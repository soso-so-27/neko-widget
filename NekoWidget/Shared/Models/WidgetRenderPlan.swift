import CoreGraphics
import Foundation

enum WidgetCompositionMode: String, Codable, CaseIterable, Sendable {
    case catFullBleed = "cat-full-bleed"
    case mediumUpperFocus = "medium-upper-focus"
    case blurredFitFallback = "blurred-fit-fallback"

    var generatedMetadataKey: String {
        switch self {
        case .catFullBleed: "compositionGeneratedCatFullBleed"
        case .mediumUpperFocus: "compositionGeneratedMediumUpperFocus"
        case .blurredFitFallback: "compositionGeneratedBlurredFitFallback"
        }
    }
}

/// A normalized source rectangle with a top-left origin. It is deliberately
/// distinct from `NormalizedRect`, whose coordinate system is Vision's
/// bottom-left origin.
struct WidgetRenderRect: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var isValid: Bool {
        let values = [x, y, width, height]
        return values.allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1.000_001 && y + height <= 1.000_001
    }

    private enum CodingKeys: String, CodingKey {
        case x, y
        case width = "w"
        case height = "h"
    }
}

struct WidgetSourcePixelSize: Codable, Equatable, Hashable, Sendable {
    var width: Int
    var height: Int

    var isValid: Bool { width > 0 && height > 0 && width <= 16_384 && height <= 16_384 }
}

struct WidgetFamilyRenderPlan: Codable, Equatable, Hashable, Sendable {
    var sourceRect: WidgetRenderRect
    var compositionMode: WidgetCompositionMode

    var isValid: Bool { sourceRect.isValid }
}

struct WidgetRenderPlans: Codable, Equatable, Hashable, Sendable {
    var small: WidgetFamilyRenderPlan
    var medium: WidgetFamilyRenderPlan
    var large: WidgetFamilyRenderPlan

    func plan(for variant: WidgetImageVariant) -> WidgetFamilyRenderPlan {
        switch variant {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    var allAreValid: Bool { small.isValid && medium.isValid && large.isValid }

    /// Strict validation used before a plan is allowed into an encrypted
    /// sharing manifest. Personal manifests are migration-tolerant, whereas a
    /// peer must never render untrusted geometry from disk or the network.
    func isValidForSharing(sourcePixelSize: WidgetSourcePixelSize) -> Bool {
        guard sourcePixelSize.isValid,
              sourcePixelSize.width <= WidgetRenderPlanner.maximumCanonicalPixelDimension,
              sourcePixelSize.height <= WidgetRenderPlanner.maximumCanonicalPixelDimension
        else { return false }

        return WidgetImageVariant.allCases.allSatisfy { variant in
            let candidate = plan(for: variant)
            guard candidate.isValid else { return false }
            switch candidate.compositionMode {
            case .mediumUpperFocus:
                guard variant == .medium else { return false }
            case .blurredFitFallback:
                guard candidate.sourceRect == .fullSource else { return false }
            case .catFullBleed:
                break
            }

            if candidate.compositionMode == .blurredFitFallback { return true }
            let cropWidth = candidate.sourceRect.width * Double(sourcePixelSize.width)
            let cropHeight = candidate.sourceRect.height * Double(sourcePixelSize.height)
            guard cropWidth > 0, cropHeight > 0 else { return false }
            let actual = cropWidth / cropHeight
            let expected = Double(variant.pixelWidth) / Double(variant.pixelHeight)
            // The canonical crop is aligned to source pixels before it is
            // scaled. Permit only the rounding error of that alignment.
            let relativeError = abs(actual - expected) / expected
            return relativeError <= 0.002
        }
    }
}

extension WidgetRenderRect {
    static let fullSource = WidgetRenderRect(CGRect(x: 0, y: 0, width: 1, height: 1))
}

/// The one pure geometry contract used by personal Widget rendering and by
/// encrypted daily sharing metadata. No receiver is allowed to reinterpret a
/// cat bounding box with a different implementation.
enum WidgetRenderPlanner {
    // v6 fixes the shared source normalization contract for UIImage scale and
    // all mirrored orientations. Cache keys include this value.
    static let rendererVersion = "cat-aware-full-bleed-v6"
    static let maximumCanonicalPixelDimension = 2_048
    static let catMarginFraction: CGFloat = 0.08
    static let legacyCatMarginFraction: CGFloat = 0.18
    static let minimumImageMarginFraction: CGFloat = 0.03
    static let mediumUpperFocusFraction: CGFloat = 0.35

    static func plans(
        visionBoundingBox: CGRect?,
        sourcePixelSize: WidgetSourcePixelSize,
        marginFraction: CGFloat = catMarginFraction
    ) -> WidgetRenderPlans {
        WidgetRenderPlans(
            small: plan(
                visionBoundingBox: visionBoundingBox,
                sourcePixelSize: sourcePixelSize,
                variant: .small,
                marginFraction: marginFraction
            ),
            medium: plan(
                visionBoundingBox: visionBoundingBox,
                sourcePixelSize: sourcePixelSize,
                variant: .medium,
                marginFraction: marginFraction
            ),
            large: plan(
                visionBoundingBox: visionBoundingBox,
                sourcePixelSize: sourcePixelSize,
                variant: .large,
                marginFraction: marginFraction
            )
        )
    }

    static func plan(
        visionBoundingBox: CGRect?,
        sourcePixelSize: WidgetSourcePixelSize,
        variant: WidgetImageVariant,
        marginFraction: CGFloat = catMarginFraction
    ) -> WidgetFamilyRenderPlan {
        let fullSource = WidgetFamilyRenderPlan(
            sourceRect: .fullSource,
            compositionMode: .blurredFitFallback
        )
        let imageSize = CGSize(
            width: CGFloat(sourcePixelSize.width),
            height: CGFloat(sourcePixelSize.height)
        )
        let canvasSize = CGSize(
            width: CGFloat(variant.pixelWidth),
            height: CGFloat(variant.pixelHeight)
        )
        guard let visionBoundingBox,
              sourcePixelSize.isValid,
              marginFraction.isFinite,
              marginFraction >= 0,
              [
                  visionBoundingBox.minX,
                  visionBoundingBox.minY,
                  visionBoundingBox.width,
                  visionBoundingBox.height
              ].allSatisfy(\.isFinite)
        else { return fullSource }

        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let photoBoundingBox = CGRect(
            x: visionBoundingBox.minX,
            y: 1 - visionBoundingBox.maxY,
            width: visionBoundingBox.width,
            height: visionBoundingBox.height
        ).standardized.intersection(unitRect)
        guard !photoBoundingBox.isNull,
              photoBoundingBox.width > 0,
              photoBoundingBox.height > 0 else { return fullSource }

        let horizontalMargin = max(
            photoBoundingBox.width * marginFraction,
            minimumImageMarginFraction
        )
        let verticalMargin = max(
            photoBoundingBox.height * marginFraction,
            minimumImageMarginFraction
        )
        let paddedBoundingBox = photoBoundingBox.insetBy(
            dx: -horizontalMargin,
            dy: -verticalMargin
        ).intersection(unitRect)

        let imageAspectRatio = imageSize.width / imageSize.height
        let canvasAspectRatio = canvasSize.width / canvasSize.height
        let cropSize: CGSize
        if imageAspectRatio > canvasAspectRatio {
            cropSize = CGSize(width: canvasAspectRatio / imageAspectRatio, height: 1)
        } else {
            cropSize = CGSize(width: 1, height: imageAspectRatio / canvasAspectRatio)
        }

        if paddedBoundingBox.width <= cropSize.width,
           paddedBoundingBox.height <= cropSize.height {
            return WidgetFamilyRenderPlan(
                sourceRect: WidgetRenderRect(
                    clampedCropRect(
                        centeredAt: CGPoint(x: paddedBoundingBox.midX, y: paddedBoundingBox.midY),
                        cropSize: cropSize
                    )
                ),
                compositionMode: .catFullBleed
            )
        }

        guard variant == .medium else { return fullSource }
        let upperFocus = CGPoint(
            x: paddedBoundingBox.midX,
            y: paddedBoundingBox.minY + paddedBoundingBox.height * mediumUpperFocusFraction
        )
        return WidgetFamilyRenderPlan(
            sourceRect: WidgetRenderRect(
                clampedCropRect(centeredAt: upperFocus, cropSize: cropSize)
            ),
            compositionMode: .mediumUpperFocus
        )
    }

    private static func clampedCropRect(centeredAt focus: CGPoint, cropSize: CGSize) -> CGRect {
        CGRect(
            x: min(max(focus.x - cropSize.width / 2, 0), 1 - cropSize.width),
            y: min(max(focus.y - cropSize.height / 2, 0), 1 - cropSize.height),
            width: cropSize.width,
            height: cropSize.height
        )
    }
}
