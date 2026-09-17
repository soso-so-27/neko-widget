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

        guard app.navigationBars["アルバム"].waitForExistence(timeout: 20),
              app.descendants(matching: .any)["albums-favorites"].waitForExistence(timeout: 10) else {
            fail("The Albums root did not appear first.", application: app)
            return
        }
        XCTAssertFalse(app.segmentedControls["memories-section-picker"].exists)
        XCTAssertFalse(app.buttons["album-primary-all-cat-photos"].exists)
        captureScreenshot(named: "review-albums-root")

        let organizedAlbum = app.descendants(matching: .any)["album-card-household_growth"].firstMatch
        guard scrollUpUntilHittable(organizedAlbum, application: app),
              waitForFixturePhotos(in: app, requirements: [(8, 1)]) else {
            fail("The direct album cover did not render its fixture photo.", application: app)
            return
        }
        captureScreenshot(named: "03-organized-memories")
        organizedAlbum.tap()
        let albumTitle = app.navigationBars["あの頃と今"]
        guard albumTitle.waitForExistence(timeout: 10) else {
            fail("The album cover did not open its collection directly.", application: app)
            return
        }
        albumTitle.buttons.element(boundBy: 0).tap()
        guard app.navigationBars["アルバム"].waitForExistence(timeout: 10) else {
            fail("The collection did not return to Albums.", application: app)
            return
        }

        let favorites = app.descendants(matching: .any)["albums-favorites"].firstMatch
        for _ in 0..<8 where !(favorites.exists && favorites.isHittable) { app.swipeDown() }
        guard favorites.isHittable else {
            fail("The favorites entry was not reachable from Albums.", application: app)
            return
        }
        favorites.tap()
        guard app.navigationBars["お気に入り"].waitForExistence(timeout: 10),
              waitForFixturePhotos(in: app, requirements: [(9, 1), (10, 1), (11, 1)]) else {
            fail("The complete favorites gallery did not render.", application: app)
            return
        }
        let selectSavedPhotos = app.buttons["saved-memories-selection-toggle"]
        guard selectSavedPhotos.waitForExistence(timeout: 10), waitForHittable(selectSavedPhotos) else {
            fail("The favorite-photo selection action was not reachable.", application: app)
            return
        }
        XCTAssertFalse(app.buttons["photo-book-export"].exists)
        captureScreenshot(named: "04-liked-photos")
        selectSavedPhotos.tap()
        let createPDF = app.buttons["saved-memories-create-pdf"]
        guard createPDF.waitForExistence(timeout: 10), waitForHittable(createPDF) else {
            fail("The output choices did not open from favorites.", application: app)
            return
        }
        captureScreenshot(named: "review-favorites-creation-options")
        createPDF.tap()
        guard app.navigationBars["写真を選ぶ"].waitForExistence(timeout: 10),
              app.buttons["photo-book-export"].waitForExistence(timeout: 10) else {
            fail("PDF creation was not available after photo selection opened.", application: app)
            return
        }
        XCTAssertFalse(app.buttons["photo-book-export"].isEnabled)
        XCTAssertTrue(app.staticTexts["0枚を選択"].exists)
        captureScreenshot(named: "review-favorites-selection")
        selectSavedPhotos.tap()
        guard app.navigationBars["お気に入り"].waitForExistence(timeout: 10) else {
            fail("Canceling selection did not restore favorites browsing.", application: app)
            return
        }
        app.navigationBars["お気に入り"].buttons.element(boundBy: 0).tap()
        guard app.navigationBars["アルバム"].waitForExistence(timeout: 10),
              tapTab(application: app, identifier: "main-tab-photos", fallbackLabel: "写真") else {
            fail("Favorites could not return to Albums and open Photos.", application: app)
            return
        }
        guard app.descendants(matching: .any)["photo-hub-detected-grid"].waitForExistence(timeout: 15),
              app.buttons["photo-hub-photo-app-store-screenshot-fixture-1"].isHittable,
              waitForFixturePhotos(in: app, requirements: [(1, 1), (2, 1), (3, 1)]) else {
            fail("The scoped Photos grid did not render.", application: app)
            return
        }
        XCTAssertFalse(app.buttons["photos-open-automatic-albums"].exists)
        captureScreenshot(named: "02-local-photo-window")
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
