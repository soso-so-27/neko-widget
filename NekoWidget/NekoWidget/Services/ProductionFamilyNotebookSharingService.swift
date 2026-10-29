import Foundation

/// A registered identity and private stores for one endpoint/person/device.
/// Construction does not import personal records or prototype membership.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
final class FamilyNotebookSession {
    let identity: GroupDeviceIdentity, endpoint: URL
    let journal: any GroupSecretStore
    let wire: FamilyNotebookTransport, keys: FamilyNotebookKeyCoordinator
    let admission: FamilyNotebookAdmissionClient, membership: FamilyNotebookMembershipClient
    let directory: URL
    private struct Participation: Codable { let familyID: UUID; let admittedGeneration: Int64 }
    private let account = "op:fnb-active-participation"
    private(set) var notebook: FamilyNotebookStore?
    private var participation: Participation?

    init(endpoint: URL, identity: GroupDeviceIdentity, transport: any GroupHTTPTransport,
         journal: any GroupSecretStore, secrets: any GroupSecretStore, directory: URL) throws {
        self.identity = identity; self.endpoint = endpoint; self.journal = journal; self.directory = directory
        wire = try .init(endpoint: endpoint, identity: identity, transport: transport, journal: journal)
        keys = try .init(endpoint: endpoint, identity: identity, network: wire, secrets: secrets, journal: journal)
        admission = .init(endpoint: endpoint, identity: identity, wire: wire, keys: keys, journal: journal, secrets: secrets)
        membership = try .init(endpoint: endpoint, identity: identity, transport: transport, journal: journal)
        if let bytes = try journal.read(account) {
            let saved = try GroupWire.decode(Participation.self, bytes)
            guard (1...1_000_000_000).contains(saved.admittedGeneration) else { throw FamilyNotebookError.corruptStorage }
            notebook = try open(saved); participation = saved
        }
    }
    private func open(_ value: Participation) throws -> FamilyNotebookStore {
        try .init(directory: directory.appendingPathComponent(value.familyID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(String(value.admittedGeneration), isDirectory: true), familyID: value.familyID, deviceID: identity.deviceID)
    }
    func activate(family: UUID, admittedGeneration: Int64) throws -> FamilyNotebookStore {
        if let existing = participation, existing.familyID == family, existing.admittedGeneration == admittedGeneration, let notebook {
            guard try !notebook.snapshot().sharingEnded else { throw FamilySharingError.removedOrDissolved }
            return notebook
        }
        // A new admission is a new local participation. Never reopen a departed
        // copy's unsent outbox, overwrite it, or delete its records.
        if let notebook { _ = try notebook.endSharing() }
        let next = Participation(familyID: family, admittedGeneration: admittedGeneration), store = try open(next)
        guard try !store.snapshot().sharingEnded else { throw FamilySharingError.removedOrDissolved }
        try journal.write(GroupWire.encode(next), account: account, createOnly: false)
        participation = next; notebook = store
        return store
    }
    func confirmedOutsideFamily() throws {
        if let notebook { _ = try notebook.endSharing() }
        // Keep the pointer and full copy for the reader. It is no longer an
        // active membership, and synchronize refuses its terminal outbox.
    }
}

/// Explicitly enabled builds use this adapter. Every membership decision comes
/// from authenticated HTTP; cryptographic trust still comes from the accepted
/// invitation or our own acknowledged creation, never directory JSON.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
final class ProductionFamilyNotebookSharingService: FamilyNotebookSharingService {
    typealias SessionProvider = @MainActor () async throws -> FamilyNotebookSession
    private let provider: SessionProvider
    private let billing: @MainActor () async throws -> Void
    private let displayName: @MainActor () throws -> String
    private let catNames: @MainActor () -> [String]
    private var session: FamilyNotebookSession?
    private var working = false
    private(set) var needsAnotherPass = false
    private(set) var currentFamilyID: UUID?
    private(set) var lastMembers: [FamilyNotebookAdmissionClient.Member] = []
    var notebook: FamilyNotebookStore? { session?.notebook }
    var author: FamilyNotebookAuthor? {
        guard let identity = session?.identity, let name = try? displayName() else { return nil }
        return .init(personID: identity.personID, displayName: name)
    }
    var sendsInvitations: Bool { true }

    init(provider: @escaping SessionProvider, billing: @escaping @MainActor () async throws -> Void,
         displayName: @escaping @MainActor () throws -> String, catNames: @escaping @MainActor () -> [String]) {
        self.provider = provider; self.billing = billing; self.displayName = displayName; self.catNames = catNames
    }
    private func run<T>(_ action: (FamilyNotebookSession) async throws -> T) async throws -> T {
        guard !working else { throw FamilySharingError.unknownOutcome }
        working = true; defer { working = false }
        do {
            let context: FamilyNotebookSession
            if let session { context = session } else { context = try await provider(); session = context }
            return try await action(context)
        } catch { throw Self.presentation(error) }
    }
    private static func presentation(_ error: Error) -> FamilySharingError {
        if let error = error as? FamilySharingError { return error }
        if let error = error as? FamilyNotebookTransportError, case .server(let code, _) = error {
            switch code {
            case "family_notebook_invitation_unavailable": return .invitationExpired
            case "family_notebook_already_in_family": return .alreadyInFamily
            case "family_notebook_member_limit": return .memberLimit
            default: break
            }
        }
        if error is FamilyNotebookCryptoError { return .unsupported }
        return FamilyNotebookMembershipClient.presentation(error)
    }
    private func family(_ context: FamilyNotebookSession) async throws -> FamilyNotebookAdmissionClient.Family {
        guard let value = try await context.admission.directory().family else { throw FamilySharingError.removedOrDissolved }
        return value
    }
    private func payer(_ context: FamilyNotebookSession) async throws -> FamilyNotebookPayerState {
        let family = try await family(context)
        return try await context.membership.loadPayer(familyID: family.familyID, minimumGeneration: family.generation)
    }
    func loadState() async throws -> FamilySharingState {
        try await run { context in
            needsAnotherPass = false
            try await context.admission.resumePending()
            try await context.membership.resumePending(notebook: context.notebook)
            let directory = try await context.admission.directory()
            guard let family = directory.family else {
                currentFamilyID = nil; lastMembers = []
                try context.confirmedOutsideFamily()
                return directory.pendingRequests.isEmpty ? .notInFamily : .pendingApproval
            }
            let members = try await context.admission.members(family.familyID)
            guard members.generation >= family.generation,
                  let own = members.members.first(where: { $0.personID == context.identity.personID }),
                  own.identityPublicKey == context.identity.personPublicKey else { throw FamilyNotebookTransportError.invalidResponse }
            let state = try await context.membership.loadPayer(familyID: family.familyID, minimumGeneration: members.generation)
            let store = try context.activate(family: family.familyID, admittedGeneration: own.admittedGeneration)
            currentFamilyID = family.familyID; lastMembers = members.members
            // Paused sharing still has a real membership and a retained local
            // notebook. Do not turn a write-gate rejection into an endless spinner.
            if state.sharingStatus == .paused { return .inFamily(.init(role: state.role == .payer ? .payer : .member)) }
            guard let material = try await context.keys.prepare(family: family.familyID) else { needsAnotherPass = true; return .waitingForKeys }
            guard material.ready, !material.moreWork else { needsAnotherPass = true; return .waitingForKeys }
            let sync = try FamilyNotebookSync(familyID: family.familyID, identity: context.identity, store: store,
                network: context.wire, journal: context.journal, endpointID: context.endpoint.absoluteString)
            let result = try await sync.synchronize(current: material.current, history: material.history, keys: material.keys)
            needsAnotherPass = result.moreHistory || result.needsRotation
            if needsAnotherPass { return .waitingForKeys }
            return .inFamily(.init(role: state.role == .payer ? .payer : .member))
        }
    }
    func loadPause() async throws -> FamilySharingPause? {
        try await run { FamilySharingPause(try await payer($0)) }
    }
    private func admissionAllowed(_ context: FamilyNotebookSession) async throws {
        guard try await !context.membership.hasPendingOperation() else { throw FamilySharingError.unknownOutcome }
    }
    private func managementAllowed(_ context: FamilyNotebookSession) async throws {
        guard try await !context.admission.hasPendingOperation() else { throw FamilySharingError.unknownOutcome }
    }
    func createFamily(operationID: UUID) async throws {
        try await run { context in
            try await admissionAllowed(context)
            // Reconcile a prior receipt even when current billing is unavailable.
            if try await !context.admission.hasPendingOperation() {
                guard try await context.admission.directory().family == nil else { throw FamilySharingError.alreadyInFamily }
                try await billing()
            }
            try await context.admission.create(operation: operationID)
        }
    }
    func createInvitation(operationID: UUID) async throws -> FamilyInvitation {
        try await run { context in
            try await admissionAllowed(context)
            let family = try await family(context), state = try await context.membership.loadPayer(familyID: family.familyID, minimumGeneration: family.generation)
            guard let material = try await context.keys.prepare(family: family.familyID), material.ready, !material.moreWork else { throw FamilySharingError.membershipChecking }
            return try await context.admission.invite(family: family.familyID, generation: state.generation,
                roster: material.current, payer: state.payerPersonId, name: displayName(), catNames: catNames(), operation: operationID)
        }
    }
    func previewInvitation(_ link: URL?) async throws -> FamilyInvitationPreview {
        guard let link else { throw FamilySharingError.invitationExpired }
        return try await run { try await $0.admission.preview(link) }
    }
    func join(_ invitation: FamilyInvitationPreview, operationID: UUID) async throws -> FamilyJoinResult {
        try await run { context in
            try await admissionAllowed(context)
            try await context.admission.join(invitation, name: displayName(), operation: operationID)
            return .pendingApproval
        }
    }
    func loadHandover() async throws -> FamilyPayerHandover {
        try await run { context in
            let family = try await family(context)
            return try await context.membership.loadHandover(familyID: family.familyID, minimumGeneration: family.generation)
        }
    }
    func nominatePayer(personID: String, expectedGeneration: Int64, operationID: UUID) async throws {
        try await run { context in
            try await managementAllowed(context); let family = try await family(context)
            try await context.membership.nominatePayer(familyID: family.familyID, personID: personID, expectedGeneration: expectedGeneration, operationID: operationID)
        }
    }
    func acceptPayer(nominationID: UUID, expectedGeneration: Int64, operationID: UUID) async throws {
        try await run { context in
            try await managementAllowed(context)
            if try await !context.membership.hasPendingOperation() { try await billing() }
            let family = try await family(context)
            try await context.membership.acceptPayer(familyID: family.familyID, nominationID: nominationID, expectedGeneration: expectedGeneration, operationID: operationID)
        }
    }
    func cancelPayerNomination(nominationID: UUID, expectedGeneration: Int64, operationID: UUID) async throws {
        try await run { context in
            try await managementAllowed(context); let family = try await family(context)
            try await context.membership.cancelPayerNomination(familyID: family.familyID, nominationID: nominationID, expectedGeneration: expectedGeneration, operationID: operationID)
        }
    }
    func claimPayer(operationID: UUID) async throws {
        try await run { context in
            try await managementAllowed(context)
            if try await !context.membership.hasPendingOperation() { try await billing() }
            let family = try await family(context)
            try await context.membership.claimPayer(familyID: family.familyID, expectedGeneration: family.generation, operationID: operationID)
        }
    }
    func removeMember(personID: String, operationID: UUID) async throws {
        try await run { context in
            try await managementAllowed(context); let family = try await family(context)
            try await context.membership.removeMember(familyID: family.familyID, personID: personID, expectedGeneration: family.generation, operationID: operationID)
        }
    }
    func leaveFamily(operationID: UUID) async throws -> FamilyExitResult { try await exit(operationID, dissolve: false) }
    func dissolveFamily(operationID: UUID) async throws -> FamilyExitResult { try await exit(operationID, dissolve: true) }
    private func exit(_ operation: UUID, dissolve: Bool) async throws -> FamilyExitResult {
        try await run { context in
            try await managementAllowed(context)
            if try await context.membership.hasPendingOperation() {
                do { try await context.membership.resumePending(notebook: context.notebook) }
                catch FamilySharingError.unknownOutcome { return .pending }
                // A resumed management action may have been a different one.
                if try context.notebook?.snapshot().sharingEnded == true { return .confirmed }
            }
            let family = try await family(context), members = try await context.admission.members(family.familyID)
            guard let own = members.members.first(where: { $0.personID == context.identity.personID }) else { throw FamilySharingError.notAllowed }
            let store = try context.activate(family: family.familyID, admittedGeneration: own.admittedGeneration)
            return try await (dissolve
                ? context.membership.dissolveFamily(familyID: family.familyID, expectedGeneration: members.generation, operationID: operation, notebook: store)
                : context.membership.leaveFamily(familyID: family.familyID, expectedGeneration: members.generation, operationID: operation, notebook: store))
        }
    }
    func pendingRequests() async throws -> [FamilyNotebookJoinRequest] {
        try await run { context in
            let family = try await family(context), result = try await context.admission.requests(family.familyID)
            return try await result.requests.asyncNames(context.admission, family: family.familyID, generation: result.generation)
        }
    }
    func decide(requestID: UUID, approve: Bool, operationID: UUID) async throws {
        try await run { context in
            try await admissionAllowed(context)
            // A pending approval already contains the explicitly selected root;
            // resolve it before a consumed request disappears from the list.
            if try await context.admission.hasPendingOperation() {
                try await context.admission.resumePending()
                throw FamilySharingError.staleRoster // Reload; do not claim this newly selected request was approved.
            }
            let family = try await family(context), result = try await context.admission.requests(family.familyID)
            guard let request = result.requests.first(where: { $0.requestID == requestID }) else { throw FamilySharingError.staleRoster }
            try await context.admission.decide(family: family.familyID, request: request, generation: result.generation, approve: approve, operation: operationID)
        }
    }
}

struct FamilyNotebookJoinRequest: Equatable, Sendable {
    let id: UUID, personID: String, displayName: String, generation: Int64
}
private extension Array where Element == FamilyNotebookAdmissionClient.Request {
    func asyncNames(_ client: FamilyNotebookAdmissionClient, family: UUID, generation: Int64) async throws -> [FamilyNotebookJoinRequest] {
        var result: [FamilyNotebookJoinRequest] = []
        for request in self {
            result.append(try await .init(id: request.requestID, personID: request.personID,
                displayName: client.requestName(request, family: family), generation: generation))
        }
        return result
    }
}
