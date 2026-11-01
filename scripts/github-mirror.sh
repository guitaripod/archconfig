#!/usr/bin/env bash
set -uo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

OWNER="guitaripod"
PRIMARY_MOUNT="/mnt/nvme8tb"
PRIMARY="$PRIMARY_MOUNT/github-backup"
DRIVE_MOUNT="/mnt/backup"
DRIVE_DEST="$DRIVE_MOUNT/github-mirror"
MAC_HOST="mac"
MAC_MOUNT="/Volumes/2TBMicroSD"
MAC_DEST="$MAC_MOUNT/github-mirror"
MAC_RSYNC="caffeinate -i /opt/homebrew/bin/rsync"
SENTINEL=".github-mirror"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/github-mirror"
STALE_AFTER_SECONDS=$((2 * 86400))
MIN_REPO_PERCENT=90
TARGETS=(drive mac)
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
RSYNC_COMMON=(-rt --modify-window=2 --omit-dir-times --timeout=600 "--exclude=/$SENTINEL")
BACKUP_FLAGS=(--token-from-gh --incremental --all --releases --assets --private --fork --bare --lfs --wikis
    --no-prune --throttle-limit 100 --throttle-pause 60 --retries 8)

now() { date +%s; }

stamp_get() { cat "$STATE/$1" 2>/dev/null || echo 0; }

stamp_set() { printf '%s\n' "${2:-$(now)}" > "$STATE/$1"; }

describe_age() {
    local at=$1
    (( at == 0 )) && { echo never; return; }
    echo "$(( ($(now) - at) / 3600 ))h ago"
}

# Every bare git directory under the primary: repositories, wikis and gists.
bare_repos() {
    find "$PRIMARY" -maxdepth 6 -type f -name HEAD -execdir test -d objects \; -printf '%h\n'
}

count_repos() { bare_repos | wc -l; }

# github-backup writes the GitHub token into each clone's origin URL; this strips it so the token never reaches a copy.
scrub_tokens() {
    local repo url
    while IFS= read -r repo; do
        url=$(git config --file "$repo/config" --get remote.origin.url 2>/dev/null) || continue
        [[ "$url" == *@* ]] || continue
        git config --file "$repo/config" remote.origin.url "$(sed -E 's#//[^/@]*@#//#' <<<"$url")"
    done < <(bare_repos)
}

org_names() { gh api user/orgs --paginate -q '.[].login'; }

backup_owner() {
    local owner=$1
    shift
    mkdir -p "$PRIMARY/$owner"
    github-backup "$owner" --output-directory "$PRIMARY/$owner" "${BACKUP_FLAGS[@]}" "$@"
}

# Rsync may only delete from a copy while the primary still holds nearly every repo seen at the last backup.
primary_is_intact() {
    local previous current
    previous=$(cat "$STATE/repo-count" 2>/dev/null || echo 0)
    current=$(count_repos)
    (( previous > 0 && current * 100 >= previous * MIN_REPO_PERCENT ))
}

rsync_target() {
    local dest=$1
    shift
    local prune=()
    primary_is_intact && prune=(--delete-after)
    rsync "${RSYNC_COMMON[@]}" "${prune[@]}" "$@" "$PRIMARY/" "$dest/"
}

drive_ready() { mountpoint -q "$DRIVE_MOUNT" && [[ -f "$DRIVE_DEST/$SENTINEL" ]]; }

mac_ready() { ssh "${SSH_OPTS[@]}" "$MAC_HOST" "test -f '$MAC_DEST/$SENTINEL'" 2>/dev/null; }

drive_rsync() { rsync_target "$DRIVE_DEST" "$@"; }

mac_rsync() { rsync_target "$MAC_HOST:$MAC_DEST" -e "ssh ${SSH_OPTS[*]}" --rsync-path="$MAC_RSYNC" "$@"; }

# The stamp records when the sync started, so a backup that finishes later always leaves the target behind.
sync_one() {
    local name=$1 started
    (( $(stamp_get "$name.ok") >= $(stamp_get backup.ok) )) && return 0
    if ! "${name}_ready"; then
        echo "$name: not available, skipped"
        return 0
    fi
    started=$(now)
    if "${name}_rsync"; then
        stamp_set "$name.ok" "$started"
        echo "$name: synced"
    else
        echo "$name: rsync failed, will retry" >&2
    fi
}

check_stale() {
    local name behind=0 backup_at
    backup_at=$(stamp_get backup.ok)
    for name in "${TARGETS[@]}"; do
        if (( $(stamp_get "$name.ok") < backup_at && $(now) - backup_at > STALE_AFTER_SECONDS )); then
            echo "error: $name has missed every backup for over 2 days" >&2
            behind=1
        fi
    done
    return $behind
}

verify_primary() {
    local bad
    bad=$(bare_repos | xargs -r -P 4 -I{} sh -c 'git -C "$1" fsck --no-dangling --no-progress >/dev/null 2>&1 || echo "$1"' _ {})
    [[ -z "$bad" ]] && return 0
    echo "error: git fsck failed in:" >&2
    echo "$bad" >&2
    return 1
}

# A copy that differs from a sound primary is repaired with a checksum pass, but still fails the run: it points at failing media.
verify_target() {
    local name=$1 primary_sound=$2 listing diffs
    if (( $(stamp_get "$name.ok") < $(stamp_get backup.ok) )) || ! "${name}_ready"; then
        echo "$name: not current or not available, verify skipped"
        return 0
    fi
    listing=$("${name}_rsync" --checksum --dry-run --itemize-changes) || { echo "error: $name: rsync failed during verify" >&2; return 1; }
    diffs=$(grep -v '^\.d' <<<"$listing")
    [[ -z "$diffs" ]] && { echo "$name: identical to primary"; return 0; }
    echo "error: $name differs from primary:" >&2
    head -n 10 <<<"$diffs" >&2
    (( primary_sound )) && "${name}_rsync" --checksum && echo "$name: repaired from primary" >&2
    return 1
}

cmd_backup() {
    local failed=0 orgs org
    mountpoint -q "$PRIMARY_MOUNT" || { echo "error: $PRIMARY_MOUNT is not mounted" >&2; return 1; }
    flock -w 7200 9 || { echo "error: another run holds the lock" >&2; return 1; }
    trap scrub_tokens EXIT
    backup_owner "$OWNER" --gists || failed=1
    orgs=$(org_names) || failed=1
    for org in $orgs; do
        backup_owner "$org" --organization || failed=1
    done
    scrub_tokens
    (( failed )) && return 1
    count_repos > "$STATE/repo-count"
    stamp_set backup.ok
}

cmd_sync() {
    local name
    flock -n 9 || { echo "another run is active, skipped"; return 0; }
    mountpoint -q "$PRIMARY_MOUNT" || { echo "error: $PRIMARY_MOUNT is not mounted" >&2; return 1; }
    (( $(stamp_get backup.ok) > 0 )) || { echo "no backup yet, skipped"; return 0; }
    scrub_tokens
    for name in "${TARGETS[@]}"; do
        sync_one "$name"
    done
    check_stale
}

cmd_verify() {
    local name failed=0 primary_sound=1
    flock -n 9 || { echo "another run is active, skipped"; return 0; }
    verify_primary || { failed=1; primary_sound=0; }
    for name in "${TARGETS[@]}"; do
        verify_target "$name" "$primary_sound" || failed=1
    done
    (( failed )) && return 1
    stamp_set verify.ok
}

# Creates the sentinel that marks each copy as the right, mounted volume; syncing refuses any target without it.
cmd_init() {
    mountpoint -q "$DRIVE_MOUNT" || { echo "error: $DRIVE_MOUNT is not mounted" >&2; return 1; }
    mkdir -p "$DRIVE_DEST" && touch "$DRIVE_DEST/$SENTINEL"
    ssh "${SSH_OPTS[@]}" "$MAC_HOST" \
        "mount | grep -q ' on $MAC_MOUNT ' && mkdir -p '$MAC_DEST' && touch '$MAC_DEST/$SENTINEL'" \
        || { echo "error: $MAC_MOUNT is not mounted on $MAC_HOST" >&2; return 1; }
}

cmd_status() {
    local name
    for name in backup "${TARGETS[@]}" verify; do
        printf '%-7s %s\n' "$name" "$(describe_age "$(stamp_get "$name.ok")")"
    done
    printf '%-7s %s\n' repos "$(cat "$STATE/repo-count" 2>/dev/null || echo unknown)"
}

main() {
    local cmd=${1:-status}
    mkdir -p "$STATE"
    exec 9>"$STATE/lock"
    case "$cmd" in
        backup|sync|verify|init|status) "cmd_$cmd" ;;
        *) echo "usage: github-mirror backup|sync|verify|init|status" >&2; return 2 ;;
    esac
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
