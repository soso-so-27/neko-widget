import CoreGraphics
import Foundation

/// A normalized rectangle in Vision coordinates (origin at the lower-left).
struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.width,
            height: rect.height
        )
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var area: Double {
        max(0, width) * max(0, height)
    }

    private enum CodingKeys: String, CodingKey {
        case x, y
        case width = "w"
        case height = "h"
    }
}
