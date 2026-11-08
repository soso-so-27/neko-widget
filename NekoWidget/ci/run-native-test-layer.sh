#!/usr/bin/env bash
# Disposable hosted Simulator only; no accounts, service secrets or deployment.
set -euo pipefail
cd "$(dirname "$0")/.."
layer="${1:?unit or ui}"
shard="${2:-0}"
[[ "$layer" == unit || "$layer" == ui ]]
[[ "$shard" =~ ^[0-3]$ ]]
route="${3:-standard}"
out="$RUNNER_TEMP/native-$layer-$route-$shard"
if [[ "$layer" == unit ]]; then out="$RUNNER_TEMP/native-unit-$shard"; fi
mkdir -p "$out"
if [[ "$layer" == ui ]]; then
  python3 ci/native-ui-inventory.py select "$shard" "$out/selected.txt" "$route" "${NEKO_NATIVE_FILTER:-}"
  if [[ "$route" == widget || "$route" == movie ]]; then
    status=0
    while IFS= read -r selected; do
      # Restore only the two generated fixture templates in this disposable CI checkout.
      git restore --worktree -- NekoWidgetWidget/NekoWidgetView.swift NekoWidget/Views/PhotoNoteInput.swift
      export NEKO_NATIVE_TEST_SELECTION="$selected"
      export NEKO_IOS_RUNTIME_LANE=app-ui
      bash ci/run-sharing-runtime-matrix.sh > "$out/$(basename "$selected").log" 2>&1 || status=1
      cat "$out/$(basename "$selected").log"
    done < "$out/selected.txt"
    cat "$out/"*.log > "$out/xcodebuild.log"
    python3 ci/native-ui-inventory.py report "$out/selected.txt" "$out/xcodebuild.log" "$out/results.md" || status=1
    cat "$out/results.md" >> "$GITHUB_STEP_SUMMARY"
    exit "$status"
  fi
fi
device_type=com.apple.CoreSimulator.SimDeviceType.iPhone-16
if [[ "$route" == ipad ]]; then
  device_type=$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys; ds=[d for d in json.load(sys.stdin)["devicetypes"] if d["name"].startswith("iPad")]; print(next((d for d in ds if d["name"]=="iPad (A16)"),ds[0])["identifier"])')
fi
runtime=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and ".iOS-" in x["identifier"]]; print(max(r,key=lambda x:tuple(map(int,x["version"].split("."))))["identifier"])')
device=$(xcrun simctl create "NekoTests-$layer-$shard" "$device_type" "$runtime")
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
  selection=()
  while IFS= read -r test; do selection+=("-only-testing:$test"); done < "$out/selected.txt"
  # Existing generated fixture photos only; never a user's photo library.
  if [[ "$route" != empty ]]; then xcrun simctl addmedia "$device" ci/fixtures/cats/*.png; fi
fi
status=0
if [[ "$route" == ipad || "$route" == release ]]; then
  python3 ci/production_candidate.py fixture --synthetic --contract "$out/contract.json"
  python3 ci/production_candidate.py build --synthetic --contract "$out/contract.json" -- \
    build-for-testing -sdk iphonesimulator -destination "platform=iOS Simulator,id=$device" \
    -derivedDataPath "$out/build" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
    AD_HOC_CODE_SIGNING_ALLOWED=YES ONLY_ACTIVE_ARCH=YES SWIFT_OPTIMIZATION_LEVEL=-Onone SWIFT_COMPILATION_MODE=singlefile \
    2>&1 | tee "$out/build.log"
  runs=("$out/build/Build/Products/"*.xctestrun)
  [[ ${#runs[@]} == 1 && -f "${runs[0]}" ]]
  xcodebuild test-without-building -xctestrun "${runs[0]}" \
    -destination "platform=iOS Simulator,id=$device" -resultBundlePath "$out/Tests.xcresult" \
    "${selection[@]}" -parallel-testing-enabled NO -testLanguage ja -testRegion JP \
    2>&1 | tee "$out/xcodebuild.log" || status=$?
else
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
fi
if [[ "$layer" == ui ]]; then
  python3 ci/native-ui-inventory.py report "$out/selected.txt" "$out/xcodebuild.log" "$out/results.md" || status=1
  cat "$out/results.md" >> "$GITHUB_STEP_SUMMARY"
fi
exit "$status"
