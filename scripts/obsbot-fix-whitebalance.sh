#!/bin/bash

VENDOR="3564"
PRODUCT="ff02"

get_video_dev() {
    for dev in /dev/video*; do
        if v4l2-ctl -d "$dev" --info 2>/dev/null | grep -q "OBSBOT"; then
            echo "$dev"
            return
        fi
    done
}

while true; do
    dev=$(get_video_dev)
    if [[ -n "$dev" ]] && fuser "$dev" 2>/dev/null | grep -qv "$$"; then
        v4l2-ctl -d "$dev" \
            --set-ctrl=white_balance_automatic=0 \
            --set-ctrl=white_balance_temperature=4800 2>/dev/null
    fi
    sleep 3
done
