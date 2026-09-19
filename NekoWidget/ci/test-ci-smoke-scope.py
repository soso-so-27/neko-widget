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
FULL_TESTS = (BOOTSTRAP, "NekoWidgetUITests/OfficialWindowUITests",
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

    def test_default_and_full_keep_all_twenty_one_tests(self):
        for selected_scope in (None, scope.FULL_SCOPE):
            with self.subTest(scope=selected_scope):
                result, metadata, arguments, heavy = self.run_smoke(selected_scope)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(metadata["scope"], scope.FULL_SCOPE)
                self.assertEqual(metadata["nativeTests"], list(FULL_TESTS))
                self.assertEqual([arg for arg in arguments if arg.startswith("-only-testing:")],
                                 ["-only-testing:" + test for test in FULL_TESTS])
                self.assertIn("test", arguments)
                self.assertFalse(heavy)

    def test_every_targeted_scope_keeps_real_photos_test_and_signed_invocation(self):
        for selected_scope in scope.SCOPES:
            if selected_scope == scope.FULL_SCOPE:
                continue
            with self.subTest(scope=selected_scope):
                result, metadata, arguments, heavy = self.run_smoke(selected_scope)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(metadata["scope"], selected_scope)
                self.assertEqual(metadata["lane"], "smoke")
                self.assertEqual(metadata["nativeTests"], [BOOTSTRAP])
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


if __name__ == "__main__":
    unittest.main()
