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

    def test_widget_resume_entry_is_only_on_the_widget_opened_photo(self) -> None:
        # ADR-027 5章: the Widget that kept its last photo offers Plus where it
        # is opened, and nowhere else; the sheet never opens by itself.
        main = source("NekoWidget/Views/MainTabView.swift")
        self.assertIn("decision(for: .refreshPersonalWidget) == .membershipRequired", main)
        self.assertIn("showsWidgetTiming: openedFromWidget && !personalWidgetPaused", main)
        self.assertIn("if openedFromWidget, personalWidgetPaused { WidgetResumeOffer() }", main)
        offer = section(main, "private struct WidgetResumeOffer: View {", "\n}\n")
        self.assertIn("MembershipOfferSheet(model: .live(), context: .widgetResume)", offer)
        self.assertNotIn("presentsImmediately", offer)
        self.assertNotIn("PlusOfferPrompt", offer)
        for relative in (
            "NekoWidget/Views/LikedPhotosView.swift",
            "NekoWidget/App/AppRootView.swift",
        ):
            self.assertNotIn(".widgetResume", source(relative))

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
        self.assertLess(view.index("if isMember {"), view.index("Text(offer.afterTrialText ?? offer.priceText)"))
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


if __name__ == "__main__":
    unittest.main()
