import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct MomentShareIngressPhoto: Sendable {
    let canonicalJPEG: Data
    let capturedAt: Date?
    let pixelWidth: Int
    let pixelHeight: Int

    @MainActor
    func previewImage() throws -> UIImage {
        guard let image = UIImage(data: canonicalJPEG, scale: 1) else {
            throw MomentSharingError.invalidPayload
        }
        return image
    }
}

/// Converts exactly one provider-granted image into the small, metadata-free
/// JPEG that the host app will later moderate, encrypt, and deliver.
///
/// This boundary deliberately has no identity credential, room-key,
/// moderation, or network dependency. A Share Extension can only stage a
/// capture against a short-lived admission previously issued by the host app.
struct MomentShareIngressService {
    private static let maximumSourceBytes = 64 * 1_024 * 1_024
    private static let senderPolicyVersion = 1

    func prepare(from provider: NSItemProvider) async throws -> MomentShareIngressPhoto {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) {
                sourceURL, providerError in
                if let providerError {
                    continuation.resume(throwing: providerError)
                    return
                }
                guard let sourceURL else {
                    continuation.resume(throwing: MomentSharingError.invalidPayload)
                    return
                }
                do {
                    let prepared = try autoreleasepool {
                        try Self.canonicalPhoto(from: sourceURL)
                    }
                    continuation.resume(returning: prepared)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Host-app `PhotosPicker` file-representation entry point. The caller
    /// must invoke this while the provider-granted URL is valid. No source
    /// bytes or provider URL are retained after the bounded canonical JPEG is
    /// returned.
    func prepare(fromFileURL url: URL) throws -> MomentShareIngressPhoto {
        try autoreleasepool {
            try Self.canonicalPhoto(from: url)
        }
    }

    func activeAdmissions(now: Date = .now) async throws -> [MomentShareDestinationAdmission] {
        try await Task.detached(priority: .userInitiated) {
            try MomentShareHandoffStore.activeAdmissions(now: now)
        }.value
    }

    func stage(
        _ photo: MomentShareIngressPhoto,
        admissionID: UUID,
        senderPolicyAcceptedAt: Date,
        now: Date = .now
    ) async throws {
        _ = try await Task.detached(priority: .userInitiated) {
            try MomentShareHandoffStore.stageCapture(
                admissionID: admissionID,
                canonicalJPEG: photo.canonicalJPEG,
                capturedAt: photo.capturedAt,
                pixelWidth: photo.pixelWidth,
                pixelHeight: photo.pixelHeight,
                senderPolicyVersion: Self.senderPolicyVersion,
                senderPolicyAcceptedAt: senderPolicyAcceptedAt,
                now: now
            )
        }.value
    }

    private static func canonicalPhoto(from url: URL) throws -> MomentShareIngressPhoto {
        guard url.isFileURL,
              let sourceByteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              (1...maximumSourceBytes).contains(sourceByteCount),
              let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
              )
        else { throw MomentSharingError.invalidPayload }

        return try canonicalPhoto(from: source)
    }

    private static func canonicalPhoto(
        from source: CGImageSource
    ) throws -> MomentShareIngressPhoto {
        guard CGImageSourceGetCount(source) == 1 else {
            throw MomentSharingError.invalidPayload
        }

        // Read only the small property dictionary and a bounded thumbnail.
        // The original is never copied into the App Group container.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize:
                MomentSharingProtocol.maximumCanonicalPixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { throw MomentSharingError.invalidPayload }

        let preview = try MomentCanonicalPreviewBuilder.build(
            image: UIImage(cgImage: thumbnail, scale: 1, orientation: .up)
        )
        return MomentShareIngressPhoto(
            canonicalJPEG: preview.jpeg,
            capturedAt: captureDate(from: properties),
            pixelWidth: preview.pixelWidth,
            pixelHeight: preview.pixelHeight
        )
    }

    private static func captureDate(from properties: [CFString: Any]?) -> Date? {
        guard let properties else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let offsetOriginalKey = "OffsetTimeOriginal" as CFString
        let offsetDigitizedKey = "OffsetTimeDigitized" as CFString
        let candidates: [(date: String?, offset: String?)] = [
            (
                exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                exif?[offsetOriginalKey] as? String
            ),
            (
                exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
                exif?[offsetDigitizedKey] as? String
            )
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXX"
        for candidate in candidates {
            guard let date = candidate.date,
                  let offset = candidate.offset,
                  let value = formatter.date(from: date + offset)
            else { continue }
            return value
        }
        return nil
    }
}
