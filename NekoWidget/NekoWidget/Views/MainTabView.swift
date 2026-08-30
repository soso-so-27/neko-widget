import SwiftUI

enum PhotosRoute: Hashable {
    case photo(String)
    case collectionPhoto(String)
}

enum MemoriesRoute: Hashable {
    case photo(String)
    case automaticAlbums
    case seasonalMovie(SeasonalMoviePeriodID)
    case monthlyWindow(MonthlyWindowPresentation)
}

private struct SeasonalMoviePreparationKey: Hashable {
    let canPrepare: Bool
    let quarterStart: Date?
    let photoDigest: Int
    let videoCatalogDigest: Int
    let sourceAlbumIdentifier: String?
}

struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase

    let currentPhoto: PhotoPresentation?
    let likedPhotos: [PhotoPresentation]
    let catPhotos: [PhotoPresentation]
    let libraryPhotos: [PhotoPresentation]
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

    @State private var selectedTab: AppTab = .photos
    @State private var photosPath = NavigationPath()
    @State private var memoriesPath = NavigationPath()
    @State private var showsSettings = false
    @State private var replaysWidgetGuideAfterSettingsDismiss = false
    @State private var widgetOpenedPhotoIdentifier: String?
    @State private var widgetShownAt: Date?
    @State private var selectedAlbumScope: CatProfileScopePresentation = .everyone
    @State private var seasonalMovie: SeasonalMoviePresentation?
    @State private var completedSeasonalMoviePreparationKey: SeasonalMoviePreparationKey?
    @StateObject private var seasonalMovieArchive = SeasonalMovieArchiveLibrary()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $photosPath) {
                HomeView(
                    currentPhoto: currentPhoto,
                    scan: scan,
                    hasPhotoAccess: hasPhotoAccess,
                    isLimitedAccess: isLimitedAccess,
                    shouldOfferWidgetPlacementGuide: shouldOfferWidgetPlacementGuide,
                    requestPhotoAccess: requestPhotoAccess,
                    chooseMorePhotos: chooseMorePhotos,
                    showWidgetPlacementGuide: showWidgetPlacementGuide,
                    showSettings: { showsSettings = true },
                    setMemorySaved: setMemorySaved,
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
            }
            .tabItem {
                Label("写真", systemImage: "photo.on.rectangle.angled")
                    .accessibilityIdentifier("main-tab-photos")
            }
            .tag(AppTab.photos)

            if SharingAPIConfiguration.current.isReviewVisible {
                NavigationStack {
                    WindowListView(
                        opensActiveWindow: $deepLinkedFamilyWindowIsPresented,
                        pendingFamilyMomentSourceDigest: $deepLinkedFamilyMomentSourceDigest,
                        pendingFamilyNotificationRoute:
                            $pendingFamilyNotificationRoute,
                        showSettings: { showsSettings = true }
                    )
                }
                .tabItem {
                    Label("まど", systemImage: "rectangle.split.2x2")
                        .accessibilityIdentifier("main-tab-windows")
                }
                .tag(AppTab.windows)
            }

            NavigationStack(path: $memoriesPath) {
                LikedPhotosView(
                    photos: likedPhotos,
                    hasPhotoAccess: hasPhotoAccess,
                    monthlyWindowResult: currentMonthlyWindowResult,
                    seasonalMovies: seasonalMovieArchive.records,
                    automaticAlbumPreviewPhotos: automaticAlbumPreviewPhotos,
                    exportPhotoBook: exportPhotoBook,
                    showSettings: { showsSettings = true }
                )
                    .navigationDestination(
                        for: MemoriesRoute.self,
                        destination: memoriesDestination
                    )
            }
            .tabItem {
                Label("思い出", systemImage: "photo.stack.fill")
                    .accessibilityIdentifier("main-tab-memories")
            }
            .tag(AppTab.memories)
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
        .onChange(of: catProfilesPresentation.availableScopes) { _, scopes in
            guard scopes.contains(selectedAlbumScope) else {
                selectedAlbumScope = .everyone
                return
            }
        }
        .task(id: seasonalMoviePreparationKey) {
            await prepareSeasonalMovie()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
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
                    Button("閉じる") {
                        showsSettings = false
                    }
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
        }
    }

    @ViewBuilder
    private func detailView(for localIdentifier: String) -> some View {
        let initialPhoto = photo(for: localIdentifier)
        PhotoBrowserView(
            // A proposed photo and a Widget tap are one-photo entry points.
            // The grid uses a separate route whose browser can page through
            // the detected cat-photo collection.
            photos: [initialPhoto],
            libraryPhotos: libraryPhotos,
            initialPhoto: initialPhoto,
            widgetShownAt: widgetOpenedPhotoIdentifier == localIdentifier ? widgetShownAt : nil,
            showsWidgetTiming: widgetOpenedPhotoIdentifier == localIdentifier,
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
                Task { await catProfilesActions.replacePhotoAssignments(values) }
            }
        )
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
                Task { await catProfilesActions.replacePhotoAssignments(values) }
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
                Task { await catProfilesActions.replacePhotoAssignments(values) }
            }
        )
    }

    @ViewBuilder
    private func memoriesDestination(for route: MemoriesRoute) -> some View {
        switch route {
        case let .photo(localIdentifier):
            memoryDetailView(for: localIdentifier)
        case .automaticAlbums:
            automaticAlbumsView
        case let .seasonalMovie(periodID):
            seasonalMovieDestination(periodID)
        case let .monthlyWindow(snapshot):
            MonthlyWindowView(
                presentation: refreshedMonthlyWindow(snapshot),
                setMemorySaved: setMemorySaved
            )
        }
    }

    @ViewBuilder
    private func seasonalMovieDestination(
        _ periodID: SeasonalMoviePeriodID
    ) -> some View {
        if let presentation = seasonalMovieArchive.presentation(for: periodID) {
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
                    return updated
                },
                freezeRecipe: { reason in
                    try await seasonalMovieArchive.freeze(
                        periodID,
                        reason: reason
                    )
                }
            )
        } else {
            ContentUnavailableView(
                "この季節の作品を開けません",
                systemImage: "film.stack",
                description: Text("元の写真や動画がこのiPhoneにあるか確認してください。")
            )
        }
    }

    private var automaticAlbumsView: some View {
        AlbumView(
            sections: curatedAlbumSections,
            scan: scan,
            profiles: catProfilesPresentation.profiles,
            photoAlbumOptions: catProfilesPresentation.photoAlbumOptions,
            profileActions: catProfilesActions,
            selectedScope: $selectedAlbumScope
        )
        .navigationTitle("自動アルバム")
        .navigationDestination(for: AlbumRoute.self, destination: albumDestination)
    }

    @ViewBuilder
    private func albumDestination(for route: AlbumRoute) -> some View {
        switch route {
        case let .album(albumID):
            if let album = curatedAlbum(for: albumID) {
                if albumID.isGrowthComparison {
                    GrowthAlbumDetailView(
                        album: album,
                        lifeReference: growthLifeReference(for: albumID),
                        albumOpened: albumOpened,
                        excludeFromCatCandidates: { identifiers in
                            Task { await excludeFromCatCandidates(identifiers) }
                        },
                        profiles: catProfilesPresentation.profiles,
                        assignmentsByPhotoIdentifier: assignmentsByPhotoIdentifier,
                        replaceProfileAssignments: { values in
                            Task { await catProfilesActions.replacePhotoAssignments(values) }
                        }
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
                            Task { await catProfilesActions.replacePhotoAssignments(values) }
                        }
                    )
                }
            } else {
                missingAlbumView
            }

        case let .photo(albumID, localIdentifier):
            if let album = curatedAlbum(for: albumID),
               let initialPhoto = album.photos.first(where: {
                   $0.localIdentifier == localIdentifier
               }) {
                PhotoBrowserView(
                    photos: album.photos,
                    libraryPhotos: libraryPhotos,
                    initialPhoto: initialPhoto,
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
                        Task { await catProfilesActions.replacePhotoAssignments(values) }
                    }
                )
            } else {
                missingAlbumView
            }
        }
    }

    private var curatedAlbumSections: [CuratedAlbumSectionPresentation] {
        let builder = CuratedAlbumBuilder()
        let includesScopedGrowth: Bool
        if selectedAlbumScope == .everyone {
            includesScopedGrowth = false
        } else {
            includesScopedGrowth = catProfilesPresentation
                .timePolicy(for: selectedAlbumScope)
                .showsGrowthComparison
        }
        let baseSections = builder.sections(
            from: scopedCatPhotos,
            lifeReference: scopedLifeReference,
            includesGrowth: includesScopedGrowth
        )

        guard selectedAlbumScope == .everyone,
              let householdGrowth = HouseholdGrowthAlbumBuilder().album(
                from: catPhotos
              ) else {
            return baseSections
        }

        var sections = baseSections
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
        return sections
    }

    private var currentMonthlyWindowResult: MonthlyWindowBuildResult? {
        guard hasPhotoAccess else { return nil }
        let result = MonthlyWindowBuilder().buildMostRecent(
            from: catPhotos,
            through: Date()
        )
        if case .unavailable = result, !scan.hasFinalResult {
            return nil
        }
        return result
    }

    private var automaticAlbumPreviewPhotos: [PhotoPresentation] {
        let sections = CuratedAlbumBuilder().sections(
            from: catPhotos,
            lifeReference: nil,
            includesGrowth: false
        )
        let themedCovers = [
            CuratedAlbumGroup.time,
            .cuteness,
            .special,
        ].compactMap { group -> PhotoPresentation? in
            guard let section = sections.first(where: { $0.id == group }) else {
                return nil
            }
            let album = group == .time ? section.albums.last : section.albums.first
            return album?.coverPhoto
        }
        let allPhotos = sections
            .first(where: { $0.id == .all })?
            .albums
            .first(where: { $0.id == .allCatPhotos })?
            .photos ?? catPhotos

        var seenIdentifiers = Set<String>()
        var result: [PhotoPresentation] = []
        for photo in themedCovers + allPhotos {
            guard seenIdentifiers.insert(photo.localIdentifier).inserted else {
                continue
            }
            result.append(photo)
            if result.count == 4 { break }
        }
        return result
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

    private func refreshedMonthlyWindow(
        _ snapshot: MonthlyWindowPresentation
    ) -> MonthlyWindowPresentation {
        var currentByIdentifier: [String: PhotoPresentation] = [:]
        for photo in catPhotos {
            currentByIdentifier[photo.localIdentifier] = photo
        }
        return MonthlyWindowPresentation(
            monthStart: snapshot.monthStart,
            yearNumber: snapshot.yearNumber,
            monthNumber: snapshot.monthNumber,
            photos: snapshot.photos.map {
                currentByIdentifier[$0.localIdentifier] ?? $0
            },
            availableSceneCount: snapshot.availableSceneCount
        )
    }

    private var scopedCatPhotos: [PhotoPresentation] {
        guard case let .profile(identifier) = selectedAlbumScope else {
            return catPhotos
        }
        return profileAlbumPhotos[identifier] ?? []
    }

    private var scopedLifeReference: CatLifeReference? {
        guard case let .profile(identifier) = selectedAlbumScope else {
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

    private func growthLifeReference(for albumID: CuratedAlbumID) -> CatLifeReference? {
        switch albumID {
        case .householdGrowth:
            return nil
        case .growth:
            return scopedLifeReference
        case let .profileGrowth(profileIdentifier, _):
            return lifeReference(for: profileIdentifier)
        default:
            return nil
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
        for id: CuratedAlbumID
    ) -> CuratedAlbumPresentation? {
        curatedAlbumSections
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
    let showSettings: () -> Void

    @State private var windows: [PrivateWindowCatalogEntry] = []
    @State private var activeWindowID: String?
    @State private var isLoading = true
    @State private var switchingWindowID: String?
    @State private var catalogLoadMessage: String?
    @State private var pendingPreparationCounts: [String: Int] = [:]
    @State private var pairingPhases: [String: PairingPhase] = [:]
    @State private var catalogReloadRevision = 0
    @State private var showsAddWindowConfirmation = false
    @State private var requestedSetupPath: PairingSetupPath?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 22) {
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

                    if windows.isEmpty {
                        emptyWindowCard
                    } else {
                        if !connectedWindows.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                windowSectionTitle("接続済みのまど")
                                ForEach(connectedWindows) { window in
                                    windowCard(window)
                                }
                            }
                        }
                        if !setupWindows.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                windowSectionTitle("設定中のまど")
                                ForEach(setupWindows) { window in
                                    windowCard(window)
                                }
                            }
                        }
                        if !connectedWindows.isEmpty {
                            Text("まどの名前は、作成した人の最初のiPhoneから変更できます。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if availabilityMessage == nil,
                       let message = model.userFacingStatusMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                Color.orange.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 16)
                            )
                    }

                    if !windows.isEmpty {
                        windowAdditionControl
                    }

                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("まど")
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("設定")
                .accessibilityIdentifier("window-list-settings-button")
            }
        }
        .confirmationDialog(
            "このiPhoneですることを選んでください",
            isPresented: $showsAddWindowConfirmation,
            titleVisibility: .visible
        ) {
            Button("新しいまどを作る") {
                createAndOpenWindow(setupPath: .create)
            }
            Button("招待されたまどに参加") {
                createAndOpenWindow(setupPath: .join)
            }
            Button("このiPhoneを以前のまどに追加") {
                createAndOpenWindow(setupPath: .recover)
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("選んだ操作の入力画面へ進みます。")
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
            Task { await reloadCatalogPresentation() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .momentSharingContentNeedsReload
            )
        ) { _ in
            reloadPreparationCounts()
        }
    }

    private var availabilityMessage: String? {
        model.bootstrapRetryMessage ?? catalogLoadMessage
    }

    private var pausesWindowChanges: Bool {
        isLoading || availabilityMessage != nil
    }

    private func unavailableWindowContent(message: String) -> some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "まどを一時的に確認できません",
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

            Text("更新が完了するまで、まどの切り替えや追加は行いません。")
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
            Label("まだまどがありません", systemImage: "rectangle.on.rectangle.slash")
                .font(.headline)

            Text("新しく作るか、招待・機種変更のコードを使います。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("まどをはじめる") {
                showsAddWindowConfirmation = true
            }
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

    private var addWindowButton: some View {
        Button {
            showsAddWindowConfirmation = true
        } label: {
            Label("別のまどを追加", systemImage: "rectangle.stack.badge.plus")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .disabled(
            model.isWorking
                || pausesWindowChanges
        )
        .accessibilityIdentifier("window-list-add")
    }

    @ViewBuilder
    private var windowAdditionControl: some View {
        if !setupWindows.isEmpty {
            Label(
                "設定中のまどは同時に1個です。先に開いて設定を続けてください",
                systemImage: "arrow.up.left.square"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("window-list-setup-limit")
        } else if windows.count >= PrivateWindowCatalogState.maximumProductWindowCount {
            Label(
                windows.count > PrivateWindowCatalogState.maximumProductWindowCount
                    ? "現在は新しいまどを追加できません。既存のまどはそのまま使えます"
                    : "初期版では、まどは合計3個までです",
                systemImage: "rectangle.stack"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("window-list-product-limit")
        } else {
            addWindowButton
        }
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

    private func windowSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func createAndOpenWindow(setupPath: PairingSetupPath) {
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
            HStack(spacing: 12) {
                windowThumbnail(for: window)

                VStack(alignment: .leading, spacing: 5) {
                    Text(window.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    Text(windowPrimaryStatusLabel(for: window))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let pendingCount = pendingPreparationCounts[window.localWindowID],
                       pendingCount > 0 {
                        Label(
                            "送信準備中 \(pendingCount.formatted())枚",
                            systemImage: "clock.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    }

                }

                Spacer(minLength: 6)

                if isSwitching {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(
                        Color.primary.opacity(0.05),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(
            model.isWorking
                || isLoading
                || (pausesWindowChanges && !isActive)
        )
        .accessibilityIdentifier("window-list-row-\(window.localWindowID)")
        .accessibilityHint(
            pausesWindowChanges && !isActive
                ? "更新が完了すると、このまどを開けます"
                : "このまどを開きます"
        )
    }

    @ViewBuilder
    private func windowThumbnail(for window: PrivateWindowCatalogEntry) -> some View {
        SubtleWindowThumbnail(showsSetupMark: window.spaceID == nil)
            .frame(width: 56, height: 56)
            .background(
                Color.accentColor.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 13)
            )
            .accessibilityHidden(true)
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
        isLoading = true
        await model.bootstrap()
        await reloadCatalogPresentation()
        isLoading = false
    }

    private struct CatalogPresentationSnapshot: Sendable {
        let windows: [PrivateWindowCatalogEntry]
        let activeWindowID: String
        let pairingPhases: [String: PairingPhase]
    }

    private func reloadCatalogPresentation() async {
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
                return
            }
            windows = snapshot.windows
            activeWindowID = snapshot.activeWindowID
            pairingPhases = snapshot.pairingPhases
            catalogLoadMessage = nil
            reloadPreparationCounts()
        } catch {
            guard revision == catalogReloadRevision else { return }
            catalogLoadMessage = windows.isEmpty
                ? "保存済みのまどを読み込めませんでした。時間をおいて、もう一度お試しください。"
                : "まどの一覧を更新できませんでした。保存済みの一覧は変更していません。"
        }
    }

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
            pairingPhases: Dictionary(uniqueKeysWithValues: phasePairs)
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
            return "相手1人と非公開"
        case .failed:
            return "設定を確認"
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

private struct DeepLinkSelection: Equatable {
    let identifier: String?
    let shownAt: Date?
}
