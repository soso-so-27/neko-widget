import XCTest

final class OfficialWindowUITests: XCTestCase {
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
        let sameDay = app.buttons.matching(identifier: "photo-browser-same-day")
        let originalDate = try XCTUnwrap(try foreground(sameDay).value as? String)
        try foreground(app.buttons.matching(identifier: "photo-browser-related")).tap()
        try foreground(app.buttons.matching(identifier: "photo-related-year-calendar_year_2025")).tap()
        try foreground(app.buttons.matching(
            identifier: "curated-album-photo-calendar_year_2025-app-store-screenshot-fixture-3"
        )).tap()
        _ = try foreground(app.images.matching(identifier: "photo-detail-zoom-surface"))
        let relatedDate = try XCTUnwrap(try foreground(sameDay).value as? String)
        XCTAssertNotEqual(relatedDate, originalDate, "The related album must open the selected different photo")
        capture("widget-url-personal-related-photo", app)

        let closeRelated = app.buttons.matching(identifier: "photo-related-close")
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
        _ = try foreground(app.buttons.matching(identifier: "photo-browser-related"))
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
        let discover = app.buttons["window-list-discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 10))
        discover.tap()
        XCTAssertTrue(app.navigationBars["まどを探す"].waitForExistence(timeout: 5))
        app.buttons["official-window-entry"].tap()
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
        capture("cat-window-widget-guide", app)
        app.navigationBars["ホーム画面に置く"].buttons["閉じる"].tap()
        app.navigationBars["キジ白のまど"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(catWindow.waitForExistence(timeout: 5), "Back must return to the original photo")
        app.buttons["official-photo-close-official-cats"].tap()
        XCTAssertTrue(app.navigationBars["どこかの猫"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["public-window-overview-official-cats"].buttons["official-window-subscribe"].exists,
                      "Opening a cat must not subscribe to its discovery source")
        app.navigationBars["どこかの猫"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["まどを探す"].waitForExistence(timeout: 5))
        app.navigationBars["まどを探す"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["まど"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["public-window-entry-cat-tabby-nap"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["official-window-entry"].exists)
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
        let discover = app.buttons["window-list-discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 10))
        discover.tap()
        XCTAssertTrue(app.navigationBars["まどを探す"].waitForExistence(timeout: 5))
        let nap = app.buttons["public-window-entry-nap-cats"]
        XCTAssertTrue(nap.waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.navigationBars["ホーム画面に置く"].waitForExistence(timeout: 5))
        let source = app.descendants(matching: .any)["official-window-widget-source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        for _ in 0..<3 { if source.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(source.isHittable)
        XCTAssertTrue(source.label.contains("おひるね"), "The guide must name the window just received")
        capture("nap-window-widget-guide", app)
        app.buttons["閉じる"].tap()
        app.navigationBars["おひるね"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["まどを探す"].waitForExistence(timeout: 5))
        app.navigationBars["まどを探す"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["まど"].waitForExistence(timeout: 5))
        XCTAssertTrue(nap.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["official-window-entry"].exists, "Receiving a theme must not subscribe to the other window")
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
        XCTAssertFalse(second.exists, "Stopping one public window must remove only that receiving card")
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
        let discover = app.buttons["window-list-discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["window-list-connect"].exists,
                       "A public-only configuration must not offer private connections")
        XCTAssertFalse(app.buttons["official-window-entry"].exists, "Unsubscribed windows belong in discovery")
        let start = app.buttons["window-list-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.navigationBars["まどを探す"].waitForExistence(timeout: 5),
                      "The empty-list action must open discovery directly")
        app.buttons["official-window-entry"].tap()
        XCTAssertTrue(app.tabBars.buttons["写真"].exists)
        XCTAssertTrue(app.tabBars.buttons["アルバム"].exists)
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
        XCTAssertTrue(app.navigationBars["まどを探す"].waitForExistence(timeout: 5))
        app.navigationBars["まどを探す"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["まど"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["official-window-entry"].waitForExistence(timeout: 5))
        capture("window-list-after-receiving", app)
        app.buttons["official-window-entry"].tap()
        stopReceiving(app)
        XCTAssertTrue(app.buttons["official-window-subscribe"].waitForExistence(timeout: 5))
        app.navigationBars["どこかの猫"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(discover.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isHittable)
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
        let discover = app.buttons["window-list-discover"]
        XCTAssertTrue(discover.isHittable)
        XCTAssertTrue(app.tabBars.buttons["写真"].isHittable)
        capture("window-list-large-text", app)
        discover.tap()
        XCTAssertTrue(app.navigationBars["まどを探す"].waitForExistence(timeout: 5))
        app.navigationBars["まどを探す"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["まど"].waitForExistence(timeout: 5))
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
        app.buttons["official-window-refresh"].tap()
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
            let discover = app.buttons["window-list-discover"]
            let connect = app.buttons["window-list-connect"]
            XCTAssertTrue(discover.isHittable)
            XCTAssertTrue(connect.isHittable)
            // Native toolbar AX frames are not a measurement of the complete
            // touch target. Verify distinct, reachable actions and their result.
            XCTAssertFalse(discover.frame.intersects(connect.frame))
            discover.tap()
            XCTAssertTrue(app.navigationBars["まどを探す"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["official-window-entry"].waitForExistence(timeout: 5),
                          "Public discovery must open directly even when private setup needs recovery")
            XCTAssertFalse(app.buttons["window-list-resume-setup"].exists)
            capture(largeText ? "window-discovery-direct-large-text" : "window-discovery-direct-standard", app)
            app.navigationBars["まどを探す"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["まど"].waitForExistence(timeout: 5),
                          "One back from discovery must return to the window list")
            XCTAssertTrue(connect.isHittable)
            connect.tap()
            XCTAssertTrue(app.navigationBars["ねことも"].waitForExistence(timeout: 5),
                          "A single unfinished window must open directly from the person-plus action")
            XCTAssertFalse(app.descendants(matching: .any)["window-connection-options"].firstMatch.exists)
            XCTAssertFalse(app.buttons["window-list-resume-setup"].exists)
            capture(largeText ? "window-setup-direct-large-text" : "window-setup-direct-standard", app)
            app.navigationBars["ねことも"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["まど"].waitForExistence(timeout: 5),
                          "One back from setup must return to the window list")
            connect.tap()
            XCTAssertTrue(app.navigationBars["ねことも"].waitForExistence(timeout: 5))
            let restart = app.buttons["設定をやり直す"]
            for _ in 0..<6 { if restart.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(restart.isHittable, "Failed setup must have a recovery action")
            restart.tap()
            expectation(for: NSPredicate(format: "exists == false"),
                        evaluatedWith: app.staticTexts["pairing-failure-title"])
            waitForExpectations(timeout: 5)
            let create = app.buttons["新しいまどを作る"]
            let setupForm = app.collectionViews.firstMatch
            XCTAssertTrue(setupForm.waitForExistence(timeout: 5))
            for _ in 0..<6 { if create.isHittable { break }; setupForm.swipeUp() }
            XCTAssertTrue(create.waitForExistence(timeout: 5), "Recovery reuses the slot for the setup choices")
            XCTAssertTrue(create.isHittable)
            app.navigationBars["ねことも"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["まど"].waitForExistence(timeout: 5),
                          "Closing setup returns to the window list")
            XCTAssertTrue(discover.waitForExistence(timeout: 5))
            discover.tap()
            XCTAssertTrue(app.navigationBars["まどを探す"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["official-window-entry"].waitForExistence(timeout: 5),
                          "Private setup must not block public discovery")
            app.terminate()
        }
    }

    @MainActor
    func testFailedRemoteSetupChecksConnectionWithoutResetting() {
        continueAfterFailure = false
        for largeText in [false, true] {
            let app = launchFailedSetup("remote", largestText: largeText)
            let title = app.staticTexts["pairing-failure-title"]
            let check = app.buttons["pairing-recovery-action"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            XCTAssertEqual(app.staticTexts.matching(identifier: "pairing-failure-title").count, 1)
            XCTAssertEqual(app.textFields.count, 0, "A failed connection must not offer name sharing")
            XCTAssertFalse(app.staticTexts["このBuildでは写真を保存・送信しません"].exists,
                           "The isolated fixture must reproduce the user's photo-sharing presentation")
            XCTAssertFalse(app.staticTexts["画面の案内を確認してください"].exists)
            XCTAssertFalse(app.staticTexts["まどの設定を完了できませんでした"].exists)
            let error = app.staticTexts["pairing-recovery-error"]
            XCTAssertTrue(error.waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts.matching(identifier: "pairing-recovery-error").count, 1)
            XCTAssertFalse(app.alerts.firstMatch.exists, "A connection check must never ask to delete settings")
            XCTAssertFalse(app.buttons["pairing-recheck-connection"].exists)
            if largeText && !check.isHittable { app.swipeUp() }
            XCTAssertTrue(check.isHittable)
            XCTAssertEqual(check.label, "接続を確認")
            XCTAssertGreaterThanOrEqual(check.frame.height + 0.001, 44)
            capture(largeText ? "pairing-check-retained-largest" : "pairing-check-retained", app)
            check.tap()
            XCTAssertTrue(app.staticTexts["相手と接続済み"].waitForExistence(timeout: 5))
            XCTAssertFalse(title.exists)
            XCTAssertFalse(app.alerts.firstMatch.exists)
            capture(largeText ? "pairing-check-resumed-largest" : "pairing-check-resumed", app)
            app.terminate()
        }
    }

    @MainActor
    func testExpiredInvitationExplainsNextStepAndRetainsFailedCancellation() {
        continueAfterFailure = false
        for largeText in [false, true] {
            let app = launchFailedSetup("expired", largestText: largeText)
            let action = app.buttons["pairing-recovery-action"]
            XCTAssertTrue(app.staticTexts["招待の期限が切れています"].waitForExistence(timeout: 10))
            XCTAssertEqual(action.label, "新しい招待で設定")
            for _ in 0..<2 where !action.isHittable { app.swipeUp() }
            XCTAssertTrue(action.isHittable)
            capture(largeText ? "pairing-expired-largest" : "pairing-expired", app)
            action.tap()
            let cancel = pairingConfirmationButton("pairing-reset-cancel", title: "戻る", in: app)
            capture(largeText ? "pairing-new-invitation-confirmation-largest" : "pairing-new-invitation-confirmation", app)
            cancel.tap()
            XCTAssertEqual(action.label, "新しい招待で設定")
            action.tap()
            pairingConfirmationButton("pairing-reset-confirm", title: "設定を終了して進む", in: app).tap()
            XCTAssertTrue(app.staticTexts["pairing-recovery-error"].waitForExistence(timeout: 5))
            XCTAssertEqual(action.label, "終了の手続きを再開")
            XCTAssertFalse(app.staticTexts["招待の期限が切れています"].exists,
                           "The previous expiry result cannot override an in-flight cancellation")
            XCTAssertFalse(app.buttons["pairing-recheck-connection"].exists,
                           "Checking status must not replace the saved cancellation")
            for _ in 0..<2 where !action.isHittable { app.swipeUp() }
            capture(largeText ? "pairing-ending-retained-largest" : "pairing-ending-retained", app)
            action.tap()
            pairingConfirmationButton("pairing-reset-confirm", title: "設定を終了して進む", in: app).tap()
            expectation(for: NSPredicate(format: "exists == false"),
                        evaluatedWith: app.staticTexts["pairing-failure-title"])
            waitForExpectations(timeout: 5)
            let creation = app.buttons["この名前でまどを作る"]
            for _ in 0..<5 where !creation.exists { app.swipeUp() }
            XCTAssertTrue(creation.exists, "Successful explicit reset proceeds to invitation creation")
            XCTAssertFalse(app.buttons["招待されたまどに参加"].exists,
                           "Do not ask an inviter to choose their role again after an explicit restart")
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
        XCTAssertTrue(app.staticTexts["共有されるもの"].exists)
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
        app.buttons["cat-profile-more"].tap()
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
        app.buttons["cat-profile-more"].tap()
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

        let settingsButton = firstExistingButton(
            in: app,
            identifiers: ["albums-settings-button"],
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
                // Unavailable or still-preparing summaries have no empty
                // cover. Favorites and the Photos route remain available.
                XCTAssertTrue(app.navigationBars["アルバム"].waitForExistence(timeout: 15))
                XCTAssertTrue(app.descendants(matching: .any)["albums-favorites"].exists)
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
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    @MainActor
    func testPersonalArchiveRestoresPhotoAndTextAndExplicitlySavesNewText() {
        let app = XCUIApplication()
        app.launchArguments = ["--personal-archive-ui-fixture", "--photo-window-ui-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_ALBUM_CATALOG_DEBUG"] = "1"
        app.launchEnvironment["NEKO_ALBUM_CATALOG_DELAY_MS"] = "2500"
        app.launch()

        let catalog = app.staticTexts["album-catalog-debug-state"]
        let progress = app.staticTexts["archive-root-fixture-progress"]
        func waitForCatalog(_ fields: [String], timeout: TimeInterval = 15) {
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates:
                fields.map { NSPredicate(format: "value CONTAINS %@", $0) })
            let ready = XCTNSPredicateExpectation(predicate: predicate, object: catalog)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
        }
        func catalogNumber(_ key: String) -> Int {
            let fields = (catalog.value as? String ?? "").split(separator: ";")
            return fields.first(where: { $0.hasPrefix(key + ":") })
                .flatMap { Int($0.dropFirst(key.count + 1)) } ?? -1
        }
        func assertReadyRemainsVisible(for seconds: TimeInterval) {
            // A single root-exists check also passes while its child is an
            // endlessly restarting ProgressView. Observe the actual ready state.
            let hidden = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false OR value CONTAINS %@", ";visible:0;"),
                object: catalog)
            hidden.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: seconds), .completed)
            XCTAssertFalse(app.progressIndicators["albums-preparing"].exists)
        }

        XCTAssertTrue(catalog.waitForExistence(timeout: 15))
        waitForCatalog(["active:0;pending:0;visible:1;", "visibleCount:6000;visibleContainsProbe:1"])
        let initialStarted = catalogNumber("started")
        XCTAssertEqual(initialStarted, 1, "Progress-only publications must not restart the catalog")
        let initialProgress = Int(progress.value as? String ?? "") ?? -1
        XCTAssertGreaterThan(initialProgress, 0)
        assertReadyRemainsVisible(for: 2)
        capture("personal-archive-albums-ready-under-progress")
        let settings = app.buttons["albums-settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let archive = app.buttons["settings-personal-archive"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        for _ in 0..<4 where !archive.isHittable { app.swipeUp() }
        XCTAssertTrue(archive.isHittable)
        archive.tap()
        let refresh = app.buttons["personal-archive-refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["まだ記録がありません"].waitForExistence(timeout: 10))
        refresh.tap()
        let restored = app.buttons["personal-archive-record-11111111-1111-4111-8111-111111111111"]
        for _ in 0..<4 { if restored.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        capture("personal-archive-restored-list")
        restored.tap()
        XCTAssertTrue(app.staticTexts["はじめて窓辺で眠った日"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["保管した写真"].exists)
        capture("personal-archive-restored-record")
        app.navigationBars["記録"].buttons.element(boundBy: 0).tap()
        let compose = app.buttons["personal-archive-compose"]
        for _ in 0..<4 { if compose.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(compose.isHittable)
        compose.tap()
        let text = app.textViews["personal-archive-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        capture("personal-archive-composer-from-settings-sheet")
        let composerBar = app.navigationBars["保管する記録"]
        composerBar.buttons["戻る"].tap()
        let composerClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: composerBar)
        XCTAssertEqual(XCTWaiter.wait(for: [composerClosed], timeout: 5), .completed)
        XCTAssertTrue(compose.isHittable)
        compose.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        // Exercise real AppRoot/MainTab scene transitions underneath the real
        // settings/composer sheets, with another finite scan-progress burst.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(composerBar.waitForExistence(timeout: 10))
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap(); text.typeText("A quiet afternoon")
        app.buttons["完了"].tap()
        app.buttons["personal-archive-save"].tap()
        let savedComposerClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: composerBar)
        XCTAssertEqual(XCTWaiter.wait(for: [savedComposerClosed], timeout: 10), .completed)
        XCTAssertTrue(app.navigationBars["記録の保管"].waitForExistence(timeout: 10))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "personal-archive-record-"))
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: rows)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.navigationBars["保管する記録"].exists)

        app.navigationBars["記録の保管"].buttons.element(boundBy: 0).tap()
        app.navigationBars["設定"].buttons["閉じる"].tap()
        waitForCatalog(["active:0;pending:0;visible:1;", "visibleCount:6000;visibleContainsProbe:1"])
        XCTAssertEqual(catalogNumber("started"), initialStarted,
                       "Opening sheets and returning to the foreground must retain the same catalog")
        XCTAssertGreaterThan(Int(progress.value as? String ?? "") ?? -1, initialProgress)
        assertReadyRemainsVisible(for: 2)
        capture("personal-archive-albums-after-composer")

        app.buttons["archive-root-fixture-content"].tap()
        assertReadyRemainsVisible(for: 3)
        waitForCatalog(["active:0;pending:0;visible:1;", "visibleCount:6000;visibleContainsProbe:1"])
        XCTAssertGreaterThan(catalogNumber("started"), initialStarted)
        XCTAssertLessThanOrEqual(catalogNumber("started") - initialStarted, 2,
                                 "A burst of real edits should use one worker and its latest pending input")

        app.buttons["archive-root-fixture-remove"].tap()
        waitForCatalog(["visibleContainsProbe:0"], timeout: 2)
        app.buttons["archive-root-fixture-access"].tap()
        XCTAssertEqual(app.buttons["archive-root-fixture-access"].value as? String, "denied")
        waitForCatalog([";visible:0;", "visibleCount:0;visibleContainsProbe:0"])
        let staleResult = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", ";visible:1;"), object: catalog)
        staleResult.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [staleResult], timeout: 3), .completed)
        app.buttons["archive-root-fixture-access"].tap()
        waitForCatalog(["active:0;pending:0;visible:1;", "visibleCount:5999;visibleContainsProbe:0"])
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testPhotosOpenEachCatsPhotosDirectlyAndKeepManagementInSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-screenshot-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "cats"
        app.launch()
        assertAlbumsRoot(in: app)
        XCTAssertFalse(element("albums-cat-fixture-cat-0", in: app).exists)

        // Choose a subject first, then filter inside its shipping destination.
        let closeUp = element("album-card-close_up", in: app)
        reveal(closeUp, in: app)
        closeUp.tap()
        XCTAssertTrue(app.navigationBars["どアップ"].waitForExistence(timeout: 5))
        let albumPhotos = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "の猫の写真"))
        XCTAssertEqual(albumPhotos.count, 1)
        selectAlbumCatFilter("fixture-cat-1", expectedName: "ソラ", in: app)
        XCTAssertEqual(albumPhotos.count, 0, "A cat with no matching photos must not fall back to everyone.")
        selectAlbumCatFilter(nil, in: app)
        XCTAssertEqual(albumPhotos.count, 1)
        app.navigationBars["どアップ"].buttons.element(boundBy: 0).tap()
        assertAlbumsRoot(in: app)

        let years = element("albums-years-toggle", in: app)
        reveal(years, in: app)
        years.tap()
        XCTAssertTrue(app.navigationBars["年から探す"].waitForExistence(timeout: 5))
        let year = element("album-card-calendar_year_2025", in: app)
        reveal(year, in: app)
        year.tap()
        XCTAssertTrue(app.navigationBars["2025年"].waitForExistence(timeout: 5))
        XCTAssertEqual(albumPhotos.count, 3)
        selectAlbumCatFilter("fixture-cat-0", expectedName: "ミケ", in: app)
        XCTAssertEqual(albumPhotos.count, 1)
        albumPhotos.firstMatch.tap()
        let filteredPhoto = app.images["photo-detail-zoom-surface"]
        XCTAssertTrue(filteredPhoto.waitForExistence(timeout: 10))
        let filteredDate = app.buttons["photo-browser-same-day"]
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
        XCTAssertTrue(app.navigationBars["年から探す"].waitForExistence(timeout: 5))
        app.navigationBars["年から探す"].buttons.element(boundBy: 0).tap()
        assertAlbumsRoot(in: app)
        openPhotosTab(in: app)
        XCTAssertTrue(app.buttons["photo-hub-cat-profiles"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["photo-hub-source-recovery"].exists)
        XCTAssertFalse(app.staticTexts["写真の対象と整理"].exists)
        capture("photo-hub-cats")
        for (index, name) in ["ミケ", "ソラ"].enumerated() {
            let shortcut = app.buttons["photo-hub-cat-fixture-cat-\(index)"]
            XCTAssertTrue(shortcut.isHittable)
            shortcut.tap()
            XCTAssertTrue(app.navigationBars["\(name)の写真"].waitForExistence(timeout: 5))
            let photos = app.buttons.matching(identifier: "cat-profile-photo")
            XCTAssertEqual(photos.count, 1, "The shortcut must retain the selected cat")
            let more = app.buttons["cat-profile-more"]
            XCTAssertTrue(more.isHittable)
            more.tap()
            XCTAssertTrue(app.buttons["cat-profile-add-photos"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["cat-profile-settings"].exists)
            app.buttons["cat-profile-select"].tap()
            XCTAssertEqual(app.buttons["cat-profile-select"].label, "完了")
            app.buttons["cat-profile-select"].tap()
            if index == 0 { capture("cat-photo-page") }

            photos.firstMatch.tap()
            let zoom = app.images["photo-detail-zoom-surface"]
            XCTAssertTrue(zoom.waitForExistence(timeout: 10))
            let date = app.buttons["photo-browser-same-day"]
            XCTAssertTrue(date.waitForExistence(timeout: 5))
            let expectedDate = index == 0 ? "2025年12月18日" : "2025年8月4日"
            XCTAssertEqual(date.value as? String, expectedDate, "The browser opened another cat's photo")
            XCTAssertTrue(app.buttons["photo-browser-memory-saved-state"].isHittable,
                          "The cat photo must retain the normal favorite action")
            // Each existing fixture cat has one photo. Paging cannot expose
            // the other cat or the unassigned photos in the main library.
            zoom.swipeLeft()
            XCTAssertEqual(date.value as? String, expectedDate)
            app.navigationBars["写真"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["\(name)の写真"].waitForExistence(timeout: 5))
            XCTAssertEqual(photos.count, 1)
            app.navigationBars["\(name)の写真"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        }
        app.buttons["window-settings-button"].tap()
        let profiles = app.buttons["settings-cat-profiles"]
        XCTAssertTrue(profiles.waitForExistence(timeout: 5))
        for _ in 0..<5 where !profiles.isHittable { app.swipeUp() }
        profiles.tap()
        XCTAssertTrue(app.navigationBars["猫のプロフィール"].waitForExistence(timeout: 5))
        let firstCat = app.buttons.matching(identifier: "cat-profile-open").firstMatch
        XCTAssertTrue(firstCat.waitForExistence(timeout: 5))
        let catName = firstCat.label.contains("ミケ") ? "ミケ" : "ソラ"
        firstCat.tap()
        XCTAssertTrue(app.navigationBars[catName].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["名前を変更"].exists, "Settings must open the profile, without a photo-grid intermediary")
        XCTAssertFalse(app.navigationBars["\(catName)の写真"].exists)
        capture("cat-settings-direct")
        app.navigationBars[catName].buttons.element(boundBy: 0).tap()
        app.navigationBars["猫のプロフィール"].buttons.element(boundBy: 0).tap()

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
        XCTAssertTrue(app.navigationBars["写真"].waitForExistence(timeout: 5),
                      "Selecting a source returns directly to photo settings")
        let excluded = app.buttons["settings-excluded-photos"]
        for _ in 0..<5 where !excluded.isHittable { app.swipeUp() }
        XCTAssertTrue(excluded.isHittable)
        excluded.tap()
        XCTAssertTrue(app.navigationBars["除外した写真"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["写真の対象"].exists)
        app.terminate()
    }

    @MainActor
    func testPhotosStayUsableWithoutCatRegistrationAndOfferSourceRecoveryOnlyWhenNeeded() {
        for scenario in ["no-cats", "source-unavailable"] {
            let app = XCUIApplication()
            app.launchArguments = ["--app-store-screenshot-fixture", "-AppleLanguages", "(ja)"]
            app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = scenario
            app.launch()
            if scenario == "no-cats" {
                assertAlbumsRoot(in: app)
                XCTAssertEqual(element("albums-favorites", in: app).label, "お気に入り、9枚",
                               "Favorites include saved photos outside the eight-photo source.")
                capture("albums-root-standard")
                openFavorites(in: app)
                let favorite = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "猫の写真")).firstMatch
                XCTAssertTrue(favorite.waitForExistence(timeout: 10))
                favorite.tap()
                XCTAssertTrue(app.images["photo-detail-zoom-surface"].waitForExistence(timeout: 10))
                XCTAssertTrue(element("photo-browser-memory-saved-state", in: app).exists)
                app.navigationBars["写真"].buttons.element(boundBy: 0).tap()
                XCTAssertTrue(app.navigationBars["お気に入り"].waitForExistence(timeout: 10))
                returnFromFavorites(in: app)
                let album = element("album-card-household_growth", in: app)
                reveal(album, in: app)
                assertComparisonDates(on: album)
                capture("albums-comparison-standard")
                album.tap()
                XCTAssertTrue(app.navigationBars["昔と最近"].waitForExistence(timeout: 10))
                app.navigationBars["昔と最近"].buttons.element(boundBy: 0).tap()
                assertAlbumsRoot(in: app)
                capture("albums-without-cat-registration")
            }
            openPhotosTab(in: app)
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
            let title = app.staticTexts["family-window-settings-title"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            let originalName = title.label
            let rename = app.buttons["family-window-rename"]
            XCTAssertTrue(rename.isHittable)
            rename.tap()
            let nameAlert = app.alerts["まどの名前"]
            XCTAssertTrue(nameAlert.waitForExistence(timeout: 5))
            let nameField = nameAlert.textFields.firstMatch
            XCTAssertTrue(nameField.isHittable)
            nameField.tap()
            nameField.typeText("test")
            capture(largeText ? "window-name-direct-largest-text" : "window-name-direct")
            nameAlert.buttons["キャンセル"].tap()
            XCTAssertFalse(nameAlert.exists)
            XCTAssertEqual(title.label, originalName, "Cancelling a name edit must retain the window name")
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
        openPhotosTab(in: app)
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
            XCTAssertTrue(retry.isHittable, "The monthly browser must leave retry reachable")
            retry.tap()
            XCTAssertTrue(element("monthly-window-browser", in: app).waitForExistence(timeout: 10))
            let save = app.buttons["お気に入りに追加"]
            let savedState = app.buttons["photo-browser-memory-saved-state"]
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
                XCTAssertEqual(savedState.label, "お気に入りに追加済み")
                savedState.tap()
                app.buttons["お気に入りから外す"].tap()
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
        func hittableElements(_ query: XCUIElementQuery, count: Int = 1, timeout: TimeInterval = 5,
                              file: StaticString = #filePath, line: UInt = #line) throws -> [XCUIElement] {
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                query.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.count == count
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: timeout), .completed,
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
            app.launch()
            let related = app.buttons.matching(identifier: "photo-browser-related")
            let sameDay = app.buttons.matching(identifier: "photo-browser-same-day")
            let secondDayPhoto = app.buttons.matching(identifier: "day-photos-photo-app-store-screenshot-fixture-2")
            let secondPage = app.staticTexts.matching(NSPredicate(format: "label == %@", "2 / 2"))
            let back = app.buttons.matching(identifier: "BackButton")
            _ = try foreground(related, timeout: 15)
            capture(largeText ? "photo-related-largest-text" : "photo-related-widget-detail")
            try foreground(related).tap()
            let theme = app.buttons.matching(identifier: "photo-related-theme-close_up")
            let cat = app.buttons.matching(identifier: "photo-related-cat-fixture-cat-0")
            let year = app.buttons.matching(identifier: "photo-related-year-calendar_year_2025")
            _ = try foreground(theme)
            _ = try foreground(cat)
            _ = try foreground(year)
            _ = try hittableElements(app.buttons.matching(identifier: "photo-related-cat-fixture-cat-1"), count: 0)
            capture(largeText ? "photo-related-menu-largest-text" : "photo-related-menu")
            if largeText { app.terminate(); continue }

            try foreground(year).tap()
            let thirdYearPhoto = app.buttons.matching(identifier: "curated-album-photo-calendar_year_2025-app-store-screenshot-fixture-3")
            _ = try foreground(thirdYearPhoto)
            try closeSheet(in: app)
            try foreground(sameDay).tap()
            try foreground(secondDayPhoto).tap()
            _ = try foreground(secondPage)
            try foreground(related).tap()
            try foreground(theme).tap()
            let secondThemePhoto = app.buttons.matching(identifier: "curated-album-photo-close_up-app-store-screenshot-fixture-2")
            _ = try foreground(secondThemePhoto)
            _ = try hittableElements(app.buttons.matching(identifier: "curated-album-photo-close_up-app-store-screenshot-fixture-3"), count: 0)
            try foreground(secondThemePhoto).tap()
            _ = try foreground(related)
            _ = try foreground(app.buttons.matching(identifier: "photo-related-close"))
            capture("photo-related-sheet-photo")
            try foreground(related).tap()
            try foreground(cat).tap()
            let firstCatPhoto = app.buttons.matching(identifier: "curated-album-photo-all_cat_photos-app-store-screenshot-fixture-1")
            _ = try foreground(firstCatPhoto)
            _ = try hittableElements(app.buttons.matching(identifier: "curated-album-photo-all_cat_photos-app-store-screenshot-fixture-3"), count: 0)
            try foreground(firstCatPhoto).tap()
            try foreground(sameDay).tap()
            try foreground(secondDayPhoto).tap()
            _ = try foreground(secondPage)
            try foreground(related).tap()
            _ = try foreground(year)
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
            _ = try foreground(sameDay)
            try foreground(back).tap()
            let catShortcut = app.buttons.matching(identifier: "photo-hub-cat-fixture-cat-0")
            try foreground(catShortcut).tap()
            let catPhotos = app.buttons.matching(identifier: "cat-profile-photo")
            // This grid deliberately contains two choices; open its first visible card.
            try hittableElements(catPhotos, count: 2)[0].tap()
            try foreground(related).tap()
            try foreground(year).tap()
            try closeSheet(in: app)
            _ = try foreground(app.buttons.matching(identifier: "photo-memory-note-open"))
            try foreground(back).tap()
            XCTAssertTrue(app.navigationBars["ミケの写真"].waitForExistence(timeout: 5))
            _ = try hittableElements(catPhotos, count: 2)
            try foreground(back).tap()
            _ = try foreground(catShortcut)
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
        XCTAssertTrue(element("photo-browser-memory-saved-state", in: app).waitForExistence(timeout: 10))
        capture("solo-rediscovery-same-day-second-photo-saved")

        app.buttons["photo-browser-memory-saved-state"].tap()
        app.buttons["お気に入りから外す"].tap()
        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "app-store-screenshot-fixture-2|false"),
            object: app.staticTexts["solo-rediscovery-memory-request"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        XCTAssertEqual(app.alerts.count, 0)
        app.buttons["お気に入りに追加"].tap()
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
        XCTAssertTrue(app.buttons["お気に入りに追加"].isHittable,
                      "Two back actions return to the original, unsaved photo")
        XCTAssertFalse(element("photo-browser-memory-saved-state", in: app).exists)
        app.terminate()
    }

    @MainActor
    func testEmptyAndSingleFavoriteRemainReachableIncludingDeniedAccess() {
        for scenario in ["empty", "saved", "denied"] {
            let app = launch(scenario)
            assertAlbumsRoot(in: app)
            let favorites = element("albums-favorites", in: app)
            XCTAssertEqual(favorites.label, "お気に入り、\(scenario == "saved" ? 1 : 0)枚")
            openFavorites(in: app)
            if scenario == "saved" {
                XCTAssertTrue(app.staticTexts["solo-memories-loaded-1"].waitForExistence(timeout: 15))
                let selection = app.buttons["saved-memories-selection-toggle"]
                XCTAssertTrue(selection.isHittable)
                XCTAssertFalse(app.buttons["photo-book-export"].exists,
                               "Opening favorites must start in browsing mode.")
                capture("albums-single-favorite")
                selection.tap()
                let createPDF = app.buttons["saved-memories-create-pdf"]
                XCTAssertTrue(createPDF.waitForExistence(timeout: 5))
                createPDF.tap()
                XCTAssertTrue(app.navigationBars["写真を選ぶ"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["photo-book-export"].exists)
                XCTAssertFalse(app.buttons["photo-book-export"].isEnabled)
                XCTAssertTrue(app.staticTexts["0枚を選択"].exists)
                XCTAssertFalse(app.buttons["book-demand-preview"].exists)
                selection.tap()
                XCTAssertTrue(app.navigationBars["お気に入り"].waitForExistence(timeout: 5))

                selection.tap()
                let createBookPreview = app.buttons["saved-memories-create-book-preview"]
                XCTAssertTrue(createBookPreview.waitForExistence(timeout: 5))
                createBookPreview.tap()
                XCTAssertTrue(app.navigationBars["写真を選ぶ"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["book-demand-preview"].exists)
                XCTAssertFalse(app.buttons["book-demand-preview"].isEnabled)
                XCTAssertTrue(app.staticTexts["0枚を選択"].exists)
                XCTAssertFalse(app.buttons["photo-book-export"].exists)
                selection.tap()
                XCTAssertTrue(app.navigationBars["お気に入り"].waitForExistence(timeout: 5))
            } else {
                XCTAssertTrue(app.staticTexts["まだありません"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons["saved-memories-selection-toggle"].exists)
                if scenario == "empty" { capture("albums-empty-favorites") }
            }
            returnFromFavorites(in: app)
            if scenario != "saved" {
                let photos = app.buttons["memories-open-photos"]
                XCTAssertTrue(photos.waitForExistence(timeout: 10))
                XCTAssertTrue(photos.isHittable)
                photos.tap()
                let destination = app.staticTexts["solo-memories-other-screen"]
                XCTAssertTrue(destination.waitForExistence(timeout: 10))
                XCTAssertEqual(destination.label, "写真")
                app.buttons["solo-memories-return"].tap()
                assertAlbumsRoot(in: app)
            }
            if scenario == "denied" {
                fixtureAction("solo-memories-toggle-access", in: app, expectedValue: "写真アクセスあり")
                assertAlbumsRoot(in: app)
                XCTAssertEqual(favorites.label, "お気に入り、1枚")
                XCTAssertTrue(monthlyCard(in: app).waitForExistence(timeout: 10))
            } else {
                XCTAssertFalse(monthlyCard(in: app).exists)
            }
            app.terminate()
        }
    }

    @MainActor
    func testAlbumRootUpdatesAndPreservesFavoritesAndReflectionDestinations() {
        let app = launch("saved")
        assertAlbumsRoot(in: app)
        fixtureAction("solo-memories-add-letter", in: app, expectedValue: "便りあり")
        assertAlbumsRoot(in: app)
        XCTAssertTrue(monthlyCard(in: app).waitForExistence(timeout: 10))

        fixtureAction("solo-memories-toggle-access", in: app, expectedValue: "写真アクセスなし")
        assertAlbumsRoot(in: app)
        XCTAssertFalse(monthlyCard(in: app).exists)
        XCTAssertTrue(app.buttons["memories-open-photos"].isHittable)
        fixtureAction("solo-memories-toggle-access", in: app, expectedValue: "写真アクセスあり")
        assertAlbumsRoot(in: app)
        openCardAndReturn(monthlyCard(in: app), expectedRoute: "monthly:2025-08", in: app)
        visitOtherScreenAndReturn(in: app)
        assertAlbumsRoot(in: app)

        openFavorites(in: app)
        let favorite = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "猫の写真")).firstMatch
        openCardAndReturn(favorite, expectedRoute: "photo:app-store-screenshot-fixture-9", in: app)
        XCTAssertTrue(app.navigationBars["お気に入り"].waitForExistence(timeout: 10))
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
        readyApp.buttons["photo-browser-deliver"].tap()
        let family = readyApp.buttons["photo-window-destination-fixture-family"]
        XCTAssertTrue(family.waitForExistence(timeout: 10))
        family.tap()
        let cancel = readyApp.buttons["family-window-cancel-delivery"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(readyApp.staticTexts["2 / 5"].waitForExistence(timeout: 5))
        XCTAssertEqual(readyApp.staticTexts["solo-memories-delivery-state"].label,
                       "app-store-screenshot-fixture-2|0")
        XCTAssertTrue(readyApp.buttons["photo-browser-memory-saved-state"].exists)
        readyApp.navigationBars["写真"].buttons.element(boundBy: 0).tap()
        assertAlbumsRoot(in: readyApp)
        monthlyCard(in: readyApp).tap()
        XCTAssertTrue(readyApp.staticTexts["1 / 5"].waitForExistence(timeout: 5))
        image.swipeLeft()
        XCTAssertTrue(readyApp.staticTexts["2 / 5"].waitForExistence(timeout: 5))
        XCTAssertTrue(readyApp.buttons["photo-browser-memory-saved-state"].waitForExistence(timeout: 5),
                      "The saved second photo must remain saved after leaving and reopening the month.")
        capture("albums-monthly-second-photo-saved-and-reopened")
        readyApp.navigationBars["写真"].buttons.element(boundBy: 0).tap()
        assertAlbumsRoot(in: readyApp)
        XCTAssertFalse(element("albums-highlights-all", in: readyApp).exists,
                       "The heading must not create a redundant overview destination.")
        let archive = element("albums-months-all", in: readyApp)
        reveal(archive, in: readyApp)
        archive.tap()
        XCTAssertTrue(readyApp.navigationBars["月の写真"].waitForExistence(timeout: 10))
        let previousMonth = element("albums-month-2025-07", in: readyApp)
        reveal(previousMonth, in: readyApp)
        XCTAssertTrue(previousMonth.label.contains("1枚"))
        capture("albums-monthly-date-rows")
        openCardAndReturn(previousMonth, expectedRoute: "monthly:2025-07", in: readyApp)
        XCTAssertTrue(readyApp.navigationBars["月の写真"].waitForExistence(timeout: 10))
        capture("albums-reflections-archive-return")
        readyApp.navigationBars["月の写真"].buttons.element(boundBy: 0).tap()
        assertAlbumsRoot(in: readyApp)
        readyApp.terminate()
    }

    @MainActor
    func testHighlightsPageThroughTheirPhotosAndReopenFromTheCard() {
        for scenario in ["highlights", "highlights-large", "highlights-cats"] {
            let app = launch(scenario)
            assertAlbumsRoot(in: app)
            if scenario == "highlights-cats" {
                let favoritesLabel = element("albums-favorites", in: app).label
                XCTAssertFalse(element("albums-cat-fixture-cat-0", in: app).exists)
                for (identifier, title, route, cardID) in [
                    ("albums-months-all", "月の写真", "monthly:2025-08", "memories-monthly-window"),
                    ("albums-movies-all", "ムービー", "seasonal:2025-Q3", "albums-seasonal-movie")
                ] {
                    let entry = element(identifier, in: app)
                    reveal(entry, in: app)
                    entry.tap()
                    XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
                    openCardAndReturn(element(cardID, in: app), expectedRoute: route, in: app)
                    XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
                    app.navigationBars[title].buttons.element(boundBy: 0).tap()
                    assertAlbumsRoot(in: app)
                }
                XCTAssertEqual(element("albums-favorites", in: app).label, favoritesLabel,
                               "Household month and movie browsing must retain the complete favorites collection.")
                capture("albums-household-entries-with-registered-cats")
                app.terminate()
                continue
            }
            let firstFeatured = element("albums-highlight-featured", in: app)
            XCTAssertTrue(firstFeatured.waitForExistence(timeout: 10))
            reveal(firstFeatured, in: app)
            XCTAssertFalse(element("albums-highlights-all", in: app).exists)
            let firstLabel = firstFeatured.label
            let carousel = element("albums-pickup-carousel", in: app)
            carousel.swipeLeft()
            let visible = app.buttons.matching(identifier: "albums-highlight-featured")
                .allElementsBoundByIndex.filter { $0.isHittable }
            guard let featured = visible.min(by: {
                abs($0.frame.midX - carousel.frame.midX) < abs($1.frame.midX - carousel.frame.midX)
            }) else {
                XCTFail("The next pickup must be directly reachable by horizontal scrolling.")
                app.terminate()
                return
            }
            let featuredLabel = featured.label
            XCTAssertNotEqual(featuredLabel, firstLabel)
            let featuredX = featured.frame.minX
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
            XCTAssertEqual(returned.frame.minX, featuredX, accuracy: 12,
                           "Returning from the browser must preserve the horizontal card position.")
            waitForLoadedPhotos([expectedNumbers[0]], in: app)
            capture("albums-\(scenario)-featured")

            let closeUp = element("album-card-close_up", in: app)
            if !scenario.hasSuffix("-large") {
                XCTAssertTrue(returned.isHittable)
                XCTAssertTrue(closeUp.isHittable,
                    "The first fixed themes must be reachable alongside the compact feature.")
                XCTAssertGreaterThanOrEqual(closeUp.frame.minY, returned.frame.maxY)
            }
            reveal(closeUp, in: app)
            let closeUpFrame = closeUp.frame
            if scenario.hasSuffix("-large") {
                XCTAssertGreaterThan(closeUpFrame.width, app.frame.width / 2)
            } else {
                let together = element("album-card-together", in: app)
                XCTAssertTrue(together.isHittable)
                XCTAssertEqual(closeUpFrame.minY, together.frame.minY, accuracy: 2)
                XCTAssertLessThan(closeUpFrame.maxX, together.frame.minX)
            }
            capture("albums-\(scenario)-themes")
            openCardAndReturn(closeUp, expectedRoute: "album:close_up", in: app)

            // Reopen the same card; navigating into a theme must retain it.
            for _ in 0..<8 where !returned.isHittable { app.scrollViews.firstMatch.swipeDown() }
            XCTAssertTrue(returned.isHittable)
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
                let photos = app.buttons["memories-open-photos"]
                XCTAssertTrue(photos.isHittable)
                capture("albums-highlights-denied")
                photos.tap()
                XCTAssertTrue(app.staticTexts["solo-memories-other-screen"].waitForExistence(timeout: 5))
                app.buttons["solo-memories-return"].tap()
            }
            assertAlbumsRoot(in: app)
            app.terminate()
        }
    }

    @MainActor
    func testAlbumCoversAndFavoritesRemainReachableWithLargestText() {
        let app = launch("seasonal-large")
        assertAlbumsRoot(in: app)
        let seasonalCard = element("albums-seasonal-movie", in: app)
        XCTAssertTrue(seasonalCard.waitForExistence(timeout: 10))
        XCTAssertFalse(monthlyCard(in: app).exists)
        waitForLoadedPhotos([1], in: app)
        capture("albums-seasonal-largest-text")
        openCardAndReturn(seasonalCard, expectedRoute: "seasonal:2025-Q3", in: app)
        assertAlbumsRoot(in: app)

        fixtureAction("solo-memories-add-letter", in: app, expectedValue: "便りあり")
        assertAlbumsRoot(in: app)
        let favorites = element("albums-favorites", in: app)
        XCTAssertTrue(favorites.isHittable, "The header keeps favorites reachable at maximum text size.")
        let theme = element("album-card-close_up", in: app)
        reveal(theme, in: app)
        XCTAssertGreaterThan(theme.frame.width, app.frame.width / 2)
        XCTAssertGreaterThanOrEqual(theme.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(theme.frame.maxX, app.frame.maxX)
        capture("albums-close_up-largest-text")
        openCardAndReturn(theme, expectedRoute: "album:close_up", in: app)

        // Fixed destinations remain available even when today's carousel
        // keeps its existing movie rather than replacing it with the new month.
        for (identifier, title, route, cardID) in [
            ("albums-months-all", "月の写真", "monthly:2025-08", "memories-monthly-window"),
            ("albums-movies-all", "ムービー", "seasonal:2025-Q3", "albums-seasonal-movie")
        ] {
            let entry = element(identifier, in: app)
            reveal(entry, in: app)
            XCTAssertGreaterThan(entry.frame.width, app.frame.width / 2)
            XCTAssertGreaterThanOrEqual(entry.frame.height, 44)
            entry.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
            let item = element(cardID, in: app)
            reveal(item, in: app)
            XCTAssertGreaterThan(item.frame.width, app.frame.width / 2)
            XCTAssertGreaterThanOrEqual(item.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(item.frame.maxX, app.frame.maxX)
            capture("albums-\(identifier)-largest-text")
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
        XCTAssertTrue(app.navigationBars["年から探す"].exists)
        reveal(year, in: app)
        XCTAssertGreaterThan(year.frame.width, app.frame.width / 2)
        XCTAssertGreaterThanOrEqual(year.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(year.frame.maxX, app.frame.maxX)
        capture("albums-calendar_year_2025-largest-text")
        openCardAndReturn(year, expectedRoute: "album:calendar_year_2025", in: app)
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        XCTAssertTrue(year.isHittable, "Returning from a year preserves its place in the list.")
        app.navigationBars["年から探す"].buttons.element(boundBy: 0).tap()
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

    @MainActor
    private func monthlyCard(in app: XCUIApplication) -> XCUIElement {
        element("memories-monthly-window", in: app)
    }

    @MainActor
    private func openCardAndReturn(_ card: XCUIElement, expectedRoute: String, in app: XCUIApplication) {
        reveal(card, in: app)
        XCTAssertTrue(card.isEnabled)
        card.tap()
        if expectedRoute.hasPrefix("monthly:") {
            XCTAssertTrue(element("monthly-window-browser", in: app).waitForExistence(timeout: 10))
            XCTAssertTrue(app.navigationBars["写真"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.images["photo-detail-zoom-surface"].waitForExistence(timeout: 10))
            let destination = element("solo-memories-monthly-destination", in: app)
            XCTAssertTrue(destination.waitForExistence(timeout: 10))
            XCTAssertEqual(destination.label, String(expectedRoute.dropFirst("monthly:".count)))
            XCTAssertFalse((destination.value as? String ?? "").isEmpty)
            app.navigationBars["写真"].buttons.element(boundBy: 0).tap()
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

    @MainActor
    private func openPhotosTab(in app: XCUIApplication) {
        assertAlbumsRoot(in: app)
        // UIKit can omit SwiftUI's tab-item identifier after relaunch while
        // preserving the visible, accessible tab label.
        let identified = app.buttons["main-tab-photos"]
        let photos = identified.exists ? identified : app.tabBars.buttons["写真"]
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        photos.tap()
        XCTAssertTrue(app.navigationBars["写真"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["photos-open-automatic-albums"].exists)
    }

    @MainActor
    private func openFavorites(in app: XCUIApplication) {
        let favorites = element("albums-favorites", in: app)
        for _ in 0..<8 where !(favorites.exists && favorites.isHittable) { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(favorites.isHittable)
        favorites.tap()
        XCTAssertTrue(app.navigationBars["お気に入り"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func returnFromFavorites(in app: XCUIApplication) {
        app.navigationBars["お気に入り"].buttons.element(boundBy: 0).tap()
        assertAlbumsRoot(in: app)
    }

    @MainActor
    private func reveal(_ card: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(card.exists && card.isHittable) { app.scrollViews.firstMatch.swipeUp() }
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
        app.launchArguments = ["--photo-window-ui-fixture", "--memory-library-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let entry = app.buttons["albums-memory-notes"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(entry.value as? String, "1件")
        attach(app, name: "memory-library-album-entry")
        entry.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory-note-row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        attach(app, name: "memory-library-list")
        XCTAssertFalse(app.buttons["memory-notes-export"].exists)
        row.tap()
        let body = app.staticTexts["memory-note-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue(body.label.contains("小さな寝息"))
        let photo = app.buttons["memory-note-photo"]
        XCTAssertTrue(photo.isHittable)
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
        app.terminate()
    }

    @MainActor
    func testMemoryLibraryWithoutPhotoSupportsLargestTextEditingAndDeletion() {
        let app = XCUIApplication()
        app.launchArguments = ["--photo-window-ui-fixture", "--memory-library-fixture",
                               "--memory-library-no-photo", "--photo-window-large",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let entry = app.buttons["albums-memory-notes"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "Text must remain reachable without Photos access.\n\(app.debugDescription)")
        entry.tap()
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
        app.buttons["photo-memory-note-save"].tap()
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "文章は残っている。"), object: body)], timeout: 5), .completed)
        app.buttons["memory-note-menu"].tap()
        XCTAssertFalse(app.buttons["書き出す"].exists)
        app.buttons["メモを削除"].tap()
        app.buttons["削除"].tap()
        // Group-level identifiers are forwarded to the empty state's children.
        // Verify its visible content and keep export out of the current UI.
        XCTAssertTrue(app.staticTexts["写真に思い出を添えると、ここで読み返せます。"].waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
        XCTAssertFalse(app.buttons["memory-notes-export"].exists)
        attach(app, name: "memory-library-empty-after-deletion")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: entry)], timeout: 5), .completed)
        app.terminate()
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
    func testPersonalMemoryNoteSurvivesReopenStaysWithPhotoAndNeverBecomesCaption() {
        let app = XCUIApplication()
        app.launchArguments = ["--photo-window-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let open = app.buttons["photo-memory-note-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let input = app.textViews["photo-memory-note-text"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        // The fixture has its own file, never the user's store. Clear a note
        // from an interrupted prior run before starting the lifecycle check.
        if app.buttons["photo-memory-note-delete"].exists {
            app.buttons["photo-memory-note-delete"].tap()
            app.buttons["削除"].tap()
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            open.tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
        }
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
        app.buttons["変更を破棄"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertFalse(excerpt.exists)
        end.press(forDuration: 0.05, thenDragTo: start)
        XCTAssertTrue(excerpt.waitForExistence(timeout: 5))
        XCTAssertEqual(excerpt.value as? String, note)

        app.buttons["photo-browser-deliver"].tap()
        let family = app.buttons["photo-window-destination-family"]
        XCTAssertTrue(family.waitForExistence(timeout: 10))
        family.tap()
        let editCaption = app.buttons["family-window-caption-edit"]
        XCTAssertTrue(editCaption.waitForExistence(timeout: 10))
        editCaption.tap()
        let caption = app.descendants(matching: .any)["family-window-caption-input"].firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertFalse((caption.value as? String ?? "").contains(note), "Private memories must not be sent automatically")
        app.buttons["family-window-caption-done-top"].tap()
        app.buttons["family-window-cancel-delivery"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        let delete = app.buttons["photo-memory-note-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        app.buttons["削除"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertFalse(excerpt.exists)
        XCTAssertTrue(app.buttons["お気に入りに追加"].exists)
        app.terminate()
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
            XCTAssertGreaterThanOrEqual(app.buttons["お気に入りに追加"].frame.height, 44)
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
        XCTAssertEqual(save.label, "自分のお気に入りに追加")
        XCTAssertEqual(heart.label, "写真を届けた相手にハートを送る")
        XCTAssertTrue(heart.isEnabled)
        tapReceivedDetailControl(app, identifier: "family-window-save-memory")
        XCTAssertEqual(request.label, "save|1", "The callback must name the currently displayed photo.")
        tapReceivedDetailControl(app, identifier: "received-fixture-complete-action")
        tapReceivedDetailControl(app, identifier: "お気に入りの操作")
        let remove = app.buttons["お気に入りから外す"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertEqual(request.label, "remove|1")
        tapReceivedDetailControl(app, identifier: "received-fixture-complete-action")
        XCTAssertFalse(saved.exists)
        XCTAssertEqual(save.label, "自分のお気に入りに再追加",
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
    func testSharedAlbumMixesBothSidesAndOpensTheSelectedPhoto() {
        let expectedIDs = ["received-r1", "sent-s1", "received-r2", "sent-s2"]
        for variant in ["standard", "large", "narrow"] {
            let app = XCUIApplication()
            app.launchArguments = ["--moment-shared-album-ui-fixture", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
            if variant == "large" { app.launchArguments.append("--shared-album-large-text") }
            if variant == "narrow" { app.launchArguments.append("--shared-album-narrow") }
            app.launch()

            let projection = app.descendants(matching: .any)["shared-album-fixture-projection"].firstMatch
            XCTAssertTrue(projection.waitForExistence(timeout: 15))
            // Read the actual projection; a LazyVGrid need not instantiate offscreen cells.
            XCTAssertEqual(projection.value as? String, expectedIDs.joined(separator: ","),
                "Sort by addition time, use a stable tie order, prefer received duplicates, and omit missing/invalid sent images.")
            // The grid exposes the identified card as an AX container with a Button child.
            // Match its stable ID; tapping it must still open the exact photo below.
            let first = app.descendants(matching: .any)["shared-album-fixture-received-r1"].firstMatch
            let second = app.descendants(matching: .any)["shared-album-fixture-sent-s1"].firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            XCTAssertTrue(second.waitForExistence(timeout: 5))
            XCTAssertTrue(first.isHittable)
            XCTAssertEqual(first.frame.width, second.frame.width, accuracy: 2,
                "Both directions use the same photo columns.")
            XCTAssertGreaterThanOrEqual(first.frame.height + 1, first.frame.width,
                "The square photo must keep its area beneath the optional caption.")
            if variant == "large" {
                XCTAssertGreaterThanOrEqual(second.frame.minY + 1, first.frame.maxY,
                    "Accessibility text uses one column.")
                XCTAssertGreaterThan(first.frame.width, app.frame.width * 0.7)
            } else {
                XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 2)
                XCTAssertGreaterThanOrEqual(second.frame.minX + 1, first.frame.maxX)
                if variant == "narrow" { XCTAssertLessThanOrEqual(first.frame.width, 144) }
            }
            XCTAssertTrue(second.label.contains("ハートが届いています"))
            attach(app, name: "shared-album-\(variant)")

            let scroll = app.scrollViews["shared-album-fixture-scroll"]
            for (index, photoID) in expectedIDs.enumerated() {
                let tile = app.descendants(matching: .any)["shared-album-fixture-\(photoID)"].firstMatch
                for _ in 0..<6 where !(tile.exists && tile.isHittable) { scroll.swipeUp() }
                XCTAssertTrue(tile.exists && tile.isHittable, "Every projected photo remains reachable.")
                // Exercise both existing detail directions without repeating every identical transition.
                if index < 2 {
                    tile.tap()
                    let current = app.staticTexts["shared-album-fixture-current-photo"]
                    XCTAssertTrue(current.waitForExistence(timeout: 5))
                    XCTAssertEqual(current.value as? String, photoID)
                    let image = app.descendants(matching: .any)["photo-detail-zoom-surface"].firstMatch
                    XCTAssertTrue(image.waitForExistence(timeout: 10))
                    XCTAssertGreaterThan(Self.detailValue(image.value as? String, field: "pixels") ?? 0, 0)
                    if variant == "standard" { attach(app, name: "shared-album-detail-\(photoID)") }
                    closePhotoDetail(app)
                    XCTAssertTrue(tile.exists && tile.isHittable, "One close returns to the selected photo in the shared list.")
                }
            }
            for omittedID in ["sent-duplicate", "sent-missing", "sent-invalid"] {
                XCTAssertFalse(app.descendants(matching: .any)["shared-album-fixture-\(omittedID)"].firstMatch.exists)
            }
            if variant == "large" { attach(app, name: "shared-album-large-later-photos") }
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

/// The history and photo views are production components. Only the personal
/// store directory, fixture pixels and save/send boundaries are isolated.
final class PersonalRediscoveryUITests: XCTestCase {
    @MainActor
    func testDailyTurnKeepsYesterdayAndPreviousPhotoWithExistingPhotoActions() {
        continueAfterFailure = false
        for large in [false, true] {
            let app = application(large: large)
            app.launch()
            openHistory(in: app)
            let results = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "personal-rediscovery-result-"))
            let previous = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "personal-rediscovery-previous-"))
            XCTAssertTrue(results.firstMatch.waitForExistence(timeout: 10))
            XCTAssertEqual(results.count, 1)
            let yesterdayResultID = results.firstMatch.identifier
            let yesterdayPhotoID = results.firstMatch.value as? String ?? ""
            let previousButtonID = previous.firstMatch.identifier
            let previousPhotoID = previous.firstMatch.value as? String ?? ""
            XCTAssertFalse(yesterdayPhotoID.isEmpty)
            XCTAssertFalse(previousPhotoID.isEmpty)
            XCTAssertNotEqual(yesterdayPhotoID, previousPhotoID)

            let resultFrame = results.firstMatch.frame
            let previousFrame = previous.firstMatch.frame
            if large {
                XCTAssertGreaterThanOrEqual(previousFrame.minY, resultFrame.maxY,
                    "Accessibility text must stack the two photos vertically")
                XCTAssertEqual(resultFrame.minX, previousFrame.minX, accuracy: 2)
                XCTAssertGreaterThan(resultFrame.width, app.frame.width * 0.7)
            } else {
                XCTAssertEqual(resultFrame.minY, previousFrame.minY, accuracy: 2)
                XCTAssertGreaterThanOrEqual(previousFrame.minX, resultFrame.maxX)
            }

            let turn = app.buttons["personal-rediscovery-turn"]
            XCTAssertTrue(turn.isHittable)
            XCTAssertGreaterThanOrEqual(turn.frame.height, 44)
            turn.tap()
            XCTAssertTrue(app.descendants(matching: .any)["personal-rediscovery-used"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(results.count, 2, "Today's selection must keep yesterday's remaining 48-hour history")
            XCTAssertFalse(turn.exists, "Reading history must not offer a second daily turn")
            capture(large ? "rediscovery-history-large" : "rediscovery-history", app)

            let oldResult = app.buttons[yesterdayResultID]
            reveal(oldResult, in: app)
            oldResult.tap()
            assertPhoto(yesterdayPhotoID, in: app)
            let save = app.buttons.matching(NSPredicate(format: "label == %@", "お気に入りに追加"))
                .allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(save)
            save?.tap()
            XCTAssertTrue(app.buttons.matching(identifier: "photo-browser-memory-saved-state")
                .firstMatch.waitForExistence(timeout: 5))
            let deliver = app.buttons.matching(identifier: "photo-browser-deliver")
                .allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(deliver)
            deliver?.tap()
            XCTAssertTrue(app.descendants(matching: .any)["photo-window-no-destinations"].firstMatch.waitForExistence(timeout: 5))
            app.buttons["photo-window-cancel"].tap()
            assertPhoto(yesterdayPhotoID, in: app)
            capture(large ? "rediscovery-old-result-large" : "rediscovery-old-result", app)
            app.buttons["widget-photo-close"].tap()

            let prior = app.buttons[previousButtonID]
            reveal(prior, in: app)
            prior.tap()
            assertPhoto(previousPhotoID, in: app)
            app.buttons["widget-photo-close"].tap()
            XCTAssertEqual(results.count, 2, "Viewing the prior photo must not redraw or consume a turn")
            XCTAssertFalse(app.buttons["personal-rediscovery-turn"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testOneCandidateShowsPhotoWithoutSpendingADailyTurn() {
        continueAfterFailure = false
        let app = application()
        app.launchArguments.append("--personal-rediscovery-one-photo")
        app.launch()
        openHistory(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["personal-rediscovery-empty"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["personal-rediscovery-not-ready"].exists)
        XCTAssertFalse(app.buttons["personal-rediscovery-turn"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["personal-rediscovery-used"].firstMatch.exists)
        capture("rediscovery-one-candidate", app)
        app.buttons["personal-rediscovery-history-close"].tap()
        assertPhoto("app-store-screenshot-fixture-1", in: app)
    }

    @MainActor
    private func application(large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--personal-rediscovery-ui-fixture", "--photo-window-ui-fixture",
                               "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        if large { app.launchArguments.append("--personal-rediscovery-large") }
        return app
    }

    @MainActor
    private func openHistory(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["写真メニュー"].waitForExistence(timeout: 10))
        app.buttons["写真メニュー"].tap()
        let history = app.buttons["photo-browser-rediscovery-history"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        XCTAssertTrue(app.navigationBars["まどでめくった写真"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func reveal(_ button: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable)
    }

    @MainActor
    private func assertPhoto(_ identifier: String, in app: XCUIApplication) {
        let markers = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@",
            "personal-rediscovery-fixture-photo-id", identifier))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            markers.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.count == 1
                && app.images.matching(identifier: "photo-detail-zoom-surface")
                    .allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.count == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
