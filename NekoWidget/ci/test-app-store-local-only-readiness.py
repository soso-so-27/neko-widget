#!/usr/bin/env python3
"""Regression tests for the local-only Japanese App Store metadata pack."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[1]
REPOSITORY = PROJECT.parent
SCRIPT = PROJECT / "ci" / "validate-app-store-local-only-readiness.py"
WRITER = PROJECT / "ci" / "write-local-only-release-evidence.py"
MANIFEST = PROJECT / "docs" / "app-store" / "local-only-ja.json"
OWNER_EXAMPLE = PROJECT / "docs" / "app-store" / "local-only-owner-input.example.json"
EVIDENCE_EXAMPLE = PROJECT / "docs" / "app-store" / "local-only-release-evidence.example.json"
README = PROJECT / "docs" / "app-store" / "README.md"
SUPPORT_PAGE = REPOSITORY / "docs" / "app" / "support" / "index.html"
GITIGNORE = REPOSITORY / ".gitignore"
COPY_WORKFLOW = REPOSITORY / ".github" / "workflows" / "ios-build.yml"
RELEASE_WORKFLOW = REPOSITORY / ".github" / "workflows" / "testflight.yml"

SPEC = importlib.util.spec_from_file_location("app_store_readiness", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not import {SCRIPT}")
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


def manifest() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


def repository_head() -> str:
    return subprocess.run(
        ["git", "-C", str(REPOSITORY), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    ).stdout.strip()


def complete_owner_input(source_commit: str, build_number: str = "36") -> dict:
    return {
        "app_name_confirmed_in_connect": True,
        "bundle_id_and_sku_confirmed": True,
        "primary_language": "Japanese",
        "primary_category": "Photo & Video",
        "content_rights_confirmed": True,
        "license_agreement_confirmed": True,
        "dsa_status_completed": True,
        "regional_availability_requirements_completed": True,
        "made_for_kids": "no",
        "age_rating_questionnaire_completed": True,
        "age_rating_result": "4+",
        "app_privacy_reconciled_with_final_archive": True,
        "app_privacy_answers_published": True,
        "privacy_policy_url_saved_in_connect": True,
        "support_url_saved_in_connect": True,
        "public_support_contact_published": True,
        "private_privacy_contact_published": True,
        "review_contact_entered_in_connect": True,
        "copyright": "2026 Owner-confirmed rights holder",
        "screenshot_set_approved": True,
        "export_compliance_completed": True,
        "export_compliance_result": "no_documentation_required_confirmed",
        "final_archive_release_mode": "disabled",
        "selected_version": "1.0",
        "selected_build": build_number,
        "selected_git_commit": source_commit,
        "pricing": "free",
        "tax_category_confirmed": True,
        "territories_confirmed": True,
        "release_method": "manual",
        "final_owner_submit_approval": True,
        "release_workflow_conclusion_success_confirmed": True,
    }


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_processed_info(path: Path, build_number: str = "36") -> None:
    path.write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": "jp.nekowidget.app",
                "CFBundleDisplayName": "ねこのまど",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": build_number,
                "SharingReleaseMode": "disabled",
                "SharingFeatureEnabled": "NO",
                "SharingMediaEnabled": "NO",
                "SharingShareExtensionHandoffEnabled": "NO",
                "SharingShareExtensionSendEnabled": "NO",
                "SharingReviewPreviewEnabled": "NO",
                "SharingAPIBaseURL": "",
                "SharingModerationKeyID": "",
                "SharingModerationPublicKey": "",
                "SharingPrivacyURL": "",
                "SharingSupportURL": "",
                "SharingCommunityStandardsURL": "",
                "AppPrivacyURL": VALIDATOR.EXPECTED_PRIVACY_URL,
                "AppSupportURL": VALIDATOR.EXPECTED_SUPPORT_URL,
                "ITSAppUsesNonExemptEncryption": False,
            }
        )
    )


def complete_release_evidence(
    source_commit: str,
    artifact_path: Path,
    info_path: Path,
    build_number: str = "36",
) -> dict:
    return {
        "schema_version": 1,
        "generated_at_utc": "2026-08-24T12:00:00Z",
        "repository": "soso-so-27/neko-widget",
        "source_commit": source_commit,
        "version": "1.0",
        "build_number": build_number,
        "release_mode": "disabled",
        "ci_run": {
            "workflow": ".github/workflows/testflight.yml",
            "run_id": 123456789,
            "run_attempt": 1,
            "event": "workflow_dispatch",
            "head_sha": source_commit,
            "run_url": "https://github.com/soso-so-27/neko-widget/actions/runs/123456789",
            "status": "completed",
            "conclusion": "success",
            "upload_to_testflight": True,
            "app_store_upload_passed": True,
            "retain_signed_artifacts": True,
        },
        "validations": {
            "archive_validator": "NekoWidget/ci/validate-sharing-release.py",
            "archive_validator_passed": True,
            "signature_validation_passed": True,
            "artifact_encryption_verified": True,
        },
        "signed_artifact": {
            "filename": "NekoWidget-signed-artifacts.tar.gz.enc",
            "sha256": sha256_file(artifact_path),
            "size_bytes": artifact_path.stat().st_size,
            "encrypted": True,
        },
        "processed_app_info": {
            "filename": "NekoWidget-processed-app-info.plist",
            "sha256": sha256_file(info_path),
        },
    }


def marked_text(source: str, field: str) -> str:
    start = f"<!-- metadata:{field}:start -->"
    end = f"<!-- metadata:{field}:end -->"
    block = source.split(start, 1)[1].split(end, 1)[0].strip()
    if not block.startswith("```text\n") or not block.endswith("\n```"):
        raise AssertionError(f"Malformed copy block for {field}")
    return block[len("```text\n") : -len("\n```")]


class AppStoreLocalOnlyReadinessTests(unittest.TestCase):
    def test_canonical_copy_and_limits_are_valid(self) -> None:
        value = manifest()
        self.assertEqual([], VALIDATOR.validate_copy(value))
        counts = VALIDATOR.metadata_counts(value)
        self.assertLessEqual(counts["app_name_characters"], 30)
        self.assertLessEqual(counts["subtitle_characters"], 30)
        self.assertLessEqual(counts["promotional_text_characters"], 170)
        self.assertLessEqual(counts["description_characters"], 4_000)
        self.assertLessEqual(counts["keywords_bytes"], 100)
        self.assertLessEqual(counts["review_notes_bytes"], 4_000)

    def test_readme_paste_blocks_match_machine_readable_source(self) -> None:
        value = manifest()
        source = README.read_text(encoding="utf-8")
        expected = {
            "app_name": value["metadata"]["app_name"],
            "subtitle": value["metadata"]["subtitle"],
            "promotional_text": value["metadata"]["promotional_text"],
            "description": value["metadata"]["description"],
            "keywords": value["metadata"]["keywords"],
            "support_url": value["metadata"]["support_url"],
            "privacy_policy_url": value["metadata"]["privacy_policy_url"],
            "review_notes": value["review"]["notes"],
        }
        for field, copy_value in expected.items():
            with self.subTest(field=field):
                self.assertEqual(copy_value, marked_text(source, field))

    def test_owner_and_release_examples_are_explicitly_unanswered(self) -> None:
        owner = json.loads(OWNER_EXAMPLE.read_text(encoding="utf-8"))
        self.assertEqual(set(VALIDATOR.OWNER_KEYS), set(owner))
        self.assertTrue(all(answer is None for answer in owner.values()))
        owner_blockers = VALIDATOR.validate_owner_input(owner, manifest())
        self.assertIn(
            "owner.release_workflow_conclusion_success_confirmed: must be explicitly true",
            owner_blockers,
        )
        self.assertIn(
            "owner.private_privacy_contact_published: must be explicitly true",
            owner_blockers,
        )

        evidence = json.loads(EVIDENCE_EXAMPLE.read_text(encoding="utf-8"))
        blockers = VALIDATOR.validate_release_evidence(
            evidence, manifest(), REPOSITORY, EVIDENCE_EXAMPLE
        )
        self.assertTrue(any("generated_at_utc" in blocker for blocker in blockers))
        self.assertTrue(any("source_commit" in blocker for blocker in blockers))
        self.assertTrue(any("signed_artifact_path" in blocker for blocker in blockers))

    def test_missing_private_inputs_are_red_but_copy_only_is_valid(self) -> None:
        copy_result = subprocess.run(
            [sys.executable, str(SCRIPT), "--copy-only", "--json"],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(0, copy_result.returncode, copy_result.stderr)
        self.assertEqual("COPY_VALID", json.loads(copy_result.stdout)["status"])

        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--owner-input",
                    str(temporary / "missing-owner.json"),
                    "--release-evidence",
                    str(temporary / "missing-evidence.json"),
                    "--json",
                ],
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
            )
        self.assertEqual(2, result.returncode, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual("RED", payload["status"])
        self.assertFalse(payload["submission_ready"])
        self.assertTrue(any("release_evidence_file: missing" in item for item in payload["blockers"]))
        self.assertTrue(any("owner_input_file: missing" in item for item in payload["blockers"]))

    def test_owner_contract_rejects_placeholders_and_cross_checks_evidence(self) -> None:
        head = repository_head()
        evidence = {
            "version": "1.0",
            "build_number": "36",
            "source_commit": head,
            "release_mode": "disabled",
        }
        owner = complete_owner_input(head)
        self.assertEqual([], VALIDATOR.validate_owner_input(owner, manifest(), evidence))

        owner["age_rating_result"] = "owner-recorded-result"
        blockers = VALIDATOR.validate_owner_input(owner, manifest(), evidence)
        self.assertTrue(any("placeholder" in blocker for blocker in blockers))

        owner = complete_owner_input("a" * 40)
        blockers = VALIDATOR.validate_owner_input(owner, manifest(), evidence)
        self.assertTrue(any("repeated-character SHA" in blocker for blocker in blockers))
        self.assertTrue(any("must exactly match release evidence" in blocker for blocker in blockers))

    def test_cli_cannot_override_canonical_site_root(self) -> None:
        self.assertEqual(REPOSITORY / "docs" / "app", VALIDATOR.DEFAULT_SITE_ROOT)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--site-root", "C:/dummy"],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(2, result.returncode)
        self.assertIn("unrecognized arguments: --site-root", result.stderr)

    def test_contact_page_contract_is_a_pure_parser_gate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            site_root = Path(directory)
            for name in ("support", "privacy"):
                page = site_root / name
                page.mkdir()
                page.joinpath("index.html").write_text(
                    """<!doctype html><html><head>
                    <meta name="neko-app-store-contact-ready" content="true">
                    </head><body>
                    <a data-neko-private-contact="true"
                       href="mailto:privacy@soso-so-27.github.io">Contact</a>
                    </body></html>""",
                    encoding="utf-8",
                )
            self.assertEqual([], VALIDATOR.validate_publication_gate(site_root))

        parser = VALIDATOR.ContactPageParser()
        parser.feed(
            '<meta name="neko-app-store-contact-ready" content="true">'
            '<a data-neko-private-contact="true" data-neko-contact-kind="form" '
            'href="https://soso-so-27.github.io/neko-widget/app/contact/">Contact</a>'
        )
        self.assertTrue(parser.has_ready_marker)
        self.assertIsNone(VALIDATOR.private_contact_route_error(*parser.private_contact_routes[0]))

    def test_current_canonical_pages_keep_contact_gate_red(self) -> None:
        source = SUPPORT_PAGE.read_text(encoding="utf-8")
        self.assertIn("非公開のプライバシー問い合わせ窓口は現在未掲載", source)
        self.assertIn("一般公開の提出準備は完了していません", source)
        blockers = VALIDATOR.validate_publication_gate(VALIDATOR.DEFAULT_SITE_ROOT)
        self.assertTrue(any("public_support_page" in blocker for blocker in blockers))
        self.assertTrue(any("public_privacy_page" in blocker for blocker in blockers))
        self.assertTrue(any("contact-ready" in blocker for blocker in blockers))

    def test_release_evidence_binds_real_files_head_and_disabled_archive(self) -> None:
        head = repository_head()
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            artifact = temporary / "NekoWidget-signed-artifacts.tar.gz.enc"
            artifact.write_bytes(b"signed-encrypted-archive\0" * 50_000)
            info = temporary / "NekoWidget-processed-app-info.plist"
            write_processed_info(info)
            evidence_path = temporary / "local-only-release-evidence.json"
            evidence = complete_release_evidence(head, artifact, info)
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")

            self.assertEqual(
                [],
                VALIDATOR.validate_release_evidence(
                    evidence, manifest(), REPOSITORY, evidence_path, artifact, info
                ),
            )

            dry_run = json.loads(json.dumps(evidence))
            dry_run["ci_run"]["upload_to_testflight"] = False
            dry_run["ci_run"]["app_store_upload_passed"] = False
            blockers = VALIDATOR.validate_release_evidence(
                dry_run, manifest(), REPOSITORY, evidence_path, artifact, info
            )
            self.assertTrue(any("upload_to_testflight" in item for item in blockers))
            self.assertTrue(any("app_store_upload_passed" in item for item in blockers))

            fake_sha = json.loads(json.dumps(evidence))
            fake_sha["source_commit"] = "a" * 40
            fake_sha["ci_run"]["head_sha"] = "a" * 40
            blockers = VALIDATOR.validate_release_evidence(
                fake_sha, manifest(), REPOSITORY, evidence_path, artifact, info
            )
            self.assertTrue(any("repeated-character SHA" in item for item in blockers))
            self.assertTrue(any("repository HEAD" in item for item in blockers))

            placeholder = json.loads(json.dumps(evidence))
            placeholder["validations"]["archive_validator"] = "owner-recorded-result"
            blockers = VALIDATOR.validate_release_evidence(
                placeholder, manifest(), REPOSITORY, evidence_path, artifact, info
            )
            self.assertTrue(any("placeholder" in item for item in blockers))

            artifact.write_bytes(artifact.read_bytes() + b"tampered")
            blockers = VALIDATOR.validate_release_evidence(
                evidence, manifest(), REPOSITORY, evidence_path, artifact, info
            )
            self.assertTrue(any("actual file mismatch" in item for item in blockers))

    def test_github_run_and_artifacts_are_cross_checked_as_pure_records(self) -> None:
        head = repository_head()
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            artifact = temporary / "NekoWidget-signed-artifacts.tar.gz.enc"
            artifact.write_bytes(b"signed-encrypted-archive\0" * 50_000)
            info = temporary / "NekoWidget-processed-app-info.plist"
            write_processed_info(info)
            evidence = complete_release_evidence(head, artifact, info)
        run_record = {
            "id": 123456789,
            "event": "workflow_dispatch",
            "head_sha": head,
            "head_branch": "main",
            "run_attempt": 1,
            "status": "completed",
            "conclusion": "success",
            "html_url": "https://github.com/soso-so-27/neko-widget/actions/runs/123456789",
            "path": ".github/workflows/testflight.yml@main",
            "repository": {"full_name": "soso-so-27/neko-widget"},
        }
        artifacts_record = {
            "artifacts": [
                {
                    "id": index,
                    "name": name,
                    "size_in_bytes": size,
                    "digest": "sha256:" + digest,
                    "expired": False,
                    "workflow_run": {"id": 123456789, "head_sha": head},
                }
                for index, name, size, digest in (
                    (
                        9001,
                        "nekowidget-signed-artifacts-123456789-1",
                        2_000_000,
                        "12" * 32,
                    ),
                    (
                        9002,
                        "nekowidget-local-only-release-evidence-123456789-1",
                        8_192,
                        "34" * 32,
                    ),
                )
            ]
        }
        self.assertEqual(
            [],
            VALIDATOR.validate_github_run_records(
                evidence, run_record, artifacts_record
            ),
        )
        run_record["conclusion"] = "failure"
        blockers = VALIDATOR.validate_github_run_records(
            evidence, run_record, artifacts_record
        )
        self.assertIn(
            "github_run.conclusion: must exactly match release evidence/final run",
            blockers,
        )

    def test_workflow_writer_generates_file_bound_evidence_only_in_actions(self) -> None:
        head = repository_head()
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            artifact = temporary / "NekoWidget-signed-artifacts.tar.gz.enc"
            artifact.write_bytes(b"signed-encrypted-archive\0" * 50_000)
            source_info = temporary / "archive-app-info.plist"
            write_processed_info(source_info)
            environment = dict(os.environ)
            environment.update(
                {
                    "GITHUB_ACTIONS": "true",
                    "GITHUB_SHA": head,
                    "GITHUB_RUN_ID": "123456789",
                    "GITHUB_RUN_ATTEMPT": "1",
                    "GITHUB_EVENT_NAME": "workflow_dispatch",
                    "GITHUB_REPOSITORY": "soso-so-27/neko-widget",
                }
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(WRITER),
                    "--repository",
                    str(REPOSITORY),
                    "--info-plist",
                    str(source_info),
                    "--artifact",
                    str(artifact),
                    "--output-directory",
                    str(temporary),
                    "--source-commit",
                    head,
                    "--version",
                    "1.0",
                    "--build-number",
                    "36",
                    "--release-mode",
                    "disabled",
                    "--run-id",
                    "123456789",
                    "--run-attempt",
                    "1",
                    "--event",
                    "workflow_dispatch",
                    "--upload-to-testflight",
                    "true",
                    "--retain-signed-artifacts",
                    "true",
                ],
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
                env=environment,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            evidence_path = temporary / "local-only-release-evidence.json"
            processed_info = temporary / "NekoWidget-processed-app-info.plist"
            evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
            self.assertEqual("completed", evidence["ci_run"]["status"])
            self.assertEqual("success", evidence["ci_run"]["conclusion"])
            self.assertEqual(
                [],
                VALIDATOR.validate_release_evidence(
                    evidence,
                    manifest(),
                    REPOSITORY,
                    evidence_path,
                    artifact,
                    processed_info,
                ),
            )

    def test_privacy_age_export_and_final_approval_each_fail_closed(self) -> None:
        head = repository_head()
        for key in (
            "private_privacy_contact_published",
            "age_rating_questionnaire_completed",
            "export_compliance_completed",
            "release_workflow_conclusion_success_confirmed",
            "final_owner_submit_approval",
        ):
            owner = complete_owner_input(head)
            owner[key] = False
            blockers = VALIDATOR.validate_owner_input(owner, manifest())
            with self.subTest(key=key):
                self.assertIn(f"owner.{key}: must be explicitly true", blockers)

    def test_copy_validator_rejects_limits_mismatch_and_fake_url(self) -> None:
        value = manifest()
        value["metadata"]["subtitle"] = "猫" * 31
        self.assertTrue(any("subtitle" in error for error in VALIDATOR.validate_copy(value)))

        value = manifest()
        value["metadata"]["keywords"] = "猫写真," * 30
        self.assertTrue(any("keywords" in error for error in VALIDATOR.validate_copy(value)))

        value = manifest()
        value["metadata"]["support_url"] = "https://localhost/support/"
        self.assertTrue(any("support_url" in error for error in VALIDATOR.validate_copy(value)))

        value = manifest()
        value["verified_facts"]["network_photo_sharing"] = True
        self.assertIn(
            "verified_facts: exact local-only fact contract does not match",
            VALIDATOR.validate_copy(value),
        )

    def test_private_evidence_is_ignored_and_workflows_are_wired(self) -> None:
        ignored = GITIGNORE.read_text(encoding="utf-8")
        for path in (
            "NekoWidget/docs/app-store/local-only-owner-input.json",
            "NekoWidget/docs/app-store/local-only-release-evidence.json",
            "NekoWidget/docs/app-store/NekoWidget-signed-artifacts.tar.gz.enc",
            "NekoWidget/docs/app-store/NekoWidget-processed-app-info.plist",
        ):
            self.assertIn(path, ignored)

        copy_workflow = COPY_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("python3 ci/test-app-store-local-only-readiness.py", copy_workflow)
        release_workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        upload_index = release_workflow.index("Validate and upload IPA to TestFlight")
        evidence_index = release_workflow.index("Write local-only signed release evidence")
        self.assertLess(upload_index, evidence_index)
        self.assertIn("inputs.release_mode == 'disabled'", release_workflow)
        self.assertIn('--upload-to-testflight "$UPLOAD_TO_TESTFLIGHT"', release_workflow)
        self.assertIn("local-only-release-evidence.json", release_workflow)
        writer = WRITER.read_text(encoding="utf-8")
        self.assertIn('os.environ.get("GITHUB_ACTIONS") != "true"', writer)
        self.assertIn('EXPECTED_EVIDENCE_FILENAME = "local-only-release-evidence.json"', writer)


if __name__ == "__main__":
    unittest.main()
