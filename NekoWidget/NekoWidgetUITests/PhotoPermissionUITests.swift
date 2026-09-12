import XCTest

final class OfficialWindowUITests: XCTestCase {
    @MainActor
    func testDiscoverReceiveGuideAndStopUpdatesWindowList() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments = ["--window-list-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let addition = app.buttons["window-list-addition"]
        XCTAssertTrue(addition.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["official-window-entry"].exists, "Unsubscribed windows belong in discovery")
        addition.tap()
        app.buttons["window-list-discover"].tap()
        app.buttons["official-window-entry"].tap()
        XCTAssertTrue(app.tabBars.buttons["写真"].exists)
        XCTAssertTrue(app.tabBars.buttons["思い出"].exists)
        for _ in 0..<5 { if app.buttons["official-window-subscribe"].isHittable { break }; app.swipeUp() }
        app.buttons["official-window-subscribe"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["official-window-subscription-confirmation"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["どこかの猫"].exists, "Receiving must not send the user back to the list")
        XCTAssertTrue(app.descendants(matching: .any)["official-window-image-unavailable"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["official-window-refresh"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["official-window-image-loaded"].firstMatch.waitForExistence(timeout: 10))
        let guide = app.buttons["official-window-widget-guide"]
        for _ in 0..<5 { if guide.isHittable { break }; app.swipeUp() }
        guide.tap()
        XCTAssertTrue(app.navigationBars["ホーム画面に置く"].waitForExistence(timeout: 5))
        app.buttons["すでに置いている"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["official-window-widget-source"].firstMatch.exists)
        capture("window-widget-guide-existing", app)
        app.buttons["閉じる"].tap()
        app.navigationBars["どこかの猫"].buttons.element(boundBy: 0).tap()
        app.navigationBars["まどを探す"].buttons.element(boundBy: 0).tap()
        app.navigationBars["まどを追加"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["official-window-entry"].waitForExistence(timeout: 5))
        capture("window-list-after-receiving", app)
        app.buttons["official-window-entry"].tap()
        stopReceiving(app)
        XCTAssertTrue(app.buttons["official-window-subscribe"].waitForExistence(timeout: 5))
        app.navigationBars["どこかの猫"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(addition.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["official-window-entry"].exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }

    @MainActor
    func testWindowListLargeTextKeepsDiscoveryAndPhotoReachable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--window-list-ui-fixture", "--window-list-subscribed",
                               "--window-list-large-text", "-AppleLanguages", "(ja)"]
        app.launch()
        let card = app.buttons["official-window-entry"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.isHittable)
        XCTAssertTrue(app.buttons["window-list-addition"].isHittable)
        XCTAssertTrue(app.tabBars.buttons["写真"].isHittable)
        capture("window-list-large-text", app)
        card.tap()
        let manage = app.buttons["official-window-manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        // A toolbar Menu exposes both its labelled accessibility button and an
        // underlying button at the same frame. Verify the user's operation and
        // destination instead of relying on the labelled node's hit-test flag.
        manage.tap()
        let about = app.buttons["official-window-about"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.tap()
        XCTAssertTrue(app.navigationBars["このまどについて"].waitForExistence(timeout: 5))
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.navigationBars["どこかの猫"].waitForExistence(timeout: 5))
        capture("official-window-overview-large-text", app)
        let photo = app.buttons["official-window-photo-fixture-photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        // The zoom surface keeps its own identity inside the photo's
        // accessibility group. Its metrics exclude the overview thumbnail.
        let zoomSurface = app.images.matching(NSPredicate(
            format: "identifier == %@ AND value CONTAINS %@",
            "photo-detail-zoom-surface", "zoom="
        )).firstMatch
        XCTAssertTrue(zoomSurface.waitForExistence(timeout: 5))
        func metric(_ field: String) -> Double {
            let value = zoomSurface.value as? String ?? ""
            let part = value.split(separator: ";").first { $0.hasPrefix(field + "=") }
            return part.flatMap { Double($0.dropFirst(field.count + 1)) } ?? 0
        }
        XCTAssertGreaterThanOrEqual(metric("pixels"), 1_000)
        XCTAssertEqual(metric("zoom"), 1, accuracy: 0.05)
        capture("official-photo-large-text", app)
        zoomSurface.doubleTap()
        expectation(for: NSPredicate { _, _ in metric("zoom") > 1.1 }, evaluatedWith: zoomSurface)
        waitForExpectations(timeout: 5)
        capture("official-photo-large-text-zoom", app)
        app.buttons["official-photo-information"].tap()
        XCTAssertTrue(app.navigationBars["写真の情報"].waitForExistence(timeout: 5))
        let photographedOn = app.staticTexts["撮影日：2026-09-01"]
        for _ in 0..<5 where !photographedOn.isHittable {
            app.scrollViews["official-photo-information-content"].swipeUp()
        }
        XCTAssertTrue(photographedOn.isHittable)
        capture("official-photo-information-large-text", app)
        app.buttons["official-photo-information-close"].tap()
        XCTAssertTrue(app.navigationBars["確認用の猫"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(metric("zoom"), 1.1, "Reading information must keep the photo and zoom position")
        XCTAssertTrue(app.buttons["閉じる"].isHittable)
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.navigationBars["どこかの猫"].exists)
    }

    @MainActor
    func testReceiveRetryOpenAndStopWithoutPhotoPermission() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments = ["--official-window-ui-fixture", "--official-window-recent-photos", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let subscribe = app.buttons["official-window-subscribe"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 15))
        let preview = app.buttons["official-window-photo-fixture-photo"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.tap()
        XCTAssertTrue(app.navigationBars["確認用の猫"].waitForExistence(timeout: 5))
        capture("official-window-preview-detail", app)
        app.buttons["閉じる"].tap()
        XCTAssertTrue(subscribe.exists, "Previewing must not subscribe")
        XCTAssertFalse(app.buttons["official-window-widget-guide"].exists)
        capture("official-window-before-receiving", app)
        for _ in 0..<5 { if subscribe.isHittable { break }; app.swipeUp() }
        subscribe.tap()
        XCTAssertTrue(app.descendants(matching: .any)["official-window-image-unavailable"].firstMatch.waitForExistence(timeout: 10))
        preview.tap()
        let retryPhoto = app.buttons["official-photo-retry"]
        XCTAssertTrue(retryPhoto.waitForExistence(timeout: 5))
        XCTAssertEqual(retryPhoto.label, "写真をもう一度読み込む")
        XCTAssertGreaterThanOrEqual(retryPhoto.frame.height, 44)
        retryPhoto.tap()
        let recoveredPhoto = app.images["photo-detail-zoom-surface"]
        XCTAssertTrue(recoveredPhoto.waitForExistence(timeout: 10), "Same-file retry must load the detail's photo, not just its background overview")
        XCTAssertTrue(recoveredPhoto.isHittable)
        XCTAssertTrue(app.navigationBars["確認用の猫"].exists)
        capture("official-photo-retry-recovered", app)
        app.buttons["閉じる"].tap()
        for _ in 0..<5 { if preview.isHittable { break }; app.swipeDown() }
        capture("official-window-photo", app)
        app.buttons["official-window-photo-fixture-photo"].tap()
        XCTAssertTrue(app.navigationBars["確認用の猫"].waitForExistence(timeout: 5))
        capture("official-window-photo-detail", app)
        app.buttons["閉じる"].tap()
        let recent = app.buttons["official-window-photo-fixture-photo-1"]
        for _ in 0..<6 { if recent.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(recent.isHittable)
        if recent.frame.maxY > app.frame.height * 0.85 { app.swipeUp() }
        capture("official-window-recent-photos", app)
        recent.tap()
        XCTAssertTrue(app.navigationBars["確認用の猫"].waitForExistence(timeout: 5))
        app.buttons["閉じる"].tap()
        XCTAssertFalse(app.buttons["official-window-stop"].exists, "Management must stay out of the photo list")
        app.buttons["official-window-manage"].tap()
        app.buttons["official-window-stop"].tap()
        let cancelStop = receivingConfirmationButton("official-window-stop-cancel", in: app)
        XCTAssertTrue(cancelStop.waitForExistence(timeout: 5))
        capture("official-window-stop-confirmation", app)
        cancelStop.tap()
        XCTAssertFalse(subscribe.exists, "Canceling stop keeps the subscription")
        stopReceiving(app)
        XCTAssertTrue(subscribe.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["official-window-image-loaded"].firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        capture("official-window-receiving-stopped", app)
    }

    @MainActor
    func testMixedWindowsKeepAdditionAndScopedRecoveryReachable() {
        continueAfterFailure = false
        for largeText in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--window-list-ui-fixture", "--window-list-mixed", "--window-list-subscribed",
                                   "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            if largeText { app.launchArguments.append("--window-list-large-text") }
            else { app.launchArguments.append("--window-list-dark") }
            app.launch()
            let family = app.buttons["window-list-row-10000000-0000-0000-0000-000000000001"]
            XCTAssertTrue(family.waitForExistence(timeout: 10))
            XCTAssertEqual(family.value as? String, "写真あり")
            XCTAssertFalse(family.label.contains("確認"), "Another window's error must not label this window")
            if !largeText {
                let official = app.buttons["official-window-entry"]
                XCTAssertTrue(official.waitForExistence(timeout: 10))
                XCTAssertEqual(family.frame.width, official.frame.width, accuracy: 1)
                XCTAssertEqual(family.frame.height, official.frame.height, accuracy: 1,
                               "A portrait photo and its credit must not make one window taller")
                XCTAssertEqual(family.frame.minY, official.frame.minY, accuracy: 1)
                XCTAssertTrue((official.value as? String ?? "").contains("AI生成"))
            }
            let setup = app.buttons["window-list-row-10000000-0000-0000-0000-000000000002"]
            for _ in 0..<6 { if setup.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(setup.isHittable)
            XCTAssertTrue((setup.value as? String ?? "").contains("設定を開いて確認"))
            if !largeText {
                XCTAssertLessThan(setup.frame.height, family.frame.height / 2,
                                  "Unfinished setup is a compact resume row, not another photo card")
            }
            capture(largeText ? "window-mixed-large-text" : "window-mixed-standard", app)
            let addition = app.buttons["window-list-addition"]
            XCTAssertTrue(addition.isHittable)
            addition.tap()
            let discover = app.buttons["window-list-discover"]
            XCTAssertTrue(discover.waitForExistence(timeout: 5))
            let resume = app.buttons["window-list-resume-setup"]
            for _ in 0..<5 { if resume.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(resume.isHittable)
            XCTAssertTrue(resume.label.contains("ねことも"))
            XCTAssertFalse(app.buttons["window-list-create"].exists, "Resume the existing setup slot")
            capture(largeText ? "window-addition-large-text" : "window-addition-standard", app)
            resume.tap()
            XCTAssertTrue(app.navigationBars["ねことも"].waitForExistence(timeout: 5))
            let restart = app.buttons["設定をやり直す"]
            for _ in 0..<6 { if restart.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(restart.isHittable, "Failed setup must have a recovery action")
            restart.tap()
            let create = app.buttons["新しいまどを作る"]
            for _ in 0..<6 { if create.isHittable { break }; app.swipeDown() }
            XCTAssertTrue(create.waitForExistence(timeout: 5), "Recovery reuses the slot for the setup choices")
            app.navigationBars["ねことも"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(addition.waitForExistence(timeout: 5), "Closing setup returns to the window list")
            addition.tap()
            XCTAssertTrue(discover.waitForExistence(timeout: 5))
            discover.tap()
            XCTAssertTrue(app.buttons["official-window-entry"].waitForExistence(timeout: 5),
                          "Private setup must not block public discovery")
            app.terminate()
        }
    }

    @MainActor
    func testFailedRemoteSetupHasOneRecoveryPathAndPreservesItAfterFailure() {
        continueAfterFailure = false
        for largeText in [false, true] {
            let app = launchFailedSetup("remote", largestText: largeText)
            let title = app.staticTexts["pairing-failure-title"]
            let restart = app.buttons["pairing-recovery-action"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            XCTAssertEqual(app.staticTexts.matching(identifier: "pairing-failure-title").count, 1)
            XCTAssertEqual(app.textFields.count, 0, "A failed connection must not offer name sharing")
            XCTAssertFalse(app.staticTexts["画面の案内を確認してください"].exists)
            XCTAssertFalse(app.staticTexts["まどの設定を完了できませんでした"].exists)
            capture(largeText ? "pairing-failed-remote-largest-initial" : "pairing-failed-remote", app)
            if largeText && !restart.isHittable { app.swipeUp() }
            XCTAssertTrue(restart.isHittable, "Recovery comes before secondary settings and explanation")
            XCTAssertEqual(restart.label, "つなぎ直す")
            XCTAssertGreaterThanOrEqual(restart.frame.height + 0.001, 44)
            capture(largeText ? "pairing-failed-remote-largest-action" : "pairing-failed-remote-action", app)
            restart.tap()
            let cancel = pairingConfirmationButton("pairing-reset-cancel", title: "戻る", in: app)
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            capture(largeText ? "pairing-reset-confirmation-largest" : "pairing-reset-confirmation", app)
            cancel.tap()
            XCTAssertTrue(restart.waitForExistence(timeout: 5), "Cancel must keep the failed setup")
            restart.tap()
            pairingConfirmationButton("pairing-reset-confirm", title: "取り消してつなぎ直す", in: app).tap()
            let error = app.staticTexts["pairing-recovery-error"]
            XCTAssertTrue(error.waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts.matching(identifier: "pairing-recovery-error").count, 1)
            XCTAssertFalse(app.buttons["新しいまどを作る"].exists,
                           "A cancellation failure must not show fresh setup as if it succeeded")
            for _ in 0..<2 where !restart.isHittable { app.swipeUp() }
            XCTAssertTrue(restart.isHittable)
            capture(largeText ? "pairing-reset-kept-after-failure-largest" : "pairing-reset-kept-after-failure", app)
            restart.tap()
            pairingConfirmationButton("pairing-reset-confirm", title: "取り消してつなぎ直す", in: app).tap()
            let create = app.buttons["新しいまどを作る"]
            for _ in 0..<5 where !create.isHittable { app.swipeUp() }
            XCTAssertTrue(create.waitForExistence(timeout: 5))
            XCTAssertFalse(title.exists)
            app.terminate()
        }
    }

    @MainActor
    func testIncompleteSetupOpensDiagnosticsWithoutDestructiveReset() {
        let app = launchFailedSetup("unavailable", largestText: false)
        let diagnostics = app.buttons["pairing-recovery-diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        XCTAssertTrue(diagnostics.isHittable)
        XCTAssertFalse(app.buttons["pairing-recovery-action"].exists)
        capture("pairing-failed-incomplete-information", app)
        diagnostics.tap()
        XCTAssertTrue(app.navigationBars["診断ログ"].waitForExistence(timeout: 5))
        app.navigationBars["診断ログ"].buttons.element(boundBy: 0).tap()
        let information = app.buttons["pairing-sharing-information"]
        XCTAssertTrue(information.waitForExistence(timeout: 5))
        information.tap()
        XCTAssertTrue(app.navigationBars["共有について"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["確認した1枚だけを届けます"].exists)
        app.terminate()
    }

    @MainActor
    private func launchFailedSetup(_ scenario: String, largestText: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--window-list-ui-fixture", "--window-list-mixed", "--window-list-dark",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        if largestText { app.launchArguments.append("--window-list-largest-text") }
        app.launchEnvironment["NEKO_PAIRING_FAILURE_FIXTURE"] = scenario
        app.launch()
        let setup = app.buttons["window-list-row-10000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        for _ in 0..<4 where !setup.isHittable { app.swipeUp() }
        setup.tap()
        return app
    }

    @MainActor
    private func pairingConfirmationButton(_ identifier: String, title: String, in app: XCUIApplication) -> XCUIElement {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let identified = alert.buttons.matching(identifier: identifier).firstMatch
        return identified.waitForExistence(timeout: 2) ? identified : alert.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    @MainActor
    private func stopReceiving(_ app: XCUIApplication) {
        let manage = app.buttons["official-window-manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()
        app.buttons["official-window-stop"].tap()
        let confirm = receivingConfirmationButton("official-window-stop-confirm", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Stopping needs a deliberate confirmation")
        confirm.tap()
    }

    @MainActor
    private func receivingConfirmationButton(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        // iOS 26's recorded AX tree exposes a parent and child Button with
        // the same ID/label for one alert action. Scope to this exact alert
        // before selecting that action; the post-tap subscription checks stay.
        app.alerts["「どこかの猫」の受け取りをやめますか？"]
            .buttons.matching(identifier: identifier).firstMatch
    }

    @MainActor
    func testUnconfiguredFeedIsPreparationNotFakeDelivery() {
        let app = XCUIApplication()
        app.launchArguments = ["--official-window-ui-fixture", "--official-window-unconfigured", "-AppleLanguages", "(ja)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["公式まどを準備しています"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["official-window-subscribe"].exists)
        capture("official-window-preparing", app)
    }

    @MainActor
    func testWidgetPhotoOpensBeforeRefreshAndClosesInOneStep() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--official-window-ui-fixture", "--official-window-linked-photo", "-AppleLanguages", "(ja)"]
        app.launch()
        let launcher = app.buttons["official-window-fixture-launch"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 10))
        launcher.tap()
        let failRefresh = app.buttons["確認用：通信を失敗させる"]
        XCTAssertTrue(failRefresh.waitForExistence(timeout: 5))
        // The refresh cannot finish until this test permits it. The old
        // overview -> refresh -> second sheet flow fails these assertions.
        XCTAssertTrue(app.navigationBars["確認用の猫"].exists)
        XCTAssertFalse(app.navigationBars["どこかの猫"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["official-window-image-loaded"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "閉じる").count, 1)
        capture("official-widget-direct-photo-before-refresh", app)
        failRefresh.tap()
        XCTAssertTrue(app.buttons["確認用：通信失敗済み"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["確認用の猫"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["official-window-image-loaded"].firstMatch.exists)
        app.buttons["閉じる"].tap()
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertTrue(launcher.isHittable)
        XCTAssertFalse(app.navigationBars["どこかの猫"].exists)
    }

    @MainActor
    func testMissingWidgetPhotoDoesNotOpenAnotherPhoto() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--official-window-ui-fixture", "--official-window-linked-photo",
                               "--official-window-missing-photo", "-AppleLanguages", "(ja)"]
        app.launch()
        let launcher = app.buttons["official-window-fixture-launch"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 10))
        launcher.tap()
        let failRefresh = app.buttons["確認用：通信を失敗させる"]
        XCTAssertTrue(failRefresh.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["確認用の猫"].exists)
        failRefresh.tap()
        let overview = app.buttons["official-window-show-overview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["official-window-image-loaded"].firstMatch.exists)
        capture("official-widget-unavailable-photo", app)
        overview.tap()
        XCTAssertTrue(app.navigationBars["どこかの猫"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["official-window-photo-fixture-photo"].exists)
    }

    @MainActor
    func testFullscreenOfficialPhotoStopsAtItsDisplayDeadline() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--official-window-ui-fixture", "--window-list-subscribed",
                               "--official-window-expiring-photo", "-AppleLanguages", "(ja)"]
        app.launch()
        let photo = app.buttons["official-window-photo-fixture-photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        let information = app.buttons["official-photo-information"]
        XCTAssertTrue(information.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["official-window-image-loaded"].firstMatch.exists)
        expectation(for: NSPredicate { _, _ in !information.exists }, evaluatedWith: app)
        waitForExpectations(timeout: 40)
        XCTAssertTrue(app.staticTexts["写真の掲載期間が終わりました"].exists)
        // The full-screen dismiss animates after the deadline. Wait for its
        // disappearing accessibility tree, while still requiring no photo.
        let loadedPhoto = app.descendants(matching: .any)["official-window-image-loaded"].firstMatch
        expectation(for: NSPredicate { _, _ in !loadedPhoto.exists }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        capture("official-photo-expired-while-open", app)
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The fixture substitutes only the action boundary and image source. These
/// are the shipping cat views; no real photo library or account is accessed.
final class CatProfilePhotoFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    @MainActor
    func testCreateBrowseAddRetryKeepOtherCatAndDelete() {
        let app = XCUIApplication()
        app.launchArguments = ["--cat-profile-photo-flow-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()

        createCat("テスト猫A", photoIndex: 0, app: app)
        XCTAssertEqual(visiblePhotos(app).count, 1)
        visiblePhotos(app)[0].tap()
        XCTAssertTrue(app.buttons["閉じる"].waitForExistence(timeout: 5))
        app.buttons["閉じる"].tap()
        backToCatList(app)

        createCat("テスト猫B", photoIndex: 1, app: app)
        app.buttons["cat-profile-add-photos"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "cat-profile-photo").firstMatch.waitForExistence(timeout: 5))
        guard let firstChoice = visiblePhotos(app).first else {
            XCTFail("No explicit photo choices appeared.")
            return
        }
        firstChoice.tap()
        let add = app.buttons["cat-profile-confirm-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.staticTexts["追加できませんでした。選択は残っています。もう一度お試しください。"].waitForExistence(timeout: 5))
        XCTAssertEqual(add.label, "1枚を追加", "A failed save lost the explicit selection.")
        add.tap()
        XCTAssertTrue(app.navigationBars["テスト猫Bの写真"].waitForExistence(timeout: 5))
        XCTAssertEqual(visiblePhotos(app).count, 2)
        capture("multi-cat-photo-page", app: app)
        backToCatList(app)

        app.buttons.matching(identifier: "cat-profile-open").element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["テスト猫Aの写真"].waitForExistence(timeout: 5))
        XCTAssertEqual(visiblePhotos(app).count, 1, "Adding to B removed A's photo.")
        backToCatList(app)
        app.buttons.matching(identifier: "cat-profile-open").element(boundBy: 1).tap()
        app.buttons["cat-profile-settings"].tap()
        let delete = app.buttons["プロフィールを削除"]
        for _ in 0..<4 {
            if delete.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(delete.isHittable)
        delete.tap()
        XCTAssertTrue(app.staticTexts["テスト猫Bのプロフィールを削除しますか？"].waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(app.navigationBars["猫ごとの写真"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "cat-profile-open").count, 1)
        capture("multi-cat-after-delete", app: app)

        app.buttons["cat-profile-add"].tap()
        XCTAssertTrue(app.buttons["キャンセル"].waitForExistence(timeout: 5))
        app.buttons["キャンセル"].tap()
        XCTAssertTrue(app.navigationBars["猫ごとの写真"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "cat-profile-open").count, 1)
    }

    @MainActor
    private func createCat(_ name: String, photoIndex: Int, app: XCUIApplication) {
        XCTAssertTrue(app.buttons["cat-profile-add"].waitForExistence(timeout: 10))
        app.buttons["cat-profile-add"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "cat-profile-photo").firstMatch.waitForExistence(timeout: 5))
        let choices = visiblePhotos(app)
        guard choices.indices.contains(photoIndex) else {
            XCTFail("The generated photo picker did not expose its expected choices.")
            return
        }
        choices[photoIndex].tap()
        let field = app.textFields["cat-profile-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["cat-profile-key-photo"].label.contains("別の写真を選ぶ"),
                      "The selected photo was lost between the picker and naming sheet.")
        field.tap()
        field.typeText(name)
        app.buttons["cat-profile-create"].tap()
        XCTAssertTrue(app.navigationBars["\(name)の写真"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func visiblePhotos(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(identifier: "cat-profile-photo").allElementsBoundByIndex.filter(\.isHittable)
    }

    @MainActor
    private func backToCatList(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["猫ごとの写真"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

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
                if scenario == "one" {
                    captureMainlineScreen("widget-guide")
                }
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
    func testPhotosOpenEachCatsPhotosDirectlyAndKeepManagementInSettings() {
        for largeText in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--app-store-screenshot-fixture",
                                   "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            if largeText { app.launchArguments.append("--ux-large-text") }
            app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "cats"
            app.launch()
            XCTAssertTrue(app.buttons["photo-hub-cat-profiles"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["photo-hub-source-recovery"].exists)
            XCTAssertFalse(app.staticTexts["写真の対象と整理"].exists)
            capture(largeText ? "photo-hub-cats-largest-text" : "photo-hub-cats")
            for (index, name) in ["ミケ", "ソラ"].enumerated() {
                let shortcut = app.buttons["photo-hub-cat-fixture-cat-\(index)"]
                XCTAssertTrue(shortcut.isHittable)
                shortcut.tap()
                XCTAssertTrue(app.navigationBars["\(name)の写真"].waitForExistence(timeout: 5))
                let photos = app.buttons.matching(identifier: "cat-profile-photo")
                XCTAssertEqual(photos.count, 1, "The shortcut must retain the selected cat")
                XCTAssertTrue(app.buttons["cat-profile-add-photos"].isHittable)
                XCTAssertTrue(app.buttons["cat-profile-settings"].isHittable)
                if index == 0 {
                    capture(largeText ? "cat-photo-page-largest-text" : "cat-photo-page")
                    photos.firstMatch.tap()
                    XCTAssertTrue(app.images["photo-detail-zoom-surface"].waitForExistence(timeout: 10))
                    app.buttons["閉じる"].tap()
                }
                app.navigationBars["\(name)の写真"].buttons.element(boundBy: 0).tap()
                XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
            }
            if !largeText {
                app.buttons["window-settings-button"].tap()
                let photoSettings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "写真の表示と整理")).firstMatch
                XCTAssertTrue(photoSettings.waitForExistence(timeout: 5))
                photoSettings.tap()
                let curation = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "対象と除外")).firstMatch
                for _ in 0..<5 where !curation.isHittable { app.swipeUp() }
                XCTAssertTrue(curation.isHittable)
                curation.tap()
                XCTAssertTrue(app.navigationBars["写真の整理"].waitForExistence(timeout: 5))
            }
            app.terminate()
        }
    }

    @MainActor
    func testPhotosStayUsableWithoutCatRegistrationAndOfferSourceRecoveryOnlyWhenNeeded() {
        for scenario in ["no-cats", "source-unavailable"] {
            let app = XCUIApplication()
            app.launchArguments = ["--app-store-screenshot-fixture", "-AppleLanguages", "(ja)"]
            app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = scenario
            app.launch()
            XCTAssertTrue(app.buttons["photo-hub-cat-profiles"].waitForExistence(timeout: 15))
            let recovery = app.buttons["photo-hub-source-recovery"]
            if scenario == "source-unavailable" {
                XCTAssertTrue(recovery.isHittable)
                capture("photo-source-recovery")
                recovery.tap()
                XCTAssertTrue(app.navigationBars["写真の整理"].waitForExistence(timeout: 5))
            } else {
                XCTAssertFalse(recovery.exists)
                let photo = app.buttons["photo-hub-photo-app-store-screenshot-fixture-1"]
                for _ in 0..<6 where !photo.isHittable { app.swipeUp() }
                XCTAssertTrue(photo.isHittable)
                photo.tap()
                XCTAssertTrue(app.images["photo-detail-zoom-surface"].waitForExistence(timeout: 10))
            }
            app.terminate()
        }
    }

    @MainActor
    func testWindowSettingsPrioritizeDisplayAndKeepSafetyReachable() {
        for largeText in [false, true] {
            var arguments = ["--family-window-settings-fixture"]
            if largeText { arguments.append("--family-window-settings-large-text") }
            let app = launch("family-settings", arguments: arguments)
            // This fixture contains one shipping settings ScrollView. Keep
            // gestures inside it instead of swiping the application window.
            let settings = app.scrollViews.firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            let widget = app.buttons["family-window-widget-guide"]
            XCTAssertTrue(widget.waitForExistence(timeout: 10))
            XCTAssertTrue(widget.isHittable)
            if largeText { capture("window-settings-largest-text-before-scroll") }
            let notification = app.buttons["family-window-notification-open-settings"]
            for _ in 0..<5 where !notification.isHittable { settings.swipeUp() }
            XCTAssertTrue(notification.isHittable)
            XCTAssertGreaterThanOrEqual(notification.frame.height + 0.001, 44)
            capture(largeText ? "window-settings-largest-text" : "window-settings")
            let management = app.buttons["family-window-sharing-settings"]
            for _ in 0..<5 where !management.isHittable { settings.swipeUp() }
            XCTAssertTrue(management.isHittable)
            let privacy = app.buttons.matching(identifier: "family-window-privacy-details").firstMatch
            for _ in 0..<5 where !privacy.isHittable { settings.swipeUp() }
            XCTAssertTrue(privacy.isHittable)
            privacy.tap()
            capture(largeText ? "window-settings-safety-largest-text" : "window-settings-safety")
            app.terminate()
        }
    }

    @MainActor
    func testLocalPhotoFailureCanReloadTheSamePhoto() {
        let app = launch("rediscovery", arguments: ["--photo-load-fails-once"])
        let retry = app.buttons["local-photo-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertEqual(retry.label, "写真をもう一度読み込む")
        XCTAssertTrue(retry.isHittable)
        // AX converts point frames to floating values (44 can be 43.99999999999994).
        XCTAssertGreaterThanOrEqual(retry.frame.height + 0.001, 44)
        capture("local-photo-load-failed")
        retry.tap()
        let image = app.images["photo-detail-zoom-surface"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        XCTAssertTrue(image.isHittable)
        XCTAssertFalse(retry.exists)
        app.buttons["思い出に残す"].tap()
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "app-store-screenshot-fixture-1|true"),
            object: app.staticTexts["solo-rediscovery-memory-request"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
        capture("local-photo-reloaded-same-id")
        app.terminate()
    }

    @MainActor
    func testPartialPhotoRetryPreservesZoomAndVisibleRegion() {
        let app = launch("rediscovery", arguments: ["--photo-load-preview-then-fail"])
        let retry = app.buttons["local-photo-retry"]
        let photo = app.images["photo-detail-zoom-surface"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertTrue(photo.exists, "A failed final request keeps its usable preview")
        func metric(_ name: String) -> Double {
            let prefix = name + "="
            return (photo.value as? String ?? "").split(separator: ";")
                .first(where: { $0.hasPrefix(prefix) })
                .flatMap { Double($0.dropFirst(prefix.count)) } ?? -1
        }
        XCTAssertEqual(metric("pixels"), 120)
        XCTAssertGreaterThanOrEqual(retry.frame.height + 0.001, 44)
        photo.doubleTap()
        expectation(for: NSPredicate { _, _ in metric("zoom") > 1.1 }, evaluatedWith: photo)
        waitForExpectations(timeout: 5)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.4))
            .press(forDuration: 0.1, thenDragTo:
                photo.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)))
        let previousZoom = metric("zoom")
        let previousX = metric("offsetX")
        let previousY = metric("offsetY")
        capture("local-photo-preview-failed-zoomed")
        retry.tap()
        expectation(for: NSPredicate { _, _ in metric("pixels") >= 1_000 }, evaluatedWith: photo)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(retry.exists)
        XCTAssertEqual(metric("zoom"), previousZoom, accuracy: 0.01)
        XCTAssertEqual(metric("offsetX"), previousX, accuracy: 1)
        XCTAssertEqual(metric("offsetY"), previousY, accuracy: 1)
        XCTAssertTrue(app.buttons["思い出に残す"].isHittable)
        capture("local-photo-quality-recovered-same-viewport")
        app.buttons["思い出に残す"].tap()
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "app-store-screenshot-fixture-1|true"),
            object: app.staticTexts["solo-rediscovery-memory-request"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
        app.terminate()
    }

    @MainActor
    func testWidgetPhotoOutsideCurrentScopeOffersAPathBack() {
        for scenario in ["excluded", "scoped", "available"] {
            let app = XCUIApplication()
            app.launchArguments = ["--app-store-screenshot-fixture",
                                   "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = scenario
            app.launch()
            if scenario == "available" {
                let photo = app.images["photo-detail-zoom-surface"]
                XCTAssertTrue(photo.waitForExistence(timeout: 15))
                XCTAssertTrue(photo.isHittable)
                XCTAssertTrue((app.buttons["photo-browser-same-day"].value as? String ?? "")
                    .contains("2025年12月18日"))
                XCTAssertFalse(app.buttons["unavailable-widget-open-photos"].exists)
            } else {
                let openPhotos = app.buttons["unavailable-widget-open-photos"]
                XCTAssertTrue(openPhotos.waitForExistence(timeout: 15))
                XCTAssertTrue(openPhotos.isHittable)
                XCTAssertFalse(app.images["photo-detail-zoom-surface"].exists,
                               "A rejected Widget link must never substitute another photo")
                if scenario == "excluded" { capture("widget-photo-unavailable-return") }
                openPhotos.tap()
                let gridPhoto = app.buttons["photo-hub-photo-app-store-screenshot-fixture-2"]
                XCTAssertTrue(gridPhoto.waitForExistence(timeout: 10))
                XCTAssertFalse(openPhotos.exists)
            }
            app.terminate()
        }
    }

    @MainActor
    func testPhotoGridRevealsFollowingBatchesAndKeepsReturnPosition() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-screenshot-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "paging"
        app.launch()
        let grid = element("photo-hub-detected-grid", in: app)
        XCTAssertTrue(grid.waitForExistence(timeout: 15))
        for number in [25, 49] {
            let target = app.buttons["photo-hub-photo-app-store-screenshot-fixture-page-\(number)"]
            for _ in 0..<14 where !target.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(target.isHittable, "Scrolling alone reaches photo \(number)")
            XCTAssertEqual(app.buttons.matching(identifier: target.identifier).count, 1)
            target.tap()
            XCTAssertTrue(app.staticTexts["\(number) / 50"].waitForExistence(timeout: 10))
            app.navigationBars["写真"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(target.waitForExistence(timeout: 10))
            XCTAssertTrue(target.isHittable, "Returning preserves the opened row")
        }
        XCTAssertFalse(app.buttons["もっと見る"].exists)
        capture("photo-grid-scrolled-to-last-batch")
        app.terminate()
    }

    @MainActor
    func testMonthlySaveUsesConfirmedStateAndCanBeRemoved() {
        for scenario in ["monthly-save", "monthly-save-unconfirmed"] {
            let app = XCUIApplication()
            app.launchArguments = ["--app-store-screenshot-fixture", "--photo-load-fails-once",
                                   "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] = scenario
            app.launch()
            let retry = app.buttons["local-photo-retry"]
            XCTAssertTrue(retry.waitForExistence(timeout: 15))
            XCTAssertTrue(retry.isHittable, "The letter decoration must not cover retry")
            retry.tap()
            let save = app.buttons["monthly-window-memory-app-store-screenshot-fixture-1"]
            XCTAssertTrue(save.waitForExistence(timeout: 10))
            XCTAssertEqual(save.label, "思い出に残す")
            save.tap()
            let request = app.staticTexts["monthly-fixture-memory-request"]
            let requested = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", "app-store-screenshot-fixture-1|true"),
                object: request
            )
            XCTAssertEqual(XCTWaiter.wait(for: [requested], timeout: 5), .completed)
            if scenario == "monthly-save-unconfirmed" {
                XCTAssertEqual(save.label, "思い出に残す", "A request alone is not a saved result")
            } else {
                let saved = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label == %@", "思い出に残した"), object: save
                )
                XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
                save.tap()
                app.buttons["思い出から外す"].tap()
                let removed = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label == %@", "app-store-screenshot-fixture-1|false"),
                    object: request
                )
                XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
                XCTAssertEqual(save.label, "思い出に残す")
                XCTAssertEqual(app.alerts.count, 0)
                save.tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label == %@", "思い出に残した"), object: save
                )], timeout: 5), .completed)
                capture("monthly-memory-resaved")
            }
            app.terminate()
        }
    }

    @MainActor
    func testSameDayRediscoveryOpensAndSavesTheTappedPhoto() {
        let app = launch("rediscovery")
        let sameDay = app.buttons["この日の写真をすべて見る"]
        XCTAssertTrue(sameDay.waitForExistence(timeout: 15))
        for _ in 0..<3 where !sameDay.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(sameDay.isHittable)
        sameDay.tap()

        let firstPhoto = app.buttons["day-photos-photo-app-store-screenshot-fixture-1"]
        let secondPhoto = app.buttons["day-photos-photo-app-store-screenshot-fixture-2"]
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
        XCTAssertTrue(secondPhoto.isHittable)
        XCTAssertTrue(app.staticTexts["mainline-loaded-2"].waitForExistence(timeout: 15))
        secondPhoto.tap()
        XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["photo-browser-same-day"].exists,
                       "A photo opened in this day's collection must not push the same collection again")

        let save = app.buttons["思い出に残す"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        for _ in 0..<3 where !save.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(save.isHittable)
        save.tap()
        let requested = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "app-store-screenshot-fixture-2|true"),
            object: app.staticTexts["solo-rediscovery-memory-request"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [requested], timeout: 10), .completed)
        XCTAssertTrue(element("photo-browser-memory-saved-state", in: app).waitForExistence(timeout: 10))
        capture("solo-rediscovery-same-day-second-photo-saved")

        app.buttons["photo-browser-memory-saved-state"].tap()
        app.buttons["思い出から外す"].tap()
        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "app-store-screenshot-fixture-2|false"),
            object: app.staticTexts["solo-rediscovery-memory-request"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        XCTAssertEqual(app.alerts.count, 0)
        app.buttons["思い出に残す"].tap()
        XCTAssertTrue(element("photo-browser-memory-saved-state", in: app).waitForExistence(timeout: 5))

        let backToDay = app.navigationBars["写真"].buttons.element(boundBy: 0)
        XCTAssertTrue(backToDay.isHittable)
        XCTAssertNotEqual(backToDay.label, "写真メニュー")
        backToDay.tap()
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
        XCTAssertTrue(firstPhoto.isHittable)
        XCTAssertTrue(secondPhoto.isHittable)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                        "day-photos-photo-")).count, 2)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(sameDay.waitForExistence(timeout: 5))
        // The entry browser contains only the first photo; the same-day
        // collection contains two. Only its second photo was saved above.
        XCTAssertTrue(app.buttons["思い出に残す"].isHittable,
                      "Two back actions return to the original, unsaved photo")
        XCTAssertFalse(element("photo-browser-memory-saved-state", in: app).exists)
        app.terminate()
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
    private func launch(_ scenario: String, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-screenshot-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"] + arguments
        app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] =
            ["family-settings", "monthly-save", "monthly-save-unconfirmed"].contains(scenario)
                ? scenario : "solo-memories-\(scenario)"
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
            let zoom = app.images.matching(identifier: "photo-detail-zoom-surface")
            expectation(for: NSPredicate { _, _ in zoom.allElementsBoundByIndex.contains { $0.isHittable } }, evaluatedWith: app)
            waitForExpectations(timeout: 10)
            guard let visiblePhoto = zoom.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
                XCTFail("The visible photo must expose its zoom surface")
                return
            }
            func photoZoom() -> Double {
                let value = visiblePhoto.value as? String ?? ""
                let part = value.split(separator: ";").first { $0.hasPrefix("zoom=") }
                return part.flatMap { Double($0.dropFirst(5)) } ?? 0
            }
            XCTAssertEqual(photoZoom(), 1, accuracy: 0.05)
            XCTAssertGreaterThan(visiblePhoto.frame.height, app.frame.height * 0.55)
            XCTAssertGreaterThanOrEqual(deliver.frame.height, 44)
            XCTAssertGreaterThanOrEqual(app.buttons["思い出に残す"].frame.height, 44)
            attach(app, name: "photo-browser-compact-actions-\(variant)")
            visiblePhoto.doubleTap()
            expectation(for: NSPredicate { _, _ in photoZoom() > 1.1 }, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            visiblePhoto.swipeRight()
            XCTAssertTrue(app.staticTexts["2 / 2"].exists, "Panning a zoomed photo must not turn the page")
            attach(app, name: "photo-browser-zoomed-\(variant)")
            visiblePhoto.doubleTap()
            expectation(for: NSPredicate { _, _ in abs(photoZoom() - 1) < 0.05 }, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            if variant == "standard" {
                visiblePhoto.pinch(withScale: 1.7, velocity: 1)
                expectation(for: NSPredicate { _, _ in photoZoom() > 1.1 }, evaluatedWith: app)
                waitForExpectations(timeout: 5)
                visiblePhoto.doubleTap()
                expectation(for: NSPredicate { _, _ in abs(photoZoom() - 1) < 0.05 }, evaluatedWith: app)
                waitForExpectations(timeout: 5)
            }
            end.press(forDuration: 0.05, thenDragTo: start)
            XCTAssertTrue(app.staticTexts["1 / 2"].waitForExistence(timeout: 5), "Paging resumes after returning to fit size")
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
            let actions = app.buttons["family-window-save-memory"].firstMatch
            XCTAssertGreaterThanOrEqual(actions.frame.minY, latest.frame.maxY)
            actions.tap()
            XCTAssertEqual(app.staticTexts["received-fixture-action-request"].label, "save|0",
                           "The cropped photo must not intercept adjacent controls.")
            let cancel = app.buttons["received-fixture-cancel-action"]
            for _ in 0..<4 where !cancel.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(cancel.isHittable)
            cancel.tap()
            for _ in 0..<4 where !latest.isHittable { app.scrollViews.firstMatch.swipeDown() }
            attach(app, name: "received-layout-\(variant)")
            latest.tap()
            XCTAssertFalse(app.staticTexts["received-fixture-action-request"].exists,
                           "Cancelling a fixture request must not leave debug rows in the photo footer.")
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
                tapReceivedDetailControl(app, identifier: action == "save"
                    ? "family-window-save-memory" : "family-window-send-paw")
                XCTAssertEqual(app.staticTexts["received-fixture-action-request"].label, "\(action)|0")
                tapReceivedDetailControl(app, identifier: "received-fixture-complete-action")
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
    func testReceivedProductControlsBindRequestsAndPendingStateToTheVisiblePhoto() {
        // This exercises the shipping controls with an explicit offline state
        // driver. It does not prove PhotoKit import, confirmation dialogs, or delivery.
        let app = XCUIApplication()
        app.launchArguments = ["--moment-received-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let latest = app.buttons["received-fixture-latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 15))
        latest.tap()
        let save = app.buttons["family-window-save-memory"].firstMatch
        let heart = app.buttons["family-window-send-paw"].firstMatch
        let saved = app.descendants(matching: .any)["family-window-saved-memory-state"].firstMatch
        let request = app.staticTexts["received-fixture-action-request"]

        tapReceivedDetailControl(app, identifier: "family-window-save-memory")
        XCTAssertFalse(latest.exists, "The full-screen fixture must hide the presenting list from accessibility.")
        XCTAssertEqual(app.staticTexts.matching(identifier: "received-fixture-action-request").count, 1,
                       "Only the visible photo may expose the recorded request.")
        XCTAssertEqual(request.label, "save|0")
        XCTAssertFalse(save.isEnabled)
        XCTAssertFalse(heart.isEnabled, "A pending action must prevent another request.")
        XCTAssertFalse(saved.exists, "Requesting a save alone must not display the saved state.")
        tapReceivedDetailControl(app, identifier: "received-fixture-complete-action")
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        tapReceivedDetailControl(app, identifier: "family-window-send-paw")
        XCTAssertEqual(request.label, "heart|0")
        XCTAssertFalse(heart.isEnabled)
        XCTAssertNotEqual(heart.label, "ハートを送信済みです")
        tapReceivedDetailControl(app, identifier: "received-fixture-complete-action")
        XCTAssertEqual(heart.label, "ハートを送信済みです")
        XCTAssertFalse(heart.isEnabled)
        closePhotoDetail(app)

        let second = app.buttons["received-fixture-tile-1"]
        for _ in 0..<6 where !second.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(second.isHittable)
        second.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(saved.exists, "Another photo must not inherit the saved state.")
        XCTAssertEqual(save.label, "取り込んで残す")
        XCTAssertEqual(heart.label, "写真を届けた相手にハートを送る")
        XCTAssertTrue(heart.isEnabled)
        tapReceivedDetailControl(app, identifier: "family-window-save-memory")
        XCTAssertEqual(request.label, "save|1", "The callback must name the currently displayed photo.")
        tapReceivedDetailControl(app, identifier: "received-fixture-complete-action")
        tapReceivedDetailControl(app, identifier: "思い出の操作")
        let remove = app.buttons["思い出から外す"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertEqual(request.label, "remove|1")
        tapReceivedDetailControl(app, identifier: "received-fixture-complete-action")
        XCTAssertFalse(saved.exists)
        XCTAssertEqual(save.label, "もう一度思い出に加える",
                       "Removing the saved state must retain the already-imported distinction.")
        closePhotoDetail(app)
        for _ in 0..<6 where !latest.isHittable { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(latest.isHittable)
        latest.tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertEqual(heart.label, "ハートを送信済みです",
                       "Changing photo 1 must not change photo 0's reaction.")
        attach(app, name: "received-product-controls-offline-state")
    }

    @MainActor
    private func tapReceivedDetailControl(_ app: XCUIApplication, identifier: String) {
        let control = app.buttons[identifier].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        let footer = app.scrollViews["photo-detail-actions-scroll"]
        for _ in 0..<6 where !control.isHittable && footer.exists {
            if control.frame.minY < footer.frame.minY { footer.swipeDown() }
            else { footer.swipeUp() }
        }
        XCTAssertTrue(control.isHittable)
        XCTAssertGreaterThanOrEqual(control.frame.height + 0.001, 44,
                                    "The action must retain a 44-point target, allowing only floating-point rounding.")
        control.tap()
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
