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
        if participation?.familyID == family, let notebook {
            // Only the private ID correspondence crosses admissions. Old edits,
            // acknowledgements and the departed outbox never resume.
            let links = try notebook.snapshot().activeMappings
            try store.applyLocalChanges(.init(familyID: family, entries: [], mappings: links),
                author: .init(personID: identity.personID, displayName: "local mapping"))
        }
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
    private let hasExistingIdentity: @MainActor () async throws -> Bool
    private let hasPersonalPlus: @MainActor () -> Bool
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
    /// 11/15 (1115q): what the last key pass saw; a changed value is progress.
    private(set) var lastKeyObservation = ""
    /// 11/16: what the last whole read did about this iPhone's writing (nil:
    /// it did not get as far as sending, e.g. paused or keys still moving
    /// without an error). Kinds only (FamilyNotebookSendHealth).
    private(set) var lastSend: FamilyNotebookSendHealth.Outcome?
    /// The person's 「もう一度」: the next read tries the set-aside writing too.
    var retriesHeldOnce = false
    private(set) var currentFamilyID: UUID?
    private(set) var memberNames: [String: String] = [:]
    private(set) var lastJoinResults: [FamilyNotebookAdmissionClient.JoinResult] = []
    private(set) var lastMembers: [FamilyNotebookAdmissionClient.Member] = []
    // 11/17: the family's representative photo (FamilyNotebookRepresentativePhoto).
    // The roster and keys of the last read stay in this service; the screens
    // get only pixels to show and what happened (the extension below).
    fileprivate struct PhotoMaterial { let familyID: UUID; let generation: Int64; let material: FamilyNotebookKeyMaterial }
    fileprivate var photoMaterial: PhotoMaterial?
    private var photoClient: (familyID: UUID, client: FamilyNotebookRepresentativePhotoClient, journal: any GroupSecretStore)?
    /// The pixels last shown for each asset: a report sends exactly these.
    private var shownPhotos: [UUID: Data] = [:]
    /// This session's delivery of each cat, sent again by 「もう一度」.
    private var photoRetries: [UUID: UUID] = [:]
    private let photoRuntimeEnabled: Bool
    private let photoTransport: any GroupHTTPTransport
    /// 11/18: one line per stage of a delivery (FamilyPhotoDeliveryLog).
    private let photoTrace: FamilyPhotoDeliveryTrace
    private let moderationRecipient: @MainActor () -> (keyID: String, publicKey: Data)?
    var notebook: FamilyNotebookStore? { session?.notebook }
    var author: FamilyNotebookAuthor? {
        guard let identity = session?.identity, let name = try? displayName() else { return nil }
        return .init(personID: identity.personID, displayName: name)
    }
    var sendsInvitations: Bool { true }

    init(provider: @escaping SessionProvider, billing: @escaping @MainActor () async throws -> Void,
         displayName: @escaping @MainActor () throws -> String, catNames: @escaping @MainActor () -> [String],
         privateFarewellDay: @escaping @MainActor (UUID, UUID?) throws -> String? = { _, _ in nil },
         now: @escaping @MainActor () -> Date = { Date() },
         hasPersonalPlus: @escaping @MainActor () -> Bool = { false },
         hasExistingIdentity: @escaping @MainActor () async throws -> Bool = { true },
         photoRuntimeEnabled: Bool = false, photoTransport: any GroupHTTPTransport = GroupURLSessionTransport(),
         moderationRecipient: @escaping @MainActor () -> (keyID: String, publicKey: Data)? = { nil },
         photoTrace: @escaping FamilyPhotoDeliveryTrace = { FamilyPhotoDeliveryLog.system($0) }) {
        self.provider = provider; self.billing = billing; self.displayName = displayName; self.catNames = catNames
        self.privateFarewellDay = privateFarewellDay; self.now = now
        self.hasPersonalPlus = hasPersonalPlus; self.hasExistingIdentity = hasExistingIdentity
        self.photoRuntimeEnabled = photoRuntimeEnabled; self.photoTransport = photoTransport; self.photoTrace = photoTrace
        self.moderationRecipient = moderationRecipient
    }
    private func run<T>(_ action: (FamilyNotebookSession) async throws -> T) async throws -> T {
        guard !working else { throw FamilySharingError.unknownOutcome }
        working = true; defer { working = false }
        do {
            let context: FamilyNotebookSession
            if let session { context = session } else { context = try await provider(); session = context }
            return try await action(context)
        } catch is CancellationError { throw CancellationError() }
        catch { throw Self.presentation(error) }
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
        guard try await hasExistingIdentity() else {
            currentFamilyID = nil; lastMembers = []; session = nil; photoMaterial = nil; photoClient = nil
            return .notInFamily
        }
        lastSend = nil
        let retryHeld = retriesHeldOnce
        retriesHeldOnce = false
        return try await run { context in
          do {
            needsAnotherPass = false
            try await context.admission.resumePending()
            try await context.membership.resumePending(notebook: context.notebook)
            let directory = try await context.admission.directory()
            lastJoinResults = directory.joinRequests ?? []
            guard let family = directory.family else {
                currentFamilyID = nil; lastMembers = []; photoMaterial = nil
                try context.confirmedOutsideFamily()
                return directory.pendingRequests.isEmpty ? .notInFamily : .pendingApproval
            }
            // Both reads use fresh signed requests. Validate the combined generation
            // before activation; concurrent reads never authorize stale membership.
            async let memberRead = context.admission.members(family.familyID)
            async let payerRead = context.membership.loadPayer(familyID: family.familyID, minimumGeneration: family.generation)
            let members = try await memberRead
            guard members.generation >= family.generation,
                  let own = members.members.first(where: { $0.personID == context.identity.personID }),
                  own.identityPublicKey == context.identity.personPublicKey else { throw FamilyNotebookTransportError.invalidResponse }
            let state = try await payerRead.validated(family: family.familyID.uuidString.lowercased(),
                person: context.identity.personID, minimumGeneration: members.generation)
            let store = try context.activate(family: family.familyID, admittedGeneration: own.admittedGeneration)
            currentFamilyID = family.familyID; lastMembers = members.members
            memberNames = try await context.admission.knownNames(family: family.familyID)
            // Paused sharing still has a real membership and a retained local
            // notebook. Do not turn a write-gate rejection into an endless spinner.
            if state.sharingStatus == .paused { return .inFamily(.init(role: state.role == .payer ? .payer : .member)) }
            let prepared = try await context.keys.prepare(family: family.familyID)
            lastKeyObservation = await context.keys.observation
            guard let material = prepared else { needsAnotherPass = true; return .waitingForKeys }
            guard material.ready, !material.moreWork else { needsAnotherPass = true; return .waitingForKeys }
            photoMaterial = .init(familyID: family.familyID, generation: members.generation, material: material)
            let sync = try FamilyNotebookSync(familyID: family.familyID, identity: context.identity, store: store,
                network: context.wire, journal: context.journal, endpointID: context.endpoint.absoluteString)
            let result = try await sync.synchronize(current: material.current, history: material.history,
                                                    keys: material.keys, retryHeld: retryHeld)
            lastSend = result.paused || result.needsRotation ? nil
                : .sent(heldBack: result.heldBack, failure: result.heldFailure?.rawValue)
            needsAnotherPass = result.moreHistory || result.needsRotation
            if needsAnotherPass { return .waitingForKeys }
            return .inFamily(.init(role: state.role == .payer ? .payer : .member))
          } catch {
            // 11/16: the kind, before it becomes the screens' error.
            lastSend = .failed(FamilyNotebookSendFailure.kind(of: error).rawValue)
            throw error
          }
        }
    }
    func loadPause() async throws -> FamilySharingPause? {
        try await run { context in
            // An existing member who just purchased/restored must connect that
            // verified billing credential before the relay can offer payer claim.
            // This neither creates family membership nor buys a subscription.
            _ = try await family(context)
            if hasPersonalPlus() { try await billing() }
            return FamilySharingPause(try await payer(context))
        }
    }

    private func farewellMapping(_ context: FamilyNotebookSession, tool: UUID) throws -> (FamilyNotebookStore, FamilyNotebookLocalMapping) {
        guard let store = context.notebook else { throw FamilySharingError.membershipChecking }
        let snapshot = try store.snapshot()
        guard !snapshot.sharingEnded else { throw FamilySharingError.removedOrDissolved }
        let mappings = snapshot.activeMappings.filter { $0.recordID == nil && $0.toolCatID == tool }
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

/// 11/17: one family cat's representative photo, as the screens get it.
enum FamilyNotebookPhotoLoad: Equatable, Sendable {
    /// Pixels to show on the cat's page only: never the photo list, a
    /// widget, the archive or the library.
    case shown(assetID: UUID, authorID: String, jpeg: Data)
    /// This person chose not to show this author's photos here.
    case hidden(authorID: String)
    /// None, cleared, reported, stopped or replaced: のわ again.
    case none
}

enum FamilyNotebookPhotoFailure: Error, Equatable {
    /// 「家族の手帳の写真が上限です」.
    case limited
    case failed
    /// Off, or nothing to send (no shown photo, no moderation recipient).
    case unavailable
}

/// 11/17: the representative photo (FamilyNotebookRepresentativePhotoClient
/// behind it). Every call starts from a person's tap or a page that is shown;
/// nothing here sends a photo by itself. Off (`photoRuntimeEnabled` false),
/// every call throws before any network.
@available(iOS 17.0, macOS 14.0, *)
extension ProductionFamilyNotebookSharingService {
    var representativePhotosEnabled: Bool { photoRuntimeEnabled }
    var personID: String? { session?.identity.personID }

    fileprivate func photoContext() throws -> (session: FamilyNotebookSession, store: FamilyNotebookStore, material: PhotoMaterial,
                                          client: FamilyNotebookRepresentativePhotoClient, journal: any GroupSecretStore) {
        guard photoRuntimeEnabled else { throw FamilyNotebookPhotoFailure.unavailable }
        guard let session, let store = session.notebook, let material = photoMaterial,
              let snapshot = try? store.snapshot(), !snapshot.sharingEnded, snapshot.familyID == material.familyID
        else { throw FamilySharingError.membershipChecking }
        if let photoClient, photoClient.familyID == material.familyID {
            return (session, store, material, photoClient.client, photoClient.journal)
        }
        // Its own journal beside the notebook's: ciphertext, receipts and this
        // person's 「表示しない」, never the notebook's keys.
        let journal = try GroupOperationStore(directory: session.directory.deletingLastPathComponent()
            .appendingPathComponent("representative-photo", isDirectory: true), maximumRecordBytes: 2_100_000)
        let client = FamilyNotebookRepresentativePhotoClient(familyID: material.familyID, endpoint: session.endpoint,
            identity: session.identity, transport: photoTransport, journal: journal, runtimeEnabled: photoRuntimeEnabled)
        photoClient = (material.familyID, client, journal)
        return (session, store, material, client, journal)
    }

    /// The reference in the verified notebook and who wrote it; nil: none or cleared.
    private func photoReference(_ snapshot: FamilyNotebookSnapshot, cat: UUID, familyID: UUID) throws
        -> (reference: FamilyNotebookRepresentativePhotoReference, authorID: String)? {
        guard let field = snapshot.fieldState(for: .init(familyCatID: cat, field: .representativePhoto)),
              !field.isDeleted, case .text(let text) = field.operation.value else { return nil }
        let reference = try GroupWire.decode(FamilyNotebookRepresentativePhotoReference.self, Data(text.utf8))
        try reference.validate()
        guard reference.slotID == FamilyNotebookRepresentativePhotoCrypto.slotID(familyID: familyID, catID: cat)
        else { throw FamilyNotebookCryptoError.untrusted }
        return (reference, field.operation.author.personID)
    }

    /// The roster of an earlier key epoch, through the chain to the current one.
    private func photoRoster(_ material: FamilyNotebookKeyMaterial, epoch: Int) throws -> VerifiedFamilyNotebookRoster {
        var context = FamilyNotebookKeyContext.current(material.current)
        while context.source.roster.epoch > epoch {
            guard let previous = material.history[context.source.roster.epoch - 1] else { throw FamilyNotebookCryptoError.untrusted }
            context = try context.previous(previous)
        }
        guard context.source.roster.epoch == epoch else { throw FamilyNotebookCryptoError.untrusted }
        return context.source
    }

    /// Who delivered the cat's photo, from this copy only (no network).
    func representativePhotoAuthor(familyCatID: UUID) -> String? {
        guard photoRuntimeEnabled, let familyID = photoMaterial?.familyID,
              let snapshot = try? session?.notebook?.snapshot() else { return nil }
        do { return try photoReference(snapshot, cat: familyCatID, familyID: familyID)?.authorID } catch { return nil }
    }

    /// The photos to show. A cat missing from the answer could not be read
    /// this time: the screen keeps what it shows. Thrown: nothing was read.
    func representativePhotos(familyCatIDs: [UUID]) async throws -> [UUID: FamilyNotebookPhotoLoad] {
        let context = try photoContext()
        let snapshot = try context.store.snapshot()
        var result: [UUID: FamilyNotebookPhotoLoad] = [:]
        var references: [UUID: (reference: FamilyNotebookRepresentativePhotoReference, authorID: String)] = [:]
        for cat in familyCatIDs {
            do {
                if let found = try photoReference(snapshot, cat: cat, familyID: context.material.familyID) { references[cat] = found }
                else { result[cat] = FamilyNotebookPhotoLoad.none }
            } catch { continue }
        }
        guard !references.isEmpty else { return result }
        let hidden = try await context.client.hiddenAuthors()
        let slots = try await context.client.slots()
        for (cat, found) in references {
            if hidden.contains(found.authorID) { result[cat] = .hidden(authorID: found.authorID); continue }
            guard let slot = slots.first(where: { $0.slotID == found.reference.slotID }), let asset = slot.assetID else {
                result[cat] = FamilyNotebookPhotoLoad.none; continue
            }
            // A newer photo than this copy has read: keep what is shown until the next read.
            guard asset == found.reference.assetID else { continue }
            do {
                let roster = try photoRoster(context.material.material, epoch: found.reference.keyEpoch)
                if let jpeg = try await context.client.image(slot: slot, reference: found.reference, roster: roster,
                                                             verifiedAuthorID: found.authorID) {
                    shownPhotos[asset] = jpeg
                    result[cat] = .shown(assetID: asset, authorID: found.authorID, jpeg: jpeg)
                } else {
                    shownPhotos[asset] = nil
                    result[cat] = FamilyNotebookPhotoLoad.none
                }
            } catch is CancellationError { throw CancellationError() } catch { continue }
        }
        return result
    }

    /// Only after 「家族に写真を届けますか」→［届ける］. The client keeps the
    /// encrypted delivery for 「もう一度」, which sends the same one.
    func deliverRepresentativePhoto(familyCatID: UUID, source: Data) async throws {
        let trace = photoTrace
        let context: (session: FamilyNotebookSession, store: FamilyNotebookStore, material: PhotoMaterial,
                      client: FamilyNotebookRepresentativePhotoClient, journal: any GroupSecretStore)
        do { context = try photoContext() }
        catch { trace(.init(stage: .contextUnavailable, code: Self.photoTraceCode(error))); throw error }
        guard let author else { trace(.init(stage: .authorMissing)); throw FamilySharingError.signInExpired }
        let snapshot = try context.store.snapshot()
        guard snapshot.activeMappings.contains(where: { $0.familyCatID == familyCatID }) else {
            trace(.init(stage: .catNotInNotebook)); throw FamilySharingError.notAllowed
        }
        let current = context.material.material.current
        guard let key = context.material.material.keys[current.roster.epoch] else {
            trace(.init(stage: .keyMissing)); throw FamilySharingError.membershipChecking
        }
        trace(.init(stage: .keyReady))
        let slotID = FamilyNotebookRepresentativePhotoCrypto.slotID(familyID: context.material.familyID, catID: familyCatID)
        let revision: Int
        do { revision = try await context.client.slots().first { $0.slotID == slotID }?.revision ?? 0 }
        catch {
            trace(.init(stage: .stateListFailed, status: Self.photoTraceStatus(error), code: FamilyPhotoDeliveryLog.code(of: error)))
            throw Self.photoFailure(error)
        }
        trace(.init(stage: .stateListed))
        let target = FamilyNotebookTarget(familyCatID: familyCatID, field: .representativePhoto)
        let pending: FamilyNotebookRepresentativePhotoClient.Pending
        do {
            pending = try FamilyNotebookRepresentativePhotoClient.prepare(source: source, familyID: context.material.familyID,
                catID: familyCatID, expectedRevision: revision, generation: context.material.generation,
                nextClock: snapshot.clock + 1, author: author, identity: context.session.identity, roster: current,
                epochKey: key, observedOperationIDs: FamilyNotebookCore.observedFrontier(target: target, operations: snapshot.operations))
        } catch { trace(.init(stage: .prepareFailed, code: FamilyPhotoDeliveryLog.code(of: error))); throw error }
        trace(.init(stage: .imagePrepared))
        photoRetries[familyCatID] = pending.reservation.operationID
        try await send(pending, context.client, context.store, context.material.material)
        photoRetries[familyCatID] = nil
    }

    /// 「もう一度」: the same encrypted delivery, never a second one.
    func retryRepresentativePhoto(familyCatID: UUID) async throws {
        let context = try photoContext()
        guard let id = photoRetries[familyCatID],
              let pending = try await context.client.pendingDeliveries().first(where: { $0.reservation.operationID == id })
        else { photoTrace(.init(stage: .retryNothingPending)); throw FamilyNotebookPhotoFailure.failed }
        try await send(pending, context.client, context.store, context.material.material)
        photoRetries[familyCatID] = nil
    }

    private func send(_ pending: FamilyNotebookRepresentativePhotoClient.Pending, _ client: FamilyNotebookRepresentativePhotoClient,
                      _ store: FamilyNotebookStore, _ material: FamilyNotebookKeyMaterial) async throws {
        do { try await client.deliver(pending, trace: photoTrace) }
        catch {
            photoTrace(.init(stage: .deliveryFailed, status: Self.photoTraceStatus(error), code: FamilyPhotoDeliveryLog.code(of: error)))
            throw Self.photoFailure(error)
        }
        // Into this copy at once, as a received operation: its clock moves
        // past it, and the next read finds the reference here.
        if let key = material.keys[pending.reservation.keyEpoch],
           let roster = try? photoRoster(material, epoch: pending.reservation.keyEpoch),
           let received = try? FamilyNotebookOperationCrypto.openRetaining(pending.operation, roster: roster, key: key) {
            try? store.receiveRetaining([received])
        }
    }

    private static func photoTraceStatus(_ error: Error) -> Int? {
        if case FamilyNotebookTransportError.server(_, let status) = error { return status }
        return nil
    }

    /// The fixed word for a local failure before the network (FamilyPhotoDeliveryLog).
    private static func photoTraceCode(_ error: Error) -> String {
        if let error = error as? FamilySharingError {
            switch error {
            case .membershipChecking: return "membership_checking"
            case .signInExpired: return "sign_in_expired"
            case .notAllowed: return "not_allowed"
            default: return "sharing_other"
            }
        }
        if let error = error as? FamilyNotebookPhotoFailure {
            switch error {
            case .unavailable: return "photo_off"
            case .failed: return "photo_failed"
            case .limited: return "photo_limited"
            }
        }
        return FamilyPhotoDeliveryLog.code(of: error)
    }

    private static func photoFailure(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if case FamilyNotebookTransportError.server(let code, _) = error, code == "photo_slots_full" {
            return FamilyNotebookPhotoFailure.limited
        }
        return FamilyNotebookPhotoFailure.failed
    }

    /// 「家族に届けた写真を消す」: an ordinary notebook write (the sync sends
    /// it with its clearPhoto effect). The next read sends it.
    func clearRepresentativePhoto(familyCatID: UUID) throws {
        let context = try photoContext()
        guard let author else { throw FamilySharingError.signInExpired }
        _ = try context.store.edit(target: .init(familyCatID: familyCatID, field: .representativePhoto), value: .clear, author: author)
    }

    func hideRepresentativePhotos(of personID: String) async throws { try await photoContext().client.hideAuthor(personID) }
    func showRepresentativePhotos(of personID: String) async throws { try await photoContext().client.unhideAuthor(personID) }

    /// The photo shown, encrypted for the team only after the person chose a
    /// reason and 「送る」. The encrypted report is kept until it is received,
    /// so 「もう一度送る」 sends the same one. Returns the report's number.
    func reportRepresentativePhoto(assetID: UUID, reasonCode: String) async throws -> String {
        let context = try photoContext()
        let account = "op:fp:report:" + assetID.uuidString.lowercased()
        let pending: FamilyNotebookRepresentativePhotoClient.PendingReport
        if let saved = try context.journal.read(account) {
            pending = try GroupWire.decode(FamilyNotebookRepresentativePhotoClient.PendingReport.self, saved)
        } else {
            guard let jpeg = shownPhotos[assetID], let recipient = moderationRecipient() else { throw FamilyNotebookPhotoFailure.unavailable }
            pending = try await context.client.prepareReport(canonicalJPEG: jpeg, assetID: assetID, reasonCode: reasonCode,
                moderationKeyID: recipient.keyID, moderationPublicKey: recipient.publicKey)
            try context.journal.write(GroupWire.encode(pending), account: account, createOnly: true)
        }
        let receipt = try await context.client.report(pending)
        try? context.journal.remove(account)
        shownPhotos[assetID] = nil
        return receipt.reportID
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
