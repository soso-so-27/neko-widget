import Foundation
import AuthenticationServices
import Combine

/// The same export transaction is used by the screen and the runtime boundary check.
enum ManagedPreservationExport {
    typealias Reauthenticate = @MainActor @Sendable (ManagedPreservationClient.SessionCheckpoint) async throws -> ManagedPreservationClient.SessionCheckpoint

    /// One explicit export owns this state. A replacement is accepted only after
    /// visible user authentication, same-owner validation and a fresh inventory fence.
    private actor ExportSession {
        let client: ManagedPreservationClient
        let reauthenticate: Reauthenticate?
        var checkpoint: ManagedPreservationClient.SessionCheckpoint
        var generation: Int?
        init(client: ManagedPreservationClient, checkpoint: ManagedPreservationClient.SessionCheckpoint,
             reauthenticate: Reauthenticate?) {
            self.client = client; self.checkpoint = checkpoint; self.reauthenticate = reauthenticate
        }
        func bind(_ value: Int) { generation = value }
        func requireCurrent() async throws { try await client.requireSessionCheckpoint(checkpoint) }
        func atCompleteBoundary() async throws {
            try Task.checkCancellation()
            // Leave room for a 120-second page and one bounded 60-second wait.
            if try await client.exportNeedsReauthentication(checkpoint, minimumLifetime: 210),
               let reauthenticate {
                let previous = checkpoint
                let replacement = try await reauthenticate(previous)
                try Task.checkCancellation()
                try await client.requireExportReplacement(replacement, for: previous)
                if let generation {
                    let current = try await client.list(forExport: true)
                    try await client.requireSessionCheckpoint(replacement)
                    guard current.generation == generation else { throw ManagedPreservationError.conflict }
                }
                checkpoint = replacement
            }
            try await requireCurrent()
        }
        func finalCheck(validate: ManagedPreservationCoordinator.ExportValidation? = nil) async throws {
            try await atCompleteBoundary()
            guard let generation else { throw ManagedPreservationError.invalidResponse }
            if let validate { try await validate() }
            try await requireCurrent()
            let current = try await client.list(forExport: true)
            try await requireCurrent()
            guard current.generation == generation else { throw ManagedPreservationError.conflict }
            if let validate { try await validate() }
            try await requireCurrent()
        }
    }

    private actor CompletedExport {
        var session: ExportSession?
        func set(_ value: ExportSession) { session = value }
        func verify(validate: @escaping ManagedPreservationCoordinator.ExportValidation) async throws {
            if let session { try await session.finalCheck(validate: validate) }
            else { try await validate() }
        }
    }

    @MainActor static func prepare(_ snapshot: ManagedPreservationExportSnapshot,
                                  using exporter: RecordExportController,
                                  validate: @escaping ManagedPreservationCoordinator.ExportValidation) {
        exporter.prepare(build: { try archive(snapshot) }, verify: validate)
    }

    static func archive(_ snapshot: ManagedPreservationExportSnapshot) throws -> PhotoMemoryNoteExportPayload {
        let document = try snapshot.document.validated()
        guard (document.photoFile != nil) == (snapshot.jpegData != nil) else {
            throw ManagedPreservationError.invalidRecord
        }
        return try PhotoMemoryNoteExporter.createArchive(text: document.text,
            capturedAt: document.capturedAt, writtenAt: document.writtenAt,
            updatedAt: document.updatedAt, catNames: document.catNames, jpegData: snapshot.jpegData, weight: document.weight)
    }

    @MainActor static func prepareAll(client: ManagedPreservationClient,
                                      using exporter: RecordExportController,
                                      validate: @escaping ManagedPreservationCoordinator.ExportValidation,
                                      reauthenticate: Reauthenticate? = nil,
                                      progress: @escaping @Sendable (Int, Int) async -> Void) {
        let completed = CompletedExport()
        exporter.prepare(build: {
            let (payload, session) = try await archiveAll(client: client, reauthenticate: reauthenticate, progress: progress)
            await completed.set(session)
            return payload
        }, verify: {
            // The first invocation precedes construction. Later verification may
            // pause for explicit authentication before checking the view's owner.
            try await completed.verify(validate: validate)
        })
    }

    private static func archiveAll(client: ManagedPreservationClient,
                                   reauthenticate: Reauthenticate?,
                                   progress: @escaping @Sendable (Int, Int) async -> Void)
        async throws -> (PhotoMemoryNoteExportPayload, ExportSession) {
        let session = ExportSession(client: client, checkpoint: try await client.captureSessionCheckpoint(),
                                    reauthenticate: reauthenticate)
        try await session.atCompleteBoundary()
        let first: ManagedPreservationExportPageFile
        do { first = try await client.exportPage() }
        catch ManagedPreservationError.exportUnsupported {
            // Compatibility with deployed pilot servers predating export pages.
            // Never use this fallback for throttling, malformed pages or partial data.
            try await session.requireCurrent()
            let (payload, generation, legacyCheckpoint) = try await archiveAllLegacy(client: client, progress: progress)
            let legacySession = ExportSession(client: client, checkpoint: legacyCheckpoint, reauthenticate: nil)
            await legacySession.bind(generation)
            return (payload, legacySession)
        }
        await session.bind(first.generation)
        let pages = ExportPages(client: client, session: session, first: first)
        var payload: PhotoMemoryNoteExportPayload?
        do {
            try await session.requireCurrent()
            let result = try await PhotoMemoryNoteExporter.createBulkArchive(recordCount: first.totalRecords,
                fetch: { index in try await pages.next(index) }, progress: progress)
            payload = result
            try await pages.finish()
            try await session.requireCurrent()
            try await session.finalCheck()
            return (result, session)
        } catch {
            // Remove both incomplete page and archive, even if either removal fails.
            var pending = (error as? PhotoMemoryNoteExportCleanupPending)?.payloads ?? []
            do { try await pages.cleanup() }
            catch let failure as PhotoMemoryNoteExportCleanupPending { pending += failure.payloads }
            if let payload {
                do { try payload.cleanup() }
                catch { pending.append(payload) }
            }
            if let first = pending.first {
                throw PhotoMemoryNoteExportCleanupPending(payload: first, additionalPayloads: Array(pending.dropFirst()))
            }
            throw error
        }
    }

    private actor ExportPages {
        let client: ManagedPreservationClient
        let session: ExportSession
        let generation: Int
        let totalRecords: Int
        var page: ManagedPreservationExportPageFile
        var completed = 0
        init(client: ManagedPreservationClient, session: ExportSession,
             first: ManagedPreservationExportPageFile) {
            self.client = client; self.session = session; self.page = first
            self.generation = first.generation; self.totalRecords = first.totalRecords
        }
        func next(_ index: Int) async throws -> PhotoMemoryNoteBulkEntry {
            guard index == completed, completed < totalRecords else { throw ManagedPreservationError.invalidResponse }
            try await session.requireCurrent()
            var data = try page.nextRecordData()
            if data == nil {
                guard let cursor = try page.nextCursor() else { throw ManagedPreservationError.invalidResponse }
                try page.cleanup()
                try await session.atCompleteBoundary()
                page = try await client.exportPage(after: cursor, generation: generation)
                guard page.generation == generation, page.totalRecords == totalRecords else {
                    throw ManagedPreservationError.conflict
                }
                data = try page.nextRecordData()
            }
            guard let data else { throw ManagedPreservationError.invalidResponse }
            let snapshot = try await client.decodeExportRecord(data)
            try await session.requireCurrent()
            let document = try snapshot.document.validated()
            completed += 1
            return PhotoMemoryNoteBulkEntry(recordID: snapshot.record.id, revision: snapshot.record.revision,
                text: document.text, capturedAt: document.capturedAt, writtenAt: document.writtenAt,
                updatedAt: document.updatedAt, catNames: document.catNames, jpegData: snapshot.jpegData, weight: document.weight)
        }
        func finish() async throws {
            try await session.requireCurrent()
            guard completed == totalRecords, try page.nextRecordData() == nil, try page.nextCursor() == nil else {
                throw ManagedPreservationError.invalidResponse
            }
            try page.cleanup()
        }
        func cleanup() throws { try page.cleanup() }
    }

    private static func archiveAllLegacy(client: ManagedPreservationClient,
                                         progress: @escaping @Sendable (Int, Int) async -> Void)
        async throws -> (PhotoMemoryNoteExportPayload, Int, ManagedPreservationClient.SessionCheckpoint) {
        let session = try await client.captureSessionCheckpoint()
        var listing: [ManagedPreservationRecord] = []
        var seen: Set<UUID> = []
        var cursor: String?
        var generation: Int?
        var previousID: String?
        repeat {
            try Task.checkCancellation()
            try await client.requireSessionCheckpoint(session)
            let page = try await client.list(after: cursor)
            try await client.requireSessionCheckpoint(session)
            if let generation, page.generation != generation { throw ManagedPreservationError.conflict }
            generation = page.generation
            guard !page.items.isEmpty || page.nextCursor == nil else {
                throw ManagedPreservationError.invalidResponse
            }
            for record in page.items {
                let identifier = record.id.uuidString.lowercased()
                if let previousID, identifier <= previousID {
                    throw ManagedPreservationError.invalidResponse
                }
                guard seen.insert(record.id).inserted else {
                    throw ManagedPreservationError.invalidResponse
                }
                previousID = identifier
                listing.append(record)
            }
            if let next = page.nextCursor,
               next.lowercased() != page.items.last?.id.uuidString.lowercased() {
                throw ManagedPreservationError.invalidResponse
            }
            cursor = page.nextCursor
        } while cursor != nil
        guard let generation else { throw ManagedPreservationError.invalidResponse }
        let records = listing
        let payload = try await PhotoMemoryNoteExporter.createBulkArchive(
            recordCount: records.count, fetch: { index in
                let listed = records[index]
                try await client.requireSessionCheckpoint(session)
                let snapshot = try await client.detail(listed.id)
                try await client.requireSessionCheckpoint(session)
                guard snapshot.record.revision == listed.revision,
                      snapshot.document == listed.document else {
                    throw ManagedPreservationError.conflict
                }
                let document = try snapshot.document.validated()
                return PhotoMemoryNoteBulkEntry(recordID: listed.id, revision: listed.revision,
                    text: document.text, capturedAt: document.capturedAt,
                    writtenAt: document.writtenAt, updatedAt: document.updatedAt,
                    catNames: document.catNames, jpegData: snapshot.jpegData, weight: document.weight)
            }, progress: progress)
        do {
            try Task.checkCancellation()
            try await client.requireSessionCheckpoint(session)
            let current = try await client.list()
            try await client.requireSessionCheckpoint(session)
            guard current.generation == generation else { throw ManagedPreservationError.conflict }
            return (payload, generation, session)
        } catch {
            do { try payload.cleanup() }
            catch { throw PhotoMemoryNoteExportCleanupPending(payload: payload) }
            throw error
        }
    }
}

/// Owns only this screen's state. Does not enroll PhotoKit, local notes, CloudKit
/// or shared windows, and never treats a purchase/account ID as preservation identity.
@MainActor
final class ManagedPreservationCoordinator: ObservableObject {
    enum CopyState: Equatable {
        case deviceOnly, saving, stored, failed, needsConfirmation, checking

        var title: String {
            switch self {
            case .deviceOnly: "この端末のみ"
            case .saving: "保管中…"
            case .stored: "サービスに保管済み"
            case .failed: "保管できませんでした"
            case .needsConfirmation: "保管結果を確認してください"
            case .checking: "保管結果を確認中…"
            }
        }
    }
    typealias ExportValidation = @MainActor () async throws -> Void
    typealias ExportHandler = @MainActor (ManagedPreservationExportSnapshot, @escaping ExportValidation) async throws -> Void

    let isEnabled: Bool
    let canExport: Bool
    @Published private(set) var isSignedIn = false
    @Published private(set) var isBusy = false
    @Published private(set) var accountDeletionState: ManagedPreservationSessionStore.DeletionReceipt.State?
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var preparedSignIn: ManagedPreservationChallenge?
    @Published private(set) var records: [ManagedPreservationRecord] = []
    @Published private(set) var selected: ManagedPreservationExportSnapshot?
    @Published private(set) var hasMore = false
    @Published private(set) var copyState: CopyState = .deviceOnly
    var draftWasSaved: Bool { copyState == .stored }
    @Published private(set) var pendingMemoDrafts: [ManagedPreservationSessionStore.PendingMemo] = []
    @Published private(set) var draftRecoveryWarning: String?
    @Published private(set) var hasUnsecuredMemo = false
    @Published private(set) var membership: ManagedPreservationMembership?
    @Published private(set) var membershipMessage: String?
    @Published private(set) var membershipLoading = false
    @Published private(set) var saveFailureCode: String?
    @Published private(set) var saveFailureMessage: String?
    @Published private(set) var noticeContact: ManagedPreservationNoticeContact?
    @Published private(set) var retention: ManagedPreservationRetention?
    @Published private(set) var usage: ManagedPreservationUsage?
    @Published private(set) var usageLoading = false
    @Published private(set) var usageMessage: String?
    @Published private(set) var exportProgress: (completed: Int, total: Int)?
    @Published private(set) var exportAuthenticationNeeded = false
    @Published private(set) var preparedExportSignIn: ManagedPreservationChallenge?
    @Published var consentToNewSave = false
    @Published var editedText = ""

    let draft: ManagedPreservationDraft?
    private let client: ManagedPreservationClient
    private let onExport: ExportHandler?
    private let draftStore: ManagedPreservationSessionStore
    private var task: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?
    private var usageRequestID = UUID()
    private var membershipTask: Task<Void, Never>?
    private var membershipRequestID = UUID()
    private var viewEpoch = UUID()
    private var nextCursor: String?
    private var listingGeneration: Int?
    private var authenticatedOwnerID: String?
    private var editingDraftID = UUID()
    // Fallback only when Keychain is locked/unavailable. Never published for another owner.
    private var volatileDrafts: [UUID: ManagedPreservationSessionStore.PendingMemo] = [:]
    private var unsecuredMemoIDs: Set<UUID> = []
    private var copyStates: [String: CopyState] = [:]
    private struct ExportRenewal {
        let id: UUID
        let ticket: UUID
        let checkpoint: ManagedPreservationClient.SessionCheckpoint
        let continuation: CheckedContinuation<ManagedPreservationClient.SessionCheckpoint, Error>
    }
    private var exportRenewal: ExportRenewal?

    private func setCopyState(_ state: CopyState, owner: String) {
        copyStates[owner] = state
        if authenticatedOwnerID == owner { copyState = state }
    }

    init(configuration: ManagedPreservationConfiguration = .current,
         draft: ManagedPreservationDraft? = nil, onExport: ExportHandler? = nil,
         client injectedClient: ManagedPreservationClient? = nil) {
        isEnabled = configuration.isEnabled
        client = injectedClient ?? ManagedPreservationClient(configuration: configuration)
        draftStore = ManagedPreservationSessionStore(origin: configuration.origin?.absoluteString ?? "disabled")
        self.draft = draft; self.onExport = onExport; canExport = onExport != nil
    }

    func start() {
        guard isEnabled else { return }
        run { ticket in
            self.clearAccountPresentation()
            self.accountDeletionState = try await self.client.savedDeletionState()
            if self.accountDeletionState != nil {
                if self.accountDeletionState != .completed && self.accountDeletionState != .requestedElsewhere {
                    do { self.accountDeletionState = try await self.client.checkAccountDeletion() }
                    catch ManagedPreservationError.deletionNotReceived {
                        try await self.client.reloadSessionFromSecureStorage()
                        self.isSignedIn = try await self.client.hasSession()
                        if !self.isSignedIn { self.preparedSignIn = try await self.client.prepareSignIn() }
                        throw ManagedPreservationError.deletionNotReceived
                    }
                }
                return
            }
            try await self.client.reloadSessionFromSecureStorage()
            let authenticated = try await self.client.hasSession()
            try self.check(ticket)
            self.isSignedIn = authenticated
            if authenticated { try await self.loadFirstPage(ticket) }
            else {
                let challenge = try await self.client.prepareSignIn()
                try self.check(ticket)
                self.preparedSignIn = challenge
            }
        }
    }

    func prepareSignIn() {
        run { ticket in
            try await self.client.reloadSessionFromSecureStorage()
            let challenge = try await self.client.prepareSignIn()
            try self.check(ticket)
            self.preparedSignIn = challenge
        }
    }

    func completeSignIn(_ result: Result<ASAuthorization, Error>) {
        guard preparedSignIn != nil, !isBusy else { return }
        preparedSignIn = nil
        run { ticket in
            switch result {
            case .success(let authorization):
                guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let token = apple.identityToken, let code = apple.authorizationCode else {
                    await self.client.cancelSignIn()
                    throw ManagedPreservationError.authenticationStepFailed(.credential)
                }
                try await self.client.finishSignIn(state: apple.state, identityToken: token, authorizationCode: code)
                try self.check(ticket)
                self.isSignedIn = true
                self.consentToNewSave = false
                self.membership = nil; self.membershipMessage = nil
                self.noticeContact = nil
                self.retention = nil
                try await self.loadFirstPage(ticket)
            case .failure(let error):
                await self.client.cancelSignIn()
                if (error as? ASAuthorizationError)?.code == .canceled {
                    self.statusMessage = "本人確認をキャンセルしました。写真やメモは送信していません。"
                    return
                }
                if let appleError = error as? ASAuthorizationError {
                    // Only a bounded system code, never the error's message or userInfo.
                    let code = appleError.code.rawValue
                    throw ManagedPreservationError.appleAuthorizationFailed((1000...1006).contains(code) ? code : 1099)
                }
                throw ManagedPreservationError.authenticationStepFailed(.appleResponse)
            }
        }
    }

    func signOut() {
        cancelCurrentWork()
        clearAccountPresentation()
        run { ticket in
            try await self.client.signOut()
            try self.check(ticket)
            self.statusMessage = "この端末の保管用ログインを解除しました。保管記録は削除していません。"
        }
    }

    func deleteServiceAccount() {
        guard !isBusy, !hasUnsecuredMemo else { return }
        run { ticket in
            do {
                try await self.client.requestAccountDeletion()
                try self.check(ticket)
                self.clearAccountPresentation()
                self.accountDeletionState = try await self.client.savedDeletionState()
            } catch {
                self.accountDeletionState = try? await self.client.savedDeletionState()
                throw error
            }
        }
    }

    func checkAccountDeletion() {
        run { ticket in
            let state = try await self.client.checkAccountDeletion()
            try self.check(ticket)
            self.clearAccountPresentation()
            self.accountDeletionState = state
        }
    }

    func dismissCompletedDeletion() {
        run { ticket in
            try await self.client.dismissCompletedDeletion()
            try self.check(ticket)
            self.accountDeletionState = nil
            self.preparedSignIn = try await self.client.prepareSignIn()
        }
    }

    func refresh() {
        run { ticket in try await self.loadFirstPage(ticket) }
    }

    func refreshUsage() {
        guard isSignedIn, let owner = authenticatedOwnerID else { return }
        loadUsage(viewEpoch, owner: owner)
    }

    /// Eligibility is read-only and independent of listing/export. Linking is
    /// still an explicit, separately consented operation.
    func checkMembership() {
        guard isSignedIn, !isBusy, let owner = authenticatedOwnerID else { return }
        loadMembership(viewEpoch, owner: owner)
    }

    func checkNoticeContact() {
        guard isSignedIn, !isBusy else { return }
        noticeContact = nil
        run { ticket in
            let owner = try await self.requireCurrentOwner(ticket)
            let result = try await self.client.noticeContact()
            guard try await self.requireCurrentOwner(ticket) == owner else {
                throw ManagedPreservationError.staleSession
            }
            self.noticeContact = result
        }
    }

    func checkRetention() {
        guard isSignedIn, !isBusy else { return }
        retention = nil
        run { ticket in
            let owner = try await self.requireCurrentOwner(ticket)
            let result = try await self.client.retention()
            guard try await self.requireCurrentOwner(ticket) == owner else {
                throw ManagedPreservationError.staleSession
            }
            self.retention = result
        }
    }

    func connectMembership(consent: Bool) {
        guard isSignedIn, consent, !isBusy else { return }
        membershipTask?.cancel(); membershipTask = nil; membershipRequestID = UUID(); membershipLoading = false
        membership = nil; membershipMessage = "接続結果が不明な場合は「接続状況を確認」で確かめられます。"
        retention = nil
        run { ticket in
            let owner = try await self.requireCurrentOwner(ticket)
            let result = try await self.client.linkMembership(consent: true)
            guard try await self.requireCurrentOwner(ticket) == owner else { throw ManagedPreservationError.staleSession }
            self.membership = result; self.membershipMessage = nil
            self.retention = nil
            self.statusMessage = "会員情報を接続しました。購入や写真の送信は行っていません。"
        }
    }

    func loadMore() {
        guard let after = nextCursor, let generation = listingGeneration else { return }
        run { ticket in
            let page = try await self.client.list(after: after)
            try self.check(ticket)
            guard page.generation == generation,
                  Set(self.records.map(\.id)).isDisjoint(with: page.items.map(\.id)) else {
                self.nextCursor = nil; self.hasMore = false
                throw ManagedPreservationError.conflict
            }
            self.records.append(contentsOf: page.items)
            self.nextCursor = page.nextCursor; self.hasMore = page.nextCursor != nil
        }
    }

    func open(_ record: ManagedPreservationRecord) {
        guard !isBusy else { return }
        retainUnsentEdit()
        selected = nil; editedText = ""
        editingDraftID = UUID()
        run { ticket in
            let owner = try await self.requireCurrentOwner(ticket)
            let snapshot = try await self.client.detail(record.id)
            guard try await self.requireCurrentOwner(ticket) == owner else {
                throw ManagedPreservationError.staleSession
            }
            self.selected = snapshot; self.editedText = snapshot.document.text
        }
    }

    func closeDetail() {
        guard !isBusy else { return }
        retainUnsentEdit()
        guard !hasUnsecuredMemo else { return }
        selected = nil; editedText = ""
    }

    func saveSelectedCopy() {
        guard let draft, !isBusy, copyState == .deviceOnly || copyState == .failed,
              consentToNewSave, membership?.canSave == true else { return }
        saveFailureCode = nil; saveFailureMessage = nil
        run { ticket in
            let owner: String
            do { owner = try await self.requireCurrentOwner(ticket) }
            catch { try self.check(ticket); self.rememberSaveFailure(error); throw error }
            self.setCopyState(.saving, owner: owner)
            do {
                _ = try await self.client.put(draft, consent: true)
                guard try await self.requireCurrentOwner(ticket) == owner else {
                    throw ManagedPreservationError.staleSession
                }
            }
            catch {
                try self.check(ticket)
                // A missing response does not prove that the server rejected the write.
                // Re-read this ID before permitting another PUT; never overwrite on conflict.
                let known = error as? ManagedPreservationError
                self.rememberSaveFailure(error)
                let rejected = known.map {
                    [ManagedPreservationError.membershipRequired, .accessUnconfirmed, .consentRequired,
                     .invalidRecord, .requestRejected, .capacityReached, .rateLimited, .accountingUnavailable].contains($0)
                } ?? false
                self.setCopyState(rejected ? .failed : .needsConfirmation, owner: owner)
                if let known = error as? ManagedPreservationError,
                   known == .membershipRequired || known == .accessUnconfirmed {
                    self.membership = nil
                    self.membershipMessage = "会員資格の確認が必要です。接続状況を確認してから、もう一度お試しください。"
                }
                throw error
            }
            try self.check(ticket)
            self.setCopyState(.stored, owner: owner)
            self.saveFailureCode = nil; self.saveFailureMessage = nil
            self.statusMessage = "選んだ記録のコピーを保管しました。元の写真・メモは変更していません。"
            try await self.loadFirstPage(ticket)
        }
    }

    func confirmCopyResult() {
        guard let draft, !isBusy, copyState == .needsConfirmation else { return }
        run { ticket in
            let owner = try await self.requireCurrentOwner(ticket)
            guard self.copyStates[owner] == .needsConfirmation else { throw ManagedPreservationError.staleSession }
            self.setCopyState(.checking, owner: owner)
            do {
                let existing = try await self.client.detail(draft.recordID)
                guard try await self.requireCurrentOwner(ticket) == owner else {
                    throw ManagedPreservationError.staleSession
                }
                // updatedAt belongs to the server. Every client-owned field and photo must match.
                // Compare the exact millisecond-precision wire representation, not Date() fractions.
                var expected = try ManagedPreservationWire.decoder().decode(ManagedPreservationDocument.self,
                    from: ManagedPreservationWire.encoder().encode(draft.document))
                expected.updatedAt = existing.document.updatedAt
                guard existing.document == expected, existing.jpegData == draft.jpegData else {
                    throw ManagedPreservationError.conflict
                }
                self.setCopyState(.stored, owner: owner)
                self.saveFailureCode = nil; self.saveFailureMessage = nil
                self.statusMessage = "選んだ写真とメモが保管済みであることを確認しました。"
                try await self.loadFirstPage(ticket)
            } catch {
                try self.check(ticket)
                if self.copyState != .stored, (error as? ManagedPreservationError) == .notFound {
                    self.setCopyState(.failed, owner: owner)
                    self.statusMessage = "この記録は保管されていませんでした。元の写真とメモは端末に残っています。もう一度保管できます。"
                    return
                }
                if self.copyState != .stored {
                    self.setCopyState((error as? ManagedPreservationError) == .notFound ? .failed : .needsConfirmation,
                                      owner: owner)
                }
                throw error
            }
        }
    }

    func saveEditedNote() {
        guard let original = selected else { return }
        let text = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Persist before the first suspension, including a request that may expire.
        retainUnsentEdit()
        run { ticket in
            let owner = try await self.requireCurrentOwner(ticket)
            var document = original.document
            document.text = text
            // The server owns updatedAt. Preserve both other dates, including null.
            let draft = ManagedPreservationDraft(recordID: original.record.id,
                                                  document: document, jpegData: original.jpegData)
            _ = try await self.client.put(draft, expectedRevision: original.record.revision, consent: false)
            try self.check(ticket)
            let updated = try await self.client.detail(original.record.id)
            guard try await self.requireCurrentOwner(ticket) == owner else {
                throw ManagedPreservationError.staleSession
            }
            self.removePendingMemo(self.editingDraftID, owner: owner)
            self.selected = updated; self.editedText = updated.document.text
            self.statusMessage = "保管したコピーのメモを更新しました。端末の元メモは変更していません。"
            self.records = self.records.map { $0.id == updated.record.id ? updated.record : $0 }
            self.nextCursor = nil; self.hasMore = false
        }
    }

    func deleteSelectedCopy() {
        guard let original = selected else { return }
        retainUnsentEdit()
        run { ticket in
            try await self.client.delete(original.record)
            try self.check(ticket)
            self.selected = nil; self.editedText = ""
            self.statusMessage = "保管したコピーを削除しました。端末の元の写真・メモは削除していません。"
            try await self.loadFirstPage(ticket)
        }
    }

    func exportSelectedCopy() {
        guard let original = selected, let onExport else { return }
        run { ticket in
            let owner = try await self.requireCurrentOwner(ticket)
            // Refetch to reject deletion/revision changes before handing data to the host.
            let verified = try await self.client.detail(original.record.id)
            guard try await self.requireCurrentOwner(ticket) == owner else {
                throw ManagedPreservationError.staleSession
            }
            guard verified.record.revision == original.record.revision else { throw ManagedPreservationError.conflict }
            let validate: ExportValidation = {
                try self.check(ticket)
                guard try await self.requireCurrentOwner(ticket) == owner else {
                    throw ManagedPreservationError.staleSession
                }
                let current = try await self.client.detail(original.record.id)
                guard try await self.requireCurrentOwner(ticket) == owner else {
                    throw ManagedPreservationError.staleSession
                }
                guard current.record.id == verified.record.id,
                      current.record.revision == verified.record.revision else {
                    throw ManagedPreservationError.conflict
                }
                try self.check(ticket)
            }
            // Host must invoke validate after building and immediately before sharing.
            try await onExport(verified, validate)
            try self.check(ticket)
        }
    }

    func exportAllCopies(using exporter: RecordExportController) {
        guard isSignedIn, !isBusy, canExport else { return }
        run { ticket in
            let owner = try await self.requireCurrentOwner(ticket)
            self.usageTask?.cancel(); self.usageTask = nil; self.usageRequestID = UUID()
            self.membershipTask?.cancel(); self.membershipTask = nil; self.membershipRequestID = UUID()
            self.membershipLoading = false; self.usageLoading = false
            self.exportProgress = (0, 0)
            let validate: ExportValidation = {
                try self.check(ticket)
                guard try await self.requireCurrentOwner(ticket) == owner else {
                    throw ManagedPreservationError.staleSession
                }
            }
            ManagedPreservationExport.prepareAll(client: self.client, using: exporter,
                validate: validate, reauthenticate: { [weak self] checkpoint in
                    guard let self else { throw CancellationError() }
                    return try await self.requestExportReauthentication(checkpoint, ticket: ticket)
                }, progress: { [weak self] completed, total in
                    await MainActor.run {
                        guard let self, self.viewEpoch == ticket,
                              self.authenticatedOwnerID == owner else { return }
                        self.exportProgress = (completed, total)
                    }
                })
        }
    }

    private func requestExportReauthentication(_ checkpoint: ManagedPreservationClient.SessionCheckpoint,
                                               ticket: UUID) async throws -> ManagedPreservationClient.SessionCheckpoint {
        try check(ticket)
        _ = try await client.exportNeedsReauthentication(checkpoint, minimumLifetime: 0)
        try check(ticket)
        guard exportRenewal == nil, authenticatedOwnerID == checkpoint.ownerID else {
            throw ManagedPreservationError.staleSession
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let progress = exportProgress
                exportRenewal = ExportRenewal(id: id, ticket: ticket, checkpoint: checkpoint, continuation: continuation)
                exportAuthenticationNeeded = true
                clearAccountPresentation()
                exportProgress = progress
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelExportReauthentication(id: id) }
        }
    }

    /// A visible button is the only entry into a replacement Apple challenge.
    func prepareExportSignIn() {
        guard let renewal = exportRenewal, !isBusy else { return }
        run { ticket in
            do {
                guard ticket == renewal.ticket, self.exportRenewal?.id == renewal.id else { throw CancellationError() }
                let challenge = try await self.client.prepareExportSignIn(replacing: renewal.checkpoint)
                try self.check(ticket)
                guard self.exportRenewal?.id == renewal.id else { throw CancellationError() }
                self.preparedExportSignIn = challenge
            } catch {
                self.finishExportReauthentication(id: renewal.id, result: .failure(error))
                throw error
            }
        }
    }

    func completeExportSignIn(_ result: Result<ASAuthorization, Error>) {
        guard let renewal = exportRenewal, preparedExportSignIn != nil, !isBusy else { return }
        preparedExportSignIn = nil
        run { ticket in
            do {
                guard ticket == renewal.ticket, self.exportRenewal?.id == renewal.id else { throw CancellationError() }
                switch result {
                case .success(let authorization):
                    guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
                          let token = apple.identityToken, let code = apple.authorizationCode else {
                        throw ManagedPreservationError.authenticationStepFailed(.credential)
                    }
                    try await self.client.finishSignIn(state: apple.state, identityToken: token, authorizationCode: code)
                case .failure:
                    await self.client.cancelSignIn()
                    throw CancellationError()
                }
                let replacement = try await self.client.captureSessionCheckpoint()
                try await self.client.requireExportReplacement(replacement, for: renewal.checkpoint)
                try self.check(ticket)
                guard self.exportRenewal?.id == renewal.id else { throw CancellationError() }
                self.isSignedIn = true
                try await self.loadFirstPage(ticket)
                self.finishExportReauthentication(id: renewal.id, result: .success(replacement))
            } catch {
                self.finishExportReauthentication(id: renewal.id, result: .failure(error))
                throw error
            }
        }
    }

    private func finishExportReauthentication(id: UUID,
        result: Result<ManagedPreservationClient.SessionCheckpoint, Error>) {
        guard let renewal = exportRenewal, renewal.id == id else { return }
        exportRenewal = nil; exportAuthenticationNeeded = false; preparedExportSignIn = nil
        renewal.continuation.resume(with: result)
    }

    func cancelExportReauthentication(id: UUID? = nil) {
        guard let renewal = exportRenewal, id == nil || id == renewal.id else { return }
        task?.cancel()
        if let state = preparedExportSignIn?.state {
            Task { await client.cancelSignIn(ifState: state) }
        }
        finishExportReauthentication(id: renewal.id, result: .failure(CancellationError()))
    }

    /// View disappearance cancels network work and drops this screen's sensitive copies.
    /// A dispatched write might still have reached the server; re-read on returning.
    func stop() {
        retainUnsentEdit()
        if let owner = authenticatedOwnerID, copyState == .saving || copyState == .checking {
            setCopyState(.needsConfirmation, owner: owner)
        }
        cancelCurrentWork()
        preparedSignIn = nil; selected = nil; editedText = ""; records = []
        nextCursor = nil; listingGeneration = nil; hasMore = false
        consentToNewSave = false
        membership = nil; membershipMessage = nil
        saveFailureCode = nil; saveFailureMessage = nil
        noticeContact = nil
        retention = nil
        usage = nil; usageLoading = false; usageMessage = nil
        authenticatedOwnerID = nil; pendingMemoDrafts = []
        copyState = .deviceOnly
        exportProgress = nil
    }

    private func loadFirstPage(_ ticket: UUID) async throws {
        let requestedOwner = try await client.sessionOwnerID()
        try check(ticket)
        if authenticatedOwnerID != requestedOwner {
            // A local session change is enough to hide the former owner's presentation.
            // Drafts are still exposed only after this new session's list is accepted.
            records = []; pendingMemoDrafts = []; copyState = .deviceOnly
            authenticatedOwnerID = nil
        }
        let page = try await client.list()
        try check(ticket)
        records = page.items; nextCursor = page.nextCursor
        listingGeneration = page.generation; hasMore = page.nextCursor != nil
        // Only expose drafts after the service accepted this session's list request.
        guard let owner = try await client.sessionOwnerID() else {
            throw ManagedPreservationError.authenticationRequired
        }
        try check(ticket)
        guard owner == requestedOwner else { throw ManagedPreservationError.staleSession }
        authenticatedOwnerID = owner
        copyState = copyStates[owner] ?? .deviceOnly
        var ownDrafts: [UUID: ManagedPreservationSessionStore.PendingMemo] = [:]
        do {
            ownDrafts = Dictionary(uniqueKeysWithValues: try draftStore.pendingMemos(ownerId: owner).map { ($0.id, $0) })
        } catch {
            draftRecoveryWarning = "端末の未送信メモを読み込めません。ロック解除後に一覧を更新してください。保管済みの記録は引き続き開けます。"
        }
        for value in volatileDrafts.values where value.ownerId == owner { ownDrafts[value.id] = value }
        pendingMemoDrafts = ownDrafts.values.sorted { $0.id.uuidString < $1.id.uuidString }
        hasUnsecuredMemo = !unsecuredMemoIDs.isEmpty
        loadUsage(ticket, owner: owner)
        loadMembership(ticket, owner: owner)
    }

    private func rememberSaveFailure(_ error: Error) {
        let known = error as? ManagedPreservationError
        saveFailureCode = error is CancellationError ? "S05" : known?.preservationSupportCode ?? "S99"
        saveFailureMessage = error is CancellationError ? ManagedPreservationError.interrupted.errorDescription
            : known?.errorDescription ?? ManagedPreservationError.unavailable.errorDescription
    }

    private func loadMembership(_ ticket: UUID, owner: String) {
        membershipTask?.cancel(); membershipRequestID = UUID()
        let requestID = membershipRequestID
        membership = nil; membershipMessage = nil; membershipLoading = true; retention = nil
        membershipTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.viewEpoch == ticket && self.authenticatedOwnerID == owner
                    && self.membershipRequestID == requestID {
                    self.membershipLoading = false; self.membershipTask = nil
                }
            }
            do {
                let result = try await self.client.membership()
                try self.check(ticket)
                guard try await self.client.sessionOwnerID() == owner,
                      self.authenticatedOwnerID == owner else { throw ManagedPreservationError.staleSession }
                guard self.membershipRequestID == requestID else { return }
                self.membership = result
            } catch {
                guard self.viewEpoch == ticket, self.authenticatedOwnerID == owner,
                      self.membershipRequestID == requestID, !(error is CancellationError) else { return }
                if let known = error as? ManagedPreservationError,
                   known == .authenticationRequired || known == .staleSession {
                    self.clearAccountPresentation()
                    return
                }
                self.membershipMessage = (error as? ManagedPreservationError)?.errorDescription
                    ?? ManagedPreservationError.unavailable.errorDescription
            }
        }
    }

    /// Usage must not hold the record list or old-photo access hostage to a
    /// delayed accounting response. It is never shown for a changed owner.
    private func loadUsage(_ ticket: UUID, owner: String) {
        usageTask?.cancel()
        usageRequestID = UUID()
        let requestID = usageRequestID
        usage = nil; usageMessage = nil; usageLoading = true
        usageTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.viewEpoch == ticket && self.authenticatedOwnerID == owner
                    && self.usageRequestID == requestID {
                    self.usageLoading = false; self.usageTask = nil
                }
            }
            do {
                let result = try await self.client.usage()
                try self.check(ticket)
                let currentOwner = try await self.client.sessionOwnerID()
                guard currentOwner == owner, self.authenticatedOwnerID == owner else {
                    throw ManagedPreservationError.staleSession
                }
                guard self.usageRequestID == requestID else { return }
                self.usage = result
            } catch {
                guard self.viewEpoch == ticket, self.authenticatedOwnerID == owner,
                      self.usageRequestID == requestID,
                      !(error is CancellationError) else { return }
                if let known = error as? ManagedPreservationError,
                   known == .authenticationRequired || known == .staleSession {
                    self.clearAccountPresentation()
                    return
                }
                self.usageMessage = (error as? ManagedPreservationError)?.errorDescription
                    ?? ManagedPreservationError.unavailable.errorDescription
            }
        }
    }

    func resumePendingMemo(_ memo: ManagedPreservationSessionStore.PendingMemo) {
        guard !isBusy, isSignedIn, memo.ownerId == authenticatedOwnerID else { return }
        retainUnsentEdit()
        run { ticket in
            guard try await self.requireCurrentOwner(ticket) == memo.ownerId else {
                throw ManagedPreservationError.staleSession
            }
            let current = try await self.client.detail(memo.recordId)
            guard try await self.requireCurrentOwner(ticket) == memo.ownerId else {
                throw ManagedPreservationError.staleSession
            }
            // Never silently rebase an old edit onto a newer/deleted record.
            guard current.record.revision == memo.baseRevision else { throw ManagedPreservationError.conflict }
            self.editingDraftID = memo.id
            self.selected = current; self.editedText = memo.text
            self.statusMessage = "同じ本人の未送信メモを戻しました。まだ送信していません。内容を確認して更新してください。"
        }
    }

    func retryPendingMemoStorage() {
        guard isSignedIn, !isBusy else { return }
        retainUnsentEdit()
        run { ticket in
            let owner = try await self.requireCurrentOwner(ticket)
            for memo in self.pendingMemoDrafts where memo.ownerId == owner {
                try self.draftStore.savePendingMemo(memo)
                self.unsecuredMemoIDs.remove(memo.id)
            }
            self.hasUnsecuredMemo = !self.unsecuredMemoIDs.isEmpty
            if !self.hasUnsecuredMemo {
                self.draftRecoveryWarning = nil
                self.statusMessage = "未送信メモをこの端末に残しました。サービスにはまだ送信していません。"
            }
        }
    }

    /// Explicitly discard only edits that failed durable local storage. No service record is touched.
    func discardUnsecuredMemos() {
        guard !isBusy else { return }
        if unsecuredMemoIDs.contains(editingDraftID) { editedText = selected?.document.text ?? "" }
        for id in unsecuredMemoIDs { volatileDrafts[id] = nil }
        pendingMemoDrafts.removeAll { unsecuredMemoIDs.contains($0.id) }
        unsecuredMemoIDs.removeAll()
        hasUnsecuredMemo = false; draftRecoveryWarning = nil
    }

    private func requireCurrentOwner(_ ticket: UUID) async throws -> String {
        guard let owner = try await client.sessionOwnerID() else { throw ManagedPreservationError.authenticationRequired }
        try check(ticket)
        guard owner == authenticatedOwnerID else { throw ManagedPreservationError.staleSession }
        return owner
    }

    /// Save while typing, so a locked/unavailable Keychain is visible before leaving.
    func retainUnsentEdit() {
        guard let owner = authenticatedOwnerID, let selected else { return }
        if editedText == selected.document.text {
            if volatileDrafts[editingDraftID] != nil || pendingMemoDrafts.contains(where: { $0.id == editingDraftID }) {
                removePendingMemo(editingDraftID, owner: owner)
            }
            return
        }
        let memo = ManagedPreservationSessionStore.PendingMemo(id: editingDraftID, ownerId: owner,
            recordId: selected.record.id, baseRevision: selected.record.revision, text: editedText)
        volatileDrafts[memo.id] = memo
        do {
            try draftStore.savePendingMemo(memo)
            unsecuredMemoIDs.remove(memo.id)
            if unsecuredMemoIDs.isEmpty { draftRecoveryWarning = nil }
        }
        catch {
            unsecuredMemoIDs.insert(memo.id)
            draftRecoveryWarning = "未送信メモは安全な端末保存に失敗し、この画面のメモリだけに残っています。アプリや画面を閉じると失われる可能性があります。同じ本人で確認し直し、文章を控えてください。"
        }
        if isSignedIn {
            pendingMemoDrafts.removeAll { $0.id == memo.id }
            pendingMemoDrafts.append(memo)
            hasUnsecuredMemo = !unsecuredMemoIDs.isEmpty
        }
    }

    private func removePendingMemo(_ id: UUID, owner: String) {
        do {
            try draftStore.removePendingMemo(id: id, ownerId: owner)
            volatileDrafts[id] = nil
            unsecuredMemoIDs.remove(id)
            pendingMemoDrafts.removeAll { $0.id == id && $0.ownerId == owner }
            hasUnsecuredMemo = !unsecuredMemoIDs.isEmpty
            if !hasUnsecuredMemo { draftRecoveryWarning = nil }
        } catch {
            draftRecoveryWarning = "更新前の下書きを端末から片付けられませんでした。保管先の最新内容と比較し、重ねて送信しないでください。"
        }
    }

    private func run(_ operation: @escaping @MainActor (UUID) async throws -> Void) {
        guard isEnabled, !isBusy else { return }
        let ticket = viewEpoch
        isBusy = true; errorMessage = nil; statusMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.viewEpoch == ticket { self.isBusy = false; self.task = nil } }
            do { try await operation(ticket) }
            catch {
                guard self.viewEpoch == ticket else { return }
                let known = error as? ManagedPreservationError
                if known == .authenticationRequired || known == .staleSession {
                    self.clearAccountPresentation()
                }
                self.errorMessage = error is CancellationError
                    ? ManagedPreservationError.interrupted.errorDescription
                    : (known?.errorDescription ?? ManagedPreservationError.unavailable.errorDescription)
            }
        }
    }

    private func check(_ ticket: UUID) throws {
        try Task.checkCancellation()
        guard ticket == viewEpoch else { throw ManagedPreservationError.staleSession }
    }

    private func cancelCurrentWork() {
        cancelExportReauthentication()
        viewEpoch = UUID(); task?.cancel(); task = nil; usageTask?.cancel(); usageTask = nil
        usageRequestID = UUID(); isBusy = false
        membershipTask?.cancel(); membershipTask = nil; membershipRequestID = UUID(); membershipLoading = false
        errorMessage = nil; statusMessage = nil
    }

    private func clearAccountPresentation() {
        retainUnsentEdit()
        saveFailureCode = nil; saveFailureMessage = nil
        usageTask?.cancel(); usageTask = nil; usageRequestID = UUID()
        membershipTask?.cancel(); membershipTask = nil; membershipRequestID = UUID(); membershipLoading = false
        isSignedIn = false; preparedSignIn = nil; selected = nil; editedText = ""
        records = []; nextCursor = nil; listingGeneration = nil; hasMore = false
        // Keep a possibly committed write bound to its owner until that owner can re-read it.
        if let owner = authenticatedOwnerID, copyState == .saving || copyState == .checking {
            setCopyState(.needsConfirmation, owner: owner)
        }
        consentToNewSave = false
        copyState = .deviceOnly
        membership = nil; membershipMessage = nil
        noticeContact = nil
        retention = nil
        usage = nil; usageLoading = false; usageMessage = nil
        authenticatedOwnerID = nil; pendingMemoDrafts = []
        hasUnsecuredMemo = !unsecuredMemoIDs.isEmpty
        if !hasUnsecuredMemo { draftRecoveryWarning = nil }
        exportProgress = nil
    }
}
