import SwiftUI
import UIKit

/// Only saved identity and its name are reused. Never infer identity from a
/// name, or carry health, care, contact or incident information into a visit.
@MainActor
enum SavedToolCatChoices {
    struct Choice {
        let id: UUID
        let name: String
        let source: String
        var cat: PhotoMemoryNoteCat { .init(id: id, name: name) }
    }

    static func cats(care: CareHandoffStore, evacuation: EvacuationStore) -> [Choice] {
        func identity(_ profile: String?, _ tool: UUID?, _ legacy: UUID) -> UUID? {
            if let profile { return UUID(uuidString: profile) }
            return tool ?? legacy
        }
        let careCats = care.loadError == nil && care.saveError == nil ? care.plan.cats : []
        let evacuationCats = evacuation.loadError == nil && evacuation.saveError == nil ? evacuation.plan.cats : []
        let careGroups = Dictionary(grouping: careCats.compactMap { cat in
            identity(cat.profileID, cat.toolCatID, cat.id).map { ($0, cat.displayName) }
        }, by: { $0.0 })
        let evacuationGroups = Dictionary(grouping: evacuationCats.compactMap { cat in
            identity(cat.profileID, cat.toolCatID, cat.id).map { ($0, cat.displayName) }
        }, by: { $0.0 })
        return Set(careGroups.keys).union(evacuationGroups.keys).compactMap { id -> Choice? in
            let a = careGroups[id] ?? [], b = evacuationGroups[id] ?? []
            // Duplicate identity within a tool is ambiguous, even if names agree.
            guard a.count <= 1, b.count <= 1 else { return nil }
            let sources = [a.isEmpty ? nil : "預けるとき", b.isEmpty ? nil : "避難に備える"].compactMap { $0 }
            return Choice(id: id, name: a.first?.1 ?? b.first!.1, source: sources.joined(separator: "・"))
        }.sorted {
            $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// Display only the closed, user-facing messages owned by these stores.
/// Arbitrary platform errors may contain file paths or private source details.
private func veterinaryErrorMessage(_ error: any Error) -> String {
    let message: String?
    if let known = error as? VeterinaryVisitError { message = known.errorDescription }
    else if let known = error as? PhotoMemoryNoteStoreError { message = known.errorDescription }
    else { message = nil }
    return message ?? "操作の結果を確認できませんでした。開き直して保存状況を確認してください。"
}

struct VeterinaryVisitsView: View {
    var profiles: [CatProfilePresentation] = []
    var photos: [PhotoPresentation]
    var noteStore: PhotoMemoryNoteStore = .shared
    var store: VeterinaryVisitStore = .shared
    var initialRecord: PhotoMemoryNoteRecord? = nil
    @ObservedObject var careStore: CareHandoffStore = .shared
    @ObservedObject var evacuationStore: EvacuationStore = .shared
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var visits: [VeterinaryVisit] = []
    @State private var cats: [PhotoMemoryNoteCat] = []
    @State private var toolSources: [UUID: String] = [:]
    @State private var selected: VeterinaryVisit?
    @State private var error: String?
    @State private var ready = false
    @State private var addsCat = false
    @State private var newName = ""
    @State private var cleanupPending = false
    @Environment(\.membershipActions) private var actionAccess
    @State private var membershipNotice: MembershipAccessDecision?

    var body: some View {
        List {
            if ready {
                Section {
                    ForEach(cats, id: \.id) { cat in
                        Button { Task { await open(cat) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(cat.name, systemImage: "cat")
                                    if let source = toolSources[cat.id] {
                                        Text(source).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let visit = visits.first(where: { $0.catID == cat.id && $0.completedAt == nil }), !visit.entries.isEmpty {
                                    Text("\(visit.entries.count)件").foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }.foregroundStyle(.primary).padding(.vertical, 6)
                        }.accessibilityIdentifier("vet-cat-\(cat.id.uuidString)")
                    }
                    Button("猫の名前を入力して作る", systemImage: "plus") { newName = ""; addsCat = true }
                        .accessibilityIdentifier("vet-new-cat")
                } header: { Text("診察する猫") }
                  footer: { Text("気になった写真やメモを選んで、診察で伝える内容をまとめます。診断は行いません。") }
                if !visits.filter({ $0.completedAt != nil }).isEmpty {
                    Section("これまでの診察メモ") {
                        ForEach(visits.filter { $0.completedAt != nil }.reversed()) { visit in
                            Button { selected = visit } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(visit.catName).foregroundStyle(.primary)
                                    Text(visit.completedAt!.formatted(.dateTime.year().month().day())).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else if error == nil { ProgressView() }
            if let error { Section { Text(error); Button("再試行") { Task { await reload() } } } }
            if cleanupPending { Section { Text("使わなくなった診察用写真の削除が完了していません。").font(.footnote); Button("削除を再試行") { Task { await reload() } } } }
        }
        .navigationTitle("病院で見せる").navigationBarTitleDisplayMode(.inline)
        .membershipActionNotice($membershipNotice)
        .task { await reload() }
        .alert("猫の名前", isPresented: $addsCat) {
            TextField("名前", text: $newName)
            Button("作る") { Task { await open(PhotoMemoryNoteCat(id: UUID(), name: newName.trimmingCharacters(in: .whitespacesAndNewlines))) } }
            Button("キャンセル", role: .cancel) {}
        }
        .sheet(item: $selected, onDismiss: { Task { await reload() } }) { visit in
            NavigationStack {
                VeterinaryConsultationView(initialVisit: visit, photos: photos, noteStore: noteStore,
                    store: store, initialRecord: initialRecord)
            }
            .environment(\.dynamicTypeSize, typeSize)
        }
    }
    private func open(_ cat: PhotoMemoryNoteCat) async {
        let access = actionAccess
        do {
            selected = try await store.current(catID: cat.id, catName: cat.name) { commit in
                try access.perform(for: .createVeterinaryVisit, commit)
            }
            error = nil
        }
        catch let denied as MembershipActionDenied { membershipNotice = denied.decision }
        catch { self.error = veterinaryErrorMessage(error) }
    }
    private func reload() async {
        do {
            let loaded = try await store.visits()
            let notes: [PhotoMemoryNoteRecord]
            var sourceError: String?
            do { notes = try await noteStore.records() }
            catch { notes = []; sourceError = "元のメモを読み込めません。保存済みの診察メモは開けます。" }
            var seen = Set<UUID>()
            let known = profiles.compactMap { profile in UUID(uuidString: profile.identifier).map { PhotoMemoryNoteCat(id: $0, name: profile.displayName) } }
            let savedTools = SavedToolCatChoices.cats(care: careStore, evacuation: evacuationStore)
            let measuredCats = notes.compactMap { record -> PhotoMemoryNoteCat? in
                guard let weight = record.note.weight, let id = weight.catID else { return nil }
                return PhotoMemoryNoteCat(id: id, name: weight.value.catName ?? "名前未設定の猫")
            }
            // Keep each append separately typed; a long chain of overloaded +
            // exceeded the native compiler's expression-checking budget.
            var candidates: [PhotoMemoryNoteCat] = known
            candidates.append(contentsOf: initialRecord?.note.context?.cats ?? [])
            candidates.append(contentsOf: notes.flatMap { $0.note.context?.cats ?? [] })
            candidates.append(contentsOf: loaded.map { PhotoMemoryNoteCat(id: $0.catID, name: $0.catName) })
            candidates.append(contentsOf: savedTools.map(\.cat))
            candidates.append(contentsOf: measuredCats)
            cats = candidates.filter { seen.insert($0.id).inserted }
            toolSources = Dictionary(uniqueKeysWithValues: savedTools.map { ($0.id, $0.source) })
            if careStore.loadError != nil || careStore.saveError != nil || evacuationStore.loadError != nil || evacuationStore.saveError != nil {
                let message = "入力済みの猫を一部読み込めません。既存の診察メモや、名前を入力して作る操作は使えます。"
                sourceError = sourceError.map { $0 + "\n" + message } ?? message
            }
            visits = loaded; ready = true; error = sourceError
            do { cleanupPending = try await store.cleanupPending() }
            catch { cleanupPending = true }
        } catch { self.error = veterinaryErrorMessage(error); ready = false }
    }
}

private struct VeterinaryConsultationView: View {
    let initialVisit: VeterinaryVisit
    let photos: [PhotoPresentation]
    let noteStore: PhotoMemoryNoteStore
    let store: VeterinaryVisitStore
    let initialRecord: PhotoMemoryNoteRecord?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var visit: VeterinaryVisit?
    @State private var observations = ""
    @State private var questions = ""
    @State private var hasStartedDay = false
    @State private var startedDay = Date()
    @State private var picking = false
    @State private var showing = false
    @State private var discarding = false
    @State private var finishing = false
    @State private var deletesVisit = false
    @State private var error: String?
    @State private var busy = false
    @State private var chosen: PhotoMemoryNoteRecord?
    @State private var pendingSource: PhotoMemoryNoteRecord?

    private var changes: Bool {
        guard let visit else { return false }
        return observations != visit.observations || questions != visit.questions
            || (hasStartedDay ? VeterinaryVisit.day(startedDay) : nil) != visit.startedOn
    }
    var body: some View {
        Form {
            if let visit {
                Section {
                    Label(visit.catName, systemImage: "cat").font(.title3.bold())
                    if visit.completedAt != nil { Text("診察済みの控え").font(.caption).foregroundStyle(.secondary) }
                }
                if visit.completedAt == nil {
                    Section {
                        TextField("家で気付いたこと", text: $observations, axis: .vertical).lineLimit(3...8)
                            .accessibilityIdentifier("vet-observations")
                        Toggle("いつからかを記録", isOn: $hasStartedDay)
                        if hasStartedDay { DatePicker("気付いた日", selection: $startedDay, displayedComponents: .date) }
                        TextField("先生に聞きたいこと", text: $questions, axis: .vertical).lineLimit(2...8)
                            .accessibilityIdentifier("vet-questions")
                    } header: { Text("今回伝えること") }
                      footer: { Text("それぞれ500文字まで。以前の薬やお世話情報は自動で入りません。") }
                } else {
                    Section("伝えたこと") {
                        if !visit.observations.isEmpty { Text(visit.observations) }
                        if let day = visit.startedOn { Text("気付いた日 \(day)") }
                        if !visit.questions.isEmpty { Text(visit.questions) }
                    }
                }
                Section {
                    ForEach(visit.orderedEntries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            VeterinaryEntryPhoto(entry: entry, visitID: visit.id, store: store)
                            if !entry.text.isEmpty { Text(entry.text) }
                            if let weight = entry.weight { PhotoMemoWeightLabel(weight: weight) }
                            VeterinaryEntryDates(entry: entry)
                            if visit.completedAt == nil {
                                Button("診察メモから外す", role: .destructive) { Task { await remove(entry) } }
                                    .accessibilityIdentifier("vet-remove-\(entry.id.uuidString)")
                            }
                        }.padding(.vertical, 6)
                    }
                    if visit.completedAt == nil {
                        Button("写真・メモを選ぶ", systemImage: "plus") { picking = true }
                            .accessibilityIdentifier("vet-pick-records")
                    }
                } header: { Text("見せる記録 · \(visit.entries.count)件") }
                  footer: { Text("選んだ時点の控えです。元のメモを編集しても自動では変わりません。外しても元の写真・メモは残ります。") }
                Section {
                    Button("この内容を見せる", systemImage: "rectangle.inset.filled") { showing = true }
                        .accessibilityIdentifier("vet-show").disabled(changes)
                    if visit.completedAt == nil {
                        Button("診察済みとして残す", systemImage: "checkmark") { finishing = true }.disabled(changes)
                    }
                    if changes { Text("変更を保存してから見せてください。").font(.caption).foregroundStyle(.secondary) }
                    Button("この診察メモを削除", role: .destructive) { deletesVisit = true }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.secondary).accessibilityIdentifier("vet-error") } }
        }
        .navigationTitle("診察メモ").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("閉じる") { if changes { discarding = true } else { dismiss() } }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } }
                .disabled(!changes || busy || observations.count > 500 || questions.count > 500)
                .accessibilityIdentifier("vet-save") }
        }
        .disabled(busy)
        .interactiveDismissDisabled(changes || busy)
        .task {
            guard visit == nil else { return }
            visit = initialVisit; observations = initialVisit.observations; questions = initialVisit.questions
            hasStartedDay = initialVisit.startedOn != nil
            if let day = initialVisit.startedOn {
                let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
                startedDay = formatter.date(from: day) ?? Date()
            }
            if initialVisit.completedAt == nil { chosen = initialRecord }
        }
        .sheet(isPresented: $picking, onDismiss: { chosen = pendingSource; pendingSource = nil }) {
            if let visit {
                VeterinaryRecordPicker(visit: visit, photos: photos, noteStore: noteStore) { pendingSource = $0; picking = false }
                    .environment(\.dynamicTypeSize, typeSize)
            }
        }
        .sheet(item: $chosen) { source in
            if let visit {
                VeterinaryRecordConfirmation(source: source, visit: visit, photos: photos, noteStore: noteStore, store: store) { updated in
                    self.visit = updated; chosen = nil
                }
                .environment(\.dynamicTypeSize, typeSize)
            }
        }
        .fullScreenCover(isPresented: $showing) {
            if let visit { VeterinaryReadView(visit: visit, store: store).environment(\.dynamicTypeSize, typeSize) }
        }
        .confirmationDialog("保存せずに閉じますか？", isPresented: $discarding, titleVisibility: .visible) {
            Button("変更を破棄", role: .destructive) { dismiss() }; Button("編集を続ける", role: .cancel) {}
        }
        .confirmationDialog("診察済みの控えとして残しますか？", isPresented: $finishing, titleVisibility: .visible) {
            Button("残す") { Task { await save(completing: true) } }; Button("キャンセル", role: .cancel) {}
        } message: { Text("次の診察は空のメモから作れます。この控えは自分だけの記録として残ります。") }
        .confirmationDialog("この診察メモを削除しますか？", isPresented: $deletesVisit, titleVisibility: .visible) {
            Button("削除", role: .destructive) { Task { await deleteVisit() } }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("この診察用の控えだけを削除します。元の写真・メモ・保管した記録は残ります。") }
    }
    private func save(completing: Bool = false) async {
        guard var draft = visit, !busy else { return }
        busy = true; defer { busy = false }
        draft.observations = observations; draft.questions = questions
        draft.startedOn = hasStartedDay ? VeterinaryVisit.day(startedDay) : nil
        if completing { draft.completedAt = Date() }
        do { visit = try await store.save(draft, expectedRevision: draft.revision); error = nil }
        catch { self.error = veterinaryErrorMessage(error) }
    }
    private func remove(_ entry: VeterinaryVisitEntry) async {
        guard let visit, !busy else { return }
        busy = true; defer { busy = false }
        do { self.visit = try await store.remove(entryID: entry.id, from: visit.id, expectedRevision: visit.revision); error = nil }
        catch { self.error = veterinaryErrorMessage(error) }
    }
    private func deleteVisit() async {
        guard let visit, !busy else { return }
        busy = true; defer { busy = false }
        do { try await store.delete(visitID: visit.id, expectedRevision: visit.revision); dismiss() }
        catch { self.error = veterinaryErrorMessage(error) }
    }
}

private struct VeterinaryRecordPicker: View {
    let visit: VeterinaryVisit
    let photos: [PhotoPresentation]
    let noteStore: PhotoMemoryNoteStore
    let choose: (PhotoMemoryNoteRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var records: [PhotoMemoryNoteRecord] = []
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(records) { record in
                        Button { choose(record) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.note.text.isEmpty ? "体重の記録" : record.note.text).lineLimit(3).foregroundStyle(.primary)
                                if let weight = record.note.weight { PhotoMemoWeightLabel(weight: weight.value) }
                                if let selected = visit.entries.first(where: { $0.sourceNoteID == record.id }) {
                                    Text(selected.sourceRevision == record.note.revision ? "追加済み" : "元のメモが変更されています · 内容を確認して更新")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }.accessibilityIdentifier("vet-source-\(record.id.uuidString)")
                    }
                    if records.isEmpty && error == nil { Text("写真に付けたメモはここから選べます。") }
                } header: { Text("\(visit.catName)に見せるメモを選ぶ") }
                Section("写真だけ選ぶ") {
                    ForEach(photos.filter { access.photo(for: $0.localIdentifier) != nil }) { photo in
                        Button {
                            let selected = visit.entries.first { $0.sourcePhotoIdentifier == photo.localIdentifier }
                            let note = PhotoMemoryNote(id: selected?.sourceNoteID ?? UUID(), text: "", updatedAt: Date(),
                                revision: UUID().uuidString, context: PhotoMemoryNoteContext(capturedAt: photo.creationDate, cats: []))
                            choose(PhotoMemoryNoteRecord(photoIdentifier: photo.localIdentifier, note: note))
                        } label: {
                            HStack(spacing: 12) {
                                PhotoAssetImageView(localIdentifier: photo.localIdentifier, catBoundingBox: nil,
                                    targetPixelSize: CGSize(width: 180, height: 180), showsFullImage: true)
                                    .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(photo.creationDate.map { "撮影 \(VeterinaryVisit.day($0))" } ?? "撮影日不明").foregroundStyle(.primary)
                            }
                        }
                    }
                }
                if let error { Text(error) }
            }
            .navigationTitle("メモを選ぶ").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .task {
                access.start(photos: photos)
                do {
                    // Known other-cat measurements are never offered. Unknown
                    // ownership requires confirmation, not a name match.
                    records = try await noteStore.records().filter {
                        $0.note.weight?.catID == nil || $0.note.weight?.catID == visit.catID
                    }
                } catch { self.error = veterinaryErrorMessage(error) }
            }
            .onDisappear { access.stop() }
        }
    }
}

private struct VeterinaryRecordConfirmation: View {
    let source: PhotoMemoryNoteRecord
    let visit: VeterinaryVisit
    let photos: [PhotoPresentation]
    let noteStore: PhotoMemoryNoteStore
    let store: VeterinaryVisitStore
    let saved: (VeterinaryVisit) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var confirmed = false
    @State private var busy = false
    @State private var error: String?
    private var wrongCat: Bool { source.note.weight?.catID.map { $0 != visit.catID } ?? false }
    private var photoOnly: Bool { source.note.text.isEmpty && source.note.weight == nil }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(visit.catName)の診察メモに追加").font(.headline)
                    if access.photo(for: source.photoIdentifier) != nil {
                        PhotoAssetImageView(localIdentifier: source.photoIdentifier, catBoundingBox: nil,
                            targetPixelSize: CGSize(width: 1000, height: 1000), showsFullImage: true)
                            .aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                    } else { Label("元の写真を開けません。文章と体重だけ追加します。", systemImage: "photo").font(.caption) }
                    if !source.note.text.isEmpty { Text(source.note.text) }
                    if let weight = source.note.weight { PhotoMemoWeightLabel(weight: weight.value) }
                    Toggle("この記録は\(visit.catName)のものです", isOn: $confirmed)
                        .accessibilityIdentifier("vet-confirm-target")
                    if wrongCat { Text("体重の測定対象が別の猫です。元のメモで対象を確認してください。") }
                    Button(visit.entries.contains { $0.sourceNoteID == source.id } ? "選んだ記録を更新" : "診察メモに追加") { Task { await add() } }
                        .disabled(!confirmed || wrongCat || busy).accessibilityIdentifier("vet-add-confirmed")
                    if busy { ProgressView("写真の控えを準備しています…") }
                } footer: { Text("選んだこの記録だけを追加します。まどへの共有や自動送信はしません。") }
                if let error { Text(error).accessibilityIdentifier("vet-add-error") }
            }
            .navigationTitle("内容を確認").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .task { access.start(photos: photos) }.onDisappear { access.stop() }
        }
    }
    private func add() async {
        guard confirmed, !busy else { return }
        busy = true; defer { busy = false }
        do {
            guard try await sourceIsCurrent() else { throw VeterinaryVisitError.changed }
            let identifier = source.photoIdentifier
            let hasPhoto = access.photo(for: identifier) != nil
            var fixtureBytes: Data?
#if DEBUG
            if hasPhoto, CommandLine.arguments.contains("--memory-library-fixture") {
                fixtureBytes = AppStoreScreenshotFixture.image(for: identifier)?.jpegData(compressionQuality: 0.85)
            }
#endif
            let bytes: Data?
            if let fixtureBytes { bytes = fixtureBytes }
            else {
                bytes = await Task.detached(priority: .userInitiated) { () -> Data? in
                    guard hasPhoto, !Task.isCancelled else { return nil }
                    return PhotoImageLoader().image(localIdentifier: identifier, targetSize: CGSize(width: 2048, height: 2048), contentMode: .aspectFit)?.jpegData(compressionQuality: 0.85)
                }.value
            }
            try Task.checkCancellation(); access.refresh()
            guard try await sourceIsCurrent(),
                  !hasPhoto || (bytes != nil && access.photo(for: identifier) != nil) else { throw VeterinaryVisitError.changed }
            guard !photoOnly || bytes != nil else { throw VeterinaryVisitError.changed }
            let updated = try await store.add(source: source, jpeg: bytes, to: visit.id,
                expectedRevision: visit.revision, confirmedTarget: confirmed,
                replace: visit.entries.contains { $0.sourceNoteID == source.id })
            saved(updated)
        } catch { self.error = veterinaryErrorMessage(error) }
    }
    private func sourceIsCurrent() async throws -> Bool {
        if photoOnly {
            // A photo-only choice does not claim to copy any current memo.
            return true
        }
        return try await noteStore.record(id: source.id) == source
    }
}

private struct VeterinaryEntryDates: View {
    let entry: VeterinaryVisitEntry
    var body: some View {
        Text("撮影日 \(entry.capturedAt.map(VeterinaryVisit.day) ?? "不明") · メモ日 \(entry.writtenAt.map(VeterinaryVisit.day) ?? "不明")")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct VeterinaryEntryPhoto: View {
    let entry: VeterinaryVisitEntry
    let visitID: UUID
    let store: VeterinaryVisitStore
    @State private var bytes: Data?
    @State private var failed = false
    var body: some View {
        Group {
            if let bytes { MemoArchivePhoto(data: bytes, allowsExpansion: true).frame(maxHeight: 260) }
            else if failed { Label("写真の控えを開けません", systemImage: "photo").font(.caption) }
            else if entry.photoFile != nil { ProgressView() }
        }.task(id: entry) {
            bytes = nil; failed = false
            do { bytes = try await store.image(for: entry, visitID: visitID); failed = false }
            catch { bytes = nil; failed = true }
        }
    }
}

private struct VeterinaryReadView: View {
    let visit: VeterinaryVisit
    let store: VeterinaryVisitStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(visit.catName).font(.largeTitle.bold())
                    if let day = visit.startedOn { Label("気付いた日 \(day)", systemImage: "calendar") }
                    if !visit.observations.isEmpty { VStack(alignment: .leading, spacing: 8) { Text("家で気付いたこと").font(.headline); Text(visit.observations) } }
                    if !visit.questions.isEmpty { VStack(alignment: .leading, spacing: 8) { Text("聞きたいこと").font(.headline); Text(visit.questions) } }
                    ForEach(visit.orderedEntries) { entry in
                        VStack(alignment: .leading, spacing: 12) {
                            VeterinaryEntryPhoto(entry: entry, visitID: visit.id, store: store)
                            if !entry.text.isEmpty { Text(entry.text) }
                            if let weight = entry.weight { PhotoMemoWeightLabel(weight: weight) }
                            VeterinaryEntryDates(entry: entry)
                        }
                        Divider()
                    }
                    if visit.entries.isEmpty && visit.observations.isEmpty && visit.questions.isEmpty { Text("まだ見せる内容がありません。写真やメモを選んでください。").foregroundStyle(.secondary) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("vet-reading")
            .navigationTitle("診察で見せる").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}
