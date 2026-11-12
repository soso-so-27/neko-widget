#!/usr/bin/env python3
"""Static privacy and release-boundary contract for App Store capture."""

from __future__ import annotations

import struct
import hashlib
import tempfile
import unittest
from pathlib import Path

import ios_ci_scope as scope


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
        # The original privacy-safe screenshot set still imports no Photos.
        legacy = self.workflow.split("  capture-public-ipad:", 1)[0]
        self.assertNotIn("simctl addmedia", legacy)
        self.assertNotIn("ci/fixtures/cats", legacy)

    def test_public_ipad_lane_uses_only_reviewed_media_and_public_release(self) -> None:
        lane = self.workflow.split("  capture-public-ipad:", 1)[1]
        self.assertIn("if: inputs.review_test == 'testReviewPublicIPadCompatibility'", lane)
        self.assertIn("inputs.review_test != 'testReviewPublicIPadCompatibility'", self.workflow)
        self.assertIn("production_candidate.py build --synthetic", lane)
        self.assertIn("production_candidate.py products --synthetic", lane)
        self.assertIn("info.get('UIDeviceFamily') != [1]", lane)
        self.assertNotIn('simctl privacy', lane)
        self.assertEqual(lane.count("simctl addmedia"), 1)
        media = [line.strip().rstrip("\\").strip() for line in lane.splitlines()
                 if line.strip().startswith("ci/fixtures/")]
        self.assertEqual(media, ["ci/fixtures/cats/cat-orange-square.png",
                                 "ci/fixtures/cats/cat-tuxedo-landscape.png",
                                 "ci/fixtures/cats/cat-gray-portrait.png"])
        for forbidden in ("-configuration Debug", "--app-store-screenshot-fixture",
                          "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
                          "-exportArchive", "-retry-tests-on-failure"):
            self.assertNotIn(forbidden, lane)
        self.assertNotIn("-test-iterations", lane)
        self.assertNotIn("-run-tests-until-failure", lane)
        self.assertIn("-enableCodeCoverage NO", lane)
        self.assertIn("SWIFT_OPTIMIZATION_LEVEL=-Onone SWIFT_COMPILATION_MODE=singlefile", lane)
        self.assertIn("timeout-minutes: 25", lane)
        self.assertIn("if cases != [(expected, 'started'), (expected, 'passed')]", lane)

    def test_public_ipad_walkthrough_uses_normal_entries_without_purchase(self) -> None:
        method = self.ui_test.split("func testReviewPublicIPadCompatibility()", 1)[1].split(
            "func testReviewPublicPresentation()", 1)[0]
        for entry in ("onboarding-purpose-start", "initial-scan-continue", "main-tab-photos",
                      "main-tab-windows", "tools-settings-button", "settings-membership-offer",
                      "ipad-public-plus-entry-observation", "07-plus-entry-unavailable-synthetic-url",
                      "Allow Full Access", "com.apple.springboard", "02-photo-permission",
                      "group-window-unavailable", "みんなのまどを読み込めません",
                      "05-windows-unavailable-synthetic-url"):
            self.assertIn(entry, method)
        for forbidden in ("--app-store-screenshot-fixture", "--review-public-presentation",
                          'app.launchEnvironment[', 'tap("membership-offer-purchase"',
                          'tap("membership-offer-restore"', 'tap("settings-membership-restore"',
                          'plus.tap()', 'tap("settings-membership-preview"', 'membership-offer-close',
                          '"group-window-list"'):
            self.assertNotIn(forbidden, method)

    def test_capture_build_is_explicitly_local_only(self) -> None:
        required = {
            "SHARING_RELEASE_MODE=production",
            "GROUP_WINDOWS_ENABLED=YES",
            "OFFICIAL_WINDOW_FEED_URL=",
            "MANAGED_PRESERVATION_ORIGIN=",
            "PLUS_BILLING_API_BASE_URL=",
            "PLUS_BILLING_CLIENT_ENABLED=NO",
            "PLUS_STOREFRONT_ENABLED=NO",
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
        default_lane = self.workflow.split("  capture-review", 1)[0]
        flags = {line.strip().rstrip(chr(92)).strip() for line in default_lane.splitlines()}
        for value in required:
            self.assertIn(value, flags)
        self.assertIn("releaseBoundary\": \"version1-offline-debug", self.exporter)

    def test_generated_photo_preheating_never_fetches_photokit_assets(self) -> None:
        preheating = self.photo_image.split("private static func assets(withLocalIdentifiers", 1)[1].split(
            "private static func fullImageRequestOptions", 1
        )[0]
        debug_filter, release = preheating.split("#else", 1)
        self.assertIn("#if DEBUG", debug_filter)
        self.assertIn('!$0.hasPrefix("app-store-screenshot-fixture-")', debug_filter)
        self.assertIn("let photoIdentifiers = identifiers", release)
        self.assertLess(preheating.index("guard !photoIdentifiers.isEmpty"), preheating.index("PHAsset.fetchAssets"))
        self.assertIn("withLocalIdentifiers: photoIdentifiers", preheating)

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
            "- name: Prepare the erased Simulator and build the offline capture app",
            1,
        )[1].split("- name:", 1)[0]
        self.assertIn("timeout-minutes: 25", capture_step)
        tests = self.workflow.split("- name: Capture the three UI tests", 1)[1].split("- name:", 1)[0]
        self.assertIn("timeout-minutes: 12", tests)
        self.assertIn("test-without-building -xctestrun", tests)
        failure_upload = self.workflow.split(
            "- name: Upload capture diagnostics on failure",
            1,
        )[1]
        self.assertNotIn("AppStoreScreenshots.xcresult", failure_upload)
        self.assertIn("if-no-files-found: error", failure_upload)
        self.assertNotIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=", self.workflow)

    def test_shared_widget_review_is_gated_after_ordinary_runtime_validation(self) -> None:
        runtime = source("NekoWidget/ci/run-sharing-runtime-matrix.sh")
        condition = (
            "WIDGET_SCREENSHOT_FIXTURE_CONDITION="
            "APP_STORE_SCREENSHOT_WIDGET_FIXTURE WIDGET_VISUAL_REVIEW_FIXTURE"
        )
        self.assertEqual(runtime.count(condition), 1)
        review = runtime.index('if (( validator_status == 0 )) && [[ "$label" == "ios-26-2" && "$RUNTIME_LANE" != runtime ]]')
        self.assertLess(runtime.index('python3 "$VALIDATOR"'), review)
        self.assertGreater(runtime.index(condition), review)
        self.assertIn('"${COMPOSER_TEST_ARGUMENTS[@]}"', runtime)
        self.assertIn('"NekoWidgetUITests/MomentDeliveryComposerUITests"',
                      source("NekoWidget/ci/ios_ci_scope.py"))
        self.assertIn(
            "NekoWidgetUITests/WidgetPlacementScreenshotUITests/"
            "testCaptureSharedWidgetAllSupportedSizes", scope.native_tests(scope.FULL_SCOPE),
        )
        self.assertIn(
            "#if WIDGET_VISUAL_REVIEW_FIXTURE && (!DEBUG || !APP_STORE_SCREENSHOT_WIDGET_FIXTURE)",
            self.widget_view,
        )
        self.assertNotIn("WIDGET_VISUAL_REVIEW_FIXTURE", self.config)
        self.assertNotIn("WIDGET_VISUAL_REVIEW_FIXTURE", self.workflow)
        self.assertIn('["medium", "large"].enumerated()', self.widget_ui_test)
        self.assertNotIn('springboard.pageIndicators.firstMatch', self.widget_ui_test)
        self.assertIn('.containing(.pageIndicator, identifier: nil)', self.widget_ui_test)
        # Four Gallery pages: the three NekoWidget sizes, then ShowcaseWidget small.
        self.assertIn('galleryPage(pages) == [1, 4]', self.widget_ui_test)
        self.assertIn('galleryPage(pages) == [index + 2, 4]', self.widget_ui_test)
        self.assertIn('galleryPage(pages) == [2 - index, 4]', self.widget_ui_test)
        bundle = source("NekoWidget/NekoWidgetWidget/NekoWidgetBundle.swift")
        self.assertIn("        NekoWidget()\n        ShowcaseWidget()\n", bundle)
        self.assertIn(".supportedFamilies([.systemSmall, .systemMedium, .systemLarge])",
                      source("NekoWidget/NekoWidgetWidget/NekoWidget.swift"))
        self.assertIn(".supportedFamilies([.accessoryCircular, .systemSmall])",
                      source("NekoWidget/NekoWidgetWidget/ShowcaseWidget.swift"))
        self.assertIn('NSPredicate(format: "value != %@", previousPage)', self.widget_ui_test)
        self.assertNotIn('pixels == previousPixels', self.widget_ui_test)
        self.assertIn('timeIntervalSince(visibleSince) >= 0.5', self.widget_ui_test)
        self.assertIn('visibleSince = nil', self.widget_ui_test)

        # Extra comparisons remain independent of app UI failures, reuse only
        # the Gallery test, and cannot erase a preceding app UI failure.
        self.assertIn('if [[ "$RUNTIME_SCOPE" == "full-v1" && "$RUNTIME_LANE" == all ]]; then\n    RUN_WIDGET_GALLERY=true', runtime)
        scenarios = runtime.index('for widget_scenario in $WIDGET_SCENARIOS; do')
        normal_failure = runtime.index('if (( composer_status != 0 )); then')
        self.assertGreater(normal_failure, scenarios)
        self.assertIn('return "$composer_status"', runtime[normal_failure:])
        scenario_body = runtime[scenarios:runtime.index('\n        done', scenarios)]
        # Explicit Gallery lanes reject mapped scopes before any Simulator work.
        for selected in (scope.PHOTO_SCOPE, scope.OFFICIAL_SCOPE, scope.COMBINED_SCOPE,
                         scope.WIDGET_BEHAVIOR_SCOPE, scope.CI_SELECTION_SCOPE):
            with self.assertRaises(ValueError):
                scope.lane_tests(selected, "gallery-variants")
        for selected in (scope.WIDGET_LAYOUT_SCOPE, scope.WIDGET_STYLE_SCOPE):
            self.assertEqual(scope.lane_tests(selected, "gallery-variants"),
                             scope.lane_tests(scope.FULL_SCOPE, "gallery-variants"))
        self.assertEqual(scenario_body.count('-only-testing:'), 1)
        self.assertIn(
            '-only-testing:NekoWidgetUITests/WidgetPlacementScreenshotUITests/'
            '$widget_scenario_test', scenario_body,
        )
        self.assertIn('widget_scenario_test="testCaptureSharedWidgetAllSupportedSizes"', scenario_body)
        self.assertIn('widget_scenario_test="testCaptureSharedWidgetWhiteBackgroundAllSupportedSizes"', scenario_body)
        self.assertIn('func testCaptureSharedWidgetWhiteBackgroundAllSupportedSizes()', self.widget_ui_test)
        self.assertIn('captureFixtureGallery(captureAllSizes: true, expectWhiteFixture: true)', self.widget_ui_test)
        preparation = source('NekoWidget/ci/prepare-simulator-and-build.sh')
        reset_positions = []
        for command in ('shutdown', 'erase', 'boot', 'bootstatus'):
            arguments = ' -b' if command == 'bootstatus' else ''
            reset = f'xcrun simctl {command} "$simulator_udid"{arguments} || return $?'
            self.assertIn(reset, preparation)
            reset_positions.append(preparation.index(reset))
        self.assertEqual(reset_positions, sorted(reset_positions))
        self.assertIn('prepare_simulator_and_build "$simulator_udid"', scenario_body)
        self.assertIn('build-for-testing || widget_scenario_status=$?', scenario_body)
        self.assertIn('test-without-building || widget_scenario_status=$?', scenario_body)
        self.assertIn('-derivedDataPath "$DERIVED_DATA_DIRECTORY"', scenario_body)
        self.assertIn(
            'WIDGET_VISUAL_REVIEW_LONG_CAPTION WIDGET_VISUAL_REVIEW_WHITE_BACKGROUND '
            'WIDGET_VISUAL_REVIEW_LARGE_TEXT', scenario_body,
        )
        self.assertIn('widget_scenario_conditions="WIDGET_VISUAL_REVIEW_NO_CAPTION"', scenario_body)
        self.assertIn('Widget-$widget_scenario.xcresult', scenario_body)
        self.assertIn('widget-$widget_scenario-screenshots', scenario_body)
        self.assertIn('widget_matrix_status=1', scenario_body)
        workflow = source('.github/workflows/ios-build.yml')
        runtime_job = workflow[workflow.index('\n  sharing-runtime-matrix:'):]
        self.assertIn('timeout-minutes: 60', runtime_job)

    def test_widget_portrait_review_reuses_production_cache_and_decoder(self) -> None:
        runtime = source("NekoWidget/ci/run-sharing-runtime-matrix.sh")
        app_runtime = source("NekoWidget/NekoWidget/Services/SharingRuntimeSelfTest.swift")
        portrait_hash = hashlib.sha256(
            (ROOT / "ci/fixtures/cats/cat-gray-portrait.png").read_bytes()
        ).hexdigest()
        self.assertIn(portrait_hash, runtime)
        self.assertIn(portrait_hash, app_runtime)
        self.assertTrue(app_runtime.startswith("#if DEBUG\n"))
        image_helper = app_runtime.split(
            "private static func widgetPortraitReviewImageIfRequested()", 1
        )[1].split("private static func exportWidgetPortraitReviewIfRequested", 1)[0]
        self.assertIn("#if targetEnvironment(simulator)", image_helper)
        self.assertIn("CommandLine.arguments.contains(launchArgument)", image_helper)
        self.assertIn("CommandLine.arguments.contains(widgetPortraitReviewArgument)", image_helper)
        self.assertIn("PairingCrypto.sha256(data)", image_helper)
        flow = app_runtime.split("private static func testRetainedWidgetPublication()", 1)[1]
        self.assertIn("image: widgetPortraitReviewImageIfRequested() ?? generatedImage()", flow)
        self.assertLess(flow.index("widgetBuilder.buildFamilyWindow("),
                        flow.index("exportWidgetPortraitReviewIfRequested("))
        self.assertIn("filenames: publishedPhoto.cacheFilenames", flow)
        self.assertIn("image.width == variant.pixelWidth", app_runtime)
        self.assertIn("image.height == variant.pixelHeight", app_runtime)
        self.assertIn("data.count <= variant.maximumJPEGByteCount", app_runtime)
        self.assertIn('runtime_launch_arguments+=("--sharing-widget-portrait-review")', runtime)
        self.assertIn('"${runtime_launch_arguments[@]}"', runtime)
        self.assertIn('f"sharing-widget-review-{size}.jpg"', runtime)
        self.assertIn('"$runtime_artifacts/widget-portrait-cache"', runtime)
        self.assertIn('"productionBuilder": "WidgetCacheBuilder.buildFamilyWindow"', runtime)
        for size in ("SMALL", "MEDIUM", "LARGE"):
            self.assertEqual(self.widget_view.count(f"__W1_WIDGET_{size}_CACHE_JPEG_BASE64__"), 1)
        self.assertNotIn("__W1_WIDGET_SMALL_PNG_BASE64__", self.widget_view)
        self.assertIn("WidgetCacheImageLoader.decodedImage(", self.widget_view)
        self.assertNotIn("CGImageSourceCreateThumbnailAtIndex", self.widget_view)
        self.assertEqual(self.widget_loader.count("CGImageSourceCreateThumbnailAtIndex("), 1)
        decode = self.widget_loader.index("let image = decodedImage(data: data,")
        visibility = self.widget_loader.index("guard WidgetManifestReader.cacheURL(for: cacheFilename,", decode)
        returned = self.widget_loader.index("return image", visibility)
        self.assertLess(decode, visibility)
        self.assertLess(visibility, returned)

    def test_ui_test_and_exporter_agree_on_eight_ordered_names(self) -> None:
        names = [
            "01-local-cat-widget",
            "07-group-window",
            "03-organized-memories",
            "02-local-photo-window",
            "04-liked-photos",
            "06-windows-tab",
            "08-nowa-window",
            "09-cat-care",
        ]
        for name in names:
            captures = self.ui_test.count(f'captureScreenshot(named: "{name}"')
            captures += self.widget_ui_test.count(f'captureScreenshot(named: "{name}"')
            self.assertEqual(captures, 1)
            self.assertIn(f'("{name}",', self.exporter)
        selectors = self.workflow.split("  capture-review", 1)[0]
        for method in ("testCaptureVersion1ProductScreens", "testCaptureVersion1WindowScreens",
                       "testCaptureVersion1CatCareScreen"):
            self.assertIn("AppStoreScreenshotUITests/" + method, selectors)
        self.assertNotIn("05-on-device-photo-privacy", self.exporter)
        self.assertNotIn("AppStoreScreenshotUITests/testCaptureJapaneseLocalOnlyProductScreens", selectors)
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
        self.assertIn("requirements: [(1, 1), (2, 1), (3, 1)]", self.ui_test)
        self.assertIn('app.buttons["photos-section-favorites"]', self.ui_test)
        self.assertIn('app.descendants(matching: .any)["saved-memories-gallery"]', self.ui_test)
        self.assertIn('app.buttons["saved-memories-selection-toggle"]', self.ui_test)
        self.assertIn('app.buttons["photo-book-export"]', self.ui_test)
        self.assertIn('"album-primary-all-cat-photos"', self.album_view)
        self.assertIn('["monthly-story", "monthly-book"]', self.ui_test)
        self.assertIn("numbers: Array(19...24)", self.ui_test)
        self.assertIn('"--app-store-screenshot-album"', self.ui_test)
        self.assertIn('"--app-store-screenshot-album"', self.fixture)
        self.assertIn("identifiers = (1...24)", self.fixture)
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


def load_review_collector():
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "collect_review_screenshots", ROOT / "ci" / "collect-review-screenshots.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class ReviewScreenshotWorkflowTests(unittest.TestCase):
    """The design-review capture: synthetic, manual, short-lived, PNGs only."""

    def setUp(self) -> None:
        self.workflow = source(".github/workflows/review-screenshots.yml")
        self.ui_test = source("NekoWidget/NekoWidgetUITests/ReviewScreenshotUITests.swift")
        self.collector_source = source("NekoWidget/ci/collect-review-screenshots.py")
        self.collector = load_review_collector()

    def test_review_workflow_is_manual_read_only_and_never_publishes(self) -> None:
        trigger = self.workflow.split("on:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("workflow_dispatch:", trigger)
        for forbidden_trigger in ("push:", "pull_request:", "schedule:", "workflow_run:"):
            self.assertNotIn(forbidden_trigger, trigger)
        self.assertIn("permissions:\n  contents: read\n", self.workflow)
        self.assertNotIn("write", self.workflow.split("\njobs:", 1)[0].split("permissions:", 1)[1])
        lowered = self.workflow.lower()
        for forbidden in ("secrets.", "gh api", "altool", "notarytool", "app-store-connect",
                          "upload_to_testflight", "environment: testflight"):
            self.assertNotIn(forbidden, lowered)
        self.assertIn("persist-credentials: false", self.workflow)

    def test_review_capture_is_synthetic_and_separate_from_owner_capture(self) -> None:
        for text in (self.workflow, self.ui_test):
            for forbidden in ("NEKO_PRIVATE_CAPTURE_ROOT", "--owner-store-capture", "NEKO_CAPTURE_KEY",
                              "owner-store-capture", ".nekoenc", "simctl addmedia", "ci/fixtures/cats",
                              "simctl privacy"):
                self.assertNotIn(forbidden, text)
        # The existing App Store capture does not run or know the review class.
        self.assertNotIn("ReviewScreenshotUITests", source(".github/workflows/app-store-screenshots.yml"))
        self.assertNotIn("ReviewScreenshotUITests", source(".github/workflows/owner-store-capture.yml"))
        # No service, relay or billing endpoint in the capture build.
        for setting in ("SHARING_API_BASE_URL= \\", "PLUS_BILLING_API_BASE_URL= \\",
                        "OFFICIAL_WINDOW_FEED_URL= \\", "MANAGED_PRESERVATION_ORIGIN= \\",
                        "SHARING_FEATURE_ENABLED=NO", "PLUS_BILLING_CLIENT_ENABLED=NO",
                        "MANAGED_PRESERVATION_ENABLED=NO"):
            self.assertIn(setting, self.workflow)
        self.assertIn('raise SystemExit(f"Capture build unexpectedly configured {key}")', self.workflow)

    def test_review_artifact_is_pngs_and_index_with_short_retention(self) -> None:
        uploads = self.workflow.split("uses: actions/upload-artifact@")[1:]
        self.assertEqual(len(uploads), 2)
        retention = sorted(int(line.split(":", 1)[1]) for line in self.workflow.splitlines()
                           if line.strip().startswith("retention-days:"))
        self.assertEqual(retention, [1, 7])
        for upload in uploads:
            path = next(line.strip() for line in upload.splitlines() if line.strip().startswith("path:"))
            self.assertIn(path, ("path: ${{ runner.temp }}/review/shots",
                                 "path: ${{ runner.temp }}/review-screenshots"))
            self.assertNotIn("xcresult", upload.split("- name:", 1)[0])
            self.assertNotIn(".log", upload.split("- name:", 1)[0])
        self.assertIn("name: review-screenshots-${{ github.run_id }}", self.workflow)
        # The index step deletes everything that is not a PNG or index.txt.
        self.assertIn('path.name != "index.txt" and path.suffix.lower() != ".png"', self.collector_source)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "light").mkdir()
            (root / "light" / "01_photos_top.png").write_bytes(b"\x89PNG\r\n\x1a\n" + bytes(16))
            (root / "light" / "stray.log").write_text("runner output", encoding="utf-8")
            (root / "index-light.txt").write_text(
                "captured  light/01_photos_top.png  1x1\nMISSING   light/15_lost_preview  reason\n",
                encoding="utf-8")
            self.collector.build_index(root)
            files = sorted(str(path.relative_to(root)).replace("\\", "/")
                           for path in root.rglob("*") if path.is_file())
            self.assertEqual(files, ["index.txt", "light/01_photos_top.png"])
            index = (root / "index.txt").read_text(encoding="utf-8")
            self.assertIn("captured: 1  MISSING: 1", index)
            self.assertIn("MISSING   light/15_lost_preview", index)

    def test_review_sets_devices_and_appearance(self) -> None:
        self.assertIn('\'["light","dark","se"]\'', self.workflow)
        self.assertIn("fail-fast: false", self.workflow)
        self.assertIn('"iPhone SE (3rd generation)"', self.workflow)
        self.assertIn('"iPhone 17 Pro Max"', self.workflow)
        self.assertIn('xcrun simctl ui "$device" appearance "$appearance"', self.workflow)
        self.assertIn("TEST_RUNNER_REVIEW_SET: ${{ matrix.set }}", self.workflow)
        self.assertIn('"-app.appearance.v1", appearance', self.ui_test)
        self.assertIn('xcrun simctl bootstatus "$device" -b', self.workflow)
        # One retry, of the tests that did not pass, on a rebooted Simulator.
        self.assertEqual(self.workflow.count("run_tests 1 "), 1)
        self.assertEqual(self.workflow.count("run_tests 2 "), 1)
        self.assertIn("-test-timeouts-enabled YES", self.workflow)
        self.assertIn("app.wait(for: .runningForeground", self.ui_test)

    def test_review_screen_names_match_the_collector_and_selected_methods(self) -> None:
        import re

        captured = set(re.findall(r'shot\("([A-Za-z0-9_]+)"', self.ui_test))
        if 'shot("29_widget_guide_\\(page)"' in self.ui_test:
            captured |= {f"29_widget_guide_{page}" for page in range(2, 6)}
        self.assertEqual(captured, set(self.collector.FULL_SCREENS))
        self.assertEqual(len(self.collector.FULL_SCREENS), len(set(self.collector.FULL_SCREENS)))
        se_block = self.ui_test.split("static let seScreens: Set<String> = [", 1)[1].split("]", 1)[0]
        self.assertEqual(set(re.findall(r'"([A-Za-z0-9_]+)"', se_block)), set(self.collector.SE_SCREENS))
        self.assertTrue(set(self.collector.SE_SCREENS) <= captured)
        methods = re.findall(r"\bfunc\s+(test\w+)\s*\(", self.ui_test)
        self.assertEqual(len(methods), len(set(methods)))
        full_run = self.workflow.split("else\n            methods=(", 1)[1].split(")", 1)[0].split()
        self.assertEqual(sorted(full_run), sorted(methods))
        se_run = self.workflow.split('if [[ "$REVIEW_SET" == se ]]; then\n            methods=(', 1)[1]
        self.assertTrue(set(se_run.split(")", 1)[0].split()) <= set(methods))
        # A miss is recorded and the walk goes on.
        self.assertIn("continueAfterFailure = true", self.ui_test)
        self.assertIn('attachment.name = "review-missing__\\(name)__end"', self.ui_test)
        self.assertIn('attachment.name = "review-shot__\\(name)__end"', self.ui_test)

    def test_review_test_is_in_the_ui_test_target(self) -> None:
        project = source("NekoWidget/NekoWidget.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("ReviewScreenshotUITests.swift"), 6)
        self.assertEqual(project.count("ReviewScreenshotUITests.swift in Sources"), 2)


if __name__ == "__main__":
    unittest.main()
