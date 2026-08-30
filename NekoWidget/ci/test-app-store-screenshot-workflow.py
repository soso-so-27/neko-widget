#!/usr/bin/env python3
"""Static privacy and release-boundary contract for App Store capture."""

from __future__ import annotations

import struct
import tempfile
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
        self.album_view = source("NekoWidget/NekoWidget/Views/LikedPhotosView.swift")
        self.ui_test = source("NekoWidget/NekoWidgetUITests/AppStoreScreenshotUITests.swift")
        self.widget_ui_test = source(
            "NekoWidget/NekoWidgetUITests/WidgetPlacementScreenshotUITests.swift"
        )
        self.widget_provider = source(
            "NekoWidget/NekoWidgetWidget/NekoWidgetTimelineProvider.swift"
        )
        self.widget_view = source("NekoWidget/NekoWidgetWidget/NekoWidgetView.swift")
        self.widget_loader = source(
            "NekoWidget/NekoWidgetWidget/WidgetCacheImageLoader.swift"
        )
        self.config = source("NekoWidget/Config.xcconfig")
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
        self.assertNotIn("installWidgetPreviewFixture", self.fixture)
        self.assertNotIn("WidgetCenter.shared.reloadAllTimelines()", self.fixture)
        self.assertNotIn("--app-store-widget-screenshot-fixture", app)
        self.assertNotIn("--app-store-widget-screenshot-fixture", self.widget_ui_test)
        self.assertIn(
            "WidgetPlacementScreenshotUITests/testCaptureJapaneseLocalOnlyWidgetPreviewForAppStore",
            self.workflow,
        )
        condition = "APP_STORE_SCREENSHOT_WIDGET_FIXTURE"
        dual_guard = f"#if DEBUG && {condition}"
        self.assertIn(
            f"WIDGET_SCREENSHOT_FIXTURE_CONDITION={condition}",
            self.workflow,
        )
        self.assertIn("WIDGET_SCREENSHOT_FIXTURE_CONDITION =\n", self.config)
        self.assertEqual(self.project.count("$(WIDGET_SCREENSHOT_FIXTURE_CONDITION)"), 1)
        widget_debug = self.project.split(
            "A00000000000000000000054 /* Debug */",
            1,
        )[1].split("A00000000000000000000055 /* Release */", 1)[0]
        self.assertIn("$(WIDGET_SCREENSHOT_FIXTURE_CONDITION)", widget_debug)
        self.assertGreaterEqual(self.widget_provider.count(dual_guard), 3)
        self.assertIn(dual_guard, self.widget_view)
        self.assertIn("#if APP_STORE_SCREENSHOT_WIDGET_FIXTURE && !DEBUG", self.widget_view)
        self.assertIn("#error(", self.widget_view)
        self.assertIn('cacheFilename = "app-store-widget-gallery-preview.fixture"', self.widget_view)
        self.assertIn("localIdentifier: nil", self.widget_view)
        self.assertIn("isLikeInteractionEnabled: false", self.widget_view)
        self.assertIn("UIGraphicsImageRenderer", self.widget_view)
        self.assertIn(dual_guard, self.widget_loader)
        self.assertIn("AppStoreWidgetPreviewFixture.image", self.widget_loader)
        self.assertIn(".accessibilityElement(children: .ignore)", self.widget_view)
        self.assertNotIn("URLSession.", self.widget_view)
        self.assertNotIn("PHAsset.", self.widget_view)
        self.assertIn("AppStoreScreenshots.xcresult", self.workflow)
        self.assertIn("-showBuildSettings", self.workflow)
        self.assertIn("widget-fixture-build-conditions.txt", self.workflow)
        self.assertIn("ordinary_debug_conditions", self.workflow)
        self.assertIn("release_conditions", self.workflow)
        self.assertIn("failure-attachments", self.workflow)
        self.assertIn("failure-xcresulttool-export.log", self.workflow)
        self.assertIn("timeout-minutes: 40", self.workflow)
        capture_step = self.workflow.split(
            "- name: Capture erased-Simulator product screens",
            1,
        )[1].split("- name:", 1)[0]
        self.assertIn("timeout-minutes: 25", capture_step)
        failure_upload = self.workflow.split(
            "- name: Upload capture diagnostics on failure",
            1,
        )[1]
        self.assertNotIn("AppStoreScreenshots.xcresult", failure_upload)
        self.assertIn("if-no-files-found: error", failure_upload)
        self.assertNotIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=", self.workflow)

    def test_ui_test_and_exporter_agree_on_five_ordered_names(self) -> None:
        names = [
            "01-local-cat-widget",
            "02-local-photo-window",
            "03-organized-memories",
            "04-liked-photos",
            "05-on-device-photo-privacy",
        ]
        for name in names:
            captures = self.ui_test.count(f'captureScreenshot(named: "{name}"')
            captures += self.widget_ui_test.count(f'captureScreenshot(named: "{name}"')
            self.assertEqual(captures, 1)
            self.assertEqual(self.exporter.count(f'"{name}"'), 1)
        self.assertIn("写真や動画を開発者のサーバーへ自動送信しません", self.ui_test)
        self.assertIn("--app-store-screenshot-fixture", self.ui_test)
        self.assertIn("app.wait(for: .runningForeground", self.widget_ui_test)
        self.assertIn(
            "このiPhoneで見つけた猫写真",
            self.widget_view,
        )
        self.assertNotIn("このiPhoneで見つけた猫写真", self.widget_ui_test)
        self.assertIn("waitForFixturePalette(timeout: 15)", self.widget_ui_test)
        self.assertIn("fixturePaletteIsVisible", self.widget_ui_test)
        self.assertIn("pixels.withUnsafeMutableBytes", self.widget_ui_test)
        self.assertIn("XCUIScreen.main.screenshot()", self.widget_ui_test)
        self.assertIn("furPixels >= 500", self.widget_ui_test)
        self.assertIn("eyePixels >= 25", self.widget_ui_test)
        self.assertIn(
            "@MainActor\n    private func captureScreenshot",
            self.widget_ui_test,
        )
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
        self.assertIn("requirements: [(18, 1)]", self.ui_test)
        self.assertIn('app.buttons["memories-create-from-photos-action"]', self.ui_test)
        self.assertIn('app.buttons["saved-memories-selection-toggle"]', self.ui_test)
        self.assertIn('app.buttons["photo-book-export"]', self.ui_test)
        self.assertIn('"album-primary-all-cat-photos"', self.album_view)
        self.assertIn(
            'app.buttons["album-primary-all-cat-photos"]',
            self.ui_test,
        )
        self.assertIn("requirements: [(1, 1), (8, 2), (6, 1), (4, 1)]", self.ui_test)
        self.assertIn("requirements: [(9, 1), (10, 1), (11, 1)]", self.ui_test)
        self.assertNotIn("waitForStableRendering", self.ui_test)

    def test_exporter_rejects_wrong_size_or_metadata(self) -> None:
        for dimensions in ("(1260, 2736)", "(1290, 2796)", "(1320, 2868)"):
            self.assertIn(dimensions, self.exporter)
        self.assertIn('"format": "jpeg"', self.exporter)
        self.assertIn("def strip_jpeg_app1(path):", self.exporter)
        self.assertIn("stripped_app1_segments = strip_jpeg_app1(destination)", self.exporter)
        self.assertIn('"removedApp1Segments": stripped_app1_segments', self.exporter)
        self.assertIn("if marker == 0xE1", self.exporter)
        self.assertIn("contains a JPEG APP1 metadata segment", self.exporter)
        self.assertIn('"userReviewRequiredBeforeUpload": True', self.exporter)
        self.assertIn(
            '"releaseArchiveVerification": "not-performed-by-debug-capture-workflow"',
            self.exporter,
        )
        self.assertNotIn("releaseArchiveContainsFixtureRoute", self.exporter)
        self.assertIn('rm -rf "$RAW_DIRECTORY"', self.exporter)

    def test_exporter_strips_app1_and_rejects_truncated_jpeg(self) -> None:
        helper_start = self.exporter.index("def jpeg_dimensions_and_app1(path):")
        helper_end = self.exporter.index("\n\nreport =", helper_start)
        namespace = {"struct": struct}
        exec(self.exporter[helper_start:helper_end], namespace)

        app0 = b"\xff\xe0\x00\x04JF"
        app1 = b"\xff\xe1\x00\x06EXIF"
        scan = b"\xff\xda\x00\x04AB\x11\x22\xff\xd9"
        expected = b"\xff\xd8" + app0 + scan
        with tempfile.TemporaryDirectory() as temporary_directory:
            destination = Path(temporary_directory) / "fixture.jpg"
            destination.write_bytes(b"\xff\xd8" + app0 + app1 + scan)
            self.assertEqual(namespace["strip_jpeg_app1"](destination), 1)
            self.assertEqual(destination.read_bytes(), expected)

            destination.write_bytes(expected[:-2])
            with self.assertRaisesRegex(SystemExit, "end marker is missing"):
                namespace["strip_jpeg_app1"](destination)

            destination.write_bytes(b"\xff\xd8" + app0 + b"\xff\xd9")
            with self.assertRaisesRegex(SystemExit, "scan marker is missing"):
                namespace["strip_jpeg_app1"](destination)

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
