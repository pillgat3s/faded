#!/bin/bash
# Installs FadedDriver.driver into the HAL plug-in folder and restarts
# coreaudiod. Run as root:  sudo scripts/install-driver.sh path/to/FadedDriver.driver
set -euo pipefail
SRC="${1:-$(dirname "$0")/../driver/build/FadedDriver.driver}"
DST="/Library/Audio/Plug-Ins/HAL/FadedDriver.driver"
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
[[ -d "$SRC" ]] || { echo "no driver at $SRC (run: make driver)"; exit 1; }
rm -rf "$DST"
mkdir -p "$(dirname "$DST")"
cp -R "$SRC" "$DST"
chown -R root:wheel "$DST"
chmod -R go-w "$DST"
killall coreaudiod || true
sleep 2
echo "installed → $DST"
system_profiler SPAudioDataType 2>/dev/null | grep -E "^\s{8}Faded" || echo "(Faded device not visible yet — give coreaudiod a second, or check: log show --last 2m --predicate 'process == \"coreaudiod\"' | grep -i faded)"
