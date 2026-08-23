#!/usr/bin/env python3
"""Regression tests for the local-only Japanese App Store metadata pack."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[1]
REPOSITORY = PROJECT.parent
SCRIPT = PROJECT / "ci" / "validate-app-store-local-only-readiness.py"
MANIFEST = PROJECT / "docs" / "app-store" / "local-only-ja.json"
OWNER_EXAMPLE = (
    PROJECT / "docs" / "app-store" / "local-only-owner-input.example.json"
)
README = PROJECT / "docs" / "app-store" / "README.md"
SUPPORT_PAGE = REPOSITORY / "docs" / "app" / "support" / "index.html"
GITIGNORE = REPOSITORY / ".gitignore"
WORKFLOW = REPOSITORY / ".github" / "workflows" / "ios-build.yml"

SPEC = importlib.util.spec_from_file_location("app_store_readiness", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not import {SCRIPT}")
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


def manifest() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


def complete_owner_input() -> dict:
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
        "age_rating_result": "owner-recorded-result",
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
        "export_compliance_result": "owner-recorded-result",
        "final_archive_release_mode": "disabled",
        "selected_version": "1.0",
        "selected_build": "36",
        "selected_git_commit": "a" * 40,
        "pricing": "free",
        "tax_category_confirmed": True,
        "territories_confirmed": True,
        "release_method": "manual",
        "final_owner_submit_approval": True,
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

    def test_owner_example_is_complete_but_explicitly_unanswered(self) -> None:
        value = json.loads(OWNER_EXAMPLE.read_text(encoding="utf-8"))
        self.assertEqual(set(VALIDATOR.OWNER_KEYS), set(value))
        self.assertTrue(all(answer is None for answer in value.values()))
        blockers = VALIDATOR.validate_owner_input(value, manifest())
        self.assertIn(
            "owner.age_rating_questionnaire_completed: must be explicitly true",
            blockers,
        )
        self.assertIn(
            "owner.export_compliance_completed: must be explicitly true", blockers
        )
        self.assertIn(
            "owner.private_privacy_contact_published: must be explicitly true",
            blockers,
        )

    def test_missing_owner_input_is_red_and_copy_only_is_valid(self) -> None:
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
            missing = Path(directory) / "missing-owner.json"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--owner-input",
                    str(missing),
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
        self.assertIn("owner_input_file: missing", payload["blockers"][0])

    def test_complete_owner_input_can_be_green_after_public_page_gate_is_fixed(self) -> None:
        owner = complete_owner_input()
        self.assertEqual([], VALIDATOR.validate_owner_input(owner, manifest()))
        self.assertNotIn("email", "\n".join(str(value) for value in owner.values()).lower())
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            owner_path = temporary / "owner.json"
            owner_path.write_text(
                json.dumps(owner, ensure_ascii=False), encoding="utf-8"
            )
            site_root = temporary / "app"
            (site_root / "support").mkdir(parents=True)
            (site_root / "privacy").mkdir(parents=True)
            (site_root / "support" / "index.html").write_text(
                "<html><body>Owner-verified support contact page.</body></html>",
                encoding="utf-8",
            )
            (site_root / "privacy" / "index.html").write_text(
                "<html><body>Owner-verified privacy contact page.</body></html>",
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--owner-input",
                    str(owner_path),
                    "--site-root",
                    str(site_root),
                    "--json",
                ],
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
            )
        self.assertEqual(0, result.returncode, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual("GREEN", payload["status"])
        self.assertTrue(payload["submission_ready"])

    def test_privacy_age_export_and_final_approval_each_fail_closed(self) -> None:
        for key in (
            "private_privacy_contact_published",
            "age_rating_questionnaire_completed",
            "export_compliance_completed",
            "final_owner_submit_approval",
        ):
            owner = complete_owner_input()
            owner[key] = False
            blockers = VALIDATOR.validate_owner_input(owner, manifest())
            with self.subTest(key=key):
                self.assertIn(f"owner.{key}: must be explicitly true", blockers)

    def test_copy_validator_rejects_over_limit_mismatch_and_fake_url(self) -> None:
        value = manifest()
        value["metadata"]["subtitle"] = "猫" * 31
        self.assertTrue(
            any("subtitle" in error for error in VALIDATOR.validate_copy(value))
        )

        value = manifest()
        value["metadata"]["keywords"] = "猫写真," * 30
        self.assertTrue(
            any("keywords" in error for error in VALIDATOR.validate_copy(value))
        )

        value = manifest()
        value["metadata"]["support_url"] = "https://localhost/support/"
        errors = VALIDATOR.validate_copy(value)
        self.assertTrue(any("support_url" in error for error in errors))

        value = manifest()
        value["verified_facts"]["network_photo_sharing"] = True
        self.assertIn(
            "verified_facts: exact local-only fact contract does not match",
            VALIDATOR.validate_copy(value),
        )

        value = manifest()
        value["metadata"] = []
        self.assertTrue(VALIDATOR.validate_copy(value))
        self.assertEqual(0, VALIDATOR.metadata_counts(value)["description_characters"])

    def test_private_owner_file_is_ignored_and_ci_runs_tests(self) -> None:
        ignored = "NekoWidget/docs/app-store/local-only-owner-input.json"
        self.assertIn(ignored, GITIGNORE.read_text(encoding="utf-8"))
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("python3 ci/test-app-store-local-only-readiness.py", workflow)

    def test_current_public_support_page_keeps_contact_gate_visibly_red(self) -> None:
        source = SUPPORT_PAGE.read_text(encoding="utf-8")
        self.assertIn("非公開のプライバシー問い合わせ窓口は現在未掲載", source)
        self.assertIn("一般公開の提出準備は完了していません", source)
        blockers = VALIDATOR.validate_publication_gate(REPOSITORY / "docs" / "app")
        self.assertTrue(any("public_support_page" in blocker for blocker in blockers))
        self.assertTrue(any("public_privacy_page" in blocker for blocker in blockers))


if __name__ == "__main__":
    unittest.main()
