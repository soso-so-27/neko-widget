#!/usr/bin/env python3
"""11/21c: Plus purchase bugs (source-level pins; no compiler on this lane)."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
STORE = (ROOT / "NekoWidget/Services/PlusPurchaseStore.swift").read_text(encoding="utf-8")
CORE = (ROOT / "NekoWidget/Services/BillingClientCore.swift").read_text(encoding="utf-8")
SERVER_AUTH = (ROOT / "SharingService/src/billing-auth.ts").read_text(encoding="utf-8")
CLIENT = (ROOT / "NekoWidget/Services/BillingAPIClient.swift").read_text(encoding="utf-8")
KEYCHAIN = (ROOT / "NekoWidget/Services/BillingKeychainStore.swift").read_text(encoding="utf-8")
OFFER = (ROOT / "NekoWidget/Services/MembershipOfferModel.swift").read_text(encoding="utf-8")
SERVER_BILLING = (ROOT / "SharingService/src/billing.ts").read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


class DeviceClockBehindServerTests(unittest.TestCase):
    """A slightly slow iPhone clock must not make a paid member not Plus."""

    def setUp(self) -> None:
        self.entitlement = section(STORE, "struct PlusVerifiedEntitlement", "enum PlusEntitlementState")
        self.authority = section(STORE, "private func refreshServerAuthority() async",
                                 "private func markServerConfirmationIndeterminate()")

    def test_bound_matches_protocol_and_server_window(self) -> None:
        self.assertIn("static let maximumDeviceClockLag: TimeInterval = 5 * 60", self.entitlement)
        self.assertIn("private static let maximumClockSkewMs = 5 * 60 * 1_000", CORE)
        self.assertIn("Math.abs(now - timestamp) > 300", SERVER_AUTH)

    def test_server_times_move_back_by_the_lag_never_forward(self) -> None:
        received = section(self.entitlement, "static func received(", "\n    }\n")
        self.assertIn("guard lag.isFinite, lag <= maximumDeviceClockLag else { return nil }", received)
        self.assertIn("let shift = max(0, lag)", received)
        self.assertEqual(received.count("addingTimeInterval(-shift)"), 3)
        self.assertNotIn("+ shift", received)
        self.assertNotIn("addingTimeInterval(shift)", received)
        for rounding in ("rounded", "ceil(", "floor(", ".up", ".down"):
            self.assertNotIn(rounding, received)
        self.assertIn("Double(accessUntilMs) / 1_000", received)
        self.assertIn("Double(authorityStaleAtMs) / 1_000", received)
        self.assertIn("monotonicDeadline: receivedInstant.advanced(by: .seconds(remaining))", received)

    def test_usable_keeps_rollback_rule_and_adds_monotonic_deadline(self) -> None:
        usable = section(self.entitlement, "func isUsable(at date: Date = .now) -> Bool {", "\n    }\n")
        self.assertIn("ContinuousClock.now >= monotonicDeadline { return false }", usable)
        self.assertIn("status.grantsAccess && date >= serverEvaluatedAt && expirationDate > date", usable)

    def test_shift_only_after_validation_and_beyond_bound_is_not_a_denial(self) -> None:
        validated = self.authority.index("let authority = try response.validated()")
        identity = self.authority.index("throw BillingClientError.credentialChanged")
        shifted = self.authority.index("PlusVerifiedEntitlement.received(")
        granted = self.authority.index("entitlementState = .serverConfirmed(entitlement)")
        self.assertLess(validated, shifted)
        self.assertLess(identity, shifted)
        self.assertLess(shifted, granted)
        beyond = self.authority[shifted:self.authority.index("guard entitlement.isUsable() else {")]
        self.assertIn("markServerConfirmationIndeterminate()", beyond)
        self.assertIn("return .indeterminate", beyond)
        self.assertNotIn(".serverConfirmed", beyond)
        # The old 0-second construction from raw server times is gone.
        self.assertNotIn("serverEvaluatedAt: Date(timeIntervalSince1970: Double(authority.evaluatedAtMs)", STORE)
        # The cache gets the same receipt time the shift used.
        self.assertIn("serverEvaluatedAt: entitlement.serverEvaluatedAt, receivedAt: receivedAt)", self.authority)

    def test_cached_answer_is_also_bounded_by_the_monotonic_clock(self) -> None:
        restore = section(STORE, "private func restoreCachedAuthority(", "private func hasKnownCacheIdentityChange(")
        self.assertIn("min(authority.accessUntil, authority.authorityStaleAt).timeIntervalSinceNow", restore)
        self.assertIn("monotonicDeadline: ContinuousClock.now.advanced(by: .seconds(remaining))", restore)
        self.assertIn("accessUntilDate: authority.accessUntil, authorityStaleAt: authority.authorityStaleAt", restore)


class AskToBuyPendingTests(unittest.TestCase):
    """Ask to Buy waiting survives relaunch, and always ends."""

    def test_record_has_apple_lifetime_and_clock_rollback_ends_it(self) -> None:
        record = section(STORE, "struct PlusAskToBuyPendingRecord", "@MainActor\nfinal class PlusPurchaseStore")
        self.assertIn("static let lifetime: TimeInterval = 24 * 60 * 60", record)
        self.assertIn("age.isFinite && age >= 0 && age < lifetime", record)
        self.assertNotIn("grants", record.replace("never grants Plus", ""))

    def test_pending_flag_persists_through_one_setter(self) -> None:
        self.assertRegex(STORE, r"@Published private\(set\) var pendingProductID: String\? \{\s*"
                                r"didSet \{ if pendingProductID != oldValue \{ persistPendingAskToBuy\(\) \} \}")
        persist = section(STORE, "private func persistPendingAskToBuy() {", "private func restorePendingAskToBuy()")
        self.assertIn("let since = pendingAskToBuySince ?? Date()", persist)
        self.assertEqual(persist.count("if usesLiveCache {"), 2)
        self.assertIn("PlusAskToBuyPendingRecord.clear()", persist)

    def test_restored_at_launch_with_its_first_time_and_expires(self) -> None:
        start = section(STORE, "private func performStart() async {", "func refreshAfterForegroundEntry()")
        self.assertLess(start.index("restorePendingAskToBuy()"), start.index("startTransactionUpdatesListener()"))
        self.assertLess(start.index("restorePendingAskToBuy()"), start.index("await reconcileCurrentEntitlements()"))
        restore = section(STORE, "private func restorePendingAskToBuy() {", "private func expirePendingAskToBuyIfDue()")
        self.assertIn("configuration.plan(for: record.productID) != nil", restore)
        self.assertIn("PlusAskToBuyPendingRecord.isCurrent(since: record.since, now: Date())", restore)
        self.assertLess(restore.index("pendingAskToBuySince = record.since"), restore.index("pendingProductID = record.productID"))
        reconcile = section(STORE, "private func performCurrentEntitlementReconciliation() async {",
                            "let scan = await scanCurrentEntitlements()")
        self.assertIn("expirePendingAskToBuyIfDue()", reconcile)
        expire = section(STORE, "private func expirePendingAskToBuyIfDue() {", "private func currentCacheContext(")
        self.assertIn("!PlusAskToBuyPendingRecord.isCurrent(since: since, now: Date())", expire)

    def test_purchase_still_blocks_while_pending(self) -> None:
        purchase = section(STORE, "    func purchase(\n", "static let serverConfirmationRecheckDelays")
        self.assertIn("pendingProductID == nil,", purchase)
        self.assertIn("pendingProductID = product.id", purchase)
        self.assertTrue(re.search(r"case \.pending:\s*pendingProductID = product\.id\s*return \.pending", purchase))


class ReinstallCanBuyAgainTests(unittest.TestCase):
    """A credential kept in the Keychain from an earlier installation."""

    def setUp(self) -> None:
        self.swap = section(KEYCHAIN, "static func replaceRetainedCredential(",
                            "static func loadRecoveryAttempt()")
        self.fresh = section(CLIENT, "private func loadOrCreateFreshCredential(", "private func resume(")

    def test_keychain_swap_is_compare_and_swap_under_the_lock(self) -> None:
        swap = self.swap
        self.assertIn("try withLock {", swap)
        self.assertIn("candidate.phase == .pendingBootstrap", swap)
        self.assertIn("retained.installationMarker != candidate.installationMarker", swap)
        # Idempotent: a winner for this installation is returned, not replaced.
        self.assertLess(swap.index("current.installationMarker == candidate.installationMarker"),
                        swap.index("guard current == retained else"))
        self.assertLess(swap.index("guard current == retained else"), swap.index("SecItemUpdate("))
        self.assertIn("throw BillingClientError.credentialChanged", swap)
        self.assertIn("guard try loadUnlocked() == candidate else", swap)
        for forbidden in ("SecItemDelete", "SecItemAdd", "registered", "billingAccountID"):
            self.assertNotIn(forbidden, swap)

    def test_fresh_path_replaces_only_after_the_no_purchase_proof(self) -> None:
        fresh = self.fresh
        same = fresh.index("guard try existing.validated().installationMarker != markerValue else {")
        self.assertLess(same, fresh.index("return try await resume(existing, markerValue: markerValue)"))
        proof = fresh.index("try authorization.validatedForBootstrap()")
        self.assertLess(proof, fresh.index("replaceRetainedCredential(retained, candidate)"))
        self.assertLess(proof, fresh.index("insertPendingCredential(candidate)"))
        self.assertIn("return try await resume(pending, markerValue: markerValue)", fresh)
        # Never re-bound: no credential is rewritten with this marker.
        self.assertNotIn("installationMarker = markerValue", fresh)
        self.assertNotIn("installationMarker: markerValue", fresh)
        resume = section(CLIENT, "private func resume(", "private func completeBootstrap(")
        self.assertIn("guard existing.installationMarker == markerValue else {", resume)
        self.assertIn("throw BillingClientError.installationChanged", resume)
        # A current purchase never reaches the swap: the scan sends it to recovery.
        authorizer = (ROOT / "NekoWidget/Services/BillingFreshAccountAuthorization.swift").read_text(encoding="utf-8")
        self.assertIn("throw BillingClientError.billingAccountRecoveryRequired", authorizer)
        prepare = section(CLIENT, "func prepareAccountForExplicitPurchase()", "func recordVerifiedTransactionEvent(")
        self.assertIn("error == .billingCredentialMissing || error == .installationChanged", prepare)
        self.assertIn(".authorizeAfterCurrentEntitlementScan()", prepare)
        # A createAccount lost after the swap is resumed with the same request.
        self.assertIn("const existing = await loadBootstrap(env, clientRequestId);", SERVER_BILLING)

    def test_store_offers_purchase_for_a_retained_credential_only_after_scan(self) -> None:
        fresh = section(STORE, "private func hasFreshLocalPurchaseEligibility() async -> Bool {",
                        "private func scanCurrentEntitlements()")
        retained = fresh.index("let retainedFromAnotherInstallation")
        self.assertLess(retained, fresh.index("if let existing, !retainedFromAnotherInstallation {"))
        self.assertLess(fresh.index("if let existing, !retainedFromAnotherInstallation {"),
                        fresh.index(".authorizeAfterCurrentEntitlementScan()"))
        self.assertIn("try authorization.validatedForBootstrap()", fresh)
        self.assertIn("guard try BillingKeychainStore.load() == existing,", fresh)

    def test_restore_without_any_purchase_is_nothing_to_restore(self) -> None:
        client = OFFER[OFFER.index("private final class MembershipStoreKitClient"):]
        restore = section(client, "func restore() async -> MembershipOfferActionResult {",
                          "private static func periodText(")
        catch = restore[restore.index("} catch {"):]
        self.assertIn("(error as? BillingClientError) == .billingAccountRecoveryUnavailable", catch)
        self.assertIn("BillingFreshAccountAuthorizer().authorizeAfterCurrentEntitlementScan()", catch)
        self.assertLess(catch.index("return .nothingToRestore"), catch.index("return .restoreFailed(.recovering(error))"))


if __name__ == "__main__":
    unittest.main()
