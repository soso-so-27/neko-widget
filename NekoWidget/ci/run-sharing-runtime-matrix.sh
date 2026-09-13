#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIRECTORY/ci/prepare-simulator-and-build.sh"
VALIDATOR="$PROJECT_DIRECTORY/ci/validate-sharing-runtime-self-test.py"
REPORT_FILENAME="sharing-runtime-self-test.json"
RENDERER_VERSION="cat-aware-full-bleed-v6"
ARTIFACT_DIRECTORY="${RUNNER_TEMP:?RUNNER_TEMP is required}/neko-sharing-runtime-matrix"
DERIVED_DATA_DIRECTORY="$RUNNER_TEMP/NekoWidgetSharingRuntimeDerivedData"
DEVICE_INVENTORY="$RUNNER_TEMP/neko-sharing-runtime-devices.json"
SELECTION_FILE="$RUNNER_TEMP/neko-sharing-runtime-selection.tsv"
RUNTIME_SCOPE="${NEKO_IOS_RUNTIME_SCOPE:-full-v1}"
UI_SELECTION_FILE="$RUNNER_TEMP/neko-sharing-runtime-ui-selection.txt"
RUNTIME_LABELS=("ios-18-5" "ios-26-2")
REQUESTED_RUNTIMES=(
    "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
    "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
)

SELECTED_UDIDS=()
CREATED_UDIDS=()
UI_PIDS=()
APP_BUNDLE_ID=""
APP_GROUP_ID=""

mkdir -p "$ARTIFACT_DIRECTORY"
python3 "$PROJECT_DIRECTORY/ci/ios_ci_scope.py" \
    --scope "$RUNTIME_SCOPE" \
    --metadata "$ARTIFACT_DIRECTORY/runtime-scope.json" \
    --tests "$UI_SELECTION_FILE"
COMPOSER_TEST_ARGUMENTS=()
while IFS= read -r test_argument; do
    COMPOSER_TEST_ARGUMENTS+=("$test_argument")
done < "$UI_SELECTION_FILE"
if (( ${#COMPOSER_TEST_ARGUMENTS[@]} == 0 )); then
    echo "The requested scope did not select any native UI tests." >&2
    exit 1
fi
UI_PARTITION_DIRECTORY="$ARTIFACT_DIRECTORY/ui-partition"
python3 "$PROJECT_DIRECTORY/ci/test-balanced-ui-shards.py"
python3 "$PROJECT_DIRECTORY/ci/balanced_ui_shards.py" \
    --scope "$RUNTIME_SCOPE" --output "$UI_PARTITION_DIRECTORY"
RUN_WIDGET_GALLERY=false
if [[ "$RUNTIME_SCOPE" == "full-v1" ]]; then
    RUN_WIDGET_GALLERY=true
fi

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

# Assign through the caller's variable: command substitution would lose the
# owned-UDID registration and leave a Simulator behind during failure cleanup.
create_test_simulator() {
    local destination_variable="$1"
    local purpose="$2"
    local device_type="$3"
    local runtime="$4"
    local created_udid=""
    created_udid="$(xcrun simctl create "Neko-CI-$purpose" "$device_type" "$runtime")" || return $?
    if [[ ! "$created_udid" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
        echo "Simulator creation did not return a UDID." >&2
        return 1
    fi
    CREATED_UDIDS+=("$created_udid")
    printf -v "$destination_variable" '%s' "$created_udid"
}

discard_test_simulator() {
    local simulator_udid="$1"
    local index=""
    xcrun simctl shutdown "$simulator_udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_udid" || return $?
    for index in "${!CREATED_UDIDS[@]}"; do
        if [[ "${CREATED_UDIDS[$index]}" == "$simulator_udid" ]]; then
            CREATED_UDIDS[$index]=""
        fi
    done
}

cleanup_all() {
    local original_status=$?
    local simulator_udid=""

    trap - EXIT
    set +e
    # Join outstanding xcodebuild children before touching their Simulators.
    local child_pid=""
    for child_pid in ${UI_PIDS[@]+"${UI_PIDS[@]}"}; do
        [[ -z "$child_pid" ]] || kill "$child_pid" 2>/dev/null || true
    done
    for child_pid in ${UI_PIDS[@]+"${UI_PIDS[@]}"}; do
        [[ -z "$child_pid" ]] || wait "$child_pid" 2>/dev/null || true
    done
    for simulator_udid in ${CREATED_UDIDS[@]+"${CREATED_UDIDS[@]}"}; do
        [[ -z "$simulator_udid" ]] || discard_test_simulator "$simulator_udid" || true
    done
    for simulator_udid in ${SELECTED_UDIDS[@]+"${SELECTED_UDIDS[@]}"}; do
        cleanup_runtime "$simulator_udid" || true
    done
    exit "$original_status"
}
trap cleanup_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
    local report_published="false"
    local poll_attempt=0
    local validator_status=0
    local app_data_container=""
    local -a runtime_launch_arguments=("--sharing-runtime-self-test")

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

    if [[ "$label" == "ios-26-2" ]]; then
        app_data_container="$(xcrun simctl get_app_container "$simulator_udid" "$APP_BUNDLE_ID" data)"
        if [[ ! -d "$app_data_container/tmp" ]]; then
            echo "The Widget review fixture container is unavailable." >&2
            return 1
        fi
        # The same fixed public portrait enters the real canonicalization,
        # decrypted-receipt, Vision and family-cache path in the runtime test.
        # The app independently verifies this exact hash before using/exporting it.
        python3 - "$app_data_container/tmp" <<'PY' || return $?
import hashlib
import sys
from pathlib import Path

data = Path("ci/fixtures/cats/cat-gray-portrait.png").read_bytes()
if hashlib.sha256(data).hexdigest() != "bd5a348e5e6df1b32837c51ab0357505119ea564d13ac4afefe3803b1b8dfbf8":
    raise SystemExit("The fixed Widget portrait fixture failed its hash check")
Path(sys.argv[1], "sharing-widget-review-source.png").write_bytes(data)
PY
        runtime_launch_arguments+=("--sharing-widget-portrait-review")
    fi

    if ! launch_output="$(
        xcrun simctl launch --terminate-running-process \
            "$simulator_udid" "$APP_BUNDLE_ID" "${runtime_launch_arguments[@]}"
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
    # After ordinary runtime validation, use dedicated iOS 26 Simulators for UI
    # review. Only these final test builds enable Widget Gallery fixture pixels.
    # These DEBUG fixtures have no accounts, PhotoKit access or network activity.
    if (( validator_status == 0 )) && [[ "$label" == "ios-26-2" ]]; then
        local composer_status=0
        xcrun simctl terminate "$simulator_udid" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
        defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
        # Export only the three runtime-validated JPEGs derived from the known
        # portrait. Reuse those exact bytes in normal and no-caption Gallery
        # builds; the separate white-background comparison remains synthetic.
        # Normal app builds and the release checkout do not inject these bytes.
        python3 - "$app_data_container/tmp" "$runtime_artifacts/widget-portrait-cache" <<'PY' || return $?
import base64
import hashlib
import json
import sys
from pathlib import Path

cache_output = Path(sys.argv[2])
cache_output.mkdir(parents=True, exist_ok=True)
exported = []
view = Path("NekoWidgetWidget/NekoWidgetView.swift")
source = view.read_text(encoding="utf-8")
for size, width, height, byte_cap in [
    ("small", 500, 500, 100 * 1024),
    ("medium", 1050, 500, 200 * 1024),
    ("large", 1050, 1100, 220 * 1024),
]:
    marker = f"__W1_WIDGET_{size.upper()}_CACHE_JPEG_BASE64__"
    if source.count(marker) != 1:
        raise SystemExit(f"Missing or duplicate Widget fixture marker: {size}")
    image = Path(sys.argv[1], f"sharing-widget-review-{size}.jpg").read_bytes()
    if not image.startswith(b"\xff\xd8") or not image.endswith(b"\xff\xd9") or len(image) > byte_cap:
        raise SystemExit("Widget fixture must be the bounded runtime JPEG")
    filename = f"{size}.jpg"
    (cache_output / filename).write_bytes(image)
    exported.append({
        "file": filename,
        "sha256": hashlib.sha256(image).hexdigest(),
        "bytes": len(image),
        "expectedWidth": width,
        "expectedHeight": height,
    })
    source = source.replace(marker, base64.b64encode(image).decode("ascii"))
view.write_text(source, encoding="utf-8")
(cache_output / "fixture-lineage.json").write_text(json.dumps({
    "schemaVersion": 1,
    "source": "cat-gray-portrait.png",
    "sourceSHA256": "bd5a348e5e6df1b32837c51ab0357505119ea564d13ac4afefe3803b1b8dfbf8",
    "productionBuilder": "WidgetCacheBuilder.buildFamilyWindow",
    "outputs": exported,
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")

view = Path("NekoWidget/Views/MomentDeliveryComposer.swift")
source = view.read_text(encoding="utf-8")
for name, filename in [
    ("GRAY", "cat-gray-portrait.png"),
    ("ORANGE", "cat-orange-square.png"),
    ("TUXEDO", "cat-tuxedo-landscape.png"),
]:
    marker = f"__MOMENT_EXPERIENCE_{name}_PNG_BASE64__"
    if source.count(marker) != 1:
        raise SystemExit(f"Missing or duplicate photo experience fixture marker: {name}")
    image = Path("ci/fixtures/cats", filename).read_bytes()
    if not image.startswith(b"\x89PNG\r\n\x1a\n"):
        raise SystemExit("Photo experience fixture must be a PNG")
    source = source.replace(marker, base64.b64encode(image).decode("ascii"))
view.write_text(source, encoding="utf-8")
PY
        # One normal fixture build feeds both explicit app UI shards and the
        # normal Gallery capture. No build writes occur while UI shards run.
        local device_type=""
        device_type="$(python3 - "$DEVICE_INVENTORY" "$runtime" "$simulator_udid" <<'PY'
import json
import sys
from pathlib import Path

devices = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["devices"]
device = next(device for device in devices[sys.argv[2]] if device["udid"] == sys.argv[3])
device_type = device.get("deviceTypeIdentifier", "")
if not device_type.startswith("com.apple.CoreSimulator.SimDeviceType.iPhone-"):
    raise SystemExit("The selected iPhone device type is unavailable")
print(device_type)
PY
        )" || return $?
        xcrun simctl shutdown "$simulator_udid" || return $?
        local shard=""
        local ui_udid=""
        local ui_primary_udid=""
        local ui_index=0
        local ui_status=0
        local ui_result=""
        local ui_test_manifest=""
        local -a ui_names=()
        local -a ui_udids=()
        local -a ui_statuses=()
        local -a ui_arguments=()
        local widget_review_conditions="APP_STORE_SCREENSHOT_WIDGET_FIXTURE WIDGET_VISUAL_REVIEW_FIXTURE"
        for shard in a b; do
            [[ -s "$UI_PARTITION_DIRECTORY/shard-$shard.txt" ]] || continue
            create_test_simulator ui_udid "UI-$shard" "$device_type" "$runtime" || return $?
            ui_names+=("$shard")
            ui_udids+=("$ui_udid")
        done
        ui_primary_udid="${ui_udids[0]}"
        prepare_simulator_and_build "$ui_primary_udid" --fresh xcodebuild \
            -project NekoWidget.xcodeproj \
            -scheme NekoWidget \
            -configuration Debug \
            -sdk iphonesimulator \
            -destination "platform=iOS Simulator,id=$ui_primary_udid" \
            -derivedDataPath "$DERIVED_DATA_DIRECTORY" \
            -resultBundlePath "$runtime_artifacts/MomentComposer-build.xcresult" \
            "${COMPOSER_TEST_ARGUMENTS[@]}" \
            -parallel-testing-enabled NO \
            -testLanguage ja \
            -testRegion JP \
            COMPILER_INDEX_STORE_ENABLE=NO \
            CODE_SIGNING_ALLOWED=YES \
            CODE_SIGN_IDENTITY=- \
            AD_HOC_CODE_SIGNING_ALLOWED=YES \
            'WIDGET_SCREENSHOT_FIXTURE_CONDITION=APP_STORE_SCREENSHOT_WIDGET_FIXTURE WIDGET_VISUAL_REVIEW_FIXTURE' \
            build-for-testing || return $?
        # Run the prepared test manifest directly. Concurrent workers must not
        # resolve/build the same scheme or write to a shared build database.
        ui_test_manifest="$(python3 - "$DERIVED_DATA_DIRECTORY/Build/Products" <<'PY'
import sys
from pathlib import Path

candidates = list(Path(sys.argv[1]).glob("NekoWidget_*.xctestrun"))
if len(candidates) != 1:
    raise SystemExit("Expected exactly one prepared NekoWidget test manifest")
print(candidates[0].resolve())
PY
        )" || return $?
        # Configure both before launching either test process. Each has its own
        # UDID, result bundle and log, with Xcode's automatic cloning disabled.
        for ui_udid in "${ui_udids[@]}"; do
            if [[ "$ui_udid" != "$ui_primary_udid" ]]; then
                xcrun simctl boot "$ui_udid" || return $?
                xcrun simctl bootstatus "$ui_udid" -b || return $?
            fi
            xcrun simctl spawn "$ui_udid" defaults write NSGlobalDomain AppleKeyboards -array ja_JP-Kana en_US || return $?
            xcrun simctl spawn "$ui_udid" defaults write NSGlobalDomain AppleLanguages -array ja || return $?
            xcrun simctl spawn "$ui_udid" defaults write NSGlobalDomain AppleLocale -string ja_JP || return $?
        done
        UI_PIDS=()
        for ui_index in "${!ui_names[@]}"; do
            shard="${ui_names[$ui_index]}"
            ui_arguments=()
            while IFS= read -r test_argument; do
                ui_arguments+=("$test_argument")
            done < "$UI_PARTITION_DIRECTORY/shard-$shard.txt"
            printf 'App UI shard %s started at %s\n' "$shard" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            xcodebuild \
                -xctestrun "$ui_test_manifest" \
                -destination "platform=iOS Simulator,id=${ui_udids[$ui_index]}" \
                -resultBundlePath "$runtime_artifacts/MomentComposer-$shard.xcresult" \
                "${ui_arguments[@]}" -parallel-testing-enabled NO \
                -testLanguage ja -testRegion JP \
                test-without-building > "$runtime_artifacts/ui-shard-$shard.log" 2>&1 &
            UI_PIDS+=("$!")
        done
        # Wait for BOTH even if the first fails. Aggregate before Gallery and
        # retain each exit status; no failed shard becomes a successful run.
        for ui_index in "${!ui_names[@]}"; do
            ui_status=0
            wait "${UI_PIDS[$ui_index]}" || ui_status=$?
            UI_PIDS[$ui_index]=""
            ui_statuses+=("$ui_status")
            if (( ui_status != 0 )); then
                composer_status=1
            fi
        done
        python3 - "$runtime_artifacts/ui-shard-results.json" "${ui_names[*]}" "${ui_statuses[*]}" <<'PY' || return $?
import json
import sys
from pathlib import Path

rows = [{"shard": name, "exitStatus": int(status)}
        for name, status in zip(sys.argv[2].split(), sys.argv[3].split(), strict=True)]
Path(sys.argv[1]).write_text(json.dumps({"schemaVersion": 1, "results": rows,
    "testCommandsSucceeded": all(row["exitStatus"] == 0 for row in rows)}, indent=2) + "\n", encoding="utf-8")
PY
        for ui_index in "${!ui_names[@]}"; do
            shard="${ui_names[$ui_index]}"
            cat "$runtime_artifacts/ui-shard-$shard.log" || composer_status=1
            ui_result="$runtime_artifacts/MomentComposer-$shard.xcresult"
            if [[ -d "$ui_result" ]]; then
                xcrun xcresulttool export attachments --path "$ui_result" \
                    --output-path "$runtime_artifacts/composer-screenshots/shard-$shard" || composer_status=1
            else
                echo "App UI shard $shard produced no result bundle." >&2
                composer_status=1
            fi
            discard_test_simulator "${ui_udids[$ui_index]}" || return $?
        done
        # Reuse only compiled products. Every Gallery condition starts on a
        # newly created UDID, after both app UI processes and devices finish.
        # No app-UI or earlier Gallery SpringBoard/catalog state is inherited.
        # These captures do not install a Home Screen Widget or invoke actions.
        local widget_scenario=""
        local widget_scenario_conditions=""
        local widget_scenario_result=""
        local widget_scenario_status=0
        local widget_scenario_test=""
        local widget_simulator_udid=""
        local -a widget_test_arguments=()
        for widget_scenario in normal long-white-large no-caption; do
            if [[ "$RUN_WIDGET_GALLERY" != true ]]; then
                break
            fi
            widget_scenario_test="testCaptureSharedWidgetAllSupportedSizes"
            widget_scenario_conditions=""
            case "$widget_scenario" in
                long-white-large)
                    widget_scenario_test="testCaptureSharedWidgetWhiteBackgroundAllSupportedSizes"
                    widget_scenario_conditions="WIDGET_VISUAL_REVIEW_LONG_CAPTION WIDGET_VISUAL_REVIEW_WHITE_BACKGROUND WIDGET_VISUAL_REVIEW_LARGE_TEXT"
                    ;;
                no-caption)
                    widget_scenario_conditions="WIDGET_VISUAL_REVIEW_NO_CAPTION"
                    ;;
            esac
            widget_scenario_result="$runtime_artifacts/Widget-$widget_scenario.xcresult"
            widget_scenario_status=0
            create_test_simulator widget_simulator_udid "Gallery-$widget_scenario" "$device_type" "$runtime" || return $?
            widget_test_arguments=(
                -project NekoWidget.xcodeproj
                -scheme NekoWidget
                -configuration Debug
                -sdk iphonesimulator
                -destination "platform=iOS Simulator,id=$widget_simulator_udid"
                -derivedDataPath "$DERIVED_DATA_DIRECTORY"
                "-only-testing:NekoWidgetUITests/WidgetPlacementScreenshotUITests/$widget_scenario_test"
                -parallel-testing-enabled NO
                -testLanguage ja
                -testRegion JP
                COMPILER_INDEX_STORE_ENABLE=NO
                CODE_SIGNING_ALLOWED=YES
                CODE_SIGN_IDENTITY=-
                AD_HOC_CODE_SIGNING_ALLOWED=YES
                "WIDGET_SCREENSHOT_FIXTURE_CONDITION=$widget_review_conditions $widget_scenario_conditions"
            )
            if [[ "$widget_scenario" == normal ]]; then
                # Reuse the normal build made before the app UI shards.
                xcrun simctl boot "$widget_simulator_udid" || return $?
                xcrun simctl bootstatus "$widget_simulator_udid" -b || return $?
            else
                prepare_simulator_and_build "$widget_simulator_udid" --fresh \
                    xcodebuild "${widget_test_arguments[@]}" \
                    -resultBundlePath "$runtime_artifacts/Widget-$widget_scenario-build.xcresult" \
                    build-for-testing || return $?
            fi
            xcodebuild "${widget_test_arguments[@]}" \
                -resultBundlePath "$widget_scenario_result" \
                test-without-building || widget_scenario_status=$?
            if [[ -d "$widget_scenario_result" ]]; then
                xcrun xcresulttool export attachments --path "$widget_scenario_result" \
                    --output-path "$runtime_artifacts/widget-$widget_scenario-screenshots" || widget_scenario_status=1
            fi
            discard_test_simulator "$widget_simulator_udid" || return $?
            if (( widget_scenario_status != 0 )); then
                return "$widget_scenario_status"
            fi
        done
        # App UI and Widget contrast/no-caption captures are independent.
        # Preserve the UI failure, but collect the remaining visual evidence
        # instead of withholding it because a different screen failed.
        if (( composer_status != 0 )); then
            return "$composer_status"
        fi
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
