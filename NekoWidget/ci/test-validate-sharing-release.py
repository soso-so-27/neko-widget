#!/usr/bin/env python3
"""Regression tests for the archive sharing/privacy preflight."""

from __future__ import annotations

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


def privacy(*data_types: str) -> dict:
    return {
        "NSPrivacyTracking": False,
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


def info(
    pairing: object,
    media: object,
    endpoint: str = "",
    review_preview: object = "NO",
    share_extension_send: object = "NO",
) -> dict:
    return {
        "SharingFeatureEnabled": pairing,
        "SharingMediaEnabled": media,
        "SharingShareExtensionSendEnabled": share_extension_send,
        "SharingReviewPreviewEnabled": review_preview,
        "SharingAPIBaseURL": endpoint,
        "NSPhotoLibraryUsageDescription": (
            "共有シートで選んだ1枚を最大2,048pxへ縮小し、位置情報を除いて"
            "暗号化して送り、原本は自動送信しません。"
        ),
        "SharingModerationKeyID": "moderation-v1",
        "SharingModerationPublicKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "SharingSupportURL": "https://nekonomado.jp/support",
        "SharingCommunityStandardsURL": "https://nekonomado.jp/community",
        "ITSAppUsesNonExemptEncryption": False,
    }


def share_info_from(app_info: dict) -> dict:
    value = dict(app_info)
    value["SharingReviewPreviewEnabled"] = False
    return value


class SharingReleasePreflightTests(unittest.TestCase):
    def run_preflight(
        self,
        info_value: dict,
        privacy_value: dict,
        export_reviewed: str = "YES",
        share_info_value: dict | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            info_path = root / "Info.plist"
            share_info_path = root / "ShareInfo.plist"
            privacy_path = root / "PrivacyInfo.xcprivacy"
            with info_path.open("wb") as stream:
                plistlib.dump(info_value, stream)
            with share_info_path.open("wb") as stream:
                plistlib.dump(
                    share_info_value or share_info_from(info_value),
                    stream,
                )
            with privacy_path.open("wb") as stream:
                plistlib.dump(privacy_value, stream)
            return subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--info-plist",
                    str(info_path),
                    "--share-info-plist",
                    str(share_info_path),
                    "--privacy-manifest",
                    str(privacy_path),
                    "--export-reviewed",
                    export_reviewed,
                ],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_explicit_all_off_is_the_only_disabled_pass(self) -> None:
        result = self.run_preflight(info("NO", "NO"), privacy(), "NO")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("sharing is disabled", result.stdout)

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
        self.assertIn("runtime flags OFF", runtime.stderr)

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
        self.assertIn("requires SharingFeatureEnabled", result.stderr)

    def test_pairing_only_requires_user_id_but_not_photos(self) -> None:
        result = self.run_preflight(
            info(True, False, ENDPOINT),
            privacy(USER_ID),
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        overdeclared = self.run_preflight(
            info(True, False, ENDPOINT),
            privacy(USER_ID, PHOTOS),
        )
        self.assertNotEqual(overdeclared.returncode, 0)
        self.assertIn("not enabled", overdeclared.stderr)

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
        self.assertNotEqual(complete.returncode, 0)
        self.assertIn("host handoff", complete.stderr)

    def test_media_requires_safety_configuration(self) -> None:
        expected_privacy = privacy(USER_ID, PHOTOS, DEVICE_ID, PRODUCT_INTERACTION)
        for key in (
            "SharingModerationKeyID",
            "SharingModerationPublicKey",
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
        self.assertIn("install-bound host authorization", result.stderr)

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
        self.assertIn("SharingAPIBaseURL does not match", result.stderr)

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
