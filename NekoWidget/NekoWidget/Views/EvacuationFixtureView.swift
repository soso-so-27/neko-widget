#if DEBUG
import SwiftUI
import UIKit
import CoreGraphics

/// Isolated native fixture. No production records, accounts or network.
/// Raster illustrations exercise storage/layout, not real PhotoKit retrieval.
struct EvacuationFixtureView: View {
    @StateObject private var store: EvacuationStore
    @State private var checks = ""
    private static let mugi = UUID(uuidString: "E0260929-0000-0000-0000-000000000001")!
    private static let sora = UUID(uuidString: "E0260929-0000-0000-0000-000000000002")!
    init() {
        let requested = ProcessInfo.processInfo.environment["NEKO_EVACUATION_FIXTURE_KEY"] ?? ""
        let key = UUID(uuidString: requested)?.uuidString ?? UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvacuationFixture", isDirectory: true).appendingPathComponent(key, isDirectory: true)
        let store = EvacuationStore(directory: directory)
        if store.plan.cats.isEmpty && ProcessInfo.processInfo.environment["NEKO_EVACUATION_EMPTY"] != "1" {
            var mugi = EvacuationCat(); mugi.id = Self.mugi; mugi.name = "むぎ"
            mugi.features = "茶白・足先が白い"; mugi.food = "むぎ専用フード"
            mugi.medicalStatus = .recorded; mugi.medicalDetails = "非公開の薬メモ"
            var sora = EvacuationCat(); sora.id = Self.sora; sora.name = "そら"
            sora.features = "黒白・鼻に黒い模様"; sora.food = "そら専用フード"
            store.update { plan in
                plan.cats = [mugi, sora]; plan.contact = "private-contact@example.invalid"
                plan.supplies[0].location = "玄関"; plan.supplies[1].location = "防災バッグ"
            }
            if let photo = AppStoreScreenshotFixture.photos.first,
               let data = AppStoreScreenshotFixture.image(for: photo.localIdentifier)?.pngData() {
                try? store.replacePhoto(data, catID: Self.mugi, role: .face)
                try? store.replacePhoto(data, catID: Self.sora, role: .face)
            }
        }
        _store = StateObject(wrappedValue: store)
    }
    var body: some View {
        NavigationStack {
            EvacuationPreparationView(profiles: [], unregisteredPhotos: [], store: store)
                .safeAreaInset(edge: .bottom) {
                    Text(checks).font(.caption2).accessibilityIdentifier("evacuation-boundary-result")
                }
        }
        .dynamicTypeSize(CommandLine.arguments.contains("--ux-large-text") ? .accessibility3 : .large)
        .task {
            do { try Self.verifyBoundaries(); checks = "境界検証成功" }
            catch { checks = "境界検証失敗" }
        }
    }

    private static func verifyBoundaries() throws {
        enum Failure: Error { case assertion(String) }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure.assertion(message) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("evacuation-boundary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try EvacuationRepository(directory: directory)
        var plan = repository.committed
        var cat = EvacuationCat(); cat.name = "猫A"; cat.food = "Aの食事"
        cat.medicalStatus = .recorded; cat.medicalDetails = "private-medical"
        let firstPhoto = UUID().uuidString + ".jpg"
        cat.photos["face"] = firstPhoto
        plan.cats = [cat]; plan.contact = "private-contact"; plan.supplies[0].location = "private-location"
        try repository.commit(plan, newPhotos: [firstPhoto: Data([1, 2, 3])])
        let decoded = try EvacuationRepository(directory: directory)
        try require(decoded.committed == plan, "roundtrip")
        let publicText = EvacuationDisclosure().fields(cat: cat, plan: plan).map { $0.1 }.joined()
        try require(!publicText.contains("private-"), "default disclosure")
        var disclosure = EvacuationDisclosure(); disclosure.medical = true; disclosure.contact = true
        let privateText = disclosure.fields(cat: cat, plan: plan).map { $0.1 }.joined()
        try require(privateText.contains("private-medical") && privateText.contains("private-contact"), "explicit disclosure")
        let failing = try EvacuationRepository(directory: directory, write: { data, url in
            if url.lastPathComponent == "plan.json" { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let replacement = UUID().uuidString + ".jpg"
        var next = plan; next.cats[0].photos["face"] = replacement
        var failed = false
        do { try failing.commit(next, newPhotos: [replacement: Data([4])]) } catch { failed = true }
        try require(failed, "manifest failure injection")
        try require(FileManager.default.fileExists(atPath: directory.appendingPathComponent(firstPhoto).path), "old photo retained")
        try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(replacement).path), "new photo rollback")
        let restored = try EvacuationRepository(directory: directory)
        try require(restored.committed == plan, "old record retained")
        let orphan = directory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([8]).write(to: orphan)
        _ = try EvacuationRepository(directory: directory)
        try require(!FileManager.default.fileExists(atPath: orphan.path), "orphan retry after restart")
        let unrelated = directory.appendingPathComponent("keep-me.txt")
        try Data([9]).write(to: unrelated)
        next = plan; next.removeCat(cat.id)
        try repository.commit(next)
        try require(FileManager.default.fileExists(atPath: unrelated.path), "unrelated file retained")
        try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(firstPhoto).path), "removed photo cleanup")
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("plan.json"))
        var rejected = false
        do { _ = try EvacuationRepository(directory: directory) } catch { rejected = true }
        try require(rejected, "corrupt manifest rejects edits")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("plan.json"))
        try Data([7]).write(to: orphan)
        rejected = false
        do { _ = try EvacuationRepository(directory: directory) } catch { rejected = true }
        try require(rejected && FileManager.default.fileExists(atPath: orphan.path), "missing manifest preserves photos")

        let exportRecord = EvacuationShareRecord(name: "猫A", photos: [],
            fields: [("長い記録", String(repeating: "この子のごはんと接し方を確認します。", count: 140))],
            reviewedAt: nil, includesPrivateInformation: false)
        let output = try EvacuationExporter.create(exportRecord, printCopy: true)
        defer { EvacuationExporter.remove(output.directory) }
        guard let document = CGPDFDocument(output.files[0] as CFURL) else { throw Failure.assertion("PDF readable") }
        try require(document.numberOfPages > 1, "long text paginates")
    }
}
#endif
