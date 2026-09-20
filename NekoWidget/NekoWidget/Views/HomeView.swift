import SwiftUI
import UIKit

/// Only reading position is persisted here. No photo, note or cloud state is changed.
enum PhotoLibraryReadingPosition {
    static var defaults: UserDefaults {
#if DEBUG
        if let suite = ProcessInfo.processInfo.environment["NEKO_PHOTO_UI_PREFERENCES_SUITE"],
           let defaults = UserDefaults(suiteName: suite) { return defaults }
#endif
        return .standard
    }

    static func identifier(for section: String) -> String? {
        defaults.string(forKey: "photoLibrary.position.\(section).v1")
    }

    static func save(_ identifier: String?, section: String) {
        let key = "photoLibrary.position.\(section).v1"
        guard defaults.string(forKey: key) != identifier else { return }
        if let identifier { defaults.set(identifier, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

private struct PhotoLibraryItemFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PhotoLibraryItemCatalog: PreferenceKey {
    static var defaultValue: [String] { [] }
    static func reduce(value: inout [String], nextValue: () -> [String]) {
        value.append(contentsOf: nextValue())
    }
}

private struct PhotoLibraryViewportHeight: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    func photoLibraryReadingItem(_ identifier: String, section: String?) -> some View {
        self.id(identifier).background {
            if let section {
                GeometryReader { geometry in
                    Color.clear.preference(key: PhotoLibraryItemFrames.self,
                        value: [identifier: geometry.frame(in: .named("photoLibrary.\(section)"))])
                }
            }
        }
    }

    func photoLibraryReadingItems(_ identifiers: [String]) -> some View {
        preference(key: PhotoLibraryItemCatalog.self, value: identifiers)
    }

    func restoringPhotoLibraryPosition(section: String?, isSearching: Bool = false) -> some View {
        modifier(PhotoLibraryPositionRestoration(section: section, isSearching: isSearching))
    }
}

private struct PhotoLibraryPositionRestoration: ViewModifier {
    let section: String?
    let isSearching: Bool
    @State private var catalog: [String] = []
    @State private var restored = false
    @State private var isVisible = false
    @State private var pendingIdentifier: String?
    @State private var viewportHeight: CGFloat = 0
    @State private var requestedRestoration = false

    init(section: String?, isSearching: Bool) {
        self.section = section
        self.isSearching = isSearching
        _pendingIdentifier = State(initialValue: section.flatMap(PhotoLibraryReadingPosition.identifier))
    }

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .coordinateSpace(name: "photoLibrary.\(section ?? "standalone")")
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: PhotoLibraryViewportHeight.self, value: geometry.size.height)
                    }
                }
                .onPreferenceChange(PhotoLibraryViewportHeight.self) { viewportHeight = $0 }
                .onAppear {
                    pendingIdentifier = section.flatMap(PhotoLibraryReadingPosition.identifier)
                    requestedRestoration = false
                    restored = false
                    isVisible = true
                }
                .onDisappear { isVisible = false }
                .onPreferenceChange(PhotoLibraryItemCatalog.self) { catalog = $0 }
                .task(id: restoreTarget) {
                    guard let target = restoreTarget else { return }
                    // Wait until the loaded rows (including a paged grid) have entered layout.
                    await Task.yield()
                    guard !Task.isCancelled, !restored else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { proxy.scrollTo(target, anchor: .top) }
                    requestedRestoration = true
                }
                .onPreferenceChange(PhotoLibraryItemFrames.self) { frames in
                    guard let section, isVisible, !isSearching, !catalog.isEmpty else { return }
                    let visible = frames.filter {
                        $0.value.maxY > 1 && $0.value.minY < viewportHeight && $0.value.height > 0
                    }
                    if !restored {
                        if let pendingIdentifier {
                            guard requestedRestoration, visible[pendingIdentifier] != nil else { return }
                        }
                        restored = true
                    }
                    // Inspect visible cells only, not the entire photo library on every scroll.
                    guard let first = visible.min(by: {
                        $0.value.minY == $1.value.minY
                            ? $0.value.minX < $1.value.minX : $0.value.minY < $1.value.minY
                    }) else { return }
                    let atStart = first.key == catalog.first && first.value.minY >= 0
                    PhotoLibraryReadingPosition.save(atStart ? nil : first.key, section: section)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { _ in
                    // Missing/deleted rows never trap the user in a pending restoration.
                    if !isSearching { restored = true }
                })
                .onChange(of: isSearching) { _, searching in
                    if !searching {
                        pendingIdentifier = section.flatMap(PhotoLibraryReadingPosition.identifier)
                        requestedRestoration = false
                        restored = false
                    }
                }
        }
    }

    private var restoreTarget: String? {
        guard section != nil, isVisible, !restored, !isSearching,
              let pendingIdentifier, catalog.contains(pendingIdentifier) else { return nil }
        return pendingIdentifier
    }
}

struct HomeView: View {

    let catPhotos: [PhotoPresentation]
    let scan: ScanPresentation
    let hasPhotoAccess: Bool
    let isLimitedAccess: Bool
    let shouldOfferWidgetPlacementGuide: Bool
    let requestPhotoAccess: () -> Void
    let chooseMorePhotos: () -> Void
    let showWidgetPlacementGuide: () -> Void
    let showSettings: () -> Void
    let rescan: () -> Void
    let excludedCatPhotos: [ExcludedCatPhotoPresentation]
    let photoSourceAlbums: [PhotoSourceAlbumOption]
    let photoSourceStatus: PhotoSourceAlbumStatus
    let restoreCatCandidates: ([String]) async -> Void
    let selectPhotoSourceAlbum: (String?) async -> Void
    let refreshPhotoSourceAlbums: () async -> Void
    let catProfilesPresentation: CatProfilesPresentation
    let catProfilesActions: CatProfilesViewActions
    let isEmbedded: Bool
    let supplementaryPhotos: AnyView?

    @State private var visibleDetectedPhotoCount = 24
    @State private var openedCatProfileIdentifier: String?
    @State private var initialReadingIdentifier: String?

    init(
        scan: ScanPresentation,
        hasPhotoAccess: Bool,
        isLimitedAccess: Bool,
        shouldOfferWidgetPlacementGuide: Bool,
        requestPhotoAccess: @escaping () -> Void,
        chooseMorePhotos: @escaping () -> Void,
        showWidgetPlacementGuide: @escaping () -> Void,
        showSettings: @escaping () -> Void,
        rescan: @escaping () -> Void,
        catPhotos: [PhotoPresentation] = [],
        excludedCatPhotos: [ExcludedCatPhotoPresentation] = [],
        photoSourceAlbums: [PhotoSourceAlbumOption] = [],
        photoSourceStatus: PhotoSourceAlbumStatus = .allLibrary,
        restoreCatCandidates: @escaping ([String]) async -> Void = { _ in },
        selectPhotoSourceAlbum: @escaping (String?) async -> Void = { _ in },
        refreshPhotoSourceAlbums: @escaping () async -> Void = {},
        catProfilesPresentation: CatProfilesPresentation = .init(),
        catProfilesActions: CatProfilesViewActions = .noOp,
        isEmbedded: Bool = false,
        supplementaryPhotos: AnyView? = nil
    ) {
        self.catPhotos = catPhotos
        self.scan = scan
        self.hasPhotoAccess = hasPhotoAccess
        self.isLimitedAccess = isLimitedAccess
        self.shouldOfferWidgetPlacementGuide = shouldOfferWidgetPlacementGuide
        self.requestPhotoAccess = requestPhotoAccess
        self.chooseMorePhotos = chooseMorePhotos
        self.showWidgetPlacementGuide = showWidgetPlacementGuide
        self.showSettings = showSettings
        self.rescan = rescan
        self.excludedCatPhotos = excludedCatPhotos
        self.photoSourceAlbums = photoSourceAlbums
        self.photoSourceStatus = photoSourceStatus
        self.restoreCatCandidates = restoreCatCandidates
        self.selectPhotoSourceAlbum = selectPhotoSourceAlbum
        self.refreshPhotoSourceAlbums = refreshPhotoSourceAlbums
        self.catProfilesPresentation = catProfilesPresentation
        self.catProfilesActions = catProfilesActions
        self.isEmbedded = isEmbedded
        self.supplementaryPhotos = supplementaryPhotos
        _initialReadingIdentifier = State(initialValue: isEmbedded
            ? PhotoLibraryReadingPosition.identifier(for: "all") : nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if hasPhotoAccess {
                    if isLimitedAccess {
                        LimitedAccessBanner(chooseMorePhotos: chooseMorePhotos)
                    }

                    catProfilesSection

                    if case .unavailable = photoSourceStatus {
                        photoSourceRecoveryLink
                    }

                    if shouldOfferWidgetPlacementGuide, !catPhotos.isEmpty {
                        widgetPlacementCard
                    }

                    if !catPhotos.isEmpty {
                        detectedPhotosSection
                    } else {
                        emptyPhotoState
                    }
                } else {
                    photoAccessCard
                }
                supplementaryPhotos
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .restoringPhotoLibraryPosition(section: isEmbedded ? "all" : nil)
        .navigationTitle("写真")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .toolbar {
            if !isEmbedded {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("設定")
                .accessibilityIdentifier("window-settings-button")
            }
            }
        }
        .navigationDestination(item: $openedCatProfileIdentifier) { identifier in
            if hasPhotoAccess,
               let profile = catProfilesPresentation.profiles.first(where: { $0.identifier == identifier }) {
                CatProfileConfirmedPhotosView(
                    profile: profile,
                    allProfiles: catProfilesPresentation.profiles,
                    actions: catProfilesActions,
                    profileSettingsAlbumOptions: catProfilesPresentation.photoAlbumOptions
                )
            }
        }
        .onChange(of: catProfilesPresentation.profiles.map(\.identifier)) { _, identifiers in
            if let openedCatProfileIdentifier, !identifiers.contains(openedCatProfileIdentifier) {
                self.openedCatProfileIdentifier = nil
            }
        }
        .onChange(of: hasPhotoAccess) { _, hasAccess in
            if !hasAccess { openedCatProfileIdentifier = nil }
        }
    }

    private var photoAccessCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("このiPhoneの猫写真を見つけるには、写真へのアクセスが必要です", systemImage: "photo.on.rectangle.angled")
                .font(.headline)

            Text(OnboardingPresentationCopy.homePermissionBody(
                isMediaAvailable: SharingAPIConfiguration.current.isMediaAvailable
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("写真へのアクセスを許可", action: requestPhotoAccess)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("home-photo-permission")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var widgetPlacementCard: some View {
        Button(action: showWidgetPlacementGuide) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 14))

                Text("ウィジェットを置く")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.accentColor.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 20)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-widget-placement-guide")
        .accessibilityHint("ホーム画面にウィジェットを追加する手順を開きます")
    }

    private var detectedPhotosSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("すべての猫写真")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("photo-hub-detected-grid")
                Spacer()
                Text("\(catPhotos.count.formatted())枚")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
                spacing: 2
            ) {
                ForEach(catPhotos.prefix(restoredDetectedPhotoCount)) { photo in
                    NavigationLink(value: PhotosRoute.collectionPhoto(photo.localIdentifier)) {
                        PhotoAssetImageView(
                            localIdentifier: photo.localIdentifier,
                            catBoundingBox: photo.catBoundingBox,
                            targetPixelSize: CGSize(width: 360, height: 360),
                            targetAspectRatio: 1
                        )
                        .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("photo-hub-photo-\(photo.localIdentifier)")
                    .accessibilityLabel(detectedPhotoAccessibilityLabel(photo))
                    .accessibilityHint("写真を大きく表示します")
                    .photoLibraryReadingItem(photo.localIdentifier, section: isEmbedded ? "all" : nil)
                    .onAppear {
                        revealNextDetectedPhotos(after: photo.localIdentifier)
                    }
                }
            }
            .photoLibraryReadingItems(catPhotos.map(\.localIdentifier))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(.top, 2)
    }

    private func revealNextDetectedPhotos(after localIdentifier: String) {
        let displayedCount = min(restoredDetectedPhotoCount, catPhotos.count)
        guard displayedCount > 0, displayedCount < catPhotos.count,
              catPhotos[displayedCount - 1].localIdentifier == localIdentifier else { return }
        // Append to the same grid. Reappearing cells from an earlier batch
        // cannot reveal another page or replace the user's scroll position.
        visibleDetectedPhotoCount = min(catPhotos.count, displayedCount + 24)
    }

    private var restoredDetectedPhotoCount: Int {
        guard let initialReadingIdentifier,
              let index = catPhotos.firstIndex(where: { $0.localIdentifier == initialReadingIdentifier }) else {
            return visibleDetectedPhotoCount
        }
        return max(visibleDetectedPhotoCount, index + 24)
    }

    @ViewBuilder private var catProfilesSection: some View {
        if catProfilesPresentation.profiles.isEmpty {
            catProfilesLink
        } else {
            CatProfileNavigationStrip {
                ForEach(catProfilesPresentation.profiles) { profile in
                    Button {
                        openedCatProfileIdentifier = profile.identifier
                    } label: {
                        CatProfileNavigationLabel(profile: profile)
                    }
                    .accessibilityLabel("\(profile.displayName)の写真、\(profile.confirmedPhotoCount.formatted())枚")
                    .accessibilityIdentifier("photo-hub-cat-\(profile.identifier)")
                }
            } more: {
                catProfilesLink
            }
        }
    }

    private var catProfilesLink: some View {
        NavigationLink {
            CatProfilesView(
                presentation: catProfilesPresentation,
                actions: catProfilesActions
            )
        } label: {
            if catProfilesPresentation.profiles.isEmpty {
                HStack {
                    Label("猫ごとの写真", systemImage: "cat.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            } else {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("photo-hub-cat-profiles")
        .accessibilityLabel("猫の一覧と追加")
    }

    private var photoSourceRecoveryLink: some View {
        NavigationLink {
            CatCandidateCurationView(
                excludedPhotos: excludedCatPhotos,
                sourceAlbums: photoSourceAlbums,
                sourceStatus: photoSourceStatus,
                isLimitedAccess: isLimitedAccess,
                isScanning: scan.isScanning,
                chooseMorePhotos: chooseMorePhotos,
                restoreCatCandidates: restoreCatCandidates,
                selectSourceAlbum: selectPhotoSourceAlbum,
                refreshSourceAlbums: refreshPhotoSourceAlbums
            )
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("写真の対象を確認")
                    Text("選んだアルバムを利用できません")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityHint("選んだアルバムを利用できません。写真の対象を確認します")
        .accessibilityIdentifier("photo-hub-source-recovery")
    }

    private func detectedPhotoAccessibilityLabel(_ photo: PhotoPresentation) -> String {
        guard let creationDate = photo.creationDate else { return "撮影日不明の猫写真" }
        return "\(creationDate.formatted(.dateTime.year().month().day()))の猫写真"
    }

    @ViewBuilder
    private var emptyPhotoState: some View {
        if scan.hasFinalResult && scan.displayedCatCount == 0 && !scan.isScanning {
            ContentUnavailableView {
                Label("猫の写真は見つかりませんでした", systemImage: "photo.on.rectangle")
            } description: {
                Text("スキャンは正常に完了しました。猫が主役に写った写真を写真アプリに追加するか、写真へのアクセス範囲を確認して、もう一度スキャンしてください。")
            } actions: {
                VStack(spacing: 10) {
                    if isLimitedAccess {
                        Button("もっと写真を選ぶ", systemImage: "photo.badge.plus", action: chooseMorePhotos)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("もう一度スキャン", systemImage: "arrow.clockwise", action: rescan)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        } else if scan.hasPreliminaryResult && scan.displayedCatCount == 0 {
            ContentUnavailableView {
                Label("猫の写真を探しています", systemImage: "photo.on.rectangle")
            } description: {
                Text("見つかるとここに表示します。")
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        } else {
            ContentUnavailableView {
                Label("猫の写真を探しています", systemImage: "photo.on.rectangle")
            } description: {
                Text(scan.isPaused
                    ? "アプリへ戻るとスキャンを再開します。"
                    : "見つかるとここに表示します。")
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        }
    }

}

private struct HomeAlbumHighlightCard: View {
    let album: CuratedAlbumPresentation
    let coverPhoto: PhotoPresentation
    let aspectRatio: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoAssetImageView(
                localIdentifier: coverPhoto.localIdentifier,
                catBoundingBox: coverPhoto.catBoundingBox,
                targetPixelSize: CGSize(width: 720, height: 720),
                targetAspectRatio: aspectRatio
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(album.cardTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(album.countLabel)
                    .font(.caption.monospacedDigit().weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct PhotoShuffleGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("猫写真をロック画面にも")
                            .font(.title2.bold())
                        Text("アルバムを作ったら、Apple標準の写真シャッフルに一度設定します。")
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        GuideStep(number: 1, title: "ロック画面を長押し", detail: "「＋」をタップします。")
                        GuideStep(number: 2, title: "「写真シャッフル」を選ぶ", detail: "上部のカテゴリから開きます。")
                        GuideStep(number: 3, title: "「アルバム」を選ぶ", detail: "写真アプリの「うちの子」アルバムを指定します。")
                        GuideStep(number: 4, title: "頻度を「ロック時」に", detail: "ロック解除のたびに別の1枚を楽しめます。", isLast: true)
                    }
                    .padding(.horizontal, 16)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))

                    Label {
                        Text("写真シャッフルは設定時のアルバム内容を使います。アルバム更新後の写真を反映するには、壁紙で写真アプリの「うちの子」アルバムを選び直してください。")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    .padding(16)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))

                }
                .padding(20)
            }
            .navigationTitle("写真シャッフル")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("完了")
                }
            }
        }
    }
}

private struct GuideStep: View {
    let number: Int
    let title: String
    let detail: String
    var isLast = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(number.formatted())
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.tint, in: Circle())
                if !isLast {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.22))
                        .frame(width: 2, height: 42)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(.top, 16)
        .padding(.bottom, isLast ? 16 : 0)
    }
}
