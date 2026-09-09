import SwiftUI
import XCTest
@testable import PetIdentityProbe

final class CandidateReviewTests: XCTestCase {
    private func vector(_ angle: Double) -> [Float] {
        [Float(cos(angle)), Float(sin(angle))] + Array(repeating: 0, count: 510)
    }
    private var saved: [IdentityPhotoSlot: [String]] {
        [.referenceA: (0..<5).map { "a\($0)" }, .referenceB: (0..<5).map { "b\($0)" }, .evaluationA: ["old-eval"]]
    }
    private func image() throws -> CGImage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: IdentityDetectorControlID.orange.rawValue, withExtension: "png"))
        return try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
    }
    private func makeReviewFixture() throws -> CandidateReviewRun {
        let raster = try image()
        return .init(photos: [
            .init(id: 0, image: raster, suggestion: .a, issue: nil),
            .init(id: 1, image: raster, suggestion: .a, issue: nil),
            .init(id: 2, image: raster, suggestion: .b, issue: nil),
            .init(id: 3, image: raster, suggestion: nil, issue: .similarPhoto),
            .init(id: 4, image: nil, suggestion: nil, issue: .unavailable)
        ], referenceA: raster, referenceB: raster)
    }

    func testSuggestionsKeepTheExistingRuleAndNeverAcceptIdentity() throws {
        let a = [0, 0.8, 1, 1.2, 1.4].map { Optional(vector($0)) }
        let b = [0.2, 0.3, 0.4, 0.5, 0.6].map { Optional(vector($0)) }
        let inputs: [[Float]?] = [vector(0), nil, []]
        let output = try IdentityEvaluationCore.reviewSuggestions(registrationA: a, registrationB: b, inputs: inputs)
        XCTAssertEqual(output, [.b, .missingEmbedding, .invalidEmbedding])
        let old = try IdentityEvaluationCore.compareReferenceRanking(registrationA: a, registrationB: b,
            evaluationA: inputs, evaluationB: [])
        XCTAssertEqual(old.aggregatedReferences.overall.otherFirst, 1)
        let tie = try IdentityEvaluationCore.reviewSuggestions(registrationA: a, registrationB: a, inputs: [vector(0)])
        XCTAssertEqual(tie, [.equalScores])
        XCTAssertThrowsError(try IdentityEvaluationCore.reviewSuggestions(registrationA: [], registrationB: b, inputs: inputs))
        XCTAssertThrowsError(try IdentityEvaluationCore.reviewSuggestions(registrationA: Array(repeating: nil, count: 5), registrationB: b, inputs: inputs))
        XCTAssertThrowsError(try IdentityEvaluationCore.reviewSuggestions(registrationA: a, registrationB: b, inputs: []))
        XCTAssertThrowsError(try IdentityEvaluationCore.reviewSuggestions(registrationA: a, registrationB: b, inputs: Array(repeating: nil, count: 25)))
    }

    func testBatchExclusionCorrectionUndoAndUnseenPhotosRemainSeparate() throws {
        var session = CandidateReviewSession(run: try makeReviewFixture())
        XCTAssertTrue(session.decisions.isEmpty)
        session.toggleExcluded(1)
        session.confirmGroup(.a)
        XCTAssertEqual(session.decisions, [0: .a]); XCTAssertEqual(session.remaining, 4)
        session.choose(.b, for: 1)
        session.undo()
        XCTAssertEqual(session.decisions, [0: .a]); XCTAssertFalse(session.canUndo)
        session.choose(.b, for: 1)
        session.confirmGroup(.b)
        session.choose(.other, for: 3)
        session.choose(.a, for: 4) // Unreadable photo cannot be classified.
        XCTAssertNil(session.decisions[4])
        session.choose(.unsure, for: 4)
        XCTAssertEqual(session.remaining, 0)
        XCTAssertEqual(session.run.photos.map(\.suggestion), [.a, .a, .b, nil, nil])
        let report = session.report
        XCTAssertEqual(report.selected, 5); XCTAssertEqual(report.proposed, 3)
        XCTAssertEqual(report.confirmedAsSuggested, 2); XCTAssertEqual(report.changedSuggestion, 1)
        XCTAssertEqual(report.individuallyLabeledUnranked, 1); XCTAssertEqual(report.unsure, 1)
        XCTAssertEqual(report.confirmedAsSuggested + report.changedSuggestion + report.individuallyLabeledUnranked + report.unsure + report.remaining, report.selected)
        XCTAssertEqual(report.reviewActions["batchConfirmation"], 2)
        XCTAssertEqual(report.reviewActions["individualChoice"], 4)
        XCTAssertEqual(report.reviewActions["undo"], 1)
        XCTAssertEqual(report.totalReviewActions, 8)
        session.confirmGroup(.a); session.choose(.unsure, for: 4)
        XCTAssertEqual(session.report.totalReviewActions, 9) // Reconfirming a label is still a user tap.
    }

    func testNilPreviewIsNeverBulkConfirmedEvenWithAnUnexpectedSuggestion() {
        var session = CandidateReviewSession(run: .init(photos: [
            .init(id: 0, image: nil, suggestion: .a, issue: .unavailable)
        ], referenceA: nil, referenceB: nil))
        session.confirmGroup(.a); session.toggleExcluded(0)
        XCTAssertTrue(session.decisions.isEmpty); XCTAssertEqual(session.remaining, 1)
    }

    func testSelectionCannotReuseKnownReferencesOrEvaluationsAndRejectsMalformedInputs() throws {
        try CandidateReviewSelection.validate(["new1", "new2"], saved: saved)
        for ids in [[], ["a0"], ["b3"], ["old-eval"], ["new", "new"], [""], Array(repeating: "x", count: 25)] {
            XCTAssertThrowsError(try CandidateReviewSelection.validate(ids, saved: saved))
        }
        XCTAssertThrowsError(try CandidateReviewSelection.validate(["new"], saved: [:]))
    }

    func testExportIsAggregateOnlyAndNeverCallsUserConfirmationAccuracy() throws {
        var session = CandidateReviewSession(run: try makeReviewFixture())
        session.confirmGroup(.a)
        let json = try XCTUnwrap(session.report.json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["protocolIdentifier", "appBuild", "modelSHA256", "method", "scope", "selected", "proposed",
            "confirmedAsSuggested", "changedSuggestion", "individuallyLabeledUnranked", "unsure", "remaining", "inputIssues", "reviewActions",
            "totalReviewActions", "hypotheticalManualLabelTaps", "manualComparison", "photosIncluded", "identifiersIncluded", "embeddingsIncluded",
            "individualPredictionsIncluded", "productionDataChanged", "accuracyEvaluated", "productValidated"])
        XCTAssertFalse(session.report.accuracyEvaluated); XCTAssertFalse(session.report.productValidated)
        XCTAssertTrue(session.report.manualComparison.contains("not-measured"))
        for key in ["decisions", "suggestion", "image", "assetIdentifier", "distance", "vector"] {
            XCTAssertFalse(json.contains("\"\(key)\""))
        }
        XCTAssertEqual(session.report.remaining, 3)
    }

    func testArchiveIsBoundedProtectedAndSeparateFromLegacy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CandidateReviewTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = IdentitySelectionArchive(url: directory.appendingPathComponent("legacy.json"))
        let archive = CandidateSelectionArchive(url: directory.appendingPathComponent("candidates.json"))
        try legacy.save(saved); let before = try Data(contentsOf: legacy.url)
        try archive.save(["new1", "new2"])
        XCTAssertEqual(try archive.load(), ["new1", "new2"])
        XCTAssertEqual(try archive.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertTrue(IdentitySelectionArchive.writingOptions.contains(.completeFileProtection))
        #if !targetEnvironment(simulator)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: archive.url.path)[.protectionKey] as? FileProtectionType, .complete)
        #endif
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archive.url)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema", "identifiers"])
        XCTAssertThrowsError(try archive.save(["duplicate", "duplicate"]))
        XCTAssertEqual(try archive.load(), ["new1", "new2"])
        try archive.save([]); XCTAssertTrue(try archive.load().isEmpty)
        XCTAssertEqual(try Data(contentsOf: legacy.url), before)
        try Data("{\"schema\":99,\"identifiers\":[]}".utf8).write(to: archive.url)
        XCTAssertThrowsError(try archive.load())
    }

    @MainActor func testPickerCancelNilKnownReuseAndStaleResultsPreserveSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CandidateStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = IdentitySelectionArchive(url: directory.appendingPathComponent("legacy.json"))
        let archive = CandidateSelectionArchive(url: directory.appendingPathComponent("candidate.json"))
        try legacy.save(saved); try archive.save(["fresh"])
        let store = CandidateReviewStore(referenceArchive: legacy, candidateArchive: archive)
        let attempts: [[String?]] = [[], [nil], ["a0"], ["old-eval"], ["x", "x"]]
        for ids in attempts {
            let request = CandidatePickerRequest(); store.picker = request
            store.picked(ids, request: request)
            XCTAssertEqual(store.selected, ["fresh"])
        }
        let request = CandidatePickerRequest(); store.picker = request
        store.differentScenes = true
        store.picked(["new1", "new2"], request: request)
        XCTAssertFalse(store.differentScenes); XCTAssertEqual(try archive.load(), ["new1", "new2"])
        let stale = CandidatePickerRequest(); store.picker = stale
        store.session = CandidateReviewSession(run: try makeReviewFixture())
        store.suspend(); store.picked(["late"], request: stale)
        XCTAssertNil(store.session); XCTAssertNil(store.picker); XCTAssertEqual(store.selected, ["new1", "new2"])
        store.clearCandidateSelection()
        XCTAssertTrue(try archive.load().isEmpty); XCTAssertEqual(try legacy.load(), saved)
        try Data("broken".utf8).write(to: archive.url)
        let corrupt = CandidateReviewStore(referenceArchive: legacy, candidateArchive: archive)
        XCTAssertTrue(corrupt.candidateReadFailed); XCTAssertFalse(corrupt.canChoose)
        corrupt.clearCandidateSelection()
        XCTAssertFalse(corrupt.candidateReadFailed); XCTAssertTrue(corrupt.canChoose)
        XCTAssertEqual(try legacy.load(), saved)
    }

    @MainActor func testLateCompletionAndReferenceChangeDoNotPublish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CandidateAsyncTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = IdentitySelectionArchive(url: directory.appendingPathComponent("legacy.json"))
        let archive = CandidateSelectionArchive(url: directory.appendingPathComponent("candidate.json"))
        try legacy.save(saved); try archive.save(["fresh"])
        var finish: CheckedContinuation<CandidateReviewRun, Error>?
        let started = expectation(description: "runner started")
        let store = CandidateReviewStore(referenceArchive: legacy, candidateArchive: archive, runner: { _, _ in
            try await withCheckedThrowingContinuation { finish = $0; started.fulfill() }
        })
        store.differentScenes = true; store.start()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(store.running)
        store.suspend()
        finish?.resume(returning: try makeReviewFixture())
        await Task.yield(); await Task.yield()
        XCTAssertNil(store.session); XCTAssertFalse(store.running); XCTAssertEqual(store.selected, ["fresh"])
        var changed = saved; changed[.referenceA]?[0] = "changed"
        try legacy.save(changed)
        store.differentScenes = true; store.start()
        XCTAssertFalse(store.running); XCTAssertTrue(store.message?.contains("見本が変わりました") == true)
    }

    @MainActor func testCandidateBoardRendersWithGeneratedImages() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = try makeReviewFixture()
        let view = ScrollView {
            CandidateReviewBoard(session: CandidateReviewSession(run: fixture), toggle: { _ in }, confirm: { _ in }, open: { _ in }, undo: {})
                .padding(20)
        }.background(Color.black).environment(\.colorScheme, .dark)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let renderer = UIGraphicsImageRenderer(size: window.bounds.size)
        let image = renderer.image { _ in XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)) }
        XCTAssertEqual(image.size.width, 390)
        let attachment = XCTAttachment(image: image); attachment.name = "candidate-review-generated-board"
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
