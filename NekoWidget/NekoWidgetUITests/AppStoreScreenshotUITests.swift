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

        guard app.buttons["window-current-photo"].waitForExistence(timeout: 20) else {
            fail("The deterministic Window fixture did not appear.", application: app)
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
        let savedSegment = memoriesSectionPicker.buttons["残した"]
        guard memoriesSectionPicker.waitForExistence(timeout: 15),
              savedSegment.waitForExistence(timeout: 5) else {
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
        let allSavedPhotos = app.buttons["memories-show-all-saved-photos"]
        guard allSavedPhotos.waitForExistence(timeout: 10),
              waitForHittable(allSavedPhotos) else {
            fail("The complete saved-photo collection was not reachable.", application: app)
            return
        }
        captureScreenshot(named: "04-liked-photos")

        allSavedPhotos.tap()
        guard app.navigationBars["残した写真"].waitForExistence(timeout: 10),
              app.buttons["saved-memories-selection-toggle"].exists else {
            fail("The complete saved-photo collection did not open separately.", application: app)
            return
        }
        let savedPhotosBackButton = app.navigationBars["残した写真"].buttons["思い出"]
        guard savedPhotosBackButton.waitForExistence(timeout: 5) else {
            fail("The saved-photo collection could not return to Memories.", application: app)
            return
        }
        savedPhotosBackButton.tap()

        let reflectionsSegment = memoriesSectionPicker.buttons["ふりかえり"]
        guard memoriesSectionPicker.waitForExistence(timeout: 5),
              reflectionsSegment.waitForExistence(timeout: 5) else {
            fail("The Memories section picker was not reachable.", application: app)
            return
        }
        reflectionsSegment.tap()

        let memoriesAutomaticAlbums = app.buttons["memories-open-automatic-albums"]
        guard scrollUpUntilHittable(memoriesAutomaticAlbums, application: app),
              reflectionsSegment.isSelected else {
            fail(
                "The automatic-albums entry could not be reached from Memories.",
                application: app
            )
            return
        }
        memoriesAutomaticAlbums.tap()
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

        let memoriesBackButton = app.navigationBars["自動アルバム"].buttons["思い出"]
        guard memoriesBackButton.waitForExistence(timeout: 5) else {
            fail(
                "The automatic-albums screen could not return to Memories.",
                application: app
            )
            return
        }
        memoriesBackButton.tap()

        let createSegment = memoriesSectionPicker.buttons["つくる"]
        guard createSegment.waitForExistence(timeout: 5) else {
            fail("The Memories creation section was not reachable.", application: app)
            return
        }
        createSegment.tap()

        let pdfAction = app.buttons["memories-photo-book-action"]
        guard scrollUpUntilHittable(pdfAction, application: app),
              createSegment.isSelected else {
            fail("The PDF creation action could not be reached.", application: app)
            return
        }
        pdfAction.tap()
        guard app.navigationBars["PDFにまとめる"].waitForExistence(timeout: 10),
              app.buttons["photo-book-export"].waitForExistence(timeout: 10) else {
            fail("PDF selection did not open on its own screen.", application: app)
            return
        }
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
