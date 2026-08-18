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
}
