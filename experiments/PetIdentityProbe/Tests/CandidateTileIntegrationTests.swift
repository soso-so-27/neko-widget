import XCTest
import UIKit
@testable import PetIdentityProbe

final class CandidateTileIntegrationTests: XCTestCase {
    private func fixture() throws -> CandidateReviewRun {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cat-orange-square", withExtension: "png"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        let a = CandidateDistanceAssessment(ranking: .a, status: .withinReferenceRange)
        let b = CandidateDistanceAssessment(ranking: .b, status: .withinReferenceRange)
        let held = CandidateTileCheck(status: .separateRegions, requests: 4, validRegions: 2)
        return .init(photos: [
            .init(id: 0, image: image, suggestion: .a, issue: nil, distanceAssessment: a, tileCheck: held),
            .init(id: 1, image: image, suggestion: .a, issue: nil, distanceAssessment: a, tileCheck: held),
            .init(id: 2, image: image, suggestion: .b, issue: nil, distanceAssessment: b,
                  tileCheck: .init(status: .noSeparateRegions, requests: 4, validRegions: 1)),
            .init(id: 3, image: image, suggestion: .a, issue: nil, distanceAssessment: a,
                  tileCheck: .init(status: .incomplete, requests: 4, validRegions: 0)),
            .init(id: 4, image: image, suggestion: nil, issue: nil,
                  distanceAssessment: .init(ranking: .b, status: .outsideReferenceRange)),
            .init(id: 5, image: image, suggestion: .b, issue: nil, distanceAssessment: b, tileCheck: held)
        ], referenceA: image, referenceB: image)
    }

    func testOnlyPositiveExtraEvidenceWithholdsAndNeverAssignsBoth() throws {
        var session = CandidateReviewSession(run: try fixture())
        XCTAssertNil(session.run.photos[0].batchSuggestion)
        XCTAssertEqual(session.run.photos[0].batchSuggestionBeforeTileCheck, .a)
        XCTAssertEqual(session.run.photos[2].batchSuggestion, .b)
        XCTAssertEqual(session.run.photos[3].batchSuggestion, .a) // Incomplete is separately reported, not a positive signal.
        XCTAssertNil(session.run.photos[4].batchSuggestion)
        session.confirmGroup(.a); session.confirmGroup(.b)
        XCTAssertEqual(session.decisions, [2: .b, 3: .a])
        XCTAssertNil(session.decisions[0]); XCTAssertNil(session.decisions[1])
        session.choose(.both, for: 0)
        session.confirmGroup(.a)
        XCTAssertEqual(session.decisions[0], .both)
    }

    func testBeforeAndAfterUseSavedChoicesWithoutChangingThemOrDistanceCounts() throws {
        let ids = (0..<6).map { "private-tile-\($0)" }
        let progress = CandidateSavedProgress(referenceFingerprint: String(repeating: "a", count: 64),
            decisions: [ids[0]: .both, ids[1]: .a, ids[2]: .b, ids[3]: .b, ids[4]: .b, ids[5]: .a],
            previousDecisions: nil, excluded: [])
        var session = CandidateReviewSession(run: try fixture(), progress: progress, identifiers: ids)
        let saved = session.decisions
        let report = session.report
        XCTAssertEqual(report.previouslyConfirmed, 6)
        XCTAssertEqual(report.remaining, 0)
        XCTAssertEqual(report.proposed, 2)
        XCTAssertEqual(report.distanceFiltering.suggestedPhotosAfterFilter, 5)
        XCTAssertEqual(report.distanceFiltering.withheldPhotos, 1)
        let tiles = report.tileComparison
        XCTAssertEqual(tiles.baselineProposals, 5)
        XCTAssertEqual(tiles.baselineMatchingProposals, 2)
        XCTAssertEqual(tiles.baselineBothInSingleProposals, 1)
        XCTAssertEqual(tiles.attemptedPhotos, 5); XCTAssertEqual(tiles.requestCount, 20)
        XCTAssertEqual(tiles.withheldPhotos, 3)
        XCTAssertEqual(tiles.withheldMatchingAOrBChoices, 1) // Old A/B choices are not reinterpreted as single-cat truth.
        XCTAssertEqual(tiles.withheldDifferentCatProposals, 1)
        XCTAssertEqual(tiles.withheldBothPhotos, 1)
        XCTAssertEqual(tiles.savedChoicesCompared, 5)
        XCTAssertEqual(tiles.withheldPhotos, tiles.withheldMatchingAOrBChoices + tiles.withheldDifferentCatProposals + tiles.withheldBothPhotos + tiles.withheldOtherPhotos + tiles.withheldUnreviewedOrUnsurePhotos)
        XCTAssertEqual(report.qualityComparison.counts, [[0,1,0,0,0,0], [0,1,0,0,0,0], [0,1,0,0,0,0], [2,0,1,0,0,0]])
        XCTAssertEqual(session.decisions, saved)
        session.confirmGroup(.a); session.confirmGroup(.b)
        XCTAssertEqual(session.decisions, saved)
        XCTAssertTrue(session.actions.isEmpty)
        XCTAssertFalse(report.tileComparison.goalValidated)
    }

    func testSharedTileInformationIsFixedAggregateOnlyAndUnreviewedStaysUnknown() throws {
        let session = CandidateReviewSession(run: try fixture())
        let json = try XCTUnwrap(session.report.json)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let tiles = try XCTUnwrap(root["tileComparison"] as? [String: Any])
        XCTAssertEqual(Set(tiles.keys), ["method", "scope", "baselineProposals", "baselineMatchingProposals", "baselineBothInSingleProposals",
            "attemptedPhotos", "requestCount", "statuses", "withheldPhotos", "withheldMatchingAOrBChoices", "withheldDifferentCatProposals", "withheldBothPhotos",
            "withheldOtherPhotos", "withheldUnreviewedOrUnsurePhotos", "savedChoicesCompared", "goalValidated"])
        XCTAssertEqual(session.report.tileComparison.withheldUnreviewedOrUnsurePhotos, 3)
        XCTAssertEqual(session.report.tileComparison.baselineMatchingProposals, 0)
        XCTAssertFalse(session.report.productValidated)
        for forbidden in ["identifiers", "image", "boxes", "vector", "referenceFingerprint", "decisions"] {
            XCTAssertFalse(json.contains("\"\(forbidden)\""))
        }
    }
}
