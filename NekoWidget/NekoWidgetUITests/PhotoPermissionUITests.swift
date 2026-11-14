import XCTest

/// Settings has one door since 10/22: the gear on the この子 tab (was ツール).
@MainActor
fileprivate func openSettings(in app: XCUIApplication) {
    let tools = app.buttons["main-tab-tools"]
    if tools.waitForExistence(timeout: 10) { tools.tap() } else { app.tabBars.buttons["この子"].tap() }
    let gear = app.buttons["tools-settings-button"]
    XCTAssertTrue(gear.waitForExistence(timeout: 10))
    // 11/13: 設定 scrolls with the page; back to the top first.
    for _ in 0..<8 where !gear.isHittable { app.swipeDown() }
    gear.tap()
}

/// The 保存 row sits directly in Settings since 10/31; bring it into view.
/// 11/7: one row, 自動保存 (holding the profile file) or, without it, the file.
@MainActor
fileprivate func revealSaveSection(_ app: XCUIApplication) {
    let transfer = app.buttons["settings-cat-profile-transfer"]
    let autoSave = app.buttons["settings-managed-preservation"]
    for _ in 0..<4 where !((transfer.exists && transfer.isHittable) || (autoSave.exists && autoSave.isHittable)) {
        app.swipeUp()
    }
}

final class OfficialWindowUITests: XCTestCase {
    private var holdsSlowLaunchAssertion = false
    private var heldSlowLaunchIssue: XCTIssue?

    /// A hosted Simulator still settling Xcode's install can take longer than
    /// XCTest's fixed 30 s to grant the background assertion for a process that
    /// is already starting (11/9, run 42507589058: the app drew its screen and
    /// the Photos prompt, and the launch was still reported as failed). Only
    /// that one issue, only during the movie diagnostic's launch, is held. It
    /// is recorded unchanged unless the same app then reaches the foreground,
    /// and tearDown records it if the test stops before that is decided.
    override func record(_ issue: XCTIssue) {
        if holdsSlowLaunchAssertion, heldSlowLaunchIssue == nil,
           issue.compactDescription.contains("Timed out while acquiring background assertion") {
            heldSlowLaunchIssue = issue
            return
        }
        super.record(issue)
    }

    override func tearDown() {
        holdsSlowLaunchAssertion = false
        if let issue = heldSlowLaunchIssue {
            heldSlowLaunchIssue = nil
            super.record(issue)
        }
        super.tearDown()
    }

    /// Launches once. Not a relaunch: the diagnostic keeps exactly one run of
    /// the app, so its single receipt directory stays the evidence.
    @MainActor
    private func launchWaitingForSlowAssertion(_ app: XCUIApplication) -> Bool {
        holdsSlowLaunchAssertion = true
        app.launch()
        holdsSlowLaunchAssertion = false
        guard let issue = heldSlowLaunchIssue else { return true }
        heldSlowLaunchIssue = nil
        guard app.wait(for: .runningForeground, timeout: 60) else {
            super.record(issue)
            return false
        }
        let note = XCTAttachment(string: "Launch reported: \(issue.compactDescription) "
            + "The same app then reached the foreground; every later check is unchanged.")
        note.name = "movie-launch-slow-assertion"
        note.lifetime = .keepAlways
        add(note)
        return true
    }

    @MainActor
    func testSyntheticMovieShippingExportsSoundOnAndOff() throws {
        guard ProcessInfo.processInfo.environment["NEKO_MOVIE_SYNTHETIC_DIAGNOSTIC"] == "true" else {
            throw XCTSkip("Run only through the pinned synthetic movie diagnostic preparation.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-screenshot-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] = "movie"
        app.launchEnvironment["NEKO_MOVIE_SYNTHETIC_FIXTURE_DIR"] = "@app-tmp/movie-synthetic-inputs"
        app.launchEnvironment["NEKO_MOVIE_BUILD_SHA"] = ProcessInfo.processInfo.environment["NEKO_MOVIE_BUILD_SHA"] ?? "not supplied"
        let fullAccessLabels = ["Allow Full Access", "Allow Access to All Photos",
                                "フルアクセスを許可", "すべての写真へのアクセスを許可"]
        let acceptFullPhotosAccess: (XCUIElement) -> Bool = { alert in
            guard alert.staticTexts.allElementsBoundByIndex.contains(where: {
                $0.label.localizedCaseInsensitiveContains("photos") || $0.label.contains("写真")
            }), let button = fullAccessLabels.map({ alert.buttons[$0] }).first(where: { $0.exists }) else {
                return false
            }
            button.tap()
            return true
        }
        let photosMonitor = addUIInterruptionMonitor(withDescription: "Synthetic movie Photos authorization",
            handler: acceptFullPhotosAccess)
        defer { removeUIInterruptionMonitor(photosMonitor); app.terminate() }
        guard launchWaitingForSlowAssertion(app) else { return }
        let ready = app.staticTexts["mainline-movie-ready"]
        let deadline = Date().addingTimeInterval(180)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        while !ready.exists && Date() < deadline {
            if app.staticTexts["mainline-movie-failed"].exists { break }
            // Only this explicit synthetic fixture creates and deletes Photos.
            let alert = springboard.alerts.firstMatch
            // Polling alone need not trigger an interruption monitor. Handle
            // only the same positively identified full Photos-access buttons.
            if alert.exists { _ = acceptFullPhotosAccess(alert) }
            for label in ["削除", "Delete"] where alert.exists && alert.buttons[label].exists {
                alert.buttons[label].tap()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        evidence.name = "movie-synthetic-on-off"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertTrue(ready.exists, "Shipping ON/OFF export, input validation or synthetic cleanup failed.")
    }

    /// These tests send an actual URL event into the production presentation
    /// host. Source resolution and pixels stay offline; they do not establish
    /// live PhotoKit authorization, private binding validity, or WidgetKit tap
    /// timing before iOS delivers the URL to the app.
    @MainActor
    func testWidgetURLsColdOpenPhotoBeforeSourceResolvesAndCloseOnce() {
        continueAfterFailure = false
        for route in widgetPhotoRoutes() {
            let app = widgetPhotoApplication()
            app.launch()
            XCTAssertTrue(app.buttons["widget-photo-fixture-home"].waitForExistence(timeout: 10))
            app.terminate()
            XCTAssertEqual(app.state, .notRunning)
            app.open(route.url)
            assertWidgetPhotoOpening(route, in: app)
            capture("widget-url-cold-loading-\(route.name)", app)
            resolveWidgetPhoto(in: app)
            capture("widget-url-cold-\(route.name)", app)
            closeWidgetPhotoOnce(in: app)
            app.terminate()
        }
    }

    @MainActor
    func testWidgetURLPersonalPhotoOpensRelatedAlbumAndReturnsToOriginal() throws {
        func foreground(_ query: XCUIElementQuery, timeout: TimeInterval = 5,
                        file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                query.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.count == 1
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: timeout), .completed,
                           "Expected exactly one foreground element", file: file, line: line)
            let matches = query.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            return try XCTUnwrap(matches.count == 1 ? matches.first : nil,
                                 "Foreground element changed before use", file: file, line: line)
        }

        continueAfterFailure = false
        let app = widgetPhotoApplication()
        app.launch()
        XCTAssertTrue(app.buttons["widget-photo-fixture-home"].waitForExistence(timeout: 10))
        let route = widgetPhotoRoutes()[0]
        openWidgetURLInActiveApp(route.url, app: app, process: widgetFixtureProcess(in: app))
        assertWidgetPhotoOpening(route, in: app)
        resolveWidgetPhoto(in: app)

        // The URL host calls the same direct destination as AppRootView; it
        // must work without MainTabView.body's environment or navigation path.
        let sameDay = app.descendants(matching: .any).matching(identifier: "photo-browser-date")
        let originalDate = try XCTUnwrap(try foreground(sameDay).value as? String)
        // 10/19: 「関連する写真」 is a submenu of the photo's 「…」 menu.
        let more = app.buttons.matching(identifier: "photo-browser-related")
        try foreground(more).tap()
        try foreground(app.buttons.matching(NSPredicate(format: "label == %@", "関連する写真"))).tap()
        try foreground(app.buttons.matching(identifier: "photo-related-year-calendar_year_2025")).tap()
        let closeRelated = app.buttons.matching(identifier: "photo-related-close")
        _ = try foreground(closeRelated)
        // SwiftUI NavigationLink may expose a Link or another element type,
        // rather than Button. Match the stable tile identity while retaining
        // the exact-one foreground/hittable requirement used for this sheet.
        try foreground(app.descendants(matching: .any).matching(
            identifier: "curated-album-photo-calendar_year_2025-app-store-screenshot-fixture-3"
        )).tap()
        _ = try foreground(app.images.matching(identifier: "photo-detail-zoom-surface"))
        let relatedDate = try XCTUnwrap(try foreground(sameDay).value as? String)
        XCTAssertNotEqual(relatedDate, originalDate, "The related album must open the selected different photo")
        capture("widget-url-personal-related-photo", app)

        try foreground(closeRelated).tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            closeRelated.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        XCTAssertEqual(try foreground(sameDay).value as? String, originalDate,
                       "Closing related photos must retain the original Widget photo")
        _ = try foreground(app.images.matching(identifier: "photo-detail-zoom-surface"))
        XCTAssertEqual(try foreground(app.staticTexts.matching(identifier: "widget-photo-fixture-route")).label,
                       route.key)
        _ = try foreground(more)
        capture("widget-url-personal-related-return", app)
        closeWidgetPhotoOnce(in: app)
    }

    @MainActor
    func testWidgetURLsActiveAppReplacesPhotosAndRestoresPresentations() {
        continueAfterFailure = false
        let app = widgetPhotoApplication()
        app.launch()
        XCTAssertTrue(app.buttons["widget-photo-fixture-list"].waitForExistence(timeout: 10))
        let process = widgetFixtureProcess(in: app)
        let routes = widgetPhotoRoutes()
        // Replace a destination while its lookup is still held, then replace
        // already displayed photos. Only the last selection may survive.
        openWidgetURLInActiveApp(routes[3].url, app: app, process: process)
        assertWidgetPhotoOpening(routes[3], in: app)
        for route in routes {
            openWidgetURLInActiveApp(route.url, app: app, process: process)
            assertWidgetPhotoOpening(route, in: app)
            resolveWidgetPhoto(in: app)
        }
        capture("widget-url-warm-last-photo", app)
        closeWidgetPhotoOnce(in: app)

        app.buttons["widget-photo-fixture-settings-open"].tap()
        let editSettings = app.buttons["widget-photo-fixture-settings-edit"]
        XCTAssertTrue(editSettings.waitForExistence(timeout: 5))
        editSettings.tap()
        XCTAssertEqual(app.staticTexts["widget-photo-fixture-settings-draft"].label, "変更回数：1")
        openWidgetURLInActiveApp(routes[1].url, app: app, process: process)
        assertWidgetPhotoOpening(routes[1], in: app)
        XCTAssertFalse(isWidgetElementHittable(editSettings), "The existing settings sheet must be covered while loading")
        resolveWidgetPhoto(in: app)
        XCTAssertFalse(isWidgetElementHittable(app.staticTexts["widget-photo-fixture-settings-draft"]))
        capture("widget-url-above-settings", app)
        app.buttons["widget-photo-close"].tap()
        XCTAssertTrue(editSettings.waitForExistence(timeout: 5))
        XCTAssertTrue(editSettings.isHittable)
        XCTAssertEqual(app.staticTexts["widget-photo-fixture-settings-draft"].label, "変更回数：1",
                       "One close must restore the same settings draft")
        capture("widget-url-restored-settings-draft", app)
        XCTAssertFalse(app.buttons["widget-photo-close"].exists)
        app.buttons["widget-photo-fixture-settings-close"].tap()
        XCTAssertTrue(app.buttons["widget-photo-fixture-home"].waitForExistence(timeout: 5))

        app.buttons["widget-photo-fixture-existing-open"].tap()
        let editExistingPhoto = app.buttons["widget-photo-fixture-existing-edit"]
        XCTAssertTrue(editExistingPhoto.waitForExistence(timeout: 5))
        editExistingPhoto.tap()
        XCTAssertEqual(app.staticTexts["widget-photo-fixture-existing-draft"].label, "変更回数：1")
        openWidgetURLInActiveApp(routes[0].url, app: app, process: process)
        assertWidgetPhotoOpening(routes[0], in: app)
        XCTAssertFalse(isWidgetElementHittable(editExistingPhoto),
                       "An existing full-screen photo must be covered while the Widget loads")
        resolveWidgetPhoto(in: app)
        XCTAssertFalse(isWidgetElementHittable(app.staticTexts["widget-photo-fixture-existing-draft"]))
        capture("widget-url-above-existing-fullscreen-photo", app)
        app.buttons["widget-photo-close"].tap()
        XCTAssertTrue(editExistingPhoto.waitForExistence(timeout: 5))
        XCTAssertTrue(editExistingPhoto.isHittable)
        XCTAssertEqual(app.staticTexts["widget-photo-fixture-existing-draft"].label, "変更回数：1",
                       "One close must restore the existing full-screen photo and its draft")
        capture("widget-url-restored-fullscreen-photo-draft", app)
        XCTAssertFalse(app.buttons["widget-photo-close"].exists)
        app.buttons["widget-photo-fixture-existing-close"].tap()
        XCTAssertTrue(app.buttons["widget-photo-fixture-home"].waitForExistence(timeout: 5))

        openWidgetURLInActiveApp(routes[3].url, app: app, process: process)
        assertWidgetPhotoOpening(routes[3], in: app)
        resolveWidgetPhoto(in: app)
        app.buttons["official-photo-information"].tap()
        let closeInformation = app.buttons["official-photo-information-close"]
        XCTAssertTrue(closeInformation.waitForExistence(timeout: 5))
        let windowURL = URL(string: "nekowidget://official-window")!
        openWidgetURLInActiveApp(windowURL, app: app, process: process)
        let fallback = app.staticTexts["widget-photo-fixture-other-url"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 5))
        XCTAssertEqual(fallback.label, windowURL.absoluteString)
        XCTAssertTrue(fallback.isHittable,
                      "A non-photo destination may present after the Widget photo dismisses")
        XCTAssertFalse(closeInformation.exists,
                       "The photo's child information sheet must dismiss with the Widget")
        XCTAssertFalse(app.buttons["widget-photo-close"].exists)
        XCTAssertEqual(visibleWidgetPhotos(in: app).count, 0)
        app.buttons["widget-photo-fixture-other-close"].tap()
        XCTAssertTrue(app.buttons["widget-photo-fixture-home"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testWidgetURLsMissingPhotoNeverSubstituteAvailableFixturePhoto() {
        continueAfterFailure = false
        let app = widgetPhotoApplication()
        app.launch()
        XCTAssertTrue(app.buttons["widget-photo-fixture-home"].waitForExistence(timeout: 10))
        let process = widgetFixtureProcess(in: app)
        for route in widgetPhotoRoutes(missing: true) {
            openWidgetURLInActiveApp(route.url, app: app, process: process)
            assertWidgetPhotoOpening(route, in: app)
            app.buttons["widget-photo-fixture-resolve"].tap()
            let unavailable = app.staticTexts.matching(NSPredicate(
                format: "label == %@ OR label == %@", "写真を表示できません", "この写真は表示できません"
            )).firstMatch
            XCTAssertTrue(unavailable.waitForExistence(timeout: 10), route.name)
            XCTAssertEqual(visibleWidgetPhotos(in: app).count, 0,
                           "Missing \(route.name) must not borrow the seeded valid photo")
            XCTAssertFalse(app.descendants(matching: .any)
                .matching(identifier: "official-window-image-loaded")
                .allElementsBoundByIndex.contains { $0.isHittable })
            assertWidgetBackgroundHidden(in: app)
            capture("widget-url-missing-\(route.name)", app)
            closeWidgetPhotoOnce(in: app)
        }
    }

    private struct WidgetPhotoTestRoute {
        let name: String
        let url: URL
        let key: String
    }

    private func widgetPhotoRoutes(missing: Bool = false) -> [WidgetPhotoTestRoute] {
        let localID = missing ? "unavailable-fixture-photo" : "app-store-screenshot-fixture-1"
        let photoID = missing ? "removed-photo" : "fixture-photo"
        let windowID = "11111111-1111-4111-8111-111111111111"
        let digest = String(repeating: missing ? "b" : "a", count: 64)
        return [
            WidgetPhotoTestRoute(name: "personal",
                url: URL(string: "nekowidget://photo?id=\(localID)&shownAt=2026-09-14T00:00:00Z")!,
                key: "personal|\(localID)"),
            WidgetPhotoTestRoute(name: "private",
                url: URL(string: "nekowidget://family-window?window=\(windowID)&source=\(digest)&action=view-photo")!,
                key: "family|\(windowID)|\(digest)"),
            WidgetPhotoTestRoute(name: "official",
                url: URL(string: "nekowidget://official-window?photo=\(photoID)")!,
                key: "official|official-cats|\(photoID)"),
            WidgetPhotoTestRoute(name: "public-channel",
                url: URL(string: "nekowidget://public-window?window=nap-cats&photo=\(photoID)")!,
                key: "official|nap-cats|\(photoID)")
        ]
    }

    @MainActor
    private func widgetPhotoApplication() -> XCUIApplication {
        let app = XCUIApplication()
        // The second flag reuses existing app/delegate service suppression.
        // The first selects the host fixture before the photo-window branch.
        app.launchArguments = ["--widget-photo-opening-ui-fixture", "--photo-window-ui-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        return app
    }

    @MainActor
    private func widgetFixtureProcess(in app: XCUIApplication) -> String {
        let labels = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "widget-photo-fixture-process-"
        ))
        XCTAssertTrue(labels.firstMatch.waitForExistence(timeout: 5))
        let identities = Set(labels.allElementsBoundByIndex.map(\.label))
        XCTAssertEqual(identities.count, 1,
                       "All retained fixture surfaces must belong to one process")
        return identities.first ?? ""
    }

    @MainActor
    private func openWidgetURLInActiveApp(_ url: URL, app: XCUIApplication, process: String) {
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(widgetFixtureProcess(in: app), process)
        // XCUIApplication.open launches a new app process. The device's
        // XCUISystem sends this URL to the already running default handler.
        XCUIDevice.shared.system.open(url)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertEqual(widgetFixtureProcess(in: app), process,
                       "Every active URL must preserve the original app process and its drafts")
    }

    @MainActor
    private func assertWidgetPhotoOpening(_ route: WidgetPhotoTestRoute, in app: XCUIApplication) {
        let selectedRoute = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "widget-photo-fixture-route", route.key
        )).firstMatch
        XCTAssertTrue(selectedRoute.waitForExistence(timeout: 10), route.name)
        let resolve = app.buttons["widget-photo-fixture-resolve"]
        XCTAssertTrue(resolve.waitForExistence(timeout: 5))
        XCTAssertTrue(resolve.isHittable)
        XCTAssertEqual(visibleWidgetPhotos(in: app).count, 0,
                       "The previous photo must disappear while the new selection loads")
        XCTAssertEqual(app.buttons.matching(identifier: "widget-photo-close").count, 1)
        assertWidgetBackgroundHidden(in: app)
    }

    @MainActor
    private func resolveWidgetPhoto(in app: XCUIApplication) {
        app.buttons["widget-photo-fixture-resolve"].tap()
        let photos = app.images.matching(identifier: "photo-detail-zoom-surface")
        let oneVisiblePhoto = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            photos.allElementsBoundByIndex.filter { $0.isHittable }.count == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [oneVisiblePhoto], timeout: 10), .completed,
                       "Exactly one photo must become visible after the selected route resolves")
        XCTAssertEqual(app.buttons.matching(identifier: "widget-photo-close").count, 1)
        assertWidgetBackgroundHidden(in: app)
    }

    // Native overFullScreen keeps covered views in the hierarchy: exists can
    // remain true. Check interaction/visible photos; loading screenshots also
    // verify that the opaque destination does not show background content.
    @MainActor
    private func visibleWidgetPhotos(in app: XCUIApplication) -> [XCUIElement] {
        app.images.matching(identifier: "photo-detail-zoom-surface")
            .allElementsBoundByIndex.filter { $0.isHittable }
    }

    @MainActor
    private func isWidgetElementHittable(_ element: XCUIElement) -> Bool {
        element.exists && element.isHittable
    }

    @MainActor
    private func assertWidgetBackgroundHidden(in app: XCUIApplication) {
        XCTAssertFalse(isWidgetElementHittable(app.buttons["widget-photo-fixture-home"]))
        XCTAssertFalse(isWidgetElementHittable(app.buttons["widget-photo-fixture-list"]))
        XCTAssertFalse(isWidgetElementHittable(app.navigationBars["確認用ホーム"]))
        XCTAssertFalse(isWidgetElementHittable(app.navigationBars["どこかの猫"]))
        XCTAssertFalse(isWidgetElementHittable(app.navigationBars["おひるね"]))
    }

    @MainActor
    private func closeWidgetPhotoOnce(in app: XCUIApplication) {
        app.buttons["widget-photo-close"].tap()
        let home = app.buttons["widget-photo-fixture-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(home.isHittable)
        XCTAssertTrue(app.buttons["widget-photo-fixture-list"].isHittable)
        XCTAssertFalse(app.buttons["widget-photo-close"].exists)
        XCTAssertEqual(visibleWidgetPhotos(in: app).count, 0)
        XCTAssertFalse(app.navigationBars["どこかの猫"].exists)
        XCTAssertFalse(app.navigationBars["おひるね"].exists)
    }

    @MainActor
    func testPhotoToCatWindowReceiveAndReturnKeepsOriginalPreview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--window-list-ui-fixture", "--window-list-cat-window", "-AppleLanguages", "(ja)"]
        app.launch()
        // 1.0: windows not yet received are listed under 「公式のまど」 on the まど tab itself.
        let original = app.buttons["official-window-entry"]
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["public-window-add-official-cats"].exists)
        original.tap()
        XCTAssertTrue(app.navigationBars["どこかの猫"].waitForExistence(timeout: 5),
                      "The chosen discovery card must open its own window")
        let photo = app.buttons["official-window-photo-fixture-photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        let catWindow = app.buttons["official-photo-cat-window"]
        XCTAssertTrue(catWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(catWindow.isHittable)
        capture("photo-to-cat-window", app)
        catWindow.tap()
        XCTAssertTrue(app.navigationBars["キジ白のまど"].waitForExistence(timeout: 5))
        let catOverview = app.scrollViews["public-window-overview-cat-tabby-nap"]
        let subscribe = catOverview.buttons["official-window-subscribe"]
        for _ in 0..<5 { if subscribe.isHittable { break }; catOverview.swipeUp() }
        subscribe.tap()
        let guide = catOverview.buttons["official-window-widget-guide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        for _ in 0..<5 { if guide.isHittable { break }; catOverview.swipeUp() }
        guide.tap()
        let source = app.descendants(matching: .any)["official-window-widget-source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(source.label.contains("キジ白のまど"))
        // 11/7: the same guide as 設定, with the window named in its last line.
        XCTAssertTrue(app.descendants(matching: .any)["widget-placement-steps"].firstMatch.exists)
        capture("cat-window-widget-guide", app)
        app.buttons["widget-placement-close"].tap()
        app.navigationBars["キジ白のまど"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(catWindow.waitForExistence(timeout: 5), "Back must return to the original photo")
        app.buttons["official-photo-close-official-cats"].tap()
        XCTAssertTrue(app.navigationBars["どこかの猫"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["public-window-overview-official-cats"].buttons["official-window-subscribe"].exists,
                      "Opening a cat must not subscribe to its discovery source")
        app.navigationBars["どこかの猫"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["まど"].waitForExistence(timeout: 5))
        let catEntry = app.buttons["public-window-entry-cat-tabby-nap"]
        XCTAssertTrue(catEntry.waitForExistence(timeout: 5))
        waitForWindowEntry("public-window-entry-cat-tabby-nap", value: "受け取り中", in: app)
        XCTAssertFalse(app.buttons["public-window-add-cat-tabby-nap"].exists,
                       "The received cat window moves out of discovery")
        // The original window stays in discovery, still offered with 「受け取る」.
        waitForWindowEntry("official-window-entry", value: "まだ受け取っていません", in: app)
        XCTAssertTrue(app.buttons["public-window-add-official-cats"].exists)
        capture("cat-window-receiving-list", app)
    }

    @MainActor
    func testCatWindowLargeTextKeepsPhotoEntryAndSeparateStop() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--window-list-ui-fixture", "--window-list-cat-window", "--window-list-subscribed",
                               "--window-list-largest-text", "-AppleLanguages", "(ja)"]
        app.launch()
        let original = app.buttons["official-window-entry"]
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        original.tap()
        app.buttons["official-window-photo-fixture-photo"].tap()
        let catWindow = app.buttons["official-photo-cat-window"]
        XCTAssertTrue(catWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(catWindow.isHittable)
        XCTAssertLessThan(catWindow.frame.maxY, app.frame.maxY - 20,
                          "The cat entry must remain above the home indicator without scrolling")
        capture("photo-to-cat-window-largest-text", app)
        catWindow.tap()
        let catOverview = app.scrollViews["public-window-overview-cat-tabby-nap"]
        let subscribe = catOverview.buttons["official-window-subscribe"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 5))
        for _ in 0..<5 { if subscribe.isHittable { break }; catOverview.swipeUp() }
        subscribe.tap()
        let photo = catOverview.buttons["official-window-photo-fixture-photo"]
        for _ in 0..<5 { if photo.isHittable { break }; catOverview.swipeDown() }
        photo.tap()
        let catDetail = app.descendants(matching: .any)["official-photo-detail-cat-tabby-nap"].firstMatch
        XCTAssertTrue(catDetail.waitForExistence(timeout: 5))
        XCTAssertFalse(catDetail.buttons["official-photo-cat-window"].exists,
                       "A cat photo must not link recursively to the same window")
        app.buttons["official-photo-close-cat-tabby-nap"].tap()
        stopReceiving(app, windowName: "キジ白のまど")
        app.navigationBars["キジ白のまど"].buttons.element(boundBy: 0).tap()
        app.buttons["official-photo-close-official-cats"].tap()
        XCTAssertTrue(app.navigationBars["どこかの猫"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.scrollViews["public-window-overview-official-cats"].buttons["official-window-subscribe"].exists,
                       "Stopping a cat must keep the original subscription")
    }

    @MainActor
    func testDiscoverNapWindowReceivesOnlyChosenWindow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--window-list-ui-fixture", "--window-list-two-public", "-AppleLanguages", "(ja)"]
        app.launch()
        // 1.0: both windows wait under 「公式のまど」 on the まど tab itself.
        let nap = app.buttons["public-window-entry-nap-cats"]
        XCTAssertTrue(nap.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["public-window-add-nap-cats"].exists)
        XCTAssertTrue(app.buttons["public-window-add-official-cats"].exists)
        for _ in 0..<3 { if nap.isHittable { break }; app.swipeUp() }
        capture("public-windows-discovery", app)
        nap.tap()
        XCTAssertTrue(app.navigationBars["おひるね"].waitForExistence(timeout: 5))
        let subscribe = app.buttons["official-window-subscribe"]
        for _ in 0..<5 { if subscribe.isHittable { break }; app.swipeUp() }
        subscribe.tap()
        let guide = app.buttons["official-window-widget-guide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        for _ in 0..<5 { if guide.isHittable { break }; app.swipeUp() }
        guide.tap()
        XCTAssertTrue(app.buttons["widget-placement-close"].waitForExistence(timeout: 5))
        let source = app.descendants(matching: .any)["official-window-widget-source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        for _ in 0..<3 { if source.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(source.isHittable)
        XCTAssertTrue(source.label.contains("おひるね"), "The guide must name the window just received")
        capture("nap-window-widget-guide", app)
        app.buttons["widget-placement-close"].tap()
        app.navigationBars["おひるね"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["まど"].waitForExistence(timeout: 5))
        XCTAssertTrue(nap.waitForExistence(timeout: 5))
        waitForWindowEntry("public-window-entry-nap-cats", value: "受け取り中", in: app)
        XCTAssertFalse(app.buttons["public-window-add-nap-cats"].exists)
        waitForWindowEntry("official-window-entry", value: "まだ受け取っていません", in: app)
        XCTAssertTrue(app.buttons["public-window-add-official-cats"].exists,
                      "Receiving a theme must not subscribe to the other window")
        capture("nap-window-receiving-list", app)
    }

    @MainActor
    func testTwoPublicWindowsKeepSamePhotoIDAndStopSeparate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--window-list-ui-fixture", "--window-list-two-public",
                               "--window-list-subscribed", "-AppleLanguages", "(ja)"]
        app.launch()
        let original = app.buttons["official-window-entry"]
        let second = app.buttons["public-window-entry-nap-cats"]
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
        XCTAssertTrue(app.navigationBars["おひるね"].waitForExistence(timeout: 5))
        app.buttons["official-window-photo-fixture-photo"].tap()
        XCTAssertTrue(app.navigationBars["おひるねの猫"].waitForExistence(timeout: 5))
        app.buttons["閉じる"].tap()
        stopReceiving(app, windowName: "おひるね")
        XCTAssertTrue(app.buttons["official-window-subscribe"].waitForExistence(timeout: 5))
        app.navigationBars["おひるね"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        // 1.0: a stopped window goes back to the 「公式のまど」 rows on the まど tab
        // (with 「受け取る」), not away from the tab (c8880b79 made the rows'
        // own identifiers visible). Only that window stopped; the other keeps receiving.
        waitForWindowEntry("public-window-entry-nap-cats", value: "まだ受け取っていません", in: app)
        XCTAssertTrue(app.buttons["public-window-add-nap-cats"].exists,
                      "Stopping one public window must remove only that receiving card")
        waitForWindowEntry("official-window-entry", value: "受け取り中", in: app)
        XCTAssertFalse(app.buttons["public-window-add-official-cats"].exists)
        original.tap()
        app.buttons["official-window-photo-fixture-photo"].tap()
        XCTAssertTrue(app.navigationBars["確認用の猫"].waitForExistence(timeout: 5),
                      "The same photo ID in another window must keep its own photo")
        capture("two-public-windows-original-after-stop", app)
    }

    @MainActor
    func testDiscoverReceiveGuideAndStopUpdatesWindowList() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments = ["--window-list-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        // 1.0: a window not yet received waits under 「公式のまど」 on the まど tab,
        // with its own 「受け取る」; there is no separate discovery screen.
        let entry = app.buttons["official-window-entry"]
        let add = app.buttons["public-window-add-official-cats"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isHittable, "The list itself must offer receiving")
        XCTAssertFalse(app.buttons["window-list-connect"].exists,
                       "A public-only configuration must not offer private connections")
        waitForWindowEntry("official-window-entry", value: "まだ受け取っていません", in: app)
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        XCTAssertTrue(app.navigationBars["どこかの猫"].waitForExistence(timeout: 5),
                      "The discovery row must open its window to look before receiving")
        XCTAssertTrue(app.tabBars.buttons["写真"].exists)
        XCTAssertTrue(app.tabBars.buttons["アルバム"].exists)
        for _ in 0..<5 { if app.buttons["official-window-subscribe"].isHittable { break }; app.swipeUp() }
        app.buttons["official-window-subscribe"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["official-window-subscription-confirmation"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["どこかの猫"].exists, "Receiving must not send the user back to the list")
        XCTAssertTrue(app.descendants(matching: .any)["official-window-image-unavailable"].firstMatch.waitForExistence(timeout: 10))
        pullToRefresh(app)
        XCTAssertTrue(app.descendants(matching: .any)["official-window-image-loaded"].firstMatch.waitForExistence(timeout: 10))
        let guide = app.buttons["official-window-widget-guide"]
        for _ in 0..<5 { if guide.isHittable { break }; app.swipeUp() }
        guide.tap()
        XCTAssertTrue(app.buttons["widget-placement-close"].waitForExistence(timeout: 5))
        // 11/7: one guide everywhere, no second 「初めて置く・すでに置いている」 guide.
        XCTAssertFalse(app.buttons["すでに置いている"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["official-window-widget-source"].firstMatch.exists)
        capture("window-widget-guide-existing", app)
        app.buttons["widget-placement-close"].tap()
        // The guide was offered once, after 「受け取る」; later it is in 設定 → ホーム画面.
        XCTAssertFalse(app.buttons["official-window-widget-guide"].exists)
        app.navigationBars["どこかの猫"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["まど"].waitForExistence(timeout: 5))
        waitForWindowEntry("official-window-entry", value: "受け取り中", in: app)
        XCTAssertFalse(add.exists, "A received window leaves 「公式のまど」")
        capture("window-list-after-receiving", app)
        entry.tap()
        stopReceiving(app)
        app.navigationBars["どこかの猫"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["まど"].waitForExistence(timeout: 5))
        waitForWindowEntry("official-window-entry", value: "まだ受け取っていません", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 5), "A stopped window returns to 「公式のまど」")
        capture("window-discovery-after-stop", app)
        // Receiving again from the list: the same confirmation and guide as in the window.
        for _ in 0..<3 where !add.isHittable { app.swipeUp(velocity: .slow) }
        add.tap()
        waitForWindowEntry("official-window-entry", value: "受け取り中", in: app)
        let listGuide = app.buttons["window-list-widget-guide"]
        XCTAssertTrue(listGuide.waitForExistence(timeout: 5), "「受け取る」 on the list must confirm the start")
        XCTAssertFalse(add.exists)
        listGuide.tap()
        XCTAssertTrue(app.buttons["widget-placement-close"].waitForExistence(timeout: 5))
        let listSource = app.descendants(matching: .any)["official-window-widget-source"].firstMatch
        XCTAssertTrue(listSource.waitForExistence(timeout: 5))
        XCTAssertTrue(listSource.label.contains("どこかの猫"), "The guide must name the window just received")
        capture("window-list-widget-guide", app)
        app.buttons["widget-placement-close"].tap()
        XCTAssertFalse(listGuide.exists, "The list's guide is offered once")
        for _ in 0..<3 where !entry.isHittable { app.swipeDown(velocity: .slow) }
        entry.tap()
        stopReceiving(app)
        XCTAssertTrue(app.buttons["official-window-subscribe"].waitForExistence(timeout: 5))
        app.navigationBars["どこかの猫"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["まど"].waitForExistence(timeout: 5))
        waitForWindowEntry("official-window-entry", value: "まだ受け取っていません", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isHittable)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }

    @MainActor
    func testWindowListLargeTextKeepsDiscoveryAndPhotoReachable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // 1.0: the received window is a card at the top and 「公式のまど」 (here
        // おひるね, not received) is listed below it on the same tab.
        app.launchArguments = ["--window-list-ui-fixture", "--window-list-subscribed", "--window-list-nap-discoverable",
                               "--window-list-large-text", "-AppleLanguages", "(ja)"]
        app.launch()
        let card = app.buttons["official-window-entry"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.isHittable)
        XCTAssertTrue((card.value as? String ?? "").contains("受け取り中"))
        XCTAssertTrue(app.tabBars.buttons["写真"].isHittable)
        capture("window-list-large-text", app)
        let discover = app.buttons["public-window-entry-nap-cats"]
        let receive = app.buttons["public-window-add-nap-cats"]
        XCTAssertTrue(discover.waitForExistence(timeout: 5))
        for _ in 0..<5 where !(discover.isHittable && receive.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(discover.isHittable, "Discovery must stay reachable at large text")
        XCTAssertTrue(receive.isHittable, "「受け取る」 must stay reachable at large text")
        XCTAssertGreaterThanOrEqual(receive.frame.height, 44)
        XCTAssertTrue(app.tabBars.buttons["写真"].isHittable)
        capture("window-list-large-text-discovery", app)
        discover.tap()
        XCTAssertTrue(app.navigationBars["おひるね"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["official-window-subscribe"].exists, "Looking must not receive")
        app.navigationBars["おひるね"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["まど"].waitForExistence(timeout: 5))
        XCTAssertTrue(receive.waitForExistence(timeout: 5))
        for _ in 0..<5 where !card.isHittable { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(card.isHittable, "Discovery must return to the receiving photo")
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
        let photographedOn = app.staticTexts["撮影日：2026年9月1日"]
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
        app.launchArguments = ["--official-window-ui-fixture", "--official-window-recent-photos",
                               "--official-window-renew-expiry", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
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
        XCTAssertTrue(app.navigationBars["確認用の猫"].exists,
                      "Renewing this photo's expiry during its retry must keep its full-screen viewer open")
        capture("official-photo-retry-recovered", app)
        app.buttons["閉じる"].tap()
        // The next edition renews the same IDs, bytes and original publication
        // dates. It must not be described as newly received photos.
        pullToRefresh(app)
        XCTAssertTrue(app.staticTexts["新しい写真はありませんでした"].waitForExistence(timeout: 10))
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
    func testLostCatMissingLedgerStopsWithoutChangingPhotosAndRecoversAfterRestore() {
        let app = XCUIApplication()
        app.launchArguments = ["--lost-cat-draft-ui-fixture", "--lost-cat-ledger-recovery-check"]
        app.launch()
        let result = app.staticTexts["lost-cat-ledger-recovery-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label == %@", "passed"), evaluatedWith: result)
        waitForExpectations(timeout: 10)
    }

    @MainActor
    func testLostCatExportLifecycleProtectsAndRemovesOnlyManagedCopies() {
        let app = XCUIApplication()
        app.launchArguments = ["--lost-cat-draft-ui-fixture", "--lost-cat-export-lifecycle-check"]
        app.launch()
        let result = app.staticTexts["lost-cat-export-lifecycle-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let finished = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "passed", "failed:")
        expectation(for: finished, evaluatedWith: result)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(result.label, "passed", "Export lifecycle fixture reported a bounded failure code")
    }

    /// 1.0: one window is a row under 「公式のまど」 or a card above it. While it
    /// moves, both can exist for a moment; wait until exactly one entry remains
    /// and it reads the expected receiving state.
    @MainActor
    /// 公式のまど checks again by pull to refresh only; there is no ↻ button (11/8).
    private func pullToRefresh(_ app: XCUIApplication) {
        XCTAssertFalse(app.buttons["official-window-refresh"].exists)
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        for _ in 0..<3 { scroll.swipeDown() }
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func waitForWindowEntry(_ identifier: String, value expected: String, in app: XCUIApplication) {
        let entries = app.buttons.matching(identifier: identifier)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            entries.count == 1 && (entries.firstMatch.value as? String ?? "").contains(expected)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                       "\(identifier) must settle as 「\(expected)」")
    }

    @MainActor
    private func stopReceiving(_ app: XCUIApplication, windowName: String = "どこかの猫") {
        let manage = app.navigationBars[windowName].buttons["official-window-manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()
        app.buttons["official-window-stop"].tap()
        let confirm = receivingConfirmationButton("official-window-stop-confirm", in: app, windowName: windowName)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Stopping needs a deliberate confirmation")
        confirm.tap()
    }

    @MainActor
    private func receivingConfirmationButton(_ identifier: String, in app: XCUIApplication, windowName: String = "どこかの猫") -> XCUIElement {
        // iOS 26's recorded AX tree exposes a parent and child Button with
        // the same ID/label for one alert action. Scope to this exact alert
        // before selecting that action; the post-tap subscription checks stay.
        app.alerts["「\(windowName)」の受け取りをやめますか？"]
            .buttons.matching(identifier: identifier).firstMatch
    }

    @MainActor
    func testOfficialEmptyStatesMatchCoverAndOfferNearbyActions() {
        continueAfterFailure = false
        let scenarios: [(String, String)] = [
            ("empty", "いまは見られる写真がありません"),
            ("paused", "いまは写真が届きません"),
            ("failure", "写真を読み込めませんでした"),
            ("catalog-expiry", "写真を読み込み直してください")
        ]
        for largest in [false, true] {
            for (scenario, title) in scenarios {
                let app = XCUIApplication()
                app.launchArguments = ["--window-list-ui-fixture", "--window-list-subscribed", "--window-list-two-public",
                                       "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
                    + (largest ? ["--window-list-largest-text"] : [])
                app.launchEnvironment["NEKO_OFFICIAL_WINDOW_STATUS_FIXTURE"] = scenario
                app.launch()
                let entry = app.buttons["official-window-entry"]
                XCTAssertTrue(entry.waitForExistence(timeout: 10))
                if scenario == "catalog-expiry" {
                    XCTAssertFalse((entry.value as? String ?? "").contains(title))
                    capture("official-state-catalog-before-deadline-\(largest)", app)
                }
                expectation(for: NSPredicate { _, _ in
                    (entry.value as? String ?? "").contains(title)
                }, evaluatedWith: entry)
                waitForExpectations(timeout: 20)
                XCTAssertFalse((entry.value as? String ?? "").contains("配信は終了"))
                capture("official-state-\(scenario)-cover-\(largest)", app)
                entry.tap()
                let state = app.descendants(matching: .any)["official-window-state-title"].firstMatch
                XCTAssertTrue(state.waitForExistence(timeout: 5))
                expectation(for: NSPredicate { _, _ in state.label.contains(title) }, evaluatedWith: state)
                waitForExpectations(timeout: 5)
                let retry = app.buttons["official-window-refresh-retry"]
                for _ in 0..<3 where !retry.isHittable { app.swipeUp(velocity: .slow) }
                XCTAssertTrue(retry.isHittable)
                XCTAssertTrue(retry.isEnabled)
                capture("official-state-\(scenario)-detail-\(largest)", app)
                retry.tap()
                expectation(for: NSPredicate { _, _ in retry.isEnabled }, evaluatedWith: retry)
                waitForExpectations(timeout: 5)
                XCTAssertTrue(state.label.contains(title))
                // Other official windows are added from the まど tab, not from here (10/31).
                XCTAssertFalse(app.buttons["official-window-state-discovery"].exists)
                app.terminate()
            }
        }
    }

    @MainActor
    func testUnconfiguredFeedIsPreparationNotFakeDelivery() {
        let app = XCUIApplication()
        app.launchArguments = ["--official-window-ui-fixture", "--official-window-unconfigured", "-AppleLanguages", "(ja)"]
        app.launch()
        // The copy says 「公式のまど」 since the 10/30 wording pass.
        let state = app.descendants(matching: .any)["official-window-state-title"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        XCTAssertTrue(state.label.contains("公式のまどを準備しています"), state.label)
        XCTAssertFalse(app.buttons["official-window-subscribe"].exists)
        XCTAssertFalse(app.buttons["official-window-refresh-retry"].exists,
                       "An unconfigured window has nothing to check again")
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
        XCTAssertTrue(app.staticTexts["写真の公開が終わりました"].exists)
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
        app.buttons["cat-profile-more"].tap()
        app.buttons["cat-profile-add-photos"].tap()
        let picker = app.scrollViews["cat-profile-add-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let firstChoice = picker.buttons.matching(identifier: "cat-profile-photo").firstMatch
        XCTAssertTrue(firstChoice.waitForExistence(timeout: 5))
        firstChoice.tap()
        let add = app.buttons["cat-profile-confirm-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.staticTexts["追加できませんでした。もう一度お試しください。"].waitForExistence(timeout: 5))
        XCTAssertEqual(add.label, "テスト猫Bに1枚追加", "A failed save lost the explicit selection or destination.")
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
        app.buttons["cat-profile-more"].tap()
        app.buttons["cat-profile-settings"].tap()
        // 11/7: the cat's one page; 11/12: its parts are always open.
        // 11/12 (round 2): deleting is in 「…」 at the top right.
        XCTAssertTrue(app.buttons["cat-profile-rename"].waitForExistence(timeout: 5), app.debugDescription)
        let more = app.buttons["cat-care-more-menu"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        let delete = app.buttons["cat-profile-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(delete.label, "この子を削除")
        delete.tap()
        let confirmation = app.alerts["テスト猫Bを削除しますか？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["この子を削除"].tap()
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
            labels: ["アルバム"],
            timeout: 10
        ) != nil else {
            fail("The Albums tab disappeared from the tab bar.", app: app)
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
            fail("Settings remained a peer tab instead of a toolbar action.", app: app)
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

        app.buttons["main-tab-tools"].tap()
        let settingsButton = firstExistingButton(
            in: app,
            identifiers: ["tools-settings-button"],
            labels: ["設定"],
            timeout: 10
        )
        guard let settingsButton else {
            fail("Albums did not expose its Settings action after onboarding.", app: app)
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

        // From Settings the guide has one 「閉じる」, not 「完了」 and 「あとで」 (11/7).
        let widgetClose = app.buttons["widget-placement-close"]
        guard widgetClose.waitForExistence(timeout: 15) else {
            fail(
                "The Widget placement guide did not reopen from Settings.",
                app: app
            )
            return
        }
        XCTAssertFalse(app.buttons["widget-placement-skip"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Widget placement guide reopened from Settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.terminate()
    }

    @MainActor
    func testMainlineAcceptanceScreensWithAuthorizedLibrary() {
        // The harness validates and archives the real permission evidence
        // before this separate session can prune it through fixture launches.
        // Movie preparation still reuses the UI-authorized library.
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
                    // 10/21: the first scan shows a grid of up to nine, so all
                    // four inputs of "three" are shown and nothing else loads.
                    let expected = scenario == "one" ? 1 : 4
                    XCTAssertTrue(app.staticTexts["mainline-loaded-\(expected)"].waitForExistence(timeout: 15),
                                  app.debugDescription)
                    XCTAssertFalse(app.staticTexts["mainline-loaded-\(expected + 1)"].exists)
                } else {
                    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "写真を表示できません").firstMatch
                        .waitForExistence(timeout: 15))
                }
                captureMainlineScreen(scenario)
                next.tap()
                // 10/22: 「あとで」 enters the 写真 tab directly; no first photo is opened.
                XCTAssertFalse(app.buttons["widget-placement-skip"].exists)
                XCTAssertTrue(app.staticTexts["mainline-fixture-finished"].waitForExistence(timeout: 10))

                // Widget placement remains an explicit alternative, rather
                // than interrupting the first photo the person wants to see.
                app.terminate()
                app.launch()
                let widgetGuide = app.buttons["initial-scan-widget-guide"]
                XCTAssertTrue(widgetGuide.waitForExistence(timeout: 15))
                widgetGuide.tap()
                let skipWidget = app.buttons["widget-placement-skip"]
                XCTAssertTrue(skipWidget.waitForExistence(timeout: 15))
                if scenario == "one" {
                    captureMainlineScreen("widget-guide")
                }
                skipWidget.tap()
                XCTAssertTrue(app.staticTexts["mainline-fixture-finished"].waitForExistence(timeout: 10))
            case "limited-zero":
                XCTAssertTrue(app.staticTexts["猫の写真は見つかりませんでした"].waitForExistence(timeout: 15))
                XCTAssertFalse(app.buttons["initial-scan-widget-guide"].exists)
                XCTAssertFalse(app.buttons["first-run-photo-close"].exists)
                captureMainlineScreen(scenario)
                // 10/30 plain-Japanese copy: 「写真を追加で選ぶ」「もう一度探す」.
                app.buttons["写真を追加で選ぶ"].tap()
                XCTAssertTrue(app.staticTexts["mainline-action-choose"].waitForExistence(timeout: 5))
                app.buttons["もう一度探す"].tap()
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
                // Unavailable or still-preparing summaries have no empty
                // cover. The Photos route remains available without a duplicate
                // Favorites entry in Albums.
                XCTAssertTrue(app.navigationBars["アルバム"].waitForExistence(timeout: 15))
                XCTAssertFalse(app.descendants(matching: .any)["albums-favorites"].exists)
                XCTAssertTrue(app.buttons["memories-open-photos"].isHittable)
                XCTAssertFalse(app.descendants(matching: .any)["memories-monthly-window"].exists)
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
    @MainActor
    private func verifyAutomaticSaveInterruptionAndBackgroundLifetime() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-records-ui-fixture", "--app-records-background-probe"]
        app.launch()
        XCTAssertTrue(app.staticTexts["background probe ready"].waitForExistence(timeout: 15), app.debugDescription)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        // Give the real UIKit assertion time to finish while the app is backgrounded.
        Thread.sleep(forTimeInterval: 9)
        app.activate()
        XCTAssertTrue(app.staticTexts["background probe completed in background"].waitForExistence(timeout: 5), app.debugDescription)
        app.terminate()
        app.launchArguments = ["--app-records-ui-fixture", "--app-records-photo-interruption-probe"]
        app.launch()
        XCTAssertTrue(app.staticTexts["45MBの中断再開と写真の再送なしを確認しました"].waitForExistence(timeout: 120), app.debugDescription)
        app.terminate()
        verifyAutomaticSaveGroupsMetadataAndResumesInterruptedUnion()
    }
    @MainActor
    func testAutomaticPartitionedRecordsMigrationAndRestore() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-records-ui-fixture", "--app-records-capacity-probe",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(app.staticTexts["容量対応・旧形式の移行・写真とメモの復元を確認しました"].waitForExistence(timeout: 180), app.debugDescription)
        capture("automatic-partitioned-records-migration-and-restore")
        app.terminate()
    }

    @MainActor
    func testFamilyProofOpensAfterRestoreAndReconnects() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-records-ui-fixture", "--family-proof-restore-ui-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let proof = app.buttons["cat-care-restored-vaccine-proof"]
        XCTAssertTrue(proof.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(proof.label, "証明の写真")
        XCTAssertFalse(app.staticTexts["試験のワクチン"].exists)
        proof.tap()
        let enlarged = app.descendants(matching: .any).matching(identifier: "tool-record-photo-full").firstMatch
        XCTAssertTrue(enlarged.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["閉じる"].tap()
        app.buttons["fixture-reinvite-proof"].tap()
        XCTAssertTrue(app.staticTexts["証明の写真あり"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(proof.exists)
    }
    @MainActor
    func testAutomaticSaveDestinationRebind() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-records-ui-fixture", "--app-records-rebind-probe",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(app.staticTexts["保存先を切り替えて保存済みまで確認しました"].waitForExistence(timeout: 120), app.debugDescription)
        print(app.staticTexts["autosave-measurements"].label)
        capture("automatic-save-destination-rebind")
    }

    @MainActor
    func testAutomaticSaveEfficiencyAndCleanupPriority() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-records-ui-fixture", "--app-records-efficiency-probe",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(app.staticTexts["保存中の停止を確認できます"].waitForExistence(timeout: 120), app.debugDescription)
        app.buttons["保存・復元"].tap()
        let pause = app.buttons["app-record-pause"]
        for _ in 0..<4 where !pause.isHittable { app.swipeUp() }
        XCTAssertTrue(pause.waitForExistence(timeout: 10), app.debugDescription)
        pause.tap()
        app.buttons["自動保存をやめる"].tap()
        // Keep this screen open: reopening used to hide the stale-state bug.
        for _ in 0..<4 where !app.buttons["app-record-enable"].isHittable { app.swipeDown() }
        XCTAssertTrue(app.buttons["app-record-enable"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["自動保存はオフです"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["app-record-pause"].exists, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["app-record-quota-records"].exists, app.debugDescription)
        capture("automatic-save-paused-without-reopening")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["保存の回数・片づけの分離・編集の集約を確認しました"].waitForExistence(timeout: 20), app.debugDescription)
        print(app.staticTexts["autosave-measurements"].label)
        capture("automatic-save-efficiency-and-cleanup-priority")
        app.terminate()
        verifyAutomaticSaveKeepsAcknowledgementAndResumesCleanup()
    }

    @MainActor
    func testAutomaticSaveRefreshesVisibleUsage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-records-ui-fixture", "--app-records-opening-usage-ui",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(app.buttons["保存・復元"].waitForExistence(timeout: 60), app.debugDescription)
        app.buttons["保存・復元"].tap()
        let count = app.descendants(matching: .any)["app-record-quota-records"].firstMatch
        // Before enable the quota section is intentionally hidden. The fixture's
        // opening GET returns zero; after the first saved head it returns three.
        let start = app.buttons["app-record-enable"]
        if !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        start.tap()
        XCTAssertTrue(count.waitForExistence(timeout: 120), app.debugDescription)
        let saved = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "3 / 3,000", "3 / 3,000")
        expectation(for: saved, evaluatedWith: count)
        waitForExpectations(timeout: 120)
        let storage = app.descendants(matching: .any)["app-record-quota-storage"].firstMatch
        let capacity = storage.label + " " + (storage.value as? String ?? "") + " "
            + storage.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(capacity.contains("4") && capacity.contains("GB"), capacity)
        XCTAssertFalse(capacity.contains("0 KB /"), capacity)
        XCTAssertTrue(app.staticTexts["保存済み"].exists, app.debugDescription)
        capture("automatic-save-usage-after-save")
    }

    @MainActor
    func testAutomaticSaveSettingsDoNotInvalidateSession() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-records-ui-fixture", "--app-records-session-probe",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(app.staticTexts["自動保存の照会干渉と一項目の計測を確認しました"].waitForExistence(timeout: 90), app.debugDescription)
        print(app.staticTexts["autosave-measurements"].label)
        capture("automatic-save-account-observation")
        app.terminate()
        for expired in [false, true] {
            app.launchArguments = ["--app-records-ui-fixture", "--app-records-observation-ui",
                                   "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            if expired { app.launchArguments.append("--app-records-expired-session") }
            app.launch()
            XCTAssertTrue(app.buttons["保存・復元"].waitForExistence(timeout: 60), app.debugDescription)
            app.buttons["保存・復元"].tap()
            XCTAssertTrue(app.navigationBars["自動保存"].waitForExistence(timeout: 10), app.debugDescription)
            if expired {
                XCTAssertTrue(app.buttons["app-record-check-session"].waitForExistence(timeout: 10), app.debugDescription)
            } else {
                XCTAssertTrue(app.buttons["app-record-pause"].waitForExistence(timeout: 10), app.debugDescription)
            }
            XCTAssertFalse(app.buttons["app-record-signin"].exists, app.debugDescription)
            XCTAssertFalse(app.staticTexts["サインインすると、保存が始まります。"].exists, app.debugDescription)
            XCTAssertEqual(app.staticTexts["app-record-save-status"].label, "保存済み", app.debugDescription)
            capture(expired ? "automatic-save-expired-observation" : "automatic-save-401-observation")
            app.terminate()
        }
    }
    @MainActor
    private func verifyAutomaticSaveKeepsAcknowledgementAndResumesCleanup() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-records-ui-fixture", "--app-records-cleanup-probe",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(app.staticTexts["保存完了・中断の区別と自動再開を確認しました"].waitForExistence(timeout: 40), app.debugDescription)
        capture("automatic-save-acknowledgement-and-cleanup-resume")
        app.terminate()
    }

    @MainActor
    private func verifyAutomaticSaveDeletionJournalSurvivesDirectoryEnumeration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-records-ui-fixture", "--app-records-journal-probe",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(app.staticTexts["途中の整理記録を読み直しました"].waitForExistence(timeout: 10), app.debugDescription)
        let identity = app.staticTexts["journal-identity-probe"]
        XCTAssertTrue(identity.exists, app.debugDescription)
        print("APP_RECORD_JOURNAL_IDENTITY_INPUTS \(identity.label)")
        capture("automatic-save-deletion-journal-roundtrip")
        app.terminate()
    }

    @MainActor
    func testToolBackupShowsForegroundGuidanceAndResumesInterruptedDeletion() {
        verifyAutomaticSaveInterruptionAndBackgroundLifetime()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--managed-preservation-membership-ui-fixture", "--preservation-tool-delete-pending-ui-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let resume = app.buttons["preservation-resume-tool-deletion"]
        XCTAssertTrue(app.navigationBars["保存した記録"].waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<12 where !resume.isHittable { app.swipeUp() }
        XCTAssertTrue(resume.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["preservation-transfer-foreground-guidance"].exists)
        resume.tap()
        let complete = app.staticTexts["このコピーを削除しました。ほかのコピーで使う写真は残っています。"]
        for _ in 0..<12 where !complete.isHittable { app.swipeDown() }
        XCTAssertTrue(complete.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(resume.exists)
        app.terminate()
        verifyAutomaticSaveDeletionJournalSurvivesDirectoryEnumeration()
        verifyAutomaticSaveKeepsAcknowledgementAndResumesCleanup()
    }

    @MainActor
    func testToolBackupRestoresPrivateCopiesWithoutPhotoLibraryIdentity() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--tool-backup-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let result = app.staticTexts["保存・再開・欠落拒否・復元・元記録保全を確認"]
        XCTAssertTrue(result.waitForExistence(timeout: 40), app.debugDescription)
        app.buttons["復元したツールを開く"].tap()
        XCTAssertTrue(app.buttons["預けるとき"].waitForExistence(timeout: 5))
        // 10/31 plain-Japanese copy (75eb9286): 「ツールの内容・写真N枚」.
        XCTAssertEqual(app.staticTexts["restored-tool-contents-summary"].label, "ツールの内容・写真3枚")
        capture("restored-tools-show-attachment-count")
        app.buttons["預けるとき"].tap()
        // 11/7: the care tool opens a cat in place. 11/12: the cats are the
        // items of the menu in the bar (care-cat-<UUID>, as the row's chips
        // were named), not other care-cat-… controls such as the folded この子のこと.
        let cats = app.buttons.matching(NSPredicate(format: "identifier MATCHES %@",
            "care-cat-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"))
        openCareCatMenu(app)
        XCTAssertTrue(cats.firstMatch.waitForExistence(timeout: 5)); XCTAssertEqual(cats.count, 2)
        cats.firstMatch.tap()
        // The name of a cat without a profile is its own row's page.
        openToolRow("care-row-name", title: "名前", bottom: "care-preview-open", app: app)
        let name = app.textFields["care-cat-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); XCTAssertEqual(name.value as? String, "同じ名前")
        name.tap(); name.typeText("編集")
        let edited = name.value as? String
        XCTAssertTrue(edited?.contains("編集") == true)
        // Leave the name's page and the tool (the memo is the tool's page) and reopen it.
        leaveVetPage("名前", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["預けるとき"].waitForExistence(timeout: 5)); app.buttons["預けるとき"].tap()
        openCareCatMenu(app)
        XCTAssertTrue(cats.firstMatch.waitForExistence(timeout: 5)); XCTAssertEqual(cats.count, 2)
        cats.firstMatch.tap()
        openToolRow("care-row-name", title: "名前", bottom: "care-preview-open", app: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5)); XCTAssertEqual(name.value as? String, edited)
        capture("restored-care-edit-keeps-same-name-cats-separate")
        leaveVetPage("名前", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["病院で見せる"].waitForExistence(timeout: 5))
        app.buttons["病院で見せる"].tap()
        // 11/8: a past memo row is named by its day; find it by its identifier.
        // 11/12: the past memos are a page of their own, opened from one row
        // under 「診察メモ」, below the first screen; the Form makes it near view.
        let previousVisit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "vet-past-")).firstMatch
        XCTAssertTrue(app.buttons["vet-show"].waitForExistence(timeout: 5), app.debugDescription)
        let pastRow = app.buttons["vet-row-past"]
        revealVetRow(pastRow, app: app); pastRow.tap()
        XCTAssertTrue(app.navigationBars["これまでの診察メモ"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(previousVisit.waitForExistence(timeout: 5), app.debugDescription)
        previousVisit.tap()
        XCTAssertTrue(app.staticTexts["診察済み"].waitForExistence(timeout: 5))
        // What was noticed is read only, on its row's page inside the memo.
        openVetRow("vet-step-noticed", title: "家で気付いたこと", app: app)
        XCTAssertTrue(app.staticTexts["保存当時の診察"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["vet-observations"].exists, "A finished memo stays read only")
        capture("restored-veterinary-history-keeps-original-context")
        leaveVetPage("家で気付いたこと", app: app)
        app.navigationBars["診察メモ"].buttons["閉じる"].tap()
        leaveVetPage("これまでの診察メモ", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let lost = app.buttons["迷子の控え"]
        for _ in 0..<5 where !lost.isHittable { app.swipeUp(velocity: .slow) }
        lost.tap()
        // 11/12: the name is a row of 迷子のとき; its page holds the field.
        openToolRow("lost-cat-row-name", title: "名前", bottom: "チラシを作る", app: app)
        XCTAssertTrue(app.textFields["lost-cat-name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["lost-cat-name"].value as? String, "迷子の控え")
        capture("restored-lost-cat-draft")
        leaveVetPage("名前", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<5 where !app.buttons["みんなの写真"].isHittable { app.swipeUp(velocity: .slow) }
        app.buttons["みんなの写真"].tap()
        XCTAssertTrue(app.images["保存した写真"].waitForExistence(timeout: 5), app.debugDescription)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "restored-tool-owned-photo"; attachment.lifetime = .keepAlways; add(attachment)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["編集後の元記録を確認"].tap()
        XCTAssertTrue(app.staticTexts["元の記録を保ち、復元コピーだけを編集しました"].waitForExistence(timeout: 5))
        app.terminate()
        verifyAutomaticRecordSavingAndRestore(app)
    }

    @MainActor
    private func prepareAutomaticRecordSavingAndRestore(_ app: XCUIApplication, archiveListingConflict: Bool = false) {
        app.launchArguments = ["--app-records-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        if archiveListingConflict { app.launchArguments.append("--app-records-settings-conflict") }
        app.launch()
        XCTAssertTrue(app.buttons["保存・復元"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["app-record-fixture-photo-count"].label, "写真の送信 0回")
        app.buttons["保存・復元"].tap()
        // One button starts saving (10/31); its consent is the text above it.
        let start = app.buttons["app-record-enable"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.switches["app-record-consent"].exists)
        XCTAssertFalse(app.buttons["ツールを保存する"].exists)
        start.tap()
        let saved = app.staticTexts["app-record-save-status"]
        XCTAssertTrue(NSPredicate(format: "label == %@", "保存済み").evaluate(with: saved) || saved.waitForExistence(timeout: 10))
        let completes = expectation(for: NSPredicate(format: "label == %@", "保存済み"), evaluatedWith: saved)
        wait(for: [completes], timeout: 20)
        capture("automatic-save-one-time-consent")
        // Plus lives in Settings' own section; this screen keeps the account door.
        XCTAssertFalse(app.buttons["app-record-membership-manage"].exists)
        let account = app.buttons["app-record-account"]
        for _ in 0..<4 where !account.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(account.waitForExistence(timeout: 5), app.debugDescription)
        // Everything saved comes out as one file from the same screen.
        XCTAssertTrue(app.buttons["app-record-export"].waitForExistence(timeout: 5), app.debugDescription)
        if archiveListingConflict {
            XCTAssertFalse(app.staticTexts["記録が更新されています。最新の内容を読み込み直してください。"].exists)
        }
        capture("automatic-save-apple-contract-entry")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let photoCount = app.staticTexts["app-record-fixture-photo-count"]
        XCTAssertEqual(photoCount.label, "写真の送信 4回")
        let status = app.staticTexts["app-record-fixture-status"]
        let detail = app.staticTexts["app-record-fixture-detail"]
        func waitUntilSaved() {
            let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "保存済み"), object: status)
            XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 25), .completed,
                           "\(status.label) / \(detail.exists ? detail.label : "説明なし")")
        }
        // 11/7: the care tool opens a cat in place (no list to go back to).
        // 11/12: its cats are the menu's care-cat-<UUID> items.
        let cats = app.buttons.matching(NSPredicate(format: "identifier MATCHES %@",
            "care-cat-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"))
        // 11/9 (#900): the first time a tool opens, the identifying photos the
        // tools kept are copied once into 「この子のこと」 (two in this fixture;
        // run 42540048321 counted 6 after the first save). Those new files are
        // saved once; open the tool first so they are counted apart from the
        // ordinary edit below.
        app.buttons["預けるとき"].tap()
        openCareCatMenu(app)
        XCTAssertTrue(cats.firstMatch.waitForExistence(timeout: 5)); XCTAssertEqual(cats.count, 2)
        // Choosing the cat closes the menu; nothing is written by it.
        cats.firstMatch.tap()
        XCTAssertTrue(app.buttons["care-preview-open"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["自動保存の検査"].waitForExistence(timeout: 5), app.debugDescription)
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "写真の送信 6回"), object: photoCount)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 25), .completed,
                       "\(photoCount.label) / \(status.label) / \(detail.exists ? detail.label : "説明なし")")
        waitUntilSaved()
        app.buttons["預けるとき"].tap()
        openCareCatMenu(app)
        XCTAssertTrue(cats.firstMatch.waitForExistence(timeout: 5)); XCTAssertEqual(cats.count, 2)
        cats.firstMatch.tap()
        openToolRow("care-row-name", title: "名前", bottom: "care-preview-open", app: app)
        let name = app.textFields["care-cat-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("変更")
        let edited = name.value as? String
        // Back from the name's page, then one back leaves the tool and
        // returns to the fixture's own list.
        leaveVetPage("名前", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["自動保存の検査"].waitForExistence(timeout: 5), app.debugDescription)
        // The list can still show the earlier 「保存済み」 until this edit's save
        // starts (run 42545036862 went on 0.1 s after coming back). Let the
        // save begin; a save quicker than a poll leaves this wait unmet, which
        // is fine: 「保存済み」 is still required below, and the restore on the
        // other device checks this edit's name.
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", "保存済み"), object: status)], timeout: 10)
        waitUntilSaved()
        // The ordinary edit sends no photo again.
        XCTAssertEqual(photoCount.label, "写真の送信 6回")
        capture("automatic-save-from-ordinary-care-edit-no-photo-resend")
        app.buttons["別端末での自動復元を検査"].tap()
        let restoreResult = app.staticTexts["app-record-fixture-result"]
        XCTAssertTrue(app.staticTexts["自動復元・通常画面・元記録保全を確認"].waitForExistence(timeout: 20),
                      (restoreResult.exists ? restoreResult.label : "結果なし") + " / " + app.debugDescription)
        app.buttons["預けるとき"].tap()
        openCareCatMenu(app)
        XCTAssertTrue(cats.firstMatch.waitForExistence(timeout: 5)); XCTAssertEqual(cats.count, 2)
        cats.firstMatch.tap()
        openToolRow("care-row-name", title: "名前", bottom: "care-preview-open", app: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5)); XCTAssertEqual(name.value as? String, edited)
        capture("automatic-restore-keeps-normal-tool-edit-and-cat-identity")
        leaveVetPage("名前", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["自動保存の検査"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func verifyAutomaticSaveGroupsMetadataAndResumesInterruptedUnion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-records-ui-fixture", "--app-records-metadata-batch-probe",
            "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(app.staticTexts["集約保存・中断再開・復元を確認しました"].waitForExistence(timeout: 60), app.debugDescription)
        app.terminate()
    }

    @MainActor
    private func verifyAutomaticRecordSavingAndRestore(_ app: XCUIApplication) {
        prepareAutomaticRecordSavingAndRestore(app)
        app.buttons["写真メモ"].tap()
        let note = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory-note-row-")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10)); note.tap()
        XCTAssertTrue(app.buttons["memory-note-photo"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["memory-note-photo-unavailable"].exists)
        capture("automatic-restore-photo-memo-without-photokit-link")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.terminate()
        verifyAutomaticSaveGroupsMetadataAndResumesInterruptedUnion()
    }

    @MainActor
    func testAutomaticRestoreProtectsUnsavedMemoDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        prepareAutomaticRecordSavingAndRestore(app, archiveListingConflict: true)
        let openDraft = app.buttons["app-record-open-draft"]
        XCTAssertTrue(openDraft.isEnabled); openDraft.tap()
        let draft = app.textViews["photo-memory-note-text"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10), app.debugDescription); draft.tap(); draft.typeText("編集中の文章")
        let draftText = draft.value as? String
        app.buttons["photo-memory-note-keyboard-done"].tap()
        app.buttons["別端末の変更を受信"].tap()
        let protected = expectation(for: NSPredicate(format: "label == %@", "入力が終わるのを待っています"), evaluatedWith: app.staticTexts["draft-protection-status"])
        wait(for: [protected], timeout: 15)
        XCTAssertEqual(draft.value as? String, draftText)
        capture("automatic-restore-defers-while-normal-memo-has-unsaved-text")
        app.buttons["photo-memory-note-close"].tap()
        app.buttons["保存せずに閉じる"].tap()
        XCTAssertTrue(app.buttons["通常のツール画面"].waitForExistence(timeout: 10), app.debugDescription)
        let resumed = expectation(for: NSPredicate(format: "label == %@", "復元しました"), evaluatedWith: app.staticTexts["app-record-fixture-status"])
        wait(for: [resumed], timeout: 25)
        capture("automatic-restore-resumes-after-editor-is-closed")
        app.terminate()
    }

    @MainActor
    func testAutomaticRestoredShowcaseWithoutPhotoAccess() {
        continueAfterFailure = false
        let app = XCUIApplication()
        prepareAutomaticRecordSavingAndRestore(app)
        let openTools = app.buttons["app-record-open-tools"]
        XCTAssertTrue(openTools.isEnabled); openTools.tap()
        let tools = app.buttons["main-tab-tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 10), app.debugDescription); tools.tap()
        let showcase = app.buttons["tools-showcase-open"]
        XCTAssertTrue(showcase.waitForExistence(timeout: 10)); showcase.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "showcase-gallery-photo").firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        capture("automatic-restore-showcase-opens-without-photo-library-access")
        app.terminate()
    }
    @MainActor
    private func launchWeightMemo(extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--photo-window-ui-fixture", "--memory-library-fixture", "--memory-library-weight",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"] + extra
        app.launchEnvironment["NEKO_PHOTO_UI_PREFERENCES_SUITE"] = "WeightMemoUITest.\(UUID())"
        app.launch()
        let section = app.buttons["photos-section-notes"]
        XCTAssertTrue(section.waitForExistence(timeout: 15)); section.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "memory-note-row-", "食べる量が少なかった")).firstMatch
        // Search can focus automatically at the largest text size. Close its
        // keyboard before scrolling the actual memo list, whose older target
        // row is lazily created below the newer, unselected cat's record.
        if app.keyboards.firstMatch.exists {
            let closeSearch = app.buttons["閉じる"]
            XCTAssertTrue(closeSearch.waitForExistence(timeout: 5)); closeSearch.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
        let notesList = app.scrollViews["memory-notes-list"]
        XCTAssertTrue(notesList.waitForExistence(timeout: 5))
        for _ in 0..<10 where !(row.exists && row.isHittable) { notesList.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.isHittable); row.tap()
        XCTAssertTrue(app.staticTexts["memory-note-weight"].waitForExistence(timeout: 5))
        return app
    }

    /// The picker lists recent photos first (349); bring 「写真に付けたメモ」 up.
    @MainActor
    private func revealVetPickerMemos(_ app: XCUIApplication) {
        let memos = app.staticTexts["写真に付けたメモ"]
        for _ in 0..<8 where !(memos.exists && memos.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(memos.exists, app.debugDescription)
    }

    @MainActor
    private func revealVetElement(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<10 where !element.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(element.isHittable, "Required action must be reachable: \(element.identifier)")
    }

    /// 病院で見せる's page between the navigation bar on top and 「先生に見せる」 at
    /// the bottom. A row under either still reads as hittable, but a tap there
    /// does nothing (runs 42545036862 and 42564398913: the picker and a past
    /// memo did not open). Scrolls toward the row from either side.
    @MainActor
    private func revealVetRow(_ element: XCUIElement, app: XCUIApplication) {
        let bar = app.buttons["vet-show"]
        let top = app.navigationBars.firstMatch
        func shown() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let y = element.frame.midY
            return (!bar.exists || y < bar.frame.minY - 24) && (!top.exists || y > top.frame.maxY + 8)
        }
        for _ in 0..<10 where !shown() {
            if !element.exists || (bar.exists && element.frame.midY > bar.frame.minY - 24) {
                app.swipeUp(velocity: .slow)
            } else { app.swipeDown(velocity: .slow) }
        }
        XCTAssertTrue(shown(), "Required row must be reachable: \(element.identifier) / " + app.debugDescription)
    }

    /// 11/12: 病院で見せる is a list of rows; each opens a page titled with the
    /// row's name that holds that part's controls.
    @MainActor
    private func openVetRow(_ identifier: String, title: String, app: XCUIApplication) {
        let row = app.buttons[identifier]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        revealVetRow(row, app: app); row.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// Back from a row's page to the page that opened it (what was written
    /// is saved on leaving).
    @MainActor
    private func leaveVetPage(_ title: String, app: XCUIApplication) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), app.debugDescription)
        bar.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    /// 11/12: 預けるとき and 迷子のとき are lists of rows too. Like revealVetRow,
    /// the row is brought between the bar on top and the tool's button below
    /// (`bottom`: its identifier, or its label when it has none).
    @MainActor
    private func revealToolRow(_ element: XCUIElement, bottom: String, app: XCUIApplication) {
        let bar = app.buttons[bottom]
        let top = app.navigationBars.firstMatch
        func shown() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let y = element.frame.midY
            return (!bar.exists || y < bar.frame.minY - 24) && (!top.exists || y > top.frame.maxY + 8)
        }
        for _ in 0..<10 where !shown() {
            if !element.exists || (bar.exists && element.frame.midY > bar.frame.minY - 24) {
                app.swipeUp(velocity: .slow)
            } else { app.swipeDown(velocity: .slow) }
        }
        XCTAssertTrue(shown(), "Required row must be reachable: \(element.identifier) / " + app.debugDescription)
    }

    /// Opens a row of 預けるとき or 迷子のとき; its page has the row's name.
    @MainActor
    private func openToolRow(_ identifier: String, title: String, bottom: String, app: XCUIApplication) {
        let row = app.buttons[identifier]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        revealToolRow(row, bottom: bottom, app: app); row.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// 11/12: 預けるとき's cats are the items of the menu in the bar, named as
    /// the row's chips were (tool-profile-…, care-cat-…, care-saved-…).
    @MainActor
    private func openCareCatMenu(_ app: XCUIApplication) {
        let menu = app.buttons["care-cat-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        menu.tap()
    }

    /// 11/12: the cat is chosen from the menu in the bar (the row of faces is
    /// gone from this tool). `identifier` is the cat's item, as the row's chip
    /// was named; the menu then names the chosen cat.
    @MainActor
    private func chooseVetCat(_ identifier: String, app: XCUIApplication) {
        let menu = app.buttons["vet-cat-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        menu.tap()
        let item = app.buttons[identifier]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        let name = item.label
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5))
        // The item may also read its checkmark; either way the names overlap.
        let named = NSPredicate { object, _ in
            guard let label = (object as? XCUIElement)?.label, !label.isEmpty else { return false }
            return label.contains(name) || name.contains(label)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: named, object: menu)], timeout: 5),
                       .completed, "The chosen cat's memo must be the open page")
        // The memo is replaced in place; let the new page settle before using it.
        _ = app.buttons["vet-step-records"].waitForExistence(timeout: 5)
        sleep(1)
    }

    /// The cats the menu offers, with the menu open; closes it again.
    @MainActor
    private func vetMenuCats(_ app: XCUIApplication, matching predicate: NSPredicate) -> Int {
        let menu = app.buttons["vet-cat-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        menu.tap()
        let items = app.buttons.matching(predicate)
        _ = items.firstMatch.waitForExistence(timeout: 5)
        let count = items.count
        // Tapping outside the menu closes it without choosing.
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(items.firstMatch.waitForNonExistence(timeout: 5))
        return count
    }

    // The real PhotoKit request can arrive while the fixture's source-confirmation
    // sheet is visible. Grant access only to the imported public test photos;
    // XCTest's default interruption handler otherwise denies and consumes a tap.
    @MainActor
    @discardableResult
    private func dismissVetPhotosPromptIfPresent() -> Bool {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return false }
        let labels = ["Allow Full Access", "Allow Access to All Photos",
                      "フルアクセスを許可", "すべての写真へのアクセスを許可"]
        guard let fullAccess = labels.map({ alert.buttons[$0] }).first(where: { $0.exists }) else {
            XCTFail("Unexpected system alert; do not dismiss unrelated permissions: \(alert.debugDescription)")
            return false
        }
        fullAccess.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 10))
        return true
    }

    @MainActor
    private func setVetToggle(_ toggle: XCUIElement, to value: String, app: XCUIApplication) {
        revealVetElement(toggle, app: app)
        dismissVetPhotosPromptIfPresent()
        if toggle.value as? String == value { return }
        // SwiftUI exposes both the whole labelled row and its native UISwitch.
        // Tap the thumb, not the row's center (which can be inert at large text).
        let thumb = toggle.switches.firstMatch
        XCTAssertTrue(thumb.exists, "A real switch thumb must be exposed: \(toggle.debugDescription)")
        thumb.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: toggle)
        if XCTWaiter.wait(for: [changed], timeout: 3) == .completed { return }
        // Retry only when a newly arrived, positively identified Photos prompt
        // consumed that interaction, never to conceal an unresponsive control.
        guard dismissVetPhotosPromptIfPresent() else {
            capture("vet-toggle-did-not-change")
            XCTFail("Switch did not reach \(value): \(toggle.debugDescription)")
            return
        }
        if toggle.value as? String != value { thumb.tap() }
        let afterPermission = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [afterPermission], timeout: 5), .completed)
    }

    @MainActor
    func testWeightOnlyMemoRemainsReadableAndEditable() {
        let app = launchWeightMemo()
        app.buttons["memory-note-edit"].tap()
        let input = app.textViews["photo-memory-note-text"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.press(forDuration: 1.2)
        let selectAll = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["すべてを選択", "Select All"])).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5)); selectAll.tap()
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(input.value as? String, "")
        app.buttons["photo-memory-note-keyboard-done"].tap()
        app.buttons["photo-memory-note-save"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 5), "Weight alone is a record, not a deletion request")
        XCTAssertEqual(app.staticTexts["memory-note-weight"].label, "体重 4.2 kg")
        XCTAssertFalse(app.staticTexts["memory-note-body"].exists)
        capture("weight-only-memo-detail")
        app.navigationBars.buttons.firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "memory-note-row-", "4.2 kg")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        app.buttons["memory-note-edit"].tap()
        let weight = app.textFields["memo-weight-input"]
        revealVetElement(weight, app: app)
        XCTAssertEqual(weight.value as? String, "4.2")
        let date = app.switches["memo-weight-date-toggle"]; revealVetElement(date, app: app)
        XCTAssertEqual(date.value as? String, "1")
        capture("weight-only-memo-editor")
        app.terminate()
    }

    /// 11/10: the memo page no longer has 「診察メモに追加」; a memo reaches
    /// 「病院で見せる」 only through 「写真を選ぶ」 → 「写真に付けたメモ」.
    /// Leaves the memo page, opens 「病院で見せる」 as the tools do, makes the
    /// memo's own cat the open page from the cat menu, opens 「見せる写真・記録」
    /// and picks this memo, which presents its confirmation over the picker.
    /// The confirmation is a Form: at the largest text its 「この記録は…」 switch
    /// starts below the first screen and is made only near view, so the sheet
    /// is known by its title here and callers reveal `confirm` themselves.
    @MainActor
    private func openVetConfirmationThroughPicker(_ cat: String, memo: String, app: XCUIApplication) -> XCUIElement {
        let memoBar = app.navigationBars["メモ"]
        XCTAssertTrue(memoBar.waitForExistence(timeout: 5), app.debugDescription)
        let back = memoBar.buttons["写真"].exists ? memoBar.buttons["写真"] : memoBar.buttons.element(boundBy: 0)
        back.tap()
        XCTAssertTrue(memoBar.waitForNonExistence(timeout: 5))
        let open = app.buttons["memory-library-fixture-open-vet"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        XCTAssertTrue(app.navigationBars["病院で見せる"].waitForExistence(timeout: 10), app.debugDescription)
        chooseVetCat(cat, app: app)
        openVetRow("vet-step-records", title: "見せる写真・記録", app: app)
        let pick = app.buttons["vet-pick-records"]
        revealVetElement(pick, app: app); pick.tap()
        dismissVetPhotosPromptIfPresent()
        let picker = app.navigationBars["見せる写真を選ぶ"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15), app.debugDescription)
        let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "vet-source-", memo)).firstMatch
        revealVetPickerMemos(app)
        for _ in 0..<8 where !(source.exists && source.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(source.waitForExistence(timeout: 5), app.debugDescription)
        source.tap()
        XCTAssertTrue(app.navigationBars["内容を確認"].waitForExistence(timeout: 10), app.debugDescription)
        return picker
    }

    @MainActor
    func testVeterinarySelectionIsExplicitAndRemovalKeepsSource() {
        let app = launchWeightMemo()
        let cat = "vet-cat-09300000-0000-0000-0000-000000000001"
        let confirm = app.switches["vet-confirm-target"]
        let firstPicker = openVetConfirmationThroughPicker(cat, memo: "食べる量が少なかった。", app: app)
        revealVetElement(confirm, app: app)
        let add = app.buttons["vet-add-confirmed"]
        // 11/8: the memo names only むぎ (by saved identity), so it is not asked again.
        XCTAssertEqual(confirm.value as? String, "1")
        XCTAssertTrue(add.isEnabled)
        XCTAssertFalse(app.staticTexts["選んでいない別の猫の記録"].exists)
        capture("vet-selected-source-confirmation")
        setVetToggle(confirm, to: "1", app: app)
        revealVetElement(add, app: app); XCTAssertTrue(add.isEnabled); add.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10))
        // The picker stays open after an addition; 「完了」 returns to the page.
        XCTAssertTrue(firstPicker.exists, "The picker stays open after an addition")
        firstPicker.buttons["vet-pick-done"].tap()
        XCTAssertTrue(firstPicker.waitForNonExistence(timeout: 5))
        // 11/12: back on the page, the row counts the record.
        leaveVetPage("見せる写真・記録", app: app)
        let recordsRow = app.buttons["vet-step-records"]
        XCTAssertTrue(recordsRow.waitForExistence(timeout: 5))
        XCTAssertTrue((recordsRow.label + " " + (recordsRow.value as? String ?? "")).contains("1件"), recordsRow.debugDescription)
        let show = app.buttons["vet-show"]; revealVetElement(show, app: app); show.tap()
        XCTAssertTrue(app.scrollViews["vet-reading"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["食べる量が少なかった。"].exists)
        XCTAssertFalse(app.staticTexts["選んでいない別の猫の記録"].exists)
        capture("vet-selected-record-in-person-display")
        // The reading screen is titled 「診察メモ」; the page under it 「病院で見せる」.
        app.navigationBars["診察メモ"].buttons["閉じる"].tap()
        XCTAssertTrue(app.scrollViews["vet-reading"].waitForNonExistence(timeout: 5))
        // 11/12: the record and 「診察メモから外す」 are on 「見せる写真・記録」's page.
        openVetRow("vet-step-records", title: "見せる写真・記録", app: app)
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "vet-remove-")).firstMatch
        revealVetElement(remove, app: app); remove.tap()
        XCTAssertTrue(app.buttons["外す"].waitForExistence(timeout: 5)); app.buttons["外す"].tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        capture("vet-record-removed-source-kept")
        let pick = app.buttons["vet-pick-records"]
        revealVetElement(pick, app: app); pick.tap()
        // 349: 「見せる写真を選ぶ」, recent photos first, then the memos below.
        // 11/9 (#899): it also reads the recent videos; the sheet was still
        // coming up at 5 s on the hosted Simulator (dimming already shown).
        let picker = app.navigationBars["見せる写真を選ぶ"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15), app.debugDescription)
        let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "vet-source-")).firstMatch
        revealVetPickerMemos(app)
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "vet-source-", "選んでいない別の猫の記録")).firstMatch.exists)
        source.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "A pick must present the real confirmation")
        app.navigationBars["内容を確認"].buttons["閉じる"].tap()
        // The list stays open for more picks; 「完了」 closes it.
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(picker.exists, "The picker stays open after a pick")
        picker.buttons["vet-pick-done"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        // The cat's memo is the 「病院で見せる」 page itself (11/7); closing it
        // returns to the memo list, and the photo memo itself is unchanged.
        leaveVetPage("見せる写真・記録", app: app)
        app.navigationBars["病院で見せる"].buttons["閉じる"].tap()
        XCTAssertTrue(app.navigationBars["病院で見せる"].waitForNonExistence(timeout: 5))
        let memoRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "memory-note-row-", "食べる量が少なかった")).firstMatch
        for _ in 0..<10 where !(memoRow.exists && memoRow.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(memoRow.waitForExistence(timeout: 5)); memoRow.tap()
        XCTAssertTrue(app.staticTexts["memory-note-body"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["memory-note-body"].label, "食べる量が少なかった。")
        XCTAssertEqual(app.staticTexts["memory-note-weight"].label, "体重 4.2 kg")
        app.terminate()

        // Real tool stores, no registered profiles: shared IDs coalesce, while
        // two cats named むぎ stay separate. Only an explicit choice assigns weight.
        app.launchArguments = ["--evacuation-ui-fixture", "--ux-large-text",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_EVACUATION_FIXTURE_KEY"] = UUID().uuidString
        app.launchEnvironment["NEKO_EVACUATION_VET"] = "1"
        app.launch()
        let boundary = app.staticTexts["vet-saved-cat-boundary"]
        XCTAssertTrue(boundary.waitForExistence(timeout: 15)); XCTAssertEqual(boundary.label, "境界検証成功")
        let firstCat = "vet-cat-E0260929-0000-0000-0000-000000000001"
        let sameNameOtherCat = "vet-cat-E0260929-0000-0000-0000-000000000002"
        // 11/12: the cats are in the menu in the bar. Cats only: the menu itself
        // is "vet-cat-menu" and the folded 「この子のこと」 row (11/8) is
        // "vet-cat-care-fields-folded"; neither is a cat.
        XCTAssertEqual(vetMenuCats(app, matching: NSPredicate(format: "identifier IN %@", [firstCat, sameNameOtherCat])), 2)
        XCTAssertEqual(vetMenuCats(app, matching: NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@) AND identifier != %@",
            "vet-cat-", "vet-cat-care-", "vet-cat-menu")), 2)
        capture("vet-saved-cats-same-name-large-text")
        app.buttons["vet-saved-cat-edit-memo"].tap()
        let catPicker = app.descendants(matching: .any).matching(identifier: "memo-weight-cat-picker").firstMatch
        XCTAssertTrue(catPicker.waitForExistence(timeout: 5)); revealVetElement(catPicker, app: app)
        // 10/31 copy: no cat chosen reads 「選ばない」 (was 「未指定」).
        XCTAssertTrue(catPicker.label.contains("選ばない") || (catPicker.value as? String)?.contains("選ばない") == true)
        catPicker.tap()
        let choice = app.buttons["むぎ · 預けるとき・避難に備える"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        capture("weight-cat-explicit-tool-selection")
        app.buttons["photo-memory-note-save"].tap()
        XCTAssertTrue(catPicker.waitForNonExistence(timeout: 5))
        // 11/7: choosing a cat opens its memo in place on 「病院で見せる」
        // (11/12: from the menu in the bar).
        chooseVetCat(firstCat, app: app)
        XCTAssertTrue(app.navigationBars["病院で見せる"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "vet-remove-")).count, 0)
        // 家で気付いたこと is still empty: its row says so, and its page has the empty field.
        let noticedRow = app.buttons["vet-step-noticed"]
        XCTAssertTrue(noticedRow.waitForExistence(timeout: 5))
        XCTAssertTrue((noticedRow.label + " " + (noticedRow.value as? String ?? "")).contains("未記入"), noticedRow.debugDescription)
        openVetRow("vet-step-noticed", title: "家で気付いたこと", app: app)
        let observations = app.descendants(matching: .any).matching(identifier: "vet-observations").firstMatch
        XCTAssertTrue(observations.waitForExistence(timeout: 5))
        XCTAssertTrue(["", "例：1日2回吐く・食欲が半分"].contains(observations.value as? String ?? ""))
        leaveVetPage("家で気付いたこと", app: app)
        // No record chosen yet: the row says 「なし」 (11/12 rows; was the step header).
        let recordsStep = app.buttons["vet-step-records"]
        XCTAssertTrue(recordsStep.waitForExistence(timeout: 5))
        func recordsValue() -> String { recordsStep.label + " " + (recordsStep.value as? String ?? "") }
        XCTAssertTrue(recordsValue().contains("見せる写真・記録") && recordsValue().contains("なし"), recordsValue())
        openVetRow("vet-step-records", title: "見せる写真・記録", app: app)
        revealVetElement(app.buttons["vet-pick-records"], app: app)
        app.buttons["vet-pick-records"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        let measuredSource = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "vet-source-", "食べる量が少なかった。")).firstMatch
        revealVetPickerMemos(app)
        XCTAssertTrue(measuredSource.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "vet-source-", "選んでいない別の猫の記録")).firstMatch.exists)
        measuredSource.tap()
        // The weight was just given to this cat explicitly: already confirmed.
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); XCTAssertEqual(confirm.value as? String, "1")
        setVetToggle(confirm, to: "1", app: app); revealVetElement(add, app: app); XCTAssertTrue(add.isEnabled); add.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10))
        // 349: back on the list, the memo is marked added; 「完了」 closes it.
        XCTAssertTrue(picker.exists, "The picker stays open after an addition")
        XCTAssertTrue(measuredSource.waitForExistence(timeout: 5))
        XCTAssertTrue(measuredSource.label.contains("追加済み"), measuredSource.label)
        picker.buttons["vet-pick-done"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        leaveVetPage("見せる写真・記録", app: app)
        revealVetElement(show, app: app); show.tap()
        let reading = app.scrollViews["vet-reading"]
        XCTAssertTrue(reading.waitForExistence(timeout: 5))
        revealVetElement(reading.staticTexts["memory-note-weight"], app: app)
        XCTAssertEqual(reading.staticTexts["memory-note-weight"].label, "体重 4.2 kg")
        XCTAssertTrue(reading.staticTexts["むぎ · 測定日 不明"].exists)
        XCTAssertFalse(reading.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "private-")).firstMatch.exists)
        capture("vet-saved-cat-weight-in-person-display")
        app.terminate(); app.launch()
        chooseVetCat(firstCat, app: app)
        XCTAssertTrue(recordsStep.waitForExistence(timeout: 5))
        XCTAssertTrue(recordsValue().contains("1件"), recordsValue())
        openVetRow("vet-step-records", title: "見せる写真・記録", app: app)
        let retainedRecord = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "vet-remove-")).firstMatch
        revealVetElement(retainedRecord, app: app)
        XCTAssertTrue(retainedRecord.exists)
        leaveVetPage("見せる写真・記録", app: app)
        // The menu stays in the bar; the other むぎ opens in place.
        chooseVetCat(sameNameOtherCat, app: app)
        XCTAssertTrue(recordsStep.waitForExistence(timeout: 5))
        XCTAssertTrue(recordsValue().contains("なし"), "Same name must not carry the other cat's records: " + recordsValue())
        openVetRow("vet-step-records", title: "見せる写真・記録", app: app)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "vet-remove-")).firstMatch.exists)
        revealVetElement(app.buttons["vet-pick-records"], app: app); app.buttons["vet-pick-records"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        revealVetPickerMemos(app)
        XCTAssertFalse(measuredSource.waitForExistence(timeout: 3), "Same name must not reuse the other cat's weight")
        capture("vet-same-name-other-cat-keeps-separate-records")
        app.terminate()
    }

    @MainActor
    func testVeterinaryWithoutPhotoKeepsUnknownMeasurementDayAtLargestText() {
        let app = launchWeightMemo(extra: ["--memory-library-no-photo", "--photo-window-large"])
        app.buttons["memory-note-edit"].tap()
        let date = app.switches["memo-weight-date-toggle"]
        setVetToggle(date, to: "0", app: app)
        XCTAssertEqual(date.value as? String, "0")
        capture("weight-input-unknown-day-largest-text")
        app.buttons["photo-memory-note-save"].tap()
        XCTAssertTrue(date.waitForNonExistence(timeout: 5))
        let cat = "vet-cat-09300000-0000-0000-0000-000000000001"
        let confirm = app.switches["vet-confirm-target"]
        let picker = openVetConfirmationThroughPicker(cat, memo: "食べる量が少なかった。", app: app)
        XCTAssertTrue(app.staticTexts["元の写真を開けません。文章と体重だけ追加します。"].waitForExistence(timeout: 5))
        // At the largest size the confirmation thumb is below the first screen.
        // Verify the missing-photo explanation before scrolling it offscreen.
        revealVetElement(confirm, app: app)
        setVetToggle(confirm, to: "1", app: app)
        let add = app.buttons["vet-add-confirmed"]; revealVetElement(add, app: app)
        XCTAssertTrue(add.isEnabled); add.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10))
        XCTAssertTrue(picker.exists, "The picker stays open after an addition")
        picker.buttons["vet-pick-done"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        leaveVetPage("見せる写真・記録", app: app)
        let show = app.buttons["vet-show"]; revealVetElement(show, app: app); show.tap()
        // Presented sheets can leave the source memo's accessibility tree alive.
        // Assert the actual in-person reading surface, not every stacked view.
        let reading = app.scrollViews["vet-reading"]
        XCTAssertTrue(reading.waitForExistence(timeout: 5))
        let weight = reading.staticTexts["memory-note-weight"]
        revealVetElement(weight, app: app)
        XCTAssertEqual(weight.label, "体重 4.2 kg")
        XCTAssertTrue(reading.staticTexts["むぎ · 測定日 不明"].exists)
        XCTAssertFalse(reading.staticTexts["選んでいない別の猫の記録"].exists)
        XCTAssertLessThanOrEqual(weight.frame.maxX, app.frame.maxX)
        capture("vet-text-weight-without-photo-largest-text")
        app.terminate()
    }

    @MainActor
    func testCareHandoffAutofillIsRealOutputAndEditedValueSurvivesRestart() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--care-handoff-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_CARE_FIXTURE_KEY"] = UUID().uuidString
        app.launchEnvironment["NEKO_CARE_EMPTY"] = "1"
        app.launchEnvironment["NEKO_CARE_AUTOFILL"] = "1"
        app.launch()
        let boundaries = app.staticTexts["care-boundary-result"]
        XCTAssertTrue(boundaries.waitForExistence(timeout: 10))
        XCTAssertEqual(boundaries.label, "境界検証成功")
        // 11/7: the tool opens its cat in place. The cat written only in
        // 避難に備える becomes this tool's memo at once, filled from that record;
        // with one cat the cat menu stays away. Right after a deleted memo
        // the tool waits for a tap instead of making one by itself.
        // 11/12: one page of rows; 「お世話メモを作る」 is its bar's button.
        let make = app.buttons["care-preview-open"]
        let create = app.buttons["care-create-saved-C0260929-0000-0000-0000-000000000001"]
        if !make.waitForExistence(timeout: 5), create.exists { create.tap() }
        XCTAssertTrue(make.waitForExistence(timeout: 5), app.debugDescription)
        let name = app.descendants(matching: .any).matching(identifier: "care-cat-name").firstMatch
        // The name of a cat without a profile is written on its row's page.
        openToolRow("care-row-name", title: "名前", bottom: "care-preview-open", app: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "むぎ")
        leaveVetPage("名前", app: app)
        // Everyday care is shown from 「この子のこと」; the older tool entry fills
        // it until 「この子のこと」 has meals of its own. 349: one row below the
        // rows that opens the cat; the value itself is read on the made memo.
        let folded = app.descendants(matching: .any)["care-cat-care-fields-folded"].firstMatch
        for _ in 0..<5 where !folded.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(folded.isHittable)
        XCTAssertTrue(folded.label.contains("この子のこと"), folded.label)
        XCTAssertFalse(app.staticTexts["いつものフード 20g"].exists, "The folded row does not repeat the values")
        capture("care-autofill-visible-real-value")
        // 11/8: every cat starts chosen (11/12: in the row 「お願いする猫」).
        openToolRow("care-row-cats", title: "お願いする猫", bottom: "care-preview-open", app: app)
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "care-select-")).firstMatch
        revealCareMemoRow(selected, app: app)
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        XCTAssertEqual(selected.value as? String, "選択済み")
        leaveVetPage("お願いする猫", app: app)
        XCTAssertTrue(make.isEnabled); make.tap()
        XCTAssertTrue(app.navigationBars["できあがり"].waitForExistence(timeout: 5))
        let previewFood = app.staticTexts["いつものフード 20g"]
        for _ in 0..<5 where !previewFood.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(previewFood.isHittable)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "private-")).firstMatch.exists)
        capture("care-autofill-output-without-editing")
        app.terminate()
        // The source changes; the unedited candidate follows it when the memo
        // is opened again, and stays the same memo (no second copy).
        app.launchEnvironment["NEKO_TOOL_REFRESH_PHASE"] = "2"
        app.launch()
        XCTAssertTrue(make.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(create.exists)
        // The refreshed value, read on the made memo (349: the row is folded).
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: make)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        make.tap()
        XCTAssertTrue(app.navigationBars["できあがり"].waitForExistence(timeout: 5))
        let refreshed = app.staticTexts["更新したフード 25g"]
        XCTAssertTrue(refreshed.waitForExistence(timeout: 5))
        for _ in 0..<5 where !refreshed.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(refreshed.isHittable)
        XCTAssertFalse(app.staticTexts["いつものフード 20g"].exists)
        capture("care-refreshed-unedited-candidate")
        app.navigationBars["できあがり"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(make.waitForExistence(timeout: 5))
        // The food is written in 「この子のこと」 now; the filled-in name is the
        // value still edited here. Edit it and check the edit is kept.
        openToolRow("care-row-name", title: "名前", bottom: "care-preview-open", app: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "むぎ")
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Verify app-owned editing/persistence, not the OS selection-menu geometry.
        // An insertion may land at any caret position; it must preserve every
        // original character plus exactly one copy of the entered fragment.
        let entered = "今回の名前"
        name.typeText(entered)
        let edited = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", entered), object: name)
        XCTAssertEqual(XCTWaiter.wait(for: [edited], timeout: 10), .completed, name.value as? String ?? "値なし")
        let editedValue = name.value as? String ?? ""
        XCTAssertEqual(editedValue.replacingOccurrences(of: entered, with: ""), "むぎ")
        XCTAssertEqual(editedValue.count, "むぎ".count + entered.count)
        // Back on the page, so the name is saved as it is everywhere.
        leaveVetPage("名前", app: app)
        // Phase 3 changes both the food and the name in 避難に備える.
        app.launchEnvironment["NEKO_TOOL_REFRESH_PHASE"] = "3"
        app.terminate(); app.launch()
        XCTAssertTrue(make.waitForExistence(timeout: 10), app.debugDescription)
        // The refresh has run once the newer food shows on the made memo; only
        // then is the name compared, so a late overwrite could not pass unnoticed.
        let readyAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: make)
        XCTAssertEqual(XCTWaiter.wait(for: [readyAgain], timeout: 5), .completed)
        make.tap()
        XCTAssertTrue(app.navigationBars["できあがり"].waitForExistence(timeout: 5))
        let newest = app.staticTexts["さらに更新したフード 30g"]
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        app.navigationBars["できあがり"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(make.waitForExistence(timeout: 5))
        openToolRow("care-row-name", title: "名前", bottom: "care-preview-open", app: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, editedValue)
        XCTAssertNotEqual(name.value as? String, "むぎ（避難に備えるで変更）")
        capture("care-autofill-edited-value-restored")
        app.terminate()
    }

    @MainActor
    func testEvacuationAutofillKeepsMealDetailsAndIndependentPhotoAtLargeText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--evacuation-ui-fixture", "--ux-large-text", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_EVACUATION_FIXTURE_KEY"] = UUID().uuidString
        app.launchEnvironment["NEKO_EVACUATION_EMPTY"] = "1"
        app.launchEnvironment["NEKO_EVACUATION_AUTOFILL"] = "1"
        app.launch()
        let open = app.buttons["evacuation-cats-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        // 11/7: 「猫の情報」 opens the first cat in place. The only cat is the one
        // written in 預けるとき, so its page is made from it at once, and the
        // row of cats stays away with a single cat.
        let edit = app.buttons["evacuation-cat-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["evacuation-saved-E0260929-0000-0000-0000-000000000001"].exists)
        // 11/9: the usual photo is taken into 「この子のこと」 as the face photo,
        // and the cat's page shows it; it is kept there (11/11: chosen from here too).
        let photos = app.buttons["evacuation-identifying-photos-face"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<5 where !photos.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertFalse(photos.label.contains("顔の写真、まだありません"), photos.label)
        capture("evacuation-autofill-general-photo-large-text")
        // The meal comes from 「この子のこと」, folded to one row under the steps
        // that opens the cat (349); every line is read on the made memo.
        let folded = app.descendants(matching: .any).matching(identifier: "evacuation-cat-care-fields-folded").firstMatch
        for _ in 0..<9 where !folded.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(folded.isHittable)
        XCTAssertTrue(folded.label.contains("この子のこと"), folded.label)
        capture("evacuation-autofill-visible-values-large-text")
        let preview = app.buttons["evacuation-preview-open"]
        for _ in 0..<8 where !preview.isHittable { app.swipeUp(velocity: .slow) }
        preview.tap()
        XCTAssertTrue(app.navigationBars["むぎの避難メモ"].waitForExistence(timeout: 5), app.debugDescription)
        let food = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "むぎ専用フード")).firstMatch
        for _ in 0..<9 where !food.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(food.isHittable)
        let value = food.label
        XCTAssertTrue(value.contains("朝8時") && value.contains("20g"))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "private-")).firstMatch.exists)
        capture("evacuation-autofill-output-without-editing-large-text")
        app.launchEnvironment["NEKO_TOOL_REFRESH_PHASE"] = "2"
        app.terminate(); app.launch()
        let reopen = app.buttons["evacuation-cats-open"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 10)); reopen.tap()
        // The saved cat's page opens in place again (its own record now).
        let restoredEdit = app.buttons["evacuation-cat-edit"]
        XCTAssertTrue(restoredEdit.waitForExistence(timeout: 10), app.debugDescription)
        let restoredPhotos = app.buttons["evacuation-identifying-photos-face"]
        XCTAssertTrue(restoredPhotos.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(restoredPhotos.label.contains("顔の写真、まだありません"), restoredPhotos.label)
        // After a restart the meal is still there. Later edits happen in
        // 「この子のこと」, which every tool reads, so nothing is copied again.
        let restoredFolded = app.descendants(matching: .any).matching(identifier: "evacuation-cat-care-fields-folded").firstMatch
        for _ in 0..<9 where !restoredFolded.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(restoredFolded.isHittable)
        for _ in 0..<8 where !preview.isHittable { app.swipeUp(velocity: .slow) }
        preview.tap()
        XCTAssertTrue(app.navigationBars["むぎの避難メモ"].waitForExistence(timeout: 5), app.debugDescription)
        let restoredFood = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "むぎ専用フード")).firstMatch
        for _ in 0..<9 where !restoredFood.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(restoredFood.waitForExistence(timeout: 5))
        capture("evacuation-refreshed-candidate-large-text")
        app.terminate()
    }

    /// 11/12: the cats and what to include are each a row's page of
    /// 預けるとき. Brings a control there into view, above the bottom bar
    /// (「お世話メモを作る」) wherever that bar is shown.
    @MainActor
    private func revealCareMemoRow(_ element: XCUIElement, app: XCUIApplication) {
        let bar = app.buttons["care-preview-open"]
        for _ in 0..<8 {
            if element.exists, element.isHittable,
               !bar.exists || element.frame.midY < bar.frame.minY - 24 { return }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }

    @MainActor
    func testCareHandoffSelectionPrivacyAndPDF() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--care-handoff-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_CARE_FIXTURE_KEY"] = UUID().uuidString
        app.launch()
        let boundaries = app.staticTexts["care-boundary-result"]
        XCTAssertTrue(boundaries.waitForExistence(timeout: 10))
        XCTAssertEqual(boundaries.label, "境界検証成功")
        capture("care-handoff-home")
        app.buttons["出力を確認"].tap()
        XCTAssertTrue(app.scrollViews["care-rendered-output"].waitForExistence(timeout: 5))
        capture("care-generated-image")
        app.swipeUp(); capture("care-generated-pdf-last-page")
        app.terminate(); app.launch()
        // 11/12: one page of rows; 「お世話メモを作る」 is its bar's button.
        let preview = app.buttons["care-preview-open"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        // 11/8: the period and the request are written in 「期間とお願い」.
        openToolRow("care-row-request", title: "期間とお願い", bottom: "care-preview-open", app: app)
        XCTAssertTrue(app.descendants(matching: .any)["care-period"].firstMatch.waitForExistence(timeout: 5))
        leaveVetPage("期間とお願い", app: app)
        XCTAssertTrue(preview.isEnabled)
        // 11/8: every cat starts chosen; the one not going is taken out.
        openToolRow("care-row-cats", title: "お願いする猫", bottom: "care-preview-open", app: app)
        let chosenCat = app.buttons["care-select-C0260929-0000-0000-0000-000000000001"]
        let otherCat = app.buttons["care-select-C0260929-0000-0000-0000-000000000002"]
        revealCareMemoRow(otherCat, app: app)
        XCTAssertTrue(chosenCat.waitForExistence(timeout: 5))
        XCTAssertEqual(chosenCat.value as? String, "選択済み")
        XCTAssertEqual(otherCat.value as? String, "選択済み")
        otherCat.tap()
        XCTAssertEqual(otherCat.value as? String, "未選択")
        XCTAssertEqual(chosenCat.value as? String, "選択済み")
        leaveVetPage("お願いする猫", app: app)
        XCTAssertTrue(preview.isEnabled)
        // 11/8: written health and contacts start on; turned off, they stay out.
        openToolRow("care-row-include", title: "載せるもの", bottom: "care-preview-open", app: app)
        let health = app.switches["care-disclose-health"]
        let contacts = app.switches["care-disclose-contacts"]
        revealCareMemoRow(contacts, app: app)
        XCTAssertTrue(health.isHittable)
        XCTAssertEqual(health.value as? String, "1")
        XCTAssertEqual(contacts.value as? String, "1")
        health.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        contacts.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(health.value as? String, "0")
        XCTAssertEqual(contacts.value as? String, "0")
        capture("care-handoff-disclosure")
        leaveVetPage("載せるもの", app: app)
        XCTAssertTrue(preview.isEnabled)
        preview.tap()
        XCTAssertTrue(app.navigationBars["できあがり"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["むぎ"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["そら"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "private-")).firstMatch.exists)
        capture("care-handoff-selected-preview")
        // 11/8: no question first; the share sheet opens at once.
        app.buttons["care-share-pdf"].tap()
        XCTAssertFalse(app.buttons["PDFを作って渡す"].exists)
        XCTAssertTrue(app.otherElements["ShareSheet.RemoteContainerView"].firstMatch.waitForExistence(timeout: 10))
        capture("care-handoff-pdf-share")
        app.terminate()
    }

    @MainActor
    func testEvacuationPackingPersistsAndPrivateFieldsStayOutOfPreview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--evacuation-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_EVACUATION_FIXTURE_KEY"] = UUID().uuidString
        app.launch()
        let boundaries = app.staticTexts["evacuation-boundary-result"]
        XCTAssertTrue(boundaries.waitForExistence(timeout: 10))
        XCTAssertEqual(boundaries.label, "境界検証成功")
        app.buttons["evacuation-packing-open"].tap()
        let supply = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "evacuation-supply-")).firstMatch
        XCTAssertTrue(supply.waitForExistence(timeout: 5))
        let supplyID = supply.identifier
        supply.tap()
        XCTAssertEqual(supply.value as? String, "そろっている")
        XCTAssertTrue(app.staticTexts["evacuation-packing-count"].label.hasPrefix("そろっているもの"))
        capture("evacuation-packing")
        app.terminate()
        app.launch()
        app.buttons["evacuation-packing-open"].tap()
        let restored = app.buttons[supplyID]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertEqual(restored.value as? String, "そろっている")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["evacuation-cats-open"].tap()
        let mugi = app.buttons["evacuation-cat-E0260929-0000-0000-0000-000000000001"]
        XCTAssertTrue(mugi.waitForExistence(timeout: 5))
        mugi.tap()
        let preview = app.buttons["evacuation-preview-open"]
        for _ in 0..<5 where !preview.isHittable { app.swipeUp() }
        preview.tap()
        // The show screen itself (11/8: 「この子のこと」 on the cat's page is
        // folded, so its food line is not what is read here).
        XCTAssertTrue(app.navigationBars["むぎの避難メモ"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["むぎ専用フード"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["非公開の薬メモ"].exists)
        XCTAssertFalse(app.staticTexts["private-contact@example.invalid"].exists)
        XCTAssertFalse(app.staticTexts["そら専用フード"].exists)
        capture("evacuation-cat-private-fields-excluded")
        let share = app.buttons["evacuation-share-pdf"]
        for _ in 0..<6 where !share.isHittable { app.swipeUp() }
        XCTAssertTrue(share.isHittable)
        share.tap()
        // The show screen's 「印刷用のPDF」 asks once before making the file.
        let confirmation = app.buttons["印刷用のPDFを作る"]
        let presented = confirmation.waitForExistence(timeout: 5)
        capture("evacuation-print-confirmation")
        XCTAssertTrue(presented, "The print confirmation must be presented before confirming export")
        confirmation.tap()
        XCTAssertTrue(app.otherElements["ShareSheet.RemoteContainerView"].firstMatch.waitForExistence(timeout: 10))
        capture("evacuation-print-share")
        app.terminate()
    }

    @MainActor
    func testUnpreparedLostCatDraftPreviewsAndCreatesImageAndPDF() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--lost-cat-draft-ui-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_LOST_CAT_DRAFT_FIXTURE_KEY"] = "guest-fixture-\(UUID().uuidString)"
        app.launch()
        XCTAssertTrue(app.buttons["先にすること：探す・届け出る"].waitForExistence(timeout: 5))
        // 11/12, a list of rows: the face photo is in, so the photo row says so,
        // and the bar names only what is still missing.
        XCTAssertTrue(app.staticTexts["探すためのチラシを作ります。"].exists)
        let photoRow = app.buttons["lost-cat-row-photo"]
        XCTAssertTrue(photoRow.waitForExistence(timeout: 5), app.debugDescription)
        let photoValue = photoRow.label + " " + (photoRow.value as? String ?? "")
        XCTAssertTrue(photoValue.contains("顔") && !photoValue.contains("なし"), photoValue)
        let missing = app.staticTexts["tool-make-missing"]
        XCTAssertTrue(missing.waitForExistence(timeout: 5))
        XCTAssertEqual(missing.label, "あと：場所・連絡先")
        XCTAssertFalse(app.buttons["チラシを作る"].isEnabled)
        XCTAssertFalse(app.buttons["日時と場所を消す"].exists)
        // Each text is on its row's page; a field is reached by opening its
        // row from the list (and leaving the page that is open).
        let pages = ["lost-cat-name": ("lost-cat-row-name", "名前"),
                     "lost-cat-features": ("lost-cat-row-features", "見分ける特徴"),
                     "lost-cat-place": ("lost-cat-row-place", "最後に見かけた場所"),
                     "lost-cat-contact": ("lost-cat-row-contact", "連絡先"),
                     "lost-cat-identifying-photos": ("lost-cat-row-photo", "写真")]
        var openPage: String?
        func backToList() {
            guard let page = openPage else { return }
            leaveVetPage(page, app: app)
            openPage = nil
        }
        func field(_ name: String) -> XCUIElement {
            let element = app.descendants(matching: .any).matching(identifier: name).firstMatch
            guard let target = pages[name] else {
                XCTFail("No row opens \(name)")
                return element
            }
            let (row, title) = target
            if openPage != title {
                backToList()
                openToolRow(row, title: title, bottom: "チラシを作る", app: app)
                openPage = title
            }
            XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
            return element
        }
        // The pages have the same way to put the keyboard away as the list
        // (11/8, #872); then back to the list, where 「チラシを作る」 is.
        func closeKeyboard() {
            let keyboard = app.keyboards.firstMatch
            guard keyboard.exists else { return }
            let close = app.buttons["キーボードを閉じる"]
            XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription); close.tap()
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        }
        func makeFlyer() {
            closeKeyboard()
            backToList()
            let make = app.buttons["チラシを作る"]
            XCTAssertTrue(make.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(make.isEnabled)
            make.tap()
        }
        /// 11/12: the cat is chosen from the menu in the bar; its items are
        /// named as the row's chips were.
        func chooseCat(_ key: String) {
            let menu = app.buttons["lost-cat-menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 8), app.debugDescription); menu.tap()
            let item = app.buttons["lost-cat-saved-\(key)"]
            XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription); item.tap()
            XCTAssertTrue(item.waitForNonExistence(timeout: 5))
            openPage = nil
        }
        for (name, value) in [("lost-cat-name", "むぎ"),
                              ("lost-cat-place", "駅の近く"),
                              ("lost-cat-contact", "08000000000")] {
            let input = field(name); input.tap(); input.typeText(value)
        }
        makeFlyer()
        let preview = app.buttons["共有する迷子の猫の画像"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        // An unknown day is left out; the post ends with the hashtags.
        let postText = preview.value as? String ?? ""
        XCTAssertFalse(postText.contains("日時"))
        XCTAssertFalse(postText.contains("不明"))
        XCTAssertTrue(postText.hasSuffix("#迷子猫 #迷い猫"))
        XCTAssertTrue(app.navigationBars["できあがり"].exists)
        capture("lost-cat-social-one-photo")
        for action in ["lost-cat-share-image", "lost-cat-share-pdf"] {
            if action == "lost-cat-share-pdf" { app.buttons["A4チラシ"].tap() }
            capture("lost-cat-layout-\(action)")
            let button = app.buttons[action]
            XCTAssertTrue(button.isHittable, action)
            button.tap()
            let sheet = app.otherElements["ShareSheet.RemoteContainerView"].firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 10), action)
            let close = sheet.buttons["header.closeButton"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: sheet
            )], timeout: 5), .completed)
        }
        app.terminate(); app.launch()
        openPage = nil
        XCTAssertTrue(app.buttons["lost-cat-row-name"].waitForExistence(timeout: 5))
        XCTAssertEqual(field("lost-cat-name").value as? String, "むぎ")
        XCTAssertEqual(field("lost-cat-place").value as? String, "駅の近く")
        XCTAssertEqual(field("lost-cat-contact").value as? String, "08000000000")
        // Long input must not be lost or prevent the user from seeing what to fix.
        let overLimit = String(repeating: "茶", count: 201)
        let features = field("lost-cat-features")
        features.tap(); features.typeText(overLimit)
        XCTAssertEqual(features.value as? String, overLimit)
        closeKeyboard()
        backToList()
        // The row to fix says what to do, in red, on the list.
        let featuresRow = app.buttons["lost-cat-row-features"]
        XCTAssertTrue(featuresRow.waitForExistence(timeout: 5))
        XCTAssertTrue((featuresRow.label + " " + (featuresRow.value as? String ?? "")).contains("200文字まで"),
                      featuresRow.debugDescription)
        XCTAssertTrue(app.staticTexts["直すところがあります。赤い文字の欄を見てください"].exists)
        makeFlyer()
        XCTAssertTrue(app.buttons["lost-cat-edit-text"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["lost-cat-share-image"].isEnabled)
        XCTAssertTrue(app.staticTexts["見分ける特徴は200文字までです。あと1文字減らしてください。"].exists)
        capture("lost-cat-over-limit-keeps-original")
        app.terminate(); app.launch()
        openPage = nil
        XCTAssertTrue(app.buttons["lost-cat-row-features"].waitForExistence(timeout: 5))
        XCTAssertEqual(field("lost-cat-features").value as? String, overLimit)
        let restoredFeatures = field("lost-cat-features")
        // A tap after relaunch doesn't promise a caret at the end. Select the
        // existing text explicitly, as a user replacing the description would.
        restoredFeatures.tap()
        restoredFeatures.press(forDuration: 1.2)
        let selectAll = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["すべてを選択", "Select All"])
        ).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        restoredFeatures.typeText(String(repeating: "茶", count: 200))
        XCTAssertEqual((restoredFeatures.value as? String)?.count, 200)
        makeFlyer()
        XCTAssertTrue(app.buttons["共有する迷子の猫の画像"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["lost-cat-share-image"].isEnabled)
        app.buttons["A4チラシ"].tap()
        XCTAssertTrue(app.buttons["lost-cat-share-pdf"].isEnabled)
        app.terminate()
        // Exercise the production saved-cat entry and real editable candidates,
        // not a separately drawn mock screen. Same-named cats keep separate IDs.
        app.launchEnvironment["NEKO_LOST_CAT_SAVED_INFO"] = "1"
        app.launchEnvironment["NEKO_LOST_CAT_DRAFT_FIXTURE_KEY"] = "guest-reuse-\(UUID().uuidString)"
        app.launchArguments.append("--ux-large-text")
        app.launch()
        XCTAssertTrue(app.staticTexts["lost-cat-model-checks-passed"].waitForExistence(timeout: 8))
        let firstKey = "guest-tool-AAAA0000-0000-4000-8000-000000000001"
        let otherKey = "guest-tool-AAAA0000-0000-4000-8000-000000000002"
        chooseCat(firstKey)
        XCTAssertEqual(field("lost-cat-name").value as? String, "むぎ")
        // 11/9 (#900): a tool's saved cat has 「この子のこと」, so its face photo
        // (still filled from the saved record) is shown here, not chosen here.
        _ = field("lost-cat-identifying-photos")
        let savedFace = app.descendants(matching: .any).matching(identifier: "lost-cat-identifying-photos-face").firstMatch
        XCTAssertTrue(savedFace.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(savedFace.label, "顔の写真")
        XCTAssertFalse(app.buttons["lost-cat-face-actions"].exists)
        XCTAssertEqual(field("lost-cat-features").value as? String, "茶白・しっぽが長い")
        capture("lost-cat-saved-candidates-large-text")
        app.terminate()
        app.launchEnvironment["NEKO_TOOL_REFRESH_PHASE"] = "2"
        app.launch()
        chooseCat(firstKey)
        XCTAssertEqual(field("lost-cat-features").value as? String, "茶白・右耳に印・しっぽが長い")
        capture("lost-cat-refreshed-candidate-large-text")
        let candidateFeatures = field("lost-cat-features")
        let refreshedFeatures = candidateFeatures.value as? String ?? ""
        candidateFeatures.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // At this large text the system edit menu put 「すべてを選択」 out of
        // view (old run: not found). Verify the app's editing, not the OS menu:
        // hold to pick up the caret, drag it past the end of the text, and
        // delete the whole candidate, as a person replacing it would.
        let focusedFeatures = field("lost-cat-features")
        focusedFeatures.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2,
            thenDragTo: focusedFeatures.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 1.0)))
        focusedFeatures.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: refreshedFeatures.count))
        candidateFeatures.typeText("茶白・右耳に小さな傷")
        XCTAssertEqual(candidateFeatures.value as? String, "茶白・右耳に小さな傷")
        let contact = field("lost-cat-contact")
        XCTAssertFalse((contact.value as? String ?? "").contains("非公開"))
        contact.tap(); contact.typeText("public@example.test")
        let place = field("lost-cat-place")
        XCTAssertFalse((place.value as? String ?? "").contains("非公開"))
        place.tap(); place.typeText("公園の近く")
        makeFlyer()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let publicText = preview.value as? String ?? ""
        XCTAssertTrue(publicText.contains("茶白・右耳に小さな傷"))
        XCTAssertTrue(publicText.contains("public@example.test"))
        XCTAssertFalse(publicText.contains("非公開"))
        capture("lost-cat-saved-candidates-public-preview")
        app.launchEnvironment["NEKO_TOOL_REFRESH_PHASE"] = "3"
        app.terminate(); app.launch()
        chooseCat(firstKey)
        XCTAssertEqual(field("lost-cat-features").value as? String, "茶白・右耳に小さな傷")
        capture("lost-cat-edited-candidate-restored")
        app.terminate(); app.launch()
        chooseCat(otherKey)
        // Shown from 「この子のこと」 now (#900): its face stays empty.
        _ = field("lost-cat-identifying-photos")
        let otherFace = app.descendants(matching: .any).matching(identifier: "lost-cat-identifying-photos-face").firstMatch
        XCTAssertTrue(otherFace.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(otherFace.label, "顔の写真、まだありません",
            "A photo marked as including the owner must not become a public candidate")
        XCTAssertEqual(field("lost-cat-features").value as? String, "黒猫・短いしっぽ")
        app.terminate()
    }

    @MainActor
    func testLostCatDraftOffersThisCatsPhotosBeforeEntireLibrary() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--lost-cat-draft-ui-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        // A registered cat, as in the app: its profile identifier is a UUID,
        // so it has 「この子のこと」 (the fixture names the profile by this key).
        app.launchEnvironment["NEKO_LOST_CAT_DRAFT_FIXTURE_KEY"] = UUID().uuidString
        app.launchEnvironment["NEKO_LOST_CAT_HAS_CONFIRMED_PHOTO"] = "1"
        app.launchEnvironment["NEKO_LOST_CAT_PREPARED_PHOTOS"] = "1"
        app.launchEnvironment["NEKO_LOST_CAT_LONG_TEXT"] = "1"
        app.launch()
        // 11/9 (#900): a registered cat's face and body photos are kept once,
        // in 「この子のこと」. 11/11: a photo here opens the same chooser as
        // there; a link opens that page. There is no second picker of the
        // tool's own. The draft's earlier photos are shown (and copied into
        // 「この子のこと」 once). 11/12: they are on the page of the row 「写真」,
        // which says a face photo is in.
        let photoRow = app.buttons["lost-cat-row-photo"]
        XCTAssertTrue(photoRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue((photoRow.label + " " + (photoRow.value as? String ?? "")).contains("顔"), photoRow.debugDescription)
        openToolRow("lost-cat-row-photo", title: "写真", bottom: "チラシを作る", app: app)
        let shown = app.descendants(matching: .any).matching(identifier: "lost-cat-identifying-photos").firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["lost-cat-face-photo"].exists, "The tool must not offer a second photo picker")
        let toolFace = app.descendants(matching: .any).matching(identifier: "lost-cat-identifying-photos-face").firstMatch
        let toolBody = app.descendants(matching: .any).matching(identifier: "lost-cat-identifying-photos-body").firstMatch
        XCTAssertEqual(toolFace.label, "顔の写真")
        XCTAssertEqual(toolBody.label, "全身の写真")
        capture("lost-cat-editor")
        leaveVetPage("写真", app: app)
        openToolRow("lost-cat-row-features", title: "見分ける特徴", bottom: "チラシを作る", app: app)
        let features = app.descendants(matching: .any).matching(identifier: "lost-cat-features").firstMatch
        XCTAssertTrue(features.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<5 where !features.isHittable { app.swipeUp() }
        XCTAssertEqual((features.value as? String)?.count, 200)
        XCTAssertGreaterThan(features.frame.width, app.frame.width * 0.65)
        capture("lost-cat-long-text-editor")
        // The page puts the cursor in the field; put the keyboard away, then back.
        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 2) {
            app.buttons["キーボードを閉じる"].tap()
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        }
        leaveVetPage("見分ける特徴", app: app)
        app.buttons["チラシを作る"].tap()
        XCTAssertTrue(app.buttons["共有する迷子の猫の画像"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["lost-cat-share-image"].isEnabled)
        capture("lost-cat-two-aspect-social")
        app.buttons["A4チラシ"].tap()
        XCTAssertTrue(app.buttons["lost-cat-share-pdf"].isEnabled)
        capture("lost-cat-two-aspect-paper")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // 11/11: the tool's face photo opens 「この子のこと」's own chooser in place:
        // this cat's photos first and 写真アプリ, nothing else.
        openToolRow("lost-cat-row-photo", title: "写真", bottom: "チラシを作る", app: app)
        let toolFaceButton = app.buttons["lost-cat-identifying-photos-face"]
        XCTAssertTrue(toolFaceButton.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<5 where !toolFaceButton.isHittable { app.swipeDown() }
        toolFaceButton.tap()
        let toolCandidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "cat-care-photo-candidate-"))
        XCTAssertTrue(toolCandidates.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(toolCandidates.count, 1)
        XCTAssertTrue(app.buttons["cat-care-photo-system"].exists)
        app.buttons["キャンセル"].tap()
        XCTAssertTrue(toolCandidates.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(toolFaceButton.exists, app.debugDescription)
        // Taking off and cropping stay in 「この子のこと」, one link away.
        let openCatCare = app.buttons["lost-cat-identifying-photos-open-cat-care"]
        for _ in 0..<5 where !openCatCare.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertEqual(openCatCare.label, "「この子のこと」を開く")
        openCatCare.tap()
        // 「この子のこと」: this cat's photos come first; any iPhone photo is a
        // visible button (写真アプリ). The other cats' photos are not listed.
        let face = app.buttons["cat-care-photo-face"]
        XCTAssertTrue(face.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<5 where !face.isHittable { app.swipeUp(velocity: .slow) }
        face.tap()
        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "cat-care-photo-candidate-"))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(candidates.count, 1)
        let system = app.buttons["cat-care-photo-system"]
        XCTAssertTrue(system.exists)
        XCTAssertEqual(system.label, "写真アプリから選ぶ")
        XCTAssertFalse(app.segmentedControls.firstMatch.exists)
        capture("lost-cat-app-cat-photos")
        app.buttons["キャンセル"].tap()
        XCTAssertTrue(candidates.firstMatch.waitForNonExistence(timeout: 5))
        // Cutting and taking a photo off are done here too.
        let faceActions = app.buttons["cat-care-photo-actions-face"]
        XCTAssertTrue(faceActions.waitForExistence(timeout: 5), app.debugDescription)
        faceActions.tap(); app.buttons["切り取る"].tap()
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 3))
        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0.25)
        capture("lost-cat-photo-crop")
        app.buttons["この範囲を使う"].tap()
        XCTAssertTrue(app.sliders.firstMatch.waitForNonExistence(timeout: 5))
        let bodyActions = app.buttons["cat-care-photo-actions-body"]
        XCTAssertTrue(bodyActions.waitForExistence(timeout: 5), app.debugDescription)
        bodyActions.tap(); app.buttons["全身の写真を外す"].tap()
        XCTAssertTrue(bodyActions.waitForNonExistence(timeout: 5))
        XCTAssertTrue(faceActions.exists)
        app.terminate(); app.launch()
        // The tool follows 「この子のこと」 after a restart: the face stays, the
        // body photo that was taken off is not brought back from the draft.
        openToolRow("lost-cat-row-photo", title: "写真", bottom: "チラシを作る", app: app)
        XCTAssertTrue(shown.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(toolFace.label, "顔の写真")
        XCTAssertEqual(toolBody.label, "全身の写真、まだありません")
        app.terminate()
    }

    @MainActor
    func testLostCatPhotoTapSelectsOnlyTheTappedCandidate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--lost-cat-draft-ui-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_LOST_CAT_PICKER_TAP_FIXTURE"] = "1"
        app.launch()
        let candidates = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "lost-cat-candidate-"))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(candidates.count, 3)
        let identifiers = (0..<3).map { candidates.element(boundBy: $0).identifier }
        var expected: [String] = []
        for index in [0, 1, 2, 0] {
            let button = app.buttons[identifiers[index]]
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            expected.append(String(identifiers[index].dropFirst("lost-cat-candidate-".count)))
            let log = app.staticTexts["lost-cat-picker-selection-log"]
            XCTAssertTrue(log.waitForExistence(timeout: 5))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", expected.joined(separator: ",")),
                object: log
            )], timeout: 5), .completed,
                "One physical tap must request only its photo; actual: \(log.label)")
        }
        capture("lost-cat-picker-independent-photo-taps")
        app.terminate()
    }

    @MainActor
    func testToolsReplaceAlbumShowcaseEntryAtStandardAndLargeText() {
        for appearance in ["dark", "light", "large"] {
            let largeText = appearance == "large"
            let app = XCUIApplication()
            // Acceptance scenarios use a separate two-tab harness; this opens MainTabView.
            // The harness has no cats; its tools start from empty records, not
            // from memos other UI tests left on this Simulator (a leftover
            // 預けるとき memo opened its page instead of 「猫を追加」).
            app.launchArguments = ["--app-store-screenshot-fixture", "--isolated-app-records",
                                   "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
                + (largeText ? ["--ux-large-text"] : [])
                + [appearance == "dark" ? "--tools-hub-dark" : "--tools-hub-light"]
            app.launch()
            XCTAssertFalse(app.buttons["albums-showcase-open"].exists)
            let identified = app.buttons["main-tab-tools"]
            let tab = identified.exists ? identified : app.tabBars.buttons["この子"]
            XCTAssertTrue(tab.waitForExistence(timeout: 10))
            tab.tap()
            // 11/12 (この子): this harness has no cat, so the page is のわ,
            // 「この子を追加」 and the two tools for the whole home; the
            // per-cat tools open from a cat's page once a cat is added.
            XCTAssertTrue(app.buttons["cat-home-add"].waitForExistence(timeout: 5), app.debugDescription)
            let showcase = app.buttons["tools-showcase-open"]
            let evacuation = app.buttons["tools-evacuation-open"]
            XCTAssertTrue(showcase.waitForExistence(timeout: 5))
            if largeText {
                // At the accessibility sizes のわ, the sentence and the button
                // fill the first screen; the rows are under it, one swipe down.
                for _ in 0..<3 where !showcase.isHittable { app.swipeUp() }
            }
            XCTAssertTrue(showcase.isHittable)
            XCTAssertTrue(showcase.label.contains("写真を見せる"))
            XCTAssertFalse(app.buttons["tools-showcase-edit"].exists)
            for id in ["tools-care-open", "tools-vet-open", "tools-lost-cat-open"] {
                XCTAssertFalse(app.buttons[id].exists, "No per-cat tool without a cat: " + id)
            }
            XCTAssertTrue(app.buttons["tools-settings-button"].exists)
            if largeText {
                // The accessibility sizes list the tools as rows, one under the other.
                XCTAssertGreaterThan(showcase.frame.minY, evacuation.frame.minY)
                XCTAssertEqual(showcase.frame.width, evacuation.frame.width, accuracy: 1)
            } else {
                // Round buttons of one size, side by side.
                XCTAssertEqual(showcase.frame.width, evacuation.frame.width, accuracy: 1)
                XCTAssertEqual(showcase.frame.minY, evacuation.frame.minY, accuracy: 1)
                XCTAssertGreaterThan(showcase.frame.minX, evacuation.frame.minX)
                let visibleBottom = app.tabBars.firstMatch.frame.minY
                for entrance in [showcase, evacuation] {
                    XCTAssertTrue(entrance.isHittable, "Every standard-size entrance starts visible")
                    XCTAssertLessThanOrEqual(entrance.frame.maxY, visibleBottom + 1,
                        "Partial visibility is insufficient for an entrance")
                }
            }
            capture("tools-hub-\(appearance)")
            // 避難 is the row above 見せる: back down if the swipe took it past the top.
            for _ in 0..<5 where !evacuation.isHittable {
                if evacuation.frame.midY < app.frame.midY { app.swipeDown() } else { app.swipeUp() }
            }
            XCTAssertTrue(evacuation.isHittable)
            evacuation.tap()
            XCTAssertTrue(app.buttons["evacuation-packing-open"].waitForExistence(timeout: 5))
            capture("tools-entry-\(appearance)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(evacuation.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testShowcasePickerOffersOnlyCatPhotoCandidates() {
        let app = XCUIApplication()
        // The fixture has eight detected-cat photos and nine additional
        // favorites. Favorites alone must not become showcase candidates.
        app.launchArguments = ["--app-store-screenshot-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "cats"
        app.launch()
        let toolsTab = app.tabBars.buttons["この子"]
        XCTAssertTrue(toolsTab.waitForExistence(timeout: 10))
        toolsTab.tap()
        let showcase = app.buttons["tools-showcase-open"]
        XCTAssertTrue(showcase.waitForExistence(timeout: 10))
        showcase.tap()
        // 11/7: the cat is chosen on the show screen only; the edit screen edits its set.
        let scope = app.buttons["showcase-gallery-scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.tap()
        app.buttons["ミケ"].tap()
        XCTAssertTrue(scope.label.contains("ミケ"))
        // Choosing a cat may fill its set by recommendation; let that settle.
        _ = app.buttons.matching(identifier: "showcase-gallery-photo").firstMatch.waitForExistence(timeout: 5)
        // 11/12 (round 2): 「編集」 shows once photos are chosen; before that,
        // the empty screen's 「写真を選ぶ」 opens the same sheet.
        let edit = app.buttons["showcase-gallery-edit"]
        if edit.waitForExistence(timeout: 5) {
            edit.tap()
        } else {
            let select = app.buttons["showcase-gallery-select"]
            XCTAssertTrue(select.waitForExistence(timeout: 5), app.debugDescription)
            select.tap()
        }
        XCTAssertTrue(app.staticTexts["showcase-preparation-cat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["showcase-preparation-cat"].label.contains("ミケ"))
        XCTAssertFalse(app.buttons["showcase-scope-picker"].exists)
        // 11/8: no 「表紙」 label; every kept photo reads 「見せる写真」.
        let kept = app.buttons.matching(NSPredicate(format: "label == %@", "見せる写真")).count
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "表紙")).count, 0)
        let select = app.buttons["showcase-preparation-select"]
        let add = app.buttons["showcase-preparation-add"]
        XCTAssertTrue(select.waitForExistence(timeout: 5) || add.exists)
        (select.exists ? select : add).tap()
        let candidate = app.buttons.matching(identifier: "showcase-candidate-photo").firstMatch
        let hasCandidate = candidate.waitForExistence(timeout: 5)
        capture("showcase-cat-candidates")
        XCTAssertTrue(hasCandidate)
        // All eight detected-cat photos, less the ones already in this cat's set.
        XCTAssertEqual(app.buttons.matching(identifier: "showcase-candidate-photo").count, 8 - kept)
        let secondCandidate = app.buttons.matching(identifier: "showcase-candidate-photo").element(boundBy: 1)
        for (index, element) in [candidate, secondCandidate].enumerated() {
            XCTAssertTrue(element.label.contains("\(index + 1)枚目"))
        }
        XCTAssertNotEqual(candidate.label, secondCandidate.label)
        // Only one is assigned to this cat. Manual selection still offers the
        // unassigned cat photos, but never the fixture's non-cat favorites.
        XCTAssertEqual(candidate.frame.width, candidate.frame.height, accuracy: 1)
    }

    @MainActor
    func testShowcaseOpensSquareGalleryAndReturnsWithoutAuthentication() {
        for largeText in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--app-store-screenshot-fixture", "--showcase-gallery-ui-fixture",
                                   "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
                + (largeText ? ["--ux-large-text"] : [])
            app.launch()
            let tools = app.tabBars.buttons["この子"]
            XCTAssertTrue(tools.waitForExistence(timeout: 10))
            tools.tap()
            app.buttons["tools-showcase-open"].tap()
            let cells = app.buttons.matching(identifier: "showcase-gallery-photo")
            let hasPhotos = cells.firstMatch.waitForExistence(timeout: 5)
            capture("showcase-gallery-\(largeText ? "large" : "standard")")
            XCTAssertTrue(hasPhotos)
            // 11/8: three columns at every text size, so the nine stay one 3×3 picture.
            XCTAssertEqual(cells.count, 9)
            XCTAssertEqual(cells.element(boundBy: 2).frame.minY, cells.element(boundBy: 0).frame.minY, accuracy: 1)
            XCTAssertGreaterThan(cells.element(boundBy: 3).frame.minY, cells.element(boundBy: 0).frame.minY)
            let first = cells.element(boundBy: 0).frame
            let second = cells.element(boundBy: 1).frame
            XCTAssertEqual(first.width, first.height, accuracy: 1)
            XCTAssertEqual(first.width, second.width, accuracy: 1)
            XCTAssertEqual(first.minY, second.minY, accuracy: 1)
            // 11/8 (4cf0c2b8): a tight 3pt gap, so the nine read as one picture
            // (ShowcasePhotoView.gallery: GridItem spacing 3) at every text size.
            XCTAssertEqual(second.minX - first.maxX, 3, accuracy: 0.5)
            XCTAssertEqual(cells.element(boundBy: 3).frame.minY - first.maxY, 3, accuracy: 0.5)
            cells.element(boundBy: 1).tap()
            // 「2 / 9」 on screen is read out as 「9枚中2枚目」 (99a78596, 10/20).
            XCTAssertTrue(app.staticTexts["9枚中2枚目"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.images["showcase-detail-photo"].exists)
            app.buttons["写真の一覧に戻る"].tap()
            XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 5))
            app.buttons["閉じる"].tap()
            XCTAssertTrue(app.buttons["tools-showcase-open"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testShowcaseGalleryKeepsSelectedCatThroughDetailAndEditing() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-screenshot-fixture", "--showcase-gallery-ui-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "cats"
        app.launch()
        let tools = app.tabBars.buttons["この子"]
        XCTAssertTrue(tools.waitForExistence(timeout: 10))
        tools.tap()
        let showcase = app.buttons["tools-showcase-open"]
        if !showcase.waitForExistence(timeout: 5) {
            // Simulator startup may still be restoring the Album tab.
            // Retry only when the requested tab was not selected.
            XCTAssertFalse(tools.isSelected)
            tools.tap()
        }
        XCTAssertTrue(showcase.waitForExistence(timeout: 10))
        // 11/13: 写真を見せる opens for the この子 page's cat (the one place the
        // cat is chosen). The page is chosen here, so the stored page from an
        // earlier test does not decide the result.
        // 11/14: by swiping (the round menu shows only from five cats), until
        // the cat's 「この子のこと」 row is on the page on screen.
        func choosePage(_ identifier: String) {
            let row = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier IN %@", ["tools-cat-" + identifier, "tools-family-cat-" + identifier])).firstMatch
            _ = app.descendants(matching: .any)["cat-home-hero"].firstMatch.waitForExistence(timeout: 10)
            var found = row.waitForExistence(timeout: 2)
            let add = app.buttons["cat-home-add"]
            for _ in 0..<13 where !found && !add.exists {
                app.swipeLeft()
                found = row.waitForExistence(timeout: 2)
            }
            for _ in 0..<13 where !found {
                app.swipeRight()
                found = row.waitForExistence(timeout: 2)
            }
            XCTAssertTrue(found, app.debugDescription)
        }
        choosePage("fixture-cat-1")
        showcase.tap()
        let scope = app.buttons["showcase-gallery-scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        // 11/8: a cat, never すべての猫; here the page's cat.
        XCTAssertFalse(scope.label.contains("すべての猫"))
        XCTAssertTrue(scope.label.contains("ソラ"), scope.label)
        app.buttons.matching(identifier: "showcase-gallery-photo").firstMatch.tap()
        app.buttons["写真の一覧に戻る"].tap()
        XCTAssertTrue(scope.label.contains("ソラ"))
        let edit = app.buttons["showcase-gallery-edit"]
        XCTAssertTrue(edit.label.contains("編集"))
        edit.tap()
        // 11/7: the edit screen edits the chosen cat's set and has no cat picker of its own.
        let editingCat = app.staticTexts["showcase-preparation-cat"]
        XCTAssertTrue(editingCat.waitForExistence(timeout: 5))
        XCTAssertTrue(editingCat.label.contains("ソラ"))
        XCTAssertFalse(app.buttons["showcase-scope-picker"].exists)
        // 「完了」 returns to the same show screen; no second one is stacked on it.
        app.buttons["showcase-preparation-done"].tap()
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        XCTAssertTrue(scope.label.contains("ソラ"))
        XCTAssertEqual(app.buttons.matching(identifier: "showcase-gallery-scope").count, 1)
        app.buttons["閉じる"].tap()
        // Another page, another cat: the page decides, not the set shown last.
        choosePage("fixture-cat-0")
        app.buttons["tools-showcase-open"].tap()
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        XCTAssertTrue(scope.label.contains("ミケ"), scope.label)
        app.buttons["閉じる"].tap()
        choosePage("fixture-cat-1")
        app.buttons["tools-showcase-open"].tap()
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        XCTAssertTrue(scope.label.contains("ソラ"), scope.label)
    }

    @MainActor
    func testManagedPreservationMembershipLinkConsentAndRetry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--managed-preservation-membership-ui-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        func tap(_ identifier: String, towardBottom: Bool = false) {
            let button = app.buttons.matching(identifier: identifier).firstMatch
            // List rows below the viewport are virtualized. Scroll before
            // requiring the export action to exist in the accessibility tree.
            if towardBottom {
                for _ in 0..<8 where !button.isHittable { app.swipeUp() }
            } else {
                XCTAssertTrue(button.waitForExistence(timeout: 8), identifier)
                for _ in 0..<8 where !button.isHittable { app.swipeDown() }
            }
            XCTAssertTrue(button.waitForExistence(timeout: 8), identifier)
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: button)
            // After the system share sheet closes, the list can stay disabled
            // for a few seconds on a busy hosted Simulator (11/8 run 42507589058:
            // the row was on screen but not yet enabled and hittable at 5 s). Same condition.
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, identifier)
            button.tap()
        }
        tap("preservation-membership-check")
        tap("preservation-membership-connect")
        let confirm = app.buttons.matching(identifier: "preservation-membership-confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        capture("preservation-membership-explicit-consent")
        let cancel = app.buttons["キャンセル"].firstMatch
        if cancel.exists { cancel.tap() }
        else {
            // iOS 26 renders this as a popover: the system omits the cancel
            // row and exposes the outside dismissal region instead.
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismissRegion.waitForExistence(timeout: 5))
            dismissRegion.tap()
        }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["preservation-membership-connect"].exists)
        tap("preservation-membership-connect")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        tap("preservation-membership-confirm")
        let failure = app.staticTexts["preservation-error"]
        XCTAssertTrue(failure.waitForExistence(timeout: 8))
        tap("preservation-membership-check")
        tap("preservation-membership-connect")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        tap("preservation-membership-confirm")
        XCTAssertTrue(app.descendants(matching: .any)["preservation-membership-linked"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["preservation-membership-ready"].firstMatch.exists)
        let usage = app.staticTexts["preservation-usage-summary"]
        for _ in 0..<4 where !usage.exists { app.swipeUp() }
        XCTAssertTrue(usage.waitForExistence(timeout: 8))
        XCTAssertTrue(usage.label.contains("使用中"))
        XCTAssertTrue(usage.label.contains("5 GB"), usage.label)
        XCTAssertFalse(app.staticTexts["preservation-record-usage"].exists,
                       "Internal storage pieces must not be presented as a user's photo or copy count")
        capture("preservation-membership-expired-read-available")
        tap("preservation-export-all", towardBottom: true)
        cancelRecordExportSheet(app, screenshot: "preservation-all-export-system-sheet")
        XCTAssertFalse(app.staticTexts["record-export-error"].exists)
        let record = app.buttons["preservation-record-a1223334-5556-4788-9990-aabbccddeeff"]
        for _ in 0..<8 where !record.exists { app.swipeUp() }
        tap("preservation-record-a1223334-5556-4788-9990-aabbccddeeff", towardBottom: true)
        let memo = app.textViews["保存したメモ"]
        XCTAssertTrue(memo.waitForExistence(timeout: 8))
        XCTAssertEqual(memo.value as? String, "はじめて膝で眠った日")
        XCTAssertTrue(app.buttons["この記録を書き出す"].exists)
        capture("preservation-membership-expired-record-detail")
        app.terminate()

        // Exercise the shipping pause UI before an expiring export session.
        // Apple authentication itself remains a person-owned device operation.
        app.launchArguments += ["--preservation-export-reauthentication-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["preservation-membership-connect"].waitForExistence(timeout: 15))
        tap("preservation-export-all", towardBottom: true)
        let reauthentication = app.staticTexts["preservation-export-reauthentication"]
        XCTAssertTrue(reauthentication.waitForExistence(timeout: 8))
        for _ in 0..<4 where !reauthentication.isHittable { app.swipeDown() }
        XCTAssertTrue(reauthentication.isHittable)
        let prepareReauthentication = app.buttons["preservation-export-prepare-reauthentication"]
        XCTAssertTrue(prepareReauthentication.exists)
        XCTAssertTrue(prepareReauthentication.isEnabled)
        XCTAssertFalse(app.buttons["preservation-record-a1223334-5556-4788-9990-aabbccddeeff"].exists)
        XCTAssertFalse(app.buttons["preservation-export-all"].exists)
        capture("preservation-export-reauthentication")
        tap("preservation-export-prepare-reauthentication")
        XCTAssertTrue(app.buttons["preservation-export-signin"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["preservation-export-signin"].isEnabled)
        capture("preservation-export-reauthentication-prepared")
        tap("preservation-export-cancel-reauthentication", towardBottom: true)
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: reauthentication)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["record-export-error"].exists)
        XCTAssertTrue(app.buttons["Appleでサインイン"].waitForExistence(timeout: 5))
        capture("preservation-export-reauthentication-cancelled")
        app.terminate()
    }

    @MainActor
    func testManagedPreservationAccountDeletionRetainsReceiptAndCompletes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--managed-preservation-membership-ui-fixture",
            "--preservation-account-deletion-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        func tap(_ label: String) {
            let button = app.buttons.matching(identifier: label).firstMatch
            for _ in 0..<10 where !button.isHittable { app.swipeUp() }
            XCTAssertTrue(button.waitForExistence(timeout: 8), label)
            XCTAssertTrue(button.isHittable, label)
            button.tap()
        }
        // 11/8: the deletion screen is one sentence and the button, not the account screen.
        XCTAssertTrue(app.buttons["preservation-account-delete"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["preservation-membership-connect"].exists)
        tap("preservation-account-delete")
        XCTAssertTrue(app.buttons["preservation-account-delete-confirm"].waitForExistence(timeout: 5))
        capture("preservation-account-delete-confirmation")
        let cancel = app.buttons["キャンセル"].firstMatch
        if cancel.exists { cancel.tap() }
        else {
            // iOS 26 presents this confirmation as a popover. Its native
            // dismissal region replaces the separate cancel row.
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismissRegion.waitForExistence(timeout: 5))
            dismissRegion.tap()
        }
        let confirmation = app.buttons.matching(identifier: "preservation-account-delete-confirm").firstMatch
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: confirmation)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["届いたか確かめる"].exists)
        tap("preservation-account-delete")
        tap("preservation-account-delete-confirm")
        XCTAssertTrue(app.buttons["届いたか確かめる"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["自動保存のアカウントを削除しました"].exists)
        capture("preservation-account-delete-response-lost")
        tap("届いたか確かめる")
        XCTAssertTrue(app.staticTexts["アカウントを削除しています"].waitForExistence(timeout: 8))
        tap("削除状況を確認")
        XCTAssertTrue(app.staticTexts["自動保存のアカウントを削除しました"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["preservation-account-delete"].exists)
        capture("preservation-account-delete-completed")
        app.terminate()
    }

    @MainActor
    func testManagedPreservationLostCopyResultShowsConfirmationAndStoredState() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--managed-preservation-membership-ui-fixture", "--preservation-copy-result-ui-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        func tap(_ identifier: String, scrollUp: Bool = true) {
            let button = app.buttons.matching(identifier: identifier).firstMatch
            for _ in 0..<10 where !button.isHittable {
                if scrollUp { app.swipeUp() } else { app.swipeDown() }
            }
            XCTAssertTrue(button.waitForExistence(timeout: 8), identifier)
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, identifier)
            button.tap()
        }
        XCTAssertTrue(app.switches["内容を確認して、保存に同意する"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["preservation-membership-check"].exists,
                       "A selected copy must check eligibility without a manual membership action.")
        XCTAssertFalse(app.buttons["preservation-membership-connect"].exists)
        let consent = app.switches["内容を確認して、保存に同意する"]
        for _ in 0..<10 where !consent.isHittable { app.swipeUp() }
        XCTAssertTrue(consent.waitForExistence(timeout: 8))
        // SwiftUI exposes the whole Form row as a switch. Its default tap point
        // is the label, so target the visible switch at the trailing edge.
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let agreed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: consent)
        XCTAssertEqual(XCTWaiter.wait(for: [agreed], timeout: 5), .completed, "consent must be on before saving")
        capture("preservation-copy-automatic-eligibility")
        tap("preservation-copy-save")
        XCTAssertTrue(app.buttons["preservation-copy-confirm"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["preservation-copy-save"].exists)
        capture("preservation-copy-result-unknown")
        tap("preservation-copy-confirm", scrollUp: false)
        XCTAssertTrue(app.staticTexts["保存済み"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["preservation-copy-confirm"].exists)
        capture("preservation-copy-stored")
        app.terminate()
    }

    @MainActor
    func testManagedPreservationDisabledHidesEntries() {
        let app = launchRecordPortabilityFixture()
        openSettings(in: app)
        revealSaveSection(app)
        let existing = app.buttons["settings-cat-profile-transfer"]
        XCTAssertTrue(existing.waitForExistence(timeout: 5))
        for _ in 0..<4 where !existing.isHittable { app.swipeUp() }
        XCTAssertTrue(existing.isHittable)
        XCTAssertFalse(app.buttons["settings-personal-archive"].exists)
        XCTAssertFalse(app.buttons["settings-managed-preservation"].exists)
        capture("managed-preservation-disabled-settings")
        app.terminate()

        let photoApp = launch("rediscovery")
        let menu = photoApp.buttons["photo-browser-related"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        XCTAssertTrue(photoApp.buttons["photo-browser-same-day"].waitForExistence(timeout: 5))
        XCTAssertFalse(photoApp.buttons["photo-browser-managed-preserve"].exists)
        XCTAssertFalse(photoApp.buttons["photo-browser-preserve-note"].exists)
        capture("managed-preservation-disabled-photo-menu")
        photoApp.terminate()
    }

    @MainActor
    private func launchRecordPortabilityFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--personal-archive-ui-fixture", "--photo-window-ui-fixture",
                               "--record-portability-ui-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let probe = app.buttons["archive-root-fixture-portability"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ready"), object: probe)], timeout: 5), .completed)
        // iOS 26 may drop the tab label's identifier; the tab itself must be there.
        XCTAssertTrue(app.buttons["main-tab-tools"].waitForExistence(timeout: 5)
                      || app.tabBars.buttons["この子"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func cancelRecordExportSheet(_ app: XCUIApplication, screenshot: String) {
        // iOS 26 hosts UIActivityViewController remotely; the wrapper's custom
        // identifier is absent from the captured accessibility hierarchy.
        let sheet = app.otherElements["ShareSheet.RemoteContainerView"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        capture(screenshot)
        let close = sheet.buttons["header.closeButton"].firstMatch
        // The remote sheet can still be sliding in on a busy CI Simulator: its
        // container exists before its header (11/8 diagnostic).
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        let beforeScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        beforeScreen.name = screenshot + "-before-close-screen"
        beforeScreen.lifetime = .keepAlways
        add(beforeScreen)
        let beforeCloseExists = close.exists
        print("RECORD_EXPORT_CLOSE_BEFORE at=\(Date().timeIntervalSince1970) exists=\(beforeCloseExists)")
        if beforeCloseExists {
            print("RECORD_EXPORT_CLOSE_READY hittable=\(close.isHittable) frame=\(close.frame)")
        }
        close.tap()
        let dismissed = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: sheet)], timeout: 5)
        let afterScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        afterScreen.name = screenshot + "-after-close-screen"
        afterScreen.lifetime = .keepAlways
        add(afterScreen)
        print("RECORD_EXPORT_CLOSE_AFTER at=\(Date().timeIntervalSince1970) waiter=\(dismissed.rawValue) sheetExists=\(sheet.exists) closeExists=\(close.exists)")
        if close.exists {
            print("RECORD_EXPORT_CLOSE_REMAINING hittable=\(close.isHittable) frame=\(close.frame)")
        }
        if dismissed != .completed {
            print("RECORD_EXPORT_CLOSE_APP_AFTER \(app.debugDescription)")
            print("RECORD_EXPORT_CLOSE_SHEET_AFTER \(sheet.debugDescription)")
        }
        XCTAssertEqual(dismissed, .completed)
    }

    @MainActor
    private func assertRecordPortabilitySourcesKept(_ app: XCUIApplication) {
        let probe = app.buttons["archive-root-fixture-portability"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        probe.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "kept;files=0"), object: probe)], timeout: 5), .completed,
            "Cancelling the real system share sheet must preserve the stored memo and remove only temporary exports")
    }

    @MainActor
    func testMembershipAccessPreservesExistingMemoAndDistinguishesUnknown() {
        let app = XCUIApplication()
        app.launchArguments = ["--membership-access-ui-fixture", "--photo-window-ui-fixture"]
        app.launch()
        let existing = app.buttons["membership-existing"]
        XCTAssertTrue(existing.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: existing)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        existing.tap()
        let editor = app.textViews["photo-memory-note-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "An expired membership must not lock an existing memo")
        editor.tap()
        editor.typeText("。")
        app.navigationBars["メモ"].buttons["保存"].tap()
        XCTAssertTrue(existing.waitForExistence(timeout: 5))
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "。"),
            object: app.staticTexts["membership-existing-text"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)

        // 11/13: writing a new memo is free. Without Plus the editor opens at
        // once, with no Plus screen, line, button or mark.
        app.buttons["membership-new"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "A new memo must open without Plus")
        XCTAssertFalse(app.staticTexts["membership-offer-heading"].exists)
        XCTAssertFalse(app.otherElements["plus-offer-prompt"].exists)
        XCTAssertTrue(app.switches["memo-weight-toggle"].exists, "Attaching a weight follows the memo (free)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "membership-new-memo-free"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["photo-memory-note-close"].tap()
        // An unknown purchase state does not stop a new memo either.
        app.buttons["membership-unknown"].tap()
        app.buttons["membership-new"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "An unknown purchase state must not stop a new memo")
        XCTAssertFalse(app.buttons["購入を復元"].exists)
        XCTAssertFalse(app.staticTexts["membership-offer-heading"].exists)
        app.buttons["photo-memory-note-close"].tap()
        app.buttons["membership-beta"].tap()
        app.buttons["membership-new"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "The current beta stays unrestricted")
        app.terminate()
    }

    @MainActor
    func testMembershipDailyToolsKeepExistingRecordsAccessible() {
        let app = XCUIApplication()
        app.launchArguments = ["--membership-access-ui-fixture", "--photo-window-ui-fixture",
            "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let existing = app.buttons["membership-existing"]
        XCTAssertTrue(existing.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: existing)], timeout: 5), .completed)
        // ADR-027: ツールは無料。会員が切れていても（inactive）新しい記録を作れる。
        // 新しい記録は「猫のプロフィール」から作る（プロフィールごとに1件）。
        // 11/7: each tool is one page; the row of cats switches the memo in
        // place (no list to go back to). A profile cat's name is read-only, so
        // an opened memo is the chosen chip with that memo's own fields.
        let sora = "tool-profile-AB000000-0000-0000-0000-000000000002"
        let hana = "tool-profile-AB000000-0000-0000-0000-000000000003"
        let kuro = "tool-profile-AB000000-0000-0000-0000-000000000004"
        func choose(_ chip: XCUIElement, _ message: String) {
            XCTAssertTrue(chip.waitForExistence(timeout: 5), message); chip.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "selected == true"), object: chip)], timeout: 5), .completed, message)
        }
        // 11/12: 預けるとき's cats are the items of the menu in the bar; a chosen
        // item closes the menu and the bar names that cat.
        func chooseCare(_ item: XCUIElement, _ message: String) {
            openCareCatMenu(app)
            XCTAssertTrue(item.waitForExistence(timeout: 5), message)
            let name = item.label
            item.tap()
            XCTAssertTrue(item.waitForNonExistence(timeout: 5), message)
            let named = NSPredicate { object, _ in
                guard let label = (object as? XCUIElement)?.label, !label.isEmpty else { return false }
                return label.contains(name) || name.contains(label)
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: named, object: app.buttons["care-cat-menu"])],
                                          timeout: 5), .completed, message)
        }
        func opensCareMemo(_ identifier: String, _ message: String) {
            chooseCare(app.buttons[identifier], message)
            XCTAssertTrue(app.buttons["care-row-important"].waitForExistence(timeout: 5), message)
            XCTAssertFalse(app.staticTexts["membership-offer-heading"].exists, message)
        }
        func showsVetQuestions(_ message: String) {
            // 11/12: 先生に聞きたいこと is a row that opens its page with the field.
            openVetRow("vet-step-questions", title: "先生に聞きたいこと", app: app)
            let questions = app.descendants(matching: .any)["vet-questions"].firstMatch
            XCTAssertTrue(questions.waitForExistence(timeout: 5), message)
            leaveVetPage("先生に聞きたいこと", app: app)
        }
        app.buttons["membership-care"].tap()
        // The existing memo's cat has no profile here: its item is care-cat-<UUID>.
        let cat = app.buttons.matching(NSPredicate(format: "identifier MATCHES %@", "care-cat-[0-9A-F-]{36}")).firstMatch
        chooseCare(cat, "The existing care memo's cat stays in the menu")
        // Its name is the page of its row 「名前」.
        openToolRow("care-row-name", title: "名前", bottom: "care-preview-open", app: app)
        XCTAssertTrue(app.descendants(matching: .any)["care-cat-name"].firstMatch.waitForExistence(timeout: 5),
                      "Existing care memo remains editable")
        leaveVetPage("名前", app: app)
        opensCareMemo(sora, "An expired membership must not block a new care memo")
        capture("membership-care-new-free")
        chooseCare(cat, "The existing care memo can be opened again")
        XCTAssertTrue(app.buttons["care-preview-open"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["care-preview-open"].isHittable, "Existing output remains available")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["membership-veterinary"].tap()
        // 11/12: 病院で見せる chooses the cat from the menu in the bar.
        chooseVetCat("vet-cat-AB000000-0000-0000-0000-000000000001", app: app)
        showsVetQuestions("Existing draft remains editable")
        chooseVetCat(sora, app: app)
        showsVetQuestions("An expired membership must not block a new veterinary visit")
        XCTAssertFalse(app.staticTexts["membership-offer-heading"].exists)
        capture("membership-veterinary-new-free")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // 確認不能（checking）でもツールは止まらない。
        app.buttons["membership-unknown"].tap()
        app.buttons["membership-care"].tap()
        opensCareMemo(hana, "Unknown membership must not block a new care memo")
        XCTAssertFalse(app.buttons["購入を復元"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["membership-beta"].tap()
        app.buttons["membership-care"].tap()
        opensCareMemo(kuro, "Beta creation remains unrestricted")
        app.terminate()
    }

    @MainActor
    func testMembershipShowcaseBoundaryKeepsEmergencyToolsFree() {
        let app = XCUIApplication()
        app.launchArguments = ["--membership-access-ui-fixture", "--photo-window-ui-fixture",
            "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        // 11/12 (この子): 迷子のとき opens from a cat's page, so the tools list has cats.
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "tool-profiles"
        app.launch()
        let tools = app.buttons["membership-tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 10)); tools.tap()
        let tab = app.buttons["main-tab-tools"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5)); tab.tap()
        // ADR-027: 「写真を見せる」も無料。会員が切れていても会員案内は出ない。
        app.buttons["tools-showcase-open"].tap()
        XCTAssertFalse(app.staticTexts["membership-offer-heading"].waitForExistence(timeout: 3),
            "Presenting cat photos must not ask for a membership")
        capture("membership-showcase-free")
        if app.alerts.buttons["閉じる"].exists {
            app.alerts.buttons["閉じる"].tap()
        } else if app.buttons["showcase-back"].exists {
            app.buttons["showcase-back"].tap()
        }
        let lost = app.buttons["tools-lost-cat-open"]
        for _ in 0..<5 where !lost.isHittable { app.swipeUp() }
        lost.tap()
        XCTAssertTrue(app.navigationBars["迷子のとき"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["membership-offer-heading"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let evacuation = app.buttons["tools-evacuation-open"]
        for _ in 0..<5 where !evacuation.isHittable { app.swipeUp() }
        evacuation.tap()
        XCTAssertTrue(app.buttons["evacuation-packing-open"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["membership-offer-heading"].exists)
        app.terminate()
    }

    @MainActor
    private func checkBillingOwnerEnrollmentPreparesOnceWithoutPurchase() {
        let app = XCUIApplication()
        app.launchArguments = ["--membership-offer-ui-fixture", "--billing-owner-enrollment-fixture"]
        app.launch()
        let read = app.buttons["billing-owner-enrollment-read"]
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        read.tap()
        let prepare = app.buttons["billing-owner-enrollment-prepare"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        XCTAssertTrue(prepare.isHittable)
        prepare.tap()
        let status = app.staticTexts["billing-owner-enrollment-status"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "境界確認OK"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertFalse(prepare.exists)
        let requestID = app.staticTexts["billing-owner-enrollment-request"].label
        let fingerprint = app.staticTexts["billing-owner-enrollment-fingerprint"].label
        XCTAssertEqual(requestID.count, 36)
        XCTAssertEqual(fingerprint.count, 64)
        read.tap()
        XCTAssertEqual(app.staticTexts["billing-owner-enrollment-request"].label, requestID)
        XCTAssertEqual(app.staticTexts["billing-owner-enrollment-fingerprint"].label, fingerprint)
        XCTAssertTrue(status.label.contains("購入はまだ開始していません"))
        XCTAssertFalse(app.buttons["membership-offer-purchase"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "billing-owner-enrollment-local-preparation"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    @MainActor
    func testMembershipOfferExplainsExpiryWithoutChangingThePlan() {
        for largeText in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--membership-offer-ui-fixture",
                                   "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            if largeText {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            app.launch()
            XCTAssertTrue(app.buttons["membership-preview-open"].waitForExistence(timeout: 10))
            app.buttons["membership-preview-open"].tap()
            let heading = app.staticTexts["membership-offer-heading"]
            XCTAssertTrue(heading.waitForExistence(timeout: 5))
            XCTAssertEqual(heading.label, "うちの子との毎日を、もっと残す")
            let overview = XCTAttachment(screenshot: app.screenshot())
            overview.name = "membership-overview-\(largeText ? "largest" : "standard")"
            overview.lifetime = .keepAlways
            add(overview)
            // Trial eligibility comes from StoreKit; the preview stands in for it.
            XCTAssertEqual(app.buttons["membership-offer-purchase"].label, "14日間無料で試す")
            let price = app.staticTexts["membership-offer-price"]
            if !largeText {
                // 11/11: the button, the price and the renewal sentence are
                // pinned at the bottom of the first screen, with no scrolling.
                XCTAssertTrue(price.isHittable, "The price is pinned on the first screen")
                XCTAssertTrue(app.buttons["membership-offer-purchase"].isHittable)
                XCTAssertTrue(app.staticTexts["membership-offer-renewal"].isHittable)
            }
            for _ in 0..<10 { if price.isHittable { break }; app.swipeUp() }
            XCTAssertEqual(price.label, "その後 月額¥980（自動更新）")
            // 11/10: the button, the price line and the trust box sit inside
            // the same side margins, never at the screen edge.
            let margin = app.windows.firstMatch.frame
            for element in [app.buttons["membership-offer-purchase"], price,
                            app.descendants(matching: .any)["membership-offer-reassurance"].firstMatch] {
                XCTAssertGreaterThanOrEqual(element.frame.minX - margin.minX, 16, element.identifier)
                XCTAssertGreaterThanOrEqual(margin.maxX - element.frame.maxX, 16, element.identifier)
            }
            let values = app.descendants(matching: .any)["membership-offer-values"].firstMatch
            XCTAssertFalse(values.label.contains("毎日、新しい1枚がホーム画面に"), "The daily photo is free")
            XCTAssertFalse(values.label.contains("写真に新しいメモを書く"), "A new memo is free (11/13)")
            for line in ["月の作品、季節のムービー",
                         "まどを作って、家族と写真を届け合う", "家族の手帳を作って、家族と一緒に書く",
                         "猫のこと・メモ・ツールの記録を保存して、新しいiPhoneに戻せる"] {
                XCTAssertTrue(values.label.contains(line), "Missing value: \(line)")
            }
            let reassurance = app.descendants(matching: .any)["membership-offer-reassurance"].firstMatch
            for _ in 0..<10 { if reassurance.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(reassurance.isHittable, "The three reassurances must be readable before the links")
            for line in ["いつでも解約できます", "解約しても、写真・まど・メモは消えません", "招待した家族は無料で入れます"] {
                XCTAssertTrue(reassurance.label.contains(line), "Missing reassurance: \(line)")
            }
            for identifier in ["membership-offer-restore", "membership-offer-cancel-help",
                               "membership-offer-terms", "membership-offer-privacy"] {
                let link = app.descendants(matching: .any)[identifier].firstMatch
                for _ in 0..<10 { if link.isHittable { break }; app.swipeUp() }
                XCTAssertTrue(link.isHittable, "Missing footer link: \(identifier)")
            }
            for retired in ["検討中", "最大3つ", "送信は停止", "会員の有効期間が終わると"] {
                XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", retired))
                    .firstMatch.exists, "Retired copy is still shown: \(retired)")
            }
            let footer = XCTAttachment(screenshot: app.screenshot())
            footer.name = "membership-reassurance-\(largeText ? "largest" : "standard")"
            footer.lifetime = .keepAlways
            add(footer)
            XCTAssertFalse(app.staticTexts["membership-preview-result"].exists,
                           "Reading the terms must not purchase, restore, or finish the offer")
            XCTAssertTrue(app.buttons["membership-offer-close"].isHittable)
            app.buttons["membership-offer-close"].tap()
            XCTAssertTrue(app.buttons["membership-preview-open"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testMembershipOfferPreviewReturnsToPurpose() {
        for cancelled in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--membership-offer-ui-fixture"]
            if cancelled { app.launchArguments.append("--membership-purchase-cancelled") }
            app.launch()
            XCTAssertTrue(app.buttons["membership-preview-open"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.staticTexts["membership-fixture-configuration"].label, "構成確認OK")
            app.buttons["membership-preview-open"].tap()
            let purchase = app.buttons["membership-offer-purchase"]
            XCTAssertTrue(purchase.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["membership-offer-preview-notice"].exists)
            if !cancelled {
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "membership-offer-preview"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            for _ in 0..<3 where !purchase.isHittable { app.swipeUp() }
            purchase.tap()
            if !cancelled {
                // 11/12: bought from Settings, where nothing was waiting: one
                // line and the one next step, in the same sheet.
                let started = app.staticTexts["membership-offer-started"]
                XCTAssertTrue(started.waitForExistence(timeout: 5))
                XCTAssertEqual(started.label, "Plusが始まりました。")
                XCTAssertFalse(app.alerts["自動保存も始めますか？"].exists,
                               "Auto-save is never asked over the purchase")
                let next = app.buttons["membership-offer-next-step"]
                XCTAssertEqual(next.label, "10月の作品を開く")
                let startedCapture = XCTAttachment(screenshot: app.screenshot())
                startedCapture.name = "membership-offer-started"
                startedCapture.lifetime = .keepAlways
                add(startedCapture)
                next.tap()
            }
            let result = app.staticTexts["membership-preview-result"]
            XCTAssertTrue(result.waitForExistence(timeout: 5))
            XCTAssertTrue(result.label.contains(cancelled ? "取り消して" : "契約は変更していません"))
            XCTAssertTrue(app.buttons["membership-preview-open"].isHittable)
            if !cancelled {
                // A place with something waiting (making a まど) goes straight
                // back to it: no 「Plusが始まりました。」, no question.
                let window = app.buttons["membership-preview-open-create-window"]
                for _ in 0..<10 { if window.isHittable { break }; app.swipeUp() }
                window.tap()
                let windowPurchase = app.buttons["membership-offer-purchase"]
                XCTAssertTrue(windowPurchase.waitForExistence(timeout: 5))
                for _ in 0..<3 where !windowPurchase.isHittable { app.swipeUp() }
                windowPurchase.tap()
                XCTAssertTrue(window.waitForExistence(timeout: 5))
                XCTAssertFalse(app.staticTexts["membership-offer-started"].exists)
                XCTAssertFalse(app.alerts["自動保存も始めますか？"].exists)
                XCTAssertTrue(app.staticTexts["membership-preview-result"].label.contains("契約は変更していません"))
            }
            app.terminate()
        }
        checkBillingOwnerEnrollmentPreparesOnceWithoutPurchase()
        checkJoinedMembershipCannotOfferAnotherPurchase()
    }

    /// ADR-027 5章: every entry opens the same one screen; only the reason
    /// line differs. Without trial eligibility the button names the price.
    @MainActor
    private func checkPlusOfferContextsShareOneSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["--membership-offer-ui-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        // 11/12 (review 5): what the person gets there, not a rule.
        let reasons: [(String, String?)] = [
            ("onboarding", nil),
            ("monthly-summary", "10月の作品ができています。Plusで開けます。"),
            ("create-window", "Plusがいるのは作る人だけです。"), ("continue-window", "作った人のPlus"),
            ("create-family", "家族で一緒に書けます。"), ("continue-family", "家族の誰か1人のPlus"),
            ("preservation", "新しいiPhoneに戻せます。"), ("settings", nil),
        ]
        XCTAssertTrue(app.buttons["membership-preview-open"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["membership-preview-open-monthly-summary"].label, "Plusで10月の作品を見る")
        for (identifier, reason) in reasons {
            let open = app.buttons["membership-preview-open-" + identifier]
            for _ in 0..<10 { if open.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(open.isHittable, identifier)
            open.tap()
            let heading = app.staticTexts["membership-offer-heading"]
            XCTAssertTrue(heading.waitForExistence(timeout: 5), identifier)
            XCTAssertEqual(heading.label, "うちの子との毎日を、もっと残す")
            XCTAssertEqual(app.buttons["membership-offer-purchase"].label, "14日間無料で試す")
            let reasonText = app.staticTexts["membership-offer-reason"]
            if let reason {
                XCTAssertTrue(reasonText.label.contains(reason), identifier)
                XCTAssertFalse(reasonText.label.contains("写真やメモの保存"), identifier)
            } else {
                XCTAssertFalse(reasonText.exists, identifier)
            }
            // Only the first offer, which opens by itself, says Plus is optional.
            let staysFree = app.staticTexts["membership-offer-stays-free"]
            if identifier == "onboarding" {
                for _ in 0..<10 { if staysFree.isHittable { break }; app.swipeUp() }
                XCTAssertEqual(staysFree.label, "Plusにしなくても、このまま無料で使えます。")
            } else {
                XCTAssertFalse(staysFree.exists, identifier)
            }
            app.buttons["membership-offer-close"].tap()
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            let result = app.staticTexts["membership-preview-result"]
            XCTAssertTrue(result.waitForExistence(timeout: 5))
            XCTAssertTrue(result.label.contains("取り消して"),
                          "Closing without buying must not report a purchase")
        }
        app.terminate()

        let noTrial = XCUIApplication()
        noTrial.launchArguments = ["--membership-offer-ui-fixture", "--membership-offer-no-trial",
                                   "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        noTrial.launch()
        XCTAssertTrue(noTrial.buttons["membership-preview-open"].waitForExistence(timeout: 10))
        noTrial.buttons["membership-preview-open"].tap()
        let purchase = noTrial.buttons["membership-offer-purchase"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 5))
        XCTAssertEqual(purchase.label, "Plusを始める")
        // The price is said once, under the button, with that it renews.
        XCTAssertEqual(noTrial.staticTexts["membership-offer-price"].label, "月額¥980（自動更新）")
        XCTAssertFalse(noTrial.staticTexts["membership-offer-trial"].exists)
        let capture = XCTAttachment(screenshot: noTrial.screenshot())
        capture.name = "membership-offer-without-trial"
        capture.lifetime = .keepAlways
        add(capture)
        // From Settings a completed purchase ends on one line and one button
        // (11/12); the button closes the sheet.
        for _ in 0..<5 where !purchase.isHittable { noTrial.swipeUp() }
        purchase.tap()
        XCTAssertTrue(noTrial.staticTexts["membership-offer-started"].waitForExistence(timeout: 5))
        XCTAssertFalse(noTrial.staticTexts["membership-offer-heading"].exists)
        noTrial.buttons["membership-offer-next-step"].tap()
        XCTAssertTrue(noTrial.staticTexts["membership-preview-result"].waitForExistence(timeout: 5))
        XCTAssertFalse(noTrial.staticTexts["membership-offer-started"].exists)
        noTrial.terminate()

        // 11/12 (review 8): no price could be read; 「もう一度読み込む」 is
        // there, and it brings the price and the button back.
        let failing = XCUIApplication()
        failing.launchArguments = ["--membership-offer-ui-fixture", "--membership-offer-load-fails-once",
                                   "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        failing.launch()
        XCTAssertTrue(failing.buttons["membership-preview-open"].waitForExistence(timeout: 10))
        failing.buttons["membership-preview-open"].tap()
        let reload = failing.buttons["membership-offer-reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 5), "A failed price read must offer a retry")
        XCTAssertFalse(failing.buttons["membership-offer-purchase"].isEnabled)
        XCTAssertFalse(failing.buttons["membership-offer-manage"].exists)
        let unavailable = XCTAttachment(screenshot: failing.screenshot())
        unavailable.name = "membership-offer-price-unavailable"
        unavailable.lifetime = .keepAlways
        add(unavailable)
        reload.tap()
        XCTAssertTrue(failing.staticTexts["membership-offer-price"].waitForExistence(timeout: 5))
        XCTAssertEqual(failing.staticTexts["membership-offer-price"].label, "その後 月額¥980（自動更新）")
        XCTAssertTrue(failing.buttons["membership-offer-purchase"].isEnabled)
        XCTAssertFalse(reload.exists)
        failing.terminate()
    }

    @MainActor
    func testMembershipOfferPreviewWaitingAndRestore() {
        checkMembershipCatalogRefreshRequiresReview()
        checkPlusOfferContextsShareOneSheet()
        let app = XCUIApplication()
        app.launchArguments = ["--membership-offer-ui-fixture", "--membership-purchase-waiting"]
        app.launch()
        XCTAssertTrue(app.buttons["membership-preview-open"].waitForExistence(timeout: 10))
        app.buttons["membership-preview-open"].tap()
        let purchase = app.buttons["membership-offer-purchase"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 5))
        for _ in 0..<3 where !purchase.isHittable { app.swipeUp() }
        purchase.tap()
        let message = app.staticTexts["membership-offer-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        // 10/30 wording: wait for Apple's purchase, and do not buy again.
        XCTAssertTrue(message.label.contains("購入手続きが終わるのを待っています"), message.label)
        XCTAssertTrue(message.label.contains("もう一度購入せず"), message.label)
        XCTAssertFalse(purchase.isEnabled)
        XCTAssertFalse(app.staticTexts["membership-preview-result"].exists)
        let restore = app.buttons["membership-offer-restore"]
        for _ in 0..<3 where !restore.isHittable { app.swipeUp() }
        XCTAssertTrue(restore.isEnabled)
        restore.tap()
        XCTAssertTrue(app.staticTexts["membership-preview-result"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["membership-preview-open"].isHittable)
        app.terminate()
        checkMembershipConfirmationStates()
    }

    @MainActor
    func testFamilyNotebookUnshareRequiresConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--family-unshare-ui-fixture"]
        app.launch()
        // 11/7: the row is a name, not a link (one place to write: ツール).
        let row = app.staticTexts["試験の猫"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        app.buttons["手帳から外す"].tap()
        XCTAssertTrue(app.staticTexts["この猫を家族の手帳から外しますか？"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["各自の記録は残ります。"].exists)
        XCTAssertFalse(app.staticTexts["unshare-completed"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "family-unshare-confirmation"; image.lifetime = .keepAlways; add(image)
        app.buttons["外す"].tap()
        XCTAssertTrue(app.staticTexts["unshare-completed"].waitForExistence(timeout: 3))
        XCTAssertFalse(row.exists)
        app.terminate()
    }

    @MainActor
    func testRestorationDoesNotRequireProductCatalog() {
        let app = XCUIApplication()
        app.launchArguments = ["--membership-offer-ui-fixture", "--membership-restore-without-catalog"]
        app.launch()
        let open = app.buttons["membership-preview-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let restore = app.buttons["membership-restore-submit"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        XCTAssertTrue(restore.isEnabled)
        XCTAssertFalse(app.buttons["membership-offer-purchase"].exists)
        let message = app.staticTexts["membership-restore-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertFalse(message.label.contains("料金"))
        // One button: 「購入を復元」 also re-checks, so no second button (11/5).
        XCTAssertEqual(restore.label, "購入を復元")
        XCTAssertFalse(app.buttons["membership-restore-refresh"].exists)
        XCTAssertFalse(app.buttons["購入状況を再確認"].exists)
        restore.tap()
        let failure = NSPredicate(format: "label == %@", "購入を確かめられませんでした。もう一度購入せず、時間をおいて「購入を復元」をお試しください。")
        expectation(for: failure, evaluatedWith: message)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(restore.isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "restore-without-product-catalog"
        attachment.lifetime = .keepAlways
        add(attachment)
        // A successful restore closes the real sheet even with no catalog.
        restore.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(open.isHittable)
        XCTAssertFalse(restore.exists)
        app.terminate()
    }

    @MainActor
    func testMembershipRestoreFailureStaysVisible() {
        let app = XCUIApplication()
        app.launchArguments = ["--membership-offer-ui-fixture", "--membership-restore-apple-failure"]
        app.launch()
        XCTAssertTrue(app.buttons["membership-preview-open"].waitForExistence(timeout: 10))
        app.buttons["membership-preview-open"].tap()
        let restore = app.buttons["membership-offer-restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        for _ in 0..<3 where !restore.isHittable { app.swipeUp() }
        restore.tap()
        let message = app.staticTexts["membership-offer-message"]
        let failure = NSPredicate(format: "label == %@", "購入を確かめられませんでした。もう一度購入せず、時間をおいて「購入を復元」をお試しください。")
        expectation(for: failure, evaluatedWith: message)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(restore.isEnabled)
        XCTAssertFalse(app.buttons["membership-offer-purchase"].isEnabled)
        XCTAssertFalse(app.staticTexts["membership-preview-result"].exists)
        // One button: no separate re-check next to 「購入を復元」 (11/5).
        XCTAssertFalse(app.buttons["membership-offer-refresh"].exists)
        XCTAssertFalse(app.buttons["購入状況を再確認"].exists)
        // The next tap that finds Plus closes the sheet; the old error goes with it.
        restore.tap()
        XCTAssertTrue(app.staticTexts["membership-preview-result"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["membership-preview-result"].label.contains("確認を終えて"))
        XCTAssertFalse(message.exists)
        app.terminate()
    }

    @MainActor
    private func checkJoinedMembershipCannotOfferAnotherPurchase() {
        for largeText in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--membership-offer-ui-fixture", "--membership-state-active"]
            if largeText {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            app.launch()
            XCTAssertTrue(app.buttons["membership-preview-open"].waitForExistence(timeout: 10))
            app.buttons["membership-preview-open"].tap()
            // 11/7: 「Plusを利用中です」 is words, not a disabled purchase button.
            let joined = app.descendants(matching: .any)["membership-offer-active"].firstMatch
            XCTAssertTrue(joined.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["membership-offer-purchase"].exists)
            XCTAssertFalse(app.buttons["Plusを利用中です"].exists)
            XCTAssertFalse(app.staticTexts["membership-offer-price"].exists)
            XCTAssertFalse(app.staticTexts["membership-offer-trial"].exists)
            for _ in 0..<5 where !joined.isHittable { app.swipeUp() }
            XCTAssertTrue(joined.isHittable)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = largeText ? "membership-joined-largest" : "membership-joined"
            attachment.lifetime = .keepAlways
            add(attachment)
            checkMembershipManagementPreviewKeepsState(app, expectedPurchaseTitle: nil,
                                                       captureName: largeText ? "largest" : "standard")
            app.buttons["membership-offer-close"].tap()
            XCTAssertTrue(app.staticTexts["membership-preview-result"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["membership-preview-result"].label.contains("確認を終えて"))
            app.terminate()
        }
    }

    @MainActor
    private func checkMembershipConfirmationStates() {
        for state in ["unknown", "authority-pending", "apple-pending", "expired", "expiring"] {
            let app = XCUIApplication()
            app.launchArguments = ["--membership-offer-ui-fixture", "--membership-state-" + state]
            app.launch()
            XCTAssertTrue(app.buttons["membership-preview-open"].waitForExistence(timeout: 10))
            app.buttons["membership-preview-open"].tap()
            let purchase = app.buttons["membership-offer-purchase"]
            XCTAssertTrue(purchase.waitForExistence(timeout: 5))
            if state == "expiring" {
                let expired = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label == %@", "購入状況の確認が必要です"), object: purchase)
                XCTAssertEqual(XCTWaiter.wait(for: [expired], timeout: 5), .completed)
            }
            XCTAssertFalse(purchase.isEnabled, "Unknown and pending states must not invite another purchase")
            XCTAssertTrue(app.staticTexts["membership-offer-message"].label.contains("もう一度購入せず")
                          || app.staticTexts["membership-offer-message"].label.contains("もう一度購入しない"))
            // One button: 「購入を復元」 re-checks and restores (11/5).
            XCTAssertFalse(app.buttons["membership-offer-refresh"].exists)
            XCTAssertFalse(app.buttons["購入状況を再確認"].exists)
            let restore = app.buttons["membership-offer-restore"]
            for _ in 0..<5 where !restore.isHittable { app.swipeUp() }
            XCTAssertTrue(restore.isHittable)
            XCTAssertTrue(restore.isEnabled)
            if state == "unknown" {
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "membership-confirmation-required"
                attachment.lifetime = .keepAlways
                add(attachment)
                checkMembershipManagementPreviewKeepsState(app, expectedPurchaseTitle: "購入状況の確認が必要です",
                                                           captureName: "unknown")
                for _ in 0..<5 where !restore.isHittable { app.swipeUp() }
            }
            restore.tap()
            if state == "expired" || state == "expiring" {
                // Nothing to restore: the sheet stays, the result stays, and buying is open again.
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: purchase)
                XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
                XCTAssertTrue(app.staticTexts["membership-offer-message"].label.contains("見つかりませんでした"))
                XCTAssertFalse(app.staticTexts["membership-preview-result"].exists,
                               "A restore that finds nothing must not close the sheet")
            } else if state == "apple-pending" {
                XCTAssertFalse(purchase.isEnabled)
                XCTAssertEqual(purchase.label, "購入の確認待ちです")
                XCTAssertFalse(app.staticTexts["membership-preview-result"].exists,
                               "A purchase still pending at Apple must not close the sheet")
            } else {
                // The re-check confirms Plus: the sheet closes as a restore does.
                let result = app.staticTexts["membership-preview-result"]
                XCTAssertTrue(result.waitForExistence(timeout: 5))
                XCTAssertTrue(result.label.contains("確認を終えて"))
            }
            app.terminate()
        }
    }

    @MainActor
    private func checkMembershipCatalogRefreshRequiresReview() {
        let app = XCUIApplication()
        app.launchArguments = ["--membership-offer-ui-fixture", "--membership-catalog-refresh"]
        app.launch()
        let boundary = app.staticTexts["membership-catalog-boundary"]
        XCTAssertTrue(boundary.waitForExistence(timeout: 10))
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "境界確認OK"), object: boundary)
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 5), .completed)
        app.buttons["membership-preview-open"].tap()
        let price = app.staticTexts["membership-offer-price"]
        XCTAssertTrue(price.waitForExistence(timeout: 5))
        XCTAssertEqual(price.label, "月額$5.99（自動更新）")
        let purchase = app.buttons["membership-offer-purchase"]
        for _ in 0..<5 where !purchase.isHittable { app.swipeUp() }
        purchase.tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "その後 月額¥980（自動更新）"), object: price)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
        XCTAssertEqual(purchase.label, "1週間無料で試す")
        XCTAssertTrue(app.staticTexts["membership-offer-message"].label.contains("表示を確かめてから"))
        XCTAssertFalse(app.staticTexts["membership-preview-result"].exists,
                       "An old quote must update in place without purchasing or dismissing")
        XCTAssertTrue(purchase.isEnabled)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "membership-refreshed-price-requires-another-tap"
        capture.lifetime = .keepAlways
        add(capture)
        purchase.tap()
        XCTAssertTrue(app.staticTexts["membership-preview-result"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    private func checkMembershipManagementPreviewKeepsState(_ app: XCUIApplication,
                                                          expectedPurchaseTitle: String?,
                                                          captureName: String) {
        let manage = app.buttons["membership-offer-manage"]
        for _ in 0..<10 where !manage.isHittable { app.swipeUp() }
        XCTAssertTrue(manage.isHittable, "Management must be reachable for active and unconfirmed members")
        XCTAssertTrue(manage.isEnabled)
        XCTAssertEqual(manage.label, "サブスクリプションを管理")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "membership-management-\(captureName)"
        attachment.lifetime = .keepAlways
        add(attachment)
        manage.tap()
        let preview = app.alerts["契約管理の操作確認"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.staticTexts["このプレビューではAppleの契約画面を開きません。契約や会員状態は変更していません。"].exists)
        preview.buttons["閉じる"].tap()
        XCTAssertFalse(preview.exists)
        let purchase = app.buttons["membership-offer-purchase"]
        if let expectedPurchaseTitle {
            XCTAssertEqual(purchase.label, expectedPurchaseTitle,
                           "Closing management must not invent a purchase, cancellation, or grant")
            XCTAssertFalse(purchase.isEnabled)
        } else {
            // A member has no purchase button (11/7); closing management must not add one.
            XCTAssertFalse(purchase.exists, "Closing management must not invent a purchase, cancellation, or grant")
            XCTAssertTrue(app.descendants(matching: .any)["membership-offer-active"].firstMatch.exists)
        }
        XCTAssertFalse(app.staticTexts["membership-preview-result"].exists)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    @MainActor
    func testPhotosOpenEachCatsPhotosDirectlyAndKeepManagementInSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-screenshot-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "cats"
        app.launch()
        // 11/1: the アルバム tab keeps only the works; themes and years are
        // browsed from 写真's theme row. Choose a subject first, then filter
        // inside its shipping destination.
        openWorksAlbumTab(in: app)
        XCTAssertFalse(element("albums-cat-fixture-cat-0", in: app).exists)
        openPhotosTab(in: app)
        assertPhotoLibraryCat("すべての猫", in: app)
        let themeRow = element("photos-theme-row", in: app)
        XCTAssertTrue(themeRow.waitForExistence(timeout: 15), app.debugDescription)
        func openTheme(_ title: String) {
            let theme = app.buttons["photos-theme-\(title)"]
            XCTAssertTrue(theme.waitForExistence(timeout: 10), app.debugDescription)
            // Off-screen tiles of the horizontal row have no hit point yet:
            // swipe the row until the tile's frame is inside the screen.
            // A swipe flings past a tile; drag a short distance at a time.
            for _ in 0..<12 where !app.frame.contains(theme.frame) {
                let center = themeRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                let step: CGFloat = theme.frame.minX < app.frame.minX ? 150 : -150
                center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: step, dy: 0)))
            }
            XCTAssertTrue(theme.isHittable, "The \(title) theme must stay reachable in the row")
            theme.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        }
        openTheme("大きく写った猫")
        let albumPhotos = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "の猫の写真"))
        XCTAssertEqual(albumPhotos.count, 1)
        selectAlbumCatFilter("fixture-cat-1", expectedName: "ソラ", in: app)
        XCTAssertEqual(albumPhotos.count, 0, "A cat with no matching photos must not fall back to everyone.")
        selectAlbumCatFilter(nil, in: app)
        XCTAssertEqual(albumPhotos.count, 1)
        app.navigationBars["大きく写った猫"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(themeRow.waitForExistence(timeout: 5))

        for _ in 0..<6 where !themeRow.isHittable { app.swipeDown() }
        openTheme("2025年")
        XCTAssertEqual(albumPhotos.count, 3)
        selectAlbumCatFilter("fixture-cat-0", expectedName: "ミケ", in: app)
        XCTAssertEqual(albumPhotos.count, 1)
        albumPhotos.firstMatch.tap()
        let filteredPhoto = app.images["photo-detail-zoom-surface"]
        XCTAssertTrue(filteredPhoto.waitForExistence(timeout: 10))
        let filteredDate = app.descendants(matching: .any)["photo-browser-date"].firstMatch
        XCTAssertTrue(filteredDate.waitForExistence(timeout: 5))
        XCTAssertEqual(filteredDate.value as? String, "2025年12月18日")
        filteredPhoto.swipeLeft()
        XCTAssertEqual(filteredDate.value as? String, "2025年12月18日",
                       "The filtered year browser must not page into another cat's photos.")
        app.navigationBars["写真"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["2025年"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["album-cat-filter"].value as? String, "ミケ")
        selectAlbumCatFilter(nil, in: app)
        XCTAssertEqual(albumPhotos.count, 3)
        app.navigationBars["2025年"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(themeRow.waitForExistence(timeout: 5))
        openPhotosTab(in: app)
        XCTAssertTrue(element("photos-cat-picker", in: app).waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["photo-hub-source-recovery"].exists)
        XCTAssertFalse(app.staticTexts["写真の対象と整理"].exists)
        capture("photo-hub-cats")
        for (index, name) in ["ミケ", "ソラ"].enumerated() {
            selectPhotoLibraryCat("fixture-cat-\(index)", expectedName: name, in: app)
            XCTAssertTrue(app.navigationBars["写真"].exists)
            // 11/7: with one cat chosen, its photos are added here (not on the cat's page).
            XCTAssertTrue(app.buttons["photos-cat-add-photos"].exists, "The chosen cat's add entry is missing")
            let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-hub-photo-"))
            XCTAssertEqual(photos.count, 1, "The root filter must retain the selected cat")
            XCTAssertFalse(app.buttons["cat-profile-open-albums"].exists)
            if index == 0 { capture("cat-filtered-photo-root") }
            photos.firstMatch.tap()
            let zoom = app.images["photo-detail-zoom-surface"]
            XCTAssertTrue(zoom.waitForExistence(timeout: 10))
            let date = app.descendants(matching: .any)["photo-browser-date"].firstMatch
            XCTAssertTrue(date.waitForExistence(timeout: 5))
            let expectedDate = index == 0 ? "2025年12月18日" : "2025年8月4日"
            XCTAssertEqual(date.value as? String, expectedDate, "The browser opened another cat's photo")
            XCTAssertTrue(app.buttons["photo-browser-memory-saved-state"].isHittable)
            zoom.swipeLeft()
            XCTAssertEqual(date.value as? String, expectedDate)
            app.navigationBars["写真"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["photos-cat-picker"].waitForExistence(timeout: 5))
            assertPhotoLibraryCat(name, in: app)
            XCTAssertEqual(photos.count, 1)
        }
        // 11/7: a cat's page opens from the この子 tab (was ツール) only; 設定
        // has no 猫のプロフィール row. 11/12: the 「この子のこと」 card of the
        // cat on screen (not the cat menu or its items).
        let toolsTab = app.buttons["main-tab-tools"]
        if toolsTab.waitForExistence(timeout: 10) { toolsTab.tap() } else { app.tabBars.buttons["この子"].tap() }
        let firstCat = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@) AND identifier != %@",
            "tools-cat-", "tools-cat-menu", "tools-cat-profiles")).firstMatch
        XCTAssertTrue(firstCat.waitForExistence(timeout: 5))
        let catName = firstCat.identifier.hasSuffix("fixture-cat-1") ? "ソラ" : "ミケ"
        firstCat.tap()
        // 11/12 (round 2): the bar names the page; the name is under the photo.
        XCTAssertTrue(app.navigationBars["この子のこと"].waitForExistence(timeout: 5))
        // 11/7: the cat's one page; the name is changed at its top (11/12:
        // the parts are always open, nothing to unfold first).
        XCTAssertFalse(app.buttons["cat-profile-page-photos"].exists, "The cat's page has no 写真 tab")
        XCTAssertTrue(app.buttons["名前を変更"].waitForExistence(timeout: 5),
                      "The tools must open the profile, without a photo-grid intermediary")
        XCTAssertFalse(app.navigationBars["\(catName)の写真"].exists)
        capture("cat-settings-direct")
        // The tab bar is hidden on the cat's page; going back brings it again.
        app.navigationBars["この子のこと"].buttons.element(boundBy: 0).tap()
        openSettings(in: app)
        XCTAssertFalse(app.buttons["settings-cat-profiles"].exists)

        let photoSettings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "写真の表示と整理")).firstMatch
        for _ in 0..<5 where !photoSettings.isHittable { app.swipeDown() }
        XCTAssertTrue(photoSettings.isHittable)
        photoSettings.tap()
        let source = app.buttons["settings-photo-source"]
        for _ in 0..<5 where !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.isHittable)
        capture("photo-settings-shortcuts")
        source.tap()
        XCTAssertTrue(app.navigationBars["写真の対象"].waitForExistence(timeout: 5))
        capture("photo-source-direct")
        let allPhotos = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "すべての写真")).firstMatch
        XCTAssertTrue(allPhotos.isHittable)
        allPhotos.tap()
        // The photo settings page is titled 「写真の表示と整理」 (10/21).
        XCTAssertTrue(app.navigationBars["写真の表示と整理"].waitForExistence(timeout: 5),
                      "Selecting a source returns directly to photo settings")
        let excluded = app.buttons["settings-excluded-photos"]
        for _ in 0..<5 where !excluded.isHittable { app.swipeUp() }
        XCTAssertTrue(excluded.isHittable)
        excluded.tap()
        XCTAssertTrue(app.navigationBars["外した写真"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["写真の対象"].exists)
        app.terminate()

        // The cat-list entrance keeps browsing prominent; secondary actions
        // still reach their original destinations without changing membership.
        app.launchArguments = ["--cat-profile-photo-flow-fixture", "--cat-profile-list-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(app.navigationBars["猫ごとの写真"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "cat-profile-open").count, 2)
        XCTAssertFalse(app.staticTexts["単頭設定からの引き継ぎ"].exists)
        XCTAssertFalse(app.buttons["cat-profiles-unassigned"].exists)
        capture("cat-list-browsing")
        app.buttons["cat-profile-add"].tap()
        XCTAssertTrue(app.navigationBars["写真を選ぶ"].waitForExistence(timeout: 5))
        app.buttons["キャンセル"].tap()
        XCTAssertTrue(app.navigationBars["猫ごとの写真"].waitForExistence(timeout: 5))
        app.buttons["cat-profiles-more"].tap()
        XCTAssertTrue(app.buttons["cat-profiles-unassigned"].waitForExistence(timeout: 5))
        capture("cat-list-menu")
        app.buttons["cat-profiles-unassigned"].tap()
        XCTAssertTrue(app.navigationBars["未分類の写真"].waitForExistence(timeout: 5))
        app.navigationBars["未分類の写真"].buttons.element(boundBy: 0).tap()
        app.buttons["cat-profiles-more"].tap()
        XCTAssertTrue(app.buttons["cat-profiles-about"].waitForExistence(timeout: 5))
        // 前に外した写真 has no entry since 10/31.
        XCTAssertFalse(app.buttons["cat-profiles-excluded"].exists)
        app.buttons["cat-profiles-about"].tap()
        XCTAssertTrue(app.navigationBars["猫ごとの写真について"].waitForExistence(timeout: 5))
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.navigationBars["猫ごとの写真"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "cat-profile-open").count, 2)
        app.terminate()
    }

    @MainActor
    func testCatPhotoRootFilterLargeTextAndViewerReturn() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-screenshot-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "cats"
        app.launch()
        openPhotosTab(in: app)
        // 11/7: the cat switch is a menu above the pages.
        selectPhotoLibraryCat("fixture-cat-0", expectedName: "ミケ", in: app)
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-hub-photo-"))
        XCTAssertEqual(photos.count, 1)
        photos.firstMatch.tap()
        XCTAssertTrue(app.images["photo-detail-zoom-surface"].waitForExistence(timeout: 10))
        app.navigationBars["写真"].buttons.element(boundBy: 0).tap()
        assertPhotoLibraryCat("ミケ", in: app)
        XCTAssertEqual(photos.count, 1)
        selectPhotoLibraryCat("unassigned", expectedName: "未分類", in: app)
        XCTAssertFalse(app.buttons["photo-hub-photo-app-store-screenshot-fixture-1"].exists)
        XCTAssertFalse(app.buttons["photo-hub-photo-app-store-screenshot-fixture-2"].exists)
        capture("photo-filter-largest-text")
        app.terminate()
    }

    @MainActor
    func testPhotosStayUsableWithoutCatRegistrationAndOfferSourceRecoveryOnlyWhenNeeded() {
        for scenario in ["no-cats", "source-unavailable"] {
            let app = XCUIApplication()
            app.launchArguments = ["--app-store-screenshot-fixture", "-AppleLanguages", "(ja)"]
            app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = scenario
            app.launch()
            // 11/1: the アルバム tab is the works shelf in both cases. Without
            // a source it offers no album recovery of its own; recovery is
            // in 写真, where the photos are chosen.
            openWorksAlbumTab(in: app)
            XCTAssertFalse(app.buttons["albums-source-recovery"].exists)
            XCTAssertFalse(app.buttons.matching(identifier: "albums-source-unavailable")
                .matching(NSPredicate(format: "label == %@", "「写真」タブを開く")).firstMatch.exists)
            XCTAssertFalse(app.staticTexts["猫のアルバムがまだありません"].exists)
            capture(scenario == "no-cats" ? "albums-root-standard" : "albums-source-unavailable")
            if scenario == "no-cats" {
                openFavorites(in: app)
                XCTAssertEqual(element("saved-memories-gallery", in: app).value as? String, "お気に入り、9枚",
                               "Favorites include saved photos outside the eight-photo source.")
                let favorite = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "猫の写真")).firstMatch
                XCTAssertTrue(favorite.waitForExistence(timeout: 10))
                favorite.tap()
                XCTAssertTrue(app.images["photo-detail-zoom-surface"].waitForExistence(timeout: 10))
                XCTAssertTrue(element("photo-browser-memory-saved-state", in: app).exists)
                app.navigationBars["写真"].buttons.element(boundBy: 0).tap()
                XCTAssertTrue(element("saved-memories-gallery", in: app).waitForExistence(timeout: 10))
                // The household comparison is a theme of 写真 (11/1), opened
                // without registering a cat; it shows the earlier and later photo.
                openPhotosTab(in: app)
                let album = app.buttons["photos-theme-昔と最近"]
                XCTAssertTrue(album.waitForExistence(timeout: 15), app.debugDescription)
                for _ in 0..<8 where !app.frame.contains(album.frame) { element("photos-theme-row", in: app).swipeLeft() }
                XCTAssertTrue(album.isHittable)
                capture("albums-comparison-standard")
                album.tap()
                XCTAssertTrue(app.navigationBars["昔と最近"].waitForExistence(timeout: 10))
                for year in ["2022", "2025"] {
                    XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
                        format: "label CONTAINS %@ AND label CONTAINS %@", year, "の猫の写真"
                    )).firstMatch.waitForExistence(timeout: 10),
                    "The comparison must expose the \(year) photograph's date.")
                }
                app.navigationBars["昔と最近"].buttons.element(boundBy: 0).tap()
                XCTAssertTrue(app.navigationBars["写真"].waitForExistence(timeout: 10))
                capture("albums-without-cat-registration")
            } else {
                openPhotosTab(in: app)
            }
            // No registered cat: the photos stay usable without a cat switch (11/7).
            XCTAssertTrue(app.navigationBars["写真"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["photos-cat-picker"].exists)
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
        app.buttons["お気に入りに追加"].tap()
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
        XCTAssertTrue(app.buttons["お気に入りに追加"].isHittable)
        capture("local-photo-quality-recovered-same-viewport")
        app.buttons["お気に入りに追加"].tap()
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
                XCTAssertTrue((app.descendants(matching: .any)["photo-browser-date"].firstMatch.value as? String ?? "")
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
    func testCommonCatFilterPersistsAcrossPhotoModesAndViewer() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-screenshot-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "cats"
        app.launch()
        openPhotosTab(in: app)
        // 11/7: one cat switch (a menu) over all three pages.
        selectPhotoLibraryCat("fixture-cat-0", expectedName: "ミケ", in: app)
        for mode in ["favorites", "notes", "all"] {
            let section = app.buttons["photos-section-\(mode)"]
            section.tap()
            // The section is kept once the pages come to rest (11/7 pager).
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isSelected == true"), object: section)], timeout: 5), .completed)
            assertPhotoLibraryCat("ミケ", in: app)
            if mode == "favorites" {
                XCTAssertFalse(app.buttons["saved-memory-photo-app-store-screenshot-fixture-2"].exists)
            } else if mode == "notes" {
                let sort = app.buttons["memory-notes-sort"]
                XCTAssertTrue(sort.waitForExistence(timeout: 10))
                XCTAssertEqual(app.buttons.matching(identifier: "memory-notes-sort").count, 1)
                XCTAssertTrue(sort.isHittable, "The sort control retains its own accessible identity")
                XCTAssertTrue(sort.label.contains("撮影順"))
                sort.tap()
                app.buttons["更新順"].tap()
                XCTAssertTrue(sort.label.contains("更新順"))
                assertPhotoLibraryCat("ミケ", in: app)
            }
        }
        let photo = app.buttons["photo-hub-photo-app-store-screenshot-fixture-1"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        XCTAssertTrue(app.images["photo-detail-zoom-surface"].waitForExistence(timeout: 10))
        app.navigationBars["写真"].buttons.element(boundBy: 0).tap()
        assertPhotoLibraryCat("ミケ", in: app)
        XCTAssertTrue(photo.isHittable)
        XCTAssertFalse(app.buttons["photo-hub-photo-app-store-screenshot-fixture-2"].exists)
        app.terminate()
    }

    @MainActor
    func testMonthJumpReachesPhotoBeyondInitialGridBatch() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-screenshot-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "paging"
        app.launchEnvironment["NEKO_PHOTO_UI_PREFERENCES_SUITE"] = "PhotoMonthJumpUITest.\(UUID().uuidString)"
        app.launch()
        openPhotosTab(in: app)
        let jump = app.buttons["photo-library-month-jump"]
        XCTAssertTrue(jump.waitForExistence(timeout: 10))
        reveal(jump, in: app)
        jump.tap()
        let september = app.buttons["2025年9月"]
        XCTAssertTrue(september.waitForExistence(timeout: 5))
        september.tap()
        let firstSeptemberPhotoIdentifier = "photo-hub-photo-app-store-screenshot-fixture-page-31"
        let firstSeptemberPhoto = app.buttons[firstSeptemberPhotoIdentifier].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: firstSeptemberPhoto
        )], timeout: 10), .completed)
        XCTAssertEqual(app.buttons.matching(identifier: firstSeptemberPhotoIdentifier).count, 1)
        firstSeptemberPhoto.tap()
        XCTAssertTrue(app.staticTexts["31 / 50"].waitForExistence(timeout: 10))
        app.navigationBars["写真"].buttons.element(boundBy: 0).tap()
        // Returning restores the exact row asynchronously.
        // Wait on that same photo, without scrolling or choosing a substitute.
        print("[PhotoMonthJumpReturn] Back completed; waiting for original page-31 without scrolling")
        let returnedToMonthRow = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: firstSeptemberPhoto)
        let returned = XCTWaiter.wait(for: [returnedToMonthRow], timeout: 5)
        let returnedMatches = app.buttons.matching(identifier: firstSeptemberPhotoIdentifier).count
        if returned != .completed || returnedMatches != 1 {
            capture("photo-grid-month-jump-return-failed")
            let diagnostic = XCTAttachment(string: app.debugDescription)
            diagnostic.name = "photo-grid-month-jump-return-hierarchy"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
        }
        print("[PhotoMonthJumpReturn] waiter=\(returned) matches=\(returnedMatches)")
        XCTAssertEqual(returned, .completed, "Returning restores the same September row")
        XCTAssertEqual(returnedMatches, 1)
        XCTAssertTrue(firstSeptemberPhoto.isHittable)
        capture("photo-grid-month-jump-beyond-first-batch")
        firstSeptemberPhoto.tap()
        XCTAssertTrue(app.staticTexts["31 / 50"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testPhotoGridRevealsFollowingBatchesAndKeepsReturnPosition() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-screenshot-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "paging"
        // Other UI methods also save the photo-list position. This scenario
        // must start with its own empty reading history.
        app.launchEnvironment["NEKO_PHOTO_UI_PREFERENCES_SUITE"] = "PhotoPagingUITest.\(UUID().uuidString)"
        app.launch()
        openPhotosTab(in: app)
        let grid = element("photo-hub-detected-grid", in: app)
        XCTAssertTrue(grid.waitForExistence(timeout: 15))
        // The common cat picker is a separate horizontal ScrollView above
        // the grid. Scroll the photo collection, never the first scroll view.
        let photoList = app.scrollViews["photo-library-all-scroll"]
        XCTAssertTrue(photoList.waitForExistence(timeout: 5))
        for number in [25, 49] {
            let target = app.buttons["photo-hub-photo-app-store-screenshot-fixture-page-\(number)"]
            for _ in 0..<14 where !target.isHittable { photoList.swipeUp() }
            XCTAssertTrue(target.isHittable, "Scrolling alone reaches photo \(number)")
            XCTAssertEqual(app.buttons.matching(identifier: target.identifier).count, 1)
            target.tap()
            XCTAssertTrue(app.staticTexts["\(number) / 50"].waitForExistence(timeout: 10))
            app.navigationBars["写真"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(target.waitForExistence(timeout: 10))
            let returnedToRow = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == true"), object: target)
            XCTAssertEqual(XCTWaiter.wait(for: [returnedToRow], timeout: 5), .completed,
                           "Returning preserves the opened row")
        }
        XCTAssertFalse(app.buttons["もっと見る"].exists)
        capture("photo-grid-scrolled-to-last-batch")
        app.terminate()
    }

    @MainActor
    func testInitialScanPreviewPreservesUnavailableLabelAndOpensPhoto() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-screenshot-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] = "unavailable"
        app.launch()
        let failure = app.descendants(matching: .any)
            .matching(identifier: "写真を表示できません").firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        let preview = app.buttons["initial-scan-photo-mainline-unavailable-photo"]
        XCTAssertEqual(preview.label, "写真を表示できません")
        XCTAssertTrue(preview.isHittable)
        XCTAssertTrue(app.buttons["initial-scan-continue"].isHittable)
        capture("initial-scan-unavailable-accessible-preview")
        preview.tap()
        let close = app.buttons["first-run-photo-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["photo-memory-note-open"].exists)
        capture("initial-scan-unavailable-opened-photo")
        close.tap()
        // 11/12: closing the photo returns to the scan page; the first run
        // goes on, so its next step is still there.
        XCTAssertTrue(app.buttons["initial-scan-continue"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["mainline-fixture-finished"].exists)
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
            XCTAssertTrue(retry.isHittable, "The monthly browser must leave retry reachable")
            retry.tap()
            XCTAssertTrue(element("monthly-window-browser", in: app).waitForExistence(timeout: 10))
            // 10/21: one bookmark under the photo; its label is the action it
            // takes next, so a saved photo reads 「お気に入りから外す」.
            let save = app.buttons["お気に入りに追加"]
            let savedState = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@",
                "photo-browser-memory-saved-state", "お気に入りから外す")).firstMatch
            XCTAssertTrue(save.waitForExistence(timeout: 10))
            XCTAssertEqual(save.label, "お気に入りに追加")
            save.tap()
            let request = app.staticTexts["monthly-fixture-memory-request"]
            let requested = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", "app-store-screenshot-fixture-1|true"),
                object: request
            )
            XCTAssertEqual(XCTWaiter.wait(for: [requested], timeout: 5), .completed)
            if scenario == "monthly-save-unconfirmed" {
                XCTAssertEqual(save.label, "お気に入りに追加", "A request alone is not a saved result")
                XCTAssertFalse(savedState.exists)
            } else {
                XCTAssertTrue(savedState.waitForExistence(timeout: 5))
                XCTAssertEqual(savedState.label, "お気に入りから外す")
                // The app's own favorite is removed by its one tap (no dialog).
                savedState.tap()
                let removed = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label == %@", "app-store-screenshot-fixture-1|false"),
                    object: request
                )
                XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
                XCTAssertTrue(save.waitForExistence(timeout: 5))
                XCTAssertFalse(savedState.exists)
                XCTAssertEqual(app.alerts.count, 0)
                save.tap()
                XCTAssertTrue(savedState.waitForExistence(timeout: 5))
                capture("monthly-memory-resaved")
            }
            app.terminate()
        }
    }

    @MainActor
    func testAlbumRelatedPhotoRoutesPreserveScopeAndReturnToOrigin() throws {
        let fullAccessLabels = ["Allow Full Access", "Allow Access to All Photos",
                                "フルアクセスを許可", "すべての写真へのアクセスを許可"]
        let acceptPhotosAccess: (XCUIElement) -> Bool = { alert in
            guard alert.staticTexts.allElementsBoundByIndex.contains(where: {
                $0.label.localizedCaseInsensitiveContains("photos") || $0.label.contains("写真")
            }), let button = fullAccessLabels.map({ alert.buttons[$0] }).first(where: { $0.exists }) else {
                return false
            }
            button.tap()
            return true
        }
        // This fixture expects photo access. Do not let XCTest's default
        // interruption handler silently deny it during the Menu tap.
        let photosMonitor = addUIInterruptionMonitor(withDescription: "Related photo fixture Photos authorization",
                                                     handler: acceptPhotosAccess)
        defer { removeUIInterruptionMonitor(photosMonitor) }
        func hittableElements(_ query: XCUIElementQuery, count: Int = 1, timeout: TimeInterval = 5,
                              file: StaticString = #filePath, line: UInt = #line) throws -> [XCUIElement] {
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                query.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.count == count
            }, object: nil)
            let result = XCTWaiter.wait(for: [visible], timeout: timeout)
            if result != .completed {
                capture("photo-related-foreground-failure")
                print("RELATED_MENU_QUERY_FAILURE \(query.debugDescription)")
                print("RELATED_MENU_APP_FAILURE \(XCUIApplication().debugDescription)")
            }
            XCTAssertEqual(result, .completed,
                           "Expected exactly \(count) foreground elements", file: file, line: line)
            let matches = query.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            return try XCTUnwrap(matches.count == count ? matches : nil,
                                 "Foreground elements changed before use", file: file, line: line)
        }
        func foreground(_ query: XCUIElementQuery, timeout: TimeInterval = 5,
                        file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
            try hittableElements(query, timeout: timeout, file: file, line: line)[0]
        }
        func closeSheet(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
            let close = app.buttons.matching(identifier: "photo-related-close")
            try foreground(close, file: file, line: line).tap()
            _ = try hittableElements(close, count: 0, file: file, line: line)
        }

        for largeText in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--app-store-screenshot-fixture",
                "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
                + (largeText ? ["--ux-large-text"] : [])
            app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "rediscovery"
            app.resetAuthorizationStatus(for: .photos)
            app.launch()
            defer { app.terminate() }
            // 10/19: 「関連する写真」 is a submenu of the photo's 「…」 menu,
            // next to 同じ日の写真.
            let more = app.buttons.matching(identifier: "photo-browser-related")
            let related = app.buttons.matching(NSPredicate(format: "label == %@", "関連する写真"))
            let relatedItems = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-related-"))
            func openRelated(expectingLabel: Bool = false) throws {
                try foreground(more).tap()
                if expectingLabel { XCTAssertEqual(try foreground(related).label, "関連する写真") }
                try foreground(related).tap()
                // A tap that lands while the menu is still appearing does not
                // open the submenu; tap the same visible item once more.
                if !relatedItems.firstMatch.waitForExistence(timeout: 5) {
                    try foreground(related).tap()
                }
            }
            // The 「関連する写真」 submenu can fold back into the 「…」 menu, or the
            // menu close, while it is read (runs 42545036862 and 42556129520 on the
            // hosted Simulator). Open it again, at most twice; every item must
            // still be shown, exactly once.
            func visible(_ query: XCUIElementQuery) -> [XCUIElement] {
                query.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            }
            func inRelated(_ query: XCUIElementQuery) throws -> XCUIElement {
                for _ in 0..<2 {
                    let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in visible(query).count == 1 }, object: nil)
                    if XCTWaiter.wait(for: [shown], timeout: 3) == .completed { break }
                    if let parent = visible(related).first {
                        parent.tap()
                    } else if let menu = visible(more).first {
                        menu.tap()
                        if related.firstMatch.waitForExistence(timeout: 3), let parent = visible(related).first { parent.tap() }
                    }
                }
                return try foreground(query)
            }
            let sameDay = app.buttons.matching(identifier: "photo-browser-same-day")
            let thisPhotoSameDay = app.buttons.matching(identifier: "cloudy-photo-same-day")
            let secondDayPhoto = app.buttons.matching(identifier: "day-photos-photo-app-store-screenshot-fixture-2")
            let secondPage = app.staticTexts.matching(NSPredicate(format: "label == %@", "2 / 2"))
            let back = app.buttons.matching(identifier: "BackButton")
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for alert in springboard.alerts.allElementsBoundByIndex where alert.exists {
                if acceptPhotosAccess(alert) {
                    XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "Photos alert must finish before the route check")
                    print("RELATED_MENU_PHOTOS_EXPLICITLY_ACCEPTED")
                }
            }
            _ = try foreground(more, timeout: 15)
            XCTAssertEqual(try foreground(more).label, "写真のその他の操作")
            capture(largeText ? "photo-related-largest-text" : "photo-related-widget-detail")
            try openRelated(expectingLabel: true)
            let theme = app.buttons.matching(identifier: "photo-related-theme-close_up")
            let cat = app.buttons.matching(identifier: "photo-related-cat-fixture-cat-0")
            let year = app.buttons.matching(identifier: "photo-related-year-calendar_year_2025")
            capture(largeText ? "photo-related-menu-probe-largest-text" : "photo-related-menu-probe")
            print("RELATED_MENU_APP_AFTER_TAP \(app.debugDescription)")
            for (role, query) in [
                ("buttons-id", app.buttons.matching(identifier: "photo-related-theme-close_up")),
                ("menuItems-id", app.menuItems.matching(identifier: "photo-related-theme-close_up")),
                ("any-id", app.descendants(matching: .any).matching(identifier: "photo-related-theme-close_up")),
                ("any-label", app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "同じテーマ、大きく写った猫")))
            ] {
                let elements = query.allElementsBoundByIndex
                print("RELATED_MENU_TRACE role=\(role) count=\(elements.count)")
                for element in elements {
                    print("RELATED_MENU_ELEMENT type=\(element.elementType.rawValue) id=\(element.identifier) label=\(element.label) frame=\(element.frame) exists=\(element.exists) enabled=\(element.isEnabled) hittable=\(element.isHittable)")
                }
            }
            _ = try inRelated(theme)
            _ = try inRelated(cat)
            XCTAssertEqual(try inRelated(cat).label, "この猫、ミケ")
            _ = try inRelated(year)
            _ = try hittableElements(app.buttons.matching(identifier: "photo-related-cat-fixture-cat-1"), count: 0)
            capture(largeText ? "photo-related-menu-largest-text" : "photo-related-menu")
            if largeText { app.terminate(); continue }

            try foreground(year).tap()
            let thirdYearPhoto = app.buttons.matching(identifier: "curated-album-photo-calendar_year_2025-app-store-screenshot-fixture-3")
            _ = try foreground(thirdYearPhoto)
            try closeSheet(in: app)
            // 11/8 (01c5937e): on 「この1枚」 the same-day link is the one under
            // the photo; the 「…」 menu does not repeat it (one door).
            try foreground(thisPhotoSameDay).tap()
            try foreground(secondDayPhoto).tap()
            _ = try foreground(secondPage)
            try openRelated()
            try inRelated(theme).tap()
            let secondThemePhoto = app.buttons.matching(identifier: "curated-album-photo-close_up-app-store-screenshot-fixture-2")
            _ = try foreground(secondThemePhoto)
            _ = try hittableElements(app.buttons.matching(identifier: "curated-album-photo-close_up-app-store-screenshot-fixture-3"), count: 0)
            try foreground(secondThemePhoto).tap()
            _ = try foreground(more)
            _ = try foreground(app.buttons.matching(identifier: "photo-related-close"))
            capture("photo-related-sheet-photo")
            try openRelated()
            try inRelated(cat).tap()
            let firstCatPhoto = app.buttons.matching(identifier: "curated-album-photo-all_cat_photos-app-store-screenshot-fixture-1")
            _ = try foreground(firstCatPhoto)
            _ = try hittableElements(app.buttons.matching(identifier: "curated-album-photo-all_cat_photos-app-store-screenshot-fixture-3"), count: 0)
            try foreground(firstCatPhoto).tap()
            try foreground(more).tap()
            try foreground(sameDay).tap()
            try foreground(secondDayPhoto).tap()
            _ = try foreground(secondPage)
            try openRelated()
            _ = try inRelated(year)
            _ = try hittableElements(app.buttons.matching(identifier: "photo-related-cat-fixture-cat-1"), count: 0)
            try foreground(year).tap()
            _ = try foreground(app.buttons.matching(identifier: "curated-album-photo-calendar_year_2025-app-store-screenshot-fixture-1"))
            // All three fixture cards would be on screen; only this cat's two belong here.
            _ = try hittableElements(thirdYearPhoto, count: 0)
            capture("photo-related-year-keeps-cat-scope")
            try foreground(back).tap()
            _ = try foreground(secondPage) // The sheet's same-day photo, not the original behind it.
            try foreground(back).tap()
            _ = try foreground(secondDayPhoto)
            try closeSheet(in: app)
            _ = try foreground(secondPage) // Closing preserves the original collection's second photo.
            try foreground(back).tap()
            _ = try foreground(secondDayPhoto)
            try foreground(back).tap()
            _ = try foreground(app.descendants(matching: .any).matching(identifier: "photo-browser-date"))
            try foreground(back).tap()
            // Photos restores its last section. Select the scope that owns
            // the cat shortcuts instead of assuming a fresh "all" section.
            try foreground(app.buttons.matching(identifier: "photos-section-all")).tap()
            // 11/7: the cat switch is a menu above the pages.
            let catPicker = app.buttons.matching(identifier: "photos-cat-picker")
            try foreground(catPicker).tap()
            try foreground(app.buttons.matching(identifier: "photos-cat-fixture-cat-0")).tap()
            let catPhotos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-hub-photo-"))
            // This grid deliberately contains two choices; open its first visible card.
            try hittableElements(catPhotos, count: 2)[0].tap()
            try openRelated()
            try inRelated(year).tap()
            try closeSheet(in: app)
            _ = try foreground(app.buttons.matching(identifier: "photo-memory-note-open"))
            try foreground(back).tap()
            XCTAssertTrue(app.navigationBars["写真"].waitForExistence(timeout: 5))
            _ = try hittableElements(catPhotos, count: 2)
            XCTAssertEqual(try foreground(catPicker).value as? String, "ミケ")
            app.terminate()
        }
    }

    @MainActor
    func testSameDayRediscoveryOpensAndSavesTheTappedPhoto() {
        let app = launch("rediscovery")
        let sameDay = app.buttons["photo-browser-same-day"]
        let menu = app.buttons["photo-browser-related"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
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

        let save = app.buttons["お気に入りに追加"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        for _ in 0..<3 where !save.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(save.isHittable)
        save.tap()
        let requested = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "app-store-screenshot-fixture-2|true"),
            object: app.staticTexts["solo-rediscovery-memory-request"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [requested], timeout: 10), .completed)
        // 10/21: the bookmark's label is the next action; saved reads 「お気に入りから外す」.
        let savedState = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@",
            "photo-browser-memory-saved-state", "お気に入りから外す")).firstMatch
        XCTAssertTrue(savedState.waitForExistence(timeout: 10))
        capture("solo-rediscovery-same-day-second-photo-saved")

        // The app's own favorite is removed by its one tap (no dialog).
        savedState.tap()
        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "app-store-screenshot-fixture-2|false"),
            object: app.staticTexts["solo-rediscovery-memory-request"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        XCTAssertEqual(app.alerts.count, 0)
        app.buttons["お気に入りに追加"].tap()
        XCTAssertTrue(savedState.waitForExistence(timeout: 5))

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
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        // The entry browser contains only the first photo; the same-day
        // collection contains two. Only its second photo was saved above.
        XCTAssertTrue(app.buttons["お気に入りに追加"].isHittable,
                      "Two back actions return to the original, unsaved photo")
        XCTAssertFalse(savedState.exists)
        app.terminate()
    }

    @MainActor
    func testEmptyAndSingleFavoriteRemainReachableIncludingDeniedAccess() {
        for scenario in ["empty", "saved", "denied"] {
            let app = launch(scenario)
            assertAlbumsRoot(in: app)
            openFavorites(in: app)
            let favorites = element("saved-memories-gallery", in: app)
            XCTAssertEqual(favorites.value as? String, scenario == "denied"
                ? "お気に入り、写真へのアクセスが必要です" : "お気に入り、\(scenario == "saved" ? 1 : 0)枚")
            if scenario == "saved" {
                waitForLoadedPhotos([9], in: app)
                let selection = app.buttons["saved-memories-selection-toggle"]
                XCTAssertTrue(selection.isHittable)
                XCTAssertFalse(app.buttons["photo-book-export"].exists,
                               "Opening favorites must start in browsing mode.")
                capture("albums-single-favorite")
                // No PDF chooser since 10/31: test builds open 本のイメージ directly.
                selection.tap()
                XCTAssertFalse(app.buttons["saved-memories-create-pdf"].exists)
                XCTAssertTrue(app.buttons["book-demand-preview"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons["book-demand-preview"].isEnabled)
                XCTAssertTrue(app.staticTexts["0枚を選択"].exists)
                XCTAssertFalse(app.buttons["photo-book-export"].exists)
                selection.tap()
                XCTAssertTrue(app.navigationBars["写真"].waitForExistence(timeout: 5))
            } else {
                if scenario == "denied" {
                    XCTAssertTrue(element("saved-memories-photo-access-unavailable", in: app).waitForExistence(timeout: 5))
                    XCTAssertFalse(app.staticTexts["まだありません"].exists)
                } else {
                    XCTAssertTrue(app.staticTexts["まだありません"].waitForExistence(timeout: 5))
                }
                XCTAssertFalse(app.buttons["saved-memories-selection-toggle"].exists)
                if scenario == "empty" { capture("albums-empty-favorites") }
            }
            returnFromFavorites(in: app)
            if scenario != "saved" {
                let photos = albumOpenPhotosButton(in: app)
                XCTAssertTrue(photos.waitForExistence(timeout: 10))
                XCTAssertTrue(photos.isHittable)
                photos.tap()
                XCTAssertTrue(app.navigationBars["写真"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.buttons["photos-section-all"].isSelected)
                returnFromFavorites(in: app)
                assertAlbumsRoot(in: app)
            }
            if scenario == "denied" {
                fixtureAction("solo-memories-toggle-access", in: app, expectedValue: "写真アクセスあり")
                assertAlbumsRoot(in: app)
                openFavorites(in: app)
                XCTAssertEqual(favorites.value as? String, "お気に入り、1枚")
                returnFromFavorites(in: app)
                XCTAssertTrue(monthlyCard(in: app).waitForExistence(timeout: 10))
            } else {
                XCTAssertFalse(monthlyCard(in: app).exists)
            }
            app.terminate()
        }
    }

    @MainActor
    func testAlbumMemoReadFailureCanRetryAndKeepRecoveredMemoOnReturn() {
        let app = launch("memo", arguments: ["--photo-window-ui-fixture", "--album-memos-fail-once"])
        assertAlbumsRoot(in: app)
        let retry = app.buttons["albums-memo-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(retry.isHittable)
        XCTAssertFalse(app.buttons["albums-memo-featured"].exists)
        capture("albums-memo-read-failed")
        retry.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: retry
        )], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["albums-memo-featured"].exists)
        let memo = openMemoNotes(in: app)
        XCTAssertTrue(memo.label.contains("はじめてのおふろ"))
        let memoLabel = memo.label
        memo.tap()
        XCTAssertTrue(app.buttons["memory-note-photo"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(memo.waitForExistence(timeout: 10))
        XCTAssertEqual(memo.label, memoLabel)
        returnFromFavorites(in: app)
        XCTAssertFalse(retry.exists, "Returning must retain the successful album memo reload.")
        capture("albums-memo-read-recovered")
        app.terminate()
    }

    @MainActor
    func testAlbumGroupedScanFailureDoesNotRemainPreparing() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-screenshot-fixture", "-AppleLanguages", "(ja)"]
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "album-scan-failed"
        app.launch()
        // 11/1: the アルバム tab is the works shelf and the scan's state is
        // shown with the photos in 写真. A failed grouped scan says so there,
        // with a retry, and neither tab keeps saying it is preparing.
        openWorksAlbumTab(in: app)
        XCTAssertFalse(app.staticTexts["新しいアルバムを準備しています"].exists)
        XCTAssertFalse(app.staticTexts["アルバムを準備しています"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["albums-preparing"].exists)
        openPhotosTab(in: app)
        XCTAssertTrue(app.staticTexts["写真を最後まで探せませんでした"].waitForExistence(timeout: 10), app.debugDescription)
        // The status's own identifier is given to its button (iOS 26), so
        // the retry is read by its role and visible title.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "もう一度探す")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["新しいアルバムを準備しています"].exists)
        XCTAssertFalse(app.staticTexts["アルバムを準備しています"].exists)
        XCTAssertFalse(app.staticTexts["猫の写真を探しています"].exists)
        capture("albums-grouped-scan-failed")
        app.terminate()
    }

    @MainActor
    func testAlbumRootUpdatesAndPreservesFavoritesAndReflectionDestinations() {
        let memoApp = launch("memo", arguments: ["--photo-window-ui-fixture"])
        assertAlbumsRoot(in: memoApp)
        XCTAssertFalse(memoApp.buttons["albums-memo-featured"].exists)
        let memoCard = openMemoNotes(in: memoApp)
        let memoLabel = memoCard.label
        XCTAssertTrue(memoLabel.contains("はじめてのおふろ"))
        capture("photos-local-memo")
        memoCard.tap()
        XCTAssertTrue(memoApp.buttons["memory-note-photo"].waitForExistence(timeout: 10))
        XCTAssertTrue(memoApp.staticTexts["はじめてのおふろ"].exists)
        XCTAssertTrue(memoApp.buttons["memory-note-edit"].exists)
        memoApp.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(memoCard.waitForExistence(timeout: 10))
        XCTAssertEqual(memoCard.label, memoLabel, "Returning must retain the local memo.")
        returnFromFavorites(in: memoApp)
        fixtureAction("solo-memories-toggle-access", in: memoApp, expectedValue: "写真アクセスなし")
        let unavailableMemo = openMemoNotes(in: memoApp)
        XCTAssertEqual(unavailableMemo.label, memoLabel, "Photo authority changes must preserve local memo text.")
        XCTAssertTrue(unavailableMemo.isHittable)
        // The center remains tappable when removing the thumbnail leaves a
        // transparent gap between the memo text and the disclosure chevron.
        unavailableMemo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(memoApp.navigationBars["メモ"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("memory-note-photo-unavailable", in: memoApp).waitForExistence(timeout: 10))
        XCTAssertFalse(memoApp.buttons["memory-note-photo"].exists, "A local memo must not bypass photo access.")
        memoApp.navigationBars.buttons.element(boundBy: 0).tap()
        returnFromFavorites(in: memoApp)
        fixtureAction("solo-memories-toggle-access", in: memoApp, expectedValue: "写真アクセスあり")
        let restoredMemo = openMemoNotes(in: memoApp)
        XCTAssertEqual(restoredMemo.label, memoLabel)
        restoredMemo.tap()
        XCTAssertTrue(memoApp.buttons["memory-note-photo"].waitForExistence(timeout: 10))
        memoApp.navigationBars.buttons.element(boundBy: 0).tap()
        returnFromFavorites(in: memoApp)
        memoApp.terminate()

        let app = launch("saved")
        assertAlbumsRoot(in: app)
        fixtureAction("solo-memories-add-letter", in: app, expectedValue: "便りあり")
        assertAlbumsRoot(in: app)
        XCTAssertTrue(monthlyCard(in: app).waitForExistence(timeout: 10))

        fixtureAction("solo-memories-toggle-access", in: app, expectedValue: "写真アクセスなし")
        assertAlbumsRoot(in: app)
        XCTAssertFalse(monthlyCard(in: app).exists)
        let openPhotos = albumOpenPhotosButton(in: app)
        XCTAssertTrue(openPhotos.waitForExistence(timeout: 5))
        XCTAssertTrue(openPhotos.isHittable)
        fixtureAction("solo-memories-toggle-access", in: app, expectedValue: "写真アクセスあり")
        assertAlbumsRoot(in: app)
        openCardAndReturn(monthlyCard(in: app), expectedRoute: "monthly:2025-08", in: app)
        visitOtherScreenAndReturn(in: app)
        assertAlbumsRoot(in: app)

        openFavorites(in: app)
        let favorite = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "猫の写真")).firstMatch
        openCardAndReturn(favorite, expectedRoute: "photo:app-store-screenshot-fixture-9", in: app)
        XCTAssertTrue(element("saved-memories-gallery", in: app).waitForExistence(timeout: 10))
        returnFromFavorites(in: app)
        app.terminate()

        // The pickup and the fixed month list open the same chronological pager.
        let readyApp = launch("monthly")
        assertAlbumsRoot(in: readyApp)
        XCTAssertTrue(monthlyCard(in: readyApp).waitForExistence(timeout: 10))
        waitForLoadedPhotos([1], in: readyApp)
        capture("albums-monthly-ready")
        monthlyCard(in: readyApp).tap()
        XCTAssertTrue(element("monthly-window-browser", in: readyApp).waitForExistence(timeout: 10))
        let monthlyDestination = element("solo-memories-monthly-destination", in: readyApp)
        XCTAssertTrue(monthlyDestination.waitForExistence(timeout: 10))
        XCTAssertEqual(monthlyDestination.label, "2025-08")
        XCTAssertEqual(monthlyDestination.value as? String,
            (1...5).map { "app-store-screenshot-fixture-\($0)" }.joined(separator: "|"))
        XCTAssertTrue(readyApp.staticTexts["1 / 5"].waitForExistence(timeout: 5))
        let image = readyApp.images["photo-detail-zoom-surface"].firstMatch
        image.swipeLeft()
        XCTAssertTrue(readyApp.staticTexts["2 / 5"].waitForExistence(timeout: 5))
        readyApp.buttons["お気に入りに追加"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "app-store-screenshot-fixture-2|true"),
            object: readyApp.staticTexts["solo-memories-highlight-memory-request"]
        )], timeout: 5), .completed)
        XCTAssertTrue(readyApp.buttons["photo-browser-memory-saved-state"].waitForExistence(timeout: 5))
        XCTAssertFalse(readyApp.buttons["photo-browser-deliver"].exists)
        XCTAssertTrue(readyApp.staticTexts["2 / 5"].exists)
        XCTAssertTrue(readyApp.buttons["photo-browser-memory-saved-state"].exists)
        readyApp.navigationBars["8月の作品"].buttons.element(boundBy: 0).tap()
        assertAlbumsRoot(in: readyApp)
        monthlyCard(in: readyApp).tap()
        XCTAssertTrue(readyApp.staticTexts["1 / 5"].waitForExistence(timeout: 5))
        image.swipeLeft()
        XCTAssertTrue(readyApp.staticTexts["2 / 5"].waitForExistence(timeout: 5))
        XCTAssertTrue(readyApp.buttons["photo-browser-memory-saved-state"].waitForExistence(timeout: 5),
                      "The saved second photo must remain saved after leaving and reopening the month.")
        capture("albums-monthly-second-photo-saved-and-reopened")
        readyApp.navigationBars["8月の作品"].buttons.element(boundBy: 0).tap()
        assertAlbumsRoot(in: readyApp)
        XCTAssertFalse(element("albums-highlights-all", in: readyApp).exists,
                       "The heading must not create a redundant overview destination.")
        // 10/20: months and movies share one list, 「これまでの月のまとめ・
        // 季節のムービー」, under ふりかえり.
        openReflectionsArchive(in: readyApp)
        let previousMonth = element("albums-month-2025-07", in: readyApp)
        reveal(previousMonth, in: readyApp)
        XCTAssertTrue(previousMonth.label.contains("1枚"))
        capture("albums-monthly-date-rows")
        openCardAndReturn(previousMonth, expectedRoute: "monthly:2025-07", in: readyApp)
        XCTAssertTrue(readyApp.navigationBars[reflectionsArchiveTitle].waitForExistence(timeout: 10))
        capture("albums-reflections-archive-return")
        readyApp.navigationBars[reflectionsArchiveTitle].buttons.element(boundBy: 0).tap()
        assertAlbumsRoot(in: readyApp)
        readyApp.terminate()
    }

    @MainActor
    func testHighlightsPageThroughTheirPhotosAndReopenFromTheCard() {
        for scenario in ["highlights", "highlights-large", "highlights-cats"] {
            let app = launch(scenario)
            assertAlbumsRoot(in: app)
            if scenario == "highlights-cats" {
                openFavorites(in: app)
                let favoritesValue = element("saved-memories-gallery", in: app).value as? String
                returnFromFavorites(in: app)
                XCTAssertFalse(element("albums-cat-fixture-cat-0", in: app).exists)
                // 10/20: months and movies share one list, 「これまでの月のまとめ・
                // 季節のムービー」, under ふりかえり; open each from there.
                let title = "月の作品・季節のムービー"
                for (route, cardID) in [
                    ("monthly:2025-08", "memories-monthly-window"),
                    ("seasonal:2025-Q3", "albums-seasonal-movie")
                ] {
                    let entry = app.buttons.matching(NSPredicate(format: "label == %@",
                        "これまでの月の作品・季節のムービー")).firstMatch
                    reveal(entry, in: app)
                    entry.tap()
                    XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
                    XCTAssertTrue(element("albums-reflections-archive", in: app).waitForExistence(timeout: 5))
                    openCardAndReturn(element(cardID, in: app), expectedRoute: route, in: app)
                    XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
                    app.navigationBars[title].buttons.element(boundBy: 0).tap()
                    assertAlbumsRoot(in: app)
                }
                openFavorites(in: app)
                XCTAssertEqual(element("saved-memories-gallery", in: app).value as? String, favoritesValue,
                               "Household month and movie browsing must retain the complete favorites collection.")
                returnFromFavorites(in: app)
                capture("albums-household-entries-with-registered-cats")
                app.terminate()
                continue
            }
            let firstFeatured = element("albums-highlight-featured", in: app)
            XCTAssertTrue(firstFeatured.waitForExistence(timeout: 10))
            reveal(firstFeatured, in: app)
            XCTAssertFalse(element("albums-highlights-all", in: app).exists)
            XCTAssertTrue(element("albums-pickup-cover", in: app).exists)
            XCTAssertEqual(app.buttons.matching(identifier: "albums-highlight-featured").count, 1,
                           "The root offers one photo collection rather than a carousel.")
            let featured = firstFeatured
            let featuredLabel = featured.label
            featured.tap()
            let destination = app.staticTexts["solo-memories-highlight-destination"]
            XCTAssertTrue(destination.waitForExistence(timeout: 10))
            let highlightID = destination.label
            let expectedNumbers: [Int]
            switch highlightID {
            case "highlight-2025-08-close_up": expectedNumbers = [1, 2, 3]
            case "highlight-2025-08-together": expectedNumbers = [4, 5, 6]
            case "highlight-2025-08-multiple_cats": expectedNumbers = [7, 8, 9]
            case "highlight-2025-08-outing": expectedNumbers = [10, 11, 12]
            case "highlight-2025-02-cat_day": expectedNumbers = [13, 14, 15]
            case "highlight-2025-07-close_up": expectedNumbers = [16, 17, 18]
            default:
                XCTFail("Unexpected featured collection: \(highlightID)")
                app.terminate()
                return
            }
            assertHighlightPhotos(expectedNumbers, in: app,
                                  pagesThroughAll: !scenario.hasSuffix("-large"))
            capture("albums-\(scenario)-browser")
            app.navigationBars["写真"].buttons.element(boundBy: 0).tap()
            assertAlbumsRoot(in: app)
            let returned = app.buttons.matching(identifier: "albums-highlight-featured")
                .matching(NSPredicate(format: "label == %@", featuredLabel)).firstMatch
            XCTAssertTrue(returned.waitForExistence(timeout: 10))
            XCTAssertTrue(returned.isHittable)
            waitForLoadedPhotos([expectedNumbers[0]], in: app)
            capture("albums-\(scenario)-featured")

            let closeUp = element("album-card-close_up", in: app)
            if scenario.hasSuffix("-large") {
                reveal(closeUp, in: app)
                XCTAssertGreaterThan(closeUp.frame.width, app.frame.width / 2)
            } else {
                let pair = element("album-card-multiple_cats", in: app)
                reveal(pair, in: app)
                let together = element("album-card-together", in: app)
                XCTAssertTrue(pair.isHittable)
                XCTAssertTrue(together.isHittable)
                XCTAssertEqual(pair.frame.minY, together.frame.minY, accuracy: 2)
                XCTAssertLessThan(pair.frame.maxX, together.frame.minX)
                reveal(closeUp, in: app)
                XCTAssertTrue(closeUp.isHittable, "The third theme must remain reachable below the first row.")
            }
            capture("albums-\(scenario)-themes")
            openCardAndReturn(closeUp, expectedRoute: "album:close_up", in: app)

            // Reopen the same card; navigating into a theme must retain it.
            // A large-text card can be partly hittable while its center is
            // covered by the navigation bar. Tap only after its center clears
            // that bar; otherwise XCTest taps the overlay instead of the card.
            let visibleTop = app.navigationBars.firstMatch.frame.maxY + 24
            for _ in 0..<8 where !returned.isHittable || returned.frame.midY <= visibleTop {
                app.scrollViews.firstMatch.swipeDown()
            }
            XCTAssertTrue(returned.isHittable)
            XCTAssertGreaterThan(returned.frame.midY, visibleTop)
            capture("albums-\(scenario)-reopen-target")
            returned.tap()
            XCTAssertTrue(destination.waitForExistence(timeout: 10))
            XCTAssertEqual(destination.label, highlightID)
            assertHighlightPhotos(expectedNumbers, in: app, pagesThroughAll: false, alreadySaved: true)
            app.navigationBars["写真"].buttons.element(boundBy: 0).tap()
            assertAlbumsRoot(in: app)
            app.terminate()
        }
    }

    @MainActor
    func testSparsePhotosAndDeniedAccessDoNotOfferEmptyHighlights() {
        for scenario in ["highlights-few", "highlights-denied"] {
            let app = launch(scenario)
            assertAlbumsRoot(in: app)
            XCTAssertFalse(element("albums-highlight-featured", in: app).exists)
            XCTAssertFalse(element("albums-highlights-all", in: app).exists)
            if scenario.hasSuffix("-few") {
                let theme = element("album-card-close_up", in: app)
                reveal(theme, in: app)
                XCTAssertTrue(theme.label.contains("2枚"))
                capture("albums-highlights-two-scenes")
                openCardAndReturn(theme, expectedRoute: "album:close_up", in: app)
            } else {
                XCTAssertFalse(element("album-card-close_up", in: app).exists)
                let photos = albumOpenPhotosButton(in: app)
                XCTAssertTrue(photos.waitForExistence(timeout: 5))
                XCTAssertTrue(photos.isHittable)
                capture("albums-highlights-denied")
                photos.tap()
                XCTAssertTrue(app.buttons["home-photo-permission"].waitForExistence(timeout: 5))
                returnFromFavorites(in: app)
            }
            assertAlbumsRoot(in: app)
            app.terminate()
        }
    }

    @MainActor
    func testAlbumCoversAndFavoritesRemainReachableWithLargestText() {
        let app = launch("seasonal-large")
        assertAlbumsRoot(in: app)
        // 10/20: the latest movie is shown in ふりかえり on the album itself; no
        // month exists before the letter is added below.
        XCTAssertFalse(monthlyCard(in: app).exists)
        let rootMovie = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@ AND label CONTAINS %@",
            ["albums-seasonal-movie", "memories-summaries-section"], "場面"
        )).firstMatch
        XCTAssertTrue(rootMovie.waitForExistence(timeout: 10), app.debugDescription)
        openReflectionsArchive(in: app)
        let seasonalCard = element("albums-seasonal-movie", in: app)
        XCTAssertTrue(seasonalCard.waitForExistence(timeout: 10))
        reveal(seasonalCard, in: app)
        XCTAssertGreaterThan(seasonalCard.frame.width, app.frame.width / 2)
        XCTAssertGreaterThanOrEqual(seasonalCard.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(seasonalCard.frame.maxX, app.frame.maxX)
        // The archive uses date rows; it does not load a photo cover.
        capture("albums-seasonal-largest-text")
        openCardAndReturn(seasonalCard, expectedRoute: "seasonal:2025-Q3", in: app)
        XCTAssertTrue(app.navigationBars[reflectionsArchiveTitle].waitForExistence(timeout: 5))
        app.navigationBars[reflectionsArchiveTitle].buttons.element(boundBy: 0).tap()
        assertAlbumsRoot(in: app)

        fixtureAction("solo-memories-add-letter", in: app, expectedValue: "便りあり")
        assertAlbumsRoot(in: app)
        XCTAssertFalse(element("albums-favorites", in: app).exists)
        XCTAssertFalse(element("album-card-close_up", in: app).exists,
                       "A single-photo theme belongs in the secondary disclosure.")
        let otherThemes = element("albums-other-themes", in: app)
        reveal(otherThemes, in: app)
        otherThemes.tap()
        let theme = element("album-secondary-close_up", in: app)
        reveal(theme, in: app)
        XCTAssertGreaterThan(theme.frame.width, app.frame.width / 2)
        XCTAssertGreaterThanOrEqual(theme.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(theme.frame.maxX, app.frame.maxX)
        capture("albums-close_up-largest-text")
        openCardAndReturn(theme, expectedRoute: "album:close_up", in: app)

        // The month and the movie stay in the one fixed list, 「これまでの
        // 月のまとめ・季節のムービー」, alongside the single photo hero.
        let title = reflectionsArchiveTitle
        for (route, cardID) in [
            ("monthly:2025-08", "memories-monthly-window"),
            ("seasonal:2025-Q3", "albums-seasonal-movie")
        ] {
            let entry = reflectionsArchiveEntry(in: app)
            // The secondary theme returns near the shelf's bottom; ふりかえり is above it.
            reveal(entry, in: app, scrollsDown: true)
            XCTAssertGreaterThan(entry.frame.width, app.frame.width / 2)
            XCTAssertGreaterThanOrEqual(entry.frame.height, 44)
            entry.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
            XCTAssertTrue(element("albums-reflections-archive", in: app).waitForExistence(timeout: 5))
            let item = element(cardID, in: app)
            reveal(item, in: app)
            XCTAssertGreaterThan(item.frame.width, app.frame.width / 2)
            XCTAssertGreaterThanOrEqual(item.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(item.frame.maxX, app.frame.maxX)
            capture("albums-\(cardID)-largest-text")
            openCardAndReturn(item, expectedRoute: route, in: app)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            app.navigationBars[title].buttons.element(boundBy: 0).tap()
            assertAlbumsRoot(in: app)
        }
        let comparison = element("album-card-household_growth", in: app)
        reveal(comparison, in: app)
        assertComparisonDates(on: comparison)
        XCTAssertGreaterThan(comparison.frame.width, app.frame.width / 2)
        capture("albums-household_growth-largest-text")
        openCardAndReturn(comparison, expectedRoute: "album:household_growth", in: app)

        let years = element("albums-years-toggle", in: app)
        reveal(years, in: app)
        let year = element("album-card-calendar_year_2025", in: app)
        XCTAssertFalse(year.exists, "Year folders belong to the year destination, not the album root.")
        capture("albums-years-entry-largest-text")
        years.tap()
        XCTAssertTrue(element("albums-years-list", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["日付から探す"].exists)
        reveal(year, in: app)
        XCTAssertGreaterThan(year.frame.width, app.frame.width / 2)
        XCTAssertGreaterThanOrEqual(year.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(year.frame.maxX, app.frame.maxX)
        capture("albums-calendar_year_2025-largest-text")
        openCardAndReturn(year, expectedRoute: "album:calendar_year_2025", in: app)
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        XCTAssertTrue(year.isHittable, "Returning from a year preserves its place in the list.")
        app.navigationBars["日付から探す"].buttons.element(boundBy: 0).tap()
        assertAlbumsRoot(in: app)
        openFavorites(in: app)
        XCTAssertTrue(app.buttons["saved-memories-selection-toggle"].isHittable)
        capture("albums-favorites-largest-text")
        returnFromFavorites(in: app)
        app.terminate()
    }

    @MainActor
    private func assertHighlightPhotos(
        _ numbers: [Int], in app: XCUIApplication, pagesThroughAll: Bool, alreadySaved: Bool = false
    ) {
        let identifiers = numbers.map { "app-store-screenshot-fixture-\($0)" }
        XCTAssertEqual(app.staticTexts["solo-memories-highlight-destination"].value as? String,
                       identifiers.joined(separator: "|"))
        XCTAssertTrue(app.navigationBars["写真"].waitForExistence(timeout: 5))
        let image = app.images["photo-detail-zoom-surface"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        for index in 0..<(pagesThroughAll ? identifiers.count : 1) {
            XCTAssertTrue(app.staticTexts["\(index + 1) / \(identifiers.count)"].waitForExistence(timeout: 5),
                "The production browser must page only through this small collection.")
            // Fixture photo 9 is already a favorite before this flow starts.
            if !alreadySaved && numbers[index] != 9 {
                let save = app.buttons["お気に入りに追加"]
                XCTAssertTrue(save.isHittable)
                save.tap()
                let selectedPhoto = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label == %@", "\(identifiers[index])|true"),
                    object: app.staticTexts["solo-memories-highlight-memory-request"]
                )
                XCTAssertEqual(XCTWaiter.wait(for: [selectedPhoto], timeout: 5), .completed,
                    "The selected photo's real action must retain its collection identity.")
            }
            XCTAssertTrue(app.buttons["photo-browser-memory-saved-state"].waitForExistence(timeout: 5))
            if pagesThroughAll && index < identifiers.count - 1 { image.swipeLeft() }
        }
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
    private func selectAlbumCatFilter(
        _ identifier: String?, expectedName: String = "すべての猫", in app: XCUIApplication
    ) {
        let filter = app.buttons["album-cat-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        let choice = app.buttons["album-cat-filter-\(identifier ?? "everyone")"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedName), object: filter
        )], timeout: 5), .completed)
    }

    @MainActor
    private func assertComparisonDates(on cover: XCUIElement) {
        let dates = cover.value as? String ?? ""
        XCTAssertTrue(dates.contains("2022"), "The comparison must expose the earlier photograph's date.")
        XCTAssertTrue(dates.contains("2025"), "The comparison must expose the later photograph's date.")
        XCTAssertTrue(dates.contains("〜"))
    }

    @MainActor
    private func waitForLoadedPhotos(_ numbers: [Int], in app: XCUIApplication) {
        // Covers can load several photos, and lazy shelves may load more.
        // Wait for the expected image identities instead of an exact total.
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: numbers.map {
            NSPredicate(format: "value CONTAINS %@", "|app-store-screenshot-fixture-\($0)|")
        })
        let loaded = XCTNSPredicateExpectation(
            predicate: predicate,
            object: app.staticTexts["solo-memories-loaded-photos"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 15), .completed)
    }

    private let reflectionsArchiveTitle = "月の作品・季節のムービー"

    /// The one list of months and movies under ふりかえり (10/20).
    @MainActor
    private func reflectionsArchiveEntry(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@",
            "これまでの月の作品・季節のムービー")).firstMatch
    }

    @MainActor
    private func openReflectionsArchive(in app: XCUIApplication) {
        let entry = reflectionsArchiveEntry(in: app)
        reveal(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars[reflectionsArchiveTitle].waitForExistence(timeout: 10))
        XCTAssertTrue(element("albums-reflections-archive", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func monthlyCard(in app: XCUIApplication) -> XCUIElement {
        // On iOS 26 the ふりかえり section's own identifier is given to the
        // month card inside it; the card's label ends with its photo count.
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR (identifier == %@ AND label ENDSWITH %@)",
            "memories-monthly-window", "memories-summaries-section", "枚"
        )).firstMatch
    }

    @MainActor
    private func openCardAndReturn(_ card: XCUIElement, expectedRoute: String, in app: XCUIApplication) {
        reveal(card, in: app)
        XCTAssertTrue(card.isEnabled)
        card.tap()
        if expectedRoute.hasPrefix("monthly:") {
            XCTAssertTrue(element("monthly-window-browser", in: app).waitForExistence(timeout: 10))
            // The month's photos are titled 「8月のまとめ」 (10/19), not 写真.
            let month = Int(expectedRoute.split(separator: "-").last ?? "") ?? 0
            let title = "\(month)月の作品"
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.images["photo-detail-zoom-surface"].waitForExistence(timeout: 10))
            let destination = element("solo-memories-monthly-destination", in: app)
            XCTAssertTrue(destination.waitForExistence(timeout: 10))
            XCTAssertEqual(destination.label, String(expectedRoute.dropFirst("monthly:".count)))
            XCTAssertFalse((destination.value as? String ?? "").isEmpty)
            app.navigationBars[title].buttons.element(boundBy: 0).tap()
            return
        }
        let destination = app.staticTexts["solo-memories-detail-destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        XCTAssertEqual(destination.value as? String, expectedRoute)
        app.buttons["solo-memories-detail-return"].tap()
    }

    @MainActor
    private func assertAlbumsRoot(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["アルバム"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("albums-root", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.segmentedControls["memories-section-picker"].exists)
        XCTAssertFalse(app.buttons["memories-section-menu"].exists)
    }

    /// The app's own tab bar button. UIKit can omit SwiftUI's tab-item
    /// identifier after relaunch while preserving the visible tab label.
    @MainActor
    private func mainTab(_ identifier: String, label: String, in app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let identified = app.buttons[identifier]
        return identified.exists ? identified : app.tabBars.buttons[label]
    }

    /// The shipping アルバム tab is the works shelf (11/1); its old root with
    /// themes and years is browsed from 写真 now. Tapped, never assumed: a cold
    /// start opens the last tab the person tapped (11/8).
    @MainActor
    private func openWorksAlbumTab(in app: XCUIApplication) {
        let albums = mainTab("main-tab-memories", label: "アルバム", in: app)
        XCTAssertTrue(albums.waitForExistence(timeout: 10))
        albums.tap()
        XCTAssertTrue(app.navigationBars["アルバム"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("albums-root", in: app).exists, "The shipping アルバム tab is the works shelf")
    }

    /// 写真's cat switch is a menu above the pages (11/7): open it, choose,
    /// and read the choice back from the switch.
    @MainActor
    private func selectPhotoLibraryCat(_ identifier: String?, expectedName: String, in app: XCUIApplication) {
        let picker = app.buttons["photos-cat-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(picker.isHittable)
        picker.tap()
        let choice = app.buttons["photos-cat-\(identifier ?? "all")"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedName), object: picker
        )], timeout: 5), .completed, "The cat switch must show \(expectedName)")
    }

    @MainActor
    private func assertPhotoLibraryCat(_ expectedName: String, in app: XCUIApplication,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let picker = app.buttons["photos-cat-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(picker.value as? String, expectedName, file: file, line: line)
    }

    /// 「写真」 from the album without photos. iOS 26 ContentUnavailableView
    /// gives its own identifier to its action button, so the denied state's
    /// button is matched by that identifier and its exact visible label.
    @MainActor
    private func albumOpenPhotosButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR (identifier == %@ AND label == %@)",
            "memories-open-photos", "memories-no-photo-access", "「写真」タブで許可する"
        )).firstMatch
    }

    @MainActor
    private func openPhotosTab(in app: XCUIApplication) {
        // A cold start opens the last tab the person tapped (11/8), so tap
        // 写真 instead of assuming where the app starts.
        let photos = mainTab("main-tab-photos", label: "写真", in: app)
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        photos.tap()
        XCTAssertTrue(app.navigationBars["写真"].waitForExistence(timeout: 10))
        let all = app.buttons["photos-section-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        XCTAssertFalse(app.buttons["photos-open-automatic-albums"].exists)
    }

    @MainActor
    private func openMemoNotes(in app: XCUIApplication) -> XCUIElement {
        openPhotosTab(in: app)
        let notes = app.buttons["photos-section-notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        XCTAssertTrue(element("memory-notes-list", in: app).waitForExistence(timeout: 10))
        let memo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory-note-row-")).firstMatch
        XCTAssertTrue(memo.waitForExistence(timeout: 10))
        XCTAssertTrue(notes.isSelected)
        return memo
    }

    @MainActor
    private func openFavorites(in app: XCUIApplication) {
        openPhotosTab(in: app)
        let favorites = app.buttons["photos-section-favorites"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 5))
        XCTAssertTrue(favorites.isHittable)
        favorites.tap()
        XCTAssertTrue(element("saved-memories-gallery", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(favorites.isSelected)
    }

    @MainActor
    private func returnFromFavorites(in app: XCUIApplication) {
        app.buttons["photos-section-all"].tap()
        let albums = mainTab("main-tab-albums", label: "アルバム", in: app)
        XCTAssertTrue(albums.waitForExistence(timeout: 5))
        albums.tap()
        assertAlbumsRoot(in: app)
    }

    @MainActor
    private func reveal(_ card: XCUIElement, in app: XCUIApplication, scrollsDown: Bool = false) {
        for _ in 0..<8 where !(card.exists && card.isHittable) {
            if scrollsDown { app.scrollViews.firstMatch.swipeDown() }
            else { app.scrollViews.firstMatch.swipeUp() }
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.isHittable, "The actual card must remain reachable at this text size.")
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
    func testMemoryLibraryEntryReadsEditsAndOpensTheOriginalPhoto() {
        let app = XCUIApplication()
        let preferenceSuite = "PhotoLibrarySelectionUITest.\(UUID().uuidString)"
        app.launchEnvironment["NEKO_PHOTO_UI_PREFERENCES_SUITE"] = preferenceSuite
        app.launchArguments = ["--photo-window-ui-fixture", "--memory-library-fixture",
                               "--memory-service-preservation-entry-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let entry = app.buttons["photos-section-notes"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), app.debugDescription)
        let favorites = app.buttons["photos-section-favorites"]
        let all = app.buttons["photos-section-all"]
        // 10/19: 写真 always opens at すべて, memos or not; メモ is one tap away.
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"), object: all)], timeout: 10), .completed,
            "A first visit with an existing local memo still starts in All.")
        XCTAssertFalse(entry.isSelected)
        XCTAssertEqual(entry.label, "メモ")
        XCTAssertLessThan(all.frame.minX, favorites.frame.minX)
        XCTAssertLessThan(favorites.frame.minX, entry.frame.minX)
        all.tap()
        entry.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory-note-row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(row.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "Memo rows must expose their reading content as one accessible link.")
        attach(app, name: "memory-library-list")
        let search = app.searchFields["memory-notes-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("寝息")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        attach(app, name: "memory-library-search")
        row.tap()
        XCTAssertTrue(app.buttons["memory-note-photo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["memory-note-body"].label.contains("小さな寝息"))
        XCTAssertTrue(app.navigationBars["メモ"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["写真"].waitForExistence(timeout: 5))
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Search must remain reachable after returning from a matching record.")
        attach(app, name: "memory-library-return-from-search")
        XCTAssertEqual(search.value as? String, "寝息", "Returning must preserve the search query.")
        search.tap()
        let closeSearch = app.buttons["閉じる"]
        XCTAssertTrue(closeSearch.waitForExistence(timeout: 5))
        closeSearch.tap()
        XCTAssertTrue(app.navigationBars["写真"].waitForExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["memory-notes-export"].exists)
        row.tap()
        let body = app.staticTexts["memory-note-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue(body.label.contains("小さな寝息"))
        XCTAssertTrue(app.navigationBars["メモ"].exists)
        let memoBodyFrame = body.frame
        app.buttons["memory-note-menu"].tap()
        XCTAssertTrue(app.buttons["memory-note-managed-preserve"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["memory-note-managed-preserve"].isEnabled)
        XCTAssertFalse(app.buttons["memory-note-preserve"].exists)
        attach(app, name: "memory-library-service-preservation-entry")
        // The native menu hides navigation accessibility on iOS 26. Tap the
        // already observed memo text, outside the menu, to dismiss it.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: memoBodyFrame.midX, dy: memoBodyFrame.midY)).tap()
        let photo = app.buttons["memory-note-photo"]
        XCTAssertTrue(photo.isHittable)
        attach(app, name: "memory-library-photo-detail")
        photo.tap()
        XCTAssertTrue(app.buttons["photo-memory-note-open"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["photo-memory-note-excerpt"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        app.buttons["memory-note-edit"].tap()
        let input = app.textViews["photo-memory-note-text"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("またここで眠ろう。")
        app.buttons["photo-memory-note-keyboard-done"].tap()
        app.buttons["photo-memory-note-save"].tap()
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "またここで眠ろう。"), object: body)], timeout: 5), .completed)
        attach(app, name: "memory-library-detail")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        all.tap()
        app.terminate()

        // The three shipping lists keep distinct reading positions. Fixture
        // note UUIDs are process-local; stable photo IDs also cover relaunch.
        app.launchEnvironment["NEKO_PHOTO_UI_PREFERENCES_SUITE"] = preferenceSuite + ".scroll"
        app.launchArguments = ["--photo-window-ui-fixture", "--memory-library-fixture", "--memory-library-scroll",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"), object: all)], timeout: 10), .completed)
        func assertVisible(_ target: XCUIElement) {
            // Asking an element whose frame is still off screen (mid back
            // animation) for hittability fails the test outright; poll the
            // frame first, then require it to be hittable.
            let outcome = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    target.exists && app.frame.contains(CGPoint(x: target.frame.midX, y: target.frame.midY))
                        && target.isHittable
                }, object: nil)],
                timeout: 10)
            if outcome != .completed { attach(app, name: "photos-position-restoration-failure") }
            let trace = app.otherElements["memory-library-fixture"].value as? String ?? "No position trace"
            XCTAssertEqual(outcome, .completed, app.debugDescription + "\nPOSITION TRACE:\n" + trace)
        }
        func scrollTo(_ target: XCUIElement) {
            for _ in 0..<8 {
                if target.exists && app.frame.contains(CGPoint(x: target.frame.midX, y: target.frame.midY))
                    && target.isHittable { break }
                app.swipeUp()
            }
            assertVisible(target)
        }
        func attachPositionTrace(_ name: String) {
            let trace = app.otherElements["memory-library-fixture"].value as? String ?? "No position trace"
            let attachment = XCTAttachment(string: trace)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        all.tap()
        let lowerPhoto = app.buttons["photo-hub-photo-app-store-screenshot-fixture-page-30"]
        scrollTo(lowerPhoto)
        let photoY = lowerPhoto.frame.minY
        attach(app, name: "photos-all-scrolled-before-leaving")
        attachPositionTrace("photos-all-position-before-leaving")
        favorites.tap()
        let lowerFavorite = app.buttons["saved-memory-photo-app-store-screenshot-fixture-page-30"]
        scrollTo(lowerFavorite)
        let favoriteY = lowerFavorite.frame.minY
        attach(app, name: "photos-favorites-scrolled-before-leaving")
        attachPositionTrace("photos-favorites-position-before-leaving")
        entry.tap()
        let lowerNote = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "memory-note-row-", "スクロール確認 8")).firstMatch
        scrollTo(lowerNote)
        let noteY = lowerNote.frame.minY
        lowerNote.tap()
        XCTAssertTrue(app.staticTexts["memory-note-body"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["memory-note-body"].label.contains("スクロール確認 8"))
        app.navigationBars.buttons.firstMatch.tap()
        assertVisible(lowerNote)
        XCTAssertLessThan(abs(lowerNote.frame.minY - noteY), lowerNote.frame.height + 2)
        attachPositionTrace("photos-notes-position-before-switching-back")
        all.tap()
        assertVisible(lowerPhoto)
        XCTAssertLessThan(abs(lowerPhoto.frame.minY - photoY), lowerPhoto.frame.height + 2)
        favorites.tap()
        assertVisible(lowerFavorite)
        XCTAssertLessThan(abs(lowerFavorite.frame.minY - favoriteY), lowerFavorite.frame.height + 2)
        attach(app, name: "photos-favorites-scroll-restored")
        entry.tap()
        assertVisible(lowerNote)
        XCTAssertLessThan(abs(lowerNote.frame.minY - noteY), lowerNote.frame.height + 2)
        all.tap()
        app.terminate()

        app.launch()
        XCTAssertTrue(all.waitForExistence(timeout: 15))
        XCTAssertTrue(all.isSelected, "Existing memos must not override the previous explicit section after relaunch.")
        assertVisible(lowerPhoto)
        XCTAssertLessThan(abs(lowerPhoto.frame.minY - photoY), lowerPhoto.frame.height + 2)
        attach(app, name: "photos-all-scroll-restored-after-relaunch")
        app.terminate()
    }

    @MainActor
    func testMemoryLibraryWithoutPhotoSupportsLargestTextEditingAndDeletion() {
        let app = XCUIApplication()
        let preferenceSuite = "PhotoLibraryWithoutPhotoUITest.\(UUID().uuidString)"
        app.launchEnvironment["NEKO_PHOTO_UI_PREFERENCES_SUITE"] = preferenceSuite
        app.launchArguments = ["--photo-window-ui-fixture", "--memory-library-fixture",
                               "--memory-library-no-photo", "--photo-window-large",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let entry = app.buttons["photos-section-notes"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "Text must remain reachable without Photos access.\n\(app.debugDescription)")
        // 10/19: 写真 always opens at すべて; メモ is one tap away.
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"), object: app.buttons["photos-section-all"])],
            timeout: 10), .completed)
        entry.tap()
        XCTAssertTrue(entry.isSelected)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory-note-row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["memory-notes-export"].exists)
        row.tap()
        let body = app.staticTexts["memory-note-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["memory-note-photo"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["memory-note-photo-unavailable"].firstMatch.exists)
        XCTAssertLessThanOrEqual(body.frame.maxX, app.frame.maxX)
        attach(app, name: "memory-library-no-photo-largest-text")
        app.buttons["memory-note-edit"].tap()
        let input = app.textViews["photo-memory-note-text"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("文章は残っている。")
        app.buttons["photo-memory-note-keyboard-done"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let save = app.buttons["photo-memory-note-save"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true AND isHittable == true"), object: save)], timeout: 5), .completed)
        save.tap()
        // The reading view remains in the hierarchy behind the editor sheet.
        // Confirm dismissal before inspecting its updated, visible body.
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "文章は残っている。"), object: body)], timeout: 5), .completed)
        app.buttons["memory-note-menu"].tap()
        XCTAssertFalse(app.buttons["書き出す"].exists)
        app.buttons["メモを削除"].tap()
        app.buttons["削除"].tap()
        // Group-level identifiers are forwarded to the empty state's children.
        // Verify its visible content and keep export out of the current UI.
        XCTAssertTrue(app.staticTexts["写真を開いて、鉛筆のボタンから書けます。"].waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
        XCTAssertFalse(app.buttons["memory-notes-export"].exists)
        attach(app, name: "memory-library-empty-after-deletion")
        app.buttons["photos-section-all"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "An empty library remains a Photos section.")
        entry.tap()
        XCTAssertFalse(app.buttons["memory-notes-menu"].exists,
                       "The embedded notes section must not add a second Photos menu.")
        XCTAssertFalse(app.buttons["iCloudから読み込む"].exists,
                       "The retired iCloud copies offer no restoration entry.")
        app.terminate()

        app.launchEnvironment["NEKO_PHOTO_UI_PREFERENCES_SUITE"] = preferenceSuite + ".empty"
        app.launchArguments = ["--photo-window-ui-fixture", "--memory-library-fixture", "--memory-library-empty",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let all = app.buttons["photos-section-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 15))
        XCTAssertTrue(all.isSelected, "Without a memo, the first visit must start in All.")
        entry.tap()
        XCTAssertTrue(app.staticTexts["写真を開いて、鉛筆のボタンから書けます。"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testPersonalMemoryNoteSurvivesReopenStaysWithPhotoAndNeverBecomesCaption() {
        let app = XCUIApplication()
        app.launchArguments = ["--photo-window-ui-fixture", "--memo-local-account-change-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_PHOTO_MEMORY_UI_SESSION"] = UUID().uuidString
        app.launch()
        let open = app.buttons["photo-memory-note-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let input = app.textViews["photo-memory-note-text"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(input.isEnabled, "An account notification must leave a local-only memo editable.")
        XCTAssertFalse(app.alerts["メモを保存できませんでした"].exists,
                       "An account notification must not report a local-only memo save failure.")
        XCTAssertEqual(input.value as? String ?? "", "", "Each run starts with an isolated fixture store.")
        let note = "窓辺で初めて寝た日。"
        input.tap()
        input.typeText(note)
        let done = app.buttons["photo-memory-note-keyboard-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        attach(app, name: "personal-memory-note-editor")
        app.buttons["photo-memory-note-save"].tap()
        let excerpt = app.buttons["photo-memory-note-excerpt"]
        XCTAssertTrue(excerpt.waitForExistence(timeout: 5))
        XCTAssertEqual(excerpt.value as? String, note)
        attach(app, name: "personal-memory-note-photo")
        app.terminate()
        app.launch()
        XCTAssertTrue(excerpt.waitForExistence(timeout: 15))
        XCTAssertEqual(excerpt.value as? String, note)

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.30))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.30))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 5))
        XCTAssertFalse(excerpt.exists, "The second photo must not inherit the first photo's note")
        open.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("保存しないメモ")
        app.buttons["photo-memory-note-close"].tap()
        app.buttons["保存せずに閉じる"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertFalse(excerpt.exists)
        end.press(forDuration: 0.05, thenDragTo: start)
        XCTAssertTrue(excerpt.waitForExistence(timeout: 5))
        XCTAssertEqual(excerpt.value as? String, note)

        XCTAssertFalse(app.buttons["photo-browser-deliver"].exists,
                       "The retired two-person sender must not be reachable from a private memo.")
        XCTAssertTrue(app.buttons["お気に入りに追加"].exists)
        app.terminate()
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
        let beforeZoomValue = image.value as? String ?? "nil"
        let beforeZoomFrame = image.frame
        image.doubleTap()
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (Self.detailValue(image.value as? String, field: "zoom") ?? 0) > 1.1
        }, object: image)
        let zoomResult = XCTWaiter.wait(for: [zoomed], timeout: 5)
        if zoomResult != .completed {
            let state = XCTAttachment(string: "before=\(beforeZoomValue)\nafter=\(image.value as? String ?? "nil")\nbeforeFrame=\(beforeZoomFrame)\nafterFrame=\(image.frame)")
            state.name = "\(name)-zoom-failure-state"
            state.lifetime = .keepAlways
            add(state)
            attach(app, name: "\(name)-zoom-failed")
        }
        XCTAssertEqual(zoomResult, .completed, "Double-tap must enlarge the visible photo.")
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
        app.navigationBars["メモ"].buttons["閉じる"].tap()
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
