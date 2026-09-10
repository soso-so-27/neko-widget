import UIKit
import XCTest
@testable import PetIdentityProbe

final class CandidateObjectIntegrationTests: XCTestCase {
    private func raster() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
            bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    func testVisibleRegionsAreNotClippedIntoIdentityOrCalledKnownCats() throws {
        let a = CGRect(x: -4, y: 4, width: 44, height: 60)
        let b = CGRect(x: 70, y: 4, width: 48, height: 60)
        let two = CandidateObjectProbe.assess([a, b], width: 128, height: 128)
        XCTAssertEqual(two.status, .multipleRegions); XCTAssertTrue(two.withholdsCandidate)
        XCTAssertEqual(two.usableRegions, 2); XCTAssertEqual(a.minX, -4)
        XCTAssertEqual(CandidateObjectProbe.assess([], width: 128, height: 128).status, .noCatRegion)
        XCTAssertEqual(CandidateObjectProbe.assess([a], width: 128, height: 128).status, .oneRegion)
        for bad in [CGRect(x: 120, y: 5, width: 40, height: 40), CGRect(x: 3, y: 3, width: 31, height: 60)] {
            let result = CandidateObjectProbe.assess([a, bad], width: 128, height: 128)
            XCTAssertEqual(result.status, .unusableRegions); XCTAssertFalse(result.withholdsCandidate)
        }
        for bad in [CGRect.null, CGRect.infinite, CGRect.zero, CGRect(x: CGFloat.nan, y: 1, width: 10, height: 10),
                    CGRect(x: 80, y: 10, width: -40, height: 40), CGRect(x: 10, y: 80, width: 40, height: -40)] {
            XCTAssertEqual(CandidateObjectProbe.assess([bad], width: 128, height: 128).status, .failed)
        }
        XCTAssertEqual(CandidateObjectProbe.assess([], width: 1025, height: 128).status, .failed)
    }

    func testDetectorFailureIsReportedButCancellationPropagates() throws {
        enum Failure: Error { case detector }
        let failed = try CandidateObjectProbe.check(raster()) { _ in throw Failure.detector }
        XCTAssertEqual(failed.status, .failed); XCTAssertFalse(failed.withholdsCandidate)
        XCTAssertThrowsError(try CandidateObjectProbe.check(raster()) { _ in throw CancellationError() }) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    private func fixture(restored: Bool) throws -> CandidateReviewSession {
        let image = try raster()
        let keptA = CandidateDistanceAssessment(ranking: .a, status: .withinReferenceRange)
        let keptB = CandidateDistanceAssessment(ranking: .b, status: .withinReferenceRange)
        let two = CandidateObjectCheck(status: .multipleRegions, detectedRegions: 2, usableRegions: 2)
        let run = CandidateReviewRun(photos: [
            .init(id: 0, image: image, suggestion: .a, issue: nil, distanceAssessment: keptA, objectCheck: two),
            .init(id: 1, image: image, suggestion: .a, issue: nil, distanceAssessment: keptA, objectCheck: two),
            .init(id: 2, image: image, suggestion: .b, issue: nil, distanceAssessment: keptB,
                  objectCheck: .init(status: .oneRegion, detectedRegions: 1, usableRegions: 1)),
            .init(id: 3, image: image, suggestion: .a, issue: nil, distanceAssessment: keptA, objectCheck: .failed),
            .init(id: 4, image: image, suggestion: nil, issue: nil,
                  distanceAssessment: .init(ranking: .b, status: .outsideReferenceRange)),
            .init(id: 5, image: image, suggestion: .b, issue: nil, distanceAssessment: keptB, objectCheck: two)
        ], referenceA: image, referenceB: image)
        let ids = (0..<6).map { "fixture-\($0)" }
        let choices: [CandidateReviewChoice] = [.both, .a, .b, .b, .b, .a]
        let saved: [IdentityPhotoSlot: [String]] = [.referenceA: (0..<5).map { "a\($0)" }, .referenceB: (0..<5).map { "b\($0)" }]
        let progress = CandidateSavedProgress(referenceFingerprint: try CandidateSavedProgress.fingerprint(saved),
            decisions: Dictionary(uniqueKeysWithValues: zip(ids, choices)), previousDecisions: nil, excluded: [])
        return CandidateReviewSession(run: run, progress: restored ? progress : nil, identifiers: ids)
    }

    func testWithholdingExcludesBulkAndNeverSetsBothOrRewritesSavedChoices() throws {
        var fresh = try fixture(restored: false)
        XCTAssertNil(fresh.run.photos[0].batchSuggestion)
        XCTAssertEqual(fresh.run.photos[3].batchSuggestion, .a) // failed check retains baseline, not a single-cat proof.
        fresh.confirmGroup(.a); fresh.confirmGroup(.b)
        XCTAssertEqual(fresh.decisions, [2: .b, 3: .a])
        XCTAssertFalse(fresh.decisions.values.contains(.both))
        var restored = try fixture(restored: true)
        let before = restored.decisions
        restored.confirmGroup(.a); restored.confirmGroup(.b)
        XCTAssertEqual(restored.decisions, before); XCTAssertEqual(restored.restoredIDs.count, 6)
        XCTAssertEqual(restored.remaining, 0)
    }

    func testBeforeAfterAggregateKeepsDistanceEffectSeparateAndDoesNotLeakGeometry() throws {
        let session = try fixture(restored: true)
        let report = session.report, comparison = report.objectComparison
        XCTAssertEqual(report.distanceFiltering.suggestedPhotosAfterFilter, 5)
        XCTAssertEqual(report.distanceFiltering.withheldPhotos, 1)
        XCTAssertEqual(report.proposed, 2)
        XCTAssertEqual(comparison.baselineProposals, 5); XCTAssertEqual(comparison.baselineMatchingProposals, 2)
        XCTAssertEqual(comparison.baselineBothInSingleProposals, 1)
        XCTAssertEqual(comparison.attemptedPhotos, 5); XCTAssertEqual(comparison.savedChoicesCompared, 5)
        XCTAssertEqual(comparison.withheldPhotos, 3)
        XCTAssertEqual(comparison.withheldMatchingAOrBChoices, 1)
        XCTAssertEqual(comparison.withheldDifferentCatProposals, 1)
        XCTAssertEqual(comparison.withheldBothPhotos, 1)
        XCTAssertEqual(comparison.withheldPhotos, comparison.withheldMatchingAOrBChoices + comparison.withheldDifferentCatProposals
            + comparison.withheldBothPhotos + comparison.withheldOtherPhotos + comparison.withheldUnreviewedOrUnsurePhotos)
        let json = try XCTUnwrap(report.json)
        for forbidden in ["fixture-", "boxes", "coordinates", "tensor", "decisions"] { XCTAssertFalse(json.contains("\"\(forbidden)")) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let fields = try XCTUnwrap(object["objectComparison"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["detector", "detectorSHA256", "method", "scope", "baselineProposals", "baselineMatchingProposals",
            "baselineBothInSingleProposals", "attemptedPhotos", "statuses", "withheldPhotos", "withheldMatchingAOrBChoices",
            "withheldDifferentCatProposals", "withheldBothPhotos", "withheldOtherPhotos", "withheldUnreviewedOrUnsurePhotos", "savedChoicesCompared", "goalValidated"])
        XCTAssertFalse(comparison.goalValidated); XCTAssertFalse(report.productValidated)
        XCTAssertFalse(report.productionDataChanged); XCTAssertFalse(report.photosIncluded); XCTAssertFalse(report.identifiersIncluded)
    }
}
