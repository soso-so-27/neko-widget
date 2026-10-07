#!/usr/bin/env python3
"""Check bounded artifact export preserves failure and actual timing evidence."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

CI = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("recorded", CI / "run-recorded-command.py")
recorded = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorded)


class RecordedCommandTests(unittest.TestCase):
    def test_success_failure_and_timeout_are_distinct(self):
        for code, timeout, expected in (("pass", None, 0),
                                        ("raise SystemExit(65)", None, 65),
                                        ("import time; time.sleep(30)", 0.1, 124)):
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                record = Path(directory) / "timing.json"
                self.assertEqual(recorded.run([sys.executable, "-c", code], record, timeout), expected)
                report = json.loads(record.read_text(encoding="utf-8"))
                self.assertEqual(report["exitCode"], expected)
                self.assertEqual(report["timedOut"], expected == 124)
                self.assertGreaterEqual(report["elapsedSeconds"], 0)
                self.assertLessEqual(report["startedAt"], report["completedAt"])
                self.assertNotIn("command", report)

    def test_missing_command_creates_nested_failure_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            record = Path(directory) / "new" / "timing.json"
            self.assertEqual(recorded.run([str(Path(directory) / "missing-command")], record), 127)
            report = json.loads(record.read_text())
            self.assertEqual(report["exitCode"], 127)
            self.assertEqual(report["state"], "completed")

    def test_external_interruption_keeps_nonzero_status_and_restores_handlers(self):
        original = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
        with tempfile.TemporaryDirectory() as directory, patch.object(recorded.subprocess, "Popen") as start:
            process = start.return_value
            process.wait.side_effect = [recorded.Interrupted(signal.SIGTERM), 0]
            process.poll.return_value = None
            with patch.object(recorded, "stop") as stop:
                record = Path(directory) / "timing.json"
                self.assertEqual(recorded.run(["fixture"], record), 143)
                stop.assert_called_once_with(process)
            report = json.loads(record.read_text())
            self.assertEqual(report["interruptedSignal"], signal.SIGTERM)
            self.assertFalse(report["timedOut"])
        self.assertEqual({sig: signal.getsignal(sig) for sig in original}, original)

    @unittest.skipUnless(os.name == "posix", "Real runner signal delivery requires POSIX")
    def test_runner_sigterm_writes_completion_and_stops_child(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record, ready, child_pid = root / "timing.json", root / "ready", root / "child-pid"
            child = ("import os,time; from pathlib import Path; "
                     f"Path({str(child_pid)!r}).write_text(str(os.getpid())); "
                     f"Path({str(ready)!r}).touch(); time.sleep(60)")
            process = subprocess.Popen([sys.executable, str(CI / "run-recorded-command.py"),
                "--record", str(record), "--", sys.executable, "-c", child])
            try:
                deadline = time.monotonic() + 10
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(ready.exists())
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=10), 143)
                self.assertEqual(json.loads(record.read_text())["exitCode"], 143)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(child_pid.read_text()), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

    def test_workflow_reserves_upload_and_keeps_missing_evidence_fatal(self):
        workflow = (CI.parents[1] / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
        ui = workflow.split("  sharing-app-ui:\n", 1)[1].split("  sharing-runtime-matrix:\n", 1)[0]
        self.assertIn("timeout-minutes: 90", ui)
        self.assertIn("timeout-minutes: 80", ui)
        self.assertIn("compression-level: 0", ui)
        self.assertIn("if-no-files-found: error", ui)
        script = (CI / "run-sharing-runtime-matrix.sh").read_text(encoding="utf-8")
        self.assertIn("composer_status == 0 && composer_export_status != 0", script)
        self.assertIn("widget_scenario_status == 0 && attachment_status != 0", script)
        self.assertEqual(script.count("--timeout 180 -- xcrun xcresulttool export attachments"), 2)


if __name__ == "__main__":
    unittest.main()
