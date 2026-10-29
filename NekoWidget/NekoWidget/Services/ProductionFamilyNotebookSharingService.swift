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
    func matchesParticipation(family: UUID, admittedGeneration: Int64) -> Bool {
        participation?.familyID == family && participation?.admittedGeneration == admittedGeneration
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
    private let privateFarewellDay: @MainActor (UUID, UUID?) throws -> String?
    private let now: @MainActor () -> Date
    private struct PreparedFarewell {
        let preview: FamilyFarewellPreview
        let toolCatID: UUID, profileID: UUID?
        let directory: URL
        let generation: Int64
        let sharedOperationID: UUID?
    }
    private var farewellPreviews: [UUID: PreparedFarewell] = [:]
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
         displayName: @escaping @MainActor () throws -> String, catNames: @escaping @MainActor () -> [String],
         privateFarewellDay: @escaping @MainActor (UUID, UUID?) throws -> String? = { _, _ in nil },
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.provider = provider; self.billing = billing; self.displayName = displayName; self.catNames = catNames
        self.privateFarewellDay = privateFarewellDay; self.now = now
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
        if let error = error as? FamilyNotebookError {
            switch error {
            case .staleConsent, .consentOperationConflict: return .farewellPreviewChanged
            case .sharingEnded: return .removedOrDissolved
            default: break
            }
        }
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

    private func farewellMapping(_ context: FamilyNotebookSession, tool: UUID) throws -> (FamilyNotebookStore, FamilyNotebookLocalMapping) {
        guard let store = context.notebook else { throw FamilySharingError.membershipChecking }
        let snapshot = try store.snapshot()
        guard !snapshot.sharingEnded else { throw FamilySharingError.removedOrDissolved }
        let mappings = snapshot.mappings.filter { $0.recordID == nil && $0.toolCatID == tool }
        guard let mapping = mappings.first, Set(mappings.map(\.familyCatID)).count == 1,
              Set(mappings.compactMap(\.profileID)).count <= 1 else { throw FamilySharingError.notAllowed }
        return (store, mapping)
    }
    private func farewellFamily(_ context: FamilyNotebookSession, store: FamilyNotebookStore) async throws -> FamilyNotebookAdmissionClient.Family {
        let value = try await family(context)
        let members = try await context.admission.members(value.familyID)
        let snapshot = try store.snapshot()
        guard value.familyID == snapshot.familyID,
              let own = members.members.first(where: { $0.personID == context.identity.personID }),
              own.identityPublicKey == context.identity.personPublicKey,
              members.generation == value.generation,
              context.matchesParticipation(family: value.familyID, admittedGeneration: own.admittedGeneration)
        else { throw FamilySharingError.farewellPreviewChanged }
        return value
    }
    private func sharedFarewell(_ snapshot: FamilyNotebookSnapshot, cat: UUID) -> (String?, FamilyNotebookAuthor?) {
        guard let field = snapshot.fieldState(for: .init(familyCatID: cat, field: .farewellDay)),
              !field.isDeleted, case .day(let day) = field.operation.value else { return (nil, nil) }
        return (day, field.operation.author)
    }
    func loadFarewellSharing(toolCatID: UUID) async throws -> FamilyFarewellSharingState {
        try await run { context in
            let (store, mapping) = try farewellMapping(context, tool: toolCatID), snapshot = try store.snapshot()
            let decision = snapshot.farewellDecisions.last { $0.familyCatID == mapping.familyCatID && $0.personID == context.identity.personID }
            let shared = sharedFarewell(snapshot, cat: mapping.familyCatID)
            let pending = decision?.sharedOperationID.map { id in snapshot.outbox.contains { $0.id == id } } ?? false
            let ownDates = snapshot.operations.filter { operation in
                guard operation.target.familyCatID == mapping.familyCatID, operation.target.field == .farewellDay,
                      operation.author.personID == context.identity.personID, case .day = operation.value else { return false }
                return true
            }
            var possiblyShared = false
            for operation in ownDates {
                let attempted = try context.journal.read("op:family:" + operation.id.uuidString.lowercased()) != nil
                // A received/restored copy may have no local HTTP journal.
                // Absence of that journal never proves the date stayed private.
                let stillPendingHere = snapshot.outbox.contains { $0.id == operation.id }
                if attempted || !stillPendingHere || operation.version.deviceID != store.localDeviceID ||
                    snapshot.acknowledgements.contains(where: { $0.operationID == operation.id }) { possiblyShared = true }
            }
            return try .init(familyID: snapshot.familyID, familyCatID: mapping.familyCatID,
                localDay: privateFarewellDay(toolCatID, mapping.profileID), consentedDay: decision?.day,
                sharedDay: shared.0, sharedAuthor: shared.1,
                sharingPending: pending && decision?.day != nil, revocationPending: pending && decision?.day == nil,
                mayAlreadyHaveBeenShared: possiblyShared)
        }
    }
    func previewFarewellSharing(toolCatID: UUID) async throws -> FamilyFarewellPreview {
        try await run { context in
            let (store, mapping) = try farewellMapping(context, tool: toolCatID)
            let family = try await farewellFamily(context, store: store), snapshot = try store.snapshot()
            guard let day = try privateFarewellDay(toolCatID, mapping.profileID) else { throw FamilySharingError.farewellDayMissing }
            try FamilyNotebookCore.validate(target: .init(familyCatID: mapping.familyCatID, field: .farewellDay), value: .day(day))
            let shared = sharedFarewell(snapshot, cat: mapping.familyCatID)
            guard let name = snapshot.fieldState(for: .init(familyCatID: mapping.familyCatID, field: .name)),
                  !name.isDeleted, case .text(let catName) = name.operation.value else { throw FamilySharingError.notAllowed }
            let preview = FamilyFarewellPreview(id: UUID(), familyID: family.familyID, familyCatID: mapping.familyCatID,
                catName: catName, day: day, currentSharedDay: shared.0, currentSharedAuthor: shared.1, expiresAt: now().addingTimeInterval(600))
            farewellPreviews = farewellPreviews.filter { $0.value.preview.expiresAt > now() }
            farewellPreviews[preview.id] = .init(preview: preview, toolCatID: toolCatID, profileID: mapping.profileID,
                directory: store.localDirectory, generation: family.generation,
                sharedOperationID: snapshot.fieldState(for: .init(familyCatID: mapping.familyCatID, field: .farewellDay))?.operation.id)
            return preview
        }
    }
    func consentToShareFarewell(previewID: UUID, operationID: UUID) async throws {
        try await run { context in
            guard let store = context.notebook, try !store.snapshot().sharingEnded else { throw FamilySharingError.removedOrDissolved }
            if let saved = try store.farewellDecision(actionID: operationID) {
                guard saved.personID == context.identity.personID, saved.previewID == previewID, saved.day != nil else { throw FamilySharingError.farewellPreviewChanged }
                return // Durable receipt; a retry never renews a revoked decision.
            }
            guard let prepared = farewellPreviews[previewID], prepared.preview.expiresAt > now(),
                  prepared.directory == store.localDirectory else { throw FamilySharingError.farewellPreviewChanged }
            let (_, mapping) = try farewellMapping(context, tool: prepared.toolCatID)
            let family = try await farewellFamily(context, store: store)
            guard prepared.preview.expiresAt > now(), family.familyID == prepared.preview.familyID, family.generation == prepared.generation,
                  mapping.familyCatID == prepared.preview.familyCatID, mapping.profileID == prepared.profileID,
                  try privateFarewellDay(prepared.toolCatID, prepared.profileID) == prepared.preview.day else { throw FamilySharingError.farewellPreviewChanged }
            try store.consentFarewell(cat: mapping.familyCatID, day: prepared.preview.day,
                author: .init(personID: context.identity.personID, displayName: displayName()), previewID: previewID,
                expectedSharedOperationID: prepared.sharedOperationID, actionID: operationID, now: now())
        }
    }
    func revokeFarewellSharing(toolCatID: UUID, operationID: UUID) async throws {
        try await run { context in
            let (store, mapping) = try farewellMapping(context, tool: toolCatID)
            try store.revokeFarewell(cat: mapping.familyCatID,
                author: .init(personID: context.identity.personID, displayName: displayName()), actionID: operationID, now: now())
        }
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
