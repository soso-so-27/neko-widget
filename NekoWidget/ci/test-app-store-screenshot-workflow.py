#!/usr/bin/env python3
"""Static privacy and release-boundary contract for App Store capture."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = ROOT.parent


def source(path: str) -> str:
    return (REPOSITORY / path).read_text(encoding="utf-8")


class AppStoreScreenshotWorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = source(".github/workflows/app-store-screenshots.yml")
        self.fixture = source("NekoWidget/NekoWidget/App/AppStoreScreenshotFixture.swift")
        self.photo_image = source("NekoWidget/NekoWidget/Views/PhotoAssetImageView.swift")
        self.ui_test = source("NekoWidget/NekoWidgetUITests/AppStoreScreenshotUITests.swift")
        self.exporter = source("NekoWidget/ci/export-app-store-screenshots.sh")
        self.project = source("NekoWidget/NekoWidget.xcodeproj/project.pbxproj")

    def test_workflow_is_manual_and_does_not_publish(self) -> None:
        trigger = self.workflow.split("on:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("workflow_dispatch:", trigger)
        for forbidden_trigger in ("push:", "pull_request:", "schedule:"):
            self.assertNotIn(forbidden_trigger, trigger)
        for forbidden_action in (
            "gh api",
            "altool",
            "notarytool",
            "app-store-connect",
            "upload_to_testflight",
        ):
            self.assertNotIn(forbidden_action, self.workflow.lower())

    def test_capture_uses_erased_iphone_and_no_media_import(self) -> None:
        self.assertGreaterEqual(
            self.workflow.count('xcrun simctl erase "$simulator_udid"'),
            2,
        )
        self.assertIn('CAPTURE_IOS_RUNTIME: com.apple.CoreSimulator.SimRuntime.iOS-26-2', self.workflow)
        self.assertIn('"iPhone 17 Pro Max"', self.workflow)
        self.assertIn('"iPhone 16 Pro Max"', self.workflow)
        self.assertNotIn("simctl addmedia", self.workflow)
        self.assertNotIn("ci/fixtures/cats", self.workflow)

    def test_capture_build_is_explicitly_local_only(self) -> None:
        required = {
            "SHARING_RELEASE_MODE=disabled",
            "SHARING_FEATURE_ENABLED=NO",
            "SHARING_MEDIA_ENABLED=NO",
            "SHARING_SHARE_EXTENSION_HANDOFF_ENABLED=NO",
            "SHARING_SHARE_EXTENSION_SEND_ENABLED=NO",
            "SHARING_REVIEW_PREVIEW_ENABLED=NO",
            "SHARING_API_BASE_URL=",
            "SHARING_MODERATION_KEY_ID=",
            "SHARING_MODERATION_PUBLIC_KEY=",
            "SHARE_EXTENSION_INFOPLIST_FILE=NekoWidgetShareExtension/Info.Disabled.plist",
        }
        for value in required:
            self.assertIn(value, self.workflow)
        self.assertIn("releaseBoundary\": \"local-only-disabled", self.exporter)

    def test_fixture_is_debug_only_and_owns_no_external_input(self) -> None:
        self.assertTrue(self.fixture.startswith("#if DEBUG\n"))
        self.assertTrue(self.fixture.rstrip().endswith("#endif"))
        self.assertIn("UIGraphicsImageRenderer", self.fixture)
        self.assertIn("CGGradient", self.fixture)
        self.assertIn('identifierPrefix = "app-store-screenshot-fixture-"', self.fixture)
        self.assertIn("static func isFixtureIdentifier", self.fixture)
        for forbidden in (
            "URLSession.",
            "PHAsset.",
            "import Photos",
            "CLLocation(",
            "UIImage(named:",
            "Data(contentsOf:",
            "http://",
            "https://",
        ):
            self.assertNotIn(forbidden, self.fixture)

        app = source("NekoWidget/NekoWidget/App/NekoWidgetApp.swift")
        debug_start = app.index("#if DEBUG", app.index("var body: some Scene"))
        release_branch = app.index("#else", debug_start)
        fixture_route = app.index("AppStoreScreenshotFixture.launchArgument", debug_start)
        self.assertLess(fixture_route, release_branch)

    def test_ui_test_and_exporter_agree_on_four_ordered_names(self) -> None:
        names = [
            "01-on-device-photo-privacy",
            "02-private-photo-window",
            "03-organized-memories",
            "04-liked-photos",
        ]
        for name in names:
            self.assertEqual(self.ui_test.count(f'captureScreenshot(named: "{name}")'), 1)
            self.assertEqual(self.exporter.count(f'"{name}"'), 1)
        self.assertIn("・写真は端末の外に出ません", self.ui_test)
        self.assertIn("--app-store-screenshot-fixture", self.ui_test)
        self.assertIn(
            "AppStoreScreenshotFixture.loadTracker.record(",
            self.photo_image,
        )
        self.assertIn("private var loadedAccessibilityMarkers", self.fixture)
        self.assertIn(".accessibilityElement(children: .contain)", self.fixture)
        self.assertIn(
            '"app-store-screenshot-fixture-photo-loaded-"',
            self.fixture,
        )
        self.assertIn("requirements: [(12, 1)]", self.ui_test)
        self.assertIn("requirements: [(8, 2)]", self.ui_test)
        self.assertIn("requirements: [(9, 1), (10, 1), (11, 1)]", self.ui_test)
        self.assertNotIn("waitForStableRendering", self.ui_test)

    def test_exporter_rejects_wrong_size_or_metadata(self) -> None:
        for dimensions in ("(1260, 2736)", "(1290, 2796)", "(1320, 2868)"):
            self.assertIn(dimensions, self.exporter)
        self.assertIn('"format": "jpeg"', self.exporter)
        self.assertIn("if marker == 0xE1", self.exporter)
        self.assertIn("contains a JPEG APP1 metadata segment", self.exporter)
        self.assertIn('"userReviewRequiredBeforeUpload": True', self.exporter)
        self.assertIn(
            '"releaseArchiveVerification": "not-performed-by-debug-capture-workflow"',
            self.exporter,
        )
        self.assertNotIn("releaseArchiveContainsFixtureRoute", self.exporter)
        self.assertIn('rm -rf "$RAW_DIRECTORY"', self.exporter)

    def test_xcode_project_references_both_new_swift_sources(self) -> None:
        self.assertEqual(self.project.count("AppStoreScreenshotFixture.swift"), 6)
        self.assertEqual(self.project.count("AppStoreScreenshotUITests.swift"), 6)

    def test_documentation_keeps_owner_and_macos_gates(self) -> None:
        documentation = source("NekoWidget/docs/App-Store-スクリーンショット撮影.md")
        self.assertIn("App Store Connectへのアップロードや提出は行わない", documentation)
        self.assertIn("アップロード前の人による確認", documentation)
        self.assertIn("macOSでのみ残る検証", documentation)
        self.assertIn("Content Rights", documentation)


if __name__ == "__main__":
    unittest.main()
