import PhotosUI
import SwiftUI
import UIKit

// 「この子のこと」: each cat's information in one place, read by every tool.
// Local records are shared only for cats explicitly added to the family notebook.

extension CatCareStore {
    /// Weights written in photo memos join the weight list (read only; memos
    /// are not changed). Moved here from the old この子のこと entry, so the
    /// cat's page does it wherever it opens from (11/7).
    func importMemoWeights() async {
        guard let records = try? await PhotoMemoryNoteStore.shared.records() else { return }
        importWeights(records.compactMap { record in
            record.note.weight.map { weight in
                CatCareMemoWeight(noteID: record.note.id.uuidString, catID: weight.catID,
                                  grams: weight.value.grams, measuredOn: weight.value.measuredOn,
                                  fallbackDate: record.note.context?.capturedAt ?? record.note.writtenAt)
            }
        }, cleared: Set(records.filter { $0.note.weight == nil }.map { $0.note.id.uuidString }))
    }
}

/// Whose 「この子のこと」 a page shows: a cat profile, or a tool's cat that
/// has no profile (a guest cat), which has a page of its own too.
enum CatCareSubject {
    case profile(CatProfilePresentation)
    case toolCat(id: UUID, name: String)

    var displayName: String {
        switch self {
        case let .profile(profile): profile.displayName
        case let .toolCat(_, name):
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "名前未設定の猫" : name
        }
    }

    var key: String {
        switch self {
        case let .profile(profile): profile.identifier
        case let .toolCat(id, _): "tool-" + id.uuidString
        }
    }
}

/// 11/21: a microchip number not 15 digits yet, by cat, while the app runs.
/// Never written to a file: only the full number is saved.
@MainActor
enum CatCareUnfinishedMicrochip {
    static var numbers: [UUID: String] = [:]
}

/// 11/21: deleting a cat removes what this iPhone kept for it in the tools
/// (預けるとき・避難に備える・迷子のとき・病院のメモ・この子のこと), so the
/// cat does not come back as a tool page.
/// A cat in the family notebook stays the family's cat for everyone: its
/// 「この子のこと」 and tool records are kept and follow the family's cat
/// (the household cat ID) instead of the deleted profile, so it has one
/// page, not a second one made from the tools.
@MainActor
enum CatProfileDeletionCleanup {
    /// 11/21: a cleanup not finished yet (a store could not be written, the
    /// iPhone was locked, the app closed). Every step can run again, so the
    /// whole cleanup is tried again when the この子 tab opens, until done.
    struct Pending: Codable, Equatable {
        var profileID: String
        var careCatID: UUID?
        var keepsCareRecord: Bool
    }

    static let pendingKey = "catProfileDeletionCleanup.pending.v1"
    static var defaults: UserDefaults = .standard
    private static var running: Set<String> = []

    static func run(profileID: String, careCatID: UUID?, keepsCareRecord: Bool) {
        let job = Pending(profileID: profileID, careCatID: careCatID, keepsCareRecord: keepsCareRecord)
        var all = pending()
        all.removeAll { $0.profileID.caseInsensitiveCompare(profileID) == .orderedSame }
        all.append(job)
        store(all)
        Task { await finish(job) }
    }

    /// When the この子 tab opens. A cat with the same profile again (brought
    /// back from a file) is a cat now: its job is dropped, nothing is removed.
    static func retryPending(existingProfiles: [String]) {
        for job in pending() {
            if existingProfiles.contains(where: { $0.caseInsensitiveCompare(job.profileID) == .orderedSame }) {
                forget(profileID: job.profileID)
            } else {
                Task { await finish(job) }
            }
        }
    }

    /// A cat profile made again with this identifier (a file read back).
    static func forget(profileID: String) {
        let all = pending()
        let rest = all.filter { $0.profileID.caseInsensitiveCompare(profileID) != .orderedSame }
        if rest != all { store(rest) }
    }

    static func pending() -> [Pending] {
        guard let data = defaults.data(forKey: pendingKey) else { return [] }
        return (try? JSONDecoder().decode([Pending].self, from: data)) ?? []
    }

    private static func store(_ all: [Pending]) {
        if all.isEmpty { defaults.removeObject(forKey: pendingKey); return }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: pendingKey) }
    }

    private static func finish(_ job: Pending) async {
        guard running.insert(job.profileID.uppercased()).inserted else { return }
        defer { running.remove(job.profileID.uppercased()) }
        guard pending().contains(job) else { return }
        if await perform(job) { forget(profileID: job.profileID) }
    }

    /// True when every step is done (a step with nothing left to do is done).
    private static func perform(_ job: Pending) async -> Bool {
        let profileID = job.profileID, careCatID = job.careCatID
        guard let profile = UUID(uuidString: profileID) else { return true }
        func matches(_ value: String?) -> Bool {
            value.flatMap(UUID.init(uuidString:)) == profile
        }
        let care = CareHandoffStore.shared
        let evacuation = EvacuationStore.shared
        let keepsCareRecord = job.keepsCareRecord
        var done = true
        if keepsCareRecord {
            guard let careCatID else { return true }
            // The record no longer names the deleted profile.
            done = CatCareStore.shared.update { state in
                for index in state.cats.indices where state.cats[index].catID == careCatID
                    && state.cats[index].profileID == profile {
                    state.cats[index].profileID = nil
                }
            } && done
            if care.plan.cats.contains(where: { matches($0.profileID) }) {
                done = care.update { plan in
                    for index in plan.cats.indices where matches(plan.cats[index].profileID) {
                        plan.cats[index].profileID = nil
                        plan.cats[index].toolCatID = careCatID
                    }
                } && done
            }
            if evacuation.plan.cats.contains(where: { matches($0.profileID) }) {
                done = evacuation.update { plan in
                    for index in plan.cats.indices where matches(plan.cats[index].profileID) {
                        plan.cats[index].profileID = nil
                        plan.cats[index].toolCatID = careCatID
                    }
                } && done
            }
            // 11/21: the 迷子のとき draft follows the family's cat too (its key
            // is now the household cat ID), so its page reaches it. Moved,
            // never dropped: one already there is left as it is.
            let lost = LostCatDraftStore.shared
            let newKey = "guest-tool-" + careCatID.uuidString
            for key in Set([profileID, profileID.uppercased(), profileID.lowercased()]) {
                guard let draft = lost.drafts[key] else { continue }
                guard lost.drafts[newKey] == nil else { continue }
                do {
                    try lost.save(draft, for: newKey)
                    try lost.delete(for: key)
                } catch { done = false }
            }
            // 11/21: the cat's 病院 memos and 迷子の備え follow it too.
            done = await VeterinaryVisitStore.refile(fromProfileID: profileID, toCatID: careCatID) && done
            done = CatPreparednessStore.move(fromProfileID: profileID, toCatID: careCatID) && done
            return done
        }
        if care.plan.cats.contains(where: { matches($0.profileID) }) {
            done = care.update { $0.cats.removeAll { matches($0.profileID) } } && done
        }
        let evacuationIDs = evacuation.plan.cats.filter { matches($0.profileID) }.map(\.id)
        if !evacuationIDs.isEmpty {
            let departed = CatFarewell.departedIdentifiers()
            done = evacuation.update { plan in evacuationIDs.forEach { plan.removeCat($0, departed: departed) } } && done
        }
        for key in Set([profileID, profileID.uppercased()]) {
            do { try CatPreparednessStore.shared.delete(for: key) } catch { done = false }
            do { try LostCatDraftStore.shared.delete(for: key) } catch { done = false }
        }
        let ids = Set([careCatID, profile].compactMap { $0 })
        let now = Date()
        done = CatCareStore.shared.update { state in
            for index in state.cats.indices where state.cats[index].deletedAt == nil
                && (ids.contains(state.cats[index].catID) || state.cats[index].profileID == profile) {
                state.cats[index].deletedAt = now
                // Its photos are named no more, so their files leave too
                // (CatCareStore removes a file only when nothing names it).
                state.cats[index].facePhoto = nil
                state.cats[index].bodyPhoto = nil
                for entry in state.cats[index].vaccinations.indices {
                    state.cats[index].vaccinations[entry].proof = nil
                }
                state.cats[index].detachedVaccinations = nil
            }
        } && done
        let vet = VeterinaryVisitStore.shared
        do {
            for visit in try await vet.visits() where ids.contains(visit.catID) {
                try await vet.delete(visitID: visit.id, expectedRevision: visit.revision)
            }
        } catch { done = false }
        return done
    }
}

/// Test builds only: the day a cat passed away (ねこのまど_ペットロスの方針_1028).
/// Kept on this iPhone until the saved records can hold it. Nothing is
/// deleted: the photos and records stay; the age stops at this day.
enum CatFarewell {
    static let key = "debug.catFarewell.days.v1"
    /// 11/15: the 旅立った日 the family shared in the notebook (someone chose
    /// to send it), by the same keys. Read only; set by the notebook when it
    /// is read, never saved here.
    static var familyDays: [String: CatCareDay] = [:]

    /// 11/20: read entry by entry, so one unreadable entry hides no other.
    /// The record's copy (CatHouseholdIdentityState.farewellDays) is kept the
    /// same by AppRecordLinkRetry, so 保存 carries the day.
    static func days(_ json: String) -> [String: CatCareDay] {
        (CatFarewellDay.decodeAll(json) ?? [:]).compactMapValues {
            CatCareDay(year: $0.year, month: $0.month, day: $0.day)
        }
    }

    /// An unreadable value is never replaced by a new, smaller one: the
    /// change is not made and the stored text stays exactly as it was.
    static func setting(_ day: CatCareDay?, for subject: String, in json: String) -> String {
        guard var all = CatFarewellDay.decodeAll(json) else { return json }
        all[subject] = day.map { CatFarewellDay(year: $0.year, month: $0.month, day: $0.day) }
        return CatFarewellDay.encodeAll(all, keepingUnreadableFrom: json)
    }

    static func text(_ day: CatCareDay) -> String {
        "\(day.year)年\(day.month)月\(day.day)日"
    }

    /// The profiles whose day is recorded: they do not count toward the
    /// 10 living cats (11/14). Read where SwiftUI's @AppStorage is not at hand.
    static func departedIdentifiers(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(days(defaults.string(forKey: key) ?? "").keys).union(familyDays.keys)
    }
}

/// Recording the day, quietly: a date and one sentence, nothing to fill in.
/// Reached only where someone goes looking at that time (deleting the cat's
/// profile), never from a page that is open every day.
struct CatFarewellEditor: View {
    let name: String
    let recorded: CatCareDay?
    let save: (CatCareDay?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("旅立った日", selection: $date, in: ...Date(), displayedComponents: .date)
                } footer: {
                    Text("写真や記録、ホーム画面のウィジェットは、すべてそのまま残ります。")
                }
                if recorded != nil {
                    Section {
                        Button("記録を消す", role: .destructive) { save(nil); dismiss() }
                    }
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("記録する") { save(CatCareDay(date: date)); dismiss() }
                        .accessibilityIdentifier("cat-farewell-save")
                }
            }
            .onAppear {
                if let recorded, let day = recorded.date() { date = day }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 「この子のこと」 from a tool: the cat's own page, the same page as the
/// cat's face in ツール; a guest cat's page under its name.
/// (11/7: it opened a title-only page that looked like another screen.)
struct CatCareSubjectView: View {
    let subject: CatCareSubject
    /// Every cat. Empty means only this cat.
    var profiles: [CatProfilePresentation] = []
    @ObservedObject private var store = CatCareStore.shared
    @Environment(\.toolProfileActions) private var profileActions

    var body: some View {
        // Opened from a tool, so the tool's frame stays: popping returns to it.
        Group {
            switch subject {
            case let .profile(profile):
                CatProfileDetailView(profile: profile, allProfiles: profiles.isEmpty ? [profile] : profiles,
                    manualCandidatePhotos: profile.manualCandidatePhotos, photoAlbumOptions: [],
                    actions: profileActions)
                    .onAppear {
                        store.importFromTools()
                        store.importBirthdays(profiles)
                        if profiles.isEmpty { store.importBirthdays([profile]) }
                    }
            case let .toolCat(id, name):
                CatCareDetailView(toolCatID: id, name: name)
                    .navigationTitle(subject.displayName)
                    .navigationBarTitleDisplayMode(.inline)
                    .onAppear { store.importFromTools() }
            }
        }
        .toolChrome()
    }
}

private struct CatCareInsideCatPageKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var catCareInsideCatPage: Bool {
        get { self[CatCareInsideCatPageKey.self] }
        set { self[CatCareInsideCatPageKey.self] = newValue }
    }
    /// 11/16: this iPhone's cats, set where the この子 tab opens a cat's
    /// 「この子のこと」, so its 「…」 offers 「並べ替え」. Nil elsewhere.
    var catOrderProfiles: [CatProfilePresentation]? {
        get { self[CatOrderProfilesKey.self] }
        set { self[CatOrderProfilesKey.self] = newValue }
    }
}

private struct CatOrderProfilesKey: EnvironmentKey {
    static let defaultValue: [CatProfilePresentation]? = nil
}

struct CatCareDetailView: View {
    let subject: CatCareSubject
    let otherProfiles: [CatProfilePresentation]
    @Binding var selectedProfileID: String?
    @ObservedObject private var store = CatCareStore.shared
    @Environment(\.toolProfileActions) private var profileActions
    @Environment(\.catOrderProfiles) private var orderProfiles
    /// 11/16: 「並べ替え」 in 「…」 (the この子 tab's one way in).
    @State private var reorders = false
    /// The cat this page last loaded, so coming back from a list does not
    /// reload over what is on screen.
    @State private var loadedKey: String?
    @State private var showsLifeDatesEditor = false
    @State private var showsFarewellEditor = false
    @AppStorage(CatFarewell.key) private var farewellJSON = ""
    /// Whether this cat's farewell day is shared with the family (1029h).
    /// Nil outside a family, or when it could not be read.
    @State private var farewellSharing: FamilyFarewellSharingState?
    @State private var showsFarewellSharing = false
    /// The cat's own name, photo and deleting, in 基本 (11/7: the page's
    /// old 写真 tab is gone, so these live here).
    @Environment(\.dismiss) private var dismiss
    @State private var showsKeyPhotoPicker = false
    @State private var showsNameEditor = false
    @State private var draftName = ""
    @State private var isSavingName = false
    @State private var nameSaveFailed = false
    @State private var showsDeleteConfirmation = false
    /// 11/15: 「家族の手帳とのつながりを外す」 was chosen in 「…」.
    @State private var confirmsUnlink = false
    @State private var unlinkFailed = false
    @State private var isDeleting = false
    @State private var deleteFailed = false
    /// 11/17: the family's representative photo, in 「…」 (off: nothing).
    @ObservedObject private var familyPhotos = FamilyRepresentativePhotos.shared
    @State private var familyPhotoQuestion: FamilyPhotoQuestion?
    @State private var familyPhotoReport: FamilyPhotoReportTarget?
    /// Opened from inside the family notebook: no second notebook on top of it.
    private var insideFamilyNotebook = false

    /// 1.0 (Version1), as the rest of the album.
    private var farewell: CatCareDay? {
        Version1.isOn ? CatFarewell.days(farewellJSON)[subject.key] : nil
    }

    init(profile: CatProfilePresentation, otherProfiles: [CatProfilePresentation],
         selectedProfileID: Binding<String?>) {
        subject = .profile(profile)
        self.otherProfiles = otherProfiles
        _selectedProfileID = selectedProfileID
    }

    init(toolCatID: UUID, name: String, insideFamilyNotebook: Bool = false) {
        subject = .toolCat(id: toolCatID, name: name)
        otherProfiles = []
        _selectedProfileID = .constant(nil)
        self.insideFamilyNotebook = insideFamilyNotebook
    }

    @Environment(\.scenePhase) private var scenePhase
    /// Inside the cat's page, which shows the family button for both tabs.
    @Environment(\.catCareInsideCatPage) private var insideCatPage
    @State private var draft = CatCareDraft()
    @ObservedObject private var familyNotebook = FamilyNotebookPrototype.shared
    @State private var savedDraft = CatCareDraft()
    /// What the store held when this page last read or wrote it. A choice
    /// not stored yet (持病「あり」 before its text) differs from it on purpose,
    /// so only a value that changed in the store is taken in (11/6).
    @State private var storedDraft = CatCareDraft()
    @State private var catID: UUID?
    @State private var autosave: Task<Void, Never>?
    /// Autosave did not go through. Said once on the screen, not as an alert
    /// each time typing stops (11/5); the next save that works clears it.
    @State private var autosaveFailed = false
    @State private var editing: CatCareListEditor?
    @State private var microchipInvalid = false
    /// 見分ける写真 (11/9): chosen here only; the tools show them.
    @State private var photoRole: CatCarePhotoRole?
    @State private var cropRequest: CatCarePhotoCropRequest?
    @State private var photoFailed = false

    /// This cat is in the family notebook (not just: this person has a family).
    private var sharedWithFamily: Bool {
        guard let catID else { return false }
        return familyNotebook.activeFamilyCats.contains { $0.toolID == catID }
    }

    /// The rows and the delete question, apart from `body` so the type
    /// checker stays fast.
    private var form: some View {
        Form { formContent }
            // 11/12 (round 2): the parts close together, as on the tools, so the
            // first rows show on the first screen of a small iPhone.
            .toolPageSpacing()
            // Once, when a row written here makes the page 「すべてそろっています」:
            // opening (or switching to) a cat that is already complete changes
            // the loaded cat in the same update, so it does not count.
            .sensoryFeedback(.success, trigger: careCompletion, condition: CareCompletion.justCompleted)
            .alert(deleteTitle, isPresented: $showsDeleteConfirmation) { deleteActions } message: {
                // 11/7: what goes, what stays, and that it is final. 11/21: the
                // tools' records of this cat go too (CatProfileDeletionCleanup).
                // A cat in the family notebook stays the family's cat.
                Text(sharedWithFamily
                     ? "このiPhoneの、この子のプロフィールが消えます。家族の手帳のこの子と、書いたことは残ります。元に戻せません。"
                     : "この子の記録と、ツールに書いたことが消えます。写真アプリの写真は残ります。元に戻せません。")
            }
            .confirmationDialog("家族の手帳とのつながりを外しますか？", isPresented: $confirmsUnlink, titleVisibility: .visible) {
                Button("つながりを外す", role: .destructive) { unlinkFromFamily() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この子の写真と、書いたことの控えは、このiPhoneに残ります。")
            }
            .alert("つながりを外せませんでした", isPresented: $unlinkFailed) { Button("閉じる", role: .cancel) {} }
                message: { Text("少し待ってから、もう一度お試しください。") }
            .sheet(isPresented: $reorders) {
                NavigationStack { CatOrderView(profiles: orderProfiles ?? [], actions: profileActions) }
            }
    }

    var body: some View {
        form
        // 11/16: a cat in the family notebook: pull down to read the family
        // once; what came shows here at once (takeFamilyWrites).
        .familyNotebookPullToRead(enabled: sharedWithFamily)
        .disabled(isDeleting)
        .navigationBarBackButtonHidden(isDeleting || isSavingName)
        // 11/12 (round 2): a pushed page like the tools, so the tab bar is
        // hidden here too, wherever the page opens from (the cat's face on
        // ツール included); the ツール list shows it again.
        .toolChrome()
        .onChange(of: draft) { _, _ in
            autosave?.cancel()
            autosave = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                save()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { autosave?.cancel(); save() }
        }
        .onDisappear { autosave?.cancel(); save() }
        .appRecordEditing(retainWhileHidden: draft != savedDraft || editing != nil || autosaveFailed
                          || showsNameEditor || isSavingName || showsKeyPhotoPicker
                          || photoRole != nil || cropRequest != nil)
        .familyNotebookToolSync(enabled: sharedWithFamily)
        .modifier(FamilyPhotoDialogs(question: $familyPhotoQuestion, reportTarget: $familyPhotoReport))
        .task(id: familyPhotoCatID) {
            // The photo 「…」 offers to report is the one this page's cat shows.
            if let cat = familyPhotoCatID, showsFamilyPhoto { await familyPhotos.read([cat]) }
        }
        .onChange(of: familyNotebook.familyWritesToCatCare) { _, _ in takeFamilyWrites() }
        // 11/21: memo weights reach a family cat's and a tool cat's page too
        // (a profile's page reads them where it opens, CatProfileDetailView).
        .task(id: catID) {
            if catID != nil, !isProfile { await store.importMemoWeights() }
        }
        .toolbar {
            // 11/12 (round 2): deleting the cat sits in 「…」, as deleting does
            // in every tool (it was the page's last red row).
            if isProfile {
                ToolbarItem(placement: .topBarTrailing) { moreMenu }
            } else if showsFamilyCatMenu {
                // A family cat's page: nothing to delete here, only the order
                // (and the family's photo, 11/17).
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canReorder { reorderButton }
                        familyPhotoItems
                    } label: {
                        Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("その他")
                    .accessibilityIdentifier("cat-care-more-menu")
                }
            }
            // 11/22: no family button here. 家族の手帳 is the last row of the
            // cat's card on この子 (one place; it was found by nobody here).
        }
        .sheet(item: $editing) { editor in
            CatCareListEntrySheet(editor: editor, catID: catID, saving: { result in apply(result) })
        }
        .sheet(item: $photoRole) { role in
            CatCareIdentifyingPhotoSheet(subject: subject, role: role) { photoFailed = !$0 }
        }
        .sheet(item: $cropRequest) { request in
            LostCatPhotoCropView(image: request.image) { data in
                guard let jpeg = CatCareFormat.cleanJPEG(data),
                      let ref = store.savePhoto(jpeg, sourceAssetID: nil, origin: request.origin) else { return false }
                let kept = setPhoto(ref, request.role)
                // 11/21: a copy not kept does not stay behind.
                if !kept { store.discardPhoto(ref) }
                return kept
            }
        }
        .sheet(isPresented: $showsFarewellEditor) {
            CatFarewellEditor(name: subject.displayName, recorded: farewell) { day in
                farewellJSON = CatFarewell.setting(day, for: subject.key, in: farewellJSON)
            }
        }
        .sheet(isPresented: $showsFarewellSharing) {
            if let catID {
                FamilyFarewellShareSheet(toolCatID: catID) { Task { await loadFarewellSharing() } }
            }
        }
        .task(id: "\(catID?.uuidString ?? "")|\(farewellJSON)|\(familyNotebook.hasFamily)") {
            await loadFarewellSharing()
        }
        .sheet(isPresented: $showsLifeDatesEditor) {
            if case let .profile(profile) = subject {
                CatProfileLifeReferenceEditor(profile: profile, save: profileActions.updateLifeDates)
            }
        }
        .sheet(isPresented: $showsKeyPhotoPicker) {
            if case let .profile(profile) = subject {
                NavigationStack {
                    // 11/13: this cat's photos first, then every other cat
                    // photo; one of those is added to this cat, then made
                    // its key photo, in one tap.
                    CatProfilePhotoPicker(
                        photos: profile.confirmedPhotos,
                        selectedIdentifier: profile.keyPhotoIdentifier,
                        choose: { await chooseKeyPhoto($0, for: profile) },
                        otherPhotos: profile.otherKeyPhotoCandidates,
                        otherHeading: "ほかの猫の写真"
                    )
                }
            }
        }
        .task(id: subject.key) {
            // Only when the cat changes: save the one shown before (the draft
            // still belongs to it), then load the new one.
            guard loadedKey != subject.key else { return }
            autosave?.cancel()
            save()
            load()
            loadedKey = subject.key
        }
    }

    // MARK: Sections

    /// The page, as 設定 (11/12): the photo and name, the ring, 見分ける写真,
    /// then the four parts, always open, each a list of rows that show what
    /// is written. Split in parts so the type checker stays fast.
    @ViewBuilder private var formContent: some View {
        // 11/7: the photo and name lead the page, so whose page it is shows first.
        if case let .profile(profile) = subject {
            profileHeading(profile)
        }
        if otherProfiles.count > 1 {
            Section {
                Picker("猫", selection: $selectedProfileID) {
                    ForEach(otherProfiles) { other in
                        Text(other.displayName).tag(Optional(other.identifier))
                    }
                }
                .accessibilityIdentifier("cat-care-cat-picker")
            }
        }
        statusSections
        // 11/22: no ring and 「あと…つで…そろいます」 line here; each tool's
        // 「この子のこと」 row says what that tool still needs.
        // 11/9: the photos every tool shows, open on the page, so a tool's
        // 「この子のこと」を開く lands right on them.
        identifyingPhotosSection
        // 11/12: the four parts are always open, each with how full it is in
        // its header; a row shows what is written and opens it.
        basicsSection
        healthSection
        livingSection
        householdSection
    }

    @ViewBuilder private var statusSections: some View {
        if let message = store.loadError {
            Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        } else if store.unreadableCatCount > 0 {
            Section {
                Label("開けない記録があるので、いまは保存できません。App Storeでアプリを最新にしてください。",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        if deleteFailed {
            Section {
                Text("削除できませんでした。もう一度お試しください。")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        if autosaveFailed {
            Section {
                Label("保存できませんでした。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("cat-care-save-failed")
                Button("もう一度") { save() }
                    .accessibilityIdentifier("cat-care-save-retry")
            }
        }
    }

    static func photoTitle(_ role: CatCarePhotoRole) -> String { role == .face ? "顔の写真" : "全身の写真" }

    private func photoFile(_ role: CatCarePhotoRole) -> URL? {
        guard let ref = currentRecord?.identifyingPhoto(role)?.value ?? nil,
              let url = store.photoURL(ref), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 見分ける写真: the face and the whole body, the photos 迷子・避難・預ける use.
    /// 11/12: two equal squares the photos fill (no gray bars), with their
    /// names under them and 「⋯」 on the photo. Round 2: the two squares share
    /// the card's whole width (a third square's room was left empty).
    private var identifyingPhotosSection: some View {
        Section {
            // 11/20: with no photo yet, two low dashed tiles, so the 基本 rows
            // show on the first screen; one photo in, both squares again.
            let noPhotos = CatCarePhotoRole.allCases.allSatisfy { photoFile($0) == nil }
            HStack(alignment: .top, spacing: 12) {
                ForEach(CatCarePhotoRole.allCases) { role in
                    let title = Self.photoTitle(role)
                    let file = photoFile(role)
                    ToolPhotoSlot(title, image: nil, file: file, disabled: catID == nil || !store.canSave,
                                  identifier: "cat-care-photo-\(role.rawValue)",
                                  actionsIdentifier: "cat-care-photo-actions-\(role.rawValue)",
                                  choose: { photoFailed = false; photoRole = role }) {
                        Button("写真を選び直す", systemImage: "photo") { photoFailed = false; photoRole = role }
                        if let file {
                            Button("切り取る", systemImage: "crop") { crop(role, file: file) }
                        }
                        Button("\(title)を外す", systemImage: "minus.circle", role: .destructive) {
                            setPhoto(nil, role)
                        }
                    }
                    .filledSquare()
                    .lowWhileEmpty(noPhotos)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            if photoFailed {
                Text("写真を保存できませんでした。もう一度お試しください。")
                    .font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("見分ける写真")
        }
        .accessibilityIdentifier("cat-care-identifying-photos")
    }

    private func crop(_ role: CatCarePhotoRole, file: URL) {
        guard let image = UIImage(contentsOfFile: file.path) else { photoFailed = true; return }
        let origin = (currentRecord?.identifyingPhoto(role)?.value ?? nil)?.origin ?? .photos
        cropRequest = CatCarePhotoCropRequest(role: role, image: image, origin: origin)
    }

    /// One photo set or taken off, saved at once (not with the typed draft).
    @discardableResult
    private func setPhoto(_ ref: CatCarePhotoRef?, _ role: CatCarePhotoRole) -> Bool {
        guard let catID else { photoFailed = true; return false }
        let saved = store.setIdentifyingPhoto(ref, role, catID: catID)
        photoFailed = !saved
        return saved
    }

    /// The loaded cat and whether its page is all in, for the one haptic.
    private struct CareCompletion: Equatable {
        let cat: String?
        let complete: Bool

        static func justCompleted(_ old: CareCompletion, _ new: CareCompletion) -> Bool {
            new.cat != nil && old.cat == new.cat && !old.complete && new.complete
        }
    }

    /// Apart from `body`, so the type checker stays fast.
    private var careCompletion: CareCompletion {
        CareCompletion(cat: loadedKey == subject.key ? loadedKey : nil, complete: progress.filled >= progress.total)
    }

    /// The same count as the ring on the ツール tab, so a row filled here moves it.
    private var progress: CatCareProgress {
        var lifeDates: Bool?
        if case let .profile(profile) = subject { lifeDates = profile.lifeReference != nil }
        return CatCareProgress(draft: draft, record: currentRecord, hasLifeDates: lifeDates)
    }

    /// 「ミケ（4歳）」 and what the dates are for: read-only facts go in the footer, not in rows.
    private var basicsFooter: String {
        var line = subject.displayName
        if let birthday = currentRecord?.birthday?.value ?? nil,
           let age = CatCareLostCat.age(birthday, today: farewell ?? CatCareDay(date: Date())) {
            line += farewell == nil ? "（\(age)）" : "（\(age)まで）"
        }
        if case let .profile(profile) = subject {
            line += "\n" + profile.lifeDatesExplanation
        }
        return line
    }

    /// The heading's one quiet line, from what is written (11/12): 「オス・4歳」.
    /// Unknown parts are left out; nothing known, no line. The age stops at a
    /// recorded farewell day, worded as the 基本 footer words it (「4歳まで」).
    private var summaryLine: String? {
        var parts: [String] = []
        switch draft.sex {
        case .male: parts.append("オス")
        case .female: parts.append("メス")
        case .unknown: break
        }
        if let birthday = currentRecord?.birthday?.value ?? nil,
           let age = CatCareLostCat.age(birthday, today: farewell ?? CatCareDay(date: Date())) {
            parts.append(farewell == nil ? age : age + "まで")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    // MARK: Rows (11/12, as 設定 and 病院で見せる)

    /// A part's header: its name, and one green check once it is full.
    private func partHeader(_ title: String, _ count: (Int, Int), key: String) -> some View {
        let full = count.0 >= count.1
        // 11/12 (round 2): one green check once full (words and numbers were
        // mixed down the page's headers). 11/20: no 「3 / 7」 any more; the
        // ring at the top was a second way of counting.
        return HStack {
            Text(title)
            Spacer()
            if full {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityIdentifier("cat-care-part-\(key)")
    }

    /// A toggle's name with its icon, the same as a ToolValueRow's. 11/22:
    /// the choices are ToolChoiceRow (nothing at the side until one is chosen).
    private static func rowLabel(_ title: String, _ systemImage: String) -> some View {
        Label {
            Text(title).foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(Color.accentColor)
        }
    }

    /// Who in the family wrote it, under the row, as under the old fields.
    @ViewBuilder private func noted<Row: View>(_ row: Row, _ field: FamilyNotebookField?) -> some View {
        if let field { row.familyNotebookNote(catID, field) } else { row }
    }

    /// The first words of a written text, on one line; nil when empty.
    private static func firstWords(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(60))
    }

    /// A written item: its first words or 「未記入」; it opens a page with its
    /// one field. The field keeps its identifier there; the row adds 「-row」.
    private func textRow(_ item: CatCareTextItem) -> some View {
        let words = Self.firstWords(draft[keyPath: item.path])
        let problem = item.isMicrochip && microchipInvalid
        return NavigationLink { textPage(item) } label: {
            noted(ToolValueRow(title: item.title, systemImage: item.systemImage, value: words ?? ToolEmptyValue.unwritten,
                               filled: words != nil, problem: problem), item.note)
        }
        // The red value, in the words its page shows for it.
        .accessibilityHint(problem ? "15桁の数字にすると保存されます。" : "")
        .accessibilityIdentifier(item.identifier + "-row")
    }

    /// The page a written item opens: its one field, the same value in the
    /// draft (so the autosave and its checks are the page's own), the cursor
    /// in it; leaving saves what is pending.
    private func textPage(_ item: CatCareTextItem) -> some View {
        ToolPushedPage(title: item.title, focusesField: true, leave: { autosave?.cancel(); save() }) { focus in
            Section {
                CatCareTextField(item: item, text: $draft[dynamicMember: item.path], focus: focus)
            } footer: {
                if item.isMicrochip && microchipInvalid {
                    Label("15桁の数字にすると保存されます。", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                } else if !item.isMicrochip && !item.isPhone {
                    // 11/12 (round 2): the same counter as every page to write in.
                    ToolFieldCounter(count: draft[keyPath: item.path].count, limit: CatCareLimits.textCharacters)
                }
            }
        }
        .disabled(isDeleting)
    }

    /// A row that opens a sheet (the dates): the same look, with a chevron.
    private func sheetRow(_ title: String, _ systemImage: String, value: String, filled: Bool,
                          identifier: String, open: @escaping () -> Void) -> some View {
        ToolSheetRow(row: ToolValueRow(title: title, systemImage: systemImage, value: value, filled: filled),
                     action: open)
            .accessibilityIdentifier(identifier)
    }

    // MARK: 基本

    private var basicsSection: some View {
        Section {
            lifeDateRows
            sexPicker
            neuteredPicker
            indoorPicker
            textRow(.coat)
            textRow(.marks)
            microchipPicker
            if draft.microchipStatus == .recorded {
                textRow(.microchip)
            }
        } header: {
            partHeader("基本", progress.basics, key: "basics")
        } footer: {
            Text(basicsFooter)
                .accessibilityIdentifier("cat-care-basics")
        }
    }

    /// The dates are facts about the cat, so they live here with the rest;
    /// the album reads them from here.
    @ViewBuilder private var lifeDateRows: some View {
        if case let .profile(profile) = subject {
            sheetRow("誕生日・迎えた日", "birthday.cake", value: profile.lifeDatesSummary,
                     filled: profile.lifeReference != nil || profile.lifeDates.birthday != nil
                        || profile.lifeDates.adoptionDay != nil,
                     identifier: "cat-care-life-dates") { showsLifeDatesEditor = true }
        }
        if let farewell {
            sheetRow("旅立った日", "star", value: CatFarewell.text(farewell), filled: true,
                     identifier: "cat-care-farewell") { showsFarewellEditor = true }
        }
        if let farewellSharing, farewell != nil || farewellSharing.sharedDay != nil {
            sheetRow(farewell == nil ? "家族が記録した旅立った日" : "家族の手帳", "person.2",
                     value: FamilyNotebookWords.farewellStatus(farewellSharing), filled: true,
                     identifier: "cat-care-farewell-family") { showsFarewellSharing = true }
        }
    }

    private var sexPicker: some View {
        ToolChoiceRow(title: "性別", systemImage: "pawprint", selection: $draft.sex,
                      choices: [(CatCareSex.unknown, ToolEmptyValue.unset), (CatCareSex.male, "オス"), (CatCareSex.female, "メス")])
        .familyNotebookNote(catID, .sex)
        .accessibilityIdentifier("cat-care-sex")
    }

    private var neuteredPicker: some View {
        ToolChoiceRow(title: "去勢・避妊", systemImage: "checkmark.seal", selection: $draft.neutered,
                      choices: [(CatCareTriState.unknown, ToolEmptyValue.unset), (CatCareTriState.yes, "済み"), (CatCareTriState.no, "まだ")])
        .familyNotebookNote(catID, .neutered)
        .accessibilityIdentifier("cat-care-neutered")
    }

    private var indoorPicker: some View {
        ToolChoiceRow(title: "飼い方", systemImage: "house", selection: $draft.indoorOnly,
                      choices: [(CatCareTriState.unknown, ToolEmptyValue.unset), (CatCareTriState.yes, "室内だけ"), (CatCareTriState.no, "外にも出る")])  // 11/20: was 「室内飼い」, a yes/no label
        .familyNotebookNote(catID, .indoorOnly)
        .accessibilityIdentifier("cat-care-indoor")
    }

    private var microchipPicker: some View {
        ToolChoiceRow(title: "マイクロチップ", systemImage: "memorychip", selection: $draft.microchipStatus,
                      choices: [(CatCareMicrochipStatus.unknown, ToolEmptyValue.unset), (CatCareMicrochipStatus.recorded, "入っている"), (CatCareMicrochipStatus.none, "入っていない")])
        .familyNotebookNote(catID, .microchip)
        .accessibilityIdentifier("cat-care-microchip-status")
    }

    /// The key photo (tap to change) and the name (tap to rename), at the top
    /// of the page (11/7: moved from the page's old 写真 tab, then out of 基本).
    /// 11/12 (round 2): the photo two thirds the size and the gaps halved, so
    /// the first rows show on a small iPhone; one pencil, on the photo; the
    /// name once (the bar says 「この子のこと」).
    private func profileHeading(_ profile: CatProfilePresentation) -> some View {
        Section {
            VStack(spacing: 4) {
                // 11/13: any detected cat photo can be the key photo (it is
                // added to this cat first), so only an empty library stops it.
                let hasPhotos = profile.hasKeyPhotoChoices
                Button {
                    showsKeyPhotoPicker = true
                } label: {
                    CatProfileThumbnail(photo: profile.coverPhoto)
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                        // 11/7: a small badge says the photo can be changed.
                        .overlay(alignment: .bottomTrailing) {
                            if hasPhotos {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.title3)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Color.white, Color.accentColor)
                                    .background(Circle().fill(Color(.systemGroupedBackground)).padding(-2))
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(!hasPhotos)
                .accessibilityLabel("\(profile.displayName)の代表写真を変更")
                .accessibilityIdentifier("cat-care-key-photo")
                if !hasPhotos {
                    // No cat photo found at all yet: an honest one line.
                    Text("猫の写真が見つかると選べます")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("cat-care-key-photo-empty")
                }
                nameButton(profile)
                if let summaryLine {
                    // 11/12: one quiet line of what is known (「オス・4歳」).
                    Text(summaryLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("cat-care-summary")
                }
                if nameSaveFailed {
                    Text("名前を保存できませんでした。もう一度お試しください。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("cat-profile-name-failed")
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .alert("名前を変更", isPresented: $showsNameEditor) {
                TextField("名前", text: VisibleTextInput.catName($draftName))
                    .accessibilityIdentifier("cat-profile-name-field")
                Button("保存") { saveName(profile) }
                Button("キャンセル", role: .cancel) {}
            }
        }
    }

    /// 11/11: the name is changed in the system's own small dialog
    /// (keyboard up at once, 保存 / キャンセル where iOS puts them).
    /// A field with two text buttons opened under the name, with
    /// the name still above it, and read as a broken row.
    /// 11/12 (round 2): the name alone is the button (its second pencil is
    /// gone: one pencil on the page, on the photo).
    private func nameButton(_ profile: CatProfilePresentation) -> some View {
        Button {
            draftName = profile.name ?? ""
            nameSaveFailed = false
            showsNameEditor = true
        } label: {
            Text(profile.displayName)
                .font(.title2.bold())
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSavingName)
        .accessibilityLabel("\(profile.displayName)、名前を変更")
        .accessibilityIdentifier("cat-profile-rename")
    }

    /// An empty name keeps the old one: the dialog cannot grey out 保存.
    private func saveName(_ profile: CatProfilePresentation) {
        guard let name = CatNameText.saving(draftName) else { return }
        isSavingName = true
        nameSaveFailed = false
        Task {
            let saved = await profileActions.updateName(profile.identifier, name)
            isSavingName = false
            nameSaveFailed = !saved
        }
    }

    /// The key photo must be one of this cat's photos (the model's rule), so
    /// a photo not added yet is added first, the same as 「この子の写真を
    /// 追加」 (an explicit 「この子」), then set; one tap either way.
    private func chooseKeyPhoto(_ identifier: String, for profile: CatProfilePresentation) async -> Bool {
        let assigned = profile.confirmedPhotos.contains { $0.localIdentifier == identifier }
        if !assigned {
            guard await profileActions.confirmProfileMembership(profile.identifier, [identifier]) else { return false }
        }
        return await profileActions.setKeyPhoto(profile.identifier, identifier)
    }

    private var isProfile: Bool {
        if case .profile = subject { return true }
        return false
    }

    /// A family cat's page with something in its 「…」 (the order, the family's photo).
    private var showsFamilyCatMenu: Bool {
        canReorder || familyPhotoCatID.map({ FamilyPhotoMenuItems.hasItems(cat: $0) }) == true
    }

    /// Deleting the cat, in 「…」 at the top right (11/12, round 2; it was the
    /// page's last row). The confirmation also offers to record the day
    /// instead, as before (11/7: moved from 写真).
    private var moreMenu: some View {
        ToolMoreMenu(destructiveTitle: "この子を削除", itemIdentifier: "cat-profile-delete",
                     menuIdentifier: "cat-care-more-menu") {
            deleteFailed = false
            showsDeleteConfirmation = true
        } extra: {
            if canReorder { reorderButton }
            // 11/15: only a cat this iPhone linked to a family cat; the one
            // place to undo 「同じ子」.
            if case let .profile(profile) = subject, familyNotebook.unlinkOffered(profile: profile.identifier) {
                Button("家族の手帳とのつながりを外す", systemImage: "link") { confirmsUnlink = true }
                    .accessibilityIdentifier("cat-profile-family-unlink")
            }
        }
        .disabled(isDeleting)
    }

    // MARK: The family's representative photo (11/17)

    /// The family notebook's cat this page is (nil: not in it, or the photo is off).
    private var familyPhotoCatID: UUID? {
        guard familyPhotos.isOn else { return nil }
        let tool: UUID?
        if case let .toolCat(id, _) = subject { tool = id } else { tool = catID }
        guard let tool else { return nil }
        return familyNotebook.activeFamilyCats.first { $0.toolID == tool }?.id
    }

    /// A family cat with no cat of this iPhone: its page shows the family's photo.
    private var showsFamilyPhoto: Bool {
        if case .toolCat = subject { return true }
        return false
    }

    /// A family cat's own page: the photo it shows (report, not show this
    /// person's photos). 11/19: a cat of this iPhone has nothing here; the
    /// creator's key photo goes to the family by itself.
    @ViewBuilder private var familyPhotoItems: some View {
        if let cat = familyPhotoCatID, showsFamilyPhoto {
            FamilyPhotoMenuItems(cat: cat, question: $familyPhotoQuestion, reportTarget: $familyPhotoReport)
        }
    }

    /// From two cats, the family notebook's included (CatOrderView).
    private var canReorder: Bool {
        guard let orderProfiles else { return false }
        return orderProfiles.count + familyNotebook.unlinkedFamilyCats.count >= 2
    }

    private var reorderButton: some View {
        Button("並べ替え", systemImage: "arrow.up.arrow.down") { reorders = true }
            .accessibilityIdentifier("cat-care-reorder")
    }

    private func unlinkFromFamily() {
        guard case let .profile(profile) = subject else { return }
        do { try familyNotebook.unlink(profile: profile.identifier) } catch { unlinkFailed = true }
    }

    private var deleteTitle: String { "\(subject.displayName)を削除しますか？" }

    @ViewBuilder private var deleteActions: some View {
        if case let .profile(profile) = subject {
            Button("この子を削除", role: .destructive) { delete(profile) }
            // When a cat has died, deleting is usually where people go. Offer
            // to record the day instead; the button says what it opens.
            if farewell == nil, Version1.isOn {
                Button("旅立った日を記録する") { showsFarewellEditor = true }
            }
        }
        Button("キャンセル", role: .cancel) {}
    }

    private func delete(_ profile: CatProfilePresentation) {
        isDeleting = true
        deleteFailed = false
        // Read before the profile goes: whether this is the family's cat.
        let shared = sharedWithFamily
        Task {
            let deleted = await profileActions.deleteProfile(profile.identifier)
            isDeleting = false
            if deleted {
                // 11/21: what the tools kept for this cat goes too, so the
                // cat does not come back as a page of its own.
                CatProfileDeletionCleanup.run(profileID: profile.identifier, careCatID: catID,
                                              keepsCareRecord: shared)
                if shared { familyNotebook.forgetDeletedProfile(profile.identifier) }
                // The family's cat keeps its 旅立った日, under the key its
                // page uses from now on; a cat that is gone keeps none.
                let day = CatFarewell.days(farewellJSON)[subject.key]
                var days = CatFarewell.setting(nil, for: subject.key, in: farewellJSON)
                if shared, let catID, let day {
                    days = CatFarewell.setting(day, for: "tool-" + catID.uuidString, in: days)
                }
                farewellJSON = days
                dismiss()
            } else { deleteFailed = true }
        }
    }

    // MARK: 健康

    private var healthSection: some View {
        Section {
            conditionsPicker
            if draft.conditionsStatus == .recorded {
                textRow(.conditions)
            }
            allergyPicker
            if draft.allergyStatus == .recorded {
                textRow(.allergyText)
            }
            listRow(title: "体重", systemImage: "scalemass", detail: weightSummary, kind: .weight)
            listRow(title: "飲んでいる薬", systemImage: "pills", detail: medicationSummary, kind: .medication)
            listRow(title: "ワクチン", systemImage: "syringe", detail: vaccinationSummary, kind: .vaccination)
            vaccinationNoneToggle
        } header: {
            partHeader("健康", progress.health, key: "health")
        }
    }

    /// Like アレルギー: 「なし」 is an answer too, so a healthy cat's page can be all filled in.
    private var conditionsPicker: some View {
        ToolChoiceRow(title: "持病", systemImage: "heart.text.square", selection: $draft.conditionsStatus,
                      choices: [(CatCareConditionsStatus.unknown, ToolEmptyValue.unset), (CatCareConditionsStatus.none, "なし"), (CatCareConditionsStatus.recorded, "あり")])
        .familyNotebookNote(catID, .conditions)
        .accessibilityIdentifier("cat-care-conditions-status")
    }

    private var allergyPicker: some View {
        ToolChoiceRow(title: "アレルギー", systemImage: "allergens", selection: $draft.allergyStatus,
                      choices: [(CatCareAllergy.Status.unknown, ToolEmptyValue.unset), (CatCareAllergy.Status.none, "なし"), (CatCareAllergy.Status.recorded, "あり")])
        .familyNotebookNote(catID, .allergyStatus)
        .accessibilityIdentifier("cat-care-allergy-status")
    }

    /// No history to list: 「受けていない」 is an answer too.
    @ViewBuilder private var vaccinationNoneToggle: some View {
        if currentRecord?.activeVaccinations.isEmpty ?? true {
            Toggle(isOn: Binding(
                get: { draft.vaccinationStatus == CatCareVaccinationStatus.none },
                set: { draft.vaccinationStatus = $0 ? CatCareVaccinationStatus.none : .unknown })) {
                Self.rowLabel("ワクチンは受けていない", "minus.circle")
            }
            .accessibilityIdentifier("cat-care-vaccination-none")
        }
    }

    // MARK: 暮らし

    private var livingSection: some View {
        Section {
            listRow(title: "ごはん", systemImage: "fork.knife",
                    detail: CatCareFormat.meals(currentRecord?.activeMeals ?? []), kind: .meal)
            textRow(.specialDiet)
            textRow(.water)
            textRow(.litter)
            textRow(.temperament)
        } header: {
            partHeader("暮らし", progress.living, key: "living")
        }
    }

    // MARK: 家の情報

    private var householdSection: some View {
        Section {
            textRow(.ownerContact)
            textRow(.backupContact)
            vetPicker
            if draft.vetStatus == .recorded {
                textRow(.vetName)
                textRow(.vetPhone)
            }
            // 11/7: the family's meeting place is written only in 避難に備える
            // (one place); the stored value is kept and read there.
        } header: {
            partHeader("家の情報", progress.household, key: "household")
        } footer: {
            Text("ほかの猫とも共通です。")
        }
    }

    private var vetPicker: some View {
        ToolChoiceRow(title: "かかりつけ", systemImage: "cross.case", selection: $draft.vetStatus,
                      choices: [(CatCareVetStatus.unknown, ToolEmptyValue.unset), (CatCareVetStatus.recorded, "決まっている"), (CatCareVetStatus.none, "まだない")])
        .familyNotebookNote(catID, .vetName)
        .accessibilityIdentifier("cat-care-vet-status")
    }

    /// A list (体重・薬・ワクチン・ごはん): the same row look, opening its list.
    private func listRow(title: String, systemImage: String, detail: String,
                         kind: CatCareListEditor.Kind) -> some View {
        NavigationLink {
            CatCareListView(kind: kind, catID: catID, editing: $editing)
        } label: {
            ToolValueRow(title: title, systemImage: systemImage, value: detail, filled: detail != ToolEmptyValue.unwritten)
                .accessibilityValue(detail)
        }
        .disabled(catID == nil)
        .accessibilityIdentifier("cat-care-list-\(kind.rawValue)")
    }

    // MARK: Summaries

    private func loadFarewellSharing() async {
        guard familyNotebook.hasFamily, Version1.isOn, let catID else {
            farewellSharing = nil
            return
        }
        // Kept as shown when the read fails; a busy service is waited for.
        let service = FamilyNotebookSharing.shared.service
        if let loaded = try? await FamilyNotebookSharing.waitingForCheck({ try await service.loadFarewellSharing(toolCatID: catID) }) {
            farewellSharing = loaded
        }
    }

    private var currentRecord: CatCareRecord? { catID.flatMap { store.state?.record(catID: $0) } }

    private var weightSummary: String {
        guard let latest = currentRecord?.activeWeights.first else { return ToolEmptyValue.unwritten }
        return CatCareFormat.weight(latest.grams) + "（\(CatCareFormat.day(latest.measuredOn))）"
    }

    private var medicationSummary: String {
        let count = currentRecord?.activeMedications.count ?? 0
        return count == 0 ? ToolEmptyValue.unwritten : "\(count)件"
    }

    private var vaccinationSummary: String {
        guard let latest = currentRecord?.activeVaccinations.first else {
            return draft.vaccinationStatus == CatCareVaccinationStatus.none ? CatCareVaccinationStatus.noneText : ToolEmptyValue.unwritten
        }
        return "\(latest.kind)（\(CatCareFormat.day(latest.givenOn))）"
    }

    // MARK: Load and save

    private func load() {
        guard let record = store.ensureRecord(for: subject) else { catID = nil; return }
        catID = record.catID
        draft = CatCareDraft(record: record, household: store.state?.household ?? CatCareHousehold())
        savedDraft = draft
        storedDraft = draft
        microchipInvalid = false
        // 11/21: a number still being typed comes back with the page.
        if let unfinished = CatCareUnfinishedMicrochip.numbers[record.catID] {
            draft.microchipStatus = .recorded
            draft.microchip = unfinished
            microchipInvalid = true
        }
    }

    /// Saves what changed. A microchip number that is not 15 digits yet is
    /// kept on screen and not saved; everything else is saved.
    private func save() {
        guard let catID, draft != savedDraft, store.canSave else { return }
        var value = draft
        if draft.microchipStatus != .recorded {
            value.microchip = ""
            microchipInvalid = false
            CatCareUnfinishedMicrochip.numbers[catID] = nil
        } else if let chip = CatCareLimits.normalizedMicrochip(draft.microchip), !chip.isEmpty {
            value.microchip = chip
            microchipInvalid = false
            CatCareUnfinishedMicrochip.numbers[catID] = nil
        } else {
            // 「入っている」 with no full number yet: keep what was saved.
            value.microchipStatus = savedDraft.microchipStatus
            value.microchip = savedDraft.microchip
            let typed = draft.microchip.trimmingCharacters(in: .whitespacesAndNewlines)
            microchipInvalid = !typed.isEmpty
            // 11/21: kept while the app runs, so leaving the page or
            // switching cats does not lose the digits typed so far.
            CatCareUnfinishedMicrochip.numbers[catID] = typed.isEmpty ? nil : draft.microchip
        }
        // 11/20: a cat no longer in the file stores nothing; that is not saved.
        var written = false
        // 11/21: only what was changed on this page since it last read the
        // store; a family member's newer write to another field stays.
        let base = savedDraft
        let saved = store.update { state in
            guard let index = state.liveIndex(catID: catID) else { return }
            value.write(to: &state.cats[index], household: &state.household,
                        by: state.deviceID, now: Date(), since: base)
            written = true
        } && written
        // What was actually stored: an unfinished chip number stays out of it.
        if saved { UsageCounter.shared.count(.catCareEdited) }  // Usage (11/7): each autosave that stored a change
        if saved, let state = store.state, let record = state.record(catID: catID) {
            // 11/21: a field not changed here that someone else changed
            // meanwhile now shows their value (it was not written over).
            let fresh = CatCareDraft(record: record, household: state.household)
            savedDraft = value.takingOthersWrites(fresh, untouchedSince: base, stored: storedDraft)
            let shown = draft.takingOthersWrites(fresh, untouchedSince: base, stored: storedDraft)
            storedDraft = fresh
            if shown != draft { draft = shown }
        } else if saved { savedDraft = value }
        autosaveFailed = !saved
    }

    /// The family's writing came into 「この子のこと」 (test builds): show it.
    /// Items typed here and not saved yet stay as typed and are saved after.
    private func takeFamilyWrites() {
        guard let catID, let state = store.state, let record = state.record(catID: catID) else { return }
        let fresh = CatCareDraft(record: record, household: state.household)
        let next = draft.takingOthersWrites(fresh, untouchedSince: savedDraft, stored: storedDraft)
        savedDraft = fresh
        storedDraft = fresh
        draft = next
    }

    /// 11/21: nil once saved; else the sheet stays open with this line.
    private func apply(_ result: CatCareListEditor.Result) -> String? {
        guard let catID else { return CatCareListEditor.saveFailedSentence }
        return store.applyEntry(result, catID: catID)
    }
}

/// A written item of 「この子のこと」 (11/12): its row shows the first words and
/// opens a page with this one field. The example is the field's placeholder,
/// as before; the keyboard and the 15-digit check stay the same. Round 2: a
/// text of a sentence or more has a field of two lines or more, so its page
/// does not look empty; numbers and names keep one line.
private struct CatCareTextItem {
    let title: String
    let systemImage: String
    let example: String
    let path: WritableKeyPath<CatCareDraft, String>
    /// The field's identifier, on the page; the row's is this plus 「-row」.
    let identifier: String
    /// Who in the family wrote it, shown under the row.
    var note: FamilyNotebookField? = nil
    /// Several lines; nil: one line.
    var lines: ClosedRange<Int>? = nil
    var keyboard: UIKeyboardType = .default
    var isMicrochip = false
    /// 11/14: a telephone number (PhoneNumberInput).
    var isPhone = false

    // 基本
    static var coat: Self {
        Self(title: "毛色・柄", systemImage: "paintpalette", example: "例：キジトラ", path: \.coat,
             identifier: "cat-care-coat", note: .coat, lines: 2...6)
    }
    static var marks: Self {
        Self(title: "見分ける特徴", systemImage: "eye", example: "例：しっぽが短い、右耳に切れ込み", path: \.marks,
             identifier: "cat-care-marks", note: .marks, lines: 3...8)
    }
    static var microchip: Self {
        Self(title: "マイクロチップ番号", systemImage: "number", example: "15桁の数字", path: \.microchip,
             identifier: "cat-care-microchip", keyboard: .numberPad, isMicrochip: true)
    }
    // 健康
    static var conditions: Self {
        Self(title: "持病の内容", systemImage: "list.bullet.clipboard", example: "例：腎臓の療法食中",
             path: \.conditions, identifier: "cat-care-conditions-text", lines: 3...8)
    }
    static var allergyText: Self {
        Self(title: "アレルギーの内容", systemImage: "list.bullet.clipboard", example: "例：鶏肉", path: \.allergyText,
             identifier: "cat-care-allergy-text", note: .allergyText, lines: 2...6)
    }
    // 暮らし
    static var specialDiet: Self {
        Self(title: "食事の注意", systemImage: "leaf", example: "例：療法食、ほかの猫と分けてあげる",
             path: \.specialDiet, identifier: "cat-care-special-diet", note: .specialDiet, lines: 3...8)
    }
    static var water: Self {
        Self(title: "水", systemImage: "drop", example: "例：1日2回とりかえる", path: \.water,
             identifier: "cat-care-water", note: .water, lines: 2...6)
    }
    static var litter: Self {
        Self(title: "トイレ", systemImage: "tray", example: "例：システムトイレ・1日2回そうじ", path: \.litter,
             identifier: "cat-care-litter", note: .litter, lines: 2...6)
    }
    static var temperament: Self {
        Self(title: "接し方・苦手なこと", systemImage: "hand.raised", example: "例：抱っこが苦手",
             path: \.temperament, identifier: "cat-care-temperament", note: .temperament, lines: 3...8)
    }
    // 家の情報
    static var ownerContact: Self {
        Self(title: "飼い主の連絡先", systemImage: "phone", example: "例：090-1234-5678", path: \.ownerContact,
             identifier: "cat-care-owner-contact")
    }
    static var backupContact: Self {
        Self(title: "つながらないときの連絡先", systemImage: "person.crop.circle.badge.questionmark",
             example: "例：家族の名前と電話番号", path: \.backupContact, identifier: "cat-care-backup-contact",
             lines: 2...6)
    }
    static var vetName: Self {
        Self(title: "かかりつけ病院の名前", systemImage: "building.2", example: "例：みどり動物病院", path: \.vetName,
             identifier: "cat-care-vet-name")
    }
    static var vetPhone: Self {
        Self(title: "かかりつけ病院の電話", systemImage: "phone.circle", example: "例：03-1234-5678", path: \.vetPhone,
             identifier: "cat-care-vet-phone", note: .vetPhone, keyboard: .phonePad, isPhone: true)
    }
}

/// The one field on a written item's page. Its name is the page's title, so
/// the field shows only the example; VoiceOver reads the name.
private struct CatCareTextField: View {
    let item: CatCareTextItem
    @Binding var text: String
    let focus: FocusState<Bool>.Binding

    var body: some View {
        TextField(item.example, text: item.isPhone ? PhoneNumberInput.binding($text) : $text,
                  axis: item.lines == nil ? .horizontal : .vertical)
            .lineLimit(item.lines ?? (1...1))
            .keyboardType(item.keyboard)
            .textContentType(item.isPhone ? .telephoneNumber : nil)
            .font(item.isMicrochip ? Font.body.monospacedDigit() : Font.body)
            .focused(focus)
            .accessibilityLabel(item.title)
            .accessibilityIdentifier(item.identifier)
    }
}

// MARK: - Progress (what is filled, and what that makes)

/// Which entries are in: the ones a tool reads and every household can
/// answer (「なし」 counts). Optional rows (療法食, つながらないときの連絡先,
/// かかりつけの電話, 薬) can be written but are not counted, so a
/// full ring means ready, not 「every box typed in」. The ring on the ツール
/// tab and the parts' checks here use this one count (11/20: the parts no
/// longer show 「3 / 7」).
struct CatCareProgress {
    let basics: (Int, Int)
    let health: (Int, Int)
    let living: (Int, Int)
    let household: (Int, Int)
    /// The tool whose entries are closest to all in, for one line at the top.
    let nextHint: String?
    /// 11/20: that tool's own count (filled, total), for the ring beside the
    /// line, so the ring and the words count the same thing.
    let nextGroup: (Int, Int)?

    var filled: Int { basics.0 + health.0 + living.0 + household.0 }
    var total: Int { basics.1 + health.1 + living.1 + household.1 }

    /// `hasLifeDates` is nil for a tool's cat with no profile (no birthday row).
    init(draft: CatCareDraft, record: CatCareRecord?, hasLifeDates: Bool?) {
        func has(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func count(_ values: [Bool]) -> (Int, Int) { (values.filter { $0 }.count, values.count) }
        let meals = (record?.activeMeals.count ?? 0) > 0
        let weights = (record?.activeWeights.count ?? 0) > 0
        let vaccinations = (record?.activeVaccinations.count ?? 0) > 0
            || draft.vaccinationStatus == CatCareVaccinationStatus.none
        basics = count([has(draft.coat), has(draft.marks), draft.microchipFilled,
                        draft.sex != .unknown, draft.neutered != .unknown, draft.indoorOnly != .unknown]
                       + (hasLifeDates.map { [$0] } ?? []))
        health = count([draft.conditionsFilled, draft.allergyStatus != .unknown, weights, vaccinations])
        living = count([meals, has(draft.water), has(draft.litter), has(draft.temperament)])
        household = count([has(draft.ownerContact), draft.vetFilled])

        // What each tool reads first: 「あと2つで「預けるとき」の項目がそろいます」.
        let tools: [(String, [Bool])] = [
            ("迷子のとき", [has(draft.coat), has(draft.marks), has(draft.ownerContact)]),
            ("預けるとき", [meals, has(draft.water), has(draft.litter), has(draft.temperament), draft.vetFilled]),
            ("病院で見せる", [weights, vaccinations, draft.conditionsFilled, draft.allergyStatus != .unknown,
                          draft.vetFilled])
        ]
        let next = tools.map { ($0.0, $0.1.filter { !$0 }.count, $0.1.count) }
            .filter { $0.1 > 0 }
            .min { ($0.1, $0.0) < ($1.1, $1.0) }
        nextHint = next.map { "あと\($0.1)つで「\($0.0)」の項目がそろいます" }
        nextGroup = next.map { ($0.2 - $0.1, $0.2) }
    }
}

/// The ring around a cat: one arc that grows as この子のこと is filled.
struct CatCareRing: View {
    let progress: CatCareProgress
    let lineWidth: CGFloat
    /// 11/20: the ring beside 「あと N つで「…」の項目がそろいます」 shows that
    /// tool's count; with no such line, the whole page's.
    var followsNextHint = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var count: (Int, Int) {
        followsNextHint ? progress.nextGroup ?? (progress.filled, progress.total) : (progress.filled, progress.total)
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: count.1 == 0 ? 0 : CGFloat(count.0) / CGFloat(count.1))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: count.0)
        }
        .accessibilityHidden(true)
    }
}


// MARK: - Draft (single values edited on the page)

struct CatCareDraft: Equatable {
    var sex: CatCareSex = .unknown
    var neutered: CatCareTriState = .unknown
    var indoorOnly: CatCareTriState = .unknown
    var coat = ""
    var marks = ""
    var microchipStatus: CatCareMicrochipStatus = .unknown
    /// The number; only used while 「入っている」 is chosen.
    var microchip = ""
    /// Only an answer while there is no vaccination in the list.
    var vaccinationStatus: CatCareVaccinationStatus = .unknown
    var conditionsStatus: CatCareConditionsStatus = .unknown
    /// What the condition is; only used while 「あり」 is chosen.
    var conditions = ""
    var allergyStatus: CatCareAllergy.Status = .unknown
    var allergyText = ""
    var specialDiet = ""
    var water = ""
    var litter = ""
    var temperament = ""
    var ownerContact = ""
    var backupContact = ""
    var vetStatus: CatCareVetStatus = .unknown
    var vetName = ""
    var vetPhone = ""

    init() {}

    /// 「なし」, or 「あり」 with what it is.
    var conditionsFilled: Bool {
        conditionsStatus == CatCareConditionsStatus.none
            || (conditionsStatus == .recorded && !conditions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// 「入っていない」, or 「入っている」 with a full number.
    var microchipFilled: Bool {
        microchipStatus == CatCareMicrochipStatus.none
            || (microchipStatus == .recorded && !(CatCareLimits.normalizedMicrochip(microchip) ?? "").isEmpty)
    }

    /// 「まだない」, or 「決まっている」 with the hospital's name.
    var vetFilled: Bool {
        vetStatus == CatCareVetStatus.none
            || (vetStatus == .recorded && !vetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    init(record: CatCareRecord, household: CatCareHousehold) {
        sex = record.sex?.value ?? .unknown
        neutered = record.neutered?.value ?? .unknown
        indoorOnly = record.indoorOnly?.value ?? .unknown
        coat = record.coat?.value ?? ""
        marks = record.marks?.value ?? ""
        microchipStatus = record.microchipStatus
        microchip = microchipStatus == .recorded ? record.microchip?.value ?? "" : ""
        vaccinationStatus = record.vaccinationStatus
        conditionsStatus = record.conditionsStatus
        conditions = conditionsStatus == .recorded ? record.conditions?.value ?? "" : ""
        allergyStatus = record.allergy?.value.status ?? .unknown
        allergyText = record.allergy?.value.text ?? ""
        specialDiet = record.specialDiet?.value ?? ""
        water = record.water?.value ?? ""
        litter = record.litter?.value ?? ""
        temperament = record.temperament?.value ?? ""
        ownerContact = household.ownerContact?.value ?? ""
        backupContact = household.backupContact?.value ?? ""
        let effectiveVet = record.vetOverride?.value ?? household.vet?.value
        vetStatus = record.vetStatus(household: household)
        vetName = vetStatus == .recorded ? effectiveVet?.name ?? "" : ""
        vetPhone = vetStatus == .recorded ? effectiveVet?.phone ?? "" : ""
    }

    /// This draft with someone else's writes taken in: each field left as it
    /// was at `base` whose stored value moved from `stored` to `fresh`.
    func takingOthersWrites(_ fresh: CatCareDraft, untouchedSince base: CatCareDraft,
                            stored: CatCareDraft) -> CatCareDraft {
        var next = self
        func take<Value: Equatable>(_ path: WritableKeyPath<CatCareDraft, Value>) {
            if self[keyPath: path] == base[keyPath: path], fresh[keyPath: path] != stored[keyPath: path] {
                next[keyPath: path] = fresh[keyPath: path]
            }
        }
        take(\.sex); take(\.neutered); take(\.indoorOnly); take(\.allergyStatus); take(\.conditionsStatus)
        take(\.microchipStatus); take(\.vaccinationStatus); take(\.vetStatus)
        let texts: [WritableKeyPath<CatCareDraft, String>] = [
            \.coat, \.marks, \.microchip, \.conditions, \.allergyText, \.specialDiet, \.water, \.litter,
            \.temperament, \.ownerContact, \.backupContact, \.vetName, \.vetPhone]
        for path in texts { take(path) }
        return next
    }

    /// Writes only fields that changed, so each keeps its own who/when.
    /// 11/21: `base` is what the page opened with (or last stored). A field
    /// left as it was there is not written, so a family member's write that
    /// arrived meanwhile is never put back to the page's older value.
    func write(to r: inout CatCareRecord, household h: inout CatCareHousehold, by: String, now: Date,
               since base: CatCareDraft? = nil) {
        func changed<V: Equatable>(_ path: KeyPath<CatCareDraft, V>) -> Bool {
            guard let base else { return true }
            return self[keyPath: path] != base[keyPath: path]
        }
        func set<V: Codable & Equatable & Sendable>(_ field: inout CatCareStamped<V>?, _ value: V, empty: V,
                                                    changed: Bool) {
            guard changed else { return }
            if field?.value == value || (field == nil && value == empty) { return }
            field = .init(value: value, editedAt: now, editedBy: by)
        }
        func text(_ value: String) -> String { CatCareLimits.clippedText(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        set(&r.sex, sex, empty: .unknown, changed: changed(\.sex))
        set(&r.neutered, neutered, empty: .unknown, changed: changed(\.neutered))
        set(&r.indoorOnly, indoorOnly, empty: .unknown, changed: changed(\.indoorOnly))
        set(&r.coat, text(coat), empty: "", changed: changed(\.coat))
        set(&r.marks, text(marks), empty: "", changed: changed(\.marks))
        let chip = microchipStatus == .recorded ? microchip : ""
        if changed(\.microchipStatus) || changed(\.microchip),
           (microchipStatus, chip) != (r.microchipStatus, r.microchipStatus == .recorded ? r.microchip?.value ?? "" : "") {
            r.setMicrochip(status: microchipStatus, number: chip, editedAt: now, editedBy: by)
        }
        // A vaccination in the list is the answer; the toggle only speaks for an empty list.
        if changed(\.vaccinationStatus),
           r.activeVaccinations.isEmpty, vaccinationStatus != .recorded, vaccinationStatus != r.vaccinationStatus {
            r.setVaccinationStatus(vaccinationStatus, editedAt: now, editedBy: by)
        }
        // 「あり」 with 「なし」 typed in is the none choice; 「あり」 with nothing typed keeps what was saved.
        let details = conditionsStatus == .recorded ? text(conditions) : ""
        let status: CatCareConditionsStatus = CatCareConditionsStatus.reading(details) == CatCareConditionsStatus.none
            ? CatCareConditionsStatus.none : conditionsStatus
        if changed(\.conditionsStatus) || changed(\.conditions),
           (status, details) != (r.conditionsStatus, r.conditionsStatus == .recorded ? r.conditions?.value ?? "" : "") {
            r.setConditions(status: status, text: details, editedAt: now, editedBy: by)
        }
        set(&r.allergy, CatCareAllergy(status: allergyStatus, text: allergyStatus == .recorded ? text(allergyText) : ""),
            empty: CatCareAllergy(), changed: changed(\.allergyStatus) || changed(\.allergyText))
        set(&r.specialDiet, text(specialDiet), empty: "", changed: changed(\.specialDiet))
        set(&r.water, text(water), empty: "", changed: changed(\.water))
        set(&r.litter, text(litter), empty: "", changed: changed(\.litter))
        set(&r.temperament, text(temperament), empty: "", changed: changed(\.temperament))
        set(&h.ownerContact, text(ownerContact), empty: "", changed: changed(\.ownerContact))
        set(&h.backupContact, text(backupContact), empty: "", changed: changed(\.backupContact))
        let vet = vetStatus == .recorded ? (text(vetName), text(vetPhone)) : ("", "")
        let effectiveVet = r.vetOverride?.value ?? h.vet?.value
        let savedStatus = r.vetStatus(household: h)
        let savedVet = savedStatus == .recorded ? (effectiveVet?.name ?? "", effectiveVet?.phone ?? "") : ("", "")
        if changed(\.vetStatus) || changed(\.vetName) || changed(\.vetPhone),
           vetStatus != savedStatus || vet != savedVet {
            // Edit the same value the family/page reads. A received cat's vet
            // never overwrites unrelated cats' household-wide fallback.
            if r.vetOverride != nil {
                r.setVetOverride(status: vetStatus, name: vet.0, phone: vet.1, note: effectiveVet?.note ?? "", editedAt: now, editedBy: by)
            } else {
                h.setVet(status: vetStatus, name: vet.0, phone: vet.1, note: effectiveVet?.note ?? "", editedAt: now, editedBy: by)
            }
        }
        // 11/7: the meeting place is not written from here (避難に備える is its one place),
        // so a draft loaded earlier never overwrites what was written there.
        r.reviewedAt = now
    }
}

// MARK: - Growing lists: weight, medication, vaccination, meal

struct CatCareListEditor: Identifiable {
    enum Kind: String { case weight, medication, vaccination, meal }
    let id = UUID()
    let kind: Kind
    /// The record being changed; nil adds a new one.
    var entryID: UUID? = nil

    static let saveFailedSentence = "保存できませんでした。もう一度お試しください。"
    static let deletedMeanwhileSentence = "この記録は削除されています。"

    enum Result {
        case weight(grams: Int, day: CatCareDay, replacing: UUID? = nil)
        case medication(name: String, dose: String, schedule: String, replacing: UUID? = nil)
        case vaccination(kind: String, day: CatCareDay, proof: CatCarePhotoRef?, replacing: UUID? = nil)
        case meal(time: String, food: String, amount: String, replacing: UUID? = nil)
        case delete(kind: Kind, entryID: UUID)

        var kind: Kind {
            switch self {
            case .weight: .weight
            case .medication: .medication
            case .vaccination: .vaccination
            case .meal: .meal
            case let .delete(kind, _): kind
            }
        }

        /// The entry being changed, when this changes one.
        var replacing: UUID? {
            switch self {
            case let .weight(_, _, id), let .medication(_, _, _, id), let .vaccination(_, _, _, id), let .meal(_, _, _, id): id
            case .delete: nil
            }
        }

        /// 11/21: the entry this changes was deleted meanwhile (by the family
        /// or on another iPhone). A deletion is final in the family's
        /// notebook, so the change is not written into it; the sheet says so.
        func editsDeletedEntry(in r: CatCareRecord) -> Bool {
            guard let id = replacing else { return false }
            let deletedAt: Date?? = switch kind {
            case .weight: r.weights.first { $0.id == id }.map(\.deletedAt)
            case .medication: r.medications.first { $0.id == id }.map(\.deletedAt)
            case .vaccination: r.vaccinations.first { $0.id == id }.map(\.deletedAt)
            case .meal: r.meals.first { $0.id == id }.map(\.deletedAt)
            }
            return deletedAt.map { $0 != nil } ?? false
        }

        /// False when a new record was refused because the list is full
        /// (11/20: counted without deleted records, as the list shows them),
        /// or when the entry it changes was deleted (editsDeletedEntry).
        @discardableResult
        func apply(to r: inout CatCareRecord, by: String, now: Date) -> Bool {
            if editsDeletedEntry(in: r) { return false }
            switch self {
            case let .weight(grams, day, replacing):
                if let index = replacing.flatMap({ id in r.weights.firstIndex { $0.id == id } }) {
                    r.weights[index].grams = grams; r.weights[index].measuredOn = day
                    r.weights[index].editedAt = now; r.weights[index].editedBy = by
                    return true
                }
                guard r.activeWeights.count < CatCareLimits.maximumWeights else { return false }
                r.weights.append(.init(measuredOn: day, grams: grams, editedAt: now, editedBy: by))
            case let .medication(name, dose, schedule, replacing):
                if let index = replacing.flatMap({ id in r.medications.firstIndex { $0.id == id } }) {
                    r.medications[index].name = CatCareLimits.clippedText(name)
                    r.medications[index].dose = CatCareLimits.clippedText(dose)
                    r.medications[index].schedule = CatCareLimits.clippedText(schedule)
                    r.medications[index].editedAt = now; r.medications[index].editedBy = by
                    return true
                }
                guard r.activeMedications.count < CatCareLimits.maximumMedications else { return false }
                r.medications.append(.init(name: CatCareLimits.clippedText(name), dose: CatCareLimits.clippedText(dose),
                                           schedule: CatCareLimits.clippedText(schedule), editedAt: now, editedBy: by))
            case let .vaccination(kind, day, proof, replacing):
                if let index = replacing.flatMap({ id in r.vaccinations.firstIndex { $0.id == id } }) {
                    r.vaccinations[index].kind = CatCareLimits.clippedText(kind)
                    r.vaccinations[index].givenOn = day
                    r.replaceVaccinationProof(proof, for: r.vaccinations[index].id)
                    r.vaccinations[index].editedAt = now; r.vaccinations[index].editedBy = by
                    return true
                }
                guard r.activeVaccinations.count < CatCareLimits.maximumVaccinations else { return false }
                r.vaccinations.append(.init(kind: CatCareLimits.clippedText(kind), givenOn: day, proof: proof,
                                            editedAt: now, editedBy: by))
            case let .meal(time, food, amount, replacing):
                if let index = replacing.flatMap({ id in r.meals.firstIndex { $0.id == id } }) {
                    r.meals[index].time = time; r.meals[index].food = food; r.meals[index].amount = amount
                    r.meals[index].editedAt = now; r.meals[index].editedBy = by
                    return true
                }
                guard r.activeMeals.count < CatCareLimits.maximumMeals else { return false }
                r.meals.append(.init(time: time, food: food, amount: amount,
                                     order: (r.activeMeals.map(\.order).max() ?? -1) + 1,
                                     editedAt: now, editedBy: by))
            case let .delete(kind, entryID):
                // Mark, never remove: a shared copy must not bring it back.
                switch kind {
                case .weight: r.weights.markDeleted(entryID, at: now, by: by)
                case .medication: r.medications.markDeleted(entryID, at: now, by: by)
                case .vaccination:
                    // 11/21: its proof photo is named no more, so the file
                    // leaves too (only when no saved copy names it).
                    if r.vaccinations.contains(where: { $0.id == entryID && $0.deletedAt == nil }) {
                        r.replaceVaccinationProof(nil, for: entryID)
                    }
                    r.vaccinations.markDeleted(entryID, at: now, by: by)
                case .meal: r.meals.markDeleted(entryID, at: now, by: by)
                }
            }
            return true
        }
    }
}

/// 11/14: each list's limit, counted as the store counts it, and the one
/// sentence shown where 「追加」 was.
extension CatCareListEditor.Kind {
    var limit: Int {
        switch self {
        case .weight: CatCareLimits.maximumWeights
        case .medication: CatCareLimits.maximumMedications
        case .vaccination: CatCareLimits.maximumVaccinations
        case .meal: CatCareLimits.maximumMeals
        }
    }

    func isFull(_ record: CatCareRecord?) -> Bool {
        guard let r = record else { return false }
        switch self {
        case .weight: return r.activeWeights.count >= limit
        case .medication: return r.activeMedications.count >= limit
        case .vaccination: return r.activeVaccinations.count >= limit
        case .meal: return r.activeMeals.count >= limit
        }
    }

    var limitSentence: String { AppLimitCopy.items(CatCareFormat.title(self), limit) }
}

struct CatCareListView: View {
    let kind: CatCareListEditor.Kind
    let catID: UUID?
    @Binding var editing: CatCareListEditor?
    @ObservedObject private var store = CatCareStore.shared
    @State private var pendingDelete: UUID?

    private var record: CatCareRecord? { catID.flatMap { store.state?.record(catID: $0) } }

    /// Every record opens to be changed; deleting is a button there (and a
    /// swipe), always with a confirmation.
    private func row<Content: View>(_ id: UUID, @ViewBuilder _ content: () -> Content) -> some View {
        Button { editing = CatCareListEditor(kind: kind, entryID: id) } label: {
            // 11/7: a chevron, so the row reads as one that opens.
            HStack {
                content().frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("押すと直せます。削除もここからできます")
        .swipeActions { Button("削除", role: .destructive) { pendingDelete = id } }
    }

    var body: some View {
        List {
            switch kind {
            case .weight:
                ForEach(record?.activeWeights ?? []) { entry in
                    row(entry.id) {
                        LabeledContent(CatCareFormat.day(entry.measuredOn), value: CatCareFormat.weight(entry.grams))
                    }
                }
            case .medication:
                ForEach(record?.activeMedications ?? []) { entry in
                    row(entry.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.body.weight(.semibold))
                            Text([entry.dose, entry.schedule].filter { !$0.isEmpty }.joined(separator: "・"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            case .vaccination:
                ForEach(record?.activeVaccinations ?? []) { entry in
                    row(entry.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            LabeledContent(entry.kind, value: CatCareFormat.day(entry.givenOn))
                            if record?.vaccinationProof(entry.id) != nil {
                                Label("証明の写真あり", systemImage: "doc.text.image")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ForEach(record?.unmatchedVaccinationProofs ?? [], id: \.displayKey) { photo in
                    if let proof = photo.proof {
                        DetachedToolPhotoRow(title: "証明の写真", load: {
                            guard let url = store.photoURL(proof) else { return nil }
                            return try Data(contentsOf: url)
                        }, remove: {
                            guard let catID else { return }
                            store.update { state in
                                guard let i = state.liveIndex(catID: catID) else { return }
                                state.cats[i].removeUnmatchedVaccinationProof(photo)
                            }
                        })
                        .id(proof.fileName)
                        .accessibilityIdentifier("cat-care-restored-vaccine-proof")
                    }
                }
            case .meal:
                ForEach(record?.activeMeals ?? []) { entry in
                    row(entry.id) {
                        LabeledContent(entry.time.isEmpty ? "時間は未記入" : entry.time,
                                       value: [entry.food, entry.amount].filter { !$0.isEmpty }.joined(separator: " "))
                    }
                }
            }
        }
        .overlay {
            if isEmpty {
                ContentUnavailableView("まだ記録がありません", systemImage: "square.and.pencil")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if kind.isFull(record) {
                    LimitNote(kind.limitSentence)
                }
                Button { editing = CatCareListEditor(kind: kind) } label: {
                    Label(CatCareFormat.title(kind) + "を追加", systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canSave || kind.isFull(record))
                .accessibilityIdentifier("cat-care-add-\(kind.rawValue)")
            }
            .padding().background(.regularMaterial)
        }
        .navigationTitle(CatCareFormat.title(kind))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: CatCareListEntrySheet.deleteRequested)) { note in
            if let id = note.object as? UUID { pendingDelete = id }
        }
        .confirmationDialog("この記録を削除しますか？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let id = pendingDelete { delete(id) }
                pendingDelete = nil
            }
            .accessibilityIdentifier("cat-care-confirm-delete")
            Button("キャンセル", role: .cancel) { pendingDelete = nil }
        } message: { Text("削除した記録は、ほかのツールにも載らなくなります。元に戻せません。") }
    }

    private var isEmpty: Bool {
        switch kind {
        case .weight: record?.activeWeights.isEmpty ?? true
        case .medication: record?.activeMedications.isEmpty ?? true
        case .vaccination: (record?.activeVaccinations.isEmpty ?? true) && (record?.unmatchedVaccinationProofs.isEmpty ?? true)
        case .meal: record?.activeMeals.isEmpty ?? true
        }
    }

    private func delete(_ id: UUID) {
        guard let catID else { return }
        store.update { state in
            guard let index = state.liveIndex(catID: catID) else { return }
            CatCareListEditor.Result.delete(kind: kind, entryID: id)
                .apply(to: &state.cats[index], by: state.deviceID, now: Date())
        }
    }
}

#if DEBUG
struct CatCareFamilyProofRestoreFixture: View {
    private let cat = UUID()
    private let vaccination = UUID()
    private let link = String(repeating: "3", count: 64)
    @State private var editing: CatCareListEditor?
    @State private var ready = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            if ready {
                CatCareListView(kind: .vaccination, catID: cat, editing: $editing)
                    .toolbar { Button("試験の再招待", action: receiveAgain).accessibilityIdentifier("fixture-reinvite-proof") }
            } else if failed { Text("試験データを作れませんでした") }
            else { ProgressView() }
        }
        .task { if !ready && !failed { restore() } }
    }

    private func restore() {
        do {
            let now = Date(), day = CatCareDay(isoDay: "2026-01-20")!
            var own = CatCareState(deviceID: "fixture-original", now: now)
            own.cats = [.init(catID: cat)]
            let before = try CatCareDecoding.encode(own)
            var display = own
            display.cats[0].vaccinations = [.init(id: vaccination, kind: "試験のワクチン", givenOn: day,
                                                familyPhotoLink: link, editedAt: now, editedBy: "family:fixture")]
            let received = try FamilyNotebookRecordOrigin.recording(CatCareDecoding.encode(display), over: before, tool: "CatCare", family: true)
            let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).jpegData(withCompressionQuality: 0.8) { context in
                context.cgContext.setFillColor(UIColor.systemTeal.cgColor)
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            guard let proof = CatCareStore.shared.savePhoto(jpeg, sourceAssetID: nil, origin: .camera) else { failed = true; return }
            display.cats[0].vaccinations[0].proof = proof
            display.cats[0].vaccinations[0].editedBy = "fixture-original"
            let mixed = try FamilyNotebookRecordOrigin.recording(CatCareDecoding.encode(display), over: received, tool: "CatCare", family: false)
            let portable = try CatCareDecoding.personalBackup(mixed)
            let restored = try CatCareDecoding.portable(portable, deviceID: "fixture-restored")
            let file = AppRecordDataset.directory("CatCare").appendingPathComponent("state.json")
            try AppRecordJSON.write(restored, to: file)
            CatCareStore.shared.reload(); ready = true
        } catch { failed = true }
    }

    private func receiveAgain() {
        CatCareStore.shared.update(familyProjection: true) { state in
            guard let i = state.cats.firstIndex(where: { $0.catID == cat }) else { return }
            state.cats[i].vaccinations = [.init(kind: "試験のワクチン", givenOn: CatCareDay(isoDay: "2026-01-20")!,
                                               familyPhotoLink: link, editedAt: Date(), editedBy: "family:fixture")]
        }
    }
}
#endif

struct CatCareListEntrySheet: View {
    /// Asks the list to confirm deleting the record this sheet was showing.
    static let deleteRequested = Notification.Name("catCare.listEntry.deleteRequested")

    let editor: CatCareListEditor
    let catID: UUID?
    /// 11/21: nil once saved; else one line, and the sheet stays open with
    /// what was typed (a failed save closed it and lost the words).
    let saving: (CatCareListEditor.Result) -> String?
    @Environment(\.dismiss) private var dismiss

    init(editor: CatCareListEditor, catID: UUID?, saving: @escaping (CatCareListEditor.Result) -> String?) {
        self.editor = editor
        self.catID = catID
        self.saving = saving
    }

    /// A caller that reports its own outcome (the vet memo's weight).
    init(editor: CatCareListEditor, catID: UUID?, onSave: @escaping (CatCareListEditor.Result) -> Void) {
        self.init(editor: editor, catID: catID, saving: { result in onSave(result); return nil })
    }
    @ObservedObject private var store = CatCareStore.shared

    @State private var date = Date()
    @State private var gramsText = ""
    @State private var name = ""
    @State private var dose = ""
    @State private var schedule = ""
    @State private var food = ""
    @State private var amount = ""
    @State private var proofItem: PhotosPickerItem?
    @State private var showsCamera = false
    /// 11/20: the camera is off for this app: the vet memo's sentence and 「設定を開く」.
    @State private var cameraBlocked: String?
    @Environment(\.openURL) private var openURL
    @State private var proof: CatCarePhotoRef?
    @State private var opensProof = false
    @State private var removesProof = false
    @State private var message: String?
    /// 11/21: one tap saves once (a second tap made a second entry).
    @State private var saved = false
    /// 11/21: what the sheet opened with, so closing with changes asks first.
    @State private var opened: [String]?
    @State private var confirmsDiscard = false
    /// 11/21: photos picked on this sheet; any not kept leave with it.
    @State private var pickedHere: [CatCarePhotoRef] = []
    /// 11/21: a picked photo still being read; 追加 waits for it.
    @State private var loadingProof = false

    var body: some View {
        NavigationStack {
            Form {
                switch editor.kind {
                case .weight:
                    DatePicker("測った日", selection: $date, in: ...Date(), displayedComponents: .date)
                    TextField("体重（kg）例：4.2", text: $gramsText).keyboardType(.decimalPad)
                        .accessibilityIdentifier("cat-care-weight-kg")
                case .medication:
                    TextField("薬の名前", text: $name)
                    TextField("量（例：1/2錠）", text: $dose)
                    TextField("時間（例：朝・夜）", text: $schedule)
                    // 11/8: moved here from 「預けるとき」, beside where the medicine is written.
                    Text("薬は、獣医師に言われたとおりに書いてください。")
                        .font(.footnote).foregroundStyle(.secondary)
                case .vaccination:
                    TextField("種類（例：3種混合）", text: $name)
                    DatePicker("接種した日", selection: $date, in: ...Date(), displayedComponents: .date)
                    PhotosPicker(selection: $proofItem, matching: .images) {
                        Label(proof == nil ? "証明の写真を選ぶ" : "証明の写真を選び直す", systemImage: "photo")
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            // 11/20: asked first, as 「病院で見せる」's 「撮る」 does.
                            Task {
                                cameraBlocked = await VeterinaryCapture.cameraBlockedReason()
                                if cameraBlocked == nil { showsCamera = true }
                            }
                        } label: {
                            Label(proof == nil ? "証明をカメラで撮る" : "カメラで撮り直す", systemImage: "camera")
                        }
                        .accessibilityIdentifier("cat-care-proof-camera")
                        if let cameraBlocked {
                            Text(cameraBlocked).font(.footnote).foregroundStyle(.secondary)
                            Button("設定を開く") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                            .accessibilityIdentifier("cat-care-proof-camera-settings")
                        }
                    }
                    if let current = proof {
                        Button { opensProof = true } label: {
                            Label("証明の写真を付けました", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        .contextMenu { Button("写真を外す", role: .destructive) { removesProof = true } }
                        .confirmationDialog("写真を外しますか？", isPresented: $removesProof) {
                            Button("写真を外す", role: .destructive) { replaceProof(nil) }
                            Button("キャンセル", role: .cancel) { }
                        }
                        .fullScreenCover(isPresented: $opensProof) {
                            ToolRecordFullPhoto {
                                guard let url = store.photoURL(current) else { return nil }
                                return try Data(contentsOf: url)
                            }
                        }
                    }
                case .meal:
                    TextField("時間（例：朝7時）", text: $name)
                    TextField("フード", text: $food)
                    TextField("量（例：20g）", text: $amount)
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle(CatCareFormat.title(editor.kind) + (editor.entryID == nil ? "を追加" : "を直す"))
            .appRecordEditing(retainWhileHidden: true)
            .announcesWhenShown(message)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { if hasChanges { confirmsDiscard = true } else { close() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editor.entryID == nil ? "追加" : "保存") { save() }.disabled(saved || loadingProof)
                }
                if let entryID = editor.entryID {
                    ToolbarItem(placement: .bottomBar) {
                        Button("この記録を削除", role: .destructive) {
                            close()
                            NotificationCenter.default.post(name: Self.deleteRequested, object: entryID)
                        }
                        .accessibilityIdentifier("cat-care-delete-entry")
                    }
                }
            }
            .onAppear {
                guard opened == nil else { return }
                fillFromRecord()
                opened = snapshot
            }
            // 11/21: typed words are not lost to a swipe; キャンセル asks.
            .interactiveDismissDisabled(hasChanges)
            .confirmationDialog("入力した内容を破棄しますか？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("破棄する", role: .destructive) { close() }
                Button("入力を続ける", role: .cancel) {}
            }
            .fullScreenCover(isPresented: $showsCamera) {
                CatCareCameraView { image in
                    showsCamera = false
                    guard let image else { return }
                    // Re-encoding drops metadata. The shot stays in this app, not in Photos.
                    if let data = image.jpegData(compressionQuality: 0.95), let jpeg = CatCareFormat.cleanJPEG(data) {
                        if let made = store.savePhoto(jpeg, sourceAssetID: nil, origin: .camera) {
                            pickedHere.append(made); replaceProof(made)
                        } else { message = "写真を保存できませんでした。空き容量を確かめて、もう一度お試しください。" }
                    } else {
                        message = "写真を保存できませんでした。空き容量を確かめて、もう一度お試しください。"
                    }
                }
                .ignoresSafeArea()
            }
            .onChange(of: proofItem) { _, item in
                guard let item else { return }
                loadingProof = true
                Task {
                    defer { loadingProof = false }
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let jpeg = CatCareFormat.cleanJPEG(data) {
                        if let made = store.savePhoto(jpeg, sourceAssetID: item.itemIdentifier, origin: .photos) {
                            pickedHere.append(made); replaceProof(made)
                        } else { message = "写真を保存できませんでした。空き容量を確かめて、もう一度お試しください。" }
                    } else {
                        message = "写真を読み込めませんでした。別の写真を選んでください。"
                    }
                }
            }
        }
    }

    /// When changing a record, start from what is stored.
    private func fillFromRecord() {
        guard let entryID = editor.entryID, let catID,
              let record = store.state?.record(catID: catID) else { return }
        func dateOf(_ day: CatCareDay) -> Date {
            day.date() ?? Date()
        }
        switch editor.kind {
        case .weight:
            guard let entry = record.weights.first(where: { $0.id == entryID }) else { return }
            date = dateOf(entry.measuredOn)
            // 11/21: three places when the grams need them (4.235 kg was
            // shown as 4.24 and saved back as 4,240 g).
            gramsText = String(format: entry.grams % 10 == 0 ? "%.2f" : "%.3f", Double(entry.grams) / 1000)
        case .medication:
            guard let entry = record.medications.first(where: { $0.id == entryID }) else { return }
            name = entry.name; dose = entry.dose; schedule = entry.schedule
        case .vaccination:
            guard let entry = record.vaccinations.first(where: { $0.id == entryID }) else { return }
            name = entry.kind; date = dateOf(entry.givenOn); proof = record.vaccinationProof(entry.id)
        case .meal:
            guard let entry = record.meals.first(where: { $0.id == entryID }) else { return }
            name = entry.time; food = entry.food; amount = entry.amount
        }
    }

    /// What can be typed or picked here, to tell a change from the opened sheet.
    private var snapshot: [String] {
        [gramsText, name, dose, schedule, food, amount, proof?.fileName ?? "",
         CatCareDay(date: date).map { "\($0.year)-\($0.month)-\($0.day)" } ?? ""]
    }

    private var hasChanges: Bool { !saved && opened != nil && snapshot != opened }

    /// A photo picked here and then replaced or removed leaves at once.
    private func replaceProof(_ next: CatCarePhotoRef?) {
        if let old = proof, old != next, pickedHere.contains(old) {
            store.discardPhoto(old)
            pickedHere.removeAll { $0 == old }
        }
        proof = next
    }

    /// Closing without saving: photos picked here are not kept.
    private func close() {
        pickedHere.forEach { store.discardPhoto($0) }
        pickedHere = []
        dismiss()
    }

    private func save() {
        guard !saved else { return }
        guard let day = CatCareDay(date: date) else { message = "日付を確かめてください。"; return }
        let replacing = editor.entryID
        let result: CatCareListEditor.Result
        switch editor.kind {
        case .weight:
            // kg, as in the photo memo. Full-width digits and a comma also work.
            let half = gramsText.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? gramsText
            // 11/21: 「-4」 is not 4 kg.
            guard !half.contains("-") else { message = "体重はkgの数字で入れてください（例：4.2）。"; return }
            let number = half.replacingOccurrences(of: ",", with: ".").filter { $0.isASCII && ($0.isNumber || $0 == ".") }
            guard let kilograms = Double(number), kilograms > 0,
                  let today = CatCareDay(date: Date()),
                  case let grams = Int((kilograms * 1000).rounded()),
                  CatCareLimits.isValidWeight(grams: grams, on: day, today: today)
            else { message = "体重はkgの数字で入れてください（例：4.2）。"; return }
            result = .weight(grams: grams, day: day, replacing: replacing)
        case .medication:
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { message = "薬の名前を入れてください。"; return }
            result = .medication(name: name, dose: dose, schedule: schedule, replacing: replacing)
        case .vaccination:
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { message = "種類を入れてください。"; return }
            result = .vaccination(kind: name, day: day, proof: proof, replacing: replacing)
        case .meal:
            guard ![name, food, amount].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                message = "時間・フード・量のどれかを入れてください。"; return
            }
            result = .meal(time: name, food: food, amount: amount, replacing: replacing)
        }
        // 11/21: not saved: the sheet stays open with what was typed.
        if let failure = saving(result) { message = failure; return }
        saved = true
        // Photos picked here and not kept (picked again before saving) leave.
        pickedHere.filter { $0 != proof }.forEach { store.discardPhoto($0) }
        pickedHere = []
        dismiss()
    }
}

extension CatCarePhotoRole: Identifiable {
    var id: String { rawValue }
}

struct CatCarePhotoCropRequest: Identifiable {
    let id = UUID()
    let role: CatCarePhotoRole
    let image: UIImage
    let origin: CatCarePhotoRef.Origin
}

extension CatCareStore {
    /// The record 「この子のこと」 shows for this cat, made when there is none yet.
    func ensureRecord(for subject: CatCareSubject) -> CatCareRecord? {
        switch subject {
        case let .profile(profile):
            return UUID(uuidString: profile.identifier).flatMap { ensureRecord(profileID: $0, name: profile.name) }
        case let .toolCat(id, name):
            return ensureRecord(toolCatID: id, profileIdentifier: nil, name: name)
        }
    }

    /// 11/21: one entry of a list added, changed or deleted, the same way from
    /// every page. Nil when it was saved; else the one line its sheet shows,
    /// and the sheet stays open with what was typed.
    func applyEntry(_ result: CatCareListEditor.Result, catID: UUID) -> String? {
        var applied: Bool?
        var deletedMeanwhile = false
        let saved = update { state in
            guard let index = state.liveIndex(catID: catID) else { return }
            if result.editsDeletedEntry(in: state.cats[index]) { deletedMeanwhile = true; return }
            applied = result.apply(to: &state.cats[index], by: state.deviceID, now: Date())
        }
        if deletedMeanwhile { return CatCareListEditor.deletedMeanwhileSentence }
        guard saved, let applied else { return CatCareListEditor.saveFailedSentence }
        return applied ? nil : result.kind.limitSentence
    }

    /// One 見分ける写真 set or taken off, saved at once (not with the typed draft).
    func setIdentifyingPhoto(_ ref: CatCarePhotoRef?, _ role: CatCarePhotoRole, catID: UUID) -> Bool {
        update { state in
            guard let index = state.liveIndex(catID: catID) else { return }
            state.cats[index].setIdentifyingPhoto(role, ref, editedAt: Date(), editedBy: state.deviceID)
        }
    }
}

/// Choosing one 見分ける写真, the same sheet from 「この子のこと」 and from a
/// tool's photo (11/11). Either way it is kept in 「この子のこと」 only.
struct CatCareIdentifyingPhotoSheet: View {
    let subject: CatCareSubject
    let role: CatCarePhotoRole
    /// Whether the chosen photo was kept, once it has been written.
    var onSaved: (Bool) -> Void = { _ in }
    @ObservedObject private var store = CatCareStore.shared

    var body: some View {
        NavigationStack {
            CatCareIdentifyingPhotoPicker(title: CatCareDetailView.photoTitle(role), photos: Self.photos(subject)) { jpeg, assetID in
                save(jpeg, assetID: assetID)
            }
        }
    }

    /// This cat's photos first in the picker; any photo is in 写真アプリ.
    static func photos(_ subject: CatCareSubject) -> [CatProfilePhotoPresentation] {
        guard case let .profile(profile) = subject else { return [] }
        return profile.confirmedPhotos + profile.manualCandidatePhotos
    }

    private func save(_ jpeg: Data, assetID: String?) -> Bool {
        guard let ref = store.savePhoto(jpeg, sourceAssetID: assetID, origin: .photos) else { return false }
        guard let catID = store.ensureRecord(for: subject)?.catID else {
            store.discardPhoto(ref); onSaved(false); return false
        }
        let saved = store.setIdentifyingPhoto(ref, role, catID: catID)
        // 11/21: a copy not kept does not stay behind.
        if !saved { store.discardPhoto(ref) }
        onSaved(saved)
        return saved
    }
}

/// Choosing a 見分ける写真 in 「この子のこと」: this cat's photos, newest first,
/// or any photo from 写真アプリ.
private struct CatCareIdentifyingPhotoPicker: View {
    let title: String
    let photos: [CatProfilePhotoPresentation]
    /// A clean JPEG and the Photos asset it came from; true once it is saved.
    let save: (Data, String?) -> Bool
    @State private var item: PhotosPickerItem?
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                PhotosPicker(selection: $item, matching: .images) {
                    Label("写真アプリから選ぶ", systemImage: "photo.on.rectangle")
                }
                .disabled(busy)
                .accessibilityIdentifier("cat-care-photo-system")
            }
            ToolRecentPhotoSection(photos: photos, own: Set(photos.map(\.localIdentifier)), disabled: busy,
                                   identifierPrefix: "cat-care-photo-candidate-") { use($0) }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() }.disabled(busy) }
        }
        .interactiveDismissDisabled(busy)
        .overlay {
            if busy {
                ProgressView("写真を保存中…").padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .announcesWhenShown(error)
        .onChange(of: item) { _, value in
            guard let value, !busy else { return }
            busy = true; error = nil
            Task {
                let data = try? await value.loadTransferable(type: Data.self)
                finish(data.flatMap { CatCareFormat.cleanJPEG($0) }, assetID: value.itemIdentifier)
                item = nil
            }
        }
    }

    private func use(_ photo: CatProfilePhotoPresentation) {
        busy = true; error = nil
        Task {
            let result = try? await PhotoLibraryJPEGExporter().export(localIdentifier: photo.localIdentifier)
            finish(result.flatMap { CatCareFormat.cleanJPEG($0.jpeg) }, assetID: photo.localIdentifier)
        }
    }

    private func finish(_ jpeg: Data?, assetID: String?) {
        busy = false
        if let jpeg, save(jpeg, assetID) { dismiss() }
        else { error = "この写真は使えませんでした。別の写真を選んでください。" }
    }
}

/// ② of every tool: what 「この子のこと」 fills in, read only, and one way to
/// change it there. Tools never write these values themselves.
struct ToolCatCareSection<Extra: View>: View {
    let title: String
    let lines: [(String, String)]
    let subject: CatCareSubject?
    let footer: String?
    let identifier: String
    let editIdentifier: String
    /// Every cat, passed on to the cat's page.
    let profiles: [CatProfilePresentation]
    /// The cat's birthday and adoption day; off for a box of contacts (347).
    let showsLifeDates: Bool
    /// Folded to one row on a tool's input page: what is read from 「この子のこと」
    /// is not something to do there (11/8: a long read-only box sat among
    /// the steps and looked like more to write).
    let folded: Bool
    /// A heading over the folded row and its extra rows (11/12: 病院で見せる's
    /// 「この子の記録」); none when not given.
    let foldedHeader: String?
    let extra: () -> Extra

    init(title: String, lines: [(String, String)], subject: CatCareSubject?, footer: String? = nil,
         identifier: String, editIdentifier: String, profiles: [CatProfilePresentation] = [],
         showsLifeDates: Bool = true, folded: Bool = false, foldedHeader: String? = nil,
         @ViewBuilder extra: @escaping () -> Extra) {
        self.title = title; self.lines = lines; self.subject = subject; self.footer = footer
        self.identifier = identifier; self.editIdentifier = editIdentifier; self.profiles = profiles
        self.showsLifeDates = showsLifeDates; self.folded = folded; self.foldedHeader = foldedHeader
        self.extra = extra
    }

    private var profile: CatProfilePresentation? {
        if case let .profile(profile)? = subject { return profile }
        return nil
    }

    /// A line whose value only says it is not written yet.
    private static func isEmptyLine(_ line: (String, String)) -> Bool {
        line.1.hasPrefix("未記入") || line.1.hasPrefix("未確認")
    }

    var body: some View {
        let filled = lines.filter { !Self.isEmptyLine($0) }
        let missing = lines.filter(Self.isEmptyLine).map(\.0)
        let birthday = showsLifeDates ? profile?.lifeDates.birthday : nil
        let adoption = showsLifeDates ? profile?.lifeDates.adoptionDay : nil
        Section {
            if folded {
                // One row (349): its name, what the tool uses, what is not
                // written yet; a tap opens the cat's 「この子のこと」.
                if let subject {
                    NavigationLink { CatCareSubjectView(subject: subject, profiles: profiles) } label: {
                        foldedLabel(filled: filled, missing: missing, dated: birthday != nil || adoption != nil)
                    }
                    .accessibilityIdentifier(identifier + "-folded")
                } else {
                    foldedLabel(filled: filled, missing: missing, dated: birthday != nil || adoption != nil)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(identifier + "-folded")
                }
                extra()
            } else {
                readRows(filled: filled, birthday: birthday, adoption: adoption)
                if filled.isEmpty && birthday == nil && adoption == nil && missing.isEmpty {
                    Text("まだ何も書いていません。")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(identifier + "-empty")
                }
                if !missing.isEmpty {
                    // 「、」 between items: some names already contain 「・」.
                    Text("まだ書いていないこと：" + missing.joined(separator: "、"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                extra()
                if let subject {
                    NavigationLink("「この子のこと」を開く") { CatCareSubjectView(subject: subject, profiles: profiles) }
                        .accessibilityIdentifier(editIdentifier)
                }
            }
        } header: { if !folded { Text(title) } else if let foldedHeader { Text(foldedHeader) } }
          footer: { if let footer { Text(footer) } }
    }

    /// The folded row (11/12, round 2): the same row as every other row of
    /// the tool, an icon, 「この子のこと」 and, at the side, how many of the
    /// things this tool reads are not written yet, or 「そろっています」.
    /// VoiceOver also hears which ones.
    private func foldedLabel(filled: [(String, String)], missing: [String], dated: Bool) -> some View {
        ToolValueRow(title: title, systemImage: "pawprint",
                     value: missing.isEmpty ? "そろっています" : "あと\(missing.count)つ",
                     filled: missing.isEmpty)
            .accessibilityElement(children: .combine)
            .accessibilityHint(missing.isEmpty ? "" : "まだ：" + missing.joined(separator: "・"))
    }

    @ViewBuilder
    private func readRows(filled: [(String, String)], birthday: CatProfileLifeReferencePresentation?,
                          adoption: CatProfileLifeReferencePresentation?) -> some View {
        // The dates were a second 「猫のプロフィール」 box above; they are
        // facts of この子のこと, so they sit here, in the one box (11/7).
        if let birthday {
            LabeledContent("誕生日", value: birthday.date.formatted(date: .abbreviated, time: .omitted))
        }
        if let adoption {
            LabeledContent("迎えた日", value: adoption.date.formatted(date: .abbreviated, time: .omitted))
        }
        ForEach(Array(filled.enumerated()), id: \.offset) { _, line in
            VStack(alignment: .leading, spacing: 4) {
                Text(line.0).font(.subheadline).foregroundStyle(.secondary)
                Text(line.1).font(.body).textSelection(.enabled)
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

extension ToolCatCareSection where Extra == EmptyView {
    init(title: String, lines: [(String, String)], subject: CatCareSubject?, footer: String? = nil,
         identifier: String, editIdentifier: String, profiles: [CatProfilePresentation] = [],
         showsLifeDates: Bool = true, folded: Bool = false, foldedHeader: String? = nil) {
        self.init(title: title, lines: lines, subject: subject, footer: footer,
                  identifier: identifier, editIdentifier: editIdentifier, profiles: profiles,
                  showsLifeDates: showsLifeDates, folded: folded, foldedHeader: foldedHeader) { EmptyView() }
    }
}

// MARK: - One shape for every tool's input page (11/8)
//
// The four tools (病院・迷子・預ける・避難) each had their own layout: it was
// unclear what to do first or where to look. Every input page reads the same
// way, top to bottom (ねこのまど_ツール入力ページの型_1108):
//   1. the cat row (11/22: only with two or more cats and no cat menu in the
//      bar, ToolCatNameHeader; the gray sentence of what the page makes is
//      gone, the title says it)
//   2. numbered steps, each a Section with a ToolStepHeader; done shows a check
//   3. 「この子のこと」 folded to one row (ToolCatCareSection(folded: true))
//   4. notes, 「診察済み」-style marks and delete, last and small
//   5. at the bottom, ToolMakeBar: 「あと：…」 and the one button
// One page with marked steps, not a wizard: 病院 and 預ける are repeated
// tasks, and steps can be filled in any order.
//
// 11/12: 病院で見せる is the trial of another shape, a list of rows as in 設定
// (a section heading, then rows with an icon, the name, what is written and a
// chevron; each row opens its own page), with the cat chosen from a menu in
// the bar instead of the row of faces (ToolRowParts.swift). 預けるとき and
// 迷子のとき were then made the same way; 避難に備える keeps the shape above.
// 11/12 (round 2): 避難に備える's main page has the same rows too; its cat's
// page (11/22: 「この子のこと」, was 猫の情報) keeps the row of faces and the
// numbered parts.

/// Where a step stands: the first one not done is the one to do now.
enum ToolStepState: Equatable {
    case todo, current, done

    static func states(_ done: [Bool]) -> [ToolStepState] {
        let current = done.firstIndex(of: false)
        return done.indices.map { done[$0] ? .done : ($0 == current ? .current : .todo) }
    }
}

/// A step's heading: its number, or a check once done.
struct ToolStepHeader: View {
    let number: Int
    let title: String
    var state: ToolStepState = .todo

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                switch state {
                case .done:
                    Circle().fill(Color.green.opacity(0.2))
                    Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(Color.green)
                case .current:
                    Circle().fill(Color.accentColor)
                    Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(Color.white)
                case .todo:
                    Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                    Text("\(number)").font(.caption.weight(.semibold)).foregroundStyle(Color.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(state == .todo ? Color.secondary : Color.primary)
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number)、\(title)" + (state == .done ? "、済み" : ""))
    }
}

/// The one way forward, in the same place on every tool page: what is still
/// missing, then the button (a Button or a NavigationLink; styled here).
/// 11/11: the bar is the page's own colour (`ground`: a list page's grouped
/// colour unless told otherwise), with the rows fading out just above it, as
/// on the Plus screen; and the button is the app's one primary button.
struct ToolMakeBar<Top: View, Action: View>: View {
    let missing: [String]
    let ground: Color
    let top: Top
    let action: Action

    init(missing: [String] = [], ground: Color = NekoPalette.groupedGround,
         @ViewBuilder top: () -> Top, @ViewBuilder action: () -> Action) {
        self.missing = missing; self.ground = ground; self.top = top(); self.action = action()
    }

    var body: some View {
        VStack(spacing: 6) {
            top
            if !missing.isEmpty {
                Text("あと：" + missing.joined(separator: "・"))
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("tool-make-missing")
            }
            action
                .nekoPrimaryButton()
                // A thin edge, seen only through a gray button that cannot be
                // pressed yet (dark mode: it nearly disappeared into the
                // page); a filled button covers it.
                .background(RoundedRectangle(cornerRadius: NekoRadius.button)
                    .strokeBorder(Color(.separator), lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ToolChrome.sideMargin)
        .padding(.vertical, 10)
        .background(ground)
        .overlay(alignment: .top) {
            LinearGradient(colors: [ground.opacity(0), ground], startPoint: .top, endPoint: .bottom)
                .frame(height: ToolChrome.fade)
                .offset(y: -ToolChrome.fade)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The frame around every tool page (11/11).
enum ToolChrome {
    /// How far the rows fade out above ToolMakeBar.
    static let fade: CGFloat = 28
    /// The side margin of a list's cards, so the bottom button is exactly as
    /// wide as the cards above it (11/12, round 2: it stood out by a few
    /// points on the larger iPhones): 20 points from 390 points wide, 16 below.
    @MainActor static var sideMargin: CGFloat { UIScreen.main.bounds.width >= 390 ? 20 : 16 }
}

extension View {
    /// 11/11: inside a tool the app's tab bar is hidden, so the tool's bar sits
    /// at the very bottom instead of on top of the tab bar. Set on every page a
    /// tool pushes and on 「この子のこと」: a pushed page without it brings the
    /// tab bar back. Popping back to the ツール list shows the tab bar again.
    /// 11/12 (round 2): the one place for the top bar too. Rows scrolled under
    /// the title used to show through it, blurred (iOS 26); the bar now has
    /// the page's own colour under it, so rows end cleanly at its edge.
    func toolChrome(ground: Color = NekoPalette.groupedGround) -> some View {
        toolbar(.hidden, for: .tabBar)
            .modifier(ToolChromeTopBar(ground: ground))
    }

    /// Room under the last row for the fade above ToolMakeBar, so the last row
    /// can be scrolled fully clear of it.
    func toolBarFadeRoom() -> some View {
        contentMargins(.bottom, ToolChrome.fade, for: .scrollContent)
    }
}

/// The top bar of every tool page (toolChrome): the page's colour under the
/// title. iOS 26 draws a soft, see-through edge by default; there the bar is
/// filled at all times and the edge is the hard one. Before iOS 26 the colour
/// shows only once the rows scroll under the bar, as the system bar does.
private struct ToolChromeTopBar: ViewModifier {
    let ground: Color

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .toolbarBackground(ground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
                .toolbarBackground(ground, for: .navigationBar)
        }
    }
}

extension View {
    /// The same spacing on every tool page: the purpose line right under the
    /// cat row, the steps close together (349: a tall gap above the purpose).
    func toolPageSpacing() -> some View {
        listSectionSpacing(.compact)
            .contentMargins(.top, 4, for: .scrollContent)
    }
}

/// One photo on a tool page, the same in every tool (349): the photo (tap to
/// choose), its name under it, and 「⋯」 for the rest. Taking a photo off sits
/// in that menu, never as red text on the page.
/// A kept photo is given as `file` and shown from a small copy made off the
/// main thread (`ToolPhotoThumbnail`, 11/8); `image` is for a photo already
/// in memory.
struct ToolPhotoSlot<Actions: View>: View {
    let title: String
    let image: UIImage?
    var file: URL?
    var dimmedTitle = false
    var disabled = false
    /// Shown only (11/9): a tool showing 「この子のこと」's photo. No menu and no
    /// picker; the row around it opens 「この子のこと」.
    var readOnly = false
    /// Tap to choose, no menu (11/11): a tool's 見分ける写真, chosen into
    /// 「この子のこと」; taking off and cropping stay there.
    var chooseOnly = false
    /// A square the photo fills (`filledSquare()`); off: the whole photo, 4:3.
    var fillsSquare = false
    /// 11/20: a low tile (`lowWhileEmpty`), while neither photo is chosen.
    var low = false
    let identifier: String
    let actionsIdentifier: String
    let choose: () -> Void
    let actions: Actions
    @State private var thumbnail: UIImage?

    init(_ title: String, image: UIImage?, file: URL? = nil, dimmedTitle: Bool = false, disabled: Bool = false,
         identifier: String, actionsIdentifier: String, choose: @escaping () -> Void,
         @ViewBuilder actions: () -> Actions) {
        self.title = title; self.image = image; self.file = file
        self.dimmedTitle = dimmedTitle; self.disabled = disabled
        self.identifier = identifier; self.actionsIdentifier = actionsIdentifier
        self.choose = choose; self.actions = actions()
    }

    private var hasPhoto: Bool { image != nil || file != nil }
    private var shown: UIImage? { file == nil ? image : thumbnail }

    /// 11/20: 96pt high while low; otherwise square or 4:3, as before.
    @ViewBuilder private var ground: some View {
        if low {
            Color(.tertiarySystemGroupedBackground).frame(height: 96)
        } else {
            Color(.tertiarySystemGroupedBackground)
                .aspectRatio(fillsSquare ? 1 : 4.0 / 3.0, contentMode: .fit)
        }
    }

    private var tile: some View {
        ground
            .overlay {
                if fillsSquare, let shown { Image(uiImage: shown).resizable().scaledToFill() }
                else if let shown { Image(uiImage: shown).resizable().scaledToFit() }
                else if !hasPhoto {
                    Image(systemName: readOnly ? "photo" : "photo.badge.plus").font(.title2).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // 11/12 (round 2): an empty slot has a dashed edge, so it shows on
            // a card of almost the same gray (dark mode).
            .overlay {
                if !hasPhoto {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 「⋯」 on the photo's top corner, on a round ground, so it is easy to
    /// find and to press (11/12, round 2: three small dots beside the name).
    private var actionsMenu: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.primary)
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(title)の操作")
        .accessibilityIdentifier(actionsIdentifier)
    }

    /// A square the photo fills, cut at the edges (11/12, 「この子のこと」's
    /// 見分ける写真); every other screen keeps the whole photo in a wide tile.
    func filledSquare() -> Self {
        var slot = self
        slot.fillsSquare = true
        return slot
    }

    /// 11/20: 「この子のこと」's two empty slots, low (96pt) instead of square,
    /// so the rows under them show on the first screen. Once either has a
    /// photo, both are squares again (11/12: two equal squares).
    func lowWhileEmpty(_ empty: Bool) -> Self {
        var slot = self
        slot.low = empty
        return slot
    }

    var body: some View {
        VStack(spacing: 4) {
            if readOnly {
                tile
                    .accessibilityElement()
                    .accessibilityLabel(title + (hasPhoto ? "" : "、まだありません"))
                    .accessibilityIdentifier(identifier)
            } else {
                ZStack(alignment: .topTrailing) {
                    Button(action: choose) { tile }
                        .buttonStyle(.plain)
                        .accessibilityLabel(chooseOnly && !hasPhoto ? title + "、まだありません" : title)
                        .accessibilityIdentifier(identifier)
                        .disabled(disabled)
                    if hasPhoto && !chooseOnly {
                        actionsMenu
                    }
                }
            }
            // 11/12 (round 2): the name a size larger (it was hard to read).
            Text(title).font(.footnote)
                .foregroundStyle(dimmedTitle ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task(id: file) { thumbnail = await ToolPhotoThumbnail.load(file) }
    }
}

/// Photo slots side by side, two to a row; one slot keeps the same size.
struct ToolPhotoGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top),
                            GridItem(.flexible(), spacing: 12, alignment: .top)], spacing: 12, content: content)
            .padding(.vertical, 4)
    }
}

extension ToolPhotoSlot where Actions == EmptyView {
    /// A photo from 「この子のこと」, shown in a tool (11/9).
    init(readOnly title: String, file: URL?, identifier: String) {
        self.init(title, image: nil, file: file, identifier: identifier, actionsIdentifier: identifier + "-actions",
                  choose: {}) { EmptyView() }
        readOnly = true
    }

    /// A tool's 見分ける写真 (11/11): tap to choose it into 「この子のこと」.
    init(choosing title: String, file: URL?, disabled: Bool, identifier: String, choose: @escaping () -> Void) {
        self.init(title, image: nil, file: file, disabled: disabled, identifier: identifier,
                  actionsIdentifier: identifier + "-actions", choose: choose) { EmptyView() }
        chooseOnly = true
    }
}

/// 見分ける写真 in a tool: kept in 「この子のこと」 (11/9). Tapping a photo
/// opens the same chooser as there and keeps the choice there (11/11);
/// taking off and cropping stay in 「この子のこと」, one link away.
struct ToolIdentifyingPhotos: View {
    let faceFile: URL?
    let bodyFile: URL?
    let subject: CatCareSubject?
    var profiles: [CatProfilePresentation] = []
    /// 預けるとき prints the face only.
    var showsBody = true
    let identifier: String

    var body: some View {
        if let subject {
            ToolIdentifyingPhotoChoice(faceFile: faceFile, bodyFile: bodyFile, subject: subject, profiles: profiles,
                                       showsBody: showsBody, identifier: identifier)
        } else {
            ToolPhotoGrid {
                // 11/12 (round 2): the photos fill their squares, as in 「この子のこと」.
                ToolPhotoSlot(readOnly: "顔の写真", file: faceFile, identifier: identifier + "-face").filledSquare()
                if showsBody {
                    ToolPhotoSlot(readOnly: "全身の写真", file: bodyFile, identifier: identifier + "-body").filledSquare()
                }
            }
        }
    }
}

/// A cat with 「この子のこと」: each photo opens its chooser, and one quiet
/// link opens 「この子のこと」 for the rest (11/11). Two rows, so the link
/// row never takes over the taps on the photos.
private struct ToolIdentifyingPhotoChoice: View {
    let faceFile: URL?
    let bodyFile: URL?
    let subject: CatCareSubject
    let profiles: [CatProfilePresentation]
    let showsBody: Bool
    let identifier: String
    @ObservedObject private var store = CatCareStore.shared
    @State private var photoRole: CatCarePhotoRole?

    var body: some View {
        photos
        NavigationLink { CatCareSubjectView(subject: subject, profiles: profiles) } label: {
            Text("「この子のこと」を開く").font(.footnote)
        }
        .accessibilityIdentifier(identifier + "-open-cat-care")
    }

    /// A failed save is said in the chooser, which stays open.
    private var photos: some View {
        ToolPhotoGrid {
            slot(.face, file: faceFile, identifier: identifier + "-face")
            if showsBody {
                slot(.body, file: bodyFile, identifier: identifier + "-body")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .sheet(item: $photoRole) { role in
            CatCareIdentifyingPhotoSheet(subject: subject, role: role)
        }
        .appRecordEditing(retainWhileHidden: photoRole != nil)
    }

    private func slot(_ role: CatCarePhotoRole, file: URL?, identifier: String) -> some View {
        ToolPhotoSlot(choosing: CatCareDetailView.photoTitle(role), file: file, disabled: !store.canSave,
                      identifier: identifier, choose: { photoRole = role })
            .filledSquare()
    }
}

extension ToolMakeBar where Top == EmptyView {
    init(missing: [String] = [], ground: Color = NekoPalette.groupedGround, @ViewBuilder action: () -> Action) {
        self.init(missing: missing, ground: ground, top: { EmptyView() }, action: action)
    }
}

extension View {
    /// Reads a new message aloud with VoiceOver, so an error or a "done" is
    /// not only shown in color on the screen.
    func announcesWhenShown(_ message: String?) -> some View {
        onChange(of: message) { _, new in
            guard let new, !new.isEmpty else { return }
            AccessibilityNotification.Announcement(new).post()
        }
    }
}

extension View {
    /// A tool's bottom bar, out of the way while the keyboard is up, so the
    /// field being written stays in view (348: 「先生に見せる」 and the keyboard
    /// left two lines to write in). Swipe down or 「キーボードを閉じる」 to finish.
    func toolBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        modifier(ToolBottomBar(bar: bar()))
    }
}

private struct ToolBottomBar<Bar: View>: ViewModifier {
    let bar: Bar
    @State private var typing = false
    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) { if !typing { bar } }
            .toolBarFadeRoom()
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("キーボードを閉じる") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in typing = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in typing = false }
    }
}

/// A photo beside its text, stacked when the text is very large.
struct ToolAdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var spacing: CGFloat = 14
    @ViewBuilder let content: () -> Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(spacing: spacing))
        layout { content() }
    }
}

enum ToolPhotoLabel {
    /// 「この写真を使う、2026年10月20日」: photos in a grid are told apart by their day.
    static func text(_ action: String, date: Date?) -> String {
        guard let date else { return action }
        return action + "、" + date.formatted(date: .long, time: .omitted)
    }
}

/// The system camera. Nothing is written to the Photos library.
private struct CatCareCameraView: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

// MARK: - Formatting

extension CatCareFormat {
    static func title(_ kind: CatCareListEditor.Kind) -> String {
        switch kind {
        case .weight: "体重"
        case .medication: "飲んでいる薬"
        case .vaccination: "ワクチン"
        case .meal: "ごはん"
        }
    }

    /// Re-encodes to JPEG, which drops location and other metadata.
    static func cleanJPEG(_ data: Data) -> Data? {
        // 11/21: read at most 2048 px straight from the file (a 48 MP photo
        // was decoded whole, about 190 MB), upright, without the photo's
        // place or other details. ImageIO's copy carries no HDR picture.
        VeterinaryCapture.copy(of: data)
    }
}

// What tools show is built in Services/CatCareOutputLines.swift (11/8), so CI
// can check it without the screens. Only the store lookups stay here.
@MainActor
extension CatCareSummary {
    static func record(profileIdentifier: String) -> CatCareRecord? {
        guard let profileID = UUID(uuidString: profileIdentifier) else { return nil }
        return CatCareStore.shared.state?.cats.first { $0.profileID == profileID && $0.deletedAt == nil }
    }

    /// 見分ける写真 as a tool shows and prints it (11/9): 「この子のこと」 once set
    /// there (taken off there stays off), else the tool's own older photo.
    static func identifyingPhotoURL(_ record: CatCareRecord?, _ role: CatCarePhotoRole, legacy: URL?) -> URL? {
        let legacy = legacy.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        switch CatCareIdentifyingPhotos.choice(record?.identifyingPhoto(role), legacy: legacy) {
        case let .catCare(ref):
            // A copy that is not on this iPhone (a restore in progress) falls back.
            if let url = CatCareStore.shared.photoURL(ref), FileManager.default.fileExists(atPath: url.path) { return url }
            return legacy
        case let .legacy(url): return url
        case .missing: return nil
        }
    }

    /// The record for a tool's cat: the shared tool ID first, then the profile.
    static func record(toolCatID: UUID, profileIdentifier: String?) -> CatCareRecord? {
        let cats = CatCareStore.shared.state?.cats.filter { $0.deletedAt == nil } ?? []
        if let match = cats.first(where: { $0.catID == toolCatID }) { return match }
        return profileIdentifier.flatMap { record(profileIdentifier: $0) }
    }

}

// MARK: - The family's representative photo (11/17)

/// What the screens need from the family's representative photo. Behind it
/// is the real service (FamilyNotebookServiceFactory) only while it is on,
/// or, in review captures, a synthetic relay; otherwise there is none and
/// the screens show nothing of it.
@MainActor
protocol FamilyRepresentativePhotoBackend: AnyObject {
    var myPersonID: String? { get }
    /// 11/19: this iPhone can write the photo now (the family's keys are read).
    var canWrite: Bool { get }
    func displayName(of personID: String) -> String?
    /// Who delivered the cat's photo, from this iPhone's copy (no network).
    func author(of cat: UUID) -> String?
    /// The photo the cat's reference in this iPhone's copy points to (no
    /// network); nil: none, cleared or unreadable.
    func referencedAsset(of cat: UUID) -> UUID?
    func load(_ cats: [UUID]) async throws -> [UUID: FamilyNotebookPhotoLoad]
    func deliver(_ cat: UUID, source: Data) async throws
    /// An encrypted delivery waits to be sent again (it was reserved before it stopped).
    func hasPending(_ cat: UUID) -> Bool
    func retry(_ cat: UUID) async throws
    func clear(_ cat: UUID) async throws
    func report(assetID: UUID, reason: GroupReportReason) async throws -> String
    func hide(_ personID: String) async throws
    func unhide(_ personID: String) async throws
    /// 11/19: what the relay said about the photo (its own gate) in this process.
    var relayAnswer: FamilyPhotoServerState { get }
    /// One question to the relay while its answer is not known.
    func probe() async
}

extension FamilyRepresentativePhotoBackend {
    /// Review captures: a synthetic relay that is always open.
    var relayAnswer: FamilyPhotoServerState { .on }
    func probe() async {}
}

/// The photos a family cat page shows instead of のわ. Shown only: never the
/// photo list, a widget, the archive or the library. A read that fails keeps
/// what is on screen (only an answer of 「none」 brings のわ back).
///
/// 11/19: the photo of each family cat is the key photo the notebook's
/// creator (the payer) chose on their own iPhone, sent by itself
/// (`syncCreatorPhotos`). Nobody delivers, replaces or clears it by hand,
/// and nothing about it shows on the creator's pages.
@MainActor
final class FamilyRepresentativePhotos: ObservableObject {
    static let shared = FamilyRepresentativePhotos()

    struct Shown: Equatable {
        let assetID: UUID
        let authorID: String
        let image: UIImage
        static func == (lhs: Shown, rhs: Shown) -> Bool { lhs.assetID == rhs.assetID && lhs.authorID == rhs.authorID }
    }
    /// By the family cat's ID.
    @Published private(set) var shown: [UUID: Shown] = [:]
    /// Cats whose photo is from someone this person chose not to show.
    @Published private(set) var hiddenAuthors: [UUID: String] = [:]
    @Published private(set) var backend: (any FamilyRepresentativePhotoBackend)?
    /// The photo each cat's page last read, and when.
    private var readAt: [UUID: (asset: UUID, at: Date)] = [:]
    /// The one read under way (11/19: owned here, not by the page that asked).
    private var readTask: Task<Void, Never>?
    /// Calls that came while reading: read once more right after.
    private var queued: (cats: [UUID], force: Bool)?
    /// A page that stays open reads the same photo at most once a minute; a
    /// new photo in the copy is read at once.
    static let automaticGap: TimeInterval = 60

    init() { backend = FamilyNotebookServiceFactory.representativePhotoBackend() }

    /// 11/19: the relay's own gate, as last answered. Closed: nothing of the
    /// photo is shown or asked for again in this process (as before 1.0).
    @Published private(set) var relayAnswer: FamilyPhotoServerState = .unknown

    var isOn: Bool { backend != nil && relayAnswer != .off }
    /// The notebook is read more often for a photo only once the relay said open.
    var readsForPhotos: Bool { isOn && relayAnswer == .on }

    private func noteRelay() {
        guard let answer = backend?.relayAnswer, answer != relayAnswer else { return }
        relayAnswer = answer
    }

#if DEBUG
    /// Review captures only (AppStoreScreenshotFixture.CatHomeStress).
    func installFixture(_ backend: any FamilyRepresentativePhotoBackend) { self.backend = backend; noteRelay() }
#endif

    func name(of personID: String) -> String {
        GroupDisplayName.withSan(backend?.displayName(of: personID) ?? "家族の人")
    }

    func isMine(_ personID: String?) -> Bool {
        guard let personID, let me = backend?.myPersonID else { return false }
        return personID == me
    }

    /// The photos of the cats on screen. Not marked as the person's: the
    /// calls count toward the automatic budget like any page that reads.
    /// A cat with no reference in the copy is still passed on (the answer
    /// 「none」 is made without the network) but uses up no minute.
    ///
    /// 11/19 (TestFlight 392): the read runs in a task of its own, as the
    /// creator's sync does. It used to run in the page's `.task(id:)`, which
    /// SwiftUI cancels when the notebook's copy changes again (one pass
    /// changes it more than once); the cancelled read had already marked the
    /// new photo as read, and the read queued behind it ran in that same
    /// cancelled task, so the photo fetched from the relay was never shown
    /// until the app started again. Now only a photo that reached the screen
    /// counts as read.
    func read(_ cats: [UUID], force: Bool = false) async {
        guard backend != nil, !cats.isEmpty else { return }
        if let running = readTask {
            let waiting = queued?.cats ?? []
            queued = (cats: waiting + cats.filter { !waiting.contains($0) }, force: (queued?.force ?? false) || force)
            await running.value
            return
        }
        let task = Task { @MainActor in await self.readAll(cats, force: force) }
        readTask = task
        await task.value
    }

    private func readAll(_ cats: [UUID], force: Bool) async {
        var next: (cats: [UUID], force: Bool)? = (cats: cats, force: force)
        // Nothing is awaited between taking the queue and clearing the task,
        // so a call that comes as the last read ends is not lost.
        while let call = next, let backend {
            await readOnce(call.cats, force: call.force, backend: backend)
            next = queued; queued = nil
        }
        queued = nil
        readTask = nil
    }

    private func readOnce(_ cats: [UUID], force: Bool, backend: any FamilyRepresentativePhotoBackend) async {
        defer { noteRelay() }
        // 11/19: not known yet whether the relay's photo is open: one question.
        if backend.relayAnswer == .unknown { await backend.probe(); noteRelay() }
        guard backend.relayAnswer != .off else { return }
        let now = Date()
        var due: [UUID] = [], assets: [UUID: UUID] = [:]
        for cat in cats {
            guard let asset = backend.referencedAsset(of: cat) else { due.append(cat); continue }
            if !force, let last = readAt[cat], last.asset == asset,
               now.timeIntervalSince(last.at) < Self.automaticGap { continue }
            assets[cat] = asset
            due.append(cat)
        }
        guard !due.isEmpty, let loaded = try? await backend.load(due) else { return }
        for (cat, load) in loaded {
            apply(load, to: cat)
            if let asset = assets[cat] { readAt[cat] = (asset: asset, at: now) }
        }
    }

    private func apply(_ load: FamilyNotebookPhotoLoad, to cat: UUID) {
        switch load {
        case let .shown(assetID, authorID, jpeg):
            if hiddenAuthors[cat] != nil { hiddenAuthors[cat] = nil }
            guard shown[cat]?.assetID != assetID, let image = UIImage(data: jpeg) else { return }
            shown[cat] = Shown(assetID: assetID, authorID: authorID, image: image)
        case let .hidden(authorID):
            if shown[cat] != nil { shown[cat] = nil }
            if hiddenAuthors[cat] != authorID { hiddenAuthors[cat] = authorID }
        case .none:
            if shown[cat] != nil { shown[cat] = nil }
            if hiddenAuthors[cat] != nil { hiddenAuthors[cat] = nil }
        }
    }

    // MARK: The creator's key photos, by themselves (11/19)

    /// This iPhone's cats and the key photo each was given (nil: none
    /// chosen), as AppRootView last saw them. Nil until it has: nothing is
    /// cleared before the cats are known.
    private var ownKeyPhotos: [UUID: String?]?
    /// 11/19 (TestFlight 391): the one sync under way, owned here. It used to
    /// run inside its caller's task (the notebook's schedule, which is
    /// cancelled when it is planned again or the app leaves the front), so a
    /// commit was cut off mid-call and a change asked for meanwhile was
    /// dropped with the cancelled loop until a later pass.
    private var syncTask: Task<Void, Never>?
    private var syncAgain = false
    private var syncBackground: UIBackgroundTaskIdentifier = .invalid
    /// A cat that did not go: its photo (nil: a clear), failures in a row,
    /// and when it is tried again. A new photo starts over.
    private var waits: [UUID: (photo: String?, failures: Int, until: Date)] = [:]
    /// The photo a cat's slot was full for: left until the photo changes.
    private var limitedPhotos: [UUID: String] = [:]
    /// The photo of a delivery reserved and not finished (sent again as it is).
    private var pendingPhotos: [UUID: String] = [:]
    /// Waits after failures in a row; the tries themselves ride the
    /// notebook's one schedule (FamilyNotebookAutoCheck) and coming to the front.
    static let retryBackoff: [TimeInterval] = [60, 5 * 60, 15 * 60, 60 * 60]
    private static let sentKeyPrefix = "familyNotebook.creatorPhotos.v1."

    /// AppRootView: the cats or their key photos changed, the notebook or its
    /// links changed, or the app came to the front.
    func ownKeyPhotosChanged(_ value: [UUID: String?]) async {
        ownKeyPhotos = value
        await syncCreatorPhotos()
    }

    /// Only the creator's iPhone writes. For each family cat linked to a cat
    /// of this iPhone: its key photo when that is not the one this iPhone
    /// last sent, a clear when it has none, nothing when unchanged. The
    /// check is this iPhone's own (the copy and what it sent), no network.
    ///
    /// The work runs in a task of its own (not its caller's: a screen or the
    /// schedule going away does not cut a send off) and, while it runs, in
    /// the time iOS gives an app that leaves the front. A call while it runs
    /// is checked right after it, and waits for that.
    func syncCreatorPhotos() async {
        // Not the creator's iPhone (most passes): nothing starts.
        guard let backend, backend.canWrite, ownKeyPhotos != nil,
              FamilyNotebookSharing.shared.state.membership?.role == .payer else { return }
        if let running = syncTask {
            syncAgain = true
            await running.value
            return
        }
        // Automatic, as before (within this iPhone's call budget).
        let task = Task { @MainActor in
            // A call that came as one pass ended is not lost: nothing is
            // awaited between this check and clearing the task.
            repeat {
                await SharingPersonAction.automatic { await self.runSync() }
                self.noteRelay()
            } while syncAgain && !Task.isCancelled
            syncTask = nil
            endSyncBackground()
        }
        syncTask = task
        beginSyncBackground()
        await task.value
    }

    private func beginSyncBackground() {
        guard syncBackground == .invalid else { return }
        // UIKit calls the expiration on the main thread.
        syncBackground = UIApplication.shared.beginBackgroundTask(withName: "Send family key photo") { [weak self] in
            MainActor.assumeIsolated {
                self?.syncTask?.cancel()
                self?.endSyncBackground()
            }
        }
    }

    private func endSyncBackground() {
        guard syncBackground != .invalid else { return }
        UIApplication.shared.endBackgroundTask(syncBackground)
        syncBackground = .invalid
    }

    private func runSync() async {
        repeat {
            syncAgain = false
            guard let backend, backend.canWrite, let keyPhotos = ownKeyPhotos else { return }
            let notebook = FamilyNotebookPrototype.shared
            guard notebook.isReal, notebook.hasFamily, FamilyNotebookSharing.shared.state.membership?.role == .payer,
                  let family = notebook.snapshot?.familyID else { return }
            var sent = Self.sentPhotos(family), seen = Self.seenPhotos(family)
            let before = sent, seenBefore = seen
            for (profile, photo) in keyPhotos.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                guard !Task.isCancelled else { break }
                guard let cat = notebook.linkedFamilyCat(profile: profile.uuidString) else { continue }
                await syncOne(cat, photo: photo, sent: &sent, seen: &seen, backend: backend)
            }
            if sent != before { Self.saveSent(sent, family) }
            if seen != seenBefore { Self.saveSeen(seen, family) }
        } while syncAgain && !Task.isCancelled
    }

    private func syncOne(_ cat: UUID, photo: String?, sent: inout [String: String], seen: inout [String: String],
                         backend: any FamilyRepresentativePhotoBackend) async {
        let key = cat.uuidString.lowercased()
        let referenced = backend.referencedAsset(of: cat) != nil
        // 11/19 (the creator with two iPhones): the family's photo by this
        // person that this iPhone never sent came from the person's other
        // iPhone. This iPhone's choice as first seen then is only noted (""
        // for none); it replaces the photo only once that choice changes.
        // A new iPhone never overwrites the photo on its first pass.
        if sent[key] == nil {
            if let first = seen[key] {
                if first == (photo ?? "") { return }
            } else if referenced, isMine(backend.author(of: cat)) {
                seen[key] = photo ?? ""
                return
            }
        }
        if let photo {
            if referenced, isMine(backend.author(of: cat)), sent[key] == photo { return }
            if limitedPhotos[cat] == photo || waiting(cat, photo: photo) { return }
            do {
                try await deliver(cat, photo: photo, backend: backend)
                sent[key] = photo; seen[key] = nil
                waits[cat] = nil; limitedPhotos[cat] = nil; pendingPhotos[cat] = nil
            } catch FamilyNotebookPhotoFailure.limited {
                // Full: dropped without a word until the photo changes.
                limitedPhotos[cat] = photo; waits[cat] = nil
            } catch where Task.isCancelled {
                // iOS ended the time it gave: not a failure (no wait); the
                // kept delivery goes on the next pass.
            } catch { failed(cat, photo: photo) }
        } else {
            // 11/19 (機種変更): only a slot this iPhone itself filled is cleared.
            // A new iPhone of the same person (the same author) has no record and
            // leaves the family's photo. Presence only: a changed PhotoKit ID of
            // the photo it sent is not a clear. 11/20: a choice noted when first
            // seen (after 機種変更, or the app deleted, which wipes `sent`) that
            // had a photo and now has none is the person's own change: cleared.
            guard sent[key] != nil || seen[key] != nil else { return }
            guard referenced || backend.author(of: cat) != nil else { sent[key] = nil; seen[key] = nil; return }
            if waiting(cat, photo: nil) { return }
            do {
                try await backend.clear(cat)
                sent[key] = nil; seen[key] = nil
                waits[cat] = nil; limitedPhotos[cat] = nil; pendingPhotos[cat] = nil
            } catch where Task.isCancelled {
            } catch { failed(cat, photo: nil) }
        }
    }

    /// The same encrypted delivery when one of this photo waits; else from the photo.
    private func deliver(_ cat: UUID, photo: String, backend: any FamilyRepresentativePhotoBackend) async throws {
        if pendingPhotos[cat] == photo, backend.hasPending(cat) {
            do { try await backend.retry(cat); return }
            catch FamilyNotebookPhotoFailure.limited { throw FamilyNotebookPhotoFailure.limited }
            catch { if backend.hasPending(cat) { throw error } }
        }
        guard let data = await Self.keyPhotoJPEG(photo) else {
            FamilyPhotoDeliveryDiagnostics.note(.init(stage: .sourceMissing))
            throw FamilyNotebookPhotoFailure.failed
        }
        FamilyPhotoDeliveryDiagnostics.note(.init(stage: .sourceLoaded))
        pendingPhotos[cat] = photo
        try await backend.deliver(cat, source: data)
    }

    private func waiting(_ cat: UUID, photo: String?) -> Bool {
        guard let wait = waits[cat], wait.photo == photo else { return false }
        return wait.until > Date()
    }

    private func failed(_ cat: UUID, photo: String?) {
        let failures = waits[cat].flatMap { $0.photo == photo ? $0.failures : nil } ?? 0
        let gap = Self.retryBackoff[min(failures, Self.retryBackoff.count - 1)]
        waits[cat] = (photo: photo, failures: failures + 1, until: Date().addingTimeInterval(gap))
    }

    /// What this iPhone last sent for each cat of the family (its PhotoKit
    /// ID), written only after a send or a clear went through.
    private static func sentPhotos(_ family: UUID) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: sentKeyPrefix + family.uuidString.lowercased()) as? [String: String] ?? [:]
    }

    private static func saveSent(_ sent: [String: String], _ family: UUID) {
        UserDefaults.standard.set(sent, forKey: sentKeyPrefix + family.uuidString.lowercased())
    }

    /// This iPhone's choice for a cat when it first saw the family's photo
    /// sent by the person's other iPhone ("" for none); dropped once this
    /// iPhone sends its own.
    private static let seenKeyPrefix = "familyNotebook.creatorPhotos.seen.v1."
    private static func seenPhotos(_ family: UUID) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: seenKeyPrefix + family.uuidString.lowercased()) as? [String: String] ?? [:]
    }

    private static func saveSeen(_ seen: [String: String], _ family: UUID) {
        UserDefaults.standard.set(seen, forKey: seenKeyPrefix + family.uuidString.lowercased())
    }

#if INTERNAL_PRESENTATION
    /// 11/19 (the owner's two-device trial only): the records of a device
    /// that is being forgotten on this iPhone, so the next one starts fresh.
    static func forgetSyncRecords(_ family: UUID) {
        UserDefaults.standard.removeObject(forKey: sentKeyPrefix + family.uuidString.lowercased())
        UserDefaults.standard.removeObject(forKey: seenKeyPrefix + family.uuidString.lowercased())
    }
#endif

    /// The photo shown when 「この写真を通報」 was chosen; once received it
    /// is not shown on this iPhone again.
    func report(cat: UUID, assetID: UUID, reason: GroupReportReason) async throws -> String {
        guard let backend else { throw FamilyNotebookPhotoFailure.unavailable }
        let number = try await SharingPersonAction.run { try await backend.report(assetID: assetID, reason: reason) }
        FamilyReportReplies.markSent()
        if shown[cat]?.assetID == assetID { shown[cat] = nil }
        return number
    }

    /// This iPhone only; the other person is not told.
    func hide(_ personID: String) async -> Bool {
        guard let backend else { return false }
        do { try await SharingPersonAction.run { try await backend.hide(personID) } } catch { return false }
        for (cat, photo) in shown where photo.authorID == personID {
            shown[cat] = nil
            hiddenAuthors[cat] = personID
        }
        return true
    }

    func unhide(_ personID: String) async {
        guard let backend else { return }
        do { try await SharingPersonAction.run { try await backend.unhide(personID) } } catch { return }
        let cats = hiddenAuthors.filter { $0.value == personID }.map(\.key)
        for cat in cats { hiddenAuthors[cat] = nil }
        await SharingPersonAction.run { await read(cats, force: true) }
    }

    /// The cat's key photo of this iPhone, as the creator's iPhone sends it
    /// (the client re-encodes it without metadata).
    static func keyPhotoJPEG(_ localIdentifier: String) async -> Data? {
#if DEBUG
        if let image = AppStoreScreenshotFixture.CatHomeStress.image(for: localIdentifier) {
            return image.jpegData(compressionQuality: 0.9)
        }
#endif
        return await Task.detached(priority: .userInitiated) {
            PhotoImageLoader().image(localIdentifier: localIdentifier, targetSize: CGSize(width: 2048, height: 2048))?
                .jpegData(compressionQuality: 0.9)
        }.value
    }
}

/// A question about the family's photo, asked from 「…」.
enum FamilyPhotoQuestion: Identifiable, Equatable {
    case hide(personID: String)
    var id: String {
        switch self {
        case let .hide(personID): "hide-" + personID
        }
    }
}

struct FamilyPhotoReportTarget: Identifiable, Equatable {
    let cat: UUID
    let assetID: UUID
    var id: UUID { assetID }
}

/// 「…」's items for the family's photo of one cat, on the page of a family
/// cat with no cat of this iPhone. Nothing while it is off. 11/19: the
/// creator's photo goes by itself, so there is nothing to deliver here.
@MainActor
struct FamilyPhotoMenuItems: View {
    let cat: UUID
    @Binding var question: FamilyPhotoQuestion?
    @Binding var reportTarget: FamilyPhotoReportTarget?
    @ObservedObject private var photos = FamilyRepresentativePhotos.shared

    init(cat: UUID, question: Binding<FamilyPhotoQuestion?>, reportTarget: Binding<FamilyPhotoReportTarget?>) {
        self.cat = cat; _question = question; _reportTarget = reportTarget
    }

    static func hasItems(cat: UUID) -> Bool {
        let photos = FamilyRepresentativePhotos.shared
        guard photos.isOn else { return false }
        if let shown = photos.shown[cat], !photos.isMine(shown.authorID) { return true }
        return photos.hiddenAuthors[cat] != nil
    }

    var body: some View {
        if photos.isOn { receivedItems }
    }

    @ViewBuilder private var receivedItems: some View {
        if let shown = photos.shown[cat], !photos.isMine(shown.authorID) {
            Button("この写真を通報", systemImage: "exclamationmark.bubble") {
                reportTarget = FamilyPhotoReportTarget(cat: cat, assetID: shown.assetID)
            }
            .accessibilityIdentifier("family-photo-report")
            Button(photos.name(of: shown.authorID) + "の写真を表示しない", systemImage: "eye.slash") {
                question = .hide(personID: shown.authorID)
            }
            .accessibilityIdentifier("family-photo-hide")
        }
        if let hidden = photos.hiddenAuthors[cat] {
            Button(photos.name(of: hidden) + "の写真を表示する", systemImage: "eye") {
                Task { await photos.unhide(hidden) }
            }
            .accessibilityIdentifier("family-photo-unhide")
        }
    }
}

/// The questions and the report sheet of FamilyPhotoMenuItems, on the page.
@MainActor
struct FamilyPhotoDialogs: ViewModifier {
    @Binding var question: FamilyPhotoQuestion?
    @Binding var reportTarget: FamilyPhotoReportTarget?
    @ObservedObject private var photos = FamilyRepresentativePhotos.shared

    init(question: Binding<FamilyPhotoQuestion?>, reportTarget: Binding<FamilyPhotoReportTarget?>) {
        _question = question; _reportTarget = reportTarget
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(hideTitle, isPresented: asksHide, titleVisibility: .visible) {
                Button("表示しない", role: .destructive) { hide() }
                    .accessibilityIdentifier("family-photo-hide-confirm")
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この手帳で、" + hideName + "の写真がこのiPhoneに出なくなります。相手には知らせません。")
            }
            .sheet(item: $reportTarget) { target in
                FamilyPhotoReportSheet(target: target)
            }
    }

    private var hiddenPerson: String? {
        if case let .hide(personID) = question { return personID }
        return nil
    }
    private var asksHide: Binding<Bool> {
        Binding(get: { hiddenPerson != nil }, set: { if !$0, hiddenPerson != nil { question = nil } })
    }
    private var hideName: String { hiddenPerson.map { photos.name(of: $0) } ?? "" }
    private var hideTitle: String { hideName + "の写真を表示しませんか" }

    private func hide() {
        guard let personID = hiddenPerson else { return }
        Task { _ = await photos.hide(personID) }
    }
}

/// Reporting the family's photo shown on this page, as a まど photo is
/// reported (GroupReportSheet): why, and only this one photo is sent.
struct FamilyPhotoReportSheet: View {
    let target: FamilyPhotoReportTarget
    @ObservedObject private var photos = FamilyRepresentativePhotos.shared
    @Environment(\.dismiss) private var dismiss
    @State private var reason: GroupReportReason?
    @State private var number: String?
    @State private var sending = false
    @State private var failure: GroupSafetyError?

    var body: some View {
        NavigationStack {
            Form {
                if let number {
                    Section {
                        Label("通報しました", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                    } footer: {
                        Text("この写真は、このiPhoneではもう表示されません。")
                    }
                    Section {
                        LabeledContent("通報番号") {
                            Text(number).font(.body.monospaced()).textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("family-photo-report-number")
                    } footer: {
                        // 11/19 (UI/UX 整理): where the answer comes.
                        Text("返答は、家族の手帳の「通報への返答」に届きます。")
                    }
                } else {
                    Section {
                        ForEach(GroupReportReason.allCases, id: \.self) { candidate in
                            Button {
                                reason = candidate
                            } label: {
                                HStack {
                                    Text(candidate.title).foregroundStyle(.primary)
                                    Spacer()
                                    if reason == candidate { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                            .disabled(sending || failure == .unknownOutcome)
                            .accessibilityIdentifier("family-photo-report-reason-" + candidate.rawValue)
                        }
                    } header: {
                        Text("理由")
                    } footer: {
                        Text("運営に送るのはこの写真1枚だけです。送ると、この写真はこのiPhoneでは見えなくなります。")
                    }
                    if let failure {
                        Section {
                            Text(failure.message).font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("family-photo-report-failure")
                        }
                    }
                }
            }
            .navigationTitle("この写真を通報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(number != nil ? "閉じる" : "やめる") { dismiss() }
                        .disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                            .accessibilityLabel("送っています")
                    } else if number == nil {
                        Button(failure == .unknownOutcome ? "もう一度送る" : "送る") { Task { await send() } }
                            .disabled(reason == nil)
                            .accessibilityIdentifier("family-photo-report-send")
                    }
                }
            }
        }
        .interactiveDismissDisabled(sending)
    }

    /// The first tap fixes the photo and the reason; 「もう一度送る」 sends
    /// the same encrypted report again (kept by the service until received).
    private func send() async {
        guard let reason else { return }
        sending = true
        defer { sending = false }
        do {
            number = try await photos.report(cat: target.cat, assetID: target.assetID, reason: reason)
            failure = nil
        } catch FamilyNotebookPhotoFailure.unavailable {
            failure = .disabled
        } catch let error as GroupReportCryptoError {
            // Stopped on this iPhone before anything was sent: not 「送れた
            // かどうか分かりませんでした」 (11/19, TestFlight 391).
            switch error {
            case .invalidCanonicalJPEG, .payloadTooLarge: failure = .evidenceUnavailable
            case .invalidInput, .untrustedModerationKey: failure = .disabled
            }
        } catch {
            failure = .unknownOutcome
        }
    }
}
