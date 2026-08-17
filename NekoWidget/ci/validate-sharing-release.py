#!/usr/bin/env python3
"""Fail closed when a release archive enables invite-only sharing.

The shipping app is the source of truth: this validator reads the processed
Info.plist and privacy manifest from the archive, rather than trusting source
build settings that may have been overridden by xcodebuild.
"""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path
from urllib.parse import urlparse


REQUIRED_COLLECTIONS = {
    "NSPrivacyCollectedDataTypeUserID",
    "NSPrivacyCollectedDataTypePhotosorVideos",
    "NSPrivacyCollectedDataTypeProductInteraction",
}
APP_FUNCTIONALITY = "NSPrivacyCollectedDataTypePurposeAppFunctionality"
PHOTO_DESCRIPTION_TERMS = ("招待", "最大20枚", "縮小", "暗号化", "原本")


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


def validate_privacy_manifest(privacy: dict, failures: list[str]) -> None:
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

    for data_type in sorted(REQUIRED_COLLECTIONS):
        item = by_type.get(data_type)
        if item is None:
            failures.append(f"PrivacyInfo is missing {data_type}.")
            continue
        if item.get("NSPrivacyCollectedDataTypeLinked") is not True:
            failures.append(f"{data_type} must be declared linked to the user.")
        if item.get("NSPrivacyCollectedDataTypeTracking") is not False:
            failures.append(f"{data_type} must declare tracking=false.")
        purposes = item.get("NSPrivacyCollectedDataTypePurposes")
        if not isinstance(purposes, list) or APP_FUNCTIONALITY not in purposes:
            failures.append(f"{data_type} must include the App Functionality purpose.")


def validate_enabled_release(
    info: dict, privacy: dict, export_reviewed: str
) -> list[str]:
    failures: list[str] = []

    endpoint = str(info.get("SharingAPIBaseURL", "")).strip()
    parsed_endpoint = urlparse(endpoint)
    if parsed_endpoint.scheme != "https" or not parsed_endpoint.hostname:
        failures.append("SharingAPIBaseURL must be a non-placeholder HTTPS URL.")
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

    validate_privacy_manifest(privacy, failures)

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

    enabled = truthy(info.get("SharingFeatureEnabled"))
    endpoint = str(info.get("SharingAPIBaseURL", "")).strip()
    # The runtime exposes pairing only when both switches are usable. Keeping
    # either value unset is the intentional non-release/default configuration.
    if not enabled or not endpoint:
        print("sharing release preflight: PASS (sharing is disabled)")
        return 0

    failures = validate_enabled_release(info, privacy, args.export_reviewed)
    if failures:
        print("sharing release preflight: FAIL", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("sharing release preflight: PASS (sharing disclosure gates satisfied)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
