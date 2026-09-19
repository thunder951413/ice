#!/bin/zsh

set -euo pipefail

root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-hosted-enumeration-policy.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT

swiftc \
    "$root/Ice/MenuBar/MenuBarItems/HostedEnumerationScanPolicy.swift" \
    "$root/Tests/HostedEnumerationScanPolicyTests.swift" \
    -o "$scratch_directory/HostedEnumerationScanPolicyTests"

"$scratch_directory/HostedEnumerationScanPolicyTests"
