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
                Text(saved.index.contentsSummary)
                    .accessibilityIdentifier("restored-tool-contents-summary")
                Text("保存当時の記録です。ここでの編集は、この復元した記録だけに反映されます。")
                    .font(.footnote).foregroundStyle(.secondary)
                if ManagedPreservationConfiguration.current.isEnabled {
                    NavigationLink("この記録をサービスに保管する") {
                        ManagedPreservationView(toolBackupSource: saved.id)
                    }
                }
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
                Section("写真を見せる") {
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
                            }.navigationTitle("写真を見せる")
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
    @State private var originalSource: URL?
    @State private var originalCareData: Data?
    @State private var editResult = ""
    var body: some View {
        NavigationStack {
            List {
                Text(result).accessibilityIdentifier("tool-backup-result")
                if let saved {
                    NavigationLink("復元したツールを開く") { RestoredToolWorkspace(saved: saved) }
                    Button("編集後の元記録を確認") {
                        do {
                            guard let source = originalSource, let before = originalCareData,
                                  try Data(contentsOf: source.appendingPathComponent("CareHandoff/plan.json")) == before,
                                  try Data(contentsOf: ToolBackupFiles.directory(saved.id).appendingPathComponent("contents/CareHandoff/plan.json")) != before
                            else { throw ToolBackupError.invalid }
                            editResult = "元の記録を保ち、復元コピーだけを編集しました"
                            try FileManager.default.removeItem(at: source); originalSource = nil
                        } catch { editResult = "編集後の確認に失敗しました" }
                    }
                    Text(editResult)
                }
            }.task { if saved == nil && result == "確認中" { await verify() } }
        }
    }
    private func verify() async {
        var phase = "source"
        do {
            AppIdleTimer.setPreventSleep(true, for: "fixture-scan")
            AppIdleTimer.setPreventSleep(true, for: "fixture-transfer")
            AppIdleTimer.setPreventSleep(false, for: "fixture-scan")
            guard UIApplication.shared.isIdleTimerDisabled else { throw ToolBackupError.invalid }
            AppIdleTimer.setPreventSleep(false, for: "fixture-transfer")
            guard !UIApplication.shared.isIdleTimerDisabled else { throw ToolBackupError.invalid }
            let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
            var lost = LostCatDraft()
            lost.name = "迷子の控え"; lost.contact = "保存当時の連絡先"; lost.faceFileName = name
            try ToolBackupFiles.write(JSONEncoder().encode(["saved-cat": lost]), to: source.appendingPathComponent("LostCatDrafts/drafts.json"))
            try ToolBackupFiles.write(image, to: source.appendingPathComponent("LostCatDrafts/" + name))
            let vet = VeterinaryVisitStore(directory: source.appendingPathComponent("VeterinaryVisits"))
            var visit = try await vet.current(catID: UUID(), catName: "診察の記録") { try $0() }
            visit.observations = "保存当時の診察"; visit.startedOn = "2026-09-30"
            visit.completedAt = Date(timeIntervalSince1970: 1_790_726_400)
            _ = try await vet.save(visit, expectedRevision: visit.revision)
            let owner = UUID().uuidString.lowercased()
            phase = "capture-and-validate"
            let candidate = try ToolBackupFiles.capture(owner: owner, source: source)
            try await ToolBackupValidation.validate(candidate.index, at: ToolBackupFiles.directory(candidate.id))
            guard candidate.index.files.contains(where: { $0.path == "EvacuationPreparation/" + name }) else { throw ToolBackupError.invalid }
            let origin = URL(string: "https://" + UUID().uuidString.lowercased() + ".tool-fixture.invalid")!
            let store = ManagedPreservationSessionStore(origin: origin.absoluteString)
            // Secure storage uses millisecond ISO dates; make fixture CAS values exact.
            let expiry = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 600)
            let credential = ManagedPreservationSessionStore.Credential(token: String(repeating: "t", count: 43), ownerId: owner,
                                                                       expiresAt: expiry)
            guard try store.save(credential, replacing: nil) else { throw ToolBackupError.invalid }
            guard try store.load() == credential else { throw ToolBackupError.invalid }
            defer { if let current = try? store.load() { _ = try? store.clear(ifMatching: current) } }
            let pieces = try ToolBackupFiles.drafts(candidate)
            let server = ToolBackupFixtureServer(maximum: pieces.count + 10)
            let configuration = ManagedPreservationConfiguration(isEnabled: true, origin: origin, membershipAudience: "tool.fixture")
            let client = ManagedPreservationClient(configuration: configuration,
                requestOverride: { request, _ in try await server.request(request) })
            phase = "upload-lost-reply"
            do {
                try await ToolBackupTransfer.upload(candidate, client: client) { _, _ in }
                throw ToolBackupError.invalid
            } catch ManagedPreservationError.unavailable { }
            phase = "uncertain-cancel"
            await server.hide(pieces[0].0)
            do {
                try await ToolBackupTransfer.confirmPendingAttemptBeforeDeletion(candidate, client: client)
                throw ToolBackupError.invalid
            } catch ToolBackupError.uncertain { }
            guard try ToolBackupFiles.pending(owner: owner)?.id == candidate.id else { throw ToolBackupError.invalid }
            await server.hide(nil)
            phase = "upload-resume"
            try await ToolBackupTransfer.upload(candidate, client: client) { _, _ in }
            guard await server.putCount(pieces[0].0) == 1 else { throw ToolBackupError.invalid }
            phase = "request-owner-binding"
            let bound = try await client.detail(candidate.id)
            let checkpoint = try await client.captureSessionCheckpoint()
            let requestCount = await server.requestCount()
            let other = ManagedPreservationSessionStore.Credential(token: String(repeating: "b", count: 43),
                ownerId: UUID().uuidString.lowercased(), expiresAt: expiry)
            guard try store.save(other, replacing: credential) else { throw ToolBackupError.invalid }
            try await client.reloadSessionFromSecureStorage()
            do {
                _ = try await client.put(.init(recordID: candidate.id, document: bound.document, jpegData: nil), consent: true, checkpoint: checkpoint)
                throw ToolBackupError.invalid
            } catch ManagedPreservationError.staleSession { }
            do {
                try await client.delete(bound.record, checkpoint: checkpoint)
                throw ToolBackupError.invalid
            } catch ManagedPreservationError.staleSession { }
            do {
                _ = try await client.detail(candidate.id, checkpoint: checkpoint)
                throw ToolBackupError.invalid
            } catch ManagedPreservationError.staleSession { }
            guard await server.requestCount() == requestCount,
                  try store.save(credential, replacing: other) else { throw ToolBackupError.invalid }
            try await client.reloadSessionFromSecureStorage()
            phase = "parts-only-list-with-rate-limit"
            let coordinator = ManagedPreservationCoordinator(configuration: configuration, client: client)
            coordinator.start()
            for _ in 0..<100 where coordinator.isBusy { try await Task.sleep(for: .milliseconds(100)) }
            guard coordinator.records.map(\.id) == [candidate.id] else { throw ToolBackupError.invalid }
            coordinator.stop()
            let index = try await client.detail(candidate.id)
            phase = "missing-part-restore"
            let missingID = pieces[pieces.count - 2].0
            await server.hide(missingID)
            do {
                _ = try await ToolBackupTransfer.restore(index.record, client: client) { _, _ in }
                throw ToolBackupError.invalid
            } catch ManagedPreservationError.notFound { }
            guard !FileManager.default.fileExists(atPath: ToolBackupFiles.directory(candidate.id).appendingPathComponent("contents").path)
            else { throw ToolBackupError.invalid }
            await server.hide(nil)
            let firstReads = await server.readCount(pieces[0].0)
            // A fresh explicit same-owner authentication may continue verified
            // files without starting a large restore from the beginning.
            phase = "restore-reauthentication"
            let renewed = ManagedPreservationSessionStore.Credential(token: String(repeating: "r", count: 43), ownerId: owner,
                                                                     expiresAt: expiry)
            guard try store.save(renewed, replacing: credential) else { throw ToolBackupError.invalid }
            try await client.reloadSessionFromSecureStorage()
            phase = "restore-resume"
            let restored = try await ToolBackupTransfer.restore(index.record, client: client) { _, _ in }
            guard await server.readCount(pieces[0].0) == firstReads else { throw ToolBackupError.invalid }
            let restoredRoot = ToolBackupFiles.directory(restored.id).appendingPathComponent("contents")
            guard try Data(contentsOf: source.appendingPathComponent("CareHandoff/plan.json")) == careBytes,
                  try Data(contentsOf: restoredRoot.appendingPathComponent("CareHandoff/plan.json")) == careBytes,
                  try Data(contentsOf: restoredRoot.appendingPathComponent("EvacuationPreparation/" + name)) == image else { throw ToolBackupError.invalid }
            phase = "restored-data-and-rebackup"
            // No name matching, current-health prefill or PhotoKit relinking.
            let restoredCare = CareHandoffStore(directory: restoredRoot.appendingPathComponent("CareHandoff"), allowsCandidateRefresh: false)
            guard restoredCare.plan.cats.count == 2, restoredCare.plan.cats[0].id != restoredCare.plan.cats[1].id,
                  restoredCare.plan.cats[0].healthDetails == "保存当時の薬" else { throw ToolBackupError.invalid }
            let restoredVisits = try await VeterinaryVisitStore(directory: restoredRoot.appendingPathComponent("VeterinaryVisits")).visits()
            guard restoredVisits.first?.startedOn == "2026-09-30", restoredVisits.first?.completedAt == visit.completedAt else { throw ToolBackupError.invalid }
            do {
                _ = try ToolBackupFiles.restoredSource(restored.id, owner: UUID().uuidString)
                throw ToolBackupError.invalid
            } catch ManagedPreservationError.staleSession { }
            phase = "reuse-unchanged-photo"
            await server.enableReuseListing()
            await server.setPhotoReuseAllowed(false)
            guard try await ToolBackupTransfer.reusablePhotos(client: client).isEmpty else { throw ToolBackupError.invalid }
            await server.setPhotoReuseAllowed(true)
            let reusable = try await ToolBackupTransfer.reusablePhotos(client: client)
            let next = try ToolBackupFiles.capture(owner: owner, source: restoredRoot, sourceSnapshotID: restored.id,
                reusablePhotos: reusable, indexVersion: 2)
            defer { try? FileManager.default.removeItem(at: ToolBackupFiles.directory(next.id)) }
            guard next.index.files.contains(where: { $0.sourceSnapshotID == candidate.id }),
                  try ToolBackupFiles.drafts(next).allSatisfy({ $0.1.kind != "photo" }) else { throw ToolBackupError.invalid }
            guard try ToolBackupFiles.pending(owner: owner, sourceSnapshotID: restored.id)?.id == next.id,
                  try ToolBackupFiles.pending(owner: owner) == nil else { throw ToolBackupError.invalid }
            try await ToolBackupTransfer.upload(next, client: client) { _, _ in }
            phase = "delete-lost-reply"
            // Index-first deletion leaves a durable journal for explicit retry.
            do {
                try await ToolBackupTransfer.delete(candidate.index, client: client) { _, _ in }
                throw ToolBackupError.invalid
            } catch ManagedPreservationError.unavailable { }
            guard try ToolBackupFiles.pendingDeletions(owner: owner).contains(where: { $0.id == candidate.id }) else { throw ToolBackupError.invalid }
            let deletedFirstReads = await server.readCount(pieces[0].0)
            phase = "delete-reauthentication-and-resume"
            let deletionRenewed = ManagedPreservationSessionStore.Credential(token: String(repeating: "d", count: 43), ownerId: owner,
                                                                            expiresAt: expiry)
            guard try store.save(deletionRenewed, replacing: renewed) else { throw ToolBackupError.invalid }
            try await client.reloadSessionFromSecureStorage()
            try await ToolBackupTransfer.delete(candidate.index, client: client) { _, _ in }
            guard await server.readCount(pieces[0].0) == deletedFirstReads + 1,
                  try ToolBackupFiles.saved().contains(where: { $0.id == restored.id }) else { throw ToolBackupError.invalid }
            phase = "restore-after-original-copy-deleted"
            let nextRecord = try await client.detail(next.id).record
            let nextRestored = try await ToolBackupTransfer.restore(nextRecord, client: client) { _, _ in }
            guard nextRestored.index == next.index else { throw ToolBackupError.invalid }
            try await ToolBackupTransfer.delete(next.index, client: client) { _, _ in }
            guard await server.isEmpty(), try ToolBackupFiles.pendingDeletions(owner: owner).isEmpty else { throw ToolBackupError.invalid }
            phase = "large-index-and-zip"
            try verifyLargeIndex()
            originalSource = source; originalCareData = careBytes
            saved = restored; result = "保存・再開・欠落拒否・復元・元記録保全を確認"
        } catch { result = "確認に失敗しました (\(phase))" }
    }
    private func verifyLargeIndex() throws {
        let id = UUID(), owner = UUID().uuidString
        var files: [ToolBackupIndex.File] = [.init(path: "VeterinaryVisits/state.json", bytes: 2,
            sha256: ToolBackupIndex.hash(Data("{}".utf8)), records: [UUID()])]
        files += (0..<900).map { _ in .init(path: "VeterinaryVisits/" + UUID().uuidString + ".jpg", bytes: 1000,
            sha256: String(repeating: "0", count: 64), records: [UUID()]) }
        let index = ToolBackupIndex(snapshotID: id, createdAt: Date(), files: files)
        try index.validate()
        let data = try JSONEncoder().encode(index)
        guard data.count > 128 * 1024 else { throw ToolBackupError.invalid }
        let value = ToolBackupFiles.Saved(owner: owner, index: index)
        let folder = ToolBackupFiles.directory(id)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ToolBackupFiles.write(JSONEncoder().encode(value), to: folder.appendingPathComponent("pending.json"))
        guard try ToolBackupFiles.pending(owner: owner)?.index == index else { throw ToolBackupError.invalid }
        let part = ToolBackupPart(snapshotId: id.uuidString.lowercased(), kind: "index", path: "index.json", part: 0, count: 1,
                                  sha256: ToolBackupIndex.hash(data), payload: data.base64EncodedString())
        try part.validate(photo: false)
        let bytes = try JSONEncoder().encode(part)
        let archive = try PhotoMemoryNoteExporter.createArchive(text: "ツールの保存", capturedAt: nil, writtenAt: nil,
            updatedAt: nil, catNames: [], jpegData: nil, toolBackupJSON: bytes)
        defer { try? archive.cleanup() }
        guard try Data(contentsOf: archive.fileURL).range(of: bytes) != nil else { throw ToolBackupError.invalid }
    }
}

private actor ToolBackupFixtureServer {
    var maximum: Int
    var reuseListing = false
    var photoReuseAllowed = true
    var generation = 1
    var records: [UUID: [String: Any]] = [:]
    var totalRequests = 0
    var losesReply = true
    var deleteCount = 0
    var throttlesList = true
    var hidden: UUID?
    var reads: [UUID: Int] = [:]
    var puts: [UUID: Int] = [:]
    init(maximum: Int) { self.maximum = maximum }
    func enableReuseListing() { reuseListing = true; maximum = 200 }
    func setPhotoReuseAllowed(_ value: Bool) { photoReuseAllowed = value; generation += 1 }
    func hide(_ id: UUID?) { hidden = id }
    func readCount(_ id: UUID) -> Int { reads[id, default: 0] }
    func putCount(_ id: UUID) -> Int { puts[id, default: 0] }
    func isEmpty() -> Bool { records.isEmpty }
    func requestCount() -> Int { totalRequests }
    func request(_ request: URLRequest) throws -> (Data, URLResponse) {
        totalRequests += 1
        let url = request.url!
        func response(_ json: [String: Any], status: Int = 200, headers: [String: String]? = nil) throws -> (Data, URLResponse) {
            var fields = headers ?? [:]; fields["Content-Type"] = "application/json"
            return (try JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: fields)!)
        }
        if url.path == "/v1/records" {
            let after = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "after" })?.value
            let all = Array(records.values)
            if reuseListing {
                let page = all.filter { ($0["recordId"] as! String) > (after ?? "") }
                    .sorted { ($0["recordId"] as! String) < ($1["recordId"] as! String) }
                let items = page.prefix(20).map { record in
                    var item = record
                    if ((record["document"] as? [String: Any])?["toolBackup"] as? [String: Any])?["kind"] as? String == "photo" {
                        item["toolPhotoReusable"] = photoReuseAllowed
                    }
                    return item
                }
                return try response(["items": items, "nextCursor": page.count > 20 ? items.last!["recordId"]! : NSNull(), "generation": generation])
            }
            if after == nil {
                var hiddenPart = all.first { (($0["document"] as? [String: Any])?["toolBackup"] as? [String: Any])?["kind"] as? String != "index" }!
                hiddenPart["recordId"] = "00000000-0000-0000-0000-000000000001"
                return try response(["items": [hiddenPart], "nextCursor": hiddenPart["recordId"]!, "generation": 1])
            }
            if throttlesList {
                throttlesList = false
                return try response(["error": ["code": "RATE_LIMITED"]], status: 429, headers: ["Retry-After": "1"])
            }
            let index = all.first { (($0["document"] as? [String: Any])?["toolBackup"] as? [String: Any])?["kind"] as? String == "index" }!
            return try response(["items": [index], "nextCursor": NSNull(), "generation": 1])
        }
        if url.path == "/v1/usage" {
            return try response(["version": 1, "accounting": "encrypted-records-v1",
                "toolSnapshots": ["maximumIndexVersion": 2, "strictPartDeletion": true],
                "storage": ["usedBytes": 0, "reservedBytes": 0, "limitBytes": 100000000, "availableBytes": 100000000, "overLimit": false],
                "records": ["saved": records.count, "pending": 0, "maximumRecords": maximum, "creationLimitReached": records.count >= maximum]])
        }
        guard let id = UUID(uuidString: url.lastPathComponent) else { throw ToolBackupError.invalid }
        if request.httpMethod == "DELETE" {
            if let target = records[id], let document = target["document"] as? [String: Any],
               let part = document["toolBackup"] as? [String: Any], part["kind"] as? String != "index" {
                let otherUse = records.values.contains { value in
                    guard let doc = value["document"] as? [String: Any], let tag = doc["toolBackup"] as? [String: Any],
                          tag["kind"] as? String == "index", let encoded = tag["payload"] as? String,
                          let bytes = Data(base64Encoded: encoded), let index = try? JSONDecoder().decode(ToolBackupIndex.self, from: bytes)
                    else { return false }
                    return index.files.contains { $0.records.contains(id) }
                }
                if otherUse { return try response(["error": ["code": "TOOL_PART_REFERENCED"]], status: 409) }
                guard request.value(forHTTPHeaderField: "X-Tool-Delete-Unreferenced") == "1" else { throw ToolBackupError.invalid }
            }
            guard records.removeValue(forKey: id) != nil else { return try response(["error": ["code": "RECORD_NOT_FOUND"]], status: 404) }
            generation += 1
            deleteCount += 1
            if deleteCount == 2 { throw ManagedPreservationError.unavailable }
            return try response(["recordId": id.uuidString.lowercased(), "revision": 2])
        }
        if request.httpMethod == "PUT" {
            puts[id, default: 0] += 1
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let photo = (body["photoBase64"] as? String).flatMap { Data(base64Encoded: $0) }
            records[id] = ["recordId": id.uuidString.lowercased(), "revision": 1, "document": body["document"]!,
                           "photoBase64": body["photoBase64"] ?? NSNull(), "photoSHA256": photo.map { ToolBackupIndex.hash($0) as Any } ?? NSNull()]
            generation += 1
            if losesReply { losesReply = false; throw ManagedPreservationError.unavailable }
            return try response(["recordId": id.uuidString.lowercased(), "revision": 1])
        }
        reads[id, default: 0] += 1
        guard id != hidden, let record = records[id] else { return try response(["error": ["code": "RECORD_NOT_FOUND"]], status: 404) }
        return try response(record)
    }
}
#endif
