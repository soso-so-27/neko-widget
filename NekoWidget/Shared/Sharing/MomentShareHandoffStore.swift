import CryptoKit
import Darwin
import Foundation

/// A host-issued, non-secret destination handle that the Share Extension may
/// read without opening Pairing state or Keychain credentials. The binding is
/// a one-way digest of the current installation and pairing identity; raw
/// Server identifiers never need to enter the extension UI.
struct MomentShareDestinationAdmission: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    let id: UUID
    let bindingSHA256: Data
    let displayName: String
    let issuedAt: Date
    let expiresAt: Date

    func validated() throws -> Self {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard schemaVersion == Self.schemaVersion,
              bindingSHA256.count == 32,
              displayName == trimmedName,
              (1...64).contains(displayName.utf8.count),
              !displayName.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              issuedAt > Date(timeIntervalSince1970: 0),
              expiresAt > issuedAt
        else { throw MomentSharingError.stateUnavailable }
        return self
    }

    func isActive(at now: Date) -> Bool {
        expiresAt > now
    }
}

struct MomentShareAdmissionCatalog: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    let destinations: [MomentShareDestinationAdmission]
    let updatedAt: Date

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              updatedAt > Date(timeIntervalSince1970: 0),
              destinations.count <= MomentShareHandoffStore.maximumAdmissionCount,
              Set(destinations.map(\.id)).count == destinations.count,
              Set(destinations.map(\.bindingSHA256)).count == destinations.count
        else { throw MomentSharingError.stateUnavailable }
        _ = try destinations.map { try $0.validated() }
        return self
    }
}

/// Host-only input for publishing the sanitized admission catalog. It is not
/// Codable so a raw construction request cannot accidentally become another
/// persisted authority beside `MomentShareAdmissionCatalog`.
struct MomentShareAdmissionInput: Equatable, Sendable {
    let bindingSHA256: Data
    let displayName: String

    init(bindingSHA256: Data, displayName: String) {
        self.bindingSHA256 = bindingSHA256
        self.displayName = displayName
    }
}

enum MomentPendingCapturePhase: String, Codable, Sendable {
    case pending
    case processing
}

/// One short-lived canonical preview awaiting host-app authorization. This is
/// local input, not an outbound payload: it has no space ID, participant ID,
/// credential, room key, or Server reservation.
struct MomentPendingCaptureRecord: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    /// Also becomes `MomentRequestContext.clientMomentID` after promotion.
    let id: UUID
    /// Stable across host crashes and promotion reconciliation.
    let clientRequestID: UUID
    let admissionID: UUID
    let kind: MomentKind
    let canonicalJPEG: Data
    let canonicalJPEGSize: Int
    let canonicalJPEGSHA256: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let capturedAt: Date?
    let captureDateIsMissing: Bool
    /// Version the host must apply before promotion. This is a requirement,
    /// never evidence that the Share Extension already analyzed the image.
    let requiredHostModerationVersion: Int
    /// Always true on disk. Only the host may satisfy this requirement, and it
    /// does so immediately before creating the room-encrypted outbox payload.
    let requiresHostModeration: Bool
    let senderPolicyVersion: Int
    let senderPolicyAcceptedAt: Date
    let createdAt: Date
    let expiresAt: Date
    var updatedAt: Date
    var phase: MomentPendingCapturePhase
    var claimID: UUID?
    var claimedAt: Date?
    var nextRetryAt: Date?
    var lastErrorCode: String?

    func validated() throws -> Self {
        let hasJPEGSignature = canonicalJPEG.count >= 4
            && canonicalJPEG.starts(with: [UInt8(0xff), 0xd8, 0xff])
            && canonicalJPEG.suffix(2).elementsEqual([UInt8(0xff), 0xd9])
        let hasClaim = claimID != nil && claimedAt != nil
        let safeError = lastErrorCode.map(Self.isSafeErrorCode) ?? true
        guard schemaVersion == Self.schemaVersion,
              kind == .live,
              canonicalJPEGSize == canonicalJPEG.count,
              (1...(MomentSharingProtocol.maximumMediaCiphertextBytes - 28))
                .contains(canonicalJPEGSize),
              hasJPEGSignature,
              canonicalJPEGSHA256.count == 32,
              canonicalJPEGSHA256 == Data(SHA256.hash(data: canonicalJPEG)),
              (1...MomentSharingProtocol.maximumCanonicalPixelDimension).contains(pixelWidth),
              (1...MomentSharingProtocol.maximumCanonicalPixelDimension).contains(pixelHeight),
              captureDateIsMissing == (capturedAt == nil),
              requiredHostModerationVersion == MomentSharingProtocol.moderationVersion,
              requiresHostModeration,
              senderPolicyVersion >= 1,
              senderPolicyAcceptedAt <= createdAt,
              createdAt > Date(timeIntervalSince1970: 0),
              expiresAt > createdAt,
              updatedAt >= createdAt,
              updatedAt < expiresAt,
              (phase == .processing) == hasClaim,
              phase != .pending || (claimID == nil && claimedAt == nil),
              claimedAt.map { $0 >= createdAt && $0 <= updatedAt } ?? true,
              nextRetryAt.map { $0 >= createdAt } ?? true,
              safeError
        else { throw MomentSharingError.stateUnavailable }
        return self
    }

    private static func isSafeErrorCode(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45 || $0 == 95
        }
    }
}

/// An in-process claim capability. Keeping this non-Codable prevents a second
/// persisted claim source and makes the on-disk record's claim ID the only CAS
/// authority after a crash.
struct MomentPendingCaptureClaim: Equatable, Sendable {
    let record: MomentPendingCaptureRecord
    let claimID: UUID
}

/// Plain handoff input is more sensitive than the ordinary sharing metadata or
/// already-encrypted outbox. Its inode and parent directory must use complete
/// Data Protection and backup exclusion before the first content byte exists.
private enum MomentShareHandoffProtectedFile {
    enum Error: Swift.Error {
        case cannotCreateTemporaryFile
        case atomicCommitFailed(Int32)
        case securityAttributesUnavailable
    }

    private static let temporaryPrefix = ".moment-handoff-secure-"

    static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try enforceProtectionAndBackupExclusion(directory)
        cleanupInterruptedWrites(in: directory)

        let temporary = directory.appendingPathComponent(
            "\(temporaryPrefix)\(UUID().uuidString)",
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

            // No content is written until both properties have been applied
            // and read back on a physical device.
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

            let renameResult = temporary.path.withCString { source in
                url.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard renameResult == 0 else {
                throw Error.atomicCommitFailed(Darwin.errno)
            }

            // The protected inode is already committed. Directory fsync is
            // best effort and must not turn that commit into an ambiguous
            // failure for a caller that may otherwise stage a second photo.
            let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
            if directoryDescriptor >= 0 {
                _ = Darwin.fsync(directoryDescriptor)
                Darwin.close(directoryDescriptor)
            }
#if DEBUG
            if !hasRequiredProtectionAndBackupExclusion(url) {
                assertionFailure("Moment handoff capture lost complete protection")
            }
#endif
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    static func hasRequiredProtectionAndBackupExclusion(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]),
              values.isExcludedFromBackup == true
        else { return false }
#if targetEnvironment(simulator)
        // Simulator does not model Data Protection consistently. Backup
        // exclusion remains testable; physical devices require exact `.complete`.
        return true
#else
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ) else { return false }
        return (attributes[.protectionKey] as? FileProtectionType) == .complete
#endif
    }

    private static func enforceProtectionAndBackupExclusion(_ url: URL) throws {
#if targetEnvironment(simulator)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
#else
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
#endif
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
        guard hasRequiredProtectionAndBackupExclusion(url) else {
            throw Error.securityAttributesUnavailable
        }
    }

    /// Every caller holds the stable lifecycle flock, so any prior temporary
    /// inode necessarily belongs to a crashed writer rather than live work.
    private static func cleanupInterruptedWrites(in directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        for url in urls where url.lastPathComponent.hasPrefix(temporaryPrefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

enum MomentShareHandoffStore {
    static let admissionLifetime: TimeInterval = 24 * 60 * 60
    static let captureLifetime: TimeInterval = 60 * 60
    static let claimRecoveryInterval: TimeInterval = 5 * 60
    static let maximumAdmissionCount = 8
    static let maximumPendingCaptureCount = 3
    static let maximumPendingCaptureBytes = 3 * 1_024 * 1_024

    private static let maximumAdmissionFileBytes = 64 * 1_024
    private static let maximumEncodedCaptureBytes =
        MomentSharingProtocol.maximumMediaCiphertextBytes + 96 * 1_024
    private static let captureFileSuffix = ".capture.v1.plist"

    /// Canonical, length-prefixed digest used only to recognize whether a
    /// previously issued admission still describes the current installation
    /// and pairing. It is not an authentication key.
    static func makeBindingSHA256(
        installationMarker: String,
        spaceID: String,
        participantID: String
    ) throws -> Data {
        guard let marker = UUID(uuidString: installationMarker),
              isOpaqueIdentifier(spaceID),
              isOpaqueIdentifier(participantID)
        else { throw MomentSharingError.invalidPayload }
        let fields = [
            "NW2.MOMENT-HANDOFF-ADMISSION",
            String(MomentSharingProtocol.version),
            marker.uuidString.lowercased(),
            spaceID,
            participantID
        ]
        var canonical = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var count = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { canonical.append(contentsOf: $0) }
            canonical.append(bytes)
        }
        return Data(SHA256.hash(data: canonical))
    }

    /// Replaces the host-authorized destination set. Matching bindings retain
    /// their admission IDs so a foreground renewal does not strand a capture;
    /// removed or changed bindings lose every capture before the lock opens.
    @discardableResult
    static func publishAdmissions(
        _ inputs: [MomentShareAdmissionInput],
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> MomentShareAdmissionCatalog {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard now > Date(timeIntervalSince1970: 0),
                  inputs.count <= maximumAdmissionCount
            else { throw MomentSharingError.invalidPayload }

            let validatedInputs = try inputs.map { input -> MomentShareAdmissionInput in
                let name = input.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard input.bindingSHA256.count == 32,
                      name == input.displayName,
                      (1...64).contains(name.utf8.count),
                      !name.unicodeScalars.contains(where: {
                          CharacterSet.controlCharacters.contains($0)
                      })
                else { throw MomentSharingError.invalidPayload }
                return input
            }
            guard Set(validatedInputs.map(\.bindingSHA256)).count == validatedInputs.count
            else { throw MomentSharingError.invalidPayload }

            if validatedInputs.isEmpty {
                try purgeAllWhileLocked()
                return try MomentShareAdmissionCatalog(
                    destinations: [],
                    updatedAt: now
                ).validated()
            }

            let existing: MomentShareAdmissionCatalog
            do {
                existing = try loadCatalogWhileLocked() ?? MomentShareAdmissionCatalog(
                    destinations: [],
                    updatedAt: now
                )
            } catch {
                // This cache contains no irreplaceable user state. A malformed
                // admission must never be treated as authority, and the host
                // can safely republish it from freshly bootstrapped Pairing.
                try purgeAllWhileLocked()
                existing = MomentShareAdmissionCatalog(destinations: [], updatedAt: now)
            }
            let existingByBinding = Dictionary(
                uniqueKeysWithValues: existing.destinations.map {
                    ($0.bindingSHA256, $0)
                }
            )
            let destinations = validatedInputs.map { input in
                let previous = existingByBinding[input.bindingSHA256]
                return MomentShareDestinationAdmission(
                    id: previous?.id ?? UUID(),
                    bindingSHA256: input.bindingSHA256,
                    displayName: input.displayName,
                    issuedAt: previous?.issuedAt ?? now,
                    expiresAt: now.addingTimeInterval(admissionLifetime)
                )
            }
            let catalog = try MomentShareAdmissionCatalog(
                destinations: destinations,
                updatedAt: now
            ).validated()
            try writeCatalogWhileLocked(catalog)

            let retainedIDs = Set(destinations.map(\.id))
            try removeCapturesWhileLocked { !retainedIDs.contains($0.admissionID) }
            return catalog
        }
    }

    static func revokeAdmissions(
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try purgeAllWhileLocked()
        }
    }

    /// Extension-safe read of the sanitized destination catalog. Missing or
    /// expired admission means the host app must be opened again.
    static func activeAdmissions(now: Date = .now) throws -> [MomentShareDestinationAdmission] {
        try SharingLifecycleGate.withExclusive {
            guard !SharingLifecycleGate.isCleanupRequired else {
                throw MomentSharingError.stateUnavailable
            }
            // Opening the Share sheet is itself a cleanup opportunity. Do
            // not require another stage attempt or a host-app launch before
            // expired canonical plaintext is physically removed.
            try pruneCapturesWhileLocked(now: now)
            guard let catalog = try loadCatalogWhileLocked() else { return [] }
            return catalog.destinations
                .filter { $0.isActive(at: now) }
                .sorted { lhs, rhs in
                    if lhs.displayName == rhs.displayName {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.displayName.localizedStandardCompare(rhs.displayName)
                        == .orderedAscending
                }
        }
    }

    /// Atomically stages one already-canonicalized preview. The extension does
    /// not perform or claim moderation; the host must analyze these exact
    /// bytes before room encryption. Admission is re-read inside the lifecycle
    /// lock so an async image task cannot publish after unlink, reinstall
    /// cleanup, or destination change.
    @discardableResult
    static func stageCapture(
        admissionID: UUID,
        canonicalJPEG: Data,
        capturedAt: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        requiredHostModerationVersion: Int = MomentSharingProtocol.moderationVersion,
        senderPolicyVersion: Int,
        senderPolicyAcceptedAt: Date,
        now: Date = .now
    ) throws -> MomentPendingCaptureRecord {
        let id = UUID()
        let record = try MomentPendingCaptureRecord(
            id: id,
            clientRequestID: UUID(),
            admissionID: admissionID,
            kind: .live,
            canonicalJPEG: canonicalJPEG,
            canonicalJPEGSize: canonicalJPEG.count,
            canonicalJPEGSHA256: Data(SHA256.hash(data: canonicalJPEG)),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            capturedAt: capturedAt,
            captureDateIsMissing: capturedAt == nil,
            requiredHostModerationVersion: requiredHostModerationVersion,
            requiresHostModeration: true,
            senderPolicyVersion: senderPolicyVersion,
            senderPolicyAcceptedAt: senderPolicyAcceptedAt,
            createdAt: now,
            expiresAt: now.addingTimeInterval(captureLifetime),
            updatedAt: now,
            phase: .pending,
            claimID: nil,
            claimedAt: nil,
            nextRetryAt: nil,
            lastErrorCode: nil
        ).validated()
        let encoded = try encode(record)
        guard encoded.count <= maximumEncodedCaptureBytes else {
            throw MomentSharingError.payloadTooLarge
        }

        try SharingLifecycleGate.withExclusive {
            guard !SharingLifecycleGate.isCleanupRequired else {
                throw MomentSharingError.stateUnavailable
            }
            try pruneCapturesWhileLocked(now: now)
            guard let catalog = try loadCatalogWhileLocked(),
                  catalog.destinations.contains(where: {
                      $0.id == admissionID && $0.isActive(at: now)
                  })
            else { throw MomentSharingError.notPaired }

            let current = try loadCaptureRecordsWhileLocked()
            let currentBytes = current.reduce(0) { $0 + $1.canonicalJPEGSize }
            guard current.count < maximumPendingCaptureCount,
                  currentBytes <= maximumPendingCaptureBytes - record.canonicalJPEGSize
            else { throw MomentSharingError.outboxFull }
            let url = try captureURL(for: record.id)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw MomentSharingError.stateUnavailable
            }
            try MomentShareHandoffProtectedFile.write(encoded, to: url)
        }
        return record
    }

    /// Returns the oldest retry-eligible record for one currently authorized
    /// destination. The record is only a snapshot; `claimCapture` performs the
    /// exact CAS after any asynchronous host moderation.
    static func nextPendingCapture(
        admissionID: UUID,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> MomentPendingCaptureRecord? {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try pruneCapturesWhileLocked(now: now)
            guard try hasActiveAdmissionWhileLocked(id: admissionID, now: now) else {
                return nil
            }
            return try loadCaptureRecordsWhileLocked()
                .filter {
                    $0.admissionID == admissionID
                        && $0.phase == .pending
                        && ($0.nextRetryAt == nil || $0.nextRetryAt! <= now)
                }
                .sorted(by: captureOrder)
                .first
        }
    }

    /// Full-record CAS. A second host coordinator that moderated the same
    /// snapshot receives nil and must move on instead of duplicating work.
    static func claimCapture(
        _ expected: MomentPendingCaptureRecord,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> MomentPendingCaptureClaim? {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try pruneCapturesWhileLocked(now: now)
            guard try hasActiveAdmissionWhileLocked(id: expected.admissionID, now: now),
                  var current = try loadCaptureWhileLocked(id: expected.id),
                  current == expected,
                  current.phase == .pending,
                  current.expiresAt > now,
                  current.nextRetryAt == nil || current.nextRetryAt! <= now
            else { return nil }

            let claimID = UUID()
            let mutationDate = max(now, current.updatedAt)
            current.phase = .processing
            current.claimID = claimID
            current.claimedAt = mutationDate
            current.updatedAt = mutationDate
            current.nextRetryAt = nil
            current.lastErrorCode = nil
            current = try current.validated()
            try writeCaptureWhileLocked(current)
            return MomentPendingCaptureClaim(record: current, claimID: claimID)
        }
    }

    /// Re-reads the claimed record under the current installation token before
    /// exposing local plaintext to the host moderation temporary file.
    static func readCanonicalJPEG(
        _ claim: MomentPendingCaptureClaim,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> Data {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            let current = try requireCurrentClaimWhileLocked(claim, now: now)
            return current.canonicalJPEG
        }
    }

    static func releaseCapture(
        _ claim: MomentPendingCaptureClaim,
        retryAt: Date?,
        errorCode: String?,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            var current = try requireCurrentClaimWhileLocked(
                claim,
                now: now,
                requiresActiveAdmission: false,
                requiresUnexpiredCapture: false
            )
            if current.expiresAt <= now || retryAt.map({ $0 >= current.expiresAt }) == true {
                try removeCaptureWhileLocked(id: current.id)
                return
            }
            let safeError = errorCode.map { String($0.prefix(64)) }
            let mutationDate = max(now, current.updatedAt)
            current.phase = .pending
            current.claimID = nil
            current.claimedAt = nil
            current.nextRetryAt = retryAt
            current.lastErrorCode = safeError
            current.updatedAt = mutationDate
            current = try current.validated()
            try writeCaptureWhileLocked(current)
        }
    }

    /// The operation must be synchronous and idempotent. The caller uses a
    /// MomentSharingStateStore while-locked enqueue/reconcile primitive here;
    /// calling an API that reacquires SharingLifecycleGate would deadlock.
    /// Capture deletion happens only after the durable promotion returns.
    static func promoteCapture<Result>(
        _ claim: MomentPendingCaptureClaim,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now,
        operation: (MomentPendingCaptureRecord) throws -> Result
    ) throws -> Result {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            let current = try requireCurrentClaimWhileLocked(claim, now: now)
            let result = try operation(current)
            try removeCaptureWhileLocked(id: current.id)
            return result
        }
    }

    static func completeCapture(
        _ claim: MomentPendingCaptureClaim,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            _ = try requireCurrentClaimWhileLocked(
                claim,
                now: now,
                requiresActiveAdmission: false,
                requiresUnexpiredCapture: false
            )
            try removeCaptureWhileLocked(id: claim.record.id)
        }
    }

    static func discardCapture(
        _ claim: MomentPendingCaptureClaim,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws {
        try completeCapture(claim, validating: lifecycleToken, now: now)
    }

    static func prune(
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try pruneCapturesWhileLocked(now: now)
        }
    }

    /// Runtime/self-test hook that exposes only the protection result, never a
    /// path or capture contents.
    static func captureHasRequiredProtection(_ record: MomentPendingCaptureRecord) -> Bool {
        guard let url = try? captureURL(for: record.id) else { return false }
        return MomentShareHandoffProtectedFile
            .hasRequiredProtectionAndBackupExclusion(url)
    }

    /// Runtime/self-test hook for physical retention checks. Protection and
    /// existence are deliberately separate assertions.
    static func captureExists(_ record: MomentPendingCaptureRecord) -> Bool {
        guard let url = try? captureURL(for: record.id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Locked storage

    private static func loadCatalogWhileLocked() throws -> MomentShareAdmissionCatalog? {
        guard let url = SharedContainer.momentShareHandoffAdmissionsURL else {
            throw MomentSharingError.stateUnavailable
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try boundedData(from: url, maximumBytes: maximumAdmissionFileBytes)
        do {
            return try decode(MomentShareAdmissionCatalog.self, from: data).validated()
        } catch let error as MomentSharingError {
            throw error
        } catch {
            throw MomentSharingError.stateUnavailable
        }
    }

    private static func writeCatalogWhileLocked(
        _ catalog: MomentShareAdmissionCatalog
    ) throws {
        guard let url = SharedContainer.momentShareHandoffAdmissionsURL else {
            throw MomentSharingError.stateUnavailable
        }
        let encoded = try encode(try catalog.validated())
        guard encoded.count <= maximumAdmissionFileBytes else {
            throw MomentSharingError.stateUnavailable
        }
        try SharingSecureFile.write(encoded, to: url)
    }

    private static func loadCaptureRecordsWhileLocked() throws -> [MomentPendingCaptureRecord] {
        guard let directory = SharedContainer.momentShareHandoffCapturesDirectoryURL else {
            throw MomentSharingError.stateUnavailable
        }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )
        var records: [MomentPendingCaptureRecord] = []
        for url in urls {
            guard url.lastPathComponent.hasSuffix(captureFileSuffix) else {
                // This directory is exclusively owned by the handoff store.
                // Unknown visible entries cannot be treated as input or kept
                // outside the retention/cap accounting.
                try FileManager.default.removeItem(at: url)
                continue
            }
            do {
                let record = try loadCaptureFileWhileLocked(url)
                records.append(record)
            } catch {
                // Pending captures are short-lived derived input. Corrupt or
                // foreign-schema files are never promoted and may be removed.
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    throw MomentSharingError.stateUnavailable
                }
            }
        }
        return records
    }

    private static func loadCaptureWhileLocked(id: UUID) throws -> MomentPendingCaptureRecord? {
        let url = try captureURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try loadCaptureFileWhileLocked(url)
    }

    private static func loadCaptureFileWhileLocked(
        _ url: URL
    ) throws -> MomentPendingCaptureRecord {
        let name = url.lastPathComponent
        guard name.hasSuffix(captureFileSuffix),
              let fileID = UUID(
                  uuidString: String(name.dropLast(captureFileSuffix.count))
              ),
              MomentShareHandoffProtectedFile
                .hasRequiredProtectionAndBackupExclusion(url)
        else { throw MomentSharingError.stateUnavailable }
        let data = try boundedData(from: url, maximumBytes: maximumEncodedCaptureBytes)
        do {
            let record = try decode(MomentPendingCaptureRecord.self, from: data).validated()
            guard record.id == fileID else { throw MomentSharingError.stateUnavailable }
            return record
        } catch let error as MomentSharingError {
            throw error
        } catch {
            throw MomentSharingError.stateUnavailable
        }
    }

    private static func writeCaptureWhileLocked(_ record: MomentPendingCaptureRecord) throws {
        let record = try record.validated()
        let data = try encode(record)
        guard data.count <= maximumEncodedCaptureBytes else {
            throw MomentSharingError.stateUnavailable
        }
        try MomentShareHandoffProtectedFile.write(
            data,
            to: try captureURL(for: record.id)
        )
    }

    private static func pruneCapturesWhileLocked(now: Date) throws {
        for var record in try loadCaptureRecordsWhileLocked() {
            if record.expiresAt <= now {
                try removeCaptureWhileLocked(id: record.id)
                continue
            }
            if record.phase == .processing,
               let claimedAt = record.claimedAt,
               claimedAt.addingTimeInterval(claimRecoveryInterval) <= now {
                record.phase = .pending
                record.claimID = nil
                record.claimedAt = nil
                record.updatedAt = max(now, record.updatedAt)
                record.lastErrorCode = "claim-recovered"
                try writeCaptureWhileLocked(record)
            }
        }
    }

    private static func hasActiveAdmissionWhileLocked(id: UUID, now: Date) throws -> Bool {
        guard let catalog = try loadCatalogWhileLocked() else { return false }
        return catalog.destinations.contains { $0.id == id && $0.isActive(at: now) }
    }

    private static func requireCurrentClaimWhileLocked(
        _ claim: MomentPendingCaptureClaim,
        now: Date,
        requiresActiveAdmission: Bool = true,
        requiresUnexpiredCapture: Bool = true
    ) throws -> MomentPendingCaptureRecord {
        guard let current = try loadCaptureWhileLocked(id: claim.record.id),
              current.phase == .processing,
              current.claimID == claim.claimID,
              current.id == claim.record.id,
              current.clientRequestID == claim.record.clientRequestID,
              current.admissionID == claim.record.admissionID,
              current.canonicalJPEGSHA256 == claim.record.canonicalJPEGSHA256,
              !requiresUnexpiredCapture || current.expiresAt > now
        else { throw MomentSharingError.stateUnavailable }
        if requiresActiveAdmission {
            guard try hasActiveAdmissionWhileLocked(id: current.admissionID, now: now)
            else { throw MomentSharingError.notPaired }
        }
        return current
    }

    private static func removeCapturesWhileLocked(
        where shouldRemove: (MomentPendingCaptureRecord) -> Bool
    ) throws {
        for record in try loadCaptureRecordsWhileLocked() where shouldRemove(record) {
            try removeCaptureWhileLocked(id: record.id)
        }
    }

    private static func removeCaptureWhileLocked(id: UUID) throws {
        let url = try captureURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func purgeAllWhileLocked() throws {
        guard let directory = SharedContainer.momentShareHandoffDirectoryURL else {
            throw MomentSharingError.stateUnavailable
        }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private static func captureURL(for id: UUID) throws -> URL {
        guard let directory = SharedContainer.momentShareHandoffCapturesDirectoryURL else {
            throw MomentSharingError.stateUnavailable
        }
        return directory.appendingPathComponent(
            "\(id.uuidString.lowercased())\(captureFileSuffix)",
            isDirectory: false
        )
    }

    private static func boundedData(from url: URL, maximumBytes: Int) throws -> Data {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw MomentSharingError.stateUnavailable
        }
        return data
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            return try encoder.encode(value)
        } catch {
            throw MomentSharingError.stateUnavailable
        }
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try PropertyListDecoder().decode(type, from: data)
        } catch {
            throw MomentSharingError.stateUnavailable
        }
    }

    private static func captureOrder(
        _ lhs: MomentPendingCaptureRecord,
        _ rhs: MomentPendingCaptureRecord
    ) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
    }

    private static func isOpaqueIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45 || $0 == 95
        }
    }
}
