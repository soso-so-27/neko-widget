import Darwin
import Foundation

enum AtomicJSON {
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try makeDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        // Encoder/decoder instances are intentionally not shared. LibraryStore
        // and WidgetCacheBuilder can run on different actors at the same time,
        // and Foundation does not document JSONEncoder as thread-safe.
        let data = try makeEncoder().encode(value)
        try data.write(to: url, options: .atomic)

        // Widget data must remain readable after the first device unlock.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}

enum SharingSecureFile {
    enum Error: Swift.Error {
        case cannotCreateTemporaryFile
        case atomicCommitFailed(Int32)
        case securityAttributesUnavailable
    }

    /// Sharing-scoped crash-safe writer. The empty temporary inode and its
    /// parent are protected/excluded before any private metadata or ciphertext
    /// is written. Callers serialize writes with their state/lease lock.
    static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try enforceProtectionAndBackupExclusion(directory)
        cleanupStaleTemporaryFiles(in: directory)

        let temporary = directory.appendingPathComponent(
            ".sharing-secure-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            let descriptor = Darwin.open(
                temporary.path,
                O_CREAT | O_EXCL | O_WRONLY,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else { throw Error.cannotCreateTemporaryFile }
            Darwin.close(descriptor)
            try enforceProtectionAndBackupExclusion(temporary)

            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            // Both paths are in the same directory. POSIX rename is the one
            // commit point: it atomically installs the already-validated inode
            // and replaces an existing regular file when present. Nothing may
            // throw after this succeeds, because callers are allowed to clean
            // up ciphertext after a failed state save.
            let renameResult = temporary.path.withCString { source in
                url.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard renameResult == 0 else {
                throw Error.atomicCommitFailed(Darwin.errno)
            }

            // The file contents were synchronized above. Persist the directory
            // entry where the platform supports it; failure after the commit is
            // deliberately non-fatal and must not make the result ambiguous.
            let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
            if directoryDescriptor >= 0 {
                _ = Darwin.fsync(directoryDescriptor)
                Darwin.close(directoryDescriptor)
            }
#if DEBUG
            if !hasRequiredProtectionAndBackupExclusion(url) {
                assertionFailure("Sharing secure file lost its prevalidated attributes")
            }
#endif
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    static func enforceProtectionAndBackupExclusion(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
        guard hasRequiredProtectionAndBackupExclusion(url) else {
            throw Error.securityAttributesUnavailable
        }
    }

    static func hasRequiredProtectionAndBackupExclusion(_ url: URL) -> Bool {
        guard let verified = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return false }
        return verified.isExcludedFromBackup == true
            && (attributes[.protectionKey] as? FileProtectionType)
                == .completeUntilFirstUserAuthentication
    }

    private static func cleanupStaleTemporaryFiles(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-60 * 60)
        guard let values = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        for value in values where value.lastPathComponent.hasPrefix(".sharing-secure-") {
            let attributes = try? value.resourceValues(forKeys: [.contentModificationDateKey])
            if let modifiedAt = attributes?.contentModificationDate,
               modifiedAt < cutoff {
                try? FileManager.default.removeItem(at: value)
            }
        }
    }
}

/// Stable cross-process gate for the complete sharing lifecycle. Its inode is
/// outside the purgeable `sharing/` subtree, so unlinking media/state can never
/// split the lock between an old writer and a new process.
enum SharingLifecycleGate {
    enum Error: Swift.Error { case unavailable }

    struct Token: Equatable, Sendable {
        fileprivate let epoch: Int
    }

    private struct LifecycleState: Codable {
        static let schemaVersion = 1
        var schemaVersion: Int = Self.schemaVersion
        var epoch: Int

        func validated() throws -> Self {
            guard schemaVersion == Self.schemaVersion, epoch > 0 else {
                throw Error.unavailable
            }
            return self
        }
    }

    final class Lease: @unchecked Sendable {
        private let descriptor: Int32
        private let stateLock = NSLock()
        private var released = false

        fileprivate init(descriptor: Int32) { self.descriptor = descriptor }

        func assertHeld() throws {
            stateLock.lock()
            let isReleased = released
            stateLock.unlock()
            guard !isReleased, Darwin.fcntl(descriptor, F_GETFD) != -1 else {
                throw Error.unavailable
            }
        }

        func release() {
            stateLock.lock()
            guard !released else {
                stateLock.unlock()
                return
            }
            released = true
            stateLock.unlock()
            _ = Darwin.flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }

        deinit { release() }
    }

    static func acquire(blocking: Bool) throws -> Lease? {
        guard let lockURL = SharedContainer.sharingLifecycleLockURL else {
            throw Error.unavailable
        }
        let directory = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SharingSecureFile.enforceProtectionAndBackupExclusion(directory)
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw Error.unavailable }
        let operation = blocking ? LOCK_EX : (LOCK_EX | LOCK_NB)
        guard Darwin.flock(descriptor, operation) == 0 else {
            let code = Darwin.errno
            Darwin.close(descriptor)
            if !blocking, code == EWOULDBLOCK { return nil }
            throw Error.unavailable
        }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: lockURL.path
        )
        return Lease(descriptor: descriptor)
    }

    static func withExclusive<Value>(_ operation: () throws -> Value) throws -> Value {
        guard let lease = try acquire(blocking: true) else { throw Error.unavailable }
        defer { lease.release() }
        return try operation()
    }

    static func issueToken() throws -> Token {
        try withExclusive {
            try issueTokenWhileLocked()
        }
    }

    static func issueTokenWhileLocked() throws -> Token {
        guard !isCleanupRequired else { throw Error.unavailable }
        return Token(epoch: try currentEpochWhileLocked())
    }

    static func withValidatedToken<Value>(
        _ token: Token,
        operation: () throws -> Value
    ) throws -> Value {
        try withExclusive {
            guard !isCleanupRequired,
                  try currentEpochWhileLocked() == token.epoch
            else { throw Error.unavailable }
            return try operation()
        }
    }

    /// Re-checks a token after an async boundary without performing a write.
    /// Pairing operations call this immediately after every network await so a
    /// response from an operation invalidated by unlink/reinstall is discarded
    /// before any key material or state derived from it is processed.
    static func validate(_ token: Token) throws {
        try withValidatedToken(token) { () }
    }

    /// Must be called while `withExclusive` is held. The first installation
    /// starts from a random positive epoch rather than a fixed value, so an
    /// orphaned in-memory operation can never become valid after control-state
    /// loss and recreation.
    static func currentEpochWhileLocked() throws -> Int {
        guard let url = SharedContainer.sharingLifecycleStateURL else {
            throw Error.unavailable
        }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                return try AtomicJSON.read(LifecycleState.self, from: url).validated().epoch
            } catch {
                throw Error.unavailable
            }
        }
        let state = LifecycleState(epoch: freshEpoch(excluding: nil))
        try writeLifecycleState(state, to: url)
        return state.epoch
    }

    /// Invalidates every previously issued logical sync lease. The caller
    /// writes the cleanup tombstone first and keeps the short lifecycle flock
    /// until the lease record, keys, state, and ciphertext are reset.
    @discardableResult
    static func bumpEpochWhileLocked() throws -> Int {
        guard let url = SharedContainer.sharingLifecycleStateURL else {
            throw Error.unavailable
        }
        let current = try? AtomicJSON.read(LifecycleState.self, from: url).validated().epoch
        let next: Int
        if let current, current < Int.max - 1 {
            next = current + 1
        } else {
            next = freshEpoch(excluding: current)
        }
        try writeLifecycleState(LifecycleState(epoch: next), to: url)
        return next
    }

    static func markCleanupRequired() throws {
        guard let url = SharedContainer.sharingCleanupRequiredURL else {
            throw Error.unavailable
        }
        try SharingSecureFile.write(Data("cleanup-required\n".utf8), to: url)
    }

    static func clearCleanupRequired() throws {
        guard let url = SharedContainer.sharingCleanupRequiredURL else {
            throw Error.unavailable
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Error.unavailable
        }
    }

    static var isCleanupRequired: Bool {
        guard let url = SharedContainer.sharingCleanupRequiredURL else { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func writeLifecycleState(_ state: LifecycleState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try SharingSecureFile.write(try encoder.encode(state), to: url)
    }

    private static func freshEpoch(excluding value: Int?) -> Int {
        var candidate: Int
        repeat {
            candidate = Int.random(in: 1...(Int.max / 2))
        } while candidate == value
        return candidate
    }
}
