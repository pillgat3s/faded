#!/bin/bash
# Verifies driver/FaderProtocol.h and app/.../FaderProtocol.swift agree on the
# values that must match. Cheap guard against editing one and not the other.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/driver/FaderProtocol.h"
S="$ROOT/app/Sources/Fader/Driver/FaderProtocol.swift"
fail=0
check() { # name, header-regex, swift-regex
  local hv sv
  hv=$(grep -E "$2" "$H" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
  sv=$(grep -E "$3" "$S" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
  if [[ "$hv" != "$sv" ]]; then echo "MISMATCH $1: header='$hv' swift='$sv'"; fail=1; else echo "ok $1 = $hv"; fi
}
check outputUID  'define kFaderOutputDeviceUID'  'outputDeviceUID ='
check tapUID     'define kFaderTapDeviceUID'     'tapDeviceUID ='
check outputName 'define kFaderOutputDeviceName' 'outputDeviceName ='
check tapName    'define kFaderTapDeviceName'    'tapDeviceName ='
check appBundle  'define kFaderAppBundleID'      'appBundleID ='
check version    'define kFaderProtocolVersion'  'protocolVersion ='
for sel in fcli fapv fbyp fhid fver fsta; do
  grep -q "'$sel'" "$H" && grep -q "\"$sel\"" "$S" && echo "ok selector $sel" || { echo "MISMATCH selector $sel"; fail=1; }
done
exit $fail
