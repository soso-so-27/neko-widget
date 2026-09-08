import CoreGraphics
import Foundation

// Export only an outcome, never the user's crop coordinates, dimensions or pixels.
struct IdentityRecoveredCropReport: Encodable {
    enum Status: String, Encodable, Error {
        case candidatePrepared, noCandidate, multipleCandidates, resultsUnavailable
        case inconsistentResult, invalidBounds, outsidePhoto, tooSmall, cropFailed, previewFailed
        var summary: String {
            switch self {
            case .candidatePrepared: "切り抜き候補を用意しました。猫の範囲が合っているか確認してください。"
            case .noCandidate: "50％表示でも猫の候補がないため、切り抜きはありません。"
            case .multipleCandidates: "候補が複数あるため、切り抜く範囲を決めていません。"
            case .outsidePhoto: "枠が元の写真の外へはみ出したため、切り抜いていません。"
            case .tooSmall: "元画像へ戻した範囲が小さすぎるため、切り抜いていません。"
            default: "検出範囲を安全に切り抜けませんでした。元の写真は変更していません。"
            }
        }
    }
    let status: Status
    let sourceScalePercent = 50
    let method = "inverse-centered-half-padding-to-fetched-original;single-box;contained;min32px;local-preview-only"
    let usedForIdentity = false
    let userConfirmed = false
    let cropSaved = false
}

// Deliberately not Codable. Released with the existing comparison result on leave/background.
struct IdentityRecoveredCropPreview {
    let report: IdentityRecoveredCropReport
    let originalThumbnail: CGImage?
    let cropThumbnail: CGImage?
    let originalBox: CGRect? // Vision normalized bottom-left, for local overlay only.
}

enum IdentityRecoveredCropProbe {
    static func mapHalfBoxToOriginal(_ box: CGRect) -> Result<CGRect, IdentityRecoveredCropReport.Status> {
        guard [box.minX, box.minY, box.width, box.height, box.maxX, box.maxY].allSatisfy(\.isFinite),
              box.width > 0, box.height > 0 else { return .failure(.invalidBounds) }
        // Half-size content occupies [0.25, 0.75] on BOTH axes, including non-square canvases.
        // Allow floating-point roundoff only, not a heuristic padding-overlap threshold.
        let epsilon: CGFloat = 0.000001
        guard box.minX >= 0.25 - epsilon, box.minY >= 0.25 - epsilon,
              box.maxX <= 0.75 + epsilon, box.maxY <= 0.75 + epsilon else { return .failure(.outsidePhoto) }
        let mapped = CGRect(x: (box.minX - 0.25) * 2, y: (box.minY - 0.25) * 2,
            width: box.width * 2, height: box.height * 2)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !mapped.isNull, !mapped.isEmpty else { return .failure(.invalidBounds) }
        return .success(mapped)
    }

    // The same bounds and original-raster crop for both local preview and the separate diagnostic experiment.
    static func recoverCrop(original: CGImage, diagnostic: IdentityAnimalDetectionDiagnostic,
                            acceptedBoxes: [CGRect]) -> Result<(crop: CGImage, box: CGRect), IdentityRecoveredCropReport.Status> {
        guard diagnostic.resultsAvailable else { return .failure(.resultsUnavailable) }
        guard diagnostic.acceptedCatObservationCount == acceptedBoxes.count else { return .failure(.inconsistentResult) }
        guard !acceptedBoxes.isEmpty else { return .failure(.noCandidate) }
        guard acceptedBoxes.count == 1 else { return .failure(.multipleCandidates) }
        let mapped: CGRect
        switch mapHalfBoxToOriginal(acceptedBoxes[0]) {
        case .failure(let status): return .failure(status)
        case .success(let box): mapped = box
        }
        guard let pixels = IdentityImagePipeline.cropRect(mapped, width: original.width, height: original.height) else {
            return .failure(.tooSmall)
        }
        // Crop the original fetched raster, not the 50%-resampled or padded variant.
        guard let crop = original.cropping(to: pixels) else { return .failure(.cropFailed) }
        return .success((crop, mapped))
    }

    static func makePreview(original: CGImage, diagnostic: IdentityAnimalDetectionDiagnostic,
                            acceptedBoxes: [CGRect]) -> IdentityRecoveredCropPreview {
        func result(_ status: IdentityRecoveredCropReport.Status) -> IdentityRecoveredCropPreview {
            IdentityRecoveredCropPreview(report: IdentityRecoveredCropReport(status: status),
                originalThumbnail: thumbnail(original), cropThumbnail: nil, originalBox: nil)
        }
        let crop: CGImage, mapped: CGRect
        switch recoverCrop(original: original, diagnostic: diagnostic, acceptedBoxes: acceptedBoxes) {
        case .failure(let status): return result(status)
        case .success(let recovered): crop = recovered.crop; mapped = recovered.box
        }
        guard let originalThumbnail = thumbnail(original), let cropThumbnail = thumbnail(crop) else {
            return result(.previewFailed)
        }
        return IdentityRecoveredCropPreview(report: IdentityRecoveredCropReport(status: .candidatePrepared),
            originalThumbnail: originalThumbnail, cropThumbnail: cropThumbnail, originalBox: mapped)
    }

    private static func thumbnail(_ image: CGImage) -> CGImage? {
        let fraction = min(1, 480.0 / Double(max(image.width, image.height)))
        return IdentityImagePipeline.resized(image, width: max(1, Int(Double(image.width) * fraction)),
            height: max(1, Int(Double(image.height) * fraction)))
    }
}
