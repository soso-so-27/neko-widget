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
        self.assertRegex(config, r"(?m)^PLUS_BILLING_RECOVERY_ENABLED = NO$")
        self.assertRegex(
            config,
            r"(?m)^PLUS_WINDOW_SPONSORSHIP_CLIENT_ENABLED = NO$",
        )

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
        self.assertEqual(
            info["PlusBillingRecoveryEnabled"],
            "$(PLUS_BILLING_RECOVERY_ENABLED)",
        )
        self.assertEqual(
            info["PlusWindowSponsorshipClientEnabled"],
            "$(PLUS_WINDOW_SPONSORSHIP_CLIENT_ENABLED)",
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

        # The sponsorship bridge must use the existing participant credential
        # to sign its participant-scoped GET/owner consent. The independent
        # billing identity, Keychain material, and StoreKit authorizer remain
        # free of pairing/window secrets.
        combined = "\n".join(
            source(f"NekoWidget/Services/{name}")
            for name in (
                "BillingClientCore.swift",
                "BillingKeychainStore.swift",
                "BillingFreshAccountAuthorization.swift",
            )
        )
        for forbidden in (
            "PairingCredential",
            "SharedContainer",
            "UserDefaults",
            "@AppStorage",
        ):
            self.assertNotIn(forbidden, combined)
        client = source("NekoWidget/Services/BillingAPIClient.swift")
        sponsorship = client[
            client.index("struct BillingWindowOwnerConsentContext"):
            client.index("actor PlusBillingSession")
        ]
        self.assertIn("PairingCredential", sponsorship)
        for forbidden in ("roomKey", "agreementPrivateKey", "Photo"):
            self.assertNotIn(forbidden, sponsorship)

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
        bootstrap_keychain = keychain[:keychain.index(
            "static func loadRecoveryAttempt()"
        )]
        self.assertNotIn("SecItemDelete", bootstrap_keychain)

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
        self.assertIn(
            "case .authoritativeEntitlement, .windowSponsorshipGrant: return \"GET\"",
            client,
        )
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

    def test_explicit_account_recovery_is_device_bound_and_crash_resumable(self) -> None:
        core = source("NekoWidget/Services/BillingClientCore.swift")
        client = source("NekoWidget/Services/BillingAPIClient.swift")
        storekit = source(
            "NekoWidget/Services/BillingFreshAccountAuthorization.swift"
        )
        keychain = source("NekoWidget/Services/BillingKeychainStore.swift")
        plus = source("NekoWidget/Services/PlusPurchaseStore.swift")
        app = source("NekoWidget/App/NekoWidgetApp.swift")

        self.assertIn(
            'static let accountRecoveryPath = "/v1/billing/accounts/recover"',
            core,
        )
        transcript = core[
            core.index("static func accountRecoveryTranscript("):
            core.index("static func signedRequestTranscript(")
        ]
        transcript_fields = transcript[transcript.index(
            "return try encodeCanonicalFields(["
        ):]
        ordered_fields = (
            '"NWB1.ACCOUNT.RECOVER"',
            "attempt.clientRequestID",
            "attempt.billingAccountID",
            "signingPublicKey",
            "evidence.deviceVerificationID",
            "attempt.appTransactionID",
            "attempt.expectedTransactionID",
            "attempt.expectedOriginalTransactionID",
            "sha256(Data(evidence.signedAppTransactionInfo.utf8))",
            "sha256(Data(evidence.signedTransactionInfo.utf8))",
        )
        positions = [transcript_fields.index(field) for field in ordered_fields]
        self.assertEqual(positions, sorted(positions))

        attempt = core[
            core.index("struct BillingAccountRecoveryAttempt:"):
            core.index("struct BillingAccountRecoveryResult:")
        ]
        for persisted in (
            "clientRequestID",
            "signingPrivateKey",
            "billingAccountID",
            "deviceVerificationID",
            "appTransactionID",
            "signedAppTransactionInfo",
            "signedTransactionInfo",
            "expectedTransactionID",
            "expectedOriginalTransactionID",
        ):
            self.assertIn(f"var {persisted}:", attempt)
        self.assertIn("func matchesCurrentAccount(", attempt)
        self.assertIn("func matchesExactWireEvidence(", attempt)
        current_match = attempt[
            attempt.index("func matchesCurrentAccount("):
            attempt.index("func matchesExactWireEvidence(")
        ]
        self.assertNotIn("expectedTransactionID ==", current_match)
        self.assertNotIn("signedTransactionInfo ==", current_match)
        exact_match = attempt[
            attempt.index("func matchesExactWireEvidence("):
            attempt.index("var persistedEvidence:")
        ]
        self.assertIn("signedAppTransactionInfo", exact_match)
        self.assertIn("signedTransactionInfo", exact_match)
        self.assertIn("expectedTransactionID", exact_match)

        collector = storekit[
            storekit.index("actor BillingStoreKitRecoveryEvidenceCollector"):
        ]
        self.assertIn("func collectForExplicitRecovery()", collector)
        self.assertIn("try await AppTransaction.shared", collector)
        self.assertIn("try await AppTransaction.refresh()", collector)
        self.assertNotIn("AppStore.sync", collector.replace(
            "AppStore.sync() is intentionally never used here.", ""
        ))
        self.assertIn("AppStore.deviceVerificationID", collector)
        self.assertIn("SHA384.hash", collector)
        self.assertIn("nonce.uuidString.lowercased()", collector)
        self.assertIn("deviceVerificationID.uuidString.lowercased()", collector)
        self.assertGreaterEqual(collector.count("verifyDeviceBinding("), 3)
        self.assertIn("Transaction.currentEntitlements", collector)
        self.assertIn("transaction.ownershipType == .purchased", collector)
        self.assertIn("transaction.revocationDate == nil", collector)
        self.assertIn("!transaction.isUpgraded", collector)
        self.assertIn("purchases.count == 1", collector)
        self.assertIn("purchase.value.appTransactionID", collector)
        self.assertIn("appTransaction.value.appTransactionID", collector)

        coordinator = client[
            client.index("actor BillingAccountRecoveryCoordinator"):
            client.index("struct BillingWindowOwnerConsentContext")
        ]
        self.assertIn("configuration.isEnabled", coordinator)
        self.assertIn("recoverFromExplicitUserAction", coordinator)
        self.assertIn("insertRecoveryAttempt(candidate)", coordinator)
        self.assertIn("attempt.persistedEvidence", coordinator)
        self.assertLess(
            coordinator.index("insertRecoveryAttempt(candidate)"),
            coordinator.index("apiClient.recoverAccount("),
        )
        self.assertLess(
            coordinator.index("apiClient.recoverAccount("),
            coordinator.index("saveRecoveredCredential(registered"),
        )
        rejection = coordinator[
            coordinator.index("} catch let error as BillingClientError {"):
            coordinator.index("let registered = try attempt.registering(")
        ]
        self.assertIn("[400, 401, 409].contains(status)", rejection)
        self.assertIn("try deleteRecoveryAttempt(attempt)", rejection)
        self.assertNotIn("Pairing", coordinator)
        self.assertNotIn("Moment", coordinator)
        self.assertNotIn("Photo", coordinator)

        self.assertIn(
            '"jp.nekowidget.billing.recovery-attempt.v1.host"',
            keychain,
        )
        recovery_storage = keychain[
            keychain.index("static func insertRecoveryAttemptIfAbsent("):
            keychain.index("private static func withLock")
        ]
        self.assertIn("kSecAttrAccessibleWhenUnlockedThisDeviceOnly", recovery_storage)
        self.assertIn("kSecAttrSynchronizable", recovery_storage)
        self.assertIn("SecItemAdd", recovery_storage)
        cas_delete = keychain[
            keychain.index("static func deleteRecoveryAttempt("):
            keychain.index("static func saveRecoveredCredential(")
        ]
        self.assertLess(
            cas_delete.index("guard current == expected"),
            cas_delete.index("SecItemDelete"),
        )
        self.assertIn("SecItemDelete(recoveryItemQuery()", recovery_storage)
        self.assertIn("removeRecoveryAttemptIfCommitted", keychain)

        recovery_api = client[
            client.index("func recoverAccount(", client.index(
                "actor URLSessionBillingAPIClient"
            )):
            client.index("func recordTransaction(", client.index(
                "actor URLSessionBillingAPIClient"
            ))
        ]
        for field in (
            "deviceVerificationId",
            "expectedAppTransactionId",
            "signedAppTransactionInfo",
            "signedTransactionInfo",
            "expectedTransactionId",
            "expectedOriginalTransactionId",
            "recoverySignature",
        ):
            self.assertIn(field, recovery_api)
        self.assertIn("authentication: .none", recovery_api)
        self.assertNotIn("timestamp", recovery_api)
        self.assertNotIn("nonce", recovery_api.lower())
        self.assertIn("response.clientRequestId", recovery_api)
        self.assertIn("response.billingAccountId", recovery_api)

        self.assertNotIn("recoverBillingAccountExplicitly", plus)
        self.assertNotIn("recoverBillingAccountExplicitly", app)
        self.assertNotIn("BillingAccountRecoveryCoordinator", app)

    def test_disabled_window_sponsorship_client_matches_server_contract(self) -> None:
        core = source("NekoWidget/Services/BillingClientCore.swift")
        client = source("NekoWidget/Services/BillingAPIClient.swift")
        keychain = source("NekoWidget/Services/BillingKeychainStore.swift")
        plus = source("NekoWidget/Services/PlusPurchaseStore.swift")
        app = source("NekoWidget/App/NekoWidgetApp.swift")

        self.assertIn(
            'static let windowSponsorshipGrantPath = "/v1/window-sponsorship"',
            core,
        )
        self.assertIn(
            '"/v1/billing/window-sponsorships/"',
            core,
        )
        self.assertIn("case windowSponsorshipOwnerDetach", client)
        self.assertIn("case .windowSponsorshipOwnerDetach: return \"DELETE\"", client)

        transcript = core[
            core.index("static func windowSponsorshipOwnerConsentTranscript("):
            core.index("static func signedRequestTranscript(")
        ]
        transcript = transcript[
            transcript.index("return try encodeCanonicalFields(["):
        ]
        ordered = (
            '"NWB1.WINDOW.SPONSORSHIP"',
            "BillingWindowSponsorshipOperation.sponsor.rawValue",
            "clientRequestID",
            "billingAccountID",
            "windowLineageID",
            "String(expectedGeneration)",
            'expectedCurrentBillingAccountID ?? ""',
            "consentSpaceID",
            "ownerParticipantID",
            "ownerDeviceID",
            "String(consentIssuedAt)",
            "String(consentMembershipRevision)",
            "ownerConsentNonce",
        )
        positions = [transcript.index(field) for field in ordered]
        self.assertEqual(positions, sorted(positions))

        attempt = core[
            core.index("struct BillingWindowSponsorshipAttempt:"):
            core.index("struct BillingWindowOwnerDetachResult:")
        ]
        for field in (
            "clientRequestID",
            "billingAccountID",
            "windowLineageID",
            "expectedGeneration",
            "expectedCurrentBillingAccountID",
            "exactRequestBody",
        ):
            self.assertIn(f"var {field}:", attempt)
        self.assertIn("func matchesStableIntent(", attempt)
        self.assertIn("try encode(body) == data", core)
        self.assertIn(
            "try container.encodeNil(forKey: .expectedCurrentBillingAccountId)",
            core,
        )
        for wire_field in (
            "consentSpaceId",
            "ownerParticipantId",
            "ownerDeviceId",
            "consentMembershipRevision",
            "consentIssuedAt",
            "ownerConsentNonce",
            "ownerConsentSignature",
        ):
            self.assertIn(wire_field, core)

        grant = core[
            core.index("struct BillingWindowSponsorshipGrant:"):
            core.index("struct BillingWindowSponsorshipChangeResult:")
        ]
        for state in (
            "unknown",
            "unsponsored",
            "sponsoredWithoutCurrentAccess",
            "active",
            "offlineGrace",
            "expired",
        ):
            self.assertIn(f"case {state}", grant)
        self.assertIn("let generation: Int", grant)
        self.assertIn("accessUntilMs - evaluatedAtMs", grant)
        self.assertIn("offlineGraceDurationMs = 24 * 60 * 60 * 1_000", grant)
        self.assertIn("let activeUntilMs = min(", grant)
        self.assertIn("evaluatedAtMs + Self.offlineGraceDurationMs", grant)
        self.assertIn("lastConfirmed: BillingWindowSponsorshipGrant?", grant)

        owner_detach = core[
            core.index("struct BillingWindowOwnerDetachAttempt:"):
            core.index("struct BillingWindowSponsorWireRequest:")
        ]
        self.assertIn("var deviceID: String?", owner_detach)
        self.assertNotIn("ownerParticipantID", owner_detach)
        self.assertNotIn("ownerDeviceID", owner_detach)

        coordinator = client[
            client.index("actor BillingWindowSponsorshipCoordinator"):
            client.index("actor PlusBillingSession")
        ]
        self.assertIn("configuration.isEnabled", coordinator)
        self.assertIn("fetchGrantFromExplicitUserAction", coordinator)
        self.assertIn("sponsorFromExplicitUserAction", coordinator)
        self.assertIn("unsponsorAsPayerFromExplicitUserAction", coordinator)
        self.assertIn("detachAsOwnerFromExplicitUserAction", coordinator)
        self.assertIn("PairingCrypto.sign(", coordinator)
        self.assertIn("insertAttempt(candidate)", coordinator)
        self.assertLess(
            coordinator.index("insertAttempt(candidate)"),
            coordinator.index("apiClient.changeWindowSponsorship("),
        )
        self.assertIn("insertOwnerDetachAttempt(candidate)", coordinator)
        self.assertLess(
            coordinator.index("insertOwnerDetachAttempt(candidate)"),
            coordinator.index("apiClient.detachWindowSponsorshipAsOwner("),
        )
        self.assertIn("case .transportUnavailable", coordinator)
        self.assertIn("reason = .offline", coordinator)
        self.assertIn("return preserved.offlineAccessState(now: now)", coordinator)
        self.assertIn("lastConfirmed: preserved", coordinator)
        self.assertIn("let ownerDeviceID = owner.deviceID", coordinator)
        self.assertNotIn("credential.deviceID ??", coordinator)

        api = client[client.index("actor URLSessionBillingAPIClient"):]
        self.assertIn("authentication: .billing(credential)", api)
        self.assertIn("authentication: .participant(", api)
        for header in (
            "Neko-Billing-Protocol-Version",
            "Neko-Billing-Nonce",
            "Neko-Billing-Signature",
            "Neko-Protocol-Version",
            "Neko-Member-ID",
            "Neko-Nonce",
            "Neko-Signature",
        ):
            self.assertIn(header, api)
        self.assertIn("PairingCrypto.sha256(body)", api)

        for service in (
            "window-sponsorship-attempt.v1.host",
            "window-owner-detach-attempt.v1.host",
        ):
            self.assertIn(service, keychain)
        sponsorship_storage = keychain[
            keychain.index("static func insertWindowSponsorshipAttemptIfAbsent("):
            keychain.index("private static func loadRecoveryAttemptUnlocked(")
        ]
        self.assertIn("SecItemAdd", sponsorship_storage)
        self.assertIn("case errSecDuplicateItem", sponsorship_storage)
        self.assertIn("guard current == expected", sponsorship_storage)
        self.assertIn("SecItemDelete", sponsorship_storage)
        self.assertIn("kSecAttrAccessibleWhenUnlockedThisDeviceOnly", keychain)
        self.assertIn("kSecAttrSynchronizable", keychain)

        for disconnected in (plus, app):
            self.assertNotIn("BillingWindowSponsorshipCoordinator", disconnected)
            self.assertNotIn("fetchWindowSponsorshipGrant", disconnected)
            self.assertNotIn("detachAsOwnerFromExplicitUserAction", disconnected)
        self.assertNotIn("AppStore.sync", coordinator)
        for forbidden in ("roomKey", "agreementPrivateKey", "Photo"):
            self.assertNotIn(forbidden, coordinator)


if __name__ == "__main__":
    unittest.main()
