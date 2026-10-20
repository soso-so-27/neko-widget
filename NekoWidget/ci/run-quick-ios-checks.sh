#!/usr/bin/env bash
# Ordinary CI: real unit tests, Release build, and one fresh-install launch.
# Full Photos/Widget/UI regressions remain in the opt-in workflow jobs.
set -euo pipefail
cd "$(dirname "$0")/.."

xcrun swiftc -parse-as-library \
  NekoWidget/Views/OnboardingPresentation.swift \
  ci/verify-onboarding-presentation.swift -o "$RUNNER_TEMP/onboarding-tests"
"$RUNNER_TEMP/onboarding-tests"
xcrun swiftc -parse-as-library \
  Shared/Models/AppSettings.swift Shared/Models/NormalizedRect.swift \
  Shared/Models/CatDetection.swift Shared/Models/AssetRecord.swift \
  Shared/Models/ScanState.swift Shared/Models/LibrarySnapshot.swift \
  NekoWidget/Views/GrowthAlbumSelector.swift \
  NekoWidget/Views/AppPresentationModels.swift \
  NekoWidget/Views/HouseholdAlbumCatalogCoordinator.swift \
  ci/verify-album-catalog-coordinator.swift ci/verify-album-grouping.swift \
  -o "$RUNNER_TEMP/album-tests"
"$RUNNER_TEMP/album-tests"

xcrun swiftc -parse-as-library \
  Shared/Sharing/PairingCore.swift Shared/Models/WidgetRenderPlan.swift \
  Shared/Models/WidgetManifest.swift Shared/Sharing/MomentSharingCore.swift \
  Shared/Sharing/FamilyRecordCore.swift ci/verify-family-records.swift \
  -o "$RUNNER_TEMP/family-record-tests"
"$RUNNER_TEMP/family-record-tests"
xcrun --sdk macosx swiftc -parse-as-library \
  Shared/Routing/DeepLink.swift NekoWidget/Views/MomentSharingPresentation.swift \
  ci/verify-moment-sharing-presentation.swift -o "$RUNNER_TEMP/moment-sharing-presentation-tests"
"$RUNNER_TEMP/moment-sharing-presentation-tests"
python3 ci/test-family-window-widget-boundaries.py

xcrun --sdk macosx swiftc -D DEBUG -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift \
  NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowFixture.swift ci/verify-group-windows.swift \
  -o "$RUNNER_TEMP/group-window-tests"
"$RUNNER_TEMP/group-window-tests" ci/fixtures/group-roster-v3.json

settings_paths=()
for target in NekoWidget NekoWidgetWidgetExtension NekoWidgetShareExtension; do
  output="$RUNNER_TEMP/${target}ReleaseBuildSettings.json"
  xcodebuild -project NekoWidget.xcodeproj -target "$target" \
    -configuration Release -sdk iphonesimulator -showBuildSettings -json > "$output"
  settings_paths+=("$output")
done
python3 ci/validate-disabled-release-build-settings.py "${settings_paths[@]}"

runtime=$(xcrun simctl list runtimes -j | python3 -c '
import json,sys
items=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and ".iOS-" in r["identifier"]]
assert items, "No available iOS Simulator runtime"
print(next((r for r in items if r["version"] == "26.2"), items[0])["identifier"])
')
device=$(xcrun simctl create NekoQuickLaunch com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$runtime")
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1 || true; xcrun simctl delete "$device" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b &
boot_pid=$!

xcodebuild -project NekoWidget.xcodeproj -scheme NekoWidget \
  -configuration Release -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$device" ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath "$RUNNER_TEMP/QuickBuild" \
  SWIFT_OPTIMIZATION_LEVEL=-Onone SWIFT_COMPILATION_MODE=singlefile \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES \
  build
wait "$boot_pid"
app="$RUNNER_TEMP/QuickBuild/Build/Products/Release-iphonesimulator/NekoWidget.app"
bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
xcrun simctl install "$device" "$app"
launch=$(xcrun simctl launch "$device" "$bundle")
pid=${launch##*: }
sleep 5
xcrun simctl spawn "$device" launchctl list | awk -v pid="$pid" -v bundle="$bundle" '
  $1 == pid && index($0, bundle) { alive=1 }
  END { exit !alive }
'
mkdir -p "$RUNNER_TEMP/ci-screenshots"
xcrun simctl io "$device" screenshot "$RUNNER_TEMP/ci-screenshots/first-launch.png"
