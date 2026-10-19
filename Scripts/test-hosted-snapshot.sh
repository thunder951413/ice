#!/bin/zsh
# Read-only live smoke; does not press icons or acquire a hiding assertion.
set -euo pipefail
root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-hosted-snapshot.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT
xcrun swiftc \
    "$root/Ice/MenuBar/MenuBarItems/HostedMenuBarBackend.swift" \
    "$root/Ice/MenuBar/MenuBarItems/HostedEnumerationScanPolicy.swift" \
    "$root/Ice/Utilities/AsyncSnapshotCache.swift" \
    "$root/Tests/HostedSnapshotSmoke.swift" -o "$scratch_directory/HostedSnapshotSmoke"
"$scratch_directory/HostedSnapshotSmoke" "$@"
