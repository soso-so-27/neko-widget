import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct MomentCanonicalPreview: Sendable {
    let jpeg: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Canonicalizes one user-selected photo for explicit family sharing.
///
/// This intentionally does not depend on the personal Widget render plans or
/// the retired daily-sharing protocol, so the containing app and Share
/// Extension execute the exact same small image contract.
enum MomentCanonicalPreviewBuilder {
    static func build(image: UIImage) throws -> MomentCanonicalPreview {
        try Task.checkCancellation()
        guard image.imageOrientation == .up, let source = image.cgImage else {
            throw MomentSharingError.invalidPayload
        }
        let longest = max(source.width, source.height)
        guard longest > 0 else { throw MomentSharingError.invalidPayload }
        let baseScale = min(
            1,
            CGFloat(MomentSharingProtocol.maximumCanonicalPixelDimension) / CGFloat(longest)
        )
        let scales: [CGFloat] = [1, 0.9, 0.8, 0.7, 0.6].map { baseScale * $0 }
        let qualities: [CGFloat] = [0.92, 0.86, 0.80, 0.74, 0.68, 0.62, 0.56]
        var encounteredCanonicalizationFailure = false

        for scale in scales {
            try Task.checkCancellation()
            let width = max(1, Int((CGFloat(source.width) * scale).rounded(.down)))
            let height = max(1, Int((CGFloat(source.height) * scale).rounded(.down)))
            guard width <= MomentSharingProtocol.maximumCanonicalPixelDimension,
                  height <= MomentSharingProtocol.maximumCanonicalPixelDimension
            else { continue }
            guard let normalized = normalizedSRGBImage(source, width: width, height: height)
            else {
                encounteredCanonicalizationFailure = true
                continue
            }

            for quality in qualities {
                try Task.checkCancellation()
                guard let data = jpegData(normalized, quality: quality) else {
                    encounteredCanonicalizationFailure = true
                    continue
                }
                guard data.count <= MomentSharingProtocol.maximumMediaCiphertextBytes - 28
                else { continue }
                do {
                    try validateJPEG(data, pixelWidth: width, pixelHeight: height)
                    return MomentCanonicalPreview(
                        jpeg: data,
                        pixelWidth: width,
                        pixelHeight: height
                    )
                } catch {
                    encounteredCanonicalizationFailure = true
                    continue
                }
            }
        }
        throw encounteredCanonicalizationFailure
            ? MomentSharingError.invalidPayload
            : MomentSharingError.payloadTooLarge
    }

    static func validateReceived(
        _ data: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        expectedPlaintextSHA256: Data
    ) throws {
        guard !data.isEmpty,
              data.count <= MomentSharingProtocol.maximumMediaCiphertextBytes - 28,
              expectedPlaintextSHA256.count == 32,
              Data(SHA256.hash(data: data)) == expectedPlaintextSHA256,
              (1...MomentSharingProtocol.maximumCanonicalPixelDimension).contains(pixelWidth),
              (1...MomentSharingProtocol.maximumCanonicalPixelDimension).contains(pixelHeight)
        else { throw MomentSharingError.invalidPayload }
        try validateJPEG(data, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    private static func normalizedSRGBImage(
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

    private static func jpegData(_ image: CGImage, quality: CGFloat) -> Data? {
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            result,
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
        // ImageIO may synthesize application metadata even when its input is a
        // freshly rendered CGImage. This protocol needs no APP payload, so
        // remove every APPn segment and comment before validation and hashing.
        return strippingPrivateMetadata(from: result as Data)
    }

    /// Rewrites the bounded JPEG marker stream, including markers between
    /// progressive scans. Entropy-coded bytes, byte stuffing, and restart
    /// markers remain unchanged; APPn and COM metadata containers do not.
    private static func strippingPrivateMetadata(from jpeg: Data) -> Data? {
        guard jpeg.count >= 4,
              jpeg[0] == 0xFF,
              jpeg[1] == 0xD8
        else { return nil }

        var output = Data([0xFF, 0xD8])
        var cursor = 2
        var isReadingEntropyData = false
        var sawStartOfScan = false
        while cursor < jpeg.count {
            if isReadingEntropyData {
                guard jpeg[cursor] == 0xFF else {
                    output.append(jpeg[cursor])
                    cursor += 1
                    continue
                }

                let markerStart = cursor
                while cursor < jpeg.count, jpeg[cursor] == 0xFF {
                    cursor += 1
                }
                guard cursor < jpeg.count else { return nil }
                let marker = jpeg[cursor]

                // A stuffed zero and restart markers are part of the scan,
                // not the start of a marker segment.
                if marker == 0x00 || (0xD0...0xD7).contains(marker) {
                    output.append(contentsOf: jpeg[markerStart...cursor])
                    cursor += 1
                    continue
                }

                // Re-process the marker outside entropy mode so its declared
                // length is bounds checked and private segments can be removed.
                cursor = markerStart
                isReadingEntropyData = false
                continue
            }

            let markerStart = cursor
            guard jpeg[cursor] == 0xFF else { return nil }
            while cursor < jpeg.count, jpeg[cursor] == 0xFF {
                cursor += 1
            }
            guard cursor < jpeg.count else { return nil }
            let marker = jpeg[cursor]
            cursor += 1

            if marker == 0xD9 {
                guard sawStartOfScan else { return nil }
                output.append(contentsOf: jpeg[markerStart..<cursor])
                guard cursor == jpeg.count else { return nil }
                return output
            }
            guard marker != 0x00,
                  marker != 0xD8,
                  !(0xD0...0xD7).contains(marker)
            else { return nil }

            if marker == 0x01 {
                output.append(contentsOf: jpeg[markerStart..<cursor])
                continue
            }

            guard cursor <= jpeg.count - 2 else { return nil }

            let segmentLength = (Int(jpeg[cursor]) << 8) | Int(jpeg[cursor + 1])
            guard segmentLength >= 2,
                  segmentLength <= jpeg.count - cursor
            else { return nil }
            let segmentEnd = cursor + segmentLength

            if !(0xE0...0xEF).contains(marker), marker != 0xFE {
                output.append(contentsOf: jpeg[markerStart..<segmentEnd])
            }
            cursor = segmentEnd
            if marker == 0xDA {
                sawStartOfScan = true
                isReadingEntropyData = true
            }
        }
        return nil
    }

#if DEBUG
    static func runtimeSelfTestStrippingPrivateMetadata(from jpeg: Data) -> Data? {
        strippingPrivateMetadata(from: jpeg)
    }
#endif

    private static func validateJPEG(
        _ data: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws {
        guard strippingPrivateMetadata(from: data) == data,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
        CGImageSourceGetCount(source) == 1,
        CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
        properties[kCGImagePropertyPixelWidth] as? Int == pixelWidth,
        properties[kCGImagePropertyPixelHeight] as? Int == pixelHeight,
        properties[kCGImagePropertyColorModel] as? String
            == kCGImagePropertyColorModelRGB as String,
        properties[kCGImagePropertyExifDictionary] == nil,
        properties[kCGImagePropertyTIFFDictionary] == nil,
        properties[kCGImagePropertyGPSDictionary] == nil,
        properties[kCGImagePropertyIPTCDictionary] == nil,
        properties[kCGImagePropertyOrientation] == nil
            || properties[kCGImagePropertyOrientation] as? Int == 1,
        CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) != nil
        else { throw MomentSharingError.invalidPayload }
    }
}
