import Foundation

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
