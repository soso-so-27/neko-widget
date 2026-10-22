import PhotosUI
import SwiftUI
import UIKit

// 「この子のこと」: each cat's information in one place, read by every tool.
// Stored on this iPhone only. Nothing here is sent anywhere; it leaves the
// iPhone only when the owner exports a tool's sheet themselves.

/// Entry from the Tools tab: pick a cat (with several), then its page.
struct CatCareEntryView: View {
    let profiles: [CatProfilePresentation]
    @ObservedObject private var store = CatCareStore.shared
    @AppStorage("catCare.lastProfile.v1") private var lastProfileID = ""
    @State private var selectedProfileID: String?

    var body: some View {
        Group {
            if profiles.isEmpty {
                ContentUnavailableView(
                    "まだ猫のプロフィールがありません",
                    systemImage: "cat",
                    description: Text("ツールの「猫のプロフィール」で猫を入れると、ここで猫ごとの情報をまとめられます。")
                )
            } else if let profile = selectedProfile {
                CatCareDetailView(profile: profile, otherProfiles: profiles.count > 1 ? profiles : [],
                                  selectedProfileID: $selectedProfileID)
            }
        }
        .navigationTitle("この子のこと")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.importFromTools()
            store.importBirthdays(profiles)
            if selectedProfileID == nil {
                selectedProfileID = profiles.first { $0.identifier == lastProfileID }?.identifier
                    ?? profiles.first?.identifier
            }
        }
        .onChange(of: selectedProfileID) { _, value in
            if let value { lastProfileID = value }
        }
        .task {
            // Weights written in photo memos join the weight list (read only; memos are not changed).
            guard let records = try? await PhotoMemoryNoteStore.shared.records() else { return }
            store.importWeights(records.compactMap { record in
                record.note.weight.map { weight in
                    CatCareMemoWeight(noteID: record.note.id.uuidString, catID: weight.catID,
                                      grams: weight.value.grams, measuredOn: weight.value.measuredOn,
                                      fallbackDate: record.note.context?.capturedAt ?? record.note.writtenAt)
                }
            })
        }
    }

    private var selectedProfile: CatProfilePresentation? {
        profiles.first { $0.identifier == selectedProfileID } ?? profiles.first
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

/// 「この子のことを直す」 from a tool: the profile's page, or the guest cat's.
struct CatCareSubjectView: View {
    let subject: CatCareSubject
    @ObservedObject private var store = CatCareStore.shared

    var body: some View {
        switch subject {
        case let .profile(profile):
            CatCareEntryView(profiles: [profile])
        case let .toolCat(id, name):
            CatCareDetailView(toolCatID: id, name: name)
                .navigationTitle("この子のこと")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear { store.importFromTools() }
        }
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

    init(profile: CatProfilePresentation, otherProfiles: [CatProfilePresentation],
         selectedProfileID: Binding<String?>) {
        subject = .profile(profile)
        self.otherProfiles = otherProfiles
        _selectedProfileID = selectedProfileID
    }

    init(toolCatID: UUID, name: String) {
        subject = .toolCat(id: toolCatID, name: name)
        otherProfiles = []
        _selectedProfileID = .constant(nil)
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = CatCareDraft()
    @State private var savedDraft = CatCareDraft()
    @State private var catID: UUID?
    @State private var autosave: Task<Void, Never>?
    @State private var saveFailed = false
    @State private var editing: CatCareListEditor?
    @State private var microchipInvalid = false

    var body: some View {
        Form {
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
                    Label("読み込めない記録があるため、いまは保存できません。アプリを最新にしてください。記録は消していません。",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            basicsSection
            healthSection
            livingSection
            householdSection
            Section {
                Text("書いた内容は自動で保存します。")
                Text("このiPhoneの中だけに保存し、外には送りません。")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("cat-care-autosave-note")
        }
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
        .alert("保存できませんでした", isPresented: $saveFailed) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text("入れた内容は画面に残っています。少し待ってから、もう一度お試しください。")
        }
        .sheet(item: $editing) { editor in
            CatCareListEntrySheet(editor: editor, catID: catID) { result in
                apply(result)
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

    /// The top of the page: how far this cat's page is, and what each entry
    /// makes possible (the lost-cat picture, the care sheet, the vet sheet).
    private var progressSection: some View {
        let progress = CatCareProgress(draft: draft, record: currentRecord)
        return Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(Color(.tertiarySystemFill), lineWidth: 7)
                        Circle()
                            .trim(from: 0, to: progress.total == 0 ? 0 : CGFloat(progress.filled) / CGFloat(progress.total))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.4), value: progress.filled)
                        Text("\(progress.filled)")
                            .font(.title3.bold().monospacedDigit())
                    }
                    .frame(width: 58, height: 58)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(progress.filled >= progress.total ? "すべて入っています"
                             : "\(progress.filled) / \(progress.total) 入っています")
                            .font(.headline)
                        if let hint = progress.nextHint {
                            Text(hint).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 10) {
                    ForEach(progress.sheets, id: \.title) { sheet in
                        VStack(spacing: 5) {
                            VStack(spacing: 4) {
                                Image(systemName: sheet.isComplete ? "checkmark.circle.fill" : "doc.text")
                                    .font(.title3)
                                    .foregroundStyle(sheet.isComplete ? Color.green : Color.secondary)
                                Text(sheet.title).font(.caption.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(sheet.isComplete ? "できた" : "\(sheet.done) / \(sheet.total)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(sheet.isComplete ? Color.green : Color.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(sheet.title)、\(sheet.isComplete ? "できています" : "\(sheet.done)／\(sheet.total)")")
                    }
                }
            }
            .padding(.vertical, 6)
            .accessibilityIdentifier("cat-care-progress")
        } footer: {
            Text("入れるほど、迷子の画像・預けるメモ・病院の控えが埋まります。")
        }
    }

    /// 「ミケ・2020/1/1（4歳）」: read-only facts go in the footer, not in rows.
    private var basicsFooter: String {
        var line = subject.displayName
        if let birthday = currentRecord?.birthday?.value ?? nil {
            line += "・誕生日 " + CatCareFormat.day(birthday)
                + (CatCareLostCat.age(birthday, today: CatCareDay(date: Date())).map { "（\($0)）" } ?? "")
        } else if case .profile = subject {
            line += "・誕生日は未記入"
        }
        if case .profile = subject { line += "。名前と誕生日は猫のプロフィールで直せます。" }
        return line
    }

    private var basicsSection: some View {
        Section {
            if case let .profile(profile) = subject {
                // Name and birthday belong to the cat profile; change them there.
                NavigationLink {
                    CatProfileDetailView(profile: profile, allProfiles: otherProfiles.isEmpty ? [profile] : otherProfiles,
                        manualCandidatePhotos: profile.manualCandidatePhotos, photoAlbumOptions: [], actions: profileActions)
                } label: {
                    Label("猫のプロフィール", systemImage: "cat")
                }
                .accessibilityIdentifier("cat-care-open-profile")
            }
            Picker("性別", selection: $draft.sex) {
                Text("未記入").tag(CatCareSex.unknown)
                Text("オス").tag(CatCareSex.male)
                Text("メス").tag(CatCareSex.female)
            }
            Picker("去勢・避妊", selection: $draft.neutered) {
                Text("未記入").tag(CatCareTriState.unknown)
                Text("済み").tag(CatCareTriState.yes)
                Text("まだ").tag(CatCareTriState.no)
            }
            Picker("室内飼い", selection: $draft.indoorOnly) {
                Text("未記入").tag(CatCareTriState.unknown)
                Text("室内だけ").tag(CatCareTriState.yes)
                Text("外にも出る").tag(CatCareTriState.no)
            }
            TextField("毛色・柄（例：キジトラ）", text: $draft.coat)
            TextField("見分ける特徴（例：しっぽが短い、右耳に切れ込み）", text: $draft.marks, axis: .vertical)
                .lineLimit(2...4)
            VStack(alignment: .leading, spacing: 4) {
                TextField("マイクロチップ番号（15桁）", text: $draft.microchip)
                    .keyboardType(.numberPad)
                    .font(.body.monospacedDigit())
                    .accessibilityIdentifier("cat-care-microchip")
                if microchipInvalid {
                    Label("15桁の数字で入れると保存します。", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("基本")
        } footer: {
            Text(basicsFooter)
                .accessibilityIdentifier("cat-care-basics")
        }
    }

    private var healthSection: some View {
        Section {
            TextField("持病（例：腎臓の療法食中）", text: $draft.conditions, axis: .vertical)
                .lineLimit(1...4)
            Picker("アレルギー", selection: $draft.allergyStatus) {
                Text("未確認").tag(CatCareAllergy.Status.unknown)
                Text("なし").tag(CatCareAllergy.Status.none)
                Text("あり").tag(CatCareAllergy.Status.recorded)
            }
            if draft.allergyStatus == .recorded {
                TextField("アレルギーの内容", text: $draft.allergyText)
            }
            listRow(title: "体重", detail: weightSummary, kind: .weight)
            listRow(title: "飲んでいる薬", detail: "\(currentRecord?.activeMedications.count ?? 0)件", kind: .medication)
            listRow(title: "ワクチン", detail: vaccinationSummary, kind: .vaccination)
        } header: {
            Text("健康")
        } footer: {
            Text("体重は、写真のメモの「体重を添える」でも記録できます。")
        }
    }

    private var livingSection: some View {
        Section("暮らし") {
            listRow(title: "ごはん", detail: "\(currentRecord?.activeMeals.count ?? 0)回", kind: .meal)
            TextField("療法食・別々に与えるなど（何匹もいるとき大事）", text: $draft.specialDiet, axis: .vertical)
                .lineLimit(1...3)
            TextField("水", text: $draft.water)
            TextField("トイレ", text: $draft.litter)
            TextField("接し方・苦手なこと", text: $draft.temperament, axis: .vertical)
                .lineLimit(1...4)
        }
    }

    private var householdSection: some View {
        Section {
            TextField("飼い主の連絡先", text: $draft.ownerContact)
            TextField("予備の連絡先", text: $draft.backupContact)
            TextField("かかりつけ病院の名前", text: $draft.vetName)
            TextField("かかりつけ病院の電話", text: $draft.vetPhone)
                .keyboardType(.phonePad)
            TextField("避難のときの家族の集合場所", text: $draft.meetingPlace)
        } header: {
            Text("家の情報")
        } footer: {
            Text("ほかの猫と共通です。1回入れると、どの猫にも載ります。")
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

    private var currentRecord: CatCareRecord? { catID.flatMap { store.state?.record(catID: $0) } }

    private var weightSummary: String {
        guard let latest = currentRecord?.activeWeights.first else { return "未記入" }
        return CatCareFormat.weight(latest.grams) + "（\(CatCareFormat.day(latest.measuredOn))）"
    }

    private var vaccinationSummary: String {
        guard let latest = currentRecord?.activeVaccinations.first else { return "未記入" }
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
        microchipInvalid = false
    }

    /// Saves what changed. A microchip number that is not 15 digits yet is
    /// kept on screen and not saved; everything else is saved.
    private func save() {
        guard let catID, draft != savedDraft, store.canSave else { return }
        var value = draft
        if let chip = CatCareLimits.normalizedMicrochip(draft.microchip) {
            value.microchip = chip
            microchipInvalid = false
        } else {
            value.microchip = savedDraft.microchip
            microchipInvalid = true
        }
        let saved = store.update { state in
            guard let index = state.cats.firstIndex(where: { $0.catID == catID }) else { return }
            value.write(to: &state.cats[index], household: &state.household,
                        by: state.deviceID, now: Date())
        }
        // What was actually stored: an unfinished chip number stays out of it.
        if saved { savedDraft = value } else { saveFailed = true }
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

// MARK: - Progress (what is filled, and what that makes)

/// Which entries are in, and how close each tool's sheet is. The fields are
/// the ones the sheets print; nothing is counted twice.
struct CatCareProgress {
    struct Sheet: Equatable {
        let title: String
        let done: Int
        let total: Int
        var isComplete: Bool { done >= total }
    }

    let filled: Int
    let total: Int
    let sheets: [Sheet]

    init(draft: CatCareDraft, record: CatCareRecord?) {
        func has(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let items: [(String, Bool)] = [
            ("毛色", has(draft.coat)),
            ("特徴", has(draft.marks)),
            ("連絡先", has(draft.ownerContact)),
            ("ごはん", (record?.activeMeals.count ?? 0) > 0),
            ("水", has(draft.water)),
            ("トイレ", has(draft.litter)),
            ("接し方", has(draft.temperament)),
            ("かかりつけ", has(draft.vetName)),
            ("体重", (record?.activeWeights.count ?? 0) > 0),
            ("ワクチン", (record?.activeVaccinations.count ?? 0) > 0),
            ("持病", has(draft.conditions)),
            ("アレルギー", draft.allergyStatus != .unknown)
        ]
        filled = items.filter(\.1).count
        total = items.count
        func sheet(_ title: String, _ names: [String]) -> Sheet {
            let picked = items.filter { names.contains($0.0) }
            return Sheet(title: title, done: picked.filter(\.1).count, total: picked.count)
        }
        sheets = [
            sheet("迷子", ["毛色", "特徴", "連絡先"]),
            sheet("預ける", ["ごはん", "水", "トイレ", "接し方", "かかりつけ"]),
            sheet("病院", ["体重", "ワクチン", "持病", "アレルギー", "かかりつけ"])
        ]
    }

    /// The sheet closest to done: 「あと2つで「預ける」の控えが完成」.
    var nextHint: String? {
        sheets.filter { !$0.isComplete }
            .min { ($0.total - $0.done, $0.title) < ($1.total - $1.done, $1.title) }
            .map { "あと\($0.total - $0.done)つで「\($0.title)」の控えが完成" }
    }
}

// MARK: - Draft (single values edited on the page)

struct CatCareDraft: Equatable {
    var sex: CatCareSex = .unknown
    var neutered: CatCareTriState = .unknown
    var indoorOnly: CatCareTriState = .unknown
    var coat = ""
    var marks = ""
    var microchip = ""
    var conditions = ""
    var allergyStatus: CatCareAllergy.Status = .unknown
    var allergyText = ""
    var specialDiet = ""
    var water = ""
    var litter = ""
    var temperament = ""
    var ownerContact = ""
    var backupContact = ""
    var vetName = ""
    var vetPhone = ""
    var meetingPlace = ""

    init() {}

    init(record: CatCareRecord, household: CatCareHousehold) {
        sex = record.sex?.value ?? .unknown
        neutered = record.neutered?.value ?? .unknown
        indoorOnly = record.indoorOnly?.value ?? .unknown
        coat = record.coat?.value ?? ""
        marks = record.marks?.value ?? ""
        microchip = record.microchip?.value ?? ""
        conditions = record.conditions?.value ?? ""
        allergyStatus = record.allergy?.value.status ?? .unknown
        allergyText = record.allergy?.value.text ?? ""
        specialDiet = record.specialDiet?.value ?? ""
        water = record.water?.value ?? ""
        litter = record.litter?.value ?? ""
        temperament = record.temperament?.value ?? ""
        ownerContact = household.ownerContact?.value ?? ""
        backupContact = household.backupContact?.value ?? ""
        vetName = household.vet?.value.name ?? ""
        vetPhone = household.vet?.value.phone ?? ""
        meetingPlace = household.meetingPlace?.value ?? ""
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
        set(&r.microchip, microchip, empty: "")
        set(&r.conditions, text(conditions), empty: "")
        set(&r.allergy, CatCareAllergy(status: allergyStatus, text: allergyStatus == .recorded ? text(allergyText) : ""),
            empty: CatCareAllergy())
        set(&r.specialDiet, text(specialDiet), empty: "")
        set(&r.water, text(water), empty: "")
        set(&r.litter, text(litter), empty: "")
        set(&r.temperament, text(temperament), empty: "")
        set(&h.ownerContact, text(ownerContact), empty: "")
        set(&h.backupContact, text(backupContact), empty: "")
        set(&h.vet, CatCareVet(name: text(vetName), phone: text(vetPhone), note: h.vet?.value.note ?? ""),
            empty: CatCareVet())
        set(&h.meetingPlace, text(meetingPlace), empty: "")
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
            content().frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
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
                case .vaccination:
                    TextField("種類（例：3種混合）", text: $name)
                    DatePicker("接種した日", selection: $date, in: ...Date(), displayedComponents: .date)
                    PhotosPicker(selection: $proofItem, matching: .images) {
                        Label(proof == nil ? "証明の写真を写真から選ぶ" : "証明の写真を選び直す", systemImage: "photo")
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
    let extra: () -> Extra

    init(title: String, lines: [(String, String)], subject: CatCareSubject?, footer: String? = nil,
         identifier: String, editIdentifier: String, @ViewBuilder extra: @escaping () -> Extra) {
        self.title = title; self.lines = lines; self.subject = subject; self.footer = footer
        self.identifier = identifier; self.editIdentifier = editIdentifier; self.extra = extra
    }

    /// A line whose value only says it is not written yet.
    private static func isEmptyLine(_ line: (String, String)) -> Bool {
        line.1.hasPrefix("未記入") || line.1.hasPrefix("未確認")
    }

    var body: some View {
        let filled = lines.filter { !Self.isEmptyLine($0) }
        let missing = lines.filter(Self.isEmptyLine).map(\.0)
        Section {
            ForEach(Array(filled.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 4) {
                    Text(line.0).font(.subheadline).foregroundStyle(.secondary)
                    Text(line.1).font(.body).textSelection(.enabled)
                }
            }
            .accessibilityIdentifier(identifier)
            if filled.isEmpty {
                Text("まだ何も書いていません。「この子のことを直す」から書くと、ここと渡す控えに載ります。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(identifier + "-empty")
            }
            if !missing.isEmpty && !filled.isEmpty {
                // 「、」 between items: some names already contain 「・」.
                Text("まだ書いていないこと：" + missing.joined(separator: "、"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            extra()
            if let subject {
                NavigationLink("この子のことを直す") { CatCareSubjectView(subject: subject) }
                    .accessibilityIdentifier(editIdentifier)
            }
        } header: { Text(title) }
          footer: { if let footer { Text(footer) } }
    }
}

extension ToolCatCareSection where Extra == EmptyView {
    init(title: String, lines: [(String, String)], subject: CatCareSubject?, footer: String? = nil,
         identifier: String, editIdentifier: String) {
        self.init(title: title, lines: lines, subject: subject, footer: footer,
                  identifier: identifier, editIdentifier: editIdentifier) { EmptyView() }
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

enum CatCareFormat {
    static func day(_ day: CatCareDay) -> String { "\(day.year)/\(day.month)/\(day.day)" }

    static func weight(_ grams: Int) -> String {
        grams >= 1000 ? String(format: "%.2fkg", Double(grams) / 1000) : "\(grams)g"
    }

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

// MARK: - What tools show from 「この子のこと」

/// Read-only lines a tool shows or exports. Empty items say so instead of
/// inventing anything; nothing here is a medical judgement.
@MainActor
enum CatCareSummary {
    static func record(profileIdentifier: String) -> CatCareRecord? {
        guard let profileID = UUID(uuidString: profileIdentifier) else { return nil }
        return CatCareStore.shared.state?.cats.first { $0.profileID == profileID && $0.deletedAt == nil }
    }

    /// For 「病院で見せる」: what a vet usually asks first.
    static func veterinaryFields(_ record: CatCareRecord?, household: CatCareHousehold?) -> [(String, String)] {
        let empty = "未記入・飼い主に確認"
        func text(_ value: String?) -> String {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? empty : trimmed
        }
        var fields: [(String, String)] = []
        let sex: String = switch record?.sex?.value ?? .unknown {
        case .male: "オス"
        case .female: "メス"
        case .unknown: "未記入"
        }
        let neutered: String = switch record?.neutered?.value ?? .unknown {
        case .yes: "去勢・避妊 済み"
        case .no: "去勢・避妊 まだ"
        case .unknown: "去勢・避妊 未記入"
        }
        // Both unknown: one 「未記入」, not 「未記入・去勢・避妊 未記入」.
        let bothUnknown = (record?.sex?.value ?? .unknown) == .unknown && (record?.neutered?.value ?? .unknown) == .unknown
        fields.append(("性別", bothUnknown ? empty : sex + "・" + neutered))
        fields.append(("年齢", CatCareLostCat.age(record?.birthday?.value, today: CatCareDay(date: Date())) ?? empty))
        fields.append(("マイクロチップ", text(record?.microchip?.value)))
        fields.append(("持病", text(record?.conditions?.value)))
        let allergy: String = switch record?.allergy?.value.status ?? .unknown {
        case .none: "なし（飼い主の記入）"
        case .recorded: text(record?.allergy?.value.text)
        case .unknown: "未確認・飼い主に確認"
        }
        fields.append(("アレルギー", allergy))
        let medications = (record?.activeMedications ?? []).map { medication in
            [medication.name, medication.dose, medication.schedule].filter { !$0.isEmpty }.joined(separator: "・")
        }
        fields.append(("飲んでいる薬", medications.isEmpty ? empty : medications.joined(separator: "\n")))
        let vaccinations = (record?.activeVaccinations ?? []).prefix(3).map {
            "\($0.kind)（\(CatCareFormat.day($0.givenOn))）" + ($0.proof != nil ? " 証明あり" : "")
        }
        fields.append(("ワクチン", vaccinations.isEmpty ? empty : vaccinations.joined(separator: "\n")))
        fields.append(("体重の推移", weightTrend(record).map { $0.isEmpty ? empty : $0.joined(separator: "\n") } ?? empty))
        if let diet = record?.specialDiet?.value, !diet.isEmpty { fields.append(("療法食など", diet)) }
        let vet = record?.vetOverride?.value ?? household?.vet?.value
        if let vet, !vet.isEmpty {
            fields.append(("かかりつけ病院", [vet.name, vet.phone].filter { !$0.isEmpty }.joined(separator: " ")))
        }
        return fields
    }

    /// The record for a tool's cat: the shared tool ID first, then the profile.
    static func record(toolCatID: UUID, profileIdentifier: String?) -> CatCareRecord? {
        let cats = CatCareStore.shared.state?.cats.filter { $0.deletedAt == nil } ?? []
        if let match = cats.first(where: { $0.catID == toolCatID }) { return match }
        return profileIdentifier.flatMap { record(profileIdentifier: $0) }
    }

    /// For 「預けるとき」: 「3歳・4.20kg（2026/10/20）」. Nil when neither is recorded.
    static func ageAndWeight(_ record: CatCareRecord?, today: CatCareDay? = CatCareDay(date: Date())) -> String? {
        var parts: [String] = []
        if let age = CatCareLostCat.age(record?.birthday?.value, today: today) { parts.append(age) }
        if let latest = record?.activeWeights.first {
            parts.append(CatCareFormat.weight(latest.grams) + "（\(CatCareFormat.day(latest.measuredOn))）")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    /// For 「預けるとき」 when health is shared: each medicine on its own line with
    /// dose and timing, and the allergy record. Only what the owner wrote.
    static func careHandoffHealthFields(_ record: CatCareRecord?) -> [(String, String)] {
        var fields: [(String, String)] = []
        let medicines = (record?.activeMedications ?? []).map { medicine in
            [medicine.name, medicine.dose, medicine.schedule, medicine.note]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "・")
        }.filter { !$0.isEmpty }
        if !medicines.isEmpty { fields.append(("飲んでいる薬（量・時間）", medicines.joined(separator: "\n"))) }
        switch record?.allergy?.value.status ?? .unknown {
        case .none: fields.append(("アレルギー", "なし（飼い主の記入）"))
        case .recorded:
            let text = (record?.allergy?.value.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            fields.append(("アレルギー", text.isEmpty ? "あり・飼い主に確認" : text))
        case .unknown: break
        }
        return fields
    }

    // MARK: One place for each fact

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 「この子のこと」's value; the tool's older entry only for a field never
    /// set here. A field the owner cleared stays empty.
    private static func pick(_ field: CatCareStamped<String>?, _ legacy: String?, empty: String) -> String {
        if let field { return nonEmpty(field.value) ?? empty }
        return nonEmpty(legacy) ?? empty
    }

    /// 「朝7時 腎臓ケア 20g」, one meal a line.
    static func mealsText(_ record: CatCareRecord?) -> String? {
        let lines = (record?.activeMeals ?? []).map { meal in
            [meal.time, meal.food, meal.amount].compactMap(nonEmpty).joined(separator: " ")
        }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 「キジトラ・しっぽが短い」.
    static func features(_ record: CatCareRecord?, legacy: String?) -> String? {
        if record?.coat != nil || record?.marks != nil {
            let parts = [record?.coat?.value, record?.marks?.value].compactMap(nonEmpty)
            return parts.isEmpty ? nil : parts.joined(separator: "・")
        }
        return nonEmpty(legacy)
    }

    /// For 「預けるとき」: everyday care, all from 「この子のこと」.
    static func careHandoffLines(_ record: CatCareRecord?, legacy cat: CareCat) -> [(String, String)] {
        let empty = "未記入・飼い主に確認"
        var lines: [(String, String)] = []
        if let about = ageAndWeight(record) { lines.append(("年齢・体重", about)) }
        let neverHadMeals = record?.meals.isEmpty ?? true
        let food = mealsText(record) ?? (neverHadMeals ? nonEmpty(cat.reusableFood) : nil)
        lines.append(("ごはん", food ?? empty))
        if let diet = nonEmpty(record?.specialDiet?.value) { lines.append(("療法食など", diet)) }
        lines.append(("水", pick(record?.water, cat.water, empty: empty)))
        lines.append(("トイレ", pick(record?.litter, cat.toilet, empty: empty)))
        lines.append(("接し方・苦手なこと", pick(record?.temperament, cat.handling, empty: empty)))
        return lines
    }

    /// For 「預けるとき」 when health is shared: medicines, allergy and conditions.
    /// A note written in the tool before is shown until 「この子のこと」 has them.
    static func careHandoffHealthLines(_ record: CatCareRecord?, legacy cat: CareCat) -> [(String, String)] {
        var fields = careHandoffHealthFields(record)
        if let conditions = nonEmpty(record?.conditions?.value) { fields.append(("持病", conditions)) }
        if fields.isEmpty, cat.healthStatus != .unknown {
            fields.append(("薬・アレルギー（前にこのツールに書いた内容）", cat.healthText))
        }
        if fields.isEmpty { fields.append(("薬・アレルギー", "未記入・飼い主に確認")) }
        return fields
    }

    /// For 「避難に備える」: one cat's sheet. What is shown follows the toggles;
    /// everything per cat comes from 「この子のこと」.
    static func evacuationShareFields(_ record: CatCareRecord?, legacy cat: EvacuationCat,
                                      household: CatCareHousehold?, planContact: String,
                                      disclosure: EvacuationDisclosure) -> [(String, String)] {
        let empty = "未記入"
        var fields: [(String, String)] = [("見分ける特徴", features(record, legacy: cat.features) ?? empty)]
        fields.append(evacuationFields(record)[0])
        if disclosure.food {
            let neverHadMeals = record?.meals.isEmpty ?? true
            let food = [mealsText(record), nonEmpty(record?.specialDiet?.value)].compactMap { $0 }
            let text = food.isEmpty ? (neverHadMeals ? nonEmpty(cat.food) : nil) : food.joined(separator: "\n")
            fields.append(("いつものごはん", text ?? empty))
        }
        if disclosure.handling {
            fields.append(("接し方・苦手なこと", pick(record?.temperament, cat.handling, empty: empty)))
        }
        if disclosure.medical {
            var health: [(String, String)] = []
            if let conditions = nonEmpty(record?.conditions?.value) { health.append(("持病", conditions)) }
            health += careHandoffHealthFields(record)
            if health.isEmpty {
                // Older entry from this tool only when it says something.
                health.append(cat.medicalStatus == .unknown ? ("病歴・薬", empty) : ("病歴・薬（飼い主の記録）", cat.medicalText))
            }
            fields += health
        }
        if disclosure.contact {
            fields.append(("飼い主の連絡先", pick(household?.ownerContact, planContact, empty: empty)))
        }
        if disclosure.catCare { fields += evacuationFields(record).dropFirst() }
        return fields
    }

    /// For 「避難に備える」: what a shelter asks to see.
    static func evacuationFields(_ record: CatCareRecord?,
                                 today: CatCareDay? = CatCareDay(date: Date())) -> [(String, String)] {
        let empty = "未記入"
        var about: [String] = []
        switch record?.sex?.value ?? .unknown {
        case .male: about.append("オス")
        case .female: about.append("メス")
        case .unknown: break
        }
        switch record?.neutered?.value ?? .unknown {
        case .yes: about.append("去勢・避妊 済み")
        case .no: about.append("去勢・避妊 まだ")
        case .unknown: break
        }
        if let age = CatCareLostCat.age(record?.birthday?.value, today: today) { about.append(age) }
        if let latest = record?.activeWeights.first { about.append(CatCareFormat.weight(latest.grams)) }
        var fields: [(String, String)] = [("性別・年齢・体重", about.isEmpty ? empty : about.joined(separator: "・"))]
        let chip = (record?.microchip?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        fields.append(("マイクロチップ番号", chip.isEmpty ? empty : chip))
        let vaccinations = (record?.activeVaccinations ?? []).prefix(4).map { entry in
            var line = "\(entry.kind)（\(CatCareFormat.day(entry.givenOn))）"
            if let next = entry.nextDueOn { line += " 次回 \(CatCareFormat.day(next))" }
            if entry.proof != nil { line += " 証明あり" }
            return line
        }
        fields.append(("ワクチン", vaccinations.isEmpty ? empty : vaccinations.joined(separator: "\n")))
        return fields
    }

    /// For 「迷子のとき」: what the police, the health center and shelters ask.
    /// Shown in the app for reporting; none of it goes on the flyer by itself.
    static func lostCatReportFields(_ record: CatCareRecord?,
                                    today: CatCareDay? = CatCareDay(date: Date())) -> [(String, String)] {
        let empty = "未記入"
        func text(_ value: String?) -> String {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? empty : trimmed
        }
        var fields: [(String, String)] = []
        let sex: String = switch record?.sex?.value ?? .unknown {
        case .male: "オス"
        case .female: "メス"
        case .unknown: empty
        }
        let neutered: String = switch record?.neutered?.value ?? .unknown {
        case .yes: "・去勢・避妊 済み"
        case .no: "・去勢・避妊 まだ"
        case .unknown: ""
        }
        fields.append(("性別", sex + neutered))
        fields.append(("年齢", CatCareLostCat.age(record?.birthday?.value, today: today) ?? empty))
        if let latest = record?.activeWeights.first {
            fields.append(("体重", CatCareFormat.weight(latest.grams) + "（\(CatCareFormat.day(latest.measuredOn))）"))
        }
        fields.append(("毛色", text(record?.coat?.value)))
        fields.append(("見分ける特徴", text(record?.marks?.value)))
        fields.append(("マイクロチップ番号", text(record?.microchip?.value)))
        let indoor: String = switch record?.indoorOnly?.value ?? .unknown {
        case .yes: "室内飼い（外に慣れていない）"
        case .no: "外にも出る"
        case .unknown: empty
        }
        fields.append(("暮らし", indoor))
        let medications = (record?.activeMedications ?? []).map(\.name).filter { !$0.isEmpty }
        if !medications.isEmpty { fields.append(("飲んでいる薬", medications.joined(separator: "・"))) }
        return fields
    }

    /// Newest first, with the change from the previous record:
    /// 「2026/10/20 4.20kg（前回から −0.10kg）」. Up to six lines.
    static func weightTrend(_ record: CatCareRecord?) -> [String]? {
        guard let weights = record?.activeWeights, !weights.isEmpty else { return nil }
        let recent = Array(weights.prefix(7))
        return recent.prefix(6).enumerated().map { index, entry in
            var line = CatCareFormat.day(entry.measuredOn) + " " + CatCareFormat.weight(entry.grams)
            if index + 1 < recent.count {
                let diff = entry.grams - recent[index + 1].grams
                let sign = diff > 0 ? "＋" : diff < 0 ? "−" : "±"
                line += "（前回から \(sign)\(String(format: "%.2f", Double(abs(diff)) / 1000))kg）"
            }
            return line
        }
    }
}
