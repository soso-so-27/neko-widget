import XCTest

/// Captures a Japanese, local-only App Store screenshot set without importing
/// Photos or signing in to any account. The product screens use the shipping
/// SwiftUI views with DEBUG-only, code-generated cat illustrations.
final class AppStoreScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    @MainActor
    func testCaptureJapaneseLocalOnlyProductScreens() {
        captureOnDevicePrivacyScreen()
        captureFixtureProductScreens()
    }

    @MainActor
    private func captureOnDevicePrivacyScreen() {
        let app = XCUIApplication()
        app.launchEnvironment["NEKO_RESET_ONBOARDING_FOR_UI_TESTS"] = "1"
        app.launchArguments += japaneseLaunchArguments
        app.launch()

        let start = app.buttons["onboarding-purpose-start"]
        guard start.waitForExistence(timeout: 20) else {
            fail("The first onboarding page did not appear.", application: app)
            return
        }
        start.tap()

        let permissionAction = app.buttons["onboarding-photo-permission-allow"]
        guard permissionAction.waitForExistence(timeout: 15) else {
            fail("The local-only Photos privacy page did not appear.", application: app)
            return
        }
        let permissionReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: permissionAction
        )
        guard XCTWaiter.wait(for: [permissionReady], timeout: 15) == .completed else {
            fail("The local-only Photos privacy page did not finish preparing.", application: app)
            return
        }
        guard app.staticTexts["・写真や動画を開発者のサーバーへ自動送信しません"].exists else {
            fail("The disabled-build privacy statement was not visible.", application: app)
            return
        }

        captureScreenshot(named: "05-on-device-photo-privacy")
        app.terminate()
    }

    @MainActor
    private func captureFixtureProductScreens() {
        let app = XCUIApplication()
        app.launchArguments += japaneseLaunchArguments
        app.launchArguments.append("--app-store-screenshot-fixture")
        app.launch()

        guard app.descendants(matching: .any)["photo-hub-detected-grid"].waitForExistence(timeout: 20),
              app.buttons["photos-open-automatic-albums"].waitForExistence(timeout: 10) else {
            fail("The deterministic cat-photo library did not appear.", application: app)
            return
        }
        guard waitForFixturePhotos(in: app, requirements: [(18, 1)]) else {
            fail("The deterministic Window illustration did not finish loading.", application: app)
            return
        }
        captureScreenshot(named: "02-local-photo-window")

        guard tapTab(
            application: app,
            identifier: "main-tab-memories",
            fallbackLabel: "思い出"
        ) else {
            fail("The Memories tab was not available.", application: app)
            return
        }
        let memoriesSectionPicker = app.segmentedControls["memories-section-picker"]
        let photosSegment = memoriesSectionPicker.buttons["写真"]
        guard memoriesSectionPicker.waitForExistence(timeout: 15),
              photosSegment.waitForExistence(timeout: 5) else {
            fail(
                "The Memories information architecture did not appear.",
                application: app
            )
            return
        }
        guard waitForFixturePhotos(
            in: app,
            requirements: [(9, 1), (10, 1), (11, 1)]
        ) else {
            fail("The deterministic Likes illustrations did not finish loading.", application: app)
            return
        }
        let selectSavedPhotos = app.buttons["memories-create-from-photos-action"]
        guard selectSavedPhotos.waitForExistence(timeout: 10),
              waitForHittable(selectSavedPhotos) else {
            fail("The saved-photo selection action was not reachable.", application: app)
            return
        }
        captureScreenshot(named: "04-liked-photos")

        selectSavedPhotos.tap()
        guard app.navigationBars["写真を選ぶ"].waitForExistence(timeout: 10),
              app.buttons["saved-memories-selection-toggle"].exists else {
            fail("The saved-photo selection flow did not open.", application: app)
            return
        }
        guard app.buttons["photo-book-export"].waitForExistence(timeout: 10) else {
            fail("PDF creation was not available after photo selection opened.", application: app)
            return
        }
        let savedPhotosBackButton = app.navigationBars["写真を選ぶ"].buttons["思い出"]
        guard savedPhotosBackButton.waitForExistence(timeout: 5) else {
            fail("Photo selection could not return to Memories.", application: app)
            return
        }
        savedPhotosBackButton.tap()

        guard tapTab(
            application: app,
            identifier: "main-tab-photos",
            fallbackLabel: "写真"
        ) else {
            fail("The Photos tab was not available.", application: app)
            return
        }

        let photosAutomaticAlbums = app.buttons["photos-open-automatic-albums"]
        guard scrollUpUntilHittable(photosAutomaticAlbums, application: app) else {
            fail(
                "The automatic-albums entry could not be reached from Photos.",
                application: app
            )
            return
        }
        photosAutomaticAlbums.tap()
        let allCatPhotosAlbum = app.buttons["album-primary-all-cat-photos"]
        guard allCatPhotosAlbum.waitForExistence(timeout: 15) else {
            fail(
                "The deterministic primary album did not appear.",
                application: app
            )
            return
        }
        // The primary uses fixture photo 1; household growth and 2022 both
        // use fixture photo 8. Requiring those plus the intervening year
        // covers proves that the full-width primary card and organized grid
        // rendered real fixture pixels without depending on off-screen rows.
        guard waitForFixturePhotos(
            in: app,
            requirements: [(1, 1), (8, 2), (6, 1), (4, 1)]
        ) else {
            fail("The deterministic album illustrations did not finish loading.", application: app)
            return
        }
        captureScreenshot(named: "03-organized-memories")

        let photosBackButton = app.navigationBars["自動アルバム"].buttons["写真"]
        guard photosBackButton.waitForExistence(timeout: 5) else {
            fail(
                "The automatic-albums screen could not return to Photos.",
                application: app
            )
            return
        }
        photosBackButton.tap()
    }

    private var japaneseLaunchArguments: [String] {
        [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
        ]
    }

    @MainActor
    private func tapTab(
        application: XCUIApplication,
        identifier: String,
        fallbackLabel: String
    ) -> Bool {
        let identified = application.buttons[identifier]
        if identified.waitForExistence(timeout: 10) {
            identified.tap()
            return true
        }

        let labelled = application.tabBars.buttons[fallbackLabel]
        if labelled.waitForExistence(timeout: 5) {
            labelled.tap()
            return true
        }
        return false
    }

    @MainActor
    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        if element.isHittable { return true }
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }

    @MainActor
    private func scrollUpUntilHittable(
        _ element: XCUIElement,
        application: XCUIApplication,
        maximumSwipes: Int = 8
    ) -> Bool {
        if element.exists, element.isHittable { return true }
        for _ in 0..<maximumSwipes {
            application.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            if element.exists, element.isHittable { return true }
        }
        return false
    }

    @MainActor
    private func waitForFixturePhotos(
        in application: XCUIApplication,
        requirements: [(number: Int, minimumCount: Int)]
    ) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            let allRequiredPixelsLoaded = requirements.allSatisfy { requirement in
                let identifier = "app-store-screenshot-fixture-photo-loaded-"
                    + "app-store-screenshot-fixture-\(requirement.number)"
                return application.descendants(matching: .any)
                    .matching(identifier: identifier)
                    .count >= requirement.minimumCount
            }
            if allRequiredPixelsLoaded {
                // Let the tab transition finish after every visible fixture
                // image has published its loaded accessibility state.
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func captureScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func fail(_ message: String, application: XCUIApplication) {
        let hierarchy = XCTAttachment(string: application.debugDescription)
        hierarchy.name = "Application hierarchy on capture failure"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Screen on App Store capture failure"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTFail(message)
    }
}
