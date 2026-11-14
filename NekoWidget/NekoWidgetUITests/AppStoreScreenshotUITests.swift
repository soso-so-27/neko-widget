import XCTest

/// Captures a Japanese, local-only App Store screenshot set without importing
/// Photos or signing in to any account. The product screens use the shipping
/// SwiftUI views with DEBUG-only, code-generated cat illustrations.
final class AppStoreScreenshotUITests: XCTestCase {
    @MainActor
    func testReviewClientUpgradeRequired() {
        let app = XCUIApplication()
        app.launchArguments = ["--client-upgrade-response-fixture", "-AppleLanguages", "(ja)"]
        app.launch()
        XCTAssertTrue(app.buttons["upgrade-fixture-settings"].waitForExistence(timeout: 10))
        app.buttons["upgrade-fixture-settings"].tap()
        XCTAssertTrue(app.buttons["upgrade-fixture-503"].waitForExistence(timeout: 5))
        app.buttons["upgrade-fixture-503"].tap()
        XCTAssertFalse(app.staticTexts["client-upgrade-message"].exists)
        XCTAssertTrue(app.staticTexts["通常のエラー"].exists)
        app.buttons["upgrade-fixture-426"].tap()
        let message = app.staticTexts["client-upgrade-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.label, "App Storeでアプリを最新にしてください。")
        XCTAssertFalse(app.links["client-upgrade-store"].exists)
        XCTAssertFalse(app.buttons["upgrade-fixture-426"].isHittable)
        captureScreenshot(named: "client-upgrade-required-over-settings")
        app.terminate()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    /// Normal public Release UI; simctl supplies synthetic Photos externally.
    @MainActor
    func testReviewPublicIPadCompatibility() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        func capture(_ name: String) {
            captureScreenshot(named: "ipad-public-" + name)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "ipad-public-" + name + "-hierarchy"
            tree.lifetime = .keepAlways
            add(tree)
        }
        func tap(_ identifier: String, timeout: TimeInterval = 10) -> Bool {
            let button = app.buttons[identifier].firstMatch
            guard button.waitForExistence(timeout: timeout), button.isHittable else {
                capture("unreachable-" + identifier)
                XCTFail("Public iPad control is not hittable: " + identifier)
                return false
            }
            button.tap()
            return true
        }
        guard app.buttons["onboarding-purpose-start"].waitForExistence(timeout: 30) else {
            capture("missing-onboarding"); XCTFail("Normal onboarding missing"); return
        }
        capture("01-onboarding")
        guard tap("onboarding-purpose-start") else { return }
        let photoPermission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard photoPermission.waitForExistence(timeout: 60) else {
            capture("missing-photo-permission"); XCTFail("Normal Photos permission prompt missing"); return
        }
        capture("02-photo-permission")
        let fullAccess = photoPermission.buttons.matching(NSPredicate(format: "label IN %@", [
            "Allow Full Access", "Allow Access to All Photos", "フルアクセスを許可", "すべての写真へのアクセスを許可"
        ])).firstMatch
        guard fullAccess.exists, fullAccess.isHittable else {
            capture("unreachable-photo-permission"); XCTFail("Full access action missing from Photos permission prompt"); return
        }
        fullAccess.tap()
        guard app.buttons["initial-scan-continue"].waitForExistence(timeout: 60) else {
            capture("scan-not-ready"); XCTFail("Normal scan screen missing"); return
        }
        capture("02-onboarding-scan")
        guard tap("initial-scan-continue") else { return }
        if app.buttons["onboarding-plus-offer-skip"].waitForExistence(timeout: 3) {
            guard tap("onboarding-plus-offer-skip") else { return }
        }
        guard tapTab(application: app, identifier: "main-tab-photos", fallbackLabel: "写真") else {
            capture("missing-photos"); XCTFail("Photos tab missing"); return
        }
        capture("03-photos")
        app.swipeUp()
        capture("04-photos-scrolled")
        guard tapTab(application: app, identifier: "main-tab-windows", fallbackLabel: "まど") else {
            capture("missing-windows"); XCTFail("Windows tab missing"); return
        }
        // This lane uses reserved .candidate.test URLs. Public URL validation
        // must reject them; reaching the unavailable screen is the contract.
        XCTAssertTrue(app.navigationBars["まど"].waitForExistence(timeout: 15))
        let unavailable = app.staticTexts.matching(identifier: "group-window-unavailable")
            .matching(NSPredicate(format: "label == %@", "みんなのまどを読み込めません")).firstMatch
        let unavailableVisible = unavailable.waitForExistence(timeout: 15)
        capture("05-windows-unavailable-synthetic-url")
        XCTAssertTrue(unavailableVisible, app.debugDescription)
        guard tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "この子") else {
            capture("missing-tools"); XCTFail("Tools tab missing"); return
        }
        guard tap("tools-settings-button") else { return }
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 10))
        capture("06-settings")
        let plus = app.buttons["settings-membership-offer"].firstMatch
        let plusEntryVisible = scrollUpUntilHittable(plus, application: app, maximumSwipes: 5)
        capture(plusEntryVisible ? "07-plus-entry" : "07-plus-entry-unavailable-synthetic-url")
        let plusObservation = XCTAttachment(string: "Public Plus entry hittable: \(plusEntryVisible). Synthetic .test billing URL is not a configured public billing service; Plus sheet is outside this walk-through.")
        plusObservation.name = "ipad-public-plus-entry-observation"
        plusObservation.lifetime = .keepAlways
        add(plusObservation)
        // Entry observation only: never use an internal preview or open StoreKit.
        app.swipeUp()
        capture("08-settings-bottom")
        XCTAssertFalse(app.buttons["settings-membership-preview"].exists)
        XCTAssertFalse(app.buttons["settings-internal-diagnostics"].exists)
        app.terminate()
    }

    @MainActor
    func testReviewPublicPresentation() {
        let app = XCUIApplication()
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture", "--review-public-presentation"]
        app.launch()
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "この子"))
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
        // Public favorites offer no PDF or book creation entry (10/31).
        XCTAssertTrue(app.descendants(matching: .any)["saved-memories-gallery"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["saved-memories-selection-toggle"].exists)
        captureScreenshot(named: "public-favorites-no-creation")
        app.terminate()

        // Internal DEBUG distribution still exposes its preview; sandbox is
        // deliberately not used as the discriminator in shipping code.
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        app.launch()
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "この子"))
        app.buttons["tools-settings-button"].tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 10))
        app.swipeUp()
        XCTAssertTrue(app.buttons["settings-membership-preview"].exists)
        // The Plus screen shows one of this person's cat photos, not a symbol.
        app.buttons["settings-membership-preview"].tap()
        XCTAssertTrue(app.staticTexts["membership-offer-heading"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["membership-offer-photo"].firstMatch.waitForExistence(timeout: 10),
                      app.debugDescription)
        XCTAssertTrue(waitForFixturePhotos(in: app, requirements: [(1, 1)]), app.debugDescription)
        captureScreenshot(named: "review-plus-with-cat-photo")
        app.terminate()
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
        // 11/14 (family journey A1): one button and one quiet line for
        // invited people; the line is not a button, their link opens the join
        // screen by itself.
        XCTAssertTrue(app.buttons["onboarding-purpose-start"].waitForExistence(timeout: 15))
        let invitationLine = app.staticTexts["onboarding-purpose-invitation-line"]
        if invitationLine.exists {
            XCTAssertEqual(invitationLine.label, "招待を受けた方は、届いたリンクをもう一度開いてください。")
        }
        XCTAssertFalse(app.buttons["onboarding-purpose-invitation-line"].exists)
        XCTAssertFalse(app.staticTexts["onboarding-purpose-join-hint"].exists)
        XCTAssertFalse(app.staticTexts["届いた招待リンクをタップしてください。"].exists)
        XCTAssertFalse(app.buttons["onboarding-purpose-join"].exists)
        // The one main button starts on one's own: 「猫を探す」 (OnboardingPresentationCopy.purposeAction,
        // pinned by ci/verify-onboarding-presentation.swift and the public guide page).
        XCTAssertEqual(app.buttons["onboarding-purpose-start"].label, "猫を探す")
        captureScreenshot(named: "onboarding-two-entries")
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
        // 「まどに届ける」 is the group まど's main action (10/31); the screen
        // fixture supplies a まど client so the button is shown as shipped.
        app.launchArguments = japaneseLaunchArguments
            + ["--app-store-screenshot-fixture", "--group-window-screens-fixture"]
        app.launchEnvironment["NEKO_MAINLINE_ACCEPTANCE_CASE"] = "review-photo-layout"
        app.launch()
        let deliver = app.buttons["photo-browser-deliver-group"]
        XCTAssertTrue(deliver.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(deliver.label, "まどに届ける")
        captureScreenshot(named: "personal-photo-deliver")
        // 10/21: お気に入り・メモ・共有 are under the photo; 「…」 holds the rest.
        XCTAssertTrue(app.buttons["photo-browser-memory-saved-state"].exists)
        XCTAssertTrue(app.buttons["photo-memory-note-open"].exists)
        app.buttons["photo-browser-related"].tap()
        XCTAssertTrue(app.buttons["photo-browser-same-day"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons["photo-browser-same-day"].label, "同じ日の猫写真")
        XCTAssertFalse(app.buttons["photo-browser-rediscovery-history"].exists)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "NEKO_MAINLINE_ACCEPTANCE_CASE")
        // The cat filter appears once there are cats to filter by.
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "cats"
        app.launch()
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-photos", fallbackLabel: "写真"))
        // The cat menu only filters since 10/31; profiles live in 設定.
        app.buttons["photos-cat-picker"].tap()
        XCTAssertTrue(app.buttons["すべての猫"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["photos-cat-profiles"].exists)
        captureScreenshot(named: "personal-cat-filter")
        app.terminate()
    }

    @MainActor
    func testReviewStartupTab() {
        // 11/8: a cold start opens the last tab the person tapped, except
        // ツール (a task, not a place to come back to), which opens アルバム.
        let app = XCUIApplication()
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture"]
        app.launch()
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-photos", fallbackLabel: "写真"))
        XCTAssertTrue(app.buttons["photos-section-all"].waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["photos-section-all"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.navigationBars["写真"].exists)
        captureScreenshot(named: "startup-restored-photos")
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "この子"))
        // 11/12 (この子): 避難 is on the page with or without a cat; 預ける
        // only once this fixture has one.
        XCTAssertTrue(app.buttons["tools-evacuation-open"].waitForExistence(timeout: 10))
        captureScreenshot(named: "startup-last-tools")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["アルバム"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["tools-care-open"].exists)
        XCTAssertFalse(app.buttons["photos-section-all"].exists)
        captureScreenshot(named: "startup-tools-opens-albums")
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
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "この子"))
        // 11/12 (この子): the cat is chosen on its page (11/14: by swiping;
        // the round menu shows only from five cats); the tool then opens for
        // it, without a cat menu of its own.
        chooseHomeCat("11111111-1111-4111-8111-111111111111", application: app)
        captureScreenshot(named: "PR5-cat-picker")
        let careButton = app.buttons["tools-care-open"]
        XCTAssertTrue(careButton.waitForExistence(timeout: 10), app.debugDescription); careButton.tap()
        XCTAssertTrue(app.buttons["care-preview-open"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["care-cat-menu"].exists, "Opened from the cat's page: no cat menu in the tool")
        // 「この子のこと」 is the row under the rows of this memo, so it can
        // start below the first screen of the memo.
        XCTAssertTrue(app.buttons["care-preview-open"].waitForExistence(timeout: 10), app.debugDescription)
        let catCareHeading = app.staticTexts["この子のこと"]
        XCTAssertTrue(scrollUpUntilHittable(catCareHeading, application: app)
                      || catCareHeading.waitForExistence(timeout: 10), app.debugDescription)
        captureScreenshot(named: "PR5-profile-in-tool")
        // 11/7: 「この子のこと」 opens the cat's one page (no 写真 tab); the profile
        // is deleted at the bottom of that same page. 349 (#886): in a tool the
        // section is one folded row, and that row itself opens the page.
        let edit = app.descendants(matching: .any)["care-cat-care-fields-folded"].firstMatch
        XCTAssertTrue(scrollUpUntilHittable(edit, application: app), app.debugDescription)
        XCTAssertTrue(edit.label.contains("この子のこと"), edit.label); edit.tap()
        // The name and the key photo lead the page; 11/12: the parts are
        // always open. Round 2: deleting is in 「…」 at the top right.
        XCTAssertTrue(app.buttons["cat-profile-rename"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["cat-profile-page-photos"].exists, "The cat's page has no 写真 tab")
        let more = app.buttons["cat-care-more-menu"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription); more.tap()
        let delete = app.buttons["cat-profile-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription); delete.tap()
        let confirmation = app.alerts.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["この子を削除"].tap()
        // The profile disappears but the tool's original record remains
        // editable: its name is the page of the row 「名前」 now.
        let nameRow = app.buttons["care-row-name"]
        XCTAssertTrue(nameRow.waitForExistence(timeout: 10), app.debugDescription)
        // The rows are at the top of the page; the folded row was below them.
        for _ in 0..<6 where !nameRow.isHittable { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(nameRow.isHittable, app.debugDescription)
        nameRow.tap()
        XCTAssertTrue(app.navigationBars["名前"].waitForExistence(timeout: 10), app.debugDescription)
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
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "この子"))
        for identifier in ["tools-showcase-open", "tools-care-open", "tools-vet-open", "tools-lost-cat-open", "tools-evacuation-open"] {
            XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 10))
        }
        captureScreenshot(named: "PR4-tools")
        // 11/12 (この子): with two cats, the cat is chosen on its page; the
        // memo opens for that cat with no cat menu in its bar.
        chooseHomeCat("11111111-1111-4111-8111-111111111111", application: app)
        app.buttons["tools-vet-open"].tap()
        XCTAssertTrue(app.buttons["vet-step-noticed"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["vet-cat-menu"].exists, "Opened from the cat's page: no cat menu in the tool")
        // 家で気付いたこと is a row that opens its own page with the field.
        let noticed = app.buttons["vet-step-noticed"]
        XCTAssertTrue(noticed.waitForExistence(timeout: 10), app.debugDescription)
        sleep(1)
        noticed.tap()
        let page = app.navigationBars["家で気付いたこと"]
        XCTAssertTrue(page.waitForExistence(timeout: 10), app.debugDescription)
        let observations = app.descendants(matching: .any)["vet-observations"].firstMatch
        XCTAssertTrue(observations.waitForExistence(timeout: 10), app.debugDescription)
        observations.tap(); observations.typeText("いつもの様子")
        // 11/8 (130f6436): a tool's page steps aside while the keyboard is up.
        // Close it as a person would, then go back: leaving saves, and the
        // bar's button shows whether the automatic save went through.
        let closeKeyboard = app.buttons["キーボードを閉じる"].firstMatch
        XCTAssertTrue(closeKeyboard.waitForExistence(timeout: 5), app.debugDescription); closeKeyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        page.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(page.waitForNonExistence(timeout: 5))
        XCTAssertTrue((noticed.label + " " + (noticed.value as? String ?? "")).contains("いつもの様子"), noticed.debugDescription)
        let preview = app.buttons["vet-show"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)
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
        // The cat filter appears once there are cats to filter by (11/7).
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "cats"
        app.launch()
        // UIKit can omit the tab item's identifier; wait for the tab bar itself.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permission.waitForExistence(timeout: 3) {
            let deny = permission.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "許可しない"])).firstMatch
            if deny.exists { deny.tap() }
        }
        // A cold start opens the last tab tapped (11/8): open アルバム for its shot.
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-memories", fallbackLabel: "アルバム"))
        XCTAssertTrue(app.navigationBars["アルバム"].waitForExistence(timeout: 10))
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
        // The section is kept once the pages come to rest (11/7 pager).
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"), object: app.buttons["photos-section-favorites"]
        )], timeout: 5), .completed, app.debugDescription)
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
        // 10/22: 「あとで」 enters the 写真 tab directly; no first photo opens.
        let all = app.buttons["photos-section-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["first-run-photo-close"].exists)
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
        XCTAssertTrue(app.buttons["同じ日の猫写真"].waitForExistence(timeout: 5))
        captureScreenshot(named: "PR2-photo-menu")
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
        // 11/10: page two is the windows and the Photos dialog; its own title
        // repeated page one and was removed.
        XCTAssertFalse(app.staticTexts["このiPhoneの中から、猫の写真と動画を見つけます。"].exists,
                       "The Photos permission page repeated page one's promise")
        // The privacy promise is said once, on page one (11/8).
        XCTAssertFalse(app.staticTexts["・写真や動画を、勝手にiPhoneの外へ送りません"].exists)

        captureScreenshot(named: "05-on-device-photo-privacy")
        app.terminate()
    }

    @MainActor
    func testCaptureVersion1ProductScreens() {
        captureFixtureProductScreens(publicPresentation: true)
    }

    @MainActor
    private func captureFixtureProductScreens(publicPresentation: Bool = false) {
        let app = XCUIApplication()
        app.launchArguments += japaneseLaunchArguments
        app.launchArguments.append("--app-store-screenshot-fixture")
        // The month that just finished arrived as a work on the shelf.
        app.launchArguments.append("--app-store-screenshot-album")
        if publicPresentation { app.launchArguments.append("--review-public-presentation") }
        app.launch()

        guard app.navigationBars["アルバム"].waitForExistence(timeout: 20),
              app.buttons["album-prototype-past"].waitForExistence(timeout: 10) else {
            fail("The Albums shelf did not appear first.", application: app)
            return
        }
        // The fixture starts without Photos access. If the system still asks, keep
        // the evidence and decline, so the App Store set never shows the prompt.
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permission.waitForExistence(timeout: 3) {
            let evidence = XCTAttachment(string: permission.debugDescription)
            evidence.name = "System prompt at fixture launch"
            evidence.lifetime = .keepAlways
            add(evidence)
            let deny = permission.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "許可しない"])).firstMatch
            if deny.exists { deny.tap() }
        }
        // The newest work: last month's cover, or this year's book from 12/6.
        let latestWork = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@", ["album-prototype-latest", "album-prototype-year"])
        ).firstMatch
        guard latestWork.waitForExistence(timeout: 10),
              waitForAnyFixturePhoto(in: app, numbers: Array(19...24)) else {
            fail("The newest work did not render its fixture cover.", application: app)
            return
        }
        captureScreenshot(named: "03-organized-memories")
        latestWork.tap()
        // The work opens as the book or the story, by the album's setting.
        let openedWork = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@", ["monthly-story", "monthly-book"])
        ).firstMatch
        guard openedWork.waitForExistence(timeout: 15),
              waitForAnyFixturePhoto(in: app, numbers: Array(19...24)) else {
            fail("The newest work did not open as a story.", application: app)
            return
        }
        captureScreenshot(named: "review-monthly-story")
        let closeStory = app.buttons["閉じる"].firstMatch
        guard closeStory.waitForExistence(timeout: 5) else {
            fail("The story has no close button.", application: app)
            return
        }
        closeStory.tap()
        guard app.buttons["album-prototype-past"].waitForExistence(timeout: 10) else {
            fail("The story did not return to Albums.", application: app)
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
        if publicPresentation {
            // 1.0 favorites are for browsing: no selection, PDF or book entry.
            XCTAssertFalse(selectSavedPhotos.exists, app.debugDescription)
        } else {
            guard selectSavedPhotos.waitForExistence(timeout: 10), waitForHittable(selectSavedPhotos) else {
                fail("The favorite-photo selection action was not reachable.", application: app)
                return
            }
        }
        XCTAssertFalse(app.buttons["photo-book-export"].exists)
        captureScreenshot(named: "04-liked-photos")
        if !publicPresentation {
            selectSavedPhotos.tap()
            // The PDF chooser is gone (10/31); test builds go straight to 本のイメージ.
            guard app.buttons["book-demand-preview"].waitForExistence(timeout: 10) else {
                fail("The book preview selection did not open from favorites.", application: app)
                return
            }
            XCTAssertFalse(app.buttons["book-demand-preview"].isEnabled)
            XCTAssertFalse(app.buttons["photo-book-export"].exists)
            XCTAssertTrue(app.staticTexts["0枚を選択"].exists)
            captureScreenshot(named: "review-favorites-selection")
            selectSavedPhotos.tap()
            guard app.navigationBars["写真"].waitForExistence(timeout: 10) else {
                fail("Canceling selection did not restore favorites browsing.", application: app)
                return
            }
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
        // Leave the Home Screen to the Widget capture that runs next.
        app.terminate()
    }

    /// 「この子のこと」 written in, with the family entry at the top right.
    @MainActor
    func testCaptureVersion1CatCareScreen() {
        let app = XCUIApplication()
        app.launchArguments = japaneseLaunchArguments
            + ["--app-store-screenshot-fixture", "--review-public-presentation", "--app-store-screenshot-cat-care"]
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "tool-profiles"
        app.launch()
        // The next capture starts on Albums: leave that tab selected even when
        // this test stops early.
        addTeardownBlock {
            MainActor.assumeIsolated {
                // 11/11: a tool hides the tab bar, so go back to ツール first.
                for _ in 0..<4 where !app.tabBars.firstMatch.isHittable {
                    let back = app.navigationBars.buttons.element(boundBy: 0)
                    guard back.exists else { break }
                    back.tap()
                }
                _ = self.tapTab(application: app, identifier: "main-tab-memories", fallbackLabel: "アルバム")
                app.terminate()
            }
        }
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "この子"), app.debugDescription)
        let care = app.buttons["tools-care-open"]
        XCTAssertTrue(care.waitForExistence(timeout: 10), app.debugDescription)
        chooseHomeCat("11111111-1111-4111-8111-111111111111", application: app)
        care.tap()
        chooseCareCat("tool-profile-11111111-1111-4111-8111-111111111111", application: app)
        // 「預けるとき」 opens first; its link to 「この子のこと」 is further down
        // the list, which makes the row only once it scrolls near. 349: it is
        // one row below the steps, and a tap opens the cat's page.
        let folded = app.descendants(matching: .any)["care-cat-care-fields-folded"].firstMatch
        XCTAssertTrue(scrollUpUntilHittable(folded, application: app), app.debugDescription)
        folded.tap()
        XCTAssertTrue(app.buttons["cat-care-family-notebook"].waitForExistence(timeout: 10), app.debugDescription)
        // 11/12: the four parts are always open, each a list of rows that
        // show what is written (接し方・ごはん・トイレ in 暮らし).
        // 「見分ける写真」 sits above the parts, so 暮らし can start below the
        // first screen; the list makes its rows only near view.
        // 接し方 is the last row of 暮らし; bring it up so the shot shows what was written.
        let temperamentText = "抱っこは少し苦手。名前を呼ぶと来ます。"
        let temperament = app.descendants(matching: .any)["cat-care-temperament-row"].firstMatch
        XCTAssertTrue(scrollUpUntilHittable(temperament, application: app), app.debugDescription)
        XCTAssertTrue(temperament.label.contains(temperamentText)
                      || (temperament.value as? String)?.contains(temperamentText) == true
                      || app.staticTexts[temperamentText].exists,
                      temperament.debugDescription)
        sleep(1)
        captureScreenshot(named: "09-cat-care")
    }

    /// App Store candidates for the window screens: the まど tab and one
    /// みんなのまど, on the in-memory screen fixture (no relay, key or account).
    @MainActor
    func testReviewAppStoreWindowScreens() {
        captureWindowScreens(publicPresentation: false)
    }

    @MainActor
    func testCaptureVersion1WindowScreens() {
        captureWindowScreens(publicPresentation: true)
    }

    @MainActor
    private func captureWindowScreens(publicPresentation: Bool) {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments = japaneseLaunchArguments
            + ["--app-store-screenshot-fixture", "--group-window-screens-fixture"]
        if publicPresentation { app.launchArguments += ["--review-public-presentation", "--app-store-screenshot-nowa"] }
        app.launch()
        if publicPresentation {
            let tabs = app.tabBars.buttons
            XCTAssertEqual(tabs.count, 4, app.debugDescription)
            for label in ["写真", "まど", "アルバム", "この子"] {
                XCTAssertTrue(tabs[label].exists, "Missing tab: " + label)
            }
        }
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-windows", fallbackLabel: "まど"), app.debugDescription)
        let room = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "実家のまど")).firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 20), app.debugDescription)
        room.tap()
        XCTAssertTrue(app.buttons["group-window-open-members"].waitForExistence(timeout: 15), app.debugDescription)
        // Let the fixture's photos draw before the capture.
        _ = app.images.firstMatch.waitForExistence(timeout: 10)
        sleep(2)
        captureScreenshot(named: "07-group-window")
        // Back on the tab, the card shows the newest photo this iPhone received.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(room.waitForExistence(timeout: 10), app.debugDescription)
        sleep(2)
        captureScreenshot(named: "06-windows-tab")
        if publicPresentation {
            // のわのまど, received: today's のわ and its line.
            let nowa = app.buttons["public-window-entry-black-cats"]
            XCTAssertTrue(nowa.waitForExistence(timeout: 10), app.debugDescription)
            nowa.tap()
            XCTAssertTrue(app.buttons["official-window-photo-app-store-nowa"].waitForExistence(timeout: 15),
                          app.debugDescription)
            sleep(2)
            captureScreenshot(named: "08-nowa-window")
        }
        app.terminate()
    }

    private var japaneseLaunchArguments: [String] {
        [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
        ]
    }

    @MainActor
    private func launchOwnerCapture(_ screen: String) throws -> XCUIApplication {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["NEKO_PRIVATE_CAPTURE_ROOT"])
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments = japaneseLaunchArguments + ["--app-store-screenshot-fixture",
            "--review-public-presentation", "--owner-store-capture", "--tools-hub-light",
            "--app-store-screenshot-album", "--app-store-screenshot-cat-care", "--group-window-screens-fixture"]
        app.launchEnvironment["NEKO_PRIVATE_CAPTURE_ROOT"] = root
        app.launchEnvironment["NEKO_CAPTURE_SCREEN"] = screen
        app.launchEnvironment["NEKO_UX_RECOVERY_CASE"] = "tool-profiles"
        app.launch()
        return app
    }

    @MainActor
    func testCaptureOwnerStoreAppScreens() throws {
        let app = try launchOwnerCapture("photos")
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-photos", fallbackLabel: "写真"))
        app.buttons["photos-section-all"].tap()
        XCTAssertTrue(waitForFixturePhotos(in: app, requirements: [(1, 1), (2, 1), (3, 1)]))
        captureScreenshot(named: "02_photos")
        app.terminate()
    }

    @MainActor
    func testCaptureOwnerStoreWindow() throws {
        let app = try launchOwnerCapture("window")
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-windows", fallbackLabel: "まど"))
        let room = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "わが家")).firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 15)); room.tap()
        XCTAssertTrue(app.buttons["group-window-open-members"].waitForExistence(timeout: 15))
        let delivered = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "から届いた写真")).firstMatch
        XCTAssertTrue(delivered.waitForExistence(timeout: 15)); delivered.tap()
        XCTAssertTrue(app.staticTexts["ふたりでくっついて寝ていた"].waitForExistence(timeout: 15))
        sleep(2)
        captureScreenshot(named: "03_window")
        app.terminate()
    }

    @MainActor
    func testCaptureOwnerStoreTools() throws {
        let app = try launchOwnerCapture("tools")
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "この子"))
        for identifier in ["tools-showcase-open", "tools-care-open", "tools-vet-open", "tools-lost-cat-open", "tools-evacuation-open"] {
            XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 10))
        }
        sleep(1)
        captureScreenshot(named: "07_tools")
        app.terminate()
    }

    @MainActor
    func testCaptureOwnerStoreShowcase() throws {
        let app = try launchOwnerCapture("showcase")
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "この子"))
        app.buttons["tools-showcase-open"].tap()
        XCTAssertTrue(app.buttons["showcase-slideshow-open"].waitForExistence(timeout: 15))
        if app.buttons["showcase-gallery-scope"].exists {
            app.buttons["showcase-gallery-scope"].tap()
            let all = app.buttons["すべての猫"]
            XCTAssertTrue(all.waitForExistence(timeout: 5)); all.tap()
        }
        XCTAssertEqual(app.buttons.matching(identifier: "showcase-gallery-photo").count, 9)
        sleep(1)
        captureScreenshot(named: "04_showcase")
        app.terminate()
    }

    @MainActor
    func testCaptureOwnerStoreAlbum() throws {
        let app = try launchOwnerCapture("album")
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-memories", fallbackLabel: "アルバム"))
        let latest = app.buttons["album-prototype-latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForAnyFixturePhoto(in: app, numbers: Array(19...24)))
        captureScreenshot(named: "supplement_album_shelf")
        latest.tap()
        XCTAssertTrue(app.descendants(matching: .any)["monthly-book"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitForAnyFixturePhoto(in: app, numbers: Array(19...24)))
        app.swipeLeft()
        sleep(2)
        captureScreenshot(named: "05_album")
        app.terminate()
    }

    @MainActor
    func testCaptureOwnerStoreCare() throws {
        let app = try launchOwnerCapture("care")
        XCTAssertTrue(tapTab(application: app, identifier: "main-tab-tools", fallbackLabel: "この子"))
        chooseHomeCat("11111111-1111-4111-8111-111111111111", application: app)
        app.buttons["tools-care-open"].tap()
        chooseCareCat("tool-profile-11111111-1111-4111-8111-111111111111", application: app)
        let folded = app.descendants(matching: .any)["care-cat-care-fields-folded"].firstMatch
        XCTAssertTrue(scrollUpUntilHittable(folded, application: app)); folded.tap()
        XCTAssertTrue(app.buttons["cat-care-family-notebook"].waitForExistence(timeout: 10))
        // 11/12: the parts are always open; the hospital's row shows its name.
        let vet = app.descendants(matching: .any)["cat-care-vet-name-row"].firstMatch
        XCTAssertTrue(scrollUpUntilHittable(vet, application: app))
        sleep(1)
        captureScreenshot(named: "06_cat_care")
        app.terminate()
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

    /// 11/14: a cat's page on この子 is reached by swiping (the round cat
    /// menu shows only from five cats). The cat's 「この子のこと」 row is found
    /// only on the page on screen. Swipes toward the add page first, then
    /// back; at most 13 pages each way.
    /// The tools opened from the page open for that cat.
    @MainActor
    private func chooseHomeCat(_ identifier: String, application app: XCUIApplication) {
        XCTAssertTrue(swipeToHomeCat(app, identifier), app.debugDescription)
    }

    @MainActor
    private func swipeToHomeCat(_ app: XCUIApplication, _ identifier: String) -> Bool {
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", ["tools-cat-" + identifier, "tools-family-cat-" + identifier])).firstMatch
        _ = app.descendants(matching: .any)["cat-home-hero"].firstMatch.waitForExistence(timeout: 10)
        if row.waitForExistence(timeout: 2) { return true }
        let add = app.buttons["cat-home-add"]
        for _ in 0..<13 where !add.exists {
            app.swipeLeft()
            if row.waitForExistence(timeout: 2) { return true }
        }
        for _ in 0..<13 {
            app.swipeRight()
            if row.waitForExistence(timeout: 2) { return true }
        }
        return false
    }

    /// 11/12: 預けるとき's cats are the items of the menu in the bar. The tool
    /// opens a cat's page by itself; with one cat there is no menu, and that
    /// cat's page is the one open. Opened from a cat's page on この子 there is
    /// no menu either: the page chose the cat.
    @MainActor
    private func chooseCareCat(_ identifier: String, application app: XCUIApplication) {
        XCTAssertTrue(app.buttons["care-preview-open"].waitForExistence(timeout: 10), app.debugDescription)
        let menu = app.buttons["care-cat-menu"]
        guard menu.exists else { return }
        menu.tap()
        let item = app.buttons[identifier]
        XCTAssertTrue(item.waitForExistence(timeout: 10), app.debugDescription)
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5), app.debugDescription)
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

    /// Any one of the given fixture photos has published its loaded state.
    @MainActor
    private func waitForAnyFixturePhoto(in application: XCUIApplication, numbers: [Int]) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            let loaded = numbers.contains { number in
                application.descendants(matching: .any)
                    .matching(identifier: "app-store-screenshot-fixture-photo-loaded-app-store-screenshot-fixture-\(number)")
                    .count >= 1
            }
            if loaded {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
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
        // A failure must not leave this app over the Home Screen for the Widget capture.
        application.terminate()
    }
}
