#!/usr/bin/env python3
"""Exercise the real smoke selector and Bash argument handoff without Xcode."""

import json
import os
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
BOOTSTRAP = "NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess"
ACCEPTANCE = "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary"
FULL_TESTS = (BOOTSTRAP, ACCEPTANCE, "NekoWidgetUITests/OfficialWindowUITests",
              "NekoWidgetUITests/PersonalRediscoveryUITests")


class SmokeScopeTests(unittest.TestCase):
    def run_smoke(self, selected_scope=None, empty_selector=False, full_script=False):
        self.assertIsNotNone(BASH, "Bash is required to verify the smoke argument handoff")
        source = (CI / "run-simulator-smoke.sh").read_text(encoding="utf-8")
        # Execute the production initialization and the production xcodebuild
        # call, replacing only the expensive build/Simulator commands.
        prefix = source[:source.index("# `simctl addmedia`")]
        start = source.index("TEST_RUNNER_NEKO_EXPECT_DISABLED_RELEASE=1 xcodebuild")
        command = source[start:source.index('\n\nif [[ -d "$PERMISSION_RESULT_BUNDLE"', start)]
        with tempfile.TemporaryDirectory(prefix="neko smoke scope ") as directory:
            root = Path(directory)
            ci = root / "project" / "ci"
            ci.mkdir(parents=True)
            selector = ci / "ios_ci_scope.py"
            if empty_selector:
                selector.write_text('''import pathlib, sys
pathlib.Path(sys.argv[sys.argv.index("--metadata") + 1]).write_text("{}")
pathlib.Path(sys.argv[sys.argv.index("--tests") + 1]).write_text("\\n\\n")
''', encoding="utf-8")
            else:
                shutil.copyfile(CI / "ios_ci_scope.py", selector)
                shutil.copyfile(CI / "app_icon_ci.py", ci / "app_icon_ci.py")
            script = ci / "run-simulator-smoke.sh"
            if full_script:
                script.write_text(source, encoding="utf-8")
            else:
                script.write_text(prefix + '''
SIMULATOR_UDID=fixture-device
''' + command, encoding="utf-8")
            driver = root / "driver.sh"
            driver.write_text(r'''#!/usr/bin/env bash
set -Eeuo pipefail
python3() { "$NEKO_TEST_PYTHON" "$@"; }
xcodebuild() { printf '%s\0' "$@" > "$RUNNER_TEMP/xcode-arguments"; }
sw_vers() { printf 'unexpected preparation\n' > "$RUNNER_TEMP/heavy-started"; return 91; }
xcrun() { printf 'unexpected Simulator\n' > "$RUNNER_TEMP/heavy-started"; return 92; }
source "$1"
''', encoding="utf-8")
            env = os.environ.copy()
            for key in ("NEKO_IOS_RUNTIME_SCOPE", "SIMULATOR_TEST_MODE", "SIMCTL_ADDMEDIA_TIMEOUT_SECONDS"):
                env.pop(key, None)
            env.update(RUNNER_TEMP=root.as_posix(), NEKO_TEST_PYTHON=Path(sys.executable).as_posix(),
                       SMOKE_IOS_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-18-6",
                       GITHUB_SHA="a" * 40)
            if selected_scope is not None:
                env["NEKO_IOS_RUNTIME_SCOPE"] = selected_scope
            result = subprocess.run([BASH, driver.as_posix(), script.as_posix()],
                                    env=env, capture_output=True, text=True, encoding="utf-8", timeout=20)
            artifacts = root / "neko-smoke-artifacts"
            metadata_path = artifacts / "smoke-scope.json"
            arguments_path = root / "xcode-arguments"
            return (result,
                    json.loads(metadata_path.read_text()) if metadata_path.exists() else None,
                    arguments_path.read_bytes().decode().rstrip("\0").split("\0")
                    if arguments_path.exists() else None,
                    (root / "heavy-started").exists())

    def test_default_and_full_keep_all_selected_tests(self):
        for selected_scope in (None, scope.FULL_SCOPE):
            with self.subTest(scope=selected_scope):
                result, metadata, arguments, heavy = self.run_smoke(selected_scope)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(metadata["scope"], scope.FULL_SCOPE)
                self.assertEqual(metadata["nativeTests"], list(FULL_TESTS))
                self.assertEqual([arg for arg in arguments if arg.startswith("-only-testing:")],
                                 ["-only-testing:" + BOOTSTRAP])
                self.assertIn("test", arguments)
                self.assertFalse(heavy)

    def test_every_targeted_scope_keeps_real_photos_test_and_signed_invocation(self):
        for selected_scope in scope.SCOPES:
            if selected_scope == scope.FULL_SCOPE:
                continue
            with self.subTest(scope=selected_scope):
                result, metadata, arguments, heavy = self.run_smoke(selected_scope)
                expected_tests = FULL_TESTS if selected_scope in (scope.APP_VIEW_SCOPE, scope.APP_DATA_SCOPE) else (BOOTSTRAP, ACCEPTANCE)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(metadata["scope"], selected_scope)
                self.assertEqual(metadata["lane"], "smoke")
                self.assertEqual(metadata["nativeTests"], list(expected_tests))
                self.assertEqual(metadata["sharingRuntime"], [])
                self.assertEqual(metadata["photoBootstrapRuntime"],
                                 "com.apple.CoreSimulator.SimRuntime.iOS-18-6")
                self.assertEqual([arg for arg in arguments if arg.startswith("-only-testing:")],
                                 ["-only-testing:" + BOOTSTRAP])
                self.assertEqual(arguments[arguments.index("-parallel-testing-enabled") + 1], "NO")
                self.assertIn("CODE_SIGNING_ALLOWED=YES", arguments)
                self.assertIn("AD_HOC_CODE_SIGNING_ALLOWED=YES", arguments)
                # The temporary paths contain spaces; quoting must preserve
                # the xcconfig and artifact path as one argument each.
                self.assertTrue(arguments[arguments.index("-xcconfig") + 1].endswith("/Config.Disabled.xcconfig"))
                self.assertIn("neko smoke scope ", arguments[arguments.index("-resultBundlePath") + 1])
                self.assertFalse(heavy)

    def test_unknown_scope_stops_before_any_simulator_or_build(self):
        result, metadata, arguments, heavy = self.run_smoke("unknown-scope", full_script=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid choice", result.stdout + result.stderr)
        self.assertIsNone(metadata)
        self.assertIsNone(arguments)
        self.assertFalse(heavy)

    def test_empty_selection_stops_before_any_simulator_or_build(self):
        result, _, arguments, heavy = self.run_smoke(scope.PHOTO_SCOPE, empty_selector=True, full_script=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not select any native UI tests", result.stdout + result.stderr)
        self.assertIsNone(arguments)
        self.assertFalse(heavy)

    def test_checkpoint_survives_fixture_pruning_and_still_rejects_invalid_permission(self):
        source = (CI / "run-simulator-smoke.sh").read_text(encoding="utf-8")
        prefix = source[:source.index("# `simctl addmedia`")]
        start = source.index("TEST_RUNNER_NEKO_EXPECT_DISABLED_RELEASE=1 xcodebuild")
        phase = source[start:source.index("\narchive_and_reset_permission_bootstrap", start)]
        for mode in ("prune", "duplicate", "revoked"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix="neko checkpoint ") as directory:
                root = Path(directory)
                ci = root / "project/ci"; ci.mkdir(parents=True)
                for name in ("ios_ci_scope.py", "app_icon_ci.py", "validate-photo-permission-bootstrap.py"):
                    shutil.copyfile(CI / name, ci / name)
                logs = root / "group/diagnostic-logs"; logs.mkdir(parents=True)
                filename = "app-1787507348233-22259-4d2db22bf65d.jsonl"
                entries = [dict(process="app", category="permission", message="Photo permission request started",
                                metadata={}, timestamp=10.0),
                           dict(process="app", category="permission", message="Photo permission request finished",
                                metadata={"status": "authorized"}, timestamp=11.0)]
                if mode == "duplicate":
                    entries.append(entries[0])
                original = "".join(json.dumps(entry) + "\n" for entry in entries)
                (logs / filename).write_text(original, encoding="utf-8")
                data = root / "data/Documents/MainlineAcceptance"; data.mkdir(parents=True)
                for name in ("opening.mp4", "opening.png"):
                    (data / name).write_bytes(b"fixture")
                for name, auth in (("tcc-valid.json", 2), ("tcc-revoked.json", 0)):
                    (root / name).write_text(json.dumps(dict(bundleIdentifier="jp.nekowidget.app", rows=[
                        dict(service="kTCCServicePhotos", client="jp.nekowidget.app", auth_value=auth)])), encoding="utf-8")
                script = ci / "run-simulator-smoke.sh"
                script.write_text(prefix + '\nSIMULATOR_UDID=fixture-device\nAPP_BUNDLE_ID=jp.nekowidget.app\n' + phase,
                                  encoding="utf-8")
                driver = root / "driver.sh"
                driver.write_text(r'''set -Eeuo pipefail
python3() { "$NEKO_TEST_PYTHON" "$@"; }
resolve_group_container() { printf '%s\n' "$RUNNER_TEMP/group"; }
capture_tcc_state() {
    local report="$RUNNER_TEMP/tcc-valid.json"
    if [[ "$1" == after-ui-test && "$CHECKPOINT_MODE" == revoked ]]; then
        report="$RUNNER_TEMP/tcc-revoked.json"
    fi
    cp "$report" "$ARTIFACT_DIRECTORY/tcc-$1.json"
}
xcodebuild() {
    local call=1
    if [[ -f "$RUNNER_TEMP/calls" ]]; then call=2; fi
    printf '%s\n' "$call" > "$RUNNER_TEMP/calls"
    printf '%s\0' "$@" > "$RUNNER_TEMP/arguments-$call"
    if (( call == 2 )); then
        test -s "$ARTIFACT_DIRECTORY/permission-evidence/diagnostic-logs/app-1787507348233-22259-4d2db22bf65d.jsonl"
        rm "$RUNNER_TEMP/group/diagnostic-logs/"*.jsonl
        for session in 1 2 3 4; do
            printf '{}\n' > "$RUNNER_TEMP/group/diagnostic-logs/app-178750734900$session-22260-abcd$session.jsonl"
        done
    fi
}
xcrun() {
    if [[ "$1 $2" == 'simctl get_app_container' ]]; then printf '%s\n' "$RUNNER_TEMP/data"; fi
}
launch_app() { return 0; }
wait_for_completed_snapshot() { return 0; }
sleep() { return 0; }
source "$1"
''', encoding="utf-8")
                env = {**os.environ, "RUNNER_TEMP": root.as_posix(), "NEKO_TEST_PYTHON": Path(sys.executable).as_posix(),
                       "CHECKPOINT_MODE": mode, "NEKO_IOS_RUNTIME_SCOPE": scope.FULL_SCOPE}
                result = subprocess.run([BASH, driver.as_posix(), script.as_posix()], env=env,
                                        capture_output=True, text=True, encoding="utf-8", timeout=20)
                if mode == "duplicate":
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("exactly one", result.stdout + result.stderr)
                    self.assertEqual((root / "calls").read_text().strip(), "1")
                    continue
                self.assertEqual((root / "calls").read_text().strip(), "2")
                checkpoint = root / "neko-smoke-artifacts/permission-evidence/diagnostic-logs" / filename
                self.assertEqual(checkpoint.read_text(encoding="utf-8"), original)
                self.assertFalse((logs / filename).exists(), "Regression must actually prune the source evidence")
                first = (root / "arguments-1").read_bytes().decode().split("\0")
                second = (root / "arguments-2").read_bytes().decode().split("\0")
                self.assertEqual([arg for arg in first if arg.startswith("-only-testing:")], ["-only-testing:" + BOOTSTRAP])
                self.assertEqual([arg for arg in second if arg.startswith("-only-testing:")],
                                 ["-only-testing:" + name for name in FULL_TESTS[1:]])
                self.assertIn("test-without-building", second)
                self.assertEqual(result.returncode, 0 if mode == "prune" else 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout.count("PASS Photos permission bootstrap:"), 2 if mode == "prune" else 1)


if __name__ == "__main__":
    unittest.main()
