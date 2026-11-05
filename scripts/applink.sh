#!/bin/bash
set -uo pipefail

NAME="App Link"
LINKS="$HOME/.config/applink/links.tsv"
LAST="$HOME/.local/state/applink/last"
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

[[ -r "$LINKS" ]] || die "Missing $LINKS"

declare -A urls labels
menu=()
bad=()
n=0
while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    [[ -z "$line" ]] && continue
    IFS=$'\t' read -r code name url extra <<<"$line"
    if [[ -z "$code" || -z "$name" || "$url" != https://* || -n "$extra" || "$line" == *$'\t\t'* ]]; then
        bad+=("$n")
        continue
    fi
    urls[$code]=$url
    labels[$code]="$name   $code"
    menu+=("$code" "${labels[$code]}")
done < "$LINKS"

[[ ${#bad[@]} -gt 0 ]] && notify-send -a "$NAME" "$NAME" "Skipped malformed lines in $LINKS: ${bad[*]}"
[[ ${#menu[@]} -gt 0 ]] || die "No links in $LINKS"

window=$(kdotool getactivewindow 2>/dev/null || true)
class=""
[[ -n "$window" ]] && class=$(kdotool getwindowclassname "$window" 2>/dev/null || true)

last=$(cat "$LAST" 2>/dev/null || true)
default=${labels[${last:-none}]:-${menu[1]}}

choice=$(kdialog --title "$NAME" --default "$default" --menu "Paste the App Store link for:" "${menu[@]}" 2>/dev/null) || exit 0
url=${urls[$choice]:-}
[[ -n "$url" ]] || exit 0

mkdir -p "${LAST%/*}"
printf '%s\n' "$choice" > "$LAST"
printf '%s' "$url" | wl-copy 9>&- || die "wl-copy failed"

[[ -n "$window" ]] || { notify-send -a "$NAME" "$NAME" "No focused window to paste into; the link is on the clipboard"; exit 0; }
ensure_ydotoold || die "ydotoold is not running; the link is on the clipboard"
focus_window "$window" || die "The window you were in is gone; the link is on the clipboard"
sleep 0.1
ydotool key $(paste_chord "$class") >/dev/null 2>&1 || die "Paste failed; the link is on the clipboard"
