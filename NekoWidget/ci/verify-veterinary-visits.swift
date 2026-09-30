import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

@main enum VeterinaryVisitVerifier {
    struct Failure: Error { let message: String }
    static func require(_ result: Bool, _ message: String) throws { if !result { throw Failure(message: message) } }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vet-verify-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VeterinaryVisitStore(directory: root), owner = UUID(), otherOwner = UUID()
        let first = try await store.current(catID: owner, catName: "同じ名前")
        let other = try await store.current(catID: otherOwner, catName: "同じ名前")
        try require(first.id != other.id, "same names merged cats")
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
        let next = try await store.current(catID: owner, catName: "同じ名前")
        try require(next.id != saved.id && next.entries.isEmpty && next.questions.isEmpty, "old consultation copied into next")
        let bytes = try Data(contentsOf: root.appendingPathComponent("state.json"))
        let corrupt = Data("{bad".utf8); try corrupt.write(to: root.appendingPathComponent("state.json"))
        do { _ = try await store.current(catID: owner, catName: "same"); throw Failure(message: "corrupt state replaced") }
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
        let visit = try await store.current(catID: UUID(), catName: "むぎ")
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
        let next = try await store.current(catID: UUID(), catName: "そら")
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
