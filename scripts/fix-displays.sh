#!/usr/bin/env bash
# Restore the arch three-screen layout: Odyssey Ark portrait on the left, LG TV
# to its right, LG UltraGear+ right of that, Remote Play dummy off.
#
# Connector names drift when the MST hub or GPU link comes up, so each display is
# identified by its EDID description from wayland-info, and every screen gets the
# highest 3840x2160 refresh it currently offers (Ark 165, UltraGear+ 144, TV 144
# once HDMI Deep Colour gives it back 4K144).
set -euo pipefail

export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"

declare -A connector_of=(
  ["Samsung Electric Company Odyssey Ark"]="DP-4"
  ["LG Electronics LG TV SSCR2"]="DP-1"
  ["LG Electronics LG ULTRAGEAR+"]="DP-3"
)

declare -A position_of=(
  ["Samsung Electric Company Odyssey Ark"]="0,0"
  ["LG Electronics LG TV SSCR2"]="2160,1961"
  ["LG Electronics LG ULTRAGEAR+"]="6000,2479"
)

declare -A priority_of=(
  ["LG Electronics LG TV SSCR2"]="1"
  ["Samsung Electric Company Odyssey Ark"]="2"
  ["LG Electronics LG ULTRAGEAR+"]="3"
)

declare -A max_refresh_of=(
  ["LG Electronics LG TV SSCR2"]="144"
  ["Samsung Electric Company Odyssey Ark"]="165"
  ["LG Electronics LG ULTRAGEAR+"]="144"
)

dummy_connector() {
  wayland-info 2>/dev/null | awk "
    /^[[:space:]]*name: '/ { conn = \$2; gsub(/'/, \"\", conn) }
    /^[[:space:]]*description: '/ {
      desc = \$0
      sub(/.*description: '/, \"\", desc)
      sub(/'.*/, \"\", desc)
      if (desc ~ /Dummy/) print conn
    }
  "
}

describe() {
  wayland-info 2>/dev/null | awk "
    /^[[:space:]]*name: '/ { conn = \$2; gsub(/'/, \"\", conn) }
    /^[[:space:]]*description: '/ {
      desc = \$0
      sub(/.*description: '/, \"\", desc)
      sub(/'.*/, \"\", desc)
      print conn \"|\" desc
    }
  "
}

best_4k_mode() {
  kscreen-doctor -o 2>&1 | sed 's/\x1b\[[0-9;]*m//g' |
    awk -v want="$1" -v ceiling="$2" '
      /^Output: / { conn = $3; next }
      /Modes:/ && conn == want {
        line = $0
        sub(/.*Modes: */, "", line)
        n = split(line, parts, /[[:space:]]+/)
        for (i = 1; i <= n; i++) {
          gsub(/[*!]/, "", parts[i])
          if (match(parts[i], /^([0-9]+):3840x2160@([0-9.]+)$/, m)) {
            if (m[2] + 0 > best && m[2] + 0 <= ceiling + 0.5) { best = m[2] + 0; idx = m[1] }
          }
        }
      }
      END { if (idx != "") print idx }'
}

# Puts the UltraGear+ on its factory-calibrated 6500K colour preset (D65) instead of hand-tuned User gains.
restore_ultragear_white_balance() {
  ddcutil --sn 511NTZNF9973 setvcp 14 0x05 2>/dev/null ||
    echo "UltraGear+ white balance not applied: DDC/CI unreachable" >&2
}

layout=(output.DP-2.disable)

for connector in $(dummy_connector); do
  layout[0]="output.$connector.disable"
done

while IFS='|' read -r connector description; do
  name="${connector_of[$description]:-}"
  [[ -n "$name" ]] || continue
  layout+=("output.$name.enable" "output.$name.position.${position_of[$description]}" "output.$name.priority.${priority_of[$description]}")
  mode="$(best_4k_mode "$name" "${max_refresh_of[$description]:-144}")"
  [[ -n "$mode" ]] && layout+=("output.$name.mode.$mode")
  [[ "$description" == "LG Electronics LG TV SSCR2" ]] && tv="$name"
done < <(describe)

kscreen-doctor "${layout[@]}" >/dev/null

sleep 1

tv_args=("output.$tv.hdr.disable" "output.$tv.wcg.enable")
tv_mode="$(best_4k_mode "$tv" "${max_refresh_of["LG Electronics LG TV SSCR2"]}")"
[[ -n "$tv_mode" ]] && tv_args+=("output.$tv.mode.$tv_mode")
kscreen-doctor "${tv_args[@]}" >/dev/null

sleep 1

"$HOME/.local/bin/kscreen-gamut" "$tv" 0.6

restore_ultragear_white_balance

kscreen-doctor -o 2>&1 | sed 's/\x1b\[[0-9;]*m//g' |
  awk '/^Output: / { conn = $3; state = ""; mode = ""; next }
       /^[[:space:]]*(enabled|disabled)$/ { state = $1 }
       /Modes:/ {
         line = $0
         sub(/.*Modes: */, "", line)
         n = split(line, parts, /[[:space:]]+/)
         for (i = 1; i <= n; i++) if (parts[i] ~ /\*/) { mode = parts[i]; sub(/^[0-9]+:/, "", mode); gsub(/[*!]/, "", mode) }
       }
       /Geometry:/ { printf "%-5s %-9s %-16s %s %s %s\n", conn, state, mode == "" ? "-" : mode, $2, $3, $4 }'
