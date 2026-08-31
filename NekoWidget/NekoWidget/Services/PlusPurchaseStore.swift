import Combine
import Foundation
import StoreKit

/// A pseudonymous purchase correlation identifier. It is deliberately not a
/// window participant, device, Keychain credential account, or window owner.
/// The future billing bootstrap owns creation/recovery of this value.
struct BillingAccountID: Equatable, Hashable, Sendable {
    let rawValue: UUID
}

enum PlusProductPlan: String, CaseIterable, Sendable {
    case annual
    case monthly

    fileprivate var sortOrder: Int {
        switch self {
        case .annual: 0
        case .monthly: 1
        }
    }
}

struct PlusPurchaseConfiguration: Equatable, Sendable {
    let isEnabled: Bool
    let monthlyProductID: String?
    let annualProductID: String?

    init(
        isEnabled: Bool,
        monthlyProductID: String?,
        annualProductID: String?
    ) {
        self.isEnabled = isEnabled
        self.monthlyProductID = Self.validatedProductID(monthlyProductID)
        self.annualProductID = Self.validatedProductID(annualProductID)
    }

    var isConfigured: Bool {
        guard isEnabled,
              let monthlyProductID,
              let annualProductID
        else { return false }
        return monthlyProductID != annualProductID
    }

    var productIDs: [String] {
        guard isConfigured,
              let monthlyProductID,
              let annualProductID
        else { return [] }
        return [annualProductID, monthlyProductID]
    }

    func productID(for plan: PlusProductPlan) -> String? {
        switch plan {
        case .annual: annualProductID
        case .monthly: monthlyProductID
        }
    }

    func plan(for productID: String) -> PlusProductPlan? {
        if productID == annualProductID { return .annual }
        if productID == monthlyProductID { return .monthly }
        return nil
    }

    static var current: Self {
        let info = Bundle.main.infoDictionary ?? [:]
        return Self(
            isEnabled: explicitFlag(info["PlusStorefrontEnabled"]),
            monthlyProductID: info["PlusMonthlyProductID"] as? String,
            annualProductID: info["PlusAnnualProductID"] as? String
        )
    }

    private static func validatedProductID(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.count <= 100,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("$("),
              value.unicodeScalars.allSatisfy({ scalar in
                  let codePoint = scalar.value
                  return (48 ... 57).contains(codePoint)
                      || (65 ... 90).contains(codePoint)
                      || (97 ... 122).contains(codePoint)
                      || codePoint == 45
                      || codePoint == 46
                      || codePoint == 95
              })
        else { return nil }
        return value
    }

    private static func explicitFlag(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return false
    }
}

struct PlusVerifiedEntitlement: Equatable, Sendable {
    let plan: PlusProductPlan
    let status: BillingAuthoritativeEntitlementStatus
    let accessUntilDate: Date
    let authorityStaleAt: Date

    /// Both Apple's access boundary and the server observation freshness bound
    /// are authoritative. Neither may be used to extend the other.
    var expirationDate: Date { min(accessUntilDate, authorityStaleAt) }

    func isUsable(at date: Date = .now) -> Bool {
        status.grantsAccess && expirationDate > date
    }
}

/// The purchase entitlement state. Even a server-confirmed purchase is not a
/// sponsorship for any particular window and must never delete existing data.
enum PlusEntitlementState: Equatable, Sendable {
    case disabled
    case checking
    case inactive
    case serverConfirmed(PlusVerifiedEntitlement)
    case indeterminate(lastServerConfirmed: PlusVerifiedEntitlement?)

    var lastServerConfirmed: PlusVerifiedEntitlement? {
        switch self {
        case let .serverConfirmed(entitlement): entitlement
        case let .indeterminate(lastServerConfirmed): lastServerConfirmed
        case .disabled, .checking, .inactive: nil
        }
    }

    var grantsPlus: Bool {
        switch self {
        case let .serverConfirmed(entitlement):
            return entitlement.isUsable()
        case .disabled, .checking, .inactive, .indeterminate:
            return false
        }
    }
}

enum PlusProductAvailability: Equatable, Sendable {
    case disabled
    case loading
    case available
    case unavailable
}

enum PlusPurchaseOutcome: Equatable, Sendable {
    case purchased
    case awaitingServerConfirmation
    case pending
    case cancelled
    case unavailable
    case verificationFailed
    case failed
}

enum PlusRestoreOutcome: Equatable, Sendable {
    case entitlementFound
    case nothingToRestore
    case indeterminate
    case unavailable
    case failed
}

/// Records every verified event for an expected product, including renewal,
/// revocation, upgrade and unsupported ownership. The server validates and
/// records the signed transaction idempotently; recording alone never grants
/// or withdraws the account entitlement.
struct PlusVerifiedTransactionEvent: Sendable {
    let transaction: Transaction
    /// The compact Apple-signed JWS from VerificationResult. The unsigned
    /// Transaction JSON representation is never an acceptable substitute.
    let signedTransactionInfo: String
}

typealias PlusVerifiedTransactionEventRecorder = @Sendable (
    _ event: PlusVerifiedTransactionEvent,
    _ billingAccountID: BillingAccountID
) async throws -> BillingTransactionRecordAcknowledgement

typealias PlusAuthoritativeEntitlementFetcher = @Sendable () async throws
    -> BillingAuthoritativeEntitlement

private enum PlusPurchaseRecordingFailure: Error {
    case invalidAcknowledgement
}

@MainActor
final class PlusPurchaseStore: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var productAvailability: PlusProductAvailability
    @Published private(set) var entitlementState: PlusEntitlementState
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published private(set) var pendingProductID: String?

    private struct EntitlementScan {
        var events: [PlusVerifiedTransactionEvent] = []
        var encounteredUnverifiedOrUnsupported = false
    }

    private enum ServerAuthorityRefresh {
        case confirmed
        case denied
        case indeterminate
    }

    private let configuration: PlusPurchaseConfiguration
    private let recordVerifiedTransactionEvent: PlusVerifiedTransactionEventRecorder?
    private let fetchAuthoritativeEntitlement: PlusAuthoritativeEntitlementFetcher?
    private var transactionUpdatesTask: Task<Void, Never>?
    private var hasStarted = false

    init(
        configuration: PlusPurchaseConfiguration = .current,
        recordVerifiedTransactionEvent: PlusVerifiedTransactionEventRecorder? = nil,
        fetchAuthoritativeEntitlement: PlusAuthoritativeEntitlementFetcher? = nil
    ) {
        self.configuration = configuration
        if recordVerifiedTransactionEvent == nil,
           fetchAuthoritativeEntitlement == nil,
           let liveSession = PlusBillingSession.configured(
               purchaseConfiguration: configuration
           ) {
            self.recordVerifiedTransactionEvent = { event, billingAccountID in
                try await liveSession.recordVerifiedTransactionEvent(
                    event,
                    billingAccountID: billingAccountID
                )
            }
            self.fetchAuthoritativeEntitlement = {
                try await liveSession.fetchAuthoritativeEntitlement()
            }
        } else {
            self.recordVerifiedTransactionEvent = recordVerifiedTransactionEvent
            self.fetchAuthoritativeEntitlement = fetchAuthoritativeEntitlement
        }
        if configuration.isEnabled {
            productAvailability = .loading
            entitlementState = .checking
        } else {
            productAvailability = .disabled
            entitlementState = .disabled
        }
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        guard configuration.isEnabled else {
            productAvailability = .disabled
            entitlementState = .disabled
            return
        }
        guard configuration.isConfigured else {
            productAvailability = .unavailable
            entitlementState = .indeterminate(lastServerConfirmed: nil)
            return
        }

        startTransactionUpdatesListener()
        await reconcileCurrentEntitlements()
        await loadProducts()
    }

    /// Reconciles time-sensitive subscription state after foreground entry.
    /// This remains a no-op while the source-controlled storefront flag is off.
    func refreshAfterForegroundEntry() async {
        guard hasStarted, configuration.isConfigured else { return }
        await reconcileCurrentEntitlements()
        if products.isEmpty {
            await loadProducts()
        }
    }

    func stop() {
        transactionUpdatesTask?.cancel()
        transactionUpdatesTask = nil
        hasStarted = false
    }

    /// This method is intentionally unreachable from the current UI. A future
    /// paywall must first obtain a stable BillingAccountID from the independent
    /// billing bootstrap and supply an idempotent server recorder.
    func purchase(
        _ plan: PlusProductPlan,
        billingAccountID: BillingAccountID
    ) async -> PlusPurchaseOutcome {
        guard configuration.isConfigured,
              recordVerifiedTransactionEvent != nil,
              fetchAuthoritativeEntitlement != nil,
              !isPurchasing,
              pendingProductID == nil,
              let productID = configuration.productID(for: plan),
              let product = products.first(where: { $0.id == productID })
        else { return .unavailable }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase(options: [
                .appAccountToken(billingAccountID.rawValue)
            ])
            switch result {
            case let .success(verification):
                switch verification {
                case let .verified(transaction):
                    guard isEligibleStoreKitTransaction(transaction),
                          transaction.appAccountToken == billingAccountID.rawValue
                    else {
                        entitlementState = .indeterminate(
                            lastServerConfirmed: entitlementState.lastServerConfirmed
                        )
                        return .verificationFailed
                    }
                    do {
                        try await recordVerifiedTransactionEvent(
                            PlusVerifiedTransactionEvent(
                                transaction: transaction,
                                signedTransactionInfo: verification.jwsRepresentation
                            ),
                            billingAccountID
                        )
                        await transaction.finish()
                        pendingProductID = nil
                        switch await refreshServerAuthority() {
                        case .confirmed:
                            return .purchased
                        case .denied, .indeterminate:
                            return .awaitingServerConfirmation
                        }
                    } catch {
                        markServerConfirmationIndeterminate()
                        return .awaitingServerConfirmation
                    }
                case .unverified:
                    entitlementState = .indeterminate(
                        lastServerConfirmed: entitlementState.lastServerConfirmed
                    )
                    return .verificationFailed
                }
            case .pending:
                pendingProductID = product.id
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    /// AppStore.sync can show Apple Account authentication. Call this only
    /// from an explicit future "購入を復元" action, never at launch. This scan
    /// may resume the billing credential already registered on this exact
    /// installation; it intentionally cannot claim an older account after a
    /// reinstall or on another iPhone until a dedicated recovery protocol is
    /// implemented.
    func restorePurchases() async -> PlusRestoreOutcome {
        guard configuration.isConfigured,
              recordVerifiedTransactionEvent != nil,
              fetchAuthoritativeEntitlement != nil,
              !isRestoring
        else { return .unavailable }

        isRestoring = true
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
        } catch {
            // Apple authentication/transport failure does not make a recent
            // server status invalid. It also cannot manufacture a grant: a
            // missing old-account credential stays indeterminate.
            switch await refreshServerAuthority() {
            case .confirmed:
                return .entitlementFound
            case .denied:
                return .nothingToRestore
            case .indeterminate:
                return .failed
            }
        }
        await reconcileCurrentEntitlements()
        switch entitlementState {
        case .serverConfirmed:
            return .entitlementFound
        case .inactive:
            return .nothingToRestore
        case .indeterminate, .checking:
            return .indeterminate
        case .disabled:
            return .unavailable
        }
    }

    private func loadProducts() async {
        productAvailability = .loading
        do {
            let fetched = try await Product.products(for: configuration.productIDs)
            let expectedIDs = Set(configuration.productIDs)
            let eligible = fetched.filter {
                expectedIDs.contains($0.id) && $0.type == .autoRenewable
            }
            guard Set(eligible.map(\.id)) == expectedIDs else {
                products = []
                productAvailability = .unavailable
                return
            }
            products = eligible.sorted { lhs, rhs in
                let left = configuration.plan(for: lhs.id)?.sortOrder ?? .max
                let right = configuration.plan(for: rhs.id)?.sortOrder ?? .max
                return left < right
            }
            productAvailability = .available
        } catch {
            products = []
            productAvailability = .unavailable
        }
    }

    private func startTransactionUpdatesListener() {
        guard transactionUpdatesTask == nil else { return }
        transactionUpdatesTask = Task { @MainActor [weak self] in
            for await update in Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.handleTransactionUpdate(update)
            }
        }
    }

    private func handleTransactionUpdate(
        _ result: VerificationResult<Transaction>
    ) async {
        switch result {
        case let .verified(transaction):
            guard configuration.plan(for: transaction.productID) != nil else { return }
            guard let billingToken = transaction.appAccountToken,
                  recordVerifiedTransactionEvent != nil,
                  fetchAuthoritativeEntitlement != nil
            else {
                entitlementState = .indeterminate(
                    lastServerConfirmed: entitlementState.lastServerConfirmed
                )
                return
            }
            do {
                // Non-entitling verified events must also reach the server so
                // refunds/upgrades withdraw access and family sharing is denied.
                try await recordVerifiedTransactionEvent(
                    PlusVerifiedTransactionEvent(
                        transaction: transaction,
                        signedTransactionInfo: result.jwsRepresentation
                    ),
                    BillingAccountID(rawValue: billingToken)
                )
                await transaction.finish()
                if pendingProductID == transaction.productID {
                    pendingProductID = nil
                }
                _ = await refreshServerAuthority()
            } catch {
                markServerConfirmationIndeterminate()
            }
        case let .unverified(transaction, _):
            guard configuration.plan(for: transaction.productID) != nil else { return }
            entitlementState = .indeterminate(
                lastServerConfirmed: entitlementState.lastServerConfirmed
            )
        }
    }

    private func reconcileCurrentEntitlements() async {
        let scan = await scanCurrentEntitlements()

        guard !scan.encounteredUnverifiedOrUnsupported else {
            markServerConfirmationIndeterminate()
            return
        }
        guard scan.events.isEmpty || recordVerifiedTransactionEvent != nil else {
            markServerConfirmationIndeterminate()
            return
        }

        do {
            for event in scan.events {
                let transaction = event.transaction
                guard let billingToken = transaction.appAccountToken else {
                    markServerConfirmationIndeterminate()
                    return
                }
                try await recordVerifiedTransactionEvent(
                    event,
                    BillingAccountID(rawValue: billingToken)
                )
                await transaction.finish()
            }
            pendingProductID = nil
            _ = await refreshServerAuthority()
        } catch {
            // Do not fetch after a newer StoreKit event failed to reach the
            // server; that could revive an older, now-revoked status.
            markServerConfirmationIndeterminate()
        }
    }

    @discardableResult
    private func refreshServerAuthority() async -> ServerAuthorityRefresh {
        guard let fetchAuthoritativeEntitlement else {
            markServerConfirmationIndeterminate()
            return .indeterminate
        }
        do {
            // Validate again even for injected clients. Only this response,
            // never a transaction-recording acknowledgement, may grant Plus.
            let response = try await fetchAuthoritativeEntitlement()
            let authority = try response.validated()
            if authority.status == .unconfirmed {
                markServerConfirmationIndeterminate()
                return .indeterminate
            }
            guard authority.status.grantsAccess else {
                entitlementState = .inactive
                return .denied
            }
            guard authority.grantsPlus,
                  let productID = authority.productId,
                  let plan = configuration.plan(for: productID),
                  let accessUntilMs = authority.accessUntilMs,
                  let authorityStaleAtMs = authority.authorityStaleAtMs
            else { throw BillingClientError.invalidServerResponse }

            let entitlement = PlusVerifiedEntitlement(
                plan: plan,
                status: authority.status,
                accessUntilDate: Date(
                    timeIntervalSince1970: Double(accessUntilMs) / 1_000
                ),
                authorityStaleAt: Date(
                    timeIntervalSince1970: Double(authorityStaleAtMs) / 1_000
                )
            )
            guard entitlement.isUsable() else {
                entitlementState = .inactive
                return .denied
            }
            entitlementState = .serverConfirmed(entitlement)
            return .confirmed
        } catch {
            markServerConfirmationIndeterminate()
            return .indeterminate
        }
    }

    private func markServerConfirmationIndeterminate() {
        entitlementState = .indeterminate(
            lastServerConfirmed: entitlementState.lastServerConfirmed
        )
    }

    private func scanCurrentEntitlements() async -> EntitlementScan {
        var scan = EntitlementScan()
        for await result in Transaction.currentEntitlements {
            switch result {
            case let .verified(transaction):
                if isEligibleStoreKitTransaction(transaction) {
                    scan.events.append(PlusVerifiedTransactionEvent(
                        transaction: transaction,
                        signedTransactionInfo: result.jwsRepresentation
                    ))
                } else if configuration.plan(for: transaction.productID) != nil {
                    scan.encounteredUnverifiedOrUnsupported = true
                }
            case let .unverified(transaction, _):
                if configuration.plan(for: transaction.productID) != nil {
                    scan.encounteredUnverifiedOrUnsupported = true
                }
            }
        }
        return scan
    }

    private func isEligibleStoreKitTransaction(
        _ transaction: Transaction
    ) -> Bool {
        guard configuration.plan(for: transaction.productID) != nil,
              transaction.productType == .autoRenewable,
              transaction.ownershipType == .purchased,
              transaction.revocationDate == nil,
              !transaction.isUpgraded,
              transaction.expirationDate != nil
        else { return false }
        return true
    }

    private func recordVerifiedTransactionEvent(
        _ event: PlusVerifiedTransactionEvent,
        _ billingAccountID: BillingAccountID
    ) async throws {
        guard let recordVerifiedTransactionEvent else {
            throw PlusPurchaseRecordingFailure.invalidAcknowledgement
        }
        let acknowledgement = try await recordVerifiedTransactionEvent(
            event,
            billingAccountID
        )
        let transaction = event.transaction
        guard acknowledgement.billingAccountID == billingAccountID,
              acknowledgement.transactionID == String(transaction.id),
              acknowledgement.originalTransactionID == String(transaction.originalID)
        else {
            throw PlusPurchaseRecordingFailure.invalidAcknowledgement
        }
    }

}
