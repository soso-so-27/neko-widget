import XCTest
import UIKit
import SwiftUI
@testable import PetIdentityProbe

final class IdentityRecoveredCropTests: XCTestCase {
    private func diagnostic(_ count: Int = 1, available: Bool = true) -> IdentityAnimalDetectionDiagnostic {
        IdentityAnimalDetectionDiagnostic(observationLabels: Array(repeating:
            [IdentityAnimalLabelSample(label: "Cat", confidence: 0.8)], count: count),
            revision: 2, systemCatLabel: "Cat", resultsAvailable: available)
    }

    private func source() throws -> CGImage {
        // Top-left red, top-right green, bottom blue: detects y-flips on a non-square raster.
        var bytes = [UInt8](repeating: 255, count: 120 * 80 * 4)
        for y in 0..<80 { for x in 0..<120 {
            let offset = (y * 120 + x) * 4
            bytes[offset] = y < 40 && x < 60 ? 255 : 0
            bytes[offset + 1] = y < 40 && x >= 60 ? 255 : 0
            bytes[offset + 2] = y >= 40 ? 255 : 0
        } }
        return try XCTUnwrap(CGImage(width: 120, height: 80, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 480, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }

    func testInversePaddingAndVisionYUseOriginalPixelsWithoutUpscale() throws {
        let image = try source()
        for (box, mapped, rgb) in [
            (CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25), CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), [255, 0, 0]),
            (CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), [0, 255, 0]),
            (CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25), CGRect(x: 0, y: 0, width: 0.5, height: 0.5), [0, 0, 255])
        ] {
            let preview = IdentityRecoveredCropProbe.makePreview(original: image,
                diagnostic: diagnostic(), acceptedBoxes: [box])
            XCTAssertEqual(preview.report.status, .candidatePrepared)
            XCTAssertEqual(preview.originalBox, mapped)
            let crop = try XCTUnwrap(preview.cropThumbnail)
            XCTAssertEqual(crop.width, 60); XCTAssertEqual(crop.height, 40)
            let normalized = try XCTUnwrap(IdentityImageFormatProbe.standardRGB(crop))
            let data = try XCTUnwrap(normalized.dataProvider?.data)
            let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
            let pixel = withExtendedLifetime(data) { (0..<3).map { Int(bytes[20 * normalized.bytesPerRow + 30 * 4 + $0]) } }
            XCTAssertEqual(pixel, rgb)
            XCTAssertEqual(preview.originalThumbnail?.width, 120)
            XCTAssertEqual(preview.originalThumbnail?.height, 80)
        }
        let full = try IdentityRecoveredCropProbe.mapHalfBoxToOriginal(
            CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)).get()
        XCTAssertEqual(full, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testInvalidAmbiguousAndPaddingBoxesDoNotProduceCrops() throws {
        let image = try source()
        let valid = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let cases: [(IdentityAnimalDetectionDiagnostic, [CGRect], IdentityRecoveredCropReport.Status)] = [
            (diagnostic(available: false), [], .resultsUnavailable),
            (diagnostic(0), [], .noCandidate),
            (diagnostic(), [], .inconsistentResult),
            (diagnostic(2), [valid, valid], .multipleCandidates),
            (diagnostic(), [.zero], .invalidBounds),
            (diagnostic(), [CGRect(x: CGFloat.nan, y: 0.3, width: 0.2, height: 0.2)], .invalidBounds),
            (diagnostic(), [CGRect(x: 0.1, y: 0.3, width: 0.2, height: 0.2)], .outsidePhoto),
            (diagnostic(), [CGRect(x: 0.3, y: 0.6, width: 0.2, height: 0.2)], .outsidePhoto),
            (diagnostic(), [CGRect(x: 0.3, y: 0.3, width: 0.05, height: 0.05)], .tooSmall)
        ]
        for (detection, boxes, status) in cases {
            let preview = IdentityRecoveredCropProbe.makePreview(original: image,
                diagnostic: detection, acceptedBoxes: boxes)
            XCTAssertEqual(preview.report.status, status)
            XCTAssertNil(preview.cropThumbnail); XCTAssertNil(preview.originalBox)
            XCTAssertFalse(preview.report.usedForIdentity)
            XCTAssertFalse(preview.report.userConfirmed); XCTAssertFalse(preview.report.cropSaved)
        }
    }

    func testPreviewReusesHalfDetectionAndExportHasNoGeometryOrImages() throws {
        let image = try source()
        var calls: [IdentityDetectorScale] = []
        var preview: IdentityRecoveredCropPreview?
        let comparison = try IdentityDetectorScaleProbe.compareIfNeeded(image, original: diagnostic(0),
            detect: { _, scale in
                calls.append(scale)
                let detection = self.diagnostic(scale == .half ? 1 : 0)
                if scale == .half {
                    preview = IdentityRecoveredCropProbe.makePreview(original: image, diagnostic: detection,
                        acceptedBoxes: [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)])
                }
                return detection
            })
        XCTAssertEqual(calls, [.full, .threeQuarters, .half])
        let crop = try XCTUnwrap(preview)
        XCTAssertEqual(crop.report.status, .candidatePrepared)
        let report = IdentityDetectorComparisonReport(controls: [],
            savedPhoto: IdentityDetectorInputReport(image: image, diagnostic: diagnostic(0), issue: .catNotDetected),
            savedPhotoScaleComparison: comparison, savedPhotoCropCheck: crop.report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(report.json).utf8)) as? [String: Any])
        let exported = try XCTUnwrap(object["savedPhotoCropCheck"] as? [String: Any])
        XCTAssertEqual(Set(exported.keys), ["status", "sourceScalePercent", "method", "usedForIdentity", "userConfirmed", "cropSaved"])
        XCTAssertEqual(exported["sourceScalePercent"] as? Int, 50)
        XCTAssertFalse(report.savedPhoto!.cropUsable)
        XCTAssertEqual(report.savedPhoto!.inputIssue, .catNotDetected)
        XCTAssertFalse(report.savedPhotoGeometryIncluded)
        XCTAssertFalse(report.modelExecuted); XCTAssertFalse(report.identityEvaluated)
        XCTAssertFalse(report.productValidated); XCTAssertFalse(report.productionDataChanged)
    }

    @MainActor func testGeneratedCropPanelRendersAtPhoneWidth() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: IdentityDetectorControlID.orange.rawValue, withExtension: "png"))
        let loaded = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        let source = try XCTUnwrap(IdentityImagePipeline.upright(loaded))
        // Fixed generated-image geometry for layout only, not a claimed detection result.
        let preview = IdentityRecoveredCropProbe.makePreview(original: source, diagnostic: diagnostic(),
            acceptedBoxes: [CGRect(x: 0.375, y: 0.325, width: 0.25, height: 0.35)])
        XCTAssertEqual(preview.report.status, .candidatePrepared)
        let content = IdentityEvaluationView().recoveredCropResults(preview)
            .padding(16).frame(width: 390).background(Color.black).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width, 390)
        XCTAssertGreaterThan(image.size.height, 250)
        let attachment = XCTAttachment(image: image)
        attachment.name = "generated-recovered-crop-panel"
        attachment.lifetime = .keepAlways
        add(attachment) // Generated fixture only; never a selected/private photo.
    }
}
