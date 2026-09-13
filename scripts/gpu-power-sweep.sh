#!/usr/bin/env bash
# Measures decode speed and board power at a series of GPU power limits, so the cap can be picked from the
# efficiency curve rather than guessed. Run as root (nvidia-smi -pl needs it); restores the starting limit.
set -euo pipefail

MODEL="${MODEL:-sglang-muse30b}"
SWAP_URL="${SWAP_URL:-http://127.0.0.1:8081}"
TOKENS="${TOKENS:-768}"
REPS="${REPS:-3}"
LIMITS=("${@:-600 550 500 450 400 350}")
read -r -a LIMITS <<< "${LIMITS[*]}"

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0 ${LIMITS[*]}" >&2; exit 1; }
command -v jq >/dev/null || { echo "needs jq" >&2; exit 1; }

ORIGINAL=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits | cut -d. -f1)
restore() { nvidia-smi -pl "$ORIGINAL" >/dev/null 2>&1 || true; }
trap restore EXIT

prompt='Write a detailed technical explanation of how a modern out-of-order CPU core executes instructions, covering register renaming, the reorder buffer and branch prediction.'

generate() {
  curl -s --max-time 600 "$SWAP_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$(jq -n \
    --arg model "$MODEL" --arg prompt "$prompt" --argjson tokens "$TOKENS" \
    '{model: $model, messages: [{role: "user", content: $prompt}], max_tokens: $tokens, temperature: 0, stream: false}')"
}

echo "Model $MODEL, $TOKENS tokens, $REPS reps per limit. Starting limit ${ORIGINAL} W."
printf '%6s  %10s  %8s  %10s  %9s\n' "limit" "tok/s" "watts" "tok/J" "vs 1st"
generate >/dev/null

first_tps=
for limit in "${LIMITS[@]}"; do
  nvidia-smi -pl "$limit" >/dev/null
  sleep 2
  best_tps=0 watts=0
  for ((rep = 0; rep < REPS; rep++)); do
    samples=$(mktemp)
    nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits -lms 200 > "$samples" &
    sampler=$!
    start=$(date +%s.%N)
    body=$(generate)
    end=$(date +%s.%N)
    kill "$sampler" 2>/dev/null || true
    wait "$sampler" 2>/dev/null || true
    completion=$(jq -r '.usage.completion_tokens // 0' <<< "$body")
    seconds=$(echo "$end - $start" | bc -l)
    tps=$(echo "$completion / $seconds" | bc -l)
    mean=$(awk '$1 > 100 { total += $1; count++ } END { print (count ? total / count : 0) }' "$samples")
    rm -f "$samples"
    (( $(echo "$tps > $best_tps" | bc -l) )) && { best_tps=$tps; watts=$mean; }
  done
  first_tps=${first_tps:-$best_tps}
  printf '%5sW  %10.1f  %8.0f  %10.3f  %8.1f%%\n' "$limit" "$best_tps" "$watts" \
    "$(echo "if ($watts > 0) $best_tps / $watts else 0" | bc -l)" \
    "$(echo "100 * $best_tps / $first_tps" | bc -l)"
done

echo
echo "Pick the lowest limit still within ~3% of the fastest row, then set it for good:"
echo "  sudo install -m644 ~/dotfiles/etc/systemd/system/nvidia-power-limit.service /etc/systemd/system/"
echo "  sudo systemctl enable --now nvidia-power-limit.service"
