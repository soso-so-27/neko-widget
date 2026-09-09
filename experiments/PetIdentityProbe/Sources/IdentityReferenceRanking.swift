import Foundation

// Ranking is not identity acceptance. These per-input values never leave the core.
enum IdentityRankingOutcome: Equatable {
    case a, b, equalScores, missingEmbedding, invalidEmbedding
}

struct IdentityRankingCounts: Encodable, Equatable, Sendable {
    let expectedFirst: Int
    let otherFirst: Int
    let equalScores: Int
    let missingEmbedding: Int
    let invalidEmbedding: Int
    var notRanked: Int { equalScores + missingEmbedding + invalidEmbedding }
    var selected: Int { expectedFirst + otherFirst + notRanked }

    init(_ outcomes: [(IdentityCatLabel, IdentityRankingOutcome)]) {
        expectedFirst = outcomes.filter { ($0.0 == .a && $0.1 == .a) || ($0.0 == .b && $0.1 == .b) }.count
        otherFirst = outcomes.filter { ($0.0 == .a && $0.1 == .b) || ($0.0 == .b && $0.1 == .a) }.count
        equalScores = outcomes.filter { $0.1 == .equalScores }.count
        missingEmbedding = outcomes.filter { $0.1 == .missingEmbedding }.count
        invalidEmbedding = outcomes.filter { $0.1 == .invalidEmbedding }.count
    }
}

struct IdentityCatRanking: Encodable, Equatable, Sendable {
    let label: IdentityCatLabel
    let counts: IdentityRankingCounts
}

struct IdentityRankingMethod: Encodable, Equatable, Sendable {
    let method: String
    let overall: IdentityRankingCounts
    let perCat: [IdentityCatRanking]

    init(method: String, outcomes: [(IdentityCatLabel, IdentityRankingOutcome)]) {
        self.method = method
        overall = .init(outcomes)
        perCat = IdentityCatLabel.allCases.map { label in
            .init(label: label, counts: .init(outcomes.filter { $0.0 == label }))
        }
    }
}

/// Two fixed retrieval rules on the SAME recovered input embeddings and five
/// references per cat. No distance threshold, no fitting, no identity acceptance.
struct IdentityReferenceRankingComparison: Encodable, Sendable {
    let protocolIdentifier = "pet-identity-reference-ranking-comparison-v1"
    let scope = "candidate-inputs-only;two-registered-cats-closed-set;selected-label-as-expected;diagnostic-reuse;not-identity-acceptance;singleton-count-reveals-one-input"
    let inputReuse = "same-five-references-per-cat-and-same-evaluation-embeddings;no-additional-fetch-detection-or-model-run"
    let thresholdPolicy = "ranking-only;no-distance-cutoff-or-ratio;original-acceptance-unchanged;no-tuning-to-evaluation"
    let aggregatedReferences: IdentityRankingMethod
    let nearestReference: IdentityRankingMethod
    let pairedOutcomeOrder = ["expectedFirst", "otherFirst", "notRanked"]
    let pairedOutcomes: [[Int]] // Rows aggregated, columns nearest; never per-photo rows.
    let identityAssignmentsMade = false
    let productValidated = false

    init(aggregated: [(IdentityCatLabel, IdentityRankingOutcome)], nearest: [(IdentityCatLabel, IdentityRankingOutcome)]) {
        aggregatedReferences = .init(method: "second-nearest-of-five-per-cat", outcomes: aggregated)
        nearestReference = .init(method: "nearest-of-five-per-cat", outcomes: nearest)
        var paired = Array(repeating: [0, 0, 0], count: 3)
        func index(_ item: (IdentityCatLabel, IdentityRankingOutcome)) -> Int {
            switch item.1 {
            case .a: return item.0 == .a ? 0 : 1
            case .b: return item.0 == .b ? 0 : 1
            default: return 2
            }
        }
        for (left, right) in zip(aggregated, nearest) { paired[index(left)][index(right)] += 1 }
        pairedOutcomes = paired
    }
}
