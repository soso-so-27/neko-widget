#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import re
import tempfile
import unittest
from pathlib import Path


CI_DIRECTORY = Path(__file__).resolve().parent
VALIDATOR_PATH = CI_DIRECTORY / "validate-photo-permission-bootstrap.py"
SPEC = importlib.util.spec_from_file_location("photo_permission_validator", VALIDATOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Unable to load Photos permission validator.")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PhotoPermissionBootstrapTests(unittest.TestCase):
    bundle_identifier = "jp.nekowidget.app"

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.tcc_report = self.root / "tcc.json"
        self.log_directory = self.root / "diagnostic-logs"
        self.log_directory.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_tcc(self, *, auth_value: int = 2, rows: list[dict] | None = None) -> None:
        if rows is None:
            rows = [
                {
                    "service": "kTCCServicePhotos",
                    "client": self.bundle_identifier,
                    "auth_value": auth_value,
                }
            ]
        self.tcc_report.write_text(
            json.dumps({"bundleIdentifier": self.bundle_identifier, "rows": rows}),
            encoding="utf-8",
        )

    def app_log_path(self) -> Path:
        return self.log_directory / "app-1787507348233-22259-4d2db22bf65d.jsonl"

    def write_events(self, *, finish_status: str | None = "authorized") -> None:
        entries = [
            {
                "process": "app",
                "category": "permission",
                "message": "Photo permission request started",
                "metadata": {},
                "timestamp": 10.0,
            }
        ]
        if finish_status is not None:
            entries.append(
                {
                    "process": "app",
                    "category": "permission",
                    "message": "Photo permission request finished",
                    "metadata": {"status": finish_status},
                    "timestamp": 11.0,
                }
            )
        self.app_log_path().write_text(
            "".join(json.dumps(entry) + "\n" for entry in entries),
            encoding="utf-8",
        )

    def validate(self) -> dict:
        return MODULE.validate_permission_bootstrap(
            self.tcc_report,
            self.log_directory,
            self.bundle_identifier,
        )

    def test_accepts_full_access_with_terminal_authorized_event(self) -> None:
        self.write_tcc()
        self.write_events()
        summary = self.validate()
        self.assertEqual(summary["photosAuthValue"], 2)
        self.assertEqual(summary["requestFinishedStatus"], "authorized")

    def test_rejects_missing_or_non_full_tcc_state(self) -> None:
        self.write_events()
        for rows in ([], [{"service": "kTCCServicePhotos", "client": self.bundle_identifier, "auth_value": 0}]):
            with self.subTest(rows=rows):
                self.write_tcc(rows=rows)
                with self.assertRaises(ValueError):
                    self.validate()

    def test_rejects_limited_denied_or_unfinished_requests(self) -> None:
        self.write_tcc()
        for status in ("limited", "denied", None):
            with self.subTest(status=status):
                self.write_events(finish_status=status)
                with self.assertRaises(ValueError):
                    self.validate()

    def test_rejects_contradictory_or_reordered_terminal_events(self) -> None:
        self.write_tcc()
        self.write_events()
        path = self.app_log_path()
        entries = [json.loads(line) for line in path.read_text().splitlines()]
        entries.append({**entries[-1], "metadata": {"status": "denied"}, "timestamp": 12.0})
        path.write_text("".join(json.dumps(entry) + "\n" for entry in entries))
        with self.assertRaises(ValueError):
            self.validate()

        entries = entries[:2]
        entries[-1]["timestamp"] = 9.0
        path.write_text("".join(json.dumps(entry) + "\n" for entry in entries))
        with self.assertRaises(ValueError):
            self.validate()

    def test_tolerates_only_one_interrupted_final_app_append(self) -> None:
        self.write_tcc()
        self.write_events()
        path = self.app_log_path()
        path.write_text(path.read_text(encoding="utf-8") + '{"process":"app"', encoding="utf-8")
        self.validate()

        path.write_text(path.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            self.validate()

    def test_ignores_widget_and_unrecognized_streams(self) -> None:
        self.write_tcc()
        self.write_events()
        (self.log_directory / "widget-1787507348233-22259-4d2db22bf65d.jsonl").write_text(
            "malformed widget stream\n", encoding="utf-8"
        )
        (self.log_directory / "app.jsonl").write_text(
            "malformed unrecognized stream\n", encoding="utf-8"
        )
        for name in (
            "app-1_0-22259-4d2db22bf65d.jsonl",
            "app-１０-22259-4d2db22bf65d.jsonl",
            "app-10-+2_2-4d2db22bf65d.jsonl",
        ):
            (self.log_directory / name).write_text(
                "malformed non-Swift integer stream\n", encoding="utf-8"
            )
        self.validate()

        self.app_log_path().unlink()
        with self.assertRaisesRegex(ValueError, "No recognized app"):
            self.validate()

    def test_rejects_non_finite_event_timestamps(self) -> None:
        self.write_tcc()
        for timestamp in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(timestamp=timestamp):
                self.write_events()
                path = self.app_log_path()
                entries = [json.loads(line) for line in path.read_text().splitlines()]
                entries[-1]["timestamp"] = timestamp
                path.write_text(
                    "".join(json.dumps(entry) + "\n" for entry in entries),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(ValueError, "event order"):
                    self.validate()

    def test_rejects_legacy_pre_privacy_wording(self) -> None:
        self.write_tcc()
        self.write_events()
        path = self.app_log_path()
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "Photo permission request", "Photo authorization request"
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(ValueError, "request start"):
            self.validate()

    def test_ci_contract_keeps_real_ui_and_terminal_gate(self) -> None:
        project = CI_DIRECTORY.parent
        ui_test = (project / "NekoWidgetUITests" / "PhotoPermissionUITests.swift").read_text(
            encoding="utf-8"
        )
        harness = (CI_DIRECTORY / "run-simulator-smoke.sh").read_text(encoding="utf-8")
        self.assertIn("permissionAlert.waitForExistence(timeout: 60)", ui_test)
        self.assertIn("executionTimeAllowance = 240", ui_test)
        self.assertIn("Allow Full Access", ui_test)
        self.assertIn("フルアクセスを許可", ui_test)
        self.assertIn("-parallel-testing-enabled NO", harness)
        self.assertIn("validate-photo-permission-bootstrap.py", harness)
        self.assertIsNone(
            re.search(r"(?m)^\s*xcrun\s+simctl\s+privacy\s+grant\b", harness),
            "The smoke test must not bypass the real system permission prompt.",
        )


if __name__ == "__main__":
    unittest.main()
