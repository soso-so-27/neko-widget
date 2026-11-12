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
        })
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

/// Test builds only: the day a cat passed away (ねこのまど_ペットロスの方針_1028).
/// Kept on this iPhone until the saved records can hold it. Nothing is
/// deleted: the photos and records stay; the age stops at this day.
enum CatFarewell {
    static let key = "debug.catFarewell.days.v1"

    static func days(_ json: String) -> [String: CatCareDay] {
        (try? JSONDecoder().decode([String: CatCareDay].self, from: Data(json.utf8))) ?? [:]
    }

    static func setting(_ day: CatCareDay?, for subject: String, in json: String) -> String {
        var all = days(json)
        all[subject] = day
        guard let data = try? JSONEncoder().encode(all) else { return json }
        return String(decoding: data, as: UTF8.self)
    }

    static func text(_ day: CatCareDay) -> String {
        "\(day.year)年\(day.month)月\(day.day)日"
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
}

struct CatCareDetailView: View {
    let subject: CatCareSubject
    let otherProfiles: [CatProfilePresentation]
    @Binding var selectedProfileID: String?
    @ObservedObject private var store = CatCareStore.shared
    @Environment(\.toolProfileActions) private var profileActions
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
    @State private var isDeleting = false
    @State private var deleteFailed = false
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
    @State private var saveFailed = false
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
        return familyNotebook.familyCats.contains { $0.toolID == catID }
    }

    var body: some View {
        Form { formContent }
        .disabled(isDeleting)
        .navigationBarBackButtonHidden(isDeleting || isSavingName)
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
        .appRecordEditing(retainWhileHidden: draft != savedDraft || editing != nil || saveFailed || autosaveFailed
                          || showsNameEditor || isSavingName || showsKeyPhotoPicker
                          || photoRole != nil || cropRequest != nil)
        .familyNotebookToolSync(enabled: sharedWithFamily)
        .onChange(of: familyNotebook.familyWritesToCatCare) { _, _ in takeFamilyWrites() }
        .toolbar {
            // The family, at the top right like sharing in Notes, so it is
            // out of the way for anyone who keeps to themselves.
            // The same page opens from ツール and from the family notebook. A
            // cat in the notebook shows the family's faces here, so whose page
            // it is can be seen without words (11/6: "two places to write water?").
            // Inside the cat's page, that page shows it for both tabs (11/7).
            if !insideCatPage {
                if sharedWithFamily {
                    ToolbarItem(placement: .topBarTrailing) {
                        if insideFamilyNotebook {
                            FamilyFaces(names: familyNotebook.members.map(\.displayName))
                        } else {
                            FamilyNotebookButton(sharedNames: familyNotebook.members.map(\.displayName))
                        }
                    }
                } else if !insideFamilyNotebook, Version1.familyNotebook || familyNotebook.hasFamily {
                    ToolbarItem(placement: .topBarTrailing) { FamilyNotebookButton() }
                }
            }
        }
        .alert("保存できませんでした", isPresented: $saveFailed) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text("少し待ってから、もう一度お試しください。")
        }
        .sheet(item: $editing) { editor in
            CatCareListEntrySheet(editor: editor, catID: catID) { result in
                apply(result)
            }
        }
        .sheet(item: $photoRole) { role in
            CatCareIdentifyingPhotoSheet(subject: subject, role: role) { photoFailed = !$0 }
        }
        .sheet(item: $cropRequest) { request in
            LostCatPhotoCropView(image: request.image) { data in
                guard let jpeg = CatCareFormat.cleanJPEG(data),
                      let ref = store.savePhoto(jpeg, sourceAssetID: nil, origin: request.origin) else { return false }
                return setPhoto(ref, request.role)
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
                    CatProfilePhotoPicker(
                        photos: profile.confirmedPhotos,
                        selectedIdentifier: profile.keyPhotoIdentifier,
                        choose: { await profileActions.setKeyPhoto(profile.identifier, $0) }
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
        progressSection
        // 11/9: the photos every tool shows, open on the page, so a tool's
        // 「この子のこと」を開く lands right on them.
        identifyingPhotosSection
        // 11/12: the four parts are always open, each with how full it is in
        // its header; a row shows what is written and opens it.
        basicsSection
        healthSection
        livingSection
        householdSection
        // 11/12: deleting is the page's last row, after every part.
        if case let .profile(profile) = subject {
            deleteSection(profile)
        }
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

    @ViewBuilder private var progressSection: some View {
        if farewell == nil {
            // The same ring as on the ツール tab, so writing here visibly fills it.
            // One line beside it, not a dashboard: what the next entry is for.
            Section {
                HStack(spacing: 12) {
                    CatCareRing(progress: progress, lineWidth: 4)
                        .frame(width: 30, height: 30)
                    Text(progress.filled >= progress.total ? "すべてそろっています"
                         : progress.nextHint ?? "あと\(progress.total - progress.filled)つでそろいます")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("cat-care-next-hint")
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
    /// 11/12: two equal squares the photos fill (no gray bars), smaller than
    /// the old wide tiles, with their names and 「⋯」 under them.
    private var identifyingPhotosSection: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
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
                    .frame(maxWidth: 140)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// A part's header: its name, and how full it is at the trailing side,
    /// the same count as the ring (「基本　3 / 7」).
    private func partHeader(_ title: String, _ count: (Int, Int), key: String) -> some View {
        let full = count.0 >= count.1
        return HStack {
            Text(title)
            Spacer()
            Text(verbatim: full ? "そろっています" : "\(count.0) / \(count.1)")
                .foregroundStyle(full ? Color.green : Color.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)、\(count.0) / \(count.1)")
        .accessibilityIdentifier("cat-care-part-\(key)")
    }

    /// A choice's name with its icon, the same as a ToolValueRow's.
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
            noted(ToolValueRow(title: item.title, systemImage: item.systemImage, value: words ?? "未記入",
                               filled: words != nil, problem: problem), item.note)
        }
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
                }
            }
        }
        .disabled(isDeleting)
    }

    /// A row that opens a sheet (the dates): the same look, with a chevron.
    private func sheetRow(_ title: String, _ systemImage: String, value: String, filled: Bool,
                          identifier: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack {
                ToolValueRow(title: title, systemImage: systemImage, value: value, filled: filled)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
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
        Picker(selection: $draft.sex) {
            Text("未記入").tag(CatCareSex.unknown)
            Text("オス").tag(CatCareSex.male)
            Text("メス").tag(CatCareSex.female)
        } label: { Self.rowLabel("性別", "pawprint") }
        .pickerStyle(.menu)
        .familyNotebookNote(catID, .sex)
        .accessibilityIdentifier("cat-care-sex")
    }

    private var neuteredPicker: some View {
        Picker(selection: $draft.neutered) {
            Text("未記入").tag(CatCareTriState.unknown)
            Text("済み").tag(CatCareTriState.yes)
            Text("まだ").tag(CatCareTriState.no)
        } label: { Self.rowLabel("去勢・避妊", "checkmark.seal") }
        .pickerStyle(.menu)
        .familyNotebookNote(catID, .neutered)
        .accessibilityIdentifier("cat-care-neutered")
    }

    private var indoorPicker: some View {
        Picker(selection: $draft.indoorOnly) {
            Text("未記入").tag(CatCareTriState.unknown)
            Text("室内だけ").tag(CatCareTriState.yes)
            Text("外にも出る").tag(CatCareTriState.no)
        } label: { Self.rowLabel("室内飼い", "house") }
        .pickerStyle(.menu)
        .familyNotebookNote(catID, .indoorOnly)
        .accessibilityIdentifier("cat-care-indoor")
    }

    private var microchipPicker: some View {
        Picker(selection: $draft.microchipStatus) {
            Text("未記入").tag(CatCareMicrochipStatus.unknown)
            Text("入っている").tag(CatCareMicrochipStatus.recorded)
            Text("入っていない").tag(CatCareMicrochipStatus.none)
        } label: { Self.rowLabel("マイクロチップ", "memorychip") }
        .pickerStyle(.menu)
        .familyNotebookNote(catID, .microchip)
        .accessibilityIdentifier("cat-care-microchip-status")
    }

    /// The key photo (tap to change) and the name with its pencil, at the top
    /// of the page (11/7: moved from the page's old 写真 tab, then out of 基本).
    private func profileHeading(_ profile: CatProfilePresentation) -> some View {
        Section {
            VStack(spacing: 8) {
                let hasPhotos = !profile.confirmedPhotos.isEmpty
                Button {
                    showsKeyPhotoPicker = true
                } label: {
                    CatProfileThumbnail(photo: profile.coverPhoto)
                        .frame(width: 96, height: 96)
                        .clipShape(Circle())
                        // 11/7: a small badge says the photo can be changed.
                        .overlay(alignment: .bottomTrailing) {
                            if hasPhotos {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.title2)
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
                    // 11/7: why the photo cannot be chosen yet, in one line.
                    Text("写真タブでこの子の写真を追加すると選べます")
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
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
            .alert("名前を変更", isPresented: $showsNameEditor) {
                TextField("名前", text: $draftName)
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
    private func nameButton(_ profile: CatProfilePresentation) -> some View {
        Button {
            draftName = profile.name ?? ""
            nameSaveFailed = false
            showsNameEditor = true
        } label: {
            HStack(spacing: 8) {
                Text(profile.displayName)
                    .font(.title2.bold())
                    .foregroundStyle(Color.primary)
                Image(systemName: "pencil.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
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
        guard !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSavingName = true
        nameSaveFailed = false
        Task {
            let saved = await profileActions.updateName(profile.identifier, draftName)
            isSavingName = false
            nameSaveFailed = !saved
        }
    }

    /// Deleting the cat, the page's last row (11/12; was the last of 基本). The confirmation also
    /// offers to record the day instead, as before (11/7: moved from 写真).
    private func deleteSection(_ profile: CatProfilePresentation) -> some View {
        Section {
            Button("この子を削除", role: .destructive) {
                deleteFailed = false
                showsDeleteConfirmation = true
            }
            .accessibilityIdentifier("cat-profile-delete")
            .alert("\(profile.displayName)を削除しますか？", isPresented: $showsDeleteConfirmation) {
                Button("この子を削除", role: .destructive) {
                    isDeleting = true
                    deleteFailed = false
                    Task {
                        let deleted = await profileActions.deleteProfile(profile.identifier)
                        isDeleting = false
                        if deleted {
                            dismiss()
                        } else { deleteFailed = true }
                    }
                }
                // When a cat has died, deleting is usually where people go. Offer
                // to record the day instead; the button says what it opens.
                if farewell == nil, Version1.isOn {
                    Button("旅立った日を記録する") { showsFarewellEditor = true }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                // 11/7: what goes (removeProfile drops the profile and which
                // photos are this cat), what stays, and that it is final.
                Text("名前・誕生日と、この子に分けた写真の記録が消えます。写真アプリの写真とツールの記録は残ります。元に戻せません。")
            }
            if deleteFailed {
                Text("削除できませんでした。もう一度お試しください。")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
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
        Picker(selection: $draft.conditionsStatus) {
            Text("未記入").tag(CatCareConditionsStatus.unknown)
            Text("なし").tag(CatCareConditionsStatus.none)
            Text("あり").tag(CatCareConditionsStatus.recorded)
        } label: { Self.rowLabel("持病", "heart.text.square") }
        .pickerStyle(.menu)
        .familyNotebookNote(catID, .conditions)
        .accessibilityIdentifier("cat-care-conditions-status")
    }

    private var allergyPicker: some View {
        Picker(selection: $draft.allergyStatus) {
            Text("未確認").tag(CatCareAllergy.Status.unknown)
            Text("なし").tag(CatCareAllergy.Status.none)
            Text("あり").tag(CatCareAllergy.Status.recorded)
        } label: { Self.rowLabel("アレルギー", "allergens") }
        .pickerStyle(.menu)
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
        Picker(selection: $draft.vetStatus) {
            Text("未記入").tag(CatCareVetStatus.unknown)
            Text("決まっている").tag(CatCareVetStatus.recorded)
            Text("まだない").tag(CatCareVetStatus.none)
        } label: { Self.rowLabel("かかりつけ", "cross.case") }
        .pickerStyle(.menu)
        .familyNotebookNote(catID, .vetName)
        .accessibilityIdentifier("cat-care-vet-status")
    }

    /// A list (体重・薬・ワクチン・ごはん): the same row look, opening its list.
    private func listRow(title: String, systemImage: String, detail: String,
                         kind: CatCareListEditor.Kind) -> some View {
        NavigationLink {
            CatCareListView(kind: kind, catID: catID, editing: $editing)
        } label: {
            ToolValueRow(title: title, systemImage: systemImage, value: detail, filled: detail != "未記入")
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
        guard let latest = currentRecord?.activeWeights.first else { return "未記入" }
        return CatCareFormat.weight(latest.grams) + "（\(CatCareFormat.day(latest.measuredOn))）"
    }

    private var medicationSummary: String {
        let count = currentRecord?.activeMedications.count ?? 0
        return count == 0 ? "未記入" : "\(count)件"
    }

    private var vaccinationSummary: String {
        guard let latest = currentRecord?.activeVaccinations.first else {
            return draft.vaccinationStatus == CatCareVaccinationStatus.none ? CatCareVaccinationStatus.noneText : "未記入"
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
    }

    /// Saves what changed. A microchip number that is not 15 digits yet is
    /// kept on screen and not saved; everything else is saved.
    private func save() {
        guard let catID, draft != savedDraft, store.canSave else { return }
        var value = draft
        if draft.microchipStatus != .recorded {
            value.microchip = ""
            microchipInvalid = false
        } else if let chip = CatCareLimits.normalizedMicrochip(draft.microchip), !chip.isEmpty {
            value.microchip = chip
            microchipInvalid = false
        } else {
            // 「入っている」 with no full number yet: keep what was saved.
            value.microchipStatus = savedDraft.microchipStatus
            value.microchip = savedDraft.microchip
            microchipInvalid = !draft.microchip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let saved = store.update { state in
            guard let index = state.cats.firstIndex(where: { $0.catID == catID }) else { return }
            value.write(to: &state.cats[index], household: &state.household,
                        by: state.deviceID, now: Date())
        }
        // What was actually stored: an unfinished chip number stays out of it.
        if saved { savedDraft = value }
        if saved { UsageCounter.shared.count(.catCareEdited) }  // Usage (11/7): each autosave that stored a change
        if saved, let state = store.state, let record = state.record(catID: catID) {
            storedDraft = CatCareDraft(record: record, household: state.household)
        }
        autosaveFailed = !saved
    }

    /// The family's writing came into 「この子のこと」 (test builds): show it.
    /// Items typed here and not saved yet stay as typed and are saved after.
    private func takeFamilyWrites() {
        guard let catID, let state = store.state, let record = state.record(catID: catID) else { return }
        let fresh = CatCareDraft(record: record, household: state.household)
        var next = draft
        // Taken: an item untouched here whose stored value someone else changed.
        func take<Value: Equatable>(_ path: WritableKeyPath<CatCareDraft, Value>) {
            if draft[keyPath: path] == savedDraft[keyPath: path], fresh[keyPath: path] != storedDraft[keyPath: path] {
                next[keyPath: path] = fresh[keyPath: path]
            }
        }
        take(\.sex); take(\.neutered); take(\.indoorOnly); take(\.allergyStatus); take(\.conditionsStatus)
        take(\.microchipStatus); take(\.vaccinationStatus); take(\.vetStatus)
        let texts: [WritableKeyPath<CatCareDraft, String>] = [
            \.coat, \.marks, \.microchip, \.conditions, \.allergyText, \.specialDiet, \.water, \.litter,
            \.temperament, \.ownerContact, \.backupContact, \.vetName, \.vetPhone]
        for path in texts { take(path) }
        savedDraft = fresh
        storedDraft = fresh
        draft = next
    }

    private func apply(_ result: CatCareListEditor.Result) {
        guard let catID else { return }
        let saved = store.update { state in
            guard let index = state.cats.firstIndex(where: { $0.catID == catID }) else { return }
            result.apply(to: &state.cats[index], by: state.deviceID, now: Date())
        }
        if !saved { saveFailed = true }
    }
}

/// A written item of 「この子のこと」 (11/12): its row shows the first words and
/// opens a page with this one field. The example is the field's placeholder,
/// as before; the keyboard and the 15-digit check stay the same.
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

    // 基本
    static var coat: Self {
        Self(title: "毛色・柄", systemImage: "paintpalette", example: "例：キジトラ", path: \.coat,
             identifier: "cat-care-coat", note: .coat)
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
             identifier: "cat-care-allergy-text", note: .allergyText)
    }
    // 暮らし
    static var specialDiet: Self {
        Self(title: "食事の注意", systemImage: "leaf", example: "例：療法食、ほかの猫と分けてあげる",
             path: \.specialDiet, identifier: "cat-care-special-diet", note: .specialDiet, lines: 3...8)
    }
    static var water: Self {
        Self(title: "水", systemImage: "drop", example: "例：1日2回とりかえる", path: \.water,
             identifier: "cat-care-water", note: .water)
    }
    static var litter: Self {
        Self(title: "トイレ", systemImage: "tray", example: "例：システムトイレ・1日2回そうじ", path: \.litter,
             identifier: "cat-care-litter", note: .litter)
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
             example: "例：家族の名前と電話番号", path: \.backupContact, identifier: "cat-care-backup-contact")
    }
    static var vetName: Self {
        Self(title: "かかりつけ病院の名前", systemImage: "building.2", example: "例：みどり動物病院", path: \.vetName,
             identifier: "cat-care-vet-name")
    }
    static var vetPhone: Self {
        Self(title: "かかりつけ病院の電話", systemImage: "phone.circle", example: "例：03-1234-5678", path: \.vetPhone,
             identifier: "cat-care-vet-phone", note: .vetPhone, keyboard: .phonePad)
    }
}

/// The one field on a written item's page. Its name is the page's title, so
/// the field shows only the example; VoiceOver reads the name.
private struct CatCareTextField: View {
    let item: CatCareTextItem
    @Binding var text: String
    let focus: FocusState<Bool>.Binding

    var body: some View {
        TextField(item.example, text: $text, axis: item.lines == nil ? .horizontal : .vertical)
            .lineLimit(item.lines ?? (1...1))
            .keyboardType(item.keyboard)
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
/// tab and the 「基本　3 / 7」 rows here use this one count.
struct CatCareProgress {
    let basics: (Int, Int)
    let health: (Int, Int)
    let living: (Int, Int)
    let household: (Int, Int)
    /// The tool whose entries are closest to all in, for one line at the top.
    let nextHint: String?

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
        nextHint = tools.map { ($0.0, $0.1.filter { !$0 }.count) }
            .filter { $0.1 > 0 }
            .min { ($0.1, $0.0) < ($1.1, $1.0) }
            .map { "あと\($0.1)つで「\($0.0)」の項目がそろいます" }
    }
}

/// The ring around a cat: one arc that grows as この子のこと is filled.
struct CatCareRing: View {
    let progress: CatCareProgress
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress.total == 0 ? 0 : CGFloat(progress.filled) / CGFloat(progress.total))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: progress.filled)
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

    /// Writes only fields that changed, so each keeps its own who/when.
    func write(to r: inout CatCareRecord, household h: inout CatCareHousehold, by: String, now: Date) {
        func set<V: Codable & Equatable & Sendable>(_ field: inout CatCareStamped<V>?, _ value: V, empty: V) {
            if field?.value == value || (field == nil && value == empty) { return }
            field = .init(value: value, editedAt: now, editedBy: by)
        }
        func text(_ value: String) -> String { CatCareLimits.clippedText(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        set(&r.sex, sex, empty: .unknown)
        set(&r.neutered, neutered, empty: .unknown)
        set(&r.indoorOnly, indoorOnly, empty: .unknown)
        set(&r.coat, text(coat), empty: "")
        set(&r.marks, text(marks), empty: "")
        let chip = microchipStatus == .recorded ? microchip : ""
        if (microchipStatus, chip) != (r.microchipStatus, r.microchipStatus == .recorded ? r.microchip?.value ?? "" : "") {
            r.setMicrochip(status: microchipStatus, number: chip, editedAt: now, editedBy: by)
        }
        // A vaccination in the list is the answer; the toggle only speaks for an empty list.
        if r.activeVaccinations.isEmpty, vaccinationStatus != .recorded, vaccinationStatus != r.vaccinationStatus {
            r.setVaccinationStatus(vaccinationStatus, editedAt: now, editedBy: by)
        }
        // 「あり」 with 「なし」 typed in is the none choice; 「あり」 with nothing typed keeps what was saved.
        let details = conditionsStatus == .recorded ? text(conditions) : ""
        let status: CatCareConditionsStatus = CatCareConditionsStatus.reading(details) == CatCareConditionsStatus.none
            ? CatCareConditionsStatus.none : conditionsStatus
        if (status, details) != (r.conditionsStatus, r.conditionsStatus == .recorded ? r.conditions?.value ?? "" : "") {
            r.setConditions(status: status, text: details, editedAt: now, editedBy: by)
        }
        set(&r.allergy, CatCareAllergy(status: allergyStatus, text: allergyStatus == .recorded ? text(allergyText) : ""),
            empty: CatCareAllergy())
        set(&r.specialDiet, text(specialDiet), empty: "")
        set(&r.water, text(water), empty: "")
        set(&r.litter, text(litter), empty: "")
        set(&r.temperament, text(temperament), empty: "")
        set(&h.ownerContact, text(ownerContact), empty: "")
        set(&h.backupContact, text(backupContact), empty: "")
        let vet = vetStatus == .recorded ? (text(vetName), text(vetPhone)) : ("", "")
        let effectiveVet = r.vetOverride?.value ?? h.vet?.value
        let savedStatus = r.vetStatus(household: h)
        let savedVet = savedStatus == .recorded ? (effectiveVet?.name ?? "", effectiveVet?.phone ?? "") : ("", "")
        if vetStatus != savedStatus || vet != savedVet {
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

    enum Result {
        case weight(grams: Int, day: CatCareDay, replacing: UUID? = nil)
        case medication(name: String, dose: String, schedule: String, replacing: UUID? = nil)
        case vaccination(kind: String, day: CatCareDay, proof: CatCarePhotoRef?, replacing: UUID? = nil)
        case meal(time: String, food: String, amount: String, replacing: UUID? = nil)
        case delete(kind: Kind, entryID: UUID)

        func apply(to r: inout CatCareRecord, by: String, now: Date) {
            switch self {
            case let .weight(grams, day, replacing):
                if let index = replacing.flatMap({ id in r.weights.firstIndex { $0.id == id } }) {
                    r.weights[index].grams = grams; r.weights[index].measuredOn = day
                    r.weights[index].editedAt = now; r.weights[index].editedBy = by
                    return
                }
                guard r.weights.count < CatCareLimits.maximumWeights else { return }
                r.weights.append(.init(measuredOn: day, grams: grams, editedAt: now, editedBy: by))
            case let .medication(name, dose, schedule, replacing):
                if let index = replacing.flatMap({ id in r.medications.firstIndex { $0.id == id } }) {
                    r.medications[index].name = CatCareLimits.clippedText(name)
                    r.medications[index].dose = CatCareLimits.clippedText(dose)
                    r.medications[index].schedule = CatCareLimits.clippedText(schedule)
                    r.medications[index].editedAt = now; r.medications[index].editedBy = by
                    return
                }
                guard r.medications.count < CatCareLimits.maximumMedications else { return }
                r.medications.append(.init(name: CatCareLimits.clippedText(name), dose: CatCareLimits.clippedText(dose),
                                           schedule: CatCareLimits.clippedText(schedule), editedAt: now, editedBy: by))
            case let .vaccination(kind, day, proof, replacing):
                if let index = replacing.flatMap({ id in r.vaccinations.firstIndex { $0.id == id } }) {
                    r.vaccinations[index].kind = CatCareLimits.clippedText(kind)
                    r.vaccinations[index].givenOn = day
                    r.replaceVaccinationProof(proof, for: r.vaccinations[index].id)
                    r.vaccinations[index].editedAt = now; r.vaccinations[index].editedBy = by
                    return
                }
                guard r.vaccinations.count < CatCareLimits.maximumVaccinations else { return }
                r.vaccinations.append(.init(kind: CatCareLimits.clippedText(kind), givenOn: day, proof: proof,
                                            editedAt: now, editedBy: by))
            case let .meal(time, food, amount, replacing):
                if let index = replacing.flatMap({ id in r.meals.firstIndex { $0.id == id } }) {
                    r.meals[index].time = time; r.meals[index].food = food; r.meals[index].amount = amount
                    r.meals[index].editedAt = now; r.meals[index].editedBy = by
                    return
                }
                guard r.activeMeals.count < CatCareLimits.maximumMeals else { return }
                r.meals.append(.init(time: time, food: food, amount: amount,
                                     order: (r.activeMeals.map(\.order).max() ?? -1) + 1,
                                     editedAt: now, editedBy: by))
            case let .delete(kind, entryID):
                // Mark, never remove: a shared copy must not bring it back.
                switch kind {
                case .weight: r.weights.markDeleted(entryID, at: now, by: by)
                case .medication: r.medications.markDeleted(entryID, at: now, by: by)
                case .vaccination: r.vaccinations.markDeleted(entryID, at: now, by: by)
                case .meal: r.meals.markDeleted(entryID, at: now, by: by)
                }
            }
        }
    }
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
                                guard let i = state.cats.firstIndex(where: { $0.catID == catID }) else { return }
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
            Button { editing = CatCareListEditor(kind: kind) } label: {
                Label(CatCareFormat.title(kind) + "を追加", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canSave)
            .accessibilityIdentifier("cat-care-add-\(kind.rawValue)")
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
        } message: { Text("削除した記録は、ほかのツールにも載らなくなります。") }
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
            guard let index = state.cats.firstIndex(where: { $0.catID == catID }) else { return }
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
    let onSave: (CatCareListEditor.Result) -> Void
    @Environment(\.dismiss) private var dismiss
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
    @State private var proof: CatCarePhotoRef?
    @State private var opensProof = false
    @State private var removesProof = false
    @State private var message: String?

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
                        Button { showsCamera = true } label: {
                            Label(proof == nil ? "証明をカメラで撮る" : "カメラで撮り直す", systemImage: "camera")
                        }
                        .accessibilityIdentifier("cat-care-proof-camera")
                    }
                    if let current = proof {
                        Button { opensProof = true } label: {
                            Label("証明の写真を付けました", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        .contextMenu { Button("写真を外す", role: .destructive) { removesProof = true } }
                        .confirmationDialog("写真を外しますか？", isPresented: $removesProof) {
                            Button("写真を外す", role: .destructive) { proof = nil }
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
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(editor.entryID == nil ? "追加" : "保存") { save() } }
                if let entryID = editor.entryID {
                    ToolbarItem(placement: .bottomBar) {
                        Button("この記録を削除", role: .destructive) {
                            dismiss()
                            NotificationCenter.default.post(name: Self.deleteRequested, object: entryID)
                        }
                        .accessibilityIdentifier("cat-care-delete-entry")
                    }
                }
            }
            .onAppear(perform: fillFromRecord)
            .fullScreenCover(isPresented: $showsCamera) {
                CatCareCameraView { image in
                    showsCamera = false
                    guard let image else { return }
                    // Re-encoding drops metadata. The shot stays in this app, not in Photos.
                    if let data = image.jpegData(compressionQuality: 0.95), let jpeg = CatCareFormat.cleanJPEG(data) {
                        proof = store.savePhoto(jpeg, sourceAssetID: nil, origin: .camera)
                    } else {
                        message = "写真を保存できませんでした。空き容量を確かめて、もう一度お試しください。"
                    }
                }
                .ignoresSafeArea()
            }
            .onChange(of: proofItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let jpeg = CatCareFormat.cleanJPEG(data) {
                        proof = store.savePhoto(jpeg, sourceAssetID: item.itemIdentifier, origin: .photos)
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
            gramsText = String(format: "%.2f", Double(entry.grams) / 1000)
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

    private func save() {
        guard let day = CatCareDay(date: date) else { return }
        let replacing = editor.entryID
        switch editor.kind {
        case .weight:
            // kg, as in the photo memo. Full-width digits and a comma also work.
            let half = gramsText.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? gramsText
            let number = half.replacingOccurrences(of: ",", with: ".").filter { $0.isASCII && ($0.isNumber || $0 == ".") }
            guard let kilograms = Double(number), kilograms > 0,
                  let today = CatCareDay(date: Date()),
                  case let grams = Int((kilograms * 1000).rounded()),
                  CatCareLimits.isValidWeight(grams: grams, on: day, today: today)
            else { message = "体重はkgの数字で入れてください（例：4.2）。"; return }
            onSave(.weight(grams: grams, day: day, replacing: replacing))
        case .medication:
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { message = "薬の名前を入れてください。"; return }
            onSave(.medication(name: name, dose: dose, schedule: schedule, replacing: replacing))
        case .vaccination:
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { message = "種類を入れてください。"; return }
            onSave(.vaccination(kind: name, day: day, proof: proof, replacing: replacing))
        case .meal:
            guard ![name, food, amount].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                message = "時間・フード・量のどれかを入れてください。"; return
            }
            onSave(.meal(time: name, food: food, amount: amount, replacing: replacing))
        }
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

    /// One 見分ける写真 set or taken off, saved at once (not with the typed draft).
    func setIdentifyingPhoto(_ ref: CatCarePhotoRef?, _ role: CatCarePhotoRole, catID: UUID) -> Bool {
        update { state in
            guard let index = state.cats.firstIndex(where: { $0.catID == catID }) else { return }
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
        guard let catID = store.ensureRecord(for: subject)?.catID else { onSaved(false); return false }
        let saved = store.setIdentifyingPhoto(ref, role, catID: catID)
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

    /// The folded row: 「この子のこと」, then what is used (up to four names),
    /// then, short, what is not written yet.
    private func foldedLabel(filled: [(String, String)], missing: [String], dated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(Color.primary)
            let summary = filled.prefix(4).map(\.0).joined(separator: "・") + (filled.count > 4 ? " など" : "")
            if !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !missing.isEmpty {
                Text("まだ：" + missing.prefix(4).joined(separator: "・") + (missing.count > 4 ? " など" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if summary.isEmpty && missing.isEmpty && !dated {
                Text("まだ何も書いていません。").font(.caption).foregroundStyle(.secondary)
            }
        }
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
//   1. the cat row, then one gray sentence: what the page makes (ToolPurpose)
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

/// One gray sentence under the cat row: what this page makes.
struct ToolPurpose: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
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
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
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
}

extension View {
    /// 11/11: inside a tool the app's tab bar is hidden, so the tool's bar sits
    /// at the very bottom instead of on top of the tab bar. Set on every page a
    /// tool pushes: a pushed page without it brings the tab bar back. Popping
    /// back to the ツール list shows the tab bar again.
    func toolChrome() -> some View {
        toolbar(.hidden, for: .tabBar)
    }

    /// Room under the last row for the fade above ToolMakeBar, so the last row
    /// can be scrolled fully clear of it.
    func toolBarFadeRoom() -> some View {
        contentMargins(.bottom, ToolChrome.fade, for: .scrollContent)
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

    private var tile: some View {
        Color(.tertiarySystemGroupedBackground)
            .aspectRatio(fillsSquare ? 1 : 4.0 / 3.0, contentMode: .fit)
            .overlay {
                if fillsSquare, let shown { Image(uiImage: shown).resizable().scaledToFill() }
                else if let shown { Image(uiImage: shown).resizable().scaledToFit() }
                else if !hasPhoto {
                    Image(systemName: readOnly ? "photo" : "photo.badge.plus").font(.title2).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    /// A square the photo fills, cut at the edges (11/12, 「この子のこと」's
    /// 見分ける写真); every other screen keeps the whole photo in a wide tile.
    func filledSquare() -> Self {
        var slot = self
        slot.fillsSquare = true
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
                Button(action: choose) { tile }
                    .buttonStyle(.plain)
                    .accessibilityLabel(chooseOnly && !hasPhoto ? title + "、まだありません" : title)
                    .accessibilityIdentifier(identifier)
                    .disabled(disabled)
            }
            HStack {
                Text(title).font(.caption)
                    .foregroundStyle(dimmedTitle ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
                if hasPhoto && !readOnly && !chooseOnly {
                    Menu { actions } label: {
                        Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(title)の操作")
                    .accessibilityIdentifier(actionsIdentifier)
                }
            }
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
                ToolPhotoSlot(readOnly: "顔の写真", file: faceFile, identifier: identifier + "-face")
                if showsBody {
                    ToolPhotoSlot(readOnly: "全身の写真", file: bodyFile, identifier: identifier + "-body")
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
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 2048
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.85)
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
