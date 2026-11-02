#!/usr/bin/env python3
"""Regression tests for the DEBUG runtime marker validator."""

from __future__ import annotations

import json
import re
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate-sharing-runtime-self-test.py")
RENDERER = "cat-aware-full-bleed-v6"
CASES = {
    "managed-preservation-pilot-boundary",
    "managed-preservation-membership-boundary",
    "managed-preservation-export-boundary",
    "canonical-local-only-privacy-budget",
    "daily-store-cas-highwater-anchor",
    "diagnostic-persistence-privacy",
    "disabled-upgrade-purge",
    "legacy-store-lease-exclusion",
    "legacy-widget-cache-migration",
    "moment-report-only-terminal-gate",
    "moment-saved-memory-boundary",
    "moment-sent-delivery-receipt-boundary",
    "moment-paw-reaction-boundary",
    "moment-imported-memory-boundary",
    "retained-widget-publication",
    "moment-inbound-moderation-retry-policy",
    "moderation-dual-key-configuration",
    "moment-commit-ack-metadata",
    "moment-build61-schema7-migration",
    "moment-outbox-bounds-and-expiry",
    "moment-outcome-ledger-migration",
    "moment-report-outbox-bounds-and-recovery",
    "moment-block-withdrawal-lifecycle",
    "normalizer-orientation-scale-parity",
    "partial-download-resume-tamper",
    "pairing-bootstrap-transient-preservation",
    "private-window-catalog-authority-uniqueness",
    "private-window-catalog-protected-storage-migration",
    "private-window-legacy-conflict-quarantine-policy",
    "peer-revoke-terminal-purge",
    "secure-file-attributes",
}


def report() -> dict:
    return {
        "schemaVersion": 1,
        "rendererVersion": RENDERER,
        "status": "passed",
        "cases": [
            {"id": identifier, "status": "passed"}
            for identifier in sorted(CASES)
        ],
    }


class SharingRuntimeSelfTestValidatorTests(unittest.TestCase):
    def validate(self, value: dict) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            return subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(path),
                    "--renderer-version",
                    RENDERER,
                ],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_complete_privacy_safe_marker_passes(self) -> None:
        result = self.validate(report())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_validator_cases_match_runtime_runner(self) -> None:
        runner = (
            SCRIPT.parent.parent
            / "NekoWidget"
            / "Services"
            / "SharingRuntimeSelfTest.swift"
        ).read_text(encoding="utf-8")
        runtime_cases = set(
            re.findall(
                r'results\.append\((?:await )?(?:run|runAsync)\("([^"]+)"\)',
                runner,
            )
        )
        self.assertEqual(runtime_cases, CASES)

    def test_fixed_assertion_inventory_matches_literal_debug_instrumentation(self) -> None:
        allowed = runpy.run_path(str(SCRIPT))["ASSERTION_IDS"]
        runner = (SCRIPT.parent.parent / "NekoWidget/Services/SharingRuntimeSelfTest.swift").read_text(encoding="utf-8")
        identifiers = re.findall(r'throw SharingRuntimeSelfTestRunner.recordAssertionFailure\("([A-Z0-9-]+)",', runner)
        self.assertEqual(len(identifiers), 162)
        self.assertEqual(len(set(identifiers)), 162)
        boundaries = re.findall(r'operationID = "(RWP-OP-[0-9]+)"', runner)
        self.assertEqual(len(boundaries), 27)
        self.assertEqual(len(set(boundaries)), 27)
        identifiers += boundaries
        # Keep the one-shot precision diagnosis readable after its confirmed fix.
        self.assertEqual(set(identifiers) | {"DUP-RS-007-PRECISION"}, set().union(*allowed.values()))
        self.assertEqual(set(allowed), {"disabled-upgrade-purge", "managed-preservation-membership-boundary", "retained-widget-publication"})

    def test_fixed_failure_assertion_is_safely_copied_without_passing_case(self) -> None:
        for identifier, assertion in (("disabled-upgrade-purge", "DUP-001"),
                                      ("managed-preservation-membership-boundary", "MPM-SESSION-001"),
                                      ("retained-widget-publication", "RWP-001"),
                                      ("retained-widget-publication", "unclassified-operation-error")):
            with self.subTest(identifier=identifier, assertion=assertion), tempfile.TemporaryDirectory() as directory:
                value = report(); value["status"] = "failed"
                row = next(item for item in value["cases"] if item["id"] == identifier)
                row.update(status="failed", failedAssertionID=assertion)
                source = Path(directory) / "source.json"; safe_copy = Path(directory) / "safe.json"
                source.write_text(json.dumps(value), encoding="utf-8")
                result = subprocess.run([sys.executable, str(SCRIPT), str(source), "--renderer-version", RENDERER,
                                         "--safe-copy", str(safe_copy)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("did not pass", result.stderr)
                self.assertEqual(json.loads(safe_copy.read_text(encoding="utf-8")), value)

    def test_assertion_fields_reject_other_cases_success_and_unlisted_data(self) -> None:
        for identifier, status, assertion in (("secure-file-attributes", "failed", "DUP-001"),
                                               ("disabled-upgrade-purge", "passed", "DUP-001"),
                                               ("disabled-upgrade-purge", "failed", "RWP-001"),
                                               ("disabled-upgrade-purge", "failed", "DUP-999"),
                                               ("disabled-upgrade-purge", "failed", "/private/photo/key"),
                                               ("disabled-upgrade-purge", "failed", None)):
            with self.subTest(identifier=identifier, status=status, assertion=assertion):
                value = report()
                next(item for item in value["cases"] if item["id"] == identifier).update(status=status, failedAssertionID=assertion)
                result = self.validate(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid fixed assertion", result.stderr)

    def test_missing_case_fails(self) -> None:
        value = report()
        value["cases"].pop()
        result = self.validate(value)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing cases", result.stderr)

    def test_arbitrary_diagnostic_text_is_rejected(self) -> None:
        value = report()
        value["cases"][0]["detail"] = "PhotoKit/local/identifier"
        result = self.validate(value)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected schema", result.stderr)

    def test_failed_fixed_schema_is_copied_before_failure(self) -> None:
        value = report()
        value["status"] = "failed"
        value["cases"][0]["status"] = "failed"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.json"
            safe_copy = root / "artifact.json"
            source.write_text(json.dumps(value), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(source),
                    "--renderer-version",
                    RENDERER,
                    "--safe-copy",
                    str(safe_copy),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(safe_copy.read_text(encoding="utf-8")), value)

    def test_malformed_report_is_never_copied(self) -> None:
        value = report()
        value["cases"][0]["detail"] = "must-not-be-copied"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.json"
            safe_copy = root / "artifact.json"
            source.write_text(json.dumps(value), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(source),
                    "--renderer-version",
                    RENDERER,
                    "--safe-copy",
                    str(safe_copy),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(safe_copy.exists())


if __name__ == "__main__":
    unittest.main()
