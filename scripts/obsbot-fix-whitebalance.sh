#!/bin/bash

sleep 2

for dev in /dev/video*; do
    if v4l2-ctl -d "$dev" --info 2>/dev/null | grep -q "OBSBOT"; then
        v4l2-ctl -d "$dev" \
            --set-ctrl=white_balance_automatic=0 \
            --set-ctrl=white_balance_temperature=4800 \
            --set-ctrl=hue=50 \
            --set-ctrl=saturation=50 2>/dev/null
        break
    fi
done
