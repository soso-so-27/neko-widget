#!/usr/bin/env python3
"""Static ordering tests for TestFlight release evidence handling."""

from __future__ import annotations

import unittest
from pathlib import Path


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/testflight.yml"


class TestFlightReleaseEvidenceWorkflowTests(unittest.TestCase):
    def test_upload_reauthenticates_then_rehashes_exact_payload_before_altool(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        upload_step = workflow.index("- name: Validate and upload IPA to TestFlight")
        upload_end = workflow.index("- name: Write local-only signed release evidence")
        upload_block = workflow[upload_step:upload_end]
        self.assertIn(
            'python3 "$GITHUB_WORKSPACE/$PROJECT_DIRECTORY/ci/'
            'signed-artifact-authentication.py" verify',
            upload_block,
        )
        self.assertIn(
            'python3 "$GITHUB_WORKSPACE/$PROJECT_DIRECTORY/ci/'
            'verify-moderation-upload-payload.py"',
            upload_block,
        )
        self.assertNotIn('python3 "$PROJECT_DIRECTORY/ci/', upload_block)
        authentication = workflow.index(
            'signed-artifact-authentication.py" verify', upload_step
        )
        payload_binding = workflow.index(
            'verify-moderation-upload-payload.py"', authentication
        )
        validate = workflow.index("run_altool_stage validate", payload_binding)
        upload = workflow.index("run_altool_stage upload", validate)
        self.assertLess(authentication, payload_binding)
        self.assertLess(payload_binding, validate)
        self.assertLess(validate, upload)

    def test_bundle_is_authenticated_before_decryption_and_content_binding(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        package_step = workflow.index("- name: Package archive and symbols")
        package_end = workflow.index(
            "- name: Upload encrypted signed app and symbols", package_step
        )
        package = workflow[package_step:package_end]
        self.assertIn("COPYFILE_DISABLE=1 tar \\", package)
        authentication = workflow.index(
            'signed-artifact-authentication.py" verify', package_step
        )
        decryption = workflow.index("openssl enc \\\n            -d", authentication)
        content_binding = workflow.index(
            'verify-signed-artifact-contents.py"', decryption
        )
        self.assertLess(authentication, decryption)
        self.assertLess(decryption, content_binding)
        self.assertIn("moderation-key-trust-manifest.json", workflow)

    def test_local_only_success_and_failure_preserve_authenticated_triples(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        writer_step = workflow.index("- name: Write local-only signed release evidence")
        self.assertNotEqual(-1, workflow.find("--release-metadata", writer_step))
        self.assertNotEqual(-1, workflow.find("--artifact-authentication", writer_step))
        failure_stage = workflow.index(
            "- name: Stage authenticated local-only evidence after failure"
        )
        failure_verify = workflow.index(
            'signed-artifact-authentication.py" verify', failure_stage
        )
        failure_copy = workflow.index(
            '/bin/cp "$ciphertext" "$metadata" "$authentication"', failure_verify
        )
        failure_upload = workflow.index(
            "- name: Preserve authenticated local-only evidence after failure",
            failure_copy,
        )
        self.assertLess(failure_verify, failure_copy)
        self.assertLess(failure_copy, failure_upload)
        self.assertIn(
            "path: ${{ runner.temp }}/failed-local-only-authenticated-evidence/",
            workflow[failure_upload:],
        )


if __name__ == "__main__":
    unittest.main()
