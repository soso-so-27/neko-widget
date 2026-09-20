import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Capability-checked entry in the already authenticated private window.
struct FamilyRecordEntryButton: View {
    let spaceID: String
    @State private var available = false
    @State private var presented = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing: 0) {
            if available {
                Button { presented = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("共同記録", systemImage: "book.closed")
                        Text("同じ写真に、それぞれの言葉を")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                }
                .accessibilityIdentifier("family-record-entry")
            }
        }
        .task(id: spaceID) { available = await FamilyRecordClient(expectedSpaceID: spaceID).isAvailable() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { available = false }
            else if phase == .active { Task { available = await FamilyRecordClient(expectedSpaceID: spaceID).isAvailable() } }
        }
        .sheet(isPresented: $presented) { FamilyRecordView(expectedSpaceID: spaceID) }
    }
}

@MainActor
private final class FamilyRecordViewModel: ObservableObject {
    @Published var snapshot: FamilyRecordSnapshot?
    @Published var error: String?
    @Published var loading = false
    let client: any FamilyRecordServing
    private var generation = UUID()
    init(client: any FamilyRecordServing) { self.client = client }
    func clear() { generation = UUID(); snapshot = nil; loading = false }
    func reload() async {
        let request = UUID(); generation = request
        snapshot = nil; loading = true; error = nil
        defer { if generation == request { loading = false } }
        do {
            let result = try await client.load()
            guard generation == request, !Task.isCancelled else { return }
            snapshot = result
        } catch {
            guard generation == request else { return }
            self.error = "共同記録を確認できませんでした。接続を確認して、もう一度読み込んでください。"
        }
    }
}

struct FamilyRecordView: View {
    @StateObject private var model: FamilyRecordViewModel
    @State private var adding = false
    @State private var showingInformation = false
    @State private var editing: FamilyRecordEditTarget?
    @State private var withdrawing: FamilyRecordRow?
    @State private var mutation: FamilyRecordMutation?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    private let fixturePhoto: MomentShareIngressPhoto?
    init(expectedSpaceID: String) {
        _model = StateObject(wrappedValue: FamilyRecordViewModel(client: FamilyRecordClient(expectedSpaceID: expectedSpaceID)))
        fixturePhoto = nil
    }
#if DEBUG
    init(fixtureClient: any FamilyRecordServing, fixturePhoto: MomentShareIngressPhoto) {
        _model = StateObject(wrappedValue: FamilyRecordViewModel(client: fixtureClient))
        self.fixturePhoto = fixturePhoto
    }
#endif

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("同じ写真に、それぞれの言葉を")
                            .font(.headline)
                        Text("写真を持ち寄って、見ていたことや覚えておきたいことを。このまどの二人で読み返せます。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                recordSection
                if let error = model.error {
                    Section { Text(error); Button("もう一度読み込む") { Task { await model.reload() } } }
                }
                if model.loading { ProgressView("共同記録を確認中") }
            }
            .navigationTitle("共同記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("写真を追加", systemImage: "plus") { adding = true }
                        .disabled(model.snapshot == nil || saving)
                        .accessibilityIdentifier("family-record-add")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("共同記録について", systemImage: "info.circle") { showingInformation = true }
                        .accessibilityIdentifier("family-record-information")
                }
            }
            .refreshable { await model.reload() }
        }
        .task { await model.reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.clear() }
            else if phase == .active { Task { await model.reload() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .momentSharingPresentationNeedsRefresh)
            .receive(on: DispatchQueue.main)) { _ in
                model.clear()
                Task { await model.reload() }
            }
        .sheet(isPresented: $adding) {
            FamilyRecordEditor(client: model.client, target: nil, fixturePhoto: fixturePhoto) { Task { await model.reload() } }
        }
        .sheet(item: $editing) { target in
            FamilyRecordEditor(client: model.client, target: target, fixturePhoto: nil) { Task { await model.reload() } }
        }
        .sheet(isPresented: $showingInformation) { information }
        .confirmationDialog("この記録から取り下げますか？", isPresented: Binding(
            get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } })) {
                if let row = withdrawing {
                    Button("取り下げる", role: .destructive) { Task { await withdraw(row) } }
                }
            } message: {
                Text(withdrawing?.kind == .words
                     ? "自分が書いたこの言葉だけを取り下げます。写真や相手の言葉は残ります。すでに個人保存されたコピーは回収できません。"
                     : "写真を取り下げても、書かれた言葉は残ります。相手がすでに個人保存したコピーは回収できません。")
            }
    }

    @ViewBuilder private var recordSection: some View {
        if let snapshot = model.snapshot {
            let photos = snapshot.catalog.records.filter { $0.kind == .photo }
            if photos.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("まずは、写真を一枚", systemImage: "photo.on.rectangle")
                            .font(.headline)
                        Text("言葉はあとからでも。相手も同じ写真に言葉を添えられます。")
                            .foregroundStyle(.secondary)
                        Button("写真を追加") { adding = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(saving)
                            .accessibilityIdentifier("family-record-empty-add")
                    }.padding(.vertical, 8)
                }
            }
            ForEach(photos) { photo in
                Section {
                    if photo.state == .active {
                        FamilyRecordPhoto(client: model.client, row: photo)
                    } else { Label("写真は取り下げられました", systemImage: "photo") }
                    photoHeader(photo, current: snapshot.catalog.participantID)
                    ForEach(snapshot.catalog.records.filter {
                        $0.kind == .words && $0.entryID == photo.id && $0.state == .active
                    }) { words in
                        wordView(words, snapshot: snapshot)
                    }
                    Button("言葉を添える") { editing = .init(entryID: photo.id, row: nil, text: "") }
                        .accessibilityIdentifier("family-record-add-words")
                        .accessibilityHint("自分の言葉を追加します。相手の言葉は変わりません")
                }.disabled(saving)
            }
        }
    }
    private func photoHeader(_ photo: FamilyRecordRow, current: String) -> some View {
        HStack(alignment: .top) {
            authorAndDate(photo, current: current)
            Spacer()
            if photo.authorID == current && photo.state == .active {
                Menu {
                    Button("写真を取り下げる", role: .destructive) { withdrawing = photo }
                        .accessibilityIdentifier("family-record-withdraw-photo")
                } label: {
                    Label("自分が追加した写真の操作", systemImage: "ellipsis")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("family-record-photo-menu")
                .buttonStyle(.borderless)
            }
        }
    }
    private func wordView(_ words: FamilyRecordRow, snapshot: FamilyRecordSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                authorAndDate(words, current: snapshot.catalog.participantID)
                Spacer()
                if words.authorID == snapshot.catalog.participantID {
                    Menu {
                        Button("言葉を編集", systemImage: "pencil") {
                            editing = .init(entryID: words.entryID, row: words, text: snapshot.words[words.id] ?? "")
                        }
                        .accessibilityIdentifier("family-record-edit-words")
                        Button("言葉を取り下げる", role: .destructive) { withdrawing = words }
                    } label: {
                        Label("自分の言葉の操作", systemImage: "ellipsis")
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("family-record-words-menu")
                    .buttonStyle(.borderless)
                }
            }
            Text(snapshot.words[words.id] ?? "この言葉を読み込めません")
                .textSelection(.enabled)
        }
    }
    private func authorAndDate(_ row: FamilyRecordRow, current: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.kind == .photo
                 ? (row.authorID == current ? "自分が追加した写真" : "相手が追加した写真")
                 : (row.authorID == current ? "自分の言葉" : "相手の言葉"))
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 4) {
                Text(Date(timeIntervalSince1970: row.createdAt), style: .date)
                if row.kind == .words && row.updatedAt > row.createdAt { Text("編集済み") }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
    private var information: some View {
        NavigationStack {
            List {
                Section("二人で持ち寄る") {
                    Text("このまどに参加している二人が、写真や言葉を追加できます。写真だけの追加もできます。")
                    Text("選んだ写真と、ここに書いた言葉だけを共有します。個人メモやお気に入りが自動で共有されることはありません。")
                }
                Section("変更できるのは自分の分だけ") {
                    Text("自分が書いた言葉は編集・取り下げできます。相手の言葉は変更できません。")
                    Text("写真を取り下げられるのは、追加した本人だけです。写真を取り下げても、二人が書いた言葉は残ります。")
                }
                Section("共有を終了すると") {
                    Text("共有を解除・ブロックすると、この共同記録は開けなくなります。退出だけで追加済みの記録が自動削除されるわけではありません。")
                        .accessibilityIdentifier("family-record-ending-explanation")
                    Text("取り下げたい自分の写真や言葉は、共有を終了する前に操作してください。相手がすでに保存したコピーは回収できません。")
                }
                Section("写真の保管と引き継ぎ") {
                    Text("ここに残るのは鑑賞用の写真コピーです。写真アプリの原本や、まどへ届けた写真の履歴とは別の記録です。")
                    Text("参加資格と共有鍵がある端末で利用します。二人のすべての端末を失ったときの復元や、無期限の保存には対応していません。")
                }
                Section("内部テストで使える範囲") {
                    Text("一つのまどに写真100件・言葉1,000件までです。取り下げ済みの記録も件数に含みます。上限に達しても、古い記録を自動で消すことはありません。")
                }
            }
            .navigationTitle("共同記録について")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { showingInformation = false }
                        .accessibilityIdentifier("family-record-information-close")
                }
            }
        }
    }
    private func withdraw(_ row: FamilyRecordRow) async {
        saving = true
        defer { saving = false }
        do {
            if mutation?.id != row.id { mutation = try await model.client.prepareWithdrawal(row) }
            if let mutation { try await model.client.save(mutation) }
            mutation = nil
            await model.reload()
        } catch { model.error = "取り下げを確認できませんでした。再読み込みして現在の状態を確認してください。" }
    }
}

private struct FamilyRecordPhoto: View {
    let client: any FamilyRecordServing
    let row: FamilyRecordRow
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Label("写真を読み込めません。言葉は下に残っています。", systemImage: "photo") }
            else { ProgressView() }
        }
        .task(id: row) {
            do {
                let data = try await client.photo(row)
                guard !Task.isCancelled else { return }
                image = UIImage(data: data); failed = image == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

private struct FamilyRecordEditTarget: Identifiable {
    let id = UUID()
    let entryID: String
    let row: FamilyRecordRow?
    let text: String
}
private struct FamilyRecordPickedPhoto: Transferable {
    let photo: MomentShareIngressPhoto
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            Self(photo: try MomentShareIngressService().prepare(fromFileURL: file.file))
        }
    }
}

private struct FamilyRecordEditor: View {
    let client: any FamilyRecordServing
    let target: FamilyRecordEditTarget?
    let fixturePhoto: MomentShareIngressPhoto?
    let saved: () -> Void
    @State private var text: String
    @State private var photo: MomentShareIngressPhoto?
    @State private var selection: PhotosPickerItem?
    @State private var picking = false
    @State private var choosingFixture = false
    @State private var busy = false
    @State private var pending: [FamilyRecordMutation] = []
    @State private var prepared = false
    @State private var photoAdded = false
    @State private var message: String?
    @State private var selectionGeneration = UUID()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    init(client: any FamilyRecordServing, target: FamilyRecordEditTarget?, fixturePhoto: MomentShareIngressPhoto?, saved: @escaping () -> Void) {
        self.client = client; self.target = target; self.fixturePhoto = fixturePhoto; self.saved = saved
        _text = State(initialValue: target?.text ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                if target == nil {
                    Section("写真") {
                        if let photo, let image = UIImage(data: photo.canonicalJPEG) {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                        Button("写真を選ぶ") {
                            focused = false
                            if fixturePhoto != nil { choosingFixture = true } else { picking = true }
                        }.disabled(busy || prepared).accessibilityIdentifier("family-record-pick-photo")
                    }
                }
                Section(target == nil ? "言葉（あとからでも）" : "自分の言葉") {
                    TextEditor(text: $text).frame(minHeight: 140).focused($focused).disabled(busy || prepared)
                        .accessibilityIdentifier("family-record-words-input")
                    Text("\(text.count) / 500文字").font(.caption)
                    Text("ここに書いた言葉を、このまどの相手と共有します。個人メモは自動で共有されません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if photoAdded { Text("写真は追加済みです。言葉の追加を確認しています。") }
                if let message { Text(message).foregroundStyle(.red) }
                if prepared && message != nil {
                    Button("入力した言葉をコピー") { UIPasteboard.general.string = text }
                }
                Button(prepared ? "同じ操作を再確認" : (target?.row == nil ? "このまどの共同記録に追加" : "言葉の変更を共有")) { Task { await save() } }
                    .disabled(busy || text.count > 500 || (target == nil ? photo == nil : text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityIdentifier("family-record-save")
                if busy { ProgressView() }
            }
            .navigationTitle(target == nil ? "写真を追加" : (target?.row == nil ? "言葉を添える" : "自分の言葉を編集"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() }.disabled(busy) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完了") { focused = false } }
            }
        }
        .photosPicker(isPresented: $picking, selection: $selection, matching: .images, preferredItemEncoding: .current)
#if DEBUG
        .sheet(isPresented: $choosingFixture) {
            NavigationStack {
                VStack {
                    if let fixturePhoto, let image = UIImage(data: fixturePhoto.canonicalJPEG) {
                        Image(uiImage: image).resizable().scaledToFit()
                        Button("この写真を選ぶ") { photo = fixturePhoto; choosingFixture = false }
                            .accessibilityIdentifier("family-record-fixture-choose")
                    }
                }.toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { choosingFixture = false } }
                }
            }
        }
#endif
        .onChange(of: selection) { _, item in
            let generation = UUID(); selectionGeneration = generation
            guard let item else { return }
            photo = nil
            busy = true
            Task {
                defer { if selectionGeneration == generation { busy = false } }
                do {
                    let result = try await item.loadTransferable(type: FamilyRecordPickedPhoto.self)
                    guard selectionGeneration == generation else { return }
                    photo = result?.photo; message = nil
                } catch { if selectionGeneration == generation { message = "写真を読み込めませんでした。" } }
            }
        }
        .onDisappear { selectionGeneration = UUID() }
        .interactiveDismissDisabled(busy)
    }
    private func save() async {
        busy = true; message = nil; focused = false
        defer { busy = false }
        do {
            if !prepared {
                var operations: [FamilyRecordMutation] = []
                let entryID: String
                if let target { entryID = target.entryID }
                else if let photo {
                    let operation = try await client.preparePhoto(photo)
                    operations.append(operation); entryID = operation.id
                } else { throw FamilyRecordError.invalid }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    operations.append(try await client.prepareWords(text, entryID: entryID, replacing: target?.row))
                }
                pending = operations; prepared = true
            }
            while let first = pending.first {
                try await client.save(first)
                if first.body.kind == .photo { photoAdded = true }
                pending.removeFirst()
            }
            saved(); dismiss()
        } catch {
            message = (error as? FamilyRecordError)?.errorDescription
                ?? "追加を確認できませんでした。入力を残しています。再確認しても同じ記録を重複追加しません。"
        }
    }
}

#if DEBUG
/// Exercises the product view/editor with an isolated authority and image input.
/// No Pairing/Keychain/Photos/CloudKit/network/store reads occur in this fixture.
/// It does not substitute for the separate real PhotosPicker regression.
struct FamilyRecordUIFixture: View {
    private let client: FamilyRecordFixtureClient
    private let photo: MomentShareIngressPhoto
    init() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 180)).image { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
            UIImage(systemName: "cat.fill")?.draw(in: CGRect(x: 70, y: 40, width: 100, height: 100))
        }
        let jpeg = image.jpegData(compressionQuality: 0.8) ?? Data()
        photo = MomentShareIngressPhoto(canonicalJPEG: jpeg, capturedAt: nil, pixelWidth: 240, pixelHeight: 180)
        client = FamilyRecordFixtureClient(jpeg: jpeg)
    }
    var body: some View {
        FamilyRecordView(fixtureClient: client, fixturePhoto: photo)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("相手の追記") { Task { await client.addPeerWords(); refresh() } }
                        .accessibilityIdentifier("family-record-fixture-peer")
                    Button("退出") { Task { await client.leave(); refresh() } }
                        .accessibilityIdentifier("family-record-fixture-leave")
                }.buttonStyle(.bordered).padding(6)
            }
    }
    @MainActor private func refresh() {
        NotificationCenter.default.post(name: .momentSharingPresentationNeedsRefresh, object: nil)
    }
}

private actor FamilyRecordFixtureClient: FamilyRecordServing {
    private let space = "fixture_family_space"
    private let author = "fixture_family_author"
    private let peer = "fixture_family_peer"
    private let jpeg: Data
    private var active = true
    private var rows: [FamilyRecordRow] = []
    private var words: [String: String] = [:]
    private var receipts: [String: FamilyRecordRow] = [:]
    init(jpeg: Data) { self.jpeg = jpeg }
    private func requireActive() throws { guard active else { throw FamilyRecordError.unavailable } }
    func load() throws -> FamilyRecordSnapshot {
        try requireActive()
        return FamilyRecordSnapshot(catalog: .init(schemaVersion: 1, spaceID: space,
            participantID: author, maximumPhotos: 100, records: rows), words: words)
    }
    func photo(_ row: FamilyRecordRow) throws -> Data {
        try requireActive()
        guard rows.contains(where: { $0.id == row.id && $0.state == .active }) else { throw FamilyRecordError.changed }
        return jpeg
    }
    func preparePhoto(_ photo: MomentShareIngressPhoto) throws -> FamilyRecordMutation {
        try requireActive()
        let id = UUID().uuidString.lowercased()
        return operation(id: id, entryID: id, kind: .photo, revision: 0, text: "fixture-photo")
    }
    func prepareWords(_ text: String, entryID: String, replacing row: FamilyRecordRow?) throws -> FamilyRecordMutation {
        try requireActive()
        return operation(id: row?.id ?? UUID().uuidString.lowercased(), entryID: entryID, kind: .words,
            revision: row?.revision ?? 0, text: try FamilyRecordPayload.words(text).text)
    }
    func prepareWithdrawal(_ row: FamilyRecordRow) throws -> FamilyRecordMutation {
        try requireActive()
        return operation(id: row.id, entryID: row.entryID, kind: row.kind, revision: row.revision, text: nil)
    }
    private func operation(id: String, entryID: String, kind: FamilyRecordRow.Kind, revision: Int, text: String?) -> FamilyRecordMutation {
        FamilyRecordMutation(id: id, spaceID: space, authorID: author, lifecycleToken: nil,
            body: .init(entryID: entryID, kind: kind, expectedRevision: revision,
                operationID: UUID().uuidString.lowercased(), ciphertext: text))
    }
    func save(_ mutation: FamilyRecordMutation) throws -> FamilyRecordRow {
        try requireActive()
        guard mutation.spaceID == space, mutation.authorID == author else { throw FamilyRecordError.changed }
        if let result = receipts[mutation.body.operationID] { return result }
        let prior = rows.first { $0.id == mutation.id }
        guard prior?.authorID == nil || prior?.authorID == author,
              (prior?.revision ?? 0) == mutation.body.expectedRevision,
              prior?.state != .withdrawn else { throw FamilyRecordError.changed }
        let now = Date().timeIntervalSince1970
        let row = FamilyRecordRow(id: mutation.id, entryID: mutation.body.entryID, kind: mutation.body.kind,
            authorID: author, revision: mutation.body.expectedRevision + 1,
            state: mutation.body.ciphertext == nil ? .withdrawn : .active, keyEpoch: 1,
            ciphertext: nil, createdAt: prior?.createdAt ?? now, updatedAt: now)
        rows.removeAll { $0.id == row.id }; rows.append(row)
        if row.kind == .words { words[row.id] = mutation.body.ciphertext }
        receipts[mutation.body.operationID] = row
        return row
    }
    func addPeerWords() {
        guard active, let photo = rows.first(where: { $0.kind == .photo }) else { return }
        let id = UUID().uuidString.lowercased(), now = Date().timeIntervalSince1970
        rows.append(FamilyRecordRow(id: id, entryID: photo.id, kind: .words, authorID: peer,
            revision: 1, state: .active, keyEpoch: 1, ciphertext: nil, createdAt: now, updatedAt: now))
        words[id] = "相手が添えた言葉"
    }
    func leave() { active = false }
}
#endif
