@preconcurrency import Photos
@preconcurrency import Vision
import ImageIO
import UIKit

enum ScanEvent: Sendable {
    case progress(ScanState, analyzedRecords: [AssetRecord])
    case provisional(LibrarySnapshot)
}

actor PhotoLibraryScanner {
    private enum AnalysisMode: Sendable {
        case full
        case groupedAlbumOnly
        case postureRepairOnly

        var preservesPreviousCatOnFailure: Bool {
            switch self {
            case .groupedAlbumOnly, .postureRepairOnly: return true
            case .full: return false
            }
        }

        var preservesPrimaryDetectionOnSuccess: Bool {
            if case .postureRepairOnly = self { return true }
            return false
        }
    }

    private struct IndexedRecord: Sendable {
        var index: Int
        var record: AssetRecord
    }

    private struct LocalThumbnailRequestOutcome {
        var image: UIImage?
        var errorDomain: String?
        var errorCode: Int?
        var wasCancelled: Bool
        var isInCloud: Bool
        var isDegraded: Bool
        var timedOut: Bool

        static let taskCancelled = LocalThumbnailRequestOutcome(
            image: nil,
            errorDomain: nil,
            errorCode: nil,
            wasCancelled: true,
            isInCloud: false,
            isDegraded: false,
            timedOut: false
        )
    }

    private enum LocalThumbnailLoadResult {
        case image(UIImage)
        case unavailableLocally
        case failed
    }

    private final class LocalThumbnailRequest: @unchecked Sendable {
        private let asset: PHAsset
        private let manager = PHImageManager.default()
        private let options: PHImageRequestOptions
        private let timeoutNanoseconds: UInt64
        private let lock = NSLock()
        private var continuation: CheckedContinuation<LocalThumbnailRequestOutcome, Never>?
        private var requestID: PHImageRequestID?
        private var timeoutTask: Task<Void, Never>?
        private var isFinished = false

        init(
            asset: PHAsset,
            options: PHImageRequestOptions,
            timeoutNanoseconds: UInt64
        ) {
            self.asset = asset
            self.options = options
            self.timeoutNanoseconds = timeoutNanoseconds
        }

        func value() async -> LocalThumbnailRequestOutcome {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isFinished {
                    lock.unlock()
                    continuation.resume(returning: .taskCancelled)
                    return
                }
                self.continuation = continuation
                lock.unlock()

                let identifier = manager.requestImage(
                    for: asset,
                    targetSize: CGSize(width: 1_024, height: 1_024),
                    contentMode: .aspectFit,
                    options: options
                ) { [weak self] image, info in
                    self?.handle(image: image, info: info)
                }

                lock.lock()
                if isFinished {
                    lock.unlock()
                    manager.cancelImageRequest(identifier)
                    return
                }
                requestID = identifier
                lock.unlock()

                let timeoutTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                    } catch {
                        return
                    }
                    self.finish(
                        LocalThumbnailRequestOutcome(
                            image: nil,
                            errorDomain: "PhotoLibraryScanner.Timeout",
                            errorCode: 1,
                            wasCancelled: false,
                            isInCloud: false,
                            isDegraded: false,
                            timedOut: true
                        ),
                        cancelImageRequest: true
                    )
                }
                lock.lock()
                if isFinished {
                    lock.unlock()
                    timeoutTask.cancel()
                } else {
                    self.timeoutTask = timeoutTask
                    lock.unlock()
                }
            }
        }

        func cancel() {
            finish(.taskCancelled, cancelImageRequest: true)
        }

        private func handle(image: UIImage?, info: [AnyHashable: Any]?) {
            let wasCancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            let error = info?[PHImageErrorKey] as? NSError

            // A high-quality asynchronous request may first deliver a degraded
            // image. Wait for the final callback unless the request has ended.
            if isDegraded, !wasCancelled, error == nil {
                return
            }
            finish(
                LocalThumbnailRequestOutcome(
                    image: wasCancelled || error != nil ? nil : image,
                    errorDomain: error?.domain,
                    errorCode: error?.code,
                    wasCancelled: wasCancelled,
                    isInCloud: isInCloud,
                    isDegraded: isDegraded,
                    timedOut: false
                ),
                cancelImageRequest: false
            )
        }

        private func finish(
            _ outcome: LocalThumbnailRequestOutcome,
            cancelImageRequest: Bool
        ) {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            let continuation = self.continuation
            let identifier = requestID
            let timeoutTask = self.timeoutTask
            self.continuation = nil
            self.timeoutTask = nil
            lock.unlock()

            timeoutTask?.cancel()
            if cancelImageRequest, let identifier {
                manager.cancelImageRequest(identifier)
            }
            continuation?.resume(returning: outcome)
        }
    }

    /// Performs a newest-first, two-stage scan. Inference runs up to four
    /// thumbnails at a time; each is bounded to 1024px and never downloads from
    /// iCloud. Moving the app out of the foreground cancels the owning Task.
    func scan(
        existing: LibrarySnapshot,
        settings inputSettings: AppSettings,
        forceFullAnalysis: Bool,
        sourceAlbumIdentifier: String? = nil,
        onEvent: @escaping @Sendable (ScanEvent) async -> Void
    ) async throws -> LibrarySnapshot {
        let settings = inputSettings.normalized()
        let scanPurpose = existing.scanState.purpose
            ?? (forceFullAnalysis ? .manualRescan : .regular)
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        // A stale or inaccessible selected album fails before any provisional
        // publication. This preserves the previous snapshot and outputs rather
        // than silently widening the user's source back to the full library.
        let assets = try PhotoSourceAlbumCatalog.fetchImageAssets(
            sourceAlbumIdentifier: sourceAlbumIdentifier,
            options: fetchOptions
        )
        let outingByIdentifier = HomeLocationClassifier.classify(assets.map { asset in
            AlbumLocationSample(
                localIdentifier: asset.localIdentifier,
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude
            )
        })
        SharedLog.app.info(
            "scan",
            "Photo library fetch completed",
            metadata: [
                "assets": "\(assets.count)",
                "forceFullAnalysis": "\(forceFullAnalysis)",
                "networkAllowed": "false",
                "quickLimit": "\(settings.quickScanLimit)",
                "source": sourceAlbumIdentifier == nil ? "all-library" : "selected-album"
            ]
        )

        let previousByIdentifier = Dictionary(
            uniqueKeysWithValues: existing.assets.map { ($0.localIdentifier, $0) }
        )
        let activeIdentifiers = Set(assets.map(\.localIdentifier))
        // A selected album is only a candidate scope, not permission to destroy
        // the full-library Vision cache. Dormant records remain hidden by the
        // durable source membership and become reusable if the user later picks
        // another album or returns to the whole library.
        let dormantIdentifiers = PhotoSourceCachePolicy.dormantIdentifiers(
            existingIdentifiers: existing.assets.map(\.localIdentifier),
            activeIdentifiers: activeIdentifiers,
            usesSelectedSource: sourceAlbumIdentifier != nil
        )
        let dormantRecords = existing.assets.filter {
            dormantIdentifiers.contains($0.localIdentifier)
        }
        var records = Array<AssetRecord?>(repeating: nil, count: assets.count)
        var seenBurstIdentifiers = Set<String>()
        let quickEnd = min(settings.quickScanLimit, assets.count)

        if quickEnd > 0 {
            try await process(
                range: 0..<quickEnd,
                assets: assets,
                records: &records,
                seenBurstIdentifiers: &seenBurstIdentifiers,
                previousByIdentifier: previousByIdentifier,
                outingByIdentifier: outingByIdentifier,
                settings: settings,
                forceFullAnalysis: forceFullAnalysis,
                totalAssets: assets.count,
                phase: .quickScan,
                purpose: scanPurpose,
                onEvent: onEvent
            )
        }

        var quickState = makeState(
            records: records,
            scannedAssets: quickEnd,
            totalAssets: assets.count,
            phase: assets.count > quickEnd ? .fullScan : .completed,
            resultKind: assets.count > quickEnd ? .provisional : .final,
            requiresFullRescan: forceFullAnalysis && assets.count > quickEnd,
            purpose: scanPurpose
        )
        quickState.lastScannedAt = .now
        var quickSnapshot = existing
        // Keep resumable records only for assets that are still present in the
        // current PhotoKit fetch. This preserves likes for the unprocessed tail
        // without carrying deleted assets or photos removed from limited access
        // into the quick album/widget publication.
        var quickRecords = records.compactMap { $0 }
        if quickEnd < assets.count {
            quickRecords.append(contentsOf: assets[quickEnd...].compactMap {
                previousByIdentifier[$0.localIdentifier]
            })
        }
        quickRecords.append(contentsOf: dormantRecords)
        quickSnapshot.assets = quickRecords
        quickSnapshot.scanState = quickState
        quickSnapshot.settings = settings
        quickSnapshot.updatedAt = .now
        await onEvent(.provisional(quickSnapshot))

        if quickEnd < assets.count {
            try await process(
                range: quickEnd..<assets.count,
                assets: assets,
                records: &records,
                seenBurstIdentifiers: &seenBurstIdentifiers,
                previousByIdentifier: previousByIdentifier,
                outingByIdentifier: outingByIdentifier,
                settings: settings,
                forceFullAnalysis: forceFullAnalysis,
                totalAssets: assets.count,
                phase: .fullScan,
                purpose: scanPurpose,
                onEvent: onEvent
            )
        }

        try Task.checkCancellation()
        var final = existing
        final.assets = records.compactMap { $0 } + dormantRecords
        final.scanState = makeState(
            records: records,
            scannedAssets: assets.count,
            totalAssets: assets.count,
            phase: .completed,
            resultKind: .final,
            requiresFullRescan: false,
            purpose: scanPurpose
        )
        final.scanState.lastScannedAt = .now
        final.settings = settings
        final.updatedAt = .now
        var completionMetadata = [
            "postureAnalysisVersion": "\(CatAlbumTraits.currentAnalysisVersion)",
            "cats": "\(final.scanState.catAssets)",
            "deferred": "\(final.scanState.deferredAssets)",
            "postureScope": "active-source-before-user-curation",
            "scanPurpose": scanPurpose.rawValue,
            "total": "\(final.scanState.totalAssets)"
        ]
        completionMetadata.merge(
            final.scanState.postureSummary?.logMetadata ?? [:],
            uniquingKeysWith: { current, _ in current }
        )
        SharedLog.app.info(
            "scan",
            "Photo library scan completed",
            metadata: completionMetadata
        )
        return final
    }

    private func process(
        range: Range<Int>,
        assets: [PHAsset],
        records: inout [AssetRecord?],
        seenBurstIdentifiers: inout Set<String>,
        previousByIdentifier: [String: AssetRecord],
        outingByIdentifier: [String: Bool?],
        settings: AppSettings,
        forceFullAnalysis: Bool,
        totalAssets: Int,
        phase: ScanPhase,
        purpose: ScanPurpose,
        onEvent: @escaping @Sendable (ScanEvent) async -> Void
    ) async throws {
#if targetEnvironment(simulator)
        // Hosted Simulators don't expose an iPhone GPU/Neural Engine. Keep
        // CPU-only Vision work narrowly parallel so the UI and XCTest stay
        // responsive while bounded PhotoKit requests can still make progress.
        let concurrency = 2
#else
        let concurrency = 4
#endif
        var batchStart = range.lowerBound
        var lastPublishedIndex = range.lowerBound
        var newlyAnalyzedCount = 0
        var reusedCount = 0

        while batchStart < range.upperBound {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + concurrency, range.upperBound)
            var pending: [(Int, PHAsset, AssetRecord?, AnalysisMode)] = []

            for index in batchStart..<batchEnd {
                let asset = assets[index]
                let previous = previousByIdentifier[asset.localIdentifier]
                let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)

                // Build 12's primary cat/no-cat decisions remain valid. A
                // posture repair touches only known cats whose secondary traits
                // are nil or stale. Existing non-target records (including
                // iCloud/failed primary records) are retained without Vision;
                // genuinely new assets still use the normal path below.
                if purpose == .postureRepair, let previous {
                    if previous.isCatCandidate,
                       !Self.hasCompletedGroupedAlbumAnalysis(previous) {
                        let currentModificationDate = Self.normalizedModificationDate(
                            asset.modificationDate
                        )
                        let mode: AnalysisMode = previous.canPreservePrimaryDetection(
                            sourceModificationDate: currentModificationDate,
                            analysisFingerprint: settings.analysisFingerprint
                        ) ? .postureRepairOnly : .full
                        pending.append((index, asset, previous, mode))
                    } else {
                        var reused = previous
                        reused.creationDate = asset.creationDate
                        reused.sourceModificationDate = Self.normalizedModificationDate(
                            asset.modificationDate
                        )
                        reused.sourceModificationDateWasCaptured = true
                        reused.isFavorite = asset.isFavorite
                        reused.isScreenshot = isScreenshot
                        reused.burstIdentifier = asset.burstIdentifier
                        if reused.isCatCandidate,
                           var traits = reused.albumTraits,
                           traits.analysisVersion == CatAlbumTraits.currentAnalysisVersion {
                            traits.isOuting = Self.outingValue(
                                for: asset.localIdentifier,
                                in: outingByIdentifier
                            )
                            reused.albumTraits = traits
                        }
                        records[index] = reused
                        reusedCount += 1
                    }
                    continue
                }

                if isScreenshot {
                    records[index] = Self.excludedRecord(
                        asset: asset,
                        status: .excludedScreenshot,
                        analysisFingerprint: settings.analysisFingerprint,
                        previous: previous
                    )
                    continue
                }

                if let burstIdentifier = asset.burstIdentifier {
                    if seenBurstIdentifiers.contains(burstIdentifier) {
                        records[index] = Self.excludedRecord(
                            asset: asset,
                            status: .excludedBurstDuplicate,
                            analysisFingerprint: settings.analysisFingerprint,
                            previous: previous
                        )
                        continue
                    }
                    seenBurstIdentifiers.insert(burstIdentifier)
                }

                // Legacy snapshots have no capture marker. Trust them once and
                // record PhotoKit's current value below so later edits invalidate
                // the Vision box without forcing an upgrade rescan. The marker
                // also distinguishes a captured nil date from a missing field.
                if let previous,
                   (!forceFullAnalysis
                       || (purpose == .groupedAlbumUpgrade
                           && Self.hasCompletedGroupedAlbumAnalysis(previous))),
                   previous.analysisFingerprint == settings.analysisFingerprint,
                   (previous.sourceModificationDateWasCaptured != true
                       || previous.sourceModificationDate
                           == Self.normalizedModificationDate(asset.modificationDate)),
                   previous.analysisStatus != .unavailableLocally,
                   previous.analysisStatus != .failed {
                    var reused = previous
                    reused.creationDate = asset.creationDate
                    reused.sourceModificationDate = Self.normalizedModificationDate(
                        asset.modificationDate
                    )
                    reused.sourceModificationDateWasCaptured = true
                    reused.isFavorite = asset.isFavorite
                    reused.isScreenshot = false
                    reused.burstIdentifier = asset.burstIdentifier
                    if reused.analysisStatus == .detected, reused.isCatCandidate {
                        if reused.albumAnalysisVersion
                                == CatAlbumTraits.currentAnalysisVersion,
                           var traits = reused.albumTraits,
                           traits.analysisVersion
                                == CatAlbumTraits.currentAnalysisVersion {
                            traits.isOuting = Self.outingValue(
                                for: asset.localIdentifier,
                                in: outingByIdentifier
                            )
                            reused.albumTraits = traits
                            reused.albumAnalysisVersion =
                                CatAlbumTraits.currentAnalysisVersion
                            records[index] = reused
                            reusedCount += 1
                        } else {
                            pending.append((index, asset, previous, .groupedAlbumOnly))
                        }
                    } else if reused.analysisStatus == .noCat {
                        reused.albumAnalysisVersion =
                            CatAlbumTraits.currentAnalysisVersion
                        reused.albumTraits = nil
                        records[index] = reused
                        reusedCount += 1
                    } else {
                        pending.append((index, asset, previous, .full))
                    }
                } else {
                    let mode: AnalysisMode = purpose == .groupedAlbumUpgrade
                        && previous?.isCatCandidate == true
                        ? .groupedAlbumOnly
                        : .full
                    pending.append((index, asset, previous, mode))
                }
            }
            newlyAnalyzedCount += pending.count

            let analyzed = try await withThrowingTaskGroup(
                of: IndexedRecord.self,
                returning: [IndexedRecord].self
            ) { group in
                for (index, asset, previous, analysisMode) in pending {
                    group.addTask {
                        try Task.checkCancellation()
                        let record = try await Self.analyze(
                            asset: asset,
                            settings: settings,
                            previous: previous,
                            analysisMode: analysisMode,
                            isOuting: Self.outingValue(
                                for: asset.localIdentifier,
                                in: outingByIdentifier
                            )
                        )
                        return IndexedRecord(index: index, record: record)
                    }
                }

                var values: [IndexedRecord] = []
                for try await value in group { values.append(value) }
                return values
            }
            for value in analyzed { records[value.index] = value.record }

            batchStart = batchEnd
            let isFirstQuickBatch = phase == .quickScan
                && batchEnd == min(range.lowerBound + concurrency, range.upperBound)
            if isFirstQuickBatch || batchEnd == range.upperBound || batchEnd.isMultiple(of: 100) {
                let state = makeState(
                    records: records,
                    scannedAssets: batchEnd,
                    totalAssets: totalAssets,
                    phase: phase,
                    // A partial count must always be labelled provisional. The
                    // first four thumbnails publish quickly so the initial UI
                    // doesn't wait for all 500 Vision requests.
                    resultKind: .provisional,
                    requiresFullRescan: forceFullAnalysis,
                    purpose: purpose
                )
                await onEvent(
                    .progress(
                        state,
                        analyzedRecords: records[lastPublishedIndex..<batchEnd]
                            .compactMap { $0 }
                    )
                )
                lastPublishedIndex = batchEnd
            }
            await Task.yield()
        }

        let phaseRecords = records[range].compactMap { $0 }
        let statusCounts = Dictionary(
            grouping: phaseRecords,
            by: { $0.analysisStatus.rawValue }
        ).mapValues(\.count)
        SharedLog.app.info(
            "vision",
            "Vision phase summary",
            metadata: [
                "burstDuplicates": "\(statusCounts[AssetAnalysisStatus.excludedBurstDuplicate.rawValue, default: 0])",
                "cats": "\(statusCounts[AssetAnalysisStatus.detected.rawValue, default: 0])",
                "deferred": "\(statusCounts[AssetAnalysisStatus.unavailableLocally.rawValue, default: 0])",
                "failed": "\(statusCounts[AssetAnalysisStatus.failed.rawValue, default: 0])",
                "newlyAnalyzed": "\(newlyAnalyzedCount)",
                "noCat": "\(statusCounts[AssetAnalysisStatus.noCat.rawValue, default: 0])",
                "phase": phase.rawValue,
                "reused": "\(reusedCount)",
                "screenshots": "\(statusCounts[AssetAnalysisStatus.excludedScreenshot.rawValue, default: 0])",
                "thumbnailTargetPixels": "1024x1024"
            ]
        )
    }

    private func makeState(
        records: [AssetRecord?],
        scannedAssets: Int,
        totalAssets: Int,
        phase: ScanPhase,
        resultKind: ScanResultKind,
        requiresFullRescan: Bool,
        purpose: ScanPurpose?
    ) -> ScanState {
        let finished = records.compactMap { $0 }
        let cats = finished.filter(\.isCatCandidate)
        let postureSummary = PostureScanSummary(records: finished)
        let resultingPurpose: ScanPurpose?
        if resultKind == .final {
            resultingPurpose = !requiresFullRescan
                && postureSummary.secondaryPendingAssets > 0
                ? .postureRepair
                : nil
        } else {
            resultingPurpose = purpose
        }
        return ScanState(
            phase: phase,
            resultKind: resultKind,
            lastScannedAt: nil,
            totalAssets: totalAssets,
            scannedAssets: scannedAssets,
            catAssets: cats.count,
            oldestCatPhotoDate: cats.compactMap(\.creationDate).min(),
            deferredAssets: finished.filter { record in
                record.analysisStatus == .unavailableLocally
                    || record.analysisStatus == .failed
                    || (record.isCatCandidate
                        && (record.albumAnalysisVersion
                                != CatAlbumTraits.currentAnalysisVersion
                            || record.albumTraits?.analysisVersion
                                != CatAlbumTraits.currentAnalysisVersion))
            }.count,
            postureSummary: postureSummary,
            // Completing one full pass clears the migration banner even when
            // an iCloud-only known cat could not receive secondary traits.
            // Its nil album version is still retried by the normal reuse path.
            requiresFullRescan: requiresFullRescan,
            // Keep a lightweight repair purpose through checkpoints and after
            // a final pass that still has secondary failures. This preserves
            // the retry/UI state without turning it into a primary rescan.
            purpose: resultingPurpose,
            lastError: nil
        )
    }

    private static func outingValue(
        for localIdentifier: String,
        in values: [String: Bool?]
    ) -> Bool? {
        guard let stored = values[localIdentifier] else { return nil }
        return stored
    }

    private static func hasCompletedGroupedAlbumAnalysis(
        _ record: AssetRecord
    ) -> Bool {
        guard record.albumAnalysisVersion == CatAlbumTraits.currentAnalysisVersion else {
            return false
        }
        if record.analysisStatus == .detected {
            guard record.isCatCandidate else { return false }
            return record.albumTraits?.analysisVersion
                == CatAlbumTraits.currentAnalysisVersion
        }
        return true
    }

    private static func analyze(
        asset: PHAsset,
        settings: AppSettings,
        previous: AssetRecord?,
        analysisMode: AnalysisMode,
        isOuting: Bool?
    ) async throws -> AssetRecord {
        let sourcePixelCount = Int64(asset.pixelWidth) * Int64(asset.pixelHeight)
        let tracesLargePhoto = sourcePixelCount >= largePhotoTraceMinimumPixelCount
        let assetHash = tracesLargePhoto
            ? SharedLog.shortHash(asset.localIdentifier)
            : ""
        let sourcePixels = "\(asset.pixelWidth)x\(asset.pixelHeight)"
        let processingStartedAt = Date()
        var processingOutcome = "unknown"
        var resolvedOutputPixels = "0x0"
        var resolvedDecodedBytes = 0

        if tracesLargePhoto {
            SharedLog.app.info(
                "image-load",
                "Large photo processing started",
                metadata: [
                    "asset": assetHash,
                    "pixelCount": "\(sourcePixelCount)",
                    "sourcePixels": sourcePixels,
                    "targetPixels": "1024x1024"
                ]
            )
        }
        defer {
            if tracesLargePhoto {
                SharedLog.app.info(
                    "image-load",
                    "Large photo processing finished",
                    metadata: [
                        "asset": assetHash,
                        "decodedBytesEstimate": "\(resolvedDecodedBytes)",
                        "durationMs": String(
                            format: "%.1f",
                            Date().timeIntervalSince(processingStartedAt) * 1_000
                        ),
                        "outcome": processingOutcome,
                        "outputPixels": resolvedOutputPixels,
                        "sourcePixels": sourcePixels
                    ]
                )
            }
        }

        let thumbnailStartedAt = Date()
        let thumbnailResult: LocalThumbnailLoadResult
        do {
            thumbnailResult = try await localThumbnail(for: asset)
        } catch is CancellationError {
            processingOutcome = "cancelled"
            if tracesLargePhoto {
                logLargePhotoThumbnailResolved(
                    assetHash: assetHash,
                    sourcePixels: sourcePixels,
                    outputPixels: resolvedOutputPixels,
                    decodedBytesEstimate: resolvedDecodedBytes,
                    durationMilliseconds: Date().timeIntervalSince(thumbnailStartedAt) * 1_000,
                    outcome: "cancelled"
                )
            }
            throw CancellationError()
        } catch {
            processingOutcome = "thumbnailError"
            if tracesLargePhoto {
                logLargePhotoThumbnailResolved(
                    assetHash: assetHash,
                    sourcePixels: sourcePixels,
                    outputPixels: resolvedOutputPixels,
                    decodedBytesEstimate: resolvedDecodedBytes,
                    durationMilliseconds: Date().timeIntervalSince(thumbnailStartedAt) * 1_000,
                    outcome: "error"
                )
            }
            throw error
        }

        let image: UIImage
        switch thumbnailResult {
        case .image(let loadedImage):
            image = loadedImage
            let width = loadedImage.cgImage?.width
                ?? Int((loadedImage.size.width * loadedImage.scale).rounded())
            let height = loadedImage.cgImage?.height
                ?? Int((loadedImage.size.height * loadedImage.scale).rounded())
            resolvedOutputPixels = "\(width)x\(height)"
            resolvedDecodedBytes = width * height * 4
            if tracesLargePhoto {
                logLargePhotoThumbnailResolved(
                    assetHash: assetHash,
                    sourcePixels: sourcePixels,
                    outputPixels: resolvedOutputPixels,
                    decodedBytesEstimate: resolvedDecodedBytes,
                    durationMilliseconds: Date().timeIntervalSince(thumbnailStartedAt) * 1_000,
                    outcome: "loaded"
                )
            }
        case .unavailableLocally:
            processingOutcome = AssetAnalysisStatus.unavailableLocally.rawValue
            if tracesLargePhoto {
                logLargePhotoThumbnailResolved(
                    assetHash: assetHash,
                    sourcePixels: sourcePixels,
                    outputPixels: resolvedOutputPixels,
                    decodedBytesEstimate: resolvedDecodedBytes,
                    durationMilliseconds: Date().timeIntervalSince(thumbnailStartedAt) * 1_000,
                    outcome: AssetAnalysisStatus.unavailableLocally.rawValue
                )
            }
            if analysisMode.preservesPreviousCatOnFailure,
               let previous,
               previous.isCatCandidate {
                return pendingGroupedAlbumRecord(asset: asset, previous: previous)
            }
            return AssetRecord(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                sourceModificationDate: Self.normalizedModificationDate(asset.modificationDate),
                sourceModificationDateWasCaptured: true,
                isFavorite: asset.isFavorite,
                isScreenshot: false,
                burstIdentifier: asset.burstIdentifier,
                cat: .none,
                analysisStatus: .unavailableLocally,
                analysisFingerprint: settings.analysisFingerprint
            ).preservingUserState(from: previous)
        case .failed:
            processingOutcome = AssetAnalysisStatus.failed.rawValue
            if tracesLargePhoto {
                logLargePhotoThumbnailResolved(
                    assetHash: assetHash,
                    sourcePixels: sourcePixels,
                    outputPixels: resolvedOutputPixels,
                    decodedBytesEstimate: resolvedDecodedBytes,
                    durationMilliseconds: Date().timeIntervalSince(thumbnailStartedAt) * 1_000,
                    outcome: AssetAnalysisStatus.failed.rawValue
                )
            }
            if analysisMode.preservesPreviousCatOnFailure,
               let previous,
               previous.isCatCandidate {
                return pendingGroupedAlbumRecord(asset: asset, previous: previous)
            }
            return AssetRecord(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                sourceModificationDate: Self.normalizedModificationDate(asset.modificationDate),
                sourceModificationDateWasCaptured: true,
                isFavorite: asset.isFavorite,
                isScreenshot: false,
                burstIdentifier: asset.burstIdentifier,
                cat: .none,
                analysisStatus: .failed,
                analysisFingerprint: settings.analysisFingerprint
            ).preservingUserState(from: previous)
        }

        guard let cgImage = image.cgImage else {
            processingOutcome = AssetAnalysisStatus.failed.rawValue
            SharedLog.app.warning(
                "image-load",
                "Photo thumbnail had no CGImage backing",
                metadata: ["asset": SharedLog.shortHash(asset.localIdentifier)]
            )
            if analysisMode.preservesPreviousCatOnFailure,
               let previous,
               previous.isCatCandidate {
                return pendingGroupedAlbumRecord(asset: asset, previous: previous)
            }
            return AssetRecord(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                sourceModificationDate: Self.normalizedModificationDate(asset.modificationDate),
                sourceModificationDateWasCaptured: true,
                isFavorite: asset.isFavorite,
                isScreenshot: false,
                burstIdentifier: asset.burstIdentifier,
                cat: .none,
                analysisStatus: .failed,
                analysisFingerprint: settings.analysisFingerprint
            ).preservingUserState(from: previous)
        }

        do {
            let request = VNRecognizeAnimalsRequest()
#if targetEnvironment(simulator)
            // Vision's automatic compute-device selection can stall against
            // the simulated Metal device. This affects CI only; devices keep
            // the normal GPU/Neural Engine scheduling path.
            request.usesCPUOnly = true
#endif
            let orientation = CGImagePropertyOrientation(image.imageOrientation)
            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: orientation,
                options: [:]
            )
            try handler.perform([request])

            let observations = request.results ?? []
            let cats: [(VNRecognizedObjectObservation, Float)] = observations.compactMap {
                observation in
                guard let label = observation.labels
                    .filter({ $0.identifier.caseInsensitiveCompare("cat") == .orderedSame })
                    .max(by: { $0.confidence < $1.confidence }),
                      label.confidence >= settings.confidenceThreshold else {
                    return nil
                }
                return (observation, label.confidence)
            }

            let catBoundingBoxes = cats.map { $0.0.boundingBox }
            let union = catBoundingBoxes.reduce(CGRect.null) { $0.union($1) }
            let catAreaRatio = min(
                1,
                catBoundingBoxes.reduce(0) {
                    $0 + Double($1.width * $1.height)
                }
            )
            guard !cats.isEmpty,
                  !union.isNull,
                  catAreaRatio >= settings.minimumCatAreaRatio else {
                if analysisMode.preservesPreviousCatOnFailure,
                   let previous,
                   previous.isCatCandidate {
                    processingOutcome = "detected-album-pending"
                    return pendingGroupedAlbumRecord(asset: asset, previous: previous)
                }
                processingOutcome = AssetAnalysisStatus.noCat.rawValue
                return AssetRecord(
                    localIdentifier: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    sourceModificationDate: Self.normalizedModificationDate(asset.modificationDate),
                    sourceModificationDateWasCaptured: true,
                    isFavorite: asset.isFavorite,
                    isScreenshot: false,
                    burstIdentifier: asset.burstIdentifier,
                    cat: .none,
                    analysisStatus: .noCat,
                    analysisFingerprint: settings.analysisFingerprint,
                    albumAnalysisVersion: CatAlbumTraits.currentAnalysisVersion,
                    albumTraits: nil
                ).preservingUserState(from: previous)
            }

            let confidence = cats.map { $0.1 }.max() ?? 0
            let refreshedDetection = CatDetection(
                detected: true,
                confidence: confidence,
                boundingBox: NormalizedRect(union),
                areaRatio: catAreaRatio,
                catCount: cats.count
            )
            let primaryDetection: CatDetection
            let primaryAnalyzedAt: Date
            if analysisMode.preservesPrimaryDetectionOnSuccess, let previous {
                primaryDetection = previous.cat
                primaryAnalyzedAt = previous.analyzedAt
            } else {
                primaryDetection = refreshedDetection
                primaryAnalyzedAt = .now
            }

            do {
                try Task.checkCancellation()
                let traits = try groupedAlbumTraits(
                    cgImage: cgImage,
                    orientation: orientation,
                    catBoundingBoxes: catBoundingBoxes,
                    isOuting: isOuting
                )
                processingOutcome = AssetAnalysisStatus.detected.rawValue
                return AssetRecord(
                    localIdentifier: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    sourceModificationDate: Self.normalizedModificationDate(asset.modificationDate),
                    sourceModificationDateWasCaptured: true,
                    isFavorite: asset.isFavorite,
                    isScreenshot: false,
                    burstIdentifier: asset.burstIdentifier,
                    cat: primaryDetection,
                    analysisStatus: .detected,
                    analysisFingerprint: settings.analysisFingerprint,
                    analyzedAt: primaryAnalyzedAt,
                    albumAnalysisVersion: CatAlbumTraits.currentAnalysisVersion,
                    albumTraits: traits
                ).preservingUserState(from: previous)
            } catch is CancellationError {
                processingOutcome = "cancelled"
                throw CancellationError()
            } catch {
                // A secondary album classifier must never erase a valid cat or
                // make it disappear from the existing Widget. Nil versioning
                // schedules a later retry while the primary result survives.
                processingOutcome = "detected-album-pending"
                let value = error as NSError
                SharedLog.app.warning(
                    "vision",
                    "Grouped album analysis deferred",
                    metadata: [
                        "asset": SharedLog.shortHash(asset.localIdentifier),
                        "code": "\(value.code)",
                        "domain": value.domain
                    ]
                )
                return AssetRecord(
                    localIdentifier: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    sourceModificationDate: Self.normalizedModificationDate(asset.modificationDate),
                    sourceModificationDateWasCaptured: true,
                    isFavorite: asset.isFavorite,
                    isScreenshot: false,
                    burstIdentifier: asset.burstIdentifier,
                    cat: primaryDetection,
                    analysisStatus: .detected,
                    analysisFingerprint: settings.analysisFingerprint,
                    analyzedAt: primaryAnalyzedAt,
                    albumAnalysisVersion: nil,
                    albumTraits: nil
                ).preservingUserState(from: previous)
            }
        } catch is CancellationError {
            processingOutcome = "cancelled"
            throw CancellationError()
        } catch {
            let value = error as NSError
            if analysisMode.preservesPreviousCatOnFailure,
               let previous,
               previous.isCatCandidate {
                processingOutcome = "detected-album-pending"
                SharedLog.app.warning(
                    "vision",
                    "Cat bounds refresh deferred for grouped albums",
                    metadata: [
                        "asset": SharedLog.shortHash(asset.localIdentifier),
                        "code": "\(value.code)",
                        "domain": value.domain
                    ]
                )
                return pendingGroupedAlbumRecord(asset: asset, previous: previous)
            }

            processingOutcome = AssetAnalysisStatus.failed.rawValue
            SharedLog.app.error(
                "vision",
                "Vision animal recognition request failed",
                metadata: [
                    "code": "\(value.code)",
                    "domain": value.domain
                ]
            )
            return AssetRecord(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                sourceModificationDate: Self.normalizedModificationDate(asset.modificationDate),
                sourceModificationDateWasCaptured: true,
                isFavorite: asset.isFavorite,
                isScreenshot: false,
                burstIdentifier: asset.burstIdentifier,
                cat: .none,
                analysisStatus: .failed,
                analysisFingerprint: settings.analysisFingerprint
            ).preservingUserState(from: previous)
        }
    }

    private static func groupedAlbumTraits(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        catBoundingBoxes: [CGRect],
        isOuting: Bool?
    ) throws -> CatAlbumTraits {
        let poseRequest = VNDetectAnimalBodyPoseRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
#if targetEnvironment(simulator)
        poseRequest.usesCPUOnly = true
        faceRequest.usesCPUOnly = true
#endif
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: orientation,
            options: [:]
        )
        try handler.perform([poseRequest, faceRequest])

        let poseObservations = poseRequest.results ?? []
        let posture = AnimalPostureClassifier.classify(
            from: poseObservations,
            matching: catBoundingBoxes
        )
        let containsPerson = containsProminentHumanFace(
            faceRequest.results ?? [],
            excluding: catBoundingBoxes
        )
        let largestCatAreaRatio = catBoundingBoxes.lazy.map {
            Double($0.width * $0.height)
        }.max() ?? 0
        return CatAlbumTraits(
            // The initializer derives the photo-level union from the ordered
            // per-cat outcomes. The explicit value is legacy fallback only.
            postures: Array(posture.photoTags),
            poseObservationCount: posture.diagnostics.rawObservationCount,
            postureDiagnostics: posture.diagnostics,
            postureInstances: posture.instances,
            containsPerson: containsPerson,
            isOuting: isOuting,
            largestCatAreaRatio: largestCatAreaRatio
        )
    }

    private static func containsProminentHumanFace(
        _ observations: [VNFaceObservation],
        excluding catBoundingBoxes: [CGRect]
    ) -> Bool {
        observations.contains { observation in
            let face = observation.boundingBox.standardized
            let faceArea = face.width * face.height
            guard observation.confidence >= 0.6,
                  faceArea >= 0.02,
                  min(face.width, face.height) >= 0.10 else { return false }

            let mostlyOverlapsCat = catBoundingBoxes.contains { cat in
                let overlap = face.intersection(cat.standardized)
                guard !overlap.isNull, !overlap.isEmpty else { return false }
                return (overlap.width * overlap.height) / faceArea >= 0.5
            }
            return !mostlyOverlapsCat
        }
    }

    private static func pendingGroupedAlbumRecord(
        asset: PHAsset,
        previous: AssetRecord
    ) -> AssetRecord {
        var value = previous
        value.creationDate = asset.creationDate
        value.sourceModificationDate = normalizedModificationDate(asset.modificationDate)
        value.sourceModificationDateWasCaptured = true
        value.isFavorite = asset.isFavorite
        value.isScreenshot = false
        value.burstIdentifier = asset.burstIdentifier
        value.albumAnalysisVersion = nil
        value.albumTraits = nil
        return value
    }

    private static let largePhotoTraceMinimumPixelCount: Int64 = 40_000_000

    private static func logLargePhotoThumbnailResolved(
        assetHash: String,
        sourcePixels: String,
        outputPixels: String,
        decodedBytesEstimate: Int,
        durationMilliseconds: Double,
        outcome: String
    ) {
        SharedLog.app.info(
            "image-load",
            "Large photo thumbnail resolved",
            metadata: [
                "asset": assetHash,
                "decodedBytesEstimate": "\(decodedBytesEstimate)",
                "durationMs": String(format: "%.1f", durationMilliseconds),
                "outcome": outcome,
                "outputPixels": outputPixels,
                "sourcePixels": sourcePixels,
                "targetPixels": "1024x1024"
            ]
        )
    }

    private static func localThumbnail(
        for asset: PHAsset
    ) async throws -> LocalThumbnailLoadResult {
        let options = PHImageRequestOptions()
        options.version = .current
        // Keep the request asynchronous: malformed or partially imported
        // PhotoKit records can fail to return from a synchronous request. The
        // request wrapper enforces a bounded wait and cancels PhotoKit on
        // timeout. Network access stays disabled to avoid iCloud downloads.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        #if targetEnvironment(simulator)
        // simctl can publish PHAsset metadata shortly before the imported
        // resource becomes readable. The scale job must keep one app PID, so
        // retry only under its explicit DEBUG launch argument rather than
        // terminating and relaunching the app between attempts.
        let maximumAttempts = ProcessInfo.processInfo.arguments.contains(
            "--neko-simulator-scale"
        ) ? 4 : 1
        #else
        let maximumAttempts = 1
        #endif
        var resolvedOutcome: LocalThumbnailRequestOutcome?
        for attempt in 1...maximumAttempts {
            let request = LocalThumbnailRequest(
                asset: asset,
                options: options,
                timeoutNanoseconds: 5_000_000_000
            )
            let outcome = await withTaskCancellationHandler {
                await request.value()
            } onCancel: {
                request.cancel()
            }
            try Task.checkCancellation()
            resolvedOutcome = outcome

            if outcome.image != nil
                || outcome.isInCloud
                || outcome.wasCancelled
                || attempt == maximumAttempts {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let outcome = resolvedOutcome else {
            return .failed
        }

        if let output = outcome.image {
            if thumbnailLogSampler.takeSuccess() {
                let width = output.cgImage?.width
                    ?? Int((output.size.width * output.scale).rounded())
                let height = output.cgImage?.height
                    ?? Int((output.size.height * output.scale).rounded())
                SharedLog.app.debug(
                    "image-load",
                    "Photo thumbnail loaded (sampled)",
                    metadata: [
                        "asset": SharedLog.shortHash(asset.localIdentifier),
                        "assetPixels": "\(asset.pixelWidth)x\(asset.pixelHeight)",
                        "degraded": "\(outcome.isDegraded)",
                        "deliveryMode": "highQualityFormat",
                        "estimatedDecodedBytes": "\(width * height * 4)",
                        "networkAllowed": "false",
                        "outputPixels": "\(width)x\(height)",
                        "targetPixels": "1024x1024"
                    ]
                )
            }
        } else if thumbnailLogSampler.takeFailure() {
            SharedLog.app.warning(
                "image-load",
                "Photo thumbnail load failed (sampled)",
                metadata: [
                    "asset": SharedLog.shortHash(asset.localIdentifier),
                    "assetPixels": "\(asset.pixelWidth)x\(asset.pixelHeight)",
                    "cancelled": "\(outcome.wasCancelled)",
                    "code": outcome.errorCode.map { String($0) } ?? "none",
                    "deliveryMode": "highQualityFormat",
                    "degraded": "\(outcome.isDegraded)",
                    "domain": outcome.errorDomain ?? "none",
                    "inCloud": "\(outcome.isInCloud)",
                    "networkAllowed": "false",
                    "targetPixels": "1024x1024",
                    "timedOut": "\(outcome.timedOut)"
                ]
            )
        }
        if let output = outcome.image {
            return .image(output)
        }
        return outcome.isInCloud ? .unavailableLocally : .failed
    }

    private static let thumbnailLogSampler = ThumbnailLogSampler(limit: 12)

    private static func normalizedModificationDate(_ date: Date?) -> Date? {
        date.map {
            // AtomicJSON's ISO-8601 representation stores whole seconds. Keep
            // the in-memory value on the same precision so a persisted record
            // does not look edited merely because fractional seconds vanished.
            Date(timeIntervalSince1970: floor($0.timeIntervalSince1970))
        }
    }

    private static func excludedRecord(
        asset: PHAsset,
        status: AssetAnalysisStatus,
        analysisFingerprint: String,
        previous: AssetRecord?
    ) -> AssetRecord {
        AssetRecord(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            sourceModificationDate: Self.normalizedModificationDate(asset.modificationDate),
            sourceModificationDateWasCaptured: true,
            isFavorite: asset.isFavorite,
            isScreenshot: status == .excludedScreenshot,
            burstIdentifier: asset.burstIdentifier,
            cat: .none,
            analysisStatus: status,
            analysisFingerprint: analysisFingerprint,
            albumAnalysisVersion: CatAlbumTraits.currentAnalysisVersion,
            albumTraits: nil
        ).preservingUserState(from: previous)
    }
}

private final class ThumbnailLogSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var successCount = 0
    private var failureCount = 0

    init(limit: Int) {
        self.limit = limit
    }

    func takeSuccess() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard successCount < limit else { return false }
        successCount += 1
        return true
    }

    func takeFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard failureCount < limit else { return false }
        failureCount += 1
        return true
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
