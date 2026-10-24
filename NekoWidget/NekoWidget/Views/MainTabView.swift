import SwiftUI
import UIKit
import ImageIO
import Photos

enum PhotoLibrarySection: String, CaseIterable {
    case all, favorites, notes

    var title: String {
        switch self {
        case .all: "すべて"
        case .favorites: "お気に入り"
        case .notes: "メモ"
        }
    }
}

/// Photo entry always starts at All; list positions remain device-local.
@MainActor
final class PhotoLibrarySelectionState: ObservableObject {
    @Published private(set) var selection: PhotoLibrarySection = .all
    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "photoLibrary.lastSection.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        PhotoLibraryReadingPosition.activeSection = selection.rawValue
    }

    var binding: Binding<PhotoLibrarySection> {
        Binding(get: { self.selection }, set: { self.select($0) })
    }

    func select(_ section: PhotoLibrarySection) {
        if selection != section { PhotoLibraryReadingPosition.activeSection = section.rawValue }
        selection = section
        defaults.set(section.rawValue, forKey: storageKey)
    }
}

/// Thin underline tabs under the title, the way Photos lists its albums:
/// no box, no fill, the chosen one underlined.
struct PhotoLibrarySectionPicker: View {
    @Binding var selection: PhotoLibrarySection
    var isCompact = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 20))
        VStack(spacing: 0) {
            layout {
                ForEach(PhotoLibrarySection.allCases, id: \.self) { section in
                    Button { selection = section } label: {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selection == section ? .primary : .secondary)
                            .frame(minHeight: 44)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(selection == section ? Color.primary : .clear)
                                    .frame(height: 2)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("photos-section-\(section.rawValue)")
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            }
            Divider()
        }
        .padding(.horizontal, isCompact ? 0 : 16)
    }
}

enum PhotosRoute: Hashable {
    case photo(String)
    case collectionPhoto(String)
    case automaticAlbums
    case unavailableWidgetPhoto
}

private struct ShowcaseSession: Identifiable {
    let id = UUID()
    let currentPhotoIdentifier: String?
    let scopeID: String
}

/// The app's one accent is blue: 「いつも」 tools take its shades. Only the
/// 「もしも」 tools are warm, so colour itself means "in case".
private enum ToolTint {
    static let everyday = Color.accentColor
    static let everydayLight = Color(red: 0.36, green: 0.62, blue: 0.86)
    static let everydayDeep = Color(red: 0.22, green: 0.42, blue: 0.70)
    static let emergency = Color.orange
    static let emergencyWarm = Color(red: 0.93, green: 0.56, blue: 0.19)
    static let emergencyDeep = Color.red
    static let emergencyBrown = Color(red: 0.78, green: 0.36, blue: 0.26)
}

/// A cat in the row above the tools: round photo with a ring of twelve
/// marks around it (one per entry in この子のこと), and the name. The ring
/// fills as entries go in; no numbers.
private struct CatChip: View {
    let profile: CatProfilePresentation
    let progress: CatCareProgress

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                let total = max(progress.total, 1)
                let gap: CGFloat = 0.015
                ForEach(0 ..< total, id: \.self) { index in
                    Circle()
                        .trim(from: CGFloat(index) / CGFloat(total) + gap, to: CGFloat(index + 1) / CGFloat(total) - gap)
                        .stroke(index < progress.filled ? Color.accentColor : Color(.tertiarySystemFill),
                                style: StrokeStyle(lineWidth: 3.5, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                CatProfileThumbnail(photo: profile.coverPhoto)
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
            Text(profile.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: 72)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(profile.displayName)、この子のこと \(progress.filled)／\(progress.total)")
    }
}

/// A tool is a card you can see is a button: a big coloured symbol, the
/// name, one line of what it makes. No cat art, no small icons.
private struct ToolTile: View {
    let title: String
    let systemImage: String
    let subtitle: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(tint, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)、\(subtitle)")
    }
}

private struct ToolCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

enum MemoriesRoute: Hashable {
    case favorites
    case memoryNotes
    case memoryNote(UUID)
    case memoryNotePhoto(UUID)
    case reflectionsArchive
    case highlight(AlbumHighlightPresentation)
    case photo(String)
    case seasonalMovie(SeasonalMoviePeriodID)
    case monthlyWindow(MonthlyWindowPresentation)
    case catAlbums(String)
    case catHighlight(String, AlbumHighlightPresentation)
}

private struct SeasonalMoviePreparationKey: Hashable {
    let canPrepare: Bool
    let quarterStart: Date?
    let photoPresentationVersion: LibraryPresentationVersion
    let videoCatalogDigest: Int
    let sourceAlbumIdentifier: String?
}

private struct MonthlyWindowCollectionKey: Hashable {
    let canBuild: Bool
    let currentMonthStart: Date?
    let sourceAlbumIdentifier: String?
    let photoPresentationVersion: LibraryPresentationVersion
}

private struct SeasonalMovieArchiveAccessKey: Hashable {
    let canPresent: Bool
    let sourceAlbumIdentifier: String?
    let sourceResolutionRevision: Int
    let excludedIdentifiers: Set<String>
}

private struct SeasonalMovieArchiveVideoPeriod: Hashable, Sendable {
    let start: Date
    let end: Date
    let identifiers: Set<String>
}

private struct SeasonalMovieArchiveValidationKey: Hashable {
    let access: SeasonalMovieArchiveAccessKey
    let isActive: Bool
    let videoPeriods: [SeasonalMovieArchiveVideoPeriod]
}

struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.photoMemoStore) private var memoStore

    let currentPhoto: PhotoPresentation?
    let likedPhotos: [PhotoPresentation]
    let catPhotos: [PhotoPresentation]
    let libraryPhotos: [PhotoPresentation]
    var photoLibraryAssignments: [String: Set<String>]? = nil
    var photoLibraryProfileNames: [String: String]? = nil
    var receivedPhotoIdentifiers: Set<String> = []
    var savedPhotoIdentifiers: Set<String>? = nil
    var savedPhotoStateReadFailed: Bool = false
    var readablePhotoIdentifiers: Set<String>? = nil
    let photoPresentationVersion: LibraryPresentationVersion
    let scan: ScanPresentation
    let albumState: AlbumPresentationState
    let settings: SettingsPresentation
    let detectionAccuracySample: DetectionAccuracySamplePresentation
    let highResolutionRecoverySample: DetectionAccuracySamplePresentation
    let excludedCatPhotos: [ExcludedCatPhotoPresentation]
    let photoSourceAlbums: [PhotoSourceAlbumOption]
    let photoSourceStatus: PhotoSourceAlbumStatus
    let catProfilesPresentation: CatProfilesPresentation
    let profileAlbumPhotos: [String: [PhotoPresentation]]
    let catProfilesActions: CatProfilesViewActions
    let hasPhotoAccess: Bool
    let isLimitedAccess: Bool
    let isScanning: Bool
    let shouldOfferWidgetPlacementGuide: Bool
    let privateWindowDisplayName: String
    @Binding var deepLinkedPhotoIdentifier: String?
    @Binding var deepLinkedPhotoShownAt: Date?
    @Binding var deepLinkedFamilyWindowIsPresented: Bool
    @Binding var deepLinkedFamilyMomentSourceDigest: String?
    @Binding var pendingFamilyNotificationRoute: MomentNotificationRoute?

    let chooseMorePhotos: () -> Void
    let requestPhotoAccess: () -> Void
    let showWidgetPlacementGuide: () -> Void
    let setMemorySaved: (String, Bool) -> Void
    let exportPhotoBook: ([String]) async throws -> URL
    let exportMemoryPhoto: (String) async throws -> MemoryPhotoJPEGExport
    let albumOpened: (String, String) -> Void
    let updateAlbum: () -> Void
    let rescan: () async -> Void
    let savePhotoSettings: (PhotoRangePresentation, Int) async -> Void
    let saveDetectionSettings: (Double, Double) async -> Void
    let saveLifeReference: (CatLifeReference?) async -> Void
    let excludeFromCatCandidates: ([String]) async -> Void
    let restoreCatCandidates: ([String]) async -> Void
    let selectPhotoSourceAlbum: (String?) async -> Void
    let refreshPhotoSourceAlbums: () async -> Void
    let exportJSON: () async -> URL?
    var personalArchiveStore: PersonalArchiveStore? = nil
    var startsInPhotos = false

    @State private var selectedTab: AppTab = .memories
    @Environment(\.membershipAccess) private var membershipAccess
    @ObservedObject private var groupWindowOpenInbox = GroupWindowOpenInbox.shared
    @ObservedObject private var careStore = CatCareStore.shared
    @State private var didApplyInitialTab = false
    @AppStorage("navigation.lastTab.v1") private var lastViewedTab = AppTab.memories.rawValue
    @State private var arrivalDates: [String: [Date]] = [:]
    @State private var arrivalReadFailed = false
    @State private var receivedPhotoSourceLabels: [String: String] = [:]
    @State private var arrivalRefreshSequence = 0

    private var showsMadoTab: Bool {
        SharingAPIConfiguration.current.isReviewVisible || GroupWindowClientProvider.ui != nil
            || OfficialWindowConfiguration.definitions.contains { $0.endpoint != nil }
    }

    private var newMadoPhotoCount: Int {
        arrivalDates.reduce(0) { count, entry in
            let seen = UserDefaults.standard.double(forKey: "navigation.madoVisited.v1.\(entry.key)")
            return count + entry.value.filter { $0.timeIntervalSince1970 > seen }.count
        }
    }

    private func refreshReceivedPhotoSources() async {
        let sources = await Task.detached(priority: .utility) { () -> [String: String] in
            (try? SharingLifecycleGate.withExclusive {
                guard let catalog = try PrivateWindowCatalogStore.load() else { return [:] }
                var labels: [String: String] = [:]
                for window in catalog.windows {
                    guard let state = try? MomentSharingStateStore.loadWhileLifecycleLocked(localWindowID: window.localWindowID) else { continue }
                    for record in state.importedMemories {
                        labels[record.photoLocalIdentifier] = window.displayName + "から"
                    }
                }
                return labels
            }) ?? [:]
        }.value
        // Group window photos kept with 「自分のお気に入りに追加」: 「ゆかさんから」.
        var labels = sources
        let store = GroupWindowLocalPhotoStore.shared
        for window in await store.knownWindows() {
            for entry in await store.entries(windowID: window.id) {
                if let identifier = entry.favoriteLocalIdentifier {
                    labels[identifier] = GroupDisplayName.withSan(entry.senderDisplayName) + "から"
                }
            }
        }
        receivedPhotoSourceLabels = labels
    }

    private func rememberMadoVisit() {
        // Only dates in the successfully loaded snapshot are consumed. Photos
        // arriving later remain new. This preference never sends a read ACK.
        guard !arrivalReadFailed else { return }
        for (window, dates) in arrivalDates {
            guard let latest = dates.max() else { continue }
            let key = "navigation.madoVisited.v1.\(window)"
            UserDefaults.standard.set(max(UserDefaults.standard.double(forKey: key),
                                          latest.timeIntervalSince1970), forKey: key)
        }
    }

    private func refreshMadoArrivals() async {
        guard showsMadoTab else { return }
        arrivalRefreshSequence &+= 1
        let sequence = arrivalRefreshSequence
        let countsPrivateWindows = GroupWindowClientProvider.ui == nil
        let result = await Task.detached(priority: .utility) { () -> [String: [Date]]? in
            try? SharingLifecycleGate.withExclusive {
                let catalog = try PrivateWindowCatalogStore.load()
                var dates: [String: [Date]] = [:]
                let now = Date()
                for window in (countsPrivateWindows ? catalog?.windows ?? [] : []) where window.spaceID != nil {
                    let state = try MomentSharingStateStore.loadWhileLifecycleLocked(localWindowID: window.localWindowID)
                    guard state.reportOnlyUntil == nil else { continue }
                    dates[window.localWindowID] = state.inbox.compactMap { item in
                        guard item.state == .available || item.state == .acknowledged,
                              item.localJPEGFileName != nil, item.accessExpiresAt > now,
                              !state.isModerationHidden(item.id) else { return nil }
                        return item.receivedAt
                    }
                }
                for definition in OfficialWindowConfiguration.definitions where definition.endpoint != nil {
                    // The existing store validates subscription, channel, cat,
                    // expiry and the build-owned endpoint. No feed is fetched.
                    let state = OfficialWindowStore.forWindow(definition).snapshot()
                    dates["official:" + definition.id] = state.photos.map(\.publishedAt)
                }
                return dates
            }
        }.value
        guard sequence == arrivalRefreshSequence else { return }
        arrivalReadFailed = result == nil
        arrivalDates = result ?? [:]
        guard !didApplyInitialTab else { return }
        didApplyInitialTab = true
        // Explicit routes and the first-run photo destination take precedence.
        if deepLinkedFamilyWindowIsPresented || pendingFamilyNotificationRoute != nil {
            selectedTab = .windows
        } else if widgetOpenedPhotoIdentifier != nil || startsInPhotos {
            selectedTab = .photos
        } else {
            selectedTab = MainTabStartupPolicy.selection(lastTab: lastViewedTab,
                hasNewPhotos: newMadoPhotoCount > 0, showsMado: showsMadoTab)
        }
    }
    @StateObject private var photoLibrarySelection = PhotoLibrarySelectionState()
    @State private var photoLibraryProfileIdentifier: String?
    @StateObject private var showcaseStore = ShowcasePhotoStore.shared
    @AppStorage("showcase.lastScopeID.v1") private var showcaseScopeID = ""
    @State private var showcaseSession: ShowcaseSession?
    @State private var showsShowcasePreparation = false
    @State private var preparingShowcaseScopes = Set<String>()
    @State private var showcaseWaitingToOpen: String?
    @State private var showcasePreparationError = false
    @State private var showsShowcaseNoPhotos = false
    @State private var photoLibraryRevision = 0
    @State private var photosPath = NavigationPath()
    @State private var memoriesPath = NavigationPath()
    @State private var relatedPhotoRoute: PhotoRediscoveryRoute?
    @State private var relatedPhotoUsesLibraryScope = false
    @State private var showsSettings = false
    @State private var showsCatProfiles = false
    @State private var replaysWidgetGuideAfterSettingsDismiss = false
    @State private var widgetOpenedPhotoIdentifier: String?
    @State private var widgetShownAt: Date?
    @State private var albumHighlightsReferenceDate = Date()
    @StateObject private var householdAlbumCatalog = HouseholdAlbumCatalogCoordinator()
    @State private var seasonalMovie: SeasonalMoviePresentation?
    @State private var completedSeasonalMoviePreparationKey: SeasonalMoviePreparationKey?
    @State private var monthlyWindowCollection: MonthlyWindowCollectionPresentation?
    @State private var completedMonthlyWindowCollectionKey: MonthlyWindowCollectionKey?
    @StateObject private var seasonalMovieArchive = SeasonalMovieArchiveLibrary()
    @State private var validatedSeasonalMovieArchiveKey: SeasonalMovieArchiveValidationKey?
    @State private var accessibleSeasonalMovieVideoIdentifiers = Set<String>()
    @AppStorage(MonthlyWindowReadReceipt.storageKey)
    private var readMonthlyWindowPeriodIdentifier = ""
    @AppStorage(GrowthAlbumPhotoOverrides.storageKey)
    private var growthPhotoOverridesJSON = ""
    /// Test builds only: 設定 → テスト用「新しいアルバム（試作）」.
    @AppStorage(AlbumPrototype.key) private var albumPrototypeStored = false

    private var tabContent: some View {
        TabView(selection: Binding(get: { selectedTab }, set: { tab in
            // This setter is for a person's tab tap. Deep links continue to
            // set selectedTab directly and keep their exact-photo destination.
            if tab == .photos {
                photoLibrarySelection.select(.all)
                photosPath = NavigationPath()
            }
            if selectedTab == .windows && tab != .windows { rememberMadoVisit() }
            didApplyInitialTab = true
            lastViewedTab = tab.rawValue
            selectedTab = tab
        })) {
            NavigationStack(path: $memoriesPath) {
                albumRoot
                    .navigationDestination(for: AlbumRoute.self) { route in
                        albumDestination(for: route, defaultScope: .everyone)
                    }
                    .navigationDestination(for: AlbumCatalogRoute.self, destination: albumCatalogDestination)
                    .navigationDestination(for: MemoriesRoute.self) { memoriesDestination(for: $0) }
            }
            .environment(\.photoRelatedAlbums, relatedAlbums)
            .environment(\.openPhotoRelatedAlbum, { relatedPhotoUsesLibraryScope = false; relatedPhotoRoute = $0 })
            .tabItem {
                Label("アルバム", systemImage: "photo.stack.fill")
                    .accessibilityIdentifier("main-tab-memories")
            }
            .badge(hasUnreadMemoriesSummary && summaryOpens ? 1 : 0)
            .tag(AppTab.memories)

            NavigationStack(path: $photosPath) {
                photoLibrary
                .navigationDestination(for: PhotosRoute.self, destination: photosDestination)
                .navigationDestination(for: MemoriesRoute.self) { memoriesDestination(for: $0, libraryContext: true) }
                .navigationDestination(for: AlbumRoute.self) { route in
                    albumDestination(for: route, defaultScope: .everyone)
                }
                .navigationDestination(for: AlbumCatalogRoute.self, destination: albumCatalogDestination)
            }
            .environment(\.photoRelatedAlbums, relatedAlbums)
            .environment(\.openPhotoRelatedAlbum, { relatedPhotoUsesLibraryScope = false; relatedPhotoRoute = $0 })
            .environment(\.catProfilePhotoDestination, { profileID, photoID in
                AnyView(albumPhotoDetail(for: .allCatPhotos,
                    localIdentifier: photoID, scope: .profile(profileID)))
            })
            .tabItem {
                Label("写真", systemImage: "photo.on.rectangle.angled")
                    .accessibilityIdentifier("main-tab-photos")
            }
            .tag(AppTab.photos)

            if SharingAPIConfiguration.current.isReviewVisible || GroupWindowClientProvider.ui != nil
                || OfficialWindowConfiguration.definitions.contains(where: { $0.endpoint != nil }) {
                NavigationStack {
                    WindowListView(
                        opensActiveWindow: $deepLinkedFamilyWindowIsPresented,
                        pendingFamilyMomentSourceDigest: $deepLinkedFamilyMomentSourceDigest,
                        pendingFamilyNotificationRoute: $pendingFamilyNotificationRoute,
                        showSettings: { showsSettings = true }
                    )
                }
                // The window screens start 「写真を届ける」 from these cat photos.
                // Set on the stack: pushed screens take the stack's environment.
                .environment(\.groupWindowCatPhotos, catPhotos)
                .tabItem {
                    Label("まど", systemImage: "window.vertical.closed")
                        .accessibilityIdentifier("main-tab-windows")
                }
                .badge(newMadoPhotoCount)
                .tag(AppTab.windows)
            }

            NavigationStack {
                toolsView
            }
            .tabItem {
                Label("ツール", systemImage: "wrench.and.screwdriver")
                    .accessibilityIdentifier("main-tab-tools")
            }
            .tag(AppTab.tools)
        }
    }

    private var presentedTabContent: some View {
        tabContent
        .environment(\.toolProfileActions, catProfilesActions)
        .environment(\.receivedPhotoIdentifiers, receivedPhotoIdentifiers)
        .environment(\.catProfileAlbumsDestination, catProfileAlbumsDestination)
        .environment(\.showcaseOpenOne, { identifier in
            showcaseSession = ShowcaseSession(currentPhotoIdentifier: identifier, scopeID: "")
        })
        .environment(\.showcaseAddPhoto, { identifier, scope in
            guard showcaseCandidates.contains(where: { $0.localIdentifier == identifier }) else {
                throw ShowcasePhotoStore.Error.unavailable
            }
            try await showcaseStore.add(photoIdentifier: identifier, to: scope)
            showcaseScopeID = scope
        })
        .environment(\.showcaseAddTargets, showcaseAddScopes.map {
            ShowcaseAddTarget(id: $0, title: showcaseScopeTitle($0))
        })
        .alert("見せる写真を準備できませんでした", isPresented: $showcasePreparationError) {
            Button("編集画面を開く") { showsShowcasePreparation = true }
            Button("閉じる", role: .cancel) {}
        }
        .fullScreenCover(item: $showcaseSession) { session in
            ShowcasePhotoView(
                store: showcaseStore,
                items: showcaseItems(for: session),
                title: session.currentPhotoIdentifier == nil
                    ? showcaseScopeTitle(session.scopeID) : "この写真",
                onClose: { showcaseSession = nil },
                onManage: nil,
                initialScopeID: session.currentPhotoIdentifier == nil ? session.scopeID : nil,
                profiles: catProfilesPresentation.profiles,
                candidates: showcaseCandidates,
                onScopeSelected: { scopeID, preparesIfNeeded in
                    showcaseScopeID = scopeID
                    if preparesIfNeeded {
                        prepareShowcaseIfNeeded(openAfter: false, scopeID: scopeID)
                    }
                }
            )
        }
        .sheet(isPresented: $showsShowcasePreparation) {
            ShowcasePreparationView(
                store: showcaseStore,
                candidates: showcaseCandidates,
                profiles: catProfilesPresentation.profiles,
                scopeID: $showcaseScopeID
            )
        }
        .sheet(isPresented: $showsCatProfiles) {
            NavigationStack {
                CatProfilesView(presentation: catProfilesPresentation, actions: catProfilesActions,
                                opensProfileSettings: true)
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { showsCatProfiles = false }
                    } }
            }
        }
        .sheet(isPresented: $showsSettings, onDismiss: {
            photoLibraryRevision &+= 1
            presentDeferredWidgetGuide()
        }) {
            settingsSheet
                .onAppear {
#if DEBUG
                    PersonalArchiveSettingsTrace.shared.record("sheet-appeared")
#endif
                }
                .onDisappear {
#if DEBUG
                    PersonalArchiveSettingsTrace.shared.record("sheet-disappeared")
#endif
                }
        }
        .sheet(item: $relatedPhotoRoute, onDismiss: { relatedPhotoUsesLibraryScope = false }) { route in
            relatedAlbumsSheet(for: route)
        }
    }

    private var routedTabContent: some View {
        presentedTabContent
        .onChange(of: deepLinkSelection, initial: true) { _, selection in
            guard let identifier = selection.identifier else { return }
            relatedPhotoUsesLibraryScope = false
            relatedPhotoRoute = nil
            let isOutsideScopedSource = photoSourceStatus != .allLibrary
                && !catPhotos.contains(where: {
                    $0.localIdentifier == identifier
                })
            guard !excludedCatCandidateIdentifiers.contains(identifier),
                  !isOutsideScopedSource else {
                widgetOpenedPhotoIdentifier = nil
                widgetShownAt = nil
                showsSettings = false
                selectedTab = .photos
                photoLibrarySelection.select(.all)
                photosPath = NavigationPath()
                photosPath.append(PhotosRoute.unavailableWidgetPhoto)
                deepLinkedPhotoIdentifier = nil
                deepLinkedPhotoShownAt = nil
                return
            }
            widgetOpenedPhotoIdentifier = identifier
            widgetShownAt = selection.shownAt
            showsSettings = false
            selectedTab = .photos
            photoLibrarySelection.select(.all)
            photosPath = NavigationPath()
            photosPath.append(PhotosRoute.photo(identifier))
            deepLinkedPhotoIdentifier = nil
            deepLinkedPhotoShownAt = nil
        }
        .onChange(of: deepLinkedFamilyWindowIsPresented, initial: true) { _, isPresented in
            guard isPresented else { return }
            relatedPhotoUsesLibraryScope = false
            relatedPhotoRoute = nil
            showsSettings = false
            selectedTab = .windows
        }
        .onChange(of: groupWindowOpenInbox.pendingWindowID, initial: true) { _, windowID in
            // A group window's home-screen photo: show the まど tab, where
            // the group list opens that window.
            guard windowID != nil else { return }
            showsSettings = false
            selectedTab = .windows
        }
        .onChange(of: pendingFamilyNotificationRoute, initial: true) { _, route in
            guard route != nil else { return }
            relatedPhotoUsesLibraryScope = false
            relatedPhotoRoute = nil
            showsSettings = false
            selectedTab = .windows
            deepLinkedFamilyWindowIsPresented = true
        }
        .onChange(of: photosPath) { _, path in
            guard path.isEmpty else { return }
            widgetOpenedPhotoIdentifier = nil
            widgetShownAt = nil
        }
    }

    var body: some View {
        routedTabContent
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                consumeShowcaseLaunchRequest()
                Task { await refreshMadoArrivals() }
            } else if selectedTab == .windows { rememberMadoVisit() }
        }
        .task {
            if !showsMadoTab && !didApplyInitialTab {
                didApplyInitialTab = true
                selectedTab = startsInPhotos ? .photos : MainTabStartupPolicy.selection(
                    lastTab: lastViewedTab, hasNewPhotos: false, showsMado: false)
            }
            await refreshMadoArrivals()
            await refreshReceivedPhotoSources()
        }
        .onReceive(NotificationCenter.default.publisher(for: .receivedMemoryImportNeedsRefresh)) { _ in
            Task { await refreshReceivedPhotoSources() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .officialWindowPresentationDidChange)) { _ in
            Task { await refreshMadoArrivals() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .momentSharingSynchronizationSucceeded)) { _ in
            Task { await refreshMadoArrivals() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .momentSharingContentNeedsReload)) { _ in
            Task { await refreshMadoArrivals() }
        }
        .onChange(of: selectedTab) { oldTab, tab in
            if oldTab == .windows && tab != .windows { rememberMadoVisit() }
            lastViewedTab = tab.rawValue
            if tab != .tools { showcaseWaitingToOpen = nil }
        }
        .onChange(of: showcaseScopeID) { _, _ in
            showcaseWaitingToOpen = nil
        }
        .onChange(of: hasPhotoAccess) { _, canShowPhotos in
            if canShowPhotos { consumeShowcaseLaunchRequest() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ShowcaseLaunchRequest.notification)) { _ in
            Task { @MainActor in consumeShowcaseLaunchRequest() }
        }
        .onChange(of: settings.catLifeReference) { _, _ in
            // A legacy single-cat reference replaces calendar-year albums with
            // age/adoption buckets. Pop typed routes whose album may no longer
            // exist after the setting changes.
            memoriesPath = NavigationPath()
        }
        .onChange(of: memoriesPath.count) { _, count in
            if count == 0 { albumHighlightsReferenceDate = Date() }
        }
        .task(id: householdAlbumCatalogKey) {
            submitHouseholdAlbumCatalog()
        }
        .overlay(alignment: .bottomLeading) {
            #if DEBUG
            if ProcessInfo.processInfo.environment["NEKO_ALBUM_CATALOG_DEBUG"] == "1" {
                Text("catalog")
                    .font(.system(size: 1))
                    .opacity(0.01)
                    .accessibilityIdentifier("album-catalog-debug-state")
                    .accessibilityValue(householdAlbumCatalog.debugState(for: householdAlbumCatalogKey.access))
            }
            #endif
        }
        .task(id: seasonalMoviePreparationKey) {
            await prepareSeasonalMovie()
        }
        .task(id: monthlyWindowCollectionKey) {
            await prepareMonthlyWindowCollection()
        }
        .task(id: seasonalMovieArchiveValidationKey) {
            await resolveSeasonalMovieArchiveVideos()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if memoriesPath.isEmpty { albumHighlightsReferenceDate = Date() }
            await seasonalMovieArchive.load()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active,
                  personalArchiveStore != nil || PersonalArchiveStore.isConfigured else { return }
            let archiveStore = personalArchiveStore ?? .shared
            // Only explicitly enrolled records can have pending reflections.
            guard let account = try? await archiveStore.accountContext() else { return }
            try? await PhotoMemoCoordinator(noteStore: memoStore, archiveStore: archiveStore)
                .retryUpdates(expectedAccount: account)
        }
    }

    private var photoLibrary: some View {
        VStack(spacing: 0) {
            // One row, one kind of control: which photos (all / favorites / memos).
            PhotoLibrarySectionPicker(selection: photoLibrarySelection.binding, isCompact: true)
                .padding(.horizontal, 16)
            photoLibraryContent.id("\(photoLibraryRevision)-\(photoLibraryPositionKey)")
        }
        .navigationTitle("写真")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .onChange(of: photoLibraryPositionKey, initial: true) { _, key in
            PhotoLibraryReadingPosition.activeSection = key
        }
        .onChange(of: photoLibraryRegisteredIdentifiers) { _, identifiers in
            if let selected = photoLibraryProfileIdentifier,
               selected != "unassigned", !identifiers.contains(selected) {
                photoLibraryProfileIdentifier = nil
            }
        }
        // Settings lives in one place (the ツール tab), as in Apple's own apps.

    }

    @ViewBuilder private var albumRoot: some View {
        if AlbumPrototype.isOn(albumPrototypeStored) {
            AlbumPrototypeView(
                letters: hasPhotoAccess ? currentMonthlyWindowCollection?.letters ?? [] : [],
                movies: hasPhotoAccess ? currentSeasonalMovieRecords : [],
                catPhotos: hasPhotoAccess ? catPhotos : [],
                assignments: currentPhotoLibraryAssignments,
                profileNames: currentPhotoLibraryProfileNames,
                openMovie: { memoriesPath.append(MemoriesRoute.seasonalMovie($0)) }
            )
        } else {
            albumsView()
        }
    }

    private var showcaseCandidates: [PhotoPresentation] {
        // The library contains every accessible photo, including people and scenery.
        // Only cat candidates and photos explicitly confirmed for a cat belong here.
        let knownPhotos = Dictionary(
            (libraryPhotos + likedPhotos + catPhotos).map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let confirmedPhotos = catProfilesPresentation.profiles.flatMap(\.confirmedPhotos).map { photo in
            knownPhotos[photo.localIdentifier] ?? PhotoPresentation(
                localIdentifier: photo.localIdentifier,
                creationDate: photo.creationDate,
                catBoundingBox: photo.catBoundingBox,
                detectedCatCount: photo.detectedCatCount
            )
        }
        var seen = Set<String>()
        return (catPhotos + confirmedPhotos).filter {
            !excludedCatCandidateIdentifiers.contains($0.localIdentifier)
                && seen.insert($0.localIdentifier).inserted
        }.sorted { first, second in
            let firstFavorite = first.isLiked || first.isPhotoLibraryFavorite
            let secondFavorite = second.isLiked || second.isPhotoLibraryFavorite
            if firstFavorite != secondFavorite { return firstFavorite }
            if first.creationDate != second.creationDate {
                return (first.creationDate ?? .distantPast) > (second.creationDate ?? .distantPast)
            }
            return first.localIdentifier < second.localIdentifier
        }
    }

    private var toolsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // The cats are the door, but small: a row of faces above the
                // tools, each opening the cat's page. The tools stay tools.
                catStrip
                toolSection("いつも") {
                    showcaseToolCard
                }
                if !preparingShowcaseScopes.isEmpty {
                    ProgressView("見せる写真を準備中")
                }
                toolSection("もしも") {
                    NavigationLink {
                        LostCatEmergencyEntryView(
                            profiles: catProfilesPresentation.profiles,
                            unregisteredPhotos: unregisteredCatPhotos
                        )
                    } label: {
                        ToolTile(title: "迷子のとき", systemImage: "magnifyingglass",
                                 subtitle: "探す画像を作る", tint: ToolTint.emergency)
                    }
                    .buttonStyle(ToolCardButtonStyle())
                    .accessibilityIdentifier("tools-lost-cat-open")
                    NavigationLink {
                        CareHandoffView(profiles: catProfilesPresentation.profiles,
                                        unregisteredPhotos: unregisteredCatPhotos)
                    } label: {
                        ToolTile(title: "預けるとき", systemImage: "hand.raised.fill",
                                 subtitle: "お世話を渡す", tint: ToolTint.emergencyWarm)
                    }
                    .buttonStyle(ToolCardButtonStyle())
                    .accessibilityIdentifier("tools-care-open")
                    NavigationLink {
                        VeterinaryVisitsView(profiles: catProfilesPresentation.profiles,
                            photos: memoryNotePhotos, noteStore: memoStore)
                    } label: {
                        ToolTile(title: "病院で見せる", systemImage: "cross.case.fill",
                                 subtitle: "診察メモ", tint: ToolTint.emergencyDeep)
                    }
                    .buttonStyle(ToolCardButtonStyle())
                    .accessibilityIdentifier("tools-vet-open")
                    NavigationLink {
                        EvacuationPreparationView(profiles: catProfilesPresentation.profiles,
                                                  unregisteredPhotos: unregisteredCatPhotos)
                    } label: {
                        ToolTile(title: "避難に備える", systemImage: "backpack.fill",
                                 subtitle: "持ち物と行き先", tint: ToolTint.emergencyBrown)
                    }
                    .buttonStyle(ToolCardButtonStyle())
                    .accessibilityIdentifier("tools-evacuation-open")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("ツール")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("設定")
                    .accessibilityIdentifier("tools-settings-button")
            }
        }
    }

    private var showcaseToolCard: some View {
        Button {
            if showcaseStore.availableEntries(in: "").isEmpty && (!hasPhotoAccess || showcaseCandidates.isEmpty) {
                showsShowcaseNoPhotos = true
            } else { openPreparedShowcase(scopeID: "") }
        } label: {
            ToolTile(title: "写真を見せる", systemImage: "square.grid.3x3.fill",
                     subtitle: "ベストナインを作る", tint: ToolTint.everydayLight)
        }
        .buttonStyle(ToolCardButtonStyle())
        .accessibilityIdentifier("tools-showcase-open")
        .alert(hasPhotoAccess ? "猫の写真を準備しましょう" : "写真の許可が必要です", isPresented: $showsShowcaseNoPhotos) {
            Button(hasPhotoAccess ? "写真を開く" : "写真の許可を確認") {
                selectedTab = .photos
                photoLibrarySelection.select(.all)
                if !hasPhotoAccess { requestPhotoAccess() }
            }
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(scan.isScanning ? "猫の写真を探しています。見つかると使えるようになります。" : "「写真」で猫の写真とアクセス範囲を確認してください。")
        }
    }

    /// A row of the cats (face and name) and 「＋」. One tap opens the cat's page.
    private var catStrip: some View {
        // Large type: the same chips, one under the other, so names stay on a line.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        return ScrollView(dynamicTypeSize.isAccessibilitySize ? .vertical : .horizontal, showsIndicators: false) {
            layout {
                ForEach(catProfilesPresentation.profiles) { profile in
                    NavigationLink {
                        CatProfileDetailView(
                            profile: profile,
                            allProfiles: catProfilesPresentation.profiles,
                            manualCandidatePhotos: profile.manualCandidatePhotos,
                            photoAlbumOptions: catProfilesPresentation.photoAlbumOptions,
                            actions: catProfilesActions
                        )
                    } label: {
                        CatChip(profile: profile, progress: careProgress(for: profile))
                    }
                    .buttonStyle(ToolCardButtonStyle())
                    .accessibilityIdentifier("tools-cat-\(profile.identifier)")
                }
                NavigationLink {
                    CatProfilesView(presentation: catProfilesPresentation, actions: catProfilesActions,
                                    opensProfileSettings: true)
                } label: {
                    // 「＋」 alone: adding a cat needs no caption.
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 64, height: 64)
                        .background(Color(.secondarySystemGroupedBackground), in: Circle())
                        .overlay(Circle().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
                        .frame(width: 72, alignment: .top)
                }
                .buttonStyle(ToolCardButtonStyle())
                .accessibilityLabel(catProfilesPresentation.profiles.isEmpty ? "猫を追加" : "猫を追加・整理")
                .accessibilityIdentifier("tools-cat-profiles")
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("tools-cat-strip")
    }

    /// How far this cat's この子のこと is, for the chip's small line.
    private func careProgress(for profile: CatProfilePresentation) -> CatCareProgress {
        let record = careStore.state?.cats.first { $0.profileID?.uuidString == profile.identifier }
        let draft = record.map { CatCareDraft(record: $0, household: careStore.state?.household ?? CatCareHousehold()) }
            ?? CatCareDraft()
        return CatCareProgress(draft: draft, record: record)
    }

    private func toolSection<Content: View>(_ title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                        ? [GridItem(.flexible())]
                        : [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)],
                      spacing: 10, content: content)
        }
    }

    private func consumeShowcaseLaunchRequest() {
        guard ShowcaseLaunchRequest.hasPending else { return }
        guard hasPhotoAccess || !showcaseStore.availableEntries(in: effectiveShowcaseScopeID).isEmpty else {
            selectedTab = .photos
            photoLibrarySelection.select(.all)
            return
        }
        guard ShowcaseLaunchRequest.consume() else { return }
        selectedTab = .tools
        openPreparedShowcase()
    }

    private func openPreparedShowcase(scopeID: String? = nil) {
        let targetScopeID = scopeID ?? effectiveShowcaseScopeID
#if DEBUG && targetEnvironment(simulator)
        if ShowcasePhotoView.layoutFixtureItems != nil {
            showcaseSession = ShowcaseSession(currentPhotoIdentifier: nil, scopeID: targetScopeID)
            return
        }
#endif
        prepareShowcaseIfNeeded(openAfter: true, scopeID: targetScopeID)
    }

    private func showcaseItems(for session: ShowcaseSession) -> [ShowcasePhotoView.Item] {
        if let identifier = session.currentPhotoIdentifier { return [.current(identifier)] }
#if DEBUG && targetEnvironment(simulator)
        if let fixture = ShowcasePhotoView.layoutFixtureItems { return fixture }
#endif
        return showcaseStore.availableEntries(in: session.scopeID).compactMap { entry in
            showcaseStore.imageURL(for: entry).map { .prepared(entry, $0) }
        }
    }

    private func prepareShowcaseIfNeeded(openAfter: Bool, scopeID: String? = nil) {
        let scopeID = scopeID ?? effectiveShowcaseScopeID
        // A saved set opens as-is; recommendation runs only before this scope's first set.
        if !showcaseStore.availableEntries(in: scopeID).isEmpty {
            if openAfter {
                showcaseSession = ShowcaseSession(currentPhotoIdentifier: nil, scopeID: scopeID)
            }
            return
        }
        if showcaseStore.hasCorruptManifest {
            if openAfter { showcasePreparationError = true }
            return
        }
        if showcaseStore.hasInitialized(scopeID) {
            if openAfter {
                showcaseSession = ShowcaseSession(currentPhotoIdentifier: nil, scopeID: scopeID)
            }
            return
        }
        if openAfter { showcaseWaitingToOpen = scopeID }
        guard preparingShowcaseScopes.insert(scopeID).inserted else { return }
        let candidates = showcaseCandidatesForScope(scopeID)
        Task {
            let identifiers = await ShowcaseRecommender.identifiers(
                from: candidates,
                excluding: showcaseStore.excludedIdentifiers(in: scopeID)
            )
            do {
                try await showcaseStore.applyRecommendations(identifiers, to: scopeID)
                preparingShowcaseScopes.remove(scopeID)
                guard showcaseWaitingToOpen == scopeID,
                      selectedTab == .tools else { return }
                showcaseWaitingToOpen = nil
                showcaseSession = ShowcaseSession(currentPhotoIdentifier: nil, scopeID: scopeID)
            } catch {
                preparingShowcaseScopes.remove(scopeID)
                guard showcaseWaitingToOpen == scopeID else { return }
                showcaseWaitingToOpen = nil
                showcasePreparationError = true
            }
        }
    }

    private func showcaseCandidatesForScope(_ scopeID: String) -> [PhotoPresentation] {
        guard !scopeID.isEmpty else { return showcaseCandidates }
        guard let profile = catProfilesPresentation.profiles.first(where: {
            $0.identifier == scopeID
        }) else { return [] }
        let confirmed = Set(profile.confirmedPhotos.map(\.localIdentifier))
        return showcaseCandidates.filter { confirmed.contains($0.localIdentifier) }
    }

    private var effectiveShowcaseScopeID: String {
        showcaseScopeID
    }

    private var showcaseAddScopes: [String] {
        // Choosing a showcase set does not assign the photo to a cat profile.
        let scopes = [""] + catProfilesPresentation.profiles.map(\.identifier)
        guard scopes.contains(showcaseScopeID) else { return scopes }
        return [showcaseScopeID] + scopes.filter { $0 != showcaseScopeID }
    }

    private func showcaseScopeTitle(_ scopeID: String) -> String {
        catProfilesPresentation.profiles.first(where: { $0.identifier == scopeID })?.displayName
            ?? (scopeID.isEmpty ? "すべての猫" : "前に選んだ猫")
    }

    private var unregisteredCatPhotos: [PhotoPresentation] {
        let registeredIdentifiers = Set(catProfilesPresentation.profiles.flatMap { profile in
            profile.confirmedPhotos.map(\.localIdentifier)
        })
        return catPhotos.filter { !registeredIdentifiers.contains($0.localIdentifier) }
    }

    private var photoLibraryPositionKey: String {
        let mode = photoLibrarySelection.selection.rawValue
        return photoLibraryProfileIdentifier.map { "\(mode)-\($0)" } ?? mode
    }

    private var currentPhotoLibraryAssignments: [String: Set<String>] {
        photoLibraryAssignments ?? assignmentsByPhotoIdentifier
    }

    private var currentPhotoLibraryProfileNames: [String: String] {
        photoLibraryProfileNames ?? Dictionary(uniqueKeysWithValues: catProfilesPresentation.profiles.map { ($0.identifier, $0.displayName) })
    }

    private var photoLibraryRegisteredIdentifiers: Set<String> { Set(currentPhotoLibraryProfileNames.keys) }

    private var photoLibraryRediscoveryScope: CatProfileScopePresentation {
        photoLibraryProfileIdentifier.map(CatProfileScopePresentation.profile) ?? .everyone
    }

    private var permitsPhotoLibraryRediscovery: Bool {
        photoLibraryProfileIdentifier != "unassigned"
    }

    private func photoLibraryRelatedAlbums(for identifier: String, scope: CatProfileScopePresentation) -> [PhotoRelatedAlbumLink] {
        guard permitsPhotoLibraryRediscovery, scope == photoLibraryRediscoveryScope else { return [] }
        guard case let .profile(profileIdentifier) = scope else { return relatedAlbums(for: identifier, scope: scope) }
        let photos = photoLibraryCatPhotos
        guard photos.contains(where: { $0.localIdentifier == identifier }) else { return [] }
        let albums = CuratedAlbumBuilder().sections(from: photos, lifeReference: nil, includesGrowth: false)
            .flatMap(\.albums).filter { album in
                album.photos.contains { $0.localIdentifier == identifier }
                    && album.photos.contains { $0.localIdentifier != identifier }
            }
        var allowed = Set(albums.map { AlbumRoute.catAlbum(profileIdentifier: profileIdentifier, album: $0.id) })
        if photos.count > 1 { allowed.insert(.catAlbum(profileIdentifier: profileIdentifier, album: .allCatPhotos)) }
        return relatedAlbums(for: identifier, scope: scope).filter { allowed.contains($0.route) }
    }

    private func openPhotoLibraryRelatedAlbum(_ route: PhotoRediscoveryRoute) {
        relatedPhotoUsesLibraryScope = true
        relatedPhotoRoute = route
    }

    private func photoLibraryIncludes(_ identifier: String) -> Bool {
        let registered = photoLibraryRegisteredIdentifiers
        let assignments = (currentPhotoLibraryAssignments[identifier] ?? []).intersection(registered)
        return PhotoMemoryNoteLibraryPolicy.includes(selected: photoLibraryProfileIdentifier, identifiers: assignments)
    }

    private var photoLibraryCatPhotos: [PhotoPresentation] { catPhotos.filter { photoLibraryIncludes($0.localIdentifier) } }
    private var photoLibraryLikedPhotos: [PhotoPresentation] { likedPhotos.filter { photoLibraryIncludes($0.localIdentifier) } }
    private var photoLibraryBrowserPhotos: [PhotoPresentation] {
        photoLibraryCatPhotos.filter { !excludedCatCandidateIdentifiers.contains($0.localIdentifier) }
    }
    private var unavailablePhotoLibrarySavedCount: Int {
        let saved = savedPhotoIdentifiers ?? Set(likedPhotos.map(\.localIdentifier))
        let visible = Set((hasPhotoAccess ? photoLibraryLikedPhotos : []).map(\.localIdentifier))
        return saved.filter { photoLibraryIncludes($0) && !visible.contains($0) }.count
    }

    private var photoLibraryCatPicker: some View {
        Menu {
            photoLibraryCatButton("すべての猫", identifier: nil)
            ForEach(catProfilesPresentation.profiles) { profile in
                photoLibraryCatButton(profile.displayName, identifier: profile.identifier)
            }
            photoLibraryCatButton("未指定", identifier: "unassigned")
            Divider()
            Button("猫のプロフィール", systemImage: "cat.fill") { showsCatProfiles = true }
                .accessibilityIdentifier("photos-cat-profiles")
        } label: {
            HStack(spacing: 6) {
                Text((photoLibraryProfileIdentifier.map { currentPhotoLibraryProfileNames[$0] ?? "未指定" } ?? "すべての猫") + "の写真")
                    .font(.title3.bold())
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .foregroundStyle(.primary)
            .frame(minHeight: 44)
            .accessibilityAddTraits(.isHeader)
        }
        .accessibilityIdentifier("photos-cat-picker")
    }

    private func photoLibraryCatButton(_ title: String, identifier: String?) -> some View {
        Button { photoLibraryProfileIdentifier = identifier } label: {
            Text(title).font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(photoLibraryProfileIdentifier == identifier ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(photoLibraryProfileIdentifier == identifier ? .isSelected : [])
        .accessibilityIdentifier("photos-cat-\(identifier ?? "all")")
    }

    @ViewBuilder private var photoLibraryContent: some View {
        switch photoLibrarySelection.selection {
        case .all:
            allPhotosView
        case .favorites:
            SavedMemoriesGalleryView(photos: hasPhotoAccess ? photoLibraryLikedPhotos : [], startsInExportMode: false,
                                    isEmbedded: true,
                                    readingPositionKey: photoLibraryPositionKey,
                                    unavailableSavedPhotoCount: unavailablePhotoLibrarySavedCount,
                                    hasPhotoAccess: hasPhotoAccess,
                                    savedStateReadFailed: savedPhotoStateReadFailed,
                                    receivedPhotoIdentifiers: receivedPhotoIdentifiers,
                                    ownCatPhotoIdentifiers: Set(currentPhotoLibraryAssignments.compactMap { $0.value.isEmpty ? nil : $0.key }),
                                    receivedPhotoSourceLabels: receivedPhotoSourceLabels,
                                    exportPhotoBook: exportPhotoBook)
        case .notes:
            PhotoMemoryNotesListView(photos: memoryNotePhotos, store: memoStore, archiveStore: personalArchiveStore,
                                     isEmbedded: true,
                                     openCatPreparedness: nil,
                                     selectedProfileIdentifier: photoLibraryProfileIdentifier,
                                     currentPhotoAssignments: currentPhotoLibraryAssignments,
                                     registeredProfileIdentifiers: photoLibraryRegisteredIdentifiers,
                                     currentProfileNames: currentPhotoLibraryProfileNames,
                                     readingPositionKey: photoLibraryPositionKey) {
                photoLibrarySelection.select(.all)
            }
        }
    }

    private var allPhotosView: some View {
        HomeView(
            scan: scan, hasPhotoAccess: hasPhotoAccess, isLimitedAccess: isLimitedAccess,
            shouldOfferWidgetPlacementGuide: shouldOfferWidgetPlacementGuide,
            requestPhotoAccess: requestPhotoAccess, chooseMorePhotos: chooseMorePhotos,
            showWidgetPlacementGuide: showWidgetPlacementGuide,
            showSettings: { showsSettings = true }, rescan: { Task { await rescan() } },
            catPhotos: photoLibraryCatPhotos, excludedCatPhotos: excludedCatPhotos,
            photoSourceAlbums: photoSourceAlbums, photoSourceStatus: photoSourceStatus,
            restoreCatCandidates: restoreCatCandidates, selectPhotoSourceAlbum: selectPhotoSourceAlbum,
            refreshPhotoSourceAlbums: refreshPhotoSourceAlbums,
            catProfilesPresentation: catProfilesPresentation, catProfilesActions: catProfilesActions,
            isEmbedded: true,
            supplementaryPhotos: photoLibraryProfileIdentifier == nil ? AnyView(PersonalArchivePhotosSection(
                photos: hasPhotoAccess ? catPhotos : [], archiveStore: personalArchiveStore)) : nil,
            readingPositionKey: photoLibraryPositionKey,
            showsCatProfileNavigation: false,
            headerAccessory: catProfilesPresentation.profiles.isEmpty ? nil : AnyView(photoLibraryCatPicker)
        )
    }

    private var catProfileAlbumsDestination: CatProfileAlbumsDestination {
        { identifier, close in
            AnyView(albumsView(scope: .profile(identifier), openPhotosOverride: close)
                .navigationDestination(for: AlbumRoute.self) { route in
                    albumDestination(for: route, defaultScope: .profile(identifier))
                }
                .navigationDestination(for: AlbumCatalogRoute.self, destination: albumCatalogDestination)
                .navigationDestination(for: MemoriesRoute.self) { memoriesDestination(for: $0) })
        }
    }

    private var settingsSheet: some View {
        SettingsSheetHost(onClose: { showsSettings = false }) {
            SettingsView(
                settings: settings,
                detectionAccuracySample: detectionAccuracySample,
                highResolutionRecoverySample: highResolutionRecoverySample,
                hasPhotoAccess: hasPhotoAccess,
                isScanning: isScanning,
                albumState: albumState,
                canUpdatePhotoLibraryAlbum: scan.hasPreliminaryResult
                    && scan.displayedCatCount > 0,
                requestPhotoAccess: requestPhotoAccess,
                updatePhotoLibraryAlbum: updateAlbum,
                savePhotoSettings: savePhotoSettings,
                saveDetectionSettings: saveDetectionSettings,
                saveLifeReference: saveLifeReference,
                rescan: rescan,
                excludedCatPhotos: excludedCatPhotos,
                photoSourceAlbums: photoSourceAlbums,
                photoSourceStatus: photoSourceStatus,
                isLimitedAccess: isLimitedAccess,
                chooseMorePhotos: chooseMorePhotos,
                restoreCatCandidates: restoreCatCandidates,
                selectPhotoSourceAlbum: selectPhotoSourceAlbum,
                refreshPhotoSourceAlbums: refreshPhotoSourceAlbums,
                exportJSON: exportJSON,
                catProfilesPresentation: catProfilesPresentation,
                catProfilesActions: catProfilesActions,
                privateWindowDisplayName: privateWindowDisplayName,
                showWidgetPlacementGuide: {
                    replaysWidgetGuideAfterSettingsDismiss = true
                    showsSettings = false
                },
                personalArchiveStore: personalArchiveStore
            )
        }
        // The settings sheet is presented outside the TabView's environment.
        // Its profile-photo destination needs the same explicit album routes.
        .environment(\.catProfileAlbumsDestination, catProfileAlbumsDestination)
    }

    @ViewBuilder
    private func photosDestination(for route: PhotosRoute) -> some View {
        switch route {
        case let .photo(localIdentifier):
            detailView(for: localIdentifier)
        case let .collectionPhoto(localIdentifier):
            collectionDetailView(for: localIdentifier)
                .onDisappear {
                    // The grid saves its top visible row while scrolling. If
                    // a lower visible photo is opened, returning to that old
                    // top row can hide the photo that was just viewed. Restore
                    // after the pop rather than before its layout transition.
                    PhotoLibraryReadingPosition.returnToOpenedPhoto(
                        PhotoLibraryGridRow.identifier(containing: localIdentifier, in: photoLibraryCatPhotos),
                        section: photoLibraryPositionKey
                    )
                    if photosPath.isEmpty {
                        // A retained native scroll view can keep its final offset even
                        // when the saved/bound row ID is unchanged. Recreate only the
                        // root collection, after saving the exact return row.
                        photoLibraryRevision &+= 1
                        PhotoLibraryReadingPosition.diagnose("rebuild returned collection \(photoLibraryPositionKey) revision=\(photoLibraryRevision)")
                    }
                }
        case .automaticAlbums:
            automaticAlbumsView
        case .unavailableWidgetPhoto:
            ContentUnavailableView {
                Label("この写真は開けません", systemImage: "photo")
                    .accessibilityIdentifier("unavailable-widget-photo")
            } description: {
                Text("現在、表示する写真の範囲から外れています。")
            } actions: {
                Button {
                    photosPath = NavigationPath()
                } label: {
                    Text("写真を見る").frame(minHeight: 44)
                }
                .accessibilityIdentifier("unavailable-widget-open-photos")
            }
            .navigationTitle("写真")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func detailView(for localIdentifier: String) -> some View {
        photoDetail(for: localIdentifier,
                    shownAt: widgetOpenedPhotoIdentifier == localIdentifier ? widgetShownAt : nil,
                    openedFromWidget: widgetOpenedPhotoIdentifier == localIdentifier,
                    libraryContext: widgetOpenedPhotoIdentifier != localIdentifier)
    }

    @ViewBuilder
    func widgetPhotoDestination(for localIdentifier: String, shownAt: Date?) -> some View {
        // AppRoot calls this destination directly, outside MainTabView.body.
        // The installed host must own presentation state and supply the same
        // related-photo actions as the in-app browser.
        PhotoRelatedAlbumsHost(relatedAlbums: relatedAlbums, sheet: relatedAlbumsSheet) { openRelatedAlbum in
            if hasPhotoAccess,
               catPhotos.contains(where: { $0.localIdentifier == localIdentifier }),
               !excludedCatCandidateIdentifiers.contains(localIdentifier) {
                photoDetail(for: localIdentifier, shownAt: shownAt, openedFromWidget: true,
                            openRelatedAlbumOverride: openRelatedAlbum)
            } else {
                ContentUnavailableView("この写真は開けません", systemImage: "photo",
                                       description: Text("現在、表示する写真の範囲から外れているか、写真にアクセスできません。"))
                    .accessibilityIdentifier("unavailable-widget-photo")
            }
        }
        .id(localIdentifier)
    }

    @ViewBuilder
    func firstRunPhotoDestination(for localIdentifier: String) -> some View {
        PhotoRelatedAlbumsHost(relatedAlbums: relatedAlbums, sheet: relatedAlbumsSheet) { openRelatedAlbum in
            if hasPhotoAccess, photoPresentationVersion.canPresent,
               photoSourceStatus != .unavailable,
               catPhotos.contains(where: { $0.localIdentifier == localIdentifier }),
               !excludedCatCandidateIdentifiers.contains(localIdentifier) {
                photoDetail(for: localIdentifier, shownAt: nil, openedFromWidget: false,
                            openRelatedAlbumOverride: openRelatedAlbum)
            } else {
                ContentUnavailableView("この写真は開けません", systemImage: "photo",
                                       description: Text("現在、表示する写真の範囲から外れているか、写真にアクセスできません。"))
                    .accessibilityIdentifier("unavailable-first-run-photo")
            }
        }
        .id(localIdentifier)
    }

    private func relatedAlbumsSheet(for route: PhotoRediscoveryRoute) -> some View {
        PhotoRelatedAlbumsSheet(
            root: route,
            relatedAlbums: relatedAlbums,
            albumDestination: { AnyView(albumDestination(for: $0, defaultScope: .everyone)) },
            relatedDestination: { AnyView(photoRediscoveryDestination(for: $0)) }
        )
    }

    @ViewBuilder
    private func photoDetail(for localIdentifier: String, shownAt: Date?,
                             openedFromWidget: Bool, fromNote: Bool = false, libraryContext: Bool = false,
                             openRelatedAlbumOverride: OpenPhotoRelatedAlbum? = nil) -> some View {
        if hasPhotoAccess, photoPresentationVersion.canPresent,
           fromNote || photoSourceStatus != .unavailable,
           !libraryContext || photoLibraryIncludes(localIdentifier),
           let initialPhoto = (fromNote ? memoryNotePhotos : catPhotos).first(where: { $0.localIdentifier == localIdentifier }) {
            PhotoBrowserView(
                // A proposed photo and a Widget tap are one-photo entry points.
                // The grid uses a separate route whose browser can page through
                // the detected cat-photo collection.
                photos: [initialPhoto],
                libraryPhotos: libraryContext ? photoLibraryBrowserPhotos : scopedCatPhotos(for: .everyone),
                initialPhoto: initialPhoto,
                widgetShownAt: shownAt,
                showsWidgetTiming: openedFromWidget,
                setMemorySaved: setMemorySaved,
                exportMemoryPhoto: exportMemoryPhoto,
                excludedCatCandidateIdentifiers: excludedCatCandidateIdentifiers,
                excludeFromCatCandidates: { identifiers in
                    Task { await excludeFromCatCandidates(identifiers) }
                },
                restoreCatCandidates: { identifiers in
                    Task { await restoreCatCandidates(identifiers) }
                },
                profiles: catProfilesPresentation.profiles,
                assignmentsByPhotoIdentifier: assignmentsByPhotoIdentifier,
                replaceProfileAssignments: { values in
                    await catProfilesActions.replacePhotoAssignments(values)
                },
                navigationTitle: openedFromWidget && CloudyWindowStore.shared.configuration().enabled ? "この1枚" : "写真",
                legacyBirthday: settings.catLifeReference?.kind == .birthday ? settings.catLifeReference?.date.date() : nil
            )
            .environment(\.photoRediscoveryScope, libraryContext ? photoLibraryRediscoveryScope : .everyone)
            .environment(\.photoRediscoveryEnabled, !libraryContext || permitsPhotoLibraryRediscovery)
            .environment(\.photoRelatedAlbums, libraryContext ? photoLibraryRelatedAlbums : relatedAlbums)
            // The nearest environment wins. Direct destinations must use their
            // installed host's state, not MainTabView.body's unrelated state.
            .environment(\.openPhotoRelatedAlbum, openRelatedAlbumOverride
                ?? (libraryContext ? openPhotoLibraryRelatedAlbum : { relatedPhotoUsesLibraryScope = false; relatedPhotoRoute = $0 }))
            .id(photoPresentationVersion.sourceResolutionRevision)
        } else {
            unavailablePersonalPhotoView
        }
    }

    /// Related albums use today's permission/source/explicit-assignment state,
    /// never a Widget snapshot or inferred identity. A link must lead beyond
    /// the current photo to be useful.
    private func relatedAlbums(
        for localIdentifier: String, scope: CatProfileScopePresentation
    ) -> [PhotoRelatedAlbumLink] {
        guard hasPhotoAccess, photoPresentationVersion.canPresent,
              photoSourceStatus != .unavailable else { return [] }
        if relatedPhotoUsesLibraryScope {
            guard permitsPhotoLibraryRediscovery,
                  scope == photoLibraryRediscoveryScope else { return [] }
        }
        let photos = scopedCatPhotos(for: scope)
        guard photos.contains(where: { $0.localIdentifier == localIdentifier }) else { return [] }
        let albums = CuratedAlbumBuilder().sections(
            from: photos, lifeReference: nil, includesGrowth: false
        ).flatMap(\.albums).filter { album in
            album.photos.contains { $0.localIdentifier == localIdentifier }
                && album.photos.contains { $0.localIdentifier != localIdentifier }
        }
        func route(for albumID: CuratedAlbumID) -> AlbumRoute {
            if case let .profile(identifier) = scope {
                return .catAlbum(profileIdentifier: identifier, album: albumID)
            }
            return .album(albumID)
        }
        var links: [PhotoRelatedAlbumLink] = albums.compactMap { album in
            switch album.id {
            case .closeUp, .together, .multipleCats, .outing, .catDay:
                return PhotoRelatedAlbumLink(
                    group: .theme, title: album.title, route: route(for: album.id),
                    accessibilityIdentifier: "photo-related-theme-\(album.id.logKey)"
                )
            default:
                return nil
            }
        }
        let assigned = assignmentsByPhotoIdentifier[localIdentifier] ?? []
        for profile in catProfilesPresentation.profiles where assigned.contains(profile.identifier) {
            // A photo containing several cats must not silently widen a
            // browser that the person already filtered to one of them.
            if case let .profile(identifier) = scope, identifier != profile.identifier { continue }
            let catPhotos = scopedCatPhotos(for: .profile(profile.identifier))
            guard catPhotos.contains(where: { $0.localIdentifier == localIdentifier }),
                  catPhotos.contains(where: { $0.localIdentifier != localIdentifier }) else { continue }
            links.append(PhotoRelatedAlbumLink(
                group: .cat, title: profile.displayName,
                route: .catAlbum(profileIdentifier: profile.identifier, album: .allCatPhotos),
                accessibilityIdentifier: "photo-related-cat-\(profile.identifier)"
            ))
        }
        for album in albums {
            guard case .calendarYear = album.id else { continue }
            links.append(PhotoRelatedAlbumLink(
                group: .year, title: album.title, route: route(for: album.id),
                accessibilityIdentifier: "photo-related-year-\(album.id.logKey)"
            ))
        }
        return links
    }

    @ViewBuilder
    private func photoRediscoveryDestination(for route: PhotoRediscoveryRoute) -> some View {
        switch route {
        case let .day(context):
            DayPhotosView(date: context.date, photos: currentDayPhotos(context), navigationContext: context)
        case let .dayPhoto(context, localIdentifier):
            let photos = currentDayPhotos(context)
            if let initialPhoto = photos.first(where: { $0.localIdentifier == localIdentifier }) {
                PhotoBrowserView(
                    photos: photos, libraryPhotos: browserLibraryPhotos(for: context.scope),
                    initialPhoto: initialPhoto, widgetShownAt: nil, showsWidgetTiming: false,
                    setMemorySaved: setMemorySaved,
                    exportMemoryPhoto: exportMemoryPhoto,
                    excludedCatCandidateIdentifiers: excludedCatCandidateIdentifiers,
                    excludeFromCatCandidates: { identifiers in
                        Task { await excludeFromCatCandidates(identifiers) }
                    },
                    restoreCatCandidates: { identifiers in
                        Task { await restoreCatCandidates(identifiers) }
                    },
                    profiles: catProfilesPresentation.profiles,
                    assignmentsByPhotoIdentifier: assignmentsByPhotoIdentifier,
                    replaceProfileAssignments: { values in
                        await catProfilesActions.replacePhotoAssignments(values)
                    },
                    dayCollectionDate: context.date
                )
                .environment(\.photoRediscoveryScope, context.scope)
            } else {
                unavailableRediscoveryView
            }
        case let .album(sourcePhotoIdentifier, scope, album):
            if relatedAlbums(for: sourcePhotoIdentifier, scope: scope).contains(where: { $0.route == album }) {
                albumDestination(for: album, defaultScope: scope)
            } else {
                unavailableRediscoveryView
            }
        }
    }

    private func currentDayPhotos(_ context: PhotoRediscoveryDay) -> [PhotoPresentation] {
        guard hasPhotoAccess, photoPresentationVersion.canPresent,
              photoSourceStatus != .unavailable else { return [] }
        if relatedPhotoUsesLibraryScope {
            guard permitsPhotoLibraryRediscovery,
                  context.scope == photoLibraryRediscoveryScope else { return [] }
        }
        var seen = Set<String>()
        return browserLibraryPhotos(for: context.scope).filter { photo in
            guard let date = photo.creationDate,
                  !excludedCatCandidateIdentifiers.contains(photo.localIdentifier),
                  Calendar.current.isDate(date, inSameDayAs: context.date) else { return false }
            return seen.insert(photo.localIdentifier).inserted
        }.sorted {
            if $0.creationDate == $1.creationDate { return $0.localIdentifier < $1.localIdentifier }
            return ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }
    }

    private var unavailableRediscoveryView: some View {
        ContentUnavailableView("この写真の続きを開けません", systemImage: "photo.on.rectangle",
                               description: Text("写真の範囲や猫の指定が変わりました。前の画面に戻って選び直してください。"))
            .navigationTitle("写真")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("photo-rediscovery-unavailable")
    }

    @ViewBuilder
    private func collectionDetailView(for localIdentifier: String) -> some View {
        if hasPhotoAccess, photoPresentationVersion.canPresent,
           photoSourceStatus != .unavailable,
           let initialPhoto = photoLibraryCatPhotos.first(where: { $0.localIdentifier == localIdentifier }) {
            PhotoBrowserView(
                photos: photoLibraryCatPhotos,
                libraryPhotos: photoLibraryBrowserPhotos,
                initialPhoto: initialPhoto,
                widgetShownAt: nil,
                showsWidgetTiming: false,
                setMemorySaved: setMemorySaved,
                exportMemoryPhoto: exportMemoryPhoto,
                excludedCatCandidateIdentifiers: excludedCatCandidateIdentifiers,
                excludeFromCatCandidates: { identifiers in
                    Task { await excludeFromCatCandidates(identifiers) }
                },
                restoreCatCandidates: { identifiers in
                    Task { await restoreCatCandidates(identifiers) }
                },
                profiles: catProfilesPresentation.profiles,
                assignmentsByPhotoIdentifier: assignmentsByPhotoIdentifier,
                replaceProfileAssignments: { values in
                    await catProfilesActions.replacePhotoAssignments(values)
                }
            )
            .environment(\.photoRediscoveryScope, photoLibraryRediscoveryScope)
            .environment(\.photoRediscoveryEnabled, permitsPhotoLibraryRediscovery)
            .environment(\.photoRelatedAlbums, photoLibraryRelatedAlbums)
            .environment(\.openPhotoRelatedAlbum, openPhotoLibraryRelatedAlbum)
            .id(photoPresentationVersion.sourceResolutionRevision)
        } else {
            unavailablePersonalPhotoView
        }
    }

    @ViewBuilder
    private func memoryDetailView(for localIdentifier: String, libraryContext: Bool = false) -> some View {
        if hasPhotoAccess, photoPresentationVersion.canPresent,
           !libraryContext || photoLibraryIncludes(localIdentifier),
           (readablePhotoIdentifiers?.contains(localIdentifier)
            ?? (likedPhotos + libraryPhotos).contains { $0.localIdentifier == localIdentifier }) {
            let initialPhoto = photo(for: localIdentifier)
            PhotoBrowserView(
                photos: libraryContext ? photoLibraryLikedPhotos : likedPhotos,
                libraryPhotos: libraryContext ? photoLibraryBrowserPhotos : scopedCatPhotos(for: .everyone),
                initialPhoto: initialPhoto,
                widgetShownAt: nil,
                showsWidgetTiming: false,
                setMemorySaved: setMemorySaved,
                exportMemoryPhoto: exportMemoryPhoto,
                excludedCatCandidateIdentifiers: excludedCatCandidateIdentifiers,
                excludeFromCatCandidates: { identifiers in
                    Task { await excludeFromCatCandidates(identifiers) }
                },
                restoreCatCandidates: { identifiers in
                    Task { await restoreCatCandidates(identifiers) }
                },
                profiles: catProfilesPresentation.profiles,
                assignmentsByPhotoIdentifier: assignmentsByPhotoIdentifier,
                replaceProfileAssignments: { values in
                    await catProfilesActions.replacePhotoAssignments(values)
                }
            )
            .environment(\.photoRediscoveryScope, libraryContext ? photoLibraryRediscoveryScope : .everyone)
            .environment(\.photoRediscoveryEnabled, !libraryContext || permitsPhotoLibraryRediscovery)
            .environment(\.photoRelatedAlbums, libraryContext ? photoLibraryRelatedAlbums : relatedAlbums)
            .environment(\.openPhotoRelatedAlbum, libraryContext ? openPhotoLibraryRelatedAlbum : { relatedPhotoUsesLibraryScope = false; relatedPhotoRoute = $0 })
            .id(photoPresentationVersion.sourceResolutionRevision)
        } else {
            unavailablePersonalPhotoView
        }
    }

    private var unavailablePersonalPhotoView: some View {
        ContentUnavailableView("この写真は開けません", systemImage: "photo",
            description: Text("写真へのアクセスや表示する写真の範囲が変更されました。戻って選び直してください。"))
            .navigationTitle("写真")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("personal-photo-unavailable")
    }

    private func albumsView(
        scope: CatProfileScopePresentation = .everyone,
        showsReflectionArchive: Bool = false,
        showsHighlightArchive: Bool = false,
        openPhotosOverride: (() -> Void)? = nil
    ) -> LikedPhotosView {
        let profile: CatProfilePresentation?
        if case let .profile(identifier) = scope {
            profile = catProfilesPresentation.profile(identifier: identifier)
        } else {
            profile = nil
        }
        return LikedPhotosView(
            photos: likedPhotos,
            hasPhotoAccess: hasPhotoAccess,
            isPhotoSourceUnavailable: photoSourceStatus == .unavailable,
            monthlyWindowCollection: scope == .everyone ? currentMonthlyWindowCollection : nil,
            latestMonthlyWindowIsUnread: scope == .everyone && latestMonthlyWindowIsUnread,
            latestSeasonalMovieIsNew: scope == .everyone && latestSeasonalMovieIsNew,
            seasonalMovies: scope == .everyone ? currentSeasonalMovieRecords : [],
            exportPhotoBook: exportPhotoBook,
            openPhotos: openPhotosOverride ?? {
                photoLibrarySelection.select(.all)
                photosPath = NavigationPath()
                selectedTab = .photos
            },
            recoverPhotoSource: {
                openPhotosOverride?()
                photoLibrarySelection.select(.all)
                photosPath = NavigationPath()
                selectedTab = .photos
            },
            albumSections: scope == .everyone
                ? currentHouseholdAlbumCatalog?.sections ?? []
                : curatedAlbumSections(for: scope),
            preparedHighlights: scope == .everyone ? currentHouseholdAlbumCatalog?.highlights ?? [] : nil,
            isPreparingAlbums: scope == .everyone
                && householdAlbumCatalogKey.access.canBuild && currentHouseholdAlbumCatalog == nil,
            albumScan: scan,
            albumProfiles: catProfilesPresentation.profiles,
            albumOptions: catProfilesPresentation.photoAlbumOptions,
            albumProfileActions: catProfilesActions,
            albumScope: .constant(scope),
            showSettings: {
#if DEBUG
                PersonalArchiveSettingsTrace.shared.record("album-action")
#endif
                showsSettings = true
#if DEBUG
                PersonalArchiveSettingsTrace.shared.record("binding:\(showsSettings)")
#endif
            },
            showsReflectionArchive: showsReflectionArchive,
            showsHighlightArchive: showsHighlightArchive,
            referenceDate: albumHighlightsReferenceDate,
            isCatDetail: scope != .everyone,
            navigationTitleOverride: profile.map { "\($0.displayName)のアルバム" },
            memoryNoteStore: memoStore
        )
    }

    @ViewBuilder
    private func albumCatalogDestination(for route: AlbumCatalogRoute) -> some View {
        switch route {
        case .months:
            albumsView().periodArchive(showsMovies: false)
                .membershipFeature(.browseAlbums, hasContent: hasAutomaticAlbumContent)
        case .movies:
            albumsView().periodArchive(showsMovies: true)
                .membershipFeature(.browseAlbums, hasContent: hasAutomaticAlbumContent)
        case .cats:
            albumsView().catArchive
                .membershipFeature(.browseAlbums, hasContent: hasAutomaticAlbumContent)
        case let .years(profileIdentifier):
            AlbumScopedContent(
                profiles: catProfilesPresentation.profiles,
                initialScope: profileIdentifier.map(CatProfileScopePresentation.profile) ?? .everyone
            ) { scope in
                AlbumView(
                    sections: calendarAlbumSections(for: scope),
                    scan: scan,
                    profiles: catProfilesPresentation.profiles,
                    photoAlbumOptions: catProfilesPresentation.photoAlbumOptions,
                    profileActions: catProfilesActions,
                    selectedScope: .constant(scope),
                    showsAllPhotos: false, isEmbedded: true, showsProfilePicker: false
                ).yearArchive
            }
            .membershipFeature(.browseAlbums, hasContent: hasAutomaticAlbumContent)
        }
    }

    @ViewBuilder
    private func memoriesDestination(for route: MemoriesRoute, libraryContext: Bool = false) -> some View {
        switch route {
        case .memoryNotes:
            PhotoMemoryNotesListView(photos: memoryNotePhotos, store: memoStore, archiveStore: personalArchiveStore) {
                photoLibrarySelection.select(.all)
                photosPath = NavigationPath()
                selectedTab = .photos
            }
        case let .memoryNote(identifier):
            PhotoMemoryNoteDetailView(recordID: identifier, photos: memoryNotePhotos, store: memoStore,
                                      archiveStore: personalArchiveStore)
        case let .memoryNotePhoto(identifier):
            PhotoMemoryNotePhotoDestination(recordID: identifier, photos: memoryNotePhotos, store: memoStore) { photo in
                photoDetail(for: photo.localIdentifier, shownAt: nil, openedFromWidget: false, fromNote: true, libraryContext: libraryContext)
            }
        case .favorites:
            SavedMemoriesGalleryView(
                photos: likedPhotos, startsInExportMode: false,
                receivedPhotoIdentifiers: receivedPhotoIdentifiers,
                                    ownCatPhotoIdentifiers: Set(currentPhotoLibraryAssignments.compactMap { $0.value.isEmpty ? nil : $0.key }),
                                    receivedPhotoSourceLabels: receivedPhotoSourceLabels,
                                    exportPhotoBook: exportPhotoBook
            )
        case .reflectionsArchive:
            albumsView(showsReflectionArchive: true)
        case let .catAlbums(identifier):
            catAlbumsDestination(identifier, showsHighlightArchive: false)
        case let .catHighlight(identifier, snapshot):
            highlightDestination(snapshot, scope: .profile(identifier))
        case let .highlight(snapshot):
            highlightDestination(snapshot)
        case let .photo(localIdentifier):
            memoryDetailView(for: localIdentifier, libraryContext: libraryContext)
        case let .seasonalMovie(periodID):
            seasonalMovieDestination(periodID)
        case let .monthlyWindow(snapshot):
            MonthlyWindowView(
                presentation: refreshedMonthlyWindow(snapshot),
                setMemorySaved: setMemorySaved,
                exportMemoryPhoto: exportMemoryPhoto,
                libraryPhotos: scopedCatPhotos(for: .everyone),
                excludedCatCandidateIdentifiers: excludedCatCandidateIdentifiers,
                excludeFromCatCandidates: { identifiers in
                    Task { await excludeFromCatCandidates(identifiers) }
                },
                restoreCatCandidates: { identifiers in
                    Task { await restoreCatCandidates(identifiers) }
                },
                profiles: catProfilesPresentation.profiles,
                assignmentsByPhotoIdentifier: assignmentsByPhotoIdentifier,
                replaceProfileAssignments: { values in
                    await catProfilesActions.replacePhotoAssignments(values)
                }
            )
            .onAppear {
                if !refreshedMonthlyWindow(snapshot).photos.isEmpty {
                    markMonthlyWindowReadIfLatest(snapshot)
                }
            }
            .growingSummaryFeature(.monthlySummary(month: snapshot.monthNumber),
                                   hasContent: !refreshedMonthlyWindow(snapshot).photos.isEmpty)
        }
    }

    @ViewBuilder
    private func catAlbumsDestination(_ identifier: String, showsHighlightArchive: Bool) -> some View {
        if catProfilesPresentation.profile(identifier: identifier) != nil {
            albumsView(scope: .profile(identifier), showsHighlightArchive: showsHighlightArchive)
        } else {
            ContentUnavailableView("この猫のアルバムを開けません", systemImage: "cat",
                description: Text("プロフィールが変更されました。アルバムに戻って選び直してください。"))
        }
    }

    @ViewBuilder
    private func highlightDestination(
        _ snapshot: AlbumHighlightPresentation,
        scope: CatProfileScopePresentation = .everyone
    ) -> some View {
        // Resolve saved route identifiers against the current, scoped library.
        // Permission changes, exclusions and changed cat scopes cannot restore
        // stale photos merely because they were in an earlier preview.
        let current = curatedAlbum(for: snapshot.sourceAlbumID, scope: scope)?.photos ?? []
        let currentByID = Dictionary(current.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let photos = hasPhotoAccess ? snapshot.photos.compactMap { currentByID[$0.localIdentifier] } : []
        if let first = photos.first {
            PhotoBrowserView(
                photos: photos, libraryPhotos: browserLibraryPhotos(for: scope), initialPhoto: first,
                widgetShownAt: nil, showsWidgetTiming: false,
                setMemorySaved: setMemorySaved,
                exportMemoryPhoto: exportMemoryPhoto,
                excludedCatCandidateIdentifiers: excludedCatCandidateIdentifiers,
                excludeFromCatCandidates: { identifiers in
                    Task { await excludeFromCatCandidates(identifiers) }
                },
                restoreCatCandidates: { identifiers in
                    Task { await restoreCatCandidates(identifiers) }
                },
                profiles: catProfilesPresentation.profiles,
                assignmentsByPhotoIdentifier: assignmentsByPhotoIdentifier,
                replaceProfileAssignments: { values in
                    await catProfilesActions.replacePhotoAssignments(values)
                }
            )
            .environment(\.photoRediscoveryScope, scope)
            .onAppear {
                AlbumHighlightRecommendationStore.shared.markOpened(snapshot.id, scopeKey: scope.id, on: Date())
            }
        } else {
            missingAlbumView
        }
    }

    @ViewBuilder
    private func seasonalMovieDestination(
        _ periodID: SeasonalMoviePeriodID
    ) -> some View {
        if let presentation = currentSeasonalMovieRecords.first(where: { $0.periodID == periodID })?.effectivePresentation {
            SeasonalMovieView(
                presentation: presentation,
                setSceneExcluded: { identifier, excluded in
                    let updated = try await seasonalMovieArchive.setSceneExcluded(
                        identifier,
                        excluded: excluded,
                        in: periodID
                    )
                    if seasonalMovie.map({
                        SeasonalMoviePeriodID(presentation: $0)
                    }) == periodID {
                        seasonalMovie = updated
                    }
                    return currentSeasonalMovieRecords.first(where: { $0.periodID == periodID })?.effectivePresentation
                        ?? updated.replacingScenes([])
                },
                freezeRecipe: { reason in
                    try await seasonalMovieArchive.freeze(
                        periodID,
                        reason: reason
                    )
                }
            )
            .id(seasonalMovieArchiveAccessKey)
            .growingSummaryFeature(.monthlySummary(month: nil), hasContent: !presentation.scenes.isEmpty)
        } else {
            ContentUnavailableView(
                "この季節のムービーを開けません",
                systemImage: "film.stack",
                description: Text("元の写真や動画がこのiPhoneにあるか確認してください。")
            )
        }
    }

    private var hasAutomaticAlbumContent: Bool {
        hasPhotoAccess && (currentHouseholdAlbumCatalog?.sections.contains(where: { $0.id != .all }) == true
            || currentMonthlyWindowCollection?.letters.isEmpty == false
            || !currentSeasonalMovieRecords.isEmpty)
    }

    private var automaticAlbumsView: some View {
        AlbumView(
            sections: currentHouseholdAlbumCatalog?.sections ?? [],
            scan: scan,
            profiles: catProfilesPresentation.profiles,
            photoAlbumOptions: catProfilesPresentation.photoAlbumOptions,
            profileActions: catProfilesActions,
            selectedScope: .constant(.everyone),
            showsProfilePicker: false
        )
        .navigationTitle("アルバム")
        .navigationBarTitleDisplayMode(.inline)
        .membershipFeature(.browseAlbums, hasContent: hasAutomaticAlbumContent)
    }

    @ViewBuilder
    private func albumDestination(
        for route: AlbumRoute,
        defaultScope: CatProfileScopePresentation
    ) -> some View {
        switch route {
        case let .album(albumID):
            albumDetail(for: albumID, scope: defaultScope)
        case let .photo(albumID, localIdentifier):
            albumPhotoDetail(for: albumID, localIdentifier: localIdentifier, scope: defaultScope)
        case let .catAlbum(profileIdentifier, albumID):
            albumDetail(for: albumID, scope: .profile(profileIdentifier))
        case let .catPhoto(profileIdentifier, albumID, localIdentifier):
            albumPhotoDetail(for: albumID, localIdentifier: localIdentifier, scope: .profile(profileIdentifier))
        }
    }

    @ViewBuilder
    private func albumDetail(
        for albumID: CuratedAlbumID, scope: CatProfileScopePresentation
    ) -> some View {
        AlbumScopedContent(profiles: catProfilesPresentation.profiles, initialScope: scope) { selectedScope in
            albumDetailContent(
                for: comparisonAlbumID(albumID, scope: selectedScope), scope: selectedScope
            )
            .environment(\.photoRediscoveryScope, selectedScope)
            .membershipFeature(.browseAlbums,
                hasContent: curatedAlbum(for: comparisonAlbumID(albumID, scope: selectedScope), scope: selectedScope)?.photos.isEmpty == false)
        }
    }

    @ViewBuilder
    private func albumDetailContent(
        for albumID: CuratedAlbumID, scope: CatProfileScopePresentation
    ) -> some View {
        if let album = curatedAlbum(for: albumID, scope: scope) {
            if albumID.isGrowthComparison {
                GrowthAlbumDetailView(
                    album: album,
                    sourcePhotos: growthCandidatePhotos(for: albumID, scope: scope),
                    lifeReference: growthLifeReference(for: albumID, scope: scope),
                    setPhotoOverride: { period, photoIdentifier in
                        setGrowthPhotoOverride(photoIdentifier, albumID: albumID,
                                               period: period, scope: scope)
                    },
                    albumOpened: albumOpened,
                    excludeFromCatCandidates: { identifiers in
                        Task { await excludeFromCatCandidates(identifiers) }
                    },
                    profiles: catProfilesPresentation.profiles,
                    assignmentsByPhotoIdentifier: assignmentsByPhotoIdentifier,
                    replaceProfileAssignments: { values in
                        await catProfilesActions.replacePhotoAssignments(values)
                    },
                    profileIdentifier: profileIdentifier(for: scope)
                )
            } else {
                CuratedAlbumDetailView(
                    album: album,
                    albumOpened: albumOpened,
                    excludeFromCatCandidates: { identifiers in
                        Task { await excludeFromCatCandidates(identifiers) }
                    },
                    profiles: catProfilesPresentation.profiles,
                    assignmentsByPhotoIdentifier: assignmentsByPhotoIdentifier,
                    replaceProfileAssignments: { values in
                        await catProfilesActions.replacePhotoAssignments(values)
                    },
                    profileIdentifier: profileIdentifier(for: scope)
                )
            }
        } else {
            ContentUnavailableView {
                Label(albumID.isGrowthComparison ? "比較できる写真がまだありません" : "この範囲の写真はありません",
                      systemImage: albumID.isGrowthComparison ? "rectangle.split.2x1" : "photo.on.rectangle")
            } description: {
                if albumID.isGrowthComparison {
                    Text("違う時期の写真がそろうと表示します。")
                }
            }
            .navigationTitle(albumID.title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("album-scope-empty")
        }
    }

    private func comparisonAlbumID(
        _ albumID: CuratedAlbumID, scope: CatProfileScopePresentation
    ) -> CuratedAlbumID {
        guard albumID.isGrowthComparison else { return albumID }
        return scope == .everyone ? .householdGrowth : .growth
    }

    @ViewBuilder
    private func albumPhotoDetail(
        for albumID: CuratedAlbumID,
        localIdentifier: String,
        scope: CatProfileScopePresentation
    ) -> some View {
        if let album = curatedAlbum(for: albumID, scope: scope),
           let initialPhoto = album.photos.first(where: { $0.localIdentifier == localIdentifier }) {
            PhotoBrowserView(
                photos: album.photos,
                libraryPhotos: browserLibraryPhotos(for: scope),
                initialPhoto: initialPhoto,
                widgetShownAt: nil, showsWidgetTiming: false,
                setMemorySaved: setMemorySaved,
                exportMemoryPhoto: exportMemoryPhoto,
                excludedCatCandidateIdentifiers: excludedCatCandidateIdentifiers,
                excludeFromCatCandidates: { identifiers in
                    Task { await excludeFromCatCandidates(identifiers) }
                },
                restoreCatCandidates: { identifiers in
                    Task { await restoreCatCandidates(identifiers) }
                },
                profiles: catProfilesPresentation.profiles,
                assignmentsByPhotoIdentifier: assignmentsByPhotoIdentifier,
                replaceProfileAssignments: { values in
                    await catProfilesActions.replacePhotoAssignments(values)
                }
            )
            .environment(\.photoRediscoveryScope, scope)
        } else {
            missingAlbumView
        }
    }

    private var albumEligibleCatPhotos: [PhotoPresentation] {
        let assigned = Set(currentPhotoLibraryAssignments.compactMap { $0.value.isEmpty ? nil : $0.key })
        var seen = Set<String>()
        // Explicit cat selection also admits an imported photo before a scan
        // detects a cat. Clearing that selection removes only derived entries.
        guard !savedPhotoStateReadFailed else { return [] }
        let explicitlyAssignedImports = profileAlbumPhotos.values.flatMap { $0 }.filter {
            receivedPhotoIdentifiers.contains($0.localIdentifier)
        }
        return (catPhotos + explicitlyAssignedImports).filter { photo in
            ReceivedPhotoAlbumPolicy.includes(isReceived: receivedPhotoIdentifiers.contains(photo.localIdentifier),
                hasExplicitCat: assigned.contains(photo.localIdentifier))
                && seen.insert(photo.localIdentifier).inserted
        }
    }

    private var householdAlbumCatalogKey: HouseholdAlbumCatalogKey {
        let timeZone = TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sourceAlbumIdentifier: String?
        if case let .selected(album) = photoSourceStatus { sourceAlbumIdentifier = album.localIdentifier }
        else { sourceAlbumIdentifier = nil }
        return HouseholdAlbumCatalogKey(
            access: HouseholdAlbumCatalogAccessKey(
                canBuild: hasPhotoAccess && photoPresentationVersion.canPresent
                    && photoSourceStatus != .unavailable,
                isLimitedAccess: isLimitedAccess,
                analysisFingerprint: photoPresentationVersion.analysisFingerprint,
                curationMutationRevision: photoPresentationVersion.curationMutationRevision,
                identityMutationRevision: photoPresentationVersion.identityMutationRevision,
                sourceResolutionRevision: photoPresentationVersion.sourceResolutionRevision,
                removedPhotoRevision: photoPresentationVersion.removedPhotoRevision,
                sourceAlbumIdentifier: sourceAlbumIdentifier
            ),
            content: HouseholdAlbumCatalogContentKey(
                photoContentRevision: photoPresentationVersion.photoContentRevision,
                photoCount: albumEligibleCatPhotos.count,
                legacyLifeReference: settings.catLifeReference,
                growthPhotoOverridesJSON: growthPhotoOverridesJSON,
                referenceDay: calendar.startOfDay(for: albumHighlightsReferenceDate),
                timeZoneIdentifier: timeZone.identifier
            )
        )
    }

    private var currentHouseholdAlbumCatalog: PreparedHouseholdAlbumCatalog? {
        householdAlbumCatalog.catalog(for: householdAlbumCatalogKey.access)
    }

    @MainActor
    private func submitHouseholdAlbumCatalog() {
        let key = householdAlbumCatalogKey
        householdAlbumCatalog.submit(HouseholdAlbumCatalogRequest(
            key: key,
            input: HouseholdAlbumCatalogInput(
                photos: key.access.canBuild ? albumEligibleCatPhotos : [],
                excludedIdentifiers: key.access.canBuild ? excludedCatCandidateIdentifiers : [],
                lifeReference: catProfilesPresentation.profiles.isEmpty ? settings.catLifeReference : nil,
                growthPhotoOverridesJSON: growthPhotoOverridesJSON,
                referenceDate: albumHighlightsReferenceDate,
                timeZone: .current
            )
        ))
    }

    private func curatedAlbumSections(for scope: CatProfileScopePresentation) -> [CuratedAlbumSectionPresentation] {
        guard hasPhotoAccess, photoPresentationVersion.canPresent else { return [] }
        if case let .profile(identifier) = scope,
           catProfilesPresentation.profile(identifier: identifier) == nil { return [] }
        let scopedPhotos = scopedCatPhotos(for: scope)
        let builder = CuratedAlbumBuilder()
        let includesScopedGrowth: Bool
        if scope == .everyone {
            includesScopedGrowth = false
        } else {
            includesScopedGrowth = catProfilesPresentation
                .timePolicy(for: scope)
                .showsGrowthComparison
        }
        let baseSections = builder.sections(
            from: scopedPhotos,
            lifeReference: scopedLifeReference(for: scope),
            includesGrowth: includesScopedGrowth
        )

        var sections = baseSections
        if scope == .everyone,
           let householdGrowth = HouseholdGrowthAlbumBuilder().album(
               from: scopedPhotos
           ) {
            if let timeIndex = sections.firstIndex(where: { $0.id == .time }) {
                sections[timeIndex] = CuratedAlbumSectionPresentation(
                    id: .time,
                    albums: [householdGrowth] + sections[timeIndex].albums
                )
            } else {
                sections.insert(
                    CuratedAlbumSectionPresentation(
                        id: .time,
                        albums: [householdGrowth]
                    ),
                    at: 0
                )
            }
        }
        return applyingGrowthPhotoOverrides(to: sections, scope: scope)
    }

    private func calendarAlbumSections(
        for scope: CatProfileScopePresentation
    ) -> [CuratedAlbumSectionPresentation] {
        guard hasPhotoAccess, photoPresentationVersion.canPresent else { return [] }
        // Choosing a cat inside a year must keep that calendar year even when
        // the cat has a birthday/adoption date used by its growth comparison.
        return CuratedAlbumBuilder().sections(
            from: scopedCatPhotos(for: scope), lifeReference: nil, includesGrowth: false
        )
    }


    private var monthlyWindowCollectionKey: MonthlyWindowCollectionKey {
        let sourceAlbumIdentifier: String?
        let sourceIsAvailable: Bool
        switch photoSourceStatus {
        case .allLibrary:
            sourceAlbumIdentifier = nil
            sourceIsAvailable = true
        case let .selected(album):
            sourceAlbumIdentifier = album.localIdentifier
            sourceIsAvailable = true
        case .unavailable:
            sourceAlbumIdentifier = nil
            sourceIsAvailable = false
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        let currentMonthStart = calendar.dateInterval(
            of: .month,
            for: Date()
        )?.start
        return MonthlyWindowCollectionKey(
            canBuild: hasPhotoAccess
                && sourceIsAvailable
                && scan.hasFinalResult
                && !isScanning,
            currentMonthStart: currentMonthStart,
            sourceAlbumIdentifier: sourceAlbumIdentifier,
            photoPresentationVersion: photoPresentationVersion
        )
    }

    private var latestMonthlyWindowPeriodIdentifier: String? {
        currentMonthlyWindowCollection?.letters.first?.periodIdentifier
    }

    private var latestMonthlyWindowIsUnread: Bool {
        MonthlyWindowReadReceipt.hasUnread(
            latestPeriodIdentifier: latestMonthlyWindowPeriodIdentifier,
            readPeriodIdentifier: readMonthlyWindowPeriodIdentifier
        )
    }

    private var latestSeasonalMovieIsNew: Bool {
        currentSeasonalMovieRecords.first.map { !$0.isFrozen } ?? false
    }

    private var hasUnreadMemoriesSummary: Bool {
        latestMonthlyWindowIsUnread || latestSeasonalMovieIsNew
    }

    /// The tab's red mark points to something that opens; without Plus the
    /// cards stay visible in the album with a 「Plus」 mark instead (案1).
    private var summaryOpens: Bool {
        membershipAccess.decision(for: .openGrowingSummary) == .allowed
    }

    private func markMonthlyWindowReadIfLatest(
        _ presentation: MonthlyWindowPresentation
    ) {
        readMonthlyWindowPeriodIdentifier = MonthlyWindowReadReceipt
            .readPeriodIdentifier(
                afterOpening: presentation.periodIdentifier,
                latestPeriodIdentifier: latestMonthlyWindowPeriodIdentifier,
                currentReadPeriodIdentifier: readMonthlyWindowPeriodIdentifier
            )
    }

    @MainActor
    private func prepareMonthlyWindowCollection() async {
        let key = monthlyWindowCollectionKey
        guard key.canBuild else {
            if !hasPhotoAccess || photoSourceStatus == .unavailable {
                monthlyWindowCollection = nil
                completedMonthlyWindowCollectionKey = nil
            }
            return
        }
        guard completedMonthlyWindowCollectionKey != key else { return }

        let photos = albumEligibleCatPhotos
        let referenceDate = Date()
        let buildTask = Task.detached(priority: .utility) {
            MonthlyWindowBuilder().buildCompletedCollection(
                from: photos,
                through: referenceDate
            )
        }
        let collection = await withTaskCancellationHandler {
            await buildTask.value
        } onCancel: {
            buildTask.cancel()
        }
        guard !Task.isCancelled, monthlyWindowCollectionKey == key else {
            return
        }
        monthlyWindowCollection = collection
        completedMonthlyWindowCollectionKey = key
    }

    private var seasonalMoviePreparationKey: SeasonalMoviePreparationKey {
        let builder = SeasonalMovieBuilder()
        let interval = builder.completedQuarter(containing: Date())
        let sourceAlbumIdentifier: String?
        let sourceIsAvailable: Bool
        switch photoSourceStatus {
        case .allLibrary:
            sourceAlbumIdentifier = nil
            sourceIsAvailable = true
        case let .selected(album):
            sourceAlbumIdentifier = album.localIdentifier
            sourceIsAvailable = true
        case .unavailable:
            sourceAlbumIdentifier = nil
            sourceIsAvailable = false
        }
        let videoCatalogDigest: Int
        if hasPhotoAccess, sourceIsAvailable, !isScanning, scenePhase == .active, let interval {
            videoCatalogDigest = SeasonalMovieVideoCatalog.digest(
                in: interval,
                sourceAlbumIdentifier: sourceAlbumIdentifier
            )
        } else {
            videoCatalogDigest = 0
        }
        return SeasonalMoviePreparationKey(
            canPrepare: hasPhotoAccess
                && sourceIsAvailable
                && !isScanning
                && scenePhase == .active,
            quarterStart: interval?.start,
            photoPresentationVersion: photoPresentationVersion,
            videoCatalogDigest: videoCatalogDigest,
            sourceAlbumIdentifier: sourceAlbumIdentifier
        )
    }

    @MainActor
    private func prepareSeasonalMovie() async {
        guard hasPhotoAccess else {
            seasonalMovie = nil
            completedSeasonalMoviePreparationKey = nil
            return
        }
        let preparationKey = seasonalMoviePreparationKey
        guard preparationKey.canPrepare else {
            if photoSourceStatus == .unavailable {
                seasonalMovie = nil
                completedSeasonalMoviePreparationKey = nil
            }
            return
        }
        guard completedSeasonalMoviePreparationKey != preparationKey else { return }

        let now = Date()
        let builder = SeasonalMovieBuilder()
        guard let quarter = builder.completedQuarter(containing: now) else {
            seasonalMovie = nil
            return
        }
        let service = SeasonalMovieCandidateService()
        let photoCandidates = await service.photoCandidates(albumEligibleCatPhotos, in: quarter)
        guard !Task.isCancelled else { return }
        var archiveDraft: SeasonalMovieArchiveDraft?
        if case let .ready(photoPresentation) = builder.buildMostRecent(
            from: photoCandidates,
            through: now
        ) {
            archiveDraft = await seasonalMovieArchive.recordDraft(
                photoPresentation
            )
            seasonalMovie = archiveDraft?.presentation
            guard archiveDraft != nil else {
                completedSeasonalMoviePreparationKey = nil
                return
            }
        }

        let videoBatch = await service.videoCandidateBatch(
            in: quarter,
            sourceAlbumIdentifier: preparationKey.sourceAlbumIdentifier
        )
        guard !Task.isCancelled else { return }
        if case let .ready(richerPresentation) = builder.buildMostRecent(
            from: photoCandidates + videoBatch.candidates,
            through: now
        ) {
            if let archiveDraft {
                seasonalMovie = await seasonalMovieArchive.finalizeDraft(
                    richerPresentation,
                    from: archiveDraft
                )
            } else {
                let richerDraft = await seasonalMovieArchive.recordDraft(
                    richerPresentation
                )
                guard let richerDraft else {
                    // A foreground transition changes the preparation task
                    // key, giving temporary protected-file/IO failure one
                    // bounded retry without spinning in this session.
                    completedSeasonalMoviePreparationKey = nil
                    return
                }
                seasonalMovie = await seasonalMovieArchive.finalizeDraft(
                    richerPresentation,
                    from: richerDraft
                )
            }
        } else if archiveDraft == nil {
            seasonalMovie = nil
        }
        // PhotoKit does not expose local byte availability as stable metadata.
        // If a network-disabled request found an unavailable video, leave the
        // key incomplete so the next foreground activation gets one bounded
        // retry. No retry is started in this foreground task.
        completedSeasonalMoviePreparationKey = videoBatch.hadLocallyUnavailableMedia
            ? nil
            : preparationKey
    }

    private var currentMonthlyWindowCollection: MonthlyWindowCollectionPresentation? {
        monthlyWindowCollection?.refreshed(
            from: photoSourceStatus == .unavailable ? [] : albumEligibleCatPhotos,
            hasPhotoAccess: hasPhotoAccess && photoPresentationVersion.canPresent,
            excludedIdentifiers: excludedCatCandidateIdentifiers
        )
    }

    private var seasonalMovieArchiveAccessKey: SeasonalMovieArchiveAccessKey {
        let sourceAlbumIdentifier: String?
        if case let .selected(album) = photoSourceStatus {
            sourceAlbumIdentifier = album.localIdentifier
        } else {
            sourceAlbumIdentifier = nil
        }
        return SeasonalMovieArchiveAccessKey(
            canPresent: hasPhotoAccess && photoPresentationVersion.canPresent
                && photoSourceStatus != .unavailable,
            sourceAlbumIdentifier: sourceAlbumIdentifier,
            sourceResolutionRevision: photoPresentationVersion.sourceResolutionRevision,
            excludedIdentifiers: excludedCatCandidateIdentifiers
        )
    }

    private var seasonalMovieArchiveValidationKey: SeasonalMovieArchiveValidationKey {
        SeasonalMovieArchiveValidationKey(
            access: seasonalMovieArchiveAccessKey,
            isActive: scenePhase == .active,
            videoPeriods: seasonalMovieArchive.records.compactMap { record in
                let identifiers = Set(record.presentation.scenes.filter { $0.mediaKind == .video }.map(\.localIdentifier))
                guard !identifiers.isEmpty else { return nil }
                return SeasonalMovieArchiveVideoPeriod(start: record.presentation.quarterStart,
                    end: record.presentation.quarterEnd, identifiers: identifiers)
            }
        )
    }

    /// Only this transient projection changes with the current source. Frozen
    /// archive recipes remain intact and can reappear when access is restored.
    private var currentSeasonalMovieRecords: [SeasonalMovieArchiveRecord] {
        guard hasPhotoAccess, photoPresentationVersion.canPresent,
              photoSourceStatus != .unavailable else { return [] }
        let currentPhotos = Dictionary(scopedCatPhotos(for: .everyone).map { ($0.localIdentifier, $0) },
                                       uniquingKeysWith: { first, _ in first })
        let videoIdentifiers = validatedSeasonalMovieArchiveKey?.access == seasonalMovieArchiveAccessKey
            ? accessibleSeasonalMovieVideoIdentifiers : []
        return seasonalMovieArchive.records.compactMap { record in
            let scenes = record.effectivePresentation.scenes.filter { scene in
                guard !excludedCatCandidateIdentifiers.contains(scene.localIdentifier) else { return false }
                if scene.mediaKind == .video { return videoIdentifiers.contains(scene.localIdentifier) }
                guard let photo = currentPhotos[scene.localIdentifier], let date = photo.creationDate else { return false }
                return date >= record.presentation.quarterStart && date < record.presentation.quarterEnd
            }
            guard !scenes.isEmpty else { return nil }
            var current = record
            current.presentation = record.presentation.replacingScenes(scenes)
            return current
        }
    }

    @MainActor
    private func resolveSeasonalMovieArchiveVideos() async {
        let key = seasonalMovieArchiveValidationKey
        guard key.access.canPresent else {
            accessibleSeasonalMovieVideoIdentifiers = []
            validatedSeasonalMovieArchiveKey = nil
            return
        }
        guard key.isActive else { return }
        let periods = key.videoPeriods
        let sourceAlbumIdentifier = key.access.sourceAlbumIdentifier
        let resolutionTask = Task.detached(priority: .utility) {
            var identifiers = Set<String>()
            for period in periods {
                guard !Task.isCancelled else { return Set<String>() }
                guard let assets = SeasonalMovieVideoCatalog.fetchAssets(
                        in: DateInterval(start: period.start, end: period.end),
                        sourceAlbumIdentifier: sourceAlbumIdentifier
                      ) else { continue }
                for index in 0..<assets.count {
                    guard !Task.isCancelled else { return Set<String>() }
                    let identifier = assets.object(at: index).localIdentifier
                    if period.identifiers.contains(identifier) { identifiers.insert(identifier) }
                }
            }
            return identifiers
        }
        let identifiers = await withTaskCancellationHandler {
            await resolutionTask.value
        } onCancel: {
            resolutionTask.cancel()
        }
        guard !Task.isCancelled, seasonalMovieArchiveValidationKey == key else { return }
        accessibleSeasonalMovieVideoIdentifiers = identifiers
        validatedSeasonalMovieArchiveKey = key
    }

    private func refreshedMonthlyWindow(
        _ snapshot: MonthlyWindowPresentation
    ) -> MonthlyWindowPresentation {
        snapshot.refreshed(
            from: photoSourceStatus == .unavailable ? [] : albumEligibleCatPhotos,
            hasPhotoAccess: hasPhotoAccess && photoPresentationVersion.canPresent,
            excludedIdentifiers: excludedCatCandidateIdentifiers
        )
    }

    private func profileIdentifier(for scope: CatProfileScopePresentation) -> String? {
        guard case let .profile(identifier) = scope else { return nil }
        return identifier
    }

    private func browserLibraryPhotos(for scope: CatProfileScopePresentation) -> [PhotoPresentation] {
        scopedCatPhotos(for: scope)
    }

    private func scopedCatPhotos(for scope: CatProfileScopePresentation) -> [PhotoPresentation] {
        guard hasPhotoAccess, photoPresentationVersion.canPresent else { return [] }
        let excludedIdentifiers = excludedCatCandidateIdentifiers
        if relatedPhotoUsesLibraryScope, photoLibraryProfileIdentifier != nil {
            guard permitsPhotoLibraryRediscovery,
                  scope == photoLibraryRediscoveryScope else { return [] }
            return albumEligibleCatPhotos.filter {
                photoLibraryIncludes($0.localIdentifier) && !excludedIdentifiers.contains($0.localIdentifier)
            }
        }
        guard case let .profile(identifier) = scope else {
            return albumEligibleCatPhotos.filter { !excludedIdentifiers.contains($0.localIdentifier) }
        }
        guard let profile = catProfilesPresentation.profile(identifier: identifier) else { return [] }
        let assignedIDs = Set(profile.confirmedPhotos.map(\.localIdentifier))
        return (profileAlbumPhotos[identifier] ?? []).filter {
            assignedIDs.contains($0.localIdentifier)
                && !excludedIdentifiers.contains($0.localIdentifier)
                && ReceivedPhotoAlbumPolicy.includes(
                    isReceived: receivedPhotoIdentifiers.contains($0.localIdentifier),
                    hasExplicitCat: !(currentPhotoLibraryAssignments[$0.localIdentifier] ?? []).isEmpty)
        }
    }

    private func scopedLifeReference(for scope: CatProfileScopePresentation) -> CatLifeReference? {
        guard case let .profile(identifier) = scope else {
            // Preserve the legacy single-cat birthday/adoption buckets until a
            // profile exists. Once profiles exist, "すべての猫" must not apply one
            // cat's date to the whole household. Household growth itself is
            // always built separately from calendar years.
            return catProfilesPresentation.profiles.isEmpty
                ? settings.catLifeReference
                : nil
        }
        return lifeReference(for: identifier)
    }

    private func lifeReference(for profileIdentifier: String) -> CatLifeReference? {
        guard let reference = catProfilesPresentation
            .profile(identifier: profileIdentifier)?
            .lifeReference,
              let date = CatLifeDate(date: reference.date) else { return nil }
        return CatLifeReference(
            kind: reference.kind == .birthday ? .birthday : .adoptionDay,
            date: date
        )
    }

    private func growthLifeReference(for albumID: CuratedAlbumID, scope: CatProfileScopePresentation) -> CatLifeReference? {
        switch albumID {
        case .householdGrowth:
            return nil
        case .growth:
            return scopedLifeReference(for: scope)
        case let .profileGrowth(profileIdentifier, _):
            return lifeReference(for: profileIdentifier)
        default:
            return nil
        }
    }

    private func growthCandidatePhotos(for albumID: CuratedAlbumID, scope: CatProfileScopePresentation) -> [PhotoPresentation] {
        switch albumID {
        case .householdGrowth:
            return scopedCatPhotos(for: .everyone).map(\.householdGrowthCandidate)
        case .growth:
            return scopedCatPhotos(for: scope)
        case let .profileGrowth(profileIdentifier, _):
            return scopedCatPhotos(for: .profile(profileIdentifier))
        default:
            return []
        }
    }

    private func growthOverrideNamespace(
        for albumID: CuratedAlbumID, scope: CatProfileScopePresentation
    ) -> String? {
        let selectedProfileIdentifier: String?
        if case let .profile(identifier) = scope {
            selectedProfileIdentifier = identifier
        } else {
            selectedProfileIdentifier = nil
        }
        return albumID.growthOverrideNamespace(
            selectedProfileIdentifier: selectedProfileIdentifier
        )
    }

    private func applyingGrowthPhotoOverrides(
        to sections: [CuratedAlbumSectionPresentation], scope: CatProfileScopePresentation
    ) -> [CuratedAlbumSectionPresentation] {
        let overrideDocument = GrowthAlbumPhotoOverrides.decode(
            growthPhotoOverridesJSON
        )
        let selector = GrowthAlbumSelector()

        return sections.map { section in
            let albums = section.albums.map { album in
                guard album.id.isGrowthComparison,
                      let namespace = growthOverrideNamespace(for: album.id, scope: scope) else {
                    return album
                }

                let sourcePhotos = growthCandidatePhotos(for: album.id, scope: scope)
                let lifeReference = growthLifeReference(for: album.id, scope: scope)
                let groups = selector.candidateGroups(
                    from: sourcePhotos,
                    lifeReference: lifeReference
                )
                var preferredPhotoIdentifiers: [GrowthAlbumPeriod: String] = [:]
                for group in groups {
                    if let identifier = overrideDocument.photoIdentifier(
                        albumNamespace: namespace,
                        period: group.period
                    ) {
                        preferredPhotoIdentifiers[group.period] = identifier
                    }
                }
                let photos = selector.select(
                    from: sourcePhotos,
                    lifeReference: lifeReference,
                    preferredPhotoIdentifiers: preferredPhotoIdentifiers
                ).map(\.photo)
                guard photos.count >= GrowthAlbumVisibilityPolicy.minimumComparablePeriods else {
                    return album
                }
                return CuratedAlbumPresentation(
                    id: album.id,
                    group: album.group,
                    photos: photos
                )
            }
            return CuratedAlbumSectionPresentation(
                id: section.id,
                albums: albums
            )
        }
    }

    private func setGrowthPhotoOverride(
        _ photoIdentifier: String?,
        albumID: CuratedAlbumID,
        period: GrowthAlbumPeriod,
        scope: CatProfileScopePresentation
    ) {
        guard let namespace = growthOverrideNamespace(for: albumID, scope: scope) else {
            return
        }
        var overrideDocument = GrowthAlbumPhotoOverrides.decode(
            growthPhotoOverridesJSON
        )
        overrideDocument.setPhotoIdentifier(
            photoIdentifier,
            albumNamespace: namespace,
            period: period
        )
        growthPhotoOverridesJSON = overrideDocument.encoded()
    }

    private var memoryNotePhotos: [PhotoPresentation] {
        guard hasPhotoAccess, photoPresentationVersion.canPresent else { return [] }
        let excludedIdentifiers = excludedCatCandidateIdentifiers
        // Favorites already have a deliberate, source-independent route.
        // Other records only resolve within the current source library.
        var seen = Set<String>()
        return (libraryPhotos + likedPhotos).filter {
            !excludedIdentifiers.contains($0.localIdentifier)
                && seen.insert($0.localIdentifier).inserted
        }
    }

    private var excludedCatCandidateIdentifiers: Set<String> {
        Set(excludedCatPhotos.map(\.localIdentifier))
    }

    private var assignmentsByPhotoIdentifier: [String: Set<String>] {
        let photos = catProfilesPresentation.unassignedPhotos
            + catProfilesPresentation.profiles.flatMap(\.confirmedPhotos)
        var result: [String: Set<String>] = [:]
        for photo in photos {
            result[photo.localIdentifier, default: []]
                .formUnion(photo.assignedProfileIdentifiers)
        }
        return result
    }

    private func curatedAlbum(
        for id: CuratedAlbumID, scope: CatProfileScopePresentation
    ) -> CuratedAlbumPresentation? {
        let sections: [CuratedAlbumSectionPresentation]
        if case .calendarYear = id {
            sections = calendarAlbumSections(for: scope)
        } else {
            sections = curatedAlbumSections(for: scope)
        }
        return sections
            .lazy
            .flatMap(\.albums)
            .first { $0.id == id }
    }

    private var missingAlbumView: some View {
        ContentUnavailableView(
            "アルバムを更新しています",
            systemImage: "rectangle.stack",
            description: Text("写真を探し終えました。アルバムの一覧に戻って、もう一度開いてください。")
        )
    }

    private func photo(for localIdentifier: String) -> PhotoPresentation {
        if let currentPhoto, currentPhoto.localIdentifier == localIdentifier {
            return currentPhoto
        }
        if let photo = likedPhotos.first(where: { $0.localIdentifier == localIdentifier }) {
            return photo
        }
        if let photo = catPhotos.first(where: { $0.localIdentifier == localIdentifier }) {
            return photo
        }
        if let photo = libraryPhotos.first(where: { $0.localIdentifier == localIdentifier }) {
            return photo
        }
        // A widget can open while the in-memory snapshot is still loading. PhotoKit can still
        // resolve the identifier, and the model will enrich this screen on the next publication.
        return PhotoPresentation(localIdentifier: localIdentifier)
    }

    private var deepLinkSelection: DeepLinkSelection {
        DeepLinkSelection(
            identifier: deepLinkedPhotoIdentifier,
            shownAt: deepLinkedPhotoShownAt
        )
    }

    private func presentDeferredWidgetGuide() {
        guard replaysWidgetGuideAfterSettingsDismiss else { return }
        replaysWidgetGuideAfterSettingsDismiss = false
        showWidgetPlacementGuide()
    }

}

/// Direct Widget destinations are installed without MainTabView.body. Own
/// their related-photo state in the destination's actual view hierarchy.
private struct PhotoRelatedAlbumsHost<Content: View, Sheet: View>: View {
    @State private var route: PhotoRediscoveryRoute?
    let relatedAlbums: PhotoRelatedAlbums
    let sheet: (PhotoRediscoveryRoute) -> Sheet
    let content: (@escaping OpenPhotoRelatedAlbum) -> Content

    init(relatedAlbums: @escaping PhotoRelatedAlbums,
         sheet: @escaping (PhotoRediscoveryRoute) -> Sheet,
         @ViewBuilder content: @escaping (@escaping OpenPhotoRelatedAlbum) -> Content) {
        self.relatedAlbums = relatedAlbums
        self.sheet = sheet
        self.content = content
    }

    var body: some View {
        // Pass this installed state setter to the browser itself, where an
        // inner environment would otherwise replace an ancestor's action.
        content({ route = $0 })
            .environment(\.photoRelatedAlbums, relatedAlbums)
            .environment(\.openPhotoRelatedAlbum, { route = $0 })
            .sheet(item: $route, content: sheet)
    }
}

/// Keep exploration separate from the originating browser's navigation style.
/// The root stays fixed while subsequent related links append to this sheet.
private struct PhotoRelatedAlbumsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()

    let root: PhotoRediscoveryRoute
    let relatedAlbums: PhotoRelatedAlbums
    let albumDestination: (AlbumRoute) -> AnyView
    let relatedDestination: (PhotoRediscoveryRoute) -> AnyView

    var body: some View {
        NavigationStack(path: $path) {
            relatedDestination(root)
                .toolbar { PhotoRelatedCloseToolbar(close: { dismiss() }) }
                .navigationDestination(for: AlbumRoute.self) { route in
                    albumDestination(route)
                        .toolbar { PhotoRelatedCloseToolbar(close: { dismiss() }) }
                }
                .navigationDestination(for: PhotoRediscoveryRoute.self) { route in
                    relatedDestination(route)
                        .toolbar { PhotoRelatedCloseToolbar(close: { dismiss() }) }
                }
        }
        .environment(\.photoRelatedAlbums, relatedAlbums)
        .environment(\.openPhotoRelatedAlbum, { path.append($0) })
        .environment(\.closePhotoRelatedAlbums, { dismiss() })
    }
}

private struct WindowListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model = PairingViewModel()
    @ObservedObject private var invitationInbox = GroupInvitationInbox.shared

    @Binding var opensActiveWindow: Bool
    @Binding var pendingFamilyMomentSourceDigest: String?
    @Binding var pendingFamilyNotificationRoute: MomentNotificationRoute?

    @State private var windows: [PrivateWindowCatalogEntry] = []
    @State private var activeWindowID: String?
    @State private var isLoading = true
    @State private var switchingWindowID: String?
    @State private var catalogLoadMessage: String?
    @State private var pendingPreparationCounts: [String: Int] = [:]
    @State private var pairingPhases: [String: PairingPhase] = [:]
    @State private var catalogReloadRevision = 0
    @State private var requestedSetupPath: PairingSetupPath?
    @State private var publicStates: [String: OfficialWindowState]
    @State private var publicRefreshFailures: [String: UUID] = [:]
    @State private var coverPhotos: [String: PrivateWindowCoverPresentation] = [:]
    @State private var coverClock: Date = .now
    @State private var windowErrors: Set<String> = []

    let supportsPrivateWindows: Bool
    let publicWindows: [PublicWindowPresentationSource]
    let showSettings: (() -> Void)?

    init(opensActiveWindow: Binding<Bool>,
         pendingFamilyMomentSourceDigest: Binding<String?>,
         pendingFamilyNotificationRoute: Binding<MomentNotificationRoute?>,
         // With group windows on, the two-person window is not shown anywhere (10/21).
         supportsPrivateWindows: Bool = SharingAPIConfiguration.current.isReviewVisible
             && GroupWindowClientProvider.ui == nil,
         officialStore: OfficialWindowStore = .shared,
         refreshOfficialFeed: (() async throws -> Void)? = nil,
         previewOfficialFeed: (() async throws -> OfficialWindowPreview)? = nil,
         publicWindows: [PublicWindowPresentationSource]? = nil,
         showSettings: (() -> Void)? = nil) {
        self.showSettings = showSettings
        _opensActiveWindow = opensActiveWindow
        _pendingFamilyMomentSourceDigest = pendingFamilyMomentSourceDigest
        _pendingFamilyNotificationRoute = pendingFamilyNotificationRoute
        self.supportsPrivateWindows = supportsPrivateWindows
        let sources = publicWindows ?? OfficialWindowConfiguration.definitions.map { definition in
            definition.id == officialStore.windowID
                ? PublicWindowPresentationSource(store: officialStore, refresh: refreshOfficialFeed, preview: previewOfficialFeed)
                : PublicWindowPresentationSource(store: .forWindow(definition))
        }
        self.publicWindows = sources
        _publicStates = State(initialValue: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.store.snapshot()) }))
    }

    private var cardColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), alignment: .top),
              count: dynamicTypeSize >= .xxxLarge ? 1 : 2)
    }

    private var receivingPublicWindows: [PublicWindowPresentationSource] {
        publicWindows.filter { publicStates[$0.id]?.isSubscribed == true }
    }

    private func publicCard(_ source: PublicWindowPresentationSource,
                            presentation: OfficialWindowEntryCard.Presentation = .list) -> some View {
        OfficialWindowEntryCard(state: publicStates[source.id], store: source.store,
                                refreshFeed: source.refresh, presentation: presentation,
                                previewFeed: source.preview, relatedWindows: publicWindows,
                                refreshFailed: publicRefreshFailures[source.id] != nil
                                    && publicRefreshFailures[source.id] == publicStates[source.id]?.subscriptionID)
    }

    private func reloadPublicStates() {
        publicStates = Dictionary(uniqueKeysWithValues: publicWindows.map { ($0.id, $0.store.snapshot()) })
    }

    private var discovery: some View {
        PublicWindowDiscoveryView(sources: publicWindows)
    }

    private var connectionOptions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                windowAdditionControl
                if let message = model.operationErrorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("window-add-error")
                }
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("相手とつなぐ")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("window-connection-options")
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 22) {
                if let groupClient = GroupWindowClientProvider.ui {
                    // Windows people share come first (1-4); public windows follow.
                    GroupWindowListSection(client: groupClient)
                    if !receivingPublicWindows.isEmpty {
                        Text("公式のまど")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                if !connectedWindows.isEmpty || !receivingPublicWindows.isEmpty || !setupWindows.isEmpty {
                    LazyVGrid(columns: cardColumns, spacing: 22) {
                        ForEach(connectedWindows) { window in
                            windowCard(window)
                        }
                        ForEach(receivingPublicWindows) { source in publicCard(source) }
                        ForEach(setupWindows) { window in windowCard(window) }
                    }
                    .accessibilityIdentifier("window-list-receiving")
                }
                if isLoading, windows.isEmpty {
                    ProgressView("まどを確認しています…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if windows.isEmpty, let message = availabilityMessage {
                    unavailableWindowContent(message: message)
                } else {
                    if isLoading {
                        ProgressView("まどを更新しています…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let message = availabilityMessage {
                        cachedWindowWarning(message: message)
                    }

                    if GroupWindowClientProvider.ui != nil {
                        publicWindowEntry
                    } else if windows.isEmpty, receivingPublicWindows.isEmpty {
                        emptyWindowCard
                    }

                    if let message = model.operationErrorMessage {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }

                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("まど")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if supportsPrivateWindows {
                    connectionEntry
                    // Without group windows, the public list is reached from here.
                    NavigationLink { discovery } label: {
                        Label("公式のまど", systemImage: "safari")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel("公式のまどを探す")
                    .accessibilityIdentifier("window-list-discover")
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .onAppear { reloadPublicStates() }
        .onReceive(NotificationCenter.default.publisher(for: .officialWindowPresentationDidChange)) { _ in
            reloadPublicStates()
        }
        .navigationDestination(isPresented: Binding(
            get: { supportsPrivateWindows && opensActiveWindow },
            set: { opensActiveWindow = $0 }
        )) {
            activeWindowDestination
                .id(activeWindowID ?? "no-active-window")
        }
        .onChange(of: opensActiveWindow, initial: true) { _, opens in
            // Links that used to open the two-person window only show this tab.
            if opens && !supportsPrivateWindows { opensActiveWindow = false }
        }
        // A group invitation link joins here, in the まど tab itself.
        .sheet(item: Binding(
            get: { GroupWindowClientProvider.ui != nil ? invitationInbox.pending : nil },
            set: { if $0 == nil { invitationInbox.discard() } }
        )) { invitation in
            GroupInvitationJoinSheet(invitation: invitation)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await reload()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .momentSharingPresentationNeedsRefresh
            )
        ) { _ in
            catalogReloadRevision += 1
            coverPhotos = [:]
            Task { await reloadCatalogPresentation() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .momentSharingContentNeedsReload
            )
        ) { _ in
            catalogReloadRevision += 1
            coverPhotos = [:]
            reloadPreparationCounts()
            Task { await reloadCatalogPresentation() }
        }
    }

    private var availabilityMessage: String? {
        model.bootstrapRetryMessage ?? catalogLoadMessage
    }

    private var connectionEntry: some View {
        NavigationLink { connectionOptions } label: {
            Image(systemName: "person.badge.plus")
        }
        .accessibilityLabel("相手とつなぐ")
        .accessibilityIdentifier("window-list-connect")
    }

    private var pausesWindowChanges: Bool {
        isLoading || availabilityMessage != nil
    }

    private func unavailableWindowContent(message: String) -> some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "家族・友だちのまどを確認できません",
                systemImage: "arrow.triangle.2.circlepath",
                description: Text(message)
            )

            Button("もう一度確認する") {
                Task { await reload() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("window-list-retry")
        }
    }

    private func cachedWindowWarning(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "最後に確認できたまどを表示しています",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("更新が終わるまで、まどの切り替えや追加はできません。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("もう一度確認する") {
                Task { await reload() }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("window-list-cached-retry")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }

    /// With group windows on, public windows are a small second entry below them.
    private var publicWindowEntry: some View {
        NavigationLink { discovery } label: {
            HStack(spacing: 12) {
                Image(systemName: "building.2")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(receivingPublicWindows.isEmpty ? "公式のまどを見る" : "ほかの公式のまど")
                        .font(.body.weight(.semibold))
                    Text("猫カフェや保護猫の写真を、見るだけで受け取れます")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(minHeight: 44)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("window-list-start")
    }

    private var emptyWindowCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("まどをはじめる").font(.title2)
                .accessibilityAddTraits(.isHeader)
            if supportsPrivateWindows {
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink { connectionOptions } label: {
                        Label("相手とつなぐ", systemImage: "person.badge.plus")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("window-list-start-private")
                    Text("家族や友だちと写真を届け合います。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                NavigationLink { discovery } label: {
                    Label("公式の写真を受け取る", systemImage: "photo")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("window-list-start")
                Text("まどを選んで写真を見られます。写真の投稿や、相手の招待は必要ありません。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var windowAdditionControl: some View {
        if let pending = setupWindows.first {
            Button { open(pending) } label: {
                Label("\(pending.displayName)の設定を開く", systemImage: "arrow.right.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking || pausesWindowChanges)
            .accessibilityIdentifier("window-list-resume-setup")
        } else if windows.count >= PrivateWindowCatalogState.maximumProductWindowCount {
            Label(
                windows.count > PrivateWindowCatalogState.maximumProductWindowCount
                    ? "現在は新しいまどを追加できません。既存のまどはそのまま使えます"
                    : "まどは、合計\(PrivateWindowCatalogState.maximumProductWindowCount)個までです",
                systemImage: "rectangle.stack"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("window-list-product-limit")
        } else {
            if let groupClient = GroupWindowClientProvider.ui {
                // One place to start a window. New windows are group windows,
                // also for two people; existing two-person windows keep working.
                NavigationLink { GroupWindowCreateScreen(client: groupClient) } label: {
                    Text("まどを作る（\(GroupWindowPresentation.memberLimit)人まで）")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || pausesWindowChanges)
                .accessibilityIdentifier("window-list-create-group")
            } else {
                setupAction("新しいまどを作る", path: .create, identifier: "window-list-create")
            }
            setupAction("招待されたまどに参加", path: .join, identifier: "window-list-join")
            setupAction("以前のまどにこのiPhoneを追加", path: .recover, identifier: "window-list-recover")
        }
        if pausesWindowChanges {
            Text(availabilityMessage ?? "家族・友だちのまどを確認しています…")
                .font(.footnote).foregroundStyle(.secondary)
            if availabilityMessage != nil {
                Button("もう一度確認する") { Task { await reload() } }
                    .frame(minHeight: 44)
            }
        }
    }

    private func setupAction(_ title: String, path: PairingSetupPath, identifier: String) -> some View {
        Button { createAndOpenWindow(setupPath: path) } label: {
            Text(title).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(model.isWorking || pausesWindowChanges)
        .accessibilityIdentifier(identifier)
    }

    private var connectedWindows: [PrivateWindowCatalogEntry] {
        groupedWindows.connectedWindowIDs.compactMap { windowByID($0) }
    }

    private var setupWindows: [PrivateWindowCatalogEntry] {
        groupedWindows.setupWindowIDs.compactMap { windowByID($0) }
    }

    private var groupedWindows: PrivateWindowListPresentation {
        PrivateWindowListPresentationPolicy.make(inputs: windows.map { window in
            PrivateWindowListPresentationInput(
                localWindowID: window.localWindowID,
                createdAt: window.createdAt,
                phase: pairingPhases[window.localWindowID]
            )
        })
    }

    private func windowByID(_ id: String) -> PrivateWindowCatalogEntry? {
        windows.first { $0.localWindowID == id }
    }

    private func createAndOpenWindow(setupPath: PairingSetupPath) {
        guard !model.isWorking, !pausesWindowChanges else { return }
        Task {
            let previousActiveWindowID = activeWindowID
            await model.createAnotherPrivateWindow()
            await reloadCatalogPresentation()
            guard let createdWindowID = activeWindowID,
                  createdWindowID != previousActiveWindowID
            else { return }
            requestedSetupPath = setupPath
            opensActiveWindow = true
        }
    }

    private func windowCard(_ window: PrivateWindowCatalogEntry) -> some View {
        // A state change refreshes both the image and the outer VoiceOver value.
        // TimelineView's scheduled redraw alone can leave the Button's AX value stale.
        let now = max(Date.now, coverClock)
        let deadline = coverPhotos[window.localWindowID]?.photo?.displayUntil
        return windowCard(window, at: now)
            .task(id: deadline) {
                guard let deadline, deadline > now else { return }
                do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
                catch { return }
                guard !Task.isCancelled,
                      coverPhotos[window.localWindowID]?.photo?.displayUntil == deadline else { return }
                coverClock = max(Date.now, deadline)
            }
    }

    private func windowCard(_ window: PrivateWindowCatalogEntry, at now: Date) -> some View {
        let isActive = window.localWindowID == activeWindowID
        let isSwitching = window.localWindowID == switchingWindowID
        let isSetup = groupedWindows.setupWindowIDs.contains(window.localWindowID)

        return Button {
            open(window)
        } label: {
            if isSetup {
                WindowPhotoCard(title: window.displayName, kind: .setup) {
                    VStack(spacing: 18) {
                        Image("ToolCat-tilt").resizable().scaledToFit()
                            .frame(width: 58, height: 58).accessibilityHidden(true)
                        if isSwitching {
                            ProgressView()
                        } else {
                            VStack(spacing: 8) {
                                Text(windowPrimaryStatusLabel(for: window))
                                    .foregroundStyle(windowErrors.contains(window.localWindowID)
                                                     ? Color.orange : Color.primary)
                                Label("設定を開く", systemImage: "chevron.right")
                                    .foregroundStyle(Color.accentColor)
                            }
                                .font(.caption.weight(.medium))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                WindowPhotoCard(title: window.displayName, kind: .shared) {
                    windowCover(for: window, at: now)
                        .overlay(alignment: .topTrailing) {
                            if isSwitching {
                                ProgressView().padding(8).background(.thinMaterial, in: Capsule()).padding(8)
                            } else if windowErrors.contains(window.localWindowID) {
                                Label("開けませんでした", systemImage: "exclamationmark.circle.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.red)
                                    .padding(8).background(.thinMaterial, in: Capsule()).padding(8)
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if let pendingCount = pendingPreparationCounts[window.localWindowID], pendingCount > 0 {
                                Label("\(pendingCount.formatted())枚 準備中", systemImage: "clock")
                                    .font(.caption.weight(.semibold))
                                    .padding(8).background(.thinMaterial, in: Capsule()).padding(8)
                            }
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(
            model.isWorking
                || isLoading
                || (pausesWindowChanges && !isActive)
        )
        .accessibilityIdentifier("window-list-row-\(window.localWindowID)")
        .accessibilityLabel(isSetup ? window.displayName : "\(window.displayName)、相手と送り合うまど")
        .accessibilityValue(windowAccessibilityStatus(for: window, isSetup: isSetup, at: now))
        .accessibilityHint(
            pausesWindowChanges && !isActive
                ? "更新が完了すると、このまどを開けます"
                : "このまどを開きます"
        )
    }

    private func windowCover(for window: PrivateWindowCatalogEntry, at now: Date) -> some View {
        GeometryReader { geometry in
            if let cover = coverPhotos[window.localWindowID]?.photo,
               cover.isVisible(at: now), let image = UIImage(data: cover.jpeg) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            } else {
                VStack(spacing: 12) {
                    Image("ToolCat-hide").resizable().scaledToFit()
                        .frame(width: 58, height: 58)
                    Text(coverPlaceholder(for: window))
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func windowAccessibilityStatus(for window: PrivateWindowCatalogEntry, isSetup: Bool, at now: Date) -> String {
        let visiblePhoto = coverPhotos[window.localWindowID]?.photo.flatMap { cover in
            cover.isVisible(at: now) && UIImage(data: cover.jpeg) != nil ? cover : nil
        }
        var parts = [isSetup ? windowPrimaryStatusLabel(for: window)
                     : visiblePhoto != nil ? "写真あり" : coverPlaceholder(for: window)]
        if !isSetup, let visiblePhoto {
            parts.append(visiblePhoto.origin == .received ? "相手から届いた写真" : "送った写真")
        }
        if windowErrors.contains(window.localWindowID) {
            parts.append(isSetup ? "設定を開いて確認" : "開いて共有の状態を確認")
        }
        if let pendingCount = pendingPreparationCounts[window.localWindowID], pendingCount > 0 {
            parts.append("送信準備中 \(pendingCount.formatted())枚")
        }
        return parts.joined(separator: "、")
    }

    private func coverPlaceholder(for window: PrivateWindowCatalogEntry) -> String {
        guard let status = coverPhotos[window.localWindowID]?.status else {
            return availabilityMessage == nil ? "写真を確認中" : "写真を確認できません"
        }
        switch status {
        case .noPhotos: return "いまは写真がありません"
        case .noRetainedImage: return "写真の控えがありません"
        case .unavailable: return "写真を確認できません"
        case .notConnected: return "接続を確認してください"
        case .photo: return "写真の保存期間が過ぎました"
        }
    }

    private func open(_ window: PrivateWindowCatalogEntry) {
        guard !model.isWorking, !isLoading else { return }
        guard window.localWindowID != activeWindowID else {
            requestedSetupPath = nil
            opensActiveWindow = true
            return
        }
        guard !pausesWindowChanges else { return }

        switchingWindowID = window.localWindowID
        Task {
            await model.activatePrivateWindow(localWindowID: window.localWindowID)
            await reloadCatalogPresentation()
            switchingWindowID = nil
            guard activeWindowID == window.localWindowID else { return }
            requestedSetupPath = nil
            opensActiveWindow = true
        }
    }

    private func reload() async {
        reloadPublicStates()
        for source in receivingPublicWindows {
            Task {
                guard let subscriptionID = source.store.snapshot().subscriptionID else { return }
                do {
                    try await source.refresh()
                    if source.store.snapshot().subscriptionID == subscriptionID {
                        publicRefreshFailures.removeValue(forKey: source.id)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if source.store.snapshot().subscriptionID == subscriptionID {
                        publicRefreshFailures[source.id] = subscriptionID
                    }
                }
                publicStates[source.id] = source.store.snapshot()
            }
        }
#if DEBUG
        if loadMixedFixtureIfNeeded() { return }
#endif
        guard supportsPrivateWindows else {
            isLoading = false
            return
        }
        isLoading = true
        await model.bootstrap()
        // Render the authenticated local catalog immediately. Network name
        // reconciliation is freshness work and must not turn the whole picker
        // into a loading screen when one inactive window is offline.
        await reloadCatalogPresentation()
        isLoading = false
        await model.synchronizeWindowNamesForWindowList()
        await reloadCatalogPresentation()
    }

    private struct CatalogPresentationSnapshot: Sendable {
        let windows: [PrivateWindowCatalogEntry]
        let activeWindowID: String
        let pairingPhases: [String: PairingPhase]
        let coverPhotos: [String: PrivateWindowCoverPresentation]
        let windowErrors: Set<String>
    }

    private func reloadCatalogPresentation() async {
#if DEBUG
        if loadMixedFixtureIfNeeded() { return }
#endif
        guard supportsPrivateWindows else { return }
        catalogReloadRevision += 1
        let revision = catalogReloadRevision
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try Self.loadCatalogPresentationSnapshot()
            }.value
            guard revision == catalogReloadRevision else { return }
            guard let snapshot else {
                windows = []
                activeWindowID = nil
                pendingPreparationCounts = [:]
                pairingPhases = [:]
                catalogLoadMessage = nil
                coverPhotos = [:]
                windowErrors = []
                return
            }
            windows = snapshot.windows
            activeWindowID = snapshot.activeWindowID
            pairingPhases = snapshot.pairingPhases
            coverPhotos = snapshot.coverPhotos
            windowErrors = snapshot.windowErrors
            catalogLoadMessage = nil
            reloadPreparationCounts()
        } catch {
            guard revision == catalogReloadRevision else { return }
            coverPhotos = [:]
            catalogLoadMessage = windows.isEmpty
                ? "保存済みのまどを読み込めませんでした。時間をおいて、もう一度お試しください。"
                : "まどの一覧を更新できませんでした。保存済みの一覧は変更していません。"
        }
    }

#if DEBUG
    /// Only the account read is replaced. The shipping list, controls, grouping,
    /// accessibility and layouts are used by the mixed-state UI regression.
    private func loadMixedFixtureIfNeeded() -> Bool {
        guard CommandLine.arguments.contains("--window-list-ui-fixture") else { return false }
        if CommandLine.arguments.contains("--window-list-empty-private") {
            windows = []; pairingPhases = [:]; coverPhotos = [:]; windowErrors = []
            activeWindowID = nil; isLoading = false
            return true
        }
        guard CommandLine.arguments.contains("--window-list-mixed") else { return false }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let pairedID = "10000000-0000-0000-0000-000000000001"
        let failedID = "10000000-0000-0000-0000-000000000002"
        windows = [
            .init(localWindowID: pairedID, displayName: "マイファミリー", spaceID: "fixture-space",
                  credentialAccount: nil, createdAt: date, updatedAt: date),
            .init(localWindowID: failedID, displayName: "ねことも", spaceID: nil,
                  credentialAccount: nil, createdAt: date.addingTimeInterval(1), updatedAt: date.addingTimeInterval(1))
        ]
        activeWindowID = failedID
        pairingPhases = [pairedID: .paired, failedID: .failed]
        windowErrors = [failedID]
        if let jpeg = MomentExperiencePhotoFixture.image(index: 1).jpegData(compressionQuality: 0.8) {
            coverPhotos = [pairedID: .init(photo: .init(jpeg: jpeg, displayUntil: Date().addingTimeInterval(CommandLine.arguments.contains("--window-list-expiring-cover") ? 5 : 3600), origin: .sent), status: .photo)]
        }
        isLoading = false
        return true
    }
#endif

    private nonisolated static func loadCatalogPresentationSnapshot() throws
        -> CatalogPresentationSnapshot? {
        guard let catalog = try PrivateWindowCatalogStore.load() else {
            return nil
        }
        let phasePairs: [(String, PairingPhase)] = catalog.windows.compactMap { window in
            guard let state = try? PairingStateStore.load(
                localWindowID: window.localWindowID
            ) else { return nil }
            return (window.localWindowID, state.phase)
        }
        return CatalogPresentationSnapshot(
            windows: catalog.windows.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.localWindowID < $1.localWindowID
            },
            activeWindowID: catalog.activeWindowID,
            pairingPhases: Dictionary(uniqueKeysWithValues: phasePairs),
            coverPhotos: Dictionary(uniqueKeysWithValues: catalog.windows.map { window in
                (window.localWindowID, PrivateWindowCoverPhotoService.load(for: window))
            }),
            windowErrors: Set(catalog.windows.compactMap { window in
                guard let state = try? PairingStateStore.load(localWindowID: window.localWindowID),
                      state.lastError != nil else { return nil }
                return window.localWindowID
            })
        )
    }

    private func windowConnectionLabel(
        for window: PrivateWindowCatalogEntry
    ) -> String {
        guard let phase = pairingPhases[window.localWindowID] else {
            return window.spaceID == nil ? "設定を続ける" : "接続状態を確認中"
        }
        switch phase {
        case .unpaired:
            return "設定を続ける"
        case .creatingInvitation:
            return "招待を準備中"
        case .awaitingInvitee:
            return "相手の参加待ち"
        case .joining:
            return "招待を確認中"
        case .claimingRecovery:
            return "このiPhoneを追加中"
        case .pendingRecoveryApproval:
            return "iPhone追加の承認待ち"
        case .recoveryAwaitingCompletion:
            return "iPhone追加の完了待ち"
        case .pendingApproval:
            return "相手の承認待ち"
        case .approvalRequired:
            return "相手の確認が必要"
        case .awaitingCompletion:
            return "接続の完了待ち"
        case .paired:
            return "相手と送り合う"
        case .failed:
            return "設定を完了できませんでした"
        }
    }

    private func windowPrimaryStatusLabel(
        for window: PrivateWindowCatalogEntry
    ) -> String {
        pairingPhases[window.localWindowID] == .unpaired
            ? "設定を続ける"
            : windowConnectionLabel(for: window)
    }

    private func reloadPreparationCounts() {
        guard SharingAPIConfiguration.current.isShareExtensionHandoffAvailable else {
            pendingPreparationCounts = [:]
            return
        }
        do {
            let admissions = try MomentShareHandoffStore.activeAdmissions()
            let snapshot = try MomentShareHandoffStore.presentationSnapshot()
            let onlyWindowID = windows.count == 1 ? windows[0].localWindowID : nil
            var windowIDByDestinationKey: [String: String] = [:]
            for admission in admissions {
                guard let localWindowID = admission.localWindowID ?? onlyWindowID else {
                    continue
                }
                windowIDByDestinationKey[admission.id.uuidString.lowercased()] = localWindowID
            }

            var nextCounts: [String: Int] = [:]
            for status in snapshot.statuses {
                guard let localWindowID = windowIDByDestinationKey[status.destinationKey]
                else { continue }
                nextCounts[localWindowID, default: 0] += 1
            }
            pendingPreparationCounts = nextCounts
        } catch {
            // Presentation-only failure is not evidence that a queued photo
            // disappeared. Keep the last verified per-window counts.
        }
    }

    @ViewBuilder
    private var activeWindowDestination: some View {
#if DEBUG
        if CommandLine.arguments.contains("--window-list-ui-fixture"),
           CommandLine.arguments.contains("--window-list-mixed") {
            PairingView(fixtureModel: PairingViewModel.failedSetupFixture())
        } else {
            productionWindowDestination
        }
#else
        productionWindowDestination
#endif
    }

    @ViewBuilder
    private var productionWindowDestination: some View {
        if SharingAPIConfiguration.current.isMediaAvailable {
            FamilyWindowView(
                initialSetupPath: requestedSetupPath,
                pendingMemorySourceDigest: $pendingFamilyMomentSourceDigest,
                pendingNotificationRoute: $pendingFamilyNotificationRoute
            )
        } else if SharingAPIConfiguration.current.isAvailable {
            PairingView(initialSetupPath: requestedSetupPath)
        } else if SharingAPIConfiguration.current.isReviewPreviewEnabled {
            SharingReviewPreviewView()
        } else {
            EmptyView()
        }
    }
}

private struct SubtleWindowThumbnail: View {
    let showsSetupMark: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.035))

            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.72), lineWidth: 1.5)

            Rectangle()
                .fill(Color.accentColor.opacity(0.42))
                .frame(width: 1)
                .padding(.vertical, 3)

            Rectangle()
                .fill(Color.accentColor.opacity(0.42))
                .frame(height: 1)
                .padding(.horizontal, 3)

            if showsSetupMark {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.accentColor, Color(.secondarySystemBackground))
                    .offset(x: 14, y: 14)
            }
        }
        .frame(width: 38, height: 38)
    }
}

#if DEBUG
/// The shipping list and navigation with an isolated public store. Private
/// account bootstrap and the real public network are not used by this fixture.
struct WindowListNavigationFixture: View {
    @StateObject private var model = OfficialWindowFixtureModel()
    @StateObject private var secondModel = OfficialWindowFixtureModel(definition: PublicWindowDefinition(
        id: "nap-cats", displayName: "おひるね", subtitle: "お昼寝中の猫の写真",
        endpoint: URL(string: "https://official.invalid/windows/nap-cats/catalog.json")))
    @StateObject private var catModel = OfficialWindowFixtureModel(definition: PublicWindowDefinition(
        id: "cat-tabby-nap", displayName: "キジ白のまど", subtitle: "この猫の写真",
        endpoint: URL(string: "https://official.invalid/windows/cat-tabby-nap/catalog.json"),
        catID: "generated-tabby-nap"), initiallySubscribed: false)
    @State private var selectedTab = 2
    @State private var opensActiveWindow = false

    private var sources: [PublicWindowPresentationSource] {
        var result = [PublicWindowPresentationSource(store: model.store,
                        refresh: { try await model.refresh() }, preview: { try await model.preview() })]
        if CommandLine.arguments.contains("--window-list-two-public") {
            result.append(PublicWindowPresentationSource(store: secondModel.store,
                            refresh: { try await secondModel.refresh() }, preview: { try await secondModel.preview() }))
        }
        if CommandLine.arguments.contains("--window-list-cat-window") {
            result.append(PublicWindowPresentationSource(store: catModel.store,
                            refresh: { try await catModel.refresh() }, preview: { try await catModel.preview() }))
        }
        return result
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Text("写真").tabItem { Label("写真", systemImage: "photo") }.tag(0)
            Text("アルバム").tabItem { Label("アルバム", systemImage: "photo.stack") }.tag(1)
            NavigationStack {
                WindowListView(opensActiveWindow: $opensActiveWindow,
                               pendingFamilyMomentSourceDigest: .constant(nil),
                               pendingFamilyNotificationRoute: .constant(nil),
                               supportsPrivateWindows: CommandLine.arguments.contains("--window-list-mixed") || CommandLine.arguments.contains("--window-list-empty-private"),
                               officialStore: model.store,
                               refreshOfficialFeed: { try await model.refresh() },
                               previewOfficialFeed: { try await model.preview() },
                               publicWindows: sources)
                    .frame(maxWidth: CommandLine.arguments.contains("--window-list-narrow") ? 320 : .infinity)
            }
            .tabItem { Label("まど", systemImage: "window.vertical.closed") }.tag(2)
        }
        .environment(\.dynamicTypeSize,
                     CommandLine.arguments.contains("--window-list-largest-text") ? .accessibility5 :
                     CommandLine.arguments.contains("--window-list-large-text") ? .accessibility3 : .large)
        .preferredColorScheme(CommandLine.arguments.contains("--window-list-dark") ? .dark :
                              CommandLine.arguments.contains("--window-list-light") ? .light : nil)
    }
}
#endif

private struct DeepLinkSelection: Equatable {
    let identifier: String?
    let shownAt: Date?
}

/// A monthly summary or seasonal movie that needs Plus is replaced by the one
/// Plus screen for that month (ADR-027 5章). Album lists stay free and never
/// use this gate; an unknown purchase state shows the restore-only notice.
private struct GrowingSummaryGate: ViewModifier {
    @Environment(\.membershipAccess) private var access
    let context: PlusOfferContext
    let hasContent: Bool

    func body(content: Content) -> some View {
        let decision = access.decision(for: .openGrowingSummary)
        if !hasContent || decision == .allowed {
            content
        } else {
            PlusOfferPrompt(context: context, decision: decision)
        }
    }
}

private extension View {
    func growingSummaryFeature(_ context: PlusOfferContext, hasContent: Bool) -> some View {
        modifier(GrowingSummaryGate(context: context, hasContent: hasContent))
    }
}
