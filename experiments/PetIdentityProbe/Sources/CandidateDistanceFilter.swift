import Foundation

// No scores, vectors or individual rankings are persisted or shared.
enum CandidateDistanceStatus: String, CaseIterable {
    case withinReferenceRange, outsideReferenceRange, referenceRangeUnavailable, notRanked
}

struct CandidateDistanceAssessment {
    let ranking: IdentityRankingOutcome // Unchanged pre-filter ranking, local comparison only.
    let status: CandidateDistanceStatus

    var suggestedCat: CandidateReviewChoice? {
        guard status == .withinReferenceRange else { return nil }
        return ranking == .a ? .a : ranking == .b ? .b : nil
    }
    var isWithheld: Bool { status == .outsideReferenceRange || status == .referenceRangeUnavailable }
    var withheldTitle: String? {
        switch status {
        case .outsideReferenceRange: "見本との違いが大きいため、候補を出していません"
        case .referenceRangeUnavailable: "見本から比較範囲を決められないため、個別に確認"
        default: nil
        }
    }
}

// Aggregate effect of one fixed filter, not identity accuracy or threshold fitting.
struct CandidateDistanceFilterCounts: Encodable {
    let policy = "winner-second-nearest-distance<=winner-registration-loo-radius*1.25;nonpositive-radius-withheld;no-ratio-gate;no-runner-up-fallback"
    let scope = "fixed-registration-only-filter;no-feedback-training-or-evaluation-tuning;withheld-is-not-unknown-cat-detection;not-independent-accuracy"
    let photoStatusCounts: [String: Int]
    let rankedPhotosBeforeFilter: Int
    let suggestedPhotosAfterFilter: Int
    let withheldPhotos: Int
    let regionStatusCounts: [String: Int]
    let rankedRegionsBeforeFilter: Int
    let suggestedRegionsAfterFilter: Int
    let priorConfirmationScope = "pre-filter-rank-vs-restored-human-choice-only;confirmation-bias;no-new-choices;photo-level-only;not-accuracy"
    let priorConfirmationRows = ["kept", "withheld"]
    let priorConfirmationColumns = ["sameCat", "differentCat", "both", "other", "unsure", "noPriorConfirmation"]
    let priorConfirmationCounts: [[Int]]

    init(session: CandidateReviewSession) {
        let photos = session.run.photos
        func counts(_ values: [CandidateDistanceAssessment?]) -> [String: Int] {
            var result = Dictionary(uniqueKeysWithValues: CandidateDistanceStatus.allCases.map { status in
                (status.rawValue, values.filter { $0?.status == status }.count)
            })
            result["notAssessed"] = values.filter { $0 == nil }.count
            return result
        }
        let eligible = photos.filter { $0.image != nil && $0.issue == nil && $0.regionReview == nil }
        let ranked = eligible.filter { $0.distanceAssessment?.ranking == .a || $0.distanceAssessment?.ranking == .b }
        photoStatusCounts = counts(photos.map(\.distanceAssessment))
        rankedPhotosBeforeFilter = ranked.count
        suggestedPhotosAfterFilter = ranked.filter { $0.batchSuggestion != nil }.count
        withheldPhotos = ranked.filter { $0.distanceAssessment?.isWithheld == true }.count
        let regions = photos.flatMap { $0.regionReview?.regions ?? [] }
        regionStatusCounts = counts(regions.map { $0.assessment })
        rankedRegionsBeforeFilter = regions.filter { $0.assessment.ranking == .a || $0.assessment.ranking == .b }.count
        suggestedRegionsAfterFilter = regions.filter { $0.suggestion != nil }.count
        var matrix = Array(repeating: Array(repeating: 0, count: 6), count: 2)
        for photo in ranked {
            guard let assessment = photo.distanceAssessment else { continue }
            let row = assessment.isWithheld ? 1 : 0
            var column = 5
            if session.restoredIDs.contains(photo.id), let choice = session.decisions[photo.id] {
                switch choice {
                case .a, .b:
                    let matches = (choice == .a && assessment.ranking == .a) || (choice == .b && assessment.ranking == .b)
                    column = matches ? 0 : 1
                case .both: column = 2
                case .other: column = 3
                case .unsure: column = 4
                }
            }
            matrix[row][column] += 1
        }
        priorConfirmationCounts = matrix
    }
}
