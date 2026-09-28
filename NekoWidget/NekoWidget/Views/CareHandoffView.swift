import SwiftUI
import PhotosUI
import UIKit

struct CareHandoffView: View {
    var profiles: [CatProfilePresentation]
    var unregisteredPhotos: [PhotoPresentation]
    @ObservedObject var store: CareHandoffStore = .shared
    @State private var newCatID: UUID?
    @State private var opensNewCat = false

    var body: some View {
        Group {
            if let error = store.loadError {
                ContentUnavailableView {
                    Label("お世話メモを開けません", systemImage: "exclamationmark.folder")
                } description: { Text(error) } actions: { Button("再試行") { store.reload() } }
            } else {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("いつものお世話を\nそのまま伝える").font(.title2.bold())
                            Text("ごはんの量も、この子の苦手も。写真付きのメモを作って渡せます。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                    Section("猫ごとのお世話メモ") {
                        ForEach(store.plan.cats) { cat in
                            NavigationLink { editor(cat.id) } label: {
                                HStack(spacing: 12) {
                                    CarePhoto(image: store.image(cat.photoName)).frame(width: 64, height: 64)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(cat.displayName).font(.headline)
                                        Text(cat.meals.first.map { $0.food.isEmpty ? "お世話の内容を記入" : $0.food } ?? "お世話の内容を記入")
                                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }.padding(.vertical, 4)
                            }.accessibilityIdentifier("care-cat-\(cat.id.uuidString)")
                        }
                        Button(store.plan.cats.isEmpty ? "お世話メモを作る" : "猫を追加", systemImage: "plus") { addCat() }
                            .accessibilityIdentifier("care-add-cat").disabled(store.plan.cats.count >= 20)
                        let available = profiles.filter { profile in !store.plan.cats.contains { $0.profileID == profile.identifier } }
                        if !available.isEmpty {
                            Menu("登録した猫から作る") {
                                ForEach(available) { profile in
                                    Button(profile.displayName) { addCat(profileID: profile.identifier, name: profile.displayName) }
                                }
                            }.disabled(store.plan.cats.count >= 20)
                        }
                    }
                    if !store.plan.cats.isEmpty {
                        Section {
                            NavigationLink { CareRequestEditor(store: store) } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("今回のお願い").font(.headline)
                                        Text("相手・期間・連絡先").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: "calendar") }
                            }.accessibilityIdentifier("care-request-open")
                            NavigationLink { CareDisclosureView(store: store) } label: {
                                Label("渡す内容を確認", systemImage: "doc.text.image").font(.headline)
                            }.accessibilityIdentifier("care-disclosure-open").disabled(store.saveError != nil)
                        } footer: {
                            Text("相手はアプリなしで読めます。作ったメモは次に預けるときも使えます。")
                        }
                    }
                }
            }
        }
        .navigationTitle("預けるとき").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $opensNewCat) { if let newCatID { editor(newCatID) } }
        .safeAreaInset(edge: .bottom) { CareSaveNotice(store: store) }
    }
    private func addCat(profileID: String? = nil, name: String = "") {
        if let id = store.addCat(profileID: profileID, name: name) { newCatID = id; opensNewCat = true }
    }
    private func editor(_ id: UUID) -> some View {
        let profileID = store.plan.cats.first(where: { $0.id == id })?.profileID
        let own = profiles.first(where: { $0.identifier == profileID })?.confirmedPhotos ?? []
        var seen = Set<String>()
        let other = (profiles.flatMap { $0.confirmedPhotos + $0.manualCandidatePhotos }
            + unregisteredPhotos.map { CatProfilePhotoPresentation(localIdentifier: $0.localIdentifier,
                creationDate: $0.creationDate, catBoundingBox: $0.catBoundingBox) })
            .filter { seen.insert($0.localIdentifier).inserted }
        return CareCatEditor(id: id, ownPhotos: own, otherPhotos: other, store: store)
    }
}

private struct CareSaveNotice: View {
    @ObservedObject var store: CareHandoffStore
    var body: some View {
        if let error = store.saveError {
            VStack(spacing: 8) {
                Text(error).font(.footnote).foregroundStyle(.red)
                Button("保存を再試行") { store.retrySave() }
            }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
                .accessibilityIdentifier("care-save-error")
        } else if store.pendingPhotoCleanup {
            VStack(spacing: 8) {
                Text("使わなくなった写真の削除が完了していません。").font(.footnote)
                Button("写真の削除を再試行") { store.retrySave() }
            }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
        }
    }
}

private struct CareField: View {
    let label: String
    let example: String
    let identifier: String
    @Binding var text: String
    var limit = 4000
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.medium))
            TextField(example, text: Binding(get: { text }, set: { text = String($0.prefix(limit)) }), axis: .vertical)
                .lineLimit(1...8).frame(minHeight: 36)
                .accessibilityLabel(label).accessibilityIdentifier(identifier)
        }.padding(.vertical, 4)
    }
}

private struct CareCatEditor: View {
    let id: UUID
    let ownPhotos: [CatProfilePhotoPresentation]
    let otherPhotos: [CatProfilePhotoPresentation]
    @ObservedObject var store: CareHandoffStore
    @State private var showsPhotoPicker = false
    @State private var deleteRequested = false
    @Environment(\.dismiss) private var dismiss
    private var cat: CareCat? { store.plan.cats.first { $0.id == id } }
    private func text(_ key: WritableKeyPath<CareCat, String>) -> Binding<String> {
        Binding(get: { cat?[keyPath: key] ?? "" }, set: { new in store.editCat(id) { $0[keyPath: key] = new } })
    }
    private func mealText(_ mealID: UUID, _ key: WritableKeyPath<CareMeal, String>) -> Binding<String> {
        Binding(get: { cat?.meals.first(where: { $0.id == mealID })?[keyPath: key] ?? "" }, set: { new in
            store.editCat(id) { cat in
                if let index = cat.meals.firstIndex(where: { $0.id == mealID }) { cat.meals[index][keyPath: key] = new }
            }
        })
    }
    var body: some View {
        Form {
            if let cat {
                Section {
                    CareField(label: "猫の名前", example: "例：むぎ", identifier: "care-cat-name", text: text(\.name), limit: 80)
                    Button { showsPhotoPicker = true } label: {
                        HStack(spacing: 16) {
                            CarePhoto(image: store.image(cat.photoName)).frame(width: 88, height: 88)
                            Label(cat.photoName == nil ? "写真を選ぶ" : "写真を変える", systemImage: "photo")
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("care-photo-open")
                    if cat.photoName != nil {
                        Button("このメモの写真を外す", role: .destructive) { store.editCat(id) { $0.photoName = nil } }
                    }
                }
                Section {
                    CareField(label: "まず伝えたいこと", example: "例：玄関を開ける前に、猫が別の部屋にいるか確認", identifier: "care-important", text: text(\.important))
                } footer: { Text("必ず守ってほしいことを先頭に載せます。空欄のままでも保存できます。") }
                ForEach(Array(cat.meals.enumerated()), id: \.element.id) { index, meal in
                    Section("ごはん \(index + 1)") {
                        CareField(label: "時間", example: "例：朝8時", identifier: "care-meal-time-\(index)", text: mealText(meal.id, \.time))
                        CareField(label: "フード", example: "いつものフード名", identifier: "care-meal-food-\(index)", text: mealText(meal.id, \.food))
                        CareField(label: "量", example: "例：20g（単位も記入）", identifier: "care-meal-amount-\(index)", text: mealText(meal.id, \.amount))
                        if cat.meals.count > 1 {
                            Button("このごはんを外す", role: .destructive) { store.editCat(id) { $0.meals.removeAll { $0.id == meal.id } } }
                        }
                    }
                }
                Section {
                    Button("ごはんの時間を追加", systemImage: "plus") { store.editCat(id) { $0.meals.append(CareMeal()) } }
                        .disabled(cat.meals.count >= 8)
                }
                Section("ふだんのお世話") {
                    CareField(label: "水", example: "器の場所・取り替え方", identifier: "care-water", text: text(\.water))
                    CareField(label: "トイレ", example: "掃除のタイミング・砂や袋の場所", identifier: "care-toilet", text: text(\.toilet))
                    CareField(label: "接し方・苦手なこと", example: "例：隠れていたら無理に抱かず、そっとしておく", identifier: "care-handling", text: text(\.handling))
                }
                Section {
                    DisclosureGroup("薬・アレルギー") {
                        Picker("記録の状態", selection: Binding(get: { cat.healthStatus }, set: { new in
                            store.editCat(id) { $0.healthStatus = new }
                        })) {
                            ForEach(CareCat.HealthStatus.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        if cat.healthStatus == .recorded {
                            CareField(label: "伝える内容", example: "獣医師からの指示、薬の名前・時間・量など", identifier: "care-health", text: text(\.healthDetails))
                        }
                        Text("獣医師から指示された内容を記入してください。薬の量の判断や計算はしません。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: { Text("薬・連絡先を渡すかどうかは、最後の確認画面で選べます。") }
                Section {
                    Button("このお世話メモを削除", role: .destructive) { deleteRequested = true }
                } footer: { Text("入力した内容はこの端末に自動保存します。") }
            }
        }
        .navigationTitle("お世話メモを編集").navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("入力を閉じる") {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        } } }
        .sheet(isPresented: $showsPhotoPicker) {
            NavigationStack { CarePhotoPicker(catID: id, ownPhotos: ownPhotos, otherPhotos: otherPhotos, store: store) }
        }
        .confirmationDialog("この子のお世話メモを削除しますか？", isPresented: $deleteRequested, titleVisibility: .visible) {
            Button("お世話メモを削除", role: .destructive) {
                if store.update({ $0.cats.removeAll { $0.id == id } }) { dismiss() }
            }
        } message: { Text("このツールの記録と写真のコピーだけを削除します。元の写真・猫プロフィール・他のツールの記録は残ります。") }
        .safeAreaInset(edge: .bottom) { CareSaveNotice(store: store) }
    }
}

private struct CareRequestEditor: View {
    @ObservedObject var store: CareHandoffStore
    private func text(_ key: WritableKeyPath<CareHandoffPlan, String>) -> Binding<String> {
        Binding(get: { store.plan[keyPath: key] }, set: { new in store.update { $0[keyPath: key] = new } })
    }
    var body: some View {
        Form {
            Section {
                CareField(label: "お願いする相手", example: "例：お母さん", identifier: "care-recipient", text: text(\.recipient))
                CareField(label: "期間", example: "例：10月5日 夜〜10月7日 朝", identifier: "care-period", text: text(\.period))
                CareField(label: "今回のお願い", example: "例：お世話が終わったら写真を1枚送ってください", identifier: "care-request", text: text(\.request))
            } footer: { Text("次に預けるときは、ここだけ書き換えて使えます。住所や鍵の番号は別の方法で伝えてください。") }
            Section {
                CareField(label: "飼い主の連絡先", example: "名前と電話番号など", identifier: "care-contact", text: text(\.contact))
                CareField(label: "つながらないときの連絡先", example: "連絡できる人の名前と電話番号", identifier: "care-backup", text: text(\.backupContact))
                CareField(label: "かかりつけの動物病院", example: "病院名・電話番号・必要な連絡事項", identifier: "care-vet", text: text(\.veterinarian))
            } header: { Text("連絡が必要なとき")
            } footer: { Text("連絡先は、渡す前に選んだ場合だけ控えに載せます。") }
        }.navigationTitle("今回のお願い").navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { CareSaveNotice(store: store) }
    }
}

private struct CarePhoto: View {
    let image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "cat").font(.title2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.tertiarySystemFill)) }
        }.clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel(image == nil ? "写真は未設定" : "この子の写真")
    }
}

private struct CarePhotoPicker: View {
    let catID: UUID
    let ownPhotos: [CatProfilePhotoPresentation]
    let otherPhotos: [CatProfilePhotoPresentation]
    @ObservedObject var store: CareHandoffStore
    @State private var item: PhotosPickerItem?
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                PhotosPicker(selection: $item, matching: .images) { Label("写真アプリから選ぶ", systemImage: "photo.badge.plus") }
                    .disabled(busy)
            } footer: { Text("預かる人が見分けやすい写真を選びます。この端末にコピーを保存するので、通信がなくても開けます。") }
            if !ownPhotos.isEmpty { grid("この子の写真", ownPhotos) }
            let own = Set(ownPhotos.map(\.localIdentifier))
            let remaining = otherPhotos.filter { !own.contains($0.localIdentifier) }
            if !remaining.isEmpty { grid("ほかの猫写真", remaining) }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("写真を選ぶ")
            .toolbar { Button("キャンセル") { dismiss() }.disabled(busy) }
            .interactiveDismissDisabled(busy)
            .overlay { if busy { ProgressView("写真を保存中…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .onChange(of: item) { _, value in
                guard let value, !busy else { return }
                busy = true; error = nil
                Task {
                    do {
                        guard let data = try await value.loadTransferable(type: Data.self) else { throw CareHandoffError.photoUnavailable }
                        try store.replacePhoto(data, catID: catID); busy = false; dismiss()
                    } catch { self.error = "写真を保存できませんでした。通信や空き容量を確認して選び直してください。元の写真は変更していません。"; busy = false; item = nil }
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
                                try store.replacePhoto(data.jpeg, catID: catID); busy = false; dismiss()
                            } catch { self.error = "この写真を保存できません。写真アプリから選び直すこともできます。"; busy = false }
                        }
                    } label: {
                        PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                            targetPixelSize: CGSize(width: 300, height: 300), targetAspectRatio: 1, showsFullImage: true)
                            .aspectRatio(1, contentMode: .fit)
                    }.buttonStyle(.plain).disabled(busy).accessibilityLabel("この写真を使う")
                }
            }
        }
    }
}

private struct CarePreview: Identifiable, Hashable {
    let id = UUID()
    let record: CareHandoffShareRecord
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct CareDisclosureView: View {
    @ObservedObject var store: CareHandoffStore
    @State private var disclosure = CareHandoffDisclosure()
    @State private var initialized = false
    @State private var preview: CarePreview?
    @State private var error: String?
    var body: some View {
        List {
            Section("今回お願いする猫") {
                ForEach(store.plan.cats) { cat in
                    Toggle(isOn: Binding(get: { disclosure.catIDs.contains(cat.id) }, set: { selected in
                        if selected { disclosure.catIDs.insert(cat.id) } else { disclosure.catIDs.remove(cat.id) }
                    })) { Text(cat.displayName) }.accessibilityIdentifier("care-select-\(cat.id.uuidString)")
                }
            }
            Section {
                Toggle("薬・アレルギーを含める", isOn: $disclosure.health).accessibilityIdentifier("care-disclose-health")
                Toggle("連絡先・動物病院を含める", isOn: $disclosure.contacts).accessibilityIdentifier("care-disclose-contacts")
            } header: { Text("必要な相手に渡す情報")
            } footer: { Text("写真・名前・お世話・今回のお願いは載せます。薬や連絡先は、渡す相手に合わせて選んでください。") }
            Section {
                Button("この内容でプレビュー", systemImage: "doc.text.magnifyingglass") {
                    do { preview = CarePreview(record: try store.shareRecord(disclosure)); error = nil }
                    catch { self.error = (error as? CareHandoffError)?.errorDescription ?? "控えを開けません。元の記録は残っています。" }
                }.font(.headline).disabled(disclosure.catIDs.isEmpty || store.saveError != nil)
                    .accessibilityIdentifier("care-preview-open")
                if let error { Text(error).foregroundStyle(.red) }
            }
        }.navigationTitle("渡す内容を確認").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if !initialized {
                    if store.plan.cats.count == 1, let cat = store.plan.cats.first { disclosure.catIDs = [cat.id] }
                    initialized = true
                }
            }
            .navigationDestination(item: $preview) { CareDisplayView(record: $0.record) }
            .safeAreaInset(edge: .bottom) { CareSaveNotice(store: store) }
    }
}

private struct CareDisplayView: View {
    let record: CareHandoffShareRecord
    @State private var export: CareHandoffExporter.Export?
    @State private var retainedDirectory: URL?
    @State private var pdf = false
    @State private var confirmShare = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("お世話メモ").font(.largeTitle.bold())
                if !record.includesHealth { Label("薬・アレルギーは含めていません", systemImage: "info.circle").font(.subheadline) }
                if !record.includesContacts { Label("連絡先・動物病院は含めていません", systemImage: "info.circle").font(.subheadline) }
                fields(record.commonFields)
                ForEach(Array(record.cats.enumerated()), id: \.offset) { _, cat in
                    VStack(alignment: .leading, spacing: 18) {
                        Text(cat.name).font(.title.bold())
                        if let photo = cat.photo { Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 260).accessibilityLabel("渡す猫の写真") }
                        else { Text("写真は未設定").foregroundStyle(.secondary) }
                        fields(cat.fields)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                }
                Text("渡した控えは自動更新されません。内容が変わったら、新しい控えを渡してください。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(16)
        }.background(Color(.systemGroupedBackground))
            .navigationTitle("プレビュー").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                ViewThatFits(in: .horizontal) {
                    HStack { shareButton("画像で渡す", pdf: false); shareButton("PDFで渡す", pdf: true) }
                    VStack { shareButton("画像で渡す", pdf: false); shareButton("PDFで渡す", pdf: true) }
                }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
            }
            .confirmationDialog("表示中の内容を控えにします", isPresented: $confirmShare, titleVisibility: .visible) {
                Button(pdf ? "PDFを作って渡す" : "画像を作って渡す") { createExport() }
            } message: {
                Text("次の画面で送信先を選びます。渡す相手を確認してください。長い内容や複数の猫は複数ページになります。")
            }
            .sheet(item: $export, onDismiss: {
                if let retainedDirectory { CareHandoffExporter.remove(retainedDirectory) }
                retainedDirectory = nil
            }) { CareActivitySheet(items: $0.files) }
    }
    private func fields(_ values: [(String, String)]) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
            VStack(alignment: .leading, spacing: 6) {
                Text(value.0).font(.subheadline).foregroundStyle(.secondary)
                Text(value.1).font(.body).textSelection(.enabled)
            }
        }
    }
    private func shareButton(_ title: String, pdf: Bool) -> some View {
        Button { self.pdf = pdf; confirmShare = true } label: {
            Label(title, systemImage: pdf ? "doc" : "photo").frame(maxWidth: .infinity).padding(.vertical, 4)
        }.buttonStyle(.borderedProminent).accessibilityIdentifier(pdf ? "care-share-pdf" : "care-share-images")
    }
    private func createExport() {
        do {
            let made = try CareHandoffExporter.create(record, pdf: pdf)
            retainedDirectory = made.directory; export = made; error = nil
        } catch { self.error = "控えを作れませんでした。空き容量やメモの長さを確認してください。元の記録は残っています。" }
    }
}

private struct CareActivitySheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
