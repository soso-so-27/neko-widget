import Foundation

enum MembershipOperation: String, CaseIterable, Sendable {
    case browsePhotos
    case manageFavorites
    case readExistingMemo
    case editExistingMemo
    case deleteOwnedContent
    case exportExistingContent
    case receivePhotos
    case reactToPhoto
    case browseOfficialWindow
    case automaticAlbums
    case refreshPersonalWidget
    case createPersonalMemo
    case createWindow
    case presentCatPhotos
    case createCareMemo
    case createVeterinaryVisit
    case addSharedContent
    case continueAcceptedDelivery
}

enum MembershipAccessDecision: Equatable, Sendable {
    case allowed
    case membershipRequired
    case verificationRequired
    case windowSupportRequired
}

/// Only verified authority may produce these dates. Adapters must preserve the
/// earlier of the access expiry and authority freshness/offline-grace boundary.
/// A confirmed revocation replaces any previous grant with `inactive`.
enum MembershipPersonalState: Equatable, Sendable {
    case inactive
    case checking
    case verified(validUntil: Date)
    case indeterminate(lastVerifiedUntil: Date?)
}

/// Authority for the particular window being operated on, never the viewer's
/// personal subscription. Adapters must validate its identity and generation.
enum MembershipWindowState: Equatable, Sendable {
    case inactive
    case checking
    case verified(validUntil: Date)
    case indeterminate(lastVerifiedUntil: Date?)
}

/// A pure membership requirement decision, not an authorization or server grant.
/// `allowed` never bypasses photo permission, ownership, consent, withdrawal,
/// retention, window membership/key checks, or the server's send authorization.
/// Callers must establish that content is existing/owned and a delivery really
/// was accepted before choosing the corresponding operation. This policy neither
/// accepts a delivery nor permits an unaccepted attempt to be labeled a retry.
enum MembershipAccessPolicy {
    static func decision(
        for operation: MembershipOperation,
        enforcementEnabled: Bool,
        personal: MembershipPersonalState,
        window: MembershipWindowState,
        now: Date
    ) -> MembershipAccessDecision {
        // Beta disables only membership restrictions, not the checks above.
        guard enforcementEnabled else { return .allowed }

        switch operation {
        case .browsePhotos, .manageFavorites, .readExistingMemo,
             .editExistingMemo, .deleteOwnedContent, .exportExistingContent,
             .receivePhotos, .reactToPhoto, .browseOfficialWindow,
             .continueAcceptedDelivery:
            return .allowed
        case .automaticAlbums, .refreshPersonalWidget, .createPersonalMemo,
             .createWindow, .presentCatPhotos, .createCareMemo, .createVeterinaryVisit:
            guard now.timeIntervalSinceReferenceDate.isFinite else {
                return .verificationRequired
            }
            switch personal {
            case .inactive:
                return .membershipRequired
            case .checking:
                return .verificationRequired
            case let .verified(validUntil):
                return verifiedDecision(
                    until: validUntil, now: now, expired: .membershipRequired
                )
            case let .indeterminate(lastVerifiedUntil):
                return lastVerifiedDecision(until: lastVerifiedUntil, now: now)
            }
        case .addSharedContent:
            guard now.timeIntervalSinceReferenceDate.isFinite else {
                return .verificationRequired
            }
            switch window {
            case .inactive:
                return .windowSupportRequired
            case .checking:
                return .verificationRequired
            case let .verified(validUntil):
                return verifiedDecision(
                    until: validUntil, now: now, expired: .windowSupportRequired
                )
            case let .indeterminate(lastVerifiedUntil):
                return lastVerifiedDecision(until: lastVerifiedUntil, now: now)
            }
        }
    }

    private static func verifiedDecision(
        until: Date, now: Date, expired: MembershipAccessDecision
    ) -> MembershipAccessDecision {
        guard until.timeIntervalSinceReferenceDate.isFinite else {
            return .verificationRequired
        }
        return now < until ? .allowed : expired
    }

    private static func lastVerifiedDecision(
        until: Date?, now: Date
    ) -> MembershipAccessDecision {
        guard let until,
              until.timeIntervalSinceReferenceDate.isFinite,
              now < until else { return .verificationRequired }
        return .allowed
    }
}

struct MembershipActionDenied: Error {
    let decision: MembershipAccessDecision
}

/// A live local membership requirement, not ownership or a server grant.
/// Update the same instance when authority changes; suspended work must not
/// keep an earlier Bool/snapshot as permission to create. A synchronous commit
/// is serialized with updates and checks the current clock. Existing records
/// are returned before this boundary.
final class MembershipActionAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    private var personal: MembershipPersonalState

    init(enforcementEnabled: Bool = true, personal: MembershipPersonalState = .checking) {
        enabled = enforcementEnabled; self.personal = personal
    }
    static var beta: MembershipActionAccess { .init(enforcementEnabled: false) }

    func update(enforcementEnabled: Bool, personal: MembershipPersonalState) {
        lock.lock(); defer { lock.unlock() }
        enabled = enforcementEnabled; self.personal = personal
    }
    func decision(for operation: MembershipOperation, now: Date = .now) -> MembershipAccessDecision {
        lock.lock(); defer { lock.unlock() }
        return check(operation, now: now)
    }
    func perform<T>(for operation: MembershipOperation, _ commit: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let decision = check(operation, now: .now)
        guard decision == .allowed else { throw MembershipActionDenied(decision: decision) }
        return try commit()
    }
    private func check(_ operation: MembershipOperation, now: Date) -> MembershipAccessDecision {
        MembershipAccessPolicy.decision(for: operation, enforcementEnabled: enabled,
            personal: personal, window: .inactive, now: now)
    }
}
