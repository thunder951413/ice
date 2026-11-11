#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    selected_dev_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ ! -x "$selected_dev_dir/usr/bin/xcodebuild" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi
# Every Scripts/test-<suite>.sh runs automatically, so a new suite cannot be
# forgotten here. Suites that need a real macOS 27 session (Accessibility,
# live MenuBarAgent) or are run explicitly below are skipped.
skip=(regressions hosted-visibility hosted-snapshot native-bridge-build icebar-surface)
for script in "$root"/Scripts/test-*.sh; do
    suite="${${script:t:r}#test-}"
    (( ${skip[(Ie)$suite]} )) && continue
    "$script"
done
python3 "$root/Scripts/test-verify-release.py"
"$root/Scripts/test-native-bridge-build.sh"
"$root/Scripts/test-icebar-surface.sh"
