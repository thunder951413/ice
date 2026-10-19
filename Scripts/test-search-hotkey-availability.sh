#!/bin/zsh

set -euo pipefail

root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-search-hotkey-availability.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT

swiftc \
    "$root/Ice/Hotkeys/Hotkey.swift" \
    "$root/Tests/SearchHotkeyAvailabilityTests.swift" \
    -o "$scratch_directory/SearchHotkeyAvailabilityTests"

"$scratch_directory/SearchHotkeyAvailabilityTests"
