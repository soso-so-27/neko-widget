#!/usr/bin/env python3
"""Static release-boundary checks that also run on Windows."""

from __future__ import annotations

import plistlib
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = ROOT.parent
BASE_CONFIG = ROOT / "Config.xcconfig"
PAIRING_CONFIG = ROOT / "Config.PairingOnly.xcconfig"
PAIRING_PRIVACY = ROOT / "ci" / "PrivacyInfo.PairingOnly.xcprivacy"
APP_PRIVACY = ROOT / "NekoWidget" / "PrivacyInfo.xcprivacy"
SHARE_PRIVACY = ROOT / "NekoWidgetShareExtension" / "PrivacyInfo.xcprivacy"
TESTFLIGHT = REPOSITORY / ".github" / "workflows" / "testflight.yml"


def assignments(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("//") or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Z0-9_]+)\s*=\s*(.*)", line)
        if match:
            values[match.group(1)] = match.group(2).strip()
    return values


def load_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        raise AssertionError(f"{path} must contain a dictionary plist")
    return value


def collected_types(manifest: dict) -> dict[str, dict]:
    return {
        item["NSPrivacyCollectedDataType"]: item
        for item in manifest["NSPrivacyCollectedDataTypes"]
    }


class PairingOnlyReleaseConfigTests(unittest.TestCase):
    def test_review_preview_remains_the_shipping_default(self) -> None:
        values = assignments(BASE_CONFIG)
        self.assertEqual(values["SHARING_RELEASE_MODE"], "review-preview")
        self.assertEqual(values["SHARING_FEATURE_ENABLED"], "NO")
        self.assertEqual(values["SHARING_MEDIA_ENABLED"], "NO")
        self.assertEqual(values["SHARING_SHARE_EXTENSION_HANDOFF_ENABLED"], "NO")
        self.assertEqual(values["SHARING_SHARE_EXTENSION_SEND_ENABLED"], "NO")
        self.assertEqual(values["SHARING_REVIEW_PREVIEW_ENABLED"], "YES")
        self.assertEqual(values["SHARING_API_BASE_URL"], "")

    def test_pairing_only_config_has_no_photo_or_embedded_origin_path(self) -> None:
        source = PAIRING_CONFIG.read_text(encoding="utf-8")
        self.assertIn('#include "Config.xcconfig"', source)
        values = assignments(PAIRING_CONFIG)
        self.assertEqual(values["SHARING_RELEASE_MODE"], "pairing-only")
        self.assertEqual(values["SHARING_FEATURE_ENABLED"], "YES")
        self.assertEqual(values["SHARING_MEDIA_ENABLED"], "NO")
        self.assertEqual(values["SHARING_SHARE_EXTENSION_HANDOFF_ENABLED"], "NO")
        self.assertEqual(values["SHARING_SHARE_EXTENSION_SEND_ENABLED"], "NO")
        self.assertEqual(values["SHARING_REVIEW_PREVIEW_ENABLED"], "NO")
        self.assertEqual(values["SHARING_API_BASE_URL"], "")
        self.assertNotIn("workers.dev", source)
        self.assertNotIn("https://", source)

    def test_pairing_only_app_privacy_is_user_id_only(self) -> None:
        manifest = load_plist(PAIRING_PRIVACY)
        self.assertIs(manifest["NSPrivacyTracking"], False)
        collections = collected_types(manifest)
        self.assertEqual(set(collections), {"NSPrivacyCollectedDataTypeUserID"})
        user_id = collections["NSPrivacyCollectedDataTypeUserID"]
        self.assertIs(user_id["NSPrivacyCollectedDataTypeLinked"], True)
        self.assertIs(user_id["NSPrivacyCollectedDataTypeTracking"], False)
        self.assertEqual(
            user_id["NSPrivacyCollectedDataTypePurposes"],
            ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
        )
        accessed = {
            item["NSPrivacyAccessedAPIType"]: item["NSPrivacyAccessedAPITypeReasons"]
            for item in manifest["NSPrivacyAccessedAPITypes"]
        }
        self.assertIn("CA92.1", accessed["NSPrivacyAccessedAPICategoryUserDefaults"])
        self.assertIn("35F9.1", accessed["NSPrivacyAccessedAPICategorySystemBootTime"])
        self.assertIn("C617.1", accessed["NSPrivacyAccessedAPICategoryFileTimestamp"])

    def test_default_and_share_privacy_boundaries_remain_empty(self) -> None:
        self.assertEqual(collected_types(load_plist(APP_PRIVACY)), {})
        self.assertEqual(collected_types(load_plist(SHARE_PRIVACY)), {})

    def test_testflight_selects_mode_and_origin_explicitly(self) -> None:
        workflow = TESTFLIGHT.read_text(encoding="utf-8")
        required_fragments = (
            "default: review-preview",
            "- pairing-only",
            "${{ vars.SHARING_STAGING_API_ORIGIN }}",
            'release_origin="${SHARING_STAGING_API_ORIGIN:-}"',
            "PrivacyInfo.PairingOnly.xcprivacy",
            'SHARING_RELEASE_MODE="$RELEASE_SHARING_RELEASE_MODE"',
            'SHARING_FEATURE_ENABLED="$RELEASE_SHARING_FEATURE_ENABLED"',
            'SHARING_MEDIA_ENABLED="$RELEASE_SHARING_MEDIA_ENABLED"',
            'SHARING_SHARE_EXTENSION_HANDOFF_ENABLED="$RELEASE_SHARING_HANDOFF_ENABLED"',
            'SHARING_SHARE_EXTENSION_SEND_ENABLED="$RELEASE_SHARING_DIRECT_SEND_ENABLED"',
            'SHARING_REVIEW_PREVIEW_ENABLED="$RELEASE_SHARING_REVIEW_PREVIEW_ENABLED"',
            'SHARING_API_BASE_URL="$RELEASE_SHARING_API_ORIGIN"',
            '--expected-mode "$SHARING_EXPECTED_MODE"',
            '--expected-api-origin "$RELEASE_SHARING_API_ORIGIN"',
            "pairing-only/photos disabled",
        )
        for fragment in required_fragments:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, workflow)
        self.assertNotIn('-xcconfig "$RELEASE_XCCONFIG"', workflow)
        self.assertNotIn("RELEASE_XCCONFIG", workflow)

        review_block = workflow.split("review-preview)", 1)[1].split(";;", 1)[0]
        pairing_block = workflow.split("pairing-only)", 1)[1].split(";;", 1)[0]

        def release_values(block: str) -> dict[str, str]:
            return dict(
                re.findall(
                    r'^\s+(release_[a-z_]+)="([^"]*)"$',
                    block,
                    flags=re.MULTILINE,
                )
            )

        self.assertEqual(
            release_values(review_block),
            {
                "release_origin": "",
                "release_summary": "review-preview/runtime disabled",
                "release_feature": "NO",
                "release_media": "NO",
                "release_handoff": "NO",
                "release_direct_send": "NO",
                "release_review_preview": "YES",
            },
        )
        self.assertEqual(
            release_values(pairing_block),
            {
                "release_origin": "${SHARING_STAGING_API_ORIGIN:-}",
                "release_summary": "pairing-only/photos disabled",
                "release_feature": "YES",
                "release_media": "NO",
                "release_handoff": "NO",
                "release_direct_send": "NO",
                "release_review_preview": "NO",
            },
        )

    def test_app_share_info_carry_the_same_processed_mode_marker(self) -> None:
        for relative in ("NekoWidget/Info.plist", "NekoWidgetShareExtension/Info.plist"):
            with self.subTest(relative=relative):
                source = (ROOT / relative).read_text(encoding="utf-8")
                self.assertIn("<key>SharingReleaseMode</key>", source)
                self.assertIn("<string>$(SHARING_RELEASE_MODE)</string>", source)

    def test_pairing_ui_discloses_the_build_scope(self) -> None:
        sources = "\n".join(
            (ROOT / relative).read_text(encoding="utf-8")
            for relative in (
                "NekoWidget/Views/PairingView.swift",
                "NekoWidget/Views/HomeView.swift",
                "NekoWidget/Views/SettingsView.swift",
            )
        )
        self.assertIn('"ペアリングのみ"', sources)
        self.assertIn("このBuildでは写真を保存・送信しません", sources)
        family_window = (ROOT / "NekoWidget/Views/FamilyWindowView.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("共有の設定・解除", family_window)
        self.assertIn("招待相手の確認と共有解除", family_window)
        self.assertIn("PairingView()", family_window)
        share_extension = (
            ROOT / "NekoWidgetShareExtension/ShareViewController.swift"
        ).read_text(encoding="utf-8")
        photo_gate = "configuration.isEnabled && !configuration.isMediaEnabled"
        self.assertIn(photo_gate, share_extension)
        self.assertLess(
            share_extension.index(photo_gate),
            share_extension.index("selectedImageProvider()"),
        )


if __name__ == "__main__":
    unittest.main()
