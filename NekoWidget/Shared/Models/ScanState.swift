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
