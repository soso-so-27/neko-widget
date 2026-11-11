from pathlib import Path
import plistlib
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(value: str, start: str, end: str) -> str:
    start_index = value.index(start)
    end_index = value.index(end, start_index)
    return value[start_index:end_index]


class PlusPurchaseFoundationTests(unittest.TestCase):
    def test_offer_keeps_preview_separate_and_uses_authoritative_products(self) -> None:
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        preview = section(model, "static func preview(", "private final class MembershipStoreKitClient")
        self.assertNotIn("PlusPurchaseStore(", preview)
        self.assertNotIn("PlusBillingSession", preview)
        live = section(model, "private final class MembershipStoreKitClient", "struct MembershipOfferSheet")
        self.assertIn("product.displayPrice", live)
        self.assertIn("subscription.isEligibleForIntroOffer", live)
        self.assertIn("introductory.paymentMode == .freeTrial", live)
        self.assertIn("subscription.subscriptionPeriod.value == 1", live)
        self.assertNotIn("980", live)
        self.assertNotIn("7日", live)
        self.assertIn("case .pending, .awaitingServerConfirmation: return .waiting", live)
        # A completed purchase closes the sheet without a completion page.
        self.assertIn("if result == .completed || (model.isPreview && result == .cancelled)", model)
        self.assertIn("init(model: MembershipOfferModel, context: PlusOfferContext", model)
        self.assertNotIn("検討中", model)
        self.assertIn("onClose: { onFinish(model.isMember ? .completed : .cancelled) }", model)
        self.assertIn("!isWorking && !isWaiting", model)

    def setUp(self) -> None:
        self.store = source("NekoWidget/Services/PlusPurchaseStore.swift")
        self.billing_core = source("NekoWidget/Services/BillingClientCore.swift")

    def test_source_configuration_is_explicitly_disabled_and_unconfigured(self) -> None:
        config = source("Config.xcconfig")
        self.assertRegex(config, r"(?m)^PLUS_STOREFRONT_ENABLED = NO$")
        self.assertRegex(config, r"(?m)^PLUS_MONTHLY_PRODUCT_ID =$")
        self.assertRegex(config, r"(?m)^PLUS_ANNUAL_PRODUCT_ID =$")
        self.assertRegex(config, r"(?m)^PLUS_BILLING_API_BASE_URL =$")
        # ADR-027: the membership gate is one xcconfig variable read by both the
        # App and the Widget Info.plist, and it stays off in source.
        self.assertRegex(config, r"(?m)^MEMBERSHIP_ACCESS_ENFORCED = NO$")
        for relative in ("NekoWidget/Info.plist", "NekoWidgetWidget/Info.plist"):
            with (ROOT / relative).open("rb") as handle:
                self.assertEqual(
                    plistlib.load(handle)["MembershipAccessEnforced"],
                    "$(MEMBERSHIP_ACCESS_ENFORCED)",
                    relative,
                )
        for relative in (
            "NekoWidget/Services/MembershipAccessContext.swift",
            "Shared/PersonalWidgetMembershipStore.swift",
        ):
            self.assertIn(
                'MembershipAccessFlag.isOn(Bundle.main.object(forInfoDictionaryKey: "MembershipAccessEnforced"))',
                source(relative),
                relative,
            )

        with (ROOT / "NekoWidget/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(info["PlusStorefrontEnabled"], "$(PLUS_STOREFRONT_ENABLED)")
        self.assertEqual(info["PlusMonthlyProductID"], "$(PLUS_MONTHLY_PRODUCT_ID)")
        self.assertEqual(info["PlusAnnualProductID"], "$(PLUS_ANNUAL_PRODUCT_ID)")
        self.assertEqual(
            info["PlusBillingAPIBaseURL"],
            "$(PLUS_BILLING_API_BASE_URL)",
        )

        self.assertIn("guard configuration.isEnabled else", self.store)
        self.assertIn("guard configuration.isConfigured else", self.store)
        self.assertIn('!value.contains("$(")', self.store)
        self.assertIn("monthlyProductID != annualProductID", self.store)

    def test_storekit_observation_and_explicit_restore_contract(self) -> None:
        self.assertIn("Product.products(for: configuration.productIDs)", self.store)
        self.assertIn("Transaction.currentEntitlements", self.store)
        self.assertIn("Transaction.updates", self.store)
        self.assertIn("Task { @MainActor [weak self] in", self.store)
        self.assertIn("func refreshAfterForegroundEntry() async", self.store)
        self.assertEqual(self.store.count("try await AppStore.sync()"), 1)

        restore = section(
            self.store,
            "func restorePurchases() async",
            "private func loadProducts() async",
        )
        self.assertIn("try await AppStore.sync()", restore)
        self.assertGreaterEqual(restore.count("refreshServerAuthority()"), 1)
        start = section(
            self.store,
            "func start() async",
            "func stop()",
        )
        self.assertNotIn("AppStore.sync", start)

    def test_purchase_requires_billing_identity_and_server_confirmation(self) -> None:
        purchase = section(
            self.store,
            "func purchase(",
            "func restorePurchases() async",
        )
        self.assertIn("billingAccountID: BillingAccountID", purchase)
        self.assertIn("recordVerifiedTransactionEvent != nil", purchase)
        self.assertIn("fetchAuthoritativeEntitlement != nil", purchase)
        self.assertIn(".appAccountToken(billingAccountID.rawValue)", purchase)
        self.assertIn("verification.jwsRepresentation", purchase)
        self.assertLess(
            purchase.index("recordVerifiedTransactionEvent != nil"),
            purchase.index("product.purchase(options:"),
        )
        self.assertLess(
            purchase.index("try await recordVerifiedTransactionEvent("),
            purchase.index("await transaction.finish()"),
        )
        self.assertLess(
            purchase.index("await transaction.finish()"),
            purchase.index("await refreshServerAuthority()"),
        )
        failure = section(
            purchase,
            "} catch {",
            "return .awaitingServerConfirmation",
        )
        self.assertIn("markServerConfirmationIndeterminate()", failure)
        self.assertNotIn("finish()", failure)
        confirmed = section(
            purchase,
            "switch await refreshServerAuthority()",
            "} catch {",
        )
        self.assertIn("case .confirmed:", confirmed)
        self.assertIn("return .purchased", confirmed)
        self.assertIn("return .awaitingServerConfirmation", purchase)

    def test_updates_record_all_configured_verified_changes_before_finish(self) -> None:
        updates = section(
            self.store,
            "private func handleTransactionUpdate(",
            "private func reconcileCurrentEntitlements() async",
        )
        self.assertIn("configuration.plan(for: transaction.productID)", updates)
        self.assertIn("result.jwsRepresentation", updates)
        self.assertLess(
            updates.index("try await recordVerifiedTransactionEvent("),
            updates.index("await transaction.finish()"),
        )

    def test_empty_or_unrelated_reconciliation_cannot_release_pending_purchase(self) -> None:
        reconcile = section(
            self.store,
            "private func reconcileCurrentEntitlements() async",
            "private func refreshServerAuthority() async",
        )
        guard = "if pendingProductID == transaction.productID {"
        self.assertEqual(reconcile.count("pendingProductID = nil"), 1)
        self.assertIn(guard, reconcile)
        acknowledged = reconcile.index("try await recordVerifiedTransactionEvent(")
        finished = reconcile.index("await transaction.finish()")
        matching = reconcile.index(guard)
        cleared = reconcile.index("pendingProductID = nil")
        loop_end = reconcile.index("if scan.events.isEmpty, pendingProductID == nil,")
        self.assertLess(acknowledged, finished)
        self.assertLess(finished, matching)
        self.assertLess(matching, cleared)
        # Both the matching guard and event loop must end before the authority
        # fetch. A reset at loop scope would admit a second pending purchase.
        self.assertRegex(reconcile[cleared:loop_end], r"pendingProductID = nil\s*}\s*}\s*$")
        failure = reconcile[reconcile.index("} catch {"):]
        self.assertNotIn("pendingProductID = nil", failure)

    def test_entitlement_is_server_confirmed_and_family_sharing_is_not_granted(self) -> None:
        self.assertIn("case serverConfirmed(PlusVerifiedEntitlement)", self.store)
        self.assertIn("case indeterminate(lastServerConfirmed:", self.store)
        self.assertNotIn("case active", self.store)
        self.assertIn(
            ") async throws -> BillingTransactionRecordAcknowledgement",
            self.store,
        )
        self.assertIn("acknowledgement.billingAccountID == billingAccountID", self.store)
        self.assertIn("acknowledgement.transactionID == String(transaction.id)", self.store)
        self.assertIn(
            "acknowledgement.originalTransactionID == String(transaction.originalID)",
            self.store,
        )
        self.assertNotIn("expectedDisposition", self.store)
        self.assertNotIn("entitlementState = .serverConfirmed(preferred.1)", self.store)
        authority = section(
            self.store,
            "private func refreshServerAuthority() async",
            "private func markServerConfirmationIndeterminate()",
        )
        self.assertIn("authority.status.grantsAccess", authority)
        self.assertIn("authority.status == .unconfirmed", authority)
        self.assertLess(
            authority.index("authority.status == .unconfirmed"),
            authority.index("guard authority.status.grantsAccess"),
        )
        self.assertIn("entitlementState = .inactive", authority)
        self.assertIn("entitlementState = .serverConfirmed(entitlement)", authority)
        self.assertIn("markServerConfirmationIndeterminate()", authority)
        self.assertIn("authority.accessUntilMs", authority)
        self.assertIn("authority.authorityStaleAtMs", authority)
        self.assertIn("var expirationDate: Date { min(accessUntilDate, authorityStaleAt) }", self.store)
        self.assertIn("case let .serverConfirmed(entitlement):", self.store)
        self.assertIn("return entitlement.isUsable()", self.store)
        reconcile = section(
            self.store,
            "private func reconcileCurrentEntitlements() async",
            "private func refreshServerAuthority() async",
        )
        self.assertNotIn("preferred", reconcile)
        self.assertIn("_ = await refreshServerAuthority()", reconcile)
        self.assertIn("transaction.productType == .autoRenewable", self.store)
        self.assertIn("transaction.ownershipType == .purchased", self.store)
        self.assertIn("transaction.revocationDate == nil", self.store)
        self.assertIn("!transaction.isUpgraded", self.store)
        self.assertIn("transaction.expirationDate != nil", self.store)
        self.assertNotIn("expirationDate > Date.now", self.store)
        self.assertNotIn("expirationDate.map", self.store)
        self.assertNotIn(".distantFuture", self.store)
        self.assertNotIn("jsonRepresentation", self.store)
        self.assertNotIn("UserDefaults", self.store)
        self.assertNotIn("@AppStorage", self.store)
        self.assertNotIn("PairingCredential", self.store)

    def test_live_session_is_only_injected_when_both_configs_are_explicit(self) -> None:
        client = source("NekoWidget/Services/BillingAPIClient.swift")
        session = section(
            client,
            "actor PlusBillingSession",
            "actor URLSessionBillingAPIClient",
        )
        self.assertIn("purchaseConfiguration.isConfigured", session)
        self.assertIn("billingConfiguration.isConfigured", session)
        self.assertIn("bootstrap.resumeExistingCredential()", session)
        self.assertIn("billingAccountRecoveryRequired", session)
        self.assertIn("createFreshBillingAccount(", session)
        self.assertIn("authorizedBy authorization: BillingFreshAccountAuthorization", session)
        self.assertIn("apiClient.fetchAuthoritativeEntitlement(", session)

        initializer = section(
            self.store,
            "init(\n        configuration:",
            "deinit {",
        )
        self.assertIn("PlusBillingSession.configured(", initializer)
        self.assertIn("recordVerifiedTransactionEvent == nil", initializer)
        self.assertIn("fetchAuthoritativeEntitlement == nil", initializer)

    def test_storekit_is_app_target_only_and_has_no_current_ui_or_gate(self) -> None:
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        app_sources = section(
            project,
            "A00000000000000000000021 /* Sources */ = {",
            "A00000000000000000000025 /* Sources */ = {",
        )
        extension_sources = project[project.index("A00000000000000000000025 /* Sources */ = {") :]
        self.assertIn("PlusPurchaseStore.swift in Sources", app_sources)
        self.assertNotIn("PlusPurchaseStore.swift in Sources", extension_sources)

        app = source("NekoWidget/App/NekoWidgetApp.swift")
        self.assertIn("@StateObject private var plusPurchases = PlusPurchaseStore.productionShared", app)
        self.assertIn("await plusPurchases.start()", app)
        self.assertIn("await plusPurchases.refreshAfterForegroundEntry()", app)
        self.assertIn("guard newPhase == .active", app)

        self.assertIn("@Published private(set) var pendingProductID", self.store)
        purchase = section(
            self.store,
            "func purchase(",
            "func restorePurchases() async",
        )
        self.assertIn("pendingProductID == nil", purchase)
        self.assertIn("pendingProductID = product.id", purchase)

        for relative in (
            "NekoWidget/Views/MainTabView.swift",
            "NekoWidget/Views/SettingsView.swift",
            "NekoWidget/Views/LikedPhotosView.swift",
        ):
            ui = source(relative)
            self.assertNotIn("PlusPurchaseStore", ui)
            self.assertNotIn("PlusStorefrontEnabled", ui)
            self.assertNotIn("ねこのまど Plus", ui)
            self.assertNotIn("¥980", ui)

    def test_personal_widget_daily_photo_is_free_and_not_a_plus_entry(self) -> None:
        # 11/11: the daily photo on the personal Widget (with the cloudy
        # window and 「もう一枚」) is free. Nothing in the app or the Widget
        # stops it for membership or offers Plus for it.
        policy = source("Shared/MembershipAccessPolicy.swift")
        allowed = section(policy, "        switch operation {\n", "            return .allowed\n")
        self.assertIn(".refreshPersonalWidget", allowed)
        gated = section(policy, "            return .allowed\n        case ", "return .membershipRequired")
        self.assertNotIn(".refreshPersonalWidget", gated)
        main = source("NekoWidget/Views/MainTabView.swift")
        self.assertNotIn("personalWidgetPaused", main)
        self.assertIn("showsWidgetTiming: openedFromWidget,", main)
        for relative in (
            "NekoWidgetWidget/NekoWidgetTimelineProvider.swift",
            "NekoWidgetWidget/RevealCloudyWindowIntent.swift",
            "NekoWidgetWidget/DailyPersonalPhotoIntent.swift",
        ):
            widget = source(relative)
            self.assertNotIn("PersonalWidgetMembershipStore", widget, relative)
            self.assertNotIn("allowsSelection: allows", widget, relative)
        swift_roots = ("NekoWidget", "Shared", "NekoWidgetWidget", "NekoWidgetShareExtension")
        for root in swift_roots:
            for path in (ROOT / root).rglob("*.swift"):
                text = path.read_text(encoding="utf-8")
                relative = str(path.relative_to(ROOT))
                self.assertNotIn("widgetResume", text, relative)
                self.assertNotIn("毎日新しくなるのはPlus", text, relative)
                self.assertNotIn("毎日新しくするのは", text, relative)
                self.assertNotIn("毎日、新しい1枚がホーム画面に", text, relative)
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        self.assertIn("case .onboarding: nil", model)

    def test_offer_observes_shared_authority_without_enabling_unknown_or_active_purchase(self) -> None:
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        view = source("NekoWidget/Views/MembershipOfferView.swift")
        live_factory = section(model, "static func live(", "func refresh() async")
        self.assertIn("PlusPurchaseStore.productionShared", live_factory)
        self.assertIn("store.objectWillChange.sink", live_factory)
        self.assertNotIn("PlusPurchaseStore()", model)
        eligibility = section(model, "var canPurchase: Bool", "private init(")
        for guard in ("!isMember", "!isWaiting", "!verificationRequired", "purchases?.canStartNewPurchase"):
            self.assertIn(guard, eligibility)
        self.assertIn("purchases.entitlementState.grantsPlus", model)
        self.assertIn("expirationDate", model)
        self.assertIn("expiryTask?.cancel()", model)
        refresh = section(model, "func refresh() async", "private func updateMembershipState()")
        self.assertIn("refreshAfterForegroundEntry()", refresh)
        self.assertNotIn("restorePurchases", refresh)
        self.assertNotIn("purchaseAction", refresh)
        self.assertIn("if isMember {", view)
        self.assertLess(view.index("if isMember {"), view.index("Text(offer.billingLine)"))
        self.assertIn(".disabled(isWorking || !canPurchase || offer == nil)", view)

    def test_purchase_screen_keeps_terms_and_privacy_links(self) -> None:
        # App Review: the one Plus screen links the terms of use and the privacy
        # policy. A selling build always has the privacy page; Debug's preview
        # fixture stands in for one (11/8: the UI test found the link missing).
        view = source("NekoWidget/Views/MembershipOfferView.swift")
        footer = section(view, "@ViewBuilder private var footerLinkContent: some View {", "\n    }\n")
        for identifier in ("membership-offer-restore", "membership-offer-terms", "membership-offer-privacy"):
            self.assertIn(f'.accessibilityIdentifier("{identifier}")', footer)
        self.assertIn('Link("利用規約", destination: termsURL)', footer)
        # 11/11: the EULA URL is shared with 設定, written once in the configuration.
        self.assertIn("if let termsURL = AppPublicLinksConfiguration.termsOfUseURL {", footer)
        self.assertNotIn("stdeula", view)
        self.assertIn("if let privacyURL = Self.privacyURL {", footer)
        privacy = section(view, "static var privacyURL: URL? {", "\n    }\n")
        debug, release = privacy.split("#endif", 1)
        self.assertIn("#if DEBUG", debug)
        self.assertIn('CommandLine.arguments.contains("--membership-offer-ui-fixture")', debug)
        self.assertEqual(release.strip(), "return AppPublicLinksConfiguration.current.privacyURL")
        # The live storefront never loads an offer without the privacy page,
        # and the release overlay that sells sets it.
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        load = section(model, "func load() async -> MembershipOfferPresentation? {", "await purchases.start()")
        self.assertIn("AppPublicLinksConfiguration.current.privacyURL != nil", load)
        production = source("Config.Production.xcconfig")
        self.assertRegex(production, r"(?m)^APP_PRIVACY_URL = https:/\$\(\)/\S+/privacy/$")

    def test_plus_prompt_keeps_its_entry_button_identifier(self) -> None:
        # 11/8: the prompt's identifier on a plain stack replaced its button's
        # (plus-offer-entry-*), so closing the Plus screen showed no button to UI tests.
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        prompt = section(model, "struct PlusOfferPrompt: View {", "struct PlusSettingsSection: View {")
        self.assertIn(r'.accessibilityIdentifier("plus-offer-entry-\(context.identifier)")', prompt)
        before = prompt[:prompt.index('.accessibilityIdentifier("plus-offer-prompt")')].rstrip()
        self.assertTrue(before.endswith(".accessibilityElement(children: .contain)"))

    def test_restore_is_one_button_that_also_rechecks(self) -> None:
        # 11/5: 「購入状況を再確認」 and 「購入を復元」 are one button, 「購入を復元」.
        for path in sorted((ROOT / "NekoWidget").rglob("*.swift")):
            self.assertNotIn("購入状況を再確認", path.read_text(encoding="utf-8"), str(path))
        for identifier in ("membership-offer-refresh", "membership-restore-refresh",
                           "settings-membership-recheck", "app-record-membership-recheck"):
            for path in sorted((ROOT / "NekoWidget").rglob("*.swift")):
                self.assertNotIn(f'"{identifier}"', path.read_text(encoding="utf-8"), str(path))
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        restore = section(model, "    func restore() async -> MembershipOfferActionResult", "    private func apply(")
        # The re-check comes first and a confirmed member skips AppStore.sync.
        self.assertLess(restore.index("await recheckConfirmsMembership()"), restore.index("await restoreAction()"))
        recheck = section(restore, "private func recheckConfirmsMembership()", "static func restoreForAnotherScreen()")
        self.assertIn("await purchases.refreshAfterForegroundEntry()", recheck)
        self.assertIn("purchases.entitlementState.permitsPersonalPlus", recheck)
        self.assertNotIn("restoreAction", recheck)
        self.assertNotIn("purchaseAction", recheck)
        self.assertIn("await model.restore()", section(model, "static func restoreForAnotherScreen()", "    private func apply("))
        # Settings: the unknown state's one row is the restore, and restore
        # stays reachable while launch is still checking.
        settings = section(model, "struct PlusSettingsSection: View {", "private func refreshMembership()")
        unknown = section(settings, "case .unknown:", "case .checking:")
        # 11/7: the row restores where it is tapped, with the same restore().
        self.assertIn('MembershipRestoreButton(look: .settingsRow, identifier: "settings-membership-restore")', unknown)
        self.assertIn("if status == .notMember || status == .checking {", settings)
        self.assertIn('MembershipRestoreButton(look: .footnote, identifier: "settings-membership-restore")',
                      section(settings, "if status == .notMember || status == .checking {", "} header: {"))
        in_place = section(source("NekoWidget/Services/MembershipAccessContext.swift"),
                           "struct MembershipRestoreButton: View {", "#if DEBUG")
        self.assertIn("MembershipOfferModel.live(presentsOffer: false)", in_place)
        self.assertIn("await model.restore()", in_place)
        self.assertIn('workingTitle: "確認しています…"', in_place)
        # The restore sheet and the Plus sheet carry the one restore button only.
        sheet = section(source("NekoWidget/Services/MembershipAccessContext.swift"),
                        "struct MembershipRestoreSheet: View {", "private struct MembershipFeatureGate")
        self.assertEqual(sheet.count("Button("), 2, "購入を復元 and 閉じる only")
        self.assertIn("await model.restore()", sheet)
        self.assertNotIn("model.refresh()", sheet)
        # Saving screens: the same restore, then that screen's Plus check.
        coordinator = source("NekoWidget/Services/ManagedPreservationCoordinator.swift")
        restore_membership = section(coordinator, "func restoreMembership()", "func checkNoticeContact()")
        self.assertLess(restore_membership.index("await MembershipOfferModel.restoreForAnotherScreen()"),
                        restore_membership.index("self.checkMembership()"))
        # A Plus check still running never disables the restore.
        self.assertIn("guard isSignedIn, !membershipRestoring, let owner = authenticatedOwnerID else { return }",
                      restore_membership)
        view = source("NekoWidget/Views/ManagedPreservationView.swift")
        # 11/6: the button says 「確認しています…」 while the restore runs.
        self.assertEqual(view.count('Button { coordinator.restoreMembership() } label: {'), 2)
        self.assertEqual(len(re.findall(
            r'Button \{ coordinator\.restoreMembership\(\) \} label: \{\n'
            r'\s*WorkingLabel\(title: "購入を復元", workingTitle: "確認しています…", working: coordinator\.membershipRestoring\)\n'
            r'\s*\}\n'
            r'(?:\s*\.accessibilityIdentifier\("[^"]+"\)\n)?\s*\.disabled\(coordinator\.membershipRestoring\)', view)), 2)
        # A connection failure keeps its own retry: never an Apple sign-in.
        retry = section(view, "} else if coordinator.membership == nil {", "} else if coordinator.membership?.canSave != true {")
        self.assertIn('Button("もう一度確認") { coordinator.checkMembership() }', retry)
        self.assertNotIn("restoreMembership", retry)
        self.assertIn("「もう一度確認」を押してから", coordinator)
        persistence = source("NekoWidget/Services/AppRecordPersistence.swift")
        # 11/7: this iPhone already has Plus there, so the same check is named for it.
        self.assertIn('Button { authentication.restoreMembership() } label: {\n'
                      '                    WorkingLabel(title: "Plusをもう一度確かめる", workingTitle: "確認しています…", '
                      'working: authentication.membershipRestoring)', persistence)

    def test_empty_purchase_history_opens_paid_entry_points_without_unlocking_access(self) -> None:
        reconcile = section(self.store, "private func performCurrentEntitlementReconciliation()", "@discardableResult")
        fresh = section(reconcile, "await hasFreshLocalPurchaseEligibility()", "_ = await refreshServerAuthority()")
        self.assertIn("entitlementState = .inactive", fresh)
        self.assertNotIn("markServerConfirmationIndeterminate()", fresh)
        authority = section(self.store, "if authority.status == .unconfirmed", "guard authority.status.grantsAccess")
        empty = section(authority, "if authorityAllowsNewPurchase {", "markServerConfirmationIndeterminate()")
        self.assertIn("entitlementState = .inactive", empty)
        self.assertIn("return .denied", empty)
        self.assertIn("markServerConfirmationIndeterminate()", authority)
        context = source("NekoWidget/Services/MembershipAccessContext.swift")
        self.assertIn("case .inactive: personal = .inactive", context)
        # The executable operation matrix covers all three requested entry points,
        # bounded paid-offline access, and expired -> membershipRequired.
        matrix = source("ci/verify-membership-access.swift")
        for operation in (".createOwnWindow", ".createPersonalMemo", ".openGrowingSummary"):
            self.assertIn(operation, matrix)
        self.assertIn('("offline within prior authority",', matrix)
        self.assertIn('("expired", .verified(validUntil: past), .membershipRequired)', matrix)

    def test_foreground_deadline_rechecks_authority_without_extending_it(self) -> None:
        expiry = section(self.store, "private func scheduleAuthorityExpiry()", "func start()")
        self.assertIn("expiry > .now", expiry)
        self.assertIn("await self.refreshAfterForegroundEntry()", expiry)
        self.assertNotIn("canStartNewPurchase = true", expiry)
        self.assertNotIn("AppStore.sync", expiry)
        self.assertIn("scheduleAuthorityExpiry()", section(self.store, "var entitlementState", "let membershipActions"))

    def test_new_purchase_presentation_never_uses_network_failure_or_incomplete_identity_as_fresh(self) -> None:
        reconcile = section(self.store, "private func performCurrentEntitlementReconciliation()", "@discardableResult")
        fresh = section(self.store, "private func hasFreshLocalPurchaseEligibility()", "private func scanCurrentEntitlements()")
        self.assertLess(reconcile.index("!scan.encounteredUnverifiedOrUnsupported"),
                        reconcile.index("await hasFreshLocalPurchaseEligibility()"))
        self.assertIn("scan.events.isEmpty, pendingProductID == nil", reconcile)
        self.assertIn("!awaitingServerConfirmation", reconcile)
        self.assertIn("purchaseEligibilityGeneration == eligibilityGeneration", reconcile)
        self.assertIn("authorizeAfterCurrentEntitlementScan()", fresh)
        self.assertIn("validatedForBootstrap()", fresh)
        self.assertIn("BillingSandboxOwnerEnrollment.readExistingPending", fresh)
        self.assertIn("BillingKeychainStore.load() == existing", fresh)
        self.assertIn("BillingInstallationMarkerStore.loadExisting() == marker", fresh)
        self.assertIn("catch { return false }", fresh)
        catch = reconcile[reconcile.index("} catch {"):]
        self.assertNotIn("hasFreshLocalPurchaseEligibility", catch)
        self.assertNotIn("canStartNewPurchase = true", catch)
        authority = section(self.store, "private func refreshServerAuthority() async", "private func markServerConfirmationIndeterminate()")
        self.assertIn("canStartNewPurchase = false", authority)
        self.assertIn("authority.productId == nil", authority)
        self.assertIn("authority.accessUntilMs == nil", authority)
        self.assertIn("authority.authorityStaleAtMs == nil", authority)
        updates = section(self.store, "private func handleTransactionUpdate(", "private func reconcileCurrentEntitlements()")
        self.assertEqual(updates.count("canStartNewPurchase = false"), 2)
        self.assertEqual(updates.count("purchaseEligibilityGeneration &+= 1"), 2)
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        live_purchase = section(model[model.index("private final class MembershipStoreKitClient"):],
                                "func purchase(presentedOffer:", "func restore() async")
        self.assertEqual(live_purchase.count("purchases.requirePurchaseVerification()"), 2)
        invalidate = section(self.store, "func requirePurchaseVerification()", "func purchase(")
        self.assertIn("purchaseEligibilityGeneration &+= 1", invalidate)
        self.assertIn("canStartNewPurchase = false", invalidate)
        self.assertIn("if !entitlementState.grantsPlus", invalidate)

    def test_shared_store_waits_for_initialization_and_reuses_inflight_scan(self) -> None:
        self.assertIn("if let startTask { await startTask.value; return }", self.store)
        self.assertIn("if let refreshTask { await refreshTask.value; return }", self.store)
        self.assertIn("if let reconciliationTask { await reconciliationTask.value; return }", self.store)

    def test_catalog_changes_cannot_purchase_an_old_quote(self) -> None:
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        refresh = section(self.store, "private func performRefresh()", "func stop()")
        self.assertIn("await loadProducts()", refresh)
        self.assertNotIn("if products.isEmpty", refresh)
        self.assertIn("for await _ in Storefront.updates", self.store)
        loader = section(self.store, "private func loadProducts()", "private func startStorefrontUpdatesListener()")
        self.assertLess(loader.index("products = []"), loader.index("Product.products(for:"))
        self.assertIn("generation == productLoadGeneration", loader)
        self.assertIn("storefrontID == currentStorefrontID", loader)
        purchase = section(self.store, "func purchase(", "func restorePurchases()")
        self.assertLess(purchase.index("productCatalogRevision == expectedCatalogRevision"),
                        purchase.index("product.purchase(options:"))
        self.assertIn("currentStorefrontID == productStorefrontID", purchase)
        final_gate = purchase[purchase.index("let currentStorefrontID"):purchase.index("product.purchase(options:")]
        for required in ("purchaseEligibilityGeneration == eligibilityGeneration", "!entitlementState.grantsPlus",
                         "!awaitingServerConfirmation", "pendingProductID == nil", "!isRestoring"):
            self.assertIn(required, final_gate)
        live = section(model, "private final class MembershipStoreKitClient", "struct MembershipOfferSheet")
        self.assertLess(live.index("currentOffer == presentedOffer"), live.index("prepareAccountForExplicitPurchase()"))
        self.assertIn("expectedCatalogRevision: catalogRevision", live)
        self.assertIn("generation == offerLoadGeneration", model)
        self.assertIn("store.productCatalogRevision", model)

    def test_cancelled_member_sees_until_when_plus_lasts(self) -> None:
        # 11/9: auto-renewal off but still active shows its end date, so the
        # cancellation visibly worked; renewing stays 「Plus（利用中）」.
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        app_sources = section(project, "A00000000000000000000021 /* Sources */ = {",
                              "A00000000000000000000025 /* Sources */ = {")
        extension_sources = project[project.index("A00000000000000000000025 /* Sources */ = {"):]
        self.assertIn("PlusRenewalPresentation.swift in Sources", app_sources)
        self.assertNotIn("PlusRenewalPresentation.swift in Sources", extension_sources)
        words = source("NekoWidget/Services/PlusRenewalPresentation.swift")
        self.assertNotIn("import SwiftUI", words)
        self.assertNotIn("import StoreKit", words)
        self.assertIn('"Plus（\\($0)まで）"', words)
        self.assertIn('"\\($0)まで使えます"', words)
        self.assertIn("guard willAutoRenew == false, let expiration, expiration > now", words)

        # StoreKit 2 renewal info, verified only, read for words and never for access.
        self.assertIn("@Published private(set) var renewal: PlusRenewalSnapshot?", self.store)
        renewal = section(self.store, "private func refreshRenewal() async {", "func refreshProductsForOffer()")
        self.assertIn("Transaction.currentEntitlements", renewal)
        self.assertIn("Product.SubscriptionInfo.status(for: groupID)", renewal)
        self.assertIn("case let .verified(transaction) = status.transaction", renewal)
        self.assertIn("case let .verified(renewalInfo) = status.renewalInfo", renewal)
        self.assertIn("renewalInfo.willAutoRenew", renewal)
        self.assertIn("transaction.expirationDate", renewal)
        self.assertIn("isEligibleStoreKitTransaction(transaction)", renewal)
        for forbidden in ("entitlementState =", "canStartNewPurchase", "AppStore.sync", "refreshServerAuthority"):
            self.assertNotIn(forbidden, renewal)
        # Every launch / foreground / refresh request re-reads it.
        start = section(self.store, "private func performStart() async {", "func refreshAfterForegroundEntry()")
        self.assertLess(start.index("await reconcileCurrentEntitlements()"), start.index("await refreshRenewal()"))
        refresh = section(self.store, "private func performRefresh() async {", "private func refreshRenewal()")
        self.assertLess(refresh.index("await reconcileCurrentEntitlements()"), refresh.index("await refreshRenewal()"))
        updates = section(self.store, "private func startTransactionUpdatesListener()", "private func handleTransactionUpdate(")
        self.assertIn("await self?.refreshRenewal()", updates)

        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        settings = section(model, "struct PlusSettingsSection: View {", "#if DEBUG || INTERNAL_PRESENTATION")
        self.assertNotIn('"Plus（利用中）"', model)
        self.assertIn("Text(status == .member ? memberHeader :", settings)
        self.assertIn("PlusRenewalPresentation.settingsHeader(willAutoRenew: purchases.renewal?.willAutoRenew,", settings)
        self.assertIn('.accessibilityIdentifier(status == .member ? "settings-membership-active"', settings)
        # Closing Apple's management sheet re-reads renewal through the shared refresh.
        self.assertIn(".manageSubscriptionsSheet(isPresented: $showsManagement)", settings)
        self.assertIn("if !isPresented { refreshMembership() }", settings)
        self.assertIn("NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)",
                      settings[settings.index("private func refreshMembership()"):])
        app = source("NekoWidget/App/NekoWidgetApp.swift")
        notified = section(app, ".onReceive(NotificationCenter.default.publisher(for: .membershipAccessRefreshRequested))",
                           ".task {")
        self.assertIn("await plusPurchases.refreshAfterForegroundEntry()", notified)
        sheet = section(model, "struct MembershipOfferSheet: View {", "struct PlusOfferPrompt: View {")
        self.assertIn("await model.refreshAfterSubscriptionManagement()", sheet)
        self.assertIn("isMember: model.isMember, memberEndLine: model.memberEndLine,", sheet)
        state = section(model, "private func updateMembershipState()", "static func preview(state:")
        self.assertIn("let endLine = isMember ? PlusRenewalPresentation.offerEndLine(willAutoRenew: renewal?.willAutoRenew,",
                      state)
        # Previews and fixtures have no StoreKit renewal: they keep 「Plusを利用中です」.
        self.assertIn("let renewal = purchases?.renewal", state)

        # The Plus screen: one line, the end date, in place of 「Plusを利用中です」.
        view = source("NekoWidget/Views/MembershipOfferView.swift")
        member = section(view, "            if isMember {", "            } else if let offer {")
        self.assertIn('Label(memberEndLine ?? PlusRenewalPresentation.renewingOfferTitle, systemImage: "checkmark.circle.fill")',
                      member)
        self.assertIn('.accessibilityIdentifier("membership-offer-active")', member)
        self.assertLess(member.index("if memberEndLine == nil {"), member.index("新しく申し込む必要はありません。"))
        self.assertEqual(member.count("Text("), 1)

        # The words run on macOS in the ordinary quick checks.
        quick = source("ci/run-quick-ios-checks.sh")
        self.assertIn("NekoWidget/Services/PlusAuthorityCache.swift NekoWidget/Services/PlusRenewalPresentation.swift \\\n"
                      "  ci/verify-plus-authority-cache.swift", quick)
        verifier = source("ci/verify-plus-authority-cache.swift")
        self.assertIn("try verifyRenewalWords()", verifier)
        for expected in ('"Plus（11月9日まで）"', '"11月9日まで使えます"', '"Plus（2027年1月9日まで）"', '"Plus（利用中）"'):
            self.assertIn(expected, verifier)


    def test_plus_screen_loads_once_and_keeps_its_price_and_photo(self) -> None:
        # 11/10 (build 354): the Plus screen reloaded over and over; the photo
        # blinked and 「料金を確認できません…」 showed next to the price.
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        live_factory = section(model, "static func live(", "func refresh() async")
        sink = section(live_factory, "store.objectWillChange.sink", "        return model")
        # A publication never clears the offer itself: one shared, settled read.
        self.assertIn("if model.presentsOffer && model.hasLoaded {", sink)
        self.assertIn("await model.reloadOfferForCurrentCatalog()", sink)
        self.assertNotIn("reloadOfferPresentation()", sink)
        coalesce = section(model, "private func reloadOfferForCurrentCatalog() async {",
                           "private func applyOfferUnavailableMessage()")
        self.assertIn("if observedCatalogRevision == revision, let offerReloadTask {", coalesce)
        self.assertIn("PlusOfferReloadPolicy.shouldReload(", coalesce)
        self.assertIn("catalogLoading: store.productAvailability == .loading", coalesce)
        load = section(model, "    func load() async {", "    func purchase() async")
        self.assertIn("await reloadOfferForCurrentCatalog()", load)
        self.assertNotIn("時間をおいて開き直して", load)
        self.assertEqual(model.count("PlusOfferReloadPolicy.unavailableMessage"), 2)
        self.assertNotIn('"料金を確認できません。時間をおいて開き直してください。"', model)
        reload = section(model, "private func reloadOfferPresentation() async {",
                         "private func reloadOfferForCurrentCatalog() async {")
        # What a tap may buy is still cleared during a read; the screen keeps the price.
        self.assertLess(reload.index("offer = nil"), reload.index("await loadAction()"))
        self.assertIn("PlusOfferReloadPolicy.displayed(previous: displayedOffer, loaded: updated, settled: settled)", reload)
        self.assertIn("$0.productAvailability != .loading && $0.productCatalogRevision == revision", reload)
        state = section(model, "private func updateMembershipState()", "static func preview(state:")
        self.assertIn("applyOfferUnavailableMessage()", state)
        sheet = section(model, "struct MembershipOfferSheet: View {", "struct PlusOfferPrompt: View {")
        self.assertIn("offer: model.displayedOffer,", sheet)
        self.assertIn("canPurchase: model.canPurchase", sheet)
        self.assertIn("photoAsset: heldPhoto ?? placePhoto", sheet)
        self.assertIn("if heldPhoto == nil { heldPhoto = placePhoto }", sheet)
        self.assertIn(".task { await model.load() }", sheet)
        self.assertIn("guard !hasLoaded else { return }", load)
        # Settings keeps its last answer while re-checking, so the sheet on its header stays.
        settings = section(model, "struct PlusSettingsSection: View {", "private func refreshMembership()")
        self.assertIn("private var status: Status { Status.steady(liveStatus, lastAnswer: lastAnswer) }", settings)
        self.assertIn(".onChange(of: liveStatus, initial: true) { _, answer in", settings)
        self.assertIn("if answer != .checking { lastAnswer = answer }", settings)
        verifier = source("ci/verify-plus-authority-cache.swift")
        self.assertIn("try verifyOfferSteadiness()", verifier)
        self.assertIn('"one refresh, one offer read"', verifier)
        self.assertIn('"never 料金を確認できません next to a price"', verifier)

    def test_plus_screen_sits_inside_its_margins_and_says_the_price_once(self) -> None:
        # 11/10 (TestFlight 354): the rows, the button and the trust box ran to
        # the screen edges. A scaledToFill photo sized by itself widened the
        # whole stack; it now fills a fixed box as an overlay.
        view = source("NekoWidget/Views/MembershipOfferView.swift")
        body = section(view, "    var body: some View {", "    private var photoHeader: some View {")
        self.assertIn(".frame(maxWidth: 440)\n            .padding(.horizontal, 24)", body)
        for forbidden in ("ignoresSafeArea", "UIScreen.main", "containerRelativeFrame", ".padding(.horizontal, 0)"):
            self.assertNotIn(forbidden, view)
        header = section(view, "    private var photoHeader: some View {", "    private var offerDetails: some View {")
        box = section(header, "private static func photoBox<Content: View>", "\n    }\n")
        self.assertLess(box.index("Color.clear"), box.index(".frame(height: 164)"))
        self.assertLess(box.index(".frame(height: 164)"), box.index(".overlay { content() }"))
        self.assertIn(".clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))", box)
        self.assertEqual(header.count("Self.photoBox {"), 2)
        # Every scaledToFill photo is inside the overlay box, never sizing the stack.
        self.assertEqual(header.count(".scaledToFill()"), 1)
        self.assertLess(header.index("Self.photoBox {"), header.index(".scaledToFill()"))
        values = section(body, "ForEach(Self.values", "offerDetails")
        self.assertIn(".frame(maxWidth: .infinity, alignment: .leading)", values)
        actions = section(view, "    private var actions: some View {", "    private var reassurance: some View {")
        self.assertIn(".frame(maxWidth: .infinity, minHeight: 36)", actions)
        # The shared primary button: filled, large, 14 corners (DesignTokens).
        self.assertIn(".nekoPrimaryButton()", actions)
        tokens = source("NekoWidget/Views/DesignTokens.swift")
        primary = section(tokens, "func nekoPrimaryButton() -> some View {", "\n    }\n")
        for part in (".buttonStyle(.borderedProminent)", ".buttonBorderShape(.roundedRectangle(radius: NekoRadius.button))",
                     ".controlSize(.large)"):
            self.assertIn(part, primary)
        self.assertIn("static let button: CGFloat = 14", tokens)
        reassurance = section(view, "    private var reassurance: some View {", "    private var footerLinks: some View {")
        self.assertIn(".frame(maxWidth: .infinity, alignment: .leading)", reassurance)
        self.assertIn("in: RoundedRectangle(cornerRadius: 14, style: .continuous)", reassurance)
        # Order: photo, heading, the six rows, the purchase block, the trust box, the links.
        scroll = section(body, "        ScrollView {", ".frame(maxWidth: 440)")
        order = ["photoHeader", "valueRows", "if !pinsPurchase { purchaseBlock }", "reassurance", "footerLinks"]
        self.assertEqual(sorted(order, key=scroll.index), order)
        # 11/11: the button, the price and the renewal sentence are pinned at
        # the bottom, so they are on the first screen even on iPhone SE. Only
        # the accessibility text sizes keep them in the scrolling column.
        self.assertIn(".safeAreaInset(edge: .bottom, spacing: 0) {\n            if pinsPurchase { pinnedPurchaseBar }", body)
        self.assertIn("private var pinsPurchase: Bool { !dynamicTypeSize.isAccessibilitySize }", view)
        block = section(view, "    private var purchaseBlock: some View {", "    private var pinnedPurchaseBar: some View {")
        self.assertLess(block.index("offerDetails"), block.index("actions"))
        bar = section(view, "    private var pinnedPurchaseBar: some View {", "    private var photoHeader: some View {")
        for part in ("purchaseBlock", ".frame(maxWidth: 440)", ".padding(.horizontal, 24)", ".background(Color(uiColor: .systemBackground))", "LinearGradient(colors: [Color(uiColor: .systemBackground).opacity(0),",
                     ".accessibilityElement(children: .contain)", 'accessibilityIdentifier("membership-offer-purchase-bar")'):
            self.assertIn(part, bar)
        self.assertLess(actions.index('accessibilityIdentifier("membership-offer-purchase")'),
                        actions.index('accessibilityIdentifier("membership-offer-price")'))
        self.assertLess(actions.index('accessibilityIdentifier("membership-offer-price")'),
                        actions.index('accessibilityIdentifier("membership-offer-renewal")'))
        # The five rows are regular weight; only the heading is bold.
        rows = section(view, "    private var valueRows: some View {", "    private var purchaseBlock: some View {")
        self.assertIn("Text(value.0).font(.subheadline)", rows)
        self.assertNotIn(".headline", rows)
        self.assertEqual(len(re.findall(r'^        \("', view, re.M)), 5)
        # Guideline 3.1.2: the price once, under the button, with 自動更新, as a headline.
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        monthly = section(model, "static let startTitle", "enum MembershipRestoreFailure")
        self.assertIn('static let startTitle = "Plusを始める"', monthly)
        self.assertIn('var billingLine: String { afterTrialText ?? "\\(priceText)（自動更新）" }', monthly)
        self.assertIn('purchaseTitle: "\\(trialPeriod)無料で試す"', monthly)
        self.assertIn('afterTrialText: "その後 \\(price)（自動更新）"', monthly)
        self.assertNotIn("（\\(price)）", monthly)
        self.assertIn('let price = "月額\\(displayPrice)"', monthly)
        billing = section(actions, "Text(offer.billingLine)", 'accessibilityIdentifier("membership-offer-price")')
        self.assertIn(".font(.headline)", billing)
        self.assertNotIn("membership-offer-trial", view)
        # Loading: spinner on the disabled button; no product: only the one message line.
        self.assertIn('if isWorking && running != "購入を復元" { ProgressView().tint(.white) }', actions)
        self.assertNotIn("membership-offer-unavailable", view)
        self.assertNotIn('"料金を確認できません"', view)
        for link in ("membership-offer-restore", "membership-offer-cancel-help", "membership-offer-terms",
                     "membership-offer-privacy"):
            self.assertIn(f'.accessibilityIdentifier("{link}")', view)
        ui = source("NekoWidgetUITests/PhotoPermissionUITests.swift")
        self.assertIn('"14日間無料で試す"', ui)
        self.assertIn('"その後 月額¥980（自動更新）"', ui)
        self.assertIn('XCTAssertEqual(purchase.label, "Plusを始める")', ui)
        self.assertIn('"月額¥980（自動更新）"', ui)
        self.assertIn("XCTAssertGreaterThanOrEqual(element.frame.minX - margin.minX, 16, element.identifier)", ui)
        self.assertIn('XCTAssertTrue(price.isHittable, "The price is pinned on the first screen")', ui)
        self.assertNotIn("無料で始める", ui)

if __name__ == "__main__":
    unittest.main()
