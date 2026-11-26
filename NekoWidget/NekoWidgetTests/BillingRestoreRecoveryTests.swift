import CryptoKit
import XCTest
@testable import NekoWidget

/// 11/26: 「購入を復元」 on an iPhone whose billing key was rotated away by a
/// recovery on another iPhone. Synthetic values only: no network, Keychain,
/// StoreKit or real identifiers.
final class BillingRestoreRecoveryTests: XCTestCase {
    private let marker = UUID()
    private let accountID = UUID().uuidString.lowercased()
    private static let oldKeyID = String(repeating: "A", count: 22)
    private static let newKeyID = String(repeating: "Q", count: 21) + "A"

    private func storedCredential() throws -> BillingCredential {
        try BillingCredential(
            phase: .registered,
            installationMarker: marker.uuidString.lowercased(),
            clientRequestID: UUID().uuidString.lowercased(),
            signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation,
            billingAccountID: accountID,
            billingKeyID: Self.oldKeyID
        ).validated()
    }

    private func evidence() throws -> BillingStoreKitRecoveryEvidence {
        try BillingStoreKitRecoveryEvidence(
            billingAccountID: accountID,
            deviceVerificationID: UUID().uuidString.lowercased(),
            appTransactionID: "1000000000000001",
            signedAppTransactionInfo: "aGVhZA.cGF5bG9hZA.c2ln",
            signedTransactionInfo: "aGVhZA.cGF5bG9hZA.c2ln",
            expectedTransactionID: "2000000000000002",
            expectedOriginalTransactionID: "2000000000000001"
        ).validated()
    }

    private func coordinator(
        _ api: FakeBillingAPI, keychain: FakeRecoveryKeychain
    ) throws -> BillingAccountRecoveryCoordinator {
        let evidence = try evidence()
        let marker = marker
        return BillingAccountRecoveryCoordinator(
            apiClient: api,
            configuration: BillingRecoveryConfiguration(isEnabled: true),
            loadCredential: { keychain.credential },
            insertRecoveryAttempt: { candidate in
                if let existing = keychain.attempt { return existing }
                keychain.attempt = candidate
                return candidate
            },
            saveRecoveredCredential: { registered, _, previous in
                guard keychain.credential == previous else {
                    throw BillingClientError.credentialChanged
                }
                keychain.credential = registered
                keychain.attempt = nil
            },
            removeCommittedAttempt: { _ in },
            deleteRecoveryAttempt: { _ in keychain.attempt = nil },
            loadInstallationMarker: { marker },
            collectEvidence: { evidence }
        )
    }

    /// The server's answer for a revoked key sends the explicit restore on to
    /// recovery, and the new key replaces the revoked one.
    func testRevokedKeyDuringExplicitRestoreRecoversAndReplacesTheKey() async throws {
        let stored = try storedCredential()
        let keychain = FakeRecoveryKeychain(credential: stored)
        let api = FakeBillingAPI(probeError: BillingClientError.requestRejected(
            status: 401, code: "invalid_billing_authentication"), newKeyID: Self.newKeyID)
        let recovered = try await coordinator(api, keychain: keychain).recoverFromExplicitUserAction()

        XCTAssertEqual(api.probes, 1)
        XCTAssertEqual(api.recoveries, 1)
        XCTAssertEqual(recovered.billingAccountID, accountID)
        XCTAssertEqual(recovered.billingKeyID, Self.newKeyID)
        XCTAssertNotEqual(recovered.signingPrivateKey, stored.signingPrivateKey)
        XCTAssertEqual(keychain.credential, recovered)
        XCTAssertNil(keychain.attempt)
    }

    /// Any other answer keeps the stored key and never recovers.
    func testOtherAnswersKeepTheStoredKeyWithoutRecovery() async throws {
        let others: [Error?] = [
            nil,
            BillingClientError.requestRejected(status: 401, code: "stale_billing_request"),
            BillingClientError.requestRejected(status: 409, code: "replayed_billing_request"),
            BillingClientError.requestRejected(status: 401, code: nil),
            BillingClientError.requestRejected(status: 429, code: "rate_limited"),
            BillingClientError.requestRejected(status: 503, code: "billing_nonce_unavailable"),
            BillingClientError.transportUnavailable,
        ]
        for probeError in others {
            let stored = try storedCredential()
            let keychain = FakeRecoveryKeychain(credential: stored)
            let api = FakeBillingAPI(probeError: probeError, newKeyID: Self.newKeyID)
            let result = try await coordinator(api, keychain: keychain).recoverFromExplicitUserAction()
            XCTAssertEqual(result, stored, "\(String(describing: probeError))")
            XCTAssertEqual(keychain.credential, stored)
            XCTAssertEqual(api.recoveries, 0, "\(String(describing: probeError))")
        }
    }

    func testOnlyTheRevokedKeyAnswerCountsAsKeyNoLongerActive() {
        XCTAssertTrue(BillingCredentialRejection.keyNoLongerActive(
            BillingClientError.requestRejected(status: 401, code: "invalid_billing_authentication")))
        XCTAssertFalse(BillingCredentialRejection.keyNoLongerActive(
            BillingClientError.requestRejected(status: 401, code: "stale_billing_request")))
        XCTAssertFalse(BillingCredentialRejection.keyNoLongerActive(
            BillingClientError.requestRejected(status: 409, code: "replayed_billing_request")))
        XCTAssertFalse(BillingCredentialRejection.keyNoLongerActive(
            BillingClientError.requestRejected(status: 403, code: "invalid_billing_authentication")))
        XCTAssertFalse(BillingCredentialRejection.keyNoLongerActive(BillingClientError.transportUnavailable))
    }
}

private final class FakeRecoveryKeychain: @unchecked Sendable {
    var credential: BillingCredential?
    var attempt: BillingAccountRecoveryAttempt?
    init(credential: BillingCredential?) { self.credential = credential }
}

private struct FakeUnused: Error {}

private final class FakeBillingAPI: BillingAPIClientProtocol, @unchecked Sendable {
    let probeError: Error?
    let newKeyID: String
    var probes = 0
    var recoveries = 0

    init(probeError: Error?, newKeyID: String) {
        self.probeError = probeError
        self.newKeyID = newKeyID
    }

    func fetchAuthoritativeEntitlement(
        credential: BillingCredential
    ) async throws -> BillingAuthoritativeEntitlement {
        probes += 1
        if let probeError { throw probeError }
        return BillingAuthoritativeEntitlement(
            status: .active, productId: nil, accessUntilMs: nil, authorityStaleAtMs: nil,
            evaluatedAtMs: 1, provisional: false, grantsPlus: true)
    }

    func recoverAccount(
        attempt: BillingAccountRecoveryAttempt,
        evidence: BillingStoreKitRecoveryEvidence
    ) async throws -> BillingAccountRecoveryResult {
        recoveries += 1
        return BillingAccountRecoveryResult(
            clientRequestID: attempt.clientRequestID,
            billingAccountID: attempt.billingAccountID,
            billingKeyID: newKeyID,
            recoveredAt: 1)
    }

    func createAccount(credential: BillingCredential) async throws -> BillingAccountBootstrapResult {
        throw FakeUnused()
    }

    func recordTransaction(
        signedTransactionInfo: String, expectedTransactionID: String,
        expectedOriginalTransactionID: String, credential: BillingCredential
    ) async throws -> BillingTransactionRecordAcknowledgement {
        throw FakeUnused()
    }

    func fetchWindowSponsorshipGrant(
        memberID: String, credential: PairingCredential
    ) async throws -> BillingWindowSponsorshipReadResult {
        throw FakeUnused()
    }

    func changeWindowSponsorship(
        attempt: BillingWindowSponsorshipAttempt, payerCredential: BillingCredential
    ) async throws -> BillingWindowSponsorshipChangeResult {
        throw FakeUnused()
    }

    func detachWindowSponsorshipAsOwner(
        attempt: BillingWindowOwnerDetachAttempt, credential: PairingCredential
    ) async throws -> BillingWindowOwnerDetachResult {
        throw FakeUnused()
    }
}
