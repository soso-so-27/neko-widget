#if DEBUG
import SwiftUI
import UIKit
import PDFKit

/// Isolated synthetic records. Exercises native persistence/disclosure/rendering,
/// not real PhotoKit permission, purchases or another person's records.
struct CareHandoffFixtureView: View {
    @StateObject private var store: CareHandoffStore
    @State private var checks = "確認中"
    @State private var rendered: [UIImage] = []
    @State private var showsRendered = false
    private static let mugi = UUID(uuidString: "C0260929-0000-0000-0000-000000000001")!
    private static let sora = UUID(uuidString: "C0260929-0000-0000-0000-000000000002")!
    init() {
        let raw = ProcessInfo.processInfo.environment["NEKO_CARE_FIXTURE_KEY"] ?? ""
        let key = UUID(uuidString: raw)?.uuidString ?? UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CareHandoffFixture")
            .appendingPathComponent(key, isDirectory: true)
        let store = CareHandoffStore(directory: directory)
        if store.plan.cats.isEmpty && ProcessInfo.processInfo.environment["NEKO_CARE_EMPTY"] != "1" {
            var mugi = CareCat(); mugi.id = Self.mugi; mugi.name = "むぎ"
            mugi.meals[0].time = "朝8時"; mugi.meals[0].food = "むぎ専用フード"; mugi.meals[0].amount = "20g"
            mugi.important = "玄関を開ける前に、猫が別の部屋にいるか確認"
            mugi.water = "ごはんの横の器。毎朝、新しい水に取り替える"
            mugi.toilet = "汚れた砂は青い袋に。替えの砂は洗面所"
            mugi.handling = "隠れていたら、無理に抱かずにそっとしておく"
            mugi.healthStatus = .recorded; mugi.healthDetails = "private-health-sentinel"
            var sora = CareCat(); sora.id = Self.sora; sora.name = "そら"
            sora.meals[0].food = "そら専用フード"; sora.meals[0].time = "夜7時"; sora.meals[0].amount = "25g"
            store.update {
                $0.cats = [mugi, sora]; $0.recipient = "お母さん"; $0.period = "10月5日 夜〜10月7日 朝"
                $0.contact = "private-contact-sentinel"; $0.backupContact = "private-backup-sentinel"
                $0.veterinarian = "private-vet-sentinel"
            }
            if let photo = AppStoreScreenshotFixture.photos.first,
               let data = AppStoreScreenshotFixture.image(for: photo.localIdentifier)?.pngData() {
                try? store.replacePhoto(data, catID: Self.mugi)
            }
        }
        _store = StateObject(wrappedValue: store)
    }
    var body: some View {
        NavigationStack {
            CareHandoffView(profiles: [], unregisteredPhotos: [], store: store)
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Text(checks).font(.caption2).accessibilityIdentifier("care-boundary-result")
                        Button("出力を確認") { showsRendered = true }.font(.caption).disabled(rendered.isEmpty)
                    }.padding(4)
                }
        }
        .dynamicTypeSize(CommandLine.arguments.contains("--ux-large-text") ? .accessibility3 : .large)
        .sheet(isPresented: $showsRendered) {
            ScrollView { VStack {
                ForEach(Array(rendered.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } }.accessibilityIdentifier("care-rendered-output")
        }
        .task {
            do { rendered = try Self.verifyBoundaries(); checks = "境界検証成功" }
            catch { checks = "境界検証失敗" }
        }
    }

    private static func verifyBoundaries() throws -> [UIImage] {
        enum Failure: Error { case assertion(String) }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure.assertion(message) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("care-boundary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try CareHandoffRepository(directory: directory)
        var plan = repository.committed
        var cat = CareCat(); cat.name = "猫A"; cat.meals[0].food = "Aの食事"
        cat.healthStatus = .recorded; cat.healthDetails = "private-health"
        let photo = UUID().uuidString + ".jpg"; cat.photoName = photo
        plan.cats = [cat]; plan.contact = "private-contact"
        try repository.commit(plan, newPhotos: [photo: Data([1, 2, 3])])
        let roundtrip = try CareHandoffRepository(directory: directory)
        try require(roundtrip.committed == plan, "roundtrip")
        let hidden = CareHandoffDisclosure().fields(cat: cat) + CareHandoffDisclosure().commonFields(plan: plan)
        try require(!hidden.map { $0.1 }.joined().contains("private-"), "closed disclosure")
        var selected = CareHandoffDisclosure(); selected.health = true; selected.contacts = true
        let shown = selected.fields(cat: cat) + selected.commonFields(plan: plan)
        try require(shown.map { $0.1 }.joined().contains("private-health") && shown.map { $0.1 }.joined().contains("private-contact"), "explicit disclosure")
        let failing = try CareHandoffRepository(directory: directory, write: { data, url in
            if url.lastPathComponent == "plan.json" { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let replacement = UUID().uuidString + ".jpg"
        var next = plan; next.cats[0].photoName = replacement
        var failed = false
        do { try failing.commit(next, newPhotos: [replacement: Data([4])]) } catch { failed = true }
        try require(failed && FileManager.default.fileExists(atPath: directory.appendingPathComponent(photo).path), "old photo retained on failure")
        try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(replacement).path), "new photo rolled back")
        let restored = try CareHandoffRepository(directory: directory)
        try require(restored.committed == plan, "old manifest retained")
        let orphan = directory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([8]).write(to: orphan)
        _ = try CareHandoffRepository(directory: directory)
        try require(!FileManager.default.fileExists(atPath: orphan.path), "orphan retry")
        let keep = directory.appendingPathComponent("unrelated.txt"); try Data([7]).write(to: keep)
        next.cats = []; try repository.commit(next)
        try require(FileManager.default.fileExists(atPath: keep.path) && !FileManager.default.fileExists(atPath: directory.appendingPathComponent(photo).path), "owned deletion only")
        try Data("broken".utf8).write(to: directory.appendingPathComponent("plan.json"))
        failed = false
        do { _ = try CareHandoffRepository(directory: directory) } catch { failed = true }
        try require(failed, "corruption rejects writes")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("plan.json"))
        failed = false
        do { _ = try CareHandoffRepository(directory: directory) } catch { failed = true }
        try require(failed && FileManager.default.fileExists(atPath: keep.path), "missing manifest preserves data")

        let storeDirectory = directory.appendingPathComponent("store")
        let store = CareHandoffStore(directory: storeDirectory)
        var a = CareCat(); a.name = "むぎ"; a.meals[0].food = "Aだけの食事"; a.healthDetails = "private-health"
        a.healthStatus = .recorded; a.important = String(repeating: "窓や玄関を開ける前に猫の居場所を確認してください。", count: 35) + "記録の末尾"
        var b = CareCat(); b.name = "そら"; b.meals[0].food = "Bだけの食事"
        store.update { $0.cats = [a, b]; $0.contact = "private-contact" }
        var disclosure = CareHandoffDisclosure(); disclosure.catIDs = [a.id]
        let one = try store.shareRecord(disclosure)
        try require(one.cats.count == 1 && one.cats[0].name == "むぎ", "selection excludes other cat")
        let privateText = (one.commonFields + one.cats[0].fields).map { $0.1 }.joined()
        try require(!privateText.contains("private-") && !privateText.contains("Bだけ"), "private fields and second cat absent")
        disclosure.catIDs.insert(b.id)
        let both = try store.shareRecord(disclosure)
        let pdf = try CareHandoffExporter.create(both, pdf: true)
        defer { CareHandoffExporter.remove(pdf.directory) }
        guard let document = PDFDocument(url: pdf.files[0]), let text = document.string else { throw Failure.assertion("PDF readable") }
        try require(document.pageCount >= 3 && text.contains("記録の末尾") && text.contains("Bだけの食事") && !text.contains("private-"), "pagination and disclosure in actual PDF")
        let images = try CareHandoffExporter.create(one, pdf: false)
        defer { CareHandoffExporter.remove(images.directory) }
        try require(images.files.count >= 2 && images.files.allSatisfy { UIImage(contentsOfFile: $0.path) != nil }, "PNG pages readable")
        // A second immutable export must still represent the selection before edits.
        store.update { $0.cats[0].name = "変更後" }
        try require(one.cats[0].name == "むぎ", "frozen preview")
        guard let image = UIImage(contentsOfFile: images.files[0].path),
              let last = document.page(at: document.pageCount - 1) else { throw Failure.assertion("renderable") }
        return [image, last.thumbnail(of: CGSize(width: 595, height: 842), for: .mediaBox)]
    }
}
#endif
