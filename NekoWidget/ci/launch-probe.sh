#!/usr/bin/env bash
# DIAGNOSTIC ONLY (branch diagnostic/cat-home-care-launch-*, never merged).
# Launch already-built synthetic apps (this PR's and main's as control) in one
# fresh Simulator and keep what the normal job scrubs: the console output of
# `simctl launch --console-pty`, the app's own log lines and launch-related
# system lines, and any crash report naming NekoWidget. Synthetic builds only.
# Usage: launch-probe.sh label=/path/NekoWidget.app ...
set -uo pipefail
out="${PROBE_OUT:-$RUNNER_TEMP/launch-probe}"
mkdir -p "$out"
bundle=jp.nekowidget.app

runtime=$(xcrun simctl list runtimes -j | python3 -c '
import json,sys
items=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and ".iOS-" in r["identifier"]]
print(next((r for r in items if r["version"] == "26.2"), items[0])["identifier"])
')
device=$(xcrun simctl create NekoLaunchProbe com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$runtime")
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1; xcrun simctl delete "$device" >/dev/null 2>&1' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b >/dev/null
echo "booted $device"

bounded() { # seconds command...
  python3 - "$@" <<'PY'
import subprocess, sys
try:
    sys.exit(subprocess.run(sys.argv[2:], timeout=int(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    print(f"TIMEOUT after {sys.argv[1]}s: {' '.join(sys.argv[2:4])}", flush=True)
    sys.exit(124)
PY
}

reports_before=$(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | sort)

for spec in "$@"; do
  label=${spec%%=*}; app=${spec#*=}
  dir="$out/$label"; mkdir -p "$dir"
  xcrun simctl uninstall "$device" "$bundle" >/dev/null 2>&1 || true
  start=$(date -u '+%Y-%m-%d %H:%M:%S')
  bounded 120 xcrun simctl install "$device" "$app" > "$dir/install.txt" 2>&1; echo "install $label: $?"
  # --console-pty stays attached to the app's stdout/stderr; stop it after 60 s.
  bounded 60 xcrun simctl launch --console-pty --terminate-running-process "$device" "$bundle" \
    > "$dir/console.txt" 2>&1; echo "launch $label: $?" | tee "$dir/launch-status.txt"
  sleep 3
  xcrun simctl spawn "$device" launchctl list 2>/dev/null | grep -i nekowidget > "$dir/launchctl.txt" || true
  xcrun simctl io "$device" screenshot "$dir/screen.png" >/dev/null 2>&1 || true
  bounded 60 xcrun simctl spawn "$device" log show --start "$start" --info --debug --style compact \
    --predicate 'process == "NekoWidget" OR (eventMessage CONTAINS[c] "nekowidget" AND (process == "runningboardd" OR process == "SpringBoard" OR process == "launchd" OR process == "ReportCrash" OR process == "dyld" OR process == "kernel" OR process == "amfid" OR process == "installcoordinationd"))' \
    > "$dir/log.txt" 2>&1 || true
  bounded 30 xcrun simctl terminate "$device" "$bundle" >/dev/null 2>&1 || true
  # Crash reports written since the start that name the app.
  mkdir -p "$dir/reports"
  for f in ~/Library/Logs/DiagnosticReports/*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    if ! grep -qxF "$name" <<<"$reports_before" && grep -q -i nekowidget "$f" 2>/dev/null; then
      cp "$f" "$dir/reports/"
    fi
  done
  reports_before=$(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | sort)
  echo "== $label console (head)"; head -60 "$dir/console.txt"
  echo "== $label reports"; ls "$dir/reports"
  for f in "$dir"/reports/*; do [ -f "$f" ] && head -c 6000 "$f"; done
  echo "== $label log (errors/faults/launch)"; grep -i -E "fault|error|crash|terminat|exception|fatal|launch|dyld|assert" "$dir/log.txt" | head -80
done
