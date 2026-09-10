import SwiftUI
import XCTest
@testable import PetIdentityProbe

@MainActor
final class CandidateProgressTests: XCTestCase {
    private var directory: URL!
    private var refs: IdentitySelectionArchive!
    private var archive: CandidateSelectionArchive!
    private var saved: [IdentityPhotoSlot: [String]] {
        [.referenceA: (0..<5).map { "a\($0)" }, .referenceB: (0..<5).map { "b\($0)" }]
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CandidateProgress-\(UUID())")
        refs = .init(url: directory.appendingPathComponent("refs.json"))
        archive = .init(url: directory.appendingPathComponent("candidate.json"))
        try refs.save(saved); try archive.save(["p0", "p1", "p2"])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func store(using replacement: CandidateSelectionArchive? = nil) throws -> CandidateReviewStore {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(ctx.makeImage())
        return CandidateReviewStore(referenceArchive: refs, candidateArchive: replacement ?? archive, runner: { _, ids in
            .init(photos: ids.indices.map {
                .init(id: $0, image: image, suggestion: $0 == 2 ? nil : .a, issue: $0 == 2 ? .noSingleCat : nil)
            }, referenceA: image, referenceB: image)
        })
    }
    private func start(_ store: CandidateReviewStore) async throws {
        store.start()
        for _ in 0..<100 where store.running { await Task.yield() }
        XCTAssertFalse(store.running)
        _ = try XCTUnwrap(store.session)
    }

    func testResumePreservesConfirmationsExclusionsAndUndoWithoutModelOutputs() async throws {
        let legacyBefore = try Data(contentsOf: refs.url)
        let first = try store(); try await start(first)
        first.toggleExcluded(1); first.confirmGroup(.a)
        XCTAssertEqual(first.session?.decisions, [0: .a])
        XCTAssertTrue(first.choose(.both, for: 2))
        first.suspend()
        XCTAssertNil(first.session); XCTAssertEqual(first.savedConfirmationCount, 2)
        let restored = try store(); XCTAssertEqual(restored.savedConfirmationCount, 2)
        try await start(restored)
        XCTAssertEqual(restored.session?.decisions, [0: .a, 2: .both])
        XCTAssertEqual(restored.session?.excluded, [1])
        XCTAssertEqual(restored.session?.report.previouslyConfirmed, 2)
        XCTAssertEqual(restored.session?.report.confirmedAsSuggested, 0)
        XCTAssertEqual(restored.session?.report.individuallyLabeledUnranked, 0)
        XCTAssertEqual(restored.session?.report.totalReviewActions, 0)
        restored.confirmGroup(.a) // The previously excluded candidate must not be re-included.
        XCTAssertNil(restored.session?.decisions[1])
        restored.undo()
        XCTAssertEqual(restored.session?.decisions, [0: .a])
        XCTAssertEqual(try archive.loadBatch().progress?.decisions, ["p0": .a])
        XCTAssertTrue(restored.unconfirm(0))
        XCTAssertTrue(try XCTUnwrap(restored.session).decisions.isEmpty)
        restored.undo(); XCTAssertEqual(restored.session?.decisions, [0: .a])
        XCTAssertEqual(try Data(contentsOf: refs.url), legacyBefore)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: archive.url)) as! [String: Any]
        XCTAssertEqual(raw["schema"] as? Int, 2)
        let progress = try XCTUnwrap(raw["progress"] as? [String: Any])
        XCTAssertEqual(Set(progress.keys), ["referenceFingerprint", "decisions", "excluded"])
        XCTAssertNil(progress["previousDecisions"])
        let json = try XCTUnwrap(restored.session?.report.json)
        for value in ["p0", "a0", "referenceFingerprint", "previousDecisions", "excluded"] {
            XCTAssertFalse(json.contains("\"\(value)\""))
        }
    }

    func testWriteFailureDoesNotPublishConfirmationOrUndoAndCanRetry() async throws {
        var fail = true
        let injected = CandidateSelectionArchive(url: archive.url, writeData: { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: IdentitySelectionArchive.writingOptions)
        })
        let subject = try store(using: injected); try await start(subject)
        let before = try Data(contentsOf: archive.url)
        XCTAssertFalse(subject.choose(.both, for: 2))
        XCTAssertTrue(try XCTUnwrap(subject.session).decisions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: archive.url), before)
        XCTAssertNotNil(subject.storageWarning)
        fail = false
        XCTAssertTrue(subject.choose(.both, for: 2))
        let confirmed = try Data(contentsOf: archive.url)
        fail = true; subject.undo()
        XCTAssertEqual(subject.session?.decisions, [2: .both])
        XCTAssertEqual(try Data(contentsOf: archive.url), confirmed)
        fail = false; subject.undo()
        XCTAssertTrue(try XCTUnwrap(subject.session).decisions.isEmpty)
    }

    func testChangedOrSwappedReferencesBlockUntilExplicitResetAndDoNotRewrite() async throws {
        let first = try store(); try await start(first); first.choose(.a, for: 0); first.suspend()
        let before = try Data(contentsOf: archive.url)
        var changed = saved
        changed[.referenceA] = saved[.referenceB]; changed[.referenceB] = saved[.referenceA]
        try refs.save(changed)
        let blocked = try store()
        XCTAssertTrue(blocked.requiresProgressReset); XCTAssertFalse(blocked.canRun)
        XCTAssertFalse(blocked.canChoose)
        XCTAssertEqual(try Data(contentsOf: archive.url), before)
        blocked.resetProgressForChangedReferences()
        XCTAssertFalse(blocked.requiresProgressReset); XCTAssertTrue(blocked.canRun)
        XCTAssertEqual(try archive.load(), ["p0", "p1", "p2"])
        XCTAssertNil(try archive.loadBatch().progress)
    }

    func testNewSelectionRequiresConfirmationAndCancellationKeepsProgress() async throws {
        let subject = try store(); try await start(subject); subject.choose(.a, for: 0); subject.suspend()
        let before = try Data(contentsOf: archive.url)
        let request = CandidatePickerRequest(); subject.picker = request
        subject.picked(["new"], request: request)
        XCTAssertEqual(subject.pendingSelection, ["new"])
        XCTAssertEqual(subject.selected, ["p0", "p1", "p2"])
        XCTAssertEqual(try Data(contentsOf: archive.url), before)
        subject.pendingSelection = nil // Cancel the explicit replacement dialog.
        XCTAssertEqual(try Data(contentsOf: archive.url), before)
        let again = CandidatePickerRequest(); subject.picker = again
        subject.picked(["new"], request: again); subject.confirmPendingSelection()
        XCTAssertEqual(try archive.load(), ["new"])
        XCTAssertNil(try archive.loadBatch().progress); XCTAssertEqual(subject.savedConfirmationCount, 0)
        subject.suspend(); subject.confirmPendingSelection()
        XCTAssertEqual(try archive.load(), ["new"])
    }

    func testStaleStoreAndChangedReferenceCannotOverwriteHumanProgress() async throws {
        let first = try store(), stale = try store()
        try await start(first); try await start(stale)
        XCTAssertTrue(first.choose(.a, for: 0))
        let before = try Data(contentsOf: archive.url)
        XCTAssertFalse(stale.choose(.b, for: 1))
        XCTAssertEqual(try Data(contentsOf: archive.url), before)
        stale.suspend(); stale.clearCandidateSelection()
        XCTAssertEqual(try Data(contentsOf: archive.url), before)
        var changed = saved; changed[.referenceA]?[0] = "changed"
        try refs.save(changed)
        XCTAssertFalse(first.choose(.b, for: 1))
        XCTAssertEqual(try Data(contentsOf: archive.url), before)
    }

    func testIDMappingIsNotTheArrayPositionAndRestoredCountsPartitionPhotos() throws {
        let progress = CandidateSavedProgress(referenceFingerprint: try CandidateSavedProgress.fingerprint(saved),
            decisions: ["p2": .both], previousDecisions: [:], excluded: ["p0"])
        let run = CandidateReviewRun(photos: (0..<3).map { .init(id: $0, image: nil, suggestion: nil, issue: .unavailable) },
                                     referenceA: nil, referenceB: nil)
        let session = CandidateReviewSession(run: run, progress: progress, identifiers: ["p2", "p1", "p0"])
        XCTAssertEqual(session.decisions, [0: .both]); XCTAssertEqual(session.excluded, [2])
        let r = session.report
        XCTAssertEqual(r.previouslyConfirmed, 1); XCTAssertEqual(r.remaining, 2)
        XCTAssertEqual(r.previouslyConfirmed + r.confirmedAsSuggested + r.changedSuggestion + r.individuallyLabeledUnranked + r.unsure + r.remaining, r.selected)
    }

    func testOldSelectionMigrationAndInvalidProgressFailClosed() throws {
        let old = Data("{\"schema\":1,\"identifiers\":[\"p0\"]}".utf8)
        try old.write(to: archive.url)
        XCTAssertEqual(try archive.load(), ["p0"])
        XCTAssertNil(try archive.loadBatch().progress)
        XCTAssertEqual(try Data(contentsOf: archive.url), old)
        let invalid = CandidateSavedProgress(referenceFingerprint: try CandidateSavedProgress.fingerprint(saved),
            decisions: ["not-selected": .a], previousDecisions: nil, excluded: [])
        XCTAssertThrowsError(try archive.saveBatch(.init(identifiers: ["p0"], progress: invalid)))
        XCTAssertEqual(try Data(contentsOf: archive.url), old)
        try Data("{\"schema\":2,\"identifiers\":[\"p0\"],\"progress\":{\"referenceFingerprint\":\"bad\",\"decisions\":{},\"excluded\":[]}}".utf8).write(to: archive.url)
        let corrupt = try store()
        XCTAssertTrue(corrupt.candidateReadFailed); XCTAssertFalse(corrupt.canRun)
        try archive.save(["newer-selection"])
        corrupt.clearCandidateSelection()
        XCTAssertEqual(try archive.load(), ["newer-selection"])
    }

    func testResumeSetupRendersLimitsAndSavedStatusAtBothWidths() async throws {
        let first = try store(); try await start(first); first.choose(.a, for: 0); first.suspend()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        for width in [320.0, 390.0] {
            let restored = try store()
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            let host = UIHostingController(rootView: NavigationStack {
                CandidateReviewView(store: restored)
            }.environment(\.colorScheme, .dark))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "candidate-resume-setup-\(Int(width))"
            attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(restored.savedConfirmationCount, 1)
        }
    }
}
