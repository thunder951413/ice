#!/bin/zsh

set -euo pipefail

root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-hosted-visibility-policy.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT

swiftc \
    "$root/Ice/MenuBar/MenuBarItems/HostedVisibilityPolicy.swift" \
    "$root/Tests/HostedVisibilityPolicyTests.swift" \
    -o "$scratch_directory/HostedVisibilityPolicyTests"

"$scratch_directory/HostedVisibilityPolicyTests"
