#!/usr/bin/env bash
# Disposable hosted Simulator only; no accounts, service secrets or deployment.
set -euo pipefail
cd "$(dirname "$0")/.."
layer="${1:?unit or ui}"
shard="${2:-0}"
[[ "$layer" == unit || "$layer" == ui ]]
[[ "$shard" =~ ^[0-3]$ ]]
out="$RUNNER_TEMP/native-$layer-$shard"
mkdir -p "$out"
runtime=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and ".iOS-" in x["identifier"]]; print(max(r,key=lambda x:tuple(map(int,x["version"].split("."))))["identifier"])')
device=$(xcrun simctl create "NekoTests-$layer-$shard" com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$runtime")
cleanup() {
  xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
  xcrun simctl delete "$device" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$device"
python3 - "$device" <<'PY'
import subprocess,sys
subprocess.run(['xcrun','simctl','bootstatus',sys.argv[1],'-b'],check=True,timeout=120)
PY
scheme=NekoWidgetTests
selection=(-only-testing:NekoWidgetTests)
if [[ "$layer" == ui ]]; then
  scheme=NekoWidget
  python3 ci/native-ui-inventory.py select "$shard" "$out/selected.txt"
  selection=()
  while IFS= read -r test; do selection+=("-only-testing:$test"); done < "$out/selected.txt"
  # Existing generated fixture photos only; never a user's photo library.
  xcrun simctl addmedia "$device" ci/fixtures/cats/*.png
fi
status=0
xcodebuild -project NekoWidget.xcodeproj -scheme "$scheme" \
  -configuration Debug -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$device" \
  -derivedDataPath "$RUNNER_TEMP/Native-$layer-$shard" \
  -resultBundlePath "$out/Tests.xcresult" \
  "${selection[@]}" -parallel-testing-enabled NO \
  -testLanguage ja -testRegion JP \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES \
  ONLY_ACTIVE_ARCH=YES ENABLE_TESTABILITY=YES \
  test 2>&1 | tee "$out/xcodebuild.log" || status=$?
if [[ "$layer" == ui ]]; then
  python3 ci/native-ui-inventory.py report "$out/selected.txt" "$out/xcodebuild.log" "$out/results.md" || status=1
fi
exit "$status"
