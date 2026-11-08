import XCTest
import UIKit
@testable import NekoWidget

final class OutputHarnessTests: XCTestCase {
    @MainActor
    func testHostModuleAndSyntheticImageRoundTrip() throws {
        // Establish the app-hosted renderer test harness, not a product snapshot.
        XCTAssertFalse(EvacuationDestination().canConfirm)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            UIColor.black.setFill()
            UIBezierPath(ovalIn: CGRect(x: 8, y: 8, width: 16, height: 16)).fill()
        }
        let decoded = try XCTUnwrap(UIImage(data: XCTUnwrap(image.pngData())))
        XCTAssertEqual(decoded.cgImage?.width, 32)
        XCTAssertEqual(decoded.cgImage?.height, 32)
    }
}
