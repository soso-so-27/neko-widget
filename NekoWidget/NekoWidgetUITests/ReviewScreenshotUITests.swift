import XCTest

/// Design-review captures of every main screen, on synthetic fixtures only
/// (code-drawn cats, sample names, no account and no Photos import).
///
/// `.github/workflows/review-screenshots.yml` runs this class once per set:
/// `REVIEW_SET` (passed as `TEST_RUNNER_REVIEW_SET`) is `light`, `dark` or
/// `se`. A screen that cannot be reached is recorded as a miss and the walk
/// goes on; `ci/collect-review-screenshots.py` turns the attachments named
/// `review-shot__<name>__end` and `review-missing__<name>__end` into
/// `<set>/<name>.png` and `index.txt`. The expected names are listed there.
final class ReviewScreenshotUITests: XCTestCase {
    /// Layout-critical screens also captured on the small iPhone SE.
    static let seScreens: Set<String> = [
        "10_tools_tab", "11_cat_care_top", "12_vet_bottom", "14_lost_bottom", "16_care_bottom",
        "23_plus_offer_top", "23_plus_offer_bottom", "24_settings_top", "28_onboarding_1",
    ]
    private static let mike = "11111111-1111-4111-8111-111111111111"

    private var reviewSet: String {
        ProcessInfo.processInfo.environment["REVIEW_SET"] ?? "light"
    }

    override func setUpWithError() throws {
        // A screen that is not reached is a recorded miss, never a stop.
        continueAfterFailure = true
        executionTimeAllowance = 900
    }

    // MARK: - 写真

    @MainActor
    func test01Photos() {
        let app = launch(fixture + ["--group-window-screens-fixture"])
        let grid = app.descendants(matching: .any)["photo-hub-detected-grid"]
        shot("01_photos_top", app) {
            guard tapTab(app, "main-tab-photos", "写真") else { return "photos tab not found" }
            tapIfPresent(app.buttons["photos-section-all"])
            guard grid.waitForExistence(timeout: 20) else { return "photo grid did not appear" }
            _ = waitForFixturePhotos(app, [1, 2, 3])
            return nil
        }
        shot("01_photos_scrolled", app) {
            guard grid.exists else { return "photo grid not shown" }
            app.swipeUp(); app.swipeUp()
            return nil
        }
        for _ in 0..<3 { app.swipeDown() }
        let first = app.buttons["photo-hub-photo-app-store-screenshot-fixture-1"]
        let memo = app.buttons["photo-memory-note-open"]
        shot("02_photo_detail", app) {
            guard reveal(first, app) else { return "first fixture photo not hittable" }
            first.tap()
            guard memo.waitForExistence(timeout: 15) else { return "photo screen did not open" }
            return nil
        }
        shot("03_memo_editor", app) {
            guard memo.exists, memo.isHittable else { return "memo button not on the photo screen" }
            memo.tap()
            guard app.textViews["photo-memory-note-text"].waitForExistence(timeout: 10)
                    || app.navigationBars["メモ"].waitForExistence(timeout: 5) else { return "memo editor did not open" }
            return nil
        }
        let closeMemo = app.buttons["photo-memory-note-close"]
        if closeMemo.exists { closeMemo.tap() } else { closeTop(app) }
        _ = memo.waitForExistence(timeout: 5)
        shot("06_window_send", app) {
            let deliver = app.buttons["photo-browser-deliver-group"]
            guard deliver.waitForExistence(timeout: 10) else { return "「まどに届ける」 is not on the photo screen" }
            deliver.tap()
            // The sheet asks for Photos access over itself on a fresh
            // Simulator; decline it so the sheet is what is captured.
            declinePhotosPrompt(timeout: 8)
            let sheet = anyIdentifier(app, ["group-library-delivery-send", "group-library-delivery-destination"])
            let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "に届ける")).firstMatch
            guard sheet.waitForExistence(timeout: 10) || title.waitForExistence(timeout: 5) else {
                return "delivery sheet did not open"
            }
            declinePhotosPrompt(timeout: 2)
            settle(1)
            return nil
        }
        app.terminate()
    }

    // MARK: - まど

    @MainActor
    func test02Windows() {
        let app = launch(fixture + ["--group-window-screens-fixture", "--app-store-screenshot-nowa"])
        let room = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "実家のまど")).firstMatch
        shot("04_windows_list", app) {
            guard tapTab(app, "main-tab-windows", "まど") else { return "windows tab not found" }
            guard room.waitForExistence(timeout: 20) else { return "「実家のまど」 card not found" }
            settle(2)
            return nil
        }
        shot("05_window_feed_top", app) {
            guard room.exists else { return "windows list not shown" }
            room.tap()
            guard app.buttons["group-window-open-members"].waitForExistence(timeout: 15) else {
                return "window feed did not open"
            }
            _ = app.images.firstMatch.waitForExistence(timeout: 10)
            settle(2)
            return nil
        }
        shot("05_window_feed_bottom", app) {
            guard app.buttons["group-window-open-members"].exists else { return "window feed not shown" }
            scrollToEnd(app)
            return nil
        }
        app.terminate()
    }

    // MARK: - アルバム

    @MainActor
    func test03Albums() {
        let app = launch(fixture + ["--app-store-screenshot-album"])
        let latest = anyIdentifier(app, ["album-prototype-latest", "album-prototype-year"])
        shot("07_album_shelf_plus", app) {
            _ = tapTab(app, "main-tab-memories", "アルバム")
            guard app.navigationBars["アルバム"].waitForExistence(timeout: 20) else { return "Albums did not appear" }
            guard latest.waitForExistence(timeout: 15) else { return "newest work not on the shelf" }
            _ = waitForAnyFixturePhoto(app, Array(19...24))
            return nil
        }
        shot("09_album_work_open", app) {
            guard latest.exists else { return "newest work not on the shelf" }
            latest.tap()
            guard anyIdentifier(app, ["monthly-story", "monthly-book", "year-story", "year-book"])
                    .waitForExistence(timeout: 15) else { return "work did not open" }
            _ = waitForAnyFixturePhoto(app, Array(19...24))
            settle(1.5)
            return nil
        }
        app.terminate()

        // Non-member: the membership-access fixture pushes the same screens
        // with an inactive membership.
        let member = launch(["--membership-access-ui-fixture", "--photo-window-ui-fixture",
                             "--app-store-screenshot-album"])
        let memberLatest = anyIdentifier(member, ["album-prototype-latest", "album-prototype-year"])
        shot("08_album_nonmember", member) {
            let tools = member.buttons["membership-tools"]
            guard tools.waitForExistence(timeout: 15) else { return "membership fixture did not start" }
            tools.tap()
            guard tapTab(member, "main-tab-memories", "アルバム") else { return "Albums tab not found" }
            guard memberLatest.waitForExistence(timeout: 15) else { return "newest work not on the shelf" }
            _ = waitForAnyFixturePhoto(member, Array(19...24))
            return nil
        }
        // Extra: what a non-member meets when opening the work.
        shot("08b_album_nonmember_work_gate", member) {
            guard memberLatest.exists else { return "newest work not on the shelf" }
            memberLatest.tap()
            guard anyIdentifier(member, ["album-work-plus-gate", "membership-offer-heading", "membership-offer-purchase",
                                         "monthly-story", "monthly-book"]).waitForExistence(timeout: 15) else {
                return "nothing appeared after opening the work"
            }
            settle(2)
            return nil
        }
        member.terminate()
    }

    // MARK: - ツール: この子のこと・病院

    @MainActor
    func test04ToolsCatCareAndVet() {
        let app = launch(fixture + ["--app-store-screenshot-cat-care"], tools: true)
        shot("10_tools_tab", app) {
            guard tapTab(app, "main-tab-tools", "ツール") else { return "tools tab not found" }
            guard app.buttons["tools-care-open"].waitForExistence(timeout: 15) else { return "tools did not appear" }
            settle(1)
            return nil
        }
        let catChip = app.descendants(matching: .any)["tools-cat-" + Self.mike].firstMatch
        let catPage = anyIdentifier(app, ["cat-profile-rename", "cat-care-family-notebook", "cat-care-part-basics"])
        shot("11_cat_care_top", app) {
            app.swipeDown()
            guard catChip.waitForExistence(timeout: 10) else { return "cat chip on tools not found" }
            catChip.tap()
            guard catPage.waitForExistence(timeout: 15) else { return "「この子のこと」 did not open" }
            settle(1)
            return nil
        }
        shot("27_family_notebook", app) {
            let family = app.buttons["cat-care-family-notebook"]
            guard family.waitForExistence(timeout: 5), family.isHittable else { return "family notebook entry not shown" }
            family.tap()
            guard app.navigationBars["家族の手帳"].waitForExistence(timeout: 10) else { return "family notebook did not open" }
            settle(1)
            return nil
        }
        if app.navigationBars["家族の手帳"].exists { closeTop(app) }
        _ = catPage.waitForExistence(timeout: 5)
        shot("11_cat_care_bottom", app) {
            guard catPage.exists else { return "「この子のこと」 not shown" }
            scrollToEnd(app, until: app.buttons["cat-profile-delete"], maximumSwipes: 16)
            return nil
        }
        shot("11b_cat_care_text_page", app) {
            let row = app.descendants(matching: .any)["cat-care-temperament-row"].firstMatch
            guard reveal(row, app, maximumSwipes: 14) else { return "「接し方」 row not found" }
            row.tap()
            guard app.navigationBars["接し方・苦手なこと"].waitForExistence(timeout: 10) else { return "text page did not open" }
            settle(1.5)
            return nil
        }
        app.terminate()

        let vet = launch(fixture + ["--app-store-screenshot-cat-care"], tools: true)
        let noticed = vet.buttons["vet-step-noticed"]
        shot("12_vet_top", vet) {
            guard openTool(vet, "tools-vet-open") else { return "病院 tile not found" }
            chooseCat(vet, menu: "vet-cat-menu")
            guard noticed.waitForExistence(timeout: 15) else { return "病院 did not open" }
            settle(1)
            return nil
        }
        shot("12_vet_bottom", vet) {
            guard noticed.exists else { return "病院 not shown" }
            scrollToEnd(vet, until: vet.descendants(matching: .any)["vet-cat-care-fields-folded"].firstMatch)
            return nil
        }
        for _ in 0..<8 where !noticed.isHittable { vet.swipeDown() }
        let page = vet.navigationBars["家で気付いたこと"]
        shot("12b_vet_row_page", vet) {
            guard reveal(noticed, vet) else { return "「家で気付いたこと」 row not hittable" }
            noticed.tap()
            guard page.waitForExistence(timeout: 10) else { return "row page did not open" }
            let field = vet.descendants(matching: .any)["vet-observations"].firstMatch
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText("ごはんを少し残すことがあります。")
                closeKeyboard(vet)
            }
            settle(1)
            return nil
        }
        if page.exists { page.buttons.element(boundBy: 0).tap(); _ = page.waitForNonExistence(timeout: 5) }
        shot("13_vet_read", vet) {
            let show = vet.buttons["vet-show"]
            guard show.waitForExistence(timeout: 10) else { return "「先生に見せる」 not found" }
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: show)
            guard XCTWaiter.wait(for: [enabled], timeout: 15) == .completed else { return "「先生に見せる」 stayed disabled" }
            show.tap()
            guard vet.descendants(matching: .any)["vet-reading"].firstMatch.waitForExistence(timeout: 15)
                    || vet.navigationBars["診察メモ"].waitForExistence(timeout: 5) else { return "reading view did not open" }
            settle(1.5)
            return nil
        }
        vet.terminate()
    }

    // MARK: - ツール: 迷子・預けるとき

    @MainActor
    func test05ToolsLostAndCare() {
        let app = launch(fixture + ["--app-store-screenshot-cat-care"], tools: true)
        let guide = anyIdentifier(app, ["lost-cat-row-guide", "lost-cat-row-photo"])
        shot("14_lost_top", app) {
            guard openTool(app, "tools-lost-cat-open") else { return "迷子 tile not found" }
            guard guide.waitForExistence(timeout: 15) else { return "迷子 did not open" }
            settle(1)
            return nil
        }
        shot("14_lost_bottom", app) {
            guard guide.exists else { return "迷子 not shown" }
            scrollToEnd(app, until: app.buttons["lost-cat-row-advice"])
            return nil
        }
        app.terminate()

        let care = launch(fixture + ["--app-store-screenshot-cat-care"], tools: true)
        let preview = care.buttons["care-preview-open"]
        shot("16_care_top", care) {
            guard openTool(care, "tools-care-open") else { return "預けるとき tile not found" }
            guard preview.waitForExistence(timeout: 15) else { return "預けるとき did not open" }
            chooseCat(care, menu: "care-cat-menu")
            settle(1)
            return nil
        }
        shot("16_care_bottom", care) {
            guard preview.exists else { return "預けるとき not shown" }
            scrollToEnd(care, until: care.descendants(matching: .any)["care-cat-care-fields-folded"].firstMatch)
            return nil
        }
        shot("17_care_done", care) {
            guard preview.exists else { return "預けるとき not shown" }
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: preview)
            guard XCTWaiter.wait(for: [enabled], timeout: 10) == .completed else { return "「できあがり」 button disabled" }
            preview.tap()
            guard care.navigationBars["できあがり"].waitForExistence(timeout: 15) else { return "できあがり did not open" }
            settle(2)
            return nil
        }
        care.terminate()
    }

    // MARK: - ツール: 避難・見せる

    @MainActor
    func test06ToolsEvacuationAndShowcase() {
        let app = launch(fixture + ["--app-store-screenshot-cat-care"], tools: true)
        let now = app.buttons["evacuation-now-open"]
        shot("18_evac_top", app) {
            guard openTool(app, "tools-evacuation-open") else { return "避難 tile not found" }
            guard now.waitForExistence(timeout: 15) else { return "避難 did not open" }
            settle(1)
            return nil
        }
        shot("18_evac_bottom", app) {
            guard now.exists else { return "避難 not shown" }
            scrollToEnd(app, until: app.descendants(matching: .any)["evacuation-notices-toggle"].firstMatch)
            return nil
        }
        for _ in 0..<8 where !now.isHittable { app.swipeDown() }
        shot("19_evac_now", app) {
            guard reveal(now, app) else { return "「いま避難する」 not hittable" }
            now.tap()
            guard app.navigationBars["いま避難する"].waitForExistence(timeout: 10) else { return "いま避難する did not open" }
            settle(1)
            return nil
        }
        back(app)
        shot("20_evac_packing", app) {
            let packing = app.buttons["evacuation-packing-open"]
            guard reveal(packing, app) else { return "「持ち出すもの」 not hittable" }
            packing.tap()
            guard app.navigationBars["持ち出すもの"].waitForExistence(timeout: 10) else { return "持ち出すもの did not open" }
            settle(1)
            return nil
        }
        back(app)
        shot("21_evac_memo", app) {
            let cats = app.buttons["evacuation-cats-open"]
            guard reveal(cats, app) else { return "「猫の情報」 not hittable" }
            cats.tap()
            let open = app.buttons["evacuation-preview-open"]
            guard open.waitForExistence(timeout: 15) else { return "猫の情報 did not open" }
            guard reveal(open, app), open.isEnabled else { return "「避難メモ」 button not usable" }
            open.tap()
            let memo = app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS %@ OR label CONTAINS %@",
                                                               "避難メモ", "避難メモ")).firstMatch
            guard memo.waitForExistence(timeout: 15)
                    || app.descendants(matching: .any)["evacuation-share-preview"].firstMatch.waitForExistence(timeout: 5) else {
                return "避難メモ did not open"
            }
            settle(1.5)
            return nil
        }
        app.terminate()

        let showcase = launch(fixture, tools: true)
        shot("22_showcase", showcase) {
            guard openTool(showcase, "tools-showcase-open") else { return "見せる tile not found" }
            guard anyIdentifier(showcase, ["showcase-gallery", "showcase-back"]).waitForExistence(timeout: 15) else {
                return "showcase did not open"
            }
            _ = waitForAnyFixturePhoto(showcase, Array(1...8))
            settle(1.5)
            return nil
        }
        showcase.terminate()
    }

    // MARK: - 迷子のチラシ (prepared draft with synthetic photos)

    @MainActor
    func test07LostFlyer() {
        let app = launch(["--lost-cat-draft-ui-fixture"], environment: [
            "NEKO_LOST_CAT_DRAFT_FIXTURE_KEY": "guest-fixture-review-screenshots",
            "NEKO_LOST_CAT_PREPARED_PHOTOS": "1",
        ])
        let photoRow = app.buttons["lost-cat-row-photo"]
        shot("14b_lost_photo_page", app) {
            guard photoRow.waitForExistence(timeout: 20) else { return "lost-cat draft did not open" }
            photoRow.tap()
            guard app.navigationBars["写真"].waitForExistence(timeout: 10) else { return "photo page did not open" }
            settle(1.5)
            return nil
        }
        if app.navigationBars["写真"].exists { back(app) }
        shot("15_lost_preview", app) {
            let make = app.buttons["チラシを作る"]
            guard make.waitForExistence(timeout: 10) else { return "「チラシを作る」 not found" }
            _ = reveal(make, app)
            guard make.isEnabled else { return "「チラシを作る」 disabled (draft incomplete)" }
            make.tap()
            guard app.navigationBars["できあがり"].waitForExistence(timeout: 20) else { return "できあがり did not open" }
            settle(2.5)
            return nil
        }
        app.terminate()
    }

    // MARK: - Plus

    @MainActor
    func test08PlusOffer() {
        func openOffer(_ arguments: [String], entry: String) -> XCUIApplication {
            let app = launch(["--membership-offer-ui-fixture"] + arguments)
            let open = app.buttons[entry]
            if open.waitForExistence(timeout: 15), reveal(open, app) { open.tap() }
            return app
        }
        var app = openOffer([], entry: "membership-preview-open")
        let heading = app.staticTexts["membership-offer-heading"]
        shot("23_plus_offer_top", app) {
            guard heading.waitForExistence(timeout: 15)
                    || app.buttons["membership-offer-purchase"].waitForExistence(timeout: 5) else {
                return "Plus offer did not open"
            }
            settle(1.5)
            return nil
        }
        shot("23_plus_offer_bottom", app) {
            guard app.buttons["membership-offer-purchase"].exists || heading.exists else { return "Plus offer not shown" }
            scrollToEnd(app, until: app.descendants(matching: .any)["membership-offer-privacy"].firstMatch)
            return nil
        }
        app.terminate()

        app = openOffer([], entry: "membership-preview-open-monthly-summary")
        shot("23b_plus_offer_from_work", app) {
            guard app.buttons["membership-offer-purchase"].waitForExistence(timeout: 15) else {
                return "Plus offer (from a work) did not open"
            }
            settle(1.5)
            return nil
        }
        app.terminate()

        app = openOffer([], entry: "membership-preview-open-onboarding")
        shot("23c_plus_offer_onboarding", app) {
            guard app.buttons["membership-offer-purchase"].waitForExistence(timeout: 15) else {
                return "Plus offer (first run) did not open"
            }
            settle(1.5)
            return nil
        }
        app.terminate()

        app = openOffer(["--membership-offer-load-fails-once"], entry: "membership-preview-open")
        shot("91_error_plus_product_unavailable", app) {
            guard app.buttons["membership-offer-reload"].waitForExistence(timeout: 15) else {
                return "price-unavailable state did not appear"
            }
            settle(1)
            return nil
        }
        app.terminate()
    }

    // MARK: - 設定

    @MainActor
    func test09Settings() {
        let app = launch(fixture, tools: true)
        let title = app.navigationBars["設定"]
        shot("24_settings_top", app) {
            guard tapTab(app, "main-tab-tools", "ツール") else { return "tools tab not found" }
            let button = app.buttons["tools-settings-button"]
            guard button.waitForExistence(timeout: 15) else { return "settings button not found" }
            button.tap()
            guard title.waitForExistence(timeout: 10) else { return "settings did not open" }
            settle(1)
            return nil
        }
        shot("24_settings_bottom", app) {
            guard title.exists else { return "settings not shown" }
            scrollToEnd(app, until: anyIdentifier(app, ["settings-app-version", "settings-account-deletion"]), maximumSwipes: 14)
            return nil
        }
        shot("25_settings_photos", app) {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "写真の表示と整理")).firstMatch
            guard reveal(row, app, maximumSwipes: 14) else { return "「写真の表示と整理」 row not found" }
            row.tap()
            guard app.navigationBars["写真の表示と整理"].waitForExistence(timeout: 10) else { return "photo settings did not open" }
            settle(1)
            return nil
        }
        if app.navigationBars["写真の表示と整理"].exists { back(app) }
        let guide = app.buttons["settings-widget-placement-guide"]
        let steps = app.descendants(matching: .any)["widget-placement-steps"].firstMatch
        shot("29_widget_guide_1", app) {
            guard reveal(guide, app, maximumSwipes: 14) else { return "widget guide row not found" }
            guide.tap()
            guard app.buttons["widget-placement-close"].waitForExistence(timeout: 15) else { return "widget guide did not open" }
            settle(1.5)
            return nil
        }
        for page in 2...5 {
            shot("29_widget_guide_\(page)", app) {
                guard app.buttons["widget-placement-close"].exists else { return "widget guide not shown" }
                if steps.exists { steps.swipeLeft() } else { app.swipeLeft() }
                settle(1.5)
                return nil
            }
        }
        app.terminate()

        let records = launch(["--app-records-ui-fixture"])
        shot("26_autosave", records) {
            let open = records.buttons["保存・復元"]
            guard open.waitForExistence(timeout: 15) else { return "app-records fixture did not start" }
            open.tap()
            guard anyIdentifier(records, ["app-record-enable", "app-record-save-status"]).waitForExistence(timeout: 15) else {
                return "保存・復元 did not open"
            }
            settle(1)
            return nil
        }
        records.terminate()
    }

    // MARK: - 初回起動

    @MainActor
    func test12Onboarding() {
        // Pages one and two are the real first launch (no fixture root).
        // Earlier tests may have declined Photos; page two needs it undecided.
        XCUIApplication().resetAuthorizationStatus(for: .photos)
        let app = launch([], environment: ["NEKO_RESET_ONBOARDING_FOR_UI_TESTS": "1"])
        let start = app.buttons["onboarding-purpose-start"]
        shot("28_onboarding_1", app) {
            guard start.waitForExistence(timeout: 25) else { return "first onboarding page did not appear" }
            settle(1)
            return nil
        }
        shot("28_onboarding_2", app) {
            guard start.exists else { return "first onboarding page not shown" }
            start.tap()
            let allow = app.buttons["onboarding-photo-permission-allow"]
            guard allow.waitForExistence(timeout: 15) else { return "Photos permission page did not appear" }
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: allow)
            _ = XCTWaiter.wait(for: [ready], timeout: 15)
            settle(1)
            return nil
        }
        app.terminate()

        // The scan pages use the onboarding fixture with synthetic results.
        func scan(_ scenario: String) -> XCUIApplication {
            launch(["--app-store-screenshot-fixture"], environment: ["NEKO_MAINLINE_ACCEPTANCE_CASE": scenario])
        }
        let found = scan("three")
        shot("28_onboarding_3_scan_found", found) {
            guard found.buttons["initial-scan-continue"].waitForExistence(timeout: 20) else { return "scan page did not appear" }
            _ = found.staticTexts["mainline-loaded-4"].waitForExistence(timeout: 15)
            settle(1)
            return nil
        }
        found.terminate()

        let zero = scan("zero")
        shot("28_onboarding_4_scan_zero", zero) {
            guard anyIdentifier(zero, ["onboarding-scan-zero-body", "initial-scan-continue"]).waitForExistence(timeout: 20) else {
                return "zero-cat scan page did not appear"
            }
            settle(1)
            return nil
        }
        zero.terminate()

        let one = scan("one")
        shot("28_onboarding_5_widget_guide", one) {
            let guide = one.buttons["initial-scan-widget-guide"]
            guard guide.waitForExistence(timeout: 20) else { return "widget guide entry not on the scan page" }
            guide.tap()
            guard one.buttons["widget-placement-skip"].waitForExistence(timeout: 15) else { return "widget guide did not open" }
            settle(1.5)
            return nil
        }
        one.terminate()
    }

    // MARK: - Where things go wrong

    @MainActor
    func test13ValidationError() {
        let app = launch(fixture + ["--app-store-screenshot-cat-care"], tools: true)
        let noticed = app.buttons["vet-step-noticed"]
        let page = app.navigationBars["家で気付いたこと"]
        shot("90_error_vet_field_page", app) {
            guard openTool(app, "tools-vet-open") else { return "病院 tile not found" }
            chooseCat(app, menu: "vet-cat-menu")
            guard noticed.waitForExistence(timeout: 15), reveal(noticed, app) else { return "病院 did not open" }
            noticed.tap()
            guard page.waitForExistence(timeout: 10) else { return "row page did not open" }
            let field = app.descendants(matching: .any)["vet-observations"].firstMatch
            guard field.waitForExistence(timeout: 5) else { return "field not found" }
            field.tap()
            // 502 characters: over the 500-character limit of this field.
            field.typeText(String(repeating: "ねこ", count: 251))
            closeKeyboard(app)
            settle(1.5)
            return nil
        }
        shot("90_error_vet_row", app) {
            guard page.exists else { return "row page not shown" }
            page.buttons.element(boundBy: 0).tap()
            guard noticed.waitForExistence(timeout: 10) else { return "did not return to 病院" }
            settle(1.5)
            return nil
        }
        app.terminate()
    }

    // MARK: - Helpers

    private var fixture: [String] {
        ["--app-store-screenshot-fixture", "--review-public-presentation"]
    }

    /// Launches with the set's appearance; retries once when the launch does
    /// not reach the foreground (a known Simulator flake on hosted runners).
    @MainActor
    private func launch(_ arguments: [String], environment: [String: String] = [:],
                        tools: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        let appearance = reviewSet == "dark" ? "dark" : "light"
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
                               "-app.appearance.v1", appearance] + arguments
        if appearance == "dark", arguments.contains("--app-store-screenshot-fixture") {
            app.launchArguments.append("--tools-hub-dark")
        }
        var environment = environment
        if tools { environment["NEKO_UX_RECOVERY_CASE"] = "tool-profiles" }
        app.launchEnvironment = environment
        for attempt in 0..<2 {
            app.launch()
            if app.wait(for: .runningForeground, timeout: 45) { break }
            note("launch attempt \(attempt + 1) did not reach the foreground")
            app.terminate()
        }
        declinePhotosPrompt()
        return app
    }

    /// One screen: `reach` brings it up (nil) or says why it could not.
    @MainActor
    private func shot(_ name: String, _ app: XCUIApplication, _ reach: () -> String?) {
        if let reason = reach() {
            guard wants(name) else { return }
            let attachment = XCTAttachment(string: reason + "\n\n" + app.debugDescription)
            attachment.name = "review-missing__\(name)__end"
            attachment.lifetime = .keepAlways
            add(attachment)
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "review-debug__\(name)__end"
            screen.lifetime = .keepAlways
            add(screen)
            return
        }
        guard wants(name) else { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "review-shot__\(name)__end"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wants(_ name: String) -> Bool {
        reviewSet != "se" || Self.seScreens.contains(name)
    }

    private func note(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "review-note"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func declinePhotosPrompt(timeout: TimeInterval = 2) {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else { return }
        let deny = alert.buttons.matching(NSPredicate(format: "label IN %@",
                                                      ["Don’t Allow", "Don't Allow", "許可しない"])).firstMatch
        if deny.exists { deny.tap() }
    }

    @MainActor
    private func tapTab(_ app: XCUIApplication, _ identifier: String, _ label: String) -> Bool {
        let identified = app.buttons[identifier]
        if identified.waitForExistence(timeout: 15) { identified.tap(); return true }
        let labelled = app.tabBars.buttons[label]
        if labelled.waitForExistence(timeout: 5) { labelled.tap(); return true }
        return false
    }

    /// From a fresh launch: the ツール tab, then one tool's tile.
    @MainActor
    private func openTool(_ app: XCUIApplication, _ tile: String) -> Bool {
        guard tapTab(app, "main-tab-tools", "ツール") else { return false }
        let button = app.buttons[tile]
        guard button.waitForExistence(timeout: 15), reveal(button, app) else { return false }
        button.tap()
        return true
    }

    /// With two cats, pick ミケ from the tool's cat menu when there is one.
    @MainActor
    private func chooseCat(_ app: XCUIApplication, menu identifier: String) {
        let menu = app.buttons[identifier]
        guard menu.waitForExistence(timeout: 5) else { return }
        menu.tap()
        let item = app.buttons["tool-profile-" + Self.mike]
        if item.waitForExistence(timeout: 5) {
            item.tap()
            _ = item.waitForNonExistence(timeout: 5)
        } else {
            closeTop(app)
        }
    }

    @MainActor
    private func anyIdentifier(_ app: XCUIApplication, _ identifiers: [String]) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", identifiers)).firstMatch
    }

    @MainActor
    private func tapIfPresent(_ element: XCUIElement) {
        if element.waitForExistence(timeout: 5), element.isHittable { element.tap() }
    }

    /// Swipes up, then down, until the element can be tapped.
    @MainActor
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, maximumSwipes: Int = 8) -> Bool {
        if element.exists, element.isHittable { return true }
        for _ in 0..<maximumSwipes {
            app.swipeUp(velocity: .slow)
            if element.exists, element.isHittable { return true }
        }
        for _ in 0..<(maximumSwipes * 2) {
            app.swipeDown(velocity: .slow)
            if element.exists, element.isHittable { return true }
        }
        return false
    }

    /// Scrolls to the end: until `until` is on screen, then twice more so
    /// the list rests at its very end (where the fixed bars meet the last rows).
    @MainActor
    private func scrollToEnd(_ app: XCUIApplication, until element: XCUIElement? = nil, maximumSwipes: Int = 10) {
        for _ in 0..<maximumSwipes {
            if let element, element.exists, element.isHittable { break }
            app.swipeUp()
        }
        app.swipeUp(); app.swipeUp()
        settle(1.2)
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.waitForExistence(timeout: 5) { button.tap() }
        settle(0.8)
    }

    @MainActor
    private func closeTop(_ app: XCUIApplication) {
        for label in ["閉じる", "完了"] {
            let button = app.buttons[label].firstMatch
            if button.exists, button.isHittable { button.tap(); settle(0.8); return }
        }
        app.swipeDown(velocity: .fast)
        settle(0.8)
    }

    @MainActor
    private func closeKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        let close = app.buttons["キーボードを閉じる"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
    }

    @MainActor
    private func waitForFixturePhotos(_ app: XCUIApplication, _ numbers: [Int]) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if numbers.allSatisfy({ fixturePhotoLoaded(app, $0) }) { settle(0.3); return true }
            settle(0.2)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func waitForAnyFixturePhoto(_ app: XCUIApplication, _ numbers: [Int]) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if numbers.contains(where: { fixturePhotoLoaded(app, $0) }) { settle(0.3); return true }
            settle(0.2)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func fixturePhotoLoaded(_ app: XCUIApplication, _ number: Int) -> Bool {
        app.descendants(matching: .any)
            .matching(identifier: "app-store-screenshot-fixture-photo-loaded-app-store-screenshot-fixture-\(number)")
            .count >= 1
    }
}
