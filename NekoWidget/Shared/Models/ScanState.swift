import Foundation

enum ScanPhase: String, Codable, Equatable, Sendable {
    case idle
    case quickScan
    case fullScan
    case completed
    case cancelled
    case failed
}

/// Makes it impossible for the UI to accidentally present a 500-photo quick
/// scan as a complete library count.
enum ScanResultKind: String, Codable, Equatable, Sendable {
    case none
    case provisional
    case final
}

enum ScanPurpose: String, Codable, Equatable, Sendable {
    case regular
    case manualRescan
    case groupedAlbumUpgrade
    /// Re-runs only missing/stale secondary album traits for known cat photos.
    case postureRepair
}

/// Privacy-minimal aggregate diagnostics for the posture pipeline. These are
/// counts only: no PhotoKit identifiers, joint coordinates, or image data.
struct PostureScanSummary: Codable, Equatable, Sendable {
    var targetCatAssets: Int
    /// Assets with one or more raw Vision animal-body-pose observations.
    var poseObservationAssets: Int
    var reliableSkeletonAssets: Int
    var matchedSkeletonAssets: Int
    var ruleQualityPassedAssets: Int
    var geometryPassedAssets: Int
    var sleepingAssets: Int
    var bellyUpAssets: Int
    var loafAssets: Int
    var stretchingAssets: Int
    var curledAssets: Int
    var classifiedAnyAssets: Int
    var unclassifiedAssets: Int
    var secondaryPendingAssets: Int
    /// Instance totals are kept separate from asset totals. A photo may contain
    /// more than one cat/body-pose observation.
    var rawObservationInstances: Int
    var reliableSkeletonInstances: Int
    var matchedSkeletonInstances: Int
    var ruleQualityPassedInstances: Int
    var geometryPassedInstances: Int
    var classifiedInstances: Int

    static let empty = PostureScanSummary(
        targetCatAssets: 0,
        poseObservationAssets: 0,
        reliableSkeletonAssets: 0,
        matchedSkeletonAssets: 0,
        ruleQualityPassedAssets: 0,
        geometryPassedAssets: 0,
        sleepingAssets: 0,
        bellyUpAssets: 0,
        loafAssets: 0,
        stretchingAssets: 0,
        curledAssets: 0,
        classifiedAnyAssets: 0,
        unclassifiedAssets: 0,
        secondaryPendingAssets: 0,
        rawObservationInstances: 0,
        reliableSkeletonInstances: 0,
        matchedSkeletonInstances: 0,
        ruleQualityPassedInstances: 0,
        geometryPassedInstances: 0,
        classifiedInstances: 0
    )

    init(records: [AssetRecord]) {
        self = .empty
        for record in records where record.isCatCandidate {
            targetCatAssets += 1
            guard record.albumAnalysisVersion == CatAlbumTraits.currentAnalysisVersion,
                  let traits = record.albumTraits,
                  traits.analysisVersion == CatAlbumTraits.currentAnalysisVersion else {
                secondaryPendingAssets += 1
                continue
            }

            if let diagnostics = traits.postureDiagnostics {
                rawObservationInstances += diagnostics.rawObservationCount
                reliableSkeletonInstances += diagnostics.reliableSkeletonCount
                matchedSkeletonInstances += diagnostics.matchedSkeletonCount
                ruleQualityPassedInstances += diagnostics.ruleQualityPassedCount
                geometryPassedInstances += diagnostics.geometryPassedCount
                classifiedInstances += diagnostics.classifiedInstanceCount

                if diagnostics.rawObservationCount > 0 {
                    poseObservationAssets += 1
                }
                if diagnostics.reliableSkeletonCount > 0 {
                    reliableSkeletonAssets += 1
                }
                if diagnostics.matchedSkeletonCount > 0 {
                    matchedSkeletonAssets += 1
                }
                if diagnostics.ruleQualityPassedCount > 0 {
                    ruleQualityPassedAssets += 1
                }
                if diagnostics.geometryPassedCount > 0 {
                    geometryPassedAssets += 1
                }
            } else if (traits.poseObservationCount ?? 0) > 0 {
                // Compatibility for manually produced pre-v3-style fixtures.
                // No later stage is inferred from the raw count.
                poseObservationAssets += 1
                rawObservationInstances += traits.poseObservationCount ?? 0
            }
            let tags = Set(traits.postures)
            if tags.contains(.sleeping) { sleepingAssets += 1 }
            if tags.contains(.bellyUp) { bellyUpAssets += 1 }
            if tags.contains(.loaf) { loafAssets += 1 }
            if tags.contains(.stretching) { stretchingAssets += 1 }
            if tags.contains(.curled) { curledAssets += 1 }
            if tags.isEmpty {
                unclassifiedAssets += 1
            } else {
                classifiedAnyAssets += 1
            }
        }
    }

    private init(
        targetCatAssets: Int,
        poseObservationAssets: Int,
        reliableSkeletonAssets: Int,
        matchedSkeletonAssets: Int,
        ruleQualityPassedAssets: Int,
        geometryPassedAssets: Int,
        sleepingAssets: Int,
        bellyUpAssets: Int,
        loafAssets: Int,
        stretchingAssets: Int,
        curledAssets: Int,
        classifiedAnyAssets: Int,
        unclassifiedAssets: Int,
        secondaryPendingAssets: Int,
        rawObservationInstances: Int,
        reliableSkeletonInstances: Int,
        matchedSkeletonInstances: Int,
        ruleQualityPassedInstances: Int,
        geometryPassedInstances: Int,
        classifiedInstances: Int
    ) {
        self.targetCatAssets = targetCatAssets
        self.poseObservationAssets = poseObservationAssets
        self.reliableSkeletonAssets = reliableSkeletonAssets
        self.matchedSkeletonAssets = matchedSkeletonAssets
        self.ruleQualityPassedAssets = ruleQualityPassedAssets
        self.geometryPassedAssets = geometryPassedAssets
        self.sleepingAssets = sleepingAssets
        self.bellyUpAssets = bellyUpAssets
        self.loafAssets = loafAssets
        self.stretchingAssets = stretchingAssets
        self.curledAssets = curledAssets
        self.classifiedAnyAssets = classifiedAnyAssets
        self.unclassifiedAssets = unclassifiedAssets
        self.secondaryPendingAssets = secondaryPendingAssets
        self.rawObservationInstances = rawObservationInstances
        self.reliableSkeletonInstances = reliableSkeletonInstances
        self.matchedSkeletonInstances = matchedSkeletonInstances
        self.ruleQualityPassedInstances = ruleQualityPassedInstances
        self.geometryPassedInstances = geometryPassedInstances
        self.classifiedInstances = classifiedInstances
    }

    private enum CodingKeys: String, CodingKey {
        case targetCatAssets
        case poseObservationAssets
        case reliableSkeletonAssets
        case matchedSkeletonAssets
        case ruleQualityPassedAssets
        case geometryPassedAssets
        case sleepingAssets
        case bellyUpAssets
        case loafAssets
        case stretchingAssets
        case curledAssets
        case classifiedAnyAssets
        case unclassifiedAssets
        case secondaryPendingAssets
        case rawObservationInstances
        case reliableSkeletonInstances
        case matchedSkeletonInstances
        case ruleQualityPassedInstances
        case geometryPassedInstances
        case classifiedInstances
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetCatAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .targetCatAssets) ?? 0
        )
        poseObservationAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .poseObservationAssets) ?? 0
        )
        reliableSkeletonAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .reliableSkeletonAssets) ?? 0
        )
        matchedSkeletonAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .matchedSkeletonAssets) ?? 0
        )
        ruleQualityPassedAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .ruleQualityPassedAssets) ?? 0
        )
        geometryPassedAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .geometryPassedAssets) ?? 0
        )
        sleepingAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .sleepingAssets) ?? 0
        )
        bellyUpAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .bellyUpAssets) ?? 0
        )
        loafAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .loafAssets) ?? 0
        )
        stretchingAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .stretchingAssets) ?? 0
        )
        curledAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .curledAssets) ?? 0
        )
        classifiedAnyAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .classifiedAnyAssets) ?? 0
        )
        unclassifiedAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .unclassifiedAssets) ?? 0
        )
        secondaryPendingAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .secondaryPendingAssets) ?? 0
        )
        rawObservationInstances = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .rawObservationInstances) ?? 0
        )
        reliableSkeletonInstances = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .reliableSkeletonInstances) ?? 0
        )
        matchedSkeletonInstances = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .matchedSkeletonInstances) ?? 0
        )
        ruleQualityPassedInstances = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .ruleQualityPassedInstances) ?? 0
        )
        geometryPassedInstances = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .geometryPassedInstances) ?? 0
        )
        classifiedInstances = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .classifiedInstances) ?? 0
        )
    }

    var logMetadata: [String: String] {
        [
            "postureTargetCats": "\(targetCatAssets)",
            "posturePoseObserved": "\(poseObservationAssets)",
            "posturePoseObservationAssets": "\(poseObservationAssets)",
            "postureReliableSkeletonAssets": "\(reliableSkeletonAssets)",
            "postureMatchedSkeletonAssets": "\(matchedSkeletonAssets)",
            "postureRuleQualityPassedAssets": "\(ruleQualityPassedAssets)",
            "postureGeometryPassedAssets": "\(geometryPassedAssets)",
            "postureSleeping": "\(sleepingAssets)",
            "postureBellyUp": "\(bellyUpAssets)",
            "postureLoaf": "\(loafAssets)",
            "postureStretching": "\(stretchingAssets)",
            "postureCurled": "\(curledAssets)",
            "postureClassifiedAny": "\(classifiedAnyAssets)",
            "postureUnclassified": "\(unclassifiedAssets)",
            "postureSecondaryPending": "\(secondaryPendingAssets)",
            "postureRawObservationInstances": "\(rawObservationInstances)",
            "postureReliableSkeletonInstances": "\(reliableSkeletonInstances)",
            "postureMatchedSkeletonInstances": "\(matchedSkeletonInstances)",
            "postureRuleQualityPassedInstances": "\(ruleQualityPassedInstances)",
            "postureGeometryPassedInstances": "\(geometryPassedInstances)",
            "postureClassifiedInstances": "\(classifiedInstances)"
        ]
    }
}

struct ScanState: Codable, Equatable, Sendable {
    var phase: ScanPhase
    var resultKind: ScanResultKind
    var lastScannedAt: Date?
    var totalAssets: Int
    var scannedAssets: Int
    var catAssets: Int
    var oldestCatPhotoDate: Date?
    var deferredAssets: Int
    /// Aggregate posture diagnostics included in snapshot/export JSON. Optional
    /// so snapshots written before Build 13 remain decodable.
    var postureSummary: PostureScanSummary? = nil
    /// True while a threshold-changing rescan must continue without reusing
    /// records produced under the previous detector settings.
    var requiresFullRescan: Bool
    var purpose: ScanPurpose? = nil
    var lastError: String?

    static let idle = ScanState(
        phase: .idle,
        resultKind: .none,
        lastScannedAt: nil,
        totalAssets: 0,
        scannedAssets: 0,
        catAssets: 0,
        oldestCatPhotoDate: nil,
        deferredAssets: 0,
        postureSummary: .empty,
        requiresFullRescan: false,
        lastError: nil
    )

    var progress: Double {
        guard totalAssets > 0 else { return phase == .completed ? 1 : 0 }
        return min(1, max(0, Double(scannedAssets) / Double(totalAssets)))
    }

    var isQuickResultReady: Bool {
        resultKind == .provisional || resultKind == .final
    }

    var isComplete: Bool {
        phase == .completed && resultKind == .final
    }
}
