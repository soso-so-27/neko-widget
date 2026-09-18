import SwiftUI
import UIKit
import ImageIO
import Photos

enum PhotosRoute: Hashable {
    case photo(String)
    case collectionPhoto(String)
    case automaticAlbums
    case unavailableWidgetPhoto
}

enum MemoriesRoute: Hashable {
    case favorites
    case memoryNotes
    case memoryNote(UUID)
    case memoryNotePhoto(UUID)
    case reflectionsArchive
    case highlightsArchive
    case highlight(AlbumHighlightPresentation)
    case photo(String)
    case seasonalMovie(SeasonalMoviePeriodID)
    case monthlyWindow(MonthlyWindowPresentation)
    case catAlbums(String)
    case catHighlightsArchive(String)
    case catHighlight(String, AlbumHighlightPresentation)
}

private struct SeasonalMoviePreparationKey: Hashable {
    let canPrepare: Bool
    let quarterStart: Date?
    let photoDigest: Int
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

    let currentPhoto: PhotoPresentation?
    let likedPhotos: [PhotoPresentation]
    let catPhotos: [PhotoPresentation]
    let libraryPhotos: [PhotoPresentation]
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

    @State private var selectedTab: AppTab = .memories
    @State private var photosPath = NavigationPath()
    @State private var memoriesPath = NavigationPath()
    @State private var showsSettings = false
    @State private var replaysWidgetGuideAfterSettingsDismiss = false
    @State private var widgetOpenedPhotoIdentifier: String?
    @State private var widgetShownAt: Date?
    @State private var albumHighlightsReferenceDate = Date()
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

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $memoriesPath) {
                albumsView()
                    .navigationDestination(for: AlbumRoute.self) { route in
                        albumDestination(for: route, defaultScope: .everyone)
                    }
                    .navigationDestination(for: AlbumCatalogRoute.self, destination: albumCatalogDestination)
                    .navigationDestination(for: PhotoRediscoveryRoute.self, destination: photoRediscoveryDestination)
                    .navigationDestination(
                        for: MemoriesRoute.self,
                        destination: memoriesDestination
                    )
            }
            .environment(\.photoRelatedAlbums, relatedAlbums)
            .tabItem {
                Label("アルバム", systemImage: "photo.stack.fill")
                    .accessibilityIdentifier("main-tab-memories")
            }
            .badge(hasUnreadMemoriesSummary ? 1 : 0)
            .tag(AppTab.memories)

            NavigationStack(path: $photosPath) {
                HomeView(
                    scan: scan,
                    hasPhotoAccess: hasPhotoAccess,
                    isLimitedAccess: isLimitedAccess,
                    shouldOfferWidgetPlacementGuide: shouldOfferWidgetPlacementGuide,
                    requestPhotoAccess: requestPhotoAccess,
                    chooseMorePhotos: chooseMorePhotos,
                    showWidgetPlacementGuide: showWidgetPlacementGuide,
                    showSettings: { showsSettings = true },
                    rescan: { Task { await rescan() } },
                    catPhotos: catPhotos,
                    excludedCatPhotos: excludedCatPhotos,
                    photoSourceAlbums: photoSourceAlbums,
                    photoSourceStatus: photoSourceStatus,
                    restoreCatCandidates: restoreCatCandidates,
                    selectPhotoSourceAlbum: selectPhotoSourceAlbum,
                    refreshPhotoSourceAlbums: refreshPhotoSourceAlbums,
                    catProfilesPresentation: catProfilesPresentation,
                    catProfilesActions: catProfilesActions
                )
                .navigationDestination(for: PhotosRoute.self, destination: photosDestination)
                .navigationDestination(for: AlbumRoute.self) { route in
                    albumDestination(for: route, defaultScope: .everyone)
                }
                .navigationDestination(for: AlbumCatalogRoute.self, destination: albumCatalogDestination)
                .navigationDestination(for: PhotoRediscoveryRoute.self, destination: photoRediscoveryDestination)
            }
            .environment(\.photoRelatedAlbums, relatedAlbums)
            .environment(\.catProfilePhotoDestination, { profileID, photoID in
                AnyView(albumPhotoDetail(for: .allCatPhotos,
                    localIdentifier: photoID, scope: .profile(profileID)))
            })
            .tabItem {
                Label("写真", systemImage: "photo.on.rectangle.angled")
                    .accessibilityIdentifier("main-tab-photos")
            }
            .tag(AppTab.photos)

            if SharingAPIConfiguration.current.isReviewVisible || OfficialWindowConfiguration.definitions.contains(where: { $0.endpoint != nil }) {
                NavigationStack {
                    WindowListView(
                        opensActiveWindow: $deepLinkedFamilyWindowIsPresented,
                        pendingFamilyMomentSourceDigest: $deepLinkedFamilyMomentSourceDigest,
                        pendingFamilyNotificationRoute: $pendingFamilyNotificationRoute,
                        showSettings: { showsSettings = true }
                    )
                }
                .tabItem {
                    Label("まど", systemImage: "rectangle.split.2x2")
                        .accessibilityIdentifier("main-tab-windows")
                }
                .tag(AppTab.windows)
            }
        }
        .sheet(isPresented: $showsSettings, onDismiss: presentDeferredWidgetGuide) {
            settingsSheet
        }
        .onChange(of: deepLinkSelection, initial: true) { _, selection in
            guard let identifier = selection.identifier else { return }
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
            photosPath = NavigationPath()
            photosPath.append(PhotosRoute.photo(identifier))
            deepLinkedPhotoIdentifier = nil
            deepLinkedPhotoShownAt = nil
        }
        .onChange(of: deepLinkedFamilyWindowIsPresented, initial: true) { _, isPresented in
            guard isPresented else { return }
            showsSettings = false
            selectedTab = .windows
        }
        .onChange(of: pendingFamilyNotificationRoute, initial: true) { _, route in
            guard route != nil else { return }
            showsSettings = false
            selectedTab = .windows
            deepLinkedFamilyWindowIsPresented = true
        }
        .onChange(of: photosPath) { _, path in
            guard path.isEmpty else { return }
            widgetOpenedPhotoIdentifier = nil
            widgetShownAt = nil
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
    }

    private var settingsSheet: some View {
        NavigationStack {
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
                }
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showsSettings = false
                    } label: {
                        Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("閉じる")
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func photosDestination(for route: PhotosRoute) -> some View {
        switch route {
        case let .photo(localIdentifier):
            detailView(for: localIdentifier)
        case let .collectionPhoto(localIdentifier):
            collectionDetailView(for: localIdentifier)
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
                    openedFromWidget: widgetOpenedPhotoIdentifier == localIdentifier)
    }

    @ViewBuilder
    func widgetPhotoDestination(for localIdentifier: String, shownAt: Date?) -> some View {
        if hasPhotoAccess,
           catPhotos.contains(where: { $0.localIdentifier == localIdentifier }),
           !excludedCatCandidateIdentifiers.contains(localIdentifier) {
            photoDetail(for: localIdentifier, shownAt: shownAt, openedFromWidget: true)
        } else {
            ContentUnavailableView("この写真は開けません", systemImage: "photo",
                                   description: Text("現在、表示する写真の範囲から外れているか、写真にアクセスできません。"))
                .accessibilityIdentifier("unavailable-widget-photo")
        }
    }

    private func photoDetail(for localIdentifier: String, shownAt: Date?,
                             openedFromWidget: Bool) -> some View {
        let initialPhoto = photo(for: localIdentifier)
        return PhotoBrowserView(
            // A proposed photo and a Widget tap are one-photo entry points.
            // The grid uses a separate route whose browser can page through
            // the detected cat-photo collection.
            photos: [initialPhoto],
            libraryPhotos: libraryPhotos,
            initialPhoto: initialPhoto,
            widgetShownAt: shownAt,
            showsWidgetTiming: openedFromWidget,
            setMemorySaved: setMemorySaved,
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
    }

    /// Related albums use today's permission/source/explicit-assignment state,
    /// never a Widget snapshot or inferred identity. A link must lead beyond
    /// the current photo to be useful.
    private func relatedAlbums(
        for localIdentifier: String, scope: CatProfileScopePresentation
    ) -> [PhotoRelatedAlbumLink] {
        guard hasPhotoAccess, photoPresentationVersion.canPresent,
              photoSourceStatus != .unavailable else { return [] }
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
                    exportMemoryPhoto: context.allowsPhotoExport ? exportMemoryPhoto : nil,
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
        PhotoBrowserView(
            photos: catPhotos,
            libraryPhotos: libraryPhotos,
            initialPhoto: photo(for: localIdentifier),
            widgetShownAt: nil,
            showsWidgetTiming: false,
            setMemorySaved: setMemorySaved,
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
    }

    @ViewBuilder
    private func memoryDetailView(for localIdentifier: String) -> some View {
        PhotoBrowserView(
            photos: likedPhotos,
            libraryPhotos: libraryPhotos,
            initialPhoto: photo(for: localIdentifier),
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
    }

    private func albumsView(
        scope: CatProfileScopePresentation = .everyone,
        showsReflectionArchive: Bool = false,
        showsHighlightArchive: Bool = false
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
            monthlyWindowCollection: scope == .everyone ? currentMonthlyWindowCollection : nil,
            latestMonthlyWindowIsUnread: scope == .everyone && latestMonthlyWindowIsUnread,
            latestSeasonalMovieIsNew: scope == .everyone && latestSeasonalMovieIsNew,
            seasonalMovies: scope == .everyone ? currentSeasonalMovieRecords : [],
            exportPhotoBook: exportPhotoBook,
            openPhotos: {
                photosPath = NavigationPath()
                selectedTab = .photos
            },
            albumSections: curatedAlbumSections(for: scope),
            albumScan: scan,
            albumProfiles: catProfilesPresentation.profiles,
            albumOptions: catProfilesPresentation.photoAlbumOptions,
            albumProfileActions: catProfilesActions,
            albumScope: .constant(scope),
            showSettings: { showsSettings = true },
            showsReflectionArchive: showsReflectionArchive,
            showsHighlightArchive: showsHighlightArchive,
            referenceDate: albumHighlightsReferenceDate,
            isCatDetail: scope != .everyone,
            navigationTitleOverride: profile.map { "\($0.displayName)のアルバム" }
        )
    }

    @ViewBuilder
    private func albumCatalogDestination(for route: AlbumCatalogRoute) -> some View {
        switch route {
        case .months:
            albumsView().periodArchive(showsMovies: false)
        case .movies:
            albumsView().periodArchive(showsMovies: true)
        case .cats:
            albumsView().catArchive
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
        }
    }

    @ViewBuilder
    private func memoriesDestination(for route: MemoriesRoute) -> some View {
        switch route {
        case .memoryNotes:
            PhotoMemoryNotesListView(photos: memoryNotePhotos) {
                photosPath = NavigationPath()
                selectedTab = .photos
            }
        case let .memoryNote(identifier):
            PhotoMemoryNoteDetailView(recordID: identifier, photos: memoryNotePhotos)
        case let .memoryNotePhoto(identifier):
            PhotoMemoryNotePhotoDestination(recordID: identifier, photos: memoryNotePhotos) { photo in
                photoDetail(for: photo.localIdentifier, shownAt: nil, openedFromWidget: false)
            }
        case .favorites:
            SavedMemoriesGalleryView(
                photos: likedPhotos, startsInExportMode: false,
                exportPhotoBook: exportPhotoBook
            )
        case .reflectionsArchive:
            albumsView(showsReflectionArchive: true)
        case .highlightsArchive:
            albumsView(showsHighlightArchive: true)
        case let .catAlbums(identifier):
            catAlbumsDestination(identifier, showsHighlightArchive: false)
        case let .catHighlightsArchive(identifier):
            catAlbumsDestination(identifier, showsHighlightArchive: true)
        case let .catHighlight(identifier, snapshot):
            highlightDestination(snapshot, scope: .profile(identifier))
        case let .highlight(snapshot):
            highlightDestination(snapshot)
        case let .photo(localIdentifier):
            memoryDetailView(for: localIdentifier)
        case let .seasonalMovie(periodID):
            seasonalMovieDestination(periodID)
        case let .monthlyWindow(snapshot):
            MonthlyWindowView(
                presentation: refreshedMonthlyWindow(snapshot),
                setMemorySaved: setMemorySaved,
                libraryPhotos: libraryPhotos,
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
        } else {
            ContentUnavailableView(
                "この季節のムービーを開けません",
                systemImage: "film.stack",
                description: Text("元の写真や動画がこのiPhoneにあるか確認してください。")
            )
        }
    }

    private var automaticAlbumsView: some View {
        AlbumView(
            sections: curatedAlbumSections(for: .everyone),
            scan: scan,
            profiles: catProfilesPresentation.profiles,
            photoAlbumOptions: catProfilesPresentation.photoAlbumOptions,
            profileActions: catProfilesActions,
            selectedScope: .constant(.everyone),
            showsProfilePicker: false
        )
        .navigationTitle("アルバム")
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

    private func curatedAlbumSections(for scope: CatProfileScopePresentation) -> [CuratedAlbumSectionPresentation] {
        guard hasPhotoAccess, photoPresentationVersion.canPresent else { return [] }
        if case let .profile(identifier) = scope,
           catProfilesPresentation.profile(identifier: identifier) == nil { return [] }
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
            from: scopedCatPhotos(for: scope),
            lifeReference: scopedLifeReference(for: scope),
            includesGrowth: includesScopedGrowth
        )

        var sections = baseSections
        if scope == .everyone,
           let householdGrowth = HouseholdGrowthAlbumBuilder().album(
               from: catPhotos.filter { !excludedCatCandidateIdentifiers.contains($0.localIdentifier) }
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

        let photos = catPhotos
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
        var hasher = Hasher()
        if let interval {
            for photo in catPhotos
                .filter({ photo in
                    guard let date = photo.creationDate else { return false }
                    return date >= interval.start && date < interval.end
                })
                .sorted(by: { $0.localIdentifier < $1.localIdentifier }) {
                hasher.combine(photo.localIdentifier)
                hasher.combine(photo.creationDate)
                hasher.combine(photo.catBoundingBox)
                hasher.combine(photo.largestCatAreaRatio)
                hasher.combine(photo.isLiked)
                hasher.combine(photo.isPhotoLibraryFavorite)
            }
        }
        let videoCatalogDigest: Int
        if hasPhotoAccess, sourceIsAvailable, let interval {
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
            photoDigest: hasher.finalize(),
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
        let photoCandidates = await service.photoCandidates(catPhotos, in: quarter)
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
            from: photoSourceStatus == .unavailable ? [] : catPhotos,
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
            from: photoSourceStatus == .unavailable ? [] : catPhotos,
            hasPhotoAccess: hasPhotoAccess && photoPresentationVersion.canPresent,
            excludedIdentifiers: excludedCatCandidateIdentifiers
        )
    }

    private func profileIdentifier(for scope: CatProfileScopePresentation) -> String? {
        guard case let .profile(identifier) = scope else { return nil }
        return identifier
    }

    private func browserLibraryPhotos(for scope: CatProfileScopePresentation) -> [PhotoPresentation] {
        scope == .everyone ? libraryPhotos : scopedCatPhotos(for: scope)
    }

    private func scopedCatPhotos(for scope: CatProfileScopePresentation) -> [PhotoPresentation] {
        guard hasPhotoAccess, photoPresentationVersion.canPresent else { return [] }
        guard case let .profile(identifier) = scope else {
            return catPhotos.filter { !excludedCatCandidateIdentifiers.contains($0.localIdentifier) }
        }
        guard let profile = catProfilesPresentation.profile(identifier: identifier) else { return [] }
        let assignedIDs = Set(profile.confirmedPhotos.map(\.localIdentifier))
        return (profileAlbumPhotos[identifier] ?? []).filter {
            assignedIDs.contains($0.localIdentifier)
                && !excludedCatCandidateIdentifiers.contains($0.localIdentifier)
        }
    }

    private func scopedLifeReference(for scope: CatProfileScopePresentation) -> CatLifeReference? {
        guard case let .profile(identifier) = scope else {
            // Preserve the legacy single-cat birthday/adoption buckets until a
            // profile exists. Once profiles exist, "みんな" must not apply one
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
        // Favorites already have a deliberate, source-independent route.
        // Other records only resolve within the current source library.
        var seen = Set<String>()
        return (libraryPhotos + likedPhotos).filter {
            !excludedCatCandidateIdentifiers.contains($0.localIdentifier)
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
            description: Text("スキャン結果が更新されました。アルバムの一覧へ戻って、もう一度開いてください。")
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

private struct WindowListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model = PairingViewModel()

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
    @State private var coverPhotos: [String: PrivateWindowCoverPresentation] = [:]
    @State private var windowErrors: Set<String> = []

    let supportsPrivateWindows: Bool
    let publicWindows: [PublicWindowPresentationSource]
    let showSettings: (() -> Void)?

    init(opensActiveWindow: Binding<Bool>,
         pendingFamilyMomentSourceDigest: Binding<String?>,
         pendingFamilyNotificationRoute: Binding<MomentNotificationRoute?>,
         supportsPrivateWindows: Bool = SharingAPIConfiguration.current.isReviewVisible,
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
                                previewFeed: source.preview, relatedWindows: publicWindows)
    }

    private func reloadPublicStates() {
        publicStates = Dictionary(uniqueKeysWithValues: publicWindows.map { ($0.id, $0.store.snapshot()) })
    }

    private var discovery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(publicWindows) { source in
                    publicCard(source, presentation: .discovery)
                }
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("まどを探す")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("window-discovery")
    }

    private var connectionOptions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                windowAdditionControl
                if let message = model.operationErrorMessage {
                    Text(message).font(.footnote).foregroundStyle(.orange)
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
                if !connectedWindows.isEmpty || !receivingPublicWindows.isEmpty {
                    LazyVGrid(columns: cardColumns, spacing: 14) {
                        ForEach(connectedWindows) { window in
                            windowCard(window)
                        }
                        ForEach(receivingPublicWindows) { source in publicCard(source) }
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

                    if windows.isEmpty, receivingPublicWindows.isEmpty {
                        emptyWindowCard
                    } else {
                        if !setupWindows.isEmpty {
                            VStack(spacing: 8) {
                                ForEach(setupWindows) { window in
                                    windowCard(window)
                                }
                            }
                        }
                    }

                    if let message = model.operationErrorMessage {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }

                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("まど")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let showSettings {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: showSettings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("設定")
                        .accessibilityIdentifier("windows-settings-button")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if supportsPrivateWindows {
                    connectionEntry
                }
                NavigationLink { discovery } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("まどを探す")
                .accessibilityIdentifier("window-list-discover")
            }
        }
        .background(Color(.systemGroupedBackground))
        .onAppear { reloadPublicStates() }
        .onReceive(NotificationCenter.default.publisher(for: .officialWindowPresentationDidChange)) { _ in
            reloadPublicStates()
        }
        .navigationDestination(isPresented: $opensActiveWindow) {
            activeWindowDestination
                .id(activeWindowID ?? "no-active-window")
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

    @ViewBuilder
    private var connectionEntry: some View {
        if setupWindows.count == 1, let pending = setupWindows.first {
            Button { open(pending) } label: {
                Image(systemName: "person.badge.plus")
            }
            .disabled(model.isWorking || pausesWindowChanges || switchingWindowID != nil)
            .accessibilityLabel("\(pending.displayName)の設定を続ける")
            .accessibilityIdentifier("window-list-connect")
        } else {
            NavigationLink { connectionOptions } label: {
                Image(systemName: "person.badge.plus")
            }
            .accessibilityLabel("相手とつなぐ")
            .accessibilityIdentifier("window-list-connect")
        }
    }

    private var pausesWindowChanges: Bool {
        isLoading || availabilityMessage != nil
    }

    private func unavailableWindowContent(message: String) -> some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "身近な人とのまどを確認できません",
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

            Text("更新が完了するまで、身近な人とのまどの切り替えや追加は行いません。")
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

    private var emptyWindowCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("暮らしの中に、猫の一枚を。", systemImage: "pawprint.fill")
                .font(.title2)

            Text("公開まどから写真を受け取れます。写真の投稿や、友だちの招待は必要ありません。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            NavigationLink { discovery } label: { Text("まどを探す") }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("window-list-start")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 20)
        )
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
                    : "身近な人とのまどは、合計3個までです",
                systemImage: "rectangle.stack"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("window-list-product-limit")
        } else {
            setupAction("新しいまどを作る", path: .create, identifier: "window-list-create")
            setupAction("招待されたまどに参加", path: .join, identifier: "window-list-join")
            setupAction("以前のまどにこのiPhoneを追加", path: .recover, identifier: "window-list-recover")
        }
        if pausesWindowChanges {
            Text(availabilityMessage ?? "身近な人とのまどを確認しています…")
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
        let isActive = window.localWindowID == activeWindowID
        let isSwitching = window.localWindowID == switchingWindowID
        let isSetup = groupedWindows.setupWindowIDs.contains(window.localWindowID)

        return Button {
            open(window)
        } label: {
            if isSetup {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(window.displayName)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if windowErrors.contains(window.localWindowID) {
                            Label("設定を開く", systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Text(windowPrimaryStatusLabel(for: window))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    if isSwitching {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
            } else {
                WindowPhotoCard(title: window.displayName, kind: .shared) {
                    windowCover(for: window)
                        .overlay(alignment: .topTrailing) {
                            if isSwitching {
                                ProgressView().padding(8).background(.thinMaterial, in: Capsule()).padding(8)
                            } else if windowErrors.contains(window.localWindowID) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                                    .padding(8).background(.thinMaterial, in: Capsule()).padding(8)
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if let pendingCount = pendingPreparationCounts[window.localWindowID], pendingCount > 0 {
                                Label("\(pendingCount.formatted())", systemImage: "clock")
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
        .accessibilityValue(windowAccessibilityStatus(for: window, isSetup: isSetup))
        .accessibilityHint(
            pausesWindowChanges && !isActive
                ? "更新が完了すると、このまどを開けます"
                : "このまどを開きます"
        )
    }

    private func windowCover(for window: PrivateWindowCatalogEntry) -> some View {
        GeometryReader { geometry in
            TimelineView(.explicit([Date.now, coverPhotos[window.localWindowID]?.photo?.displayUntil].compactMap { $0 })) { context in
                if let cover = coverPhotos[window.localWindowID]?.photo,
                   context.date < cover.displayUntil,
                   let image = UIImage(data: cover.jpeg) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    VStack(spacing: 12) {
                        SubtleWindowThumbnail(showsSetupMark: false)
                        Text(coverPlaceholder(for: window))
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func windowAccessibilityStatus(for window: PrivateWindowCatalogEntry, isSetup: Bool) -> String {
        var parts = [isSetup ? windowPrimaryStatusLabel(for: window)
                     : coverPhotos[window.localWindowID]?.photo != nil ? "写真あり" : coverPlaceholder(for: window)]
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
        case .noPhotos: return "まだ写真がありません"
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
                try? await source.refresh()
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
        guard CommandLine.arguments.contains("--window-list-ui-fixture"),
              CommandLine.arguments.contains("--window-list-mixed") else { return false }
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
            coverPhotos = [pairedID: .init(photo: .init(jpeg: jpeg, displayUntil: Date().addingTimeInterval(3600), origin: .sent), status: .photo)]
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
                               supportsPrivateWindows: CommandLine.arguments.contains("--window-list-mixed"),
                               officialStore: model.store,
                               refreshOfficialFeed: { try await model.refresh() },
                               previewOfficialFeed: { try await model.preview() },
                               publicWindows: sources)
            }
            .tabItem { Label("まど", systemImage: "rectangle.split.2x2") }.tag(2)
        }
        .environment(\.dynamicTypeSize,
                     CommandLine.arguments.contains("--window-list-largest-text") ? .accessibility5 :
                     CommandLine.arguments.contains("--window-list-large-text") ? .accessibility3 : .large)
        .preferredColorScheme(CommandLine.arguments.contains("--window-list-dark") ? .dark : nil)
    }
}
#endif

private struct DeepLinkSelection: Equatable {
    let identifier: String?
    let shownAt: Date?
}
