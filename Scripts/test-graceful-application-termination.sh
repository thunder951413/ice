#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-graceful-application-termination.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT
swiftc "$root/Ice/MenuBar/Spacing/GracefulApplicationTermination.swift" "$root/Tests/GracefulApplicationTerminationTests.swift" -o "$scratch_directory/GracefulApplicationTerminationTests"
"$scratch_directory/GracefulApplicationTerminationTests"
