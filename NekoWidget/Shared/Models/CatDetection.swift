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

/// Privacy-minimal counters for the animal-pose pipeline. Counts are stored,
/// but the Vision observations, recognized joints, and their coordinates are
/// discarded after the in-memory classification pass.
struct PosturePipelineDiagnostics: Codable, Equatable, Sendable {
    var rawObservationCount: Int
    var reliableSkeletonCount: Int
    var matchedSkeletonCount: Int
    var ruleQualityPassedCount: Int
    var geometryPassedCount: Int
    var classifiedInstanceCount: Int

    static let zero = PosturePipelineDiagnostics(
        rawObservationCount: 0,
        reliableSkeletonCount: 0,
        matchedSkeletonCount: 0,
        ruleQualityPassedCount: 0,
        geometryPassedCount: 0,
        classifiedInstanceCount: 0
    )

    init(
        rawObservationCount: Int,
        reliableSkeletonCount: Int,
        matchedSkeletonCount: Int,
        ruleQualityPassedCount: Int,
        geometryPassedCount: Int,
        classifiedInstanceCount: Int
    ) {
        let raw = max(0, rawObservationCount)
        let reliable = min(raw, max(0, reliableSkeletonCount))
        let matched = min(reliable, max(0, matchedSkeletonCount))
        let quality = min(matched, max(0, ruleQualityPassedCount))
        let geometry = min(quality, max(0, geometryPassedCount))
        let classified = min(geometry, max(0, classifiedInstanceCount))
        self.rawObservationCount = raw
        self.reliableSkeletonCount = reliable
        self.matchedSkeletonCount = matched
        self.ruleQualityPassedCount = quality
        self.geometryPassedCount = geometry
        self.classifiedInstanceCount = classified
    }
}

/// One detector-box outcome. The cat bounding box is already part of the
/// primary detector output; pose joints and pose-derived coordinates are not
/// persisted. Photo-level posture tags are derived from these outcomes in v3.
struct CatPostureInstanceOutcome: Codable, Equatable, Sendable {
    var boundingBox: NormalizedRect
    var poseMatched: Bool
    var ruleQualityPassed: Bool
    var geometryPassed: Bool
    var postures: [CatPostureTag]

    init(
        boundingBox: NormalizedRect,
        poseMatched: Bool,
        ruleQualityPassed: Bool,
        geometryPassed: Bool,
        postures: [CatPostureTag]
    ) {
        let normalizedPostures = Array(Set(postures)).sorted { $0.rawValue < $1.rawValue }
        self.boundingBox = normalizedPostureRect(boundingBox)
        self.poseMatched = poseMatched
        self.ruleQualityPassed = poseMatched && ruleQualityPassed
        self.geometryPassed = self.ruleQualityPassed
            && (geometryPassed || !normalizedPostures.isEmpty)
        self.postures = self.geometryPassed ? normalizedPostures : []
    }

    var isClassified: Bool { !postures.isEmpty }
}

/// The privacy-minimal album classification persisted for one cat photo.
/// Human-face rectangles, pose joints and locations never leave the in-memory
/// analysis pass; only these derived values are saved.
struct CatAlbumTraits: Codable, Equatable, Sendable {
    /// Version 3 records stage diagnostics and per-cat detector-box outcomes,
    /// and relaxes structural visibility requirements without globally lowering
    /// any joint-confidence threshold. Existing known cats receive one
    /// secondary-only retry; primary cat/no-cat decisions remain valid.
    static let currentAnalysisVersion = 3

    var analysisVersion: Int
    var postures: [CatPostureTag]
    /// Number of animal-body-pose observations returned for this photo. This
    /// derived count is safe to persist; raw joints and coordinates are not.
    /// Optional so Build 12 snapshots continue to decode before migration.
    var poseObservationCount: Int?
    /// Optional so Build 12/13 snapshots continue to decode before migration.
    var postureDiagnostics: PosturePipelineDiagnostics? = nil
    /// Nil denotes a legacy photo-level result. New v3 results contain one
    /// outcome per valid cat detector box, including unmatched boxes.
    var postureInstances: [CatPostureInstanceOutcome]? = nil
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
        poseObservationCount: Int? = nil,
        postureDiagnostics: PosturePipelineDiagnostics? = nil,
        postureInstances: [CatPostureInstanceOutcome]? = nil,
        containsPerson: Bool,
        isOuting: Bool?,
        largestCatAreaRatio: Double,
        analyzedAt: Date = .now
    ) {
        self.analysisVersion = analysisVersion
        let normalizedInstances = postureInstances?.sorted(by: postureInstanceOrder)
        self.postureInstances = normalizedInstances
        if let normalizedInstances {
            self.postures = Array(Set(normalizedInstances.flatMap(\.postures)))
                .sorted { $0.rawValue < $1.rawValue }
        } else {
            self.postures = Array(Set(postures)).sorted { $0.rawValue < $1.rawValue }
        }
        self.postureDiagnostics = postureDiagnostics
        self.poseObservationCount = postureDiagnostics?.rawObservationCount
            ?? poseObservationCount.map { max(0, $0) }
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

/// Measurement-only grouping of the detector's existing per-cat boxes. This
/// does not run Vision or change album membership; it lets us review the real
/// width/height distribution before adopting a bounding-box album policy.
enum CatBoundingBoxAspectBucket: String, CaseIterable, Hashable, Sendable {
    case sleeping
    case curled
    case sitting
    case unclassified

    static func bucket(for boundingBox: NormalizedRect) -> Self? {
        guard boundingBox.width.isFinite,
              boundingBox.height.isFinite,
              boundingBox.width > 0,
              boundingBox.height > 0 else { return nil }
        let ratio = boundingBox.width / boundingBox.height
        guard ratio.isFinite else { return nil }
        if ratio < 0.9 { return .sitting }
        if ratio <= 1.1 { return .curled }
        if ratio < 2.0 { return .unclassified }
        return .sleeping
    }
}

private func normalizedPostureRect(_ value: NormalizedRect) -> NormalizedRect {
    guard value.x.isFinite,
          value.y.isFinite,
          value.width.isFinite,
          value.height.isFinite else {
        return NormalizedRect(x: 0, y: 0, width: 0, height: 0)
    }
    if value.x >= 0,
       value.y >= 0,
       value.width >= 0,
       value.height >= 0,
       value.x + value.width <= 1,
       value.y + value.height <= 1 {
        return value
    }
    let firstX = value.x
    let secondX = value.x + value.width
    let firstY = value.y
    let secondY = value.y + value.height
    let minimumX = min(1, max(0, min(firstX, secondX)))
    let maximumX = min(1, max(0, max(firstX, secondX)))
    let minimumY = min(1, max(0, min(firstY, secondY)))
    let maximumY = min(1, max(0, max(firstY, secondY)))
    return NormalizedRect(
        x: minimumX,
        y: minimumY,
        width: maximumX - minimumX,
        height: maximumY - minimumY
    )
}

private func postureInstanceOrder(
    _ first: CatPostureInstanceOutcome,
    _ second: CatPostureInstanceOutcome
) -> Bool {
    let firstBox = first.boundingBox
    let secondBox = second.boundingBox
    let firstValues = [firstBox.x, firstBox.y, firstBox.width, firstBox.height]
    let secondValues = [secondBox.x, secondBox.y, secondBox.width, secondBox.height]
    for (left, right) in zip(firstValues, secondValues) where left != right {
        return left < right
    }
    if first.poseMatched != second.poseMatched { return !first.poseMatched }
    if first.ruleQualityPassed != second.ruleQualityPassed {
        return !first.ruleQualityPassed
    }
    if first.geometryPassed != second.geometryPassed { return !first.geometryPassed }
    let firstTags = first.postures.map(\.rawValue).joined(separator: ",")
    let secondTags = second.postures.map(\.rawValue).joined(separator: ",")
    return firstTags < secondTags
}

enum AssetAnalysisStatus: String, Codable, Equatable, Sendable {
    case detected
    case noCat
    case unavailableLocally
    case excludedScreenshot
    case excludedBurstDuplicate
    case failed
}
