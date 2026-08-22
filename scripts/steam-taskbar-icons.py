#!/usr/bin/env python3
"""Give every Steam game a real taskbar icon under Plasma.

Steam launches games with the X11/Wayland window class `steam_app_<appid>` (Proton's
wine driver and Steam's SDL_VIDEO_*_WMCLASS both do this). Plasma's task manager turns
a window class into an icon by looking for a .desktop file of that name, or one whose
StartupWMClass matches. Steam ships no such file, so any game that does not set its own
_NET_WM_ICON falls back to the generic placeholder window icon.

This writes one ~/.local/share/applications/steam_app_<appid>.desktop per installed
game (Steam library entries and non-Steam shortcuts), each pointing at an icon
installed into the hicolor theme as steam_icon_<appid> -- the same name Steam itself
uses, so its own desktop shortcuts keep working.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import OrderedDict

HOME = os.path.expanduser('~')
STEAM = os.path.join(HOME, '.local/share/Steam')
APPS = os.path.join(HOME, '.local/share/applications')
ICONS = os.path.join(HOME, '.local/share/icons/hicolor')
CACHE = os.path.join(HOME, '.cache/steam-taskbar-icons')
SIZES = [16, 24, 32, 48, 64, 128, 256]
API = 'https://www.steamgriddb.com/api/v2'
MARKER = 'steam-taskbar-icons'
SKIP_NAMES = re.compile(r'^(Proton|Steam Linux Runtime|Steamworks Common|SteamVR|'
                        r'Steam Controller|Proton Experimental)', re.I)
SKIP_IDS = {228980, 1070560, 1391110, 1493710, 1580130, 1826330, 2180100, 2230260,
            2348590, 2805730, 3658110, 3960590, 4183110, 4628710, 250820, 1161040}


def log(msg: str) -> None:
    print(msg, flush=True)


def run(*cmd: str) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True)


def library_paths() -> list[str]:
    vdf = os.path.join(STEAM, 'steamapps/libraryfolders.vdf')
    paths = []
    if os.path.exists(vdf):
        for m in re.finditer(r'"path"\s+"([^"]+)"', open(vdf, encoding='utf-8', errors='replace').read()):
            p = os.path.join(m.group(1), 'steamapps')
            if os.path.isdir(p):
                paths.append(p)
    if not paths:
        paths = [os.path.join(STEAM, 'steamapps')]
    return paths


def installed_apps() -> list[tuple[int, str]]:
    seen: dict[int, str] = {}
    for lib in library_paths():
        for f in sorted(os.listdir(lib)):
            m = re.fullmatch(r'appmanifest_(\d+)\.acf', f)
            if not m:
                continue
            appid = int(m.group(1))
            txt = open(os.path.join(lib, f), encoding='utf-8', errors='replace').read()
            nm = re.search(r'"name"\s+"([^"]*)"', txt)
            name = nm.group(1) if nm else f'Steam App {appid}'
            if appid in SKIP_IDS or SKIP_NAMES.match(name):
                continue
            seen[appid] = name
    return sorted(seen.items(), key=lambda kv: kv[1].lower())


def _read_str(data: bytes, i: int) -> tuple[str, int]:
    j = data.index(b'\x00', i)
    return data[i:j].decode('utf-8', 'replace'), j + 1


def parse_binary_vdf(data: bytes, i: int = 0) -> tuple[OrderedDict, int]:
    out: OrderedDict = OrderedDict()
    while i < len(data):
        t = data[i]
        i += 1
        if t == 0x08:
            return out, i
        key, i = _read_str(data, i)
        if t == 0x00:
            out[key], i = parse_binary_vdf(data, i)
        elif t == 0x01:
            out[key], i = _read_str(data, i)
        elif t == 0x02:
            out[key] = int.from_bytes(data[i:i + 4], 'little', signed=True)
            i += 4
        elif t == 0x07:
            out[key] = int.from_bytes(data[i:i + 8], 'little')
            i += 8
        else:
            raise ValueError(f'unknown vdf type {t:#x} at {i}')
    return out, i


def shortcut_apps() -> list[tuple[int, str, str | None, bool]]:
    out = []
    udir = os.path.join(STEAM, 'userdata')
    if not os.path.isdir(udir):
        return out
    for uid in os.listdir(udir):
        path = os.path.join(udir, uid, 'config/shortcuts.vdf')
        if not os.path.exists(path):
            continue
        try:
            tree, _ = parse_binary_vdf(open(path, 'rb').read())
        except Exception as exc:
            log(f'  ! could not parse {path}: {exc}')
            continue
        root = next(iter(tree.values())) if len(tree) == 1 and isinstance(next(iter(tree.values())), OrderedDict) else tree
        grid = os.path.join(udir, uid, 'config/grid')
        for entry in root.values():
            if not isinstance(entry, OrderedDict):
                continue
            appid = entry.get('appid')
            name = entry.get('AppName') or entry.get('appname')
            if appid is None or not name:
                continue
            uappid = appid & 0xFFFFFFFF
            src = None
            for cand in (entry.get('icon') or '',
                         os.path.join(grid, f'{uappid}_icon.png'),
                         os.path.join(grid, f'{uappid}_icon.ico'),
                         os.path.join(grid, f'{uappid}p.png')):
                cand = cand.strip('"')
                if cand and os.path.exists(cand):
                    src = cand
                    break
            out.append((uappid, name, src, True))
    return sorted(out, key=lambda t: t[1].lower())


def load_state() -> dict:
    try:
        return json.load(open(os.path.join(CACHE, 'installed.json')))
    except Exception:
        return {}


def save_state(state: dict) -> None:
    os.makedirs(CACHE, exist_ok=True)
    json.dump(state, open(os.path.join(CACHE, 'installed.json'), 'w'), indent=1, sort_keys=True)


def existing_icon_max(appid: int) -> int:
    best = 0
    for size in SIZES:
        if os.path.exists(os.path.join(ICONS, f'{size}x{size}/apps/steam_icon_{appid}.png')):
            best = max(best, size)
    return best


def librarycache_icon(appid: int) -> str | None:
    d = os.path.join(STEAM, f'appcache/librarycache/{appid}')
    if not os.path.isdir(d):
        return None
    best = None
    for f in os.listdir(d):
        if re.fullmatch(r'[0-9a-f]{40}\.(jpg|png|ico)', f):
            p = os.path.join(d, f)
            w, h = image_size(p)
            if w and w == h and (best is None or w > best[1]):
                best = (p, w)
    if best:
        return best[0]
    for f in ('logo.png', 'library_600x900.jpg', 'library_header.jpg'):
        p = os.path.join(d, f)
        if os.path.exists(p):
            return p
    return None


def image_size(path: str) -> tuple[int, int]:
    r = run('identify', '-format', '%w %h\n', path)
    if r.returncode != 0 or not r.stdout.strip():
        return (0, 0)
    w, h = r.stdout.strip().splitlines()[0].split()
    return int(w), int(h)


def largest_frame(path: str) -> str:
    r = run('identify', '-format', '%s %w\n', path)
    if r.returncode != 0:
        return path
    best_idx, best_w = 0, -1
    for line in r.stdout.strip().splitlines():
        try:
            idx, w = line.split()[:2]
            if int(w) > best_w:
                best_idx, best_w = int(idx), int(w)
        except ValueError:
            continue
    return f'{path}[{best_idx}]'


class Grid:
    def __init__(self, key: str | None, enabled: bool = True):
        self.key = key
        self.enabled = enabled and bool(key)
        os.makedirs(CACHE, exist_ok=True)
        self.map_path = os.path.join(CACHE, 'sgdb.json')
        try:
            self.map = json.load(open(self.map_path))
        except Exception:
            self.map = {}

    def save(self) -> None:
        json.dump(self.map, open(self.map_path, 'w'), indent=1, sort_keys=True)

    def _get(self, path: str) -> dict | None:
        req = urllib.request.Request(f'{API}/{path}', headers={
            'Authorization': f'Bearer {self.key}', 'User-Agent': 'steam-taskbar-icons/1.0'})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=25) as r:
                    return json.load(r)
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    return None
                if e.code == 429:
                    time.sleep(3 * (attempt + 1))
                    continue
                return None
            except Exception:
                time.sleep(1.5 * (attempt + 1))
        return None

    def icon_url(self, appid: int, name: str) -> str | None:
        if not self.enabled:
            return None
        cached = self.map.get(str(appid))
        if cached is not None:
            return cached or None
        gid = None
        d = self._get(f'games/steam/{appid}')
        if d and d.get('success') and d.get('data'):
            gid = d['data'].get('id')
        if gid is None:
            q = urllib.parse.quote(name)
            d = self._get(f'search/autocomplete/{q}')
            if d and d.get('data'):
                gid = d['data'][0].get('id')
        url = ''
        if gid is not None:
            for query in (f'icons/game/{gid}?types=static&styles=official',
                          f'icons/game/{gid}?types=static'):
                d = self._get(query)
                items = [i for i in ((d or {}).get('data') or []) if i.get('url')]
                if items:
                    items.sort(key=lambda i: (i.get('width') or 0), reverse=True)
                    url = items[0]['url']
                    break
        self.map[str(appid)] = url
        self.save()
        return url or None


def download(url: str, dest: str) -> str | None:
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'steam-taskbar-icons/1.0'})
        with urllib.request.urlopen(req, timeout=40) as r, open(dest, 'wb') as f:
            shutil.copyfileobj(r, f)
        return dest
    except Exception:
        return None


def install_icon(appid: int, src: str, dry: bool) -> int:
    """Render src into the hicolor theme as steam_icon_<appid>; return the largest size."""
    read_from = largest_frame(src) if src.lower().endswith('.ico') else src
    w, h = image_size(read_from)
    native = max(w, h) or 32
    sizes = [s for s in SIZES if s <= native] or [SIZES[0]]
    if native not in sizes and native in SIZES:
        sizes.append(native)
    largest = max(sizes)
    for size in sizes:
        out = os.path.join(ICONS, f'{size}x{size}/apps/steam_icon_{appid}.png')
        if dry:
            continue
        os.makedirs(os.path.dirname(out), exist_ok=True)
        r = run('magick', read_from, '-background', 'none', '-alpha', 'set',
                '-resize', f'{size}x{size}>', '-gravity', 'center',
                '-extent', f'{size}x{size}', '-strip', f'PNG32:{out}')
        if r.returncode != 0:
            log(f'  ! magick failed for {appid} @{size}: {r.stderr.strip()[:120]}')
            return 0
    return largest


DESKTOP = """[Desktop Entry]
Type=Application
Name={name}
Comment=Play this game on Steam
Exec=steam steam://rungameid/{rungameid}
Icon=steam_icon_{appid}
Terminal=false
Categories=Game;
StartupWMClass=steam_app_{appid}
StartupNotify=true
{nodisplay}X-Steam-AppID={appid}
X-Generated-By={marker}
"""


def write_desktop(appid: int, name: str, rungameid: int, nodisplay: bool, dry: bool) -> bool:
    """Write the entry only when it would change, so repeat runs touch nothing."""
    path = os.path.join(APPS, f'steam_app_{appid}.desktop')
    body = DESKTOP.format(name=name.replace('\n', ' '), appid=appid, rungameid=rungameid,
                          nodisplay='NoDisplay=true\n' if nodisplay else '', marker=MARKER)
    if os.path.exists(path) and open(path, encoding='utf-8', errors='replace').read() == body:
        return False
    if not dry:
        os.makedirs(APPS, exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(body)
        os.chmod(path, 0o644)
    return True


def refresh_caches() -> None:
    for cmd in (('kbuildsycoca6', '--noincremental'),
                ('gtk-update-icon-cache', '-f', '-t', ICONS),
                ('update-desktop-database', APPS)):
        if shutil.which(cmd[0]):
            run(*cmd)
    run('gdbus', 'call', '--session', '--dest', 'org.kde.KWin', '--object-path', '/KWin',
        '--method', 'org.kde.KWin.reconfigure')


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--only', type=int, action='append', help='limit to these appids')
    ap.add_argument('--no-sgdb', action='store_true', help='skip SteamGridDB lookups')
    ap.add_argument('--force-icons', action='store_true',
                    help='re-render icons even when a good one is already installed')
    ap.add_argument('--show', action='store_true',
                    help='list the entries in the application menu instead of hiding them')
    ap.add_argument('--clean', action='store_true',
                    help='remove everything this tool generated and exit')
    args = ap.parse_args()

    if args.clean:
        n = 0
        for f in sorted(os.listdir(APPS)):
            p = os.path.join(APPS, f)
            if f.startswith('steam_app_') and f.endswith('.desktop') \
                    and MARKER in open(p, encoding='utf-8', errors='replace').read():
                os.remove(p)
                n += 1
        log(f'removed {n} generated .desktop files (icons left in place)')
        refresh_caches()
        return 0

    key = None
    kp = os.path.join(HOME, '.config/steamgriddb/key')
    if os.path.exists(kp):
        key = open(kp).read().strip()
    grid = Grid(key, enabled=not args.no_sgdb)
    if not grid.enabled:
        log('SteamGridDB disabled -- falling back to Steam\'s own 32px client icons')

    targets: list[tuple[int, str, str | None, bool]] = [(a, n, None, False) for a, n in installed_apps()]
    targets += shortcut_apps()
    if args.only:
        want = set(args.only)
        targets = [t for t in targets if t[0] in want]

    stats = {'sgdb': 0, 'steam': 0, 'kept': 0, 'shortcut': 0, 'none': 0}
    dirty = [False]
    state = load_state()
    for appid, name, shortcut_src, is_shortcut in targets:
        rungameid = ((appid << 32) | 0x02000000) if is_shortcut else appid
        have = existing_icon_max(appid)
        done = state.get(str(appid))
        source_label = None
        if have and (have >= 128 or (done and have >= int(done.get('size', 0)))) \
                and not args.force_icons:
            stats['kept'] += 1
            source_label = f'kept {have}px'
        else:
            src = None
            if shortcut_src:
                src = shortcut_src
                source_label = 'shortcut art'
                stats['shortcut'] += 1
            if src is None:
                url = grid.icon_url(appid, name)
                if url:
                    ext = os.path.splitext(urllib.parse.urlparse(url).path)[1] or '.png'
                    tmp = os.path.join(CACHE, f'{appid}{ext}')
                    src = download(url, tmp)
                    if src:
                        source_label = 'steamgriddb'
                        stats['sgdb'] += 1
            if src is None:
                src = librarycache_icon(appid)
                if src:
                    source_label = 'steam cache ' + os.path.basename(src)
                    stats['steam'] += 1
            if src is None:
                if have:
                    source_label = f'kept {have}px'
                    stats['kept'] += 1
                else:
                    stats['none'] += 1
                    log(f'  - {appid:<10} {name[:44]:<46} NO ICON FOUND')
                    continue
            else:
                got = install_icon(appid, src, args.dry_run)
                if not got:
                    stats['none'] += 1
                    continue
                state[str(appid)] = {'size': got, 'source': source_label}
                source_label = f'{source_label} -> {got}px'
        changed = write_desktop(appid, name, rungameid, nodisplay=not args.show, dry=args.dry_run)
        if changed or not source_label.startswith('kept'):
            dirty[0] = True
            log(f'  * {appid:<10} {name[:44]:<46} {source_label}')

    log(f'\n{len(targets)} apps: {stats["sgdb"]} steamgriddb, {stats["steam"]} steam cache, '
        f'{stats["shortcut"]} shortcut art, {stats["kept"]} already good, {stats["none"]} unresolved')
    if args.dry_run:
        log('dry run -- nothing written')
        return 0
    save_state(state)
    if not dirty[0]:
        log('nothing changed -- caches left alone')
        return 0
    refresh_caches()
    log('caches refreshed; open windows repaint within a second')
    return 0


if __name__ == '__main__':
    sys.exit(main())
