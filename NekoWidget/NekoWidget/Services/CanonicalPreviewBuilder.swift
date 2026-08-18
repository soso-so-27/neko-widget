import CoreGraphics
import CoreImage
import CryptoKit
import ImageIO
@preconcurrency import Photos
import UIKit
import UniformTypeIdentifiers

private enum CanonicalEncodingFailureStage: String {
    case normalizeSRGB = "normalize-srgb"
    case cropPlan = "crop-plan"
    case cropImage = "crop-image"
    case transformPlans = "transform-plans"
    case minimumScale = "minimum-scale"
    case resizeSRGB = "resize-srgb"
    case binding = "binding"
    case resolution = "resolution"
    case jpegDestinationCreate = "jpeg-destination-create"
    case jpegDestinationFinalize = "jpeg-destination-finalize"
    case jpegProfilePayload = "jpeg-profile-payload"
    case jpegSOI = "jpeg-soi"
    case jpegMarker = "jpeg-marker"
    case jpegSegment = "jpeg-segment"
    case jpegAPP2NonICC = "jpeg-app2-non-icc"
    case jpegNoSOS = "jpeg-no-sos"
    case jpegByteBudget = "jpeg-byte-budget"
    case validateProfileExact = "validate-profile-exact"
    case validateSourceCreate = "validate-source-create"
    case validateImageCount = "validate-image-count"
    case validateType = "validate-type"
    case validateProperties = "validate-properties"
    case validateDimensions = "validate-dimensions"
    case validateColorModel = "validate-color-model"
    case validateOrientation = "validate-orientation"
    case validateExif = "validate-exif"
    case validateTIFF = "validate-tiff"
    case validateGPS = "validate-gps"
    case validateIPTC = "validate-iptc"
    case validateDecode = "validate-decode"
    case validateDecodedColorSpace = "validate-decoded-color-space"
    case validateDecodedRGB = "validate-decoded-rgb"
    case noCandidate = "no-candidate"
}

#if DEBUG
enum CanonicalPreviewRuntimeSelfTestCase: String {
    case canonicalLocalOnlyPrivacyBudget = "canonical-local-only-privacy-budget"
    case ownSourceLocalPromotion = "own-source-local-promotion"
}
#endif

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

/// Fixed protocol color profile used by both the canonical encoder and its
/// receiver validator. This avoids binding the wire format to the particular
/// sRGB profile bytes shipped by an OS release.
///
/// Source: https://github.com/saucecontrol/Compact-ICC-Profiles/blob/bdd84663061bc4ae95ca70decff54f581e27f702/profiles/sRGB-v4.icc
/// License: CC0-1.0 public-domain dedication
/// SHA-256: c56e1685d888f5edb92fe07f2750f387f8fe8e91b32ff8fb0b56bfbbb9458353
private enum SharingCanonicalColorProfile {
    private static let jpegICCSignature = Array("ICC_PROFILE\u{0}".utf8)
    private static let encodedProfile =
        "AAAB4GxjbXMEIAAAbW50clJHQiBYWVogB+IAAwAUAAkADgAdYWNzcE1TRlQAAAAA" +
        "c2F3c2N0cmwAAAAAAAAAAAAAAAAAAPbWAAEAAAAA0y1oYW5keem/Vlo+AbaDI4VV" +
        "RvdPqgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKZGVzYwAAAPwAAAAk" +
        "Y3BydAAAASAAAAAid3RwdAAAAUQAAAAUY2hhZAAAAVgAAAAsclhZWgAAAYQAAAAU" +
        "Z1hZWgAAAZgAAAAUYlhZWgAAAawAAAAUclRSQwAAAcAAAAAgZ1RSQwAAAcAAAAAg" +
        "YlRSQwAAAcAAAAAgbWx1YwAAAAAAAAABAAAADGVuVVMAAAAIAAAAHABzAFIARwBC" +
        "bWx1YwAAAAAAAAABAAAADGVuVVMAAAAGAAAAHABDAEMAMAAAWFlaIAAAAAAAAPbW" +
        "AAEAAAAA0y1zZjMyAAAAAAABDD8AAAXd///zJgAAB5AAAP2S///7of///aIAAAPc" +
        "AADAcVhZWiAAAAAAAABvoAAAOPIAAAOPWFlaIAAAAAAAAGKWAAC3iQAAGNpYWVog" +
        "AAAAAAAAJKAAAA+FAAC2xHBhcmEAAAAAAAMAAAACZmkAAPKnAAANWQAAE9AAAApb"
    private static let expectedSHA256 =
        "xW4WhdiI9e25L+B/J1Dzh/j+jpGzL/j7C1a/u7lFg1M="

    static let data: Data? = {
        guard let data = Data(base64Encoded: encodedProfile),
              data.count == 480,
              Data(SHA256.hash(data: data)).base64EncodedString() == expectedSHA256
        else { return nil }
        return data
    }()

    static func makeColorSpace() -> CGColorSpace? {
        guard let data else { return nil }
        return CGColorSpace(iccData: data as CFData)
    }

    static func hasExactEmbeddedProfile(in jpeg: Data) -> Bool {
        exactEmbeddedProfileRange(in: jpeg) != nil
    }

    /// ImageIO is allowed to reserialize the ICC representation owned by a
    /// `CGColorSpace`. Canonicalize that encoder output explicitly so the wire
    /// contract remains the pinned profile bytes rather than an OS-specific
    /// serialization of the same color space.
    static func canonicalizingEmbeddedProfile(
        in jpeg: Data,
        failureRecorder: ((CanonicalEncodingFailureStage) -> Void)? = nil
    ) -> Data? {
        guard let profile = data else {
            failureRecorder?(.jpegProfilePayload)
            return nil
        }
        guard jpeg.count >= 4,
              jpeg[0] == 0xFF,
              jpeg[1] == 0xD8
        else {
            failureRecorder?(.jpegSOI)
            return nil
        }

        let payloadLength = jpegICCSignature.count + 2 + profile.count
        let segmentLength = payloadLength + 2
        guard segmentLength <= Int(UInt16.max) else {
            failureRecorder?(.jpegProfilePayload)
            return nil
        }

        var profileSegment = Data([0xFF, 0xE2])
        profileSegment.append(UInt8((segmentLength >> 8) & 0xFF))
        profileSegment.append(UInt8(segmentLength & 0xFF))
        profileSegment.append(contentsOf: jpegICCSignature)
        profileSegment.append(contentsOf: [1, 1])
        profileSegment.append(profile)

        // Keep JFIF APP0 first when ImageIO emits it. The protocol ICC follows
        // the leading APP0 segment(s), before all other metadata/codec tables.
        var result = Data([0xFF, 0xD8])
        var insertedProfile = false
        func insertProfileIfNeeded() {
            guard !insertedProfile else { return }
            result.append(profileSegment)
            insertedProfile = true
        }

        var cursor = 2
        while cursor < jpeg.count {
            let markerStart = cursor
            guard jpeg[cursor] == 0xFF else {
                failureRecorder?(.jpegMarker)
                return nil
            }
            while cursor < jpeg.count, jpeg[cursor] == 0xFF {
                cursor += 1
            }
            guard cursor < jpeg.count else {
                failureRecorder?(.jpegMarker)
                return nil
            }
            let marker = jpeg[cursor]
            cursor += 1

            if marker == 0xDA {
                insertProfileIfNeeded()
                result.append(contentsOf: jpeg[markerStart...])
                return result
            }
            guard marker != 0x00,
                  marker != 0x01,
                  !(0xD0...0xD9).contains(marker),
                  cursor <= jpeg.count - 2
            else {
                failureRecorder?(.jpegMarker)
                return nil
            }

            let sourceSegmentLength = (Int(jpeg[cursor]) << 8) | Int(jpeg[cursor + 1])
            guard sourceSegmentLength >= 2,
                  sourceSegmentLength <= jpeg.count - cursor
            else {
                failureRecorder?(.jpegSegment)
                return nil
            }
            let payloadStart = cursor + 2
            let payloadEnd = cursor + sourceSegmentLength

            if marker != 0xE0 {
                insertProfileIfNeeded()
            }
            if marker == 0xE2 {
                let signatureEnd = payloadStart + jpegICCSignature.count
                guard signatureEnd + 2 <= payloadEnd,
                      jpeg[payloadStart..<signatureEnd].elementsEqual(jpegICCSignature)
                else {
                    failureRecorder?(.jpegAPP2NonICC)
                    return nil
                }
                // Drop every encoder-produced ICC chunk. The fixed single
                // chunk inserted above is the only APP2 form this protocol
                // permits, and the receiver independently verifies it.
            } else if marker == 0xE1 || marker == 0xED || marker == 0xFE {
                // ImageIO may synthesize EXIF/XMP (APP1), IPTC (APP13), or a
                // comment even when the source is a metadata-free CGImage.
                // None is part of the canonical protocol, so remove it before
                // hashing rather than weakening the receiver's privacy gate.
            } else {
                result.append(contentsOf: jpeg[markerStart..<payloadEnd])
            }
            cursor = payloadEnd
        }
        failureRecorder?(.jpegNoSOS)
        return nil
    }

#if DEBUG
    static func tamperingEmbeddedProfile(in jpeg: Data) -> Data? {
        guard let range = exactEmbeddedProfileRange(in: jpeg) else { return nil }
        var result = jpeg
        result[range.lowerBound] = result[range.lowerBound] ^ 0x01
        return result
    }
#endif

    /// Parses only the bounded JPEG header. The fixed 480-byte profile fits in
    /// one APP2 segment, so split, duplicate, reordered, or malformed ICC
    /// payloads are outside the protocol and fail closed.
    private static func exactEmbeddedProfileRange(in jpeg: Data) -> Range<Int>? {
        guard let expected = data,
              jpeg.count >= 4,
              jpeg[0] == 0xFF,
              jpeg[1] == 0xD8
        else { return nil }

        var cursor = 2
        var profileRange: Range<Int>?
        while cursor < jpeg.count {
            guard jpeg[cursor] == 0xFF else { return nil }
            while cursor < jpeg.count, jpeg[cursor] == 0xFF {
                cursor += 1
            }
            guard cursor < jpeg.count else { return nil }
            let marker = jpeg[cursor]
            cursor += 1

            if marker == 0xDA || marker == 0xD9 {
                return profileRange
            }
            guard marker != 0x00,
                  marker != 0x01,
                  !(0xD0...0xD8).contains(marker),
                  cursor <= jpeg.count - 2
            else { return nil }

            let segmentLength = (Int(jpeg[cursor]) << 8) | Int(jpeg[cursor + 1])
            guard segmentLength >= 2,
                  segmentLength <= jpeg.count - cursor
            else { return nil }
            let payloadStart = cursor + 2
            let payloadEnd = cursor + segmentLength

            if marker == 0xE2 {
                let signatureEnd = payloadStart + jpegICCSignature.count
                let profileStart = signatureEnd + 2
                guard profileRange == nil,
                      signatureEnd <= payloadEnd,
                      jpeg[payloadStart..<signatureEnd].elementsEqual(jpegICCSignature),
                      profileStart <= payloadEnd,
                      jpeg[signatureEnd] == 1,
                      jpeg[signatureEnd + 1] == 1,
                      payloadEnd - profileStart == expected.count,
                      jpeg[profileStart..<payloadEnd].elementsEqual(expected)
                else { return nil }
                profileRange = profileStart..<payloadEnd
            }
            cursor = payloadEnd
        }
        return nil
    }
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
              let colorSpace = SharingCanonicalColorProfile.makeColorSpace()
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
        renderPlans: WidgetRenderPlans,
        diagnosticCase: CanonicalPreviewRuntimeSelfTestCase
    ) throws -> CanonicalPreview {
        var lastFailureStage: CanonicalEncodingFailureStage?
        let failureRecorder: (CanonicalEncodingFailureStage) -> Void = { stage in
            lastFailureStage = stage
        }
        do {
            let upright: CGImage
            do {
                upright = try orientationNormalizedSRGBImage(image)
            } catch {
                failureRecorder(.normalizeSRGB)
                throw error
            }
            let crop: (pixelRect: CGRect, normalizedRect: CGRect)
            do {
                crop = try pixelAlignedUnionCrop(
                    plans: renderPlans,
                    width: upright.width,
                    height: upright.height
                )
            } catch {
                failureRecorder(.cropPlan)
                throw error
            }
            guard let cropped = upright.cropping(to: crop.pixelRect) else {
                failureRecorder(.cropImage)
                throw DailySharingError.canonicalEncodingFailed
            }
            let transformed: WidgetRenderPlans
            do {
                transformed = try transformedPlans(
                    renderPlans,
                    canonicalCrop: crop.normalizedRect
                )
            } catch {
                failureRecorder(.transformPlans)
                throw error
            }
            return try compressWithinBudget(
                cropped,
                renderPlans: transformed,
                failureRecorder: failureRecorder
            )
        } catch {
            SharedLog.app.error(
                "sharing-runtime-self-test",
                "Canonical preview stage failed",
                metadata: [
                    "case": diagnosticCase.rawValue,
                    "stage": (lastFailureStage ?? .noCandidate).rawValue
                ]
            )
            throw error
        }
    }

    nonisolated static func runtimeSelfTestJPEGWithTamperedColorProfile(
        _ jpeg: Data
    ) throws -> Data {
        guard let result = SharingCanonicalColorProfile.tamperingEmbeddedProfile(in: jpeg) else {
            throw DailySharingError.canonicalEncodingFailed
        }
        return result
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
        renderPlans: WidgetRenderPlans,
        failureRecorder: ((CanonicalEncodingFailureStage) -> Void)? = nil
    ) throws -> CanonicalPreview {
        let minimumScale: CGFloat
        do {
            minimumScale = try minimumQualityScale(
                sourcePixelSize: WidgetSourcePixelSize(width: source.width, height: source.height),
                plans: renderPlans
            )
        } catch {
            failureRecorder?(.minimumScale)
            throw error
        }
        guard minimumScale <= 1.001 else {
            failureRecorder?(.resolution)
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
            guard let image = resizedSRGBImage(source, width: width, height: height) else {
                failureRecorder?(.resizeSRGB)
                continue
            }
            let pixelSize = WidgetSourcePixelSize(width: width, height: height)
            guard renderPlans.isValidForSharing(sourcePixelSize: pixelSize) else {
                failureRecorder?(.binding)
                continue
            }
            let binding = SharingMediaBinding(
                canonicalPixelSize: pixelSize,
                renderPlans: renderPlans
            )
            do {
                _ = try binding.validated()
            } catch {
                failureRecorder?(.binding)
                throw error
            }
            guard hasSufficientResolution(pixelSize: pixelSize, plans: renderPlans) else {
                failureRecorder?(.resolution)
                continue
            }
            for quality in qualities {
                guard let data = jpegData(
                    image,
                    quality: quality,
                    failureRecorder: failureRecorder
                ) else { continue }
                guard data.count <= DailySharingProtocol.maximumJPEGBytes else {
                    failureRecorder?(.jpegByteBudget)
                    continue
                }
                try validateEncodedJPEG(
                    data,
                    expectedSize: pixelSize,
                    failureRecorder: failureRecorder
                )
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
        guard let colorSpace = SharingCanonicalColorProfile.makeColorSpace(),
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

    private nonisolated static func jpegData(
        _ image: CGImage,
        quality: CGFloat,
        failureRecorder: ((CanonicalEncodingFailureStage) -> Void)? = nil
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            failureRecorder?(.jpegDestinationCreate)
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            failureRecorder?(.jpegDestinationFinalize)
            return nil
        }
        return SharingCanonicalColorProfile.canonicalizingEmbeddedProfile(
            in: data as Data,
            failureRecorder: failureRecorder
        )
    }

    private nonisolated static func validateEncodedJPEG(
        _ data: Data,
        expectedSize: WidgetSourcePixelSize,
        failureRecorder: ((CanonicalEncodingFailureStage) -> Void)? = nil
    ) throws {
        guard SharingCanonicalColorProfile.hasExactEmbeddedProfile(in: data) else {
            failureRecorder?(.validateProfileExact)
            throw DailySharingError.canonicalEncodingFailed
        }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            failureRecorder?(.validateSourceCreate)
            throw DailySharingError.canonicalEncodingFailed
        }
        guard CGImageSourceGetCount(source) == 1 else {
            failureRecorder?(.validateImageCount)
            throw DailySharingError.canonicalEncodingFailed
        }
        guard CGImageSourceGetType(source) as String? == UTType.jpeg.identifier else {
            failureRecorder?(.validateType)
            throw DailySharingError.canonicalEncodingFailed
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        else {
            failureRecorder?(.validateProperties)
            throw DailySharingError.canonicalEncodingFailed
        }
        guard properties[kCGImagePropertyPixelWidth] as? Int == expectedSize.width,
              properties[kCGImagePropertyPixelHeight] as? Int == expectedSize.height
        else {
            failureRecorder?(.validateDimensions)
            throw DailySharingError.canonicalEncodingFailed
        }
        guard properties[kCGImagePropertyColorModel] as? String
            == kCGImagePropertyColorModelRGB as String
        else {
            failureRecorder?(.validateColorModel)
            throw DailySharingError.canonicalEncodingFailed
        }
        guard properties[kCGImagePropertyOrientation] == nil
                || properties[kCGImagePropertyOrientation] as? Int == 1
        else {
            failureRecorder?(.validateOrientation)
            throw DailySharingError.canonicalEncodingFailed
        }
        guard properties[kCGImagePropertyExifDictionary] == nil else {
            failureRecorder?(.validateExif)
            throw DailySharingError.canonicalEncodingFailed
        }
        guard properties[kCGImagePropertyTIFFDictionary] == nil else {
            failureRecorder?(.validateTIFF)
            throw DailySharingError.canonicalEncodingFailed
        }
        guard properties[kCGImagePropertyGPSDictionary] == nil else {
            failureRecorder?(.validateGPS)
            throw DailySharingError.canonicalEncodingFailed
        }
        guard properties[kCGImagePropertyIPTCDictionary] == nil else {
            failureRecorder?(.validateIPTC)
            throw DailySharingError.canonicalEncodingFailed
        }
        guard let decoded = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
              )
        else {
            failureRecorder?(.validateDecode)
            throw DailySharingError.canonicalEncodingFailed
        }
        guard let decodedColorSpace = decoded.colorSpace else {
            failureRecorder?(.validateDecodedColorSpace)
            throw DailySharingError.canonicalEncodingFailed
        }
        guard decodedColorSpace.model == .rgb else {
            failureRecorder?(.validateDecodedRGB)
            throw DailySharingError.canonicalEncodingFailed
        }
    }
}
