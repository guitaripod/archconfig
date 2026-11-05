#!/bin/bash
set -uo pipefail

NAME="App Link"
LOCK="${XDG_RUNTIME_DIR:-/tmp}/applink.lock"
TERMINALS='^([a-z0-9-]+\.)*(ghostty|konsole|yakuake|kitty|alacritty|foot|footclient|wezterm)$'
export YDOTOOL_SOCKET="/run/user/$(id -u)/.ydotool_socket"

die() { notify-send -a "$NAME" -u critical "$NAME" "$1"; exit 1; }

# Ctrl+Shift+V for terminals, Ctrl+V everywhere else, as ydotool keycodes.
paste_chord() {
    if [[ "${1,,}" =~ $TERMINALS ]]; then
        echo 29:1 42:1 47:1 47:0 42:0 29:0
    else
        echo 29:1 47:1 47:0 29:0
    fi
}

# Activate the window the picker was opened over and wait up to half a second for KWin to report it active.
focus_window() {
    kdotool windowactivate "$1" 2>/dev/null
    for _ in {1..10}; do
        [[ "$(kdotool getactivewindow 2>/dev/null)" == "$1" ]] && return 0
        sleep 0.05
    done
    return 1
}

# Start the ydotool user unit if needed and wait up to a second for its socket.
ensure_ydotoold() {
    systemctl --user is-active --quiet ydotool || systemctl --user start ydotool
    for _ in {1..20}; do
        [[ -S "$YDOTOOL_SOCKET" ]] && return 0
        sleep 0.05
    done
    return 1
}

exec 9>"$LOCK"
flock -n 9 || exit 0

window=$(kdotool getactivewindow 2>/dev/null || true)
class=""
[[ -n "$window" ]] && class=$(kdotool getwindowclassname "$window" 2>/dev/null || true)

url=$("${BASH_SOURCE[0]%/*}/applink-picker") || exit 0
[[ -n "$url" ]] || exit 0

printf '%s' "$url" | wl-copy 9>&- || die "wl-copy failed"

[[ -n "$window" ]] || { notify-send -a "$NAME" "$NAME" "No focused window to paste into; the link is on the clipboard"; exit 0; }
ensure_ydotoold || die "ydotoold is not running; the link is on the clipboard"
focus_window "$window" || die "The window you were in is gone; the link is on the clipboard"
sleep 0.1
ydotool key $(paste_chord "$class") >/dev/null 2>&1 || die "Paste failed; the link is on the clipboard"
