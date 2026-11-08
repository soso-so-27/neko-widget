#!/usr/bin/env bash
set -euo pipefail
# Exercise the real save fixture/XCTest directly. This does not claim a pass
# for the independent sharing runtime matrix or replace any release check.
artifacts="$RUNNER_TEMP/neko-ui-diagnostic"
mkdir -p "$artifacts"
runtime="$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and x["version"]=="26.2" and "iOS" in x["name"]]; assert len(r)==1; print(r[0]["identifier"])')"
device_type="$(xcrun simctl list devicetypes --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["devicetypes"] if x["name"]=="iPhone 17 Pro"]; assert len(r)==1; print(r[0]["identifier"])')"
device="$(xcrun simctl create AutomaticSaveProbe "$device_type" "$runtime")"
cleanup() { xcrun simctl shutdown "$device" >/dev/null 2>&1 || true; xcrun simctl delete "$device" >/dev/null 2>&1 || true; }
trap cleanup EXIT
xcrun simctl boot "$device"
python3 ci/run-recorded-command.py --record "$artifacts/autosave-boot.json" --timeout 120 -- xcrun simctl bootstatus "$device" -b
status=0
python3 ci/run-recorded-command.py --record "$artifacts/autosave-test.json" --timeout 1200 -- xcodebuild \
  -project NekoWidget.xcodeproj -scheme NekoWidget -configuration Debug \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$device" \
  -derivedDataPath "$RUNNER_TEMP/AutoSaveProbeBuild" -resultBundlePath "$artifacts/AutoSave.xcresult" \
  -only-testing:NekoWidgetUITests/SoloMemoriesUITests/testAutomaticSaveEfficiencyAndCleanupPriority \
  -parallel-testing-enabled NO -testLanguage ja -testRegion JP \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES \
  COMPILER_INDEX_STORE_ENABLE=NO test || status=$?
if [[ -d "$artifacts/AutoSave.xcresult" ]]; then
  xcrun xcresulttool export attachments --path "$artifacts/AutoSave.xcresult" --output-path "$artifacts/attachments" || true
fi
exit "$status"
