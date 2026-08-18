import CryptoKit
import Foundation

struct JSONExporter {
    func export(
        _ snapshot: LibrarySnapshot,
        curation: CatCandidateCurationState = .empty
    ) throws -> URL {
        let exportedAt = Date.now
        let likeMeasurement = try SharedLikeStore.measurementSnapshot()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "neko-widget-\(formatter.string(from: exportedAt)).json"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename, isDirectory: false)
        try AtomicJSON.write(
            VerificationExportPayload(
                snapshot: snapshot,
                exportedAt: exportedAt,
                likeMeasurement: likeMeasurement,
                curation: curation
            ),
            to: url
        )
        return url
    }
}

/// Keeps the existing `LibrarySnapshot` keys at the JSON root and adds
/// export-only review and measurement fields. Older tooling can decode it as a
/// `LibrarySnapshot`, because `JSONDecoder` ignores unknown keys by default.
private struct VerificationExportPayload: Encodable {
    var snapshot: LibrarySnapshot
    var detectionAccuracySample: DetectionAccuracySample
    var likeMeasurement: LikeMeasurementExport
    var catCandidateCuration: CatCandidateCurationExportSummary

    init(
        snapshot: LibrarySnapshot,
        exportedAt: Date,
        likeMeasurement: SharedLikeMeasurementSnapshot,
        curation: CatCandidateCurationState
    ) {
        self.snapshot = snapshot
        detectionAccuracySample = DetectionAccuracySample(
            selection: DetectionAccuracySampler.sample(from: snapshot),
            generatedAt: exportedAt
        )
        self.likeMeasurement = LikeMeasurementExport(snapshot: likeMeasurement)
        catCandidateCuration = CatCandidateCurationExportSummary(state: curation)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case assets
        case scanState
        case settings
        case albumLocalIdentifier
        case albumUsage
        case catLifeReferenceConfigured
        case updatedAt
        case detectionAccuracySample
        case likeMeasurement
        case catCandidateCuration
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(snapshot.schemaVersion, forKey: .schemaVersion)
        try container.encode(snapshot.assets, forKey: .assets)
        try container.encode(snapshot.scanState, forKey: .scanState)
        // The optional birthday/adoption day is needed only on this device to
        // group memories. Keep the exact date out of a shareable verification
        // export while still recording whether age-based grouping was active.
        var exportSettings = snapshot.settings
        let catLifeReferenceConfigured = exportSettings.catLifeReference != nil
        exportSettings.catLifeReference = nil
        try container.encode(exportSettings, forKey: .settings)
        try container.encodeIfPresent(
            snapshot.albumLocalIdentifier,
            forKey: .albumLocalIdentifier
        )
        try container.encodeIfPresent(snapshot.albumUsage, forKey: .albumUsage)
        try container.encode(
            catLifeReferenceConfigured,
            forKey: .catLifeReferenceConfigured
        )
        try container.encode(snapshot.updatedAt, forKey: .updatedAt)
        try container.encode(detectionAccuracySample, forKey: .detectionAccuracySample)
        try container.encode(likeMeasurement, forKey: .likeMeasurement)
        try container.encode(catCandidateCuration, forKey: .catCandidateCuration)
    }
}

/// Rotation-proof product-measurement evidence. The private local identifiers
/// already exist in the root asset array; photo bytes are never embedded.
private struct LikeMeasurementExport: Encodable {
    var schemaVersion = 2
    var containsPhotoData = false
    var experimentStatus = "withdrawn"
    var withdrawnOn = "2026-08-17"
    var eligibleForProductDecision = false
    var startedAt: Date?
    var baselineLikedCount: Int
    var eventCount: Int
    var retentionDays: Int
    var maximumEventCount: Int
    var droppedEventCount: Int
    var historyIsComplete: Bool
    var events: [LikeMeasurementEventExport]

    init(snapshot: SharedLikeMeasurementSnapshot) {
        startedAt = snapshot.startedAt
        baselineLikedCount = snapshot.baselineLikedCount
        eventCount = snapshot.events.count
        retentionDays = snapshot.retentionDays
        maximumEventCount = snapshot.maximumEventCount
        droppedEventCount = snapshot.droppedEventCount
        // A complete on-disk ledger is not a completed experiment. The
        // one-week run was withdrawn before a valid product measurement ended.
        historyIsComplete = false
        events = snapshot.events.map { LikeMeasurementEventExport(event: $0) }
    }
}

private struct LikeMeasurementEventExport: Encodable {
    var id: String
    var sequence: Int
    var localIdentifier: String
    var assetToken: String
    var previousIsLiked: Bool
    var isLiked: Bool
    var changedAt: Date
    var changedAtEpochMilliseconds: Int64
    var source: String

    init(event: SharedLikeEvent) {
        id = event.id
        sequence = event.sequence
        localIdentifier = event.localIdentifier
        assetToken = SharedLog.shortHash(event.localIdentifier)
        previousIsLiked = event.previousIsLiked
        isLiked = event.isLiked
        changedAt = event.changedAt
        changedAtEpochMilliseconds = event.changedAtEpochMilliseconds
        source = event.source
    }
}

/// One ranked machine-positive used by both the JSON export and the in-app
/// review screen. `AssetRecord` remains on the core side of AppRootView's
/// core-to-presentation boundary and is never passed into a SwiftUI view.
struct DetectionAccuracySampleSelectionItem: Sendable {
    var reviewNumber: Int
    var selectionDigest: String
    var record: AssetRecord
}

/// The single source of truth for the deterministic 100-photo review queue.
/// Hash-ranking produces an unbiased, reproducible subset without relying on
/// PhotoKit enumeration order. Human labels remain outside the application.
struct DetectionAccuracySampleSelection: Sendable {
    var snapshotIsFinal: Bool
    var analysisFingerprint: String
    var populationDefinition: String
    var sampleSeed: String
    var sampleAlgorithm: String
    var requestedSampleCount: Int
    var populationCount: Int
    var items: [DetectionAccuracySampleSelectionItem]
}

enum DetectionAccuracySampler {
    static let requestedCount = 100
    private static let algorithm = "sha256-lexicographic-rank-v1"

    static func isFinal(_ snapshot: LibrarySnapshot) -> Bool {
        snapshot.scanState.phase == .completed
            && snapshot.scanState.resultKind == .final
            && !snapshot.scanState.requiresFullRescan
            && snapshot.scanState.scannedAssets == snapshot.scanState.totalAssets
    }

    static func sample(from snapshot: LibrarySnapshot) -> DetectionAccuracySampleSelection {
        let fingerprint = snapshot.settings.analysisFingerprint
        let seed = "neko-widget-detected-precision-v1|\(fingerprint)"
        let population = snapshot.assets.filter {
            $0.analysisFingerprint == fingerprint
                && $0.analysisStatus == .detected
                && $0.cat.detected
        }
        let ranked = population
            .map { record in
                (
                    record: record,
                    digest: selectionDigest(
                        seed: seed,
                        localIdentifier: record.localIdentifier
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.digest != rhs.digest { return lhs.digest < rhs.digest }
                return lhs.record.localIdentifier < rhs.record.localIdentifier
            }

        return DetectionAccuracySampleSelection(
            snapshotIsFinal: isFinal(snapshot),
            analysisFingerprint: fingerprint,
            populationDefinition: "analysisFingerprint == settings.analysisFingerprint && analysisStatus == detected && cat.detected == true",
            sampleSeed: seed,
            sampleAlgorithm: "\(algorithm): sort ascending SHA256(UTF8(seed) + 0x00 + UTF8(localIdentifier)); break digest ties by localIdentifier",
            requestedSampleCount: requestedCount,
            populationCount: population.count,
            items: ranked.prefix(requestedCount).enumerated().map { offset, rankedRecord in
                DetectionAccuracySampleSelectionItem(
                    reviewNumber: offset + 1,
                    selectionDigest: rankedRecord.digest,
                    record: rankedRecord.record
                )
            }
        )
    }

    private static func selectionDigest(seed: String, localIdentifier: String) -> String {
        var input = Data(seed.utf8)
        input.append(0x00)
        input.append(contentsOf: localIdentifier.utf8)
        return SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// JSON representation of the shared deterministic selection. It is an export
/// review queue, not human ground truth and not a recall measurement.
private struct DetectionAccuracySample: Encodable {

    var schemaVersion: Int
    var generatedAt: Date
    var containsPhotoData: Bool
    var snapshotIsFinal: Bool
    var analysisFingerprint: String
    var populationDefinition: String
    var sampleSeed: String
    var sampleAlgorithm: String
    var requestedSampleCount: Int
    var populationCount: Int
    var sampleCount: Int
    var items: [DetectionAccuracySampleItem]
    var manualClassificationSchema: ManualClassificationSchema

    init(selection: DetectionAccuracySampleSelection, generatedAt: Date) {
        schemaVersion = 1
        self.generatedAt = generatedAt
        containsPhotoData = false
        snapshotIsFinal = selection.snapshotIsFinal
        analysisFingerprint = selection.analysisFingerprint
        populationDefinition = selection.populationDefinition
        sampleSeed = selection.sampleSeed
        sampleAlgorithm = selection.sampleAlgorithm
        requestedSampleCount = selection.requestedSampleCount
        populationCount = selection.populationCount
        sampleCount = selection.items.count
        items = selection.items.map { selectionItem in
            DetectionAccuracySampleItem(
                reviewNumber: selectionItem.reviewNumber,
                selectionDigest: selectionItem.selectionDigest,
                record: selectionItem.record
            )
        }
        manualClassificationSchema = .current
    }
}

private struct DetectionAccuracySampleItem: Encodable {
    var reviewNumber: Int
    var selectionDigest: String
    /// The root `assets` array already contains this private PhotoKit value.
    /// Repeating it here makes the review queue self-identifying without
    /// introducing any new class of personal data or embedding photo bytes.
    var localIdentifier: String
    var creationDate: Date?
    var isFavorite: Bool
    var isScreenshot: Bool
    var burstIdentifier: String?
    var machineStatus: AssetAnalysisStatus
    var confidence: Float
    var boundingBox: NormalizedRect?
    var areaRatio: Double
    var catCount: Int
    var analysisFingerprint: String
    var analyzedAt: Date

    init(reviewNumber: Int, selectionDigest: String, record: AssetRecord) {
        self.reviewNumber = reviewNumber
        self.selectionDigest = selectionDigest
        localIdentifier = record.localIdentifier
        creationDate = record.creationDate
        isFavorite = record.isFavorite
        isScreenshot = record.isScreenshot
        burstIdentifier = record.burstIdentifier
        machineStatus = record.analysisStatus
        confidence = record.cat.confidence
        boundingBox = record.cat.boundingBox
        areaRatio = record.cat.areaRatio
        catCount = record.cat.catCount
        analysisFingerprint = record.analysisFingerprint
        analyzedAt = record.analyzedAt
    }
}

private struct ManualClassificationSchema: Encodable {
    var catTruthValues: [String]
    var productTruthValues: [String]
    var rejectionReasonValues: [String]
    var burstReviewValues: [String]
    var note: String

    static let current = ManualClassificationSchema(
        catTruthValues: ["realCat", "noRealCat", "uncertain"],
        productTruthValues: ["keep", "reject", "uncertain"],
        rejectionReasonValues: [
            "screenshot",
            "tvOrScreen",
            "illustration",
            "plush",
            "otherPersonCat",
            "smallIncidentalCat",
            "dogOrOtherAnimal",
            "noCat",
            "other",
            "uncertain"
        ],
        burstReviewValues: ["ok", "badBurstRepresentative", "notApplicable"],
        note: "Write human labels in a separate private review table. This JSON contains metadata only and no photo data."
    )
}
