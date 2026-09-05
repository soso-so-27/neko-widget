import Foundation
import XCTest
@testable import PetIdentityProbe

final class IdentityEvaluationCoreTests: XCTestCase {
    private func vector(_ angle: Double) -> [Float] {
        var result = [Float](repeating: 0, count: 512)
        result[0] = Float(cos(angle))
        result[1] = Float(sin(angle))
        return result
    }

    private func references(_ center: Double) -> [[Float]?] {
        [-0.12, -0.06, 0, 0.06, 0.12].map { vector(center + $0) }
    }

    private func evaluate(_ a: [[Float]?], _ b: [[Float]?]) throws -> IdentityEvaluationResult {
        try IdentityEvaluationCore.evaluate(
            registrationA: references(0), registrationB: references(1.5),
            evaluationA: a, evaluationB: b
        )
    }

    func testCorrectWrongUnknownAndConfusionOrientation() throws {
        let a: [[Float]?] = [vector(0), vector(1.5), vector(3)] + Array(repeating: nil, count: 12)
        let b: [[Float]?] = [vector(0), vector(1.5), vector(1.5)] + Array(repeating: nil, count: 12)
        let result = try evaluate(a, b)
        XCTAssertEqual(Array(result.predictionsA.prefix(3)), [.a, .b, .unknown])
        XCTAssertEqual(Array(result.predictionsB.prefix(3)), [.a, .b, .b])
        XCTAssertEqual(result.aggregate.perCat.map(\.label), [.a, .b])
        XCTAssertEqual(result.aggregate.perCat[0].counts, .init(correct: 1, wrong: 1, unknown: 13))
        XCTAssertEqual(result.aggregate.perCat[1].counts, .init(correct: 2, wrong: 1, unknown: 12))
        XCTAssertEqual(result.aggregate.overall, .init(correct: 3, wrong: 2, unknown: 25))
        XCTAssertEqual(result.aggregate.confusionMatrix.actualLabels, ["A", "B"])
        XCTAssertEqual(result.aggregate.confusionMatrix.predictedLabels, ["A", "B", "unknown"])
        XCTAssertEqual(result.aggregate.confusionMatrix.counts, [[1, 1, 13], [1, 2, 12]])
    }

    func testAllCorrectIsOnlyAnExplorationCandidate() throws {
        let result = try evaluate(Array(repeating: vector(0), count: 15),
                                  Array(repeating: vector(1.5), count: 15))
        XCTAssertEqual(result.aggregate.overall, .init(correct: 30, wrong: 0, unknown: 0))
        XCTAssertTrue(result.aggregate.gate.precisionPassed)
        XCTAssertTrue(result.aggregate.gate.coveragePassed)
        XCTAssertTrue(result.aggregate.gate.explorationCandidate)
        XCTAssertFalse(result.aggregate.gate.productValidated)
    }

    func testMissingEvaluationKeepsThirtyInDenominatorAndSeventyPercentBoundary() throws {
        let a: [[Float]?] = Array(repeating: vector(0), count: 11) + Array(repeating: nil, count: 4)
        let b: [[Float]?] = Array(repeating: vector(1.5), count: 10) + Array(repeating: nil, count: 5)
        let result = try evaluate(a, b)
        XCTAssertEqual(result.aggregate.overall.total, 30)
        XCTAssertEqual(result.aggregate.overall.unknown, 9)
        XCTAssertTrue(result.aggregate.gate.coveragePassed)
        XCTAssertTrue(result.aggregate.gate.explorationCandidate)
        var fewer = a
        fewer[0] = nil
        let below = try evaluate(fewer, b)
        XCTAssertEqual(below.aggregate.overall.total, 30)
        XCTAssertFalse(below.aggregate.gate.coveragePassed)
        XCTAssertFalse(below.aggregate.gate.explorationCandidate)
    }

    func testIntegerPrecisionDoesNotRound947PercentUpTo95() {
        let precision = Double(18) / 19 * 100
        XCTAssertEqual(precision.rounded(), 95)
        let below = IdentityEvaluationGate(counts: .init(correct: 18, wrong: 1, unknown: 11))
        XCTAssertFalse(below.precisionPassed)
        XCTAssertFalse(below.explorationCandidate)
        let boundary = IdentityEvaluationGate(counts: .init(correct: 19, wrong: 1, unknown: 10))
        XCTAssertTrue(boundary.precisionPassed)
        let noAssignments = IdentityEvaluationGate(counts: .init(correct: 0, wrong: 0, unknown: 30))
        XCTAssertFalse(noAssignments.precisionPassed)
        XCTAssertFalse(noAssignments.coveragePassed)
    }

    func testZeroRadiusAndTiedClassesAreUnknown() throws {
        let evaluations = Array<[Float]?>(repeating: vector(0), count: 15)
        let zero = try IdentityEvaluationCore.evaluate(
            registrationA: Array(repeating: vector(0), count: 5),
            registrationB: Array(repeating: vector(1.5), count: 5),
            evaluationA: evaluations, evaluationB: Array(repeating: vector(1.5), count: 15)
        )
        XCTAssertEqual(zero.aggregate.overall.unknown, 30)
        let tie = try IdentityEvaluationCore.evaluate(
            registrationA: references(0), registrationB: references(0),
            evaluationA: evaluations, evaluationB: evaluations
        )
        XCTAssertEqual(tie.aggregate.overall.unknown, 30)
        XCTAssertTrue(tie.predictionsA.allSatisfy { $0 == .unknown })
    }

    func testRatioRejectsAnOtherwiseNearbyAmbiguousInput() throws {
        let result = try IdentityEvaluationCore.evaluate(
            registrationA: references(0), registrationB: references(0.1),
            evaluationA: Array(repeating: vector(0.048), count: 15),
            evaluationB: Array(repeating: nil, count: 15)
        )
        XCTAssertEqual(result.aggregate.overall.unknown, 30)
    }

    func testNearestThreeMedianRejectsSingleCloseReference() throws {
        let wideA: [[Float]?] = [-0.4, -0.1, 0, 0.1, 0.4].map(vector)
        let evaluations: [[Float]?] = [vector(0.2), vector(0.5)] + Array(repeating: nil, count: 13)
        let result = try IdentityEvaluationCore.evaluate(
            registrationA: wideA, registrationB: references(1.5),
            evaluationA: evaluations, evaluationB: Array(repeating: nil, count: 15)
        )
        XCTAssertEqual(Array(result.predictionsA.prefix(2)), [.a, .unknown])
    }

    func testEvaluationCompositionCannotChangeRegistrationCalibration() throws {
        let baseline = try evaluate(Array(repeating: vector(0), count: 15),
                                    Array(repeating: vector(1.5), count: 15))
        let different: [[Float]?] = [vector(0)] + Array(repeating: vector(3), count: 14)
        let changed = try evaluate(different, Array(repeating: nil, count: 15))
        XCTAssertEqual(changed.predictionsA[0], baseline.predictionsA[0])
        XCTAssertEqual(changed.aggregate.overall.correct, 1)
        XCTAssertEqual(changed.aggregate.overall.unknown, 29)
    }

    func testInvalidEvaluationVectorsAreUnknownAndInvalidRegistrationThrows() throws {
        var notFinite = vector(0)
        notFinite[2] = .nan
        var infinite = vector(0)
        infinite[2] = .infinity
        var notNormalized = vector(0)
        notNormalized[0] = 2
        let invalid = [Array(repeating: Float(0), count: 512),
                       Array(repeating: Float(0), count: 511), notFinite, infinite, notNormalized]
        let evaluations: [[Float]?] = invalid.map { Optional($0) } + Array(repeating: nil, count: 10)
        let result = try evaluate(evaluations, Array(repeating: vector(1.5), count: 15))
        XCTAssertEqual(result.aggregate.overall, .init(correct: 15, wrong: 0, unknown: 15))
        XCTAssertTrue(result.predictionsA.allSatisfy { $0 == .unknown })
        for input in invalid {
            var registration = references(0)
            registration[0] = input
            XCTAssertThrowsError(try IdentityEvaluationCore.evaluate(
                registrationA: registration, registrationB: references(1.5),
                evaluationA: Array(repeating: nil, count: 15), evaluationB: Array(repeating: nil, count: 15)
            )) { XCTAssertEqual($0 as? IdentityEvaluationError, .invalidRegistrationVector) }
        }
    }

    func testMissingRegistrationWrongCountsAndRuntimeFailClosed() {
        let missing = Array<[Float]?>(repeating: nil, count: 15)
        var registration = references(0)
        registration[0] = nil
        XCTAssertThrowsError(try IdentityEvaluationCore.evaluate(
            registrationA: registration, registrationB: references(1.5),
            evaluationA: missing, evaluationB: missing
        )) { XCTAssertEqual($0 as? IdentityEvaluationError, .missingRegistration) }
        XCTAssertThrowsError(try IdentityEvaluationCore.evaluate(
            registrationA: Array(references(0).prefix(4)), registrationB: references(1.5),
            evaluationA: missing, evaluationB: missing
        )) { XCTAssertEqual($0 as? IdentityEvaluationError, .invalidRegistrationCount) }
        XCTAssertThrowsError(try IdentityEvaluationCore.evaluate(
            registrationA: references(0), registrationB: references(1.5),
            evaluationA: Array(missing.prefix(14)), evaluationB: missing
        )) { XCTAssertEqual($0 as? IdentityEvaluationError, .invalidEvaluationCount) }
        XCTAssertThrowsError(try IdentityEvaluationCore.evaluate(
            registrationA: references(0), registrationB: references(1.5),
            evaluationA: missing, evaluationB: missing, runtimeVersion: "1.22.1"
        )) { XCTAssertEqual($0 as? IdentityEvaluationError, .unsupportedRuntime) }
    }

    func testAggregateJSONContainsOnlyFixedMetadataAndCounts() throws {
        let result = try evaluate(Array(repeating: vector(0), count: 15),
                                  Array(repeating: nil, count: 15))
        let data = try JSONEncoder().encode(result.aggregate)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "protocolIdentifier", "modelSHA256", "runtimeVersion", "embeddingDimensions",
            "registrationCountPerCat", "evaluationCountPerCat", "distanceMetric", "normalization",
            "classScore", "radiusDefinition", "missingEvaluationPolicy", "gateScope", "thresholds",
            "perCat", "overall", "confusionMatrix", "gate"
        ])
        XCTAssertEqual(object["protocolIdentifier"] as? String, "pet-identity-onnx-heldout-v1")
        XCTAssertEqual(object["modelSHA256"] as? String, IdentityEvaluationCore.modelSHA256)
        XCTAssertEqual(object["runtimeVersion"] as? String, "1.24.2")
        let rows = try XCTUnwrap(object["perCat"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["label"] as? String }, ["A", "B"])
        XCTAssertTrue(rows.allSatisfy { Set($0.keys) == ["label", "counts"] })
        let forbiddenKeys: Set<String> = ["predictionsA", "predictionsB", "predictions", "vectors",
                                          "embeddings", "distances", "radiusA", "radiusB", "name",
                                          "photoID", "assetIdentifier", "date", "samples"]
        func check(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                XCTAssertTrue(forbiddenKeys.isDisjoint(with: dictionary.keys))
                dictionary.values.forEach(check)
            } else if let array = value as? [Any] {
                array.forEach(check)
            }
        }
        check(object)
        XCTAssertEqual(try JSONDecoder().decode(IdentityEvaluationAggregate.self, from: data), result.aggregate)
    }
}
