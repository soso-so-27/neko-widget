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
    /// Decode-only Build 13-15 value. Current code clears this on load and
    /// never routes a scan through the retired animal-body-pose pipeline.
    case postureRepair
}

/// Privacy-minimal aggregate diagnostics. Active album counts come from the
/// normalized detector-box policy. Former pose-stage fields remain encoded so
/// Build 13-15 snapshots and exports continue to decode.
struct PostureScanSummary: Codable, Equatable, Sendable {
    var targetCatAssets: Int
    /// Legacy animal-body-pose counter; current summaries leave this at zero.
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
    var sittingAssets: Int
    var classifiedAnyAssets: Int
    var unclassifiedAssets: Int
    var secondaryPendingAssets: Int
    /// Instance totals are kept separate from asset totals. Current
    /// `classifiedInstances` counts classified detector boxes; the preceding
    /// pose-stage instance fields are legacy compatibility counters.
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
        sittingAssets: 0,
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

            let tags = Set(traits.postures)
            if tags.contains(.sleeping) { sleepingAssets += 1 }
            if tags.contains(.bellyUp) { bellyUpAssets += 1 }
            if tags.contains(.loaf) { loafAssets += 1 }
            if tags.contains(.stretching) { stretchingAssets += 1 }
            if tags.contains(.curled) { curledAssets += 1 }
            if tags.contains(.sitting) { sittingAssets += 1 }
            if tags.isEmpty {
                unclassifiedAssets += 1
            } else {
                classifiedAnyAssets += 1
            }
            classifiedInstances += record.resolvedCatBoundingBoxes.boundingBoxes
                .lazy
                .compactMap { CatBoundingBoxAspectBucket.bucket(for: $0) }
                .filter { $0 != .unclassified }
                .count
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
        sittingAssets: Int,
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
        self.sittingAssets = sittingAssets
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
        case sittingAssets
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
        sittingAssets = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .sittingAssets) ?? 0
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
            "postureSitting": "\(sittingAssets)",
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

/// Counts and elapsed time for Build 19's two bounded fallback paths. These
/// aggregates are enough to compare recovery yield and scan cost without
/// exporting per-photo identifiers.
struct ScanRecoveryDiagnostics: Codable, Equatable, Sendable {
    var localRecoveryAttemptedAssets: Int
    var localRecoveryResolvedAssets: Int
    var localRecoveryDetectedAssets: Int
    var localRecoveryDurationMilliseconds: Double
    var highResolutionAttemptedAssets: Int
    var highResolutionResolvedAssets: Int
    var highResolutionDetectedAssets: Int
    var highResolutionDurationMilliseconds: Double

    static let zero = ScanRecoveryDiagnostics(
        localRecoveryAttemptedAssets: 0,
        localRecoveryResolvedAssets: 0,
        localRecoveryDetectedAssets: 0,
        localRecoveryDurationMilliseconds: 0,
        highResolutionAttemptedAssets: 0,
        highResolutionResolvedAssets: 0,
        highResolutionDetectedAssets: 0,
        highResolutionDurationMilliseconds: 0
    )

    private enum CodingKeys: String, CodingKey {
        case localRecoveryAttemptedAssets
        case localRecoveryResolvedAssets
        case localRecoveryDetectedAssets
        case localRecoveryDurationMilliseconds
        case highResolutionAttemptedAssets
        case highResolutionResolvedAssets
        case highResolutionDetectedAssets
        case highResolutionDurationMilliseconds
    }

    init(
        localRecoveryAttemptedAssets: Int,
        localRecoveryResolvedAssets: Int,
        localRecoveryDetectedAssets: Int,
        localRecoveryDurationMilliseconds: Double,
        highResolutionAttemptedAssets: Int,
        highResolutionResolvedAssets: Int,
        highResolutionDetectedAssets: Int,
        highResolutionDurationMilliseconds: Double
    ) {
        let localAttempted = max(0, localRecoveryAttemptedAssets)
        let localResolved = min(localAttempted, max(0, localRecoveryResolvedAssets))
        self.localRecoveryAttemptedAssets = localAttempted
        self.localRecoveryResolvedAssets = localResolved
        self.localRecoveryDetectedAssets = min(
            localResolved,
            max(0, localRecoveryDetectedAssets)
        )
        self.localRecoveryDurationMilliseconds = max(
            0,
            localRecoveryDurationMilliseconds
        )

        let highAttempted = max(0, highResolutionAttemptedAssets)
        let highResolved = min(highAttempted, max(0, highResolutionResolvedAssets))
        self.highResolutionAttemptedAssets = highAttempted
        self.highResolutionResolvedAssets = highResolved
        self.highResolutionDetectedAssets = min(
            highResolved,
            max(0, highResolutionDetectedAssets)
        )
        self.highResolutionDurationMilliseconds = max(
            0,
            highResolutionDurationMilliseconds
        )
    }

    /// Reconstructs stable aggregate diagnostics when a completed Build 19
    /// record is reused on a later foreground scan. This prevents the original
    /// recovery yield from appearing to reset to zero without rerunning Vision.
    init(evidence: AssetAnalysisEvidence?) {
        guard let evidence,
              let reason = evidence.fallbackReason else {
            self = .zero
            return
        }
        let resolved = evidence.fallbackOutcome == .detected
            || evidence.fallbackOutcome == .noCat
        let detected = evidence.fallbackOutcome == .detected
        let duration = evidence.fallbackDurationMilliseconds ?? 0
        switch reason {
        case .unavailableLocally:
            self.init(
                localRecoveryAttemptedAssets: 1,
                localRecoveryResolvedAssets: resolved ? 1 : 0,
                localRecoveryDetectedAssets: detected ? 1 : 0,
                localRecoveryDurationMilliseconds: duration,
                highResolutionAttemptedAssets: 0,
                highResolutionResolvedAssets: 0,
                highResolutionDetectedAssets: 0,
                highResolutionDurationMilliseconds: 0
            )
        case .noCatAt1024:
            self.init(
                localRecoveryAttemptedAssets: 0,
                localRecoveryResolvedAssets: 0,
                localRecoveryDetectedAssets: 0,
                localRecoveryDurationMilliseconds: 0,
                highResolutionAttemptedAssets: 1,
                highResolutionResolvedAssets: resolved ? 1 : 0,
                highResolutionDetectedAssets: detected ? 1 : 0,
                highResolutionDurationMilliseconds: duration
            )
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            localRecoveryAttemptedAssets: try container.decodeIfPresent(
                Int.self,
                forKey: .localRecoveryAttemptedAssets
            ) ?? 0,
            localRecoveryResolvedAssets: try container.decodeIfPresent(
                Int.self,
                forKey: .localRecoveryResolvedAssets
            ) ?? 0,
            localRecoveryDetectedAssets: try container.decodeIfPresent(
                Int.self,
                forKey: .localRecoveryDetectedAssets
            ) ?? 0,
            localRecoveryDurationMilliseconds: try container.decodeIfPresent(
                Double.self,
                forKey: .localRecoveryDurationMilliseconds
            ) ?? 0,
            highResolutionAttemptedAssets: try container.decodeIfPresent(
                Int.self,
                forKey: .highResolutionAttemptedAssets
            ) ?? 0,
            highResolutionResolvedAssets: try container.decodeIfPresent(
                Int.self,
                forKey: .highResolutionResolvedAssets
            ) ?? 0,
            highResolutionDetectedAssets: try container.decodeIfPresent(
                Int.self,
                forKey: .highResolutionDetectedAssets
            ) ?? 0,
            highResolutionDurationMilliseconds: try container.decodeIfPresent(
                Double.self,
                forKey: .highResolutionDurationMilliseconds
            ) ?? 0
        )
    }

    mutating func merge(_ other: Self) {
        self = Self(
            localRecoveryAttemptedAssets: localRecoveryAttemptedAssets
                + other.localRecoveryAttemptedAssets,
            localRecoveryResolvedAssets: localRecoveryResolvedAssets
                + other.localRecoveryResolvedAssets,
            localRecoveryDetectedAssets: localRecoveryDetectedAssets
                + other.localRecoveryDetectedAssets,
            localRecoveryDurationMilliseconds: localRecoveryDurationMilliseconds
                + other.localRecoveryDurationMilliseconds,
            highResolutionAttemptedAssets: highResolutionAttemptedAssets
                + other.highResolutionAttemptedAssets,
            highResolutionResolvedAssets: highResolutionResolvedAssets
                + other.highResolutionResolvedAssets,
            highResolutionDetectedAssets: highResolutionDetectedAssets
                + other.highResolutionDetectedAssets,
            highResolutionDurationMilliseconds: highResolutionDurationMilliseconds
                + other.highResolutionDurationMilliseconds
        )
    }

    var logMetadata: [String: String] {
        [
            "localRecoveryAttempted": "\(localRecoveryAttemptedAssets)",
            "localRecoveryResolved": "\(localRecoveryResolvedAssets)",
            "localRecoveryDetected": "\(localRecoveryDetectedAssets)",
            "localRecoveryDurationMs": String(
                format: "%.1f",
                localRecoveryDurationMilliseconds
            ),
            "highResolutionAttempted": "\(highResolutionAttemptedAssets)",
            "highResolutionResolved": "\(highResolutionResolvedAssets)",
            "highResolutionDetected": "\(highResolutionDetectedAssets)",
            "highResolutionDurationMs": String(
                format: "%.1f",
                highResolutionDurationMilliseconds
            )
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
    /// Strict area/fidelity population eligible for Widget publication.
    /// Optional so snapshots written before Build 19 remain decodable.
    var widgetEligibleAssets: Int? = nil
    var oldestCatPhotoDate: Date?
    var deferredAssets: Int
    /// Wall-clock duration for the current completed/provisional scan. Optional
    /// for snapshots written before Build 19.
    var scanDurationMilliseconds: Double? = nil
    /// Optional for snapshots written before Build 19.
    var recoveryDiagnostics: ScanRecoveryDiagnostics? = nil
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
        widgetEligibleAssets: 0,
        oldestCatPhotoDate: nil,
        deferredAssets: 0,
        scanDurationMilliseconds: nil,
        recoveryDiagnostics: .zero,
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
