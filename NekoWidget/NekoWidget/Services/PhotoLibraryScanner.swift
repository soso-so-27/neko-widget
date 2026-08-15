@preconcurrency import Photos
@preconcurrency import Vision
import ImageIO
import UIKit

enum ScanEvent: Sendable {
    case progress(ScanState, analyzedRecords: [AssetRecord])
    case provisional(LibrarySnapshot)
}

actor PhotoLibraryScanner {
    private struct IndexedRecord: Sendable {
        var index: Int
        var record: AssetRecord
    }

    /// Performs a newest-first, two-stage scan. Inference runs four thumbnails
    /// at a time; each thumbnail is bounded to 1024px and never downloads from
    /// iCloud. Moving the app out of the foreground cancels the owning Task.
    func scan(
        existing: LibrarySnapshot,
        settings inputSettings: AppSettings,
        forceFullAnalysis: Bool,
        onEvent: @escaping @Sendable (ScanEvent) async -> Void
    ) async throws -> LibrarySnapshot {
        let settings = inputSettings.normalized()
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }
        SharedLog.app.info(
            "scan",
            "Photo library fetch completed",
            metadata: [
                "assets": "\(assets.count)",
                "forceFullAnalysis": "\(forceFullAnalysis)",
                "networkAllowed": "false",
                "quickLimit": "\(settings.quickScanLimit)"
            ]
        )

        let previousByIdentifier = Dictionary(
            uniqueKeysWithValues: existing.assets.map { ($0.localIdentifier, $0) }
        )
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
                settings: settings,
                forceFullAnalysis: forceFullAnalysis,
                totalAssets: assets.count,
                phase: .quickScan,
                onEvent: onEvent
            )
        }

        var quickState = makeState(
            records: records,
            scannedAssets: quickEnd,
            totalAssets: assets.count,
            phase: assets.count > quickEnd ? .fullScan : .completed,
            resultKind: assets.count > quickEnd ? .provisional : .final,
            requiresFullRescan: forceFullAnalysis && assets.count > quickEnd
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
                settings: settings,
                forceFullAnalysis: forceFullAnalysis,
                totalAssets: assets.count,
                phase: .fullScan,
                onEvent: onEvent
            )
        }

        try Task.checkCancellation()
        var final = existing
        final.assets = records.compactMap { $0 }
        final.scanState = makeState(
            records: records,
            scannedAssets: assets.count,
            totalAssets: assets.count,
            phase: .completed,
            resultKind: .final,
            requiresFullRescan: false
        )
        final.scanState.lastScannedAt = .now
        final.settings = settings
        final.updatedAt = .now
        SharedLog.app.info(
            "scan",
            "Photo library scan completed",
            metadata: [
                "cats": "\(final.scanState.catAssets)",
                "deferred": "\(final.scanState.deferredAssets)",
                "total": "\(final.scanState.totalAssets)"
            ]
        )
        return final
    }

    private func process(
        range: Range<Int>,
        assets: [PHAsset],
        records: inout [AssetRecord?],
        seenBurstIdentifiers: inout Set<String>,
        previousByIdentifier: [String: AssetRecord],
        settings: AppSettings,
        forceFullAnalysis: Bool,
        totalAssets: Int,
        phase: ScanPhase,
        onEvent: @escaping @Sendable (ScanEvent) async -> Void
    ) async throws {
        let concurrency = 4
        var batchStart = range.lowerBound
        var lastPublishedIndex = range.lowerBound
        var newlyAnalyzedCount = 0
        var reusedCount = 0

        while batchStart < range.upperBound {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + concurrency, range.upperBound)
            var pending: [(Int, PHAsset, AssetRecord?)] = []

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

                if let previous,
                   previous.analysisFingerprint == settings.analysisFingerprint,
                   previous.analysisStatus != .unavailableLocally,
                   previous.analysisStatus != .failed {
                    var reused = previous
                    reused.creationDate = asset.creationDate
                    reused.isFavorite = asset.isFavorite
                    reused.isScreenshot = false
                    reused.burstIdentifier = asset.burstIdentifier
                    records[index] = reused
                    reusedCount += 1
                } else {
                    pending.append((index, asset, previous))
                }
            }
            newlyAnalyzedCount += pending.count

            let analyzed = try await withThrowingTaskGroup(
                of: IndexedRecord.self,
                returning: [IndexedRecord].self
            ) { group in
                for (index, asset, previous) in pending {
                    group.addTask {
                        try Task.checkCancellation()
                        let record = autoreleasepool {
                            Self.analyze(
                                asset: asset,
                                settings: settings,
                                previous: previous
                            )
                        }
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
                    requiresFullRescan: forceFullAnalysis
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
        requiresFullRescan: Bool
    ) -> ScanState {
        let finished = records.compactMap { $0 }
        let cats = finished.filter(\.isCatCandidate)
        return ScanState(
            phase: phase,
            resultKind: resultKind,
            lastScannedAt: nil,
            totalAssets: totalAssets,
            scannedAssets: scannedAssets,
            catAssets: cats.count,
            oldestCatPhotoDate: cats.compactMap(\.creationDate).min(),
            deferredAssets: finished.filter { $0.analysisStatus == .unavailableLocally }.count,
            requiresFullRescan: requiresFullRescan,
            lastError: nil
        )
    }

    private static func analyze(
        asset: PHAsset,
        settings: AppSettings,
        previous: AssetRecord?
    ) -> AssetRecord {
        guard let image = localThumbnail(for: asset), let cgImage = image.cgImage else {
            return AssetRecord(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                isFavorite: asset.isFavorite,
                isScreenshot: false,
                burstIdentifier: asset.burstIdentifier,
                cat: .none,
                analysisStatus: .unavailableLocally,
                analysisFingerprint: settings.analysisFingerprint
            ).preservingUserState(from: previous)
        }

        do {
            let request = VNRecognizeAnimalsRequest()
#if targetEnvironment(simulator)
            // GitHub-hosted Intel simulators do not provide an iPhone GPU/ANE.
            // Keep the smoke test deterministic without changing real-device
            // scheduling or memory behavior.
            request.usesCPUOnly = true
#endif
            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: CGImagePropertyOrientation(image.imageOrientation),
                options: [:]
            )
            try handler.perform([request])

            let observations = request.results ?? []
            let cats: [(VNRecognizedObjectObservation, Float)] = observations.compactMap { observation in
                guard let label = observation.labels
                    .filter({ $0.identifier.caseInsensitiveCompare("cat") == .orderedSame })
                    .max(by: { $0.confidence < $1.confidence }),
                      label.confidence >= settings.confidenceThreshold else {
                    return nil
                }
                return (observation, label.confidence)
            }

            let union = cats
                .map { $0.0.boundingBox }
                .reduce(CGRect.null) { $0.union($1) }
            let catAreaRatio = min(
                1,
                cats.reduce(0) {
                    $0 + Double($1.0.boundingBox.width * $1.0.boundingBox.height)
                }
            )
            guard !cats.isEmpty,
                  !union.isNull,
                  catAreaRatio >= settings.minimumCatAreaRatio else {
                return AssetRecord(
                    localIdentifier: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    isFavorite: asset.isFavorite,
                    isScreenshot: false,
                    burstIdentifier: asset.burstIdentifier,
                    cat: .none,
                    analysisStatus: .noCat,
                    analysisFingerprint: settings.analysisFingerprint
                ).preservingUserState(from: previous)
            }

            let confidence = cats.map { $0.1 }.max() ?? 0
            let detection = CatDetection(
                detected: true,
                confidence: confidence,
                boundingBox: NormalizedRect(union),
                areaRatio: catAreaRatio,
                catCount: cats.count
            )
            return AssetRecord(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                isFavorite: asset.isFavorite,
                isScreenshot: false,
                burstIdentifier: asset.burstIdentifier,
                cat: detection,
                analysisStatus: .detected,
                analysisFingerprint: settings.analysisFingerprint
            ).preservingUserState(from: previous)
        } catch {
            let value = error as NSError
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
                isFavorite: asset.isFavorite,
                isScreenshot: false,
                burstIdentifier: asset.burstIdentifier,
                cat: .none,
                analysisStatus: .failed,
                analysisFingerprint: settings.analysisFingerprint
            ).preservingUserState(from: previous)
        }
    }

    private static func localThumbnail(for asset: PHAsset) -> UIImage? {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = true

        var output: UIImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 1_024, height: 1_024),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let error = info?[PHImageErrorKey] as? Error
            if !cancelled, error == nil { output = image }
        }
        return output
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
            isFavorite: asset.isFavorite,
            isScreenshot: status == .excludedScreenshot,
            burstIdentifier: asset.burstIdentifier,
            cat: .none,
            analysisStatus: status,
            analysisFingerprint: analysisFingerprint
        ).preservingUserState(from: previous)
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
