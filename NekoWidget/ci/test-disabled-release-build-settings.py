#!/usr/bin/env python3
"""Regression tests for resolved ordinary Release build settings."""

from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate-disabled-release-build-settings.py")
LOCAL_DESCRIPTION = (
    "猫の写真を端末内で見つけて整理し、「うちの子」アルバムとウィジェットへ反映します。"
)
TARGETS = {
    "NekoWidget": "NekoWidget/Info.plist",
    "NekoWidgetWidgetExtension": "NekoWidgetWidget/Info.plist",
    "NekoWidgetShareExtension": "NekoWidgetShareExtension/Info.Disabled.plist",
}


def fixture() -> list[dict]:
    values = []
    for target, info_plist in TARGETS.items():
        values.append(
            {
                "target": target,
                "buildSettings": {
                    "CONFIGURATION": "Release",
                    "INFOPLIST_FILE": info_plist,
                    "SHARE_EXTENSION_INFOPLIST_FILE": (
                        "NekoWidgetShareExtension/Info.Disabled.plist"
                    ),
                    "PHOTO_LIBRARY_USAGE_DESCRIPTION": LOCAL_DESCRIPTION,
                    "SHARING_RELEASE_MODE": "disabled",
                    "SHARING_FEATURE_ENABLED": "NO",
                    "SHARING_MEDIA_ENABLED": "NO",
                    "SHARING_SHARE_EXTENSION_HANDOFF_ENABLED": "NO",
                    "SHARING_SHARE_EXTENSION_SEND_ENABLED": "NO",
                    "SHARING_REVIEW_PREVIEW_ENABLED": "NO",
                    "SHARING_API_BASE_URL": "",
                    "SHARING_MODERATION_KEY_ID": "",
                    "SHARING_MODERATION_PUBLIC_KEY": "",
                    "SHARING_PRIVACY_URL": "",
                    "SHARING_SUPPORT_URL": "",
                    "SHARING_COMMUNITY_STANDARDS_URL": "",
                },
            }
        )
    return values


class DisabledReleaseBuildSettingsTests(unittest.TestCase):
    def run_validator(self, value: object) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings.json"
            path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(path)],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_valid_release_settings_pass(self) -> None:
        result = self.run_validator(fixture())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("all off", result.stdout)

    def test_cli_combines_one_resolved_file_per_shipped_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for index, entry in enumerate(fixture()):
                path = Path(directory) / f"target-{index}.json"
                path.write_text(
                    json.dumps([entry], ensure_ascii=False), encoding="utf-8"
                )
                paths.append(str(path))
            result = subprocess.run(
                [sys.executable, str(SCRIPT), *paths],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("all off", result.stdout)

    def test_each_sharing_flag_fails_open_detection(self) -> None:
        for key in (
            "SHARING_RELEASE_MODE",
            "SHARING_FEATURE_ENABLED",
            "SHARING_MEDIA_ENABLED",
            "SHARING_SHARE_EXTENSION_HANDOFF_ENABLED",
            "SHARING_SHARE_EXTENSION_SEND_ENABLED",
            "SHARING_REVIEW_PREVIEW_ENABLED",
        ):
            with self.subTest(key=key):
                value = fixture()
                value[0]["buildSettings"][key] = (
                    "review-preview" if key == "SHARING_RELEASE_MODE" else "YES"
                )
                result = self.run_validator(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(key, result.stderr)

    def test_network_value_and_enabled_share_plist_fail(self) -> None:
        value = fixture()
        value[1]["buildSettings"]["SHARING_API_BASE_URL"] = (
            "https://sharing.invalid"
        )
        value[2]["buildSettings"]["INFOPLIST_FILE"] = (
            "NekoWidgetShareExtension/Info.plist"
        )
        result = self.run_validator(value)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("empty SHARING_API_BASE_URL", result.stderr)
        self.assertIn("Info.Disabled.plist", result.stderr)

    def test_duplicate_target_fails_closed(self) -> None:
        value = fixture()
        value.append(copy.deepcopy(value[0]))
        result = self.run_validator(value)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate target NekoWidget", result.stderr)

    def test_missing_target_and_misleading_photo_copy_fail(self) -> None:
        value = copy.deepcopy(fixture()[:-1])
        value[0]["buildSettings"]["PHOTO_LIBRARY_USAGE_DESCRIPTION"] = (
            "猫の写真を端末内で解析し、相手へ共有して履歴に残します。"
        )
        result = self.run_validator(value)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing target NekoWidgetShareExtension", result.stderr)
        self.assertIn("contains sharing terms", result.stderr)

    def test_ci_resolves_each_shipped_target_explicitly(self) -> None:
        workflow = (SCRIPT.parents[2] / ".github/workflows/ios-build.yml").read_text(
            encoding="utf-8"
        )
        start = workflow.index("- name: Resolve fail-closed ordinary Release settings")
        end = workflow.index(
            "- name: Build disabled app and extensions for iOS Simulator", start
        )
        step = workflow[start:end]
        for target in TARGETS:
            self.assertIn(target, step)
        self.assertIn('-target "$target"', step)
        self.assertIn('settings_paths+=("$output")', step)
        self.assertIn('"${settings_paths[@]}"', step)
        self.assertNotIn("-scheme NekoWidget", step)


if __name__ == "__main__":
    unittest.main()
