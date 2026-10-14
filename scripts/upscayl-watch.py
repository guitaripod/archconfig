#!/usr/bin/env python3
"""Watch a pictures tree with inotify and upscale new images locally via realesrgan-ncnn-vulkan."""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import errno
import fcntl
import fnmatch
import math
import os
import queue
import selectors
import signal
import sqlite3
import struct
import subprocess
import sys
import threading
import time
import tomllib
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

Image.MAX_IMAGE_PIXELS = None

APP = "upscayl-watch"
HOME = Path.home()
CONFIG_PATH = Path(os.environ.get("UPSCAYL_WATCH_CONFIG", HOME / ".config" / APP / "config.toml"))
STATE_DIR = Path(os.environ.get("UPSCAYL_WATCH_STATE", HOME / ".local" / "state" / APP))

NATIVE_SCALE = 4
PIPELINE = "v2"
THUMB_EDGE = 64
WEBP_MAX_EDGE = 16383
TEMP_PREFIX = ".uwatch-"
IMAGE_SUFFIXES = (".jpg", ".jpeg", ".png", ".webp")
ANIMATED_FORMATS = ("GIF", "WEBP", "PNG")
HIGH_BIT_MODES = ("I;16", "I;16L", "I;16B", "I;16N", "I", "F")

IN_CREATE = 0x00000100
IN_CLOSE_WRITE = 0x00000008
IN_MOVED_FROM = 0x00000040
IN_MOVED_TO = 0x00000080
IN_DELETE_SELF = 0x00000400
IN_MOVE_SELF = 0x00000800
IN_IGNORED = 0x00008000
IN_Q_OVERFLOW = 0x00004000
IN_ISDIR = 0x40000000
IN_ONLYDIR = 0x01000000
IN_EXCL_UNLINK = 0x04000000

WATCH_MASK = (
    IN_CREATE
    | IN_CLOSE_WRITE
    | IN_MOVED_FROM
    | IN_MOVED_TO
    | IN_DELETE_SELF
    | IN_MOVE_SELF
    | IN_ONLYDIR
    | IN_EXCL_UNLINK
)

EVENT_HEADER = struct.Struct("iIII")

LIVE_PRIORITY = 0
BACKFILL_PRIORITY = 1
SENTINEL_PRIORITY = 9


def log(msg: str) -> None:
    print(msg, flush=True)


def warn(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


@dataclass(frozen=True)
class Root:
    """One watched tree and where its upscaled mirror is written."""

    path: Path
    output: Path
    backfill: bool = True

    def contains(self, other: Path) -> bool:
        return other == self.path or self.path in other.parents


@dataclass(frozen=True)
class Config:
    watch_dir: Path = HOME / "Pictures"
    output_dir: Path = HOME / "Pictures" / "Upscaled"
    work_dir: Path = STATE_DIR / "work"
    roots: tuple[Root, ...] = ()
    min_free_gb: float = 50.0
    binary: str = "realesrgan-ncnn-vulkan"
    model_dir: Path = Path("/usr/share/upscayl/models")
    model: str = "ultrasharp-4x"
    max_scale: float = 4.0
    max_output_long_edge: int = 8192
    max_output_pixels: int = 48_000_000
    min_gain: float = 1.5
    jpeg_quality: int = 88
    webp_quality: int = 88
    gpu_id: int = 0
    tile_sizes: tuple[int, ...] = (256, 128)
    threads: str = "1:2:2"
    tta: bool = False
    band_pixels: int = 4_000_000
    band_pad: int = 16
    min_psnr: float = 28.0
    extensions: tuple[str, ...] = IMAGE_SUFFIXES
    exclude_globs: tuple[str, ...] = ()
    min_input_pixels: int = 4096
    max_input_pixels: int = 16_000_000
    settle_seconds: float = 2.0
    settle_timeout: float = 300.0
    job_timeout: float = 1800.0
    gpu_busy_percent: int = 55
    gpu_busy_backoff: float = 45.0
    gpu_samples: int = 5
    gpu_sample_interval: float = 0.6
    max_attempts: int = 3
    preserve_mtime: bool = True

    @property
    def signature(self) -> str:
        """Everything that changes what a finished output should look like. Encoder quality is
        deliberately absent: retuning it must not invalidate the existing library."""
        flags = "tta" if self.tta else "std"
        return (
            f"{PIPELINE}:{self.model}:x{self.max_scale:g}"
            f":{self.max_output_long_edge}:{self.max_output_pixels}:{flags}"
        )

    def with_default_root(self) -> Config:
        """Fall back to the legacy single watch_dir/output_dir pair when no roots are declared."""
        if self.roots:
            return self
        return replace(self, roots=(Root(self.watch_dir, self.output_dir, True),))

    def clamped(self) -> Config:
        """Keep configured limits inside what the model and the WebP container can deliver."""
        return replace(
            self,
            max_scale=min(self.max_scale, float(NATIVE_SCALE)),
            max_output_long_edge=min(self.max_output_long_edge, WEBP_MAX_EDGE),
        )


_PATH_FIELDS = {"watch_dir", "output_dir", "work_dir", "model_dir"}
_TUPLE_FIELDS = {"extensions", "exclude_globs", "tile_sizes"}


def _expand(value: object) -> Path:
    return Path(os.path.expanduser(str(value))).resolve()


def _parse_roots(raw: list) -> tuple[Root, ...]:
    roots: list[Root] = []
    for entry in raw:
        path = _expand(entry["path"])
        output = _expand(entry.get("output", path / "Upscaled"))
        roots.append(Root(path, output, bool(entry.get("backfill", True))))
    return tuple(roots)


def load_config(path: Path) -> Config:
    """Read the TOML config, falling back to built-in defaults for anything absent."""
    cfg = Config()
    if not path.exists():
        return cfg.with_default_root().clamped()
    with path.open("rb") as fh:
        raw = tomllib.load(fh)
    known = {f.name for f in Config.__dataclass_fields__.values()}
    updates: dict[str, object] = {}
    for key, value in raw.items():
        name = key
        if name not in known:
            warn(f"config: ignoring unknown key {key!r}")
            continue
        if name == "roots":
            updates[name] = _parse_roots(value)
        elif name in _PATH_FIELDS:
            updates[name] = _expand(value)
        elif name in _TUPLE_FIELDS:
            updates[name] = tuple(value)
        else:
            updates[name] = value
    return replace(cfg, **updates).with_default_root().clamped()


@dataclass
class Normalized:
    """A source decoded into the one shape the pipeline works with: upright 8-bit RGB or RGBA."""

    image: Image.Image
    icc: bytes | None
    exif: bytes | None

    @property
    def has_alpha(self) -> bool:
        return self.image.mode == "RGBA"


class Unsupported(Exception):
    """The source is a valid image the pipeline deliberately leaves alone."""


def _to_eight_bit(im: Image.Image) -> Image.Image:
    """Collapse 16-bit and float grayscale to 8-bit by scaling, never by clipping."""
    arr = np.asarray(im, dtype=np.float64)
    peak = float(arr.max()) if arr.size else 0.0
    if peak > 255:
        arr = arr / (65535.0 if peak <= 65535 else peak) * 255.0
    return Image.fromarray(arr.clip(0, 255).astype(np.uint8), "L")


def _srgb_like_profile(icc: bytes | None) -> bytes | None:
    """Keep an embedded profile only when it describes RGB data, since the output is always RGB."""
    if icc and len(icc) > 20 and icc[16:20] == b"RGB ":
        return icc
    return None


def _exif_bytes(im: Image.Image) -> bytes | None:
    """The upright image's EXIF block, or None when it has none or cannot be re-serialised."""
    try:
        exif = im.getexif()
        return exif.tobytes() if len(exif) else None
    except Exception:
        return None


def load_normalized_image(im: Image.Image) -> Image.Image:
    """Flatten an already-open output file to the RGB(A) shape the comparison expects."""
    if im.mode in ("RGB", "RGBA"):
        return im.copy()
    return im.convert("RGBA" if "A" in im.getbands() else "RGB")


def load_normalized(path: Path) -> Normalized:
    """Decode any supported source to upright 8-bit RGB(A), keeping its ICC profile and EXIF.

    The GPU binary ignores EXIF orientation and mishandles palettes, 16-bit data and alpha,
    so every source goes through here before it is shown to the model.
    """
    with Image.open(path) as im:
        if im.format in ANIMATED_FORMATS and getattr(im, "n_frames", 1) > 1:
            raise Unsupported("animated")
        icc = _srgb_like_profile(im.info.get("icc_profile"))
        upright = ImageOps.exif_transpose(im)
        upright.load()
    exif = _exif_bytes(upright)
    if upright.mode in HIGH_BIT_MODES:
        upright = _to_eight_bit(upright)
    if upright.mode not in ("RGB", "RGBA"):
        try:
            upright = upright.convert("RGBA")
        except ValueError:
            upright = upright.convert("RGB").convert("RGBA")
    if upright.mode == "RGBA" and upright.getchannel("A").getextrema()[0] == 255:
        upright = upright.convert("RGB")
    return Normalized(upright, icc, exif)


def thumbnail(im: Image.Image, size: tuple[int, int]) -> np.ndarray:
    """Flatten onto mid-gray and shrink to a fixed grid, so any two renditions are comparable."""
    small = im.resize(size, Image.Resampling.BOX)
    if small.mode == "RGBA":
        backdrop = Image.new("RGBA", size, (128, 128, 128, 255))
        small = Image.alpha_composite(backdrop, small)
    return np.asarray(small.convert("RGB"), dtype=np.float32)


def similarity(source: Image.Image, other: Image.Image) -> float:
    """PSNR between thumbnails of two renditions of the same picture. A correct upscale keeps
    the low frequencies of its source, so scrambled tiles or black regions drop far below 28 dB."""
    width, height = source.size
    ratio = THUMB_EDGE / max(width, height)
    size = (max(1, round(width * ratio)), max(1, round(height * ratio)))
    mse = float(((thumbnail(source, size) - thumbnail(other, size)) ** 2).mean())
    return 99.0 if mse == 0 else 10 * math.log10(255 * 255 / mse)


def plan_output(cfg: Config, width: int, height: int) -> tuple[tuple[int, int], float] | str:
    """Pick the output size within the caps, or return the reason this image is left alone."""
    pixels = width * height
    if pixels < cfg.min_input_pixels:
        return f"too small ({width}x{height})"
    if pixels > cfg.max_input_pixels:
        return f"too large ({width}x{height})"
    scale = min(
        cfg.max_scale,
        cfg.max_output_long_edge / max(width, height),
        math.sqrt(cfg.max_output_pixels / pixels),
    )
    if scale < cfg.min_gain:
        return f"already large ({width}x{height}): only x{scale:.2f} possible"
    return (round(width * scale), round(height * scale)), scale


class State:
    """SQLite record of what has been upscaled, keyed by source path and content stamp."""

    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.execute(
            """CREATE TABLE IF NOT EXISTS jobs(
                   src TEXT PRIMARY KEY,
                   mtime REAL NOT NULL,
                   size INTEGER NOT NULL,
                   sig TEXT NOT NULL,
                   dst TEXT,
                   status TEXT NOT NULL,
                   detail TEXT,
                   updated REAL NOT NULL,
                   attempts INTEGER NOT NULL DEFAULT 0)"""
        )
        columns = {row[1] for row in self.db.execute("PRAGMA table_info(jobs)")}
        if "attempts" not in columns:
            self.db.execute("ALTER TABLE jobs ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0")
        self.db.commit()
        self.lock = threading.Lock()

    def get(self, src: str) -> tuple | None:
        with self.lock:
            cur = self.db.execute(
                "SELECT mtime, size, sig, dst, status, attempts FROM jobs WHERE src=?", (src,)
            )
            return cur.fetchone()

    def put(
        self,
        src: str,
        mtime: float,
        size: int,
        sig: str,
        dst: str | None,
        status: str,
        detail: str = "",
        attempts: int = 0,
    ) -> None:
        with self.lock:
            self.db.execute(
                """INSERT INTO jobs(src, mtime, size, sig, dst, status, detail, updated, attempts)
                   VALUES(?,?,?,?,?,?,?,?,?)
                   ON CONFLICT(src) DO UPDATE SET
                     mtime=excluded.mtime, size=excluded.size, sig=excluded.sig,
                     dst=excluded.dst, status=excluded.status,
                     detail=excluded.detail, updated=excluded.updated,
                     attempts=excluded.attempts""",
                (src, mtime, size, sig, dst, status, detail, time.time(), attempts),
            )
            self.db.commit()

    def forget(self, src: str) -> None:
        with self.lock:
            self.db.execute("DELETE FROM jobs WHERE src=?", (src,))
            self.db.commit()

    def adopt(self, src: str, sig: str) -> None:
        """Re-stamp a verified output with the current signature without touching its file."""
        with self.lock:
            self.db.execute("UPDATE jobs SET sig=? WHERE src=?", (sig, src))
            self.db.commit()

    def owner_of(self, dst: str, other_than: str) -> str | None:
        """The source that already owns an output path, so two sources never share one file."""
        with self.lock:
            row = self.db.execute(
                "SELECT src FROM jobs WHERE dst=? AND src!=? AND status='done'", (dst, other_than)
            ).fetchone()
            return row[0] if row else None

    def done(self) -> list[tuple[str, str, str]]:
        with self.lock:
            return self.db.execute(
                "SELECT src, dst, sig FROM jobs WHERE status='done' AND dst IS NOT NULL"
            ).fetchall()

    def retrying(self) -> list[str]:
        with self.lock:
            return [r[0] for r in self.db.execute("SELECT src FROM jobs WHERE status='retry'")]

    def counts(self) -> list[tuple[str, int]]:
        with self.lock:
            return self.db.execute(
                "SELECT status, COUNT(*) FROM jobs GROUP BY status ORDER BY 2 DESC"
            ).fetchall()

    def failures(self, limit: int = 20) -> list[tuple]:
        with self.lock:
            return self.db.execute(
                "SELECT src, detail, updated FROM jobs WHERE status IN ('failed','retry')"
                " ORDER BY updated DESC LIMIT ?",
                (limit,),
            ).fetchall()

    def failed_sources(self) -> list[str]:
        with self.lock:
            rows = self.db.execute("SELECT src FROM jobs WHERE status IN ('failed','retry')")
            return [r[0] for r in rows]

    def retry_failed(self) -> int:
        with self.lock:
            cur = self.db.execute("DELETE FROM jobs WHERE status IN ('failed','retry')")
            self.db.commit()
            return cur.rowcount


class INotify:
    """Minimal ctypes binding to Linux inotify with recursive directory tracking."""

    def __init__(self) -> None:
        libc_name = ctypes.util.find_library("c")
        self.libc = ctypes.CDLL(libc_name, use_errno=True)
        self.libc.inotify_init1.argtypes = [ctypes.c_int]
        self.libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
        self.libc.inotify_rm_watch.argtypes = [ctypes.c_int, ctypes.c_int]
        self.fd = self.libc.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1 failed")
        self.wd_to_path: dict[int, Path] = {}
        self.path_to_wd: dict[Path, int] = {}

    def add(self, path: Path) -> int | None:
        if path in self.path_to_wd:
            return self.path_to_wd[path]
        wd = self.libc.inotify_add_watch(self.fd, str(path).encode(), WATCH_MASK)
        if wd < 0:
            err = ctypes.get_errno()
            if err not in (errno.ENOENT, errno.ENOTDIR, errno.EACCES):
                warn(f"inotify: cannot watch {path}: {os.strerror(err)}")
            return None
        self.wd_to_path[wd] = path
        self.path_to_wd[path] = wd
        return wd

    def drop(self, wd: int) -> None:
        path = self.wd_to_path.pop(wd, None)
        if path is not None:
            self.path_to_wd.pop(path, None)
        self.libc.inotify_rm_watch(self.fd, wd)

    def read(self) -> list[tuple[int, int, str]]:
        try:
            data = os.read(self.fd, 1 << 20)
        except BlockingIOError:
            return []
        events: list[tuple[int, int, str]] = []
        offset = 0
        while offset + EVENT_HEADER.size <= len(data):
            wd, mask, _cookie, length = EVENT_HEADER.unpack_from(data, offset)
            offset += EVENT_HEADER.size
            name = data[offset : offset + length].split(b"\0", 1)[0].decode(errors="replace")
            offset += length
            events.append((wd, mask, name))
        return events

    def close(self) -> None:
        try:
            os.close(self.fd)
        except OSError:
            pass


@dataclass
class Attempt:
    """What one render-encode-verify pass produced."""

    failure: str | None = None
    psnr: float = 0.0
    nbytes: int = 0


class Upscaler:
    """Runs realesrgan-ncnn-vulkan for one image at a time, then re-encodes the result to a compact format.

    The model is native 4x and only ever run at 4x, on RGB, with an explicit tile size. Each of
    those is load-bearing: other scales scramble the tiles, RGBA input corrupts large outputs, and
    auto or large tiles leave black regions whenever the GPU is shared, all while exiting 0. Large sources are processed in
    overlapping bands, each resampled straight to the target size, so memory stays flat and no
    single GPU job grows large enough to corrupt. Every finished file is decoded again and compared
    with its source before it is allowed to replace anything.
    """

    def __init__(self, cfg: Config, state: State, stop: threading.Event) -> None:
        self.cfg = cfg
        self.state = state
        self.stop = stop
        self.proc: subprocess.Popen | None = None
        self.processed = 0
        self.skipped = 0
        self.failed = 0

    def destination(self, src: Path, root: Root, has_alpha: bool) -> Path:
        """Mirror the source under the output tree. Photos stay .jpg, everything else becomes
        .webp. A path already owned by another source (foo.jpg vs foo.jpeg) is disambiguated."""
        rel = src.relative_to(root.path)
        photo = src.suffix.lower() in (".jpg", ".jpeg") and not has_alpha
        suffix = ".jpg" if photo else ".webp"
        dst = (root.output / rel).with_suffix(suffix)
        if self.state.owner_of(str(dst), str(src)) is not None:
            dst = (root.output / rel).with_name(src.name + suffix)
        return dst

    def needs_work(self, src: Path) -> bool:
        try:
            st = src.stat()
        except OSError:
            return False
        row = self.state.get(str(src))
        if row is None:
            return True
        mtime, size, sig, dst, status, attempts = row
        if (round(mtime, 3), size, sig) != (round(st.st_mtime, 3), st.st_size, self.cfg.signature):
            return True
        if status == "failed":
            return attempts < self.cfg.max_attempts
        if status == "skipped":
            return False
        return not (dst and Path(dst).exists())

    def _settled(self, src: Path) -> os.stat_result | None:
        """Block until the file stops changing, so half-written downloads are never fed to the GPU."""
        deadline = time.monotonic() + self.cfg.settle_timeout
        last: tuple[int, float] | None = None
        while not self.stop.is_set():
            try:
                st = src.stat()
            except OSError:
                return None
            stamp = (st.st_size, st.st_mtime)
            if last == stamp and time.time() - st.st_mtime >= self.cfg.settle_seconds:
                return st
            last = stamp
            if time.monotonic() > deadline:
                return st
            if self.stop.wait(self.cfg.settle_seconds):
                return None
        return None

    def _gpu_sample(self) -> int | None:
        try:
            out = subprocess.run(
                ["nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"],
                capture_output=True,
                text=True,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        if out.returncode != 0:
            return None
        values = [int(v) for v in out.stdout.split() if v.strip().isdigit()]
        return max(values) if values else None

    def _gpu_busy(self) -> bool:
        """Median of a short utilisation burst, so a single spike never stalls the queue."""
        if self.cfg.gpu_busy_percent <= 0:
            return False
        samples: list[int] = []
        for index in range(self.cfg.gpu_samples):
            value = self._gpu_sample()
            if value is None:
                return False
            samples.append(value)
            if index + 1 < self.cfg.gpu_samples and self.stop.wait(self.cfg.gpu_sample_interval):
                break
        if not samples:
            return False
        samples.sort()
        return samples[len(samples) // 2] >= self.cfg.gpu_busy_percent

    def _wait_for_gpu(self) -> bool:
        """Hold jobs back while the GPU is busy elsewhere, so games and streams keep the card."""
        deferred = False
        while self._gpu_busy():
            if not deferred:
                log(f"defer: gpu >= {self.cfg.gpu_busy_percent}% busy, waiting")
                deferred = True
            if self.stop.wait(self.cfg.gpu_busy_backoff):
                return False
        if deferred:
            log("resume: gpu free")
        return not self.stop.is_set()

    def _wait_for_space(self, target: Path) -> bool:
        """Pause rather than fill the filesystem the mirror lives on."""
        if self.cfg.min_free_gb <= 0:
            return True
        need = int(self.cfg.min_free_gb * 1024**3)
        warned = False
        while not self.stop.is_set():
            usage = os.statvfs(target)
            if usage.f_bavail * usage.f_frsize >= need:
                return True
            if not warned:
                warn(f"defer: less than {self.cfg.min_free_gb}G free on {target}")
                warned = True
            if self.stop.wait(300):
                return False
        return False

    def _skip(self, src: Path, st: os.stat_result, reason: str) -> None:
        self.skipped += 1
        self.state.put(str(src), st.st_mtime, st.st_size, self.cfg.signature, None, "skipped", reason)
        log(f"skip  {src.name}: {reason}")

    def run(self, src: Path, root: Root) -> None:
        if not self.needs_work(src):
            return
        st = self._settled(src)
        if st is None:
            return
        try:
            norm = load_normalized(src)
        except Unsupported as exc:
            self._skip(src, st, str(exc))
            return
        except Exception as exc:
            self._skip(src, st, f"unreadable: {exc}")
            return
        plan = plan_output(self.cfg, *norm.image.size)
        if isinstance(plan, str):
            self._skip(src, st, plan)
            return
        out_size, scale = plan
        key = str(src)
        dst = self.destination(src, root, norm.has_alpha)
        dst.parent.mkdir(parents=True, exist_ok=True)
        self._retire_previous(dst, key)
        if not self._wait_for_space(dst.parent) or not self._wait_for_gpu():
            return
        started = time.monotonic()
        attempt = Attempt(failure="no tile size configured")
        for tile in self.cfg.tile_sizes:
            attempt = self._attempt(norm, dst, out_size, tile)
            if attempt.failure is None or self.stop.is_set():
                break
            warn(f"retry {src.name} (tile {tile}): {attempt.failure[:200]}")
        if self.stop.is_set():
            return
        if attempt.failure is not None:
            attempts = (self.state.get(key) or (0, 0, "", None, "", 0))[5] + 1
            self.failed += 1
            status = "failed" if attempts >= self.cfg.max_attempts else "retry"
            self.state.put(
                key, st.st_mtime, st.st_size, self.cfg.signature, None, status,
                attempt.failure[:500], attempts,
            )
            warn(f"fail  {src.name} (attempt {attempts}): {attempt.failure[:200]}")
            return

        if self.cfg.preserve_mtime:
            os.utime(dst, (st.st_atime, st.st_mtime))
        self.processed += 1
        self.state.put(key, st.st_mtime, st.st_size, self.cfg.signature, str(dst), "done")
        width, height = norm.image.size
        log(
            f"done  {src.relative_to(root.path)} -> {dst.name}"
            f" ({time.monotonic() - started:.1f}s, {width}x{height} -> {out_size[0]}x{out_size[1]}"
            f" x{scale:.2f}, {attempt.nbytes / 1e6:.2f}MB, {attempt.psnr:.1f}dB)"
        )

    def _attempt(
        self, norm: Normalized, dst: Path, out_size: tuple[int, int], tile: int
    ) -> Attempt:
        """Render, encode, decode again and compare; the destination is replaced only on success."""
        final_tmp = dst.with_name(f"{TEMP_PREFIX}{os.getpid()}.final")
        try:
            canvas = self._render(norm.image, out_size, tile)
            if isinstance(canvas, str):
                return Attempt(failure=canvas)
            self._encode(canvas, final_tmp, dst.suffix, norm)
            del canvas
            with Image.open(final_tmp) as probe:
                probe.load()
                decoded = load_normalized_image(probe)
            if decoded.size != out_size:
                return Attempt(failure=f"output is {decoded.size}, expected {out_size}")
            psnr = similarity(norm.image, decoded)
            if psnr < self.cfg.min_psnr:
                return Attempt(failure=f"output fails integrity check ({psnr:.1f} dB)")
            nbytes = final_tmp.stat().st_size
            os.replace(final_tmp, dst)
            return Attempt(psnr=psnr, nbytes=nbytes)
        except Exception as exc:
            return Attempt(failure=f"{type(exc).__name__}: {exc}")
        finally:
            final_tmp.unlink(missing_ok=True)

    def _bands(self, width: int, height: int) -> list[tuple[int, int]]:
        """Split the source into near-equal full-width row bands that each stay under the budget."""
        rows = max(1, self.cfg.band_pixels // max(1, width))
        count = max(1, math.ceil(height / rows))
        step = math.ceil(height / count)
        return [(y, min(height, y + step)) for y in range(0, height, step)]

    def _render(
        self, image: Image.Image, out_size: tuple[int, int], tile: int
    ) -> Image.Image | str:
        """Upscale every band on the GPU and resample it straight into place on the output canvas.

        Bands carry a few rows of padding so the model sees real context at every join, and the
        resample box is fractional so neighbouring bands meet on exactly the same output row.
        """
        width, height = image.size
        out_w, out_h = out_size
        rgb = image.convert("RGB")
        canvas = Image.new("RGB", out_size)
        native = out_size == (width * NATIVE_SCALE, height * NATIVE_SCALE)
        bands = self._bands(width, height)
        pad = self.cfg.band_pad if len(bands) > 1 else 0
        work = self.cfg.work_dir
        work.mkdir(parents=True, exist_ok=True)
        stage_in = work / f"{TEMP_PREFIX}{os.getpid()}.in.png"
        stage_out = work / f"{TEMP_PREFIX}{os.getpid()}.out.png"
        try:
            for top, bottom in bands:
                lo, hi = max(0, top - pad), min(height, bottom + pad)
                rgb.crop((0, lo, width, hi)).save(stage_in, compress_level=1)
                code, output = self._invoke(stage_in, stage_out, tile)
                if code != 0 or not stage_out.exists() or stage_out.stat().st_size == 0:
                    tail = (output or "").strip().splitlines()[-1:]
                    return tail[0] if tail else f"exit {code}"
                with Image.open(stage_out) as up:
                    up.load()
                    expected = (width * NATIVE_SCALE, (hi - lo) * NATIVE_SCALE)
                    if up.size != expected:
                        return f"gpu returned {up.size}, expected {expected}"
                    box = (0, (top - lo) * NATIVE_SCALE, width * NATIVE_SCALE, (bottom - lo) * NATIVE_SCALE)
                    row0, row1 = round(top * out_h / height), round(bottom * out_h / height)
                    piece = up.crop(box) if native else up.resize(
                        (out_w, row1 - row0), Image.Resampling.LANCZOS, box=box
                    )
                canvas.paste(piece, (0, row0))
                stage_out.unlink(missing_ok=True)
                if self.stop.is_set():
                    return "stopped"
        finally:
            stage_in.unlink(missing_ok=True)
            stage_out.unlink(missing_ok=True)
        if image.mode == "RGBA":
            alpha = image.getchannel("A").resize(out_size, Image.Resampling.BICUBIC)
            canvas.putalpha(alpha)
        return canvas

    def _encode(self, canvas: Image.Image, target: Path, suffix: str, norm: Normalized) -> None:
        """Size-optimization layer: lossy JPEG for photos, lossy WebP for the rest.

        Photos use progressive 4:2:0 and everything else method-6 WebP, both with the source's
        ICC profile and EXIF carried over so colors and metadata survive. At 4x the model output
        is smooth enough that these settings stay above 36 dB against the lossless result.
        """
        extras: dict[str, object] = {}
        if norm.icc:
            extras["icc_profile"] = norm.icc
        if norm.exif:
            extras["exif"] = norm.exif
        if suffix == ".jpg":
            canvas.convert("RGB").save(
                target,
                "JPEG",
                quality=self.cfg.jpeg_quality,
                subsampling="4:2:0",
                optimize=True,
                progressive=True,
                **extras,
            )
        else:
            canvas.save(target, "WEBP", quality=self.cfg.webp_quality, method=6, **extras)

    def _retire_previous(self, dst: Path, key: str) -> None:
        """Delete a superseded output so the mirror never keeps both generations of one source."""
        row = self.state.get(key)
        if not row:
            return
        old_dst = row[3]
        if old_dst and Path(old_dst) != dst:
            old = Path(old_dst)
            if old.parent == dst.parent and old.is_file():
                old.unlink(missing_ok=True)

    def _invoke(self, source: Path, target: Path, tile: int) -> tuple[int, str]:
        """Run one 4x pass; the GPU stage always writes lossless PNG. Both paths must be
        space-free: the packaged launcher forwards its arguments through an unquoted $@."""
        cmd = [
            self.cfg.binary,
            "-i", str(source),
            "-o", str(target),
            "-m", str(self.cfg.model_dir),
            "-n", self.cfg.model,
            "-s", str(NATIVE_SCALE),
            "-f", "png",
            "-t", str(tile),
            "-j", self.cfg.threads,
            "-g", str(self.cfg.gpu_id),
        ]
        if self.cfg.tta:
            cmd.append("-x")
        try:
            self.proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
            )
            output, _ = self.proc.communicate(timeout=self.cfg.job_timeout)
            return self.proc.returncode, output
        except subprocess.TimeoutExpired:
            self._kill()
            return -9, "timed out"
        except OSError as exc:
            return -1, str(exc)
        finally:
            self.proc = None

    def _kill(self) -> None:
        proc = self.proc
        if proc is None or proc.poll() is not None:
            return
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()

    def abort(self) -> None:
        self._kill()


@dataclass
class Finding:
    """One output the audit judged unfit, and why."""

    src: Path
    dst: Path
    reason: str


class Auditor:
    """Re-checks every finished output against its source and what the current pipeline would make."""

    def __init__(self, cfg: Config, state: State) -> None:
        self.cfg = cfg
        self.state = state

    def inspect(self, src: Path, dst: Path) -> str | None:
        """Return the reason an output is unfit, or None when it matches the current plan."""
        if not dst.exists():
            return "output missing"
        try:
            norm = load_normalized(src)
        except Exception as exc:
            return f"source unreadable: {exc}"
        plan = plan_output(self.cfg, *norm.image.size)
        if isinstance(plan, str):
            return f"should not exist: {plan}"
        try:
            with Image.open(dst) as probe:
                probe.load()
                decoded = load_normalized_image(probe)
        except Exception as exc:
            return f"output undecodable: {exc}"
        if decoded.size != plan[0]:
            return f"size {decoded.size[0]}x{decoded.size[1]}, plan is {plan[0][0]}x{plan[0][1]}"
        psnr = similarity(norm.image, decoded)
        if psnr < self.cfg.min_psnr:
            return f"corrupt ({psnr:.1f} dB)"
        return None

    def run(self, fix: bool, roots: tuple[Root, ...]) -> list[Finding]:
        """Check every done record. With fix, drop bad outputs and their records so a rescan redoes
        them, and re-stamp good outputs with the current signature so they are never redone."""
        findings: list[Finding] = []
        rows = self.state.done()
        sig = self.cfg.signature
        for index, (src_s, dst_s, row_sig) in enumerate(rows, 1):
            src, dst = Path(src_s), Path(dst_s)
            if not src.exists():
                continue
            reason = self.inspect(src, dst)
            if index % 50 == 0:
                log(f"audit: {index}/{len(rows)}")
            if reason is None:
                if fix and row_sig != sig:
                    self.state.adopt(src_s, sig)
                continue
            findings.append(Finding(src, dst, reason))
            if fix:
                self._discard(dst, roots)
                self.state.forget(src_s)
        return findings

    def _discard(self, dst: Path, roots: tuple[Root, ...]) -> None:
        """Delete a derived output, but only ever inside a configured output tree."""
        if any(root.output in dst.parents for root in roots):
            dst.unlink(missing_ok=True)

    def legacy_duplicates(self, roots: tuple[Root, ...]) -> list[Path]:
        """Outputs left over from earlier pipelines: same folder and stem as a current output."""
        current = {Path(dst) for _src, dst, _sig in self.state.done() if Path(dst).exists()}
        stems = {(p.parent, p.stem) for p in current}
        stale: list[Path] = []
        for root in roots:
            if not root.output.is_dir():
                continue
            for parent, _dirs, files in os.walk(root.output):
                for name in files:
                    path = Path(parent) / name
                    if path.suffix.lower() not in IMAGE_SUFFIXES or name.startswith("."):
                        continue
                    if path not in current and (path.parent, path.stem) in stems:
                        stale.append(path)
        return sorted(stale)


class Watcher:
    """Owns the inotify tree, the backfill scan, and the single-threaded upscale worker."""

    def __init__(self, cfg: Config, state: State) -> None:
        self.cfg = cfg
        self.state = state
        self.stop = threading.Event()
        self.queue: queue.PriorityQueue = queue.PriorityQueue()
        self.pending: set[Path] = set()
        self.pending_lock = threading.Lock()
        self.sequence = 0
        self.upscaler = Upscaler(cfg, state, self.stop)
        self.notifier: INotify | None = None

    def root_for(self, path: Path) -> Root | None:
        for root in self.cfg.roots:
            if root.contains(path):
                return root
        return None

    def is_excluded(self, path: Path) -> bool:
        root = self.root_for(path)
        if root is None:
            return True
        if any(other.output == path or other.output in path.parents for other in self.cfg.roots):
            return True
        rel = path.relative_to(root.path)
        if any(part.startswith(".") for part in rel.parts):
            return True
        return any(fnmatch.fnmatch(str(rel), pat) for pat in self.cfg.exclude_globs)

    def is_candidate(self, path: Path) -> bool:
        return (
            path.suffix.lower() in self.cfg.extensions
            and not path.name.startswith(".")
            and not self.is_excluded(path)
            and path.is_file()
        )

    def enqueue(self, path: Path, priority: int = LIVE_PRIORITY) -> None:
        """Live drops jump ahead of any backfill still draining."""
        with self.pending_lock:
            if path in self.pending:
                return
            self.pending.add(path)
            self.sequence += 1
            order = self.sequence
        self.queue.put((priority, order, path))

    def worker(self) -> None:
        while True:
            _priority, _order, item = self.queue.get()
            if item is None:
                return
            with self.pending_lock:
                self.pending.discard(item)
            try:
                root = self.root_for(item)
                if root is not None:
                    self.upscaler.run(item, root)
            except Exception as exc:
                warn(f"worker error on {item}: {exc}")
            finally:
                self.queue.task_done()

    def scan(self) -> int:
        found = 0
        for root in self.cfg.roots:
            if not root.backfill or not root.path.is_dir():
                continue
            for parent, dirs, files in os.walk(root.path, followlinks=False):
                parent_path = Path(parent)
                dirs[:] = sorted(d for d in dirs if not self.is_excluded(parent_path / d))
                for name in sorted(files):
                    path = parent_path / name
                    if self.is_candidate(path) and self.upscaler.needs_work(path):
                        self.enqueue(path, BACKFILL_PRIORITY)
                        found += 1
        return found

    def requeue_retries(self) -> int:
        """Pick up jobs that failed transiently before the last shutdown, in any root."""
        count = 0
        for name in self.state.retrying():
            path = Path(name)
            if self.is_candidate(path) and self.upscaler.needs_work(path):
                self.enqueue(path, BACKFILL_PRIORITY)
                count += 1
        return count

    def sweep_temp(self) -> None:
        """Remove half-written files a crashed run left in the output trees and the work dir."""
        trees = [root.output for root in self.cfg.roots] + [self.cfg.work_dir]
        for tree in trees:
            if not tree.is_dir():
                continue
            for parent, _dirs, files in os.walk(tree):
                for name in files:
                    if name.startswith(TEMP_PREFIX):
                        (Path(parent) / name).unlink(missing_ok=True)

    def watch_tree(self) -> None:
        assert self.notifier is not None
        for root in self.cfg.roots:
            if not root.path.is_dir():
                warn(f"watch root missing: {root.path}")
                continue
            self.notifier.add(root.path)
            for parent, dirs, _ in os.walk(root.path, followlinks=False):
                parent_path = Path(parent)
                dirs[:] = [d for d in dirs if not self.is_excluded(parent_path / d)]
                for d in dirs:
                    self.notifier.add(parent_path / d)

    def _handle(self, wd: int, mask: int, name: str) -> None:
        assert self.notifier is not None
        if mask & IN_Q_OVERFLOW:
            warn("inotify queue overflow; rescanning")
            self.scan()
            return
        base = self.notifier.wd_to_path.get(wd)
        if base is None:
            return
        if mask & (IN_IGNORED | IN_DELETE_SELF | IN_MOVE_SELF):
            self.notifier.drop(wd)
            return
        path = base / name if name else base
        if self.is_excluded(path):
            return
        if mask & IN_ISDIR:
            if mask & (IN_CREATE | IN_MOVED_TO):
                self.notifier.add(path)
                for sub in self.scan_new_dir(path):
                    self.enqueue(sub)
            return
        if mask & (IN_CLOSE_WRITE | IN_MOVED_TO) and self.is_candidate(path):
            self.enqueue(path)

    def scan_new_dir(self, root: Path) -> list[Path]:
        found: list[Path] = []
        for parent, dirs, files in os.walk(root, followlinks=False):
            parent_path = Path(parent)
            dirs[:] = [d for d in dirs if not self.is_excluded(parent_path / d)]
            for d in dirs:
                assert self.notifier is not None
                self.notifier.add(parent_path / d)
            for name in files:
                path = parent_path / name
                if self.is_candidate(path):
                    found.append(path)
        return found

    def _start_worker(self) -> threading.Thread:
        for root in self.cfg.roots:
            if root.path.is_dir():
                root.output.mkdir(parents=True, exist_ok=True)
        self.sweep_temp()
        thread = threading.Thread(target=self.worker, name="upscaler", daemon=True)
        thread.start()
        return thread

    def _drain(self, thread: threading.Thread) -> int:
        self.queue.join()
        self.queue.put((SENTINEL_PRIORITY, self.sequence + 1, None))
        thread.join(timeout=30)
        return self._summary()

    def run_paths(self, paths: list[Path]) -> int:
        """Process exactly these sources, wherever they live, then exit."""
        thread = self._start_worker()
        for path in paths:
            self.enqueue(path, BACKFILL_PRIORITY)
        log(f"rebuild: {len(paths)} image(s) queued")
        return self._drain(thread)

    def run(self, once: bool = False) -> int:
        thread = self._start_worker()

        if not once:
            self.notifier = INotify()
            self.watch_tree()
            for root in self.cfg.roots:
                mode = "backfill" if root.backfill else "new files only"
                log(f"watching {root.path} -> {root.output} ({mode})")
            log(f"inotify watches: {len(self.notifier.wd_to_path)} dirs")

        backlog = self.scan() + self.requeue_retries()
        log(f"backlog: {backlog} image(s) queued")

        if once:
            return self._drain(thread)

        sel = selectors.DefaultSelector()
        sel.register(self.notifier.fd, selectors.EVENT_READ)
        while not self.stop.is_set():
            for _key, _mask in sel.select(timeout=1.0):
                for wd, event_mask, name in self.notifier.read():
                    self._handle(wd, event_mask, name)
        sel.close()
        self.notifier.close()
        self.queue.put((SENTINEL_PRIORITY, self.sequence + 1, None))
        thread.join(timeout=15)
        return self._summary()

    def _summary(self) -> int:
        up = self.upscaler
        log(f"summary: {up.processed} upscaled, {up.skipped} skipped, {up.failed} failed")
        return 1 if up.failed and not up.processed else 0

    def shutdown(self, *_args) -> None:
        self.stop.set()
        self.upscaler.abort()


DEFAULT_CONFIG = """# upscayl-watch configuration
min_free_gb = 50.0

binary = "realesrgan-ncnn-vulkan"
model_dir = "/usr/share/upscayl/models"
model = "ultrasharp-4x"

# The model is native 4x and always runs at 4x; larger results are resampled down to these caps.
max_scale = 4.0
max_output_long_edge = 8192
max_output_pixels = 48000000
# Skip sources that could only be enlarged by less than this factor.
min_gain = 1.5

# Size-optimization layer: .jpg/.jpeg photos -> progressive .jpg, everything else -> .webp
jpeg_quality = 88
webp_quality = 88

gpu_id = 0
# Small explicit tiles only. Auto (0), 1024 and even 512 leave black regions when the GPU is shared; the second size is the retry.
tile_sizes = [256, 128]
threads = "1:2:2"
tta = false

# Large sources run in overlapping bands of about this many source pixels.
band_pixels = 4000000
band_pad = 16

# Every output is decoded again and compared with its source; below this it is rejected.
min_psnr = 28.0

extensions = [".jpg", ".jpeg", ".png", ".webp"]
exclude_globs = []

min_input_pixels = 4096
max_input_pixels = 16000000

settle_seconds = 2.0
job_timeout = 1800.0

gpu_busy_percent = 55
gpu_busy_backoff = 45.0
gpu_samples = 5
gpu_sample_interval = 0.6

max_attempts = 3
preserve_mtime = true

# Watched trees. Keep these tables last: TOML assigns every bare key that
# follows a [[roots]] header to that table.
[[roots]]
path = "{watch}"
output = "{out}"
backfill = true
"""


def write_default_config(path: Path, cfg: Config) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(DEFAULT_CONFIG.format(watch=cfg.watch_dir, out=cfg.output_dir))
    log(f"wrote {path}")


def acquire_lock() -> int | None:
    """Only one process may own the queue and the output trees at a time."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fd = os.open(STATE_DIR / "lock", os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


def report_findings(findings: list[Finding], stale: list[Path], fix: bool) -> None:
    verb = "dropped" if fix else "flagged"
    for item in findings:
        log(f"  {item.reason}: {item.dst}")
    for path in stale:
        log(f"  legacy duplicate: {path}")
    log(f"audit: {len(findings)} output(s) {verb}, {len(stale)} legacy duplicate(s)")


def main() -> int:
    parser = argparse.ArgumentParser(prog=APP, description=__doc__)
    parser.add_argument("--once", action="store_true", help="process the backlog and exit")
    parser.add_argument("--status", action="store_true", help="print state summary and exit")
    parser.add_argument("--retry-failed", action="store_true", help="clear failures and exit")
    parser.add_argument("--init-config", action="store_true", help="write a default config file")
    parser.add_argument("--audit", action="store_true", help="verify every finished output and exit")
    parser.add_argument(
        "--rebuild",
        action="store_true",
        help="audit, drop every bad output, redo exactly those, remove legacy duplicates, exit",
    )
    parser.add_argument("--config", type=Path, default=CONFIG_PATH)
    args = parser.parse_args()

    cfg = load_config(args.config)
    if args.init_config:
        write_default_config(args.config, cfg)
        return 0

    state = State(STATE_DIR / "state.db")

    if args.status:
        log(f"config:  {args.config}")
        for root in cfg.roots:
            mode = "backfill" if root.backfill else "new files only"
            log(f"root:    {root.path} -> {root.output} ({mode})")
        log(
            f"model:   {cfg.model} (native x{NATIVE_SCALE}, up to x{cfg.max_scale:g},"
            f" long edge <= {cfg.max_output_long_edge}px, <= {cfg.max_output_pixels // 1_000_000}MP)"
        )
        for status, count in state.counts():
            log(f"  {status:<8} {count}")
        failures = state.failures(5)
        if failures:
            log("recent failures:")
            for src, detail, _ts in failures:
                log(f"  {src}: {detail}")
        return 0

    if args.retry_failed:
        log(f"cleared {state.retry_failed()} failed record(s)")
        return 0

    if args.audit:
        auditor = Auditor(cfg, state)
        report_findings(auditor.run(False, cfg.roots), auditor.legacy_duplicates(cfg.roots), False)
        return 0

    if not any(root.path.is_dir() for root in cfg.roots):
        warn("no configured watch root exists")
        return 1

    lock = acquire_lock()
    if lock is None:
        warn("another upscayl-watch owns the queue; stop it first")
        return 1

    watcher = Watcher(cfg, state)
    signal.signal(signal.SIGTERM, watcher.shutdown)
    signal.signal(signal.SIGINT, watcher.shutdown)

    if args.rebuild:
        auditor = Auditor(cfg, state)
        findings = auditor.run(True, cfg.roots)
        report_findings(findings, [], True)
        redo = [item.src for item in findings] + [Path(s) for s in state.failed_sources()]
        state.retry_failed()
        code = watcher.run_paths(redo)
        stale = auditor.legacy_duplicates(cfg.roots)
        for path in stale:
            path.unlink(missing_ok=True)
        report_findings([], stale, True)
        return code

    return watcher.run(once=args.once)


if __name__ == "__main__":
    sys.exit(main())
