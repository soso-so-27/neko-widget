import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

@main enum VeterinaryVisitVerifier {
    struct Failure: Error { let message: String }
    static func require(_ result: Bool, _ message: String) throws { if !result { throw Failure(message: message) } }
    static func verifyLedgerRecovery(root: URL) async throws {
        let manager = FileManager.default
        let store = VeterinaryVisitStore(directory: root)
        try require(try await store.visits().isEmpty, "New absent directory was not empty")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try require(try await store.visits().isEmpty, "New empty directory was not empty")
        let visit = try await store.current(catID: UUID(), catName: "むぎ") { try $0() }
        let ledger = root.appendingPathComponent("state.json")
        let original = try Data(contentsOf: ledger)
        let photo = root.appendingPathComponent(UUID().uuidString + ".jpg")
        let photoBytes = Data([0xff, 0xd8, 0xff, 0xd9])
        try photoBytes.write(to: photo)
        try require(try await store.visits() == [visit], "Normal ledger failed")
        for corrupt in [false, true] {
            if corrupt { try Data("broken-ledger".utf8).write(to: ledger) }
            else { try manager.removeItem(at: ledger) }
            do { _ = try await store.visits(); throw Failure(message: "Missing/corrupt ledger became empty") }
            catch VeterinaryVisitError.storage {} catch VeterinaryVisitError.corrupted {}
            do {
                _ = try await store.current(catID: UUID(), catName: "別の猫") { _ in
                    throw Failure(message: "Unreadable ledger reached creation")
                }
                throw Failure(message: "Unreadable ledger accepted creation")
            } catch VeterinaryVisitError.storage {} catch VeterinaryVisitError.corrupted {}
            do { _ = try await store.save(visit, expectedRevision: visit.revision); throw Failure(message: "Unreadable ledger accepted edit") }
            catch VeterinaryVisitError.storage {} catch VeterinaryVisitError.corrupted {}
            do { try await store.delete(visitID: visit.id, expectedRevision: visit.revision); throw Failure(message: "Unreadable ledger accepted delete") }
            catch VeterinaryVisitError.storage {} catch VeterinaryVisitError.corrupted {}
            do { _ = try await store.cleanupPending(); throw Failure(message: "Unreadable ledger accepted cleanup") }
            catch VeterinaryVisitError.storage {} catch VeterinaryVisitError.corrupted {}
            try require(try Data(contentsOf: photo) == photoBytes, "Recovery path changed photo bytes")
            if corrupt { try require(try Data(contentsOf: ledger) == Data("broken-ledger".utf8), "Corrupt ledger overwritten") }
            else { try require(!manager.fileExists(atPath: ledger.path), "Missing ledger recreated") }
            try original.write(to: ledger)
            try require(try await store.visits() == [visit], "Restored ledger did not recover")
            // Restore a newer revision and another cat's record, then reuse the
            // old instance. Its stale edit/delete must preserve both records.
            struct RestoredState: Encodable { let schema = 1; let visits: [VeterinaryVisit] }
            var newer = visit; newer.revision = UUID(); newer.observations = "復元後の新しい記録"
            let additional = VeterinaryVisit(id: UUID(), catID: UUID(), catName: "別の猫", revision: UUID(),
                startedOn: nil, observations: "復元した別の記録", questions: "", entries: [], completedAt: nil)
            let restoredBytes = try JSONEncoder().encode(RestoredState(visits: [newer, additional]))
            try restoredBytes.write(to: ledger)
            do { _ = try await store.save(visit, expectedRevision: visit.revision); throw Failure(message: "Stale edit overwrote restored revision") }
            catch VeterinaryVisitError.changed {}
            do { try await store.delete(visitID: visit.id, expectedRevision: visit.revision); throw Failure(message: "Stale delete removed restored revision") }
            catch VeterinaryVisitError.changed {}
            try require(try Data(contentsOf: ledger) == restoredBytes, "Stale operation changed restored bytes")
            var edited = newer; edited.questions = "復元後の追記"
            let saved = try await store.save(edited, expectedRevision: newer.revision)
            let reopened = VeterinaryVisitStore(directory: root)
            let after = try await reopened.visits()
            try require(after.contains(saved) && after.contains(additional) && after.count == 2, "Post-recovery edit lost records")
            try require(try Data(contentsOf: photo) == photoBytes, "Post-recovery edit changed photo bytes")
            try original.write(to: ledger)
        }
    }

    static func main() async throws {
        let suiteRoot = FileManager.default.temporaryDirectory.appendingPathComponent("vet-verify-\(UUID())")
        defer { try? FileManager.default.removeItem(at: suiteRoot) }
        try await verifyLedgerRecovery(root: suiteRoot.appendingPathComponent("ledger-recovery"))
        let root = suiteRoot.appendingPathComponent("primary-store")
        let store = VeterinaryVisitStore(directory: root), owner = UUID(), otherOwner = UUID()
        let initial = try await store.visits()
        for invalid in ["", "   ", String(repeating: "猫", count: 201), "猫\0"] {
            do {
                _ = try await store.current(catID: UUID(), catName: invalid) { _ in
                    throw Failure(message: "Invalid name reached the creation boundary")
                }
                throw Failure(message: "Invalid name accepted")
            } catch VeterinaryVisitError.invalidName {}
            try require(try await store.visits() == initial, "Invalid name changed records")
        }
        // Previously valid whitespace names must remain readable, without a schema migration.
        struct LegacyState: Encodable { let schema = 1; let visits: [VeterinaryVisit] }
        let legacyRoot = suiteRoot.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacy = VeterinaryVisit(id: UUID(), catID: UUID(), catName: "   ", revision: UUID(),
            startedOn: nil, observations: "", questions: "", entries: [], completedAt: nil)
        try JSONEncoder().encode(LegacyState(visits: [legacy])).write(to: legacyRoot.appendingPathComponent("state.json"))
        let legacyStore = VeterinaryVisitStore(directory: legacyRoot)
        try require(try await legacyStore.visits() == [legacy], "Legacy whitespace name became unreadable")
        let reused = try await legacyStore.current(catID: legacy.catID, catName: "   ") { _ in
            throw Failure(message: "Existing legacy record invoked creation")
        }
        try require(reused == legacy, "Legacy draft was not reused")
        let capacityRoot = suiteRoot.appendingPathComponent("capacity")
        try FileManager.default.createDirectory(at: capacityRoot, withIntermediateDirectories: true)
        let full = (0..<100).map { _ in VeterinaryVisit(id: UUID(), catID: UUID(), catName: "猫", revision: UUID(),
            startedOn: nil, observations: "", questions: "", entries: [], completedAt: nil) }
        try JSONEncoder().encode(LegacyState(visits: full)).write(to: capacityRoot.appendingPathComponent("state.json"))
        let capacityStore = VeterinaryVisitStore(directory: capacityRoot)
        do {
            _ = try await capacityStore.current(catID: UUID(), catName: "新しい猫") { _ in
                throw Failure(message: "Full store reached creation")
            }
            throw Failure(message: "Visit cap accepted another visit")
        } catch VeterinaryVisitError.visitLimit {}
        try require(try await capacityStore.visits() == full, "Visit limit changed records")
        let first = try await store.current(catID: owner, catName: "同じ名前") { try $0() }
        let other = try await store.current(catID: otherOwner, catName: "同じ名前") { try $0() }
        try require(first.id != other.id, "same names merged cats")
        let existing = try await store.current(catID: owner, catName: "同じ名前") { _ in
            throw Failure(message: "Creation denied")
        }
        try require(existing == first, "Expiry blocked an existing draft")
        do {
            let before = try await store.visits()
            do {
                _ = try await store.current(catID: UUID(), catName: "新しい猫") { _ in
                    throw Failure(message: "Creation denied")
                }
                throw Failure(message: "Denied creation saved a new draft")
            } catch let denied as Failure { try require(denied.message == "Creation denied", "Creation boundary not invoked") }
            try require(try await store.visits() == before, "Denied creation changed records")
        }
        let value = PhotoMemoWeightValue(grams: 4200, measuredOn: "2026-09-29", catName: "同じ名前")
        let note = PhotoMemoryNote(text: "選んだ記録だけ", updatedAt: Date(), revision: UUID().uuidString,
            weight: PhotoMemoWeight(value: value, catID: owner))
        let source = PhotoMemoryNoteRecord(photoIdentifier: "private-photo", note: note)
        do {
            _ = try await store.add(source: source, jpeg: nil, to: first.id, expectedRevision: first.revision, confirmedTarget: false)
            throw Failure(message: "unconfirmed record was included")
        } catch VeterinaryVisitError.confirmationRequired { }
        do {
            _ = try await store.add(source: source, jpeg: nil, to: other.id, expectedRevision: other.revision, confirmedTarget: true)
            throw Failure(message: "other-cat weight was included")
        } catch VeterinaryVisitError.wrongCat { }
        let added = try await store.add(source: source, jpeg: nil, to: first.id, expectedRevision: first.revision, confirmedTarget: true)
        try require(added.entries.count == 1 && added.entries[0].weight == value, "selected snapshot incorrect")
        let reopened = VeterinaryVisitStore(directory: root)
        try require(try await reopened.visits().first { $0.id == first.id } == added, "snapshot not durable")
        let changedNote = PhotoMemoryNote(id: note.id, text: "元の記録を変更", updatedAt: Date(), revision: UUID().uuidString,
            weight: PhotoMemoWeight(value: PhotoMemoWeightValue(grams: 4300, measuredOn: nil, catName: "同じ名前"), catID: owner))
        let changed = PhotoMemoryNoteRecord(photoIdentifier: source.photoIdentifier, note: changedNote)
        do {
            _ = try await store.add(source: changed, jpeg: nil, to: first.id, expectedRevision: added.revision, confirmedTarget: true)
            throw Failure(message: "source edit silently replaced selected snapshot")
        } catch VeterinaryVisitError.changed { }
        let replaced = try await store.add(source: changed, jpeg: nil, to: first.id,
            expectedRevision: added.revision, confirmedTarget: true, replace: true)
        try require(replaced.entries.count == 1 && replaced.entries[0].weight?.grams == 4300, "explicit replacement duplicated or lost value")
        let removed = try await store.remove(entryID: replaced.entries[0].id, from: first.id, expectedRevision: replaced.revision)
        try require(removed.entries.isEmpty && source.note == note, "removal affected source")
        var completed = removed; completed.questions = "聞きたいこと"; completed.completedAt = Date()
        let saved = try await store.save(completed, expectedRevision: removed.revision)
        let next = try await store.current(catID: owner, catName: "同じ名前") { try $0() }
        try require(next.id != saved.id && next.entries.isEmpty && next.questions.isEmpty, "old consultation copied into next")
        let bytes = try Data(contentsOf: root.appendingPathComponent("state.json"))
        let corrupt = Data("{bad".utf8); try corrupt.write(to: root.appendingPathComponent("state.json"))
        do { _ = try await store.current(catID: owner, catName: "same") { try $0() }; throw Failure(message: "corrupt state replaced") }
        catch VeterinaryVisitError.corrupted { }
        try require(try Data(contentsOf: root.appendingPathComponent("state.json")) == corrupt, "corrupt bytes were overwritten")
        try bytes.write(to: root.appendingPathComponent("state.json"))
        try await store.delete(visitID: saved.id, expectedRevision: saved.revision)
        try require(try await store.visits().contains { $0.id == other.id }, "deleting consultation deleted other cat")
        try await verifiesOwnedPhotoCleanup(root.appendingPathComponent("photos"))
        print("Veterinary visit boundaries passed: selection, identity, persistence, snapshots, replacement, removal, completion, corruption")
    }

    private static func verifiesOwnedPhotoCleanup(_ root: URL) async throws {
        let store = VeterinaryVisitStore(directory: root)
        let visit = try await store.current(catID: UUID(), catName: "むぎ") { try $0() }
        let note = PhotoMemoryNote(text: "", updatedAt: Date(), revision: UUID().uuidString)
        let source = PhotoMemoryNoteRecord(photoIdentifier: "original-photo-not-a-file", note: note)
        let jpeg: Data
#if canImport(ImageIO)
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try require(CGImageDestinationFinalize(destination), "native JPEG fixture failed")
        jpeg = output as Data
#else
        // Foundation boundary only; real JPEG decoding is exercised on Apple.
        jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 1, 0xff, 0xd9])
#endif
        let added = try await store.add(source: source, jpeg: jpeg, to: visit.id, expectedRevision: visit.revision, confirmedTarget: true)
        let first = added.entries[0]
        try require(try await store.image(for: first, visitID: visit.id) == jpeg, "owned JPEG not durable")
        let replaced = try await store.add(source: source, jpeg: jpeg, to: visit.id,
            expectedRevision: added.revision, confirmedTarget: true, replace: true)
        try require(first.photoFile != replaced.entries[0].photoFile
            && !FileManager.default.fileExists(atPath: root.appendingPathComponent(first.photoFile!).path), "replaced photo retained")
        let external = root.appendingPathComponent("unrelated-sentinel.txt")
        try Data("keep".utf8).write(to: external)
        try await store.delete(visitID: visit.id, expectedRevision: replaced.revision)
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(replaced.entries[0].photoFile!).path)
            && FileManager.default.fileExists(atPath: external.path), "delete escaped consultation-owned photo")
        let next = try await store.current(catID: UUID(), catName: "そら") { try $0() }
        let url = root.appendingPathComponent("state.json")
        var state = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        state["retiredPhotoFiles"] = (0..<2000).map { _ in UUID().uuidString + ".jpg" }
        let bounded = try JSONSerialization.data(withJSONObject: state); try bounded.write(to: url)
        do {
            _ = try await store.add(source: source, jpeg: jpeg, to: next.id, expectedRevision: next.revision, confirmedTarget: true)
            throw Failure(message: "cleanup intent overflow accepted")
        } catch VeterinaryVisitError.storage { }
        try require(try Data(contentsOf: url) == bounded, "overflow wrote an unreadable manifest")
        try require(try await store.visits().contains(next), "overflow hid healthy consultation")
        try require(try await store.cleanupPending() == false, "missing retired files could not be recovered")
        var invalid = state; invalid["retiredPhotoFiles"] = ["../unrelated-sentinel.txt"]
        let invalidBytes = try JSONSerialization.data(withJSONObject: invalid); try invalidBytes.write(to: url)
        do { _ = try await store.cleanupPending(); throw Failure(message: "invalid deletion target accepted") }
        catch VeterinaryVisitError.corrupted { }
        try require(FileManager.default.fileExists(atPath: external.path) && (try Data(contentsOf: url)) == invalidBytes,
                    "invalid cleanup changed manifest or external file")
    }
}
