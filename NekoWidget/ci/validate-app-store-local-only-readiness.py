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
import os
import plistlib
import re
import shutil
import socket
import stat
import subprocess
import tempfile
import unicodedata
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener


PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = PROJECT / "docs" / "app-store" / "local-only-ja.json"
DEFAULT_OWNER_INPUT = PROJECT / "docs" / "app-store" / "local-only-owner-input.json"
DEFAULT_CONTACT_APPROVAL = (
    PROJECT / "docs" / "app-store" / "local-only-contact-approval.json"
)
DEFAULT_SITE_ROOT = PROJECT.parent / "docs" / "app"
CANONICAL_RELEASE_SOURCE_PATHS = (
    "NekoWidget/docs/app-store/local-only-ja.json",
    "docs/app/support/index.html",
    "docs/app/privacy/index.html",
)

EXPECTED_PRIVACY_URL = "https://soso-so-27.github.io/neko-widget/app/privacy/"
EXPECTED_SUPPORT_URL = "https://soso-so-27.github.io/neko-widget/app/support/"
EXPECTED_REPOSITORY = "soso-so-27/neko-widget"
EXPECTED_WORKFLOW = ".github/workflows/testflight.yml"
EXPECTED_ARCHIVE_VALIDATOR = "NekoWidget/ci/validate-sharing-release.py"
EXPECTED_APP_BUNDLE_ID = "jp.nekowidget.app"
EXPECTED_ARTIFACT_FILENAME = "NekoWidget-signed-artifacts.tar.gz.enc"
EXPECTED_PROCESSED_INFO_FILENAME = "NekoWidget-processed-app-info.plist"
EXPECTED_EVIDENCE_FILENAME = "local-only-release-evidence.json"
EXPECTED_BUNDLE_MEMBERS = {
    EXPECTED_EVIDENCE_FILENAME,
    EXPECTED_PROCESSED_INFO_FILENAME,
    EXPECTED_ARTIFACT_FILENAME,
}
MINIMUM_SIGNED_ARTIFACT_BYTES = 1_000_000
MAXIMUM_EVIDENCE_ZIP_BYTES = 2_000_000_000
MAXIMUM_EVIDENCE_MANIFEST_BYTES = 256_000
MAXIMUM_PROCESSED_INFO_BYTES = 1_000_000
CONTACT_APPROVAL_MAX_AGE_DAYS = 90
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
    "selected_github_run_id",
    "selected_github_artifact_id",
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
    "selected_github_run_id",
    "selected_github_artifact_id",
)

OWNER_ENUMS = {
    "made_for_kids": {"yes", "no"},
    "final_archive_release_mode": {"disabled"},
    "pricing": {"free", "paid"},
    "release_method": {"manual", "automatic", "automatic_no_earlier_than"},
    "age_rating_result": {"4+", "9+", "13+", "16+", "18+"},
    "export_compliance_result": {
        "no_encryption_confirmed",
        "exempt_no_documentation_required_confirmed",
        "documentation_approved",
    },
}

PLACEHOLDERS = (
    "【",
    "】",
    "本人入力",
    "connect確認",
    "権利者",
    "todo",
    "tbd",
    "to be determined",
    "to be confirmed",
    "pending",
    "not applicable",
    "n/a",
    "placeholder",
    "replace-me",
    "your-email",
    "example.com",
    "example.net",
    "example.org",
    "owner-confirmed",
    "owner confirmed",
    "owner-recorded",
    "owner recorded",
    "owner-recorded-result",
    "rights holder",
    "未入力",
    "未確定",
    "確認待ち",
)

EVIDENCE_PLACEHOLDERS = PLACEHOLDERS + (
    "not resolved",
    "unknown",
    "dummy",
    "fixture",
    "sample",
)


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("root must be a JSON object")
    return value


def matched_placeholder(value: str) -> str | None:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    compact = re.sub(r"[\W_]+", "", normalized, flags=re.UNICODE)
    for placeholder in EVIDENCE_PLACEHOLDERS:
        normalized_placeholder = unicodedata.normalize("NFKC", placeholder).casefold()
        compact_placeholder = re.sub(
            r"[\W_]+", "", normalized_placeholder, flags=re.UNICODE
        )
        compact_match = bool(compact_placeholder) and (
            compact == compact_placeholder
            or (
                len(compact_placeholder) >= 3
                and compact_placeholder in compact
            )
        )
        if normalized_placeholder in normalized or compact_match:
            return placeholder
    return None


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


def public_hostname_resolution_error(value: str) -> str | None:
    """Reject a URL before I/O unless every current DNS answer is public."""
    parsed = urlparse(value)
    hostname = parsed.hostname
    if not hostname:
        return "hostname is missing"
    try:
        answers = socket.getaddrinfo(
            hostname,
            parsed.port or 443,
            type=socket.SOCK_STREAM,
        )
    except socket.gaierror as error:
        return f"hostname could not be resolved: {error}"
    addresses = {answer[4][0] for answer in answers if answer[4]}
    if not addresses:
        return "hostname did not resolve to an address"
    for address in sorted(addresses):
        try:
            parsed_address = ipaddress.ip_address(address)
        except ValueError:
            return "hostname resolved to an invalid address"
        if not parsed_address.is_global:
            return f"hostname resolved to non-public address {address}"
    return None


def signed_download_url_error(value: Any) -> str | None:
    """Validate a short-lived GitHub artifact redirect without rejecting its query."""
    if not isinstance(value, str) or not value:
        return "redirect URL is missing"
    if any(character.isspace() or ord(character) < 0x20 for character in value):
        return "redirect URL contains whitespace or control characters"
    parsed = urlparse(value)
    if parsed.scheme != "https":
        return "redirect URL must use https"
    if parsed.username or parsed.password or parsed.fragment:
        return "redirect URL must not contain credentials or a fragment"
    hostname = (parsed.hostname or "").lower().rstrip(".")
    if not hostname or "." not in hostname:
        return "redirect URL must use a public DNS hostname"
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        pass
    else:
        return "redirect URL must not use an IP literal"
    return public_hostname_resolution_error(value)


def parse_utc_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError:
        return None


def parse_api_timestamp(value: Any) -> datetime | None:
    """Parse GitHub's RFC 3339 timestamps, including fractional seconds."""
    if not isinstance(value, str):
        return None
    candidate = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(candidate)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(timezone.utc)


class ContactPageParser(html.parser.HTMLParser):
    VOID_ELEMENTS = {
        "area",
        "base",
        "br",
        "col",
        "embed",
        "hr",
        "img",
        "input",
        "link",
        "meta",
        "param",
        "source",
        "track",
        "wbr",
    }

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.has_ready_marker = False
        self.private_contact_routes: list[tuple[str, str]] = []
        self.invalid_marked_routes: list[str] = []
        self.in_head = False
        self.in_body = False
        self.hidden_stack: list[bool] = []
        self.pending_marked_anchors: list[dict[str, Any]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "head":
            self.in_head = True
        if tag == "body":
            self.in_body = True
        if (
            tag == "meta"
            and self.in_head
            and attributes.get("name") == CONTACT_READY_MARKER
            and attributes.get("content") == "true"
        ):
            self.has_ready_marker = True
        style = (attributes.get("style") or "").replace(" ", "").lower()
        hidden = any(self.hidden_stack) or (
            "hidden" in attributes
            or attributes.get("aria-hidden") == "true"
            or "display:none" in style
            or "visibility:hidden" in style
        )
        if tag not in self.VOID_ELEMENTS:
            self.hidden_stack.append(hidden)
        if attributes.get(PRIVATE_CONTACT_MARKER) != "true":
            return
        if tag != "a" or not attributes.get("href") or hidden or not self.in_body:
            self.invalid_marked_routes.append(
                "marked contact route must be a visible anchor in body with href"
            )
            return
        self.pending_marked_anchors.append(
            {
                "kind": attributes.get("data-neko-contact-kind", "mailto"),
                "href": attributes["href"] or "",
                "aria_label": (attributes.get("aria-label") or "").strip(),
                "text": [],
            }
        )

    def handle_data(self, data: str) -> None:
        if self.pending_marked_anchors and not any(self.hidden_stack):
            self.pending_marked_anchors[-1]["text"].append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self.pending_marked_anchors:
            pending = self.pending_marked_anchors.pop()
            accessible_name = pending["aria_label"] or "".join(
                pending["text"]
            ).strip()
            if accessible_name:
                self.private_contact_routes.append(
                    (pending["kind"], pending["href"])
                )
            else:
                self.invalid_marked_routes.append(
                    "marked contact route must have visible text or aria-label"
                )
        if tag == "head":
            self.in_head = False
        if tag == "body":
            self.in_body = False
        if tag not in self.VOID_ELEMENTS and self.hidden_stack:
            self.hidden_stack.pop()

    def close(self) -> None:
        super().close()
        if self.pending_marked_anchors:
            self.invalid_marked_routes.append(
                "marked contact route must be a closed anchor"
            )
            self.pending_marked_anchors.clear()


def private_contact_route_error(kind: str, value: str) -> str | None:
    if kind == "mailto":
        parsed = urlparse(value)
        address = parsed.path
        if parsed.scheme != "mailto" or parsed.query or parsed.fragment:
            return "mailto route must be a plain mailto URL"
        if "%" in address:
            return "mailto address must not use percent encoding"
        if any(character.isspace() or ord(character) < 0x20 for character in address):
            return "mailto address contains whitespace or control characters"
        if not re.fullmatch(
            r"[A-Za-z0-9.!#$&'*+/=?^_`{|}~-]+@"
            r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+",
            address,
        ):
            return "mailto address must be one plain ASCII mailbox"
        local, domain = address.rsplit("@", 1)
        domain = domain.lower().rstrip(".")
        if (
            local.startswith(".")
            or local.endswith(".")
            or ".." in local
            or any(label.startswith("-") or label.endswith("-") for label in domain.split("."))
        ):
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


def validate_tracked_head_paths(
    repository: Path, relative_paths: tuple[str, ...]
) -> list[str]:
    """Require selected submission sources to be tracked and identical to HEAD."""
    tracked = subprocess.run(
        [
            "git",
            "-C",
            str(repository),
            "ls-files",
            "--error-unmatch",
            "--",
            *relative_paths,
        ],
        check=False,
        capture_output=True,
    )
    if tracked.returncode != 0:
        return ["release_sources: canonical submission source is not tracked at HEAD"]
    unchanged = subprocess.run(
        [
            "git",
            "-C",
            str(repository),
            "diff",
            "--quiet",
            "--no-ext-diff",
            "HEAD",
            "--",
            *relative_paths,
        ],
        check=False,
        capture_output=True,
    )
    if unchanged.returncode == 1:
        return [
            "release_sources: canonical metadata/privacy/support sources must "
            "exactly match repository HEAD"
        ]
    if unchanged.returncode != 0:
        return ["release_sources: could not compare canonical sources with HEAD"]
    return []


def validate_canonical_release_source_binding(manifest_path: Path) -> list[str]:
    try:
        selected_manifest = manifest_path.resolve()
        canonical_manifest = DEFAULT_MANIFEST.resolve()
    except OSError as error:
        return [f"manifest: could not resolve canonical path: {error}"]
    blockers: list[str] = []
    if selected_manifest != canonical_manifest:
        blockers.append(
            "manifest: non-copy readiness must use the canonical local-only-ja.json"
        )
    blockers.extend(
        validate_tracked_head_paths(PROJECT.parent, CANONICAL_RELEASE_SOURCE_PATHS)
    )
    return blockers


def github_json(url: str, token: str | None = None) -> Any:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "NekoWidget-App-Store-readiness",
        "X-GitHub-Api-Version": GITHUB_API_VERSION,
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = Request(
        url,
        headers=headers,
    )
    with build_opener(NoRedirect()).open(request, timeout=15) as response:
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
    if (placeholder := matched_placeholder(combined)) is not None:
        errors.append(
            f"copy: forbidden placeholder or personal address fragment {placeholder!r}"
        )
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
    release_artifact: dict[str, Any] | None = None,
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
    if owner.get("primary_language") != "Japanese":
        blockers.append("owner.primary_language: expected Japanese")
    if owner.get("primary_category") != "Photo & Video":
        blockers.append("owner.primary_category: expected Photo & Video")
    copyright_value = owner.get("copyright")
    copyright_match = (
        re.fullmatch(r"2026\s+(.+\S)", copyright_value)
        if isinstance(copyright_value, str)
        else None
    )
    rights_owner = copyright_match.group(1) if copyright_match else ""
    normalized_rights_owner = unicodedata.normalize(
        "NFKC", rights_owner
    ).casefold()
    compact_rights_owner = "".join(
        character for character in normalized_rights_owner if character.isalnum()
    )
    junk_rights_owners = {
        "x",
        "xx",
        "xxx",
        "foo",
        "bar",
        "test",
        "sample",
        "dummy",
        "example",
        "owner",
        "appowner",
        "rightsowner",
    }
    junk_rights_tokens = {
        "app",
        "bar",
        "company",
        "dummy",
        "example",
        "foo",
        "here",
        "holder",
        "name",
        "owner",
        "rights",
        "sample",
        "test",
        "x",
        "xx",
        "xxx",
        "your",
    }
    rights_owner_tokens = re.findall(r"\w+", normalized_rights_owner)
    junk_rights_phrases = (
        "app owner",
        "company name",
        "name here",
        "rights holder",
        "sample owner",
        "test owner",
        "your company",
        "your name",
    )
    if (
        copyright_match is None
        or len(compact_rights_owner) < 3
        or compact_rights_owner in junk_rights_owners
        or len(set(compact_rights_owner)) < 2
        or (
            bool(rights_owner_tokens)
            and all(token in junk_rights_tokens for token in rights_owner_tokens)
        )
        or any(phrase in normalized_rights_owner for phrase in junk_rights_phrases)
    ):
        blockers.append("owner.copyright: expected '2026 <specific rights owner>'")

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
    for key in ("selected_github_run_id", "selected_github_artifact_id"):
        value = owner.get(key)
        if isinstance(value, str) and value.strip() and not re.fullmatch(
            r"[1-9][0-9]*", value
        ):
            blockers.append(f"owner.{key}: must be a positive integer string")
    selected_commit = owner.get("selected_git_commit")
    if not isinstance(selected_commit, str) or not re.fullmatch(
        r"[0-9a-fA-F]{40}", selected_commit
    ):
        blockers.append("owner.selected_git_commit: must be a full 40-character SHA")

    for key, value in owner.items():
        if not isinstance(value, str):
            continue
        placeholder = matched_placeholder(value)
        if placeholder is not None:
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
        ci_run = release_evidence.get("ci_run")
        evidence_run_id = ci_run.get("run_id") if isinstance(ci_run, dict) else None
        if owner.get("selected_github_run_id") != str(evidence_run_id):
            blockers.append(
                "owner.selected_github_run_id: must exactly match release evidence run_id"
            )
    if release_artifact is not None:
        if owner.get("selected_github_artifact_id") != str(
            release_artifact.get("id")
        ):
            blockers.append(
                "owner.selected_github_artifact_id: must exactly match downloaded artifact id"
            )

    return blockers


def placeholder_errors(value: Any, prefix: str) -> list[str]:
    errors: list[str] = []
    for text in nested_strings(value):
        placeholder = matched_placeholder(text)
        if placeholder is not None:
            errors.append(f"{prefix}: contains placeholder {placeholder!r}")
    return errors


def validate_contact_approval(approval: dict[str, Any]) -> list[str]:
    blockers: list[str] = []
    expected_keys = {
        "schema_version",
        "owner_selected_and_approved",
        "pages",
    }
    if set(approval) != expected_keys:
        blockers.append("contact_approval: exact field contract does not match")
    if approval.get("schema_version") != 1:
        blockers.append("contact_approval.schema_version: expected 1")
    if approval.get("owner_selected_and_approved") is not True:
        blockers.append(
            "contact_approval.owner_selected_and_approved: must be explicitly true"
        )
    blockers.extend(placeholder_errors(approval, "contact_approval"))
    pages = approval.get("pages")
    if not isinstance(pages, dict) or set(pages) != {"support", "privacy"}:
        blockers.append("contact_approval.pages: expected exact support/privacy records")
        pages = {}
    for label in ("support", "privacy"):
        page = pages.get(label)
        expected_page_keys = {
            "canonical_page_uri",
            "contact_kind",
            "contact_uri",
            "owner_delivery_test_completed",
            "approved_at_utc",
        }
        if not isinstance(page, dict) or set(page) != expected_page_keys:
            blockers.append(
                f"contact_approval.pages.{label}: exact field contract does not match"
            )
            page = {}
        expected_canonical = (
            EXPECTED_SUPPORT_URL if label == "support" else EXPECTED_PRIVACY_URL
        )
        if page.get("canonical_page_uri") != expected_canonical:
            blockers.append(
                f"contact_approval.pages.{label}.canonical_page_uri: expected canonical URL"
            )
        if page.get("owner_delivery_test_completed") is not True:
            blockers.append(
                f"contact_approval.pages.{label}.owner_delivery_test_completed: "
                "must be explicitly true"
            )
        approved_at = page.get("approved_at_utc")
        if not isinstance(approved_at, str):
            blockers.append(
                f"contact_approval.pages.{label}.approved_at_utc: expected UTC timestamp"
            )
        else:
            try:
                timestamp = datetime.strptime(
                    approved_at, "%Y-%m-%dT%H:%M:%SZ"
                ).replace(tzinfo=timezone.utc)
            except ValueError:
                blockers.append(
                    f"contact_approval.pages.{label}.approved_at_utc: "
                    "expected YYYY-MM-DDTHH:MM:SSZ"
                )
            else:
                if timestamp.year < 2026:
                    blockers.append(
                        f"contact_approval.pages.{label}.approved_at_utc: implausibly old"
                    )
                now = datetime.now(timezone.utc)
                if timestamp > now:
                    blockers.append(
                        f"contact_approval.pages.{label}.approved_at_utc: must not be in future"
                    )
                elif timestamp < now - timedelta(days=CONTACT_APPROVAL_MAX_AGE_DAYS):
                    blockers.append(
                        f"contact_approval.pages.{label}.approved_at_utc: "
                        f"owner delivery test is older than "
                        f"{CONTACT_APPROVAL_MAX_AGE_DAYS} days"
                    )
        uri = page.get("contact_uri")
        if not isinstance(uri, str) or not uri:
            blockers.append(f"contact_approval.pages.{label}.contact_uri: required")
            continue
        kind = page.get("contact_kind")
        expected_kind = "mailto" if urlparse(uri).scheme == "mailto" else "form"
        if kind != expected_kind:
            blockers.append(
                f"contact_approval.pages.{label}.contact_kind: URI kind mismatch"
            )
        error = private_contact_route_error(kind, uri) if isinstance(kind, str) else "invalid kind"
        if error is not None:
            blockers.append(f"contact_approval.pages.{label}.contact_uri: {error}")
    return blockers


def approved_contact_uri(approval: dict[str, Any], label: str) -> str:
    pages = approval.get("pages")
    if not isinstance(pages, dict):
        return ""
    page = pages.get(label)
    if not isinstance(page, dict):
        return ""
    uri = page.get("contact_uri")
    return uri if isinstance(uri, str) else ""


def parse_contact_page(label: str, source: str, expected_uri: str) -> list[str]:
    blockers: list[str] = []
    not_ready_phrases = (
        "非公開のプライバシー問い合わせ窓口は現在未掲載",
        "一般公開の提出準備は完了していません",
    )
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
        return [f"public_{label}_page: invalid HTML: {error}"]
    if not parser.has_ready_marker:
        blockers.append(
            f"public_{label}_page: missing exact contact-ready meta marker "
            f"{CONTACT_READY_MARKER!r}='true'"
        )
    for error in parser.invalid_marked_routes:
        blockers.append(f"public_{label}_page: {error}")
    valid_routes: list[tuple[str, str]] = []
    for kind, route in parser.private_contact_routes:
        route_error = private_contact_route_error(kind, route)
        if route_error is None:
            valid_routes.append((kind, route))
        else:
            blockers.append(
                f"public_{label}_page: invalid marked contact route: {route_error}"
            )
    expected_kind = "mailto" if urlparse(expected_uri).scheme == "mailto" else "form"
    if valid_routes != [(expected_kind, expected_uri)]:
        blockers.append(
            f"public_{label}_page: exactly one marked route must exactly match "
            "owner-approved URI and kind"
        )
    return blockers


def validate_publication_gate(
    site_root: Path, approval: dict[str, Any] | None
) -> list[str]:
    """Validate the fixed repository pages against owner-approved exact URIs."""
    blockers: list[str] = []
    pages = {
        "support": site_root / "support" / "index.html",
        "privacy": site_root / "privacy" / "index.html",
    }
    for label, path in pages.items():
        if not path.is_file():
            blockers.append(f"public_{label}_page: missing {path}")
            continue
        try:
            source = path.read_text(encoding="utf-8")
        except OSError as error:
            blockers.append(f"public_{label}_page: could not be read: {error}")
            continue
        expected_uri = ""
        if approval is not None:
            expected_uri = approved_contact_uri(approval, label)
        blockers.extend(parse_contact_page(label, source, expected_uri))
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


def fetch_public_url(url: str, include_body: bool) -> dict[str, Any]:
    if (url_error := public_https_error(url)) is not None:
        raise ValueError(f"unsafe public URL: {url_error}")
    if (resolution_error := public_hostname_resolution_error(url)) is not None:
        raise ValueError(f"unsafe public URL: {resolution_error}")
    request = Request(
        url,
        headers={
            "Accept": "text/html,application/xhtml+xml",
            "User-Agent": "NekoWidget-App-Store-readiness",
        },
    )
    with build_opener(NoRedirect()).open(request, timeout=15) as response:
        body = response.read(2_000_001 if include_body else 1)
        if include_body and len(body) > 2_000_000:
            raise ValueError("response body exceeds 2 MB")
        return {
            "requested_url": url,
            "final_url": response.geturl(),
            "status": response.status,
            "content_type": response.headers.get_content_type(),
            "body": body.decode("utf-8") if include_body else "",
        }


def validate_live_page_records(
    approval: dict[str, Any],
    records: dict[str, dict[str, Any]],
    local_sources: dict[str, str] | None = None,
) -> list[str]:
    """Pure validation for live page and HTTPS contact reachability records."""
    blockers: list[str] = []
    page_urls = {"support": EXPECTED_SUPPORT_URL, "privacy": EXPECTED_PRIVACY_URL}
    for label, expected_page_url in page_urls.items():
        record = records.get(f"page:{label}")
        if not isinstance(record, dict):
            blockers.append(f"live_{label}_page: missing reachability record")
            continue
        if record.get("requested_url") != expected_page_url:
            blockers.append(f"live_{label}_page: requested URL mismatch")
        if record.get("final_url") != expected_page_url:
            blockers.append(f"live_{label}_page: redirect/final URL mismatch")
        status = record.get("status")
        if not isinstance(status, int) or not 200 <= status < 300:
            blockers.append(f"live_{label}_page: expected HTTP 2xx")
        if record.get("content_type") not in {"text/html", "application/xhtml+xml"}:
            blockers.append(f"live_{label}_page: expected HTML content type")
        body = record.get("body")
        if not isinstance(body, str):
            blockers.append(f"live_{label}_page: missing UTF-8 HTML")
            continue
        expected_uri = approved_contact_uri(approval, label)
        blockers.extend(parse_contact_page(label, body, expected_uri))
        if local_sources is not None and isinstance(local_sources.get(label), str):
            local_parser = ContactPageParser()
            live_parser = ContactPageParser()
            local_parser.feed(local_sources[label])
            local_parser.close()
            live_parser.feed(body)
            live_parser.close()
            if set(local_parser.private_contact_routes) != set(
                live_parser.private_contact_routes
            ):
                blockers.append(
                    f"live_{label}_page: marked routes differ from canonical source"
                )

        if urlparse(expected_uri).scheme != "https":
            continue
        route_record = records.get(f"route:{label}")
        if not isinstance(route_record, dict):
            blockers.append(f"live_{label}_contact: missing reachability record")
            continue
        if route_record.get("requested_url") != expected_uri:
            blockers.append(f"live_{label}_contact: approved URI mismatch")
        if route_record.get("final_url") != expected_uri:
            blockers.append(
                f"live_{label}_contact: redirect/final URL must equal approved URI"
            )
        route_status = route_record.get("status")
        if not isinstance(route_status, int) or not 200 <= route_status < 300:
            blockers.append(f"live_{label}_contact: expected HTTP 2xx")
        if route_record.get("content_type") not in {
            "text/html",
            "application/xhtml+xml",
        }:
            blockers.append(f"live_{label}_contact: expected HTML content type")
    return blockers


def validate_live_contact_gate(approval: dict[str, Any]) -> list[str]:
    records: dict[str, dict[str, Any]] = {}
    local_sources: dict[str, str] = {}
    for label, page_url in (
        ("support", EXPECTED_SUPPORT_URL),
        ("privacy", EXPECTED_PRIVACY_URL),
    ):
        local_path = DEFAULT_SITE_ROOT / label / "index.html"
        try:
            local_sources[label] = local_path.read_text(encoding="utf-8")
        except OSError:
            local_sources[label] = ""
        try:
            records[f"page:{label}"] = fetch_public_url(page_url, include_body=True)
        except (HTTPError, URLError, OSError, TimeoutError, UnicodeError, ValueError) as error:
            records[f"page:{label}"] = {
                "requested_url": page_url,
                "final_url": None,
                "status": None,
                "body": "",
            }
            records[f"page:{label}"]["fetch_error"] = str(error)
        approved_uri = approved_contact_uri(approval, label)
        if isinstance(approved_uri, str) and urlparse(approved_uri).scheme == "https":
            try:
                records[f"route:{label}"] = fetch_public_url(
                    approved_uri, include_body=False
                )
            except (HTTPError, URLError, OSError, TimeoutError, ValueError) as error:
                records[f"route:{label}"] = {
                    "requested_url": approved_uri,
                    "final_url": None,
                    "status": None,
                    "body": "",
                    "fetch_error": str(error),
                }
    return validate_live_page_records(approval, records, local_sources)


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
        parsed_timestamp = parse_utc_timestamp(generated_at)
        if parsed_timestamp is None:
            blockers.append(
                "release_evidence.generated_at_utc: expected YYYY-MM-DDTHH:MM:SSZ"
            )
        else:
            if parsed_timestamp.year < 2026:
                blockers.append("release_evidence.generated_at_utc: implausibly old")
            if parsed_timestamp > datetime.now(timezone.utc):
                blockers.append("release_evidence.generated_at_utc: must not be in future")

    blockers.extend(placeholder_errors(evidence, "release_evidence"))

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
        "inputs",
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
    run_inputs = ci_run.get("inputs")
    expected_input_keys = {
        "requested_build_number",
        "release_mode",
        "upload_to_testflight",
        "retain_signed_artifacts",
    }
    if not isinstance(run_inputs, dict) or set(run_inputs) != expected_input_keys:
        blockers.append("release_evidence.ci_run.inputs: exact contract does not match")
        run_inputs = {}
    requested_build = run_inputs.get("requested_build_number")
    if requested_build not in {"", build_number}:
        blockers.append(
            "release_evidence.ci_run.inputs.requested_build_number: must be empty or equal processed build"
        )
    if run_inputs.get("release_mode") != "disabled":
        blockers.append("release_evidence.ci_run.inputs.release_mode: expected disabled")
    if run_inputs.get("upload_to_testflight") is not True:
        blockers.append(
            "release_evidence.ci_run.inputs.upload_to_testflight: must be true"
        )
    if run_inputs.get("retain_signed_artifacts") is not True:
        blockers.append(
            "release_evidence.ci_run.inputs.retain_signed_artifacts: must be true"
        )
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


def validate_remote_run_and_artifact_records(
    expected_run_id: int,
    expected_artifact_id: int,
    expected_source_commit: str,
    run_record: Any,
    artifact_record: Any,
    jobs_record: Any,
) -> list[str]:
    """Reject unrelated/unfinished runs before downloading any artifact bytes."""
    blockers: list[str] = []
    if not isinstance(run_record, dict):
        return ["github_run: API response must be an object"]
    run_attempt = run_record.get("run_attempt")
    expected_run = {
        "id": expected_run_id,
        "event": "workflow_dispatch",
        "head_sha": expected_source_commit,
        "head_branch": "main",
        "status": "completed",
        "conclusion": "success",
        "html_url": (
            f"https://github.com/{EXPECTED_REPOSITORY}/actions/runs/{expected_run_id}"
        ),
    }
    for key, expected in expected_run.items():
        if run_record.get(key) != expected:
            blockers.append(f"github_run.{key}: selected final run mismatch")
    if not isinstance(run_attempt, int) or isinstance(run_attempt, bool) or run_attempt < 1:
        blockers.append("github_run.run_attempt: expected positive integer")
    if run_record.get("path") not in {
        EXPECTED_WORKFLOW,
        f"{EXPECTED_WORKFLOW}@main",
    }:
        blockers.append(f"github_run.path: expected {EXPECTED_WORKFLOW} on main")
    run_started = parse_api_timestamp(run_record.get("run_started_at"))
    run_updated = parse_api_timestamp(run_record.get("updated_at"))
    if run_started is None or run_updated is None or run_started > run_updated:
        blockers.append("github_run.timestamps: invalid run window")
    elif run_updated > datetime.now(timezone.utc):
        blockers.append("github_run.timestamps: run completion is in future")
    repository = run_record.get("repository")
    if not isinstance(repository, dict) or repository.get("full_name") != EXPECTED_REPOSITORY:
        blockers.append(f"github_run.repository: expected {EXPECTED_REPOSITORY}")

    if not isinstance(artifact_record, dict):
        return blockers + ["github_artifact: selected artifact was not found in run"]
    expected_name = (
        f"nekowidget-local-only-release-evidence-{expected_run_id}-{run_attempt}"
    )
    if artifact_record.get("id") != expected_artifact_id:
        blockers.append("github_artifact.id: selected artifact mismatch")
    if artifact_record.get("name") != expected_name:
        blockers.append("github_artifact.name: unrelated artifact")
    if artifact_record.get("expired") is not False:
        blockers.append("github_artifact.expired: artifact is unavailable")
    size = artifact_record.get("size_in_bytes")
    if (
        not isinstance(size, int)
        or isinstance(size, bool)
        or size < MINIMUM_SIGNED_ARTIFACT_BYTES
        or size > MAXIMUM_EVIDENCE_ZIP_BYTES
    ):
        blockers.append("github_artifact.size_in_bytes: implausible bundle size")
    digest = artifact_record.get("digest")
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        blockers.append("github_artifact.digest: missing SHA-256")
    elif re.fullmatch(r"sha256:([0-9a-f])\1{63}", digest):
        blockers.append("github_artifact.digest: placeholder SHA-256")
    expected_download_url = (
        f"https://api.github.com/repos/{EXPECTED_REPOSITORY}/actions/artifacts/"
        f"{expected_artifact_id}/zip"
    )
    if artifact_record.get("archive_download_url") != expected_download_url:
        blockers.append("github_artifact.archive_download_url: canonical URL mismatch")
    artifact_run = artifact_record.get("workflow_run")
    if not isinstance(artifact_run, dict):
        blockers.append("github_artifact.workflow_run: missing")
    else:
        if artifact_run.get("id") != expected_run_id:
            blockers.append("github_artifact.workflow_run.id: run mismatch")
        if artifact_run.get("head_sha") != expected_source_commit:
            blockers.append("github_artifact.workflow_run.head_sha: SHA mismatch")
        if artifact_run.get("head_branch") != "main":
            blockers.append("github_artifact.workflow_run.head_branch: expected main")

    if not isinstance(jobs_record, dict) or not isinstance(jobs_record.get("jobs"), list):
        return blockers + ["github_jobs: attempt jobs response is missing"]
    matching_jobs = [
        job
        for job in jobs_record["jobs"]
        if isinstance(job, dict)
        and job.get("name") == "Archive, export IPA, and upload"
    ]
    if len(matching_jobs) != 1:
        return blockers + ["github_jobs: expected exactly one release job"]
    expected_job = matching_jobs[0]
    if expected_job.get("run_id") != expected_run_id:
        blockers.append("github_jobs.run_id: selected run mismatch")
    if expected_job.get("run_attempt") != run_attempt:
        blockers.append("github_jobs.run_attempt: selected attempt mismatch")
    if expected_job.get("head_sha") != expected_source_commit:
        blockers.append("github_jobs.head_sha: selected source mismatch")
    if expected_job.get("status") != "completed" or expected_job.get("conclusion") != "success":
        blockers.append("github_jobs: release job did not complete successfully")
    job_started = parse_api_timestamp(expected_job.get("started_at"))
    job_completed = parse_api_timestamp(expected_job.get("completed_at"))
    if job_started is None or job_completed is None or job_started > job_completed:
        blockers.append("github_jobs.timestamps: invalid job window")
    elif job_completed > datetime.now(timezone.utc):
        blockers.append("github_jobs.timestamps: job completion is in future")
    steps = expected_job.get("steps")
    if not isinstance(steps, list):
        return blockers + ["github_jobs: release job steps are missing"]
    required_steps = (
        "Validate sharing privacy and export gates",
        "Verify archive signatures and App Group entitlements",
        "Package archive and symbols",
        "Validate and upload IPA to TestFlight",
        "Write local-only signed release evidence",
        "Upload local-only signed release evidence",
    )
    for step_name in required_steps:
        matching_steps = [
            step
            for step in steps
            if isinstance(step, dict) and step.get("name") == step_name
        ]
        if len(matching_steps) != 1:
            blockers.append(
                f"github_jobs.step.{step_name}: expected exactly one step"
            )
        elif matching_steps[0].get("status") != "completed" or matching_steps[0].get(
            "conclusion"
        ) != "success":
            blockers.append(f"github_jobs.step.{step_name}: expected success")
    return blockers


def validate_github_run_records(
    evidence: dict[str, Any],
    run_record: Any,
    artifact_record: Any,
    jobs_record: Any,
) -> list[str]:
    ci_run_value = evidence.get("ci_run")
    ci_run = ci_run_value if isinstance(ci_run_value, dict) else {}
    run_id = ci_run.get("run_id")
    artifact_id = artifact_record.get("id") if isinstance(artifact_record, dict) else None
    if not isinstance(run_id, int) or not isinstance(artifact_id, int):
        return ["release_evidence: remote run/artifact identifiers are invalid"]
    blockers = validate_remote_run_and_artifact_records(
        run_id,
        artifact_id,
        str(evidence.get("source_commit", "")),
        run_record,
        artifact_record,
        jobs_record,
    )
    expected_fields = {
        "run_attempt": ci_run.get("run_attempt"),
        "event": ci_run.get("event"),
        "head_sha": ci_run.get("head_sha"),
        "status": ci_run.get("status"),
        "conclusion": ci_run.get("conclusion"),
        "html_url": ci_run.get("run_url"),
    }
    if isinstance(run_record, dict):
        for key, expected in expected_fields.items():
            if run_record.get(key) != expected:
                blockers.append(
                    f"github_run.{key}: must exactly match evidence inside API artifact"
                )
    generated = parse_utc_timestamp(evidence.get("generated_at_utc"))
    expected_job = None
    if isinstance(jobs_record, dict) and isinstance(jobs_record.get("jobs"), list):
        matching_jobs = [
            job
            for job in jobs_record["jobs"]
            if isinstance(job, dict)
            and job.get("name") == "Archive, export IPA, and upload"
        ]
        if len(matching_jobs) == 1:
            expected_job = matching_jobs[0]
    if isinstance(expected_job, dict):
        job_started = parse_api_timestamp(expected_job.get("started_at"))
        job_completed = parse_api_timestamp(expected_job.get("completed_at"))
        if (
            generated is None
            or job_started is None
            or job_completed is None
            or not job_started <= generated <= job_completed
        ):
            blockers.append(
                "release_evidence.generated_at_utc: must be inside the remote job window"
            )
    return blockers


def validate_evidence_bundle_zip(
    bundle_zip: Path,
    artifact_record: dict[str, Any],
    manifest: dict[str, Any],
    repository: Path,
    extraction_root: Path,
) -> tuple[dict[str, Any] | None, list[str]]:
    """Verify API ZIP digest first, then open only the fixed three-member bundle."""
    blockers: list[str] = []
    if not bundle_zip.is_file():
        return None, ["release_bundle: downloaded ZIP is missing"]
    actual_zip_size = bundle_zip.stat().st_size
    if artifact_record.get("size_in_bytes") != actual_zip_size:
        return None, ["release_bundle: ZIP byte size does not match GitHub API"]
    expected_digest = artifact_record.get("digest")
    actual_digest = f"sha256:{sha256_file(bundle_zip)}"
    if expected_digest != actual_digest:
        return None, ["release_bundle: ZIP SHA-256 does not match GitHub API digest"]

    try:
        archive = zipfile.ZipFile(bundle_zip)
    except (OSError, zipfile.BadZipFile) as error:
        return None, [f"release_bundle: invalid ZIP after digest verification: {error}"]
    with archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            blockers.append("release_bundle: duplicate ZIP member")
        if set(names) != EXPECTED_BUNDLE_MEMBERS:
            blockers.append("release_bundle: exact member allowlist does not match")
        total_size = 0
        for info in infos:
            total_size += info.file_size
            mode = info.external_attr >> 16
            if info.is_dir() or stat.S_ISLNK(mode) or (
                stat.S_IFMT(mode) not in {0, stat.S_IFREG}
            ):
                blockers.append(f"release_bundle.{info.filename}: non-regular member")
            if info.flag_bits & 0x1:
                blockers.append(f"release_bundle.{info.filename}: encrypted ZIP member")
            if info.file_size < 0 or info.compress_size < 0:
                blockers.append(f"release_bundle.{info.filename}: invalid member size")
            if (
                info.filename == EXPECTED_EVIDENCE_FILENAME
                and not 1 <= info.file_size <= MAXIMUM_EVIDENCE_MANIFEST_BYTES
            ):
                blockers.append(
                    "release_bundle.local-only-release-evidence.json: "
                    "manifest size is outside the fixed bound"
                )
            if (
                info.filename == EXPECTED_PROCESSED_INFO_FILENAME
                and not 1 <= info.file_size <= MAXIMUM_PROCESSED_INFO_BYTES
            ):
                blockers.append(
                    "release_bundle.NekoWidget-processed-app-info.plist: "
                    "plist size is outside the fixed bound"
                )
            if info.filename == EXPECTED_ARTIFACT_FILENAME and not (
                MINIMUM_SIGNED_ARTIFACT_BYTES
                <= info.file_size
                <= MAXIMUM_EVIDENCE_ZIP_BYTES
            ):
                blockers.append(
                    "release_bundle.NekoWidget-signed-artifacts.tar.gz.enc: "
                    "encrypted artifact size is outside the fixed bound"
                )
            if info.file_size > 10_000_000 and info.compress_size > 0:
                if info.file_size / info.compress_size > 10:
                    blockers.append(
                        f"release_bundle.{info.filename}: suspicious compression ratio"
                    )
        if total_size > MAXIMUM_EVIDENCE_ZIP_BYTES:
            blockers.append("release_bundle: uncompressed content is too large")
        if blockers:
            return None, blockers
        try:
            corrupt = archive.testzip()
        except (OSError, RuntimeError, zipfile.BadZipFile) as error:
            blockers.append(f"release_bundle: ZIP integrity check failed: {error}")
            corrupt = None
        if corrupt is not None:
            blockers.append(f"release_bundle: corrupt member {corrupt}")
        if blockers:
            return None, blockers
        if extraction_root.exists() and any(extraction_root.iterdir()):
            return None, ["release_bundle: extraction directory must be empty"]
        extraction_root.mkdir(parents=True, exist_ok=True)
        for name in sorted(EXPECTED_BUNDLE_MEMBERS):
            target = extraction_root / name
            try:
                with archive.open(name) as source, target.open("xb") as destination:
                    shutil.copyfileobj(source, destination, length=1024 * 1024)
            except OSError as error:
                return None, [f"release_bundle: safe extraction failed: {error}"]

    evidence_path = extraction_root / EXPECTED_EVIDENCE_FILENAME
    try:
        evidence = load_json(evidence_path)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return None, [f"release_bundle: evidence manifest is invalid: {error}"]
    blockers.extend(
        validate_release_evidence(
            evidence,
            manifest,
            repository,
            evidence_path,
            extraction_root / EXPECTED_ARTIFACT_FILENAME,
            extraction_root / EXPECTED_PROCESSED_INFO_FILENAME,
        )
    )
    return evidence, blockers


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request: Any, *args: Any, **kwargs: Any) -> None:
        return None


def github_auth_token() -> str | None:
    for key in ("GH_TOKEN", "GITHUB_TOKEN"):
        value = os.environ.get(key)
        if value:
            return value
    try:
        result = subprocess.run(
            ["gh", "auth", "token"],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    except OSError:
        return None
    token = result.stdout.strip()
    return token if result.returncode == 0 and token else None


def download_github_artifact_zip(
    artifact_record: dict[str, Any], destination: Path
) -> list[str]:
    token = github_auth_token()
    if token is None:
        return [
            "github_artifact: authenticated download unavailable; use gh auth login "
            "or a read-only GH_TOKEN/GITHUB_TOKEN"
        ]
    url = artifact_record.get("archive_download_url")
    if not isinstance(url, str):
        return ["github_artifact.archive_download_url: missing"]
    if (resolution_error := public_hostname_resolution_error(url)) is not None:
        return [f"github_artifact.archive_download_url: {resolution_error}"]
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "User-Agent": "NekoWidget-App-Store-readiness",
        "X-GitHub-Api-Version": GITHUB_API_VERSION,
    }
    opener = build_opener(NoRedirect())
    try:
        response = opener.open(Request(url, headers=headers), timeout=15)
    except HTTPError as error:
        if error.code not in {301, 302, 303, 307, 308}:
            return [f"github_artifact: download request failed with HTTP {error.code}"]
        location = error.headers.get("Location")
        if not location:
            return ["github_artifact: download redirect is missing Location"]
        if (redirect_error := signed_download_url_error(location)) is not None:
            return [f"github_artifact: unsafe signed redirect: {redirect_error}"]
        try:
            response = build_opener(NoRedirect()).open(
                Request(location, headers={"User-Agent": headers["User-Agent"]}),
                timeout=30,
            )
        except (HTTPError, URLError, OSError, TimeoutError) as second_error:
            return [f"github_artifact: signed download failed: {second_error}"]
    except (URLError, OSError, TimeoutError) as error:
        return [f"github_artifact: download request failed: {error}"]
    expected_size = artifact_record.get("size_in_bytes")
    if getattr(response, "status", None) != 200:
        response.close()
        return ["github_artifact: download response was not HTTP 200"]
    written = 0
    try:
        with response, destination.open("wb") as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                written += len(chunk)
                if written > MAXIMUM_EVIDENCE_ZIP_BYTES or (
                    isinstance(expected_size, int) and written > expected_size
                ):
                    return ["github_artifact: downloaded ZIP exceeds API size"]
                output.write(chunk)
    except (OSError, TimeoutError) as error:
        return [f"github_artifact: download stream failed: {error}"]
    if written != expected_size:
        return ["github_artifact: downloaded ZIP size does not match API"]
    return []


def fetch_remote_release_records(
    run_id: int, artifact_id: int
) -> tuple[Any, Any, Any, list[str]]:
    token = github_auth_token()
    if token is None:
        return None, None, None, [
            "github_artifact: authenticated API access unavailable; use gh auth "
            "login or a read-only GH_TOKEN/GITHUB_TOKEN"
        ]
    base = f"https://api.github.com/repos/{EXPECTED_REPOSITORY}/actions/runs/{run_id}"
    try:
        run_record = github_json(base, token)
    except (HTTPError, URLError, OSError, TimeoutError, ValueError) as error:
        return None, None, None, [f"github_run: API lookup failed: {error}"]
    try:
        artifact_record = github_json(
            f"https://api.github.com/repos/{EXPECTED_REPOSITORY}/actions/artifacts/"
            f"{artifact_id}",
            token,
        )
    except (HTTPError, URLError, OSError, TimeoutError, ValueError) as error:
        return run_record, None, None, [
            f"github_artifact: API lookup failed: {error}"
        ]
    run_attempt = run_record.get("run_attempt") if isinstance(run_record, dict) else None
    if not isinstance(run_attempt, int):
        return run_record, artifact_record, None, ["github_run.run_attempt: missing"]
    jobs_url = f"{base}/attempts/{run_attempt}/jobs?per_page=100"
    try:
        jobs_record = github_json(jobs_url, token)
    except (HTTPError, URLError, OSError, TimeoutError, ValueError) as error:
        return run_record, artifact_record, None, [f"github_jobs: API lookup failed: {error}"]
    return run_record, artifact_record, jobs_record, []


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


def read_contact_approval(path: Path) -> tuple[dict[str, Any] | None, list[str]]:
    if not path.is_file():
        return None, [
            "contact_approval_file: missing; owner-selected real contact approval "
            "is required"
        ]
    try:
        return load_json(path), []
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return None, [f"contact_approval_file: could not be read: {error}"]


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
        "--contact-approval", type=Path, default=DEFAULT_CONTACT_APPROVAL
    )
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
        owner_blockers.extend(
            validate_canonical_release_source_binding(args.manifest)
        )
        owner, read_errors = read_owner_input(args.owner_input)
        owner_blockers.extend(read_errors)
        evidence: dict[str, Any] | None = None
        artifact_record: dict[str, Any] | None = None
        if owner is not None:
            run_id_text = owner.get("selected_github_run_id")
            artifact_id_text = owner.get("selected_github_artifact_id")
            selected_commit = owner.get("selected_git_commit")
            identifiers_valid = (
                isinstance(run_id_text, str)
                and re.fullmatch(r"[1-9][0-9]*", run_id_text) is not None
                and isinstance(artifact_id_text, str)
                and re.fullmatch(r"[1-9][0-9]*", artifact_id_text) is not None
                and isinstance(selected_commit, str)
                and re.fullmatch(r"[0-9a-f]{40}", selected_commit) is not None
                and re.fullmatch(r"([0-9a-f])\1{39}", selected_commit) is None
            )
            if not identifiers_valid:
                owner_blockers.append(
                    "release_evidence: valid owner-selected run, artifact, and commit are required"
                )
            else:
                run_id = int(run_id_text)
                artifact_id = int(artifact_id_text)
                run_record, candidate_artifact, jobs_record, fetch_errors = (
                    fetch_remote_release_records(run_id, artifact_id)
                )
                owner_blockers.extend(fetch_errors)
                pre_download_errors = validate_remote_run_and_artifact_records(
                    run_id,
                    artifact_id,
                    selected_commit,
                    run_record,
                    candidate_artifact,
                    jobs_record,
                )
                owner_blockers.extend(pre_download_errors)
                if not fetch_errors and not pre_download_errors and isinstance(
                    candidate_artifact, dict
                ):
                    artifact_record = candidate_artifact
                    with tempfile.TemporaryDirectory() as directory:
                        temporary = Path(directory)
                        bundle_zip = temporary / "github-release-evidence.zip"
                        download_errors = download_github_artifact_zip(
                            artifact_record, bundle_zip
                        )
                        owner_blockers.extend(download_errors)
                        if not download_errors:
                            evidence, bundle_errors = validate_evidence_bundle_zip(
                                bundle_zip,
                                artifact_record,
                                manifest,
                                PROJECT.parent,
                                temporary / "extracted",
                            )
                            owner_blockers.extend(bundle_errors)
                            if evidence is not None:
                                owner_blockers.extend(
                                    validate_github_run_records(
                                        evidence,
                                        run_record,
                                        artifact_record,
                                        jobs_record,
                                    )
                                )
            owner_blockers.extend(
                validate_owner_input(owner, manifest, evidence, artifact_record)
            )

        approval, approval_read_errors = read_contact_approval(args.contact_approval)
        owner_blockers.extend(approval_read_errors)
        approval_errors: list[str] = []
        if approval is not None:
            approval_errors = validate_contact_approval(approval)
            owner_blockers.extend(approval_errors)
        owner_blockers.extend(validate_publication_gate(DEFAULT_SITE_ROOT, approval))
        if approval is not None and not approval_errors:
            owner_blockers.extend(validate_live_contact_gate(approval))

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
