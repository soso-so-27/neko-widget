import CoreGraphics
import CoreImage
import CryptoKit
import ImageIO
@preconcurrency import Photos
import UIKit
import UniformTypeIdentifiers

struct CanonicalPreviewRequest: Sendable {
    let localIdentifier: String
    let sourceModificationDate: Date?
    let sourcePixelSize: WidgetSourcePixelSize
    let renderPlans: WidgetRenderPlans
}

struct CanonicalPreview: Sendable {
    let jpeg: Data
    let binding: SharingMediaBinding
    let plaintextSHA256: Data
}

/// The personal cache and shared-canonical paths must agree on UIImage scale
/// and orientation before planning crops. `normalizedUIImage` intentionally
/// preserves the shipping UIGraphics scale-1 implementation byte-for-visual
/// compatibility. The host-only canonical path then converts that exact
/// logical image into sRGB; the Widget never links or calls this builder.
enum WidgetSourceImageNormalizer {
    static func normalizedUIImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up || image.scale != 1 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    static func normalizedCGImage(_ image: UIImage) throws -> CGImage {
        let normalized = normalizedUIImage(image)
        guard let source = normalized.cgImage else {
            throw DailySharingError.canonicalEncodingFailed
        }
        let targetWidth = source.width
        let targetHeight = source.height
        guard targetWidth <= DailySharingProtocol.maximumCanonicalPixelDimension,
              targetHeight <= DailySharingProtocol.maximumCanonicalPixelDimension,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw DailySharingError.canonicalEncodingFailed }
        let input = CIImage(cgImage: source)
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .cacheIntermediates: false
        ])
        guard let result = context.createCGImage(
            input,
            from: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(targetWidth),
                height: CGFloat(targetHeight)
            ),
            format: .RGBA8,
            colorSpace: colorSpace
        ) else { throw DailySharingError.canonicalEncodingFailed }
        return result
    }

}

private enum LocalCanonicalPhotoResult {
    case final(UIImage, modificationDate: Date?)
    case unavailable
    case degradedOnly
    case cancelled
    case failed
}

/// Builds one metadata-free canonical at a time. The caller must encrypt and
/// atomically persist the returned bytes before asking for the next photo, so
/// decoded memory is bounded to one source/canonical pair.
actor CanonicalPreviewBuilder {
    /// Runtime self-tests assert this contract directly. Automatic daily
    /// sharing must never turn it on; a future explicit download flow needs a
    /// separate API and consent surface.
    nonisolated static let automaticNetworkAccessAllowed = false

    func build(_ request: CanonicalPreviewRequest) async throws -> CanonicalPreview {
        try Task.checkCancellation()
        let result = await Self.loadLocalPhoto(identifier: request.localIdentifier)
        try Task.checkCancellation()

        let image: UIImage
        let modificationDate: Date?
        switch result {
        case let .final(value, date):
            image = value
            modificationDate = date
        case .degradedOnly:
            throw DailySharingError.degradedPhoto
        case .unavailable:
            throw DailySharingError.localPhotoUnavailable
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw DailySharingError.canonicalEncodingFailed
        }
        guard Self.sameModificationDate(request.sourceModificationDate, modificationDate) else {
            throw DailySharingError.invalidLocalManifest
        }

        return try autoreleasepool {
            let upright = try Self.orientationNormalizedSRGBImage(image)
            guard upright.width == request.sourcePixelSize.width,
                  upright.height == request.sourcePixelSize.height,
                  request.renderPlans.allAreValid
            else { throw DailySharingError.invalidLocalManifest }

            let crop = try Self.pixelAlignedUnionCrop(
                plans: request.renderPlans,
                width: upright.width,
                height: upright.height
            )
            guard let cropped = upright.cropping(to: crop.pixelRect) else {
                throw DailySharingError.canonicalEncodingFailed
            }
            let transformedPlans = try Self.transformedPlans(
                request.renderPlans,
                canonicalCrop: crop.normalizedRect
            )
            return try Self.compressWithinBudget(
                cropped,
                renderPlans: transformedPlans
            )
        }
    }

#if DEBUG
    /// Simulator runtime gate for the exact host-only image pipeline. It skips
    /// PhotoKit acquisition (which is separately fixed to local-only above)
    /// but exercises normalization, crop-union, sRGB encoding, metadata
    /// stripping, quality budget, and the receiver validator with generated
    /// non-user pixels.
    nonisolated static func runtimeSelfTestPreview(
        image: UIImage,
        renderPlans: WidgetRenderPlans
    ) throws -> CanonicalPreview {
        let upright = try orientationNormalizedSRGBImage(image)
        let crop = try pixelAlignedUnionCrop(
            plans: renderPlans,
            width: upright.width,
            height: upright.height
        )
        guard let cropped = upright.cropping(to: crop.pixelRect) else {
            throw DailySharingError.canonicalEncodingFailed
        }
        return try compressWithinBudget(
            cropped,
            renderPlans: transformedPlans(
                renderPlans,
                canonicalCrop: crop.normalizedRect
            )
        )
    }
#endif

    /// Authenticates the decrypted canonical before it can become the local
    /// high-water generation. The plaintext is inspected one item at a time
    /// and is never written to the App Group container.
    nonisolated static func validateReceivedJPEG(
        _ data: Data,
        binding: SharingMediaBinding,
        expectedPlaintextSHA256: String
    ) throws {
        guard !data.isEmpty,
              data.count <= DailySharingProtocol.maximumJPEGBytes,
              Data(base64URLString: expectedPlaintextSHA256)?.count == 32,
              PairingCrypto.sha256(data).base64URLEncodedString() == expectedPlaintextSHA256
        else { throw DailySharingError.invalidCiphertext }
        let binding = try binding.validated()
        let plans = binding.renderPlans.localPlans
        guard hasSufficientResolution(
            pixelSize: binding.canonicalPixelSize,
            plans: plans
        ) else { throw DailySharingError.invalidSharedManifest }
        do {
            try validateEncodedJPEG(data, expectedSize: binding.canonicalPixelSize)
        } catch {
            throw DailySharingError.invalidSharedManifest
        }
    }

    /// `isNetworkAccessAllowed` is permanently false for automatic daily
    /// sharing. A future explicit iCloud-download consent flow must use a
    /// separate API rather than changing this path.
    private nonisolated static func loadLocalPhoto(identifier: String) async -> LocalCanonicalPhotoResult {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                guard let asset = fetch.firstObject else { return .unavailable }

                let options = PHImageRequestOptions()
                options.version = .current
                // Match the personal Widget cache request geometry so the
                // persisted render plan's sourcePixelSize is exact.
                options.resizeMode = .fast
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = automaticNetworkAccessAllowed
                options.isSynchronous = true

                var finalImage: UIImage?
                var sawDegraded = false
                var wasCancelled = false
                var requestFailed = false
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(
                        width: DailySharingProtocol.maximumCanonicalPixelDimension,
                        height: DailySharingProtocol.maximumCanonicalPixelDimension
                    ),
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        wasCancelled = true
                        return
                    }
                    if info?[PHImageErrorKey] as? Error != nil {
                        requestFailed = true
                        return
                    }
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                        sawDegraded = sawDegraded || image != nil
                        return
                    }
                    if let image { finalImage = image }
                }

                if wasCancelled || Task.isCancelled { return .cancelled }
                if let finalImage {
                    return .final(finalImage, modificationDate: asset.modificationDate)
                }
                if sawDegraded { return .degradedOnly }
                if requestFailed { return .failed }
                return .unavailable
            }
        }.value
    }

    private nonisolated static func sameModificationDate(_ expected: Date?, _ actual: Date?) -> Bool {
        switch (expected, actual) {
        case (nil, nil):
            return true
        case let (expected?, actual?):
            return abs(expected.timeIntervalSince(actual)) < 1
        default:
            return false
        }
    }

    private nonisolated static func orientationNormalizedSRGBImage(_ image: UIImage) throws -> CGImage {
        try WidgetSourceImageNormalizer.normalizedCGImage(image)
    }

    private nonisolated static func pixelAlignedUnionCrop(
        plans: WidgetRenderPlans,
        width: Int,
        height: Int
    ) throws -> (pixelRect: CGRect, normalizedRect: CGRect) {
        let rects = WidgetImageVariant.allCases.map { plans.plan(for: $0).sourceRect.cgRect }
        guard let first = rects.first else { throw DailySharingError.invalidLocalManifest }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !union.isNull, union.width > 0, union.height > 0 else {
            throw DailySharingError.invalidLocalManifest
        }
        let minX = max(0, Int(floor(union.minX * CGFloat(width))))
        let minY = max(0, Int(floor(union.minY * CGFloat(height))))
        let maxX = min(width, Int(ceil(union.maxX * CGFloat(width))))
        let maxY = min(height, Int(ceil(union.maxY * CGFloat(height))))
        guard maxX > minX, maxY > minY else {
            throw DailySharingError.invalidLocalManifest
        }
        let pixel = CGRect(
            x: CGFloat(minX),
            y: CGFloat(minY),
            width: CGFloat(maxX - minX),
            height: CGFloat(maxY - minY)
        )
        return (
            pixel,
            CGRect(
                x: CGFloat(minX) / CGFloat(width),
                y: CGFloat(minY) / CGFloat(height),
                width: CGFloat(maxX - minX) / CGFloat(width),
                height: CGFloat(maxY - minY) / CGFloat(height)
            )
        )
    }

    private nonisolated static func transformedPlans(
        _ plans: WidgetRenderPlans,
        canonicalCrop: CGRect
    ) throws -> WidgetRenderPlans {
        guard canonicalCrop.width > 0, canonicalCrop.height > 0 else {
            throw DailySharingError.invalidLocalManifest
        }
        func transform(_ value: WidgetFamilyRenderPlan) -> WidgetFamilyRenderPlan {
            let source = value.sourceRect.cgRect
            return WidgetFamilyRenderPlan(
                sourceRect: WidgetRenderRect(
                    CGRect(
                        x: (source.minX - canonicalCrop.minX) / canonicalCrop.width,
                        y: (source.minY - canonicalCrop.minY) / canonicalCrop.height,
                        width: source.width / canonicalCrop.width,
                        height: source.height / canonicalCrop.height
                    )
                ),
                compositionMode: value.compositionMode
            )
        }
        let result = WidgetRenderPlans(
            small: transform(plans.small),
            medium: transform(plans.medium),
            large: transform(plans.large)
        )
        guard result.allAreValid else { throw DailySharingError.invalidLocalManifest }
        return result
    }

    private nonisolated static func compressWithinBudget(
        _ source: CGImage,
        renderPlans: WidgetRenderPlans
    ) throws -> CanonicalPreview {
        let minimumScale = try minimumQualityScale(
            sourcePixelSize: WidgetSourcePixelSize(width: source.width, height: source.height),
            plans: renderPlans
        )
        guard minimumScale <= 1.001 else {
            throw DailySharingError.insufficientPhotoResolution
        }

        var scales: [CGFloat] = [1, 0.9, 0.8, 0.7, 0.6]
        scales = scales.filter { $0 + 0.000_001 >= minimumScale }
        if scales.last.map({ abs($0 - minimumScale) > 0.000_001 }) != false {
            scales.append(minimumScale)
        }
        // Below 0.52, whiskers and fur collapse in the high-entropy fixture.
        // Prefer keeping yesterday's generation over publishing that result.
        let qualities: [CGFloat] = [0.88, 0.82, 0.76, 0.70, 0.64, 0.58, 0.52]

        for scale in scales {
            let width = max(1, Int((CGFloat(source.width) * scale).rounded(.down)))
            let height = max(1, Int((CGFloat(source.height) * scale).rounded(.down)))
            guard let image = resizedSRGBImage(source, width: width, height: height) else { continue }
            let pixelSize = WidgetSourcePixelSize(width: width, height: height)
            guard renderPlans.isValidForSharing(sourcePixelSize: pixelSize) else { continue }
            let binding = SharingMediaBinding(
                canonicalPixelSize: pixelSize,
                renderPlans: renderPlans
            )
            _ = try binding.validated()
            guard hasSufficientResolution(pixelSize: pixelSize, plans: renderPlans) else {
                continue
            }
            for quality in qualities {
                guard let data = jpegData(image, quality: quality) else { continue }
                guard data.count <= DailySharingProtocol.maximumJPEGBytes else { continue }
                try validateEncodedJPEG(data, expectedSize: pixelSize)
                return CanonicalPreview(
                    jpeg: data,
                    binding: binding,
                    plaintextSHA256: PairingCrypto.sha256(data)
                )
            }
        }
        throw DailySharingError.canonicalEncodingFailed
    }

    private nonisolated static func minimumQualityScale(
        sourcePixelSize: WidgetSourcePixelSize,
        plans: WidgetRenderPlans
    ) throws -> CGFloat {
        var result: CGFloat = 0
        for variant in WidgetImageVariant.allCases {
            let plan = plans.plan(for: variant)
            let rect = plan.sourceRect.cgRect
            let sourceWidth = rect.width * CGFloat(sourcePixelSize.width)
            let sourceHeight = rect.height * CGFloat(sourcePixelSize.height)
            guard sourceWidth > 0, sourceHeight > 0 else {
                throw DailySharingError.invalidLocalManifest
            }
            let required: CGFloat
            if plan.compositionMode == .blurredFitFallback {
                required = min(
                    CGFloat(variant.pixelWidth) / sourceWidth,
                    CGFloat(variant.pixelHeight) / sourceHeight
                )
            } else {
                required = max(
                    CGFloat(variant.pixelWidth) / sourceWidth,
                    CGFloat(variant.pixelHeight) / sourceHeight
                )
            }
            result = max(result, required)
        }
        return result
    }

    private nonisolated static func hasSufficientResolution(
        pixelSize: WidgetSourcePixelSize,
        plans: WidgetRenderPlans
    ) -> Bool {
        for variant in WidgetImageVariant.allCases {
            let plan = plans.plan(for: variant)
            let rect = plan.sourceRect.cgRect
            let availableWidth = rect.width * CGFloat(pixelSize.width)
            let availableHeight = rect.height * CGFloat(pixelSize.height)
            if plan.compositionMode == .blurredFitFallback {
                let fitScale = min(
                    CGFloat(variant.pixelWidth) / availableWidth,
                    CGFloat(variant.pixelHeight) / availableHeight
                )
                guard fitScale <= 1.000_001 else { return false }
            } else {
                guard availableWidth + 0.000_001 >= CGFloat(variant.pixelWidth),
                      availableHeight + 0.000_001 >= CGFloat(variant.pixelHeight)
                else { return false }
            }
        }
        return true
    }

    private nonisolated static func resizedSRGBImage(
        _ source: CGImage,
        width: Int,
        height: Int
    ) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(
            source,
            in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        )
        return context.makeImage()
    }

    private nonisolated static func jpegData(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private nonisolated static func validateEncodedJPEG(
        _ data: Data,
        expectedSize: WidgetSourcePixelSize
    ) throws {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == expectedSize.width,
              properties[kCGImagePropertyPixelHeight] as? Int == expectedSize.height,
              properties[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelRGB as String,
              (properties[kCGImagePropertyOrientation] == nil
                || properties[kCGImagePropertyOrientation] as? Int == 1),
              properties[kCGImagePropertyExifDictionary] == nil,
              properties[kCGImagePropertyTIFFDictionary] == nil,
              properties[kCGImagePropertyGPSDictionary] == nil,
              properties[kCGImagePropertyIPTCDictionary] == nil,
              let decoded = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              decoded.colorSpace?.name == CGColorSpace.sRGB
        else { throw DailySharingError.canonicalEncodingFailed }
    }
}
