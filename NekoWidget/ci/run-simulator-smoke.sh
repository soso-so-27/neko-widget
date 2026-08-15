#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIRECTORY="$PROJECT_DIRECTORY/ci/fixtures/cats"
VALIDATOR="$PROJECT_DIRECTORY/ci/validate-simulator-smoke.py"
ARTIFACT_DIRECTORY="${RUNNER_TEMP:?RUNNER_TEMP is required}/neko-smoke-artifacts"
DERIVED_DATA_DIRECTORY="$RUNNER_TEMP/NekoWidgetSmokeDerivedData"
RESULT_BUNDLE="$ARTIFACT_DIRECTORY/NekoWidgetSimulator.xcresult"
PERMISSION_RESULT_BUNDLE="$ARTIFACT_DIRECTORY/NekoWidgetPhotoPermission.xcresult"
TARGET_SIMULATOR_RUNTIME="${SMOKE_IOS_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-18-6}"

SIMULATOR_UDID=""
SIMULATOR_NAME=""
SIMULATOR_RUNTIME=""
APP_BUNDLE_ID=""
WIDGET_BUNDLE_ID=""
APP_GROUP_ID=""
APP_PID=""
APP_GROUP_CONTAINER=""
SCREENSHOT_CAPTURED="false"
PERMISSION_TEST_STATUS=0

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

photo_authorization_log_contains() {
    local expected_message="$1"
    local expected_status="$2"
    local container=""
    local log_directory=""

    container="$(resolve_group_container || true)"
    if [[ -z "$container" ]]; then
        return 1
    fi
    log_directory="$container/diagnostic-logs"
    if [[ ! -d "$log_directory" ]]; then
        return 1
    fi

    python3 - "$log_directory" "$expected_message" "$expected_status" <<'PY'
import json
import sys
from pathlib import Path

expected_message = sys.argv[2]
expected_status = sys.argv[3]
for path in Path(sys.argv[1]).glob("*.jsonl"):
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        continue
    for line in lines:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (
            entry.get("category") == "permission"
            and entry.get("message") == expected_message
            and (
                expected_status == "*"
                or entry.get("metadata", {}).get("status") == expected_status
            )
        ):
            raise SystemExit(0)
raise SystemExit(1)
PY
}

wait_for_photo_authorization() {
    local expected_message="$1"
    local expected_status="$2"
    local timeout_seconds="$3"
    local attempt=""

    for attempt in $(seq 1 "$timeout_seconds"); do
        if photo_authorization_log_contains \
            "$expected_message" "$expected_status"; then
            printf 'Photo authorization event "%s" (%s) observed after %d second(s).\n' \
                "$expected_message" "$expected_status" "$attempt"
            return 0
        fi
        if [[ -n "${APP_PID:-}" ]] && ! kill -0 "$APP_PID" 2>/dev/null; then
            echo "The app exited while checking PhotoKit authorization." >&2
            return 1
        fi
        sleep 1
    done
    return 1
}

capture_tcc_state() {
    local label="$1"
    local database="$HOME/Library/Developer/CoreSimulator/Devices/$SIMULATOR_UDID/data/Library/TCC/TCC.db"
    local output="$ARTIFACT_DIRECTORY/tcc-$label.json"

    if [[ ! -f "$database" ]]; then
        printf '{"error":"TCC database was not found"}\n' > "$output"
        return 0
    fi

    python3 - "$database" "$APP_BUNDLE_ID" "$output" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

database, bundle_identifier, output = sys.argv[1:]
report = {"bundleIdentifier": bundle_identifier, "rows": []}
try:
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=2)
    connection.row_factory = sqlite3.Row
    schema_row = connection.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'access'"
    ).fetchone()
    report["schema"] = schema_row[0] if schema_row else None
    rows = connection.execute(
        "SELECT * FROM access WHERE client = ? ORDER BY service",
        (bundle_identifier,),
    ).fetchall()
    for row in rows:
        report["rows"].append(
            {
                key: value.hex() if isinstance(value, bytes) else value
                for key, value in dict(row).items()
            }
        )
    connection.close()
except Exception as error:  # Diagnostic capture must not mask the smoke result.
    report["error"] = f"{type(error).__name__}: {error}"
Path(output).write_text(
    json.dumps(report, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

archive_and_reset_permission_bootstrap() {
    local container=""
    local expected_prefix=""
    local archive_directory="$ARTIFACT_DIRECTORY/permission-bootstrap-app-group"
    local item=""

    container="$(resolve_group_container || true)"
    if [[ -z "$container" || ! -d "$container" ]]; then
        echo "The App Group container was unavailable after the permission UI test." >&2
        return 1
    fi

    expected_prefix="$HOME/Library/Developer/CoreSimulator/Devices/$SIMULATOR_UDID/data/Containers/Shared/AppGroup/"
    if [[ "$container" != "$expected_prefix"* ]]; then
        echo "Refusing to clean an unexpected App Group path: $container" >&2
        return 1
    fi

    mkdir -p "$archive_directory"
    for item in \
        diagnostic-logs \
        library-snapshot.json \
        widget-manifest.json \
        widget-timeline-lease.json \
        widget-cache; do
        if [[ -e "$container/$item" ]]; then
            cp -R "$container/$item" "$archive_directory/"
        fi
    done

    # Remove the bootstrap logs and Widget outputs before adding fixtures so
    # they cannot satisfy the later smoke predicates. Keep library-snapshot.json:
    # it is both the baseline asset set and the owner of any PhotoKit album ID
    # created during permission bootstrap, preventing a duplicate album.
    rm -rf -- \
        "$container/diagnostic-logs" \
        "$container/widget-cache"
    rm -f -- \
        "$container/widget-manifest.json" \
        "$container/widget-timeline-lease.json"
}

wait_for_completed_snapshot() {
    local timeout_seconds="$1"
    local attempt=0
    local container=""
    local snapshot=""

    for attempt in $(seq 1 "$timeout_seconds"); do
        container="$(resolve_group_container || true)"
        snapshot="$container/library-snapshot.json"
        if [[ -n "$container" && -f "$snapshot" ]] && python3 - "$snapshot" <<'PY'
import json
import sys
from pathlib import Path

try:
    snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
state = snapshot.get("scanState", {})
raise SystemExit(
    0
    if state.get("phase") == "completed" and state.get("resultKind") == "final"
    else 1
)
PY
        then
            return 0
        fi
        sleep 1
    done
    return 1
}

fixtures_are_ready() {
    local container="$1"
    local baseline_snapshot="$2"
    local expected_count="$3"

    python3 - \
        "$container/library-snapshot.json" \
        "$baseline_snapshot" \
        "$expected_count" <<'PY'
import json
import sys
from pathlib import Path

try:
    current = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
    baseline = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8-sig"))
    expected_count = int(sys.argv[3])
except (OSError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)

baseline_ids = {
    asset.get("localIdentifier")
    for asset in baseline.get("assets", [])
    if isinstance(asset, dict) and isinstance(asset.get("localIdentifier"), str)
}
fixtures = [
    asset
    for asset in current.get("assets", [])
    if isinstance(asset, dict)
    and isinstance(asset.get("localIdentifier"), str)
    and asset.get("localIdentifier") not in baseline_ids
]
statuses = [asset.get("analysisStatus") for asset in fixtures]
state = current.get("scanState", {})
ready = (
    state.get("phase") == "completed"
    and state.get("resultKind") == "final"
    and len(fixtures) >= expected_count
    and all(status in {"detected", "noCat"} for status in statuses)
    and any(status == "detected" for status in statuses)
)
raise SystemExit(0 if ready else 1)
PY
}

launch_app() {
    local attempt_name="$1"
    local launch_output=""
    shift

    launch_output="$(
        xcrun simctl launch --terminate-running-process \
            "$SIMULATOR_UDID" "$APP_BUNDLE_ID" "$@"
    )"
    printf '%s\n' "$launch_output" \
        | tee "$ARTIFACT_DIRECTORY/launch-$attempt_name.txt"
    printf '%s\n' "$launch_output" >> "$ARTIFACT_DIRECTORY/launches.txt"
    APP_PID="${launch_output##*: }"
    if [[ ! "$APP_PID" =~ ^[0-9]+$ ]]; then
        echo "simctl did not return a numeric app PID: $launch_output" >&2
        return 1
    fi
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
    "$ARTIFACT_DIRECTORY/selected-simulator.tsv" \
    "$TARGET_SIMULATOR_RUNTIME" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
target_runtime = sys.argv[3]
devices = json.loads(source.read_text(encoding="utf-8"))["devices"]

candidates = [
    device
    for device in devices.get(target_runtime, [])
    if device.get("isAvailable", False)
    and str(device.get("name", "")).startswith("iPhone")
]
if not candidates:
    available_ios_runtimes = sorted(
        runtime
        for runtime, runtime_devices in devices.items()
        if ".iOS-" in runtime
        and any(device.get("isAvailable", False) for device in runtime_devices)
    )
    raise SystemExit(
        f"Requested Simulator runtime is unavailable: {target_runtime}; "
        f"available iOS runtimes: {', '.join(available_ios_runtimes) or 'none'}"
    )

selected = candidates[0]
destination.write_text(
    f"{selected['udid']}\t{selected['name']}\t{target_runtime}\n",
    encoding="utf-8",
)
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
xcrun simctl help privacy > "$ARTIFACT_DIRECTORY/simctl-privacy-help.txt" 2>&1

# `simctl privacy grant photos` writes a legacy TCC row on current GitHub
# Hosted Simulators but PhotoKit's `.readWrite` API remains `.notDetermined`.
# Exercise the production permission button and expected system dialog through
# Apple's UI-testing APIs instead. Parallel testing must stay disabled so the
# authorization remains on this exact Simulator rather than a cloned device.
xcodebuild \
    -project NekoWidget.xcodeproj \
    -scheme NekoWidget \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
    -derivedDataPath "$DERIVED_DATA_DIRECTORY" \
    -resultBundlePath "$PERMISSION_RESULT_BUNDLE" \
    -only-testing:NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess \
    -parallel-testing-enabled NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    test || PERMISSION_TEST_STATUS=$?

if (( PERMISSION_TEST_STATUS == 0 )); then
    # XCTest may terminate the AUT when the test session ends. Start one
    # explicit normal launch so the pre-fixture asset IDs are always persisted
    # for the baseline comparison below.
    launch_app "permission-baseline" || PERMISSION_TEST_STATUS=$?
fi
if (( PERMISSION_TEST_STATUS == 0 )) \
    && ! wait_for_completed_snapshot 45; then
    echo "The permission bootstrap scan did not produce a completed baseline snapshot." >&2
    PERMISSION_TEST_STATUS=1
fi
xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" || true
xcrun simctl terminate "$SIMULATOR_UDID" "$WIDGET_BUNDLE_ID" || true
sleep 1
capture_tcc_state "after-ui-test"
if (( PERMISSION_TEST_STATUS != 0 )); then
    exit "$PERMISSION_TEST_STATUS"
fi
archive_and_reset_permission_bootstrap
BASELINE_SNAPSHOT="$ARTIFACT_DIRECTORY/permission-bootstrap-app-group/library-snapshot.json"
if [[ ! -f "$BASELINE_SNAPSHOT" ]]; then
    echo "The permission bootstrap baseline snapshot was not archived." >&2
    exit 1
fi

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

TERMINAL_EVENT_FOUND="false"
MAX_SCAN_LAUNCH_ATTEMPTS=6
SCAN_POLLS_PER_LAUNCH=15
for launch_attempt in $(seq 1 "$MAX_SCAN_LAUNCH_ATTEMPTS"); do
    launch_app "smoke-$launch_attempt"
    if ! wait_for_photo_authorization \
        "Photo authorization checked" "authorized" 15; then
        echo "PhotoKit was not authorized before the scan timeout window." >&2
        exit 1
    fi

    # `simctl addmedia` can publish PHAsset metadata before its local image
    # resource is ready. The scanner deliberately retries unavailable/failed
    # records on the next launch, so use bounded relaunches instead of a long,
    # timing-sensitive fixed sleep.
    for poll_attempt in $(seq 1 "$SCAN_POLLS_PER_LAUNCH"); do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            echo "The app process exited during scan attempt $launch_attempt." >&2
            break
        fi

        APP_GROUP_CONTAINER="$(resolve_group_container || true)"
        if [[ -n "$APP_GROUP_CONTAINER" \
            && -d "$APP_GROUP_CONTAINER/diagnostic-logs" ]] \
            && grep -R -q 'Widget timeline reload requested' \
                "$APP_GROUP_CONTAINER/diagnostic-logs" \
            && fixtures_are_ready \
                "$APP_GROUP_CONTAINER" "$BASELINE_SNAPSHOT" "$FIXTURE_COUNT"; then
            TERMINAL_EVENT_FOUND="true"
            printf 'Fixtures and widget output became ready on launch %d after %d second(s).\n' \
                "$launch_attempt" "$((poll_attempt * 2))"
            break
        fi
        sleep 2
    done

    if [[ "$TERMINAL_EVENT_FOUND" == "true" ]]; then
        break
    fi
    if (( launch_attempt < MAX_SCAN_LAUNCH_ATTEMPTS )); then
        xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" || true
        sleep 3
    fi
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
    "$BASELINE_SNAPSHOT" \
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
