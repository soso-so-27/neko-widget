#if DEBUG
import SwiftUI
import UIKit
import PDFKit

/// Isolated synthetic records. Exercises native persistence/disclosure/rendering,
/// not real PhotoKit permission, purchases or another person's records.
struct CareHandoffFixtureView: View {
    @StateObject private var store: CareHandoffStore
    @StateObject private var reuseStore: EvacuationStore
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
        let reuse = EvacuationStore(directory: directory.deletingLastPathComponent()
            .appendingPathComponent(key + "-other-tool", isDirectory: true))
        if ProcessInfo.processInfo.environment["NEKO_CARE_AUTOFILL"] == "1", reuse.plan.cats.isEmpty {
            var cat = EvacuationCat(); cat.id = Self.mugi; cat.name = "むぎ"
            cat.food = "いつものフード 20g"; cat.handling = "無理に抱かない"
            cat.medicalStatus = .recorded; cat.medicalDetails = "private-medical"
            reuse.update { $0.cats = [cat]; $0.contact = "private-contact" }
            if let photo = AppStoreScreenshotFixture.photos.first,
               let data = AppStoreScreenshotFixture.image(for: photo.localIdentifier)?.pngData() {
                try? reuse.replacePhoto(data, catID: cat.id, role: .face)
            }
        }
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
        _reuseStore = StateObject(wrappedValue: reuse)
    }
    var body: some View {
        NavigationStack {
            CareHandoffView(profiles: [], unregisteredPhotos: [], store: store, reuseStore: reuseStore)
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
            do { rendered = try Self.verifyBoundaries(); try Self.verifyAutofill(); checks = "境界検証成功" }
            catch { checks = "境界検証失敗" }
        }
    }

    /// Executes production stores and repositories, not a parallel fake implementation.
    @MainActor
    private static func verifyAutofill() throws {
        enum Failure: Error { case assertion(String) }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure.assertion(message) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autofill-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let careDirectory = directory.appendingPathComponent("care")
        let evacuationDirectory = directory.appendingPathComponent("evacuation")
        let care = CareHandoffStore(directory: careDirectory)
        let evacuation = EvacuationStore(directory: evacuationDirectory)
        var a = EvacuationCat(); a.name = "同じ名前"; a.food = "Aのフード 20g"; a.handling = "Aの接し方"
        a.medicalStatus = .recorded; a.medicalDetails = "private-medical"
        var b = EvacuationCat(); b.name = a.name; b.food = "Bのフード"
        evacuation.update { $0.cats = [a, b]; $0.contact = "private-contact" }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        guard let bytes = image.pngData() else { throw Failure.assertion("synthetic photo") }
        try evacuation.replacePhoto(bytes, catID: a.id, role: .face)
        try evacuation.replacePhoto(bytes, catID: b.id, role: .withOwner)
        guard let id = care.addCat(using: evacuation, sourceCatID: a.id),
              let copied = care.plan.cats.first(where: { $0.id == id }), let photo = copied.photoName
        else { throw Failure.assertion("automatic creation") }
        try require(copied.usualFood == a.food && copied.handling == a.handling, "actual food and handling values")
        try require(copied.healthStatus == .unknown && copied.healthDetails.isEmpty && care.plan.contact.isEmpty, "no private field reuse")
        let output = CareHandoffDisclosure(catIDs: [id]).fields(cat: copied).map { $0.1 }.joined()
        try require(output.contains(a.food) && !output.contains("private-") && !output.contains(b.food), "untouched values output for selected cat")
        try require(photo != evacuation.plan.cats[0].photos["face"], "destination owns a distinct photo")
        try require(evacuation.addCat(using: care, sourceCatID: id) == a.id, "legacy unregistered identity reopens in reverse direction")
        care.editCat(id) { $0.usualFood = ""; $0.handling = "今回の接し方" }
        try require(care.addCat(using: evacuation, sourceCatID: a.id) == id, "same identity reopens instead of importing again")
        let restarted = CareHandoffStore(directory: careDirectory)
        try require(restarted.plan.cats[0].usualFood == "" && restarted.plan.cats[0].handling == "今回の接し方", "cleared and edited fields survive restart")
        guard let secondID = care.addCat(using: evacuation, sourceCatID: b.id) else { throw Failure.assertion("second same-name cat") }
        try require(care.plan.cats.count == 2 && care.plan.cats.first(where: { $0.id == secondID })?.photoName == nil, "distinct identity; owner-only photo excluded")
        // Reverse direction retains structured meal values as text, without guessing.
        var c = CareCat(); c.name = "新しい猫"; c.profileID = "profile-c"
        c.meals[0].time = "朝8時"; c.meals[0].food = "Cのフード"; c.meals[0].amount = "20g"
        c.handling = "Cの接し方"; c.healthStatus = .recorded; c.healthDetails = "private-health"
        care.update { $0.cats.append(c); $0.recipient = "private-recipient"; $0.period = "private-period" }
        try care.replacePhoto(bytes, catID: c.id)
        guard let reverseID = evacuation.addCat(profileID: c.profileID, name: c.name, using: care),
              let reverse = evacuation.plan.cats.first(where: { $0.id == reverseID }), let reversePhoto = reverse.photos["reference"]
        else { throw Failure.assertion("reverse autofill") }
        try require(reverse.food.contains("朝8時") && reverse.food.contains("20g") && reverse.handling == c.handling, "structured meal information retained")
        try require(reverse.medicalStatus == .unknown && reverse.medicalDetails.isEmpty && reverse.photos["face"] == nil, "no medical or invented photo role")
        try require(care.addCat(profileID: c.profileID, using: evacuation) == c.id, "legacy identity does not create duplicate")
        evacuation.editCat(reverseID) { $0.food = ""; $0.handling = "今回だけの配慮" }
        _ = evacuation.addCat(profileID: c.profileID, using: care)
        try require(evacuation.plan.cats.first(where: { $0.id == reverseID })?.food == "", "existing cleared value not repopulated")
        care.update { $0.cats.removeAll { $0.id == c.id } }
        try require(evacuation.image(reversePhoto) != nil, "source deletion keeps independent copy")
        evacuation.update { $0.removeCat(a.id) }
        try require(care.image(photo) != nil, "reverse deletion keeps independent copy")
        // Optional metadata must decode pre-change data without a migration or rewrite.
        var legacy = CareCat(); legacy.name = "旧記録"
        let oldCare = try JSONEncoder().encode(legacy)
        let decodedCare = try JSONDecoder().decode(CareCat.self, from: oldCare)
        try require(decodedCare == legacy, "legacy care optional metadata")
        var legacyEvacuation = EvacuationCat(); legacyEvacuation.name = "旧記録"
        let oldEvacuation = try JSONEncoder().encode(legacyEvacuation)
        let decodedEvacuation = try JSONDecoder().decode(EvacuationCat.self, from: oldEvacuation)
        try require(decodedEvacuation == legacyEvacuation, "legacy evacuation optional metadata")
        // Source failures must never create a partly copied record or fall back to another cat.
        let failureTarget = CareHandoffStore(directory: directory.appendingPathComponent("failure-target"))
        guard let brokenPhoto = evacuation.plan.cats.first(where: { $0.id == reverseID })?.photos["reference"] else {
            throw Failure.assertion("failure source photo")
        }
        try FileManager.default.removeItem(at: evacuationDirectory.appendingPathComponent(brokenPhoto))
        try require(failureTarget.addCat(using: evacuation, sourceCatID: reverseID) == nil
            && failureTarget.plan.cats.isEmpty && failureTarget.saveError != nil, "missing source photo refuses partial creation")
        let sourceBefore = evacuation.plan
        try Data("not-json".utf8).write(to: evacuationDirectory.appendingPathComponent("plan.json"))
        let brokenSource = EvacuationStore(directory: evacuationDirectory)
        let freshTarget = CareHandoffStore(directory: directory.appendingPathComponent("corrupt-source-target"))
        try require(brokenSource.loadError != nil && freshTarget.addCat(using: brokenSource, sourceCatID: reverseID) == nil
            && freshTarget.plan.cats.isEmpty && evacuation.plan == sourceBefore, "unreadable source fails without changing records")
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
