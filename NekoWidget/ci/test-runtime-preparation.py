#!/usr/bin/env python3
"""Exercise concurrent build/boot joins without Xcode or a Simulator."""

import os
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import ios_ci_scope as scope


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
        start = harness.index("for widget_scenario in normal long-white-large no-caption; do")
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

    def test_parallel_partition_preserves_every_scope_and_rejects_unknown_tests(self):
        source = (CI / "run-sharing-runtime-matrix.sh").read_text(encoding="utf-8")
        selection = source.split("COMPOSER_TEST_ARGUMENTS=()", 1)[1].split("\ncollect_ui_clones()", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script, selected = root / "partition.sh", root / "selection.txt"
            script.write_text('set -Eeuo pipefail\nRUNTIME_SCOPE="$1"\nUI_SELECTION_FILE="$2"\n'
                              + 'COMPOSER_TEST_ARGUMENTS=()' + selection
                              + '\nprintf "%s\\n" "${COMPOSER_TEST_ARGUMENTS[@]}" "gallery=$RUN_WIDGET_GALLERY"\n', encoding="utf-8", newline="\n")
            for requested in scope.SCOPES:
                expected = scope.native_tests(requested)
                selected.write_text("".join("-only-testing:" + name + "\n" for name in expected), encoding="utf-8", newline="\n")
                result = subprocess.run([BASH, script.as_posix(), requested, selected.as_posix()],
                                        capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                lines = result.stdout.splitlines()
                self.assertEqual(lines[:-1], ["-only-testing:" + name for name in expected if name != scope.GALLERY_TEST])
                self.assertEqual(lines[-1], "gallery=" + str(requested == scope.FULL_SCOPE).lower())
            for invalid in ("-only-testing:NekoWidgetUITests/UnknownTests\n",
                            "-only-testing:" + scope.GALLERY_TEST + "\n"):
                selected.write_text(invalid, encoding="utf-8", newline="\n")
                result = subprocess.run([BASH, script.as_posix(), scope.FULL_SCOPE, selected.as_posix()],
                                        capture_output=True, text=True, timeout=15)
                self.assertNotEqual(result.returncode, 0)

    def test_clone_inventory_only_selects_new_clones_of_the_original_runtime_device(self):
        source = (CI / "run-sharing-runtime-matrix.sh").read_text(encoding="utf-8")
        collector = source.split("collect_ui_clones() {", 1)[1].split("<<'PY' || return $?\n", 1)[1].split("\nPY", 1)[0]
        runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
        original = {"udid": "original", "name": "iPhone 17 Pro"}
        existing = {"udid": "existing", "name": "Clone 1 of iPhone 17 Pro"}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            before, after, identifiers, metadata = [root / name for name in ("before.json", "after.json", "ids.txt", "counts.json")]
            before.write_text(json.dumps({"devices": {runtime: [original, existing]}}))
            after.write_text(json.dumps({"devices": {
                runtime: [original, existing, {"udid": "new1", "name": "Clone 2 of iPhone 17 Pro"},
                          {"udid": "new2", "name": "Clone 3 of iPhone 17 Pro"},
                          {"udid": "other-device", "name": "Clone 1 of iPhone 17"},
                          {"udid": "not-clone", "name": "iPhone 17 Pro"}],
                "another-runtime": [{"udid": "other-os", "name": "Clone 1 of iPhone 17 Pro"}],
            }}))
            result = subprocess.run([sys.executable, "-", str(before), str(after), "original",
                                     str(identifiers), str(metadata), scope.FULL_SCOPE], input=collector,
                                    capture_output=True, text=True, env={**os.environ, "GITHUB_SHA": "a" * 40}, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(identifiers.read_text().splitlines(), ["new1", "new2"])
            report = json.loads(metadata.read_text())
            self.assertEqual(report["observedNewCloneCount"], 2)
            self.assertEqual(report["commit"], "a" * 40)
            self.assertEqual(report["requestedWorkers"], 2)
            self.assertNotIn("udid", metadata.read_text())
            self.assertNotIn("iPhone", metadata.read_text())

    def test_parallel_workers_finish_and_clean_up_before_any_serial_gallery(self):
        source = (CI / "run-sharing-runtime-matrix.sh").read_text(encoding="utf-8")
        app = source.split('UI_SOURCE_UDID="$simulator_udid"', 1)[1].split('for widget_scenario', 1)[0]
        self.assertIn('-parallel-testing-enabled YES', app)
        self.assertIn('-parallel-testing-worker-count 2', app)
        self.assertIn('test || composer_status=$?', app)
        self.assertIn('collect_ui_clones || return $?', app)
        self.assertIn('cleanup_runtime "$clone_udid" || return 2', app)
        self.assertLess(app.index('test || composer_status=$?'), app.index('cleanup_runtime "$clone_udid"'))
        gallery = source.split('for widget_scenario in normal long-white-large no-caption; do', 1)[1]
        self.assertIn('-parallel-testing-enabled NO', gallery)
        self.assertNotIn('-parallel-testing-enabled YES', gallery)
        self.assertIn('if [[ "$widget_scenario" != normal ]]; then', gallery)
        self.assertIn('return "$composer_status"', gallery)


if __name__ == "__main__":
    unittest.main()
