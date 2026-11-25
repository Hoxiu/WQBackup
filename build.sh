#!/usr/bin/env bash
# Builds WQBackup.ipa (arm64, ad-hoc signed with an App Group entitlement;
# re-sign with AltStore, SideStore or Impactor, keeping the App Group).
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"
MINIMUM_IOS_VERSION=26.0
FINAL_IPA=${WQBACKUP_FINAL_IPA:-WQBackup.ipa}

PREFLIGHT_RUNNER="$ROOT/tests/run_all_tests.sh"
if [[ "${WQB_SKIP_PREFLIGHT:-0}" == 1 ]]; then
    {
        echo "************************************************************"
        echo "WARNING: host regression preflight SKIPPED (WQB_SKIP_PREFLIGHT=1)."
        echo "************************************************************"
    } >&2
else
    if [[ ! -f "$PREFLIGHT_RUNNER" ]]; then
        echo "preflight runner missing: $PREFLIGHT_RUNNER" >&2
        exit 1
    fi
    bash "$PREFLIGHT_RUNNER" || {
        echo "preflight failed: $PREFLIGHT_RUNNER (no IPA written)" >&2
        exit 1
    }
fi

if [[ "$FINAL_IPA" != /* ]]; then
    FINAL_IPA="$ROOT/$FINAL_IPA"
fi
FINAL_DIR=$(dirname -- "$FINAL_IPA")
[[ -d "$FINAL_DIR" ]] || { echo "IPA directory does not exist: $FINAL_DIR" >&2; exit 1; }

plist_value() {
    plutil -extract "$1" raw -o - "$2"
}

fail() {
    echo "build validation failed: $*" >&2
    exit 1
}

EXPECTED_BUNDLE_ID=$(plist_value CFBundleIdentifier Info.plist)
EXPECTED_VERSION=$(plist_value CFBundleShortVersionString Info.plist)
EXPECTED_BUILD=$(plist_value CFBundleVersion Info.plist)
EXPECTED_MINIMUM_OS=$(plist_value MinimumOSVersion Info.plist)
APP_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' entitlements.plist)
[[ -n "$APP_GROUP" ]] || fail "entitlements.plist has no App Group"
[[ "$EXPECTED_MINIMUM_OS" == "$MINIMUM_IOS_VERSION" ]] || \
    fail "Info.plist minimum OS $EXPECTED_MINIMUM_OS does not match build policy $MINIMUM_IOS_VERSION"
for key in UIFileSharingEnabled LSSupportsOpeningDocumentsInPlace; do
    [[ "$(plist_value "$key" Info.plist)" == "true" ]] || \
        fail "Info.plist $key must be true (the backup folder in the Files app)"
done

OUT=$(mktemp -d "$FINAL_DIR/.WQBackup-build.XXXXXX")
IPA_TMP=$(mktemp "$FINAL_DIR/.WQBackup.ipa.XXXXXX")
rm -f -- "$IPA_TMP"
CHECK_DIR=""
cleanup() {
    if [[ -n "${OUT:-}" && -d "$OUT" ]]; then rm -rf -- "$OUT"; fi
    if [[ -n "${IPA_TMP:-}" && -e "$IPA_TMP" ]]; then rm -f -- "$IPA_TMP"; fi
    if [[ -n "${CHECK_DIR:-}" && -d "$CHECK_DIR" ]]; then rm -rf -- "$CHECK_DIR"; fi
}
trap cleanup EXIT

APP="$OUT/Payload/WQBackup.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/ModuleCache" -arch arm64 \
    -miphoneos-version-min="$MINIMUM_IOS_VERSION" \
    -isysroot "$SDK" -Wall -Wextra -Werror -O2 \
    -framework UIKit -framework Foundation -framework Security -lz \
    WQCore.m WQAccess.m WQLocalization.m WQLaunchServices.m WQArchive.m \
    WQBPaths.m WQBDiscovery.m WQBBackup.m WQBUI.m main.m \
    -o "$APP/WQBackup"
cp Info.plist "$APP/Info.plist"

# App icon: one universal 1024 image in an asset catalog (iOS 18+ accepts the
# single-size icon and renders the variants itself).
ICON_CATALOG="$OUT/Icons.xcassets"
mkdir -p "$ICON_CATALOG/AppIcon.appiconset"
cp icons/AppIcon1024.png "$ICON_CATALOG/AppIcon.appiconset/"
cat > "$ICON_CATALOG/Contents.json" <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON
cat > "$ICON_CATALOG/AppIcon.appiconset/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "AppIcon1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
xcrun actool "$ICON_CATALOG" --compile "$APP" --platform iphoneos \
    --minimum-deployment-target "$MINIMUM_IOS_VERSION" --target-device iphone --target-device ipad \
    --app-icon AppIcon --output-partial-info-plist "$OUT/icon-info.plist" \
    --errors --warnings --output-format human-readable-text >/dev/null || fail "actool could not compile the app icon"
[[ -f "$APP/Assets.car" ]] || fail "actool wrote no Assets.car"
for key in CFBundleIcons 'CFBundleIcons~ipad'; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Info.plist" >/dev/null 2>&1 || true
done
/usr/libexec/PlistBuddy -c "Merge $OUT/icon-info.plist" "$APP/Info.plist" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$APP/Info.plist")" == AppIcon ]] || \
    fail "Info.plist has no catalog app icon"

for lproj in "$ROOT"/*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$APP/"
done
plutil -convert binary1 "$APP/Info.plist"
codesign -f -s - --entitlements entitlements.plist "$APP"

validate_app() {
    local app_path=$1
    [[ -x "$app_path/WQBackup" ]] || fail "missing executable in $app_path"
    [[ -f "$app_path/Info.plist" ]] || fail "missing Info.plist in $app_path"
    [[ "$(plist_value CFBundleIdentifier "$app_path/Info.plist")" == "$EXPECTED_BUNDLE_ID" ]] || \
        fail "bundle identifier does not match source metadata"
    [[ "$(plist_value CFBundleShortVersionString "$app_path/Info.plist")" == "$EXPECTED_VERSION" ]] || \
        fail "short version does not match source metadata"
    [[ "$(plist_value CFBundleVersion "$app_path/Info.plist")" == "$EXPECTED_BUILD" ]] || \
        fail "build version does not match source metadata"
    [[ "$(plist_value MinimumOSVersion "$app_path/Info.plist")" == "$EXPECTED_MINIMUM_OS" ]] || \
        fail "minimum OS does not match source metadata"
    codesign --verify --deep --strict "$app_path"
    local signed_entitlements
    signed_entitlements=$(codesign -d --entitlements :- "$app_path" 2>&1) || \
        fail "unable to inspect signed entitlements"
    [[ "$signed_entitlements" == *"$APP_GROUP"* ]] || \
        fail "signed app is missing required App Group $APP_GROUP"
}

(cd "$OUT" && zip -qry "$IPA_TMP" Payload)
unzip -tqq "$IPA_TMP"
CHECK_DIR=$(mktemp -d "$OUT/ipa-check.XXXXXX")
unzip -q "$IPA_TMP" -d "$CHECK_DIR"
validate_app "$CHECK_DIR/Payload/WQBackup.app"
mv -f -- "$IPA_TMP" "$FINAL_IPA"
IPA_TMP=""
echo "wrote $FINAL_IPA"
