import SwiftUI
import PhotosUI
import CoreTransferable
import CloudKit
import UniformTypeIdentifiers
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var records: [PersonalArchiveRecord] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showsComposer = false
    @State private var selectedRecord: PersonalArchiveRecord?
    @State private var viewGeneration = UUID()
    @State private var pendingCount = 0

    init(store: PersonalArchiveStore = .shared) { self.store = store }

    var body: some View {
        List {
            Section {
                Text("選んだ写真と言葉を、自分のiCloudに保管します。")
                Text("同じApple AccountのiPhoneから取り戻せます。iCloudの空き容量を使います。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } footer: {
                Text("内部テスト中です。写真は鑑賞用のコピーで、原本のバックアップではありません。")
            }

            Section {
                Button { showsComposer = true } label: {
                    Label("写真と言葉を選ぶ", systemImage: "plus")
                }
                .accessibilityIdentifier("personal-archive-compose")
                .disabled(isLoading || isWorking)
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
                Section("保管した記録") {
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
                ContentUnavailableView("まだ記録がありません", systemImage: "photo.on.rectangle",
                    description: Text("写真だけ、言葉だけでも保管できます。"))
            }
        }
        .navigationTitle("記録の保管")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(
            get: { selectedRecord != nil },
            set: { if !$0 { selectedRecord = nil } }
        )) {
            if let selectedRecord { PersonalArchiveRecordView(record: selectedRecord, store: store) }
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
        .sheet(isPresented: $showsComposer, onDismiss: {
            Task { await loadLocalRecords() }
        }) { PersonalArchiveComposer(store: store) }
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

private struct PersonalArchiveRecordView: View {
    let store: PersonalArchiveStore
    @Environment(\.dismiss) private var dismiss
    @State private var record: PersonalArchiveRecord
    @State private var account: String?
    @State private var editing = false
    @State private var confirmsDelete = false
    @State private var deleting = false
    @State private var deleteID = UUID()
    @State private var errorMessage: String?

    init(record: PersonalArchiveRecord, store: PersonalArchiveStore) {
        _record = State(initialValue: record)
        self.store = store
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let data = record.jpegData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("保管した写真")
                }
                if !record.text.isEmpty {
                    Text(record.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("保管日 \(record.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                archiveContext(capturedAt: record.capturedAt, context: record.context)
                Text(record.isDeletionPending ? "削除待ち・完了するまで、このiPhoneに内容を残しています" : record.state.archiveLabel)
                    .font(.caption).foregroundStyle(.secondary)
                if let issue = record.issue {
                    Text(personalArchiveMessage(for: issue)).font(.subheadline).foregroundStyle(.secondary)
                }
                if let remoteText = record.conflictingText {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("別の端末で変更された言葉").font(.headline)
                        Text(remoteText.isEmpty ? "言葉なし" : remoteText).textSelection(.enabled)
                        Text("上の手元の内容は上書きしていません。必要な言葉を控えてください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
                if deleting { ProgressView("削除しています…") }
            }.padding()
        }
        .navigationTitle("記録").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("言葉を編集", systemImage: "pencil") { editing = true }
                        .disabled(record.state != .stored && record.state != .partial || record.isDeletionPending)
                        .accessibilityIdentifier("personal-archive-edit")
                    Button("保管したコピーを削除", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                        .disabled(record.isDeletionPending || record.state == .conflict)
                        .accessibilityIdentifier("personal-archive-delete")
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("記録の操作")
                .accessibilityIdentifier("personal-archive-record-menu")
                .disabled(account == nil || deleting)
            }
        }
        .task {
            do { account = try await store.accountContext() }
            catch { errorMessage = personalArchiveMessage(for: error) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: DispatchQueue.main)) { _ in account = nil; editing = false; dismiss() }
        .sheet(isPresented: $editing) {
            if let account {
                PersonalArchiveTextEditor(record: record, store: store, account: account) { record = $0 }
            }
        }
        .confirmationDialog("保管したコピーを削除しますか？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("コピーを削除", role: .destructive) { Task { await delete() } }
        } message: {
            Text("iCloudとこのアプリの保管一覧から削除します。別のiPhoneには次の読み込み時に反映されます。写真アプリの原本、元のメモ、相手と共有したコピーは残ります。")
        }
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

private struct PersonalArchiveTextEditor: View {
    let record: PersonalArchiveRecord
    let store: PersonalArchiveStore
    let account: String
    let didUpdate: (PersonalArchiveRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var attempted = false
    @State private var operation = UUID()
    @State private var accountChanged = false
    @State private var errorMessage: String?
    @FocusState private var writing: Bool

    init(record: PersonalArchiveRecord, store: PersonalArchiveStore, account: String,
         didUpdate: @escaping (PersonalArchiveRecord) -> Void) {
        self.record = record; self.store = store; self.account = account; self.didUpdate = didUpdate
        _text = State(initialValue: record.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).frame(minHeight: 160).focused($writing)
                        .disabled(saving || attempted).accessibilityIdentifier("personal-archive-edit-text")
                } footer: { Text("\(text.count) / 500文字") }
                Text("保管したコピーの言葉を変更します。元のメモと共有済みの内容は変わりません。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if saving { ProgressView() }
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("言葉を編集").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(attempted ? "閉じる" : "キャンセル") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(attempted ? "再試行" : "保存") { Task { await save() } }
                        .disabled(saving || accountChanged || text.count > 500 ||
                                  (record.jpegData == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("personal-archive-edit-save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button("完了") { writing = false }
                }
            }
            .interactiveDismissDisabled(saving || text != record.text)
            .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)
                .receive(on: DispatchQueue.main)) { _ in
                accountChanged = true
                errorMessage = personalArchiveMessage(for: PersonalArchiveError.accountChanged)
            }
        }
    }

    @MainActor private func save() async {
        guard !saving, !accountChanged else { return }
        saving = true; attempted = true; writing = false
        defer { saving = false }
        do {
            let context = PersonalArchiveContext(writtenAt: record.context?.writtenAt,
                updatedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
                catNames: record.context?.catNames ?? [])
            // Keep operation metadata fixed on retries as well as its identifier.
            if editContext == nil { editContext = context }
            let updated = try await store.update(id: record.id, operationID: operation,
                expectedRevision: record.revision, text: text, capturedAt: record.capturedAt,
                context: editContext ?? context, expectedAccount: account)
            didUpdate(updated); dismiss()
        } catch { errorMessage = personalArchiveMessage(for: error) }
    }
    @State private var editContext: PersonalArchiveContext?
}

/// An explicit snapshot of an existing note. Opening it never enrolls data.
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
        case .stored: return "保管済み"
        case .changed: return "コピーを更新"
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
                        Text("元の写真を読み込めません。メモの言葉は保管できます。")
                        Button("写真をもう一度読み込む") { Task { await prepare() } }.disabled(attempted)
                        Button("言葉だけ保管する") { withoutPhoto = true }.disabled(attempted)
                            .accessibilityIdentifier("memory-note-archive-text-only")
                    }
                }
                Section {
                    Text(record.note.text).textSelection(.enabled)
                        .accessibilityIdentifier("memory-note-archive-preview")
                    archiveContext(capturedAt: record.note.context?.capturedAt, context: context)
                }
                Section {
                    Text("この内容を自分のiCloudに保管します。相手には送られません。")
                    if withoutPhoto { Text("写真を含めず、言葉と日付を保管します。") }
                    if status == .changed { Text("以前に保管したコピーを、この内容に更新します。") }
                    if status == .deleted { Text("削除したコピーとは別の記録として保管します。") }
                } footer: { Text("写真は鑑賞用のコピーです。原本のバックアップではありません。") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
                if saving { ProgressView("保管しています…") }
            }
            .navigationTitle("メモを保管").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("戻る") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(title) { Task { await preserve() } }
                        .disabled(preparing || !prepared || saving || invalidated || account == nil ||
                                  (jpeg == nil && !withoutPhoto) || (status == .stored && !attempted))
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
                bytes = try await Task.detached(priority: .userInitiated) {
                    var image: UIImage?
#if DEBUG
                    if CommandLine.arguments.contains("--memory-library-fixture") {
                        image = AppStoreScreenshotFixture.image(for: identifier)
                    }
#endif
                    if image == nil {
                        image = PhotoImageLoader().image(localIdentifier: identifier,
                            targetSize: CGSize(width: 4096, height: 4096), contentMode: .aspectFit)
                    }
                    guard let raw = image?.jpegData(compressionQuality: 0.96) else { return nil as Data? }
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
            let result = try await archiveStore.preserve(source: source, jpegData: withoutPhoto ? nil : jpeg,
                text: record.note.text, capturedAt: record.note.context?.capturedAt, context: context,
                expectedAccount: account, recreateDeleted: status == .deleted)
            if result.state == .stored { dismiss() }
            else { errorMessage = result.state.archiveLabel }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? personalArchiveMessage(for: error)
        }
    }
}

private struct PersonalArchivePickedPhoto: Transferable {
    let jpegData: Data
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            Self(jpegData: try PersonalArchiveImage.jpeg(from: file.file))
        }
    }
}

private struct PersonalArchiveComposer: View {
    let store: PersonalArchiveStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var showsPhotoPicker = false
    @State private var jpegData: Data?
    @State private var text = ""
    @State private var isPreparing = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmsDiscard = false
    @State private var selectionVersion = UUID()
    @State private var accountContext: String?
    @State private var accountChanged = false
    @State private var saveID = UUID()
    @State private var hasAttemptedSave = false
    @FocusState private var isWriting: Bool

    var body: some View {
        NavigationStack {
            composerForm
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("保管する記録").navigationBarTitleDisplayMode(.inline)
            .toolbar { composerToolbar }
            .interactiveDismissDisabled(jpegData != nil || !text.isEmpty || isSaving)
            .confirmationDialog(hasAttemptedSave ? "この画面を閉じますか？" : "入力を取り消しますか？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                discardActions
            } message: {
                if hasAttemptedSave { Text("このiPhoneに保存済みの記録は、画面を閉じても削除されません。") }
            }
            .onChange(of: selection) { _, item in Task { await prepare(item) } }
            .task {
                do { accountContext = try await store.accountContext() }
                catch { errorMessage = personalArchiveMessage(for: error) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)
                .receive(on: DispatchQueue.main)) { _ in
                accountChanged = true
                errorMessage = "Apple Accountの状態が変わったため、保管を止めました。入力内容はこの画面に残っています。元のアカウントを確認してください。"
            }
        }
        // Keep the system presentation attached to this stable screen, rather
        // than to a Form row that SwiftUI can rebuild during sheet layout.
        .photosPicker(isPresented: $showsPhotoPicker, selection: $selection,
                      matching: .images, preferredItemEncoding: .current)
    }

    private var composerForm: some View {
        Form {
            photoSection
            textSection
            privacySection
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            if isSaving { ProgressView("保管しています…") }
        }
    }

    private var photoSection: some View {
        Section {
            if let jpegData, let image = UIImage(data: jpegData) {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel("保管する写真")
            }
            Button {
                isWriting = false
                showsPhotoPicker = true
            } label: {
                Label(jpegData == nil ? "写真を選ぶ" : "写真を選び直す", systemImage: "photo")
            }.disabled(isSaving || isPreparing || hasAttemptedSave)
            if jpegData != nil {
                Button("写真を外す") { selection = nil; jpegData = nil; selectionVersion = UUID() }
                    .disabled(isSaving || isPreparing || hasAttemptedSave)
            }
            if isPreparing { ProgressView("写真を準備しています…") }
        }
    }

    private var textSection: some View {
        Section {
            TextEditor(text: $text).frame(minHeight: 140)
                .focused($isWriting).disabled(isSaving || hasAttemptedSave)
                .accessibilityLabel("保管する言葉")
                .accessibilityIdentifier("personal-archive-text")
        } header: {
            Text("言葉（任意）")
        } footer: {
            Text("\(text.count) / 500文字")
        }
    }

    private var privacySection: some View {
        Section {
            Text("この内容を自分のiCloudに保管します。相手には送られません。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ToolbarContentBuilder
    private var composerToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("戻る") {
                isWriting = false
                if jpegData != nil || !text.isEmpty { confirmsDiscard = true } else { dismiss() }
            }.disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(hasAttemptedSave ? "再試行" : "保管") { Task { await save() } }
                .disabled(saveDisabled)
                .accessibilityIdentifier("personal-archive-save")
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("完了") { isWriting = false }
        }
    }

    private var saveDisabled: Bool {
        isSaving || isPreparing || accountContext == nil || accountChanged || text.count > 500 ||
            (jpegData == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @ViewBuilder
    private var discardActions: some View {
        if hasAttemptedSave {
            Button("閉じる") { dismiss() }
        } else {
            Button("取り消して戻る", role: .destructive) { dismiss() }
        }
        Button("入力を続ける", role: .cancel) { }
    }

    @MainActor private func prepare(_ item: PhotosPickerItem?) async {
        let version = UUID(); selectionVersion = version
        guard let item else { return }
        isPreparing = true
        defer { if selectionVersion == version { isPreparing = false } }
        do {
            guard let photo = try await item.loadTransferable(type: PersonalArchivePickedPhoto.self) else {
                throw PersonalArchiveImage.PreparationError.unreadable
            }
            guard selectionVersion == version else { return }
            jpegData = photo.jpegData
            errorMessage = nil
        } catch {
            guard selectionVersion == version else { return }
            errorMessage = "写真を準備できませんでした。もう一度選んでください。"
            selection = nil
        }
    }

    @MainActor private func save() async {
        guard let accountContext, !accountChanged else { return }
        isWriting = false
        isSaving = true
        hasAttemptedSave = true
        defer { isSaving = false }
        do {
            // Only this explicit action enrolls this immutable copy.
            _ = try await store.save(id: saveID, jpegData: jpegData, text: text, capturedAt: nil,
                                     expectedAccount: accountContext)
            dismiss()
        } catch { errorMessage = personalArchiveMessage(for: error) }
    }
}

#if DEBUG
/// Runs the shipping AppRoot/MainTab and settings/composer lifecycle with a
/// large, changing library. Only external library input and archive transport
/// are fixtures; catalog scheduling, view identity and scene handling are real.
@MainActor
struct PersonalArchiveUIFixture: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var driver = PersonalArchiveRootFixtureDriver()

    var body: some View {
        AppRootView(viewModel: driver.viewModel, personalArchiveStore: driver.archiveStore)
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
