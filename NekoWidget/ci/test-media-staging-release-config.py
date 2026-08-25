#!/usr/bin/env python3
"""Static fail-closed checks for the two-device media-staging release mode."""

from __future__ import annotations

import plistlib
import re
import subprocess
import sys
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = ROOT.parent
BASE_CONFIG = ROOT / "Config.xcconfig"
PAIRING_CONFIG = ROOT / "Config.PairingOnly.xcconfig"
MEDIA_CONFIG = ROOT / "Config.MediaStaging.xcconfig"
MEDIA_PRIVACY = ROOT / "ci" / "PrivacyInfo.MediaStaging.xcprivacy"
WORKFLOW = REPOSITORY / ".github/workflows/testflight.yml"

USER_ID = "NSPrivacyCollectedDataTypeUserID"
PHOTOS = "NSPrivacyCollectedDataTypePhotosorVideos"
DEVICE_ID = "NSPrivacyCollectedDataTypeDeviceID"
PRODUCT_INTERACTION = "NSPrivacyCollectedDataTypeProductInteraction"
APP_FUNCTIONALITY = "NSPrivacyCollectedDataTypePurposeAppFunctionality"


def assignments(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("//", "#")):
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


class MediaStagingReleaseConfigTests(unittest.TestCase):
    def test_existing_shipping_and_pairing_defaults_are_unchanged(self) -> None:
        base = assignments(BASE_CONFIG)
        self.assertEqual(
            (
                base["SHARING_RELEASE_MODE"],
                base["SHARING_FEATURE_ENABLED"],
                base["SHARING_MEDIA_ENABLED"],
                base["SHARING_SHARE_EXTENSION_HANDOFF_ENABLED"],
                base["SHARING_SHARE_EXTENSION_SEND_ENABLED"],
                base["SHARING_REVIEW_PREVIEW_ENABLED"],
            ),
            ("review-preview", "NO", "NO", "NO", "NO", "YES"),
        )
        pairing = assignments(PAIRING_CONFIG)
        self.assertEqual(
            (
                pairing["SHARING_RELEASE_MODE"],
                pairing["SHARING_FEATURE_ENABLED"],
                pairing["SHARING_MEDIA_ENABLED"],
                pairing["SHARING_SHARE_EXTENSION_HANDOFF_ENABLED"],
                pairing["SHARING_SHARE_EXTENSION_SEND_ENABLED"],
                pairing["SHARING_REVIEW_PREVIEW_ENABLED"],
            ),
            ("pairing-only", "YES", "NO", "NO", "NO", "NO"),
        )

    def test_media_overlay_enables_only_installation_bound_media(self) -> None:
        source = MEDIA_CONFIG.read_text(encoding="utf-8")
        self.assertIn('#include "Config.xcconfig"', source)
        values = assignments(MEDIA_CONFIG)
        self.assertEqual(
            (
                values["SHARING_RELEASE_MODE"],
                values["SHARING_FEATURE_ENABLED"],
                values["SHARING_MEDIA_ENABLED"],
                values["SHARING_SHARE_EXTENSION_HANDOFF_ENABLED"],
                values["SHARING_SHARE_EXTENSION_SEND_ENABLED"],
                values["SHARING_REVIEW_PREVIEW_ENABLED"],
            ),
            ("media-staging", "YES", "YES", "YES", "NO", "NO"),
        )
        for key in (
            "SHARING_API_BASE_URL",
            "SHARING_MODERATION_KEY_ID",
            "SHARING_MODERATION_PUBLIC_KEY",
            "SHARING_PRIVACY_URL",
            "SHARING_SUPPORT_URL",
            "SHARING_COMMUNITY_STANDARDS_URL",
        ):
            with self.subTest(key=key):
                self.assertEqual(values[key], "")
        self.assertNotIn("https://", source)
        self.assertNotIn("workers.dev", source)

    def test_media_privacy_manifest_is_exact_and_nontracking(self) -> None:
        manifest = load_plist(MEDIA_PRIVACY)
        self.assertIs(manifest["NSPrivacyTracking"], False)
        self.assertEqual(manifest["NSPrivacyTrackingDomains"], [])
        items = manifest["NSPrivacyCollectedDataTypes"]
        by_type = {item["NSPrivacyCollectedDataType"]: item for item in items}
        self.assertEqual(
            set(by_type),
            {USER_ID, PHOTOS, DEVICE_ID, PRODUCT_INTERACTION},
        )
        self.assertEqual(len(items), 4)
        for data_type, item in by_type.items():
            with self.subTest(data_type=data_type):
                self.assertIs(item["NSPrivacyCollectedDataTypeLinked"], True)
                self.assertIs(item["NSPrivacyCollectedDataTypeTracking"], False)
                self.assertEqual(
                    item["NSPrivacyCollectedDataTypePurposes"],
                    [APP_FUNCTIONALITY],
                )

    def test_workflow_injects_only_protected_media_values_and_verifies_archive(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(
            '届いた写真は、あなたが「写真アプリへコピー」を明示的に選んだ場合だけ追加します',
            workflow,
        )
        self.assertNotIn(
            '受信した写真を自動的に写真アプリへ追加します',
            workflow,
        )
        variable_names = (
            "SHARING_STAGING_API_ORIGIN",
            "SHARING_STAGING_MODERATION_KEY_ID",
            "SHARING_STAGING_MODERATION_PUBLIC_KEY",
            "SHARING_STAGING_PRIVACY_URL",
            "SHARING_STAGING_SUPPORT_URL",
            "SHARING_STAGING_COMMUNITY_STANDARDS_URL",
        )
        self.assertIn("- media-staging", workflow)
        for name in variable_names:
            with self.subTest(name=name):
                self.assertIn(f"${{{{ vars.{name} }}}}", workflow)
                self.assertNotIn(f"${{{{ secrets.{name} }}}}", workflow)

        media_block = workflow.split("media-staging)", 1)[1].split(";;", 1)[0]
        expected_fragments = (
            'release_feature="YES"',
            'release_media="YES"',
            'release_handoff="YES"',
            'release_direct_send="NO"',
            'release_review_preview="NO"',
            'release_photo_usage_description="$media_photo_usage_description"',
            "PrivacyInfo.MediaStaging.xcprivacy",
        )
        for fragment in expected_fragments:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, media_block)

        archive_and_preflight_fragments = (
            'SHARING_RELEASE_MODE="$RELEASE_SHARING_RELEASE_MODE"',
            'SHARING_MEDIA_ENABLED="$RELEASE_SHARING_MEDIA_ENABLED"',
            'SHARING_SHARE_EXTENSION_HANDOFF_ENABLED="$RELEASE_SHARING_HANDOFF_ENABLED"',
            'SHARING_SHARE_EXTENSION_SEND_ENABLED="$RELEASE_SHARING_DIRECT_SEND_ENABLED"',
            'APP_PRIVACY_URL="$RELEASE_APP_PRIVACY_URL"',
            'APP_SUPPORT_URL="$RELEASE_APP_SUPPORT_URL"',
            'SHARING_PRIVACY_URL="$RELEASE_SHARING_PRIVACY_URL"',
            'PHOTO_LIBRARY_USAGE_DESCRIPTION="$RELEASE_PHOTO_LIBRARY_USAGE_DESCRIPTION"',
            'SHARE_EXTENSION_INFOPLIST_FILE="$RELEASE_SHARE_EXTENSION_INFOPLIST_FILE"',
            '--expected-mode "$SHARING_EXPECTED_MODE"',
            '--expected-photo-library-usage-description "$RELEASE_PHOTO_LIBRARY_USAGE_DESCRIPTION"',
            '--expected-moderation-public-key "$RELEASE_SHARING_MODERATION_PUBLIC_KEY"',
            '--expected-app-privacy-url "$RELEASE_APP_PRIVACY_URL"',
            '--expected-app-support-url "$RELEASE_APP_SUPPORT_URL"',
            '--expected-privacy-url "$RELEASE_SHARING_PRIVACY_URL"',
            '--expected-support-url "$RELEASE_SHARING_SUPPORT_URL"',
            '--expected-community-standards-url "$RELEASE_SHARING_COMMUNITY_STANDARDS_URL"',
        )
        for fragment in archive_and_preflight_fragments:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, workflow)

    def test_release_selector_bash_and_embedded_python_are_valid(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        step = workflow.split("- name: Select fail-closed release mode", 1)[1]
        step = step.split("\n      - name:", 1)[0]
        shell_source = textwrap.dedent(step.split("run: |", 1)[1]).lstrip()
        bash_check = subprocess.run(
            ["bash", "-n"],
            input=shell_source.replace("\r", "").encode("utf-8"),
            capture_output=True,
            check=False,
        )
        self.assertEqual(
            bash_check.returncode,
            0,
            bash_check.stderr.decode("utf-8", errors="replace"),
        )

        marker = '"$release_community_standards_url" <<\'PY\'\n'
        embedded = workflow.split(marker, 1)[1].split("\n          PY", 1)[0]
        embedded = textwrap.dedent(embedded)
        compile(embedded, "testflight-release-selector", "exec")

        public_dns_stub = (
            "import socket\n"
            "socket.getaddrinfo = lambda *args, **kwargs: "
            "[(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('93.184.216.34', 443))]\n"
        )
        valid_arguments = [
            "media-staging",
            "https://sharing.nekonomado.jp",
            "https://nekonomado.jp/privacy",
            "https://nekonomado.jp/support",
            "moderation-v1",
            "hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo",
            "https://nekonomado.jp/privacy",
            "https://nekonomado.jp/support",
            "https://nekonomado.jp/community",
        ]
        valid = subprocess.run(
            [sys.executable, "-c", public_dns_stub + embedded, *valid_arguments],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(valid.returncode, 0, valid.stderr)

        missing_privacy = list(valid_arguments)
        missing_privacy[2] = ""
        missing_privacy[6] = ""
        invalid = subprocess.run(
            [sys.executable, "-c", public_dns_stub + embedded, *missing_privacy],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("SHARING_STAGING_PRIVACY_URL", invalid.stderr)

        small_order_key = list(valid_arguments)
        small_order_key[5] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        invalid = subprocess.run(
            [sys.executable, "-c", public_dns_stub + embedded, *small_order_key],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("small-order X25519 point", invalid.stderr)

    def test_privacy_policy_is_a_required_runtime_gate_and_visible_before_consent(self) -> None:
        info = (ROOT / "NekoWidget/Info.plist").read_text(encoding="utf-8")
        configuration = (
            ROOT / "Shared/Sharing/SharingAPIConfiguration.swift"
        ).read_text(encoding="utf-8")
        pairing = (ROOT / "NekoWidget/Views/PairingView.swift").read_text(
            encoding="utf-8"
        )
        family = (ROOT / "NekoWidget/Views/FamilyWindowView.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("<key>SharingPrivacyURL</key>", info)
        self.assertIn("<string>$(SHARING_PRIVACY_URL)</string>", info)
        self.assertIn('info["SharingPrivacyURL"]', configuration)
        self.assertIn("&& privacyURL != nil", configuration)
        self.assertIn("hasSmallOrderX25519PublicKey", configuration)
        self.assertEqual(pairing.count('Link("プライバシーポリシーを確認"'), 2)
        self.assertEqual(pairing.count('Link("コミュニティ基準を確認"'), 2)
        self.assertIn('Link("プライバシーポリシー"', family)


if __name__ == "__main__":
    unittest.main()
