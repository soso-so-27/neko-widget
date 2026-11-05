#!/usr/bin/env bash
set -euo pipefail
# Render the real production row and run the existing XCTest, without compiling
# unrelated photo/model fixtures. This is UI diagnosis, not release evidence.
source_root="$PWD"
probe="$RUNNER_TEMP/family-notebook-row-probe"
artifacts="$RUNNER_TEMP/neko-ui-diagnostic"
mkdir -p "$probe/App" "$probe/Tests" "$artifacts"
cp NekoWidget/Views/FamilyNotebookSharedCatRow.swift "$probe/App/FamilyNotebookSharedCatRow.swift"
python3 - "$probe" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
source = Path('NekoWidgetUITests/PhotoPermissionUITests.swift').read_text()
match = re.search(r'    @MainActor\n    func testFamilyNotebookUnshareRequiresConfirmation\(\) \{', source)
if not match:
    raise SystemExit('The actual family-row XCTest is missing')
start = match.start()
end = source.index('\n    @MainActor', match.end())
method = source[start:end]
if method.count('func test') != 1 or method.count('{') != method.count('}'):
    raise SystemExit('The actual family-row XCTest is not a single balanced method')
(root / 'Tests/FamilyRowTests.swift').write_text('import XCTest\nfinal class SoloMemoriesUITests: XCTestCase {\n' + method + '\n}\n')
(root / 'App/ProbeApp.swift').write_text('import SwiftUI\n@main struct ProbeApp: App { var body: some Scene { WindowGroup { FamilyNotebookUnshareFixture() } } }\n')
(root / 'project.yml').write_text('''name: FamilyRowProbe
options:
  bundleIdPrefix: jp.nekowidget.ui-probe
  deploymentTarget:
    iOS: "26.0"
settings:
  base:
    SWIFT_VERSION: "5.0"
    GENERATE_INFOPLIST_FILE: YES
    INFOPLIST_KEY_UILaunchScreen_Generation: YES
    TARGETED_DEVICE_FAMILY: "1,2"
targets:
  FamilyRowProbe:
    type: application
    platform: iOS
    sources: [App]
  NekoWidgetUITests:
    type: bundle.ui-testing
    platform: iOS
    sources: [Tests]
    dependencies:
      - target: FamilyRowProbe
schemes:
  FamilyRowProbe:
    build:
      targets:
        FamilyRowProbe: all
    test:
      targets: [NekoWidgetUITests]
''')
PY
if ! command -v xcodegen >/dev/null; then brew install xcodegen; fi
xcodegen generate --spec "$probe/project.yml" --project "$probe"
runtime="$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and "iOS" in x["name"]]; print(sorted(r,key=lambda x:tuple(map(int,x["version"].split("."))))[-1]["identifier"])')"
device_type="$(xcrun simctl list devicetypes --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["devicetypes"] if x["name"]=="iPhone 17 Pro"]; assert len(r)==1; print(r[0]["identifier"])')"
device="$(xcrun simctl create FamilyNotebookRowProbe "$device_type" "$runtime")"
cleanup() { xcrun simctl shutdown "$device" >/dev/null 2>&1 || true; xcrun simctl delete "$device" >/dev/null 2>&1 || true; }
trap cleanup EXIT
xcrun simctl boot "$device"
python3 ci/run-recorded-command.py --record "$artifacts/family-row-boot.json" --timeout 120 -- xcrun simctl bootstatus "$device" -b
status=0
python3 ci/run-recorded-command.py --record "$artifacts/family-row-test.json" --timeout 480 -- xcodebuild \
  -project "$probe/FamilyRowProbe.xcodeproj" -scheme FamilyRowProbe -configuration Debug \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$device" \
  -derivedDataPath "$probe/DerivedData" -resultBundlePath "$artifacts/FamilyRow.xcresult" \
  -only-testing:NekoWidgetUITests/SoloMemoriesUITests/testFamilyNotebookUnshareRequiresConfirmation \
  -parallel-testing-enabled NO -testLanguage ja -testRegion JP \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES \
  COMPILER_INDEX_STORE_ENABLE=NO test || status=$?
if [[ -d "$artifacts/FamilyRow.xcresult" ]]; then
  xcrun xcresulttool export attachments --path "$artifacts/FamilyRow.xcresult" --output-path "$artifacts/attachments" || true
fi
exit "$status"
