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
    var poseObservationAssets: Int
    var sleepingAssets: Int
    var bellyUpAssets: Int
    var loafAssets: Int
    var stretchingAssets: Int
    var curledAssets: Int
    var classifiedAnyAssets: Int
    var unclassifiedAssets: Int
    var secondaryPendingAssets: Int

    static let empty = PostureScanSummary(
        targetCatAssets: 0,
        poseObservationAssets: 0,
        sleepingAssets: 0,
        bellyUpAssets: 0,
        loafAssets: 0,
        stretchingAssets: 0,
        curledAssets: 0,
        classifiedAnyAssets: 0,
        unclassifiedAssets: 0,
        secondaryPendingAssets: 0
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

            if (traits.poseObservationCount ?? 0) > 0 {
                poseObservationAssets += 1
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
        sleepingAssets: Int,
        bellyUpAssets: Int,
        loafAssets: Int,
        stretchingAssets: Int,
        curledAssets: Int,
        classifiedAnyAssets: Int,
        unclassifiedAssets: Int,
        secondaryPendingAssets: Int
    ) {
        self.targetCatAssets = targetCatAssets
        self.poseObservationAssets = poseObservationAssets
        self.sleepingAssets = sleepingAssets
        self.bellyUpAssets = bellyUpAssets
        self.loafAssets = loafAssets
        self.stretchingAssets = stretchingAssets
        self.curledAssets = curledAssets
        self.classifiedAnyAssets = classifiedAnyAssets
        self.unclassifiedAssets = unclassifiedAssets
        self.secondaryPendingAssets = secondaryPendingAssets
    }

    var logMetadata: [String: String] {
        [
            "postureTargetCats": "\(targetCatAssets)",
            "posturePoseObserved": "\(poseObservationAssets)",
            "postureSleeping": "\(sleepingAssets)",
            "postureBellyUp": "\(bellyUpAssets)",
            "postureLoaf": "\(loafAssets)",
            "postureStretching": "\(stretchingAssets)",
            "postureCurled": "\(curledAssets)",
            "postureClassifiedAny": "\(classifiedAnyAssets)",
            "postureUnclassified": "\(unclassifiedAssets)",
            "postureSecondaryPending": "\(secondaryPendingAssets)"
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
