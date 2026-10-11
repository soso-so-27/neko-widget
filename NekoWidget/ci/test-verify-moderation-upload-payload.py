#!/usr/bin/env python3
"""Tests for the final TestFlight IPA-to-metadata binding check."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
import plistlib
import zipfile
import internal_report_release as reports
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify-moderation-upload-payload.py")


class UploadPayloadBindingTests(unittest.TestCase):
    def test_v3_binds_internal_context_and_actual_ipa_flags_even_after_rehash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); ipa = root / "NekoWidget.ipa"
            metadata = root / "moderation-release-metadata.json"
            value = {"schema": "jp.nekowidget.moderation-release-metadata.v3", "releaseEnvironment": "testflight",
                "sourceCommit": "a"*40, "releaseMode": "media-staging", "version": "1.0", "buildNumber": "250",
                "githubRunId": "123456", "githubRunAttempt": 1, "moderationKeyId": "moderation-v2",
                "moderationPublicKey": reports.PUBLIC_KEY, "moderationPublicKeySha256": "b"*64,
                "moderationTrustManifestRevision": 2, "moderationTrustManifestSha256": "b"*64,
                "moderationRolloutPolicyRevision": 2, "moderationRolloutPolicySha256": "b"*64,
                "archiveDigestAlgorithm": "sha256-tree-v2", "archiveSha256": "c"*64, "ipaSha256": "",
                "internalEncryptedReportEnabled": True, "internalEncryptedReportScope": reports.SCOPE,
                "testFlightInternalTestingOnly": True}
            info = {reports.ENABLED: True, reports.SCOPE_KEY: reports.SCOPE, "SharingReleaseMode": "media-staging",
                "SharingAPIBaseURL": reports.ORIGIN, "SharingModerationKeyID": "moderation-v2",
                "SharingModerationPublicKey": reports.PUBLIC_KEY, "SharingFeatureEnabled": True, "SharingMediaEnabled": True,
                "SharingReviewPreviewEnabled": False, "SharingShareExtensionSendEnabled": False}
            def write(tamper=False):
                with zipfile.ZipFile(ipa, "w") as archive:
                    archive.writestr("Payload/NekoWidget.app/Info.plist", plistlib.dumps(info))
                    for extension in ("NekoWidgetShareExtension", "NekoWidgetWidgetExtension"):
                        archive.writestr(f"Payload/NekoWidget.app/PlugIns/{extension}.appex/Info.plist",
                            plistlib.dumps(info if tamper else {reports.ENABLED: False, reports.SCOPE_KEY: ""}))
                value["ipaSha256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()
                metadata.write_text(json.dumps(value))
            command = [sys.executable, str(SCRIPT), "--metadata", str(metadata), "--ipa", str(ipa),
                "--expected-source-commit", "a"*40, "--expected-build-number", "250", "--expected-github-run-id", "123456",
                "--expected-github-run-attempt", "1", "--expected-release-mode", "media-staging",
                "--expected-internal-reports", "true", "--expected-internal-report-scope", reports.SCOPE]
            write(); accepted = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            wrong_context = subprocess.run(command[:-4], capture_output=True, text=True)
            self.assertNotEqual(wrong_context.returncode, 0)
            self.assertIn("upload context", wrong_context.stderr)
            write(True); rejected = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("Compiled internal report", rejected.stderr)

    def test_accepts_exact_payload_and_rejects_post_authentication_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "NekoWidget.ipa"
            ipa.write_bytes(b"signed-ipa-v1")
            metadata = root / "moderation-release-metadata.json"
            value = {
                "schema": "jp.nekowidget.moderation-release-metadata.v2",
                "releaseEnvironment": "testflight",
                "sourceCommit": "a" * 40,
                "releaseMode": "disabled",
                "version": "1.0",
                "buildNumber": "72",
                "githubRunId": "123456789",
                "githubRunAttempt": 2,
                "moderationKeyId": "",
                "moderationPublicKey": "",
                "moderationPublicKeySha256": "",
                "moderationTrustManifestRevision": None,
                "moderationTrustManifestSha256": None,
                "moderationRolloutPolicyRevision": 1,
                "moderationRolloutPolicySha256": "b" * 64,
                "archiveDigestAlgorithm": "sha256-tree-v1",
                "archiveSha256": "c" * 64,
                "ipaSha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
            }
            metadata.write_text(json.dumps(value), encoding="utf-8")
            command = [
                sys.executable,
                str(SCRIPT),
                "--metadata",
                str(metadata),
                "--ipa",
                str(ipa),
                "--expected-source-commit",
                "a" * 40,
                "--expected-build-number",
                "72",
                "--expected-github-run-id",
                "123456789",
                "--expected-github-run-attempt",
                "2",
                "--expected-release-mode",
                "disabled",
            ]
            accepted = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(0, accepted.returncode, accepted.stderr)

            ipa.write_bytes(b"signed-ipa-v2-after-metadata")
            rejected = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(0, rejected.returncode)
            self.assertIn("IPA SHA-256", rejected.stderr)

    def test_rejects_duplicate_metadata_keys(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "NekoWidget.ipa"
            ipa.write_bytes(b"ipa")
            metadata = root / "moderation-release-metadata.json"
            metadata.write_text('{"schema":"a","schema":"b"}', encoding="utf-8")
            rejected = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--metadata",
                    str(metadata),
                    "--ipa",
                    str(ipa),
                    "--expected-source-commit",
                    "a" * 40,
                    "--expected-build-number",
                    "72",
                    "--expected-github-run-id",
                    "123456789",
                    "--expected-github-run-attempt",
                    "2",
                    "--expected-release-mode",
                    "disabled",
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(0, rejected.returncode)
            self.assertIn("duplicate JSON key", rejected.stderr)


if __name__ == "__main__":
    unittest.main()
