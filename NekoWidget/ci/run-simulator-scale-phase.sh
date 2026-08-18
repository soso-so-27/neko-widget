#!/usr/bin/env bash

# This file is sourced by run-simulator-smoke.sh after its proven build,
# entitlement validation, installation, Photos permission UI test and baseline
# snapshot. It intentionally does not install its own EXIT trap.

run_simulator_scale_phase() {
    local baseline_snapshot="$1"
    local scale_count="${SCALE_PHOTO_COUNT:-1000}"
    local large_count=3
    local generator_source="$PROJECT_DIRECTORY/ci/generate-scale-fixtures.swift"
    local generator_binary="$RUNNER_TEMP/generate-scale-fixtures"
    local sampler_source="$PROJECT_DIRECTORY/ci/sample-process-memory.c"
    local sampler_binary="$RUNNER_TEMP/sample-process-memory"
    local fixture_root="$RUNNER_TEMP/neko-scale-fixtures"
    local fixture_manifest="$fixture_root/scale-fixture-manifest.json"
    local artifact_manifest="$ARTIFACT_DIRECTORY/scale-fixture-manifest.json"
    local memory_csv="$ARTIFACT_DIRECTORY/memory-samples.csv"
    local sampler_log="$ARTIFACT_DIRECTORY/memory-sampler.log"
    local scan_timeout_seconds=0
    local scan_deadline=0
    local scan_start_epoch_ns=""
    local scan_end_epoch_ns=""
    local scan_elapsed_seconds=""
    local sampler_status=0
    local process_exited_early="false"
    local authorization_failed="false"
    local scan_completed="false"
    local validation_status=0
    local last_progress_report=0
    local now=0
    local crash_root=""
    local crash_report=""
    local generation_started=0
    local generation_finished=0
    local import_started=0
    local import_finished=0
    local -a bulk_files=()
    local -a large_files=()
    local -a warmup_files=()

    scale_snapshot_is_complete() {
        local snapshot_path="$1"
        python3 - "$snapshot_path" "$baseline_snapshot" "$scale_count" <<'PY'
import json
import sys
from pathlib import Path

try:
    current = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
    baseline = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8-sig"))
    expected = int(sys.argv[3])
except (OSError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)

baseline_ids = {
    asset.get("localIdentifier")
    for asset in baseline.get("assets", [])
    if isinstance(asset, dict) and isinstance(asset.get("localIdentifier"), str)
}
imported = [
    asset
    for asset in current.get("assets", [])
    if isinstance(asset, dict)
    and isinstance(asset.get("localIdentifier"), str)
    and asset.get("localIdentifier") not in baseline_ids
]
state = current.get("scanState", {})
ready = (
    state.get("phase") == "completed"
    and state.get("resultKind") == "final"
    and len(imported) == expected
    and all(asset.get("analysisStatus") in {"detected", "noCat"} for asset in imported)
    and any(asset.get("analysisStatus") == "detected" for asset in imported)
)
raise SystemExit(0 if ready else 1)
PY
    }

    case "$scale_count" in
        1000|2000|3000) ;;
        *)
            echo "SCALE_PHOTO_COUNT must be one of 1000, 2000 or 3000; got $scale_count." >&2
            return 2
            ;;
    esac
    if [[ ! -f "$baseline_snapshot" ]]; then
        echo "Scale-test baseline snapshot is missing: $baseline_snapshot" >&2
        return 1
    fi
    if [[ ! -f "$generator_source" || ! -f "$sampler_source" ]]; then
        echo "Scale-test generator or memory sampler source is missing." >&2
        return 1
    fi

    # Six seconds per image leaves CPU-only Vision ample time on the hosted M1
    # while reserving at least roughly 30 minutes of the six-hour job for build,
    # evidence collection and artifact upload at the 3,000-image setting.
    scan_timeout_seconds=$((scale_count * 6))
    printf 'Scale phase configuration: photos=%s large=%s timeout=%ss\n' \
        "$scale_count" "$large_count" "$scan_timeout_seconds"
    printf '%s\n' "$scale_count" > "$ARTIFACT_DIRECTORY/requested-photo-count.txt"

    echo "Compiling deterministic fixture generator."
    xcrun --sdk macosx swiftc \
        "$generator_source" \
        -o "$generator_binary"
    echo "Compiling process physical-footprint sampler."
    xcrun --sdk macosx clang \
        -std=c17 -O2 -Wall -Wextra -Werror \
        "$sampler_source" \
        -o "$sampler_binary" \
        -lproc

    mkdir -p "$fixture_root"
    generation_started="$(date -u '+%s')"
    "$generator_binary" \
        --source-dir "$FIXTURE_DIRECTORY" \
        --output-dir "$fixture_root" \
        --count "$scale_count"
    generation_finished="$(date -u '+%s')"
    cp "$fixture_manifest" "$artifact_manifest"

    python3 - "$fixture_manifest" "$scale_count" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = int(sys.argv[2])
outputs = manifest.get("outputs", [])
failures = []
if manifest.get("schemaVersion") != 1:
    failures.append("unexpected manifest schema")
if manifest.get("totalCount") != expected or len(outputs) != expected:
    failures.append("generated count does not match the requested count")
if manifest.get("largeCount") != 3:
    failures.append("manifest does not contain exactly three large fixtures")
if manifest.get("warmupCount") != 4:
    failures.append("manifest does not contain exactly four warm-up fixtures")
if not manifest.get("allOutputHashesUnique"):
    failures.append("generated fixture hashes are not unique")
large = [item for item in outputs if item.get("role") == "large"]
if len(large) != 3 or any(
    item.get("width") != 8000 or item.get("height") != 6000 for item in large
):
    failures.append("large fixtures are not exactly 8000x6000")
if failures:
    raise SystemExit("; ".join(failures))
PY

    shopt -s nullglob
    bulk_files=("$fixture_root/bulk/"*.jpg)
    large_files=("$fixture_root/large/"*.jpg)
    warmup_files=("$fixture_root/warmup/"*.jpg)
    shopt -u nullglob
    if (( ${#bulk_files[@]} + ${#large_files[@]} + ${#warmup_files[@]} != scale_count )); then
        echo "Generated file count does not match manifest total." >&2
        return 1
    fi
    if (( ${#large_files[@]} != large_count || ${#warmup_files[@]} != 4 )); then
        echo "Generated role directories are incomplete." >&2
        return 1
    fi

    import_scale_role() {
        local role="$1"
        shift
        local -a role_files=("$@")
        local role_offset=0
        local role_batch_number=0
        local role_batch_status=0
        local role_batch_label=""
        local -a role_batch=()
        while (( role_offset < ${#role_files[@]} )); do
            role_batch=("${role_files[@]:role_offset:100}")
            role_batch_number=$((role_batch_number + 1))
            printf 'Importing %s batch %d (%d file(s)).\n' \
                "$role" "$role_batch_number" "${#role_batch[@]}"
            printf -v role_batch_label 'scale-%s-%03d' \
                "$role" "$role_batch_number"
            role_batch_status=0
            bounded_simctl_addmedia "$role_batch_label" "${role_batch[@]}" \
                || role_batch_status=$?
            if (( role_batch_status != 0 )); then
                echo "Scale batch $role_batch_label will not be retried. " \
                    "The final baseline-relative asset count will fail closed if " \
                    "the import was incomplete." >&2
            fi
            role_offset=$((role_offset + ${#role_batch[@]}))
        done
    }

    # Warm-up images carry the newest capture dates, followed by the 48 MP
    # images. This initializes Vision before the large-image memory windows and
    # keeps those windows deterministic while every output remains unique.
    import_started="$(date -u '+%s')"
    import_scale_role "bulk" "${bulk_files[@]}"
    sleep 2
    import_scale_role "large" "${large_files[@]}"
    sleep 2
    import_scale_role "warmup" "${warmup_files[@]}"
    import_finished="$(date -u '+%s')"
    sleep 15

    python3 - \
        "$generation_started" "$generation_finished" \
        "$import_started" "$import_finished" \
        "$ARTIFACT_DIRECTORY/setup-timings.json" <<'PY'
import json
import sys
from pathlib import Path

generation_started, generation_finished, import_started, import_finished = map(
    int, sys.argv[1:5]
)
Path(sys.argv[5]).write_text(
    json.dumps(
        {
            "fixtureGenerationSeconds": generation_finished - generation_started,
            "photoImportSeconds": import_finished - import_started,
        },
        indent=2,
        sort_keys=True,
    ) + "\n",
    encoding="utf-8",
)
PY

    # The permission bootstrap process was already terminated and its logs
    # archived by the parent harness. Clear the fixed diagnostic directory one
    # final time immediately before the measured launch so a delayed WidgetKit
    # callback cannot introduce a stale app-session PID into the scale report.
    APP_GROUP_CONTAINER="$(resolve_group_container || true)"
    if [[ -z "$APP_GROUP_CONTAINER" \
        || "$APP_GROUP_CONTAINER" != "$HOME/Library/Developer/CoreSimulator/Devices/$SIMULATOR_UDID/data/Containers/Shared/AppGroup/"* ]]; then
        echo "Refusing to clean an unresolved or unexpected App Group container." >&2
        return 1
    fi
    rm -rf -- "$APP_GROUP_CONTAINER/diagnostic-logs"

    touch "$ARTIFACT_DIRECTORY/scale-start.marker"
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$ARTIFACT_DIRECTORY/scale-start-utc.txt"
    date -u '+%Y-%m-%d %H:%M:%S' > "$ARTIFACT_DIRECTORY/scale-log-start.txt"
    scan_start_epoch_ns="$(python3 -c 'import time; print(time.time_ns())')"
    launch_app "scale" --neko-simulator-scale

    # Start sampling immediately after simctl returns the host PID. The four
    # newest regular-size fixtures warm Vision before the 48 MP assets, giving
    # the sampler a pre-large baseline while the kernel lifetime high-water
    # counter still captures any spike before the first 100 ms poll.
    MEMORY_SAMPLER_STOP_FILE="$ARTIFACT_DIRECTORY/memory-sampler.stop"
    rm -f "$MEMORY_SAMPLER_STOP_FILE"
    "$sampler_binary" \
        "$APP_PID" "$memory_csv" "$MEMORY_SAMPLER_STOP_FILE" 100 \
        > "$sampler_log" 2>&1 &
    MEMORY_SAMPLER_PID=$!

    if ! wait_for_photo_authorization \
        "Photo authorization checked" "authorized" 15; then
        echo "PhotoKit was not authorized for the scale scan." >&2
        authorization_failed="true"
    fi

    scan_deadline=$(( $(date -u '+%s') + scan_timeout_seconds ))
    while [[ "$process_exited_early" != "true" \
        && "$authorization_failed" != "true" ]]; do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            echo "The single scale-test app process exited before completion." >&2
            process_exited_early="true"
            break
        fi

        APP_GROUP_CONTAINER="$(resolve_group_container || true)"
        if [[ -n "$APP_GROUP_CONTAINER" \
            && -f "$APP_GROUP_CONTAINER/library-snapshot.json" \
            && -d "$APP_GROUP_CONTAINER/diagnostic-logs" ]] \
            && grep -R -q 'Final scan result applied' \
                "$APP_GROUP_CONTAINER/diagnostic-logs" \
            && python3 - "$APP_GROUP_CONTAINER/library-snapshot.json" <<'PY'
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
    if state.get("phase") == "completed"
    and state.get("resultKind") == "final"
    else 1
)
PY
        then
            scan_completed="true"
            if ! scale_snapshot_is_complete \
                "$APP_GROUP_CONTAINER/library-snapshot.json"; then
                echo "The scale scan finished, but imported assets are incomplete or nonterminal." >&2
            fi
            break
        fi

        now="$(date -u '+%s')"
        if (( now >= scan_deadline )); then
            echo "Scale scan exceeded its ${scan_timeout_seconds}-second internal deadline." >&2
            break
        fi
        if (( now - last_progress_report >= 60 )); then
            last_progress_report=$now
            python3 - "$APP_GROUP_CONTAINER/library-snapshot.json" <<'PY' || true
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if path.is_file():
    state = json.loads(path.read_text(encoding="utf-8-sig")).get("scanState", {})
    print(
        "Scale progress checkpoint: "
        f"phase={state.get('phase')} scanned={state.get('scannedAssets')} "
        f"total={state.get('totalAssets')} cats={state.get('catAssets')}"
    )
PY
        fi
        sleep 2
    done

    scan_end_epoch_ns="$(python3 -c 'import time; print(time.time_ns())')"
    scan_elapsed_seconds="$(python3 - "$scan_start_epoch_ns" "$scan_end_epoch_ns" <<'PY'
import sys
print(f"{(int(sys.argv[2]) - int(sys.argv[1])) / 1_000_000_000:.3f}")
PY
)"
    printf '%s\n' "$scan_start_epoch_ns" > "$ARTIFACT_DIRECTORY/scan-start-epoch-ns.txt"
    printf '%s\n' "$scan_end_epoch_ns" > "$ARTIFACT_DIRECTORY/scan-end-epoch-ns.txt"
    printf '%s\n' "$scan_elapsed_seconds" > "$ARTIFACT_DIRECTORY/scan-elapsed-seconds.txt"
    printf 'Scale scan observation ended: completed=%s exitedEarly=%s elapsed=%ss\n' \
        "$scan_completed" "$process_exited_early" "$scan_elapsed_seconds"

    touch "$MEMORY_SAMPLER_STOP_FILE"
    if wait "$MEMORY_SAMPLER_PID"; then
        sampler_status=0
    else
        sampler_status=$?
    fi
    MEMORY_SAMPLER_PID=""
    printf '%s\n' "$sampler_status" \
        > "$ARTIFACT_DIRECTORY/memory-sampler-exit-code.txt"

    capture_screenshot
    APP_GROUP_CONTAINER="$(resolve_group_container || true)"
    if [[ -z "$APP_GROUP_CONTAINER" || ! -d "$APP_GROUP_CONTAINER" ]]; then
        echo "The App Group container could not be resolved after the scale scan." >&2
        return 1
    fi

    mkdir -p "$ARTIFACT_DIRECTORY/crash-reports"
    for crash_root in \
        "$HOME/Library/Logs/DiagnosticReports" \
        "$HOME/Library/Developer/CoreSimulator/Devices/$SIMULATOR_UDID/data/Library/Logs/CrashReporter" \
        "$HOME/Library/Developer/CoreSimulator/Devices/$SIMULATOR_UDID/data/Library/Logs/DiagnosticReports"; do
        [[ -d "$crash_root" ]] || continue
        while IFS= read -r crash_report; do
            cp "$crash_report" "$ARTIFACT_DIRECTORY/crash-reports/" 2>/dev/null || true
        done < <(
            find "$crash_root" -type f \
                \( -name 'NekoWidget*.crash' \
                -o -name 'NekoWidget*.ips' \
                -o -name 'JetsamEvent*.ips' \) \
                -newer "$ARTIFACT_DIRECTORY/scale-start.marker" \
                2>/dev/null || true
        )
    done
    xcrun simctl spawn "$SIMULATOR_UDID" log show \
        --style compact \
        --start "$(cat "$ARTIFACT_DIRECTORY/scale-log-start.txt")" \
        --predicate 'eventMessage CONTAINS[c] "jetsam" OR eventMessage CONTAINS[c] "memorystatus" OR eventMessage CONTAINS[c] "memory pressure"' \
        > "$ARTIFACT_DIRECTORY/simulator-memory-termination.log" 2>&1 || true

    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "The app process was no longer alive at validation time." >&2
        process_exited_early="true"
    fi

    if python3 "$PROJECT_DIRECTORY/ci/validate-simulator-scale.py" \
        --app-group-container "$APP_GROUP_CONTAINER" \
        --baseline-snapshot "$baseline_snapshot" \
        --fixture-manifest "$artifact_manifest" \
        --memory-csv "$memory_csv" \
        --expected-count "$scale_count" \
        --expected-large-count "$large_count" \
        --scan-start-epoch-ns "$scan_start_epoch_ns" \
        --scan-end-epoch-ns "$scan_end_epoch_ns" \
        --app-pid "$APP_PID" \
        --sampler-exit-code "$sampler_status" \
        --authorization-failed "$authorization_failed" \
        --process-exited-early "$process_exited_early" \
        --scan-completed "$scan_completed" \
        --crash-directory "$ARTIFACT_DIRECTORY/crash-reports" \
        --memory-termination-log "$ARTIFACT_DIRECTORY/simulator-memory-termination.log" \
        --max-peak-mib "${SCALE_MAX_PEAK_MIB:-512}" \
        --max-large-delta-mib "${SCALE_MAX_LARGE_DELTA_MIB:-128}" \
        --report "$ARTIFACT_DIRECTORY/scale-report.json" \
        --summary "$ARTIFACT_DIRECTORY/scale-summary.md"; then
        validation_status=0
    else
        validation_status=$?
    fi

    if [[ -n "${GITHUB_STEP_SUMMARY:-}" \
        && -f "$ARTIFACT_DIRECTORY/scale-summary.md" ]]; then
        cat "$ARTIFACT_DIRECTORY/scale-summary.md" >> "$GITHUB_STEP_SUMMARY"
    fi
    if (( validation_status != 0 )); then
        return "$validation_status"
    fi
}
