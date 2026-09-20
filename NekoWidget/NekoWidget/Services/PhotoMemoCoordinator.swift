import Foundation

enum PhotoMemoReflectionState: String, Equatable, Sendable {
    case localOnly, stored, pending, conflict, accountChanged
}

struct PhotoMemoSaveResult: Sendable {
    let localRecord: PhotoMemoryNoteRecord?
    let archiveRecord: PersonalArchiveRecord?
    let reflection: PhotoMemoReflectionState
}

/// A per-photo, explicitly enrolled outbox, not a general background sync engine.
/// Local text is committed before any cloud await. Old copies are never enrolled
/// by opening them; legacy correspondence must still be confirmed by the user.
actor PhotoMemoCoordinator {
    private let noteStore: PhotoMemoryNoteStore
    private let archiveStore: PersonalArchiveStore

    init(noteStore: PhotoMemoryNoteStore = .shared, archiveStore: PersonalArchiveStore = .shared) {
        self.noteStore = noteStore; self.archiveStore = archiveStore
    }

    func linkedArchive(for record: PhotoMemoryNoteRecord, expectedAccount: String) async throws -> PersonalArchiveRecord? {
        try await archiveStore.linkedRecord(noteID: record.id, expectedAccount: expectedAccount)
    }

    /// A cloud entry can lead back to the same editor only through an explicit
    /// correspondence. An unrelated or divergent copy remains independent.
    func localRecord(forArchive record: PersonalArchiveRecord, expectedAccount: String) async throws -> PhotoMemoryNoteRecord? {
        let snapshot = try await archiveStore.readingSnapshot(expectedAccount: expectedAccount)
        guard let current = snapshot.records.first(where: { $0.id == record.id }),
              current.revision == record.revision, current.state != .conflict, !current.isDeletionPending else { return nil }
        let bindings = try await noteStore.archiveBindings()
        if let binding = bindings.first(where: { $0.recordID == record.id && $0.accountKey == snapshot.account.key }),
           let local = try await noteStore.record(id: binding.noteID) {
            let source = try await archiveStore.sourceSnapshot(recordID: record.id, expectedAccount: expectedAccount, matchingPayload: true)
            let ownInFlight = binding.inFlight != nil && source?.revision == binding.inFlight?.revision
            if current.revision == binding.archiveRevision || ownInFlight {
                _ = try await archiveStore.verifiedAccount(expectedAccount: expectedAccount)
                return local
            }
        }
        guard let source = snapshot.associations.first(where: { $0.recordID == record.id })?.source,
              let local = try await noteStore.record(id: source.noteID),
              Self.source(local) == source, local.note.text == record.text else { return nil }
        _ = try await archiveStore.verifiedAccount(expectedAccount: expectedAccount)
        return local
    }

    func syncStatus(photoIdentifier: String, expectedAccount: String? = nil) async throws -> PhotoMemoReflectionState {
        guard let binding = try await noteStore.archiveBinding(for: photoIdentifier) else { return .localOnly }
        let context: String
        do {
            if let expectedAccount { context = expectedAccount }
            else { context = try await archiveStore.accountContext() }
        }
        catch { return .accountChanged }
        do {
            let snapshot = try await archiveStore.readingSnapshot(expectedAccount: context)
            guard snapshot.account.key == binding.accountKey else { return .accountChanged }
            guard let record = try await archiveStore.memoRecord(id: binding.recordID, expectedAccount: context),
                  record.state != .conflict else { return .conflict }
            if binding.pending != nil || binding.inFlight != nil { return .pending }
            guard record.revision == binding.archiveRevision else { return .conflict }
            return record.state == .stored ? .stored : .pending
        } catch PersonalArchiveError.accountChanged { return .accountChanged }
        catch PersonalArchiveError.notSignedIn { return .accountChanged }
        catch { return .pending }
    }

    @discardableResult
    func enableUpdates(for record: PhotoMemoryNoteRecord, jpegData: Data?, expectedAccount: String,
                       recreateDeleted: Bool = false) async throws -> PhotoMemoSaveResult {
        let account = try await archiveStore.verifiedAccount(expectedAccount: expectedAccount)
        guard try await noteStore.record(id: record.id) == record else { throw PhotoMemoryNoteStoreError.conflict }
        let existingBinding = try await noteStore.archiveBinding(for: record.photoIdentifier)
        if let binding = existingBinding {
            guard binding.accountKey == account.key else { throw PersonalArchiveError.accountChanged }
        }
        let source = Self.source(record)
        let status = try await archiveStore.preservationStatus(source: source, jpegData: jpegData, expectedAccount: expectedAccount)
        if existingBinding != nil, !(status == .deleted && recreateDeleted) {
            return try await reflect(photoIdentifier: record.photoIdentifier, expectedAccount: expectedAccount)
        }
        guard status != .changed, status != .conflict, status != .deleted || recreateDeleted else {
            throw PersonalArchiveError.conflict
        }
        // Missing originals can enroll an exact existing copy without erasing its image.
        let old = try await archiveStore.linkedRecord(noteID: record.id, expectedAccount: expectedAccount)
        let archived: PersonalArchiveRecord
        if let old, status != .deleted {
            guard old.text == record.note.text else { throw PersonalArchiveError.conflict }
            archived = old
        } else {
            archived = try await archiveStore.preserve(source: source, jpegData: jpegData, text: record.note.text,
                capturedAt: record.note.context?.capturedAt,
                context: Self.context(record.note), expectedAccount: expectedAccount, recreateDeleted: recreateDeleted)
        }
        guard archived.state != .conflict, !archived.isDeletionPending else { throw PersonalArchiveError.conflict }
        _ = try await archiveStore.verifiedAccount(expectedAccount: expectedAccount)
        if archived.state == .stored || archived.state == .partial {
            try await archiveStore.acknowledgeMemoSource(source, recordID: archived.id,
                expectedRevision: archived.revision, expectedAccount: expectedAccount)
        }
        try await noteStore.bindArchive(record: record, recordID: archived.id, accountKey: account.key, archiveRevision: archived.revision,
            replacingDeletedRecordID: status == .deleted && recreateDeleted ? existingBinding?.recordID : nil)
        _ = try await archiveStore.verifiedAccount(expectedAccount: expectedAccount)
        return PhotoMemoSaveResult(localRecord: record, archiveRecord: archived,
                                   reflection: archived.state == .stored ? .stored : .pending)
    }

    @discardableResult
    func saveLocal(text: String, photoIdentifier: String, expectedRevision: String?,
                   context: PhotoMemoryNoteContext? = nil, expectedAccount: String? = nil) async throws -> PhotoMemoSaveResult {
        _ = try await noteStore.save(text: text, for: photoIdentifier, expectedRevision: expectedRevision, context: context)
        return try await reflect(photoIdentifier: photoIdentifier, expectedAccount: expectedAccount)
    }

    @discardableResult
    func saveLocal(text: String, recordID: UUID, expectedRevision: String,
                   expectedAccount: String? = nil) async throws -> PhotoMemoSaveResult {
        guard let old = try await noteStore.record(id: recordID) else { throw PhotoMemoryNoteStoreError.conflict }
        _ = try await noteStore.save(text: text, recordID: recordID, expectedRevision: expectedRevision)
        return try await reflect(photoIdentifier: old.photoIdentifier, expectedAccount: expectedAccount)
    }

    @discardableResult
    func saveArchive(record: PersonalArchiveRecord, text: String, operationID: UUID,
                     expectedAccount: String, expectedLocalRevision: String? = nil) async throws -> PhotoMemoSaveResult {
        // Only enrolled links write the local original. A legacy link needs the
        // explicit enableUpdates confirmation before becoming one logical memo.
        let account = try await archiveStore.verifiedAccount(expectedAccount: expectedAccount)
        let bindings = try await noteStore.archiveBindings()
        if bindings.contains(where: { $0.recordID == record.id && $0.accountKey == account.key }) {
            guard let local = try await localRecord(forArchive: record, expectedAccount: expectedAccount) else {
                throw PersonalArchiveError.conflict
            }
            guard let expectedLocalRevision, local.note.revision == expectedLocalRevision else { throw PhotoMemoryNoteStoreError.conflict }
            return try await saveLocal(text: text, recordID: local.id, expectedRevision: expectedLocalRevision,
                                       expectedAccount: expectedAccount)
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, record.jpegData == nil {
            // A missing local image must not be mistaken for a text-only record.
            let deleted = try await archiveStore.deleteWords(id: record.id, operationID: operationID,
                expectedRevision: record.revision, expectedAccount: expectedAccount)
            return PhotoMemoSaveResult(localRecord: nil, archiveRecord: deleted,
                reflection: deleted.state == .stored ? .stored : (deleted.state == .conflict ? .conflict : .pending))
        }
        let updated = try await archiveStore.update(id: record.id, operationID: operationID,
            expectedRevision: record.revision, text: text, capturedAt: record.capturedAt,
            context: record.context, expectedAccount: expectedAccount)
        return PhotoMemoSaveResult(localRecord: nil, archiveRecord: updated,
            reflection: updated.state == .stored ? .stored : (updated.state == .conflict ? .conflict : .pending))
    }

    func retryUpdates(expectedAccount: String) async throws {
        let account = try await archiveStore.verifiedAccount(expectedAccount: expectedAccount)
        for binding in try await noteStore.archiveBindings() where binding.accountKey == account.key {
            _ = try await reflect(photoIdentifier: binding.photoIdentifier, expectedAccount: expectedAccount)
        }
    }

    @discardableResult
    func resolveConflict(record: PersonalArchiveRecord, chooseRemote: Bool, operationID: UUID,
                         expectedAccount: String, expectedLocalNoteRevision: String? = nil) async throws -> PhotoMemoSaveResult {
        let account = try await archiveStore.verifiedAccount(expectedAccount: expectedAccount)
        guard record.state == .conflict, let remoteRevision = record.conflictingRevision,
              let remoteText = record.conflictingText, !record.isDeletionPending else { throw PersonalArchiveError.conflict }
        let bindings = try await noteStore.archiveBindings()
        if let binding = bindings.first(where: { $0.accountKey == account.key && $0.recordID == record.id }) {
            let local = try await noteStore.record(id: binding.noteID)
            guard local?.note.revision == expectedLocalNoteRevision else { throw PhotoMemoryNoteStoreError.conflict }
            // Local means the current frozen original, including a newer edit
            // queued behind the conflicting request, never an older draft.
            let text = chooseRemote ? remoteText : (local?.note.text ?? "")
            try await archiveStore.validateMemoConflict(id: record.id, localRevision: record.revision,
                remoteRevision: remoteRevision, text: text, expectedAccount: expectedAccount)
            try await noteStore.stageConflictResolution(binding: binding, expectedNoteRevision: expectedLocalNoteRevision,
                text: text, operationID: operationID, localRevision: record.revision, remoteRevision: remoteRevision)
            return try await reflect(photoIdentifier: binding.photoIdentifier, expectedAccount: expectedAccount)
        }
        let resolved = try await archiveStore.resolveMemoConflict(id: record.id, operationID: operationID,
            localRevision: record.revision, remoteRevision: remoteRevision, text: chooseRemote ? remoteText : record.text,
            expectedAccount: expectedAccount)
        return PhotoMemoSaveResult(localRecord: nil, archiveRecord: resolved,
            reflection: resolved.state == .stored ? .stored : (resolved.state == .conflict ? .conflict : .pending))
    }

    /// Safe reading coalescence while an explicitly enrolled local edit waits.
    /// Deleted local words suppress only their known older copy, not a divergent
    /// remote edit. The caller still renders all unmatched/independent records.
    func coalescedRecordIDs(localRecords: [PhotoMemoryNoteRecord], snapshot: PersonalArchiveReadingSnapshot) async throws -> [UUID: UUID] {
        _ = try await archiveStore.verifiedAccount(expectedAccount: snapshot.account.context)
        var result = snapshot.exactLinkedRecordIDs(matching: localRecords.map(Self.source))
        for binding in try await noteStore.archiveBindings() where binding.accountKey == snapshot.account.key {
            guard let archived = snapshot.records.first(where: { $0.id == binding.recordID }),
                  archived.state != .conflict, !archived.isDeletionPending else { continue }
            let source = try await archiveStore.sourceSnapshot(recordID: binding.recordID,
                expectedAccount: snapshot.account.context, matchingPayload: true)
            let ownInFlight = binding.inFlight != nil && source?.revision == binding.inFlight?.revision
            guard archived.revision == binding.archiveRevision || ownInFlight else { continue }
            let current = try await noteStore.record(id: binding.noteID)
            if let local = localRecords.first(where: { $0.id == binding.noteID }), current == local {
                result[binding.noteID] = binding.recordID
            } else if current == nil, (binding.pending ?? binding.inFlight)?.text == "" {
                result[binding.noteID] = binding.recordID
            }
        }
        _ = try await archiveStore.verifiedAccount(expectedAccount: snapshot.account.context)
        return result
    }

    /// Integrates only previously fetched copies and only explicitly enrolled
    /// links without a local outbox. No Photos lookup, fetch or upload occurs.
    func reconcile(expectedAccount: String) async throws {
        let snapshot = try await archiveStore.readingSnapshot(expectedAccount: expectedAccount)
        for binding in try await noteStore.archiveBindings() where binding.accountKey == snapshot.account.key {
            guard binding.pending == nil, binding.inFlight == nil,
                  let record = snapshot.records.first(where: { $0.id == binding.recordID }),
                  record.state == .stored || record.state == .partial, !record.isDeletionPending else { continue }
            _ = try await archiveStore.verifiedAccount(expectedAccount: expectedAccount)
            let local = try await noteStore.acceptArchiveText(binding: binding, text: record.text,
                writtenAt: record.context?.writtenAt, updatedAt: record.context?.updatedAt ?? record.createdAt,
                archiveRevision: record.revision)
            _ = try await archiveStore.verifiedAccount(expectedAccount: expectedAccount)
            if let local {
                try await archiveStore.acknowledgeMemoSource(Self.source(local), recordID: record.id,
                    expectedRevision: record.revision, expectedAccount: expectedAccount)
            }
        }
    }

    private func reflect(photoIdentifier: String, expectedAccount: String?) async throws -> PhotoMemoSaveResult {
        var archived: PersonalArchiveRecord?
        var verifiedContext: String?
        var outcome: PhotoMemoReflectionState = .localOnly
        if let binding = try await noteStore.archiveBinding(for: photoIdentifier) {
            outcome = .pending
            do {
                let context: String
                if let expectedAccount { context = expectedAccount }
                else { context = try await archiveStore.accountContext() }
                let account = try await archiveStore.verifiedAccount(expectedAccount: context)
                guard account.key == binding.accountKey else { throw PersonalArchiveError.accountChanged }
                verifiedContext = context
                // A maximum of two snapshots: the durable in-flight operation,
                // then the latest queued edit. Further concurrent edits stay queued.
                for _ in 0..<2 {
                    guard let current = try await noteStore.beginReflection(for: photoIdentifier, accountKey: account.key) else { break }
                    if let operation = current.inFlight {
                        // Complete an earlier creation/update before replacing it.
                        let retried = try await archiveStore.retryRecord(id: current.recordID, expectedAccount: context)
                        if retried?.state == .pending { break }
                        let source = PersonalArchiveSourceSnapshot(noteID: current.noteID, revision: operation.revision,
                                                                  photoIdentifier: photoIdentifier)
                        if let localRevision = operation.conflictLocalRevision, let remoteRevision = operation.conflictRemoteRevision {
                            archived = try await archiveStore.resolveMemoConflict(id: current.recordID,
                                operationID: operation.operationID, localRevision: localRevision, remoteRevision: remoteRevision,
                                text: operation.text, sourceSnapshot: source, expectedAccount: context)
                        } else if operation.text.isEmpty {
                            archived = try await archiveStore.deleteWords(id: current.recordID, operationID: operation.operationID,
                                expectedRevision: current.archiveRevision, expectedAccount: context, sourceSnapshot: source)
                        } else {
                            archived = try await archiveStore.update(id: current.recordID, operationID: operation.operationID,
                            expectedRevision: current.archiveRevision, text: operation.text,
                            capturedAt: operation.context?.capturedAt,
                            context: PersonalArchiveContext(writtenAt: operation.writtenAt, updatedAt: operation.updatedAt,
                                catNames: operation.context?.cats.map(\.name) ?? []), expectedAccount: context,
                            sourceSnapshot: source)
                        }
                        guard let archived, archived.state == .stored || archived.state == .partial else {
                            outcome = archived?.state == .conflict ? .conflict : .pending
                            break
                        }
                        _ = try await archiveStore.verifiedAccount(expectedAccount: context)
                        try await noteStore.finishReflection(for: photoIdentifier, accountKey: account.key,
                            operationID: operation.operationID, archiveRevision: archived.revision)
                    } else {
                        archived = try await archiveStore.retryRecord(id: current.recordID, expectedAccount: context)
                        break
                    }
                }
                outcome = try await syncStatus(photoIdentifier: photoIdentifier, expectedAccount: context)
                _ = try await archiveStore.verifiedAccount(expectedAccount: context)
            } catch PersonalArchiveError.accountChanged { outcome = .accountChanged; archived = nil }
            catch PersonalArchiveError.notSignedIn { outcome = .accountChanged; archived = nil }
            catch PersonalArchiveError.conflict { outcome = .conflict }
            catch { outcome = .pending }
        }
        let note = try await noteStore.note(for: photoIdentifier)
        if let verifiedContext {
            do { _ = try await archiveStore.verifiedAccount(expectedAccount: verifiedContext) }
            catch { outcome = .accountChanged; archived = nil }
        }
        return PhotoMemoSaveResult(localRecord: note.map { PhotoMemoryNoteRecord(photoIdentifier: photoIdentifier, note: $0) },
                                   archiveRecord: archived, reflection: outcome)
    }

    private static func source(_ record: PhotoMemoryNoteRecord) -> PersonalArchiveSourceSnapshot {
        PersonalArchiveSourceSnapshot(noteID: record.id, revision: record.note.revision, photoIdentifier: record.photoIdentifier)
    }
    private static func context(_ note: PhotoMemoryNote) -> PersonalArchiveContext {
        PersonalArchiveContext(writtenAt: note.writtenAt, updatedAt: note.updatedAt, catNames: note.context?.cats.map(\.name) ?? [])
    }
}
