from pathlib import Path
import plistlib
import unittest


ROOT = Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class BillingClientFoundationTests(unittest.TestCase):
    def test_authoritative_freshness_is_client_bounded(self) -> None:
        core = source("NekoWidget/Services/BillingClientCore.swift")
        authority = core[
            core.index("struct BillingAuthoritativeEntitlement:"):
            core.index("struct BillingProvisionalEntitlement:")
        ]
        self.assertIn("36 * 60 * 60 * 1_000", authority)
        self.assertIn("+ maximumClockSkewMs", authority)
        self.assertIn(
            "authorityStaleAtMs - evaluatedAtMs",
            authority,
        )
        self.assertIn(
            "<= Self.maximumAuthorityFreshnessMs",
            authority,
        )
        self.assertIn("case .unconfirmed:", authority)
        self.assertIn("let hasNoAuthority", authority)
        self.assertIn("let hasUnsupportedAuthority", authority)
        self.assertIn("let hasExpiredOrStaleAuthority", authority)
        self.assertIn("accessUntilMs <= evaluatedAtMs", authority)
        self.assertIn("authorityStaleAtMs <= evaluatedAtMs", authority)

    def test_source_configuration_remains_closed(self) -> None:
        config = source("Config.xcconfig")
        self.assertRegex(config, r"(?m)^PLUS_STOREFRONT_ENABLED = NO$")
        self.assertRegex(config, r"(?m)^PLUS_MONTHLY_PRODUCT_ID =$")
        self.assertRegex(config, r"(?m)^PLUS_ANNUAL_PRODUCT_ID =$")
        self.assertRegex(config, r"(?m)^PLUS_BILLING_CLIENT_ENABLED = NO$")
        self.assertRegex(config, r"(?m)^PLUS_BILLING_API_BASE_URL =$")

        with (ROOT / "NekoWidget/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(
            info["PlusBillingClientEnabled"],
            "$(PLUS_BILLING_CLIENT_ENABLED)",
        )
        self.assertEqual(
            info["PlusBillingAPIBaseURL"],
            "$(PLUS_BILLING_API_BASE_URL)",
        )
        core = source("NekoWidget/Services/BillingClientCore.swift")
        self.assertIn('info["PlusBillingClientEnabled"]', core)
        self.assertNotIn('info["PlusStorefrontEnabled"]', core)

    def test_billing_identity_is_separate_and_host_only(self) -> None:
        files = [
            "BillingClientCore.swift",
            "BillingKeychainStore.swift",
            "BillingAPIClient.swift",
            "BillingFreshAccountAuthorization.swift",
        ]
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        app_start = project.index("A00000000000000000000021 /* Sources */ = {")
        extension_start = project.index(
            "A00000000000000000000025 /* Sources */ = {",
            app_start,
        )
        app_sources = project[app_start:extension_start]
        extension_sources = project[extension_start:]
        for name in files:
            self.assertIn(f"{name} in Sources", app_sources)
            self.assertNotIn(f"{name} in Sources", extension_sources)

        keychain = source("NekoWidget/Services/BillingKeychainStore.swift")
        self.assertIn(
            '"jp.nekowidget.billing.credentials.v1.host"',
            keychain,
        )
        self.assertIn("kSecAttrAccessibleWhenUnlockedThisDeviceOnly", keychain)
        self.assertIn("kSecAttrSynchronizable", keychain)
        self.assertNotIn("kSecAttrAccessGroup", keychain)
        self.assertIn(".applicationSupportDirectory", keychain)
        self.assertIn("isExcludedFromBackup = true", keychain)
        self.assertIn(".completeFileProtection", keychain)

        combined = "\n".join(
            source(f"NekoWidget/Services/{name}") for name in files
        )
        for forbidden in (
            "PairingCredential",
            "SharedContainer",
            "UserDefaults",
            "@AppStorage",
        ):
            self.assertNotIn(forbidden, combined)

    def test_bootstrap_is_crash_resumable_and_not_wired_to_ui(self) -> None:
        client = source("NekoWidget/Services/BillingAPIClient.swift")
        authorizer = source(
            "NekoWidget/Services/BillingFreshAccountAuthorization.swift"
        )
        keychain = source("NekoWidget/Services/BillingKeychainStore.swift")
        bootstrap = client[
            client.index("actor BillingAccountBootstrapCoordinator"):
            client.index("actor PlusBillingSession")
        ]
        self.assertIn("fileprivate init(validFor lifetime: Duration)", authorizer)
        self.assertIn("authorizationLifetime: Duration = .seconds(30)", authorizer)
        self.assertIn("PlusPurchaseConfiguration.current", authorizer)
        self.assertIn("configuration.isConfigured", authorizer)
        self.assertIn(
            "for await result in Transaction.currentEntitlements",
            authorizer,
        )
        self.assertIn("case let .verified(value)", authorizer)
        self.assertIn("case let .unverified(value, _)", authorizer)
        self.assertIn(
            "configuredProductIDs.contains(transaction.productID)",
            authorizer,
        )
        self.assertIn(
            "BillingClientError.billingAccountRecoveryRequired",
            authorizer,
        )
        self.assertGreaterEqual(authorizer.count("Task.checkCancellation()"), 3)

        self.assertIn("private var existingInFlight", bootstrap)
        self.assertIn("private var freshInFlight", bootstrap)
        existing_public = bootstrap[
            bootstrap.index("func resumeExistingCredential("):
            bootstrap.index("func createFreshCredential(")
        ]
        self.assertNotIn("BillingFreshAccountAuthorization", existing_public)
        self.assertNotIn("insertPendingCredential", existing_public)

        existing_private = bootstrap[
            bootstrap.index("private func loadAndResumeExistingCredential("):
            bootstrap.index("private func loadOrCreateFreshCredential(")
        ]
        self.assertIn(
            "guard let existing = try loadCredential() else",
            existing_private,
        )
        self.assertIn("BillingClientError.billingCredentialMissing", existing_private)
        self.assertNotIn("BillingCredential.pending", existing_private)
        self.assertNotIn("BillingFreshAccountAuthorization", existing_private)

        fresh = bootstrap[
            bootstrap.index("private func loadOrCreateFreshCredential("):
            bootstrap.index("private func resume(")
        ]
        self.assertIn(
            "authorizedBy authorization: BillingFreshAccountAuthorization",
            fresh,
        )
        self.assertLess(
            fresh.index("if let existing = try loadCredential()"),
            fresh.index("let candidate ="),
        )
        self.assertLess(
            fresh.index("try authorization.validatedForBootstrap()"),
            fresh.index("insertPendingCredential(candidate)"),
        )
        self.assertLess(
            fresh.index("insertPendingCredential(candidate)"),
            fresh.index("return try await resume(pending"),
        )
        self.assertEqual(
            bootstrap.count("try authorization.validatedForBootstrap()"),
            1,
        )
        resume = bootstrap[
            bootstrap.index("private func resume("):
            bootstrap.index("private func completeBootstrap(")
        ]
        self.assertNotIn("BillingFreshAccountAuthorization", resume)
        self.assertIn("return try await completeBootstrap(existing)", resume)

        complete = bootstrap[bootstrap.index("private func completeBootstrap("):]
        self.assertNotIn("BillingFreshAccountAuthorization", complete)
        self.assertLess(
            complete.index("try await apiClient.createAccount"),
            complete.index("let current = try loadCredential()"),
        )
        self.assertLess(
            complete.index("guard current == pending"),
            complete.index("try saveRegisteredCredential(registered, pending)"),
        )
        self.assertIn("throw BillingClientError.installationChanged", bootstrap)
        self.assertIn("SecItemAdd", keychain)
        self.assertIn("case errSecDuplicateItem", keychain)
        self.assertIn("return winner", keychain)
        pending_insert = keychain[
            keychain.index("static func insertPendingIfAbsent("):
            keychain.index("static func saveRegistered(")
        ]
        self.assertNotIn("SecItemUpdate", pending_insert)
        registration = keychain[
            keychain.index("static func saveRegistered("):
            keychain.index("private static func itemQuery(")
        ]
        self.assertLess(
            registration.index("guard current == pending"),
            registration.index("SecItemUpdate"),
        )
        self.assertIn(".withoutOverwriting", keychain)
        self.assertNotIn(".atomic", keychain)
        self.assertIn("if let winner = try loadIfPresent(at: url)", keychain)
        self.assertNotIn("SecItemDelete", keychain)

        app = source("NekoWidget/App/NekoWidgetApp.swift")
        self.assertNotIn("BillingAccountBootstrapCoordinator", app)
        self.assertNotIn("URLSessionBillingAPIClient", app)
        self.assertNotIn("BillingFreshAccountAuthorizer", app)

    def test_wire_contract_and_ack_are_fail_closed(self) -> None:
        core = source("NekoWidget/Services/BillingClientCore.swift")
        client = source("NekoWidget/Services/BillingAPIClient.swift")
        self.assertIn('"NWB1.ACCOUNT.CREATE"', core)
        self.assertIn('"NWB1.REQUEST"', core)
        self.assertIn("case candidate", core)
        self.assertIn("case nonEntitling", core)
        self.assertIn("It is not, by itself, an active Plus entitlement", core)
        self.assertIn(
            'static let entitlementPath = "/v1/billing/entitlement"',
            core,
        )
        self.assertIn(
            '(method == "GET" && pathname == entitlementPath)',
            core,
        )

        provisional = core[
            core.index("struct BillingProvisionalEntitlement:"):
            core.index("struct BillingTransactionRecordAcknowledgement:")
        ]
        self.assertIn("case activeCandidate", core)
        self.assertIn("case noActiveCandidate", core)
        self.assertIn("provisional,", provisional)
        self.assertIn("!grantsPlus", provisional)
        self.assertIn("BillingValidation.productID(productId)", provisional)
        self.assertIn("expiresDateMs > evaluatedAtMs", provisional)
        self.assertIn("productId == nil, expiresDateMs == nil", provisional)

        self.assertIn("response.recorded", client)
        self.assertIn("expectedTransactionID", client)
        self.assertIn("expectedOriginalTransactionID", client)
        self.assertIn("func fetchAuthoritativeEntitlement(", client)
        self.assertIn("case .authoritativeEntitlement: return \"GET\"", client)
        self.assertIn("endpoint: .authoritativeEntitlement", client)
        self.assertIn("body: Data()", client)
        self.assertIn("response.billingAccountId == billingAccountID", client)
        api_actor = client.index("actor URLSessionBillingAPIClient")
        transaction = client[
            client.index("func recordTransaction(", api_actor):
            client.index("func fetchAuthoritativeEntitlement(", api_actor)
        ]
        self.assertIn("_ = try response.entitlement.validated()", transaction)
        self.assertNotIn("serverConfirmed", transaction)
        self.assertIn(
            "let entitlement: BillingProvisionalEntitlement",
            client,
        )
        authority = core[
            core.index("enum BillingAuthoritativeEntitlementStatus:"):
            core.index("struct BillingProvisionalEntitlement:")
        ]
        for status in (
            "active",
            "gracePeriod",
            "billingRetry",
            "expired",
            "revoked",
            "upgraded",
            "unconfirmed",
        ):
            self.assertIn(f"case {status}", authority)
        self.assertIn("!provisional", authority)
        self.assertIn("grantsPlus == status.grantsAccess", authority)
        self.assertIn("accessUntilMs > evaluatedAtMs", authority)
        self.assertIn("authorityStaleAtMs > evaluatedAtMs", authority)
        self.assertIn("min(accessUntilMs, authorityStaleAtMs)", authority)
        self.assertIn(
            "let entitlement: BillingAuthoritativeEntitlement",
            client,
        )
        self.assertIn("http.url == url", client)
        self.assertIn("completionHandler(nil)", client)
        self.assertIn("URLSessionConfiguration.ephemeral", client)


if __name__ == "__main__":
    unittest.main()
