#!/usr/bin/env python3
"""Fail closed when a release archive enables invite-only sharing.

The shipping app is the source of truth: this validator reads the processed
Info.plist and privacy manifest from the archive, rather than trusting source
build settings that may have been overridden by xcodebuild.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import ipaddress
import plistlib
import re
import sys
from pathlib import Path
from urllib.parse import urlparse


PAIRING_COLLECTIONS = {"NSPrivacyCollectedDataTypeUserID"}
MEDIA_COLLECTIONS = {"NSPrivacyCollectedDataTypePhotosorVideos"}
MEDIA_INTERACTION_COLLECTIONS = {
    "NSPrivacyCollectedDataTypeDeviceID",
    "NSPrivacyCollectedDataTypeProductInteraction",
}
APP_FUNCTIONALITY = "NSPrivacyCollectedDataTypePurposeAppFunctionality"
PHOTO_DESCRIPTION_TERMS = ("選んだ1枚", "2,048", "位置情報", "暗号化", "原本")
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

    accessed_values = privacy.get("NSPrivacyAccessedAPITypes")
    accessed_by_type: dict[str, dict] = {}
    if isinstance(accessed_values, list):
        for item in accessed_values:
            if isinstance(item, dict) and isinstance(
                item.get("NSPrivacyAccessedAPIType"), str
            ):
                accessed_by_type[item["NSPrivacyAccessedAPIType"]] = item
    file_timestamp = accessed_by_type.get(
        "NSPrivacyAccessedAPICategoryFileTimestamp"
    )
    if file_timestamp is None or "C617.1" not in file_timestamp.get(
        "NSPrivacyAccessedAPITypeReasons", []
    ):
        failures.append(
            "PrivacyInfo must declare FileTimestamp reason C617.1 for app-group metadata."
        )

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
    if address is not None:
        failures.append("SharingAPIBaseURL must use a public DNS hostname, not an IP literal.")
    if "." not in hostname:
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

        moderation_key_id = str(info.get("SharingModerationKeyID", "")).strip()
        if moderation_key_id != "moderation-v1":
            failures.append("SharingModerationKeyID must be moderation-v1.")
        moderation_public_key = str(
            info.get("SharingModerationPublicKey", "")
        ).strip()
        try:
            if re.fullmatch(r"[A-Za-z0-9_-]{43}", moderation_public_key) is None:
                raise ValueError("non-canonical base64url")
            decoded_moderation_key = base64.b64decode(
                moderation_public_key.replace("-", "+").replace("_", "/") + "=",
                validate=True,
            )
            canonical_key = base64.urlsafe_b64encode(decoded_moderation_key).decode(
                "ascii"
            ).rstrip("=")
            if canonical_key != moderation_public_key:
                raise ValueError("non-canonical base64url")
        except (ValueError, binascii.Error):
            decoded_moderation_key = b""
        if len(decoded_moderation_key) != 32:
            failures.append(
                "SharingModerationPublicKey must be a 32-byte base64url public key."
            )

        for key in ("SharingSupportURL", "SharingCommunityStandardsURL"):
            raw_url = str(info.get(key, "")).strip()
            parsed_url = urlparse(raw_url)
            url_host = (parsed_url.hostname or "").lower().rstrip(".")
            try:
                parsed_url.port
            except ValueError:
                url_host = ""
            try:
                address = ipaddress.ip_address(url_host)
            except ValueError:
                address = None
            if (
                parsed_url.scheme != "https"
                or not url_host
                or url_host == "localhost"
                or url_host.endswith(RESERVED_HOST_SUFFIXES)
                or address is not None
                or "." not in url_host
                or parsed_url.username is not None
                or parsed_url.password is not None
                or parsed_url.params
                or parsed_url.query
                or parsed_url.fragment
                or "$" in raw_url
                or "REPLACE" in raw_url.upper()
            ):
                failures.append(f"{key} must be a public HTTPS URL.")

    required_collections = set(PAIRING_COLLECTIONS)
    if media_enabled:
        required_collections.update(MEDIA_COLLECTIONS)
        required_collections.update(MEDIA_INTERACTION_COLLECTIONS)
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


def validate_share_extension_boundary(
    app_info: dict,
    share_info: dict,
    failures: list[str],
) -> tuple[bool, bool]:
    """Keep the embedded Share Extension reviewable but unable to reuse a
    stale App Group/Keychain credential after reinstall.

    The extension cannot read the host app's ordinary-container installation
    marker. Direct network delivery therefore remains an unconditional release
    failure. The only supported path is a protected, short-lived handoff whose
    host-side promotion is installation-bound.
    """

    app_direct = parsed_flag(
        app_info, "SharingShareExtensionSendEnabled", failures
    )
    app_handoff = parsed_flag(
        app_info, "SharingShareExtensionHandoffEnabled", failures
    )
    share_failures: list[str] = []
    share_pairing = parsed_flag(
        share_info, "SharingFeatureEnabled", share_failures
    )
    share_media = parsed_flag(
        share_info, "SharingMediaEnabled", share_failures
    )
    share_preview = parsed_flag(
        share_info, "SharingReviewPreviewEnabled", share_failures
    )
    share_direct = parsed_flag(
        share_info, "SharingShareExtensionSendEnabled", share_failures
    )
    share_handoff = parsed_flag(
        share_info, "SharingShareExtensionHandoffEnabled", share_failures
    )
    failures.extend(f"Share Extension: {value}" for value in share_failures)

    app_pairing = truthy(app_info.get("SharingFeatureEnabled"))
    app_media = truthy(app_info.get("SharingMediaEnabled"))
    if share_pairing != app_pairing:
        failures.append("Share Extension SharingFeatureEnabled does not match the app.")
    if share_media != app_media:
        failures.append("Share Extension SharingMediaEnabled does not match the app.")
    if share_preview:
        failures.append("Share Extension must not enable the static review preview.")
    if app_direct != share_direct:
        failures.append(
            "Share Extension SharingShareExtensionSendEnabled does not match the app."
        )
    if app_direct or share_direct:
        failures.append(
            "Direct Share Extension delivery is permanently blocked; the extension "
            "may only hand one protected input to the installation-bound host app."
        )
    if app_handoff != share_handoff:
        failures.append(
            "Share Extension SharingShareExtensionHandoffEnabled does not match the app."
        )
    for key in (
        "SharingAPIBaseURL",
        "SharingModerationKeyID",
        "SharingModerationPublicKey",
        "SharingSupportURL",
        "SharingCommunityStandardsURL",
    ):
        if str(share_info.get(key, "")).strip():
            failures.append(
                f"Share Extension {key} must be absent; capture-only handoff has no network configuration."
            )
    return app_handoff, share_handoff


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--info-plist", type=Path, required=True)
    parser.add_argument("--share-info-plist", type=Path, required=True)
    parser.add_argument("--privacy-manifest", type=Path, required=True)
    parser.add_argument("--share-privacy-manifest", type=Path, required=True)
    parser.add_argument("--export-reviewed", default="")
    args = parser.parse_args()

    try:
        info = load_plist(args.info_plist)
        share_info = load_plist(args.share_info_plist)
        privacy = load_plist(args.privacy_manifest)
        share_privacy = load_plist(args.share_privacy_manifest)
    except ValueError as error:
        print(f"sharing release preflight: FAIL: {error}", file=sys.stderr)
        return 1

    flag_failures: list[str] = []
    pairing_enabled = parsed_flag(info, "SharingFeatureEnabled", flag_failures)
    media_enabled = parsed_flag(info, "SharingMediaEnabled", flag_failures)
    review_preview_enabled = parsed_flag(
        info, "SharingReviewPreviewEnabled", flag_failures
    )
    handoff_enabled, _ = validate_share_extension_boundary(
        info, share_info, flag_failures
    )
    validate_privacy_manifest(share_privacy, set(), flag_failures)
    endpoint = str(info.get("SharingAPIBaseURL", "")).strip()
    if flag_failures:
        print("sharing release preflight: FAIL", file=sys.stderr)
        for failure in flag_failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    if review_preview_enabled:
        failures: list[str] = []
        if pairing_enabled or media_enabled or handoff_enabled:
            failures.append(
                "Sharing review preview requires pairing, media, and handoff runtime flags OFF."
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
    if media_enabled and not pairing_enabled:
        print("sharing release preflight: FAIL", file=sys.stderr)
        print(
            "- SharingMediaEnabled requires SharingFeatureEnabled.",
            file=sys.stderr,
        )
        return 1
    if handoff_enabled and (not pairing_enabled or not media_enabled):
        print("sharing release preflight: FAIL", file=sys.stderr)
        print(
            "- SharingShareExtensionHandoffEnabled requires both SharingFeatureEnabled "
            "and SharingMediaEnabled.",
            file=sys.stderr,
        )
        return 1
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
    if media_enabled and not handoff_enabled:
        print("sharing release preflight: FAIL", file=sys.stderr)
        print(
            "- SharingMediaEnabled requires the installation-bound Share Extension handoff.",
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
