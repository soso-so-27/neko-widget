import SwiftUI
import AuthenticationServices
import ImageIO

/// Standalone, default-OFF entry. The host must explicitly supply a selected copy;
/// opening this screen never enumerates or automatically uploads a photo library.
@MainActor
struct ManagedPreservationView: View {
    @StateObject private var coordinator: ManagedPreservationCoordinator
    @StateObject private var exporter: RecordExportController
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsDeletion = false
    @State private var needsResume = false

    init(configuration: ManagedPreservationConfiguration = .current,
         draft: ManagedPreservationDraft? = nil) {
        let exporter = RecordExportController()
        _exporter = StateObject(wrappedValue: exporter)
        _coordinator = StateObject(wrappedValue: ManagedPreservationCoordinator(
            configuration: configuration, draft: draft, onExport: { snapshot, validate in
                ManagedPreservationExport.prepare(snapshot, using: exporter, validate: validate)
            }))
    }

    var body: some View {
        Group {
            if coordinator.isEnabled { content }
            else {
                ContentUnavailableView("保管先は準備中です", systemImage: "externaldrive.badge.person.crop",
                                       description: Text("この構成ではサービス保管を利用できません。写真やメモは送信されません。"))
            }
        }
        .navigationTitle("サービスに保管")
        .navigationBarTitleDisplayMode(.inline)
        .task { coordinator.start() }
        .onDisappear { exporter.cancelPreparation(); coordinator.stop() }
        .sheet(item: $exporter.payload) { payload in
            RecordExportActivity(payload: payload) { exporter.finishSharing(payload, failed: $0) }
                .onDisappear { exporter.finishSharing(payload) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                exporter.cancelPreparation(); coordinator.stop(); needsResume = true
            }
            if phase == .active {
                exporter.retryCleanup()
                // Apple sign-in also transitions inactive -> active. Starting a
                // second request there could discard its still-arriving result.
                if needsResume { needsResume = false; coordinator.start() }
            }
        }
        .onChange(of: coordinator.isSignedIn) { _, signedIn in
            if !signedIn { exporter.invalidate() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)
            .receive(on: DispatchQueue.main)) { _ in
            exporter.invalidate()
            coordinator.signOut()
        }
        .confirmationDialog("サービスに保管したコピーを削除しますか？",
                            isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("保管コピーを削除", role: .destructive) { coordinator.deleteSelectedCopy() }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("この保管先からは取り戻せません。端末の元の写真・メモは削除しません。")
        }
    }

    private var content: some View {
        List {
            Section {
                Text("選んだ写真・メモのコピーを、ねこのまどのサービスに保管します。写真原本や動画のバックアップではありません。")
                Text("既存のiCloud保管とは別の保管先です。自動移行や、全写真の自動アップロードは行いません。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !coordinator.isSignedIn { authenticationSection }
            else if coordinator.selected != nil { detailSection }
            else {
                if let draft = coordinator.draft, !coordinator.draftWasSaved { newCopySection(draft) }
                if !coordinator.pendingMemoDrafts.isEmpty { pendingMemoSection }
                recordsSection
            }
            if coordinator.isBusy {
                Section { ProgressView("保管先に確認しています…") }
            }
            if exporter.preparing { Section { ProgressView("書き出しを準備しています…") } }
            if let error = exporter.error { Section { Text(error).foregroundStyle(.red) } }
            if let error = coordinator.errorMessage {
                Section { Text(error).foregroundStyle(.red).accessibilityAddTraits(.isStaticText) }
            }
            if let status = coordinator.statusMessage {
                Section { Text(status).foregroundStyle(.secondary) }
            }
            if let warning = coordinator.draftRecoveryWarning {
                Section { Text(warning).foregroundStyle(.red) }
            }
            if coordinator.isSignedIn {
                Section {
                    Button("この端末の保管用ログインを解除", role: .destructive) { coordinator.signOut() }
                        .disabled(coordinator.isBusy)
                } footer: {
                    Text("保管記録や会員契約は削除・解約されません。別の本人として使う前に解除してください。")
                }
            }
        }
        .disabled(coordinator.isBusy || exporter.preparing || exporter.payload != nil)
    }

    private var authenticationSection: some View {
        Section {
            if let challenge = coordinator.preparedSignIn {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = []
                    // Server defines the nonce. Do not introduce an unagreed client hash.
                    request.nonce = challenge.nonce
                    request.state = challenge.state
                } onCompletion: { result in coordinator.completeSignIn(result) }
                    .frame(height: 48)
                    .signInWithAppleButtonStyle(.black)
                Button("本人確認を準備し直す") { coordinator.prepareSignIn() }
            } else {
                Button("Appleで本人確認を準備") { coordinator.prepareSignIn() }
            }
        } header: { Text("保管用の本人確認") }
        footer: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Appleで同じ本人と確認できた場合に、その本人の保管記録を読み込みます。ログインだけで保管や購入は始まりません。")
                Text("未送信のメモはこの端末だけに保持します。同じ本人で確認できるまで文章を表示せず、別の本人へ引き継いだり、自動で送信したりしません。")
                Button("この端末に残っている本人確認情報を解除") { coordinator.signOut() }
            }
        }
    }

    private var pendingMemoSection: some View {
        Section {
            ForEach(coordinator.pendingMemoDrafts) { memo in
                VStack(alignment: .leading, spacing: 8) {
                    Text(memo.text.isEmpty ? "メモを空にする未送信の編集" : memo.text)
                        .font(.footnote).textSelection(.enabled)
                    Button("この未送信メモを再開") { coordinator.resumePendingMemo(memo) }
                }
            }
        } header: { Text("この本人の未送信メモ") }
        footer: {
            Text("通信中断前の下書きです。送信済みの可能性もあるため自動で上書きしません。記録が更新・削除されている場合は再開せず、この文章を控えて最新の記録と比べてください。")
        }
    }

    private func newCopySection(_ draft: ManagedPreservationDraft) -> some View {
        Section {
            if let photo = draft.jpegData {
                ManagedPreservationPhotoPreview(data: photo, maximumHeight: 220)
                    .id(draft.recordID)
                    .accessibilityLabel("今回保管する写真のコピー")
            }
            if !draft.document.text.isEmpty { Text(draft.document.text) }
            Toggle("この保管方法に同意する", isOn: $coordinator.consentToNewSave)
            Text("暗号化して保管しますが、運営者は技術的に復号できます。エンドツーエンド暗号化ではありません。選んだ写真とメモだけを送ります。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("選んだコピーを保管") { coordinator.saveSelectedCopy() }
                .disabled(!coordinator.consentToNewSave)
        } header: { Text("今回選んだ記録") }
        footer: {
            Text("新しい保管には会員資格が必要です。保管済みの記録の閲覧・メモ編集・削除・持ち出しに会員資格は必要ありません。写真原本や端末の元メモは変更しません。")
        }
    }

    private var recordsSection: some View {
        Section {
            Button { coordinator.refresh() } label: { Label("保管先から読み直す", systemImage: "arrow.clockwise") }
            ForEach(coordinator.records) { record in
                Button { coordinator.open(record) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.document.text.isEmpty ? "写真の記録" : record.document.text)
                            .lineLimit(2).foregroundStyle(.primary)
                        if !record.document.catNames.isEmpty {
                            Text(record.document.catNames.joined(separator: "・"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let captured = record.document.capturedAt {
                            Text(captured, format: .dateTime.year().month().day())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if coordinator.records.isEmpty && !coordinator.isBusy && coordinator.errorMessage == nil {
                Text("この本人の保管記録はまだありません。")
                    .foregroundStyle(.secondary)
            }
            if coordinator.hasMore { Button("続きを読み込む") { coordinator.loadMore() } }
        } header: { Text("保管したコピー") }
    }

    @ViewBuilder private var detailSection: some View {
        if let snapshot = coordinator.selected {
            Section {
                Button("保管一覧に戻る") { coordinator.closeDetail() }
                if let photo = snapshot.jpegData {
                    ManagedPreservationPhotoPreview(data: photo, maximumHeight: 360)
                        .id(snapshot.record.id)
                        .accessibilityLabel("サービスに保管された写真のコピー")
                }
                if !snapshot.document.catNames.isEmpty {
                    Text(snapshot.document.catNames.joined(separator: "・"))
                }
                TextEditor(text: $coordinator.editedText)
                    .frame(minHeight: 120).accessibilityLabel("保管コピーのメモ")
                Text("\(coordinator.editedText.count) / 500文字")
                    .font(.caption).foregroundStyle(.secondary)
                Button("保管コピーのメモを更新") { coordinator.saveEditedNote() }
                    .disabled(coordinator.editedText == snapshot.document.text)
                if coordinator.canExport {
                    Button("この記録を書き出す") { coordinator.exportSelectedCopy() }
                } else {
                    Text("この構成では書き出し画面はまだ接続されていません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("保管コピーを削除", role: .destructive) { confirmsDeletion = true }
            } footer: {
                Text("ここでの編集は保管したコピーだけに反映されます。未送信の編集はこの端末だけに保持し、本人確認が切れた場合は同じ本人で確認し直すまで隠します。")
            }
        }
    }
}

/// A single explicitly selected asset. Failure never falls back to uploading only
/// the text, and the prepared ID/content survive retry and authentication changes.
@MainActor
struct ManagedPreservationPhotoView: View {
    let photo: PhotoPresentation
    let context: PhotoMemoryNoteContext
    let noteStore: PhotoMemoryNoteStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var draft: ManagedPreservationDraft?
    @State private var draftID = UUID()
    @State private var errorMessage: String?
    @State private var attempt = UUID()

    var body: some View {
        NavigationStack {
            Group {
                if !ManagedPreservationConfiguration.current.isEnabled {
                    ContentUnavailableView("保管先は準備中です", systemImage: "externaldrive")
                } else if let draft {
                    ManagedPreservationView(draft: draft)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("写真を準備できませんでした", systemImage: "photo")
                    } description: { Text(errorMessage) } actions: {
                        Button("もう一度試す") { attempt = UUID() }
                    }
                } else { ProgressView("選んだ写真を準備しています…") }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("閉じる") { dismiss() }
            } }
            .task(id: attempt) { await prepare() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background && draft == nil { attempt = UUID() }
                if phase == .active && draft == nil { attempt = UUID() }
            }
            .onDisappear { access.stop() }
        }
    }

    private func prepare() async {
        guard ManagedPreservationConfiguration.current.isEnabled, draft == nil,
              scenePhase != .background else { return }
        let token = attempt
        errorMessage = nil
        access.start(photos: [photo])
        do {
            guard access.photo(for: photo.localIdentifier) != nil else {
                throw ManagedPreservationError.invalidRecord
            }
            let identifier = photo.localIdentifier
            let note = try await noteStore.note(for: identifier)
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                guard let raw = PhotoImageLoader().image(localIdentifier: identifier,
                    targetSize: CGSize(width: 4096, height: 4096), contentMode: .aspectFit)?
                    .jpegData(compressionQuality: 0.96) else { throw ManagedPreservationError.invalidRecord }
                try Task.checkCancellation()
                return try PersonalArchiveImage.jpeg(from: raw)
            }
            let jpeg = try await withTaskCancellationHandler { try await worker.value }
                onCancel: { worker.cancel() }
            let current = try await noteStore.note(for: identifier)
            try Task.checkCancellation()
            access.refresh()
            guard token == attempt, access.photo(for: identifier) != nil, current == note else {
                throw ManagedPreservationError.conflict
            }
            let document = ManagedPreservationDocument(text: note?.text ?? "",
                capturedAt: context.capturedAt, writtenAt: note?.writtenAt, updatedAt: note?.updatedAt,
                catNames: context.cats.map(\.name), photoFile: "photo.jpg")
            draft = ManagedPreservationDraft(recordID: draftID,
                document: try document.validated(), jpegData: jpeg)
        } catch is CancellationError {
            // No service request has been made, and the local source is untouched.
        } catch {
            guard token == attempt else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "写真とメモを読み込めませんでした。元の内容は変更していません。"
        }
    }
}

/// Downsample only for display; the validated export/upload copy remains untouched.
private struct ManagedPreservationPhotoPreview: View {
    let data: Data
    let maximumHeight: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .frame(maxHeight: maximumHeight)
        .task {
            guard image == nil, !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1024,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return }
            guard !Task.isCancelled else { return }
            image = UIImage(cgImage: thumbnail)
        }
    }
}
