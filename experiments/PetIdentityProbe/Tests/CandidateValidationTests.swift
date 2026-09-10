import CoreGraphics
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import PetIdentityProbe

// Deterministic storage/state tests: no PhotoKit access, Vision or ONNX inference.
@MainActor
final class CandidateValidationTests: XCTestCase {
    private typealias Metadata = ([String]) async throws -> String
    private typealias ImageLoader = (String) async throws -> CGImage?
    private typealias Runner = ([IdentityPhotoSlot: [String]], [String], [String]) async throws -> CandidateReviewRun
    private var directory: URL!
    private var references: IdentitySelectionArchive!
    private var development: CandidateSelectionArchive!
    private var archive: CandidateValidationArchive!
    private var image: CGImage!
    private var saved: [IdentityPhotoSlot: [String]] {
        [.referenceA: (0..<5).map { "reference-a-\($0)" },
         .referenceB: (0..<5).map { "reference-b-\($0)" },
         .evaluationA: ["prior-evaluation-a"], .evaluationB: ["prior-evaluation-b"]]
    }
    private var developmentIDs: [String] { (0..<21).map { "development-private-\($0)" } }
    private var known: [String] { Set(saved.values.flatMap { $0 } + developmentIDs).sorted() }
    // Deliberately not numeric or lexicographic order: labels follow IDs, not local chunk indices.
    private var freshIDs: [String] { (0..<60).reversed().map { "study-private-\($0)" } }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CandidateValidation-\(UUID())")
        references = .init(url: directory.appendingPathComponent("references.json"))
        development = .init(url: directory.appendingPathComponent("development.json"))
        archive = .init(url: directory.appendingPathComponent("validation.json"))
        try references.save(saved)
        let progress = CandidateSavedProgress(referenceFingerprint: try CandidateSavedProgress.fingerprint(saved),
            decisions: [developmentIDs[0]: .a, developmentIDs[1]: .both],
            previousDecisions: [developmentIDs[0]: .a], excluded: [developmentIDs[2]])
        try development.saveBatch(.init(identifiers: developmentIDs, progress: progress))
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        image = try XCTUnwrap(context.makeImage())
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private static func metadataDigest(_ ids: [String]) -> String {
        CandidateValidationStudy.digest(Data(ids.sorted().joined(separator: "\n").utf8))
    }

    private func fixture(count: Int = 60, labeled: Bool = true, knownIDs: [String]? = nil) throws -> CandidateValidationStudy {
        let ids = Array(freshIDs.prefix(count)), existing = knownIDs ?? known
        var value = CandidateValidationStudy(method: CandidateValidationStudy.protocolKey,
            identityModel: ProbeModelFile.sha256, objectModel: CandidateObjectDetector.modelSHA256,
            runtime: IdentityEvaluationCore.expectedRuntimeVersion,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            referenceFingerprint: try CandidateValidationStudy.fingerprint(saved), knownIdentifiers: existing,
            assetStateFingerprint: Self.metadataDigest(existing + ids))
        for start in stride(from: 0, to: ids.count, by: 24) {
            try value.append(Array(ids[start..<min(start + 24, ids.count)]),
                assetFingerprint: Self.metadataDigest(existing + Array(ids.prefix(min(start + 24, ids.count)))))
        }
        if labeled {
            for (index, id) in ids.enumerated() {
                try value.choose(index < 20 ? .a : index < 40 ? .b : index < 50 ? .both : .other, id: id)
            }
        }
        return value
    }

    private func store(using replacement: CandidateValidationArchive? = nil, metadata: Metadata? = nil,
                       imageLoader: ImageLoader? = nil, runner: Runner? = nil) -> CandidateValidationStore {
        let thumbnail = image!
        return CandidateValidationStore(references: references, development: development,
            archive: replacement ?? archive, metadata: metadata ?? { Self.metadataDigest($0) },
            imageLoader: imageLoader ?? { _ in thumbnail }, runner: runner ?? { _, ids, _ in
                .init(photos: ids.indices.map { .init(id: $0, image: thumbnail, suggestion: nil, issue: .noSingleCat) },
                    referenceA: thumbnail, referenceB: thumbnail)
            })
    }

    private func finish(_ subject: CandidateValidationStore, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if !subject.running { return }
            await Task.yield()
        }
        XCTAssertFalse(subject.running, "Injected operation did not finish", file: file, line: line)
    }

    private func pick(_ ids: [String?], in subject: CandidateValidationStore) async {
        let request = CandidatePickerRequest(); subject.picker = request
        subject.picked(ids, request: request)
        await finish(subject)
    }

    private func photos(_ ids: [String]) -> [CandidateReviewPhoto] {
        ids.indices.map { .init(id: $0, image: image, suggestion: nil, issue: .noSingleCat) }
    }

    func testArchiveBoundsInvalidPayloadsAndSealedMutations() throws {
        XCTAssertNil(try archive.load())
        var complete = try fixture()
        XCTAssertEqual(complete.identifiers.count, 60); XCTAssertTrue(complete.compositionReady)
        XCTAssertTrue(complete.canSeal); XCTAssertTrue(complete.pending.isEmpty)
        try complete.seal()
        let sealed = complete
        XCTAssertThrowsError(try complete.choose(.other, id: freshIDs[0]))
        XCTAssertThrowsError(try complete.append(["another"], assetFingerprint: complete.assetStateFingerprint))
        XCTAssertThrowsError(try complete.seal())
        XCTAssertEqual(complete, sealed)
        try archive.save(complete)
        XCTAssertEqual(try archive.load(), complete)
        let before = try Data(contentsOf: archive.url)
        var invalid: [CandidateValidationStudy] = []
        var value = complete; value.schema = 2; invalid.append(value)
        value = complete; value.identifiers += ["overflow"]; invalid.append(value)
        value = complete; value.identifiers[1] = value.identifiers[0]; invalid.append(value)
        value = complete; value.identifiers[0] = ""; invalid.append(value)
        value = complete; value.identifiers[0] = String(repeating: "x", count: 4097); invalid.append(value)
        value = complete; value.decisions["not-selected"] = .a; invalid.append(value)
        value = complete; value.decisions.removeValue(forKey: freshIDs[0]); invalid.append(value)
        value = complete; value.assetStateFingerprint = "not-a-digest"; invalid.append(value)
        value = try fixture(count: 1); value.sealed = true; invalid.append(value)
        value = try fixture(count: 0); value.identifiers = [known[0]]; invalid.append(value)
        let tooManyKnown = (0..<65).map { "known-\($0)" }
        invalid.append(try fixture(count: 0, knownIDs: tooManyKnown))
        for (index, candidate) in invalid.enumerated() {
            XCTAssertThrowsError(try archive.save(candidate), "Invalid payload \(index)")
            XCTAssertEqual(try Data(contentsOf: archive.url), before)
        }
        var draft = try fixture(count: 0)
        XCTAssertThrowsError(try draft.append(Array(freshIDs.prefix(25)), assetFingerprint: draft.assetStateFingerprint))
        XCTAssertThrowsError(try draft.append([known[0]], assetFingerprint: draft.assetStateFingerprint))
        XCTAssertThrowsError(try draft.seal())
        XCTAssertNoThrow(try fixture(count: 0, knownIDs: Array(tooManyKnown.prefix(64))).validate())
        try JSONEncoder().encode(invalid[0]).write(to: archive.url)
        XCTAssertThrowsError(try archive.load())
        try Data(repeating: 0, count: 1_048_577).write(to: archive.url)
        XCTAssertThrowsError(try archive.load())
    }

    func testPickerExcludesKnownAndCurrentIDsAndPreservesInvalidCancelAndStaleResults() async throws {
        var calls = 0
        let subject = store(runner: { _, ids, _ in
            calls += 1; return .init(photos: self.photos(ids), referenceA: nil, referenceB: nil)
        })
        await pick(["reference-a-0", "reference-b-0", "prior-evaluation-a", developmentIDs[0], "p0", "p1"], in: subject)
        XCTAssertEqual(subject.study?.identifiers, ["p0", "p1"])
        await pick(["p0", "p2"], in: subject)
        XCTAssertEqual(subject.study?.identifiers, ["p0", "p1", "p2"])
        let before = try Data(contentsOf: archive.url)
        let rejected: [[String?]] = [[], [nil], [""], ["p3", "p3"], [String(repeating: "x", count: 4097)],
            Array(freshIDs.prefix(25)).map { Optional($0) }, ["p0", "prior-evaluation-b", developmentIDs[1]]]
        for values in rejected {
            await pick(values, in: subject)
            XCTAssertEqual(try Data(contentsOf: archive.url), before)
        }
        let active = CandidatePickerRequest(); subject.picker = active
        subject.picked(["late"], request: CandidatePickerRequest())
        XCTAssertEqual(subject.picker?.id, active.id)
        subject.suspend(); subject.picked(["late"], request: active)
        XCTAssertEqual(try Data(contentsOf: archive.url), before)
        XCTAssertEqual(calls, 0); XCTAssertNil(subject.report)
    }

    func testBlindLabelsResumeAndRemovalPreserveBothLegacyArchivesByteForByte() async throws {
        let refsBefore = try Data(contentsOf: references.url), devBefore = try Data(contentsOf: development.url)
        var calls = 0
        let loader: ImageLoader = { id in id == "p1" ? nil : self.image }
        let run: Runner = { _, ids, _ in
            calls += 1; return .init(photos: self.photos(ids), referenceA: nil, referenceB: nil)
        }
        let subject = store(imageLoader: loader, runner: run)
        await pick(["p0", "p1"], in: subject)
        subject.openPhoto(0); await finish(subject)
        XCTAssertTrue(subject.focusLoaded); XCTAssertNotNil(subject.focusImage)
        XCTAssertNotNil(subject.referenceA); XCTAssertNotNil(subject.referenceB)
        subject.choose(.a); await finish(subject)
        XCTAssertEqual(subject.study?.decisions, ["p0": .a])
        subject.suspend()
        let restored = store(imageLoader: loader, runner: run)
        XCTAssertEqual(restored.confirmed, 1)
        restored.openPhoto(); await finish(restored)
        XCTAssertEqual(restored.focusIndex, 1); XCTAssertTrue(restored.focusLoaded); XCTAssertNil(restored.focusImage)
        restored.choose(.b); await finish(restored)
        XCTAssertNil(restored.study?.decisions["p1"])
        restored.choose(.unsure); await finish(restored)
        XCTAssertEqual(restored.study?.decisions, ["p0": .a, "p1": .unsure])
        restored.openPhoto(0); await finish(restored)
        restored.choose(.b); await finish(restored)
        restored.remove(1); await finish(restored)
        XCTAssertEqual(try archive.load()?.identifiers, ["p0"])
        XCTAssertEqual(try archive.load()?.decisions, ["p0": .b])
        XCTAssertEqual(try Data(contentsOf: references.url), refsBefore)
        XCTAssertEqual(try Data(contentsOf: development.url), devBefore)
        XCTAssertEqual(calls, 0); XCTAssertNil(restored.report)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archive.url)) as? [String: Any])
        XCTAssertEqual(Set(raw.keys), ["schema", "method", "identityModel", "objectModel", "runtime", "osVersion",
            "referenceFingerprint", "knownIdentifiers", "identifiers", "decisions", "assetStateFingerprint", "sealed"])
        XCTAssertTrue(CandidateValidationStudy.isDigest(try XCTUnwrap(raw["assetStateFingerprint"] as? String)))
    }

    func testAtomicWriteFailureDoesNotPublishSelectionChoiceOrSealAndNeverStartsInference() async throws {
        var fail = true, calls = 0
        let failing = CandidateValidationArchive(url: archive.url, writeData: { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: IdentitySelectionArchive.writingOptions)
        })
        let run: Runner = { _, ids, _ in
            calls += 1; return .init(photos: self.photos(ids), referenceA: nil, referenceB: nil)
        }
        let subject = store(using: failing, runner: run)
        await pick(["p0"], in: subject)
        XCTAssertNil(subject.study); XCTAssertNil(try archive.load()); XCTAssertNotNil(subject.message)
        fail = false; await pick(["p0"], in: subject)
        subject.openPhoto(0); await finish(subject)
        let beforeChoice = try Data(contentsOf: archive.url)
        fail = true; subject.choose(.a); await finish(subject)
        XCTAssertEqual(subject.confirmed, 0); XCTAssertEqual(subject.focusIndex, 0)
        XCTAssertEqual(try Data(contentsOf: archive.url), beforeChoice)
        fail = false; subject.choose(.a); await finish(subject)
        XCTAssertEqual(subject.study?.decisions, ["p0": .a])
        try archive.save(fixture())
        let complete = store(using: failing, runner: run), beforeSeal = try Data(contentsOf: archive.url)
        fail = true; complete.compare(); await finish(complete)
        XCTAssertFalse(complete.isSealed); XCTAssertNil(complete.report); XCTAssertEqual(calls, 0)
        XCTAssertEqual(try Data(contentsOf: archive.url), beforeSeal)
    }

    func testStaleStudyReferencesDevelopmentAndMetadataCannotSealOrInfer() async throws {
        let refsBefore = try Data(contentsOf: references.url), devBefore = try Data(contentsOf: development.url)
        for change in ["study", "references", "development", "metadata"] {
            try refsBefore.write(to: references.url); try devBefore.write(to: development.url)
            try archive.save(fixture())
            var metadataChanged = false, calls = 0
            let subject = store(metadata: { ids in
                Self.metadataDigest(ids + (metadataChanged ? ["edited-after-selection"] : []))
            }, runner: { _, ids, _ in
                calls += 1; return .init(photos: self.photos(ids), referenceA: nil, referenceB: nil)
            })
            switch change {
            case "study":
                var newer = try XCTUnwrap(archive.load()); try newer.choose(.both, id: freshIDs[0]); try archive.save(newer)
            case "references":
                var swapped = saved; swapped[.referenceA] = saved[.referenceB]; swapped[.referenceB] = saved[.referenceA]
                try references.save(swapped)
            case "development": try development.save(["different-development-selection"])
            default: metadataChanged = true
            }
            let before = try Data(contentsOf: archive.url)
            subject.compare(); await finish(subject)
            XCTAssertEqual(calls, 0, change); XCTAssertNil(subject.report, change)
            XCTAssertFalse(subject.isSealed, change); XCTAssertNotNil(subject.message, change)
            XCTAssertEqual(try Data(contentsOf: archive.url), before, change)
        }
    }

    func testLoadFailuresAndChangedFrozenMethodBlockWithoutReplacingData() throws {
        let refsBefore = try Data(contentsOf: references.url), devBefore = try Data(contentsOf: development.url)
        try archive.save(fixture())
        let studyBefore = try Data(contentsOf: archive.url)
        for url in [references.url, development.url, archive.url] {
            try Data("not-json".utf8).write(to: url)
            let subject = store()
            XCTAssertTrue(subject.blocked); XCTAssertFalse(subject.canAdd); XCTAssertFalse(subject.canCompare)
            XCTAssertEqual(try Data(contentsOf: url), Data("not-json".utf8))
            try refsBefore.write(to: references.url); try devBefore.write(to: development.url)
            try studyBefore.write(to: archive.url)
        }
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: studyBefore) as? [String: Any])
        raw["method"] = "a-different-candidate-method"
        let changed = try JSONSerialization.data(withJSONObject: raw)
        try changed.write(to: archive.url)
        XCTAssertTrue(store().blocked)
        XCTAssertEqual(try Data(contentsOf: archive.url), changed)
        XCTAssertEqual(try Data(contentsOf: references.url), refsBefore)
        XCTAssertEqual(try Data(contentsOf: development.url), devBefore)
    }

    func testCancelledMetadataPreventsBothFirstSaveAndSealOrInference() async throws {
        for complete in [false, true] {
            if complete { try archive.save(fixture()) }
            let before = try archive.load()
            var continuation: CheckedContinuation<String, Never>?, calls = 0
            let entered = expectation(description: "metadata suspended \(complete)")
            let returned = expectation(description: "metadata returned \(complete)")
            var requestedIDs: [String] = []
            let subject = store(metadata: { ids in
                requestedIDs = ids
                let value = await withCheckedContinuation { continuation = $0; entered.fulfill() }
                returned.fulfill(); return value
            }, runner: { _, ids, _ in
                calls += 1; return .init(photos: self.photos(ids), referenceA: nil, referenceB: nil)
            })
            if complete { subject.compare() }
            else {
                let request = CandidatePickerRequest(); subject.picker = request
                subject.picked(["p0"], request: request)
            }
            await fulfillment(of: [entered], timeout: 2)
            subject.suspend()
            continuation?.resume(returning: Self.metadataDigest(requestedIDs)); continuation = nil
            await fulfillment(of: [returned], timeout: 2)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(try archive.load(), before)
            XCTAssertFalse(subject.isSealed); XCTAssertFalse(subject.running)
            XCTAssertNil(subject.report); XCTAssertEqual(calls, 0)
        }
    }

    func testSealedSixtyPhotosUse24Then24Then12AndOnlyKnownPlusEarlierDuplicateIDs() async throws {
        let original = try fixture(); try archive.save(original)
        let refsBefore = try Data(contentsOf: references.url), devBefore = try Data(contentsOf: development.url)
        var batches: [[String]] = [], contexts: [[String]] = []
        let subject = store(runner: { refs, ids, duplicates in
            XCTAssertEqual(refs, self.saved)
            XCTAssertTrue(try XCTUnwrap(self.archive.load()).sealed)
            batches.append(ids); contexts.append(duplicates)
            let values = ids.enumerated().map { local, id -> CandidateReviewPhoto in
                let index = original.identifiers.firstIndex(of: id)!
                let suggestion: CandidateReviewChoice? = index < 20 ? .a : index < 40 ? .b : nil
                return .init(id: local, image: self.image, suggestion: suggestion, issue: suggestion == nil ? .noSingleCat : nil)
            }
            return .init(photos: values, referenceA: self.image, referenceB: self.image, duplicateSourcesUnavailable: batches.count - 1)
        })
        subject.compare(); await finish(subject)
        XCTAssertEqual(batches.map(\.count), [24, 24, 12])
        XCTAssertEqual(batches.flatMap { $0 }, original.identifiers)
        for (batch, start) in [0, 24, 48].enumerated() {
            XCTAssertEqual(contexts[batch], Set(known + Array(original.identifiers.prefix(start))).sorted())
            XCTAssertTrue(Set(contexts[batch]).isDisjoint(with: Set(original.identifiers.dropFirst(start))))
        }
        let report = try XCTUnwrap(subject.report)
        XCTAssertEqual(report.counts, [[20, 0, 0, 0, 0, 0], [0, 20, 0, 0, 0, 0], [0, 0, 10, 10, 0, 0]])
        XCTAssertEqual(report.selected, 60); XCTAssertEqual(report.proposed, 40); XCTAssertEqual(report.matchingProposals, 40)
        XCTAssertTrue(report.compositionReady); XCTAssertEqual(report.duplicateSourcesUnavailable, 3)
        XCTAssertEqual(subject.processed, 60)
        let sealedBytes = try Data(contentsOf: archive.url)
        subject.remove(0); subject.openPhoto(0); subject.choose(.other)
        await pick(["not-allowed-after-seal"], in: subject)
        XCTAssertNil(subject.focusIndex)
        XCTAssertEqual(try Data(contentsOf: archive.url), sealedBytes)
        subject.suspend()
        let restored = store()
        XCTAssertTrue(restored.isSealed); XCTAssertEqual(restored.confirmed, 60)
        XCTAssertTrue(restored.canCompare); XCTAssertNil(restored.report)
        XCTAssertEqual(try Data(contentsOf: references.url), refsBefore)
        XCTAssertEqual(try Data(contentsOf: development.url), devBefore)
    }

    func testIncompleteOrMalformedChunkCannotPublishPartialReport() async throws {
        for fault in ["throw", "short", "ids"] {
            try archive.save(fixture())
            var calls = 0
            let subject = store(runner: { _, ids, _ in
                calls += 1
                if calls == 2 && fault == "throw" { throw CocoaError(.fileReadUnknown) }
                var values = self.photos(ids)
                if calls == 2 && fault == "short" { values.removeLast() }
                if calls == 2 && fault == "ids" {
                    values[0] = .init(id: 1, image: self.image, suggestion: nil, issue: .noSingleCat)
                }
                return .init(photos: values, referenceA: nil, referenceB: nil)
            })
            subject.compare(); await finish(subject)
            XCTAssertEqual(calls, 2, fault); XCTAssertNil(subject.report, fault)
            XCTAssertNotNil(subject.message, fault); XCTAssertEqual(subject.processed, 24, fault)
            XCTAssertTrue(try XCTUnwrap(archive.load()).sealed)
            XCTAssertEqual(try archive.load()?.decisions, try fixture().decisions)
        }
    }

    func testLateRunnerAfterSuspendCannotPublishOrStartAnotherChunk() async throws {
        try archive.save(fixture())
        var continuation: CheckedContinuation<CandidateReviewRun, Never>?, calls = 0, requestedIDs: [String] = []
        let entered = expectation(description: "first chunk started")
        let returned = expectation(description: "cancelled runner returned")
        let subject = store(runner: { _, ids, _ in
            calls += 1; requestedIDs = ids
            let run = await withCheckedContinuation { continuation = $0; entered.fulfill() }
            returned.fulfill(); return run
        })
        subject.compare()
        await fulfillment(of: [entered], timeout: 2)
        let sealedBytes = try Data(contentsOf: archive.url)
        subject.suspend()
        continuation?.resume(returning: .init(photos: photos(requestedIDs), referenceA: nil, referenceB: nil)); continuation = nil
        await fulfillment(of: [returned], timeout: 2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(calls, 1); XCTAssertNil(subject.report); XCTAssertFalse(subject.running)
        XCTAssertTrue(subject.isSealed); XCTAssertEqual(subject.confirmed, 60)
        XCTAssertEqual(try Data(contentsOf: archive.url), sealedBytes)
    }

    func testReportKeepsUnsureDuplicateAndUnavailableDenominatorsAndExportsOnlyAggregates() throws {
        var study = try fixture(); try study.choose(.unsure, id: freshIDs[0]); try study.seal()
        var values = photos(study.identifiers)
        values[0] = .init(id: 0, image: image, suggestion: .a, issue: nil)
        values[1] = .init(id: 1, image: image, suggestion: .a, issue: .repeatedBurst)
        values[2] = .init(id: 2, image: image, suggestion: .a, issue: .similarPhoto)
        values[3] = .init(id: 3, image: nil, suggestion: nil, issue: .unavailable)
        values[4] = .init(id: 4, image: image, suggestion: .a, issue: nil)
        values[20] = .init(id: 20, image: image, suggestion: .b, issue: nil)
        let report = try CandidateValidationReport(study: study, photos: values, duplicateSourcesUnavailable: 2)
        XCTAssertEqual(report.counts, [[1, 0, 0, 0, 1, 0], [0, 1, 0, 0, 0, 0], [18, 19, 10, 10, 0, 0]])
        XCTAssertEqual(report.counts.flatMap { $0 }.reduce(0, +), 60)
        XCTAssertEqual(report.selected, 60); XCTAssertEqual(report.proposed, 3); XCTAssertEqual(report.matchingProposals, 2)
        XCTAssertEqual(report.duplicatePhotos, 2); XCTAssertEqual(report.unavailablePhotos, 1)
        XCTAssertFalse(report.compositionReady)
        let json = try XCTUnwrap(report.json)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        for field in ["manualTimeComparisonMeasured", "independentAccuracyEvaluated", "goalValidated", "productValidated",
                      "productionDataChanged", "photosIncluded", "identifiersIncluded", "embeddingsIncluded", "individualPredictionsIncluded"] {
            XCTAssertEqual(raw[field] as? Bool, false, field)
        }
        for field in ["referenceFingerprint", "knownIdentifiers", "identifiers", "decisions", "assetStateFingerprint",
                      "boxes", "image", "embedding", "scores", "photos"] {
            XCTAssertNil(raw[field], field)
        }
        for id in known + freshIDs { XCTAssertFalse(json.contains(id), id) }
        XCTAssertFalse(json.contains(study.referenceFingerprint)); XCTAssertFalse(json.contains(study.assetStateFingerprint))
        XCTAssertThrowsError(try CandidateValidationReport(study: study, photos: Array(values.dropLast()), duplicateSourcesUnavailable: 0))
        XCTAssertThrowsError(try CandidateValidationReport(study: study, photos: values, duplicateSourcesUnavailable: -1))
        var bad = study; bad.sealed = false
        XCTAssertThrowsError(try CandidateValidationReport(study: bad, photos: values, duplicateSourcesUnavailable: 0))
        bad = study; bad.decisions.removeValue(forKey: freshIDs[0])
        XCTAssertThrowsError(try CandidateValidationReport(study: bad, photos: values, duplicateSourcesUnavailable: 0))
    }

    func testNarrowSetupAndBlindReviewRenderWithOnlyGeneratedImages() async throws {
        let generated = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 240, height: 360)).image { context in
            UIColor.darkGray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 240, height: 360))
            UIColor.cyan.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
            UIColor.orange.setFill(); context.fill(CGRect(x: 160, y: 300, width: 80, height: 60))
        }.cgImage)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        for blind in [false, true] {
            let subject = store(imageLoader: { _ in generated })
            if subject.count == 0 { await pick(["generated-portrait"], in: subject) }
            if blind {
                subject.openPhoto(0); await finish(subject)
                XCTAssertTrue(subject.focusLoaded); XCTAssertNotNil(subject.focusImage)
            }
            let view = CandidateValidationView(store: subject)
            let content = blind ? AnyView(view.blindReview) : AnyView(NavigationStack { view })
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 844)
            let host = UIHostingController(rootView: content.environment(\.colorScheme, .dark))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                subject.suspend(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            }
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let screenshot = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "candidate-validation-\(blind ? "blind" : "setup")-320"
            attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertNil(subject.report); XCTAssertFalse(subject.isSealed)
        }
    }
}
