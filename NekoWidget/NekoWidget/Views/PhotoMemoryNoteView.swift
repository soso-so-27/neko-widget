import SwiftUI
import CloudKit
import ImageIO
import UIKit

/// Owns only explicit exports. Closing a picker never writes back to a record.
@MainActor
final class RecordExportController: ObservableObject {
    @Published var payload: PhotoMemoryNoteExportPayload?
    @Published private(set) var preparing = false
    @Published private(set) var error: String?
    @Published private(set) var failureKind: PreservationExportFailure?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private static var pendingCleanup: [UUID: PhotoMemoryNoteExportPayload] = [:]

    func prepare(
        build: @escaping @Sendable () async throws -> PhotoMemoryNoteExportPayload,
        verify: @escaping @MainActor () async throws -> Void = {}
    ) {
        guard !preparing, payload == nil, retryCleanup() else { return }
        error = nil; failureKind = nil
        preparing = true
        let token = UUID()
        generation = token
        operation = Task {
            var prepared: PhotoMemoryNoteExportPayload?
            defer {
                if let prepared { remove(prepared) }
                if generation == token { preparing = false; operation = nil }
            }
            do {
                try await verify()
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated, operation: build)
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                prepared = result
                try Task.checkCancellation()
                try await verify()
                guard generation == token, !Task.isCancelled else { return }
                payload = result
                prepared = nil
            } catch let pending as PhotoMemoryNoteExportCleanupPending {
                for item in pending.payloads { remove(item) }
                if generation == token { error = PhotoMemoryNoteExportError.cleanupFailed.errorDescription; failureKind = .cleanup }
            } catch is CancellationError {
                if generation == token { failureKind = .cancelled }
                // The immutable source and any other export remain unchanged.
            } catch {
                if generation == token {
                    self.failureKind = PreservationExportFailure.classify(error)
                    self.error = (error as? LocalizedError)?.errorDescription
                        ?? "ファイルを準備できませんでした。もう一度お試しください。"
                }
            }
        }
    }

    func cancelPreparation() {
        if preparing { failureKind = .cancelled }
        generation = UUID()
        operation?.cancel()
        operation = nil
        preparing = false
    }

    func recordPreparationFailure(_ error: Error) {
        failureKind = PreservationExportFailure.classify(error)
    }

    func invalidate() {
        cancelPreparation()
        if let payload { finishSharing(payload) }
    }

    func finishSharing(_ completed: PhotoMemoryNoteExportPayload, failed: Bool = false) {
        // An old share-sheet callback must not dismiss or clean a later export.
        if payload?.id == completed.id { payload = nil }
        remove(completed)
        if failed { error = "ファイルの保存・共有を完了できませんでした。もう一度お試しください。" }
    }

    @discardableResult
    func retryCleanup() -> Bool {
        for value in Array(Self.pendingCleanup.values) { remove(value) }
        return Self.pendingCleanup.isEmpty
    }

    private func remove(_ value: PhotoMemoryNoteExportPayload) {
        do {
            try value.cleanup()
            Self.pendingCleanup[value.id] = nil
        } catch {
            Self.pendingCleanup[value.id] = value
            self.error = PhotoMemoryNoteExportError.cleanupFailed.errorDescription
            self.failureKind = .cleanup
        }
    }
}

struct RecordExportActivity: UIViewControllerRepresentable {
    let payload: PhotoMemoryNoteExportPayload
    let finished: @MainActor (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [payload.fileURL], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            let failed = error != nil
            Task { @MainActor in finished(failed) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct PhotoMemoStoreKey: EnvironmentKey {
    static let defaultValue = PhotoMemoryNoteStore.shared
}

extension EnvironmentValues {
    var photoMemoStore: PhotoMemoryNoteStore {
        get { self[PhotoMemoStoreKey.self] }
        set { self[PhotoMemoStoreKey.self] = newValue }
    }
}

/// The selected photo may change while the actor is reading. Only the latest
/// request may publish a note into the browser. Sharing is always explicit.
@MainActor
final class PhotoMemoryNotePresentation: ObservableObject {
    let store: PhotoMemoryNoteStore
    @Published private(set) var reading = PhotoMemoryNoteReadingState()
    var identifier: String? { reading.identifier }
    var note: PhotoMemoryNote? { reading.note }
    var readState: PhotoMemoryNoteReadState { reading.phase }

    init(store: PhotoMemoryNoteStore) { self.store = store }

    func load(for identifier: String) async {
        let token = reading.begin(for: identifier)
        do {
            let loaded = try await store.note(for: identifier)
            guard !Task.isCancelled else { reading.cancel(token: token); return }
            reading.complete(loaded, token: token)
        } catch is CancellationError {
            reading.cancel(token: token)
        } catch {
            guard !Task.isCancelled else { reading.cancel(token: token); return }
            reading.fail(token: token)
            // Never log private content or turn a read failure into an empty memo.
        }
    }

    func note(for identifier: String) -> PhotoMemoryNote? {
        self.identifier == identifier && readState == .loaded ? note : nil
    }

    func state(for identifier: String) -> PhotoMemoryNoteReadState {
        self.identifier == identifier ? readState : .loading
    }
}

/// A memo has the same reading hierarchy regardless of its storage location.
struct PhotoMemoDetailContent<Photo: View, Status: View>: View {
    let text: String
    let capturedAt: Date?
    let writtenAt: Date?
    let fallbackDate: Date
    let weight: PhotoMemoWeightValue?
    let photo: Photo
    let status: Status

    init(text: String, capturedAt: Date?, writtenAt: Date?, fallbackDate: Date, weight: PhotoMemoWeightValue? = nil,
         @ViewBuilder photo: () -> Photo, @ViewBuilder status: () -> Status) {
        self.text = text; self.capturedAt = capturedAt
        self.writtenAt = writtenAt; self.fallbackDate = fallbackDate
        self.weight = weight
        self.photo = photo(); self.status = status()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                photo
                if !text.isEmpty {
                    Text(text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("memory-note-body")
                }
                if let weight { PhotoMemoWeightLabel(weight: weight) }
                Text("\(capturedAt == nil ? "メモ" : "撮影") \((capturedAt ?? writtenAt ?? fallbackDate).formatted(.dateTime.year().month().day()))")
                    .font(.caption).foregroundStyle(.secondary)
                status
            }.padding(16)
        }
    }
}

struct PhotoMemoWeightLabel: View {
    let weight: PhotoMemoWeightValue
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("体重 \(weight.kilogramsText) kg", systemImage: "scalemass")
                .font(.headline).accessibilityIdentifier("memory-note-weight")
            Text("\(weight.catName ?? "猫を選んでいません") · 測定日 \(weight.measuredOn.map(DayText.japanese) ?? "不明")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// `photo` is frozen when the editor opens, including when its parent pages.
/// The local original stays independent of any explicitly attached send copy.
struct PhotoMemoryNoteEditor: View {
    @Environment(\.membershipAccess) private var membershipAccess
    let photo: PhotoPresentation?
    let store: PhotoMemoryNoteStore
    let onSaved: () -> Void
    private let recordID: UUID?
    private let context: PhotoMemoryNoteContext?
    @StateObject private var photoAccess = PhotoMemoryNotePhotoAccess()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isWriting: Bool
    @FocusState private var isMeasuring: Bool
    @State private var original: PhotoMemoryNote?
    @State private var savedPhotoURL: URL?
    @State private var text = ""
    @State private var isLoaded = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loadFailed = false
    @State private var saveError: String?
    /// 11/14: a photo without a memo, when 3,000 memos are written.
    @State private var notesFull = false
    @State private var confirmsDiscard = false
    @State private var confirmsDelete = false
    @State private var weightEnabled = false
    @State private var weightKg = ""
    @State private var weightDateKnown = false
    @State private var weightDate = Date()
    @State private var weightCatID: UUID?
    @State private var weightCatName: String?

    private var originalWeight: PhotoMemoWeight? { original?.weight }
    @ObservedObject private var careStore: CareHandoffStore = .shared
    @ObservedObject private var evacuationStore: EvacuationStore = .shared
    private var photoCats: [PhotoMemoryNoteCat] { original?.context?.cats ?? context?.cats ?? [] }
    private var toolCats: [SavedToolCatChoices.Choice] { SavedToolCatChoices.cats(care: careStore, evacuation: evacuationStore) }
    private var weightCats: [PhotoMemoryNoteCat] {
        var existing = photoCats
        if let weight = originalWeight, let id = weight.catID {
            existing.append(.init(id: id, name: weight.value.catName ?? "記録した猫"))
        }
        var seen = Set<UUID>()
        return (existing + toolCats.map(\.cat)).filter { seen.insert($0.id).inserted }
    }
    private func weightCatLabel(_ cat: PhotoMemoryNoteCat) -> String {
        guard !photoCats.contains(where: { $0.id == cat.id }), let source = toolCats.first(where: { $0.id == cat.id }) else { return cat.name }
        return cat.name + " · " + source.source
    }
    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
    private var draftWeight: PhotoMemoWeight? {
        guard weightEnabled, let grams = PhotoMemoWeightValue.grams(from: weightKg) else { return nil }
        return PhotoMemoWeight(value: PhotoMemoWeightValue(grams: grams,
            measuredOn: weightDateKnown ? Self.dayFormatter().string(from: weightDate) : nil,
            catName: weightCatName), catID: weightCatID)
    }
    private var validWeight: Bool { !weightEnabled || draftWeight != nil }
    private func loadWeight(_ weight: PhotoMemoWeight?) {
        weightEnabled = weight != nil; weightKg = weight?.value.kilogramsText ?? ""
        weightDateKnown = weight?.value.measuredOn != nil
        weightDate = weight?.value.measuredOn.flatMap { Self.dayFormatter().date(from: $0) } ?? Date()
        weightCatID = weight?.catID; weightCatName = weight?.value.catName
        // A single saved tool cat does not establish who is in this photo.
        if weight == nil, photoCats.count == 1 {
            weightCatID = photoCats[0].id; weightCatName = photoCats[0].name
        }
    }

    init(photo: PhotoPresentation, store: PhotoMemoryNoteStore,
         context: PhotoMemoryNoteContext? = nil,
         onSaved: @escaping () -> Void) {
        self.photo = photo
        self.store = store
        self.context = context ?? PhotoMemoryNoteContext(capturedAt: photo.creationDate, cats: [])
        self.onSaved = onSaved
        recordID = nil
    }

    init(record: PhotoMemoryNoteRecord, photo: PhotoPresentation?, store: PhotoMemoryNoteStore,
         careStore: CareHandoffStore? = nil, evacuationStore: EvacuationStore? = nil,
         onSaved: @escaping () -> Void) {
        self.photo = photo
        self.store = store
        self.context = nil
        self.recordID = record.id
        self.onSaved = onSaved
        _careStore = ObservedObject(wrappedValue: careStore ?? .shared)
        _evacuationStore = ObservedObject(wrappedValue: evacuationStore ?? .shared)
    }

    private var normalizedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var createsNewMemo: Bool {
        original == nil && recordID == nil
    }

    private var hasChanges: Bool {
        isLoaded && (normalizedText != (original?.text ?? "")
            || draftWeight != originalWeight || (weightEnabled && !validWeight))
    }

    private var hasCurrentPhoto: Bool {
        guard let photo else { return false }
        return photoAccess.photo(for: photo.localIdentifier) != nil
    }

    @ViewBuilder
    private var notePhotoSection: some View {
        if let savedPhotoURL {
            Section {
                AppRecordSavedPhoto(url: savedPhotoURL)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("保存した写真")
            }
        } else if let photo, photoAccess.photo(for: photo.localIdentifier) != nil {
            Section {
            HStack(spacing: 12) {
                PhotoAssetImageView(
                    localIdentifier: photo.localIdentifier,
                    catBoundingBox: photo.catBoundingBox,
                    targetPixelSize: CGSize(width: 240, height: 240),
                    showsFullImage: true
                )
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
                if let date = photo.creationDate {
                    Text(date.formatted(.dateTime.year().month().day()))
                        .font(.subheadline)
                }
            }
            }
        }
    }

    @ViewBuilder
    private var noteEditorSection: some View {
        if isLoaded && createsNewMemo && membershipAccess.enforcementEnabled
            && !hasCurrentPhoto {
            Section {
                Text("元の写真が見つかりません。写真へのアクセスを確かめて、写真を選び直してください。")
            }
        } else if isLoaded && notesFull {
            Section {
                LimitNote(PhotoMemoryNoteStoreError.limitReached.errorDescription ?? "")
            }
        } else if isLoaded {
            // 11/13: writing a memo (and its weight) is free for everyone.
            Section {
                PhotoNoteInput(text: $text, focus: $isWriting,
                    maximumCharacters: PhotoMemoryNoteStore.maximumCharacters,
                    audience: "自分だけ", identifier: "photo-memory-note-text", minimumHeight: 160)
                    .disabled(isSaving)
            }
            Section {
                Toggle("体重を添える", isOn: $weightEnabled).accessibilityIdentifier("memo-weight-toggle")
                if weightEnabled {
                    HStack {
                        TextField("体重", text: $weightKg).keyboardType(.decimalPad)
                            .focused($isMeasuring)
                            .accessibilityIdentifier("memo-weight-input")
                        Text("kg").foregroundStyle(.secondary)
                    }
                    if !weightKg.isEmpty && !validWeight { Text("kgで、小数点以下3けたまで入力できます。").font(.caption).foregroundStyle(.secondary) }
                    if !weightCats.isEmpty {
                        Picker("測定した猫", selection: $weightCatID) {
                            Text(weightCatID == nil && weightCatName != nil ? "\(weightCatName!)（どの子か選んでください）" : "選ばない").tag(Optional<UUID>.none)
                            ForEach(weightCats, id: \.id) { cat in Text(weightCatLabel(cat)).tag(Optional(cat.id)) }
                        }.onChange(of: weightCatID) { _, id in weightCatName = weightCats.first { $0.id == id }?.name }
                            .accessibilityIdentifier("memo-weight-cat-picker")
                    }
                    Toggle("測定日を指定", isOn: $weightDateKnown).accessibilityIdentifier("memo-weight-date-toggle")
                    if weightDateKnown { DatePicker("測定日", selection: $weightDate, displayedComponents: .date) }
                }
            }
                .disabled(isSaving)
        } else if loadFailed {
            Section {
                Text("メモを読み込めませんでした。")
                Button("もう一度読み込む") { Task { await load() } }
                    .disabled(isLoading)
            }
        } else {
            ProgressView("読み込んでいます…")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                notePhotoSection
                noteEditorSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("メモ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        isWriting = false; isMeasuring = false
                        if hasChanges { confirmsDiscard = true } else { dismiss() }
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("photo-memory-note-close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        isWriting = false; isMeasuring = false
                        if normalizedText.isEmpty && !weightEnabled && original != nil {
                            confirmsDelete = true
                        } else {
                            Task { await save(normalizedText) }
                        }
                    }
                    .disabled(!hasChanges || !validWeight || text.count > PhotoMemoryNoteStore.maximumCharacters || isSaving)
                    .accessibilityIdentifier("photo-memory-note-save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { isWriting = false; isMeasuring = false }
                        .accessibilityIdentifier("photo-memory-note-keyboard-done")
                }
            }
            .confirmationDialog("変更を保存せずに閉じますか？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("保存せずに閉じる", role: .destructive) { dismiss() }
                Button("編集を続ける", role: .cancel) {}
            }
            .confirmationDialog("この写真のメモを削除しますか？", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) { Task { await save("") } }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("写真は残り、メモの文章・体重・測定日が削除されます。")
            }
            .alert("メモを保存できませんでした", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text(saveError ?? "少し待ってから、もう一度お試しください。")
            }
            .interactiveDismissDisabled(hasChanges || isSaving)
            .task {
                photoAccess.start(photos: photo.map { [$0] } ?? [])
                await load()
#if DEBUG
                if CommandLine.arguments.contains("--memo-local-account-change-fixture") {
                    NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
                }
#endif
            }
            .onChange(of: photo) { _, value in photoAccess.start(photos: value.map { [$0] } ?? []) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { photoAccess.refresh() }
            }
            .onDisappear { photoAccess.stop() }
        }
        .appRecordEditing(retainWhileHidden: hasChanges || isSaving)
    }

    private func load() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded: PhotoMemoryNote?
            if let recordID {
                guard let record = try await store.record(id: recordID) else {
                    throw PhotoMemoryNoteStoreError.conflict
                }
                loaded = record.note
            } else if let photo {
                loaded = try await store.note(for: photo.localIdentifier)
            } else {
                throw PhotoMemoryNoteStoreError.invalidIdentifier
            }
            guard !Task.isCancelled else { return }
            original = loaded
            if let loaded { savedPhotoURL = try await store.photoURL(for: loaded.id) }
            else { notesFull = (try? await store.isFull()) ?? false }
            text = loaded?.text ?? ""
            loadWeight(loaded?.weight)
            loadFailed = false
            isLoaded = true
            // Opening an existing note first reads it; writing is always optional.
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }

    private func save(_ value: String) async {
        guard isLoaded, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let weightChange = PhotoMemoWeightChange.set(draftWeight)
            if let recordID, let original {
                _ = try await store.save(text: value, recordID: recordID,
                    expectedRevision: original.revision, weightChange: weightChange)
            } else if let photo {
                _ = try await store.save(text: value, for: photo.localIdentifier,
                    expectedRevision: original?.revision, context: context, weightChange: weightChange)
            } else { throw PhotoMemoryNoteStoreError.invalidIdentifier }
            if !value.isEmpty || weightEnabled { UsageCounter.shared.count(.photoMemoWritten) }  // Usage (11/7); empty is a delete
            onSaved()
            dismiss()
        } catch PhotoMemoryNoteStoreError.conflict {
            saveError = "ほかの画面でメモが変更されました。書いた文をコピーしてから、開き直してください。"
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription
                ?? "少し待ってから、もう一度お試しください。"
        }
    }
}
