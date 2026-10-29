import Foundation

// The family notebook between iPhones, as the screens see it (1028c, Codex's
// proposed contract). The screens talk only to `FamilyNotebookSharing`; behind
// it is the prototype on this iPhone now, and the real service later. Leaving,
// taking someone out and ending the family are separate operations, and none
// of them deletes this person's own copy.

/// What the screens hold: the state, and one way to run an operation.
@MainActor
final class FamilyNotebookSharing: ObservableObject {
    static let shared = FamilyNotebookSharing(service: FamilyNotebookServiceFactory.make())

    @Published private(set) var state: FamilySharingState = .checking
    @Published private(set) var pause: FamilySharingPause?
    @Published var failure: FamilySharingError?
    @Published private(set) var isWorking = false
    let service: any FamilyNotebookSharingService

    init(service: any FamilyNotebookSharingService) {
        self.service = service
    }

    func refresh() async {
        do {
            state = try await service.loadState()
            pause = state.membership == nil ? nil : try await service.loadPause()
        } catch { failure = error as? FamilySharingError ?? .serviceUnavailable }
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
    /// Test only, kept in memory: the payer left, and whether this person
    /// became the payer afterwards.
    private var pretendedPause: FamilySharingPause?
    private var claimedPayer = false

    var sendsInvitations: Bool { false }

    private var isPayer: Bool {
        claimedPayer || (!model.joinedSomeonesFamily && pretendedPause == nil)
    }

    func loadState() async throws -> FamilySharingState {
        guard model.hasFamily else { return .notInFamily }
        return .inFamily(FamilyMembership(role: isPayer ? .payer : .member))
    }

    func loadPause() async throws -> FamilySharingPause? {
        model.hasFamily ? pretendedPause : nil
    }

    /// 「払う人が抜けたときを試す」: as the server would say it, with this
    /// person's Plus as the only thing deciding `canClaim`.
    func pretendPayerLeft(hasPlus: Bool) {
        pretendedPause = .noPayer(canClaim: hasPlus, handoverPending: false)
        claimedPayer = false
    }

    func claimPayer(operationID: UUID) async throws {
        guard case .noPayer(canClaim: true, _)? = pretendedPause else { throw FamilySharingError.plusRequired }
        pretendedPause = nil
        claimedPayer = true
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
        pretendedPause = nil; claimedPayer = false
        return .confirmed
    }

    func removeMember(personID: String, operationID: UUID) async throws {
        guard model.hasFamily, isPayer else { throw FamilySharingError.notAllowed }
        model.removeMember(personID: personID)
    }

    func dissolveFamily(operationID: UUID) async throws -> FamilyExitResult {
        guard model.hasFamily, isPayer else { throw FamilySharingError.notAllowed }
        model.endPrototypeFamily()
        pretendedPause = nil; claimedPayer = false
        return .confirmed
    }
}
