#!/usr/bin/env python3
"""Run a game on the P-cores of a hybrid Intel CPU and keep its helper threads on the E-cores.

Steam launch options:  game-cores %command%
                       hdr-game game-cores mangohud obs-gamecapture %command%

The whole process tree starts on the P-cores. While the game runs, threads whose names match
the helper pattern (streaming, audio, shader compiles, Wine plumbing, overlays) and whole helper
processes (crash reporters, Proton's steam.exe bridge) are moved to the E-cores, so the main,
render and job threads have the P-cores to themselves. On a CPU without E-cores it just runs
the command. GAME_CORES_HELPERS overrides the thread pattern, GAME_CORES=off disables it.
"""

from __future__ import annotations

import ctypes
import os
import re
import signal
import sys
import time

DEFAULT_HELPER_THREADS = (
    r"^(NxStorage|Job Lo|audio_client|FAudio|Texture Streami|File Video Stre|Pipeline creati|"
    r"Pipeline write|Archive|Asset Load|UXAnalytics|Save Thread|Stats thread|TTY Transmitter|"
    r"wine_|mangohud|sl\.log|cuda|\[vk|vkd3d-disk|Touch Pad|MessageThread|ResourceCreatio)"
)
HELPER_PROCESSES = re.compile(
    r"(crs-handler|crashreport|system32\\steam\.exe|explorer\.exe|winedevice\.exe|services\.exe|"
    r"plugplay\.exe|rpcss\.exe|svchost\.exe|tabtip\.exe)",
    re.IGNORECASE,
)
POLL_SECONDS = 2.0
PR_SET_CHILD_SUBREAPER = 36
FORWARDED_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)


def _read(path: str) -> str:
    """Reads a /proc file as text, tolerating non-UTF-8 thread names; empty when the task is gone."""
    try:
        with open(path, "rb") as f:
            return f.read().decode(errors="replace")
    except OSError:
        return ""


def _cpu_list(path: str) -> set[int]:
    """Parses a sysfs CPU list such as "0-15,20" into a set, or an empty set when absent."""
    cpus: set[int] = set()
    for part in filter(None, _read(path).strip().split(",")):
        first, _, last = part.partition("-")
        cpus.update(range(int(first), int(last or first) + 1))
    return cpus


def _children_map() -> dict[int, list[int]]:
    """Maps every live pid to its child pids, read from /proc/<pid>/stat."""
    children: dict[int, list[int]] = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        stat = _read(f"/proc/{entry}/stat")
        try:
            fields = stat[stat.rindex(")") + 2 :].split()
            if fields[0] == "Z":
                continue
            children.setdefault(int(fields[1]), []).append(int(entry))
        except (ValueError, IndexError):
            continue
    return children


def _process_tree(root: int) -> list[int]:
    """Lists root and every pid below it, which covers everything Steam's reaper and Proton start."""
    children = _children_map()
    found, stack = [root], [root]
    while stack:
        for child in children.get(stack.pop(), []):
            found.append(child)
            stack.append(child)
    return found


def _pin(tid: int, cpus: set[int]) -> None:
    """Sets one thread's affinity when it differs, ignoring threads that exit meanwhile."""
    try:
        if os.sched_getaffinity(tid) != cpus:
            os.sched_setaffinity(tid, cpus)
    except OSError:
        pass


def _place(root: int, p_cores: set[int], e_cores: set[int], helper_threads: re.Pattern[str]) -> None:
    """Puts helper processes and helper threads on the E-cores and every other thread on the P-cores."""
    for pid in _process_tree(root):
        helper_process = bool(HELPER_PROCESSES.search(_read(f"/proc/{pid}/cmdline").replace("\0", " ")))
        try:
            tids = os.listdir(f"/proc/{pid}/task")
        except OSError:
            continue
        for tid in tids:
            name = _read(f"/proc/{pid}/task/{tid}/comm").rstrip("\n")
            if name:
                _pin(int(tid), e_cores if helper_process or helper_threads.match(name) else p_cores)


def _become_subreaper() -> None:
    """Adopts orphaned descendants, so a game that Wine starts through a double fork stays in our tree."""
    ctypes.CDLL(None, use_errno=True).prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0)


def _forward(signum: int) -> None:
    """Passes a stop signal to the whole tree, since Proton's script dies without relaying it to Wine."""
    for pid in _process_tree(os.getpid())[1:]:
        try:
            os.kill(pid, signum)
        except OSError:
            pass


def _reap(child: int) -> int | None:
    """Collects every exited descendant and returns the direct child's wait status once it has exited."""
    while True:
        try:
            pid, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return 0
        except InterruptedError:
            continue
        if pid == 0:
            return None
        if pid == child:
            return status


def _exit_like(status: int) -> None:
    """Exits with the child's code, or dies by the same signal so Steam sees a signal exit."""
    if os.WIFSIGNALED(status):
        sig = os.WTERMSIG(status)
        signal.signal(sig, signal.SIG_DFL)
        os.kill(os.getpid(), sig)
    sys.exit(os.waitstatus_to_exitcode(status))


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__.strip() if __doc__ else "usage: game-cores <command> [args...]")
        sys.exit(0 if len(sys.argv) > 1 else 2)
    command = sys.argv[1:]
    p_cores = _cpu_list("/sys/devices/cpu_core/cpus")
    e_cores = _cpu_list("/sys/devices/cpu_atom/cpus")
    try:
        if not p_cores or not e_cores or os.environ.get("GAME_CORES", "").lower() == "off":
            os.execvp(command[0], command)
        helper_threads = re.compile(os.environ.get("GAME_CORES_HELPERS", DEFAULT_HELPER_THREADS))
        os.sched_setaffinity(0, p_cores)
        _become_subreaper()
        child = os.posix_spawnp(command[0], command, os.environ)
    except OSError as err:
        print(f"game-cores: {command[0]}: {err.strerror}", file=sys.stderr)
        sys.exit(127)
    for sig in FORWARDED_SIGNALS:
        signal.signal(sig, lambda signum, _: _forward(signum))
    while (status := _reap(child)) is None:
        _place(os.getpid(), p_cores, e_cores, helper_threads)
        time.sleep(POLL_SECONDS)
    _exit_like(status)


if __name__ == "__main__":
    main()
