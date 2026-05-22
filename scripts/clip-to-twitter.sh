#!/usr/bin/env bash
set -euo pipefail

src="${1:?usage: clip-to-twitter <video>}"
dst_dir="/mnt/stuff2/Clips/twitter-compatible"
mkdir -p "$dst_dir"
dst="$dst_dir/$(basename "${src%.*}").mp4"

ffmpeg -y -hide_banner -loglevel warning -stats -i "$src" \
  -c:v libx264 -profile:v high -preset slow -crf 20 -maxrate 40M -bufsize 80M -pix_fmt yuv420p \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=lanczos" \
  -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 160k \
  -movflags +faststart \
  "$dst"

echo "→ $dst"
