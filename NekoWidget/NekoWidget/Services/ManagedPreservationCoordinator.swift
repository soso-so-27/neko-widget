import Foundation
import AuthenticationServices
import Combine

/// The same export transaction is used by the screen and the runtime boundary check.
enum ManagedPreservationExport {
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
            updatedAt: document.updatedAt, catNames: document.catNames, jpegData: snapshot.jpegData)
    }
}

/// Owns only this screen's state. Does not enroll PhotoKit, local notes, CloudKit
/// or shared windows, and never treats a purchase/account ID as preservation identity.
@MainActor
final class ManagedPreservationCoordinator: ObservableObject {
    typealias ExportValidation = @MainActor () async throws -> Void
    typealias ExportHandler = @MainActor (ManagedPreservationExportSnapshot, @escaping ExportValidation) async throws -> Void

    let isEnabled: Bool
    let canExport: Bool
    @Published private(set) var isSignedIn = false
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var preparedSignIn: ManagedPreservationChallenge?
    @Published private(set) var records: [ManagedPreservationRecord] = []
    @Published private(set) var selected: ManagedPreservationExportSnapshot?
    @Published private(set) var hasMore = false
    @Published private(set) var draftWasSaved = false
    @Published private(set) var pendingMemoDrafts: [ManagedPreservationSessionStore.PendingMemo] = []
    @Published private(set) var draftRecoveryWarning: String?
    @Published var consentToNewSave = false
    @Published var editedText = ""

    let draft: ManagedPreservationDraft?
    private let client: ManagedPreservationClient
    private let onExport: ExportHandler?
    private let draftStore: ManagedPreservationSessionStore
    private var task: Task<Void, Never>?
    private var viewEpoch = UUID()
    private var nextCursor: String?
    private var listingGeneration: Int?
    private var authenticatedOwnerID: String?
    private var editingDraftID = UUID()
    // Fallback only when Keychain is locked/unavailable. Never published for another owner.
    private var volatileDrafts: [UUID: ManagedPreservationSessionStore.PendingMemo] = [:]

    init(configuration: ManagedPreservationConfiguration = .current,
         draft: ManagedPreservationDraft? = nil, onExport: ExportHandler? = nil) {
        isEnabled = configuration.isEnabled
        client = ManagedPreservationClient(configuration: configuration)
        draftStore = ManagedPreservationSessionStore(origin: configuration.origin?.absoluteString ?? "disabled")
        self.draft = draft; self.onExport = onExport; canExport = onExport != nil
    }

    func start() {
        guard isEnabled else { return }
        run { ticket in
            let authenticated = try await self.client.hasSession()
            try self.check(ticket)
            self.isSignedIn = authenticated
            if authenticated { try await self.loadFirstPage(ticket) }
        }
    }

    func prepareSignIn() {
        run { ticket in
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
                    throw ManagedPreservationError.authenticationFailed
                }
                try await self.client.finishSignIn(state: apple.state, identityToken: token, authorizationCode: code)
                try self.check(ticket)
                self.isSignedIn = true
                self.consentToNewSave = false
                try await self.loadFirstPage(ticket)
            case .failure(let error):
                await self.client.cancelSignIn()
                if (error as? ASAuthorizationError)?.code == .canceled { throw CancellationError() }
                throw ManagedPreservationError.authenticationFailed
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

    func refresh() {
        run { ticket in try await self.loadFirstPage(ticket) }
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
        selected = nil; editedText = ""
    }

    func saveSelectedCopy() {
        guard let draft, !draftWasSaved, consentToNewSave else { return }
        run { ticket in
            _ = try await self.client.put(draft, consent: true)
            try self.check(ticket)
            self.draftWasSaved = true
            self.statusMessage = "選んだ記録のコピーを保管しました。元の写真・メモは変更していません。"
            try await self.loadFirstPage(ticket)
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

    /// View disappearance cancels network work and drops this screen's sensitive copies.
    /// A dispatched write might still have reached the server; re-read on returning.
    func stop() {
        retainUnsentEdit()
        cancelCurrentWork()
        preparedSignIn = nil; selected = nil; editedText = ""; records = []
        nextCursor = nil; listingGeneration = nil; hasMore = false
        consentToNewSave = false
        authenticatedOwnerID = nil; pendingMemoDrafts = []
    }

    private func loadFirstPage(_ ticket: UUID) async throws {
        let page = try await client.list()
        try check(ticket)
        records = page.items; nextCursor = page.nextCursor
        listingGeneration = page.generation; hasMore = page.nextCursor != nil
        // Only expose drafts after the service accepted this session's list request.
        guard let owner = try await client.sessionOwnerID() else {
            throw ManagedPreservationError.authenticationRequired
        }
        try check(ticket)
        authenticatedOwnerID = owner
        var ownDrafts = Dictionary(uniqueKeysWithValues: try draftStore.pendingMemos(ownerId: owner).map { ($0.id, $0) })
        for value in volatileDrafts.values where value.ownerId == owner { ownDrafts[value.id] = value }
        pendingMemoDrafts = ownDrafts.values.sorted { $0.id.uuidString < $1.id.uuidString }
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

    private func requireCurrentOwner(_ ticket: UUID) async throws -> String {
        guard let owner = try await client.sessionOwnerID() else { throw ManagedPreservationError.authenticationRequired }
        try check(ticket)
        guard owner == authenticatedOwnerID else { throw ManagedPreservationError.staleSession }
        return owner
    }

    private func retainUnsentEdit() {
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
        do { try draftStore.savePendingMemo(memo) }
        catch {
            draftRecoveryWarning = "未送信メモは安全な端末保存に失敗し、この画面のメモリだけに残っています。アプリや画面を閉じると失われる可能性があります。同じ本人で確認し直し、文章を控えてください。"
        }
        if isSignedIn {
            pendingMemoDrafts.removeAll { $0.id == memo.id }
            pendingMemoDrafts.append(memo)
        }
    }

    private func removePendingMemo(_ id: UUID, owner: String) {
        do {
            try draftStore.removePendingMemo(id: id, ownerId: owner)
            volatileDrafts[id] = nil
            pendingMemoDrafts.removeAll { $0.id == id && $0.ownerId == owner }
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
        viewEpoch = UUID(); task?.cancel(); task = nil; isBusy = false
        errorMessage = nil; statusMessage = nil
    }

    private func clearAccountPresentation() {
        retainUnsentEdit()
        isSignedIn = false; preparedSignIn = nil; selected = nil; editedText = ""
        records = []; nextCursor = nil; listingGeneration = nil; hasMore = false
        consentToNewSave = false; draftWasSaved = false
        authenticatedOwnerID = nil; pendingMemoDrafts = []
    }
}
