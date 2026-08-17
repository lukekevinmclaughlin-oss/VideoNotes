#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ROOT="${VIDEONOTES_CI_ROOT:-/tmp/VideoNotes-ci-${CI_RUN_ID:-$$}}"
SIMULATOR_ID=""

cleanup() {
  if [[ -n "$SIMULATOR_ID" ]]; then
    xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cd "$ROOT"
command -v xcodegen >/dev/null || {
  echo "xcodegen is required (brew install xcodegen)." >&2
  exit 2
}
command -v jq >/dev/null || {
  echo "jq is required to select an available iOS Simulator." >&2
  exit 2
}

rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT"
xcodegen generate

swift test \
  --package-path Engine \
  --parallel \
  --scratch-path "$RUN_ROOT/engine-tests" \
  -Xswiftc -warnings-as-errors \
  -Xswiftc -strict-concurrency=complete

xcodebuild test -quiet \
  -project VideoNotes.xcodeproj \
  -scheme VideoNotes-macOS \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:VideoNotes-macOSTests \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -derivedDataPath "$RUN_ROOT/macos-tests" \
  -resultBundlePath "$RUN_ROOT/macos-tests.xcresult" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

SIMULATOR_ID="$(
  xcrun simctl list devices available -j \
    | jq -r '[.devices[][] | select(.isAvailable == true) | select(.name | startswith("iPhone"))][0].udid // empty'
)"
if [[ -z "$SIMULATOR_ID" ]]; then
  echo "No available iPhone Simulator runtime was found." >&2
  exit 3
fi
xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b

# The main app unit target contains only project Swift and remains strict.
xcodebuild test -quiet \
  -project VideoNotes.xcodeproj \
  -scheme VideoNotes-iOS \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -only-testing:VideoNotes-iOSTests \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -derivedDataPath "$RUN_ROOT/ios-tests" \
  -resultBundlePath "$RUN_ROOT/ios-tests.xcresult" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

# StoreKitTest's iOS 26 SDK module contains its own deprecated declaration.
# Run that isolated Apple-framework suite without global warnings-as-errors;
# project sources remain covered by the strict main unit and release gates.
xcodebuild test -quiet \
  -project VideoNotes.xcodeproj \
  -scheme VideoNotes-iOS-StoreKit \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -only-testing:VideoNotes-iOSStoreKitTests \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -derivedDataPath "$RUN_ROOT/ios-tests" \
  -resultBundlePath "$RUN_ROOT/ios-storekit-tests.xcresult"

xcodebuild test -quiet \
  -project VideoNotes.xcodeproj \
  -scheme VideoNotes-iOS-UI \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$RUN_ROOT/ios-ui-tests" \
  -resultBundlePath "$RUN_ROOT/ios-ui-tests.xcresult" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

# Compiles the macOS UI runner in CI without requiring a hosted runner to
# grant Accessibility automation permission. An authorized physical Mac runs
# the same scheme with `test` before public release.
xcodebuild build-for-testing -quiet \
  -project VideoNotes.xcodeproj \
  -scheme VideoNotes-macOS-UI \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$RUN_ROOT/macos-ui-build" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

xcodebuild build -quiet \
  -project VideoNotes.xcodeproj \
  -scheme VideoNotes-macOS \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$RUN_ROOT/macos-release" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

xcodebuild build -quiet \
  -project VideoNotes.xcodeproj \
  -scheme VideoNotes-iOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$RUN_ROOT/ios-release" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

xcodebuild analyze -quiet \
  -project VideoNotes.xcodeproj \
  -scheme VideoNotes-macOS \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$RUN_ROOT/macos-analyze" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

xcodebuild analyze -quiet \
  -project VideoNotes.xcodeproj \
  -scheme VideoNotes-iOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$RUN_ROOT/ios-analyze" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

if find \
  "$RUN_ROOT/macos-release/Build/Products/Release/VideoNotes.app" \
  "$RUN_ROOT/ios-release/Build/Products/Release-iphoneos/VideoNotes.app" \
  -iname '*.storekit' -print | grep -q .
then
  echo "A test StoreKit configuration leaked into a Release app bundle." >&2
  exit 4
fi

echo "VideoNotes CI verification passed. Artifacts: $RUN_ROOT"
