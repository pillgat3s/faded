#!/bin/bash
# Verifies driver/FadedProtocol.h and app/.../FadedProtocol.swift agree on the
# values that must match. Cheap guard against editing one and not the other.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/driver/FadedProtocol.h"
S="$ROOT/app/Sources/Faded/Driver/FadedProtocol.swift"
fail=0
check() { # name, header-regex, swift-regex
  local hv sv
  hv=$(grep -E "$2" "$H" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
  sv=$(grep -E "$3" "$S" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
  if [[ "$hv" != "$sv" ]]; then echo "MISMATCH $1: header='$hv' swift='$sv'"; fail=1; else echo "ok $1 = $hv"; fi
}
check outputUID  'define kFadedOutputDeviceUID'  'outputDeviceUID ='
check tapUID     'define kFadedTapDeviceUID'     'tapDeviceUID ='
check outputName 'define kFadedOutputDeviceName' 'outputDeviceName ='
check tapName    'define kFadedTapDeviceName'    'tapDeviceName ='
check appBundle  'define kFadedAppBundleID'      'appBundleID ='
check version    'define kFadedProtocolVersion'  'protocolVersion ='
for sel in fcli fapv fbyp fhid fver fsta; do
  grep -q "'$sel'" "$H" && grep -q "\"$sel\"" "$S" && echo "ok selector $sel" || { echo "MISMATCH selector $sel"; fail=1; }
done
exit $fail
