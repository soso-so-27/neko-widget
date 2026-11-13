import XCTest

/// 画面ごとの表示の速さを測る（記録だけ。合否の線は置かない）。
///
/// - 手で開く画面: 操作の直前から、その画面の目印が出るまでの時間（ms）を
///   `SPEED|<画面>|<指標>|<値>` の 1 行で出す。XCUITest の問い合わせ自体の
///   時間を含むので、`基準` 行（すでに出ている要素を確かめるだけの時間）を
///   同じ実行で測り、比べられるようにする。
/// - 起動とスクロールは XCTest の metric（XCTApplicationLaunchMetric,
///   XCTOSSignpostMetric.scrollingAndDecelerationMetric）で測る。値は
///   xcodebuild のログの `measured [...]` 行に出る。
///
/// シミュレータ（Debug・-Onone）の値なので、実機の値ではなく画面どうしの
/// 比較に使う。手動の native-tests（route=standard,
/// test_filter=ScreenSpeedSweep）でだけ動かす。
final class ScreenSpeedSweepUITests: XCTestCase {
    private static let samples = 3

    override func setUpWithError() throws {
        // 測れなかった画面があっても、残りの画面は測り続ける。
        continueAfterFailure = true
        executionTimeAllowance = 900
    }

    // MARK: - 起動

    /// 起動の metric（最初のフレームまで）。中身入りの見本データで起動する。
    @MainActor
    func testSpeed01LaunchMetric() {
        let app = fixtureApp()
        let options = XCTMeasureOptions()
        options.iterationCount = Self.samples
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
        }
        app.terminate()
    }

    /// 起動から最初のタブの中身が出るまで（見本データ）と、見本なしの
    /// 本物のアプリの最初の画面が出るまで。
    @MainActor
    func testSpeed02LaunchToFirstContent() {
        let app = fixtureApp()
        app.launch()
        // 次の起動がアルバムから始まるようにしておく（最後に開いたタブが開く）。
        _ = tapTab(app, "main-tab-memories", "アルバム")
        _ = app.navigationBars["アルバム"].waitForExistence(timeout: 15)
        app.terminate()
        var values: [Double] = []
        for _ in 0..<Self.samples {
            let start = Date()
            app.launch()
            let ok = waitAny([app.buttons["album-prototype-past"], app.navigationBars["アルバム"]], timeout: 30)
            let ms = Date().timeIntervalSince(start) * 1000
            guard ok else { missing("起動→アルバム（見本）", app); break }
            values.append(ms)
            app.terminate()
        }
        report("起動→アルバム（見本）", "ms_to_content", values)

        // 見本なしの本物の起動。写真の許可がない初回はオンボーディングが最初の画面。
        let real = XCUIApplication()
        real.launchArguments = japanese
        values = []
        for _ in 0..<Self.samples {
            let start = Date()
            real.launch()
            let ok = waitAny([real.buttons["onboarding-purpose-start"], real.tabBars.firstMatch], timeout: 30)
            let ms = Date().timeIntervalSince(start) * 1000
            guard ok else { missing("起動→最初の画面（本物・見本なし）", real); break }
            values.append(ms)
            real.terminate()
        }
        report("起動→最初の画面（本物・見本なし）", "ms_to_content", values)
    }

    // MARK: - タブ

    @MainActor
    func testSpeed03TabSwitches() {
        let app = launchFixture()
        guard tapTab(app, "main-tab-memories", "アルバム") else { missing("タブ", app); return }
        _ = app.navigationBars["アルバム"].waitForExistence(timeout: 15)
        baseline(app, app.navigationBars["アルバム"])
        // タップ＋問い合わせの基準: いま選ばれているタブをもう一度タップする。
        var tapBase: [Double] = []
        for _ in 0..<Self.samples {
            let start = Date()
            guard tapTab(app, "main-tab-memories", "アルバム"),
                  app.buttons["album-prototype-past"].waitForExistence(timeout: 10) else { break }
            tapBase.append(Date().timeIntervalSince(start) * 1000)
        }
        report("基準（同じタブをタップ＋問い合わせ）", "ms_overhead", tapBase)
        let tabs: [(String, String, String, () -> [XCUIElement])] = [
            ("写真", "main-tab-photos", "写真", { [app.buttons["photos-section-all"]] }),
            ("まど", "main-tab-windows", "まど", { [app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "実家のまど")).firstMatch] }),
            ("この子", "main-tab-tools", "この子", { [app.buttons["tools-care-open"]] }),
            ("アルバム", "main-tab-memories", "アルバム", { [app.buttons["album-prototype-past"]] }),
        ]
        var first: [String: Double] = [:]
        var later: [String: [Double]] = [:]
        for round in 0..<Self.samples {
            for (name, identifier, label, target) in tabs {
                let start = Date()
                guard tapTab(app, identifier, label) else { missing("タブ:" + name, app); continue }
                let ok = waitAny(target(), timeout: 20)
                let ms = Date().timeIntervalSince(start) * 1000
                guard ok else { missing("タブ:" + name, app); continue }
                if round == 0 { first[name] = ms } else { later[name, default: []].append(ms) }
            }
        }
        for (name, _, _, _) in tabs {
            if let value = first[name] { report("タブ:" + name + "（初回）", "ms_to_content", [value]) }
            report("タブ:" + name + "（2回目以降）", "ms_to_content", later[name] ?? [])
        }
        app.terminate()
    }

    // MARK: - 画面を開く

    @MainActor
    func testSpeed04AlbumAndPhotoScreens() {
        let app = launchFixture()
        guard tapTab(app, "main-tab-memories", "アルバム") else { missing("アルバム", app); return }
        let past = app.buttons["album-prototype-past"]
        _ = past.waitForExistence(timeout: 15)
        baseline(app, past)
        let latest = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@", ["album-prototype-latest", "album-prototype-year"])).firstMatch
        timeOpen("月の作品", app, open: { latest.tap() },
                 until: [anyIdentifier(app, ["monthly-story", "monthly-book"])],
                 close: { self.closeTop(app) }, back: [past])

        guard tapTab(app, "main-tab-photos", "写真") else { missing("写真タブ", app); return }
        let all = app.buttons["photos-section-all"]
        if all.waitForExistence(timeout: 10), !all.isSelected { all.tap() }
        let firstPhoto = app.buttons["photo-hub-photo-app-store-screenshot-fixture-1"].firstMatch
        _ = firstPhoto.waitForExistence(timeout: 15)
        timeOpen("写真の画面（PhotoBrowserView）", app, open: { firstPhoto.tap() },
                 until: [app.buttons["photo-browser-related"], app.buttons["photo-memory-note-open"]],
                 close: { self.back(app) }, back: [firstPhoto])

        // 届ける画面: 写真の画面の「まどに届ける」から。
        firstPhoto.tap()
        let deliver = app.buttons["photo-browser-deliver-group"]
        if deliver.waitForExistence(timeout: 15) {
            timeOpen("届ける画面", app, open: { deliver.tap() },
                     until: [app.sheets.firstMatch, app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "実家のまど")).firstMatch,
                             app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS %@", "届")).firstMatch],
                     close: { self.closeTop(app) }, back: [deliver])
        } else {
            missing("届ける画面", app)
        }
        app.terminate()
    }

    @MainActor
    func testSpeed05WindowScreens() {
        let app = launchFixture()
        let room = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "実家のまど")).firstMatch
        timeOpen("まど一覧（タブ）", app, open: { _ = self.tapTab(app, "main-tab-windows", "まど") },
                 until: [room], close: nil, back: [])
        guard room.waitForExistence(timeout: 20) else { missing("1つのまど", app); return }
        timeOpen("1つのまど", app, open: { room.tap() },
                 until: [app.buttons["group-window-open-members"]],
                 close: { self.back(app) }, back: [room])
        app.terminate()
    }

    @MainActor
    func testSpeed06SettingsScreens() {
        let app = launchFixture()
        guard tapTab(app, "main-tab-tools", "この子") else { missing("設定", app); return }
        let gear = app.buttons["tools-settings-button"]
        _ = gear.waitForExistence(timeout: 15)
        timeOpen("設定", app, open: { gear.tap() }, until: [app.navigationBars["設定"]],
                 close: { self.closeTop(app) }, back: [gear])
        gear.tap()
        guard app.navigationBars["設定"].waitForExistence(timeout: 15) else { missing("設定の中", app); return }
        let autoSave = app.buttons["settings-managed-preservation"].firstMatch
        if autoSave.waitForExistence(timeout: 5) {
            timeOpen("自動保存", app, open: { autoSave.tap() },
                     until: [app.navigationBars["自動保存"], anyIdentifierPrefix(app, "app-record-")],
                     close: { self.back(app) }, back: [autoSave])
        } else {
            missing("自動保存", app)
        }
        let plus = anyIdentifier(app, ["settings-membership-offer", "settings-membership-preview"])
        if scrollToHittable(plus, app) {
            timeOpen("Plus 画面", app, open: { plus.tap() },
                     until: [app.staticTexts["membership-offer-heading"]],
                     close: { self.closeTop(app) }, back: [plus])
        } else {
            missing("Plus 画面", app)
        }
        app.terminate()
    }

    @MainActor
    func testSpeed07ToolScreens() {
        let app = launchFixture()
        guard tapTab(app, "main-tab-tools", "この子") else { missing("この子", app); return }
        let care = app.buttons["tools-care-open"]
        _ = care.waitForExistence(timeout: 15)
        let profile = app.buttons["tool-profile-11111111-1111-4111-8111-111111111111"]

        let showcase = app.buttons["tools-showcase-open"]
        timeOpen("写真を見せる", app, open: { self.safeTap(showcase, app) },
                 until: [anyIdentifierPrefix(app, "showcase-")],
                 close: { self.closeTop(app) }, back: [showcase])

        let tools: [(String, String, String, [String])] = [
            // 11/12: rows that open their pages; the first row stands for the page.
            ("病院で見せる", "tools-vet-open", "病院で見せる", ["vet-step-noticed"]),
            ("預けるとき", "tools-care-open", "預けるとき", ["care-row-photo", "care-preview-open"]),
            ("迷子のとき", "tools-lost-cat-open", "迷子のとき", ["lost-cat-row-photo", "lost-cat-row-guide"]),
        ]
        for (name, identifier, title, pageIdentifiers) in tools {
            let tile = app.buttons[identifier]
            guard scrollToHittable(tile, app) else { missing(name, app); continue }
            timeOpen(name + "（猫を選ぶ画面）", app, open: { self.safeTap(tile, app) },
                     until: [profile, app.navigationBars[title]],
                     close: { self.back(app) }, back: [tile])
            tile.tap()
            // 11/12: 病院で見せる, 預けるとき and 迷子のとき open a cat's page by
            // themselves (the cats are in the menu in the bar, not a row of
            // faces): time the tile to its rows.
            if ["tools-vet-open", "tools-care-open", "tools-lost-cat-open"].contains(identifier) {
                back(app)
                _ = tile.waitForExistence(timeout: 10)
                timeOpen(name + "（1匹のページ）", app, open: { self.safeTap(tile, app) },
                         until: [anyIdentifier(app, pageIdentifiers)],
                         close: { self.back(app) }, back: [tile])
                back(app)
                _ = tile.waitForExistence(timeout: 10)
                continue
            }
            guard profile.waitForExistence(timeout: 15) else { missing(name + "（1匹のページ）", app); continue }
            timeOpen(name + "（1匹のページ）", app, open: { profile.tap() },
                     until: [anyIdentifier(app, pageIdentifiers)],
                     close: { self.back(app) }, back: [profile])
            back(app)
            _ = tile.waitForExistence(timeout: 10)
        }

        let evacuation = app.buttons["tools-evacuation-open"]
        if scrollToHittable(evacuation, app) {
            let now = app.buttons["evacuation-now-open"]
            timeOpen("避難に備える", app, open: { evacuation.tap() },
                     until: [now, app.navigationBars["避難に備える"]],
                     close: { self.back(app) }, back: [evacuation])
            evacuation.tap()
            if now.waitForExistence(timeout: 15) {
                timeOpen("いま避難する", app, open: { now.tap() },
                         until: [app.navigationBars["いま避難する"]],
                         close: { self.back(app) }, back: [now])
            } else {
                missing("いま避難する", app)
            }
            back(app)
        } else {
            missing("避難に備える", app)
        }

        // この子のこと: この子 tab, the cat's page, its 「この子のこと」 card.
        let catChip = app.descendants(matching: .any)["tools-cat-11111111-1111-4111-8111-111111111111"].firstMatch
        app.swipeDown()
        chooseHomeCat(app, "11111111-1111-4111-8111-111111111111")
        if catChip.waitForExistence(timeout: 10) {
            timeOpen("この子のこと", app, open: { catChip.tap() },
                     until: [anyIdentifier(app, ["cat-care-part-basics", "cat-care-next-hint", "cat-care-family-notebook"])],
                     close: { self.back(app) }, back: [catChip])
        } else {
            missing("この子のこと", app)
        }
        app.terminate()
    }

    @MainActor
    func testSpeed08MemoScreens() {
        let app = memoApp()
        app.launch()
        let notes = app.buttons["photos-section-notes"]
        guard notes.waitForExistence(timeout: 20) else { missing("メモ一覧", app); return }
        let all = app.buttons["photos-section-all"]
        if notes.isSelected { all.tap() }
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory-note-row-")).firstMatch
        timeOpen("メモ一覧", app, open: { notes.tap() }, until: [row],
                 close: { all.tap() }, back: [all])
        notes.tap()
        guard row.waitForExistence(timeout: 15) else { missing("メモのページ", app); return }
        timeOpen("メモのページ", app, open: { row.tap() },
                 until: [app.staticTexts["memory-note-body"]],
                 close: { self.back(app) }, back: [row])
        app.terminate()
    }

    // MARK: - スクロール（hitch time ratio）

    @MainActor
    func testScroll01PhotoGrid() {
        let app = fixtureApp()
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "paging"
        app.launch()
        guard tapTab(app, "main-tab-photos", "写真") else { missing("スクロール:写真グリッド", app); return }
        let list = app.scrollViews["photo-library-all-scroll"]
        guard list.waitForExistence(timeout: 15) else { missing("スクロール:写真グリッド", app); return }
        measureScroll("写真グリッド（50枚）", list)
        app.terminate()
    }

    @MainActor
    func testScroll02Albums() {
        let app = launchFixture()
        guard tapTab(app, "main-tab-memories", "アルバム"),
              app.buttons["album-prototype-past"].waitForExistence(timeout: 15) else {
            missing("スクロール:アルバム", app); return
        }
        measureScroll("アルバム", app)
        app.terminate()
    }

    @MainActor
    func testScroll03MemoList() {
        let app = memoApp()
        app.launch()
        let notes = app.buttons["photos-section-notes"]
        guard notes.waitForExistence(timeout: 20) else { missing("スクロール:メモ一覧", app); return }
        if !notes.isSelected { notes.tap() }
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory-note-row-")).firstMatch
        guard row.waitForExistence(timeout: 15) else { missing("スクロール:メモ一覧", app); return }
        measureScroll("メモ一覧（24件）", app)
        app.terminate()
    }

    @MainActor
    func testScroll04Settings() {
        let app = launchFixture()
        guard tapTab(app, "main-tab-tools", "この子") else { missing("スクロール:設定", app); return }
        let gear = app.buttons["tools-settings-button"]
        guard gear.waitForExistence(timeout: 15) else { missing("スクロール:設定", app); return }
        gear.tap()
        guard app.navigationBars["設定"].waitForExistence(timeout: 15) else { missing("スクロール:設定", app); return }
        measureScroll("設定", app)
        app.terminate()
    }

    @MainActor func testScroll05ToolsHub() { scrollTool(name: "この子", tile: nil, profile: false, until: ["tools-care-open"]) }
    @MainActor func testScroll06ToolShowcase() { scrollTool(name: "写真を見せる", tile: "tools-showcase-open", profile: false, until: [], prefix: "showcase-") }
    @MainActor func testScroll07ToolVet() { scrollTool(name: "病院で見せる", tile: "tools-vet-open", profile: false, until: ["vet-step-noticed"]) }
    @MainActor func testScroll08ToolCare() { scrollTool(name: "預けるとき", tile: "tools-care-open", profile: false, until: ["care-row-photo", "care-preview-open"]) }
    @MainActor func testScroll09ToolLostCat() { scrollTool(name: "迷子のとき", tile: "tools-lost-cat-open", profile: false, until: ["lost-cat-row-photo", "lost-cat-row-guide"]) }
    @MainActor func testScroll10ToolEvacuation() { scrollTool(name: "避難に備える", tile: "tools-evacuation-open", profile: false, until: ["evacuation-now-open"]) }
    @MainActor func testScroll11ToolEvacuationNow() { scrollTool(name: "いま避難する", tile: "tools-evacuation-open", profile: false, until: ["evacuation-now-open"], then: "evacuation-now-open", thenTitle: "いま避難する") }

    @MainActor
    func testScroll12CatCare() {
        let app = launchFixture()
        guard tapTab(app, "main-tab-tools", "この子") else { missing("スクロール:この子のこと", app); return }
        chooseHomeCat(app, "11111111-1111-4111-8111-111111111111")
        let chip = app.descendants(matching: .any)["tools-cat-11111111-1111-4111-8111-111111111111"].firstMatch
        guard chip.waitForExistence(timeout: 15) else { missing("スクロール:この子のこと", app); return }
        chip.tap()
        guard anyIdentifier(app, ["cat-care-part-basics", "cat-care-next-hint", "cat-care-family-notebook"]).waitForExistence(timeout: 15) else {
            missing("スクロール:この子のこと", app); return
        }
        measureScroll("この子のこと", app)
        app.terminate()
    }

    // MARK: - 下ごしらえ

    private let japanese = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]

    /// 中身入りの見本: 写真・月の作品・みんなのまど・猫 2 匹と「この子のこと」。
    @MainActor
    private func fixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = japanese + ["--app-store-screenshot-fixture", "--app-store-screenshot-album",
                                          "--group-window-screens-fixture", "--app-store-screenshot-cat-care"]
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "tool-profiles"
        app.launchEnvironment["NEKO_PHOTO_UI_PREFERENCES_SUITE"] = "ScreenSpeedSweep.\(UUID().uuidString)"
        return app
    }

    @MainActor
    private func launchFixture() -> XCUIApplication {
        let app = fixtureApp()
        app.launch()
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 30)
        dismissSystemAlert()
        return app
    }

    /// メモ 24 件と写真 36 枚の見本（写真タブのメモ一覧）。
    @MainActor
    private func memoApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--photo-window-ui-fixture", "--memory-library-fixture", "--memory-library-scroll"] + japanese
        app.launchEnvironment["NEKO_PHOTO_UI_PREFERENCES_SUITE"] = "ScreenSpeedSweepMemo.\(UUID().uuidString)"
        app.launchEnvironment["NEKO_PHOTO_MEMORY_UI_SESSION"] = UUID().uuidString
        return app
    }

    /// The cat's page on この子, from the menu over the photo (the tools open
    /// for the page's cat). Leaves the page as it is when the menu is missing.
    @MainActor
    private func chooseHomeCat(_ app: XCUIApplication, _ identifier: String) {
        let menu = app.buttons["tools-cat-menu"]
        guard menu.waitForExistence(timeout: 10) else { return }
        // 11/13: the menu scrolls with the page; back to the top first.
        for _ in 0..<8 where !menu.isHittable { app.swipeDown() }
        menu.tap()
        let item = app.buttons["tools-cat-menu-" + identifier]
        guard item.waitForExistence(timeout: 5) else { return }
        item.tap()
        _ = item.waitForNonExistence(timeout: 5)
    }

    @MainActor
    private func scrollTool(name: String, tile: String?, profile: Bool, until: [String], prefix: String? = nil,
                            then: String? = nil, thenTitle: String? = nil) {
        let app = launchFixture()
        let label = "スクロール:" + name
        guard tapTab(app, "main-tab-tools", "この子") else { missing(label, app); return }
        _ = app.buttons["tools-care-open"].waitForExistence(timeout: 15)
        if let tile {
            let button = app.buttons[tile]
            guard scrollToHittable(button, app) else { missing(label, app); return }
            button.tap()
        }
        if profile {
            let cat = app.buttons["tool-profile-11111111-1111-4111-8111-111111111111"]
            guard cat.waitForExistence(timeout: 15) else { missing(label, app); return }
            cat.tap()
        }
        let target = prefix.map { anyIdentifierPrefix(app, $0) } ?? anyIdentifier(app, until)
        guard target.waitForExistence(timeout: 15) else { missing(label, app); return }
        if let then {
            app.buttons[then].tap()
            guard app.navigationBars[thenTitle ?? ""].waitForExistence(timeout: 15) else { missing(label, app); return }
        }
        measureScroll(name, app)
        app.terminate()
    }

    /// 1 回ずつ速く上へはじいて、止まるまでの hitch を測る（戻すのは測らない）。
    @MainActor
    private func measureScroll(_ name: String, _ element: XCUIElement) {
        print("SPEED|スクロール:\(name)|scroll_begin|-")
        let options = XCTMeasureOptions()
        options.iterationCount = Self.samples
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            element.swipeUp(velocity: .fast)
            stopMeasuring()
            element.swipeDown(velocity: .fast)
            element.swipeDown(velocity: .fast)
        }
        print("SPEED|スクロール:\(name)|scroll_end|-")
    }

    /// 開く操作の直前から目印が出るまでを 3 回。閉じられない画面は 1 回だけ。
    @MainActor
    private func timeOpen(_ screen: String, _ app: XCUIApplication, open: () -> Void, until targets: [XCUIElement],
                          close: (() -> Void)?, back: [XCUIElement]) {
        var values: [Double] = []
        for index in 0..<Self.samples {
            if index > 0 {
                guard let close else { break }
                close()
                guard back.isEmpty || waitAny(back, timeout: 15) else { print("SPEED|\(screen)|note|closed-not-returned"); break }
                // 戻る動きが落ち着いてから次を測る。
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            }
            let start = Date()
            open()
            let ok = waitAny(targets, timeout: 20)
            let ms = Date().timeIntervalSince(start) * 1000
            guard ok else { missing(screen, app); break }
            values.append(ms)
        }
        report(screen, "ms_to_content", values)
        if let close, !values.isEmpty {
            close()
            if !back.isEmpty { _ = waitAny(back, timeout: 15) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    /// XCUITest の問い合わせだけの時間（すでに出ている要素）。
    @MainActor
    private func baseline(_ app: XCUIApplication, _ element: XCUIElement) {
        var values: [Double] = []
        for _ in 0..<Self.samples {
            let start = Date()
            guard element.waitForExistence(timeout: 5) else { break }
            values.append(Date().timeIntervalSince(start) * 1000)
        }
        report("基準（問い合わせだけ）", "ms_overhead", values)
    }

    @MainActor
    private func waitAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for element in elements where element.exists { return true }
        } while Date() < deadline
        return false
    }

    @MainActor
    private func anyIdentifier(_ app: XCUIApplication, _ identifiers: [String]) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", identifiers)).firstMatch
    }

    @MainActor
    private func anyIdentifierPrefix(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    private func tapTab(_ app: XCUIApplication, _ identifier: String, _ label: String) -> Bool {
        let identified = app.buttons[identifier]
        if identified.waitForExistence(timeout: 10) { identified.tap(); return true }
        let labelled = app.tabBars.buttons[label]
        if labelled.waitForExistence(timeout: 5) { labelled.tap(); return true }
        return false
    }

    @MainActor
    private func safeTap(_ element: XCUIElement, _ app: XCUIApplication) {
        if element.exists, element.isHittable { element.tap(); return }
        if scrollToHittable(element, app) { element.tap() }
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.waitForExistence(timeout: 5) { button.tap() }
    }

    /// シート・全画面の「閉じる」、なければナビゲーションの戻る、なければ下へ払う。
    @MainActor
    private func closeTop(_ app: XCUIApplication) {
        let close = app.buttons["閉じる"].firstMatch
        if close.exists, close.isHittable { close.tap(); return }
        let done = app.buttons["完了"].firstMatch
        if done.exists, done.isHittable { done.tap(); return }
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists, backButton.isHittable { backButton.tap(); return }
        app.swipeDown(velocity: .fast)
    }

    @MainActor
    private func scrollToHittable(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
        if element.waitForExistence(timeout: 5), element.isHittable { return true }
        for _ in 0..<8 {
            app.swipeUp()
            if element.exists, element.isHittable { return true }
        }
        return false
    }

    @MainActor
    private func dismissSystemAlert() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        let deny = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "許可しない"])).firstMatch
        if deny.exists { deny.tap() }
    }

    // MARK: - 記録

    private func report(_ screen: String, _ metric: String, _ values: [Double]) {
        guard !values.isEmpty else { return }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let all = values.map { String(format: "%.0f", $0) }.joined(separator: ",")
        print("SPEED|\(screen)|\(metric)|\(String(format: "%.0f", median))|samples=\(all)")
    }

    /// 目印が出なかった画面。どこにいたかの手がかりを 1 行と添付で残す。
    @MainActor
    private func missing(_ screen: String, _ app: XCUIApplication) {
        let tree = app.debugDescription
        let pattern = try? NSRegularExpression(pattern: "identifier: '([^']+)'")
        let range = NSRange(tree.startIndex..., in: tree)
        let identifiers = (pattern?.matches(in: tree, range: range) ?? []).compactMap { match in
            Range(match.range(at: 1), in: tree).map { String(tree[$0]) }
        }
        var seen = Set<String>()
        let unique = identifiers.filter { seen.insert($0).inserted }.prefix(60)
        let bars = app.navigationBars.allElementsBoundByIndex.map(\.identifier)
        print("SPEED|\(screen)|missing|-|bars=\(bars.joined(separator: "/")) ids=\(unique.joined(separator: ","))")
        let attachment = XCTAttachment(string: tree)
        attachment.name = "speed-missing-" + screen
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
