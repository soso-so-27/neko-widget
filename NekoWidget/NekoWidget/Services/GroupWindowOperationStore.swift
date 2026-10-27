import Foundation
import SQLite3

/// Durable retry bodies and compact completed receipts belong in the private
/// app container, not thousands of Keychain items. Only key material and trust
/// pins use Keychain. This database is new; no existing app record is migrated.
final class GroupOperationStore: GroupSecretStore, @unchecked Sendable {
    private let database: OpaquePointer
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL) throws {
        guard directory.isFileURL else { throw GroupClientError.invalidResponse }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
#endif
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var folder = directory; try folder.setResourceValues(excluded)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("operations.sqlite").path, &connection,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }; throw GroupClientError.unavailable
        }
        sqlite3_busy_timeout(connection, 2000)
        guard sqlite3_exec(connection, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS group_http_operations(account TEXT PRIMARY KEY, data BLOB NOT NULL) WITHOUT ROWID;", nil, nil, nil) == SQLITE_OK
        else { sqlite3_close(connection); throw GroupClientError.unavailable }
        database = connection
    }
    deinit { sqlite3_close(database) }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw GroupClientError.unavailable }
        return statement
    }
    private func bind(_ account: String, to statement: OpaquePointer) throws {
        guard account.hasPrefix("op:"), account.utf8.count <= 80,
              account.withCString({ sqlite3_bind_text(statement, 1, $0, -1, transient) }) == SQLITE_OK else { throw GroupClientError.invalidResponse }
    }
    func read(_ account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT data FROM group_http_operations WHERE account=?")
        defer { sqlite3_finalize(statement) }; try bind(account, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw GroupClientError.unavailable }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard (1...262_144).contains(count), let bytes = sqlite3_column_blob(statement, 0) else { throw GroupClientError.invalidResponse }
        return Data(bytes: bytes, count: count)
    }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        guard (1...262_144).contains(data.count) else { throw GroupClientError.invalidResponse }
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(createOnly ? "INSERT INTO group_http_operations VALUES (?,?)"
            : "INSERT INTO group_http_operations VALUES (?,?) ON CONFLICT(account) DO UPDATE SET data=excluded.data")
        defer { sqlite3_finalize(statement) }; try bind(account, to: statement)
        guard data.withUnsafeBytes({ sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }) == SQLITE_OK else { throw GroupClientError.unavailable }
        let result = sqlite3_step(statement)
        if result == SQLITE_CONSTRAINT { throw GroupClientError.idempotencyConflict }
        guard result == SQLITE_DONE else { throw GroupClientError.unavailable }
    }
    func remove(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("DELETE FROM group_http_operations WHERE account=?")
        defer { sqlite3_finalize(statement) }; try bind(account, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw GroupClientError.unavailable }
    }
}
