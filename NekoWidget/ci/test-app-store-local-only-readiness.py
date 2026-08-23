#!/usr/bin/env python3
"""Regression tests for fail-closed local-only App Store readiness."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock
from urllib.error import HTTPError


PROJECT = Path(__file__).resolve().parents[1]
REPOSITORY = PROJECT.parent
SCRIPT = PROJECT / "ci" / "validate-app-store-local-only-readiness.py"
WRITER = PROJECT / "ci" / "write-local-only-release-evidence.py"
MANIFEST = PROJECT / "docs" / "app-store" / "local-only-ja.json"
OWNER_EXAMPLE = PROJECT / "docs" / "app-store" / "local-only-owner-input.example.json"
CONTACT_EXAMPLE = PROJECT / "docs" / "app-store" / "local-only-contact-approval.example.json"
EVIDENCE_EXAMPLE = PROJECT / "docs" / "app-store" / "local-only-release-evidence.example.json"
README = PROJECT / "docs" / "app-store" / "README.md"
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


def valid_owner_fixture(source_commit: str) -> dict:
    """Concrete values used only inside this unit-test fixture."""
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
        "copyright": "2026 Cat Window QA Labs",
        "screenshot_set_approved": True,
        "export_compliance_completed": True,
        "export_compliance_result": "exempt_no_documentation_required_confirmed",
        "final_archive_release_mode": "disabled",
        "selected_version": "1.0",
        "selected_build": "36",
        "selected_git_commit": source_commit,
        "selected_github_run_id": "123456789",
        "selected_github_artifact_id": "987654321",
        "pricing": "free",
        "tax_category_confirmed": True,
        "territories_confirmed": True,
        "release_method": "manual",
        "final_owner_submit_approval": True,
        "release_workflow_conclusion_success_confirmed": True,
    }


def valid_contact_fixture() -> dict:
    """Synthetic exact records used only for pure-function unit tests."""
    approved_at = (datetime.now(timezone.utc) - timedelta(days=1)).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    return {
        "schema_version": 1,
        "owner_selected_and_approved": True,
        "pages": {
            "support": {
                "canonical_page_uri": VALIDATOR.EXPECTED_SUPPORT_URL,
                "contact_kind": "mailto",
                "contact_uri": "mailto:support@soso-so-27.github.io",
                "owner_delivery_test_completed": True,
                "approved_at_utc": approved_at,
            },
            "privacy": {
                "canonical_page_uri": VALIDATOR.EXPECTED_PRIVACY_URL,
                "contact_kind": "mailto",
                "contact_uri": "mailto:privacy@soso-so-27.github.io",
                "owner_delivery_test_completed": True,
                "approved_at_utc": approved_at,
            },
        },
    }


def page_html(uri: str, kind: str = "mailto", hidden: bool = False) -> str:
    kind_attribute = "" if kind == "mailto" else ' data-neko-contact-kind="form"'
    hidden_attribute = " hidden" if hidden else ""
    return f"""<!doctype html><html><head>
<meta name="neko-app-store-contact-ready" content="true">
</head><body><a data-neko-private-contact="true"{kind_attribute}{hidden_attribute}
href="{uri}">問い合わせ</a></body></html>"""


def processed_info_bytes(build_number: str = "36") -> bytes:
    return plistlib.dumps(
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


def evidence_fixture(source_commit: str, encrypted: bytes, info: bytes) -> dict:
    return {
        "schema_version": 1,
        "generated_at_utc": "2026-08-23T12:00:00Z",
        "repository": "soso-so-27/neko-widget",
        "source_commit": source_commit,
        "version": "1.0",
        "build_number": "36",
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
            "inputs": {
                "requested_build_number": "36",
                "release_mode": "disabled",
                "upload_to_testflight": True,
                "retain_signed_artifacts": True,
            },
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
            "filename": VALIDATOR.EXPECTED_ARTIFACT_FILENAME,
            "sha256": hashlib.sha256(encrypted).hexdigest(),
            "size_bytes": len(encrypted),
            "encrypted": True,
        },
        "processed_app_info": {
            "filename": VALIDATOR.EXPECTED_PROCESSED_INFO_FILENAME,
            "sha256": hashlib.sha256(info).hexdigest(),
        },
    }


def write_bundle(
    directory: Path,
    evidence: dict,
    encrypted: bytes,
    info: bytes,
    extra_member: bool = False,
) -> Path:
    output = directory / "remote-release-evidence.zip"
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr(
            VALIDATOR.EXPECTED_EVIDENCE_FILENAME,
            json.dumps(evidence, ensure_ascii=False),
        )
        archive.writestr(VALIDATOR.EXPECTED_PROCESSED_INFO_FILENAME, info)
        archive.writestr(VALIDATOR.EXPECTED_ARTIFACT_FILENAME, encrypted)
        if extra_member:
            archive.writestr("unrelated.txt", "not allowed")
    return output


def artifact_record(bundle: Path, source_commit: str) -> dict:
    return {
        "id": 987654321,
        "name": "nekowidget-local-only-release-evidence-123456789-1",
        "size_in_bytes": bundle.stat().st_size,
        "digest": "sha256:" + hashlib.sha256(bundle.read_bytes()).hexdigest(),
        "expired": False,
        "archive_download_url": (
            "https://api.github.com/repos/soso-so-27/neko-widget/actions/"
            "artifacts/987654321/zip"
        ),
        "workflow_run": {
            "id": 123456789,
            "head_branch": "main",
            "head_sha": source_commit,
        },
    }


def run_record(source_commit: str) -> dict:
    return {
        "id": 123456789,
        "event": "workflow_dispatch",
        "head_sha": source_commit,
        "head_branch": "main",
        "run_attempt": 1,
        "status": "completed",
        "conclusion": "success",
        "run_started_at": "2026-08-23T10:50:00.125Z",
        "updated_at": "2026-08-23T13:05:00.875Z",
        "html_url": "https://github.com/soso-so-27/neko-widget/actions/runs/123456789",
        "path": ".github/workflows/testflight.yml",
        "repository": {"full_name": "soso-so-27/neko-widget"},
    }


def jobs_record() -> dict:
    names = (
        "Validate sharing privacy and export gates",
        "Verify archive signatures and App Group entitlements",
        "Package archive and symbols",
        "Validate and upload IPA to TestFlight",
        "Write local-only signed release evidence",
        "Upload local-only signed release evidence",
    )
    return {
        "jobs": [
            {
                "name": "Archive, export IPA, and upload",
                "run_id": 123456789,
                "run_attempt": 1,
                "head_sha": repository_head(),
                "status": "completed",
                "conclusion": "success",
                "started_at": "2026-08-23T11:00:00.250Z",
                "completed_at": "2026-08-23T13:00:00.750Z",
                "steps": [
                    {
                        "name": name,
                        "status": "completed",
                        "conclusion": "success",
                    }
                    for name in names
                ],
            }
        ]
    }


def marked_text(source: str, field: str) -> str:
    start = f"<!-- metadata:{field}:start -->"
    end = f"<!-- metadata:{field}:end -->"
    block = source.split(start, 1)[1].split(end, 1)[0].strip()
    if not block.startswith("```text\n") or not block.endswith("\n```"):
        raise AssertionError(f"Malformed copy block for {field}")
    return block[len("```text\n") : -len("\n```")]


class AppStoreLocalOnlyReadinessTests(unittest.TestCase):
    def test_canonical_copy_limits_and_paste_blocks(self) -> None:
        value = manifest()
        self.assertEqual([], VALIDATOR.validate_copy(value))
        counts = VALIDATOR.metadata_counts(value)
        self.assertLessEqual(counts["app_name_characters"], 30)
        self.assertLessEqual(counts["subtitle_characters"], 30)
        self.assertLessEqual(counts["promotional_text_characters"], 170)
        self.assertLessEqual(counts["description_characters"], 4_000)
        self.assertLessEqual(counts["keywords_bytes"], 100)
        self.assertLessEqual(counts["review_notes_bytes"], 4_000)
        source = README.read_text(encoding="utf-8")
        for field, expected in {
            "app_name": value["metadata"]["app_name"],
            "subtitle": value["metadata"]["subtitle"],
            "promotional_text": value["metadata"]["promotional_text"],
            "description": value["metadata"]["description"],
            "keywords": value["metadata"]["keywords"],
            "support_url": value["metadata"]["support_url"],
            "privacy_policy_url": value["metadata"]["privacy_policy_url"],
            "review_notes": value["review"]["notes"],
        }.items():
            with self.subTest(field=field):
                self.assertEqual(expected, marked_text(source, field))

    def test_checked_in_examples_are_unanswered_and_fail_closed(self) -> None:
        owner = json.loads(OWNER_EXAMPLE.read_text(encoding="utf-8"))
        self.assertEqual(set(VALIDATOR.OWNER_KEYS), set(owner))
        self.assertTrue(all(value is None for value in owner.values()))
        self.assertTrue(VALIDATOR.validate_owner_input(owner, manifest()))

        approval = json.loads(CONTACT_EXAMPLE.read_text(encoding="utf-8"))
        blockers = VALIDATOR.validate_contact_approval(approval)
        self.assertTrue(any("owner_selected_and_approved" in item for item in blockers))
        self.assertTrue(any("contact_uri" in item for item in blockers))

        evidence = json.loads(EVIDENCE_EXAMPLE.read_text(encoding="utf-8"))
        self.assertIsNone(evidence["source_commit"])
        self.assertIsNone(evidence["ci_run"]["inputs"]["release_mode"])

    def test_default_readiness_is_red_without_owner_contact_or_remote_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--owner-input",
                    str(temporary / "missing-owner.json"),
                    "--contact-approval",
                    str(temporary / "missing-contact.json"),
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
        self.assertTrue(any("owner_input_file: missing" in item for item in payload["blockers"]))
        self.assertTrue(any("contact_approval_file: missing" in item for item in payload["blockers"]))

        copy_result = subprocess.run(
            [sys.executable, str(SCRIPT), "--copy-only", "--json"],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(0, copy_result.returncode)
        self.assertEqual("COPY_VALID", json.loads(copy_result.stdout)["status"])

    def test_cli_cannot_override_site_or_supply_three_local_evidence_files(self) -> None:
        self.assertEqual(REPOSITORY / "docs" / "app", VALIDATOR.DEFAULT_SITE_ROOT)
        for arguments in (
            ["--site-root", "C:/dummy"],
            ["--release-evidence", "evidence.json"],
            ["--signed-artifact", "archive.enc"],
            ["--processed-app-info", "Info.plist"],
        ):
            result = subprocess.run(
                [sys.executable, str(SCRIPT), *arguments],
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
            )
            with self.subTest(arguments=arguments):
                self.assertEqual(2, result.returncode)
                self.assertIn("unrecognized arguments", result.stderr)

    def test_submission_uses_canonical_clean_head_sources_only(self) -> None:
        self.assertEqual(
            [],
            VALIDATOR.validate_canonical_release_source_binding(MANIFEST),
        )
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            alternate = temporary / "alternate-local-only-ja.json"
            alternate.write_text(
                MANIFEST.read_text(encoding="utf-8"), encoding="utf-8"
            )
            normal = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--manifest",
                    str(alternate),
                    "--json",
                ],
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
            )
            self.assertEqual(2, normal.returncode)
            payload = json.loads(normal.stdout)
            self.assertTrue(
                any(
                    "canonical local-only-ja.json" in item
                    for item in payload["blockers"]
                )
            )
            copy_only = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--manifest",
                    str(alternate),
                    "--copy-only",
                ],
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
            )
            self.assertEqual(0, copy_only.returncode, copy_only.stderr)

        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            tracked = repository / "release.json"
            tracked.write_text('{"status":"committed"}\n', encoding="utf-8")
            commands = (
                ["git", "init", "-q"],
                ["git", "config", "user.email", "unit-test@invalid.example"],
                ["git", "config", "user.name", "Unit Test"],
                ["git", "add", "release.json"],
                ["git", "commit", "-q", "-m", "fixture"],
            )
            for command in commands:
                subprocess.run(
                    command,
                    cwd=repository,
                    check=True,
                    capture_output=True,
                )
            self.assertEqual(
                [],
                VALIDATOR.validate_tracked_head_paths(
                    repository, ("release.json",)
                ),
            )
            tracked.write_text('{"status":"dirty"}\n', encoding="utf-8")
            blockers = VALIDATOR.validate_tracked_head_paths(
                repository, ("release.json",)
            )
            self.assertTrue(
                any("exactly match repository HEAD" in item for item in blockers)
            )

    def test_contact_approval_requires_exact_specific_values(self) -> None:
        approval = valid_contact_fixture()
        self.assertEqual([], VALIDATOR.validate_contact_approval(approval))

        approval["pages"]["support"]["canonical_page_uri"] = VALIDATOR.EXPECTED_PRIVACY_URL
        self.assertTrue(
            any("canonical_page_uri" in item for item in VALIDATOR.validate_contact_approval(approval))
        )
        approval = valid_contact_fixture()
        approval["pages"]["privacy"]["contact_uri"] = "mailto:T O D O@soso-so-27.github.io"
        blockers = VALIDATOR.validate_contact_approval(approval)
        self.assertTrue(any("placeholder" in item for item in blockers))
        approval = valid_contact_fixture()
        approval["pages"]["support"]["owner_delivery_test_completed"] = False
        self.assertTrue(
            any("owner_delivery_test_completed" in item for item in VALIDATOR.validate_contact_approval(approval))
        )
        approval = valid_contact_fixture()
        approval["pages"]["support"]["approved_at_utc"] = (
            datetime.now(timezone.utc)
            - timedelta(days=VALIDATOR.CONTACT_APPROVAL_MAX_AGE_DAYS + 1)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertTrue(
            any(
                "older than" in item
                for item in VALIDATOR.validate_contact_approval(approval)
            )
        )
        for unsafe in (
            "mailto:a%0d%0abcc@real-domain.jp",
            "mailto:first@real-domain.jp,second@real-domain.jp",
            "mailto:first@real-domain.jp?bcc=second@real-domain.jp",
        ):
            with self.subTest(unsafe=unsafe):
                self.assertIsNotNone(
                    VALIDATOR.private_contact_route_error("mailto", unsafe)
                )

    def test_contact_pages_must_match_approved_uri_and_visible_head_marker(self) -> None:
        approval = valid_contact_fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for label in ("support", "privacy"):
                page = root / label
                page.mkdir()
                page.joinpath("index.html").write_text(
                    page_html(approval["pages"][label]["contact_uri"]),
                    encoding="utf-8",
                )
            self.assertEqual([], VALIDATOR.validate_publication_gate(root, approval))

            (root / "support" / "index.html").write_text(
                page_html("mailto:different@soso-so-27.github.io"), encoding="utf-8"
            )
            blockers = VALIDATOR.validate_publication_gate(root, approval)
            self.assertTrue(any("owner-approved URI" in item for item in blockers))

            (root / "support" / "index.html").write_text(
                page_html(approval["pages"]["support"]["contact_uri"], hidden=True),
                encoding="utf-8",
            )
            blockers = VALIDATOR.validate_publication_gate(root, approval)
            self.assertTrue(any("visible anchor" in item for item in blockers))

        marker_in_body = (
            '<html><body><meta name="neko-app-store-contact-ready" content="true">'
            '<a data-neko-private-contact="true" '
            'href="mailto:support@soso-so-27.github.io">Contact</a></body></html>'
        )
        blockers = VALIDATOR.parse_contact_page(
            "support", marker_in_body, "mailto:support@soso-so-27.github.io"
        )
        self.assertTrue(any("contact-ready" in item for item in blockers))

        for malformed_route in (
            '<html><head><meta name="neko-app-store-contact-ready" content="true">'
            '<a data-neko-private-contact="true" '
            'href="mailto:support@soso-so-27.github.io">Contact</a></head><body></body></html>',
            '<html><head><meta name="neko-app-store-contact-ready" content="true">'
            '</head><body><a data-neko-private-contact="true" '
            'href="mailto:support@soso-so-27.github.io"></a></body></html>',
        ):
            with self.subTest(malformed_route=malformed_route):
                blockers = VALIDATOR.parse_contact_page(
                    "support",
                    malformed_route,
                    "mailto:support@soso-so-27.github.io",
                )
                self.assertTrue(blockers)

    def test_live_records_require_canonical_pages_and_reachable_https_form(self) -> None:
        approval = valid_contact_fixture()
        local_sources = {
            label: page_html(approval["pages"][label]["contact_uri"])
            for label in ("support", "privacy")
        }
        records = {
            f"page:{label}": {
                "requested_url": approval["pages"][label]["canonical_page_uri"],
                "final_url": approval["pages"][label]["canonical_page_uri"],
                "status": 200,
                "content_type": "text/html",
                "body": local_sources[label],
            }
            for label in ("support", "privacy")
        }
        self.assertEqual(
            [], VALIDATOR.validate_live_page_records(approval, records, local_sources)
        )

        approval["pages"]["support"]["contact_kind"] = "form"
        approval["pages"]["support"]["contact_uri"] = (
            "https://soso-so-27.github.io/neko-widget/app/contact/"
        )
        local_sources["support"] = page_html(
            approval["pages"]["support"]["contact_uri"], kind="form"
        )
        records["page:support"]["body"] = local_sources["support"]
        records["route:support"] = {
            "requested_url": approval["pages"]["support"]["contact_uri"],
            "final_url": approval["pages"]["support"]["contact_uri"],
            "status": 404,
            "content_type": "text/html",
            "body": "",
        }
        blockers = VALIDATOR.validate_live_page_records(
            approval, records, local_sources
        )
        self.assertTrue(any("expected HTTP 2xx" in item for item in blockers))
        records["route:support"]["status"] = 200
        records["route:support"]["final_url"] = VALIDATOR.EXPECTED_SUPPORT_URL
        blockers = VALIDATOR.validate_live_page_records(
            approval, records, local_sources
        )
        self.assertTrue(any("final URL" in item for item in blockers))
        records["route:support"]["final_url"] = approval["pages"]["support"][
            "contact_uri"
        ]
        records["route:support"]["content_type"] = "application/json"
        blockers = VALIDATOR.validate_live_page_records(
            approval, records, local_sources
        )
        self.assertTrue(any("HTML content type" in item for item in blockers))

    def test_current_canonical_pages_remain_red_without_approval(self) -> None:
        blockers = VALIDATOR.validate_publication_gate(VALIDATOR.DEFAULT_SITE_ROOT, None)
        self.assertTrue(any("public_support_page" in item for item in blockers))
        self.assertTrue(any("public_privacy_page" in item for item in blockers))
        self.assertTrue(any("owner-approved URI" in item for item in blockers))

    def test_owner_fields_reject_templates_shortcuts_and_obfuscated_placeholders(self) -> None:
        head = repository_head()
        owner = valid_owner_fixture(head)
        self.assertEqual([], VALIDATOR.validate_owner_input(owner, manifest()))
        mutations = {
            "primary_language": "x",
            "primary_category": "ok",
            "age_rating_result": "ok",
            "export_compliance_result": "Owner_confirmed",
            "copyright": "【権利者】",
        }
        for key, value in mutations.items():
            candidate = valid_owner_fixture(head)
            candidate[key] = value
            with self.subTest(key=key):
                self.assertTrue(VALIDATOR.validate_owner_input(candidate, manifest()))
        for value in (
            "2026 x",
            "2026 xx",
            "2026 foo",
            "2026 bar",
            "2026 test",
            "2026 sample",
            "2026 x!",
            "2026 Test Owner",
            "2026 Sample Owner",
            "2026 Your Name",
            "2026 Name Here",
        ):
            candidate = valid_owner_fixture(head)
            candidate["copyright"] = value
            with self.subTest(copyright=value):
                blockers = VALIDATOR.validate_owner_input(candidate, manifest())
                self.assertTrue(any("specific rights owner" in item for item in blockers))
        real_owner_word = valid_owner_fixture(head)
        real_owner_word["copyright"] = "2026 Cat Owner Studio"
        self.assertEqual(
            [], VALIDATOR.validate_owner_input(real_owner_word, manifest())
        )
        for value in (
            "T O D O",
            "ＴＢＤ",
            "owner_recorded_result",
            "【Connect確認】",
            "n/a",
        ):
            self.assertIsNotNone(VALIDATOR.matched_placeholder(value))
        self.assertIsNone(VALIDATOR.matched_placeholder("2026 Nakanishi Studio"))

    def test_remote_run_artifact_and_required_steps_are_exact(self) -> None:
        head = repository_head()
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            encrypted = b"signed-encrypted-archive\0" * 50_000
            info = processed_info_bytes()
            evidence = evidence_fixture(head, encrypted, info)
            bundle = write_bundle(temporary, evidence, encrypted, info)
            artifact = artifact_record(bundle, head)
            run = run_record(head)
            jobs = jobs_record()
            self.assertEqual(
                [],
                VALIDATOR.validate_remote_run_and_artifact_records(
                    123456789, 987654321, head, run, artifact, jobs
                ),
            )
            self.assertEqual(
                [], VALIDATOR.validate_github_run_records(evidence, run, artifact, jobs)
            )

            unrelated = dict(artifact)
            unrelated["name"] = "nekowidget-release-diagnostics-123456789-1"
            blockers = VALIDATOR.validate_remote_run_and_artifact_records(
                123456789, 987654321, head, run, unrelated, jobs
            )
            self.assertTrue(any("unrelated artifact" in item for item in blockers))
            dry_run_artifact = dict(artifact)
            dry_run_artifact["name"] = (
                "nekowidget-signed-artifacts-123456789-1"
            )
            blockers = VALIDATOR.validate_remote_run_and_artifact_records(
                123456789, 987654321, head, run, dry_run_artifact, jobs
            )
            self.assertTrue(any("unrelated artifact" in item for item in blockers))
            expired = dict(artifact)
            expired["expired"] = True
            blockers = VALIDATOR.validate_remote_run_and_artifact_records(
                123456789, 987654321, head, run, expired, jobs
            )
            self.assertTrue(any("unavailable" in item for item in blockers))
            failed_jobs = jobs_record()
            failed_jobs["jobs"][0]["steps"][3]["conclusion"] = "skipped"
            blockers = VALIDATOR.validate_remote_run_and_artifact_records(
                123456789, 987654321, head, run, artifact, failed_jobs
            )
            self.assertTrue(any("Validate and upload IPA" in item for item in blockers))

            duplicate_jobs = jobs_record()
            duplicate_jobs["jobs"][0]["steps"].append(
                dict(duplicate_jobs["jobs"][0]["steps"][0])
            )
            blockers = VALIDATOR.validate_remote_run_and_artifact_records(
                123456789, 987654321, head, run, artifact, duplicate_jobs
            )
            self.assertTrue(any("exactly one step" in item for item in blockers))

            duplicate_release_jobs = jobs_record()
            duplicate_release_jobs["jobs"].append(
                dict(duplicate_release_jobs["jobs"][0])
            )
            blockers = VALIDATOR.validate_remote_run_and_artifact_records(
                123456789,
                987654321,
                head,
                run,
                artifact,
                duplicate_release_jobs,
            )
            self.assertTrue(any("exactly one release job" in item for item in blockers))

            wrong_url = dict(artifact)
            wrong_url["archive_download_url"] = (
                "https://api.github.com/repos/soso-so-27/neko-widget/actions/"
                "artifacts/111111111/zip"
            )
            blockers = VALIDATOR.validate_remote_run_and_artifact_records(
                123456789, 987654321, head, run, wrong_url, jobs
            )
            self.assertTrue(any("canonical URL mismatch" in item for item in blockers))

            wrong_attempt = dict(run)
            wrong_attempt["run_attempt"] = 2
            blockers = VALIDATOR.validate_remote_run_and_artifact_records(
                123456789, 987654321, head, wrong_attempt, artifact, jobs
            )
            self.assertTrue(any("run_attempt" in item for item in blockers))

            wrong_sha = dict(run)
            wrong_sha["head_sha"] = "b" * 40
            blockers = VALIDATOR.validate_remote_run_and_artifact_records(
                123456789, 987654321, head, wrong_sha, artifact, jobs
            )
            self.assertTrue(any("head_sha" in item for item in blockers))

    def test_remote_lookup_fails_closed_without_auth_or_on_unauthorized_api(self) -> None:
        with mock.patch.object(VALIDATOR, "github_auth_token", return_value=None):
            run, artifact, jobs, blockers = VALIDATOR.fetch_remote_release_records(
                123456789, 987654321
            )
        self.assertIsNone(run)
        self.assertIsNone(artifact)
        self.assertIsNone(jobs)
        self.assertTrue(any("authenticated API access" in item for item in blockers))

        unauthorized = HTTPError(
            "https://api.github.com/",
            401,
            "Unauthorized",
            hdrs=None,
            fp=None,
        )
        with mock.patch.object(
            VALIDATOR, "github_auth_token", return_value="unit-test-token"
        ), mock.patch.object(VALIDATOR, "github_json", side_effect=unauthorized):
            run, artifact, jobs, blockers = VALIDATOR.fetch_remote_release_records(
                123456789, 987654321
            )
        self.assertIsNone(run)
        self.assertIsNone(artifact)
        self.assertIsNone(jobs)
        self.assertTrue(any("API lookup failed" in item for item in blockers))

    def test_api_zip_digest_is_verified_before_fixed_members_and_inner_files(self) -> None:
        head = repository_head()
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            encrypted = b"signed-encrypted-archive\0" * 50_000
            info = processed_info_bytes()
            evidence = evidence_fixture(head, encrypted, info)
            bundle = write_bundle(temporary, evidence, encrypted, info)
            artifact = artifact_record(bundle, head)
            extracted = temporary / "extracted"
            parsed, blockers = VALIDATOR.validate_evidence_bundle_zip(
                bundle, artifact, manifest(), REPOSITORY, extracted
            )
            self.assertEqual([], blockers)
            self.assertEqual(evidence, parsed)
            self.assertEqual(
                set(VALIDATOR.EXPECTED_BUNDLE_MEMBERS),
                {path.name for path in extracted.iterdir()},
            )

            tampered_bytes = bytearray(bundle.read_bytes())
            tampered_bytes[len(tampered_bytes) // 2] ^= 0x01
            bundle.write_bytes(tampered_bytes)
            parsed, blockers = VALIDATOR.validate_evidence_bundle_zip(
                bundle, artifact, manifest(), REPOSITORY, temporary / "tampered"
            )
            self.assertIsNone(parsed)
            self.assertEqual(
                ["release_bundle: ZIP SHA-256 does not match GitHub API digest"], blockers
            )

        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            original_encrypted = b"signed-encrypted-archive\0" * 50_000
            changed_encrypted = b"changed-encrypted-archive\0" * 50_000
            info = processed_info_bytes()
            evidence = evidence_fixture(head, original_encrypted, info)
            bundle = write_bundle(
                temporary, evidence, changed_encrypted, info
            )
            artifact = artifact_record(bundle, head)
            parsed, blockers = VALIDATOR.validate_evidence_bundle_zip(
                bundle,
                artifact,
                manifest(),
                REPOSITORY,
                temporary / "inner-mismatch",
            )
            self.assertIsNotNone(parsed)
            self.assertTrue(any("actual file mismatch" in item for item in blockers))

    def test_digest_valid_but_unrelated_member_and_false_upload_are_rejected(self) -> None:
        head = repository_head()
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            encrypted = b"signed-encrypted-archive\0" * 50_000
            info = processed_info_bytes()
            evidence = evidence_fixture(head, encrypted, info)
            extra_bundle = write_bundle(
                temporary, evidence, encrypted, info, extra_member=True
            )
            extra_artifact = artifact_record(extra_bundle, head)
            parsed, blockers = VALIDATOR.validate_evidence_bundle_zip(
                extra_bundle,
                extra_artifact,
                manifest(),
                REPOSITORY,
                temporary / "extra",
            )
            self.assertIsNone(parsed)
            self.assertTrue(any("allowlist" in item for item in blockers))

        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            encrypted = b"signed-encrypted-archive\0" * 50_000
            info = processed_info_bytes()
            evidence = evidence_fixture(head, encrypted, info)
            evidence["ci_run"]["inputs"]["upload_to_testflight"] = False
            evidence["ci_run"]["upload_to_testflight"] = False
            evidence["ci_run"]["app_store_upload_passed"] = False
            bundle = write_bundle(temporary, evidence, encrypted, info)
            artifact = artifact_record(bundle, head)
            parsed, blockers = VALIDATOR.validate_evidence_bundle_zip(
                bundle, artifact, manifest(), REPOSITORY, temporary / "false-upload"
            )
            self.assertIsNotNone(parsed)
            self.assertTrue(any("upload_to_testflight" in item for item in blockers))
            self.assertTrue(any("app_store_upload_passed" in item for item in blockers))

    def test_bundle_rejects_oversized_manifest_and_plist_before_parsing(self) -> None:
        head = repository_head()
        encrypted = b"signed-encrypted-archive\0" * 50_000
        info = processed_info_bytes()
        evidence = evidence_fixture(head, encrypted, info)
        evidence["padding"] = "x" * VALIDATOR.MAXIMUM_EVIDENCE_MANIFEST_BYTES
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            bundle = write_bundle(temporary, evidence, encrypted, info)
            artifact = artifact_record(bundle, head)
            parsed, blockers = VALIDATOR.validate_evidence_bundle_zip(
                bundle, artifact, manifest(), REPOSITORY, temporary / "manifest"
            )
            self.assertIsNone(parsed)
            self.assertTrue(any("manifest size" in item for item in blockers))

        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            oversized_info = b"x" * (VALIDATOR.MAXIMUM_PROCESSED_INFO_BYTES + 1)
            evidence = evidence_fixture(head, encrypted, oversized_info)
            bundle = write_bundle(temporary, evidence, encrypted, oversized_info)
            artifact = artifact_record(bundle, head)
            parsed, blockers = VALIDATOR.validate_evidence_bundle_zip(
                bundle, artifact, manifest(), REPOSITORY, temporary / "plist"
            )
            self.assertIsNone(parsed)
            self.assertTrue(any("plist size" in item for item in blockers))

    def test_bundle_rejects_duplicate_traversal_symlink_and_zip_bomb(self) -> None:
        head = repository_head()
        encrypted = b"signed-encrypted-archive\0" * 50_000
        info = processed_info_bytes()
        evidence_bytes = json.dumps(
            evidence_fixture(head, encrypted, info), ensure_ascii=False
        ).encode("utf-8")

        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            bundle = temporary / "duplicate.zip"
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                    archive.writestr(VALIDATOR.EXPECTED_EVIDENCE_FILENAME, evidence_bytes)
                    archive.writestr(VALIDATOR.EXPECTED_EVIDENCE_FILENAME, evidence_bytes)
                    archive.writestr(VALIDATOR.EXPECTED_PROCESSED_INFO_FILENAME, info)
                    archive.writestr(VALIDATOR.EXPECTED_ARTIFACT_FILENAME, encrypted)
            parsed, blockers = VALIDATOR.validate_evidence_bundle_zip(
                bundle,
                artifact_record(bundle, head),
                manifest(),
                REPOSITORY,
                temporary / "out",
            )
            self.assertIsNone(parsed)
            self.assertTrue(any("duplicate" in item for item in blockers))

        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            bundle = temporary / "traversal.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr(
                    "nested/../" + VALIDATOR.EXPECTED_EVIDENCE_FILENAME,
                    evidence_bytes,
                )
                archive.writestr(VALIDATOR.EXPECTED_PROCESSED_INFO_FILENAME, info)
                archive.writestr(VALIDATOR.EXPECTED_ARTIFACT_FILENAME, encrypted)
            parsed, blockers = VALIDATOR.validate_evidence_bundle_zip(
                bundle,
                artifact_record(bundle, head),
                manifest(),
                REPOSITORY,
                temporary / "out",
            )
            self.assertIsNone(parsed)
            self.assertTrue(any("allowlist" in item for item in blockers))

        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            bundle = temporary / "symlink.zip"
            symlink = zipfile.ZipInfo(VALIDATOR.EXPECTED_EVIDENCE_FILENAME)
            symlink.create_system = 3
            symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr(symlink, b"target")
                archive.writestr(VALIDATOR.EXPECTED_PROCESSED_INFO_FILENAME, info)
                archive.writestr(VALIDATOR.EXPECTED_ARTIFACT_FILENAME, encrypted)
            parsed, blockers = VALIDATOR.validate_evidence_bundle_zip(
                bundle,
                artifact_record(bundle, head),
                manifest(),
                REPOSITORY,
                temporary / "out",
            )
            self.assertIsNone(parsed)
            self.assertTrue(any("non-regular" in item for item in blockers))

        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            bundle = temporary / "bomb.zip"
            bomb = b"\0" * 11_000_000
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr(VALIDATOR.EXPECTED_EVIDENCE_FILENAME, evidence_bytes)
                archive.writestr(VALIDATOR.EXPECTED_PROCESSED_INFO_FILENAME, info)
                archive.writestr(VALIDATOR.EXPECTED_ARTIFACT_FILENAME, bomb)
            parsed, blockers = VALIDATOR.validate_evidence_bundle_zip(
                bundle,
                artifact_record(bundle, head),
                manifest(),
                REPOSITORY,
                temporary / "out",
            )
            self.assertIsNone(parsed)
            self.assertTrue(any("compression ratio" in item for item in blockers))

    def test_owner_cross_matches_remote_manifest_and_artifact_id(self) -> None:
        head = repository_head()
        encrypted = b"signed-encrypted-archive\0" * 50_000
        info = processed_info_bytes()
        evidence = evidence_fixture(head, encrypted, info)
        remote_artifact = {"id": 987654321}
        owner = valid_owner_fixture(head)
        self.assertEqual(
            [],
            VALIDATOR.validate_owner_input(
                owner, manifest(), evidence, remote_artifact
            ),
        )
        owner["selected_github_artifact_id"] = "987654322"
        blockers = VALIDATOR.validate_owner_input(
            owner, manifest(), evidence, remote_artifact
        )
        self.assertTrue(any("downloaded artifact id" in item for item in blockers))

    def test_workflow_writer_uses_event_payload_and_emits_exact_bundle_members(self) -> None:
        head = repository_head()
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            inputs = temporary / "inputs"
            inputs.mkdir()
            artifact = inputs / VALIDATOR.EXPECTED_ARTIFACT_FILENAME
            artifact.write_bytes(b"signed-encrypted-archive\0" * 50_000)
            source_info = inputs / "archive-app-info.plist"
            source_info.write_bytes(processed_info_bytes())
            event_path = inputs / "event.json"
            event_path.write_text(
                json.dumps(
                    {
                        "ref": "main",
                        "repository": {"full_name": "soso-so-27/neko-widget"},
                        "inputs": {
                            "build_number": "36",
                            "release_mode": "disabled",
                            "upload_to_testflight": "true",
                            "retain_signed_artifacts": "true",
                        },
                    }
                ),
                encoding="utf-8",
            )
            output = temporary / "output"
            environment = dict(os.environ)
            environment.update(
                {
                    "GITHUB_ACTIONS": "true",
                    "GITHUB_SHA": head,
                    "GITHUB_RUN_ID": "123456789",
                    "GITHUB_RUN_ATTEMPT": "1",
                    "GITHUB_EVENT_NAME": "workflow_dispatch",
                    "GITHUB_REPOSITORY": "soso-so-27/neko-widget",
                    "GITHUB_REF": "refs/heads/main",
                    "GITHUB_EVENT_PATH": str(event_path),
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
                    str(output),
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
            self.assertEqual(
                set(VALIDATOR.EXPECTED_BUNDLE_MEMBERS),
                {path.name for path in output.iterdir()},
            )
            evidence = json.loads(
                output.joinpath(VALIDATOR.EXPECTED_EVIDENCE_FILENAME).read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual("36", evidence["ci_run"]["inputs"]["requested_build_number"])
            self.assertTrue(evidence["ci_run"]["inputs"]["upload_to_testflight"])

            event = json.loads(event_path.read_text(encoding="utf-8"))
            event["inputs"]["release_mode"] = "media-staging"
            event_path.write_text(json.dumps(event), encoding="utf-8")
            rejected = subprocess.run(
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
                    str(temporary / "rejected"),
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
            self.assertNotEqual(0, rejected.returncode)
            self.assertIn("release_mode does not match", rejected.stderr)

            event["inputs"]["release_mode"] = "disabled"
            event["inputs"]["upload_to_testflight"] = "false"
            event_path.write_text(json.dumps(event), encoding="utf-8")
            rejected_upload = subprocess.run(
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
                    str(temporary / "rejected-upload"),
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
            self.assertNotEqual(0, rejected_upload.returncode)
            self.assertIn("upload_to_testflight does not match", rejected_upload.stderr)

            rejected_dry_run = subprocess.run(
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
                    str(temporary / "rejected-dry-run"),
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
                    "false",
                    "--retain-signed-artifacts",
                    "true",
                ],
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
                env=environment,
            )
            self.assertNotEqual(0, rejected_dry_run.returncode)
            self.assertIn("requires a successful TestFlight upload", rejected_dry_run.stderr)

    def test_private_files_and_workflows_use_remote_single_bundle_contract(self) -> None:
        ignored = GITIGNORE.read_text(encoding="utf-8")
        self.assertIn("local-only-owner-input.json", ignored)
        self.assertIn("local-only-contact-approval.json", ignored)
        copy_workflow = COPY_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("python3 ci/test-app-store-local-only-readiness.py", copy_workflow)
        release_workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(
            "if: ${{ inputs.retain_signed_artifacts && "
            "(inputs.release_mode != 'disabled' || !inputs.upload_to_testflight) }}",
            release_workflow,
        )
        self.assertIn(
            "inputs.release_mode == 'disabled' && inputs.upload_to_testflight "
            "&& inputs.retain_signed_artifacts",
            release_workflow,
        )
        self.assertIn("path: ${{ runner.temp }}/local-only-release-evidence/", release_workflow)
        self.assertIn("compression-level: 0", release_workflow)
        upload_index = release_workflow.index("Validate and upload IPA to TestFlight")
        writer_index = release_workflow.index("Write local-only signed release evidence")
        final_bundle_index = release_workflow.index("Upload local-only signed release evidence")
        failure_archive_index = release_workflow.index(
            "Preserve encrypted local-only archive after failure"
        )
        self.assertLess(upload_index, writer_index)
        self.assertLess(writer_index, final_bundle_index)
        self.assertLess(final_bundle_index, failure_archive_index)
        self.assertIn(
            "if: ${{ failure() && inputs.retain_signed_artifacts && "
            "inputs.release_mode == 'disabled' && inputs.upload_to_testflight }}",
            release_workflow,
        )
        self.assertIn(
            "nekowidget-failed-local-only-signed-artifacts-${{ github.run_id }}-"
            "${{ github.run_attempt }}",
            release_workflow,
        )
        self.assertIn("if-no-files-found: warn", release_workflow)
        writer = WRITER.read_text(encoding="utf-8")
        self.assertIn('os.environ.get("GITHUB_EVENT_PATH")', writer)
        self.assertIn('"GITHUB_REF": "refs/heads/main"', writer)
        validator = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn('parser.add_argument("--release-evidence"', validator)
        self.assertNotIn('parser.add_argument("--signed-artifact"', validator)
        self.assertNotIn('parser.add_argument("--processed-app-info"', validator)
        readme = README.read_text(encoding="utf-8")
        self.assertIn("local-only-contact-approval.json", readme)
        self.assertIn("selected_github_run_id", readme)
        self.assertIn("selected_github_artifact_id", readme)
        self.assertIn("validator自身がGitHub API", readme)
        self.assertIn("固定3 member", readme)
        self.assertIn("Build dry-runの保管専用", readme)
        self.assertIn("validatorも`nekowidget-signed-artifacts-*`", readme)
        self.assertIn("`<a href>`", readme)
        self.assertIn("`<form>`自体へmarker", readme)
        self.assertNotIn("--release-evidence", readme)
        self.assertNotIn("--signed-artifact", readme)
        self.assertNotIn("--processed-app-info", readme)


if __name__ == "__main__":
    unittest.main()
