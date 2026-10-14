import SwiftUI
import UIKit

struct RestoredToolsView: View {
    @State private var backups: [ToolBackupFiles.Saved] = []
    @State private var failed = false
    var body: some View {
        List {
            Section {
                Text("保存時点のツールの記録です。元の記録とは別に開けます。通信がなくても使えます。")
                Text("連絡先・薬・受診内容は保存当時の情報です。渡す前に、いまの内容を確認してください。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(backups) { backup in
                NavigationLink {
                    RestoredToolWorkspace(saved: backup)
                } label: {
                    VStack(alignment: .leading) {
                        Text("ツールの記録")
                        Text(backup.index.createdAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if failed { Text("復元した記録を読み込めませんでした。記録は削除していません。") }
            else if backups.isEmpty { Text("まだ復元したツールはありません。サービスの保管一覧から復元できます。") }
        }
        .navigationTitle("復元したツール")
        .task {
            do { backups = try ToolBackupFiles.saved(); failed = false }
            catch { failed = true }
        }
    }
}

@MainActor
private struct RestoredToolWorkspace: View {
    let saved: ToolBackupFiles.Saved
    let root: URL
    @StateObject private var care: CareHandoffStore
    @StateObject private var evacuation: EvacuationStore
    @StateObject private var lost: LostCatDraftStore
    private let legacy: CatPreparednessStore
    private let veterinary: VeterinaryVisitStore
    private let notes: PhotoMemoryNoteStore
    @State private var photos: [RestoredPhoto] = []
    @State private var photoError = false
    struct RestoredPhoto: Identifiable { let id: String; let url: URL; let group: String }

    init(saved: ToolBackupFiles.Saved) {
        self.saved = saved
        let root = ToolBackupFiles.directory(saved.id).appendingPathComponent("contents", isDirectory: true)
        self.root = root
        _care = StateObject(wrappedValue: CareHandoffStore(directory: root.appendingPathComponent("CareHandoff"), allowsCandidateRefresh: false))
        _evacuation = StateObject(wrappedValue: EvacuationStore(directory: root.appendingPathComponent("EvacuationPreparation"), allowsCandidateRefresh: false))
        let legacy = CatPreparednessStore(directory: root.appendingPathComponent("CatPreparedness"))
        self.legacy = legacy
        _lost = StateObject(wrappedValue: LostCatDraftStore(directory: root.appendingPathComponent("LostCatDrafts"), legacy: legacy,
                                                         allowsCandidateRefresh: false))
        veterinary = VeterinaryVisitStore(directory: root.appendingPathComponent("VeterinaryVisits"))
        notes = PhotoMemoryNoteStore(fileURL: root.appendingPathComponent("RestoredEmptyNotes/notes.json"))
    }
    private func has(_ name: String) -> Bool { saved.index.files.contains { $0.path.hasPrefix(name + "/") } }
    private var lostKeys: [String] {
        Set(lost.drafts.keys).union(legacy.records.keys.map { $0 == "unregistered" ? "guest-legacy" : $0 }).sorted()
    }
    var body: some View {
        List {
            Section {
                Text(saved.index.createdAt, format: .dateTime.year().month().day().hour().minute())
                Text("保存当時の記録です。ここでの編集は、この復元した記録だけに反映されます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if has("CareHandoff") {
                NavigationLink("預けるとき") {
                    CareHandoffView(profiles: [], unregisteredPhotos: [], store: care, reuseStore: evacuation)
                }
            }
            if has("EvacuationPreparation") {
                NavigationLink("避難に備える") {
                    EvacuationPreparationView(profiles: [], unregisteredPhotos: [], store: evacuation, reuseStore: care)
                }
            }
            if has("VeterinaryVisits") {
                NavigationLink("病院で見せる") {
                    VeterinaryVisitsView(photos: [], noteStore: notes, store: veterinary, careStore: care, evacuationStore: evacuation)
                }
            }
            if has("LostCatDrafts") || has("CatPreparedness") {
                Section("迷子のとき") {
                    ForEach(lostKeys, id: \.self) { key in
                        NavigationLink {
                            LostCatDraftView(initialKey: key, initialName: "", profiles: [], allPhotos: [],
                                             evacuationStore: evacuation, careStore: care, store: lost)
                        } label: {
                            Text(lost.drafts[key]?.name.nonEmpty ?? legacy.records[key]?.name.nonEmpty ?? "保存した猫の記録")
                        }
                    }
                }
            }
            if has("ShowcasePhotos") {
                Section("うちの子を見せる") {
                    ForEach(Array(Set(photos.map(\.group))).sorted(), id: \.self) { group in
                        NavigationLink {
                            ScrollView {
                                LazyVStack {
                                    ForEach(photos.filter { $0.group == group }) { photo in
                                        if let image = UIImage(contentsOfFile: photo.url.path) {
                                            Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("保存した写真")
                                        } else { Text("写真を読み込めませんでした。") }
                                    }
                                }
                            }.navigationTitle("うちの子を見せる")
                        } label: {
                            Text(group.isEmpty ? "みんなの写真" : "保存した写真の組み合わせ")
                        }
                    }
                    if photoError { Text("写真の組み合わせを読み込めませんでした。") }
                }
            }
        }
        .navigationTitle("復元したツール")
        .task {
            guard has("ShowcasePhotos") else { return }
            do {
                struct Manifest: Decodable { let entries: [ShowcasePhotoStore.Entry] }
                let data = try ToolBackupFiles.read(root.appendingPathComponent("ShowcasePhotos/selected.json"), maximum: 8 * 1024 * 1024)
                let decoder = JSONDecoder()
                let entries: [ShowcasePhotoStore.Entry]
                if let manifest = try? decoder.decode(Manifest.self, from: data) { entries = manifest.entries }
                else { entries = try decoder.decode([ShowcasePhotoStore.Entry].self, from: data) }
                photos = try entries.map { entry in
                    let path = "ShowcasePhotos/" + entry.imageFileName
                    try ToolBackupIndex.validatePath(path)
                    return RestoredPhoto(id: entry.id, url: root.appendingPathComponent(path), group: entry.scopeID)
                }
            } catch { photoError = true }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

#if DEBUG
/// Synthetic owner and files only. Exercises the shipping client/transfer/stores.
@MainActor
struct ToolBackupFixtureView: View {
    @State private var saved: ToolBackupFiles.Saved?
    @State private var result = "確認中"
    var body: some View {
        NavigationStack {
            List {
                Text(result).accessibilityIdentifier("tool-backup-result")
                if let saved {
                    NavigationLink("復元したツールを開く") { RestoredToolWorkspace(saved: saved) }
                }
            }.task { await verify() }
        }
    }
    private func verify() async {
        do {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: source) }
            var care = CareHandoffPlan()
            care.cats = [CareCat(name: "同じ名前", healthStatus: .recorded, healthDetails: "保存当時の薬"), CareCat(name: "同じ名前")]
            care.contact = "保存当時の連絡先"
            let careBytes = try JSONEncoder().encode(care)
            try ToolBackupFiles.write(careBytes, to: source.appendingPathComponent("CareHandoff/plan.json"))
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
                UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }.jpegData(compressionQuality: 0.9)!
            let name = UUID().uuidString + ".jpg"
            var evacuation = EvacuationPlan()
            evacuation.cats = [EvacuationCat(name: "同じ名前", photos: ["withOwner": name])]
            try ToolBackupFiles.write(JSONEncoder().encode(evacuation), to: source.appendingPathComponent("EvacuationPreparation/plan.json"))
            try ToolBackupFiles.write(image, to: source.appendingPathComponent("EvacuationPreparation/" + name))
            let entry = ShowcasePhotoStore.Entry(scopeID: "", photoIdentifier: "absent-from-photokit", imageFileName: name)
            try ToolBackupFiles.write(JSONEncoder().encode([entry]), to: source.appendingPathComponent("ShowcasePhotos/selected.json"))
            try ToolBackupFiles.write(image, to: source.appendingPathComponent("ShowcasePhotos/" + name))
            let owner = UUID().uuidString.lowercased()
            let candidate = try ToolBackupFiles.capture(owner: owner, source: source)
            try await ToolBackupValidation.validate(candidate.index, at: ToolBackupFiles.directory(candidate.id))
            guard candidate.index.files.contains(where: { $0.path == "EvacuationPreparation/" + name }) else { throw ToolBackupError.invalid }
            let origin = URL(string: "https://" + UUID().uuidString.lowercased() + ".tool-fixture.invalid")!
            let store = ManagedPreservationSessionStore(origin: origin.absoluteString)
            let credential = ManagedPreservationSessionStore.Credential(token: String(repeating: "t", count: 43), ownerId: owner,
                                                                       expiresAt: Date().addingTimeInterval(600))
            guard try store.save(credential, replacing: nil) else { throw ToolBackupError.invalid }
            defer { _ = try? store.clear(ifMatching: credential) }
            let pieces = try ToolBackupFiles.drafts(candidate)
            let server = ToolBackupFixtureServer(maximum: pieces.count)
            let configuration = ManagedPreservationConfiguration(isEnabled: true, origin: origin, membershipAudience: "tool.fixture")
            let client = ManagedPreservationClient(configuration: configuration,
                requestOverride: { request, _ in try await server.request(request) })
            do {
                try await ToolBackupTransfer.upload(candidate, client: client) { _, _ in }
                throw ToolBackupError.invalid
            } catch ManagedPreservationError.unavailable { }
            try await ToolBackupTransfer.upload(candidate, client: client) { _, _ in }
            let index = try await client.detail(candidate.id)
            let missingID = pieces[0].0
            await server.hide(missingID)
            do {
                _ = try await ToolBackupTransfer.restore(index.record, client: client) { _, _ in }
                throw ToolBackupError.invalid
            } catch ManagedPreservationError.notFound { }
            guard !FileManager.default.fileExists(atPath: ToolBackupFiles.directory(candidate.id).appendingPathComponent("contents").path)
            else { throw ToolBackupError.invalid }
            await server.hide(nil)
            let restored = try await ToolBackupTransfer.restore(index.record, client: client) { _, _ in }
            let restoredRoot = ToolBackupFiles.directory(restored.id).appendingPathComponent("contents")
            guard try Data(contentsOf: source.appendingPathComponent("CareHandoff/plan.json")) == careBytes,
                  try Data(contentsOf: restoredRoot.appendingPathComponent("CareHandoff/plan.json")) == careBytes,
                  try Data(contentsOf: restoredRoot.appendingPathComponent("EvacuationPreparation/" + name)) == image else { throw ToolBackupError.invalid }
            // No name matching, current-health prefill or PhotoKit relinking.
            let restoredCare = CareHandoffStore(directory: restoredRoot.appendingPathComponent("CareHandoff"), allowsCandidateRefresh: false)
            guard restoredCare.plan.cats.count == 2, restoredCare.plan.cats[0].id != restoredCare.plan.cats[1].id,
                  restoredCare.plan.cats[0].healthDetails == "保存当時の薬" else { throw ToolBackupError.invalid }
            saved = restored; result = "保存・再開・欠落拒否・復元・元記録保全を確認"
        } catch { result = "失敗: \(error)" }
    }
}

private actor ToolBackupFixtureServer {
    let maximum: Int
    var records: [UUID: [String: Any]] = [:]
    var losesReply = true
    var hidden: UUID?
    init(maximum: Int) { self.maximum = maximum }
    func hide(_ id: UUID?) { hidden = id }
    func request(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url!
        func response(_ json: [String: Any], status: Int = 200) throws -> (Data, URLResponse) {
            (try JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if url.path == "/v1/usage" {
            return try response(["version": 1, "accounting": "encrypted-records-v1",
                "storage": ["usedBytes": 0, "reservedBytes": 0, "limitBytes": 100000000, "availableBytes": 100000000, "overLimit": false],
                "records": ["saved": records.count, "pending": 0, "maximumRecords": maximum, "creationLimitReached": records.count >= maximum]])
        }
        guard let id = UUID(uuidString: url.lastPathComponent) else { throw ToolBackupError.invalid }
        if request.httpMethod == "PUT" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let photo = (body["photoBase64"] as? String).flatMap { Data(base64Encoded: $0) }
            records[id] = ["recordId": id.uuidString.lowercased(), "revision": 1, "document": body["document"]!,
                           "photoBase64": body["photoBase64"] ?? NSNull(), "photoSHA256": photo.map(ToolBackupIndex.hash) as Any? ?? NSNull()]
            if losesReply { losesReply = false; throw ManagedPreservationError.unavailable }
            return try response(["recordId": id.uuidString.lowercased(), "revision": 1])
        }
        guard id != hidden, let record = records[id] else { return try response(["error": ["code": "RECORD_NOT_FOUND"]], status: 404) }
        return try response(record)
    }
}
#endif
