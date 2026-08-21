#!/usr/bin/env python3
"""Fail closed when a release archive enables invite-only sharing.

The shipping app is the source of truth: this validator reads the processed
Info.plist and privacy manifest from the archive, rather than trusting source
build settings that may have been overridden by xcodebuild.
"""

from __future__ import annotations

import argparse
import ipaddress
import plistlib
import sys
from pathlib import Path
from urllib.parse import urlparse


PAIRING_COLLECTIONS = {"NSPrivacyCollectedDataTypeUserID"}
MEDIA_COLLECTIONS = {"NSPrivacyCollectedDataTypePhotosorVideos"}
APP_FUNCTIONALITY = "NSPrivacyCollectedDataTypePurposeAppFunctionality"
PHOTO_DESCRIPTION_TERMS = ("招待", "最大20枚", "縮小", "暗号化", "原本")
RESERVED_HOST_SUFFIXES = (".example", ".invalid", ".local", ".localhost", ".test")


def load_plist(path: Path) -> dict:
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ValueError(f"Could not read plist {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"Expected a dictionary plist at {path}")
    return value


def truthy(value: object) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes"}
    return False


def parsed_flag(info: dict, key: str, failures: list[str]) -> bool:
    """Read an explicit processed Info.plist flag without treating typos as off."""

    if key not in info:
        failures.append(f"{key} is missing from the processed Info.plist.")
        return False
    value = info[key]
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value != 0
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes"}:
            return True
        if normalized in {"0", "false", "no"}:
            return False
    failures.append(f"{key} is not an explicit YES/NO value.")
    return False


def validate_privacy_manifest(
    privacy: dict,
    expected_collections: set[str],
    failures: list[str],
) -> None:
    if privacy.get("NSPrivacyTracking") is not False:
        failures.append("PrivacyInfo must declare NSPrivacyTracking=false.")

    values = privacy.get("NSPrivacyCollectedDataTypes")
    if not isinstance(values, list):
        failures.append("PrivacyInfo has no NSPrivacyCollectedDataTypes array.")
        return

    by_type: dict[str, dict] = {}
    for item in values:
        if isinstance(item, dict) and isinstance(
            item.get("NSPrivacyCollectedDataType"), str
        ):
            by_type[item["NSPrivacyCollectedDataType"]] = item

    if len(by_type) != len(values):
        failures.append("PrivacyInfo contains duplicate or malformed collected-data entries.")

    for data_type in sorted(expected_collections):
        item = by_type.get(data_type)
        if item is None:
            failures.append(f"PrivacyInfo is missing {data_type}.")
            continue
        if item.get("NSPrivacyCollectedDataTypeLinked") is not True:
            failures.append(f"{data_type} must be declared linked to the user.")
        if item.get("NSPrivacyCollectedDataTypeTracking") is not False:
            failures.append(f"{data_type} must declare tracking=false.")
        purposes = item.get("NSPrivacyCollectedDataTypePurposes")
        if purposes != [APP_FUNCTIONALITY]:
            failures.append(f"{data_type} must use only the App Functionality purpose.")

    unexpected = set(by_type) - expected_collections
    for data_type in sorted(unexpected):
        failures.append(
            f"PrivacyInfo declares {data_type}, which is not enabled in this sharing build."
        )


def validate_enabled_release(
    info: dict,
    privacy: dict,
    export_reviewed: str,
    media_enabled: bool,
) -> list[str]:
    failures: list[str] = []

    endpoint = str(info.get("SharingAPIBaseURL", "")).strip()
    parsed_endpoint = urlparse(endpoint)
    if parsed_endpoint.scheme != "https" or not parsed_endpoint.hostname:
        failures.append("SharingAPIBaseURL must be a non-placeholder HTTPS URL.")
    hostname = (parsed_endpoint.hostname or "").lower().rstrip(".")
    try:
        parsed_endpoint.port
    except ValueError:
        failures.append("SharingAPIBaseURL contains an invalid port.")
    if hostname == "localhost" or hostname.endswith(RESERVED_HOST_SUFFIXES):
        failures.append("SharingAPIBaseURL uses a reserved placeholder hostname.")
    try:
        address = ipaddress.ip_address(hostname)
    except ValueError:
        address = None
    if address is not None and not address.is_global:
        failures.append("SharingAPIBaseURL must not use a private or local IP address.")
    if address is None and "." not in hostname:
        failures.append("SharingAPIBaseURL must use a public fully-qualified hostname.")
    if (
        parsed_endpoint.username is not None
        or parsed_endpoint.password is not None
        or parsed_endpoint.path not in {"", "/"}
        or parsed_endpoint.params
        or parsed_endpoint.query
        or parsed_endpoint.fragment
    ):
        failures.append(
            "SharingAPIBaseURL must be an HTTPS origin without credentials, "
            "a path, query, or fragment."
        )
    if "$" in endpoint or "REPLACE" in endpoint.upper():
        failures.append("SharingAPIBaseURL still contains a build placeholder.")

    if media_enabled:
        description = info.get("NSPhotoLibraryUsageDescription")
        if not isinstance(description, str):
            failures.append("NSPhotoLibraryUsageDescription is missing.")
        else:
            missing_terms = [term for term in PHOTO_DESCRIPTION_TERMS if term not in description]
            if missing_terms:
                failures.append(
                    "NSPhotoLibraryUsageDescription does not explain invite-only preview "
                    f"sharing (missing: {', '.join(missing_terms)})."
                )

    required_collections = set(PAIRING_COLLECTIONS)
    if media_enabled:
        required_collections.update(MEDIA_COLLECTIONS)
    validate_privacy_manifest(privacy, required_collections, failures)

    if not truthy(export_reviewed):
        failures.append(
            "SHARING_EXPORT_REVIEWED is not YES. Reassess App Store Connect export "
            "compliance for X25519, Ed25519, HKDF-SHA256, and ChaCha20-Poly1305."
        )

    encryption_value = info.get("ITSAppUsesNonExemptEncryption")
    if not isinstance(encryption_value, bool):
        failures.append("ITSAppUsesNonExemptEncryption must be an explicit Boolean.")
    elif encryption_value:
        declaration_code = info.get("AppEncryptionDeclarationCode")
        if not isinstance(declaration_code, str) or not declaration_code.strip():
            failures.append(
                "A non-exempt encryption build requires AppEncryptionDeclarationCode."
            )

    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--info-plist", type=Path, required=True)
    parser.add_argument("--privacy-manifest", type=Path, required=True)
    parser.add_argument("--export-reviewed", default="")
    args = parser.parse_args()

    try:
        info = load_plist(args.info_plist)
        privacy = load_plist(args.privacy_manifest)
    except ValueError as error:
        print(f"sharing release preflight: FAIL: {error}", file=sys.stderr)
        return 1

    flag_failures: list[str] = []
    pairing_enabled = parsed_flag(info, "SharingFeatureEnabled", flag_failures)
    media_enabled = parsed_flag(info, "SharingMediaEnabled", flag_failures)
    review_preview_enabled = parsed_flag(
        info, "SharingReviewPreviewEnabled", flag_failures
    )
    endpoint = str(info.get("SharingAPIBaseURL", "")).strip()
    if flag_failures:
        print("sharing release preflight: FAIL", file=sys.stderr)
        for failure in flag_failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    if review_preview_enabled:
        failures: list[str] = []
        if pairing_enabled or media_enabled:
            failures.append(
                "Sharing review preview requires pairing and media runtime flags OFF."
            )
        if endpoint:
            failures.append("Sharing review preview requires an empty API URL.")
        validate_privacy_manifest(privacy, set(), failures)
        if failures:
            print("sharing release preflight: FAIL", file=sys.stderr)
            for failure in failures:
                print(f"- {failure}", file=sys.stderr)
            return 1
        print(
            "sharing release preflight: PASS "
            "(review preview visible; runtime sharing is disabled)"
        )
        return 0

    # Only the explicit all-off configuration is a no-collection build. A
    # missing endpoint must never turn an enabled pairing/media build into a
    # silent pass, and media cannot operate without the pairing identity/key.
    if not pairing_enabled and not media_enabled:
        failures: list[str] = []
        if endpoint:
            failures.append("Disabled sharing requires an empty API URL.")
        validate_privacy_manifest(privacy, set(), failures)
        if failures:
            print("sharing release preflight: FAIL", file=sys.stderr)
            for failure in failures:
                print(f"- {failure}", file=sys.stderr)
            return 1
        print("sharing release preflight: PASS (sharing is disabled)")
        return 0
    if media_enabled and not pairing_enabled:
        print("sharing release preflight: FAIL", file=sys.stderr)
        print(
            "- SharingMediaEnabled requires SharingFeatureEnabled.",
            file=sys.stderr,
        )
        return 1

    failures = validate_enabled_release(
        info,
        privacy,
        args.export_reviewed,
        media_enabled,
    )
    if failures:
        print("sharing release preflight: FAIL", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("sharing release preflight: PASS (sharing disclosure gates satisfied)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
