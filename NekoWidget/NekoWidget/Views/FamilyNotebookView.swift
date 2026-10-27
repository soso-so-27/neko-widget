import SwiftUI

/// Test builds only: the family notebook, working on this iPhone alone.
/// It copies 「この子のこと」 once (the original stays as it is) into
/// Codex's local model, and shows per item who wrote it, when, and whether
/// it has reached the family. Nothing is sent: there is no server yet, so
/// "the family" can be tried with the test buttons at the bottom.
@MainActor
final class FamilyNotebookPrototype: ObservableObject {
    static let shared = FamilyNotebookPrototype()

    private static let familyKey = "debug.familyNotebook.familyID.v1"
    private static let deviceKey = "debug.familyNotebook.deviceID.v1"
    private static let seenKey = "debug.familyNotebook.seenClock.v1"

    @Published private(set) var snapshot: FamilyNotebookSnapshot?
    @Published var message: String?

    private var store: FamilyNotebookStore?

    static let me = FamilyNotebookAuthor(personID: "this-iphone", displayName: "あなた")
    /// The other person in the test buttons. Not a real member.
    static let tryout = FamilyNotebookAuthor(personID: "tryout-family", displayName: "家族（試し）")
    private static let tryoutDevice = "tryout-device"

    var hasFamily: Bool { snapshot != nil }

    private init() {
        guard let id = UserDefaults.standard.string(forKey: Self.familyKey).flatMap(UUID.init(uuidString:)) else { return }
        open(id)
    }

    private static var root: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FamilyNotebookPrototype", isDirectory: true)
    }

    private static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: deviceKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }

    private func open(_ familyID: UUID) {
        guard let root = Self.root else { return }
        do {
            store = try FamilyNotebookStore(directory: root.appendingPathComponent(familyID.uuidString.lowercased(), isDirectory: true),
                                            familyID: familyID, deviceID: Self.deviceID)
            reload()
        } catch {
            store = nil; snapshot = nil
            message = "家族の手帳を読み込めませんでした。記録は消していません。"
        }
    }

    private func reload() {
        do { snapshot = try store?.snapshot() }
        catch { message = "家族の手帳を読み込めませんでした。記録は消していません。" }
    }

    // MARK: Making the family

    /// Makes the family and copies 「この子のこと」 into it. The source file
    /// is only read; a cat is linked by its tool ID and profile, never by name.
    func create() {
        let familyID = UUID()
        open(familyID)
        guard let store else { return }
        do {
            let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("CatCare", isDirectory: true).appendingPathComponent("state.json")
            var data: Data?
            if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                data = try Data(contentsOf: fileURL)
            }
            let source = try FamilyNotebookMigrationSource.decode(catCareData: data)
            let mappings = (source.catCare?.cats ?? []).map { cat in
                FamilyNotebookLocalMapping(sourceKey: "cat:" + cat.catID.uuidString.lowercased(), familyCatID: UUID(),
                                           profileID: cat.profileID, toolCatID: cat.catID)
            }
            let prepared = try FamilyNotebookMigration.prepare(source: source, familyID: familyID, mappings: mappings)
            try store.applyImport(prepared.plan, author: Self.me)
            UserDefaults.standard.set(familyID.uuidString, forKey: Self.familyKey)
            markSeen()
            reload()
        } catch {
            discard(familyID)
            message = "「この子のこと」を写せませんでした。元の記録はそのままです。"
        }
    }

    /// Test builds only: forget the tried family. 「この子のこと」 is not touched.
    func remove() {
        guard let familyID = snapshot?.familyID else { return }
        discard(familyID)
    }

    private func discard(_ familyID: UUID) {
        store = nil; snapshot = nil
        UserDefaults.standard.removeObject(forKey: Self.familyKey)
        UserDefaults.standard.removeObject(forKey: Self.seenKey)
        if let directory = Self.root?.appendingPathComponent(familyID.uuidString.lowercased(), isDirectory: true) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Reading

    struct Cat: Identifiable {
        let id: UUID
        let name: String
        let latest: FamilyNotebookOperation?
        let hasConflict: Bool
    }

    var cats: [Cat] {
        guard let snapshot else { return [] }
        let ids = snapshot.operations.filter { $0.target.collection == .cat }.map(\.target.familyCatID)
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }.compactMap { id -> Cat? in
            if snapshot.fieldState(for: .init(familyCatID: id, field: nil))?.isDeleted == true { return nil }
            let name: String
            if case let .text(text)? = state(id, .name)?.operation.value, !text.isEmpty { name = text } else { name = "名前なし" }
            let latest = snapshot.operations.filter { $0.target.familyCatID == id }.max { $0.version < $1.version }
            let conflict = FamilyNotebookCatView.allFields.contains { state(id, $0)?.status == .conflict }
            return Cat(id: id, name: name, latest: latest, hasConflict: conflict)
        }
    }

    func state(_ cat: UUID, _ field: FamilyNotebookField) -> FamilyNotebookFieldState? {
        snapshot?.fieldState(for: .init(familyCatID: cat, field: field))
    }

    func count(_ cat: UUID, _ collection: FamilyNotebookCollection) -> Int {
        guard let snapshot else { return 0 }
        let records = Set(snapshot.operations.filter { $0.target.familyCatID == cat && $0.target.collection == collection }
            .compactMap(\.target.recordID))
        return records.filter { id in
            snapshot.fieldState(for: .init(familyCatID: cat, collection: collection, recordID: id, field: nil))?.isDeleted != true
        }.count
    }

    /// The people who have written in this notebook, you first.
    var writers: [String] {
        var names = [Self.me.displayName]
        for operation in snapshot?.operations ?? [] where !names.contains(operation.author.displayName) {
            names.append(operation.author.displayName)
        }
        return names
    }

    /// Someone else wrote after you last looked: a small dot on the tools tab.
    var hasNewFromFamily: Bool {
        let seen = UInt64(UserDefaults.standard.integer(forKey: Self.seenKey))
        return snapshot?.operations.contains { $0.author != Self.me && $0.version.clock > seen } ?? false
    }

    func markSeen() {
        guard let clock = snapshot?.clock else { return }
        UserDefaults.standard.set(Int(clock), forKey: Self.seenKey)
        objectWillChange.send()
    }

    // MARK: Writing

    func write(_ cat: UUID, _ field: FamilyNotebookField, _ value: FamilyNotebookValue) {
        do {
            try store?.edit(target: .init(familyCatID: cat, field: field), value: value, author: Self.me)
            reload()
        } catch {
            message = "書けませんでした。もう一度お試しください。"
        }
    }

    // MARK: Test buttons: what the family's writing will look like

    /// Another iPhone in the family writes to one item; it arrives as shared.
    func tryFamilyWrite() {
        guard let cat = cats.first?.id else { message = "猫がいないので試せません。"; return }
        let target = FamilyNotebookTarget(familyCatID: cat, field: .temperament)
        let observed = snapshot?.operations.filter { $0.target == target }.map(\.id) ?? []
        arrive(target: target, value: .text("抱っこは短めに。夜はよく鳴きます"), observing: observed)
    }

    /// Two people change the same item at once (each without seeing the other).
    func tryConflict() {
        guard let cat = cats.first?.id else { message = "猫がいないので試せません。"; return }
        let target = FamilyNotebookTarget(familyCatID: cat, field: .litter)
        // The other person saw everything up to now, but not what you write next.
        let before = snapshot?.operations.filter { $0.target == target }.map(\.id) ?? []
        write(cat, .litter, .text("砂は週に 1 回、全部かえる"))
        arrive(target: target, value: .text("砂は 2 週に 1 回、全部かえる"), observing: before)
    }

    private func arrive(target: FamilyNotebookTarget, value: FamilyNotebookValue, observing: [UUID]) {
        guard let store, let snapshot else { return }
        let operation = FamilyNotebookOperation(
            familyID: snapshot.familyID, target: target, value: value,
            version: .init(clock: snapshot.clock + 1, deviceID: Self.tryoutDevice, operationID: UUID()),
            author: Self.tryout, editedAt: Date(), observedOperationIDs: observing)
        do {
            try store.receive([operation])
            try store.acknowledge(.init(familyID: snapshot.familyID, operationID: operation.id, version: operation.version))
            reload()
        } catch {
            message = "試しの書き込みを入れられませんでした。"
        }
    }
}

// MARK: - The notebook

struct FamilyNotebookView: View {
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsRemove = false

    var body: some View {
        NavigationStack {
            Group {
                if model.hasFamily { notebook } else { FamilyNotebookIntroView(create: { model.create() }) }
            }
            .navigationTitle("家族の手帳")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .alert("家族の手帳", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.message ?? "") }
        }
        .onAppear { model.markSeen() }
        .onDisappear { model.markSeen() }
    }

    private var notebook: some View {
        List {
            Section {
                ForEach(model.writers, id: \.self) { name in
                    HStack {
                        Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
                        Text(name)
                        Spacer()
                        if name == FamilyNotebookPrototype.me.displayName {
                            Text("支払う人").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button {} label: { Label("家族を招待する", systemImage: "person.badge.plus") }
                    .disabled(true)
            } header: {
                Text("家族")
            } footer: {
                Text("招待された人はずっと無料。だれでも、どの項目でも書けます。家族とつなぐのは次の段階で、いまはこのiPhoneの中だけです。")
            }
            Section("猫") {
                ForEach(model.cats) { cat in
                    NavigationLink {
                        FamilyNotebookCatView(catID: cat.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(cat.name).font(.headline)
                                if cat.hasConflict {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                        .accessibilityLabel("見てほしい項目があります")
                                }
                            }
                            if let latest = cat.latest {
                                Text(FamilyNotebookFieldRow.byline(latest)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if model.cats.isEmpty {
                    Text("「この子のこと」に猫がいません。猫のプロフィールから入れると、ここに並びます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("家族が書いたときを試す") { model.tryFamilyWrite() }
                Button("2 人が同時に直したときを試す") { model.tryConflict() }
                Button("試した家族を消す", role: .destructive) { confirmsRemove = true }
            } header: {
                Text("テスト用")
            } footer: {
                Text("「家族（試し）」は本物の家族ではありません。消しても「この子のこと」はそのままです。")
            }
        }
        .confirmationDialog("試した家族を消しますか？", isPresented: $confirmsRemove, titleVisibility: .visible) {
            Button("消す", role: .destructive) { model.remove() }
        } message: {
            Text("家族の手帳に写した内容が消えます。「この子のこと」は消えません。")
        }
    }
}

/// What the family notebook is, and the button that makes one.
struct FamilyNotebookIntroView: View {
    var create: (@MainActor () -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("一緒にお世話する人（家族・同居の人）と、この子のことを同じ手帳に書けます。")
                    .font(.body)
                VStack(alignment: .leading, spacing: 14) {
                    point("syringe", "だれかが書いたワクチンの日を、ほかの家族も見られる")
                    point("house", "預けるとき、実家の親が自分の iPhone で食事の量を確かめられる")
                    point("clock.arrow.circlepath", "どの項目も、だれがいつ書いたかが残る")
                    point("lock", "健康や家の情報は、iPhone の中で暗号にしてから送る")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("一緒に書けるもの").font(.subheadline.weight(.semibold))
                    Text("この子のこと（基本・健康・暮らし）、病院で見せる、預けるとき。迷子のチラシも、いつも最新の内容で作れます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("家族の外の人には").font(.subheadline.weight(.semibold))
                    Text("ペットシッターや病院には、道具ごとに PDF や画像で渡せます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("料金").font(.subheadline.weight(.semibold))
                    Text("家族を作る人は Plus。招待された人はずっと無料です。Plus をやめても、書いたことはみんなの iPhone に残ります。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button { create?() } label: {
                    Text("家族を作る").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(create == nil)
                Text("テスト用の版の試作です。このiPhoneの中だけで動き、何も送りません。いまの「この子のこと」を写して始めます（元の記録はそのまま）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func point(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 22)
            Text(text).font(.subheadline)
        }
    }
}

// MARK: - One cat

struct FamilyNotebookCatView: View {
    let catID: UUID
    @ObservedObject private var model = FamilyNotebookPrototype.shared

    static let basics: [FamilyNotebookField] = [.name, .sex, .neutered, .indoorOnly, .birthday, .coat, .marks, .microchip]
    static let health: [FamilyNotebookField] = [.conditions, .allergyStatus, .allergyText]
    static let living: [FamilyNotebookField] = [.specialDiet, .water, .litter, .temperament]
    static let vet: [FamilyNotebookField] = [.vetName, .vetPhone, .vetNote]
    static var allFields: [FamilyNotebookField] { basics + health + living + vet }

    var body: some View {
        List {
            section("基本", Self.basics)
            Section("健康") {
                rows(Self.health)
                LabeledContent("体重", value: "\(model.count(catID, .weight))件")
                LabeledContent("飲んでいる薬", value: "\(model.count(catID, .medication))件")
                LabeledContent("ワクチン", value: "\(model.count(catID, .vaccination))件")
            }
            Section("暮らし") {
                LabeledContent("ごはん", value: "\(model.count(catID, .meal))回")
                rows(Self.living)
            }
            section("かかりつけ", Self.vet)
        }
        .navigationTitle(model.cats.first { $0.id == catID }?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, _ fields: [FamilyNotebookField]) -> some View {
        Section(title) { rows(fields) }
    }

    private func rows(_ fields: [FamilyNotebookField]) -> some View {
        ForEach(fields, id: \.self) { field in
            FamilyNotebookFieldRow(catID: catID, field: field)
        }
    }
}

/// One item: its value, who wrote it and when, and whether the family has it.
struct FamilyNotebookFieldRow: View {
    let catID: UUID
    let field: FamilyNotebookField
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @State private var editing = false

    var body: some View {
        let state = model.state(catID, field)
        Button { editing = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.label(field)).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(Self.text(state?.operation.value, field) ?? "未記入")
                        .foregroundStyle(Self.text(state?.operation.value, field) == nil ? .tertiary : .primary)
                        .multilineTextAlignment(.trailing)
                }
                if let state {
                    HStack(spacing: 6) {
                        Text(Self.byline(state.operation))
                        Spacer(minLength: 8)
                        Label(Self.statusText(state.status), systemImage: Self.statusSymbol(state.status))
                            .foregroundStyle(state.status == .conflict ? Color.orange : Color.secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .sheet(isPresented: $editing) {
            FamilyNotebookFieldEditor(catID: catID, field: field)
        }
    }

    static func byline(_ operation: FamilyNotebookOperation) -> String {
        let date = (operation.importedSourceEditedAt ?? operation.editedAt)
            .formatted(.dateTime.month(.defaultDigits).day())
        return "\(operation.author.displayName)が \(date) に書きました"
    }

    static func statusText(_ status: FamilyNotebookStatus) -> String {
        switch status {
        case .localSaved: "このiPhoneだけ"
        case .pendingShared: "家族にまだ届いていない"
        case .shared: "家族と同じ"
        case .conflict: "同時に直されました"
        }
    }

    static func statusSymbol(_ status: FamilyNotebookStatus) -> String {
        switch status {
        case .localSaved: "iphone"
        case .pendingShared: "arrow.up.circle"
        case .shared: "checkmark.circle"
        case .conflict: "exclamationmark.triangle.fill"
        }
    }

    static func label(_ field: FamilyNotebookField) -> String {
        switch field {
        case .name: "名前"
        case .sex: "性別"
        case .neutered: "去勢・避妊"
        case .indoorOnly: "室内飼い"
        case .birthday: "誕生日"
        case .coat: "毛色・柄"
        case .marks: "見分ける特徴"
        case .microchip: "マイクロチップ"
        case .conditions: "持病"
        case .allergyStatus: "アレルギー"
        case .allergyText: "アレルギーの内容"
        case .specialDiet: "療法食など"
        case .water: "水"
        case .litter: "トイレ"
        case .temperament: "接し方・苦手なこと"
        case .vetName: "病院の名前"
        case .vetPhone: "病院の電話"
        case .vetNote: "病院のメモ"
        default: field.rawValue
        }
    }

    /// Choices for the items that are picked, not typed: (stored value, shown).
    static func choices(_ field: FamilyNotebookField) -> [(String, String)]? {
        switch field {
        case .sex: [(CatCareSex.unknown.rawValue, "未記入"), (CatCareSex.male.rawValue, "オス"), (CatCareSex.female.rawValue, "メス")]
        case .neutered: [(CatCareTriState.unknown.rawValue, "未記入"), (CatCareTriState.yes.rawValue, "済み"), (CatCareTriState.no.rawValue, "まだ")]
        case .indoorOnly: [(CatCareTriState.unknown.rawValue, "未記入"), (CatCareTriState.yes.rawValue, "室内だけ"), (CatCareTriState.no.rawValue, "外にも出る")]
        case .allergyStatus: [(CatCareAllergy.Status.unknown.rawValue, "未確認"), (CatCareAllergy.Status.none.rawValue, "なし"),
                              (CatCareAllergy.Status.recorded.rawValue, "あり")]
        default: nil
        }
    }

    /// What a value reads as, or nil when nothing is written.
    static func text(_ value: FamilyNotebookValue?, _ field: FamilyNotebookField) -> String? {
        switch value {
        case let .text(text)?:
            if let choices = choices(field) {
                guard let shown = choices.first(where: { $0.0 == text }), shown.0 != choices[0].0 else { return nil }
                return shown.1
            }
            return text.isEmpty ? nil : text
        case let .day(day)?:
            let parts = day.split(separator: "-").compactMap { Int($0) }
            return parts.count == 3 ? "\(parts[0])年\(parts[1])月\(parts[2])日" : day
        case let .integer(number)?: return "\(number)"
        default: return nil
        }
    }
}

/// Writing one item. When two people changed it at once, both are shown
/// and one is kept; the other stays in the item's history.
struct FamilyNotebookFieldEditor: View {
    let catID: UUID
    let field: FamilyNotebookField
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var day = Date()
    @State private var hasDay = false

    var body: some View {
        let state = model.state(catID, field)
        NavigationStack {
            Form {
                if state?.status == .conflict, let state {
                    Section {
                        ForEach([state.operation] + state.history.filter(\.isConcurrentConflict).map(\.operation)) { operation in
                            Button {
                                if let value = operation.value { model.write(catID, field, value) }
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(FamilyNotebookFieldRow.text(operation.value, field) ?? "未記入").foregroundStyle(.primary)
                                    Text(FamilyNotebookFieldRow.byline(operation)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("2 人が同時に直しました")
                    } footer: {
                        Text("残すほうを選んでください。いまは新しいほうを表示しています。")
                    }
                }
                Section {
                    if let choices = FamilyNotebookFieldRow.choices(field) {
                        Picker(FamilyNotebookFieldRow.label(field), selection: $text) {
                            ForEach(choices.indices, id: \.self) { index in
                                Text(choices[index].1).tag(choices[index].0)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } else if field == .birthday {
                        Toggle("誕生日を書く", isOn: $hasDay)
                        if hasDay {
                            DatePicker("誕生日", selection: $day, in: ...Date(), displayedComponents: .date)
                                .datePickerStyle(.graphical)
                        }
                    } else {
                        TextField(FamilyNotebookFieldRow.label(field), text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .keyboardType(field == .microchip ? .numberPad : field == .vetPhone ? .phonePad : .default)
                    }
                } footer: {
                    if field == .microchip, CatCareLimits.normalizedMicrochip(text) == nil {
                        Text("15桁の数字で入れると保存します。").foregroundStyle(.orange)
                    } else if let state {
                        Text(FamilyNotebookFieldRow.byline(state.operation))
                    }
                }
            }
            .navigationTitle(FamilyNotebookFieldRow.label(field))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("書く") { save(); dismiss() }
                        .disabled(field == .microchip && CatCareLimits.normalizedMicrochip(text) == nil)
                }
            }
            .onAppear { fill(state?.operation.value) }
        }
    }

    private func fill(_ value: FamilyNotebookValue?) {
        switch value {
        case let .text(value)?: text = value
        case let .day(value)?:
            let parts = value.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) {
                day = date; hasDay = true
            }
        default:
            text = FamilyNotebookFieldRow.choices(field)?.first?.0 ?? ""
        }
    }

    private func save() {
        let value: FamilyNotebookValue
        if field == .birthday {
            guard hasDay else { model.write(catID, field, .clear); return }
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
            value = .day(String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
        } else if field == .microchip {
            guard let digits = CatCareLimits.normalizedMicrochip(text) else { return }
            value = digits.isEmpty ? .clear : .text(digits)
        } else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            value = trimmed.isEmpty ? .clear : .text(trimmed)
        }
        guard value != model.state(catID, field)?.operation.value else { return }
        model.write(catID, field, value)
    }
}
