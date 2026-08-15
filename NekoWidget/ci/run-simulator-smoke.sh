#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIRECTORY="$PROJECT_DIRECTORY/ci/fixtures/cats"
VALIDATOR="$PROJECT_DIRECTORY/ci/validate-simulator-smoke.py"
ARTIFACT_DIRECTORY="${RUNNER_TEMP:?RUNNER_TEMP is required}/neko-smoke-artifacts"
DERIVED_DATA_DIRECTORY="$RUNNER_TEMP/NekoWidgetSmokeDerivedData"
RESULT_BUNDLE="$ARTIFACT_DIRECTORY/NekoWidgetSimulator.xcresult"

SIMULATOR_UDID=""
SIMULATOR_NAME=""
SIMULATOR_RUNTIME=""
APP_BUNDLE_ID=""
WIDGET_BUNDLE_ID=""
APP_GROUP_ID=""
APP_PID=""
APP_GROUP_CONTAINER=""
SCREENSHOT_CAPTURED="false"

mkdir -p "$ARTIFACT_DIRECTORY"
exec > >(tee -a "$ARTIFACT_DIRECTORY/smoke-test.log") 2>&1

resolve_group_container() {
    local direct_path=""
    local fallback_path=""

    if [[ -z "${SIMULATOR_UDID:-}" || -z "${APP_BUNDLE_ID:-}" || -z "${APP_GROUP_ID:-}" ]]; then
        return 1
    fi

    direct_path="$(
        xcrun simctl get_app_container \
            "$SIMULATOR_UDID" "$APP_BUNDLE_ID" "$APP_GROUP_ID" 2>/dev/null || true
    )"
    if [[ -n "$direct_path" && -d "$direct_path" ]]; then
        printf '%s\n' "$direct_path"
        return 0
    fi

    xcrun simctl get_app_container \
        "$SIMULATOR_UDID" "$APP_BUNDLE_ID" groups \
        > "$ARTIFACT_DIRECTORY/app-group-containers.txt" 2>/dev/null || return 1
    fallback_path="$(
        awk -v group="$APP_GROUP_ID" '
            {
                identifier = $1
                sub(/[:=]$/, "", identifier)
                if (identifier == group) {
                    $1 = ""
                    sub(/^[[:space:]:=]+/, "", $0)
                    print $0
                    exit
                }
            }
        ' "$ARTIFACT_DIRECTORY/app-group-containers.txt"
    )"
    if [[ -n "$fallback_path" && -d "$fallback_path" ]]; then
        printf '%s\n' "$fallback_path"
        return 0
    fi
    return 1
}

capture_screenshot() {
    if [[ -n "${SIMULATOR_UDID:-}" && "$SCREENSHOT_CAPTURED" != "true" ]]; then
        if xcrun simctl io "$SIMULATOR_UDID" \
            screenshot "$ARTIFACT_DIRECTORY/after-launch.png"; then
            SCREENSHOT_CAPTURED="true"
        fi
    fi
}

collect_and_cleanup() {
    local original_status=$?
    local recovered_group=""
    local crash_report=""

    trap - EXIT
    set +e
    printf '%s\n' "$original_status" > "$ARTIFACT_DIRECTORY/smoke-exit-code.txt"

    capture_screenshot

    if [[ -n "${SIMULATOR_UDID:-}" ]]; then
        xcrun simctl listapps "$SIMULATOR_UDID" \
            > "$ARTIFACT_DIRECTORY/installed-apps.txt" 2>&1

        if [[ -n "${APP_BUNDLE_ID:-}" ]]; then
            xcrun simctl spawn "$SIMULATOR_UDID" log show \
                --style compact \
                --last 10m \
                --predicate "process == 'NekoWidget' OR process == 'NekoWidgetWidgetExtension' OR subsystem == '$APP_BUNDLE_ID' OR subsystem == '$WIDGET_BUNDLE_ID'" \
                > "$ARTIFACT_DIRECTORY/simulator-unified.log" 2>&1
        fi

        recovered_group="$(resolve_group_container || true)"
        if [[ -n "$recovered_group" && -d "$recovered_group" ]]; then
            APP_GROUP_CONTAINER="$recovered_group"
            mkdir -p "$ARTIFACT_DIRECTORY/app-group"
            cp -R "$recovered_group/." "$ARTIFACT_DIRECTORY/app-group/"
            if [[ -d "$recovered_group/diagnostic-logs" ]]; then
                cp -R "$recovered_group/diagnostic-logs" \
                    "$ARTIFACT_DIRECTORY/shared-log-jsonl"
            fi
            for shared_file in library-snapshot.json widget-manifest.json; do
                if [[ -f "$recovered_group/$shared_file" ]]; then
                    cp "$recovered_group/$shared_file" \
                        "$ARTIFACT_DIRECTORY/$shared_file"
                fi
            done
            printf '%s\n' "$APP_GROUP_ID" \
                > "$ARTIFACT_DIRECTORY/app-group-identifier.txt"
        fi
    fi

    xcrun simctl list devices \
        > "$ARTIFACT_DIRECTORY/simctl-devices-final.txt" 2>&1

    mkdir -p "$ARTIFACT_DIRECTORY/crash-reports"
    while IFS= read -r crash_report; do
        cp "$crash_report" "$ARTIFACT_DIRECTORY/crash-reports/"
    done < <(
        find "$HOME/Library/Logs/DiagnosticReports" \
            -maxdepth 1 -type f \
            \( -name 'NekoWidget*.crash' -o -name 'NekoWidget*.ips' \) \
            -mmin -15 2>/dev/null || true
    )

    if [[ -n "${SIMULATOR_UDID:-}" ]]; then
        if [[ -n "${APP_BUNDLE_ID:-}" ]]; then
            xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" || true
        fi
        xcrun simctl shutdown "$SIMULATOR_UDID" || true
        xcrun simctl erase "$SIMULATOR_UDID" || true
    fi

    exit "$original_status"
}
trap collect_and_cleanup EXIT

printf 'Simulator smoke test started at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
sw_vers | tee "$ARTIFACT_DIRECTORY/macos-version.txt"
xcodebuild -version | tee "$ARTIFACT_DIRECTORY/xcode-version.txt"
xcrun simctl list devices available --json \
    > "$ARTIFACT_DIRECTORY/available-simulators.json"

python3 - \
    "$ARTIFACT_DIRECTORY/available-simulators.json" \
    "$ARTIFACT_DIRECTORY/selected-simulator.tsv" <<'PY'
import json
import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
devices = json.loads(source.read_text(encoding="utf-8"))["devices"]


def version(runtime: str) -> tuple[int, ...]:
    match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
    return tuple(int(part) for part in match.group(1).split("-")) if match else ()


for runtime in sorted(devices, key=version, reverse=True):
    candidates = [
        device
        for device in devices[runtime]
        if device.get("isAvailable", False)
        and str(device.get("name", "")).startswith("iPhone")
    ]
    if candidates:
        selected = candidates[0]
        destination.write_text(
            f"{selected['udid']}\t{selected['name']}\t{runtime}\n",
            encoding="utf-8",
        )
        break
else:
    raise SystemExit("No available iPhone Simulator was found.")
PY

IFS=$'\t' read -r SIMULATOR_UDID SIMULATOR_NAME SIMULATOR_RUNTIME \
    < "$ARTIFACT_DIRECTORY/selected-simulator.tsv"
if [[ -z "$SIMULATOR_UDID" || -z "$SIMULATOR_NAME" || -z "$SIMULATOR_RUNTIME" ]]; then
    echo "The selected Simulator record is incomplete." >&2
    exit 1
fi
printf 'Selected Simulator: %s (%s, %s)\n' \
    "$SIMULATOR_NAME" "$SIMULATOR_RUNTIME" "$SIMULATOR_UDID"

xcrun simctl shutdown "$SIMULATOR_UDID" || true
xcrun simctl erase "$SIMULATOR_UDID"
xcrun simctl boot "$SIMULATOR_UDID"
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
xcrun simctl status_bar "$SIMULATOR_UDID" override \
    --time 09:41 --batteryLevel 100 --batteryState charged || true

cd "$PROJECT_DIRECTORY"
xcodebuild \
    -project NekoWidget.xcodeproj \
    -scheme NekoWidget \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
    -derivedDataPath "$DERIVED_DATA_DIRECTORY" \
    -resultBundlePath "$RESULT_BUNDLE" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    build

APP_PATH="$DERIVED_DATA_DIRECTORY/Build/Products/Debug-iphonesimulator/NekoWidget.app"
EXTENSION_PATH="$APP_PATH/PlugIns/NekoWidgetWidgetExtension.appex"
if [[ ! -d "$APP_PATH" || ! -d "$EXTENSION_PATH" ]]; then
    echo "The built app or embedded Widget extension was not found." >&2
    exit 1
fi

APP_BUNDLE_ID="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist"
)"
WIDGET_BUNDLE_ID="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$EXTENSION_PATH/Info.plist"
)"
APP_GROUP_ID="$(
    /usr/libexec/PlistBuddy -c 'Print :AppGroupIdentifier' "$APP_PATH/Info.plist"
)"
printf 'App bundle: %s\nWidget bundle: %s\nApp Group: %s\n' \
    "$APP_BUNDLE_ID" "$WIDGET_BUNDLE_ID" "$APP_GROUP_ID" \
    | tee "$ARTIFACT_DIRECTORY/built-identifiers.txt"

codesign --verify --deep --strict "$APP_PATH"
codesign --verify --strict "$EXTENSION_PATH"
codesign --display --entitlements :- "$APP_PATH" \
    > "$ARTIFACT_DIRECTORY/app-codesign-entitlements.plist" \
    2> "$ARTIFACT_DIRECTORY/app-codesign.txt"
codesign --display --entitlements :- "$EXTENSION_PATH" \
    > "$ARTIFACT_DIRECTORY/widget-codesign-entitlements.plist" \
    2> "$ARTIFACT_DIRECTORY/widget-codesign.txt"
plutil -lint "$ARTIFACT_DIRECTORY/app-codesign-entitlements.plist"
plutil -lint "$ARTIFACT_DIRECTORY/widget-codesign-entitlements.plist"

# Xcode places restricted Simulator entitlements in a Mach-O section instead
# of the ad-hoc code-signature dictionary. Validate the exact generated xcent
# files that its linker embeds into the app and extension executables.
APP_SIMULATOR_ENTITLEMENTS="$(
    find "$DERIVED_DATA_DIRECTORY/Build/Intermediates.noindex" \
        -type f -name 'NekoWidget.app-Simulated.xcent' -print -quit
)"
WIDGET_SIMULATOR_ENTITLEMENTS="$(
    find "$DERIVED_DATA_DIRECTORY/Build/Intermediates.noindex" \
        -type f -name 'NekoWidgetWidgetExtension.appex-Simulated.xcent' -print -quit
)"
if [[ -z "$APP_SIMULATOR_ENTITLEMENTS" \
    || -z "$WIDGET_SIMULATOR_ENTITLEMENTS" ]]; then
    echo "Xcode did not generate the expected Simulator entitlement files." >&2
    exit 1
fi
cp "$APP_SIMULATOR_ENTITLEMENTS" \
    "$ARTIFACT_DIRECTORY/app-simulator-entitlements.plist"
cp "$WIDGET_SIMULATOR_ENTITLEMENTS" \
    "$ARTIFACT_DIRECTORY/widget-simulator-entitlements.plist"
plutil -lint "$ARTIFACT_DIRECTORY/app-simulator-entitlements.plist"
plutil -lint "$ARTIFACT_DIRECTORY/widget-simulator-entitlements.plist"

python3 - \
    "$ARTIFACT_DIRECTORY/app-simulator-entitlements.plist" \
    "$ARTIFACT_DIRECTORY/widget-simulator-entitlements.plist" \
    "$ARTIFACT_DIRECTORY/app-codesign-entitlements.plist" \
    "$ARTIFACT_DIRECTORY/widget-codesign-entitlements.plist" \
    "$APP_GROUP_ID" \
    "$ARTIFACT_DIRECTORY/entitlement-validation.json" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

app_path = Path(sys.argv[1])
widget_path = Path(sys.argv[2])
app_codesign_path = Path(sys.argv[3])
widget_codesign_path = Path(sys.argv[4])
expected_group = sys.argv[5]
report_path = Path(sys.argv[6])

with app_path.open("rb") as stream:
    app = plistlib.load(stream)
with widget_path.open("rb") as stream:
    widget = plistlib.load(stream)
with app_codesign_path.open("rb") as stream:
    app_codesign = plistlib.load(stream)
with widget_codesign_path.open("rb") as stream:
    widget_codesign = plistlib.load(stream)

key = "com.apple.security.application-groups"
app_groups = app.get(key, [])
widget_groups = widget.get(key, [])
report = {
    "expectedAppGroup": expected_group,
    "simulatorAppGroups": app_groups,
    "simulatorWidgetGroups": widget_groups,
    "codeSignAppGroups": app_codesign.get(key, []),
    "codeSignWidgetGroups": widget_codesign.get(key, []),
    "match": app_groups == widget_groups and expected_group in app_groups,
}
report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
print(json.dumps(report, indent=2, sort_keys=True))
if not report["match"]:
    raise SystemExit("App and Widget App Group entitlements do not match.")
PY

xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"

shopt -s nullglob
FIXTURES=("$FIXTURE_DIRECTORY"/*.png)
shopt -u nullglob
FIXTURE_COUNT=${#FIXTURES[@]}
if (( FIXTURE_COUNT < 3 )); then
    echo "At least three PNG fixtures are required; found $FIXTURE_COUNT." >&2
    exit 1
fi
printf '%s\n' "${FIXTURES[@]}" > "$ARTIFACT_DIRECTORY/fixture-paths.txt"
xcrun simctl addmedia "$SIMULATOR_UDID" "${FIXTURES[@]}"
sleep 8

xcrun simctl privacy "$SIMULATOR_UDID" grant photos "$APP_BUNDLE_ID"
LAUNCH_OUTPUT="$(
    xcrun simctl launch --terminate-running-process \
        "$SIMULATOR_UDID" "$APP_BUNDLE_ID"
)"
printf '%s\n' "$LAUNCH_OUTPUT" | tee "$ARTIFACT_DIRECTORY/launch.txt"
APP_PID="${LAUNCH_OUTPUT##*: }"
if [[ ! "$APP_PID" =~ ^[0-9]+$ ]]; then
    echo "simctl did not return a numeric app PID: $LAUNCH_OUTPUT" >&2
    exit 1
fi

TERMINAL_EVENT_FOUND="false"
for attempt in $(seq 1 90); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "The app process exited before the smoke test completed." >&2
        break
    fi

    APP_GROUP_CONTAINER="$(resolve_group_container || true)"
    if [[ -n "$APP_GROUP_CONTAINER" \
        && -d "$APP_GROUP_CONTAINER/diagnostic-logs" ]] \
        && grep -R -q 'Widget timeline reload requested' \
            "$APP_GROUP_CONTAINER/diagnostic-logs"; then
        TERMINAL_EVENT_FOUND="true"
        printf 'Terminal log event found after %d second(s).\n' "$((attempt * 2))"
        break
    fi
    sleep 2
done

capture_screenshot

APP_GROUP_CONTAINER="$(resolve_group_container || true)"
if [[ -z "$APP_GROUP_CONTAINER" || ! -d "$APP_GROUP_CONTAINER" ]]; then
    echo "The App Group container could not be resolved after launch." >&2
    exit 1
fi

python3 "$VALIDATOR" \
    "$APP_GROUP_CONTAINER" \
    "$FIXTURE_COUNT" \
    "$ARTIFACT_DIRECTORY/validation-report.json"

if [[ "$TERMINAL_EVENT_FOUND" != "true" ]]; then
    echo "Timed out waiting for the widget timeline reload event." >&2
    exit 1
fi
if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "The app process exited after producing its final scan artifacts." >&2
    exit 1
fi

printf 'Simulator smoke test passed at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
