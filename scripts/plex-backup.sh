#!/bin/bash
set -euo pipefail

DB_DIR="/var/lib/plex/Plex Media Server/Plug-in Support/Databases"
DB_NAME="com.plexapp.plugins.library.db"
BUCKET="plex-backup"
RETENTION_DAYS=60
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

die() {
    echo "plex-backup: $*" >&2
    exit 1
}

# Copies the live database with its WAL and lets sqlite fold the WAL into one consistent file.
snapshot_library_db() {
    mkdir "$WORK/src"
    cp -- "$DB_DIR/$DB_NAME" "$DB_DIR/$DB_NAME-wal" "$DB_DIR/$DB_NAME-shm" "$WORK/src/"
    sqlite3 "$WORK/src/$DB_NAME" ".backup '$WORK/library.db'"
    rm -rf "$WORK/src"
}

# Plex's FTS tokenizer is missing from stock sqlite, so PRAGMA quick_check cannot run; a populated history table is the sanity check.
verify_snapshot() {
    local views
    views="$(sqlite3 "$WORK/library.db" 'SELECT count(*) FROM metadata_item_views')"
    [ "$views" -gt 0 ] || die "snapshot has no watch history"
}

upload_snapshot() {
    local key="$1"
    zstd -19 -T0 -q "$WORK/library.db" -o "$WORK/library.db.zst"
    wrangler r2 object put "$BUCKET/$key" --file "$WORK/library.db.zst" --content-type application/zstd --remote >/dev/null
    wrangler r2 object get "$BUCKET/$key" --file "$WORK/check.zst" --remote >/dev/null
    cmp -s "$WORK/library.db.zst" "$WORK/check.zst" || die "uploaded $key does not match the local snapshot"
}

ensure_retention_rule() {
    wrangler r2 bucket lifecycle list "$BUCKET" 2>/dev/null | grep -q 'expire-library' && return 0
    wrangler r2 bucket lifecycle add "$BUCKET" expire-library library- --expire-days "$RETENTION_DAYS" >/dev/null
}

snapshot_library_db
verify_snapshot
key="library-$(date +%F).db.zst"
upload_snapshot "$key"
ensure_retention_rule
echo "plex-backup: uploaded $BUCKET/$key"
