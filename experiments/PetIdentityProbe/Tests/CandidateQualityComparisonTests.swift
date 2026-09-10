import XCTest
import SwiftUI
@testable import PetIdentityProbe

final class CandidateQualityComparisonTests: XCTestCase {
    private func image() throws -> CGImage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cat-orange-square", withExtension: "png"))
        return try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
    }

    private func fixture() throws -> CandidateReviewRun {
        let raster = try image()
        let withheld = CandidateDistanceAssessment(ranking: .a, status: .outsideReferenceRange)
        return .init(photos: [
            .init(id: 0, image: raster, suggestion: .a, issue: nil),
            .init(id: 1, image: raster, suggestion: .a, issue: nil),
            .init(id: 2, image: raster, suggestion: .b, issue: nil),
            .init(id: 3, image: raster, suggestion: nil, issue: nil, distanceAssessment: withheld),
            .init(id: 4, image: raster, suggestion: nil, issue: nil, distanceAssessment: withheld),
            .init(id: 5, image: raster, suggestion: nil, issue: .noSingleCat),
            .init(id: 6, image: nil, suggestion: nil, issue: .unavailable),
            .init(id: 7, image: raster, suggestion: .b, issue: nil)
        ], referenceA: raster, referenceB: raster)
    }

    func testComparisonCountsEveryPhotoAndDoesNotTreatPartialReviewAsAccuracy() throws {
        var session = CandidateReviewSession(run: try fixture())
        let empty = session.report.qualityComparison
        XCTAssertEqual(empty.unreviewed, 8); XCTAssertEqual(empty.reviewedProposals, 0)
        XCTAssertEqual(empty.aOrBChoicePhotos, 0)
        XCTAssertFalse(empty.goalValidated); XCTAssertFalse(empty.independentAccuracyEvaluated)
        for (id, choice) in [(0, CandidateReviewChoice.a), (1, .both), (2, .a), (3, .a), (4, .other), (5, .b), (6, .unsure)] {
            session.choose(choice, for: id)
        }
        let result = session.report.qualityComparison
        XCTAssertEqual(result.counts, [[1,0,1,0,0,0], [1,0,0,0,0,1], [1,0,0,1,0,0], [0,1,0,0,1,0]])
        XCTAssertEqual(result.counts.flatMap { $0 }.reduce(0, +), result.selected)
        XCTAssertEqual(result.reviewedWithKnownChoice, 6)
        XCTAssertEqual(result.reviewedWithKnownChoice + result.unreviewed + result.unsure, 8)
        XCTAssertEqual(result.proposed, 4); XCTAssertEqual(result.reviewedProposals, 3)
        XCTAssertEqual(result.matchingProposals, 1); XCTAssertEqual(result.differentCatProposals, 1)
        XCTAssertEqual(result.bothInSingleCatProposals, 1); XCTAssertEqual(result.otherCatProposals, 0)
        XCTAssertEqual(result.matchingProposals + result.differentCatProposals + result.bothInSingleCatProposals + result.otherCatProposals, result.reviewedProposals)
        XCTAssertEqual(result.aOrBChoicePhotos, 4); XCTAssertEqual(result.matchingAOrBProposals, 1)
        XCTAssertEqual(result.aOrBChoicesByCat, ["a": 3, "b": 1])
        XCTAssertEqual(result.matchingProposalsByCat, ["a": 1, "b": 0])
        XCTAssertEqual(result.withheldAOrBChoices, 1); XCTAssertEqual(result.withheldBothOrOtherPhotos, 1)
        // Only a diagnostic comparison: even complete / perfect decisions never certify the goal.
        session.choose(.b, for: 7); session.choose(.a, for: 6) // Unreadable remains unsure.
        XCTAssertFalse(session.report.qualityComparison.goalValidated)
        XCTAssertEqual(session.report.qualityComparison.unsure, 1)
    }

    func testSavedChoicesStaySeparateAndCorrectionAndUndoRecomputeComparison() throws {
        let ids = (0..<8).map { "private-quality-photo-\($0)" }
        let saved = CandidateSavedProgress(referenceFingerprint: String(repeating: "a", count: 64),
            decisions: [ids[0]: .a, ids[1]: .both, ids[4]: .other], previousDecisions: nil, excluded: [])
        var session = CandidateReviewSession(run: try fixture(), progress: saved, identifiers: ids)
        let original = session.decisions
        let result = session.report.qualityComparison
        XCTAssertEqual(result.restoredChoices, 3)
        XCTAssertEqual(result.restoredCounts, [[1,0,1,0,0,0], [0,0,0,0,0,0], [0,0,0,1,0,0], [0,0,0,0,0,0]])
        XCTAssertTrue(result.decisionMeaning.contains("legacy-decisions-not-reinterpreted"))
        session.choose(.both, for: 0)
        XCTAssertEqual(session.report.qualityComparison.bothInSingleCatProposals, 2)
        XCTAssertEqual(session.report.qualityComparison.restoredChoices, 2)
        session.undo()
        XCTAssertEqual(session.decisions, original)
        XCTAssertEqual(session.report.qualityComparison.restoredCounts, result.restoredCounts)
        session.unconfirm(1)
        XCTAssertEqual(session.report.qualityComparison.bothInSingleCatProposals, 0)
        XCTAssertEqual(session.report.qualityComparison.unreviewed, 6)
        session.undo(); XCTAssertEqual(session.decisions, original)
    }

    func testBothCorrectionPreventsLaterSingleCatBulkOverwriteAndIsReversible() throws {
        var session = CandidateReviewSession(run: try fixture())
        session.choose(.both, for: 1)
        session.confirmGroup(.a)
        XCTAssertEqual(session.decisions[1], .both)
        XCTAssertEqual(session.decisions[0], .a)
        session.undo(); XCTAssertEqual(session.decisions, [1: .both])
        XCTAssertEqual(CandidateReviewChoice.a.confirmationTitle, "猫Aだけ")
        XCTAssertEqual(CandidateReviewChoice.b.confirmationTitle, "猫Bだけ")
        XCTAssertEqual(CandidateReviewChoice.both.confirmationTitle, "猫Aと猫B")
        XCTAssertEqual(CandidateReviewChoice.a.rawValue, "a") // No archive schema/meaning migration.
    }

    func testOnlyFixedAggregateComparisonIsSharedAndNoAcceptanceFlagsAreSet() throws {
        var session = CandidateReviewSession(run: try fixture())
        session.confirmGroup(.a); session.confirmGroup(.b)
        let json = try XCTUnwrap(session.report.json)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let quality = try XCTUnwrap(root["qualityComparison"] as? [String: Any])
        XCTAssertEqual(Set(quality.keys), ["scope", "decisionMeaning", "rows", "columns", "counts", "restoredCounts", "selected",
            "reviewedWithKnownChoice", "restoredChoices", "unreviewed", "unsure", "proposed", "reviewedProposals", "matchingProposals",
            "differentCatProposals", "bothInSingleCatProposals", "otherCatProposals", "aOrBChoicePhotos", "matchingAOrBProposals",
            "aOrBChoicesByCat", "matchingProposalsByCat", "withheldAOrBChoices", "withheldBothOrOtherPhotos",
            "independentAccuracyEvaluated", "goalValidated"])
        for forbidden in ["assetIdentifier", "image", "decisions", "distance", "radius", "vector", "box", "referenceFingerprint"] {
            XCTAssertFalse(json.contains("\"\(forbidden)\""))
        }
        XCTAssertFalse(session.report.productValidated); XCTAssertFalse(session.report.accuracyEvaluated)
        XCTAssertFalse(session.report.qualityComparison.goalValidated)
    }

    @MainActor func testSingleDetectedPhotoHasVisibleBothChoiceAtBothPhoneWidths() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        // A generated single-cat image stands in for the single-box UI path; this is not a detector accuracy test.
        let photo = try XCTUnwrap(fixture().photos.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        for size in [CGSize(width: 320, height: 568), CGSize(width: 390, height: 844)] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            let host = UIHostingController(rootView: CandidatePhotoReview(photo: photo, choice: size.width == 320 ? .a : nil,
                restoredChoice: size.width == 320, choose: { _ in true })
                .environment(\.colorScheme, .dark))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let raster = UIGraphicsImageRenderer(size: size).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: raster)
            attachment.name = "candidate-quality-single-path-generated-\(Int(size.width))"
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
