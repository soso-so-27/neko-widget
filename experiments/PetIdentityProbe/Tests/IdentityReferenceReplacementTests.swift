import XCTest
import SwiftUI
import UIKit
@testable import PetIdentityProbe

final class IdentityReferenceReplacementTests: XCTestCase {
    private var saved: [IdentityPhotoSlot: [String]] {
        [.referenceA: (0..<5).map { "a\($0)" }, .referenceB: (0..<5).map { "b\($0)" },
         .evaluationA: ["eval-a"], .evaluationB: ["eval-b"]]
    }
    private func failed(_ thumbnail: CGImage? = nil) -> IdentityUnusableReference {
        .init(slot: .referenceB, target: .init(index: 2, assetIdentifier: "b2"), thumbnail: thumbnail,
              originalIssue: .catNotDetected, recoveryStatus: .noCandidate)
    }
    private func run(_ reference: IdentityUnusableReference) throws -> IdentityRecoveryRun {
        .init(report: try IdentityRecoveryComparisonCore.report([]), unusableReferences: [reference])
    }

    func testOnlyCandidateFailedReferencesGetLocalPreviewsAndNeverEnterJSON() throws {
        let missing = IdentityRecoveryItem(slot: .referenceB, original: nil, candidate: nil,
            recoveryStatus: .noCandidate, originalIssue: .catNotDetected)
        var requested = 0
        let failed = try XCTUnwrap(IdentityUnusableReference.make(slot: .referenceB, index: 2,
            identifier: "private-photo-id", input: missing, thumbnail: { requested += 1; return nil }))
        XCTAssertEqual(requested, 1); XCTAssertNil(failed.thumbnail)
        XCTAssertEqual(failed.title, "猫B・見本3枚目")
        XCTAssertTrue(failed.reason.contains("検出できません"))
        let recovered = IdentityRecoveryItem(slot: .referenceA, original: nil, candidate: [1], recoveryStatus: .recovered)
        XCTAssertNil(IdentityUnusableReference.make(slot: .referenceA, index: 0, identifier: "a",
            input: recovered, thumbnail: { XCTFail("do not retain successful reference images"); return nil }))
        let evaluation = IdentityRecoveryItem(slot: .evaluationB, original: nil, candidate: nil, recoveryStatus: .noCandidate)
        XCTAssertNil(IdentityUnusableReference.make(slot: .evaluationB, index: 0, identifier: "eval",
            input: evaluation, thumbnail: { XCTFail("not a reference"); return nil }))
        XCTAssertNil(IdentityUnusableReference.make(slot: .referenceA, index: 0, identifier: "wrong-slot",
            input: missing, thumbnail: { XCTFail("mismatched slot"); return nil }))
        let aggregate = try IdentityRecoveryComparisonCore.report([missing])
        let local = IdentityRecoveryRun(report: aggregate, unusableReferences: [failed])
        XCTAssertEqual(local.report.json, aggregate.json)
        let json = try XCTUnwrap(local.report.json)
        for forbidden in ["private-photo-id", "thumbnail", "assetIdentifier", "unusableReferences", "target"] {
            XCTAssertFalse(json.contains(forbidden))
        }
        XCTAssertFalse(local.report.photosIncluded); XCTAssertFalse(local.report.identifiersIncluded)
    }

    @MainActor func testOneReplacementPreservesEveryOtherSelectionAndPersistsOnlyIDs() throws {
        let archive = IdentitySelectionArchive(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("ProbeReferenceReplacement-\(UUID().uuidString)/selection-v1.json"))
        defer { try? FileManager.default.removeItem(at: archive.url.deletingLastPathComponent()) }
        try archive.save(saved)
        let store = IdentityEvaluationStore(archive: archive)
        let reference = failed()
        store.recoveryResult = try run(reference)
        store.replaceReference(reference)
        let request = try XCTUnwrap(store.picker)
        XCTAssertTrue(request.singleSelection); XCTAssertFalse(request.firstInputOnly)
        XCTAssertTrue(store.pickerSelection(for: request).isEmpty)
        store.selected(["new-b-reference"], request: request)
        var expected = saved; expected[.referenceB]?[2] = "new-b-reference"
        XCTAssertEqual(store.selections, expected); XCTAssertEqual(try archive.load(), expected)
        XCTAssertNil(store.picker); XCTAssertNil(store.recoveryResult)
        XCTAssertFalse(store.running); XCTAssertTrue(store.message?.contains("再確認") == true)
        let reopened = IdentityEvaluationStore(archive: archive)
        XCTAssertEqual(reopened.selections, expected)
        let json = String(decoding: try Data(contentsOf: archive.url), as: UTF8.self)
        XCTAssertFalse(json.contains("thumbnail")); XCTAssertFalse(json.contains("recoveryStatus"))
    }

    @MainActor func testCancelInvalidDuplicateAndSamePhotoLeaveOriginalSelectionsAndPreview() throws {
        let attempts: [[String?]] = [[], [nil], [""], ["b1"], ["a0"], ["eval-b"], ["new", "another"], ["b2"]]
        for chosen in attempts {
            let store = IdentityEvaluationStore()
            store.selections = saved; store.recoveryResult = try run(failed())
            store.replaceReference(failed())
            let request = try XCTUnwrap(store.picker)
            store.selected(chosen, request: request)
            XCTAssertEqual(store.selections, saved)
            XCTAssertEqual(store.recoveryResult?.unusableReferences.first?.target, failed().target)
            XCTAssertNil(store.picker); XCTAssertFalse(store.running)
        }
    }

    @MainActor func testStaleAndBackgroundPickerCannotReplaceOrReviveReference() throws {
        let store = IdentityEvaluationStore()
        store.selections = saved; store.recoveryResult = try run(failed())
        store.replaceReference(failed())
        let old = try XCTUnwrap(store.picker)
        store.selections[.referenceB]?[2] = "changed"
        store.selected(["new"], request: old)
        XCTAssertEqual(store.selections[.referenceB]?[2], "changed")
        store.selections = saved; store.recoveryResult = try run(failed())
        store.replaceReference(failed())
        let beforeBackground = try XCTUnwrap(store.picker)
        store.suspend()
        store.selected(["late"], request: beforeBackground)
        XCTAssertEqual(store.selections, saved); XCTAssertNil(store.recoveryResult); XCTAssertNil(store.picker)
        store.replaceReference(failed()); XCTAssertNil(store.picker) // No current failed-reference result.
        store.recoveryResult = try run(failed()); store.replaceReference(failed())
        let newer = try XCTUnwrap(store.picker)
        store.selected(["late"], request: old)
        XCTAssertEqual(store.picker?.id, newer.id); XCTAssertEqual(store.selections, saved)
    }

    @MainActor func testFailedReferenceCardRendersWithGeneratedPhotoAndUnavailablePhoto() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: IdentityDetectorControlID.orange.rawValue, withExtension: "png"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        for (name, thumbnail) in [("generated-failed-reference-card", Optional(image)), ("unavailable-reference-card", nil)] {
            let view = IdentityUnusableReferenceView(reference: failed(thumbnail), enabled: true, replace: {})
                .padding(16).frame(width: 390).background(Color.black).environment(\.colorScheme, .dark)
            // ImageRenderer intermittently omits hosted text/buttons. Render an actual UIKit window.
            let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 480)
            window.overrideUserInterfaceStyle = .dark
            let host = UIHostingController(rootView: view)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil
                previousKeyWindow?.makeKey()
            }
            host.view.frame = window.bounds
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let format = UIGraphicsImageRendererFormat(); format.scale = 2
            let rendered = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            XCTAssertEqual(rendered.size.width, 390); XCTAssertGreaterThan(rendered.size.height, 250)
            // A successful render can still be all-black; verify visible card content too.
            let raster = try XCTUnwrap(rendered.cgImage)
            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 32, height: 32,
                    bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(raster, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).contains {
                pixels[$0] > 20 || pixels[$0 + 1] > 20 || pixels[$0 + 2] > 20
            }, "Card must not render blank: \(name)")
            XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).contains {
                pixels[$0 + 2] > 150 && Int(pixels[$0 + 2]) - Int(pixels[$0]) > 80
            }, "Replacement button must be visible, not just the generated photo: \(name)")
            let attachment = XCTAttachment(image: rendered)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
