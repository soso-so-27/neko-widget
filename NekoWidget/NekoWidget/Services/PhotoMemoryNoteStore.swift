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
            id: existing?.id ?? UUID(),
            text: text,
            updatedAt: now,
            revision: UUID().uuidString,
            writtenAt: existing == nil ? now : existing?.writtenAt,
            context: preservedContext
        )
        state.notes[identifier] = note
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
        guard header.schemaVersion == 1 || header.schemaVersion == 2 else {
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
