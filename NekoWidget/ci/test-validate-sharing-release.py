#!/usr/bin/env python3
"""Regression tests for the archive sharing/privacy preflight."""

from __future__ import annotations

import base64
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate-sharing-release.py")
ENDPOINT = "https://sharing.nekonomado.jp"
USER_ID = "NSPrivacyCollectedDataTypeUserID"
PHOTOS = "NSPrivacyCollectedDataTypePhotosorVideos"
DEVICE_ID = "NSPrivacyCollectedDataTypeDeviceID"
PRODUCT_INTERACTION = "NSPrivacyCollectedDataTypeProductInteraction"
PURPOSE = "NSPrivacyCollectedDataTypePurposeAppFunctionality"
MODERATION_KEY_ID = "moderation-v1"
MODERATION_PUBLIC_KEY = "hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo"
PRIVACY_URL = "https://nekonomado.jp/privacy"
SUPPORT_URL = "https://nekonomado.jp/support"
COMMUNITY_URL = "https://nekonomado.jp/community"


def privacy(*data_types: str) -> dict:
    return {
        "NSPrivacyTracking": False,
        "NSPrivacyTrackingDomains": [],
        "NSPrivacyAccessedAPITypes": [
            {
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
            },
            {
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategorySystemBootTime",
                "NSPrivacyAccessedAPITypeReasons": ["35F9.1"],
            },
            {
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
                "NSPrivacyAccessedAPITypeReasons": ["C617.1"],
            },
        ],
        "NSPrivacyCollectedDataTypes": [
            {
                "NSPrivacyCollectedDataType": value,
                "NSPrivacyCollectedDataTypeLinked": True,
                "NSPrivacyCollectedDataTypeTracking": False,
                "NSPrivacyCollectedDataTypePurposes": [PURPOSE],
            }
            for value in data_types
        ],
    }


def share_privacy() -> dict:
    return {
        "NSPrivacyTracking": False,
        "NSPrivacyTrackingDomains": [],
        "NSPrivacyAccessedAPITypes": [
            {
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
                "NSPrivacyAccessedAPITypeReasons": ["C617.1"],
            }
        ],
        "NSPrivacyCollectedDataTypes": [],
    }


def widget_privacy() -> dict:
    return {
        "NSPrivacyTracking": False,
        "NSPrivacyTrackingDomains": [],
        "NSPrivacyAccessedAPITypes": [
            {
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
                "NSPrivacyAccessedAPITypeReasons": ["C617.1"],
            }
        ],
        "NSPrivacyCollectedDataTypes": [],
    }


def info(
    pairing: object,
    media: object,
    endpoint: str = "",
    review_preview: object = "NO",
    share_extension_send: object = "NO",
    share_extension_handoff: object | None = None,
    release_mode: str | None = None,
) -> dict:
    if share_extension_handoff is None:
        share_extension_handoff = media
    if release_mode is None:
        if review_preview in (True, "YES", "yes", "true", "1", 1):
            release_mode = "review-preview"
        elif media in (True, "YES", "yes", "true", "1", 1):
            release_mode = "media-staging"
        elif pairing in (True, "YES", "yes", "true", "1", 1):
            release_mode = "pairing-only"
        else:
            release_mode = "disabled"
    has_media_safety_configuration = release_mode == "media-staging"
    return {
        "SharingReleaseMode": release_mode,
        "SharingFeatureEnabled": pairing,
        "SharingMediaEnabled": media,
        "SharingShareExtensionSendEnabled": share_extension_send,
        "SharingShareExtensionHandoffEnabled": share_extension_handoff,
        "SharingReviewPreviewEnabled": review_preview,
        "SharingAPIBaseURL": endpoint,
        "NSPhotoLibraryUsageDescription": (
            "共有シートで選んだ1枚を最大2,048pxへ縮小し、位置情報を除いて"
            "暗号化して送り、原本は自動送信しません。"
        ),
        "SharingModerationKeyID": (
            MODERATION_KEY_ID if has_media_safety_configuration else ""
        ),
        "SharingModerationPublicKey": (
            MODERATION_PUBLIC_KEY if has_media_safety_configuration else ""
        ),
        "SharingPrivacyURL": PRIVACY_URL if has_media_safety_configuration else "",
        "SharingSupportURL": SUPPORT_URL if has_media_safety_configuration else "",
        "SharingCommunityStandardsURL": (
            COMMUNITY_URL if has_media_safety_configuration else ""
        ),
        "ITSAppUsesNonExemptEncryption": False,
    }


def share_info_from(app_info: dict) -> dict:
    value = dict(app_info)
    value["SharingReviewPreviewEnabled"] = False
    for key in (
        "SharingAPIBaseURL",
        "SharingModerationKeyID",
        "SharingModerationPublicKey",
        "SharingPrivacyURL",
        "SharingSupportURL",
        "SharingCommunityStandardsURL",
    ):
        value.pop(key, None)
    activation_count = 0 if app_info.get("SharingReleaseMode") == "disabled" else 1
    value["NSExtension"] = {
        "NSExtensionAttributes": {
            "NSExtensionActivationRule": {
                "NSExtensionActivationSupportsImageWithMaxCount": activation_count,
            }
        }
    }
    return value


def widget_info_from(app_info: dict) -> dict:
    return {
        "SharingReleaseMode": app_info.get("SharingReleaseMode", ""),
        "SharingFeatureEnabled": app_info.get("SharingFeatureEnabled", "NO"),
        "SharingMediaEnabled": app_info.get("SharingMediaEnabled", "NO"),
    }


class SharingReleasePreflightTests(unittest.TestCase):
    def run_preflight(
        self,
        info_value: dict,
        privacy_value: dict,
        export_reviewed: str = "YES",
        share_info_value: dict | None = None,
        widget_info_value: dict | None = None,
        widget_privacy_value: dict | None = None,
        widget_privacy_exists: bool = True,
        widget_privacy_bytes: bytes | None = None,
        share_privacy_value: dict | None = None,
        expected_mode: str | None = None,
        expected_api_origin: str | None = None,
        expected_moderation_key_id: str | None = None,
        expected_moderation_public_key: str | None = None,
        expected_privacy_url: str | None = None,
        expected_support_url: str | None = None,
        expected_community_url: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            info_path = root / "Info.plist"
            share_info_path = root / "ShareInfo.plist"
            widget_info_path = root / "WidgetInfo.plist"
            privacy_path = root / "PrivacyInfo.xcprivacy"
            widget_privacy_path = root / "WidgetPrivacyInfo.xcprivacy"
            share_privacy_path = root / "SharePrivacyInfo.xcprivacy"
            with info_path.open("wb") as stream:
                plistlib.dump(info_value, stream)
            with share_info_path.open("wb") as stream:
                plistlib.dump(
                    share_info_value or share_info_from(info_value),
                    stream,
                )
            with widget_info_path.open("wb") as stream:
                plistlib.dump(
                    widget_info_value or widget_info_from(info_value),
                    stream,
                )
            with privacy_path.open("wb") as stream:
                plistlib.dump(privacy_value, stream)
            if widget_privacy_bytes is not None:
                widget_privacy_path.write_bytes(widget_privacy_bytes)
            elif widget_privacy_exists:
                with widget_privacy_path.open("wb") as stream:
                    plistlib.dump(
                        widget_privacy()
                        if widget_privacy_value is None
                        else widget_privacy_value,
                        stream,
                    )
            with share_privacy_path.open("wb") as stream:
                plistlib.dump(
                    share_privacy()
                    if share_privacy_value is None
                    else share_privacy_value,
                    stream,
                )
            selected_mode = expected_mode or str(
                info_value.get("SharingReleaseMode", "")
            )
            exact_media_configuration = selected_mode == "media-staging"

            def expected_value(key: str, override: str | None) -> str:
                if override is not None:
                    return override
                if exact_media_configuration:
                    return str(info_value.get(key, ""))
                return ""

            return subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--info-plist",
                    str(info_path),
                    "--share-info-plist",
                    str(share_info_path),
                    "--widget-info-plist",
                    str(widget_info_path),
                    "--privacy-manifest",
                    str(privacy_path),
                    "--widget-privacy-manifest",
                    str(widget_privacy_path),
                    "--share-privacy-manifest",
                    str(share_privacy_path),
                    "--export-reviewed",
                    export_reviewed,
                    "--expected-mode",
                    selected_mode,
                    "--expected-api-origin",
                    (
                        str(info_value.get("SharingAPIBaseURL", ""))
                        if expected_api_origin is None
                        else expected_api_origin
                    ),
                    "--expected-moderation-key-id",
                    expected_value(
                        "SharingModerationKeyID", expected_moderation_key_id
                    ),
                    "--expected-moderation-public-key",
                    expected_value(
                        "SharingModerationPublicKey",
                        expected_moderation_public_key,
                    ),
                    "--expected-privacy-url",
                    expected_value("SharingPrivacyURL", expected_privacy_url),
                    "--expected-support-url",
                    expected_value("SharingSupportURL", expected_support_url),
                    "--expected-community-standards-url",
                    expected_value(
                        "SharingCommunityStandardsURL", expected_community_url
                    ),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_explicit_all_off_is_the_only_disabled_pass(self) -> None:
        result = self.run_preflight(info("NO", "NO"), privacy(), "NO")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("sharing is disabled", result.stdout)

    def test_disabled_rejects_every_sharing_surface_flag(self) -> None:
        flag_cases = {
            "feature": ("SharingFeatureEnabled", "YES"),
            "media": ("SharingMediaEnabled", "YES"),
            "handoff": ("SharingShareExtensionHandoffEnabled", "YES"),
            "direct-send": ("SharingShareExtensionSendEnabled", "YES"),
            "review-preview": ("SharingReviewPreviewEnabled", "YES"),
        }
        for name, (key, value) in flag_cases.items():
            with self.subTest(name=name):
                app = info("NO", "NO")
                app[key] = value
                result = self.run_preflight(
                    app,
                    privacy(),
                    "NO",
                    expected_mode="disabled",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Expected disabled flags", result.stderr)

    def test_disabled_rejects_endpoint_and_safety_configuration(self) -> None:
        values = {
            "SharingAPIBaseURL": ENDPOINT,
            "SharingModerationKeyID": MODERATION_KEY_ID,
            "SharingModerationPublicKey": MODERATION_PUBLIC_KEY,
            "SharingPrivacyURL": PRIVACY_URL,
            "SharingSupportURL": SUPPORT_URL,
            "SharingCommunityStandardsURL": COMMUNITY_URL,
        }
        for key, value in values.items():
            with self.subTest(key=key):
                app = info("NO", "NO")
                app[key] = value
                result = self.run_preflight(
                    app,
                    privacy(),
                    "NO",
                    expected_mode="disabled",
                    expected_api_origin="",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("does not exactly match", result.stderr)

    def test_widget_mode_and_flags_must_match_the_archive_mode(self) -> None:
        app = info("NO", "NO")
        cases = (
            {"SharingReleaseMode": "review-preview", "SharingFeatureEnabled": "NO", "SharingMediaEnabled": "NO"},
            {"SharingReleaseMode": "disabled", "SharingFeatureEnabled": "YES", "SharingMediaEnabled": "NO"},
            {"SharingReleaseMode": "disabled", "SharingFeatureEnabled": "NO", "SharingMediaEnabled": "YES"},
        )
        for widget in cases:
            with self.subTest(widget=widget):
                result = self.run_preflight(
                    app,
                    privacy(),
                    "NO",
                    widget_info_value=widget,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Widget", result.stderr)

    def test_share_extension_activation_matches_the_archive_mode(self) -> None:
        disabled = info("NO", "NO")
        disabled_share = share_info_from(disabled)
        disabled_share["NSExtension"]["NSExtensionAttributes"][
            "NSExtensionActivationRule"
        ]["NSExtensionActivationSupportsImageWithMaxCount"] = 1
        result = self.run_preflight(
            disabled,
            privacy(),
            "NO",
            share_info_value=disabled_share,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("activation count must be 0", result.stderr)

        media = info("YES", "YES", ENDPOINT, release_mode="media-staging")
        media_share = share_info_from(media)
        media_share["NSExtension"]["NSExtensionAttributes"][
            "NSExtensionActivationRule"
        ]["NSExtensionActivationSupportsImageWithMaxCount"] = 0
        result = self.run_preflight(
            media,
            privacy(USER_ID, PHOTOS, DEVICE_ID, PRODUCT_INTERACTION),
            share_info_value=media_share,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("activation count must be 1", result.stderr)

    def test_widget_privacy_manifest_is_required(self) -> None:
        result = self.run_preflight(
            info("NO", "NO"),
            privacy(),
            "NO",
            widget_privacy_exists=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not read plist", result.stderr)

    def test_widget_privacy_manifest_must_be_valid_plist(self) -> None:
        result = self.run_preflight(
            info("NO", "NO"),
            privacy(),
            "NO",
            widget_privacy_bytes=b"not a plist",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not read plist", result.stderr)

    def test_widget_privacy_manifest_requires_file_timestamp_reason(self) -> None:
        manifest = widget_privacy()
        manifest["NSPrivacyAccessedAPITypes"] = []
        result = self.run_preflight(
            info("NO", "NO"),
            privacy(),
            "NO",
            widget_privacy_value=manifest,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FileTimestamp", result.stderr)

    def test_widget_privacy_manifest_rejects_collection(self) -> None:
        manifest = widget_privacy()
        manifest["NSPrivacyCollectedDataTypes"] = privacy(USER_ID)[
            "NSPrivacyCollectedDataTypes"
        ]
        result = self.run_preflight(
            info("NO", "NO"),
            privacy(),
            "NO",
            widget_privacy_value=manifest,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not enabled", result.stderr)

    def test_widget_privacy_manifest_rejects_tracking(self) -> None:
        manifest = widget_privacy()
        manifest["NSPrivacyTracking"] = True
        result = self.run_preflight(
            info("NO", "NO"),
            privacy(),
            "NO",
            widget_privacy_value=manifest,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NSPrivacyTracking=false", result.stderr)

    def test_all_off_rejects_an_overdeclared_collection(self) -> None:
        result = self.run_preflight(info("NO", "NO"), privacy(USER_ID), "NO")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not enabled", result.stderr)

    def test_review_preview_is_visible_without_enabling_collection(self) -> None:
        result = self.run_preflight(
            info("NO", "NO", review_preview="YES"),
            privacy(),
            "NO",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("review preview visible", result.stdout)

    def test_review_preview_rejects_runtime_or_endpoint(self) -> None:
        runtime = self.run_preflight(
            info("YES", "NO", ENDPOINT, review_preview="YES"),
            privacy(USER_ID),
        )
        self.assertNotEqual(runtime.returncode, 0)
        self.assertIn("Expected review-preview flags", runtime.stderr)

        endpoint = self.run_preflight(
            info("NO", "NO", ENDPOINT, review_preview="YES"),
            privacy(),
        )
        self.assertNotEqual(endpoint.returncode, 0)
        self.assertIn("empty API URL", endpoint.stderr)

    def test_review_preview_rejects_collected_data(self) -> None:
        result = self.run_preflight(
            info("NO", "NO", review_preview="YES"),
            privacy(USER_ID),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not enabled", result.stderr)

    def test_pairing_enabled_requires_endpoint(self) -> None:
        result = self.run_preflight(info("YES", "NO"), privacy(USER_ID))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SharingAPIBaseURL", result.stderr)

    def test_media_cannot_be_enabled_without_pairing(self) -> None:
        result = self.run_preflight(
            info("NO", "YES", ENDPOINT),
            privacy(USER_ID, PHOTOS, DEVICE_ID, PRODUCT_INTERACTION),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected media-staging flags", result.stderr)

    def test_pairing_only_requires_user_id_but_not_photos(self) -> None:
        result = self.run_preflight(
            info(True, False, ENDPOINT),
            privacy(USER_ID),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pairing-only; photos disabled", result.stdout)

        overdeclared = self.run_preflight(
            info(True, False, ENDPOINT),
            privacy(USER_ID, PHOTOS),
        )
        self.assertNotEqual(overdeclared.returncode, 0)
        self.assertIn("not enabled", overdeclared.stderr)

    def test_pairing_only_rejects_every_photo_path_flag(self) -> None:
        cases = {
            "media": info(
                "YES",
                "YES",
                ENDPOINT,
                share_extension_handoff="NO",
                release_mode="pairing-only",
            ),
            "handoff": info(
                "YES",
                "NO",
                ENDPOINT,
                share_extension_handoff="YES",
                release_mode="pairing-only",
            ),
            "direct-send": info(
                "YES",
                "NO",
                ENDPOINT,
                share_extension_send="YES",
                share_extension_handoff="NO",
                release_mode="pairing-only",
            ),
            "review-preview": info(
                "YES",
                "NO",
                ENDPOINT,
                review_preview="YES",
                share_extension_handoff="NO",
                release_mode="pairing-only",
            ),
        }
        for name, app in cases.items():
            with self.subTest(name=name):
                result = self.run_preflight(
                    app,
                    privacy(USER_ID),
                    expected_mode="pairing-only",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Expected pairing-only flags", result.stderr)

    def test_expected_mode_must_match_processed_app_and_share(self) -> None:
        app = info("YES", "NO", ENDPOINT)
        result = self.run_preflight(
            app,
            privacy(USER_ID),
            expected_mode="review-preview",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SharingReleaseMode must be review-preview", result.stderr)

        share = share_info_from(app)
        share["SharingReleaseMode"] = "review-preview"
        result = self.run_preflight(
            app,
            privacy(USER_ID),
            share_info_value=share,
            expected_mode="pairing-only",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("App and Share Extension SharingReleaseMode do not match", result.stderr)

    def test_processed_origin_must_match_release_environment(self) -> None:
        result = self.run_preflight(
            info("YES", "NO", ENDPOINT),
            privacy(USER_ID),
            expected_api_origin="https://other.example.org",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not exactly match", result.stderr)

    def test_media_staging_requires_exact_mode_flags_and_environment_values(self) -> None:
        app = info(
            "YES",
            "YES",
            ENDPOINT,
            release_mode="media-staging",
        )
        manifest = privacy(USER_ID, PHOTOS, DEVICE_ID, PRODUCT_INTERACTION)
        result = self.run_preflight(app, manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "media-staging; two-device one-photo sharing enabled",
            result.stdout,
        )

        no_handoff = dict(app)
        no_handoff["SharingShareExtensionHandoffEnabled"] = "NO"
        result = self.run_preflight(no_handoff, manifest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected media-staging flags", result.stderr)

    def test_media_staging_rejects_small_order_x25519_public_keys(self) -> None:
        small_order_keys = (
            bytes.fromhex("00" * 32),
            bytes.fromhex("01" + ("00" * 31)),
            bytes.fromhex("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"),
            bytes.fromhex("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157"),
            bytes.fromhex("ec" + ("ff" * 30) + "7f"),
            bytes.fromhex("ed" + ("ff" * 30) + "7f"),
            bytes.fromhex("ee" + ("ff" * 30) + "7f"),
            bytes.fromhex(("00" * 31) + "80"),
        )
        manifest = privacy(USER_ID, PHOTOS, DEVICE_ID, PRODUCT_INTERACTION)
        for raw_key in small_order_keys:
            with self.subTest(raw_key=raw_key.hex()):
                app = info("YES", "YES", ENDPOINT, release_mode="media-staging")
                app["SharingModerationPublicKey"] = base64.urlsafe_b64encode(
                    raw_key
                ).decode("ascii").rstrip("=")
                result = self.run_preflight(app, manifest)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("small-order X25519 point", result.stderr)

    def test_media_staging_rejects_any_processed_environment_mismatch(self) -> None:
        baseline = info(
            "YES",
            "YES",
            ENDPOINT,
            release_mode="media-staging",
        )
        expected_arguments = {
            "expected_moderation_key_id": MODERATION_KEY_ID,
            "expected_moderation_public_key": MODERATION_PUBLIC_KEY,
            "expected_privacy_url": PRIVACY_URL,
            "expected_support_url": SUPPORT_URL,
            "expected_community_url": COMMUNITY_URL,
        }
        configuration_keys = (
            "SharingModerationKeyID",
            "SharingModerationPublicKey",
            "SharingPrivacyURL",
            "SharingSupportURL",
            "SharingCommunityStandardsURL",
        )
        manifest = privacy(USER_ID, PHOTOS, DEVICE_ID, PRODUCT_INTERACTION)
        for key in configuration_keys:
            with self.subTest(key=key):
                app = dict(baseline)
                app[key] = f"{app[key]}-changed"
                result = self.run_preflight(
                    app,
                    manifest,
                    **expected_arguments,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"Processed {key} does not exactly match", result.stderr)

    def test_pairing_manifest_preserves_required_api_reasons(self) -> None:
        for api_type in (
            "NSPrivacyAccessedAPICategoryUserDefaults",
            "NSPrivacyAccessedAPICategorySystemBootTime",
            "NSPrivacyAccessedAPICategoryFileTimestamp",
        ):
            with self.subTest(api_type=api_type):
                manifest = privacy(USER_ID)
                manifest["NSPrivacyAccessedAPITypes"] = [
                    item
                    for item in manifest["NSPrivacyAccessedAPITypes"]
                    if item.get("NSPrivacyAccessedAPIType") != api_type
                ]
                result = self.run_preflight(
                    info("YES", "NO", ENDPOINT),
                    manifest,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(api_type, result.stderr)

    def test_pairing_share_manifest_must_collect_nothing(self) -> None:
        result = self.run_preflight(
            info("YES", "NO", ENDPOINT),
            privacy(USER_ID),
            share_privacy_value=privacy(USER_ID),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not enabled", result.stderr)

    def test_non_exempt_encryption_uses_the_official_compliance_key(self) -> None:
        app = info("YES", "NO", ENDPOINT)
        app["ITSAppUsesNonExemptEncryption"] = True
        result = self.run_preflight(app, privacy(USER_ID))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ITSEncryptionExportComplianceCode", result.stderr)

        app["ITSEncryptionExportComplianceCode"] = "test-compliance-code"
        result = self.run_preflight(app, privacy(USER_ID))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_media_requires_photos_and_specific_usage_copy(self) -> None:
        result = self.run_preflight(
            info("YES", "YES", ENDPOINT),
            privacy(USER_ID),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(PHOTOS, result.stderr)

        complete = self.run_preflight(
            info("YES", "YES", ENDPOINT),
            privacy(USER_ID, PHOTOS, DEVICE_ID, PRODUCT_INTERACTION),
        )
        self.assertEqual(complete.returncode, 0, complete.stderr)

    def test_media_requires_safety_configuration(self) -> None:
        expected_privacy = privacy(USER_ID, PHOTOS, DEVICE_ID, PRODUCT_INTERACTION)
        for key in (
            "SharingModerationKeyID",
            "SharingModerationPublicKey",
            "SharingPrivacyURL",
            "SharingSupportURL",
            "SharingCommunityStandardsURL",
        ):
            with self.subTest(key=key):
                value = info("YES", "YES", ENDPOINT)
                value[key] = ""
                result = self.run_preflight(value, expected_privacy)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(key, result.stderr)

        for invalid_url in (
            "https://127.0.0.1/support",
            "https://192.168.1.10/support",
            "https://8.8.8.8/support",
            "https://intranet/support",
        ):
            with self.subTest(url=invalid_url):
                value = info("YES", "YES", ENDPOINT)
                value["SharingSupportURL"] = invalid_url
                result = self.run_preflight(value, expected_privacy)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("SharingSupportURL", result.stderr)

        invalid_key = info("YES", "YES", ENDPOINT)
        invalid_key["SharingModerationPublicKey"] += "!!"
        result = self.run_preflight(invalid_key, expected_privacy)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SharingModerationPublicKey", result.stderr)

    def test_direct_share_extension_delivery_is_hard_disabled(self) -> None:
        app = info("NO", "NO", share_extension_send="YES")
        result = self.run_preflight(app, privacy(), "NO")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("permanently blocked", result.stderr)

        app = info("NO", "NO")
        share = share_info_from(app)
        share["SharingShareExtensionSendEnabled"] = "YES"
        result = self.run_preflight(app, privacy(), "NO", share)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the app", result.stderr)

        share = share_info_from(app)
        del share["SharingShareExtensionSendEnabled"]
        result = self.run_preflight(app, privacy(), "NO", share)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is missing", result.stderr)

    def test_share_extension_runtime_configuration_must_match_app(self) -> None:
        app = info("NO", "NO")
        share = share_info_from(app)
        share["SharingMediaEnabled"] = "YES"
        result = self.run_preflight(app, privacy(), "NO", share)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SharingMediaEnabled does not match", result.stderr)

        share = share_info_from(app)
        share["SharingAPIBaseURL"] = ENDPOINT
        result = self.run_preflight(app, privacy(), "NO", share)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SharingAPIBaseURL must be absent", result.stderr)

    def test_media_requires_installation_bound_handoff(self) -> None:
        app = info(
            "YES",
            "YES",
            ENDPOINT,
            share_extension_handoff="NO",
        )
        result = self.run_preflight(
            app,
            privacy(USER_ID, PHOTOS, DEVICE_ID, PRODUCT_INTERACTION),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected media-staging flags", result.stderr)

        app = info("NO", "NO", share_extension_handoff="YES")
        result = self.run_preflight(app, privacy(), "NO")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected disabled flags", result.stderr)

        app = info("NO", "NO")
        share = share_info_from(app)
        share["SharingShareExtensionHandoffEnabled"] = "YES"
        result = self.run_preflight(app, privacy(), "NO", share)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HandoffEnabled does not match", result.stderr)

    def test_app_group_file_metadata_requires_declared_reason(self) -> None:
        value = info("NO", "NO")
        manifest = privacy()
        manifest["NSPrivacyAccessedAPITypes"] = [
            item
            for item in manifest["NSPrivacyAccessedAPITypes"]
            if item.get("NSPrivacyAccessedAPIType")
            != "NSPrivacyAccessedAPICategoryFileTimestamp"
        ]
        result = self.run_preflight(value, manifest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FileTimestamp", result.stderr)

    def test_unknown_flag_does_not_silently_become_disabled(self) -> None:
        result = self.run_preflight(info("$(BROKEN_FLAG)", "NO"), privacy())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("explicit YES/NO", result.stderr)

    def test_placeholder_or_local_endpoint_is_rejected(self) -> None:
        for endpoint in (
            "https://sharing.example",
            "https://sharing.local",
            "https://sharing.internal",
            "https://internal-api",
            "https://127.0.0.1",
            "https://8.8.8.8",
            "https://[2606:4700:4700::1111]",
        ):
            with self.subTest(endpoint=endpoint):
                result = self.run_preflight(
                    info("YES", "NO", endpoint),
                    privacy(USER_ID),
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("SharingAPIBaseURL", result.stderr)


if __name__ == "__main__":
    unittest.main()
