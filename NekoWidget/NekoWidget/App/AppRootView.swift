import Foundation
import Photos
import SwiftUI
import UIKit

@MainActor
struct AppRootView: View {
    @ObservedObject var viewModel: AppViewModel

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenInitialScanResult.v1") private var hasSeenInitialScanResult = false
    @State private var presentedError: PresentedError?

    var body: some View {
        Group {
            switch viewModel.authorizationStatus {
            case .authorized, .limited:
                authorizedContent
            case .notDetermined, .denied, .restricted:
                PhotoPermissionView(
                    status: viewModel.authorizationStatus,
                    requestAccess: {
                        Task { await viewModel.requestAccess() }
                    },
                    openSettings: openSystemSettings
                )
            @unknown default:
                PhotoPermissionView(
                    status: .denied,
                    requestAccess: {},
                    openSettings: openSystemSettings
                )
            }
        }
        .task {
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
            MainTabView(
                currentPhoto: viewModel.currentAsset.map(photoPresentation),
                likedPhotos: viewModel.likedAssets.map(photoPresentation),
                catPhotos: viewModel.catAssets.map(photoPresentation),
                libraryPhotos: viewModel.visibleLibraryAssets.map(photoPresentation),
                scan: scanPresentation,
                albumState: effectiveAlbumState,
                settings: settingsPresentation,
                detectionAccuracySample: detectionAccuracySamplePresentation,
                excludedCatPhotos: excludedCatPhotoPresentations,
                photoSourceAlbums: viewModel.photoSourceAlbums,
                photoSourceStatus: viewModel.photoSourceStatus,
                isLimitedAccess: viewModel.isLimitedAccess,
                isScanning: viewModel.isScanning,
                widgetIntervalMinutes: viewModel.settings.widgetEntryIntervalMinutes,
                deepLinkedPhotoIdentifier: $viewModel.selectedAssetIdentifier,
                deepLinkedPhotoShownAt: $viewModel.selectedAssetShownAt,
                chooseMorePhotos: presentLimitedLibraryPicker,
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
                retryPendingPostureClassification: {
                    await viewModel.retryPendingPostureClassification()
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
    }

    private var scanPresentation: ScanPresentation {
        let state = viewModel.scanState
        var presentation = ScanPresentation(
            scannedAssets: state.scannedAssets,
            totalAssets: state.totalAssets,
            deferredAssets: state.deferredAssets,
            postureSecondaryPendingAssets: state.requiresFullRescan
                ? 0
                : viewModel.postureSecondaryPendingAssets,
            isScanning: viewModel.isScanning,
            isPaused: state.phase == .cancelled,
            lastScannedAt: state.lastScannedAt,
            isGroupedAlbumUpgrade: state.purpose == .groupedAlbumUpgrade
                || state.purpose == .postureRepair
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
        return PhotoPresentation(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            catBoundingBox: asset.cat.boundingBox?.cgRect,
            isLiked: asset.liked,
            likedAt: asset.likedAt,
            albumPostures: Set(traits?.postures ?? []),
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
