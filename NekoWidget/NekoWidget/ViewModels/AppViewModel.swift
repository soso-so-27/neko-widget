import Photos
import SwiftUI
import UIKit
import WidgetKit

enum AlbumUpdateStatus: Equatable {
    case idle
    case updating
    case ready(photoCount: Int, updatedAt: Date)
    case failed(message: String)
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
    @Published private(set) var likeMeasurement: SharedLikeMeasurementSnapshot = .empty
    @Published private(set) var isLikeInteractionReady = false
    @Published var selectedAssetIdentifier: String?

    var isLimitedAccess: Bool { authorizationStatus == .limited }
    var catAssets: [AssetRecord] { snapshot.catAssets }
    var likedAssets: [AssetRecord] { snapshot.likedAssets }
    var progress: Double { scanState.progress }
    var isQuickResultReady: Bool { scanState.isQuickResultReady }
    var isComplete: Bool { scanState.isComplete }

    private let authorizationService: PhotoAuthorizationService
    private let scanner: PhotoLibraryScanner
    private let albumService: PhotoAlbumService
    private let widgetCacheBuilder: WidgetCacheBuilder
    private let imageLoader: PhotoImageLoader
    private let photoSelector: WeightedPhotoSelector
    private let albumSelector: AlbumCandidateSelector
    private let exporter: JSONExporter
    private let store: LibraryStore?
    private let storeInitializationError: String?

    private var hasStarted = false
    private var libraryChangePending = false
    private var lastActivationSyncAt: Date?
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var successfulImageLoadCount = 0
    private var sharedLikeRecords: [String: SharedLikeRecord] = [:]

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

        do {
            store = try LibraryStore()
            storeInitializationError = nil
            SharedLog.app.info("storage", "Shared snapshot store initialized")
        } catch {
            store = nil
            storeInitializationError = error.localizedDescription
            Self.logError(error, category: "storage", operation: "initialize_store")
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
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        SharedLog.app.info("lifecycle", "Application startup began")

        if let store {
            do {
                let loaded = try await store.load()
                applySnapshot(loaded)
                let likesChanged = synchronizeSharedLikes(importLegacyLikes: true)
                chooseCurrentAssetIfNeeded()
                if likesChanged {
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
        authorizationStatus = authorizationService.status
        let likesChanged = synchronizeSharedLikes(importLegacyLikes: true)
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
        libraryObserver.start()

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
        snapshot.scanState = scanState
        await saveSnapshot(reportErrors: false)
        await launchScan(forceFullAnalysis: true)
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
        refreshLikeMeasurementState()
        applySharedLikeRecord(mutation.record, at: index)
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
        snapshot.updatedAt = .now
        refreshCurrentAsset()
        await saveSnapshot(reportErrors: true)

        // A like changes the 3x display weight, so refresh the principal v1
        // display surface immediately.
        await rebuildWidgetCache(reportErrors: false)
    }

    func startLikeMeasurement() async {
        errorMessage = nil
        do {
            let measurement = try SharedLikeStore.startMeasurement(at: .now)
            likeMeasurement = measurement
            SharedLog.app.info(
                "like",
                "One-week like measurement started",
                metadata: [
                    "baselineLikedCount": "\(measurement.baselineLikedCount)",
                    "retentionDays": "\(measurement.retentionDays)",
                    "maximumEvents": "\(measurement.maximumEventCount)",
                    "startedAt": measurement.startedAt.map(Self.iso8601String) ?? "unknown"
                ]
            )
        } catch {
            Self.logError(error, category: "like", operation: "start_like_measurement")
            setError(error)
        }
    }

    func selectAsset(id localIdentifier: String?) {
        selectedAssetIdentifier = localIdentifier
    }

    func createOrUpdateAlbum() async {
        await createOrUpdateAlbum(reportErrors: true)
    }

    func rebuildAlbum() async {
        await createOrUpdateAlbum()
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
            currentAsset = photoSelector.selectOne(
                from: snapshot.assets,
                settings: normalized
            )
        }
        await saveSnapshot(reportErrors: true)

        if detectionChanged {
            scanState.requiresFullRescan = true
            snapshot.scanState = scanState
            await saveSnapshot(reportErrors: false)
            await launchScan(forceFullAnalysis: true)
        } else if hasEligibleDisplayCandidates(in: snapshot) {
            await createOrUpdateAlbum(reportErrors: false)
            await rebuildWidgetCache(reportErrors: false)
        } else {
            await clearAlbumAndWidgetOutputs(reportErrors: false)
        }
    }

    func exportJSON() async -> URL? {
        errorMessage = nil
        do {
            let url = try exporter.export(snapshot)
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
        switch link.destination {
        case let .photo(localIdentifier):
            selectedAssetIdentifier = localIdentifier
            SharedLog.app.info(
                "deeplink",
                "Opened photo from widget deep link",
                metadata: ["asset": SharedLog.shortHash(localIdentifier)]
            )
        }
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
        scanState = startingState
        SharedLog.app.info(
            "scan",
            "Scan generation started",
            metadata: [
                "existingRecords": "\(snapshot.assets.count)",
                "forceFullAnalysis": "\(forceFullAnalysis)",
                "generation": "\(generation)"
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
                forceFullAnalysis: forceFullAnalysis
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
                metadata: [
                    "cats": "\(final.scanState.catAssets)",
                    "deferred": "\(final.scanState.deferredAssets)",
                    "total": "\(final.scanState.totalAssets)"
                ]
            )

            if hasEligibleDisplayCandidates(in: final) {
                await createOrUpdateAlbum(reportErrors: false)
                await rebuildWidgetCache(reportErrors: false)
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
            chooseCurrentAssetIfNeeded()
            SharedLog.app.info(
                "scan",
                "Scan progress published",
                metadata: [
                    "cats": "\(published.catAssets)",
                    "deferred": "\(published.deferredAssets)",
                    "phase": published.phase.rawValue,
                    "scanned": "\(published.scannedAssets)",
                    "total": "\(published.totalAssets)"
                ]
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
                metadata: [
                    "cats": "\(provisional.scanState.catAssets)",
                    "deferred": "\(provisional.scanState.deferredAssets)",
                    "scanned": "\(provisional.scanState.scannedAssets)",
                    "total": "\(provisional.scanState.totalAssets)"
                ]
            )
            await saveSnapshot(reportErrors: false)
            // Publish a usable v1 experience after the newest 500 assets rather
            // than waiting for a potentially long full-library scan.
            if provisional.scanState.resultKind == .provisional {
                if hasEligibleDisplayCandidates(in: provisional) {
                    await createOrUpdateAlbum(reportErrors: false)
                    await rebuildWidgetCache(reportErrors: false)
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

    private func applySnapshot(_ newSnapshot: LibrarySnapshot) {
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

        snapshot = merged
        scanState = merged.scanState
        settings = merged.settings.normalized()
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
    private func synchronizeSharedLikes(importLegacyLikes: Bool) -> Bool {
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
            refreshLikeMeasurementState()
            if !wasInteractionReady && isLikeInteractionReady {
                WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
                SharedLog.app.info(
                    "like",
                    "Widget like interaction enabled after legacy migration"
                )
            }
            var changedCount = 0
            for index in snapshot.assets.indices {
                guard let record = records[snapshot.assets[index].localIdentifier] else { continue }
                let asset = snapshot.assets[index]
                guard asset.liked != record.isLiked || asset.likedAt != record.likedAt else { continue }
                applySharedLikeRecord(record, at: index)
                changedCount += 1
            }

            if changedCount > 0 {
                snapshot.updatedAt = .now
                refreshCurrentAsset()
            }
            SharedLog.app.info(
                "like",
                "Shared like state synchronized",
                metadata: [
                    "changedAssets": "\(changedCount)",
                    "records": "\(records.count)",
                    "source": "app-group"
                ]
            )
            return changedCount > 0
        } catch {
            Self.logError(error, category: "like", operation: "synchronize_shared_likes")
            return false
        }
    }

    private func refreshLikeMeasurementState() {
        do {
            let state = try SharedLikeStore.stateSnapshot()
            isLikeInteractionReady = state.isInteractionReady
            likeMeasurement = try SharedLikeStore.measurementSnapshot()
        } catch {
            Self.logError(error, category: "like", operation: "read_like_measurement")
        }
    }

    private func applySharedLikeRecord(_ record: SharedLikeRecord, at index: Int) {
        snapshot.assets[index].liked = record.isLiked
        snapshot.assets[index].likedAt = record.likedAt
    }

    private func chooseCurrentAssetIfNeeded() {
        if let currentAsset,
           let updated = snapshot.assets.first(where: {
               $0.localIdentifier == currentAsset.localIdentifier
                   && $0.isCatCandidate
                   && $0.analysisFingerprint == settings.analysisFingerprint
           }) {
            self.currentAsset = updated
            return
        }
        currentAsset = photoSelector.selectOne(
            from: snapshot.assets,
            settings: settings
        )
    }

    private func refreshCurrentAsset() {
        guard let identifier = currentAsset?.localIdentifier else { return }
        currentAsset = snapshot.assets.first { $0.localIdentifier == identifier }
    }

    private func createOrUpdateAlbum(reportErrors: Bool) async {
        if case .updating = albumStatus { return }
        let selected = albumSelector.select(from: snapshot)
        guard !selected.isEmpty else {
            await clearAlbumAndWidgetOutputs(reportErrors: false)
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

    private func rebuildWidgetCache(reportErrors: Bool) async {
        SharedLog.app.info(
            "widget-cache",
            "Widget cache rebuild requested",
            metadata: ["assets": "\(snapshot.assets.count)"]
        )
        do {
            let result = try await widgetCacheBuilder.build(from: snapshot)
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
        await clearWidgetOutput(reportErrors: reportErrors)
    }

    private func clearWidgetOutput(reportErrors: Bool) async {
        do {
            try await widgetCacheBuilder.clear()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            Self.logError(error, category: "widget-cache", operation: "clear_cache")
            if reportErrors { setError(error) }
        }
    }

    private func hasEligibleDisplayCandidates(in value: LibrarySnapshot) -> Bool {
        photoSelector.selectOne(
            from: value.assets,
            settings: value.settings
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
