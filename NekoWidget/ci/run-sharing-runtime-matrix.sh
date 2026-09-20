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
RUNTIME_LANE="${NEKO_IOS_RUNTIME_LANE:-all}"
UI_SELECTION_FILE="$RUNNER_TEMP/neko-sharing-runtime-ui-selection.txt"
RUNTIME_LABELS=("ios-18-5" "ios-26-2")
REQUESTED_RUNTIMES=(
    "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
    "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
)

SELECTED_UDIDS=()
APP_BUNDLE_ID=""
APP_GROUP_ID=""

# BEGIN DIAGNOSTIC-ONLY artifact
DIAGNOSTIC_REQUESTED=false
if [[ -n "${NEKO_IOS_DIAGNOSTIC_TEST_METHOD+x}" \
    || -n "${NEKO_IOS_DIAGNOSTIC_SOURCE_SHA+x}" \
    || "${GITHUB_WORKFLOW_REF:-}" == */.github/workflows/ios-ui-diagnostic.yml@* ]]; then
    DIAGNOSTIC_REQUESTED=true
    ARTIFACT_DIRECTORY="$RUNNER_TEMP/neko-ui-diagnostic"
fi
# END DIAGNOSTIC-ONLY artifact
mkdir -p "$ARTIFACT_DIRECTORY"
# BEGIN DIAGNOSTIC-ONLY selection
if [[ "$DIAGNOSTIC_REQUESTED" == true ]]; then
    python3 - "$PROJECT_DIRECTORY" "$ARTIFACT_DIRECTORY/diagnostic.json" "$UI_SELECTION_FILE" <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys

project, metadata_path, selection_path = map(Path, sys.argv[1:])
source = os.environ.get("NEKO_IOS_DIAGNOSTIC_SOURCE_SHA", "")
method = os.environ.get("NEKO_IOS_DIAGNOSTIC_TEST_METHOD", "")
repository = os.environ.get("GITHUB_REPOSITORY", "")
ref = os.environ.get("GITHUB_REF", "")
if (not repository or os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
        or not ref.startswith("refs/heads/diagnostic/")
        or os.environ.get("GITHUB_WORKFLOW_REF") != f"{repository}/.github/workflows/ios-ui-diagnostic.yml@{ref}"
        or os.environ.get("NEKO_IOS_RUNTIME_LANE") != "app-ui"):
    raise SystemExit("A single-test override is allowed only in the dedicated diagnostic workflow.")
if (re.fullmatch(r"[0-9a-f]{40}", source) is None
        or source != os.environ.get("GITHUB_SHA")
        or source != subprocess.check_output(["git", "-C", str(project), "rev-parse", "HEAD"], text=True).strip()):
    raise SystemExit("Diagnostic source must equal both the workflow SHA and checkout HEAD.")
if re.fullmatch(r"test[A-Za-z0-9_]+", method) is None:
    raise SystemExit("Specify exactly one XCTest method name, without arguments or a class path.")
test_source = (project / "NekoWidgetUITests/PhotoPermissionUITests.swift").read_text(encoding="utf-8")
# Existing tests use a top-level class and four-space method declarations.
# Do not match other classes, commented-out methods, or multiline string data.
test_source = re.sub(r'(?s)/\*.*?\*/|""".*?"""', "", test_source)
test_source = re.sub(r"(?m)//[^\n]*", "", test_source)
classes = re.findall(r"(?ms)^final class MomentDeliveryComposerUITests: XCTestCase \{\n(.*?)^\}", test_source)
declaration = rf"(?m)^    func {re.escape(method)}\(\)(?: async)?(?: throws)? \{{"
if len(classes) != 1 or len(re.findall(declaration, classes[0])) != 1:
    raise SystemExit("The requested method is not an existing MomentDeliveryComposerUITests test.")
test = f"NekoWidgetUITests/MomentDeliveryComposerUITests/{method}"
metadata_path.write_text(json.dumps({
    "schemaVersion": 1, "diagnosticOnly": True, "releaseEvidence": False,
    "sourceSHA": source, "workflowSHA": os.environ["GITHUB_SHA"],
    "repository": repository, "nativeTests": [test], "runtime": "ios-26-2",
    "fixturePreparation": "run-sharing-runtime-matrix",
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
selection_path.write_text(f"-only-testing:{test}\n", encoding="utf-8")
PY
else
# END DIAGNOSTIC-ONLY selection
python3 "$PROJECT_DIRECTORY/ci/ios_ci_scope.py" \
    --scope "$RUNTIME_SCOPE" \
    --lane "$RUNTIME_LANE" \
    --metadata "$ARTIFACT_DIRECTORY/runtime-scope.json" \
    --tests "$UI_SELECTION_FILE"
# BEGIN DIAGNOSTIC-ONLY selection-end
fi
# END DIAGNOSTIC-ONLY selection-end
COMPOSER_TEST_ARGUMENTS=()
while IFS= read -r test_argument; do
    COMPOSER_TEST_ARGUMENTS+=("$test_argument")
done < "$UI_SELECTION_FILE"
if [[ "$RUNTIME_LANE" != runtime ]] && (( ${#COMPOSER_TEST_ARGUMENTS[@]} == 0 )); then
    echo "The requested scope did not select any native UI tests." >&2
    exit 1
fi
RUN_WIDGET_GALLERY=false
if [[ "$RUNTIME_SCOPE" == "full-v1" && "$RUNTIME_LANE" == all ]]; then
    RUN_WIDGET_GALLERY=true
fi
WIDGET_SCENARIOS=""
case "$RUNTIME_LANE" in
    all)
        if [[ "$RUN_WIDGET_GALLERY" == true ]]; then
            WIDGET_SCENARIOS="long-white-large no-caption personal-available personal-used"
        fi
        ;;
    runtime) ;;
    app-ui|gallery-normal|gallery-white|gallery-no-caption)
        # Each visual lane regenerates its own validated production cache.
        # Do not transfer an injected checkout or fixture build between jobs.
        RUNTIME_LABELS=("ios-26-2")
        REQUESTED_RUNTIMES=("com.apple.CoreSimulator.SimRuntime.iOS-26-2")
        if [[ "$RUNTIME_LANE" == gallery-white ]]; then
            WIDGET_SCENARIOS="long-white-large"
        elif [[ "$RUNTIME_LANE" == gallery-no-caption ]]; then
            WIDGET_SCENARIOS="no-caption"
        elif [[ "$RUNTIME_LANE" == gallery-normal ]]; then
            WIDGET_SCENARIOS="personal-available personal-used"
        fi
        ;;
esac

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
    # After ordinary runtime validation, use the same iOS 26 Simulator for UI
    # review. Only these final test builds enable Widget Gallery fixture pixels.
    # These DEBUG fixtures have no accounts, PhotoKit access or network activity.
    if (( validator_status == 0 )) && [[ "$label" == "ios-26-2" && "$RUNTIME_LANE" != runtime ]]; then
        local composer_status=0
        local composer_result="$runtime_artifacts/MomentComposer.xcresult"
        xcrun simctl terminate "$simulator_udid" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
        defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
        xcrun simctl spawn "$simulator_udid" defaults write NSGlobalDomain \
            AppleKeyboards -array ja_JP-Kana en_US
        xcrun simctl spawn "$simulator_udid" defaults write NSGlobalDomain \
            AppleLanguages -array ja
        xcrun simctl spawn "$simulator_udid" defaults write NSGlobalDomain \
            AppleLocale -string ja_JP
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
        # Keep the same fixture preparation/build for full and mapped UI.
        # Only test selection and the extra Gallery builds vary by scope.
        if [[ "$RUNTIME_LANE" == all || "$RUNTIME_LANE" == app-ui || "$RUNTIME_LANE" == gallery-normal ]]; then
        xcodebuild \
            -project NekoWidget.xcodeproj \
            -scheme NekoWidget \
            -configuration Debug \
            -sdk iphonesimulator \
            -destination "platform=iOS Simulator,id=$simulator_udid" \
            -derivedDataPath "$DERIVED_DATA_DIRECTORY" \
            -resultBundlePath "$composer_result" \
            "${COMPOSER_TEST_ARGUMENTS[@]}" \
            -parallel-testing-enabled NO \
            -testLanguage ja \
            -testRegion JP \
            COMPILER_INDEX_STORE_ENABLE=NO \
            CODE_SIGNING_ALLOWED=YES \
            CODE_SIGN_IDENTITY=- \
            AD_HOC_CODE_SIGNING_ALLOWED=YES \
            'WIDGET_SCREENSHOT_FIXTURE_CONDITION=APP_STORE_SCREENSHOT_WIDGET_FIXTURE WIDGET_VISUAL_REVIEW_FIXTURE' \
            test || composer_status=$?
        if [[ -d "$composer_result" ]]; then
            xcrun xcresulttool export attachments --path "$composer_result" \
                --output-path "$runtime_artifacts/composer-screenshots"
        fi
        fi
        # Reuse DerivedData, but reset the disposable Simulator between
        # fixture builds. WidgetKit can otherwise serve the previous Gallery
        # snapshot even after Xcode installs the newly compiled extension.
        # These captures do not install a Home Screen Widget or invoke actions.
        local widget_review_conditions="APP_STORE_SCREENSHOT_WIDGET_FIXTURE WIDGET_VISUAL_REVIEW_FIXTURE"
        local widget_scenario=""
        local widget_scenario_conditions=""
        local widget_scenario_result=""
        local widget_scenario_status=0
        local widget_scenario_test=""
        local -a widget_test_arguments=()
        for widget_scenario in $WIDGET_SCENARIOS; do
            widget_review_conditions="APP_STORE_SCREENSHOT_WIDGET_FIXTURE WIDGET_VISUAL_REVIEW_FIXTURE"
            widget_scenario_conditions=""
            widget_scenario_test="testCaptureSharedWidgetAllSupportedSizes"
            case "$widget_scenario" in
                personal-available)
                    widget_review_conditions="APP_STORE_SCREENSHOT_WIDGET_FIXTURE PERSONAL_REDISCOVERY_WIDGET_FIXTURE"
                    widget_scenario_test="testCapturePersonalRediscoveryWidgetAvailableAllSupportedSizes"
                    ;;
                personal-used)
                    widget_review_conditions="APP_STORE_SCREENSHOT_WIDGET_FIXTURE PERSONAL_REDISCOVERY_WIDGET_FIXTURE"
                    widget_scenario_conditions="PERSONAL_REDISCOVERY_WIDGET_USED_FIXTURE"
                    widget_scenario_test="testCapturePersonalRediscoveryWidgetUsedAllSupportedSizes"
                    ;;
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
            # Runtime results and cache JPEGs were exported above. These last
            # builds need no simulator data: erase both extension registrations
            # and SpringBoard's cached previews before installing each fixture.
            # Compile while this fresh Simulator boots, then test the exact
            # prepared products. No test runs if either preparation fails.
            widget_test_arguments=(
                -project NekoWidget.xcodeproj
                -scheme NekoWidget
                -configuration Debug
                -sdk iphonesimulator
                -destination "platform=iOS Simulator,id=$simulator_udid"
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
            prepare_simulator_and_build "$simulator_udid" \
                xcodebuild "${widget_test_arguments[@]}" \
                -resultBundlePath "$runtime_artifacts/Widget-$widget_scenario-build.xcresult" \
                build-for-testing || return $?
            xcodebuild "${widget_test_arguments[@]}" \
                -resultBundlePath "$widget_scenario_result" \
                test-without-building || widget_scenario_status=$?
            if [[ -d "$widget_scenario_result" ]]; then
                xcrun xcresulttool export attachments --path "$widget_scenario_result" \
                    --output-path "$runtime_artifacts/widget-$widget_scenario-screenshots"
            fi
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
