import Darwin
import Foundation

enum OutboundGenerationPhase: String, Codable, Sendable {
    case frozen
    case reserved
    case descriptorsFrozen
    case mediaUploaded
    case prepared
    case manifestUploaded
    case committing
}

enum DailySharingRetryDomain: String, Codable, Sendable {
    case outboundMutation
    case outboundReconcileOnly
    case inbound
}

enum DailySharingOutboundRetryIntent: String, Codable, Sendable {
    case mutation
    case reconcileOnly
}

enum DailySharingOutboundReconcileReason: String, Codable, Sendable {
    /// A transport/response-loss outcome whose live server phase is unknown.
    case uncertainOutcome
    /// A prepared anchor expired; verified media may still be re-prepared.
    case prepareDeadline
    /// The whole server staging generation expired; it cannot be resumed.
    case draftDeadline
    case generationDayExpired
    case uploadClosed
    case invalidGenerationState
    case commitConflict
}

struct DailySharingRetrySchedule: Codable, Equatable, Sendable {
    var attemptCount: Int
    var nextRetryAt: Date

    func validated() throws -> Self {
        guard (1...10_000).contains(attemptCount) else {
            throw DailySharingError.stateUnavailable
        }
        return self
    }
}

struct FrozenSharingMedia: Codable, Equatable, Sendable {
    var mediaID: String
    var localIdentifier: String
    var sourceModificationDate: Date?
    var sourcePixelSize: WidgetSourcePixelSize
    var renderPlans: WidgetRenderPlans
}

struct StagedSharingMedia: Codable, Equatable, Sendable {
    var frozen: FrozenSharingMedia
    var binding: SharingMediaBinding?
    var canonicalJPEGPlaintextSHA256: String?
    var ciphertextFilename: String?
    var ciphertextSize: Int?
    var ciphertextSHA256: String?
    var uploadVerified: Bool = false

    func validated() throws -> Self {
        guard Data(base64URLString: frozen.mediaID)?.count == 16,
              !frozen.localIdentifier.isEmpty,
              frozen.localIdentifier.utf8.count <= 2_048,
              frozen.sourcePixelSize.isValid,
              frozen.renderPlans.allAreValid
        else { throw DailySharingError.stateUnavailable }

        let hasCiphertext = binding != nil
            || canonicalJPEGPlaintextSHA256 != nil
            || ciphertextFilename != nil
            || ciphertextSize != nil
            || ciphertextSHA256 != nil
            || uploadVerified
        if hasCiphertext {
            guard let binding,
                  let canonicalJPEGPlaintextSHA256,
                  Data(base64URLString: canonicalJPEGPlaintextSHA256)?.count == 32,
                  let ciphertextFilename,
                  Self.isSafeFilename(ciphertextFilename),
                  let ciphertextSize,
                  (DailySharingProtocol.chachaCombinedOverheadBytes + 1 ... DailySharingProtocol.maximumMediaCiphertextBytes)
                    .contains(ciphertextSize),
                  let ciphertextSHA256,
                  Data(base64URLString: ciphertextSHA256)?.count == 32
            else { throw DailySharingError.stateUnavailable }
            _ = try binding.validated()
        }
        return self
    }

    private static func isSafeFilename(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.contains("/") && !value.contains("\\")
            && value != "." && value != ".."
    }
}

struct PreparedSharingAttempt: Codable, Equatable, Sendable {
    var clientRequestID: String
    var attemptID: String
    var attemptRevision: Int
    var reservedRevision: Int
    var rotationAnchorUTC: Int
    var prepareExpiresAt: Int
    var manifestCiphertextFilename: String?
    var manifestCiphertextSize: Int?
    var manifestCiphertextSHA256: String?
    var commitClientRequestID: String?

    func validated() throws -> Self {
        guard UUID(uuidString: clientRequestID) != nil,
              PairingValidation.isOpaqueIdentifier(attemptID),
              attemptRevision > 0,
              reservedRevision > 0,
              rotationAnchorUTC > 0,
              rotationAnchorUTC.isMultiple(of: 1_200),
              prepareExpiresAt == rotationAnchorUTC
        else { throw DailySharingError.stateUnavailable }
        let manifestFields = [
            manifestCiphertextFilename != nil,
            manifestCiphertextSize != nil,
            manifestCiphertextSHA256 != nil,
            commitClientRequestID != nil
        ]
        guard manifestFields.allSatisfy({ $0 }) || manifestFields.allSatisfy({ !$0 }) else {
            throw DailySharingError.stateUnavailable
        }
        if let filename = manifestCiphertextFilename,
           let size = manifestCiphertextSize,
           let hash = manifestCiphertextSHA256,
           let commitClientRequestID {
            guard !filename.contains("/"), !filename.contains("\\"),
                  (DailySharingProtocol.chachaCombinedOverheadBytes + 1 ... DailySharingProtocol.maximumManifestCiphertextBytes)
                    .contains(size),
                  Data(base64URLString: hash)?.count == 32,
                  UUID(uuidString: commitClientRequestID) != nil
            else { throw DailySharingError.stateUnavailable }
        }
        return self
    }
}

struct OutboundSharingGeneration: Codable, Equatable, Sendable {
    var phase: OutboundGenerationPhase
    /// Local estimate used only to avoid more than one freeze per boundary.
    /// The server-authoritative value replaces it on reserve.
    var localDayKey: Int
    var frozenAt: Date
    var sourceManifestGeneratedAt: Date
    var reserveClientRequestID: String
    /// Durable evidence that the reserve request may already have committed
    /// server-side. It is written before the network await, so a response-loss
    /// retry keeps the exact request and frozen set even across a local day.
    var reserveAttemptedAt: Date? = nil
    var reserveAttemptBoundaryMinuteUTC: Int? = nil
    var slotMediaIDs: [String]
    var media: [StagedSharingMedia]
    var sourceID: String?
    var generationID: String?
    var serverShareDayKey: Int?
    var draftExpiresAt: Int?
    var descriptorClientRequestID: String?
    /// Persisted before the prepare request. It survives an unknown transport
    /// outcome so the server sees the exact same idempotency key on retry.
    var pendingPrepareClientRequestID: String?
    var prepare: PreparedSharingAttempt?

    func validated() throws -> Self {
        guard (0...10_000_000).contains(localDayKey),
              UUID(uuidString: reserveClientRequestID) != nil,
              !slotMediaIDs.isEmpty,
              slotMediaIDs.count <= DailySharingProtocol.maximumSlotCount,
              !media.isEmpty,
              media.count <= DailySharingProtocol.maximumSlotCount
        else { throw DailySharingError.stateUnavailable }
        let ids = media.map(\.frozen.mediaID)
        guard ids == ids.sorted(), Set(ids).count == ids.count,
              Set(slotMediaIDs) == Set(ids)
        else { throw DailySharingError.stateUnavailable }
        for item in media { _ = try item.validated() }

        let hasReservation = sourceID != nil || generationID != nil
            || serverShareDayKey != nil || draftExpiresAt != nil || descriptorClientRequestID != nil
        let hasReserveAttempt = reserveAttemptedAt != nil
            || reserveAttemptBoundaryMinuteUTC != nil
        if hasReserveAttempt {
            guard phase == .frozen,
                  !hasReservation,
                  let attemptedAt = reserveAttemptedAt,
                  let boundary = reserveAttemptBoundaryMinuteUTC,
                  (0...1_439).contains(boundary),
                  Self.dayKey(at: attemptedAt, boundaryMinuteUTC: boundary) == localDayKey
            else { throw DailySharingError.stateUnavailable }
        }
        if hasReservation {
            guard sourceID.map(PairingValidation.isOpaqueIdentifier) == true,
                  generationID.map(PairingValidation.isOpaqueIdentifier) == true,
                  serverShareDayKey.map({ (0...10_000_000).contains($0) }) == true,
                  draftExpiresAt.map({ $0 > 0 }) == true,
                  descriptorClientRequestID.flatMap(UUID.init(uuidString:)) != nil
            else { throw DailySharingError.stateUnavailable }
        }
        if hasReservation, hasReserveAttempt { throw DailySharingError.stateUnavailable }
        if phase != .frozen, !hasReservation { throw DailySharingError.stateUnavailable }
        if phase == .descriptorsFrozen || phase == .mediaUploaded
            || phase == .prepared || phase == .manifestUploaded || phase == .committing {
            guard media.allSatisfy({ $0.ciphertextFilename != nil }) else {
                throw DailySharingError.stateUnavailable
            }
        }
        if phase == .mediaUploaded || phase == .prepared
            || phase == .manifestUploaded || phase == .committing {
            guard media.allSatisfy(\.uploadVerified) else {
                throw DailySharingError.stateUnavailable
            }
        }
        guard pendingPrepareClientRequestID == nil
                || pendingPrepareClientRequestID.flatMap(UUID.init(uuidString:)) != nil,
              prepare == nil || pendingPrepareClientRequestID == nil
        else { throw DailySharingError.stateUnavailable }
        if let prepare { _ = try prepare.validated() }
        if phase == .prepared || phase == .manifestUploaded || phase == .committing {
            guard prepare != nil else { throw DailySharingError.stateUnavailable }
        }
        if phase == .manifestUploaded || phase == .committing {
            guard prepare?.manifestCiphertextFilename != nil,
                  prepare?.manifestCiphertextSize != nil,
                  prepare?.manifestCiphertextSHA256 != nil,
                  prepare?.commitClientRequestID != nil
            else { throw DailySharingError.stateUnavailable }
        }
        return self
    }

    private static func dayKey(at date: Date, boundaryMinuteUTC: Int) -> Int {
        let shifted = Int(date.timeIntervalSince1970) - boundaryMinuteUTC * 60
        return shifted / 86_400
    }
}

struct InboundSharingHighWater: Codable, Equatable, Sendable {
    var sourceID: String
    var publisherMemberID: String
    var shareDayKey: Int
    var revision: Int
    var generationID: String
    var prepareAttemptID: String
    var prepareAttemptRevision: Int
    var reservedRevision: Int
    var rotationAnchorUTC: Int
    var uniqueMediaCount: Int
    var manifestCiphertextSize: Int
    var manifestCiphertextSHA256: String
    var verifiedDirectoryName: String
    var verifiedAt: Date

    func validated() throws -> Self {
        guard PairingValidation.isOpaqueIdentifier(sourceID),
              PairingValidation.isOpaqueIdentifier(publisherMemberID),
              (0...10_000_000).contains(shareDayKey),
              revision > 0,
              PairingValidation.isOpaqueIdentifier(generationID),
              PairingValidation.isOpaqueIdentifier(prepareAttemptID),
              prepareAttemptRevision > 0,
              reservedRevision == revision,
              rotationAnchorUTC > 0,
              rotationAnchorUTC.isMultiple(of: 1_200),
              (1...DailySharingProtocol.maximumSlotCount).contains(uniqueMediaCount),
              (DailySharingProtocol.chachaCombinedOverheadBytes + 1 ... DailySharingProtocol.maximumManifestCiphertextBytes)
                .contains(manifestCiphertextSize),
              Data(base64URLString: manifestCiphertextSHA256)?.count == 32,
              verifiedDirectoryName == "\(sourceID)-\(generationID)",
              verifiedDirectoryName != ".",
              verifiedDirectoryName != "..",
              !verifiedDirectoryName.contains("/"),
              !verifiedDirectoryName.contains("\\")
        else { throw DailySharingError.stateUnavailable }
        return self
    }

    /// Reject rollback and equivocation. An exact current descriptor is a safe
    /// idempotent no-op; any same-revision identity/hash change is fatal.
    func accepts(
        publisherMemberID candidatePublisherMemberID: String,
        shareDayKey candidateDay: Int,
        revision candidateRevision: Int,
        generationID candidateGenerationID: String,
        prepareAttemptID candidatePrepareAttemptID: String,
        prepareAttemptRevision candidatePrepareAttemptRevision: Int,
        reservedRevision candidateReservedRevision: Int,
        rotationAnchorUTC candidateRotationAnchorUTC: Int,
        uniqueMediaCount candidateUniqueMediaCount: Int,
        manifestCiphertextSize candidateManifestCiphertextSize: Int,
        manifestHash candidateManifestHash: String
    ) -> Bool {
        guard candidatePublisherMemberID == publisherMemberID else { return false }
        guard candidateDay >= shareDayKey, candidateRevision >= revision else { return false }
        if candidateDay == shareDayKey || candidateRevision == revision {
            guard candidateDay == shareDayKey, candidateRevision == revision else { return false }
            return candidateGenerationID == generationID
                && candidatePrepareAttemptID == prepareAttemptID
                && candidatePrepareAttemptRevision == prepareAttemptRevision
                && candidateReservedRevision == reservedRevision
                && candidateRotationAnchorUTC == rotationAnchorUTC
                && candidateUniqueMediaCount == uniqueMediaCount
                && candidateManifestCiphertextSize == manifestCiphertextSize
                && candidateManifestHash == manifestCiphertextSHA256
        }
        return true
    }
}

struct InboundDownloadMedia: Codable, Equatable, Sendable {
    var mediaID: String
    var ciphertextSize: Int
    var ciphertextSHA256: String

    func validated() throws -> Self {
        guard Data(base64URLString: mediaID)?.count == 16,
              (DailySharingProtocol.chachaCombinedOverheadBytes + 1
                ... DailySharingProtocol.maximumMediaCiphertextBytes)
                .contains(ciphertextSize),
              Data(base64URLString: ciphertextSHA256)?.count == 32
        else { throw DailySharingError.stateUnavailable }
        return self
    }
}

/// Exact authenticated current descriptor plus incremental verification
/// progress. Only ciphertext is staged; plaintext JPEGs never reach disk.
struct InboundDownloadDraft: Codable, Equatable, Sendable {
    var sourceID: String
    var publisherMemberID: String
    var shareDayKey: Int
    var revision: Int
    var generationID: String
    var prepareAttemptID: String
    var prepareAttemptRevision: Int
    var reservedRevision: Int
    var rotationAnchorUTC: Int
    var uniqueMediaCount: Int
    var manifestCiphertextSize: Int
    var manifestCiphertextSHA256: String
    var media: [InboundDownloadMedia]
    var stagingDirectoryName: String
    var manifestVerified: Bool
    var completedMediaIDs: [String]
    var startedAt: Date

    func validated() throws -> Self {
        let descriptor = InboundSharingHighWater(
            sourceID: sourceID,
            publisherMemberID: publisherMemberID,
            shareDayKey: shareDayKey,
            revision: revision,
            generationID: generationID,
            prepareAttemptID: prepareAttemptID,
            prepareAttemptRevision: prepareAttemptRevision,
            reservedRevision: reservedRevision,
            rotationAnchorUTC: rotationAnchorUTC,
            uniqueMediaCount: uniqueMediaCount,
            manifestCiphertextSize: manifestCiphertextSize,
            manifestCiphertextSHA256: manifestCiphertextSHA256,
            verifiedDirectoryName: "\(sourceID)-\(generationID)",
            verifiedAt: startedAt
        )
        _ = try descriptor.validated()
        let mediaIDs = media.map(\.mediaID)
        guard media.count == uniqueMediaCount,
              mediaIDs == mediaIDs.sorted(),
              Set(mediaIDs).count == mediaIDs.count,
              !stagingDirectoryName.isEmpty,
              stagingDirectoryName.hasPrefix(".download-"),
              !stagingDirectoryName.contains("/"),
              !stagingDirectoryName.contains("\\"),
              completedMediaIDs == completedMediaIDs.sorted(),
              Set(completedMediaIDs).count == completedMediaIDs.count,
              Set(completedMediaIDs).isSubset(of: Set(mediaIDs)),
              manifestVerified || completedMediaIDs.isEmpty
        else { throw DailySharingError.stateUnavailable }
        for value in media { _ = try value.validated() }
        return self
    }

    func matches(_ candidate: Self) -> Bool {
        var lhs = self
        var rhs = candidate
        lhs.manifestVerified = false
        lhs.completedMediaIDs = []
        lhs.startedAt = candidate.startedAt
        rhs.manifestVerified = false
        rhs.completedMediaIDs = []
        return lhs == rhs
    }
}

struct DailySharingState: Codable, Equatable, Sendable {
    static let schemaVersion = 6

    var schemaVersion: Int = Self.schemaVersion
    /// Cross-process compare-and-swap token. Network awaits never hold the
    /// flock; a writer must reload when this value changed.
    var storageRevision: Int = 0
    var spaceID: String
    var memberID: String
    var ownSourceID: String?
    /// Local freeze window already completed. Kept separate from the
    /// server-authoritative share day, which can differ by one at a boundary.
    var lastCompletedLocalDayKey: Int?
    var lastPublishedDayKey: Int?
    var lastPublishedRevision: Int?
    var outbound: OutboundSharingGeneration?
    /// Highest authenticated descriptor ever downloaded for each source.
    /// This is the anti-rollback watermark, independent of presentation time.
    var inboundHighWaterBySource: [String: InboundSharingHighWater]
    /// Fully verified generation waiting for its server-fixed rotation anchor.
    var inboundPendingBySource: [String: InboundSharingHighWater]
    /// Generation currently eligible for presentation. Phase 3 reads only
    /// this pointer, never the pending/high-water pointer.
    var inboundActiveBySource: [String: InboundSharingHighWater]
    var inboundDownloadBySource: [String: InboundDownloadDraft]
    var retryAttemptCount: Int
    var nextRetryAt: Date?
    var retryDomain: DailySharingRetryDomain?
    var outboundRetry: DailySharingRetrySchedule?
    var outboundRetryIntent: DailySharingOutboundRetryIntent?
    var outboundReconcileReason: DailySharingOutboundReconcileReason?
    var inboundRetry: DailySharingRetrySchedule?
    var lastSyncAt: Date?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, storageRevision, spaceID, memberID, ownSourceID
        case lastCompletedLocalDayKey, lastPublishedDayKey, lastPublishedRevision
        case outbound, inboundHighWaterBySource, inboundPendingBySource
        case inboundActiveBySource, inboundDownloadBySource
        case retryAttemptCount, nextRetryAt, retryDomain
        case outboundRetry, outboundRetryIntent, outboundReconcileReason
        case inboundRetry, lastSyncAt
    }

    init(
        storageRevision: Int = 0,
        spaceID: String,
        memberID: String,
        ownSourceID: String? = nil,
        lastCompletedLocalDayKey: Int? = nil,
        lastPublishedDayKey: Int? = nil,
        lastPublishedRevision: Int? = nil,
        outbound: OutboundSharingGeneration? = nil,
        inboundHighWaterBySource: [String: InboundSharingHighWater] = [:],
        inboundPendingBySource: [String: InboundSharingHighWater] = [:],
        inboundActiveBySource: [String: InboundSharingHighWater] = [:],
        inboundDownloadBySource: [String: InboundDownloadDraft] = [:],
        retryAttemptCount: Int = 0,
        nextRetryAt: Date? = nil,
        retryDomain: DailySharingRetryDomain? = nil,
        outboundRetry: DailySharingRetrySchedule? = nil,
        outboundRetryIntent: DailySharingOutboundRetryIntent? = nil,
        outboundReconcileReason: DailySharingOutboundReconcileReason? = nil,
        inboundRetry: DailySharingRetrySchedule? = nil,
        lastSyncAt: Date? = nil
    ) {
        self.storageRevision = storageRevision
        self.spaceID = spaceID
        self.memberID = memberID
        self.ownSourceID = ownSourceID
        self.lastCompletedLocalDayKey = lastCompletedLocalDayKey
        self.lastPublishedDayKey = lastPublishedDayKey
        self.lastPublishedRevision = lastPublishedRevision
        self.outbound = outbound
        self.inboundHighWaterBySource = inboundHighWaterBySource
        self.inboundPendingBySource = inboundPendingBySource
        self.inboundActiveBySource = inboundActiveBySource
        self.inboundDownloadBySource = inboundDownloadBySource
        self.retryAttemptCount = retryAttemptCount
        self.nextRetryAt = nextRetryAt
        self.retryDomain = retryDomain
        self.outboundRetry = outboundRetry
        self.outboundRetryIntent = outboundRetryIntent
        self.outboundReconcileReason = outboundReconcileReason
        self.inboundRetry = inboundRetry
        self.lastSyncAt = lastSyncAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchema = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.schemaVersion).contains(decodedSchema) else {
            throw DailySharingError.stateUnavailable
        }
        schemaVersion = Self.schemaVersion
        storageRevision = try container.decodeIfPresent(Int.self, forKey: .storageRevision) ?? 0
        spaceID = try container.decode(String.self, forKey: .spaceID)
        memberID = try container.decode(String.self, forKey: .memberID)
        ownSourceID = try container.decodeIfPresent(String.self, forKey: .ownSourceID)
        lastCompletedLocalDayKey = try container.decodeIfPresent(
            Int.self,
            forKey: .lastCompletedLocalDayKey
        )
        lastPublishedDayKey = try container.decodeIfPresent(Int.self, forKey: .lastPublishedDayKey)
        lastPublishedRevision = try container.decodeIfPresent(Int.self, forKey: .lastPublishedRevision)
        outbound = try container.decodeIfPresent(OutboundSharingGeneration.self, forKey: .outbound)
        let highWater = try container.decodeIfPresent(
            [String: InboundSharingHighWater].self,
            forKey: .inboundHighWaterBySource
        ) ?? [:]
        inboundHighWaterBySource = highWater
        if decodedSchema >= 2 {
            inboundPendingBySource = try container.decodeIfPresent(
                [String: InboundSharingHighWater].self,
                forKey: .inboundPendingBySource
            ) ?? [:]
            inboundActiveBySource = try container.decodeIfPresent(
                [String: InboundSharingHighWater].self,
                forKey: .inboundActiveBySource
            ) ?? [:]
        } else {
            // Phase-2 schema 1 had one pointer and could activate before the
            // anchor. Preserve verified bytes, but expose only already-due
            // entries as active during migration.
            let now = Int(Date().timeIntervalSince1970)
            inboundPendingBySource = highWater.filter { $0.value.rotationAnchorUTC > now }
            inboundActiveBySource = highWater.filter { $0.value.rotationAnchorUTC <= now }
        }
        inboundDownloadBySource = try container.decodeIfPresent(
            [String: InboundDownloadDraft].self,
            forKey: .inboundDownloadBySource
        ) ?? [:]
        retryAttemptCount = try container.decodeIfPresent(Int.self, forKey: .retryAttemptCount) ?? 0
        nextRetryAt = try container.decodeIfPresent(Date.self, forKey: .nextRetryAt)
        retryDomain = try container.decodeIfPresent(
            DailySharingRetryDomain.self,
            forKey: .retryDomain
        )
        outboundRetry = try container.decodeIfPresent(
            DailySharingRetrySchedule.self,
            forKey: .outboundRetry
        )
        outboundRetryIntent = try container.decodeIfPresent(
            DailySharingOutboundRetryIntent.self,
            forKey: .outboundRetryIntent
        )
        outboundReconcileReason = try container.decodeIfPresent(
            DailySharingOutboundReconcileReason.self,
            forKey: .outboundReconcileReason
        )
        inboundRetry = try container.decodeIfPresent(
            DailySharingRetrySchedule.self,
            forKey: .inboundRetry
        )
        if decodedSchema < 4, retryAttemptCount > 0, let nextRetryAt {
            let migrated = DailySharingRetrySchedule(
                attemptCount: retryAttemptCount,
                nextRetryAt: nextRetryAt
            )
            if retryDomain == .inbound {
                inboundRetry = migrated
            } else {
                outboundRetry = migrated
                outboundRetryIntent = retryDomain == .outboundReconcileOnly
                    ? .reconcileOnly : .mutation
            }
            retryAttemptCount = 0
            self.nextRetryAt = nil
            retryDomain = nil
        }
        if decodedSchema < 6,
           outboundRetryIntent == .reconcileOnly,
           outboundReconcileReason == nil {
            outboundReconcileReason = .uncertainOutcome
        }
        lastSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAt)
    }

    static func empty(spaceID: String, memberID: String) -> Self {
        Self(
            spaceID: spaceID,
            memberID: memberID,
            inboundHighWaterBySource: [:]
        )
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              storageRevision >= 0,
              PairingValidation.isOpaqueIdentifier(spaceID),
              PairingValidation.isOpaqueIdentifier(memberID),
              ownSourceID == nil || ownSourceID.map(PairingValidation.isOpaqueIdentifier) == true,
              lastCompletedLocalDayKey == nil
                || lastCompletedLocalDayKey.map({ (0...10_000_000).contains($0) }) == true,
              (lastPublishedDayKey == nil) == (lastPublishedRevision == nil),
              lastPublishedDayKey == nil || lastPublishedDayKey.map({ (0...10_000_000).contains($0) }) == true,
              lastPublishedRevision == nil || lastPublishedRevision.map({ $0 > 0 }) == true,
              retryAttemptCount >= 0,
              retryAttemptCount <= 10_000,
              (retryAttemptCount == 0) == (nextRetryAt == nil),
              (retryAttemptCount == 0) == (retryDomain == nil),
              retryAttemptCount == 0,
              (outboundRetry == nil) == (outboundRetryIntent == nil),
              (outboundRetryIntent == .reconcileOnly)
                == (outboundReconcileReason != nil)
        else { throw DailySharingError.stateUnavailable }
        if let outboundRetry { _ = try outboundRetry.validated() }
        if let inboundRetry { _ = try inboundRetry.validated() }
        if let outbound { _ = try outbound.validated() }
        let knownSourceIDs = Set(inboundHighWaterBySource.keys)
            .union(inboundPendingBySource.keys)
            .union(inboundActiveBySource.keys)
            .union(inboundDownloadBySource.keys)
            .union(ownSourceID.map { [$0] } ?? [])
        guard knownSourceIDs.count <= 2 else { throw DailySharingError.stateUnavailable }
        let publishers = inboundHighWaterBySource.values.map(\.publisherMemberID)
        guard Set(publishers).count == publishers.count else {
            throw DailySharingError.stateUnavailable
        }
        var sourceByPublisher = Dictionary(
            uniqueKeysWithValues: inboundHighWaterBySource.values.map {
                ($0.publisherMemberID, $0.sourceID)
            }
        )
        for draft in inboundDownloadBySource.values {
            if let known = sourceByPublisher[draft.publisherMemberID], known != draft.sourceID {
                throw DailySharingError.stateUnavailable
            }
            sourceByPublisher[draft.publisherMemberID] = draft.sourceID
        }
        guard sourceByPublisher.count <= 2 else { throw DailySharingError.stateUnavailable }
        if let ownSourceID {
            if let ownHighWater = inboundHighWaterBySource[ownSourceID] {
                guard ownHighWater.publisherMemberID == memberID else {
                    throw DailySharingError.stateUnavailable
                }
            }
            if let selfPublished = inboundHighWaterBySource.values.first(
                where: { $0.publisherMemberID == memberID }
            ) {
                guard selfPublished.sourceID == ownSourceID else {
                    throw DailySharingError.stateUnavailable
                }
            }
            if let selfDraft = inboundDownloadBySource.values.first(
                where: { $0.publisherMemberID == memberID }
            ) {
                guard selfDraft.sourceID == ownSourceID else {
                    throw DailySharingError.stateUnavailable
                }
            }
        }
        for (sourceID, highWater) in inboundHighWaterBySource {
            guard sourceID == highWater.sourceID else { throw DailySharingError.stateUnavailable }
            _ = try highWater.validated()
        }
        for (sourceID, draft) in inboundDownloadBySource {
            guard sourceID == draft.sourceID else { throw DailySharingError.stateUnavailable }
            _ = try draft.validated()
            if let highWater = inboundHighWaterBySource[sourceID] {
                guard highWater.accepts(
                    publisherMemberID: draft.publisherMemberID,
                    shareDayKey: draft.shareDayKey,
                    revision: draft.revision,
                    generationID: draft.generationID,
                    prepareAttemptID: draft.prepareAttemptID,
                    prepareAttemptRevision: draft.prepareAttemptRevision,
                    reservedRevision: draft.reservedRevision,
                    rotationAnchorUTC: draft.rotationAnchorUTC,
                    uniqueMediaCount: draft.uniqueMediaCount,
                    manifestCiphertextSize: draft.manifestCiphertextSize,
                    manifestHash: draft.manifestCiphertextSHA256
                ) else { throw DailySharingError.stateUnavailable }
            }
        }
        for (sourceID, pending) in inboundPendingBySource {
            guard sourceID == pending.sourceID,
                  inboundHighWaterBySource[sourceID] == pending
            else { throw DailySharingError.stateUnavailable }
            _ = try pending.validated()
        }
        for (sourceID, active) in inboundActiveBySource {
            guard sourceID == active.sourceID,
                  let highWater = inboundHighWaterBySource[sourceID],
                  active.publisherMemberID == highWater.publisherMemberID,
                  active.shareDayKey <= highWater.shareDayKey,
                  active.revision <= highWater.revision
            else { throw DailySharingError.stateUnavailable }
            if active.shareDayKey == highWater.shareDayKey
                || active.revision == highWater.revision {
                guard active == highWater else { throw DailySharingError.stateUnavailable }
            }
            _ = try active.validated()
        }
        return self
    }
}

enum DailySharingStateStore {
    private static let processLock = NSLock()
    private static let syncLeaseProcessLock = NSLock()
    private static let syncLeaseDuration: TimeInterval = 90

    private struct SyncLeaseRecord: Codable {
        static let schemaVersion = 2
        var schemaVersion: Int = Self.schemaVersion
        var ownerID: String
        var spaceID: String
        var memberID: String
        var lifecycleEpoch: Int
        var expiresAt: Date

        func validated() throws -> Self {
            guard schemaVersion == Self.schemaVersion,
                   UUID(uuidString: ownerID) != nil,
                   PairingValidation.isOpaqueIdentifier(spaceID),
                   PairingValidation.isOpaqueIdentifier(memberID),
                   lifecycleEpoch > 0
            else { throw DailySharingError.stateUnavailable }
            return self
        }
    }

    final class SyncLease: @unchecked Sendable {
        fileprivate let ownerID: String
        fileprivate let spaceID: String
        fileprivate let memberID: String
        fileprivate let lifecycleEpoch: Int
        private var wasReleased = false
        private let releaseLock = NSLock()

        fileprivate init(
            ownerID: String,
            spaceID: String,
            memberID: String,
            lifecycleEpoch: Int
        ) {
            self.ownerID = ownerID
            self.spaceID = spaceID
            self.memberID = memberID
            self.lifecycleEpoch = lifecycleEpoch
        }

        /// Call immediately before and after every await. If another process
        /// took an expired lease while this process was suspended, all further
        /// file/state mutations fail closed.
        func renew() throws {
            releaseLock.lock()
            defer { releaseLock.unlock() }
            guard !wasReleased else { throw DailySharingError.stateChanged }
            try DailySharingStateStore.renewSyncLease(self)
        }

        /// Serializes one short state/ciphertext mutation with lifecycle purge.
        /// No network, PhotoKit, or other await may occur inside this closure.
        fileprivate func withValidatedMutation<Value>(
            _ operation: () throws -> Value
        ) throws -> Value {
            releaseLock.lock()
            defer { releaseLock.unlock() }
            guard !wasReleased else { throw DailySharingError.stateChanged }
            return try DailySharingStateStore.withValidatedSyncLease(
                self,
                operation: operation
            )
        }

        func release() {
            releaseLock.lock()
            guard !wasReleased else {
                releaseLock.unlock()
                return
            }
            wasReleased = true
            releaseLock.unlock()
            DailySharingStateStore.releaseSyncLease(self)
        }

        deinit { release() }
    }

    enum SyncLeaseAcquisition {
        case acquired(SyncLease)
        case busy(retryAt: Date)
    }

    /// Returns the existing lease's expiry while another process owns it. A
    /// crash leaves only a bounded record, and the caller can schedule an
    /// in-memory wake without consuming the launch/foreground trigger forever.
    static func acquireSyncLease(
        spaceID: String,
        memberID: String,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws -> SyncLeaseAcquisition {
        guard PairingValidation.isOpaqueIdentifier(spaceID),
              PairingValidation.isOpaqueIdentifier(memberID)
        else { throw DailySharingError.stateUnavailable }
        do {
            return try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
                let epoch = try SharingLifecycleGate.currentEpochWhileLocked()
                return try withSyncLeaseLock {
                    guard let url = SharedContainer.dailySharingSyncLeaseURL else {
                        throw DailySharingError.stateUnavailable
                    }
                    if FileManager.default.fileExists(atPath: url.path) {
                        do {
                            let existing = try AtomicJSON.read(
                                SyncLeaseRecord.self,
                                from: url
                            ).validated()
                            if existing.expiresAt > .now {
                                return .busy(
                                    retryAt: existing.expiresAt.addingTimeInterval(0.25)
                                )
                            }
                        } catch {
                            // A malformed/old schema lease cannot authorize a
                            // writer. Remove it only while both stable locks are held.
                        }
                        try? FileManager.default.removeItem(at: url)
                    }
                    let ownerID = UUID().uuidString.lowercased()
                    _ = try createSyncLease(
                        ownerID: ownerID,
                        spaceID: spaceID,
                        memberID: memberID,
                        lifecycleEpoch: epoch,
                        at: url
                    )
                    return .acquired(
                        SyncLease(
                            ownerID: ownerID,
                            spaceID: spaceID,
                            memberID: memberID,
                            lifecycleEpoch: epoch
                        )
                    )
                }
            }
        } catch {
            throw DailySharingError.stateUnavailable
        }
    }

#if DEBUG
    /// Shortens the live record only for the generated-data runtime gate. The
    /// production heartbeat must renew this same record before it expires;
    /// otherwise a competing acquisition succeeds and the test fails.
    static func runtimeSelfTestShortenSyncLease(
        _ lease: SyncLease,
        duration: TimeInterval
    ) throws {
        guard duration > 0, duration < syncLeaseDuration else {
            throw DailySharingError.stateUnavailable
        }
        try lease.withValidatedMutation {
            guard let url = SharedContainer.dailySharingSyncLeaseURL,
                  FileManager.default.fileExists(atPath: url.path)
            else { throw DailySharingError.stateChanged }
            var value = try AtomicJSON.read(SyncLeaseRecord.self, from: url).validated()
            guard value.ownerID == lease.ownerID,
                  value.spaceID == lease.spaceID,
                  value.memberID == lease.memberID,
                  value.lifecycleEpoch == lease.lifecycleEpoch
            else { throw DailySharingError.stateChanged }
            value.expiresAt = Date().addingTimeInterval(duration)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try writeSecurely(try encoder.encode(value), to: url)
        }
    }
#endif

    static func load(
        spaceID: String,
        memberID: String,
        lease: SyncLease
    ) throws -> DailySharingState {
        try lease.withValidatedMutation {
          try withExclusiveLock {
            guard let url = SharedContainer.dailySharingStateURL else {
                throw DailySharingError.stateUnavailable
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .empty(spaceID: spaceID, memberID: memberID)
            }
            do {
                let value = try AtomicJSON.read(DailySharingState.self, from: url).validated()
                guard value.spaceID == spaceID, value.memberID == memberID else {
                    throw DailySharingError.stateUnavailable
                }
                try? removeUnreferencedInboundDownloadDirectoriesUnlocked(state: value)
                try? removeUnreferencedInboundFinalDirectoriesUnlocked(state: value)
                try? removeUnreferencedOutboundCiphertextsUnlocked(state: value)
                return value
            } catch let error as DailySharingError {
                throw error
            } catch {
                throw DailySharingError.stateUnavailable
            }
          }
        }
    }

    @discardableResult
    static func save(
        _ state: DailySharingState,
        expectedStorageRevision: Int,
        lease: SyncLease
    ) throws -> DailySharingState {
        try lease.withValidatedMutation {
          try withExclusiveLock {
            guard let url = SharedContainer.dailySharingStateURL else {
                throw DailySharingError.stateUnavailable
            }
            let currentRevision: Int
            if FileManager.default.fileExists(atPath: url.path) {
                currentRevision = try AtomicJSON.read(DailySharingState.self, from: url)
                    .validated().storageRevision
            } else {
                currentRevision = 0
            }
            guard currentRevision == expectedStorageRevision,
                  state.storageRevision == expectedStorageRevision
            else { throw DailySharingError.stateChanged }
            var next = state
            next.storageRevision += 1
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try writeSecurely(try encoder.encode(try next.validated()), to: url)
            return next
          }
        }
    }

    static func writeOutboundCiphertext(
        _ data: Data,
        filename: String,
        lease: SyncLease
    ) throws {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              let directory = SharedContainer.sharingOutboundDirectoryURL
        else { throw DailySharingError.stateUnavailable }
        try lease.withValidatedMutation {
            try writeProtected(
                data,
                to: directory.appendingPathComponent(filename, isDirectory: false)
            )
        }
    }

    static func removeOutboundCiphertext(filename: String, lease: SyncLease) throws {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              let directory = SharedContainer.sharingOutboundDirectoryURL
        else { return }
        try lease.withValidatedMutation {
            let url = directory.appendingPathComponent(filename, isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    static func readOutboundCiphertext(
        filename: String,
        maximumBytes: Int,
        lease: SyncLease
    ) throws -> Data {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              let directory = SharedContainer.sharingOutboundDirectoryURL
        else { throw DailySharingError.stateUnavailable }
        return try lease.withValidatedMutation {
            let url = directory.appendingPathComponent(filename, isDirectory: false)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue > 0,
                  size.intValue <= maximumBytes
            else { throw DailySharingError.stateUnavailable }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count == size.intValue else { throw DailySharingError.stateUnavailable }
            return data
        }
    }

    static func beginInboundDownload(
        expectedState: DailySharingState,
        candidate: InboundDownloadDraft,
        lease: SyncLease
    ) throws -> DailySharingState {
        let candidate = try candidate.validated()
        return try lease.withValidatedMutation {
          try withExclusiveLock {
            guard let stateURL = SharedContainer.dailySharingStateURL,
                  let root = SharedContainer.sharingInboundDirectoryURL,
                  FileManager.default.fileExists(atPath: stateURL.path),
                  let staging = safeInboundChildURL(
                    named: candidate.stagingDirectoryName,
                    root: root
                  )
            else { throw DailySharingError.stateChanged }
            let disk = try AtomicJSON.read(DailySharingState.self, from: stateURL).validated()
            guard disk.storageRevision == expectedState.storageRevision,
                  disk.spaceID == expectedState.spaceID,
                  disk.memberID == expectedState.memberID
            else { throw DailySharingError.stateChanged }
            if let highWater = disk.inboundHighWaterBySource[candidate.sourceID] {
                guard highWater.accepts(
                    publisherMemberID: candidate.publisherMemberID,
                    shareDayKey: candidate.shareDayKey,
                    revision: candidate.revision,
                    generationID: candidate.generationID,
                    prepareAttemptID: candidate.prepareAttemptID,
                    prepareAttemptRevision: candidate.prepareAttemptRevision,
                    reservedRevision: candidate.reservedRevision,
                    rotationAnchorUTC: candidate.rotationAnchorUTC,
                    uniqueMediaCount: candidate.uniqueMediaCount,
                    manifestCiphertextSize: candidate.manifestCiphertextSize,
                    manifestHash: candidate.manifestCiphertextSHA256
                ) else { throw PairingError.invalidServerResponse }
            }
            if let known = disk.inboundHighWaterBySource.values.first(
                where: { $0.publisherMemberID == candidate.publisherMemberID }
            ) {
                guard known.sourceID == candidate.sourceID else {
                    throw PairingError.invalidServerResponse
                }
            }
            if let existing = disk.inboundDownloadBySource[candidate.sourceID],
               existing.matches(candidate) {
                if let final = safeInboundChildURL(
                    named: "\(existing.sourceID)-\(existing.generationID)",
                    root: root
                   ), FileManager.default.fileExists(atPath: final.path) {
                    do {
                        try removeInterruptedWriteFiles(in: final)
                        try verifyInboundDownloadDirectory(final, draft: existing)
                        // finalize may have renamed immediately before the
                        // state pointer commit. A complete exact final recovers
                        // with zero downloads; discard any redundant staging.
                        if FileManager.default.fileExists(atPath: staging.path) {
                            try FileManager.default.removeItem(at: staging)
                        }
                        return disk
                    } catch {
                        // Never merge a partial replacement with a corrupt
                        // final: reset progress and rebuild a complete staging
                        // directory. This rare path favors all-or-nothing
                        // integrity over saving a few downloads.
                        try FileManager.default.removeItem(at: final)
                        if FileManager.default.fileExists(atPath: staging.path) {
                            try FileManager.default.removeItem(at: staging)
                        }
                        try FileManager.default.createDirectory(
                            at: staging,
                            withIntermediateDirectories: true
                        )
                        try enforceProtectionAndBackupExclusion(staging)
                        var next = disk
                        next.storageRevision += 1
                        var reset = candidate
                        reset.manifestVerified = false
                        reset.completedMediaIDs = []
                        reset.startedAt = .now
                        next.inboundDownloadBySource[candidate.sourceID] = reset
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        encoder.outputFormatting = [
                            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes
                        ]
                        try writeSecurely(
                            try encoder.encode(try next.validated()),
                            to: stateURL
                        )
                        return next
                    }
                }
                try FileManager.default.createDirectory(
                    at: staging,
                    withIntermediateDirectories: true
                )
                try enforceProtectionAndBackupExclusion(staging)
                return disk
            }

            let oldStagingName = disk.inboundDownloadBySource[candidate.sourceID]?
                .stagingDirectoryName
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try enforceProtectionAndBackupExclusion(staging)
            var next = disk
            next.storageRevision += 1
            next.inboundDownloadBySource[candidate.sourceID] = candidate
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                try writeSecurely(try encoder.encode(try next.validated()), to: stateURL)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
            if let oldStagingName,
               oldStagingName != candidate.stagingDirectoryName,
               let old = safeInboundChildURL(named: oldStagingName, root: root) {
                try? FileManager.default.removeItem(at: old)
            }
            try? removeUnreferencedInboundDownloadDirectoriesUnlocked(state: next)
            return next
          }
        }
    }

    static func readInboundDraftManifest(
        _ draft: InboundDownloadDraft,
        lease: SyncLease
    ) throws -> Data? {
        try lease.withValidatedMutation {
            try readInboundDraftObject(
                draft: draft,
                filename: "manifest.enc",
                expectedSize: draft.manifestCiphertextSize,
                expectedSHA256: draft.manifestCiphertextSHA256
            )
        }
    }

    static func readInboundDraftMedia(
        _ draft: InboundDownloadDraft,
        media: InboundDownloadMedia,
        lease: SyncLease
    ) throws -> Data? {
        try lease.withValidatedMutation {
            try readInboundDraftObject(
                draft: draft,
                filename: "\(media.mediaID).enc",
                expectedSize: media.ciphertextSize,
                expectedSHA256: media.ciphertextSHA256
            )
        }
    }

    static func stageVerifiedInboundManifest(
        _ data: Data,
        expectedState: DailySharingState,
        sourceID: String,
        lease: SyncLease
    ) throws -> DailySharingState {
        try mutateInboundDraft(
            expectedState: expectedState,
            sourceID: sourceID,
            lease: lease
        ) { draft, directory in
            guard data.count == draft.manifestCiphertextSize,
                  PairingCrypto.sha256(data).base64URLEncodedString()
                    == draft.manifestCiphertextSHA256
            else { throw PairingError.invalidServerResponse }
            try writeSecurely(
                data,
                to: directory.appendingPathComponent("manifest.enc", isDirectory: false)
            )
            draft.manifestVerified = true
        }
    }

    static func stageVerifiedInboundMedia(
        _ data: Data,
        mediaID: String,
        expectedState: DailySharingState,
        sourceID: String,
        lease: SyncLease
    ) throws -> DailySharingState {
        try mutateInboundDraft(
            expectedState: expectedState,
            sourceID: sourceID,
            lease: lease
        ) { draft, directory in
            guard draft.manifestVerified,
                  let descriptor = draft.media.first(where: { $0.mediaID == mediaID }),
                  data.count == descriptor.ciphertextSize,
                  PairingCrypto.sha256(data).base64URLEncodedString()
                    == descriptor.ciphertextSHA256
            else { throw PairingError.invalidServerResponse }
            try writeSecurely(
                data,
                to: directory.appendingPathComponent("\(mediaID).enc", isDirectory: false)
            )
            if !draft.completedMediaIDs.contains(mediaID) {
                draft.completedMediaIDs.append(mediaID)
                draft.completedMediaIDs.sort()
            }
        }
    }

    static func finalizeInboundDownload(
        expectedState: DailySharingState,
        sourceID: String,
        lease: SyncLease,
        now: Date = .now
    ) throws -> DailySharingState {
        try lease.withValidatedMutation {
          try withExclusiveLock {
            guard let stateURL = SharedContainer.dailySharingStateURL,
                  let root = SharedContainer.sharingInboundDirectoryURL,
                  FileManager.default.fileExists(atPath: stateURL.path)
            else { throw DailySharingError.stateChanged }
            let disk = try AtomicJSON.read(DailySharingState.self, from: stateURL).validated()
            guard disk.storageRevision == expectedState.storageRevision,
                  disk.spaceID == expectedState.spaceID,
                  disk.memberID == expectedState.memberID,
                  let draft = disk.inboundDownloadBySource[sourceID],
                  draft.manifestVerified,
                  Set(draft.completedMediaIDs) == Set(draft.media.map(\.mediaID)),
                  let staging = safeInboundChildURL(
                    named: draft.stagingDirectoryName,
                    root: root
                  ),
                  let final = safeInboundChildURL(
                    named: "\(draft.sourceID)-\(draft.generationID)",
                    root: root
                  )
            else { throw DailySharingError.stateChanged }

            let manager = FileManager.default
            if manager.fileExists(atPath: staging.path) {
                try removeInterruptedWriteFiles(in: staging)
                try verifyInboundDownloadDirectory(staging, draft: draft)
                if manager.fileExists(atPath: final.path) {
                    do {
                        try removeInterruptedWriteFiles(in: final)
                        try verifyInboundDownloadDirectory(final, draft: draft)
                        try manager.removeItem(at: staging)
                    } catch {
                        // A fully verified staging generation is authoritative
                        // over a locally missing/corrupt same-identity final.
                        try manager.removeItem(at: final)
                        let result = staging.path.withCString { source in
                            final.path.withCString { destination in
                                Darwin.rename(source, destination)
                            }
                        }
                        guard result == 0 else { throw DailySharingError.stateUnavailable }
                    }
                } else {
                    let result = staging.path.withCString { source in
                        final.path.withCString { destination in
                            Darwin.rename(source, destination)
                        }
                    }
                    guard result == 0 else { throw DailySharingError.stateUnavailable }
                }
            } else {
                // Crash recovery after the directory rename but before the
                // state pointer commit.
                try verifyInboundDownloadDirectory(final, draft: draft)
            }

            let verified = InboundSharingHighWater(
                sourceID: draft.sourceID,
                publisherMemberID: draft.publisherMemberID,
                shareDayKey: draft.shareDayKey,
                revision: draft.revision,
                generationID: draft.generationID,
                prepareAttemptID: draft.prepareAttemptID,
                prepareAttemptRevision: draft.prepareAttemptRevision,
                reservedRevision: draft.reservedRevision,
                rotationAnchorUTC: draft.rotationAnchorUTC,
                uniqueMediaCount: draft.uniqueMediaCount,
                manifestCiphertextSize: draft.manifestCiphertextSize,
                manifestCiphertextSHA256: draft.manifestCiphertextSHA256,
                verifiedDirectoryName: final.lastPathComponent,
                verifiedAt: now
            )
            var next = disk
            next.storageRevision += 1
            next.inboundDownloadBySource.removeValue(forKey: sourceID)
            next.inboundHighWaterBySource[sourceID] = verified
            if Int(now.timeIntervalSince1970) >= verified.rotationAnchorUTC {
                next.inboundActiveBySource[sourceID] = verified
                next.inboundPendingBySource.removeValue(forKey: sourceID)
            } else {
                next.inboundPendingBySource[sourceID] = verified
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try writeSecurely(try encoder.encode(try next.validated()), to: stateURL)
            try? removeUnreferencedInboundDirectoriesUnlocked(
                root: root,
                sourceID: sourceID,
                keepingDirectoryNames: referencedInboundDirectoryNames(in: next, sourceID: sourceID)
            )
            try? removeUnreferencedInboundDownloadDirectoriesUnlocked(state: next)
            return next
          }
        }
    }

    private static func mutateInboundDraft(
        expectedState: DailySharingState,
        sourceID: String,
        lease: SyncLease,
        mutation: (inout InboundDownloadDraft, URL) throws -> Void
    ) throws -> DailySharingState {
        try lease.withValidatedMutation {
          try withExclusiveLock {
            guard let stateURL = SharedContainer.dailySharingStateURL,
                  let root = SharedContainer.sharingInboundDirectoryURL,
                  FileManager.default.fileExists(atPath: stateURL.path)
            else { throw DailySharingError.stateChanged }
            let disk = try AtomicJSON.read(DailySharingState.self, from: stateURL).validated()
            guard disk.storageRevision == expectedState.storageRevision,
                  disk.spaceID == expectedState.spaceID,
                  disk.memberID == expectedState.memberID,
                  var draft = disk.inboundDownloadBySource[sourceID],
                  let directory = safeInboundChildURL(
                    named: draft.stagingDirectoryName,
                    root: root
                  )
            else { throw DailySharingError.stateChanged }
            try mutation(&draft, directory)
            var next = disk
            next.storageRevision += 1
            next.inboundDownloadBySource[sourceID] = try draft.validated()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try writeSecurely(try encoder.encode(try next.validated()), to: stateURL)
            return next
          }
        }
    }

    private static func readInboundDraftObject(
        draft: InboundDownloadDraft,
        filename: String,
        expectedSize: Int,
        expectedSHA256: String
    ) throws -> Data? {
        guard let root = SharedContainer.sharingInboundDirectoryURL,
              let directory = safeInboundChildURL(named: draft.stagingDirectoryName, root: root),
              filename == URL(fileURLWithPath: filename).lastPathComponent
        else { throw DailySharingError.stateUnavailable }
        var url = directory.appendingPathComponent(filename, isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path),
           let final = safeInboundChildURL(
            named: "\(draft.sourceID)-\(draft.generationID)",
            root: root
           ) {
            url = final.appendingPathComponent(filename, isDirectory: false)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue == expectedSize else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == expectedSize,
              PairingCrypto.sha256(data).base64URLEncodedString() == expectedSHA256
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return data
    }

    private static func removeInterruptedWriteFiles(in directory: URL) throws {
        for value in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) where value.lastPathComponent.hasPrefix(".sharing-secure-")
            || value.lastPathComponent.hasPrefix(".partial-") {
            try? FileManager.default.removeItem(at: value)
        }
    }

    private static func verifyInboundDownloadDirectory(
        _ directory: URL,
        draft: InboundDownloadDraft
    ) throws {
        var expected: [String: (Int, String)] = [
            "manifest.enc": (draft.manifestCiphertextSize, draft.manifestCiphertextSHA256)
        ]
        for media in draft.media {
            expected["\(media.mediaID).enc"] = (media.ciphertextSize, media.ciphertextSHA256)
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        guard Set(files.map(\.lastPathComponent)) == Set(expected.keys) else {
            throw DailySharingError.stateUnavailable
        }
        for file in files {
            guard let descriptor = expected[file.lastPathComponent],
                  let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size == descriptor.0
            else { throw DailySharingError.stateUnavailable }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard PairingCrypto.sha256(data).base64URLEncodedString() == descriptor.1 else {
                throw PairingError.invalidServerResponse
            }
        }
    }

    static func adoptVerifiedInbound(
        expectedState: DailySharingState,
        sourceID: String,
        publisherMemberID: String,
        shareDayKey: Int,
        revision: Int,
        generationID: String,
        prepareAttemptID: String,
        prepareAttemptRevision: Int,
        reservedRevision: Int,
        rotationAnchorUTC: Int,
        uniqueMediaCount: Int,
        manifestCiphertextSize: Int,
        manifestCiphertextSHA256: String,
        manifestCiphertext: Data,
        mediaCiphertexts: [(mediaID: String, data: Data)],
        lease: SyncLease,
        now: Date = .now
    ) throws -> DailySharingState {
        try lease.withValidatedMutation {
          try withExclusiveLock {
            guard let stateURL = SharedContainer.dailySharingStateURL,
                  FileManager.default.fileExists(atPath: stateURL.path)
            else { throw DailySharingError.stateChanged }
            let disk = try AtomicJSON.read(DailySharingState.self, from: stateURL).validated()
            guard disk.storageRevision == expectedState.storageRevision,
                  disk.spaceID == expectedState.spaceID,
                  disk.memberID == expectedState.memberID
            else { throw DailySharingError.stateChanged }
            if let existingSource = disk.inboundHighWaterBySource.values.first(
                where: { $0.publisherMemberID == publisherMemberID }
            ) {
                guard existingSource.sourceID == sourceID else {
                    throw PairingError.invalidServerResponse
                }
            }
            if publisherMemberID == disk.memberID,
               let ownSourceID = disk.ownSourceID {
                guard ownSourceID == sourceID else {
                    throw PairingError.invalidServerResponse
                }
            }
            if let highWater = disk.inboundHighWaterBySource[sourceID] {
                guard highWater.accepts(
                    publisherMemberID: publisherMemberID,
                    shareDayKey: shareDayKey,
                    revision: revision,
                    generationID: generationID,
                    prepareAttemptID: prepareAttemptID,
                    prepareAttemptRevision: prepareAttemptRevision,
                    reservedRevision: reservedRevision,
                    rotationAnchorUTC: rotationAnchorUTC,
                    uniqueMediaCount: uniqueMediaCount,
                    manifestCiphertextSize: manifestCiphertextSize,
                    manifestHash: manifestCiphertextSHA256
                ) else { throw PairingError.invalidServerResponse }
            }

            let staged = try stageVerifiedInboundUnlocked(
                sourceID: sourceID,
                generationID: generationID,
                manifestCiphertext: manifestCiphertext,
                mediaCiphertexts: mediaCiphertexts
            )
            do {
                var next = disk
                next.storageRevision += 1
                let verified = InboundSharingHighWater(
                    sourceID: sourceID,
                    publisherMemberID: publisherMemberID,
                    shareDayKey: shareDayKey,
                    revision: revision,
                    generationID: generationID,
                    prepareAttemptID: prepareAttemptID,
                    prepareAttemptRevision: prepareAttemptRevision,
                    reservedRevision: reservedRevision,
                    rotationAnchorUTC: rotationAnchorUTC,
                    uniqueMediaCount: uniqueMediaCount,
                    manifestCiphertextSize: manifestCiphertextSize,
                    manifestCiphertextSHA256: manifestCiphertextSHA256,
                    verifiedDirectoryName: staged.directoryName,
                    verifiedAt: now
                )
                next.inboundHighWaterBySource[sourceID] = verified
                if Int(now.timeIntervalSince1970) >= rotationAnchorUTC {
                    next.inboundActiveBySource[sourceID] = verified
                    next.inboundPendingBySource.removeValue(forKey: sourceID)
                } else {
                    next.inboundPendingBySource[sourceID] = verified
                }
                guard inboundDirectoryExists(named: staged.directoryName) else {
                    throw DailySharingError.stateUnavailable
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try writeSecurely(try encoder.encode(try next.validated()), to: stateURL)
                // The pointer is now durable. Superseded cleanup is best
                // effort; failure must never roll the pointer back or remove
                // the newly referenced directory.
                try? removeUnreferencedInboundDirectoriesUnlocked(
                    root: staged.root,
                    sourceID: sourceID,
                    keepingDirectoryNames: referencedInboundDirectoryNames(
                        in: next,
                        sourceID: sourceID
                    )
                )
                return next
            } catch {
                if staged.created {
                    try? FileManager.default.removeItem(at: staged.finalDirectory)
                }
                throw error
            }
          }
        }
    }

    /// Promotes only due verified generations. Download and presentation are
    /// separate transactions so a future anchor can never replace the current
    /// window early. The Widget may call this same method in Phase 3.
    static func activateDueInbound(
        expectedState: DailySharingState,
        lease: SyncLease,
        now: Date
    ) throws -> DailySharingState {
        try lease.withValidatedMutation {
          try withExclusiveLock {
            guard let stateURL = SharedContainer.dailySharingStateURL,
                  FileManager.default.fileExists(atPath: stateURL.path)
            else { throw DailySharingError.stateChanged }
            let disk = try AtomicJSON.read(DailySharingState.self, from: stateURL).validated()
            guard disk.storageRevision == expectedState.storageRevision,
                  disk.spaceID == expectedState.spaceID,
                  disk.memberID == expectedState.memberID
            else { throw DailySharingError.stateChanged }
            let unix = Int(now.timeIntervalSince1970)
            let due = disk.inboundPendingBySource.filter {
                $0.value.rotationAnchorUTC <= unix
            }
            guard !due.isEmpty else { return disk }
            var next = disk
            next.storageRevision += 1
            for (sourceID, value) in due {
                if inboundDirectoryExists(named: value.verifiedDirectoryName) {
                    next.inboundActiveBySource[sourceID] = value
                }
                // A missing verified directory can result from storage pressure
                // or a prior interrupted cleanup. Drop only the presentation
                // pointer. The anti-rollback high-water remains, and the same
                // pass may download the exact authenticated current generation
                // again and restage it without exposing anything early.
                next.inboundPendingBySource.removeValue(forKey: sourceID)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try writeSecurely(try encoder.encode(try next.validated()), to: stateURL)
            if let root = SharedContainer.sharingInboundDirectoryURL {
                for sourceID in due.keys {
                    try? removeUnreferencedInboundDirectoriesUnlocked(
                        root: root,
                        sourceID: sourceID,
                        keepingDirectoryNames: referencedInboundDirectoryNames(
                            in: next,
                            sourceID: sourceID
                        )
                    )
                }
            }
            try? removeUnreferencedInboundDownloadDirectoriesUnlocked(state: next)
            return next
          }
        }
    }

    /// An authenticated source response with `current == nil` is the server's
    /// retention signal. Remove only presentation pointers and ciphertext;
    /// retain the opaque high-water descriptor so an older generation cannot
    /// later be replayed as current.
    static func expireInboundPresentation(
        expectedState: DailySharingState,
        sourceID: String,
        lease: SyncLease
    ) throws -> DailySharingState {
        try lease.withValidatedMutation {
          try withExclusiveLock {
            guard PairingValidation.isOpaqueIdentifier(sourceID),
                  let stateURL = SharedContainer.dailySharingStateURL,
                  FileManager.default.fileExists(atPath: stateURL.path)
            else { throw DailySharingError.stateChanged }
            let disk = try AtomicJSON.read(DailySharingState.self, from: stateURL).validated()
            guard disk.storageRevision == expectedState.storageRevision,
                  disk.spaceID == expectedState.spaceID,
                  disk.memberID == expectedState.memberID
            else { throw DailySharingError.stateChanged }

            let expiredDirectories = Set([
                disk.inboundPendingBySource[sourceID]?.verifiedDirectoryName,
                disk.inboundActiveBySource[sourceID]?.verifiedDirectoryName,
                disk.inboundDownloadBySource[sourceID]?.stagingDirectoryName
            ].compactMap { $0 })
            guard !expiredDirectories.isEmpty else { return disk }

            var next = disk
            next.storageRevision += 1
            next.inboundPendingBySource.removeValue(forKey: sourceID)
            next.inboundActiveBySource.removeValue(forKey: sourceID)
            next.inboundDownloadBySource.removeValue(forKey: sourceID)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try writeSecurely(try encoder.encode(try next.validated()), to: stateURL)

            if let root = SharedContainer.sharingInboundDirectoryURL {
                for directoryName in expiredDirectories {
                    if let url = safeInboundChildURL(named: directoryName, root: root) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            return next
          }
        }
    }

    private static func stageVerifiedInboundUnlocked(
        sourceID: String,
        generationID: String,
        manifestCiphertext: Data,
        mediaCiphertexts: [(mediaID: String, data: Data)]
    ) throws -> (
        directoryName: String,
        root: URL,
        finalDirectory: URL,
        created: Bool
    ) {
        guard PairingValidation.isOpaqueIdentifier(sourceID),
              PairingValidation.isOpaqueIdentifier(generationID),
              (DailySharingProtocol.chachaCombinedOverheadBytes + 1 ... DailySharingProtocol.maximumManifestCiphertextBytes)
                .contains(manifestCiphertext.count),
              !mediaCiphertexts.isEmpty,
              mediaCiphertexts.count <= DailySharingProtocol.maximumSlotCount,
              Set(mediaCiphertexts.map(\.mediaID)).count == mediaCiphertexts.count,
              mediaCiphertexts.allSatisfy({
                  Data(base64URLString: $0.mediaID)?.count == 16
                    && (DailySharingProtocol.chachaCombinedOverheadBytes + 1 ... DailySharingProtocol.maximumMediaCiphertextBytes)
                        .contains($0.data.count)
              }),
              let root = SharedContainer.sharingInboundDirectoryURL
        else { throw DailySharingError.stateUnavailable }

        let directoryName = "\(sourceID)-\(generationID)"
        guard let finalDirectory = safeInboundChildURL(named: directoryName, root: root)
        else { throw DailySharingError.stateUnavailable }
        let stagingDirectory = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staleCutoff = Date().addingTimeInterval(-60 * 60)
        for stale in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        ) where stale.lastPathComponent.hasPrefix(".staging-") {
            let values = try? stale.resourceValues(forKeys: [.contentModificationDateKey])
            if let modifiedAt = values?.contentModificationDate,
               modifiedAt < staleCutoff {
                try? FileManager.default.removeItem(at: stale)
            }
        }
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        do {
            try writeProtected(
                manifestCiphertext,
                to: stagingDirectory.appendingPathComponent("manifest.enc", isDirectory: false)
            )
            for media in mediaCiphertexts {
                try writeProtected(
                    media.data,
                    to: stagingDirectory.appendingPathComponent("\(media.mediaID).enc", isDirectory: false)
                )
            }
            if FileManager.default.fileExists(atPath: finalDirectory.path) {
                try verifyExistingInboundDirectory(
                    finalDirectory,
                    manifestCiphertext: manifestCiphertext,
                    mediaCiphertexts: mediaCiphertexts
                )
                try FileManager.default.removeItem(at: stagingDirectory)
                try enforceProtectionAndBackupExclusion(finalDirectory)
                return (directoryName, root, finalDirectory, false)
            } else {
                try FileManager.default.moveItem(at: stagingDirectory, to: finalDirectory)
            }
            try enforceProtectionAndBackupExclusion(finalDirectory)
            return (directoryName, root, finalDirectory, true)
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }
    }

    static func inboundDirectoryExists(named value: String) -> Bool {
        guard let root = SharedContainer.sharingInboundDirectoryURL,
              let url = safeInboundChildURL(named: value, root: root)
        else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Reads one object from an adopted exact-identity generation. The caller
    /// supplies the descriptor obtained from the authenticated/decrypted
    /// manifest. `nil` means local loss/corruption and must disable ETag/304 so
    /// the current generation can be rebuilt from the server.
    static func readVerifiedInboundObject(
        highWater: InboundSharingHighWater,
        filename: String,
        expectedSize: Int,
        expectedSHA256: String,
        lease: SyncLease
    ) throws -> Data? {
        let highWater = try highWater.validated()
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename != ".",
              filename != "..",
              expectedSize > 0,
              expectedSize <= DailySharingProtocol.maximumMediaCiphertextBytes,
              Data(base64URLString: expectedSHA256)?.count == 32,
              let root = SharedContainer.sharingInboundDirectoryURL,
              let directory = safeInboundChildURL(
                named: highWater.verifiedDirectoryName,
                root: root
              )
        else { throw DailySharingError.stateUnavailable }
        return try lease.withValidatedMutation {
            let url = directory.appendingPathComponent(filename, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path),
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size == expectedSize
            else { return nil }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count == expectedSize,
                  PairingCrypto.sha256(data).base64URLEncodedString() == expectedSHA256
            else { return nil }
            return data
        }
    }

    static func verifiedInboundDirectoryHasExactFileSet(
        highWater: InboundSharingHighWater,
        expectedFilenames: Set<String>,
        lease: SyncLease
    ) throws -> Bool {
        let highWater = try highWater.validated()
        guard !expectedFilenames.isEmpty,
              expectedFilenames.allSatisfy({
                  $0 == URL(fileURLWithPath: $0).lastPathComponent
                    && $0 != "." && $0 != ".."
              }),
              let root = SharedContainer.sharingInboundDirectoryURL,
              let directory = safeInboundChildURL(
                named: highWater.verifiedDirectoryName,
                root: root
              )
        else { throw DailySharingError.stateUnavailable }
        return try lease.withValidatedMutation {
            guard FileManager.default.fileExists(atPath: directory.path) else { return false }
            let values = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
            return Set(values.map(\.lastPathComponent)) == expectedFilenames
        }
    }

    private static func removeSupersededInboundDirectories(
        sourceID: String,
        keepingDirectoryName: String
    ) throws {
        guard PairingValidation.isOpaqueIdentifier(sourceID),
              let root = SharedContainer.sharingInboundDirectoryURL,
              safeInboundChildURL(named: keepingDirectoryName, root: root) != nil,
              FileManager.default.fileExists(atPath: root.path)
        else { return }
        try removeUnreferencedInboundDirectoriesUnlocked(
            root: root,
            sourceID: sourceID,
            keepingDirectoryNames: [keepingDirectoryName]
        )
    }

    private static func removeUnreferencedInboundDirectoriesUnlocked(
        root: URL,
        sourceID: String,
        keepingDirectoryNames: Set<String>
    ) throws {
        let prefix = "\(sourceID)-"
        for url in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) where url.lastPathComponent.hasPrefix(prefix)
            && !keepingDirectoryNames.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func removeUnreferencedInboundDownloadDirectoriesUnlocked(
        state: DailySharingState
    ) throws {
        guard let root = SharedContainer.sharingInboundDirectoryURL,
              FileManager.default.fileExists(atPath: root.path)
        else { return }
        let referenced = Set(
            state.inboundDownloadBySource.values.map(\.stagingDirectoryName)
        )
        for child in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) where child.lastPathComponent.hasPrefix(".download-")
            && !referenced.contains(child.lastPathComponent) {
            guard let safe = safeInboundChildURL(named: child.lastPathComponent, root: root),
                  safe == child.standardizedFileURL
            else { continue }
            try? FileManager.default.removeItem(at: safe)
        }
    }

    private static func referencedInboundDirectoryNames(
        in state: DailySharingState,
        sourceID: String
    ) -> Set<String> {
        var values = Set<String>()
        if let value = state.inboundPendingBySource[sourceID] {
            values.insert(value.verifiedDirectoryName)
        }
        if let value = state.inboundActiveBySource[sourceID] {
            values.insert(value.verifiedDirectoryName)
        }
        return values
    }

    private static func removeUnreferencedInboundFinalDirectoriesUnlocked(
        state: DailySharingState
    ) throws {
        guard let root = SharedContainer.sharingInboundDirectoryURL,
              FileManager.default.fileExists(atPath: root.path)
        else { return }
        let referenced = Set(
            state.inboundPendingBySource.values.map(\.verifiedDirectoryName)
                + state.inboundActiveBySource.values.map(\.verifiedDirectoryName)
                + state.inboundDownloadBySource.values.compactMap { draft in
                    guard draft.manifestVerified,
                          Set(draft.completedMediaIDs) == Set(draft.media.map(\.mediaID))
                    else { return nil }
                    return "\(draft.sourceID)-\(draft.generationID)"
                }
        )
        for child in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) where !child.lastPathComponent.hasPrefix(".")
            && !referenced.contains(child.lastPathComponent) {
            guard let safe = safeInboundChildURL(named: child.lastPathComponent, root: root),
                  safe == child.standardizedFileURL
            else { continue }
            try? FileManager.default.removeItem(at: safe)
        }
    }

    private static func removeUnreferencedOutboundCiphertextsUnlocked(
        state: DailySharingState
    ) throws {
        guard let root = SharedContainer.sharingOutboundDirectoryURL,
              FileManager.default.fileExists(atPath: root.path)
        else { return }
        var referenced = Set<String>()
        for item in state.outbound?.media ?? [] {
            if let filename = item.ciphertextFilename { referenced.insert(filename) }
        }
        if let filename = state.outbound?.prepare?.manifestCiphertextFilename {
            referenced.insert(filename)
        }
        for child in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) where !referenced.contains(child.lastPathComponent) {
            let standardizedRoot = root.standardizedFileURL
            let safe = standardizedRoot
                .appendingPathComponent(child.lastPathComponent, isDirectory: false)
                .standardizedFileURL
            guard safe.deletingLastPathComponent() == standardizedRoot,
                  safe == child.standardizedFileURL
            else { continue }
            try? FileManager.default.removeItem(at: safe)
        }
    }

    private static func safeInboundChildURL(named value: String, root: URL) -> URL? {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              value == URL(fileURLWithPath: value).lastPathComponent
        else { return nil }
        let standardizedRoot = root.standardizedFileURL
        let child = standardizedRoot.appendingPathComponent(value, isDirectory: true)
            .standardizedFileURL
        guard child.deletingLastPathComponent() == standardizedRoot else { return nil }
        return child
    }

    static func removeOutboundCiphertexts(
        for generationID: String,
        lease: SyncLease
    ) throws {
        guard PairingValidation.isOpaqueIdentifier(generationID),
              let root = SharedContainer.sharingOutboundDirectoryURL,
              FileManager.default.fileExists(atPath: root.path)
        else { return }
        try lease.withValidatedMutation {
            let prefix = "\(generationID)-"
            for url in try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) where url.lastPathComponent.hasPrefix(prefix) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func writeProtected(_ data: Data, to url: URL) throws {
        try writeSecurely(data, to: url)
    }

    /// Security metadata is applied and read back on a sibling temporary file
    /// before that inode atomically replaces the live path. A failed metadata
    /// gate therefore cannot advance the visible state revision.
    private static func writeSecurely(_ data: Data, to url: URL) throws {
        do {
            try SharingSecureFile.write(data, to: url)
        } catch {
            throw DailySharingError.stateUnavailable
        }
    }

    private static func enforceProtectionAndBackupExclusion(_ url: URL) throws {
        do {
            try SharingSecureFile.enforceProtectionAndBackupExclusion(url)
        } catch {
            throw DailySharingError.stateUnavailable
        }
    }

    private static func verifyExistingInboundDirectory(
        _ directory: URL,
        manifestCiphertext: Data,
        mediaCiphertexts: [(mediaID: String, data: Data)]
    ) throws {
        var expected: [String: Data] = ["manifest.enc": manifestCiphertext]
        for media in mediaCiphertexts { expected["\(media.mediaID).enc"] = media.data }
        let existing = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        guard Set(existing.map(\.lastPathComponent)) == Set(expected.keys) else {
            throw DailySharingError.stateUnavailable
        }
        for url in existing {
            guard let expectedData = expected[url.lastPathComponent] else {
                throw DailySharingError.stateUnavailable
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard values.fileSize == expectedData.count,
                  PairingCrypto.sha256(try Data(contentsOf: url, options: .mappedIfSafe))
                    == PairingCrypto.sha256(expectedData)
            else { throw DailySharingError.stateUnavailable }
        }
    }

    private static func withExclusiveLock<Value>(
        _ operation: () throws -> Value
    ) throws -> Value {
        processLock.lock()
        defer { processLock.unlock() }
        guard let lockURL = SharedContainer.dailySharingLockURL else {
            throw DailySharingError.stateUnavailable
        }
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw DailySharingError.stateUnavailable }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw DailySharingError.stateUnavailable
        }
        defer { flock(descriptor, LOCK_UN) }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: lockURL.path
        )
        return try operation()
    }

    private static func createSyncLease(
        ownerID: String,
        spaceID: String,
        memberID: String,
        lifecycleEpoch: Int,
        at url: URL
    ) throws -> Bool {
        let value = SyncLeaseRecord(
            ownerID: ownerID,
            spaceID: spaceID,
            memberID: memberID,
            lifecycleEpoch: lifecycleEpoch,
            expiresAt: Date().addingTimeInterval(syncLeaseDuration)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try writeSecurely(try encoder.encode(value), to: url)
        return true
    }

    private static func renewSyncLease(_ lease: SyncLease) throws {
        _ = try withValidatedSyncLease(lease) { () }
    }

    private static func withValidatedSyncLease<Value>(
        _ lease: SyncLease,
        operation: () throws -> Value
    ) throws -> Value {
        do {
            return try SharingLifecycleGate.withExclusive {
                guard !SharingLifecycleGate.isCleanupRequired,
                      try SharingLifecycleGate.currentEpochWhileLocked()
                        == lease.lifecycleEpoch
                else { throw DailySharingError.stateChanged }
                return try withSyncLeaseLock {
                    guard let url = SharedContainer.dailySharingSyncLeaseURL,
                          FileManager.default.fileExists(atPath: url.path)
                    else { throw DailySharingError.stateChanged }
                    var value = try AtomicJSON.read(
                        SyncLeaseRecord.self,
                        from: url
                    ).validated()
                    guard value.ownerID == lease.ownerID,
                          value.spaceID == lease.spaceID,
                          value.memberID == lease.memberID,
                          value.lifecycleEpoch == lease.lifecycleEpoch,
                          value.expiresAt > .now
                    else { throw DailySharingError.stateChanged }
                    // Extending the bounded record while the short lifecycle
                    // lock is held makes this mutation/heartbeat the new lease
                    // authority. A suspended process cannot revive an expiry.
                    value.expiresAt = Date().addingTimeInterval(syncLeaseDuration)
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    try writeSecurely(try encoder.encode(value), to: url)
                    return try operation()
                }
            }
        } catch let error as DailySharingError {
            throw error
        } catch {
            throw DailySharingError.stateChanged
        }
    }

    private static func releaseSyncLease(_ lease: SyncLease) {
        try? SharingLifecycleGate.withExclusive {
            try withSyncLeaseLock {
                guard let url = SharedContainer.dailySharingSyncLeaseURL,
                      FileManager.default.fileExists(atPath: url.path),
                      let value = try? AtomicJSON.read(
                        SyncLeaseRecord.self,
                        from: url
                      ).validated(),
                      value.ownerID == lease.ownerID,
                      value.lifecycleEpoch == lease.lifecycleEpoch
                else { return }
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Called only while the stable lifecycle flock is held and immediately
    /// after the epoch has been bumped. Removing the logical lease wakes the
    /// next process after cleanup while every old owner fails its epoch check.
    static func revokeAllSyncLeasesWhileLifecycleLocked() throws {
        try withSyncLeaseLock {
            guard let url = SharedContainer.dailySharingSyncLeaseURL else {
                throw DailySharingError.stateUnavailable
            }
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func withSyncLeaseLock<Value>(
        _ operation: () throws -> Value
    ) throws -> Value {
        syncLeaseProcessLock.lock()
        defer { syncLeaseProcessLock.unlock() }
        guard let lockURL = SharedContainer.dailySharingSyncLeaseLockURL else {
            throw DailySharingError.stateUnavailable
        }
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw DailySharingError.stateUnavailable }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw DailySharingError.stateUnavailable
        }
        defer { flock(descriptor, LOCK_UN) }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: lockURL.path
        )
        return try operation()
    }
}

enum DailyManifestFreezer {
    static func freeze(
        _ manifest: WidgetManifest,
        localDayKey: Int,
        now: Date
    ) throws -> OutboundSharingGeneration {
        let slots = Array(manifest.items.prefix(DailySharingProtocol.maximumSlotCount))
        guard !slots.isEmpty, (0...10_000_000).contains(localDayKey) else {
            throw DailySharingError.invalidLocalManifest
        }

        var mediaByLocalIdentifier: [String: FrozenSharingMedia] = [:]
        var slotMediaIDs: [String] = []
        for item in slots {
            guard item.rendererVersion == DailySharingProtocol.rendererVersion,
                  let sourcePixelSize = item.sourcePixelSize,
                  sourcePixelSize.isValid,
                  let plans = item.renderPlans,
                  plans.allAreValid
            else { throw DailySharingError.invalidLocalManifest }
            let frozen: FrozenSharingMedia
            if let existing = mediaByLocalIdentifier[item.localIdentifier] {
                guard existing.sourceModificationDate == item.sourceModificationDate,
                      existing.sourcePixelSize == sourcePixelSize,
                      existing.renderPlans == plans
                else { throw DailySharingError.invalidLocalManifest }
                frozen = existing
            } else {
                frozen = FrozenSharingMedia(
                    mediaID: PairingCrypto.randomData(count: 16).base64URLEncodedString(),
                    localIdentifier: item.localIdentifier,
                    sourceModificationDate: item.sourceModificationDate,
                    sourcePixelSize: sourcePixelSize,
                    renderPlans: plans
                )
                mediaByLocalIdentifier[item.localIdentifier] = frozen
            }
            slotMediaIDs.append(frozen.mediaID)
        }
        let media = mediaByLocalIdentifier.values
            .sorted { $0.mediaID < $1.mediaID }
            .map { StagedSharingMedia(frozen: $0) }
        return try OutboundSharingGeneration(
            phase: .frozen,
            localDayKey: localDayKey,
            frozenAt: now,
            sourceManifestGeneratedAt: manifest.generatedAt,
            reserveClientRequestID: UUID().uuidString.lowercased(),
            slotMediaIDs: slotMediaIDs,
            media: media
        ).validated()
    }
}
