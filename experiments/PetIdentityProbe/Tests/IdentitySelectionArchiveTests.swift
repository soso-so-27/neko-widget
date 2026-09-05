import XCTest
@testable import PetIdentityProbe

final class IdentitySelectionArchiveTests: XCTestCase {
    private func archive() -> IdentitySelectionArchive {
        IdentitySelectionArchive(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("ProbeSelectionTest-\(UUID().uuidString)/selection-v1.json"))
    }

    func testBoundedReferencesRoundTripProtectionBackupExclusionAndExactClear() throws {
        let archive = archive()
        defer { try? FileManager.default.removeItem(at: archive.url.deletingLastPathComponent()) }
        XCTAssertTrue(try archive.load().isEmpty)
        try archive.save([.referenceA: ["synthetic-a-1", "synthetic-a-2"]])
        XCTAssertEqual(try archive.load()[.referenceA], ["synthetic-a-1", "synthetic-a-2"])
        XCTAssertEqual(try archive.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertTrue(IdentitySelectionArchive.writingOptions.contains(.atomic))
        XCTAssertTrue(IdentitySelectionArchive.writingOptions.contains(.completeFileProtection))
        // Simulator does not expose iOS hardware-backed data-protection metadata.
        // Verify the requested policy here; only device tests can assert the attribute.
        #if !targetEnvironment(simulator)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: archive.url.path)[.protectionKey] as? FileProtectionType, .complete)
        #endif
        let other = archive.url.deletingLastPathComponent().appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: other)
        try archive.save([.referenceB: ["replacement"]])
        let text = String(decoding: try Data(contentsOf: archive.url), as: UTF8.self)
        XCTAssertFalse(text.contains("synthetic-a")) // No append-only photo history.
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["schema", "slots"])
        try archive.remove()
        XCTAssertTrue(try archive.load().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testRejectsInvalidSelectionsWithoutOverwritingArchive() throws {
        let archive = archive()
        defer { try? FileManager.default.removeItem(at: archive.url.deletingLastPathComponent()) }
        try archive.save([.referenceA: ["keep"]])
        XCTAssertThrowsError(try archive.save([.referenceA: Array(repeating: "duplicate", count: 5)]))
        XCTAssertThrowsError(try archive.save([.referenceA: (0..<6).map { "item-\($0)" }]))
        XCTAssertThrowsError(try archive.save([.referenceA: [""]]))
        XCTAssertThrowsError(try archive.save([.referenceA: ["same"], .referenceB: ["same"]]))
        XCTAssertEqual(try archive.load()[.referenceA], ["keep"])
        try Data("{\"schema\":99,\"slots\":{}}".utf8).write(to: archive.url)
        XCTAssertThrowsError(try archive.load())
    }

    @MainActor func testPartialSelectionSurvivesSuspensionReopenAndCanReplaceOneSlot() throws {
        let archive = archive()
        defer { try? FileManager.default.removeItem(at: archive.url.deletingLastPathComponent()) }
        let store = IdentityEvaluationStore(archive: archive)
        func select(_ ids: [String?], slot: IdentityPhotoSlot) {
            let request = IdentityPickerRequest(slot: slot)
            store.picker = request
            store.selected(ids, request: request)
        }
        select(["a1", "a2"], slot: .referenceA)
        select(["b1"], slot: .referenceB)
        let old = IdentityPickerRequest(slot: .evaluationA)
        store.picker = old
        store.suspend()
        store.selected(["stale"], request: old)
        XCTAssertNil(store.selections[.evaluationA])
        XCTAssertEqual(store.selections[.referenceA], ["a1", "a2"])
        let reopened = IdentityEvaluationStore(archive: archive)
        XCTAssertEqual(reopened.selections[.referenceB], ["b1"])
        XCTAssertFalse(reopened.ready)
        select(["a1", "a3"], slot: .referenceA)
        XCTAssertEqual(try archive.load()[.referenceB], ["b1"])
        XCTAssertEqual(try archive.load()[.referenceA], ["a1", "a3"])
        select([], slot: .referenceA) // Explicitly deselect all in a preselected picker.
        XCTAssertEqual(try archive.load()[.referenceA], [])
        store.clear()
        XCTAssertTrue(store.selections.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.url.path))
    }

    @MainActor func testAllFortyReferencesRemainReadyAfterReopeningWithoutFreshSampleClaim() throws {
        let archive = archive()
        defer { try? FileManager.default.removeItem(at: archive.url.deletingLastPathComponent()) }
        let selections = Dictionary(uniqueKeysWithValues: IdentityPhotoSlot.allCases.map { slot in
            (slot, (0..<slot.count).map { "\(slot.rawValue)-\($0)" })
        })
        try archive.save(selections)
        let store = IdentityEvaluationStore(archive: archive)
        XCTAssertTrue(store.ready)
        store.suspend()
        XCTAssertTrue(store.ready)
        XCTAssertNil(store.result)
        XCTAssertEqual(store.selections, selections)
    }

    @MainActor func testCorruptSavedSelectionFailsClosedAndCanBeExplicitlyCleared() throws {
        let archive = archive()
        defer { try? FileManager.default.removeItem(at: archive.url.deletingLastPathComponent()) }
        try archive.save([.referenceA: ["old"]])
        let corrupt = Data("invalid archive".utf8)
        try corrupt.write(to: archive.url)
        let store = IdentityEvaluationStore(archive: archive)
        XCTAssertNotNil(store.message)
        let request = IdentityPickerRequest(slot: .referenceA)
        store.picker = request
        store.selected(["new"], request: request)
        XCTAssertFalse(store.ready)
        XCTAssertEqual(try Data(contentsOf: archive.url), corrupt)
        store.clear()
        XCTAssertNil(store.message)
        XCTAssertTrue(store.selections.isEmpty)
    }
}
