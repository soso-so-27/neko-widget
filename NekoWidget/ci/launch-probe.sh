#!/usr/bin/env bash
# DIAGNOSTIC ONLY (branch claude/launch-time-probe, never merged).
# Launch several already-validated synthetic apps in ONE booted Simulator,
# interleaved, several times each, so Simulator/runner speed is shared and
# only the app differs. Usage: launch-probe.sh label=/path/NekoWidget.app ...
set -uo pipefail
out="${PROBE_OUT:-$RUNNER_TEMP/launch-probe}"
mkdir -p "$out/logs" "$out/shots"
summary="$out/summary.tsv"
printf 'round\tvariant\tmode\ti\tlaunch_s\tfirst_app_log_s\tapp_logs_before_return\talive\n' > "$summary"

runtime=$(xcrun simctl list runtimes -j | python3 -c '
import json,sys
items=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and ".iOS-" in r["identifier"]]
print(next((r for r in items if r["version"] == "26.2"), items[0])["identifier"])
')
device=$(xcrun simctl create NekoLaunchProbe com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$runtime")
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1; xcrun simctl delete "$device" >/dev/null 2>&1' EXIT
t=$(python3 -c 'import time;print(time.time())')
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b >/dev/null
echo "BOOT+bootstatus $(python3 -c "import time;print(round(time.time()-$t,1))")s"

now() { python3 -c 'import time;print(f"{time.time():.3f}")'; }
stamp() { python3 -c "import datetime,sys;print(datetime.datetime.fromtimestamp(float(sys.argv[1])).strftime('%Y-%m-%d %H:%M:%S'))" "$1"; }

one_launch() { # round variant mode i
  local bundle=jp.nekowidget.app tag="$1-$2-$3-$4"
  xcrun simctl terminate "$device" "$bundle" >/dev/null 2>&1 || true
  sleep 2
  local t0 t1 res pid alive
  t0=$(now)
  res=$(python3 -c 'import subprocess,sys
try:
 r=subprocess.run(sys.argv[1:],capture_output=True,text=True,timeout=90); print(r.stdout+r.stderr,end=""); sys.exit(r.returncode)
except subprocess.TimeoutExpired: sys.exit(124)' xcrun simctl launch "$device" "$bundle"); local st=$?
  t1=$(now)
  pid=${res##*: }
  sleep 6
  if xcrun simctl spawn "$device" launchctl list | awk -v pid="$pid" '$1 == pid { a=1 } END { exit !a }'; then alive=yes; else alive="no($st)"; fi
  # Everything the app process logged, and the system's lines about it.
  xcrun simctl spawn "$device" log show --start "$(stamp "$(python3 -c "print($t0-1)")")" \
    --info --debug --style compact \
    --predicate 'process == "NekoWidget" OR eventMessage CONTAINS "jp.nekowidget.app"' \
    > "$out/logs/$tag.log" 2>/dev/null || true
  python3 - "$out/logs/$tag.log" "$t0" "$t1" "$1" "$2" "$3" "$4" "$alive" >> "$summary" <<'PY'
import sys, datetime, re
path, t0, t1 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
first = None; before = 0
for line in open(path, errors="replace"):
    m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\s+\S+\s+(\S+)\[", line)
    if not m or not m.group(2).startswith("NekoWidget"): continue
    ts = datetime.datetime.strptime(m.group(1)[:26], "%Y-%m-%d %H:%M:%S.%f").timestamp()
    if ts < t0 - 0.5: continue
    if first is None: first = ts
    if ts <= t1: before += 1
fa = f"{first - t0:.2f}" if first else "-"
print("\t".join([sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7], f"{t1-t0:.2f}", fa, str(before), sys.argv[8]]))
PY
  tail -1 "$summary"
}

set_pref() { # key type value
  local c; c=$(xcrun simctl get_app_container "$device" jp.nekowidget.app data)
  xcrun simctl spawn "$device" defaults write "$c/Library/Preferences/jp.nekowidget.app" "$1" "$2" "$3"
}

rounds="${PROBE_ROUNDS:-2}"
for round in $(seq 1 "$rounds"); do
  specs=("$@")
  if (( round % 2 == 0 )); then specs=($(printf '%s\n' "$@" | tail -r)); fi
  for spec in "${specs[@]}"; do
    variant=${spec%%=*}; app=${spec#*=}
    xcrun simctl uninstall "$device" jp.nekowidget.app >/dev/null 2>&1 || true
    t=$(now); xcrun simctl install "$device" "$app"; echo "install $variant $(python3 -c "print(round($(now)-$t,1))")s"
    for i in 1 2 3; do one_launch "$round" "$variant" fresh "$i"; done
    xcrun simctl io "$device" screenshot "$out/shots/$round-$variant-fresh.png" >/dev/null 2>&1 || true
    xcrun simctl terminate "$device" jp.nekowidget.app >/dev/null 2>&1 || true
    set_pref onboarding.completedVersion -int 1
    set_pref navigation.lastTab.v1 -string memories
    for i in 1 2 3; do one_launch "$round" "$variant" tabs-memories "$i"; done
    xcrun simctl io "$device" screenshot "$out/shots/$round-$variant-memories.png" >/dev/null 2>&1 || true
    xcrun simctl terminate "$device" jp.nekowidget.app >/dev/null 2>&1 || true
    set_pref navigation.lastTab.v1 -string tools
    for i in 1 2 3; do one_launch "$round" "$variant" tabs-tools "$i"; done
    xcrun simctl io "$device" screenshot "$out/shots/$round-$variant-tools.png" >/dev/null 2>&1 || true
  done
done
echo "==== SUMMARY ===="
column -t -s $'\t' "$summary"
