import SwiftUI
import PhotosUI
import UIKit

struct EvacuationPreparationView: View {
    var profiles: [CatProfilePresentation]
    var unregisteredPhotos: [PhotoPresentation]
    @ObservedObject var store: EvacuationStore = .shared

    var body: some View {
        Group {
            if let error = store.loadError {
                ContentUnavailableView {
                    Label("備えを開けません", systemImage: "exclamationmark.folder")
                } description: { Text(error) } actions: { Button("再試行") { store.reload() } }
            } else {
                List {
                    Section {
                        NavigationLink { EvacuationPackingView(store: store) } label: {
                            entry("持ち出すものを見る", detail: "何を持つか、どこにあるか", icon: "backpack")
                        }
                        .accessibilityIdentifier("evacuation-packing-open")
                    }
                    Section {
                        NavigationLink {
                            EvacuationCatsView(profiles: profiles, otherPhotos: allPhotos, store: store)
                        } label: {
                            entry("猫の情報を見せる", detail: "写真・ごはん・必要な配慮", icon: "person.text.rectangle")
                        }
                        .accessibilityIdentifier("evacuation-cats-open")
                        NavigationLink { EvacuationDestinationsView(store: store) } label: {
                            entry("行き先と連絡先", detail: "候補と受入条件を残す", icon: "mappin.and.ellipse")
                        }
                        .accessibilityIdentifier("evacuation-destinations-open")
                    } footer: {
                        Text("保存した写真と入力内容は、通信がなくても開けます。外部サイトや送信には通信が必要です。")
                    }
                    Section {
                        Text("災害時は、ご自身と家族の安全を優先してください。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("避難に備える")
        .safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
    }

    private func entry(_ title: String, detail: String, icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }.padding(.vertical, 10)
        } icon: { Image(systemName: icon).foregroundStyle(Color.accentColor) }
    }

    private var allPhotos: [CatProfilePhotoPresentation] {
        var seen = Set<String>()
        let unregistered = unregisteredPhotos.map {
            CatProfilePhotoPresentation(localIdentifier: $0.localIdentifier, creationDate: $0.creationDate,
                                         catBoundingBox: $0.catBoundingBox)
        }
        return (profiles.flatMap { $0.confirmedPhotos + $0.manualCandidatePhotos } + unregistered)
            .filter { seen.insert($0.localIdentifier).inserted }
    }
}

private struct EvacuationSaveNotice: View {
    @ObservedObject var store: EvacuationStore
    var body: some View {
        if let error = store.saveError {
            VStack(spacing: 8) {
                Text(error).font(.footnote).foregroundStyle(.red)
                Button("保存を再試行") { store.retrySave() }
            }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
                .accessibilityIdentifier("evacuation-save-error")
        } else if store.pendingPhotoCleanup {
            VStack(spacing: 8) {
                Text("使わなくなった写真の削除が完了していません。").font(.footnote)
                Button("写真の削除を再試行") { store.retrySave() }
            }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
        }
    }
}

private struct EvacuationPackingView: View {
    @ObservedObject var store: EvacuationStore
    @State private var resetRequested = false
    private var needed: [EvacuationSupply] { store.plan.supplies.filter(\.isNeeded) }
    private var confirmedCount: Int { needed.filter { store.plan.carriedIDs.contains($0.id) }.count }

    var body: some View {
        List {
            Section {
                ForEach(needed) { item in
                    Button {
                        store.update {
                            if $0.carriedIDs.contains(item.id) { $0.carriedIDs.remove(item.id) }
                            else { $0.carriedIDs.insert(item.id) }
                            if $0.checkStartedAt == nil { $0.checkStartedAt = Date() }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: store.plan.carriedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title2).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title.isEmpty ? "名前未設定の持ち物" : item.title).foregroundStyle(.primary)
                                if let cat = store.plan.cats.first(where: { $0.id == item.catID }) {
                                    Text(cat.displayName).font(.caption).foregroundStyle(.secondary)
                                }
                                Text([item.quantity, item.location.isEmpty ? "置き場所は未設定" : item.location]
                                    .filter { !$0.isEmpty }.joined(separator: "・"))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.frame(minHeight: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(store.plan.carriedIDs.contains(item.id) ? "持出確認済み" : "未確認")
                    .accessibilityIdentifier("evacuation-supply-\(item.id.uuidString)")
                }
            } header: {
                Text("今回、持ったもの  \(confirmedCount) / \(needed.count)")
                    .accessibilityIdentifier("evacuation-packing-count")
            } footer: {
                if let date = store.plan.checkStartedAt {
                    Text("確認を始めた日：\(date.formatted(date: .numeric, time: .shortened))")
                } else { Text("持ったものにチェックします。備えが万全かを判定するものではありません。") }
            }
            Section {
                NavigationLink("リストと置き場所を編集") { EvacuationSuppliesEditor(store: store) }
                Button("次の確認を始める") { resetRequested = true }
                    .disabled(store.plan.carriedIDs.isEmpty)
            }
        }
        .navigationTitle("持ち出すもの")
        .confirmationDialog("今回のチェックだけを消します", isPresented: $resetRequested, titleVisibility: .visible) {
            Button("チェックを消す", role: .destructive) {
                store.update { $0.carriedIDs = []; $0.checkStartedAt = nil }
            }
        } message: { Text("持ち物と置き場所の記録は残ります。") }
        .safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
    }
}

private struct EvacuationSuppliesEditor: View {
    @ObservedObject var store: EvacuationStore
    var body: some View {
        List {
            Section {
                ForEach(store.plan.supplies) { item in
                    NavigationLink { EvacuationSupplyEditor(id: item.id, store: store) } label: {
                        VStack(alignment: .leading) {
                            Text(item.title.isEmpty ? "名前未設定の持ち物" : item.title)
                            Text(item.isNeeded ? (item.location.isEmpty ? "置き場所を追加" : item.location) : "今回の確認から除外")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("持ち物を追加", systemImage: "plus") {
                    store.update { $0.supplies.append(EvacuationSupply(title: "新しい持ち物")) }
                }.disabled(store.plan.supplies.count >= 200)
            } footer: { Text("共通の持ち物は1項目にまとめ、猫ごとの薬やフードは対象の猫を指定できます。") }
            Section("備蓄の目安") {
                Text("フード・水は最低5日分、できれば7日分が目安です。実際の量や持ち出し方は、この子とご家庭に合わせて確認してください。")
                    .font(.subheadline)
                Link("東京都の公式案内（通信が必要）", destination: URL(string: "https://www.hokeniryo.metro.tokyo.lg.jp/kankyo/aigo/bousai/doukou-hinan")!)
            }
        }.navigationTitle("リストを編集")
            .safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
    }
}

private struct EvacuationSupplyEditor: View {
    let id: UUID
    @ObservedObject var store: EvacuationStore
    @Environment(\.dismiss) private var dismiss
    @State private var deleteRequested = false
    private var item: EvacuationSupply? { store.plan.supplies.first { $0.id == id } }
    private func value<T>(_ key: WritableKeyPath<EvacuationSupply, T>, fallback: T) -> Binding<T> {
        Binding(get: { item?[keyPath: key] ?? fallback }, set: { new in
            store.update { plan in
                guard let index = plan.supplies.firstIndex(where: { $0.id == id }) else { return }
                plan.supplies[index][keyPath: key] = new
                plan.carriedIDs.remove(id)
            }
        })
    }
    var body: some View {
        Form {
            if item != nil {
                Section {
                    TextField("持ち物", text: value(\.title, fallback: ""))
                    TextField("量・個数（任意）", text: value(\.quantity, fallback: ""))
                    TextField("置き場所（例：玄関の防災バッグ）", text: value(\.location, fallback: ""))
                    Picker("誰の持ち物", selection: value(\.catID, fallback: Optional<UUID>.none)) {
                        Text("家で共通").tag(Optional<UUID>.none)
                        ForEach(store.plan.cats) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    Toggle("持出確認に含める", isOn: value(\.isNeeded, fallback: true))
                } footer: { Text("変更は自動で保存します。編集した項目の持出チェックは外れます。") }
                Section { Button("この持ち物を削除", role: .destructive) { deleteRequested = true } }
            }
        }.navigationTitle("持ち物と置き場所")
            .confirmationDialog("この持ち物を削除しますか？", isPresented: $deleteRequested, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if store.update({ $0.supplies.removeAll { $0.id == id }; $0.carriedIDs.remove(id) }) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
    }
}

private struct EvacuationCatsView: View {
    let profiles: [CatProfilePresentation]
    let otherPhotos: [CatProfilePhotoPresentation]
    @ObservedObject var store: EvacuationStore
    @State private var openedID: UUID?
    @State private var opensNewCat = false
    var body: some View {
        List {
            if !store.plan.cats.isEmpty {
                Section("備えを作った猫") {
                    ForEach(store.plan.cats) { cat in
                        NavigationLink { destination(cat.id) } label: {
                            Label(cat.displayName, systemImage: "cat")
                        }.accessibilityIdentifier("evacuation-cat-\(cat.id.uuidString)")
                    }
                }
            }
            let available = profiles.filter { profile in !store.plan.cats.contains { $0.profileID == profile.identifier } }
            Section {
                ForEach(available) { profile in
                    Button {
                        openNew(profileID: profile.identifier, name: profile.displayName)
                    } label: { Label("\(profile.displayName)の備えを作る", systemImage: "cat") }
                }
                Button("登録せずに猫の情報を作る", systemImage: "plus") { openNew() }
                    .accessibilityIdentifier("evacuation-add-guest")
                    .disabled(store.plan.cats.count >= 30)
            } footer: { Text("見せる写真と必要なことだけを準備できます。猫のプロフィール登録は不要です。") }
        }
        .navigationTitle("どの子の情報ですか？")
        .navigationDestination(isPresented: $opensNewCat) {
            if let openedID { destination(openedID) }
        }
        .safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
    }
    private func openNew(profileID: String? = nil, name: String = "") {
        if let id = store.addCat(profileID: profileID, name: name) { openedID = id; opensNewCat = true }
    }
    private func destination(_ id: UUID) -> some View {
        EvacuationCatView(id: id, profiles: profiles, otherPhotos: otherPhotos, store: store)
    }
}

private struct EvacuationCatView: View {
    let id: UUID
    let profiles: [CatProfilePresentation]
    let otherPhotos: [CatProfilePhotoPresentation]
    @ObservedObject var store: EvacuationStore
    @State private var disclosure = EvacuationDisclosure()
    @State private var preview: EvacuationPreviewItem?
    @State private var error: String?
    @State private var deleteRequested = false
    @Environment(\.dismiss) private var dismiss
    private var cat: EvacuationCat? { store.plan.cats.first { $0.id == id } }

    var body: some View {
        List {
            if let cat {
                Section {
                    HStack(spacing: 14) {
                        EvacuationPhoto(image: store.image(cat.photos["face"]), label: "顔の写真")
                            .frame(width: 80, height: 90)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(cat.displayName).font(.title2.bold())
                            Text(cat.features.isEmpty ? "特徴は未記入" : cat.features)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        EvacuationCatEditor(id: id,
                            ownPhotos: profiles.first(where: { $0.identifier == cat.profileID })?.confirmedPhotos ?? [],
                            otherPhotos: otherPhotos, store: store)
                    } label: { Label("写真やこの子の情報を編集", systemImage: "pencil") }
                        .accessibilityIdentifier("evacuation-cat-edit")
                }
                Section("見せる内容") {
                    Toggle("いつものごはん", isOn: $disclosure.food)
                    Toggle("接し方・苦手なこと", isOn: $disclosure.handling)
                    Toggle("病歴・薬", isOn: $disclosure.medical).accessibilityIdentifier("evacuation-disclose-medical")
                    Toggle("飼い主の連絡先", isOn: $disclosure.contact).accessibilityIdentifier("evacuation-disclose-contact")
                    if cat.photos["withOwner"] != nil { Toggle("飼い主と一緒の写真", isOn: $disclosure.withOwnerPhoto) }
                }
                Section {
                    Button("この内容を大きく見せる") {
                        do { preview = EvacuationPreviewItem(record: try store.shareRecord(catID: id, disclosure: disclosure)); error = nil }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("evacuation-preview-open")
                        .disabled(store.saveError != nil)
                    if let error { Text(error).foregroundStyle(.red) }
                } footer: { Text("写真・名前・特徴は表示します。病歴や連絡先は、必要な相手にだけ見せてください。") }
                Section {
                    Text("内容確認日：" + (cat.reviewedAt?.formatted(date: .numeric, time: .omitted) ?? "未確認"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("この子の内容を確認した") {
                        store.update { plan in
                            if let index = plan.cats.firstIndex(where: { $0.id == id }) { plan.cats[index].reviewedAt = Date() }
                        }
                    }
                    Button("この子の備えを削除", role: .destructive) { deleteRequested = true }
                }
            }
        }.navigationTitle("猫の情報を見せる")
            .navigationDestination(item: $preview) { EvacuationDisplayView(record: $0.record) }
            .confirmationDialog("この子の避難用の記録を削除しますか？", isPresented: $deleteRequested, titleVisibility: .visible) {
                Button("避難用の記録を削除", role: .destructive) {
                    if store.update({ $0.removeCat(id) }) { dismiss() }
                }
            } message: { Text("この子用の持ち物も削除します。元の写真・猫プロフィール・迷子の記録は残ります。") }
            .safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
    }
}

private struct EvacuationCatEditor: View {
    let id: UUID
    let ownPhotos: [CatProfilePhotoPresentation]
    let otherPhotos: [CatProfilePhotoPresentation]
    @ObservedObject var store: EvacuationStore
    @State private var photoRole: EvacuationCat.PhotoRole?
    private var cat: EvacuationCat? { store.plan.cats.first { $0.id == id } }
    private func text(_ key: WritableKeyPath<EvacuationCat, String>) -> Binding<String> {
        Binding(get: { cat?[keyPath: key] ?? "" }, set: { new in store.editCat(id) { $0[keyPath: key] = new } })
    }
    var body: some View {
        Form {
            if let cat {
                Section("写真と名前") {
                    TextField("名前（任意）", text: text(\.name)).accessibilityIdentifier("evacuation-cat-name")
                    ForEach(EvacuationCat.PhotoRole.allCases) { role in
                        Button { photoRole = role } label: {
                            HStack {
                                EvacuationPhoto(image: store.image(cat.photos[role.rawValue]), label: role.title)
                                    .frame(width: 62, height: 66)
                                Text(role.title).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("evacuation-photo-\(role.rawValue)")
                        if cat.photos[role.rawValue] != nil {
                            Button("\(role.title)を外す", role: .destructive) {
                                store.editCat(id) { $0.photos.removeValue(forKey: role.rawValue) }
                            }
                        }
                    }
                    TextField("見分ける特徴（任意）", text: text(\.features), axis: .vertical)
                }
                Section {
                    DisclosureGroup("いつものごはん") {
                        TextField("フード名・普段の量など", text: text(\.food), axis: .vertical)
                            .accessibilityIdentifier("evacuation-cat-food")
                    }
                    DisclosureGroup("接し方・苦手なこと") {
                        TextField("例：大きな音が苦手", text: text(\.handling), axis: .vertical)
                    }
                    DisclosureGroup("病歴・薬") {
                        Picker("病歴・薬の記録", selection: Binding(get: { cat.medicalStatus }, set: { new in
                            store.editCat(id) { $0.medicalStatus = new }
                        })) { ForEach(EvacuationCat.MedicalStatus.allCases, id: \.self) { Text($0.title).tag($0) } }
                        if cat.medicalStatus == .recorded {
                            TextField("獣医師から指示された内容など", text: text(\.medicalDetails), axis: .vertical)
                        }
                        Text("診断や薬の量の判断はしません。必要な相手に伝えるための記録です。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("必要なことだけ")
                } footer: { Text("空欄があっても使えます。変更は自動で保存します。見せる項目は前の画面で選べます。") }
                Section("家庭で共通の連絡先") {
                    TextField("相手に伝える連絡先（任意）", text: Binding(get: { store.plan.contact }, set: { new in
                        store.update { plan in
                            plan.contact = new
                            for index in plan.cats.indices { plan.cats[index].reviewedAt = nil }
                        }
                    }), axis: .vertical).accessibilityIdentifier("evacuation-contact")
                }
            }
        }.navigationTitle("この子の情報を編集")
            .sheet(item: $photoRole) { role in
                NavigationStack {
                    EvacuationPhotoPicker(catID: id, role: role, ownPhotos: ownPhotos, otherPhotos: otherPhotos, store: store)
                }
            }
            .safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
    }
}

private struct EvacuationPhoto: View {
    let image: UIImage?
    let label: String
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.secondarySystemGroupedBackground)) }
        }.clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityLabel(label)
    }
}

private struct EvacuationPhotoPicker: View {
    let catID: UUID
    let role: EvacuationCat.PhotoRole
    let ownPhotos: [CatProfilePhotoPresentation]
    let otherPhotos: [CatProfilePhotoPresentation]
    @ObservedObject var store: EvacuationStore
    @State private var item: PhotosPickerItem?
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var remaining: [CatProfilePhotoPresentation] {
        let own = Set(ownPhotos.map(\.localIdentifier))
        return otherPhotos.filter { !own.contains($0.localIdentifier) }
    }
    var body: some View {
        List {
            Section {
                PhotosPicker(selection: $item, matching: .images) { Label("写真アプリから選ぶ", systemImage: "photo.badge.plus") }
                    .disabled(busy)
            } footer: { Text("選んだ写真のコピーをこの端末に保存します。顔や柄が分かる写真を選んでください。") }
            if !ownPhotos.isEmpty { grid("この子の写真", ownPhotos) }
            if !remaining.isEmpty { grid("ほかの猫写真から選ぶ", remaining) }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(role.title)
        .toolbar { Button("キャンセル") { dismiss() }.disabled(busy) }
        .interactiveDismissDisabled(busy)
        .overlay { if busy { ProgressView("写真を保存中…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .onChange(of: item) { _, value in
            guard let value, !busy else { return }
            busy = true; error = nil
            Task {
                do {
                    guard let data = try await value.loadTransferable(type: Data.self) else { throw EvacuationStorageError.photoUnavailable }
                    try store.replacePhoto(data, catID: catID, role: role)
                    busy = false; dismiss()
                } catch { self.error = "写真を保存できませんでした。元の写真は変更していません。通信や空き容量を確認して、選び直してください。"; busy = false; item = nil }
            }
        }
    }
    private func grid(_ title: String, _ photos: [CatProfilePhotoPresentation]) -> some View {
        Section(title) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 95))], spacing: 10) {
                ForEach(photos) { photo in
                    Button {
                        busy = true; error = nil
                        Task {
                            do {
                                let data = try await PhotoLibraryJPEGExporter().export(localIdentifier: photo.localIdentifier)
                                try store.replacePhoto(data.jpeg, catID: catID, role: role)
                                busy = false; dismiss()
                            } catch { self.error = "この写真を保存できません。写真アプリから選び直すこともできます。"; busy = false }
                        }
                    } label: {
                        PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                            targetPixelSize: CGSize(width: 300, height: 300), targetAspectRatio: 1, showsFullImage: true)
                            .aspectRatio(1, contentMode: .fit)
                    }.buttonStyle(.plain).disabled(busy)
                        .accessibilityLabel("この写真を使う")
                        .accessibilityIdentifier("evacuation-candidate-\(photo.localIdentifier)")
                }
            }
        }
    }
}

private struct EvacuationPreviewItem: Identifiable, Hashable {
    let id = UUID()
    let record: EvacuationShareRecord
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct EvacuationDisplayView: View {
    let record: EvacuationShareRecord
    @State private var export: EvacuationExporter.Export?
    @State private var retainedDirectory: URL?
    @State private var wantsPrint: Bool?
    @State private var confirmShare = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(record.name).font(.largeTitle.bold())
                ForEach(Array(record.photos.enumerated()), id: \.offset) { _, photo in
                    Image(uiImage: photo).resizable().scaledToFit().accessibilityLabel("共有に含める写真")
                }
                if record.photos.isEmpty { Label("識別用の写真は未設定", systemImage: "photo").foregroundStyle(.secondary) }
                ForEach(Array(record.fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(field.0).font(.subheadline).foregroundStyle(.secondary)
                        Text(field.1).font(.title3).textSelection(.enabled)
                    }
                }
                Text("内容確認日：" + (record.reviewedAt?.formatted(date: .numeric, time: .omitted) ?? "未確認"))
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                Button("家族に送る", systemImage: "square.and.arrow.up") { wantsPrint = false; confirmShare = true }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("evacuation-share-images")
                Button("印刷して持つ", systemImage: "printer") { wantsPrint = true; confirmShare = true }
                    .buttonStyle(.bordered).accessibilityIdentifier("evacuation-share-pdf")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .navigationTitle("この子の避難メモ").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("evacuation-share-preview")
        .disabled(busy)
        .confirmationDialog("表示中の内容を控えにします", isPresented: $confirmShare, titleVisibility: .visible) {
            Button(wantsPrint == true ? "PDFを作って保存・印刷" : "画像を作って送信先を選ぶ") { createExport() }
        } message: {
            Text((record.includesPrivateInformation ? "病歴・連絡先・飼い主の写真のうち、選択した内容を含みます。渡す相手を確認してください。\n" : "")
                 + "渡した控えは、あとから編集しても更新されません。長い内容は複数ページになります。")
        }
        .sheet(item: $export, onDismiss: {
            if let retainedDirectory { EvacuationExporter.remove(retainedDirectory) }
            retainedDirectory = nil
        }) { EvacuationActivitySheet(items: $0.files) }
    }
    private func createExport() {
        busy = true
        do {
            let made = try EvacuationExporter.create(record, printCopy: wantsPrint == true)
            retainedDirectory = made.directory; export = made; error = nil
        } catch { self.error = "控えを作れませんでした。空き容量や記録の長さを確認してください。元の記録は残っています。" }
        busy = false
    }
}

private struct EvacuationActivitySheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct EvacuationDestinationsView: View {
    @ObservedObject var store: EvacuationStore
    var body: some View {
        List {
            Section {
                ForEach(store.plan.destinations) { place in
                    NavigationLink { EvacuationDestinationEditor(id: place.id, store: store) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(place.name.isEmpty ? "行き先の候補" : place.name).font(.headline)
                            Text(place.checkedAt.map { "受入条件の確認日：" + $0.formatted(date: .numeric, time: .omitted) } ?? "受入条件は未確認")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if !place.conditions.isEmpty { Text(place.conditions).font(.subheadline) }
                            if !place.telephone.isEmpty { Text(place.telephone).font(.subheadline) }
                        }
                    }
                }
                Button("行き先の候補を追加", systemImage: "plus") {
                    store.update { $0.destinations.append(EvacuationDestination()) }
                }.disabled(store.plan.destinations.count >= 30)
            } footer: { Text("避難先で猫を受け入れる条件を、自治体や施設に事前に確認してください。ここでは最新の受入状況を判定しません。") }
            Section("家族の集合メモ") {
                TextField("家族で決めた場所や連絡方法", text: Binding(get: { store.plan.familyMeetingMemo }, set: { new in
                    store.update { $0.familyMeetingMemo = new }
                }), axis: .vertical)
            }
            Section {
                Text("同行避難は、人と猫が同じ部屋で過ごせることを意味しません。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Link("環境省の公式案内（通信が必要）", destination: URL(string: "https://www.env.go.jp/nature/dobutsu/aigo/1_law/disaster.html")!)
            }
        }.navigationTitle("行き先と連絡先")
            .safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
    }
}

private struct EvacuationDestinationEditor: View {
    let id: UUID
    @ObservedObject var store: EvacuationStore
    @State private var deleteRequested = false
    @Environment(\.dismiss) private var dismiss
    private var place: EvacuationDestination? { store.plan.destinations.first { $0.id == id } }
    private func text(_ key: WritableKeyPath<EvacuationDestination, String>) -> Binding<String> {
        Binding(get: { place?[keyPath: key] ?? "" }, set: { new in
            store.update { plan in
                if let index = plan.destinations.firstIndex(where: { $0.id == id }) {
                    plan.destinations[index][keyPath: key] = new; plan.destinations[index].checkedAt = nil
                }
            }
        })
    }
    var body: some View {
        Form {
            if let place {
                Section("行き先の候補") {
                    TextField("施設名", text: text(\.name))
                    TextField("電話番号（任意）", text: text(\.telephone))
                    TextField("確認した受入条件", text: text(\.conditions), axis: .vertical)
                    TextField("確認先（窓口や公式ページなど）", text: text(\.source), axis: .vertical)
                }
                Section {
                    if let date = place.checkedAt {
                        DatePicker("自分で確認した日", selection: Binding(get: { date }, set: { new in
                            store.update { plan in
                                if let index = plan.destinations.firstIndex(where: { $0.id == id }) { plan.destinations[index].checkedAt = new }
                            }
                        }), in: ...Date(), displayedComponents: .date)
                    } else {
                        Text("受入条件は未確認").foregroundStyle(.secondary)
                        Button("自分で受入条件を確認した") {
                            store.update { plan in
                                if let index = plan.destinations.firstIndex(where: { $0.id == id }) { plan.destinations[index].checkedAt = Date() }
                            }
                        }.disabled([place.name, place.conditions, place.source].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    }
                } footer: { Text("自分で確認した内容と日付の記録です。現在の空きや受入を保証するものではありません。内容を編集すると未確認に戻ります。") }
                Section { Button("この候補を削除", role: .destructive) { deleteRequested = true } }
            }
        }.navigationTitle("候補を編集")
            .confirmationDialog("この候補を削除しますか？", isPresented: $deleteRequested, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if store.update({ $0.destinations.removeAll { $0.id == id } }) { dismiss() }
                }
            }.safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
    }
}
