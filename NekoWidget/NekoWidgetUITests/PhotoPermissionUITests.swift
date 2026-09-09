import XCTest

final class PhotoPermissionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    @MainActor
    func testGrantFullPhotoLibraryAccess() {
        let app = XCUIApplication()
        let expectsDisabledRelease = ProcessInfo.processInfo.environment["NEKO_EXPECT_DISABLED_RELEASE"] == "1"
        app.resetAuthorizationStatus(for: .photos)
        app.launchEnvironment["NEKO_RESET_ONBOARDING_FOR_UI_TESTS"] = "1"
        app.launch()

        let startButton = app.buttons["onboarding-purpose-start"]
        guard startButton.waitForExistence(timeout: 15) else {
            addDiagnosticAttachment(
                name: "Missing onboarding start button",
                contents: app.debugDescription
            )
            XCTFail("The first onboarding page did not appear.")
            return
        }
        startButton.tap()

        let requestButton = app.buttons["onboarding-photo-permission-allow"]
        guard requestButton.waitForExistence(timeout: 15) else {
            addDiagnosticAttachment(
                name: "Missing in-app Photos permission button",
                contents: app.debugDescription
            )
            XCTFail("The in-app Photos permission button did not appear.")
            return
        }
        let requestReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: requestButton
        )
        guard XCTWaiter.wait(for: [requestReady], timeout: 15) == .completed else {
            addDiagnosticAttachment(
                name: "Photos permission button stayed disabled",
                contents: app.debugDescription
            )
            XCTFail("The onboarding permission action did not become ready.")
            return
        }
        requestButton.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permissionAlert = springboard.alerts.firstMatch
        // Hosted Simulators can display the Photos prompt well after PhotoKit
        // has submitted the TCC request. Keep this fail-closed, but allow the
        // observed SpringBoard/accessibility propagation delay.
        guard permissionAlert.waitForExistence(timeout: 60) else {
            addDiagnosticAttachment(
                name: "Missing Photos permission alert",
                contents: springboard.debugDescription
            )
            XCTFail("The system Photos permission alert did not appear.")
            return
        }

        let fullAccessLabels = [
            "Allow Full Access",
            "Allow Access to All Photos",
            "フルアクセスを許可",
            "すべての写真へのアクセスを許可",
        ]
        guard let fullAccessButton = fullAccessLabels.lazy
            .map({ permissionAlert.buttons[$0] })
            .first(where: { $0.exists })
        else {
            let buttonLabels = permissionAlert.buttons.allElementsBoundByIndex
                .map(\.label)
                .joined(separator: "\n")
            addDiagnosticAttachment(
                name: "Unhandled Photos permission alert",
                contents: "Buttons:\n\(buttonLabels)\n\nAlert:\n\(permissionAlert.debugDescription)"
            )
            XCTFail("No known full-access button was present in the Photos permission alert.")
            return
        }

        fullAccessButton.tap()

        let systemAlertDisappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: permissionAlert
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [systemAlertDisappeared], timeout: 15),
            .completed,
            "The Photos permission alert did not close after granting full access."
        )

        app.activate()

        // The smoke workflow runs this test before importing any fixtures, so
        // Apple's bundled non-cat images may still exist. The scan must reach the zero-cat
        // branch instead of merely leaving the progress screen.
        let zeroResult = app.staticTexts["猫の写真は見つかりませんでした"]
        guard zeroResult.waitForExistence(timeout: 45) else {
            fail(
                "The empty Photo Library did not produce the zero-photo result.",
                app: app
            )
            return
        }

        let continueFromZero = firstExistingButton(
            in: app,
            identifiers: ["initial-scan-continue"],
            labels: ["次へ", "写真を見る"],
            timeout: 10
        )
        guard let continueFromZero else {
            fail(
                "The zero-photo result did not expose its continue action.",
                app: app
            )
            return
        }
        continueFromZero.tap()

        // An empty library cannot demonstrate a photo Widget, so completing
        // the zero-result page now enters the app directly. The guide remains
        // available from Settings and is verified below.

        guard firstExistingButton(
            in: app,
            identifiers: ["main-tab-memories"],
            labels: ["思い出"],
            timeout: 10
        ) != nil else {
            fail("The Memories tab disappeared from the tab bar.", app: app)
            return
        }

        guard firstExistingButton(
            in: app,
            identifiers: ["main-tab-photos"],
            labels: ["写真"],
            timeout: 10
        ) != nil else {
            fail("The primary Photos tab was not available.", app: app)
            return
        }

        if expectsDisabledRelease {
            XCTAssertFalse(
                app.buttons["main-tab-windows"].exists || app.tabBars.buttons["まど"].exists,
                "The disabled build exposed the Windows tab."
            )
        } else if firstExistingButton(
                  in: app,
                  identifiers: ["main-tab-windows"],
                  labels: ["まど"],
                  timeout: 10
              ) == nil {
            fail("The primary Windows tab was not available.", app: app)
            return
        }

        guard !app.tabBars.buttons["設定"].exists else {
            fail("Settings remained a peer tab instead of moving under Home.", app: app)
            return
        }

        if expectsDisabledRelease {
            XCTAssertFalse(
                app.buttons["window-family-window-review"].exists,
                "The disabled build exposed the pairing/sharing card."
            )
            XCTAssertFalse(
                app.buttons["window-latest-family-photo"].exists,
                "The disabled build exposed stale received-photo UI."
            )
        }

        let settingsButton = firstExistingButton(
            in: app,
            identifiers: ["window-settings-button"],
            labels: ["設定"],
            timeout: 10
        )
        guard let settingsButton else {
            fail("Home did not expose its Settings action after onboarding.", app: app)
            return
        }
        settingsButton.tap()

        let settingsWidgetGuide = app.buttons["settings-widget-placement-guide"]
        guard settingsWidgetGuide.waitForExistence(timeout: 15) else {
            fail(
                "Settings did not expose the Widget placement guide replay action.",
                app: app
            )
            return
        }
        if expectsDisabledRelease {
            XCTAssertFalse(
                app.descendants(matching: .any)["settings-sharing-review"].exists,
                "The disabled build exposed sharing settings."
            )
        }
        settingsWidgetGuide.tap()

        let widgetSkip = app.buttons["widget-placement-skip"]
        guard widgetSkip.waitForExistence(timeout: 15) else {
            fail(
                "The Widget placement guide did not reopen from Settings.",
                app: app
            )
            return
        }

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Widget placement guide reopened from Settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // Reuse this build and its UI-authorized Simulator library baseline.
        // These fixtures exercise the actual views without enrolling cats,
        // sharing, or reading any personal media.
        app.terminate()
        verifyMainlineAcceptanceScreens()
    }

    @MainActor
    private func verifyMainlineAcceptanceScreens() {
        for scenario in ["one", "three", "unavailable", "limited-zero", "skip",
                         "monthly-empty", "monthly-pending", "movie"] {
            let app = XCUIApplication()
            app.launchArguments = ["--app-store-screenshot-fixture",
                                   "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] = scenario
            app.launch()

            switch scenario {
            case "one", "three", "unavailable":
                let next = app.buttons["initial-scan-continue"]
                XCTAssertTrue(next.waitForExistence(timeout: 15))
                XCTAssertTrue(next.isHittable, "Continue must not wait for thumbnails.")
                if scenario != "unavailable" {
                    let expected = scenario == "one" ? 1 : 3
                    XCTAssertTrue(app.staticTexts["mainline-loaded-\(expected)"].waitForExistence(timeout: 15))
                    XCTAssertFalse(app.staticTexts["mainline-loaded-4"].exists)
                } else {
                    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "写真を表示できません").firstMatch
                        .waitForExistence(timeout: 15))
                }
                captureMainlineScreen(scenario)
                next.tap()
                let skipWidget = app.buttons["widget-placement-skip"]
                XCTAssertTrue(skipWidget.waitForExistence(timeout: 15))
                skipWidget.tap()
                XCTAssertTrue(app.staticTexts["mainline-fixture-finished"].waitForExistence(timeout: 10))
            case "limited-zero":
                XCTAssertTrue(app.staticTexts["猫の写真は見つかりませんでした"].waitForExistence(timeout: 15))
                captureMainlineScreen(scenario)
                app.buttons["もっと写真を選ぶ"].tap()
                XCTAssertTrue(app.staticTexts["mainline-action-choose"].waitForExistence(timeout: 5))
                app.buttons["もう一度スキャン"].tap()
                XCTAssertTrue(app.staticTexts["mainline-action-rescan"].waitForExistence(timeout: 5))
                app.buttons["initial-scan-continue"].tap()
                XCTAssertTrue(app.staticTexts["mainline-fixture-finished"].waitForExistence(timeout: 10))
            case "skip":
                let skip = app.buttons["onboarding-photo-permission-skip"]
                XCTAssertTrue(skip.waitForExistence(timeout: 15))
                captureMainlineScreen(scenario)
                skip.tap()
                XCTAssertTrue(app.staticTexts["mainline-fixture-finished"].waitForExistence(timeout: 10))
            case "monthly-empty", "monthly-pending":
                // With no completed reflection, Memories opens on saved
                // photos. Explicitly visit the existing empty/pending state.
                let summaries = app.segmentedControls["memories-section-picker"].buttons["ふりかえり"]
                XCTAssertTrue(summaries.waitForExistence(timeout: 15))
                summaries.tap()
                let expected = scenario == "monthly-empty"
                    ? "月の便りはまだありません" : "写真の確認を待っています"
                // SwiftUI exposes the parent section's identifier on the
                // combined card. Assert the actual visible title instead.
                let emptyState = app.staticTexts[expected]
                XCTAssertTrue(emptyState.waitForExistence(timeout: 15))
                captureMainlineScreen(scenario)
            case "movie":
                let ready = app.staticTexts["mainline-movie-ready"]
                let deadline = Date().addingTimeInterval(60)
                let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                while !ready.exists && Date() < deadline {
                    if app.staticTexts["mainline-movie-failed"].exists { break }
                    // The app deletes only the synthetic asset whose ID it
                    // created. Do not accept unrelated alerts.
                    let alert = springboard.alerts.firstMatch
                    for label in ["削除", "Delete"] where alert.exists && alert.buttons[label].exists {
                        alert.buttons[label].tap()
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                }
                XCTAssertTrue(ready.exists, "The real movie export or its fixture cleanup failed.")
            default: XCTFail("Unexpected acceptance scenario")
            }
            app.terminate()
        }
    }

    @MainActor
    private func captureMainlineScreen(_ scenario: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "mainline-\(scenario)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func firstExistingButton(
        in app: XCUIApplication,
        identifiers: [String],
        labels: [String],
        timeout: TimeInterval
    ) -> XCUIElement? {
        let candidates = identifiers.map { app.buttons[$0] }
            + labels.map { app.buttons[$0] }
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let candidate = candidates.first(where: \.exists) {
                return candidate
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return nil
    }

    @MainActor
    private func fail(_ message: String, app: XCUIApplication) {
        addDiagnosticAttachment(name: message, contents: app.debugDescription)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Screen on onboarding UI test failure"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTFail(message)
    }

    private func addDiagnosticAttachment(name: String, contents: String) {
        let attachment = XCTAttachment(string: contents)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Deterministic presentation tests: no library permission request, archive
/// write, movie export, or network operation is part of this fixture route.
final class SoloMemoriesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    @MainActor
    func testEmptyAndSingleSavedPhotoStartWithPhotosIncludingDeniedAccess() {
        for scenario in ["empty", "saved", "denied"] {
            let app = launch(scenario)
            assertSection("残した写真", in: app)
            if scenario == "saved" {
                XCTAssertTrue(app.staticTexts["solo-memories-loaded-1"].waitForExistence(timeout: 15))
                XCTAssertEqual(app.staticTexts["photo-book-progress"].label, "1枚")
                XCTAssertFalse(app.buttons["memories-open-photos"].exists)
                capture("solo-memories-single-saved-photo")
            } else {
                let openPhotos = app.buttons["memories-open-photos"]
                XCTAssertTrue(openPhotos.waitForExistence(timeout: 10))
                XCTAssertTrue(openPhotos.isHittable)
                if scenario == "empty" { capture("solo-memories-empty") }
                openPhotos.tap()
                let destination = app.staticTexts["solo-memories-other-screen"]
                XCTAssertTrue(destination.waitForExistence(timeout: 10))
                XCTAssertEqual(destination.label, "写真")
                app.buttons["solo-memories-return"].tap()
                assertSection("残した写真", in: app)
            }
            if scenario == "denied" {
                fixtureAction("solo-memories-toggle-access", in: app, expectedValue: "写真アクセスあり")
                assertSection("残した写真", in: app)
            }
            // Both sections stay available, independently of the initial one.
            selectSection("ふりかえり", in: app)
            if scenario == "denied" {
                XCTAssertTrue(monthlyCard(in: app).exists)
            } else {
                XCTAssertTrue(app.staticTexts["月の便りはまだありません"].exists)
            }
            selectSection("残した写真", in: app)
            app.terminate()
        }
    }

    @MainActor
    func testInitialReflectionAndLaterChangesPreserveTheChosenSection() {
        let app = launch("saved")
        assertSection("残した写真", in: app)
        fixtureAction("solo-memories-add-letter", in: app, expectedValue: "便りあり")
        assertSection("残した写真", in: app)
        selectSection("ふりかえり", in: app)
        XCTAssertTrue(monthlyCard(in: app).waitForExistence(timeout: 10))

        fixtureAction("solo-memories-toggle-access", in: app, expectedValue: "写真アクセスなし")
        assertSection("ふりかえり", in: app)
        XCTAssertTrue(app.staticTexts["写真へのアクセスを許可すると表示されます"].exists)
        fixtureAction("solo-memories-toggle-access", in: app, expectedValue: "写真アクセスあり")
        assertSection("ふりかえり", in: app)
        XCTAssertTrue(monthlyCard(in: app).exists)
        visitOtherScreenAndReturn(in: app)
        assertSection("ふりかえり", in: app)

        selectSection("残した写真", in: app)
        visitOtherScreenAndReturn(in: app)
        assertSection("残した写真", in: app)
        app.terminate()

        // A fresh first display with a completed letter starts on that letter.
        let readyApp = launch("monthly")
        assertSection("ふりかえり", in: readyApp)
        XCTAssertTrue(monthlyCard(in: readyApp).waitForExistence(timeout: 10))
        XCTAssertTrue(readyApp.staticTexts["solo-memories-loaded-1"].waitForExistence(timeout: 15))
        capture("solo-memories-monthly-ready")
        openCardAndReturn(monthlyCard(in: readyApp), expectedRoute: "monthly:2025-08", in: readyApp)
        assertSection("ふりかえり", in: readyApp)
        readyApp.terminate()
    }

    @MainActor
    func testSeasonalOnlyStartsFirstAndKeepsItsOrderWithLargestText() {
        let app = launch("seasonal-large")
        assertSection("ふりかえり", in: app, largeText: true)
        XCTAssertTrue(app.staticTexts["solo-memories-loaded-1"].waitForExistence(timeout: 15))
        // Native AX gives these children their section container's identifier.
        // Match the actual heading text, retaining the visual order assertion.
        let seasonalTitle = app.staticTexts["季節のムービー"]
        let monthlyTitle = app.staticTexts["月の便り"]
        XCTAssertTrue(seasonalTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(monthlyTitle.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(seasonalTitle.frame.height, 0)
        XCTAssertGreaterThan(monthlyTitle.frame.height, 0)
        XCTAssertLessThan(seasonalTitle.frame.minY, monthlyTitle.frame.minY)
        let menu = app.buttons["memories-section-menu"]
        XCTAssertTrue(menu.isHittable)
        XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
        XCTAssertGreaterThanOrEqual(menu.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(menu.frame.maxX, app.frame.maxX)
        capture("solo-memories-seasonal-first-largest-text")

        let seasonalCard = app.buttons["2025年7月–9月の季節のムービー、3場面、新着"]
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(seasonalCard.isHittable)
        capture("solo-memories-seasonal-card-largest-text")
        openCardAndReturn(seasonalCard, expectedRoute: "seasonal:2025-Q3", in: app)
        assertSection("ふりかえり", in: app, largeText: true)

        fixtureAction("solo-memories-add-letter", in: app, expectedValue: "便りあり")
        assertSection("ふりかえり", in: app, largeText: true)
        XCTAssertLessThan(seasonalTitle.frame.minY, monthlyTitle.frame.minY,
                          "A late monthly letter must not move the seasonal movie below it.")
        openCardAndReturn(monthlyCard(in: app), expectedRoute: "monthly:2025-08", in: app)
        for _ in 0..<6 where !menu.isHittable { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(menu.isHittable)
        selectSection("残した写真", in: app, largeText: true)
        visitOtherScreenAndReturn(in: app)
        assertSection("残した写真", in: app, largeText: true)
        selectSection("ふりかえり", in: app, largeText: true)
        XCTAssertLessThan(seasonalTitle.frame.minY, monthlyTitle.frame.minY)
        app.terminate()
    }

    @MainActor
    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-screenshot-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] = "solo-memories-\(scenario)"
        app.launch()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func monthlyCard(in app: XCUIApplication) -> XCUIElement {
        // Native AX identifies both the heading and card as
        // memories-latest-summary. The card's full spoken name stays distinct.
        app.buttons["2025年8月の小さな便り、5枚、未読"]
    }

    @MainActor
    private func openCardAndReturn(_ card: XCUIElement, expectedRoute: String, in app: XCUIApplication) {
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        for _ in 0..<6 where !card.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(card.isHittable, "The real card must remain reachable at this text size.")
        XCTAssertTrue(card.isEnabled)
        card.tap()
        let destination = app.staticTexts["solo-memories-detail-destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        XCTAssertEqual(destination.value as? String, expectedRoute)
        app.buttons["solo-memories-detail-return"].tap()
    }

    @MainActor
    private func assertSection(_ title: String, in app: XCUIApplication, largeText: Bool = false) {
        let identifier = title == "残した写真" ? "memories-saved-section" : "memories-summaries-section"
        XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: 10))
        if largeText {
            let menu = app.buttons["memories-section-menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
            XCTAssertTrue(menu.label.contains(title))
        } else {
            let selected = app.segmentedControls["memories-section-picker"].buttons[title]
            XCTAssertTrue(selected.waitForExistence(timeout: 10))
            XCTAssertTrue(selected.isSelected, "The visible section and selected control must agree.")
        }
    }

    @MainActor
    private func selectSection(_ title: String, in app: XCUIApplication, largeText: Bool = false) {
        if largeText {
            app.buttons["memories-section-menu"].tap()
            let option = app.buttons[title]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
        } else {
            app.segmentedControls["memories-section-picker"].buttons[title].tap()
        }
        assertSection(title, in: app, largeText: largeText)
    }

    @MainActor
    private func fixtureAction(_ identifier: String, in app: XCUIApplication, expectedValue: String? = nil) {
        let actions = app.buttons["solo-memories-fixture-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        let action = app.buttons[identifier]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
        if let expectedValue {
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@", expectedValue), object: actions
            )
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        }
    }

    @MainActor
    private func visitOtherScreenAndReturn(in app: XCUIApplication) {
        fixtureAction("solo-memories-open-other", in: app)
        XCTAssertTrue(app.staticTexts["solo-memories-other-screen"].waitForExistence(timeout: 10))
        app.buttons["solo-memories-return"].tap()
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Exercises the production composer offline, including the Japanese keyboard.
final class MomentDeliveryComposerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    @MainActor
    func testPhotoDeliveryProgressAllowsOtherActionsAndShowsTruthfulStates() {
        let app = XCUIApplication()
        app.launchArguments = ["--photo-delivery-progress-ui-fixture", "--delivery-progress-display-only",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let status = app.staticTexts["photo-delivery-progress-status-fixture-photo"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertEqual(status.label, "送信中")
        attach(app, name: "photo-delivery-progress-sending")
        let otherAction = app.buttons["delivery-progress-fixture-other-action"]
        XCTAssertTrue(otherAction.isHittable)
        otherAction.tap()
        XCTAssertEqual(app.staticTexts["delivery-progress-fixture-other-action-count"].label, "別の操作：1回")
        app.buttons["delivery-progress-fixture-waiting"].tap()
        XCTAssertEqual(status.label, "時間がかかっています")
        XCTAssertTrue(app.staticTexts["写真は保持しています。送り直しは不要です。"].exists)
        attach(app, name: "photo-delivery-progress-waiting")
        otherAction.tap()
        XCTAssertEqual(app.staticTexts["delivery-progress-fixture-other-action-count"].label, "別の操作：2回")
        app.buttons["delivery-progress-fixture-accepted"].tap()
        XCTAssertEqual(status.label, "送信しました。サーバーの受付を確認しました")
        attach(app, name: "photo-delivery-progress-accepted")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    @MainActor
    func testPhotoDeliveryProgressRemainsUsableWithLargestTextAndReducedMotion() {
        let app = XCUIApplication()
        app.launchArguments = ["--photo-delivery-progress-ui-fixture", "--delivery-progress-large-text",
                               "--delivery-progress-reduce-motion", "--delivery-progress-long-running",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let status = app.staticTexts["photo-delivery-progress-status-fixture-photo"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertEqual(status.label, "時間がかかっています")
        XCTAssertGreaterThan(status.frame.height, 40)
        XCTAssertGreaterThanOrEqual(status.frame.minX, 0)
        XCTAssertLessThanOrEqual(status.frame.maxX, app.frame.maxX)
        attach(app, name: "photo-delivery-progress-large-text-reduced-motion")
        let otherAction = app.buttons["delivery-progress-fixture-other-action"]
        for _ in 0..<3 where !otherAction.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(otherAction.isHittable)
        otherAction.tap()
        XCTAssertEqual(app.staticTexts["delivery-progress-fixture-other-action-count"].label, "別の操作：1回")
    }

    @MainActor
    func testPhotoBrowserDeliversVisiblePhotoAfterDestinationConfirmation() {
        var standardDestinationHeight: CGFloat = 0
        for variant in ["standard", "large"] {
            let app = XCUIApplication()
            app.launchArguments = ["--photo-window-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            if variant == "large" { app.launchArguments.append("--photo-window-large") }
            app.launch()
            let deliver = app.buttons["photo-browser-deliver"]
            XCTAssertTrue(deliver.waitForExistence(timeout: 15))
            // Swipe the actual production pager away from initialPhoto.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.30))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.30))
            start.press(forDuration: 0.05, thenDragTo: end)
            XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 5))
            for _ in 0..<4 where !deliver.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(deliver.isHittable)
            deliver.tap()
            let family = app.buttons["photo-window-destination-family"]
            XCTAssertTrue(family.waitForExistence(timeout: 10))
            attach(app, name: "photo-window-destinations-\(variant)")
            family.tap()
            let edit = app.buttons["family-window-caption-edit"]
            XCTAssertTrue(edit.waitForExistence(timeout: 10))
            edit.tap()
            let input = app.descendants(matching: .any)["family-window-caption-input"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.tap()
            input.typeText("ねむい")
            app.buttons["family-window-caption-done-top"].tap()
            app.buttons["photo-window-change-destination"].tap()
            let friends = app.buttons["photo-window-destination-friends"]
            XCTAssertTrue(friends.waitForExistence(timeout: 10))
            friends.tap()
            let destination = app.staticTexts["family-window-composer-destination"]
            XCTAssertTrue(destination.waitForExistence(timeout: 10))
            XCTAssertTrue(destination.label.contains("猫ともだち"))
            if variant == "standard" { standardDestinationHeight = destination.frame.height }
            if variant == "large" {
                XCTAssertGreaterThan(destination.frame.height, standardDestinationHeight * 1.4,
                    "Maximum text size must reach the presented confirmation, not only the photo browser.")
            }
            XCTAssertTrue(app.buttons["family-window-caption-edit"].label.contains("ねむい"))
            attach(app, name: "photo-window-confirmation-\(variant)")
            app.buttons["family-window-cancel-delivery"].tap()
            let result = app.staticTexts["photo-window-fixture-result"]
            XCTAssertTrue(result.waitForExistence(timeout: 5))
            XCTAssertTrue(result.label.hasPrefix("0|"), "Choosing and cancelling must not send.")
            // Any initial PhotoKit system prompt has been handled by the
            // preceding interaction; capture the unobscured production entry.
            attach(app, name: "photo-window-entry-\(variant)")
            deliver.tap()
            XCTAssertTrue(friends.waitForExistence(timeout: 10))
            friends.tap()
            let confirm = app.buttons["family-window-confirm-delivery"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            confirm.tap()
            expectation(for: NSPredicate(format: "label == %@", "1|2|friends|"), evaluatedWith: result)
            waitForExpectations(timeout: 10)
            XCTAssertFalse(app.alerts["送信を開始しました"].exists, "Sending must not block photo browsing.")
            XCTAssertEqual(result.label, "1|2|friends|", "Send exactly the visible, unsaved photo; a cancelled caption must not leak.")
            XCTAssertTrue(app.staticTexts["2 / 2"].exists, "Return to the same photo.")
            app.terminate()
        }
    }

    @MainActor
    func testPhotoWindowRetryPreservesConfirmedPhotoAndCaption() {
        let app = XCUIApplication()
        app.launchArguments = ["--photo-window-ui-fixture", "--photo-window-retry", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let deliver = app.buttons["photo-browser-deliver"]
        XCTAssertTrue(deliver.waitForExistence(timeout: 15))
        deliver.tap()
        let family = app.buttons["photo-window-destination-family"]
        XCTAssertTrue(family.waitForExistence(timeout: 10))
        family.tap()
        let edit = app.buttons["family-window-caption-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        let input = app.descendants(matching: .any)["family-window-caption-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("おやすみ")
        app.buttons["family-window-caption-done-top"].tap()
        let confirm = app.buttons["family-window-confirm-delivery"]
        confirm.tap()
        XCTAssertTrue(app.staticTexts["送信を開始できませんでした。もう一度お試しください。"].waitForExistence(timeout: 5))
        XCTAssertTrue(edit.label.contains("おやすみ"))
        XCTAssertTrue(app.staticTexts["family-window-composer-destination"].label.contains("マイファミリー"))
        confirm.tap()
        let result = app.staticTexts["photo-window-fixture-result"]
        expectation(for: NSPredicate(format: "label == %@", "1|1|family|おやすみ"), evaluatedWith: result)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.alerts["送信を開始しました"].exists)
        XCTAssertEqual(result.label, "1|1|family|おやすみ")
    }

    @MainActor
    func testPhotoWindowCancellationAndUnavailableSourcesDoNotSend() {
        for variant in ["empty", "unavailable", "slow"] {
            let app = XCUIApplication()
            app.launchArguments = ["--photo-window-ui-fixture", "--photo-window-\(variant)", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            app.launch()
            let deliver = app.buttons["photo-browser-deliver"]
            XCTAssertTrue(deliver.waitForExistence(timeout: 15))
            deliver.tap()
            if variant == "empty" {
                XCTAssertTrue(app.descendants(matching: .any)["photo-window-no-destinations"].firstMatch.waitForExistence(timeout: 10))
            } else {
                let family = app.buttons["photo-window-destination-family"]
                XCTAssertTrue(family.waitForExistence(timeout: 10))
                family.tap()
                if variant == "unavailable" {
                    XCTAssertTrue(app.buttons["もう一度確認"].waitForExistence(timeout: 10))
                    XCTAssertFalse(app.buttons["family-window-confirm-delivery"].exists)
                }
            }
            attach(app, name: "photo-window-\(variant)")
            app.buttons["photo-window-cancel"].tap()
            let result = app.staticTexts["photo-window-fixture-result"]
            XCTAssertTrue(result.waitForExistence(timeout: 5))
            XCTAssertTrue(result.label.hasPrefix("0|"))
            if variant == "slow" {
                XCTAssertFalse(app.buttons["family-window-confirm-delivery"].waitForExistence(timeout: 4), "A late image must not reopen a cancelled flow.")
            }
            XCTAssertTrue(deliver.isHittable)
            app.terminate()
        }
    }

    @MainActor
    func testReceivedPhotosKeepTheirFramesAcrossAspectRatiosAndTextSizes() {
        var standardDetailCaptionHeight: CGFloat = 0
        for variant in ["standard", "narrow", "large"] {
            let app = XCUIApplication()
            app.launchArguments = ["--moment-received-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            if variant == "narrow" { app.launchArguments.append("--received-narrow") }
            if variant == "large" { app.launchArguments.append("--received-large-text") }
            app.launch()
            let latest = app.buttons["received-fixture-latest"]
            XCTAssertTrue(latest.waitForExistence(timeout: 15))
            let initialFrame = latest.frame
            XCTAssertEqual(initialFrame.height, initialFrame.width * 0.75, accuracy: 2)
            XCTAssertGreaterThanOrEqual(initialFrame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(initialFrame.maxX, app.frame.maxX)
            let settled = NSPredicate { _, _ in app.progressIndicators.count == 0 }
            expectation(for: settled, evaluatedWith: app)
            waitForExpectations(timeout: 10)
            XCTAssertEqual(latest.frame.height, initialFrame.height, accuracy: 2,
                           "Decoded pixels must not resize the surrounding screen.")
            let actions = app.buttons["received-fixture-actions"]
            XCTAssertGreaterThanOrEqual(actions.frame.minY, latest.frame.maxY)
            actions.tap()
            XCTAssertTrue(app.staticTexts["received-fixture-action-result"].exists,
                          "The cropped photo must not intercept adjacent controls.")
            attach(app, name: "received-layout-\(variant)")
            latest.tap()
            verifySharpDetail(app, name: "received-detail-\(variant)")
            let detailCaption = app.buttons["photo-detail-read-caption"]
            XCTAssertTrue(detailCaption.exists)
            if variant == "standard" { standardDetailCaptionHeight = detailCaption.frame.height }
            if variant == "large" {
                XCTAssertGreaterThan(detailCaption.frame.height, standardDetailCaptionHeight * 1.4,
                                     "The maximum text size must reach the full-screen detail, not just its presenting list.")
            }
            if variant == "narrow" {
                XCTAssertLessThanOrEqual(app.descendants(matching: .any)["photo-detail-zoom-surface"].firstMatch.frame.width, 290,
                                         "The narrow fixture must also constrain the opened photo.")
            }
            let firstPhotoPixels = Self.detailValue(
                app.descendants(matching: .any)["photo-detail-zoom-surface"].firstMatch.value as? String,
                field: "pixels")
            verifyCaptionRoundTrip(app,
                identifier: "received-fixture-full-caption",
                expected: String(repeating: "ねこの写真とひとことを、ゆっくり見返しています。", count: 3))
            for action in ["save", "heart"] {
                let control = app.buttons["received-fixture-detail-\(action)"]
                let footer = app.scrollViews["photo-detail-actions-scroll"]
                for _ in 0..<4 where !control.isHittable && footer.exists { footer.swipeUp() }
                XCTAssertTrue(control.isHittable)
                control.tap()
                XCTAssertTrue(app.staticTexts["received-fixture-detail-\(action)-result"].waitForExistence(timeout: 5))
            }
            closePhotoDetail(app)
            XCTAssertTrue(latest.isHittable)
            let scroll = app.scrollViews.firstMatch
            for index in 0..<4 {
                let tile = app.buttons["received-fixture-tile-\(index)"]
                for _ in 0..<6 where !tile.isHittable { scroll.swipeUp() }
                XCTAssertTrue(tile.isHittable, "Every photo, including the missing-file placeholder, stays reachable.")
                let photo = app.descendants(matching: .any)["received-fixture-tile-photo-\(index)"].firstMatch
                XCTAssertTrue(photo.exists)
                XCTAssertEqual(photo.frame.width, photo.frame.height, accuracy: 2)
                XCTAssertTrue(tile.frame.insetBy(dx: -2, dy: -2).contains(photo.frame),
                              "Caption and photo must remain inside the same reachable tile.")
                XCTAssertGreaterThanOrEqual(tile.frame.minX, app.frame.minX)
                XCTAssertLessThanOrEqual(tile.frame.maxX, app.frame.maxX)
                if variant == "standard", index > 0 {
                    tile.tap()
                    let decodedPhoto = app.descendants(matching: .any)["photo-detail-zoom-surface"].firstMatch
                    if index == 3 {
                        let retry = app.buttons["photo-detail-retry"]
                        XCTAssertTrue(retry.waitForExistence(timeout: 10))
                        XCTAssertFalse(decodedPhoto.exists,
                                       "A missing file must not retain the previously opened photo.")
                        retry.tap()
                        XCTAssertTrue(app.staticTexts["写真を読み込めませんでした"].waitForExistence(timeout: 10))
                        XCTAssertTrue(retry.isHittable)
                        XCTAssertFalse(decodedPhoto.exists)
                    } else {
                        XCTAssertTrue(decodedPhoto.waitForExistence(timeout: 10))
                        XCTAssertGreaterThanOrEqual(Self.detailValue(decodedPhoto.value as? String, field: "pixels") ?? 0, 1_000)
                        if index == 1 {
                            // The gray portrait and orange square fixtures have
                            // different canonical dimensions. Read the decoded
                            // image, not merely a selected-row label.
                            XCTAssertNotEqual(Self.detailValue(decodedPhoto.value as? String, field: "pixels"), firstPhotoPixels,
                                              "Opening a different tile must replace the previous decoded photo.")
                            attach(app, name: "received-second-photo")
                        } else {
                            XCTAssertFalse(app.buttons["photo-detail-read-caption"].exists,
                                           "A photo without a caption must not inherit another photo's text.")
                            verifyPanoramicPhotoPanning(app, image: decodedPhoto)
                            attach(app, name: "received-no-caption")
                        }
                    }
                    closePhotoDetail(app)
                    XCTAssertTrue(tile.isHittable)
                }
            }
            attach(app, name: "received-grid-\(variant)")
            app.terminate()
        }
    }

    @MainActor
    func testSentHistoryKeepsPhotosVisibleAndMissingPhotosCompact() {
        for variant in ["standard", "narrow", "large", "notification"] {
            let app = XCUIApplication()
            app.launchArguments = ["--moment-history-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            if variant == "large" { app.launchArguments.append("--history-large-text") }
            if variant == "narrow" { app.launchArguments.append("--history-narrow") }
            if variant == "notification" { app.launchArguments.append("--history-notification-target") }
            app.launch()
            let photo = app.buttons["history-fixture-photo"]
            let missing = app.buttons["history-fixture-missing"]
            XCTAssertTrue(photo.waitForExistence(timeout: 15))
            XCTAssertTrue(photo.isHittable)
            let photoHeight = photo.frame.height
            if variant == "notification" {
                XCTAssertTrue(missing.isHittable)
                XCTAssertLessThanOrEqual(missing.frame.maxY, photo.frame.minY,
                                         "The exact notification target stays first even without a preview.")
            }
            for _ in 0..<6 where !missing.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(missing.isHittable)
            XCTAssertLessThan(missing.frame.height, photoHeight,
                              "Fileless history must not occupy a full photo tile.")
            if variant != "notification", photo.isHittable {
                XCTAssertGreaterThanOrEqual(missing.frame.minY, photo.frame.maxY,
                                            "Photo content must come before fileless history.")
            }
            attach(app, name: "sent-history-\(variant)")
            for status in ["サーバー受付済み", "相手のiPhoneへ到着"] {
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", status)).firstMatch.exists,
                               "Normal delivery bookkeeping must not take over the photo list.")
            }
            missing.tap()
            XCTAssertTrue(app.staticTexts["写真を表示できません"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.descendants(matching: .any)["photo-detail-zoom-surface"].firstMatch.exists)
            verifyCaptionRoundTrip(app, identifier: "history-fixture-detail-caption",
                expected: "のびー。今日はずっといっしょにいたいみたいです。")
            closePhotoDetail(app)
            for _ in 0..<6 where !photo.isHittable { app.scrollViews.firstMatch.swipeDown() }
            XCTAssertTrue(photo.isHittable)
            photo.tap()
            verifySharpDetail(app, name: "sent-canonical-\(variant)")
            verifyCaptionRoundTrip(app, identifier: "history-fixture-detail-caption",
                expected: "おこってるんだけど？")
            closePhotoDetail(app)
            XCTAssertTrue(photo.isHittable)
            if variant == "standard" {
                let legacy = app.buttons["history-fixture-legacy"]
                for _ in 0..<6 where !legacy.isHittable { app.scrollViews.firstMatch.swipeUp() }
                legacy.tap()
                let image = app.descendants(matching: .any)["photo-detail-legacy-image"].firstMatch
                XCTAssertTrue(image.waitForExistence(timeout: 5))
                XCTAssertGreaterThan(Self.detailValue(image.value as? String, field: "pixels") ?? 0, 0)
                XCTAssertLessThanOrEqual(Self.detailValue(image.value as? String, field: "pixels") ?? .infinity, 240)
                XCTAssertFalse(app.descendants(matching: .any)["photo-detail-zoom-surface"].firstMatch.exists)
                attach(app, name: "sent-legacy-small-copy")
                closePhotoDetail(app)
                XCTAssertTrue(legacy.isHittable)
            }
            app.terminate()
        }
    }

    private nonisolated static func detailValue(_ value: String?, field: String) -> Double? {
        guard let value else { return nil }
        return value.split(separator: ";").compactMap { part -> Double? in
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0] == field else { return nil }
            return Double(pair[1])
        }.first
    }

    @MainActor
    private func verifySharpDetail(_ app: XCUIApplication, name: String) {
        let image = app.descendants(matching: .any)["photo-detail-zoom-surface"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(Self.detailValue(image.value as? String, field: "pixels") ?? 0, 1_000,
                                    "Opened detail must decode the canonical photo, not the list thumbnail.")
        XCTAssertEqual(Self.detailValue(image.value as? String, field: "zoom") ?? 0, 1, accuracy: 0.05)
        XCTAssertTrue(app.frame.insetBy(dx: -2, dy: -2).contains(image.frame))
        if name.hasSuffix("standard") {
            XCTAssertGreaterThan(image.frame.height, app.frame.height * 0.65,
                "Ordinary captions must not reserve an empty footer that shrinks the photo.")
        }
        attach(app, name: name)
        image.doubleTap()
        expectation(for: NSPredicate { _, _ in (Self.detailValue(image.value as? String, field: "zoom") ?? 0) > 1.1 }, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        attach(app, name: "\(name)-zoomed")
        image.doubleTap()
        expectation(for: NSPredicate { _, _ in abs((Self.detailValue(image.value as? String, field: "zoom") ?? 0) - 1) < 0.05 }, evaluatedWith: image)
        waitForExpectations(timeout: 5)
    }

    private nonisolated static func panoramicPhotoStaysVisible(_ value: String?) -> Bool {
        guard let photoHeight = detailValue(value, field: "photoHeight"),
              let viewportHeight = detailValue(value, field: "viewportHeight"),
              let contentHeight = detailValue(value, field: "contentHeight"),
              let viewportWidth = detailValue(value, field: "viewportWidth"),
              let contentWidth = detailValue(value, field: "contentWidth"),
              let photoWidth = detailValue(value, field: "photoWidth"),
              let offsetY = detailValue(value, field: "offsetY"),
              let visibleHeight = detailValue(value, field: "visibleHeight"),
              let visibleWidth = detailValue(value, field: "visibleWidth") else { return false }
        return photoHeight > 0 && photoHeight < viewportHeight
            && abs(contentHeight - photoHeight) < 2 && abs(contentWidth - photoWidth) < 2
            && abs(offsetY + (viewportHeight - photoHeight) / 2) < 2
            && abs(visibleHeight - photoHeight) < 2 && visibleWidth >= viewportWidth - 2
    }

    @MainActor
    private func verifyPanoramicPhotoPanning(_ app: XCUIApplication, image: XCUIElement) {
        let width = Self.detailValue(image.value as? String, field: "photoWidth") ?? 0
        let height = Self.detailValue(image.value as? String, field: "photoHeight") ?? 1
        XCTAssertGreaterThan(width / max(height, 1), 3.8,
                             "The panning fixture must exercise an actual wide photograph.")
        XCTAssertEqual(Self.detailValue(image.value as? String, field: "zoom") ?? 0, 1, accuracy: 0.05)
        image.doubleTap()
        expectation(for: NSPredicate { _, _ in
            (Self.detailValue(image.value as? String, field: "zoom") ?? 0) > 2
                && Self.panoramicPhotoStaysVisible(image.value as? String)
        }, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        for (start, end) in [
            (CGVector(dx: 0.5, dy: 0.8), CGVector(dx: 0.5, dy: 0.1)),
            (CGVector(dx: 0.5, dy: 0.2), CGVector(dx: 0.5, dy: 0.9)),
            (CGVector(dx: 0.9, dy: 0.5), CGVector(dx: 0.1, dy: 0.5)),
            (CGVector(dx: 0.1, dy: 0.5), CGVector(dx: 0.9, dy: 0.5))
        ] {
            image.coordinate(withNormalizedOffset: start).press(forDuration: 0.05,
                thenDragTo: image.coordinate(withNormalizedOffset: end))
            expectation(for: NSPredicate { _, _ in
                Self.panoramicPhotoStaysVisible(image.value as? String)
            }, evaluatedWith: image)
            waitForExpectations(timeout: 5)
        }
        attach(app, name: "received-panorama-edge-pan")
        image.doubleTap()
        expectation(for: NSPredicate { _, _ in
            abs((Self.detailValue(image.value as? String, field: "zoom") ?? 0) - 1) < 0.05
        }, evaluatedWith: image)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func verifyCaptionRoundTrip(_ app: XCUIApplication, identifier: String, expected: String) {
        let read = app.buttons["photo-detail-read-caption"]
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        XCTAssertTrue(read.isHittable)
        read.tap()
        let caption = app.staticTexts[identifier]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertEqual(caption.label, expected)
        app.navigationBars["ひとこと"].buttons["閉じる"].tap()
        expectation(for: NSPredicate { _, _ in !caption.exists }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(read.isHittable)
    }

    @MainActor
    private func closePhotoDetail(_ app: XCUIApplication) {
        let close = app.buttons["photo-detail-close"]
        XCTAssertTrue(close.isHittable)
        close.tap()
        expectation(for: NSPredicate { _, _ in !close.exists }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testCaptionOnPhotoAndReturnFromKeyboard() {
        var standardCaptionHeight: CGFloat = 0
        for variant in ["standard", "large", "panorama"] {
            let app = XCUIApplication()
            app.launchArguments = ["--moment-composer-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            if variant == "large" { app.launchArguments.append("--composer-large-text") }
            if variant == "panorama" { app.launchArguments.append("--composer-panorama") }
            app.launch()
            let open = app.buttons["composer-fixture-open"]
            XCTAssertTrue(open.waitForExistence(timeout: 15))
            open.tap()
            let edit = app.buttons["family-window-caption-edit"]
            XCTAssertTrue(edit.waitForExistence(timeout: 10))
            XCTAssertTrue(edit.isHittable)
            edit.tap()
            let input = app.descendants(matching: .any)["family-window-caption-input"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.typeText("のびー")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let done = app.buttons["family-window-caption-done-top"]
            XCTAssertTrue(done.isHittable, "The navigation Done action must stay above the keyboard.")
            let footerDone = app.buttons["family-window-caption-done"]
            XCTAssertTrue(footerDone.isHittable, "The footer must remain above the keyboard.")
            XCTAssertTrue(app.buttons["family-window-cancel-delivery"].isHittable)
            attach(app, name: "caption-edit-\(variant)")
            if variant == "standard" { done.tap() }
            else { footerDone.tap() }
            XCTAssertTrue(waitForKeyboardToClose(app))
            XCTAssertTrue(edit.label.contains("のびー"), "Finishing input must preserve the caption on the photo.")
            if variant == "standard" { standardCaptionHeight = edit.frame.height }
            if variant == "large" {
                XCTAssertGreaterThan(edit.frame.height, standardCaptionHeight * 1.2,
                                     "Large text must actually reach the presented composer.")
            }
            let photo = app.descendants(matching: .any)["family-window-composer-photo"].firstMatch
            XCTAssertTrue(photo.exists)
            XCTAssertTrue(photo.frame.insetBy(dx: -1, dy: -1).contains(edit.frame), "The caption belongs inside the photo preview.")
            let navigation = app.navigationBars["写真を確認"]
            let destination = app.staticTexts["family-window-composer-destination"]
            XCTAssertGreaterThanOrEqual(photo.frame.minY, navigation.frame.maxY - 2,
                                       "Finishing input must return the complete photo below the navigation bar.")
            XCTAssertLessThanOrEqual(photo.frame.maxY, destination.frame.minY + 2,
                                    "The photo and its recipient must remain visible together after finishing input.")
            XCTAssertTrue(destination.isHittable)
            let send = app.buttons["family-window-confirm-delivery"]
            XCTAssertTrue(send.isHittable, "Sending must be reachable without scrolling after input.")
            attach(app, name: "caption-preview-\(variant)")
            send.tap()
            let sent = app.staticTexts["composer-fixture-sent"]
            XCTAssertTrue(sent.waitForExistence(timeout: 5))
            XCTAssertEqual(sent.label, "送信内容：のびー")

            if variant != "standard" {
                app.terminate()
                continue
            }

            // Cancel directly while editing, then ensure the next photo is blank.
            open.tap()
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            edit.tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.typeText("とりけし")
            app.buttons["family-window-cancel-delivery"].tap()
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            XCTAssertFalse(app.navigationBars["写真を確認"].exists)
            open.tap()
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            XCTAssertEqual(edit.label, "ひとことを添える")
            app.buttons["family-window-confirm-delivery"].tap()
            XCTAssertTrue(sent.waitForExistence(timeout: 5))
            XCTAssertEqual(sent.label, "送信内容：")
            app.terminate()
        }
    }

    @MainActor
    private func waitForKeyboardToClose(_ app: XCUIApplication) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
