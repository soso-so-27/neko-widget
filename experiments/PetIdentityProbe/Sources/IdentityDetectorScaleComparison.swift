import CoreGraphics
import Foundation

enum IdentityDetectorScale: Int, CaseIterable, Encodable {
    case full = 100, threeQuarters = 75, half = 50
    var title: String { self == .full ? "大きさそのまま（形式統一）" : "\(rawValue)％に縮小＋余白" }
}

// Counts and pixel format only. No image, asset ID, crop or observation geometry.
struct IdentityDetectorScaleResult: Encodable {
    enum Status: String, Encodable { case completed, conversionFailed, detectionFailed, resultsUnavailable }
    let scalePercent: IdentityDetectorScale
    let status: Status
    let format: IdentityPixelFormat?
    let animalDetection: IdentityAnimalDetectionDiagnostic?

    var summary: String {
        guard status == .completed, let animalDetection else { return "比較できませんでした（0件とは別）" }
        return "猫候補 \(animalDetection.acceptedCatObservationCount)件"
    }
}

struct IdentityDetectorScaleComparison: Encodable {
    enum Status: String, Encodable { case completed, normalizationFailed, incomplete }
    let status: Status
    let normalizedFormat: IdentityPixelFormat?
    let variants: [IdentityDetectorScaleResult]
    let trigger = "original-results-available-and-zero-observations"
    let method = "same-canvas-as-source;srgb8-rgbx32;centered-100-75-50-percent;gray128-padding;no-crop-rotation-upscale"
    let scope = "one-saved-photo;scale-and-padding-comparison;not-isolated-scale-or-cause-or-accuracy-proof"
    let usedForIdentity = false
}

enum IdentityDetectorScaleProbe {
    static func compareIfNeeded(_ image: CGImage, original: IdentityAnimalDetectionDiagnostic?,
        normalize: (CGImage) -> CGImage? = IdentityImageFormatProbe.standardRGB,
        detect: (CGImage, IdentityDetectorScale) throws -> IdentityAnimalDetectionDiagnostic = { image, _ in
            try IdentityImagePipeline.inspectCatCrop(image).diagnostic
        }) throws -> IdentityDetectorScaleComparison? {
        guard let original, original.resultsAvailable, original.observationCount == 0 else { return nil }
        try Task.checkCancellation()
        guard let normalized = normalize(image) else {
            return IdentityDetectorScaleComparison(status: .normalizationFailed, normalizedFormat: nil, variants: [])
        }
        var results: [IdentityDetectorScaleResult] = []
        for scale in IdentityDetectorScale.allCases {
            try Task.checkCancellation()
            let result = try autoreleasepool { () throws -> IdentityDetectorScaleResult in
                guard let rendered = render(normalized, scale: scale) else {
                    return IdentityDetectorScaleResult(scalePercent: scale, status: .conversionFailed,
                        format: nil, animalDetection: nil)
                }
                let format = IdentityPixelFormat(rendered)
                do {
                    let diagnostic = try detect(rendered, scale)
                    try Task.checkCancellation()
                    return IdentityDetectorScaleResult(scalePercent: scale,
                        status: diagnostic.resultsAvailable ? .completed : .resultsUnavailable,
                        format: format, animalDetection: diagnostic)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Never export arbitrary system errors or paths from an image request.
                    return IdentityDetectorScaleResult(scalePercent: scale, status: .detectionFailed,
                        format: format, animalDetection: nil)
                }
            }
            results.append(result)
        }
        try Task.checkCancellation()
        return IdentityDetectorScaleComparison(status: results.allSatisfy { $0.status == .completed } ? .completed : .incomplete,
            normalizedFormat: IdentityPixelFormat(normalized), variants: results)
    }

    // Expects the single normalized raster. All variants keep its canvas and aspect ratio.
    // The full-size control returns it directly: no additional resampling or padding.
    static func render(_ normalized: CGImage, scale: IdentityDetectorScale) -> CGImage? {
        guard normalized.width > 0, normalized.height > 0,
              normalized.width <= 1024, normalized.height <= 1024 else { return nil }
        if scale == .full { return normalized }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: normalized.width, height: normalized.height,
                bitsPerComponent: 8, bytesPerRow: normalized.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        let width = CGFloat(normalized.width), height = CGFloat(normalized.height)
        let fraction = CGFloat(scale.rawValue) / 100
        context.setFillColor(CGColor(colorSpace: space, components: [128.0 / 255, 128.0 / 255, 128.0 / 255, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(normalized, in: CGRect(x: width * (1 - fraction) / 2, y: height * (1 - fraction) / 2,
            width: width * fraction, height: height * fraction))
        return context.makeImage()
    }
}
