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
                    Text("写真や記録、ホーム画面のウィジェットは、すべてそのまま残ります。ウィジェットを変えたいときは、長押しして「ウィジェットを編集」から選べます。")
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
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("記録する") { save(CatCareDay(date: date)); dismiss() }
                        .accessibilityIdentifier("cat-farewell-save")
                }
            }
            .onAppear {
                if let recorded, let day = Calendar.current.date(from: DateComponents(
                    year: recorded.year, month: recorded.month, day: recorded.day)) { date = day }
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

    /// This cat is in the family notebook (not just: this person has a family).
    private var sharedWithFamily: Bool {
        guard let catID else { return false }
        return familyNotebook.familyCats.contains { $0.toolID == catID }
    }

    var body: some View {
        Form {
            // 11/7: the photo and name lead the page, outside the folds, so
            // whose page it is shows before anything is opened.
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
            if let message = store.loadError {
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            } else if store.unreadableCatCount > 0 {
                Section {
                    Label("開けない記録があるので、いまは保存できません。アプリを最新にしてください。",
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
            // Folded by default: four short rows that say how full each part is.
            // Open one to write in it; nothing is hidden, only folded.
            folded("basics", "基本", progress.basics) { basicsSection }
            folded("health", "健康", progress.health) { healthSection }
            folded("living", "暮らし", progress.living) { livingSection }
            folded("household", "家の情報", progress.household) { householdSection }
        }
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
                          || showsNameEditor || isSavingName || showsKeyPhotoPicker)
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

    @ViewBuilder private var basicsSection: some View {
        Section {
            // The dates are facts about the cat, so they live here with the
            // rest; the album reads them from here.
            if case let .profile(profile) = subject {
                Button { showsLifeDatesEditor = true } label: {
                    HStack {
                        LabeledContent("誕生日・迎えた日", value: profile.lifeDatesSummary)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("cat-care-life-dates")
            }
            if let farewell {
                Button { showsFarewellEditor = true } label: {
                    HStack {
                        LabeledContent("旅立った日", value: CatFarewell.text(farewell))
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("cat-care-farewell")
            }
            if let farewellSharing, farewell != nil || farewellSharing.sharedDay != nil {
                Button { showsFarewellSharing = true } label: {
                    HStack {
                        LabeledContent(farewell == nil ? "家族が記録した旅立った日" : "家族の手帳",
                                       value: FamilyNotebookWords.farewellStatus(farewellSharing))
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("cat-care-farewell-family")
            }
            Picker("性別", selection: $draft.sex) {
                Text("未記入").tag(CatCareSex.unknown)
                Text("オス").tag(CatCareSex.male)
                Text("メス").tag(CatCareSex.female)
            }
            .familyNotebookNote(catID, .sex)
            Picker("去勢・避妊", selection: $draft.neutered) {
                Text("未記入").tag(CatCareTriState.unknown)
                Text("済み").tag(CatCareTriState.yes)
                Text("まだ").tag(CatCareTriState.no)
            }
            .familyNotebookNote(catID, .neutered)
            Picker("室内飼い", selection: $draft.indoorOnly) {
                Text("未記入").tag(CatCareTriState.unknown)
                Text("室内だけ").tag(CatCareTriState.yes)
                Text("外にも出る").tag(CatCareTriState.no)
            }
            .familyNotebookNote(catID, .indoorOnly)
            CatCareTextField(label: "毛色・柄", example: "例：キジトラ", text: $draft.coat)
                .familyNotebookNote(catID, .coat)
            CatCareTextField(label: "見分ける特徴", example: "例：しっぽが短い、右耳に切れ込み",
                             text: $draft.marks, axis: .vertical, lines: 2...4)
                .familyNotebookNote(catID, .marks)
            Picker("マイクロチップ", selection: $draft.microchipStatus) {
                Text("未記入").tag(CatCareMicrochipStatus.unknown)
                Text("入っている").tag(CatCareMicrochipStatus.recorded)
                Text("入っていない").tag(CatCareMicrochipStatus.none)
            }
            .familyNotebookNote(catID, .microchip)
            .accessibilityIdentifier("cat-care-microchip-status")
            if draft.microchipStatus == .recorded {
                VStack(alignment: .leading, spacing: 4) {
                    CatCareTextField(label: "マイクロチップ番号", example: "15桁の数字", text: $draft.microchip,
                                     identifier: "cat-care-microchip")
                        .keyboardType(.numberPad)
                        .font(.body.monospacedDigit())
                    if microchipInvalid {
                        Label("15桁の数字にすると保存されます。", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        } footer: {
            Text(basicsFooter)
                .accessibilityIdentifier("cat-care-basics")
        }
        // 11/7: deleting is the last row of 基本, not the page's loudest line.
        if case let .profile(profile) = subject {
            deleteSection(profile)
        }
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
                HStack(spacing: 8) {
                    Text(profile.displayName)
                        .font(.title2.bold())
                    if !showsNameEditor {
                        Button {
                            draftName = profile.name ?? ""
                            nameSaveFailed = false
                            showsNameEditor = true
                        } label: {
                            Image(systemName: "pencil.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("名前を変更")
                        .accessibilityIdentifier("cat-profile-rename")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)

            if showsNameEditor {
                TextField("名前", text: $draftName)
                    .disabled(isSavingName)
                    .accessibilityIdentifier("cat-profile-name-field")
                if nameSaveFailed {
                    Text("名前を保存できませんでした。もう一度お試しください。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("キャンセル") { showsNameEditor = false }
                    Spacer()
                    Button(isSavingName ? "保存中…" : "保存") {
                        isSavingName = true
                        nameSaveFailed = false
                        Task {
                            let saved = await profileActions.updateName(profile.identifier, draftName)
                            isSavingName = false
                            if saved { showsNameEditor = false } else { nameSaveFailed = true }
                        }
                    }
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .buttonStyle(.borderless)
                .disabled(isSavingName)
            }
        }
    }

    /// Deleting the cat, the last row of 基本. The confirmation also
    /// offers to record the day instead, as before (11/7: moved from 写真).
    private func deleteSection(_ profile: CatProfilePresentation) -> some View {
        Section {
            Button("プロフィールを削除", role: .destructive) {
                deleteFailed = false
                showsDeleteConfirmation = true
            }
            .accessibilityIdentifier("cat-profile-delete")
            .alert("\(profile.displayName)のプロフィールを削除しますか？", isPresented: $showsDeleteConfirmation) {
                Button("プロフィールを削除", role: .destructive) {
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

    @State private var openParts: Set<String> = []

    /// A part of この子のこと: one row while folded (「健康　2 / 4」), the whole
    /// section when opened. Tapping the row again folds it. The row is the
    /// part's title, so the opened sections carry no header of their own.
    @ViewBuilder private func folded<Content: View>(_ key: String, _ title: String, _ count: (Int, Int),
                                                    @ViewBuilder content: () -> Content) -> some View {
        let isOpen = openParts.contains(key)
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isOpen { openParts.remove(key) } else { openParts.insert(key) }
                }
            } label: {
                HStack {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Spacer()
                    Text(verbatim: count.0 >= count.1 ? "そろっています" : "\(count.0) / \(count.1)")
                        .font(.subheadline)
                        .foregroundStyle(count.0 >= count.1 ? Color.green : Color.secondary)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("\(title)、\(count.0) / \(count.1)")
            .accessibilityHint(isOpen ? "たたむ" : "開いて書く")
            .accessibilityIdentifier("cat-care-part-\(key)")
        }
        if isOpen { content() }
    }

    private var healthSection: some View {
        Section {
            // Like アレルギー: 「なし」 is an answer too, so a healthy cat's page can be all filled in.
            Picker("持病", selection: $draft.conditionsStatus) {
                Text("未記入").tag(CatCareConditionsStatus.unknown)
                Text("なし").tag(CatCareConditionsStatus.none)
                Text("あり").tag(CatCareConditionsStatus.recorded)
            }
            .familyNotebookNote(catID, .conditions)
            .accessibilityIdentifier("cat-care-conditions-status")
            if draft.conditionsStatus == .recorded {
                CatCareTextField(label: "持病の内容", example: "例：腎臓の療法食中", text: $draft.conditions,
                                 axis: .vertical, lines: 1...4, identifier: "cat-care-conditions-text")
            }
            Picker("アレルギー", selection: $draft.allergyStatus) {
                Text("未確認").tag(CatCareAllergy.Status.unknown)
                Text("なし").tag(CatCareAllergy.Status.none)
                Text("あり").tag(CatCareAllergy.Status.recorded)
            }
            .familyNotebookNote(catID, .allergyStatus)
            if draft.allergyStatus == .recorded {
                CatCareTextField(label: "アレルギーの内容", example: "例：鶏肉", text: $draft.allergyText)
                    .familyNotebookNote(catID, .allergyText)
            }
            listRow(title: "体重", detail: weightSummary, kind: .weight)
            listRow(title: "飲んでいる薬", detail: "\(currentRecord?.activeMedications.count ?? 0)件", kind: .medication)
            listRow(title: "ワクチン", detail: vaccinationSummary, kind: .vaccination)
            if currentRecord?.activeVaccinations.isEmpty ?? true {
                // No history to list: 「受けていない」 is an answer too.
                Toggle("ワクチンは受けていない", isOn: Binding(
                    get: { draft.vaccinationStatus == CatCareVaccinationStatus.none },
                    set: { draft.vaccinationStatus = $0 ? CatCareVaccinationStatus.none : .unknown }))
                    .accessibilityIdentifier("cat-care-vaccination-none")
            }
        }
    }

    private var livingSection: some View {
        Section {
            listRow(title: "ごはん", detail: "\(currentRecord?.activeMeals.count ?? 0)回", kind: .meal)
            CatCareTextField(label: "食事の注意", example: "例：療法食、ほかの猫と分けてあげる",
                             text: $draft.specialDiet, axis: .vertical, lines: 1...3)
                .familyNotebookNote(catID, .specialDiet)
            CatCareTextField(label: "水", example: "例：1日2回とりかえる", text: $draft.water)
                .familyNotebookNote(catID, .water)
            CatCareTextField(label: "トイレ", example: "例：システムトイレ・1日2回そうじ", text: $draft.litter)
                .familyNotebookNote(catID, .litter)
            CatCareTextField(label: "接し方・苦手なこと", example: "例：抱っこが苦手",
                             text: $draft.temperament, axis: .vertical, lines: 1...4)
                .familyNotebookNote(catID, .temperament)
        }
    }

    private var householdSection: some View {
        Section {
            CatCareTextField(label: "飼い主の連絡先", example: "例：090-1234-5678", text: $draft.ownerContact)
            CatCareTextField(label: "つながらないときの連絡先", example: "例：家族の名前と電話番号", text: $draft.backupContact)
            Picker("かかりつけ", selection: $draft.vetStatus) {
                Text("未記入").tag(CatCareVetStatus.unknown)
                Text("決まっている").tag(CatCareVetStatus.recorded)
                Text("まだない").tag(CatCareVetStatus.none)
            }
            .familyNotebookNote(catID, .vetName)
            .accessibilityIdentifier("cat-care-vet-status")
            if draft.vetStatus == .recorded {
                CatCareTextField(label: "かかりつけ病院の名前", example: "例：みどり動物病院", text: $draft.vetName)
                CatCareTextField(label: "かかりつけ病院の電話", example: "例：03-1234-5678", text: $draft.vetPhone)
                    .keyboardType(.phonePad)
                    .familyNotebookNote(catID, .vetPhone)
            }
            // 11/7: the family's meeting place is written only in 避難に備える
            // (one place); the stored value is kept and read there.
        } footer: {
            Text("ほかの猫とも共通です。")
        }
    }

    private func listRow(title: String, detail: String, kind: CatCareListEditor.Kind) -> some View {
        NavigationLink {
            CatCareListView(kind: kind, catID: catID, editing: $editing)
        } label: {
            LabeledContent(title, value: detail)
        }
        .disabled(catID == nil)
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

    private var vaccinationSummary: String {
        guard let latest = currentRecord?.activeVaccinations.first else {
            return draft.vaccinationStatus == CatCareVaccinationStatus.none ? CatCareVaccinationStatus.noneText : "未記入"
        }
        return "\(latest.kind)（\(CatCareFormat.day(latest.givenOn))）"
    }

    // MARK: Load and save

    private func load() {
        let found: CatCareRecord?
        switch subject {
        case let .profile(profile):
            found = UUID(uuidString: profile.identifier).flatMap { store.ensureRecord(profileID: $0, name: profile.name) }
        case let .toolCat(id, name):
            found = store.ensureRecord(toolCatID: id, profileIdentifier: nil, name: name)
        }
        guard let record = found else { catID = nil; return }
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

/// A field with its name always shown above it, like 預けるとき's fields
/// (11/7: the name was only the placeholder, so once typed, the two
/// contacts looked alike). The placeholder is an example.
private struct CatCareTextField: View {
    let label: String
    let example: String
    @Binding var text: String
    var axis: Axis = .horizontal
    var lines: ClosedRange<Int> = 1...1
    var identifier = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .accessibilityHidden(true)
            TextField(example, text: $text, axis: axis)
                .lineLimit(lines)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
        }
        .padding(.vertical, 2)
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
                    if let proof { r.vaccinations[index].proof = proof }
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
                            if entry.proof != nil {
                                Label("証明の写真あり", systemImage: "doc.text.image")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
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
        case .vaccination: record?.activeVaccinations.isEmpty ?? true
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
                    if proof != nil {
                        Label("証明の写真を付けました", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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
            Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? Date()
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
            name = entry.kind; date = dateOf(entry.givenOn); proof = entry.proof
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
    let extra: () -> Extra

    init(title: String, lines: [(String, String)], subject: CatCareSubject?, footer: String? = nil,
         identifier: String, editIdentifier: String, profiles: [CatProfilePresentation] = [],
         showsLifeDates: Bool = true, @ViewBuilder extra: @escaping () -> Extra) {
        self.title = title; self.lines = lines; self.subject = subject; self.footer = footer
        self.identifier = identifier; self.editIdentifier = editIdentifier; self.profiles = profiles
        self.showsLifeDates = showsLifeDates
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
        } header: { Text(title) }
          footer: { if let footer { Text(footer) } }
    }
}

extension ToolCatCareSection where Extra == EmptyView {
    init(title: String, lines: [(String, String)], subject: CatCareSubject?, footer: String? = nil,
         identifier: String, editIdentifier: String, profiles: [CatProfilePresentation] = [],
         showsLifeDates: Bool = true) {
        self.init(title: title, lines: lines, subject: subject, footer: footer,
                  identifier: identifier, editIdentifier: editIdentifier, profiles: profiles,
                  showsLifeDates: showsLifeDates) { EmptyView() }
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

    /// The record for a tool's cat: the shared tool ID first, then the profile.
    static func record(toolCatID: UUID, profileIdentifier: String?) -> CatCareRecord? {
        let cats = CatCareStore.shared.state?.cats.filter { $0.deletedAt == nil } ?? []
        if let match = cats.first(where: { $0.catID == toolCatID }) { return match }
        return profileIdentifier.flatMap { record(profileIdentifier: $0) }
    }

}
