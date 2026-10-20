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
                    "まだ猫が登録されていません",
                    systemImage: "cat",
                    description: Text("写真タブで「うちの子」を登録すると、ここで情報をまとめられます。")
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

/// How many of the main items are still empty, for the Tools tab badge.
enum CatCareCompleteness {
    static func missingCount(_ record: CatCareRecord?) -> Int {
        guard let record else { return 6 }
        var missing = 0
        if record.sex == nil || record.sex?.value == .unknown { missing += 1 }
        if (record.marks?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing += 1 }
        if (record.microchip?.value ?? "").isEmpty { missing += 1 }
        if record.allergy == nil || record.allergy?.value.status == .unknown { missing += 1 }
        if record.activeWeights.isEmpty { missing += 1 }
        if record.activeVaccinations.isEmpty { missing += 1 }
        return missing
    }
}

struct CatCareDetailView: View {
    let profile: CatProfilePresentation
    let otherProfiles: [CatProfilePresentation]
    @Binding var selectedProfileID: String?
    @ObservedObject private var store = CatCareStore.shared

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
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
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
            Text("この画面を閉じて開き直し、もう一度入れてください。")
        }
        .sheet(item: $editing) { editor in
            CatCareListEntrySheet(editor: editor) { result in
                apply(result)
            }
        }
        .task(id: profile.identifier) {
            // Save the cat shown before; the draft still belongs to it here.
            autosave?.cancel()
            save()
            load()
        }
    }

    // MARK: Sections

    private var basicsSection: some View {
        Section("基本") {
            LabeledContent("名前", value: profile.displayName)
            if let birthday = currentRecord?.birthday?.value ?? nil {
                LabeledContent("誕生日", value: CatCareFormat.day(birthday)
                    + (CatCareLostCat.age(birthday, today: CatCareDay(date: Date())).map { "（\($0)）" } ?? ""))
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
            Text("家の情報（ほかの猫と共通）")
        } footer: {
            Text("1回入れると、ほかの猫にも同じ内容が入ります。")
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
        guard let profileID = UUID(uuidString: profile.identifier),
              let record = store.ensureRecord(profileID: profileID, name: profile.name)
        else { catID = nil; return }
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
        if saved { savedDraft = draft } else { saveFailed = true }
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

    enum Result {
        case weight(grams: Int, day: CatCareDay)
        case medication(name: String, dose: String, schedule: String)
        case vaccination(kind: String, day: CatCareDay, proof: CatCarePhotoRef?)
        case meal(time: String, food: String, amount: String)
        case delete(kind: Kind, entryID: UUID)

        func apply(to r: inout CatCareRecord, by: String, now: Date) {
            switch self {
            case let .weight(grams, day):
                guard r.weights.count < CatCareLimits.maximumWeights else { return }
                r.weights.append(.init(measuredOn: day, grams: grams, editedAt: now, editedBy: by))
            case let .medication(name, dose, schedule):
                guard r.medications.count < CatCareLimits.maximumMedications else { return }
                r.medications.append(.init(name: CatCareLimits.clippedText(name), dose: CatCareLimits.clippedText(dose),
                                           schedule: CatCareLimits.clippedText(schedule), editedAt: now, editedBy: by))
            case let .vaccination(kind, day, proof):
                guard r.vaccinations.count < CatCareLimits.maximumVaccinations else { return }
                r.vaccinations.append(.init(kind: CatCareLimits.clippedText(kind), givenOn: day, proof: proof,
                                            editedAt: now, editedBy: by))
            case let .meal(time, food, amount):
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

    /// Every record is a button that asks before deleting, so a swipe is never the only way.
    private func row<Content: View>(_ id: UUID, @ViewBuilder _ content: () -> Content) -> some View {
        Button { pendingDelete = id } label: {
            content().frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("押すと削除できます")
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
    let editor: CatCareListEditor
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
                    TextField("体重（g）例：4200", text: $gramsText).keyboardType(.numberPad)
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
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
            }
            .navigationTitle(CatCareFormat.title(editor.kind) + "を追加")
            .announcesWhenShown(message)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("追加") { save() } }
            }
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

    private func save() {
        guard let day = CatCareDay(date: date) else { return }
        switch editor.kind {
        case .weight:
            guard let grams = Int(gramsText.filter(\.isNumber)),
                  let today = CatCareDay(date: Date()),
                  CatCareLimits.isValidWeight(grams: grams, on: day, today: today)
            else { message = "体重は1〜30000gの数字で入れてください。"; return }
            onSave(.weight(grams: grams, day: day))
        case .medication:
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { message = "薬の名前を入れてください。"; return }
            onSave(.medication(name: name, dose: dose, schedule: schedule))
        case .vaccination:
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { message = "種類を入れてください。"; return }
            onSave(.vaccination(kind: name, day: day, proof: proof))
        case .meal:
            onSave(.meal(time: name, food: food, amount: amount))
        }
        dismiss()
    }
}

/// ② of every tool: what 「この子のこと」 fills in, read only, and one way to
/// change it there. Tools never write these values themselves.
struct ToolCatCareSection<Extra: View>: View {
    let title: String
    let lines: [(String, String)]
    let profile: CatProfilePresentation?
    let footer: String?
    let identifier: String
    let editIdentifier: String
    let extra: () -> Extra

    init(title: String, lines: [(String, String)], profile: CatProfilePresentation?, footer: String? = nil,
         identifier: String, editIdentifier: String, @ViewBuilder extra: @escaping () -> Extra) {
        self.title = title; self.lines = lines; self.profile = profile; self.footer = footer
        self.identifier = identifier; self.editIdentifier = editIdentifier; self.extra = extra
    }

    var body: some View {
        Section {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 4) {
                    Text(line.0).font(.subheadline).foregroundStyle(.secondary)
                    Text(line.1).font(.body).textSelection(.enabled)
                }
            }
            .accessibilityIdentifier(identifier)
            if lines.isEmpty {
                Text("「この子のこと」に書くと、ここに載ります。").foregroundStyle(.secondary)
            }
            extra()
            if let profile {
                NavigationLink("この子のことを直す") { CatCareEntryView(profiles: [profile]) }
                    .accessibilityIdentifier(editIdentifier)
            }
        } header: { Text(title) }
          footer: { if let footer { Text(footer) } }
    }
}

extension ToolCatCareSection where Extra == EmptyView {
    init(title: String, lines: [(String, String)], profile: CatProfilePresentation?, footer: String? = nil,
         identifier: String, editIdentifier: String) {
        self.init(title: title, lines: lines, profile: profile, footer: footer,
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
        fields.append(("性別", sex + "・" + neutered))
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
