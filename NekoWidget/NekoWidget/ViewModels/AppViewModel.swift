import Photos
import SwiftUI
import UIKit
import WidgetKit

extension Notification.Name {
    static let sharingMediaSyncRequested = Notification.Name(
        "jp.nekowidget.sharing.media-sync-requested"
    )
}

enum AlbumUpdateStatus: Equatable {
    case idle
    case updating
    case ready(photoCount: Int, updatedAt: Date)
    case failed(message: String)
}

private enum CatIdentityLoadState {
    case loading
    case ready
    case failed
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var snapshot: LibrarySnapshot = .empty
    @Published private(set) var scanState: ScanState = .idle
    @Published private(set) var settings: AppSettings = .default
    @Published private(set) var isScanning = false
    @Published private(set) var currentAsset: AssetRecord?
    @Published private(set) var albumStatus: AlbumUpdateStatus = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var exportedURL: URL?
    @Published private(set) var isLikeInteractionReady = false
    @Published private(set) var catCandidateCuration: CatCandidateCurationState = .empty
    @Published private(set) var catHouseholdIdentity: CatHouseholdIdentityState?
    @Published private(set) var photoSourceAlbums: [PhotoSourceAlbumOption] = []
    @Published private(set) var photoSourceStatus: PhotoSourceAlbumStatus = .allLibrary
    @Published var selectedAssetIdentifier: String?
    @Published var selectedAssetShownAt: Date?

    var isLimitedAccess: Bool { authorizationStatus == .limited }
    var catAssets: [AssetRecord] {
        canPresentCatIdentity ? candidateSnapshot(snapshot).catAssets : []
    }
    var likedAssets: [AssetRecord] {
        canPresentCatIdentity ? candidateSnapshot(snapshot).likedAssets : []
    }
    var visibleLibraryAssets: [AssetRecord] {
        canPresentCatIdentity ? candidateSnapshot(snapshot).assets : []
    }
    var excludedCatAssets: [ExcludedCatAsset] {
        guard canPresentCatIdentity else { return [] }
        if let identity = catHouseholdIdentity,
           identity.mode == .profiled {
            return identity.globalExcludedAssets
        }
        return catCandidateCuration.excludedAssets
    }
    var catProfiles: [CatProfile] { catHouseholdIdentity?.profiles ?? [] }
    var oldestCatPhotoDate: Date? { catAssets.compactMap(\.creationDate).min() }
    var postureSecondaryPendingAssets: Int {
        guard canPresentCatIdentity else { return 0 }
        PostureScanSummary(records: candidateSnapshot(snapshot).assets)
            .secondaryPendingAssets
    }
    var progress: Double { scanState.progress }
    var isQuickResultReady: Bool { scanState.isQuickResultReady }
    var isComplete: Bool { scanState.isComplete }

    func catAssets(profileID: UUID) -> [AssetRecord] {
        guard let identity = catHouseholdIdentity else { return [] }
        let included = Set(identity.memberships.lazy.filter {
            $0.profileID == profileID && $0.decision == .included
        }.map(\.assetLocalIdentifier))
        return catAssets.filter { included.contains($0.localIdentifier) }
    }

    func profileMemberships(for localIdentifier: String) -> [CatAssetProfileMembership] {
        catHouseholdIdentity?.memberships.filter {
            $0.assetLocalIdentifier == localIdentifier
        } ?? []
    }

    private let authorizationService: PhotoAuthorizationService
    private let scanner: PhotoLibraryScanner
    private let albumService: PhotoAlbumService
    private let widgetCacheBuilder: WidgetCacheBuilder
    private let imageLoader: PhotoImageLoader
    private let photoSelector: WeightedPhotoSelector
    private let albumSelector: AlbumCandidateSelector
    private let exporter: JSONExporter
    private let dailySharingSyncCoordinator: DailySharingSyncCoordinator
    private let store: LibraryStore?
    private let storeInitializationError: String?
    private let curationStore: CatCandidateCurationStore?
    private let curationStoreInitializationError: String?
    private let identityStore: CatHouseholdIdentityStore?
    private let identityStoreInitializationError: String?

    private var hasStarted = false
    private var hasFinishedSnapshotLoad = false
    /// Loading and failure are different: loading must preserve scanner state
    /// internally, while public candidate surfaces stay hidden. Failure also
    /// makes the internal candidate view empty so managed outputs fail closed.
    private var catIdentityLoadState: CatIdentityLoadState = .loading
    private var candidatePhotoRouteGate = CandidatePhotoRouteGate()
    private var libraryChangePending = false
    private var lastActivationSyncAt: Date?
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    /// Serializes the one-way legacy-to-profiled transition with household
    /// exclusion mutations. Without this queue, an exclusion can commit to
    /// the legacy curation actor while profile creation concurrently makes the
    /// identity ledger canonical before that exclusion is folded in.
    private var catIdentityTransitionTail: Task<Void, Never>?
    private var catIdentityTransitionSequence = 0
    /// PhotoAlbumService awaits PhotoKit and is therefore actor-reentrant. This
    /// explicit tail keeps membership reads/writes non-overlapping and ensures
    /// the newest curation generation is always applied last.
    private var managedOutputMutationTail: Task<Void, Never>?
    private var managedOutputMutationSequence = 0
    private var successfulImageLoadCount = 0
    private var sharedLikeRecords: [String: SharedLikeRecord] = [:]
    private var sharingSyncObserver: NSObjectProtocol?
    /// nil means no additional in-memory source filter. When an album is
    /// selected this is refreshed from PhotoKit before a scan, so old snapshot
    /// records outside that album disappear from candidate surfaces at once.
    private var selectedSourceAssetIdentifiers: Set<String>?

    private lazy var libraryObserver = PhotoLibraryObserver { [weak self] in
        self?.libraryChangePending = true
    }

    init() {
        authorizationService = PhotoAuthorizationService()
        authorizationStatus = authorizationService.status
        scanner = PhotoLibraryScanner()
        albumService = PhotoAlbumService()
        imageLoader = PhotoImageLoader()
        widgetCacheBuilder = WidgetCacheBuilder()
        photoSelector = WeightedPhotoSelector()
        albumSelector = AlbumCandidateSelector()
        exporter = JSONExporter()
        dailySharingSyncCoordinator = DailySharingSyncCoordinator()

        do {
            store = try LibraryStore()
            storeInitializationError = nil
            SharedLog.app.info("storage", "Shared snapshot store initialized")
        } catch {
            store = nil
            storeInitializationError = error.localizedDescription
            Self.logError(error, category: "storage", operation: "initialize_store")
        }

        do {
            curationStore = try CatCandidateCurationStore()
            curationStoreInitializationError = nil
            SharedLog.app.info("curation", "Cat candidate curation store initialized")
        } catch {
            curationStore = nil
            curationStoreInitializationError = error.localizedDescription
            Self.logError(error, category: "curation", operation: "initialize_store")
        }

        do {
            identityStore = try CatHouseholdIdentityStore()
            identityStoreInitializationError = nil
            SharedLog.app.info("cat-identity", "Cat household identity store initialized")
        } catch {
            identityStore = nil
            identityStoreInitializationError = error.localizedDescription
            Self.logError(error, category: "cat-identity", operation: "initialize_store")
        }

        SharedLog.app.info(
            "lifecycle",
            "Application model initialized",
            metadata: [
                "authorization": Self.authorizationName(authorizationStatus),
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            ]
        )
        let coordinator = dailySharingSyncCoordinator
        sharingSyncObserver = NotificationCenter.default.addObserver(
            forName: .sharingMediaSyncRequested,
            object: nil,
            queue: .main
        ) { _ in
            Task { await coordinator.synchronize(trigger: "pairing-or-consent") }
        }
    }

    deinit {
        if let sharingSyncObserver {
            NotificationCenter.default.removeObserver(sharingSyncObserver)
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        SharedLog.app.info("lifecycle", "Application startup began")

        guard await loadCatCandidateCuration() else {
            // Curation is part of the candidate authority. Recover only the
            // managed-album identifier from the snapshot so both external
            // outputs can be cleared without publishing any uncurated asset.
            if let store,
               let loaded = try? await store.load() {
                snapshot.albumLocalIdentifier = loaded.albumLocalIdentifier
            }
            catIdentityLoadState = .failed
            currentAsset = nil
            hasFinishedSnapshotLoad = true
            discardPendingDeepLink(reason: "candidate-state-unavailable")
            await clearAlbumAndWidgetOutputs(reportErrors: false)
            return
        }

        if let store {
            do {
                let loaded = try await store.load()
                applySnapshot(loaded, preservingLiveSettings: false)
                let candidateScanStateWasReconciled = snapshot.scanState
                    != loaded.scanState
                let likesChanged = synchronizeSharedLikes(
                    importLegacyLikes: true,
                    trigger: "startup"
                )
                chooseCurrentAssetIfNeeded()
                if likesChanged || candidateScanStateWasReconciled {
                    await saveSnapshot(reportErrors: false)
                }
                SharedLog.app.info(
                    "storage",
                    "Snapshot loaded",
                    metadata: [
                        "assets": "\(loaded.assets.count)",
                        "cats": "\(loaded.catAssets.count)",
                        "scanPhase": loaded.scanState.phase.rawValue
                    ]
                )
            } catch {
                setError(error)
            }
        } else if let storeInitializationError {
            errorMessage = storeInitializationError
        }
        guard await loadCatHouseholdIdentity() else {
            catIdentityLoadState = .failed
            currentAsset = nil
            hasFinishedSnapshotLoad = true
            discardPendingDeepLink(reason: "cat-identity-state-unavailable")
            await clearAlbumAndWidgetOutputs(reportErrors: false)
            return
        }
        // The snapshot was selected before the identity ledger loaded. Apply
        // household exclusions immediately so Home cannot briefly keep a
        // photo that the canonical profiled state has removed.
        chooseCurrentAssetIfNeeded()
        hasFinishedSnapshotLoad = true
        openPendingDeepLinkIfNeeded()
        Task { [dailySharingSyncCoordinator] in
            await dailySharingSyncCoordinator.synchronize(trigger: "launch")
        }

        authorizationStatus = authorizationService.status
        SharedLog.app.info(
            "permission",
            "Photo authorization checked",
            metadata: ["status": Self.authorizationName(authorizationStatus)]
        )
        guard canReadPhotos else {
            SharedLog.app.warning("permission", "Photo library is not readable")
            await clearWidgetOutput(reportErrors: false)
            return
        }
        await refreshPhotoSourceAlbums()
        // Reconcile every launch, including the empty state after the final
        // exclusion is restored. Without a persisted output revision receipt,
        // conditional rebuilding cannot distinguish that crash gap from an
        // already-current empty curation state.
        await refreshCandidateOutputsAfterCurationChange(reportErrors: false)
        libraryObserver.start()
        await syncOnActive()
    }

    func requestAccess() async {
        errorMessage = nil
        SharedLog.app.info("permission", "Photo authorization request started")
        authorizationStatus = await authorizationService.requestAuthorization()
        SharedLog.app.info(
            "permission",
            "Photo authorization request finished",
            metadata: ["status": Self.authorizationName(authorizationStatus)]
        )
        guard canReadPhotos else {
            await clearWidgetOutput(reportErrors: false)
            return
        }
        await refreshPhotoSourceAlbums()
        guard photoSourceStatus != .unavailable else { return }
        libraryObserver.start()
        libraryChangePending = true
        await launchScan(forceFullAnalysis: scanState.requiresFullRescan)
    }

    func presentLimitedPicker(from viewController: UIViewController) {
        authorizationService.presentLimitedLibraryPicker(from: viewController)
    }

    /// Foreground activation is the reliable v1 synchronization point.
    /// Any background execution is best effort and is never required for data
    /// correctness or promised to the user.
    func syncOnActive() async {
        Task { [dailySharingSyncCoordinator] in
            await dailySharingSyncCoordinator.synchronize(trigger: "foreground")
        }
        authorizationStatus = authorizationService.status
        let likesChanged = synchronizeSharedLikes(
            importLegacyLikes: true,
            trigger: "foreground"
        )
        if likesChanged {
            await saveSnapshot(reportErrors: false)
        }
        SharedLog.app.debug(
            "lifecycle",
            "Foreground synchronization requested",
            metadata: [
                "authorization": Self.authorizationName(authorizationStatus),
                "libraryChangePending": "\(libraryChangePending)"
            ]
        )
        guard canReadPhotos else {
            await clearWidgetOutput(reportErrors: false)
            return
        }
        await refreshPhotoSourceAlbums()
        libraryObserver.start()

        guard photoSourceStatus != .unavailable else {
            SharedLog.app.warning(
                "curation",
                "Selected photo source is unavailable; previous candidates retained"
            )
            return
        }

        if let lastActivationSyncAt,
           Date().timeIntervalSince(lastActivationSyncAt) < 2,
           !libraryChangePending,
           scanState.phase == .completed {
            return
        }
        lastActivationSyncAt = .now
        libraryChangePending = false
        await launchScan(forceFullAnalysis: scanState.requiresFullRescan)
    }

    func rescan() async {
        guard canReadPhotos else {
            setError(NekoWidgetError.photoAccessDenied)
            return
        }
        errorMessage = nil
        settings.analysisRevision += 1
        SharedLog.app.info(
            "scan",
            "Full rescan requested by user",
            metadata: ["analysisRevision": "\(settings.analysisRevision)"]
        )
        snapshot.settings = settings
        scanState.requiresFullRescan = true
        scanState.purpose = .manualRescan
        snapshot.scanState = scanState
        await saveSnapshot(reportErrors: false)
        await launchScan(forceFullAnalysis: true)
    }

    /// Retries only missing/stale grouped-album traits for already-known cat
    /// photos. It does not increment the detector revision or invalidate the
    /// current Widget/primary cat results.
    func retryPendingPostureClassification() async {
        guard canReadPhotos else {
            setError(NekoWidgetError.photoAccessDenied)
            return
        }
        guard !isScanning else { return }
        guard !scanState.requiresFullRescan else {
            SharedLog.app.info(
                "vision",
                "Posture retry skipped because a primary rescan is required"
            )
            return
        }

        let summary = PostureScanSummary(records: candidateSnapshot(snapshot).assets)
        guard summary.secondaryPendingAssets > 0 else {
            SharedLog.app.info(
                "vision",
                "Posture retry skipped because no secondary analysis is pending",
                metadata: summary.logMetadata
            )
            return
        }

        errorMessage = nil
        scanState.postureSummary = summary
        scanState.requiresFullRescan = false
        scanState.purpose = .postureRepair
        snapshot.scanState = scanState
        SharedLog.app.info(
            "vision",
            "Pending posture classification retry requested",
            metadata: summary.logMetadata
        )
        await saveSnapshot(reportErrors: false)
        await launchScan(forceFullAnalysis: false)
    }

    /// Explicitly re-runs only the secondary pose/face album analysis for the
    /// current candidate scope. Primary cat/no-cat decisions, detector
    /// revision, likes, Widget output, and PhotoKit assets remain untouched.
    func rerunPostureClassification() async {
        guard canReadPhotos else {
            setError(NekoWidgetError.photoAccessDenied)
            return
        }
        guard !isScanning, !scanState.requiresFullRescan else { return }
        let targetIdentifiers = Set(
            candidateSnapshot(snapshot).catAssets.map(\.localIdentifier)
        )
        guard !targetIdentifiers.isEmpty else { return }

        var updated = snapshot
        for index in updated.assets.indices
        where targetIdentifiers.contains(updated.assets[index].localIdentifier) {
            // Keep the last derived values on disk for rollback/debugging, but
            // clear the completion marker so the postureRepair router selects
            // exactly these known-cat records.
            updated.assets[index].albumAnalysisVersion = nil
        }
        updated.updatedAt = .now
        snapshot = updated
        scanState = updated.scanState
        let summary = PostureScanSummary(records: candidateSnapshot(updated).assets)
        scanState.postureSummary = summary
        scanState.requiresFullRescan = false
        scanState.purpose = .postureRepair
        snapshot.scanState = scanState
        errorMessage = nil
        SharedLog.app.info(
            "vision",
            "Posture-only reclassification requested",
            metadata: [
                "analysisVersion": "\(CatAlbumTraits.currentAnalysisVersion)",
                "targetCats": "\(targetIdentifiers.count)"
            ]
        )
        await saveSnapshot(reportErrors: false)
        await launchScan(forceFullAnalysis: false)
    }

    func suspendScan() {
        guard isScanning else { return }
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        libraryChangePending = true
        SharedLog.app.info(
            "scan",
            "Scan suspended because the app left the foreground",
            metadata: [
                "generation": "\(scanGeneration)",
                "scanned": "\(scanState.scannedAssets)",
                "total": "\(scanState.totalAssets)"
            ]
        )

        var cancelled = scanState
        cancelled.phase = .cancelled
        scanState = cancelled
        snapshot.scanState = cancelled
        snapshot.updatedAt = .now
        Task { [snapshot, store] in
            try? await store?.save(snapshot)
        }
    }

    func toggleLike(id localIdentifier: String) async {
        guard let index = snapshot.assets.firstIndex(where: {
            $0.localIdentifier == localIdentifier
        }) else { return }

        errorMessage = nil
        let fallbackIsLiked = snapshot.assets[index].liked
        let mutation: SharedLikeMutation
        do {
            mutation = try SharedLikeStore.toggle(
                localIdentifier: localIdentifier,
                fallbackIsLiked: fallbackIsLiked,
                at: .now,
                source: "app"
            )
        } catch {
            Self.logError(error, category: "like", operation: "toggle_shared_like")
            setError(error)
            return
        }

        sharedLikeRecords[localIdentifier] = mutation.record
        refreshLikeInteractionState()
        // Publish one new value instead of mutating a field inside the
        // @Published snapshot. The explicit assignment is what makes every
        // count/list backed by `likedAssets` refresh in the same run-loop turn.
        var updatedSnapshot = snapshot
        Self.applySharedLikeRecord(mutation.record, at: index, to: &updatedSnapshot)
        updatedSnapshot.updatedAt = .now
        snapshot = updatedSnapshot
        SharedLog.app.info(
            "like",
            "Like state changed",
            metadata: [
                "asset": SharedLog.shortHash(localIdentifier),
                "changedAt": Self.iso8601String(mutation.record.changedAt),
                "liked": "\(mutation.record.isLiked)",
                "previousLiked": "\(mutation.previousIsLiked)",
                "source": "app"
            ]
        )
        refreshCurrentAsset()
        await saveSnapshot(reportErrors: true)

        // A like changes the 3x display weight, so refresh the principal v1
        // display surface immediately.
        await rebuildWidgetCache(reportErrors: false)
    }

    func selectAsset(id localIdentifier: String?) {
        selectedAssetIdentifier = localIdentifier
    }

    func refreshPhotoSourceAlbums() async {
        selectedSourceAssetIdentifiers = catCandidateCuration
            .lastKnownSourceAssetIdentifierSet
        guard canReadPhotos else {
            photoSourceAlbums = []
            photoSourceStatus = catCandidateCuration.usesSelectedAlbum
                ? .unavailable
                : .allLibrary
            return
        }
        let albums = PhotoSourceAlbumCatalog.availableAlbums(
            excluding: snapshot.albumLocalIdentifier
        )
        photoSourceAlbums = albums
        photoSourceStatus = PhotoSourceAlbumCatalog.status(
            sourceAlbumIdentifier: catCandidateCuration.sourceAlbumIdentifier,
            in: albums
        )
        if let sourceAlbumIdentifier = catCandidateCuration.sourceAlbumIdentifier,
           photoSourceStatus != .unavailable {
            do {
                let accessibleIdentifiers = try PhotoSourceAlbumCatalog
                    .accessibleImageAssetIdentifiers(
                        sourceAlbumIdentifier: sourceAlbumIdentifier
                    )
                // With limited Photos access, an existing album can look empty
                // because none of its members are currently authorized. PhotoKit
                // cannot distinguish that from a genuinely empty album. Preserve
                // the last scoped result instead of destructively publishing an
                // empty scan; the user can expand access or select another source.
                if authorizationStatus == .limited,
                   accessibleIdentifiers.isEmpty {
                    photoSourceStatus = .unavailable
                } else {
                    if let curationStore {
                        do {
                            let refreshed = try await curationStore
                                .refreshingSourceMembership(
                                    localIdentifier: sourceAlbumIdentifier,
                                    assetIdentifiers: Array(accessibleIdentifiers)
                                )
                            if applyNewestCurationState(refreshed) {
                                await acknowledgeLegacyCurationState(refreshed)
                            }
                        } catch {
                            // Keep this session narrowed to the successfully
                            // resolved set, but surface that crash-safe storage
                            // could not be refreshed.
                            selectedSourceAssetIdentifiers = accessibleIdentifiers
                            Self.logError(
                                error,
                                category: "curation",
                                operation: "refresh_source_membership"
                            )
                            setError(error)
                        }
                    } else {
                        selectedSourceAssetIdentifiers = accessibleIdentifiers
                    }
                }
            } catch {
                photoSourceStatus = .unavailable
                // Preserve a previous, narrower membership set if the album
                // disappears between catalog and asset fetch.
            }
        } else if !catCandidateCuration.usesSelectedAlbum {
            selectedSourceAssetIdentifiers = nil
        }
        reconcileCandidatePostureState()
        chooseCurrentAssetIfNeeded()
    }

    /// Removes candidates from app-managed surfaces only. PhotoKit is never
    /// mutated, and likes remain in their independent user-state ledger.
    func excludeFromCatCandidates(localIdentifiers: [String]) async {
        await serializeCatIdentityTransition {
            await self.performExcludeFromCatCandidates(
                localIdentifiers: localIdentifiers
            )
        }
    }

    private func performExcludeFromCatCandidates(
        localIdentifiers: [String]
    ) async {
        let identifiers = Array(Set(localIdentifiers)).filter { !$0.isEmpty }
        guard !identifiers.isEmpty else { return }
        let legacyCurationIsCanonical = catHouseholdIdentity?.mode == .legacyUnscoped
        if catHouseholdIdentity != nil, !legacyCurationIsCanonical {
            do {
                _ = try await mutateCatHouseholdIdentity { state in
                    state.setGloballyExcluded(
                        true,
                        assetLocalIdentifiers: identifiers
                    )
                }
            } catch {
                Self.logError(error, category: "cat-identity", operation: "exclude_global")
                setError(error)
                return
            }
        }
        guard let curationStore else {
            if legacyCurationIsCanonical {
                errorMessage = curationStoreInitializationError
                    ?? "除外設定を保存できません。アプリを開き直して再度お試しください。"
                return
            }
            // In profiled mode the identity ledger is canonical. Continue to
            // update visible outputs even if the compatibility mirror is gone.
            if catHouseholdIdentity != nil {
                chooseCurrentAssetIfNeeded()
                await refreshCandidateOutputsAfterCurationChange()
            }
            return
        }
        do {
            let updated = try await curationStore.excluding(
                localIdentifiers: identifiers
            )
            let appliedReturnedState = applyNewestCurationState(updated)
            if legacyCurationIsCanonical {
                await acknowledgeLegacyCurationState(
                    appliedReturnedState ? updated : catCandidateCuration
                )
            }
            reconcileCandidatePostureState()
            SharedLog.app.info(
                "curation",
                "Photos excluded from cat candidate surfaces",
                metadata: [
                    "changedRequestCount": "\(identifiers.count)",
                    "excludedTotal": "\(catCandidateCuration.excludedAssets.count)"
                ]
            )
            chooseCurrentAssetIfNeeded()
            await refreshCandidateOutputsAfterCurationChange()
        } catch {
            Self.logError(error, category: "curation", operation: "exclude_candidates")
            setError(error)
            if catHouseholdIdentity != nil {
                chooseCurrentAssetIfNeeded()
                await refreshCandidateOutputsAfterCurationChange(reportErrors: false)
            }
        }
    }

    func restoreCatCandidates(localIdentifiers: [String]) async {
        await serializeCatIdentityTransition {
            await self.performRestoreCatCandidates(
                localIdentifiers: localIdentifiers
            )
        }
    }

    private func performRestoreCatCandidates(
        localIdentifiers: [String]
    ) async {
        let identifiers = Array(Set(localIdentifiers)).filter { !$0.isEmpty }
        guard !identifiers.isEmpty else { return }
        let legacyCurationIsCanonical = catHouseholdIdentity?.mode == .legacyUnscoped
        if catHouseholdIdentity != nil, !legacyCurationIsCanonical {
            do {
                _ = try await mutateCatHouseholdIdentity { state in
                    state.setGloballyExcluded(
                        false,
                        assetLocalIdentifiers: identifiers
                    )
                }
            } catch {
                Self.logError(error, category: "cat-identity", operation: "restore_global")
                setError(error)
                return
            }
        }
        guard let curationStore else {
            if legacyCurationIsCanonical {
                errorMessage = curationStoreInitializationError
                    ?? "除外設定を保存できません。アプリを開き直して再度お試しください。"
                return
            }
            if catHouseholdIdentity != nil {
                chooseCurrentAssetIfNeeded()
                await refreshCandidateOutputsAfterCurationChange()
            }
            return
        }
        do {
            let updated = try await curationStore.restoring(
                localIdentifiers: identifiers
            )
            let appliedReturnedState = applyNewestCurationState(updated)
            if legacyCurationIsCanonical {
                await acknowledgeLegacyCurationState(
                    appliedReturnedState ? updated : catCandidateCuration
                )
            }
            reconcileCandidatePostureState()
            SharedLog.app.info(
                "curation",
                "Photos restored to cat candidate surfaces",
                metadata: [
                    "changedRequestCount": "\(identifiers.count)",
                    "excludedTotal": "\(catCandidateCuration.excludedAssets.count)"
                ]
            )
            chooseCurrentAssetIfNeeded()
            await refreshCandidateOutputsAfterCurationChange()
        } catch {
            Self.logError(error, category: "curation", operation: "restore_candidates")
            setError(error)
            if catHouseholdIdentity != nil {
                chooseCurrentAssetIfNeeded()
                await refreshCandidateOutputsAfterCurationChange(reportErrors: false)
            }
        }
    }

    func selectPhotoSourceAlbum(localIdentifier: String?) async {
        guard canReadPhotos, let curationStore else {
            setError(NekoWidgetError.photoAccessDenied)
            return
        }
        await refreshPhotoSourceAlbums()
        if let localIdentifier,
           !photoSourceAlbums.contains(where: { $0.localIdentifier == localIdentifier }) {
            setError(CatCandidateCurationError.selectedSourceUnavailable)
            return
        }
        do {
            let resolvedIdentifiers: [String]?
            if let localIdentifier {
                let accessibleIdentifiers = try PhotoSourceAlbumCatalog
                    .accessibleImageAssetIdentifiers(
                        sourceAlbumIdentifier: localIdentifier
                    )
                guard authorizationStatus != .limited
                        || !accessibleIdentifiers.isEmpty else {
                    setError(CatCandidateCurationError.selectedSourceUnavailable)
                    return
                }
                resolvedIdentifiers = Array(accessibleIdentifiers)
            } else {
                resolvedIdentifiers = nil
            }
            let updated = try await curationStore.selectingSourceAlbum(
                localIdentifier: localIdentifier,
                assetIdentifiers: resolvedIdentifiers
            )
            let changed = updated != catCandidateCuration
            guard applyNewestCurationState(updated) else { return }
            await acknowledgeLegacyCurationState(updated)
            guard changed else { return }
            await refreshPhotoSourceAlbums()
            // A newer source mutation may have completed while PhotoKit or the
            // store actor was awaited. Never continue old-source side effects.
            guard catCandidateCuration.sourceAlbumIdentifier == localIdentifier else { return }
            guard photoSourceStatus != .unavailable else {
                chooseCurrentAssetIfNeeded()
                await refreshCandidateOutputsAfterCurationChange(reportErrors: true)
                setError(CatCandidateCurationError.selectedSourceUnavailable)
                return
            }
            SharedLog.app.info(
                "curation",
                "Photo scan source changed",
                metadata: [
                    "source": localIdentifier == nil ? "all-library" : "selected-album"
                ]
            )
            libraryChangePending = false
            chooseCurrentAssetIfNeeded()
            Task { [weak self] in
                guard let self else { return }
                await self.refreshCandidateOutputsAfterCurationChange()
                guard self.catCandidateCuration.sourceAlbumIdentifier
                        == localIdentifier else { return }
                // A threshold change can arm a required primary pass while this
                // task is waiting behind an external-output generation. Read the
                // live flag so a stale source task cannot downgrade that pass.
                await self.launchScan(
                    forceFullAnalysis: self.scanState.requiresFullRescan
                )
            }
        } catch {
            Self.logError(error, category: "curation", operation: "select_photo_source")
            setError(error)
        }
    }

    /// Records only a bounded aggregate keyed by an ASCII product identifier.
    /// Album titles, photo identifiers, dates and location data are excluded so
    /// the local diagnostic can be shared without exposing library metadata.
    func recordAlbumOpened(key: String, group: String) async {
        guard let safeKey = Self.albumUsageToken(key),
              let safeGroup = Self.albumUsageToken(group) else {
            SharedLog.app.warning(
                "album-usage",
                "Rejected invalid grouped album usage key"
            )
            return
        }

        var updated = snapshot
        var usage = updated.albumUsage ?? .empty
        usage.recordOpen(key: safeKey, group: safeGroup)
        updated.albumUsage = usage
        updated.updatedAt = .now
        snapshot = updated

        let openCount = usage.records.first(where: { $0.key == safeKey })?.openCount ?? 1
        SharedLog.app.info(
            "album-usage",
            "Grouped album opened",
            metadata: [
                "album": safeKey,
                "group": safeGroup,
                "openCount": "\(openCount)"
            ]
        )
        await saveSnapshot(reportErrors: false)
    }

    /// Pulls the canonical App Group value into the app without starting a
    /// photo-library scan. Widget deep links call this before routing so the
    /// destination and the global count observe the same like state.
    func syncLikesForPresentation(trigger: String) async {
        let likesChanged = synchronizeSharedLikes(
            importLegacyLikes: false,
            trigger: trigger
        )
        guard likesChanged, hasFinishedSnapshotLoad else { return }
        await saveSnapshot(reportErrors: false)
    }

    func createOrUpdateAlbum() async {
        await createOrUpdateAlbum(reportErrors: true)
    }

    func rebuildAlbum() async {
        await createOrUpdateAlbum()
    }

    /// Persists the birthday/adoption day without invalidating Vision results
    /// or rebuilding PhotoKit/Widget outputs. Curated time albums are derived
    /// directly from this published setting and regroup immediately.
    func updateCatLifeReference(_ reference: CatLifeReference?) async {
        var normalized = settings
        normalized.catLifeReference = reference
        normalized = normalized.normalized()
        guard normalized.catLifeReference != settings.catLifeReference else { return }

        settings = normalized
        snapshot.settings = normalized
        snapshot.updatedAt = .now
        SharedLog.app.info(
            "settings",
            "Cat life reference updated",
            metadata: [
                "configured": "\(normalized.catLifeReference != nil)",
                "kind": normalized.catLifeReference?.kind.rawValue ?? "none"
            ]
        )
        await saveSnapshot(reportErrors: true)
    }

    func createCatProfile(
        displayName: String,
        lifeReference: CatLifeReference?,
        lifeReferenceIsApproximate: Bool,
        referenceAssetIdentifier: String?
    ) async {
        await serializeCatIdentityTransition {
            await self.performCreateCatProfile(
                displayName: displayName,
                lifeReference: lifeReference,
                lifeReferenceIsApproximate: lifeReferenceIsApproximate,
                referenceAssetIdentifier: referenceAssetIdentifier
            )
        }
    }

    private func performCreateCatProfile(
        displayName: String,
        lifeReference: CatLifeReference?,
        lifeReferenceIsApproximate: Bool,
        referenceAssetIdentifier: String?
    ) async {
        let legacyLifeReference = settings.catLifeReference
        let latestLegacyCuration = catCandidateCuration
        let profile = CatProfile(
            displayName: displayName,
            lifeReference: lifeReference,
            lifeReferenceIsApproximate: lifeReferenceIsApproximate
        )
        do {
            _ = try await mutateCatHouseholdIdentity { state in
                // Profile creation is the one-way boundary where identity
                // becomes canonical. Fold in the last committed Build 13
                // curation revision first, including a revision whose prior
                // best-effort identity acknowledgement failed.
                state = state.reconcilingLegacyUnscoped(
                    lifeReference: legacyLifeReference,
                    curation: latestLegacyCuration
                )
                state.upsertProfile(profile)
                if let referenceAssetIdentifier {
                    state.setManualMembership(
                        assetLocalIdentifier: referenceAssetIdentifier,
                        profileID: profile.id,
                        decision: .included,
                        subjectBoundingBox: self.preferredSubjectBoundingBox(
                            assetLocalIdentifier: referenceAssetIdentifier,
                            existing: nil
                        ),
                        isSimilarityReference: false
                    )
                }
            }
            // Once a profile exists, the old household-wide date is retained
            // only in legacy metadata. It must not regroup every cat as one.
            SharedLog.app.info(
                "cat-identity",
                "Cat profile created",
                metadata: [
                    "profiles": "\(catProfiles.count)",
                    "hasReferencePhoto": "\(referenceAssetIdentifier != nil)",
                    "hasLifeReference": "\(lifeReference != nil)"
                ]
            )
        } catch {
            Self.logError(error, category: "cat-identity", operation: "create_profile")
            setError(error)
        }
    }

    func updateCatProfileLifeReference(
        profileID: UUID,
        reference: CatLifeReference?,
        isApproximate: Bool
    ) async {
        do {
            _ = try await mutateCatHouseholdIdentity { state in
                guard var profile = state.profiles.first(where: { $0.id == profileID }) else {
                    return
                }
                profile.lifeReference = reference
                profile.lifeReferenceIsApproximate = reference != nil && isApproximate
                state.upsertProfile(profile)
            }
        } catch {
            Self.logError(error, category: "cat-identity", operation: "update_profile_date")
            setError(error)
        }
    }

    func updateCatProfileName(profileID: UUID, displayName: String) async {
        do {
            _ = try await mutateCatHouseholdIdentity { state in
                guard var profile = state.profiles.first(where: { $0.id == profileID }) else {
                    return
                }
                profile.displayName = displayName
                state.upsertProfile(profile)
            }
        } catch {
            Self.logError(error, category: "cat-identity", operation: "update_profile_name")
            setError(error)
        }
    }

    func deleteCatProfile(profileID: UUID) async {
        do {
            _ = try await mutateCatHouseholdIdentity { state in
                state.removeProfile(id: profileID)
            }
        } catch {
            Self.logError(error, category: "cat-identity", operation: "delete_profile")
            setError(error)
        }
    }

    /// Replaces photo-level profile membership. A photo may remain included in
    /// several profiles. When more than one cat box exists and no explicit box
    /// has been chosen, the membership remains valid for time/special albums,
    /// while profile-specific posture/growth deliberately stays unassigned.
    func replaceCatProfileAssignments(
        profileIDsByLocalIdentifier: [String: Set<UUID>]
    ) async {
        let requested = profileIDsByLocalIdentifier.filter { !$0.key.isEmpty }
        guard !requested.isEmpty else { return }
        do {
            _ = try await mutateCatHouseholdIdentity { state in
                let validProfiles = Set(state.profiles.map(\.id))
                for (identifier, requestedProfiles) in requested {
                    let selected = requestedProfiles.intersection(validProfiles)
                    for profileID in validProfiles {
                        let previous = state.membership(
                            for: identifier,
                            profileID: profileID
                        )
                        let decision: CatAssetMembershipDecision = selected.contains(profileID)
                            ? .included
                            : (previous?.decision == .excluded ? .excluded : .unknown)
                        state.setManualMembership(
                            assetLocalIdentifier: identifier,
                            profileID: profileID,
                            decision: decision,
                            subjectBoundingBox: decision == .included
                                ? self.preferredSubjectBoundingBox(
                                    assetLocalIdentifier: identifier,
                                    existing: previous?.subjectBoundingBox
                                )
                                : nil,
                            isSimilarityReference: false
                        )
                    }
                }
            }
        } catch {
            Self.logError(error, category: "cat-identity", operation: "replace_assignments")
            setError(error)
        }
    }

    func setCatProfileMembership(
        profileID: UUID,
        localIdentifiers: [String],
        decision: CatAssetMembershipDecision
    ) async {
        let identifiers = Array(Set(localIdentifiers)).filter { !$0.isEmpty }
        guard !identifiers.isEmpty else { return }
        do {
            _ = try await mutateCatHouseholdIdentity { state in
                for identifier in identifiers {
                    let previous = state.membership(for: identifier, profileID: profileID)
                    state.setManualMembership(
                        assetLocalIdentifier: identifier,
                        profileID: profileID,
                        decision: decision,
                        subjectBoundingBox: decision == .included
                            ? self.preferredSubjectBoundingBox(
                                assetLocalIdentifier: identifier,
                                existing: previous?.subjectBoundingBox
                              )
                            : nil,
                        isSimilarityReference: false
                    )
                }
            }
        } catch {
            Self.logError(error, category: "cat-identity", operation: "set_membership")
            setError(error)
        }
    }

    func updateSettings(_ newSettings: AppSettings) async {
        var normalized = newSettings.normalized()
        let detectionChanged = normalized.confidenceThreshold != settings.confidenceThreshold
            || normalized.minimumCatAreaRatio != settings.minimumCatAreaRatio
        let displayRangeChanged = normalized.dateRange != settings.dateRange
        if detectionChanged {
            normalized.analysisRevision = settings.analysisRevision + 1
        }

        settings = normalized
        SharedLog.app.info(
            "settings",
            "Settings updated",
            metadata: [
                "albumMaximum": "\(normalized.albumMaximum)",
                "dateRange": normalized.dateRange.rawValue,
                "detectionChanged": "\(detectionChanged)",
                "displayRangeChanged": "\(displayRangeChanged)"
            ]
        )
        snapshot.settings = normalized
        snapshot.updatedAt = .now
        if displayRangeChanged {
            let eligible = candidateSnapshot(snapshot)
            currentAsset = photoSelector.selectOne(
                from: eligible.assets,
                settings: normalized
            )
        }
        await saveSnapshot(reportErrors: true)

        if detectionChanged {
            scanState.requiresFullRescan = true
            scanState.purpose = .manualRescan
            snapshot.scanState = scanState
            await saveSnapshot(reportErrors: false)
            await launchScan(forceFullAnalysis: true)
        } else if hasEligibleDisplayCandidates(in: snapshot) {
            await refreshManagedOutputs(reportErrors: false)
        } else {
            await clearAlbumAndWidgetOutputs(reportErrors: false)
        }
    }

    func exportJSON() async -> URL? {
        errorMessage = nil
        do {
            let url = try exporter.export(
                snapshot,
                curation: catCandidateCuration
            )
            exportedURL = url
            SharedLog.app.info(
                "export",
                "Verification JSON exported",
                metadata: ["assets": "\(snapshot.assets.count)"]
            )
            return url
        } catch {
            Self.logError(error, category: "export", operation: "export_json")
            setError(error)
            return nil
        }
    }

    func handleURL(_ url: URL) {
        guard let link = DeepLink(url: url) else {
            SharedLog.app.warning(
                "deeplink",
                "Rejected unsupported deep link",
                metadata: [
                    "host": url.host ?? "none",
                    "scheme": url.scheme ?? "none"
                ]
            )
            return
        }
        let route: CandidatePhotoRoute
        switch link.destination {
        case let .photo(localIdentifier):
            route = CandidatePhotoRoute(
                localIdentifier: localIdentifier,
                shownAt: link.shownAt
            )
        }
        guard let readyRoute = candidatePhotoRouteGate.receive(
            route,
            candidateStateIsReady: hasFinishedSnapshotLoad
        ) else {
            // A cold-start Widget tap can arrive before the curation and
            // snapshot stores finish loading. Keep only the latest tap and
            // validate it against the loaded candidate set before routing.
            SharedLog.app.info(
                "deeplink",
                "Deferred Widget photo until candidate state loaded"
            )
            return
        }
        openPhotoRoute(readyRoute)
    }

    private func openPendingDeepLinkIfNeeded() {
        guard let route = candidatePhotoRouteGate.finishLoading(
            succeeded: true
        ) else { return }
        openPhotoRoute(route)
    }

    private func discardPendingDeepLink(reason: String) {
        guard candidatePhotoRouteGate.hasPendingRoute else { return }
        _ = candidatePhotoRouteGate.finishLoading(succeeded: false)
        selectedAssetIdentifier = nil
        selectedAssetShownAt = nil
        SharedLog.app.info(
            "deeplink",
            "Discarded deferred Widget photo",
            metadata: ["reason": reason]
        )
    }

    private func openPhotoRoute(_ route: CandidatePhotoRoute) {
        guard catAssets.contains(where: {
            $0.localIdentifier == route.localIdentifier
        }) else {
            selectedAssetIdentifier = nil
            selectedAssetShownAt = nil
            SharedLog.app.info(
                "deeplink",
                "Ignored stale Widget photo outside current candidates",
                metadata: ["asset": SharedLog.shortHash(route.localIdentifier)]
            )
            return
        }
        selectedAssetShownAt = route.shownAt
        selectedAssetIdentifier = route.localIdentifier
        SharedLog.app.info(
            "deeplink",
            "Opened photo from widget deep link",
            metadata: [
                "asset": SharedLog.shortHash(route.localIdentifier),
                "shownAt": route.shownAt.map(Self.iso8601String) ?? "unknown"
            ]
        )
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task { await syncOnActive() }
        case .inactive, .background:
            suspendScan()
        @unknown default:
            suspendScan()
        }
    }

    func loadImage(
        for localIdentifier: String,
        targetSize: CGSize
    ) async -> UIImage? {
        let startedAt = Date()
        let image = imageLoader.image(
            localIdentifier: localIdentifier,
            targetSize: targetSize,
            networkAccessAllowed: true,
            contentMode: .aspectFit
        )
        let elapsedMilliseconds = Date().timeIntervalSince(startedAt) * 1_000
        let width = image?.cgImage?.width ?? 0
        let height = image?.cgImage?.height ?? 0
        if image != nil { successfulImageLoadCount += 1 }
        // Failures are always useful. Successful UI loads are sampled so a
        // long liked-photo grid cannot crowd scan/widget diagnostics out.
        let shouldLog = image == nil
            || successfulImageLoadCount <= 3
            || successfulImageLoadCount.isMultiple(of: 25)
        if shouldLog {
            SharedLog.app.log(
                image == nil ? .warning : .debug,
                "image",
                image == nil ? "Photo image load failed" : "Photo image loaded (sampled)",
                metadata: [
                    "asset": SharedLog.shortHash(localIdentifier),
                    "decodedBytesEstimate": "\(width * height * 4)",
                    "durationMs": String(format: "%.1f", elapsedMilliseconds),
                    "networkAllowed": "true",
                    "outputPixels": "\(width)x\(height)",
                    "requestedPixels": "\(Int(targetSize.width))x\(Int(targetSize.height))",
                    "successOrdinal": "\(successfulImageLoadCount)"
                ]
            )
        }
        return image
    }

    func clearError() {
        errorMessage = nil
    }

    private var canReadPhotos: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    private func loadCatCandidateCuration() async -> Bool {
        guard let curationStore else {
            if let curationStoreInitializationError {
                errorMessage = curationStoreInitializationError
            }
            return false
        }
        do {
            catCandidateCuration = try await curationStore.load()
            selectedSourceAssetIdentifiers = catCandidateCuration
                .lastKnownSourceAssetIdentifierSet
            SharedLog.app.info(
                "curation",
                "Cat candidate curation state loaded",
                metadata: [
                    "excluded": "\(catCandidateCuration.excludedAssets.count)",
                    "source": catCandidateCuration.usesSelectedAlbum
                        ? "selected-album"
                        : "all-library"
                ]
            )
            return true
        } catch {
            // Do not fall back to an empty state: that would silently
            // resurrect every previously excluded photo.
            Self.logError(error, category: "curation", operation: "load_state")
            setError(error)
            return false
        }
    }

    private func loadCatHouseholdIdentity() async -> Bool {
        guard let identityStore else {
            if let identityStoreInitializationError {
                errorMessage = identityStoreInitializationError
            }
            return false
        }
        do {
            let loaded = try await identityStore.loadOrMigrate(
                legacyLifeReference: settings.catLifeReference,
                legacyCuration: catCandidateCuration
            )
            catHouseholdIdentity = loaded
            catIdentityLoadState = .ready
            SharedLog.app.info(
                "cat-identity",
                "Cat household identity state loaded",
                metadata: [
                    "mode": loaded.mode.rawValue,
                    "profiles": "\(loaded.profiles.count)",
                    "memberships": "\(loaded.memberships.count)",
                    "globalExcluded": "\(loaded.globalExcludedAssets.count)",
                    "revision": "\(loaded.mutationRevision)"
                ]
            )
            return true
        } catch {
            catIdentityLoadState = .failed
            // A missing/unsupported identity ledger must not silently fall
            // back to a single-cat interpretation of profile-scoped dates.
            Self.logError(error, category: "cat-identity", operation: "load_state")
            setError(error)
            return false
        }
    }

    @discardableResult
    private func applyNewestCurationState(
        _ incoming: CatCandidateCurationState
    ) -> Bool {
        guard incoming.mutationRevision >= catCandidateCuration.mutationRevision else {
            SharedLog.app.debug(
                "curation",
                "Discarded stale curation actor result",
                metadata: [
                    "currentRevision": "\(catCandidateCuration.mutationRevision)",
                    "returnedRevision": "\(incoming.mutationRevision)"
                ]
            )
            return false
        }
        catCandidateCuration = incoming
        selectedSourceAssetIdentifiers = incoming.lastKnownSourceAssetIdentifierSet
        return true
    }

    @discardableResult
    private func mutateCatHouseholdIdentity(
        _ mutation: (inout CatHouseholdIdentityState) -> Void
    ) async throws -> CatHouseholdIdentityState {
        guard let identityStore else {
            throw NekoWidgetError.appGroupUnavailable(SharedContainer.appGroupIdentifier)
        }
        var latest = catHouseholdIdentity
        for _ in 0..<3 {
            guard let current = latest else {
                throw CatHouseholdIdentityStoreError.missingState
            }
            var proposed = current
            mutation(&proposed)
            proposed = proposed.normalized()
            if proposed == current { return current }
            do {
                let committed = try await identityStore.save(
                    proposed,
                    expectedMutationRevision: current.mutationRevision
                )
                if committed.mutationRevision
                    >= (catHouseholdIdentity?.mutationRevision ?? -1) {
                    catHouseholdIdentity = committed
                }
                return committed
            } catch CatHouseholdIdentityRevisionError.stale(_, _) {
                latest = try await identityStore.load()
                if let latest,
                   latest.mutationRevision
                    >= (catHouseholdIdentity?.mutationRevision ?? -1) {
                    catHouseholdIdentity = latest
                }
            }
        }
        throw CatHouseholdIdentityRevisionError.exhausted
    }

    private func preferredSubjectBoundingBox(
        assetLocalIdentifier: String,
        existing: NormalizedRect?
    ) -> NormalizedRect? {
        guard let record = snapshot.assets.first(where: {
            $0.localIdentifier == assetLocalIdentifier
        }) else { return existing }
        let boxes = record.albumTraits?.postureInstances?.map(\.boundingBox) ?? []
        if let existing,
           boxes.contains(where: { Self.intersectionOverUnion($0, existing) >= 0.5 }) {
            return existing
        }
        if boxes.count == 1 { return boxes[0] }
        if boxes.isEmpty, record.cat.catCount <= 1 {
            return record.cat.boundingBox
        }
        return nil
    }

    private static func intersectionOverUnion(
        _ lhs: NormalizedRect,
        _ rhs: NormalizedRect
    ) -> Double {
        let intersection = lhs.cgRect.intersection(rhs.cgRect)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = Double(intersection.width * intersection.height)
        let unionArea = lhs.area + rhs.area - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }

    private func candidateSnapshot(_ input: LibrarySnapshot) -> LibrarySnapshot {
        if catIdentityLoadState == .failed {
            var value = input
            value.assets.removeAll()
            return value
        }
        let excludedIdentifiers: Set<String>
        if let identity = catHouseholdIdentity,
           identity.mode == .profiled {
            excludedIdentifiers = Set(
                identity.globalExcludedAssets.map(\.localIdentifier)
            )
        } else {
            excludedIdentifiers = catCandidateCuration.excludedAssetIdentifiers
        }
        let sourceIdentifiers = selectedSourceAssetIdentifiers
            ?? catCandidateCuration.lastKnownSourceAssetIdentifierSet
        let usesSelectedSource = catCandidateCuration.usesSelectedAlbum
        var value = input
        value.assets.removeAll { asset in
            if excludedIdentifiers.contains(asset.localIdentifier) { return true }
            guard usesSelectedSource else { return false }
            // No known membership is fail-closed, never an implicit full library.
            return sourceIdentifiers?.contains(asset.localIdentifier) != true
        }
        return value
    }

    private var canPresentCatIdentity: Bool {
        !hasStarted || catIdentityLoadState == .ready
    }

    /// While the app is still in the Build 13 compatibility mode, the legacy
    /// curation ledger remains canonical. Acknowledge each successful mirror
    /// revision in the identity ledger so a later failed mirror cannot make an
    /// older curation revision overwrite a newer identity decision at launch.
    private func acknowledgeLegacyCurationState(
        _ curation: CatCandidateCurationState
    ) async {
        guard catHouseholdIdentity?.mode == .legacyUnscoped else { return }
        let lifeReference = settings.catLifeReference
        do {
            _ = try await mutateCatHouseholdIdentity { state in
                state = state.reconcilingLegacyUnscoped(
                    lifeReference: lifeReference,
                    curation: curation
                )
            }
        } catch {
            // The curation write already committed and remains authoritative.
            // A later launch will import this higher revision again.
            Self.logError(
                error,
                category: "cat-identity",
                operation: "acknowledge_legacy_curation"
            )
            setError(error)
        }
    }

    private func serializeCatIdentityTransition(
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        catIdentityTransitionSequence += 1
        let sequence = catIdentityTransitionSequence
        let previous = catIdentityTransitionTail
        let current = Task { @MainActor in
            if let previous {
                await previous.value
            }
            await operation()
        }
        catIdentityTransitionTail = current
        await current.value
        if catIdentityTransitionSequence == sequence {
            catIdentityTransitionTail = nil
        }
    }

    private func reconcileCandidatePostureState() {
        let summary = PostureScanSummary(records: candidateSnapshot(snapshot).assets)
        scanState.postureSummary = summary
        if !scanState.requiresFullRescan, !isScanning {
            if summary.secondaryPendingAssets > 0 {
                if scanState.purpose == nil || scanState.purpose == .postureRepair {
                    scanState.purpose = .postureRepair
                }
            } else if scanState.purpose == .postureRepair {
                scanState.purpose = nil
            }
        }
        snapshot.scanState = scanState
    }

    private func refreshCandidateOutputsAfterCurationChange(
        reportErrors: Bool = true
    ) async {
        // PhotoAlbumService is an actor. Always enqueue this generation behind
        // any in-flight stale membership update; a time-bounded status poll can
        // otherwise return without ever removing an excluded photo.
        if hasEligibleDisplayCandidates(in: snapshot) {
            // This follows an explicit user correction. Surface a failure
            // instead of silently leaving a managed album or Widget on the
            // pre-correction generation.
            await refreshManagedOutputs(reportErrors: reportErrors)
        } else {
            await clearAlbumAndWidgetOutputs(reportErrors: reportErrors)
        }
    }

    private func launchScan(forceFullAnalysis: Bool) async {
        scanGeneration += 1
        let generation = scanGeneration

        if let previousTask = scanTask {
            previousTask.cancel()
            await previousTask.value
        }
        guard generation == scanGeneration else { return }

        isScanning = true
        var startingState = scanState
        startingState.phase = .quickScan
        startingState.lastError = nil
        startingState.requiresFullRescan = forceFullAnalysis
        if startingState.purpose == nil {
            startingState.purpose = forceFullAnalysis ? .manualRescan : .regular
        }
        scanState = startingState
        snapshot.scanState = startingState
        SharedLog.app.info(
            "scan",
            "Scan generation started",
            metadata: [
                "analysisVersion": "\(CatAlbumTraits.currentAnalysisVersion)",
                "existingRecords": "\(snapshot.assets.count)",
                "forceFullAnalysis": "\(forceFullAnalysis)",
                "generation": "\(generation)",
                "scanPurpose": startingState.purpose?.rawValue ?? "regular"
            ]
        )

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performScan(
                generation: generation,
                forceFullAnalysis: forceFullAnalysis
            )
        }
        scanTask = task
        await task.value

        guard generation == scanGeneration else { return }
        scanTask = nil
        isScanning = false
    }

    private func performScan(generation: Int, forceFullAnalysis: Bool) async {
        do {
            let final = try await scanner.scan(
                existing: snapshot,
                settings: settings,
                forceFullAnalysis: forceFullAnalysis,
                sourceAlbumIdentifier: catCandidateCuration.sourceAlbumIdentifier
            ) { [weak self] event in
                await self?.applyScanEvent(event, generation: generation)
            }
            guard generation == scanGeneration else { return }

            applySnapshot(final)
            chooseCurrentAssetIfNeeded()
            await saveSnapshot(reportErrors: true)
            SharedLog.app.info(
                "scan",
                "Final scan result applied",
                metadata: Self.scanLogMetadata(
                    [
                    "cats": "\(catAssets.count)",
                    "deferred": "\(final.scanState.deferredAssets)",
                    "total": "\(final.scanState.totalAssets)"
                    ],
                    state: scanState
                )
            )

            if hasEligibleDisplayCandidates(in: final) {
                await refreshManagedOutputs(reportErrors: false)
            } else {
                await clearAlbumAndWidgetOutputs(reportErrors: false)
            }
        } catch is CancellationError {
            guard generation == scanGeneration else { return }
            var cancelled = scanState
            cancelled.phase = .cancelled
            scanState = cancelled
            snapshot.scanState = cancelled
            SharedLog.app.info(
                "scan",
                "Scan task cancelled",
                metadata: ["generation": "\(generation)"]
            )
            await saveSnapshot(reportErrors: false)
        } catch CatCandidateCurationError.selectedSourceUnavailable {
            guard generation == scanGeneration else { return }
            photoSourceStatus = .unavailable
            var failed = scanState
            failed.phase = .failed
            failed.lastError = CatCandidateCurationError
                .selectedSourceUnavailable
                .localizedDescription
            scanState = failed
            snapshot.scanState = failed
            SharedLog.app.warning(
                "curation",
                "Selected photo source became unavailable; previous candidates retained"
            )
            setError(CatCandidateCurationError.selectedSourceUnavailable)
            await saveSnapshot(reportErrors: false)
        } catch {
            guard generation == scanGeneration else { return }
            var failed = scanState
            failed.phase = .failed
            failed.lastError = error.localizedDescription
            scanState = failed
            snapshot.scanState = failed
            Self.logError(error, category: "scan", operation: "perform_scan")
            setError(error)
            await saveSnapshot(reportErrors: false)
        }
    }

    private func applyScanEvent(_ event: ScanEvent, generation: Int) async {
        guard generation == scanGeneration else { return }
        switch event {
        case let .progress(progressState, analyzedRecords):
            var published = progressState
            // Publish the first completed batch as a clearly-labelled quick
            // result. The 500-photo checkpoint later replaces its count, and
            // only the completed event becomes `.final`.
            if published.phase == .quickScan || published.phase == .fullScan {
                published.resultKind = .provisional
            }
            scanState = published
            mergeAnalyzedRecords(analyzedRecords)
            snapshot.scanState = published
            snapshot.updatedAt = .now
            reconcileCandidatePostureState()
            chooseCurrentAssetIfNeeded()
            SharedLog.app.info(
                "scan",
                "Scan progress published",
                metadata: Self.scanLogMetadata(
                    [
                    "cats": "\(catAssets.count)",
                    "deferred": "\(published.deferredAssets)",
                    "phase": published.phase.rawValue,
                    "scanned": "\(published.scannedAssets)",
                    "total": "\(published.totalAssets)"
                    ],
                    state: scanState
                )
            )
            // Persist resumable full-scan checkpoints without rewriting a
            // potentially large JSON file for every progress publication.
            if published.scannedAssets.isMultiple(of: 1_000) {
                await saveSnapshot(reportErrors: false)
            }

        case let .provisional(provisional):
            applySnapshot(provisional)
            chooseCurrentAssetIfNeeded()
            SharedLog.app.info(
                "scan",
                "Provisional scan result applied",
                metadata: Self.scanLogMetadata(
                    [
                    "cats": "\(catAssets.count)",
                    "deferred": "\(provisional.scanState.deferredAssets)",
                    "scanned": "\(provisional.scanState.scannedAssets)",
                    "total": "\(provisional.scanState.totalAssets)"
                    ],
                    state: scanState
                )
            )
            await saveSnapshot(reportErrors: false)
            // Publish a usable v1 experience after the newest 500 assets rather
            // than waiting for a potentially long full-library scan.
            if provisional.scanState.resultKind == .provisional {
                if hasEligibleDisplayCandidates(in: provisional) {
                    await refreshManagedOutputs(reportErrors: false)
                } else {
                    // Limited access can shrink, or assets can be deleted,
                    // before a long full scan completes. Do not leave the old
                    // album/widget visible if the current quick snapshot has
                    // no eligible photo and the app is backgrounded here.
                    await clearAlbumAndWidgetOutputs(reportErrors: false)
                }
            }
        }
    }

    private func applySnapshot(
        _ newSnapshot: LibrarySnapshot,
        preservingLiveSettings: Bool = true
    ) {
        // A full scan can run while the user presses “これ好き” or while the
        // quick-stage album/cache publication updates display history. Merge
        // those live mutations instead of replacing them with scan-start state.
        let liveByIdentifier = Dictionary(
            uniqueKeysWithValues: snapshot.assets.map { ($0.localIdentifier, $0) }
        )
        var merged = newSnapshot
        merged.assets = newSnapshot.assets.map {
            var record = $0.preservingUserState(from: liveByIdentifier[$0.localIdentifier])
            if let sharedLike = sharedLikeRecords[record.localIdentifier] {
                record.liked = sharedLike.isLiked
                record.likedAt = sharedLike.likedAt
            }
            return record
        }
        if let liveAlbumIdentifier = snapshot.albumLocalIdentifier {
            merged.albumLocalIdentifier = liveAlbumIdentifier
        }
        // An album can be opened while a long scan is using its start-of-run
        // snapshot. Preserve that newer bounded aggregate at publication time.
        if let liveAlbumUsage = snapshot.albumUsage {
            merged.albumUsage = liveAlbumUsage
        }
        // A scan owns a start-of-run settings snapshot. Calendar grouping can
        // be edited while that long scan is in flight, so progress/final
        // publications must not roll the newly saved local date back.
        if preservingLiveSettings {
            merged.settings = snapshot.settings
        }

        snapshot = merged
        scanState = merged.scanState
        settings = merged.settings.normalized()
        reconcileCandidatePostureState()
        refreshCurrentAsset()
    }

    private func mergeAnalyzedRecords(_ records: [AssetRecord]) {
        guard !records.isEmpty else { return }
        var existingByIdentifier = Dictionary(
            uniqueKeysWithValues: snapshot.assets.map { ($0.localIdentifier, $0) }
        )
        for record in records {
            var merged = record.preservingUserState(
                from: existingByIdentifier[record.localIdentifier]
            )
            if let sharedLike = sharedLikeRecords[record.localIdentifier] {
                merged.liked = sharedLike.isLiked
                merged.likedAt = sharedLike.likedAt
            }
            existingByIdentifier[record.localIdentifier] = merged
        }
        snapshot.assets = Array(existingByIdentifier.values)
    }

    /// The small App Group file is the canonical cross-process source for
    /// likes. Import the pre-Build-6 snapshot values once, then apply both
    /// widget and app mutations to the in-memory snapshot. Explicit false
    /// records are tombstones, so a widget unlike cannot be resurrected by an
    /// older snapshot.
    @discardableResult
    private func synchronizeSharedLikes(
        importLegacyLikes: Bool,
        trigger: String
    ) -> Bool {
        do {
            let records: [String: SharedLikeRecord]
            if importLegacyLikes {
                let legacyRecords = snapshot.assets.compactMap { asset -> SharedLikeRecord? in
                    guard asset.liked else { return nil }
                    let likedAt = asset.likedAt ?? snapshot.updatedAt
                    return SharedLikeRecord(
                        localIdentifier: asset.localIdentifier,
                        isLiked: true,
                        likedAt: likedAt,
                        changedAt: likedAt
                    )
                }
                records = try SharedLikeStore.mergeLegacyLikes(legacyRecords)
            } else {
                records = try SharedLikeStore.readAll()
            }

            sharedLikeRecords = records
            let wasInteractionReady = isLikeInteractionReady
            refreshLikeInteractionState()
            if !wasInteractionReady && isLikeInteractionReady {
                WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
                SharedLog.app.info(
                    "like",
                    "Widget like interaction enabled after legacy migration"
                )
            }
            var updatedSnapshot = snapshot
            var changedCount = 0
            var matchedCount = 0
            for index in updatedSnapshot.assets.indices {
                guard let record = records[updatedSnapshot.assets[index].localIdentifier] else {
                    continue
                }
                matchedCount += 1
                let asset = updatedSnapshot.assets[index]
                guard asset.liked != record.isLiked || asset.likedAt != record.likedAt else { continue }
                Self.applySharedLikeRecord(record, at: index, to: &updatedSnapshot)
                changedCount += 1
            }

            if changedCount > 0 {
                updatedSnapshot.updatedAt = .now
                // An explicit value replacement is required here. Mutating an
                // element nested inside `@Published snapshot` did update the
                // model and disk shadow, but did not reliably invalidate views;
                // the next scan's whole-snapshot assignment masked that bug.
                snapshot = updatedSnapshot
                refreshCurrentAsset()
            }
            let sharedLikedCount = records.values.lazy.filter(\.isLiked).count
            let visibleLikedCount = updatedSnapshot.assets.lazy.filter(\.liked).count
            SharedLog.app.info(
                "like",
                "Shared like state synchronized",
                metadata: [
                    "changedAssets": "\(changedCount)",
                    "matchedAssets": "\(matchedCount)",
                    "records": "\(records.count)",
                    "sharedLiked": "\(sharedLikedCount)",
                    "source": "app-group",
                    "trigger": trigger,
                    "visibleLiked": "\(visibleLikedCount)"
                ]
            )
            return changedCount > 0
        } catch {
            Self.logError(error, category: "like", operation: "synchronize_shared_likes")
            return false
        }
    }

    private func refreshLikeInteractionState() {
        do {
            let state = try SharedLikeStore.stateSnapshot()
            isLikeInteractionReady = state.isInteractionReady
        } catch {
            Self.logError(error, category: "like", operation: "read_like_state")
        }
    }

    private static func applySharedLikeRecord(
        _ record: SharedLikeRecord,
        at index: Int,
        to snapshot: inout LibrarySnapshot
    ) {
        snapshot.assets[index].liked = record.isLiked
        snapshot.assets[index].likedAt = record.likedAt
    }

    private static func albumUsageToken(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 64 else { return nil }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }

    private func chooseCurrentAssetIfNeeded() {
        guard canPresentCatIdentity else {
            currentAsset = nil
            return
        }
        let eligible = candidateSnapshot(snapshot)
        if let currentAsset,
           let updated = eligible.assets.first(where: {
               $0.localIdentifier == currentAsset.localIdentifier
                   && $0.isCatCandidate
                   && $0.analysisFingerprint == settings.analysisFingerprint
           }) {
            self.currentAsset = updated
            return
        }
        currentAsset = photoSelector.selectOne(
            from: eligible.assets,
            settings: settings
        )
    }

    private func refreshCurrentAsset() {
        guard let identifier = currentAsset?.localIdentifier else { return }
        guard let updated = candidateSnapshot(snapshot).assets.first(where: {
            $0.localIdentifier == identifier && $0.isCatCandidate
        }) else {
            currentAsset = nil
            chooseCurrentAssetIfNeeded()
            return
        }
        currentAsset = updated
    }

    private func createOrUpdateAlbum(reportErrors: Bool) async {
        await enqueueManagedOutputMutation { model in
            await model.performCreateOrUpdateAlbum(reportErrors: reportErrors)
        }
    }

    private func refreshManagedOutputs(reportErrors: Bool) async {
        await enqueueManagedOutputMutation { model in
            if model.hasEligibleDisplayCandidates(in: model.snapshot) {
                await model.performCreateOrUpdateAlbum(reportErrors: reportErrors)
                await model.performRebuildWidgetCache(reportErrors: reportErrors)
            } else {
                await model.performClearManagedAlbum(reportErrors: reportErrors)
                await model.performClearWidgetOutput(reportErrors: reportErrors)
            }
        }
    }

    private func performCreateOrUpdateAlbum(reportErrors: Bool) async {
        let selected = albumSelector.select(from: candidateSnapshot(snapshot))
        guard !selected.isEmpty else {
            await performClearManagedAlbum(reportErrors: false)
            await performClearWidgetOutput(reportErrors: false)
            albumStatus = .failed(message: NekoWidgetError.noCatPhotos.localizedDescription)
            if reportErrors { setError(NekoWidgetError.noCatPhotos) }
            return
        }

        if reportErrors { errorMessage = nil }
        albumStatus = .updating
        SharedLog.app.info(
            "album",
            "Album synchronization started",
            metadata: [
                "hasExistingAlbum": "\(snapshot.albumLocalIdentifier != nil)",
                "selected": "\(selected.count)"
            ]
        )
        do {
            let identifier = try await albumService.createOrUpdateAlbum(
                named: settings.albumName,
                assetIdentifiers: selected.map(\.localIdentifier),
                existingAlbumIdentifier: snapshot.albumLocalIdentifier
            )
            snapshot.albumLocalIdentifier = identifier
            snapshot.updatedAt = .now
            await saveSnapshot(reportErrors: reportErrors)
            albumStatus = .ready(photoCount: selected.count, updatedAt: .now)
            SharedLog.app.info(
                "album",
                "Album synchronization finished",
                metadata: ["photoCount": "\(selected.count)"]
            )
        } catch {
            albumStatus = .failed(message: error.localizedDescription)
            Self.logError(error, category: "album", operation: "synchronize_album")
            if reportErrors { setError(error) }
        }
    }

    private func enqueueManagedOutputMutation(
        _ operation: @escaping @MainActor (AppViewModel) async -> Void
    ) async {
        managedOutputMutationSequence += 1
        let sequence = managedOutputMutationSequence
        let previous = managedOutputMutationTail
        let task = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            await operation(self)
        }
        managedOutputMutationTail = task
        await task.value
        if managedOutputMutationSequence == sequence {
            managedOutputMutationTail = nil
        }
    }

    private func rebuildWidgetCache(reportErrors: Bool) async {
        await enqueueManagedOutputMutation { model in
            await model.performRebuildWidgetCache(reportErrors: reportErrors)
        }
    }

    private func performRebuildWidgetCache(reportErrors: Bool) async {
        SharedLog.app.info(
            "widget-cache",
            "Widget cache rebuild requested",
            metadata: ["assets": "\(snapshot.assets.count)"]
        )
        do {
            let result = try await widgetCacheBuilder.build(
                from: candidateSnapshot(snapshot)
            )
            let occurrenceCounts = Dictionary(
                grouping: result.selectedIdentifiers,
                by: { $0 }
            ).mapValues(\.count)
            let shownAt = result.manifest.generatedAt
            for index in snapshot.assets.indices {
                let identifier = snapshot.assets[index].localIdentifier
                guard let count = occurrenceCounts[identifier] else { continue }
                snapshot.assets[index].lastShownAt = shownAt
                snapshot.assets[index].shownCount += count
            }
            snapshot.updatedAt = .now
            refreshCurrentAsset()
            await saveSnapshot(reportErrors: reportErrors)
            WidgetCenter.shared.reloadAllTimelines()
            SharedLog.app.info(
                "widget-cache",
                "Widget timeline reload requested",
                metadata: [
                    "entries": "\(result.manifest.items.count)",
                    "uniqueAssets": "\(Set(result.selectedIdentifiers).count)"
                ]
            )
        } catch {
            Self.logError(error, category: "widget-cache", operation: "rebuild_cache")
            if reportErrors { setError(error) }
        }
    }

    private func clearAlbumAndWidgetOutputs(reportErrors: Bool) async {
        await enqueueManagedOutputMutation { model in
            await model.performClearManagedAlbum(reportErrors: reportErrors)
            await model.performClearWidgetOutput(reportErrors: reportErrors)
        }
    }

    private func performClearManagedAlbum(reportErrors: Bool) async {
        do {
            try await albumService.removeAllAssets(
                existingAlbumIdentifier: snapshot.albumLocalIdentifier
            )
            albumStatus = .ready(photoCount: 0, updatedAt: .now)
        } catch {
            albumStatus = .failed(message: error.localizedDescription)
            Self.logError(error, category: "album", operation: "clear_album")
            if reportErrors { setError(error) }
        }
    }

    private func clearWidgetOutput(reportErrors: Bool) async {
        await enqueueManagedOutputMutation { model in
            await model.performClearWidgetOutput(reportErrors: reportErrors)
        }
    }

    private func performClearWidgetOutput(reportErrors: Bool) async {
        do {
            try await widgetCacheBuilder.clear()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            Self.logError(error, category: "widget-cache", operation: "clear_cache")
            if reportErrors { setError(error) }
        }
    }

    private func hasEligibleDisplayCandidates(in value: LibrarySnapshot) -> Bool {
        let eligible = candidateSnapshot(value)
        return photoSelector.selectOne(
            from: eligible.assets,
            settings: eligible.settings
        ) != nil
    }

    private func saveSnapshot(reportErrors: Bool) async {
        guard let store else {
            if reportErrors,
               let storeInitializationError {
                errorMessage = storeInitializationError
            }
            return
        }
        do {
            try await store.save(snapshot)
        } catch {
            Self.logError(error, category: "storage", operation: "save_snapshot")
            if reportErrors { setError(error) }
        }
    }

    private func setError(_ error: Error) {
        errorMessage = error.localizedDescription
        Self.logError(error, category: "error", operation: "present_to_user")
    }

    private static func logError(
        _ error: Error,
        category: String,
        operation: String
    ) {
        let value = error as NSError
        SharedLog.app.error(
            category,
            "Operation failed",
            metadata: [
                "code": "\(value.code)",
                "domain": value.domain,
                "operation": operation,
                "reason": error.localizedDescription
            ]
        )
    }

    private static func scanLogMetadata(
        _ base: [String: String],
        state: ScanState
    ) -> [String: String] {
        var metadata = base
        metadata.merge(
            state.postureSummary?.logMetadata ?? [:],
            uniquingKeysWith: { current, _ in current }
        )
        metadata["postureAnalysisVersion"] = "\(CatAlbumTraits.currentAnalysisVersion)"
        metadata["scanPurpose"] = state.purpose?.rawValue ?? "none"
        return metadata
    }

    private static func authorizationName(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }

    private static func iso8601String(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

}
