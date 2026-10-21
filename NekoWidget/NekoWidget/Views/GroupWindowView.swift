import PhotosUI
import SwiftUI
import UIKit
import WidgetKit
import UniformTypeIdentifiers

// Group windows in the まど tab: the list, one window's photos, sending, and
// receiving. Signing, keys, and the relay stay inside
// `ProductionGroupWindowClient`; this file only keeps verified photos on this
// iPhone and draws them. It is reached only when
// `GroupWindowClientProvider.ui` exists (GroupWindowsEnabled builds).

// MARK: - What the window screens need from a client

/// A photo fetched and verified, waiting to be kept on this iPhone. Only the
/// production adapter can carry a verified photo; screens see the JPEG.
struct GroupFetchedPhoto: Sendable {
    let photo: GroupPhoto
    let jpeg: Data
    fileprivate let verified: GroupVerifiedIncomingPhoto?
}

/// The window screens' needs on top of the members/invitation boundary:
/// fetch one photo, keep it before the relay is told, and send one.
protocol GroupWindowMediaClient: GroupWindowClient {
    func fetchPhoto(photoID: String, windowID: String) async throws -> GroupFetchedPhoto
    func keep(_ fetched: GroupFetchedPhoto, outgoingOperationID: UUID?,
              persist: @escaping @Sendable (GroupPhoto, Data) async throws -> Void) async throws
    func sendPhoto(normalizedJPEG: Data, windowID: String, operationID: UUID) async throws -> GroupPhoto
}

extension ProductionGroupWindowClient: GroupWindowMediaClient {
    func fetchPhoto(photoID: String, windowID: String) async throws -> GroupFetchedPhoto {
        let incoming = try await downloadPhoto(photoID: photoID, windowID: windowID)
        return GroupFetchedPhoto(photo: incoming.photo, jpeg: incoming.jpeg, verified: incoming)
    }

    func keep(_ fetched: GroupFetchedPhoto, outgoingOperationID: UUID?,
              persist: @escaping @Sendable (GroupPhoto, Data) async throws -> Void) async throws {
        guard let verified = fetched.verified else { throw GroupClientError.invalidResponse }
        _ = try await storeAndAcknowledge(verified, outgoingOperationID: outgoingOperationID) { kept in
            try await persist(kept.photo, kept.jpeg)
        }
    }
}

// MARK: - Picking a photo

/// The same metadata-free JPEG the two-person window sends.
private struct PickedGroupPhoto: Transferable {
    let jpeg: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(jpeg: try MomentShareIngressService().prepare(fromFileURL: received.file).canonicalJPEG)
        }
    }
}

/// Sensitive-content check on a temporary, protected file, deleted at once.
private enum GroupPhotoModeration {
    enum Verdict { case safe, hidden, checkOff, retryLater }

    /// Why a picked photo cannot be delivered.
    static func sendMessage(_ verdict: Verdict) -> String? {
        switch verdict {
        case .safe: return nil
        case .hidden: return "この写真は届けられません。iPhoneがセンシティブな内容と判断しました。"
        case .checkOff:
            return "写真を確かめられませんでした。このiPhoneの「設定」→「プライバシーとセキュリティ」→「センシティブな内容の警告」をオンにしてください。"
        case .retryLater: return "写真を確かめられませんでした。少し待ってから、もう一度お試しください。"
        }
    }

    /// Why arrived photos are not shown yet. They wait on the relay until then.
    static func receiveMessage(_ verdict: Verdict) -> String {
        verdict == .checkOff
            ? "届いた写真の安全確認を待っています。このiPhoneの「設定」→「プライバシーとセキュリティ」→「センシティブな内容の警告」をオンにしてから、画面を下に引いて更新してください。"
            : "届いた写真の安全確認を完了できませんでした。少し待ってから、画面を下に引いて更新してください。"
    }

    static func check(_ jpeg: Data, with moderation: any MomentModerating) async -> Verdict {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
#if os(iOS)
            try jpeg.write(to: file, options: [.atomic, .completeFileProtection])
#else
            try jpeg.write(to: file, options: .atomic)
#endif
            try await moderation.requireSafeImage(at: file)
            return .safe
        } catch MomentSharingError.sensitiveContent {
            return .hidden
        } catch MomentSharingError.moderationDisabled {
            return .checkOff
        } catch {
            return .retryLater
        }
    }
}

// MARK: - One window

@MainActor
final class GroupWindowScreenModel: ObservableObject {
    @Published private(set) var window: GroupWindow?
    @Published private(set) var entries: [GroupWindowLocalPhotoStore.Entry] = []
    @Published private(set) var hearts: [String: [GroupHeart]] = [:]
    @Published private(set) var isSyncing = false
    @Published private(set) var isSending = false
    @Published private(set) var isPreparing = false
    @Published private(set) var message: String?
    @Published private(set) var sendCompleted = false
    /// Arrived photos that wait for the iPhone's safety check.
    @Published private(set) var receiveNotice: String?
    /// The photo that could not be delivered, kept to send again.
    @Published private(set) var failedDelivery: FailedDelivery?
    /// The result of 「お気に入りに追加」 or 「このiPhoneから消す」.
    @Published var actionMessage: String?

    let windowID: String
    let client: any GroupWindowMediaClient
    /// Set for a window this iPhone has left: its kept photos only.
    let formerName: String?
    private let store: GroupWindowLocalPhotoStore
    private let moderation: any MomentModerating

    init(client: any GroupWindowMediaClient, windowID: String, formerName: String? = nil,
         store: GroupWindowLocalPhotoStore = .shared,
         moderation: any MomentModerating = GroupWindowClientProvider.moderation) {
        self.client = client
        self.windowID = windowID
        self.formerName = formerName
        self.store = store
        self.moderation = moderation
    }

    var isFormer: Bool { formerName != nil }

    var isPaused: Bool { window.map(GroupWindowPresentation.isPaused) ?? false }

    var canSend: Bool {
        guard !isFormer, let window, window.state == .active, !isPaused else { return false }
        return !isSending && !isPreparing
    }

    /// A checked photo waiting on the confirmation screen.
    struct PreparedPhoto: Identifiable {
        let id = UUID()
        let jpeg: Data
        /// The Photos item, for the owner's own memo. Nil when unknown.
        let photoIdentifier: String?
        /// Kept for a retry, so a photo the relay already took is not sent twice.
        var operationID = UUID()
    }

    struct FailedDelivery {
        let photo: PreparedPhoto
        let memo: String
    }

    func imageURL(for entry: GroupWindowLocalPhotoStore.Entry) async -> URL? {
        await store.imageURL(photoID: entry.id, windowID: windowID)
    }

    func myHeartIsActive(_ photoID: String) -> Bool {
        guard let me = window?.myParticipantID else { return false }
        return hearts[photoID]?.contains { $0.participantID == me && $0.active } ?? false
    }

    /// Photos already kept on this iPhone appear at once, before the relay answers.
    func showStored() async {
        if entries.isEmpty { entries = await store.entries(windowID: windowID) }
    }

    /// Reads the window, keeps every new photo on this iPhone, then tells the
    /// relay it arrived. A failed step keeps what is already shown.
    func sync() async {
        if isFormer {
            // A window this iPhone left: only what is kept here.
            entries = await store.entries(windowID: windowID)
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            var latest = try await client.window(id: windowID)
            if latest.state == .rotationRequired, latest.canManage,
               let renewed = try? await client.rotate(
                   windowID: windowID, operation: GroupOperation(expectedRevision: latest.revision)) {
                // Someone left: the creator's iPhone renews the key, so the window goes on.
                latest = renewed
            }
            window = latest
            await store.remember(windowID: windowID, name: latest.name)
            let photos = try await client.photos(windowID: windowID)
            hearts = Dictionary(photos.map { ($0.id, $0.hearts) }, uniquingKeysWith: { _, last in last })
            var waiting: GroupPhotoModeration.Verdict?
            for photo in photos {
                guard !(await store.contains(photoID: photo.id, windowID: windowID)) else { continue }
                if let deferred = await receive(photo, me: latest.myParticipantID), waiting != .checkOff {
                    waiting = deferred
                }
                // Each photo shows as soon as it is kept, not after all of them.
                entries = await store.entries(windowID: windowID)
            }
            receiveNotice = waiting.map(GroupPhotoModeration.receiveMessage)
            message = nil
        } catch {
            message = GroupWindowPresentation.message(for: error)
        }
        entries = await store.entries(windowID: windowID)
        await updateHomeScreenPhoto()
    }

    /// The Widget reads only this copy, written after verification and the
    /// on-device check. Hidden photos are never handed over.
    private func updateHomeScreenPhoto() async {
        guard let window else { return }
        let newest = entries.first { !$0.isHidden }
        var jpeg: Data?
        if let newest, let url = await store.imageURL(photoID: newest.id, windowID: windowID) {
            jpeg = try? Data(contentsOf: url)
        }
        let previous = GroupWidgetCache.entry(windowID: windowID)
        do {
            try GroupWidgetCache.update(
                windowID: windowID, windowName: window.name, photoID: newest?.id, jpeg: jpeg,
                // No "さんから" line under a photo this iPhone sent.
                senderDisplayName: newest.flatMap { $0.isOwn ? nil : $0.senderDisplayName },
                capturedAt: newest?.createdAt, isPaused: isPaused,
                myHeartActive: newest.map { myHeartIsActive($0.id) } ?? false
            )
        } catch {
            return
        }
        if previous != GroupWidgetCache.entry(windowID: windowID) {
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        }
    }

    /// Returns the verdict when the photo waits for the safety check.
    @discardableResult
    private func receive(_ photo: GroupPhoto, me: String,
                         outgoingOperationID: UUID? = nil) async -> GroupPhotoModeration.Verdict? {
        do {
            let incoming = try await client.fetchPhoto(photoID: photo.id, windowID: windowID)
            let isOwn = photo.senderParticipantID == me
            // A photo this iPhone sent was checked before sending.
            let verdict: GroupPhotoModeration.Verdict
            if isOwn {
                verdict = .safe
            } else {
                verdict = await GroupPhotoModeration.check(incoming.jpeg, with: moderation)
            }
            // Keep it unacknowledged; it is tried again next time.
            guard verdict != .retryLater, verdict != .checkOff else { return verdict }
            let store = self.store
            let windowID = self.windowID
            let hidden = verdict == .hidden
            try await client.keep(incoming, outgoingOperationID: outgoingOperationID) { kept, jpeg in
                try await store.save(
                    .init(
                        id: kept.id,
                        senderParticipantID: kept.senderParticipantID,
                        senderDisplayName: kept.senderDisplayName,
                        createdAt: kept.createdAt,
                        isHidden: hidden,
                        isOwn: isOwn
                    ),
                    jpeg: hidden ? nil : jpeg,
                    windowID: windowID
                )
            }
        } catch {
            // Leave it for the next sync; the relay keeps it until acknowledged.
        }
        return nil
    }

    /// Reads and checks a picked photo, before the confirmation screen.
    /// Nothing is sent here.
    func prepare(_ item: PhotosPickerItem) async -> PreparedPhoto? {
        guard canSend else { return nil }
        isPreparing = true
        sendCompleted = false
        defer { isPreparing = false }
        guard let picked = try? await item.loadTransferable(type: PickedGroupPhoto.self) else {
            message = "写真を読み込めませんでした。別の写真でお試しください。"
            return nil
        }
        if let reason = GroupPhotoModeration.sendMessage(
            await GroupPhotoModeration.check(picked.jpeg, with: moderation)) {
            message = reason
            return nil
        }
        message = nil
        return PreparedPhoto(jpeg: picked.jpeg, photoIdentifier: item.itemIdentifier)
    }

    /// Sends the confirmed photo. The memo stays on this iPhone, on the photo's own memo.
    func deliver(_ prepared: PreparedPhoto, memo: String) async {
        guard canSend, let me = window?.myParticipantID else { return }
        isSending = true
        sendCompleted = false
        failedDelivery = nil
        defer { isSending = false }
        do {
            let operationID = prepared.operationID
            let sent = try await client.sendPhoto(normalizedJPEG: prepared.jpeg, windowID: windowID, operationID: operationID)
            await receive(sent, me: me, outgoingOperationID: operationID)
            await saveMemo(memo, for: prepared.photoIdentifier)
            sendCompleted = true
            message = nil
            await sync()
        } catch {
            message = Self.deliveryMessage(for: error)
            if !(error is GroupSubscriptionError) {
                // The same operation resends safely, unless the window's key changed.
                let keepsOperation: Bool
                switch error as? GroupClientError {
                case .some(.staleEpoch), .some(.rotationPending), .some(.idempotencyConflict): keepsOperation = false
                default: keepsOperation = true
                }
                let retry = keepsOperation
                    ? prepared : PreparedPhoto(jpeg: prepared.jpeg, photoIdentifier: prepared.photoIdentifier)
                failedDelivery = FailedDelivery(photo: retry, memo: memo)
            }
            await sync()
        }
    }

    /// After a failed send: what happened to that photo, and what to do next.
    static func deliveryMessage(for error: Error) -> String {
        switch error as? GroupClientError {
        case .some(.offline):
            return "接続できないため、届けられませんでした。電波のあるところで「もう一度届ける」を押してください。"
        case .some(.unavailable):
            return "いま届けられませんでした。少し待ってから「もう一度届ける」を押してください。"
        default:
            return GroupWindowPresentation.message(for: error)
        }
    }

    func retryFailedDelivery() async {
        guard let failed = failedDelivery else { return }
        await deliver(failed.photo, memo: failed.memo)
    }

    func discardFailedDelivery() {
        failedDelivery = nil
        message = nil
    }

#if DEBUG
    /// Screen check only: shows the 「もう一度届ける」 row with a fixture photo.
    func showFixtureFailedDelivery() {
        guard let jpeg = AppStoreScreenshotFixture.image(for: "app-store-screenshot-fixture-4")?
            .jpegData(compressionQuality: 0.8) else { return }
        message = Self.deliveryMessage(for: GroupClientError.offline)
        failedDelivery = FailedDelivery(photo: PreparedPhoto(jpeg: jpeg, photoIdentifier: nil), memo: "")
    }
#endif

    // MARK: Keeping a received photo

    /// 「お気に入りに追加」: the same copy into the Photos app as the
    /// two-person window, then the ordinary favorite, so it can join albums.
    func addToFavorites(_ entry: GroupWindowLocalPhotoStore.Entry) async {
        guard !entry.isOwn, !entry.isHidden else { return }
        let service = ReceivedPhotoMemoryImportService()
        do {
            var identifier = entry.favoriteLocalIdentifier
            if identifier == nil {
                guard let url = await store.imageURL(photoID: entry.id, windowID: windowID),
                      let jpeg = try? Data(contentsOf: url) else {
                    actionMessage = "写真を読み込めませんでした。"
                    return
                }
                try await service.requestMemoryImportAuthorization()
                let token = entry.favoriteImportToken ?? UUID()
                if entry.favoriteImportToken == nil {
                    try await store.setFavoriteImport(photoID: entry.id, windowID: windowID, token: token, localIdentifier: nil)
                } else {
                    // An earlier copy may have finished before the app stopped.
                    identifier = try? await service.recoverImportedAsset(importToken: token)
                }
                if identifier == nil {
                    identifier = try await service.importMemory(
                        MomentPhotoLibraryCopyPayload(jpegData: jpeg, capturedAt: entry.createdAt),
                        importToken: token
                    )
                }
                if let identifier {
                    try await store.setFavoriteImport(photoID: entry.id, windowID: windowID,
                                                      token: token, localIdentifier: identifier)
                }
            }
            guard let favorite = identifier else { throw ReceivedPhotoMemoryImportError.importFailed }
            try SharedLikeStore.set(localIdentifier: favorite, isLiked: true, source: "received-memory")
            NotificationCenter.default.post(name: .receivedMemoryImportNeedsRefresh, object: favorite)
            entries = await store.entries(windowID: windowID)
            actionMessage = "お気に入りに追加しました。写真アプリにも保存しました。"
        } catch {
            entries = await store.entries(windowID: windowID)
            actionMessage = (error as? LocalizedError)?.errorDescription
                ?? "お気に入りに追加できませんでした。時間をおいて、もう一度お試しください。"
        }
    }

    /// Removes a photo from this iPhone only.
    func remove(_ entry: GroupWindowLocalPhotoStore.Entry) async {
        do {
            try await store.remove(photoID: entry.id, windowID: windowID)
        } catch {
            actionMessage = "消せませんでした。もう一度お試しください。"
            return
        }
        entries = await store.entries(windowID: windowID)
        if !isFormer { await updateHomeScreenPhoto() }
    }

    /// Stops showing this person's photos here. They are not told.
    func hideSender(of entry: GroupWindowLocalPhotoStore.Entry) async {
        await store.hide(memberID: entry.senderParticipantID, name: entry.senderDisplayName, windowID: windowID)
        entries = await store.entries(windowID: windowID)
        if !isFormer { await updateHomeScreenPhoto() }
        actionMessage = "\(GroupDisplayName.withSan(entry.senderDisplayName))の写真を表示しないようにしました。設定の「表示しないようにした人」から戻せます。"
    }

    /// For a window this iPhone left: deletes every kept photo.
    func forgetFormerWindow() async {
        await store.forget(windowID: windowID)
        try? GroupWidgetCache.remove(windowID: windowID)
        WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
    }

    private func saveMemo(_ memo: String, for identifier: String?) async {
        let text = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let identifier else { return }
        let notes = PhotoMemoryNoteStore.shared
        let existing: PhotoMemoryNote? = (try? await notes.note(for: identifier)) ?? nil
        let combined = existing.map { $0.text + "\n" + text } ?? text
        _ = try? await notes.save(text: combined, for: identifier, expectedRevision: existing?.revision)
    }

    /// Reads only the window (state, name, members), so a delivery from a
    /// photo's detail can check it without downloading every photo.
    func loadWindow() async {
        do { window = try await client.window(id: windowID); message = nil }
        catch { message = GroupWindowPresentation.message(for: error) }
    }

    /// The same checks as a picked photo, for a photo opened in the 写真 tab or an album.
    func prepare(localIdentifier: String) async -> PreparedPhoto? {
        guard canSend else { return nil }
        isPreparing = true
        sendCompleted = false
        defer { isPreparing = false }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        let jpeg: Data
        do {
            let exported = try await PhotoLibraryJPEGExporter().export(localIdentifier: localIdentifier)
#if os(iOS)
            try exported.jpeg.write(to: file, options: [.atomic, .completeFileProtection])
#else
            try exported.jpeg.write(to: file, options: .atomic)
#endif
            jpeg = try MomentShareIngressService().prepare(fromFileURL: file).canonicalJPEG
        } catch {
            message = "写真を読み込めませんでした。別の写真でお試しください。"
            return nil
        }
        if let reason = GroupPhotoModeration.sendMessage(
            await GroupPhotoModeration.check(jpeg, with: moderation)) {
            message = reason
            return nil
        }
        message = nil
        return PreparedPhoto(jpeg: jpeg, photoIdentifier: localIdentifier)
    }

    func toggleHeart(_ photoID: String) async {
        do {
            let updated = try await client.setHeart(
                photoID: photoID, windowID: windowID,
                active: !myHeartIsActive(photoID), operationID: UUID()
            )
            hearts[photoID] = updated.hearts
        } catch {
            message = GroupWindowPresentation.message(for: error)
        }
    }
}

struct GroupWindowScreen: View {
    @StateObject private var model: GroupWindowScreenModel
    @State private var pickedItem: PhotosPickerItem?
    @State private var prepared: GroupWindowScreenModel.PreparedPhoto?
    @State private var openedEntry: GroupWindowLocalPhotoStore.Entry?
    @State private var showsForgetConfirmation = false
    @Environment(\.dismiss) private var dismiss

    init(client: any GroupWindowMediaClient, windowID: String, formerName: String? = nil) {
        _model = StateObject(wrappedValue: GroupWindowScreenModel(
            client: client, windowID: windowID, formerName: formerName))
    }

    /// After leaving from the members screen: back to the list.
    private func closeAfterLeaving() {
        try? GroupWidgetCache.remove(windowID: model.windowID)
        WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        dismiss()
    }

    private var membersScreen: some View {
        GroupWindowMembersScreen(client: model.client, windowID: model.windowID, onLeft: closeAfterLeaving)
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.isFormer {
                    Label("このまどから抜けました。届いた写真は、このiPhoneに残っています。",
                          systemImage: "person.2.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("group-window-former")
                }
                if let window = model.window, model.isPaused {
                    pausedCard(window)
                }
                if let message = model.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("group-window-screen-message")
                    if model.canSend && model.failedDelivery == nil {
                        Text("下の「写真を届ける」から、別の写真を選べます。")
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                    }
                }
                if let notice = model.receiveNotice {
                    Label(notice, systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("group-window-receive-notice")
                }
                if model.isSyncing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(model.entries.isEmpty ? "写真を読み込んでいます…" : "新しい写真を確かめています…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("group-window-syncing")
                }
                if model.entries.isEmpty && model.isSyncing {
                    Color.clear.frame(height: 120)
                } else if model.entries.isEmpty {
                    ContentUnavailableView(
                        "まだ写真はありません",
                        systemImage: "photo.on.rectangle",
                        description: Text(model.isFormer
                            ? "このiPhoneに残っている写真はありません。"
                            : "届けた写真と届いた写真が、ここに並びます。参加する前の写真は届きません。")
                    )
                    .frame(minHeight: 240)
                } else {
                    // One photo per row, large, with who sent it and the hearts under it.
                    LazyVStack(spacing: 14) {
                        ForEach(model.entries) { entry in
                            GroupPhotoTile(model: model, entry: entry) { openedEntry = entry }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(model.window?.name ?? model.formerName ?? "まど")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.isFormer {
                    Menu {
                        Button("このiPhoneから消す", systemImage: "trash", role: .destructive) {
                            showsForgetConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("このまどの操作")
                } else {
                    NavigationLink { membersScreen } label: {
                        Label("メンバー", systemImage: "person.2")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel("メンバーと招待")
                    .accessibilityIdentifier("group-window-open-members")
                }
            }
        }
        .confirmationDialog("このまどの写真を、このiPhoneから消しますか？",
                            isPresented: $showsForgetConfirmation, titleVisibility: .visible) {
            Button("消す", role: .destructive) {
                Task {
                    await model.forgetFormerWindow()
                    dismiss()
                }
            }
            Button("戻る", role: .cancel) {}
        } message: {
            Text("写真アプリへ保存した写真は残ります。取り消せません。")
        }
        .safeAreaInset(edge: .bottom) {
            if !model.isFormer { sendBar }
        }
        .task {
            await model.showStored()
            await model.sync()
#if DEBUG
            if GroupWindowUIFixture.showsFailedDelivery { model.showFixtureFailedDelivery() }
#endif
        }
        .refreshable { await model.sync() }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            Task { prepared = await model.prepare(item) }
        }
        .sheet(item: $prepared) { photo in
            GroupSendConfirmSheet(photo: photo, windowName: model.window?.name ?? "まど") { memo in
                prepared = nil
                Task { await model.deliver(photo, memo: memo) }
            }
        }
        .announcesWhenShown(model.message)
        .sheet(item: $openedEntry) { entry in
            GroupPhotoDetail(model: model, startID: entry.id)
        }
    }

    private func pausedCard(_ window: GroupWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("このまどは止まっています", systemImage: "pause.circle")
                .font(.headline)
            Text(GroupWindowPresentation.pausedDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink { membersScreen } label: {
                Text(GroupWindowPresentation.isMyWindow(window)
                     ? "このまどを続ける"
                     : "\(GroupWindowPresentation.pausedOwnerPhrase(window))がPlusを続けると再開します")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("group-window-screen-paused")
    }

    private func failedDeliveryRow(_ failed: GroupWindowScreenModel.FailedDelivery) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let image = UIImage(data: failed.photo.jpeg) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                }
                Text("届けられなかった写真があります")
                    .font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("やめる") { model.discardFailedDelivery() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                Button {
                    Task { await model.retryFailedDelivery() }
                } label: {
                    Label("もう一度届ける", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSend)
                .accessibilityIdentifier("group-window-send-retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("group-window-send-failed")
    }

    private var sendBar: some View {
        VStack(spacing: 6) {
            if model.isPreparing || model.isSending {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(model.isPreparing ? "写真を確かめています…" : "届けています…")
                        .font(.footnote.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("group-window-send-progress")
            } else if model.sendCompleted {
                Label("届けました", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
            } else if let failed = model.failedDelivery {
                failedDeliveryRow(failed)
            }
            PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                Label(model.isSending ? "届けています…" : "写真を届ける", systemImage: "paperplane")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            // While a photo waits to be sent again, the retry is the main button.
            .buttonStyle(.borderedProminent)
            .opacity(model.failedDelivery == nil ? 1 : 0.45)
            .disabled(!model.canSend)
            .accessibilityIdentifier("group-window-send-photo")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// One photo in the window's feed: the picture, then one line with who sent
/// it, when, and the hearts. Tap opens it; a double tap sends a heart.
private struct GroupPhotoTile: View {
    @ObservedObject var model: GroupWindowScreenModel
    let entry: GroupWindowLocalPhotoStore.Entry
    let open: () -> Void
    @State private var url: URL?

    private var heartCount: Int { model.hearts[entry.id]?.filter(\.active).count ?? 0 }
    private var canHeart: Bool { !entry.isHidden && !entry.isOwn && !model.isFormer }

    var body: some View {
        VStack(spacing: 0) {
            Color(uiColor: .tertiarySystemFill)
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    if entry.isHidden {
                        Image(systemName: "eye.slash").font(.title2).foregroundStyle(.secondary)
                    } else if let url, let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard canHeart else { return }
                    Task { await model.toggleHeart(entry.id) }
                }
                .onTapGesture(count: 1, perform: open)
            HStack(spacing: 8) {
                GroupMemberAvatar(name: entry.isOwn ? "自" : entry.senderDisplayName, size: 24)
                Text(entry.isOwn ? "自分" : entry.senderDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(entry.createdAt.formatted(.dateTime.month().day()))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    guard canHeart else { return }
                    Task { await model.toggleHeart(entry.id) }
                } label: {
                    Label(heartCount > 0 ? heartCount.formatted() : "", systemImage: model.myHeartIsActive(entry.id) || heartCount > 0 ? "heart.fill" : "heart")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(heartCount > 0 ? Color.red : Color.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(!canHeart)
                .accessibilityLabel(heartCount > 0 ? "ハート \(heartCount)" : "ハート")
                .accessibilityHint(canHeart ? "ハートを送ります" : "")
                .accessibilityIdentifier("group-photo-tile-heart")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tileLabel)
        .accessibilityHint("押すと大きく見て、ハートを送れます")
        .accessibilityAction(named: Text("大きく見る"), open)
        .task { url = await model.imageURL(for: entry) }
    }
}

private extension GroupPhotoTile {
    var tileLabel: String {
        var parts = [entry.isOwn ? "自分が届けた写真" : "\(GroupDisplayName.withSan(entry.senderDisplayName))から届いた写真"]
        if entry.isHidden { parts.append("表示していない写真") }
        if !(model.hearts[entry.id]?.filter(\.active).isEmpty ?? true) { parts.append("ハートあり") }
        return parts.joined(separator: "、")
    }
}

// MARK: - Delivering from a photo's detail

/// 「まどに届ける」 from the 写真 tab or an album: choose a group window (not
/// asked when there is only one), then the same confirmation as in the window.
struct GroupLibraryDeliverySheet: View {
    let client: any GroupWindowMediaClient
    let localIdentifier: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var list: GroupWindowListModel
    @State private var screen: GroupWindowScreenModel?

    init(client: any GroupWindowMediaClient, localIdentifier: String) {
        self.client = client
        self.localIdentifier = localIdentifier
        _list = StateObject(wrappedValue: GroupWindowListModel(client: client))
    }

    private var openWindows: [GroupWindow] {
        list.windows.filter { $0.state == .active && !GroupWindowPresentation.isPaused($0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let screen {
                    GroupLibraryDeliveryStep(model: screen, localIdentifier: localIdentifier) { dismiss() }
                } else if !list.hasLoaded {
                    ProgressView("まどを読み込んでいます…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if openWindows.isEmpty {
                    ContentUnavailableView("届け先のまどがありません", systemImage: "window.vertical.closed",
                        description: Text("まどタブで、まどを作るか、届いた招待リンクから参加してください。"))
                } else {
                    List(openWindows) { window in
                        Button { screen = GroupWindowScreenModel(client: client, windowID: window.id) } label: {
                            LabeledContent(window.name, value: GroupWindowPresentation.memberCountText(window))
                                .frame(minHeight: 44)
                        }
                        .foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier("group-library-delivery-windows")
                }
            }
            .navigationTitle("まどに届ける")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if screen == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                }
            }
        }
        .task {
            await list.load()
            if openWindows.count == 1 {
                screen = GroupWindowScreenModel(client: client, windowID: openWindows[0].id)
            }
        }
        .announcesWhenShown(list.message)
    }
}

/// The chosen window: checks the photo, then the same confirmation as in the window.
private struct GroupLibraryDeliveryStep: View {
    @ObservedObject var model: GroupWindowScreenModel
    let localIdentifier: String
    let close: () -> Void
    @State private var prepared: GroupWindowScreenModel.PreparedPhoto?
    @State private var checked = false
    @State private var memo = ""

    var body: some View {
        Group {
            if model.sendCompleted {
                ContentUnavailableView {
                    Label("届けました", systemImage: "checkmark.circle.fill")
                } description: {
                    Text(model.window.map { "「\($0.name)」のメンバーに届きました。" } ?? "")
                } actions: {
                    Button("閉じる", action: close).buttonStyle(.borderedProminent)
                }
                .accessibilityIdentifier("group-library-delivery-done")
            } else if let prepared {
                Form {
                    Section {
                        if let image = UIImage(data: prepared.jpeg) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 300)
                                .accessibilityLabel("届ける写真")
                        }
                    }
                    Section {
                        TextField("例：おなかを見せて寝ていた", text: $memo, axis: .vertical).lineLimit(2...5)
                    } header: { Text("メモ") }
                      footer: { Text("メモはこのiPhoneにだけ残り、まどには届きません。") }
                    if let message = model.message {
                        Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        Task { await model.deliver(prepared, memo: String(memo.prefix(500))) }
                    } label: {
                        Group {
                            if model.isSending {
                                HStack(spacing: 8) { ProgressView(); Text("届けています…") }
                            } else {
                                Label("届ける", systemImage: "paperplane")
                            }
                        }
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSending)
                    .accessibilityIdentifier("group-library-delivery-send")
                    .padding().background(.regularMaterial)
                }
            } else if checked, let message = model.message {
                ContentUnavailableView {
                    Label("届けられません", systemImage: "exclamationmark.triangle")
                } description: { Text(message) } actions: {
                    Button("閉じる", action: close)
                }
            } else {
                ProgressView("写真を確かめています…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.window.map { "「\($0.name)」に届ける" } ?? "まどに届ける")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(model.sendCompleted ? "閉じる" : "キャンセル", action: close)
            }
        }
        .announcesWhenShown(model.message)
        .task {
            await model.loadWindow()
            prepared = await model.prepare(localIdentifier: localIdentifier)
            checked = true
        }
    }
}

/// Shown after a photo is picked: the photo, where it goes, and a memo for
/// this iPhone only. Nothing is sent until 「届ける」.
private struct GroupSendConfirmSheet: View {
    let photo: GroupWindowScreenModel.PreparedPhoto
    let windowName: String
    let deliver: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var memo = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let image = UIImage(data: photo.jpeg) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 320)
                            .accessibilityLabel("届ける写真")
                    }
                }
                Section {
                    TextField("例：おなかを見せて寝ていた", text: $memo, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("group-window-send-memo")
                } header: { Text("メモ") }
                  footer: { Text("メモはこのiPhoneにだけ残り、まどには届きません。写真タブで見返せます。") }
            }
            .navigationTitle("「\(windowName)」に届ける")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button { deliver(String(memo.prefix(500))) } label: {
                    Label("届ける", systemImage: "paperplane").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("group-window-send-confirm")
                .padding().background(.regularMaterial)
            }
        }
    }
}

private struct GroupPhotoDetail: View {
    @ObservedObject var model: GroupWindowScreenModel
    @State private var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var showsFavoriteConfirmation = false
    @State private var showsRemoveConfirmation = false
    @State private var showsHideConfirmation = false

    init(model: GroupWindowScreenModel, startID: String) {
        self.model = model
        _selection = State(initialValue: startID)
    }

    private var current: GroupWindowLocalPhotoStore.Entry? {
        model.entries.first { $0.id == selection }
    }

    private func reactors(_ entry: GroupWindowLocalPhotoStore.Entry) -> [String] {
        (model.hearts[entry.id] ?? []).filter(\.active).map(\.displayName)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // Swipe left and right, as in the two-person window.
                TabView(selection: $selection) {
                    ForEach(model.entries) { entry in
                        GroupPhotoPage(model: model, entry: entry).tag(entry.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                if let current {
                    details(current)
                    actions(current)
                }
                if let message = model.actionMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("group-photo-action-message")
                }
            }
            .padding(.bottom, 12)
            .background(.black)
            .navigationTitle(model.window?.name ?? model.formerName ?? "まど")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let current, !current.isOwn {
                            Button("\(GroupDisplayName.withSan(current.senderDisplayName))の写真を表示しない", systemImage: "eye.slash") {
                                showsHideConfirmation = true
                            }
                        }
                        Button("このiPhoneから消す", systemImage: "trash", role: .destructive) {
                            showsRemoveConfirmation = true
                        }
                        if let url = SharingAPIConfiguration.current.supportURL {
                            Link(destination: url) { Label("問題を問い合わせる", systemImage: "exclamationmark.bubble") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("この写真の操作")
                    .accessibilityIdentifier("group-photo-menu")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
            }
            .confirmationDialog("自分のお気に入りに追加しますか？",
                                isPresented: $showsFavoriteConfirmation, titleVisibility: .visible) {
                Button("お気に入りに追加") {
                    if let current { Task { await model.addToFavorites(current) } }
                }
                Button("戻る", role: .cancel) {}
            } message: {
                Text("写真アプリにコピーして、お気に入りに入れます。位置情報は付けません。届けた人には知らせません。")
            }
            .confirmationDialog(current.map { "\(GroupDisplayName.withSan($0.senderDisplayName))の写真を表示しないようにしますか？" } ?? "",
                                isPresented: $showsHideConfirmation, titleVisibility: .visible) {
                Button("表示しない", role: .destructive) {
                    guard let current else { return }
                    Task {
                        await model.hideSender(of: current)
                        if model.entries.isEmpty { dismiss() } else if let first = model.entries.first { selection = first.id }
                    }
                }
                Button("戻る", role: .cancel) {}
            } message: {
                Text("このまどで、この人から届いた写真がこのiPhoneで見えなくなります。相手には知らせません。設定の「表示しないようにした人」から戻せます。")
            }
            .confirmationDialog("この写真を、このiPhoneから消しますか？",
                                isPresented: $showsRemoveConfirmation, titleVisibility: .visible) {
                Button("消す", role: .destructive) {
                    guard let current else { return }
                    let next = neighbor(of: current)
                    Task {
                        await model.remove(current)
                        if let next { selection = next } else { dismiss() }
                    }
                }
                Button("戻る", role: .cancel) {}
            } message: {
                Text("このiPhoneの一覧から消します。写真アプリへ保存した写真と、ほかのメンバーのiPhoneの写真はそのままです。取り消せません。")
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.actionMessage = nil }
        .onChange(of: selection) { _, _ in model.actionMessage = nil }
    }

    private func neighbor(of entry: GroupWindowLocalPhotoStore.Entry) -> String? {
        guard let index = model.entries.firstIndex(where: { $0.id == entry.id }) else { return nil }
        if index + 1 < model.entries.count { return model.entries[index + 1].id }
        return index > 0 ? model.entries[index - 1].id : nil
    }

    private func details(_ entry: GroupWindowLocalPhotoStore.Entry) -> some View {
        let day = entry.createdAt.formatted(.dateTime.month().day())
        let names = reactors(entry)
        let position = model.entries.firstIndex { $0.id == entry.id }.map { "\($0 + 1) / \(model.entries.count)" }
        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.isOwn ? "自分" : GroupDisplayName.withSan(entry.senderDisplayName))
                    .font(.subheadline.weight(.semibold))
                Text(entry.isOwn ? "\(day)に届けました" : "\(day)に届きました")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let position {
                    Text(position).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !names.isEmpty {
                Text("♥ " + names.joined(separator: "・"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("ハートを送った人：\(names.joined(separator: "、"))")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Under the photo: ♥ with its count, and お気に入り. Words only as captions.
    @ViewBuilder
    private func actions(_ entry: GroupWindowLocalPhotoStore.Entry) -> some View {
        let heartCount = reactors(entry).count
        let mine = model.myHeartIsActive(entry.id)
        HStack(spacing: 0) {
            if !entry.isHidden && !entry.isOwn && !model.isFormer {
                Button {
                    Task { await model.toggleHeart(entry.id) }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: mine ? "heart.fill" : "heart").font(.title2)
                        Text(heartCount > 0 ? heartCount.formatted() : "ハート").font(.caption2.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(mine ? Color.red : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mine ? "ハートを送りました" : "ハートを送る")
                .accessibilityValue(heartCount > 0 ? "\(heartCount)" : "")
                .accessibilityIdentifier("group-photo-heart")
            }
            if !entry.isHidden && !entry.isOwn {
                if entry.favoriteLocalIdentifier != nil {
                    VStack(spacing: 3) {
                        Image(systemName: "bookmark.fill").font(.title2)
                        Text("お気に入り").font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("お気に入りに追加済み")
                    .accessibilityIdentifier("group-photo-favorite-done")
                } else {
                    Button {
                        showsFavoriteConfirmation = true
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "bookmark").font(.title2)
                            Text("お気に入り").font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(Color.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("自分のお気に入りに追加")
                    .accessibilityIdentifier("group-photo-favorite")
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct GroupPhotoPage: View {
    @ObservedObject var model: GroupWindowScreenModel
    let entry: GroupWindowLocalPhotoStore.Entry
    @State private var url: URL?

    var body: some View {
        Group {
            if entry.isHidden {
                ContentUnavailableView("この写真は表示しません", systemImage: "eye.slash",
                    description: Text("iPhoneがセンシティブな内容と判断しました。右上の「…」から、このiPhoneから消せます。"))
            } else if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel(entry.isOwn ? "自分が届けた写真" : "\(GroupDisplayName.withSan(entry.senderDisplayName))から届いた写真")
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: entry.id) { url = await model.imageURL(for: entry) }
    }
}

// MARK: - Members screen with the production client

struct GroupWindowMembersScreen: View {
    @StateObject private var model: GroupWindowMembersModel
    private let onLeft: (() -> Void)?
    @State private var createsOwnWindow = false

    init(client: any GroupWindowClient, windowID: String, onLeft: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: GroupWindowMembersModel(client: client, windowID: windowID))
        self.onLeft = onLeft
    }

    var body: some View {
        GroupWindowMembersView(
            model: model,
            // A paused window's member can start a window of their own.
            onCreateOwnWindow: GroupWindowClientProvider.ui == nil ? nil : { createsOwnWindow = true },
            onLeft: onLeft
        )
        .navigationDestination(isPresented: $createsOwnWindow) {
            if let client = GroupWindowClientProvider.ui {
                GroupWindowCreateScreen(client: client)
            }
        }
    }
}

// MARK: - Opening a window from the home screen

/// The window a home-screen photo asked to open, held in memory until the
/// group list in the まど tab shows it.
@MainActor
final class GroupWindowOpenInbox: ObservableObject {
    static let shared = GroupWindowOpenInbox()
    @Published private(set) var pendingWindowID: String?

    func open(windowID: String) { pendingWindowID = windowID }
    func consume() { pendingWindowID = nil }
}

// MARK: - The list in the まど tab

@MainActor
final class GroupWindowListModel: ObservableObject {
    @Published private(set) var windows: [GroupWindow] = []
    @Published private(set) var message: String?
    @Published private(set) var isWorking = false
    @Published private(set) var hasLoaded = false
    let client: any GroupWindowMediaClient

    init(client: any GroupWindowMediaClient) { self.client = client }

    func load() async {
        defer { hasLoaded = true }
        do {
            windows = try await client.windows()
            message = nil
        } catch {
            message = GroupWindowPresentation.message(for: error)
        }
    }

    /// Set when the relay answers that making a window needs Plus.
    @Published var needsPlus = false

    func create(name: String) async -> GroupWindow? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let window = try await client.createWindow(name: trimmed, operationID: UUID())
            await load()
            return window
        } catch {
            if (error as? GroupSubscriptionError) == .ownerPlusRequired {
                message = nil
                needsPlus = true
            } else {
                message = GroupWindowPresentation.message(for: error)
            }
            return nil
        }
    }
}

/// Creating a window for up to six people (two people use it too). Reached
/// from 「まどを作る」 in the まど tab.
struct GroupWindowCreateScreen: View {
    @StateObject private var model: GroupWindowListModel
    @Environment(\.membershipAccess) private var membershipAccess
    @State private var name = ""
    @State private var createdWindowID: String?

    init(client: any GroupWindowMediaClient) {
        _model = StateObject(wrappedValue: GroupWindowListModel(client: client))
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField("例：実家のまど", text: $name)
                    .accessibilityIdentifier("group-window-create-name")
            } header: { Text("まどの名前") }
              footer: { Text("名前はメンバー全員に表示されます。作ったら、招待リンクを送りましょう。") }
            if let message = model.message {
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            // The button sits right under the name, not at the bottom of an empty screen.
            Section {
                if membershipAccess.decision(for: .createOwnWindow) != .allowed {
                    // まどを作るのは Plus（App Store の14日間無料を含む）。押したときだけ開く。
                    PlusOfferPrompt(context: .createWindow,
                                    decision: membershipAccess.decision(for: .createOwnWindow),
                                    presentsImmediately: false)
                } else {
                    Button {
                        Task { createdWindowID = await model.create(name: trimmed)?.id }
                    } label: {
                        Text("作る").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty || model.isWorking)
                    .accessibilityIdentifier("group-window-create-confirm")
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .navigationTitle("家族・友だちとまどを作る")
        .navigationBarTitleDisplayMode(.inline)
        .announcesWhenShown(model.message)
        .sheet(isPresented: $model.needsPlus, onDismiss: {
            NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
        }) {
            // The relay said Plus is needed (for example, the trial ended on another iPhone).
            MembershipOfferSheet(model: .live(), context: .createWindow) { _ in model.needsPlus = false }
        }
        .navigationDestination(isPresented: Binding(
            get: { createdWindowID != nil },
            set: { if !$0 { createdWindowID = nil } }
        )) {
            if let createdWindowID {
                GroupWindowMembersScreen(client: model.client, windowID: createdWindowID)
            }
        }
    }
}

/// Shown in the まど tab only in builds with group windows turned on.
struct GroupWindowListSection: View {
    @StateObject private var model: GroupWindowListModel
    @State private var openedWindowID: String?
    @State private var formerWindows: [GroupWindowLocalPhotoStore.KnownWindow] = []
    @ObservedObject private var openInbox = GroupWindowOpenInbox.shared

    init(client: any GroupWindowMediaClient) {
        _model = StateObject(wrappedValue: GroupWindowListModel(client: client))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("家族・友だちのまど")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(model.windows) { window in
                NavigationLink {
                    GroupWindowScreen(client: model.client, windowID: window.id)
                } label: {
                    row(window)
                }
                .buttonStyle(.plain)
            }
            if !model.hasLoaded && model.windows.isEmpty {
                // Names kept on this iPhone from the last visit, so the list is not empty while it loads.
                ForEach(GroupWidgetCache.entries(), id: \.windowID) { known in
                    NavigationLink {
                        GroupWindowScreen(client: model.client, windowID: known.windowID)
                    } label: {
                        knownRow(known.windowName)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 8) {
                    ProgressView()
                    Text("まどを読み込んでいます…").font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("group-window-list-loading")
            }
            if let message = model.message {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            NavigationLink {
                GroupWindowCreateScreen(client: model.client)
            } label: {
                Label("まどを作る（\(GroupWindowPresentation.memberLimit)人まで）", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking)
            .accessibilityIdentifier("group-window-create")
            if !formerWindows.isEmpty {
                Text("前のまど")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 8)
                ForEach(formerWindows) { former in
                    NavigationLink {
                        GroupWindowScreen(client: model.client, windowID: former.id, formerName: former.name)
                    } label: {
                        formerRow(former.name)
                    }
                    .buttonStyle(.plain)
                }
                .accessibilityIdentifier("group-window-former-list")
            }
        }
        .task {
            GroupWidgetCache.markGroupWindowsOn()
            await model.load()
            await loadFormerWindows()
        }
        .task(id: openInbox.pendingWindowID) {
            guard let requested = openInbox.pendingWindowID else { return }
            openInbox.consume()
            if !model.windows.contains(where: { $0.id == requested }) { await model.load() }
            // Open only a window this iPhone is still a member of.
            if model.windows.contains(where: { $0.id == requested }) {
                openedWindowID = requested
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { openedWindowID != nil },
            set: { if !$0 { openedWindowID = nil } }
        )) {
            if let openedWindowID {
                GroupWindowScreen(client: model.client, windowID: openedWindowID)
            }
        }
        .accessibilityIdentifier("group-window-list")
    }

    /// Windows with photos kept here that the relay no longer lists for this
    /// iPhone. Only after a successful load, so being offline hides nothing.
    private func loadFormerWindows() async {
        guard model.hasLoaded, model.message == nil else { return }
        let store = GroupWindowLocalPhotoStore.shared
        let current = Set(model.windows.map(\.id))
        var former: [GroupWindowLocalPhotoStore.KnownWindow] = []
        for known in await store.knownWindows() where !current.contains(known.id) {
            if !(await store.entries(windowID: known.id)).isEmpty { former.append(known) }
        }
        formerWindows = former
    }

    private func formerRow(_ name: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold))
                Text("抜けたまど・届いた写真を見られます").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(minHeight: 44)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func knownRow(_ name: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold))
                Text("読み込み中").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(minHeight: 44)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ window: GroupWindow) -> some View {
        GroupWindowCard(window: window)
    }
}

/// A window is its newest photo: the card shows it (the Widget's copy, or the
/// newest photo kept on this iPhone; nothing is fetched), the name over it,
/// and who is in it.
private struct GroupWindowCard: View {
    let window: GroupWindow
    @State private var cover: UIImage?
    @State private var senderName: String?

    var body: some View {
        let paused = GroupWindowPresentation.isPaused(window)
        ZStack(alignment: .bottomLeading) {
            // The card's height comes from the 16:10 box, never from the photo's pixels.
            Color(uiColor: .secondarySystemGroupedBackground)
                .aspectRatio(16 / 10, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let cover {
                        Image(uiImage: cover).resizable().scaledToFill()
                    } else {
                        Image("ToolCat-snug").resizable().interpolation(.high).scaledToFit()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .opacity(0.9)
                    }
                }
            .clipped()
            .overlay(alignment: .bottom) {
                if cover != nil {
                    LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 96)
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.name)
                        .font(.title3.bold())
                    Text(paused ? "止まっています"
                         : senderName.map { "\(GroupDisplayName.withSan($0))から ・ \(window.memberCount)人" }
                           ?? "\(window.memberCount)人")
                        .font(.footnote)
                }
                .foregroundStyle(cover != nil ? Color.white : paused ? Color.orange : Color.primary)
                .shadow(color: cover != nil ? .black.opacity(0.5) : .clear, radius: 4, y: 1)
                Spacer(minLength: 0)
                HStack(spacing: -8) {
                    ForEach(window.activeMembers.prefix(4)) { member in
                        GroupMemberAvatar(name: member.displayName, size: 28)
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    }
                }
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.name)、\(paused ? "止まっています" : GroupWindowPresentation.memberCountText(window))")
        .task(id: window.id) { await loadCover() }
    }

    private func loadCover() async {
        if let cached = GroupWidgetCache.entry(windowID: window.id),
           let url = GroupWidgetCache.imageURL(for: cached),
           let image = UIImage(contentsOfFile: url.path) {
            cover = image
            senderName = cached.senderDisplayName
            return
        }
        // Not yet on the Widget: the newest photo this iPhone received.
        let store = GroupWindowLocalPhotoStore.shared
        let newest = await store.entries(windowID: window.id)
            .filter { !$0.isHidden }
            .max { $0.createdAt < $1.createdAt }
        guard let newest, let url = await store.imageURL(photoID: newest.id, windowID: window.id),
              let image = UIImage(contentsOfFile: url.path) else { return }
        cover = image
        senderName = newest.isOwn ? nil : newest.senderDisplayName
    }
}

// MARK: - People hidden on this iPhone (設定)

struct GroupHiddenMembersView: View {
    @State private var windows: [GroupWindowLocalPhotoStore.KnownWindow] = []
    @State private var loaded = false

    private struct Row: Identifiable {
        let window: GroupWindowLocalPhotoStore.KnownWindow
        let member: GroupWindowLocalPhotoStore.HiddenMember
        var id: String { window.id + "|" + member.id }
    }

    private var hidden: [Row] {
        windows.flatMap { window in (window.hiddenMembers ?? []).map { Row(window: window, member: $0) } }
    }

    var body: some View {
        List {
            ForEach(hidden) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(GroupDisplayName.withSan(item.member.name))")
                        Text(item.window.name).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("表示する") {
                        Task {
                            await GroupWindowLocalPhotoStore.shared.unhide(memberID: item.member.id, windowID: item.window.id)
                            windows = await GroupWindowLocalPhotoStore.shared.knownWindows()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(minHeight: 44)
            }
        }
        .overlay {
            if loaded && hidden.isEmpty {
                ContentUnavailableView("表示しないようにした人はいません", systemImage: "eye.slash",
                    description: Text("まどの写真の「…」から、その人の写真を表示しないようにできます。"))
            }
        }
        .navigationTitle("表示しないようにした人")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            windows = await GroupWindowLocalPhotoStore.shared.knownWindows()
            loaded = true
        }
    }
}

#if DEBUG
// MARK: - Screen fixture (simulator screenshots only)

/// `--group-window-screens-fixture`: the まど tab's group windows, one
/// window's photos, the photo detail and the members screen, on in-memory
/// data with code-drawn cat pictures. No relay, key, or account is touched.
actor GroupWindowScreenFixture: GroupWindowMediaClient {
    static let shared = GroupWindowScreenFixture()

    private let members = GroupWindowFixture(scenario: GroupWindowUIFixture.scenario, now: GroupWindowUIFixture.fixtureNow)
    private var hearts: [String: [GroupHeart]] = [:]
    private var sent: [GroupPhoto] = []

    private func photoList(_ window: GroupWindow) -> [GroupPhoto] {
        let others = window.members.filter { $0.id != window.myParticipantID }
        let now = GroupWindowUIFixture.fixtureNow
        let fixed = (1...6).map { index -> GroupPhoto in
            let sender = index % 3 == 0 || others.isEmpty ? nil : others[(index - 1) % others.count]
            let id = "fixture-group-photo-\(index)"
            return GroupPhoto(id: id, windowID: window.id,
                              senderParticipantID: sender?.id ?? window.myParticipantID,
                              senderDisplayName: sender?.displayName ?? "自分",
                              createdAt: now.addingTimeInterval(Double(-index) * 86_400),
                              fixtureAssetName: "app-store-screenshot-fixture-\(index)",
                              hearts: hearts[id] ?? (index == 1 ? [GroupHeart(participantID: others.first?.id ?? "",
                                  displayName: others.first?.displayName ?? "", active: true, updatedAt: now)] : []))
        }
        return sent + fixed
    }

    func windows() async throws -> [GroupWindow] { try await members.windows() }
    func window(id: String) async throws -> GroupWindow {
        GroupWindowUIFixture.applyDelivery(try await members.window(id: id))
    }
    func createWindow(name: String, operationID: UUID) async throws -> GroupWindow {
        try await members.createWindow(name: name, operationID: operationID)
    }
    func createInvitation(windowID: String, operation: GroupOperation) async throws -> GroupInvitation {
        try await members.createInvitation(windowID: windowID, operation: operation)
    }
    func revokeInvitation(id: String, windowID: String, operation: GroupOperation) async throws {
        try await members.revokeInvitation(id: id, windowID: windowID, operation: operation)
    }
    func apply(invitationID: String, displayName: String, operationID: UUID) async throws -> GroupJoinRequest {
        try await members.apply(invitationID: invitationID, displayName: displayName, operationID: operationID)
    }
    func joinStatus(requestID: String) async throws -> GroupJoinRequest { try await members.joinStatus(requestID: requestID) }
    func pendingRequests(windowID: String) async throws -> [GroupJoinRequest] {
        try await members.pendingRequests(windowID: windowID)
    }
    func approve(requestID: String, windowID: String, operation: GroupOperation) async throws -> GroupWindow {
        try await members.approve(requestID: requestID, windowID: windowID, operation: operation)
    }
    func reject(requestID: String, windowID: String, operation: GroupOperation) async throws {
        try await members.reject(requestID: requestID, windowID: windowID, operation: operation)
    }
    func cancel(requestID: String, operationID: UUID) async throws {
        try await members.cancel(requestID: requestID, operationID: operationID)
    }
    func addDevice(participantID: String, windowID: String, displayName: String,
                   operation: GroupOperation) async throws -> GroupWindow {
        try await members.addDevice(participantID: participantID, windowID: windowID,
                                    displayName: displayName, operation: operation)
    }
    func removeMember(participantID: String, windowID: String, operation: GroupOperation) async throws -> GroupWindow {
        try await members.removeMember(participantID: participantID, windowID: windowID, operation: operation)
    }
    func leave(windowID: String, operation: GroupOperation) async throws {
        try await members.leave(windowID: windowID, operation: operation)
    }
    func rotate(windowID: String, operation: GroupOperation) async throws -> GroupWindow {
        try await members.rotate(windowID: windowID, operation: operation)
    }
    func photos(windowID: String) async throws -> [GroupPhoto] {
        photoList(try await members.window(id: windowID))
    }
    func setHeart(photoID: String, windowID: String, active: Bool, operationID: UUID) async throws -> GroupPhoto {
        let window = try await members.window(id: windowID)
        guard var photo = photoList(window).first(where: { $0.id == photoID }) else { throw GroupClientError.invalidResponse }
        photo.hearts.removeAll { $0.participantID == window.myParticipantID }
        photo.hearts.append(GroupHeart(participantID: window.myParticipantID, displayName: "自分",
                                       active: active, updatedAt: GroupWindowUIFixture.fixtureNow))
        hearts[photoID] = photo.hearts
        return photo
    }

    func fetchPhoto(photoID: String, windowID: String) async throws -> GroupFetchedPhoto {
        let window = try await members.window(id: windowID)
        guard let photo = photoList(window).first(where: { $0.id == photoID }) else { throw GroupClientError.invalidResponse }
        let asset = photo.fixtureAssetName ?? "app-store-screenshot-fixture-1"
        let jpeg = await MainActor.run {
            AppStoreScreenshotFixture.image(for: asset)?.jpegData(compressionQuality: 0.8)
        }
        guard let jpeg else { throw GroupClientError.invalidResponse }
        return GroupFetchedPhoto(photo: photo, jpeg: jpeg, verified: nil)
    }

    func keep(_ fetched: GroupFetchedPhoto, outgoingOperationID: UUID?,
              persist: @escaping @Sendable (GroupPhoto, Data) async throws -> Void) async throws {
        try await persist(fetched.photo, fetched.jpeg)
    }

    func sendPhoto(normalizedJPEG: Data, windowID: String, operationID: UUID) async throws -> GroupPhoto {
        let window = try await members.window(id: windowID)
        let photo = GroupPhoto(id: "fixture-sent-" + operationID.uuidString.lowercased(), windowID: windowID,
                               senderParticipantID: window.myParticipantID, senderDisplayName: "自分",
                               createdAt: Date(), fixtureAssetName: "app-store-screenshot-fixture-7", hearts: [])
        sent.insert(photo, at: 0)
        return photo
    }
}

/// The fixture's on-device check: always safe, or "turned off" to show why
/// photos wait (`--group-window-screens-check-off`).
struct GroupWindowFixtureModeration: MomentModerating {
    func requireSafeImage(at url: URL) async throws {
        if GroupWindowUIFixture.checkIsOff { throw MomentSharingError.moderationDisabled }
    }
}
#endif
