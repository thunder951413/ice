#!/bin/zsh

set -euo pipefail

root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-login-item-manager.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT

swiftc \
    "$root/Ice/Settings/LoginItemManager.swift" \
    "$root/Tests/LoginItemManagerTests.swift" \
    -o "$scratch_directory/LoginItemManagerTests"

"$scratch_directory/LoginItemManagerTests"
