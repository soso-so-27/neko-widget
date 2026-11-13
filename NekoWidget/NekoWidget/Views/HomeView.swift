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

    /// Remembered while the first row is on screen. Coming back then shows
    /// the list from its top, header and theme row included, instead of
    /// pinning the first row under the bar (10/27: the row above hid).
    static let listTop = ""

    static func identifier(for section: String) -> String? {
        let identifier = unsaved[section] ?? defaults.string(forKey: "photoLibrary.position.\(section).v1")
        return identifier == listTop ? nil : identifier
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
        for (section, identifier) in pending { save(identifier == listTop ? nil : identifier, section: section) }
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
    /// `firstRow`: the list's first row. A place saved there means the top,
    /// so coming back leaves the list at its top, header included.
    func restoringPhotoLibraryPosition(section: String?, isSearching: Bool = false, firstRow: String? = nil,
                                       normalize: @escaping (String) -> String = { $0 }) -> some View {
        modifier(PhotoLibraryPositionRestoration(section: section, isSearching: isSearching,
                                                firstRow: firstRow, normalize: normalize))
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
/// the top row is kept in memory as it changes, and a restore is one `scrollTo`.
private struct PhotoLibraryPositionRestoration: ViewModifier {
    let section: String?
    let isSearching: Bool
    let firstRow: String?
    let normalize: (String) -> String
    @State private var tracker = PhotoLibraryRowTracker()
    /// Where the visible part of the list begins (below a bar laid over it,
    /// such as the memo search field). Changes with the layout, not the scroll.
    @State private var readingTop: CGFloat = 0

    init(section: String?, isSearching: Bool, firstRow: String?, normalize: @escaping (String) -> String) {
        self.section = section
        self.isSearching = isSearching
        self.firstRow = firstRow
        self.normalize = normalize
    }

    @ViewBuilder func body(content: Content) -> some View {
        if let section {
            ScrollViewReader { proxy in
                content
                    .environment(\.photoLibraryRowTracker, tracker)
                    .environment(\.photoLibraryReadingTop, readingTop)
                    .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { readingTop = $0 }
                    .modifier(PhotoLibraryUserScrollDetector(tracker: tracker))
                    .onAppear {
                        tracker.isVisible = true
                        PhotoLibraryReadingPosition.activeSection = section
                        configure(section: section)
                        // 11/8: back from a memo (or a photo, or another app tab)
                        // this same scroll view kept its offset, with the opened
                        // row where it was. Scrolling to the saved top row only
                        // moved it away: back from 「スクロール確認 8」 the list
                        // showed 13-16. Only a newly made list restores.
                        guard !tracker.hasAppeared else {
                            tracker.userScrolled = false
                            PhotoLibraryReadingPosition.diagnose("reappear \(section): kept")
                            return
                        }
                        tracker.hasAppeared = true
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
        // 10/28: 306 saved the first row while the list sat at its top, and
        // every return pinned that row under the bar, hiding the theme row.
        guard let identifier, identifier != firstRow else { return }
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
    /// The list has restored once. Later appearances are the same scroll view
    /// coming back with its offset kept, so they do not move it.
    var hasAppeared = false
    var generation: UInt64 = 0
    var onTopChange: (@MainActor (String) -> Void)?
    /// Rows the lazy stack has made. It makes rows before they reach the
    /// screen and keeps them after they leave, so this is not what is visible.
    private var rendered: [String: Int] = [:]
    /// Made rows more than half above the visible top. 11/8: the top used to be
    /// the first made row, rows above the screen; back on the memo list 13-16
    /// showed instead of 8, and the photo grids saved rows above as well.
    private var passed: Set<String> = []
    private var lastTop: String?

    /// The list the person is touching is the one whose place is kept. The
    /// 写真 tab's pages sit side by side and all appear at once.
    func claimActiveSection() {
        guard isVisible, let section else { return }
        PhotoLibraryReadingPosition.activeSection = section
    }

    func appear(_ id: String, index: Int) {
        rendered[id] = index
        report()
    }

    /// No report: rows also go when the whole list leaves for a pushed screen,
    /// which must not move the place. A row scrolled away passed the top first.
    func disappear(_ id: String) {
        rendered[id] = nil
    }

    func move(_ id: String, isPast: Bool) {
        if isPast { passed.insert(id) } else { passed.remove(id) }
        report()
    }

    private func report() {
        var first: (key: String, value: Int)?
        for (id, index) in rendered where !passed.contains(id) && index < (first?.value ?? .max) {
            first = (id, index)
        }
        guard let first else { return }
        let top = first.value == 0 ? PhotoLibraryReadingPosition.listTop : first.key
        guard top != lastTop else { return }
        lastTop = top
        onTopChange?(top)
    }
}

private struct PhotoLibraryRowTrackerKey: EnvironmentKey {
    static let defaultValue: PhotoLibraryRowTracker? = nil
}

private struct PhotoLibraryReadingTopKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var photoLibraryRowTracker: PhotoLibraryRowTracker? {
        get { self[PhotoLibraryRowTrackerKey.self] }
        set { self[PhotoLibraryRowTrackerKey.self] = newValue }
    }

    fileprivate var photoLibraryReadingTop: CGFloat {
        get { self[PhotoLibraryReadingTopKey.self] }
        set { self[PhotoLibraryReadingTopKey.self] = newValue }
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
    @Environment(\.photoLibraryReadingTop) private var readingTop

    @ViewBuilder func body(content: Content) -> some View {
        if let tracker {
            let top = readingTop
            content
                .onAppear { tracker.appear(id, index: index) }
                .onDisappear { tracker.disappear(id) }
                .onChange(of: index) { _, index in tracker.appear(id, index: index) }
                // Only the flip past the visible top is reported: nothing is
                // redrawn and nothing is written while the list scrolls.
                .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).midY <= top } action: { isPast in
                    tracker.move(id, isPast: isPast)
                }
        } else {
            content
        }
    }
}

/// Marks that the person, not a restore, moved the list. On iOS 18 the scroll
/// view reports it directly; a DragGesture over the ScrollView remains on iOS 17.
private struct PhotoLibraryUserScrollDetector: ViewModifier {
    let tracker: PhotoLibraryRowTracker

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    tracker.userScrolled = true
                    tracker.claimActiveSection()
                }
            }
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { _ in
                tracker.userScrolled = true
                tracker.claimActiveSection()
            })
        }
    }
}

struct PhotoLibraryMonthDestination: Identifiable {
    let label: String
    let identifier: String
    var id: String { identifier }

    /// The months of these photos, newest first, worked out once per drawing.
    static func months(in photos: [PhotoPresentation]) -> [PhotoLibraryMonthDestination] {
        var seen = Set<String>()
        return photos.compactMap { photo in
            guard let date = photo.creationDate else { return nil }
            let components = Calendar.nekoGregorian.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else { return nil }
            let label = "\(year)年\(month)月"
            guard seen.insert(label).inserted else { return nil }
            return PhotoLibraryMonthDestination(label: label, identifier: photo.localIdentifier)
        }
    }
}

/// 「日付」: jump to a month of the grid. The months are handed in.
struct PhotoLibraryMonthJumpMenu: View {
    let months: [PhotoLibraryMonthDestination]
    let select: (String) -> Void

    var body: some View {
        if !months.isEmpty {
            Menu {
                ForEach(months) { month in
                    Button(month.label) { select(month.identifier) }
                }
            } label: {
                Label("日付", systemImage: "calendar")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .frame(minHeight: 44)
            }
            .accessibilityLabel("年月へ移動")
            .accessibilityIdentifier("photo-library-month-jump")
        }
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
    /// Continues a stopped search; nil (previews, fixtures) falls back to `rescan`.
    let resumeScan: (() -> Void)?
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
    /// Above the grid: themes and growth (新しいアルバム（試作）only).
    let themeRow: AnyView?
    /// 11/11: set by the 写真 tab when its cat row carries 「○枚」 and 「日付」,
    /// so the grid starts without a heading row of its own. A month chosen
    /// there arrives here and is cleared once the grid has moved.
    let tabRowMonthJump: Binding<String?>?

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
        resumeScan: (() -> Void)? = nil,
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
        headerAccessory: AnyView? = nil,
        themeRow: AnyView? = nil,
        tabRowMonthJump: Binding<String?>? = nil
    ) {
        self.themeRow = themeRow
        self.tabRowMonthJump = tabRowMonthJump
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
        self.resumeScan = resumeScan
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

    /// Inside the 写真 tab the grid runs edge to edge (no side margin), so
    /// each card and banner above it adds the screen's 16 itself (11/11).
    private var cardMargin: CGFloat { isEmbedded ? NekoSpacing.screenMargin : 0 }

    private var widgetPlacementHint: String {
        if #available(iOS 18.0, *) {
            "長押し →「編集」→「ウィジェットを追加」"
        } else {
            "長押し →「＋」→ ねこのまど"
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if hasPhotoAccess {
                    VStack(spacing: 18) {
                        if isLimitedAccess {
                            LimitedAccessBanner(chooseMorePhotos: chooseMorePhotos)
                                .padding(.horizontal, cardMargin)
                        }

                        if let themeRow { themeRow }

                        if showsCatProfileNavigation { catProfilesSection }

                        if case .unavailable = photoSourceStatus {
                            photoSourceRecoveryLink
                                .padding(.horizontal, cardMargin)
                        }

                        if shouldOfferWidgetPlacementGuide, !catPhotos.isEmpty {
                            widgetPlacementCard
                                .padding(.horizontal, cardMargin)
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
                        // An empty cat or 未分類 keeps the cat switch, so the
                        // person can go back to all cats from here.
                        if let headerAccessory, let readingPositionKey, readingPositionKey != "all" {
                            headerAccessory
                        }
                        emptyPhotoState
                            .padding(.horizontal, cardMargin)
                    }
                } else {
                    photoAccessCard
                        .padding(.horizontal, cardMargin)
                }
                supplementaryPhotos.padding(.top, 16)
                    .id("photo-library-all-archive")
            }
            .padding(.horizontal, isEmbedded ? 0 : 16)
            .padding(.vertical, 12)
        }
        .accessibilityIdentifier("photo-library-all-scroll")
        .onChange(of: tabRowMonthJump?.wrappedValue) { _, identifier in
            guard let identifier else { return }
            moveToMonth(identifier)
            tabRowMonthJump?.wrappedValue = nil
        }
        .restoringPhotoLibraryPosition(section: isEmbedded ? (readingPositionKey ?? "all") : nil,
            firstRow: catPhotos.first?.localIdentifier,
            normalize: { PhotoLibraryGridRow.identifier(containing: $0, in: catPhotos) })
        .navigationTitle("写真")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .toolbar {
            if !isEmbedded {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: showSettings) {
                    SettingsGearIcon()
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
            Label("猫の写真を見つけるには、写真へのアクセスを許可してください", systemImage: "photo.on.rectangle.angled")
                .font(.headline)

            Text(OnboardingPresentationCopy.purposeBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(action: requestPhotoAccess) {
                Text("写真へのアクセスを許可").frame(maxWidth: .infinity)
            }
            .nekoPrimaryButton()
            .accessibilityIdentifier("home-photo-permission")
        }
        .nekoGroupedCard()
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
                    Text("ホーム画面にウィジェットを置く").font(.headline)
                    // The same first two steps the placement guide shows for this iOS.
                    Text(widgetPlacementHint).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(NekoPalette.groupedCard, in: NekoRadius.shape(NekoRadius.card))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-widget-placement-guide")
        .accessibilityHint("ホーム画面にウィジェットを追加する手順を開きます")
    }

    /// One state and, only when it can help, one button (349: while a search
    /// was still running, 「まだ読み込めない写真があります」 stayed up for a
    /// long time with a gray 「もう一度探す」 that could not be pressed).
    private var partialScanStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if scan.isScanning {
                // Still searching: say so; there is nothing to press yet.
                Label("猫の写真を探しています", systemImage: "photo.badge.clock")
                    .font(.subheadline)
            } else {
                Label(scan.hasFailed ? "写真を最後まで探せませんでした"
                      : scan.hasDeferredAssets ? "読み込めなかった写真が\(scan.deferredAssets.formatted())枚あります"
                      : scan.isPaused ? "写真を探すのを一時停止しています" : "猫の写真を探しています",
                      systemImage: scan.hasFailed ? "exclamationmark.triangle" : "photo.badge.clock")
                    .font(.subheadline)
                if scan.hasFailed || scan.isPaused {
                    // Continues from where it stopped (photos already looked
                    // at are reused); only 「読み込めなかった写真」 below needs
                    // the search from the start that tries those again.
                    Button(scan.isPaused ? "続きを探す" : "もう一度探す", action: resumeScan ?? rescan)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("photo-library-partial-retry")
                } else if scan.hasDeferredAssets {
                    Button("もう一度探す", action: rescan)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("photo-library-partial-retry")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        // The same side margin as the 「〇枚」 row under it.
        .padding(.horizontal, isEmbedded ? 16 : 0)
        .accessibilityIdentifier("photo-library-partial-status")
    }

    private var monthDestinations: [PhotoLibraryMonthDestination] {
        PhotoLibraryMonthDestination.months(in: catPhotos)
    }

    /// The months are worked out once per drawing and handed in here.
    private func monthJumpMenu(_ months: [PhotoLibraryMonthDestination]) -> some View {
        PhotoLibraryMonthJumpMenu(months: months, select: moveToMonth)
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
            // 11/11: in the 写真 tab with cats, 「○枚」 and 「日付」 sit in the
            // cat row above the pages, so the first photo comes one row sooner.
            if tabRowMonthJump == nil {
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
                if isEmbedded {
                    monthJumpMenu(monthDestinations)
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 8)
            .padding(.horizontal, isEmbedded ? 16 : 0)
            .id("photo-library-all-heading")
            }

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
                    Text("写真の対象を選び直す")
                    Text("選んだアルバムが見つかりません")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityHint("選んだアルバムが見つかりません。写真の対象を選び直す画面を開きます")
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
                Label("写真を最後まで探せませんでした", systemImage: "exclamationmark.triangle")
            } description: {
                Text("写真へのアクセスを確認して、もう一度探してください。")
            } actions: {
                // 「写真を追加で選ぶ」 is the banner above (11/8: one door).
                Button("もう一度探す", systemImage: "arrow.clockwise", action: rescan)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .accessibilityIdentifier("photo-hub-scan-failed")
        } else if let readingPositionKey, readingPositionKey != "all", !scan.isScanning {
            ContentUnavailableView("表示できる写真がありません", systemImage: "photo.on.rectangle",
                description: Text("選んでいる猫と、写真へのアクセスを確かめてください。"))
                .frame(maxWidth: .infinity, minHeight: 280)
                .accessibilityIdentifier("photo-library-scoped-empty")
        } else if scan.hasFinalResult && scan.displayedCatCount == 0 && !scan.isScanning {
            ContentUnavailableView {
                Label(OnboardingPresentationCopy.scanZeroTitle, systemImage: "photo.on.rectangle")
            } description: {
                // 11/12: the same one sentence as the first run's scan page,
                // never 「アクセスを確かめて」 to someone who allowed it all.
                Text(isLimitedAccess ? OnboardingPresentationCopy.scanZeroLimitedBody
                                     : OnboardingPresentationCopy.scanZeroBody)
            } actions: {
                // 「写真を追加で選ぶ」 is the banner above (11/8: one door).
                Button("もう一度探す", systemImage: "arrow.clockwise", action: rescan)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        } else if scan.hasPreliminaryResult && scan.displayedCatCount == 0 {
            ContentUnavailableView {
                Label("猫の写真を探しています", systemImage: "photo.on.rectangle")
            } description: {
                Text("見つかるとここに表示します。")
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        } else {
            ContentUnavailableView {
                Label("猫の写真を探しています", systemImage: "photo.on.rectangle")
            } description: {
                Text(scan.isPaused
                    ? "アプリに戻ると、探すのを続けます。"
                    : "見つかるとここに表示します。")
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        }
    }

}
