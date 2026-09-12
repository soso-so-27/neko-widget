#!/usr/bin/env python3
"""Exercise concurrent build/boot joins without Xcode or a Simulator."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


CI = Path(__file__).resolve().parent
GIT_BASH = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
BASH = str(GIT_BASH) if os.name == "nt" and GIT_BASH.is_file() else shutil.which("bash")


class PreparationTests(unittest.TestCase):
    def run_preparation(self, fail_step="", build_status=0):
        self.assertIsNotNone(BASH, "Bash is required to exercise the real preparation helper")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # The handshake requires build and boot to start before either can
            # finish; a serial implementation fails instead of silently passing.
            harness = root / "harness.sh"
            harness.write_text(r'''#!/usr/bin/env bash
set -Eeuo pipefail
source "$1"
cd "$2"
fail_step="$3"
fixture_build_status="$4"
await_marker() {
    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ -f "$1" ]] && return 0
        sleep 0.02
    done
    return 91
}
xcrun() {
    [[ "$1" == simctl && "$3" == fixture-device ]] || return 92
    printf '%s\n' "$2" >> events
    if [[ "$2" == shutdown ]]; then
        touch boot-started
        await_marker build-started || return $?
    fi
    [[ "$2" != "$fail_step" ]] || return 42
    if [[ "$2" == bootstatus ]]; then
        [[ "$4" == -b ]] || return 93
        touch boot-complete
    fi
}
build() {
    [[ "$#" == 2 && "$1" == 'a path with spaces' && "$2" == build-for-testing ]] || return 94
    printf '%s\n' build >> events
    touch build-started
    await_marker boot-started || return $?
    touch build-complete
    return "$fixture_build_status"
}
status=0
prepare_simulator_and_build fixture-device build 'a path with spaces' build-for-testing || status=$?
# Simulate the harness gate: failed preparation cannot become a passing test.
if (( status == 0 )); then
    [[ -f boot-complete && -f build-complete ]] || exit 95
    printf '%s\n' test >> events
fi
exit "$status"
''', encoding="utf-8")
            result = subprocess.run(
                [BASH, str(harness).replace("\\", "/"),
                 (CI / "prepare-simulator-and-build.sh").as_posix(), root.as_posix(),
                 fail_step, str(build_status)],
                capture_output=True, text=True, encoding="utf-8", timeout=20,
            )
            events = (root / "events").read_text().splitlines()
            return result, events

    def test_build_and_boot_overlap_and_both_complete_before_test(self):
        result, events = self.run_preparation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([x for x in events if x != "build"],
                         ["shutdown", "erase", "boot", "bootstatus", "test"])

    def test_each_fresh_simulator_failure_prevents_test(self):
        for step in ("shutdown", "erase", "boot", "bootstatus"):
            with self.subTest(step=step):
                result, events = self.run_preparation(fail_step=step)
                self.assertEqual(result.returncode, 42, result.stderr)
                self.assertNotIn("test", events)
                self.assertIn("build", events)
                self.assertIn("fresh-Simulator preparation failed", result.stderr)

    def test_build_failure_is_not_masked_by_successful_or_failed_boot(self):
        for step in ("", "erase"):
            with self.subTest(step=step):
                result, events = self.run_preparation(fail_step=step, build_status=41)
                self.assertEqual(result.returncode, 41, result.stderr)
                self.assertNotIn("test", events)
                self.assertIn("build-for-testing failed", result.stderr)

    def test_harness_keeps_condition_identity_artifacts_and_failure_aggregation(self):
        harness = (CI / "run-sharing-runtime-matrix.sh").read_text(encoding="utf-8")
        start = harness.index("for widget_scenario in long-white-large no-caption; do")
        body = harness[start:harness.index("\n        done", start)]
        self.assertIn('source "$PROJECT_DIRECTORY/ci/prepare-simulator-and-build.sh"', harness)
        self.assertIn('build-for-testing || return $?', body)
        self.assertIn('test-without-building || widget_scenario_status=$?', body)
        self.assertEqual(body.count('"${widget_test_arguments[@]}"'), 2)
        self.assertIn('return "$widget_scenario_status"', body)
        self.assertIn('Widget-$widget_scenario-build.xcresult', body)
        self.assertIn('Widget-$widget_scenario.xcresult', body)
        self.assertIn('widget-$widget_scenario-screenshots', body)
        self.assertIn('run_runtime_body "$label" "$runtime" "$simulator_udid" \\\n        || runtime_status=$?', harness)
        self.assertIn('run_runtime "$label" "$runtime" "$simulator_udid" \\\n        || runtime_status=$?', harness)
        self.assertIn('if (( runtime_status != 0 )); then\n        matrix_status=1', harness)
        self.assertIn('exit "$matrix_status"', harness)


if __name__ == "__main__":
    unittest.main()
