import SwiftUI
import UIKit
import ImageIO
import CoreText

/// Only saved identity and its name are reused. Never infer identity from a
/// name. Health and care details come only from the owner's 「この子のこと」
/// for the same saved identity (shown and exported, never copied into the
/// visit record); contact and incident information never enter a visit.
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
    return message ?? "うまくいったか確かめられませんでした。開き直して、保存されているか見てください。"
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
    @AppStorage("vet.lastCat.v1") private var lastCatID = ""
    @AppStorage(CatFarewell.key) private var farewellJSON = ""
    @State private var visits: [VeterinaryVisit] = []
    @State private var cats: [PhotoMemoryNoteCat] = []
    @State private var toolSources: [UUID: String] = [:]
    /// The memo on the page: the chosen cat's current one.
    @State private var current: VeterinaryVisit?
    /// A past memo, opened over the page.
    @State private var selected: VeterinaryVisit?
    @State private var error: String?
    @State private var ready = false
    @State private var countedOpen = false
    @Environment(\.membershipActions) private var actionAccess

    /// The cats in the row: profiles, then cats known only from memos and tools.
    private var stripCats: [ToolStripCat] {
        let known = Set(profiles.map(\.identifier))
        return profiles.map { ToolStripCat(id: $0.identifier, name: $0.displayName, profile: $0,
                                           accessibilityIdentifier: "tool-profile-\($0.identifier)") }
            + cats.filter { !known.contains($0.id.uuidString) }
                .map { ToolStripCat(id: $0.id.uuidString, name: $0.name, profile: nil,
                                    accessibilityIdentifier: "vet-cat-\($0.id.uuidString)") }
    }

    var body: some View {
        Group {
            if !ready {
                List {
                    if error == nil { ProgressView() }
                    notices
                }
            } else if stripCats.isEmpty {
                // No cat yet: add one here.
                List {
                    ToolCatPicker(profiles: profiles, select: { profile in
                        guard let id = UUID(uuidString: profile.identifier) else { return }
                        lastCatID = profile.identifier
                        Task { await open(PhotoMemoryNoteCat(id: id, name: profile.displayName)) }
                    }) {}
                    notices
                }
            } else if let current {
                // The chosen cat's memo, with the row of cats above it to switch in place.
                VStack(spacing: 0) {
                    noticeBar
                    VeterinaryConsultationView(initialVisit: current, photos: photos, noteStore: noteStore,
                        store: store, initialRecord: initialRecord, profiles: profiles,
                        pastVisits: Array(visits.filter { $0.id != current.id && $0.catID == current.catID }.reversed()),
                        openPast: { selected = $0 },
                        onDeleted: {
                            let cat = PhotoMemoryNoteCat(id: current.catID, name: current.catName)
                            Task { await reload(); await open(cat) }
                        },
                        // A finished memo moves to これまでの診察メモ; a new empty
                        // one opens for next time (11/7: the page was stuck read-only).
                        onFinished: {
                            let cat = PhotoMemoryNoteCat(id: current.catID, name: current.catName)
                            Task { await reload(); await open(cat) }
                        })
                        .id(current.id)
                }
                .safeAreaInset(edge: .top, spacing: 0) { strip }
            } else {
                List { notices }
                    .safeAreaInset(edge: .top, spacing: 0) { strip }
            }
        }
        .navigationTitle("病院で見せる").navigationBarTitleDisplayMode(.inline)
        .familyNotebookToolSync()
        .onReceive(NotificationCenter.default.publisher(for: .appRecordsCommitted).receive(on: DispatchQueue.main)) { note in
            guard let url = note.object as? URL, url.path.contains("/VeterinaryVisits") else { return }
            Task { await reload() }
        }
        .task {
            // Usage (11/7): once per opening, not again after a pushed screen.
            if !countedOpen { countedOpen = true; UsageCounter.shared.count(.toolVetVisit) }
            await reload()
            // A cat whose farewell day is recorded is not opened by itself:
            // opening makes a new memo (11/7).
            let openable = stripCats.filter { !$0.isDeparted(farewellJSON) }
            guard current == nil,
                  let first = openable.first(where: { $0.id == lastCatID }) ?? openable.first else { return }
            await open(first)
        }
        // The first cat, added from 「猫を追加」, opens at once (11/7).
        .onChange(of: profiles.map(\.identifier)) { old, _ in
            guard old.isEmpty, current == nil, ready,
                  let added = stripCats.first(where: { $0.profile != nil && !$0.isDeparted(farewellJSON) }) else { return }
            Task { await open(added) }
        }
        .sheet(item: $selected, onDismiss: { Task { await reload() } }) { visit in
            NavigationStack {
                VeterinaryConsultationView(initialVisit: visit, photos: photos, noteStore: noteStore,
                    store: store, initialRecord: nil, profiles: profiles)
            }
            .environment(\.dynamicTypeSize, typeSize)
        }
    }

    private var strip: some View {
        ToolCatStrip(cats: stripCats, selectedID: current?.catID.uuidString) { cat in
            Task { await open(cat) }
        }
    }

    @ViewBuilder private var notices: some View {
        if let error { Section { Text(error); Button("もう一度読み込む") { Task { await reload() } } } }
    }

    /// The same notice, as one line above the memo.
    @ViewBuilder private var noticeBar: some View {
        if let error {
            VStack(alignment: .leading, spacing: 4) {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color(.systemGroupedBackground))
        }
    }

    private func open(_ cat: ToolStripCat) async {
        guard let id = UUID(uuidString: cat.id) else { return }
        lastCatID = cat.id
        await open(PhotoMemoryNoteCat(id: id, name: cat.name))
    }
    private func open(_ cat: PhotoMemoryNoteCat) async {
        let access = actionAccess
        do {
            current = try await store.current(catID: cat.id, catName: cat.name) { commit in
                try access.perform(for: .createVeterinaryVisit, commit)
            }
            error = nil
        }
        catch { self.error = veterinaryErrorMessage(error) }
    }
    private func reload() async {
        do {
            let loaded = try await store.visits()
            let notes: [PhotoMemoryNoteRecord]
            var sourceError: String?
            do { notes = try await noteStore.records() }
            catch { notes = []; sourceError = "写真のメモを読み込めませんでした。" }
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
                let message = "「預けるとき」「避難に備える」の猫を一部読み込めませんでした。"
                sourceError = sourceError.map { $0 + "\n" + message } ?? message
            }
            visits = loaded; ready = true; error = sourceError
            // Copies of photos no longer used are removed out of sight; a
            // failure is retried on the next load, never shown (11/8).
            _ = try? await store.cleanupPending()
        } catch { self.error = veterinaryErrorMessage(error); ready = false }
    }
}

private struct VeterinaryConsultationView: View {
    let initialVisit: VeterinaryVisit
    let photos: [PhotoPresentation]
    let noteStore: PhotoMemoryNoteStore
    let store: VeterinaryVisitStore
    let initialRecord: PhotoMemoryNoteRecord?
    var profiles: [CatProfilePresentation] = []
    /// Set when the memo is the tool's page: this cat's past memos below,
    /// no 「閉じる」 (the back button leaves and saves).
    var pastVisits: [VeterinaryVisit] = []
    var openPast: ((VeterinaryVisit) -> Void)? = nil
    var onDeleted: (() -> Void)? = nil
    /// After 「診察済みにする」 on the tool's page: open the next memo.
    var onFinished: (() -> Void)? = nil
    private var isPage: Bool { openPast != nil }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var visit: VeterinaryVisit?
    @State private var observations = ""
    @State private var questions = ""
    @State private var hasStartedDay = false
    @State private var startedDay = Date()
    @State private var doctorNote = ""
    @State private var prescription = ""
    @State private var hasNextVisit = false
    @State private var nextVisitDay = Date()
    @State private var picking = false
    @State private var showing = false
    @State private var discarding = false
    @State private var finishing = false
    @State private var deletesVisit = false
    @State private var error: String?
    @State private var busy = false
    @State private var chosen: PhotoMemoryNoteRecord?
    @State private var pendingSource: PhotoMemoryNoteRecord?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var removingEntry: VeterinaryVisitEntry?
    @ObservedObject private var catCareStore = CatCareStore.shared

    private var changes: Bool {
        guard let visit else { return false }
        return observations != visit.observations || questions != visit.questions
            || (hasStartedDay ? VeterinaryVisit.day(startedDay) : nil) != visit.startedOn
            || doctorNote != (visit.doctorNote ?? "") || prescription != (visit.prescription ?? "")
            || (hasNextVisit ? VeterinaryVisit.day(nextVisitDay) : nil) != visit.nextVisitOn
    }
    private var tooLong: Bool {
        [observations, questions, doctorNote, prescription].contains { $0.count > 500 }
    }
    /// A memo with something in it, last edited a week or more ago: the
    /// consultation it was for has probably happened (11/8).
    private func looksFinished(_ visit: VeterinaryVisit) -> Bool {
        guard visit.completedAt == nil, let last = visit.lastEditedAt else { return false }
        let written = !visit.observations.isEmpty || !visit.questions.isEmpty || !visit.entries.isEmpty || visit.hasResults
        return written && Date().timeIntervalSince(last) >= 7 * 24 * 60 * 60
    }
    /// A past memo is named by its day (11/8).
    private func pastTitle(_ past: VeterinaryVisit) -> String {
        (past.completedAt ?? past.lastEditedAt).map { DayText.japanese(VeterinaryVisit.day($0)) } ?? "診察メモ"
    }
    /// A past memo's first words, on one line: what the vet said first (11/8).
    private func pastSummary(_ past: VeterinaryVisit) -> String? {
        let texts = [past.doctorNote ?? "", past.observations, past.questions] + past.orderedEntries.map(\.text)
        guard let first = texts.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        return String(first.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(40))
    }
    private static func date(_ day: String) -> Date? {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }
    /// What came after the consultation. On a finished memo it is the only
    /// part that can still be written (11/8).
    private var resultsSection: some View {
        Section {
            VeterinaryLabeledField(title: "先生の話", example: "例：胃腸炎。2日ほどで治る見込み",
                                   text: $doctorNote, lines: 2...8, identifier: "vet-doctor-note")
            VeterinaryLabeledField(title: "出た薬", example: "例：吐き気止め 1日1回・3日分",
                                   text: $prescription, lines: 1...6, identifier: "vet-prescription")
            Toggle("次に行く日を記録", isOn: $hasNextVisit).accessibilityIdentifier("vet-next-visit-toggle")
            if hasNextVisit { DatePicker("次に行く日", selection: $nextVisitDay, displayedComponents: .date) }
        } header: { Text("診察のあと") }
    }
    // The body is split in parts so the type checker stays fast.
    var body: some View {
        dialogs(lifecycle(page))
    }
    private var page: some View {
        Form { formContent }
        .navigationTitle(isPage ? "病院で見せる" : "診察メモ").navigationBarTitleDisplayMode(.inline)
        .announcesWhenShown(error)
        .toolbar {
            if !isPage {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { close() }.disabled(busy) }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
    }
    private var bottomBar: some View {
        VStack(spacing: 6) {
            if error != nil, changes {
                Button("もう一度保存する") { Task { await save() } }.accessibilityIdentifier("vet-save")
            }
            // 11/7: a save that cannot go through is red with a mark, and
            // says why 「先生に見せる」 cannot be pressed yet.
            if tooLong {
                Label("500文字を超えている欄があります。短くすると保存され、先生に見せられます",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            } else if changes, error != nil {
                Label("保存できませんでした。保存できると、先生に見せられます",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            } else {
                Text(changes ? "保存中…" : "保存しました")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { showing = true } label: {
                Label("先生に見せる", systemImage: "stethoscope").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("vet-show").disabled(changes || busy)
        }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
    }
    @ViewBuilder private var formContent: some View {
        if let visit {
            headerSections(visit)
            writingSections(visit)
            recordSections(visit)
            closingSections(visit)
        }
        // 11/7: a failure in red with a mark, not small gray text.
        if let error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("vet-error")
            }
        }
        if !pastVisits.isEmpty {
            Section("これまでの診察メモ") {
                ForEach(pastVisits) { past in
                    // 11/7: the memo's first words and a chevron, so the
                    // rows can be told apart and read as ones that open.
                    // 11/8: the day, then the start of what the vet said.
                    Button { openPast?(past) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pastTitle(past))
                                if let summary = pastSummary(past) {
                                    Text(summary)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("vet-past-\(past.id.uuidString)")
                }
            }
        }
    }
    @ViewBuilder private func headerSections(_ visit: VeterinaryVisit) -> some View {
        // The cat's name; its dates are in この子のこと below (11/7).
        Section {
            // With two or more cats the row of faces above already names it (347).
            if profiles.count < 2 {
                Label(profiles.first(where: { $0.identifier == visit.catID.uuidString })?.displayName ?? visit.catName,
                      systemImage: "cat").font(.headline)
            }
            if visit.completedAt != nil { Text("診察済み").font(.caption).foregroundStyle(.secondary) }
            // The day the memo was started (11/8).
            if let started = visit.createdAt {
                Text("書き始めた日 \(DayText.japanese(VeterinaryVisit.day(started)))")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vet-started-day")
            }
        }
        if looksFinished(visit) {
            Section {
                Text("前の診察は終わりましたか？")
                Button("診察済みにする", systemImage: "checkmark") { finishing = true }
                    .disabled(changes).accessibilityIdentifier("vet-finish-previous")
            }
        }
    }
    @ViewBuilder private func writingSections(_ visit: VeterinaryVisit) -> some View {
        // What the owner came to write goes first; the cat's facts follow.
        if visit.completedAt == nil {
            Section {
                VeterinaryLabeledField(title: "家で気付いたこと", example: "例：1日2回吐く・食欲が半分",
                                       text: $observations, lines: 3...8, identifier: "vet-observations")
                Toggle("いつからかを記録", isOn: $hasStartedDay)
                if hasStartedDay { DatePicker("気付いた日", selection: $startedDay, displayedComponents: .date) }
                VeterinaryLabeledField(title: "先生に聞きたいこと", example: "例：ごはんを変えたほうがいいですか",
                                       text: $questions, lines: 2...8, identifier: "vet-questions")
            } header: { Text("今回伝えること") }
        } else {
            resultsSection
            Section("伝えたこと") {
                if !visit.observations.isEmpty { Text(visit.observations) }
                if let day = visit.startedOn { Text("気付いた日 \(DayText.japanese(day))") }
                if !visit.questions.isEmpty { Text(visit.questions) }
            }
        }
    }
    @ViewBuilder private func recordSections(_ visit: VeterinaryVisit) -> some View {
        ToolCatCareSection(
            title: "この子のこと",
            lines: CatCareSummary.veterinaryFields(
                CatCareSummary.record(toolCatID: visit.catID, profileIdentifier: visit.catID.uuidString),
                household: catCareStore.state?.household),
            subject: profiles.first(where: { $0.identifier == visit.catID.uuidString }).map(CatCareSubject.profile)
                ?? .toolCat(id: visit.catID, name: visit.catName),
            identifier: "vet-cat-care-fields", editIdentifier: "vet-open-cat-care", profiles: profiles)
        Section {
            ForEach(visit.orderedEntries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    VeterinaryEntryPhoto(entry: entry, visitID: visit.id, store: store)
                    if !entry.text.isEmpty { Text(entry.text) }
                    if entry.familyRetained == true { Text("家族の手帳から外れた記録です").font(.caption).foregroundStyle(.secondary) }
                    if let weight = entry.weight { PhotoMemoWeightLabel(weight: weight) }
                    VeterinaryEntryDates(entry: entry)
                    if visit.completedAt == nil {
                        Button("診察メモから外す", role: .destructive) { removingEntry = entry }
                            .accessibilityIdentifier("vet-remove-\(entry.id.uuidString)")
                    }
                }.padding(.vertical, 6)
            }
            if visit.completedAt == nil {
                Button("写真・メモを選ぶ", systemImage: "plus") { picking = true }
                    .accessibilityIdentifier("vet-pick-records")
            }
        } header: { Text("見せる記録 · \(visit.entries.count)件") }
        if visit.completedAt == nil { resultsSection }
    }
    @ViewBuilder private func closingSections(_ visit: VeterinaryVisit) -> some View {
        Section {
            ToolImportantInformation(text: "飼い主の記録をまとめたもので、医療の判断ではありません。様子がおかしいときは、迷わず動物病院に連絡してください。")
        }
        Section {
            // While the question above is shown, it is the one place to finish.
            if visit.completedAt == nil, !looksFinished(visit) {
                Button("診察済みにする", systemImage: "checkmark") { finishing = true }.disabled(changes)
            }
            Button("この診察メモを削除", role: .destructive) { deletesVisit = true }
        }
    }
    private func lifecycle<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: observations) { _, _ in scheduleSave() }
        .onChange(of: questions) { _, _ in scheduleSave() }
        .onChange(of: hasStartedDay) { _, _ in scheduleSave() }
        .onChange(of: startedDay) { _, _ in scheduleSave() }
        .onChange(of: doctorNote) { _, _ in scheduleSave() }
        .onChange(of: prescription) { _, _ in scheduleSave() }
        .onChange(of: hasNextVisit) { _, _ in scheduleSave() }
        .onChange(of: nextVisitDay) { _, _ in scheduleSave() }
        .onReceive(NotificationCenter.default.publisher(for: .appRecordsCommitted).receive(on: DispatchQueue.main)) { note in
            guard let url = note.object as? URL, url.path.contains("/VeterinaryVisits"), !changes, !busy else { return }
            Task {
                guard let id = visit?.id, let latest = try? await store.visits().first(where: { $0.id == id }), !changes, !busy else { return }
                adopt(latest)
            }
        }
        .onDisappear {
            // Leaving another way than 「閉じる」 still saves what was written.
            autosaveTask?.cancel()
            if changes { Task { await save() } }
        }
        .disabled(busy)
        .interactiveDismissDisabled(changes || busy)
        .task {
            catCareStore.importFromTools()
            catCareStore.importBirthdays(profiles)
            guard visit == nil else { return }
            adopt(initialVisit)
            if initialVisit.completedAt == nil { chosen = initialRecord }
        }
    }
    private func dialogs<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $picking, onDismiss: { chosen = pendingSource; pendingSource = nil }) {
            if let visit {
                VeterinaryRecordPicker(visit: visit, photos: photos, profiles: profiles, noteStore: noteStore) { pendingSource = $0; picking = false }
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
            if let visit { VeterinaryReadView(visit: visit, store: store, displayName: profiles.first(where: { $0.identifier == visit.catID.uuidString })?.displayName).environment(\.dynamicTypeSize, typeSize) }
        }
        .confirmationDialog("まだ保存できていません", isPresented: $discarding, titleVisibility: .visible) {
            Button("書いた内容を消して閉じる", role: .destructive) { dismiss() }; Button("画面に戻る", role: .cancel) {}
        } message: {
            Text(tooLong
                 ? "500文字を超えた欄があると保存できません。短くしてから閉じてください。"
                 : (error ?? "保存できませんでした。") + " 画面に戻って、もう一度お試しください。")
        }
        .confirmationDialog("診察済みにしますか？", isPresented: $finishing, titleVisibility: .visible) {
            Button("診察済みにする") { Task { await save(completing: true) } }; Button("キャンセル", role: .cancel) {}
        } message: { Text("診察済みにすると、書けるのは「診察のあと」だけになります。") }
        .confirmationDialog("この診察メモを削除しますか？", isPresented: $deletesVisit, titleVisibility: .visible) {
            Button("削除", role: .destructive) { Task { await deleteVisit() } }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("この診察メモだけを削除します。") }
        .confirmationDialog("診察メモから外しますか？", isPresented: removingEntryPresented, titleVisibility: .visible,
                            presenting: removingEntry, actions: removalActions, message: removalMessage)
        .appRecordEditing(retainWhileHidden: changes || busy || picking || chosen != nil || pendingSource != nil)
    }
    private func scheduleSave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            while busy {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled, changes else { return }
            await save()
        }
    }
    /// Closing saves first; it asks only when the memo could not be saved.
    private func close() {
        guard changes else { dismiss(); return }
        autosaveTask?.cancel()
        Task {
            await save()
            if changes { discarding = true } else { dismiss() }
        }
    }

    private func save(completing: Bool = false) async {
        guard var draft = visit, !busy, completing || changes, !tooLong else { return }
        let base = draft
        busy = true; defer { busy = false }
        draft.doctorNote = doctorNote.isEmpty ? nil : doctorNote
        draft.prescription = prescription.isEmpty ? nil : prescription
        draft.nextVisitOn = hasNextVisit ? VeterinaryVisit.day(nextVisitDay) : nil
        do {
            if draft.completedAt != nil {
                // A finished memo: only 「診察のあと」 is saved.
                adopt(try await store.saveResults(draft, expectedRevision: draft.revision, base: base)); error = nil
                return
            }
            draft.observations = observations; draft.questions = questions
            draft.startedOn = hasStartedDay ? VeterinaryVisit.day(startedDay) : nil
            if completing { draft.completedAt = Date() }
            adopt(try await store.save(draft, expectedRevision: draft.revision, base: base)); error = nil
            if completing { onFinished?() }
        }
        catch { self.error = veterinaryErrorMessage(error) }
    }
    private func adopt(_ value: VeterinaryVisit) {
        visit = value; observations = value.observations; questions = value.questions
        hasStartedDay = value.startedOn != nil
        if let day = value.startedOn { startedDay = Self.date(day) ?? startedDay }
        doctorNote = value.doctorNote ?? ""; prescription = value.prescription ?? ""
        hasNextVisit = value.nextVisitOn != nil
        if let day = value.nextVisitOn { nextVisitDay = Self.date(day) ?? nextVisitDay }
    }
    // Kept out of the body chain so the type checker stays fast.
    private var removingEntryPresented: Binding<Bool> {
        Binding(get: { removingEntry != nil }, set: { if !$0 { removingEntry = nil } })
    }

    @ViewBuilder private func removalActions(_ entry: VeterinaryVisitEntry) -> some View {
        Button("外す", role: .destructive) { Task { await remove(entry) } }
        Button("キャンセル", role: .cancel) {}
    }

    private func removalMessage(_ entry: VeterinaryVisitEntry) -> some View {
        Text("元の写真やメモは残ります。")
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
        do {
            try await store.delete(visitID: visit.id, expectedRevision: visit.revision)
            if let onDeleted { onDeleted() } else { dismiss() }
        }
        catch { self.error = veterinaryErrorMessage(error) }
    }
}

private struct VeterinaryRecordPicker: View {
    let visit: VeterinaryVisit
    let photos: [PhotoPresentation]
    var profiles: [CatProfilePresentation] = []
    let noteStore: PhotoMemoryNoteStore
    let choose: (PhotoMemoryNoteRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var records: [PhotoMemoryNoteRecord] = []
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var error: String?

    private var profile: CatProfilePresentation? { profiles.first { $0.identifier == visit.catID.uuidString } }
    /// This cat's photos (11/8): the ones the owner put on its page. A cat
    /// without any still offers every photo, as before.
    private var offered: [PhotoPresentation] {
        guard let mine = profile?.confirmedPhotos, !mine.isEmpty else { return photos }
        var seen = Set<String>()
        return mine.filter { seen.insert($0.localIdentifier).inserted }.map {
            PhotoPresentation(localIdentifier: $0.localIdentifier, creationDate: $0.creationDate, catBoundingBox: $0.catBoundingBox)
        }
    }
    /// Newest first, in a grid of three.
    private var gridPhotos: [PhotoPresentation] {
        offered.filter { access.photo(for: $0.localIdentifier) != nil }
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }
    /// Put on this cat's page and no other: the owner already said whose it is.
    private func onlyThisCat(_ photo: PhotoPresentation) -> Bool {
        guard let profile else { return false }
        return profile.confirmedPhotos.first { $0.localIdentifier == photo.localIdentifier }?
            .assignedProfileIdentifiers == [profile.identifier]
    }
    private func choosePhoto(_ photo: PhotoPresentation) {
        let selected = visit.entries.first { $0.sourcePhotoIdentifier == photo.localIdentifier }
        let cats = onlyThisCat(photo) ? [PhotoMemoryNoteCat(id: visit.catID, name: visit.catName)] : []
        let note = PhotoMemoryNote(id: selected?.sourceNoteID ?? UUID(), text: "", updatedAt: Date(),
            revision: UUID().uuidString, context: PhotoMemoryNoteContext(capturedAt: photo.creationDate, cats: cats))
        choose(PhotoMemoryNoteRecord(photoIdentifier: photo.localIdentifier, note: note))
    }

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
                                    Text(selected.sourceRevision == record.note.revision ? "追加済み" : "元のメモが書き直されています。選ぶと新しい内容にできます")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }.accessibilityIdentifier("vet-source-\(record.id.uuidString)")
                    }
                    if records.isEmpty && error == nil { Text("写真に付けたメモはまだありません。") }
                } header: { Text("\(visit.catName)に見せるメモを選ぶ") }
                Section("写真だけ選ぶ") {
                    let grid = gridPhotos
                    if !grid.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                            ForEach(grid) { photo in photoCell(photo) }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                }
                if let error { Text(error) }
            }
            .navigationTitle("写真・メモを選ぶ").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .task {
                access.start(photos: offered)
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

    private func photoCell(_ photo: PhotoPresentation) -> some View {
        let added = visit.entries.contains { $0.sourcePhotoIdentifier == photo.localIdentifier }
        return Button { choosePhoto(photo) } label: {
            Color(.secondarySystemFill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    PhotoAssetImageView(localIdentifier: photo.localIdentifier, catBoundingBox: photo.catBoundingBox,
                                        targetPixelSize: CGSize(width: 360, height: 360))
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if added {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3).symbolRenderingMode(.multicolor).padding(4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photo.creationDate.map { "撮影 \(DayText.japanese(VeterinaryVisit.day($0)))" } ?? "写真")
        .accessibilityValue(added ? "追加済み" : "")
        .accessibilityIdentifier("vet-photo-\(photo.localIdentifier)")
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
    @State private var savedPhotoURL: URL?

    init(source: PhotoMemoryNoteRecord, visit: VeterinaryVisit, photos: [PhotoPresentation],
         noteStore: PhotoMemoryNoteStore, store: VeterinaryVisitStore, saved: @escaping (VeterinaryVisit) -> Void) {
        self.source = source; self.visit = visit; self.photos = photos
        self.noteStore = noteStore; self.store = store; self.saved = saved
        // Asked only when it is unclear whose record it is (11/8).
        _confirmed = State(initialValue: Self.belongsOnly(to: visit.catID, source))
    }

    /// The record names this cat and no other, by saved identity, never by name.
    static func belongsOnly(to cat: UUID, _ source: PhotoMemoryNoteRecord) -> Bool {
        let cats = Set(source.note.context?.cats.map(\.id) ?? [])
        if let owner = source.note.weight?.catID { return owner == cat && cats.isSubset(of: [cat]) }
        return cats == [cat]
    }
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
                    } else if let savedPhotoURL {
                        AppRecordSavedPhoto(url: savedPhotoURL).aspectRatio(1, contentMode: .fit)
                    } else { Label("元の写真を開けません。文章と体重だけ追加します。", systemImage: "photo").font(.caption) }
                    if !source.note.text.isEmpty { Text(source.note.text) }
                    if let weight = source.note.weight { PhotoMemoWeightLabel(weight: weight.value) }
                    Toggle("この記録は\(visit.catName)のものです", isOn: $confirmed)
                        .accessibilityIdentifier("vet-confirm-target")
                    if wrongCat { Text("この体重は別の猫のものです。元のメモで猫を確かめてください。") }
                    Button(visit.entries.contains { $0.sourceNoteID == source.id } ? "新しい内容にする" : "診察メモに追加") { Task { await add() } }
                        .disabled(!confirmed || wrongCat || busy).accessibilityIdentifier("vet-add-confirmed")
                    if busy { ProgressView("写真を準備しています…") }
                }
                if let error { Text(error).accessibilityIdentifier("vet-add-error") }
            }
            .navigationTitle("内容を確認").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .task { access.start(photos: photos); savedPhotoURL = try? await noteStore.photoURL(for: source.id) }.onDisappear { access.stop() }
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
            if let savedPhotoURL { bytes = try Data(contentsOf: savedPhotoURL) }
            else if let fixtureBytes { bytes = fixtureBytes }
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

/// One day per record (11/8): measured, else taken, else written. Nothing
/// when none is known.
private struct VeterinaryEntryDates: View {
    let entry: VeterinaryVisitEntry
    static func day(_ entry: VeterinaryVisitEntry) -> String? {
        entry.weight?.measuredOn ?? entry.capturedAt.map(VeterinaryVisit.day) ?? entry.writtenAt.map(VeterinaryVisit.day)
    }
    var body: some View {
        if let day = Self.day(entry) {
            Text(DayText.japanese(day)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A field whose name stays above it; the gray text inside is an example.
private struct VeterinaryLabeledField: View {
    let title: String
    let example: String
    @Binding var text: String
    let lines: ClosedRange<Int>
    let identifier: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(example, text: $text, axis: .vertical).lineLimit(lines)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
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
            else if failed { Label("写真を開けません", systemImage: "photo").font(.caption) }
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
    var displayName: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var export: CareHandoffExporter.Export?
    @State private var retainedDirectory: URL?
    @State private var exportError: String?
    /// Set while the confirmation before handing over is open.
    @State private var pendingExportIsPDF: Bool?
    @State private var lastExportIsPDF = true
    /// True while the memo for the desk is being made (11/6).
    @State private var exporting = false

    private var catCareFields: [(String, String)] {
        CatCareSummary.veterinaryFields(
            CatCareSummary.record(toolCatID: visit.catID, profileIdentifier: visit.catID.uuidString),
            household: CatCareStore.shared.state?.household)
    }
    /// 「この子のこと」 without the rows that are not written yet (11/8): the
    /// medical ones first, then the rest as 「そのほか」.
    private var careFields: (medical: [(String, String)], other: [(String, String)]) {
        VeterinaryCareOrder.split(catCareFields)
    }
    private static func text(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    /// What came after the consultation, when written.
    private var results: [(String, String)] {
        var fields: [(String, String)] = []
        if let note = Self.text(visit.doctorNote) { fields.append(("先生の話", note)) }
        if let medicine = Self.text(visit.prescription) { fields.append(("出た薬", medicine)) }
        if let day = visit.nextVisitOn { fields.append(("次に行く日", DayText.japanese(day))) }
        return fields
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // 11/8: what is happening now first; the cat's standing facts last.
                VStack(alignment: .leading, spacing: 24) {
                    Text(displayName ?? visit.catName).font(.largeTitle.bold())
                    if !visit.observations.isEmpty || visit.startedOn != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("家で気付いたこと").font(.headline)
                            if !visit.observations.isEmpty { Text(visit.observations) }
                            if let day = visit.startedOn { Label("気付いた日 \(DayText.japanese(day))", systemImage: "calendar") }
                        }
                    }
                    ForEach(Array(results.enumerated()), id: \.offset) { _, field in
                        VStack(alignment: .leading, spacing: 8) { Text(field.0).font(.headline); Text(field.1) }
                    }
                    ForEach(visit.orderedEntries) { entry in
                        VStack(alignment: .leading, spacing: 12) {
                            VeterinaryEntryPhoto(entry: entry, visitID: visit.id, store: store)
                            if !entry.text.isEmpty { Text(entry.text) }
                            if let weight = entry.weight { PhotoMemoWeightLabel(weight: weight) }
                            VeterinaryEntryDates(entry: entry)
                        }
                        Divider()
                    }
                    if !visit.questions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) { Text("先生に聞きたいこと").font(.headline); Text(visit.questions) }
                    }
                    let care = careFields
                    if !care.medical.isEmpty { VeterinaryCatCareFields(fields: care.medical) }
                    if !care.other.isEmpty {
                        Text("そのほか").font(.headline)
                        VeterinaryCatCareFields(fields: care.other)
                    }
                    if visit.entries.isEmpty && visit.observations.isEmpty && visit.questions.isEmpty && results.isEmpty
                        && care.medical.isEmpty && care.other.isEmpty {
                        Text("まだ見せる内容がありません。").foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("vet-reading")
            .navigationTitle("診察メモ").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                ViewThatFits {
                    HStack(spacing: 12) { exportButtons }
                    VStack(spacing: 8) { exportButtons }
                }
                .padding().background(.regularMaterial)
            }
            .confirmationDialog("診察メモを渡しますか？", isPresented: Binding(
                get: { pendingExportIsPDF != nil }, set: { if !$0 { pendingExportIsPDF = nil } }),
                titleVisibility: .visible) {
                Button(pendingExportIsPDF == true ? "PDFを作って渡す" : "画像を作って渡す") {
                    let pdf = pendingExportIsPDF == true
                    pendingExportIsPDF = nil
                    lastExportIsPDF = pdf
                    Task { await makeExport(pdf: pdf) }
                }
            } message: {
                Text("薬・アレルギー・体重などと選んだ写真が載るので、渡す相手を確かめてください。")
            }
            .alert("作れませんでした", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("もう一度作る") { Task { await makeExport(pdf: lastExportIsPDF) } }
                Button("閉じる", role: .cancel) {}
            } message: { Text(exportError ?? "") }
            .sheet(item: $export, onDismiss: {
                // The item is already cleared here; remove the copy this screen made.
                if let retainedDirectory { CareHandoffExporter.remove(retainedDirectory) }
                retainedDirectory = nil
            }) { made in
                VeterinaryActivitySheet(items: made.files)
            }
        }
    }

    @ViewBuilder private var exportButtons: some View {
        Button { pendingExportIsPDF = true } label: {
            Group {
                if exporting && lastExportIsPDF {
                    WorkingLabel(title: "PDFで渡す", workingTitle: "作っています…", working: true)
                } else {
                    Label("PDFで渡す", systemImage: "doc")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent).accessibilityIdentifier("vet-export-pdf")
        .disabled(exporting)
        Button { pendingExportIsPDF = false } label: {
            Group {
                if exporting && !lastExportIsPDF {
                    WorkingLabel(title: "画像で渡す", workingTitle: "作っています…", working: true)
                } else {
                    Label("画像で渡す", systemImage: "photo")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered).accessibilityIdentifier("vet-export-images")
        .disabled(exporting)
    }

    /// One sheet for the reception desk, in the order of the screen (11/8):
    /// what was noticed and since when, what the vet said, every chosen photo
    /// (numbered like its note), questions, then 「この子のこと」 without
    /// unwritten rows.
    private func makeExport(pdf: Bool) async {
        // The file is drawn on the main thread, which stops the screen; give
        // 「作っています…」 a moment to show first, so the press is not silent (11/6).
        exporting = true
        defer { exporting = false }
        try? await Task.sleep(for: .milliseconds(100))
        var blocks: [VeterinaryMemoExporter.Block] = []
        var noticed: [(String, String)] = []
        if !visit.observations.isEmpty { noticed.append(("家で気付いたこと", visit.observations)) }
        if let day = visit.startedOn { noticed.append(("気付いた日", DayText.japanese(day))) }
        blocks.append(.fields(noticed + results))
        var images: [(Int, UIImage)] = []
        var notes: [(String, String)] = []
        for (offset, entry) in visit.orderedEntries.enumerated() {
            let number = offset + 1
            // Every chosen photo (at most 20 per memo), made small enough to
            // keep the whole set in memory while the pages are drawn.
            if entry.photoFile != nil, let data = try? await store.image(for: entry, visitID: visit.id),
               let image = VeterinaryMemoExporter.image(data) {
                images.append((number, image))
            }
            var lines: [String] = []
            if !entry.text.isEmpty { lines.append(entry.text) }
            if let weight = entry.weight, !catCareFields.contains(where: { $0.1.contains(CatCareFormat.weight(weight.grams)) }) {
                lines.append("体重 \(CatCareFormat.weight(weight.grams))")
            }
            if !lines.isEmpty, let day = VeterinaryEntryDates.day(entry) { lines.append(DayText.japanese(day)) }
            if !lines.isEmpty { notes.append(("記録 \(number)", lines.joined(separator: "\n"))) }
        }
        if !images.isEmpty || !notes.isEmpty {
            blocks.append(.heading(images.isEmpty ? "記録" : "写真"))
            blocks.append(.photos(images))
            blocks.append(.fields(notes))
        }
        if !visit.questions.isEmpty { blocks.append(.fields([("先生に聞きたいこと", visit.questions)])) }
        let care = careFields
        blocks.append(.fields(care.medical))
        if !care.other.isEmpty { blocks.append(.heading("そのほか")); blocks.append(.fields(care.other)) }
        blocks.append(.fields([("ご注意", "飼い主の記録をまとめたものです。医療の判断ではありません。")]))
        do {
            let made = try VeterinaryMemoExporter.create(name: displayName ?? visit.catName, blocks: blocks, pdf: pdf)
            retainedDirectory = made.directory; export = made
        }
        catch { exportError = "空き容量やメモの長さを確かめてください。" }
    }
}

/// 「この子のこと」 for the vet: unwritten rows (未記入・未確認) are left out,
/// as on the edit side; medicine, allergy, conditions and weight come first.
private enum VeterinaryCareOrder {
    static let medical = ["飲んでいる薬", "アレルギー", "持病", "体重の推移"]
    static func isUnwritten(_ field: (String, String)) -> Bool {
        field.1.hasPrefix("未記入") || field.1.hasPrefix("未確認")
    }
    static func split(_ fields: [(String, String)]) -> (medical: [(String, String)], other: [(String, String)]) {
        let written = fields.filter { !isUnwritten($0) }
        let first = medical.compactMap { key in written.first { $0.0 == key } }
        return (first, written.filter { !medical.contains($0.0) })
    }
}

private struct VeterinaryCatCareFields: View {
    let fields: [(String, String)]
    var body: some View {
        ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
            VStack(alignment: .leading, spacing: 4) {
                Text(field.0).font(.subheadline).foregroundStyle(.secondary)
                Text(field.1).font(.body).textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("vet-cat-care-fields")
    }
}

private struct VeterinaryActivitySheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Draws the 診察メモ for the reception desk (11/8). Same page size and look
/// as 「預けるとき」, but in the order of the screen, with every chosen photo
/// in a two-column grid, numbered like its note.
@MainActor
private enum VeterinaryMemoExporter {
    enum Block {
        case fields([(String, String)])
        case heading(String)
        case photos([(Int, UIImage)])
    }
    /// The same temporary folder name as 「預けるとき」, so its cleanup
    /// (when the share sheet closes, and at launch) removes this one too.
    private static let prefix = "neko-care-handoff-"

    /// A chosen photo, made small enough to keep up to 20 of them in memory.
    static func image(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private enum Item {
        case text(CTFramesetter, CFRange, CGRect)
        case photo(UIImage, Int, CGRect)
    }

    static func create(name: String, blocks: [Block], pdf: Bool) throws -> CareHandoffExporter.Export {
        let size = pdf ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 390, height: 900)
        let margin: CGFloat = pdf ? 36 : 24
        let font: CGFloat = pdf ? 15 : 18
        let top = margin + 44, bottom = size.height - margin - 26, width = size.width - margin * 2
        var pages: [[Item]] = [[]]
        var y = top
        func newPage() throws {
            guard pages.count < 80 else { throw CareHandoffError.tooLarge }
            pages.append([]); y = top
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 11; paragraph.lineSpacing = 3
        func line(_ text: String, size: CGFloat, bold: Bool = false) -> NSAttributedString {
            NSAttributedString(string: text + "\n", attributes: [
                .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
                .foregroundColor: UIColor.black, .paragraphStyle: paragraph
            ])
        }
        // Text flows down the page and onto the next one where it does not fit.
        func place(_ text: NSAttributedString) throws {
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            var offset = 0
            while offset < text.length {
                let available = max(bottom - y, 0)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0),
                    CGPath(rect: CGRect(x: 0, y: 0, width: width, height: available), transform: nil), nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else {
                    // Not one more line fits on this page.
                    guard y > top else { throw CareHandoffError.tooLarge }
                    try newPage(); continue
                }
                let range = CFRange(location: offset, length: visible.length)
                let used = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, range, nil,
                    CGSize(width: width, height: .greatestFiniteMagnitude), nil).height
                pages[pages.count - 1].append(.text(framesetter, range, CGRect(x: margin, y: y, width: width, height: available)))
                offset += visible.length
                y += min(ceil(used), available)
                if offset < text.length { try newPage() }
            }
        }
        var body = NSMutableAttributedString()
        func flush() throws {
            guard body.length > 0 else { return }
            try place(body); body = NSMutableAttributedString()
        }
        body.append(line(name, size: font + 5, bold: true))
        for block in blocks {
            switch block {
            case .fields(let fields):
                for (title, text) in fields {
                    body.append(line(title, size: font - 2, bold: true)); body.append(line(text, size: font))
                }
            case .heading(let title):
                body.append(line(title, size: font + 1, bold: true))
            case .photos(let photos):
                guard !photos.isEmpty else { continue }
                try flush()
                let columns = 2
                let spacing: CGFloat = 10
                let cell = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                for row in stride(from: 0, to: photos.count, by: columns) {
                    if y + cell > bottom { try newPage() }
                    for (column, photo) in photos[row..<min(row + columns, photos.count)].enumerated() {
                        pages[pages.count - 1].append(.photo(photo.1, photo.0,
                            CGRect(x: margin + CGFloat(column) * (cell + spacing), y: y, width: cell, height: cell)))
                    }
                    y += cell + spacing
                }
                y += 6
            }
        }
        body.append(line("作った日：" + Date().formatted(date: .numeric, time: .shortened), size: font - 2))
        body.append(line("このメモは作った時点の内容です。変わったところは飼い主に確かめてください。", size: font - 2))
        try flush()
        if pages.last?.isEmpty == true, pages.count > 1 { pages.removeLast() }

        func draw(_ context: CGContext, index: Int) {
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            let headingStyle = NSMutableParagraphStyle(); headingStyle.lineBreakMode = .byTruncatingTail
            ("診察メモ · \(name)" as NSString).draw(in:
                CGRect(x: margin, y: margin, width: size.width - margin * 2, height: 26), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: UIColor.black,
                    .paragraphStyle: headingStyle
                ])
            for item in pages[index] {
                switch item {
                case let .text(framesetter, range, bounds):
                    context.saveGState(); context.textMatrix = .identity
                    context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
                    let path = CGPath(rect: CGRect(x: bounds.minX, y: size.height - bounds.maxY,
                        width: bounds.width, height: bounds.height), transform: nil)
                    CTFrameDraw(CTFramesetterCreateFrame(framesetter, range, path, nil), context)
                    context.restoreGState()
                case let .photo(image, number, rect):
                    UIColor(white: 0.94, alpha: 1).setFill()
                    UIBezierPath(roundedRect: rect, cornerRadius: 6).fill()
                    // The whole photo, never cropped: a vet may need its edges.
                    let scale = min(rect.width / image.size.width, rect.height / image.size.height)
                    let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                                          width: fitted.width, height: fitted.height))
                    let label = "\(number)" as NSString
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.boldSystemFont(ofSize: 13), .foregroundColor: UIColor.white
                    ]
                    let textSize = label.size(withAttributes: attributes)
                    let badge = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: max(22, textSize.width + 12), height: 22)
                    UIColor.black.withAlphaComponent(0.7).setFill()
                    UIBezierPath(roundedRect: badge, cornerRadius: 11).fill()
                    label.draw(at: CGPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
                               withAttributes: attributes)
                }
            }
            ("ねこのまど  ·  \(index + 1) / \(pages.count)" as NSString).draw(
                at: CGPoint(x: margin, y: size.height - margin), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray
                ])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        var files: [URL] = []
        do {
            if pdf {
                let file = directory.appendingPathComponent("診察メモ.pdf")
                let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
                    for index in pages.indices { context.beginPage(); draw(context.cgContext, index: index) }
                }
                try data.write(to: file, options: [.atomic, .completeFileProtection]); files.append(file)
            } else {
                let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
                for index in pages.indices {
                    let data = UIGraphicsImageRenderer(size: size, format: format).pngData { draw($0.cgContext, index: index) }
                    let file = directory.appendingPathComponent("診察メモ-\(index + 1).png")
                    try data.write(to: file, options: [.atomic, .completeFileProtection]); files.append(file)
                }
            }
            return CareHandoffExporter.Export(directory: directory, files: files)
        } catch { CareHandoffExporter.remove(directory); throw error }
    }
}
