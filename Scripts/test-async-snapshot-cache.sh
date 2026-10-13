#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-async-snapshot-cache.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT
swiftc "$root/Ice/Utilities/AsyncSnapshotCache.swift" "$root/Tests/AsyncSnapshotCacheTests.swift" -o "$scratch_directory/AsyncSnapshotCacheTests"
"$scratch_directory/AsyncSnapshotCacheTests"
