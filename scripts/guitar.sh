#!/bin/bash
set -e

SCARLETT_IN="alsa_input.usb-Focusrite_Scarlett_Solo_4th_Gen_S1JEUQQ3507881-00.pro-input-0"
SCARLETT_OUT="alsa_output.usb-Focusrite_Scarlett_Solo_4th_Gen_S1JEUQQ3507881-00.pro-output-0"

guitarix &
GX_PID=$!

echo "Waiting for Guitarix JACK ports..."
for i in $(seq 1 30); do
    if pw-link -o 2>/dev/null | grep -q "gx_head_amp:out_0"; then
        break
    fi
    sleep 0.5
done

if ! pw-link -o 2>/dev/null | grep -q "gx_head_amp:out_0"; then
    echo "Error: Guitarix ports not found"
    exit 1
fi

echo "Connecting audio routing..."
pw-link "$SCARLETT_IN:capture_AUX0" gx_head_fx:in_0 2>/dev/null || true
pw-link gx_head_fx:out_0 gx_head_amp:in_0 2>/dev/null || true
pw-link gx_head_amp:out_0 "$SCARLETT_OUT:playback_AUX0" 2>/dev/null || true
pw-link gx_head_amp:out_0 "$SCARLETT_OUT:playback_AUX1" 2>/dev/null || true

echo "Guitar rig ready. Routing:"
echo "  Scarlett In -> Guitarix FX -> Guitarix Amp -> Scarlett Out (L+R)"
echo ""
echo "NAM profiles: ~/.local/share/guitar/nam-profiles/"
echo "Cabinet IRs:  ~/.local/share/guitar/cabinet-irs/"

wait $GX_PID
