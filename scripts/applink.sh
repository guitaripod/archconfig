#!/bin/bash
set -uo pipefail

NAME="App Link"
LINKS="$HOME/.config/applink/links.tsv"
LAST="$HOME/.local/state/applink/last"
TERMINALS='ghostty|konsole|kitty|alacritty|foot|wezterm|xterm|yakuake'
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

# Start the ydotool user unit if needed and wait up to a second for its socket.
ensure_ydotoold() {
    systemctl --user is-active --quiet ydotool || systemctl --user start ydotool
    for _ in {1..20}; do
        [[ -S "$YDOTOOL_SOCKET" ]] && return 0
        sleep 0.05
    done
    return 1
}

[[ -r "$LINKS" ]] || die "Missing $LINKS"

declare -A urls labels
menu=()
while IFS=$'\t' read -r code name url; do
    [[ -z "$code" || -z "$url" ]] && continue
    urls[$code]=$url
    labels[$code]="$name   $code"
    menu+=("$code" "${labels[$code]}")
done < "$LINKS"

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
printf '%s' "$url" | wl-copy || die "wl-copy failed"

ensure_ydotoold || die "ydotoold is not running; the link is on the clipboard"
[[ -n "$window" ]] && kdotool windowactivate "$window" 2>/dev/null
sleep 0.15
ydotool key $(paste_chord "$class") >/dev/null 2>&1 || die "Paste failed; the link is on the clipboard"
