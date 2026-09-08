import XCTest
@testable import PetIdentityProbe

final class IdentityWithheldSeparationTests: XCTestCase {
    private func vector(_ angle: Double) -> [Float] {
        var values = [Float](repeating: 0, count: 512)
        values[0] = Float(cos(angle)); values[1] = Float(sin(angle))
        return values
    }
    private func references(_ center: Double) -> [[Float]?] {
        [-0.12, -0.06, 0, 0.06, 0.12].map { vector(center + $0) }
    }

    func testDirectionsTiesUnavailableAndRatioStatisticsPartitionAllWithheld() throws {
        let values: [IdentityClassDistances?] = [
            .init(a: 0.2, b: 0.4), .init(a: 0.3, b: 0.4), .init(a: 0.6, b: 0.3),
            .init(a: 0.5, b: 0.5), .init(a: 0, b: 0), nil, .init(a: .nan, b: 0.4)
        ]
        let a = IdentityCatWithheldSeparation(actual: .a, withheld: values)
        XCTAssertEqual(a.unknownCount, 7)
        XCTAssertEqual(a.closerToExpectedCount, 2); XCTAssertEqual(a.closerToOtherCount, 1)
        XCTAssertEqual(a.equalScoreCount, 2); XCTAssertEqual(a.unavailableScoreCount, 2)
        XCTAssertEqual(a.unknownCount, a.closerToExpectedCount + a.closerToOtherCount + a.equalScoreCount + a.unavailableScoreCount)
        let ratio = try XCTUnwrap(a.closerToExpectedRatio)
        XCTAssertEqual(ratio.count, 2); XCTAssertEqual(ratio.minimum, 0.5)
        XCTAssertEqual(ratio.median, 0.625, accuracy: 1e-12); XCTAssertEqual(ratio.maximum, 0.75, accuracy: 1e-12)
        XCTAssertEqual(a.closerToOtherRatio?.median, 0.5)
        let b = IdentityCatWithheldSeparation(actual: .b, withheld: values)
        XCTAssertEqual(b.closerToExpectedCount, a.closerToOtherCount)
        XCTAssertEqual(b.closerToOtherCount, a.closerToExpectedCount)
        XCTAssertEqual(b.closerToExpectedRatio, a.closerToOtherRatio)
        let odd = try XCTUnwrap(IdentityDistanceRatioSummary([0.9, 0.2, 0.5]))
        XCTAssertEqual(odd.median, 0.5)
    }

    func testEmptyInvalidAndZeroDistanceDoNotInventRatios() throws {
        let empty = IdentityCatWithheldSeparation(actual: .a, withheld: [])
        XCTAssertEqual(empty.unknownCount, 0); XCTAssertNil(empty.closerToExpectedRatio)
        XCTAssertNil(empty.closerToOtherRatio)
        let invalid = IdentityCatWithheldSeparation(actual: .a, withheld: [
            .init(a: -.infinity, b: 0.2), .init(a: -0.1, b: 0.2), .init(a: 2.1, b: 0.2)
        ])
        XCTAssertEqual(invalid.unavailableScoreCount, 3)
        XCTAssertNil(invalid.closerToExpectedRatio); XCTAssertNil(invalid.closerToOtherRatio)
        let zero = IdentityCatWithheldSeparation(actual: .a, withheld: [.init(a: 0, b: 1)])
        XCTAssertEqual(zero.closerToExpectedCount, 1); XCTAssertEqual(zero.closerToExpectedRatio?.median, 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(empty)) as? [String: Any])
        XCTAssertNil(object["closerToExpectedRatio"]); XCTAssertNil(object["closerToOtherRatio"])
    }

    func testAmbiguousExpectedAndOtherDirectionsDoNotChangePredictionsOrCalibration() throws {
        let a: [[Float]?] = [vector(0.048), vector(0.052)]
        let b: [[Float]?] = [vector(0.052), vector(0.048)]
        let result = try IdentityEvaluationCore.evaluate(registrationA: references(0), registrationB: references(0.1),
            evaluationA: a, evaluationB: b, purpose: .diagnostic)
        XCTAssertEqual(result.predictionsA, [.unknown, .unknown]); XCTAssertEqual(result.predictionsB, [.unknown, .unknown])
        XCTAssertEqual(result.reasonsA, [.ambiguous, .ambiguous]); XCTAssertEqual(result.reasonsB, [.ambiguous, .ambiguous])
        for cat in try XCTUnwrap(result.withheldSeparation).perCat {
            XCTAssertEqual(cat.unknownCount, 2)
            XCTAssertEqual(cat.closerToExpectedCount, 1); XCTAssertEqual(cat.closerToOtherCount, 1)
            XCTAssertEqual(cat.equalScoreCount, 0); XCTAssertEqual(cat.unavailableScoreCount, 0)
            XCTAssertGreaterThan(try XCTUnwrap(cat.closerToExpectedRatio).median, 0.70)
            XCTAssertLessThan(try XCTUnwrap(cat.closerToOtherRatio).median, 1)
        }
        let heldout = try IdentityEvaluationCore.evaluate(registrationA: references(0), registrationB: references(0.1),
            evaluationA: a + Array(repeating: nil, count: 13), evaluationB: b + Array(repeating: nil, count: 13))
        XCTAssertNil(heldout.withheldSeparation)
        XCTAssertEqual(Array(heldout.predictionsA.prefix(2)), result.predictionsA)
        XCTAssertEqual(Array(heldout.reasonsB.prefix(2)), result.reasonsB)
        XCTAssertEqual(heldout.aggregate.registrationRadii, result.aggregate.registrationRadii)
        XCTAssertEqual(heldout.aggregate.thresholds, result.aggregate.thresholds)
        let legacy = String(decoding: try JSONEncoder().encode(result.aggregate), as: UTF8.self)
        XCTAssertFalse(legacy.contains("withheldSeparation")); XCTAssertFalse(legacy.contains("closerToExpectedRatio"))
    }

    func testOnlyWithheldInputsCountIncludingTieAndDegenerateCalibration() throws {
        let result = try IdentityEvaluationCore.evaluate(registrationA: references(0), registrationB: references(1.5),
            evaluationA: [vector(0), vector(1.5), nil, Array(repeating: 0, count: 512)], evaluationB: [], purpose: .diagnostic)
        XCTAssertEqual(result.aggregate.overall, .init(correct: 1, wrong: 1, unknown: 2))
        let a = try XCTUnwrap(result.withheldSeparation?.perCat.first)
        XCTAssertEqual(a.unknownCount, 2); XCTAssertEqual(a.unavailableScoreCount, 2)
        XCTAssertEqual(a.closerToExpectedCount, 0); XCTAssertEqual(a.closerToOtherCount, 0)
        XCTAssertEqual(result.withheldSeparation?.perCat.last?.unknownCount, 0)
        let tie = try IdentityEvaluationCore.evaluate(registrationA: references(0), registrationB: references(0),
            evaluationA: [vector(0)], evaluationB: [], purpose: .diagnostic)
        XCTAssertEqual(tie.reasonsA, [.equalScores]); XCTAssertEqual(tie.withheldSeparation?.perCat.first?.equalScoreCount, 1)
        let degenerate = try IdentityEvaluationCore.evaluate(registrationA: Array(repeating: vector(0), count: 5),
            registrationB: Array(repeating: vector(1.5), count: 5), evaluationA: [vector(0)], evaluationB: [], purpose: .diagnostic)
        XCTAssertEqual(degenerate.reasonsA, [.degenerateCalibration])
        XCTAssertEqual(degenerate.withheldSeparation?.perCat.first?.closerToExpectedCount, 1)
        XCTAssertEqual(degenerate.withheldSeparation?.perCat.first?.closerToExpectedRatio?.median, 0)
    }

    func testComparisonExportIsAggregateOnlyAndAbsentForUnevaluatedArm() throws {
        var items: [IdentityRecoveryItem] = []
        for (slot, center) in [(IdentityPhotoSlot.referenceA, 0.0), (.referenceB, 0.1)] {
            items += references(center).map { .init(slot: slot, original: $0, candidate: $0, recoveryStatus: .originalReused) }
        }
        items[0] = .init(slot: .referenceA, original: nil, candidate: vector(-0.12), recoveryStatus: .recovered)
        items += [.init(slot: .evaluationA, original: vector(0.048), candidate: vector(0.048), recoveryStatus: .originalReused)]
        let report = try IdentityRecoveryComparisonCore.report(items)
        XCTAssertNil(report.original.withheldSeparation); XCTAssertEqual(report.original.status, .unusableReferences)
        XCTAssertEqual(report.candidate.aggregate?.overall, .init(correct: 0, wrong: 0, unknown: 1))
        XCTAssertEqual(report.candidate.withheldSeparation?.perCat.first?.closerToExpectedCount, 1)
        let json = try XCTUnwrap(report.json)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let original = try XCTUnwrap(root["original"] as? [String: Any])
        XCTAssertEqual(Set(original.keys), ["status"])
        let candidate = try XCTUnwrap(root["candidate"] as? [String: Any])
        let separation = try XCTUnwrap(candidate["withheldSeparation"] as? [String: Any])
        XCTAssertEqual(Set(separation.keys), ["scope", "ratioDefinition", "perCat"])
        let cats = try XCTUnwrap(separation["perCat"] as? [[String: Any]])
        XCTAssertEqual(Set(cats[0].keys), ["actualLabel", "unknownCount", "closerToExpectedCount", "closerToOtherCount",
            "equalScoreCount", "unavailableScoreCount", "closerToExpectedRatio"])
        let ratio = try XCTUnwrap(cats[0]["closerToExpectedRatio"] as? [String: Any])
        XCTAssertEqual(Set(ratio.keys), ["count", "minimum", "median", "maximum"])
        XCTAssertTrue((separation["scope"] as? String)?.contains("singleton-summary") == true)
        for forbidden in ["distances", "assetIdentifier", "thumbnail", "predictionsA", "predictionsB"] {
            XCTAssertFalse(json.contains("\"\(forbidden)\""))
        }
        XCTAssertFalse(report.productValidated); XCTAssertFalse(report.individualPredictionsIncluded)
    }
}
