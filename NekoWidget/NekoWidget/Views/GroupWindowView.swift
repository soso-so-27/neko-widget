import PhotosUI
import SwiftUI
import UIKit
import WidgetKit
import UniformTypeIdentifiers

// Group windows in the まど tab: the list, one window's photos, sending, and
// receiving. Signing, keys, and the relay stay inside
// `ProductionGroupWindowClient`; this file only keeps verified photos on this
// iPhone and draws them. It is reached only when
// `GroupWindowClientProvider.production` exists (GroupWindowsEnabled builds).

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
    enum Verdict { case safe, hidden, retryLater }

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

    let windowID: String
    let client: ProductionGroupWindowClient
    private let store: GroupWindowLocalPhotoStore
    private let moderation: any MomentModerating

    init(client: ProductionGroupWindowClient, windowID: String,
         store: GroupWindowLocalPhotoStore = .shared,
         moderation: any MomentModerating = MomentModerationService()) {
        self.client = client
        self.windowID = windowID
        self.store = store
        self.moderation = moderation
    }

    var isPaused: Bool { window.map(GroupWindowPresentation.isPaused) ?? false }

    var canSend: Bool {
        guard let window, window.state == .active, !isPaused else { return false }
        return !isSending && !isPreparing
    }

    /// A checked photo waiting on the confirmation screen.
    struct PreparedPhoto: Identifiable {
        let id = UUID()
        let jpeg: Data
        /// The Photos item, for the owner's own memo. Nil when unknown.
        let photoIdentifier: String?
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
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let latest = try await client.window(id: windowID)
            window = latest
            let photos = try await client.photos(windowID: windowID)
            hearts = Dictionary(photos.map { ($0.id, $0.hearts) }, uniquingKeysWith: { _, last in last })
            for photo in photos {
                guard !(await store.contains(photoID: photo.id, windowID: windowID)) else { continue }
                await receive(photo, me: latest.myParticipantID)
                // Each photo shows as soon as it is kept, not after all of them.
                entries = await store.entries(windowID: windowID)
            }
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

    private func receive(_ photo: GroupPhoto, me: String, outgoingOperationID: UUID? = nil) async {
        do {
            let incoming = try await client.downloadPhoto(photoID: photo.id, windowID: windowID)
            let isOwn = photo.senderParticipantID == me
            // A photo this iPhone sent was checked before sending.
            let verdict: GroupPhotoModeration.Verdict
            if isOwn {
                verdict = .safe
            } else {
                verdict = await GroupPhotoModeration.check(incoming.jpeg, with: moderation)
            }
            guard verdict != .retryLater else { return } // keep unacknowledged; try next time
            let store = self.store
            let windowID = self.windowID
            _ = try await client.storeAndAcknowledge(incoming, outgoingOperationID: outgoingOperationID) { verified in
                try await store.save(
                    .init(
                        id: verified.photo.id,
                        senderParticipantID: verified.photo.senderParticipantID,
                        senderDisplayName: verified.photo.senderDisplayName,
                        createdAt: verified.photo.createdAt,
                        isHidden: verdict == .hidden,
                        isOwn: isOwn
                    ),
                    jpeg: verdict == .hidden ? nil : verified.jpeg,
                    windowID: windowID
                )
            }
        } catch {
            // Leave it for the next sync; the relay keeps it until acknowledged.
        }
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
        switch await GroupPhotoModeration.check(picked.jpeg, with: moderation) {
        case .safe: break
        case .hidden:
            message = "この写真は届けられません。iPhoneがセンシティブな内容と判断しました。"
            return nil
        case .retryLater:
            message = "写真を確認できませんでした。iPhoneの設定で「センシティブな内容の警告」がオンか確かめてください。"
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
        defer { isSending = false }
        do {
            let operationID = UUID()
            let sent = try await client.sendPhoto(normalizedJPEG: prepared.jpeg, windowID: windowID, operationID: operationID)
            await receive(sent, me: me, outgoingOperationID: operationID)
            await saveMemo(memo, for: prepared.photoIdentifier)
            sendCompleted = true
            message = nil
            await sync()
        } catch {
            message = GroupWindowPresentation.message(for: error)
            await sync()
        }
    }

    private func saveMemo(_ memo: String, for identifier: String?) async {
        let text = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let identifier else { return }
        let notes = PhotoMemoryNoteStore.shared
        let existing: PhotoMemoryNote? = (try? await notes.note(for: identifier)) ?? nil
        let combined = existing.map { $0.text + "\n" + text } ?? text
        _ = try? await notes.save(text: combined, for: identifier, expectedRevision: existing?.revision)
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

    init(client: ProductionGroupWindowClient, windowID: String) {
        _model = StateObject(wrappedValue: GroupWindowScreenModel(client: client, windowID: windowID))
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let window = model.window, model.isPaused {
                    pausedCard(window)
                }
                if let message = model.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("group-window-screen-message")
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
                        description: Text("届けた写真と届いた写真が、ここに並びます。参加する前の写真は届きません。")
                    )
                    .frame(minHeight: 240)
                } else {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(model.entries) { entry in
                            Button { openedEntry = entry } label: {
                                GroupPhotoTile(model: model, entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(model.window?.name ?? "まど")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    GroupWindowMembersScreen(client: model.client, windowID: model.windowID)
                } label: {
                    Image(systemName: "person.2")
                }
                .accessibilityLabel("メンバーと招待")
                .accessibilityIdentifier("group-window-open-members")
            }
        }
        .safeAreaInset(edge: .bottom) { sendBar }
        .task {
            await model.showStored()
            await model.sync()
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
            GroupPhotoDetail(model: model, entry: entry)
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
            NavigationLink {
                GroupWindowMembersScreen(client: model.client, windowID: model.windowID)
            } label: {
                Text(GroupWindowPresentation.isMyWindow(window)
                     ? "このまどを続ける"
                     : "作った\(GroupWindowPresentation.pausedOwnerName(window))さんがPlusを続けると再開します")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("group-window-screen-paused")
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
            }
            PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                Label(model.isSending ? "届けています…" : "写真を届ける", systemImage: "paperplane")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSend)
            .accessibilityIdentifier("group-window-send-photo")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct GroupPhotoTile: View {
    @ObservedObject var model: GroupWindowScreenModel
    let entry: GroupWindowLocalPhotoStore.Entry
    @State private var url: URL?

    var body: some View {
        Color(uiColor: .tertiarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if entry.isHidden {
                    Image(systemName: "eye.slash").foregroundStyle(.secondary)
                } else if let url, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if !entry.isOwn {
                    Text(entry.senderDisplayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !(model.hearts[entry.id]?.filter(\.active).isEmpty ?? true) {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(4)
                        .background(.white.opacity(0.85), in: Circle())
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tileLabel)
            .accessibilityHint("押すと大きく見て、ハートを送れます")
            .task { url = await model.imageURL(for: entry) }
    }
}

private extension GroupPhotoTile {
    var tileLabel: String {
        var parts = [entry.isOwn ? "自分が届けた写真" : "\(entry.senderDisplayName)さんから届いた写真"]
        if entry.isHidden { parts.append("表示していない写真") }
        if !(model.hearts[entry.id]?.filter(\.active).isEmpty ?? true) { parts.append("ハートあり") }
        return parts.joined(separator: "、")
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
                } header: { Text("メモ（自分だけ）") }
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
    let entry: GroupWindowLocalPhotoStore.Entry
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?

    private var reactors: [String] {
        (model.hearts[entry.id] ?? []).filter(\.active).map(\.displayName)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Group {
                    if entry.isHidden {
                        ContentUnavailableView("この写真は表示しません", systemImage: "eye.slash",
                            description: Text("iPhoneがセンシティブな内容と判断しました。"))
                    } else if let url, let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 6) {
                    Text(entry.isOwn ? "自分が届けた写真" : "\(entry.senderDisplayName)さんから")
                        .font(.subheadline.weight(.semibold))
                    if entry.isOwn && reactors.isEmpty {
                        Text("ハートはまだ届いていません").font(.footnote).foregroundStyle(.secondary)
                    }
                    if !reactors.isEmpty {
                        Label(reactors.joined(separator: "・"), systemImage: "heart.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("ハートを送った人：\(reactors.joined(separator: "、"))")
                    }
                }
                if !entry.isHidden && !entry.isOwn {
                    Button {
                        Task { await model.toggleHeart(entry.id) }
                    } label: {
                        Label(model.myHeartIsActive(entry.id) ? "ハートを送りました" : "ハートを送る",
                              systemImage: model.myHeartIsActive(entry.id) ? "heart.fill" : "heart")
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("group-photo-heart")
                }
            }
            .padding(.bottom, 12)
            .background(.black)
            .navigationTitle(model.window?.name ?? "まど")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { url = await model.imageURL(for: entry) }
    }
}

// MARK: - Members screen with the production client

struct GroupWindowMembersScreen: View {
    @StateObject private var model: GroupWindowMembersModel

    init(client: any GroupWindowClient, windowID: String) {
        _model = StateObject(wrappedValue: GroupWindowMembersModel(client: client, windowID: windowID))
    }

    var body: some View {
        GroupWindowMembersView(model: model)
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
    let client: ProductionGroupWindowClient

    init(client: ProductionGroupWindowClient) { self.client = client }

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

/// Creating a window for several people. Reached from 「相手とつなぐ」, next to
/// the one-person window, so both start from the same place.
struct GroupWindowCreateScreen: View {
    @StateObject private var model: GroupWindowListModel
    @Environment(\.membershipAccess) private var membershipAccess
    @State private var name = ""
    @State private var createdWindowID: String?

    init(client: ProductionGroupWindowClient) {
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
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        .navigationTitle("家族・友だちとまどを作る")
        .navigationBarTitleDisplayMode(.inline)
        .announcesWhenShown(model.message)
        .safeAreaInset(edge: .bottom) {
            Group {
                if membershipAccess.decision(for: .createOwnWindow) != .allowed {
                    // まどを作るのは Plus（App Store の14日間無料を含む）。押したときだけ開く。
                    PlusOfferPrompt(context: .createWindow,
                                    decision: membershipAccess.decision(for: .createOwnWindow),
                                    presentsImmediately: false)
                } else {
                    Button {
                        Task { createdWindowID = await model.create(name: trimmed)?.id }
                    } label: {
                        Text("作る").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty || model.isWorking)
                    .accessibilityIdentifier("group-window-create-confirm")
                }
            }
            .padding().background(.regularMaterial)
        }
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
    @ObservedObject private var openInbox = GroupWindowOpenInbox.shared

    init(client: ProductionGroupWindowClient) {
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
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
            NavigationLink {
                GroupWindowCreateScreen(client: model.client)
            } label: {
                Label("まどを作る（\(GroupWindowPresentation.memberLimit)人まで）", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking)
            .accessibilityIdentifier("group-window-create")
        }
        .task { await model.load() }
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
        HStack(spacing: 12) {
            HStack(spacing: -8) {
                ForEach(window.activeMembers.prefix(3)) { member in
                    GroupMemberAvatar(name: member.displayName)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(window.name).font(.body.weight(.semibold))
                Text(GroupWindowPresentation.isPaused(window)
                     ? "止まっています"
                     : GroupWindowPresentation.memberCountText(window))
                    .font(.caption)
                    .foregroundStyle(GroupWindowPresentation.isPaused(window) ? Color.orange : Color.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(minHeight: 44)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
