import CoreImage
import CryptoKit
import Foundation
import UIKit

/// Only the host app decodes, hashes and blurs. The Widget receives immutable
/// JPEG pairs, with a 32-photo / 192-file bound (at most about 33 MiB).
actor CloudyWindowImagePreparer {
    static let shared = CloudyWindowImagePreparer()
    private let context = CIContext(options: [.cacheIntermediates: false])

    func prepare() async throws {
        guard let plan = try CloudyWindowStore.shared.preparation(),
              let cache = SharedContainer.widgetCacheDirectoryURL else { return }
        for candidate in plan.candidates {
            try Task.checkCancellation()
            if let old = plan.existing.first(where: { $0.photoID == candidate.item.localIdentifier }),
               old.source == candidate.item, old.strength == plan.configuration.strength { continue }
            try autoreleasepool {
                let source = candidate.item
                let identity = source.allCacheFilenames.joined(separator: "|") + "|" + plan.configuration.strength.rawValue
                let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                func names(_ kind: String) -> WidgetCacheFilenames {
                    .init(small: "cloudy-\(kind)-small-\(digest).jpg",
                          medium: "cloudy-\(kind)-medium-\(digest).jpg",
                          large: "cloudy-\(kind)-large-\(digest).jpg")
                }
                let clear = names("clear"), cloudy = names("blur")
                var files: [String: Data] = [:]
                var hash: UInt64 = 0
                for variant in WidgetImageVariant.allCases {
                    // These names were validated when the personal pool committed.
                    let url = cache.appendingPathComponent(source.cacheFilename(for: variant))
                    guard let data = try? Data(contentsOf: url), data.count <= variant.maximumJPEGByteCount,
                          let image = UIImage(data: data), let cg = image.cgImage else { return }
                    if variant == .small { hash = Self.differenceHash(cg) }
                    let input = CIImage(cgImage: cg)
                    let radius = plan.configuration.strength.radius * Double(cg.width) / 500
                    let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                        .cropped(to: input.extent)
                    guard let output = context.createCGImage(blurred, from: input.extent),
                          let jpeg = Self.jpeg(UIImage(cgImage: output), maximumBytes: variant.maximumJPEGByteCount) else { return }
                    files[clear.filename(for: variant)] = data
                    files[cloudy.filename(for: variant)] = jpeg
                }
                guard files.count == 6 else { return }
                try CloudyWindowStore.shared.publish(
                    .init(source: source, clear: clear, cloudy: cloudy, strength: plan.configuration.strength,
                          visualHash: hash, preparedAt: .now), files: files,
                    authorityRevision: plan.authorityRevision, configurationRevision: plan.configuration.revision,
                    protectedPhotoIDs: plan.protectedPhotoIDs)
            }
            await Task.yield()
        }
    }

    private static func jpeg(_ image: UIImage, maximumBytes: Int) -> Data? {
        for quality in [0.90, 0.80, 0.68, 0.55, 0.40] {
            if let bytes = image.jpegData(compressionQuality: quality), bytes.count <= maximumBytes { return bytes }
        }
        return nil
    }

    private static func differenceHash(_ image: CGImage) -> UInt64 {
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 9, height: 8, bitsPerComponent: 8,
                bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard drawn else { return 0 }
        var result: UInt64 = 0
        for row in 0..<8 {
            for column in 0..<8 where pixels[row * 9 + column] > pixels[row * 9 + column + 1] {
                result |= UInt64(1) << (row * 8 + column)
            }
        }
        return result
    }
}
