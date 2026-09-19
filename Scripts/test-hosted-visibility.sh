#!/bin/zsh
# Opt-in smoke test for macOS 27's hosted menu-bar visibility API.
# It builds a temporary probe app and permits every running app except that
# probe, so no installed user app is selected as the hide target.
# Set ICE_TEST_ALLOWLIST=1 to additionally run the strict positive-allowlist
# diagnostic. Temporary bundles may fail that probe when LaunchServices does
# not classify them like a canonically installed application.

set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/ice-hosted-visibility.XXXXXX")
fixture_bundle_identifier="com.ice.visibility-smoke.$(uuidgen | tr '[:upper:]' '[:lower:]')"
controller_bundle_identifier="com.ice.visibility-smoke-controller.$(uuidgen | tr '[:upper:]' '[:lower:]')"
fixture_bundle="${temporary_root}/IceProbeFixture.app"
fixture_executable="${fixture_bundle}/Contents/MacOS/IceProbeFixture"
controller_bundle="${temporary_root}/IceProbeController.app"
controller_bundle_executable="${controller_bundle}/Contents/MacOS/IceProbeController"
controller_executable="${temporary_root}/HostedVisibilitySmoke"
controller_result="${temporary_root}/controller-result"
fixture_pid=''

cleanup() {
    if [[ -n ${fixture_pid} ]]; then
        wait ${fixture_pid} 2>/dev/null || true
    fi
    rm -rf -- ${temporary_root}
}
trap cleanup EXIT INT TERM

mkdir -p "${fixture_bundle}/Contents/MacOS"
mkdir -p "${controller_bundle}/Contents/MacOS"
/usr/bin/plutil -create xml1 "${fixture_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${fixture_bundle_identifier}" "${fixture_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string IceProbeFixture' "${fixture_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string IceProbeFixture' "${fixture_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "${fixture_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSPrincipalClass string NSApplication' "${fixture_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "${fixture_bundle}/Contents/Info.plist"
/usr/bin/plutil -create xml1 "${controller_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${controller_bundle_identifier}" "${controller_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string IceProbeController' "${controller_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string IceProbeController' "${controller_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "${controller_bundle}/Contents/Info.plist"

xcrun clang -fobjc-arc -fmodules -fblocks -Wall -Wextra -Werror \
    -I "${repository_root}/Ice/Bridging" \
    "${repository_root}/Tests/HostedVisibilitySmoke.m" \
    "${repository_root}/Ice/Bridging/IceMenuBarVisibility.m" \
    -framework AppKit -framework ApplicationServices -framework Foundation \
    -o "${controller_executable}"
cp "${controller_executable}" "${fixture_executable}"
cp "${controller_executable}" "${controller_bundle_executable}"
/usr/bin/codesign --force --sign - "${fixture_bundle}"

# Launch through LaunchServices so the temporary bundle is hosted as an app.
/usr/bin/open -n -W "${fixture_bundle}" --args --fixture &
fixture_pid=$!
controller_arguments=(--controller "${fixture_bundle_identifier}" "${controller_result}")
if [[ ${ICE_TEST_ALLOWLIST:-0} == 1 ]]; then
    controller_arguments+=(--verify-allowlisted-fixture)
fi
"${controller_bundle_executable}" "${controller_arguments[@]}"
if [[ ! -f ${controller_result} || $(<"${controller_result}") != 0 ]]; then
    print -u2 "Hosted visibility smoke test failed; controller result: $(<"${controller_result}" 2>/dev/null || print unavailable)"
    exit 1
fi
print 'Hosted visibility smoke test passed.'
