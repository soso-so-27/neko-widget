#!/usr/bin/env python3
"""Check bounded artifact export preserves failure and actual timing evidence."""

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

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
