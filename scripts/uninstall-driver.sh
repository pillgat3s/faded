#!/bin/bash
# Removes FaderDriver.driver and restarts coreaudiod. Run as root.
set -euo pipefail
DST="/Library/Audio/Plug-Ins/HAL/FaderDriver.driver"
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
rm -rf "$DST"
killall coreaudiod || true
sleep 2
echo "removed $DST"
system_profiler SPAudioDataType 2>/dev/null | grep -E "^\s{8}Fader" && echo "WARNING: still visible" || echo "Fader devices gone"
