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

        var preservesPreviousCatOnFailure: Bool {
            switch self {
            case .groupedAlbumOnly: return true
            case .full: return false
            }
        }
    }

    private struct IndexedRecord: Sendable {
        var index: Int
        var record: AssetRecord
        var recoveryDiagnostics: ScanRecoveryDiagnostics
    }

    private struct AnalyzedAsset: Sendable {
        var record: AssetRecord
        var recoveryDiagnostics: ScanRecoveryDiagnostics = .zero
    }

    private enum LocalThumbnailProfile: Sendable {
        case primary1024
        case localRecovery512
        case highResolution2048

        var targetSize: CGSize {
            switch self {
            case .primary1024: CGSize(width: 1_024, height: 1_024)
            case .localRecovery512: CGSize(width: 512, height: 512)
            case .highResolution2048: CGSize(width: 2_048, height: 2_048)
            }
        }

        var deliveryMode: PHImageRequestOptionsDeliveryMode {
            switch self {
            case .localRecovery512: .fastFormat
            case .primary1024, .highResolution2048: .highQualityFormat
            }
        }

        var acceptsDegradedImage: Bool {
            switch self {
            case .localRecovery512: true
            case .primary1024, .highResolution2048: false
            }
        }

        var logName: String {
            switch self {
            case .primary1024: "primary1024"
            case .localRecovery512: "localRecovery512"
            case .highResolution2048: "highResolution2048"
            }
        }
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
        private let targetSize: CGSize
        private let acceptsDegradedImage: Bool
        private let timeoutNanoseconds: UInt64
        private let lock = NSLock()
        private var continuation: CheckedContinuation<LocalThumbnailRequestOutcome, Never>?
        private var requestID: PHImageRequestID?
        private var timeoutTask: Task<Void, Never>?
        private var isFinished = false
        private var sawDegradedOrCloudResult = false

        init(
            asset: PHAsset,
            options: PHImageRequestOptions,
            targetSize: CGSize,
            acceptsDegradedImage: Bool,
            timeoutNanoseconds: UInt64
        ) {
            self.asset = asset
            self.options = options
            self.targetSize = targetSize
            self.acceptsDegradedImage = acceptsDegradedImage
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
                    targetSize: targetSize,
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
                    let sawFallbackEvidence = self.fallbackEvidenceSeen()
                    self.finish(
                        LocalThumbnailRequestOutcome(
                            image: nil,
                            errorDomain: "PhotoLibraryScanner.Timeout",
                            errorCode: 1,
                            wasCancelled: false,
                            isInCloud: sawFallbackEvidence,
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
            let sawFallbackEvidence = recordFallbackEvidence(
                imageWasReturned: image != nil,
                isDegraded: isDegraded,
                isInCloud: isInCloud
            )

            // A high-quality asynchronous request may first deliver a degraded
            // image. Wait for the final callback unless the request has ended.
            if isDegraded, !wasCancelled, error == nil {
                guard acceptsDegradedImage, image != nil else { return }
            }
            finish(
                LocalThumbnailRequestOutcome(
                    image: wasCancelled || error != nil ? nil : image,
                    errorDomain: error?.domain,
                    errorCode: error?.code,
                    wasCancelled: wasCancelled,
                    isInCloud: isInCloud || (image == nil && sawFallbackEvidence),
                    isDegraded: isDegraded,
                    timedOut: false
                ),
                cancelImageRequest: isDegraded && acceptsDegradedImage
            )
        }

        private func recordFallbackEvidence(
            imageWasReturned: Bool,
            isDegraded: Bool,
            isInCloud: Bool
        ) -> Bool {
            lock.lock()
            if isInCloud || (isDegraded && imageWasReturned) {
                sawDegradedOrCloudResult = true
            }
            let value = sawDegradedOrCloudResult
            lock.unlock()
            return value
        }

        private func fallbackEvidenceSeen() -> Bool {
            lock.lock()
            let value = sawDegradedOrCloudResult
            lock.unlock()
            return value
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
    /// thumbnails at a time. The normal pass is 1024px, with bounded 512px
    /// local-recovery and 2048px no-cat fallback passes. None may download from
    /// iCloud. Moving the app out of the foreground cancels the owning Task.
    func scan(
        existing: LibrarySnapshot,
        settings inputSettings: AppSettings,
        forceFullAnalysis: Bool,
        sourceAlbumIdentifier: String? = nil,
        onEvent: @escaping @Sendable (ScanEvent) async -> Void
    ) async throws -> LibrarySnapshot {
        let settings = inputSettings.normalized()
        let scanStartedAt = Date()
        var migratedExisting = existing
        migratedExisting.assets = existing.assets.map {
            $0.migratedToBoundingBoxPostureAnalysis(
                synthesizingMissingTraits: existing.schemaVersion >= 2
            )
        }
        // `.postureRepair` is a decode-only legacy route. Bounding-box posture
        // migration is synchronous and must never launch animal body-pose work.
        let requestedPurpose = migratedExisting.scanState.purpose
            ?? (forceFullAnalysis ? .manualRescan : .regular)
        let scanPurpose: ScanPurpose = requestedPurpose == .postureRepair
            ? .regular
            : requestedPurpose
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
            uniqueKeysWithValues: migratedExisting.assets.map {
                ($0.localIdentifier, $0)
            }
        )
        let activeIdentifiers = Set(assets.map(\.localIdentifier))
        // A selected album is only a candidate scope, not permission to destroy
        // the full-library Vision cache. Dormant records remain hidden by the
        // durable source membership and become reusable if the user later picks
        // another album or returns to the whole library.
        let dormantIdentifiers = PhotoSourceCachePolicy.dormantIdentifiers(
            existingIdentifiers: migratedExisting.assets.map(\.localIdentifier),
            activeIdentifiers: activeIdentifiers,
            usesSelectedSource: sourceAlbumIdentifier != nil
        )
        let dormantRecords = migratedExisting.assets.filter {
            dormantIdentifiers.contains($0.localIdentifier)
        }
        var records = Array<AssetRecord?>(repeating: nil, count: assets.count)
        var seenBurstIdentifiers = Set<String>()
        let quickEnd = min(settings.quickScanLimit, assets.count)
        var recoveryDiagnostics = ScanRecoveryDiagnostics.zero

        if quickEnd > 0 {
            recoveryDiagnostics = try await process(
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
                startingRecoveryDiagnostics: recoveryDiagnostics,
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
            purpose: scanPurpose,
            settings: settings,
            recoveryDiagnostics: recoveryDiagnostics
        )
        quickState.lastScannedAt = .now
        quickState.scanDurationMilliseconds = Date().timeIntervalSince(scanStartedAt) * 1_000
        var quickSnapshot = migratedExisting
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
            recoveryDiagnostics = try await process(
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
                startingRecoveryDiagnostics: recoveryDiagnostics,
                onEvent: onEvent
            )
        }

        try Task.checkCancellation()
        var final = migratedExisting
        final.assets = records.compactMap { $0 } + dormantRecords
        final.scanState = makeState(
            records: records,
            scannedAssets: assets.count,
            totalAssets: assets.count,
            phase: .completed,
            resultKind: .final,
            requiresFullRescan: false,
            purpose: scanPurpose,
            settings: settings,
            recoveryDiagnostics: recoveryDiagnostics
        )
        final.scanState.lastScannedAt = .now
        final.scanState.scanDurationMilliseconds = Date().timeIntervalSince(scanStartedAt) * 1_000
        final.settings = settings
        final.updatedAt = .now
        var completionMetadata = [
            "bboxAnalysisVersion": "\(CatAlbumTraits.currentAnalysisVersion)",
            "cats": "\(final.scanState.catAssets)",
            "widgetEligibleCats": "\(final.scanState.widgetEligibleAssets ?? 0)",
            "deferred": "\(final.scanState.deferredAssets)",
            "bboxScope": "active-source-before-user-curation",
            "scanPurpose": scanPurpose.rawValue,
            "scanDurationMs": String(
                format: "%.1f",
                final.scanState.scanDurationMilliseconds ?? 0
            ),
            "total": "\(final.scanState.totalAssets)"
        ]
        completionMetadata.merge(
            final.scanState.postureSummary?.logMetadata ?? [:],
            uniquingKeysWith: { current, _ in current }
        )
        completionMetadata.merge(
            recoveryDiagnostics.logMetadata,
            uniquingKeysWith: { current, _ in current }
        )
        completionMetadata.merge(
            CatBoundingBoxAspectDistribution(
                records: records.compactMap { $0 }.filter {
                    $0.analysisFingerprint == settings.analysisFingerprint
                }
            ).logMetadata,
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
        startingRecoveryDiagnostics: ScanRecoveryDiagnostics,
        onEvent: @escaping @Sendable (ScanEvent) async -> Void
    ) async throws -> ScanRecoveryDiagnostics {
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
        var recoveryDiagnostics = startingRecoveryDiagnostics

        while batchStart < range.upperBound {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + concurrency, range.upperBound)
            var pending: [(Int, PHAsset, AssetRecord?, AnalysisMode)] = []

            for index in batchStart..<batchEnd {
                let asset = assets[index]
                let previous = previousByIdentifier[asset.localIdentifier]
                let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)

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
                   Self.canReusePrimaryAnalysis(previous, settings: settings),
                   (previous.sourceModificationDateWasCaptured != true
                       || previous.sourceModificationDate
                           == Self.normalizedModificationDate(asset.modificationDate)),
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
                    // Build 18's fingerprint included the Widget-only minimum
                    // area. Existing positive detections remain valid under the
                    // same detector settings and migrate without another image
                    // request. Old no-cat records are deliberately not reusable
                    // because some were only below that presentation threshold.
                    reused.analysisFingerprint = settings.analysisFingerprint
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
                            recoveryDiagnostics.merge(.init(
                                evidence: reused.analysisEvidence
                            ))
                        } else {
                            pending.append((index, asset, previous, .groupedAlbumOnly))
                        }
                    } else if reused.analysisStatus == .noCat {
                        reused.albumAnalysisVersion =
                            CatAlbumTraits.currentAnalysisVersion
                        reused.albumTraits = nil
                        records[index] = reused
                        reusedCount += 1
                        recoveryDiagnostics.merge(.init(
                            evidence: reused.analysisEvidence
                        ))
                    } else if reused.analysisStatus == .unavailableLocally {
                        // Build 19 already exhausted both network-disabled
                        // local requests. Keep that durable result until an
                        // explicit full rescan asks to probe local availability
                        // again; do not repeat thousands of requests on every
                        // foreground activation.
                        records[index] = reused
                        reusedCount += 1
                        recoveryDiagnostics.merge(.init(
                            evidence: reused.analysisEvidence
                        ))
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
                        let result = try await Self.analyze(
                            asset: asset,
                            settings: settings,
                            previous: previous,
                            analysisMode: analysisMode,
                            isOuting: Self.outingValue(
                                for: asset.localIdentifier,
                                in: outingByIdentifier
                            )
                        )
                        return IndexedRecord(
                            index: index,
                            record: result.record,
                            recoveryDiagnostics: result.recoveryDiagnostics
                        )
                    }
                }

                var values: [IndexedRecord] = []
                for try await value in group { values.append(value) }
                return values
            }
            for value in analyzed {
                records[value.index] = value.record
                recoveryDiagnostics.merge(value.recoveryDiagnostics)
            }

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
                    purpose: purpose,
                    settings: settings,
                    recoveryDiagnostics: recoveryDiagnostics
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
            ].merging(recoveryDiagnostics.logMetadata) { current, _ in current }
        )
        return recoveryDiagnostics
    }

    private func makeState(
        records: [AssetRecord?],
        scannedAssets: Int,
        totalAssets: Int,
        phase: ScanPhase,
        resultKind: ScanResultKind,
        requiresFullRescan: Bool,
        purpose: ScanPurpose?,
        settings: AppSettings,
        recoveryDiagnostics: ScanRecoveryDiagnostics
    ) -> ScanState {
        let finished = records.compactMap { $0 }
        let cats = finished.filter(\.isCatCandidate)
        let postureSummary = PostureScanSummary(records: finished)
        let resultingPurpose: ScanPurpose? = resultKind == .final ? nil : purpose
        return ScanState(
            phase: phase,
            resultKind: resultKind,
            lastScannedAt: nil,
            totalAssets: totalAssets,
            scannedAssets: scannedAssets,
            catAssets: cats.count,
            widgetEligibleAssets: cats.lazy.filter {
                $0.isWidgetEligible(settings: settings)
            }.count,
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
            recoveryDiagnostics: recoveryDiagnostics,
            postureSummary: postureSummary,
            // Completing one full pass clears the migration banner even when
            // an iCloud-only known cat could not receive secondary traits.
            // Its nil album version is still retried by the normal reuse path.
            requiresFullRescan: requiresFullRescan,
            // The former postureRepair route is decode-only. Bounding-box
            // posture migration is local and a final scan never schedules a
            // secondary animal-body-pose pass.
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

    private static func canReusePrimaryAnalysis(
        _ record: AssetRecord,
        settings: AppSettings
    ) -> Bool {
        record.migratedToAreaIndependentDetection(settings: settings)
            .analysisFingerprint == settings.analysisFingerprint
    }

    private struct CatRecognitionResult {
        var boundingBoxes: [CGRect]
        var union: CGRect
        var areaRatio: Double
        var confidence: Float

        var detected: Bool { !boundingBoxes.isEmpty && !union.isNull }
    }

    private static func analyze(
        asset: PHAsset,
        settings: AppSettings,
        previous: AssetRecord?,
        analysisMode: AnalysisMode,
        isOuting: Bool?
    ) async throws -> AnalyzedAsset {
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
        var recoveryDiagnostics = ScanRecoveryDiagnostics.zero

        func finish(_ record: AssetRecord) -> AnalyzedAsset {
            AnalyzedAsset(
                record: record,
                recoveryDiagnostics: recoveryDiagnostics
            )
        }

        func terminalRecord(
            status: AssetAnalysisStatus,
            evidence: AssetAnalysisEvidence? = nil
        ) -> AssetRecord {
            AssetRecord(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                sourceModificationDate: Self.normalizedModificationDate(asset.modificationDate),
                sourceModificationDateWasCaptured: true,
                isFavorite: asset.isFavorite,
                isScreenshot: false,
                burstIdentifier: asset.burstIdentifier,
                cat: .none,
                analysisStatus: status,
                analysisFingerprint: settings.analysisFingerprint,
                analysisEvidence: evidence,
                albumAnalysisVersion: status == .noCat
                    ? CatAlbumTraits.currentAnalysisVersion
                    : nil,
                albumTraits: nil
            ).preservingUserState(from: previous)
        }

        func preservePreviousOrFinish(
            _ record: AssetRecord,
            outcome: String
        ) -> AnalyzedAsset {
            if analysisMode.preservesPreviousCatOnFailure,
               let previous,
               previous.isCatCandidate {
                processingOutcome = outcome
                return finish(pendingGroupedAlbumRecord(asset: asset, previous: previous))
            }
            return finish(record)
        }

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
            thumbnailResult = try await localThumbnail(
                for: asset,
                profile: .primary1024
            )
        } catch is CancellationError {
            processingOutcome = "cancelled"
            throw CancellationError()
        } catch {
            processingOutcome = "thumbnailError"
            throw error
        }

        var image: UIImage
        var evidence = AssetAnalysisEvidence(finalPass: .primary1024)
        var localRecoveryStartedAt: Date?

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
            // A secondary repair must never replace a known full-fidelity cat
            // with a 512px result. Only genuinely deferred primary records use
            // the local recovery pass.
            if analysisMode.preservesPreviousCatOnFailure,
               let previous,
               previous.isCatCandidate {
                processingOutcome = "detected-album-pending"
                return finish(pendingGroupedAlbumRecord(asset: asset, previous: previous))
            }

            recoveryDiagnostics.localRecoveryAttemptedAssets = 1
            localRecoveryStartedAt = Date()
            let recoveryResult = try await localThumbnail(
                for: asset,
                profile: .localRecovery512
            )
            switch recoveryResult {
            case .image(let recoveredImage):
                image = recoveredImage
                evidence = AssetAnalysisEvidence(
                    finalPass: .localRecovery512,
                    fallbackReason: .unavailableLocally
                )
            case .unavailableLocally:
                let duration = Date().timeIntervalSince(localRecoveryStartedAt!) * 1_000
                recoveryDiagnostics.localRecoveryDurationMilliseconds = duration
                processingOutcome = AssetAnalysisStatus.unavailableLocally.rawValue
                return finish(terminalRecord(
                    status: .unavailableLocally,
                    evidence: AssetAnalysisEvidence(
                        finalPass: .localRecovery512,
                        fallbackReason: .unavailableLocally,
                        fallbackOutcome: .unavailableLocally,
                        fallbackDurationMilliseconds: duration
                    )
                ))
            case .failed:
                let duration = Date().timeIntervalSince(localRecoveryStartedAt!) * 1_000
                recoveryDiagnostics.localRecoveryDurationMilliseconds = duration
                processingOutcome = AssetAnalysisStatus.unavailableLocally.rawValue
                // The primary request established the durable reason. A failed
                // optional recovery must not rewrite it to a generic failure.
                return finish(terminalRecord(
                    status: .unavailableLocally,
                    evidence: AssetAnalysisEvidence(
                        finalPass: .localRecovery512,
                        fallbackReason: .unavailableLocally,
                        fallbackOutcome: .failed,
                        fallbackDurationMilliseconds: duration
                    )
                ))
            }
        case .failed:
            processingOutcome = AssetAnalysisStatus.failed.rawValue
            return preservePreviousOrFinish(
                terminalRecord(status: .failed),
                outcome: "detected-album-pending"
            )
        }

        guard var cgImage = image.cgImage else {
            SharedLog.app.warning(
                "image-load",
                "Photo thumbnail had no CGImage backing",
                metadata: ["asset": SharedLog.shortHash(asset.localIdentifier)]
            )
            if let localRecoveryStartedAt {
                let duration = Date().timeIntervalSince(localRecoveryStartedAt) * 1_000
                recoveryDiagnostics.localRecoveryDurationMilliseconds = duration
                evidence.fallbackOutcome = .failed
                evidence.fallbackDurationMilliseconds = duration
                processingOutcome = AssetAnalysisStatus.unavailableLocally.rawValue
                return finish(terminalRecord(
                    status: .unavailableLocally,
                    evidence: evidence
                ))
            }
            processingOutcome = AssetAnalysisStatus.failed.rawValue
            return preservePreviousOrFinish(
                terminalRecord(status: .failed, evidence: evidence),
                outcome: "detected-album-pending"
            )
        }

        var orientation = CGImagePropertyOrientation(image.imageOrientation)
        var recognition: CatRecognitionResult
        do {
            recognition = try recognizeCats(
                cgImage: cgImage,
                orientation: orientation,
                confidenceThreshold: settings.confidenceThreshold
            )
        } catch is CancellationError {
            processingOutcome = "cancelled"
            throw CancellationError()
        } catch {
            let duration = localRecoveryStartedAt.map {
                Date().timeIntervalSince($0) * 1_000
            }
            if let duration {
                recoveryDiagnostics.localRecoveryDurationMilliseconds = duration
                evidence.fallbackOutcome = .failed
                evidence.fallbackDurationMilliseconds = duration
                processingOutcome = AssetAnalysisStatus.unavailableLocally.rawValue
                logFallbackVisionFailure(error, pass: .localRecovery512)
                return finish(terminalRecord(
                    status: .unavailableLocally,
                    evidence: evidence
                ))
            }
            return visionFailureResult(
                error: error,
                asset: asset,
                settings: settings,
                previous: previous,
                analysisMode: analysisMode,
                processingOutcome: &processingOutcome,
                recoveryDiagnostics: recoveryDiagnostics
            )
        }

        if let localRecoveryStartedAt {
            let duration = Date().timeIntervalSince(localRecoveryStartedAt) * 1_000
            recoveryDiagnostics.localRecoveryResolvedAssets = 1
            recoveryDiagnostics.localRecoveryDetectedAssets = recognition.detected ? 1 : 0
            recoveryDiagnostics.localRecoveryDurationMilliseconds = duration
            evidence.fallbackOutcome = recognition.detected ? .detected : .noCat
            evidence.fallbackDurationMilliseconds = duration
        } else if !recognition.detected {
            recoveryDiagnostics.highResolutionAttemptedAssets = 1
            let highResolutionStartedAt = Date()
            let highResolutionResult = try await localThumbnail(
                for: asset,
                profile: .highResolution2048
            )
            var fallbackOutcome: AssetAnalysisFallbackOutcome
            switch highResolutionResult {
            case .image(let highResolutionImage):
                if let highResolutionCGImage = highResolutionImage.cgImage {
                    do {
                        let highOrientation = CGImagePropertyOrientation(
                            highResolutionImage.imageOrientation
                        )
                        let highRecognition = try recognizeCats(
                            cgImage: highResolutionCGImage,
                            orientation: highOrientation,
                            confidenceThreshold: settings.confidenceThreshold
                        )
                        recoveryDiagnostics.highResolutionResolvedAssets = 1
                        recoveryDiagnostics.highResolutionDetectedAssets = highRecognition.detected
                            ? 1
                            : 0
                        fallbackOutcome = highRecognition.detected ? .detected : .noCat
                        image = highResolutionImage
                        cgImage = highResolutionCGImage
                        orientation = highOrientation
                        recognition = highRecognition
                        evidence.finalPass = .highResolution2048
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        fallbackOutcome = .failed
                        logFallbackVisionFailure(error, pass: .highResolution2048)
                    }
                } else {
                    fallbackOutcome = .failed
                }
            case .unavailableLocally:
                fallbackOutcome = .unavailableLocally
            case .failed:
                fallbackOutcome = .failed
            }
            let duration = Date().timeIntervalSince(highResolutionStartedAt) * 1_000
            recoveryDiagnostics.highResolutionDurationMilliseconds = duration
            evidence.fallbackReason = .noCatAt1024
            evidence.fallbackOutcome = fallbackOutcome
            evidence.fallbackDurationMilliseconds = duration
        }

        guard recognition.detected else {
            if analysisMode.preservesPreviousCatOnFailure,
               let previous,
               previous.isCatCandidate {
                processingOutcome = "detected-album-pending"
                return finish(pendingGroupedAlbumRecord(asset: asset, previous: previous))
            }
            processingOutcome = AssetAnalysisStatus.noCat.rawValue
            return finish(terminalRecord(status: .noCat, evidence: evidence))
        }

        // Detection deliberately has no minimum-area gate. The complete area
        // ratio is persisted and the stricter Widget selector applies it later.
        let primaryDetection = CatDetection(
            detected: true,
            confidence: recognition.confidence,
            boundingBox: NormalizedRect(recognition.union),
            areaRatio: recognition.areaRatio,
            catCount: recognition.boundingBoxes.count,
            instanceBoundingBoxes: recognition.boundingBoxes.map(NormalizedRect.init)
        )
        let primaryAnalyzedAt = Date.now

        do {
            try Task.checkCancellation()
            let traits = try boundingBoxAlbumTraits(
                cgImage: cgImage,
                orientation: orientation,
                catBoundingBoxes: recognition.boundingBoxes,
                isOuting: isOuting
            )
            processingOutcome = evidence.isLowFidelity
                ? "detected-local-recovery"
                : (evidence.finalPass == .highResolution2048
                    ? "detected-high-resolution"
                    : AssetAnalysisStatus.detected.rawValue)
            return finish(AssetRecord(
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
                analysisEvidence: evidence,
                albumAnalysisVersion: CatAlbumTraits.currentAnalysisVersion,
                albumTraits: traits
            ).preservingUserState(from: previous))
        } catch is CancellationError {
            processingOutcome = "cancelled"
            throw CancellationError()
        } catch {
            // A secondary album classifier must never erase a valid cat or
            // make it disappear from the Widget candidate cache.
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
            return finish(AssetRecord(
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
                analysisEvidence: evidence,
                albumAnalysisVersion: nil,
                albumTraits: nil
            ).preservingUserState(from: previous))
        }
    }

    private static func recognizeCats(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        confidenceThreshold: Float
    ) throws -> CatRecognitionResult {
        let request = VNRecognizeAnimalsRequest()
#if targetEnvironment(simulator)
        request.usesCPUOnly = true
#endif
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: orientation,
            options: [:]
        )
        try handler.perform([request])
        let cats: [(CGRect, Float)] = (request.results ?? []).compactMap { observation in
            guard let label = observation.labels
                .filter({ $0.identifier.caseInsensitiveCompare("cat") == .orderedSame })
                .max(by: { $0.confidence < $1.confidence }),
                  label.confidence >= confidenceThreshold else {
                return nil
            }
            return (observation.boundingBox, label.confidence)
        }
        let boxes = cats.map(\.0)
        return CatRecognitionResult(
            boundingBoxes: boxes,
            union: boxes.reduce(CGRect.null) { $0.union($1) },
            areaRatio: min(1, boxes.reduce(0) {
                $0 + Double($1.width * $1.height)
            }),
            confidence: cats.map(\.1).max() ?? 0
        )
    }

    private static func visionFailureResult(
        error: Error,
        asset: PHAsset,
        settings: AppSettings,
        previous: AssetRecord?,
        analysisMode: AnalysisMode,
        processingOutcome: inout String,
        recoveryDiagnostics: ScanRecoveryDiagnostics
    ) -> AnalyzedAsset {
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
            return AnalyzedAsset(
                record: pendingGroupedAlbumRecord(asset: asset, previous: previous),
                recoveryDiagnostics: recoveryDiagnostics
            )
        }
        processingOutcome = AssetAnalysisStatus.failed.rawValue
        SharedLog.app.error(
            "vision",
            "Vision animal recognition request failed",
            metadata: ["code": "\(value.code)", "domain": value.domain]
        )
        return AnalyzedAsset(
            record: AssetRecord(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                sourceModificationDate: normalizedModificationDate(asset.modificationDate),
                sourceModificationDateWasCaptured: true,
                isFavorite: asset.isFavorite,
                isScreenshot: false,
                burstIdentifier: asset.burstIdentifier,
                cat: .none,
                analysisStatus: .failed,
                analysisFingerprint: settings.analysisFingerprint
            ).preservingUserState(from: previous),
            recoveryDiagnostics: recoveryDiagnostics
        )
    }

    private static func logFallbackVisionFailure(
        _ error: Error,
        pass: AssetDetectionPass
    ) {
        let value = error as NSError
        SharedLog.app.warning(
            "vision",
            "Cat recovery Vision pass failed; keeping the primary result",
            metadata: [
                "code": "\(value.code)",
                "domain": value.domain,
                "pass": pass.rawValue
            ]
        )
    }

    private static func boundingBoxAlbumTraits(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        catBoundingBoxes: [CGRect],
        isOuting: Bool?
    ) throws -> CatAlbumTraits {
        let faceRequest = VNDetectFaceRectanglesRequest()
#if targetEnvironment(simulator)
        faceRequest.usesCPUOnly = true
#endif
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: orientation,
            options: [:]
        )
        try handler.perform([faceRequest])

        let normalizedCatBoxes = catBoundingBoxes.map(NormalizedRect.init)
        let containsPerson = containsProminentHumanFace(
            faceRequest.results ?? [],
            excluding: catBoundingBoxes
        )
        let largestCatAreaRatio = catBoundingBoxes.lazy.map {
            Double($0.width * $0.height)
        }.max() ?? 0
        return CatAlbumTraits(
            postures: CatBoundingBoxAspectBucket.postures(
                for: normalizedCatBoxes
            ),
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
        for asset: PHAsset,
        profile: LocalThumbnailProfile
    ) async throws -> LocalThumbnailLoadResult {
        let options = PHImageRequestOptions()
        options.version = .current
        // Keep the request asynchronous: malformed or partially imported
        // PhotoKit records can fail to return from a synchronous request. The
        // request wrapper enforces a bounded wait and cancels PhotoKit on
        // timeout. Network access stays disabled to avoid iCloud downloads.
        options.deliveryMode = profile.deliveryMode
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
                targetSize: profile.targetSize,
                acceptsDegradedImage: profile.acceptsDegradedImage,
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
                        "deliveryMode": profile.logName,
                        "estimatedDecodedBytes": "\(width * height * 4)",
                        "networkAllowed": "false",
                        "outputPixels": "\(width)x\(height)",
                        "targetPixels": "\(Int(profile.targetSize.width))x\(Int(profile.targetSize.height))"
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
                    "deliveryMode": profile.logName,
                    "degraded": "\(outcome.isDegraded)",
                    "domain": outcome.errorDomain ?? "none",
                    "inCloud": "\(outcome.isInCloud)",
                    "networkAllowed": "false",
                    "targetPixels": "\(Int(profile.targetSize.width))x\(Int(profile.targetSize.height))",
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
