#!/usr/bin/env bash
# Ordinary CI: real unit tests, Release build, and one fresh-install launch.
# Full Photos/Widget/UI regressions remain in the opt-in workflow jobs.
set -euo pipefail
cd "$(dirname "$0")/.."
check_mode="${1:-all}"
case "$check_mode" in all|public|owner) ;; *) echo "Use all, public, or owner" >&2; exit 2 ;; esac

# Shared photo/memo fixtures remain available after removing the pair-window UI.
# Parse DEBUG sources too: the shipping Release build does not compile these branches.
xcrun swiftc -frontend -parse -D DEBUG \
  NekoWidget/Views/PhotoDetailComponents.swift NekoWidget/Views/PhotoNoteInput.swift \
  NekoWidget/Views/PhotoMemoryNoteFixture.swift NekoWidget/App/AppStoreScreenshotFixture.swift \
  NekoWidget/App/NekoWidgetApp.swift NekoWidget/Views/MainTabView.swift \
  NekoWidgetUITests/PhotoPermissionUITests.swift NekoWidget/Services/SharingRuntimeSelfTest.swift

# Parse the public, internal Release and DEBUG presentation variants. The
# ordinary Release build below supplies the public type/link check.
internal_boundary_sources=(
  Shared/Models/OfficialWindowCatalog.swift
  NekoWidget/Services/AppRecordPersistence.swift
  NekoWidget/Services/BillingFreshAccountAuthorization.swift
  NekoWidget/Services/BillingKeychainStore.swift
  NekoWidget/Services/GroupReporting.swift
  NekoWidget/Services/GroupReportingProvider.swift
  NekoWidget/Services/GroupWindowContract.swift
  NekoWidget/Services/MembershipOfferModel.swift
  NekoWidget/Services/PhotoBookPolicy.swift
  NekoWidget/Services/ProductionGroupWindowClient.swift
  NekoWidget/Views/AlbumPrototypeView.swift
  NekoWidget/Views/GroupWindowView.swift
  NekoWidget/Views/LikedPhotosView.swift
  NekoWidget/Views/LogView.swift
  NekoWidget/Views/ManagedPreservationView.swift
  NekoWidget/Views/SettingsView.swift
)
# macOS ships bash 3.2: expanding an empty array under nounset fails there.
xcrun swiftc -frontend -parse "${internal_boundary_sources[@]}"
xcrun swiftc -frontend -parse -D INTERNAL_PRESENTATION "${internal_boundary_sources[@]}"
xcrun swiftc -frontend -parse -D DEBUG "${internal_boundary_sources[@]}"

xcrun --sdk macosx swiftc -parse-as-library \
  NekoWidget/Services/PlusAuthorityCache.swift NekoWidget/Services/PlusRenewalPresentation.swift \
  ci/verify-plus-authority-cache.swift \
  -o "$RUNNER_TEMP/plus-cache-tests"
"$RUNNER_TEMP/plus-cache-tests"

# Cheap executor / intent observations precede either expensive product build.
python3 ci/prepare-autosave-background-probe.py "$RUNNER_TEMP/autosave-background.swift"
xcrun --sdk macosx swiftc -parse-as-library "$RUNNER_TEMP/autosave-background.swift" -o "$RUNNER_TEMP/autosave-background"
"$RUNNER_TEMP/autosave-background"
python3 ci/prepare-preservation-rebind-probe.py "$RUNNER_TEMP/preservation-rebind-probe.swift"
xcrun --sdk macosx swiftc -parse-as-library "$RUNNER_TEMP/preservation-rebind-probe.swift" -o "$RUNNER_TEMP/preservation-rebind-probe"
"$RUNNER_TEMP/preservation-rebind-probe"

owner_build_settings=(
  INTERNAL_PRESENTATION_CONDITION=INTERNAL_PRESENTATION
  OWNER_INTERNAL_REPORTS_DISABLED=YES GROUP_REPORTING_PRODUCTION_ENABLED=NO GROUP_WINDOWS_ENABLED=YES
  SHARING_RELEASE_MODE=media-staging SHARING_FEATURE_ENABLED=YES SHARING_MEDIA_ENABLED=YES
  SHARING_SHARE_EXTENSION_HANDOFF_ENABLED=YES SHARING_SHARE_EXTENSION_SEND_ENABLED=NO
  SHARING_REVIEW_PREVIEW_ENABLED=NO
  USAGE_REPORT_URL=https://neko-usage-staging.nakanishisoya.workers.dev/v1/usage
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
    assert 'INTERNAL_PRESENTATION' in settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'].split()
    assert settings['GROUP_REPORTING_PRODUCTION_ENABLED'] == 'NO'
    assert settings['SHARING_API_BASE_URL'] == 'https://neko-window-sharing-staging.nakanishisoya.workers.dev'
print('PASS resolved owner build settings before compilation')
PY
owner_settings_paths=("$RUNNER_TEMP/owner-internal-build-settings.json")
production_settings_paths=("$RUNNER_TEMP/production-group-share-settings.json")
for target in NekoWidgetShareExtension NekoWidgetWidgetExtension; do
  owner_output="$RUNNER_TEMP/owner-$target-settings.json"
  production_output="$RUNNER_TEMP/production-$target-settings.json"
  xcodebuild -project NekoWidget.xcodeproj -target "$target" -configuration Release \
    -sdk iphonesimulator "${owner_build_settings[@]}" -showBuildSettings -json > "$owner_output"
  xcodebuild -project NekoWidget.xcodeproj -target "$target" -configuration Release \
    -sdk iphonesimulator -xcconfig Config.Production.xcconfig -showBuildSettings -json > "$production_output"
  owner_settings_paths+=("$owner_output")
  production_settings_paths+=("$production_output")
done
python3 ci/preflight-group-share-settings.py "${owner_settings_paths[@]}" --owner-internal
xcodebuild -project NekoWidget.xcodeproj -scheme NekoWidget -configuration Release \
  -sdk iphonesimulator -xcconfig Config.Production.xcconfig -showBuildSettings -json \
  > "$RUNNER_TEMP/production-group-share-settings.json"
python3 ci/preflight-group-share-settings.py "${production_settings_paths[@]}"

check_owner_products() {
  # Owner-only reporting-OFF products: compile, inspect all three products, and
  # execute the configuration policy against those exact plists. Do not install
  # this staging-connected product or contact services from CI.
  xcodebuild -project NekoWidget.xcodeproj -scheme NekoWidget \
    -configuration Release -sdk iphonesimulator "${owner_build_settings[@]}" \
    -destination "generic/platform=iOS Simulator" ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
    -derivedDataPath "$RUNNER_TEMP/QuickOwnerBuild" \
    SWIFT_OPTIMIZATION_LEVEL=-Onone SWIFT_COMPILATION_MODE=singlefile \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES \
    build
  local app="$RUNNER_TEMP/QuickOwnerBuild/Build/Products/Release-iphonesimulator/NekoWidget.app"
  python3 ci/distribution_profile.py --profile owner-internal --mode media-staging \
    --internal-reports false --app "$app"
  xcrun --sdk macosx swiftc -parse-as-library Shared/Sharing/SharingAPIConfiguration.swift \
    ci/verify-owner-internal-products.swift -o "$RUNNER_TEMP/owner-internal-products"
  "$RUNNER_TEMP/owner-internal-products" "$app"
}

if [[ "$check_mode" == owner ]]; then
  check_owner_products
  exit 0
fi

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
  Shared/Models/AppSettings.swift Shared/Models/NekoCalendar.swift Shared/Models/NormalizedRect.swift \
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
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookCrypto.swift \
  NekoWidget/Services/FamilyNotebookInvitationCrypto.swift ci/verify-family-notebook-invitation.swift \
  -o "$RUNNER_TEMP/family-notebook-invitation-tests"
"$RUNNER_TEMP/family-notebook-invitation-tests"
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookCrypto.swift \
  NekoWidget/Services/FamilyNotebookTransport.swift NekoWidget/Services/FamilyNotebookInvitationCrypto.swift \
  NekoWidget/Services/FamilyNotebookKeyCoordinator.swift ci/verify-family-notebook-key-delivery.swift \
  -o "$RUNNER_TEMP/family-notebook-key-delivery-tests"
"$RUNNER_TEMP/family-notebook-key-delivery-tests"

bash ci/run-family-notebook-network-checks.sh
python3 ci/prepare-preservation-signin-probe.py "$RUNNER_TEMP/preservation-signin-probe.swift"
xcrun --sdk macosx swiftc -parse-as-library "$RUNNER_TEMP/preservation-signin-probe.swift" -o "$RUNNER_TEMP/preservation-signin-probe"
python3 ci/prepare-preservation-opening-probe.py "$RUNNER_TEMP/opening.swift"
swiftc -parse-as-library "$RUNNER_TEMP/opening.swift" -o "$RUNNER_TEMP/opening"
"$RUNNER_TEMP/opening"
"$RUNNER_TEMP/preservation-signin-probe"

xcrun --sdk macosx swiftc -D INTERNAL_PRESENTATION -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/GroupWindowAPIModels.swift NekoWidget/Services/GroupWindowPhotoValidation.swift \
  NekoWidget/Services/ProductionGroupWindowClient.swift ci/verify-group-adapter.swift \
  -o "$RUNNER_TEMP/group-adapter-tests"
"$RUNNER_TEMP/group-adapter-tests" ci/fixtures/group-http-v3.json ci/fixtures/group-roster-v3.json | node ci/verify-native-group-http.mjs
xcrun --sdk macosx swiftc -D GROUP_REPORT_CRYPTO_CHECKS -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/SharingAPIConfiguration.swift Shared/Sharing/GroupReportCrypto.swift ci/verify-group-report-crypto.swift \
  -o "$RUNNER_TEMP/group-report-crypto-tests"
"$RUNNER_TEMP/group-report-crypto-tests" ci/fixtures/group-report-v3.json | node ci/verify-group-report-crypto.mjs --swift-stdin
xcrun --sdk macosx swiftc -D INTERNAL_PRESENTATION -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift Shared/Sharing/GroupReportCrypto.swift \
  NekoWidget/Services/GroupWindowContract.swift NekoWidget/Services/GroupWindowWire.swift \
  NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
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
  NekoWidget/Services/FamilyNotebookRecordOrigin.swift \
  Shared/Models/NekoCalendar.swift NekoWidget/Services/CatCareCore.swift ci/verify-cat-care.swift \
  -o "$RUNNER_TEMP/cat-care-tests"
"$RUNNER_TEMP/cat-care-tests"

xcrun --sdk macosx swiftc -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  NekoWidget/Services/EvacuationPlan.swift ci/verify-evacuation-plan.swift \
  -o "$RUNNER_TEMP/evacuation-plan-tests"
"$RUNNER_TEMP/evacuation-plan-tests"

# 11/8: what the tools print (care memo, evacuation sheet, vet and lost-cat
# lines) from synthetic cats, so an output mistake stops CI, not a TestFlight build.
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  NekoWidget/Services/FamilyNotebookRecordOrigin.swift \
  Shared/Models/NekoCalendar.swift NekoWidget/Services/CatCareCore.swift NekoWidget/Services/CareHandoffPlan.swift \
  NekoWidget/Services/EvacuationPlan.swift NekoWidget/Services/CatCareOutputLines.swift \
  NekoWidget/Services/LostCatIncident.swift \
  ci/verify-tool-outputs.swift -o "$RUNNER_TEMP/tool-output-tests"
"$RUNNER_TEMP/tool-output-tests"



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
quick_launch_active=false
quick_launch_after_phase=after-launch
quick_snapshots="$RUNNER_TEMP/quick-launch-snapshots"
quick_snapshot() {
  python3 ci/quick_launch_diagnostics.py snapshot --device "$device" \
    --output "$quick_snapshots" --phase "$1" || true
}
quick_cleanup() {
  local original_status=$?
  trap - EXIT
  set +e
  if [[ "$quick_launch_active" == true && "$original_status" -ne 0 ]]; then
    quick_snapshot "$quick_launch_after_phase"
    bounded 35 python3 ci/quick_launch_diagnostics.py collect \
      --device "$device" --app "$app" \
      --contract "$RUNNER_TEMP/synthetic-production.json" \
      --snapshots "$quick_snapshots" --exit-status "$original_status" \
      --output "$RUNNER_TEMP/quick-launch-failure" \
      || echo "Launch diagnostics incomplete; original failure preserved." >&2
  fi
  xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
  xcrun simctl delete "$device" >/dev/null 2>&1 || true
  exit "$original_status"
}
trap quick_cleanup EXIT
bounded 60 xcrun simctl boot "$device"
bounded 300 xcrun simctl bootstatus "$device" -b &
boot_pid=$!

# Synthetic, complete public configuration: reserved .test endpoints, no real
# recipient, no upload. Inspect generated products before launch. Screenshots
# show only the first screen; the six 1.0 presentation items still need review.
python3 ci/production_candidate.py fixture --synthetic --contract "$RUNNER_TEMP/synthetic-production.json"
python3 ci/production_candidate.py build --synthetic --contract "$RUNNER_TEMP/synthetic-production.json" -- \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$device" ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath "$RUNNER_TEMP/QuickBuild" \
  SWIFT_OPTIMIZATION_LEVEL=-Onone SWIFT_COMPILATION_MODE=singlefile \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES build
app="$RUNNER_TEMP/QuickBuild/Build/Products/Release-iphonesimulator/NekoWidget.app"
quick_launch_active=true
wait "$boot_pid"
python3 ci/production_candidate.py products --synthetic --contract "$RUNNER_TEMP/synthetic-production.json" --path "$app"
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
quick_snapshot before-launch
if launch=$(bounded 90 xcrun simctl launch "$device" "$bundle"); then
  :
else
  launch_status=$?
  quick_snapshot after-launch
  # 40982324015 and 40996306345 stalled here after install succeeded.
  # A non-timeout application/launch error still fails immediately. Reset the
  # simulator once for a timeout; the same artifact must launch and stay alive.
  if [ "$launch_status" -ne 124 ]; then exit "$launch_status"; fi
  echo "Simulator launch stalled; rebooting once and reusing the installed app" >&2
  reboot_simulator
  quick_launch_after_phase=after-retry
  quick_snapshot before-retry
  launch=$(bounded 90 xcrun simctl launch "$device" "$bundle")
fi
pid=${launch##*: }
sleep 5
xcrun simctl spawn "$device" launchctl list | awk -v pid="$pid" -v bundle="$bundle" '
  $1 == pid && index($0, bundle) { alive=1 }
  END { exit !alive }
'
quick_launch_active=false
mkdir -p "$RUNNER_TEMP/ci-screenshots"
xcrun simctl io "$device" screenshot "$RUNNER_TEMP/ci-screenshots/first-launch.png"

if [[ "$check_mode" == all ]]; then check_owner_products; fi
