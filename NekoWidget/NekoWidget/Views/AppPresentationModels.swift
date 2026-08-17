import CoreGraphics
import Foundation

/// UI-only representation of a scanned photo. The image itself always remains in PhotoKit.
struct PhotoPresentation: Identifiable, Hashable {
    let localIdentifier: String
    let creationDate: Date?
    let catBoundingBox: CGRect?
    let isLiked: Bool
    let likedAt: Date?

    var id: String { localIdentifier }

    init(
        localIdentifier: String,
        creationDate: Date? = nil,
        catBoundingBox: CGRect? = nil,
        isLiked: Bool = false,
        likedAt: Date? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.catBoundingBox = catBoundingBox
        self.isLiked = isLiked
        self.likedAt = likedAt
    }
}

/// The quick result and the completed result are intentionally represented separately.
/// A quick result is based on the newest first-stage batch and must not be presented as
/// the final library-wide count.
struct ScanPresentation: Equatable {
    var scannedAssets = 0
    var totalAssets = 0
    var preliminaryCatAssets: Int?
    var preliminaryOldestDate: Date?
    var finalCatAssets: Int?
    var finalOldestDate: Date?
    var deferredAssets = 0
    var isScanning = false
    var isPaused = false
    var lastScannedAt: Date?

    /// A final result also satisfies the first-result gate when the app is relaunched
    /// after the full scan completed.
    var hasPreliminaryResult: Bool {
        preliminaryCatAssets != nil || finalCatAssets != nil
    }
    var hasFinalResult: Bool { finalCatAssets != nil }
    var hasDeferredAssets: Bool { deferredAssets > 0 }

    var progress: Double {
        guard totalAssets > 0 else { return isScanning ? 0 : 1 }
        return min(max(Double(scannedAssets) / Double(totalAssets), 0), 1)
    }

    var displayedCatCount: Int {
        finalCatAssets ?? preliminaryCatAssets ?? 0
    }

    var displayedOldestDate: Date? {
        finalOldestDate ?? preliminaryOldestDate
    }
}

enum PhotoRangePresentation: String, CaseIterable, Identifiable {
    case all = "全期間"
    case recentYear = "直近1年"

    var id: String { rawValue }
}

struct SettingsPresentation: Equatable {
    var range: PhotoRangePresentation = .all
    var albumLimit = 300
    var confidenceThreshold = 0.7
    var minimumAreaRatio = 0.08
}

/// UI-only metadata for one item in the exported detection-accuracy sample.
/// The order and review number come from the same core sampler used by the
/// verification JSON, while the photo itself remains in PhotoKit.
struct DetectionAccuracySampleItemPresentation: Identifiable, Hashable {
    let reviewNumber: Int
    let localIdentifier: String
    let creationDate: Date?

    var id: Int { reviewNumber }
}

struct DetectionAccuracySamplePresentation: Equatable {
    var snapshotIsFinal = false
    var items: [DetectionAccuracySampleItemPresentation] = []
}

enum AlbumPresentationState: Equatable {
    case idle
    case updating
    case ready(photoCount: Int, updatedAt: Date?)
    case failed(message: String)
}

enum AppTab: Hashable {
    case home
    case album
    case likes
    case settings
}
