#!/usr/bin/env python3
"""Static fail-closed checks for the local-only disabled release mode."""

from __future__ import annotations

import plistlib
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = ROOT.parent
DISABLED_CONFIG = ROOT / "Config.Disabled.xcconfig"
WORKFLOW = REPOSITORY / ".github" / "workflows" / "testflight.yml"
IOS_BUILD = REPOSITORY / ".github" / "workflows" / "ios-build.yml"


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


class DisabledReleaseConfigTests(unittest.TestCase):
    def test_disabled_overlay_is_explicitly_all_off_and_empty(self) -> None:
        source = DISABLED_CONFIG.read_text(encoding="utf-8")
        self.assertIn('#include "Config.xcconfig"', source)
        values = assignments(DISABLED_CONFIG)
        self.assertEqual(
            (
                values["SHARING_RELEASE_MODE"],
                values["SHARING_FEATURE_ENABLED"],
                values["SHARING_MEDIA_ENABLED"],
                values["SHARING_SHARE_EXTENSION_HANDOFF_ENABLED"],
                values["SHARING_SHARE_EXTENSION_SEND_ENABLED"],
                values["SHARING_REVIEW_PREVIEW_ENABLED"],
            ),
            ("disabled", "NO", "NO", "NO", "NO", "NO"),
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

    def test_workflow_defaults_to_disabled_and_removes_share_activation(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("default: disabled", workflow)
        self.assertIn("- disabled", workflow)
        disabled = workflow.split("disabled)", 1)[1].split(";;", 1)[0]
        for fragment in (
            'release_origin=""',
            'release_feature="NO"',
            'release_media="NO"',
            'release_handoff="NO"',
            'release_direct_send="NO"',
            'release_review_preview="NO"',
            'share_activation_count="0"',
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, disabled)
        self.assertIn(
            "NSExtensionActivationSupportsImageWithMaxCount $share_activation_count",
            workflow,
        )
        self.assertIn('--widget-info-plist "$widget_path/Info.plist"', workflow)

    def test_disabled_uses_the_noncollecting_privacy_manifest(self) -> None:
        with (ROOT / "NekoWidget" / "PrivacyInfo.xcprivacy").open("rb") as handle:
            manifest = plistlib.load(handle)
        self.assertIs(manifest["NSPrivacyTracking"], False)
        self.assertEqual(manifest["NSPrivacyTrackingDomains"], [])
        self.assertEqual(manifest["NSPrivacyCollectedDataTypes"], [])

    def test_all_processed_bundles_carry_the_release_boundary(self) -> None:
        for relative in (
            "NekoWidget/Info.plist",
            "NekoWidgetWidget/Info.plist",
            "NekoWidgetShareExtension/Info.plist",
        ):
            with self.subTest(relative=relative):
                source = (ROOT / relative).read_text(encoding="utf-8")
                self.assertIn("<key>SharingReleaseMode</key>", source)
                self.assertIn("<string>$(SHARING_RELEASE_MODE)</string>", source)

    def test_disabled_runtime_closes_nonstandard_entry_points(self) -> None:
        app_model = (ROOT / "NekoWidget/ViewModels/AppViewModel.swift").read_text(
            encoding="utf-8"
        )
        family_case = app_model.split("case .familyWindow:", 1)[1].split(
            "\n        }\n        guard let readyRoute", 1
        )[0]
        self.assertIn("isReviewVisible", family_case)
        self.assertLess(
            family_case.index("guard SharingAPIConfiguration.current.isReviewVisible"),
            family_case.index("isFamilyWindowPresented = true"),
        )

        home = (ROOT / "NekoWidget/Views/HomeView.swift").read_text(encoding="utf-8")
        destination = home.split("private var familyWindowDestination", 1)[1].split(
            "private var familyWindowSubtitle", 1
        )[0]
        self.assertIn("isReviewPreviewEnabled", destination)
        self.assertIn("EmptyView()", destination)

        share = (
            ROOT / "NekoWidgetShareExtension/ShareViewController.swift"
        ).read_text(encoding="utf-8")
        self.assertLess(
            share.index("guard !SharingAPIConfiguration.current.isDisabledRelease"),
            share.index("configureView()"),
        )
        self.assertLess(
            share.index("guard !SharingAPIConfiguration.current.isDisabledRelease"),
            share.index("selectedImageProvider()"),
        )

    def test_stale_family_widget_and_polling_fail_closed(self) -> None:
        timeline = (
            ROOT / "NekoWidgetWidget/NekoWidgetTimelineProvider.swift"
        ).read_text(encoding="utf-8")
        self.assertEqual(timeline.count("guard WidgetPhotoSource.familyWindowSourceIsEnabled"), 2)
        first_guard = timeline.index("guard WidgetPhotoSource.familyWindowSourceIsEnabled")
        self.assertLess(first_guard, timeline.index("return familySnapshot"))
        second_guard = timeline.index(
            "guard WidgetPhotoSource.familyWindowSourceIsEnabled", first_guard + 1
        )
        self.assertLess(second_guard, timeline.index("return familyTimeline"))

        root_view = (ROOT / "NekoWidget/App/AppRootView.swift").read_text(
            encoding="utf-8"
        )
        poll_task = root_view.split(".task(id: scenePhase)", 1)[1].split(
            ".onChange(of: viewModel.isScanning", 1
        )[0]
        self.assertIn(
            "guard SharingAPIConfiguration.current.isMediaAvailable else { return }",
            poll_task,
        )

    def test_ios_ci_runs_the_disabled_boundary_test(self) -> None:
        self.assertIn(
            "python3 ci/test-disabled-release-config.py",
            IOS_BUILD.read_text(encoding="utf-8"),
        )


if __name__ == "__main__":
    unittest.main()
