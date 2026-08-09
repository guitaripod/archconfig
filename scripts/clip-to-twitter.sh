#!/usr/bin/env bash
set -euo pipefail

: "${1:?usage: clip-to-twitter <video> [more videos...]}"

MAX_DIMENSION=3840
MAX_FPS=60

probe() {
	ffprobe -v error -select_streams "$1" -show_entries "$2" \
		-of default=nw=1:nk=1 "$3" 2>/dev/null | head -1
}

## X ingests H.264 in yuv420p with AAC audio and nothing else — it accepts an
## AV1 or Opus upload and then fails to process it. Everything below 4K/60 is
## preserved at source resolution; Marcus has verified X serves 4K intact.
video_is_compliant() {
	local file=$1 codec pix range width height fps
	codec=$(probe v:0 stream=codec_name "$file")
	pix=$(probe v:0 stream=pix_fmt "$file")
	range=$(probe v:0 stream=color_range "$file")
	width=$(probe v:0 stream=width "$file")
	height=$(probe v:0 stream=height "$file")
	fps=$(source_fps "$file")

	[[ $codec == h264 && $pix == yuv420p ]] || return 1
	[[ $range == tv || $range == unknown || -z $range ]] || return 1
	[[ -n $width && -n $height ]] || return 1
	((width <= MAX_DIMENSION && height <= MAX_DIMENSION)) || return 1
	((width % 2 == 0 && height % 2 == 0)) || return 1
	((fps <= MAX_FPS)) || return 1
}

audio_is_compliant() {
	local file=$1 codec channels
	codec=$(probe a:0 stream=codec_name "$file")
	[[ $codec == aac ]] || return 1
	channels=$(probe a:0 stream=channels "$file")
	[[ -n $channels ]] && ((channels <= 2))
}

has_audio() {
	[[ -n $(probe a:0 stream=codec_name "$1") ]]
}

## avg_frame_rate is the only trustworthy rate on a gpu-screen-recorder capture:
## its VFR files advertise r_frame_rate=1000000/1, which would make any naive
## `-r` derivation explode the output.
source_fps() {
	local rate num den
	rate=$(probe v:0 stream=avg_frame_rate "$1")
	[[ $rate == */* ]] || { echo 0; return; }
	num=${rate%/*}
	den=${rate#*/}
	((den == 0)) && { echo 0; return; }
	echo $((num / den))
}

target_fps() {
	local fps
	fps=$(source_fps "$1")
	((fps <= 0 || fps > MAX_FPS)) && fps=$MAX_FPS
	echo "$fps"
}

convert() {
	local src=$1 dst=$2
	local -a args=(-y -hide_banner -loglevel warning -stats -i "$src")

	if video_is_compliant "$src"; then
		args+=(-c:v copy)
	else
		args+=(
			-vf "scale=w='min(iw,$MAX_DIMENSION)':h='min(ih,$MAX_DIMENSION)':force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos:in_range=auto:out_range=tv"
			-fps_mode cfr -r "$(target_fps "$src")"
			-c:v libx264 -profile:v high -preset slow -crf 20
			-maxrate 40M -bufsize 80M -pix_fmt yuv420p
			-color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709
		)
	fi

	if ! has_audio "$src"; then
		args+=(-an)
	elif audio_is_compliant "$src"; then
		args+=(-c:a copy)
	else
		args+=(-c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 160k)
	fi

	args+=(-movflags +faststart "$dst")
	ffmpeg "${args[@]}"
}

## Every clip collects in one directory so a capture, a download and a manual
## conversion all end up somewhere predictable. When the conversion would land
## on its own input — a clip already in that directory that only needs a codec
## fix — it encodes to a sibling and swaps, so a failed or interrupted run
## leaves the original intact.
for src in "$@"; do
	[[ -s $src ]] || { echo "clip-to-twitter: no such file: $src" >&2; exit 1; }

	dst_dir="${CLIP_TWITTER_DIR:-/mnt/nvme8tb/Clips}"
	mkdir -p "$dst_dir"
	dst="$dst_dir/$(basename "${src%.*}").mp4"

	if [[ $(realpath -m "$src") == "$(realpath -m "$dst")" ]]; then
		tmp="$dst_dir/.$(basename "${src%.*}").twitter.mp4"
		convert "$src" "$tmp"
		mv -f "$tmp" "$dst"
	else
		convert "$src" "$dst"
	fi
	echo "→ $dst"
done
