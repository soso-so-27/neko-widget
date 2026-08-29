#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$PROJECT_DIRECTORY/ci/validate-sharing-runtime-self-test.py"
REPORT_FILENAME="sharing-runtime-self-test.json"
THUMBNAIL_WRITE_PROGRESS_FILENAME="sharing-thumbnail-write-runtime-progress.json"
RENDERER_VERSION="cat-aware-full-bleed-v6"
ARTIFACT_DIRECTORY="${RUNNER_TEMP:?RUNNER_TEMP is required}/neko-sharing-runtime-matrix"
DERIVED_DATA_DIRECTORY="$RUNNER_TEMP/NekoWidgetSharingRuntimeDerivedData"
DEVICE_INVENTORY="$RUNNER_TEMP/neko-sharing-runtime-devices.json"
SELECTION_FILE="$RUNNER_TEMP/neko-sharing-runtime-selection.tsv"
RUNTIME_LABELS=("ios-18-5" "ios-26-2")
REQUESTED_RUNTIMES=(
    "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
    "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
)

SELECTED_UDIDS=()
APP_BUNDLE_ID=""
APP_GROUP_ID=""

mkdir -p "$ARTIFACT_DIRECTORY"

resolve_group_container() {
    local simulator_udid="$1"
    local direct_path=""
    local fallback_output=""
    local fallback_path=""

    direct_path="$(
        xcrun simctl get_app_container \
            "$simulator_udid" "$APP_BUNDLE_ID" "$APP_GROUP_ID" \
            2>/dev/null || true
    )"
    if [[ -n "$direct_path" && -d "$direct_path" ]]; then
        printf '%s\n' "$direct_path"
        return 0
    fi

    fallback_output="$(
        xcrun simctl get_app_container \
            "$simulator_udid" "$APP_BUNDLE_ID" groups 2>/dev/null || true
    )"
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
        ' <<< "$fallback_output"
    )"
    if [[ -n "$fallback_path" && -d "$fallback_path" ]]; then
        printf '%s\n' "$fallback_path"
        return 0
    fi
    return 1
}

cleanup_runtime() {
    local simulator_udid="$1"
    local cleanup_status=0

    if [[ -n "$APP_BUNDLE_ID" ]]; then
        xcrun simctl terminate "$simulator_udid" "$APP_BUNDLE_ID" \
            >/dev/null 2>&1 || true
    fi
    xcrun simctl shutdown "$simulator_udid" >/dev/null 2>&1 || true
    xcrun simctl erase "$simulator_udid" || cleanup_status=$?
    return "$cleanup_status"
}

cleanup_all() {
    local original_status=$?
    local simulator_udid=""

    trap - EXIT
    set +e
    for simulator_udid in "${SELECTED_UDIDS[@]}"; do
        cleanup_runtime "$simulator_udid" || true
    done
    exit "$original_status"
}
trap cleanup_all EXIT

printf 'Sharing runtime matrix started at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
xcrun simctl list devices available --json > "$DEVICE_INVENTORY"

# Resolve both exact runtime identifiers before the single app build. The
# uploaded inventory contains only the requested IDs and availability; device
# UDIDs and host paths remain in RUNNER_TEMP and are never uploaded.
python3 - \
    "$DEVICE_INVENTORY" \
    "$SELECTION_FILE" \
    "$ARTIFACT_DIRECTORY/runtime-selection.json" \
    "${REQUESTED_RUNTIMES[@]}" <<'PY'
import json
import sys
from pathlib import Path

inventory_path = Path(sys.argv[1])
selection_path = Path(sys.argv[2])
artifact_path = Path(sys.argv[3])
requested = sys.argv[4:]
devices = json.loads(inventory_path.read_text(encoding="utf-8"))["devices"]
public_selection = []
private_rows = []
missing = []
for runtime in requested:
    candidates = [
        device
        for device in devices.get(runtime, [])
        if device.get("isAvailable") is True
        and str(device.get("name", "")).startswith("iPhone")
        and isinstance(device.get("udid"), str)
    ]
    availability = "available" if candidates else "unavailable"
    public_selection.append({"runtime": runtime, "availability": availability})
    if candidates:
        private_rows.append((runtime, candidates[0]["udid"]))
    else:
        missing.append(runtime)

artifact_path.write_text(
    json.dumps(
        {"schemaVersion": 1, "requestedRuntimes": public_selection},
        indent=2,
        sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
)
selection_path.write_text(
    "".join("\t".join(row) + "\n" for row in private_rows),
    encoding="utf-8",
)
if missing:
    raise SystemExit(
        "Requested Simulator runtime is unavailable: " + ", ".join(missing)
    )
PY

while IFS=$'\t' read -r selected_runtime selected_udid; do
    if [[ -z "$selected_runtime" || -z "$selected_udid" ]]; then
        echo "The selected Simulator record is incomplete." >&2
        exit 1
    fi
    SELECTED_UDIDS+=("$selected_udid")
done < "$SELECTION_FILE"
if (( ${#SELECTED_UDIDS[@]} != ${#REQUESTED_RUNTIMES[@]} )); then
    echo "The Simulator selection omitted a requested runtime." >&2
    exit 1
fi

cd "$PROJECT_DIRECTORY"
xcodebuild \
    -project NekoWidget.xcodeproj \
    -scheme NekoWidget \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED_DATA_DIRECTORY" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    build

APP_PATH="$DERIVED_DATA_DIRECTORY/Build/Products/Debug-iphonesimulator/NekoWidget.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "The built app was not found." >&2
    exit 1
fi
APP_BUNDLE_ID="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist"
)"
APP_GROUP_ID="$(
    /usr/libexec/PlistBuddy -c 'Print :AppGroupIdentifier' "$APP_PATH/Info.plist"
)"
if [[ -z "$APP_BUNDLE_ID" || -z "$APP_GROUP_ID" ]]; then
    echo "The built app identifiers are incomplete." >&2
    exit 1
fi
codesign --verify --deep --strict "$APP_PATH"

run_runtime_body() {
    local label="$1"
    local runtime="$2"
    local simulator_udid="$3"
    local runtime_artifacts="$ARTIFACT_DIRECTORY/$label"
    local launch_output=""
    local app_pid=""
    local group_container=""
    local source_report=""
    local source_thumbnail_progress=""
    local report_published="false"
    local poll_attempt=0
    local validator_status=0

    mkdir -p "$runtime_artifacts"
    xcrun simctl shutdown "$simulator_udid" >/dev/null 2>&1 || true
    if ! xcrun simctl erase "$simulator_udid"; then
        echo "$runtime failed before boot because erase did not complete." >&2
        return 1
    fi
    if ! xcrun simctl boot "$simulator_udid" \
        || ! xcrun simctl bootstatus "$simulator_udid" -b; then
        echo "$runtime failed to boot." >&2
        return 1
    fi
    if ! xcrun simctl install "$simulator_udid" "$APP_PATH"; then
        echo "$runtime failed to install the generated app." >&2
        return 1
    fi

    if ! launch_output="$(
        xcrun simctl launch --terminate-running-process \
            "$simulator_udid" "$APP_BUNDLE_ID" --sharing-runtime-self-test
    )"; then
        echo "$runtime failed to launch the generated-data self-test." >&2
        return 1
    fi
    app_pid="${launch_output##*: }"
    if [[ ! "$app_pid" =~ ^[0-9]+$ ]]; then
        echo "$runtime launch did not return a numeric app PID." >&2
        return 1
    fi

    for poll_attempt in $(seq 1 90); do
        group_container="$(resolve_group_container "$simulator_udid" || true)"
        if [[ -n "$group_container" ]]; then
            source_report="$group_container/$REPORT_FILENAME"
            if [[ -f "$source_report" ]]; then
                report_published="true"
                break
            fi
        fi
        if ! kill -0 "$app_pid" 2>/dev/null; then
            echo "$runtime app exited before publishing the self-test report." >&2
            return 1
        fi
        sleep 1
    done
    if [[ "$report_published" != "true" ]]; then
        echo "$runtime timed out waiting for the self-test report." >&2
        return 1
    fi

    # The validator rejects arbitrary fields or diagnostics before emitting a
    # normalized safe copy. A genuine fixed-case failure remains uploadable.
    python3 "$VALIDATOR" \
        "$source_report" \
        --renderer-version "$RENDERER_VERSION" \
        --safe-copy "$runtime_artifacts/$REPORT_FILENAME" \
        || validator_status=$?
    if (( validator_status == 0 )); then
        python3 "$VALIDATOR" \
            "$runtime_artifacts/$REPORT_FILENAME" \
            --renderer-version "$RENDERER_VERSION" \
            || validator_status=$?
    fi
    source_thumbnail_progress="$group_container/$THUMBNAIL_WRITE_PROGRESS_FILENAME"
    if [[ -f "$source_thumbnail_progress" ]]; then
        python3 - \
            "$source_thumbnail_progress" \
            "$runtime_artifacts/$THUMBNAIL_WRITE_PROGRESS_FILENAME" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
value = json.loads(source.read_text(encoding="utf-8"))
allowed = {
    "started",
    "url-validated",
    "secure-write-completed",
    "directory-validated",
    "file-validated",
    "protection-validated",
    "completed",
}
if (
    not isinstance(value, dict)
    or set(value) != {"schemaVersion", "phase"}
    or value["schemaVersion"] != 1
    or value["phase"] not in allowed
):
    raise SystemExit("thumbnail write progress has an invalid fixed schema")
destination.write_text(
    json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
    fi
    return "$validator_status"
}

run_runtime() {
    local label="$1"
    local runtime="$2"
    local simulator_udid="$3"
    local runtime_status=0
    local cleanup_status=0

    run_runtime_body "$label" "$runtime" "$simulator_udid" \
        || runtime_status=$?
    cleanup_runtime "$simulator_udid" || cleanup_status=$?
    if (( cleanup_status != 0 )); then
        echo "$runtime cleanup failed; refusing to start another runtime." >&2
        return 2
    fi
    return "$runtime_status"
}

matrix_status=0
for runtime_index in "${!REQUESTED_RUNTIMES[@]}"; do
    runtime="${REQUESTED_RUNTIMES[$runtime_index]}"
    label="${RUNTIME_LABELS[$runtime_index]}"
    simulator_udid="${SELECTED_UDIDS[$runtime_index]}"
    runtime_status=0
    run_runtime "$label" "$runtime" "$simulator_udid" \
        || runtime_status=$?
    if (( runtime_status != 0 )); then
        matrix_status=1
    fi
    if (( runtime_status == 2 )); then
        break
    fi
done

if (( matrix_status != 0 )); then
    echo "Sharing runtime matrix failed." >&2
    exit "$matrix_status"
fi
printf 'Sharing runtime matrix passed at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
