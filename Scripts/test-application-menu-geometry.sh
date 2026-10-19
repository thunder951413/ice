#!/bin/zsh

set -euo pipefail

root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-application-menu-geometry.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT

xcrun swiftc \
    "$root/Ice/Events/ApplicationMenuGeometry.swift" \
    "$root/Tests/ApplicationMenuGeometryTests.swift" \
    -o "$scratch_directory/ApplicationMenuGeometryTests"

"$scratch_directory/ApplicationMenuGeometryTests"
