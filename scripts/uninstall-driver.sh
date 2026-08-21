#!/bin/bash
# Removes FadedDriver.driver and restarts coreaudiod. Run as root.
set -euo pipefail
DST="/Library/Audio/Plug-Ins/HAL/FadedDriver.driver"
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
rm -rf "$DST"
killall coreaudiod || true
sleep 2
echo "removed $DST"
system_profiler SPAudioDataType 2>/dev/null | grep -E "^\s{8}Faded" && echo "WARNING: still visible" || echo "Faded devices gone"
