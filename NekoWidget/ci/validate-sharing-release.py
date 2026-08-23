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
LOCAL_PHOTO_DESCRIPTION_TERMS = ("猫", "端末内", "アルバム", "ウィジェット")
LOCAL_PHOTO_DESCRIPTION_FORBIDDEN_TERMS = (
    "共有",
    "招待",
    "相手",
    "受信",
    "履歴",
    "送信",
    "届け",
    "サーバー",
)
LOCAL_APP_PRIVACY_URL = (
    "https://soso-so-27.github.io/neko-widget/app/privacy/"
)
LOCAL_APP_SUPPORT_URL = (
    "https://soso-so-27.github.io/neko-widget/app/support/"
)
RESERVED_HOST_SUFFIXES = (
    ".example",
    ".invalid",
    ".local",
    ".localhost",
    ".test",
    ".internal",
    ".lan",
    ".home.arpa",
)
APP_REQUIRED_API_REASONS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": "CA92.1",
    "NSPrivacyAccessedAPICategorySystemBootTime": "35F9.1",
    "NSPrivacyAccessedAPICategoryFileTimestamp": "C617.1",
}
SHARE_REQUIRED_API_REASONS = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": "C617.1",
}
WIDGET_REQUIRED_API_REASONS = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": "C617.1",
}
EXPECTED_MODE_FLAGS = {
    "disabled": (False, False, False, False, False),
    "review-preview": (False, False, False, False, True),
    "pairing-only": (True, False, False, False, False),
    "media-staging": (True, True, True, False, False),
}

# X25519 small-order Montgomery u-coordinates, normalized by clearing the
# unused high bit as required by RFC 7748. Keep the release gate aligned with
# the blocklist used by libsodium's reviewed X25519 implementation.
X25519_SMALL_ORDER_PUBLIC_KEYS = {
    bytes.fromhex("00" * 32),
    bytes.fromhex("01" + ("00" * 31)),
    bytes.fromhex("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"),
    bytes.fromhex("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157"),
    bytes.fromhex("ec" + ("ff" * 30) + "7f"),
    bytes.fromhex("ed" + ("ff" * 30) + "7f"),
    bytes.fromhex("ee" + ("ff" * 30) + "7f"),
}


def is_x25519_small_order_public_key(value: bytes) -> bool:
    if len(value) != 32:
        return True
    normalized = bytearray(value)
    normalized[31] &= 0x7F
    return bytes(normalized) in X25519_SMALL_ORDER_PUBLIC_KEYS


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


def is_public_https_policy_url(value: str) -> bool:
    if value != value.strip() or any(ord(character) < 32 for character in value):
        return False
    parsed = urlparse(value)
    raw_host = (parsed.hostname or "").lower()
    host = raw_host.rstrip(".")
    try:
        parsed.port
    except ValueError:
        return False
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    return (
        parsed.scheme == "https"
        and bool(host)
        and not raw_host.endswith(".")
        and "." in host
        and host != "localhost"
        and not host.endswith(RESERVED_HOST_SUFFIXES)
        and address is None
        and parsed.username is None
        and parsed.password is None
        and not parsed.params
        and not parsed.query
        and not parsed.fragment
        and "$" not in value
        and "REPLACE" not in value.upper()
    )


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
    required_api_reasons: dict[str, str],
    failures: list[str],
) -> None:
    if privacy.get("NSPrivacyTracking") is not False:
        failures.append("PrivacyInfo must declare NSPrivacyTracking=false.")
    if privacy.get("NSPrivacyTrackingDomains") != []:
        failures.append(
            "PrivacyInfo must declare an empty NSPrivacyTrackingDomains array."
        )

    accessed_values = privacy.get("NSPrivacyAccessedAPITypes")
    accessed_by_type: dict[str, dict] = {}
    if isinstance(accessed_values, list):
        for item in accessed_values:
            if isinstance(item, dict) and isinstance(
                item.get("NSPrivacyAccessedAPIType"), str
            ):
                accessed_by_type[item["NSPrivacyAccessedAPIType"]] = item
    for api_type, reason in required_api_reasons.items():
        item = accessed_by_type.get(api_type)
        if item is None or reason not in item.get("NSPrivacyAccessedAPITypeReasons", []):
            failures.append(
                f"PrivacyInfo must declare {api_type} reason {reason}."
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

    raw_endpoint = str(info.get("SharingAPIBaseURL", ""))
    endpoint = raw_endpoint.strip()
    if raw_endpoint != endpoint or any(
        ord(character) < 32 for character in endpoint
    ):
        failures.append(
            "SharingAPIBaseURL must not contain whitespace or control characters."
        )
    parsed_endpoint = urlparse(endpoint)
    if parsed_endpoint.scheme != "https" or not parsed_endpoint.hostname:
        failures.append("SharingAPIBaseURL must be a non-placeholder HTTPS URL.")
    raw_hostname = (parsed_endpoint.hostname or "").lower()
    hostname = raw_hostname.rstrip(".")
    try:
        parsed_endpoint.port
    except ValueError:
        failures.append("SharingAPIBaseURL contains an invalid port.")
    if (
        raw_hostname.endswith(".")
        or hostname == "localhost"
        or hostname.endswith(RESERVED_HOST_SUFFIXES)
    ):
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

        raw_moderation_key_id = str(info.get("SharingModerationKeyID", ""))
        moderation_key_id = raw_moderation_key_id.strip()
        if raw_moderation_key_id != moderation_key_id:
            failures.append("SharingModerationKeyID must not contain surrounding whitespace.")
        if moderation_key_id != "moderation-v1":
            failures.append("SharingModerationKeyID must be moderation-v1.")
        raw_moderation_public_key = str(info.get("SharingModerationPublicKey", ""))
        moderation_public_key = raw_moderation_public_key.strip()
        if raw_moderation_public_key != moderation_public_key:
            failures.append(
                "SharingModerationPublicKey must not contain surrounding whitespace."
            )
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
        elif is_x25519_small_order_public_key(decoded_moderation_key):
            failures.append(
                "SharingModerationPublicKey must not be a small-order X25519 point."
            )

        for key in (
            "SharingPrivacyURL",
            "SharingSupportURL",
            "SharingCommunityStandardsURL",
        ):
            supplied_url = str(info.get(key, ""))
            raw_url = supplied_url.strip()
            parsed_url = urlparse(raw_url)
            raw_url_host = (parsed_url.hostname or "").lower()
            url_host = raw_url_host.rstrip(".")
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
                or raw_url_host.endswith(".")
                or url_host == "localhost"
                or url_host.endswith(RESERVED_HOST_SUFFIXES)
                or address is not None
                or "." not in url_host
                or parsed_url.username is not None
                or parsed_url.password is not None
                or parsed_url.params
                or parsed_url.query
                or parsed_url.fragment
                or raw_url != supplied_url
                or any(ord(character) < 32 for character in raw_url)
                or "$" in raw_url
                or "REPLACE" in raw_url.upper()
            ):
                failures.append(f"{key} must be a public HTTPS URL.")

    required_collections = set(PAIRING_COLLECTIONS)
    if media_enabled:
        required_collections.update(MEDIA_COLLECTIONS)
        required_collections.update(MEDIA_INTERACTION_COLLECTIONS)
    validate_privacy_manifest(
        privacy,
        required_collections,
        APP_REQUIRED_API_REASONS,
        failures,
    )

    if not truthy(export_reviewed):
        failures.append(
            "SHARING_EXPORT_REVIEWED is not YES. Reassess App Store Connect export "
            "compliance for X25519, Ed25519, HKDF-SHA256, and ChaCha20-Poly1305."
        )

    encryption_value = info.get("ITSAppUsesNonExemptEncryption")
    if not isinstance(encryption_value, bool):
        failures.append("ITSAppUsesNonExemptEncryption must be an explicit Boolean.")
    elif encryption_value:
        declaration_code = info.get("ITSEncryptionExportComplianceCode")
        if not isinstance(declaration_code, str) or not declaration_code.strip():
            failures.append(
                "A non-exempt encryption build requires ITSEncryptionExportComplianceCode."
            )

    return failures


def validate_share_extension_boundary(
    app_info: dict,
    share_info: dict,
    failures: list[str],
) -> tuple[bool, bool]:
    """Keep enabled-mode Share Extension capture-only and installation-bound.

    The disabled archive separately uses a FALSEPREDICATE activation rule and
    an early runtime refusal, so this boundary is defense in depth for every
    mode where the extension is intentionally visible.

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
        "AppPrivacyURL",
        "AppSupportURL",
        "SharingAPIBaseURL",
        "SharingModerationKeyID",
        "SharingModerationPublicKey",
        "SharingPrivacyURL",
        "SharingSupportURL",
        "SharingCommunityStandardsURL",
    ):
        if str(share_info.get(key, "")).strip():
            failures.append(
                f"Share Extension {key} must be absent; capture-only handoff has no network configuration."
            )
    return app_handoff, app_direct


def validate_expected_mode(
    expected_mode: str,
    expected_api_origin: str,
    expected_moderation_key_id: str,
    expected_moderation_public_key: str,
    expected_app_privacy_url: str,
    expected_app_support_url: str,
    expected_privacy_url: str,
    expected_support_url: str,
    expected_community_standards_url: str,
    expected_photo_library_usage_description: str,
    app_info: dict,
    share_info: dict,
    widget_info: dict,
    pairing_enabled: bool,
    media_enabled: bool,
    handoff_enabled: bool,
    direct_send_enabled: bool,
    review_preview_enabled: bool,
    failures: list[str],
) -> None:
    """Bind the requested workflow mode to the processed archive.

    The marker and every runtime flag are checked after Xcode expansion so a
    command-line override, stale xcconfig, or Share Extension mismatch fails
    closed instead of silently changing the release scope.
    """

    app_mode_value = app_info.get("SharingReleaseMode", "")
    share_mode_value = share_info.get("SharingReleaseMode", "")
    app_mode = app_mode_value if isinstance(app_mode_value, str) else ""
    share_mode = share_mode_value if isinstance(share_mode_value, str) else ""
    if app_mode != expected_mode:
        failures.append(
            f"App SharingReleaseMode must be {expected_mode}, got {app_mode or 'empty'}."
        )
    if share_mode != expected_mode:
        failures.append(
            "Share Extension SharingReleaseMode must match the expected app mode "
            f"{expected_mode}, got {share_mode or 'empty'}."
        )
    if share_mode != app_mode:
        failures.append("App and Share Extension SharingReleaseMode do not match.")

    if expected_mode == "disabled":
        required_app_privacy_url = LOCAL_APP_PRIVACY_URL
        required_app_support_url = LOCAL_APP_SUPPORT_URL
    elif expected_mode == "media-staging":
        required_app_privacy_url = expected_privacy_url
        required_app_support_url = expected_support_url
    else:
        required_app_privacy_url = ""
        required_app_support_url = ""
    if expected_app_privacy_url != required_app_privacy_url:
        if expected_mode == "media-staging":
            failures.append(
                "media-staging AppPrivacyURL must exactly match SharingPrivacyURL."
            )
        else:
            failures.append(
                f"{expected_mode} selected an unexpected general app privacy URL."
            )
    if expected_app_support_url != required_app_support_url:
        if expected_mode == "media-staging":
            failures.append(
                "media-staging AppSupportURL must exactly match SharingSupportURL."
            )
        else:
            failures.append(
                f"{expected_mode} selected an unexpected general app support URL."
            )
    app_policy_configuration = {
        "AppPrivacyURL": expected_app_privacy_url,
        "AppSupportURL": expected_app_support_url,
    }
    for key, expected_value in app_policy_configuration.items():
        archived_value = app_info.get(key)
        if not isinstance(archived_value, str) or archived_value != expected_value:
            failures.append(
                f"Processed {key} does not exactly match the selected general app policy URL."
            )
        if expected_value and not is_public_https_policy_url(expected_value):
            failures.append(f"{key} must be a public HTTPS URL.")

    widget_mode_value = widget_info.get("SharingReleaseMode", "")
    widget_mode = widget_mode_value if isinstance(widget_mode_value, str) else ""
    if widget_mode != expected_mode:
        failures.append(
            "Widget SharingReleaseMode must match the expected app mode "
            f"{expected_mode}, got {widget_mode or 'empty'}."
        )
    if widget_mode != app_mode:
        failures.append("App and Widget SharingReleaseMode do not match.")

    archived_origin = str(app_info.get("SharingAPIBaseURL", ""))
    if archived_origin != expected_api_origin:
        failures.append(
            "Processed SharingAPIBaseURL does not exactly match the origin supplied "
            "by the release workflow."
        )

    expected_configuration = {
        "SharingModerationKeyID": expected_moderation_key_id,
        "SharingModerationPublicKey": expected_moderation_public_key,
        "SharingPrivacyURL": expected_privacy_url,
        "SharingSupportURL": expected_support_url,
        "SharingCommunityStandardsURL": expected_community_standards_url,
    }
    for key, expected_value in expected_configuration.items():
        archived_value = app_info.get(key)
        if not isinstance(archived_value, str) or archived_value != expected_value:
            failures.append(
                f"Processed {key} does not exactly match the value supplied "
                "by the protected release environment."
            )

    archived_photo_description = app_info.get("NSPhotoLibraryUsageDescription")
    if (
        not isinstance(archived_photo_description, str)
        or archived_photo_description != expected_photo_library_usage_description
    ):
        failures.append(
            "Processed NSPhotoLibraryUsageDescription does not exactly match the "
            "value supplied by the protected release workflow."
        )
    if expected_mode != "media-staging" and isinstance(
        archived_photo_description, str
    ):
        missing_terms = [
            term
            for term in LOCAL_PHOTO_DESCRIPTION_TERMS
            if term not in archived_photo_description
        ]
        forbidden_terms = [
            term
            for term in LOCAL_PHOTO_DESCRIPTION_FORBIDDEN_TERMS
            if term in archived_photo_description
        ]
        if missing_terms:
            failures.append(
                "Local-only NSPhotoLibraryUsageDescription does not explain the "
                "on-device cat/album/Widget purpose "
                f"(missing: {', '.join(missing_terms)})."
            )
        if forbidden_terms:
            failures.append(
                "Local-only NSPhotoLibraryUsageDescription misleadingly describes "
                "a sharing path "
                f"(found: {', '.join(forbidden_terms)})."
            )

    actual = (
        pairing_enabled,
        media_enabled,
        handoff_enabled,
        direct_send_enabled,
        review_preview_enabled,
    )
    expected = EXPECTED_MODE_FLAGS[expected_mode]
    if actual != expected:
        names = (
            "feature",
            "media",
            "handoff",
            "direct-send",
            "review-preview",
        )
        expected_text = ", ".join(
            f"{name}={'YES' if value else 'NO'}"
            for name, value in zip(names, expected, strict=True)
        )
        actual_text = ", ".join(
            f"{name}={'YES' if value else 'NO'}"
            for name, value in zip(names, actual, strict=True)
        )
        failures.append(
            f"Expected {expected_mode} flags ({expected_text}); archive has {actual_text}."
        )

    widget_pairing_enabled = parsed_flag(
        widget_info, "SharingFeatureEnabled", failures
    )
    widget_media_enabled = parsed_flag(widget_info, "SharingMediaEnabled", failures)
    if (widget_pairing_enabled, widget_media_enabled) != expected[:2]:
        failures.append(
            "Widget sharing flags must match the expected app feature/media flags."
        )

    extension = share_info.get("NSExtension")
    attributes = extension.get("NSExtensionAttributes") if isinstance(extension, dict) else None
    activation_rule = (
        attributes.get("NSExtensionActivationRule")
        if isinstance(attributes, dict)
        else None
    )
    if expected_mode == "disabled":
        if activation_rule != "FALSEPREDICATE":
            failures.append(
                "Disabled Share Extension activation rule must be FALSEPREDICATE."
            )
    else:
        if activation_rule != {
            "NSExtensionActivationSupportsImageWithMaxCount": 1
        }:
            failures.append(
                "Share Extension activation rule must accept exactly one image for "
                f"{expected_mode}."
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--info-plist", type=Path, required=True)
    parser.add_argument("--share-info-plist", type=Path, required=True)
    parser.add_argument("--widget-info-plist", type=Path, required=True)
    parser.add_argument("--privacy-manifest", type=Path, required=True)
    parser.add_argument("--widget-privacy-manifest", type=Path, required=True)
    parser.add_argument("--share-privacy-manifest", type=Path, required=True)
    parser.add_argument("--export-reviewed", default="")
    parser.add_argument(
        "--expected-mode",
        choices=tuple(EXPECTED_MODE_FLAGS),
        required=True,
        help="Explicit release mode selected by the archive workflow.",
    )
    parser.add_argument(
        "--expected-api-origin",
        required=True,
        help="Exact API origin supplied by the protected release environment.",
    )
    parser.add_argument("--expected-moderation-key-id", default="")
    parser.add_argument("--expected-moderation-public-key", default="")
    parser.add_argument("--expected-app-privacy-url", default="")
    parser.add_argument("--expected-app-support-url", default="")
    parser.add_argument("--expected-privacy-url", default="")
    parser.add_argument("--expected-support-url", default="")
    parser.add_argument("--expected-community-standards-url", default="")
    parser.add_argument(
        "--expected-photo-library-usage-description",
        required=True,
        help="Exact photo permission purpose string selected by the release workflow.",
    )
    args = parser.parse_args()

    try:
        info = load_plist(args.info_plist)
        share_info = load_plist(args.share_info_plist)
        widget_info = load_plist(args.widget_info_plist)
        privacy = load_plist(args.privacy_manifest)
        widget_privacy = load_plist(args.widget_privacy_manifest)
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
    handoff_enabled, direct_send_enabled = validate_share_extension_boundary(
        info, share_info, flag_failures
    )
    validate_expected_mode(
        args.expected_mode,
        args.expected_api_origin,
        args.expected_moderation_key_id,
        args.expected_moderation_public_key,
        args.expected_app_privacy_url,
        args.expected_app_support_url,
        args.expected_privacy_url,
        args.expected_support_url,
        args.expected_community_standards_url,
        args.expected_photo_library_usage_description,
        info,
        share_info,
        widget_info,
        pairing_enabled,
        media_enabled,
        handoff_enabled,
        direct_send_enabled,
        review_preview_enabled,
        flag_failures,
    )
    validate_privacy_manifest(
        widget_privacy,
        set(),
        WIDGET_REQUIRED_API_REASONS,
        flag_failures,
    )
    validate_privacy_manifest(
        share_privacy,
        set(),
        SHARE_REQUIRED_API_REASONS,
        flag_failures,
    )
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
        validate_privacy_manifest(
            privacy,
            set(),
            APP_REQUIRED_API_REASONS,
            failures,
        )
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
        validate_privacy_manifest(
            privacy,
            set(),
            APP_REQUIRED_API_REASONS,
            failures,
        )
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

    if args.expected_mode == "pairing-only":
        print(
            "sharing release preflight: PASS "
            "(pairing-only; photos disabled)"
        )
    elif args.expected_mode == "media-staging":
        print(
            "sharing release preflight: PASS "
            "(media-staging; two-device one-photo sharing enabled)"
        )
    else:
        print("sharing release preflight: PASS (sharing disclosure gates satisfied)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
