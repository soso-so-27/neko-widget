import Foundation

/// Private, device-local text. It is not a sharing caption or Widget payload.
struct PhotoMemoryNote: Codable, Equatable, Sendable {
    let text: String
    let updatedAt: Date
    let revision: String
}

enum PhotoMemoryNoteStoreError: Error, LocalizedError, Equatable {
    case invalidIdentifier
    case tooLong
    case invalidRevision
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
        var schemaVersion = 1
        var notes: [String: PhotoMemoryNote] = [:]
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
        return try load(from: resolvedFileURL()).notes[identifier]
    }

    func save(
        text: String,
        for identifier: String,
        expectedRevision: String?
    ) throws -> PhotoMemoryNote? {
        try Self.validate(identifier: identifier)
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= Self.maximumCharacters else {
            throw PhotoMemoryNoteStoreError.tooLong
        }
        if let expectedRevision, UUID(uuidString: expectedRevision) == nil {
            throw PhotoMemoryNoteStoreError.invalidRevision
        }

        Self.commitLock.lock()
        defer { Self.commitLock.unlock() }

        let url = try resolvedFileURL()
        var state = try load(from: url)
        let existing = state.notes[identifier]
        guard existing?.revision == expectedRevision else {
            throw PhotoMemoryNoteStoreError.conflict
        }
        // An unchanged draft need not invalidate another open editor.
        if existing?.text == normalized { return existing }
        if existing == nil, normalized.isEmpty { return nil }

        let note = normalized.isEmpty ? nil : PhotoMemoryNote(
            text: normalized,
            updatedAt: Date(),
            revision: UUID().uuidString
        )
        state.notes[identifier] = note
        try commit(state, to: url)
        // Do not expose a new revision until the atomic write succeeds.
        return note
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
        guard header.schemaVersion == 1 else {
            throw PhotoMemoryNoteStoreError.unsupportedSchema(header.schemaVersion)
        }
        do {
            let state = try decoder.decode(State.self, from: data)
            for (identifier, note) in state.notes {
                try Self.validate(identifier: identifier)
                guard !note.text.isEmpty,
                      note.text == note.text.trimmingCharacters(in: .whitespacesAndNewlines),
                      note.text.count <= Self.maximumCharacters,
                      UUID(uuidString: note.revision) != nil,
                      note.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
                    throw PhotoMemoryNoteStoreError.corruptedState
                }
            }
            return state
        } catch {
            throw PhotoMemoryNoteStoreError.corruptedState
        }
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
