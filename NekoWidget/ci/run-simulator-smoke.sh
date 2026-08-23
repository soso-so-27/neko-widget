#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIRECTORY="$PROJECT_DIRECTORY/ci/fixtures/cats"
VALIDATOR="$PROJECT_DIRECTORY/ci/validate-simulator-smoke.py"
SHARING_RUNTIME_VALIDATOR="$PROJECT_DIRECTORY/ci/validate-sharing-runtime-self-test.py"
PHOTO_PERMISSION_VALIDATOR="$PROJECT_DIRECTORY/ci/validate-photo-permission-bootstrap.py"
SHARING_RUNTIME_REPORT_FILENAME="sharing-runtime-self-test.json"
SHARING_RUNTIME_PROGRESS_FILENAME="sharing-runtime-self-test-progress.json"
SHARING_RUNTIME_RENDERER_VERSION="cat-aware-full-bleed-v6"
LOCAL_PHOTO_LIBRARY_USAGE_DESCRIPTION='猫の写真を端末内で見つけて整理し、「うちの子」アルバムとウィジェットへ反映するため、写真ライブラリへのアクセスを許可してください。写真の解析とウィジェット用画像の作成は端末内で行います。'
SIMULATOR_TEST_MODE="${SIMULATOR_TEST_MODE:-smoke}"
case "$SIMULATOR_TEST_MODE" in
    smoke)
        ARTIFACT_DIRECTORY="${RUNNER_TEMP:?RUNNER_TEMP is required}/neko-smoke-artifacts"
        DERIVED_DATA_DIRECTORY="$RUNNER_TEMP/NekoWidgetSmokeDerivedData"
        RESULT_BUNDLE="$ARTIFACT_DIRECTORY/NekoWidgetSimulator.xcresult"
        PERMISSION_RESULT_BUNDLE="$ARTIFACT_DIRECTORY/NekoWidgetPhotoPermission.xcresult"
        HARNESS_LOG_FILENAME="smoke-test.log"
        HARNESS_EXIT_FILENAME="smoke-exit-code.txt"
        ;;
    scale)
        ARTIFACT_DIRECTORY="${RUNNER_TEMP:?RUNNER_TEMP is required}/neko-scale-artifacts"
        DERIVED_DATA_DIRECTORY="$RUNNER_TEMP/NekoWidgetScaleDerivedData"
        RESULT_BUNDLE="$ARTIFACT_DIRECTORY/NekoWidgetScaleSimulator.xcresult"
        PERMISSION_RESULT_BUNDLE="$ARTIFACT_DIRECTORY/NekoWidgetScalePhotoPermission.xcresult"
        HARNESS_LOG_FILENAME="scale-test.log"
        HARNESS_EXIT_FILENAME="scale-exit-code.txt"
        ;;
    *)
        echo "Unsupported SIMULATOR_TEST_MODE: $SIMULATOR_TEST_MODE" >&2
        exit 2
        ;;
esac
TARGET_SIMULATOR_RUNTIME="${SMOKE_IOS_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-18-6}"
SIMCTL_ADDMEDIA_TIMEOUT_SECONDS="${SIMCTL_ADDMEDIA_TIMEOUT_SECONDS:-120}"
case "$SIMCTL_ADDMEDIA_TIMEOUT_SECONDS" in
    ''|*[!0-9]*)
        echo "SIMCTL_ADDMEDIA_TIMEOUT_SECONDS must be an integer." >&2
        exit 2
        ;;
esac
SIMCTL_ADDMEDIA_TIMEOUT_SECONDS=$((10#$SIMCTL_ADDMEDIA_TIMEOUT_SECONDS))
if (( SIMCTL_ADDMEDIA_TIMEOUT_SECONDS < 15 \
    || SIMCTL_ADDMEDIA_TIMEOUT_SECONDS > 300 )); then
    echo "SIMCTL_ADDMEDIA_TIMEOUT_SECONDS must be between 15 and 300." >&2
    exit 2
fi

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
MEMORY_SAMPLER_PID=""
MEMORY_SAMPLER_STOP_FILE=""

mkdir -p "$ARTIFACT_DIRECTORY"
exec > >(tee -a "$ARTIFACT_DIRECTORY/$HARNESS_LOG_FILENAME") 2>&1

# `simctl addmedia` has occasionally submitted work to Photos and then waited
# indefinitely for the command response. A timeout therefore has an uncertain
# outcome: retrying the same files can create duplicate PHAssets. Kill the
# complete command process group, record a bounded diagnostic, and let the
# existing post-import baseline comparison decide whether every fixture became
# available. Callers must never retry the same label/files in this Simulator.
bounded_simctl_addmedia() {
    local label="$1"
    local output_log=""
    local result_json=""
    local wrapper_status=0
    shift

    if [[ ! "$label" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || (( $# == 0 )); then
        echo "Invalid bounded addmedia label or empty media list: $label" >&2
        return 2
    fi
    output_log="$ARTIFACT_DIRECTORY/simctl-addmedia-$label.log"
    result_json="$ARTIFACT_DIRECTORY/simctl-addmedia-$label.json"

    python3 - \
        "$SIMCTL_ADDMEDIA_TIMEOUT_SECONDS" \
        "$output_log" \
        "$result_json" \
        "$SIMULATOR_UDID" \
        "$@" <<'PY' || wrapper_status=$?
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

timeout_seconds = int(sys.argv[1])
output_path = Path(sys.argv[2])
result_path = Path(sys.argv[3])
simulator_udid = sys.argv[4]
media_paths = sys.argv[5:]
command = ["xcrun", "simctl", "addmedia", simulator_udid, *media_paths]
started = time.monotonic()
outcome = "spawn-failed"
command_exit_code = None
termination = "none"
wrapper_exit_code = 125

try:
    with output_path.open("wb") as output:
        process = subprocess.Popen(
            command,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            command_exit_code = process.wait(timeout=timeout_seconds)
            if command_exit_code == 0:
                outcome = "completed"
                wrapper_exit_code = 0
            else:
                # A nonzero result can still follow a partial Photos import.
                outcome = "command-failed"
                wrapper_exit_code = 1
        except subprocess.TimeoutExpired:
            outcome = "timed-out"
            termination = "sigterm"
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                command_exit_code = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                termination = "sigkill"
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    command_exit_code = process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    termination = "unreaped"
            wrapper_exit_code = 124
except OSError as error:
    output_path.write_text(
        f"addmedia wrapper could not start the command: {type(error).__name__}\n",
        encoding="utf-8",
    )

result = {
    "schemaVersion": 1,
    "commandExitCode": command_exit_code,
    "completionConfirmed": outcome == "completed",
    "durationSeconds": round(time.monotonic() - started, 3),
    "inputCount": len(media_paths),
    "outcome": outcome,
    "sameBatchRetryAllowed": False,
    "termination": termination,
    "timeoutSeconds": timeout_seconds,
}
result_path.write_text(
    json.dumps(result, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
raise SystemExit(wrapper_exit_code)
PY

    if (( wrapper_status != 0 )); then
        echo "simctl addmedia completion was not confirmed for $label " \
            "(wrapper status $wrapper_status). The same media batch will not be retried; " \
            "the baseline-relative PhotoKit scan will determine whether import completed." >&2
    fi
    return "$wrapper_status"
}

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
        widget-cache-history.json \
        widget-manifest.json \
        widget-timeline-lease.json \
        widget-timeline-lease-small.json \
        widget-timeline-lease-medium.json \
        widget-timeline-lease-large.json \
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
        "$container/widget-cache-history.json" \
        "$container/widget-manifest.json" \
        "$container/widget-timeline-lease.json" \
        "$container/widget-timeline-lease-small.json" \
        "$container/widget-timeline-lease-medium.json" \
        "$container/widget-timeline-lease-large.json"
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

final_widget_output_is_ready() {
    local container="$1"

    python3 - "$container/diagnostic-logs" <<'PY'
import json
import sys
from pathlib import Path

log_directory = Path(sys.argv[1])
entries = []
for path in sorted(log_directory.glob("app-*.jsonl")):
    stem = path.name[: -len(".jsonl")]
    base, separator, rotation = stem.rpartition(".")
    session = base if separator and rotation.isdigit() else stem
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        continue
    for raw_line in lines:
        if not raw_line.strip():
            continue
        try:
            entry = json.loads(raw_line)
        except json.JSONDecodeError:
            continue
        if isinstance(entry, dict) and entry.get("process") == "app":
            entries.append((session, entry))

def event_times(message, category, session=None):
    values = []
    for entry_session, entry in entries:
        if session is not None and entry_session != session:
            continue
        if entry.get("message") != message or entry.get("category") != category:
            continue
        try:
            values.append((float(entry.get("timestamp")), entry_session))
        except (TypeError, ValueError):
            continue
    return values

final_times = event_times("Final scan result applied", "scan")
if not final_times:
    raise SystemExit(1)
final_time, final_session = max(final_times)

cache_times = [
    value
    for value, _ in event_times(
        "Widget cache build completed", "widget-cache", final_session
    )
    if value > final_time
]
if not cache_times:
    raise SystemExit(1)
cache_time = min(cache_times)

reload_times = [
    value
    for value, _ in event_times(
        "Widget timeline reload requested", "widget-cache", final_session
    )
    if value > cache_time
]
raise SystemExit(0 if reload_times else 1)
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

run_sharing_runtime_self_test() {
    local container=""
    local source_report=""
    local source_progress=""
    local artifact_report="$ARTIFACT_DIRECTORY/$SHARING_RUNTIME_REPORT_FILENAME"
    local artifact_progress="$ARTIFACT_DIRECTORY/$SHARING_RUNTIME_PROGRESS_FILENAME"
    local sample_output="$ARTIFACT_DIRECTORY/sharing-runtime-self-test-sample.txt"
    local sample_log="$ARTIFACT_DIRECTORY/sharing-runtime-self-test-sample.log"
    local poll_attempt=0

    container="$(resolve_group_container || true)"
    if [[ -z "$container" || ! -d "$container" ]]; then
        echo "The App Group container was unavailable before the sharing runtime self-test." >&2
        return 1
    fi
    source_report="$container/$SHARING_RUNTIME_REPORT_FILENAME"
    source_progress="$container/$SHARING_RUNTIME_PROGRESS_FILENAME"

    # A previous process or retried CI step must not satisfy this launch. The
    # app publishes the new report atomically only after every generated-data
    # case has reached a terminal result.
    rm -f -- "$source_report"
    rm -f -- "$source_progress"
    rm -f -- "$artifact_report"
    rm -f -- "$artifact_progress"
    launch_app "sharing-runtime-self-test" --sharing-runtime-self-test

    for poll_attempt in $(seq 1 90); do
        if [[ -f "$source_report" ]]; then
            break
        fi
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            echo "The app exited before publishing the sharing runtime self-test report." >&2
            return 1
        fi
        sleep 1
    done
    if [[ ! -f "$source_report" ]]; then
        if [[ -f "$source_progress" ]]; then
            cp "$source_progress" "$artifact_progress" || true
        fi
        if kill -0 "$APP_PID" 2>/dev/null && command -v sample >/dev/null 2>&1; then
            sample "$APP_PID" 3 -file "$sample_output" > "$sample_log" 2>&1 || true
        fi
        echo "Timed out waiting for the sharing runtime self-test report." >&2
        return 1
    fi

    # Validate before copying so a malformed report can never become an
    # uploaded artifact. `--safe-copy` emits only the normalized fixed schema,
    # including on a genuine case failure so the artifact remains diagnosable.
    # Paths, PhotoKit identifiers, keys, invite codes, and diagnostic text are
    # rejected before any copy is written.
    python3 "$SHARING_RUNTIME_VALIDATOR" \
        "$source_report" \
        --renderer-version "$SHARING_RUNTIME_RENDERER_VERSION" \
        --safe-copy "$artifact_report"
    python3 "$SHARING_RUNTIME_VALIDATOR" \
        "$artifact_report" \
        --renderer-version "$SHARING_RUNTIME_RENDERER_VERSION"
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
    local sampler_status=0
    local scale_crash_root=""
    local scale_log_start=""
    local -a scale_log_time_args=()

    trap - EXIT
    set +e

    # Setup/compiler/import failures can occur before the full scale validator
    # is reachable. Always leave a machine-readable failed report and summary
    # so an artifact never consists only of a shell exit code.
    if [[ "$SIMULATOR_TEST_MODE" == "scale" \
        && ! -f "$ARTIFACT_DIRECTORY/scale-report.json" ]]; then
        if (( original_status == 0 )); then
            original_status=1
        fi
        python3 - "$ARTIFACT_DIRECTORY" "$original_status" <<'PY'
import json
import sys
from pathlib import Path

artifact = Path(sys.argv[1])
status = int(sys.argv[2])
failure = f"scale phase exited before validation (exit code {status})"
report = {
    "schemaVersion": 1,
    "status": "fail",
    "failures": [failure],
    "fatalPhaseExitCode": status,
    "environment": {
        "measurementTarget": "iOS Simulator app process on macOS host",
        "deviceJetsamEnforced": False,
        "limitation": "Simulator results are not proof of real-device jetsam safety",
    },
}
(artifact / "scale-report.json").write_text(
    json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
(artifact / "scale-summary.md").write_text(
    "## iOS Simulator scale test\n\n"
    "**Result: FAIL**\n\n"
    f"- {failure}\n\n"
    "> Simulator does not enforce iPhone memory-warning or jetsam limits.\n",
    encoding="utf-8",
)
PY
    fi
    printf '%s\n' "$original_status" > "$ARTIFACT_DIRECTORY/$HARNESS_EXIT_FILENAME"

    if [[ -n "${MEMORY_SAMPLER_PID:-}" ]]; then
        if [[ -n "${MEMORY_SAMPLER_STOP_FILE:-}" ]]; then
            touch "$MEMORY_SAMPLER_STOP_FILE"
        fi
        wait "$MEMORY_SAMPLER_PID"
        sampler_status=$?
        printf '%s\n' "$sampler_status" \
            > "$ARTIFACT_DIRECTORY/memory-sampler-exit-code.txt"
        MEMORY_SAMPLER_PID=""
    fi

    capture_screenshot

    if [[ -n "${SIMULATOR_UDID:-}" ]]; then
        xcrun simctl listapps "$SIMULATOR_UDID" \
            > "$ARTIFACT_DIRECTORY/installed-apps.txt" 2>&1

        if [[ -n "${APP_BUNDLE_ID:-}" ]]; then
            if [[ "$SIMULATOR_TEST_MODE" == "scale" ]]; then
                if [[ -f "$ARTIFACT_DIRECTORY/scale-log-start.txt" ]]; then
                    scale_log_start="$(cat "$ARTIFACT_DIRECTORY/scale-log-start.txt")"
                fi
                if [[ -n "$scale_log_start" ]]; then
                    scale_log_time_args=(--start "$scale_log_start")
                else
                    scale_log_time_args=(--last 10m)
                fi
                xcrun simctl spawn "$SIMULATOR_UDID" log show \
                    --style compact \
                    "${scale_log_time_args[@]}" \
                    --predicate "process == 'NekoWidget' OR process == 'NekoWidgetWidgetExtension' OR subsystem == '$APP_BUNDLE_ID' OR subsystem == '$WIDGET_BUNDLE_ID'" \
                    > "$ARTIFACT_DIRECTORY/simulator-unified.log" 2>&1
                xcrun simctl spawn "$SIMULATOR_UDID" log show \
                    --style compact \
                    "${scale_log_time_args[@]}" \
                    --predicate 'eventMessage CONTAINS[c] "jetsam" OR eventMessage CONTAINS[c] "memorystatus" OR eventMessage CONTAINS[c] "memory pressure"' \
                    > "$ARTIFACT_DIRECTORY/simulator-memory-termination.log" 2>&1
            else
                xcrun simctl spawn "$SIMULATOR_UDID" log show \
                    --style compact \
                    --last 10m \
                    --predicate "process == 'NekoWidget' OR process == 'NekoWidgetWidgetExtension' OR subsystem == '$APP_BUNDLE_ID' OR subsystem == '$WIDGET_BUNDLE_ID'" \
                    > "$ARTIFACT_DIRECTORY/simulator-unified.log" 2>&1
            fi
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

    if [[ "$SIMULATOR_TEST_MODE" == "scale" \
        && -f "$ARTIFACT_DIRECTORY/scale-start.marker" ]]; then
        for scale_crash_root in \
            "$HOME/Library/Logs/DiagnosticReports" \
            "$HOME/Library/Developer/CoreSimulator/Devices/$SIMULATOR_UDID/data/Library/Logs/CrashReporter" \
            "$HOME/Library/Developer/CoreSimulator/Devices/$SIMULATOR_UDID/data/Library/Logs/DiagnosticReports"; do
            [[ -d "$scale_crash_root" ]] || continue
            while IFS= read -r crash_report; do
                cp "$crash_report" "$ARTIFACT_DIRECTORY/crash-reports/" 2>/dev/null || true
            done < <(
                find "$scale_crash_root" -type f \
                    \( -name 'NekoWidget*.crash' \
                    -o -name 'NekoWidget*.ips' \
                    -o -name 'JetsamEvent*.ips' \) \
                    -newer "$ARTIFACT_DIRECTORY/scale-start.marker" \
                    2>/dev/null || true
            )
        done
    fi

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
# Keep DEBUG-only deterministic fixtures available while overlaying the exact
# ordinary Release boundary onto the app, Widget, and Share Extension.
xcodebuild \
    -project NekoWidget.xcodeproj \
    -scheme NekoWidget \
    -configuration Debug \
    -xcconfig "$PROJECT_DIRECTORY/Config.Disabled.xcconfig" \
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
SHARE_EXTENSION_PATH="$APP_PATH/PlugIns/NekoWidgetShareExtension.appex"
if [[ ! -d "$APP_PATH" || ! -d "$EXTENSION_PATH" \
    || ! -d "$SHARE_EXTENSION_PATH" ]]; then
    echo "The built app or an embedded extension was not found." >&2
    exit 1
fi

python3 "$PROJECT_DIRECTORY/ci/validate-sharing-release.py" \
    --info-plist "$APP_PATH/Info.plist" \
    --share-info-plist "$SHARE_EXTENSION_PATH/Info.plist" \
    --widget-info-plist "$EXTENSION_PATH/Info.plist" \
    --privacy-manifest "$APP_PATH/PrivacyInfo.xcprivacy" \
    --widget-privacy-manifest "$EXTENSION_PATH/PrivacyInfo.xcprivacy" \
    --share-privacy-manifest "$SHARE_EXTENSION_PATH/PrivacyInfo.xcprivacy" \
    --export-reviewed NO \
    --expected-mode disabled \
    --expected-api-origin '' \
    --expected-photo-library-usage-description \
        "$LOCAL_PHOTO_LIBRARY_USAGE_DESCRIPTION"

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
codesign --verify --strict "$SHARE_EXTENSION_PATH"
codesign --display \
    --entitlements "$ARTIFACT_DIRECTORY/app-codesign-entitlements.plist" \
    --xml "$APP_PATH" \
    2> "$ARTIFACT_DIRECTORY/app-codesign.txt"
codesign --display \
    --entitlements "$ARTIFACT_DIRECTORY/widget-codesign-entitlements.plist" \
    --xml "$EXTENSION_PATH" \
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
NEKO_EXPECT_DISABLED_RELEASE=1 xcodebuild \
    -project NekoWidget.xcodeproj \
    -scheme NekoWidget \
    -configuration Debug \
    -xcconfig "$PROJECT_DIRECTORY/Config.Disabled.xcconfig" \
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
if (( PERMISSION_TEST_STATUS == 0 )); then
    permission_container="$(resolve_group_container || true)"
    if [[ -z "$permission_container" || ! -d "$permission_container/diagnostic-logs" ]]; then
        echo "The permission bootstrap diagnostic log directory was unavailable." >&2
        PERMISSION_TEST_STATUS=1
    elif ! python3 "$PHOTO_PERMISSION_VALIDATOR" \
        --tcc-report "$ARTIFACT_DIRECTORY/tcc-after-ui-test.json" \
        --log-directory "$permission_container/diagnostic-logs" \
        --bundle-identifier "$APP_BUNDLE_ID"; then
        PERMISSION_TEST_STATUS=1
    fi
fi
if (( PERMISSION_TEST_STATUS != 0 )); then
    exit "$PERMISSION_TEST_STATUS"
fi
archive_and_reset_permission_bootstrap
BASELINE_SNAPSHOT="$ARTIFACT_DIRECTORY/permission-bootstrap-app-group/library-snapshot.json"
if [[ ! -f "$BASELINE_SNAPSHOT" ]]; then
    echo "The permission bootstrap baseline snapshot was not archived." >&2
    exit 1
fi

if [[ "$SIMULATOR_TEST_MODE" == "scale" ]]; then
    # The expensive phase deliberately reuses the exact green build, App Group
    # and UI-driven Photos permission bootstrap above. Keeping this hook after
    # the archived baseline lets the normal smoke path below remain unchanged.
    # shellcheck source=run-simulator-scale-phase.sh
    source "$PROJECT_DIRECTORY/ci/run-simulator-scale-phase.sh"
    run_simulator_scale_phase "$BASELINE_SNAPSHOT"
    printf 'Simulator scale test passed at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    exit 0
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
ADDMEDIA_STATUS=0
bounded_simctl_addmedia "smoke-fixtures" "${FIXTURES[@]}" \
    || ADDMEDIA_STATUS=$?
if (( ADDMEDIA_STATUS != 0 )); then
    echo "Continuing without a duplicate import attempt; fixture readiness remains " \
        "defined by the archived baseline and the final PhotoKit snapshot." >&2
fi
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
            && final_widget_output_is_ready "$APP_GROUP_CONTAINER" \
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

# Preserve all three family canvases for every detected imported fixture so
# weighted manifest ordering cannot make the visual evidence nondeterministic.
# The generated fixtures are CC0 and contain no personal photo data.
python3 - \
    "$APP_GROUP_CONTAINER/widget-manifest.json" \
    "$APP_GROUP_CONTAINER/widget-cache" \
    "$APP_GROUP_CONTAINER/library-snapshot.json" \
    "$BASELINE_SNAPSHOT" \
    "$ARTIFACT_DIRECTORY" <<'PY'
import hashlib
import json
import shutil
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
cache_directory = Path(sys.argv[2])
snapshot_path = Path(sys.argv[3])
baseline_path = Path(sys.argv[4])
artifact_directory = Path(sys.argv[5])
manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
snapshot = json.loads(snapshot_path.read_text(encoding="utf-8-sig"))
baseline = json.loads(baseline_path.read_text(encoding="utf-8-sig"))
items = manifest.get("items", [])
baseline_ids = {
    asset.get("localIdentifier")
    for asset in baseline.get("assets", [])
    if isinstance(asset, dict) and isinstance(asset.get("localIdentifier"), str)
}
fixture_ids = {
    asset.get("localIdentifier")
    for asset in snapshot.get("assets", [])
    if isinstance(asset, dict)
    and isinstance(asset.get("localIdentifier"), str)
    and asset.get("localIdentifier") not in baseline_ids
    and asset.get("analysisStatus") == "detected"
}
if not fixture_ids:
    raise SystemExit("The final snapshot has no detected imported fixture to preview.")

manifest_items_by_id = {}
for item in items:
    if not isinstance(item, dict):
        continue
    identifier = item.get("localIdentifier")
    if identifier in fixture_ids and identifier not in manifest_items_by_id:
        manifest_items_by_id[identifier] = item
missing_ids = fixture_ids - manifest_items_by_id.keys()
if missing_ids:
    raise SystemExit(
        f"The Widget manifest omitted {len(missing_ids)} detected imported fixture(s)."
    )

preview_index = {"schemaVersion": 1, "previews": []}
ordered_ids = sorted(
    fixture_ids,
    key=lambda value: hashlib.sha256(value.encode("utf-8")).hexdigest(),
)
for slot, identifier in enumerate(ordered_ids, start=1):
    item = manifest_items_by_id[identifier]
    filenames = item.get("cacheFilenames")
    if not isinstance(filenames, dict):
        raise SystemExit(
            f"Detected imported fixture {slot} has no family-specific cache filenames."
        )
    copied = {}
    for variant in ("small", "medium", "large"):
        filename = filenames.get(variant)
        if not isinstance(filename, str) or Path(filename).name != filename:
            raise SystemExit(f"Unsafe or missing {variant} preview filename.")
        source = cache_directory / filename
        if not source.is_file():
            raise SystemExit(f"Missing {variant} preview cache file: {filename}")
        output_name = f"widget-preview-fixture-{slot:02d}-{variant}.jpg"
        shutil.copy2(source, artifact_directory / output_name)
        copied[variant] = output_name
    preview_index["previews"].append(
        {
            "assetToken": hashlib.sha256(identifier.encode("utf-8")).hexdigest()[:12],
            "files": copied,
            "slot": slot,
        }
    )
(artifact_directory / "widget-preview-index.json").write_text(
    json.dumps(preview_index, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

if [[ "$TERMINAL_EVENT_FOUND" != "true" ]]; then
    echo "Timed out waiting for the widget timeline reload event." >&2
    exit 1
fi
if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "The app process exited after producing its final scan artifacts." >&2
    exit 1
fi

# Run the generated-data sharing checks only after the normal PhotoKit/widget
# smoke artifacts are complete. The dedicated launch may reset DEBUG sharing
# state, but it cannot change the evidence already validated and copied above.
run_sharing_runtime_self_test

printf 'Simulator smoke test passed at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
