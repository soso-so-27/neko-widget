#!/usr/bin/env bash
# Same synthetic product, fresh hosted runner; no compilation and no real services.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${QUICK_APP_PATH:-$RUNNER_TEMP/QuickBuild/Build/Products/Release-iphonesimulator/NekoWidget.app}"
python3 ci/production_candidate.py fixture --synthetic --contract "$RUNNER_TEMP/synthetic-production.json"
python3 ci/production_candidate.py products --synthetic --contract "$RUNNER_TEMP/synthetic-production.json" --path "$app"
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
quick_observe() {
  bounded 30 python3 ci/quick_launch_diagnostics.py observe --device "$device" \
    --output "$RUNNER_TEMP/quick-launch-failure/$1" || true
}
quick_cleanup() {
  local original_status=$?
  trap - EXIT
  set +e
  if [[ "$quick_launch_active" == true && "$original_status" -ne 0 ]]; then
    quick_observe final-failure
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
quick_launch_active=true
bounded 60 xcrun simctl boot "$device"
bounded 300 xcrun simctl bootstatus "$device" -b
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
  quick_observe install-failure
  # Only this first-install timeout may move to another hosted Mac. The
  # explicit output distinguishes it from any other command returning 124.
  if [ "$install_status" -ne 124 ]; then exit "$install_status"; fi
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "install_timeout=true" >> "$GITHUB_OUTPUT"; fi
  echo "First install timed out; end this Mac attempt without launching." >&2
  exit 124
fi
quick_snapshot before-launch
if launch=$(bounded 90 xcrun simctl launch "$device" "$bundle"); then
  :
else
  launch_status=$?
  quick_snapshot after-launch
  quick_observe first-launch-failure
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

