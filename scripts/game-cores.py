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


def _cpu_list(path: str) -> set[int]:
    """Parses a sysfs CPU list such as "0-15,20" into a set, or an empty set when absent."""
    try:
        text = open(path).read().strip()
    except OSError:
        return set()
    cpus: set[int] = set()
    for part in filter(None, text.split(",")):
        first, _, last = part.partition("-")
        cpus.update(range(int(first), int(last or first) + 1))
    return cpus


def _children_map() -> dict[int, list[int]]:
    """Maps every live pid to its child pids, read from /proc/<pid>/stat."""
    children: dict[int, list[int]] = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            stat = open(f"/proc/{entry}/stat").read()
        except OSError:
            continue
        fields = stat[stat.rindex(")") + 2 :].split()
        if fields[0] == "Z":
            continue
        children.setdefault(int(fields[1]), []).append(int(entry))
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


def _cmdline(pid: int) -> str:
    try:
        return open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace")
    except OSError:
        return ""


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
        helper_process = bool(HELPER_PROCESSES.search(_cmdline(pid)))
        try:
            tids = os.listdir(f"/proc/{pid}/task")
        except OSError:
            continue
        for tid in tids:
            try:
                name = open(f"/proc/{pid}/task/{tid}/comm").read().rstrip("\n")
            except OSError:
                continue
            on_e = helper_process or bool(helper_threads.match(name))
            _pin(int(tid), e_cores if on_e else p_cores)


def _become_subreaper() -> None:
    """Adopts orphaned descendants, so a game that Wine starts through a double fork stays in our tree."""
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0)


def _reap(child: int) -> int | None:
    """Collects every exited descendant and returns the direct child's exit code once it has exited."""
    while True:
        try:
            pid, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return 0
        if pid == 0:
            return None
        if pid == child:
            return os.waitstatus_to_exitcode(status)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: game-cores <command> [args...]", file=sys.stderr)
        return 2
    command = sys.argv[1:]
    p_cores = _cpu_list("/sys/devices/cpu_core/cpus")
    e_cores = _cpu_list("/sys/devices/cpu_atom/cpus")
    if not p_cores or not e_cores or os.environ.get("GAME_CORES", "").lower() == "off":
        os.execvp(command[0], command)
    helper_threads = re.compile(os.environ.get("GAME_CORES_HELPERS", DEFAULT_HELPER_THREADS))
    os.sched_setaffinity(0, p_cores)
    _become_subreaper()
    child = os.posix_spawnp(command[0], command, os.environ)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda signum, _: os.kill(child, signum))
    while (code := _reap(child)) is None:
        _place(os.getpid(), p_cores, e_cores, helper_threads)
        time.sleep(POLL_SECONDS)
    return code


if __name__ == "__main__":
    sys.exit(main())
