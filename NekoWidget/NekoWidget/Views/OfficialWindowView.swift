import ImageIO
import CryptoKit
import SwiftUI
import UIKit
import WidgetKit

struct OfficialWindowEntryCard: View {
    var state: OfficialWindowState = OfficialWindowStore.shared.snapshot()
    var store: OfficialWindowStore = .shared
    var refreshFeed: () async throws -> Void = {
        try await OfficialWindowClient.shared.refresh(maximumImages: 6)
    }

    private var photoDeadlines: [Date] {
        ([Date.now] + [state.catalog?.validUntil].compactMap { $0 }
         + (state.catalog?.photos.map(\.expiresAt) ?? [])).sorted()
    }

    var body: some View {
        NavigationLink {
            OfficialWindowView(store: store, refreshFeed: refreshFeed)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Color(.tertiarySystemFill)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        TimelineView(.explicit(photoDeadlines)) { _ in
                        if let photo = state.photos.first,
                           let url = store.imageURL(for: photo) {
                            MomentLocalImageView(url: url, hidesImageAccessibility: true,
                                                 maximumPixelSize: 650)
                                .id(state.imageRevision)
                        } else {
                            Image(systemName: "pawprint.fill")
                                .font(.largeTitle).foregroundStyle(.orange)
                                .accessibilityHidden(true)
                        }
                        }
                    }
                    .clipped()
                VStack(alignment: .leading, spacing: 6) {
                    Text(OfficialWindowCatalog.displayName)
                        .font(.headline).foregroundStyle(.primary)
                    Text("公式 · いろいろな猫との出会い")
                        .font(.caption).foregroundStyle(.secondary)
                    if !state.isSubscribed {
                        Text("写真の投稿や友だちの招待は不要")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("official-window-entry")
        .accessibilityLabel("\(OfficialWindowCatalog.displayName)、公式まど")
        .accessibilityHint(state.isSubscribed ? "受け取っている写真を開きます" : "まどの内容を確認します")
    }
}

extension Notification.Name {
    static let officialWindowPresentationDidChange = Notification.Name("officialWindowPresentationDidChange")
}

@MainActor
struct OfficialWindowView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var state: OfficialWindowState
    @State private var isRefreshing = false
    @State private var refreshAgain = false
    @State private var message: String?
    @State private var selectedPhoto: OfficialCatPhoto?
    @State private var showsWidgetGuide = false
    @State private var offersWidgetSetup = false
    @State private var widgetPlacement = WidgetPlacement.first
    @State private var showsOverview = false
    @State private var hasCheckedFeed = false
    let initialPhotoID: String?
    let store: OfficialWindowStore
    let refreshFeed: () async throws -> Void

    private enum WidgetPlacement: String, CaseIterable {
        case first = "初めて置く"
        case existing = "すでに置いている"
    }

    init(initialPhotoID: String? = nil, store: OfficialWindowStore = .shared,
         refreshFeed: @escaping () async throws -> Void = {
             try await OfficialWindowClient.shared.refresh(maximumImages: 6)
         }) {
        self.initialPhotoID = initialPhotoID
        self.store = store
        self.refreshFeed = refreshFeed
        // The Widget already cached this photo. Resolve it before the first
        // frame, rather than opening the overview and then another sheet.
        _state = State(initialValue: store.snapshot())
    }

    private var photos: [OfficialCatPhoto] { state.photos }

    var body: some View {
        Group {
            if let initialPhotoID, !showsOverview {
                if let photo = photos.first(where: { $0.id == initialPhotoID }) {
                    OfficialPhotoDetailView(photo: photo, store: store,
                                            imageRevision: state.imageRevision,
                                            isRefreshing: isRefreshing,
                                            showsCloseButton: false)
                } else {
                    unavailableLinkedPhoto
                }
            } else {
                overview
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refresh()
        }
        .task(id: state.catalog?.validUntil) {
            // Expiry also applies while the detail remains open offline.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                state = store.snapshot()
                dismissUnavailablePhoto()
            }
        }
        .sheet(item: $selectedPhoto) { photo in
            NavigationStack {
                OfficialPhotoDetailView(photo: photo, store: store,
                                        imageRevision: state.imageRevision, isRefreshing: isRefreshing)
            }
        }
        .sheet(isPresented: $showsWidgetGuide) {
            widgetGuide
        }
        .onChange(of: state.subscriptionID) { _, _ in
            NotificationCenter.default.post(name: .officialWindowPresentationDidChange, object: nil)
        }
        .onChange(of: state.imageRevision) { _, _ in
            NotificationCenter.default.post(name: .officialWindowPresentationDidChange, object: nil)
        }
        .onChange(of: state.catalog?.generatedAt) { _, _ in
            NotificationCenter.default.post(name: .officialWindowPresentationDidChange, object: nil)
        }
    }

    private var unavailableLinkedPhoto: some View {
        VStack(spacing: 20) {
            if state.isSubscribed && !hasCheckedFeed {
                ProgressView("写真を確認しています…")
            } else {
                ContentUnavailableView("この写真は表示できません", systemImage: "photo",
                                       description: Text(message ?? "公式まどで、いま届いている写真を確認できます。"))
                Button("公式まどを見る") { showsOverview = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("official-window-show-overview")
            }
        }
        .padding(20)
        .navigationTitle("写真")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let latest = photos.first {
                    photoButton(latest, latest: true)
                } else {
                    introduction
                }

                if let message {
                    Text(message)
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("official-window-feedback")
                }

                if state.isSubscribed {
                    widgetSetupOffer

                    if photos.count > 1 {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("最近届いた猫たち").font(.headline)
                            ForEach(photos.dropFirst().prefix(5)) { photo in
                                photoButton(photo, latest: false)
                            }
                        }
                    }
                    Button("受け取りをやめる", role: .destructive) { changeSubscription(false) }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("official-window-stop")
                } else if store.endpoint != nil {
                    Button {
                        changeSubscription(true)
                    } label: {
                        Text("このまどを受け取る").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("official-window-subscribe")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("ねこのまどが選んで届ける、公式まどです。")
                    Text("写真の提供元や掲載日は、写真を開くと確認できます。AI生成の画像には、その旨を表示します。")
                    if state.isSubscribed {
                        Text("写真が追加されると更新します。ホーム画面への反映には時間がかかることがあります。")
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle(OfficialWindowCatalog.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .refreshable { await refresh() }
        .toolbar {
            if state.isSubscribed {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh() } } label: {
                        if isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("公式まどを更新")
                }
            }
        }
    }

    private var widgetSetupOffer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if offersWidgetSetup {
                Label("受け取りを始めました", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .accessibilityIdentifier("official-window-subscription-confirmation")
                Text("ホーム画面でも、このまどを楽しめます。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    offersWidgetSetup = false
                    showsWidgetGuide = true
                } label: {
                    Label("ホーム画面に置く方法", systemImage: "plus.rectangle.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("official-window-widget-guide")
                Button("あとで") { offersWidgetSetup = false }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("official-window-widget-later")
            } else {
                Button { showsWidgetGuide = true } label: {
                    Label("ホーム画面に置く方法", systemImage: "plus.rectangle.on.rectangle")
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("official-window-widget-guide")
            }
        }
    }

    private var widgetGuide: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("ホーム画面にも、このまどを。", systemImage: "pawprint.fill").font(.title2)
                    Picker("ウィジェットの設置状況", selection: $widgetPlacement) {
                        ForEach(WidgetPlacement.allCases, id: \.self) { placement in
                            Text(placement.rawValue).tag(placement)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("official-window-widget-placement")
                    VStack(alignment: .leading, spacing: 16) {
                        if widgetPlacement == .first {
                            Text("1. ホーム画面の何もないところを長押しします。")
                            Text("2. 「編集」または「＋」からウィジェットを追加し、「ねこのまど」を選びます。")
                            Text("3. 置いたウィジェットを長押しして、「ウィジェットを編集」を開きます。")
                            Text("4. 「表示する写真」で、次の表示元を選びます。")
                        } else {
                            Text("1. ホーム画面にある「ねこのまど」のウィジェットを長押しして、「ウィジェットを編集」を開きます。")
                            Text("2. 「表示する写真」で、次の表示元を選びます。")
                        }
                        Label("どこかの猫 · 公式まど", systemImage: "pawprint.fill")
                            .font(.headline)
                            .accessibilityIdentifier("official-window-widget-source")
                    }
                    Text("写真ライブラリの許可や、猫の登録は必要ありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }
            .navigationTitle("ホーム画面に置く")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showsWidgetGuide = false } } }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "pawprint.fill").font(.system(size: 42)).foregroundStyle(.orange)
            Text(emptyTitle).font(.title2.weight(.semibold))
            Text(emptyDescription).foregroundStyle(.secondary)
            if isRefreshing { ProgressView("写真を確認しています…") }
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
        .padding(24)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .accessibilityIdentifier("official-window-introduction")
    }

    private var emptyTitle: String {
        if store.endpoint == nil { return "公式まどを準備しています" }
        if !state.isSubscribed { return "どこかの猫と、暮らしの中で会える。" }
        if state.catalog?.enabled == false { return "いまは配信をお休みしています" }
        return "いま届いている写真はありません"
    }

    private var emptyDescription: String {
        if store.endpoint == nil { return "公開する写真の準備ができたら、このまどからお届けします。" }
        if !state.isSubscribed { return "ふと見たホーム画面に、猫の一枚。自分の写真や、送る相手がいなくても楽しめます。" }
        return "新しい写真は、このまどで受け取れます。写真の投稿は必要ありません。"
    }

    private func photoButton(_ photo: OfficialCatPhoto, latest: Bool) -> some View {
        Button { selectedPhoto = photo } label: {
            VStack(alignment: .leading, spacing: 10) {
                OfficialPhotoImage(photo: photo, maximumPixelSize: latest ? 1100 : 650,
                                   store: store, isRefreshing: isRefreshing)
                    .id("\(photo.imageFilename)-\(state.imageRevision?.uuidString ?? "")")
                    .aspectRatio(CGFloat(photo.width) / CGFloat(photo.height), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                HStack {
                    Text(photo.catName).font(.headline)
                    Spacer()
                    Text(photo.publishedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                }
                if let caption = photo.caption {
                    Text(caption).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(photo.catName)の写真を開く")
    }

    private func changeSubscription(_ subscribed: Bool) {
        do {
            try store.setSubscribed(subscribed)
            state = store.snapshot()
            message = nil
            selectedPhoto = nil
            // This acknowledges the saved setting, not a successful image fetch.
            offersWidgetSetup = subscribed && state.isSubscribed
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
            if subscribed {
                if isRefreshing { refreshAgain = true }
                else { Task { await refresh() } }
            }
        } catch {
            state = store.snapshot()
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
            if !subscribed, !state.isSubscribed {
                selectedPhoto = nil
                offersWidgetSetup = false
                message = "受け取りをやめました。一部の写真データは削除できませんでした。"
            } else {
                message = "受け取りの設定を保存できませんでした。もう一度お試しください。"
            }
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        state = store.snapshot()
        guard state.isSubscribed else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            hasCheckedFeed = true
            if refreshAgain {
                refreshAgain = false
                Task { await refresh() }
            }
        }
        let requestedSubscription = state.subscriptionID
        do {
            try await refreshFeed()
            message = nil
        } catch is CancellationError {
            return
        } catch {
            if store.snapshot().subscriptionID == requestedSubscription {
                message = "新しい写真を確認できませんでした。少し時間をおいて、もう一度更新できます。"
            }
        }
        state = store.snapshot()
        dismissUnavailablePhoto()
        WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
    }

    private func dismissUnavailablePhoto() {
        if let selectedPhoto, !photos.contains(selectedPhoto) {
            self.selectedPhoto = nil
        }
    }
}

private struct OfficialPhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let photo: OfficialCatPhoto
    let store: OfficialWindowStore
    let imageRevision: UUID?
    var isRefreshing = false
    var showsCloseButton = true

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    OfficialPhotoImage(photo: photo, maximumPixelSize: 2048, store: store,
                                       isRefreshing: isRefreshing, allowsZoom: true)
                        .id("\(photo.imageFilename)-\(imageRevision?.uuidString ?? "")")
                        .frame(width: geometry.size.width, height: max(280, geometry.size.height * 0.72))
                        .clipped()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("指で広げるか、ダブルタップすると拡大できます。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let caption = photo.caption { Text(caption).font(.body) }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("提供元：\(photo.credit)")
                            if let date = photo.photographedOn { Text("撮影日：\(date)") }
                            Text("掲載日：\(photo.publishedAt.formatted(date: .abbreviated, time: .omitted))")
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 24)
            }
        }
        .navigationTitle(photo.catName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}

private struct OfficialPhotoImage: View {
    let photo: OfficialCatPhoto
    let maximumPixelSize: Int
    let store: OfficialWindowStore
    var isRefreshing = false
    var allowsZoom = false
    @State private var image: UIImage?
    @State private var loadedImageFilename: String?
    @State private var loadFailed = false

    private var isLoading: Bool { image == nil && (!loadFailed || isRefreshing) }

    var body: some View {
        ZStack {
            Color(.secondarySystemGroupedBackground)
            if let image {
                if allowsZoom {
                    MomentZoomablePhoto(image: image)
                } else {
                    Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                }
            } else if isLoading {
                ProgressView("写真を読み込んでいます…").padding()
            } else {
                Label("写真を読み込めませんでした", systemImage: "photo")
                    .font(.footnote).foregroundStyle(.secondary).padding()
            }
        }
        .accessibilityLabel("\(photo.catName)の写真")
        .accessibilityIdentifier(image != nil ? "official-window-image-loaded"
                                 : isLoading ? "official-window-image-loading" : "official-window-image-unavailable")
        .task(id: "\(photo.imageFilename)-\(isRefreshing)") {
            // A feed check must not replace an already displayed UIImage and
            // reset its zoom. A new cache revision recreates this view instead.
            guard image == nil || loadedImageFilename != photo.imageFilename else { return }
            image = nil
            loadFailed = false
            guard let url = store.imageURL(for: photo),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else {
                image = nil
                loadFailed = true
                return
            }
            image = UIImage(cgImage: cgImage)
            loadedImageFilename = photo.imageFilename
        }
    }
}

#if DEBUG
/// Offline fixture uses the shipping store and screens, with only the public
/// network boundary replaced. No Photos permission, real account or feed.
@MainActor
final class OfficialWindowFixtureModel: ObservableObject {
    let store: OfficialWindowStore
    private var attempts = 0
    let linkedPhotoID: String?
    @Published var linkedRefreshStarted = false
    @Published var finishLinkedRefresh = false
    @Published var linkedRefreshFailed = false

    init() {
        let unavailable = CommandLine.arguments.contains("--official-window-unconfigured")
        store = OfficialWindowStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("official-fixture-" + UUID().uuidString),
            endpoint: unavailable ? nil : URL(string: "https://official.invalid/catalog.json")
        )
        if CommandLine.arguments.contains("--official-window-linked-photo") {
            linkedPhotoID = CommandLine.arguments.contains("--official-window-missing-photo") ? "removed-photo" : "fixture-photo"
            do {
                try store.setSubscribed(true)
                try seedPhoto(failImage: false)
            } catch {
                assertionFailure("Could not seed the official route fixture")
            }
        } else {
            linkedPhotoID = nil
            if CommandLine.arguments.contains("--window-list-subscribed") {
                do {
                    try store.setSubscribed(true)
                    try seedPhoto(failImage: false)
                } catch {
                    assertionFailure("Could not seed the window list fixture")
                }
            }
        }
    }

    func refresh() async throws {
        if linkedPhotoID != nil {
            linkedRefreshStarted = true
            // Hold only the network boundary; the test releases it after
            // asserting that the shipping screen has already opened the photo.
            while !finishLinkedRefresh {
                try await Task.sleep(for: .milliseconds(100))
            }
            linkedRefreshFailed = true
            throw URLError(.notConnectedToInternet)
        }
        attempts += 1
        try seedPhoto(failImage: attempts == 1)
    }

    private func seedPhoto(failImage: Bool) throws {
        let request = store.snapshot()
        guard request.isSubscribed else { return }
        let image = MomentExperiencePhotoFixture.image(index: 0)
        guard let data = image.jpegData(compressionQuality: 0.88), let cgImage = image.cgImage else { return }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 2)
        let photo = OfficialCatPhoto(
            id: "fixture-photo", catID: "fixture-cat", catName: "確認用の猫", credit: "画面確認用の合成画像",
            caption: "窓辺でひと休み。", photographedOn: "2026-09-01", publishedAt: now,
            expiresAt: now.addingTimeInterval(86400), imageFilename: hash + ".jpg", sha256: hash,
            width: cgImage.width, height: cgImage.height
        )
        let catalog = OfficialWindowCatalog(schemaVersion: 1, channelID: "official-cats", enabled: true,
                                           generatedAt: now, validUntil: now.addingTimeInterval(86400), photos: [photo])
        try store.accept(catalog, for: request)
        if failImage { throw URLError(.networkConnectionLost) }
        try store.saveImage(data, photo: photo, for: request)
    }
}

struct OfficialWindowUIFixture: View {
    @StateObject private var model = OfficialWindowFixtureModel()
    @State private var presentsLinkedPhoto = false
    var body: some View {
        if let photoID = model.linkedPhotoID {
            Button("Widgetの写真を開く") { presentsLinkedPhoto = true }
                .accessibilityIdentifier("official-window-fixture-launch")
                .sheet(isPresented: $presentsLinkedPhoto) {
                    NavigationStack {
                        OfficialWindowView(initialPhotoID: photoID, store: model.store,
                                           refreshFeed: { try await model.refresh() })
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("閉じる") { presentsLinkedPhoto = false }
                                }
                                ToolbarItem(placement: .bottomBar) {
                                    if model.linkedRefreshStarted {
                                        Button(model.linkedRefreshFailed ? "確認用：通信失敗済み" : "確認用：通信を失敗させる") {
                                            model.finishLinkedRefresh = true
                                        }
                                    }
                                }
                            }
                    }
                }
        } else {
            NavigationStack {
                OfficialWindowView(store: model.store, refreshFeed: { try await model.refresh() })
            }
        }
    }
}
#endif
