#!/usr/bin/env python3
"""Tests for the final TestFlight IPA-to-metadata binding check."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify-moderation-upload-payload.py")


class UploadPayloadBindingTests(unittest.TestCase):
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
