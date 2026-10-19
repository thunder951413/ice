#!/bin/zsh

set -euo pipefail

root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-menu-bar-click-policy.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT

swiftc \
    "$root/Ice/Events/MenuBarClickPolicy.swift" \
    "$root/Tests/MenuBarClickPolicyTests.swift" \
    -o "$scratch_directory/MenuBarClickPolicyTests"

"$scratch_directory/MenuBarClickPolicyTests"
