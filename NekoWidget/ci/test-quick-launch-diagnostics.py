import json
import importlib.util
import itertools
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import quick_launch_diagnostics as diagnostic
import production_candidate as candidate

ROOT = Path(__file__).resolve().parents[1]
DEVICE = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"


class QuickLaunchDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def app(self):
        # Existing synthetic product fixture, never an installed data container.
        fixture = candidate.module("test-production-candidate").ProductionCandidateTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        for relative, _, _ in candidate.TARGETS.values():
            path = fixture.app / relative / "Info.plist"
            info = plistlib.loads(path.read_bytes())
            info["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
            path.write_bytes(plistlib.dumps(info))
        executable = fixture.app / "NekoWidget"
        executable.write_bytes(b"synthetic-mach-o-bytes\x00\x01\x02")
        executable.chmod(0o755)
        return fixture.app

    def test_archive_preserves_executable_bytes_modes_and_all_products(self):
        app = self.app()
        output = self.root / "app.tar.gz"
        diagnostic.archive_candidate(app, candidate.fixture(), output)
        with tarfile.open(output) as archive:
            name = "NekoWidget.app/NekoWidget"
            self.assertEqual(archive.extractfile(name).read(), (app / "NekoWidget").read_bytes())
            self.assertEqual(archive.getmember(name).mode, stat.S_IMODE((app / "NekoWidget").stat().st_mode))
            for relative, _, _ in candidate.TARGETS.values():
                name = "NekoWidget.app/" + ((relative + "/") if relative else "") + "Info.plist"
                self.assertEqual(archive.extractfile(name).read(), (app / relative / "Info.plist").read_bytes())

    def test_non_synthetic_and_device_products_cannot_be_retained(self):
        app = self.app()
        contract = candidate.fixture(); contract["synthetic"] = False
        with self.assertRaises(ValueError): diagnostic.archive_candidate(app, contract, self.root / "bad.tar.gz")
        info = plistlib.loads((app / "Info.plist").read_bytes())
        info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        with self.assertRaises(ValueError): diagnostic.archive_candidate(app, candidate.fixture(), self.root / "bad.tar.gz")

    def test_private_keys_receipts_and_runtime_containers_are_rejected(self):
        app = self.app()
        for name in ("AuthKey.p8", "private.pem", "embedded.mobileprovision", "_MASReceipt/receipt", "Documents/photo.heic", "Library/Keychains/keychain.db"):
            path = app / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text("private-sentinel")
            with self.subTest(name=name), self.assertRaises(ValueError):
                diagnostic.archive_candidate(app, candidate.fixture(), self.root / "bad.tar.gz")
            path.unlink()
            while path.parent != app:
                path = path.parent; path.rmdir()
        self.assertFalse((self.root / "bad.tar.gz").exists())

    def test_simctl_snapshot_excludes_names_paths_and_other_devices(self):
        raw = {"devices": {RUNTIME: [
            {"udid": DEVICE, "name": "private-person-name", "state": "Booted", "isAvailable": True,
             "dataPath": "/private/photos", "logPath": "/private/receipt"},
            {"udid": "other-user-device", "name": "private-name", "state": "Booted"}]}}
        with patch.object(diagnostic, "command", return_value=(json.dumps(raw), "ok")):
            diagnostic.snapshot(self.root, DEVICE, "before-launch")
        text = (self.root / "simctl-list-before-launch.json").read_text()
        self.assertNotIn("private", text); self.assertNotIn("other-user", text)
        self.assertEqual(json.loads(text)["devices"], [{"udid": DEVICE, "runtime": RUNTIME, "state": "Booted", "available": True}])

    def test_springboard_log_is_classified_without_free_text_or_credentials(self):
        message = 'jp.nekowidget.app launch failed FBSOpenApplicationServiceErrorDomain Code=1 /private/photo.heic https://secret.test/key?token=SECRET receipt=SECRET'
        events = diagnostic.springboard_events([
            {"processImagePath": "/System/Library/SpringBoard", "eventMessage": message,
             "timestamp": "2026-11-02 01:00:00.000+0900", "messageType": "Error", "category": "SECRET"},
            {"processImagePath": "/app/NekoWidget", "eventMessage": message},
            {"processImagePath": "/System/SpringBoard", "eventMessage": "another.app SECRET"}])
        self.assertEqual(len(events), 1)
        text = json.dumps(events)
        for value in ("SECRET", "/private", "https://", "receipt", "eventMessage"):
            self.assertNotIn(value, text)
        self.assertEqual(events[0]["errorCodes"], ["1"])
        self.assertEqual(events[0]["errorDomains"], ["FBSOpenApplicationServiceErrorDomain"])

    def test_minimal_collection_tolerates_hung_simulator_without_raw_logs(self):
        app = self.app(); output = self.root / "failure"; snapshots = self.root / "snapshots"
        with patch.object(diagnostic, "command", return_value=(None, "diagnostic-timeout")):
            diagnostic.snapshot(snapshots, DEVICE, "before-launch")
            diagnostic.snapshot(snapshots, DEVICE, "after-launch")
            diagnostic.collect(output, snapshots, DEVICE, app, candidate.fixture(), 124)
        self.assertEqual({p.name for p in output.iterdir()}, {"README.txt", "synthetic-simulator-app.tar.gz", "simctl-list-before-launch.json", "simctl-list-after-launch.json"})
        self.assertIn("exit status: 124", (output / "README.txt").read_text())
        self.assertIn("diagnostic-timeout", (output / "README.txt").read_text())
        with self.assertRaises(ValueError): diagnostic.collect(self.root / "success", snapshots, DEVICE, app, candidate.fixture(), 0)

    def test_only_known_simulator_process_names_and_numeric_states_are_retained(self):
        rows = diagnostic.process_states(" 123 Ss /System/Library/SpringBoard\n 456 S /Users/private/Keychain\n789 S /path/com.apple.CoreSimulator.CoreSimulatorService\n")
        self.assertEqual([r["process"] for r in rows], ["SpringBoard", "com.apple.CoreSimulator.CoreSimulatorService"])
        self.assertNotIn("/", json.dumps(rows))

    def test_app_pid_is_scoped_to_exact_disposable_device_and_executable(self):
        path = f"/Users/runner/Library/Developer/CoreSimulator/Devices/{DEVICE}/data/Containers/Bundle/Application/{DEVICE}/NekoWidget.app/NekoWidget"
        rows = diagnostic.app_processes(f"12 S {path}\n13 S {path}-other\n14 S /Applications/NekoWidget.app/NekoWidget\n15 S {path.replace(DEVICE, 'FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE', 1)}", DEVICE)
        self.assertEqual(rows, [{"pid": 12, "state": "S", "process": "NekoWidget"}])

    def test_failure_observation_samples_app_without_simctl_and_classifies_runningboard(self):
        path = f"/Library/Developer/CoreSimulator/Devices/{DEVICE}/data/Containers/Bundle/Application/{DEVICE}/NekoWidget.app/NekoWidget"
        def run(args, **kwargs):
            if args[0] == "ps": return f"12 S {path}", "ok"
            if args[0] == "sample":
                self.assertEqual(args[1:4], ["12", "1", "1"])
                return "Path: /private/SECRET\nBinary Images: SECRET\n  + 3 mach_msg2_trap (in libsystem_kernel.dylib) + 8 [0x123abc]\n  3 helper (in NekoWidget) /private/SECRET.swift\n", "ok"
            return json.dumps([{"processImagePath": "/usr/libexec/runningboardd", "eventMessage": "jp.nekowidget.app NotFound RBSRequestErrorDomain Code=3 SECRET"}]), "ok"
        with patch.object(diagnostic, "command", side_effect=run):
            diagnostic.observe(self.root, DEVICE)
        value = json.loads((self.root / "app-state.json").read_text())
        self.assertEqual(value["appPresence"], "present")
        self.assertIn("mach_msg2_trap", str(value))
        self.assertNotIn("SECRET", str(value))
        events = json.loads((self.root / "lifecycle.json").read_text())["events"]
        self.assertEqual(events[0]["process"], "runningboardd")
        self.assertIn("notfound", events[0]["terms"])
        self.assertEqual(events[0]["errorCodes"], ["3"])

    def test_unavailable_process_query_is_unknown_not_absent(self):
        with patch.object(diagnostic, "command", return_value=(None, "diagnostic-timeout")):
            diagnostic.observe(self.root, DEVICE)
        self.assertEqual(json.loads((self.root / "app-state.json").read_text())["appPresence"], "unknown")

    def test_build_precedes_fresh_device_and_time_limits_remain(self):
        script = (ROOT / "ci/run-quick-ios-checks.sh").read_text()
        self.assertNotIn('simctl create', script)
        self.assertIn('public-build', script)
        script = (ROOT / 'ci/run-quick-launch.sh').read_text()
        self.assertNotIn('xcodebuild', script)
        self.assertIn('bounded 90 xcrun simctl launch', script)
        self.assertIn('sleep 5', script)
        unit = (ROOT / "ci/run-native-test-layer.sh").read_text()
        self.assertLess(unit.index('build-for-testing'), unit.index('simctl create'))
        self.assertIn('timeout=120', unit)
        self.assertIn('xcodebuild test-without-building', unit)

    def test_unit_shell_compiles_before_boot_and_preserves_failed_test_status(self):
        script = (ROOT / "ci/run-native-test-layer.sh").read_text()
        script = script.replace('cd "$(dirname "$0")/.."', ':')
        bash = "C:/Program Files/Git/bin/bash.exe" if Path("C:/Program Files/Git/bin/bash.exe").exists() else shutil.which("bash")
        for scenario, code in (("success", 0), ("test-failure", 37), ("boot-failure", 124)):
            with self.subTest(scenario=scenario):
                directory = self.root / scenario; directory.mkdir()
                preamble = r'''
RUNNER_TEMP="$PWD"
GITHUB_OUTPUT="$PWD/outputs"
xcrun() { echo "xcrun $*" >> trace; if [[ "$*" == *"create"* ]]; then echo AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE; fi; }
python3() {
  echo "python3 $*" >> trace
  if [[ "$1" == -c ]]; then echo com.apple.CoreSimulator.SimRuntime.iOS-26-2
  elif [[ "$1" == - && "$scenario" == boot-failure ]]; then return 124; fi
}
xcodebuild() {
  echo "xcodebuild $*" >> trace
  if [[ "$*" == *build-for-testing* ]]; then mkdir -p "$RUNNER_TEMP/Native-unit-0/Build/Products"; touch "$RUNNER_TEMP/Native-unit-0/Build/Products/tests.xctestrun"; fi
  if [[ "$*" == *test-without-building* && "$scenario" == test-failure ]]; then return 37; fi
}
'''
                (directory / "case.sh").write_text(preamble + f"\nscenario={scenario}\n" + script, encoding="utf-8", newline="\n")
                result = subprocess.run([bash, "case.sh", "unit"], cwd=directory, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, code, result.stderr)
                trace = (directory / "trace").read_text()
                self.assertLess(trace.index("build-for-testing"), trace.index("simctl create"))
                self.assertIn("simctl delete", trace)
                if code:
                    self.assertLess(trace.index(" observe "), trace.index("simctl shutdown"))
                if scenario != "boot-failure":
                    self.assertIn("-only-testing:NekoWidgetTests", trace)
                    self.assertEqual(trace.count("test-without-building"), 1)

    def test_workflow_only_classifies_explicit_first_install_timeout(self):
        workflow = (ROOT.parent / ".github/workflows/quick-launch-attempt.yml").read_text(encoding="utf-8")
        body = workflow.split("        run: |\n", 1)[1].split("      - name: Attach", 1)[0]
        body = "\n".join(line[10:] for line in body.splitlines()).replace("${{ inputs.attempt }}", "1")
        bash = "C:/Program Files/Git/bin/bash.exe" if Path("C:/Program Files/Git/bin/bash.exe").exists() else shutil.which("bash")
        for status, marker, expected in ((0, False, "passed"), (124, True, "install_timeout"), (124, False, "failed"), (37, True, "failed"), (1, False, "failed")):
            with self.subTest(status=status, marker=marker):
                directory = self.root / f"wrapper-{status}-{marker}"; directory.mkdir()
                preamble = r'''set -euo pipefail
RUNNER_TEMP="$PWD"
RUNNER_NAME=synthetic
GITHUB_OUTPUT="$PWD/outputs"
GITHUB_STEP_SUMMARY="$PWD/summary"
touch "$GITHUB_OUTPUT"
export RUNNER_TEMP RUNNER_NAME GITHUB_OUTPUT GITHUB_STEP_SUMMARY
tar() { :; }
bash() {
  if [[ "$marker" == True ]]; then echo install_timeout=true >> "$GITHUB_OUTPUT"; fi
  return "$status"
}
'''
                (directory / "case.sh").write_text(preamble + f"\nstatus={status}\nmarker={marker}\n" + body, encoding="utf-8", newline="\n")
                result = subprocess.run([bash, "case.sh"], cwd=directory, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0 if expected != "failed" else status, result.stderr)
                self.assertIn(f"result={expected}", (directory / "outputs").read_text())
                self.assertIn("Fresh Mac attempt 1", (directory / "summary").read_text())

    def test_fresh_mac_gate_requires_successful_sequential_attempt(self):
        spec = importlib.util.spec_from_file_location("launch_gate", ROOT / "ci/check-fresh-launch-result.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        states = {
            "passed": {"result": "success", "outputs": {"result": "passed"}},
            "timeout": {"result": "success", "outputs": {"result": "install_timeout"}},
            "failed": {"result": "failure"},
            "cancelled": {"result": "cancelled"},
            "skipped": {"result": "skipped"},
            "missing": {"result": "success", "outputs": {}},
        }
        accepted = {("passed", "skipped", "skipped"), ("timeout", "passed", "skipped"), ("timeout", "timeout", "passed")}
        for values in itertools.product(states, repeat=3):
            needs = {"quick-check": {"result": "success"}}
            needs.update({f"launch-attempt-{n}": states[value] for n, value in enumerate(values, 1)})
            self.assertEqual(gate.passed(needs), values in accepted, values)
            needs["quick-check"]["result"] = "failure"
            self.assertFalse(gate.passed(needs), values)

    def test_real_shell_failure_path_preserves_status_retry_limit_and_cleanup_order(self):
        script = (ROOT / "ci/run-quick-launch.sh").read_text(encoding="utf-8")
        setup = script.split("quick_launch_active=false", 1)[1].split('bounded 60 xcrun simctl boot "$device"', 1)[0]
        setup = "quick_launch_active=false" + setup
        launch = script.split("reboot_simulator() {", 1)[1].split('mkdir -p "$RUNNER_TEMP/ci-screenshots"', 1)[0]
        launch = "reboot_simulator() {" + launch
        bash = shutil.which("bash") if not Path("C:/Program Files/Git/bin/bash.exe").exists() else "C:/Program Files/Git/bin/bash.exe"
        self.assertIsNotNone(bash)
        for scenario, expected_status, expected_launches in (("error", 37, 1), ("timeout", 124, 2), ("recovered", 0, 2), ("alive-failed", 1, 1), ("install-timeout", 124, 0), ("install-error", 37, 0)):
            with self.subTest(scenario=scenario):
                directory = self.root / scenario; directory.mkdir()
                preamble = r'''set -euo pipefail
device=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
bundle=jp.nekowidget.app
app=NekoWidget.app
RUNNER_TEMP="$PWD"
GITHUB_OUTPUT="$PWD/outputs"
python3() { echo "diagnostic $*" >> trace; if [[ "$*" == *" collect "* ]]; then return 42; fi; }
sleep() { :; }
xcrun() { echo "xcrun $*" >> trace; if [[ "$*" == *"launchctl list"* && "$scenario" != alive-failed ]]; then echo "1234 0 jp.nekowidget.app"; fi; }
bounded() {
  echo "bounded $*" >> trace
  if [[ "$*" == *"simctl install"* && "$scenario" == install-timeout ]]; then return 124; fi
  if [[ "$*" == *"simctl install"* && "$scenario" == install-error ]]; then return 37; fi
  if [[ "$*" == *"simctl launch"* ]]; then
    count=0; if [[ -f count ]]; then read -r count < count; fi
    count=$((count+1)); echo "$count" > count
    if [[ "$scenario" == error ]]; then return 37; fi
    if [[ "$scenario" == timeout || ( "$scenario" == recovered && "$count" == 1 ) ]]; then return 124; fi
    echo "jp.nekowidget.app: 1234"
  elif [[ "$*" == *" collect "* ]]; then
    python3 "$@"
  fi
}
'''
                path = directory / "case.sh"
                path.write_text(preamble + f"\nscenario={scenario}\n" + setup + "\nquick_launch_active=true\n" + launch, encoding="utf-8", newline="\n")
                result = subprocess.run([bash, "case.sh"], cwd=directory, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, expected_status, result.stderr)
                trace = (directory / "trace").read_text()
                self.assertEqual(trace.count("bounded 90 xcrun simctl launch"), expected_launches)
                self.assertIn("xcrun simctl delete", trace)
                output = directory / "outputs"
                self.assertEqual(output.exists(), scenario == "install-timeout")
                if output.exists():
                    self.assertEqual(output.read_text().strip(), "install_timeout=true")
                    self.assertEqual(trace.count("bounded 90 xcrun simctl install"), 1)
                    self.assertNotIn("bounded 30 xcrun simctl shutdown", trace)
                if expected_status:
                    self.assertIn(f"--exit-status {expected_status}", trace)
                    self.assertLess(trace.index(" collect "), trace.index("xcrun simctl delete"))
                else:
                    self.assertNotIn(" collect ", trace)
                if scenario in ("timeout", "recovered"):
                    self.assertLess(trace.index("first-launch-failure"), trace.index("bounded 30 xcrun simctl shutdown"))


if __name__ == "__main__":
    unittest.main()
