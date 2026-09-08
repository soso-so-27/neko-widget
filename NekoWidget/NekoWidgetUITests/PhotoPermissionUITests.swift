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

/// Exercises the production composer offline, including the Japanese keyboard.
final class MomentDeliveryComposerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    @MainActor
    func testReceivedPhotosKeepTheirFramesAcrossAspectRatiosAndTextSizes() {
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
            let firstPhotoPixels = Self.detailValue(
                app.descendants(matching: .any)["photo-detail-zoom-surface"].firstMatch.value as? String,
                field: "pixels")
            verifyCaptionRoundTrip(app,
                identifier: "received-fixture-full-caption",
                expected: String(repeating: "ねこの写真とひとことを、ゆっくり見返しています。", count: 3))
            for action in ["save", "heart"] {
                let control = app.buttons["received-fixture-detail-\(action)"]
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
        attach(app, name: name)
        image.doubleTap()
        expectation(for: NSPredicate { _, _ in (Self.detailValue(image.value as? String, field: "zoom") ?? 0) > 1.1 }, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        attach(app, name: "\(name)-zoomed")
        image.doubleTap()
        expectation(for: NSPredicate { _, _ in abs((Self.detailValue(image.value as? String, field: "zoom") ?? 0) - 1) < 0.05 }, evaluatedWith: image)
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
            XCTAssertEqual(edit.label, "ひとことを書く")
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
