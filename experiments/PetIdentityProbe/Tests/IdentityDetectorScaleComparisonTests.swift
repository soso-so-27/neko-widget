import XCTest
import UIKit
@testable import PetIdentityProbe

final class IdentityDetectorScaleComparisonTests: XCTestCase {
    private func diagnostic(_ labels: [[IdentityAnimalLabelSample]] = [], available: Bool = true) -> IdentityAnimalDetectionDiagnostic {
        IdentityAnimalDetectionDiagnostic(observationLabels: labels, revision: 2,
            systemCatLabel: "Cat", resultsAvailable: available)
    }

    private func source() throws -> CGImage {
        // Asymmetric raster catches flips, shifts and stretching; no personal image.
        var bytes = [UInt8](repeating: 255, count: 80 * 48 * 4)
        for y in 0..<48 { for x in 0..<80 {
            let offset = (y * 80 + x) * 4
            bytes[offset] = y < 24 && x < 40 ? 255 : 0
            bytes[offset + 1] = y < 24 && x >= 40 ? 255 : 0
            bytes[offset + 2] = y >= 24 ? 255 : 0
        } }
        return try XCTUnwrap(CGImage(width: 80, height: 48, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 320, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        return withExtendedLifetime(data) { (0..<3).map { Int(bytes[y * image.bytesPerRow + x * 4 + $0]) } }
    }

    func testScalePreservesCanvasAspectOrientationAndAddsSymmetricGrayPadding() throws {
        let normalized = try XCTUnwrap(IdentityImageFormatProbe.standardRGB(try source()))
        let full = try XCTUnwrap(IdentityDetectorScaleProbe.render(normalized, scale: .full))
        XCTAssertTrue(full === normalized) // Control is not resampled a second time.
        for scale in IdentityDetectorScale.allCases {
            let output = try XCTUnwrap(IdentityDetectorScaleProbe.render(normalized, scale: scale))
            let format = IdentityPixelFormat(output)
            XCTAssertEqual(format.width, 80); XCTAssertEqual(format.height, 48)
            XCTAssertEqual(format.colorSpace, "sRGB"); XCTAssertEqual(format.bitsPerComponent, 8)
            XCTAssertEqual(format.bitsPerPixel, 32); XCTAssertFalse(format.floatComponents)
            let fraction = Double(scale.rawValue) / 100
            for (x, y, rgb) in [(8, 8, [255, 0, 0]), (72, 8, [0, 255, 0]), (8, 40, [0, 0, 255])] {
                let px = Int(80 * (1 - fraction) / 2 + Double(x) * fraction)
                let py = Int(48 * (1 - fraction) / 2 + Double(y) * fraction)
                XCTAssertEqual(try pixel(output, px, py), rgb)
            }
            if scale != .full {
                for (x, y) in [(0, 0), (79, 0), (0, 47), (79, 47), (40, 0), (0, 24)] {
                    XCTAssertEqual(try pixel(output, x, y), [128, 128, 128])
                }
            }
        }
    }

    func testOnlyRawZeroTriggersExactlyThreeComparisonsAndKeepsBaselineFailure() throws {
        let image = try source()
        let cat = diagnostic([[IdentityAnimalLabelSample(label: "Cat", confidence: 0.8)]])
        let weakCat = diagnostic([[IdentityAnimalLabelSample(label: "Cat", confidence: 0.1)]])
        let dog = diagnostic([[IdentityAnimalLabelSample(label: "Dog", confidence: 0.8)]])
        for original in [nil, diagnostic(available: false), cat, weakCat, dog] {
            XCTAssertNil(try IdentityDetectorScaleProbe.compareIfNeeded(image, original: original,
                normalize: { _ in XCTFail("not a raw-zero result"); return nil },
                detect: { _, _ in XCTFail("must not detect"); return cat }))
        }
        var calls = 0, conversions = 0
        let compared = try XCTUnwrap(IdentityDetectorScaleProbe.compareIfNeeded(image, original: diagnostic(),
            normalize: { conversions += 1; return IdentityImageFormatProbe.standardRGB($0) },
            detect: { _, _ in calls += 1; return cat }))
        XCTAssertEqual(conversions, 1); XCTAssertEqual(calls, 3)
        XCTAssertEqual(compared.variants.map(\.scalePercent), IdentityDetectorScale.allCases)
        XCTAssertEqual(compared.status, .completed); XCTAssertFalse(compared.usedForIdentity)
        let report = IdentityDetectorComparisonReport(controls: [],
            savedPhoto: IdentityDetectorInputReport(image: image, diagnostic: diagnostic(), issue: .catNotDetected),
            savedPhotoScaleComparison: compared)
        XCTAssertFalse(report.savedPhoto!.cropUsable)
        XCTAssertEqual(report.savedPhoto!.inputIssue, .catNotDetected)
        XCTAssertFalse(report.modelExecuted); XCTAssertFalse(report.identityEvaluated)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(report.json).utf8)) as? [String: Any])
        XCTAssertEqual(object["protocolIdentifier"] as? String, "pet-detector-controls-v3")
        let scale = try XCTUnwrap(object["savedPhotoScaleComparison"] as? [String: Any])
        XCTAssertEqual(Set(scale.keys), ["status", "normalizedFormat", "variants", "trigger", "method", "scope", "usedForIdentity"])
        for variant in try XCTUnwrap(scale["variants"] as? [[String: Any]]) {
            XCTAssertEqual(Set(variant.keys), ["scalePercent", "status", "format", "animalDetection"])
        }
        for key in ["photosIncluded", "identifiersIncluded", "embeddingsIncluded", "savedPhotoGeometryIncluded", "productValidated", "productionDataChanged"] {
            XCTAssertEqual(object[key] as? Bool, false)
        }
    }

    func testFailuresAreNotZeroResultsAndCancellationStopsRemainingVariants() throws {
        let image = try source()
        let failed = try XCTUnwrap(IdentityDetectorScaleProbe.compareIfNeeded(image, original: diagnostic(),
            normalize: { _ in nil }, detect: { _, _ in XCTFail("must not detect"); return self.diagnostic() }))
        XCTAssertEqual(failed.status, .normalizationFailed); XCTAssertTrue(failed.variants.isEmpty)
        var calls = 0
        let incomplete = try XCTUnwrap(IdentityDetectorScaleProbe.compareIfNeeded(image, original: diagnostic(), detect: { _, _ in
            calls += 1
            if calls == 1 { throw NSError(domain: "private-photo-id", code: 1) }
            return self.diagnostic(available: calls != 2)
        }))
        XCTAssertEqual(incomplete.status, .incomplete)
        XCTAssertEqual(incomplete.variants.map(\.status), [.detectionFailed, .resultsUnavailable, .completed])
        XCTAssertNil(incomplete.variants[0].animalDetection)
        XCTAssertNil(incomplete.variants[1].animalDetection?.observationCount)
        XCTAssertEqual(incomplete.variants[2].animalDetection?.observationCount, 0)
        XCTAssertFalse(String(data: try JSONEncoder().encode(incomplete), encoding: .utf8)!.contains("private-photo-id"))
        calls = 0
        XCTAssertThrowsError(try IdentityDetectorScaleProbe.compareIfNeeded(image, original: diagnostic(), detect: { _, _ in
            calls += 1
            throw CancellationError()
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testGeneratedControlUsesActualVisionAtEachScaleWithoutUserPhotos() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: IdentityDetectorControlID.orange.rawValue, withExtension: "png"))
        let loaded = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        let source = try XCTUnwrap(IdentityImagePipeline.upright(loaded))
        let normalized = try XCTUnwrap(IdentityImageFormatProbe.standardRGB(source))
        for scale in IdentityDetectorScale.allCases {
            let rendered = try XCTUnwrap(IdentityDetectorScaleProbe.render(normalized, scale: scale))
            let inspected = try IdentityImagePipeline.inspectCatCrop(rendered)
            let diagnostic = inspected.diagnostic
            XCTAssertTrue(diagnostic.resultsAvailable)
            if scale == .full { XCTAssertEqual(diagnostic.acceptedCatObservationCount, 1) }
            // Infrastructure check only; not a reproduction of the private close-up photo.
            print("PROBE_GENERATED_SCALE percent=\(scale.rawValue) cats=\(diagnostic.acceptedCatObservationCount)")
            if scale == .half {
                let preview = IdentityRecoveredCropProbe.makePreview(original: source,
                    diagnostic: diagnostic, acceptedBoxes: inspected.acceptedBoxes)
                XCTAssertEqual(preview.report.status, .candidatePrepared)
                XCTAssertNotNil(preview.cropThumbnail)
                print("PROBE_GENERATED_RECOVERED_CROP status=\(preview.report.status.rawValue)")
            }
        }
    }
}
