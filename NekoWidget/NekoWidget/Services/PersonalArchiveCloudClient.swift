import Foundation
@preconcurrency import CloudKit

enum PersonalArchiveCloudConfiguration {
    static var containerIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "PersonalArchiveContainerIdentifier") as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("$(") ? nil : trimmed
    }
    static func makeClient() -> (any PersonalArchiveTransport)? {
        guard let identifier = containerIdentifier else { return nil }
        if #available(iOS 15.0, macOS 12.0, *) {
            return PersonalArchiveCloudClient(containerIdentifier: identifier)
        }
        return nil
    }
}

/// Synchronous notification epoch invalidates in-flight work even for A -> B -> A.
private final class PersonalArchiveAccountEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var observer: NSObjectProtocol?
    init() {
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            self?.advance()
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func read() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); value &+= 1; lock.unlock() }
}

/// Explicit operations only. CloudKit private DB, no CKSyncEngine or background upload.
/// Sources: CKDatabase.modifyRecords(saving:deleting:savePolicy:atomically:),
/// recordZoneChanges(inZoneWith:since:desiredKeys:resultsLimit:) and CKAsset.
@available(iOS 15.0, macOS 12.0, *)
actor PersonalArchiveCloudClient: PersonalArchiveTransport {
    private static let recordType = "PersonalArchiveEntryV1"
    private static let markerType = "PersonalArchiveGenerationV1"
    private static let metadataKeys = ["schema", "payload"]
    private let container: CKContainer
    private let database: CKDatabase
    private let containerIdentifier: String
    private let epoch = PersonalArchiveAccountEpoch()
    private var activeAccount: PersonalArchiveAccount?
    private var ownerRecordName: String?

    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        let container = CKContainer(identifier: containerIdentifier)
        self.container = container; database = container.privateCloudDatabase
    }

    func account() async throws -> PersonalArchiveAccount {
        let started = epoch.read()
        do {
            guard try await container.accountStatus() == .available else {
                if activeAccount != nil { epoch.advance() }
                activeAccount = nil; ownerRecordName = nil
                throw PersonalArchiveError.notSignedIn
            }
            let user = try await container.userRecordID()
            guard epoch.read() == started else { throw PersonalArchiveError.accountChanged }
            let key = PersonalArchiveFiles.digest(Data((containerIdentifier + "\n" + user.recordName).utf8))
            if let activeAccount, activeAccount.key != key { epoch.advance() }
            let account = PersonalArchiveAccount(key: key, generation: epoch.read())
            activeAccount = account; ownerRecordName = user.recordName
            return account
        } catch { throw Self.safeError(error) }
    }

    func isCurrent(_ account: PersonalArchiveAccount) -> Bool {
        activeAccount == account && epoch.read() == account.generation
    }

    func prepareZone(for account: PersonalArchiveAccount, allowCreation: Bool, expectedGeneration: UUID?) async throws -> UUID {
        do {
            let zoneID = try boundZoneID(account)
            do { _ = try await database.recordZone(for: zoneID) }
            catch {
                try assertCurrent(account)
                guard let failure = error as? CKError, failure.code == .zoneNotFound, allowCreation, expectedGeneration == nil else { throw error }
                // Only explicit enrollment or its never-bound initialization retry may create a zone.
                // Use the verified owner, not a late-bound current-user alias.
                _ = try await database.save(CKRecordZone(zoneID: zoneID))
            }
            try assertCurrent(account)
            do {
                let marker = try await generationMarker(zoneID, expected: expectedGeneration)
                try assertCurrent(account)
                return try markerGeneration(marker, expected: expectedGeneration)
            } catch {
                // An initialization may stop between zone and marker creation. Only
                // a never-bound enrollment can continue; a known archive never repairs itself.
                guard error as? PersonalArchiveError == .archiveChanged,
                      allowCreation, expectedGeneration == nil else { throw error }
                try assertCurrent(account)
                let marker = CKRecord(recordType: Self.markerType, recordID: markerID(zoneID))
                marker["generation"] = UUID().uuidString as NSString
                marker["writeNonce"] = UUID().uuidString as NSString
                do {
                    let result = try await database.modifyRecords(saving: [marker], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                    guard let _ = try result.saveResults[marker.recordID]?.get() else { throw PersonalArchiveError.networkUnavailable }
                } catch {
                    // Concurrent first creators bind to the winning marker; no marker is ever overwritten.
                    guard Self.isServerConflict(error) else { throw error }
                }
            }
            try assertCurrent(account)
            let marker = try await generationMarker(zoneID, expected: expectedGeneration)
            try assertCurrent(account)
            return try markerGeneration(marker, expected: expectedGeneration)
        } catch { throw Self.safeError(error) }
    }

    func upload(_ payload: PersonalArchivePayload, jpegData: Data?, account: PersonalArchiveAccount, generation: UUID) async throws {
        try payload.validate()
        guard payload.jpegSHA256 == nil ? jpegData == nil : jpegData.map(payload.accepts) == true else {
            throw PersonalArchiveError.corruptedState
        }
        let zoneID = try boundZoneID(account)
        let recordID = CKRecord.ID(recordName: payload.id.uuidString, zoneID: zoneID)
        do {
            let marker = try await generationMarker(zoneID, expected: generation)
            try assertCurrent(account)
            if let existing = try await existingRecord(recordID) {
                try assertCurrent(account)
                try verifyExisting(existing, matches: payload)
                _ = try await generationMarker(zoneID, expected: generation)
                try assertCurrent(account)
                return
            }
            try assertCurrent(account)
            let record = CKRecord(recordType: Self.recordType, recordID: recordID)
            record["schema"] = NSNumber(value: 1)
            // Words, dates and image checksums share one encrypted field. No plaintext text-derived hash.
            record.encryptedValues["payload"] = try JSONEncoder().encode(payload) as NSData
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PersonalArchiveUpload-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            if let jpegData {
                let file = temporary.appendingPathComponent("photo.jpg")
                try PersonalArchiveFiles.write(jpegData, to: file, excludedFromBackup: true)
                record["jpeg"] = CKAsset(fileURL: file)
            }
            try assertCurrent(account)
            do {
                // The marker's changeTag is a transaction guard against a deleted/recreated zone.
                // A changed random field makes the guard an actual write, rather than an unchanged-record optimization.
                marker["writeNonce"] = UUID().uuidString as NSString
                let result = try await database.modifyRecords(saving: [marker, record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                try assertCurrent(account)
                guard let _ = try result.saveResults[marker.recordID]?.get() else { throw PersonalArchiveError.networkUnavailable }
                guard let saved = try result.saveResults[recordID]?.get() else { throw PersonalArchiveError.networkUnavailable }
                guard try decode(saved).fingerprint == payload.fingerprint else { throw PersonalArchiveError.conflict }
                _ = try await generationMarker(zoneID, expected: generation)
                try assertCurrent(account)
            } catch {
                try assertCurrent(account)
                // A retry may race with the previous request's successful commit. Never overwrite it.
                if Self.isServerConflict(error) {
                    _ = try await generationMarker(zoneID, expected: generation)
                    guard let existing = try await existingRecord(recordID) else { throw PersonalArchiveError.networkUnavailable }
                    try assertCurrent(account)
                    try verifyExisting(existing, matches: payload)
                } else { throw error }
            }
        } catch { throw Self.safeError(error) }
    }

    func fetch(account: PersonalArchiveAccount, expectedGeneration: UUID?) async throws -> PersonalArchiveRemoteSnapshot {
        do {
            let zoneID = try boundZoneID(account)
            let marker = try await generationMarker(zoneID, expected: expectedGeneration)
            let generation = try markerGeneration(marker, expected: expectedGeneration)
            try assertCurrent(account)
            var token: CKServerChangeToken?
            var metadata: [UUID: PersonalArchivePayload] = [:]
            var deleted = Set<UUID>()
            var more = true
            while more {
                // Fetch metadata separately: a missing asset must not withhold the person's words.
                let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token,
                    desiredKeys: Self.metadataKeys, resultsLimit: 100)
                try assertCurrent(account)
                for (_, result) in page.modificationResultsByID {
                    let record = try result.get().record
                    guard record.recordType == Self.recordType else { continue }
                    let payload = try decode(record)
                    metadata[payload.id] = payload; deleted.remove(payload.id)
                }
                for deletion in page.deletions where deletion.recordType == Self.recordType {
                    if let id = UUID(uuidString: deletion.recordID.recordName) { metadata[id] = nil; deleted.insert(id) }
                }
                token = page.changeToken; more = page.moreComing
            }
            var records: [PersonalArchiveRemoteRecord] = []
            for payload in metadata.values {
                try assertCurrent(account)
                var bytes: Data?
                if payload.jpegSHA256 != nil {
                    do {
                        let record = try await database.record(for: CKRecord.ID(recordName: payload.id.uuidString, zoneID: zoneID))
                        try assertCurrent(account)
                        guard try decode(record).fingerprint == payload.fingerprint else { throw PersonalArchiveError.conflict }
                        bytes = assetBytes(record, payload: payload)
                    } catch {
                        try assertCurrent(account)
                        let issue = Self.safeError(error)
                        if issue == .accountChanged || issue == .notSignedIn || issue == .cancelled || issue == .zoneMissing || issue == .archiveChanged || issue == .conflict { throw issue }
                        // No asset bytes is a partial record, not a successful photo restore.
                    }
                }
                records.append(PersonalArchiveRemoteRecord(payload: payload, jpegData: bytes))
            }
            _ = try await generationMarker(zoneID, expected: generation)
            try assertCurrent(account)
            return PersonalArchiveRemoteSnapshot(generation: generation, records: records, deletedIDs: deleted)
        } catch { throw Self.safeError(error) }
    }

    private func boundZoneID(_ account: PersonalArchiveAccount) throws -> CKRecordZone.ID {
        try assertCurrent(account)
        guard let ownerRecordName else { throw PersonalArchiveError.accountChanged }
        return CKRecordZone.ID(zoneName: "PersonalArchive-v1-" + account.key, ownerName: ownerRecordName)
    }
    private func assertCurrent(_ account: PersonalArchiveAccount) throws {
        guard isCurrent(account) else { throw PersonalArchiveError.accountChanged }
        if Task.isCancelled { throw PersonalArchiveError.cancelled }
    }
    private func existingRecord(_ id: CKRecord.ID) async throws -> CKRecord? {
        do { return try await database.record(for: id) }
        catch { if let failure = error as? CKError, failure.code == .unknownItem { return nil }; throw error }
    }
    private func markerID(_ zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "archive-generation", zoneID: zoneID)
    }
    private func generationMarker(_ zoneID: CKRecordZone.ID, expected: UUID?) async throws -> CKRecord {
        guard let marker = try await existingRecord(markerID(zoneID)) else { throw PersonalArchiveError.archiveChanged }
        _ = try markerGeneration(marker, expected: expected)
        return marker
    }
    private func markerGeneration(_ record: CKRecord, expected: UUID?) throws -> UUID {
        guard record.recordType == Self.markerType, let value = record["generation"] as? String,
              let generation = UUID(uuidString: value) else { throw PersonalArchiveError.corruptedState }
        guard expected == nil || generation == expected else { throw PersonalArchiveError.archiveChanged }
        return generation
    }
    private static func isServerConflict(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .serverRecordChanged { return true }
        let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error]
        return partial?.values.contains(where: isServerConflict) == true
    }
    private func verifyExisting(_ record: CKRecord, matches payload: PersonalArchivePayload) throws {
        guard try decode(record).fingerprint == payload.fingerprint else { throw PersonalArchiveError.conflict }
        if payload.jpegSHA256 != nil, assetBytes(record, payload: payload) == nil { throw PersonalArchiveError.corruptedState }
    }
    private func decode(_ record: CKRecord) throws -> PersonalArchivePayload {
        guard record.recordType == Self.recordType, let id = UUID(uuidString: record.recordID.recordName),
              (record["schema"] as? NSNumber)?.intValue == 1,
              let data = record.encryptedValues["payload"] as? Data, data.count <= 131_072,
              let payload = try? JSONDecoder().decode(PersonalArchivePayload.self, from: data), payload.id == id else {
            throw PersonalArchiveError.corruptedState
        }
        try payload.validate()
        return payload
    }
    private func assetBytes(_ record: CKRecord, payload: PersonalArchivePayload) -> Data? {
        guard let file = (record["jpeg"] as? CKAsset)?.fileURL,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == payload.jpegByteCount,
              let bytes = try? Data(contentsOf: file), payload.accepts(bytes) else { return nil }
        // Read while the CKRecord owns its temporary asset; the store writes a protected durable copy.
        return bytes
    }
    private static func safeError(_ error: Error) -> PersonalArchiveError {
        if let error = error as? PersonalArchiveError { return error }
        if error is CancellationError { return .cancelled }
        guard let error = error as? CKError else { return .networkUnavailable }
        if let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            let categories = partial.values.map(safeError)
            for priority in [PersonalArchiveError.notSignedIn, .quotaExceeded, .zoneMissing, .conflict, .corruptedState, .cancelled] {
                if categories.contains(priority) { return priority }
            }
        }
        switch error.code {
        case .badContainer, .badDatabase, .missingEntitlement: return .notConfigured
        case .notAuthenticated, .permissionFailure: return .notSignedIn
        case .quotaExceeded: return .quotaExceeded
        case .zoneNotFound, .userDeletedZone: return .zoneMissing
        case .serverRecordChanged: return .conflict
        case .operationCancelled: return .cancelled
        case .assetFileNotFound, .assetFileModified, .serverRejectedRequest, .invalidArguments: return .corruptedState
        default: return .networkUnavailable
        }
    }
}
