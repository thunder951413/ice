#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-hosted-item-snapshot-policy.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT
swiftc "$root/Ice/MenuBar/MenuBarItems/HostedItemSnapshotPolicy.swift" "$root/Tests/HostedItemSnapshotPolicyTests.swift" -o "$scratch_directory/HostedItemSnapshotPolicyTests"
"$scratch_directory/HostedItemSnapshotPolicyTests"
