import ImageIO
import CryptoKit
import SwiftUI
import UIKit
import WidgetKit

/// The window shelf uses one photo crop and one title row for every window.
@MainActor
struct WindowPhotoCard<Photo: View>: View {
    enum Kind: Equatable { case shared, official }
    let title: String
    let kind: Kind
    let photo: Photo

    init(title: String, kind: Kind, @ViewBuilder photo: () -> Photo) {
        self.title = title
        self.kind = kind
        self.photo = photo()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color(.tertiarySystemFill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        photo.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                }
            HStack(spacing: 8) {
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if kind == .shared {
                    Image(systemName: "lock").font(.caption).accessibilityHidden(true)
                } else {
                    Text("公式").font(.caption2).fixedSize()
                }
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 24)
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}

@MainActor
struct OfficialWindowEntryCard: View {
    enum Presentation: Equatable { case list, discovery }
    let state: OfficialWindowState
    let store: OfficialWindowStore
    let refreshFeed: () async throws -> Void
    let presentation: Presentation
    let previewFeed: () async throws -> OfficialWindowPreview
    @StateObject private var preview = OfficialWindowPreviewModel()

    init(state: OfficialWindowState = OfficialWindowStore.shared.snapshot(),
         store: OfficialWindowStore = .shared,
         refreshFeed: @escaping () async throws -> Void = {
             try await OfficialWindowClient.shared.refresh(maximumImages: 6)
         }, presentation: Presentation = .list,
         previewFeed: @escaping () async throws -> OfficialWindowPreview = {
             try await OfficialWindowClient.shared.preview()
         }) {
        self.state = state
        self.store = store
        self.refreshFeed = refreshFeed
        self.presentation = presentation
        self.previewFeed = previewFeed
    }

    private var photoDeadlines: [Date] {
        let catalog = state.isSubscribed ? state.catalog : preview.content?.catalog
        return ([Date.now] + [catalog?.validUntil].compactMap { $0 }
                + (catalog?.photos.map(\.expiresAt) ?? [])).sorted()
    }

    var body: some View {
        NavigationLink {
            OfficialWindowView(store: store, refreshFeed: refreshFeed,
                               previewFeed: previewFeed, preview: preview)
        } label: {
            if presentation == .list {
                WindowPhotoCard(title: OfficialWindowCatalog.displayName, kind: .official) { cover }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Color(.tertiarySystemFill).aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay { GeometryReader { geometry in
                            cover.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        } }
                    HStack {
                        Text(OfficialWindowCatalog.displayName).font(.headline)
                        Spacer()
                        if state.isSubscribed {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                                .accessibilityLabel("受け取り中")
                        }
                    }.padding(12)
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("official-window-entry")
        .accessibilityLabel("\(OfficialWindowCatalog.displayName)、写真を受け取るまど、公式")
        .accessibilityValue([state.isSubscribed ? "受け取り中" : "まだ受け取っていません",
                             (state.isSubscribed ? state.photos.first : preview.content?.availablePhoto())?.credit]
            .compactMap { $0 }.joined(separator: "。"))
        .accessibilityHint(state.isSubscribed ? "受け取っている写真を開きます" : "まどの内容を確認します")
        .task {
            guard presentation == .discovery, !state.isSubscribed, store.endpoint != nil else { return }
            await preview.load(using: previewFeed)
        }
    }

    private var cover: some View {
        TimelineView(.explicit(photoDeadlines)) { _ in
            if let photo = state.isSubscribed ? state.photos.first : preview.content?.availablePhoto() {
                OfficialPhotoImage(photo: photo, maximumPixelSize: 650, store: store,
                                   previewImageData: state.isSubscribed ? nil : preview.content?.imageData,
                                   fillsFrame: true)
                    .id("\(photo.imageFilename)-\(state.imageRevision?.uuidString ?? "preview")")
                    .overlay(alignment: .bottomTrailing) {
                        if photo.credit.contains("AI生成") {
                            Text("AI").font(.caption2.weight(.medium))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(.thinMaterial, in: Capsule()).padding(8)
                                .accessibilityLabel("AI生成画像")
                        }
                    }
                    .accessibilityHidden(true)
            } else if preview.isLoading {
                ProgressView().accessibilityLabel("写真を確認しています")
            } else {
                Image(systemName: preview.failed ? "photo.badge.exclamationmark" : "pawprint")
                    .font(.largeTitle).foregroundStyle(.secondary)
            }
        }
    }
}

extension Notification.Name {
    static let officialWindowPresentationDidChange = Notification.Name("officialWindowPresentationDidChange")
}

@MainActor
struct OfficialWindowView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var state: OfficialWindowState
    @State private var isRefreshing = false
    @State private var refreshAgain = false
    @State private var message: String?
    @State private var refreshFailed = false
    @State private var feedbackIsTransient = false
    @State private var feedbackRevision = UUID()
    @State private var selectedPhoto: OfficialCatPhoto?
    @State private var showsWidgetGuide = false
    @State private var showsAbout = false
    @State private var confirmsStop = false
    @State private var stoppedHere = false
    @State private var offersWidgetSetup = false
    @State private var widgetPlacement = WidgetPlacement.first
    @State private var showsOverview = false
    @State private var hasCheckedFeed = false
    @State private var displayDate = Date()
    @StateObject private var preview: OfficialWindowPreviewModel
    let initialPhotoID: String?
    let store: OfficialWindowStore
    let refreshFeed: () async throws -> Void
    let previewFeed: () async throws -> OfficialWindowPreview

    private enum WidgetPlacement: String, CaseIterable {
        case first = "初めて置く"
        case existing = "すでに置いている"
    }

    init(initialPhotoID: String? = nil, store: OfficialWindowStore = .shared,
          refreshFeed: @escaping () async throws -> Void = {
              try await OfficialWindowClient.shared.refresh(maximumImages: 6)
          },
          previewFeed: @escaping () async throws -> OfficialWindowPreview = {
              try await OfficialWindowClient.shared.preview()
          }, preview: OfficialWindowPreviewModel? = nil) {
        self.initialPhotoID = initialPhotoID
        self.store = store
        self.refreshFeed = refreshFeed
        self.previewFeed = previewFeed
        _preview = StateObject(wrappedValue: preview ?? OfficialWindowPreviewModel())
        // The Widget already cached this photo. Resolve it before the first
        // frame, rather than opening the overview and then another sheet.
        _state = State(initialValue: store.snapshot())
    }

    private var isPreviewing: Bool { !state.isSubscribed && !stoppedHere && (initialPhotoID == nil || showsOverview) }
    private var isChecking: Bool { isRefreshing || (isPreviewing && preview.isLoading) }
    private var hasRefreshFailure: Bool { refreshFailed || (isPreviewing && preview.failed) }
    private var feedbackText: String? {
        message ?? (isPreviewing && preview.failed ? "公開中の写真を確認できませんでした。もう一度試せます。" : nil)
    }
    private var currentCatalog: OfficialWindowCatalog? { state.isSubscribed ? state.catalog : preview.content?.catalog }
    private var nextPhotoDeadline: Date? {
        guard let catalog = currentCatalog, catalog.enabled, catalog.validUntil > displayDate else { return nil }
        return ([catalog.validUntil] + catalog.photos.map(\.expiresAt)).filter { $0 > displayDate }.min()
    }
    private var photos: [OfficialCatPhoto] {
        if state.isSubscribed { return state.catalog?.availablePhotos(at: displayDate) ?? [] }
        if isPreviewing, let photo = preview.content?.availablePhoto(at: displayDate) { return [photo] }
        return []
    }
    private func previewData(for photo: OfficialCatPhoto) -> Data? {
        guard isPreviewing, preview.content?.availablePhoto() == photo else { return nil }
        return preview.content?.imageData
    }

    var body: some View {
        Group {
            if let initialPhotoID, !showsOverview {
                if let photo = photos.first(where: { $0.id == initialPhotoID }) {
                    OfficialPhotoDetailView(photo: photo, store: store,
                                            imageRevision: state.imageRevision,
                                            isRefreshing: isChecking,
                                            previewImageData: previewData(for: photo),
                                            showsCloseButton: false,
                                            onRetry: { Task { await refresh(interactive: true) } })
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
        .task(id: nextPhotoDeadline) {
            await observePhotoAvailability()
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            NavigationStack {
                OfficialPhotoDetailView(photo: photo, store: store,
                                        imageRevision: state.imageRevision, isRefreshing: isChecking,
                                        previewImageData: previewData(for: photo),
                                        onRetry: { Task { await refresh(interactive: true) } })
            }
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .task(id: nextPhotoDeadline) {
                // A full-screen viewer owns its own display lease: its
                // presenting overview may disappear and cancel its task.
                await observePhotoAvailability()
            }
        }
        .sheet(isPresented: $showsWidgetGuide) {
            widgetGuide
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
        .sheet(isPresented: $showsAbout) { about.environment(\.dynamicTypeSize, dynamicTypeSize) }
        .alert("「\(OfficialWindowCatalog.displayName)」の受け取りをやめますか？",
               isPresented: $confirmsStop) {
            Button("受け取りをやめる", role: .destructive) { changeSubscription(false) }
                .accessibilityIdentifier("official-window-stop-confirm")
            Button("受け取りを続ける", role: .cancel) {}
                .accessibilityIdentifier("official-window-stop-cancel")
        } message: {
            Text("このまどからの受け取りと、Widgetへの表示を止めます。あとで受け取りを再開できます。")
        }
        .task(id: feedbackRevision) {
            guard feedbackIsTransient else { return }
            let revision = feedbackRevision
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard revision == feedbackRevision else { return }
            message = nil
            feedbackIsTransient = false
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
                Button("公式まどを見る") {
                    showsOverview = true
                    Task { await refresh() }
                }
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

                if let message = feedbackText {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message)
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("official-window-feedback")
                        if hasRefreshFailure {
                            Button("もう一度確認") { Task { await refresh(interactive: true) } }
                                .frame(minHeight: 44)
                                .disabled(isChecking)
                                .accessibilityIdentifier("official-window-refresh-retry")
                        }
                    }
                }

                if state.isSubscribed {
                    widgetSetupOffer

                    if photos.count > 1 {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("最近の写真").font(.headline)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top),
                                                     count: dynamicTypeSize >= .xxxLarge ? 1 : 2),
                                      alignment: .leading, spacing: 18) {
                                ForEach(photos.dropFirst().prefix(5)) { photo in
                                    photoButton(photo, latest: false)
                                }
                            }
                            .accessibilityIdentifier("official-window-recent-photos")
                        }
                    }
                } else if store.endpoint != nil {
                    Button {
                        changeSubscription(true)
                    } label: {
                        Text("このまどを受け取る").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("official-window-subscribe")
                }

            }
            .padding(20)
        }
        .navigationTitle(OfficialWindowCatalog.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .toolbarBackground(Color(.systemGroupedBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .refreshable { await refresh(interactive: true) }
        .toolbar {
            if store.endpoint != nil, !stoppedHere {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh(interactive: true) } } label: {
                        if isChecking { ProgressView() }
                        else { Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44) }
                    }
                    .disabled(isChecking)
                    .accessibilityLabel(state.isSubscribed ? "新着を確認" : "写真を確認")
                    .accessibilityValue(isChecking ? "確認中" : "")
                    .accessibilityIdentifier("official-window-refresh")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("このまどについて") { showsAbout = true }
                        .accessibilityIdentifier("official-window-about")
                    if state.isSubscribed {
                        Button("受け取りをやめる", role: .destructive) { confirmsStop = true }
                            .accessibilityIdentifier("official-window-stop")
                    }
                } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("管理")
                .accessibilityIdentifier("official-window-manage")
            }
        }
    }

    private var about: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("写真を受け取るまど").font(.title2.weight(.semibold))
                    Text("運営が選んだ猫の写真が届きます。投稿や友だちの招待は不要です。")
                    Text("提供元・掲載日は写真で確認できます。AI生成画像はその旨を表示します。")
                    Text("新しい写真が届くと更新します。Widgetへの反映には時間がかかる場合があります。")
                }
                .padding(24)
            }
            .navigationTitle("このまどについて")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button { showsAbout = false } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("閉じる")
            } }
        }
    }

    private var widgetSetupOffer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if offersWidgetSetup {
                Label("受け取りを始めました", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .accessibilityIdentifier("official-window-subscription-confirmation")
                Button {
                    offersWidgetSetup = false
                    showsWidgetGuide = true
                } label: {
                    Label("Widgetの置き方", systemImage: "plus.rectangle.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("official-window-widget-guide")
                Button("あとで") { offersWidgetSetup = false }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("official-window-widget-later")
            } else {
                Button { showsWidgetGuide = true } label: {
                    Label("Widgetの置き方", systemImage: "plus.rectangle.on.rectangle")
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
                    widgetPlacementPicker
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

    @ViewBuilder
    private var widgetPlacementPicker: some View {
        if dynamicTypeSize >= .xxxLarge {
            VStack(spacing: 8) {
                ForEach(WidgetPlacement.allCases, id: \.self) { placement in
                    Button { widgetPlacement = placement } label: {
                        HStack {
                            Text(placement.rawValue)
                            Spacer(minLength: 8)
                            if widgetPlacement == placement { Image(systemName: "checkmark") }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityAddTraits(widgetPlacement == placement ? .isSelected : [])
                }
            }
            .accessibilityIdentifier("official-window-widget-placement")
        } else {
            Picker("ウィジェットの設置状況", selection: $widgetPlacement) {
                ForEach(WidgetPlacement.allCases, id: \.self) { placement in
                    Text(placement.rawValue).tag(placement)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("official-window-widget-placement")
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "pawprint.fill").font(.system(size: 42)).foregroundStyle(.orange)
            Text(emptyTitle).font(.title2.weight(.semibold))
            Text(emptyDescription).foregroundStyle(.secondary)
            if isChecking { ProgressView() }
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
        .padding(24)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .accessibilityIdentifier("official-window-introduction")
    }

    private var emptyTitle: String {
        if store.endpoint == nil { return "公式まどを準備しています" }
        if stoppedHere { return "受け取りをやめました" }
        if isChecking, currentCatalog == nil { return "写真を確認しています…" }
        if currentCatalog?.enabled == false { return "いまは配信をお休みしています" }
        if let catalog = currentCatalog {
            if catalog.validUntil <= displayDate { return "新しい配信の確認が必要です" }
            if !catalog.photos.isEmpty, catalog.photos.allSatisfy({ $0.expiresAt <= displayDate }) {
                return "写真の掲載期間が終わりました"
            }
            if hasRefreshFailure { return "写真を読み込めませんでした" }
            return "まだ掲載されている写真はありません"
        }
        if hasRefreshFailure { return "写真を確認できませんでした" }
        return "どんな写真が届くか、見てみましょう"
    }

    private var emptyDescription: String {
        if store.endpoint == nil { return "公開する写真の準備ができたら、このまどからお届けします。" }
        if stoppedHere { return "また楽しみたくなったら、このまどの受け取りを再開できます。" }
        if let catalog = currentCatalog, catalog.enabled, catalog.validUntil <= displayDate {
            return "写真を表示するには、新しい配信の確認が必要です。画面右上から、もう一度確認できます。"
        }
        if currentCatalog?.enabled == false { return "配信が再開されると、このまどで写真を楽しめます。" }
        if !state.isSubscribed { return "受け取りを始める前に、公開中の写真を確認できます。写真の投稿は必要ありません。" }
        return "新しい写真が掲載されると、このまどで受け取れます。"
    }

    private func photoButton(_ photo: OfficialCatPhoto, latest: Bool) -> some View {
        Button { selectedPhoto = photo } label: {
            VStack(alignment: .leading, spacing: 10) {
                OfficialPhotoImage(photo: photo, maximumPixelSize: latest ? 1100 : 650,
                                   store: store, isRefreshing: isChecking,
                                   previewImageData: previewData(for: photo), fillsFrame: !latest)
                    .id("\(photo.imageFilename)-\(state.imageRevision?.uuidString ?? "")")
                    .aspectRatio(latest ? CGFloat(photo.width) / CGFloat(photo.height) : 1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(alignment: .bottomTrailing) {
                        if photo.credit.contains("AI生成") {
                            Text("AI").font(.caption2.weight(.medium))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(.thinMaterial, in: Capsule()).padding(8)
                                .accessibilityLabel("AI生成画像")
                        }
                    }
                Text(photo.catName).font(.headline)
                if latest, let caption = photo.caption {
                    Text(caption).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("official-window-photo-\(photo.id)")
        .accessibilityLabel("\(photo.catName)の写真。掲載日、\(photo.publishedAt.formatted(date: .abbreviated, time: .omitted))")
        .accessibilityValue("提供元、\(photo.credit)。\(photo.caption ?? "")")
        .accessibilityHint("写真を拡大します")
    }

    private func changeSubscription(_ subscribed: Bool) {
        do {
            try store.setSubscribed(subscribed)
            state = store.snapshot()
            displayDate = Date()
            setFeedback(nil)
            selectedPhoto = nil
            stoppedHere = !subscribed
            preview.clear()
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
                stoppedHere = true
                preview.clear()
                setFeedback("受け取りをやめました。一部の写真データは削除できませんでした。")
            } else {
                setFeedback("受け取りの設定を保存できませんでした。もう一度お試しください。")
            }
        }
    }

    private func setFeedback(_ text: String?, failed: Bool = false, transient: Bool = false) {
        message = text
        refreshFailed = failed
        feedbackIsTransient = transient
        feedbackRevision = UUID()
    }

    private func refresh(interactive: Bool = false) async {
        guard !isRefreshing else { return }
        state = store.snapshot()
        displayDate = Date()
        guard store.endpoint != nil, state.isSubscribed || isPreviewing else { return }
        let previousPhotos = photos
        isRefreshing = true
        defer {
            isRefreshing = false
            hasCheckedFeed = true
            if refreshAgain {
                refreshAgain = false
                Task { await refresh() }
            }
        }
        if isPreviewing {
            let expired = preview.content.map {
                $0.catalog.validUntil <= Date() || ($0.photo != nil && $0.availablePhoto() == nil)
            } ?? false
            await preview.load(force: interactive || expired, using: previewFeed)
            displayDate = Date()
            guard isPreviewing else { return }
            dismissUnavailablePhoto()
            if preview.failed {
                setFeedback("公開中の写真を確認できませんでした。もう一度試せます。", failed: true)
            } else if interactive {
                setFeedback(photos == previousPhotos ? "新しい写真はありませんでした" : "写真を確認しました", transient: true)
            }
            return
        }
        let requestedSubscription = state.subscriptionID
        do {
            try await refreshFeed()
            guard store.snapshot().subscriptionID == requestedSubscription else { return }
            state = store.snapshot()
            displayDate = Date()
            setFeedback(interactive ? (photos == previousPhotos ? "新しい写真はありませんでした" : "写真を更新しました") : nil,
                        transient: interactive)
        } catch is CancellationError {
            return
        } catch {
            if store.snapshot().subscriptionID == requestedSubscription {
                setFeedback("新しい写真を確認できませんでした。少し時間をおいて、もう一度確認できます。", failed: true)
            }
        }
        state = store.snapshot()
        displayDate = Date()
        dismissUnavailablePhoto()
        WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
    }

    private func observePhotoAvailability() async {
        // Wake at the exact display deadline even offline, and also observe
        // subscription/catalog changes made by another app surface.
        while !Task.isCancelled {
            let delay = min(30, max(0, nextPhotoDeadline?.timeIntervalSinceNow ?? 30))
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            state = store.snapshot()
            displayDate = Date()
            dismissUnavailablePhoto()
        }
    }

    private func dismissUnavailablePhoto() {
        if let selectedPhoto, !photos.contains(selectedPhoto) {
            self.selectedPhoto = nil
        }
    }
}

private struct OfficialPhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showsInformation = false
    let photo: OfficialCatPhoto
    let store: OfficialWindowStore
    let imageRevision: UUID?
    var isRefreshing = false
    var previewImageData: Data? = nil
    var showsCloseButton = true
    var onRetry: (() -> Void)? = nil

    var body: some View {
        PhotoDetailLayout {
            OfficialPhotoImage(photo: photo, maximumPixelSize: 2048, store: store,
                               isRefreshing: isRefreshing, previewImageData: previewImageData,
                               allowsZoom: true, onRetry: onRetry)
                .id("\(photo.imageFilename)-\(imageRevision?.uuidString ?? "")")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            ViewThatFits(in: .vertical) {
                photoSummary.fixedSize(horizontal: false, vertical: true)
                ScrollView { photoSummary }
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .navigationTitle(photo.catName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsInformation = true } label: {
                    Image(systemName: "info.circle").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("写真の情報")
                .accessibilityIdentifier("official-photo-information")
            }
            if showsCloseButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("閉じる")
                }
            }
        }
        .sheet(isPresented: $showsInformation) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let caption = photo.caption { Text(verbatim: caption).font(.body) }
                        Text("提供元：\(photo.credit)")
                        if let date = photo.photographedOn { Text("撮影日：\(date)") }
                        Text("掲載日：\(photo.publishedAt.formatted(date: .abbreviated, time: .omitted))")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    .textSelection(.enabled)
                }
                .navigationTitle("写真の情報").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button { showsInformation = false } label: {
                        Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("閉じる")
                    .accessibilityIdentifier("official-photo-information-close")
                } }
            }
        }
    }

    private var photoSummary: some View {
        Button { showsInformation = true } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    if let caption = photo.caption {
                        Text(verbatim: caption).font(.subheadline).lineLimit(2)
                    }
                    // Keep provenance, including AI disclosure, next to the
                    // photo. Full caption and dates remain in its information.
                    Text(verbatim: photo.credit).font(.caption).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption2).accessibilityHidden(true)
            }
            .foregroundStyle(.secondary).multilineTextAlignment(.leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityHint("ひとことの全文と写真の情報を開きます")
        .accessibilityIdentifier("official-photo-summary")
    }
}

private struct OfficialPhotoImage: View {
    let photo: OfficialCatPhoto
    let maximumPixelSize: Int
    let store: OfficialWindowStore
    var isRefreshing = false
    var previewImageData: Data? = nil
    var allowsZoom = false
    var fillsFrame = false
    var onRetry: (() -> Void)? = nil
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
                } else if fillsFrame {
                    GeometryReader { geometry in
                        Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                } else {
                    Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                }
            } else if isLoading {
                ProgressView().padding().accessibilityLabel("写真を読み込んでいます")
            } else {
                VStack(spacing: 12) {
                    Label("写真を読み込めませんでした", systemImage: "photo")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let onRetry {
                        Button("もう一度読み込む", action: onRetry)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("official-photo-retry")
                    }
                }.padding()
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
            let source: CGImageSource?
            if let previewImageData {
                source = CGImageSourceCreateWithData(previewImageData as CFData, nil)
            } else if let url = store.imageURL(for: photo) {
                source = CGImageSourceCreateWithURL(url as CFURL, nil)
            } else {
                source = nil
            }
            guard let source,
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
    private let fixtureDate = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 2)
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
        let count = CommandLine.arguments.contains("--official-window-recent-photos") ? 3 : 1
        let items = try (0..<count).map { try fixturePhoto(index: $0) }
        let catalog = OfficialWindowCatalog(schemaVersion: 1, channelID: "official-cats", enabled: true,
                                           generatedAt: fixtureDate, validUntil: fixtureDate.addingTimeInterval(86400),
                                           photos: items.map(\.photo))
        try store.accept(catalog, for: request)
        if failImage { throw URLError(.networkConnectionLost) }
        for item in items { try store.saveImage(item.data, photo: item.photo, for: request) }
    }

    func preview() async throws -> OfficialWindowPreview {
        let item = try fixturePhoto(index: 0)
        let catalog = OfficialWindowCatalog(schemaVersion: 1, channelID: "official-cats", enabled: true,
                                           generatedAt: fixtureDate, validUntil: fixtureDate.addingTimeInterval(86400), photos: [item.photo])
        return OfficialWindowPreview(catalog: catalog, photo: item.photo, imageData: item.data)
    }

    private func fixturePhoto(index: Int) throws -> (photo: OfficialCatPhoto, data: Data) {
        let original = MomentExperiencePhotoFixture.image(index: index)
        // Match the reported shelf: a portrait official photo beside a private
        // photo, with an AI credit that must not change the card's height.
        let isMixedShelf = CommandLine.arguments.contains("--window-list-mixed")
        let image: UIImage
        if isMixedShelf {
            let size = CGSize(width: 900, height: 1200)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                let scale = max(size.width / original.size.width, size.height / original.size.height)
                let drawnSize = CGSize(width: original.size.width * scale, height: original.size.height * scale)
                original.draw(in: CGRect(x: (size.width - drawnSize.width) / 2, y: (size.height - drawnSize.height) / 2,
                                         width: drawnSize.width, height: drawnSize.height))
            }
        } else {
            image = original
        }
        guard let data = image.jpegData(compressionQuality: 0.88), let cgImage = image.cgImage else {
            throw OfficialWindowError.invalidImage
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let photo = OfficialCatPhoto(
            id: index == 0 ? "fixture-photo" : "fixture-photo-\(index)",
            catID: "fixture-cat", catName: "確認用の猫", credit: isMixedShelf ? "ねこのまど（AI生成）" : "画面確認用の合成画像",
            caption: "窓辺でひと休み。", photographedOn: "2026-09-01",
            publishedAt: fixtureDate.addingTimeInterval(-86400 * Double(index)),
            expiresAt: fixtureDate.addingTimeInterval(CommandLine.arguments.contains("--official-window-expiring-photo") ? 30 : 86400),
            imageFilename: hash + ".jpg", sha256: hash,
            width: cgImage.width, height: cgImage.height
        )
        return (photo, data)
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
                                           refreshFeed: { try await model.refresh() },
                                           previewFeed: { try await model.preview() })
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
                OfficialWindowView(store: model.store, refreshFeed: { try await model.refresh() },
                                   previewFeed: { try await model.preview() })
            }
        }
    }
}
#endif
