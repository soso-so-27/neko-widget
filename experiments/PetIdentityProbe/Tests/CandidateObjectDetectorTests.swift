import XCTest
import UIKit
@testable import PetIdentityProbe

final class CandidateObjectDetectorTests: XCTestCase {
    private typealias Detector = CandidateObjectDetector

    private func image(width: Int = 2, height: Int = 2, rgba: [UInt8]? = nil) throws -> CGImage {
        // Top row red/green, bottom row blue/white. Not a user photograph.
        let bytes = rgba ?? [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func emptyOutput() -> [Float] {
        [Float](repeating: 0, count: Detector.outputRows * Detector.outputColumns)
    }

    private func put(_ values: inout [Float], row: Int, x: Float = 1, y: Float = 2,
                     logWidth: Float = 0, logHeight: Float = 0, objectness: Float = 1,
                     classIndex: Int = 15, probability: Float = 0.8) {
        let offset = row * Detector.outputColumns
        values[offset] = x; values[offset + 1] = y
        values[offset + 2] = logWidth; values[offset + 3] = logHeight
        values[offset + 4] = objectness; values[offset + 5 + classIndex] = probability
    }

    func testSRGBRasterBecomesUnflippedUnnormalizedBGRWithHalfPixelSampling() throws {
        let input = try Detector.preprocess(try image())
        let side = 640, plane = side * side
        XCTAssertEqual(input.values.count, plane * 3)
        XCTAssertEqual(input.resizedWidth, side); XCTAssertEqual(input.resizedHeight, side)
        func pixel(_ x: Int, _ y: Int) -> [Float] {
            (0..<3).map { input.values[$0 * plane + y * side + x] }
        }
        XCTAssertEqual(pixel(0, 0), [0, 0, 255])
        XCTAssertEqual(pixel(639, 0), [0, 255, 0])
        XCTAssertEqual(pixel(0, 639), [255, 0, 0])
        XCTAssertEqual(pixel(639, 639), [255, 255, 255])
        // Destination center -> source (i + .5) * (2 / 640) - .5, not align-corners.
        let fraction = (Double(240) + 0.5) * 2 / 640 - 0.5
        XCTAssertEqual(pixel(240, 0)[1], Float((255 * fraction).rounded()))
        XCTAssertEqual(pixel(240, 0)[2], Float((255 * (1 - fraction)).rounded()))
        XCTAssertTrue(input.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 255 && $0.rounded() == $0 })
    }

    func testLetterboxUsesActualTruncatedDimensionsAndRejectsBadInputs() throws {
        let width = 1_001, height = 701
        let rgba = [UInt8](repeating: 255, count: width * height * 4)
        let input = try Detector.tensor(rgba: rgba, width: width, height: height)
        XCTAssertEqual(input.resizedWidth, 640); XCTAssertEqual(input.resizedHeight, 448)
        for channel in 0..<3 {
            let offset = channel * 640 * 640
            XCTAssertEqual(input.values[offset + 447 * 640 + 639], 255)
            XCTAssertEqual(input.values[offset + 448 * 640], 114)
            XCTAssertEqual(input.values[offset + 639 * 640 + 639], 114)
        }
        XCTAssertThrowsError(try Detector.tensor(rgba: [], width: 0, height: 4))
        XCTAssertThrowsError(try Detector.tensor(rgba: [], width: 1_025, height: 4))
        XCTAssertThrowsError(try Detector.tensor(rgba: [], width: 4, height: 4))
        XCTAssertThrowsError(try Detector.tensor(rgba: [UInt8](repeating: 0, count: 1_024 * 4), width: 1_024, height: 1))
    }

    func testDecodeAllThreeStridesAndPreserveRawTopLeftCoordinates() throws {
        var output = emptyOutput()
        put(&output, row: 0)
        put(&output, row: 80 * 80)
        put(&output, row: 80 * 80 + 40 * 40)
        let decoded = try Detector.decodedBoxes(output, shape: [1, 8400, 85], width: 640, height: 640)
        XCTAssertEqual(decoded.map(\.box), [
            CGRect(x: 4, y: 12, width: 8, height: 8),
            CGRect(x: 8, y: 24, width: 16, height: 16),
            CGRect(x: 16, y: 48, width: 32, height: 32)
        ])
        output = emptyOutput()
        put(&output, row: 0, x: 0, y: 0)
        XCTAssertEqual(try Detector.catBoxes(output, shape: [1, 8400, 85], width: 640, height: 640),
            [CGRect(x: -4, y: -4, width: 8, height: 8)]) // No clipping or Vision bottom-left conversion.
        output = emptyOutput()
        put(&output, row: 81, x: 0, y: 0)
        XCTAssertEqual(try Detector.decodedBoxes(output, shape: [1, 8400, 85], width: 640, height: 640).first?.box,
            CGRect(x: 4, y: 4, width: 8, height: 8)) // x grid varies first.
    }

    func testDecodeRejectsWrongShapeNonfiniteAndInvalidDimensionsEvenAtLowScore() throws {
        let shape = [1, 8400, 85]
        let empty = emptyOutput()
        XCTAssertThrowsError(try Detector.decodedBoxes(empty, shape: [8400, 85], width: 640, height: 640))
        XCTAssertThrowsError(try Detector.decodedBoxes(Array(empty.dropLast()), shape: shape, width: 640, height: 640))
        for (column, value) in [(0, Float.nan), (84, Float.infinity), (2, Float(1_000)),
                                (3, Float(-1_000)), (4, Float(-0.1)), (5, Float(1.1))] {
            var broken = empty
            broken[column] = value
            XCTAssertThrowsError(try Detector.decodedBoxes(broken, shape: shape, width: 640, height: 640), "column \(column)")
        }
        var valid = empty
        put(&valid, row: 0, logWidth: -1, logHeight: -1)
        XCTAssertEqual(try Detector.decodedBoxes(valid, shape: shape, width: 640, height: 640).count, 1)
        // Negative log-width is valid; zero/negative decoded dimensions are not.
    }

    func testScoresMultiplyAndCatFilterFollowsClassAgnosticNMS() throws {
        let shape = [1, 8400, 85]
        var output = emptyOutput()
        put(&output, row: 0, probability: 0.1)
        put(&output, row: 10, probability: 0.3)
        put(&output, row: 20, objectness: 0.5, probability: 0.5)
        XCTAssertEqual(try Detector.decodedBoxes(output, shape: shape, width: 640, height: 640).count, 2)
        XCTAssertEqual(try Detector.catBoxes(output, shape: shape, width: 640, height: 640).count, 1)
        output = emptyOutput()
        put(&output, row: 0, x: 2, classIndex: 16, probability: 0.9)
        put(&output, row: 1, x: 1, probability: 0.8) // Same rectangle as higher-score dog.
        XCTAssertEqual(try Detector.catBoxes(output, shape: shape, width: 640, height: 640), [])
    }

    func testNMSInclusiveIoUBoundaryAndBoundedMalformedInputs() throws {
        func box(_ rect: CGRect, _ score: Float = 0.9) -> Detector.ScoredBox {
            .init(box: rect, score: score, classIndex: 15)
        }
        let large = box(CGRect(x: 0, y: 0, width: 19, height: 9)) // Inclusive area 200.
        let atThreshold = box(CGRect(x: 0, y: 0, width: 8, height: 9), 0.8) // IoU 90/200 == .45.
        let aboveThreshold = box(CGRect(x: 0, y: 0, width: 9, height: 9), 0.8)
        XCTAssertEqual(try Detector.suppressOverlaps([large, atThreshold]).count, 2)
        XCTAssertEqual(try Detector.suppressOverlaps([large, aboveThreshold]).count, 1)
        XCTAssertEqual(try Detector.suppressOverlaps([large, large]).count, 1)
        XCTAssertEqual(try Detector.suppressOverlaps([]), [])
        for rect in [CGRect.null, .infinite, CGRect(x: 0, y: 0, width: -2, height: 3),
                     CGRect(x: 0, y: 0, width: 0, height: 3), CGRect(x: CGFloat.nan, y: 0, width: 2, height: 3)] {
            XCTAssertThrowsError(try Detector.suppressOverlaps([box(rect)]))
        }
        XCTAssertThrowsError(try Detector.suppressOverlaps([box(large.box, .nan)]))
        XCTAssertThrowsError(try Detector.suppressOverlaps(Array(repeating: large, count: 8401)))
    }

    func testCancellationThrowsRatherThanReturningEmptyDetections() async throws {
        let cancelled = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try Detector.tensor(rgba: [], width: 0, height: 0)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let result = await cancelled.value
        XCTAssertTrue(result)
        let cancelledDecode = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try Detector.catBoxes([], shape: [], width: 0, height: 0)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let decodeResult = await cancelledDecode.value
        XCTAssertTrue(decodeResult)
    }

}
