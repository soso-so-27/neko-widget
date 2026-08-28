@preconcurrency import AVFoundation
@preconcurrency import Photos
@preconcurrency import Vision
import CoreGraphics
import Foundation

/// A one-shot, cancellable PhotoKit bridge. PhotoKit callbacks are normally
/// reliable, but malformed or partially imported assets must not be able to
/// keep automatic preparation or playback waiting forever.
private final class SeasonalMoviePhotoKitRequest<Value>: @unchecked Sendable {
    typealias Start = (@escaping (Value?) -> Void) -> PHImageRequestID

    private let manager: PHImageManager
    private let timeoutNanoseconds: UInt64
    private let start: Start
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var requestID: PHImageRequestID?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    init(
        manager: PHImageManager,
        timeoutNanoseconds: UInt64,
        start: @escaping Start
    ) {
        self.manager = manager
        self.timeoutNanoseconds = timeoutNanoseconds
        self.start = start
    }

    func value() async -> Value? {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            self.continuation = continuation
            lock.unlock()

            let identifier = start { [weak self] value in
                self?.finish(value, cancelPhotoKitRequest: false)
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
                self.finish(nil, cancelPhotoKitRequest: true)
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
        finish(nil, cancelPhotoKitRequest: true)
    }

    private func finish(
        _ value: Value?,
        cancelPhotoKitRequest: Bool
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
        if cancelPhotoKitRequest, let identifier {
            manager.cancelImageRequest(identifier)
        }
        continuation?.resume(returning: value)
    }
}

enum SeasonalMovieLocalMediaLoader {
    private static let requestTimeoutNanoseconds: UInt64 = 5_000_000_000

    static func avAsset(for asset: PHAsset) async -> AVAsset? {
        let manager = PHImageManager.default()
        let options = PHVideoRequestOptions()
        options.deliveryMode = .mediumQualityFormat
        options.version = .current
        options.isNetworkAccessAllowed = false
        let request = SeasonalMoviePhotoKitRequest<AVAsset>(
            manager: manager,
            timeoutNanoseconds: requestTimeoutNanoseconds
        ) { completion in
            manager.requestAVAsset(
                forVideo: asset,
                options: options
            ) { avAsset, _, _ in
                completion(avAsset)
            }
        }
        return await withTaskCancellationHandler {
            await request.value()
        } onCancel: {
            request.cancel()
        }
    }

    static func livePhoto(
        for asset: PHAsset,
        targetSize: CGSize
    ) async -> PHLivePhoto? {
        let manager = PHImageManager.default()
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.isNetworkAccessAllowed = false
        let request = SeasonalMoviePhotoKitRequest<PHLivePhoto>(
            manager: manager,
            timeoutNanoseconds: requestTimeoutNanoseconds
        ) { completion in
            manager.requestLivePhoto(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { livePhoto, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                guard !isDegraded else { return }
                let wasCancelled = (info?[PHImageCancelledKey] as? Bool) == true
                let error = info?[PHImageErrorKey] as? Error
                completion(wasCancelled || error != nil ? nil : livePhoto)
            }
        }
        return await withTaskCancellationHandler {
            await request.value()
        } onCancel: {
            request.cancel()
        }
    }
}

/// Finds motion-capable seasonal candidates without uploading or persisting
/// media. Existing cat-photo results are reused for stills and Live Photos;
/// ordinary videos receive a narrow, on-device Vision check on three frames.
actor SeasonalMovieCandidateService {
    private struct VideoCatFrame {
        let seconds: TimeInterval
        let boundingBox: CGRect
        let largestAreaRatio: Double
        let confidence: Float
    }

    private static let videoSampleFractions = [0.20, 0.50, 0.80]
    private static let minimumVideoDuration: TimeInterval = 1.0
    /// Three frame checks per item keep the automatic preparation bounded to
    /// at most 108 Vision requests for a quarter. Sampling is spread through
    /// each month instead of taking only its newest videos.
    private static let maximumVideosPerMonth = 12
    private static let requiredCatFrames = 2
    private static let catConfidenceThreshold: Float = 0.70
    private static let excerptDuration: TimeInterval = 2.1

    /// Returns locally available media candidates. Network access is disabled
    /// for both Live Photo and video checks, so running this service cannot
    /// silently download motion media from iCloud.
    func candidates(
        knownCatPhotos: [PhotoPresentation],
        in quarter: DateInterval,
        sourceAlbumIdentifier: String?
    ) async -> [SeasonalMovieCandidate] {
        var result = await photoCandidates(
            knownCatPhotos,
            in: quarter
        )
        result.append(contentsOf: await videoCandidates(
            in: quarter,
            sourceAlbumIdentifier: sourceAlbumIdentifier
        ))
        return result.sorted {
            if $0.creationDate != $1.creationDate {
                return $0.creationDate < $1.creationDate
            }
            return $0.localIdentifier < $1.localIdentifier
        }
    }

    /// Cheap first stage used to make a photo/Live Photo season available
    /// before the bounded video Vision pass completes.
    func photoCandidates(
        _ photos: [PhotoPresentation],
        in quarter: DateInterval
    ) async -> [SeasonalMovieCandidate] {
        let eligible = photos.filter {
            guard let date = $0.creationDate else { return false }
            return date >= quarter.start && date < quarter.end
        }
        var byIdentifier: [String: PhotoPresentation] = [:]
        for photo in eligible {
            guard let current = byIdentifier[photo.localIdentifier] else {
                byIdentifier[photo.localIdentifier] = photo
                continue
            }
            if photo.isLiked && !current.isLiked {
                byIdentifier[photo.localIdentifier] = photo
            }
        }
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: Array(byIdentifier.keys),
            options: nil
        )

        var result: [SeasonalMovieCandidate] = []
        for index in 0..<assets.count {
            guard !Task.isCancelled else { return result }
            let asset = assets.object(at: index)
            guard asset.mediaType == .image,
                  let photo = byIdentifier[asset.localIdentifier],
                  let creationDate = photo.creationDate else { continue }

            let isLivePhoto: Bool
            if asset.mediaSubtypes.contains(.photoLive) {
                isLivePhoto = await isLivePhotoLocallyAvailable(asset)
            } else {
                isLivePhoto = false
            }
            result.append(SeasonalMovieCandidate(
                localIdentifier: photo.localIdentifier,
                creationDate: creationDate,
                mediaKind: isLivePhoto ? .livePhoto : .stillPhoto,
                catBoundingBox: photo.catBoundingBox,
                largestCatAreaRatio: photo.largestCatAreaRatio,
                isMemory: photo.isLiked,
                suggestedStartTime: nil,
                suggestedDuration: nil
            ))
        }
        return result
    }

    /// Bounded second stage. The caller may publish a valid photo-only plan
    /// first, then replace it with this richer plan when preparation finishes.
    func videoCandidates(
        in quarter: DateInterval,
        sourceAlbumIdentifier: String?
    ) async -> [SeasonalMovieCandidate] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@ AND mediaType == %d",
            quarter.start as NSDate,
            quarter.end as NSDate,
            PHAssetMediaType.video.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(
            key: "creationDate",
            ascending: false
        )]
        let assets: PHFetchResult<PHAsset>
        if let sourceAlbumIdentifier {
            guard let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [sourceAlbumIdentifier],
                options: nil
            ).firstObject,
                  collection.assetCollectionType == .album else {
                return []
            }
            assets = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            assets = PHAsset.fetchAssets(with: .video, options: options)
        }

        // Bound on-device Vision work without allowing a busy recent month to
        // crowd the beginning of the quarter out of consideration.
        var assetsByMonth: [Int: [PHAsset]] = [:]
        let calendar = Calendar(identifier: .gregorian)
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            guard asset.mediaType == .video,
                  let date = asset.creationDate else { continue }
            let components = calendar.dateComponents([.year, .month], from: date)
            let monthKey = (components.year ?? 0) * 100 + (components.month ?? 0)
            assetsByMonth[monthKey, default: []].append(asset)
        }
        var selectedAssets: [PHAsset] = []
        for monthKey in assetsByMonth.keys.sorted() {
            guard let monthlyAssets = assetsByMonth[monthKey] else { continue }
            selectedAssets.append(contentsOf: evenlySpacedAssets(
                monthlyAssets.sorted {
                    ($0.creationDate ?? .distantPast)
                        < ($1.creationDate ?? .distantPast)
                },
                limit: Self.maximumVideosPerMonth
            ))
        }

        var result: [SeasonalMovieCandidate] = []
        for asset in selectedAssets {
            guard !Task.isCancelled else { return result }
            guard let candidate = await videoCandidate(for: asset) else {
                continue
            }
            result.append(candidate)
        }
        return result
    }

    private func evenlySpacedAssets(
        _ assets: [PHAsset],
        limit: Int
    ) -> [PHAsset] {
        guard assets.count > limit, limit > 1 else {
            return Array(assets.prefix(max(0, limit)))
        }
        return (0..<limit).map { position in
            let fraction = Double(position) / Double(limit - 1)
            let index = Int((fraction * Double(assets.count - 1)).rounded())
            return assets[index]
        }
    }

    private func videoCandidate(
        for photoAsset: PHAsset
    ) async -> SeasonalMovieCandidate? {
        guard let creationDate = photoAsset.creationDate,
              let avAsset = await localAVAsset(for: photoAsset) else {
            return nil
        }

        let duration: CMTime
        do {
            duration = try await avAsset.load(.duration)
        } catch {
            return nil
        }
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite,
              durationSeconds >= Self.minimumVideoDuration else { return nil }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_024, height: 1_024)
        generator.requestedTimeToleranceBefore = CMTime(
            seconds: 0.25,
            preferredTimescale: 600
        )
        generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore

        var catFrames: [VideoCatFrame] = []
        for fraction in Self.videoSampleFractions {
            guard !Task.isCancelled else { return nil }
            let seconds = min(
                max(0, durationSeconds * fraction),
                max(0, durationSeconds - 0.05)
            )
            let requestedTime = CMTime(seconds: seconds, preferredTimescale: 600)
            do {
                let frame = try await generator.image(at: requestedTime)
                if let detection = try catFrame(
                    from: frame.image,
                    seconds: seconds
                ) {
                    catFrames.append(detection)
                }
            } catch {
                continue
            }
        }

        guard catFrames.count >= Self.requiredCatFrames,
              let representative = catFrames.max(by: {
                  if $0.confidence != $1.confidence {
                      return $0.confidence < $1.confidence
                  }
                  return $0.largestAreaRatio < $1.largestAreaRatio
              }) else { return nil }

        let start = min(
            max(0, representative.seconds - Self.excerptDuration / 2),
            max(0, durationSeconds - Self.excerptDuration)
        )
        return SeasonalMovieCandidate(
            localIdentifier: photoAsset.localIdentifier,
            creationDate: creationDate,
            mediaKind: .video,
            catBoundingBox: representative.boundingBox,
            largestCatAreaRatio: representative.largestAreaRatio,
            isMemory: photoAsset.isFavorite,
            suggestedStartTime: start,
            suggestedDuration: min(Self.excerptDuration, durationSeconds - start)
        )
    }

    private func catFrame(
        from image: CGImage,
        seconds: TimeInterval
    ) throws -> VideoCatFrame? {
        let request = VNRecognizeAnimalsRequest()
#if targetEnvironment(simulator)
        request.usesCPUOnly = true
#endif
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let recognized = (request.results ?? []).compactMap { observation -> (CGRect, Float)? in
            guard let label = observation.labels
                .filter({ $0.identifier.caseInsensitiveCompare("cat") == .orderedSame })
                .max(by: { $0.confidence < $1.confidence }),
                  label.confidence >= Self.catConfidenceThreshold else {
                return nil
            }
            return (observation.boundingBox, label.confidence)
        }
        guard !recognized.isEmpty else { return nil }
        let union = recognized.reduce(CGRect.null) { $0.union($1.0) }
        let largestArea = recognized.map {
            Double($0.0.width * $0.0.height)
        }.max() ?? 0
        return VideoCatFrame(
            seconds: seconds,
            boundingBox: union,
            largestAreaRatio: largestArea,
            confidence: recognized.map(\.1).max() ?? 0
        )
    }

    private func localAVAsset(for asset: PHAsset) async -> AVAsset? {
        await SeasonalMovieLocalMediaLoader.avAsset(for: asset)
    }

    private func isLivePhotoLocallyAvailable(_ asset: PHAsset) async -> Bool {
        await SeasonalMovieLocalMediaLoader.livePhoto(
            for: asset,
            targetSize: CGSize(width: 320, height: 320)
        ) != nil
    }
}
