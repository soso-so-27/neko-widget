import Foundation

/// Records which image pass produced the persisted detector result. The
/// evidence contains no PhotoKit identifier or image data and is safe to keep
/// with the local snapshot.
enum AssetDetectionPass: String, Codable, Equatable, Sendable {
    case primary1024
    case localRecovery512
    case highResolution2048
}

enum AssetAnalysisFallbackReason: String, Codable, Equatable, Sendable {
    /// The normal high-quality, network-disabled request reported that no
    /// suitable derivative was available on this device.
    case unavailableLocally
    /// The 1024px Vision pass completed successfully but found no cat.
    case noCatAt1024
}

enum AssetAnalysisFallbackOutcome: String, Codable, Equatable, Sendable {
    case detected
    case noCat
    case unavailableLocally
    case failed
}

struct AssetAnalysisEvidence: Codable, Equatable, Sendable {
    var finalPass: AssetDetectionPass
    var fallbackReason: AssetAnalysisFallbackReason?
    var fallbackOutcome: AssetAnalysisFallbackOutcome?

    /// Duration of the fallback image request plus its Vision request. This is
    /// diagnostic timing only; it is never used for selection.
    var fallbackDurationMilliseconds: Double?

    var isLowFidelity: Bool { finalPass == .localRecovery512 }

    init(
        finalPass: AssetDetectionPass,
        fallbackReason: AssetAnalysisFallbackReason? = nil,
        fallbackOutcome: AssetAnalysisFallbackOutcome? = nil,
        fallbackDurationMilliseconds: Double? = nil
    ) {
        self.finalPass = finalPass
        self.fallbackReason = fallbackReason
        self.fallbackOutcome = fallbackOutcome
        self.fallbackDurationMilliseconds = fallbackDurationMilliseconds.map {
            max(0, $0)
        }
    }
}

struct AssetRecord: Codable, Identifiable, Equatable, Sendable {
    /// PhotoKit identifiers are suitable only for this v1's single-device
    /// storage. They are not stable identifiers for future cross-device sync.
    var localIdentifier: String
    var creationDate: Date?
    /// PhotoKit's last edit timestamp used to invalidate stale Vision boxes and
    /// family-specific Widget crops after a rotate, crop, or other adjustment.
    var sourceModificationDate: Date?
    /// Distinguishes a legacy record that never captured PhotoKit's edit date
    /// from a current record for which PhotoKit legitimately returned nil.
    var sourceModificationDateWasCaptured: Bool?
    var isFavorite: Bool
    var isScreenshot: Bool
    var burstIdentifier: String?
    var cat: CatDetection
    var analysisStatus: AssetAnalysisStatus
    var analysisFingerprint: String
    var analyzedAt: Date
    /// Optional so snapshots written before Build 19 remain decodable. A nil
    /// value is a normal-fidelity legacy result, never a low-fidelity recovery.
    var analysisEvidence: AssetAnalysisEvidence? = nil
    /// Optional for backward-compatible decoding of Build 11 snapshots. A nil
    /// value marks an asset that still needs the grouped-album migration pass.
    var albumAnalysisVersion: Int?
    var albumTraits: CatAlbumTraits?
    var liked: Bool
    var likedAt: Date?
    var lastShownAt: Date?
    var shownCount: Int

    var id: String { localIdentifier }

    var isCatCandidate: Bool {
        analysisStatus == .detected && cat.detected
    }

    /// A secondary-only repair may preserve the primary cat box only when it
    /// was produced under the current detector settings and the exact PhotoKit
    /// source revision is unchanged. Legacy records without a capture marker
    /// must take the normal primary path once before they become reusable.
    func canPreservePrimaryDetection(
        sourceModificationDate currentModificationDate: Date?,
        analysisFingerprint currentFingerprint: String
    ) -> Bool {
        isCatCandidate
            && analysisFingerprint == currentFingerprint
            && sourceModificationDateWasCaptured == true
            && sourceModificationDate == currentModificationDate
    }

    init(
        localIdentifier: String,
        creationDate: Date?,
        sourceModificationDate: Date? = nil,
        sourceModificationDateWasCaptured: Bool? = nil,
        isFavorite: Bool,
        isScreenshot: Bool,
        burstIdentifier: String?,
        cat: CatDetection,
        analysisStatus: AssetAnalysisStatus,
        analysisFingerprint: String,
        analyzedAt: Date = .now,
        analysisEvidence: AssetAnalysisEvidence? = nil,
        albumAnalysisVersion: Int? = nil,
        albumTraits: CatAlbumTraits? = nil,
        liked: Bool = false,
        likedAt: Date? = nil,
        lastShownAt: Date? = nil,
        shownCount: Int = 0
    ) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.sourceModificationDate = sourceModificationDate
        self.sourceModificationDateWasCaptured = sourceModificationDateWasCaptured
        self.isFavorite = isFavorite
        self.isScreenshot = isScreenshot
        self.burstIdentifier = burstIdentifier
        self.cat = cat
        self.analysisStatus = analysisStatus
        self.analysisFingerprint = analysisFingerprint
        self.analyzedAt = analyzedAt
        self.analysisEvidence = analysisEvidence
        self.albumAnalysisVersion = albumAnalysisVersion
        self.albumTraits = albumTraits
        self.liked = liked
        self.likedAt = likedAt
        self.lastShownAt = lastShownAt
        self.shownCount = shownCount
    }

    func preservingUserState(from previous: AssetRecord?) -> AssetRecord {
        guard let previous else { return self }
        var merged = self
        merged.liked = previous.liked
        merged.likedAt = previous.likedAt
        merged.lastShownAt = previous.lastShownAt
        merged.shownCount = previous.shownCount
        return merged
    }

    var resolvedCatBoundingBoxes: CatBoundingBoxResolution {
        cat.resolvedInstanceBoundingBoxes(
            legacyPostureInstances: albumTraits?.postureInstances
        )
    }

    /// Widget presentation remains deliberately stricter than local detection
    /// and album membership. Build 19 records every cat while preserving the
    /// existing minimum-area visual quality gate here.
    func isWidgetEligible(settings: AppSettings) -> Bool {
        isCatCandidate
            && analysisFingerprint == settings.analysisFingerprint
            && cat.areaRatio >= settings.minimumCatAreaRatio
            && analysisEvidence?.isLowFidelity != true
    }

    /// Build 18 encoded the Widget-only minimum area in the detector
    /// fingerprint. A positive detector observation remains valid when that
    /// presentation policy is removed. Migrate only positive `cat-v2` records
    /// with the same confidence/revision; old no-cat decisions must be
    /// reevaluated because some were produced solely by the area gate.
    func migratedToAreaIndependentDetection(
        settings: AppSettings
    ) -> AssetRecord {
        guard isCatCandidate,
              analysisFingerprint != settings.analysisFingerprint else {
            return self
        }
        let parts = analysisFingerprint.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard parts.count == 4,
              parts[0] == "cat-v2",
              parts[1] == Substring(String(settings.confidenceThreshold.bitPattern)),
              UInt64(parts[2]) != nil,
              parts[3] == Substring(String(settings.analysisRevision)) else {
            return self
        }
        var value = self
        value.analysisFingerprint = settings.analysisFingerprint
        return value
    }

    /// Migrates Build 12-15 posture storage without touching PhotoKit or
    /// running Vision. Existing per-cat posture-instance boxes are copied into
    /// the primary detection; only a one-cat union can be used as fallback.
    /// Legacy pose fields remain intact for JSON decode/round-trip compatibility.
    func migratedToBoundingBoxPostureAnalysis(
        synthesizingMissingTraits: Bool = false
    ) -> AssetRecord {
        guard isCatCandidate else {
            var value = self
            if value.albumAnalysisVersion != nil {
                value.albumAnalysisVersion = CatAlbumTraits.currentAnalysisVersion
            }
            return value
        }

        let resolution = resolvedCatBoundingBoxes
        var value = self
        value.cat.instanceBoundingBoxes = resolution.boundingBoxes
        if let traits = value.albumTraits {
            value.albumTraits = traits.migratedToBoundingBoxPostures(
                boundingBoxes: resolution.boundingBoxes
            )
        } else if synthesizingMissingTraits {
            // Build 12+ can occasionally contain a known cat whose secondary
            // face/location request was deferred. Its bbox posture is still
            // fully recoverable. Unknown non-posture traits fail closed.
            value.albumTraits = CatAlbumTraits(
                postures: CatBoundingBoxAspectBucket.postures(
                    for: resolution.boundingBoxes
                ),
                containsPerson: false,
                isOuting: nil,
                largestCatAreaRatio: resolution.boundingBoxes
                    .lazy
                    .map(\.area)
                    .max() ?? 0,
                analyzedAt: analyzedAt
            )
        } else {
            return value
        }
        value.albumAnalysisVersion = CatAlbumTraits.currentAnalysisVersion
        return value
    }
}

/// Count-only diagnostics. Asset totals describe the photos an album would
/// contain; instance totals describe individual detected cats. A multi-cat
/// photo can belong to more than one asset bucket, so asset bucket totals need
/// not add up to `targetCatAssets`.
struct CatBoundingBoxAspectDistribution: Equatable, Sendable {
    var targetCatAssets = 0
    var assetsWithValidBoxes = 0
    var sleepingAssets = 0
    var curledAssets = 0
    var sittingAssets = 0
    var unclassifiedAssets = 0
    var classifiedAssets = 0
    var fullyUnclassifiedAssets = 0
    var multiBucketAssets = 0
    /// Photos that enter two or more active posture albums. Unlike
    /// `multiBucketAssets`, an unclassified cat does not increase this count.
    var multiAlbumAssets = 0
    var missingBoxAssets = 0
    var singleCatFallbackAssets = 0
    var validInstances = 0
    var invalidInstances = 0
    var sleepingInstances = 0
    var curledInstances = 0
    var sittingInstances = 0
    var unclassifiedInstances = 0

    init(records: [AssetRecord]) {
        for record in records where record.isCatCandidate {
            targetCatAssets += 1
            let resolution = record.resolvedCatBoundingBoxes
            let boxes = resolution.boundingBoxes
            invalidInstances += resolution.invalidInstanceCount
            if resolution.source == .singleCatUnion {
                singleCatFallbackAssets += 1
            }

            guard !boxes.isEmpty else {
                missingBoxAssets += 1
                continue
            }
            assetsWithValidBoxes += 1
            validInstances += boxes.count
            let buckets = boxes.compactMap {
                CatBoundingBoxAspectBucket.bucket(for: $0)
            }
            sleepingInstances += buckets.lazy.filter { $0 == .sleeping }.count
            curledInstances += buckets.lazy.filter { $0 == .curled }.count
            sittingInstances += buckets.lazy.filter { $0 == .sitting }.count
            unclassifiedInstances += buckets.lazy.filter { $0 == .unclassified }.count

            let assetBuckets = Set(buckets)
            if assetBuckets.contains(.sleeping) { sleepingAssets += 1 }
            if assetBuckets.contains(.curled) { curledAssets += 1 }
            if assetBuckets.contains(.sitting) { sittingAssets += 1 }
            if assetBuckets.contains(.unclassified) { unclassifiedAssets += 1 }
            let classifiedBuckets: Set<CatBoundingBoxAspectBucket> = [
                .sleeping,
                .curled,
                .sitting
            ]
            if !assetBuckets.isDisjoint(with: classifiedBuckets) {
                classifiedAssets += 1
            } else if assetBuckets == [.unclassified] {
                fullyUnclassifiedAssets += 1
            }
            if assetBuckets.count > 1 { multiBucketAssets += 1 }
            if assetBuckets.intersection(classifiedBuckets).count > 1 {
                multiAlbumAssets += 1
            }
        }
    }

    var logMetadata: [String: String] {
        [
            "bboxAspectPolicy": "vision-normalized-width-height-v1",
            "bboxAspectTargetAssets": "\(targetCatAssets)",
            "bboxAspectAssetsWithValidBoxes": "\(assetsWithValidBoxes)",
            "bboxAspectSleepingAssets": "\(sleepingAssets)",
            "bboxAspectCurledAssets": "\(curledAssets)",
            "bboxAspectSittingAssets": "\(sittingAssets)",
            "bboxAspectUnclassifiedAssets": "\(unclassifiedAssets)",
            "bboxAspectClassifiedAssets": "\(classifiedAssets)",
            "bboxAspectFullyUnclassifiedAssets": "\(fullyUnclassifiedAssets)",
            "bboxAspectMultiBucketAssets": "\(multiBucketAssets)",
            "bboxAspectMultiAlbumAssets": "\(multiAlbumAssets)",
            "bboxAspectMissingBoxAssets": "\(missingBoxAssets)",
            "bboxAspectSingleCatFallbackAssets": "\(singleCatFallbackAssets)",
            "bboxAspectValidInstances": "\(validInstances)",
            "bboxAspectInvalidInstances": "\(invalidInstances)",
            "bboxAspectSleepingInstances": "\(sleepingInstances)",
            "bboxAspectCurledInstances": "\(curledInstances)",
            "bboxAspectSittingInstances": "\(sittingInstances)",
            "bboxAspectUnclassifiedInstances": "\(unclassifiedInstances)"
        ]
    }
}
