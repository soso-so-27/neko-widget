import Foundation
import Photos
import SwiftUI
import UIKit

@MainActor
struct AppRootView: View {
    @ObservedObject var viewModel: AppViewModel

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenInitialScanResult.v1") private var hasSeenInitialScanResult = false
    @AppStorage(OnboardingPresentationPersistence.completedVersionKey)
    private var onboardingCompletedVersion = 0
    @AppStorage(OnboardingPresentationPersistence.resumePageIndexKey)
    private var onboardingResumePageIndex = 0
    @StateObject private var widgetInstallationChecker = WidgetInstallationChecker()
    @State private var presentedError: PresentedError?
    @State private var showsWidgetPlacementGuide = false
    @State private var onboardingScanErrorMessage: String?

    var body: some View {
        Group {
            if OnboardingPresentationPersistence.requiresPresentation(
                completedVersion: onboardingCompletedVersion
            ) {
                onboardingContent
            } else {
                regularContent
            }
        }
        .task {
            widgetInstallationChecker.refresh()
            await viewModel.start()
        }
        .onChange(of: viewModel.isScanning, initial: true) { _, isScanning in
            UIApplication.shared.isIdleTimerDisabled = isScanning && scenePhase == .active
        }
        .onOpenURL { url in
            Task { @MainActor in
                // App Intent state lives in the App Group. Apply it before
                // routing so the opened photo and the global total cannot show
                // the pre-tap value while waiting for a library scan.
                await viewModel.syncLikesForPresentation(trigger: "deeplink")
                viewModel.handleURL(url)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                UIApplication.shared.isIdleTimerDisabled = viewModel.isScanning
                widgetInstallationChecker.refresh()
                Task { await viewModel.syncOnActive() }
            case .inactive, .background:
                UIApplication.shared.isIdleTimerDisabled = false
                // Vision batches are intentionally cancellable. Do not keep decoding photos
                // after the user leaves the app; the next active transition resumes/syncs.
                viewModel.suspendScan()
            @unknown default:
                viewModel.suspendScan()
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
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
                title: Text("完了できませんでした"),
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
            scan: scanPresentation,
            scanErrorMessage: onboardingScanErrorMessage,
            isLimitedAccess: viewModel.isLimitedAccess,
            requestPhotoAccess: {
                Task { await viewModel.requestAccess() }
            },
            openPhotoSettings: openSystemSettings,
            chooseMorePhotos: presentLimitedLibraryPicker,
            rescan: {
                onboardingScanErrorMessage = nil
                viewModel.clearError()
                Task { await viewModel.rescan() }
            },
            finish: completeOnboarding
        )
    }

    @ViewBuilder
    private var authorizedContent: some View {
        if !hasSeenInitialScanResult {
            InitialScanView(
                scan: scanPresentation,
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

    private var mainTabContent: some View {
        MainTabView(
            currentPhoto: hasPhotoAccess
                ? viewModel.currentAsset.map(photoPresentation)
                : nil,
            likedPhotos: hasPhotoAccess
                ? viewModel.likedAssets.map(photoPresentation)
                : [],
            catPhotos: hasPhotoAccess
                ? viewModel.catAssets.map(photoPresentation)
                : [],
            libraryPhotos: hasPhotoAccess
                ? viewModel.visibleLibraryAssets.map(photoPresentation)
                : [],
            scan: hasPhotoAccess ? scanPresentation : ScanPresentation(),
            albumState: hasPhotoAccess ? effectiveAlbumState : .idle,
            settings: settingsPresentation,
            detectionAccuracySample: hasPhotoAccess
                ? detectionAccuracySamplePresentation
                : .init(),
            excludedCatPhotos: hasPhotoAccess ? excludedCatPhotoPresentations : [],
            photoSourceAlbums: hasPhotoAccess ? viewModel.photoSourceAlbums : [],
            photoSourceStatus: hasPhotoAccess ? viewModel.photoSourceStatus : .allLibrary,
            catProfilesPresentation: hasPhotoAccess
                ? catProfilesPresentation
                : CatProfilesPresentation(),
            profileAlbumPhotos: hasPhotoAccess ? profileAlbumPhotos : [:],
            catProfilesActions: catProfilesActions,
            hasPhotoAccess: hasPhotoAccess,
            isLimitedAccess: hasPhotoAccess && viewModel.isLimitedAccess,
            isScanning: hasPhotoAccess && viewModel.isScanning,
            shouldOfferWidgetPlacementGuide: widgetInstallationChecker
                .shouldOfferPlacementGuide,
            widgetIntervalMinutes: viewModel.settings.widgetEntryIntervalMinutes,
            deepLinkedPhotoIdentifier: $viewModel.selectedAssetIdentifier,
            deepLinkedPhotoShownAt: $viewModel.selectedAssetShownAt,
            chooseMorePhotos: presentLimitedLibraryPicker,
            requestPhotoAccess: requestOrOpenPhotoAccess,
            showWidgetPlacementGuide: {
                showsWidgetPlacementGuide = true
            },
            toggleLike: { identifier in
                Task { await viewModel.toggleLike(id: identifier) }
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
            saveSettings: { settings in
                await viewModel.updateSettings(coreSettings(from: settings))
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
            }
        )
    }

    private var scanPresentation: ScanPresentation {
        let state = viewModel.scanState
        var presentation = ScanPresentation(
            scannedAssets: state.scannedAssets,
            totalAssets: state.totalAssets,
            deferredAssets: state.deferredAssets,
            isScanning: viewModel.isScanning,
            isPaused: state.phase == .cancelled,
            lastScannedAt: state.lastScannedAt,
            isGroupedAlbumUpgrade: state.purpose == .groupedAlbumUpgrade
        )

        switch state.resultKind {
        case .none:
            break
        case .provisional:
            presentation.preliminaryCatAssets = viewModel.catAssets.count
            presentation.preliminaryOldestDate = viewModel.oldestCatPhotoDate
        case .final:
            presentation.finalCatAssets = viewModel.catAssets.count
            presentation.finalOldestDate = viewModel.oldestCatPhotoDate
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

    private var excludedCatPhotoPresentations: [ExcludedCatPhotoPresentation] {
        let assetsByIdentifier = Dictionary(
            uniqueKeysWithValues: viewModel.snapshot.assets.map {
                ($0.localIdentifier, $0)
            }
        )
        return viewModel.excludedCatAssets.map { exclusion in
            ExcludedCatPhotoPresentation(
                localIdentifier: exclusion.localIdentifier,
                creationDate: assetsByIdentifier[exclusion.localIdentifier]?.creationDate,
                excludedAt: exclusion.excludedAt
            )
        }
    }

    private var profileAlbumPhotos: [String: [PhotoPresentation]] {
        guard let identity = viewModel.catHouseholdIdentity else { return [:] }
        let assetsByIdentifier = Dictionary(
            uniqueKeysWithValues: viewModel.catAssets.map { ($0.localIdentifier, $0) }
        )
        var result: [String: [PhotoPresentation]] = [:]
        for profile in identity.profiles {
            let memberships = identity.memberships.filter {
                $0.profileID == profile.id && $0.decision == .included
            }
            result[profile.id.uuidString] = memberships.compactMap { membership in
                guard let asset = assetsByIdentifier[membership.assetLocalIdentifier] else {
                    return nil
                }
                return profilePhotoPresentation(asset, membership: membership)
            }.sorted(by: Self.newestPhotoFirst)
        }
        return result
    }

    private var catProfilesPresentation: CatProfilesPresentation {
        guard let identity = viewModel.catHouseholdIdentity else {
            return CatProfilesPresentation(
                postureDiagnostics: postureDiagnosticsPresentation
            )
        }
        let assets = viewModel.catAssets
        let assetsByIdentifier = Dictionary(
            uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) }
        )
        let includedByAsset = Dictionary(grouping: identity.memberships.filter {
            $0.decision == .included
        }, by: \.assetLocalIdentifier).mapValues { memberships in
            Set(memberships.map { $0.profileID.uuidString })
        }
        let profiles = identity.profiles.map { profile -> CatProfilePresentation in
            let memberships = identity.memberships.filter {
                $0.profileID == profile.id && $0.decision == .included
            }
            let confirmed = memberships.compactMap { membership -> CatProfilePhotoPresentation? in
                guard let asset = assetsByIdentifier[membership.assetLocalIdentifier] else {
                    return nil
                }
                return catProfilePhotoPresentation(
                    asset,
                    membership: membership,
                    assignedProfileIdentifiers: includedByAsset[asset.localIdentifier] ?? []
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
            return CatProfilePresentation(
                identifier: profile.id.uuidString,
                name: profile.displayName,
                coverPhoto: confirmed.first,
                confirmedPhotos: confirmed,
                lifeReference: lifeReference,
                similarityReferencePhotoCount: memberships.lazy.filter {
                    $0.isSimilarityReference
                }.count
            )
        }

        let assignedIdentifiers = Set(identity.memberships.lazy.filter {
            $0.decision == .included
        }.map(\.assetLocalIdentifier))
        let unassigned = assets.filter {
            !assignedIdentifiers.contains($0.localIdentifier)
        }.map { asset in
            CatProfilePhotoPresentation(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                catBoundingBox: asset.cat.boundingBox?.cgRect,
                assignedProfileIdentifiers: [],
                detectedCatCount: asset.cat.catCount
            )
        }.sorted(by: Self.newestProfilePhotoFirst)

        let allAssetsByIdentifier = Dictionary(
            uniqueKeysWithValues: viewModel.snapshot.assets.map {
                ($0.localIdentifier, $0)
            }
        )
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
                creationDate: allAssetsByIdentifier[excluded.localIdentifier]?.creationDate
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
            unassignedPhotos: unassigned,
            similarityCandidates: viewModel.catSimilarityCandidateInstances,
            legacyExcludedPhotos: legacyExcluded,
            legacyLifeReference: legacyLifeReference,
            postureDiagnostics: postureDiagnosticsPresentation
        )
    }

    private var postureDiagnosticsPresentation: CatPostureDiagnosticsPresentation {
        let distribution = CatBoundingBoxAspectDistribution(
            records: viewModel.catAssets
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
            createProfile: { draft in
                let reference = Self.lifeReference(from: draft.lifeReference)
                await viewModel.createCatProfile(
                    displayName: draft.name,
                    lifeReference: reference,
                    lifeReferenceIsApproximate: draft.lifeReference?.isApproximate == true,
                    referenceAssetIdentifier: draft.referencePhotoIdentifier
                )
            },
            updateName: { identifier, name in
                guard let profileID = UUID(uuidString: identifier) else { return }
                await viewModel.updateCatProfileName(
                    profileID: profileID,
                    displayName: name
                )
            },
            updateLifeReference: { identifier, reference in
                guard let profileID = UUID(uuidString: identifier) else { return }
                await viewModel.updateCatProfileLifeReference(
                    profileID: profileID,
                    reference: Self.lifeReference(from: reference),
                    isApproximate: reference?.isApproximate == true
                )
            },
            confirmProfileMembership: { identifier, photoIdentifiers in
                guard let profileID = UUID(uuidString: identifier) else { return }
                await viewModel.setCatProfileMembership(
                    profileID: profileID,
                    localIdentifiers: photoIdentifiers,
                    decision: .included
                )
            },
            removeProfileMembership: { identifier, photoIdentifiers in
                guard let profileID = UUID(uuidString: identifier) else { return }
                await viewModel.setCatProfileMembership(
                    profileID: profileID,
                    localIdentifiers: photoIdentifiers,
                    decision: .excluded
                )
            },
            replacePhotoAssignments: { input in
                let converted = input.mapValues { identifiers in
                    Set(identifiers.compactMap(UUID.init(uuidString:)))
                }
                await viewModel.replaceCatProfileAssignments(
                    profileIDsByLocalIdentifier: converted
                )
            },
            excludeFromHousehold: { identifiers in
                await viewModel.excludeFromCatCandidates(localIdentifiers: identifiers)
            },
            restoreLegacyExclusions: { identifiers in
                await viewModel.restoreCatCandidates(localIdentifiers: identifiers)
            },
            confirmSimilarityGroup: { identifier, candidates in
                guard let profileID = UUID(uuidString: identifier) else {
                    return false
                }
                return await viewModel.confirmCatSimilarityGroup(
                    profileID: profileID,
                    candidates: candidates
                )
            },
            deleteProfile: { identifier in
                guard let profileID = UUID(uuidString: identifier) else { return }
                await viewModel.deleteCatProfile(profileID: profileID)
            }
        )
    }

    private func profilePhotoPresentation(
        _ asset: AssetRecord,
        membership: CatAssetProfileMembership
    ) -> PhotoPresentation {
        let traits = asset.albumTraits
        let boxes = asset.resolvedCatBoundingBoxes.boundingBoxes
        let selectedBox = CatProfileBoundingBoxSelector.select(
            from: boxes,
            detectedCatCount: asset.cat.catCount,
            subjectBoundingBox: membership.subjectBoundingBox
        )
        let displayBox = membership.subjectBoundingBox
            ?? selectedBox
            ?? asset.cat.boundingBox
        let growthBox = membership.subjectBoundingBox
            ?? selectedBox
            ?? (asset.cat.catCount <= 1 ? asset.cat.boundingBox : nil)
        return PhotoPresentation(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            catBoundingBox: displayBox?.cgRect,
            isLiked: asset.liked,
            likedAt: asset.likedAt,
            albumPostures: Set(selectedBox.map {
                CatBoundingBoxAspectBucket.postures(for: [$0])
            } ?? []),
            albumContainsPerson: traits?.containsPerson,
            albumIsOuting: traits?.isOuting,
            largestCatAreaRatio: growthBox?.area,
            isGrowthEligible: growthBox != nil,
            hasCurrentAlbumAnalysis: asset.albumAnalysisVersion
                == CatAlbumTraits.currentAnalysisVersion
                && traits?.analysisVersion == CatAlbumTraits.currentAnalysisVersion
        )
    }

    private func catProfilePhotoPresentation(
        _ asset: AssetRecord,
        membership: CatAssetProfileMembership,
        assignedProfileIdentifiers: Set<String>
    ) -> CatProfilePhotoPresentation {
        CatProfilePhotoPresentation(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            catBoundingBox: (membership.subjectBoundingBox ?? asset.cat.boundingBox)?.cgRect,
            assignedProfileIdentifiers: assignedProfileIdentifiers,
            detectedCatCount: asset.cat.catCount
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

    private var effectiveAlbumState: AlbumPresentationState {
        switch viewModel.albumStatus {
        case .idle where viewModel.snapshot.albumLocalIdentifier != nil:
            return .ready(
                photoCount: min(viewModel.catAssets.count, viewModel.settings.albumMaximum),
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

    private func coreSettings(from presentation: SettingsPresentation) -> AppSettings {
        var settings = viewModel.settings
        settings.dateRange = presentation.range == .all ? .all : .recentYear
        settings.albumMaximum = presentation.albumLimit
        settings.confidenceThreshold = Float(presentation.confidenceThreshold)
        settings.minimumCatAreaRatio = presentation.minimumAreaRatio
        settings.catLifeReference = presentation.catLifeReference
        return settings
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
            albumPostures: Set(CatBoundingBoxAspectBucket.postures(
                for: resolvedBoxes
            )),
            albumContainsPerson: traits?.containsPerson,
            albumIsOuting: traits?.isOuting,
            // Growth can be built immediately from the primary cat detector.
            // The secondary pass replaces the union-area fallback with the
            // more precise largest-single-cat area when it is available.
            largestCatAreaRatio: traits?.largestCatAreaRatio ?? asset.cat.areaRatio,
            hasCurrentAlbumAnalysis: asset.albumAnalysisVersion
                == CatAlbumTraits.currentAnalysisVersion
                && traits?.analysisVersion == CatAlbumTraits.currentAnalysisVersion
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
            persistedCompletedVersion: onboardingCompletedVersion
        )
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
                     (.scanResult, .widgetGuide),
                     (.widgetGuide, .pawLike):
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

    private func completeOnboarding() {
        var state = onboardingState
        state.advance()
        persistOnboardingState(state)
        // Keep the former first-run flag current so a rollback cannot show the
        // legacy scan-result gate after the five-page flow has completed.
        hasSeenInitialScanResult = true
        widgetInstallationChecker.refresh()
    }

    private func persistOnboardingState(_ state: OnboardingPresentationState) {
        onboardingResumePageIndex = state.resumePageIndex
        onboardingCompletedVersion = state.completedVersion
    }

    private func dismissWidgetPlacementGuide() {
        showsWidgetPlacementGuide = false
        widgetInstallationChecker.refresh()
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
