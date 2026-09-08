import XCTest
@testable import PetIdentityProbe

final class IdentityReferenceRankingTests: XCTestCase {
    private func vector(_ angle: Double) -> [Float] {
        [Float(cos(angle)), Float(sin(angle))] + Array(repeating: 0, count: 510)
    }
    private var a: [[Float]?] { [0, 0.8, 1, 1.2, 1.4].map { vector($0) } }
    private var b: [[Float]?] { [0.2, 0.3, 0.4, 0.5, 0.6].map { vector($0) } }
    private func compare(_ ea: [[Float]?], _ eb: [[Float]?] = []) throws -> IdentityReferenceRankingComparison {
        try IdentityEvaluationCore.compareReferenceRanking(registrationA: a, registrationB: b,
            evaluationA: ea, evaluationB: eb)
    }

    func testNearestAndAggregatedRulesCanDisagreeInEitherDirection() throws {
        let result = try compare([vector(0)], [vector(0)])
        XCTAssertEqual(result.nearestReference.overall.expectedFirst, 1)
        XCTAssertEqual(result.nearestReference.overall.otherFirst, 1)
        XCTAssertEqual(result.aggregatedReferences.overall.expectedFirst, 1)
        XCTAssertEqual(result.aggregatedReferences.overall.otherFirst, 1)
        XCTAssertEqual(result.pairedOutcomes, [[0, 1, 0], [1, 0, 0], [0, 0, 0]])
        XCTAssertEqual(result.nearestReference.perCat[0].counts.expectedFirst, 1)
        XCTAssertEqual(result.nearestReference.perCat[1].counts.otherFirst, 1)
        XCTAssertFalse(result.identityAssignmentsMade); XCTAssertFalse(result.productValidated)
    }

    func testMissingInvalidAndTiedInputsStayInDenominator() throws {
        let refs = Array<[Float]?>(repeating: vector(0), count: 5)
        let result = try IdentityEvaluationCore.compareReferenceRanking(registrationA: refs, registrationB: refs,
            evaluationA: [vector(0), nil, [], [Float.nan] + Array(repeating: 0, count: 511)], evaluationB: [])
        for method in [result.aggregatedReferences, result.nearestReference] {
            XCTAssertEqual(method.overall.selected, 4)
            XCTAssertEqual(method.overall.equalScores, 1); XCTAssertEqual(method.overall.missingEmbedding, 1)
            XCTAssertEqual(method.overall.invalidEmbedding, 2); XCTAssertEqual(method.overall.notRanked, 4)
            XCTAssertEqual(method.perCat[1].counts.selected, 0)
        }
        XCTAssertEqual(result.pairedOutcomes, [[0, 0, 0], [0, 0, 0], [0, 0, 4]])
    }

    func testRegistrationRuntimeAndSelectionContractFailsClosed() throws {
        func run(_ ra: [[Float]?] = [], _ ea: [[Float]?] = [nil], runtime: String = "1.24.2") throws {
            _ = try IdentityEvaluationCore.compareReferenceRanking(registrationA: ra, registrationB: b,
                evaluationA: ea, evaluationB: [], runtimeVersion: runtime)
        }
        XCTAssertThrowsError(try run())
        XCTAssertThrowsError(try run(Array(repeating: nil, count: 5)))
        XCTAssertThrowsError(try run(Array(repeating: [Float](repeating: 0, count: 512), count: 5)))
        XCTAssertThrowsError(try run(a, [], runtime: "1.24.2"))
        XCTAssertThrowsError(try run(a, Array(repeating: nil, count: 16)))
        XCTAssertThrowsError(try run(a, runtime: "other"))
        let maximum = try compare(Array(repeating: nil, count: 15), Array(repeating: nil, count: 15))
        XCTAssertEqual(maximum.nearestReference.overall.selected, 30)
    }

    func testLabelsAndOrderingDoNotFitTheRetrievalRule() throws {
        let result = try compare([vector(0), vector(0.4)], [vector(0.6)])
        let swapped = try IdentityEvaluationCore.compareReferenceRanking(registrationA: Array(b.reversed()), registrationB: Array(a.reversed()),
            evaluationA: [vector(0.6)], evaluationB: [vector(0.4), vector(0)])
        XCTAssertEqual(result.nearestReference.overall, swapped.nearestReference.overall)
        XCTAssertEqual(result.aggregatedReferences.overall, swapped.aggregatedReferences.overall)
        XCTAssertEqual(result.pairedOutcomes, swapped.pairedOutcomes)
    }

    func testIntegrationDoesNotChangeLegacyAcceptanceAndOmitsUnusableComparison() throws {
        var items: [IdentityRecoveryItem] = []
        for (slot, refs) in [(IdentityPhotoSlot.referenceA, a), (.referenceB, b)] {
            items += refs.map { .init(slot: slot, original: $0, candidate: $0, recoveryStatus: .originalReused) }
        }
        items.append(.init(slot: .evaluationA, original: vector(0), candidate: vector(0), recoveryStatus: .originalReused))
        let old = try IdentityEvaluationCore.evaluate(registrationA: a, registrationB: b,
            evaluationA: [vector(0)], evaluationB: [], purpose: .diagnostic)
        let report = try IdentityRecoveryComparisonCore.report(items)
        XCTAssertEqual(report.original.aggregate, old.aggregate); XCTAssertEqual(report.candidate.aggregate, old.aggregate)
        XCTAssertEqual(report.referenceRanking?.nearestReference.overall.expectedFirst, 1)
        items[0] = .init(slot: .referenceA, original: nil, candidate: nil, recoveryStatus: .noCandidate)
        let missing = try IdentityRecoveryComparisonCore.report(items)
        XCTAssertNil(missing.referenceRanking)
        XCTAssertFalse(try XCTUnwrap(missing.json).contains("\"referenceRanking\""))
    }

    func testOnlyCountsAndFixedMetadataLeaveTheCoreEvenForSingleton() throws {
        let result = try compare([vector(0)])
        let data = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["protocolIdentifier", "scope", "inputReuse", "thresholdPolicy", "aggregatedReferences",
            "nearestReference", "pairedOutcomeOrder", "pairedOutcomes", "identityAssignmentsMade", "productValidated"])
        for key in ["aggregatedReferences", "nearestReference"] {
            let method = try XCTUnwrap(object[key] as? [String: Any])
            XCTAssertEqual(Set(method.keys), ["method", "overall", "perCat"])
            let counts = try XCTUnwrap(method["overall"] as? [String: Any])
            XCTAssertEqual(Set(counts.keys), ["expectedFirst", "otherFirst", "equalScores", "missingEmbedding", "invalidEmbedding"])
        }
        let json = String(decoding: data, as: UTF8.self)
        for key in ["distances", "embeddings", "assetIdentifier", "thumbnail", "predictionsA", "predictionsB"] {
            XCTAssertFalse(json.contains("\"\(key)\""))
        }
        XCTAssertTrue(result.scope.contains("singleton-count-reveals-one-input"))
    }
}
