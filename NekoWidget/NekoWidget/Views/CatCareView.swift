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
            if selectedProfileID == nil {
                selectedProfileID = profiles.first { $0.identifier == lastProfileID }?.identifier
                    ?? profiles.first?.identifier
            }
        }
        .onChange(of: selectedProfileID) { _, value in
            if let value { lastProfileID = value }
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

    @State private var draft = CatCareDraft()
    @State private var catID: UUID?
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
                Text("この情報はこのiPhoneの中にだけ保存します。開発者には送りません。ツールで書き出したときだけ、渡した相手に届きます。医療の判断はしません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!store.canSave || catID == nil)
                    .accessibilityIdentifier("cat-care-save")
            }
        }
        .alert("保存できませんでした", isPresented: $saveFailed) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text("ほかの画面で同時に変更された可能性があります。もう一度開き直してください。")
        }
        .sheet(item: $editing) { editor in
            CatCareListEntrySheet(editor: editor) { result in
                apply(result)
            }
        }
        .task(id: profile.identifier) { load() }
    }

    // MARK: Sections

    private var basicsSection: some View {
        Section("基本") {
            LabeledContent("名前", value: profile.displayName)
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
                    Text("15桁の数字で入れてください。").font(.caption).foregroundStyle(.orange)
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
            TextField("療法食・別々に与えるなど（多頭のとき大事）", text: $draft.specialDiet, axis: .vertical)
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
        microchipInvalid = false
    }

    private func save() {
        guard let catID else { return }
        guard let chip = CatCareLimits.normalizedMicrochip(draft.microchip) else {
            microchipInvalid = true
            return
        }
        microchipInvalid = false
        draft.microchip = chip
        let saved = store.update { state in
            guard let index = state.cats.firstIndex(where: { $0.catID == catID }) else { return }
            draft.write(to: &state.cats[index], household: &state.household,
                        by: state.deviceID, now: Date())
        }
        if !saved { saveFailed = true }
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

    private var record: CatCareRecord? { catID.flatMap { store.state?.record(catID: $0) } }

    var body: some View {
        List {
            switch kind {
            case .weight:
                ForEach(record?.activeWeights ?? []) { entry in
                    LabeledContent(CatCareFormat.day(entry.measuredOn), value: CatCareFormat.weight(entry.grams))
                        .swipeActions { deleteButton(entry.id) }
                }
            case .medication:
                ForEach(record?.activeMedications ?? []) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.body.weight(.semibold))
                        Text([entry.dose, entry.schedule].filter { !$0.isEmpty }.joined(separator: "・"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { deleteButton(entry.id) }
                }
            case .vaccination:
                ForEach(record?.activeVaccinations ?? []) { entry in
                    HStack {
                        LabeledContent(entry.kind, value: CatCareFormat.day(entry.givenOn))
                        if entry.proof != nil {
                            Image(systemName: "doc.text.image").foregroundStyle(.secondary)
                                .accessibilityLabel("証明の写真あり")
                        }
                    }
                    .swipeActions { deleteButton(entry.id) }
                }
            case .meal:
                ForEach(record?.activeMeals ?? []) { entry in
                    LabeledContent(entry.time.isEmpty ? "時間未記入" : entry.time,
                                   value: [entry.food, entry.amount].filter { !$0.isEmpty }.joined(separator: " "))
                        .swipeActions { deleteButton(entry.id) }
                }
            }
        }
        .overlay {
            if isEmpty {
                ContentUnavailableView("まだ記録がありません", systemImage: "square.and.pencil")
            }
        }
        .navigationTitle(CatCareFormat.title(kind))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("追加", systemImage: "plus") { editing = CatCareListEditor(kind: kind) }
                    .disabled(!store.canSave)
                    .accessibilityIdentifier("cat-care-add-\(kind.rawValue)")
            }
        }
    }

    private var isEmpty: Bool {
        switch kind {
        case .weight: record?.activeWeights.isEmpty ?? true
        case .medication: record?.activeMedications.isEmpty ?? true
        case .vaccination: record?.activeVaccinations.isEmpty ?? true
        case .meal: record?.activeMeals.isEmpty ?? true
        }
    }

    private func deleteButton(_ id: UUID) -> some View {
        Button("削除", role: .destructive) {
            guard let catID else { return }
            store.update { state in
                guard let index = state.cats.firstIndex(where: { $0.catID == catID }) else { return }
                CatCareListEditor.Result.delete(kind: kind, entryID: id)
                    .apply(to: &state.cats[index], by: state.deviceID, now: Date())
            }
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("追加") { save() } }
            }
            .onChange(of: proofItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let jpeg = CatCareFormat.cleanJPEG(data) {
                        proof = store.savePhoto(jpeg, sourceAssetID: item.itemIdentifier, origin: .photos)
                    } else {
                        message = "写真を読み込めませんでした。"
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
