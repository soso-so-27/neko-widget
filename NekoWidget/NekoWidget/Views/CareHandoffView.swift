import SwiftUI
import PhotosUI
import UIKit

struct CareHandoffView: View {
    var profiles: [CatProfilePresentation]
    var unregisteredPhotos: [PhotoPresentation]
    @ObservedObject var store: CareHandoffStore = .shared
    @ObservedObject var reuseStore: EvacuationStore = .shared
    @AppStorage("careHandoff.lastCat.v1") private var lastCatID = ""
    @AppStorage(CatFarewell.key) private var farewellJSON = ""
    @State private var selectedCatID: UUID?
    @State private var couldNotOpen = false
    @State private var countedOpen = false
    @Environment(\.membershipActions) private var actionAccess

    /// The cats in the row: profiles, this tool's cats without a profile, and
    /// cats written in 避難に備える that can be copied here.
    private var stripCats: [ToolStripCat] {
        let guests = store.plan.cats.filter { cat in !profiles.contains { $0.identifier == cat.profileID } }
        return profiles.map { ToolStripCat(id: $0.identifier, name: $0.displayName, profile: $0,
                                           accessibilityIdentifier: "tool-profile-\($0.identifier)") }
            + guests.map { ToolStripCat(id: $0.id.uuidString, name: $0.displayName, profile: nil,
                                        accessibilityIdentifier: "care-cat-\($0.id.uuidString)") }
            + availableSavedCats.map { ToolStripCat(id: "saved-" + $0.id.uuidString, name: $0.displayName, profile: nil,
                                                    accessibilityIdentifier: "care-saved-\($0.id.uuidString)") }
    }

    private var selectedStripID: String? {
        guard let selectedCatID, let cat = store.plan.cats.first(where: { $0.id == selectedCatID }) else { return nil }
        if let profileID = cat.profileID, profiles.contains(where: { $0.identifier == profileID }) { return profileID }
        return cat.id.uuidString
    }

    var body: some View {
        Group {
            if let error = store.loadError {
                ContentUnavailableView {
                    Label("お世話メモを開けません", systemImage: "exclamationmark.folder")
                } description: { Text(error) } actions: { Button("もう一度読み込む") { store.reload() } }
            } else if stripCats.isEmpty {
                // No cat yet: add one here.
                List { ToolCatPicker(profiles: profiles, select: { select(profileID: $0.identifier, name: $0.displayName) }, purpose: "猫を追加すると、預ける人に渡すメモを作れます。") {} }
                    .safeAreaInset(edge: .bottom) { CareSaveNotice(store: store) }
            } else if let id = selectedCatID, store.plan.cats.contains(where: { $0.id == id }) {
                // The chosen cat's memo, with the row of cats above it to switch in place.
                editor(id)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        ToolCatStrip(cats: stripCats, selectedID: selectedStripID) { select($0) }
                    }
            } else {
                List {
                    if couldNotOpen {
                        Text("お世話メモを作れませんでした。上の猫をもう一度押してください。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        // No memo open, e.g. right after one was deleted (11/7).
                        Section {
                            Text("お世話メモはありません。").foregroundStyle(.secondary)
                            ForEach(openableCats.count == 1 ? openableCats : []) { cat in
                                Button("\(cat.name)のお世話メモを作る") { select(cat) }
                                    .accessibilityIdentifier("care-create-\(cat.id)")
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    ToolCatStrip(cats: stripCats, selectedID: nil) { select($0) }
                }
                .safeAreaInset(edge: .bottom) { CareSaveNotice(store: store) }
            }
        }
        .navigationTitle("預けるとき").navigationBarTitleDisplayMode(.inline)
        .familyNotebookToolSync()
        .task {
            // Usage (11/7): once per opening, not again after a pushed screen.
            if !countedOpen { countedOpen = true; UsageCounter.shared.count(.toolCareHandoff) }
            store.retryPhotoCleanup()
            guard selectedCatID == nil, store.loadError == nil else { return }
            openFirst()
        }
        // The first cat, added from 「猫を追加」, opens at once (11/7).
        .onChange(of: profiles.map(\.identifier)) { old, _ in
            guard old.isEmpty, selectedCatID == nil, store.loadError == nil,
                  let added = openableCats.first(where: { $0.profile != nil }) else { return }
            select(added)
        }
    }

    /// Value of lastCatID after a memo is deleted: reopening then opens only a
    /// memo that is still there, never makes the deleted one again (11/7).
    private static let afterDelete = "deleted"

    /// The cats a tool may open by itself: not one whose farewell day is recorded.
    private var openableCats: [ToolStripCat] {
        stripCats.filter { !$0.isDeparted(farewellJSON) }
    }

    /// Opens the last cat, or the first. Right after a delete, only a cat
    /// whose memo already exists, so nothing is made without a tap.
    private func openFirst() {
        let cats = openableCats
        if lastCatID == Self.afterDelete {
            let existing = cats.first { cat in
                if let profile = cat.profile { return store.plan.cats.contains { $0.profileID == profile.identifier } }
                return !cat.id.hasPrefix("saved-")
            }
            if let existing { select(existing) }
            return
        }
        guard let first = cats.first(where: { $0.id == lastCatID }) ?? cats.first else { return }
        select(first)
    }

    /// Opens the cat in place: its memo, made now if this is the first time.
    private func select(_ cat: ToolStripCat) {
        couldNotOpen = false
        if let profile = cat.profile {
            select(profileID: profile.identifier, name: profile.displayName)
            return
        }
        if cat.id.hasPrefix("saved-"), let sourceID = UUID(uuidString: String(cat.id.dropFirst(6))) {
            addCat(sourceCatID: sourceID)
        } else if let id = UUID(uuidString: cat.id) {
            selectedCatID = id
        }
        lastCatID = cat.id
    }
    private func select(profileID: String, name: String) {
        couldNotOpen = false
        let matches = store.plan.cats.filter { $0.profileID == profileID }
        if let cat = matches.max(by: { $0.updatedAt < $1.updatedAt }) {
            if cat.name != name { store.editCat(cat.id) { $0.name = name } }
            selectedCatID = cat.id
        } else {
            addCat(profileID: profileID, name: name)
        }
        lastCatID = profileID
    }
    private func addCat(profileID: String? = nil, name: String = "", sourceCatID: UUID? = nil) {
        // 預けるときは無料のツール（ADR-027）。nil は重複や保存エラーで、
        // そのときは store の案内がそのまま表示される。
        if let id = store.addCat(profileID: profileID, name: name, using: reuseStore,
            sourceCatID: sourceCatID, access: actionAccess) {
            selectedCatID = id
        } else {
            couldNotOpen = true
        }
    }
    private var availableSavedCats: [EvacuationCat] {
        guard reuseStore.loadError == nil, reuseStore.saveError == nil else { return [] }
        return reuseStore.plan.cats.filter { source in
            !store.plan.cats.contains { target in
                (source.profileID != nil && target.profileID == source.profileID)
                    || (target.toolCatID ?? target.id) == (source.toolCatID ?? source.id)
            } && !profiles.contains { $0.identifier == source.profileID }
        }
    }
    private func editor(_ id: UUID) -> some View {
        let profileID = store.plan.cats.first(where: { $0.id == id })?.profileID
        let own = profiles.first(where: { $0.identifier == profileID })?.confirmedPhotos ?? []
        var seen = Set<String>()
        let other = (profiles.flatMap { $0.confirmedPhotos + $0.manualCandidatePhotos }
            + unregisteredPhotos.map { CatProfilePhotoPresentation(localIdentifier: $0.localIdentifier,
                creationDate: $0.creationDate, catBoundingBox: $0.catBoundingBox) })
            .filter { seen.insert($0.localIdentifier).inserted }
        return CareCatEditor(id: id, ownPhotos: own, otherPhotos: other, store: store, reuseStore: reuseStore,
                             profiles: profiles,
                             onDeleted: {
                                 // Stay here: the next memo, or none (11/7: it left the tool).
                                 lastCatID = Self.afterDelete
                                 selectedCatID = nil
                                 openFirst()
                             })
    }
}

private struct CareSaveNotice: View {
    @ObservedObject var store: CareHandoffStore
    var body: some View {
        if let error = store.saveError {
            VStack(spacing: 8) {
                Text(error).font(.footnote).foregroundStyle(.red)
                Button("もう一度保存する") { store.retrySave() }
            }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
                .accessibilityIdentifier("care-save-error")
        }
        // 11/8: a photo copy left behind is removed again in the background
        // (CareHandoffStore.retryPhotoCleanup), not shown as a task here.
    }
}

private struct CareField: View {
    let label: String
    let example: String
    let identifier: String
    @Binding var text: String
    var limit = 4000
    var isPrefilled = false
    /// Off when the step's heading already says the same words (11/8 型).
    var showsLabel = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsLabel || isPrefilled {
                HStack {
                    if showsLabel { Text(label).font(.subheadline.weight(.medium)) }
                    if isPrefilled { Text("前に入れた内容").font(.caption).foregroundStyle(.secondary) }
                }
            }
            TextField(example, text: Binding(get: { text }, set: { text = String($0.prefix(limit)) }), axis: .vertical)
                .lineLimit(1...8).frame(minHeight: 36)
                .foregroundStyle(Color.primary)
                .accessibilityLabel(label).accessibilityIdentifier(identifier)
        }.padding(.vertical, 4)
    }
}

private struct CareCatEditor: View {
    let id: UUID
    let ownPhotos: [CatProfilePhotoPresentation]
    let otherPhotos: [CatProfilePhotoPresentation]
    @ObservedObject var store: CareHandoffStore
    @ObservedObject var reuseStore: EvacuationStore
    var profiles: [CatProfilePresentation] = []
    /// Set when the memo is the tool's page: it stays after a delete.
    var onDeleted: (() -> Void)? = nil
    /// Redraws when 「この子のこと」 changes, for example after 「この子のことを直す」.
    @ObservedObject private var catCare = CatCareStore.shared
    @State private var showsPhotoPicker = false
    @State private var deleteRequested = false
    @State private var refreshedCandidates = false
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
    /// Common signs to call about. The owner picks; nothing is judged here.
    static let callWhenChoices = ["丸1日ごはんを食べない", "何度も吐く", "おしっこが出ていない",
                                  "隠れて出てこない", "ぐったりしている", "けがをした", "外に出てしまった"]

    /// Everyday care and health, from 「この子のこと」 only: one place for each
    /// cat, so a second copy here can never disagree with it.
    @ViewBuilder private func catCareSection(_ cat: CareCat) -> some View {
        let care = CatCareSummary.record(toolCatID: cat.toolCatID ?? cat.id, profileIdentifier: cat.profileID)
        let health = CatCareSummary.careHandoffHealthLines(care, legacy: cat)
        // 11/8: the cat's own vet is shown here; the household contacts are
        // shown once, where the memo is made.
        let vet = CareHandoffDisclosure.vetFields(plan: store.plan, household: catCare.state?.household, record: care)
        let subject: CatCareSubject = profiles.first(where: { $0.identifier == cat.profileID }).map(CatCareSubject.profile)
            ?? .toolCat(id: cat.toolCatID ?? cat.id, name: cat.name)
        // 11/8: no footer; what goes on the memo is chosen on the next page.
        ToolCatCareSection(title: "この子のこと",
                           lines: CatCareSummary.careHandoffLines(care, legacy: cat) + health + vet, subject: subject,
                           identifier: "care-cat-care-fields", editIdentifier: "care-open-cat-care", profiles: profiles,
                           folded: true)
    }

    /// Where the three steps stand (11/8 型): photo, what to say first, when to call.
    private func stepStates(_ cat: CareCat) -> [ToolStepState] {
        ToolStepState.states([cat.photoName != nil, Self.isFilled(cat.important), Self.isFilled(cat.callWhen)])
    }
    static func isFilled(_ text: String?) -> Bool {
        !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            if let cat {
                let states = stepStates(cat)
                Section { ToolPurpose(text: "預ける人に渡すお世話メモを作ります。") }
                // 11/8 型: numbered steps first, what is written this time above
                // what is read from 「この子のこと」.
                Section {
                    if let profile = profiles.first(where: { $0.identifier == cat.profileID }) {
                        // The cat's dates are in この子のこと below; the name stays here (11/7).
                        LabeledContent("猫の名前", value: profile.displayName)
                    } else {
                        CareField(label: "猫の名前", example: "例：むぎ", identifier: "care-cat-name", text: text(\.name), limit: 80,
                                  isPrefilled: cat.prefilledFields?.contains("name") == true)
                    }
                    ToolPhotoGrid {
                        ToolPhotoSlot("渡す写真", image: nil, file: store.imageURL(cat.photoName),
                                      identifier: "care-photo-open", actionsIdentifier: "care-photo-actions",
                                      choose: { showsPhotoPicker = true }) {
                            Button("写真を選び直す", systemImage: "photo") { showsPhotoPicker = true }
                            Button("このメモの写真を外す", systemImage: "minus.circle", role: .destructive) {
                                store.editCat(id) { $0.photoName = nil; $0.photoRemoved = true }
                            }
                        }
                    }
                } header: { ToolStepHeader(number: 1, title: "名前と写真", state: states[0]) }
                Section {
                    CareField(label: "まず伝えたいこと", example: "例：玄関を開ける前に、猫が別の部屋にいるか確認", identifier: "care-important", text: text(\.important),
                              showsLabel: false)
                } header: { ToolStepHeader(number: 2, title: "まず伝えたいこと", state: states[1]) }
                Section {
                    CareField(label: "こんなときは連絡を", example: "例：丸1日ごはんを食べない、何度も吐く、トイレに行ってもおしっこが出ない",
                              identifier: "care-call-when",
                              text: Binding(get: { self.cat?.callWhen ?? "" }, set: { new in
                                  store.editCat(id) { $0.callWhen = new.isEmpty ? nil : new }
                              }), showsLabel: false)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.callWhenChoices, id: \.self) { choice in
                                let current = cat.callWhen ?? ""
                                Button(choice) {
                                    store.editCat(id) { $0.callWhen = current.isEmpty ? choice : current + "、" + choice }
                                }
                                .buttonStyle(.bordered).font(.footnote)
                                .disabled(current.contains(choice))
                            }
                        }
                    }
                    .accessibilityIdentifier("care-call-when-choices")
                } header: { ToolStepHeader(number: 3, title: "こんなときは連絡を", state: states[2]) }
                catCareSection(cat)
                // Period and request are written once, where the memo is made
                // (347: a family cat had a second form here, and what was typed
                // there replaced the memo's own). Family cats get the same values.
                // 11/8 型: notes last and small; delete alone in the last section.
                if cat.familyDetached == true {
                    Section {
                        Text("このメモは、家族の手帳には入っていません。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("このお世話メモを削除", role: .destructive) { deleteRequested = true }
                }
            }
        }
        .toolPageSpacing()
        .navigationTitle("預けるとき").navigationBarTitleDisplayMode(.inline)
        .task {
            CatCareStore.shared.importFromTools()
            CatCareStore.shared.importBirthdays(profiles)
            guard !refreshedCandidates else { return }
            refreshedCandidates = true
            await Self.fillFromCatCare(id, store: store, reuseStore: reuseStore, profiles: profiles)
        }
        .sheet(isPresented: $showsPhotoPicker) {
            NavigationStack { CarePhotoPicker(catID: id, ownPhotos: ownPhotos, otherPhotos: otherPhotos, store: store) }
        }
        .confirmationDialog("この子のお世話メモを削除しますか？", isPresented: $deleteRequested, titleVisibility: .visible) {
            Button("お世話メモを削除", role: .destructive) {
                if store.update({ $0.cats.removeAll { $0.id == id } }) {
                    if let onDeleted { onDeleted() } else { dismiss() }
                }
            }
        } message: { Text("この子のお世話メモだけを削除します。") }
        .toolBottomBar {
            // NN/g: the button names the next step.
            ToolMakeBar(top: { CareSaveNotice(store: store) }) {
                NavigationLink {
                    CareDisclosureView(store: store, currentCatID: id, profiles: profiles, reuseStore: reuseStore)
                } label: {
                    Text("次へ：期間とお願い").frame(maxWidth: .infinity)
                }
                .disabled(store.saveError != nil)
                .accessibilityIdentifier("care-disclosure-open")
            }
        }
    }

    /// What opening a memo does first, once: the text from 避難に備える and the
    /// photo from 「この子のこと」. Round 2: also for a cat chosen on the make page.
    /// A failed refresh keeps what is here; nothing to say about it (11/8).
    @MainActor
    static func fillFromCatCare(_ id: UUID, store: CareHandoffStore, reuseStore: EvacuationStore,
                                profiles: [CatProfilePresentation]) async {
        try? store.refreshCandidates(id, using: reuseStore)
        await useCatCarePhoto(id, store: store, profiles: profiles)
    }

    /// 11/8: a memo without a photo starts with the face photo of 「この子のこと」,
    /// else the cat's photo. Not after 「このメモの写真を外す」; 「写真を変える」 stays.
    @MainActor
    private static func useCatCarePhoto(_ id: UUID, store: CareHandoffStore,
                                        profiles: [CatProfilePresentation]) async {
        func current() -> CareCat? { store.plan.cats.first { $0.id == id } }
        guard let cat = current(), cat.photoName == nil, cat.photoRemoved != true else { return }
        let care = CatCareSummary.record(toolCatID: cat.toolCatID ?? cat.id, profileIdentifier: cat.profileID)
        var data: Data?
        if let ref = care?.facePhoto?.value ?? nil, let url = CatCareStore.shared.photoURL(ref) {
            data = try? Data(contentsOf: url)
        }
        if data == nil, let profile = profiles.first(where: { $0.identifier == cat.profileID }),
           let identifier = profile.keyPhotoIdentifier ?? profile.coverPhoto?.localIdentifier {
            data = try? await PhotoLibraryJPEGExporter().export(localIdentifier: identifier).jpeg
        }
        guard let data, current()?.photoName == nil, current()?.photoRemoved != true else { return }
        try? store.replacePhoto(data, catID: id)
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
            } footer: { Text("預かる人が見分けやすい写真を選んでください。") }
            // 11/8: every offered photo, newest first; a photo whose cat is not
            // assigned yet is not hidden under 「ほかの猫の写真」.
            ToolRecentPhotoSection(photos: ownPhotos + otherPhotos, own: Set(ownPhotos.map(\.localIdentifier)),
                                   disabled: busy, identifierPrefix: "care-candidate-") { use($0) }
            if let error { Section { Text(error).foregroundStyle(.red) } }
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
                    } catch { self.error = "写真を保存できませんでした。通信や空き容量を確かめて、もう一度選んでください。"; busy = false; item = nil }
                }
            }
    }
    private func use(_ photo: CatProfilePhotoPresentation) {
        busy = true; error = nil
        Task {
            do {
                let data = try await PhotoLibraryJPEGExporter().export(localIdentifier: photo.localIdentifier)
                try store.replacePhoto(data.jpeg, catID: catID); busy = false; dismiss()
            } catch { self.error = "この写真は使えませんでした。「写真アプリから選ぶ」から選び直せます。"; busy = false }
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
    /// The cat whose memo this was opened from.
    var currentCatID: UUID? = nil
    var profiles: [CatProfilePresentation] = []
    @ObservedObject var reuseStore: EvacuationStore = .shared
    @Environment(\.membershipActions) private var actionAccess
    @AppStorage(CatFarewell.key) private var farewellJSON = ""
    @ObservedObject private var catCare = CatCareStore.shared
    @State private var disclosure = CareHandoffDisclosure()
    @State private var initialized = false
    @State private var preview: CarePreview?
    @State private var error: String?

    /// 11/8: a cat whose farewell day is recorded is not offered.
    private var cats: [CareCat] {
        let days = CatFarewell.days(farewellJSON)
        return store.plan.cats.filter { cat in
            !(cat.profileID.map { days[$0] != nil } ?? false) && days["tool-" + (cat.toolCatID ?? cat.id).uuidString] == nil
        }
    }
    /// Round 2 (11/8): every cat with a profile is offered, not only cats that
    /// already have a memo (347: あめ was missing). Not one whose farewell day is recorded.
    private var profilesWithoutMemo: [CatProfilePresentation] {
        let days = CatFarewell.days(farewellJSON)
        return store.plan.profileIDsWithoutMemo(profiles.map(\.identifier)).compactMap { id in
            days[id] == nil ? profiles.first { $0.identifier == id } : nil
        }
    }
    /// A tap makes the cat's memo from 「この子のこと」, as opening the cat in
    /// the tool does, and chooses it. Nothing is made without a tap.
    private func choose(_ profile: CatProfilePresentation) {
        guard let id = store.addCat(profileID: profile.identifier, name: profile.displayName,
                                    using: reuseStore, access: actionAccess) else {
            // A failed save is shown by CareSaveNotice; say it here only otherwise.
            if store.saveError == nil { error = "\(profile.displayName)のお世話メモを作れませんでした。もう一度押してください。" }
            return
        }
        disclosure.catIDs.insert(id); error = nil
        Task {
            CatCareStore.shared.importFromTools()
            CatCareStore.shared.importBirthdays(profiles)
            await CareCatEditor.fillFromCatCare(id, store: store, reuseStore: reuseStore, profiles: profiles)
        }
    }
    private func record(_ cat: CareCat) -> CatCareRecord? {
        CatCareSummary.record(toolCatID: cat.toolCatID ?? cat.id, profileIdentifier: cat.profileID)
    }
    private func vet(_ cat: CareCat) -> [(String, String)] {
        CareHandoffDisclosure.vetFields(plan: store.plan, household: catCare.state?.household, record: record(cat))
    }
    private var contacts: [(String, String)] {
        CareHandoffDisclosure.contactFields(plan: store.plan, household: catCare.state?.household)
    }
    private func text(_ key: WritableKeyPath<CareHandoffPlan, String>) -> Binding<String> {
        Binding(get: { store.plan[keyPath: key] }, set: { new in store.update { $0[keyPath: key] = new } })
    }
    /// Period and request, written in one place (347): see CareHandoffPlan.requestText.
    private func request(_ key: WritableKeyPath<CareHandoffContext, String>,
                         _ planKey: WritableKeyPath<CareHandoffPlan, String>) -> Binding<String> {
        Binding(get: { store.plan.requestText(key, planKey, chosen: disclosure.catIDs) },
                set: { new in store.update { $0.setRequestText(new, key, planKey, chosen: disclosure.catIDs) } })
    }
    /// Round 2 (11/8): 「家の中のこと」, once for the household.
    private func house(_ key: WritableKeyPath<CareHandoffPlan, String?>) -> Binding<String> {
        Binding(get: { store.plan[keyPath: key] ?? "" },
                set: { new in store.update { $0[keyPath: key] = new.isEmpty ? nil : new } })
    }
    private var houseWritten: Bool {
        !CareHandoffDisclosure.houseFields(plan: store.plan).isEmpty
    }
    /// Where the three steps stand (11/8 型): the period, a chosen cat, and
    /// what to include (done once the page is seen: the choices start set).
    /// 「家の中のこと（任意）」 is not counted: ✓ once written, else grey.
    private var stepStates: [ToolStepState] {
        ToolStepState.states([
            CareCatEditor.isFilled(store.plan.requestText(\.period, \.period, chosen: disclosure.catIDs)),
            !disclosure.catIDs.isEmpty,
            true,
        ])
    }

    var body: some View {
        let states = stepStates
        List {
            // 11/8: this time's period and request first, where the memo is made.
            Section {
                CareField(label: "お願いする相手", example: "例：お母さん", identifier: "care-recipient", text: request(\.recipient, \.recipient))
                CareField(label: "期間", example: "例：10月5日 夜〜10月7日 朝", identifier: "care-period", text: request(\.period, \.period))
                CareField(label: "ほかにお願いしたいこと", example: "例：お世話が終わったら写真を1枚送ってください", identifier: "care-request", text: request(\.request, \.request))
            } header: { ToolStepHeader(number: 1, title: "期間とお願い", state: states[0]) }
            // Round 2 (11/8): the house, once for every cat. No address or keys.
            Section {
                CareField(label: "フードと砂の置き場所", example: "例：洗面所の棚の下", identifier: "care-house-food",
                          text: house(\.houseFoodPlace), limit: 1000)
                CareField(label: "キャリーの場所", example: "例：玄関の物入れ", identifier: "care-house-carrier",
                          text: house(\.houseCarrierPlace), limit: 1000)
                CareField(label: "隠れる場所", example: "例：ベッドの下、押し入れの奥", identifier: "care-house-hiding",
                          text: house(\.houseHidingPlace), limit: 1000)
                CareField(label: "ほかに", example: "例：エアコンは27度のままにしてください", identifier: "care-house-other",
                          text: house(\.houseOther), limit: 2000)
            } header: { ToolStepHeader(number: 2, title: "家の中のこと（任意）", state: houseWritten ? .done : .todo)
            } footer: { ToolImportantInformation(text: "住所や鍵の番号は、別の方法で伝えてください。") }
            Section {
                ForEach(cats) { cat in
                    let selected = disclosure.catIDs.contains(cat.id)
                    Button {
                        if selected { disclosure.catIDs.remove(cat.id) } else { disclosure.catIDs.insert(cat.id) }
                    } label: {
                        HStack {
                            Text(cat.displayName).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityValue(selected ? "選択済み" : "未選択")
                        .accessibilityIdentifier("care-select-\(cat.id.uuidString)")
                }
                // A cat with a profile but no memo yet; a tap makes it and chooses it.
                ForEach(profilesWithoutMemo, id: \.identifier) { profile in
                    Button { choose(profile) } label: {
                        HStack {
                            Text(profile.displayName).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "circle").foregroundStyle(Color.secondary)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .disabled(store.saveError != nil)
                        .accessibilityValue("未選択")
                        .accessibilityIdentifier("care-add-profile-\(profile.identifier)")
                }
            } header: { ToolStepHeader(number: 3, title: "お願いする猫", state: states[1]) }
            Section {
                Toggle("薬・持病・アレルギーを載せる", isOn: $disclosure.health).accessibilityIdentifier("care-disclose-health")
                Toggle("連絡先・動物病院を載せる", isOn: $disclosure.contacts).accessibilityIdentifier("care-disclose-contacts")
                // The household contacts, once for every cat; written in 「この子のこと」.
                if disclosure.contacts {
                    ForEach(Array(contacts.enumerated()), id: \.offset) { _, line in
                        LabeledContent(line.0, value: line.1)
                    }
                    .accessibilityIdentifier("care-contacts")
                }
            } header: { ToolStepHeader(number: 4, title: "載せるもの", state: states[2]) }
            // What is not written yet is shown once, on each cat's
            // 「この子のこと」 row; not listed again here (11/8).
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
        }.navigationTitle("メモを作る").navigationBarTitleDisplayMode(.inline)
        .toolPageSpacing()
            .scrollDismissesKeyboard(.interactively)
            .announcesWhenShown(error)
            .onAppear {
                guard !initialized else { return }
                initialized = true
                // 11/8: an old trip's period and request start empty.
                store.clearStaleRequest()
                // Every cat to begin with; the owner takes out the ones not going.
                disclosure.catIDs = Set(cats.map(\.id))
                if disclosure.catIDs.isEmpty, let currentCatID, store.plan.cats.contains(where: { $0.id == currentCatID }) {
                    disclosure.catIDs = [currentCatID]
                }
                // On when something is written, unless the last memo left it out.
                let chosen = cats.filter { disclosure.catIDs.contains($0.id) }
                let healthWritten = chosen.contains { cat in
                    !CareHandoffDisclosure.written(CatCareSummary.careHandoffHealthLines(record(cat), legacy: cat)).isEmpty
                }
                let contactsWritten = !contacts.isEmpty || chosen.contains { !vet($0).isEmpty }
                disclosure.health = healthWritten && (store.plan.includesHealth ?? true)
                disclosure.contacts = contactsWritten && (store.plan.includesContacts ?? true)
            }
            .navigationDestination(item: $preview) { item in
                CareDisplayView(record: item.record) {
                    store.recordMade(health: item.record.includesHealth, contacts: item.record.includesContacts)
                }
            }
            .toolBottomBar {
                // The button has the name of what it makes (11/8 型).
                ToolMakeBar(missing: disclosure.catIDs.isEmpty ? ["お願いする猫"] : [],
                            top: { CareSaveNotice(store: store) }) {
                    Button {
                        do { preview = CarePreview(record: try store.shareRecord(disclosure)); error = nil }
                        catch { self.error = (error as? CareHandoffError)?.errorDescription ?? "表示できませんでした。もう一度お試しください。" }
                    } label: {
                        Label("お世話メモを作る", systemImage: "doc.text").frame(maxWidth: .infinity)
                    }
                    .disabled(disclosure.catIDs.isEmpty || store.saveError != nil)
                    .accessibilityIdentifier("care-preview-open")
                }
            }
    }
}

private struct CareDisplayView: View {
    let record: CareHandoffShareRecord
    /// Called once a file is made, so the choices are remembered for next time.
    var onMade: () -> Void = {}
    @State private var export: CareHandoffExporter.Export?
    @State private var retainedDirectory: URL?
    @State private var pdf = false
    @State private var error: String?
    /// True while the memo is being made (11/6).
    @State private var exporting = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("お世話メモ").font(.largeTitle.bold())
                if !record.includesHealth { Label("薬・持病・アレルギーは載せていません", systemImage: "info.circle").font(.subheadline) }
                if !record.includesContacts { Label("連絡先・動物病院は載せていません", systemImage: "info.circle").font(.subheadline) }
                fields(record.commonFields)
                ForEach(Array(record.cats.enumerated()), id: \.offset) { _, cat in
                    VStack(alignment: .leading, spacing: 18) {
                        Text(cat.name).font(.title.bold())
                        if let photo = cat.photo { Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 260).accessibilityLabel("渡す猫の写真") }
                        fields(cat.fields)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(16)
        }.background(Color(.systemGroupedBackground))
            .navigationTitle("できあがり").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                ViewThatFits {
                    HStack(spacing: 12) { shareButton("PDFで渡す", pdf: true); shareButton("画像で渡す", pdf: false) }
                    VStack(spacing: 8) { shareButton("PDFで渡す", pdf: true); shareButton("画像で渡す", pdf: false) }
                }
                .padding().background(.regularMaterial)
            }
            .sheet(item: $export, onDismiss: {
                if let retainedDirectory { CareHandoffExporter.remove(retainedDirectory) }
                retainedDirectory = nil
            }) { CareActivitySheet(items: $0.files, text: record.plainText) }
    }
    private func fields(_ values: [(String, String)]) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
            VStack(alignment: .leading, spacing: 6) {
                Text(value.0).font(.subheadline).foregroundStyle(.secondary)
                Text(value.1).font(.body).textSelection(.enabled)
            }
        }
    }
    /// PDF is the main way out; the image is the second.
    @ViewBuilder private func shareButton(_ title: String, pdf: Bool) -> some View {
        // 11/8: straight to the share sheet, where the person is chosen.
        let button = Button { self.pdf = pdf; Task { await createExport() } } label: {
            Group {
                if exporting && self.pdf == pdf {
                    WorkingLabel(title: title, workingTitle: "作っています…", working: true)
                } else {
                    Label(title, systemImage: pdf ? "doc" : "photo")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(exporting)
        if pdf {
            button.buttonStyle(.borderedProminent).accessibilityIdentifier("care-share-pdf")
        } else {
            button.buttonStyle(.bordered).accessibilityIdentifier("care-share-images")
        }
    }
    private func createExport() async {
        // The file is drawn on the main thread, which stops the screen; give
        // 「作っています…」 a moment to show first, so the press is not silent (11/6).
        exporting = true
        defer { exporting = false }
        try? await Task.sleep(for: .milliseconds(100))
        do {
            let made = try CareHandoffExporter.create(record, pdf: pdf)
            retainedDirectory = made.directory; export = made; error = nil
            onMade()
        } catch { self.error = "作れませんでした。空き容量やメモの長さを確かめてください。" }
    }
}

private struct CareActivitySheet: UIViewControllerRepresentable {
    let items: [URL]
    /// Round 2 (11/8): 「文字で送る」. The memo as text, to paste into LINE.
    var text = ""
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: (items as [Any]) + (text.isEmpty ? [] : [text]), applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The tool's one safety sentence, shown as it is (11/7: it was folded under
/// 「大事なこと」 and went unread).
struct ToolImportantInformation: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }
}
