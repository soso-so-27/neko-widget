import XCTest
import UIKit
@testable import PetIdentityProbe

// Fixed development experiment, not private-photo evaluation or an adoption assertion.
// The 60% tiles, 2px artificial-edge guard and >1px separation are not fitted here.
final class CandidateTileProbeTests: XCTestCase {
    private enum TestFailure: Error { case detector, unexpectedCall }

    private func diagnostic(_ count: Int = 1, available: Bool = true) -> IdentityAnimalDetectionDiagnostic {
        .init(observationLabels: Array(repeating: [.init(label: "Cat", confidence: 0.8)], count: count),
              revision: 2, systemCatLabel: "Cat", resultsAvailable: available)
    }

    private func raster(width: Int = 213, height: Int = 213) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    // Convert a tile-local top-left pixel rect into the detector's bottom-left unit box.
    private func visionBox(_ pixels: CGRect, tile: CGRect) -> CGRect {
        CGRect(x: pixels.minX / tile.width, y: 1 - pixels.maxY / tile.height,
               width: pixels.width / tile.width, height: pixels.height / tile.height)
    }

    func testFourIntegerTilesUseCeilingAndActualOddRasterBounds() {
        let tiles = CandidateTileProbe.tileRects(width: 1001, height: 701)
        XCTAssertEqual(tiles.count, 4)
        for x in [0, 400] { for y in [0, 280] {
            XCTAssertEqual(tiles.filter { $0 == CGRect(x: x, y: y, width: 601, height: 421) }.count, 1)
        } }
        XCTAssertEqual(CandidateTileProbe.tileRects(width: 64, height: 64).count, 4)
        XCTAssertEqual(CandidateTileProbe.tileRects(width: 1024, height: 1024).count, 4)
        for invalid in [-1, 0, 63, 1025, Int.max] {
            XCTAssertTrue(CandidateTileProbe.tileRects(width: invalid, height: 128).isEmpty)
            XCTAssertTrue(CandidateTileProbe.tileRects(width: 128, height: invalid).isEmpty)
        }
    }

    func testMappingUsesActualTileAndFlipsVisionYWithoutNominalFractionDrift() throws {
        let tile = CGRect(x: 400, y: 280, width: 601, height: 421)
        let mapped = try XCTUnwrap(CandidateTileProbe.mappedBox(
            CGRect(x: 0.25, y: 0.125, width: 0.5, height: 0.5), tile: tile, width: 1001, height: 701))
        // The local pixel crop encloses fractional detector bounds before adding
        // the actual tile origin: (150,157,301,212), not nominal 40% offsets.
        XCTAssertEqual(mapped, CGRect(x: 550, y: 437, width: 301, height: 212))
    }

    func testArtificialEdgesRejectTwoPixelsButOriginalPhotoEdgesRemainEligible() throws {
        let upper = CGRect(x: 0, y: 0, width: 128, height: 128)
        let lower = CGRect(x: 85, y: 85, width: 128, height: 128)
        func map(_ pixels: CGRect, tile: CGRect) -> CGRect? {
            CandidateTileProbe.mappedBox(visionBox(pixels, tile: tile), tile: tile, width: 213, height: 213)
        }
        // Top-left tile: right and bottom are artificial; left and top are original edges.
        XCTAssertNil(map(CGRect(x: 94, y: 16, width: 32, height: 32), tile: upper))
        XCTAssertNil(map(CGRect(x: 16, y: 94, width: 32, height: 32), tile: upper))
        XCTAssertNotNil(map(CGRect(x: 93, y: 16, width: 32, height: 32), tile: upper))
        XCTAssertNotNil(map(CGRect(x: 16, y: 93, width: 32, height: 32), tile: upper))
        XCTAssertNotNil(map(CGRect(x: 0, y: 16, width: 32, height: 32), tile: upper))
        XCTAssertNotNil(map(CGRect(x: 16, y: 0, width: 32, height: 32), tile: upper))
        // Bottom-right tile reverses which edges are artificial. Two pixels is still rejected.
        XCTAssertNil(map(CGRect(x: 2, y: 40, width: 32, height: 32), tile: lower))
        XCTAssertNil(map(CGRect(x: 40, y: 2, width: 32, height: 32), tile: lower))
        XCTAssertNotNil(map(CGRect(x: 3, y: 40, width: 32, height: 32), tile: lower))
        XCTAssertNotNil(map(CGRect(x: 40, y: 3, width: 32, height: 32), tile: lower))
        XCTAssertNotNil(map(CGRect(x: 96, y: 40, width: 32, height: 32), tile: lower))
        XCTAssertNotNil(map(CGRect(x: 40, y: 96, width: 32, height: 32), tile: lower))
        XCTAssertNil(map(CGRect(x: 16, y: 16, width: 31, height: 32), tile: upper))
        XCTAssertNil(map(CGRect(x: 16, y: 16, width: 32, height: 31), tile: upper))
        XCTAssertEqual(map(CGRect(x: 16, y: 16, width: 32, height: 32), tile: upper),
                       CGRect(x: 16, y: 16, width: 32, height: 32))
    }

    func testBadBoxesTilesAndDimensionsCannotBecomeEvidenceByClipping() {
        let tile = CGRect(x: 0, y: 0, width: 128, height: 128)
        let valid = CGRect(x: 0.125, y: 0.625, width: 0.25, height: 0.25)
        let invalidBoxes: [CGRect] = [.null, .infinite, .zero,
            CGRect(x: CGFloat.nan, y: 0.2, width: 0.5, height: 0.5),
            CGRect(x: 0.2, y: 0.2, width: CGFloat.infinity, height: 0.5),
            CGRect(x: 0.2, y: 0.2, width: -0.5, height: 0.5),
            CGRect(x: -0.01, y: 0.5, width: 0.5, height: 0.5),
            CGRect(x: 0.5, y: 0.5, width: 0.51, height: 0.5)]
        for box in invalidBoxes {
            XCTAssertNil(CandidateTileProbe.mappedBox(box, tile: tile, width: 213, height: 213))
        }
        for invalidTile in [CGRect.null, .infinite, .zero,
                            CGRect(x: -1, y: 0, width: 128, height: 128),
                            CGRect(x: 100, y: 100, width: 128, height: 128)] {
            XCTAssertNil(CandidateTileProbe.mappedBox(valid, tile: invalidTile, width: 213, height: 213))
        }
        XCTAssertNil(CandidateTileProbe.mappedBox(valid, tile: tile, width: 63, height: 213))
        XCTAssertNil(CandidateTileProbe.mappedBox(valid, tile: tile, width: 213, height: 1025))
    }

    func testPairRequiresMoreThanOnePixelGapAndRejectsDuplicatesOrInvalidBounds() {
        let a = CGRect(x: 10, y: 10, width: 40, height: 40)
        for other in [a, CGRect(x: 20, y: 20, width: 10, height: 10),
                      CGRect(x: 40, y: 10, width: 40, height: 40),
                      CGRect(x: 50, y: 10, width: 40, height: 40),
                      CGRect(x: 51, y: 10, width: 40, height: 40),
                      CGRect(x: 10, y: 51, width: 40, height: 40),
                      CGRect.null, .infinite, .zero,
                      CGRect(x: CGFloat.nan, y: 10, width: 40, height: 40)] {
            XCTAssertFalse(CandidateTileProbe.hasSeparatedPair([a, other]))
        }
        XCTAssertFalse(CandidateTileProbe.hasSeparatedPair([]))
        XCTAssertFalse(CandidateTileProbe.hasSeparatedPair([a]))
        let b = CGRect(x: 51.001, y: 10, width: 40, height: 40)
        XCTAssertTrue(CandidateTileProbe.hasSeparatedPair([a, b]))
        XCTAssertTrue(CandidateTileProbe.hasSeparatedPair([b, a]))
        XCTAssertTrue(CandidateTileProbe.hasSeparatedPair([a, CGRect(x: 10, y: 51.001, width: 40, height: 40)]))
    }

    func testAllFourRequestsMustFinishAndCrossTileDuplicatesAreNotSeparate() throws {
        let image = try raster()
        var calls = 0
        let separated = try CandidateTileProbe.check(image) { tileImage in
            calls += 1
            XCTAssertEqual(tileImage.width, 128); XCTAssertEqual(tileImage.height, 128)
            return (self.diagnostic(), [CGRect(x: 0.125, y: 0.625, width: 0.25, height: 0.25)])
        }
        XCTAssertEqual(calls, 4); XCTAssertEqual(separated.requests, 4)
        XCTAssertEqual(separated.validRegions, 4); XCTAssertEqual(separated.status, .separateRegions)
        XCTAssertTrue(separated.withholdsCandidate)

        let tiles = CandidateTileProbe.tileRects(width: image.width, height: image.height)
        let sameOriginalRegion = CGRect(x: 90, y: 90, width: 32, height: 32)
        calls = 0
        let duplicates = try CandidateTileProbe.check(image) { _ in
            let tile = tiles[calls]; calls += 1
            let local = sameOriginalRegion.offsetBy(dx: -tile.minX, dy: -tile.minY)
            return (self.diagnostic(), [self.visionBox(local, tile: tile)])
        }
        XCTAssertEqual(calls, 4); XCTAssertEqual(duplicates.requests, 4)
        XCTAssertEqual(duplicates.validRegions, 4); XCTAssertEqual(duplicates.status, .noSeparateRegions)
        XCTAssertFalse(duplicates.withholdsCandidate)
        let empty = try CandidateTileProbe.check(image) { _ in (self.diagnostic(0), []) }
        XCTAssertEqual(empty.status, .noSeparateRegions); XCTAssertEqual(empty.requests, 4)
        XCTAssertEqual(empty.validRegions, 0); XCTAssertFalse(empty.withholdsCandidate)
    }

    func testMissingMismatchedExcessiveAndFailedDetectionsAreIncomplete() throws {
        let image = try raster()
        let box = CGRect(x: 0.125, y: 0.625, width: 0.25, height: 0.25)
        for condition in 0..<4 {
            var calls = 0
            let result = try CandidateTileProbe.check(image) { _ in
                calls += 1
                switch condition {
                case 0: return (self.diagnostic(0, available: false), [])
                case 1: return (self.diagnostic(2), [box])
                case 2: return (self.diagnostic(5), Array(repeating: box, count: 5))
                default: throw TestFailure.detector
                }
            }
            XCTAssertEqual(result.status, .incomplete); XCTAssertFalse(result.withholdsCandidate)
            XCTAssertEqual(result.requests, calls); XCTAssertTrue((1...4).contains(calls))
        }
        var calls = 0
        let lateFailure = try CandidateTileProbe.check(image) { _ in
            calls += 1
            if calls == 4 { throw TestFailure.detector }
            return (self.diagnostic(), [box])
        }
        XCTAssertEqual(calls, 4); XCTAssertEqual(lateFailure.requests, 4)
        XCTAssertEqual(lateFailure.status, .incomplete); XCTAssertFalse(lateFailure.withholdsCandidate)
    }

    func testUnsupportedRasterSkipsDetectionAndCancellationIsNotAnIncompleteResult() throws {
        for image in [try raster(width: 63, height: 64), try raster(width: 1025, height: 64)] {
            var calls = 0
            let result = try CandidateTileProbe.check(image) { _ in
                calls += 1; throw TestFailure.unexpectedCall
            }
            XCTAssertEqual(calls, 0); XCTAssertEqual(result.requests, 0)
            XCTAssertEqual(result.status, .incomplete); XCTAssertFalse(result.withholdsCandidate)
        }
        var calls = 0
        XCTAssertThrowsError(try CandidateTileProbe.check(raster()) { _ in
            calls += 1
            if calls == 2 { throw CancellationError() }
            return (self.diagnostic(0), [])
        }) { error in XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 2)
    }

    func testAlreadyCancelledTaskDoesNotInvokeDetector() async throws {
        let image = try raster()
        let cancelledWithoutRequest = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var calls = 0
            do {
                _ = try CandidateTileProbe.check(image) { _ in
                    calls += 1; throw TestFailure.unexpectedCall
                }
                return false
            } catch is CancellationError { return calls == 0 }
            catch { return false }
        }.value
        XCTAssertTrue(cancelledWithoutRequest)
    }

    private enum Corner: String, CaseIterable {
        case topLeft = "top-left", topRight = "top-right", bottomLeft = "bottom-left", bottomRight = "bottom-right"
    }
    private struct Fixture {
        let name: String
        let cats: Int
        let render: () throws -> CGImage
    }
    private struct Observation: Encodable {
        let fixture: String
        let expectedCats: Int
        let rawAccepted: Int
        let originalCropUsable: Bool
        let tileStatus: String
        let requests: Int
        let validRegions: Int
        let withheld: Bool
        let identityDistanceEvaluated = false
    }

    func testFixedThreeSinglesTwelveSeamControlsAndSixPairsMeasureWithoutCertifyingAdoption() throws {
        let bundle = Bundle(for: Self.self)
        let controls: [(name: String, image: CGImage)] = try IdentityDetectorControlID.allCases.map { control in
            let url = try XCTUnwrap(bundle.url(forResource: control.rawValue, withExtension: "png"))
            let source = try XCTUnwrap(UIImage(contentsOfFile: url.path))
            return (control.rawValue, try XCTUnwrap(IdentityImagePipeline.upright(source)))
        }
        var fixtures = controls.map { control in
            Fixture(name: control.name, cats: 1, render: { control.image })
        }
        // These 12 placements are fixed before any Vision result: no crop, search or rotation.
        for control in controls { for corner in Corner.allCases {
            fixtures.append(Fixture(name: "\(control.name)-single75-\(corner.rawValue)", cats: 1,
                render: { try self.makeCorner(control.image, corner: corner) }))
        } }
        // Same six pair layouts as CandidateSecondScaleExperimentTests.
        for i in controls.indices { for j in controls.indices where j > i {
            let a = controls[i], b = controls[j]
            for vertical in [false, true] {
                fixtures.append(Fixture(name: "\(a.name)+\(b.name)-\(vertical ? "vertical" : "horizontal")", cats: 2,
                    render: { try self.makePair(a.image, b.image, vertical: vertical) }))
            }
        } }
        XCTAssertEqual(fixtures.count, 21); XCTAssertEqual(Set(fixtures.map(\.name)).count, 21)
        var rows: [Observation] = []
        for fixture in fixtures {
            let row = try autoreleasepool { () throws -> Observation in
                let image = try fixture.render()
                let original = try IdentityImagePipeline.inspectCatCrop(image)
                XCTAssertTrue(original.diagnostic.resultsAvailable)
                XCTAssertEqual(original.diagnostic.acceptedCatObservationCount, original.acceptedBoxes.count)
                guard case .success = original.result else {
                    return Observation(fixture: fixture.name, expectedCats: fixture.cats,
                        rawAccepted: original.acceptedBoxes.count, originalCropUsable: false,
                        tileStatus: "notEligibleOriginal", requests: 0, validRegions: 0, withheld: false)
                }
                // This isolates the detector hypothesis; no identity vectors/references are evaluated.
                let check = try CandidateTileProbe.check(image)
                XCTAssertTrue((0...4).contains(check.requests))
                XCTAssertTrue((0...16).contains(check.validRegions))
                if check.status != .incomplete { XCTAssertEqual(check.requests, 4) }
                XCTAssertEqual(check.withholdsCandidate, check.status == .separateRegions && check.requests == 4)
                return Observation(fixture: fixture.name, expectedCats: fixture.cats,
                    rawAccepted: original.acceptedBoxes.count, originalCropUsable: true,
                    tileStatus: check.status.rawValue, requests: check.requests,
                    validRegions: check.validRegions, withheld: check.withholdsCandidate)
            }
            rows.append(row)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = try XCTUnwrap(String(data: encoder.encode(rows), encoding: .utf8))
        print("CANDIDATE_TILE_FIXED_FIXTURES_JSON=\(json)")
        // XCTest success only means this fixed comparison ran. Improvement, zero false
        // withholding and adoption are read from all rows, never asserted into success.
    }

    private func canvas(_ draw: (UIGraphicsImageRendererContext) -> Void) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 1024), format: format).image { context in
            UIColor(white: 128.0 / 255, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
            draw(context)
        }
        return try XCTUnwrap(rendered.cgImage)
    }

    private func makeCorner(_ source: CGImage, corner: Corner) throws -> CGImage {
        try canvas { _ in
            let scale = min(1024 / CGFloat(source.width), 1024 / CGFloat(source.height)) * 0.75
            let width = CGFloat(source.width) * scale, height = CGFloat(source.height) * scale
            let x: CGFloat = corner == .topRight || corner == .bottomRight ? 1024 - width : 0
            let y: CGFloat = corner == .bottomLeft || corner == .bottomRight ? 1024 - height : 0
            UIImage(cgImage: source).draw(in: CGRect(x: x, y: y, width: width, height: height))
        }
    }

    private func makePair(_ a: CGImage, _ b: CGImage, vertical: Bool) throws -> CGImage {
        try canvas { _ in
            for (index, source) in [a, b].enumerated() {
                let slot = vertical ? CGRect(x: 0, y: index * 512, width: 1024, height: 512)
                                    : CGRect(x: index * 512, y: 0, width: 512, height: 1024)
                let scale = min(slot.width / CGFloat(source.width), slot.height / CGFloat(source.height))
                let width = CGFloat(source.width) * scale, height = CGFloat(source.height) * scale
                UIImage(cgImage: source).draw(in: CGRect(x: slot.midX - width / 2, y: slot.midY - height / 2,
                                                       width: width, height: height))
            }
        }
    }
}
