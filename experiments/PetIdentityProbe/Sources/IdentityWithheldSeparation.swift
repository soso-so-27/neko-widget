import Foundation

// Ephemeral, not Codable. Never leave evaluation or include these in its result.
struct IdentityClassDistances {
    let a: Double
    let b: Double
}

struct IdentityDistanceRatioSummary: Encodable, Equatable, Sendable {
    let count: Int
    let minimum: Double
    let median: Double
    let maximum: Double

    init?(_ values: [Double]) {
        let sorted = values.sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }
        count = sorted.count; minimum = first; maximum = last
        let middle = sorted.count / 2
        median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// Counts and ratio summaries for withheld inputs only. Not predictions or accuracy.
struct IdentityCatWithheldSeparation: Encodable, Equatable, Sendable {
    let actualLabel: IdentityCatLabel
    let unknownCount: Int
    let closerToExpectedCount: Int
    let closerToOtherCount: Int
    let equalScoreCount: Int
    let unavailableScoreCount: Int
    let closerToExpectedRatio: IdentityDistanceRatioSummary?
    let closerToOtherRatio: IdentityDistanceRatioSummary?

    init(actual: IdentityCatLabel, withheld: [IdentityClassDistances?]) {
        actualLabel = actual; unknownCount = withheld.count
        var expected: [Double] = [], other: [Double] = []
        var ties = 0, unavailable = 0
        for value in withheld {
            guard let value, value.a.isFinite, value.b.isFinite,
                  (0...2).contains(value.a), (0...2).contains(value.b) else {
                unavailable += 1; continue
            }
            // A tie (including 0/0) is distinct from unavailable scores; never divide it.
            guard value.a != value.b else { ties += 1; continue }
            let ratio = min(value.a, value.b) / max(value.a, value.b)
            let expectedIsCloser = actual == .a ? value.a < value.b : value.b < value.a
            if expectedIsCloser { expected.append(ratio) } else { other.append(ratio) }
        }
        closerToExpectedCount = expected.count; closerToOtherCount = other.count
        equalScoreCount = ties; unavailableScoreCount = unavailable
        closerToExpectedRatio = IdentityDistanceRatioSummary(expected)
        closerToOtherRatio = IdentityDistanceRatioSummary(other)
    }
}

struct IdentityWithheldSeparation: Encodable, Equatable, Sendable {
    let scope = "withheld-only;selected-label-as-expected;aggregate-ratios-not-probability;singleton-summary-reveals-one-input;no-threshold-tuning"
    let ratioDefinition = "min(class-distance-A,class-distance-B)/max(class-distance-A,class-distance-B);ties-and-unavailable-excluded"
    let perCat: [IdentityCatWithheldSeparation]
}
