#!/usr/bin/env python3
"""Exercise concurrent build/boot joins without Xcode or a Simulator."""

import os
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
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
        start = harness.index("for widget_scenario in $WIDGET_SCENARIOS; do")
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


class DiagnosticSelectionTests(unittest.TestCase):
    """Run the real harness only up to its first mocked Simulator command."""

    METHOD = "testMemoryLibraryEntryReadsEditsAndOpensTheOriginalPhoto"

    @classmethod
    def setUpClass(cls):
        cls.sha = subprocess.check_output(
            ["git", "-C", str(CI), "rev-parse", "HEAD"], text=True).strip()

    def selection(self, *, diagnostic=True, overrides=None):
        self.assertIsNotNone(BASH)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = {k: v for k, v in os.environ.items() if not k.startswith("NEKO_IOS_")}
            env.update({
                "RUNNER_TEMP": root.as_posix(),
                "GITHUB_SHA": self.sha,
                "GITHUB_REPOSITORY": "soso-so-27/neko-widget",
                "GITHUB_REF": "refs/heads/diagnostic/selection-test",
                "GITHUB_EVENT_NAME": "workflow_dispatch",
                "GITHUB_WORKFLOW_REF": "soso-so-27/neko-widget/.github/workflows/ios-ui-diagnostic.yml@refs/heads/diagnostic/selection-test",
                "NEKO_IOS_RUNTIME_SCOPE": "reviewed-memory-read-ui-v2",
                "NEKO_IOS_RUNTIME_LANE": "app-ui",
                "FIXTURE_PYTHON": Path(sys.executable).as_posix(),
            })
            if diagnostic:
                env["NEKO_IOS_DIAGNOSTIC_SOURCE_SHA"] = self.sha
                env["NEKO_IOS_DIAGNOSTIC_TEST_METHOD"] = self.METHOD
            else:
                env["GITHUB_EVENT_NAME"] = "push"
                env["GITHUB_WORKFLOW_REF"] = "soso-so-27/neko-widget/.github/workflows/ios-build.yml@refs/heads/main"
            for key, value in (overrides or {}).items():
                if value is None:
                    env.pop(key, None)
                else:
                    env[key] = value
            result = subprocess.run(
                [BASH, "-c", r'''
python3() { "$FIXTURE_PYTHON" "$@"; }
xcrun() { echo reached-simulator-boundary >&2; return 73; }
export -f python3 xcrun
bash "$1"
''', "diagnostic-selection-test", (CI / "run-sharing-runtime-matrix.sh").as_posix()],
                env=env, capture_output=True, text=True, encoding="utf-8", timeout=20,
            )
            metadata = {p.name: json.loads(p.read_text(encoding="utf-8"))
                        for p in root.glob("*/**/*.json") if p.stat().st_size}
            selection = root / "neko-sharing-runtime-ui-selection.txt"
            return result, metadata, selection.read_text() if selection.exists() else ""

    def test_diagnostic_selects_one_existing_test_without_release_metadata(self):
        result, metadata, selected = self.selection()
        self.assertEqual(result.returncode, 73, result.stderr)
        test = f"NekoWidgetUITests/MomentDeliveryComposerUITests/{self.METHOD}"
        self.assertEqual(selected, f"-only-testing:{test}\n")
        self.assertEqual(set(metadata), {"diagnostic.json"})
        self.assertEqual(metadata["diagnostic.json"]["nativeTests"], [test])
        self.assertTrue(metadata["diagnostic.json"]["diagnosticOnly"])
        self.assertFalse(metadata["diagnostic.json"]["releaseEvidence"])
        self.assertEqual(metadata["diagnostic.json"]["sourceSHA"], self.sha)

    def test_regular_scope_selection_remains_unchanged(self):
        from ios_ci_scope import lane_tests
        result, metadata, selected = self.selection(diagnostic=False)
        self.assertEqual(result.returncode, 73, result.stderr)
        expected = lane_tests("reviewed-memory-read-ui-v2", "app-ui")
        self.assertEqual(selected, "".join(f"-only-testing:{test}\n" for test in expected))
        self.assertGreater(len(expected), 1)
        self.assertEqual(set(metadata), {"runtime-scope.json"})
        self.assertEqual(metadata["runtime-scope.json"]["nativeTests"], list(expected))

    def test_override_rejects_regular_ci_release_and_non_dispatch_routes(self):
        cases = [
            {"GITHUB_WORKFLOW_REF": f"soso-so-27/neko-widget/.github/workflows/{name}@refs/heads/diagnostic/selection-test"}
            for name in ("ios-build.yml", "testflight.yml")
        ] + [{"GITHUB_EVENT_NAME": "push"}, {"GITHUB_REF": "refs/heads/main"},
             {"NEKO_IOS_RUNTIME_LANE": "all"}]
        for overrides in cases:
            with self.subTest(overrides=overrides):
                result, metadata, selected = self.selection(overrides=overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("reached-simulator-boundary", result.stderr)
                self.assertFalse(metadata)
                self.assertEqual(selected, "")

    def test_invalid_missing_or_mismatched_commit_is_rejected_before_simulator(self):
        for overrides in [
            {"NEKO_IOS_DIAGNOSTIC_SOURCE_SHA": "main"},
            {"NEKO_IOS_DIAGNOSTIC_SOURCE_SHA": self.sha + "\n"},
            {"NEKO_IOS_DIAGNOSTIC_SOURCE_SHA": None},
            {"GITHUB_SHA": "0" * 40},
            {"NEKO_IOS_DIAGNOSTIC_SOURCE_SHA": "0" * 40, "GITHUB_SHA": "0" * 40},
        ]:
            with self.subTest(overrides=overrides):
                result, metadata, selected = self.selection(overrides=overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("reached-simulator-boundary", result.stderr)
                self.assertFalse(metadata)
                self.assertEqual(selected, "")

    def test_method_rejects_injection_unknown_and_other_classes(self):
        for method in ("", None, "testMissingDiagnosticMethod", "testGrantFullPhotoLibraryAccess",
                       self.METHOD + "; exit 0", self.METHOD + "\n-only-testing:Other",
                       f"NekoWidgetUITests/MomentDeliveryComposerUITests/{self.METHOD}"):
            with self.subTest(method=method):
                result, metadata, selected = self.selection(
                    overrides={"NEKO_IOS_DIAGNOSTIC_TEST_METHOD": method})
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("reached-simulator-boundary", result.stderr)
                self.assertFalse(metadata)
                self.assertEqual(selected, "")

    def test_workflow_is_manual_same_commit_single_mac_job_with_separate_artifacts(self):
        workflow = (CI.parents[1] / ".github/workflows/ios-ui-diagnostic.yml").read_text()
        self.assertIn("  workflow_dispatch:", workflow)
        self.assertIn("run-name: 'UI diagnosis: ${{ inputs.test_method }}'", workflow)
        self.assertNotRegex(workflow, r"(?m)^  (?:push|pull_request|workflow_call):")
        self.assertEqual(workflow.count("runs-on: macos-15"), 1)
        self.assertIn("timeout-minutes: 30", workflow)
        self.assertIn("ref: ${{ github.sha }}", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("name: ios-ui-diagnostic-${{ github.sha }}", workflow)
        self.assertIn("path: ${{ runner.temp }}/neko-ui-diagnostic", workflow)
        self.assertNotIn("${{ inputs.", workflow.split("run: |", 1)[1])
        # Exercise the actual pre-checkout validation body, not a second parser.
        match = re.search(r"python3 - <<'PY'\n(.*?)\n          PY", workflow, re.S)
        self.assertIsNotNone(match)
        code = "\n".join(line[10:] for line in match[1].splitlines())
        env = {**os.environ, "NEKO_IOS_DIAGNOSTIC_SOURCE_SHA": self.sha,
               "NEKO_IOS_DIAGNOSTIC_TEST_METHOD": self.METHOD, "GITHUB_SHA": self.sha,
               "GITHUB_REF": "refs/heads/diagnostic/selection-test"}
        for source, status in ((self.sha, 0), ("main", 1), ("0" * 40, 1)):
            result = subprocess.run([sys.executable, "-c", code],
                                    env={**env, "NEKO_IOS_DIAGNOSTIC_SOURCE_SHA": source},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, status, result.stderr)

    def test_diagnostic_success_requires_the_requested_test_to_really_run_and_pass(self):
        workflow = (CI.parents[1] / ".github/workflows/ios-ui-diagnostic.yml").read_text()
        body = re.findall(r"python3 - <<'PY'\n(.*?)\n          PY", workflow, re.S)[1]
        code = "\n".join(line[10:] for line in body.splitlines())
        case = f"NekoWidgetUITests.MomentDeliveryComposerUITests {self.METHOD}"
        started = f"Test Case '-[{case}]' started.\n"
        passed = f"Test Case '-[{case}]' passed (1.0 seconds).\n"
        for log, succeeds in ((started + passed, True), ("", False),
                              (started + passed.replace("passed", "skipped"), False),
                              ((started + passed).replace(self.METHOD, "testOther"), False),
                              ((started + passed) * 2, False)):
            with self.subTest(log=log), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "neko-ui-diagnostic"
                root.mkdir()
                (root / "diagnostic.log").write_text(log, encoding="utf-8")
                result = subprocess.run([sys.executable, "-c", code], env={
                    **os.environ, "RUNNER_TEMP": directory, "GITHUB_SHA": self.sha,
                    "NEKO_IOS_DIAGNOSTIC_TEST_METHOD": self.METHOD,
                }, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0 if succeeds else 1, result.stderr)
                self.assertEqual((root / "diagnostic-result.json").exists(), succeeds)


if __name__ == "__main__":
    unittest.main()
