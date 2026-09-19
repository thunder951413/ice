#!/bin/zsh

set -euo pipefail

root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-visibility-assertion-session.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT

swiftc \
    "$root/Ice/MenuBar/MenuBarItems/HostedVisibilityPolicy.swift" \
    "$root/Ice/MenuBar/MenuBarItems/VisibilityAssertionSession.swift" \
    "$root/Tests/VisibilityAssertionSessionTests.swift" \
    -o "$scratch_directory/VisibilityAssertionSessionTests"

"$scratch_directory/VisibilityAssertionSessionTests"
