from pathlib import Path
import plistlib
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
        self.assertIn("if model.isPreview && (result == .completed || result == .cancelled)", model)
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

    def test_offer_observes_shared_authority_without_enabling_unknown_or_active_purchase(self) -> None:
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        view = source("NekoWidget/Views/MembershipOfferView.swift")
        live_factory = section(model, "static func live()", "func refresh() async")
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
        self.assertLess(view.index("if isMember {"), view.index("Text(offer.priceText)"))
        self.assertIn(".disabled(isWorking || !canPurchase || offer == nil)", view)

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

    def test_shared_store_waits_for_initialization_and_reuses_inflight_scan(self) -> None:
        self.assertIn("if let startTask { await startTask.value; return }", self.store)
        self.assertIn("if let refreshTask { await refreshTask.value; return }", self.store)
        self.assertIn("if let reconciliationTask { await reconciliationTask.value; return }", self.store)


if __name__ == "__main__":
    unittest.main()
