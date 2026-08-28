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
    @StateObject private var photoPresentationCache = PhotoPresentationCache()
    @StateObject private var momentNotificationTapMailbox = MomentNotificationTapMailbox.shared
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
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            guard SharingAPIConfiguration.current.isMediaAvailable else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: MomentForegroundRefreshPolicy.interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await viewModel.pollMomentSharingWhileActive(
                    isSceneActive: scenePhase == .active
                )
            }
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
        .onChange(of: momentNotificationTapMailbox.pendingTap, initial: true) { _, tap in
            guard let tap else { return }
            Task { @MainActor in
                await viewModel.handleMomentNotificationRoute(tap.route)
                momentNotificationTapMailbox.consume(id: tap.id)
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
            scan: scanPresentation(records: viewModel.catAssets),
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

    private var mainTabContent: some View {
        let visibleSnapshot = hasPhotoAccess
            ? viewModel.presentationSnapshot
            : .empty
        let photoProjection = photoPresentationCache.projection(
            snapshot: visibleSnapshot,
            sourceSnapshot: hasPhotoAccess ? viewModel.snapshot : .empty,
            version: viewModel.presentationVersion,
            transform: photoPresentation
        )
        let visibleCatAssets = photoProjection.catAssets
        let assetsByIdentifier = photoProjection.assetsByIdentifier
        let identity = hasPhotoAccess ? viewModel.catHouseholdIdentity : nil
        let identityProjection = identity.map { profileIdentityProjection($0) }
        let postureDiagnostics = postureDiagnosticsPresentation(
            records: visibleCatAssets
        )
        let profilesPresentation = makeCatProfilesPresentation(
            identity: identity,
            projection: identityProjection,
            assetsByIdentifier: assetsByIdentifier,
            candidateAssets: visibleCatAssets,
            postureDiagnostics: postureDiagnostics
        )
        let profilePhotos = makeProfileAlbumPhotos(
            identity: identity,
            projection: identityProjection,
            assetsByIdentifier: assetsByIdentifier
        )

        return MainTabView(
            currentPhoto: hasPhotoAccess
                ? viewModel.currentAsset.map(photoPresentation)
                : nil,
            likedPhotos: photoProjection.likedPhotos,
            catPhotos: photoProjection.catPhotos,
            libraryPhotos: photoProjection.libraryPhotos,
            scan: hasPhotoAccess
                ? scanPresentation(records: visibleCatAssets)
                : ScanPresentation(),
            albumState: hasPhotoAccess
                ? effectiveAlbumState(catAssetCount: visibleCatAssets.count)
                : .idle,
            settings: settingsPresentation,
            detectionAccuracySample: hasPhotoAccess
                ? detectionAccuracySamplePresentation
                : .init(),
            highResolutionRecoverySample: hasPhotoAccess
                ? highResolutionRecoverySamplePresentation(records: visibleCatAssets)
                : .init(),
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
            widgetIntervalMinutes: viewModel.settings.widgetEntryIntervalMinutes,
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
                try await MemoryPhotoJPEGExporter().export(
                    from: viewModel.likedAssets,
                    localIdentifier: identifier
                )
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
            }
        )
    }

    private func scanPresentation(records: [AssetRecord]) -> ScanPresentation {
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
        let profiles = identity.profiles.map { profile -> CatProfilePresentation in
            let memberships = projection.membershipByProfile[profile.id]?.values.filter {
                $0.decision == .included
            } ?? []
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
                coverPhoto: confirmed.first,
                confirmedPhotos: confirmed,
                manualCandidatePhotos: allCandidatePhotos.filter {
                    !confirmedIdentifiers.contains($0.localIdentifier)
                },
                lifeReference: lifeReference,
                photoAlbumLink: albumLink,
                similarityReferencePhotoCount: memberships.lazy.filter {
                    $0.isSimilarityReference
                }.count
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
            currentSimilarityCandidates: {
                viewModel.catSimilarityCandidateInstances
            },
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
                    return .conflict(reason: .invalidGroup)
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
                && traits?.analysisVersion == CatAlbumTraits.currentAnalysisVersion
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
            detectedCatCount: asset.cat.catCount
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
        var assignedByAsset: [String: Set<String>] = [:]

        for membership in identity.memberships {
            membershipByProfile[membership.profileID, default: [:]][
                membership.assetLocalIdentifier
            ] = membership
        }
        for profile in identity.profiles {
            let confirmed = identity.confirmedAssetIdentifiers(for: profile.id)
            confirmedByProfile[profile.id] = confirmed
            linkedByProfile[profile.id] = Set(
                profile.photoAlbumLink?.lastKnownAssetLocalIdentifiers ?? []
            )
            for identifier in confirmed {
                assignedByAsset[identifier, default: []].insert(
                    profile.id.uuidString
                )
            }
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
