import Foundation

/// Versioned, photo-level posture tags derived from Apple's animal body-pose
/// joints. A photo can carry more than one tag (for example, a sleeping cat
/// lying belly-up). Raw joints are deliberately never persisted.
enum CatPostureTag: String, Codable, CaseIterable, Hashable, Sendable {
    case sleeping
    case bellyUp
    case loaf
    case stretching
    case curled
}

/// The privacy-minimal album classification persisted for one cat photo.
/// Human-face rectangles, pose joints and locations never leave the in-memory
/// analysis pass; only these derived values are saved.
struct CatAlbumTraits: Codable, Equatable, Sendable {
    static let currentAnalysisVersion = 1

    var analysisVersion: Int
    var postures: [CatPostureTag]
    var containsPerson: Bool
    /// `nil` means that the asset had no usable location or that a stable home
    /// cluster could not be established. Coordinates are never persisted.
    var isOuting: Bool?
    /// Largest single-cat bounding-box area, rather than the existing union of
    /// all cats, so two distant cats don't accidentally become a close-up.
    var largestCatAreaRatio: Double
    var analyzedAt: Date

    init(
        analysisVersion: Int = Self.currentAnalysisVersion,
        postures: [CatPostureTag],
        containsPerson: Bool,
        isOuting: Bool?,
        largestCatAreaRatio: Double,
        analyzedAt: Date = .now
    ) {
        self.analysisVersion = analysisVersion
        self.postures = Array(Set(postures)).sorted { $0.rawValue < $1.rawValue }
        self.containsPerson = containsPerson
        self.isOuting = isOuting
        self.largestCatAreaRatio = min(1, max(0, largestCatAreaRatio))
        self.analyzedAt = analyzedAt
    }
}

struct CatDetection: Codable, Equatable, Sendable {
    var detected: Bool
    var confidence: Float
    /// Union of all qualifying cats, in normalized Vision coordinates.
    var boundingBox: NormalizedRect?
    var areaRatio: Double
    var catCount: Int

    static let none = CatDetection(
        detected: false,
        confidence: 0,
        boundingBox: nil,
        areaRatio: 0,
        catCount: 0
    )
}

enum AssetAnalysisStatus: String, Codable, Equatable, Sendable {
    case detected
    case noCat
    case unavailableLocally
    case excludedScreenshot
    case excludedBurstDuplicate
    case failed
}
