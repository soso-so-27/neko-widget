import Foundation

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
