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
              createdAt <= updatedAt,
              serverMomentID.map(Self.isOpaqueIdentifier) ?? true,
              phase == .prepared || phase == .failed || serverMomentID != nil
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

struct MomentSharingState: Codable, Equatable, Sendable {
    static let schemaVersion = 3
    var schemaVersion: Int = Self.schemaVersion
    var storageRevision: Int
    var changeCursor: String?
    var reportOnlyUntil: Date?
    var outbox: [MomentOutboxItem]
    var inbox: [MomentInboxItem]
    var reportOutbox: [MomentReportOutboxItem]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case storageRevision
        case changeCursor
        case reportOnlyUntil
        case outbox
        case inbox
        case reportOutbox
    }

    init(
        storageRevision: Int,
        changeCursor: String?,
        reportOnlyUntil: Date? = nil,
        outbox: [MomentOutboxItem],
        inbox: [MomentInboxItem],
        reportOutbox: [MomentReportOutboxItem]
    ) {
        self.storageRevision = storageRevision
        self.changeCursor = changeCursor
        self.reportOnlyUntil = reportOnlyUntil
        self.outbox = outbox
        self.inbox = inbox
        self.reportOutbox = reportOutbox
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
        outbox = try container.decode([MomentOutboxItem].self, forKey: .outbox)
        inbox = try container.decode([MomentInboxItem].self, forKey: .inbox)
        reportOutbox = try container.decodeIfPresent(
            [MomentReportOutboxItem].self,
            forKey: .reportOutbox
        ) ?? []
    }

    static let empty = Self(
        storageRevision: 0,
        changeCursor: nil,
        reportOnlyUntil: nil,
        outbox: [],
        inbox: [],
        reportOutbox: []
    )

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              storageRevision >= 0,
              reportOnlyUntil.map { $0 > Date(timeIntervalSince1970: 0) } ?? true,
              Set(outbox.map(\.id)).count == outbox.count,
              Set(inbox.map(\.id)).count == inbox.count,
              Set(reportOutbox.map(\.id)).count == reportOutbox.count,
              Set(reportOutbox.map(\.momentID)).count == reportOutbox.count
        else { throw MomentSharingError.stateUnavailable }
        _ = try outbox.map { try $0.validated() }
        _ = try inbox.map { try $0.validated() }
        _ = try reportOutbox.map { try $0.validated() }
        return self
    }
}

enum MomentSharingStateStore {
    private static let localHistorySeconds: TimeInterval = 90 * 24 * 60 * 60
    private static let maximumPendingOutboxSeconds: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumPendingReportSeconds: TimeInterval = 24 * 60 * 60
    private static let maximumLocalHistoryCount = 500
    private static let maximumLocalHistoryBytes = 256 * 1_024 * 1_024
    private static let maximumPendingOutboxCount = 10
    private static let maximumPendingOutboxBytes = 10 * 1_024 * 1_024
    private static let maximumPendingReportCount = 10
    private static let maximumPendingReportBytes = 10 * 1_024 * 1_024
    private static let completedOutboxMetadataSeconds: TimeInterval = 30 * 24 * 60 * 60
    private static let reportedMetadataSeconds: TimeInterval = 90 * 24 * 60 * 60

    static func load() throws -> MomentSharingState {
        try SharingLifecycleGate.withExclusive {
            try loadWhileLocked()
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
            state.storageRevision += 1
            state = try state.validated()
            try writeWhileLocked(state)
            return state
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
              existing.context.senderDeviceID == senderDeviceID,
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
            let pendingReports = state.reportOutbox.filter { $0.phase != .committed }
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
    /// moment ID so the next sync can reserve a fresh lease idempotently.
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
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        var discarded: [MomentOutboxItem] = []
        _ = try mutate(validating: lifecycleToken) { state in
            state.reportOnlyUntil = max(state.reportOnlyUntil ?? until, until)
            discarded = state.outbox.filter {
                $0.phase == .prepared || $0.phase == .reserved
                    || $0.phase == .uploaded || $0.phase == .failed
            }
            state.outbox.removeAll {
                $0.phase == .prepared || $0.phase == .reserved
                    || $0.phase == .uploaded || $0.phase == .failed
            }
        }
        for item in discarded {
            try? removeCiphertext(for: item)
        }
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
                  state.outbox[index].phase != .committed
            else { return }
            state.outbox[index].phase = .failed
            state.outbox[index].nextRetryAt = nil
            state.outbox[index].lastErrorCode = String(code.prefix(64))
            state.outbox[index].updatedAt = now
            failedItem = state.outbox[index]
        }
        if let failedItem { try? removeCiphertext(for: failedItem) }
    }

    static func discardPendingOutbox(
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        var discarded: [MomentOutboxItem] = []
        _ = try mutate(validating: lifecycleToken) { state in
            discarded = state.outbox.filter {
                $0.phase == .prepared || $0.phase == .reserved || $0.phase == .uploaded
            }
            state.outbox.removeAll {
                $0.phase == .prepared || $0.phase == .reserved || $0.phase == .uploaded
            }
        }
        for item in discarded { try? removeCiphertext(for: item) }
    }

    static func discardFailedOutbox(
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        var discarded: [MomentOutboxItem] = []
        _ = try mutate(validating: lifecycleToken) { state in
            discarded = state.outbox.filter { $0.phase == .failed }
            state.outbox.removeAll { $0.phase == .failed }
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
            guard !SharingLifecycleGate.isCleanupRequired else {
                throw MomentSharingError.stateUnavailable
            }
            var state = try loadWhileLocked()
            let original = state
            let receivedDirectory = SharedContainer.momentSharingReceivedDirectoryURL
            let ciphertextDirectory = SharedContainer.momentSharingCiphertextDirectoryURL
            let historyCutoff = now.addingTimeInterval(-localHistorySeconds)
            let pendingCutoff = now.addingTimeInterval(-maximumPendingOutboxSeconds)
            let pendingReportCutoff = now.addingTimeInterval(-maximumPendingReportSeconds)
            let outboxMetadataCutoff = now.addingTimeInterval(
                -completedOutboxMetadataSeconds
            )
            let reportMetadataCutoff = now.addingTimeInterval(-reportedMetadataSeconds)
            var retainedCount = 0
            var retainedBytes = 0
            var retainedInbox: [MomentInboxItem] = []
            var removedImageNames: [String] = []

            for item in state.inbox.sorted(by: {
                if $0.receivedAt != $1.receivedAt { return $0.receivedAt > $1.receivedAt }
                return $0.id < $1.id
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

            let removedOutbox = state.outbox.filter {
                $0.phase == .committed && $0.updatedAt < outboxMetadataCutoff
            }
            state.outbox.removeAll {
                $0.phase == .committed && $0.updatedAt < outboxMetadataCutoff
            }
            let removedReports = state.reportOutbox.filter {
                $0.phase == .committed && $0.updatedAt < reportMetadataCutoff
            }
            state.reportOutbox.removeAll {
                $0.phase == .committed && $0.updatedAt < reportMetadataCutoff
            }
            let expiredPendingReports = state.reportOutbox.filter {
                $0.phase != .committed && $0.phase != .committing
                    && $0.createdAt < pendingReportCutoff
            }
            state.reportOutbox.removeAll {
                $0.phase != .committed && $0.phase != .committing
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
                for name in names where name.hasSuffix(".jpg") && !retainedNames.contains(name) {
                    try? FileManager.default.removeItem(
                        at: receivedDirectory.appendingPathComponent(name)
                    )
                }
            }
            if let ciphertextDirectory {
                let retainedNames = Set(
                    state.outbox.filter {
                        $0.phase == .prepared || $0.phase == .reserved
                            || $0.phase == .uploaded || $0.phase == .committing
                    }.map(\.ciphertextFileName)
                        + state.reportOutbox.filter {
                            $0.phase != .committed
                        }.map(\.ciphertextFileName)
                )
                let names = (try? FileManager.default.contentsOfDirectory(
                    atPath: ciphertextDirectory.path
                )) ?? (
                    removedOutbox.map(\.ciphertextFileName)
                        + removedReports.map(\.ciphertextFileName)
                        + expiredPending.map(\.ciphertextFileName)
                        + expiredPendingReports.map(\.ciphertextFileName)
                )
                for name in names
                where name.hasSuffix(".ciphertext") && !retainedNames.contains(name) {
                    try? FileManager.default.removeItem(
                        at: ciphertextDirectory.appendingPathComponent(name)
                    )
                }
            }
        }
    }

    private static func loadWhileLocked() throws -> MomentSharingState {
        guard let url = SharedContainer.momentSharingStateURL else {
            throw MomentSharingError.stateUnavailable
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        do {
            return try AtomicJSON.read(MomentSharingState.self, from: url).validated()
        } catch {
            throw MomentSharingError.stateUnavailable
        }
    }

    private static func writeWhileLocked(_ state: MomentSharingState) throws {
        guard let url = SharedContainer.momentSharingStateURL else {
            throw MomentSharingError.stateUnavailable
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try SharingSecureFile.write(try encoder.encode(state), to: url)
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
