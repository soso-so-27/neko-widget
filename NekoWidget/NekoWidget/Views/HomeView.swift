import SwiftUI
import UIKit

/// Only reading position is persisted here. No photo, note or cloud state is changed.
@MainActor
enum PhotoLibraryReadingPosition {
    static let defaults: UserDefaults = {
#if DEBUG
        if let suite = ProcessInfo.processInfo.environment["NEKO_PHOTO_UI_PREFERENCES_SUITE"],
           let defaults = UserDefaults(suiteName: suite) { return defaults }
#endif
        return .standard
    }()
    static var activeSection: String?
    static let returnToPhotoNotification = Notification.Name("PhotoLibraryReturnToOpenedPhoto")

#if DEBUG
    static var diagnosticEvents: [String] = []
    static let diagnosticNotification = Notification.Name("PhotoLibraryReadingPositionDiagnostic")
#endif
    static func diagnose(_ event: String) {
#if DEBUG
        guard ProcessInfo.processInfo.environment["NEKO_PHOTO_UI_PREFERENCES_SUITE"] != nil else { return }
        let compact = event.replacingOccurrences(of: "app-store-screenshot-fixture-page-", with: "p")
        diagnosticEvents.append(compact)
        print("[PhotoLibraryPosition] \(compact)")
        diagnosticEvents = Array(diagnosticEvents.suffix(80))
        // The native scroll binding can run inside a layout transaction.
        // Publish test diagnostics after that transaction, never mutate its ancestor.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: diagnosticNotification, object: nil)
        }
#endif
    }

    /// Positions read while scrolling, kept in memory until the list goes
    /// away or the app leaves the screen. Writing UserDefaults on every row
    /// woke every @AppStorage view above the grid (the app root and the tab
    /// view), so the whole screen was rebuilt row by row while scrolling.
    private static var unsaved: [String: String] = [:]

    static func identifier(for section: String) -> String? {
        unsaved[section] ?? defaults.string(forKey: "photoLibrary.position.\(section).v1")
    }

    /// While scrolling: memory only.
    static func remember(_ identifier: String, section: String) {
        unsaved[section] = identifier
    }

    /// Writes what was read while scrolling. Called when the list disappears
    /// and when the app goes to the background.
    static func flush() {
        let pending = unsaved
        unsaved = [:]
        for (section, identifier) in pending { save(identifier, section: section) }
    }

    static func save(_ identifier: String?, section: String) {
        unsaved[section] = nil
        let key = "photoLibrary.position.\(section).v1"
        guard defaults.string(forKey: key) != identifier else { return }
        diagnose("save \(section): \(defaults.string(forKey: key) ?? "nil") -> \(identifier ?? "nil")")
        if let identifier { defaults.set(identifier, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    static func returnToOpenedPhoto(_ identifier: String, section: String = "all") {
        diagnose("return to \(identifier)")
        save(identifier, section: section)
        NotificationCenter.default.post(name: returnToPhotoNotification, object: identifier,
                                        userInfo: ["section": section])
    }
}

extension View {
    func restoringPhotoLibraryPosition(section: String?, isSearching: Bool = false,
                                       normalize: @escaping (String) -> String = { $0 }) -> some View {
        modifier(PhotoLibraryPositionRestoration(section: section, isSearching: isSearching,
                                                normalize: normalize))
    }
}

/// A vertical scrolling target is one complete row, with a stable photo ID.
/// Keeping cells inside an ordinary HStack avoids resolving a nested grid's
/// container rectangle as the target of an individual cell.
struct PhotoLibraryGridRow: Identifiable {
    let photos: [PhotoPresentation]
    var id: String { photos[0].localIdentifier }

    static func rows(_ photos: [PhotoPresentation]) -> [Self] {
        stride(from: 0, to: photos.count, by: 3).map { start in
            Self(photos: Array(photos[start..<min(start + 3, photos.count)]))
        }
    }

    static func identifier(containing identifier: String, in photos: [PhotoPresentation]) -> String {
        guard let index = photos.firstIndex(where: { $0.localIdentifier == identifier }) else { return identifier }
        return photos[(index / 3) * 3].localIdentifier
    }
}

struct PhotoLibraryGridRowView<Cell: View>: View {
    let row: PhotoLibraryGridRow
    let spacing: CGFloat
    @ViewBuilder let cell: (PhotoPresentation) -> Cell

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(row.photos) { photo in
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay { cell(photo) }
            }
            ForEach(row.photos.count..<3, id: \.self) { _ in
                Color.clear.aspectRatio(1, contentMode: .fit)
            }
        }
    }
}

/// Remembers and restores where the person was reading.
///
/// 10/23: `scrollPosition(id:)` with `scrollTargetLayout` tracked the top row
/// on every frame and made the photo grid stutter all the way down (proved on
/// a real iPhone in 284 by turning it off). Now rows report when they come and
/// go to a plain object (no SwiftUI state, so scrolling re-renders nothing),
/// the top row is saved as it changes, and a restore is one `scrollTo`.
private struct PhotoLibraryPositionRestoration: ViewModifier {
    let section: String?
    let isSearching: Bool
    let normalize: (String) -> String
    @State private var tracker = PhotoLibraryRowTracker()

    init(section: String?, isSearching: Bool, normalize: @escaping (String) -> String) {
        self.section = section
        self.isSearching = isSearching
        self.normalize = normalize
    }

    @ViewBuilder func body(content: Content) -> some View {
        if let section {
            ScrollViewReader { proxy in
                content
                    .environment(\.photoLibraryRowTracker, tracker)
                    .modifier(PhotoLibraryUserScrollDetector(tracker: tracker))
                    .onAppear {
                        tracker.isVisible = true
                        PhotoLibraryReadingPosition.activeSection = section
                        configure(section: section)
                        let saved = PhotoLibraryReadingPosition.identifier(for: section).map(normalize)
                        PhotoLibraryReadingPosition.diagnose("appear \(section): \(saved ?? "nil")")
                        restore(saved, with: proxy)
                    }
                    .onDisappear {
                        tracker.isVisible = false
                        tracker.generation &+= 1
                        PhotoLibraryReadingPosition.flush()
                    }
                    .onReceive(NotificationCenter.default.publisher(
                        for: UIApplication.willResignActiveNotification)) { _ in
                        PhotoLibraryReadingPosition.flush()
                    }
                    .onChange(of: self.section) { _, newSection in
                        if tracker.isVisible { PhotoLibraryReadingPosition.activeSection = newSection }
                        guard let newSection else { return }
                        configure(section: newSection)
                        restore(PhotoLibraryReadingPosition.identifier(for: newSection).map(normalize), with: proxy)
                    }
                    .onChange(of: isSearching) { _, searching in
                        tracker.isSearching = searching
                        if !searching {
                            restore(PhotoLibraryReadingPosition.identifier(for: section).map(normalize), with: proxy)
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(
                        for: PhotoLibraryReadingPosition.returnToPhotoNotification)) { notification in
                        guard tracker.isVisible, (notification.userInfo?["section"] as? String ?? "all") == section,
                              let identifier = notification.object as? String else { return }
                        // Navigation's final layout may still be settling; scroll once it is done.
                        PhotoLibraryReadingPosition.diagnose("restore return \(identifier)")
                        restore(normalize(identifier), with: proxy)
                    }
            }
        } else {
            content
        }
    }

    private func configure(section: String) {
        tracker.section = section
        tracker.isSearching = isSearching
        tracker.onTopChange = { [tracker] top in
            guard tracker.isVisible, tracker.userScrolled, !tracker.isSearching,
                  let section = tracker.section,
                  PhotoLibraryReadingPosition.activeSection == section else { return }
            PhotoLibraryReadingPosition.remember(top, section: section)
        }
    }

    /// One jump, after layout. Rows that appear because of the jump are not
    /// the person's reading, so saving waits for their next touch.
    private func restore(_ identifier: String?, with proxy: ScrollViewProxy) {
        tracker.userScrolled = false
        tracker.generation &+= 1
        let generation = tracker.generation
        guard let identifier else { return }
        DispatchQueue.main.async {
            guard tracker.isVisible, generation == tracker.generation else { return }
            proxy.scrollTo(identifier, anchor: .top)
        }
    }
}

/// Which rows of a photo list are on screen. A plain object on purpose:
/// rows coming and going while scrolling must not re-render the list.
@MainActor
final class PhotoLibraryRowTracker {
    var section: String?
    var isVisible = false
    var isSearching = false
    var userScrolled = false
    var generation: UInt64 = 0
    var onTopChange: (@MainActor (String) -> Void)?
    private var visible: [String: Int] = [:]
    private var lastTop: String?

    func appear(_ id: String, index: Int) {
        visible[id] = index
        report()
    }

    func disappear(_ id: String) {
        visible[id] = nil
        report()
    }

    private func report() {
        guard let top = visible.min(by: { $0.value < $1.value })?.key, top != lastTop else { return }
        lastTop = top
        onTopChange?(top)
    }
}

private struct PhotoLibraryRowTrackerKey: EnvironmentKey {
    static let defaultValue: PhotoLibraryRowTracker? = nil
}

extension EnvironmentValues {
    var photoLibraryRowTracker: PhotoLibraryRowTracker? {
        get { self[PhotoLibraryRowTrackerKey.self] }
        set { self[PhotoLibraryRowTrackerKey.self] = newValue }
    }
}

extension View {
    /// A row of a photo list that remembers where the person was reading.
    func photoLibraryReadingRow(_ id: String, index: Int) -> some View {
        modifier(PhotoLibraryReadingRow(id: id, index: index))
    }
}

private struct PhotoLibraryReadingRow: ViewModifier {
    let id: String
    let index: Int
    @Environment(\.photoLibraryRowTracker) private var tracker

    func body(content: Content) -> some View {
        content
            .onAppear { tracker?.appear(id, index: index) }
            .onDisappear { tracker?.disappear(id) }
    }
}

/// Marks that the person, not a restore, moved the list. On iOS 18 the scroll
/// view reports it directly; a DragGesture over the ScrollView remains on iOS 17.
private struct PhotoLibraryUserScrollDetector: ViewModifier {
    let tracker: PhotoLibraryRowTracker

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                if phase == .interacting { tracker.userScrolled = true }
            }
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { _ in
                tracker.userScrolled = true
            })
        }
    }
}

private struct PhotoLibraryMonthDestination: Identifiable {
    let label: String
    let identifier: String
    var id: String { identifier }
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
    let readingPositionKey: String?
    let showsCatProfileNavigation: Bool
    /// Shown at the right of the 「猫写真」 heading (the 写真 tab's cat switch).
    let headerAccessory: AnyView?

    /// Rows are built lazily, so a large batch costs little; fewer appends
    /// mean fewer layout passes while the grid is moving.
    @State private var visibleDetectedPhotoCount = 120
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
        supplementaryPhotos: AnyView? = nil,
        readingPositionKey: String? = nil,
        showsCatProfileNavigation: Bool = true,
        headerAccessory: AnyView? = nil
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
        self.readingPositionKey = readingPositionKey
        self.showsCatProfileNavigation = showsCatProfileNavigation
        self.headerAccessory = headerAccessory
        _initialReadingIdentifier = State(initialValue: isEmbedded
            ? PhotoLibraryReadingPosition.identifier(for: readingPositionKey ?? "all") : nil)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if hasPhotoAccess {
                    VStack(spacing: 18) {
                        if isLimitedAccess {
                            LimitedAccessBanner(chooseMorePhotos: chooseMorePhotos)
                        }

                        if showsCatProfileNavigation { catProfilesSection }

                        if case .unavailable = photoSourceStatus {
                            photoSourceRecoveryLink
                        }

                        if shouldOfferWidgetPlacementGuide, !catPhotos.isEmpty {
                            widgetPlacementCard
                        }
                    }
                    .padding(.bottom, 16)
                    .id("photo-library-all-header")

                    if !catPhotos.isEmpty {
                        if scan.hasFailed || scan.hasDeferredAssets || scan.isScanning || scan.isPaused {
                            partialScanStatus
                        }
                        detectedPhotosSection
                    } else {
                        emptyPhotoState
                    }
                } else {
                    photoAccessCard
                }
                supplementaryPhotos.padding(.top, 16)
                    .id("photo-library-all-archive")
            }
            .padding(.horizontal, isEmbedded ? 0 : 16)
            .padding(.vertical, 12)
        }
        .accessibilityIdentifier("photo-library-all-scroll")
        .restoringPhotoLibraryPosition(section: isEmbedded ? (readingPositionKey ?? "all") : nil,
            normalize: { PhotoLibraryGridRow.identifier(containing: $0, in: catPhotos) })
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

    /// The first card on the tab until WidgetKit sees a Widget: a small
    /// preview of what the Widget shows, and the three words of the gesture.
    private var widgetPlacementCard: some View {
        Button(action: showWidgetPlacementGuide) {
            HStack(spacing: 12) {
                if let photo = catPhotos.first {
                    PhotoAssetImageView(
                        localIdentifier: photo.localIdentifier,
                        catBoundingBox: photo.catBoundingBox,
                        targetPixelSize: CGSize(width: 160, height: 160),
                        networkAccessAllowed: false
                    )
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("ホーム画面にまどを置く").font(.headline)
                    Text("長押し → ＋ → ねこのまど").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-widget-placement-guide")
        .accessibilityHint("ホーム画面にウィジェットを追加する手順を開きます")
    }

    private var partialScanStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(scan.hasFailed ? "写真の確認を完了できませんでした"
                  : scan.hasDeferredAssets ? "まだ読み込めない写真があります"
                  : scan.isPaused ? "写真の確認が一時停止しています" : "写真を確認しています",
                  systemImage: scan.hasFailed ? "exclamationmark.triangle" : "photo.badge.clock")
                .font(.subheadline)
            if scan.hasFailed || scan.hasDeferredAssets || scan.isPaused {
                Button("もう一度探す", action: rescan)
                    .frame(minHeight: 44)
                    .disabled(scan.isScanning)
                    .accessibilityIdentifier("photo-library-partial-retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityIdentifier("photo-library-partial-status")
    }

    private var monthDestinations: [PhotoLibraryMonthDestination] {
        var seen = Set<String>()
        return catPhotos.compactMap { photo in
            guard let date = photo.creationDate else { return nil }
            let components = Calendar.current.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else { return nil }
            let label = "\(year)年\(month)月"
            guard seen.insert(label).inserted else { return nil }
            return PhotoLibraryMonthDestination(label: label, identifier: photo.localIdentifier)
        }
    }

    private func moveToMonth(_ identifier: String) {
        guard let index = catPhotos.firstIndex(where: { $0.localIdentifier == identifier }) else { return }
        visibleDetectedPhotoCount = max(visibleDetectedPhotoCount, index + 120)
        initialReadingIdentifier = identifier
        PhotoLibraryReadingPosition.returnToOpenedPhoto(
            PhotoLibraryGridRow.identifier(containing: identifier, in: catPhotos),
            section: readingPositionKey ?? "all")
    }

    @ViewBuilder private var detectedPhotosSection: some View {
            HStack(alignment: .center, spacing: 10) {
                if let headerAccessory {
                    // The cat switch is the heading: 「ミケの写真 ▾」.
                    headerAccessory
                } else {
                    Text(showsCatProfileNavigation ? "すべての猫写真" : "猫写真")
                        .font(.title3.bold())
                        .accessibilityAddTraits(.isHeader)
                }
                Text("\(catPhotos.count.formatted())枚")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("photo-hub-detected-grid")
                Spacer()
                if isEmbedded, !monthDestinations.isEmpty {
                    Menu {
                        ForEach(monthDestinations) { month in
                            Button(month.label) { moveToMonth(month.identifier) }
                        }
                    } label: {
                        Label("日付", systemImage: "calendar")
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: 44)
                    }
                    .accessibilityLabel("年月へ移動")
                    .accessibilityIdentifier("photo-library-month-jump")
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 8)
            .padding(.horizontal, isEmbedded ? 16 : 0)
            .id("photo-library-all-heading")

            ForEach(Array(PhotoLibraryGridRow.rows(Array(catPhotos.prefix(restoredDetectedPhotoCount))).enumerated()),
                    id: \.element.id) { index, row in
                PhotoLibraryGridRowView(row: row, spacing: 2) { photo in
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
                }
                .id(row.id)
                .photoLibraryReadingRow(row.id, index: index)
                .onAppear {
                    if let last = row.photos.last { revealNextDetectedPhotos(after: last.localIdentifier) }
                }
            }
    }

    private func revealNextDetectedPhotos(after localIdentifier: String) {
        let displayedCount = min(restoredDetectedPhotoCount, catPhotos.count)
        guard displayedCount > 0, displayedCount < catPhotos.count,
              catPhotos[displayedCount - 1].localIdentifier == localIdentifier else { return }
        // Append to the same grid. Reappearing cells from an earlier batch
        // cannot reveal another page or replace the user's scroll position.
        visibleDetectedPhotoCount = min(catPhotos.count, displayedCount + 120)
    }

    private var restoredDetectedPhotoCount: Int {
        guard let initialReadingIdentifier,
              let index = catPhotos.firstIndex(where: { $0.localIdentifier == initialReadingIdentifier }) else {
            return visibleDetectedPhotoCount
        }
        return max(visibleDetectedPhotoCount, index + 120)
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
                        .font(.subheadline)
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
        if scan.hasFailed {
            ContentUnavailableView {
                Label("写真の確認を完了できませんでした", systemImage: "exclamationmark.triangle")
            } description: {
                Text("写真へのアクセスを確認して、もう一度探してください。")
            } actions: {
                VStack(spacing: 10) {
                    if isLimitedAccess {
                        Button("写真を追加で選ぶ", systemImage: "photo.badge.plus", action: chooseMorePhotos)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("もう一度探す", systemImage: "arrow.clockwise", action: rescan)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .accessibilityIdentifier("photo-hub-scan-failed")
        } else if let readingPositionKey, readingPositionKey != "all", !scan.isScanning {
            ContentUnavailableView("この表示の写真がありません", systemImage: "photo.on.rectangle",
                description: Text("猫の選択と写真の許可を確認してください。"))
                .frame(maxWidth: .infinity, minHeight: 280)
                .accessibilityIdentifier("photo-library-scoped-empty")
        } else if scan.hasFinalResult && scan.displayedCatCount == 0 && !scan.isScanning {
            ContentUnavailableView {
                Label("猫の写真は見つかりませんでした", systemImage: "photo.on.rectangle")
            } description: {
                Text("猫の写真を追加するか、写真の許可を確認してください。")
            } actions: {
                VStack(spacing: 10) {
                    if isLimitedAccess {
                        Button("写真を追加で選ぶ", systemImage: "photo.badge.plus", action: chooseMorePhotos)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("もう一度探す", systemImage: "arrow.clockwise", action: rescan)
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
                    ? "アプリに戻ると、探すのを続けます。"
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
                        Text("写真シャッフルは、設定したときの写真を使います。新しい写真を出すには、壁紙でアルバムを選び直してください。")
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
