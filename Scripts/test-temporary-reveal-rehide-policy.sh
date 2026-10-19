#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-temporary-reveal-rehide-policy.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT
swiftc "$root/Ice/MenuBar/MenuBarItems/TemporaryRevealRehidePolicy.swift" "$root/Tests/TemporaryRevealRehidePolicyTests.swift" -o "$scratch_directory/TemporaryRevealRehidePolicyTests"
"$scratch_directory/TemporaryRevealRehidePolicyTests"
