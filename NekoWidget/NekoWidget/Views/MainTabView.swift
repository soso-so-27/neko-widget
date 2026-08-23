import SwiftUI

struct MainTabView: View {
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
    let widgetIntervalMinutes: Int
    let familyWindowPresentation: MomentFamilyWindowPresentation
    @Binding var deepLinkedPhotoIdentifier: String?
    @Binding var deepLinkedPhotoShownAt: Date?
    @Binding var deepLinkedFamilyWindowIsPresented: Bool

    let chooseMorePhotos: () -> Void
    let requestPhotoAccess: () -> Void
    let showWidgetPlacementGuide: () -> Void
    let toggleLike: (String) -> Void
    let exportPhotoBook: ([String]) async throws -> URL
    let albumOpened: (String, String) -> Void
    let updateAlbum: () -> Void
    let rescan: () async -> Void
    let saveSettings: (SettingsPresentation) async -> Void
    let saveLifeReference: (CatLifeReference?) async -> Void
    let excludeFromCatCandidates: ([String]) async -> Void
    let restoreCatCandidates: ([String]) async -> Void
    let selectPhotoSourceAlbum: (String?) async -> Void
    let refreshPhotoSourceAlbums: () async -> Void
    let exportJSON: () async -> URL?

    @State private var selectedTab: AppTab = .window
    @State private var homePath: [String] = []
    @State private var albumPath: [AlbumRoute] = []
    @State private var likesPath: [String] = []
    @State private var showsSettings = false
    @State private var replaysWidgetGuideAfterSettingsDismiss = false
    @State private var widgetOpenedPhotoIdentifier: String?
    @State private var widgetShownAt: Date?
    @State private var selectedAlbumScope: CatProfileScopePresentation = .everyone

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $homePath) {
                HomeView(
                    currentPhoto: currentPhoto,
                    scan: scan,
                    hasPhotoAccess: hasPhotoAccess,
                    isLimitedAccess: isLimitedAccess,
                    shouldOfferWidgetPlacementGuide: shouldOfferWidgetPlacementGuide,
                    familyWindowPresentation: familyWindowPresentation,
                    showsFamilyWindow: $deepLinkedFamilyWindowIsPresented,
                    requestPhotoAccess: requestPhotoAccess,
                    chooseMorePhotos: chooseMorePhotos,
                    showWidgetPlacementGuide: showWidgetPlacementGuide,
                    showSettings: { showsSettings = true },
                    toggleLike: toggleLike,
                    rescan: { Task { await rescan() } }
                )
                .navigationDestination(for: String.self, destination: detailView)
            }
            .tabItem {
                Label("まど", systemImage: "rectangle.on.rectangle")
                    .accessibilityIdentifier("main-tab-window")
            }
            .tag(AppTab.window)

            NavigationStack(path: $albumPath) {
                AlbumView(
                    sections: curatedAlbumSections,
                    scan: scan,
                    profiles: catProfilesPresentation.profiles,
                    photoAlbumOptions: catProfilesPresentation.photoAlbumOptions,
                    profileActions: catProfilesActions,
                    selectedScope: $selectedAlbumScope
                )
                    .navigationDestination(for: AlbumRoute.self, destination: albumDestination)
            }
            .tabItem {
                Label("思い出", systemImage: "square.grid.3x3.fill")
                    .accessibilityIdentifier("main-tab-memories")
            }
            .tag(AppTab.memories)

            NavigationStack(path: $likesPath) {
                LikedPhotosView(
                    photos: likedPhotos,
                    exportPhotoBook: exportPhotoBook
                )
                    .navigationDestination(for: String.self, destination: detailView)
            }
            .tabItem {
                // Tab bars on iOS 26 may discard a custom SwiftUI icon view.
                // A standard symbol keeps the destination visible; the custom
                // paw remains inside the feature's own screens.
                Label("これ好き", systemImage: "pawprint.fill")
                    .accessibilityIdentifier("main-tab-likes")
            }
            .tag(AppTab.likes)
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
            selectedTab = .window
            homePath = [identifier]
            deepLinkedPhotoIdentifier = nil
            deepLinkedPhotoShownAt = nil
        }
        .onChange(of: deepLinkedFamilyWindowIsPresented, initial: true) { _, isPresented in
            guard isPresented else { return }
            showsSettings = false
            selectedTab = .window
            homePath.removeAll()
        }
        .onChange(of: homePath) { _, path in
            guard path.isEmpty else { return }
            widgetOpenedPhotoIdentifier = nil
            widgetShownAt = nil
        }
        .onChange(of: settings.catLifeReference) { _, _ in
            // A legacy single-cat reference replaces calendar-year albums with
            // age/adoption buckets. Pop typed routes whose album may no longer
            // exist after the setting changes.
            albumPath.removeAll()
        }
        .onChange(of: selectedAlbumScope) { _, _ in
            albumPath.removeAll()
        }
        .onChange(of: catProfilesPresentation.availableScopes) { _, scopes in
            guard scopes.contains(selectedAlbumScope) else {
                selectedAlbumScope = .everyone
                return
            }
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
                saveSettings: saveSettings,
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
    private func detailView(for localIdentifier: String) -> some View {
        PhotoBrowserView(
            photos: catPhotos,
            libraryPhotos: libraryPhotos,
            initialPhoto: photo(for: localIdentifier),
            widgetShownAt: widgetOpenedPhotoIdentifier == localIdentifier ? widgetShownAt : nil,
            widgetIntervalMinutes: widgetIntervalMinutes,
            toggleLike: toggleLike,
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
                    widgetIntervalMinutes: widgetIntervalMinutes,
                    toggleLike: toggleLike,
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
            "思い出を更新しています",
            systemImage: "rectangle.stack",
            description: Text("スキャン結果が更新されました。思い出の一覧へ戻って、もう一度開いてください。")
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

private struct DeepLinkSelection: Equatable {
    let identifier: String?
    let shownAt: Date?
}
