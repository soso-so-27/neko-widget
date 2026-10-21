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
    func testReviewPublicPresentation() {
        let app = XCUIApplication()
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture", "--review-public-presentation"]
        app.launch()
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール"))
        app.buttons["tools-settings-button"].tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 10))
        app.swipeUp()
        XCTAssertFalse(app.buttons["settings-membership-preview"].exists)
        XCTAssertFalse(app.buttons["settings-window-support-preview"].exists)
        XCTAssertFalse(app.buttons["settings-internal-diagnostics"].exists)
        XCTAssertTrue(app.staticTexts["settings-app-version"].exists)
        captureScreenshot(named: "public-settings-no-internal-options")
        app.terminate()

        app.launch()
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-photos", fallbackLabel: "写真"))
        app.buttons["photos-section-favorites"].tap()
        let create = app.buttons["saved-memories-selection-toggle"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap()
        XCTAssertTrue(app.buttons["saved-memories-create-pdf"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["saved-memories-create-book-preview"].exists)
        captureScreenshot(named: "public-creation-pdf-only")
        app.terminate()

        // Internal DEBUG distribution still exposes its preview; sandbox is
        // deliberately not used as the discriminator in shipping code.
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        app.launch()
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール"))
        app.buttons["tools-settings-button"].tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 10))
        app.swipeUp()
        XCTAssertTrue(app.buttons["settings-membership-preview"].exists)
        app.terminate()
    }

    /// The 10/21 audit: group windows on the screen fixture, the tools that
    /// read 「この子のこと」, settings and albums. Steps that cannot be reached
    /// attach the screen and the hierarchy instead of stopping the run.
    @MainActor
    func testReviewAuditScreens() {
        executionTimeAllowance = 600
        continueAfterFailure = true
        let app = XCUIApplication()

        // 1. Photos that wait for the safety check, and a delivery to retry.
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture", "--group-window-screens-fixture",
                                                         "--group-window-screens-check-off", "--group-window-screens-failed-send"]
        app.launch()
        if tapTab(application: app, identifier: "main-tab-windows", fallbackLabel: "まど") {
            openGroupWindow(app)
            settle(3)
            captureScreenshot(named: "audit-01-waiting-and-failed-send")
        } else { auditMissing("windows-tab", app: app) }
        app.terminate()

        // 2. The list, a window, a photo, the members.
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture", "--group-window-screens-fixture"]
        app.launch()
        settle(2)
        captureScreenshot(named: "audit-02-albums-root")
        if tapTab(application: app, identifier: "main-tab-windows", fallbackLabel: "まど") {
            settle(2)
            captureScreenshot(named: "audit-03-window-list")
            openGroupWindow(app)
            let tile = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "届いた写真")).firstMatch
            if tile.waitForExistence(timeout: 20) {
                settle(2)
                captureScreenshot(named: "audit-04-window-photos")
                tile.tap()
                settle(2)
                captureScreenshot(named: "audit-05-photo-detail")
                app.swipeLeft()
                settle(1)
                captureScreenshot(named: "audit-06-photo-detail-next")
                app.swipeRight()
                settle(1)
                let favorite = app.buttons["group-photo-favorite"]
                if favorite.waitForExistence(timeout: 3) {
                    favorite.tap(); settle(1)
                    captureScreenshot(named: "audit-07-favorite-confirm")
                    let back = app.buttons["戻る"]
                    if back.exists { back.tap(); settle(1) }
                }
                let menu = app.buttons["group-photo-menu"]
                if menu.waitForExistence(timeout: 3) {
                    menu.tap(); settle(1)
                    captureScreenshot(named: "audit-08-photo-menu")
                    app.swipeDown(); settle(1)
                }
                let close = app.buttons["閉じる"].firstMatch
                if close.waitForExistence(timeout: 3) { close.tap(); settle(1) }
            } else { auditMissing("group-photos", app: app) }
            let members = app.buttons["group-window-open-members"]
            if members.waitForExistence(timeout: 5) {
                members.tap(); settle(2)
                captureScreenshot(named: "audit-09-members")
                app.swipeUp(); settle(1)
                captureScreenshot(named: "audit-10-members-lower")
            } else { auditMissing("members", app: app) }
        } else { auditMissing("windows-tab-2", app: app) }
        app.terminate()

        // 3. Tools with a cat profile: 預けるとき, 「この子のこと」, 病院, 避難, settings.
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "tool-profiles"
        let profileID = "tool-profile-11111111-1111-4111-8111-111111111111"

        app.launch()
        if openTool("tools-care-open", profile: profileID, app: app) {
            settle(2)
            captureScreenshot(named: "audit-11-care-top")
            app.swipeUp(); settle(1)
            captureScreenshot(named: "audit-12-care-cat-care")
            let edit = app.buttons["care-open-cat-care"]
            if scrollUpUntilHittable(edit, application: app) {
                edit.tap(); settle(2)
                captureScreenshot(named: "audit-13-cat-care-page")
                app.swipeUp(); settle(1)
                captureScreenshot(named: "audit-14-cat-care-page-lower")
                app.swipeUp(); settle(1)
                captureScreenshot(named: "audit-15-cat-care-page-bottom")
            } else { auditMissing("care-open-cat-care", app: app) }
        }
        app.terminate()

        app.launch()
        if openTool("tools-vet-open", profile: profileID, app: app) {
            settle(2)
            captureScreenshot(named: "audit-16-vet")
            app.swipeUp(); settle(1)
            captureScreenshot(named: "audit-17-vet-lower")
        }
        app.terminate()

        app.launch()
        if tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール") {
            let evacuation = app.buttons["tools-evacuation-open"]
            if scrollUpUntilHittable(evacuation, application: app) {
                evacuation.tap(); settle(2)
                captureScreenshot(named: "audit-18-evacuation")
                let cats = app.buttons["evacuation-cats-open"]
                if scrollUpUntilHittable(cats, application: app) {
                    cats.tap(); settle(2)
                    captureScreenshot(named: "audit-19-evacuation-cats")
                    let profile = app.buttons[profileID]
                    if profile.waitForExistence(timeout: 5) {
                        profile.tap(); settle(2)
                        captureScreenshot(named: "audit-20-evacuation-cat")
                        app.swipeUp(); settle(1)
                        captureScreenshot(named: "audit-21-evacuation-cat-lower")
                    }
                }
            } else { auditMissing("evacuation", app: app) }
        }
        app.terminate()

        app.launch()
        if tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール") {
            let settings = app.buttons["tools-settings-button"]
            if settings.waitForExistence(timeout: 5) {
                settings.tap(); settle(2)
                captureScreenshot(named: "audit-22-settings")
                app.swipeUp(); settle(1)
                captureScreenshot(named: "audit-23-settings-lower")
                app.swipeUp(); settle(1)
                captureScreenshot(named: "audit-24-settings-bottom")
            } else { auditMissing("settings", app: app) }
        }
        app.terminate()
    }

    /// Design review (10/21): every main screen, for looking at colour,
    /// wording, spacing and type. Nothing asserts; a missing step attaches
    /// the hierarchy and goes on. Each tool gets its own launch, so one
    /// screen that stays open cannot hide the next.
    @MainActor
    func testReviewDesignScreens() {
        executionTimeAllowance = 1500
        continueAfterFailure = true
        let app = XCUIApplication()
        let fixture = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        let group = fixture + ["--group-window-screens-fixture"]
        let profileID = "tool-profile-11111111-1111-4111-8111-111111111111"

        // 初回起動 (the shipping guide, no fixture)
        app.launchArguments = japaneseLaunchArguments
        app.launchEnvironment["NEKO_RESET_ONBOARDING_FOR_UI_TESTS"] = "1"
        app.launch(); settle(3)
        shot("design-01-onboarding-purpose")
        if tapID("onboarding-purpose-start", app) { settle(2); shot("design-02-onboarding-photos") }
        if tapID("onboarding-photo-permission-allow", app) { settle(3); shot("design-03-onboarding-after-allow") }
        else if tapID("onboarding-photo-permission-skip", app) { settle(2); shot("design-03-onboarding-after-skip") }
        settle(4); shot("design-04-onboarding-scan")
        if tapID("onboarding-scan-continue", app) || tapID("onboarding-scan-skip", app) { settle(2); shot("design-05-onboarding-after-scan") }
        if app.buttons["onboarding-plus-offer-skip"].waitForExistence(timeout: 3) { shot("design-06-onboarding-plus"); tapID("onboarding-plus-offer-skip", app); settle(2) }
        shot("design-07-after-onboarding")
        if tapID("widget-placement-skip", app) { settle(2); shot("design-08-after-widget-guide") }
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "NEKO_RESET_ONBOARDING_FOR_UI_TESTS")

        // 写真
        app.launchArguments = fixture
        app.launch(); settle(2)
        if tapTab(application: app, identifier: "main-tab-photos", fallbackLabel: "写真") {
            settle(3); shot("design-10-photos-all")
            app.swipeUp(); settle(1); shot("design-11-photos-all-lower")
            if tapID("photos-section-favorites", app) { settle(2); shot("design-12-photos-favorites") }
            tapID("photos-section-all", app); settle(2)
            if tapID("photo-hub-photo-app-store-screenshot-fixture-1", app) {
                settle(2); shot("design-13-photo-detail")
                app.swipeUp(); settle(1); shot("design-14-photo-detail-actions")
                if tapID("photo-browser-related", app) { settle(1); shot("design-15-photo-more-menu"); app.swipeDown(); settle(1) }
            }
        }
        app.terminate()

        // まど
        app.launchArguments = group
        app.launch(); settle(2)
        if tapTab(application: app, identifier: "main-tab-windows", fallbackLabel: "まど") {
            settle(2)
            if tapLabel("まどを作る", app) { settle(2); shot("design-20-create-window"); back(app) }
            if tapID("window-list-start", app) { settle(2); shot("design-21-official-windows"); back(app) }
        }
        app.terminate()

        // Plus の画面、表示しない人
        app.launchArguments = group
        app.launch(); settle(2)
        if openSettings(app) {
            if tapID("settings-group-hidden-members", app) { settle(2); shot("design-22-hidden-members"); backToSettings(app) }
            if tapID("settings-membership-preview", app) { settle(3); shot("design-23-plus-offer"); app.swipeUp(); settle(1); shot("design-24-plus-offer-lower") }
        }
        app.terminate()

        // ツール: 猫のプロフィール
        app.launchArguments = fixture
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "tool-profiles"
        app.launch(); settle(2)
        if tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール"), tapID("tools-cat-profiles", app) {
            settle(2)
            if tapLabel("ミケ", app) { settle(2); shot("design-30-cat-profile"); app.swipeUp(); settle(1); shot("design-31-cat-profile-lower"); app.swipeUp(); settle(1); shot("design-32-cat-profile-bottom") }
        }
        app.terminate()

        // ツール: 写真を見せる
        app.launch(); settle(2)
        if tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール"), tapID("tools-showcase-open", app) {
            settle(2); shot("design-33-showcase")
            if tapID("showcase-scope-picker", app) { settle(1); shot("design-34-showcase-scope"); app.swipeDown(); settle(1) }
        }
        app.terminate()

        // ツール: 迷子のとき
        app.launch(); settle(2)
        if tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール"), tapID("tools-lost-cat-open", app) {
            settle(2); shot("design-35-lost-cat-list")
            if tapID(profileID, app) || tapLabel("ミケ", app) { settle(2); shot("design-36-lost-cat"); app.swipeUp(); settle(1); shot("design-37-lost-cat-lower"); app.swipeUp(); settle(1); shot("design-38-lost-cat-bottom") }
        }
        app.terminate()

        // ツール: 預けるとき
        app.launch(); settle(2)
        if tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール"), tapID("tools-care-open", app) {
            settle(2); shot("design-39-care-list")
            if tapID(profileID, app) || tapLabel("ミケ", app) {
                settle(2)
                if tapLabel("渡す内容を選ぶ", app) { settle(2); shot("design-40-care-disclosure") }
            }
        }
        app.terminate()

        // ツール: 病院で見せる, 避難に備える
        app.launch(); settle(2)
        if tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール"), tapID("tools-vet-open", app) { settle(2); shot("design-41-vet-list") }
        app.terminate()
        app.launch(); settle(2)
        if tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール"), tapID("tools-evacuation-open", app) {
            settle(2)
            if tapID("evacuation-packing-open", app) { settle(2); shot("design-42-evacuation-packing"); app.swipeUp(); settle(1); shot("design-43-evacuation-packing-lower"); back(app) }
            if tapID("evacuation-destinations-open", app) { settle(2); shot("design-44-evacuation-destinations"); back(app) }
            if tapLabel("1冊のPDF", app) { settle(2); shot("design-45-evacuation-book") }
        }
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "NEKO_UX_RECOVERY_CASE")

        // 設定の中
        app.launchArguments = fixture
        app.launch(); settle(2)
        if openSettings(app) {
            for (identifier, name) in [("settings-widget-placement-guide", "design-50-widget-guide"),
                                       ("settings-personal-rediscovery", "design-51-rediscovery"),
                                       ("settings-cat-profile-transfer", "design-52-transfer"),
                                       ("settings-memory-note-export", "design-53-memo-export"),
                                       ("settings-personal-archive", "design-54-icloud"),
                                       ("settings-internal-diagnostics", "design-55-diagnostics")] {
                guard openSettings(app), tapID(identifier, app) else { continue }
                settle(2); shot(name)
                app.swipeUp(); settle(1); shot(name + "-lower")
                if identifier == "settings-widget-placement-guide" { closeSheet(app) } else { backToSettings(app) }
            }
        }
        app.terminate()

        // 大きな文字
        app.launchArguments = fixture + ["--ux-large-text"]
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "tool-profiles"
        app.launch(); settle(2)
        shot("design-60-large-albums")
        if tapTab(application: app, identifier: "main-tab-windows", fallbackLabel: "まど") { settle(2); shot("design-61-large-windows") }
        if tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール") {
            settle(1); shot("design-62-large-tools")
            if tapID("tools-care-open", app), tapID(profileID, app) || tapLabel("ミケ", app) { settle(2); shot("design-63-large-care"); app.swipeUp(); settle(1); shot("design-64-large-care-lower") }
        }
        app.terminate()
        app.launch(); settle(2)
        if openSettings(app) { shot("design-65-large-settings"); app.swipeUp(); settle(1); shot("design-66-large-settings-lower") }
        app.terminate()
    }

    /// 10/21 redesign (案 A〜J): the screens each proposal touches, by REVIEW_AREA.
    @MainActor
    func testReviewRedesignScreens() {
        executionTimeAllowance = 900
        continueAfterFailure = true
        let app = XCUIApplication()
        let fixture = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        let area = ProcessInfo.processInfo.environment["REVIEW_AREA"] ?? "onboarding"

        if area == "onboarding" {
            app.launchArguments = japaneseLaunchArguments
            app.launchEnvironment["NEKO_RESET_ONBOARDING_FOR_UI_TESTS"] = "1"
            app.launch(); settle(3)
            shot("re-01-purpose")
            if tapID("onboarding-purpose-start", app) { settle(2); shot("re-02-permission") }
            dismissSystemAlert(); settle(3); shot("re-03-after-dialog")
            settle(5); shot("re-04-scan")
            if tapID("initial-scan-widget-guide", app) { settle(2); shot("re-05-widget-guide"); tapID("widget-placement-skip", app); settle(2) }
            if app.buttons["onboarding-plus-offer-skip"].waitForExistence(timeout: 3) { shot("re-06-plus"); tapID("onboarding-plus-offer-skip", app); settle(2) }
            shot("re-07-after")
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "NEKO_RESET_ONBOARDING_FOR_UI_TESTS")

            // The scan page with the fixture's photos.
            app.launchArguments = fixture
            app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] = "three"
            app.launch(); settle(4)
            shot("re-08-scan-three")
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "NEKO_MAINLINE_ACCEPTANCE_CASE")
        }

        if area == "photos" {
            app.launchArguments = fixture + ["--group-window-screens-fixture"]
            app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "tool-profiles"
            app.launch(); settle(2)
            if tapTab(application: app, identifier: "main-tab-photos", fallbackLabel: "写真") {
                settle(3); shot("re-10-photos-all")
                if tapID("photos-section-favorites", app) {
                    settle(2); shot("re-11-favorites")
                    if tapID("favorites-origin-menu", app) { settle(1); shot("re-12-favorites-menu"); app.swipeDown(); settle(1) }
                }
                if tapID("photos-section-notes", app) { settle(2); shot("re-13-notes") }
                tapID("photos-section-all", app); settle(2)
                if tapID("photo-hub-photo-app-store-screenshot-fixture-1", app) {
                    settle(2); shot("re-14-photo-detail")
                    if tapID("photo-browser-related", app) { settle(1); shot("re-15-photo-menu"); app.swipeDown(); settle(1) }
                }
            }
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "NEKO_UX_RECOVERY_CASE")

            app.launchArguments = fixture
            app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] = "received-favorites"
            app.launch(); settle(3)
            shot("re-16-received-favorites")
            if tapID("favorites-origin-menu", app) { settle(1); shot("re-17-received-menu") }
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "NEKO_MAINLINE_ACCEPTANCE_CASE")
        }

        if area == "windows" {
            app.launchArguments = fixture + ["--group-window-screens-fixture"]
            app.launch(); settle(2)
            if tapTab(application: app, identifier: "main-tab-windows", fallbackLabel: "まど") {
                settle(3); shot("re-20-window-list")
                openGroupWindow(app); settle(3); shot("re-21-window")
                app.swipeUp(); settle(1); shot("re-22-window-lower")
                let tile = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "届いた写真")).firstMatch
                if tile.waitForExistence(timeout: 5) {
                    app.swipeDown(); settle(1)
                    tile.tap(); settle(2); shot("re-23-photo-detail")
                    if tapID("group-photo-heart", app) { settle(1); shot("re-24-photo-detail-hearted") }
                    closeSheet(app)
                }
                if tapID("group-window-open-members", app) { settle(2); shot("re-25-members"); app.swipeUp(); settle(1); shot("re-26-members-lower") }
            }
            app.terminate()
        }

        if area == "tools" {
            let profileID = "tool-profile-11111111-1111-4111-8111-111111111111"
            app.launchArguments = fixture
            app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "tool-profiles"
            app.launch(); settle(2)
            if tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール") {
                settle(2); shot("re-30-tools")
                if tapID("tools-cat-care", app) { settle(2); shot("re-31-cat-care"); back(app) }
            }
            app.terminate()
            app.launchArguments = fixture + ["--showcase-gallery-ui-fixture"]
            app.launch(); settle(2)
            if tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール"), tapID("tools-showcase-open", app) {
                settle(3); shot("re-32-best-nine")
            }
            app.terminate()
            app.launchArguments = fixture + ["--ux-large-text"]
            app.launch(); settle(2)
            if tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール") { settle(2); shot("re-33-tools-large") }
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "NEKO_UX_RECOVERY_CASE")
            _ = profileID
        }

        if area == "settings" {
            app.launchArguments = fixture + ["--group-window-screens-fixture"]
            app.launch(); settle(2)
            if openSettings(app) { shot("re-40-settings"); app.swipeUp(); settle(1); shot("re-41-settings-lower") }
            app.terminate()
        }
    }

    /// 10/21 review fixes: only the screens the fixes touch.
    @MainActor
    func testReviewFixScreens() {
        executionTimeAllowance = 900
        continueAfterFailure = true
        let app = XCUIApplication()
        let fixture = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        let group = fixture + ["--group-window-screens-fixture"]
        let profileID = "tool-profile-11111111-1111-4111-8111-111111111111"

        // 写真: heading row, favorites chips, detail with the deliver button, albums.
        app.launchArguments = group
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "tool-profiles"
        app.launch(); settle(2)
        if tapTab(application: app, identifier: "main-tab-photos", fallbackLabel: "写真") {
            settle(3); shot("fix-05-photos-all")
            if tapID("photos-cat-picker", app) { settle(1); shot("fix-05b-photos-cat-menu"); app.swipeDown(); settle(1) }
            if tapID("photos-section-favorites", app) { settle(2); shot("fix-06-photos-favorites") }
            tapID("photos-section-all", app); settle(2)
            if tapID("photo-hub-photo-app-store-screenshot-fixture-1", app) {
                settle(2); shot("fix-07-photo-detail")
                app.swipeUp(); settle(1); shot("fix-07b-photo-detail-lower")
            }
        }
        // The detail hides the tab bar: start the album screens from a fresh launch.
        app.terminate()
        app.launch(); settle(2)
        if tapTab(application: app, identifier: "main-tab-memories", fallbackLabel: "アルバム") {
            settle(2)
            if tapID("album-card-household_growth", app) || tapLabel("昔と最近", app) { settle(3); shot("fix-10-growth-album"); back(app) }
            if tapID("albums-years-toggle", app) { settle(2); shot("fix-11-dates") }
        }
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "NEKO_UX_RECOVERY_CASE")

        // まど: hearts with a count, members with a pending request, create.
        app.launchArguments = group
        app.launch(); settle(2)
        if tapTab(application: app, identifier: "main-tab-windows", fallbackLabel: "まど") {
            settle(2)
            if tapLabel("まどを作る", app) { settle(2); shot("fix-17-create-window"); back(app) }
            openGroupWindow(app); settle(3); shot("fix-13-window")
            if tapID("group-window-open-members", app) { settle(2); shot("fix-16-members") }
        }
        app.terminate()

        // まど: a delivery to retry.
        app.launchArguments = group + ["--group-window-screens-check-off", "--group-window-screens-failed-send"]
        app.launch(); settle(2)
        if tapTab(application: app, identifier: "main-tab-windows", fallbackLabel: "まど") {
            openGroupWindow(app); settle(3); shot("fix-15-failed-send")
        }
        app.terminate()

        // ツール: 猫のプロフィール, 預けるとき, 診察メモ.
        app.launchArguments = fixture
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "tool-profiles"
        app.launch(); settle(2)
        if tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール"), tapID("tools-cat-profiles", app) {
            settle(2)
            if tapLabel("ミケ", app) { settle(2); shot("fix-21-cat-profile"); app.swipeUp(); settle(1); shot("fix-22-cat-profile-lower") }
        }
        app.terminate()
        app.launch(); settle(2)
        if tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール"), tapID("tools-care-open", app) {
            settle(2); shot("fix-26-care-list")
            if tapID(profileID, app) || tapLabel("ミケ", app) {
                settle(2)
                if tapLabel("渡す内容を選ぶ", app) { settle(2); shot("fix-28-care-disclosure") }
            }
        }
        app.terminate()
        app.launch(); settle(2)
        if openTool("tools-vet-open", profile: profileID, app: app) { settle(2); shot("fix-31-vet-memo") }
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "NEKO_UX_RECOVERY_CASE")

        // 設定: the list, and 写真の表示と整理.
        app.launchArguments = group
        app.launch(); settle(2)
        if openSettings(app) {
            shot("fix-35-settings"); app.swipeUp(); settle(1); shot("fix-35b-settings-lower")
        }
        app.terminate()
        app.launch(); settle(2)
        if openSettings(app) {
            let photoRow = app.staticTexts["写真の表示と整理"].firstMatch
            if photoRow.waitForExistence(timeout: 4), scrollUpUntilHittable(photoRow, application: app) {
                photoRow.tap(); settle(2); shot("fix-37-photo-settings")
            } else { auditMissing("photo-settings-row", app: app) }
        }
        app.terminate()
    }

    /// The settings sheet opens from the ツール tab; re-opened when a step closed it.
    @MainActor @discardableResult
    private func openSettings(_ app: XCUIApplication) -> Bool {
        if app.navigationBars["設定"].exists { return true }
        guard tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール") else { return false }
        guard tapID("tools-settings-button", app) else { return false }
        return app.navigationBars["設定"].waitForExistence(timeout: 5)
    }

    @MainActor
    private func backToSettings(_ app: XCUIApplication) {
        if !app.navigationBars["設定"].exists { back(app) }
    }

    /// The simulator's own Photos prompt, in whatever language it shows.
    @MainActor
    private func dismissSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 1) else { return }
        for label in ["Allow Full Access", "すべての写真へのアクセスを許可", "フルアクセスを許可", "Allow Access to All Photos", "OK", "許可"] {
            let button = alert.buttons[label]
            if button.exists { button.tap(); return }
        }
        alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
    }

    @MainActor @discardableResult
    private func tapID(_ identifier: String, _ app: XCUIApplication) -> Bool {
        let element = app.buttons[identifier].exists ? app.buttons[identifier]
            : app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard element.waitForExistence(timeout: 4) else { auditMissing(identifier, app: app); return false }
        guard scrollUpUntilHittable(element, application: app) else { auditMissing(identifier + "-hittable", app: app); return false }
        element.tap()
        return true
    }

    @MainActor @discardableResult
    private func tapLabel(_ label: String, _ app: XCUIApplication) -> Bool {
        let element = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        guard element.waitForExistence(timeout: 4) else { auditMissing("label-" + label, app: app); return false }
        guard scrollUpUntilHittable(element, application: app) else { auditMissing("label-" + label + "-hittable", app: app); return false }
        element.tap()
        return true
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.exists, button.isHittable { button.tap(); settle(1) }
    }

    @MainActor
    private func closeSheet(_ app: XCUIApplication) {
        let close = app.buttons["閉じる"].firstMatch
        if close.exists, close.isHittable { close.tap(); settle(1) } else { app.swipeDown(); settle(1) }
    }

    @MainActor
    private func shot(_ name: String) { dismissSystemAlert(); captureScreenshot(named: name) }

    @MainActor
    private func openGroupWindow(_ app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "実家のまど")).firstMatch
        if row.waitForExistence(timeout: 15) { row.tap() } else { auditMissing("group-row", app: app) }
    }

    @MainActor
    private func openTool(_ identifier: String, profile: String, app: XCUIApplication) -> Bool {
        guard tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール") else {
            auditMissing("tools-tab", app: app); return false
        }
        let tool = app.buttons[identifier]
        guard tool.waitForExistence(timeout: 10), scrollUpUntilHittable(tool, application: app) else {
            auditMissing(identifier, app: app); return false
        }
        tool.tap()
        let cat = app.buttons[profile]
        guard cat.waitForExistence(timeout: 10) else { auditMissing(identifier + "-profile", app: app); return false }
        cat.tap()
        return true
    }

    private func settle(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func auditMissing(_ step: String, app: XCUIApplication) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "missing-" + step + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        captureScreenshot(named: "missing-" + step)
    }

    @MainActor
    func testReviewOctoberLayoutBatch() {
        executionTimeAllowance = 360
        // One simulator build for the four stacked feature PRs. Each check
        // retains its own two named screenshots and launches its own fixture.
        testReviewStartupTab()
        testReviewPersonalPhotoLayout()
        testReviewInvitationOnboarding()
        testReviewReceivedFavorites()
    }

    @MainActor
    func testReviewReceivedFavorites() {
        let app = XCUIApplication()
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] = "received-favorites"
        app.launch()
        // The origins live in one menu at the heading's right.
        let originMenu = app.buttons["favorites-origin-menu"]
        XCTAssertTrue(originMenu.waitForExistence(timeout: 15))
        captureScreenshot(named: "favorites-all-origins")
        originMenu.tap()
        XCTAssertTrue(app.buttons["favorites-origin-received"].waitForExistence(timeout: 5))
        app.buttons["favorites-origin-received"].tap()
        XCTAssertEqual(originMenu.label, "絞り込み、まどから届いた")
        XCTAssertTrue(app.staticTexts["お母さんから"].firstMatch.waitForExistence(timeout: 5))
        captureScreenshot(named: "favorites-from-mado")
        originMenu.tap()
        XCTAssertTrue(app.buttons["favorites-origin-ownCats"].waitForExistence(timeout: 5))
        app.buttons["favorites-origin-ownCats"].tap()
        XCTAssertEqual(originMenu.label, "絞り込み、自分の猫")
        // A received photo explicitly assigned to one's cat also belongs to
        // Own Cats, while retaining its true received provenance label.
        XCTAssertTrue(app.staticTexts["お母さんから"].firstMatch.exists)
        app.terminate()
    }

    @MainActor
    func testReviewInvitationOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] = "invite-entry"
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-purpose-join"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["onboarding-purpose-start"].label, "自分で始める")
        captureScreenshot(named: "onboarding-two-entries")
        app.buttons["onboarding-purpose-join"].tap()
        XCTAssertTrue(app.staticTexts["mainline-action-invitation"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.buttons["onboarding-purpose-start"].tap()
        // The fixture's Photos permission is already authorized, so self-start
        // enters scan results. Invitation entry above never requests Photos.
        XCTAssertTrue(app.buttons["initial-scan-continue"].waitForExistence(timeout: 10))
        captureScreenshot(named: "onboarding-self-start")
        app.terminate()
    }

    @MainActor
    func testReviewPersonalPhotoLayout() {
        let app = XCUIApplication()
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] = "review-photo-layout"
        app.launch()
        XCTAssertTrue(app.buttons["photo-browser-deliver"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["photo-browser-deliver"].label, "まどに届ける")
        captureScreenshot(named: "personal-photo-deliver")
        XCTAssertFalse(app.buttons["photo-memory-note-open"].exists)
        app.buttons["photo-browser-related"].tap()
        XCTAssertTrue(app.buttons["photo-memory-note-open"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["photo-browser-rediscovery-history"].exists)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "NEKO_MAINLINE_ACCEPTANCE_CASE")
        app.launch()
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-photos", fallbackLabel: "写真"))
        app.buttons["photos-cat-picker"].tap()
        let profiles = app.buttons["photos-cat-profiles"]
        XCTAssertTrue(profiles.waitForExistence(timeout: 5)); profiles.tap()
        XCTAssertTrue(app.navigationBars["猫のプロフィール"].waitForExistence(timeout: 10))
        captureScreenshot(named: "personal-cat-profiles")
        app.terminate()
    }

    @MainActor
    func testReviewStartupTab() {
        let app = XCUIApplication()
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        app.launch()
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール"))
        XCTAssertTrue(app.buttons["tools-care-open"].waitForExistence(timeout: 10))
        captureScreenshot(named: "startup-last-tools")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["tools-care-open"].waitForExistence(timeout: 15), app.debugDescription)
        captureScreenshot(named: "startup-restored-tools")
        app.terminate()
    }

    @MainActor
    func testReviewToolProfilesAndExistingData() {
        let app = XCUIApplication()
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        app.launchEnvironment["NEKO_TOOL_PROFILE_DATA_CHECK"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["tool-profile-data-passed"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.staticTexts["tool-profile-data-failed"].exists)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "NEKO_TOOL_PROFILE_DATA_CHECK")
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "tool-profiles"
        app.launch()
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール"))
        app.buttons["tools-care-open"].tap()
        let profile = app.buttons["tool-profile-11111111-1111-4111-8111-111111111111"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        captureScreenshot(named: "PR5-cat-picker")
        profile.tap()
        XCTAssertTrue(app.staticTexts["この子のこと"].waitForExistence(timeout: 10))
        captureScreenshot(named: "PR5-profile-in-tool")
        let edit = app.buttons["猫のプロフィールで編集"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.tap()
        let delete = app.buttons["プロフィールを削除"]
        XCTAssertTrue(scrollUpUntilHittable(delete, application: app)); delete.tap()
        let confirmation = app.alerts.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["プロフィールを削除"].tap()
        // The profile disappears but the tool's original record remains editable.
        let retainedName = app.descendants(matching: .any)["care-cat-name"].firstMatch
        XCTAssertTrue(retainedName.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(retainedName.value as? String, "ミケ")
        app.terminate()
    }

    @MainActor
    func testReviewToolsAndAutomaticVisitSave() {
        let app = XCUIApplication()
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        // The vet memo starts from a cat profile (the name prompt is gone).
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "tool-profiles"
        app.launch()
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "ツール"))
        for identifier in ["tools-showcase-open", "tools-care-open", "tools-vet-open", "tools-lost-cat-open", "tools-evacuation-open"] {
            XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 10))
        }
        captureScreenshot(named: "PR4-tools")
        app.buttons["tools-vet-open"].tap()
        let cat = app.buttons["tool-profile-11111111-1111-4111-8111-111111111111"]
        XCTAssertTrue(cat.waitForExistence(timeout: 10)); cat.tap()
        let observations = app.descendants(matching: .any)["vet-observations"].firstMatch
        XCTAssertTrue(observations.waitForExistence(timeout: 10), app.debugDescription)
        observations.tap(); observations.typeText("いつもの様子")
        let preview = app.buttons["vet-show"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        preview.tap()
        XCTAssertTrue(app.staticTexts["いつもの様子"].waitForExistence(timeout: 10))
        captureScreenshot(named: "PR4-visit-preview")
        app.terminate()
    }

    @MainActor
    func testReviewConsistentPhotosAndAlbums() {
        let app = XCUIApplication()
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["albums-settings-button"].waitForExistence(timeout: 20))
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permission.waitForExistence(timeout: 3) {
            let deny = permission.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "許可しない"])).firstMatch
            if deny.exists { deny.tap() }
        }
        captureScreenshot(named: "PR3-albums")
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-photos", fallbackLabel: "写真"))
        let picker = app.buttons["photos-cat-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["photos-section-all"].isSelected)
        captureScreenshot(named: "PR3-photos")
        picker.tap()
        XCTAssertTrue(app.buttons["すべての猫"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["すべての猫"].firstMatch.tap()
        app.buttons["photos-section-favorites"].tap()
        XCTAssertTrue(app.buttons["photos-section-favorites"].isSelected, app.debugDescription)
        XCTAssertTrue(app.buttons["saved-memories-selection-toggle"].waitForExistence(timeout: 10), app.debugDescription)
        app.terminate()
    }

    @MainActor
    func testReviewPhotoEntryAndAlbums() {
        let app = XCUIApplication()
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] = "review-first-photo"
        app.launch()
        let continueButton = app.buttons["initial-scan-continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 20))
        continueButton.tap()
        let close = app.buttons["first-run-photo-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        let all = app.buttons["photos-section-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        XCTAssertTrue(all.isSelected)
        app.buttons["photos-section-notes"].tap()
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-memories", fallbackLabel: "アルバム"))
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-photos", fallbackLabel: "写真"))
        XCTAssertTrue(all.isSelected)
        app.terminate()

        app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] = "solo-memories-monthly"
        app.launch()
        XCTAssertTrue(app.navigationBars["アルバム"].waitForExistence(timeout: 20))
        captureScreenshot(named: "PR2-albums")
        let month = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "2025年8月")).firstMatch
        XCTAssertTrue(month.waitForExistence(timeout: 10), app.debugDescription)
        app.terminate()
        app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] = "review-photo"
        app.launch()
        let menu = app.buttons["photo-browser-related"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        XCTAssertTrue(app.buttons["写真を書き出す"].waitForExistence(timeout: 5))
        captureScreenshot(named: "PR2-photo-menu")
        app.buttons["photo-browser-showcase-add"].tap()
        XCTAssertTrue(app.staticTexts["見せる写真に追加しました"].waitForExistence(timeout: 5))
        app.terminate()
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
              app.descendants(matching: .any)["albums-root"].waitForExistence(timeout: 10) else {
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

        guard tapTab(application: app, identifier: "main-tab-photos", fallbackLabel: "写真") else {
            fail("The Photos tab was not reachable from Albums.", application: app)
            return
        }
        let favorites = app.buttons["photos-section-favorites"]
        guard favorites.waitForExistence(timeout: 10), favorites.isHittable else {
            fail("The Favorites section was not reachable in Photos.", application: app)
            return
        }
        favorites.tap()
        guard app.descendants(matching: .any)["saved-memories-gallery"].waitForExistence(timeout: 10),
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
        guard app.buttons["photo-book-export"].waitForExistence(timeout: 10) else {
            fail("PDF creation was not available after photo selection opened.", application: app)
            return
        }
        XCTAssertFalse(app.buttons["photo-book-export"].isEnabled)
        XCTAssertTrue(app.staticTexts["0枚を選択"].exists)
        captureScreenshot(named: "review-favorites-selection")
        selectSavedPhotos.tap()
        guard app.navigationBars["写真"].waitForExistence(timeout: 10) else {
            fail("Canceling selection did not restore favorites browsing.", application: app)
            return
        }
        app.buttons["photos-section-all"].tap()
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
