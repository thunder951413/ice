#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-hosted-rendered-matching.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT
xcrun swiftc \
    "$root/Ice/MenuBar/MenuBarItems/HostedMenuBarBackend.swift" \
    "$root/Ice/MenuBar/MenuBarItems/HostedEnumerationScanPolicy.swift" \
    "$root/Ice/Utilities/AsyncSnapshotCache.swift" \
    "$root/Tests/HostedRenderedMatchingTests.swift" \
    -o "$scratch_directory/HostedRenderedMatchingTests"
"$scratch_directory/HostedRenderedMatchingTests"

# Keep the standalone live AX smoke harness verified at compile time even when
# Accessibility-dependent runtime execution is skipped.
xcrun swiftc \
    "$root/Ice/MenuBar/MenuBarItems/HostedMenuBarBackend.swift" \
    "$root/Ice/MenuBar/MenuBarItems/HostedEnumerationScanPolicy.swift" \
    "$root/Ice/Utilities/AsyncSnapshotCache.swift" \
    "$root/Tests/HostedSnapshotSmoke.swift" \
    -o "$scratch_directory/HostedSnapshotSmoke"
