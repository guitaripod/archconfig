#!/bin/bash
set -euo pipefail

BUCKET="state-backup"
MANIFEST="${STATE_BACKUP_MANIFEST:-$HOME/.config/state-backup/sources}"
STATE_DIR="$HOME/.local/state/state-backup"
DAILY_RETENTION_DAYS=30
MONTHLY_RETENTION_DAYS=365
WORK="$(mktemp -d)"
STAGE="$WORK/stage"
missing=0
trap 'rm -rf "$WORK"' EXIT

die() {
    echo "state-backup: $*" >&2
    exit 1
}

warn_missing() {
    echo "state-backup: missing source $1" >&2
    missing=$((missing + 1))
}

expand_home() {
    echo "${1/#\~/$HOME}"
}

# Reads the live database through a read-only connection so the WAL is folded into one consistent file.
snapshot_sqlite() {
    local label="$1" src="$2" out="$STAGE/sqlite/$1.db"
    if [ ! -f "$src" ]; then
        warn_missing "$src"
        return
    fi
    mkdir -p "$STAGE/sqlite"
    sqlite3 "file:$src?mode=ro" ".backup '$out'"
    sqlite3 "$out" 'SELECT count(*) FROM sqlite_master' >/dev/null || die "snapshot of $label is unreadable"
}

# Copies every match of a path or glob under $HOME, keeping its path relative to $HOME so a restore extracts straight back.
snapshot_files() {
    local pattern="$1" match found=0
    case "$pattern" in
        "$HOME"/*) ;;
        *) die "copy source must live under \$HOME: $pattern" ;;
    esac
    mkdir -p "$STAGE/files"
    while IFS= read -r match; do
        found=1
        (cd "$HOME" && cp -a --parents -- "${match#"$HOME"/}" "$STAGE/files/")
    done < <(compgen -G "$pattern" || true)
    [ "$found" -eq 1 ] || warn_missing "$pattern"
}

stage_sources() {
    local kind a b
    mkdir -p "$STAGE"
    while IFS=$'\t' read -r kind a b; do
        [[ -z "$kind" ]] && continue
        case "$kind" in
            sqlite) snapshot_sqlite "$a" "$(expand_home "$b")" ;;
            copy) snapshot_files "$(expand_home "$a")" ;;
            *) die "unknown source kind '$kind' in $MANIFEST" ;;
        esac
    done < "$MANIFEST"
}

# Uploads, downloads the object again and compares, so a truncated upload never passes.
upload_verified() {
    local key="$1" file="$2"
    wrangler r2 object put "$BUCKET/$key" --file "$file" --content-type application/zstd --remote >/dev/null
    wrangler r2 object get "$BUCKET/$key" --file "$WORK/check.zst" --remote >/dev/null
    cmp -s "$file" "$WORK/check.zst" || die "uploaded $key does not match the local archive"
    rm -f "$WORK/check.zst"
}

# Keeps one archive per month beyond the daily window; the marker file makes a missed first of the month still produce one.
upload_monthly_if_due() {
    local month marker="$STATE_DIR/last-monthly"
    month="$(date +%Y-%m)"
    [ "$(cat "$marker" 2>/dev/null || true)" = "$month" ] && return 0
    upload_verified "monthly/state-$month.tar.zst" "$1"
    mkdir -p "$STATE_DIR"
    echo "$month" > "$marker"
}

ensure_retention_rule() {
    local name="$1" prefix="$2" days="$3"
    wrangler r2 bucket lifecycle list "$BUCKET" 2>/dev/null | grep -q "^name: *$name\$" && return 0
    wrangler r2 bucket lifecycle add "$BUCKET" "$name" "$prefix" --expire-days "$days" >/dev/null
}

run_backup() {
    local archive="$WORK/state.tar.zst" today
    [ -f "$MANIFEST" ] || die "manifest $MANIFEST not found"
    today="$(date +%F)"
    stage_sources
    tar -C "$STAGE" -cf - . | zstd -19 -T0 -q -o "$archive"
    upload_verified "daily/state-$today.tar.zst" "$archive"
    upload_monthly_if_due "$archive"
    ensure_retention_rule expire-daily daily/ "$DAILY_RETENTION_DAYS"
    ensure_retention_rule expire-monthly monthly/ "$MONTHLY_RETENTION_DAYS"
    echo "state-backup: uploaded $BUCKET/daily/state-$today.tar.zst ($(du -h "$archive" | cut -f1))"
    [ "$missing" -eq 0 ] || die "$missing source(s) missing, see above"
}

# Downloads the key for a date into $1 and prints its path, or returns 1 if that day has no archive.
fetch_archive() {
    local key="$1" file="$2"
    wrangler r2 object get "$BUCKET/$key" --file "$file" --remote >/dev/null 2>&1 && [ -s "$file" ]
}

# Resolves "latest", YYYY-MM-DD or YYYY-MM to an archive on disk.
fetch_for() {
    local when="$1" file="$2" offset day
    case "$when" in
        latest)
            for offset in $(seq 0 "$DAILY_RETENTION_DAYS"); do
                day="$(date -d "-$offset days" +%F)"
                fetch_archive "daily/state-$day.tar.zst" "$file" && { echo "$day"; return 0; }
            done
            return 1
            ;;
        ????-??-??) fetch_archive "daily/state-$when.tar.zst" "$file" && echo "$when" ;;
        ????-??) fetch_archive "monthly/state-$when.tar.zst" "$file" && echo "$when" ;;
        *) die "restore takes latest, YYYY-MM-DD or YYYY-MM" ;;
    esac
}

# Extracts into a fresh directory and never touches live data; copy files back from there by hand.
run_restore() {
    local when="${1:-latest}" dest label
    label="$(fetch_for "$when" "$WORK/restore.tar.zst")" || die "no archive found for $when"
    dest="${2:-$HOME/state-restore-$label}"
    mkdir -p "$dest"
    zstd -dc "$WORK/restore.tar.zst" | tar -C "$dest" -xf -
    echo "state-backup: restored $label into $dest (sqlite/<name>.db are databases, files/ mirrors \$HOME)"
}

case "${1:-run}" in
    run) run_backup ;;
    restore) run_restore "${2:-latest}" "${3:-}" ;;
    *) die "usage: state-backup [run | restore [latest|YYYY-MM-DD|YYYY-MM] [dest]]" ;;
esac
