import Foundation

/// Versioned inputs that must participate in any future ephemeral cache key.
/// Revision 2 is available at the app's iOS 17.1 deployment target. The crop
/// policy expands every edge by 10% of that axis before clamping to unit space.
enum CatSimilarityFeaturePolicy {
    static let requestRevision = 2
    static let cropPolicyRevision = 1
    static let cropExpansionFractionPerEdge = 0.10

    static func cropRegion(for box: NormalizedRect) -> NormalizedRect {
        let margin = cropExpansionFractionPerEdge
        let minimumX = max(0, box.x - box.width * margin)
        let maximumX = min(1, box.x + box.width + box.width * margin)
        let minimumY = max(0, box.y - box.height * margin)
        let maximumY = min(1, box.y + box.height + box.height * margin)
        return NormalizedRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }
}

/// One detector-owned cat instance that is still awaiting a user decision.
/// The exact Vision rectangle is part of the identity of the instance; callers
/// must not replace it with an array index that could change after a rescan.
struct CatSimilarityCandidateInstance: Equatable, Hashable, Sendable {
    var assetLocalIdentifier: String
    var boundingBox: NormalizedRect
}

/// Read-only input used to derive the instances that still need grouping.
/// Callers supply only `.included` membership subjects for the asset. Global
/// exclusions and the current source/fingerprint scope are applied before this
/// value is built.
struct CatSimilarityCandidateAsset: Equatable, Sendable {
    var assetLocalIdentifier: String
    var detectedCatCount: Int
    var resolvedBoundingBoxes: [NormalizedRect]
    var includedMembershipSubjectBoundingBoxes: [NormalizedRect?]
}

private struct CatSimilaritySubjectMatchEdge {
    let subjectIndex: Int
    let boxIndex: Int
    let intersectionOverUnion: Double
}

/// Pure resolver that never changes `CatHouseholdIdentityState`.
enum CatSimilarityCandidateResolver {
    static let minimumSubjectIntersectionOverUnion = 0.35

    /// Returns exact detector rectangles in a stable order. A subject-less
    /// positive resolves the sole box of a one-cat photo, but never guesses in
    /// a multi-cat photo. A stored subject resolves every current box with an
    /// IoU at or above the same 0.35 boundary used by profile presentation.
    static func unresolvedInstances(
        from assets: [CatSimilarityCandidateAsset]
    ) -> [CatSimilarityCandidateInstance] {
        var seen = Set<CatSimilarityCandidateInstance>()
        var output: [CatSimilarityCandidateInstance] = []

        for asset in assets {
            let hasSubjectlessIncludedMembership = asset
                .includedMembershipSubjectBoundingBoxes
                .contains(where: { $0 == nil })
            let subjects = asset.includedMembershipSubjectBoundingBoxes.compactMap {
                $0
            }

            // Match persisted subjects to detector boxes one-to-one. A single
            // broad/overlapping subject must never make two cats disappear
            // from review. Greedy highest-IoU matching is deterministic and
            // sufficient for the small number of cats Vision returns here.
            let matchEdges = subjects.indices.flatMap { subjectIndex in
                asset.resolvedBoundingBoxes.indices.compactMap { boxIndex in
                    let score = intersectionOverUnion(
                        subjects[subjectIndex],
                        asset.resolvedBoundingBoxes[boxIndex]
                    )
                    guard score >= minimumSubjectIntersectionOverUnion else {
                        return nil
                    }
                    return CatSimilaritySubjectMatchEdge(
                        subjectIndex: subjectIndex,
                        boxIndex: boxIndex,
                        intersectionOverUnion: score
                    )
                }
            }.sorted { lhs, rhs in
                if lhs.intersectionOverUnion != rhs.intersectionOverUnion {
                    return lhs.intersectionOverUnion > rhs.intersectionOverUnion
                }
                if lhs.subjectIndex != rhs.subjectIndex {
                    return lhs.subjectIndex < rhs.subjectIndex
                }
                return lhs.boxIndex < rhs.boxIndex
            }
            var matchedSubjectIndices = Set<Int>()
            var matchedBoxIndices = Set<Int>()
            for edge in matchEdges
                where !matchedSubjectIndices.contains(edge.subjectIndex)
                    && !matchedBoxIndices.contains(edge.boxIndex) {
                matchedSubjectIndices.insert(edge.subjectIndex)
                matchedBoxIndices.insert(edge.boxIndex)
            }

            for (boxIndex, box) in asset.resolvedBoundingBoxes.enumerated() {
                let resolvedBySubject = matchedBoxIndices.contains(boxIndex)
                let resolvedBySingleCatFallback = hasSubjectlessIncludedMembership
                    && asset.detectedCatCount <= 1
                    && asset.resolvedBoundingBoxes.count == 1
                guard !resolvedBySubject, !resolvedBySingleCatFallback else {
                    continue
                }

                let candidate = CatSimilarityCandidateInstance(
                    assetLocalIdentifier: asset.assetLocalIdentifier,
                    boundingBox: box
                )
                if seen.insert(candidate).inserted {
                    output.append(candidate)
                }
            }
        }

        return output.sorted(by: stableCandidateOrder)
    }

    private static func intersectionOverUnion(
        _ lhs: NormalizedRect,
        _ rhs: NormalizedRect
    ) -> Double {
        guard lhs.x.isFinite,
              lhs.y.isFinite,
              lhs.width.isFinite,
              lhs.height.isFinite,
              rhs.x.isFinite,
              rhs.y.isFinite,
              rhs.width.isFinite,
              rhs.height.isFinite,
              lhs.width > 0,
              lhs.height > 0,
              rhs.width > 0,
              rhs.height > 0 else { return 0 }

        let minimumX = max(lhs.x, rhs.x)
        let maximumX = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let minimumY = max(lhs.y, rhs.y)
        let maximumY = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersectionWidth = max(0, maximumX - minimumX)
        let intersectionHeight = max(0, maximumY - minimumY)
        let intersectionArea = intersectionWidth * intersectionHeight
        let unionArea = lhs.area + rhs.area - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }
}

/// A similarity proposal may fill an old subject-less photo membership, but
/// it never replaces an exact cat instance already confirmed for that profile.
/// Explicit correction screens remain the only authority for such a move.
enum CatSimilaritySuggestionConfirmationPolicy {
    static func canAssign(
        hasIncludedMembership: Bool,
        existingSubjectBoundingBox: NormalizedRect?
    ) -> Bool {
        !hasIncludedMembership || existingSubjectBoundingBox == nil
    }
}

/// Opaque identifiers are random per generated session and have no persistence
/// or cross-device meaning. Their ordinals keep instances and groups stable
/// while the user splits groups inside that one in-memory session.
struct CatSimilaritySessionInstanceID: Equatable, Hashable, Sendable {
    private let sessionID: UUID
    private let ordinal: Int

    init(sessionID: UUID, ordinal: Int) {
        self.sessionID = sessionID
        self.ordinal = ordinal
    }
}

struct CatSimilaritySessionGroupID: Equatable, Hashable, Sendable {
    private let sessionID: UUID
    private let ordinal: Int

    init(sessionID: UUID, ordinal: Int) {
        self.sessionID = sessionID
        self.ordinal = ordinal
    }
}

struct CatSimilaritySessionInstance: Identifiable, Equatable, Hashable, Sendable {
    let id: CatSimilaritySessionInstanceID
    let candidate: CatSimilarityCandidateInstance
}

/// A review proposal only. It deliberately contains no score, probability,
/// feature vector, profile identifier, or identity-membership decision.
struct CatSimilarityCandidateGroup: Identifiable, Equatable, Sendable {
    let id: CatSimilaritySessionGroupID
    let representativeInstanceID: CatSimilaritySessionInstanceID
    let instances: [CatSimilaritySessionInstance]
}

enum CatSimilarityUngroupedReason: Equatable, Sendable {
    case assetUnavailableLocally
    case featurePrintUnavailable
}

struct CatSimilarityUngroupedInstance: Equatable, Sendable {
    let instance: CatSimilaritySessionInstance
    let reason: CatSimilarityUngroupedReason
}

/// No type in this result is `Codable`; the proposal and its PhotoKit
/// identifiers are intentionally confined to the current in-memory session.
struct CatSimilarityGroupingResult: Equatable, Sendable {
    let groups: [CatSimilarityCandidateGroup]
    let ungroupedInstances: [CatSimilarityUngroupedInstance]
}

enum CatSimilarityGroupingPhase: Equatable, Sendable {
    case generatingFeaturePrints
    case computingDistances
    case clustering
}

struct CatSimilarityGroupingProgress: Equatable, Sendable {
    let phase: CatSimilarityGroupingPhase
    let completedUnitCount: Int
    let totalUnitCount: Int
}

enum CatSimilarityGroupingError: Error, Equatable, Sendable {
    case invalidTargetGroupCount
    case invalidCandidate(inputIndex: Int)
    case duplicateCandidate(inputIndex: Int)
    case distanceComputationFailed
    case noActiveSession
    case groupNotFound
    case groupCannotBeSplit
}

func stableCandidateOrder(
    _ lhs: CatSimilarityCandidateInstance,
    _ rhs: CatSimilarityCandidateInstance
) -> Bool {
    if lhs.assetLocalIdentifier != rhs.assetLocalIdentifier {
        return lhs.assetLocalIdentifier < rhs.assetLocalIdentifier
    }
    let left = [
        lhs.boundingBox.x,
        lhs.boundingBox.y,
        lhs.boundingBox.width,
        lhs.boundingBox.height
    ]
    let right = [
        rhs.boundingBox.x,
        rhs.boundingBox.y,
        rhs.boundingBox.width,
        rhs.boundingBox.height
    ]
    for (leftValue, rightValue) in zip(left, right)
        where leftValue != rightValue {
        return leftValue < rightValue
    }
    return false
}

/// Compact symmetric storage for raw FeaturePrint distances. Distances never
/// cross the service API and are never interpreted as probabilities.
struct CatSimilarityDistanceMatrix: Sendable {
    let count: Int
    private var upperTriangle: [Float]

    init(count: Int) {
        precondition(count >= 0)
        self.count = count
        upperTriangle = Array(
            repeating: .nan,
            count: count > 1 ? count * (count - 1) / 2 : 0
        )
    }

    mutating func setDistance(
        _ distance: Float,
        between firstIndex: Int,
        and secondIndex: Int
    ) throws {
        guard firstIndex >= 0,
              firstIndex < count,
              secondIndex >= 0,
              secondIndex < count,
              distance.isFinite,
              distance >= 0 else {
            throw CatSimilarityGroupingError.distanceComputationFailed
        }
        guard firstIndex != secondIndex else {
            guard distance == 0 else {
                throw CatSimilarityGroupingError.distanceComputationFailed
            }
            return
        }
        upperTriangle[storageIndex(firstIndex, secondIndex)] = distance
    }

    func distance(between firstIndex: Int, and secondIndex: Int) -> Float {
        precondition(firstIndex >= 0 && firstIndex < count)
        precondition(secondIndex >= 0 && secondIndex < count)
        if firstIndex == secondIndex { return 0 }
        return upperTriangle[storageIndex(firstIndex, secondIndex)]
    }

    func selecting(_ indices: [Int]) throws -> CatSimilarityDistanceMatrix {
        var selected = CatSimilarityDistanceMatrix(count: indices.count)
        for first in indices.indices {
            guard indices[first] >= 0, indices[first] < count else {
                throw CatSimilarityGroupingError.distanceComputationFailed
            }
            for second in indices.indices where second > first {
                guard indices[second] >= 0, indices[second] < count else {
                    throw CatSimilarityGroupingError.distanceComputationFailed
                }
                try selected.setDistance(
                    distance(between: indices[first], and: indices[second]),
                    between: first,
                    and: second
                )
            }
        }
        return selected
    }

    func validate() throws {
        guard upperTriangle.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw CatSimilarityGroupingError.distanceComputationFailed
        }
    }

    private func storageIndex(_ firstIndex: Int, _ secondIndex: Int) -> Int {
        let lower = min(firstIndex, secondIndex)
        let upper = max(firstIndex, secondIndex)
        return lower * count - lower * (lower + 1) / 2
            + (upper - lower - 1)
    }
}

struct CatSimilarityIndexCluster: Equatable, Sendable {
    let medoidIndex: Int
    let memberIndices: [Int]
}

/// Deterministic farthest-first seeding followed by bounded k-medoids updates.
/// Canonical candidate order is the final tie-breaker everywhere.
enum CatSimilarityKMedoids {
    static let maximumRefinementIterations = 32

    static func clusters(
        distances: CatSimilarityDistanceMatrix,
        targetGroupCount: Int,
        cancellationCheck: () throws -> Void = {}
    ) throws -> [CatSimilarityIndexCluster] {
        guard targetGroupCount > 0 else {
            throw CatSimilarityGroupingError.invalidTargetGroupCount
        }
        try distances.validate()
        guard distances.count > 0 else { return [] }

        let groupCount = min(targetGroupCount, distances.count)
        var medoids = try farthestFirstMedoids(
            distances: distances,
            count: groupCount,
            cancellationCheck: cancellationCheck
        )

        for _ in 0..<maximumRefinementIterations {
            try cancellationCheck()
            let members = try assign(
                distances: distances,
                medoids: medoids,
                cancellationCheck: cancellationCheck
            )
            var updated: [Int] = []
            updated.reserveCapacity(medoids.count)
            for clusterMembers in members {
                updated.append(
                    try bestMedoid(
                        in: clusterMembers,
                        distances: distances,
                        cancellationCheck: cancellationCheck
                    )
                )
            }
            updated.sort()
            if updated == medoids { break }
            medoids = updated
        }

        let finalMembers = try assign(
            distances: distances,
            medoids: medoids,
            cancellationCheck: cancellationCheck
        )
        return zip(medoids, finalMembers).map { pair in
            CatSimilarityIndexCluster(
                medoidIndex: pair.0,
                memberIndices: pair.1.sorted()
            )
        }
    }

    private static func farthestFirstMedoids(
        distances: CatSimilarityDistanceMatrix,
        count: Int,
        cancellationCheck: () throws -> Void
    ) throws -> [Int] {
        var firstMedoid = 0
        var firstCost = Double.greatestFiniteMagnitude
        for candidate in 0..<distances.count {
            if candidate.isMultiple(of: 32) { try cancellationCheck() }
            var cost = 0.0
            for other in 0..<distances.count {
                cost += Double(
                    distances.distance(between: candidate, and: other)
                )
            }
            if cost < firstCost || (cost == firstCost && candidate < firstMedoid) {
                firstMedoid = candidate
                firstCost = cost
            }
        }

        var medoids = [firstMedoid]
        var medoidSet: Set<Int> = [firstMedoid]
        while medoids.count < count {
            try cancellationCheck()
            var selected: Int?
            var selectedDistance = -Float.infinity
            for candidate in 0..<distances.count where !medoidSet.contains(candidate) {
                let nearestDistance = medoids.lazy.map {
                    distances.distance(between: candidate, and: $0)
                }.min() ?? 0
                if nearestDistance > selectedDistance
                    || (nearestDistance == selectedDistance
                        && candidate < (selected ?? Int.max)) {
                    selected = candidate
                    selectedDistance = nearestDistance
                }
            }
            guard let selected else {
                throw CatSimilarityGroupingError.distanceComputationFailed
            }
            medoids.append(selected)
            medoidSet.insert(selected)
        }
        return medoids.sorted()
    }

    private static func assign(
        distances: CatSimilarityDistanceMatrix,
        medoids: [Int],
        cancellationCheck: () throws -> Void
    ) throws -> [[Int]] {
        let medoidSlot = Dictionary(uniqueKeysWithValues: medoids.enumerated().map {
            ($0.element, $0.offset)
        })
        var members = Array(repeating: [Int](), count: medoids.count)
        for candidate in 0..<distances.count {
            if candidate.isMultiple(of: 64) { try cancellationCheck() }
            // Even identical feature prints keep exactly k non-empty groups.
            if let ownSlot = medoidSlot[candidate] {
                members[ownSlot].append(candidate)
                continue
            }

            var selectedSlot = 0
            var selectedDistance = distances.distance(
                between: candidate,
                and: medoids[0]
            )
            for slot in medoids.indices.dropFirst() {
                let candidateDistance = distances.distance(
                    between: candidate,
                    and: medoids[slot]
                )
                if candidateDistance < selectedDistance
                    || (candidateDistance == selectedDistance
                        && medoids[slot] < medoids[selectedSlot]) {
                    selectedSlot = slot
                    selectedDistance = candidateDistance
                }
            }
            members[selectedSlot].append(candidate)
        }
        return members
    }

    private static func bestMedoid(
        in members: [Int],
        distances: CatSimilarityDistanceMatrix,
        cancellationCheck: () throws -> Void
    ) throws -> Int {
        guard let first = members.first else {
            throw CatSimilarityGroupingError.distanceComputationFailed
        }
        var selected = first
        var selectedCost = Double.greatestFiniteMagnitude
        for (offset, candidate) in members.enumerated() {
            if offset.isMultiple(of: 32) { try cancellationCheck() }
            var cost = 0.0
            for other in members {
                cost += Double(
                    distances.distance(between: candidate, and: other)
                )
            }
            if cost < selectedCost || (cost == selectedCost && candidate < selected) {
                selected = candidate
                selectedCost = cost
            }
        }
        return selected
    }
}
