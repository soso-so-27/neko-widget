#!/usr/bin/env python3
"""Validate the Japanese local-only App Store copy and owner-only release gates.

Copy can be validated in CI without private data. Submission readiness is
fail-closed: a missing owner file, null answer, or false approval is RED.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = PROJECT / "docs" / "app-store" / "local-only-ja.json"
DEFAULT_OWNER_INPUT = PROJECT / "docs" / "app-store" / "local-only-owner-input.json"
DEFAULT_SITE_ROOT = PROJECT.parent / "docs" / "app"

EXPECTED_PRIVACY_URL = "https://soso-so-27.github.io/neko-widget/app/privacy/"
EXPECTED_SUPPORT_URL = "https://soso-so-27.github.io/neko-widget/app/support/"

CHARACTER_LIMITS = {
    "app_name": 30,
    "subtitle": 30,
    "promotional_text": 170,
    "description": 4_000,
    "whats_new": 4_000,
}
BYTE_LIMITS = {
    "keywords": 100,
    "review_notes": 4_000,
}

OWNER_KEYS = (
    "app_name_confirmed_in_connect",
    "bundle_id_and_sku_confirmed",
    "primary_language",
    "primary_category",
    "content_rights_confirmed",
    "license_agreement_confirmed",
    "dsa_status_completed",
    "regional_availability_requirements_completed",
    "made_for_kids",
    "age_rating_questionnaire_completed",
    "age_rating_result",
    "app_privacy_reconciled_with_final_archive",
    "app_privacy_answers_published",
    "privacy_policy_url_saved_in_connect",
    "support_url_saved_in_connect",
    "public_support_contact_published",
    "private_privacy_contact_published",
    "review_contact_entered_in_connect",
    "copyright",
    "screenshot_set_approved",
    "export_compliance_completed",
    "export_compliance_result",
    "final_archive_release_mode",
    "selected_version",
    "selected_build",
    "selected_git_commit",
    "pricing",
    "tax_category_confirmed",
    "territories_confirmed",
    "release_method",
    "final_owner_submit_approval",
)

TRUE_OWNER_GATES = (
    "app_name_confirmed_in_connect",
    "bundle_id_and_sku_confirmed",
    "content_rights_confirmed",
    "license_agreement_confirmed",
    "dsa_status_completed",
    "regional_availability_requirements_completed",
    "age_rating_questionnaire_completed",
    "app_privacy_reconciled_with_final_archive",
    "app_privacy_answers_published",
    "privacy_policy_url_saved_in_connect",
    "support_url_saved_in_connect",
    "public_support_contact_published",
    "private_privacy_contact_published",
    "review_contact_entered_in_connect",
    "screenshot_set_approved",
    "export_compliance_completed",
    "tax_category_confirmed",
    "territories_confirmed",
    "final_owner_submit_approval",
)

NONEMPTY_OWNER_FIELDS = (
    "primary_language",
    "primary_category",
    "age_rating_result",
    "copyright",
    "export_compliance_result",
    "selected_build",
)

OWNER_ENUMS = {
    "made_for_kids": {"yes", "no"},
    "final_archive_release_mode": {"disabled"},
    "pricing": {"free", "paid"},
    "release_method": {"manual", "automatic", "automatic_no_earlier_than"},
}

PLACEHOLDERS = (
    "【",
    "】",
    "todo",
    "tbd",
    "replace-me",
    "your-email",
    "example.com",
    "gmail.com",
)


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("root must be a JSON object")
    return value


def public_https_error(value: Any) -> str | None:
    if not isinstance(value, str) or not value:
        return "must be a non-empty string"
    if any(character.isspace() or ord(character) < 0x20 for character in value):
        return "must not contain whitespace or control characters"
    parsed = urlparse(value)
    if parsed.scheme != "https":
        return "must use https"
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        return "must not contain credentials, query, or fragment"
    hostname = (parsed.hostname or "").lower().rstrip(".")
    if not hostname or "." not in hostname:
        return "must use a public DNS hostname"
    if hostname == "localhost" or hostname.endswith((".localhost", ".local", ".invalid")):
        return "must not use a local or reserved hostname"
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        pass
    else:
        return "must not use an IP literal"
    return None


def metadata_counts(manifest: dict[str, Any]) -> dict[str, int]:
    metadata_value = manifest.get("metadata", {})
    review_value = manifest.get("review", {})
    metadata = metadata_value if isinstance(metadata_value, dict) else {}
    review = review_value if isinstance(review_value, dict) else {}

    def text(mapping: dict[str, Any], key: str) -> str:
        value = mapping.get(key, "")
        return value if isinstance(value, str) else ""

    return {
        "app_name_characters": len(text(metadata, "app_name")),
        "subtitle_characters": len(text(metadata, "subtitle")),
        "promotional_text_characters": len(text(metadata, "promotional_text")),
        "description_characters": len(text(metadata, "description")),
        "keywords_bytes": len(text(metadata, "keywords").encode("utf-8")),
        "review_notes_bytes": len(text(review, "notes").encode("utf-8")),
    }


def validate_copy(manifest: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if manifest.get("schema_version") != 1:
        errors.append("schema_version: expected 1")
    if manifest.get("locale") != "ja":
        errors.append("locale: expected ja")

    release = manifest.get("release")
    if not isinstance(release, dict):
        errors.append("release: missing object")
        release = {}
    expected_release = {
        "boundary": "local-only-disabled",
        "sharing_release_mode": "disabled",
        "is_initial_version": True,
        "version_candidate": "1.0",
    }
    for key, expected in expected_release.items():
        if release.get(key) != expected:
            errors.append(f"release.{key}: expected {expected!r}")

    metadata = manifest.get("metadata")
    if not isinstance(metadata, dict):
        errors.append("metadata: missing object")
        metadata = {}
    required_metadata = (
        "app_name",
        "subtitle",
        "promotional_text",
        "description",
        "keywords",
        "support_url",
        "privacy_policy_url",
        "marketing_url",
        "whats_new",
    )
    for key in required_metadata:
        if key not in metadata:
            errors.append(f"metadata.{key}: missing")
        elif not isinstance(metadata[key], str):
            errors.append(f"metadata.{key}: must be a string")

    for key, limit in CHARACTER_LIMITS.items():
        value = metadata.get(key, "")
        if not isinstance(value, str):
            continue
        if key in {"app_name", "subtitle", "description"} and not value.strip():
            errors.append(f"metadata.{key}: must not be empty")
        if len(value) > limit:
            errors.append(f"metadata.{key}: {len(value)} characters exceeds {limit}")
    app_name = metadata.get("app_name", "")
    if isinstance(app_name, str) and app_name and len(app_name) < 2:
        errors.append("metadata.app_name: must contain at least 2 characters")

    keywords = metadata.get("keywords", "")
    if isinstance(keywords, str):
        encoded_length = len(keywords.encode("utf-8"))
        if not keywords:
            errors.append("metadata.keywords: must not be empty")
        if encoded_length > BYTE_LIMITS["keywords"]:
            errors.append(
                f"metadata.keywords: {encoded_length} bytes exceeds "
                f"{BYTE_LIMITS['keywords']}"
            )
        terms = [term.strip() for term in keywords.split(",")]
        if any(not term for term in terms):
            errors.append("metadata.keywords: contains an empty term")
        if any(len(term) < 3 for term in terms if term):
            errors.append("metadata.keywords: every term must contain at least 3 characters")
        folded = [term.casefold() for term in terms]
        if len(folded) != len(set(folded)):
            errors.append("metadata.keywords: duplicate term")
        if isinstance(app_name, str) and app_name.casefold() in folded:
            errors.append("metadata.keywords: must not duplicate the App name")

    for key, expected in (
        ("privacy_policy_url", EXPECTED_PRIVACY_URL),
        ("support_url", EXPECTED_SUPPORT_URL),
    ):
        value = metadata.get(key)
        if value != expected:
            errors.append(f"metadata.{key}: expected {expected}")
        if (url_error := public_https_error(value)) is not None:
            errors.append(f"metadata.{key}: {url_error}")
    marketing_url = metadata.get("marketing_url")
    if marketing_url and (url_error := public_https_error(marketing_url)) is not None:
        errors.append(f"metadata.marketing_url: {url_error}")
    if release.get("is_initial_version") is True and metadata.get("whats_new"):
        errors.append("metadata.whats_new: must be empty for the initial version pack")

    review = manifest.get("review")
    if not isinstance(review, dict):
        errors.append("review: missing object")
        review = {}
    if review.get("sign_in_required") is not False:
        errors.append("review.sign_in_required: expected false")
    notes = review.get("notes")
    if not isinstance(notes, str) or not notes.strip():
        errors.append("review.notes: must be a non-empty string")
        notes = ""
    notes_bytes = len(notes.encode("utf-8"))
    if notes_bytes > BYTE_LIMITS["review_notes"]:
        errors.append(
            f"review.notes: {notes_bytes} bytes exceeds {BYTE_LIMITS['review_notes']}"
        )

    plain_text_fields = (
        metadata.get("app_name", ""),
        metadata.get("subtitle", ""),
        metadata.get("promotional_text", ""),
        metadata.get("description", ""),
        notes,
    )
    combined = "\n".join(value for value in plain_text_fields if isinstance(value, str))
    lowered = combined.casefold()
    for placeholder in PLACEHOLDERS:
        if placeholder in lowered:
            errors.append(f"copy: forbidden placeholder or personal address fragment {placeholder!r}")
    if re.search(r"<\s*/?\s*[a-z][^>]*>", combined, flags=re.IGNORECASE):
        errors.append("copy: HTML is not allowed")

    description = metadata.get("description", "")
    if isinstance(description, str):
        for phrase in (
            "端末内で判定",
            "ウィジェット",
            "肉球",
            "1〜30枚",
            "写真送信、招待、受信",
            "ありません",
            "開発者のサーバーへ自動送信しません",
            "元の写真を削除・移動しません",
        ):
            if phrase not in description:
                errors.append(f"metadata.description: missing capability boundary {phrase!r}")
    for phrase in (
        "完全ローカル版",
        "デモアカウントは不要",
        "ネットワーク写真共有、招待、送信、受信、共有履歴を無効",
        "開発者サーバーへの自動通信",
        "ありません",
    ):
        if phrase not in notes:
            errors.append(f"review.notes: missing capability boundary {phrase!r}")

    expected_facts = {
        "photo_classification_on_device": True,
        "widget_derivatives_on_device": True,
        "pdf_generation_on_device": True,
        "developer_server_automatic_communication": False,
        "network_photo_sharing": False,
        "account_or_sign_in": False,
        "advertising": False,
        "tracking": False,
        "deletes_original_photos": False,
        "photos_album_membership_changes_only_after_user_action": True,
    }
    if manifest.get("verified_facts") != expected_facts:
        errors.append("verified_facts: exact local-only fact contract does not match")

    references = manifest.get("apple_references")
    if not isinstance(references, dict) or not references:
        errors.append("apple_references: missing object")
    else:
        for key, value in references.items():
            if not isinstance(value, str):
                errors.append(f"apple_references.{key}: must be a string")
                continue
            parsed = urlparse(value)
            if parsed.scheme != "https" or parsed.hostname != "developer.apple.com":
                errors.append(f"apple_references.{key}: must be an official Apple HTTPS URL")

    return errors


def validate_owner_input(
    owner: dict[str, Any], manifest: dict[str, Any]
) -> list[str]:
    blockers: list[str] = []
    expected_keys = set(OWNER_KEYS)
    actual_keys = set(owner)
    for key in sorted(expected_keys - actual_keys):
        blockers.append(f"owner.{key}: missing")
    for key in sorted(actual_keys - expected_keys):
        blockers.append(f"owner.{key}: unexpected field")

    for key in TRUE_OWNER_GATES:
        if owner.get(key) is not True:
            blockers.append(f"owner.{key}: must be explicitly true")
    for key in NONEMPTY_OWNER_FIELDS:
        value = owner.get(key)
        if not isinstance(value, str) or not value.strip():
            blockers.append(f"owner.{key}: must be a non-empty string")
    for key, allowed in OWNER_ENUMS.items():
        if owner.get(key) not in allowed:
            blockers.append(
                f"owner.{key}: must be one of {', '.join(sorted(allowed))}"
            )

    release_value = manifest.get("release", {})
    release = release_value if isinstance(release_value, dict) else {}
    if owner.get("selected_version") != release.get("version_candidate"):
        blockers.append(
            "owner.selected_version: must equal the metadata version candidate"
        )
    selected_build = owner.get("selected_build")
    if isinstance(selected_build, str) and selected_build.strip():
        if not re.fullmatch(r"[1-9][0-9]*", selected_build):
            blockers.append("owner.selected_build: must be a positive integer string")
    selected_commit = owner.get("selected_git_commit")
    if not isinstance(selected_commit, str) or not re.fullmatch(
        r"[0-9a-fA-F]{40}", selected_commit
    ):
        blockers.append("owner.selected_git_commit: must be a full 40-character SHA")

    return blockers


def validate_publication_gate(site_root: Path) -> list[str]:
    """Keep readiness red while the checked-in public pages say contact is missing."""
    blockers: list[str] = []
    pages = {
        "support": site_root / "support" / "index.html",
        "privacy": site_root / "privacy" / "index.html",
    }
    not_ready_phrases = (
        "非公開のプライバシー問い合わせ窓口は現在未掲載",
        "一般公開の提出準備は完了していません",
    )
    for label, path in pages.items():
        if not path.is_file():
            blockers.append(f"public_{label}_page: missing {path}")
            continue
        try:
            source = path.read_text(encoding="utf-8")
        except OSError as error:
            blockers.append(f"public_{label}_page: could not be read: {error}")
            continue
        for phrase in not_ready_phrases:
            if phrase in source:
                blockers.append(
                    f"public_{label}_page: still declares submission blocker {phrase!r}"
                )
    return blockers


def read_owner_input(path: Path) -> tuple[dict[str, Any] | None, list[str]]:
    if not path.is_file():
        return None, [
            "owner_input_file: missing; copy the example to the gitignored "
            "local-only-owner-input.json and complete every owner gate"
        ]
    try:
        return load_json(path), []
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return None, [f"owner_input_file: could not be read: {error}"]


def report_payload(
    manifest: dict[str, Any],
    copy_errors: list[str],
    owner_blockers: list[str],
    copy_only: bool,
) -> dict[str, Any]:
    blockers = list(copy_errors)
    if not copy_only:
        blockers.extend(owner_blockers)
    copy_valid = not copy_errors
    submission_ready = copy_valid and not copy_only and not owner_blockers
    if copy_only and copy_valid:
        status = "COPY_VALID"
    elif submission_ready:
        status = "GREEN"
    else:
        status = "RED"
    release_value = manifest.get("release", {})
    release = release_value if isinstance(release_value, dict) else {}
    return {
        "status": status,
        "copy_valid": copy_valid,
        "submission_ready": submission_ready,
        "release_boundary": release.get("boundary"),
        "counts": metadata_counts(manifest),
        "blockers": blockers,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--owner-input", type=Path, default=DEFAULT_OWNER_INPUT)
    parser.add_argument("--site-root", type=Path, default=DEFAULT_SITE_ROOT)
    parser.add_argument("--copy-only", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    try:
        manifest = load_json(args.manifest)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        payload = {
            "status": "RED",
            "copy_valid": False,
            "submission_ready": False,
            "release_boundary": None,
            "counts": {},
            "blockers": [f"manifest: could not be read: {error}"],
        }
        if args.json:
            print(json.dumps(payload, ensure_ascii=True, indent=2))
        else:
            print("STATUS: RED")
            print(f"- {payload['blockers'][0]}")
        return 1

    copy_errors = validate_copy(manifest)
    owner_blockers: list[str] = []
    if not args.copy_only:
        owner, read_errors = read_owner_input(args.owner_input)
        owner_blockers.extend(read_errors)
        if owner is not None:
            owner_blockers.extend(validate_owner_input(owner, manifest))
        owner_blockers.extend(validate_publication_gate(args.site_root))

    payload = report_payload(manifest, copy_errors, owner_blockers, args.copy_only)
    if args.json:
        print(json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True))
    else:
        print(f"STATUS: {payload['status']}")
        for key, value in payload["counts"].items():
            print(f"- {key}: {value}")
        for blocker in payload["blockers"]:
            print(f"- BLOCKER: {blocker}")

    if copy_errors:
        return 1
    if args.copy_only:
        return 0
    return 0 if not owner_blockers else 2


if __name__ == "__main__":
    raise SystemExit(main())
