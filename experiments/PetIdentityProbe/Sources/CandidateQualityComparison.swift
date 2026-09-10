import Foundation

// Compare the CURRENT fixed proposals with the user's current saved decisions.
// This is feedback for development, not an independent ground truth / release gate.
// No photo-level records, detector boxes, model scores or identifiers are exported.
struct CandidateQualityComparison: Encodable {
    let scope = "current-proposals-vs-current-and-restored-human-decisions;post-suggestion-confirmation-bias;photo-level-only;not-independent-accuracy"
    let decisionMeaning = "new-choices-a-or-b-is-that-cat-only;new-both-is-a-and-b;new-other-includes-another-cat;restored-choices-retain-original-meaning;legacy-decisions-not-reinterpreted-as-independent-truth"
    let rows = ["candidateA", "candidateB", "distanceWithheld", "individual"]
    let columns = ["a", "b", "both", "other", "unsure", "unreviewed"]
    let counts: [[Int]]
    let restoredCounts: [[Int]]
    let selected: Int
    let reviewedWithKnownChoice: Int
    let restoredChoices: Int
    let unreviewed: Int
    let unsure: Int
    let proposed: Int
    let reviewedProposals: Int
    let matchingProposals: Int
    let differentCatProposals: Int
    let bothInSingleCatProposals: Int
    let otherCatProposals: Int
    let aOrBChoicePhotos: Int
    let matchingAOrBProposals: Int
    let aOrBChoicesByCat: [String: Int]
    let matchingProposalsByCat: [String: Int]
    let withheldAOrBChoices: Int
    let withheldBothOrOtherPhotos: Int
    let independentAccuracyEvaluated = false
    let goalValidated = false

    init(session: CandidateReviewSession) {
        var matrix = Array(repeating: Array(repeating: 0, count: 6), count: 4)
        var restored = matrix
        for photo in session.run.photos {
            let row: Int
            if photo.batchSuggestion == .a { row = 0 }
            else if photo.batchSuggestion == .b { row = 1 }
            else if photo.image != nil, photo.issue == nil, photo.regionReview == nil,
                    photo.distanceAssessment?.isWithheld == true { row = 2 }
            else { row = 3 }
            let column: Int
            switch session.decisions[photo.id] {
            case .a: column = 0
            case .b: column = 1
            case .both: column = 2
            case .other: column = 3
            case .unsure: column = 4
            case nil: column = 5
            }
            matrix[row][column] += 1
            if session.restoredIDs.contains(photo.id), session.decisions[photo.id] != nil {
                restored[row][column] += 1
            }
        }
        counts = matrix
        restoredCounts = restored
        selected = session.run.photos.count
        restoredChoices = session.run.photos.filter { session.restoredIDs.contains($0.id) && session.decisions[$0.id] != nil }.count
        unreviewed = matrix.reduce(0) { $0 + $1[5] }
        unsure = matrix.reduce(0) { $0 + $1[4] }
        reviewedWithKnownChoice = selected - unreviewed - unsure
        proposed = matrix[0].reduce(0, +) + matrix[1].reduce(0, +)
        reviewedProposals = matrix[0].prefix(4).reduce(0, +) + matrix[1].prefix(4).reduce(0, +)
        matchingProposals = matrix[0][0] + matrix[1][1]
        differentCatProposals = matrix[0][1] + matrix[1][0]
        bothInSingleCatProposals = matrix[0][2] + matrix[1][2]
        otherCatProposals = matrix[0][3] + matrix[1][3]
        aOrBChoicesByCat = ["a": matrix.reduce(0) { $0 + $1[0] }, "b": matrix.reduce(0) { $0 + $1[1] }]
        matchingProposalsByCat = ["a": matrix[0][0], "b": matrix[1][1]]
        aOrBChoicePhotos = matrix.reduce(0) { $0 + $1[0] + $1[1] }
        matchingAOrBProposals = matchingProposals
        withheldAOrBChoices = matrix[2][0] + matrix[2][1]
        withheldBothOrOtherPhotos = matrix[2][2] + matrix[2][3]
    }
}
