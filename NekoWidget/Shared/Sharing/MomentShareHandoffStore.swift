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
    /// Stable device-local destination scope. Legacy single-window catalogs
    /// decode this as nil and are rebound on the next host publication.
    let localWindowID: String?
    let bindingSHA256: Data
    let displayName: String
    let issuedAt: Date
    let expiresAt: Date

    init(
        schemaVersion: Int = Self.schemaVersion,
        id: UUID,
        localWindowID: String? = nil,
        bindingSHA256: Data,
        displayName: String,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.localWindowID = localWindowID
        self.bindingSHA256 = bindingSHA256
        self.displayName = displayName
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    func validated() throws -> Self {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasValidWindowID = localWindowID.map {
            guard let uuid = UUID(uuidString: $0) else { return false }
            return uuid.uuidString.lowercased() == $0.lowercased()
        } ?? true
        guard schemaVersion == Self.schemaVersion,
              hasValidWindowID,
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
        issuedAt <= now.addingTimeInterval(
            MomentShareHandoffStore.maximumLocalClockSkew
        ) && expiresAt > now
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
              Set(destinations.map(\.bindingSHA256)).count == destinations.count,
              Set(destinations.compactMap(\.localWindowID)).count
                == destinations.compactMap(\.localWindowID).count
        else { throw MomentSharingError.stateUnavailable }
        _ = try destinations.map { try $0.validated() }
        guard destinations.allSatisfy({ destination in
            destination.issuedAt <= updatedAt
                && destination.expiresAt <= updatedAt.addingTimeInterval(
                    MomentShareHandoffStore.admissionLifetime
                )
        }) else { throw MomentSharingError.stateUnavailable }
        return self
    }

    func isCurrent(at now: Date) -> Bool {
        updatedAt <= now.addingTimeInterval(
            MomentShareHandoffStore.maximumLocalClockSkew
        )
    }
}

/// Host-only input for publishing the sanitized admission catalog. It is not
/// Codable so a raw construction request cannot accidentally become another
/// persisted authority beside `MomentShareAdmissionCatalog`.
struct MomentShareAdmissionInput: Equatable, Sendable {
    let localWindowID: String?
    let bindingSHA256: Data
    let displayName: String

    init(
        localWindowID: String? = nil,
        bindingSHA256: Data,
        displayName: String
    ) {
        self.localWindowID = localWindowID
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
              expiresAt.timeIntervalSince(createdAt)
                <= MomentShareHandoffStore.captureLifetime,
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

/// Image-free identity used only to keep a live host moderation temporary file
/// while removing crash residue for claims that no longer exist.
struct MomentPendingCaptureClaimIdentity: Hashable, Sendable {
    let captureID: UUID
    let claimID: UUID
}

private struct MomentShareHandoffReportOnlyMarker: Codable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    let createdAt: Date
    let until: Date

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              createdAt > Date(timeIntervalSince1970: 0),
              until > createdAt.addingTimeInterval(
                  -MomentSharingProtocol.maximumRelayClockSkewSeconds
              ),
              until <= createdAt.addingTimeInterval(
                  MomentSharingProtocol.maximumReportOnlyWindowSeconds
                    + MomentSharingProtocol.maximumRelayClockSkewSeconds
              )
        else { throw MomentSharingError.stateUnavailable }
        return self
    }
}

/// Read-only, sanitized host presentation state. Images, capture identifiers,
/// Server identifiers and file paths never cross this boundary. The local
/// admission UUID is exposed only as an opaque destination grouping key so a
/// future multi-window UI can count and cancel without a global cross-window
/// operation. Expiry/retry times are included because omitting them would make
/// a deferred handoff look like active processing.
struct MomentShareHandoffStatusSnapshot: Equatable, Sendable {
    let destinationKey: String
    let phase: MomentPendingCapturePhase
    let lastErrorCode: String?
    let updatedAt: Date
    let expiresAt: Date
    let nextRetryAt: Date?
    /// A pending record can be removed without racing an active host claim.
    /// Presentation remains read-only for now; this supports a future explicit
    /// preparation-cancel operation without inferring safety from the phase.
    let isCancellable: Bool
}

enum MomentShareHandoffTerminalOutcomeReason: String, Codable, Sendable {
    case preparationExpired
    case preparationFailed
}

/// Bounded, image-free history written after short-lived plaintext has been
/// physically removed. It intentionally contains no capture/admission ID,
/// image bytes, path, hash, or destination identity.
struct MomentShareHandoffTerminalOutcomeSnapshot: Equatable, Sendable {
    let reason: MomentShareHandoffTerminalOutcomeReason
    let createdAt: Date
    let expiresAt: Date
}

struct MomentShareHandoffPresentationSnapshot: Equatable, Sendable {
    let statuses: [MomentShareHandoffStatusSnapshot]
    let terminalOutcomes: [MomentShareHandoffTerminalOutcomeSnapshot]
}

private struct MomentShareHandoffTerminalOutcome: Codable, Equatable, Identifiable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    let id: UUID
    let reason: MomentShareHandoffTerminalOutcomeReason
    let createdAt: Date
    let expiresAt: Date

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              createdAt > Date(timeIntervalSince1970: 0),
              expiresAt > createdAt,
              expiresAt.timeIntervalSince(createdAt)
                <= MomentShareHandoffStore.terminalOutcomeLifetime
        else { throw MomentSharingError.stateUnavailable }
        return self
    }
}

private struct MomentShareHandoffTerminalOutcomeCatalog: Codable, Equatable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    var outcomes: [MomentShareHandoffTerminalOutcome]

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              outcomes.count <= MomentShareHandoffStore.maximumTerminalOutcomeCount,
              Set(outcomes.map(\.id)).count == outcomes.count
        else { throw MomentSharingError.stateUnavailable }
        _ = try outcomes.map { try $0.validated() }
        return self
    }
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
    static let maximumLocalClockSkew: TimeInterval = 5 * 60
    static let claimRecoveryInterval: TimeInterval = 5 * 60
    static let maximumAdmissionCount = PrivateWindowCatalogState.maximumWindowCount
    static let maximumPendingCaptureCount = 3
    static let maximumPendingCaptureBytes = 3 * 1_024 * 1_024
    private static let maximumGlobalPendingCaptureCount =
        PrivateWindowCatalogState.maximumWindowCount * maximumPendingCaptureCount
    private static let maximumGlobalPendingCaptureBytes =
        PrivateWindowCatalogState.maximumWindowCount * maximumPendingCaptureBytes
    static let terminalOutcomeLifetime: TimeInterval = 7 * 24 * 60 * 60
    static let maximumTerminalOutcomeCount = 100

    private static let maximumAdmissionFileBytes = 64 * 1_024
    private static let maximumOutcomeFileBytes = 128 * 1_024
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
            try prepareMultiWindowStorageWhileLocked()
            guard now > Date(timeIntervalSince1970: 0),
                  inputs.count <= maximumAdmissionCount,
                  !isReportOnlyDisabledWhileLocked()
            else { throw MomentSharingError.invalidPayload }

            let validatedInputs = try inputs.map { input -> MomentShareAdmissionInput in
                let name = input.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let validWindowID = input.localWindowID.map {
                    guard let uuid = UUID(uuidString: $0) else { return false }
                    return uuid.uuidString.lowercased() == $0.lowercased()
                } ?? true
                guard validWindowID,
                      input.bindingSHA256.count == 32,
                      name == input.displayName,
                      (1...64).contains(name.utf8.count),
                      !name.unicodeScalars.contains(where: {
                          CharacterSet.controlCharacters.contains($0)
                      })
                else { throw MomentSharingError.invalidPayload }
                return input
            }
            guard Set(validatedInputs.map(\.bindingSHA256)).count == validatedInputs.count
                    && Set(validatedInputs.compactMap(\.localWindowID)).count
                        == validatedInputs.compactMap(\.localWindowID).count
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
                if let loaded = try loadCatalogWhileLocked() {
                    guard loaded.isCurrent(at: now) else {
                        throw MomentSharingError.stateUnavailable
                    }
                    existing = loaded
                } else {
                    existing = MomentShareAdmissionCatalog(
                        destinations: [],
                        updatedAt: now
                    )
                }
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
                    localWindowID: input.localWindowID,
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
            try revokeAdmissionsWhileLifecycleLocked()
        }
    }

    /// Caller already owns the validated lifecycle flock. Host code uses this
    /// only after deleting its moderation plaintext, so the durable admission
    /// removal cannot commit while a cancelled analyzer input remains.
    static func revokeAdmissionsWhileLifecycleLocked() throws {
        try purgeAllWhileLocked()
    }

    /// Removes only one local window's Share Extension authority. Ordinary
    /// unlink must not cancel another window's pending capture. The optional
    /// binding also removes a Build-40 admission that predates localWindowID.
    static func revokeAdmissionWhileLifecycleLocked(
        localWindowID: String,
        bindingSHA256: Data?,
        now: Date = .now
    ) throws {
        try prepareMultiWindowStorageWhileLocked()
        // Quarantine is non-authoritative and never user-visible. Remove only
        // this window's scoped late-writer copies; another window can still
        // have a valid pending capture in its own quarantine.
        try purgeLegacyQuarantinesWhileLocked(localWindowID: localWindowID)
        guard let catalog = try loadCatalogWhileLocked() else { return }
        let removed = catalog.destinations.filter {
            $0.localWindowID == localWindowID
                || (bindingSHA256 != nil && $0.bindingSHA256 == bindingSHA256)
        }
        guard !removed.isEmpty else { return }
        let removedIDs = Set(removed.map(\.id))
        let retained = catalog.destinations.filter { !removedIDs.contains($0.id) }
        let replacement = try MomentShareAdmissionCatalog(
            destinations: retained,
            updatedAt: max(now, catalog.updatedAt)
        ).validated()
        try writeCatalogWhileLocked(replacement)
        try removeCapturesWhileLocked { removedIDs.contains($0.admissionID) }
    }

    /// Commits the fail-closed Extension boundary without purging captures.
    /// The host processor uses this split primitive so it can unlink its own
    /// moderation plaintext before making capture/catalog removal the final
    /// cancellation commit point, all under the same lifecycle flock. Only a
    /// full pairing cleanup removes this terminal marker.
    static func writeReportOnlyHandoffMarkerWhileLifecycleLocked(
        until: Date,
        now: Date = .now
    ) throws {
        guard !SharingLifecycleGate.isCleanupRequired,
              let markerURL = SharedContainer.momentShareHandoffReportOnlyMarkerURL
        else { throw MomentSharingError.stateUnavailable }
        let boundedUntil = try MomentSharingProtocol.boundedReportOnlyUntil(
            until,
            receivedAt: now
        )

        var fixedCreatedAt = now
        var fixedUntil = boundedUntil
        var recoveredFileAnchor: Date?
        if FileManager.default.fileExists(atPath: markerURL.path) {
            guard SharingSecureFile.hasRequiredProtectionAndBackupExclusion(markerURL)
            else { throw MomentSharingError.stateUnavailable }
            do {
                let existing = try loadReportOnlyMarkerWhileLocked()
                guard let existing,
                      existing.createdAt <= now.addingTimeInterval(
                          MomentSharingProtocol.maximumRelayClockSkewSeconds
                      ),
                      existing.until <= now.addingTimeInterval(
                          MomentSharingProtocol.maximumReportOnlyWindowSeconds
                            + MomentSharingProtocol.maximumRelayClockSkewSeconds
                      )
                else { throw MomentSharingError.stateUnavailable }
                // The first durable marker fixes the local report-only
                // boundary. Foreground syncs must not replace its inode and
                // slide the filesystem recovery anchor forward.
                return
            } catch {
                guard let anchor = try reportOnlyMarkerRecoveryAnchorWhileLocked(
                    now: now
                ) else { throw MomentSharingError.stateUnavailable }
                let recoveryLimit = anchor.addingTimeInterval(
                    MomentSharingProtocol.maximumReportOnlyWindowSeconds
                )
                guard !MomentSharingProtocol.isReportOnlyWindowClosed(
                    until: recoveryLimit,
                    now: now
                ) else { throw MomentSharingError.stateUnavailable }
                fixedCreatedAt = anchor
                fixedUntil = min(boundedUntil, recoveryLimit)
                recoveredFileAnchor = anchor
            }
        }
        let marker = try MomentShareHandoffReportOnlyMarker(
            createdAt: fixedCreatedAt,
            until: fixedUntil
        ).validated()
        try SharingSecureFile.write(
            try encode(marker),
            to: markerURL
        )
        if let recoveredFileAnchor {
            // Atomic replacement necessarily creates a new inode. Preserve a
            // stable filesystem fallback across repeated payload corruption
            // by restoring one trusted timestamp to the original anchor.
            try FileManager.default.setAttributes(
                [.modificationDate: recoveredFileAnchor],
                ofItemAtPath: markerURL.path
            )
            let attributes = try FileManager.default.attributesOfItem(
                atPath: markerURL.path
            )
            guard let restored = attributes[.modificationDate] as? Date,
                  abs(restored.timeIntervalSince(recoveredFileAnchor)) <= 2
            else { throw MomentSharingError.stateUnavailable }
        }
    }

    /// Lets the host resume a marker-first report-only transition after a
    /// process death between the marker and the sharing-state commit.
    static func reportOnlyHandoffDeadline(
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> Date? {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard let marker = try loadReportOnlyMarkerWhileLocked() else { return nil }
            guard let markerURL = SharedContainer.momentShareHandoffReportOnlyMarkerURL,
                  SharingSecureFile.hasRequiredProtectionAndBackupExclusion(markerURL),
                  marker.createdAt <= now.addingTimeInterval(
                      MomentSharingProtocol.maximumRelayClockSkewSeconds
                  ),
                  marker.until <= now.addingTimeInterval(
                      MomentSharingProtocol.maximumReportOnlyWindowSeconds
                        + MomentSharingProtocol.maximumRelayClockSkewSeconds
                  )
            else { throw MomentSharingError.stateUnavailable }
            return marker.until
        }
    }

    /// Recovers a fixed, bounded deadline when the protected marker exists
    /// but its payload cannot be decoded. The file timestamp is not treated as
    /// relay authority: it may only shorten or recreate a local fail-closed
    /// window of at most 24 hours. Callers prefer a valid sharing-state
    /// deadline and use this anchor only after marker decoding failed.
    static func reportOnlyHandoffRecoveryDeadline(
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> Date? {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard let anchor = try reportOnlyMarkerRecoveryAnchorWhileLocked(
                now: now
            ) else { return nil }
            return anchor.addingTimeInterval(
                MomentSharingProtocol.maximumReportOnlyWindowSeconds
            )
        }
    }

    /// Extension-safe read of every sanitized destination currently owned by
    /// the private-window catalog. The Extension receives only host-issued
    /// opaque admission IDs and labels; Pairing state, relay identifiers, and
    /// room credentials remain unavailable at this boundary. `stageCapture`
    /// revalidates the selected admission under the lifecycle lock, so an
    /// expired or revoked menu choice can never fall back to another window.
    static func activeAdmissions(now: Date = .now) throws -> [MomentShareDestinationAdmission] {
        try SharingLifecycleGate.withExclusive {
            try prepareMultiWindowStorageWhileLocked()
            guard !SharingLifecycleGate.isCleanupRequired else {
                throw MomentSharingError.stateUnavailable
            }
            if isReportOnlyDisabledWhileLocked() {
                try purgeAllWhileLocked()
                return []
            }
            // Opening the Share sheet is itself a cleanup opportunity. Do
            // not require another stage attempt or a host-app launch before
            // expired canonical plaintext is physically removed.
            try pruneCapturesWhileLocked(now: now)
            guard let catalog = try loadCurrentCatalogWhileLocked(now: now)
            else { return [] }
            let windowCatalog = try PrivateWindowCatalogStore.load()
            return try extensionEligibleAdmissions(
                catalog: catalog,
                windowCatalog: windowCatalog,
                now: now
            )
        }
    }

    /// Pure policy shared with the runtime self-test. A scoped admission is
    /// eligible only while its exact local window still exists. A Build-40
    /// admission without a local window ID remains usable solely for an
    /// unambiguous single-window installation; it is never guessed onto one of
    /// several windows.
    static func extensionEligibleAdmissions(
        catalog: MomentShareAdmissionCatalog,
        windowCatalog: PrivateWindowCatalogState?,
        now: Date
    ) throws -> [MomentShareDestinationAdmission] {
        let validatedCatalog = try catalog.validated()
        let active = validatedCatalog.destinations.filter { $0.isActive(at: now) }
        let eligible: [MomentShareDestinationAdmission]
        if let windowCatalog = try windowCatalog?.validated() {
            let windowIDs = Set(windowCatalog.windows.map(\.localWindowID))
            let scoped = active.filter { admission in
                admission.localWindowID.map(windowIDs.contains) == true
            }
            if !scoped.isEmpty || windowCatalog.windows.count > 1 {
                eligible = scoped
            } else {
                // Build 40 admissions had no localWindowID. They remain
                // unambiguous only before a second local window exists.
                let legacy = active.filter { $0.localWindowID == nil }
                guard legacy.count <= 1 else {
                    throw MomentSharingError.stateUnavailable
                }
                eligible = legacy
            }
        } else {
            let legacy = active.filter { $0.localWindowID == nil }
            guard legacy.count <= 1 else {
                throw MomentSharingError.stateUnavailable
            }
            eligible = legacy
        }
        return eligible.sorted { lhs, rhs in
            if lhs.displayName == rhs.displayName {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName)
                == .orderedAscending
        }
    }

    /// Returns only fields needed by the host app. Sorting happens before
    /// capture identifiers are stripped so simultaneous captures remain
    /// stable; only the local opaque destination grouping key crosses into the
    /// presentation policy.
    static func presentationSnapshot(
        now: Date = .now
    ) throws -> MomentShareHandoffPresentationSnapshot {
        try SharingLifecycleGate.withExclusive {
            try prepareMultiWindowStorageWhileLocked()
            guard !SharingLifecycleGate.isCleanupRequired else {
                throw MomentSharingError.stateUnavailable
            }
            if isReportOnlyDisabledWhileLocked() {
                try purgeAllWhileLocked()
                return MomentShareHandoffPresentationSnapshot(
                    statuses: [],
                    terminalOutcomes: []
                )
            }
            let records = try pruneCapturesWhileLocked(now: now)
            let statuses = records
                .sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
                .map {
                    MomentShareHandoffStatusSnapshot(
                        destinationKey: $0.admissionID.uuidString.lowercased(),
                        phase: $0.phase,
                        lastErrorCode: $0.lastErrorCode,
                        updatedAt: $0.updatedAt,
                        expiresAt: $0.expiresAt,
                        nextRetryAt: $0.nextRetryAt,
                        isCancellable: true
                    )
                }
            let terminalOutcomes = try loadTerminalOutcomesWhileLocked(now: now)
                .sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
                .map {
                    MomentShareHandoffTerminalOutcomeSnapshot(
                        reason: $0.reason,
                        createdAt: $0.createdAt,
                        expiresAt: $0.expiresAt
                    )
                }
            return MomentShareHandoffPresentationSnapshot(
                statuses: statuses,
                terminalOutcomes: terminalOutcomes
            )
        }
    }

    /// Deletes every still-local plaintext preparation. A processing claim is
    /// removed by the same CAS authority as a pending item; a late host result
    /// can no longer promote because the claimed record no longer exists. An
    /// optional opaque destination key keeps future multi-window cancellation
    /// scoped; nil retains the explicit v1 "all local preparations" action.
    @discardableResult
    static func discardCancellableCaptures(
        destinationKey: String? = nil,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> Int {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try discardCancellableCapturesWhileLifecycleLocked(
                destinationKey: destinationKey
            )
        }
    }

    /// Caller already owns the validated lifecycle flock.
    @discardableResult
    static func discardCancellableCapturesWhileLifecycleLocked(
        destinationKey: String? = nil
    ) throws -> Int {
        let records = try loadCaptureRecordsWhileLocked().filter {
            destinationKey == nil
                || $0.admissionID.uuidString.lowercased() == destinationKey
        }
        for record in records {
            try removeCaptureWhileLocked(id: record.id)
        }
        return records.count
    }

    static func clearTerminalOutcomes(
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try prepareMultiWindowStorageWhileLocked()
            guard let url = SharedContainer.momentShareHandoffOutcomesURL else {
                throw MomentSharingError.stateUnavailable
            }
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    static func isCurrentClaim(
        _ claim: MomentPendingCaptureClaim,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> Bool {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try pruneCapturesWhileLocked(now: now)
            guard let current = try loadCaptureWhileLocked(id: claim.record.id) else {
                return false
            }
            return current.phase == .processing
                && current.claimID == claim.claimID
                && current.id == claim.record.id
                && current.clientRequestID == claim.record.clientRequestID
        }
    }

    static func activeClaimIdentities(
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> Set<MomentPendingCaptureClaimIdentity> {
        try withActiveClaimIdentities(
            validating: lifecycleToken,
            now: now
        ) { $0 }
    }

    /// Runs residue reconciliation while the same lifecycle flock protects
    /// both the active-claim snapshot and any caller cleanup. Without this
    /// boundary a second drain could create a valid moderation inode after
    /// the snapshot and have it mistaken for an orphan.
    static func withActiveClaimIdentities<T>(
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now,
        _ operation: (Set<MomentPendingCaptureClaimIdentity>) throws -> T
    ) throws -> T {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            let records = try pruneCapturesWhileLocked(now: now)
            let identities: Set<MomentPendingCaptureClaimIdentity> = Set(
                records.compactMap {
                    record -> MomentPendingCaptureClaimIdentity? in
                    guard record.phase == .processing,
                          let claimID = record.claimID
                    else { return nil }
                    return MomentPendingCaptureClaimIdentity(
                        captureID: record.id,
                        claimID: claimID
                    )
                }
            )
            return try operation(identities)
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
            guard !isReportOnlyDisabledWhileLocked(),
                  let catalog = try loadCurrentCatalogWhileLocked(now: now),
                  catalog.destinations.contains(where: {
                      $0.id == admissionID && $0.isActive(at: now)
                  })
            else { throw MomentSharingError.notPaired }

            let current = try loadCaptureRecordsWhileLocked()
            let destinationRecords = current.filter {
                $0.admissionID == admissionID
            }
            let destinationBytes = destinationRecords.reduce(0) {
                $0 + $1.canonicalJPEGSize
            }
            let globalBytes = current.reduce(0) { $0 + $1.canonicalJPEGSize }
            guard destinationRecords.count < maximumPendingCaptureCount,
                  destinationBytes
                    <= maximumPendingCaptureBytes - record.canonicalJPEGSize,
                  current.count < maximumGlobalPendingCaptureCount,
                  globalBytes
                    <= maximumGlobalPendingCaptureBytes - record.canonicalJPEGSize
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

    /// Runs one short synchronous host operation only while this exact claim
    /// and installation token are still current. The host uses this to create
    /// its moderation input before releasing the lifecycle flock; cancellation
    /// or unlink therefore either removes an already-created temporary file or
    /// wins first and prevents a stale task from creating one afterward.
    static func withCurrentClaim<Result>(
        _ claim: MomentPendingCaptureClaim,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now,
        operation: (MomentPendingCaptureRecord) throws -> Result
    ) throws -> Result {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            let current = try requireCurrentClaimWhileLocked(claim, now: now)
            return try operation(current)
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
                try appendTerminalOutcomeWhileLocked(
                    reason: .preparationExpired,
                    createdAt: min(current.expiresAt, now),
                    now: now
                )
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

    /// Removes a still-authorized plaintext claim before recording a fixed,
    /// image-free local result. A notice write may fail after deletion, but the
    /// rejected preparation is never retained merely for presentation history.
    static func discardCapture(
        _ claim: MomentPendingCaptureClaim,
        recording outcomeReason: MomentShareHandoffTerminalOutcomeReason,
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
            try appendTerminalOutcomeWhileLocked(
                reason: outcomeReason,
                createdAt: now,
                now: now
            )
        }
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
        try prepareMultiWindowStorageWhileLocked()
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
        try prepareMultiWindowStorageWhileLocked()
        guard let url = SharedContainer.momentShareHandoffAdmissionsURL else {
            throw MomentSharingError.stateUnavailable
        }
        let encoded = try encode(try catalog.validated())
        guard encoded.count <= maximumAdmissionFileBytes else {
            throw MomentSharingError.stateUnavailable
        }
        try SharingSecureFile.write(encoded, to: url)
    }

    private static func loadTerminalOutcomesWhileLocked(
        now: Date
    ) throws -> [MomentShareHandoffTerminalOutcome] {
        try prepareMultiWindowStorageWhileLocked()
        guard let url = SharedContainer.momentShareHandoffOutcomesURL else {
            throw MomentSharingError.stateUnavailable
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try boundedData(from: url, maximumBytes: maximumOutcomeFileBytes)
            var catalog = try decode(
                MomentShareHandoffTerminalOutcomeCatalog.self,
                from: data
            ).validated()
            let original = catalog
            catalog.outcomes.removeAll { $0.expiresAt <= now }
            if catalog != original {
                try writeTerminalOutcomesWhileLocked(catalog.outcomes)
            }
            return catalog.outcomes
        } catch {
            // Presentation history is replaceable and grants no authority. A
            // malformed file must not block capture cleanup or sharing state.
            try? FileManager.default.removeItem(at: url)
            return []
        }
    }

    private static func appendTerminalOutcomeWhileLocked(
        reason: MomentShareHandoffTerminalOutcomeReason,
        createdAt: Date,
        now: Date
    ) throws {
        let expiresAt = createdAt.addingTimeInterval(terminalOutcomeLifetime)
        // A device returning after the entire notice-retention window should
        // delete stale plaintext without creating an already-expired row.
        guard expiresAt > now else { return }
        var outcomes = try loadTerminalOutcomesWhileLocked(now: now)
        outcomes.append(try MomentShareHandoffTerminalOutcome(
            id: UUID(),
            reason: reason,
            createdAt: createdAt,
            expiresAt: expiresAt
        ).validated())
        outcomes = Array(outcomes.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(maximumTerminalOutcomeCount))
        try writeTerminalOutcomesWhileLocked(outcomes)
    }

    private static func writeTerminalOutcomesWhileLocked(
        _ outcomes: [MomentShareHandoffTerminalOutcome]
    ) throws {
        try prepareMultiWindowStorageWhileLocked()
        guard let url = SharedContainer.momentShareHandoffOutcomesURL else {
            throw MomentSharingError.stateUnavailable
        }
        if outcomes.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        let catalog = try MomentShareHandoffTerminalOutcomeCatalog(
            outcomes: outcomes
        ).validated()
        let data = try encode(catalog)
        guard data.count <= maximumOutcomeFileBytes else {
            throw MomentSharingError.stateUnavailable
        }
        try MomentShareHandoffProtectedFile.write(data, to: url)
    }

    private static func loadCaptureRecordsWhileLocked() throws -> [MomentPendingCaptureRecord] {
        try prepareMultiWindowStorageWhileLocked()
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

    @discardableResult
    private static func pruneCapturesWhileLocked(
        now: Date
    ) throws -> [MomentPendingCaptureRecord] {
        var retained: [MomentPendingCaptureRecord] = []
        for var record in try loadCaptureRecordsWhileLocked() {
            if record.createdAt > now.addingTimeInterval(maximumLocalClockSkew) {
                // A future local timestamp cannot become retention authority.
                // This is replaceable derived input, so fail closed and remove
                // it without manufacturing a misleading user outcome.
                try removeCaptureWhileLocked(id: record.id)
                continue
            }
            if record.expiresAt <= now {
                try removeCaptureWhileLocked(id: record.id)
                // Deletion is deliberately first. A disk failure may omit the
                // notice, but never keeps plaintext merely for UI history.
                try? appendTerminalOutcomeWhileLocked(
                    reason: .preparationExpired,
                    createdAt: record.expiresAt,
                    now: now
                )
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
            retained.append(record)
        }
        return retained
    }

    private static func hasActiveAdmissionWhileLocked(id: UUID, now: Date) throws -> Bool {
        guard !isReportOnlyDisabledWhileLocked(),
              let catalog = try loadCurrentCatalogWhileLocked(now: now)
        else { return false }
        return catalog.destinations.contains { $0.id == id && $0.isActive(at: now) }
    }

    private static func loadCurrentCatalogWhileLocked(
        now: Date
    ) throws -> MomentShareAdmissionCatalog? {
        guard let catalog = try loadCatalogWhileLocked() else { return nil }
        guard catalog.isCurrent(at: now) else {
            try purgeAllWhileLocked()
            return nil
        }
        return catalog
    }

    private static func isReportOnlyDisabledWhileLocked() -> Bool {
        guard let markerURL = SharedContainer.momentShareHandoffReportOnlyMarkerURL
        else { return true }
        return FileManager.default.fileExists(atPath: markerURL.path)
    }

    private static func loadReportOnlyMarkerWhileLocked() throws
        -> MomentShareHandoffReportOnlyMarker? {
        guard let markerURL = SharedContainer.momentShareHandoffReportOnlyMarkerURL
        else { throw MomentSharingError.stateUnavailable }
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return nil }
        do {
            let data = try boundedData(from: markerURL, maximumBytes: 4 * 1_024)
            return try decode(
                MomentShareHandoffReportOnlyMarker.self,
                from: data
            ).validated()
        } catch let error as MomentSharingError {
            throw error
        } catch {
            throw MomentSharingError.stateUnavailable
        }
    }

    private static func reportOnlyMarkerRecoveryAnchorWhileLocked(
        now: Date
    ) throws -> Date? {
        guard let markerURL = SharedContainer.momentShareHandoffReportOnlyMarkerURL
        else { throw MomentSharingError.stateUnavailable }
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return nil }
        guard SharingSecureFile.hasRequiredProtectionAndBackupExclusion(markerURL)
        else { throw MomentSharingError.stateUnavailable }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: markerURL.path
        )
        let dates = [
            attributes[.creationDate] as? Date,
            attributes[.modificationDate] as? Date
        ].compactMap { $0 }
        let latestPermittedAnchor = now.addingTimeInterval(
            MomentSharingProtocol.maximumRelayClockSkewSeconds
        )
        guard !dates.isEmpty,
              dates.allSatisfy({
                  $0 > Date(timeIntervalSince1970: 0)
                    && $0 <= latestPermittedAnchor
              }),
              let anchor = dates.min()
        else { throw MomentSharingError.stateUnavailable }
        return anchor
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
        let fileManager = FileManager.default
        var firstError: Error?
        var directories = [directory]
            + SharedContainer.legacyMomentShareHandoffDirectoryURLs
        // A late Build 61 extension can leave plaintext captures inside either
        // quarantine. Revoking handoff authority must physically remove those
        // copies too; quarantine is never a retention exception.
        directories.append(contentsOf: legacyQuarantineDirectories)
        for candidate in directories where fileManager.fileExists(atPath: candidate.path) {
            do { try fileManager.removeItem(at: candidate) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private static var legacyQuarantineDirectories: [URL] {
        [
            SharedContainer.momentShareHandoffLegacyQuarantineDirectoryURL,
            SharedContainer.privateWindowLegacySharingQuarantineDirectoryURL
        ].compactMap { $0 }
    }

    private static func purgeLegacyQuarantinesWhileLocked(
        localWindowID: String
    ) throws {
        guard let windowUUID = UUID(uuidString: localWindowID),
              let catalog = try PrivateWindowCatalogStore.load()
        else { throw MomentSharingError.stateUnavailable }
        let canonicalWindowID = windowUUID.uuidString.lowercased()
        let catalogWindowIDs = Set(catalog.windows.map {
            $0.localWindowID.lowercased()
        })
        guard catalogWindowIDs.contains(canonicalWindowID) else {
            throw MomentSharingError.stateUnavailable
        }

        let fileManager = FileManager.default
        var firstError: Error?

        if let handoffRoot = SharedContainer
            .momentShareHandoffLegacyQuarantineDirectoryURL,
           fileManager.fileExists(atPath: handoffRoot.path) {
            // Build 63 stores one directory per catalog window. An unexpected
            // direct child could be an older unscoped quarantine, whose owner
            // cannot be proven. Fail the unlink rather than deleting another
            // window's plaintext or falsely claiming complete privacy cleanup.
            let entries = try fileManager.contentsOfDirectory(
                at: handoffRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            for entry in entries {
                let values = try entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true,
                      values.isSymbolicLink != true,
                      catalogWindowIDs.contains(entry.lastPathComponent.lowercased())
                else { throw MomentSharingError.stateUnavailable }
            }
            let scopedDirectory = handoffRoot.appendingPathComponent(
                canonicalWindowID,
                isDirectory: true
            )
            if fileManager.fileExists(atPath: scopedDirectory.path) {
                do { try fileManager.removeItem(at: scopedDirectory) }
                catch { firstError = error }
            }
        }

        // The complete Build-40 `sharing/` quarantine always belongs to the
        // stable first catalog slot. Other slots must never delete it.
        if catalog.windows.first?.localWindowID.lowercased() == canonicalWindowID,
           let sharingRoot = SharedContainer
            .privateWindowLegacySharingQuarantineDirectoryURL,
           fileManager.fileExists(atPath: sharingRoot.path) {
            do { try fileManager.removeItem(at: sharingRoot) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private static func captureURL(for id: UUID) throws -> URL {
        try prepareMultiWindowStorageWhileLocked()
        guard let directory = SharedContainer.momentShareHandoffCapturesDirectoryURL else {
            throw MomentSharingError.stateUnavailable
        }
        return directory.appendingPathComponent(
            "\(id.uuidString.lowercased())\(captureFileSuffix)",
            isDirectory: false
        )
    }

    private struct ScopedLegacyHandoffSource {
        let url: URL
        let localWindowID: String
    }

    private static func scopedLegacyHandoffSourcesWhileLocked() throws
        -> [ScopedLegacyHandoffSource] {
        guard let catalog = try PrivateWindowCatalogStore.load(),
              let legacyOwner = catalog.windows.first
        else { throw MomentSharingError.stateUnavailable }

        var candidates: [ScopedLegacyHandoffSource] = []
        if let legacy = SharedContainer.legacySharingCacheDirectoryURL {
            candidates.append(
                ScopedLegacyHandoffSource(
                    url: legacy.appendingPathComponent(
                        "moment-handoff",
                        isDirectory: true
                    ),
                    localWindowID: legacyOwner.localWindowID.lowercased()
                )
            )
        }
        for entry in catalog.windows {
            guard let sharing = SharedContainer.windowSharingDirectoryURL(
                localWindowID: entry.localWindowID
            ) else { throw MomentSharingError.stateUnavailable }
            candidates.append(
                ScopedLegacyHandoffSource(
                    url: sharing.appendingPathComponent(
                        "moment-handoff",
                        isDirectory: true
                    ),
                    localWindowID: entry.localWindowID.lowercased()
                )
            )
        }

        var seen = Set<String>()
        return candidates.filter {
            seen.insert($0.url.standardizedFileURL.path).inserted
        }
    }

    /// Moves the one pre-multi-window handoff directory into stable shared
    /// storage. This runs only while the lifecycle flock is held. A global
    /// directory plus a legacy directory, or more than one legacy directory,
    /// could contain independent plaintext authorities and therefore fails
    /// closed instead of merging or guessing which one wins.
    private static func prepareMultiWindowStorageWhileLocked() throws {
        guard let destination = SharedContainer.momentShareHandoffDirectoryURL
        else { throw MomentSharingError.stateUnavailable }
        let fileManager = FileManager.default
        let sources = try scopedLegacyHandoffSourcesWhileLocked()
            .filter { fileManager.fileExists(atPath: $0.url.path) }
        if fileManager.fileExists(atPath: destination.path) {
            guard SharedContainer
                .legacyMomentShareHandoffDirectoryIsSafelyQuarantinable(
                    destination
                ),
                sources.allSatisfy({ source in
                    SharedContainer
                        .legacyMomentShareHandoffDirectoryIsSafelyQuarantinable(
                            source.url
                        )
                })
            else { throw MomentSharingError.stateUnavailable }
            try quarantineLegacyHandoffSourcesWhileLocked(sources)
            return
        }
        guard sources.count <= 1 else {
            throw MomentSharingError.stateUnavailable
        }
        guard let source = sources.first?.url else { return }
        guard SharedContainer
            .legacyMomentShareHandoffDirectoryIsSafelyQuarantinable(source)
        else { throw MomentSharingError.stateUnavailable }
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            throw MomentSharingError.stateUnavailable
        }
    }

    /// A previous app/extension process can recreate its old handoff path
    /// after v2 has committed. The v2 directory remains authoritative; each
    /// validated old directory is atomically moved aside without merging or
    /// deleting pending plaintext.
    private static func quarantineLegacyHandoffSourcesWhileLocked(
        _ sources: [ScopedLegacyHandoffSource],
        quarantineRoot explicitQuarantineRoot: URL? = nil
    ) throws {
        guard !sources.isEmpty else { return }
        guard let quarantineRoot = explicitQuarantineRoot
            ?? SharedContainer.momentShareHandoffLegacyQuarantineDirectoryURL
        else { throw MomentSharingError.stateUnavailable }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: quarantineRoot,
                withIntermediateDirectories: true
            )
            try SharingSecureFile.enforceProtectionAndBackupExclusion(
                quarantineRoot
            )
            for source in sources {
                guard let windowUUID = UUID(uuidString: source.localWindowID)
                else { throw MomentSharingError.stateUnavailable }
                let windowRoot = quarantineRoot.appendingPathComponent(
                    windowUUID.uuidString.lowercased(),
                    isDirectory: true
                )
                try fileManager.createDirectory(
                    at: windowRoot,
                    withIntermediateDirectories: true
                )
                try SharingSecureFile.enforceProtectionAndBackupExclusion(
                    windowRoot
                )
                let quarantine = windowRoot.appendingPathComponent(
                    UUID().uuidString.lowercased(),
                    isDirectory: true
                )
                guard !fileManager.fileExists(atPath: quarantine.path) else {
                    throw MomentSharingError.stateUnavailable
                }
                try fileManager.moveItem(at: source.url, to: quarantine)
            }
        } catch {
            throw MomentSharingError.stateUnavailable
        }
    }

#if DEBUG
    static func runtimeTestQuarantineLegacyHandoffSources(
        _ sources: [URL],
        quarantineRoot: URL,
        localWindowID: String
    ) throws {
        try quarantineLegacyHandoffSourcesWhileLocked(
            sources.map {
                ScopedLegacyHandoffSource(
                    url: $0,
                    localWindowID: localWindowID
                )
            },
            quarantineRoot: quarantineRoot
        )
    }
#endif

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
