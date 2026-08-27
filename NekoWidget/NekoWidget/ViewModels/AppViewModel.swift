import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WidgetKit

extension Notification.Name {
    static let sharingMediaSyncRequested = Notification.Name(
        "jp.nekowidget.sharing.media-sync-requested"
    )
    static let momentSharingPresentationNeedsRefresh = Notification.Name(
        "jp.nekowidget.sharing.presentation-needs-refresh"
    )
    static let momentSharingContentNeedsReload = Notification.Name(
        "jp.nekowidget.sharing.content-needs-reload"
    )
    static let receivedMemoryImportNeedsRefresh = Notification.Name(
        "jp.nekowidget.received-memory-import-needs-refresh"
    )
}

enum AlbumUpdateStatus: Equatable {
    case idle
    case updating
    case ready(photoCount: Int, updatedAt: Date)
    case failed(message: String)
}

private enum CatIdentityLoadState: Equatable {
    case loading
    case ready
    case failed
}

/// Notification taps can arrive while an earlier private-window activation is
/// suspended in Keychain/App Group work. This gate makes activation and route
/// publication one ordered operation; the generation check then drops every
/// queued route except the newest one before it can mutate the selected window.
private actor MomentNotificationRoutingGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}

private let momentNotificationRoutingGate = MomentNotificationRoutingGate()

struct LibraryPresentationVersion: Equatable {
    let snapshotUpdatedAt: Date
    let snapshotAssetCount: Int
    let analysisFingerprint: String
    let curationMutationRevision: Int
    let identityMutationRevision: Int?
    let sourceResolutionRevision: Int
    let canPresent: Bool
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
    /// Creation dates for currently accessible profile-linked album assets.
    /// PhotoKit identifiers and dates remain in memory/local identity storage
    /// and are never added to diagnostics or sharing payloads.
    @Published private(set) var profilePhotoAlbumAssetDates: [String: Date] = [:]
    @Published private(set) var unavailableProfilePhotoAlbumIdentifiers = Set<String>()
    @Published var selectedAssetIdentifier: String?
    @Published var selectedAssetShownAt: Date?
    @Published var isFamilyWindowPresented = false
    @Published var pendingFamilyMomentSourceDigest: String?
    @Published var pendingFamilyNotificationRoute: MomentNotificationRoute?
    @Published private(set) var familyWindowPresentation: MomentFamilyWindowPresentation = .empty
    @Published private(set) var privateWindowDisplayName = PrivateWindowDisplayName.fallback

    var isLimitedAccess: Bool { authorizationStatus == .limited }
    /// One already-curated value for a SwiftUI presentation pass. Large
    /// libraries must not repeat the source/exclusion projection separately
    /// for every tab input while scan progress is publishing.
    var presentationSnapshot: LibrarySnapshot {
        let version = presentationVersion
        if let cachedPresentationSnapshot,
           cachedPresentationSnapshot.version == version {
            return cachedPresentationSnapshot.snapshot
        }
        let value = canPresentCatIdentity ? candidateSnapshot(snapshot) : .empty
        cachedPresentationSnapshot = (version, value)
        return value
    }
    var presentationVersion: LibraryPresentationVersion {
        LibraryPresentationVersion(
            snapshotUpdatedAt: snapshot.updatedAt,
            snapshotAssetCount: snapshot.assets.count,
            analysisFingerprint: snapshot.settings.analysisFingerprint,
            curationMutationRevision: catCandidateCuration.mutationRevision,
            identityMutationRevision: catHouseholdIdentity?.mutationRevision,
            sourceResolutionRevision: presentationSourceResolutionRevision,
            canPresent: canPresentCatIdentity
        )
    }
    var catAssets: [AssetRecord] {
        presentationSnapshot.catAssets
    }
    var likedAssets: [AssetRecord] {
        snapshot.likedAssets
    }
    var visibleLibraryAssets: [AssetRecord] {
        presentationSnapshot.assets
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
    /// Unresolved detector instances, not unresolved photos. A two-cat photo
    /// remains here until each exact box has a confirmed profile membership.
    var catSimilarityCandidateInstances: [CatSimilarityCandidateInstance] {
        catSimilarityCandidateInstances(from: catAssets)
    }

    func catSimilarityCandidateInstances(
        from candidateAssets: [AssetRecord]
    ) -> [CatSimilarityCandidateInstance] {
        guard canPresentCatIdentity,
              let identity = catHouseholdIdentity,
              identity.mode == .profiled,
              !identity.profiles.isEmpty else { return [] }
        return catSimilarityCandidateInstances(
            in: identity,
            candidateAssets: candidateAssets
        )
    }

    private func catSimilarityCandidateInstances(
        in identity: CatHouseholdIdentityState,
        candidateAssets: [AssetRecord]? = nil
    ) -> [CatSimilarityCandidateInstance] {
        let includedByAsset = Dictionary(grouping: identity.memberships.filter {
            $0.decision == .included
        }, by: \.assetLocalIdentifier)
        return CatSimilarityCandidateResolver.unresolvedInstances(
            from: (candidateAssets ?? catAssets).map { asset in
                CatSimilarityCandidateAsset(
                    assetLocalIdentifier: asset.localIdentifier,
                    detectedCatCount: asset.cat.catCount,
                    resolvedBoundingBoxes: asset.resolvedCatBoundingBoxes.boundingBoxes,
                    includedMembershipSubjectBoundingBoxes: includedByAsset[
                        asset.localIdentifier
                    ]?.map(\.subjectBoundingBox) ?? []
                )
            }
        )
    }
    var oldestCatPhotoDate: Date? { catAssets.compactMap(\.creationDate).min() }
    var progress: Double { scanState.progress }
    var isQuickResultReady: Bool { scanState.isQuickResultReady }
    var isComplete: Bool { scanState.isComplete }

    func catAssets(profileID: UUID) -> [AssetRecord] {
        guard let identity = catHouseholdIdentity else { return [] }
        let included = identity.confirmedAssetIdentifiers(for: profileID)
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
    private let momentSharingCoordinator: MomentSharingCoordinator
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
    /// Scanner events may arrive in reuse-heavy bursts much faster than the UI
    /// can draw. Keep the newest state plus every analyzed record until the
    /// next bounded presentation publication.
    private struct PendingScanProgress {
        var generation: Int
        var state: ScanState
        var analyzedRecords: [AssetRecord]
        var eventCount: Int
    }
    private struct ScanProgressSnapshot {
        var snapshot: LibrarySnapshot
        var state: ScanState
        var catAssetCount: Int
    }
    private var pendingScanProgress: PendingScanProgress?
    private var scanProgressFlushTask: Task<Void, Never>?
    private var scanProgressFlushSequence = 0
    private var lastScanProgressPublicationUptime: TimeInterval?
    private var cachedPresentationSnapshot: (
        version: LibraryPresentationVersion,
        snapshot: LibrarySnapshot
    )?
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
    private var momentPresentationRefreshObserver: NSObjectProtocol?
    private var receivedMemoryImportObserver: NSObjectProtocol?
    private var familyWindowRefreshSequence = 0
    private var momentNotificationRouteGeneration = 0
    /// nil means no additional in-memory source filter. When an album is
    /// selected this is refreshed from PhotoKit before a scan, so old snapshot
    /// records outside that album disappear from candidate surfaces at once.
    private var selectedSourceAssetIdentifiers: Set<String>? {
        didSet {
            presentationSourceResolutionRevision &+= 1
            cachedPresentationSnapshot = nil
        }
    }
    private var presentationSourceResolutionRevision = 0

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
        momentSharingCoordinator = MomentSharingCoordinator()

        do {
            store = try LibraryStore()
            storeInitializationError = nil
            SharedLog.app.info("storage", "Shared snapshot store initialized")
        } catch {
            store = nil
            storeInitializationError = Self.userFacingMessage(for: error)
            Self.logError(error, category: "storage", operation: "initialize_store")
        }

        do {
            curationStore = try CatCandidateCurationStore()
            curationStoreInitializationError = nil
            SharedLog.app.info("curation", "Cat candidate curation store initialized")
        } catch {
            curationStore = nil
            curationStoreInitializationError = Self.userFacingMessage(for: error)
            Self.logError(error, category: "curation", operation: "initialize_store")
        }

        do {
            identityStore = try CatHouseholdIdentityStore()
            identityStoreInitializationError = nil
            SharedLog.app.info("cat-identity", "Cat household identity store initialized")
        } catch {
            identityStore = nil
            identityStoreInitializationError = Self.userFacingMessage(for: error)
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
        sharingSyncObserver = NotificationCenter.default.addObserver(
            forName: .sharingMediaSyncRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.synchronizeMomentSharing(trigger: "pairing-or-consent")
            }
        }
        momentPresentationRefreshObserver = NotificationCenter.default.addObserver(
            forName: .momentSharingPresentationNeedsRefresh,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshFamilyWindowOutputs(trigger: "local-state-change")
            }
        }
        receivedMemoryImportObserver = NotificationCenter.default.addObserver(
            forName: .receivedMemoryImportNeedsRefresh,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let localIdentifier = notification.object as? String
            Task { @MainActor [weak self] in
                await self?.refreshReceivedMemoryImport(
                    localIdentifier: localIdentifier
                )
            }
        }
    }

    deinit {
        if let sharingSyncObserver {
            NotificationCenter.default.removeObserver(sharingSyncObserver)
        }
        if let momentPresentationRefreshObserver {
            NotificationCenter.default.removeObserver(momentPresentationRefreshObserver)
        }
        if let receivedMemoryImportObserver {
            NotificationCenter.default.removeObserver(receivedMemoryImportObserver)
        }
    }

    /// Publishes a newly imported Photos asset into the ordinary "思い出"
    /// immediately. A selected scan-source album must not hide an explicit
    /// memory, so the durable snapshot keeps this record even before a later
    /// Vision pass enriches its cat metadata.
    private func refreshReceivedMemoryImport(localIdentifier: String?) async {
        _ = synchronizeSharedLikes(
            importLegacyLikes: false,
            trigger: "received-memory-import"
        )
        guard let localIdentifier,
              sharedLikeRecords[localIdentifier]?.isReceivedMemoryImport == true,
              sharedLikeRecords[localIdentifier]?.isLiked == true,
              !snapshot.assets.contains(where: {
                  $0.localIdentifier == localIdentifier
              })
        else {
            await saveSnapshot(reportErrors: false)
            return
        }

        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )
        guard let asset = result.firstObject, asset.mediaType == .image,
              let like = sharedLikeRecords[localIdentifier]
        else { return }

        let modificationDate = asset.modificationDate.map {
            Date(timeIntervalSince1970: floor($0.timeIntervalSince1970))
        }
        var updated = snapshot
        updated.assets.append(AssetRecord(
            localIdentifier: localIdentifier,
            creationDate: asset.creationDate,
            sourceModificationDate: modificationDate,
            sourceModificationDateWasCaptured: true,
            isFavorite: asset.isFavorite,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            burstIdentifier: asset.burstIdentifier,
            cat: .none,
            // This sentinel means that cat analysis has not completed yet;
            // the explicit memory remains displayable regardless.
            analysisStatus: .unavailableLocally,
            analysisFingerprint: settings.analysisFingerprint,
            analyzedAt: .now,
            albumAnalysisVersion: nil,
            albumTraits: nil,
            liked: true,
            likedAt: like.likedAt,
            lastShownAt: nil,
            shownCount: 0
        ))
        updated.updatedAt = .now
        snapshot = updated
        libraryChangePending = true
        refreshCurrentAsset()
        await saveSnapshot(reportErrors: true)
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        var startupSnapshotNeedsSave = false
        var loadedScanState: ScanState?
        SharedLog.app.info("lifecycle", "Application startup began")
        // The Share Extension promises that a queued explicit send resumes
        // when the app opens. Keep that lifecycle independent from scanner,
        // curation and cat-identity storage health.
        Task { @MainActor [weak self] in
            await self?.synchronizeMomentSharing(trigger: "launch")
        }

        guard await loadCatCandidateCuration() else {
            // Curation is part of the candidate authority. Recover only the
            // managed-album identifier from the snapshot so both external
            // outputs can be cleared without publishing any uncurated asset.
            if let store,
               let loaded = try? await store.load() {
                snapshot.albumLocalIdentifier = loaded.albumLocalIdentifier
            } else if let store,
                      let recovered = try? await store.recoverAlbumLocalIdentifier() {
                snapshot.albumLocalIdentifier = recovered
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
                loadedScanState = loaded.scanState
                applySnapshot(loaded, preservingLiveSettings: false)
                let likesChanged = synchronizeSharedLikes(
                    importLegacyLikes: true,
                    trigger: "startup"
                )
                startupSnapshotNeedsSave = likesChanged
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
                snapshot.albumLocalIdentifier = try? await store
                    .recoverAlbumLocalIdentifier()
                catIdentityLoadState = .failed
                currentAsset = nil
                hasFinishedSnapshotLoad = true
                discardPendingDeepLink(reason: "snapshot-state-unavailable")
                await clearAlbumAndWidgetOutputs(reportErrors: false)
                return
            }
        } else if let storeInitializationError {
            errorMessage = storeInitializationError
            catIdentityLoadState = .failed
            currentAsset = nil
            hasFinishedSnapshotLoad = true
            discardPendingDeepLink(reason: "snapshot-store-unavailable")
            await clearAlbumAndWidgetOutputs(reportErrors: false)
            return
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
        reconcileCandidatePostureState()
        chooseCurrentAssetIfNeeded()
        let scanStateWasReconciled = loadedScanState.map {
            $0 != snapshot.scanState
        } ?? false
        if startupSnapshotNeedsSave || scanStateWasReconciled {
            await saveSnapshot(reportErrors: false)
        }
        hasFinishedSnapshotLoad = true
        openPendingDeepLinkIfNeeded()
        authorizationStatus = authorizationService.status
        SharedLog.app.info(
            "permission",
            "Photo permission checked",
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
        guard catIdentityLoadState == .ready else {
            logCandidateAuthorityUnavailable(operation: "request_access")
            return
        }
        errorMessage = nil
        SharedLog.app.info("permission", "Photo permission request started")
        authorizationStatus = await authorizationService.requestAuthorization()
        SharedLog.app.info(
            "permission",
            "Photo permission request finished",
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
    func pollMomentSharingWhileActive(isSceneActive: Bool) async {
        let configuration = SharingAPIConfiguration.current
        let pairingState: PairingState?
        do {
            pairingState = try await Task.detached(priority: .utility) {
                try PairingStateStore.load()
            }.value
        } catch {
            return
        }
        guard !Task.isCancelled, isSceneActive else { return }
        let hasCurrentConsent =
            pairingState?.mediaSharingConsentVersion
                == PairingMediaSharingConsent.currentVersion
            && pairingState?.mediaSharingConsentAcceptedAt != nil
        guard MomentForegroundRefreshPolicy.shouldPoll(
            isSceneActive: isSceneActive,
            isMediaAvailable: configuration.isMediaAvailable,
            isPaired: pairingState?.phase == .paired,
            hasCurrentConsent: hasCurrentConsent
        ) else { return }
        await synchronizeMomentSharing(trigger: "foreground-poll")
    }

    func syncOnActive() async {
        Task { @MainActor [weak self] in
            await self?.synchronizeMomentSharing(trigger: "foreground")
        }
        guard catIdentityLoadState == .ready else {
            logCandidateAuthorityUnavailable(operation: "sync_on_active")
            return
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
        guard catIdentityLoadState == .ready else {
            logCandidateAuthorityUnavailable(operation: "full_rescan")
            return
        }
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

    func suspendScan() {
        guard isScanning else { return }
        let suspendedGeneration = scanGeneration
        var cancelled = latestScanProgressState(generation: suspendedGeneration)
        cancelled.phase = .cancelled
        publishTerminalScanProgress(
            cancelled,
            generation: suspendedGeneration,
            operation: "suspend"
        )
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
        Task { [snapshot, store] in
            try? await store?.save(snapshot)
        }
    }

    func setMemorySaved(id localIdentifier: String, isSaved: Bool) async {
        guard candidateAuthorityIsReady(operation: "set_memory_saved") else { return }
        guard let index = snapshot.assets.firstIndex(where: {
            $0.localIdentifier == localIdentifier
        }) else { return }

        errorMessage = nil
        let mutation: SharedLikeMutation
        do {
            mutation = try SharedLikeStore.set(
                localIdentifier: localIdentifier,
                isLiked: isSaved,
                at: .now,
                source: "app"
            )
        } catch {
            Self.logError(error, category: "like", operation: "set_shared_like")
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
            "Memory saved state set",
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
        guard candidateAuthorityIsReady(operation: "refresh_photo_sources") else { return }
        selectedSourceAssetIdentifiers = catCandidateCuration
            .lastKnownSourceAssetIdentifierSet
        guard canReadPhotos else {
            photoSourceAlbums = []
            photoSourceStatus = catCandidateCuration.usesSelectedAlbum
                ? .unavailable
                : .allLibrary
            unavailableProfilePhotoAlbumIdentifiers = Set(
                catHouseholdIdentity?.profiles.compactMap {
                    $0.photoAlbumLink?.localIdentifier
                } ?? []
            )
            profilePhotoAlbumAssetDates = [:]
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
        await refreshProfilePhotoAlbumLinks(availableAlbums: albums)
        reconcileCandidatePostureState()
        chooseCurrentAssetIfNeeded()
    }

    private func refreshProfilePhotoAlbumLinks(
        availableAlbums: [PhotoSourceAlbumOption]
    ) async {
        guard let identity = catHouseholdIdentity,
              identity.mode == .profiled else {
            profilePhotoAlbumAssetDates = [:]
            unavailableProfilePhotoAlbumIdentifiers = []
            return
        }
        let availableIdentifiers = Set(availableAlbums.map(\.localIdentifier))
        let links = identity.profiles.compactMap { profile in
            profile.photoAlbumLink.map { (profile.id, $0) }
        }
        guard !links.isEmpty else {
            profilePhotoAlbumAssetDates = [:]
            unavailableProfilePhotoAlbumIdentifiers = []
            return
        }

        var assetsByAlbum: [String: [PhotoSourceAlbumAssetMetadata]] = [:]
        var unavailableIdentifiers = Set(
            links.map { $0.1.localIdentifier }
        ).subtracting(availableIdentifiers)
        for albumIdentifier in Set(links.map { $0.1.localIdentifier })
        where availableIdentifiers.contains(albumIdentifier) {
            do {
                let assets = try await Task.detached(priority: .userInitiated) {
                    try PhotoSourceAlbumCatalog.accessibleImageAssets(
                        sourceAlbumIdentifier: albumIdentifier
                    )
                }.value
                assetsByAlbum[albumIdentifier] = assets
            } catch {
                unavailableIdentifiers.insert(albumIdentifier)
                Self.logError(
                    error,
                    category: "cat-identity",
                    operation: "refresh_profile_album"
                )
            }
        }
        var dates: [String: Date] = [:]
        for assets in assetsByAlbum.values {
            for asset in assets {
                if let creationDate = asset.creationDate {
                    dates[asset.localIdentifier] = creationDate
                }
            }
        }
        profilePhotoAlbumAssetDates = dates

        let updates = links.compactMap { profileID, link -> (UUID, String, [String])? in
            guard let assets = assetsByAlbum[link.localIdentifier] else { return nil }
            let resolution = CatProfilePhotoAlbumRefreshPolicy.resolve(
                lastKnownAssetLocalIdentifiers: link.lastKnownAssetLocalIdentifiers,
                accessibleAssetLocalIdentifiers: assets.map(\.localIdentifier),
                hasLimitedPhotosAccess: authorizationStatus == .limited
            )
            if resolution.shouldWarnAccessIsIncomplete {
                unavailableIdentifiers.insert(link.localIdentifier)
            }
            return (
                profileID,
                link.localIdentifier,
                assets.map(\.localIdentifier)
            )
        }
        unavailableProfilePhotoAlbumIdentifiers = unavailableIdentifiers
        guard !updates.isEmpty else { return }
        do {
            let hasLimitedPhotosAccess = authorizationStatus == .limited
            _ = try await mutateCatHouseholdIdentity { state in
                for update in updates {
                    let latestLastKnown = state.profiles.first(where: {
                        $0.id == update.0
                    })?.photoAlbumLink?.lastKnownAssetLocalIdentifiers ?? []
                    let resolution = CatProfilePhotoAlbumRefreshPolicy.resolve(
                        lastKnownAssetLocalIdentifiers: latestLastKnown,
                        accessibleAssetLocalIdentifiers: update.2,
                        hasLimitedPhotosAccess: hasLimitedPhotosAccess
                    )
                    state.refreshProfilePhotoAlbumLink(
                        profileID: update.0,
                        localIdentifier: update.1,
                        assetLocalIdentifiers: resolution.assetLocalIdentifiers
                    )
                }
            }
        } catch {
            Self.logError(
                error,
                category: "cat-identity",
                operation: "save_profile_album_refresh"
            )
        }
    }

    /// Removes candidates from app-managed surfaces only. PhotoKit is never
    /// mutated, and likes remain in their independent user-state ledger.
    func excludeFromCatCandidates(localIdentifiers: [String]) async {
        guard candidateAuthorityIsReady(operation: "exclude_candidates") else { return }
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
        guard candidateAuthorityIsReady(operation: "restore_candidates") else { return }
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
        guard candidateAuthorityIsReady(operation: "select_photo_source") else { return }
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
        guard candidateAuthorityIsReady(operation: "record_album_open") else { return }
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
        guard candidateAuthorityIsReady(operation: "sync_likes_for_presentation") else {
            return
        }
        let likesChanged = synchronizeSharedLikes(
            importLegacyLikes: false,
            trigger: trigger
        )
        guard likesChanged, hasFinishedSnapshotLoad else { return }
        await saveSnapshot(reportErrors: false)
    }

    func createOrUpdateAlbum() async {
        guard candidateAuthorityIsReady(operation: "create_or_update_album") else {
            return
        }
        await createOrUpdateAlbum(reportErrors: true)
    }

    func rebuildAlbum() async {
        await createOrUpdateAlbum()
    }

    /// Persists the birthday/adoption day without invalidating Vision results
    /// or rebuilding PhotoKit/Widget outputs. Curated time albums are derived
    /// directly from this published setting and regroup immediately.
    func updateCatLifeReference(_ reference: CatLifeReference?) async {
        guard candidateAuthorityIsReady(operation: "update_cat_life_reference") else {
            return
        }
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
        guard candidateAuthorityIsReady(operation: "create_cat_profile") else { return }
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
                        // This is the one photo the user explicitly selected
                        // while creating the profile. Suggestions never set
                        // this flag, but an explicit seed must remain usable.
                        isSimilarityReference: true
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
        guard candidateAuthorityIsReady(operation: "update_profile_life_reference") else {
            return
        }
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
        guard candidateAuthorityIsReady(operation: "update_profile_name") else { return }
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

    @discardableResult
    func setCatProfilePhotoAlbum(
        profileID: UUID,
        localIdentifier: String?
    ) async -> Bool {
        guard candidateAuthorityIsReady(operation: "set_profile_photo_album") else {
            return false
        }
        guard canReadPhotos else {
            setError(NekoWidgetError.photoAccessDenied)
            return false
        }

        do {
            let assetIdentifiers: [String]
            if let localIdentifier {
                await refreshPhotoSourceAlbums()
                guard localIdentifier != snapshot.albumLocalIdentifier,
                      photoSourceAlbums.contains(where: {
                          $0.localIdentifier == localIdentifier
                      }) else {
                    throw CatProfilePhotoAlbumError.unavailable
                }
                let assets = try await Task.detached(priority: .userInitiated) {
                    try PhotoSourceAlbumCatalog.accessibleImageAssets(
                        sourceAlbumIdentifier: localIdentifier
                    )
                }.value
                guard authorizationStatus != .limited || !assets.isEmpty else {
                    throw CatProfilePhotoAlbumError.unavailable
                }
                assetIdentifiers = assets.map(\.localIdentifier)
                unavailableProfilePhotoAlbumIdentifiers.remove(localIdentifier)
                var dates = profilePhotoAlbumAssetDates
                for asset in assets {
                    if let creationDate = asset.creationDate {
                        dates[asset.localIdentifier] = creationDate
                    }
                }
                profilePhotoAlbumAssetDates = dates
            } else {
                assetIdentifiers = []
            }

            let committed = try await mutateCatHouseholdIdentity { state in
                state.setProfilePhotoAlbumLink(
                    profileID: profileID,
                    localIdentifier: localIdentifier,
                    assetLocalIdentifiers: assetIdentifiers
                )
            }
            guard let committedProfile = committed.profiles.first(where: {
                $0.id == profileID
            }), committedProfile.photoAlbumLink?.localIdentifier
                == localIdentifier else { return false }
            SharedLog.app.info(
                "cat-identity",
                "Profile Photos album link changed",
                metadata: [
                    "linked": "\(localIdentifier != nil)",
                    "photos": "\(assetIdentifiers.count)"
                ]
            )
            return true
        } catch {
            Self.logError(
                error,
                category: "cat-identity",
                operation: "set_profile_photo_album"
            )
            setError(error)
            return false
        }
    }

    func deleteCatProfile(profileID: UUID) async {
        guard candidateAuthorityIsReady(operation: "delete_profile") else { return }
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
        guard candidateAuthorityIsReady(operation: "replace_profile_assignments") else {
            return
        }
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
                        let isLinkedAlbumPhoto = state.linkedPhotoAlbumContains(
                            identifier,
                            profileID: profileID
                        )
                        // Saving an unchanged album-derived assignment must not
                        // materialize it as a manual positive; otherwise unlinking
                        // the album would incorrectly retain every linked photo.
                        guard let decision = CatProfileManualAssignmentPolicy.decision(
                            isSelected: selected.contains(profileID),
                            previousDecision: previous?.decision,
                            isLinkedAlbumPhoto: isLinkedAlbumPhoto
                        ) else { continue }
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
                            isSimilarityReference: decision == .included
                                && previous?.isSimilarityReference == true
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
        guard candidateAuthorityIsReady(operation: "set_profile_membership") else {
            return
        }
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
                        isSimilarityReference: decision == .included
                            && previous?.isSimilarityReference == true
                    )
                }
            }
        } catch {
            Self.logError(error, category: "cat-identity", operation: "set_membership")
            setError(error)
        }
    }

    /// Commits one user-confirmed similarity group in a single identity CAS.
    /// FeaturePrint output itself never reaches this method as authority: the
    /// caller supplies the exact boxes only after the user taps a profile.
    func confirmCatSimilarityGroup(
        profileID: UUID,
        candidates: [CatSimilarityCandidateInstance]
    ) async -> CatSimilarityGroupConfirmationOutcome {
        guard candidateAuthorityIsReady(operation: "confirm_similarity_group") else {
            return .conflict(reason: .staleCandidates)
        }
        let uniqueCandidates = Array(Set(candidates)).sorted(by: stableCandidateOrder)
        guard !uniqueCandidates.isEmpty,
              uniqueCandidates.count == candidates.count,
              Set(uniqueCandidates.map(\.assetLocalIdentifier)).count
                == uniqueCandidates.count else {
            return .conflict(reason: .invalidGroup)
        }

        var outcome = CatSimilarityGroupConfirmationOutcome.failed
        await serializeCatIdentityTransition {
            outcome = await self.performConfirmCatSimilarityGroup(
                profileID: profileID,
                candidates: uniqueCandidates
            )
        }
        return outcome
    }

    private func performConfirmCatSimilarityGroup(
        profileID: UUID,
        candidates: [CatSimilarityCandidateInstance]
    ) async -> CatSimilarityGroupConfirmationOutcome {
        do {
            var latestOutcome = CatSimilarityGroupConfirmationOutcome.conflict(
                reason: .staleCandidates
            )
            let committed = try await mutateCatHouseholdIdentity { state in
                latestOutcome = .conflict(reason: .staleCandidates)
                let unresolvedInLatestState = Set(
                    self.catSimilarityCandidateInstances(in: state)
                )
                guard state.profiles.contains(where: { $0.id == profileID }) else {
                    return
                }
                var candidatesToAssign: [CatSimilarityCandidateInstance] = []
                candidatesToAssign.reserveCapacity(candidates.count)
                for candidate in candidates {
                    guard !state.isGloballyExcluded(candidate.assetLocalIdentifier) else {
                        latestOutcome = .conflict(reason: .staleCandidates)
                        return
                    }
                    let previous = state.membership(
                        for: candidate.assetLocalIdentifier,
                        profileID: profileID
                    )
                    let decision = CatSimilaritySuggestionConfirmationPolicy.decision(
                        hasIncludedMembership: previous?.decision == .included,
                        existingSubjectBoundingBox: previous?.subjectBoundingBox,
                        candidateBoundingBox: candidate.boundingBox
                    )
                    if decision == .alreadyCommitted {
                        // A retry may include an exact membership that already
                        // committed before an unrelated persistence failure.
                        continue
                    }
                    guard decision != .profileAlreadyAssigned else {
                        latestOutcome = .conflict(reason: .profileAlreadyAssigned)
                        return
                    }
                    guard unresolvedInLatestState.contains(candidate) else {
                        latestOutcome = .conflict(reason: .staleCandidates)
                        return
                    }
                    candidatesToAssign.append(candidate)
                }
                for candidate in candidatesToAssign {
                    let previous = state.membership(
                        for: candidate.assetLocalIdentifier,
                        profileID: profileID
                    )
                    state.setManualMembership(
                        assetLocalIdentifier: candidate.assetLocalIdentifier,
                        profileID: profileID,
                        decision: .included,
                        subjectBoundingBox: candidate.boundingBox,
                        // A suggestion never becomes a learning anchor, but
                        // reconfirming an existing explicit seed must not erase it.
                        isSimilarityReference: previous?.isSimilarityReference == true
                    )
                }
                latestOutcome = .committed
            }
            guard latestOutcome == .committed else { return latestOutcome }
            let didCommitAll = candidates.allSatisfy { candidate in
                guard let membership = committed.membership(
                    for: candidate.assetLocalIdentifier,
                    profileID: profileID
                ) else { return false }
                return membership.decision == .included
                    && membership.subjectBoundingBox == candidate.boundingBox
            }
            if didCommitAll {
                SharedLog.app.info(
                    "cat-identity",
                    "User confirmed a similarity review group",
                    metadata: ["instances": "\(candidates.count)"]
                )
                return .committed
            }
            SharedLog.app.error(
                "cat-identity",
                "Similarity confirmation commit could not be verified",
                metadata: ["instances": "\(candidates.count)"]
            )
            return .failed
        } catch {
            Self.logError(
                error,
                category: "cat-identity",
                operation: "confirm_similarity_group"
            )
            setError(error)
            return .failed
        }
    }

    func updateSettings(_ newSettings: AppSettings) async {
        guard candidateAuthorityIsReady(operation: "update_settings") else { return }
        var normalized = newSettings.normalized()
        let detectionChanged = normalized.confidenceThreshold != settings.confidenceThreshold
        let displayRangeChanged = normalized.dateRange != settings.dateRange
        let widgetPolicyChanged = normalized.minimumCatAreaRatio
            != settings.minimumCatAreaRatio
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
                "displayRangeChanged": "\(displayRangeChanged)",
                "widgetPolicyChanged": "\(widgetPolicyChanged)"
            ]
        )
        snapshot.settings = normalized
        snapshot.updatedAt = .now
        if displayRangeChanged || widgetPolicyChanged {
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
        } else {
            await refreshManagedOutputs(reportErrors: false)
        }
    }

    func exportJSON() async -> URL? {
        guard candidateAuthorityIsReady(operation: "export_json") else { return nil }
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

    private func synchronizeMomentSharing(trigger: String) async {
        await synchronizeMomentSharing(
            trigger: trigger,
            expectedSpaceID: nil
        )
    }

    private func synchronizeMomentSharing(
        trigger: String,
        expectedSpaceID: String?
    ) async {
        guard UIApplication.shared.isProtectedDataAvailable else {
            // The room credential is intentionally WhenUnlockedThisDeviceOnly.
            // A launch/prewarm can reach this task before protected data is
            // readable; defer without asking the installation guard to
            // interpret that temporary condition as credential loss.
            SharedLog.app.warning(
                "moment-sharing",
                "Moment synchronization deferred",
                metadata: [
                    "trigger": String(trigger.prefix(32)),
                    "sharingFailureReason": "protected-data-unavailable"
                ]
            )
            return
        }
        await momentSharingCoordinator.synchronize(
            trigger: trigger,
            expectedSpaceID: expectedSpaceID
        )
        guard !Task.isCancelled else { return }
        if let expectedSpaceID {
            guard Self.activePrivateWindowMatches(spaceID: expectedSpaceID) else {
                SharedLog.app.info(
                    "moment-notification",
                    "Notification refresh stopped because the selected private window changed"
                )
                return
            }
        }
        await refreshFamilyWindowOutputs(trigger: trigger)
        guard !Task.isCancelled else { return }
        // FamilyWindowView owns a separate presentation model. Tell an open
        // screen to reload the durable ledger only; it must not start another
        // network pass and form a synchronization loop.
        NotificationCenter.default.post(
            name: .momentSharingContentNeedsReload,
            object: nil
        )
    }

    func refreshFamilyWindowOutputs(trigger: String) async {
        guard UIApplication.shared.isProtectedDataAvailable else {
            SharedLog.app.warning(
                "moment-sharing",
                "Family window presentation refresh deferred",
                metadata: [
                    "sharingFailureReason": "protected-data-unavailable",
                    "trigger": String(trigger.prefix(32))
                ]
            )
            return
        }
        familyWindowRefreshSequence += 1
        let refreshSequence = familyWindowRefreshSequence
        // The durable sharing ledger may already have hidden, revoked or
        // removed the previously presented item. Keep Home fail-closed while
        // bootstrap, state validation and Widget publication are in flight.
        familyWindowPresentation = .empty
        var lifecycleToken: SharingLifecycleGate.Token?
        do {
            let bootstrap = try await PairingInstallationGuard.bootstrapAsync()
            lifecycleToken = bootstrap.lifecycleToken
            guard refreshSequence == familyWindowRefreshSequence else { return }
            privateWindowDisplayName = PrivateWindowPresentationStore.resolvedDisplayName(
                pairing: bootstrap.state,
                validating: bootstrap.lifecycleToken
            )
            let configuration = SharingAPIConfiguration.current
            guard configuration.isMediaAvailable,
                  bootstrap.state.phase == .paired,
                  bootstrap.state.mediaSharingConsentVersion
                    == PairingMediaSharingConsent.currentVersion,
                  bootstrap.state.mediaSharingConsentAcceptedAt != nil
            else {
                familyWindowPresentation = .empty
                _ = try await widgetCacheBuilder.clearFamilyWindow(
                    validating: bootstrap.lifecycleToken,
                    windowDisplayName: bootstrap.state.spaceID == nil
                        ? nil
                        : privateWindowDisplayName
                )
                WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
                return
            }

            let stateAndInputs = try await Task.detached(priority: .utility) {
                let state = try MomentSharingStateStore.load(
                    validating: bootstrap.lifecycleToken
                )
                return (state, Self.familyWindowInputs(from: state))
            }.value
            guard refreshSequence == familyWindowRefreshSequence else { return }
            let presentation = MomentFamilyWindowPresentationPolicy.make(
                inputs: stateAndInputs.1,
                now: .now
            )
            let latestItem = presentation.latestStableID.flatMap { stableID in
                stateAndInputs.0.inbox.first(where: { $0.id == stableID })
            }
            let familyManifest = try await widgetCacheBuilder.buildFamilyWindow(
                from: latestItem,
                freshUntil: presentation.priorityUntil,
                windowDisplayName: privateWindowDisplayName,
                validating: bootstrap.lifecycleToken
            )
            guard refreshSequence == familyWindowRefreshSequence else { return }
            // WidgetCacheBuilder revalidates both lifecycle and the durable
            // inbox immediately before publication. Do not surface the same
            // candidate on Home until that fail-closed boundary succeeds.
            if familyManifest.item != nil {
                familyWindowPresentation = presentation
            }
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
            SharedLog.app.debug(
                "family-window",
                "Family presentation refreshed",
                metadata: [
                    "displayable": "\(familyWindowPresentation.safeCount)",
                    "priority": "\(familyWindowPresentation.isPriority)",
                    "trigger": String(trigger.prefix(32))
                ]
            )
        } catch {
            guard refreshSequence == familyWindowRefreshSequence else { return }
            familyWindowPresentation = .empty
            if let lifecycleToken {
                _ = try? await widgetCacheBuilder.clearFamilyWindow(
                    validating: lifecycleToken,
                    windowDisplayName: privateWindowDisplayName
                )
                WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
            }
            Self.logError(
                error,
                category: "family-window",
                operation: "refresh_presentation"
            )
        }
    }

    private nonisolated static func familyWindowInputs(
        from state: MomentSharingState
    ) -> [MomentFamilyWindowPresentationInput] {
        state.inbox.map { item in
            let presentationState: MomentFamilyWindowItemState
            switch item.state {
            case .available: presentationState = .available
            case .acknowledged: presentationState = .acknowledged
            case .blocked: presentationState = .blocked
            case .revoked: presentationState = .revoked
            }
            return MomentFamilyWindowPresentationInput(
                stableID: item.id,
                state: presentationState,
                imageURL: validatedReceivedMomentImageURL(for: item),
                committedAt: item.committedAt,
                receivedAt: item.receivedAt
            )
        }
    }

    private nonisolated static func validatedReceivedMomentImageURL(
        for item: MomentInboxItem
    ) -> URL? {
        guard item.state == .available || item.state == .acknowledged,
              let filename = item.localJPEGFileName,
              filename == "\(item.id).jpg",
              filename == (filename as NSString).lastPathComponent,
              let directory = SharedContainer.momentSharingReceivedDirectoryURL
        else { return nil }
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.deletingLastPathComponent() == resolvedDirectory,
              let values = try? resolvedURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= MomentSharingProtocol.maximumMediaCiphertextBytes - 28,
              let source = CGImageSourceCreateWithURL(
                resolvedURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...MomentSharingProtocol.maximumCanonicalPixelDimension).contains(width),
              (1...MomentSharingProtocol.maximumCanonicalPixelDimension).contains(height)
        else { return nil }
        return resolvedURL
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
        case let .familyWindow(localWindowID, sourceDigest):
            guard SharingAPIConfiguration.current.isReviewVisible else {
                SharedLog.app.info(
                    "deeplink",
                    "Ignored family window deep link because sharing is unavailable"
                )
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let localWindowID {
                    do {
                        _ = try await PairingInstallationGuard.activatePrivateWindowAsync(
                            localWindowID: localWindowID
                        )
                        await MomentPushSubscriptionService.shared
                            .reconcileRegistration()
                        await self.refreshFamilyWindowOutputs(
                            trigger: "widget-window-selection"
                        )
                    } catch {
                        Self.logError(
                            error,
                            category: "family-window",
                            operation: "activate_widget_window"
                        )
                        return
                    }
                }
                self.pendingFamilyNotificationRoute = nil
                self.pendingFamilyMomentSourceDigest = sourceDigest
                self.isFamilyWindowPresented = true
                SharedLog.app.info("deeplink", "Opened private window from Widget")
            }
            return
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

    func handleMomentNotificationRoute(_ route: MomentNotificationRoute) async {
        momentNotificationRouteGeneration &+= 1
        let generation = momentNotificationRouteGeneration
        await momentNotificationRoutingGate.acquire()
        guard generation == momentNotificationRouteGeneration else {
            await momentNotificationRoutingGate.release()
            return
        }
        await handleSerializedMomentNotificationRoute(
            route,
            generation: generation
        )
        await momentNotificationRoutingGate.release()
    }

    private func handleSerializedMomentNotificationRoute(
        _ route: MomentNotificationRoute,
        generation: Int
    ) async {
        guard SharingAPIConfiguration.current.isMediaAvailable else {
            SharedLog.app.info(
                "moment-notification",
                "Ignored notification route because sharing is unavailable"
            )
            return
        }

        if let target = route.target {
            do {
                guard let catalog = try PrivateWindowCatalogStore.load()
                else {
                    SharedLog.app.info(
                        "moment-notification",
                        "Ignored notification because its private window was unavailable",
                        metadata: ["kind": route.kind.rawValue]
                    )
                    return
                }
                let matches = catalog.windows.filter { $0.spaceID == target.spaceID }
                guard matches.count == 1, let targetWindow = matches.first else {
                    SharedLog.app.info(
                        "moment-notification",
                        "Ignored notification because its private window could not be resolved",
                        metadata: ["kind": route.kind.rawValue]
                    )
                    return
                }

                let switchesWindow = catalog.activeWindowID != targetWindow.localWindowID
                if switchesWindow {
                    _ = try await PairingInstallationGuard.activatePrivateWindowAsync(
                        localWindowID: targetWindow.localWindowID
                    )
                    guard generation == momentNotificationRouteGeneration else { return }
                    NotificationCenter.default.post(
                        name: .momentSharingPresentationNeedsRefresh,
                        object: nil
                    )
                }
                // Open the verified destination immediately. FamilyWindowView
                // keeps the route pending until synchronization materializes
                // exactly one matching moment, so the tap never appears inert
                // while the network is still running.
                pendingFamilyMomentSourceDigest = nil
                pendingFamilyNotificationRoute = route
                isFamilyWindowPresented = true
                // Synchronization reads only the now-active window. It never
                // walks credentials for unrelated windows in response to this
                // foreground notification tap.
                await synchronizeMomentSharing(
                    trigger: "notification-target",
                    expectedSpaceID: target.spaceID
                )
                guard generation == momentNotificationRouteGeneration else { return }
                if switchesWindow {
                    await MomentPushSubscriptionService.shared.reconcileRegistration()
                    guard generation == momentNotificationRouteGeneration else { return }
                }
                SharedLog.app.info(
                    "moment-notification",
                    "Opened targeted private window from notification",
                    metadata: ["kind": route.kind.rawValue]
                )
                return
            } catch {
                Self.logError(
                    error,
                    category: "moment-notification",
                    operation: "activate_notification_window"
                )
                return
            }
        }

        pendingFamilyMomentSourceDigest = nil
        pendingFamilyNotificationRoute = route
        isFamilyWindowPresented = true
        SharedLog.app.info(
            "moment-notification",
            "Opened selected private window from notification",
            metadata: ["kind": route.kind.rawValue]
        )
    }

    private nonisolated static func activePrivateWindowMatches(
        spaceID: String
    ) -> Bool {
        do {
            guard let catalog = try PrivateWindowCatalogStore.load(),
                  let active = catalog.windows.first(where: {
                      $0.localWindowID == catalog.activeWindowID
                  })
            else { return false }
            return active.spaceID == spaceID
        } catch {
            return false
        }
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
            metadata: ["routeOutcome": reason]
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
            let metadata = [
                "asset": SharedLog.shortHash(localIdentifier),
                "decodedBytesEstimate": "\(width * height * 4)",
                "durationMs": String(format: "%.1f", elapsedMilliseconds),
                "networkAllowed": "true",
                "outputPixels": "\(width)x\(height)",
                "requestedPixels": "\(Int(targetSize.width))x\(Int(targetSize.height))",
                "successOrdinal": "\(successfulImageLoadCount)"
            ]
            if image == nil {
                SharedLog.app.warning(
                    "image",
                    "Photo image load failed",
                    metadata: metadata
                )
            } else {
                SharedLog.app.debug(
                    "image",
                    "Photo image loaded (sampled)",
                    metadata: metadata
                )
            }
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
        let boxes = record.resolvedCatBoundingBoxes.boundingBoxes
        if let existing,
           boxes.contains(where: { Self.intersectionOverUnion($0, existing) >= 0.5 }) {
            return existing
        }
        if record.cat.catCount <= 1, boxes.count == 1 {
            return boxes[0]
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
        let summary = PostureScanSummary(records: candidateSnapshot(snapshot).catAssets)
        scanState.postureSummary = summary
        // Build 13-15's posture repair route is decode-only. Bbox posture
        // albums are derived locally and must never schedule another scan.
        if scanState.purpose == .postureRepair {
            scanState.purpose = nil
        }
        snapshot.scanState = scanState
    }

    private func refreshCandidateOutputsAfterCurationChange(
        reportErrors: Bool = true
    ) async {
        logBoundingBoxAspectDistribution(trigger: "candidate-output-refresh")
        // PhotoAlbumService is an actor. Always enqueue this generation behind
        // any in-flight stale membership update; a time-bounded status poll can
        // otherwise return without ever removing an excluded photo.
        // This follows an explicit user correction. Surface a failure instead
        // of silently leaving either managed output on the old generation.
        await refreshManagedOutputs(reportErrors: reportErrors)
    }

    private func launchScan(forceFullAnalysis: Bool) async {
        guard catIdentityLoadState == .ready else {
            logCandidateAuthorityUnavailable(operation: "launch_scan")
            return
        }
        // A replacement scan should be able to reuse every batch already
        // analyzed by the previous generation. Merge its pending records before
        // invalidating that generation; the new scan will apply its own starting
        // state immediately below.
        if pendingScanProgress?.generation == scanGeneration {
            // `rescan()` may already have changed purpose/settings on the live
            // state. Merge old-generation records without letting its older
            // progress state roll that user action back.
            publishTerminalScanProgress(
                scanState,
                generation: scanGeneration,
                operation: "replace_generation"
            )
        }
        scanGeneration += 1
        let generation = scanGeneration
        resetScanProgressCoalescer()

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

            discardPendingScanProgress(generation: generation)
            applySnapshot(final)
            lastScanProgressPublicationUptime = ProcessInfo.processInfo.systemUptime
            chooseCurrentAssetIfNeeded()
            await saveSnapshot(reportErrors: true)
            logBoundingBoxAspectDistribution(trigger: "scan-final")
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

            await refreshManagedOutputs(reportErrors: false)
        } catch is CancellationError {
            guard generation == scanGeneration else { return }
            var cancelled = latestScanProgressState(generation: generation)
            cancelled.phase = .cancelled
            publishTerminalScanProgress(
                cancelled,
                generation: generation,
                operation: "cancel"
            )
            SharedLog.app.info(
                "scan",
                "Scan task cancelled",
                metadata: ["generation": "\(generation)"]
            )
            await saveSnapshot(reportErrors: false)
        } catch CatCandidateCurationError.selectedSourceUnavailable {
            guard generation == scanGeneration else { return }
            photoSourceStatus = .unavailable
            var failed = latestScanProgressState(generation: generation)
            failed.phase = .failed
            failed.lastError = Self.userFacingMessage(
                for: CatCandidateCurationError.selectedSourceUnavailable
            )
            publishTerminalScanProgress(
                failed,
                generation: generation,
                operation: "source_unavailable"
            )
            SharedLog.app.warning(
                "curation",
                "Selected photo source became unavailable; previous candidates retained"
            )
            setError(CatCandidateCurationError.selectedSourceUnavailable)
            await saveSnapshot(reportErrors: false)
        } catch {
            guard generation == scanGeneration else { return }
            var failed = latestScanProgressState(generation: generation)
            failed.phase = .failed
            failed.lastError = Self.userFacingMessage(for: error)
            publishTerminalScanProgress(
                failed,
                generation: generation,
                operation: "failure"
            )
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
            await enqueueScanProgress(
                published,
                analyzedRecords: analyzedRecords,
                generation: generation
            )

        case let .provisional(provisional):
            // The scanner's provisional snapshot contains every quick-stage
            // record, including any still held by the UI coalescer.
            discardPendingScanProgress(generation: generation)
            applySnapshot(provisional)
            lastScanProgressPublicationUptime = ProcessInfo.processInfo.systemUptime
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
                // Limited access can shrink, or assets can be deleted, before
                // the full scan completes. Reconcile album and Widget gates
                // independently so small/low-fidelity cats remain in albums.
                await refreshManagedOutputs(reportErrors: false)
            }
        }
    }

    private func enqueueScanProgress(
        _ state: ScanState,
        analyzedRecords: [AssetRecord],
        generation: Int
    ) async {
        guard generation == scanGeneration else { return }

        if var pending = pendingScanProgress,
           pending.generation == generation {
            pending.state = state
            pending.analyzedRecords.append(contentsOf: analyzedRecords)
            pending.eventCount += 1
            pendingScanProgress = pending
        } else {
            discardPendingScanProgress(generation: pendingScanProgress?.generation)
            pendingScanProgress = PendingScanProgress(
                generation: generation,
                state: state,
                analyzedRecords: analyzedRecords,
                eventCount: 1
            )
        }

        let now = ProcessInfo.processInfo.systemUptime
        let delay = ScanProgressPublicationPolicy.delay(
            lastPublicationUptime: lastScanProgressPublicationUptime,
            nowUptime: now
        )
        let isResumeCheckpoint = ScanProgressPublicationPolicy
            .isResumeCheckpoint(scannedAssets: state.scannedAssets)

        if delay == 0 {
            publishPendingScanProgress(
                generation: generation,
                operation: "timer_ready"
            )
            if isResumeCheckpoint {
                await saveSnapshot(reportErrors: false)
            }
            return
        }

        scheduleScanProgressPublication(
            after: delay,
            generation: generation
        )

        if isResumeCheckpoint {
            // Persistence must not depend on a screen refresh. Save a merged
            // value containing every pending record while leaving UI delivery
            // on its one-update-per-second cadence.
            await savePendingScanCheckpoint(generation: generation)
        }
    }

    private func scheduleScanProgressPublication(
        after delay: TimeInterval,
        generation: Int
    ) {
        guard scanProgressFlushTask == nil else { return }
        let delayMilliseconds = max(1, Int((delay * 1_000).rounded(.up)))
        scanProgressFlushSequence &+= 1
        let sequence = scanProgressFlushSequence
        scanProgressFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            } catch {
                return
            }
            guard let self,
                  generation == self.scanGeneration,
                  sequence == self.scanProgressFlushSequence else { return }
            self.scanProgressFlushTask = nil
            self.publishPendingScanProgress(
                generation: generation,
                operation: "coalesced_timer"
            )
        }
    }

    private func publishPendingScanProgress(
        generation: Int,
        operation: String
    ) {
        guard let pending = pendingScanProgress,
              pending.generation == generation else { return }

        scanProgressFlushTask?.cancel()
        scanProgressFlushTask = nil
        scanProgressFlushSequence &+= 1
        pendingScanProgress = nil

        let publication = makeScanProgressSnapshot(
            state: pending.state,
            analyzedRecords: pending.analyzedRecords
        )
        scanState = publication.state
        snapshot = publication.snapshot
        lastScanProgressPublicationUptime = ProcessInfo.processInfo.systemUptime
        chooseCurrentAssetIfNeeded()

        SharedLog.app.info(
            "scan",
            "Scan progress published",
            metadata: Self.scanLogMetadata(
                [
                    "cats": "\(publication.catAssetCount)",
                    "coalescedEvents": "\(pending.eventCount)",
                    "deferred": "\(publication.state.deferredAssets)",
                    "operation": operation,
                    "records": "\(pending.analyzedRecords.count)",
                    "phase": publication.state.phase.rawValue,
                    "scanned": "\(publication.state.scannedAssets)",
                    "total": "\(publication.state.totalAssets)"
                ],
                state: publication.state
            )
        )
    }

    private func publishTerminalScanProgress(
        _ terminalState: ScanState,
        generation: Int,
        operation: String
    ) {
        let analyzedRecords: [AssetRecord]
        if let pending = pendingScanProgress,
           pending.generation == generation {
            analyzedRecords = pending.analyzedRecords
        } else {
            analyzedRecords = []
        }
        discardPendingScanProgress(generation: generation)

        let publication = makeScanProgressSnapshot(
            state: terminalState,
            analyzedRecords: analyzedRecords
        )
        scanState = publication.state
        snapshot = publication.snapshot
        lastScanProgressPublicationUptime = ProcessInfo.processInfo.systemUptime
        chooseCurrentAssetIfNeeded()
        SharedLog.app.debug(
            "scan",
            "Pending scan progress flushed at scan boundary",
            metadata: [
                "operation": operation,
                "records": "\(analyzedRecords.count)",
                "scanned": "\(publication.state.scannedAssets)"
            ]
        )
    }

    private func latestScanProgressState(generation: Int) -> ScanState {
        guard let pending = pendingScanProgress,
              pending.generation == generation else { return scanState }
        return pending.state
    }

    private func discardPendingScanProgress(generation: Int?) {
        guard generation == nil
            || pendingScanProgress?.generation == generation else { return }
        scanProgressFlushTask?.cancel()
        scanProgressFlushTask = nil
        scanProgressFlushSequence &+= 1
        pendingScanProgress = nil
    }

    private func resetScanProgressCoalescer() {
        scanProgressFlushTask?.cancel()
        scanProgressFlushTask = nil
        scanProgressFlushSequence &+= 1
        pendingScanProgress = nil
        lastScanProgressPublicationUptime = nil
    }

    private func savePendingScanCheckpoint(generation: Int) async {
        guard let pending = pendingScanProgress,
              pending.generation == generation else { return }
        let checkpoint = makeScanProgressSnapshot(
            state: pending.state,
            analyzedRecords: pending.analyzedRecords
        )
        await saveSnapshot(checkpoint.snapshot, reportErrors: false)
    }

    /// Produces the one value assigned to `snapshot` for a UI publication. A
    /// stable index preserves the existing asset order and lets every pending
    /// batch be merged in one pass instead of rebuilding a full dictionary for
    /// each scanner event.
    private func makeScanProgressSnapshot(
        state: ScanState,
        analyzedRecords: [AssetRecord]
    ) -> ScanProgressSnapshot {
        var updated = snapshot
        if !analyzedRecords.isEmpty {
            var indexByIdentifier = Dictionary(
                uniqueKeysWithValues: updated.assets.indices.map {
                    (updated.assets[$0].localIdentifier, $0)
                }
            )
            for record in analyzedRecords {
                let existingIndex = indexByIdentifier[record.localIdentifier]
                var merged = record.preservingUserState(
                    from: existingIndex.map { updated.assets[$0] }
                )
                if let sharedLike = sharedLikeRecords[record.localIdentifier] {
                    merged.liked = sharedLike.isLiked
                    merged.likedAt = sharedLike.likedAt
                }
                if let existingIndex {
                    updated.assets[existingIndex] = merged
                } else {
                    indexByIdentifier[record.localIdentifier] = updated.assets.count
                    updated.assets.append(merged)
                }
            }
        }

        let candidateCats = candidateSnapshot(updated).catAssets
        var reconciledState = ScanProgressPublicationPolicy
            .preservingLiveRescanIntent(
                pending: state,
                live: snapshot.scanState
            )
        // A user-requested full scan is monotonic until the replacement scan
        // starts. An older generation's delayed timer must not roll the intent
        // back while `rescan()` is awaiting durable storage.
        reconciledState.postureSummary = PostureScanSummary(records: candidateCats)
        if reconciledState.purpose == .postureRepair {
            reconciledState.purpose = nil
        }
        updated.scanState = reconciledState
        updated.updatedAt = .now
        return ScanProgressSnapshot(
            snapshot: updated,
            state: reconciledState,
            catAssetCount: candidateCats.count
        )
    }

    private func applySnapshot(
        _ newSnapshot: LibrarySnapshot,
        preservingLiveSettings: Bool = true
    ) {
        // A full scan can run while the user adds a photo to “思い出” or while the
        // quick-stage album/cache publication updates display history. Merge
        // those live mutations instead of replacing them with scan-start state.
        let durableLikeRecords = sharedLikeRecords.isEmpty
            ? ((try? SharedLikeStore.readAll()) ?? [:])
            : sharedLikeRecords
        let receivedImportIdentifiers = Set(durableLikeRecords.compactMap {
            key,
            value in
            value.isReceivedMemoryImport == true ? key : nil
        })
        var currentlyVisibleImportIdentifiers = Set<String>()
        if !receivedImportIdentifiers.isEmpty {
            let result = PHAsset.fetchAssets(
                withLocalIdentifiers: Array(receivedImportIdentifiers),
                options: nil
            )
            result.enumerateObjects { asset, _, _ in
                currentlyVisibleImportIdentifiers.insert(asset.localIdentifier)
            }
        }
        let canConcludeImportedAssetWasDeleted =
            PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
        if canConcludeImportedAssetWasDeleted {
            let confirmedDeleted = receivedImportIdentifiers
                .subtracting(currentlyVisibleImportIdentifiers)
            for identifier in confirmedDeleted {
                if let mutation = try? SharedLikeStore.set(
                    localIdentifier: identifier,
                    isLiked: false,
                    source: "received-memory-deleted"
                ) {
                    sharedLikeRecords[identifier] = mutation.record
                }
            }
        }
        let liveByIdentifier = Dictionary(
            uniqueKeysWithValues: snapshot.assets.map { ($0.localIdentifier, $0) }
        )
        var merged = newSnapshot
        merged.assets = newSnapshot.assets.filter {
            !receivedImportIdentifiers.contains($0.localIdentifier)
                || currentlyVisibleImportIdentifiers.contains($0.localIdentifier)
        }.map {
            var record = $0.preservingUserState(from: liveByIdentifier[$0.localIdentifier])
            if let sharedLike = sharedLikeRecords[record.localIdentifier] {
                record.liked = sharedLike.isLiked
                record.likedAt = sharedLike.likedAt
            }
            return record
        }
        // A selected scan-source album legitimately omits Photos assets that
        // were explicitly imported from a private window. Those assets still
        // belong to the person's global "思い出" collection. Preserve their
        // latest local records instead of letting an unrelated scan erase
        // them from the PDF/book source pool.
        let scannedIdentifiers = Set(merged.assets.map(\.localIdentifier))
        merged.assets.append(contentsOf: liveByIdentifier.values.filter {
            !scannedIdentifiers.contains($0.localIdentifier)
                && sharedLikeRecords[$0.localIdentifier]?.isReceivedMemoryImport == true
                && currentlyVisibleImportIdentifiers.contains($0.localIdentifier)
        }.sorted { $0.localIdentifier < $1.localIdentifier })
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

        let candidateCats = candidateSnapshot(merged).catAssets
        merged.scanState.postureSummary = PostureScanSummary(records: candidateCats)
        if merged.scanState.purpose == .postureRepair {
            merged.scanState.purpose = nil
        }

        snapshot = merged
        scanState = merged.scanState
        settings = merged.settings.normalized()
        refreshCurrentAsset()
    }

    /// Reads only cached detector rectangles from the already-filtered
    /// candidate snapshot. No PhotoKit image request or Vision request occurs.
    private func logBoundingBoxAspectDistribution(trigger: String) {
        let distribution = CatBoundingBoxAspectDistribution(
            records: candidateSnapshot(snapshot).catAssets
        )
        var metadata = distribution.logMetadata
        metadata["trigger"] = trigger
        SharedLog.app.info(
            "album",
            "Cat bounding-box aspect distribution measured",
            metadata: metadata
        )
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
                    && $0.isWidgetEligible(settings: settings)
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
            $0.localIdentifier == identifier
                && $0.isWidgetEligible(settings: settings)
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
            if model.hasEligibleAlbumCandidates(in: model.snapshot) {
                await model.performCreateOrUpdateAlbum(reportErrors: reportErrors)
            } else {
                await model.performClearManagedAlbum(reportErrors: reportErrors)
            }
            if model.hasEligibleDisplayCandidates(in: model.snapshot) {
                await model.performRebuildWidgetCache(reportErrors: reportErrors)
            } else {
                await model.performClearWidgetOutput(reportErrors: reportErrors)
            }
        }
    }

    private func performCreateOrUpdateAlbum(reportErrors: Bool) async {
        let selected = albumSelector.select(from: candidateSnapshot(snapshot))
        guard !selected.isEmpty else {
            await performClearManagedAlbum(reportErrors: false)
            albumStatus = .failed(
                message: Self.userFacingMessage(for: NekoWidgetError.noCatPhotos)
            )
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
            albumStatus = .failed(message: Self.userFacingMessage(for: error))
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
            albumStatus = .failed(message: Self.userFacingMessage(for: error))
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

    private func hasEligibleAlbumCandidates(in value: LibrarySnapshot) -> Bool {
        !albumSelector.select(from: candidateSnapshot(value)).isEmpty
    }

    private func saveSnapshot(reportErrors: Bool) async {
        await saveSnapshot(snapshot, reportErrors: reportErrors)
    }

    private func saveSnapshot(
        _ value: LibrarySnapshot,
        reportErrors: Bool
    ) async {
        guard catIdentityLoadState == .ready else {
            logCandidateAuthorityUnavailable(operation: "save_snapshot")
            return
        }
        guard let store else {
            if reportErrors,
               let storeInitializationError {
                errorMessage = storeInitializationError
            }
            return
        }
        do {
            try await store.save(value)
        } catch {
            Self.logError(error, category: "storage", operation: "save_snapshot")
            if reportErrors { setError(error) }
        }
    }

    private func setError(_ error: Error) {
        errorMessage = Self.userFacingMessage(for: error)
        Self.logError(error, category: "error", operation: "present_to_user")
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let value = error as? NekoWidgetError {
            switch value {
            case .appGroupUnavailable:
                return "アプリの保存領域を利用できません。アプリを更新して、もう一度お試しください。"
            case .photoAccessDenied:
                return "写真へのアクセスが許可されていません。iPhoneの設定を確認してください。"
            case .albumCreationFailed:
                return "写真アルバムを更新できませんでした。写真へのアクセスと空き容量を確認してください。"
            case .noCatPhotos:
                return "表示できる猫の写真がまだありません。"
            case .exportFailed:
                return "データを書き出せませんでした。空き容量を確認して、もう一度お試しください。"
            }
        }
        if let value = error as? CatCandidateCurationError {
            return value.errorDescription
                ?? "写真の対象設定を確認できませんでした。設定を開き直してください。"
        }
        if let value = error as? CatProfilePhotoAlbumError {
            return value.errorDescription
                ?? "選択した写真アルバムを利用できません。写真へのアクセス範囲を確認してください。"
        }
        if let value = error as? CatHouseholdIdentityStoreError {
            return value.errorDescription
                ?? "猫プロフィールを安全に読み書きできませんでした。もう一度お試しください。"
        }
        if let value = error as? SharedLikeStoreError {
            switch value {
            case .appGroupUnavailable:
                return "「思い出」の保存領域を利用できません。アプリを更新して、もう一度お試しください。"
            case .lockOpenFailed, .lockFailed:
                return "「思い出」を安全に保存できませんでした。少し待って、もう一度お試しください。"
            case .measurementNotInitialized:
                return "アプリを一度開き直してから、もう一度お試しください。"
            }
        }
        if error is URLError {
            return "通信を完了できませんでした。接続を確認して、もう一度お試しください。"
        }
        return "処理を完了できませんでした。写真へのアクセスとiPhoneの空き容量を確認して、もう一度お試しください。"
    }

    private func logCandidateAuthorityUnavailable(operation: String) {
        SharedLog.app.warning(
            "cat-identity",
            "Candidate-authority operation skipped until identity state is ready",
            metadata: [
                "operation": operation,
                "state": catIdentityLoadState == .failed ? "failed" : "loading"
            ]
        )
    }

    private func candidateAuthorityIsReady(operation: String) -> Bool {
        guard catIdentityLoadState == .ready else {
            logCandidateAuthorityUnavailable(operation: operation)
            return false
        }
        return true
    }

    private static func logError(
        _ error: Error,
        category: String,
        operation: String
    ) {
        SharedLog.app.error(
            category,
            "Operation failed",
            metadata: SharedLog.errorMetadata(
                error,
                category: .appOperation,
                additional: ["operation": operation]
            )
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
        metadata.merge(
            state.recoveryDiagnostics?.logMetadata ?? [:],
            uniquingKeysWith: { current, _ in current }
        )
        metadata["bboxAnalysisVersion"] = "\(CatAlbumTraits.currentAnalysisVersion)"
        metadata["scanPurpose"] = state.purpose?.rawValue ?? "none"
        metadata["scanDurationMs"] = state.scanDurationMilliseconds.map {
            String(format: "%.1f", $0)
        } ?? "unknown"
        metadata["widgetEligibleCats"] = "\(state.widgetEligibleAssets ?? 0)"
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
