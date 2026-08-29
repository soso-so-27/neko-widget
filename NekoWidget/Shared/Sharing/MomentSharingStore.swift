import Foundation
import ImageIO

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
    /// Opaque basename for a protected sender-side preview. The bytes live in
    /// a dedicated local directory, never in this frequently rewritten state
    /// document and never in a relay request.
    var localThumbnailFileName: String? = nil
    /// Decode-only compatibility for the short-lived Build 92 inline format.
    /// `encode(to:)` deliberately omits it; `loadWhileLocked()` migrates it to
    /// the protected file before returning state to callers.
    var legacyInlineLocalThumbnailJPEG: Data? = nil

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case context
        case phase
        case ciphertextFileName
        case ciphertextSize
        case ciphertextSHA256
        case moderationVersion
        case senderPolicyVersion
        case senderPolicyAcceptedAt
        case serverMomentID
        case uploadExpiresAt
        case attemptCount
        case nextRetryAt
        case lastErrorCode
        case commitStartedAt
        case committedAt
        case unreceivedExpiresAt
        case recipientCount
        case recipientDeliveryConfirmedAt
        case createdAt
        case updatedAt
        case localThumbnailFileName
        case localThumbnailJPEG
    }

    init(
        schemaVersion: Int = Self.schemaVersion,
        id: UUID,
        context: MomentRequestContext,
        phase: MomentOutboxPhase,
        ciphertextFileName: String,
        ciphertextSize: Int,
        ciphertextSHA256: Data,
        moderationVersion: Int,
        senderPolicyVersion: Int,
        senderPolicyAcceptedAt: Date,
        serverMomentID: String? = nil,
        uploadExpiresAt: Date? = nil,
        attemptCount: Int,
        nextRetryAt: Date? = nil,
        lastErrorCode: String? = nil,
        commitStartedAt: Date? = nil,
        committedAt: Date? = nil,
        unreceivedExpiresAt: Date? = nil,
        recipientCount: Int? = nil,
        recipientDeliveryConfirmedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date,
        localThumbnailFileName: String? = nil,
        legacyInlineLocalThumbnailJPEG: Data? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.context = context
        self.phase = phase
        self.ciphertextFileName = ciphertextFileName
        self.ciphertextSize = ciphertextSize
        self.ciphertextSHA256 = ciphertextSHA256
        self.moderationVersion = moderationVersion
        self.senderPolicyVersion = senderPolicyVersion
        self.senderPolicyAcceptedAt = senderPolicyAcceptedAt
        self.serverMomentID = serverMomentID
        self.uploadExpiresAt = uploadExpiresAt
        self.attemptCount = attemptCount
        self.nextRetryAt = nextRetryAt
        self.lastErrorCode = lastErrorCode
        self.commitStartedAt = commitStartedAt
        self.committedAt = committedAt
        self.unreceivedExpiresAt = unreceivedExpiresAt
        self.recipientCount = recipientCount
        self.recipientDeliveryConfirmedAt = recipientDeliveryConfirmedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.localThumbnailFileName = localThumbnailFileName
        self.legacyInlineLocalThumbnailJPEG = legacyInlineLocalThumbnailJPEG
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(UUID.self, forKey: .id)
        context = try container.decode(MomentRequestContext.self, forKey: .context)
        phase = try container.decode(MomentOutboxPhase.self, forKey: .phase)
        ciphertextFileName = try container.decode(String.self, forKey: .ciphertextFileName)
        ciphertextSize = try container.decode(Int.self, forKey: .ciphertextSize)
        ciphertextSHA256 = try container.decode(Data.self, forKey: .ciphertextSHA256)
        moderationVersion = try container.decode(Int.self, forKey: .moderationVersion)
        senderPolicyVersion = try container.decode(Int.self, forKey: .senderPolicyVersion)
        senderPolicyAcceptedAt = try container.decode(
            Date.self,
            forKey: .senderPolicyAcceptedAt
        )
        serverMomentID = try container.decodeIfPresent(String.self, forKey: .serverMomentID)
        uploadExpiresAt = try container.decodeIfPresent(Date.self, forKey: .uploadExpiresAt)
        attemptCount = try container.decode(Int.self, forKey: .attemptCount)
        nextRetryAt = try container.decodeIfPresent(Date.self, forKey: .nextRetryAt)
        lastErrorCode = try container.decodeIfPresent(String.self, forKey: .lastErrorCode)
        commitStartedAt = try container.decodeIfPresent(Date.self, forKey: .commitStartedAt)
        committedAt = try container.decodeIfPresent(Date.self, forKey: .committedAt)
        unreceivedExpiresAt = try container.decodeIfPresent(
            Date.self,
            forKey: .unreceivedExpiresAt
        )
        recipientCount = try container.decodeIfPresent(Int.self, forKey: .recipientCount)
        recipientDeliveryConfirmedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .recipientDeliveryConfirmedAt
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        localThumbnailFileName = try container.decodeIfPresent(
            String.self,
            forKey: .localThumbnailFileName
        )
        legacyInlineLocalThumbnailJPEG = try container.decodeIfPresent(
            Data.self,
            forKey: .localThumbnailJPEG
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(context, forKey: .context)
        try container.encode(phase, forKey: .phase)
        try container.encode(ciphertextFileName, forKey: .ciphertextFileName)
        try container.encode(ciphertextSize, forKey: .ciphertextSize)
        try container.encode(ciphertextSHA256, forKey: .ciphertextSHA256)
        try container.encode(moderationVersion, forKey: .moderationVersion)
        try container.encode(senderPolicyVersion, forKey: .senderPolicyVersion)
        try container.encode(senderPolicyAcceptedAt, forKey: .senderPolicyAcceptedAt)
        try container.encodeIfPresent(serverMomentID, forKey: .serverMomentID)
        try container.encodeIfPresent(uploadExpiresAt, forKey: .uploadExpiresAt)
        try container.encode(attemptCount, forKey: .attemptCount)
        try container.encodeIfPresent(nextRetryAt, forKey: .nextRetryAt)
        try container.encodeIfPresent(lastErrorCode, forKey: .lastErrorCode)
        try container.encodeIfPresent(commitStartedAt, forKey: .commitStartedAt)
        try container.encodeIfPresent(committedAt, forKey: .committedAt)
        try container.encodeIfPresent(unreceivedExpiresAt, forKey: .unreceivedExpiresAt)
        try container.encodeIfPresent(recipientCount, forKey: .recipientCount)
        try container.encodeIfPresent(
            recipientDeliveryConfirmedAt,
            forKey: .recipientDeliveryConfirmedAt
        )
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(localThumbnailFileName, forKey: .localThumbnailFileName)
        // Never re-encode legacyInlineLocalThumbnailJPEG.
    }

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
              localThumbnailFileName.map {
                  $0 == Self.localThumbnailFileName(for: id)
              } ?? true,
              legacyInlineLocalThumbnailJPEG.map(Self.isValidLocalThumbnail) ?? true,
              localThumbnailFileName == nil || legacyInlineLocalThumbnailJPEG == nil,
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

    static let maximumLocalThumbnailBytes = 64 * 1_024
    static let maximumLocalThumbnailPixelDimension = 512

    static func localThumbnailFileName(for id: UUID) -> String {
        "sent-thumbnail-\(id.uuidString.lowercased()).jpg"
    }

    static func isValidLocalThumbnail(_ data: Data) -> Bool {
        guard (4...maximumLocalThumbnailBytes).contains(data.count),
              data.starts(with: [UInt8(0xff), 0xd8, 0xff]),
              data.suffix(2).elementsEqual([UInt8(0xff), 0xd9])
        else { return false }

        // JPEG entropy bytes escape 0xff, so the first EOI marker must also
        // be the final two bytes. This rejects concatenated images/trailers
        // before asking ImageIO to validate the single complete image.
        let bytes = [UInt8](data)
        guard let firstEndMarker = (2..<(bytes.count - 1)).first(where: {
            bytes[$0] == 0xff && bytes[$0 + 1] == 0xd9
        }), firstEndMarker == bytes.count - 2,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let type = CGImageSourceGetType(source),
              (type as String) == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
              ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?
                .intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?
                .intValue,
              (1...maximumLocalThumbnailPixelDimension).contains(width),
              (1...maximumLocalThumbnailPixelDimension).contains(height)
        else { return false }
        return true
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
    // Persist only reports prepared for an explicitly reviewed key ID.
    private static let reviewedModerationKeyIDs: Set<String> = [
        "moderation-v1",
        "moderation-v2"
    ]

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
              Self.reviewedModerationKeyIDs.contains(moderationKeyID),
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

struct MomentSavedMemoryMutation: Equatable, Sendable {
    let previousIsSaved: Bool
    let isSaved: Bool
}

/// A durable, idempotency mapping for a received photo that the person
/// explicitly imported into Photos and the app's ordinary "思い出" collection.
/// The Photos local identifier never leaves this installation and is never
/// sent to the relay. Keeping the mapping separate from the legacy 90-day
/// bookmark prevents a retry from creating another Photos asset.
struct MomentImportedMemoryRecord: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    let momentID: String
    let photoLocalIdentifier: String
    let importedAt: Date

    var id: String { momentID }

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              Self.isOpaqueIdentifier(momentID),
              (1...1_024).contains(photoLocalIdentifier.utf8.count),
              !photoLocalIdentifier.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              importedAt > Date(timeIntervalSince1970: 0)
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

/// Crash-safe journal written before the irreversible PhotoKit change. The
/// opaque token is used only as the imported resource filename so a retry can
/// recover the exact asset instead of creating a duplicate.
struct MomentPendingMemoryImportRecord: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    let momentID: String
    let importToken: UUID
    let startedAt: Date

    var id: String { momentID }

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              Self.isOpaqueIdentifier(momentID),
              startedAt > Date(timeIntervalSince1970: 0)
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

struct MomentMemoryImportPreparation: Sendable {
    let record: MomentPendingMemoryImportRecord
    let wasAlreadyPending: Bool
}

/// One fail-closed snapshot for the two interactive controls shown over a
/// received-photo Widget. The private memory mark and the outbound reaction
/// remain separate even though both resolve the same currently published
/// moment.
struct MomentFamilyWidgetInteractionState: Equatable, Sendable {
    let isSavedMemory: Bool
    let pawPhase: MomentPawOutboxPhase?
    let canQueuePaw: Bool
}

struct MomentPhotoLibraryCopyPayload: Sendable {
    let jpegData: Data
    let capturedAt: Date?
}

enum MomentPawOutboxPhase: String, Codable, Sendable {
    case pending
    case committing
    case sent
}

/// One explicit, fixed reaction queued by the recipient. It contains no text,
/// image, participant identifier, or file path. The stable client request ID
/// makes an ambiguous network result safe to retry.
struct MomentPawOutboxItem: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    let clientRequestID: UUID
    let momentID: String
    var phase: MomentPawOutboxPhase
    var serverReactionID: String?
    let createdAt: Date
    var updatedAt: Date

    var id: UUID { clientRequestID }

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              Self.isOpaqueIdentifier(momentID),
              createdAt > Date(timeIntervalSince1970: 0),
              updatedAt >= createdAt,
              (phase == .sent) == (serverReactionID != nil),
              serverReactionID.map(Self.isOpaqueIdentifier) ?? true
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

/// A sender-side receipt from the dedicated reaction feed. `observedAt` is
/// local observation time; the recipient's exact activity time is not kept.
struct MomentPawReceipt: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    let reactionID: String
    let momentID: String
    let observedAt: Date

    var id: String { reactionID }

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              Self.isOpaqueIdentifier(reactionID),
              Self.isOpaqueIdentifier(momentID),
              observedAt > Date(timeIntervalSince1970: 0)
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
    static let schemaVersion = 9
    var schemaVersion: Int = Self.schemaVersion
    var storageRevision: Int
    var changeCursor: String?
    var reactionCursor: String?
    var reportOnlyUntil: Date?
    var outbox: [MomentOutboxItem]
    var inbox: [MomentInboxItem]
    var savedMemories: [MomentSavedMemoryRecord]
    var importedMemories: [MomentImportedMemoryRecord]
    var pendingMemoryImports: [MomentPendingMemoryImportRecord]
    var pawOutbox: [MomentPawOutboxItem]
    var receivedPaws: [MomentPawReceipt]
    var reportOutbox: [MomentReportOutboxItem]
    var outgoingOutcomes: [MomentOutgoingOutcome]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case storageRevision
        case changeCursor
        case reactionCursor
        case reportOnlyUntil
        case outbox
        case inbox
        case savedMemories
        case importedMemories
        case pendingMemoryImports
        case pawOutbox
        case receivedPaws
        case reportOutbox
        case outgoingOutcomes
    }

    init(
        storageRevision: Int,
        changeCursor: String?,
        reactionCursor: String? = nil,
        reportOnlyUntil: Date? = nil,
        outbox: [MomentOutboxItem],
        inbox: [MomentInboxItem],
        savedMemories: [MomentSavedMemoryRecord] = [],
        importedMemories: [MomentImportedMemoryRecord] = [],
        pendingMemoryImports: [MomentPendingMemoryImportRecord] = [],
        pawOutbox: [MomentPawOutboxItem] = [],
        receivedPaws: [MomentPawReceipt] = [],
        reportOutbox: [MomentReportOutboxItem],
        outgoingOutcomes: [MomentOutgoingOutcome] = []
    ) {
        self.storageRevision = storageRevision
        self.changeCursor = changeCursor
        self.reactionCursor = reactionCursor
        self.reportOnlyUntil = reportOnlyUntil
        self.outbox = outbox
        self.inbox = inbox
        self.savedMemories = savedMemories
        self.importedMemories = importedMemories
        self.pendingMemoryImports = pendingMemoryImports
        self.pawOutbox = pawOutbox
        self.receivedPaws = receivedPaws
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
        reactionCursor = try container.decodeIfPresent(
            String.self,
            forKey: .reactionCursor
        )
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
        importedMemories = try container.decodeIfPresent(
            [MomentImportedMemoryRecord].self,
            forKey: .importedMemories
        ) ?? []
        pendingMemoryImports = try container.decodeIfPresent(
            [MomentPendingMemoryImportRecord].self,
            forKey: .pendingMemoryImports
        ) ?? []
        pawOutbox = try container.decodeIfPresent(
            [MomentPawOutboxItem].self,
            forKey: .pawOutbox
        ) ?? []
        receivedPaws = try container.decodeIfPresent(
            [MomentPawReceipt].self,
            forKey: .receivedPaws
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
        reactionCursor: nil,
        reportOnlyUntil: nil,
        outbox: [],
        inbox: [],
        savedMemories: [],
        importedMemories: [],
        pendingMemoryImports: [],
        pawOutbox: [],
        receivedPaws: [],
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
              Set(importedMemories.map(\.momentID)).count == importedMemories.count,
              Set(importedMemories.map(\.photoLocalIdentifier)).count
                == importedMemories.count,
              pendingMemoryImports.count <= 10,
              Set(pendingMemoryImports.map(\.momentID)).count
                == pendingMemoryImports.count,
              Set(pendingMemoryImports.map(\.importToken)).count
                == pendingMemoryImports.count,
              Set(importedMemories.map(\.momentID)).isDisjoint(
                with: Set(pendingMemoryImports.map(\.momentID))
              ),
              pawOutbox.count <= MomentSharingStateStore.maximumReactionHistoryCount,
              Set(pawOutbox.map(\.clientRequestID)).count == pawOutbox.count,
              Set(pawOutbox.map(\.momentID)).count == pawOutbox.count,
              receivedPaws.count <= MomentSharingStateStore.maximumReactionHistoryCount,
              Set(receivedPaws.map(\.reactionID)).count == receivedPaws.count,
              Set(receivedPaws.map(\.momentID)).count == receivedPaws.count,
              Set(reportOutbox.map(\.id)).count == reportOutbox.count,
              Set(reportOutbox.map(\.momentID)).count == reportOutbox.count,
              outgoingOutcomes.count <= MomentOutgoingOutcome.maximumCount,
              Set(outgoingOutcomes.map(\.id)).count == outgoingOutcomes.count
        else { throw MomentSharingError.stateUnavailable }
        _ = try outbox.map { try $0.validated() }
        _ = try inbox.map { try $0.validated() }
        _ = try savedMemories.map { try $0.validated() }
        _ = try importedMemories.map { try $0.validated() }
        _ = try pendingMemoryImports.map { try $0.validated() }
        _ = try pawOutbox.map { try $0.validated() }
        _ = try receivedPaws.map { try $0.validated() }
        let savableMomentIDs = Set(inbox.compactMap { item -> String? in
            guard item.state == .available || item.state == .acknowledged,
                  item.localJPEGFileName != nil
            else { return nil }
            return item.id
        })
        guard savedMemories.allSatisfy({ savableMomentIDs.contains($0.momentID) })
        else { throw MomentSharingError.stateUnavailable }
        guard importedMemories.allSatisfy({ savableMomentIDs.contains($0.momentID) })
        else { throw MomentSharingError.stateUnavailable }
        guard pendingMemoryImports.allSatisfy({
            savableMomentIDs.contains($0.momentID)
        }) else { throw MomentSharingError.stateUnavailable }
        guard pawOutbox.allSatisfy({ savableMomentIDs.contains($0.momentID) })
        else { throw MomentSharingError.stateUnavailable }
        let sentMomentIDs = Set(outbox.compactMap { item in
            item.phase == .committed ? item.serverMomentID : nil
        })
        guard receivedPaws.allSatisfy({ sentMomentIDs.contains($0.momentID) })
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
    /// Five received photos per day can each receive one heart throughout the
    /// 30-day relay access window (150 records). Keep a bounded margin so the
    /// oldest still-live photo never loses its per-photo heart association.
    static let maximumReactionHistoryCount = 200
    private static let maximumLocalHistoryBytes = 256 * 1_024 * 1_024
    private static let maximumPendingOutboxCount = 10
    private static let maximumPendingOutboxBytes = 10 * 1_024 * 1_024
    private static let maximumPendingReportCount = 10
    private static let maximumPendingReportBytes = 10 * 1_024 * 1_024
    private static let completedOutboxMetadataSeconds: TimeInterval = 30 * 24 * 60 * 60
    /// Five photos per day over the 30-day delivery/heart window need 150
    /// stable sent records. A bounded margin keeps every still-live photo's
    /// delivery and heart status addressable without unbounded local growth.
    static let maximumTerminalOutboxMetadataCount = 200
    private static let reportedMetadataSeconds: TimeInterval = 90 * 24 * 60 * 60

    static func load() throws -> MomentSharingState {
        try SharingLifecycleGate.withExclusive {
            try loadWhileLocked()
        }
    }

    /// Read-only lookup for admission publication across every local window.
    /// It never changes the catalog's active entry and therefore cannot make
    /// an inactive room's outbox/inbox become the process-wide store.
    static func load(localWindowID: String) throws -> MomentSharingState {
        try SharingLifecycleGate.withExclusive {
            guard let catalog = try PrivateWindowCatalogStore.load(),
                  catalog.windows.contains(where: {
                      $0.localWindowID == localWindowID
                  }),
                  let sharing = SharedContainer.windowSharingDirectoryURL(
                      localWindowID: localWindowID
                  )
            else { throw MomentSharingError.stateUnavailable }
            let url = sharing.appendingPathComponent(
                "moment-sharing-state.v1.json",
                isDirectory: false
            )
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .empty
            }
            do {
                var state = try AtomicJSON.read(MomentSharingState.self, from: url)
                state.normalizePersistedDiagnosticErrors()
                return try state.validated()
            } catch {
                throw MomentSharingError.stateUnavailable
            }
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
                    state.importedMemories.removeAll { $0.momentID == candidate.id }
                    state.pendingMemoryImports.removeAll {
                        $0.momentID == candidate.id
                    }
                    state.pawOutbox.removeAll { $0.momentID == candidate.id }
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
            state.importedMemories.removeAll { $0.momentID == tombstone.id }
            state.pendingMemoryImports.removeAll {
                $0.momentID == tombstone.id
            }
            state.pawOutbox.removeAll { $0.momentID == tombstone.id }
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
            try validateSavedMemoryTarget(momentID: momentID, in: state)
            state.savedMemories.removeAll { $0.momentID == momentID }
            if isSaved {
                state.savedMemories.append(
                    MomentSavedMemoryRecord(momentID: momentID, savedAt: now)
                )
            }
        }
    }

    /// Reads the canonical local bookmark while applying the same lifecycle,
    /// visible-state, and file checks as a mutation. Widget entries hide their
    /// interactive button when this check cannot complete safely.
    static func savedMemoryState(
        momentID: String,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> Bool {
        try withStateWhileLifecycleLocked(validating: lifecycleToken) { state in
            try validateSavedMemoryTarget(momentID: momentID, in: state)
            return state.savedMemories.contains { $0.momentID == momentID }
        }
    }

    /// Reads both received-photo Widget actions from one lifecycle-protected
    /// state snapshot. A reaction already queued remains visible after its
    /// access deadline, while a new reaction is never offered after expiry.
    static func familyWidgetInteractionState(
        momentID: String,
        now: Date = .now,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> MomentFamilyWidgetInteractionState {
        let snapshot = try withStateWhileLifecycleLocked(validating: lifecycleToken) { state in
            try validateSavedMemoryTarget(momentID: momentID, in: state)
            guard let item = state.inbox.first(where: { $0.id == momentID })
            else { throw MomentSharingError.stateUnavailable }
            let paw = state.pawOutbox.first { $0.momentID == momentID }
            return (
                photoLocalIdentifier: state.importedMemories.first {
                    $0.momentID == momentID
                }?.photoLocalIdentifier,
                pawPhase: paw?.phase,
                canQueuePaw: paw == nil && now < item.accessExpiresAt
            )
        }
        // Never nest the sharing lifecycle lock and the ordinary-like store
        // lock. Apart from avoiding lock-order coupling, this keeps the Photos
        // identifier local to the extension process and out of the relay state.
        let isInPersonalMemories = try snapshot.photoLocalIdentifier.flatMap {
            try SharedLikeStore.record(for: $0)
        }?.isLiked == true
        return MomentFamilyWidgetInteractionState(
            isSavedMemory: isInPersonalMemories,
            pawPhase: snapshot.pawPhase,
            canQueuePaw: snapshot.canQueuePaw
        )
    }

    /// Copies only the already-sanitized received JPEG bytes out of the
    /// lifecycle-protected store for one explicit Photos action. No path or
    /// participant identity crosses this boundary.
    static func photoLibraryCopyPayload(
        momentID: String,
        now: Date = .now,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> MomentPhotoLibraryCopyPayload {
        try withStateWhileLifecycleLocked(validating: lifecycleToken) { state in
            try validateSavedMemoryTarget(momentID: momentID, in: state)
            guard let item = state.inbox.first(where: { $0.id == momentID }),
                  let fileName = item.localJPEGFileName,
                  let directory = SharedContainer.momentSharingReceivedDirectoryURL,
                  item.receivedAt >= now.addingTimeInterval(-localHistorySeconds)
            else { throw MomentSharingError.stateUnavailable }
            let data = try Data(
                contentsOf: directory.appendingPathComponent(
                    fileName,
                    isDirectory: false
                ),
                options: [.mappedIfSafe]
            )
            guard !data.isEmpty,
                  data.count <= MomentSharingProtocol.maximumMediaCiphertextBytes - 28
            else { throw MomentSharingError.stateUnavailable }
            return MomentPhotoLibraryCopyPayload(
                jpegData: data,
                capturedAt: item.capturedAt
            )
        }
    }

    /// Returns the Photos asset previously created for this received moment.
    /// The target JPEG is revalidated so a stale Widget/deep-link cannot use a
    /// mapping after the sharing lifecycle has revoked or hidden the moment.
    static func importedMemoryRecord(
        momentID: String,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> MomentImportedMemoryRecord? {
        try withStateWhileLifecycleLocked(validating: lifecycleToken) { state in
            try validateSavedMemoryTarget(momentID: momentID, in: state)
            return state.importedMemories.first { $0.momentID == momentID }
        }
    }

    /// Persists an opaque import journal before PhotoKit is allowed to write.
    /// Returning an existing journal is intentional: the caller must recover
    /// that operation instead of issuing another irreversible create request.
    static func prepareMemoryImport(
        momentID: String,
        now: Date = .now,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> MomentMemoryImportPreparation {
        var result: MomentMemoryImportPreparation?
        _ = try mutate(validating: lifecycleToken) { state in
            try validateSavedMemoryTarget(momentID: momentID, in: state)
            guard !state.importedMemories.contains(where: {
                $0.momentID == momentID
            }) else { throw MomentSharingError.stateUnavailable }
            if let existing = state.pendingMemoryImports.first(where: {
                $0.momentID == momentID
            }) {
                result = MomentMemoryImportPreparation(
                    record: existing,
                    wasAlreadyPending: true
                )
                return
            }
            guard state.pendingMemoryImports.count < 10 else {
                throw MomentSharingError.stateUnavailable
            }
            let candidate = try MomentPendingMemoryImportRecord(
                momentID: momentID,
                importToken: UUID(),
                startedAt: now
            ).validated()
            state.pendingMemoryImports.append(candidate)
            result = MomentMemoryImportPreparation(
                record: candidate,
                wasAlreadyPending: false
            )
        }
        guard let result else { throw MomentSharingError.stateUnavailable }
        return result
    }

    /// Atomically converts the crash journal into the durable moment-to-Photos
    /// mapping. A mismatched token or identifier fails closed.
    static func completeMemoryImport(
        momentID: String,
        importToken: UUID,
        photoLocalIdentifier: String,
        importedAt: Date = .now,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        let candidate = try MomentImportedMemoryRecord(
            momentID: momentID,
            photoLocalIdentifier: photoLocalIdentifier,
            importedAt: importedAt
        ).validated()
        _ = try mutate(validating: lifecycleToken) { state in
            try validateSavedMemoryTarget(momentID: momentID, in: state)
            if let existing = state.importedMemories.first(where: {
                $0.momentID == momentID
            }) {
                guard existing.photoLocalIdentifier == photoLocalIdentifier else {
                    throw MomentSharingError.stateUnavailable
                }
                state.pendingMemoryImports.removeAll {
                    $0.momentID == momentID && $0.importToken == importToken
                }
                return
            }
            guard state.pendingMemoryImports.contains(where: {
                $0.momentID == momentID && $0.importToken == importToken
            }), !state.importedMemories.contains(where: {
                $0.photoLocalIdentifier == photoLocalIdentifier
            }) else { throw MomentSharingError.stateUnavailable }
            state.pendingMemoryImports.removeAll {
                $0.momentID == momentID && $0.importToken == importToken
            }
            state.importedMemories.append(candidate)
            state.savedMemories.removeAll { $0.momentID == momentID }
        }
    }

    /// Cancels only a PhotoKit operation that conclusively failed before an
    /// asset was created. Ambiguous/crashed operations intentionally remain
    /// journaled for full-library recovery.
    static func cancelMemoryImport(
        momentID: String,
        importToken: UUID,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        _ = try mutate(validating: lifecycleToken) { state in
            try validateSavedMemoryTarget(momentID: momentID, in: state)
            state.pendingMemoryImports.removeAll {
                $0.momentID == momentID && $0.importToken == importToken
            }
        }
    }

    /// Removes only a stale mapping after Photos confirms that its asset no
    /// longer exists. It never deletes a Photos asset or received JPEG.
    static func removeImportedMemoryRecord(
        momentID: String,
        expectedPhotoLocalIdentifier: String,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        _ = try mutate(validating: lifecycleToken) { state in
            try validateSavedMemoryTarget(momentID: momentID, in: state)
            state.importedMemories.removeAll {
                $0.momentID == momentID
                    && $0.photoLocalIdentifier == expectedPhotoLocalIdentifier
            }
        }
    }

    /// Atomically toggles the canonical local bookmark. This does not enqueue
    /// an outbox item, call the relay, write Photos/iCloud, or create another
    /// JPEG. Revocation and unlink continue to win through the lifecycle gate.
    @discardableResult
    static func toggleSavedMemory(
        momentID: String,
        now: Date = .now,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> MomentSavedMemoryMutation {
        var result: MomentSavedMemoryMutation?
        _ = try mutate(validating: lifecycleToken) { state in
            try validateSavedMemoryTarget(momentID: momentID, in: state)
            let previousIsSaved = state.savedMemories.contains {
                $0.momentID == momentID
            }
            state.savedMemories.removeAll { $0.momentID == momentID }
            let isSaved = !previousIsSaved
            if isSaved {
                state.savedMemories.append(
                    MomentSavedMemoryRecord(momentID: momentID, savedAt: now)
                )
            }
            result = MomentSavedMemoryMutation(
                previousIsSaved: previousIsSaved,
                isSaved: isSaved
            )
        }
        guard let result else { throw MomentSharingError.stateUnavailable }
        return result
    }

    private static func validateSavedMemoryTarget(
        momentID: String,
        in state: MomentSharingState
    ) throws {
        guard state.reportOnlyUntil == nil else {
            throw MomentSharingError.reportOnly(until: state.reportOnlyUntil!)
        }
        guard let item = state.inbox.first(where: { $0.id == momentID }),
              item.state == .available || item.state == .acknowledged,
              let fileName = item.localJPEGFileName,
              fileName == "\(item.id).jpg",
              fileName == (fileName as NSString).lastPathComponent,
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
    }

    /// Queues one explicit paw for a currently visible received photo. A paw
    /// is separate from the local bookmark and is never created implicitly by
    /// `setSavedMemory` or its Widget AppIntent.
    @discardableResult
    static func queuePaw(
        momentID: String,
        now: Date = .now,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> MomentPawOutboxItem {
        var queued: MomentPawOutboxItem?
        _ = try mutate(validating: lifecycleToken) { state in
            try validatePawTarget(momentID: momentID, now: now, in: state)
            if let existing = state.pawOutbox.first(where: {
                $0.momentID == momentID
            }) {
                queued = existing
                return
            }
            if state.pawOutbox.count >= maximumReactionHistoryCount {
                let oldestSentID = state.pawOutbox
                    .filter { $0.phase == .sent }
                    .min(by: { $0.updatedAt < $1.updatedAt })?.id
                if let oldestSentID {
                    state.pawOutbox.removeAll { $0.id == oldestSentID }
                }
            }
            guard state.pawOutbox.count < maximumReactionHistoryCount else {
                throw MomentSharingError.stateUnavailable
            }
            let item = try MomentPawOutboxItem(
                clientRequestID: UUID(),
                momentID: momentID,
                phase: .pending,
                serverReactionID: nil,
                createdAt: now,
                updatedAt: now
            ).validated()
            state.pawOutbox.append(item)
            queued = item
        }
        guard let queued else { throw MomentSharingError.stateUnavailable }
        return queued
    }

    private static func validatePawTarget(
        momentID: String,
        now: Date,
        in state: MomentSharingState
    ) throws {
        try validateSavedMemoryTarget(momentID: momentID, in: state)
        guard let item = state.inbox.first(where: { $0.id == momentID }),
              now < item.accessExpiresAt
        else { throw MomentSharingError.stateUnavailable }
    }

    static func markPawCommitting(
        clientRequestID: UUID,
        now: Date = .now,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        _ = try mutate(validating: lifecycleToken) { state in
            guard let index = state.pawOutbox.firstIndex(where: {
                $0.clientRequestID == clientRequestID
            }) else { throw MomentSharingError.stateUnavailable }
            guard state.pawOutbox[index].phase != .sent else { return }
            state.pawOutbox[index].phase = .committing
            state.pawOutbox[index].updatedAt = max(
                state.pawOutbox[index].updatedAt,
                now
            )
        }
    }

    static func markPawSent(
        clientRequestID: UUID,
        momentID: String,
        reactionID: String,
        now: Date = .now,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        _ = try mutate(validating: lifecycleToken) { state in
            guard let index = state.pawOutbox.firstIndex(where: {
                $0.clientRequestID == clientRequestID
            }),
            state.pawOutbox[index].momentID == momentID
            else { throw MomentSharingError.stateUnavailable }
            if let existing = state.pawOutbox[index].serverReactionID {
                guard existing == reactionID else {
                    throw MomentSharingError.stateUnavailable
                }
                return
            }
            state.pawOutbox[index].phase = .sent
            state.pawOutbox[index].serverReactionID = reactionID
            state.pawOutbox[index].updatedAt = max(
                state.pawOutbox[index].updatedAt,
                now
            )
        }
    }

    /// Removes a reaction request only after the relay has returned an
    /// unambiguous, non-retryable rejection. Ambiguous network and server
    /// failures keep the stable idempotency key in `.committing`.
    static func discardRejectedPaw(
        clientRequestID: UUID,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        _ = try mutate(validating: lifecycleToken) { state in
            state.pawOutbox.removeAll {
                $0.clientRequestID == clientRequestID && $0.phase != .sent
            }
        }
    }

    /// Records a paw only for a photo that this installation durably sent.
    /// The sender sees local observation time, not the recipient's exact tap.
    @discardableResult
    static func recordReceivedPaw(
        reactionID: String,
        momentID: String,
        observedAt: Date = .now,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> Bool {
        var inserted = false
        _ = try mutate(validating: lifecycleToken) { state in
            guard state.outbox.contains(where: {
                $0.phase == .committed && $0.serverMomentID == momentID
            }) else { return }
            guard !state.receivedPaws.contains(where: {
                $0.reactionID == reactionID
                    || $0.momentID == momentID
            }) else { return }
            state.receivedPaws.append(
                try MomentPawReceipt(
                    reactionID: reactionID,
                    momentID: momentID,
                    observedAt: observedAt
                ).validated()
            )
            if state.receivedPaws.count > maximumReactionHistoryCount {
                state.receivedPaws.sort {
                    if $0.observedAt != $1.observedAt {
                        return $0.observedAt > $1.observedAt
                    }
                    return $0.reactionID < $1.reactionID
                }
                state.receivedPaws = Array(
                    state.receivedPaws.prefix(maximumReactionHistoryCount)
                )
            }
            inserted = true
        }
        return inserted
    }

    @discardableResult
    static func advanceReactionCursor(
        expected: String?,
        next: String?,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> Bool {
        var advanced = false
        _ = try mutate(validating: lifecycleToken) { state in
            guard state.reactionCursor == expected else { return }
            state.reactionCursor = next
            advanced = true
        }
        return advanced
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
        localThumbnailJPEG: Data? = nil,
        validating lifecycleToken: SharingLifecycleGate.Token? = nil,
        now: Date = .now
    ) throws -> MomentOutboxItem {
        return try withLifecycleLock(validating: lifecycleToken) {
            try enqueueWhileLifecycleLocked(
                payload: payload,
                senderPolicyVersion: senderPolicyVersion,
                senderPolicyAcceptedAt: senderPolicyAcceptedAt,
                localThumbnailJPEG: localThumbnailJPEG,
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
        localThumbnailJPEG: Data? = nil,
        now: Date = .now
    ) throws -> MomentOutboxItem {
        let payload = try payload.validated()
        let thumbnailFileName = localThumbnailJPEG.flatMap { data in
            MomentOutboxItem.isValidLocalThumbnail(data)
                ? MomentOutboxItem.localThumbnailFileName(
                for: payload.context.clientMomentID
                )
                : nil
        }
        var item = try MomentOutboxItem(
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
            if let localThumbnailJPEG, let thumbnailFileName {
                do {
                    try writeLocalThumbnail(
                        localThumbnailJPEG,
                        fileName: thumbnailFileName
                    )
                    item.localThumbnailFileName = thumbnailFileName
                    item = try item.validated()
                } catch {
                    // A sent-history preview is optional presentation state;
                    // storage pressure must not turn an otherwise valid send
                    // into a delivery failure.
                    try? removeLocalThumbnail(fileName: thumbnailFileName)
                    item.localThumbnailFileName = nil
                }
            }
            state.outbox.append(item)
            state.storageRevision += 1
            try writeWhileLocked(try state.validated())
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? removeLocalThumbnail(for: item)
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

    /// Returns only a small, protected JPEG referenced by this exact local
    /// outbox row. Corrupt, oversized, unprotected, missing, or replaced files
    /// are presentation misses rather than state failures.
    static func readLocalThumbnail(for item: MomentOutboxItem) -> Data? {
        guard let fileName = item.localThumbnailFileName,
              fileName == MomentOutboxItem.localThumbnailFileName(for: item.id),
              let url = try? localThumbnailURL(fileName: fileName),
              SharingSecureFile.hasRequiredProtectionAndBackupExclusion(url),
              let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.path
              ),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let fileSize = (attributes[.size] as? NSNumber)?.intValue,
              (4...MomentOutboxItem.maximumLocalThumbnailBytes).contains(fileSize),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(
            upToCount: MomentOutboxItem.maximumLocalThumbnailBytes + 1
        ),
        MomentOutboxItem.isValidLocalThumbnail(data)
        else { return nil }
        return data
    }

    static func removeLocalThumbnail(for item: MomentOutboxItem) throws {
        guard let fileName = item.localThumbnailFileName else { return }
        try removeLocalThumbnail(fileName: fileName)
    }

    private static func removeLocalThumbnail(fileName: String) throws {
        let url = try localThumbnailURL(fileName: fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func writeLocalThumbnail(
        _ data: Data,
        fileName: String
    ) throws {
        guard MomentOutboxItem.isValidLocalThumbnail(data) else {
            throw MomentSharingError.stateUnavailable
        }
        let url = try localThumbnailURL(fileName: fileName)
        try SharingSecureFile.write(
            data,
            to: url
        )
        guard try isSafeThumbnailDirectory(
            url.deletingLastPathComponent(),
            requireExisting: true
        ),
        let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        SharingSecureFile.hasRequiredProtectionAndBackupExclusion(url)
        else {
            try? FileManager.default.removeItem(at: url)
            throw MomentSharingError.stateUnavailable
        }
    }

    private static func localThumbnailURL(fileName: String) throws -> URL {
        guard let idText = fileName
                .split(separator: "-")
                .dropFirst(2)
                .joined(separator: "-")
                .split(separator: ".")
                .first,
              let id = UUID(uuidString: String(idText)),
              fileName == MomentOutboxItem.localThumbnailFileName(for: id),
              let directory = SharedContainer.momentSharingSentThumbnailDirectoryURL
        else { throw MomentSharingError.stateUnavailable }
        guard try isSafeThumbnailDirectory(directory, requireExisting: false)
        else { throw MomentSharingError.stateUnavailable }
        let standardizedDirectory = directory.standardizedFileURL
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard url.deletingLastPathComponent() == standardizedDirectory,
              resolvedURL.deletingLastPathComponent() == resolvedDirectory,
              values?.isSymbolicLink != true
        else {
            throw MomentSharingError.stateUnavailable
        }
        return url
    }

    /// The app-owned leaf and its sharing-cache parent must not be symbolic
    /// links. Resolving both paths also catches a redirected child while
    /// tolerating platform-level aliases above the App Group container.
    private static func isSafeThumbnailDirectory(
        _ directory: URL,
        requireExisting: Bool
    ) throws -> Bool {
        let manager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        if requireExisting && !manager.fileExists(atPath: directory.path) {
            return false
        }
        for candidate in [parent, directory]
        where manager.fileExists(atPath: candidate.path) {
            let values = try candidate.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true
            else { return false }
        }
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDirectory = directory.resolvingSymlinksInPath()
            .standardizedFileURL
        return resolvedDirectory.deletingLastPathComponent() == resolvedParent
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
            try? removeLocalThumbnail(for: item)
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
        state.pawOutbox.removeAll()
        state.receivedPaws.removeAll()
        state.reactionCursor = nil
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
        for item in discarded {
            try? removeCiphertext(for: item)
            try? removeLocalThumbnail(for: item)
        }
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
            try? removeLocalThumbnail(for: item)
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
        let thumbnailDirectory = SharedContainer.momentSharingSentThumbnailDirectoryURL
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
            state.importedMemories.removeAll {
                !retainedMomentIDs.contains($0.momentID)
            }
            state.pendingMemoryImports.removeAll {
                !retainedMomentIDs.contains($0.momentID)
            }
            state.pawOutbox.removeAll {
                !retainedMomentIDs.contains($0.momentID)
                    || ($0.phase != .sent && $0.createdAt < pendingCutoff)
                    || ($0.phase == .sent && $0.updatedAt < outboxMetadataCutoff)
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
            let retainedSentMomentIDs = Set(state.outbox.compactMap { item in
                item.phase == .committed ? item.serverMomentID : nil
            })
            state.receivedPaws.removeAll {
                !retainedSentMomentIDs.contains($0.momentID)
                    || $0.observedAt < outboxMetadataCutoff
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
            if let thumbnailDirectory,
               (try? isSafeThumbnailDirectory(
                   thumbnailDirectory,
                   requireExisting: true
               )) == true {
                let retainedNames = Set(state.outbox.compactMap(\.localThumbnailFileName))
                let fallbackNames = removedOutbox.compactMap(\.localThumbnailFileName)
                let names = boundedThumbnailDirectoryEntryNames(
                    at: thumbnailDirectory,
                    fallback: fallbackNames
                )
                // Delete only exact UUID-derived basenames through the same
                // containment checks used by ordinary thumbnail removal.
                // Unknown entries are never worth risking another sharing
                // artifact merely to reclaim optional preview bytes.
                for name in names where !retainedNames.contains(name) {
                    try? removeLocalThumbnail(fileName: name)
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
            let didMigrateThumbnail = migrateLegacyInlineThumbnailsWhileLocked(&state)
            state = try state.validated()
            if didNormalize { try writeWhileLocked(state) }
            else if didMigrateThumbnail {
                // Preview migration is optional. If this state rewrite cannot
                // commit under storage pressure, return the validated core
                // state and retry from the legacy bytes on a later load.
                try? writeWhileLocked(state)
            }
            return state
        } catch {
            throw MomentSharingError.stateUnavailable
        }
    }

    /// Build 92 briefly persisted previews inline. Migration is deliberately
    /// fail-soft: an optional preview may be dropped, but it can never make the
    /// otherwise valid sharing ledger unavailable. A later bounded prune
    /// removes any file orphaned between its commit and the state rewrite.
    private static func migrateLegacyInlineThumbnailsWhileLocked(
        _ state: inout MomentSharingState
    ) -> Bool {
        var didMigrate = false
        for index in state.outbox.indices {
            guard let data = state.outbox[index].legacyInlineLocalThumbnailJPEG
            else { continue }
            state.outbox[index].localThumbnailFileName = nil
            if MomentOutboxItem.isValidLocalThumbnail(data) {
                let fileName = MomentOutboxItem.localThumbnailFileName(
                    for: state.outbox[index].id
                )
                do {
                    try writeLocalThumbnail(data, fileName: fileName)
                    state.outbox[index].localThumbnailFileName = fileName
                } catch {
                    // Inline Build-92 previews are optional. Drop only this
                    // presentation copy; never fail the sharing state.
                    try? removeLocalThumbnail(fileName: fileName)
                }
            }
            state.outbox[index].legacyInlineLocalThumbnailJPEG = nil
            didMigrate = true
        }
        return didMigrate
    }

    private static func boundedThumbnailDirectoryEntryNames(
        at directory: URL,
        fallback: [String]
    ) -> [String] {
        let maximumEntries = maximumTerminalOutboxMetadataCount
            + maximumPendingOutboxCount + 64
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else { return Array(fallback.prefix(maximumEntries)) }
        var names: [String] = []
        for case let url as URL in enumerator {
            names.append(url.lastPathComponent)
            if names.count >= maximumEntries { break }
        }
        return names
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
