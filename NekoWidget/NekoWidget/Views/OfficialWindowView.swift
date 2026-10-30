import ImageIO
import CryptoKit
import SwiftUI
import UIKit
import WidgetKit

private extension OfficialCatPhoto {
    func displayCredit(in windowID: String) -> String {
        windowID == "black-cats" ? "ねこのまど" : credit
    }
}

/// Keep identity above the changing photo. Setup uses the same shelf footprint
/// without pretending that an unfinished connection already contains photos.
@MainActor
struct WindowPhotoCard<Photo: View>: View {
    enum Kind: Equatable { case shared, official, setup }
    @ScaledMetric(relativeTo: .subheadline) private var identityHeight = 38
    let title: String
    let kind: Kind
    let photo: Photo

    init(title: String, kind: Kind, @ViewBuilder photo: () -> Photo) {
        self.title = title
        self.kind = kind
        self.photo = photo()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(kind == .shared ? "ToolCat-snug" : "ToolCat-peek")
                    .resizable().scaledToFit()
                    .frame(width: 23, height: 23)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: identityHeight, alignment: .leading)
            Color(.secondarySystemGroupedBackground)
                .aspectRatio(4.0 / 4.65, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        photo.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if kind != .setup {
                        Group {
                            if kind == .shared {
                                Image(systemName: "lock").font(.caption)
                            } else {
                                Text("公式").font(.caption2)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                        .accessibilityHidden(true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}

@MainActor
struct PublicWindowPresentationSource: Identifiable {
    let store: OfficialWindowStore
    let refresh: () async throws -> Void
    let preview: () async throws -> OfficialWindowPreview
    var id: String { store.windowID }

    init(store: OfficialWindowStore,
         refresh: (() async throws -> Void)? = nil,
         preview: (() async throws -> OfficialWindowPreview)? = nil) {
        self.store = store
        self.refresh = refresh ?? { try await OfficialWindowClient.shared.refresh(store: store, maximumImages: 6) }
        self.preview = preview ?? { try await OfficialWindowClient.shared.preview(store: store) }
    }
}

/// Presentation only: delivery validation and photo retention stay in the store.
struct OfficialWindowStatusPresentation {
    enum Kind: Equatable {
        case preparing, stopped, checking, paused, verificationExpired, photosExpired
        case failed, noPublication, imageUnavailable, notChecked
    }
    let kind: Kind

    init(isConfigured: Bool, stopped: Bool = false, checking: Bool = false,
         failed: Bool = false, requiresVerification: Bool = false,
         catalog: OfficialWindowCatalog?, at now: Date) {
        if !isConfigured { kind = .preparing }
        else if stopped { kind = .stopped }
        else if checking && catalog == nil { kind = .checking }
        // snapshot() removes a catalog that fails today's validation, but
        // preserves checkedAt. Keep that need to recheck distinct from a first
        // failed fetch without making the rejected catalog displayable again.
        else if catalog == nil && requiresVerification { kind = .verificationExpired }
        else if catalog?.enabled == false { kind = .paused }
        else if let catalog, catalog.validUntil <= now { kind = .verificationExpired }
        else if let catalog, !catalog.photos.isEmpty,
                catalog.photos.allSatisfy({ $0.expiresAt <= now }) { kind = .photosExpired }
        else if failed { kind = .failed }
        else if let catalog {
            kind = catalog.availablePhotos(at: now).isEmpty ? .noPublication : .imageUnavailable
        } else { kind = .notChecked }
    }

    var title: String {
        switch kind {
        case .preparing: "公式のまどを準備しています"
        case .stopped: "受け取りをやめました"
        case .checking: "写真を読み込んでいます…"
        case .paused: "いまは写真が届きません"
        case .verificationExpired: "写真を読み込み直してください"
        case .photosExpired: "写真の公開が終わりました"
        case .failed: "写真を読み込めませんでした"
        case .noPublication: "いまは見られる写真がありません"
        case .imageUnavailable: "写真を表示できません"
        case .notChecked: "どんな写真が届くか見られます"
        }
    }

    var detail: String {
        switch kind {
        case .preparing: "写真の準備ができたら、このまどに届きます。"
        case .stopped: "また楽しみたくなったら、このまどの受け取りを再開できます。"
        case .checking: "少しお待ちください。"
        case .paused: "また届くようになったら、このまどで見られます。ほかのまども探せます。"
        case .verificationExpired: "「もう一度確認」を押すと、新しい写真を読み込みます。ほかのまども探せます。"
        case .photosExpired: "新しい写真を確かめるか、ほかのまどを探してみてください。"
        case .failed, .imageUnavailable: "少し待ってから、もう一度お試しください。"
        case .noPublication: "新しい写真が出たら、このまどに届きます。"
        case .notChecked: "受け取るかどうかは、見てから決められます。自分の写真を投稿する必要はありません。"
        }
    }

    var showsDiscovery: Bool {
        [.paused, .verificationExpired, .photosExpired].contains(kind)
    }
}

@MainActor
struct PublicWindowDiscoveryView: View {
    let sources: [PublicWindowPresentationSource]
    @Environment(\.scenePhase) private var scenePhase
    @State private var states: [String: OfficialWindowState]

    init(sources: [PublicWindowPresentationSource]) {
        self.sources = sources
        _states = State(initialValue: Dictionary(uniqueKeysWithValues:
            sources.map { ($0.id, $0.store.snapshot()) }))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(sources) { source in
                    OfficialWindowEntryCard(state: states[source.id], store: source.store, refreshFeed: source.refresh,
                        presentation: Version1.isOn ? .row : .discovery,
                        previewFeed: source.preview, relatedWindows: sources)
                }
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("公式のまど")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("window-discovery")
        .onReceive(NotificationCenter.default.publisher(for: .officialWindowPresentationDidChange)) { _ in
            reloadStates()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reloadStates() }
        }
    }

    private func reloadStates() {
        states = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.store.snapshot()) })
    }
}

@MainActor
struct OfficialWindowEntryCard: View {
    enum Presentation: Equatable { case list, discovery, row, wide }
    let state: OfficialWindowState
    let store: OfficialWindowStore
    let refreshFeed: () async throws -> Void
    let presentation: Presentation
    let previewFeed: () async throws -> OfficialWindowPreview
    let relatedWindows: [PublicWindowPresentationSource]
    let refreshFailed: Bool
    @StateObject private var preview: OfficialWindowPreviewModel

    init(state: OfficialWindowState? = nil,
         store: OfficialWindowStore = .shared,
         refreshFeed: (() async throws -> Void)? = nil, presentation: Presentation = .list,
         previewFeed: (() async throws -> OfficialWindowPreview)? = nil,
         relatedWindows: [PublicWindowPresentationSource] = [], refreshFailed: Bool = false) {
        let source = PublicWindowPresentationSource(store: store, refresh: refreshFeed, preview: previewFeed)
        self.state = state ?? store.snapshot()
        self.store = store
        self.refreshFeed = source.refresh
        self.refreshFailed = refreshFailed
        self.presentation = presentation
        self.previewFeed = source.preview
        self.relatedWindows = relatedWindows
        _preview = StateObject(wrappedValue: OfficialWindowPreviewModel(windowID: store.windowID))
    }

    private var photoDeadlines: [Date] {
        let catalog = state.isSubscribed ? state.catalog : preview.content?.catalog
        return ([Date.now] + [catalog?.validUntil].compactMap { $0 }
                + (catalog?.photos.map(\.expiresAt) ?? [])).sorted()
    }

    var body: some View {
        TimelineView(.explicit(photoDeadlines)) { context in
            entry(at: max(context.date, Date.now))
        }
    }

    private func entry(at now: Date) -> some View {
        // The cover and its VoiceOver value use the same photo at this boundary.
        let photo = state.isSubscribed ? state.photos.first : preview.content?.availablePhoto(at: now)
        let status = OfficialWindowStatusPresentation(isConfigured: store.endpoint != nil,
            checking: preview.isLoading, failed: refreshFailed || preview.failed,
            requiresVerification: state.isSubscribed && state.checkedAt != nil,
            catalog: state.isSubscribed ? state.catalog : preview.content?.catalog, at: now)
        return NavigationLink {
            OfficialWindowView(store: store, refreshFeed: refreshFeed,
                               previewFeed: previewFeed, preview: preview, relatedWindows: relatedWindows)
        } label: {
            if presentation == .list {
                WindowPhotoCard(title: store.displayName, kind: .official) { cover(photo: photo, status: status) }
            } else if presentation == .wide {
                // The same card as a shared window (16:10, the name over the photo).
                ZStack(alignment: .bottomLeading) {
                    Color(uiColor: .secondarySystemGroupedBackground)
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay { cover(photo: photo, status: status) }
                        .clipped()
                        .overlay(alignment: .bottom) {
                            LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                                .frame(height: 96)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.displayName).font(.title3.bold())
                        Text(store.definition.subtitle).font(.footnote)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    .padding(14)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else if presentation == .row {
                HStack(spacing: 14) {
                    cover(photo: photo, status: status)
                        .frame(width: 76, height: 76)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.displayName).font(.headline)
                        Text(store.definition.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Color(.tertiarySystemFill).aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay { GeometryReader { geometry in
                            cover(photo: photo, status: status)
                                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        } }
                    HStack {
                        Text(store.displayName).font(.headline)
                        Spacer()
                        if state.isSubscribed {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                                .accessibilityLabel("受け取り中")
                        }
                    }.padding(12)
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                // Clipping a fill image does not constrain its hit region.
                // Keep each navigation card inside the frame the person sees.
                .contentShape(RoundedRectangle(cornerRadius: 20))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(store.windowID == OfficialWindowCatalog.sourceID ? "official-window-entry" : "public-window-entry-\(store.windowID)")
        .accessibilityLabel("\(store.displayName)、写真を受け取るまど、公式")
        .accessibilityValue([state.isSubscribed ? "受け取り中" : "まだ受け取っていません",
                             photo?.displayCredit(in: store.windowID) ?? status.title]
            .compactMap { $0 }.joined(separator: "。"))
        .accessibilityHint(state.isSubscribed ? "受け取っている写真を開きます" : "どんな写真か見られます")
        .task {
            guard presentation != .list, !state.isSubscribed, store.endpoint != nil else { return }
            await preview.load(using: previewFeed)
        }
    }

    @ViewBuilder
    private func cover(photo: OfficialCatPhoto?, status: OfficialWindowStatusPresentation) -> some View {
        if let photo {
            OfficialPhotoImage(photo: photo, maximumPixelSize: 650, store: store,
                               previewImageData: state.isSubscribed ? nil : preview.content?.imageData,
                               fillsFrame: true)
                .id("\(photo.imageFilename)-\(state.imageRevision?.uuidString ?? "preview")")
                .accessibilityHidden(true)
        } else if preview.isLoading {
            ProgressView().accessibilityLabel("写真を読み込んでいます")
        } else {
            VStack(spacing: 12) {
                if refreshFailed || preview.failed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.largeTitle).foregroundStyle(.secondary)
                } else {
                    Image("ToolCat-hide").resizable().scaledToFit()
                        .frame(width: 58, height: 58).accessibilityHidden(true)
                }
                Text(status.title)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    let relatedWindows: [PublicWindowPresentationSource]

    private enum WidgetPlacement: String, CaseIterable {
        case first = "初めて置く"
        case existing = "すでに置いている"
    }

    init(initialPhotoID: String? = nil, store: OfficialWindowStore = .shared,
          refreshFeed: (() async throws -> Void)? = nil,
          previewFeed: (() async throws -> OfficialWindowPreview)? = nil,
          preview: OfficialWindowPreviewModel? = nil,
          relatedWindows: [PublicWindowPresentationSource] = []) {
        let source = PublicWindowPresentationSource(store: store, refresh: refreshFeed, preview: previewFeed)
        self.initialPhotoID = initialPhotoID
        self.store = store
        self.refreshFeed = source.refresh
        self.previewFeed = source.preview
        self.relatedWindows = relatedWindows
        _preview = StateObject(wrappedValue: preview ?? OfficialWindowPreviewModel(windowID: store.windowID))
        // The Widget already cached this photo. Resolve it before the first
        // frame, rather than opening the overview and then another sheet.
        _state = State(initialValue: store.snapshot())
    }

    private var isPreviewing: Bool { !state.isSubscribed && !stoppedHere && (initialPhotoID == nil || showsOverview) }
    private var isChecking: Bool { isRefreshing || (isPreviewing && preview.isLoading) }
    private var hasRefreshFailure: Bool { refreshFailed || (isPreviewing && preview.failed) }
    private var feedbackText: String? {
        message ?? (isPreviewing && preview.failed ? "写真を読み込めませんでした。もう一度お試しください。" : nil)
    }
    private var currentCatalog: OfficialWindowCatalog? { state.isSubscribed ? state.catalog : preview.content?.catalog }
    private var nextPhotoDeadline: Date? {
        guard let catalog = currentCatalog, catalog.enabled, catalog.validUntil > displayDate else { return nil }
        return ([catalog.validUntil] + catalog.photos.map(\.expiresAt)).filter { $0 > displayDate }.min()
    }
    private var photos: [OfficialCatPhoto] {
        if store.windowID == "black-cats", Version1.isOn {
            return currentCatalog?.widgetPhotos(at: displayDate) ?? []
        }
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
                                            relatedWindows: relatedWindows,
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
                                        relatedWindows: relatedWindows,
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
        .alert("「\(store.displayName)」の受け取りをやめますか？",
               isPresented: $confirmsStop) {
            Button("受け取りをやめる", role: .destructive) { changeSubscription(false) }
                .accessibilityIdentifier("official-window-stop-confirm")
            Button("受け取りを続ける", role: .cancel) {}
                .accessibilityIdentifier("official-window-stop-cancel")
        } message: {
            Text("このまどの写真が届かなくなり、ウィジェットにも出なくなります。あとでまた受け取れます。")
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
                ProgressView("写真を読み込んでいます…")
            } else {
                ContentUnavailableView("この写真は表示できません", systemImage: "photo",
                                       description: Text(message ?? "「\(store.displayName)」で、いま届いている写真を見られます。"))
                Button("\(store.displayName)を見る") {
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

                if !photos.isEmpty, let message = feedbackText {
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
                        Text("このまどの写真を受け取る").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("official-window-subscribe")
                }

            }
            .padding(20)
        }
        .accessibilityIdentifier("public-window-overview-\(store.windowID)")
        .navigationTitle(store.displayName)
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
                .accessibilityLabel("その他")
                .accessibilityIdentifier("official-window-manage")
            }
        }
    }

    private var about: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(store.displayName).font(.title2.weight(.semibold))
                    Text(store.definition.subtitle)
                    Text(store.definition.catID == nil
                         ? "運営が選んだ猫の写真が届きます。投稿も、友だちの招待もいりません。"
                         : "この猫の写真が届くまどです。新しい写真がないときは、次の写真が出るまでお待ちください。")
                    Text(store.windowID == "black-cats"
                         ? "写真を開くと、提供元と掲載日が見られます。毎日0時（日本時間）に新しい1枚に変わります。"
                         : "写真を開くと、提供元と掲載日が見られます。")
                    Text("新しい写真が届くと、ここに出ます。ウィジェットに出るまで、少し時間がかかることがあります。")
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
                    Label("ウィジェットの置き方", systemImage: "plus.rectangle.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("official-window-widget-guide")
                Button("あとで") { offersWidgetSetup = false }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("official-window-widget-later")
            } else {
                Button { showsWidgetGuide = true } label: {
                    Label("ウィジェットの置き方", systemImage: "plus.rectangle.on.rectangle")
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
                            Text("4. 「表示する写真」で、下のまどを選びます。")
                        } else {
                            Text("1. ホーム画面にある「ねこのまど」のウィジェットを長押しして、「ウィジェットを編集」を開きます。")
                            Text("2. 「表示する写真」で、下のまどを選びます。")
                        }
                        Label("\(store.displayName) · 公式のまど", systemImage: "pawprint.fill")
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
            Picker("ウィジェットを置いているか", selection: $widgetPlacement) {
                ForEach(WidgetPlacement.allCases, id: \.self) { placement in
                    Text(placement.rawValue).tag(placement)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("official-window-widget-placement")
        }
    }

    private var discoverySources: [PublicWindowPresentationSource] {
        if !relatedWindows.isEmpty { return relatedWindows }
        // Widget/deep-link entry has no list presenter. Use the same build-owned
        // registry as the main list while preserving this window's source.
        return OfficialWindowConfiguration.definitions.map { definition in
            definition.id == store.windowID
                ? PublicWindowPresentationSource(store: store, refresh: refreshFeed, preview: previewFeed)
                : PublicWindowPresentationSource(store: .forWindow(definition))
        }
    }

    private var introduction: some View {
        let status = OfficialWindowStatusPresentation(isConfigured: store.endpoint != nil,
            stopped: stoppedHere, checking: isChecking, failed: hasRefreshFailure,
            requiresVerification: state.isSubscribed && state.checkedAt != nil,
            catalog: currentCatalog, at: displayDate)
        return VStack(alignment: .leading, spacing: 12) {
            Label(status.title, systemImage: "photo.on.rectangle")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("official-window-state-title")
            Text(status.detail).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = feedbackText {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("official-window-feedback")
            }
            if isChecking { ProgressView() }
            if store.endpoint != nil, !stoppedHere {
                Button("もう一度確認") { Task { await refresh(interactive: true) } }
                    .frame(minHeight: 44)
                    .disabled(isChecking)
                    .accessibilityIdentifier("official-window-refresh-retry")
            }
            if status.showsDiscovery {
                NavigationLink {
                    PublicWindowDiscoveryView(sources: discoverySources)
                } label: {
                    Label("公式のまどを見る", systemImage: "building.2")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("official-window-state-discovery")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
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
        .accessibilityValue("提供元、\(photo.displayCredit(in: store.windowID))。\(photo.caption ?? "")")
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
                setFeedback("受け取りをやめました。一部の写真が残っていることがあります。")
            } else {
                setFeedback("うまく切り替えられませんでした。もう一度お試しください。")
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
                setFeedback("写真を読み込めませんでした。もう一度お試しください。", failed: true)
            } else if interactive {
                setFeedback(hasSamePublishedPhotos(as: previousPhotos) ? "新しい写真はありませんでした" : "写真を更新しました", transient: true)
            }
            return
        }
        let requestedSubscription = state.subscriptionID
        do {
            try await refreshFeed()
            guard store.snapshot().subscriptionID == requestedSubscription else { return }
            state = store.snapshot()
            displayDate = Date()
            setFeedback(interactive ? (hasSamePublishedPhotos(as: previousPhotos) ? "新しい写真はありませんでした" : "写真を更新しました") : nil,
                        transient: interactive)
        } catch is CancellationError {
            return
        } catch {
            if store.snapshot().subscriptionID == requestedSubscription {
                setFeedback("新しい写真を読み込めませんでした。少し待ってから、もう一度お試しください。", failed: true)
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
            // snapshot() deliberately discards expired catalogs. Capture the
            // cutover before replacing state so a subscribed window refreshes too.
            let dailyEditionEnded = store.windowID == "black-cats" && Version1.isOn
                && currentCatalog.map { $0.validUntil <= Date() } == true
            state = store.snapshot()
            displayDate = Date()
            dismissUnavailablePhoto()
            if dailyEditionEnded, scenePhase == .active {
                // Updating state changes nextPhotoDeadline and cancels this
                // observer task. Let the refresh finish outside that task.
                Task { await refresh() }
            }
        }
    }

    private func hasSamePublishedPhotos(as previous: [OfficialCatPhoto]) -> Bool {
        // A renewed display deadline is not a new photo. Keep every public
        // content field in this UI comparison; the store still checks full values.
        photos.elementsEqual(previous) { current, old in
            current.id == old.id && current.sha256 == old.sha256
                && current.catID == old.catID && current.catName == old.catName
                && current.credit == old.credit && current.caption == old.caption
                && current.photographedOn == old.photographedOn && current.publishedAt == old.publishedAt
                && current.imageFilename == old.imageFilename
                && current.width == old.width && current.height == old.height
        }
    }

    private func dismissUnavailablePhoto() {
        guard let selectedPhoto else { return }
        guard let current = photos.first(where: {
            $0.id == selectedPhoto.id && $0.sha256 == selectedPhoto.sha256
        }) else {
            self.selectedPhoto = nil
            return
        }
        // Only an available photo with the same verified image can renew this
        // selection. Withdrawal, expiry and an image replacement still dismiss it.
        if current != selectedPhoto {
            self.selectedPhoto = current
        }
    }
}

private struct OfficialPhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsInformation = false
    let photo: OfficialCatPhoto
    let store: OfficialWindowStore
    let imageRevision: UUID?
    var isRefreshing = false
    var previewImageData: Data? = nil
    var showsCloseButton = true
    var relatedWindows: [PublicWindowPresentationSource] = []
    var onRetry: (() -> Void)? = nil

    private var catWindow: PublicWindowPresentationSource? {
        guard let definition = OfficialWindowConfiguration.definition(forCatID: photo.catID),
              definition.id != store.windowID else { return nil }
        if let source = relatedWindows.first(where: { $0.id == definition.id }) {
            return source.store.definition.catID == photo.catID && source.store.endpoint != nil ? source : nil
        }
        guard definition.endpoint != nil else { return nil }
        return PublicWindowPresentationSource(store: .forWindow(definition))
    }

    var body: some View {
        PhotoDetailLayout {
            OfficialPhotoImage(photo: photo, maximumPixelSize: 2048, store: store,
                               isRefreshing: isRefreshing, previewImageData: previewImageData,
                               allowsZoom: true, onRetry: onRetry)
                .id("\(photo.imageFilename)-\(imageRevision?.uuidString ?? "")")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            photoActions
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("official-photo-detail-\(store.windowID)")
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
                        .accessibilityIdentifier("official-photo-close-\(store.windowID)")
                }
            }
        }
        .sheet(isPresented: $showsInformation) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let caption = photo.caption { Text(verbatim: caption).font(.body) }
                        Text("提供元：\(photo.displayCredit(in: store.windowID))")
                        if let date = photo.photographedOn { Text("撮影日：\(date)") }
                        Text("掲載日：\(photo.publishedAt.formatted(date: .abbreviated, time: .omitted))")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    .textSelection(.enabled)
                }
                .accessibilityIdentifier("official-photo-information-content")
                .navigationTitle("写真の情報").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button { showsInformation = false } label: {
                        Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("閉じる")
                    .accessibilityIdentifier("official-photo-information-close")
                } }
            }
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .preferredColorScheme(.dark)
        }
    }

    private var photoActions: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                photoSummary.fixedSize(horizontal: false, vertical: true)
                ScrollView { photoSummary }
            }
            if let source = catWindow {
                NavigationLink {
                    OfficialWindowView(store: source.store, refreshFeed: source.refresh,
                                       previewFeed: source.preview, relatedWindows: relatedWindows)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "pawprint").accessibilityHidden(true)
                        Text("この猫のまど").font(.subheadline)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption2).accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(source.store.displayName)を見る")
                .accessibilityHint("この猫の写真を見て、受け取るか選べます")
                .accessibilityIdentifier("official-photo-cat-window")
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
                    // Keep the display credit next to the photo. Full caption
                    // and dates remain in its information.
                    Text(verbatim: photo.displayCredit(in: store.windowID)).font(.caption).lineLimit(2)
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
                ZStack {
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
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(photo.catName)の写真")
                .accessibilityIdentifier("official-window-image-loaded")
            } else if isLoading {
                ProgressView().padding().accessibilityLabel("写真を読み込んでいます")
                    .accessibilityIdentifier("official-window-image-loading")
            } else {
                VStack(spacing: 12) {
                    Label("写真を読み込めませんでした", systemImage: "photo")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("official-window-image-unavailable")
                    if let onRetry {
                        Button(action: onRetry) {
                            Text("もう一度読み込む")
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("写真をもう一度読み込む")
                        .accessibilityIdentifier("official-photo-retry")
                    }
                }.padding()
            }
        }
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
    // Offline state inputs for the shipping list/detail UI regression.
    private let statusFixture = ProcessInfo.processInfo.environment["NEKO_OFFICIAL_WINDOW_STATUS_FIXTURE"]
    private let fixtureDate = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 2)
    let linkedPhotoID: String?
    @Published var linkedRefreshStarted = false
    @Published var finishLinkedRefresh = false
    @Published var linkedRefreshFailed = false

    init(definition: PublicWindowDefinition? = nil, initiallySubscribed: Bool? = nil) {
        let unavailable = CommandLine.arguments.contains("--official-window-unconfigured")
        store = OfficialWindowStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("official-fixture-" + UUID().uuidString),
            definition: definition ?? (CommandLine.arguments.contains("--black-cat-daily") ? PublicWindowDefinition(
                id: "black-cats", displayName: "黒猫のまど", subtitle: "1日1枚、きょうの黒猫",
                endpoint: unavailable ? nil : URL(string: "https://official.invalid/windows/black-cats/catalog.json")) : PublicWindowDefinition(
                id: OfficialWindowCatalog.sourceID, displayName: OfficialWindowCatalog.displayName,
                subtitle: "確認用の猫の写真",
                endpoint: unavailable ? nil : URL(string: "https://official.invalid/catalog.json")))
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
            if initiallySubscribed ?? CommandLine.arguments.contains("--window-list-subscribed") {
                do {
                    try store.setSubscribed(true)
                    if statusFixture != "failure" { try seedPhoto(failImage: false) }
                } catch {
                    assertionFailure("Could not seed the window list fixture")
                }
            }
        }
    }

    func refresh() async throws {
        if statusFixture == "failure" || statusFixture == "catalog-expiry" {
            throw URLError(.notConnectedToInternet)
        }
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
        try seedPhoto(failImage: attempts == 1 && !CommandLine.arguments.contains("--window-list-cat-window"))
    }

    private func seedPhoto(failImage: Bool) throws {
        let request = store.snapshot()
        guard request.isSubscribed else { return }
        if statusFixture == "paused" || statusFixture == "empty" {
            let catalog = OfficialWindowCatalog(schemaVersion: 1, channelID: store.windowID,
                enabled: statusFixture != "paused", generatedAt: fixtureDate,
                validUntil: fixtureDate.addingTimeInterval(86400), photos: [])
            try store.accept(catalog, for: request)
            return
        }
        let count = CommandLine.arguments.contains("--official-window-recent-photos") ? 3 : 1
        let items = try (0..<count).map { try fixturePhoto(index: $0) }
        let editionOffset = CommandLine.arguments.contains("--official-window-renew-expiry") ? Double(attempts) : 0
        let catalog = OfficialWindowCatalog(schemaVersion: 1, channelID: store.windowID, enabled: true,
                                           generatedAt: fixtureDate.addingTimeInterval(editionOffset),
                                           validUntil: fixtureDate.addingTimeInterval(statusFixture == "catalog-expiry" ? 14 : 86400 + editionOffset * 60),
                                           photos: items.map(\.photo))
        try store.accept(catalog, for: request)
        if failImage { throw URLError(.networkConnectionLost) }
        for item in items { try store.saveImage(item.data, photo: item.photo, for: request) }
    }

    func preview() async throws -> OfficialWindowPreview {
        let item = try fixturePhoto(index: 0)
        let catalog = OfficialWindowCatalog(schemaVersion: 1, channelID: store.windowID, enabled: true,
                                           generatedAt: fixtureDate, validUntil: fixtureDate.addingTimeInterval(86400), photos: [item.photo])
        return OfficialWindowPreview(catalog: catalog, photo: item.photo, imageData: item.data)
    }

    private func fixturePhoto(index: Int) throws -> (photo: OfficialCatPhoto, data: Data) {
        let isCatWindowFlow = CommandLine.arguments.contains("--window-list-cat-window")
        let original = MomentExperiencePhotoFixture.image(index: index + (isCatWindowFlow || store.windowID == OfficialWindowCatalog.sourceID ? 0 : 1))
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
        let renewal = CommandLine.arguments.contains("--official-window-renew-expiry") ? Double(max(0, attempts - 1)) * 60 : 0
        let photo = OfficialCatPhoto(
            id: index == 0 ? "fixture-photo" : "fixture-photo-\(index)",
            catID: store.definition.catID ?? (isCatWindowFlow ? "generated-tabby-nap" : "fixture-cat"),
            catName: store.windowID == "black-cats" ? "黒猫" : (isCatWindowFlow ? "キジ白" : (store.windowID == OfficialWindowCatalog.sourceID ? "確認用の猫" : "おひるねの猫")),
            credit: store.windowID == "black-cats" ? "ねこのまど（AI で作った画像）" : (isMixedShelf ? "ねこのまど（AI生成）" : "画面確認用の合成画像"),
            caption: store.windowID == "black-cats" ? nil : "窓辺でひと休み。",
            photographedOn: store.windowID == "black-cats" ? nil : "2026-09-01",
            publishedAt: fixtureDate.addingTimeInterval(-86400 * Double(index)),
            expiresAt: fixtureDate.addingTimeInterval((CommandLine.arguments.contains("--official-window-expiring-photo") ? 30 : 86400) + renewal),
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
                                           previewFeed: { try await model.preview() },
                                   relatedWindows: [PublicWindowPresentationSource(store: model.store,
                                       refresh: { try await model.refresh() }, preview: { try await model.preview() })])
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
                                   previewFeed: { try await model.preview() },
                                   relatedWindows: [PublicWindowPresentationSource(store: model.store,
                                       refresh: { try await model.refresh() }, preview: { try await model.preview() })])
            }
        }
    }
}
#endif
