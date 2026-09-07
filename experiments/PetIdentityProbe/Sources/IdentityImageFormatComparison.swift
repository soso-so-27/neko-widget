import CoreGraphics
import Foundation

/// Pixel representation only. Never encode pixels, ICC data, asset IDs or paths.
struct IdentityPixelFormat: Encodable {
    let width: Int
    let height: Int
    let bitsPerComponent: Int
    let bitsPerPixel: Int
    let floatComponents: Bool
    let colorSpace: String

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        bitsPerComponent = image.bitsPerComponent
        bitsPerPixel = image.bitsPerPixel
        floatComponents = image.bitmapInfo.contains(.floatComponents)
        let name = image.colorSpace?.name as String?
        if name == (CGColorSpace.sRGB as String) { colorSpace = "sRGB" }
        else if name == (CGColorSpace.displayP3 as String) { colorSpace = "Display-P3" }
        else if name == (CGColorSpace.extendedSRGB as String) { colorSpace = "extended-sRGB" }
        else if name == (CGColorSpace.extendedLinearSRGB as String) { colorSpace = "extended-linear-sRGB" }
        else { colorSpace = "other-or-unspecified" }
    }
}

struct IdentityImageFormatComparison: Encodable {
    enum Status: String, Encodable { case completed, conversionFailed, detectionFailed }
    let status: Status
    let originalFormat: IdentityPixelFormat
    let normalizedFormat: IdentityPixelFormat?
    let normalizedDetection: IdentityAnimalDetectionDiagnostic?
    let method = "same-raster-size-opaque-srgb8-rgbx32;no-rotation-crop-or-upscale"
    let trigger = "original-results-available-and-zero-observations"
    let usedForIdentity = false
    let scope = "one-selected-photo;format-comparison-only;not-a-cause-or-accuracy-proof"

    var summary: String {
        guard status == .completed, let result = normalizedDetection, result.resultsAvailable else {
            return "画像形式の比較を完了できませんでした。0件だったという意味ではありません。"
        }
        if result.acceptedCatObservationCount > 0 {
            return "画像形式を揃えた比較では、猫の候補が見つかりました。まだ個体識別には使っていません。"
        }
        if result.observationCount == 0 {
            return "画像形式を揃えても、動物の候補は見つかりませんでした。"
        }
        return "画像形式を揃えると動物の候補が返りましたが、猫の採用条件は満たしませんでした。"
    }
}

enum IdentityImageFormatProbe {
    static func compareIfNeeded(_ image: CGImage, original: IdentityAnimalDetectionDiagnostic?,
        convert: (CGImage) -> CGImage? = standardRGB,
        detect: (CGImage) throws -> IdentityAnimalDetectionDiagnostic = {
            try IdentityImagePipeline.inspectCatCrop($0).diagnostic
        }) throws -> IdentityImageFormatComparison? {
        guard let original, original.resultsAvailable, original.observationCount == 0 else { return nil }
        let format = IdentityPixelFormat(image)
        guard let converted = convert(image) else {
            return IdentityImageFormatComparison(status: .conversionFailed, originalFormat: format,
                normalizedFormat: nil, normalizedDetection: nil)
        }
        let normalizedFormat = IdentityPixelFormat(converted)
        do {
            return IdentityImageFormatComparison(status: .completed, originalFormat: format,
                normalizedFormat: normalizedFormat, normalizedDetection: try detect(converted))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Keep raw system errors and any embedded file identifiers out of the report.
            return IdentityImageFormatComparison(status: .detectionFailed, originalFormat: format,
                normalizedFormat: normalizedFormat, normalizedDetection: nil)
        }
    }

    static func standardRGB(_ image: CGImage) -> CGImage? {
        guard image.width > 0, image.height > 0, image.width <= 1024, image.height <= 1024,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
