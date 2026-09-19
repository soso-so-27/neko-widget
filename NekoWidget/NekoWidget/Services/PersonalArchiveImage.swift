import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A viewing copy made only after an explicit photo selection or note preservation.
/// Original resources, location metadata and PhotoKit identifiers are not stored.
enum PersonalArchiveImage {
    static let maximumPixelSize = 4096
    static let maximumBytes = 20 * 1024 * 1024

    static func jpeg(from url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { throw PreparationError.unreadable }
        return try jpeg(from: source)
    }

    static func jpeg(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { throw PreparationError.unreadable }
        return try jpeg(from: source)
    }

    private static func jpeg(from source: CGImageSource) throws -> Data {
        guard CGImageSourceGetCount(source) > 0,
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw PreparationError.unreadable }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw PreparationError.unreadable }
        // Encode the transformed pixels. Do not copy source metadata (GPS/EXIF).
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyOrientation: 1
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else {
            throw PreparationError.tooLarge
        }
        return output as Data
    }

    enum PreparationError: LocalizedError {
        case unreadable, tooLarge
        var errorDescription: String? {
            switch self {
            case .unreadable: "写真を読み込めませんでした。もう一度選んでください。"
            case .tooLarge: "この写真を保管用に準備できませんでした。別の写真でお試しください。"
            }
        }
    }
}
