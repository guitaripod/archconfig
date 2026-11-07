#!/usr/bin/env bash
# hdr-game: switch a display to HDR for as long as a game runs, then back.
#
#   Steam launch options:  hdr-game %command%
#                          hdr-game mangohud obs-gamecapture %command%
#
# The desktop stays SDR. On launch the primary output (or $HDR_GAME_OUTPUT, a connector name)
# goes to HDR and the game gets Wine's Wayland driver with HDR on; when the game's process
# ends, however it ends, the output goes back to the state it had. Several games share one
# switch-on. `hdr-game --restore` (run at login) undoes a switch whose game died with the session.
set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hdr-game"
SELF="$(readlink -f "$0")"

# Logs to stderr and the journal (`journalctl -t hdr-game`).
say() {
  printf 'hdr-game: %s\n' "$*" >&2
  logger -t hdr-game -- "$*" 2>/dev/null || true
}

# kscreen-doctor can stall until the screen redraws after a mode change, so it never gets long.
kscreen() {
  timeout 15 kscreen-doctor "$@" 2>/dev/null
}

# Prints "<hdr> <wcg>" (true/false) for a connector, or nothing when it is not connected.
output_flags() {
  kscreen -j | python3 -c '
import json, sys
for o in json.load(sys.stdin)["outputs"]:
    if o["name"] == sys.argv[1] and o.get("connected"):
        print(str(o.get("hdr", False)).lower(), str(o.get("wcg", False)).lower())
' "$1"
}

# The connector to switch: $HDR_GAME_OUTPUT, else the enabled output with the top priority,
# which is the primary that fullscreen games open on.
target_output() {
  if [[ -n "${HDR_GAME_OUTPUT:-}" ]]; then
    printf '%s\n' "$HDR_GAME_OUTPUT"
    return
  fi
  kscreen -j | python3 -c '
import json, sys
outs = [o for o in json.load(sys.stdin)["outputs"] if o.get("enabled") and o.get("connected")]
if outs:
    print(min(outs, key=lambda o: o.get("priority") or 99)["name"])
'
}

# KScreen's stable id for the monitor behind a connector; connector names drift between boots.
output_uuid() {
  kscreen -o | sed 's/\x1b\[[0-9;]*m//g' | awk -v c="$1" '$1 == "Output:" && $3 == c { print $4 }'
}

# The connector a monitor id sits on now.
connector_of() {
  kscreen -o | sed 's/\x1b\[[0-9;]*m//g' | awk -v u="$1" '$1 == "Output:" && $4 == u { print $3 }'
}

# Switches HDR and wide colour gamut together, as System Settings' HDR switch does (HDR alone
# leaves KWin grey-green), and waits until KWin reports the new state.
set_flags() {
  local output=$1 hdr=$2 wcg=$3 want="$2 $3" i
  [[ "$(output_flags "$output")" == "$want" ]] && return 0
  kscreen "output.$output.hdr.$(verb "$hdr")" "output.$output.wcg.$(verb "$wcg")" >/dev/null
  for i in $(seq 50); do
    [[ "$(output_flags "$output")" == "$want" ]] && return 0
    sleep 0.1
  done
  return 1
}

verb() {
  [[ "$1" == true ]] && echo enable || echo disable
}

# A process identity that survives pid reuse: "<pid>-<start time in clock ticks>".
process_id() {
  local stat
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  stat=${stat##*) }
  printf '%s-%s\n' "$1" "$(awk '{ print $20 }' <<<"$stat")"
}

alive() {
  [[ "$(process_id "${1%%-*}")" == "$1" ]]
}

# Drops the session marks of games that are gone and says whether any game still holds the monitor.
held() {
  local dir="$STATE_DIR/$1.sessions" mark
  for mark in "$dir"/*; do
    [[ -e "$mark" ]] || continue
    alive "$(basename "$mark")" || rm -f "$mark"
  done
  compgen -G "$dir/*" >/dev/null
}

with_lock() {
  mkdir -p "$STATE_DIR"
  exec 9>"$STATE_DIR/lock"
  flock 9
  "$@"
  local status=$?
  exec 9>&-
  return $status
}

# Marks the game as holding the monitor; the first holder records the state to return to and switches HDR on.
acquire() {
  local output=$1 uuid=$2 session=$3 prior
  if ! held "$uuid" && [[ ! -f "$STATE_DIR/$uuid.prior" ]]; then
    prior=$(output_flags "$output")
    [[ -n "$prior" ]] || { say "output $output is not connected"; return 1; }
    printf '%s\n' "$prior" >"$STATE_DIR/$uuid.prior"
  fi
  mkdir -p "$STATE_DIR/$uuid.sessions"
  : >"$STATE_DIR/$uuid.sessions/$session"
  set_flags "$output" true true || say "KWin did not switch $output to HDR"
}

# Puts the monitor back to its recorded state once no game holds it.
restore() {
  local uuid=$1 output prior
  held "$uuid" && return 0
  [[ -f "$STATE_DIR/$uuid.prior" ]] || return 0
  output=$(connector_of "$uuid")
  if [[ -z "$output" ]]; then
    say "monitor $uuid is not connected; keeping its saved state for the next --restore"
    return 0
  fi
  read -r prior_hdr prior_wcg <"$STATE_DIR/$uuid.prior"
  if set_flags "$output" "$prior_hdr" "$prior_wcg"; then
    rm -f "$STATE_DIR/$uuid.prior"
    rmdir "$STATE_DIR/$uuid.sessions" 2>/dev/null
  else
    say "KWin did not put $output back to hdr=$prior_hdr wcg=$prior_wcg"
  fi
}

release() {
  local uuid=$1 session=$2
  rm -f "$STATE_DIR/$uuid.sessions/$session"
  restore "$uuid"
}

restore_all() {
  local prior
  for prior in "$STATE_DIR"/*.prior; do
    [[ -e "$prior" ]] || continue
    restore "$(basename "$prior" .prior)"
  done
}

# Waits for the game outside its process tree, so Steam's Stop (which kills the whole tree) or a
# crash still ends in a restore.
guard() {
  local uuid=$1 session=$2
  while alive "$session"; do sleep 1; done
  with_lock release "$uuid" "$session"
}

# The Proton script in the command line, if the game runs through Proton.
proton_of() {
  local argument
  for argument in "$@"; do
    [[ "$argument" == */proton ]] && { printf '%s\n' "$argument"; return; }
  done
}

# Valve's Proton has no Wayland driver, so its games render through Xwayland and never get an
# HDR swapchain; switching the display for them only washes the picture out.
proton_reaches_hdr() {
  compgen -G "$(dirname "$1")/files/lib/wine/x86_64-unix/winewayland.so" >/dev/null
}

case "${1:-}" in
  --guard) shift; guard "$@"; exit ;;
  --restore) with_lock restore_all; exit ;;
  ""|-h|--help) sed -n '2,10p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

proton=$(proton_of "$@")
if [[ -n "$proton" ]] && ! proton_reaches_hdr "$proton"; then
  say "$(basename "$(dirname "$proton")") has no Wayland driver, so no HDR; pick GE-Proton for this game. Starting it in SDR."
  exec "$@"
fi

output=$(target_output)
uuid=$(output_uuid "$output")
session=$(process_id $$)
if [[ -z "$output" || -z "$uuid" ]]; then
  say "no output to switch (HDR_GAME_OUTPUT=${HDR_GAME_OUTPUT:-unset}); starting in SDR"
  exec "$@"
fi

if with_lock acquire "$output" "$uuid" "$session"; then
  systemd-run --user --quiet --collect --unit="hdr-game-guard-${session}" \
    -E WAYLAND_DISPLAY -E XDG_RUNTIME_DIR \
    "$SELF" --guard "$uuid" "$session" ||
    say "could not start the guard; HDR on $output stays on until 'hdr-game --restore'"
fi

if [[ -n "$proton" ]]; then
  export PROTON_ENABLE_WAYLAND="${PROTON_ENABLE_WAYLAND:-1}"
  export PROTON_ENABLE_HDR="${PROTON_ENABLE_HDR:-1}"
fi
exec "$@"
