import Darwin
import Foundation

enum CatHouseholdIdentityStoreError: LocalizedError {
    case unsupportedSchema(Int)
    case missingState
    case lockUnavailable(Int32)
    case cannotCreateTemporaryFile(Int32)
    case atomicCommitFailed(Int32)
    case securityAttributesUnavailable

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "猫プロフィールの保存形式（\(version)）をこのアプリでは読み込めません。"
        case .missingState:
            "猫プロフィールをまだ保存していません。"
        case .lockUnavailable, .cannotCreateTemporaryFile, .atomicCommitFailed,
             .securityAttributesUnavailable:
            "猫プロフィールを安全に保存できませんでした。"
        }
    }
}

/// App-only persistence for user-owned cat identity. It lives in the App Group
/// so a future Widget intent can read the same profiles, but no Widget or
/// sharing code writes it today.
actor CatHouseholdIdentityStore {
    static let filename = "cat-household-identity.json"

    private let stateURL: URL
    private let lockURL: URL

    init(
        stateURL: URL? = SharedContainer.containerURL?.appendingPathComponent(
            CatHouseholdIdentityStore.filename,
            isDirectory: false
        )
    ) throws {
        guard let stateURL else {
            throw NekoWidgetError.appGroupUnavailable(SharedContainer.appGroupIdentifier)
        }
        self.stateURL = stateURL
        self.lockURL = stateURL
            .deletingPathExtension()
            .appendingPathExtension("lock")
    }

    /// Returns nil before the first migration. Unsupported newer state is
    /// rejected rather than normalized down to a schema this build understands.
    func load() throws -> CatHouseholdIdentityState? {
        try withExclusiveLock {
            try loadUnlocked(repairingSecurityAttributes: true)
        }
    }

    /// Creates or reconciles the compatibility state without modifying the
    /// Build 13 settings or curation files. Repeating the same call is a true
    /// no-op: it does not rewrite the file or advance the revision.
    func loadOrMigrate(
        legacyLifeReference: CatLifeReference?,
        legacyCuration: CatCandidateCurationState,
        at date: Date = .now
    ) throws -> CatHouseholdIdentityState {
        try withExclusiveLock {
            guard let current = try loadUnlocked(repairingSecurityAttributes: true) else {
                let initial = CatHouseholdIdentityState.legacyUnscoped(
                    lifeReference: legacyLifeReference,
                    curation: legacyCuration,
                    at: date
                )
                try writeUnlocked(initial)
                return initial
            }

            let reconciled = current.reconcilingLegacyUnscoped(
                lifeReference: legacyLifeReference,
                curation: legacyCuration,
                at: date
            )
            guard reconciled != current else { return current }
            let committed = try CatHouseholdIdentityRevisionPolicy.committing(
                reconciled,
                replacing: current,
                expectedMutationRevision: current.mutationRevision,
                at: date
            )
            try writeUnlocked(committed)
            return committed
        }
    }

    /// Compare-and-swap commit. The caller mutates a loaded value without
    /// changing its revision, then supplies that revision here. The store reads
    /// disk again while holding the stable lock and rejects a stale caller.
    func save(
        _ proposed: CatHouseholdIdentityState,
        expectedMutationRevision: Int,
        at date: Date = .now
    ) throws -> CatHouseholdIdentityState {
        try withExclusiveLock {
            guard proposed.schemaVersion >= 1,
                  proposed.schemaVersion <= CatHouseholdIdentityState.currentSchemaVersion else {
                throw CatHouseholdIdentityStoreError.unsupportedSchema(
                    proposed.schemaVersion
                )
            }
            guard let current = try loadUnlocked(repairingSecurityAttributes: true) else {
                throw CatHouseholdIdentityStoreError.missingState
            }
            let committed = try CatHouseholdIdentityRevisionPolicy.committing(
                proposed,
                replacing: current,
                expectedMutationRevision: expectedMutationRevision,
                at: date
            )
            try writeUnlocked(committed)
            return committed
        }
    }

    nonisolated static func hasRequiredFileSecurity(at url: URL) -> Bool {
        CatHouseholdIdentityProtectedFile.hasRequiredSecurity(at: url)
    }

    private func loadUnlocked(
        repairingSecurityAttributes: Bool
    ) throws -> CatHouseholdIdentityState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        if repairingSecurityAttributes {
            try CatHouseholdIdentityProtectedFile.enforceSecurity(on: stateURL)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            CatHouseholdIdentityState.self,
            from: Data(contentsOf: stateURL)
        )
        guard decoded.schemaVersion >= 1,
              decoded.schemaVersion <= CatHouseholdIdentityState.currentSchemaVersion else {
            throw CatHouseholdIdentityStoreError.unsupportedSchema(decoded.schemaVersion)
        }
        let normalized = decoded.normalized()
        if normalized != decoded {
            // Normalization does not represent a user mutation, so it preserves
            // the store-owned revision while repairing deterministic ordering.
            try writeUnlocked(normalized)
        }
        return normalized
    }

    private func writeUnlocked(_ state: CatHouseholdIdentityState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try CatHouseholdIdentityProtectedFile.write(
            encoder.encode(state),
            to: stateURL
        )
    }

    private func withExclusiveLock<Value>(
        _ operation: () throws -> Value
    ) throws -> Value {
        let directory = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CatHouseholdIdentityStoreError.lockUnavailable(Darwin.errno)
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw CatHouseholdIdentityStoreError.lockUnavailable(Darwin.errno)
        }
        try CatHouseholdIdentityProtectedFile.enforceSecurity(on: lockURL)
        return try operation()
    }
}

/// Crash-safe writer for local identity metadata. Security attributes are
/// validated on the temporary inode before the one atomic rename commit point.
private enum CatHouseholdIdentityProtectedFile {
    private static let temporaryPrefix = ".cat-household-identity-secure-"

    static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupStaleTemporaryFiles(in: directory)

        let temporary = directory.appendingPathComponent(
            temporaryPrefix + UUID().uuidString,
            isDirectory: false
        )
        do {
            let descriptor = Darwin.open(
                temporary.path,
                O_CREAT | O_EXCL | O_WRONLY,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw CatHouseholdIdentityStoreError.cannotCreateTemporaryFile(
                    Darwin.errno
                )
            }
            Darwin.close(descriptor)
            try enforceSecurity(on: temporary)

            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            let renameResult = temporary.path.withCString { source in
                url.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard renameResult == 0 else {
                throw CatHouseholdIdentityStoreError.atomicCommitFailed(Darwin.errno)
            }

            // The inode was secured and synchronized before rename. Directory
            // fsync is best-effort after the commit and cannot make it ambiguous.
            let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
            if directoryDescriptor >= 0 {
                _ = Darwin.fsync(directoryDescriptor)
                Darwin.close(directoryDescriptor)
            }
#if DEBUG
            if !hasRequiredSecurity(at: url) {
                assertionFailure("Cat identity file lost its prevalidated attributes")
            }
#endif
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    static func enforceSecurity(on url: URL) throws {
#if os(iOS) || os(tvOS) || os(watchOS)
#if targetEnvironment(simulator)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#else
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#endif
#endif
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
        guard hasRequiredSecurity(at: url) else {
            throw CatHouseholdIdentityStoreError.securityAttributesUnavailable
        }
    }

    static func hasRequiredSecurity(at url: URL) -> Bool {
        guard let resourceValues = try? url.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ), resourceValues.isExcludedFromBackup == true else { return false }
#if os(iOS) || os(tvOS) || os(watchOS)
#if targetEnvironment(simulator)
        return true
#else
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ) else { return false }
        return (attributes[.protectionKey] as? FileProtectionType)
            == .completeUntilFirstUserAuthentication
#endif
#else
        return true
#endif
    }

    private static func cleanupStaleTemporaryFiles(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-60 * 60)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix(temporaryPrefix) {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modifiedAt = values?.contentModificationDate, modifiedAt < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
