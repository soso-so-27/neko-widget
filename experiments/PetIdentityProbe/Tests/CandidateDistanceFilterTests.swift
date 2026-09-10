import SwiftUI
import XCTest
@testable import PetIdentityProbe

final class CandidateDistanceFilterTests: XCTestCase {
    private func vector(_ angle: Double) -> [Float] {
        [Float(cos(angle)), Float(sin(angle))] + Array(repeating: 0, count: 510)
    }
    private var a: [[Float]?] { (-2...2).map { vector(Double($0) * 0.01) } }
    private var b: [[Float]?] { (-2...2).map { vector(1.4 + Double($0) * 0.01) } }
    private func image() throws -> CGImage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: IdentityDetectorControlID.orange.rawValue, withExtension: "png"))
        return try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
    }

    func testDistantWinnerIsWithheldWithoutRerankingOrDroppingInputs() throws {
        let inputs: [[Float]?] = [vector(0), vector(1.4), vector(0.5), nil, []]
        let before = try IdentityEvaluationCore.reviewSuggestions(registrationA: a, registrationB: b, inputs: inputs)
        let after = try IdentityEvaluationCore.filteredReviewSuggestions(registrationA: a, registrationB: b, inputs: inputs)
        XCTAssertEqual(after.map(\.ranking), before)
        XCTAssertEqual(after.map(\.suggestedCat), [.a, .b, nil, nil, nil])
        XCTAssertEqual(after.map(\.status), [.withinReferenceRange, .withinReferenceRange, .outsideReferenceRange, .notRanked, .notRanked])
        XCTAssertEqual(after.count, inputs.count)
        let reordered = try IdentityEvaluationCore.filteredReviewSuggestions(registrationA: a, registrationB: b, inputs: Array(inputs.reversed()))
        XCTAssertEqual(reordered.map(\.status), Array(after.map(\.status).reversed()))
        let swapped = try IdentityEvaluationCore.filteredReviewSuggestions(registrationA: b, registrationB: a, inputs: inputs)
        XCTAssertEqual(swapped.map(\.suggestedCat), [.b, .a, nil, nil, nil])
    }

    func testFixedBoundaryZeroRadiusAmbiguityAndNoRunnerUpFallback() {
        func assess(_ lhs: Double, _ rhs: Double, _ ra: Double, _ rb: Double) -> CandidateDistanceAssessment {
            IdentityEvaluationCore.assessCandidateDistance(scoreA: lhs, scoreB: rhs, radiusA: ra, radiusB: rb)
        }
        let boundary = 0.1 * 1.25
        XCTAssertEqual(assess(boundary, 0.8, 0.1, 0.1).suggestedCat, .a)
        XCTAssertEqual(assess(boundary.nextUp, 0.8, 0.1, 0.1).status, .outsideReferenceRange)
        XCTAssertEqual(assess(0.8, boundary, 0.1, 0.1).suggestedCat, .b)
        XCTAssertEqual(assess(0, 0.8, 0, 0.1).status, .referenceRangeUnavailable)
        XCTAssertEqual(assess(0.4, 0.401, 0.4, 0.4).suggestedCat, .a) // No 0.70 ratio gate.
        XCTAssertEqual(assess(0.4, 0.4, 0.4, 0.4).ranking, .equalScores)
        let noFallback = assess(0.2, 0.3, 0.01, 1)
        XCTAssertEqual(noFallback.ranking, .a); XCTAssertNil(noFallback.suggestedCat)
        for bad in [Double.nan, .infinity, -0.1, 2.1] {
            XCTAssertEqual(assess(bad, 1, 0.1, 0.1).status, .notRanked)
            XCTAssertEqual(assess(0.1, 1, bad, 0.1).status, .notRanked)
        }
    }

    func testLegacyEvaluatorIsUnchangedAndCalibrationNeverUsesReviewInputs() throws {
        let inputs: [[Float]?] = [vector(0), vector(0.5)]
        let old = try IdentityEvaluationCore.evaluate(registrationA: a, registrationB: b, evaluationA: inputs,
                                                       evaluationB: [], purpose: .diagnostic)
        _ = try IdentityEvaluationCore.filteredReviewSuggestions(registrationA: a, registrationB: b, inputs: inputs)
        let again = try IdentityEvaluationCore.evaluate(registrationA: a, registrationB: b, evaluationA: inputs,
                                                         evaluationB: [], purpose: .diagnostic)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(old.aggregate), try encoder.encode(again.aggregate))
        let single = try IdentityEvaluationCore.filteredReviewSuggestions(registrationA: a, registrationB: b, inputs: [vector(0.5)])
        let many = try IdentityEvaluationCore.filteredReviewSuggestions(registrationA: a, registrationB: b,
            inputs: [vector(0.5)] + Array(repeating: vector(0.5), count: 23))
        XCTAssertEqual(single[0].status, many[0].status)
    }

    func testMalformedAndDegenerateReferencesFailClosed() throws {
        XCTAssertThrowsError(try IdentityEvaluationCore.filteredReviewSuggestions(registrationA: [], registrationB: b, inputs: [vector(0)]))
        XCTAssertThrowsError(try IdentityEvaluationCore.filteredReviewSuggestions(registrationA: Array(repeating: nil, count: 5), registrationB: b, inputs: [vector(0)]))
        XCTAssertThrowsError(try IdentityEvaluationCore.filteredReviewSuggestions(registrationA: a, registrationB: b, inputs: []))
        XCTAssertThrowsError(try IdentityEvaluationCore.filteredReviewSuggestions(registrationA: a, registrationB: b, inputs: Array(repeating: nil, count: 25)))
        let zeroRadius = try IdentityEvaluationCore.filteredReviewSuggestions(registrationA: Array(repeating: vector(0), count: 5),
            registrationB: b, inputs: [vector(0)])
        XCTAssertEqual(zeroRadius[0].status, .referenceRangeUnavailable)
        let tied = try IdentityEvaluationCore.filteredReviewSuggestions(registrationA: a, registrationB: a, inputs: [vector(0)])
        XCTAssertEqual(tied[0].ranking, .equalScores); XCTAssertNil(tied[0].suggestedCat)
    }

    func testRegionsUseTheSameFilterWithoutExtraInferenceOrPhotoPromotion() throws {
        let raster = try image()
        let boxes = [CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)]
        let diagnostic = IdentityAnimalDetectionDiagnostic(observationLabels: Array(repeating: [.init(label: "Cat", confidence: 0.8)], count: 2),
            revision: 2, systemCatLabel: "Cat", resultsAvailable: true)
        var calls = 0
        let result = try XCTUnwrap(CandidateRegionProbe.review(image: raster, originalIssue: .multipleCats,
            recoveryStatus: .originalIneligible, diagnostic: diagnostic, boxes: boxes, registrationA: a, registrationB: b) { _ in
                calls += 1; return self.vector(calls == 1 ? 0 : 0.5)
            })
        XCTAssertEqual(calls, 2); XCTAssertEqual(result.regions.count, 2)
        XCTAssertEqual(result.regions.map(\.suggestion), [.a, nil])
        XCTAssertTrue(result.regions[1].title.contains("候補を出していません"))
        let photo = CandidateReviewPhoto(id: 0, image: raster, suggestion: .a, issue: nil, regionReview: result)
        XCTAssertNil(photo.batchSuggestion)
        let counts = CandidateReviewSession(run: .init(photos: [photo], referenceA: raster, referenceB: raster)).report.distanceFiltering
        XCTAssertEqual(counts.rankedRegionsBeforeFilter, 2); XCTAssertEqual(counts.suggestedRegionsAfterFilter, 1)
        XCTAssertEqual(counts.regionStatusCounts.values.reduce(0, +), 2)
    }

    func testRestoredHumanChoicesRemainIntactAndComparisonIsAggregateOnly() throws {
        let raster = try image()
        let assessments: [CandidateDistanceAssessment] = [
            .init(ranking: .a, status: .withinReferenceRange), .init(ranking: .a, status: .outsideReferenceRange),
            .init(ranking: .a, status: .outsideReferenceRange), .init(ranking: .b, status: .withinReferenceRange),
            .init(ranking: .b, status: .outsideReferenceRange), .init(ranking: .b, status: .referenceRangeUnavailable)]
        let photos = assessments.enumerated().map { id, result in
            CandidateReviewPhoto(id: id, image: raster, suggestion: result.suggestedCat, issue: nil, distanceAssessment: result)
        }
        let choices: [String: CandidateReviewChoice] = ["p0": .a, "p1": .other, "p2": .b, "p3": .both, "p4": .unsure]
        let progress = CandidateSavedProgress(referenceFingerprint: String(repeating: "a", count: 64), decisions: choices,
                                              previousDecisions: [:], excluded: [])
        var session = CandidateReviewSession(run: .init(photos: photos, referenceA: raster, referenceB: raster),
            progress: progress, identifiers: (0..<6).map { "p\($0)" })
        let before = session.decisions
        session.confirmGroup(.a); session.confirmGroup(.b)
        XCTAssertEqual(session.decisions, before); XCTAssertEqual(session.remaining, 1)
        let counts = session.report.distanceFiltering
        XCTAssertEqual(counts.photoStatusCounts.values.reduce(0, +), 6)
        XCTAssertEqual(counts.rankedPhotosBeforeFilter, 6); XCTAssertEqual(counts.suggestedPhotosAfterFilter, 2)
        XCTAssertEqual(counts.withheldPhotos, 4)
        XCTAssertEqual(counts.priorConfirmationCounts, [[1, 0, 1, 0, 0, 0], [0, 1, 0, 1, 1, 1]])
        session.choose(.b, for: 1) // A new correction is not promoted into the prior comparison.
        XCTAssertEqual(session.report.distanceFiltering.priorConfirmationCounts[1], [0, 1, 0, 0, 1, 2])
        session.undo(); XCTAssertEqual(session.decisions, before)
        let json = try XCTUnwrap(session.report.json)
        for forbidden in ["p0", "ranking", "decisions", "distanceAssessment", "scoreA", "radiusA", "box", "image", "vector"] {
            XCTAssertFalse(json.contains("\"\(forbidden)\""))
        }
        XCTAssertFalse(session.report.accuracyEvaluated); XCTAssertFalse(session.report.productValidated)
        let malformed = CandidateReviewPhoto(id: 9, image: raster, suggestion: .a, issue: nil,
            distanceAssessment: .init(ranking: .a, status: .outsideReferenceRange))
        XCTAssertNil(malformed.batchSuggestion)
    }
}
