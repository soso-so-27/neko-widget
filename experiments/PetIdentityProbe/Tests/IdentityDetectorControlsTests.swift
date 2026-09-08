import XCTest
import UIKit
@testable import PetIdentityProbe

final class IdentityDetectorControlsTests: XCTestCase {
    func testBundledComparisonWorksWithoutSelectedPhotosOrIdentityModel() async throws {
        let run = try await IdentityPhotoService().compareDetector(id: nil)
        XCTAssertEqual(run.report.controls.map(\.control), IdentityDetectorControlID.allCases)
        XCTAssertTrue(run.report.controls.allSatisfy { $0.input.imageReadable })
        XCTAssertTrue(run.report.controls.allSatisfy { $0.input.animalDetection?.resultsAvailable == true })
        XCTAssertNil(run.report.savedPhoto)
        XCTAssertNil(run.savedPhotoThumbnail)
        XCTAssertFalse(run.report.modelExecuted)
        XCTAssertFalse(run.report.identityEvaluated)
        XCTAssertEqual(run.report.allControlsHaveSingleUsableCrop, run.report.controls.allSatisfy { $0.input.cropUsable })
        print("PROBE_DEVICE_CONTROLS_JSON=\(try XCTUnwrap(run.report.json).replacingOccurrences(of: "\n", with: ""))")
    }

    func testSavedPhotoExportCannotContainGeometryAndMissingControlIsNotSuccess() throws {
        let detection = IdentityAnimalDetectionDiagnostic(observationLabels: [], revision: 2, systemCatLabel: "Cat")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { _ in }.cgImage
        let selected = IdentityDetectorInputReport(image: image, diagnostic: detection, issue: .catNotDetected)
        let control = IdentityDetectorControlResult(control: .gray,
            input: selected, acceptedBoxes: [try XCTUnwrap(IdentityControlBox(CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)))])
        let report = IdentityDetectorComparisonReport(controls: [control], savedPhoto: selected)
        let json = try XCTUnwrap(report.json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let saved = try XCTUnwrap(object["savedPhoto"] as? [String: Any])
        XCTAssertEqual(Set(saved.keys), ["imageReadable", "format", "animalDetection", "inputIssue", "cropUsable"])
        XCTAssertFalse(json.contains("localIdentifier"))
        XCTAssertNil(saved["acceptedBoxes"])
        XCTAssertNil(saved["thumbnail"])
        XCTAssertEqual(object["savedPhotoGeometryIncluded"] as? Bool, false)
        XCTAssertEqual(object["productValidated"] as? Bool, false)
        XCTAssertFalse(report.allControlsHaveSingleUsableCrop)
        XCTAssertEqual((object["controls"] as? [[String: Any]])?.first?["acceptedBoxes"] is [[String: Any]], true)
        XCTAssertNil(IdentityControlBox(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)))
        XCTAssertNil(IdentityControlBox(.zero))
        let unavailable = IdentityDetectorInputReport(image: nil, diagnostic: nil, issue: .assetUnavailable)
        XCTAssertNil(unavailable.animalDetection) // Failure is not a zero-result detector run.
        XCTAssertFalse(unavailable.imageReadable)
    }

    @MainActor func testComparisonUsesOnlyExistingFirstAAndCancelledResultCannotRevive() async throws {
        let began = expectation(description: "comparison began")
        var pending: CheckedContinuation<IdentityDetectorComparisonRun, Never>?
        var calls = 0
        let store = IdentityEvaluationStore(detectorInspector: { id in
            XCTAssertEqual(id, "saved-a-first")
            calls += 1
            return await withCheckedContinuation { continuation in
                pending = continuation
                began.fulfill()
            }
        })
        let selections: [IdentityPhotoSlot: [String]] = [.referenceA: ["saved-a-first", "saved-a-second"], .referenceB: ["saved-b"]]
        store.selections = selections
        store.compareDetector()
        await fulfillment(of: [began], timeout: 2)
        store.compareDetector() // Busy operation is not duplicated.
        XCTAssertEqual(calls, 1)
        XCTAssertNil(store.picker)
        store.suspend()
        let lateCrop = IdentityRecoveredCropPreview(report: IdentityRecoveredCropReport(status: .candidatePrepared),
            originalThumbnail: nil, cropThumbnail: nil, originalBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        try XCTUnwrap(pending).resume(returning: IdentityDetectorComparisonRun(
            report: IdentityDetectorComparisonReport(controls: [], savedPhoto: nil, savedPhotoCropCheck: lateCrop.report),
            savedPhotoThumbnail: nil, recoveredCropPreview: lateCrop))
        await Task.yield()
        XCTAssertEqual(store.selections, selections)
        XCTAssertNil(store.detectorResult)
        XCTAssertFalse(store.running)
        XCTAssertFalse(store.checkingDetector)
    }

    @MainActor func testCompletedComparisonKeepsSelectionsAndIsClearedOnBackground() async {
        let completed = expectation(description: "comparison completed")
        let store = IdentityEvaluationStore(detectorInspector: { id in
            XCTAssertNil(id)
            completed.fulfill()
            let crop = IdentityRecoveredCropPreview(report: IdentityRecoveredCropReport(status: .candidatePrepared),
                originalThumbnail: nil, cropThumbnail: nil, originalBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
            return IdentityDetectorComparisonRun(report: IdentityDetectorComparisonReport(controls: [], savedPhoto: nil),
                                                 savedPhotoThumbnail: nil, recoveredCropPreview: crop)
        })
        store.compareDetector()
        await fulfillment(of: [completed], timeout: 2)
        await Task.yield()
        XCTAssertNotNil(store.detectorResult)
        XCTAssertNotNil(store.detectorResult?.recoveredCropPreview?.originalBox)
        XCTAssertTrue(store.selections.isEmpty)
        XCTAssertFalse(store.running)
        store.suspend()
        XCTAssertNil(store.detectorResult)
    }
}
