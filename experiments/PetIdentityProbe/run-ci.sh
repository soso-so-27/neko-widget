#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
evidence="${RUNNER_TEMP:?}/pet-identity-evidence"
derived="$RUNNER_TEMP/PetIdentityProbeDerived"
mkdir -p "$evidence"
python3 prepare.py
if ! command -v xcodegen >/dev/null; then
  brew install xcodegen
fi
xcodegen generate

# A separate no-entitlements target; no production app or signing secrets used.
xcodebuild -project PetIdentityProbe.xcodeproj -scheme PetIdentityProbe \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived-device" \
  CODE_SIGNING_ALLOWED=NO build > "$evidence/device-build.log" 2>&1 || {
    tail -n 70 "$evidence/device-build.log"; exit 1;
  }

runtime=com.apple.CoreSimulator.SimRuntime.iOS-18-6
simulator=$(xcrun simctl create PetIdentityProbe com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$runtime")
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
xcodebuild -project PetIdentityProbe.xcodeproj -scheme PetIdentityProbe \
  -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "$derived" \
  -parallel-testing-enabled NO -only-testing:PetIdentityProbeTests \
  CODE_SIGNING_ALLOWED=NO test > "$evidence/simulator-test.log" 2>&1 || {
    tail -n 90 "$evidence/simulator-test.log"; exit 1;
  }
python3 summarize.py "$evidence/simulator-test.log" "$evidence/summary.json"

# Show the actual standalone first screen; do not add photos to the Simulator.
xcrun simctl launch "$simulator" local.nekomado.PetIdentityProbe
sleep 3
xcrun simctl io "$simulator" screenshot "$evidence/probe-screen.png"
du -sk "$derived-device/Build/Products/Debug-iphoneos/PetIdentityProbe.app" > "$evidence/unsigned-app-size-kib.txt"
shasum -a 256 Resources/model.onnx > "$evidence/model-sha256.txt"
# No IPA, model, xcframework, feature vectors or full xcresult is uploaded.
