#!/usr/bin/env python3
"""Regression tests for the DEBUG runtime marker validator."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate-sharing-runtime-self-test.py")
RENDERER = "cat-aware-full-bleed-v6"
CASES = {
    "canonical-local-only-privacy-budget",
    "daily-store-cas-highwater-anchor",
    "day-boundary-convergence",
    "diagnostic-persistence-privacy",
    "disabled-upgrade-purge",
    "lease-heartbeat",
    "legacy-widget-cache-migration",
    "moment-report-only-terminal-gate",
    "moment-saved-memory-boundary",
    "moment-sent-delivery-receipt-boundary",
    "moment-paw-reaction-boundary",
    "moment-empty-cursor-normalization",
    "moment-expired-delivery-advances",
    "moment-install-bound-handoff",
    "moment-imported-memory-boundary",
    "moment-inbound-moderation-retry-policy",
    "moment-inbound-moderation-flow",
    "moderation-dual-key-configuration",
    "moment-commit-ack-metadata",
    "moment-build61-schema7-migration",
    "moment-outbox-bounds-and-expiry",
    "moment-outcome-ledger-migration",
    "moment-process-serialized-refresh",
    "moment-report-outbox-bounds-and-recovery",
    "moment-terminal-authorization-classification",
    "normalizer-orientation-scale-parity",
    "own-source-local-promotion",
    "partial-download-resume-tamper",
    "pairing-bootstrap-transient-preservation",
    "private-window-catalog-authority-uniqueness",
    "private-window-catalog-protected-storage-migration",
    "private-window-legacy-conflict-quarantine-policy",
    "peer-revoke-terminal-purge",
    "retry-independent-deadline",
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
