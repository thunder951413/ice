#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
for suite in \
    hosted-visibility-policy hosted-enumeration-scan-policy menu-bar-click-policy \
    application-menu-geometry login-item-manager search-hotkey-availability visibility-assertion-session \
    graceful-application-termination temporary-reveal-rehide-policy hosted-item-snapshot-policy \
    clock-panel-visibility-session async-snapshot-cache; do
    "$root/Scripts/test-$suite.sh"
done
python3 "$root/Scripts/test-verify-release.py"
"$root/Scripts/test-native-bridge-build.sh"
"$root/Scripts/test-icebar-surface.sh"
