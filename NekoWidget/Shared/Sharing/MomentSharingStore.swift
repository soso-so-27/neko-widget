import Foundation

enum MomentOutboxPhase: String, Codable, Sendable {
    case prepared
    case reserved
    case uploaded
    /// Commit may already have reached the relay. This phase is deliberately
    /// not user-cancellable; retrying the same idempotency key reconciles an
    /// ambiguous response without claiming that the photo was never sent.
    case committing
    case committed
    /// The relay may have accepted commit, but this installation could not
    /// reconcile the idempotent response before the relay's response-replay
    /// window elapsed. This terminal state is not proof that delivery failed.
    case deliveryResultUnknown
    case failed
}

struct MomentOutboxItem: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    let id: UUID
    let context: MomentRequestContext
    var phase: MomentOutboxPhase
    let ciphertextFileName: String
    let ciphertextSize: Int
    let ciphertextSHA256: Data
    let moderationVersion: Int
    let senderPolicyVersion: Int
    let senderPolicyAcceptedAt: Date
    var serverMomentID: String? = nil
    var uploadExpiresAt: Date? = nil
    var attemptCount: Int
    var nextRetryAt: Date? = nil
    var lastErrorCode: String? = nil
    var commitStartedAt: Date? = nil
    /// Relay acknowledgement metadata. These fields prove only that the relay
    /// accepted the idempotent commit; they do not mean that a recipient has
    /// downloaded, opened, or read the photograph. Legacy records decode all
    /// three values as nil.
    var committedAt: Date? = nil
    var unreceivedExpiresAt: Date? = nil
    var recipientCount: Int? = nil
    /// The first time this installation observed the relay reporting that the
    /// recipient device acknowledged the encrypted delivery. This is not an
    /// opened/read receipt and intentionally carries no image or recipient
    /// metadata. Older records decode this additive optional field as nil.
    var recipientDeliveryConfirmedAt: Date? = nil
    let createdAt: Date
    var updatedAt: Date

    func validated() throws -> Self {
        _ = try context.validated()
        guard schemaVersion == Self.schemaVersion,
              id == context.clientMomentID,
              ciphertextFileName == "\(id.uuidString.lowercased()).ciphertext",
              (100...MomentSharingProtocol.maximumObjectCiphertextBytes).contains(ciphertextSize),
              ciphertextSHA256.count == 32,
              moderationVersion == MomentSharingProtocol.moderationVersion,
              senderPolicyVersion >= 1,
              attemptCount >= 0,
              lastErrorCode == DiagnosticLogPrivacy.normalizedMomentOutboxErrorCode(
                lastErrorCode
              ),
              createdAt <= updatedAt,
              commitStartedAt.map { $0 >= createdAt } ?? true,
              commitStartedAt.map { $0 <= updatedAt } ?? true,
              (phase != .committing && phase != .deliveryResultUnknown)
                || commitStartedAt != nil,
              (phase == .committing || phase == .committed
                || phase == .deliveryResultUnknown || commitStartedAt == nil),
              serverMomentID.map(Self.isOpaqueIdentifier) ?? true,
              phase == .prepared || phase == .failed || serverMomentID != nil,
              (phase == .committed || recipientDeliveryConfirmedAt == nil),
              recipientDeliveryConfirmedAt.map { confirmedAt in
                  confirmedAt >= (committedAt ?? createdAt) && confirmedAt <= updatedAt
              } ?? true,
              Self.hasValidCommitMetadata(
                  phase: phase,
                  commitStartedAt: commitStartedAt,
                  committedAt: committedAt,
                  unreceivedExpiresAt: unreceivedExpiresAt,
                  recipientCount: recipientCount
              )
        else { throw MomentSharingError.stateUnavailable }
        return self
    }

    private static func hasValidCommitMetadata(
        phase: MomentOutboxPhase,
        commitStartedAt: Date?,
        committedAt: Date?,
        unreceivedExpiresAt: Date?,
        recipientCount: Int?
    ) -> Bool {
        let valuesAreAbsent = committedAt == nil
            && unreceivedExpiresAt == nil
            && recipientCount == nil
        if phase != .committed { return valuesAreAbsent }
        // Legacy committed records written before commitStartedAt and relay
        // metadata were added remain readable. Every new commit first records
        // commitStartedAt, so it must also persist the complete response tuple.
        if valuesAreAbsent { return commitStartedAt == nil }
        guard let committedAt,
              let unreceivedExpiresAt,
              let recipientCount,
              commitStartedAt != nil
        else { return false }
        return committedAt > Date(timeIntervalSince1970: 0)
            && unreceivedExpiresAt > committedAt
            && recipientCount >= 1
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

/// Fixed, privacy-safe reasons for a local send preparation ending before any
/// network request. Never add associated values or arbitrary diagnostic text:
/// this ledger intentionally cannot contain image data, file paths, hashes,
/// relay IDs, or family/participant identifiers.
enum MomentOutgoingOutcomeReason: String, Codable, Sendable {
    case sensitiveContent
    case invalidPhoto
    case photoTooLarge
    case preparationExpired
}

struct MomentOutgoingOutcome: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    static let maximumCount = 100
    static let retentionSeconds: TimeInterval = 7 * 24 * 60 * 60

    var schemaVersion: Int = Self.schemaVersion
    let id: UUID
    let reason: MomentOutgoingOutcomeReason
    let createdAt: Date
    let expiresAt: Date

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              createdAt > Date(timeIntervalSince1970: 0),
              expiresAt > createdAt,
              expiresAt.timeIntervalSince(createdAt) <= Self.retentionSeconds
        else { throw MomentSharingError.stateUnavailable }
        return self
    }

}

enum MomentInboxState: String, Codable, Sendable {
    case available
    case acknowledged
    case revoked
    case blocked
}

enum MomentReportOutboxPhase: String, Codable, Sendable {
    case prepared
    case reserved
    case uploaded
    case committing
    case committed
    /// Commit may have succeeded, but the relay's bounded report-content
    /// reconciliation window elapsed before this installation confirmed it.
    case deliveryResultUnknown
}

struct MomentReportOutboxItem: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    let id: UUID
    let momentID: String
    let reason: MomentReportReason
    let ciphertextFileName: String
    let ciphertextSize: Int
    let ciphertextSHA256: Data
    let moderationKeyID: String
    let reporterConsentAcceptedAt: Date
    let commitRequestID: UUID
    var phase: MomentReportOutboxPhase
    var serverReportID: String? = nil
    var commitStartedAt: Date? = nil
    let createdAt: Date
    var updatedAt: Date

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              Self.isOpaqueIdentifier(momentID),
              ciphertextFileName == "report-\(id.uuidString.lowercased()).ciphertext",
              (29...MomentSharingProtocol.maximumObjectCiphertextBytes).contains(ciphertextSize),
              ciphertextSHA256.count == 32,
              moderationKeyID == "moderation-v1",
              createdAt <= updatedAt,
              commitStartedAt.map { $0 >= createdAt && $0 <= updatedAt } ?? true,
              (phase != .committing && phase != .deliveryResultUnknown)
                || commitStartedAt != nil,
              (phase == .committing || phase == .committed
                || phase == .deliveryResultUnknown || commitStartedAt == nil),
              serverReportID.map(Self.isOpaqueIdentifier) ?? true,
              phase == .prepared || serverReportID != nil
        else { throw MomentSharingError.stateUnavailable }
        return self
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

struct MomentInboxItem: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    let id: String
    let senderParticipantID: String
    let kind: MomentKind
    let keyEpoch: Int
    var localJPEGFileName: String?
    let capturedAt: Date?
    let captureDateIsMissing: Bool
    let committedAt: Date
    let receivedAt: Date
    var state: MomentInboxState
    var acknowledgedAt: Date? = nil
    var accessExpiresAt: Date

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              Self.isOpaqueIdentifier(id),
              Self.isOpaqueIdentifier(senderParticipantID),
              keyEpoch >= 1,
              (localJPEGFileName == nil || localJPEGFileName == "\(id).jpg"),
              (state == .blocked || state == .revoked
                || ((state == .available || state == .acknowledged)
                    == (localJPEGFileName != nil))),
              captureDateIsMissing == (capturedAt == nil),
              accessExpiresAt > committedAt,
              (state != .acknowledged || acknowledgedAt != nil)
        else { throw MomentSharingError.stateUnavailable }
        return self
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

/// A local bookmark for a safely displayed received photo. It deliberately
/// stores no file path, participant identifier, PhotoKit identifier, or image
/// bytes. The corresponding JPEG remains governed by the sharing history's
/// absolute 90-day / 500-item / 256-MiB limits.
struct MomentSavedMemoryRecord: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    let momentID: String
    let savedAt: Date

    var id: String { momentID }

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              Self.isOpaqueIdentifier(momentID),
              savedAt > Date(timeIntervalSince1970: 0)
        else { throw MomentSharingError.stateUnavailable }
        return self
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

struct MomentSharingState: Codable, Equatable, Sendable {
    static let schemaVersion = 6
    var schemaVersion: Int = Self.schemaVersion
    var storageRevision: Int
    var changeCursor: String?
    var reportOnlyUntil: Date?
    var outbox: [MomentOutboxItem]
    var inbox: [MomentInboxItem]
    var savedMemories: [MomentSavedMemoryRecord]
    var reportOutbox: [MomentReportOutboxItem]
    var outgoingOutcomes: [MomentOutgoingOutcome]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case storageRevision
        case changeCursor
        case reportOnlyUntil
        case outbox
        case inbox
        case savedMemories
        case reportOutbox
        case outgoingOutcomes
    }

    init(
        storageRevision: Int,
        changeCursor: String?,
        reportOnlyUntil: Date? = nil,
        outbox: [MomentOutboxItem],
        inbox: [MomentInboxItem],
        savedMemories: [MomentSavedMemoryRecord] = [],
        reportOutbox: [MomentReportOutboxItem],
        outgoingOutcomes: [MomentOutgoingOutcome] = []
    ) {
        self.storageRevision = storageRevision
        self.changeCursor = changeCursor
        self.reportOnlyUntil = reportOnlyUntil
        self.outbox = outbox
        self.inbox = inbox
        self.savedMemories = savedMemories
        self.reportOutbox = reportOutbox
        self.outgoingOutcomes = outgoingOutcomes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchema = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.schemaVersion).contains(decodedSchema) else {
            throw MomentSharingError.stateUnavailable
        }
        schemaVersion = Self.schemaVersion
        storageRevision = try container.decode(Int.self, forKey: .storageRevision)
        changeCursor = try container.decodeIfPresent(String.self, forKey: .changeCursor)
        reportOnlyUntil = try container.decodeIfPresent(Date.self, forKey: .reportOnlyUntil)
        var decodedOutbox = try container.decode(
            [MomentOutboxItem].self,
            forKey: .outbox
        )
        if decodedSchema < 4 {
            for index in decodedOutbox.indices
            where decodedOutbox[index].phase == .committing
                && decodedOutbox[index].commitStartedAt == nil {
                // Older schemas updated `updatedAt` on every retry. Freeze a
                // one-time stable ambiguity anchor during migration, preferring
                // the earlier bounded lease date when it is available.
                decodedOutbox[index].commitStartedAt = max(
                    decodedOutbox[index].createdAt,
                    min(
                        decodedOutbox[index].updatedAt,
                        decodedOutbox[index].uploadExpiresAt
                            ?? decodedOutbox[index].updatedAt
                    )
                )
            }
        }
        var decodedReportOutbox = try container.decodeIfPresent(
            [MomentReportOutboxItem].self,
            forKey: .reportOutbox
        ) ?? []
        if decodedSchema < 5 {
            for index in decodedReportOutbox.indices
            where decodedReportOutbox[index].phase == .committing
                && decodedReportOutbox[index].commitStartedAt == nil {
                // Report retries did not change updatedAt in the older
                // schemas, so it is a stable one-time ambiguity anchor.
                decodedReportOutbox[index].commitStartedAt = max(
                    decodedReportOutbox[index].createdAt,
                    decodedReportOutbox[index].updatedAt
                )
            }
        }
        outbox = decodedOutbox
        inbox = try container.decode([MomentInboxItem].self, forKey: .inbox)
        savedMemories = try container.decodeIfPresent(
            [MomentSavedMemoryRecord].self,
            forKey: .savedMemories
        ) ?? []
        reportOutbox = decodedReportOutbox
        outgoingOutcomes = try container.decodeIfPresent(
            [MomentOutgoingOutcome].self,
            forKey: .outgoingOutcomes
        ) ?? []
    }

    static let empty = Self(
        storageRevision: 0,
        changeCursor: nil,
        reportOnlyUntil: nil,
        outbox: [],
        inbox: [],
        savedMemories: [],
        reportOutbox: [],
        outgoingOutcomes: []
    )

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              storageRevision >= 0,
              reportOnlyUntil.map { $0 > Date(timeIntervalSince1970: 0) } ?? true,
              Set(outbox.map(\.id)).count == outbox.count,
              Set(inbox.map(\.id)).count == inbox.count,
              Set(savedMemories.map(\.momentID)).count == savedMemories.count,
              Set(reportOutbox.map(\.id)).count == reportOutbox.count,
              Set(reportOutbox.map(\.momentID)).count == reportOutbox.count,
              outgoingOutcomes.count <= MomentOutgoingOutcome.maximumCount,
              Set(outgoingOutcomes.map(\.id)).count == outgoingOutcomes.count
        else { throw MomentSharingError.stateUnavailable }
        _ = try outbox.map { try $0.validated() }
        _ = try inbox.map { try $0.validated() }
        _ = try savedMemories.map { try $0.validated() }
        let savableMomentIDs = Set(inbox.compactMap { item -> String? in
            guard item.state == .available || item.state == .acknowledged,
                  item.localJPEGFileName != nil
            else { return nil }
            return item.id
        })
        guard savedMemories.allSatisfy({ savableMomentIDs.contains($0.momentID) })
        else { throw MomentSharingError.stateUnavailable }
        _ = try reportOutbox.map { try $0.validated() }
        _ = try outgoingOutcomes.map { try $0.validated() }
        return self
    }

    @discardableResult
    mutating func normalizePersistedDiagnosticErrors() -> Bool {
        var didChange = false
        for index in outbox.indices {
            let normalized = DiagnosticLogPrivacy.normalizedMomentOutboxErrorCode(
                outbox[index].lastErrorCode
            )
            if outbox[index].lastErrorCode != normalized {
                outbox[index].lastErrorCode = normalized
                didChange = true
            }
        }
        return didChange
    }
}

enum MomentSharingStateStore {
    private static let localHistorySeconds: TimeInterval = 90 * 24 * 60 * 60
    private static let maximumPendingOutboxSeconds: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumCommitAmbiguitySeconds: TimeInterval =
        MomentSharingProtocol.commitReplayRetentionSeconds
    private static let maximumPendingReportSeconds: TimeInterval = 24 * 60 * 60
    static let maximumLocalHistoryCount = 500
    private static let maximumLocalHistoryBytes = 256 * 1_024 * 1_024
    private static let maximumPendingOutboxCount = 10
    private static let maximumPendingOutboxBytes = 10 * 1_024 * 1_024
    private static let maximumPendingReportCount = 10
    private static let maximumPendingReportBytes = 10 * 1_024 * 1_024
    private static let completedOutboxMetadataSeconds: TimeInterval = 30 * 24 * 60 * 60
    static let maximumTerminalOutboxMetadataCount = 100
    private static let reportedMetadataSeconds: TimeInterval = 90 * 24 * 60 * 60

    static func load() throws -> MomentSharingState {
        try SharingLifecycleGate.withExclusive {
            try loadWhileLocked()
        }
    }

    static func load(
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> MomentSharingState {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try loadWhileLocked()
        }
    }

    /// Executes one short family-output transaction against the exact state
    /// protected by the installation epoch. The operation must not await or
    /// reacquire `SharingLifecycleGate`.
    static func withStateWhileLifecycleLocked<Value>(
        validating lifecycleToken: SharingLifecycleGate.Token,
        _ operation: (MomentSharingState) throws -> Value
    ) throws -> Value {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try operation(try loadWhileLocked())
        }
    }

    /// Distinguishes durable schema/JSON corruption from a transient file I/O
    /// failure. The coordinator may reset pairing only for bytes that were
    /// read successfully but cannot become a validated sharing state; an I/O
    /// error is rethrown so safety evidence is preserved for a later retry.
    static func isPersistedStateDefinitelyCorrupt(
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> Bool {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard !SharingLifecycleGate.isCleanupRequired,
                  let url = SharedContainer.momentSharingStateURL
            else { throw MomentSharingError.stateUnavailable }
            guard FileManager.default.fileExists(atPath: url.path) else { return false }

            // Keep the read outside the decode catch: permission/protection
            // and other filesystem failures are transient, not proof that the
            // user's retained evidence is malformed.
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                var state = try decoder.decode(MomentSharingState.self, from: data)
                state.normalizePersistedDiagnosticErrors()
                _ = try state.validated()
                return false
            } catch {
                return true
            }
        }
    }

    @discardableResult
    static func mutate(
        validating lifecycleToken: SharingLifecycleGate.Token? = nil,
        _ operation: (inout MomentSharingState) throws -> Void
    ) throws -> MomentSharingState {
        try withLifecycleLock(validating: lifecycleToken) {
            guard !SharingLifecycleGate.isCleanupRequired else {
                throw MomentSharingError.stateUnavailable
            }
            var state = try loadWhileLocked()
            try operation(&state)
            pruneOutgoingOutcomes(&state, now: .now)
            state.storageRevision += 1
            state = try state.validated()
            try writeWhileLocked(state)
            return state
        }
    }

    /// Publishes one already-decrypted and locally moderated JPEG together
    /// with its inbox row under the same installation lifecycle flock. A
    /// terminal local state always wins over a late download, and pruning can
    /// never observe the final file before its state publication finishes.
    static func publishReceivedJPEG(
        _ candidate: MomentInboxItem,
        jpeg: Data,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> MomentInboxItem {
        let candidate = try candidate.validated()
        guard candidate.state == .available || candidate.state == .blocked,
              candidate.localJPEGFileName != nil
        else { throw MomentSharingError.invalidPayload }
        return try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard !SharingLifecycleGate.isCleanupRequired,
                  let directory = SharedContainer.momentSharingReceivedDirectoryURL,
                  let fileName = candidate.localJPEGFileName
            else { throw MomentSharingError.stateUnavailable }
            var state = try loadWhileLocked()
            if let existing = state.inbox.first(where: { $0.id == candidate.id }) {
                guard existing.senderParticipantID == candidate.senderParticipantID,
                      existing.kind == candidate.kind,
                      existing.keyEpoch == candidate.keyEpoch,
                      existing.committedAt == candidate.committedAt
                else { throw MomentSharingError.stateUnavailable }
                // Revocation/block are monotonic safety states. An already
                // acknowledged/available duplicate also needs no rewrite.
                if existing.state == .revoked { return existing }
                guard existing.capturedAt == candidate.capturedAt,
                      existing.captureDateIsMissing == candidate.captureDateIsMissing
                else { throw MomentSharingError.stateUnavailable }
                if existing.state == .blocked || candidate.state == .available {
                    return existing
                }
            }

            let url = directory.appendingPathComponent(fileName, isDirectory: false)
            try SharingSecureFile.write(jpeg, to: url)
            do {
                state.inbox.removeAll { $0.id == candidate.id }
                // A newly blocked classification must win over an older
                // visible copy. Remove its local bookmark in the same state
                // transaction so validation cannot fail after the JPEG has
                // already been replaced on disk.
                if candidate.state == .blocked {
                    state.savedMemories.removeAll { $0.momentID == candidate.id }
                }
                state.inbox.append(candidate)
                state.storageRevision += 1
                try writeWhileLocked(try state.validated())
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return candidate
        }
    }

    /// Applies a delivery revocation monotonically. A tombstone is written
    /// even when the JPEG has not arrived, so an older in-flight download can
    /// never recreate a visible item after this change is durable.
    static func revokeInbox(
        tombstone: MomentInboxItem,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        let tombstone = try tombstone.validated()
        guard tombstone.state == .revoked,
              tombstone.localJPEGFileName == nil
        else { throw MomentSharingError.invalidPayload }
        _ = try mutate(validating: lifecycleToken) { state in
            state.savedMemories.removeAll { $0.momentID == tombstone.id }
            if let index = state.inbox.firstIndex(where: { $0.id == tombstone.id }) {
                guard state.inbox[index].senderParticipantID
                        == tombstone.senderParticipantID,
                      state.inbox[index].kind == tombstone.kind,
                      state.inbox[index].keyEpoch == tombstone.keyEpoch,
                      state.inbox[index].committedAt == tombstone.committedAt
                else { throw MomentSharingError.stateUnavailable }
                // A blocked item retains its hidden local report evidence.
                if state.inbox[index].state != .blocked {
                    state.inbox[index].state = .revoked
                }
            } else {
                state.inbox.append(tombstone)
            }
        }
    }

    /// Adds or removes a local, sharing-scoped bookmark without performing a
    /// network request or writing to Photos/iCloud. The lifecycle flock and
    /// state validation keep the mark atomic with revoke/unlink cleanup.
    static func setSavedMemory(
        momentID: String,
        isSaved: Bool,
        now: Date = .now,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        _ = try mutate(validating: lifecycleToken) { state in
            guard state.reportOnlyUntil == nil else {
                throw MomentSharingError.reportOnly(until: state.reportOnlyUntil!)
            }
            guard let item = state.inbox.first(where: { $0.id == momentID }),
                  item.state == .available || item.state == .acknowledged,
                  let fileName = item.localJPEGFileName,
                  let directory = SharedContainer.momentSharingReceivedDirectoryURL
            else { throw MomentSharingError.stateUnavailable }

            let url = directory.appendingPathComponent(fileName, isDirectory: false)
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize > 0,
                  fileSize <= MomentSharingProtocol.maximumMediaCiphertextBytes - 28
            else { throw MomentSharingError.stateUnavailable }

            state.savedMemories.removeAll { $0.momentID == momentID }
            if isSaved {
                state.savedMemories.append(
                    MomentSavedMemoryRecord(momentID: momentID, savedAt: now)
                )
            }
        }
    }

    /// Records a sender-visible device-arrival receipt for a committed item.
    /// Both relay and client IDs must match the durable outbox row so a stale
    /// or unrelated change cannot relabel another send. The timestamp is the
    /// local observation time because the changes feed deliberately exposes
    /// only the acknowledgement state, not recipient activity metadata.
    @discardableResult
    static func markRecipientDeliveryConfirmed(
        serverMomentID: String,
        clientMomentID: UUID,
        observedAt: Date = .now,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> Bool {
        var changed = false
        _ = try mutate(validating: lifecycleToken) { state in
            guard let index = state.outbox.firstIndex(where: {
                $0.phase == .committed
                    && $0.serverMomentID == serverMomentID
                    && $0.context.clientMomentID == clientMomentID
            }) else { return }
            guard state.outbox[index].recipientDeliveryConfirmedAt == nil else { return }
            let lowerBound = state.outbox[index].committedAt
                ?? state.outbox[index].createdAt
            let confirmedAt = max(observedAt, lowerBound)
            state.outbox[index].recipientDeliveryConfirmedAt = confirmedAt
            state.outbox[index].updatedAt = max(
                state.outbox[index].updatedAt,
                confirmedAt
            )
            changed = true
        }
        return changed
    }

    /// Opaque relay cursors are not orderable. Compare-and-swap prevents a
    /// stale page from moving local progress backward if another coordinator
    /// advanced it first.
    @discardableResult
    static func advanceChangeCursor(
        expected: String?,
        next: String?,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> Bool {
        var advanced = false
        _ = try mutate(validating: lifecycleToken) { state in
            guard state.changeCursor == expected else { return }
            state.changeCursor = next
            advanced = true
        }
        return advanced
    }

    /// Records one terminal local preparation result. The random ledger ID is
    /// intentionally unrelated to the handoff capture ID, so presentation
    /// state cannot be joined back to an image or participant.
    @discardableResult
    static func recordOutgoingOutcome(
        reason: MomentOutgoingOutcomeReason,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> MomentOutgoingOutcome {
        return try withLifecycleLock(validating: lifecycleToken) {
            try recordOutgoingOutcomeWhileLifecycleLocked(reason: reason, now: now)
        }
    }

    /// For a handoff-store terminal cleanup that already owns the lifecycle
    /// flock. Calling the ordinary API from that critical section deadlocks.
    /// The caller must remove plaintext before invoking this method so a
    /// partial cross-file failure always favors deletion over UI history.
    @discardableResult
    static func recordOutgoingOutcomeWhileLifecycleLocked(
        reason: MomentOutgoingOutcomeReason,
        now: Date = .now
    ) throws -> MomentOutgoingOutcome {
        let outcome = try MomentOutgoingOutcome(
            id: UUID(),
            reason: reason,
            createdAt: now,
            expiresAt: now.addingTimeInterval(MomentOutgoingOutcome.retentionSeconds)
        ).validated()
        guard !SharingLifecycleGate.isCleanupRequired else {
            throw MomentSharingError.stateUnavailable
        }
        var state = try loadWhileLocked()
        state.outgoingOutcomes.append(outcome)
        pruneOutgoingOutcomes(&state, now: now)
        state.storageRevision += 1
        try writeWhileLocked(try state.validated())
        return outcome
    }

    static func dismissOutgoingOutcome(
        id: UUID,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        _ = try mutate(validating: lifecycleToken) { state in
            state.outgoingOutcomes.removeAll { $0.id == id }
        }
    }

    static func clearOutgoingOutcomes(
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        _ = try mutate(validating: lifecycleToken) { state in
            state.outgoingOutcomes.removeAll()
        }
    }

    static func enqueue(
        payload: MomentPreparedPayload,
        senderPolicyVersion: Int,
        senderPolicyAcceptedAt: Date,
        validating lifecycleToken: SharingLifecycleGate.Token? = nil,
        now: Date = .now
    ) throws -> MomentOutboxItem {
        return try withLifecycleLock(validating: lifecycleToken) {
            try enqueueWhileLifecycleLocked(
                payload: payload,
                senderPolicyVersion: senderPolicyVersion,
                senderPolicyAcceptedAt: senderPolicyAcceptedAt,
                now: now
            )
        }
    }

    /// Promotes a host-validated Share Extension handoff while the caller
    /// already owns the lifecycle flock through `promoteCapture`. This method
    /// must never be called by the Share Extension or outside that critical
    /// section; acquiring the flock again here would deadlock and separating
    /// the two writes would let a concurrent cancel/revoke race the enqueue.
    static func enqueueWhileLifecycleLocked(
        payload: MomentPreparedPayload,
        senderPolicyVersion: Int,
        senderPolicyAcceptedAt: Date,
        now: Date = .now
    ) throws -> MomentOutboxItem {
        let payload = try payload.validated()
        let item = try MomentOutboxItem(
            id: payload.context.clientMomentID,
            context: payload.context,
            phase: .prepared,
            ciphertextFileName:
                "\(payload.context.clientMomentID.uuidString.lowercased()).ciphertext",
            ciphertextSize: payload.ciphertext.count,
            ciphertextSHA256: payload.ciphertextSHA256,
            moderationVersion: payload.moderationVersion,
            senderPolicyVersion: senderPolicyVersion,
            senderPolicyAcceptedAt: senderPolicyAcceptedAt,
            attemptCount: 0,
            createdAt: now,
            updatedAt: now
        ).validated()
        guard !SharingLifecycleGate.isCleanupRequired,
              let directory = SharedContainer.momentSharingCiphertextDirectoryURL
        else { throw MomentSharingError.stateUnavailable }
        let url = directory.appendingPathComponent(item.ciphertextFileName, isDirectory: false)
        var state = try loadWhileLocked()
        // `reportOnlyUntil` is a persisted terminal gate, not just UI state.
        // Recheck it inside the same lock that validates the handoff claim.
        if let reportOnlyUntil = state.reportOnlyUntil {
            throw MomentSharingError.reportOnly(until: reportOnlyUntil)
        }
        if let existing = state.outbox.first(where: { $0.id == item.id }) {
            guard existing.context == item.context,
                  existing.ciphertextSHA256 == item.ciphertextSHA256,
                  existing.senderPolicyVersion == item.senderPolicyVersion,
                  samePersistedSecond(
                      existing.senderPolicyAcceptedAt,
                      item.senderPolicyAcceptedAt
                  )
            else { throw MomentSharingError.stateUnavailable }
            return existing
        }
        let pending = state.outbox.filter {
            $0.phase == .prepared || $0.phase == .reserved
                || $0.phase == .uploaded || $0.phase == .committing
        }
        let pendingBytes = pending.reduce(0) { partial, value in
            partial + value.ciphertextSize
        }
        guard pending.count < maximumPendingOutboxCount,
              pendingBytes <= maximumPendingOutboxBytes - item.ciphertextSize
        else { throw MomentSharingError.outboxFull }
        try SharingSecureFile.write(payload.ciphertext, to: url)
        do {
            state.outbox.append(item)
            state.storageRevision += 1
            try writeWhileLocked(try state.validated())
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return item
    }

    /// Exact, local-only reconciliation for a crash after an outbox became
    /// durable but before the handoff JPEG was removed. The caller already
    /// holds the lifecycle flock through `promoteCapture`.
    static func existingOutboxWhileLifecycleLocked(
        clientMomentID: UUID,
        clientRequestID: UUID,
        spaceID: String,
        senderParticipantID: String,
        senderDeviceID: String,
        legacySenderDeviceID: String? = nil,
        kind: MomentKind,
        keyEpoch: Int,
        senderPolicyVersion: Int,
        senderPolicyAcceptedAt: Date
    ) throws -> MomentOutboxItem? {
        let state = try loadWhileLocked()
        if let reportOnlyUntil = state.reportOnlyUntil {
            throw MomentSharingError.reportOnly(until: reportOnlyUntil)
        }
        guard let existing = state.outbox.first(where: { $0.id == clientMomentID }) else {
            return nil
        }
        guard existing.context.clientMomentID == clientMomentID,
              existing.context.clientRequestID == clientRequestID,
              existing.context.spaceID == spaceID,
              existing.context.senderParticipantID == senderParticipantID,
              (
                  existing.context.senderDeviceID == senderDeviceID
                      || legacySenderDeviceID.map({
                          existing.context.senderDeviceID == $0
                      }) == true
              ),
              existing.context.kind == kind,
              existing.context.keyEpoch == keyEpoch,
              existing.senderPolicyVersion == senderPolicyVersion,
              samePersistedSecond(
                  existing.senderPolicyAcceptedAt,
                  senderPolicyAcceptedAt
              )
        else { throw MomentSharingError.stateUnavailable }
        if existing.phase != .committed && existing.phase != .failed {
            guard let directory = SharedContainer.momentSharingCiphertextDirectoryURL else {
                throw MomentSharingError.stateUnavailable
            }
            guard let ciphertext = try? Data(
                contentsOf: directory.appendingPathComponent(
                    existing.ciphertextFileName,
                    isDirectory: false
                )
            ), ciphertext.count == existing.ciphertextSize,
                  PairingCrypto.sha256(ciphertext) == existing.ciphertextSHA256
            else { throw MomentSharingError.stateUnavailable }
        }
        return existing
    }

    /// Moment outbox JSON uses Foundation's ISO-8601 strategy, which may
    /// round-trip at whole-second precision, while a binary handoff plist can
    /// retain subsecond precision. IDs/context remain the authority; normalize
    /// only the local consent timestamp so crash reconciliation does not treat
    /// that encoding difference as a different logical send.
    private static func samePersistedSecond(_ lhs: Date, _ rhs: Date) -> Bool {
        Int64(lhs.timeIntervalSince1970.rounded(.down))
            == Int64(rhs.timeIntervalSince1970.rounded(.down))
    }

    static func readCiphertext(for item: MomentOutboxItem) throws -> Data {
        guard let directory = SharedContainer.momentSharingCiphertextDirectoryURL else {
            throw MomentSharingError.stateUnavailable
        }
        let data = try Data(
            contentsOf: directory.appendingPathComponent(item.ciphertextFileName)
        )
        guard data.count == item.ciphertextSize,
              PairingCrypto.sha256(data) == item.ciphertextSHA256
        else { throw MomentSharingError.stateUnavailable }
        return data
    }

    static func enqueueReport(
        momentID: String,
        reason: MomentReportReason,
        prepared: MomentPreparedReport,
        reporterConsentAcceptedAt: Date,
        validating lifecycleToken: SharingLifecycleGate.Token? = nil,
        now: Date = .now
    ) throws -> MomentReportOutboxItem {
        let id = UUID()
        let item = try MomentReportOutboxItem(
            id: id,
            momentID: momentID,
            reason: reason,
            ciphertextFileName: "report-\(id.uuidString.lowercased()).ciphertext",
            ciphertextSize: prepared.ciphertext.count,
            ciphertextSHA256: prepared.ciphertextSHA256,
            moderationKeyID: prepared.moderationKeyID,
            reporterConsentAcceptedAt: reporterConsentAcceptedAt,
            commitRequestID: UUID(),
            phase: .prepared,
            createdAt: now,
            updatedAt: now
        ).validated()
        try withLifecycleLock(validating: lifecycleToken) {
            guard !SharingLifecycleGate.isCleanupRequired,
                  let directory = SharedContainer.momentSharingCiphertextDirectoryURL
            else { throw MomentSharingError.stateUnavailable }
            var state = try loadWhileLocked()
            if let existing = state.reportOutbox.first(where: { $0.momentID == momentID }) {
                guard existing.reason == reason else {
                    throw MomentSharingError.stateUnavailable
                }
                return
            }
            let pendingReports = state.reportOutbox.filter {
                $0.phase == .prepared || $0.phase == .reserved
                    || $0.phase == .uploaded || $0.phase == .committing
            }
            let pendingReportBytes = pendingReports.reduce(0) { partial, value in
                partial + value.ciphertextSize
            }
            guard pendingReports.count < maximumPendingReportCount,
                  pendingReportBytes <= maximumPendingReportBytes - item.ciphertextSize
            else { throw MomentSharingError.outboxFull }
            let url = directory.appendingPathComponent(item.ciphertextFileName)
            try SharingSecureFile.write(prepared.ciphertext, to: url)
            do {
                state.reportOutbox.append(item)
                state.storageRevision += 1
                try writeWhileLocked(try state.validated())
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
        return try load().reportOutbox.first(where: { $0.momentID == momentID }) ?? item
    }

    static func readReportCiphertext(for item: MomentReportOutboxItem) throws -> Data {
        guard let directory = SharedContainer.momentSharingCiphertextDirectoryURL else {
            throw MomentSharingError.stateUnavailable
        }
        let data = try Data(
            contentsOf: directory.appendingPathComponent(item.ciphertextFileName)
        )
        guard data.count == item.ciphertextSize,
              PairingCrypto.sha256(data) == item.ciphertextSHA256
        else { throw MomentSharingError.stateUnavailable }
        return data
    }

    /// A report upload lease may expire while the device is offline. Preserve
    /// the already encrypted evidence and stable client request IDs, but clear
    /// only the expired server reservation so it can be reserved again within
    /// the report-only safety window.
    @discardableResult
    static func recoverExpiredReportReservation(
        itemID: UUID,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> Bool {
        var recovered = false
        _ = try mutate(validating: lifecycleToken) { state in
            guard let index = state.reportOutbox.firstIndex(where: { $0.id == itemID }),
                  state.reportOutbox[index].phase == .reserved
                    || state.reportOutbox[index].phase == .uploaded
                    || state.reportOutbox[index].phase == .committing
            else { return }
            state.reportOutbox[index].phase = .prepared
            state.reportOutbox[index].serverReportID = nil
            state.reportOutbox[index].commitStartedAt = nil
            state.reportOutbox[index].updatedAt = now
            recovered = true
        }
        return recovered
    }

    static func removeReportCiphertext(for item: MomentReportOutboxItem) throws {
        guard let directory = SharedContainer.momentSharingCiphertextDirectoryURL else {
            throw MomentSharingError.stateUnavailable
        }
        let url = directory.appendingPathComponent(item.ciphertextFileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func removeCiphertext(for item: MomentOutboxItem) throws {
        guard let directory = SharedContainer.momentSharingCiphertextDirectoryURL else {
            throw MomentSharingError.stateUnavailable
        }
        let url = directory.appendingPathComponent(item.ciphertextFileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// A reservation is only an upload lease. If it expires, preserve the
    /// exact encrypted object and logical IDs, but discard the Server's old
    /// moment ID so the next sync can reserve a fresh lease idempotently. A
    /// relay `reservation_expired` response after a commit attempt is a
    /// definitive non-commit result because the relay checks idempotent commit
    /// replay before it reports an expired lease.
    @discardableResult
    static func recoverExpiredReservation(
        itemID: UUID,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> Bool {
        var recovered = false
        _ = try mutate(validating: lifecycleToken) { state in
            guard let index = state.outbox.firstIndex(where: { $0.id == itemID }),
                  state.outbox[index].phase == .reserved
                    || state.outbox[index].phase == .uploaded
                    || state.outbox[index].phase == .committing
            else { return }
            state.outbox[index].phase = .prepared
            state.outbox[index].serverMomentID = nil
            state.outbox[index].uploadExpiresAt = nil
            state.outbox[index].commitStartedAt = nil
            state.outbox[index].attemptCount += 1
            state.outbox[index].nextRetryAt = now.addingTimeInterval(30)
            state.outbox[index].lastErrorCode = "reservation-expired"
            state.outbox[index].updatedAt = now
            recovered = true
        }
        return recovered
    }

    /// Stops every normal send as soon as the Server narrows this credential
    /// to the post-revocation reporting window. Received evidence and report
    /// drafts remain available, but unsent family ciphertext is discarded.
    static func enterReportOnlyMode(
        until: Date,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws {
        let discarded = try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try enterReportOnlyModeWhileLifecycleLocked(until: until, now: now)
        }
        for item in discarded {
            try? removeCiphertext(for: item)
        }
    }

    /// Caller already owns the validated lifecycle flock. This is paired with
    /// the handoff report-only marker so the Extension stops before this state
    /// write, while no nested flock acquisition can deadlock the transition.
    static func enterReportOnlyModeWhileLifecycleLocked(
        until: Date,
        now: Date = .now
    ) throws -> [MomentOutboxItem] {
        guard !SharingLifecycleGate.isCleanupRequired else {
            throw MomentSharingError.stateUnavailable
        }
        let boundedUntil = try MomentSharingProtocol.boundedReportOnlyUntil(
            until,
            receivedAt: now
        )
        var state = try loadWhileLocked()
        let localUpperBound = now.addingTimeInterval(
            MomentSharingProtocol.maximumReportOnlyWindowSeconds
                + MomentSharingProtocol.maximumRelayClockSkewSeconds
        )
        state.reportOnlyUntil = min(
            max(state.reportOnlyUntil ?? boundedUntil, boundedUntil),
            localUpperBound
        )
        let discarded = state.outbox.filter {
            $0.phase == .prepared || $0.phase == .reserved
                || $0.phase == .uploaded || $0.phase == .failed
        }
        state.outbox.removeAll {
            $0.phase == .prepared || $0.phase == .reserved
                || $0.phase == .uploaded || $0.phase == .failed
        }
        pruneOutgoingOutcomes(&state, now: now)
        state.storageRevision += 1
        try writeWhileLocked(try state.validated())
        return discarded
    }

    static func markOutboxFailed(
        itemID: UUID,
        code: String,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws {
        var failedItem: MomentOutboxItem?
        _ = try mutate(validating: lifecycleToken) { state in
            guard let index = state.outbox.firstIndex(where: { $0.id == itemID }),
                  state.outbox[index].phase != .committed,
                  state.outbox[index].phase != .committing,
                  state.outbox[index].phase != .deliveryResultUnknown
            else { return }
            state.outbox[index].phase = .failed
            state.outbox[index].nextRetryAt = nil
            state.outbox[index].lastErrorCode =
                DiagnosticLogPrivacy.normalizedMomentOutboxErrorCode(code)
            state.outbox[index].updatedAt = now
            failedItem = state.outbox[index]
        }
        if let failedItem { try? removeCiphertext(for: failedItem) }
    }

    static func discardPendingOutbox(
        destinationKey: String? = nil,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        // Persist the non-sendable state first. If physical cleanup is
        // interrupted, the orphan scan can retry it without resurrecting an
        // uploaded item that the user already cancelled. The optional key is
        // the relay space ID and prevents a future multi-window action from
        // crossing its selected destination.
        var discarded: [MomentOutboxItem] = []
        _ = try mutate(validating: lifecycleToken) { state in
            discarded = state.outbox.filter {
                (destinationKey == nil || $0.context.spaceID == destinationKey)
                    && ($0.phase == .prepared || $0.phase == .reserved
                        || $0.phase == .uploaded)
            }
            state.outbox.removeAll {
                (destinationKey == nil || $0.context.spaceID == destinationKey)
                    && ($0.phase == .prepared || $0.phase == .reserved
                        || $0.phase == .uploaded)
            }
        }
        for item in discarded { try? removeCiphertext(for: item) }
    }

    static func discardFailedOutbox(
        destinationKey: String? = nil,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        var discarded: [MomentOutboxItem] = []
        _ = try mutate(validating: lifecycleToken) { state in
            discarded = state.outbox.filter {
                (destinationKey == nil || $0.context.spaceID == destinationKey)
                    && ($0.phase == .failed || $0.phase == .deliveryResultUnknown)
            }
            state.outbox.removeAll {
                (destinationKey == nil || $0.context.spaceID == destinationKey)
                    && ($0.phase == .failed || $0.phase == .deliveryResultUnknown)
            }
        }
        for item in discarded {
            try? removeCiphertext(for: item)
        }
    }

    /// Keeps local family history bounded independently from Server retention.
    /// The newest 90 days are retained up to 500 photos / 256 MiB. This is a
    /// local cache policy, not a promise that the relay retains photographs.
    static func pruneLocalHistory(now: Date = .now) throws {
        try SharingLifecycleGate.withExclusive {
            try pruneLocalHistoryWhileLocked(now: now)
        }
    }

    private static func pruneLocalHistoryWhileLocked(now: Date) throws {
        guard !SharingLifecycleGate.isCleanupRequired else {
            throw MomentSharingError.stateUnavailable
        }
        var state = try loadWhileLocked()
        let original = state
        let receivedDirectory = SharedContainer.momentSharingReceivedDirectoryURL
        let ciphertextDirectory = SharedContainer.momentSharingCiphertextDirectoryURL
        let historyCutoff = now.addingTimeInterval(-localHistorySeconds)
        let pendingCutoff = now.addingTimeInterval(-maximumPendingOutboxSeconds)
        let commitAmbiguityCutoff = now.addingTimeInterval(
            -maximumCommitAmbiguitySeconds
        )
        let pendingReportCutoff = now.addingTimeInterval(-maximumPendingReportSeconds)
        let outboxMetadataCutoff = now.addingTimeInterval(
            -completedOutboxMetadataSeconds
        )
        let reportMetadataCutoff = now.addingTimeInterval(-reportedMetadataSeconds)
        pruneOutgoingOutcomes(&state, now: now)
        if let reportOnlyUntil = state.reportOnlyUntil {
            let maximumUntil = now.addingTimeInterval(
                MomentSharingProtocol.maximumReportOnlyWindowSeconds
                    + MomentSharingProtocol.maximumRelayClockSkewSeconds
            )
            if reportOnlyUntil > maximumUntil {
                // One-time normalization of pre-boundary or corrupt local
                // state. Subsequent foregrounds cannot slide this fixed
                // deadline forward.
                state.reportOnlyUntil = maximumUntil
            }
        }
        var retainedCount = 0
        var retainedBytes = 0
        var retainedInbox: [MomentInboxItem] = []
        var removedImageNames: [String] = []

            let savedAtByMomentID = Dictionary(
                uniqueKeysWithValues: state.savedMemories.map { ($0.momentID, $0.savedAt) }
            )
            let newestDisplayableMomentID = state.inbox
                .filter { $0.state == .available || $0.state == .acknowledged }
                .max(by: {
                if $0.receivedAt != $1.receivedAt { return $0.receivedAt < $1.receivedAt }
                return $0.id > $1.id
            })?.id
            for item in state.inbox.sorted(by: { first, second in
                if first.id == second.id { return false }
                // Keep the current visible experience without allowing a
                // bookmark to displace hidden report evidence or a revocation
                // tombstone. All groups still obey the absolute age/count/
                // byte limits below.
                if first.id == newestDisplayableMomentID { return true }
                if second.id == newestDisplayableMomentID { return false }
                let firstIsSafetyState = first.state == .blocked || first.state == .revoked
                let secondIsSafetyState = second.state == .blocked || second.state == .revoked
                if firstIsSafetyState != secondIsSafetyState {
                    return firstIsSafetyState
                }
                let firstSavedAt = savedAtByMomentID[first.id]
                let secondSavedAt = savedAtByMomentID[second.id]
                if (firstSavedAt != nil) != (secondSavedAt != nil) {
                    return firstSavedAt != nil
                }
                if let firstSavedAt, let secondSavedAt,
                   firstSavedAt != secondSavedAt {
                    return firstSavedAt > secondSavedAt
                }
                if first.receivedAt != second.receivedAt {
                    return first.receivedAt > second.receivedAt
                }
                return first.id < second.id
            }) {
                let fileBytes: Int
                let fileIsAvailable: Bool
                if let fileName = item.localJPEGFileName,
                   let receivedDirectory {
                    let url = receivedDirectory.appendingPathComponent(fileName)
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                    fileBytes = values?.fileSize ?? 0
                    fileIsAvailable = fileBytes > 0
                } else {
                    fileBytes = 0
                    fileIsAvailable = item.localJPEGFileName == nil
                }
                let fits = fileIsAvailable
                    && item.receivedAt >= historyCutoff
                    && retainedCount < maximumLocalHistoryCount
                    && retainedBytes + fileBytes <= maximumLocalHistoryBytes
                if fits {
                    retainedInbox.append(item)
                    retainedCount += 1
                    retainedBytes += fileBytes
                } else if let fileName = item.localJPEGFileName {
                    removedImageNames.append(fileName)
                }
            }
            state.inbox = retainedInbox
            let retainedMomentIDs = Set(retainedInbox.map(\.id))
            state.savedMemories.removeAll {
                !retainedMomentIDs.contains($0.momentID)
            }

            var expiredPending: [MomentOutboxItem] = []
            for index in state.outbox.indices where
                state.outbox[index].createdAt < pendingCutoff
                    && (state.outbox[index].phase == .prepared
                        || state.outbox[index].phase == .reserved
                        || state.outbox[index].phase == .uploaded) {
                state.outbox[index].phase = .failed
                state.outbox[index].nextRetryAt = nil
                state.outbox[index].lastErrorCode = "pending-expired"
                state.outbox[index].updatedAt = now
                expiredPending.append(state.outbox[index])
            }

            var expiredCommitAmbiguities: [MomentOutboxItem] = []
            for index in state.outbox.indices where
                state.outbox[index].phase == .committing
                    && boundedCommitReplayAnchor(state.outbox[index])
                        < commitAmbiguityCutoff {
                state.outbox[index].phase = .deliveryResultUnknown
                state.outbox[index].nextRetryAt = nil
                state.outbox[index].lastErrorCode = "commit-result-expired"
                state.outbox[index].updatedAt = now
                expiredCommitAmbiguities.append(state.outbox[index])
            }

            var expiredReportCommitAmbiguities: [MomentReportOutboxItem] = []
            for index in state.reportOutbox.indices where
                state.reportOutbox[index].phase == .committing
                    && state.reportOutbox[index].commitStartedAt.map({ startedAt in
                        // The first local commit attempt may not reach the
                        // relay until the one-hour upload lease is nearly
                        // exhausted. Keep the report through that latest
                        // possible acceptance plus the relay's seven-day
                        // report-content reconciliation window.
                        startedAt.addingTimeInterval(
                            MomentSharingProtocol.maximumUploadLeaseSeconds
                                + MomentSharingProtocol.reportContentRetentionSeconds
                                + (2 * MomentSharingProtocol.maximumRelayClockSkewSeconds)
                        ) <= now
                    }) == true {
                state.reportOutbox[index].phase = .deliveryResultUnknown
                state.reportOutbox[index].updatedAt = now
                expiredReportCommitAmbiguities.append(state.reportOutbox[index])
            }

            var removedOutbox = state.outbox.filter {
                ($0.phase == .committed || $0.phase == .failed
                    || $0.phase == .deliveryResultUnknown)
                    && $0.updatedAt < outboxMetadataCutoff
            }
            state.outbox.removeAll {
                ($0.phase == .committed || $0.phase == .failed
                    || $0.phase == .deliveryResultUnknown)
                    && $0.updatedAt < outboxMetadataCutoff
            }
            let terminalOutbox = state.outbox.filter {
                $0.phase == .committed || $0.phase == .failed
                    || $0.phase == .deliveryResultUnknown
            }.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString > $1.id.uuidString
            }
            if terminalOutbox.count > maximumTerminalOutboxMetadataCount {
                let overflow = Array(
                    terminalOutbox.dropFirst(maximumTerminalOutboxMetadataCount)
                )
                let overflowIDs = Set(overflow.map(\.id))
                removedOutbox.append(contentsOf: overflow)
                state.outbox.removeAll { overflowIDs.contains($0.id) }
            }
            let removedReports = state.reportOutbox.filter {
                ($0.phase == .committed || $0.phase == .deliveryResultUnknown)
                    && $0.updatedAt < reportMetadataCutoff
            }
            state.reportOutbox.removeAll {
                ($0.phase == .committed || $0.phase == .deliveryResultUnknown)
                    && $0.updatedAt < reportMetadataCutoff
            }
            let expiredPendingReports = state.reportOutbox.filter {
                ($0.phase == .prepared || $0.phase == .reserved
                    || $0.phase == .uploaded)
                    && $0.createdAt < pendingReportCutoff
            }
            state.reportOutbox.removeAll {
                ($0.phase == .prepared || $0.phase == .reserved
                    || $0.phase == .uploaded)
                    && $0.createdAt < pendingReportCutoff
            }

            if state != original {
                state.storageRevision += 1
                try writeWhileLocked(try state.validated())
            }

            if let receivedDirectory {
                let retainedNames = Set(state.inbox.compactMap(\.localJPEGFileName))
                let names = (try? FileManager.default.contentsOfDirectory(
                    atPath: receivedDirectory.path
                )) ?? removedImageNames
                // This directory is Moment-owned and every live file is
                // represented by `retainedNames`. Remove crash leftovers from
                // SharingSecureFile's pre-rename inode as well as malformed or
                // foreign names; otherwise a final plaintext JPEG can outlive
                // the 90-day cache policy when no later write occurs.
                for name in names where !retainedNames.contains(name) {
                    try? FileManager.default.removeItem(
                        at: receivedDirectory.appendingPathComponent(name)
                    )
                }
            }
            if let ciphertextDirectory {
                var retainedNames = Set<String>()
                for item in state.outbox where
                    item.phase == .prepared || item.phase == .reserved
                        || item.phase == .uploaded || item.phase == .committing {
                    retainedNames.insert(item.ciphertextFileName)
                }
                for item in state.reportOutbox where
                    item.phase == .prepared || item.phase == .reserved
                        || item.phase == .uploaded || item.phase == .committing {
                    retainedNames.insert(item.ciphertextFileName)
                }

                var fallbackNames: [String] = []
                fallbackNames.append(contentsOf: removedOutbox.map(\.ciphertextFileName))
                fallbackNames.append(contentsOf: removedReports.map(\.ciphertextFileName))
                fallbackNames.append(contentsOf: expiredPending.map(\.ciphertextFileName))
                fallbackNames.append(
                    contentsOf: expiredCommitAmbiguities.map(\.ciphertextFileName)
                )
                fallbackNames.append(
                    contentsOf: expiredReportCommitAmbiguities.map(\.ciphertextFileName)
                )
                fallbackNames.append(
                    contentsOf: expiredPendingReports.map(\.ciphertextFileName)
                )
                let names = (try? FileManager.default.contentsOfDirectory(
                    atPath: ciphertextDirectory.path
                )) ?? fallbackNames
                // The ciphertext directory is likewise exclusive to this
                // store. A `.sharing-secure-*` inode left before atomic rename
                // has no state reference and must be bounded by this prune,
                // not by the chance of a future write to the same directory.
                for name in names where !retainedNames.contains(name) {
                    try? FileManager.default.removeItem(
                        at: ciphertextDirectory.appendingPathComponent(name)
                    )
                }
            }
    }

    private static func loadWhileLocked() throws -> MomentSharingState {
        guard let url = SharedContainer.momentSharingStateURL else {
            throw MomentSharingError.stateUnavailable
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        do {
            var state = try AtomicJSON.read(MomentSharingState.self, from: url)
            let didNormalize = state.normalizePersistedDiagnosticErrors()
            state = try state.validated()
            if didNormalize { try writeWhileLocked(state) }
            return state
        } catch {
            throw MomentSharingError.stateUnavailable
        }
    }

    private static func pruneOutgoingOutcomes(
        _ state: inout MomentSharingState,
        now: Date
    ) {
        state.outgoingOutcomes.removeAll { $0.expiresAt <= now }
        if state.outgoingOutcomes.count > MomentOutgoingOutcome.maximumCount {
            state.outgoingOutcomes = Array(
                state.outgoingOutcomes.sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                    return $0.id.uuidString > $1.id.uuidString
                }.prefix(MomentOutgoingOutcome.maximumCount)
            )
        }
    }

    /// Server expiry dates are useful only within the signed protocol lease.
    /// Bound even a malformed/corrupt persisted value by a local commit-time
    /// anchor so ciphertext cannot be retained indefinitely by a far-future
    /// relay timestamp. `updatedAt` is the legacy fallback because entering
    /// `.committing` durably updated it before `commitStartedAt` existed.
    private static func boundedCommitReplayAnchor(
        _ item: MomentOutboxItem
    ) -> Date {
        let localCommitAt = item.commitStartedAt ?? item.updatedAt
        let maximumLeaseAnchor = localCommitAt.addingTimeInterval(
            MomentSharingProtocol.maximumUploadLeaseSeconds
                + MomentSharingProtocol.maximumRelayClockSkewSeconds
        )
        let boundedRelayExpiry = min(
            item.uploadExpiresAt ?? localCommitAt,
            maximumLeaseAnchor
        )
        return max(localCommitAt, boundedRelayExpiry)
    }

    private static func writeWhileLocked(_ state: MomentSharingState) throws {
        guard let url = SharedContainer.momentSharingStateURL else {
            throw MomentSharingError.stateUnavailable
        }
        var state = state
        state.normalizePersistedDiagnosticErrors()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try SharingSecureFile.write(try encoder.encode(try state.validated()), to: url)
    }

    private static func withLifecycleLock<Value>(
        validating lifecycleToken: SharingLifecycleGate.Token?,
        operation: () throws -> Value
    ) throws -> Value {
        if let lifecycleToken {
            return try SharingLifecycleGate.withValidatedToken(
                lifecycleToken,
                operation: operation
            )
        }
        return try SharingLifecycleGate.withExclusive(operation)
    }
}
