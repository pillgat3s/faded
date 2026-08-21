#!/bin/bash
# Verifies that the two ends of the driver protocol agree.
#
#  * driver/FadedProtocol.h  vs  app/.../FadedProtocol.swift — device identity,
#    protocol version and the custom-property selectors.
#  * driver/FadedShared.h — the shared-memory layout, which the app imports
#    directly through its bridging header, so it cannot drift. Checked here only
#    for the version constant.
#
# Cheap guard against editing one side and forgetting the other.
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
check outputName 'define kFadedOutputDeviceName' 'outputDeviceName ='
check appBundle  'define kFadedAppBundleID'      'appBundleID ='
check version    'define kFadedProtocolVersion'  'protocolVersion ='
for sel in fcli fapv fbyp fhid fver fsta; do
  grep -q "'$sel'" "$H" && grep -q "\"$sel\"" "$S" && echo "ok selector $sel" || { echo "MISMATCH selector $sel"; fail=1; }
done
# The shared ring's layout is imported by the app rather than mirrored, but the
# protocol version gates whether the app will talk to a given driver at all.
SHARED="$ROOT/driver/FadedShared.h"
if grep -q "kFadedShmVersion 1" "$SHARED"; then echo "ok shared ring version = 1"; else echo "MISMATCH shared ring version"; fail=1; fi
if grep -q "kFadedTapDeviceUID" "$ROOT/driver/FadedProtocol.h"; then
  echo "MISMATCH tap device should be gone in protocol 2"; fail=1
else
  echo "ok no tap device (protocol 2)"
fi

exit $fail
