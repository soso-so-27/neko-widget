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
        guard app.staticTexts["・開発者のサーバーへ写真を自動送信しません"].exists else {
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
        guard waitForFixturePhotos(in: app, requirements: [(12, 1)]) else {
            fail("The deterministic Window illustration did not finish loading.", application: app)
            return
        }
        captureScreenshot(named: "02-local-photo-window")

        let automaticAlbums = app.buttons["today-open-automatic-albums"]
        guard automaticAlbums.waitForExistence(timeout: 10) else {
            fail("The automatic-albums action was not available from Today.", application: app)
            return
        }
        automaticAlbums.tap()
        let allCatPhotosAlbum = app.buttons["album-primary-all-cat-photos"]
        guard allCatPhotosAlbum.waitForExistence(timeout: 15) else {
            fail("The deterministic primary album did not appear.", application: app)
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

        guard tapTab(
            application: app,
            identifier: "main-tab-memories",
            fallbackLabel: "思い出"
        ) else {
            fail("The Memories tab was not available.", application: app)
            return
        }
        let memoriesAutomaticAlbums = app.buttons["memories-open-automatic-albums"]
        guard memoriesAutomaticAlbums.waitForExistence(timeout: 15) else {
            fail(
                "The automatic-albums entry was not available from Memories.",
                application: app
            )
            return
        }
        memoriesAutomaticAlbums.tap()
        guard app.buttons["album-primary-all-cat-photos"]
            .waitForExistence(timeout: 15) else {
            fail(
                "The Memories automatic-albums entry did not open the albums.",
                application: app
            )
            return
        }
        let memoriesBackButton = app.navigationBars["自動アルバム"].buttons["思い出"]
        guard memoriesBackButton.waitForExistence(timeout: 5) else {
            fail(
                "The automatic-albums screen could not return to Memories.",
                application: app
            )
            return
        }
        memoriesBackButton.tap()
        guard app.buttons["PDFにまとめる"].waitForExistence(timeout: 15) else {
            fail("The deterministic Likes collection did not appear.", application: app)
            return
        }
        guard waitForFixturePhotos(
            in: app,
            requirements: [(9, 1), (10, 1), (11, 1)]
        ) else {
            fail("The deterministic Likes illustrations did not finish loading.", application: app)
            return
        }
        captureScreenshot(named: "04-liked-photos")
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
