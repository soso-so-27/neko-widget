import Foundation
import Photos
import SwiftUI
import UIKit

/// One foreground operation must not clear another operation's sleep request.
@MainActor
enum AppIdleTimer {
    private static var requests: Set<String> = []
    static func setPreventSleep(_ enabled: Bool, for owner: String) {
        if enabled { requests.insert(owner) } else { requests.remove(owner) }
        UIApplication.shared.isIdleTimerDisabled = !requests.isEmpty
    }
}

private struct WidgetShowcasePhoto: Identifiable {
    let id = UUID()
    let photoIdentifier: String
}

@MainActor
struct AppRootView: View {
    @ObservedObject var viewModel: AppViewModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.membershipAccess) private var membershipAccess
    @AppStorage("hasSeenInitialScanResult.v1") private var hasSeenInitialScanResult = false
    @AppStorage(OnboardingPresentationPersistence.completedVersionKey)
    private var onboardingCompletedVersion = 0
    @AppStorage(OnboardingPresentationPersistence.resumePageIndexKey)
    private var onboardingResumePageIndex = 0
    @StateObject private var widgetInstallationChecker = WidgetInstallationChecker()
    @StateObject private var photoPresentationCache = PhotoPresentationCache()
    @StateObject private var profilePresentationCache = ProfilePresentationCache()
    @StateObject private var momentNotificationTapMailbox = MomentNotificationTapMailbox.shared
    @State private var presentedError: PresentedError?
    @State private var showsWidgetPlacementGuide = false
    @ObservedObject private var invitationInbox = GroupInvitationInbox.shared
    /// Made at launch so 「この子のこと」 reaches the family notebook from the
    /// first run on. Nothing here draws from it, so it is not observed.
    private let familyNotebook = FamilyNotebookPrototype.shared
    private struct FamilyLink: Identifiable { let id = UUID(); let url: URL }
    @State private var familyLink: FamilyLink?
    /// Joined a family from a link: the notebook opens once that sheet is gone.
    @State private var joinedFamilyFromLink = false
    @State private var showsFamilyNotebook = false
    @State private var onboardingInvitation: GroupInvitationLink?
    @State private var firstRunPhoto: PhotoPresentation?
    @State private var startsInPhotosAfterOnboarding = false
    @State private var officialWindowRoute: OfficialWindowRoute?
    @State private var officialWindowPresentationID = UUID()
    @State private var onboardingScanErrorMessage: String?
    @StateObject private var widgetShowcaseStore = ShowcasePhotoStore.shared
    @State private var widgetShowcasePhoto: WidgetShowcasePhoto?

    var body: some View {
        WidgetPhotoPresentationHost(onOtherURL: handleNonPhotoURL) {
            Group {
                if OnboardingPresentationPersistence.requiresPresentation(
                    completedVersion: onboardingCompletedVersion
                ) {
                    onboardingContent
                } else {
                    regularContent
                }
            }
        } photo: { opening, close in
            widgetPhotoDestination(opening, close: close)
        }
        // Plus bought on the first run's last page: 「自動保存も始めますか？」 once the guide ends (11/7).
        .autoSaveOfferAfterOnboarding(ended: !OnboardingPresentationPersistence.requiresPresentation(
            completedVersion: onboardingCompletedVersion))
        .onReceive(NotificationCenter.default.publisher(for: .cloudyWindowConfigurationChanged)) { _ in
            Task { await viewModel.refreshCloudyWindow() }
        }
        .sheet(item: $familyLink, onDismiss: {
            if joinedFamilyFromLink {
                joinedFamilyFromLink = false; showsFamilyNotebook = true
                // Joined during the first run: the guide ends, as for a まど.
                if OnboardingPresentationPersistence.requiresPresentation(completedVersion: onboardingCompletedVersion) {
                    completeOnboardingForInvitation()
                }
            }
        }) { FamilyNotebookJoinView(link: $0.url, onJoined: { joinedFamilyFromLink = true }) }
        .sheet(isPresented: $showsFamilyNotebook) { FamilyNotebookView() }
        // An invitation link opened before the first-run guide ends: join at once,
        // then land in the まど tab. The guide can be finished later from 設定.
        .onChange(of: invitationInbox.pending?.id, initial: true) { _, _ in
            guard OnboardingPresentationPersistence.requiresPresentation(completedVersion: onboardingCompletedVersion),
                  let invitation = invitationInbox.pending else { return }
            // The first screen has no help sheet since 11/7, so nothing to wait for.
            onboardingInvitation = invitation
        }
        .sheet(item: $onboardingInvitation, onDismiss: {
            // Joined, or the invitation was settled (the sheet then cleared it).
            // Closed before applying: the guide stays, and the invitation waits.
            guard GroupWindowOpenInbox.shared.pendingWindowID != nil || invitationInbox.pending == nil else { return }
            invitationInbox.discard()
            // The まど tab opens the joined window from GroupWindowOpenInbox.
            completeOnboardingForInvitation()
        }) { invitation in
            GroupInvitationJoinSheet(invitation: invitation)
        }
        .onReceive(GroupWindowOpenInbox.shared.$pendingWindowID) { windowID in
            if windowID != nil { officialWindowRoute = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .onboardingPlusSheetClosed)) { _ in
            // A link opened while the Plus sheet was up could not be shown
            // over it; offer it now (11/7).
            guard OnboardingPresentationPersistence.requiresPresentation(completedVersion: onboardingCompletedVersion),
                  let invitation = invitationInbox.pending else { return }
            onboardingInvitation = nil
            DispatchQueue.main.async { onboardingInvitation = invitation }
        }
        .task {
            widgetInstallationChecker.refresh()
            await viewModel.start()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // SwiftUI uses scenes: app-delegate foreground callbacks alone are insufficient.
            await GroupAdmissionService.shared.refresh()
        }
        .onChange(of: viewModel.isScanning, initial: true) { _, isScanning in
            AppIdleTimer.setPreventSleep(isScanning && scenePhase == .active, for: "photo-scan")
        }
        .onChange(of: momentNotificationTapMailbox.pendingWidgetFeedback, initial: true) { _, feedback in
            guard let feedback else { return }
            presentedError = PresentedError(message: feedback.message)
            momentNotificationTapMailbox.consumeWidgetFeedback(id: feedback.id)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                AppIdleTimer.setPreventSleep(viewModel.isScanning, for: "photo-scan")
                widgetInstallationChecker.refresh()
                Task {
                    await viewModel.syncOnActive()
                    await viewModel.refreshInstalledCloudyWindows()
                }
            case .inactive, .background:
                AppIdleTimer.setPreventSleep(false, for: "photo-scan")
                // Vision batches are intentionally cancellable. Do not keep decoding photos
                // after the user leaves the app; the next active transition resumes/syncs.
                viewModel.suspendScan()
            @unknown default:
                viewModel.suspendScan()
            }
        }
        .onChange(of: widgetInstallationChecker.isInstalled, initial: true) { _, isInstalled in
            guard isInstalled else { return }
            // A guide opened from the 写真 tab closes by itself. The first
            // run's guide turns into its one 「置けました」 screen instead, and
            // nothing else opens: no Plus page on coming back (11/10).
            showsWidgetPlacementGuide = false
        }
        .onChange(of: onboardingState.currentPage, initial: true) { _, page in
            guard page == .widgetGuide else { return }
            // Before the person reaches the Home Screen, the newest cats get
            // their cloudy images, so the Widget's first drawing is the
            // cloudy window and its tag, not 「アプリを開いて」 (11/10).
            Task { await viewModel.refreshInstalledCloudyWindows() }
        }
        .onDisappear {
            AppIdleTimer.setPreventSleep(false, for: "photo-scan")
        }
        .onChange(of: viewModel.linkErrorMessage) { _, message in
            guard let message, !message.isEmpty else { return }
            // A link's problem is not the scan's: always the normal alert (11/6).
            presentedError = PresentedError(message: message)
            viewModel.clearLinkError()
        }
        // A scan that starts again (the app came back) clears its old failure.
        .onChange(of: viewModel.isScanning) { _, scanning in
            guard scanning, onboardingState.currentPage == .scanResult, onboardingScanErrorMessage != nil else { return }
            onboardingScanErrorMessage = nil
            viewModel.clearError()
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message, !message.isEmpty else { return }
            if onboardingState.currentPage == .scanResult {
                // Keep scan failures inside page three. The global alert clears
                // AppViewModel errors when dismissed, which would otherwise
                // send the onboarding back to an endless progress screen.
                onboardingScanErrorMessage = message
                return
            }
            presentedError = PresentedError(message: message)
        }
        .alert(item: $presentedError) { error in
            Alert(
                title: Text("うまくいきませんでした"),
                message: Text(error.message),
                dismissButton: .default(Text("閉じる")) {
                    viewModel.clearError()
                }
            )
        }
        .sheet(isPresented: $showsWidgetPlacementGuide) {
            WidgetPlacementGuideView(
                onComplete: dismissWidgetPlacementGuide,
                onSkip: dismissWidgetPlacementGuide
            )
        }
        .sheet(item: $firstRunPhoto) { photo in
            personalPhotoActions {
                NavigationStack {
                    mainTabContent.firstRunPhotoDestination(for: photo.localIdentifier)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("閉じる") { firstRunPhoto = nil }
                                    .accessibilityIdentifier("first-run-photo-close")
                            }
                        }
                }
            }
        }
        .sheet(item: $officialWindowRoute) { route in
            NavigationStack {
                Group {
                    if let definition = OfficialWindowConfiguration.definition(for: route.windowID) {
                        OfficialWindowView(initialPhotoID: route.photoID, store: .forWindow(definition))
                    } else {
                        ContentUnavailableView("このまどは開けません", systemImage: "rectangle.slash",
                                               description: Text("「まど」タブから、ほかのまどを選べます。"))
                    }
                }
                    .id(officialWindowPresentationID)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") { officialWindowRoute = nil }
                        }
                    }
            }
        }
    }

    private func handleNonPhotoURL(_ incoming: URL) {
        // 「アプリで開く」 on the invitation page: the same invitation (11/6).
        let url = InvitationAppLink.universal(from: incoming) ?? incoming
        if FamilyNotebookServiceFactory.productionRequested, (try? FamilyNotebookInvitationCapability(url: url)) != nil {
            familyLink = FamilyLink(url: url)
            return
        }
        if let route = CloudyWindowAlbumRoute(url: url) {
            guard Version1.isOn else { return }
            AlbumArrivalOpenInbox.shared.pending = route
            return
        }
        if let route = OfficialWindowRoute(url: url) {
            officialWindowPresentationID = UUID()
            officialWindowRoute = route
            return
        }
        if PhotosTabRoute.matches(url) {
            PhotosTabOpenInbox.shared.pending = true
            return
        }
        if ShowcaseWidgetRoute.matches(url) {
            // The iOS 17 widget: the same request as Control Center and Siri.
            ShowcaseLaunchRequest.request()
            return
        }
        Task { @MainActor in
            await viewModel.syncLikesForPresentation(trigger: "deeplink")
            viewModel.handleURL(url)
        }
    }

    @ViewBuilder
    private func widgetPhotoDestination(_ opening: WidgetPhotoOpening,
                                        close: @escaping () -> Void) -> some View {
        switch opening.destination {
        case .family:
            NavigationStack {
                ContentUnavailableView("このまどは利用できません", systemImage: "rectangle.slash",
                    description: Text("「まど」タブから、みんなのまどを開いてください。"))
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { WidgetPhotoCloseButton(close: close) } }
            }
        case let .official(route):
            NavigationStack {
                Group {
                    if let definition = OfficialWindowConfiguration.definition(for: route.windowID) {
                        OfficialWindowView(initialPhotoID: route.photoID, store: .forWindow(definition))
                    } else {
                        ContentUnavailableView("このまどは開けません", systemImage: "rectangle.slash")
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { WidgetPhotoCloseButton(close: close) }
                }
            }
        case let .personal(localIdentifier, shownAt):
            personalPhotoActions {
                NavigationStack {
                    Group {
                        switch viewModel.widgetPhotoLibraryLoadSucceeded {
                        case nil:
                            ProgressView("写真を読み込んでいます…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .some(false):
                            ContentUnavailableView("この写真は開けません", systemImage: "photo",
                                                   description: Text("写真へのアクセスと、設定の「写真の表示と整理」を確かめてください。"))
                        case .some(true):
                            mainTabContent.widgetPhotoDestination(
                                for: localIdentifier, shownAt: shownAt
                            )
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { WidgetPhotoCloseButton(close: close) }
                    }
                }
            }
            .task {
                // Refresh an App Intent's saved state in place; opening the
                // photograph no longer waits for this independent update.
                await viewModel.syncLikesForPresentation(trigger: "deeplink")
            }
        }
    }

    private func personalPhotoActions<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .environment(\.showcaseOpenOne, { identifier in
                widgetShowcasePhoto = WidgetShowcasePhoto(photoIdentifier: identifier)
            })
            .environment(\.showcaseAddPhoto, { identifier, scope in
                guard mainTabContent.catPhotos.contains(where: { $0.localIdentifier == identifier }) else {
                    throw ShowcasePhotoStore.Error.unavailable
                }
                try await widgetShowcaseStore.add(photoIdentifier: identifier, to: scope)
            })
            .environment(\.showcaseAddTargets,
                [ShowcaseAddTarget(id: "", title: "すべての猫")]
                + (viewModel.catHouseholdIdentity?.profiles ?? []).map {
                    ShowcaseAddTarget(id: $0.id.uuidString, title: $0.displayName)
                })
            .fullScreenCover(item: $widgetShowcasePhoto) { selected in
                ShowcasePhotoView(
                    store: widgetShowcaseStore,
                    items: [.current(selected.photoIdentifier)],
                    title: "この写真",
                    onClose: { widgetShowcasePhoto = nil },
                    onManage: nil
                )
            }
    }

    @ViewBuilder
    private var regularContent: some View {
        if hasPhotoAccess {
            authorizedContent
        } else {
            mainTabContent
        }
    }

    private var onboardingContent: some View {
        OnboardingView(
            page: onboardingPage,
            authorizationStatus: viewModel.authorizationStatus,
            isPhotoRequestReady: viewModel.catHouseholdIdentity != nil,
            isStartupLoadFailed: viewModel.startupLoadFailed,
            retryStartupLoad: { Task { await viewModel.retryStartup() } },
            scan: scanPresentation(records: viewModel.catAssets),
            // 11/14: the first look at "found cats" shows 確かな猫 first.
            resultPhotos: hasPhotoAccess
                ? CatPickTier.confidentFirst(viewModel.catAssets,
                                             isConfident: viewModel.isConfidentCatForPicks)
                    .prefix(9).map(photoPresentation)
                : [],
            scanErrorMessage: onboardingScanErrorMessage,
            isLimitedAccess: viewModel.isLimitedAccess,
            isWidgetPlaced: widgetInstallationChecker.isInstalled,
            requestPhotoAccess: {
                Task { await viewModel.requestAccess() }
            },
            skipPhotoAccess: completeOnboardingWithoutPhotoAccess,
            openPhotoSettings: openSystemSettings,
            chooseMorePhotos: presentLimitedLibraryPicker,
            rescan: {
                onboardingScanErrorMessage = nil
                viewModel.clearError()
                Task { await viewModel.rescan() }
            },
            finishWithoutWidgetPhoto: completeOnboardingWithoutWidgetPhoto,
            finish: {
                if onboardingState.currentPage == .widgetGuide, widgetInstallationChecker.isInstalled {
                    completeWidgetPlacementGuideIfNeeded()
                } else {
                    completeOnboarding()
                }
            },
            skipPlusOffer: skipOnboardingPlusOffer,
            openPhoto: { photo in
                // Ignore queued taps after completion or a Widget-guide choice.
                // A repeated tap must not replace the photo already presented.
                guard onboardingState.currentPage == .scanResult,
                      firstRunPhoto == nil else { return }
                // 11/12: the photo opens over the scan page and closing it
                // returns there. The first run goes on, so 「ウィジェットを置く」
                // is still the next step (it was skipped by this tap).
                firstRunPhoto = photo
            },
            openNowaWindow: openNowaWindowFromOnboarding
        )
        // A first run saved on the Plus page resumes it over the person's own
        // cat, as everywhere else, never the cat symbol (11/10).
        .environment(\.plusOfferPhoto, hasPhotoAccess ? viewModel.catAssets.first.map {
            PlusOfferPhoto(localIdentifier: $0.localIdentifier, catBoundingBox: $0.cat.boundingBox?.cgRect)
        } : nil)
    }

    /// No cat found on the scan page (11/12): のわのまど opens over it, through
    /// the same sheet as a のわのまど link, so the Widget has a cat to show.
    private var openNowaWindowFromOnboarding: (() -> Void)? {
        guard Version1.isOn,
              OfficialWindowConfiguration.definition(for: Self.nowaWindowID) != nil else { return nil }
        return {
            officialWindowPresentationID = UUID()
            officialWindowRoute = OfficialWindowRoute(windowID: Self.nowaWindowID)
        }
    }

    private static let nowaWindowID = "black-cats"

    @ViewBuilder
    private var authorizedContent: some View {
        if !hasSeenInitialScanResult {
            InitialScanView(
                scan: scanPresentation(records: viewModel.catAssets),
                isLimitedAccess: viewModel.isLimitedAccess,
                chooseMorePhotos: presentLimitedLibraryPicker,
                rescan: {
                    Task { await viewModel.rescan() }
                },
                continueToApp: {
                    hasSeenInitialScanResult = true
                }
            )
        } else {
            mainTabContent
        }
    }

    private var mainTabContent: MainTabView {
        LaunchWork.measure("mainTabContent") { makeMainTabContent() }
    }

    private func makeMainTabContent() -> MainTabView {
        let visibleSnapshot = hasPhotoAccess
            ? viewModel.presentationSnapshot
            : .empty
        let readableSnapshot = hasPhotoAccess ? viewModel.readableSourceSnapshot : .empty
        let photoProjection = photoPresentationCache.projection(
            snapshot: visibleSnapshot,
            sourceSnapshot: readableSnapshot,
            version: viewModel.presentationVersion,
            transform: photoPresentation
        )
        let visibleCatAssets = photoProjection.catAssets
        let assetsByIdentifier = photoProjection.assetsByIdentifier
        let identity = hasPhotoAccess ? viewModel.catHouseholdIdentity : nil
        // 11/14: the per-cat pages (sorting every cat's photos) and the
        // readable set were rebuilt on every drawing of the root, ~130 ms each
        // on a large library. Rebuilt only when one of their inputs changes.
        let profileKey = ProfilePresentationCache.Key(
            version: viewModel.presentationVersion, hasPhotoAccess: hasPhotoAccess,
            identity: identity, received: viewModel.receivedPhotoIdentifiers,
            sourceAlbums: viewModel.photoSourceAlbums,
            unavailableAlbums: viewModel.unavailableProfilePhotoAlbumIdentifiers,
            albumDates: viewModel.profilePhotoAlbumAssetDates,
            care: CatCareStore.shared.state, lifeReference: viewModel.settings.catLifeReference,
            excluded: viewModel.excludedCatAssets,
            isFinalScan: DetectionAccuracySampler.isFinal(viewModel.snapshot))
        let profileValues = profilePresentationCache.values(for: profileKey) {
            LaunchWork.count("profilePresentationsBuilt")
            let identityProjection = identity.map { profileIdentityProjection($0) }
            let postureDiagnostics = postureDiagnosticsPresentation(records: visibleCatAssets)
            return ProfilePresentationCache.Values(
                profiles: makeCatProfilesPresentation(
                    identity: identity,
                    projection: identityProjection,
                    assetsByIdentifier: assetsByIdentifier,
                    candidateAssets: visibleCatAssets,
                    postureDiagnostics: postureDiagnostics
                ),
                albumPhotos: makeProfileAlbumPhotos(
                    identity: identity,
                    projection: identityProjection,
                    assetsByIdentifier: assetsByIdentifier
                ),
                readableIdentifiers: Set(readableSnapshot.assets.map(\.localIdentifier)),
                // Internal builds' review samples hash and sort every cat
                // photo: once per change too.
                detectionSample: internalDetectionAccuracySample(hasPhotoAccess: hasPhotoAccess),
                recoverySample: internalHighResolutionRecoverySample(
                    hasPhotoAccess: hasPhotoAccess, records: visibleCatAssets))
        }
        let profilesPresentation = profileValues.profiles
        let profilePhotos = profileValues.albumPhotos

        return MainTabView(
            currentPhoto: hasPhotoAccess
                ? viewModel.currentAsset.map(photoPresentation)
                : nil,
            likedPhotos: photoProjection.likedPhotos,
            catPhotos: photoProjection.catPhotos,
            libraryPhotos: photoProjection.libraryPhotos,
            // 11/13: every cat's whole set (explicit includes, the linked
            // album, the single-cat rule, minus exclusions), cached per
            // presentation version in the view model, not built per render.
            photoLibraryAssignments: viewModel.catHouseholdIdentity == nil
                ? [:] : viewModel.catProfilePhotoAssignments,
            photoLibraryProfileNames: viewModel.catHouseholdIdentity.map { value in
                Dictionary(uniqueKeysWithValues: value.profiles.map { profile in
                    (profile.id.uuidString, profile.displayName)
                })
            },
            receivedPhotoIdentifiers: viewModel.receivedPhotoIdentifiers,
            savedPhotoIdentifiers: viewModel.savedPhotoIdentifiers,
            savedPhotoStateReadFailed: viewModel.savedPhotoStateReadFailed,
            readablePhotoIdentifiers: profileValues.readableIdentifiers,
            photoLibraryLoadSucceeded: viewModel.widgetPhotoLibraryLoadSucceeded,
            photoPresentationVersion: viewModel.presentationVersion,
            scan: hasPhotoAccess
                ? scanPresentation(records: visibleCatAssets)
                : ScanPresentation(),
            albumState: hasPhotoAccess
                ? effectiveAlbumState(catAssetCount: visibleCatAssets.count)
                : .idle,
            settings: settingsPresentation,
            detectionAccuracySample: profileValues.detectionSample,
            highResolutionRecoverySample: profileValues.recoverySample,
            excludedCatPhotos: hasPhotoAccess
                ? excludedCatPhotoPresentations(assetsByIdentifier: assetsByIdentifier)
                : [],
            photoSourceAlbums: hasPhotoAccess ? viewModel.photoSourceAlbums : [],
            photoSourceStatus: hasPhotoAccess ? viewModel.photoSourceStatus : .allLibrary,
            catProfilesPresentation: profilesPresentation,
            profileAlbumPhotos: profilePhotos,
            catProfilesActions: catProfilesActions,
            hasPhotoAccess: hasPhotoAccess,
            isLimitedAccess: hasPhotoAccess && viewModel.isLimitedAccess,
            isScanning: hasPhotoAccess && viewModel.isScanning,
            shouldOfferWidgetPlacementGuide: widgetInstallationChecker
                .shouldOfferPlacementGuide,
            privateWindowDisplayName: viewModel.privateWindowDisplayName,
            deepLinkedPhotoIdentifier: $viewModel.selectedAssetIdentifier,
            deepLinkedPhotoShownAt: $viewModel.selectedAssetShownAt,
            deepLinkedFamilyWindowIsPresented: $viewModel.isFamilyWindowPresented,
            deepLinkedFamilyMomentSourceDigest: $viewModel.pendingFamilyMomentSourceDigest,
            pendingFamilyNotificationRoute:
                $viewModel.pendingFamilyNotificationRoute,
            chooseMorePhotos: presentLimitedLibraryPicker,
            requestPhotoAccess: requestOrOpenPhotoAccess,
            showWidgetPlacementGuide: {
                showsWidgetPlacementGuide = true
            },
            setMemorySaved: { identifier, isSaved in
                Task {
                    await viewModel.setMemorySaved(
                        id: identifier,
                        isSaved: isSaved
                    )
                }
            },
            exportPhotoBook: { identifiers in
                try await PhotoBookPDFExporter().export(
                    from: viewModel.likedAssets,
                    selectedIdentifiers: identifiers
                )
            },
            exportMemoryPhoto: { identifier in
                guard readableSnapshot.assets.contains(where: { $0.localIdentifier == identifier }) else {
                    throw MemoryPhotoJPEGExportError.photoUnavailable
                }
                return try await PhotoLibraryJPEGExporter().export(localIdentifier: identifier)
            },
            albumOpened: { key, group in
                Task {
                    await viewModel.recordAlbumOpened(key: key, group: group)
                }
            },
            updateAlbum: updateAlbum,
            rescan: {
                await viewModel.rescan()
            },
            savePhotoSettings: { range, albumLimit in
                var settings = viewModel.settings
                settings.dateRange = range == .all ? .all : .recentYear
                settings.albumMaximum = albumLimit
                await viewModel.updateSettings(settings)
            },
            saveDetectionSettings: { confidenceThreshold, minimumAreaRatio in
                var settings = viewModel.settings
                settings.confidenceThreshold = Float(confidenceThreshold)
                settings.minimumCatAreaRatio = minimumAreaRatio
                await viewModel.updateSettings(settings)
            },
            saveLifeReference: { reference in
                await viewModel.updateCatLifeReference(reference)
            },
            excludeFromCatCandidates: { identifiers in
                await viewModel.excludeFromCatCandidates(localIdentifiers: identifiers)
            },
            restoreCatCandidates: { identifiers in
                await viewModel.restoreCatCandidates(localIdentifiers: identifiers)
            },
            selectPhotoSourceAlbum: { identifier in
                await viewModel.selectPhotoSourceAlbum(localIdentifier: identifier)
            },
            refreshPhotoSourceAlbums: {
                await viewModel.refreshPhotoSourceAlbums()
            },
            exportJSON: {
                await viewModel.exportJSON()
            },
            startsInPhotos: startsInPhotosAfterOnboarding,
            resumeScan: {
                await viewModel.resumeScan()
            }
        )
    }

    private func scanPresentation(records: [AssetRecord]) -> ScanPresentation {
        let state = viewModel.scanState
        var presentation = ScanPresentation(
            scannedAssets: state.scannedAssets,
            totalAssets: state.totalAssets,
            deferredAssets: viewModel.isScanning ? viewModel.deferredAssetsBeforePass : state.deferredAssets,
            isScanning: viewModel.isScanning,
            isPaused: state.phase == .cancelled,
            lastScannedAt: state.lastScannedAt,
            isGroupedAlbumUpgrade: state.purpose == .groupedAlbumUpgrade,
            hasFailed: state.phase == .failed
        )

        switch state.resultKind {
        case .none:
            break
        case .provisional:
            presentation.preliminaryCatAssets = records.count
            presentation.preliminaryOldestDate = records.compactMap(\.creationDate).min()
        case .final:
            presentation.finalCatAssets = records.count
            presentation.finalOldestDate = records.compactMap(\.creationDate).min()
        }
        return presentation
    }

    private var settingsPresentation: SettingsPresentation {
        SettingsPresentation(
            range: viewModel.settings.dateRange == .all ? .all : .recentYear,
            albumLimit: viewModel.settings.albumMaximum,
            confidenceThreshold: Double(viewModel.settings.confidenceThreshold),
            minimumAreaRatio: viewModel.settings.minimumCatAreaRatio,
            catLifeReference: viewModel.settings.catLifeReference
        )
    }

    /// The samples are shown only in internal builds' Settings, so the
    /// SHA-256 ranking and sort are skipped entirely in shipping builds.
    private func internalDetectionAccuracySample(
        hasPhotoAccess: Bool
    ) -> DetectionAccuracySamplePresentation {
#if DEBUG || INTERNAL_PRESENTATION
        hasPhotoAccess ? detectionAccuracySamplePresentation : .init()
#else
        .init()
#endif
    }

    private func internalHighResolutionRecoverySample(
        hasPhotoAccess: Bool,
        records: [AssetRecord]
    ) -> DetectionAccuracySamplePresentation {
#if DEBUG || INTERNAL_PRESENTATION
        hasPhotoAccess ? highResolutionRecoverySamplePresentation(records: records) : .init()
#else
        .init()
#endif
    }

#if DEBUG || INTERNAL_PRESENTATION
    private var detectionAccuracySamplePresentation: DetectionAccuracySamplePresentation {
        guard DetectionAccuracySampler.isFinal(viewModel.snapshot) else {
            return DetectionAccuracySamplePresentation()
        }
        let selection = DetectionAccuracySampler.sample(from: viewModel.snapshot)
        return DetectionAccuracySamplePresentation(
            snapshotIsFinal: selection.snapshotIsFinal,
            items: selection.items.map { item in
                DetectionAccuracySampleItemPresentation(
                    reviewNumber: item.reviewNumber,
                    localIdentifier: item.record.localIdentifier,
                    creationDate: item.record.creationDate
                )
            }
        )
    }

    /// Highest-confidence cats found only by the 2048px retry. This keeps the
    /// Build 19 visual acceptance sample on-device and exports no identifiers.
    private func highResolutionRecoverySamplePresentation(
        records: [AssetRecord]
    ) -> DetectionAccuracySamplePresentation {
        guard DetectionAccuracySampler.isFinal(viewModel.snapshot) else {
            return DetectionAccuracySamplePresentation()
        }
        let recovered = records.filter {
            $0.analysisEvidence?.finalPass == .highResolution2048
                && $0.analysisEvidence?.fallbackOutcome == .detected
        }.sorted {
            if $0.cat.confidence != $1.cat.confidence {
                return $0.cat.confidence > $1.cat.confidence
            }
            if $0.creationDate != $1.creationDate {
                return ($0.creationDate ?? .distantPast)
                    > ($1.creationDate ?? .distantPast)
            }
            return $0.localIdentifier < $1.localIdentifier
        }
        return DetectionAccuracySamplePresentation(
            snapshotIsFinal: true,
            items: recovered.prefix(20).enumerated().map { offset, record in
                DetectionAccuracySampleItemPresentation(
                    reviewNumber: offset + 1,
                    localIdentifier: record.localIdentifier,
                    creationDate: record.creationDate
                )
            }
        )
    }
#endif

    private func excludedCatPhotoPresentations(
        assetsByIdentifier: [String: AssetRecord]
    ) -> [ExcludedCatPhotoPresentation] {
        return viewModel.excludedCatAssets.map { exclusion in
            ExcludedCatPhotoPresentation(
                localIdentifier: exclusion.localIdentifier,
                creationDate: assetsByIdentifier[exclusion.localIdentifier]?.creationDate,
                excludedAt: exclusion.excludedAt
            )
        }
    }

    private func makeProfileAlbumPhotos(
        identity: CatHouseholdIdentityState?,
        projection: ProfileIdentityProjection?,
        assetsByIdentifier: [String: AssetRecord]
    ) -> [String: [PhotoPresentation]] {
        guard let identity, let projection else { return [:] }
        var result: [String: [PhotoPresentation]] = [:]
        for profile in identity.profiles {
            result[profile.id.uuidString] = (projection.confirmedByProfile[profile.id] ?? [])
                .map { identifier in
                    profilePhotoPresentation(
                        assetsByIdentifier[identifier],
                        localIdentifier: identifier,
                        creationDate: profilePhotoCreationDate(
                            identifier: identifier,
                            asset: assetsByIdentifier[identifier]
                        ),
                        membership: projection.membershipByProfile[profile.id]?[identifier],
                        isLinkedAlbumPhoto: projection.linkedByProfile[profile.id]?
                            .contains(identifier) == true
                    )
            }.sorted(by: Self.newestPhotoFirst)
        }
        return result
    }

    private func makeCatProfilesPresentation(
        identity: CatHouseholdIdentityState?,
        projection: ProfileIdentityProjection?,
        assetsByIdentifier: [String: AssetRecord],
        candidateAssets: [AssetRecord],
        postureDiagnostics: CatPostureDiagnosticsPresentation
    ) -> CatProfilesPresentation {
        guard let identity, let projection else {
            return CatProfilesPresentation(
                postureDiagnostics: postureDiagnostics
            )
        }
        let allCandidatePhotos = candidateAssets.map { asset in
            CatProfilePhotoPresentation(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                catBoundingBox: asset.cat.boundingBox?.cgRect,
                assignedProfileIdentifiers: projection.assignedByAsset[
                    asset.localIdentifier
                ] ?? [],
                detectedCatCount: asset.cat.catCount
            )
        }.sorted(by: Self.newestProfilePhotoFirst)
        let photoAlbumOptions = viewModel.photoSourceAlbums.map {
            CatProfilePhotoAlbumOptionPresentation(
                identifier: $0.localIdentifier,
                title: $0.title,
                accessiblePhotoCount: $0.accessibleAssetCount
            )
        }
        // A display projection only: family dates stay in the notebook and
        // never overwrite the personal identity file or its portable backup.
        let displayedIdentity = FamilyNotebookCatCareBridge.projectingAdoptionDays(
            CatCareStore.shared.state ?? CatCareState(), into: identity)
        let profiles = displayedIdentity.profiles.map { profile -> CatProfilePresentation in
            let confirmedIdentifiers = projection.confirmedByProfile[profile.id] ?? []
            let confirmed = confirmedIdentifiers
                .map { identifier in
                    catProfilePhotoPresentation(
                        assetsByIdentifier[identifier],
                        localIdentifier: identifier,
                        creationDate: profilePhotoCreationDate(
                            identifier: identifier,
                            asset: assetsByIdentifier[identifier]
                        ),
                        membership: projection.membershipByProfile[profile.id]?[identifier],
                        assignedProfileIdentifiers: projection.assignedByAsset[
                            identifier
                        ] ?? []
                    )
            }.sorted(by: Self.newestProfilePhotoFirst)
            let lifeReference = profile.lifeReference.flatMap { reference in
                reference.date.date().map {
                    CatProfileLifeReferencePresentation(
                        kind: reference.kind == .birthday ? .birthday : .adoptionDay,
                        date: $0,
                        isApproximate: profile.lifeReferenceIsApproximate
                    )
                }
            }
            let albumLink = profile.photoAlbumLink.map { link in
                let option = viewModel.photoSourceAlbums.first {
                    $0.localIdentifier == link.localIdentifier
                }
                let isAvailable = option != nil
                    && !viewModel.unavailableProfilePhotoAlbumIdentifiers
                        .contains(link.localIdentifier)
                let linkedProfilePhotoCount = Set(
                    link.lastKnownAssetLocalIdentifiers
                ).intersection(confirmedIdentifiers).count
                return CatProfilePhotoAlbumLinkPresentation(
                    identifier: link.localIdentifier,
                    title: option?.title,
                    accessiblePhotoCount: option?.accessibleAssetCount,
                    profilePhotoCount: linkedProfilePhotoCount,
                    isAvailable: isAvailable
                )
            }
            return CatProfilePresentation(
                identifier: profile.id.uuidString,
                name: profile.displayName,
                // 11/14: without a key photo the app picks the newest
                // 確かな猫, then the newest photo.
                coverPhoto: confirmed.first(where: {
                    $0.localIdentifier == profile.keyPhotoLocalIdentifier
                }) ?? confirmed.first(where: \.isConfidentCat) ?? confirmed.first,
                confirmedPhotos: confirmed,
                manualCandidatePhotos: allCandidatePhotos.filter {
                    !confirmedIdentifiers.contains($0.localIdentifier)
                },
                lifeReference: lifeReference,
                photoAlbumLink: albumLink,
                lifeDates: CatProfileLifeDatesPresentation(
                    birthday: Self.profileLifeDate(profile, kind: .birthday),
                    adoptionDay: Self.profileLifeDate(profile, kind: .adoptionDay),
                    primaryKind: lifeReference?.kind
                ),
                keyPhotoIdentifier: profile.keyPhotoLocalIdentifier,
                excludedPhotoIdentifiers: Set(
                    (projection.membershipByProfile[profile.id] ?? [:]).values
                        .filter { $0.decision == .excluded }
                        .map(\.assetLocalIdentifier)
                ),
                countsEveryDetectedCatPhoto: identity.singleCatProfileID == profile.id
            )
        }

        let unassigned = allCandidatePhotos.filter {
            $0.assignedProfileIdentifiers.isEmpty
        }

        let legacyExcludedIdentifiers = Set(
            identity.legacyUnscoped?.legacyExcludedAssetIdentifiers ?? []
        )
        let legacyExcluded: [LegacyExcludedCatPhotoPresentation] = viewModel
            .excludedCatAssets.compactMap { excluded -> LegacyExcludedCatPhotoPresentation? in
            guard legacyExcludedIdentifiers.contains(excluded.localIdentifier) else {
                return nil
            }
            return LegacyExcludedCatPhotoPresentation(
                localIdentifier: excluded.localIdentifier,
                creationDate: assetsByIdentifier[excluded.localIdentifier]?.creationDate
            )
        }
        let legacyLifeReference: CatProfileLifeReferencePresentation?
        if identity.profiles.isEmpty,
           let reference = viewModel.settings.catLifeReference,
           let date = reference.date.date() {
            legacyLifeReference = CatProfileLifeReferencePresentation(
                kind: reference.kind == .birthday ? .birthday : .adoptionDay,
                date: date,
                isApproximate: false
            )
        } else {
            legacyLifeReference = nil
        }
        return CatProfilesPresentation(
            profiles: profiles,
            photoAlbumOptions: photoAlbumOptions,
            unassignedPhotos: unassigned,
            legacyExcludedPhotos: legacyExcluded,
            legacyLifeReference: legacyLifeReference,
            postureDiagnostics: postureDiagnostics
        )
    }

    private func postureDiagnosticsPresentation(
        records: [AssetRecord]
    ) -> CatPostureDiagnosticsPresentation {
        let distribution = CatBoundingBoxAspectDistribution(
            records: records
        )
        return CatPostureDiagnosticsPresentation(
            targetPhotoCount: distribution.targetCatAssets,
            validBoxPhotoCount: distribution.assetsWithValidBoxes,
            classifiedPhotoCount: distribution.classifiedAssets,
            fullyUnclassifiedPhotoCount: distribution.fullyUnclassifiedAssets,
            missingBoxPhotoCount: distribution.missingBoxAssets,
            multiAlbumPhotoCount: distribution.multiAlbumAssets,
            sleepingPhotoCount: distribution.sleepingAssets,
            curledPhotoCount: distribution.curledAssets,
            sittingPhotoCount: distribution.sittingAssets
        )
    }

    private var catProfilesActions: CatProfilesViewActions {
        CatProfilesViewActions(
            exportProfileDates: { try viewModel.exportCatProfileDates() },
            previewProfileImport: { try viewModel.previewCatProfileImport($0) },
            importProfileDates: { await viewModel.importCatProfileDates($0) },
            createProfile: { draft in
                let reference = Self.lifeReference(from: draft.lifeReference)
                let identifier = await viewModel.createCatProfile(
                    displayName: draft.name,
                    lifeReference: reference,
                    lifeReferenceIsApproximate: draft.lifeReference?.isApproximate == true,
                    referenceAssetIdentifier: draft.referencePhotoIdentifier
                )
                return identifier?.uuidString
            },
            updateName: { identifier, name in
                guard let profileID = UUID(uuidString: identifier) else { return false }
                return await viewModel.updateCatProfileName(
                    profileID: profileID,
                    displayName: name
                )
            },
            updateLifeDates: { identifier, dates in
                guard let profileID = UUID(uuidString: identifier) else { return false }
                return await viewModel.updateCatProfileLifeDates(
                    profileID: profileID,
                    dates: CatProfileLifeDates(
                        birthday: Self.lifeReference(from: dates.birthday)?.date,
                        birthdayIsApproximate: dates.birthday?.isApproximate == true,
                        adoptionDay: Self.lifeReference(from: dates.adoptionDay)?.date,
                        adoptionDayIsApproximate: dates.adoptionDay?.isApproximate == true
                    ),
                    preferredPrimaryKind: dates.primaryKind.map {
                        $0 == .birthday ? .birthday : .adoptionDay
                    }
                )
            },
            setKeyPhoto: { identifier, photoIdentifier in
                guard let profileID = UUID(uuidString: identifier) else { return false }
                return await viewModel.setCatProfileKeyPhoto(
                    profileID: profileID,
                    localIdentifier: photoIdentifier
                )
            },
            setProfilePhotoAlbum: { profileIdentifier, albumIdentifier in
                guard let profileID = UUID(uuidString: profileIdentifier) else {
                    return false
                }
                return await viewModel.setCatProfilePhotoAlbum(
                    profileID: profileID,
                    localIdentifier: albumIdentifier
                )
            },
            refreshPhotoAlbums: {
                await viewModel.refreshPhotoSourceAlbums()
            },
            confirmProfileMembership: { identifier, photoIdentifiers in
                guard let profileID = UUID(uuidString: identifier) else { return false }
                return await viewModel.setCatProfileMembership(
                    profileID: profileID,
                    localIdentifiers: photoIdentifiers,
                    decision: .included
                )
            },
            removeProfileMembership: { identifier, photoIdentifiers in
                guard let profileID = UUID(uuidString: identifier) else { return false }
                return await viewModel.setCatProfileMembership(
                    profileID: profileID,
                    localIdentifiers: photoIdentifiers,
                    decision: .excluded
                )
            },
            replacePhotoAssignments: { input in
                guard input.values.allSatisfy({ identifiers in
                    identifiers.allSatisfy { UUID(uuidString: $0) != nil }
                }) else { return false }
                let converted = input.mapValues { identifiers in
                    Set(identifiers.compactMap(UUID.init(uuidString:)))
                }
                return await viewModel.replaceCatProfileAssignments(
                    profileIDsByLocalIdentifier: converted
                )
            },
            excludeFromHousehold: { identifiers in
                await viewModel.excludeFromCatCandidates(localIdentifiers: identifiers)
            },
            restoreLegacyExclusions: { identifiers in
                await viewModel.restoreCatCandidates(localIdentifiers: identifiers)
            },
            deleteProfile: { identifier in
                guard let profileID = UUID(uuidString: identifier) else { return false }
                return await viewModel.deleteCatProfile(profileID: profileID)
            },
            currentErrorMessage: { viewModel.errorMessage }
        )
    }

    private static func profileLifeDate(
        _ profile: CatProfile,
        kind: CatLifeReferenceKind
    ) -> CatProfileLifeReferencePresentation? {
        guard let reference = profile.lifeReference(for: kind),
              let date = reference.date.date() else { return nil }
        return CatProfileLifeReferencePresentation(
            kind: kind == .birthday ? .birthday : .adoptionDay,
            date: date,
            isApproximate: profile.isLifeReferenceApproximate(for: kind)
        )
    }

    private func profilePhotoPresentation(
        _ asset: AssetRecord?,
        localIdentifier: String,
        creationDate: Date?,
        membership: CatAssetProfileMembership?,
        isLinkedAlbumPhoto: Bool
    ) -> PhotoPresentation {
        guard let asset else {
            return PhotoPresentation(
                localIdentifier: localIdentifier,
                creationDate: creationDate,
                detectedCatCount: 0,
                isGrowthEligible: isLinkedAlbumPhoto
            )
        }
        let traits = asset.albumTraits
        let boxes = asset.resolvedCatBoundingBoxes.boundingBoxes
        let subjectBoundingBox = membership?.decision == .included
            ? membership?.subjectBoundingBox
            : nil
        let selectedBox = CatProfileBoundingBoxSelector.select(
            from: boxes,
            detectedCatCount: asset.cat.catCount,
            subjectBoundingBox: subjectBoundingBox
        )
        let displayBox = subjectBoundingBox
            ?? selectedBox
            ?? asset.cat.boundingBox
        // Album traits must come from a detector box that still matches this
        // profile. A stale saved subject rect is display metadata, not current
        // evidence for a close-up classification.
        let growthBox = selectedBox
        return PhotoPresentation(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            catBoundingBox: displayBox?.cgRect,
            isLiked: asset.liked,
            likedAt: asset.likedAt,
            isPhotoLibraryFavorite: asset.isFavorite,
            albumPostures: Set(selectedBox.map {
                CatBoundingBoxAspectBucket.postures(for: [$0])
            } ?? []),
            albumContainsPerson: traits?.containsPerson,
            albumIsOuting: traits?.isOuting,
            detectedCatCount: asset.cat.catCount,
            largestCatAreaRatio: growthBox?.area,
            // A linked album is explicit profile authority, but a scanned
            // multi-cat photo still needs an exact subject box before it can
            // represent one cat's growth. Unscanned linked photos keep their
            // date-only eligibility in the nil-asset branch above.
            isGrowthEligible: growthBox != nil
                || (isLinkedAlbumPhoto && asset.cat.catCount <= 1),
            hasCurrentAlbumAnalysis: asset.albumAnalysisVersion
                == CatAlbumTraits.currentAnalysisVersion
                && traits?.analysisVersion == CatAlbumTraits.currentAnalysisVersion,
            // 11/14: a linked album or an explicit include is the user's word.
            isConfidentCat: isLinkedAlbumPhoto
                || membership?.decision == .included
                || viewModel.isConfidentCatForPicks(asset)
        )
    }

    private func catProfilePhotoPresentation(
        _ asset: AssetRecord?,
        localIdentifier: String,
        creationDate: Date?,
        membership: CatAssetProfileMembership?,
        assignedProfileIdentifiers: Set<String>
    ) -> CatProfilePhotoPresentation {
        guard let asset else {
            return CatProfilePhotoPresentation(
                localIdentifier: localIdentifier,
                creationDate: creationDate,
                assignedProfileIdentifiers: assignedProfileIdentifiers
            )
        }
        let subjectBoundingBox = membership?.decision == .included
            ? membership?.subjectBoundingBox
            : nil
        let currentBox = CatProfileBoundingBoxSelector.select(
            from: asset.resolvedCatBoundingBoxes.boundingBoxes,
            detectedCatCount: asset.cat.catCount,
            subjectBoundingBox: subjectBoundingBox
        )
        return CatProfilePhotoPresentation(
            localIdentifier: asset.localIdentifier,
            creationDate: creationDate,
            catBoundingBox: (currentBox ?? asset.cat.boundingBox)?.cgRect,
            assignedProfileIdentifiers: assignedProfileIdentifiers,
            detectedCatCount: asset.cat.catCount,
            isConfidentCat: membership?.decision == .included
                || viewModel.isConfidentCatForPicks(asset)
        )
    }

    private func profilePhotoCreationDate(
        identifier: String,
        asset: AssetRecord?
    ) -> Date? {
        asset?.creationDate ?? viewModel.profilePhotoAlbumAssetDates[identifier]
    }

    private struct ProfileIdentityProjection {
        var confirmedByProfile: [UUID: Set<String>]
        var membershipByProfile: [UUID: [String: CatAssetProfileMembership]]
        var linkedByProfile: [UUID: Set<String>]
        var assignedByAsset: [String: Set<String>]
    }

    /// Builds all effective membership indexes once per presentation pass.
    /// Album links may contain thousands of identifiers, so rendering must not
    /// repeatedly scan those arrays or the manual-membership ledger per tile.
    private func profileIdentityProjection(
        _ identity: CatHouseholdIdentityState
    ) -> ProfileIdentityProjection {
        var confirmedByProfile: [UUID: Set<String>] = [:]
        var membershipByProfile: [UUID: [String: CatAssetProfileMembership]] = [:]
        var linkedByProfile: [UUID: Set<String>] = [:]
        // The 写真 tab's index, built with the sets once per version.
        let assignedByAsset = viewModel.catProfilePhotoAssignments

        for membership in identity.memberships {
            membershipByProfile[membership.profileID, default: [:]][
                membership.assetLocalIdentifier
            ] = membership
        }
        // 11/13: the view model's per-cat sets (built once per presentation
        // version) carry the single-cat rule: with one cat profile, every
        // detected cat photo counts as its photo, minus its exclusions.
        let effective = viewModel.catProfilePhotoIdentifiers
        for profile in identity.profiles {
            let confirmed = effective[profile.id]
                ?? identity.confirmedAssetIdentifiers(for: profile.id)
            confirmedByProfile[profile.id] = confirmed
            linkedByProfile[profile.id] = Set(
                profile.photoAlbumLink?.lastKnownAssetLocalIdentifiers ?? []
            )
        }
        return ProfileIdentityProjection(
            confirmedByProfile: confirmedByProfile,
            membershipByProfile: membershipByProfile,
            linkedByProfile: linkedByProfile,
            assignedByAsset: assignedByAsset
        )
    }

    private static func lifeReference(
        from presentation: CatProfileLifeReferencePresentation?
    ) -> CatLifeReference? {
        guard let presentation,
              let date = CatLifeDate(date: presentation.date) else { return nil }
        return CatLifeReference(
            kind: presentation.kind == .birthday ? .birthday : .adoptionDay,
            date: date
        )
    }

    private static func newestPhotoFirst(
        _ lhs: PhotoPresentation,
        _ rhs: PhotoPresentation
    ) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (left?, right?) where left != right: return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhs.localIdentifier < rhs.localIdentifier
        }
    }

    private static func newestProfilePhotoFirst(
        _ lhs: CatProfilePhotoPresentation,
        _ rhs: CatProfilePhotoPresentation
    ) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (left?, right?) where left != right: return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhs.localIdentifier < rhs.localIdentifier
        }
    }

    private func effectiveAlbumState(
        catAssetCount: Int
    ) -> AlbumPresentationState {
        switch viewModel.albumStatus {
        case .idle where viewModel.snapshot.albumLocalIdentifier != nil:
            return .ready(
                photoCount: min(catAssetCount, viewModel.settings.albumMaximum),
                updatedAt: viewModel.snapshot.updatedAt
            )
        case .idle:
            return .idle
        case .updating:
            return .updating
        case let .ready(photoCount, updatedAt):
            return .ready(photoCount: photoCount, updatedAt: updatedAt)
        case let .failed(message):
            return .failed(message: message)
        }
    }

    private func photoPresentation(_ asset: AssetRecord) -> PhotoPresentation {
        let traits = asset.albumTraits
        let resolvedBoxes = asset.resolvedCatBoundingBoxes.boundingBoxes
        return PhotoPresentation(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            catBoundingBox: asset.cat.boundingBox?.cgRect,
            isLiked: asset.liked,
            likedAt: asset.likedAt,
            isPhotoLibraryFavorite: asset.isFavorite,
            albumPostures: Set(CatBoundingBoxAspectBucket.postures(
                for: resolvedBoxes
            )),
            albumContainsPerson: traits?.containsPerson,
            albumIsOuting: traits?.isOuting,
            detectedCatCount: asset.cat.catCount,
            largestCatAreaRatio: resolvedBoxes.map(\.area).max()
                ?? (asset.cat.catCount <= 1 ? asset.cat.areaRatio : nil),
            hasCurrentAlbumAnalysis: asset.albumAnalysisVersion
                == CatAlbumTraits.currentAnalysisVersion
                && traits?.analysisVersion == CatAlbumTraits.currentAnalysisVersion,
            isConfidentCat: viewModel.isConfidentCatForPicks(asset)
        )
    }

    private func updateAlbum() {
        Task {
            await viewModel.createOrUpdateAlbum()
        }
    }

    private func presentLimitedLibraryPicker() {
        guard let viewController = UIApplication.shared.topViewController else { return }
        viewModel.presentLimitedPicker(from: viewController)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var hasPhotoAccess: Bool {
        switch viewModel.authorizationStatus {
        case .authorized, .limited:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestOrOpenPhotoAccess() {
        // The app's records failed to load: load them again first, or the
        // request would silently do nothing (11/10).
        if viewModel.startupLoadFailed {
            Task {
                await viewModel.retryStartup()
                if viewModel.authorizationStatus == .notDetermined { await viewModel.requestAccess() }
            }
            return
        }
        switch viewModel.authorizationStatus {
        case .notDetermined:
            Task { await viewModel.requestAccess() }
        case .denied, .restricted:
            openSystemSettings()
        case .authorized, .limited:
            break
        @unknown default:
            openSystemSettings()
        }
    }

    private var onboardingState: OnboardingPresentationState {
        OnboardingPresentationState(
            persistedResumePageIndex: onboardingResumePageIndex,
            persistedCompletedVersion: onboardingCompletedVersion,
            offersPlus: PlusOfferAvailability.isConfigured && !skipsPlusOfferForMember
        )
    }

    /// A Plus member (a reinstall) skips the Plus page. Someone already on it
    /// keeps it, so buying there does not move the page back.
    private var skipsPlusOfferForMember: Bool {
        membershipAccess.hasPersonalPlus()
            && onboardingResumePageIndex < OnboardingPresentationPage.plusOffer.rawValue
    }

    private var onboardingPage: Binding<OnboardingPresentationPage> {
        Binding(
            get: {
                onboardingState.currentPage ?? .purpose
            },
            set: { page in
                var state = onboardingState
                guard let currentPage = state.currentPage,
                      currentPage != page else { return }

                switch (currentPage, page) {
                case (.purpose, .photoPermission),
                     (.photoPermission, .scanResult),
                     (.scanResult, .widgetGuide):
                    state.advance()
                case (.photoPermission, .widgetGuide):
                    state.skipPhotoPermission()
                case (.scanResult, .photoPermission):
                    state.reconcilePhotoAuthorization(isReadable: false)
                default:
                    return
                }
                persistOnboardingState(state)
                if page != .scanResult {
                    onboardingScanErrorMessage = nil
                    viewModel.clearError()
                }
            }
        )
    }

    /// 「ホーム画面で置いてきます」 or 「あとで」 on the Widget guide (or a
    /// purchase on a resumed Plus page). The first run ends in the 写真 tab,
    /// where the found cats are (11/10); Plus is offered later, once.
    private func completeOnboarding() {
        let page = onboardingState.currentPage
        let entersPhotos = hasPhotoAccess
        startsInPhotosAfterOnboarding = entersPhotos
        var state = onboardingState
        state.advance()
        persistOnboardingState(state, entersPhotos: entersPhotos)
        // Keep the former first-run flag current so a rollback cannot show the
        // legacy scan-result gate after the four-page flow has completed.
        hasSeenInitialScanResult = true
        if page == .plusOffer {
            FirstPlusOfferPolicy.noteShown()
        }
        widgetInstallationChecker.refresh()
    }

    /// One tap past a resumed Plus page. Nothing is purchased.
    private func skipOnboardingPlusOffer() {
        let entersPhotos = hasPhotoAccess
        startsInPhotosAfterOnboarding = entersPhotos
        var state = onboardingState
        state.skipPlusOffer()
        persistOnboardingState(state, entersPhotos: entersPhotos)
        // As 「完了」 does: the guide ending must not leave the legacy scan
        // result screen to show on every launch (11/6).
        hasSeenInitialScanResult = true
        // This was the first Plus offer; it is not offered again later.
        FirstPlusOfferPolicy.noteShown()
    }

    private func completeOnboardingWithoutPhotoAccess() {
        // 11/10: the 写真 tab, where its one card asks for access again.
        startsInPhotosAfterOnboarding = true
        var state = onboardingState
        state.skipPhotoPermission()
        persistOnboardingState(state, entersPhotos: true)
        // "あとで" means entering the app without Photos access. Do not send
        // the user through a Widget guide they cannot verify yet.
        // Home remains the recovery point and explains how to grant access.
        hasSeenInitialScanResult = true
        onboardingScanErrorMessage = nil
        viewModel.clearError()
        widgetInstallationChecker.refresh()
    }

    /// Joined a まど or the family notebook from a link during the first run.
    /// skipPhotoPermission only acts on the Photos page, and a link opened
    /// right after installing arrives on the first page (11/6).
    private func completeOnboardingForInvitation() {
        var state = onboardingState
        state.finishForInvitation()
        persistOnboardingState(state)
        hasSeenInitialScanResult = true
        onboardingScanErrorMessage = nil
        viewModel.clearError()
        widgetInstallationChecker.refresh()
    }

    /// 「あとで」 (or 「はじめる」 with no cat) on the scan page. Completion does
    /// not mark a Widget as installed. A found photo no longer ends the first
    /// run (11/12): it opens over the scan page.
    private func completeOnboardingWithoutWidgetPhoto() {
        let entersPhotos = hasPhotoAccess
        startsInPhotosAfterOnboarding = entersPhotos
        var state = onboardingState
        state.completeWithoutWidgetPhoto()
        persistOnboardingState(state, entersPhotos: entersPhotos)
        hasSeenInitialScanResult = true
        onboardingScanErrorMessage = nil
        viewModel.clearError()
        widgetInstallationChecker.refresh()
    }

    /// `entersPhotos`: this step lands in the 写真 tab (not a joined まど).
    private func persistOnboardingState(_ state: OnboardingPresentationState, entersPhotos: Bool = false) {
        if OnboardingPresentationPersistence.endsFirstRun(from: onboardingCompletedVersion,
                                                          to: state.completedVersion) {
            // Usage (11/7): once, on the step that finishes the first run.
            UsageCounter.shared.count(.onboardingCompleted)
            // 11/12: every way out of the first run counts for the first Plus
            // offer, not only the Widget guide, and the second opening
            // returns to the 写真 tab instead of アルバム.
            FirstPlusOfferPolicy.noteFirstRunEnded()
            if entersPhotos { FirstRunTabMemory.rememberPhotosTab() }
        }
        onboardingResumePageIndex = state.resumePageIndex
        onboardingCompletedVersion = state.completedVersion
    }

    private func dismissWidgetPlacementGuide() {
        showsWidgetPlacementGuide = false
        widgetInstallationChecker.refresh()
    }

    /// 「写真を見る」 on the 「置けました」 screen: the Widget is on the Home
    /// Screen and the first run ends in the 写真 tab. Coming back from the
    /// Home Screen only shows that screen; it never advances by itself, so no
    /// Plus page follows the placement (11/10).
    private func completeWidgetPlacementGuideIfNeeded() {
        showsWidgetPlacementGuide = false

        var state = onboardingState
        guard state.currentPage == .widgetGuide else { return }
        let entersPhotos = hasPhotoAccess
        startsInPhotosAfterOnboarding = entersPhotos
        state.advance()
        // The first Plus offer becomes due in persistOnboardingState.
        persistOnboardingState(state, entersPhotos: entersPhotos)
        hasSeenInitialScanResult = true
    }
}

@MainActor
/// The per-cat presentations of `mainTabContent` (11/14), kept while every
/// input in `Key` is unchanged. Not published: reading never re-draws.
private final class ProfilePresentationCache: ObservableObject {
    struct Key: Equatable {
        var version: LibraryPresentationVersion
        var hasPhotoAccess: Bool
        var identity: CatHouseholdIdentityState?
        var received: Set<String>
        var sourceAlbums: [PhotoSourceAlbumOption]
        var unavailableAlbums: Set<String>
        var albumDates: [String: Date]
        var care: CatCareState?
        var lifeReference: CatLifeReference?
        var excluded: [ExcludedCatAsset]
        var isFinalScan: Bool
    }

    struct Values {
        var profiles: CatProfilesPresentation
        var albumPhotos: [String: [PhotoPresentation]]
        var readableIdentifiers: Set<String>
        var detectionSample: DetectionAccuracySamplePresentation
        var recoverySample: DetectionAccuracySamplePresentation
    }

    private var cached: (key: Key, values: Values)?

    func values(for key: Key, make: () -> Values) -> Values {
        if let cached, cached.key == key { return cached.values }
        let values = make()
        cached = (key, values)
        return values
    }
}

@MainActor
private final class PhotoPresentationCache: ObservableObject {
    struct Projection {
        var libraryPhotos: [PhotoPresentation]
        var catPhotos: [PhotoPresentation]
        var likedPhotos: [PhotoPresentation]
        var catAssets: [AssetRecord]
        var assetsByIdentifier: [String: AssetRecord]
    }

    private struct Key: Equatable {
        var version: LibraryPresentationVersion
        var visibleAssetCount: Int
        var sourceAssetCount: Int
    }

    private var cachedKey: Key?
    private var cachedProjection = Projection(
        libraryPhotos: [],
        catPhotos: [],
        likedPhotos: [],
        catAssets: [],
        assetsByIdentifier: [:]
    )

    func projection(
        snapshot: LibrarySnapshot,
        sourceSnapshot: LibrarySnapshot,
        version: LibraryPresentationVersion,
        transform: (AssetRecord) -> PhotoPresentation
    ) -> Projection {
        let key = Key(
            version: version,
            visibleAssetCount: snapshot.assets.count,
            sourceAssetCount: sourceSnapshot.assets.count
        )
        guard cachedKey != key else { return cachedProjection }

        let fingerprint = snapshot.settings.analysisFingerprint
        var libraryPhotos: [PhotoPresentation] = []
        var catPhotos: [PhotoPresentation] = []
        var likedPhotos: [PhotoPresentation] = []
        var catAssets: [AssetRecord] = []
        libraryPhotos.reserveCapacity(snapshot.assets.count)
        catPhotos.reserveCapacity(snapshot.assets.count / 8)
        for asset in snapshot.assets {
            let presentation = transform(asset)
            libraryPhotos.append(presentation)
            if asset.isCatCandidate,
               asset.analysisFingerprint == fingerprint {
                catPhotos.append(presentation)
                catAssets.append(asset)
            }
        }
        // "思い出" is a deliberate, global collection. A user's selected
        // scan-source album filters automatic candidates, but must not hide a
        // Photos asset explicitly imported from a private window.
        likedPhotos = sourceSnapshot.assets.compactMap { asset in
            asset.liked ? transform(asset) : nil
        }
        likedPhotos.sort { first, second in
            LikedPhotoOrderingPolicy.comesBefore(
                firstIdentifier: first.localIdentifier,
                firstLikedAt: first.likedAt,
                secondIdentifier: second.localIdentifier,
                secondLikedAt: second.likedAt
            )
        }
        cachedProjection = Projection(
            libraryPhotos: libraryPhotos,
            catPhotos: catPhotos,
            likedPhotos: likedPhotos,
            catAssets: catAssets,
            assetsByIdentifier: Dictionary(
                uniqueKeysWithValues: sourceSnapshot.assets.map {
                    ($0.localIdentifier, $0)
                }
            )
        )
        cachedKey = key
        return cachedProjection
    }
}

private struct PresentedError: Identifiable {
    let id = UUID()
    let message: String
}

private extension UIApplication {
    var topViewController: UIViewController? {
        let scenes = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let root = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        return root?.topPresentedViewController
    }
}

private extension UIViewController {
    var topPresentedViewController: UIViewController {
        if let presentedViewController {
            return presentedViewController.topPresentedViewController
        }
        if let navigationController = self as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return visibleViewController.topPresentedViewController
        }
        if let tabBarController = self as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return selectedViewController.topPresentedViewController
        }
        return self
    }
}
