import XCTest
import UIKit
@testable import PetIdentityProbe

final class IdentityImageFormatComparisonTests: XCTestCase {
    private func image(space: CFString = CGColorSpace.sRGB) throws -> CGImage {
        // Non-square: top-left red, top-right green, bottom blue.
        let width = 80, height = 48
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            bytes[offset] = y < 24 && x < 40 ? 255 : 0
            bytes[offset + 1] = y < 24 && x >= 40 ? 255 : 0
            bytes[offset + 2] = y >= 24 ? 255 : 0
        } }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: space)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    }

    private func diagnostic(_ labels: [[IdentityAnimalLabelSample]] = [], available: Bool = true) -> IdentityAnimalDetectionDiagnostic {
        IdentityAnimalDetectionDiagnostic(observationLabels: labels, revision: 2,
            systemCatLabel: "Cat", resultsAvailable: available)
    }

    func testStandardRGBPreservesNonSquareSizeCornersAndUsesEightBitSRGB() throws {
        let source = try image()
        let output = try XCTUnwrap(IdentityImageFormatProbe.standardRGB(source))
        let format = IdentityPixelFormat(output)
        XCTAssertEqual(format.width, 80)
        XCTAssertEqual(format.height, 48)
        XCTAssertEqual(format.bitsPerComponent, 8)
        XCTAssertEqual(format.bitsPerPixel, 32)
        XCTAssertEqual(format.colorSpace, "sRGB")
        XCTAssertFalse(format.floatComponents)
        let data = try XCTUnwrap(output.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        withExtendedLifetime(data) {
            for (x, y, rgb) in [(8, 8, [255, 0, 0]), (72, 8, [0, 255, 0]), (8, 40, [0, 0, 255])] {
                let offset = y * output.bytesPerRow + x * 4
                XCTAssertEqual((0..<3).map { Int(bytes[offset + $0]) }, rgb)
            }
        }
        let p3 = try XCTUnwrap(IdentityImageFormatProbe.standardRGB(try image(space: CGColorSpace.displayP3)))
        XCTAssertEqual(IdentityPixelFormat(p3).colorSpace, "sRGB")
        XCTAssertEqual(p3.width, 80)
        XCTAssertEqual(p3.height, 48)
    }

    func testOnlyAvailableZeroObservationsTriggerOneConversionAndOneDetection() throws {
        let source = try image()
        var conversionCount = 0, detectionCount = 0
        let cat = diagnostic([[IdentityAnimalLabelSample(label: "Cat", confidence: 0.8)]])
        let dog = diagnostic([[IdentityAnimalLabelSample(label: "Dog", confidence: 0.8)]])
        for original in [nil, diagnostic(available: false), cat, dog] {
            let result = try IdentityImageFormatProbe.compareIfNeeded(source, original: original,
                convert: { _ in conversionCount += 1; return source },
                detect: { _ in detectionCount += 1; return cat })
            XCTAssertNil(result)
        }
        XCTAssertEqual(conversionCount, 0)
        XCTAssertEqual(detectionCount, 0)
        let result = try XCTUnwrap(IdentityImageFormatProbe.compareIfNeeded(source, original: diagnostic(),
            convert: { _ in conversionCount += 1; return source },
            detect: { _ in detectionCount += 1; return cat }))
        XCTAssertEqual(conversionCount, 1)
        XCTAssertEqual(detectionCount, 1)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.normalizedDetection?.acceptedCatObservationCount, 1)
        XCTAssertFalse(result.usedForIdentity)
    }

    func testFailuresRemainDistinctFromZeroAndCancellationIsRethrown() throws {
        let source = try image()
        let conversionFailed = try XCTUnwrap(IdentityImageFormatProbe.compareIfNeeded(source, original: diagnostic(),
            convert: { _ in nil }, detect: { _ in XCTFail("must not detect"); return self.diagnostic() }))
        XCTAssertEqual(conversionFailed.status, .conversionFailed)
        XCTAssertNil(conversionFailed.normalizedDetection)
        let detectionFailed = try XCTUnwrap(IdentityImageFormatProbe.compareIfNeeded(source, original: diagnostic(),
            detect: { _ in throw NSError(domain: "private-photo-id", code: 1) }))
        XCTAssertEqual(detectionFailed.status, .detectionFailed)
        XCTAssertNil(detectionFailed.normalizedDetection)
        XCTAssertFalse(String(data: try JSONEncoder().encode(detectionFailed), encoding: .utf8)!.contains("private-photo-id"))
        XCTAssertThrowsError(try IdentityImageFormatProbe.compareIfNeeded(source, original: diagnostic(),
            detect: { _ in throw CancellationError() })) { XCTAssertTrue($0 is CancellationError) }
        let empty = try XCTUnwrap(IdentityImageFormatProbe.compareIfNeeded(source, original: diagnostic(),
            detect: { _ in self.diagnostic() }))
        XCTAssertEqual(empty.status, .completed)
        XCTAssertEqual(empty.normalizedDetection?.observationCount, 0)
        XCTAssertNotEqual(empty.summary, detectionFailed.summary)
    }

    func testInputExportKeepsBaselineFailureEvenWhenComparisonFindsCat() throws {
        let source = try image()
        let original = diagnostic()
        let compared = try IdentityImageFormatProbe.compareIfNeeded(source, original: original,
            detect: { _ in self.diagnostic([[IdentityAnimalLabelSample(label: "Cat", confidence: 0.8)]]) })
        let report = IdentityInputReport(imageReadable: true, singleCatDetected: false,
            cropUsable: false, modelOutputValidated: false, inputIssue: .catNotDetected, modelFailure: nil,
            imageWidth: 80, imageHeight: 48, cropWidth: nil, cropHeight: nil, runtimeVersion: "1.24.2",
            animalDetection: original, formatComparison: compared)
        let json = try XCTUnwrap(IdentityInputExport.json(report))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["protocolIdentifier"] as? String, "pet-identity-input-diagnostic-v3")
        XCTAssertEqual(object["inputIssue"] as? String, "catNotDetected")
        for key in ["singleCatDetected", "cropUsable", "modelOutputValidated", "photosIncluded", "identifiersIncluded", "embeddingsIncluded", "identityEvaluated", "productValidated", "productionDataChanged"] {
            XCTAssertEqual(object[key] as? Bool, false)
        }
        let comparison = try XCTUnwrap(object["formatComparison"] as? [String: Any])
        XCTAssertEqual(Set(comparison.keys), ["status", "originalFormat", "normalizedFormat", "normalizedDetection", "method", "trigger", "usedForIdentity", "scope"])
        let pixels = try XCTUnwrap(comparison["originalFormat"] as? [String: Any])
        XCTAssertEqual(Set(pixels.keys), ["width", "height", "bitsPerComponent", "bitsPerPixel", "floatComponents", "colorSpace"])
        XCTAssertNil(object["thumbnail"])
        XCTAssertFalse(json.contains("boundingBox"))
        XCTAssertFalse(json.contains("localIdentifier"))
    }
}
