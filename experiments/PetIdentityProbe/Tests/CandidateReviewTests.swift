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
            .init(id: 3, image: raster, suggestion: nil, issue: .noSingleCat,
                  cropDiagnostic: .init(originalIssue: .multipleCats, recoveryStatus: .originalIneligible)),
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

    func testKnownPhotosAreFilteredWithoutDiscardingTheOtherPicks() throws {
        let eligible = try CandidateReviewSelection.filteringKnownPhotos(["new2", "a0", "old-eval", "new1", "b3"], saved: saved)
        XCTAssertEqual(eligible, ["new2", "new1"])
        try CandidateReviewSelection.validate(eligible, saved: saved)
        XCTAssertEqual(try CandidateReviewSelection.filteringKnownPhotos(["a0", "old-eval"], saved: saved), [])
        // Filtering does not bypass malformed input or missing-reference checks.
        for ids in [["a0", "a0", "new"], ["", "new"], (0..<25).map { "p\($0)" }] {
            XCTAssertThrowsError(try CandidateReviewSelection.filteringKnownPhotos(ids, saved: saved))
        }
        XCTAssertThrowsError(try CandidateReviewSelection.filteringKnownPhotos(["new"], saved: [:]))
    }

    func testCropReasonsDistinguishExistingDetectionAndProcessingOutcomes() {
        let examples: [(IdentityInputIssue?, IdentityRecoveryStatus, String)] = [
            (.catNotDetected, .noCandidate, "追加検出でも猫が見つかりません"),
            (.multipleCats, .originalIneligible, "検出範囲が複数あります"),
            (.catNotDetected, .multipleCandidates, "検出範囲が複数あります"),
            (.invalidCrop, .originalIneligible, IdentityInputIssue.invalidCrop.title),
            (.catNotDetected, .invalidCrop, "検出した範囲を切り抜けません"),
            (.detectionFailed, .originalIneligible, IdentityInputIssue.detectionFailed.title),
            (.catNotDetected, .detectionFailed, "追加の検出処理でエラー"),
            (.catNotDetected, .conversionFailed, "検出用の画像を作れません"),
            (.catNotDetected, .resultsUnavailable, "追加の検出結果がありません"),
            (.catNotDetected, .originalIneligible, IdentityInputIssue.catNotDetected.title),
            (nil, .originalIneligible, "検出の詳細を確認できません")
        ]
        for (original, recovery, title) in examples {
            let diagnostic = CandidateCropDiagnostic(originalIssue: original, recoveryStatus: recovery)
            let photo = CandidateReviewPhoto(id: 0, image: nil, suggestion: nil, issue: .noSingleCat, cropDiagnostic: diagnostic)
            XCTAssertEqual(photo.issueTitle, title)
            XCTAssertFalse(title.contains("複数匹")) // Multiple boxes do not prove multiple animals.
        }
        let unrelated = CandidateReviewPhoto(id: 0, image: nil, suggestion: nil, issue: .similarPhoto,
            cropDiagnostic: .init(originalIssue: .catNotDetected, recoveryStatus: .noCandidate))
        XCTAssertEqual(unrelated.issueTitle, CandidateReviewIssue.similarPhoto.title)
        let missing = CandidateReviewPhoto(id: 1, image: nil, suggestion: nil, issue: .noSingleCat)
        XCTAssertEqual(missing.issueTitle, CandidateReviewIssue.noSingleCat.title)
    }

    func testCropBreakdownPartitionsFailuresAndIsShareableWithoutReclassifying() throws {
        let raster = try image()
        let missed = CandidateCropDiagnostic(originalIssue: .catNotDetected, recoveryStatus: .noCandidate)
        let photos: [CandidateReviewPhoto] = [
            .init(id: 0, image: raster, suggestion: nil, issue: .noSingleCat, cropDiagnostic: missed),
            .init(id: 1, image: raster, suggestion: nil, issue: .noSingleCat, cropDiagnostic: missed),
            .init(id: 2, image: raster, suggestion: nil, issue: .noSingleCat,
                  cropDiagnostic: .init(originalIssue: .multipleCats, recoveryStatus: .originalIneligible)),
            .init(id: 3, image: raster, suggestion: nil, issue: .noSingleCat,
                  cropDiagnostic: .init(originalIssue: .catNotDetected, recoveryStatus: .multipleCandidates)),
            .init(id: 4, image: raster, suggestion: nil, issue: .noSingleCat,
                  cropDiagnostic: .init(originalIssue: .catNotDetected, recoveryStatus: .invalidCrop)),
            .init(id: 5, image: raster, suggestion: nil, issue: .noSingleCat),
            .init(id: 6, image: raster, suggestion: .a, issue: nil),
            .init(id: 7, image: nil, suggestion: nil, issue: .unavailable, cropDiagnostic: missed)
        ]
        var session = CandidateReviewSession(run: .init(photos: photos, referenceA: nil, referenceB: nil))
        let report = session.report
        XCTAssertTrue(session.decisions.isEmpty); XCTAssertNotNil(report.json)
        XCTAssertEqual(report.selected, 8); XCTAssertEqual(report.remaining, 8); XCTAssertEqual(report.proposed, 1)
        XCTAssertEqual(report.inputIssues["noSingleCat"], 6)
        XCTAssertEqual(report.noSingleCatBreakdown.reduce(0) { $0 + $1.count }, 6)
        XCTAssertEqual(report.noSingleCatBreakdown.count, 5)
        XCTAssertEqual(report.noSingleCatBreakdown.first { $0.originalIssue == "catNotDetected" && $0.recoveryStatus == "noCandidate" }?.count, 2)
        XCTAssertEqual(report.noSingleCatBreakdown.first { $0.originalIssue == "unrecorded" && $0.recoveryStatus == "unrecorded" }?.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(report.json).utf8)) as? [String: Any])
        let rows = try XCTUnwrap(object["noSingleCatBreakdown"] as? [[String: Any]])
        for row in rows { XCTAssertEqual(Set(row.keys), ["originalIssue", "recoveryStatus", "count"]) }
        XCTAssertTrue(report.noSingleCatBreakdownScope.contains("not-confirmed-cat-count"))
        XCTAssertFalse(report.accuracyEvaluated); XCTAssertFalse(report.productionDataChanged)
        session.choose(.a, for: 0)
        XCTAssertEqual(session.report.noSingleCatBreakdown.map(\.count), report.noSingleCatBreakdown.map(\.count))
    }

    func testExportIsAggregateOnlyAndNeverCallsUserConfirmationAccuracy() throws {
        var session = CandidateReviewSession(run: try makeReviewFixture())
        session.confirmGroup(.a)
        let json = try XCTUnwrap(session.report.json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["protocolIdentifier", "appBuild", "modelSHA256", "method", "scope", "selected", "proposed",
            "confirmedAsSuggested", "changedSuggestion", "individuallyLabeledUnranked", "unsure", "remaining", "inputIssues", "noSingleCatBreakdown", "noSingleCatBreakdownScope", "multiRegionReview", "reviewActions",
            "totalReviewActions", "hypotheticalManualLabelTaps", "manualComparison", "photosIncluded", "identifiersIncluded", "embeddingsIncluded",
            "individualPredictionsIncluded", "productionDataChanged", "accuracyEvaluated", "productValidated", "previouslyConfirmed", "progressScope", "distanceFiltering", "qualityComparison", "objectComparison"])
        XCTAssertFalse(session.report.accuracyEvaluated); XCTAssertFalse(session.report.productValidated)
        XCTAssertEqual(session.report.protocolIdentifier, "pet-candidate-confirmation-usability-v9")
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
        XCTAssertTrue(store.canRun) // No memory/scene attestation is required.
        let attempts: [[String?]] = [[], [nil], ["a0"], ["old-eval"], ["x", "x"]]
        for ids in attempts {
            let request = CandidatePickerRequest(); store.picker = request
            store.picked(ids, request: request)
            XCTAssertEqual(store.selected, ["fresh"])
        }
        let request = CandidatePickerRequest(); store.picker = request
        store.picked(["a0", "new1", "old-eval", "new2"], request: request)
        XCTAssertTrue(store.canRun); XCTAssertEqual(try archive.load(), ["new1", "new2"])
        XCTAssertTrue(store.message?.contains("重なる2枚を自動で外しました") == true)
        XCTAssertTrue(store.message?.contains("残りの2枚で進められます") == true)
        let reused = CandidatePickerRequest(); store.picker = reused
        store.picked(["b0", "old-eval"], request: reused)
        XCTAssertEqual(store.selected, ["new1", "new2"])
        XCTAssertEqual(try archive.load(), ["new1", "new2"])
        XCTAssertTrue(store.message?.contains("元の2枚は残しています") == true)
        let stale = CandidatePickerRequest(); store.picker = stale
        store.suspend(); store.picked(["late"], request: stale)
        XCTAssertNil(store.session); XCTAssertNil(store.picker); XCTAssertEqual(store.selected, ["new1", "new2"])
        XCTAssertTrue(store.canRun)
        store.clearCandidateSelection()
        XCTAssertTrue(try archive.load().isEmpty); XCTAssertEqual(try legacy.load(), saved)
        let allKnown = CandidatePickerRequest(); store.picker = allKnown
        store.picked(["a0", "old-eval"], request: allKnown)
        XCTAssertTrue(store.selected.isEmpty); XCTAssertFalse(store.canRun)
        XCTAssertTrue(store.message?.contains("ほかの写真を追加できます") == true)
        try Data("broken".utf8).write(to: archive.url)
        let corrupt = CandidateReviewStore(referenceArchive: legacy, candidateArchive: archive)
        XCTAssertTrue(corrupt.candidateReadFailed); XCTAssertFalse(corrupt.canChoose)
        corrupt.clearCandidateSelection()
        XCTAssertFalse(corrupt.candidateReadFailed); XCTAssertTrue(corrupt.canChoose)
        XCTAssertEqual(try legacy.load(), saved)
    }

    @MainActor func testRestoringSelectionExcludesKnownPhotosWithoutRewritingArchives() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CandidateRestoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = IdentitySelectionArchive(url: directory.appendingPathComponent("legacy.json"))
        let archive = CandidateSelectionArchive(url: directory.appendingPathComponent("candidate.json"))
        try legacy.save(saved); let legacyBefore = try Data(contentsOf: legacy.url)
        for ids in [["a0", "fresh", "old-eval"], ["a0", "old-eval"]] {
            try archive.save(ids); let candidateBefore = try Data(contentsOf: archive.url)
            let store = CandidateReviewStore(referenceArchive: legacy, candidateArchive: archive)
            let expected = ids.filter { $0 == "fresh" }
            XCTAssertEqual(store.selected, expected)
            XCTAssertEqual(store.canRun, !expected.isEmpty)
            XCTAssertTrue(store.message?.contains("重なる2枚を自動で外しました") == true)
            XCTAssertEqual(try Data(contentsOf: archive.url), candidateBefore)
            XCTAssertEqual(try Data(contentsOf: legacy.url), legacyBefore)
            XCTAssertTrue(store.hasArchivedSelection) // Keep clear available even when every photo was filtered.
            store.clearCandidateSelection()
            XCTAssertFalse(store.hasArchivedSelection); XCTAssertTrue(try archive.load().isEmpty)
            XCTAssertEqual(try Data(contentsOf: legacy.url), legacyBefore)
        }
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
        store.start()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(store.running)
        store.suspend()
        finish?.resume(returning: try makeReviewFixture())
        await Task.yield(); await Task.yield()
        XCTAssertNil(store.session); XCTAssertFalse(store.running); XCTAssertEqual(store.selected, ["fresh"])
        var changed = saved; changed[.referenceA]?[0] = "changed"
        try legacy.save(changed)
        store.start()
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
