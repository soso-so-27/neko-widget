import XCTest
import UIKit
@testable import PetIdentityProbe

final class IdentityImagePipelineTests: XCTestCase {
    private func image() throws -> CGImage {
        // 64x64: top half red, bottom half blue; no camera or user photo fixture.
        var bytes = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 { for x in 0..<64 {
            let offset = (y * 64 + x) * 4
            bytes[offset] = y < 32 ? 255 : 0
            bytes[offset + 1] = 0
            bytes[offset + 2] = y < 32 ? 0 : 255
        } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 64 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func testRGBChannelsNormalizationAndTopBottomOrder() throws {
        let data = try XCTUnwrap(IdentityImagePipeline.rgbTensor(try image()))
        XCTAssertEqual(data.length, 3 * 224 * 224 * 4)
        var values = [Float](repeating: 0, count: 3 * 224 * 224)
        values.withUnsafeMutableBytes { data.getBytes($0.baseAddress!, length: data.length) }
        let top = 10 * 224 + 10
        let bottom = 210 * 224 + 10
        XCTAssertEqual(values[top], (1 - 0.485) / 0.229, accuracy: 0.0001)
        XCTAssertEqual(values[224 * 224 + top], -0.456 / 0.224, accuracy: 0.0001)
        XCTAssertEqual(values[2 * 224 * 224 + top], -0.406 / 0.225, accuracy: 0.0001)
        XCTAssertEqual(values[bottom], -0.485 / 0.229, accuracy: 0.0001)
        XCTAssertEqual(values[2 * 224 * 224 + bottom], (1 - 0.406) / 0.225, accuracy: 0.0001)
    }

    func testVisionBottomLeftCropCoordinatesAndBounds() {
        XCTAssertEqual(IdentityImagePipeline.cropRect(CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
            width: 200, height: 100), CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertNil(IdentityImagePipeline.cropRect(CGRect(x: 0, y: 0, width: 0.01, height: 0.01), width: 200, height: 100))
        XCTAssertNil(IdentityImagePipeline.cropRect(CGRect(x: 2, y: 0, width: 1, height: 1), width: 200, height: 100))
        XCTAssertNil(IdentityImagePipeline.cropRect(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), width: 200, height: 100))
    }

    func testUprightImageAndFingerprintAreDeterministic() throws {
        let input = try image()
        let upright = try XCTUnwrap(IdentityImagePipeline.upright(UIImage(cgImage: input)))
        XCTAssertEqual(upright.width, 64)
        XCTAssertEqual(upright.height, 64)
        XCTAssertEqual(IdentityImagePipeline.fingerprint(input), IdentityImagePipeline.fingerprint(upright))
        let first = try XCTUnwrap(IdentityImagePipeline.rgbTensor(input))
        let second = try XCTUnwrap(IdentityImagePipeline.rgbTensor(upright))
        XCTAssertEqual(first as Data, second as Data)
    }

    func testSyntheticImageHasNoCatAndCPUProducesValidEmbedding() throws {
        let input = try image()
        XCTAssertNil(try IdentityImagePipeline.singleCatCrop(input))
        let session = try IdentityCPUSession()
        let vector = try session.embedding(input)
        XCTAssertEqual(vector.count, 512)
        XCTAssertTrue(vector.allSatisfy(\.isFinite))
        XCTAssertLessThan(abs(sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) }) - 1), 0.005)
    }

    @MainActor func testPickerRejectsDuplicatesAndClearInvalidatesResults() {
        let store = IdentityEvaluationStore()
        func select(_ ids: [String?], slot: IdentityPhotoSlot) {
            let request = IdentityPickerRequest(slot: slot)
            store.picker = request
            store.selected(ids, request: request)
        }
        select((0..<5).map { "asset-\($0)" }, slot: .referenceA)
        XCTAssertEqual(store.selections[.referenceA]?.count, 5)
        select((0..<5).map { "asset-\($0)" }, slot: .referenceB)
        XCTAssertNil(store.selections[.referenceB])
        XCTAssertNotNil(store.message)
        select([nil, nil, nil, nil, nil], slot: .referenceB)
        XCTAssertNil(store.selections[.referenceB])
        store.clear()
        XCTAssertTrue(store.selections.isEmpty)
        XCTAssertNil(store.result)
        XCTAssertFalse(store.ready)
    }

    @MainActor func testOldPickerCannotRestoreClearedIDsOrDismissNewPicker() {
        let store = IdentityEvaluationStore()
        let old = IdentityPickerRequest(slot: .referenceA)
        store.picker = old
        store.clear()
        store.selected((0..<5).map { "old-\($0)" }, request: old)
        XCTAssertTrue(store.selections.isEmpty)
        XCTAssertNil(store.picker)
        let current = IdentityPickerRequest(slot: .referenceB)
        store.picker = current
        store.selected((0..<5).map { "old-\($0)" }, request: old)
        XCTAssertEqual(store.picker?.id, current.id)
        XCTAssertTrue(store.selections.isEmpty)
        store.selected((0..<5).map { "new-\($0)" }, request: current)
        XCTAssertEqual(store.selections[.referenceB]?.count, 5)
        XCTAssertNil(store.picker)
    }

    func testShareWrapperDoesNotIncludePhotosOrIndividualPredictions() throws {
        let vector: [Float] = [1] + Array(repeating: 0, count: 511)
        let result = try IdentityEvaluationCore.evaluate(registrationA: Array(repeating: vector, count: 5),
            registrationB: Array(repeating: vector, count: 5), evaluationA: Array(repeating: nil, count: 15),
            evaluationB: Array(repeating: nil, count: 15))
        let run = IdentityPhotoRun(evaluation: result,
            photos: [IdentityLocalPhoto(slot: .evaluationA, index: 7, thumbnail: try image(), embedding: vector, fingerprint: 123)], nearbyTimePairs: 0)
        let text = try XCTUnwrap(IdentityEvaluationExport.json(run))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["aggregate", "preprocessing", "photoFetch", "duplicatePolicy", "reusePolicy",
            "selectionStorage", "inputDiagnostics", "inputDiagnosticScope", "nearbyTimePairs", "osVersion", "photosIncluded", "identifiersIncluded", "individualPredictionsIncluded", "embeddingsIncluded", "productionDataChanged"])
        XCTAssertEqual(object["photosIncluded"] as? Bool, false)
        XCTAssertFalse(text.contains("thumbnail"))
        XCTAssertFalse(text.contains("predictionsA"))
        XCTAssertFalse(text.contains("fingerprint"))
    }

    func testInputDiagnosticsDistinguishDetectorAndCropFailures() throws {
        let input = try image()
        func reason(_ boxes: [CGRect]) -> IdentityInputIssue? {
            if case .failure(let issue) = IdentityImagePipeline.cropResult(input, catBoxes: boxes) { return issue }
            return nil
        }
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(reason([]), .catNotDetected)
        XCTAssertEqual(reason([full, full]), .multipleCats)
        XCTAssertEqual(reason([CGRect(x: 0, y: 0, width: 0.1, height: 0.1)]), .invalidCrop)
        XCTAssertNil(reason([full]))
    }
}
