// Run from NekoWidget/:
//   xcrun swiftc Shared/Models/NormalizedRect.swift \
//     NekoWidget/Services/CatSimilarityGroupingCore.swift \
//     ci/verify-cat-similarity-grouping.swift \
//     -o /tmp/verify-cat-similarity-grouping && \
//     /tmp/verify-cat-similarity-grouping

import Foundation

@main
enum CatSimilarityGroupingVerifier {
    static func main() throws {
        try verifiesFeaturePolicyIsPinned()
        try verifiesResolverLeavesOnlyTheOtherCatAfterOneSubjectIsKnown()
        try verifiesSubjectlessMembershipNeverGuessesInMultiCatPhoto()
        try verifiesSubjectlessMembershipResolvesOneCatPhoto()
        try verifiesSubjectIoUBoundary()
        try verifiesOneOverlappingSubjectResolvesOnlyOneCat()
        try verifiesSuggestionCannotReplaceAConfirmedInstance()
        try verifiesSplitSiblingProfileConflictIsRecoverable()
        try verifiesRetryCandidateBufferUsesLatestUnresolvedCandidates()
        try verifiesOnlyPersistenceFailureUsesFatalTransition()
        try verifiesTwoSeparatedDistanceGroups()
        try verifiesInputOrderTieBreaksAreDeterministic()
        try verifiesIdenticalPrintsStillProduceNonemptyGroups()
        try verifiesDefaultSizedRequestProducesTwentyGroups()
        try verifiesSubmatrixCanBeSplitAgain()
        print("Cat similarity grouping verifier passed")
    }

    private static func verifiesFeaturePolicyIsPinned() throws {
        try require(
            CatSimilarityFeaturePolicy.requestRevision == 2,
            "FeaturePrint request revision changed without a migration"
        )
        try require(
            CatSimilarityFeaturePolicy.cropPolicyRevision == 1
                && CatSimilarityFeaturePolicy.cropExpansionFractionPerEdge == 0.10,
            "FeaturePrint crop policy changed without a migration"
        )
        let clamped = CatSimilarityFeaturePolicy.cropRegion(
            for: NormalizedRect(x: 0, y: 0.9, width: 0.2, height: 0.1)
        )
        try require(
            approximatelyEqual(clamped.x, 0)
                && approximatelyEqual(clamped.y, 0.89)
                && approximatelyEqual(clamped.width, 0.22)
                && approximatelyEqual(clamped.height, 0.11),
            "FeaturePrint crop no longer expands per edge and clamps to unit space"
        )
    }

    private static func verifiesResolverLeavesOnlyTheOtherCatAfterOneSubjectIsKnown()
        throws {
        let left = NormalizedRect(x: 0.05, y: 0.10, width: 0.35, height: 0.60)
        let right = NormalizedRect(x: 0.60, y: 0.10, width: 0.35, height: 0.60)
        let result = CatSimilarityCandidateResolver.unresolvedInstances(
            from: [
                CatSimilarityCandidateAsset(
                    assetLocalIdentifier: "two-cats",
                    detectedCatCount: 2,
                    resolvedBoundingBoxes: [left, right],
                    includedMembershipSubjectBoundingBoxes: [left]
                )
            ]
        )
        try require(
            result == [
                CatSimilarityCandidateInstance(
                    assetLocalIdentifier: "two-cats",
                    boundingBox: right
                )
            ],
            "confirming one subject did not leave exactly the other box unresolved"
        )
    }

    private static func verifiesSubjectlessMembershipNeverGuessesInMultiCatPhoto()
        throws {
        let left = NormalizedRect(x: 0.05, y: 0.10, width: 0.35, height: 0.60)
        let right = NormalizedRect(x: 0.60, y: 0.10, width: 0.35, height: 0.60)
        let result = CatSimilarityCandidateResolver.unresolvedInstances(
            from: [
                CatSimilarityCandidateAsset(
                    assetLocalIdentifier: "ambiguous",
                    detectedCatCount: 2,
                    resolvedBoundingBoxes: [right, left],
                    includedMembershipSubjectBoundingBoxes: [nil]
                )
            ]
        )
        try require(
            result.map(\.boundingBox) == [left, right],
            "a subject-less multi-cat membership guessed an instance"
        )
    }

    private static func verifiesSubjectlessMembershipResolvesOneCatPhoto() throws {
        let only = NormalizedRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
        let result = CatSimilarityCandidateResolver.unresolvedInstances(
            from: [
                CatSimilarityCandidateAsset(
                    assetLocalIdentifier: "one-cat",
                    detectedCatCount: 1,
                    resolvedBoundingBoxes: [only],
                    includedMembershipSubjectBoundingBoxes: [nil]
                )
            ]
        )
        try require(result.isEmpty, "one-cat included fallback stayed unresolved")
    }

    private static func verifiesSubjectIoUBoundary() throws {
        let box = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        let atBoundary = NormalizedRect(x: 0, y: 0, width: 0.35, height: 1)
        let belowBoundary = NormalizedRect(x: 0, y: 0, width: 0.349, height: 1)

        let result = CatSimilarityCandidateResolver.unresolvedInstances(
            from: [
                CatSimilarityCandidateAsset(
                    assetLocalIdentifier: "at-boundary",
                    detectedCatCount: 2,
                    resolvedBoundingBoxes: [box],
                    includedMembershipSubjectBoundingBoxes: [atBoundary]
                ),
                CatSimilarityCandidateAsset(
                    assetLocalIdentifier: "below-boundary",
                    detectedCatCount: 2,
                    resolvedBoundingBoxes: [box],
                    includedMembershipSubjectBoundingBoxes: [belowBoundary]
                )
            ]
        )
        try require(
            result.map(\.assetLocalIdentifier) == ["below-boundary"],
            "subject IoU 0.35 boundary changed"
        )
    }

    private static func verifiesOneOverlappingSubjectResolvesOnlyOneCat() throws {
        let first = NormalizedRect(x: 0, y: 0, width: 0.6, height: 1)
        let second = NormalizedRect(x: 0.3, y: 0, width: 0.6, height: 1)
        let result = CatSimilarityCandidateResolver.unresolvedInstances(
            from: [
                CatSimilarityCandidateAsset(
                    assetLocalIdentifier: "overlapping-cats",
                    detectedCatCount: 2,
                    resolvedBoundingBoxes: [first, second],
                    includedMembershipSubjectBoundingBoxes: [first]
                )
            ]
        )
        try require(
            result == [
                CatSimilarityCandidateInstance(
                    assetLocalIdentifier: "overlapping-cats",
                    boundingBox: second
                )
            ],
            "one overlapping subject incorrectly resolved more than one cat"
        )
    }

    private static func verifiesSuggestionCannotReplaceAConfirmedInstance() throws {
        let box = NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.6)
        try require(
            CatSimilaritySuggestionConfirmationPolicy.canAssign(
                hasIncludedMembership: false,
                existingSubjectBoundingBox: nil
            ),
            "an unknown profile membership could not accept confirmation"
        )
        try require(
            CatSimilaritySuggestionConfirmationPolicy.canAssign(
                hasIncludedMembership: true,
                existingSubjectBoundingBox: nil
            ),
            "a legacy subject-less membership could not be made exact"
        )
        try require(
            !CatSimilaritySuggestionConfirmationPolicy.canAssign(
                hasIncludedMembership: true,
                existingSubjectBoundingBox: box
            ),
            "a suggestion could replace an already confirmed cat instance"
        )
        try require(
            CatSimilaritySuggestionConfirmationPolicy.decision(
                hasIncludedMembership: true,
                existingSubjectBoundingBox: box,
                candidateBoundingBox: box
            ) == .alreadyCommitted,
            "an exact retry stopped being idempotent"
        )
    }

    private static func verifiesSplitSiblingProfileConflictIsRecoverable() throws {
        let first = CatSimilarityCandidateInstance(
            assetLocalIdentifier: "shared-photo",
            boundingBox: NormalizedRect(x: 0.05, y: 0.1, width: 0.4, height: 0.7)
        )
        let second = CatSimilarityCandidateInstance(
            assetLocalIdentifier: "shared-photo",
            boundingBox: NormalizedRect(x: 0.55, y: 0.1, width: 0.4, height: 0.7)
        )
        var tracker = CatSimilaritySessionConfirmationTracker()
        tracker.recordCommitted(profileIdentifier: "mugi", candidates: [first])

        try require(
            tracker.conflicts(profileIdentifier: "mugi", candidates: [second]),
            "a split sibling offered the same profile twice for one photo"
        )
        try require(
            !tracker.conflicts(profileIdentifier: "ame", candidates: [second]),
            "a split sibling blocked a different profile for the same photo"
        )
        try require(
            CatSimilaritySuggestionConfirmationPolicy.decision(
                hasIncludedMembership: true,
                existingSubjectBoundingBox: first.boundingBox,
                candidateBoundingBox: second.boundingBox
            ) == .profileAlreadyAssigned,
            "the durable guard allowed split sibling B to replace mugi's box A"
        )
        try require(
            CatSimilaritySuggestionConfirmationPolicy.decision(
                hasIncludedMembership: false,
                existingSubjectBoundingBox: nil,
                candidateBoundingBox: second.boundingBox
            ) == .assign,
            "split sibling B could not be assigned to ame"
        )
        try require(
            CatSimilarityReviewConfirmationTransition.transition(
                for: .conflict(reason: .profileAlreadyAssigned)
            ) == .stayForProfileConflict,
            "a same-profile split conflict became a fatal review failure"
        )
        try require(
            CatSimilarityReviewConfirmationTransition.transition(for: .committed)
                == .advanceCommitted,
            "a different-profile confirmation could not advance"
        )
    }

    private static func verifiesRetryCandidateBufferUsesLatestUnresolvedCandidates()
        throws {
        let initial = (0..<12).map { index in
            CatSimilarityCandidateInstance(
                assetLocalIdentifier: "photo-\(index)",
                boundingBox: NormalizedRect(
                    x: Double(index) / 100,
                    y: 0.1,
                    width: 0.2,
                    height: 0.3
                )
            )
        }
        var buffer = CatSimilarityReviewCandidateBuffer(candidates: initial)
        let latestAfterEightCommits = CatSimilarityCandidateResolver.unresolvedInstances(
            from: initial.enumerated().map { index, candidate in
                CatSimilarityCandidateAsset(
                    assetLocalIdentifier: candidate.assetLocalIdentifier,
                    detectedCatCount: 1,
                    resolvedBoundingBoxes: [candidate.boundingBox],
                    includedMembershipSubjectBoundingBoxes: index < 8
                        ? [candidate.boundingBox]
                        : []
                )
            }
        )
        buffer.replaceWithLatest(latestAfterEightCommits)

        try require(
            buffer.candidates == latestAfterEightCommits
                && buffer.candidates.count == initial.count - 8,
            "retry reused the navigation-time candidate snapshot"
        )
    }

    private static func verifiesOnlyPersistenceFailureUsesFatalTransition() throws {
        let nonfatalOutcomes: [CatSimilarityGroupConfirmationOutcome] = [
            .committed,
            .conflict(reason: .profileAlreadyAssigned),
            .conflict(reason: .staleCandidates),
            .conflict(reason: .invalidGroup)
        ]
        try require(
            nonfatalOutcomes.allSatisfy {
                CatSimilarityReviewConfirmationTransition.transition(for: $0) != .fail
            },
            "a recoverable confirmation outcome became fatal"
        )
        try require(
            CatSimilarityReviewConfirmationTransition.transition(for: .failed) == .fail,
            "a persistence failure stopped using the fatal review state"
        )
    }

    private static func verifiesTwoSeparatedDistanceGroups() throws {
        let distances = try lineDistanceMatrix([0, 0.1, 10, 10.1])
        let clusters = try CatSimilarityKMedoids.clusters(
            distances: distances,
            targetGroupCount: 2
        )
        try require(
            clusters.map(\.memberIndices) == [[0, 1], [2, 3]],
            "two separated pairs were not grouped together"
        )
    }

    private static func verifiesInputOrderTieBreaksAreDeterministic() throws {
        let distances = try lineDistanceMatrix([0, 1, 2, 3, 4, 5])
        let first = try CatSimilarityKMedoids.clusters(
            distances: distances,
            targetGroupCount: 3
        )
        let second = try CatSimilarityKMedoids.clusters(
            distances: distances,
            targetGroupCount: 3
        )
        try require(first == second, "the same matrix produced unstable groups")
        try require(
            first.flatMap(\.memberIndices).sorted() == Array(0..<6),
            "deterministic grouping lost or duplicated an instance"
        )
    }

    private static func verifiesIdenticalPrintsStillProduceNonemptyGroups() throws {
        let distances = try lineDistanceMatrix([0, 0, 0, 0])
        let clusters = try CatSimilarityKMedoids.clusters(
            distances: distances,
            targetGroupCount: 3
        )
        try require(clusters.count == 3, "identical prints collapsed requested groups")
        try require(
            clusters.allSatisfy { !$0.memberIndices.isEmpty },
            "identical prints created an empty group"
        )
        try require(
            clusters.flatMap(\.memberIndices).sorted() == Array(0..<4),
            "identical-print grouping lost or duplicated an instance"
        )
    }

    private static func verifiesDefaultSizedRequestProducesTwentyGroups() throws {
        let distances = try lineDistanceMatrix((0..<25).map { Double($0) })
        let clusters = try CatSimilarityKMedoids.clusters(
            distances: distances,
            targetGroupCount: 20
        )
        try require(clusters.count == 20, "twenty-group target was not honored")
        try require(
            clusters.allSatisfy { !$0.memberIndices.isEmpty },
            "twenty-group target produced an empty group"
        )
    }

    private static func verifiesSubmatrixCanBeSplitAgain() throws {
        let full = try lineDistanceMatrix([0, 0.1, 5, 5.1, 10, 10.1])
        let selected = try full.selecting([2, 3, 4, 5])
        let split = try CatSimilarityKMedoids.clusters(
            distances: selected,
            targetGroupCount: 2
        )
        try require(
            split.map(\.memberIndices) == [[0, 1], [2, 3]],
            "selected group did not split into its two internal modes"
        )
    }

    private static func lineDistanceMatrix(
        _ values: [Double]
    ) throws -> CatSimilarityDistanceMatrix {
        var matrix = CatSimilarityDistanceMatrix(count: values.count)
        for first in values.indices {
            for second in values.indices where second > first {
                try matrix.setDistance(
                    Float(abs(values[first] - values[second])),
                    between: first,
                    and: second
                )
            }
        }
        return matrix
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw NSError(
                domain: "CatSimilarityGroupingVerifier",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private static func approximatelyEqual(
        _ lhs: Double,
        _ rhs: Double,
        tolerance: Double = 0.000_000_1
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
