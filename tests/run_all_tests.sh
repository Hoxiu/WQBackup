#!/usr/bin/env bash
# Host-side regression checks. No device, container or sandbox access is used.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
OUT=$(mktemp -d "${TMPDIR:-/tmp}/wqb-tests.XXXXXX")
cleanup() { rm -rf -- "$OUT"; }
trap cleanup EXIT

SOURCES=(WQAccess.m WQCore.m WQLocalization.m WQLaunchServices.m WQArchive.m \
         WQBPaths.m WQBDiscovery.m WQBBackup.m)
MAC_SDK=$(xcrun --sdk macosx --show-sdk-path)
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)

printf '== Host backup/discovery fixtures ==\n'
xcrun --sdk macosx clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/modules-macos" \
    -isysroot "$MAC_SDK" -Wall -Wextra -Werror -I. "${SOURCES[@]}" tests/WQBHostTests.m \
    -framework Foundation -framework Security -lz -o "$OUT/WQBHostTests" \
    > "$OUT/host-build.log" 2>&1 || { cat "$OUT/host-build.log" >&2; exit 1; }
if ! "$OUT/WQBHostTests" > "$OUT/host-run.log" 2>&1; then
    cat "$OUT/host-run.log" >&2
    exit 1
fi
grep -E '^PASS' "$OUT/host-run.log" | tail -2

printf '\n== Strict iOS arm64 build ==\n'
xcrun --sdk iphoneos clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/modules-ios" \
    -arch arm64 -miphoneos-version-min=26.0 -isysroot "$IOS_SDK" -Wall -Wextra -Werror -O2 \
    -framework UIKit -framework Foundation -framework Security -lz \
    "${SOURCES[@]}" WQBUI.m main.m -o "$OUT/WQBackup-ios" \
    > "$OUT/ios-build.log" 2>&1 || { cat "$OUT/ios-build.log" >&2; exit 1; }
file "$OUT/WQBackup-ios" | sed 's/^.*: //'

printf '\n== Metadata checks ==\n'
[[ "$(plutil -extract CFBundleIdentifier raw -o - Info.plist)" == "com.wqbackup.app" ]]
[[ "$(plutil -extract MinimumOSVersion raw -o - Info.plist)" == "26.0" ]]
[[ "$(plutil -extract UIFileSharingEnabled raw -o - Info.plist)" == "true" ]]
[[ "$(plutil -extract LSSupportsOpeningDocumentsInPlace raw -o - Info.plist)" == "true" ]]
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' entitlements.plist)" ]]
grep -q 'LiveContainer' WQBDiscovery.m
grep -q 'Applications' WQBDiscovery.m
grep -q 'Data/Application' WQBDiscovery.m
grep -q 'LCContainers' WQBDiscovery.m
grep -q 'LCDataUUID' WQBDiscovery.m
bash -n build.sh
[[ -f icons/AppIcon1024.png ]]
echo "metadata OK"

printf '\nPASS: all WQ Backup host checks\n'
