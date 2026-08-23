#!/usr/bin/env python3
"""Validate the Japanese local-only App Store copy and owner-only release gates.

Copy can be validated in CI without private data. Submission readiness is
fail-closed: a missing owner file, null answer, or false approval is RED.
"""

from __future__ import annotations

import argparse
import hashlib
import html.parser
import ipaddress
import json
import plistlib
import re
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = PROJECT / "docs" / "app-store" / "local-only-ja.json"
DEFAULT_OWNER_INPUT = PROJECT / "docs" / "app-store" / "local-only-owner-input.json"
DEFAULT_RELEASE_EVIDENCE = (
    PROJECT / "docs" / "app-store" / "local-only-release-evidence.json"
)
DEFAULT_SITE_ROOT = PROJECT.parent / "docs" / "app"

EXPECTED_PRIVACY_URL = "https://soso-so-27.github.io/neko-widget/app/privacy/"
EXPECTED_SUPPORT_URL = "https://soso-so-27.github.io/neko-widget/app/support/"
EXPECTED_REPOSITORY = "soso-so-27/neko-widget"
EXPECTED_WORKFLOW = ".github/workflows/testflight.yml"
EXPECTED_ARCHIVE_VALIDATOR = "NekoWidget/ci/validate-sharing-release.py"
EXPECTED_APP_BUNDLE_ID = "jp.nekowidget.app"
EXPECTED_ARTIFACT_FILENAME = "NekoWidget-signed-artifacts.tar.gz.enc"
EXPECTED_PROCESSED_INFO_FILENAME = "NekoWidget-processed-app-info.plist"
MINIMUM_SIGNED_ARTIFACT_BYTES = 1_000_000
GITHUB_API_VERSION = "2022-11-28"
CONTACT_READY_MARKER = "neko-app-store-contact-ready"
PRIVATE_CONTACT_MARKER = "data-neko-private-contact"

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
    "release_workflow_conclusion_success_confirmed",
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
    "release_workflow_conclusion_success_confirmed",
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
    "owner-recorded-result",
)

EVIDENCE_PLACEHOLDERS = (
    "todo",
    "tbd",
    "placeholder",
    "replace-me",
    "owner-recorded-result",
    "example.com",
    "not resolved",
    "unknown",
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
    if hostname in {"localhost", "example.com", "example.net", "example.org"} or hostname.endswith(
        (".localhost", ".local", ".invalid", ".example", ".test")
    ):
        return "must not use a local or reserved hostname"
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        pass
    else:
        return "must not use an IP literal"
    return None


class ContactPageParser(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.has_ready_marker = False
        self.private_contact_routes: list[tuple[str, str]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if (
            tag == "meta"
            and attributes.get("name") == CONTACT_READY_MARKER
            and attributes.get("content") == "true"
        ):
            self.has_ready_marker = True
        if attributes.get(PRIVATE_CONTACT_MARKER) != "true":
            return
        if tag == "a" and attributes.get("href"):
            kind = attributes.get("data-neko-contact-kind", "mailto")
            self.private_contact_routes.append((kind, attributes["href"] or ""))
        elif tag == "form" and attributes.get("action"):
            self.private_contact_routes.append(("form", attributes["action"] or ""))


def private_contact_route_error(kind: str, value: str) -> str | None:
    if kind == "mailto":
        parsed = urlparse(value)
        address = parsed.path
        if parsed.scheme != "mailto" or parsed.query or parsed.fragment:
            return "mailto route must be a plain mailto URL"
        if any(character.isspace() or ord(character) < 0x20 for character in address):
            return "mailto address contains whitespace or control characters"
        if address.count("@") != 1:
            return "mailto address must contain one @"
        local, domain = address.rsplit("@", 1)
        domain = domain.lower().rstrip(".")
        if not local or "." not in domain or domain.startswith(".") or domain.endswith("."):
            return "mailto address is incomplete"
        if domain in {"example.com", "example.net", "example.org"} or domain.endswith(
            (".localhost", ".local", ".invalid", ".example", ".test")
        ):
            return "mailto address uses a reserved domain"
        return None
    if kind == "form":
        return public_https_error(value)
    return "contact kind must be mailto or form"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_text(repository: Path, *arguments: str) -> str | None:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def github_json(url: str) -> Any:
    request = Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "NekoWidget-App-Store-readiness",
            "X-GitHub-Api-Version": GITHUB_API_VERSION,
        },
    )
    with urlopen(request, timeout=15) as response:
        return json.load(response)


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
    owner: dict[str, Any],
    manifest: dict[str, Any],
    release_evidence: dict[str, Any] | None = None,
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

    for key, value in owner.items():
        if not isinstance(value, str):
            continue
        lowered = value.casefold()
        for placeholder in EVIDENCE_PLACEHOLDERS:
            if placeholder in lowered:
                blockers.append(f"owner.{key}: contains placeholder {placeholder!r}")
        if re.fullmatch(r"([0-9a-fA-F])\1{39}", value):
            blockers.append(f"owner.{key}: repeated-character SHA is not evidence")

    if release_evidence is not None:
        exact_pairs = (
            ("selected_version", "version"),
            ("selected_build", "build_number"),
            ("selected_git_commit", "source_commit"),
            ("final_archive_release_mode", "release_mode"),
        )
        for owner_key, evidence_key in exact_pairs:
            if owner.get(owner_key) != release_evidence.get(evidence_key):
                blockers.append(
                    f"owner.{owner_key}: must exactly match release evidence "
                    f"{evidence_key}"
                )

    return blockers


def validate_publication_gate(site_root: Path) -> list[str]:
    """Validate only the repository's canonical App Store policy pages."""
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
        parser = ContactPageParser()
        try:
            parser.feed(source)
            parser.close()
        except ValueError as error:
            blockers.append(f"public_{label}_page: invalid HTML: {error}")
            continue
        if not parser.has_ready_marker:
            blockers.append(
                f"public_{label}_page: missing exact contact-ready meta marker "
                f"{CONTACT_READY_MARKER!r}='true'"
            )
        valid_routes = 0
        for kind, route in parser.private_contact_routes:
            route_error = private_contact_route_error(kind, route)
            if route_error is None:
                valid_routes += 1
            else:
                blockers.append(
                    f"public_{label}_page: invalid marked private contact route: "
                    f"{route_error}"
                )
        if valid_routes == 0:
            blockers.append(
                f"public_{label}_page: requires a marked private mailto or HTTPS form route"
            )
    return blockers


def nested_strings(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        result: list[str] = []
        for child in value.values():
            result.extend(nested_strings(child))
        return result
    if isinstance(value, list):
        result = []
        for child in value:
            result.extend(nested_strings(child))
        return result
    return []


def validate_release_evidence(
    evidence: dict[str, Any],
    manifest: dict[str, Any],
    repository: Path,
    evidence_path: Path,
    signed_artifact_path: Path | None = None,
    processed_app_info_path: Path | None = None,
) -> list[str]:
    """Bind readiness to one real signed disabled archive at repository HEAD."""
    blockers: list[str] = []
    expected_top_keys = {
        "schema_version",
        "generated_at_utc",
        "repository",
        "source_commit",
        "version",
        "build_number",
        "release_mode",
        "ci_run",
        "validations",
        "signed_artifact",
        "processed_app_info",
    }
    actual_top_keys = set(evidence)
    for key in sorted(expected_top_keys - actual_top_keys):
        blockers.append(f"release_evidence.{key}: missing")
    for key in sorted(actual_top_keys - expected_top_keys):
        blockers.append(f"release_evidence.{key}: unexpected field")
    if evidence.get("schema_version") != 1:
        blockers.append("release_evidence.schema_version: expected 1")
    if evidence.get("repository") != EXPECTED_REPOSITORY:
        blockers.append(
            f"release_evidence.repository: expected {EXPECTED_REPOSITORY}"
        )
    generated_at = evidence.get("generated_at_utc")
    if not isinstance(generated_at, str):
        blockers.append("release_evidence.generated_at_utc: must be a UTC timestamp")
    else:
        try:
            parsed_timestamp = datetime.strptime(generated_at, "%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            blockers.append(
                "release_evidence.generated_at_utc: expected YYYY-MM-DDTHH:MM:SSZ"
            )
        else:
            if parsed_timestamp.year < 2026:
                blockers.append("release_evidence.generated_at_utc: implausibly old")

    for value in nested_strings(evidence):
        lowered = value.casefold()
        for placeholder in EVIDENCE_PLACEHOLDERS:
            if placeholder in lowered:
                blockers.append(
                    f"release_evidence: contains placeholder {placeholder!r}"
                )

    release = manifest.get("release")
    if not isinstance(release, dict):
        release = {}
    source_commit = evidence.get("source_commit")
    if not isinstance(source_commit, str) or not re.fullmatch(
        r"[0-9a-f]{40}", source_commit
    ):
        blockers.append("release_evidence.source_commit: expected lowercase full SHA")
        source_commit = ""
    elif re.fullmatch(r"([0-9a-f])\1{39}", source_commit):
        blockers.append(
            "release_evidence.source_commit: repeated-character SHA is not evidence"
        )
    repository_head = git_text(repository, "rev-parse", "HEAD")
    if repository_head is None:
        blockers.append("release_evidence.source_commit: repository HEAD is unavailable")
    elif source_commit != repository_head:
        blockers.append(
            "release_evidence.source_commit: must exactly equal repository HEAD"
        )
    if source_commit and git_text(repository, "cat-file", "-t", source_commit) != "commit":
        blockers.append(
            "release_evidence.source_commit: commit does not exist in this repository"
        )

    version = evidence.get("version")
    if version != release.get("version_candidate"):
        blockers.append(
            "release_evidence.version: must equal metadata version candidate"
        )
    build_number = evidence.get("build_number")
    if not isinstance(build_number, str) or not re.fullmatch(
        r"[1-9][0-9]*", build_number
    ):
        blockers.append("release_evidence.build_number: expected positive integer string")
    if evidence.get("release_mode") != "disabled":
        blockers.append("release_evidence.release_mode: expected disabled")

    ci_run = evidence.get("ci_run")
    if not isinstance(ci_run, dict):
        blockers.append("release_evidence.ci_run: missing object")
        ci_run = {}
    expected_ci_keys = {
        "workflow",
        "run_id",
        "run_attempt",
        "event",
        "head_sha",
        "run_url",
        "status",
        "conclusion",
        "upload_to_testflight",
        "app_store_upload_passed",
        "retain_signed_artifacts",
    }
    if set(ci_run) != expected_ci_keys:
        blockers.append("release_evidence.ci_run: exact field contract does not match")
    if ci_run.get("workflow") != EXPECTED_WORKFLOW:
        blockers.append(
            f"release_evidence.ci_run.workflow: expected {EXPECTED_WORKFLOW}"
        )
    run_id = ci_run.get("run_id")
    if not isinstance(run_id, int) or isinstance(run_id, bool) or run_id < 1_000:
        blockers.append("release_evidence.ci_run.run_id: expected non-placeholder integer")
        run_id = None
    run_attempt = ci_run.get("run_attempt")
    if not isinstance(run_attempt, int) or isinstance(run_attempt, bool) or run_attempt < 1:
        blockers.append("release_evidence.ci_run.run_attempt: expected positive integer")
    if ci_run.get("event") != "workflow_dispatch":
        blockers.append("release_evidence.ci_run.event: expected workflow_dispatch")
    if ci_run.get("head_sha") != source_commit:
        blockers.append("release_evidence.ci_run.head_sha: must equal source_commit")
    expected_run_url = (
        f"https://github.com/{EXPECTED_REPOSITORY}/actions/runs/{run_id}"
        if run_id is not None
        else None
    )
    if ci_run.get("run_url") != expected_run_url:
        blockers.append("release_evidence.ci_run.run_url: does not match run_id")
    if ci_run.get("status") != "completed":
        blockers.append("release_evidence.ci_run.status: expected completed")
    if ci_run.get("conclusion") != "success":
        blockers.append("release_evidence.ci_run.conclusion: expected success")
    if ci_run.get("upload_to_testflight") is not True:
        blockers.append(
            "release_evidence.ci_run.upload_to_testflight: must be true for "
            "App Store submission readiness"
        )
    if ci_run.get("app_store_upload_passed") is not True:
        blockers.append(
            "release_evidence.ci_run.app_store_upload_passed: must be true"
        )
    if ci_run.get("retain_signed_artifacts") is not True:
        blockers.append(
            "release_evidence.ci_run.retain_signed_artifacts: must be true"
        )

    validations = evidence.get("validations")
    if not isinstance(validations, dict):
        blockers.append("release_evidence.validations: missing object")
        validations = {}
    expected_validation_keys = {
        "archive_validator",
        "archive_validator_passed",
        "signature_validation_passed",
        "artifact_encryption_verified",
    }
    if set(validations) != expected_validation_keys:
        blockers.append(
            "release_evidence.validations: exact field contract does not match"
        )
    if validations.get("archive_validator") != EXPECTED_ARCHIVE_VALIDATOR:
        blockers.append(
            "release_evidence.validations.archive_validator: unexpected validator"
        )
    for key in (
        "archive_validator_passed",
        "signature_validation_passed",
        "artifact_encryption_verified",
    ):
        if validations.get(key) is not True:
            blockers.append(f"release_evidence.validations.{key}: must be true")

    artifact = evidence.get("signed_artifact")
    if not isinstance(artifact, dict):
        blockers.append("release_evidence.signed_artifact: missing object")
        artifact = {}
    if set(artifact) != {"filename", "sha256", "size_bytes", "encrypted"}:
        blockers.append(
            "release_evidence.signed_artifact: exact field contract does not match"
        )
    if artifact.get("filename") != EXPECTED_ARTIFACT_FILENAME:
        blockers.append(
            f"release_evidence.signed_artifact.filename: expected "
            f"{EXPECTED_ARTIFACT_FILENAME}"
        )
    if artifact.get("encrypted") is not True:
        blockers.append("release_evidence.signed_artifact.encrypted: must be true")
    artifact_path = signed_artifact_path or (
        evidence_path.parent / EXPECTED_ARTIFACT_FILENAME
    )
    if artifact_path.name != EXPECTED_ARTIFACT_FILENAME:
        blockers.append("signed_artifact_path: filename does not match evidence")
    if not artifact_path.is_file():
        blockers.append(f"signed_artifact_path: missing {artifact_path}")
    else:
        actual_size = artifact_path.stat().st_size
        if actual_size < MINIMUM_SIGNED_ARTIFACT_BYTES:
            blockers.append(
                "signed_artifact_path: too small to be the encrypted signed app archive"
            )
        if artifact.get("size_bytes") != actual_size:
            blockers.append(
                "release_evidence.signed_artifact.size_bytes: actual file mismatch"
            )
        actual_sha = sha256_file(artifact_path)
        if artifact.get("sha256") != actual_sha:
            blockers.append(
                "release_evidence.signed_artifact.sha256: actual file mismatch"
            )

    processed = evidence.get("processed_app_info")
    if not isinstance(processed, dict):
        blockers.append("release_evidence.processed_app_info: missing object")
        processed = {}
    if set(processed) != {"filename", "sha256"}:
        blockers.append(
            "release_evidence.processed_app_info: exact field contract does not match"
        )
    if processed.get("filename") != EXPECTED_PROCESSED_INFO_FILENAME:
        blockers.append(
            f"release_evidence.processed_app_info.filename: expected "
            f"{EXPECTED_PROCESSED_INFO_FILENAME}"
        )
    info_path = processed_app_info_path or (
        evidence_path.parent / EXPECTED_PROCESSED_INFO_FILENAME
    )
    if info_path.name != EXPECTED_PROCESSED_INFO_FILENAME:
        blockers.append("processed_app_info_path: filename does not match evidence")
    if not info_path.is_file():
        blockers.append(f"processed_app_info_path: missing {info_path}")
    else:
        actual_info_sha = sha256_file(info_path)
        if processed.get("sha256") != actual_info_sha:
            blockers.append(
                "release_evidence.processed_app_info.sha256: actual file mismatch"
            )
        try:
            info = plistlib.loads(info_path.read_bytes())
        except (OSError, plistlib.InvalidFileException) as error:
            blockers.append(f"processed_app_info_path: invalid plist: {error}")
            info = {}
        if not isinstance(info, dict):
            blockers.append("processed_app_info_path: root must be a dictionary")
            info = {}
        expected_info = {
            "CFBundleIdentifier": EXPECTED_APP_BUNDLE_ID,
            "CFBundleDisplayName": "ねこのまど",
            "CFBundleShortVersionString": version,
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
            "AppPrivacyURL": EXPECTED_PRIVACY_URL,
            "AppSupportURL": EXPECTED_SUPPORT_URL,
            "ITSAppUsesNonExemptEncryption": False,
        }
        for key, expected in expected_info.items():
            if info.get(key) != expected:
                blockers.append(
                    f"processed_app_info.{key}: expected exact value {expected!r}"
                )

    return blockers


def validate_github_run_records(
    evidence: dict[str, Any],
    run_record: Any,
    artifacts_record: Any,
) -> list[str]:
    """Cross-check the manifest against GitHub's final, public run records."""
    blockers: list[str] = []
    ci_run_value = evidence.get("ci_run")
    ci_run = ci_run_value if isinstance(ci_run_value, dict) else {}
    source_commit = evidence.get("source_commit")
    run_id = ci_run.get("run_id")
    run_attempt = ci_run.get("run_attempt")
    if not isinstance(run_record, dict):
        return ["github_run: API response must be an object"]

    expected_run = {
        "id": run_id,
        "event": "workflow_dispatch",
        "head_sha": source_commit,
        "head_branch": "main",
        "run_attempt": run_attempt,
        "status": "completed",
        "conclusion": "success",
        "html_url": ci_run.get("run_url"),
    }
    for key, expected in expected_run.items():
        if run_record.get(key) != expected:
            blockers.append(
                f"github_run.{key}: must exactly match release evidence/final run"
            )
    path = run_record.get("path")
    if path not in {EXPECTED_WORKFLOW, f"{EXPECTED_WORKFLOW}@main"}:
        blockers.append(f"github_run.path: expected {EXPECTED_WORKFLOW} on main")
    repository = run_record.get("repository")
    if not isinstance(repository, dict) or repository.get("full_name") != EXPECTED_REPOSITORY:
        blockers.append(f"github_run.repository: expected {EXPECTED_REPOSITORY}")

    if not isinstance(artifacts_record, dict):
        blockers.append("github_artifacts: API response must be an object")
        return blockers
    artifacts = artifacts_record.get("artifacts")
    if not isinstance(artifacts, list):
        blockers.append("github_artifacts.artifacts: expected a list")
        return blockers
    expected_names = {
        f"nekowidget-signed-artifacts-{run_id}-{run_attempt}",
        f"nekowidget-local-only-release-evidence-{run_id}-{run_attempt}",
    }
    usable_names: set[str] = set()
    for artifact in artifacts:
        if not isinstance(artifact, dict) or artifact.get("name") not in expected_names:
            continue
        if artifact.get("expired") is not False:
            blockers.append(
                f"github_artifacts.{artifact.get('name')}: artifact is expired"
            )
            continue
        artifact_id = artifact.get("id")
        if not isinstance(artifact_id, int) or isinstance(artifact_id, bool) or artifact_id < 1:
            blockers.append(
                f"github_artifacts.{artifact.get('name')}: invalid artifact id"
            )
            continue
        size = artifact.get("size_in_bytes")
        minimum_size = (
            MINIMUM_SIGNED_ARTIFACT_BYTES
            if artifact.get("name", "").startswith("nekowidget-signed-artifacts-")
            else 1_024
        )
        if not isinstance(size, int) or isinstance(size, bool) or size < minimum_size:
            blockers.append(
                f"github_artifacts.{artifact.get('name')}: implausible artifact size"
            )
            continue
        digest = artifact.get("digest")
        if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            blockers.append(
                f"github_artifacts.{artifact.get('name')}: missing SHA-256 digest"
            )
            continue
        if re.fullmatch(r"sha256:([0-9a-f])\1{63}", digest):
            blockers.append(
                f"github_artifacts.{artifact.get('name')}: placeholder SHA-256 digest"
            )
            continue
        workflow_run = artifact.get("workflow_run")
        if not isinstance(workflow_run, dict):
            blockers.append(
                f"github_artifacts.{artifact.get('name')}: missing workflow_run"
            )
            continue
        if workflow_run.get("id") != run_id or workflow_run.get("head_sha") != source_commit:
            blockers.append(
                f"github_artifacts.{artifact.get('name')}: run/SHA mismatch"
            )
            continue
        usable_names.add(artifact["name"])
    for name in sorted(expected_names - usable_names):
        blockers.append(f"github_artifacts.{name}: live run artifact not found")
    return blockers


def validate_remote_release_run(evidence: dict[str, Any]) -> list[str]:
    """Fail closed unless GitHub confirms the run completed successfully."""
    ci_run_value = evidence.get("ci_run")
    ci_run = ci_run_value if isinstance(ci_run_value, dict) else {}
    run_id = ci_run.get("run_id")
    if not isinstance(run_id, int) or isinstance(run_id, bool):
        return ["github_run: a valid run_id is required before remote verification"]
    base = f"https://api.github.com/repos/{EXPECTED_REPOSITORY}/actions/runs/{run_id}"
    try:
        run_record = github_json(base)
        artifacts_record = github_json(f"{base}/artifacts?per_page=100")
    except (HTTPError, URLError, OSError, TimeoutError, ValueError) as error:
        return [f"github_run: could not verify final public Actions evidence: {error}"]
    return validate_github_run_records(evidence, run_record, artifacts_record)


def read_release_evidence(path: Path) -> tuple[dict[str, Any] | None, list[str]]:
    if not path.is_file():
        return None, [
            "release_evidence_file: missing; a workflow-generated signed archive "
            "evidence manifest is required"
        ]
    try:
        return load_json(path), []
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return None, [f"release_evidence_file: could not be read: {error}"]


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
    parser.add_argument(
        "--release-evidence", type=Path, default=DEFAULT_RELEASE_EVIDENCE
    )
    parser.add_argument("--signed-artifact", type=Path)
    parser.add_argument("--processed-app-info", type=Path)
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
        evidence, evidence_read_errors = read_release_evidence(args.release_evidence)
        owner_blockers.extend(evidence_read_errors)
        if evidence is not None:
            owner_blockers.extend(
                validate_release_evidence(
                    evidence,
                    manifest,
                    PROJECT.parent,
                    args.release_evidence,
                    args.signed_artifact,
                    args.processed_app_info,
                )
            )
            owner_blockers.extend(validate_remote_release_run(evidence))
        owner, read_errors = read_owner_input(args.owner_input)
        owner_blockers.extend(read_errors)
        if owner is not None:
            owner_blockers.extend(validate_owner_input(owner, manifest, evidence))
        owner_blockers.extend(validate_publication_gate(DEFAULT_SITE_ROOT))

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
