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
    /// Who pays and who was asked to take it over. Nil when it could not be
    /// read; the screens then offer nothing about it.
    @Published private(set) var handover: FamilyPayerHandover?
    @Published var failure: FamilySharingError?
    @Published private(set) var isWorking = false
    private var refreshing = false
    @Published private(set) var requests: [FamilyNotebookJoinRequest] = []
    let service: any FamilyNotebookSharingService

    init(service: any FamilyNotebookSharingService) {
        self.service = service
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            state = try await service.loadState()
            pause = state.membership == nil ? nil : try await service.loadPause()
            handover = state.membership == nil ? nil : try? await service.loadHandover()
            if let real = service as? ProductionFamilyNotebookSharingService {
                FamilyNotebookPrototype.shared.attachReal(real)
                requests = state.membership == nil ? [] : try await real.pendingRequests()
            }
        } catch { failure = error as? FamilySharingError ?? .serviceUnavailable }
    }

    /// Runs one operation with a fresh ID, then reads the state again.
    @discardableResult
    func perform(_ operation: (UUID) async throws -> Void) async -> Bool {
        guard !isWorking, !refreshing else { return false }
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
    /// Test only, kept in memory: the one person asked to take over paying,
    /// and whether this person had Plus when asked.
    private var nomination: (id: UUID, personID: String)?
    private var nomineeHasPlus = false
    private var generation: Int64 = 1

    var sendsInvitations: Bool { false }

    private var isPayer: Bool {
        claimedPayer || (!model.joinedSomeonesFamily && pretendedPause == nil)
    }

    private var me: String { FamilyNotebookPrototype.me.personID }

    func loadHandover() async throws -> FamilyPayerHandover {
        guard model.hasFamily, let familyID = model.snapshot?.familyID else { throw FamilySharingError.notAvailableYet }
        var payer: String? = isPayer ? me : FamilyNotebookPrototype.tryout.personID
        if case .noPayer = pretendedPause { payer = nil }
        let nominee = nomination?.personID
        return FamilyPayerHandover(
            schemaVersion: 1, familyId: familyID, generation: generation,
            payerPersonId: payer, nominationId: nomination?.id, nomineePersonId: nominee,
            canNominate: payer == me && nomination == nil,
            canAccept: nominee == me && nomineeHasPlus,
            canCancel: nomination != nil && (payer == me || nominee == me),
            nominationState: .confirmed)
    }

    func nominatePayer(personID: String, expectedGeneration: Int64, operationID: UUID) async throws {
        guard expectedGeneration == generation else { throw FamilySharingError.staleRoster }
        guard isPayer, nomination == nil, personID != me else { throw FamilySharingError.notAllowed }
        nomination = (UUID(), personID)
        generation += 1
    }

    /// Taking it over: the nominee becomes the payer, and the family goes on.
    func acceptPayer(nominationID: UUID, expectedGeneration: Int64, operationID: UUID) async throws {
        guard expectedGeneration == generation else { throw FamilySharingError.staleRoster }
        guard nomination?.id == nominationID, nomination?.personID == me else { throw FamilySharingError.notAllowed }
        guard nomineeHasPlus else { throw FamilySharingError.plusRequired }
        nomination = nil
        pretendedPause = nil
        claimedPayer = true
        generation += 1
    }

    /// The payer taking the request back, or the nominee saying no.
    func cancelPayerNomination(nominationID: UUID, expectedGeneration: Int64, operationID: UUID) async throws {
        guard expectedGeneration == generation else { throw FamilySharingError.staleRoster }
        guard nomination?.id == nominationID else { throw FamilySharingError.notAllowed }
        nomination = nil
        generation += 1
    }

    /// 「払う人に頼まれたときを試す」: the tried member, as the payer, asks
    /// this person. Plus is read once, as with the payer leaving.
    func pretendNominated(hasPlus: Bool) {
        guard model.hasFamily, !isPayer else { return }
        nomination = (UUID(), me)
        nomineeHasPlus = hasPlus
        if case .noPayer = pretendedPause { pretendedPause = .noPayer(canClaim: false, handoverPending: true) }
        generation += 1
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
        // Someone already asked keeps the request; nobody claims first then.
        pretendedPause = .noPayer(canClaim: hasPlus && nomination == nil, handoverPending: nomination != nil)
        claimedPayer = false
        if nomination?.personID == me { nomineeHasPlus = hasPlus }
    }

    private func forgetHandover() {
        pretendedPause = nil; claimedPayer = false; nomination = nil
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
        forgetHandover()
        return .confirmed
    }

    func removeMember(personID: String, operationID: UUID) async throws {
        guard model.hasFamily, isPayer else { throw FamilySharingError.notAllowed }
        model.removeMember(personID: personID)
        if nomination?.personID == personID { nomination = nil; generation += 1 }
    }

    func dissolveFamily(operationID: UUID) async throws -> FamilyExitResult {
        guard model.hasFamily, isPayer else { throw FamilySharingError.notAllowed }
        model.endPrototypeFamily()
        forgetHandover()
        return .confirmed
    }
}
