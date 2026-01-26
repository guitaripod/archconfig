#!/bin/bash
current=$(asusctl profile get | grep "Active" | awk '{print $3}')
if [ "$current" = "Performance" ]; then
    asusctl profile set Quiet
else
    asusctl profile set Performance
fi
