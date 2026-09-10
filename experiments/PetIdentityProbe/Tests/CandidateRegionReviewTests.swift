import SwiftUI
import XCTest
@testable import PetIdentityProbe

final class CandidateRegionReviewTests: XCTestCase {
    private let boxes = [CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                         CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.45)]
    private func vector(_ angle: Double) -> [Float] {
        [Float(cos(angle)), Float(sin(angle))] + Array(repeating: 0, count: 510)
    }
    private var referencesA: [[Float]?] { (0..<5).map { vector(Double($0) * 0.01) } }
    private var referencesB: [[Float]?] { (0..<5).map { vector(1.4 + Double($0) * 0.01) } }
    private func diagnostic(_ count: Int, available: Bool = true) -> IdentityAnimalDetectionDiagnostic {
        .init(observationLabels: Array(repeating: [.init(label: "Cat", confidence: 0.8)], count: count),
              revision: 2, systemCatLabel: "Cat", resultsAvailable: available)
    }
    private func image() throws -> CGImage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: IdentityDetectorControlID.orange.rawValue, withExtension: "png"))
        return try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
    }
    private func review(_ image: CGImage, boxes: [CGRect], original: IdentityInputIssue = .multipleCats,
                        recovery: IdentityRecoveryStatus = .originalIneligible,
                        detected: IdentityAnimalDetectionDiagnostic? = nil,
                        embed: (CGImage) throws -> [Float]) throws -> CandidateRegionReview? {
        try CandidateRegionProbe.review(image: image, originalIssue: original, recoveryStatus: recovery,
            diagnostic: detected ?? diagnostic(boxes.count), boxes: boxes,
            registrationA: referencesA, registrationB: referencesB, embed: embed)
    }

    func testNestedRegionsStaySeparateAndUseTheExistingRankingRule() throws {
        let raster = try image()
        var calls = 0
        let result = try XCTUnwrap(review(raster, boxes: boxes) { crop in
            XCTAssertGreaterThanOrEqual(crop.width, 32)
            calls += 1
            return self.vector(calls == 1 ? 0.02 : 1.42)
        })
        XCTAssertEqual(calls, 2); XCTAssertEqual(result.status, .prepared)
        XCTAssertEqual(result.regions.map(\.id), [0, 1])
        XCTAssertEqual(result.regions.map(\.suggestion), [.a, .b])
        XCTAssertEqual(result.regions.count, boxes.count) // No merge, suppression or largest-box selection.
        for region in result.regions {
            XCTAssertLessThanOrEqual(max(region.image.width, region.image.height), 160)
            let rect = try XCTUnwrap(IdentityImagePipeline.cropRect(boxes[region.id], width: raster.width, height: raster.height))
            XCTAssertEqual(region.box.minX, rect.minX / CGFloat(raster.width), accuracy: 0.000001)
            XCTAssertEqual(region.box.maxY, 1 - rect.minY / CGFloat(raster.height), accuracy: 0.000001)
        }
        switch IdentityImagePipeline.cropResult(raster, catBoxes: boxes) {
        case .failure(let issue): XCTAssertEqual(issue, .multipleCats) // Original single-cat policy is unchanged.
        case .success: XCTFail("Region review must not change the original crop policy")
        }
    }

    func testMissedCatsAndRecoveryRegionsDoNotActivateThisPath() throws {
        let raster = try image()
        for (original, recovery) in [(IdentityInputIssue.catNotDetected, IdentityRecoveryStatus.noCandidate),
                                    (.catNotDetected, .multipleCandidates), (.invalidCrop, .originalIneligible),
                                    (.multipleCats, .originalReused)] {
            let result = try review(raster, boxes: boxes, original: original, recovery: recovery) { _ in
                XCTFail("Ineligible inputs must not execute the model"); return self.vector(0)
            }
            XCTAssertNil(result)
        }
    }

    func testExcessOrInvalidRegionsFailClosedWithoutPartialInference() throws {
        let raster = try image()
        let examples: [([CGRect], CandidateRegionReview.Status)] = [
            (Array(repeating: boxes[0], count: CandidateRegionProbe.maximumRegions + 1), .tooManyRegions),
            ([], .invalidRegions), ([boxes[0]], .invalidRegions),
            ([boxes[0], .zero], .invalidRegions), ([boxes[0], .infinite], .invalidRegions),
            ([boxes[0], CGRect(x: 2, y: 2, width: 1, height: 1)], .invalidRegions),
            ([boxes[0], CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.01)], .invalidRegions)
        ]
        for (input, status) in examples {
            let result = try XCTUnwrap(review(raster, boxes: input) { _ in
                XCTFail("Do not infer only the valid subset"); return self.vector(0)
            })
            XCTAssertEqual(result.status, status); XCTAssertTrue(result.regions.isEmpty)
        }
        for detected in [diagnostic(1), diagnostic(2, available: false)] {
            let result = try XCTUnwrap(review(raster, boxes: boxes, detected: detected) { _ in
                XCTFail("Inconsistent detection must not reach the model"); return self.vector(0)
            })
            XCTAssertEqual(result.status, .invalidRegions); XCTAssertTrue(result.regions.isEmpty)
        }
    }

    func testErrorsAndCancellationAreNotPublishedAsPartialRegionSuccess() throws {
        let raster = try image()
        enum Failure: Error { case model }
        let errors: [Error] = [Failure.model, CancellationError()]
        for error in errors {
            var calls = 0
            XCTAssertThrowsError(try review(raster, boxes: boxes) { _ in
                calls += 1
                if calls == 2 { throw error }
                return self.vector(0)
            })
            XCTAssertEqual(calls, 2)
        }
    }

    func testRegionOverlayMatchesAspectFitAndBottomLeftCoordinates() throws {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5)
        let landscape = try XCTUnwrap(CandidateRegionProbe.displayRect(box,
            image: CGSize(width: 1000, height: 500), container: CGSize(width: 300, height: 330)))
        XCTAssertEqual(landscape.minX, 30, accuracy: 0.00001)
        XCTAssertEqual(landscape.minY, 135, accuracy: 0.00001)
        XCTAssertEqual(landscape.width, 120, accuracy: 0.00001)
        XCTAssertEqual(landscape.height, 75, accuracy: 0.00001)
        let portrait = try XCTUnwrap(CandidateRegionProbe.displayRect(box,
            image: CGSize(width: 500, height: 1000), container: CGSize(width: 300, height: 330)))
        XCTAssertEqual(portrait.minX, 84, accuracy: 0.00001)
        XCTAssertEqual(portrait.minY, 99, accuracy: 0.00001)
        XCTAssertEqual(portrait.width, 66, accuracy: 0.00001)
        XCTAssertEqual(portrait.height, 165, accuracy: 0.00001)
        for bad in [CGRect.zero, .infinite, CGRect(x: 2, y: 2, width: 1, height: 1)] {
            XCTAssertNil(CandidateRegionProbe.displayRect(bad, image: CGSize(width: 100, height: 100), container: CGSize(width: 100, height: 100)))
        }
        XCTAssertNil(CandidateRegionProbe.displayRect(box, image: .zero, container: CGSize(width: 100, height: 100)))
    }

    func testRegionSuggestionsNeverBulkConfirmAndBothIsASeparateUndoableChoice() throws {
        let raster = try image()
        let ready = CandidateRegionReview(status: .prepared, regions: [
            .init(id: 0, box: boxes[0], image: raster, assessment: .init(ranking: .a, status: .withinReferenceRange)),
            .init(id: 1, box: boxes[1], image: raster, assessment: .init(ranking: .b, status: .withinReferenceRange))
        ])
        let run = CandidateReviewRun(photos: [
            .init(id: 0, image: raster, suggestion: .a, issue: nil),
            .init(id: 1, image: raster, suggestion: nil, issue: .noSingleCat, regionReview: ready),
            .init(id: 2, image: raster, suggestion: .a, issue: .noSingleCat, regionReview: ready), // Defensive malformed input.
            .init(id: 3, image: raster, suggestion: nil, issue: .noSingleCat, regionReview: .init(status: .tooManyRegions)),
            .init(id: 4, image: raster, suggestion: nil, issue: .noSingleCat)
        ], referenceA: raster, referenceB: raster)
        var session = CandidateReviewSession(run: run)
        session.confirmGroup(.a); session.confirmGroup(.b); session.confirmGroup(.both)
        session.toggleExcluded(2)
        XCTAssertEqual(session.decisions, [0: .a]); XCTAssertTrue(session.excluded.isEmpty)
        XCTAssertEqual(session.pending(nil).map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(session.report.proposed, 1)
        session.choose(.both, for: 1)
        XCTAssertEqual(session.decisions[1], .both)
        XCTAssertNotEqual(CandidateReviewChoice.both.title, CandidateReviewChoice.other.title)
        session.undo(); XCTAssertNil(session.decisions[1])
        session.choose(.both, for: 1); session.choose(.a, for: 2)
        let report = session.report
        XCTAssertEqual(report.selected, 5); XCTAssertEqual(report.remaining, 2)
        XCTAssertEqual(report.individuallyLabeledUnranked, 2)
        XCTAssertEqual(report.multiRegionReview.attemptedPhotos, 3)
        XCTAssertEqual(report.multiRegionReview.photoStatuses, ["prepared": 2, "tooManyRegions": 1, "invalidRegions": 0])
        XCTAssertEqual(report.multiRegionReview.preparedRegions, 4)
        XCTAssertEqual(report.multiRegionReview.photosWithSuggestions, 2)
        XCTAssertEqual(report.multiRegionReview.regionsWithSuggestions, 4)
        XCTAssertEqual(report.multiRegionReview.confirmedChoices["both"], 1)
        XCTAssertEqual(report.multiRegionReview.confirmedChoices["a"], 1)
        XCTAssertEqual(report.multiRegionReview.confirmedChoices["other"], 0)
        XCTAssertEqual(report.multiRegionReview.remainingPhotos, 1)
        XCTAssertEqual(report.multiRegionReview.confirmedChoices.values.reduce(0, +) + report.multiRegionReview.remainingPhotos,
                       report.multiRegionReview.attemptedPhotos)
        XCTAssertEqual(report.noSingleCatBreakdown.reduce(0) { $0 + $1.count }, 4)
        let json = try XCTUnwrap(report.json)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let shared = try XCTUnwrap(root["multiRegionReview"] as? [String: Any])
        XCTAssertEqual(Set(shared.keys), ["scope", "maximumRegionsPerPhoto", "attemptedPhotos", "photoStatuses",
            "photosWithSuggestions", "preparedRegions", "regionsWithSuggestions", "confirmedChoices", "remainingPhotos"])
        for key in ["box", "regions", "ranking", "image", "assetIdentifier", "vector", "distance"] {
            XCTAssertFalse(json.contains("\"\(key)\""))
        }
        XCTAssertFalse(report.accuracyEvaluated); XCTAssertFalse(report.productionDataChanged)
    }

    @MainActor func testRegionPhotoReviewRendersWithFixedVisibleChoices() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let raster = try image()
        var calls = 0
        let ready = try XCTUnwrap(review(raster, boxes: boxes) { _ in
            calls += 1; return self.vector(calls == 1 ? 0.02 : 0.5)
        })
        let photo = CandidateReviewPhoto(id: 0, image: raster, suggestion: nil, issue: .noSingleCat, regionReview: ready)
        let previous = scene.windows.first(where: \.isKeyWindow)
        for size in [CGSize(width: 390, height: 844), CGSize(width: 320, height: 568)] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            let host = UIHostingController(rootView: CandidatePhotoReview(photo: photo, choice: nil, choose: { _ in true })
                .environment(\.colorScheme, .dark))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let renderer = UIGraphicsImageRenderer(size: window.bounds.size)
            let image = renderer.image { _ in XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "candidate-regions-generated-\(Int(size.width))"
            attachment.lifetime = .keepAlways; add(attachment)
            // Also inspect the below-the-fold reason, not only the pinned controls.
            func findScroll(_ view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView { return scroll }
                return view.subviews.lazy.compactMap { findScroll($0) }.first
            }
            let scroll = try XCTUnwrap(findScroll(host.view))
            let bottom = max(-scroll.adjustedContentInset.top,
                             scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let detail = renderer.image { _ in XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)) }
            let detailAttachment = XCTAttachment(image: detail)
            detailAttachment.name = "candidate-distance-reason-\(Int(size.width))"
            detailAttachment.lifetime = .keepAlways; add(detailAttachment)
        }
    }
}
