import SwiftUI
import CloudKit
import ImageIO
import Photos

private func personalArchiveMessage(for error: Error) -> String {
    (error as? PersonalArchiveError)?.errorDescription
        ?? "記録を処理できませんでした。もう一度お試しください。"
}

/// An internal, opt-in CloudKit pilot. Existing photos and notes are never
/// enrolled by opening this screen. Changes to copies are explicit operations.
struct PersonalArchiveView: View {
    let store: PersonalArchiveStore
    let noteStore: PhotoMemoryNoteStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var records: [PersonalArchiveRecord] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var selectedRecord: PersonalArchiveRecord?
    @State private var viewGeneration = UUID()
    @State private var pendingCount = 0

    init(store: PersonalArchiveStore = .shared, noteStore: PhotoMemoryNoteStore = .shared) {
        self.store = store; self.noteStore = noteStore
    }

    var body: some View {
        List {
            Section {
                Text("選んだ写真とメモの保管状況を確認できます。")
                Text("同じApple AccountのiPhoneから取り戻せます。iCloudの空き容量を使います。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } footer: {
                Text("写真の「…」から保管を始められます。写真は閲覧用のコピーです。")
            }

            Section {
                Button { Task { await updateFromCloud() } } label: {
                    Label("iCloudから読み込む", systemImage: "icloud.and.arrow.down")
                }
                .accessibilityIdentifier("personal-archive-refresh")
                .disabled(isLoading || isWorking)
                if pendingCount > 0 {
                    Button("未完了の操作を再試行") { Task { await retryPending() } }
                        .accessibilityIdentifier("personal-archive-retry")
                        .disabled(isLoading || isWorking)
                }
            }

            if isLoading || isWorking {
                ProgressView(isLoading ? "読み込んでいます…" : "iCloudと通信しています…")
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.secondary) }
            }

            if !records.isEmpty {
                Section("保管した写真とメモ") {
                    ForEach(records) { record in
                        Button { selectedRecord = record } label: {
                            HStack {
                                recordRow(record)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("personal-archive-record-\(record.id.uuidString)")
                    }
                }
            } else if !isLoading && errorMessage == nil {
                ContentUnavailableView("保管した写真はありません", systemImage: "photo.on.rectangle",
                    description: Text("メモを付けた写真の「…」から、iCloudに保管できます。"))
            }
        }
        .navigationTitle("iCloudの保管と復元")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(
            get: { selectedRecord != nil },
            set: { if !$0 { selectedRecord = nil } }
        )) {
            if let selectedRecord { PersonalArchiveRecordView(record: selectedRecord, store: store, noteStore: noteStore) }
        }
        .task { await loadLocalRecords() }
        .onChange(of: selectedRecord) { _, value in
            if value == nil { Task { await loadLocalRecords() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                records = []; selectedRecord = nil; viewGeneration = UUID()
                isLoading = false; isWorking = false
            }
            else { Task { await loadLocalRecords() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: DispatchQueue.main)) { _ in
            records = []
            selectedRecord = nil
            viewGeneration = UUID()
            isLoading = false; isWorking = false
            Task { await loadLocalRecords() }
        }
    }

    private func recordRow(_ record: PersonalArchiveRecord) -> some View {
        HStack(spacing: 12) {
            if let data = record.jpegData, let image = archiveThumbnail(data) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 64, height: 64).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "text.alignleft")
                    .frame(width: 64, height: 64).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.text.isEmpty ? "写真" : record.text).lineLimit(2)
                Text(record.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
                if record.isDeletionPending || record.state != .stored {
                    Text(record.isDeletionPending ? "削除待ち" : record.state.archiveLabel)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func archiveThumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 192
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    @MainActor private func loadLocalRecords() async {
        let generation = viewGeneration
        isLoading = true
        defer { if generation == viewGeneration { isLoading = false } }
        do {
            let loaded = try await store.records()
            let pending = try await store.pendingOperationCount()
            guard generation == viewGeneration else { return }
            records = loaded; pendingCount = pending; errorMessage = nil
        } catch {
            guard generation == viewGeneration else { return }
            records = []; errorMessage = personalArchiveMessage(for: error)
        }
    }

    @MainActor private func updateFromCloud() async {
        let generation = viewGeneration
        isWorking = true
        defer { if generation == viewGeneration { isWorking = false } }
        do {
            let loaded = try await store.refresh()
            let account = try await store.accountContext()
            try await PhotoMemoCoordinator(noteStore: noteStore, archiveStore: store)
                .reconcile(expectedAccount: account)
            let pending = try await store.pendingOperationCount()
            guard generation == viewGeneration else { return }
            records = loaded; pendingCount = pending; errorMessage = nil
        } catch {
            let local = try? await store.records()
            guard generation == viewGeneration else { return }
            records = local ?? []; errorMessage = personalArchiveMessage(for: error)
        }
    }

    @MainActor private func retryPending() async {
        let generation = viewGeneration
        isWorking = true
        defer { if generation == viewGeneration { isWorking = false } }
        do {
            try await store.retryPending()
            let account = try await store.accountContext()
            try await PhotoMemoCoordinator(noteStore: noteStore, archiveStore: store)
                .retryUpdates(expectedAccount: account)
            let loaded = try await store.records()
            let pending = try await store.pendingOperationCount()
            guard generation == viewGeneration else { return }
            records = loaded
            pendingCount = pending
            errorMessage = nil
        } catch {
            let local = try? await store.records()
            guard generation == viewGeneration else { return }
            records = local ?? []; errorMessage = personalArchiveMessage(for: error)
        }
    }
}

private extension PersonalArchiveRecordState {
    var archiveLabel: String {
        switch self {
        case .pending: "保管待ち・このiPhoneに保存されています"
        case .stored: "iCloudに保管済み"
        case .partial: "写真を取り戻せていません"
        case .conflict: "保管先の内容を確認できませんでした"
        }
    }
}

struct PersonalArchiveRecordView: View {
    let store: PersonalArchiveStore
    let noteStore: PhotoMemoryNoteStore
    private let expectedAccount: String?
    @Environment(\.dismiss) private var dismiss
    @State private var record: PersonalArchiveRecord
    @State private var account: String?
    @State private var editing = false
    @State private var confirmsDelete = false
    @State private var deleting = false
    @State private var deleteID = UUID()
    @State private var errorMessage: String?

    init(record: PersonalArchiveRecord, store: PersonalArchiveStore, expectedAccount: String? = nil,
         noteStore: PhotoMemoryNoteStore = .shared) {
        _record = State(initialValue: record)
        self.store = store
        self.expectedAccount = expectedAccount
        self.noteStore = noteStore
    }

    @State private var resolutionChoice: Bool?
    @State private var resolutionID = UUID()
    @State private var localNoteRevision: String?
    @State private var localNoteText: String?
    @State private var resolving = false

    var body: some View {
        Group {
            if expectedAccount != nil && account == nil {
                ProgressView()
            } else {
            PhotoMemoDetailContent(text: record.state == .conflict ? (localNoteText ?? record.text) : record.text, capturedAt: record.capturedAt,
                writtenAt: record.context?.writtenAt, fallbackDate: record.createdAt) {
                if let data = record.jpegData {
                    MemoArchivePhoto(data: data, allowsExpansion: true)
                }
            } status: {
                if record.isDeletionPending || record.state != .stored {
                Text(record.isDeletionPending ? "削除待ち・完了するまで、このiPhoneに内容を残しています" : record.state.archiveLabel)
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let issue = record.issue {
                    Text(personalArchiveMessage(for: issue)).font(.subheadline).foregroundStyle(.secondary)
                }
                if let remoteText = record.conflictingText {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("別の変更があります").font(.headline)
                        Text(remoteText.isEmpty ? "メモなし" : remoteText).textSelection(.enabled)
                        Text("どちらの内容も残しています。必要な内容を確認してください。")
                            .font(.caption).foregroundStyle(.secondary)
                        if record.state == .conflict, record.conflictingRevision != nil {
                            Button("このiPhoneのメモを使う") { resolutionID = UUID(); resolutionChoice = false }
                                .disabled(resolving)
                            Button("別の端末のメモを使う") { resolutionID = UUID(); resolutionChoice = true }
                                .disabled(resolving)
                        }
                    }
                }
                if record.state == .conflict && record.conflictingRevision == nil {
                    Button("iCloudの変更を確認") { Task { await refreshConflict() } }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
                if deleting || resolving { ProgressView() }
            }
            }
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel(record.text.isEmpty ? "メモを書く" : "メモを編集")
                    .accessibilityIdentifier("memory-note-edit")
                    .disabled(account == nil || deleting || resolving || record.isDeletionPending || record.state == .conflict)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Text(record.state.archiveLabel)
                    Button("保管したコピーを削除", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                        .disabled(record.isDeletionPending || record.state == .conflict)
                        .accessibilityIdentifier("personal-archive-delete")
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("メモの操作")
                .accessibilityIdentifier("personal-archive-record-menu")
                .disabled(account == nil || deleting || resolving)
            }
        }
        .task {
            do {
                let current = try await store.accountContext()
                guard expectedAccount == nil || current == expectedAccount else { dismiss(); return }
                account = current
                await loadLocalRevision(account: current)
            } catch {
                if expectedAccount != nil { dismiss() }
                else { errorMessage = personalArchiveMessage(for: error) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: DispatchQueue.main)) { _ in account = nil; editing = false; dismiss() }
        .sheet(isPresented: $editing, onDismiss: { Task { await reloadAfterEdit() } }) {
            if let account {
                PhotoMemoryNoteEditor(archiveRecord: record, archiveStore: store,
                                      account: account, noteStore: noteStore) { record = $0 }
            }
        }
        .confirmationDialog("この内容でメモを揃えますか？", isPresented: Binding(
            get: { resolutionChoice != nil }, set: { if !$0 { resolutionChoice = nil } }
        ), titleVisibility: .visible) {
            let choice = resolutionChoice ?? false
            Button("このメモを使う") {
                resolutionChoice = nil
                Task { await resolveConflict(chooseRemote: choice) }
            }
            Button("戻る", role: .cancel) { resolutionChoice = nil }
        } message: {
            Text(resolutionChoice == true ? (record.conflictingText ?? "メモなし") : ((localNoteText ?? record.text).isEmpty ? "メモなし" : (localNoteText ?? record.text)))
        }
        .confirmationDialog("保管したコピーを削除しますか？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("コピーを削除", role: .destructive) { Task { await delete() } }
        } message: {
            Text("iCloudとこのアプリの保管一覧から削除します。別のiPhoneには次の読み込み時に反映されます。写真アプリの原本、元のメモ、相手と共有したコピーは残ります。")
        }
    }

    @MainActor private func reloadAfterEdit() async {
        guard let account else { return }
        do {
            let snapshot = try await store.readingSnapshot(expectedAccount: account)
            guard let latest = snapshot.records.first(where: { $0.id == record.id }) else {
                dismiss(); return
            }
            record = latest
            await loadLocalRevision(account: account)
        } catch { errorMessage = personalArchiveMessage(for: error) }
    }

    @MainActor private func loadLocalRevision(account: String) async {
        do {
            let identity = try await store.verifiedAccount(expectedAccount: account)
            let bindings = try await noteStore.archiveBindings()
            if let binding = bindings.first(where: { $0.accountKey == identity.key && $0.recordID == record.id }) {
                let local = try await noteStore.record(id: binding.noteID)
                localNoteRevision = local?.note.revision
                localNoteText = local?.note.text ?? ""
            } else { localNoteRevision = nil; localNoteText = nil }
        } catch { errorMessage = personalArchiveMessage(for: error) }
    }

    @MainActor private func refreshConflict() async {
        guard let account, !resolving else { return }
        resolving = true; defer { resolving = false }
        do {
            _ = try await store.verifiedAccount(expectedAccount: account)
            _ = try await store.refresh()
            let snapshot = try await store.readingSnapshot(expectedAccount: account)
            if let latest = snapshot.records.first(where: { $0.id == record.id }) { record = latest }
            await loadLocalRevision(account: account)
        } catch { errorMessage = personalArchiveMessage(for: error) }
    }

    @MainActor private func resolveConflict(chooseRemote: Bool) async {
        guard let account, !resolving else { return }
        resolving = true; defer { resolving = false }
        do {
            let result = try await PhotoMemoCoordinator(noteStore: noteStore, archiveStore: store)
                .resolveConflict(record: record, chooseRemote: chooseRemote, operationID: resolutionID,
                    expectedAccount: account, expectedLocalNoteRevision: localNoteRevision)
            if let updated = result.archiveRecord { record = updated }
            if result.reflection == .stored { errorMessage = nil }
            else { errorMessage = "このiPhoneに保存しました。iCloudへの反映はまだ完了していません。" }
            await loadLocalRevision(account: account)
        } catch { errorMessage = personalArchiveMessage(for: error) }
    }

    @MainActor private func delete() async {
        guard let account, !deleting else { return }
        deleting = true
        defer { deleting = false }
        do {
            let result = try await store.delete(id: record.id, operationID: deleteID,
                expectedRevision: record.revision, expectedAccount: account)
            if result == .stored { dismiss(); return }
            if let latest = try await store.records().first(where: { $0.id == record.id }) { record = latest }
        } catch {
            if let latest = try? await store.records().first(where: { $0.id == record.id }) { record = latest }
            errorMessage = personalArchiveMessage(for: error)
        }
    }
}

@ViewBuilder
private func archiveContext(capturedAt: Date?, context: PersonalArchiveContext?) -> some View {
    if capturedAt != nil || context != nil {
        VStack(alignment: .leading, spacing: 6) {
            if let date = capturedAt { Text("撮影 \(date.formatted(date: .abbreviated, time: .omitted))") }
            if let date = context?.writtenAt { Text("書いた日 \(date.formatted(date: .abbreviated, time: .omitted))") }
            if let names = context?.catNames, !names.isEmpty { Text(names.joined(separator: "・")) }
        }.font(.caption).foregroundStyle(.secondary)
    }
}

/// Explicit consent for this photo and memo; opening never enables reflection.
struct PhotoMemoryNoteArchiveView: View {
    let record: PhotoMemoryNoteRecord
    let photos: [PhotoPresentation]
    let noteStore: PhotoMemoryNoteStore
    let archiveStore: PersonalArchiveStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var jpeg: Data?
    @State private var preparing = false
    @State private var prepared = false
    @State private var withoutPhoto = false
    @State private var saving = false
    @State private var attempted = false
    @State private var account: String?
    @State private var invalidated = false
    @State private var generation = UUID()
    @State private var status: PersonalArchivePreservationStatus = .localOnly
    @State private var errorMessage: String?

    private var source: PersonalArchiveSourceSnapshot {
        .init(noteID: record.id, revision: record.note.revision, photoIdentifier: record.photoIdentifier)
    }
    private var context: PersonalArchiveContext {
        .init(writtenAt: record.note.writtenAt, updatedAt: record.note.updatedAt,
              catNames: record.note.context?.cats.map(\.name) ?? [])
    }
    private var title: String {
        if attempted { return "再試行" }
        switch status {
        case .stored: return "変更も反映する"
        case .changed: return "内容を確認して反映"
        case .deleted: return "新しく保管"
        default: return "保管"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let jpeg, let image = UIImage(data: jpeg), !withoutPhoto {
                    Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("保管する写真")
                } else if preparing { ProgressView("写真を準備しています…") }
                else if prepared && !withoutPhoto {
                    Section {
                        Text("元の写真を読み込めません。メモだけなら保管できます。")
                        Button("写真をもう一度読み込む") { Task { await prepare() } }.disabled(attempted)
                        Button("メモだけ保管") { withoutPhoto = true }.disabled(attempted)
                            .accessibilityIdentifier("memory-note-archive-text-only")
                    }
                }
                Section {
                    Text(record.note.text).textSelection(.enabled)
                        .accessibilityIdentifier("memory-note-archive-preview")
                    archiveContext(capturedAt: record.note.context?.capturedAt, context: context)
                }
                Section {
                    Text("この写真とメモを自分のiCloudに保管します。これからのメモの変更も反映します。")
                    if withoutPhoto { Text("写真を含めず、メモと日付を保管します。") }
                    if status == .changed { Text("以前の保管内容と異なります。別の内容を上書きする前に確認が必要です。") }
                    if status == .deleted { Text("削除したコピーとは別の記録として保管します。") }
                } footer: { Text("写真は鑑賞用のコピーです。原本のバックアップではありません。") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
                if saving { ProgressView("保管しています…") }
            }
            .navigationTitle("iCloudに保管").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("戻る") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(title) { Task { await preserve() } }
                        .disabled(preparing || !prepared || saving || invalidated || account == nil ||
                                  (jpeg == nil && !withoutPhoto))
                        .accessibilityIdentifier("memory-note-archive-save")
                }
            }
            .interactiveDismissDisabled(saving)
            .task { access.start(photos: photos); await prepare() }
            .onChange(of: photos) { _, value in
                access.start(photos: value)
                if access.photo(for: record.photoIdentifier) == nil && !attempted { jpeg = nil; withoutPhoto = false }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background && preparing { generation = UUID(); preparing = false; prepared = false }
                if phase == .active { access.refresh(); if !prepared && !attempted { Task { await prepare() } } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)
                .receive(on: DispatchQueue.main)) { _ in
                invalidated = true; generation = UUID(); preparing = false
                errorMessage = personalArchiveMessage(for: PersonalArchiveError.accountChanged)
            }
            .onDisappear { access.stop(); generation = UUID() }
        }
    }

    @MainActor private func prepare() async {
        guard !attempted, !saving, !invalidated else { return }
        let token = UUID(); generation = token; preparing = true; prepared = false
        jpeg = nil; withoutPhoto = false; errorMessage = nil
        defer { if generation == token { preparing = false; prepared = true } }
        do {
            let identity = try await archiveStore.accountContext()
            let identifier = access.photo(for: record.photoIdentifier)?.localIdentifier
            let bytes: Data?
            if let identifier {
#if DEBUG
                let fixtureJPEG = CommandLine.arguments.contains("--memory-library-fixture")
                    ? AppStoreScreenshotFixture.image(for: identifier)?.jpegData(compressionQuality: 0.96) : nil
#else
                let fixtureJPEG: Data? = nil
#endif
                bytes = try await Task.detached(priority: .userInitiated) {
                    let raw = fixtureJPEG ?? PhotoImageLoader().image(localIdentifier: identifier,
                        targetSize: CGSize(width: 4096, height: 4096), contentMode: .aspectFit)?.jpegData(compressionQuality: 0.96)
                    guard let raw else { return nil as Data? }
                    return try PersonalArchiveImage.jpeg(from: raw)
                }.value
            } else { bytes = nil }
            guard generation == token, !invalidated else { return }
            access.refresh()
            jpeg = access.photo(for: record.photoIdentifier) == nil ? nil : bytes
            account = identity
            let currentStatus = try await archiveStore.preservationStatus(source: source, jpegData: jpeg, expectedAccount: identity)
            guard generation == token, !invalidated else { return }
            status = currentStatus
        } catch {
            guard generation == token else { return }
            errorMessage = personalArchiveMessage(for: error)
        }
    }

    @MainActor private func preserve() async {
        guard let account, !saving, !invalidated else { return }
        saving = true
        defer { saving = false }
        do {
            guard try await noteStore.record(id: record.id) == record else {
                throw PhotoMemoryNoteStoreError.conflict
            }
            access.refresh()
            guard withoutPhoto || access.photo(for: record.photoIdentifier) != nil else {
                jpeg = nil
                throw PersonalArchiveImage.PreparationError.unreadable
            }
            attempted = true
            let result = try await PhotoMemoCoordinator(noteStore: noteStore, archiveStore: archiveStore)
                .enableUpdates(for: record, jpegData: withoutPhoto ? nil : jpeg,
                               expectedAccount: account, recreateDeleted: status == .deleted)
            if result.reflection == .stored { dismiss() }
            else { errorMessage = "このiPhoneに保存しました。iCloudへの反映はまだ完了していません。" }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? personalArchiveMessage(for: error)
        }
    }
}

#if DEBUG
/// Runs the shipping AppRoot/MainTab and settings/record lifecycle with a
/// large, changing library. Only external library input and archive transport
/// are fixtures; catalog scheduling, view identity and scene handling are real.
@MainActor
struct PersonalArchiveUIFixture: View {
    private static let noteStore = PhotoMemoryNoteStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonalArchiveUIFixture/\(UUID().uuidString)/notes.json"))
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var driver = PersonalArchiveRootFixtureDriver()

    var body: some View {
        AppRootView(viewModel: driver.viewModel, personalArchiveStore: driver.archiveStore)
            .environment(\.photoMemoStore, Self.noteStore)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    Text("進捗")
                        .accessibilityIdentifier("archive-root-fixture-progress")
                        .accessibilityValue(String(driver.progressUpdates))
                    Button("内容更新") { driver.changePhotoContent() }
                        .accessibilityIdentifier("archive-root-fixture-content")
                    Button("写真削除") { driver.removeProbePhoto() }
                        .accessibilityIdentifier("archive-root-fixture-remove")
                    Button(driver.hasPhotoAccess ? "権限を外す" : "権限を戻す") {
                        driver.togglePhotoAccess()
                    }
                    .accessibilityIdentifier("archive-root-fixture-access")
                    .accessibilityValue(driver.hasPhotoAccess ? "allowed" : "denied")
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .padding(4)
                .background(.regularMaterial)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await driver.publishProgress()
            }
    }
}

@MainActor
private final class PersonalArchiveRootFixtureDriver: ObservableObject {
    let viewModel: AppViewModel
    let archiveStore: PersonalArchiveStore
    @Published private(set) var progressUpdates = 0
    @Published private(set) var hasPhotoAccess = true
    private var snapshot: LibrarySnapshot
    private var contentTask: Task<Void, Never>?

    init() {
        let seed = Self.makeSnapshot()
        snapshot = seed
        viewModel = AppViewModel(uiFixtureSnapshot: seed, uiFixtureIdentity: Self.makeIdentity(for: seed))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
            UIColor.systemBrown.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            UIImage(systemName: "pawprint.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 100, y: 50, width: 200, height: 200))
        }
        let jpeg = image.jpegData(compressionQuality: 0.9)!
        let payload = PersonalArchivePayload(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            text: "はじめて窓辺で眠った日", createdAt: Date(timeIntervalSince1970: 1_789_700_000),
            capturedAt: nil, jpegSHA256: PersonalArchiveFiles.digest(jpeg), jpegByteCount: jpeg.count)
        archiveStore = PersonalArchiveStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("personal-archive-ui-\(UUID().uuidString)", isDirectory: true),
            transport: PersonalArchiveFixtureTransport(record: .init(payload: payload, jpegData: jpeg)))
    }

    func publishProgress() async {
        // No library content changes here. Frequent published scan snapshots
        // must not cancel/restart a prepared catalog or hide its ready content.
        // Finite bursts preserve XCTest's eventual idle boundary. Foreground
        // entry repeats the burst while the real composer sheet remains open.
        for _ in 0..<30 {
            guard !Task.isCancelled else { return }
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            progressUpdates += 1
            snapshot.scanState.scannedAssets = 6_000 + progressUpdates
            snapshot.scanState.scanDurationMilliseconds = Double(progressUpdates * 200)
            publish()
        }
    }

    func changePhotoContent() {
        guard contentTask == nil else { return }
        contentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.contentTask = nil }
            // Several real edits arrive during one delayed catalog build. The
            // latest version must complete without replacing ready UI by a spinner.
            for _ in 0..<6 {
                guard !Task.isCancelled, self.snapshot.assets.count > 1 else { return }
                self.snapshot.assets[1].creationDate = self.snapshot.assets[1].creationDate?
                    .addingTimeInterval(60)
                self.publish()
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch { return }
            }
        }
    }

    func removeProbePhoto() {
        snapshot.assets.removeAll { $0.localIdentifier == "app-store-screenshot-fixture-page-1" }
        snapshot.scanState.catAssets = snapshot.assets.count
        publish()
    }

    func togglePhotoAccess() {
        hasPhotoAccess.toggle()
        viewModel.setUIFixturePhotoAccess(hasPhotoAccess)
    }

    private func publish() {
        snapshot.updatedAt = .now
        viewModel.updateUIFixtureSnapshot(snapshot)
    }

    private static func makeSnapshot() -> LibrarySnapshot {
        var result = LibrarySnapshot.empty
        let capturedAt = Date(timeIntervalSince1970: 1_789_700_000)
        let box = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        result.assets = (1...6_000).map { index in
            AssetRecord(
                localIdentifier: "app-store-screenshot-fixture-page-\(index)",
                creationDate: capturedAt.addingTimeInterval(-Double(index - 1) * 86_400),
                isFavorite: false, isScreenshot: false, burstIdentifier: nil,
                cat: CatDetection(detected: true, confidence: 0.99, boundingBox: box,
                                  areaRatio: 0.64, catCount: 1, instanceBoundingBoxes: [box]),
                analysisStatus: .detected, analysisFingerprint: result.settings.analysisFingerprint,
                analyzedAt: capturedAt, albumAnalysisVersion: CatAlbumTraits.currentAnalysisVersion,
                albumTraits: CatAlbumTraits(postures: [.curled], containsPerson: index % 3 == 0,
                                            isOuting: false, largestCatAreaRatio: 0.64,
                                            analyzedAt: capturedAt)
            )
        }
        result.scanState.phase = .fullScan
        result.scanState.resultKind = .provisional
        result.scanState.totalAssets = 60_000
        result.scanState.scannedAssets = 6_000
        result.scanState.catAssets = result.assets.count
        result.scanState.widgetEligibleAssets = result.assets.count
        result.scanState.oldestCatPhotoDate = result.assets.last?.creationDate
        result.updatedAt = capturedAt
        return result
    }

    private static func makeIdentity(for snapshot: LibrarySnapshot) -> CatHouseholdIdentityState {
        let ids = [UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                   UUID(uuidString: "33333333-3333-4333-8333-333333333333")!]
        let profiles = ids.enumerated().map { index, id in
            CatProfile(id: id, displayName: index == 0 ? "ミケ" : "ソラ",
                       keyPhotoLocalIdentifier: snapshot.assets[index * 3_000].localIdentifier,
                       createdAt: snapshot.updatedAt, updatedAt: snapshot.updatedAt)
        }
        let memberships = snapshot.assets.enumerated().map { index, photo in
            CatAssetProfileMembership(assetLocalIdentifier: photo.localIdentifier,
                profileID: ids[index / 3_000], decision: .included,
                subjectBoundingBox: photo.cat.boundingBox, decidedAt: snapshot.updatedAt)
        }
        return CatHouseholdIdentityState(mode: .profiled, profiles: profiles,
            memberships: memberships, globalExcludedAssets: [], legacyUnscoped: nil,
            createdAt: snapshot.updatedAt, updatedAt: snapshot.updatedAt)
    }
}

actor PersonalArchiveFixtureTransport: PersonalArchiveTransport {
    private let identity = PersonalArchiveAccount(key: PersonalArchiveFiles.digest(Data("fixture-account".utf8)), generation: 0)
    private let generation = UUID()
    private var remote: [UUID: PersonalArchiveRemoteRecord]
    init(record: PersonalArchiveRemoteRecord? = nil) {
        remote = record.map { [$0.payload.id: $0] } ?? [:]
    }
    func account() async throws -> PersonalArchiveAccount { identity }
    func isCurrent(_ account: PersonalArchiveAccount) async -> Bool { account == identity }
    func prepareZone(for account: PersonalArchiveAccount, allowCreation: Bool, expectedGeneration: UUID?) async throws -> UUID {
        guard account == identity else { throw PersonalArchiveError.accountChanged }
        guard expectedGeneration == nil || expectedGeneration == generation else { throw PersonalArchiveError.archiveChanged }
        return generation
    }
    func upload(_ payload: PersonalArchivePayload, jpegData: Data?, account: PersonalArchiveAccount, generation: UUID) async throws {
        try await commit(payload, jpegData: jpegData, precondition: .create, account: account, generation: generation)
    }
    func commit(_ payload: PersonalArchivePayload, jpegData: Data?, precondition: PersonalArchivePrecondition,
                account: PersonalArchiveAccount, generation: UUID) async throws {
        guard account == identity else { throw PersonalArchiveError.accountChanged }
        guard generation == self.generation else { throw PersonalArchiveError.archiveChanged }
        if let existing = remote[payload.id] {
            if existing.payload == payload { return }
            guard precondition.expectedRevisions.contains(existing.payload.fingerprint) else { throw PersonalArchiveError.conflict }
        } else if !precondition.allowsCreation { throw PersonalArchiveError.conflict }
        remote[payload.id] = .init(payload: payload, jpegData: jpegData)
    }
    func fetch(account: PersonalArchiveAccount, expectedGeneration: UUID?) async throws -> PersonalArchiveRemoteSnapshot {
        guard account == identity else { throw PersonalArchiveError.accountChanged }
        guard expectedGeneration == nil || expectedGeneration == generation else { throw PersonalArchiveError.archiveChanged }
        return .init(generation: generation, records: Array(remote.values), deletedIDs: [])
    }
}
#endif
