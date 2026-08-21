import CoreGraphics
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

        for scale in scales {
            let width = max(1, Int((CGFloat(source.width) * scale).rounded(.down)))
            let height = max(1, Int((CGFloat(source.height) * scale).rounded(.down)))
            guard width <= MomentSharingProtocol.maximumCanonicalPixelDimension,
                  height <= MomentSharingProtocol.maximumCanonicalPixelDimension,
                  let normalized = normalizedSRGBImage(source, width: width, height: height)
            else { continue }

            for quality in qualities {
                guard let data = jpegData(normalized, quality: quality),
                      data.count <= MomentSharingProtocol.maximumMediaCiphertextBytes - 28
                else { continue }
                do {
                    try validateJPEG(data, pixelWidth: width, pixelHeight: height)
                    return MomentCanonicalPreview(
                        jpeg: data,
                        pixelWidth: width,
                        pixelHeight: height
                    )
                } catch {
                    continue
                }
            }
        }
        throw MomentSharingError.payloadTooLarge
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
              PairingCrypto.sha256(data) == expectedPlaintextSHA256,
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
        return result as Data
    }

    private static func validateJPEG(
        _ data: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws {
        guard let source = CGImageSourceCreateWithData(
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
