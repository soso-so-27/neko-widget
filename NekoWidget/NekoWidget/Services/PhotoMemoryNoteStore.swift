import Foundation

struct PhotoMemoryNoteCat: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
}

/// A snapshot of a known capture date and the user's explicit cat assignments.
/// The store never derives identities or refreshes these names from Photos.
struct PhotoMemoryNoteContext: Codable, Equatable, Sendable {
    let capturedAt: Date?
    let cats: [PhotoMemoryNoteCat]
}

/// Private, device-local text. It is not a sharing caption or Widget payload.
struct PhotoMemoryNote: Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let updatedAt: Date
    let revision: String
    /// Nil for legacy notes: their original writing date was never stored.
    let writtenAt: Date?
    let context: PhotoMemoryNoteContext?

    init(
        id: UUID = UUID(),
        text: String,
        updatedAt: Date,
        revision: String,
        writtenAt: Date? = nil,
        context: PhotoMemoryNoteContext? = nil
    ) {
        self.id = id
        self.text = text
        self.updatedAt = updatedAt
        self.revision = revision
        self.writtenAt = writtenAt
        self.context = context
    }
}

struct PhotoMemoryNoteRecord: Identifiable, Equatable, Sendable {
    let photoIdentifier: String
    let note: PhotoMemoryNote
    var id: UUID { note.id }
}

/// Explicit consent and an outbox are device-local. Neither identifiers nor
/// consent are inferred from matching text or uploaded to CloudKit.
struct PhotoMemoryNoteReflection: Codable, Equatable, Sendable {
    let operationID: UUID
    let text: String
    let revision: String
    let writtenAt: Date?
    let updatedAt: Date
    let context: PhotoMemoryNoteContext?
    var conflictLocalRevision: String? = nil
    var conflictRemoteRevision: String? = nil
}

struct PhotoMemoryNoteArchiveBinding: Codable, Equatable, Sendable {
    let photoIdentifier: String
    let noteID: UUID
    let recordID: UUID
    let accountKey: String
    var archiveRevision: String
    var pending: PhotoMemoryNoteReflection? = nil
    var inFlight: PhotoMemoryNoteReflection? = nil
}

enum PhotoMemoryNoteStoreError: Error, LocalizedError, Equatable {
    case invalidIdentifier
    case tooLong
    case invalidRevision
    case invalidContext
    case conflict
    case unsupportedSchema(Int)
    case corruptedState
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            "この写真のメモを開けません。"
        case .tooLong:
            "メモは500文字以内で入力してください。"
        case .invalidRevision, .conflict:
            "メモが変更されています。入力内容を控えてから、メモを開き直してください。"
        case .invalidContext:
            "撮影日や猫の情報を保存できません。写真の情報を確認してください。"
        case .unsupportedSchema:
            "このメモは新しいバージョンのアプリで保存されています。"
        case .corruptedState:
            "保存されているメモを読み込めません。既存のメモは変更していません。"
        case .storageUnavailable:
            "メモを読み込み、または保存できませんでした。もう一度お試しください。"
        }
    }
}

/// App-only persistence, separate from scan snapshots and shared favorites.
/// User-authored memories are eligible for the user's OS-managed backup.
/// This is not app-level sync or a guarantee of restoring PhotoKit links on a
/// different device. No code exports this store to sharing or diagnostics.
actor PhotoMemoryNoteStore {
    static let shared = PhotoMemoryNoteStore()
    nonisolated static let maximumCharacters = 500

    private struct Header: Decodable {
        let schemaVersion: Int
    }

    private struct State: Codable {
        var schemaVersion = 2
        var notes: [String: PhotoMemoryNote] = [:]
        var archiveBindings: [String: PhotoMemoryNoteArchiveBinding]? = nil
    }

    private struct LegacyState: Decodable {
        var notes: [String: LegacyNote]
    }

    private struct LegacyNote: Decodable {
        var text: String
        var updatedAt: Date
        var revision: String
    }

    // There is one live shared actor. Also serialize injected instances in the
    // same app process so reopening a store cannot lose another photo's edit.
    private static let commitLock = NSLock()
    private let fileURLOverride: URL?

    init(fileURL: URL? = nil) {
        fileURLOverride = fileURL
    }

    func note(for identifier: String) throws -> PhotoMemoryNote? {
        try Self.validate(identifier: identifier)
        Self.commitLock.lock()
        defer { Self.commitLock.unlock() }
        return try load(from: resolvedFileURL()).notes[identifier]
    }

    /// These APIs need no photo access. A missing original never deletes text.
    func records() throws -> [PhotoMemoryNoteRecord] {
        Self.commitLock.lock()
        defer { Self.commitLock.unlock() }
        return try load(from: resolvedFileURL()).notes.map {
            PhotoMemoryNoteRecord(photoIdentifier: $0.key, note: $0.value)
        }.sorted {
            if $0.note.updatedAt != $1.note.updatedAt {
                return $0.note.updatedAt > $1.note.updatedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func record(id: UUID) throws -> PhotoMemoryNoteRecord? {
        Self.commitLock.lock()
        defer { Self.commitLock.unlock() }
        guard let entry = try load(from: resolvedFileURL()).notes.first(where: { $0.value.id == id }) else {
            return nil
        }
        return PhotoMemoryNoteRecord(photoIdentifier: entry.key, note: entry.value)
    }

    func save(
        text: String,
        for identifier: String,
        expectedRevision: String?,
        context: PhotoMemoryNoteContext? = nil
    ) throws -> PhotoMemoryNote? {
        try Self.validate(identifier: identifier)
        let normalized = try Self.normalizedText(text)
        try Self.validate(revision: expectedRevision)
        let context = try Self.normalizedContext(context)

        Self.commitLock.lock()
        defer { Self.commitLock.unlock() }

        let url = try resolvedFileURL()
        var state = try load(from: url)
        let existing = state.notes[identifier]
        guard existing?.revision == expectedRevision else {
            throw PhotoMemoryNoteStoreError.conflict
        }
        return try save(normalized: normalized, for: identifier, existing: existing,
                        context: context, state: &state, to: url)
    }

    func save(
        text: String,
        recordID: UUID,
        expectedRevision: String
    ) throws -> PhotoMemoryNoteRecord? {
        let normalized = try Self.normalizedText(text)
        try Self.validate(revision: expectedRevision)
        Self.commitLock.lock()
        defer { Self.commitLock.unlock() }
        let url = try resolvedFileURL()
        var state = try load(from: url)
        guard let entry = state.notes.first(where: { $0.value.id == recordID }),
              entry.value.revision == expectedRevision else {
            throw PhotoMemoryNoteStoreError.conflict
        }
        guard let note = try save(normalized: normalized, for: entry.key, existing: entry.value,
                                  context: nil, state: &state, to: url) else { return nil }
        return PhotoMemoryNoteRecord(photoIdentifier: entry.key, note: note)
    }

    func delete(id: UUID, expectedRevision: String) throws {
        _ = try save(text: "", recordID: id, expectedRevision: expectedRevision)
    }

    func archiveBinding(for identifier: String) throws -> PhotoMemoryNoteArchiveBinding? {
        Self.commitLock.lock(); defer { Self.commitLock.unlock() }
        return try load(from: resolvedFileURL()).archiveBindings?[identifier]
    }

    func archiveBindings() throws -> [PhotoMemoryNoteArchiveBinding] {
        Self.commitLock.lock(); defer { Self.commitLock.unlock() }
        return Array((try load(from: resolvedFileURL()).archiveBindings ?? [:]).values)
    }

    /// Consent is committed only against the exact note the user confirmed.
    func bindArchive(record: PhotoMemoryNoteRecord, recordID: UUID, accountKey: String,
                     archiveRevision: String, replacingDeletedRecordID: UUID? = nil) throws {
        Self.commitLock.lock(); defer { Self.commitLock.unlock() }
        let url = try resolvedFileURL()
        var state = try load(from: url)
        guard state.notes[record.photoIdentifier] == record.note,
              Self.validDigest(accountKey), Self.validDigest(archiveRevision) else {
            throw PhotoMemoryNoteStoreError.conflict
        }
        if let old = state.archiveBindings?[record.photoIdentifier],
           old.recordID != recordID || old.accountKey != accountKey {
            // Do not move an existing consent/outbox to another account.
            guard old.accountKey == accountKey, old.recordID == replacingDeletedRecordID else { throw PhotoMemoryNoteStoreError.conflict }
        }
        var bindings = state.archiveBindings ?? [:]
        if let old = bindings[record.photoIdentifier] {
            guard old.recordID == replacingDeletedRecordID || (old.pending == nil && old.inFlight == nil) else { throw PhotoMemoryNoteStoreError.conflict }
        }
        bindings[record.photoIdentifier] = PhotoMemoryNoteArchiveBinding(
            photoIdentifier: record.photoIdentifier, noteID: record.id, recordID: recordID,
            accountKey: accountKey, archiveRevision: archiveRevision)
        state.archiveBindings = bindings; state.schemaVersion = 3
        try commit(state, to: url)
    }

    /// Once promoted, the payload/operation ID stays fixed across interruption.
    /// Later edits replace only pending, never the request already in flight.
    func beginReflection(for identifier: String, accountKey: String) throws -> PhotoMemoryNoteArchiveBinding? {
        Self.commitLock.lock(); defer { Self.commitLock.unlock() }
        let url = try resolvedFileURL()
        var state = try load(from: url)
        guard var binding = state.archiveBindings?[identifier], binding.accountKey == accountKey else { return nil }
        if binding.inFlight == nil, let pending = binding.pending {
            binding.inFlight = pending; binding.pending = nil
            state.archiveBindings?[identifier] = binding
            try commit(state, to: url)
        }
        return binding
    }

    func finishReflection(for identifier: String, accountKey: String, operationID: UUID,
                          archiveRevision: String) throws {
        Self.commitLock.lock(); defer { Self.commitLock.unlock() }
        let url = try resolvedFileURL()
        var state = try load(from: url)
        guard var binding = state.archiveBindings?[identifier], binding.accountKey == accountKey,
              Self.validDigest(archiveRevision) else {
            throw PhotoMemoryNoteStoreError.conflict
        }
        if binding.inFlight == nil, binding.archiveRevision == archiveRevision { return }
        guard binding.inFlight?.operationID == operationID else { throw PhotoMemoryNoteStoreError.conflict }
        binding.archiveRevision = archiveRevision; binding.inFlight = nil
        state.archiveBindings?[identifier] = binding
        try commit(state, to: url)
    }

    /// Accept an already fetched version only while no local edit is queued.
    /// This never makes a new PhotoKit relationship or calls the network.
    func acceptArchiveText(binding expected: PhotoMemoryNoteArchiveBinding, text: String,
                           writtenAt: Date?, updatedAt: Date, archiveRevision: String) throws -> PhotoMemoryNoteRecord? {
        let text = try Self.normalizedText(text)
        Self.commitLock.lock(); defer { Self.commitLock.unlock() }
        let url = try resolvedFileURL()
        var state = try load(from: url)
        guard var binding = state.archiveBindings?[expected.photoIdentifier], binding == expected,
              binding.pending == nil, binding.inFlight == nil,
              Self.validDigest(archiveRevision), updatedAt.timeIntervalSinceReferenceDate.isFinite,
              writtenAt?.timeIntervalSinceReferenceDate.isFinite ?? true else { throw PhotoMemoryNoteStoreError.conflict }
        let old = state.notes[binding.photoIdentifier]
        if binding.archiveRevision == archiveRevision, (old?.text ?? "") == text {
            return old.map { PhotoMemoryNoteRecord(photoIdentifier: binding.photoIdentifier, note: $0) }
        }
        let note: PhotoMemoryNote?
        if text.isEmpty { note = nil }
        else if old?.text == text { note = old }
        else {
            note = PhotoMemoryNote(id: binding.noteID, text: text, updatedAt: updatedAt,
                revision: UUID().uuidString, writtenAt: old?.writtenAt ?? writtenAt, context: old?.context)
        }
        state.notes[binding.photoIdentifier] = note
        binding.archiveRevision = archiveRevision
        state.archiveBindings?[binding.photoIdentifier] = binding
        try commit(state, to: url)
        return note.map { PhotoMemoryNoteRecord(photoIdentifier: binding.photoIdentifier, note: $0) }
    }

    func stageConflictResolution(binding expected: PhotoMemoryNoteArchiveBinding, expectedNoteRevision: String?,
                                 text: String, operationID: UUID, localRevision: String, remoteRevision: String) throws {
        let text = try Self.normalizedText(text)
        Self.commitLock.lock(); defer { Self.commitLock.unlock() }
        let url = try resolvedFileURL()
        var state = try load(from: url)
        guard var binding = state.archiveBindings?[expected.photoIdentifier], binding == expected,
              state.notes[binding.photoIdentifier]?.revision == expectedNoteRevision,
              Self.validDigest(localRevision), Self.validDigest(remoteRevision) else { throw PhotoMemoryNoteStoreError.conflict }
        let old = state.notes[binding.photoIdentifier], now = Date(), revision = UUID().uuidString
        let note = text.isEmpty ? nil : PhotoMemoryNote(id: binding.noteID, text: text, updatedAt: now,
            revision: revision, writtenAt: old?.writtenAt, context: old?.context)
        state.notes[binding.photoIdentifier] = note
        binding.inFlight = PhotoMemoryNoteReflection(operationID: operationID, text: text, revision: revision,
            writtenAt: old?.writtenAt, updatedAt: now, context: old?.context,
            conflictLocalRevision: localRevision, conflictRemoteRevision: remoteRevision)
        binding.pending = nil
        state.archiveBindings?[binding.photoIdentifier] = binding
        try commit(state, to: url)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Called only inside the shared commit lock, after reading current state.
    private func save(
        normalized text: String,
        for identifier: String,
        existing: PhotoMemoryNote?,
        context: PhotoMemoryNoteContext?,
        state: inout State,
        to url: URL
    ) throws -> PhotoMemoryNote? {
        let preservedContext = existing?.context ?? context
        // Same text with newly available context is still a real mutation.
        if existing?.text == text, existing?.context == preservedContext { return existing }
        if existing == nil, text.isEmpty { return nil }

        let now = Date()
        let note = text.isEmpty ? nil : PhotoMemoryNote(
            id: existing?.id ?? state.archiveBindings?[identifier]?.noteID ?? UUID(),
            text: text,
            updatedAt: now,
            revision: UUID().uuidString,
            writtenAt: existing == nil ? now : existing?.writtenAt,
            context: preservedContext
        )
        state.notes[identifier] = note
        if var binding = state.archiveBindings?[identifier] {
            binding.pending = PhotoMemoryNoteReflection(operationID: UUID(), text: text,
                revision: note?.revision ?? UUID().uuidString,
                writtenAt: note?.writtenAt ?? existing?.writtenAt, updatedAt: now, context: preservedContext)
            state.archiveBindings?[identifier] = binding
        }
        try commit(state, to: url)
        // Do not expose a new revision until the atomic write succeeds.
        return note
    }

    private static func normalizedText(_ text: String) throws -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= maximumCharacters else {
            throw PhotoMemoryNoteStoreError.tooLong
        }
        return normalized
    }

    private static func validate(revision: String?) throws {
        if let revision, UUID(uuidString: revision) == nil {
            throw PhotoMemoryNoteStoreError.invalidRevision
        }
    }

    private static func normalizedContext(_ context: PhotoMemoryNoteContext?) throws -> PhotoMemoryNoteContext? {
        guard let context else { return nil }
        guard context.capturedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              Set(context.cats.map(\.id)).count == context.cats.count else {
            throw PhotoMemoryNoteStoreError.invalidContext
        }
        let cats = try context.cats.map { cat in
            let name = cat.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("\0") else {
                throw PhotoMemoryNoteStoreError.invalidContext
            }
            return PhotoMemoryNoteCat(id: cat.id, name: name)
        }
        if context.capturedAt == nil, cats.isEmpty { return nil }
        return PhotoMemoryNoteContext(capturedAt: context.capturedAt, cats: cats)
    }

    private static func validate(identifier: String) throws {
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              identifier.utf8.count <= 1_024,
              !identifier.contains("\0") else {
            throw PhotoMemoryNoteStoreError.invalidIdentifier
        }
    }

    private func resolvedFileURL() throws -> URL {
        if let fileURLOverride {
            guard fileURLOverride.isFileURL else {
                throw PhotoMemoryNoteStoreError.storageUnavailable
            }
            return fileURLOverride
        }
        do {
            return try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            .appendingPathComponent("PhotoMemoryNotes", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
        } catch {
            throw PhotoMemoryNoteStoreError.storageUnavailable
        }
    }

    private func load(from url: URL) throws -> State {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let failure = error as NSError
            // Only an explicit missing-file result can bootstrap empty state.
            // Permission, Data Protection and other read failures must not.
            if failure.domain == NSCocoaErrorDomain,
               failure.code == CocoaError.Code.fileReadNoSuchFile.rawValue
                || failure.code == CocoaError.Code.fileNoSuchFile.rawValue {
                return State()
            }
            throw PhotoMemoryNoteStoreError.storageUnavailable
        }

        let decoder = JSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw PhotoMemoryNoteStoreError.corruptedState
        }
        guard (1...3).contains(header.schemaVersion) else {
            throw PhotoMemoryNoteStoreError.unsupportedSchema(header.schemaVersion)
        }
        let state: State
        do {
            if header.schemaVersion == 1 {
                let legacy = try decoder.decode(LegacyState.self, from: data)
                // Keep revision and updatedAt exactly as stored. UUIDs become
                // observable only after the one atomic migration succeeds.
                state = State(notes: legacy.notes.mapValues {
                    PhotoMemoryNote(text: $0.text, updatedAt: $0.updatedAt, revision: $0.revision)
                })
            } else {
                state = try decoder.decode(State.self, from: data)
            }
            guard Set(state.notes.values.map(\.id)).count == state.notes.count else {
                throw PhotoMemoryNoteStoreError.corruptedState
            }
            for (identifier, note) in state.notes {
                try Self.validate(identifier: identifier)
                guard !note.text.isEmpty,
                      note.text == note.text.trimmingCharacters(in: .whitespacesAndNewlines),
                      note.text.count <= Self.maximumCharacters,
                      UUID(uuidString: note.revision) != nil,
                      note.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                      note.writtenAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
                      try Self.normalizedContext(note.context) == note.context else {
                    throw PhotoMemoryNoteStoreError.corruptedState
                }
            }
            guard state.archiveBindings == nil || state.schemaVersion == 3 else {
                throw PhotoMemoryNoteStoreError.corruptedState
            }
            let bindings = Array((state.archiveBindings ?? [:]).values)
            guard Set(bindings.map(\.noteID)).count == bindings.count,
                  Set(bindings.map { $0.accountKey + ":" + $0.recordID.uuidString }).count == bindings.count else {
                throw PhotoMemoryNoteStoreError.corruptedState
            }
            for (identifier, binding) in state.archiveBindings ?? [:] {
                try Self.validate(identifier: identifier)
                guard binding.photoIdentifier == identifier, Self.validDigest(binding.accountKey),
                      Self.validDigest(binding.archiveRevision),
                      state.notes[identifier].map({ $0.id == binding.noteID }) ?? true else {
                    throw PhotoMemoryNoteStoreError.corruptedState
                }
                for operation in [binding.pending, binding.inFlight].compactMap({ $0 }) {
                    guard try Self.normalizedText(operation.text) == operation.text,
                          UUID(uuidString: operation.revision) != nil,
                          operation.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                          operation.writtenAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
                          operation.conflictLocalRevision.map(Self.validDigest) ?? true,
                          operation.conflictRemoteRevision.map(Self.validDigest) ?? true,
                          (operation.conflictLocalRevision == nil) == (operation.conflictRemoteRevision == nil),
                          try Self.normalizedContext(operation.context) == operation.context else {
                        throw PhotoMemoryNoteStoreError.corruptedState
                    }
                }
            }
        } catch {
            throw PhotoMemoryNoteStoreError.corruptedState
        }
        // Every caller holds commitLock, including reads. Migration write
        // errors must remain storage errors and leave the v1 bytes untouched.
        if header.schemaVersion == 1 { try commit(state, to: url) }
        return state
    }

    private func commit(_ state: State, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            var directory = url.deletingLastPathComponent()
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
#if os(iOS)
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: directory.path
            )
#endif
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            try directory.setResourceValues(values)
            guard try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup == false else {
                throw PhotoMemoryNoteStoreError.storageUnavailable
            }
#if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtection]
#else
            let options: Data.WritingOptions = [.atomic]
#endif
            // Foundation writes an auxiliary file and replaces the original
            // only after a successful write. Protection applies during writing;
            // the parent has already been protected. User-authored text is
            // eligible for OS backup. No fallible mutation follows the commit.
            try data.write(to: url, options: options)
        } catch {
            throw PhotoMemoryNoteStoreError.storageUnavailable
        }
    }
}
