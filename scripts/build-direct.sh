#!/bin/bash

# Build, sign, package, notarize, and staple the fully unlocked website
# edition. App Store Release builds retain StoreKit subscriptions.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${VIDEONOTES_DIRECT_BUILD_ROOT:-/private/tmp/macossoftware-videonotes-direct}"
derived_data="$build_root/DerivedData"
source_dir="$build_root/src"
stage_dir="$build_root/stage"
output_dir="${VIDEONOTES_DIRECT_OUTPUT_DIR:-/Users/$USER/Desktop/MacOSSoftware Direct Releases/VideoNotes}"
signing_identity="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Luke Mclaughlin (24UCS53598)}"
notary_profile="${NOTARYTOOL_PROFILE:-macossoftware-notary}"

command -v xcodegen >/dev/null || { echo "xcodegen is required" >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Xcode command-line tools are required" >&2; exit 1; }

[[ "$build_root" == /private/tmp/macossoftware-videonotes-direct* || -n "${VIDEONOTES_DIRECT_BUILD_ROOT:-}" ]] || {
  echo "Unsafe build directory: $build_root" >&2
  exit 1
}
rm -rf "$build_root"
mkdir -p "$source_dir" "$derived_data" "$stage_dir" "$output_dir"

rsync -a \
  --exclude '.git' \
  --exclude '.build' \
  --exclude 'DerivedData*' \
  --exclude '*.dmg' \
  --exclude '*.xcarchive' \
  "$repo_dir/" "$source_dir/"

cd "$source_dir"
xcodegen generate
xattr -cr App Engine

xcodebuild \
  -project VideoNotes.xcodeproj \
  -scheme VideoNotes-macOS \
  -configuration Direct \
  -derivedDataPath "$derived_data" \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$signing_identity" \
  DEVELOPMENT_TEAM=24UCS53598 \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_HARDENED_RUNTIME=YES \
  clean build

app_path="$derived_data/Build/Products/Direct/VideoNotes.app"
[[ -d "$app_path" ]] || { echo "VideoNotes.app was not produced" >&2; exit 1; }

bundle_id="$(defaults read "$app_path/Contents/Info" CFBundleIdentifier)"
[[ "$bundle_id" == "com.lukemclaughlin.videonotes.direct" ]] || {
  echo "Unexpected direct bundle identifier: $bundle_id" >&2
  exit 1
}

executable="$app_path/Contents/MacOS/VideoNotes"
if otool -L "$executable" | grep -q 'StoreKit.framework'; then
  echo "Refusing to package a website build linked to StoreKit" >&2
  exit 1
fi
if rg -a -q 'Subscribe|Free Trial|Restore Purchases|videonotes.pro.monthly' "$executable"; then
  echo "Refusing to package a website build containing subscription code or UI" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
if codesign -d --entitlements :- "$app_path" 2>/dev/null | plutil -extract com.apple.security.get-task-allow raw -o - - 2>/dev/null | grep -q true; then
  echo "Refusing to package a build with get-task-allow" >&2
  exit 1
fi

version="$(defaults read "$app_path/Contents/Info" CFBundleShortVersionString)"
cp -R "$app_path" "$stage_dir/"
ln -s /Applications "$stage_dir/Applications"
dmg_path="$output_dir/VideoNotes-${version}-direct.dmg"
rm -f "$dmg_path"
hdiutil create -volname "VideoNotes Direct" -srcfolder "$stage_dir" -ov -format UDZO "$dmg_path"
codesign --force --timestamp --options runtime --sign "$signing_identity" "$dmg_path"

if [[ "${SKIP_NOTARIZATION:-0}" != "1" ]]; then
  xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
else
  echo "Local test build only: notarization and Gatekeeper assessment skipped."
fi

shasum -a 256 "$dmg_path" > "$dmg_path.sha256"
printf 'Direct release: %s\nChecksum: %s\n' "$dmg_path" "$(cut -d ' ' -f 1 "$dmg_path.sha256")"
