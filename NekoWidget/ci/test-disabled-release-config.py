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
BASE_CONFIG = ROOT / "Config.xcconfig"
PROJECT = ROOT / "NekoWidget.xcodeproj" / "project.pbxproj"
WORKFLOW = REPOSITORY / ".github" / "workflows" / "testflight.yml"
IOS_BUILD = REPOSITORY / ".github" / "workflows" / "ios-build.yml"
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

        description = values["PHOTO_LIBRARY_USAGE_DESCRIPTION"]
        for term in LOCAL_PHOTO_DESCRIPTION_TERMS:
            self.assertIn(term, description)
        for term in LOCAL_PHOTO_DESCRIPTION_FORBIDDEN_TERMS:
            self.assertNotIn(term, description)
        self.assertEqual(
            values["SHARE_EXTENSION_INFOPLIST_FILE"],
            "NekoWidgetShareExtension/Info.Disabled.plist",
        )

    def test_every_shipped_release_target_uses_the_disabled_overlay(self) -> None:
        project = PROJECT.read_text(encoding="utf-8")
        disabled_reference = (
            "baseConfigurationReference = F00000000000000000000002 "
            "/* Config.Disabled.xcconfig */;"
        )
        for identifier in (
            "A00000000000000000000051",  # project
            "A00000000000000000000053",  # app
            "A00000000000000000000055",  # Widget
            "A00000000000000000000059",  # Share Extension
        ):
            with self.subTest(identifier=identifier):
                block = project.split(f"{identifier} /* Release */", 1)[1].split(
                    "\n\t\t};", 1
                )[0]
                self.assertIn(disabled_reference, block)
        self.assertEqual(project.count(disabled_reference), 4)
        self.assertIn(
            'INFOPLIST_FILE = "$(SHARE_EXTENSION_INFOPLIST_FILE)";',
            project,
        )

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
            'release_share_info_plist="NekoWidgetShareExtension/Info.Disabled.plist"',
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, disabled)
        media = workflow.split("media-staging)", 1)[1].split(";;", 1)[0]
        self.assertIn(
            'release_photo_usage_description="$media_photo_usage_description"',
            media,
        )
        self.assertIn(
            'PHOTO_LIBRARY_USAGE_DESCRIPTION="$RELEASE_PHOTO_LIBRARY_USAGE_DESCRIPTION"',
            workflow,
        )
        self.assertIn(
            'SHARE_EXTENSION_INFOPLIST_FILE="$RELEASE_SHARE_EXTENSION_INFOPLIST_FILE"',
            workflow,
        )
        self.assertIn("--expected-photo-library-usage-description", workflow)
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
            "NekoWidgetShareExtension/Info.Disabled.plist",
        ):
            with self.subTest(relative=relative):
                source = (ROOT / relative).read_text(encoding="utf-8")
                self.assertIn("<key>SharingReleaseMode</key>", source)
                self.assertIn("<string>$(SHARING_RELEASE_MODE)</string>", source)

    def test_disabled_permission_copy_and_share_activation_are_truthful(self) -> None:
        app_info = (ROOT / "NekoWidget/Info.plist").read_text(encoding="utf-8")
        self.assertIn("$(PHOTO_LIBRARY_USAGE_DESCRIPTION)", app_info)
        self.assertNotIn("写真共有が有効なBuild", app_info)

        base_values = assignments(BASE_CONFIG)
        disabled_values = assignments(DISABLED_CONFIG)
        self.assertEqual(
            disabled_values["PHOTO_LIBRARY_USAGE_DESCRIPTION"],
            base_values["PHOTO_LIBRARY_USAGE_DESCRIPTION"],
        )

        with (ROOT / "NekoWidgetShareExtension/Info.plist").open("rb") as handle:
            enabled_share = plistlib.load(handle)
        with (ROOT / "NekoWidgetShareExtension/Info.Disabled.plist").open(
            "rb"
        ) as handle:
            disabled_share = plistlib.load(handle)
        enabled_rule = enabled_share["NSExtension"]["NSExtensionAttributes"][
            "NSExtensionActivationRule"
        ]
        disabled_rule = disabled_share["NSExtension"]["NSExtensionAttributes"][
            "NSExtensionActivationRule"
        ]
        self.assertEqual(
            enabled_rule["NSExtensionActivationSupportsImageWithMaxCount"], 1
        )
        self.assertEqual(disabled_rule, "FALSEPREDICATE")
        enabled_without_extension = dict(enabled_share)
        disabled_without_extension = dict(disabled_share)
        enabled_without_extension.pop("NSExtension")
        disabled_without_extension.pop("NSExtension")
        self.assertEqual(enabled_without_extension, disabled_without_extension)

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

        home = (ROOT / "NekoWidget/Views/HomeView.swift").read_text(
            encoding="utf-8"
        )
        body = home.split("var body: some View", 1)[1].split(
            "private var emptyState", 1
        )[0]
        self.assertLess(
            body.index("if SharingAPIConfiguration.current.isReviewVisible"),
            body.index("familyWindowCard"),
        )

        pairing = (ROOT / "NekoWidget/ViewModels/PairingViewModel.swift").read_text(
            encoding="utf-8"
        )
        initializer = pairing.split("init(configuration:", 1)[1].split(
            "var isConfigured", 1
        )[0]
        self.assertLess(
            initializer.index("if configuration.isAvailable"),
            initializer.index("URLSessionPairingAPIClient"),
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
        ios_build = IOS_BUILD.read_text(encoding="utf-8")
        self.assertIn("python3 ci/test-disabled-release-config.py", ios_build)
        self.assertIn("python3 ci/test-disabled-release-build-settings.py", ios_build)
        self.assertIn("validate-disabled-release-build-settings.py", ios_build)
        self.assertIn("-configuration Release", ios_build)
        smoke = (ROOT / "ci/run-simulator-smoke.sh").read_text(encoding="utf-8")
        self.assertGreaterEqual(
            smoke.count('-xcconfig "$PROJECT_DIRECTORY/Config.Disabled.xcconfig"'),
            2,
        )
        self.assertIn("NEKO_EXPECT_DISABLED_RELEASE=1 xcodebuild", smoke)
        ui_test = (ROOT / "NekoWidgetUITests/PhotoPermissionUITests.swift").read_text(
            encoding="utf-8"
        )
        for identifier in (
            "window-family-window-review",
            "window-latest-family-photo",
            "settings-sharing-review",
        ):
            self.assertIn(identifier, ui_test)


if __name__ == "__main__":
    unittest.main()
