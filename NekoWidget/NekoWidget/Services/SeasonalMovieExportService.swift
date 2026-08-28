@preconcurrency import AVFoundation
@preconcurrency import Photos
@preconcurrency import UIKit
import CoreImage
import Foundation

enum SeasonalMovieExportError: LocalizedError, Equatable, Sendable {
    case emptyPresentation
    case assetMissing
    case mediaNotAvailableOffline
    case cannotCreateOutput
    case encodingFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyPresentation:
            return "書き出す場面がありません。"
        case .assetMissing:
            return "使われている写真が見つかりませんでした。"
        case .mediaNotAvailableOffline:
            return "このiPhoneにない写真または動画があります。ダウンロード後にもう一度お試しください。"
        case .cannotCreateOutput:
            return "動画の書き出しを始められませんでした。"
        case .encodingFailed:
            return "動画を書き出せませんでした。"
        case .cancelled:
            return "動画の書き出しを中止しました。"
        }
    }
}

/// Creates an explicit, device-only MP4 for the share sheet.
///
/// No export is created until `export` is called. Source metadata, source file
/// names, and source audio are never copied: every frame is rendered into a
/// new portrait H.264 stream. When sound is enabled, only the app-owned
/// soundtrack is encoded; source-photo and source-video audio is never copied.
actor SeasonalMovieExportService {
    static let shared = SeasonalMovieExportService()

    private static let exportDirectoryName = "SeasonalMovieExports"
    private static let outputFileName = "seasonal-movie.mp4"
    private static let staleExportLifetime: TimeInterval = 24 * 60 * 60
    private static let frameRate: Int32 = 24
    private static let frameTimescale: Int32 = 600
    private static let outputSize = CGSize(width: 720, height: 1_280)
    private static let monthMarkerDuration: TimeInterval = 0.8
    private static let requestTimeoutNanoseconds: UInt64 = 8_000_000_000

    private enum FrameOverlay {
        case opening(title: String, period: String)
        case month(String)
        case ending
    }

    private struct AudioPipeline {
        let reader: AVAssetReader
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
    }

    private let fileManager: FileManager
    private let imageManager: PHImageManager
    private let ciContext = CIContext(options: [
        .cacheIntermediates: false
    ])

    init(
        fileManager: FileManager = .default,
        imageManager: PHImageManager = .default()
    ) {
        self.fileManager = fileManager
        self.imageManager = imageManager
        try? Self.cleanupStaleExports(
            fileManager: fileManager,
            olderThan: Self.staleExportLifetime
        )
    }

    /// Returns a temporary URL suitable for `UIActivityViewController`.
    /// The caller owns its lifetime and must call `cleanupExport(at:)` after
    /// the share sheet completes or is cancelled.
    func export(
        _ presentation: SeasonalMoviePresentation,
        soundEnabled: Bool
    ) async throws -> URL {
        guard !presentation.scenes.isEmpty else {
            throw SeasonalMovieExportError.emptyPresentation
        }

        try Task.checkCancellation()
        let outputURL = try makeOutputURL()
        do {
            let soundtrackURL = try soundtrackURL(
                beside: outputURL,
                enabled: soundEnabled
            )
            defer {
                if let soundtrackURL {
                    try? fileManager.removeItem(at: soundtrackURL)
                }
            }
            let assets = try fetchedAssets(for: presentation)
            try await encode(
                presentation: presentation,
                assets: assets,
                outputURL: outputURL,
                soundtrackURL: soundtrackURL
            )
            try protectOutput(at: outputURL)
            return outputURL
        } catch is CancellationError {
            Self.cleanupExport(at: outputURL, fileManager: fileManager)
            throw SeasonalMovieExportError.cancelled
        } catch {
            Self.cleanupExport(at: outputURL, fileManager: fileManager)
            if Task.isCancelled {
                throw SeasonalMovieExportError.cancelled
            }
            throw error
        }
    }

    /// Removes one completed or partial export, including its UUID directory.
    func cleanupExport(at outputURL: URL) {
        Self.cleanupExport(at: outputURL, fileManager: fileManager)
    }

    /// Deletes abandoned export directories. This also runs when the service
    /// is initialized, covering app relaunch after an interrupted share sheet.
    func cleanupStaleExports(
        olderThan age: TimeInterval = SeasonalMovieExportService.staleExportLifetime
    ) throws {
        try Self.cleanupStaleExports(
            fileManager: fileManager,
            olderThan: age
        )
    }

    private func fetchedAssets(
        for presentation: SeasonalMoviePresentation
    ) throws -> [String: PHAsset] {
        let identifiers = presentation.scenes.map(\.localIdentifier)
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: identifiers,
            options: nil
        )
        var assets: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            assets[asset.localIdentifier] = asset
        }
        guard identifiers.allSatisfy({ assets[$0] != nil }) else {
            throw SeasonalMovieExportError.assetMissing
        }
        return assets
    }

    private func encode(
        presentation: SeasonalMoviePresentation,
        assets: [String: PHAsset],
        outputURL: URL,
        soundtrackURL: URL?
    ) async throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw SeasonalMovieExportError.cannotCreateOutput
        }

        // A newly encoded video-only stream prevents EXIF, locations, source
        // file names, and source audio from crossing the export boundary.
        writer.metadata = []
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: 4_000_000,
            AVVideoExpectedSourceFrameRateKey: Int(Self.frameRate),
            AVVideoMaxKeyFrameIntervalKey: Int(Self.frameRate) * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(Self.outputSize.width),
            AVVideoHeightKey: Int(Self.outputSize.height),
            AVVideoCompressionPropertiesKey: compression
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw SeasonalMovieExportError.cannotCreateOutput
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw SeasonalMovieExportError.cannotCreateOutput
        }
        writer.add(input)

        let totalFrameCount = exportFrameCount(for: presentation)
        let audioPipeline = try await makeAudioPipeline(
            soundtrackURL: soundtrackURL,
            duration: Double(totalFrameCount) / Double(Self.frameRate),
            writer: writer
        )

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(Self.outputSize.width),
            kCVPixelBufferHeightKey as String: Int(Self.outputSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.startWriting() else {
            throw SeasonalMovieExportError.encodingFailed
        }
        writer.startSession(atSourceTime: .zero)

        do {
            async let audioWriting: Void = appendAudio(
                audioPipeline,
                writer: writer
            )
            var outputFrame: Int64 = 0
            var finalFrameImage: CIImage?
            for index in presentation.scenes.indices {
                try Task.checkCancellation()
                let scene = presentation.scenes[index]
                guard let asset = assets[scene.localIdentifier] else {
                    throw SeasonalMovieExportError.assetMissing
                }
                let sceneDuration = presentation.playbackDuration(at: index)
                let frameCount = max(
                    1,
                    Int((sceneDuration * Double(Self.frameRate)).rounded())
                )
                let overlay = overlay(
                    forSceneAt: index,
                    in: presentation
                )
                let overlayImage = overlay.map(makeOverlayImage)
                let overlayVisibleFrameCount: Int = overlay.map { value in
                    switch value {
                    case .month:
                        return min(
                            frameCount,
                            Int(self.frameCount(for: Self.monthMarkerDuration))
                        )
                    case .opening, .ending:
                        return frameCount
                    }
                } ?? 0

                switch scene.mediaKind {
                case .stillPhoto, .livePhoto:
                    guard asset.mediaType == .image,
                          let image = await localImage(for: asset),
                          let frameImage = normalizedCIImage(from: image) else {
                        throw SeasonalMovieExportError.mediaNotAvailableOffline
                    }
                    finalFrameImage = frameImage
                    for localFrame in 0..<frameCount {
                        try await append(
                            frameImage,
                            overlay: localFrame < overlayVisibleFrameCount
                                ? overlayImage
                                : nil,
                            at: outputFrame,
                            writer: writer,
                            input: input,
                            adaptor: adaptor
                        )
                        outputFrame += 1
                    }

                case .video:
                    guard asset.mediaType == .video,
                          let avAsset = await SeasonalMovieLocalMediaLoader.avAsset(for: asset) else {
                        throw SeasonalMovieExportError.mediaNotAvailableOffline
                    }
                    let duration: CMTime
                    do {
                        duration = try await avAsset.load(.duration)
                    } catch {
                        throw SeasonalMovieExportError.mediaNotAvailableOffline
                    }
                    let durationSeconds = CMTimeGetSeconds(duration)
                    guard durationSeconds.isFinite, durationSeconds > 0 else {
                        throw SeasonalMovieExportError.mediaNotAvailableOffline
                    }

                    let start = min(
                        max(0, scene.suggestedStartTime ?? 0),
                        max(0, durationSeconds - 0.05)
                    )
                    let availableDuration = max(0.05, durationSeconds - start)
                    let generator = AVAssetImageGenerator(asset: avAsset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = Self.outputSize
                    generator.requestedTimeToleranceBefore = CMTime(
                        seconds: 0.10,
                        preferredTimescale: Self.frameTimescale
                    )
                    generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore

                    for localFrame in 0..<frameCount {
                        try Task.checkCancellation()
                        let sourceOffset = min(
                            Double(localFrame) / Double(Self.frameRate),
                            max(0, availableDuration - 0.01)
                        )
                        let sourceTime = CMTime(
                            seconds: start + sourceOffset,
                            preferredTimescale: Self.frameTimescale
                        )
                        let generated: CGImage
                        do {
                            generated = try await generator.image(at: sourceTime).image
                        } catch {
                            throw SeasonalMovieExportError.mediaNotAvailableOffline
                        }
                        let generatedImage = CIImage(cgImage: generated)
                        finalFrameImage = generatedImage
                        try await append(
                            generatedImage,
                            overlay: localFrame < overlayVisibleFrameCount
                                ? overlayImage
                                : nil,
                            at: outputFrame,
                            writer: writer,
                            input: input,
                            adaptor: adaptor
                        )
                        outputFrame += 1
                    }
                }
            }

            guard let finalFrameImage else {
                throw SeasonalMovieExportError.encodingFailed
            }
            let endingFrameCount = frameCount(
                for: SeasonalMovieSoundtrackContract.endingDuration
            )
            let endingOverlay = makeOverlayImage(.ending)
            for _ in 0..<endingFrameCount {
                try await append(
                    finalFrameImage,
                    overlay: endingOverlay,
                    at: outputFrame,
                    writer: writer,
                    input: input,
                    adaptor: adaptor
                )
                outputFrame += 1
            }

            let endTime = CMTime(
                value: outputFrame * Int64(Self.frameTimescale / Self.frameRate),
                timescale: Self.frameTimescale
            )
            input.markAsFinished()
            try await audioWriting
            writer.endSession(atSourceTime: endTime)
            try await finish(writer)
        } catch {
            audioPipeline?.reader.cancelReading()
            input.markAsFinished()
            writer.cancelWriting()
            throw error
        }
    }

    private func makeAudioPipeline(
        soundtrackURL: URL?,
        duration: TimeInterval,
        writer: AVAssetWriter
    ) async throws -> AudioPipeline? {
        guard let soundtrackURL else { return nil }
        let sourceAsset = AVURLAsset(url: soundtrackURL)
        let sourceTracks: [AVAssetTrack]
        let sourceDuration: CMTime
        do {
            sourceTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
            sourceDuration = try await sourceAsset.load(.duration)
        } catch {
            return nil
        }
        guard let sourceTrack = sourceTracks.first,
              sourceDuration.isNumeric,
              sourceDuration > .zero else { return nil }
        let requestedDuration = CMTime(
            seconds: max(0, duration),
            preferredTimescale: Self.frameTimescale
        )
        guard requestedDuration.isNumeric, requestedDuration > .zero else {
            return nil
        }

        // The bundled soundtrack is repeated only when the rendered timeline
        // is longer than the source WAV, then trimmed and faded at the exact
        // video end. Source photo/video audio is never introduced.
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        var cursor = CMTime.zero
        do {
            while cursor < requestedDuration {
                let remaining = CMTimeSubtract(requestedDuration, cursor)
                let chunk = CMTimeMinimum(sourceDuration, remaining)
                try track.insertTimeRange(
                    CMTimeRange(start: .zero, duration: chunk),
                    of: sourceTrack,
                    at: cursor
                )
                cursor = CMTimeAdd(cursor, chunk)
            }
        } catch {
            return nil
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: composition)
        } catch {
            return nil
        }
        reader.timeRange = CMTimeRange(start: .zero, duration: requestedDuration)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: [track],
            audioSettings: outputSettings
        )
        let requestedDurationSeconds = CMTimeGetSeconds(requestedDuration)
        let fadeInDuration = min(
            SeasonalMovieSoundtrackContract.fadeInDuration,
            requestedDurationSeconds
        )
        let fadeOutDuration = min(
            SeasonalMovieSoundtrackContract.fadeOutDuration,
            requestedDurationSeconds
        )
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(0, at: .zero)
        parameters.setVolumeRamp(
            fromStartVolume: 0,
            toEndVolume: SeasonalMovieSoundtrackContract.volume,
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(
                    seconds: fadeInDuration,
                    preferredTimescale: Self.frameTimescale
                )
            )
        )
        parameters.setVolumeRamp(
            fromStartVolume: SeasonalMovieSoundtrackContract.volume,
            toEndVolume: 0,
            timeRange: CMTimeRange(
                start: CMTimeSubtract(
                    requestedDuration,
                    CMTime(
                        seconds: fadeOutDuration,
                        preferredTimescale: Self.frameTimescale
                    )
                ),
                duration: CMTime(
                    seconds: fadeOutDuration,
                    preferredTimescale: Self.frameTimescale
                )
            )
        )
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [parameters]
        output.audioMix = audioMix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)

        let inputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: SeasonalMovieSoundtrackContract.sampleRate,
            AVNumberOfChannelsKey: SeasonalMovieSoundtrackContract.channelCount,
            AVEncoderBitRateKey: SeasonalMovieSoundtrackContract.encoderBitRate
        ]
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: inputSettings
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        return AudioPipeline(reader: reader, output: output, input: input)
    }

    private func appendAudio(
        _ pipeline: AudioPipeline?,
        writer: AVAssetWriter
    ) async throws {
        guard let pipeline else { return }
        guard pipeline.reader.startReading() else {
            throw SeasonalMovieExportError.encodingFailed
        }
        while let sampleBuffer = pipeline.output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            while !pipeline.input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else {
                    throw SeasonalMovieExportError.encodingFailed
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard pipeline.input.append(sampleBuffer) else {
                throw SeasonalMovieExportError.encodingFailed
            }
        }
        guard pipeline.reader.status == .completed else {
            throw SeasonalMovieExportError.encodingFailed
        }
        pipeline.input.markAsFinished()
    }

    private func append(
        _ sourceImage: CIImage,
        overlay: CIImage?,
        at frame: Int64,
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw SeasonalMovieExportError.encodingFailed
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try Task.checkCancellation()
        guard writer.status == .writing,
              let pool = adaptor.pixelBufferPool else {
            throw SeasonalMovieExportError.encodingFailed
        }

        var optionalBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            nil,
            pool,
            &optionalBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer = optionalBuffer else {
            throw SeasonalMovieExportError.cannotCreateOutput
        }

        let outputRect = CGRect(origin: .zero, size: Self.outputSize)
        let sourceExtent = sourceImage.extent
        guard sourceExtent.width > 0, sourceExtent.height > 0 else {
            throw SeasonalMovieExportError.mediaNotAvailableOffline
        }
        let scale = min(
            outputRect.width / sourceExtent.width,
            outputRect.height / sourceExtent.height
        )
        let scaled = sourceImage.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let translated = scaled.transformed(by: CGAffineTransform(
            translationX: outputRect.midX - scaled.extent.midX,
            y: outputRect.midY - scaled.extent.midY
        ))
        let background = CIImage(color: .black).cropped(to: outputRect)
        var frameImage = translated
            .cropped(to: outputRect)
            .composited(over: background)
        if let overlay {
            frameImage = overlay.composited(over: frameImage)
        }
        ciContext.render(
            frameImage,
            to: pixelBuffer,
            bounds: outputRect,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let presentationTime = CMTime(
            value: frame * Int64(Self.frameTimescale / Self.frameRate),
            timescale: Self.frameTimescale
        )
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw SeasonalMovieExportError.encodingFailed
        }
    }

    private func localImage(for asset: PHAsset) async -> UIImage? {
        let request = SeasonalMovieExportImageRequest(
            manager: imageManager,
            timeoutNanoseconds: Self.requestTimeoutNanoseconds,
            asset: asset,
            targetSize: Self.outputSize
        )
        return await withTaskCancellationHandler {
            await request.value()
        } onCancel: {
            request.cancel()
        }
    }

    private func normalizedCIImage(from image: UIImage) -> CIImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let normalized = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let cgImage = normalized.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private func frameCount(for duration: TimeInterval) -> Int64 {
        max(1, Int64((duration * Double(Self.frameRate)).rounded()))
    }

    private func exportFrameCount(
        for presentation: SeasonalMoviePresentation
    ) -> Int64 {
        presentation.scenes.indices.reduce(Int64.zero) { total, index in
            total + frameCount(for: presentation.playbackDuration(at: index))
        } + frameCount(for: SeasonalMovieSoundtrackContract.endingDuration)
    }

    private func overlay(
        forSceneAt index: Int,
        in presentation: SeasonalMoviePresentation
    ) -> FrameOverlay? {
        guard presentation.scenes.indices.contains(index) else { return nil }
        if index == 0 {
            return .opening(
                title: presentation.title,
                period: presentation.periodTitle
            )
        }
        let calendar = Calendar.current
        let previous = presentation.scenes[index - 1].creationDate
        let current = presentation.scenes[index].creationDate
        guard !calendar.isDate(
            previous,
            equalTo: current,
            toGranularity: .month
        ) else { return nil }
        return .month(
            current.formatted(
                .dateTime.month(.wide).locale(Locale(identifier: "ja_JP"))
            )
        )
    }

    private func makeOverlayImage(_ overlay: FrameOverlay) -> CIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: Self.outputSize,
            format: format
        )
        let image = renderer.image { context in
            switch overlay {
            case let .opening(title, period):
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .left
                let titleAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 42, weight: .bold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph
                ]
                let periodAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 25, weight: .regular),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.82),
                    .paragraphStyle: paragraph
                ]
                let originX: CGFloat = 40
                let titleY = Self.outputSize.height - 260
                (title as NSString).draw(
                    in: CGRect(x: originX, y: titleY, width: 640, height: 58),
                    withAttributes: titleAttributes
                )
                (period as NSString).draw(
                    in: CGRect(x: originX, y: titleY + 62, width: 640, height: 40),
                    withAttributes: periodAttributes
                )

            case let .month(text):
                let shadow = NSShadow()
                shadow.shadowColor = UIColor.black.withAlphaComponent(0.72)
                shadow.shadowBlurRadius = 4
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.82),
                    .shadow: shadow
                ]
                (text as NSString).draw(
                    at: CGPoint(x: 40, y: Self.outputSize.height - 152),
                    withAttributes: attributes
                )

            case .ending:
                UIColor.black.withAlphaComponent(0.62).setFill()
                context.fill(CGRect(origin: .zero, size: Self.outputSize))
                let text = "この季節も、ここまで" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 38, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                let textSize = text.size(withAttributes: attributes)
                text.draw(
                    at: CGPoint(
                        x: (Self.outputSize.width - textSize.width) / 2,
                        y: (Self.outputSize.height - textSize.height) / 2
                    ),
                    withAttributes: attributes
                )
            }
        }
        guard let cgImage = image.cgImage else {
            return CIImage(color: .clear).cropped(
                to: CGRect(origin: .zero, size: Self.outputSize)
            )
        }
        return CIImage(cgImage: cgImage)
    }

    private func finish(_ writer: AVAssetWriter) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: SeasonalMovieExportError.encodingFailed
                        )
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            writer.cancelWriting()
        }
    }

    private func makeOutputURL() throws -> URL {
        let root = Self.exportRoot(fileManager: fileManager)
        let directory = root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(values)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw SeasonalMovieExportError.cannotCreateOutput
        }
        return directory.appendingPathComponent(Self.outputFileName)
    }

    private func soundtrackURL(
        beside outputURL: URL,
        enabled: Bool
    ) throws -> URL? {
        guard enabled,
              let data = NSDataAsset(name: "SeasonalMovieAmbient")?.data else {
            return nil
        }
        let url = outputURL.deletingLastPathComponent().appendingPathComponent(
            "soundtrack.wav",
            isDirectory: false
        )
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
            return url
        } catch {
            throw SeasonalMovieExportError.cannotCreateOutput
        }
    }

    private func protectOutput(at outputURL: URL) throws {
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw SeasonalMovieExportError.encodingFailed
        }
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: outputURL.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = outputURL
        try mutableURL.setResourceValues(values)
    }

    private static func exportRoot(fileManager: FileManager) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(exportDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    private static func cleanupExport(
        at outputURL: URL,
        fileManager: FileManager
    ) {
        let root = exportRoot(fileManager: fileManager)
        let candidate = outputURL.standardizedFileURL
        let directory = candidate.deletingLastPathComponent()
        guard candidate.lastPathComponent == outputFileName,
              directory.deletingLastPathComponent() == root,
              UUID(uuidString: directory.lastPathComponent) != nil else {
            return
        }
        try? fileManager.removeItem(at: directory)
    }

    /// App launch may call this static form before any export UI is opened.
    static func cleanupStaleExports(
        fileManager: FileManager = .default,
        olderThan age: TimeInterval = 24 * 60 * 60
    ) throws {
        let root = exportRoot(fileManager: fileManager)
        guard fileManager.fileExists(atPath: root.path) else { return }
        let expiration = Date().addingTimeInterval(-max(0, age))
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .contentModificationDateKey,
                .creationDateKey
            ],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let candidate = child.standardizedFileURL
            guard candidate.deletingLastPathComponent() == root,
                  UUID(uuidString: candidate.lastPathComponent) != nil else {
                continue
            }
            let values = try candidate.resourceValues(forKeys: [
                .isDirectoryKey,
                .contentModificationDateKey,
                .creationDateKey
            ])
            guard values.isDirectory == true else { continue }
            let date = values.contentModificationDate
                ?? values.creationDate
                ?? .distantPast
            if date <= expiration {
                try? fileManager.removeItem(at: candidate)
            }
        }
    }
}

/// PhotoKit callback guard used only by explicit export. Network access stays
/// disabled, and cancellation/timeout both cancel the underlying request.
private final class SeasonalMovieExportImageRequest: @unchecked Sendable {
    private let manager: PHImageManager
    private let timeoutNanoseconds: UInt64
    private let asset: PHAsset
    private let targetSize: CGSize
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestID: PHImageRequestID?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    init(
        manager: PHImageManager,
        timeoutNanoseconds: UInt64,
        asset: PHAsset,
        targetSize: CGSize
    ) {
        self.manager = manager
        self.timeoutNanoseconds = timeoutNanoseconds
        self.asset = asset
        self.targetSize = targetSize
    }

    func value() async -> UIImage? {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            self.continuation = continuation
            lock.unlock()

            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.version = .current
            options.isNetworkAccessAllowed = false
            let identifier = manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { [weak self] image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                guard !isDegraded else { return }
                let wasCancelled = (info?[PHImageCancelledKey] as? Bool) == true
                let error = info?[PHImageErrorKey] as? Error
                self?.finish(wasCancelled || error != nil ? nil : image)
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
                self.finish(nil)
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
        finish(nil)
    }

    private func finish(_ image: UIImage?) {
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
        if let identifier {
            manager.cancelImageRequest(identifier)
        }
        continuation?.resume(returning: image)
    }
}
