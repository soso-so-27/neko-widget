import Foundation

// The family notebook between iPhones, as the screens see it (1028c, Codex's
// proposed contract). The screens talk only to `FamilyNotebookSharing`; behind
// it is the prototype on this iPhone now, and the real service later. Leaving,
// taking someone out and ending the family are separate operations, and none
// of them deletes this person's own copy.

enum FamilySharingState: Equatable, Sendable {
    case checking
    case notInFamily
    /// Asked to join; the family has not let this person in yet.
    case pendingApproval
    /// Let in; the keys for the notebook have not arrived yet.
    case waitingForKeys
    case inFamily(FamilyMembership)
    /// Leaving or ending sent; the server has not confirmed it yet.
    case leaving

    var membership: FamilyMembership? {
        if case let .inFamily(membership) = self { return membership }
        return nil
    }
}

struct FamilyInvitation: Equatable, Sendable {
    var link: URL
    var expiresAt: Date
}

/// What an invitation shows before joining: who asks and for which cats.
/// Only what the family chose to show; never an address or health notes.
struct FamilyInvitationPreview: Equatable, Sendable {
    var inviterName: String
    var catNames: [String]
    var expiresAt: Date?
}

enum FamilyJoinResult: Equatable, Sendable {
    case pendingApproval
    case waitingForKeys
    case joined
}

enum FamilyExitResult: Equatable, Sendable {
    /// The server confirmed it.
    case confirmed
    /// Sent, result not known yet; ask again before doing it twice.
    case pending
}

enum FamilySharingError: Error, Equatable, Sendable {
    case invitationExpired, invitationRevoked, invitationUsed
    case alreadyInFamily, memberLimit
    case signInExpired, notAllowed
    case plusRequired, membershipChecking
    case staleRoster, removedOrDissolved
    case offline, rateLimited, serviceUnavailable, unknownOutcome
    case unsupported
    /// Not possible before the family works between iPhones (the prototype).
    case notAvailableYet

    enum Recovery: Sendable { case retry, reload, personAction }

    var recovery: Recovery {
        switch self {
        case .offline, .rateLimited, .serviceUnavailable: .retry
        case .unknownOutcome, .staleRoster: .reload
        default: .personAction
        }
    }

    var message: String {
        switch self {
        case .invitationExpired: "この招待は期限が切れています。新しい招待をもらってください。"
        case .invitationRevoked: "この招待は取り消されています。"
        case .invitationUsed: "この招待はもう使われています。"
        case .alreadyInFamily: "家族は 1 つまでです。いまの家族から抜けると参加できます。"
        case .memberLimit: "この家族はいっぱいです。"
        case .signInExpired: "もう一度サインインしてください。"
        case .notAllowed: "この操作はできません。"
        case .plusRequired: "家族を作るには Plus が必要です。"
        case .membershipChecking: "Plus の確認ができるまでお待ちください。"
        case .staleRoster: "家族の情報が新しくなりました。もう一度お試しください。"
        case .removedOrDissolved: "この家族の共有は終わっています。"
        case .offline: "つながっていません。つながってからもう一度お試しください。"
        case .rateLimited: "少し待ってから、もう一度お試しください。"
        case .serviceUnavailable: "いまは使えません。少し待ってから、もう一度お試しください。"
        case .unknownOutcome: "結果を確かめています。少し待ってから開き直してください。"
        case .unsupported: "このアプリを最新にしてください。記録は消していません。"
        case .notAvailableYet: "試作のため、まだできません。"
        }
    }
}

/// Every operation carries an operation ID; sending the same operation again
/// uses the same ID, so a retry never makes a second family or a second join.
@MainActor
protocol FamilyNotebookSharingService: AnyObject {
    /// Whether invitations can leave this iPhone (false in the prototype).
    var sendsInvitations: Bool { get }
    func loadState() async throws -> FamilySharingState
    func createFamily(operationID: UUID) async throws
    func createInvitation(operationID: UUID) async throws -> FamilyInvitation
    func previewInvitation(_ link: URL?) async throws -> FamilyInvitationPreview
    func join(_ invitation: FamilyInvitationPreview, operationID: UUID) async throws -> FamilyJoinResult
    func leaveFamily(operationID: UUID) async throws -> FamilyExitResult
    func removeMember(personID: String, operationID: UUID) async throws
    func dissolveFamily(operationID: UUID) async throws -> FamilyExitResult
}

/// What the screens hold: the state, and one way to run an operation.
@MainActor
final class FamilyNotebookSharing: ObservableObject {
    static let shared = FamilyNotebookSharing(service: FamilyNotebookPrototypeSharing())

    @Published private(set) var state: FamilySharingState = .checking
    @Published var failure: FamilySharingError?
    @Published private(set) var isWorking = false
    let service: any FamilyNotebookSharingService

    init(service: any FamilyNotebookSharingService) {
        self.service = service
    }

    func refresh() async {
        do { state = try await service.loadState() }
        catch { failure = error as? FamilySharingError ?? .serviceUnavailable }
    }

    /// Runs one operation with a fresh ID, then reads the state again.
    @discardableResult
    func perform(_ operation: (UUID) async throws -> Void) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation(UUID())
            await refresh()
            return true
        } catch {
            failure = error as? FamilySharingError ?? .unknownOutcome
            await refresh()
            return false
        }
    }
}

/// Test builds: the family on this iPhone alone (FamilyNotebookPrototype).
/// Nothing is sent; the invitation is the tried member's.
@MainActor
final class FamilyNotebookPrototypeSharing: FamilyNotebookSharingService {
    private var model: FamilyNotebookPrototype { .shared }

    var sendsInvitations: Bool { false }

    func loadState() async throws -> FamilySharingState {
        guard model.hasFamily else { return .notInFamily }
        return .inFamily(FamilyMembership(role: model.joinedSomeonesFamily ? .member : .payer))
    }

    func createFamily(operationID: UUID) async throws {
        guard !model.hasFamily else { throw FamilySharingError.alreadyInFamily }
        await model.create()
        guard model.hasFamily else { throw FamilySharingError.unsupported }
    }

    func createInvitation(operationID: UUID) async throws -> FamilyInvitation {
        throw FamilySharingError.notAvailableYet
    }

    func previewInvitation(_ link: URL?) async throws -> FamilyInvitationPreview {
        FamilyInvitationPreview(inviterName: FamilyNotebookPrototype.tryout.displayName,
                                catNames: model.catNames, expiresAt: nil)
    }

    func join(_ invitation: FamilyInvitationPreview, operationID: UUID) async throws -> FamilyJoinResult {
        guard !model.hasFamily else { throw FamilySharingError.alreadyInFamily }
        await model.join()
        guard model.hasFamily else { throw FamilySharingError.unsupported }
        return .joined
    }

    /// The prototype's own copy is 「この子のこと」, which stays; only the
    /// tried family on this iPhone ends.
    func leaveFamily(operationID: UUID) async throws -> FamilyExitResult {
        try model.leavePrototypeFamily()
        return .confirmed
    }

    func removeMember(personID: String, operationID: UUID) async throws {
        guard model.hasFamily, !model.joinedSomeonesFamily else { throw FamilySharingError.notAllowed }
        model.removeMember(personID: personID)
    }

    func dissolveFamily(operationID: UUID) async throws -> FamilyExitResult {
        guard model.hasFamily, !model.joinedSomeonesFamily else { throw FamilySharingError.notAllowed }
        model.endPrototypeFamily()
        return .confirmed
    }
}
