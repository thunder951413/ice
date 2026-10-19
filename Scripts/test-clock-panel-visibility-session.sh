#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-clock-panel-visibility-session.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT
swiftc "$root/Ice/Events/ClockPanelVisibilitySession.swift" "$root/Tests/ClockPanelVisibilitySessionTests.swift" -o "$scratch_directory/ClockPanelVisibilitySessionTests"
"$scratch_directory/ClockPanelVisibilitySessionTests"
