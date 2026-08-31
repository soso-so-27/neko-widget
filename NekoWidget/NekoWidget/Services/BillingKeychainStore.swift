import Foundation
import Security

/// Host-app-only persistence for the independent billing signing key. This
/// service is intentionally absent from the Widget and Share Extension.
enum BillingKeychainStore {
    private static let service = "jp.nekowidget.billing.credentials.v1.host"
    private static let account = "primary"
    private static let lock = NSLock()

    static func load() throws -> BillingCredential? {
        try withLock { try loadUnlocked() }
    }

    private static func loadUnlocked() throws -> BillingCredential? {
        var query = itemQuery()
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecNotAvailable:
            throw BillingClientError.protectedDataUnavailable
        default:
            throw BillingClientError.keychainUnavailable
        }
        guard let data = result as? Data else {
            throw BillingClientError.malformedCredential
        }
        do {
            return try JSONDecoder().decode(BillingCredential.self, from: data)
                .validated()
        } catch let error as BillingClientError {
            throw error
        } catch {
            // Readable but malformed data is never silently deleted or
            // replaced: doing so could orphan an already registered account.
            throw BillingClientError.malformedCredential
        }
    }

    /// Atomically inserts the first pending identity. On a duplicate, the
    /// existing validated winner is returned without overwriting it.
    static func insertPendingIfAbsent(
        _ candidate: BillingCredential
    ) throws -> BillingCredential {
        try withLock {
            let candidate = try candidate.validated()
            guard candidate.phase == .pendingBootstrap else {
                throw BillingClientError.malformedCredential
            }
            let attributes = try encodedAttributes(for: candidate)
            let addQuery = itemQuery().merging(attributes) { _, new in new }
            let status = SecItemAdd(
                addQuery as CFDictionary,
                nil
            )
            switch status {
            case errSecSuccess:
                return candidate
            case errSecDuplicateItem:
                guard let winner = try loadUnlocked() else {
                    throw BillingClientError.credentialChanged
                }
                return winner
            default:
                throw mappedWriteError(status)
            }
        }
    }

    /// Replaces one exact pending identity with its registered form. Existing
    /// malformed, unrelated, or recovery-rotated data is never overwritten.
    static func saveRegistered(
        _ registered: BillingCredential,
        replacing pending: BillingCredential
    ) throws {
        try withLock {
            let pending = try pending.validated()
            let registered = try registered.validated()
            guard pending.phase == .pendingBootstrap,
                  registered.phase == .registered,
                  pending.schemaVersion == registered.schemaVersion,
                  pending.installationMarker == registered.installationMarker,
                  pending.clientRequestID == registered.clientRequestID,
                  pending.signingPrivateKey == registered.signingPrivateKey
            else { throw BillingClientError.malformedCredential }

            let current = try loadUnlocked()
            if current == registered { return }
            guard current == pending else {
                throw BillingClientError.credentialChanged
            }
            let status = SecItemUpdate(
                itemQuery() as CFDictionary,
                try encodedAttributes(for: registered) as CFDictionary
            )
            guard status == errSecSuccess else {
                throw mappedWriteError(status)
            }
            guard try loadUnlocked() == registered else {
                throw BillingClientError.credentialChanged
            }
        }
    }

    private static func itemQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
    }

    private static func mappedWriteError(_ status: OSStatus) -> BillingClientError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable:
            return .protectedDataUnavailable
        default:
            return .keychainUnavailable
        }
    }

    private static func encodedAttributes(
        for credential: BillingCredential
    ) throws -> [CFString: Any] {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(try credential.validated())
        } catch let error as BillingClientError {
            throw error
        } catch {
            throw BillingClientError.malformedCredential
        }
        return [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
    }

    private static func withLock<Value>(
        _ operation: () throws -> Value
    ) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

/// A non-secret marker in the app's ordinary container prevents a Keychain
/// item that survived deletion/reinstallation from silently authorizing a new
/// installation. A matching StoreKit purchase may later enter an explicit
/// recovery flow; bootstrap never overwrites the old identity.
enum BillingInstallationMarkerStore {
    private static let directoryName = "jp.nekowidget.billing"
    private static let fileName = "billing-installation-marker.v1"
    private static let maximumBytes = 64

    static func loadOrCreate() throws -> UUID {
        let url = try markerURL()
        if let existing = try loadIfPresent(at: url) { return existing }

        let marker = UUID()
        let value = marker.uuidString.lowercased()
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(directoryValues)
        } catch {
            throw BillingClientError.localStateUnavailable
        }
        do {
            try Data(value.utf8).write(
                to: url,
                options: [
                    .withoutOverwriting,
                    .completeFileProtection
                ]
            )
        } catch {
            // A concurrent creator may have won after our initial read. Use
            // only its validated marker; never overwrite or regenerate it.
            if let winner = try loadIfPresent(at: url) { return winner }
            throw BillingClientError.localStateUnavailable
        }
        do {
            var fileValues = URLResourceValues()
            fileValues.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(fileValues)
        } catch {
            throw BillingClientError.localStateUnavailable
        }
        guard try loadIfPresent(at: url) == marker else {
            throw BillingClientError.localStateUnavailable
        }
        return marker
    }

    private static func loadIfPresent(at url: URL) throws -> UUID? {
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey
            ])
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  (1 ... maximumBytes).contains(fileSize)
            else { throw BillingClientError.localStateUnavailable }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= maximumBytes,
                  let value = String(data: data, encoding: .utf8),
                  let marker = BillingValidation.canonicalUUIDv4(value)
            else { throw BillingClientError.localStateUnavailable }
            return marker
        } catch let error as BillingClientError {
            throw error
        } catch {
            let cocoa = error as NSError
            guard cocoa.domain == NSCocoaErrorDomain,
                  cocoa.code == NSFileReadNoSuchFileError
            else { throw BillingClientError.localStateUnavailable }
            return nil
        }
    }

    private static func markerURL() throws -> URL {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { throw BillingClientError.localStateUnavailable }
        return root
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
