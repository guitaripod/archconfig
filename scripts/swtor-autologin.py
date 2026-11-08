#!/usr/bin/env python3
"""Fill in the SWTOR launcher's password and press Play, so a Steam launch needs no typing.

Steam launch options (SWTOR, appid 1286830):
    ... /home/marcus/.local/bin/swtor-autologin /home/marcus/.local/bin/game-cores mangohud obs-gamecapture %command%

The wrapper runs the launch command unchanged and forks a helper. The helper reads
SWTOR_PASSWORD from the 1Password-mounted ~/.config/swtor-autologin/.env, waits until the
launcher logs that it focused the password field, types the password into the launcher
window only (keyboard focus is checked before every key), submits, and presses Play once the
launcher leaves the login screen. Anything unexpected (1Password locked, another window
focused, a login error, an unknown screen) stops the helper and leaves the launcher to you.
Progress, never a secret, goes to ~/.local/state/swtor-autologin.log.
"""

from __future__ import annotations

import ctypes
import datetime
import os
import re
import sys
import threading
import time

ENV_FILE = os.path.expanduser("~/.config/swtor-autologin/.env")
OWN_LOG = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "swtor-autologin.log")
DEFAULT_PREFIX = "/mnt/nvme8tb/SteamLibrary/steamapps/compatdata/1286830"
LAUNCHER_LOG = "pfx/drive_c/users/steamuser/AppData/LocalLow/BioWare/Star Wars - The Old Republic Steam Launcher/host.developer.log"
READY = re.compile(r"Remembered username found, focusing on password field")
LOGGED_IN = re.compile(r"State Change Success - login -> (?!login\b)\S+")
LOGIN_FAILED = re.compile(r"(?i)bad password|invalid (credentials|password)|incorrect password|login failed")
LAUNCHED = re.compile(r"(?i)game successfully launched|user pressed play|retailclient\\swtor\.exe")
LAUNCHER_TITLE = b"Old Republic"


def _log(message: str) -> None:
    """Appends one timestamped line to the helper's own log."""
    os.makedirs(os.path.dirname(OWN_LOG), exist_ok=True)
    with open(OWN_LOG, "a") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}\n")


def _read_env(path: str, timeout: float) -> dict[str, str]:
    """Reads KEY=VALUE lines from the mounted .env, giving up when 1Password does not answer in time."""
    result: dict[str, str] = {}

    def read() -> None:
        try:
            with open(path) as f:
                for line in f:
                    key, sep, value = line.strip().partition("=")
                    if sep and key and not key.startswith("#"):
                        result[key.strip()] = value.strip().strip("'\"")
        except OSError:
            pass

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    reader.join(timeout)
    return result if not reader.is_alive() else {}


class _LogWatch:
    """Reads the launcher's debug log, keeping only lines stamped at or after `since`; the launcher rewrites the file on each start."""

    STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\.\d+([+-]\d\d)")

    def __init__(self, path: str, since: float) -> None:
        self.path = path
        self.since = since - 2

    def _stamp(self, line: str) -> float | None:
        m = self.STAMP.match(line)
        if not m:
            return None
        local = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")
        offset = datetime.timezone(datetime.timedelta(hours=int(m.group(2))))
        return local.replace(tzinfo=offset).timestamp()

    def poll(self) -> str:
        """All launcher log lines written since this launch began."""
        try:
            with open(self.path, "rb") as f:
                raw = f.read().decode(errors="replace")
        except OSError:
            return ""
        return "\n".join(line for line in raw.splitlines() if (self._stamp(line) or 0) >= self.since)

    def wait(self, pattern: re.Pattern[str], timeout: float, fail: re.Pattern[str] | None = None,
             after: str = "") -> str | None:
        """Waits for `pattern` in lines newer than `after`; returns "fail" if `fail` shows up first, None on timeout."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            text = self.poll()
            new = text[len(after):] if text.startswith(after) else text
            if fail and fail.search(new):
                return "fail"
            if pattern.search(new):
                return "ok"
            time.sleep(0.5)
        return None


class _XClassHint(ctypes.Structure):
    _fields_ = [("res_name", ctypes.c_char_p), ("res_class", ctypes.c_char_p)]


class _XWindowAttributes(ctypes.Structure):
    _fields_ = [("x", ctypes.c_int), ("y", ctypes.c_int), ("width", ctypes.c_int), ("height", ctypes.c_int),
                ("border_width", ctypes.c_int), ("depth", ctypes.c_int), ("visual", ctypes.c_void_p),
                ("root", ctypes.c_ulong), ("class_", ctypes.c_int), ("bit_gravity", ctypes.c_int),
                ("win_gravity", ctypes.c_int), ("backing_store", ctypes.c_int), ("backing_planes", ctypes.c_ulong),
                ("backing_pixel", ctypes.c_ulong), ("save_under", ctypes.c_int), ("colormap", ctypes.c_ulong),
                ("map_installed", ctypes.c_int), ("map_state", ctypes.c_int), ("all_event_masks", ctypes.c_long),
                ("your_event_mask", ctypes.c_long), ("do_not_propagate_mask", ctypes.c_long),
                ("override_redirect", ctypes.c_int), ("screen", ctypes.c_void_p)]


class _XClientMessage(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                ("format", ctypes.c_int), ("data", ctypes.c_long * 5), ("pad", ctypes.c_long * 17)]


class _X:
    """Just enough Xlib and XTest to find the launcher window, focus it and type into it."""

    IS_VIEWABLE = 2
    SHIFT_L = 0xFFE1
    RETURN = 0xFF0D

    def __init__(self) -> None:
        self.x = ctypes.CDLL("libX11.so.6")
        self.t = ctypes.CDLL("libXtst.so.6")
        x, t = self.x, self.t
        x.XOpenDisplay.restype = ctypes.c_void_p
        x.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x.XDefaultRootWindow.restype = ctypes.c_ulong
        x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        x.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
                                 ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)), ctypes.POINTER(ctypes.c_uint)]
        x.XGetClassHint.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(_XClassHint)]
        x.XFetchName.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_char_p)]
        x.XGetWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(_XWindowAttributes)]
        x.XGetInputFocus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int)]
        x.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        x.XRaiseWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        x.XInternAtom.restype = ctypes.c_ulong
        x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.POINTER(_XClientMessage)]
        x.XKeysymToKeycode.restype = ctypes.c_ubyte
        x.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        x.XKeycodeToKeysym.restype = ctypes.c_ulong
        x.XKeycodeToKeysym.argtypes = [ctypes.c_void_p, ctypes.c_ubyte, ctypes.c_int]
        x.XFlush.argtypes = [ctypes.c_void_p]
        x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        x.XFree.argtypes = [ctypes.c_void_p]
        t.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        self._ignore_errors = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)(lambda d, e: 0)
        x.XSetErrorHandler(self._ignore_errors)
        self.d = x.XOpenDisplay(None)
        if not self.d:
            raise RuntimeError("cannot open the X display")
        self.root = x.XDefaultRootWindow(self.d)

    def _children(self, win: int) -> list[int]:
        root, parent, kids, n = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.POINTER(ctypes.c_ulong)(), ctypes.c_uint()
        if not self.x.XQueryTree(self.d, win, ctypes.byref(root), ctypes.byref(parent), ctypes.byref(kids), ctypes.byref(n)):
            return []
        found = [kids[i] for i in range(n.value)]
        if kids:
            self.x.XFree(kids)
        return found

    def _parent(self, win: int) -> int:
        root, parent, kids, n = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.POINTER(ctypes.c_ulong)(), ctypes.c_uint()
        if not self.x.XQueryTree(self.d, win, ctypes.byref(root), ctypes.byref(parent), ctypes.byref(kids), ctypes.byref(n)):
            return 0
        if kids:
            self.x.XFree(kids)
        return parent.value

    def _matches(self, win: int, wm_class: bytes) -> bool:
        """True for a window of this Steam app whose title names the game, which only the launcher has before Play."""
        hint, name = _XClassHint(), ctypes.c_char_p()
        if not self.x.XGetClassHint(self.d, win, ctypes.byref(hint)) or hint.res_class != wm_class:
            return False
        if not self.x.XFetchName(self.d, win, ctypes.byref(name)) or not name.value:
            return False
        return LAUNCHER_TITLE in name.value and b"EXCLUSIVE" not in name.value

    def find_launcher(self) -> int:
        """The largest viewable window of this Steam app titled with the game's name, or 0."""
        wm_class = f"steam_app_{os.environ.get('SteamAppId', '1286830')}".encode()
        best, best_area = 0, 0
        stack = [(w, 0) for w in self._children(self.root)]
        while stack:
            win, depth = stack.pop()
            attrs = _XWindowAttributes()
            if (self._matches(win, wm_class) and self.x.XGetWindowAttributes(self.d, win, ctypes.byref(attrs))
                    and attrs.map_state == self.IS_VIEWABLE and attrs.width * attrs.height > best_area):
                best, best_area = win, attrs.width * attrs.height
            if depth < 2:
                stack.extend((c, depth + 1) for c in self._children(win))
        return best

    def focused_in(self, win: int) -> bool:
        """True when the keyboard focus is `win` or one of its descendants."""
        focus, revert = ctypes.c_ulong(), ctypes.c_int()
        self.x.XGetInputFocus(self.d, ctypes.byref(focus), ctypes.byref(revert))
        current = focus.value
        for _ in range(16):
            if current == win:
                return True
            if current in (0, 1, self.root):
                return False
            current = self._parent(current)
        return False

    def activate(self, win: int) -> bool:
        """Asks the window manager to activate `win`, then waits up to 5 s for the focus to land there."""
        if self.focused_in(win):
            return True
        event = _XClientMessage(type=33, send_event=1, display=self.d, window=win, format=32,
                                message_type=self.x.XInternAtom(self.d, b"_NET_ACTIVE_WINDOW", 0))
        event.data[0], event.data[1] = 2, 0
        self.x.XSendEvent(self.d, self.root, 0, (1 << 19) | (1 << 20), ctypes.byref(event))
        self.x.XRaiseWindow(self.d, win)
        self.x.XSync(self.d, 0)
        deadline = time.time() + 5
        while time.time() < deadline:
            if self.focused_in(win):
                return True
            time.sleep(0.1)
        return False

    def _tap(self, keysym: int) -> bool:
        keycode = self.x.XKeysymToKeycode(self.d, keysym)
        if not keycode:
            return False
        shifted = self.x.XKeycodeToKeysym(self.d, keycode, 0) != keysym and self.x.XKeycodeToKeysym(self.d, keycode, 1) == keysym
        shift = self.x.XKeysymToKeycode(self.d, self.SHIFT_L)
        if shifted:
            self.t.XTestFakeKeyEvent(self.d, shift, 1, 0)
        self.t.XTestFakeKeyEvent(self.d, keycode, 1, 0)
        self.t.XTestFakeKeyEvent(self.d, keycode, 0, 0)
        if shifted:
            self.t.XTestFakeKeyEvent(self.d, shift, 0, 0)
        self.x.XSync(self.d, 0)
        time.sleep(0.02)
        return True

    def type_into(self, win: int, text: str) -> bool:
        """Types printable ASCII into `win`, stopping before any key if the focus has moved elsewhere."""
        for ch in text:
            if not (0x20 <= ord(ch) <= 0x7E) or not self.focused_in(win) or not self._tap(ord(ch)):
                return False
        return True

    def press_return(self, win: int) -> bool:
        return self.focused_in(win) and self._tap(self.RETURN)


def _launcher_window(x: _X, timeout: float) -> int:
    """Waits for the launcher window to be mapped."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        win = x.find_launcher()
        if win:
            return win
        time.sleep(0.5)
    return 0


def _helper(started: float) -> None:
    """Logs in and presses Play, or stops and leaves the launcher to the user at the first surprise."""
    _log("started")
    secrets: dict[str, str] = {}
    reader = threading.Thread(target=lambda: secrets.update(_read_env(ENV_FILE, 60)), daemon=True)
    reader.start()
    prefix = os.environ.get("STEAM_COMPAT_DATA_PATH", DEFAULT_PREFIX)
    watch = _LogWatch(os.path.join(prefix, LAUNCHER_LOG), started)
    if watch.wait(READY, 180) != "ok":
        _log("the launcher never reached its login form; nothing typed")
        return
    reader.join(max(0.0, started + 60 - time.time()))
    password = secrets.get("SWTOR_PASSWORD", "")
    if not password:
        _log("no SWTOR_PASSWORD (1Password locked, empty value or the .env not mounted); log in by hand")
        return
    _log("login form ready, password loaded")
    x = _X()
    win = _launcher_window(x, 30)
    if not win or not x.activate(win):
        _log("could not focus the launcher window; nothing typed")
        return
    time.sleep(0.5)
    before = watch.poll()
    if not x.type_into(win, password) or not x.press_return(win):
        _log("focus left the launcher while typing (or a character has no key); stopped")
        return
    _log("password submitted")
    result = watch.wait(LOGGED_IN, 60, LOGIN_FAILED, after=before)
    if result != "ok":
        _log("login " + ("rejected" if result == "fail" else "did not finish in 60 s") + "; finish it by hand")
        return
    _log("logged in")
    time.sleep(3)
    before = watch.poll()
    win = _launcher_window(x, 10)
    if not win or not x.activate(win) or not x.press_return(win):
        _log("logged in, but could not press Play; click it yourself")
        return
    if watch.wait(LAUNCHED, 30, after=before) == "ok":
        _log("game launched")
    else:
        _log("logged in and pressed Return, but the game did not start; click Play yourself")


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__.strip() if __doc__ else "usage: swtor-autologin <command> [args...]")
        sys.exit(0 if len(sys.argv) > 1 else 2)
    started = time.time()
    if os.fork() == 0:
        os.setsid()
        try:
            _helper(started)
        except Exception as err:
            _log(f"helper failed: {type(err).__name__}: {err}")
        os._exit(0)
    try:
        os.execvp(sys.argv[1], sys.argv[1:])
    except OSError as err:
        print(f"swtor-autologin: {sys.argv[1]}: {err.strerror}", file=sys.stderr)
        sys.exit(127)


if __name__ == "__main__":
    main()
