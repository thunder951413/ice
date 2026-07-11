#!/bin/zsh

set -euo pipefail

root="${0:A:h:h}"
configuration="${CONFIGURATION:-Debug}"
derived_data="${DERIVED_DATA_PATH:-$root/build/DerivedData}"
xcode_path="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

signing_arguments=()
team="${DEVELOPMENT_TEAM:-}"
if [[ -z "$team" ]]; then
    certificate="$(security find-certificate -c 'Apple Development' -p 2>/dev/null || true)"
    if [[ -n "$certificate" ]]; then
        team="$(print -r -- "$certificate" | openssl x509 -noout -subject 2>/dev/null | sed -E 's#.*OU=([^/]+).*#\1#')"
    fi
fi

if [[ -n "$team" ]]; then
    signing_arguments+=("DEVELOPMENT_TEAM=$team" "CODE_SIGN_IDENTITY=Apple Development")
else
    print -u2 "No Apple Development certificate found; building without code signing."
    signing_arguments+=("CODE_SIGNING_ALLOWED=NO")
fi

DEVELOPER_DIR="$xcode_path" xcodebuild \
    -project "$root/Ice.xcodeproj" \
    -scheme Ice \
    -configuration "$configuration" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    "$@" \
    "${signing_arguments[@]}" \
    build
