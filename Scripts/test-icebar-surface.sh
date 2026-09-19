#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
output=${1:-/tmp/ice-bar-surface-test}
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
xcrun swiftc -parse-as-library \
    "$root/Ice/UI/IceBar/IceBarStyle.swift" \
    "$root/Ice/UI/IceBar/IceBarSurface.swift" \
    "$root/Ice/UI/Views/VisualEffectView.swift" \
    "$root/Tests/IceBarSurfaceSmoke.swift" \
    -o "$temporary/SurfaceSmoke"
"$temporary/SurfaceSmoke" "$output"
