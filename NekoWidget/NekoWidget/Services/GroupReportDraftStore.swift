import Foundation
import SQLite3
import Darwin

struct GroupReportReceipt: Codable, Sendable {
    let id: String
    let windowID: String
    let momentID: String
    var state: String
    let moderationKeyID: String
    let ciphertextSize: Int
    let ciphertextSHA256: String
    let uploadExpiresAt: Int
    var committedAt: Int?
    var contentExpiresAt: Int?
    var receiptNumber: String? = nil
}

/// No plaintext photo, group key, arbitrary path, or network response text.
struct GroupReportDraft: Codable, Sendable {
    var schemaVersion = 1
    let endpoint: String
    let personID: String
    let deviceID: String
    let reporterParticipantID: String
    var record: GroupReportRecord
    let reserveBody: Data
    let commitBody: Data
    let evidenceSHA256: String
    let evidenceSize: Int
    var ciphertext: Data?
    var receipt: GroupReportReceipt?
    var revision = 0
}

/// A dedicated app-private database; the smaller GroupOperationStore is not
/// used for photo evidence. One row atomically commits bytes and resume state.
final class GroupReportDraftStore {
    private let database: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static let maximumRecordBytes = 1_500_000

    init(directory: URL) throws {
        guard directory.isFileURL else { throw GroupSafetyError.storageUnavailable }
        let manager = FileManager.default
        // Foundation standardization may turn /private/var back into /var on
        // Apple platforms. SQLITE_OPEN_NOFOLLOW rejects that parent symlink;
        // retain the physical parent path without standardizing it again.
        let parentPath = directory.deletingLastPathComponent().path
        try manager.createDirectory(atPath: parentPath, withIntermediateDirectories: true)
        guard let resolvedParent = realpath(parentPath, nil) else { throw GroupSafetyError.storageUnavailable }
        defer { free(resolvedParent) }
        let parent = URL(fileURLWithPath: String(cString: resolvedParent), isDirectory: true)
        let expected = parent.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        if let attributes = try? manager.attributesOfItem(atPath: expected.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw GroupSafetyError.storageUnavailable }
        try manager.createDirectory(at: expected, withIntermediateDirectories: true)
        guard let resolvedFolder = realpath(expected.path, nil) else { throw GroupSafetyError.storageUnavailable }
        defer { free(resolvedFolder) }
        guard String(cString: resolvedFolder) == expected.path else {
            throw GroupSafetyError.storageUnavailable
        }
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var folder = expected; try folder.setResourceValues(excluded)
#if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: folder.path)
#endif
        let file = folder.appendingPathComponent("reports.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            if let attributes = try? manager.attributesOfItem(atPath: file.path + suffix),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw GroupSafetyError.storageUnavailable
            }
        }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(file.path, &connection,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            throw GroupSafetyError.storageUnavailable
        }
        sqlite3_busy_timeout(connection, 2000)
        guard sqlite3_exec(connection, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS reports(id TEXT PRIMARY KEY, data BLOB NOT NULL CHECK(length(data)<=1500000)) WITHOUT ROWID;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(connection); throw GroupSafetyError.storageUnavailable
        }
        database = connection
    }
    deinit { sqlite3_close(database) }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &value, nil) == SQLITE_OK, let value else {
            throw GroupSafetyError.storageUnavailable
        }
        return value
    }
    func all() throws -> [GroupReportDraft] {
        let query = try statement("SELECT data FROM reports ORDER BY id LIMIT 257")
        defer { sqlite3_finalize(query) }
        var result: [GroupReportDraft] = []
        while true {
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW, result.count < 256 else { throw GroupSafetyError.storageUnavailable }
            let count = Int(sqlite3_column_bytes(query, 0))
            guard (1...Self.maximumRecordBytes).contains(count), let bytes = sqlite3_column_blob(query, 0) else {
                throw GroupSafetyError.storageUnavailable
            }
            let value = try PropertyListDecoder().decode(GroupReportDraft.self, from: Data(bytes: bytes, count: count))
            guard value.schemaVersion == 1, UUID(uuidString: value.record.id) != nil else { throw GroupSafetyError.storageUnavailable }
            result.append(value)
        }
    }
    func read(_ id: String) throws -> GroupReportDraft {
        guard UUID(uuidString: id) != nil, let value = try all().first(where: { $0.record.id == id }) else {
            throw GroupSafetyError.notFound
        }
        return value
    }
    func write(_ value: GroupReportDraft, createOnly: Bool = false) throws {
        guard UUID(uuidString: value.record.id) != nil else { throw GroupSafetyError.invalidResponse }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumRecordBytes else { throw GroupSafetyError.storageUnavailable }
        let query = try statement(createOnly
            ? "INSERT INTO reports SELECT ?,? WHERE (SELECT count(*) FROM reports)<256 AND (SELECT COALESCE(sum(length(data)),0) FROM reports)+length(?)<=33554432"
            : "UPDATE reports SET data=?2 WHERE id=?1 AND (SELECT COALESCE(sum(length(data)),0) FROM reports WHERE id<>?1)+length(?2)<=33554432")
        defer { sqlite3_finalize(query) }
        guard value.record.id.withCString({ sqlite3_bind_text(query, 1, $0, -1, transient) }) == SQLITE_OK,
              data.withUnsafeBytes({ sqlite3_bind_blob(query, 2, $0.baseAddress, Int32(data.count), transient) }) == SQLITE_OK else {
            throw GroupSafetyError.storageUnavailable
        }
        if createOnly {
            guard data.withUnsafeBytes({ sqlite3_bind_blob(query, 3, $0.baseAddress, Int32(data.count), transient) }) == SQLITE_OK else {
                throw GroupSafetyError.storageUnavailable
            }
        }
        guard sqlite3_step(query) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw GroupSafetyError.storageUnavailable }
    }
}
