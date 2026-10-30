#!/usr/bin/env bash
# Ordinary CI: real unit tests, Release build, and one fresh-install launch.
# Full Photos/Widget/UI regressions remain in the opt-in workflow jobs.
set -euo pipefail
cd "$(dirname "$0")/.."

owner_build_settings=(
  OWNER_INTERNAL_REPORTS_DISABLED=YES GROUP_REPORTING_PRODUCTION_ENABLED=NO
  SHARING_RELEASE_MODE=media-staging SHARING_FEATURE_ENABLED=YES SHARING_MEDIA_ENABLED=YES
  SHARING_SHARE_EXTENSION_HANDOFF_ENABLED=YES SHARING_SHARE_EXTENSION_SEND_ENABLED=NO
  SHARING_REVIEW_PREVIEW_ENABLED=NO
  SHARING_API_BASE_URL=https://neko-window-sharing-staging.nakanishisoya.workers.dev
  SHARING_MODERATION_KEY_ID=moderation-v2
  SHARING_MODERATION_PUBLIC_KEY=T5C7__1xlc4XmIDr6zTJqMtdhBjPnMD10O3vFK_bYWg
  SHARING_PRIVACY_URL=https://soso-so-27.github.io/neko-widget/privacy/
  SHARING_SUPPORT_URL=https://soso-so-27.github.io/neko-widget/support/
  SHARING_COMMUNITY_STANDARDS_URL=https://soso-so-27.github.io/neko-widget/community/
)
# -xcconfig overrides command-line settings, including OFF=YES. Match the
# release workflow's command-line route and resolve it before compilation.
xcodebuild -project NekoWidget.xcodeproj -scheme NekoWidget -configuration Release \
  -sdk iphonesimulator "${owner_build_settings[@]}" -showBuildSettings -json \
  > "$RUNNER_TEMP/owner-internal-build-settings.json"
python3 - "$RUNNER_TEMP/owner-internal-build-settings.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
assert rows and any(row['target'] == 'NekoWidget' for row in rows)
for row in rows:
    settings = row['buildSettings']
    assert settings['OWNER_INTERNAL_REPORTS_DISABLED'] == 'YES', 'owner OFF overlay was overridden'
    assert settings['SHARING_RELEASE_MODE'] == 'media-staging'
    assert settings['GROUP_REPORTING_PRODUCTION_ENABLED'] == 'NO'
    assert settings['SHARING_API_BASE_URL'] == 'https://neko-window-sharing-staging.nakanishisoya.workers.dev'
print('PASS resolved owner build settings before compilation')
PY

# CoreSimulator installation can hang after a successful build. Bound the
# simulator commands so an environment stall cannot consume the entire job.
bounded() {
  python3 - "$@" <<'PY'
import subprocess, sys, time
started = time.monotonic()
command = sys.argv[2:]
label = " ".join(command[:3])
print(f"START {label} (limit {sys.argv[1]}s)", file=sys.stderr, flush=True)
try:
    result = subprocess.run(command, timeout=int(sys.argv[1]))
    print(f"END {label}: exit {result.returncode}, {time.monotonic()-started:.1f}s", file=sys.stderr, flush=True)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print(f"TIMEOUT {label}: {time.monotonic()-started:.1f}s", file=sys.stderr, flush=True)
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
  NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookCrypto.swift \
  NekoWidget/Services/FamilyNotebookInvitationCrypto.swift ci/verify-family-notebook-invitation.swift \
  -o "$RUNNER_TEMP/family-notebook-invitation-tests"
"$RUNNER_TEMP/family-notebook-invitation-tests"
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookCrypto.swift \
  NekoWidget/Services/FamilyNotebookTransport.swift NekoWidget/Services/FamilyNotebookInvitationCrypto.swift \
  NekoWidget/Services/FamilyNotebookKeyCoordinator.swift ci/verify-family-notebook-key-delivery.swift \
  -o "$RUNNER_TEMP/family-notebook-key-delivery-tests"
"$RUNNER_TEMP/family-notebook-key-delivery-tests"

xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift NekoWidget/Services/GroupWindowTransport.swift \
  Shared/Models/AppSettings.swift Shared/Models/NormalizedRect.swift \
  Shared/Models/CatCandidateCuration.swift Shared/Models/CatHouseholdIdentity.swift \
  Shared/Models/CatProfileTransfer.swift Shared/Models/NekoWidgetError.swift \
  Shared/Models/WidgetRenderPlan.swift Shared/Models/WidgetManifest.swift \
  Shared/Storage/AtomicJSON.swift Shared/AppGroup/SharedContainer.swift \
  NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookStore.swift \
  NekoWidget/Services/FamilyNotebookCrypto.swift NekoWidget/Services/FamilyNotebookTransport.swift \
  NekoWidget/Services/FamilyNotebookInvitationCrypto.swift NekoWidget/Services/FamilyNotebookKeyCoordinator.swift \
  NekoWidget/Services/FamilyNotebookSharingContract.swift NekoWidget/Services/FamilyNotebookMembershipClient.swift \
  NekoWidget/Services/FamilyNotebookSync.swift NekoWidget/Services/FamilyNotebookAdmissionClient.swift \
  NekoWidget/Services/ProductionFamilyNotebookSharingService.swift ci/verify-family-notebook-service.swift \
  -o "$RUNNER_TEMP/family-notebook-service-tests"
"$RUNNER_TEMP/family-notebook-service-tests"

xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/FamilyNotebookTransport.swift ci/verify-family-notebook-transport.swift \
  -o "$RUNNER_TEMP/family-notebook-transport-tests"
"$RUNNER_TEMP/family-notebook-transport-tests"

xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/GroupWindowAPIModels.swift NekoWidget/Services/GroupWindowPhotoValidation.swift \
  NekoWidget/Services/ProductionGroupWindowClient.swift ci/verify-group-adapter.swift \
  -o "$RUNNER_TEMP/group-adapter-tests"
"$RUNNER_TEMP/group-adapter-tests" ci/fixtures/group-http-v3.json ci/fixtures/group-roster-v3.json | node ci/verify-native-group-http.mjs
xcrun --sdk macosx swiftc -D GROUP_REPORT_CRYPTO_CHECKS -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/SharingAPIConfiguration.swift Shared/Sharing/GroupReportCrypto.swift ci/verify-group-report-crypto.swift \
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

# Compile and launch the explicit public template once; empty endpoints cannot
# reach production. Ordinary disabled Release settings were checked above.
xcodebuild -project NekoWidget.xcodeproj -scheme NekoWidget \
  -configuration Release -sdk iphonesimulator -xcconfig Config.Production.xcconfig \
  -destination "platform=iOS Simulator,id=$device" ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath "$RUNNER_TEMP/QuickBuild" \
  SWIFT_OPTIMIZATION_LEVEL=-Onone SWIFT_COMPILATION_MODE=singlefile \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES \
  build
wait "$boot_pid"
app="$RUNNER_TEMP/QuickBuild/Build/Products/Release-iphonesimulator/NekoWidget.app"
python3 - "$app" <<'PY'
from pathlib import Path
import plistlib, sys
app = Path(sys.argv[1])
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info['SharingReleaseMode'] == 'production'
assert info['GroupReportingProductionEnabled'] == 'YES'
assert info['PersonalArchiveReadOnly'] == 'YES'
assert not info.get('SharingAPIBaseURL'), 'CI template must not contact a real service'
assert not info.get('SharingModerationPublicKey'), 'CI template must not contain a real recipient'
actual = plistlib.loads((app / 'PrivacyInfo.xcprivacy').read_bytes())
expected = plistlib.loads(Path('Production/PrivacyInfo.xcprivacy').read_bytes())
assert actual == expected, 'public app bundled the wrong privacy manifest'
print('PASS public template Info.plist and bundled privacy manifest (not a distributable archive)')
PY
bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
reboot_simulator() {
  bounded 30 xcrun simctl shutdown "$device"
  bounded 60 xcrun simctl boot "$device"
  bounded 120 xcrun simctl bootstatus "$device" -b
}
if bounded 90 xcrun simctl install "$device" "$app"; then
  :
else
  install_status=$?
  # Retry only a timeout, never a build, signing, or application error. Reuse
  # the successful build on this runner; do not repeat compilation or tests.
  if [ "$install_status" -ne 124 ]; then exit "$install_status"; fi
  echo "Simulator install stalled; rebooting once and reusing the built app"
  reboot_simulator
  bounded 90 xcrun simctl install "$device" "$app"
fi
if launch=$(bounded 90 xcrun simctl launch "$device" "$bundle"); then
  :
else
  launch_status=$?
  # 40982324015 and 40996306345 stalled here after install succeeded.
  # A non-timeout application/launch error still fails immediately. Reset the
  # simulator once for a timeout; the same artifact must launch and stay alive.
  if [ "$launch_status" -ne 124 ]; then exit "$launch_status"; fi
  echo "Simulator launch stalled; rebooting once and reusing the installed app" >&2
  reboot_simulator
  launch=$(bounded 90 xcrun simctl launch "$device" "$bundle")
fi
pid=${launch##*: }
sleep 5
xcrun simctl spawn "$device" launchctl list | awk -v pid="$pid" -v bundle="$bundle" '
  $1 == pid && index($0, bundle) { alive=1 }
  END { exit !alive }
'
mkdir -p "$RUNNER_TEMP/ci-screenshots"
xcrun simctl io "$device" screenshot "$RUNNER_TEMP/ci-screenshots/first-launch.png"

# Owner-only reporting-OFF products: compile, inspect all three products, and
# execute the configuration policy against those exact plists. Do not install
# this staging-connected product or contact services from CI.
xcodebuild -project NekoWidget.xcodeproj -scheme NekoWidget \
  -configuration Release -sdk iphonesimulator "${owner_build_settings[@]}" \
  -destination "platform=iOS Simulator,id=$device" ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath "$RUNNER_TEMP/QuickBuild" \
  SWIFT_OPTIMIZATION_LEVEL=-Onone SWIFT_COMPILATION_MODE=singlefile \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES \
  build
python3 ci/distribution_profile.py --profile owner-internal --mode media-staging \
  --internal-reports false --app "$app"
xcrun --sdk macosx swiftc -parse-as-library Shared/Sharing/SharingAPIConfiguration.swift \
  ci/verify-owner-internal-products.swift -o "$RUNNER_TEMP/owner-internal-products"
"$RUNNER_TEMP/owner-internal-products" "$app"
