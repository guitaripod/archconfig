#!/bin/bash
current=$(asusctl profile get | grep "Active profile" | cut -d: -f2 | tr -d ' ')
if [[ "$current" == "Performance" ]]; then
    asusctl profile set Quiet
else
    asusctl profile set Performance
fi
