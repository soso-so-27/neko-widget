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
                List {
                    ToolCatPicker(profiles: profiles, select: { select(profileID: $0.identifier, name: $0.displayName) }, purpose: "猫を追加すると、預ける人に渡すメモを作れます。") {}
                    CareHandoffDetachedPhotos(store: store)
                }
                    .safeAreaInset(edge: .bottom) { CareSaveNotice(store: store) }
            } else if let id = selectedCatID, store.plan.cats.contains(where: { $0.id == id }) {
                // The chosen cat's memo; the cat menu in the bar switches it in
                // place (11/12: no row of faces on this tool). A new cat is a new
                // page, so what was chosen for one memo never carries over.
                editor(id).id(id)
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
                    CareHandoffDetachedPhotos(store: store)
                }
                .safeAreaInset(edge: .bottom) { CareSaveNotice(store: store) }
            }
        }
        .navigationTitle("預けるとき").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { catMenu }
        }
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

    /// 11/12: the cat switcher is the small menu in the bar every row-list
    /// tool uses, here too while no memo is open. It stays away with one cat.
    @ViewBuilder private var catMenu: some View {
        if store.loadError == nil, !stripCats.isEmpty {
            ToolCatMenu(cats: stripCats, selectedID: selectedStripID, title: menuName,
                        identifier: "care-cat-menu") { select($0) }
        }
    }

    private var menuName: String {
        stripCats.first { $0.id == selectedStripID }?.name ?? "猫を選ぶ"
    }

    /// True when the bar has no cat menu (one cat to choose from), so the
    /// page names the cat itself, as 病院で見せる does.
    private var menuHidden: Bool {
        let selected = selectedStripID
        return stripCats.filter { $0.id == selected || !$0.isDeparted(farewellJSON) }.count < 2
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
                             profiles: profiles, showsName: menuHidden,
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
    /// The pushed page's field, given the cursor once the page has slid in (11/12).
    var focus: FocusState<Bool>.Binding? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsLabel || isPrefilled {
                HStack {
                    if showsLabel { Text(label).font(.subheadline.weight(.medium)) }
                    if isPrefilled { Text("前に入れた内容").font(.caption).foregroundStyle(.secondary) }
                }
            }
            input
        }.padding(.vertical, 4)
    }
    @ViewBuilder private var input: some View {
        let field = TextField(example, text: Binding(get: { text }, set: { text = String($0.prefix(limit)) }), axis: .vertical)
            .lineLimit(1...8).frame(minHeight: 36)
            .foregroundStyle(Color.primary)
            .accessibilityLabel(label).accessibilityIdentifier(identifier)
        if let focus { field.focused(focus) } else { field }
    }
}

/// 11/12: one page as a list of rows, as in 設定 (the shape 病院で見せる has):
/// 「この子について」 and 「今回のお願い」 as rows that each open their own page,
/// 「この子のこと」, then the notes; the memo is made from here in one step.
/// What was the second page (期間とお願い・家の中のこと・お願いする猫・載せるもの)
/// is part of this page, and its choices live here, for this memo only.
private struct CareCatEditor: View {
    let id: UUID
    let ownPhotos: [CatProfilePhotoPresentation]
    let otherPhotos: [CatProfilePhotoPresentation]
    @ObservedObject var store: CareHandoffStore
    @ObservedObject var reuseStore: EvacuationStore
    var profiles: [CatProfilePresentation] = []
    /// The cat's name at the top, when the bar has no cat menu to name it.
    var showsName = false
    /// Set when the memo is the tool's page: it stays after a delete.
    var onDeleted: (() -> Void)? = nil
    /// Redraws when 「この子のこと」 changes, for example after 「この子のことを直す」.
    @ObservedObject private var catCare = CatCareStore.shared
    @Environment(\.membershipActions) private var actionAccess
    @AppStorage(CatFarewell.key) private var farewellJSON = ""
    @State private var deleteRequested = false
    @State private var refreshedCandidates = false
    /// What goes on this memo: kept for this hand-off only, never saved, as
    /// on the page it came from (the plan keeps only the last toggles).
    @State private var disclosure = CareHandoffDisclosure()
    @State private var initialized = false
    @State private var preview: CarePreview?
    @State private var error: String?
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

    private func subject(_ cat: CareCat) -> CatCareSubject {
        profiles.first(where: { $0.identifier == cat.profileID }).map(CatCareSubject.profile)
            ?? .toolCat(id: cat.toolCatID ?? cat.id, name: cat.name)
    }

    /// The memo's photo (11/9): the face photo of 「この子のこと」, chosen there
    /// only. Off for this memo after 「このメモには載せない」.
    private func memoPhoto(_ cat: CareCat) -> URL? {
        guard cat.photoRemoved != true else { return nil }
        let care = CatCareSummary.record(toolCatID: cat.toolCatID ?? cat.id, profileIdentifier: cat.profileID)
        return CatCareSummary.identifyingPhotoURL(care, .face, legacy: store.imageURL(cat.photoName))
    }

    /// Everyday care and health, from 「この子のこと」 only: one place for each
    /// cat, so a second copy here can never disagree with it.
    @ViewBuilder private func catCareSection(_ cat: CareCat) -> some View {
        let care = CatCareSummary.record(toolCatID: cat.toolCatID ?? cat.id, profileIdentifier: cat.profileID)
        let health = CatCareSummary.careHandoffHealthLines(care, legacy: cat)
        // 11/8: the cat's own vet is shown here; the household contacts are
        // shown once, in 「載せるもの」.
        let vet = CareHandoffDisclosure.vetFields(plan: store.plan, household: catCare.state?.household, record: care)
        let catSubject = subject(cat)
        // 11/8: no footer; what goes on the memo is chosen in 「載せるもの」.
        ToolCatCareSection(title: "この子のこと",
                           lines: CatCareSummary.careHandoffLines(care, legacy: cat) + health + vet, subject: catSubject,
                           identifier: "care-cat-care-fields", editIdentifier: "care-open-cat-care", profiles: profiles,
                           folded: true)
    }

    static func isFilled(_ text: String?) -> Bool {
        !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // The body is split in parts so the type checker stays fast.
    var body: some View {
        lifecycle(page)
    }
    private var page: some View {
        Form { formContent }
            .toolPageSpacing()
            .navigationTitle("預けるとき").navigationBarTitleDisplayMode(.inline)
            .announcesWhenShown(error)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { moreMenu }
            }
            .toolBottomBar { bottomBar }
    }
    private func lifecycle<Page: View>(_ page: Page) -> some View {
        page
            .task {
                // Once per page: coming back from a row's page reads nothing again.
                if !initialized {
                    CatCareStore.shared.importFromTools()
                    CatCareStore.shared.importBirthdays(profiles)
                    // After the import, so what 「この子のこと」 has decides the toggles.
                    initialize()
                }
                guard !refreshedCandidates else { return }
                refreshedCandidates = true
                await Self.fillFromCatCare(id, store: store, reuseStore: reuseStore, profiles: profiles)
            }
            .confirmationDialog("この子のお世話メモを削除しますか？", isPresented: $deleteRequested, titleVisibility: .visible) {
                Button("お世話メモを削除", role: .destructive) {
                    if store.update({ $0.cats.removeAll { $0.id == id } }) {
                        if let onDeleted { onDeleted() } else { dismiss() }
                    }
                }
            } message: { Text("この子のお世話メモだけを削除します。") }
            .navigationDestination(item: $preview) { item in
                CareDisplayView(record: item.record) {
                    store.recordMade(health: item.record.includesHealth, contacts: item.record.includesContacts)
                }
            }
    }
    /// 11/12: delete is not part of writing the memo; it sits in 「…」.
    private var moreMenu: some View {
        ToolMoreMenu(destructiveTitle: "このお世話メモを削除", itemIdentifier: "care-delete",
                     menuIdentifier: "care-more-menu") { deleteRequested = true }
            .disabled(cat == nil)
    }
    /// The one way forward: the button has the name of what it makes (11/8 型).
    private var bottomBar: some View {
        ToolMakeBar(missing: initialized && disclosure.catIDs.isEmpty ? ["お願いする猫"] : [],
                    top: { CareSaveNotice(store: store) }) {
            Button { makeMemo() } label: {
                Label("お世話メモを作る", systemImage: "doc.text").frame(maxWidth: .infinity)
            }
            .disabled(!initialized || disclosure.catIDs.isEmpty || store.saveError != nil)
            .accessibilityIdentifier("care-preview-open")
        }
    }
    private func makeMemo() {
        // Only the cats still here: the page stays open longer than the
        // second page did, and a family change can take a memo away.
        var chosen = disclosure
        chosen.catIDs.formIntersection(store.plan.cats.map(\.id))
        do { preview = CarePreview(record: try store.shareRecord(chosen)); error = nil }
        catch { self.error = (error as? CareHandoffError)?.errorDescription ?? "表示できませんでした。もう一度お試しください。" }
    }

    @ViewBuilder private var formContent: some View {
        if let cat {
            headerSection(cat)
            aboutSection(cat)
            requestSection
            catCareSection(cat)
            errorSection
            footnoteSection(cat)
        }
        CareHandoffDetachedPhotos(store: store)
    }
    /// The cat's name when the bar does not show it, then what this page makes.
    private func headerSection(_ cat: CareCat) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                if showsName, let profile = profiles.first(where: { $0.identifier == cat.profileID }) {
                    Label(profile.displayName, systemImage: "cat").font(.headline)
                }
                ToolPurpose(text: "預ける人に渡すお世話メモを作ります。")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        }
    }
    @ViewBuilder private var errorSection: some View {
        if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
    }
    /// Notes last, as a quiet footnote on the page ground (11/12).
    @ViewBuilder private func footnoteSection(_ cat: CareCat) -> some View {
        if cat.familyDetached == true {
            Section {
                ToolImportantInformation(text: "このメモは、家族の手帳には入っていません。")
                    .quietRow()
            }
        }
    }
}

// MARK: Rows (11/12)

extension CareCatEditor {
    /// A row's value: the first written text's first words on one line.
    private static func firstWords(_ texts: [String]) -> String? {
        guard let first = texts.first(where: { isFilled($0) }) else { return nil }
        return String(first.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(60))
    }
    private func textRow(_ title: String, _ systemImage: String, _ texts: [String]) -> ToolValueRow {
        let words = Self.firstWords(texts)
        return ToolValueRow(title: title, systemImage: systemImage, value: words ?? "未記入", filled: words != nil)
    }

    /// 「この子について」: the name (a cat without a profile), the photo, what
    /// to say first, when to call.
    private func aboutSection(_ cat: CareCat) -> some View {
        Section {
            if !profiles.contains(where: { $0.identifier == cat.profileID }) {
                NavigationLink { namePage } label: { textRow("名前", "textformat", [cat.name]) }
                    .accessibilityIdentifier("care-row-name")
            }
            NavigationLink { photoPage } label: { photoLabel(cat) }
                .accessibilityIdentifier("care-row-photo")
            NavigationLink { importantPage } label: {
                textRow("まず伝えたいこと", "exclamationmark.bubble", [cat.important])
            }
            .accessibilityIdentifier("care-row-important")
            NavigationLink { callWhenPage } label: {
                textRow("こんなときは連絡を", "phone", [cat.callWhen ?? ""])
            }
            .accessibilityIdentifier("care-row-call-when")
        } header: {
            Text("この子について")
        }
    }
    /// 「載せる」 with the photo, 「載せない」 after 「このメモには載せない」,
    /// 「なし」 when 「この子のこと」 has no face photo yet.
    private func photoLabel(_ cat: CareCat) -> ToolValueRow {
        let value = cat.photoRemoved == true ? "載せない" : (memoPhoto(cat) != nil ? "載せる" : "なし")
        return ToolValueRow(title: "写真", systemImage: "photo", value: value, filled: value != "なし")
    }

    /// 「今回のお願い」: what this trip needs, once for every cat.
    private var requestSection: some View {
        Section {
            NavigationLink { requestPage } label: { requestLabel }
                .accessibilityIdentifier("care-row-request")
            NavigationLink { housePage } label: { houseLabel }
                .accessibilityIdentifier("care-row-house")
            NavigationLink { catsPage } label: { catsLabel }
                .accessibilityIdentifier("care-row-cats")
            NavigationLink { includePage } label: { includeLabel }
                .accessibilityIdentifier("care-row-include")
        } header: {
            Text("今回のお願い")
        }
    }
    private var requestLabel: ToolValueRow {
        let chosen = disclosure.catIDs
        let plan = store.plan
        return textRow("期間とお願い", "calendar", [plan.requestText(\.period, \.period, chosen: chosen),
                                                  plan.requestText(\.recipient, \.recipient, chosen: chosen),
                                                  plan.requestText(\.request, \.request, chosen: chosen)])
    }
    private var houseLabel: ToolValueRow {
        textRow("家の中のこと", "house", CareHandoffDisclosure.houseFields(plan: store.plan).map(\.1))
    }
    private var catsLabel: ToolValueRow {
        let chosen = store.plan.cats.filter { disclosure.catIDs.contains($0.id) }
        let value = chosen.count == 1 ? chosen[0].displayName : (chosen.isEmpty ? "なし" : "\(chosen.count)匹")
        return ToolValueRow(title: "お願いする猫", systemImage: "cat", value: value, filled: !chosen.isEmpty)
    }
    private var includeLabel: ToolValueRow {
        let value: String
        switch (disclosure.health, disclosure.contacts) {
        case (true, true): value = "薬・連絡先を載せる"
        case (true, false): value = "薬を載せる"
        case (false, true): value = "連絡先を載せる"
        case (false, false): value = "載せない"
        }
        return ToolValueRow(title: "載せるもの", systemImage: "checklist", value: value,
                            filled: disclosure.health || disclosure.contacts)
    }
}

// MARK: Pages each row opens (11/12)
//
// The same bindings, limits and examples as before; each field writes to the
// store as it is typed, so leaving a page has nothing left to save.

extension CareCatEditor {
    private func pushed<Content: View>(_ title: String, focuses: Bool = false,
                                       @ViewBuilder content: @escaping (FocusState<Bool>.Binding) -> Content) -> some View {
        ToolPushedPage(title: title, focusesField: focuses, content: content)
    }

    private var namePage: some View {
        pushed("名前", focuses: true) { focus in
            Section {
                CareField(label: "猫の名前", example: "例：むぎ", identifier: "care-cat-name", text: text(\.name), limit: 80,
                          isPrefilled: cat?.prefilledFields?.contains("name") == true, focus: focus)
            }
        }
    }

    private var photoPage: some View {
        pushed("写真") { _ in
            if let cat { photoRows(cat) }
        }
    }
    @ViewBuilder private func photoRows(_ cat: CareCat) -> some View {
        Section {
            // 11/9: chosen in 「この子のこと」 only; shown here.
            let photo = memoPhoto(cat)
            ToolIdentifyingPhotos(faceFile: photo, bodyFile: nil, subject: subject(cat), profiles: profiles,
                                  showsBody: false, identifier: "care-photo-open")
            if cat.photoRemoved == true {
                Button("このメモにも写真を載せる") { store.editCat(id) { $0.photoRemoved = nil } }
                    .font(.footnote)
                    .accessibilityIdentifier("care-photo-include")
            } else if photo != nil {
                // Only this memo; the photo stays in 「この子のこと」.
                Button("このメモには載せない") { store.editCat(id) { $0.photoRemoved = true } }
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("care-photo-actions")
            }
        }
    }

    private var importantPage: some View {
        pushed("まず伝えたいこと", focuses: true) { focus in
            Section {
                CareField(label: "まず伝えたいこと", example: "例：玄関を開ける前に、猫が別の部屋にいるか確認", identifier: "care-important", text: text(\.important),
                          showsLabel: false, focus: focus)
            }
        }
    }

    private var callWhenPage: some View {
        pushed("こんなときは連絡を", focuses: true) { focus in
            Section {
                CareField(label: "こんなときは連絡を", example: "例：丸1日ごはんを食べない、何度も吐く、トイレに行ってもおしっこが出ない",
                          identifier: "care-call-when",
                          text: Binding(get: { self.cat?.callWhen ?? "" }, set: { new in
                              store.editCat(id) { $0.callWhen = new.isEmpty ? nil : new }
                          }), showsLabel: false, focus: focus)
                callWhenChips
            }
        }
    }
    private var callWhenChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.callWhenChoices, id: \.self) { choice in
                    let current = cat?.callWhen ?? ""
                    Button(choice) {
                        store.editCat(id) { $0.callWhen = current.isEmpty ? choice : current + "、" + choice }
                    }
                    .buttonStyle(.bordered).font(.footnote)
                    .disabled(current.contains(choice))
                }
            }
        }
        .accessibilityIdentifier("care-call-when-choices")
    }

    /// Period and request, written in one place (347): see CareHandoffPlan.requestText.
    private func request(_ key: WritableKeyPath<CareHandoffContext, String>,
                         _ planKey: WritableKeyPath<CareHandoffPlan, String>) -> Binding<String> {
        Binding(get: { store.plan.requestText(key, planKey, chosen: disclosure.catIDs) },
                set: { new in store.update { $0.setRequestText(new, key, planKey, chosen: disclosure.catIDs) } })
    }
    private var requestPage: some View {
        pushed("期間とお願い", focuses: true) { focus in
            Section {
                CareField(label: "お願いする相手", example: "例：お母さん", identifier: "care-recipient", text: request(\.recipient, \.recipient),
                          focus: focus)
                CareField(label: "期間", example: "例：10月5日 夜〜10月7日 朝", identifier: "care-period", text: request(\.period, \.period))
                CareField(label: "ほかにお願いしたいこと", example: "例：お世話が終わったら写真を1枚送ってください", identifier: "care-request", text: request(\.request, \.request))
            }
        }
    }

    /// Round 2 (11/8): 「家の中のこと」, once for the household.
    private func house(_ key: WritableKeyPath<CareHandoffPlan, String?>) -> Binding<String> {
        Binding(get: { store.plan[keyPath: key] ?? "" },
                set: { new in store.update { $0[keyPath: key] = new.isEmpty ? nil : new } })
    }
    private var housePage: some View {
        pushed("家の中のこと", focuses: true) { focus in
            // Round 2 (11/8): the house, once for every cat. No address or keys.
            Section {
                CareField(label: "フードと砂の置き場所", example: "例：洗面所の棚の下", identifier: "care-house-food",
                          text: house(\.houseFoodPlace), limit: 1000, focus: focus)
                CareField(label: "キャリーの場所", example: "例：玄関の物入れ", identifier: "care-house-carrier",
                          text: house(\.houseCarrierPlace), limit: 1000)
                CareField(label: "隠れる場所", example: "例：ベッドの下、押し入れの奥", identifier: "care-house-hiding",
                          text: house(\.houseHidingPlace), limit: 1000)
                CareField(label: "ほかに", example: "例：エアコンは27度のままにしてください", identifier: "care-house-other",
                          text: house(\.houseOther), limit: 2000)
            } footer: { ToolImportantInformation(text: "住所や鍵の番号は、別の方法で伝えてください。") }
        }
    }

    private var catsPage: some View {
        pushed("お願いする猫") { _ in
            Section {
                ForEach(cats) { cat in catChoice(cat) }
                // A cat with a profile but no memo yet; a tap makes it and chooses it.
                ForEach(profilesWithoutMemo, id: \.identifier) { profile in profileChoice(profile) }
            }
            errorSection
        }
    }
    private func catChoice(_ cat: CareCat) -> some View {
        let selected = disclosure.catIDs.contains(cat.id)
        return Button {
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
    private func profileChoice(_ profile: CatProfilePresentation) -> some View {
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

    private var includePage: some View {
        pushed("載せるもの") { _ in
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
            }
        }
    }
}

// MARK: Which cats and what to include (from the page that made the memo)

extension CareCatEditor {
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
    /// Once per page, as the second page did each time it opened.
    private func initialize() {
        guard !initialized else { return }
        initialized = true
        // 11/8: an old trip's period and request start empty.
        store.clearStaleRequest()
        // Every cat to begin with; the owner takes out the ones not going.
        disclosure.catIDs = Set(cats.map(\.id))
        if disclosure.catIDs.isEmpty, store.plan.cats.contains(where: { $0.id == id }) {
            disclosure.catIDs = [id]
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
}

extension CareCatEditor {
    /// What opening a memo does first, once: the text from 避難に備える, and a
    /// face photo for 「この子のこと」 when it has none. Round 2: also for a cat
    /// chosen in 「お願いする猫」. A failed refresh keeps what is here (11/8).
    @MainActor
    static func fillFromCatCare(_ id: UUID, store: CareHandoffStore, reuseStore: EvacuationStore,
                                profiles: [CatProfilePresentation]) async {
        try? store.refreshCandidates(id, using: reuseStore)
        await useKeyPhotoForCatCare(id, store: store, profiles: profiles)
    }

    /// 11/8: a memo started with the cat's photo when it had none. Since 11/9
    /// the memo shows 「この子のこと」's face photo, so a cat whose face photo
    /// was never set there (and no tool had one) starts with its key photo
    /// there. Not after 「このメモには載せない」, and never over a choice made there.
    @MainActor
    private static func useKeyPhotoForCatCare(_ id: UUID, store: CareHandoffStore,
                                              profiles: [CatProfilePresentation]) async {
        guard let cat = store.plan.cats.first(where: { $0.id == id }), cat.photoRemoved != true, cat.photoName == nil,
              let profile = profiles.first(where: { $0.identifier == cat.profileID }),
              let identifier = profile.keyPhotoIdentifier ?? profile.coverPhoto?.localIdentifier else { return }
        let catCare = CatCareStore.shared
        func unset() -> Bool {
            let record = CatCareSummary.record(toolCatID: cat.toolCatID ?? cat.id, profileIdentifier: cat.profileID)
            return record == nil || record?.facePhoto == nil
        }
        guard unset(), catCare.canSave,
              let jpeg = try? await PhotoLibraryJPEGExporter().export(localIdentifier: identifier).jpeg,
              let clean = CatCareFormat.cleanJPEG(jpeg), unset(),
              let record = catCare.ensureRecord(toolCatID: cat.toolCatID ?? cat.id, profileIdentifier: cat.profileID,
                                                name: profile.displayName),
              let ref = catCare.savePhoto(clean, sourceAssetID: identifier, origin: .photos) else { return }
        catCare.update { state in
            guard let index = state.cats.firstIndex(where: { $0.catID == record.catID }),
                  state.cats[index].facePhoto == nil else { return }
            state.cats[index].setIdentifyingPhoto(.face, ref, editedAt: Date(), editedBy: "import:Profile")
        }
    }
}

private struct CareHandoffDetachedPhotos: View {
    @ObservedObject var store: CareHandoffStore

    var body: some View {
        ForEach(store.plan.detachedPhotos ?? []) { photo in
            DetachedToolPhotoRow(title: "写真", load: { try store.photoData(photo.photoName) },
                                 remove: { store.removeDetachedPhoto(photo) })
        }
    }
}

private struct CarePreview: Identifiable, Hashable {
    let id = UUID()
    let record: CareHandoffShareRecord
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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
            .toolChrome()
            // 11/11: the input pages' bar (full-width, large); each button keeps its own style.
            .toolBarFadeRoom()
            .safeAreaInset(edge: .bottom) {
                ToolMakeBar {
                    ViewThatFits {
                        HStack(spacing: 12) { shareButton("PDFで渡す", pdf: true); shareButton("画像で渡す", pdf: false) }
                        VStack(spacing: 8) { shareButton("PDFで渡す", pdf: true); shareButton("画像で渡す", pdf: false) }
                    }
                }
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
            .frame(maxWidth: .infinity)
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
    /// As a Section's only row: a quiet footnote on the page ground, not a
    /// card of its own (11/12).
    func quietRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
    }
}
