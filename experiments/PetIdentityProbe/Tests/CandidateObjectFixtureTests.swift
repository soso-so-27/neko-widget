import UIKit
import XCTest
@testable import PetIdentityProbe

final class CandidateObjectFixtureTests: XCTestCase {
    private struct Fixture {
        let name: String
        let expectedCats: Int
        let image: () throws -> CGImage
    }
    private struct Row: Encodable {
        let fixture: String
        let expectedCats: Int
        let originalCropUsable: Bool
        let rawAccepted: Int
        let detectorStatus: String
        let detectedRegions: Int
        let usableRegions: Int
        let additionalWithholding: Bool
        let identityEvaluated = false
    }

    func testFixedSinglesPairsAndIsolatedSidesBeforeInternalDistribution() throws {
        let detector = try CandidateObjectDetector()
        let controls = try IdentityDetectorControlID.allCases.map { control -> (String, CGImage) in
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: control.rawValue, withExtension: "png"))
            return (control.rawValue, try XCTUnwrap(IdentityImagePipeline.upright(try XCTUnwrap(UIImage(contentsOfFile: url.path)))))
        }
        var fixtures = controls.map { name, image in Fixture(name: name, expectedCats: 1, image: { image }) }
        for (name, image) in controls {
            for corner in 0..<4 {
                fixtures.append(.init(name: "\(name)-single75-\(corner)", expectedCats: 1, image: {
                    try self.canvas {
                        let scale = 768 / CGFloat(max(image.width, image.height))
                        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
                        UIImage(cgImage: image).draw(in: CGRect(x: corner % 2 == 1 ? 1024-w : 0,
                            y: corner >= 2 ? 1024-h : 0, width: w, height: h))
                    }
                }))
            }
        }
        for i in controls.indices { for j in controls.indices where j > i {
            let a = controls[i], b = controls[j]
            for vertical in [false, true] {
                fixtures.append(.init(name: "\(a.0)+\(b.0)-\(vertical ? "vertical" : "horizontal")", expectedCats: 2, image: {
                    try self.canvas {
                        for (index, image) in [a.1, b.1].enumerated() {
                            let slot = vertical ? CGRect(x: 0, y: index*512, width: 1024, height: 512)
                                                : CGRect(x: index*512, y: 0, width: 512, height: 1024)
                            let scale = min(slot.width/CGFloat(image.width), slot.height/CGFloat(image.height))
                            let w = CGFloat(image.width)*scale, h = CGFloat(image.height)*scale
                            UIImage(cgImage: image).draw(in: CGRect(x: slot.midX-w/2, y: slot.midY-h/2, width: w, height: h))
                        }
                    }
                }))
                // Remove either cat but preserve the other's exact scale/position.
                // These dependent counterfactuals are not independent accuracy samples.
                for remaining in 0..<2 {
                    let image = [a.1, b.1][remaining]
                    fixtures.append(.init(name: "\(a.0)+\(b.0)-\(vertical ? "vertical" : "horizontal")-isolated-\(remaining)", expectedCats: 1, image: {
                        try self.canvas {
                            let slot = vertical ? CGRect(x: 0, y: remaining*512, width: 1024, height: 512)
                                                : CGRect(x: remaining*512, y: 0, width: 512, height: 1024)
                            let scale = min(slot.width/CGFloat(image.width), slot.height/CGFloat(image.height))
                            let w = CGFloat(image.width)*scale, h = CGFloat(image.height)*scale
                            UIImage(cgImage: image).draw(in: CGRect(x: slot.midX-w/2, y: slot.midY-h/2, width: w, height: h))
                        }
                    }))
                }
            }
        } }
        XCTAssertEqual(fixtures.count, 33); XCTAssertEqual(Set(fixtures.map(\.name)).count, 33)
        var rows: [Row] = []
        for fixture in fixtures {
            let row = try autoreleasepool { () throws -> Row in
                let image = try fixture.image()
                let original = try IdentityImagePipeline.inspectCatCrop(image)
                let eligible: Bool
                if case .success = original.result { eligible = true } else { eligible = false }
                // Run detector on every fixed image to expose misses and false positives,
                // but count guard improvements only for original-eligible photos.
                let boxes = try detector.detect(image)
                let checked = CandidateObjectProbe.assess(boxes, width: image.width, height: image.height)
                XCTAssertNotEqual(checked.status, .failed)
                if fixture.expectedCats == 2 || fixture.name == "cat-orange-square+cat-gray-portrait-vertical-isolated-1" {
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                    let rendered = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { context in
                        UIImage(cgImage: image).draw(in: CGRect(x: 0, y: 0, width: 512, height: 512))
                        context.cgContext.setStrokeColor(UIColor.green.cgColor); context.cgContext.setLineWidth(2)
                        for box in boxes { context.cgContext.stroke(CGRect(x: box.minX/2, y: box.minY/2, width: box.width/2, height: box.height/2)) }
                    }
                    let attachment = XCTAttachment(image: rendered)
                    attachment.name = "generated-object-regions-\(fixture.name)"
                    attachment.lifetime = .keepAlways; add(attachment)
                }
                return Row(fixture: fixture.name, expectedCats: fixture.expectedCats, originalCropUsable: eligible,
                    rawAccepted: original.acceptedBoxes.count, detectorStatus: checked.status.rawValue,
                    detectedRegions: checked.detectedRegions, usableRegions: checked.usableRegions,
                    additionalWithholding: eligible && checked.withholdsCandidate)
            }
            rows.append(row)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print("CANDIDATE_OBJECT_FIXED_FIXTURES_JSON=\(try XCTUnwrap(String(data: encoder.encode(rows), encoding: .utf8)))")
        // Development/regression gate, not 95% identity accuracy. Cover the four
        // originally missed fixed pairs and ALL single controls, including isolated sides.
        XCTAssertEqual(rows.filter { $0.expectedCats == 2 && $0.additionalWithholding }.count, 4)
        XCTAssertEqual(rows.filter { $0.expectedCats == 2 && $0.detectorStatus == "multipleSeparatedRegions" }.count, 6)
        XCTAssertEqual(rows.filter { $0.expectedCats == 1 && $0.additionalWithholding }.count, 0)
        XCTAssertEqual(rows.filter { $0.expectedCats == 1 && $0.detectorStatus == "multipleSeparatedRegions" }.count, 0)
    }

    private func canvas(draw: () -> Void) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 1024), format: format).image { _ in
            UIColor(white: 128.0/255, alpha: 1).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 1024, height: 1024)); draw()
        }
        return try XCTUnwrap(image.cgImage)
    }
}
