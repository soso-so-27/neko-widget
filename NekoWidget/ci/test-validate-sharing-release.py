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
PURPOSE = "NSPrivacyCollectedDataTypePurposeAppFunctionality"


def privacy(*data_types: str) -> dict:
    return {
        "NSPrivacyTracking": False,
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
) -> dict:
    return {
        "SharingFeatureEnabled": pairing,
        "SharingMediaEnabled": media,
        "SharingReviewPreviewEnabled": review_preview,
        "SharingAPIBaseURL": endpoint,
        "NSPhotoLibraryUsageDescription": (
            "招待した相手へ最大20枚の縮小画像だけを暗号化して送り、原本は送りません。"
        ),
        "ITSAppUsesNonExemptEncryption": False,
    }


class SharingReleasePreflightTests(unittest.TestCase):
    def run_preflight(
        self,
        info_value: dict,
        privacy_value: dict,
        export_reviewed: str = "YES",
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            info_path = root / "Info.plist"
            privacy_path = root / "PrivacyInfo.xcprivacy"
            with info_path.open("wb") as stream:
                plistlib.dump(info_value, stream)
            with privacy_path.open("wb") as stream:
                plistlib.dump(privacy_value, stream)
            return subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--info-plist",
                    str(info_path),
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
            privacy(USER_ID, PHOTOS),
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
            privacy(USER_ID, PHOTOS),
        )
        self.assertEqual(complete.returncode, 0, complete.stderr)

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
