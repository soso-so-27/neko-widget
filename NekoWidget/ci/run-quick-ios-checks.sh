#!/usr/bin/env bash
# Ordinary CI: real unit tests, Release build, and one fresh-install launch.
# Full Photos/Widget/UI regressions remain in the opt-in workflow jobs.
set -euo pipefail
cd "$(dirname "$0")/.."

# CoreSimulator installation can hang after a successful build. Bound the
# simulator commands so an environment stall cannot consume the entire job.
bounded() {
  python3 - "$@" <<'PY'
import subprocess, sys
try:
    result = subprocess.run(sys.argv[2:], timeout=int(sys.argv[1]))
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print("Simulator command exceeded its time limit", file=sys.stderr)
    sys.exit(124)
PY
}

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

xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/FamilyNotebookCore.swift \
  NekoWidget/Services/FamilyNotebookCrypto.swift ci/verify-family-notebook-crypto.swift \
  -o "$RUNNER_TEMP/family-notebook-crypto-tests"
"$RUNNER_TEMP/family-notebook-crypto-tests" | node ci/verify-family-notebook-crypto.mjs

xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/GroupWindowAPIModels.swift NekoWidget/Services/GroupWindowPhotoValidation.swift \
  NekoWidget/Services/ProductionGroupWindowClient.swift ci/verify-group-adapter.swift \
  -o "$RUNNER_TEMP/group-adapter-tests"
"$RUNNER_TEMP/group-adapter-tests" ci/fixtures/group-http-v3.json ci/fixtures/group-roster-v3.json | node ci/verify-native-group-http.mjs
xcrun --sdk macosx swiftc -D GROUP_REPORT_CRYPTO_CHECKS -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupReportCrypto.swift ci/verify-group-report-crypto.swift \
  -o "$RUNNER_TEMP/group-report-crypto-tests"
"$RUNNER_TEMP/group-report-crypto-tests" ci/fixtures/group-report-v3.json | node ci/verify-group-report-crypto.mjs --swift-stdin
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift Shared/Sharing/GroupReportCrypto.swift \
  NekoWidget/Services/GroupWindowContract.swift NekoWidget/Services/GroupWindowWire.swift \
  NekoWidget/Services/GroupWindowStorage.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift NekoWidget/Services/GroupReporting.swift \
  NekoWidget/Services/GroupReportingProvider.swift NekoWidget/Services/GroupReportDraftStore.swift \
  NekoWidget/Services/ProductionGroupReporting.swift ci/verify-group-reporting.swift \
  -o "$RUNNER_TEMP/group-reporting-tests"
"$RUNNER_TEMP/group-reporting-tests" ci/fixtures/group-report-v3.json
xcrun --sdk macosx swiftc -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  NekoWidget/Services/GroupInvitationLink.swift ci/verify-group-invitation-link.swift \
  -o "$RUNNER_TEMP/group-invitation-link-tests"
"$RUNNER_TEMP/group-invitation-link-tests"

xcrun --sdk macosx swiftc -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  NekoWidget/Services/CatCareCore.swift ci/verify-cat-care.swift \
  -o "$RUNNER_TEMP/cat-care-tests"
"$RUNNER_TEMP/cat-care-tests"

xcrun --sdk macosx swiftc -parse-as-library \
  NekoWidget/Services/PlusAuthorityCache.swift ci/verify-plus-authority-cache.swift \
  -o "$RUNNER_TEMP/plus-cache-tests"
"$RUNNER_TEMP/plus-cache-tests"

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
bounded 60 xcrun simctl boot "$device"
bounded 300 xcrun simctl bootstatus "$device" -b &
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
test "$(/usr/libexec/PlistBuddy -c 'Print GroupReportingProductionEnabled' "$app/Info.plist")" = "NO"
python3 ci/group-window-release.py --requested false --mode disabled \
  --app-info-plist "$app/Info.plist"
bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
if bounded 90 xcrun simctl install "$device" "$app"; then
  :
else
  install_status=$?
  # Retry only a timeout, never a build, signing, or application error. Reuse
  # the successful build on this runner; do not repeat compilation or tests.
  if [ "$install_status" -ne 124 ]; then exit "$install_status"; fi
  echo "Simulator install stalled; rebooting once and reusing the built app"
  bounded 30 xcrun simctl shutdown "$device"
  bounded 60 xcrun simctl boot "$device"
  bounded 120 xcrun simctl bootstatus "$device" -b
  bounded 90 xcrun simctl install "$device" "$app"
fi
launch=$(bounded 90 xcrun simctl launch "$device" "$bundle")
pid=${launch##*: }
sleep 5
xcrun simctl spawn "$device" launchctl list | awk -v pid="$pid" -v bundle="$bundle" '
  $1 == pid && index($0, bundle) { alive=1 }
  END { exit !alive }
'
mkdir -p "$RUNNER_TEMP/ci-screenshots"
xcrun simctl io "$device" screenshot "$RUNNER_TEMP/ci-screenshots/first-launch.png"
