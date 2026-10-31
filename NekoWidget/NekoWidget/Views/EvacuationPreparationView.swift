import SwiftUI
import PhotosUI
import UIKit

struct EvacuationPreparationView: View {
    var profiles: [CatProfilePresentation]
    var unregisteredPhotos: [PhotoPresentation]
    @ObservedObject var store: EvacuationStore = .shared
    @ObservedObject var reuseStore: CareHandoffStore = .shared
    @AppStorage("evacuation-review-reminder-dismissed") private var reminderDismissedAt: Double = 0
    @State private var confirmBook = false
    @State private var book: EvacuationExporter.Export?
    @State private var retainedBookDirectory: URL?
    @State private var bookError: String?

    var body: some View {
        Group {
            if let error = store.loadError {
                ContentUnavailableView {
                    Label("避難の備えを開けませんでした", systemImage: "exclamationmark.folder")
                } description: { Text(error) } actions: { Button("もう一度読み込む") { store.reload() } }
            } else {
                List {
                    if showsReviewReminder {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("半年ごとの見直し").font(.headline)
                                Text("前に確かめてから半年以上たちました。")
                                    .font(.subheadline)
                            }
                            Button("閉じる") { reminderDismissedAt = Date().timeIntervalSince1970 }
                        }
                        .accessibilityIdentifier("evacuation-review-reminder")
                    }
                    Section {
                        NavigationLink { EvacuationPackingView(store: store) } label: {
                            entry("持ち出すもの", detail: "何を持つか、どこにあるか", icon: "backpack")
                        }
                        .accessibilityIdentifier("evacuation-packing-open")
                        NavigationLink {
                            EvacuationCatsView(profiles: profiles, otherPhotos: allPhotos, store: store, reuseStore: reuseStore)
                        } label: {
                            entry("猫の情報", detail: "写真・ごはん・必要な配慮", icon: "person.text.rectangle")
                        }
                        .accessibilityIdentifier("evacuation-cats-open")
                        NavigationLink { EvacuationDestinationsView(store: store) } label: {
                            entry("行き先と連絡先", detail: "行き先と、受け入れの条件", icon: "mappin.and.ellipse")
                        }
                        .accessibilityIdentifier("evacuation-destinations-open")
                    }
                    Section {
                        Button { confirmBook = true } label: {
                            Label("1冊のPDFにまとめる", systemImage: "book.closed")
                                .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.bordered)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .disabled(store.saveError != nil)
                        .accessibilityIdentifier("evacuation-book-open")
                        if let bookError { Text(bookError).foregroundStyle(.red) }
                    }
                    Section {
                        ToolImportantInformation(text: "災害のときは、まず自分と家族の安全を守ってください。")
                    }
                }
            }
        }
        .navigationTitle("避難に備える").navigationBarTitleDisplayMode(.inline)
        .announcesWhenShown(bookError)
        .safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
        .task {
            CatCareStore.shared.importFromTools()
            CatCareStore.shared.importBirthdays(profiles)
        }
        .confirmationDialog("1冊のPDFを作ります", isPresented: $confirmBook, titleVisibility: .visible) {
            Button("PDFを作る") { makeBook() }
        } message: {
            Text("病歴・薬・連絡先・ワクチン・マイクロチップ番号も載ります。")
        }
        .sheet(item: $book, onDismiss: {
            // The item is already cleared here; remove the copy this screen made.
            if let retainedBookDirectory { EvacuationExporter.remove(retainedBookDirectory) }
            retainedBookDirectory = nil
        }) { EvacuationActivitySheet(items: $0.files) }
    }

    private func makeBook() {
        do {
            let made = try EvacuationExporter.createBook(store.bookRecords())
            retainedBookDirectory = made.directory; book = made
            bookError = nil
        } catch {
            bookError = (error as? EvacuationStorageError)?.errorDescription
                ?? "PDFを作れませんでした。空き容量や記録の長さを確かめてください。"
        }
    }

    /// Shown once each half year after the last time the owner checked something.
    private var showsReviewReminder: Bool {
        let checked = store.plan.cats.compactMap(\.reviewedAt) + store.plan.destinations.compactMap(\.checkedAt)
        guard let last = checked.max() else { return false }
        let halfYear: TimeInterval = 182 * 24 * 60 * 60
        return Date().timeIntervalSince(last) > halfYear
            && Date().timeIntervalSince1970 - reminderDismissedAt > halfYear
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
                Button("もう一度保存する") { store.retrySave() }
            }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
                .accessibilityIdentifier("evacuation-save-error")
        } else if store.pendingPhotoCleanup {
            VStack(spacing: 8) {
                Text("使わなくなった写真のコピーが残っています。").font(.footnote)
                Button("コピーを消す") { store.retrySave() }
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
                                Text(item.title.isEmpty ? "名前のない持ち物" : item.title).foregroundStyle(.primary)
                                if let cat = store.plan.cats.first(where: { $0.id == item.catID }) {
                                    Text(cat.displayName).font(.caption).foregroundStyle(.secondary)
                                }
                                Text([item.quantity, item.location.isEmpty ? "置き場所は未記入" : item.location]
                                    .filter { !$0.isEmpty }.joined(separator: "・"))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(store.plan.carriedIDs.contains(item.id) ? "持った" : "まだ")
                    .accessibilityIdentifier("evacuation-supply-\(item.id.uuidString)")
                }
            } header: {
                Text("今回、持ったもの  \(confirmedCount) / \(needed.count)")
                    .accessibilityIdentifier("evacuation-packing-count")
            } footer: {
                if let date = store.plan.checkStartedAt {
                    Text("チェックを始めた日：\(date.formatted(date: .numeric, time: .shortened))")
                }
            }
            Section {
                NavigationLink("リストと置き場所を編集") { EvacuationSuppliesEditor(store: store) }
                Button("チェックをやり直す") { resetRequested = true }
                    .disabled(store.plan.carriedIDs.isEmpty)
            }
        }
        .navigationTitle("持ち出すもの").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("チェックをすべて外しますか？", isPresented: $resetRequested, titleVisibility: .visible) {
            Button("すべて外す", role: .destructive) {
                store.update { $0.carriedIDs = []; $0.checkStartedAt = nil }
            }
        } message: { Text("持ち物と置き場所は消えません。") }
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
                            Text(item.title.isEmpty ? "名前のない持ち物" : item.title)
                            Text(item.isNeeded ? (item.location.isEmpty ? "置き場所を追加" : item.location) : "チェックリストに入れていない")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("持ち物を追加", systemImage: "plus") {
                    store.update { $0.supplies.append(EvacuationSupply(title: "新しい持ち物")) }
                }.disabled(store.plan.supplies.count >= 200)
                Button("おすすめの持ち物を足す", systemImage: "checklist") { addRecommended() }
                    .disabled(store.plan.supplies.count >= 200)
                    .accessibilityIdentifier("evacuation-add-recommended")
            }
            Section("備蓄の目安") {
                Text("フード・水は最低5日分、できれば7日分が目安です。")
                    .font(.subheadline)
                Link("東京都の公式案内（通信が必要）", destination: URL(string: "https://www.hokeniryo.metro.tokyo.lg.jp/kankyo/aigo/bousai/doukou-hinan")!)
            }
        }.navigationTitle("リストを編集").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
    }

    /// Adds what is missing; nothing already on the list is changed. A cat with
    /// medicine in 「この子のこと」 gets its own medicine item.
    private func addRecommended() {
        let medicines = store.plan.cats.map { cat in
            (cat.id, (CatCareSummary.record(toolCatID: cat.toolCatID ?? cat.id, profileIdentifier: cat.profileID)?
                .activeMedications ?? []).map(\.name).filter { !$0.isEmpty })
        }
        store.update { plan in
            plan.addRecommendedSupplies()
            for (catID, names) in medicines where !names.isEmpty {
                let title = "薬：" + names.joined(separator: "・")
                if let index = plan.supplies.firstIndex(where: { $0.catID == catID && $0.title.hasPrefix("薬") }) {
                    // An item this app made follows the current medicines; one the owner renamed stays.
                    if plan.supplies[index].title.hasPrefix("薬：") { plan.supplies[index].title = title }
                } else if plan.supplies.count < 200 {
                    plan.supplies.append(EvacuationSupply(title: title, quantity: "5日分以上", catID: catID))
                }
            }
        }
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
                    Toggle("チェックリストに入れる", isOn: value(\.isNeeded, fallback: true))
                } footer: { Text("直した持ち物は、チェックが外れます。") }
                Section { Button("この持ち物を削除", role: .destructive) { deleteRequested = true } }
            }
        }.navigationTitle("持ち物と置き場所").navigationBarTitleDisplayMode(.inline)
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
    @ObservedObject var reuseStore: CareHandoffStore
    @AppStorage("evacuation.lastCat.v1") private var lastCatID = ""
    @State private var openedID: UUID?
    @State private var couldNotOpen = false

    /// The cats in the row: profiles, this tool's cats without a profile, and
    /// cats written in 預けるとき that can be copied here.
    private var stripCats: [ToolStripCat] {
        let guests = store.plan.cats.filter { cat in !profiles.contains { $0.identifier == cat.profileID } }
        return profiles.map { ToolStripCat(id: $0.identifier, name: $0.displayName, profile: $0,
                                           accessibilityIdentifier: "tool-profile-\($0.identifier)") }
            + guests.map { ToolStripCat(id: $0.id.uuidString, name: $0.displayName, profile: nil,
                                        accessibilityIdentifier: "evacuation-cat-\($0.id.uuidString)") }
            + availableSavedCats.map { ToolStripCat(id: "saved-" + $0.id.uuidString, name: $0.displayName, profile: nil,
                                                    accessibilityIdentifier: "evacuation-saved-\($0.id.uuidString)") }
    }

    private var selectedStripID: String? {
        guard let openedID, let cat = store.plan.cats.first(where: { $0.id == openedID }) else { return nil }
        if let profileID = cat.profileID, profiles.contains(where: { $0.identifier == profileID }) { return profileID }
        return cat.id.uuidString
    }

    var body: some View {
        Group {
            if stripCats.isEmpty {
                // No cat yet: add one here.
                List { ToolCatPicker(profiles: profiles, select: { select(profileID: $0.identifier, name: $0.displayName) }) {} }
                    .navigationTitle("猫の情報").navigationBarTitleDisplayMode(.inline)
                    .safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
            } else if let id = openedID, store.plan.cats.contains(where: { $0.id == id }) {
                // The chosen cat's page, with the row of cats above it to switch in place.
                destination(id)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        ToolCatStrip(cats: stripCats, selectedID: selectedStripID) { select($0) }
                    }
            } else {
                List {
                    if couldNotOpen {
                        Text("猫の情報を作れませんでした。上の猫をもう一度押してください。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("猫の情報").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top, spacing: 0) {
                    ToolCatStrip(cats: stripCats, selectedID: nil) { select($0) }
                }
                .safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
            }
        }
        .task {
            guard openedID == nil,
                  let first = stripCats.first(where: { $0.id == lastCatID }) ?? stripCats.first else { return }
            select(first)
        }
    }

    /// Opens the cat in place: its page, made now if this is the first time.
    private func select(_ cat: ToolStripCat) {
        couldNotOpen = false
        if let profile = cat.profile {
            select(profileID: profile.identifier, name: profile.displayName)
            return
        }
        if cat.id.hasPrefix("saved-"), let sourceID = UUID(uuidString: String(cat.id.dropFirst(6))) {
            if let id = store.addCat(using: reuseStore, sourceCatID: sourceID) { openedID = id } else { couldNotOpen = true }
        } else if let id = UUID(uuidString: cat.id) {
            openedID = id
        }
        lastCatID = cat.id
    }
    private func select(profileID: String, name: String) {
        couldNotOpen = false
        let matches = store.plan.cats.filter { $0.profileID == profileID }
        if let cat = matches.max(by: { $0.updatedAt < $1.updatedAt }) {
            if cat.name != name { store.editCat(cat.id) { $0.name = name } }
            openedID = cat.id
        } else if let id = store.addCat(profileID: profileID, name: name, using: reuseStore) {
            openedID = id
        } else {
            couldNotOpen = true
        }
        lastCatID = profileID
    }
    private var availableSavedCats: [CareCat] {
        guard reuseStore.loadError == nil, reuseStore.saveError == nil else { return [] }
        return reuseStore.plan.cats.filter { source in
            !store.plan.cats.contains { target in
                (source.profileID != nil && target.profileID == source.profileID)
                    || (target.toolCatID ?? target.id) == (source.toolCatID ?? source.id)
            } && !profiles.contains { $0.identifier == source.profileID }
        }
    }
    private func destination(_ id: UUID) -> some View {
        EvacuationCatView(id: id, profiles: profiles, otherPhotos: otherPhotos, store: store, reuseStore: reuseStore)
    }
}

private struct EvacuationCatView: View {
    let id: UUID
    let profiles: [CatProfilePresentation]
    let otherPhotos: [CatProfilePhotoPresentation]
    @ObservedObject var store: EvacuationStore
    @ObservedObject var reuseStore: CareHandoffStore
    /// Redraws when 「この子のこと」 changes, for example after 「この子のことを直す」.
    @ObservedObject private var catCare = CatCareStore.shared
    @State private var disclosure = EvacuationDisclosure()
    @State private var preview: EvacuationPreviewItem?
    @State private var error: String?
    @State private var deleteRequested = false
    @Environment(\.dismiss) private var dismiss
    private var cat: EvacuationCat? { store.plan.cats.first { $0.id == id } }

    private func catCareRecord(_ cat: EvacuationCat) -> CatCareRecord? {
        CatCareSummary.record(toolCatID: cat.toolCatID ?? cat.id, profileIdentifier: cat.profileID)
    }

    var body: some View {
        List {
            if let cat {
                Section {
                    ToolAdaptiveStack {
                        EvacuationPhoto(image: store.image(cat.photos["face"] ?? cat.photos["body"] ?? cat.photos["reference"]), label: "この子の写真")
                            .frame(width: 80, height: 90)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(profiles.first(where: { $0.identifier == cat.profileID })?.displayName ?? cat.displayName).font(.title2.bold())
                            Text(CatCareSummary.features(catCareRecord(cat), legacy: cat.features) ?? "特徴は未記入")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        EvacuationCatEditor(id: id,
                            ownPhotos: profiles.first(where: { $0.identifier == cat.profileID })?.confirmedPhotos ?? [],
                            otherPhotos: otherPhotos, store: store, reuseStore: reuseStore, profiles: profiles)
                    } label: { Label("避難用の写真を選ぶ", systemImage: "photo") }
                        .accessibilityIdentifier("evacuation-cat-edit")
                }
                ToolCatCareSection(
                    title: "この子のこと",
                    lines: CatCareSummary.evacuationShareFields(catCareRecord(cat), legacy: cat,
                        household: catCare.state?.household, planContact: store.plan.contact,
                        disclosure: EvacuationDisclosure(food: true, handling: true, medical: true, contact: true,
                                                         withOwnerPhoto: false, catCare: true)),
                    subject: profiles.first(where: { $0.identifier == cat.profileID }).map(CatCareSubject.profile)
                        ?? .toolCat(id: cat.toolCatID ?? cat.id, name: cat.name),
                    identifier: "evacuation-cat-care-fields", editIdentifier: "evacuation-open-cat-care")
                Section {
                    Toggle("いつものごはん", isOn: $disclosure.food)
                    Toggle("接し方・苦手なこと", isOn: $disclosure.handling)
                    Toggle("病歴・薬・アレルギー", isOn: $disclosure.medical).accessibilityIdentifier("evacuation-disclose-medical")
                    Toggle("飼い主の連絡先", isOn: $disclosure.contact).accessibilityIdentifier("evacuation-disclose-contact")
                    if cat.photos["withOwner"] != nil { Toggle("飼い主と一緒の写真", isOn: $disclosure.withOwnerPhoto) }
                    Toggle("ワクチン・マイクロチップ番号", isOn: $disclosure.catCare)
                        .accessibilityIdentifier("evacuation-disclose-cat-care")
                } header: {
                    Text("見せる内容")
                }
                Section {
                    if let error { Text(error).foregroundStyle(.red) }
                    ToolImportantInformation(text: "病歴・連絡先・ワクチンの証明・マイクロチップ番号は、必要な相手にだけ見せてください。")
                }
                Section {
                    Text("内容を確かめた日：" + (cat.reviewedAt?.formatted(date: .numeric, time: .omitted) ?? "未確認"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("内容を確かめた") {
                        store.update { plan in
                            if let index = plan.cats.firstIndex(where: { $0.id == id }) {
                                plan.cats[index].reviewedAt = Date()
                                plan.cats[index].prefilledFields = []
                            }
                        }
                    }
                    Button("この子の避難用の記録を削除", role: .destructive) { deleteRequested = true }
                }
            }
        }.navigationTitle("猫の情報を見せる").navigationBarTitleDisplayMode(.inline)
            .announcesWhenShown(error)
            .safeAreaInset(edge: .bottom) {
                Button {
                    do { preview = EvacuationPreviewItem(record: try store.shareRecord(catID: id, disclosure: disclosure)); error = nil }
                    catch {
                        self.error = (error as? EvacuationStorageError)?.errorDescription
                            ?? "表示できませんでした。もう一度お試しください。"
                    }
                } label: {
                    Label("できあがりを見る", systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.saveError != nil || cat == nil)
                .accessibilityIdentifier("evacuation-preview-open")
                .padding().background(.regularMaterial)
            }
            .navigationDestination(item: $preview) { EvacuationDisplayView(record: $0.record) }
            .confirmationDialog("この子の避難用の記録を削除しますか？", isPresented: $deleteRequested, titleVisibility: .visible) {
                Button("避難用の記録を削除", role: .destructive) {
                    if store.update({ $0.removeCat(id) }) { dismiss() }
                }
            } message: { Text("この子用の持ち物も一緒に削除します。") }
            .safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
    }
}

private struct EvacuationCatEditor: View {
    let id: UUID
    let ownPhotos: [CatProfilePhotoPresentation]
    let otherPhotos: [CatProfilePhotoPresentation]
    @ObservedObject var store: EvacuationStore
    @ObservedObject var reuseStore: CareHandoffStore
    var profiles: [CatProfilePresentation] = []
    @State private var photoRole: EvacuationCat.PhotoRole?
    @State private var refreshedCandidates = false
    @State private var candidateRefreshError = false
    private var cat: EvacuationCat? { store.plan.cats.first { $0.id == id } }
    private func text(_ key: WritableKeyPath<EvacuationCat, String>) -> Binding<String> {
        Binding(get: { cat?[keyPath: key] ?? "" }, set: { new in store.editCat(id) { $0[keyPath: key] = new } })
    }
    var body: some View {
        Form {
            if let cat {
                if candidateRefreshError {
                    Text("前に入れた内容を読み込めませんでした。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let profile = profiles.first(where: { $0.identifier == cat.profileID }) {
                    ToolCatProfileInfo(profile: profile, profiles: profiles)
                }
                Section("写真と名前") {
                    if !profiles.contains(where: { $0.identifier == cat.profileID }) {
                        TextField("名前（任意）", text: text(\.name)).accessibilityIdentifier("evacuation-cat-name")
                            .foregroundStyle(Color.primary)
                    }
                    ForEach(EvacuationCat.PhotoRole.allCases.filter { $0 != .reference || cat.photos["reference"] != nil }) { role in
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
                }
            }
        }.navigationTitle("避難用の写真").navigationBarTitleDisplayMode(.inline)
            .task {
                guard !refreshedCandidates else { return }
                refreshedCandidates = true
                do { try store.refreshCandidates(id, using: reuseStore) }
                catch { candidateRefreshError = true }
            }
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
            } footer: { Text("顔や柄が分かる写真を選んでください。") }
            if !ownPhotos.isEmpty { grid("この子の写真", ownPhotos) }
            if !remaining.isEmpty { grid("ほかの猫の写真", remaining) }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(role.title).navigationBarTitleDisplayMode(.inline)
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
                } catch { self.error = "写真を保存できませんでした。通信や空き容量を確かめて、もう一度選んでください。"; busy = false; item = nil }
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
                            } catch { self.error = "この写真は使えませんでした。「写真アプリから選ぶ」から選び直せます。"; busy = false }
                        }
                    } label: {
                        PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                            targetPixelSize: CGSize(width: 300, height: 300), targetAspectRatio: 1, showsFullImage: true)
                            .aspectRatio(1, contentMode: .fit)
                    }.buttonStyle(.plain).disabled(busy)
                        .accessibilityLabel(ToolPhotoLabel.text("この写真を使う", date: photo.creationDate))
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
                    Image(uiImage: photo).resizable().scaledToFit().accessibilityLabel("載せる写真")
                }
                if record.photos.isEmpty { Label("見分けるための写真はまだありません", systemImage: "photo").foregroundStyle(.secondary) }
                ForEach(Array(record.fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(field.0).font(.subheadline).foregroundStyle(.secondary)
                        Text(field.1).font(.title3).textSelection(.enabled)
                    }
                }
                ForEach(Array(record.attachments.enumerated()), id: \.offset) { _, attachment in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(attachment.0).font(.subheadline).foregroundStyle(.secondary)
                        Image(uiImage: attachment.1).resizable().scaledToFit().accessibilityLabel(attachment.0)
                    }
                }
                Text("内容を確かめた日：" + (record.reviewedAt?.formatted(date: .numeric, time: .omitted) ?? "未確認"))
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }

            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .navigationTitle("プレビュー").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            ViewThatFits {
                HStack(spacing: 12) { exportButtons }
                VStack(spacing: 8) { exportButtons }
            }
            .padding().background(.regularMaterial)
        }
        .accessibilityIdentifier("evacuation-share-preview")
        .disabled(busy)
        .confirmationDialog("この内容で作りますか？", isPresented: $confirmShare, titleVisibility: .visible) {
            Button(wantsPrint == true ? "PDFを作って渡す" : "画像を作って渡す") { createExport() }
        } message: {
            Text(record.includesPrivateInformation
                 ? "選んだ病歴や連絡先が載るので、渡す相手を確かめてください。"
                 : "渡したあとに書き直しても、相手の手元の内容は変わりません。")
        }
        .sheet(item: $export, onDismiss: {
            if let retainedDirectory { EvacuationExporter.remove(retainedDirectory) }
            retainedDirectory = nil
        }) { EvacuationActivitySheet(items: $0.files) }
    }
    @ViewBuilder private var exportButtons: some View {
        Button { wantsPrint = true; confirmShare = true } label: {
            Label("PDFで渡す", systemImage: "doc").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent).accessibilityIdentifier("evacuation-share-pdf")
        Button { wantsPrint = false; confirmShare = true } label: {
            Label("画像で渡す", systemImage: "photo").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered).accessibilityIdentifier("evacuation-share-images")
    }

    private func createExport() {
        busy = true
        do {
            let made = try EvacuationExporter.create(record, printCopy: wantsPrint == true)
            retainedDirectory = made.directory; export = made; error = nil
        } catch { self.error = "作れませんでした。空き容量や記録の長さを確かめてください。" }
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
                            Text(place.checkedAt.map { "受け入れの条件を確かめた日：" + $0.formatted(date: .numeric, time: .omitted) } ?? "受け入れの条件はまだ確かめていません")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if !place.conditions.isEmpty { Text(place.conditions).font(.subheadline) }
                            if !place.telephone.isEmpty { Text(place.telephone).font(.subheadline) }
                        }
                    }
                }
                Button("行き先の候補を追加", systemImage: "plus") {
                    store.update { $0.destinations.append(EvacuationDestination()) }
                }.disabled(store.plan.destinations.count >= 30)
            } footer: { Text("猫を受け入れてもらえるか、前もって自治体や施設に確かめてください。") }
            Section("家族の集合場所と連絡方法") {
                TextField("家族で決めた場所や連絡方法", text: Binding(get: {
                    CatCareStore.shared.state?.household.meetingPlace == nil
                        ? store.plan.familyMeetingMemo : CatCareStore.shared.householdText(\.meetingPlace)
                }, set: { new in
                    // One place: 「この子のこと」's household, read by every tool.
                    CatCareStore.shared.setHouseholdText(new, \.meetingPlace)
                    store.update { $0.familyMeetingMemo = new }
                }), axis: .vertical)
            }
            Section {
                Link(destination: URL(string: "https://www.env.go.jp/nature/dobutsu/aigo/1_law/disaster.html")!) {
                    ExternalLinkRow("環境省の案内を見る", systemImage: "safari")
                }
            }
        }.navigationTitle("行き先と連絡先").navigationBarTitleDisplayMode(.inline)
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
                    TextField("確かめた受け入れの条件", text: text(\.conditions), axis: .vertical)
                    TextField("どこで確かめたか（窓口や公式ページなど）", text: text(\.source), axis: .vertical)
                }
                Section {
                    if let date = place.checkedAt {
                        DatePicker("確かめた日", selection: Binding(get: { date }, set: { new in
                            store.update { plan in
                                if let index = plan.destinations.firstIndex(where: { $0.id == id }) { plan.destinations[index].checkedAt = new }
                            }
                        }), in: ...Date(), displayedComponents: .date)
                    } else {
                        Text("受け入れの条件は、まだ確かめていません").foregroundStyle(.secondary)
                        Button("受け入れの条件を確かめた") {
                            store.update { plan in
                                if let index = plan.destinations.firstIndex(where: { $0.id == id }) { plan.destinations[index].checkedAt = Date() }
                            }
                        }.disabled([place.name, place.conditions, place.source].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    }
                } footer: { Text("避難するときの空きは、そのときに施設に確かめてください。") }
                Section { Button("この候補を削除", role: .destructive) { deleteRequested = true } }
            }
        }.navigationTitle("候補を編集").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("この候補を削除しますか？", isPresented: $deleteRequested, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if store.update({ $0.destinations.removeAll { $0.id == id } }) { dismiss() }
                }
            }.safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }
    }
}
