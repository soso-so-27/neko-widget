import CoreGraphics
import Foundation

@main
enum CatSimilarityReviewPresentationVerifier {
    static func main() throws {
        try verifiesMultiCatCandidatesRemainSeparate()
        try verifiesSamePhotoInstancesRequireSplitBeforeConfirmation()
        try verifiesQuestionAndProfileOrdering()
        try verifiesProgressNormalization()
        try verifiesProfileIsTheOnlyBlockingPrerequisite()
        try verifiesMissingAnchorPresentation()
        print("Cat similarity review presentation verifier passed")
    }

    private static func verifiesMultiCatCandidatesRemainSeparate() throws {
        let left = candidate(
            identifier: "photo-1#0",
            asset: "photo-1",
            x: 0.05
        )
        let right = candidate(
            identifier: "photo-1#1",
            asset: "photo-1",
            x: 0.55
        )
        let group = CatSimilarityReviewGroupPresentation(
            identifier: "group-1",
            candidates: [left, right],
            suggestedProfileIdentifier: nil
        )

        try require(
            group.candidates.map(\.assetLocalIdentifier) == ["photo-1", "photo-1"],
            "a multi-cat photo stopped sharing its PhotoKit asset"
        )
        try require(
            Set(group.candidates.map(\.id)).count == 2,
            "two cats in one photo were collapsed into one review candidate"
        )
        try require(
            group.candidates[0].subjectBoundingBox
                != group.candidates[1].subjectBoundingBox,
            "per-cat crop boxes were lost"
        )
    }

    private static func verifiesSamePhotoInstancesRequireSplitBeforeConfirmation()
        throws {
        let samePhoto = CatSimilarityReviewPresentation(
            phase: .reviewing,
            profiles: [profile("mugi", "むぎ")],
            groups: [
                CatSimilarityReviewGroupPresentation(
                    identifier: "same-photo",
                    candidates: [
                        candidate(identifier: "cat-1", asset: "photo"),
                        candidate(identifier: "cat-2", asset: "photo", x: 0.6)
                    ],
                    suggestedProfileIdentifier: nil
                )
            ]
        )
        try require(
            samePhoto.currentGroupRequiresSplitBeforeConfirmation,
            "two instances from one photo could be confirmed to one profile"
        )

        let separatePhotos = CatSimilarityReviewPresentation(
            phase: .reviewing,
            profiles: [profile("mugi", "むぎ")],
            groups: [
                CatSimilarityReviewGroupPresentation(
                    identifier: "separate-photos",
                    candidates: [
                        candidate(identifier: "cat-1", asset: "photo-1"),
                        candidate(identifier: "cat-2", asset: "photo-2")
                    ],
                    suggestedProfileIdentifier: nil
                )
            ]
        )
        try require(
            !separatePhotos.currentGroupRequiresSplitBeforeConfirmation,
            "separate photos were unnecessarily blocked from confirmation"
        )
    }

    private static func verifiesQuestionAndProfileOrdering() throws {
        let mugi = profile("mugi", "  むぎ ")
        let ame = profile("ame", "あめ")
        let group = CatSimilarityReviewGroupPresentation(
            identifier: "group-2",
            candidates: [candidate(identifier: "photo-2#0", asset: "photo-2")],
            suggestedProfileIdentifier: "mugi"
        )
        let presentation = CatSimilarityReviewPresentation(
            phase: .reviewing,
            profiles: [ame, mugi],
            groups: [group]
        )

        try require(
            presentation.currentQuestion == "このグループは全部「むぎ」？",
            "the explicit group-confirmation question changed"
        )
        try require(
            presentation.profilesForCurrentQuestion.map(\.identifier)
                == ["mugi", "ame"],
            "the suggested button was not shown first"
        )
        try require(
            presentation.reviewProgress.label == "1/1",
            "review progress stopped using group counts"
        )

        let noSuggestion = CatSimilarityReviewPresentation(
            phase: .reviewing,
            profiles: [mugi, ame],
            groups: [
                CatSimilarityReviewGroupPresentation(
                    identifier: "group-3",
                    candidates: [],
                    suggestedProfileIdentifier: nil
                )
            ]
        )
        try require(
            noSuggestion.currentQuestion == "このグループはどの子？",
            "an unlabeled similarity cluster was silently assigned a cat name"
        )
    }

    private static func verifiesProgressNormalization() throws {
        let overflow = CatSimilarityReviewPresentation(
            phase: .grouping(completedCandidateCount: 120, totalCandidateCount: 100)
        )
        try require(
            overflow.generationProgress
                == CatSimilarityReviewProgressPresentation(
                    completedCount: 100,
                    totalCount: 100
                ),
            "generation progress was allowed beyond its total"
        )

        let negative = CatSimilarityReviewPresentation(
            phase: .grouping(completedCandidateCount: -1, totalCandidateCount: -2)
        )
        try require(
            negative.generationProgress?.fraction == 0,
            "empty generation progress did not remain finite"
        )
    }

    private static func verifiesMissingAnchorPresentation() throws {
        let mugi = profile("mugi", "むぎ", anchorPhotoCount: 1)
        let ame = profile("ame", "あめ", anchorPhotoCount: 0)
        let presentation = CatSimilarityReviewPresentation(
            phase: .ready(candidateCount: 894, targetGroupCount: 20),
            profiles: [mugi, ame]
        )

        try require(
            presentation.profilesWithoutAnchors.map(\.identifier) == ["ame"],
            "anchor guidance included a ready profile or omitted a missing one"
        )
        try require(!ame.hasAnchor, "a zero-anchor profile was treated as ready")
        try require(
            presentation.displayPhase
                == .ready(candidateCount: 894, targetGroupCount: 20),
            "a missing optional anchor blocked unsupervised grouping"
        )
    }

    private static func verifiesProfileIsTheOnlyBlockingPrerequisite() throws {
        let noProfiles = CatSimilarityReviewPresentation(
            phase: .ready(candidateCount: 894, targetGroupCount: 20)
        )
        try require(
            noProfiles.displayPhase == .unavailable(.noProfiles),
            "group review started without a destination profile"
        )
    }

    private static func candidate(
        identifier: String,
        asset: String,
        x: CGFloat = 0.1
    ) -> CatSimilarityReviewCandidatePresentation {
        CatSimilarityReviewCandidatePresentation(
            identifier: identifier,
            assetLocalIdentifier: asset,
            subjectBoundingBox: CGRect(x: x, y: 0.2, width: 0.3, height: 0.4)
        )
    }

    private static func profile(
        _ identifier: String,
        _ name: String,
        anchorPhotoCount: Int = 1
    ) -> CatSimilarityReviewProfilePresentation {
        CatSimilarityReviewProfilePresentation(
            identifier: identifier,
            name: name,
            anchorPhotoCount: anchorPhotoCount
        )
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw VerificationError(message: message)
        }
    }
}

private struct VerificationError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
