#!/usr/bin/env bash

# Source this helper. Build preparation does not use Simulator state, so it
# may overlap a fresh boot. The caller may test only after both have succeeded.
# Keep the two jobs joined even on failure; no preparation child may outlive
# this function and race the runtime harness's final Simulator cleanup.
prepare_simulator_and_build() (
    local simulator_udid="$1"
    shift
    # Only the harness's newly created, owned UDIDs may skip shutdown/erase.
    # Existing callers retain the original cold-reset contract.
    local already_fresh=false
    if [[ "${1:-}" == "--fresh" ]]; then
        already_fresh=true
        shift
    fi
    local boot_pid=""
    local build_status=0
    local boot_status=0

    cleanup_preparation() {
        local original_status=$?
        trap - EXIT
        if [[ -n "$boot_pid" ]]; then
            kill "$boot_pid" >/dev/null 2>&1 || true
            wait "$boot_pid" 2>/dev/null || true
        fi
        exit "$original_status"
    }
    trap cleanup_preparation EXIT

    reset_and_boot() {
        if [[ "$already_fresh" != true ]]; then
            xcrun simctl shutdown "$simulator_udid" || return $?
            xcrun simctl erase "$simulator_udid" || return $?
        fi
        xcrun simctl boot "$simulator_udid" || return $?
        xcrun simctl bootstatus "$simulator_udid" -b || return $?
    }

    printf 'Widget preparation started at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    reset_and_boot &
    boot_pid=$!
    "$@" || build_status=$?
    wait "$boot_pid" || boot_status=$?
    boot_pid=""
    if (( build_status != 0 )); then
        echo "Widget build-for-testing failed (status $build_status)." >&2
        return "$build_status"
    fi
    if (( boot_status != 0 )); then
        echo "Widget fresh-Simulator preparation failed (status $boot_status)." >&2
        return "$boot_status"
    fi
    printf 'Widget preparation passed at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
)
