import Foundation
import CryptoKit
import StoreKit

/// A short-lived capability proving that StoreKit's complete current-
/// entitlement sequence was scanned for the configured Plus products and no
/// verified or unverified matching transaction was present.
struct BillingFreshAccountAuthorization: Sendable {
    private let expiresAt: ContinuousClock.Instant
    private let scanNonce: UUID

    fileprivate init(validFor lifetime: Duration) {
        expiresAt = ContinuousClock().now.advanced(by: lifetime)
        scanNonce = UUID()
    }

    func validatedForBootstrap() throws {
        _ = scanNonce
        guard ContinuousClock().now < expiresAt else {
            throw BillingClientError.freshAccountAuthorizationExpired
        }
    }
}

/// The sole factory for a fresh-account authorization. It intentionally reads
/// the non-injectable bundle configuration and StoreKit sequence so callers
/// cannot omit a product or substitute a sequence that hides a purchase.
actor BillingFreshAccountAuthorizer {
    private static let authorizationLifetime: Duration = .seconds(30)

    func authorizeAfterCurrentEntitlementScan()
        async throws -> BillingFreshAccountAuthorization {
        let configuration = PlusPurchaseConfiguration.current
        guard configuration.isConfigured else {
            throw BillingClientError.configurationUnavailable
        }
        let configuredProductIDs = Set(configuration.productIDs)
        guard !configuredProductIDs.isEmpty else {
            throw BillingClientError.configurationUnavailable
        }

        try Task.checkCancellation()
        for await result in Transaction.currentEntitlements {
            try Task.checkCancellation()
            let transaction: Transaction
            switch result {
            case let .verified(value):
                transaction = value
            case let .unverified(value, _):
                transaction = value
            }
            if configuredProductIDs.contains(transaction.productID) {
                // Both verified ownership and unverifiable matching evidence
                // must enter explicit JWS-backed recovery. Neither authorizes
                // creation of a second billing account.
                throw BillingClientError.billingAccountRecoveryRequired
            }
        }
        try Task.checkCancellation()
        return BillingFreshAccountAuthorization(
            validFor: Self.authorizationLifetime
        )
    }
}

/// Collects proof for one explicit billing-account recovery. This actor is not
/// constructed or called during launch, foreground refresh, or ordinary
/// entitlement reconciliation. `AppTransaction.refresh()` is used only as the
/// documented fallback after the cached value is unavailable or unverified;
/// it may present App Store authentication and therefore belongs behind a
/// future user-initiated recovery button.
actor BillingStoreKitRecoveryEvidenceCollector {
    private struct VerifiedAppTransaction {
        let value: AppTransaction
        let jwsRepresentation: String
    }

    private struct VerifiedPurchaseTransaction {
        let value: Transaction
        let jwsRepresentation: String
    }

    func collectForExplicitRecovery() async throws
        -> BillingStoreKitRecoveryEvidence {
        let configuration = PlusPurchaseConfiguration.current
        guard configuration.isConfigured else {
            throw BillingClientError.configurationUnavailable
        }
        guard let deviceVerificationID = AppStore.deviceVerificationID,
              BillingValidation.canonicalUUID(
                  deviceVerificationID.uuidString.lowercased()
              ) != nil
        else { throw BillingClientError.billingAccountRecoveryUnavailable }

        try Task.checkCancellation()
        let appTransaction = try await loadVerifiedAppTransactionExplicitly()
        try verifyDeviceBinding(
            nonce: appTransaction.value.deviceVerificationNonce,
            verification: appTransaction.value.deviceVerification,
            deviceVerificationID: deviceVerificationID
        )

        let expectedProductIDs = Set(configuration.productIDs)
        var purchases: [VerifiedPurchaseTransaction] = []
        for await result in Transaction.currentEntitlements {
            try Task.checkCancellation()
            switch result {
            case let .verified(transaction):
                guard expectedProductIDs.contains(transaction.productID) else {
                    continue
                }
                guard transaction.productType == .autoRenewable,
                      transaction.ownershipType == .purchased,
                      transaction.revocationDate == nil,
                      !transaction.isUpgraded,
                      transaction.expirationDate != nil
                else {
                    throw BillingClientError.billingAccountRecoveryUnavailable
                }
                try verifyDeviceBinding(
                    nonce: transaction.deviceVerificationNonce,
                    verification: transaction.deviceVerification,
                    deviceVerificationID: deviceVerificationID
                )
                purchases.append(VerifiedPurchaseTransaction(
                    value: transaction,
                    jwsRepresentation: result.jwsRepresentation
                ))
            case let .unverified(transaction, _):
                if expectedProductIDs.contains(transaction.productID) {
                    throw BillingClientError.billingAccountRecoveryUnavailable
                }
            }
        }
        try Task.checkCancellation()

        // Multiple current Plus transactions are ambiguous account evidence.
        // Never guess which lineage owns the account being recovered.
        guard purchases.count == 1, let purchase = purchases.first,
              let billingAccountID = purchase.value.appAccountToken,
              purchase.value.appTransactionID
                == appTransaction.value.appTransactionID
        else { throw BillingClientError.billingAccountRecoveryUnavailable }

        return try BillingStoreKitRecoveryEvidence(
            billingAccountID: billingAccountID.uuidString.lowercased(),
            deviceVerificationID: deviceVerificationID.uuidString.lowercased(),
            appTransactionID: appTransaction.value.appTransactionID,
            signedAppTransactionInfo: appTransaction.jwsRepresentation,
            signedTransactionInfo: purchase.jwsRepresentation,
            expectedTransactionID: String(purchase.value.id),
            expectedOriginalTransactionID: String(purchase.value.originalID)
        ).validated()
    }

    private func loadVerifiedAppTransactionExplicitly() async throws
        -> VerifiedAppTransaction {
        do {
            let shared = try await AppTransaction.shared
            if case let .verified(value) = shared {
                return VerifiedAppTransaction(
                    value: value,
                    jwsRepresentation: shared.jwsRepresentation
                )
            }
        } catch {
            try Task.checkCancellation()
        }

        // Apple documents refresh as a user-prompting fallback for an absent
        // or unverified shared app transaction. This explicit collector is the
        // only caller. AppStore.sync() is intentionally never used here.
        let refreshed = try await AppTransaction.refresh()
        guard case let .verified(value) = refreshed else {
            throw BillingClientError.billingAccountRecoveryUnavailable
        }
        return VerifiedAppTransaction(
            value: value,
            jwsRepresentation: refreshed.jwsRepresentation
        )
    }

    private func verifyDeviceBinding(
        nonce: UUID,
        verification: Data,
        deviceVerificationID: UUID
    ) throws {
        let target = nonce.uuidString.lowercased()
            + deviceVerificationID.uuidString.lowercased()
        let digest = Data(SHA384.hash(data: Data(target.utf8)))
        guard digest == verification else {
            throw BillingClientError.billingAccountRecoveryUnavailable
        }
    }
}
