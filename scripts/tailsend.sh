#!/bin/bash
set -uo pipefail

NAME="Tailsend"

notify_ok()   { notify-send -a "$NAME" "$@"; }
notify_err()  { notify-send -a "$NAME" -u critical "$@"; }
die()         { notify_err "$NAME" "$1"; exit 1; }

collect_clipboard() {
    local types
    types=$(wl-paste --list-types 2>/dev/null) || die "Clipboard is empty"

    local image_mime
    image_mime=$(grep -m1 '^image/' <<<"$types" || true)

    if [[ -n "$image_mime" ]]; then
        local ext="${image_mime#image/}"
        [[ "$ext" == "jpeg" ]] && ext="jpg"
        local tmp
        tmp=$(mktemp --suffix=".$ext" -t tailsend-XXXXXX)
        wl-paste -t "$image_mime" >"$tmp" || die "Failed to read clipboard image"
        printf '%s\n' "$tmp"
        return
    fi

    if grep -q '^text/uri-list' <<<"$types"; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            line="${line%$'\r'}"
            local path="${line#file://}"
            path=$(printf '%b' "${path//%/\\x}")
            [[ -e "$path" ]] && printf '%s\n' "$path"
        done < <(wl-paste -t text/uri-list 2>/dev/null)
        return
    fi

    die "Clipboard has no image or files"
}

files=()
if [[ $# -gt 0 ]]; then
    for f in "$@"; do
        [[ -e "$f" ]] || die "Not found: $f"
        files+=("$f")
    done
else
    while IFS= read -r line; do
        files+=("$line")
    done < <(collect_clipboard)
fi

[[ ${#files[@]} -gt 0 ]] || die "Nothing to send"

mapfile -t peers < <(
    tailscale status --json | jq -r '
        .Peer // {}
        | to_entries
        | map(.value)
        | map(select(.Online == true and (.OS // "") != ""))
        | sort_by(.DNSName)
        | .[] | "\((.DNSName | split("."))[0])\t\(.OS)"
    '
)

[[ ${#peers[@]} -gt 0 ]] || die "No online Tailscale peers"

dialog_args=()
for entry in "${peers[@]}"; do
    host="${entry%%$'\t'*}"
    os="${entry#*$'\t'}"
    dialog_args+=("$host" "$host ($os)" off)
done
dialog_args[2]=on

count=${#files[@]}
title="$NAME — $count file$([[ $count -ne 1 ]] && echo s)"

target=$(kdialog --title "$title" --radiolist "Send to:" "${dialog_args[@]}" 2>/dev/null) || exit 0
[[ -n "$target" ]] || exit 0

if tailscale file cp "${files[@]}" "$target:" 2>/tmp/tailsend.err; then
    summary="Sent $count file$([[ $count -ne 1 ]] && echo s) to $target"
    notify_ok "$NAME" "$summary"
else
    err=$(< /tmp/tailsend.err)
    notify_err "$NAME → $target failed" "${err:-unknown error}"
    exit 1
fi
