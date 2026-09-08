import XCTest
import SwiftUI
import UIKit
@testable import PetIdentityProbe

final class IdentityRecoveryComparisonTests: XCTestCase {
    private func vector(_ angle: Double) -> [Float] {
        var values = [Float](repeating: 0, count: 512)
        values[0] = Float(cos(angle)); values[1] = Float(sin(angle))
        return values
    }
    private func diagnostic(_ labels: [[IdentityAnimalLabelSample]] = [], available: Bool = true) -> IdentityAnimalDetectionDiagnostic {
        .init(observationLabels: labels, revision: 2, systemCatLabel: "Cat", resultsAvailable: available)
    }
    private func image() throws -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }.cgImage)
    }
    private func items() -> [IdentityRecoveryItem] {
        var rows: [IdentityRecoveryItem] = []
        for (slot, center) in [(IdentityPhotoSlot.referenceA, 0.0), (.referenceB, 1.5)] {
            rows += [-0.12, -0.06, 0, 0.06, 0.12].map {
                .init(slot: slot, original: vector(center + $0), candidate: vector(center + $0), recoveryStatus: .originalReused)
            }
        }
        rows += [
            .init(slot: .evaluationA, original: nil, candidate: vector(0), recoveryStatus: .recovered),
            .init(slot: .evaluationA, original: nil, candidate: vector(1.5), recoveryStatus: .recovered),
            .init(slot: .evaluationA, original: vector(0), candidate: vector(0), recoveryStatus: .originalReused),
            .init(slot: .evaluationB, original: vector(1.5), candidate: vector(1.5), recoveryStatus: .originalReused),
            .init(slot: .evaluationB, original: nil, candidate: nil, recoveryStatus: .noCandidate)
        ]
        return rows
    }

    func testOriginalEmbeddingIsComputedOnceAndNeverRetriedOrChanged() throws {
        let source = try image()
        var embeddings = 0
        let row = try IdentityRecoveryInputProbe.process(slot: .evaluationA, originalCrop: source,
            recover: { XCTFail("successful original must not trigger recovery"); return (nil, .noCandidate) },
            embed: { crop in XCTAssertTrue(crop === source); embeddings += 1; return self.vector(0) })
        XCTAssertEqual(embeddings, 1); XCTAssertEqual(row.original, row.candidate)
        XCTAssertEqual(row.recoveryStatus, .originalReused)
        XCTAssertThrowsError(try IdentityRecoveryInputProbe.process(slot: .evaluationA, originalCrop: source,
            recover: { XCTFail("do not retry a model error"); return (nil, .noCandidate) },
            embed: { _ in throw NSError(domain: "private-model-error", code: 1) }))
        XCTAssertThrowsError(try IdentityRecoveryInputProbe.process(slot: .evaluationA, originalCrop: nil,
            recover: { throw CancellationError() }, embed: { _ in XCTFail("cancelled"); return [] })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testOnlyAvailableRawZeroGetsOneRetryWithFullOriginalCrop() throws {
        let source = try image()
        let cat = diagnostic([[.init(label: "Cat", confidence: 0.8)]])
        let weak = diagnostic([[.init(label: "Cat", confidence: 0.1)]])
        let dog = diagnostic([[.init(label: "Dog", confidence: 0.8)]])
        for original in [nil, diagnostic(available: false), cat, weak, dog] {
            let result = try IdentityRecoveryInputProbe.attempt(image: source, original: original,
                detect: { _ in XCTFail("not raw zero"); return (cat, []) })
            XCTAssertEqual(result.status, .originalIneligible); XCTAssertNil(result.crop)
        }
        var detections = 0, embeddings = 0
        let row = try IdentityRecoveryInputProbe.process(slot: .referenceA, originalCrop: nil,
            recover: {
                try IdentityRecoveryInputProbe.attempt(image: source, original: self.diagnostic(), detect: { half in
                    detections += 1
                    XCTAssertEqual(half.width, 120); XCTAssertEqual(half.height, 80)
                    return (cat, [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)])
                })
            }, embed: { crop in
                embeddings += 1
                XCTAssertEqual(crop.width, 120); XCTAssertEqual(crop.height, 80) // Not the 60x40 resampled content.
                return self.vector(0)
            })
        XCTAssertEqual(detections, 1); XCTAssertEqual(embeddings, 1)
        XCTAssertNil(row.original); XCTAssertNotNil(row.candidate); XCTAssertEqual(row.recoveryStatus, .recovered)
        let failed = try IdentityRecoveryInputProbe.attempt(image: source, original: diagnostic(),
            detect: { _ in throw NSError(domain: "private-path", code: 1) })
        XCTAssertEqual(failed.status, .detectionFailed); XCTAssertNil(failed.crop)
        let outside = try IdentityRecoveryInputProbe.attempt(image: source, original: diagnostic(),
            detect: { _ in (cat, [CGRect(x: 0.1, y: 0.3, width: 0.4, height: 0.4)]) })
        XCTAssertEqual(outside.status, .invalidCrop); XCTAssertNil(outside.crop)
        XCTAssertThrowsError(try IdentityRecoveryInputProbe.attempt(image: source, original: diagnostic(),
            detect: { _ in throw CancellationError() })) { XCTAssertTrue($0 is CancellationError) }
    }

    func testPairedDenominatorsWrongAssignmentsAndDiagnosticGates() throws {
        let report = try IdentityRecoveryComparisonCore.report(items())
        XCTAssertEqual(report.original.status, .evaluated); XCTAssertEqual(report.candidate.status, .evaluated)
        XCTAssertEqual(report.original.aggregate?.overall, .init(correct: 2, wrong: 0, unknown: 3))
        XCTAssertEqual(report.candidate.aggregate?.overall, .init(correct: 3, wrong: 1, unknown: 1))
        XCTAssertEqual(report.pairedOutcomes, [[2, 0, 0], [0, 0, 0], [1, 1, 1]])
        XCTAssertEqual(report.original.aggregate?.evaluationCountsByCat, ["A": 3, "B": 2])
        XCTAssertEqual(report.original.aggregate?.thresholds, report.candidate.aggregate?.thresholds)
        XCTAssertEqual(report.original.aggregate?.registrationRadii, report.candidate.aggregate?.registrationRadii)
        for arm in [report.original, report.candidate] {
            XCTAssertEqual(arm.aggregate?.purpose, .diagnostic)
            XCTAssertEqual(arm.aggregate?.gate, IdentityEvaluationGate(counts: .init(correct: 30, wrong: 0, unknown: 0), purpose: .diagnostic))
        }
        var regressions = items()
        regressions[12] = .init(slot: .evaluationA, original: vector(0), candidate: vector(1.5), recoveryStatus: .recovered)
        XCTAssertEqual(try IdentityRecoveryComparisonCore.report(regressions).pairedOutcomes?[0][1], 1)
        // Above deliberately mismatched synthetic vectors check reporting, not real cat accuracy.
    }

    func testUnavailableReferenceIsNotDisguisedAsUnknownAndCalibrationUsesOnlyOwnReferences() throws {
        var rows = items()
        rows[0] = .init(slot: .referenceA, original: nil, candidate: vector(-0.12), recoveryStatus: .recovered)
        let report = try IdentityRecoveryComparisonCore.report(rows)
        XCTAssertEqual(report.original.status, .unusableReferences); XCTAssertNil(report.original.aggregate)
        XCTAssertEqual(report.candidate.status, .evaluated); XCTAssertNil(report.pairedOutcomes)
        let radius = report.candidate.aggregate?.registrationRadii
        rows[10] = .init(slot: .evaluationA, original: nil, candidate: vector(3), recoveryStatus: .recovered)
        XCTAssertEqual(try IdentityRecoveryComparisonCore.report(rows).candidate.aggregate?.registrationRadii, radius)
        let partial = try IdentityRecoveryComparisonCore.report(Array(rows.prefix(1)))
        XCTAssertEqual(partial.candidate.status, .insufficientSelections); XCTAssertNil(partial.candidate.aggregate)
        XCTAssertEqual(partial.slots[0].selected, 1); XCTAssertEqual(partial.slots[0].usableCandidate, 1)
        let noEvaluation = try IdentityRecoveryComparisonCore.report(Array(items().prefix(10)))
        XCTAssertEqual(noEvaluation.original.status, .noEvaluationPhotos)
    }

    func testSelectionAndExportBoundaries() throws {
        XCTAssertThrowsError(try IdentityRecoveryComparisonCore.validateSelection([:]))
        XCTAssertThrowsError(try IdentityRecoveryComparisonCore.validateSelection([.referenceA: [""]]))
        XCTAssertThrowsError(try IdentityRecoveryComparisonCore.validateSelection([.referenceA: ["same"], .evaluationA: ["same"]]))
        XCTAssertThrowsError(try IdentityRecoveryComparisonCore.validateSelection([.referenceA: (0..<6).map(String.init)]))
        XCTAssertNoThrow(try IdentityRecoveryComparisonCore.validateSelection([.referenceA: ["one-selected-id"]]))
        let report = try IdentityRecoveryComparisonCore.report(items())
        let json = try XCTUnwrap(report.json)
        XCTAssertEqual(report.protocolIdentifier, "pet-identity-half-recovery-paired-diagnostic-v3")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["protocolIdentifier", "appVersion", "appBuild", "modelSHA256", "runtimeVersion", "osVersion",
            "scope", "method", "calibration", "duplicatePolicy", "photoFetch", "slots", "original", "candidate", "outcomeOrder", "pairedOutcomes", "referenceRanking",
            "photosIncluded", "identifiersIncluded", "embeddingsIncluded", "individualPredictionsIncluded", "productionDataChanged", "productValidated"])
        for slot in try XCTUnwrap(object["slots"] as? [[String: Any]]) {
            XCTAssertEqual(Set(slot.keys), ["slot", "selected", "usableOriginal", "usableCandidate", "recoveryCounts", "originalInputIssues"])
        }
        for key in ["photosIncluded", "identifiersIncluded", "embeddingsIncluded", "individualPredictionsIncluded", "productionDataChanged", "productValidated"] {
            XCTAssertEqual(object[key] as? Bool, false)
        }
        XCTAssertFalse(json.contains("one-selected-id"))
        for arm in ["original", "candidate"] {
            XCTAssertEqual(Set(try XCTUnwrap(object[arm] as? [String: Any]).keys), ["status", "aggregate", "withheldSeparation"])
        }
    }

    func testGeneratedControlRecoveryRunsRealModelButNotIdentityValidation() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: IdentityDetectorControlID.orange.rawValue, withExtension: "png"))
        let image = try XCTUnwrap(IdentityImagePipeline.upright(try XCTUnwrap(UIImage(contentsOfFile: url.path))))
        // Force raw-zero trigger to exercise this path on a public generated fixture, not to reproduce a private photo.
        let recovery = try IdentityRecoveryInputProbe.attempt(image: image, original: diagnostic())
        XCTAssertEqual(recovery.status, .recovered)
        let vector = try IdentityCPUSession().embedding(try XCTUnwrap(recovery.crop))
        XCTAssertEqual(vector.count, 512)
        let report = try IdentityRecoveryComparisonCore.report([
            .init(slot: .referenceA, original: nil, candidate: vector, recoveryStatus: .recovered)])
        XCTAssertEqual(report.slots[0].usableCandidate, 1)
        XCTAssertNil(report.candidate.aggregate); XCTAssertFalse(report.productValidated)
        print("PROBE_GENERATED_RECOVERY_MODEL validated=true identityEvaluated=false")
    }

    @MainActor func testRecoveryComparisonPanelRendersAtPhoneWidth() throws {
        var rows: [IdentityRecoveryItem] = []
        for (slot, center) in [(IdentityPhotoSlot.referenceA, 0.0), (.referenceB, 0.1)] {
            rows += [-0.12, -0.06, 0, 0.06, 0.12].map {
                .init(slot: slot, original: vector(center + $0), candidate: vector(center + $0), recoveryStatus: .originalReused)
            }
        }
        rows += [(IdentityPhotoSlot.evaluationA, 0.048), (.evaluationA, 0.052), (.evaluationB, 0.052)].map {
            .init(slot: $0.0, original: vector($0.1), candidate: vector($0.1), recoveryStatus: .originalReused)
        }
        let report = try IdentityRecoveryComparisonCore.report(rows)
        let view = IdentityRecoveryComparisonView(report: report)
            .padding(16).frame(width: 390).background(Color.black).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view); renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width, 390); XCTAssertGreaterThan(image.size.height, 250)
        let attachment = XCTAttachment(image: image)
        attachment.name = "synthetic-recovery-comparison-panel"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testStoreReusesSavedSelectionsAndDiscardsLateAndBackgroundResults() async throws {
        let began = expectation(description: "comparison began")
        var pending: CheckedContinuation<IdentityRecoveryRun, Never>?
        var calls = 0
        let saved: [IdentityPhotoSlot: [String]] = [.referenceA: ["saved-a"], .referenceB: ["saved-b"]]
        let report = IdentityRecoveryRun(report: try IdentityRecoveryComparisonCore.report([]), unusableReferences: [
            .init(slot: .referenceB, target: .init(index: 0, assetIdentifier: "saved-b"), thumbnail: nil,
                  originalIssue: .catNotDetected, recoveryStatus: .noCandidate)])
        let store = IdentityEvaluationStore(recoveryInspector: { selections in
            XCTAssertEqual(selections, saved); calls += 1
            return await withCheckedContinuation { pending = $0; began.fulfill() }
        })
        store.selections = saved
        store.recoveryResult = report
        store.compareRecovery()
        XCTAssertNil(store.recoveryResult)
        await fulfillment(of: [began], timeout: 2)
        store.compareRecovery(); XCTAssertEqual(calls, 1); XCTAssertNil(store.picker)
        store.suspend()
        try XCTUnwrap(pending).resume(returning: report)
        await Task.yield()
        XCTAssertNil(store.recoveryResult); XCTAssertFalse(store.running); XCTAssertFalse(store.checkingRecovery)
        XCTAssertEqual(store.selections, saved)
        store.recoveryResult = report; store.suspend(); XCTAssertNil(store.recoveryResult)
    }
}
