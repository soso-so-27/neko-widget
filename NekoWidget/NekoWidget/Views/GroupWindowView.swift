import ImageIO
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
    func sendPhoto(normalizedJPEG: Data, caption: String?, windowID: String, operationID: UUID) async throws -> GroupPhoto
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
        case .hidden: return "センシティブな内容が含まれている可能性があるため、この写真は届けられません。"
        case .checkOff:
            return "写真を届けるには、「設定」→「プライバシーとセキュリティ」→「センシティブな内容の警告」をオンにしてください。"
        case .retryLater: return "写真を確かめられませんでした。少し待ってから、もう一度お試しください。"
        }
    }

    /// Why arrived photos are not shown yet. They wait on the relay until then.
    static func receiveMessage(_ verdict: Verdict) -> String {
        verdict == .checkOff
            ? "届いた写真を見るには、「設定」→「プライバシーとセキュリティ」→「センシティブな内容の警告」をオンにしてから、画面を下に引いて更新してください。"
            : "届いた写真を、まだ表示できません。少し待ってから、画面を下に引いて更新してください。"
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

    /// Who this iPhone is in the window: from the relay, or as last remembered.
    private var rememberedMe: String?
    /// Hearts tapped here and not yet answered by the relay: photo → (on, tap number).
    private var pendingHearts: [String: (active: Bool, tap: Int)] = [:]
    private var heartTaps = 0
    private var me: String? { window?.myParticipantID ?? rememberedMe }

    func myHeartIsActive(_ photoID: String) -> Bool {
        guard let me else { return false }
        return hearts[photoID]?.contains { $0.participantID == me && $0.active } ?? false
    }

    /// Photos and hearts already kept on this iPhone appear at once, before the relay answers.
    func showStored() async {
        if entries.isEmpty { entries = await store.entries(windowID: windowID) }
        if hearts.isEmpty { hearts = await store.hearts(windowID: windowID) }
        if rememberedMe == nil { rememberedMe = await store.myParticipantID(windowID: windowID) }
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
            await store.remember(windowID: windowID, name: latest.name, myParticipantID: latest.myParticipantID)
            let photos = try await client.photos(windowID: windowID)
            hearts = Dictionary(photos.map { ($0.id, $0.hearts) }, uniquingKeysWith: { _, last in last })
            // The relay's list may predate a tap still on its way; keep the tap.
            for (photoID, pending) in pendingHearts { applyMyHeart(pending.active, to: photoID) }
            await store.saveHearts(hearts, windowID: windowID)
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
                        isOwn: isOwn, caption: hidden ? nil : kept.caption
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

    /// Sends the confirmed photo with its ひとこと (encrypted with the window's
    /// key). The same words stay on this iPhone as the photo's own memo.
    func deliver(_ prepared: PreparedPhoto, memo: String) async {
        guard canSend, let me = window?.myParticipantID else { return }
        isSending = true
        sendCompleted = false
        failedDelivery = nil
        defer { isSending = false }
        do {
            let operationID = prepared.operationID
            let sent = try await client.sendPhoto(normalizedJPEG: prepared.jpeg, caption: memo,
                                                  windowID: windowID, operationID: operationID)
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
            return "インターネットにつながらず、届けられませんでした。つながったら「もう一度届ける」を押してください。"
        case .some(.unavailable):
            return "うまく届けられませんでした。少し待ってから「もう一度届ける」を押してください。"
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
                ?? "お気に入りに追加できませんでした。少し待ってから、もう一度お試しください。"
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
        catch is CancellationError {}
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
        let active = !myHeartIsActive(photoID)
        // Show the heart at once; the relay confirms (or corrects) it after.
        let before = hearts[photoID]
        heartTaps += 1
        let tap = heartTaps
        pendingHearts[photoID] = (active, tap)
        applyMyHeart(active, to: photoID)
        do {
            let updated = try await client.setHeart(
                photoID: photoID, windowID: windowID,
                active: active, operationID: UUID()
            )
            // A newer tap on the same photo wins; its own answer comes later.
            guard pendingHearts[photoID]?.tap == tap else { return }
            pendingHearts[photoID] = nil
            hearts[photoID] = updated.hearts
            await store.saveHearts(hearts, windowID: windowID)
        } catch {
            guard pendingHearts[photoID]?.tap == tap else { return }
            pendingHearts[photoID] = nil
            hearts[photoID] = before
            message = GroupWindowPresentation.message(for: error)
        }
    }

    private func applyMyHeart(_ active: Bool, to photoID: String) {
        guard let me else { return }
        var current = hearts[photoID] ?? []
        if let index = current.firstIndex(where: { $0.participantID == me }) {
            current[index].active = active
        } else {
            let name = window?.activeMembers.first { $0.id == me }?.displayName ?? "あなた"
            current.append(GroupHeart(participantID: me, displayName: name, active: active, updatedAt: Date()))
        }
        hearts[photoID] = current
    }
}

/// The app's own cat photos, handed to the window screens so 「写真を届ける」
/// starts from cats rather than the whole Photos library.
struct GroupWindowCatPhotosKey: EnvironmentKey {
    static let defaultValue: [PhotoPresentation] = []
}

extension EnvironmentValues {
    var groupWindowCatPhotos: [PhotoPresentation] {
        get { self[GroupWindowCatPhotosKey.self] }
        set { self[GroupWindowCatPhotosKey.self] = newValue }
    }
}

/// Picks one of the app's cat photos to deliver; the Photos app stays one
/// tap away for anything else.
private struct GroupCatPhotoPickerSheet: View {
    let photos: [PhotoPresentation]
    @Binding var pickedItem: PhotosPickerItem?
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(photos) { photo in
                        Button {
                            choose(photo.localIdentifier)
                        } label: {
                            PhotoAssetImageView(
                                localIdentifier: photo.localIdentifier,
                                catBoundingBox: photo.catBoundingBox,
                                targetPixelSize: CGSize(width: 360, height: 360),
                                networkAccessAllowed: false
                            )
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("group-window-cat-photo-\(photo.localIdentifier)")
                    }
                }
            }
            .navigationTitle("届ける写真を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                    Label("写真アプリから選ぶ", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
                .accessibilityIdentifier("group-window-send-photo-library")
            }
            .onChange(of: pickedItem) { _, item in
                if item != nil { dismiss() }
            }
        }
    }
}

private struct GroupLibraryDeliveryRequest: Identifiable {
    let localIdentifier: String
    var id: String { localIdentifier }
}

struct GroupWindowScreen: View {
    @StateObject private var model: GroupWindowScreenModel
    @Environment(\.groupWindowCatPhotos) private var catPhotos
    @State private var showsCatPicker = false
    @State private var libraryDelivery: GroupLibraryDeliveryRequest?
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
                    Label("このまどから抜けました。",
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
                }
                if let notice = model.receiveNotice {
                    Label(notice, systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("group-window-receive-notice")
                }
                // Photos already here stay as they are while new ones are checked
                // quietly; new photos simply appear. Only an empty window says it is loading.
                if model.entries.isEmpty && model.isSyncing {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .accessibilityLabel("写真を読み込んでいます")
                        .accessibilityIdentifier("group-window-syncing")
                } else if model.entries.isEmpty {
                    ContentUnavailableView(
                        "まだ写真はありません",
                        systemImage: "photo.on.rectangle",
                        description: Text(model.isFormer
                            ? "このiPhoneに残っている写真はありません。"
                            : "届けた写真と届いた写真が、ここに並びます。")
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
            Text("消したあとは元に戻せません。")
        }
        .safeAreaInset(edge: .bottom) {
            if !model.isFormer { sendBar }
        }
        .sheet(isPresented: $showsCatPicker) {
            GroupCatPhotoPickerSheet(photos: catPhotos, pickedItem: $pickedItem) { identifier in
                showsCatPicker = false
                libraryDelivery = GroupLibraryDeliveryRequest(localIdentifier: identifier)
            }
        }
        .sheet(item: $libraryDelivery) { request in
            NavigationStack {
                GroupLibraryDeliveryStep(model: model, localIdentifier: request.localIdentifier) {
                    libraryDelivery = nil
                }
                .navigationTitle("まどに届ける")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            // Photos this person reported stay covered on this iPhone, from the first frame.
            await GroupSafety.shared.loadRecords(windowID: model.windowID)
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
            if catPhotos.isEmpty {
                // No cat photos found yet: the Photos app is the only source.
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
            } else {
                // The app's cat photos first; the Photos app from inside the picker.
                Button {
                    showsCatPicker = true
                } label: {
                    Label(model.isSending ? "届けています…" : "写真を届ける", systemImage: "paperplane")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .opacity(model.failedDelivery == nil ? 1 : 0.45)
                .disabled(!model.canSend)
                .accessibilityIdentifier("group-window-send-photo")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// One photo in the window's feed: the picture, then one line with who sent
/// it, when, and the hearts. Tap opens it; a double tap sends a heart.
/// Reads a kept JPEG at a size fit for the screen, off the main thread, so a
/// list of photos scrolls without stalls.
enum GroupPhotoDecoder {
    static func image(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        let thumbnail: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

private struct GroupPhotoTile: View {
    @ObservedObject var model: GroupWindowScreenModel
    let entry: GroupWindowLocalPhotoStore.Entry
    let open: () -> Void
    @State private var image: UIImage?
    @ObservedObject private var safety = GroupSafety.shared

    private var heartCount: Int { model.hearts[entry.id]?.filter(\.active).count ?? 0 }
    private var reported: Bool { safety.hasReported(entry.id, in: model.windowID) }
    private var canHeart: Bool { !entry.isHidden && !reported && !entry.isOwn && !model.isFormer }

    var body: some View {
        VStack(spacing: 0) {
            Color(uiColor: .tertiarySystemFill)
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    if reported {
                        Label("通報した写真", systemImage: "eye.slash")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if entry.isHidden {
                        Image(systemName: "eye.slash").font(.title2).foregroundStyle(.secondary)
                    } else if let image {
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
                GroupMemberAvatar(name: entry.isOwn ? "あなた" : entry.senderDisplayName, size: 24)
                Text(entry.isOwn ? "あなた" : entry.senderDisplayName)
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
        .accessibilityHint("大きく表示します。ハートも送れます")
        .accessibilityAction(named: Text("大きく見る"), open)
        .task(id: entry.id) {
            guard !entry.isHidden, let url = await model.imageURL(for: entry) else { return }
            image = await Task.detached(priority: .userInitiated) {
                GroupPhotoDecoder.image(at: url, maxPixel: 900)
            }.value
        }
        .onChange(of: reported) { _, covered in if covered { image = nil } }
    }
}

private extension GroupPhotoTile {
    var tileLabel: String {
        var parts = [entry.isOwn ? "自分が届けた写真" : "\(GroupDisplayName.withSan(entry.senderDisplayName))から届いた写真"]
        if reported { parts.append("通報した写真") } else if entry.isHidden { parts.append("表示していない写真") }
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
                    ContentUnavailableView("届けられるまどがありません", systemImage: "window.vertical.closed",
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
                    GroupCaptionField(text: $memo)
                    if let message = model.message {
                        Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        Task { await model.deliver(prepared, memo: memo) }
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
                    .disabled(model.isSending || GroupPhotoCaption.validationMessage(for: memo) != nil)
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

/// Shown after a photo is picked: the photo, where it goes, and ひとこと for
/// the window. Nothing is sent until 「届ける」.
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
                GroupCaptionField(text: $memo)
            }
            .navigationTitle("「\(windowName)」に届ける")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button { deliver(memo) } label: {
                    Label("届ける", systemImage: "paperplane").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(GroupPhotoCaption.validationMessage(for: memo) != nil)
                .accessibilityIdentifier("group-window-send-confirm")
                .padding().background(.regularMaterial)
            }
        }
    }
}

/// ひとこと on the send confirmation: what the window will read, and that the
/// same words stay as this iPhone's memo. Empty sends the photo alone.
private struct GroupCaptionField: View {
    @Binding var text: String

    var body: some View {
        Section {
            TextField("例：おなかを見せて寝ていた", text: $text, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityIdentifier("group-window-send-caption")
            if let message = GroupPhotoCaption.validationMessage(for: text) {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        } header: { Text("ひとこと") }
          footer: { Text("まどのみんなに届きます（\(GroupPhotoCaption.maximumCharacters)文字・改行\(GroupPhotoCaption.maximumLineBreaks)つまで）。") }
    }
}

private struct GroupPhotoDetail: View {
    @ObservedObject var model: GroupWindowScreenModel
    @State private var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var showsFavoriteConfirmation = false
    @State private var showsRemoveConfirmation = false
    @State private var showsHideConfirmation = false
    @State private var reportTarget: GroupWindowLocalPhotoStore.Entry?
    @State private var showsBlockConfirmation = false
    @ObservedObject private var safety = GroupSafety.shared

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
                    if let caption = current.caption, !current.isHidden,
                       !safety.hasReported(current.id, in: model.windowID) {
                        Text(caption)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .accessibilityIdentifier("group-photo-caption")
                    }
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
                            if safety.service.isAvailable {
                                if !safety.hasReported(current.id, in: model.windowID) {
                                    Button("この写真を通報", systemImage: "exclamationmark.bubble") { reportTarget = current }
                                        .accessibilityIdentifier("group-photo-report")
                                }
                                Button("\(GroupDisplayName.withSan(current.senderDisplayName))をブロック", systemImage: "hand.raised") {
                                    showsBlockConfirmation = true
                                }
                                .accessibilityIdentifier("group-photo-block")
                            } else if SharingAPIConfiguration.current.isOwnerInternalReportsDisabled {
                                Text("この内部版では通報の受付を停止しています")
                            }
                        }
                        Button("このiPhoneから消す", systemImage: "trash", role: .destructive) {
                            showsRemoveConfirmation = true
                        }
                        if let url = SharingAPIConfiguration.current.supportURL {
                            Link(destination: url) { Label("問い合わせる", systemImage: "exclamationmark.bubble") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("この写真の操作")
                    .accessibilityIdentifier("group-photo-menu")
                    .simultaneousGesture(TapGesture().onEnded {
                        Task { await safety.load(windowID: model.windowID) }
                    })
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
                Text("写真アプリに保存して、お気に入りに入れます（位置情報は付きません）。届けた人には知らせません。")
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
                Text("この人から届いた写真が、このまどで見えなくなります。相手には知らせず、設定の「表示しないようにした人」から戻せます。")
            }
            .modifier(GroupPhotoSafetyDialogs(windowID: model.windowID, current: current,
                                              reportTarget: $reportTarget,
                                              showsBlockConfirmation: $showsBlockConfirmation) { blocked in
                await model.hideSender(of: blocked)
                if model.entries.isEmpty { dismiss() } else if let first = model.entries.first { selection = first.id }
            })
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
                Text("消したあとは元に戻せません。")
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.actionMessage = nil }
        .task(id: selection) { await safety.load(windowID: model.windowID) }
        .onChange(of: selection) { _, _ in model.actionMessage = nil }
    }

    private func neighbor(of entry: GroupWindowLocalPhotoStore.Entry) -> String? {
        guard let index = model.entries.firstIndex(where: { $0.id == entry.id }) else { return nil }
        if index + 1 < model.entries.count { return model.entries[index + 1].id }
        return index > 0 ? model.entries[index - 1].id : nil
    }

    /// Who, when, and who sent a heart (as their coloured circles). No
    /// sentence, no page count; the spoken label keeps the full sentence.
    private func details(_ entry: GroupWindowLocalPhotoStore.Entry) -> some View {
        let day = entry.createdAt.formatted(.dateTime.month().day())
        let names = reactors(entry)
        let spokenDay = entry.isOwn ? "\(day)に届けました" : "\(day)に届きました"
        // One line: who and when. The hearts live on the ♥ button below; who
        // sent them is in its spoken value.
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.isOwn ? "あなた" : GroupDisplayName.withSan(entry.senderDisplayName))
                .font(.subheadline.weight(.semibold))
            Text(day).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((entry.isOwn ? "あなたの写真、\(spokenDay)" : "\(GroupDisplayName.withSan(entry.senderDisplayName))から、\(spokenDay)")
                            + (names.isEmpty ? "" : "。ハートを送った人：\(names.joined(separator: "、"))"))
    }

    /// Under the photo: ♥ with its count, and お気に入り. Words only as captions.
    @ViewBuilder
    private func actions(_ entry: GroupWindowLocalPhotoStore.Entry) -> some View {
        let heartCount = reactors(entry).count
        let mine = model.myHeartIsActive(entry.id)
        let shown = !entry.isHidden && !safety.hasReported(entry.id, in: model.windowID)
        HStack(spacing: 0) {
            if shown && !entry.isOwn && !model.isFormer {
                Button {
                    Task { await model.toggleHeart(entry.id) }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: mine ? "heart.fill" : "heart").font(.title2)
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: mine)
                        Text(heartCount > 0 ? heartCount.formatted() : "ハート").font(.caption2.monospacedDigit())
                            .contentTransition(.numericText())
                            .animation(.snappy, value: heartCount)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(mine ? Color.red : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .light), trigger: mine) { _, sent in sent }
                .accessibilityLabel(mine ? "ハートを送りました" : "ハートを送る")
                .accessibilityValue(heartCount > 0 ? "\(heartCount)" : "")
                .accessibilityIdentifier("group-photo-heart")
            }
            if shown && !entry.isOwn {
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
    @ObservedObject private var safety = GroupSafety.shared

    var body: some View {
        Group {
            if safety.hasReported(entry.id, in: model.windowID) {
                ContentUnavailableView("通報した写真", systemImage: "eye.slash",
                    description: Text("このiPhoneでは表示しません。結果は、まどの「メンバー」の「通報への返答」でお知らせします。"))
            } else if entry.isHidden {
                ContentUnavailableView("この写真は表示しません", systemImage: "eye.slash",
                    description: Text("センシティブな内容が含まれている可能性があります。右上の「…」から消せます。"))
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

    /// Test builds only: how long the last list load took, to find where the wait is.
    @Published private(set) var lastLoadTiming: String?
    private var completedLoads = 0
    private var firstLoadSeconds: TimeInterval?

    func load() async {
        let started = ProcessInfo.processInfo.systemUptime
        let trace = InternalBuildPresentationAvailability.isAvailable ? GroupListTrace() : nil
        var outcome = "完了"
        defer {
            if let trace {
                let seconds = ProcessInfo.processInfo.systemUptime - started
                completedLoads += 1
                if firstLoadSeconds == nil { firstLoadSeconds = seconds }
                lastLoadTiming = String(format: "一覧の読み込み %.1f 秒（%d 回目・初回 %.1f 秒）・まど %d 個・%@",
                    seconds, completedLoads, firstLoadSeconds ?? seconds, windows.count, outcome)
                    + "\n" + trace.snapshot().text(total: seconds)
            }
        }
        do {
            windows = try await GroupListMeasurement.$current.withValue(trace) { try await client.windows() }
            message = nil
            hasLoaded = true
        } catch is CancellationError {
            outcome = "中断"
            // The screen went away mid-request: nothing to tell.
        } catch {
            outcome = "失敗"
            message = GroupWindowPresentation.message(for: error)
            hasLoaded = true
        }
    }

    /// Set when the relay answers that making a window needs Plus.
    @Published var needsPlus = false

    /// The creator's own name goes with the window (#470), so the others see
    /// it instead of a local word such as 「自分」.
    func create(name: String, ownerName: String) async -> GroupWindow? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !owner.isEmpty, !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let window = try await client.createWindow(name: trimmed, ownerDisplayName: owner, operationID: UUID())
            GroupDisplayName.remember(owner)
            // Keep the created window on an invitation-network failure; retrying must not create another window.
            do { _ = try await client.createInvitation(windowID: window.id, operation: GroupOperation(expectedRevision: window.revision)) }
            catch { message = "まどを作りました。招待リンクは、まどの「メンバー」から作れます。" }
            Task { await GroupAdmissionService.shared.refresh(requestPermission: true) }
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
    @State private var ownerName = GroupDisplayName.remembered
    @State private var createdWindowID: String?

    init(client: any GroupWindowMediaClient) {
        _model = StateObject(wrappedValue: GroupWindowListModel(client: client))
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedOwner: String { ownerName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooLong: Bool { !GroupDisplayName.fits(trimmed) || !GroupDisplayName.fits(trimmedOwner) }

    var body: some View {
        Form {
            Section {
                TextField("例：実家のまど", text: $name)
                    .accessibilityIdentifier("group-window-create-name")
            } header: { Text("まどの名前") }
            Section {
                TextField("例：お母さん", text: $ownerName)
                    .textContentType(.nickname)
                    .accessibilityIdentifier("group-window-create-owner-name")
            } header: { Text("あなたの名前") }
              footer: {
                  Text(tooLong ? GroupDisplayName.tooLongMessage : "メンバーには、この名前で表示されます。")
                      .foregroundStyle(tooLong ? .red : .secondary)
              }
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
                        Task { createdWindowID = await model.create(name: trimmed, ownerName: trimmedOwner)?.id }
                    } label: {
                        Text("作る").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty || trimmedOwner.isEmpty || tooLong || model.isWorking)
                    .accessibilityIdentifier("group-window-create-confirm")
                }
            } footer: {
                GroupWindowStandardsAgreement(action: "作る")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .navigationTitle("まどを作る")
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

/// Under 「作る」 and 「参加する」: pressing it is agreeing to the community
/// standards, said before the press, with the standards one tap away (1.2).
struct GroupWindowStandardsAgreement: View {
    let action: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("「\(action)」を押すと、コミュニティ基準に同意したことになります。人を傷つける写真や、写っている人の同意がない写真は届けられません。")
            if let url = SharingAPIConfiguration.current.communityStandardsURL {
                Link("コミュニティ基準を読む", destination: url)
            }
        }
        .font(.footnote)
        .padding(.top, 8)
        .accessibilityIdentifier("group-window-standards-agreement")
    }
}

/// Shown in the まど tab only in builds with group windows turned on.
struct GroupWindowListSection: View {
    @StateObject private var model: GroupWindowListModel
    @State private var openedWindowID: String?
    @State private var formerWindows: [GroupWindowLocalPhotoStore.KnownWindow] = []
    @ObservedObject private var openInbox = GroupWindowOpenInbox.shared

    /// Test builds' new まど layout: 「わたしのまど」 with a small 「＋」, and no
    /// large create button (making a window is rare; seeing them is daily).
    let compactHeader: Bool

    init(client: any GroupWindowMediaClient, compactHeader: Bool = false) {
        _model = StateObject(wrappedValue: GroupWindowListModel(client: client))
        self.compactHeader = compactHeader
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if compactHeader {
                HStack {
                    Text("わたしのまど")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    NavigationLink {
                        GroupWindowCreateScreen(client: model.client)
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 32)
                    }
                    .disabled(model.isWorking)
                    .accessibilityLabel("まどを作る")
                    .accessibilityIdentifier("group-window-create")
                }
            } else {
                Text("みんなのまど")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(model.windows) { window in
                NavigationLink {
                    GroupWindowScreen(client: model.client, windowID: window.id)
                } label: {
                    row(window)
                }
                .buttonStyle(.plain)
            }
            let known = GroupWidgetCache.entries()
            if model.windows.isEmpty, !model.hasLoaded || model.message != nil {
                // Names kept on this iPhone from the last visit: shown while the
                // list loads, and kept when the relay cannot be reached.
                ForEach(known, id: \.windowID) { entry in
                    NavigationLink {
                        GroupWindowScreen(client: model.client, windowID: entry.windowID)
                    } label: {
                        KnownWindowCard(entry: entry, subtitle: model.hasLoaded ? "前回の内容です" : "")
                    }
                    .buttonStyle(.plain)
                }
                if !model.hasLoaded && known.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .accessibilityLabel("まどを読み込んでいます")
                        .accessibilityIdentifier("group-window-list-loading")
                }
            }
            if let message = model.message {
                if model.windows.isEmpty && known.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(.red)
                } else {
                    // A refresh that failed is not an emergency: say so quietly, with a retry.
                    HStack(spacing: 8) {
                        Text("いまは新しい内容を読み込めません。").font(.footnote).foregroundStyle(.secondary)
                        Button("もう一度") { Task { await model.load() } }
                            .font(.footnote.weight(.semibold))
                            .disabled(model.isWorking)
                    }
                    .accessibilityIdentifier("group-window-list-stale")
                }
            }
            if !compactHeader {
                NavigationLink {
                    GroupWindowCreateScreen(client: model.client)
                } label: {
                    Label("まどを作る", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
                .accessibilityIdentifier("group-window-create")
            }
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
                Text("抜けたまどです。届いた写真は見られます").font(.caption).foregroundStyle(.secondary)
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
                    Text(paused ? "止まっています" : "\(window.memberCount)人")
                        .font(.footnote)
                }
                .foregroundStyle(cover != nil ? Color.white : paused ? Color.orange : Color.primary)
                .shadow(color: cover != nil ? .black.opacity(0.5) : .clear, radius: 4, y: 1)
                Spacer(minLength: 0)
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
           let url = GroupWidgetCache.imageURL(for: cached) {
            cover = await Task.detached(priority: .userInitiated) { GroupPhotoDecoder.image(at: url, maxPixel: 800) }.value
            senderName = cached.senderDisplayName
            if cover != nil { return }
        }
        // Not yet on the Widget: the newest photo this iPhone received.
        let store = GroupWindowLocalPhotoStore.shared
        let newest = await store.entries(windowID: window.id)
            .filter { !$0.isHidden }
            .max { $0.createdAt < $1.createdAt }
        guard let newest, let url = await store.imageURL(photoID: newest.id, windowID: window.id) else { return }
        cover = await Task.detached(priority: .userInitiated) { GroupPhotoDecoder.image(at: url, maxPixel: 800) }.value
        senderName = newest.isOwn ? nil : newest.senderDisplayName
    }
}

/// A window this iPhone knows from last time, drawn like a loaded one so the
/// tab does not change shape when the relay answers.
private struct KnownWindowCard: View {
    let entry: GroupWidgetCache.Entry
    let subtitle: String
    @State private var cover: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.windowName).font(.title3.bold())
                if !subtitle.isEmpty { Text(subtitle).font(.footnote) }
            }
            .foregroundStyle(cover != nil ? Color.white : Color.primary)
            .shadow(color: cover != nil ? .black.opacity(0.5) : .clear, radius: 4, y: 1)
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.windowName)
        .task(id: entry.windowID) {
            guard let url = GroupWidgetCache.imageURL(for: entry) else { return }
            cover = await Task.detached(priority: .userInitiated) { GroupPhotoDecoder.image(at: url, maxPixel: 800) }.value
        }
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
    static let captionExamples: [String?] = [nil, "きょうものんびり", String(repeating: "猫", count: 100), "朝のまど\nお昼寝\nまたあした"]


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
                                  displayName: others.first?.displayName ?? "", active: true, updatedAt: now)] : []),
                              caption: CommandLine.arguments.contains("--group-window-caption-fixture")
                                ? Self.captionExamples[(index - 1) % Self.captionExamples.count] : nil)
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
    func createWindow(name: String, ownerDisplayName: String, operationID: UUID) async throws -> GroupWindow {
        try await members.createWindow(name: name, ownerDisplayName: ownerDisplayName, operationID: operationID)
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
        try await sendPhoto(normalizedJPEG: normalizedJPEG, caption: nil, windowID: windowID, operationID: operationID)
    }
    func sendPhoto(normalizedJPEG: Data, caption: String?, windowID: String, operationID: UUID) async throws -> GroupPhoto {
        let caption = try GroupPhotoCaption.normalized(caption)
        let window = try await members.window(id: windowID)
        let photo = GroupPhoto(id: "fixture-sent-" + operationID.uuidString.lowercased(), windowID: windowID,
                               senderParticipantID: window.myParticipantID, senderDisplayName: "自分",
                               createdAt: Date(), fixtureAssetName: "app-store-screenshot-fixture-7", hearts: [], caption: caption)
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

/// Reporting one photo: why, and what is sent. Only this photo, as an
/// encrypted copy, kept 7 days for the team to check. Sent is not received:
/// the sheet says so only once the team has it.
struct GroupReportSheet: View {
    let windowID: String
    let entry: GroupWindowLocalPhotoStore.Entry
    @ObservedObject private var safety = GroupSafety.shared
    @Environment(\.dismiss) private var dismiss
    @State private var reason: GroupReportReason?
    @State private var record: GroupReportRecord?

    var body: some View {
        NavigationStack {
            Form {
                if let record, record.progress == .received {
                    Section {
                        Label("通報しました", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                    } footer: {
                        Text("この写真は、このiPhoneではもう表示されません。運営が確かめて、結果をまどの「メンバー」→「通報への返答」でお知らせします。")
                    }
                    if let number = record.receiptNumber {
                        Section {
                            GroupReportReceiptRow(number: number)
                        } footer: {
                            Text("問い合わせるときは、この番号を添えてください。")
                        }
                    }
                } else {
                    Section {
                        ForEach(GroupReportReason.allCases, id: \.self) { candidate in
                            Button {
                                reason = candidate
                            } label: {
                                HStack {
                                    Text(candidate.title).foregroundStyle(.primary)
                                    Spacer()
                                    if reason == candidate { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                            .disabled(record != nil)
                        }
                    } header: {
                        Text("理由")
                    } footer: {
                        Text("運営に送るのはこの写真1枚だけで、ひとことは送りません（7日後に削除）。送ると、この写真はこのiPhoneでは見えなくなります。")
                    }
                    if let record, record.progress == .retryable {
                        Section {
                            Text(GroupSafetyError.unknownOutcome.message).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("この写真を通報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(record?.progress == .received ? "閉じる" : "やめる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if record?.progress != .received {
                        Button(record?.progress == .retryable ? "もう一度送る" : "送る") { Task { await send() } }
                            .disabled(reason == nil || safety.isWorking)
                            .accessibilityIdentifier("group-report-send")
                    }
                }
            }
            .alert("通報", isPresented: Binding(get: { safety.failure != nil }, set: { if !$0 { safety.failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(safety.failure?.message ?? "") }
        }
        .interactiveDismissDisabled(safety.isWorking)
    }

    /// The first tap fixes the photo, reason and consent; a retry sends the
    /// same draft again instead of making a second report.
    private func send() async {
        let service = safety.service
        if let draft = record {
            record = await safety.run(windowID: windowID) { try await service.resumeReport(draftID: draft.id) } ?? draft
            return
        }
        guard let reason else { return }
        let entry = entry
        record = await safety.run(windowID: windowID) {
            let draftID = try await service.prepareReport(windowID: windowID, photoID: entry.id,
                                                          senderName: entry.senderDisplayName, reason: reason,
                                                          consent: GroupReportConsent(acceptedAt: Date()))
            do {
                return try await service.submitReport(draftID: draftID)
            } catch let error as GroupSafetyError where error == .offline || error == .unknownOutcome {
                return try await service.refreshReport(draftID: draftID)
            }
        }
    }
}

/// This person's reports in this window and the team's answers. Kept after
/// leaving the window; an answer never deletes a photo here.
struct GroupReportsView: View {
    let windowID: String
    @ObservedObject private var safety = GroupSafety.shared

    private var records: [GroupReportRecord] { safety.records[windowID] ?? [] }

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView("通報はありません", systemImage: "exclamationmark.bubble")
            }
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(record.reason.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(record.sentAt.formatted(.dateTime.month().day())).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(Self.text(record)).font(.footnote).foregroundStyle(.secondary)
                    if let number = record.receiptNumber, record.progress == .received {
                        Text("通報番号 \(number)")
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if record.progress == .retryable {
                        Button("もう一度送る") {
                            Task {
                                await safety.run(windowID: windowID) { try await safety.service.resumeReport(draftID: record.id) }
                            }
                        }
                        .font(.footnote)
                        .disabled(safety.isWorking)
                    }
                }
                .padding(.vertical, 2)
            }
            if let prototype = safety.service as? GroupReportingPrototype, !records.isEmpty {
                Section {
                    DisclosureGroup("テスト用") {
                        Button("返答が届いたときを試す") {
                            prototype.tryReply(windowID: windowID)
                            Task { await safety.load(windowID: windowID) }
                        }
                    }
                }
            }
        }
        .navigationTitle("通報への返答")
        .navigationBarTitleDisplayMode(.inline)
        .task { await safety.refresh(windowID: windowID) }
        .refreshable { await safety.refresh(windowID: windowID) }
    }

    /// What the answer means, in the app's own words. Never the server's.
    static func text(_ record: GroupReportRecord) -> String {
        // A received report keeps its answer after the photo's 7 days end.
        if record.reply != .none, record.progress == .received || record.progress == .expired {
            return replyText(record.reply)
        }
        switch record.progress {
        case .preparing, .sending: return "送っています。"
        case .retryable: return "まだ送れていません。"
        case .expired: return "時間がたったため、送れませんでした。"
        case .alreadyReported: return "この写真はもう通報しています。"
        case .authenticationRequired, .unavailable: return "送れませんでした。"
        case .received: break
        }
        return replyText(record.reply)
    }

    /// The same words whether a person or the 7-day rule stopped the photo.
    private static func replyText(_ reply: GroupReportReply) -> String {
        switch reply {
        case .none: return "通報しました。運営からの返答はまだありません。"
        case .noAction: return "運営が確かめました。今回は、この写真はほかのメンバーには見えたままです。"
        case .restricted: return "この写真を、このまどで見られないようにしました。"
        case .released: return "止めていた写真を、また見られるようにしました。"
        case .unknown: return "運営から返答があります。アプリを最新にすると読めます。"
        }
    }
}

/// The number to quote when asking about a report. It opens nothing by itself.
private struct GroupReportReceiptRow: View {
    let number: String

    var body: some View {
        LabeledContent("通報番号") {
            Text(number).font(.body.monospaced()).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("group-report-receipt-number")
    }
}

/// The photo's report sheet and block question, kept apart from the photo
/// screen so its long chain of modifiers stays quick to compile.
private struct GroupPhotoSafetyDialogs: ViewModifier {
    let windowID: String
    let current: GroupWindowLocalPhotoStore.Entry?
    @Binding var reportTarget: GroupWindowLocalPhotoStore.Entry?
    @Binding var showsBlockConfirmation: Bool
    let afterBlock: (GroupWindowLocalPhotoStore.Entry) async -> Void
    @ObservedObject private var safety = GroupSafety.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $reportTarget) { entry in
                GroupReportSheet(windowID: windowID, entry: entry)
            }
            // Blocking stops photos both ways in this window. What already
            // arrived stays; the other person is not told.
            .confirmationDialog(blockQuestion, isPresented: $showsBlockConfirmation, titleVisibility: .visible) {
                Button("ブロックする", role: .destructive) { block() }
                Button("戻る", role: .cancel) {}
            } message: {
                Text("このまどで、お互いの写真が届かなくなります。相手には知らせません。")
            }
            .alert("まど", isPresented: failureShown) {
                Button("OK", role: .cancel) {}
            } message: { Text(safety.failure?.message ?? "") }
    }

    private var blockQuestion: String {
        guard let current else { return "" }
        return GroupDisplayName.withSan(current.senderDisplayName) + "をブロックしますか？"
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { safety.failure != nil }, set: { if !$0 { safety.failure = nil } })
    }

    private func block() {
        guard let current else { return }
        let service = safety.service
        let windowID = windowID
        Task {
            let done: Void? = await safety.run(windowID: windowID) {
                try await service.setBlock(windowID: windowID, participantID: current.senderParticipantID,
                                           active: true, operationID: UUID())
            }
            if done != nil { await afterBlock(current) }
        }
    }
}
