import XCTest
import UIKit
@testable import PetIdentityProbe

// Development-only experiment. No app behavior, private photos, reference vectors,
// threshold calibration or persisted choices are changed by this test.
final class CandidateSecondScaleExperimentTests: XCTestCase {
    private struct Observation: Encodable {
        let fixture: String
        let expectedCats: Int
        let originalAcceptedRegions: Int
        let originalCropUsable: Bool
        let halfAcceptedRegions: Int
        let halfValidRegions: Int
        let wouldWithholdSingleCandidate: Bool
    }

    // A strict gap, not merely a zero-area intersection: touching, nested and
    // overlapping detections are not evidence of separate regions.
    private static func hasSeparatedPair(_ boxes: [CGRect]) -> Bool {
        let roundoff: CGFloat = 0.000001
        for i in boxes.indices {
            for j in boxes.indices where j > i {
                let a = boxes[i], b = boxes[j]
                if a.maxX + roundoff < b.minX || b.maxX + roundoff < a.minX ||
                    a.maxY + roundoff < b.minY || b.maxY + roundoff < a.minY {
                    return true
                }
            }
        }
        return false
    }

    private static func validHalfBoxes(_ boxes: [CGRect], width: Int, height: Int) -> [CGRect] {
        boxes.compactMap { box in
            guard !box.isNull, !box.isInfinite,
                  case .success(let mapped) = IdentityRecoveredCropProbe.mapHalfBoxToOriginal(box),
                  IdentityImagePipeline.cropRect(mapped, width: width, height: height) != nil else { return nil }
            return mapped
        }
    }

    func testGeometryDoesNotTreatDuplicatesTouchingPaddingOrTinyRegionsAsEvidence() {
        let a = CGRect(x: 0.30, y: 0.30, width: 0.125, height: 0.20)
        let nested = CGRect(x: 0.32, y: 0.32, width: 0.03, height: 0.04)
        let touching = CGRect(x: a.maxX, y: 0.30, width: 0.10, height: 0.20)
        let separate = CGRect(x: 0.55, y: 0.30, width: 0.10, height: 0.20)
        func verdict(_ boxes: [CGRect]) -> Bool {
            Self.hasSeparatedPair(Self.validHalfBoxes(boxes, width: 1024, height: 768))
        }
        XCTAssertFalse(verdict([a, a]))
        XCTAssertFalse(verdict([a, nested]))
        XCTAssertFalse(verdict([a, touching]))
        XCTAssertTrue(verdict([a, separate]))
        XCTAssertFalse(verdict([a, CGRect(x: 0.70, y: 0.30, width: 0.10, height: 0.20)]))
        XCTAssertFalse(verdict([a, CGRect(x: 0.55, y: 0.30, width: 0.005, height: 0.005)]))
        XCTAssertFalse(verdict([a, .null, .infinite, CGRect(x: CGFloat.nan, y: 0.30, width: 0.1, height: 0.1)]))
    }

    func testFixedGeneratedControlsAndSixPairLayoutsMeasureAddedValue() throws {
        let bundle = Bundle(for: Self.self)
        let controls: [(name: String, image: CGImage)] = try IdentityDetectorControlID.allCases.map { control in
            let url = try XCTUnwrap(bundle.url(forResource: control.rawValue, withExtension: "png"))
            let source = try XCTUnwrap(UIImage(contentsOfFile: url.path))
            return (control.rawValue, try XCTUnwrap(IdentityImagePipeline.upright(source)))
        }
        var fixtures = controls.map { (name: $0.name, cats: 1, image: $0.image) }
        // Fixed before the run: all three unique pairs, two layouts. Do not search
        // rotations/scales/crops until a desired detector outcome appears.
        for i in controls.indices {
            for j in controls.indices where j > i {
                for vertical in [false, true] {
                    let pair = try makePair(controls[i].image, controls[j].image, vertical: vertical)
                    fixtures.append(("\(controls[i].name)+\(controls[j].name)-\(vertical ? "vertical" : "horizontal")", 2, pair))
                }
            }
        }
        var rows: [Observation] = []
        for fixture in fixtures {
            let row = try autoreleasepool { () throws -> Observation in
                let original = try IdentityImagePipeline.inspectCatCrop(fixture.image)
                XCTAssertTrue(original.diagnostic.resultsAvailable)
                let normalized = try XCTUnwrap(IdentityImageFormatProbe.standardRGB(fixture.image))
                let half = try XCTUnwrap(IdentityDetectorScaleProbe.render(normalized, scale: .half))
                let added = try IdentityImagePipeline.inspectCatCrop(half)
                XCTAssertTrue(added.diagnostic.resultsAvailable)
                XCTAssertEqual(added.diagnostic.acceptedCatObservationCount, added.acceptedBoxes.count)
                let valid = Self.validHalfBoxes(added.acceptedBoxes, width: fixture.image.width, height: fixture.image.height)
                let originalUsable: Bool
                if case .success = original.result { originalUsable = true } else { originalUsable = false }
                return Observation(fixture: fixture.name, expectedCats: fixture.cats,
                    originalAcceptedRegions: original.acceptedBoxes.count, originalCropUsable: originalUsable,
                    halfAcceptedRegions: added.acceptedBoxes.count, halfValidRegions: valid.count,
                    wouldWithholdSingleCandidate: originalUsable && Self.hasSeparatedPair(valid))
            }
            rows.append(row)
        }
        XCTAssertEqual(rows.count, 9)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rows)
        print("CANDIDATE_SECOND_SCALE_FIXED_FIXTURES_JSON=\(try XCTUnwrap(String(data: data, encoding: .utf8)))")
        // Measurements are not a pass assertion: successful XCTest execution does
        // not establish detector improvement, product accuracy or device parity.
    }

    private func makePair(_ a: CGImage, _ b: CGImage, vertical: Bool) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 1024, height: 1024)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 128.0 / 255, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, source) in [a, b].enumerated() {
                let slot = vertical ? CGRect(x: 0, y: index * 512, width: 1024, height: 512)
                                    : CGRect(x: index * 512, y: 0, width: 512, height: 1024)
                let scale = min(slot.width / CGFloat(source.width), slot.height / CGFloat(source.height))
                let width = CGFloat(source.width) * scale, height = CGFloat(source.height) * scale
                UIImage(cgImage: source).draw(in: CGRect(x: slot.midX - width / 2, y: slot.midY - height / 2,
                                                       width: width, height: height))
            }
        }
        return try XCTUnwrap(image.cgImage)
    }
}
