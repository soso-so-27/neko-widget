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
    var liked: Bool
    var likedAt: Date?
    var lastShownAt: Date?
    var shownCount: Int

    var id: String { localIdentifier }

    var isCatCandidate: Bool {
        analysisStatus == .detected && cat.detected
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
