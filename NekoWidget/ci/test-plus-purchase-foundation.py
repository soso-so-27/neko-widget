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
        failure = section(
            purchase,
            "} catch {",
            "return .awaitingServerConfirmation",
        )
        self.assertIn("markServerConfirmationIndeterminate()", failure)
        self.assertNotIn("finish()", failure)
        self.assertNotIn("return .purchased", purchase)
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
        self.assertIn("transaction.productType == .autoRenewable", self.store)
        self.assertIn("transaction.ownershipType == .purchased", self.store)
        self.assertIn("transaction.revocationDate == nil", self.store)
        self.assertIn("!transaction.isUpgraded", self.store)
        self.assertIn("let expirationDate = transaction.expirationDate", self.store)
        self.assertIn("expirationDate > Date.now", self.store)
        self.assertNotIn("expirationDate.map", self.store)
        self.assertNotIn(".distantFuture", self.store)
        self.assertNotIn("jsonRepresentation", self.store)
        self.assertNotIn("UserDefaults", self.store)
        self.assertNotIn("@AppStorage", self.store)
        self.assertNotIn("PairingCredential", self.store)

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
        self.assertIn("@StateObject private var plusPurchases = PlusPurchaseStore()", app)
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


if __name__ == "__main__":
    unittest.main()
