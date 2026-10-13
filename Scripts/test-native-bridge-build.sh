#!/bin/zsh
# Compile/link the real bridge and native probe without activating a restriction.
set -euo pipefail
root="${0:A:h:h}"
scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/ice-native-bridge-build.XXXXXX")"
trap 'rm -rf "$scratch_directory"' EXIT
xcrun clang -fobjc-arc -fmodules -fblocks -Wall -Wextra -Werror \
    -I "$root/Ice/Bridging" "$root/Tests/HostedVisibilitySmoke.m" "$root/Ice/Bridging/IceMenuBarVisibility.m" \
    -framework AppKit -framework ApplicationServices -framework Foundation \
    -o "$scratch_directory/HostedVisibilitySmoke"
print 'Native bridge compilation passed'
