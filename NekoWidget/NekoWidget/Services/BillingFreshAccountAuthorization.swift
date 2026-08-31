import Foundation
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
