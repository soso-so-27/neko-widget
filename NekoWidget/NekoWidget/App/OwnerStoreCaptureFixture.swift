#if DEBUG
import Foundation
import UIKit
import ImageIO
import CoreImage
import WidgetKit

/// Owner media are injected into one disposable Simulator at runtime, never
/// bundled or committed. This route is unavailable to every Release build.
enum OwnerStoreCaptureFixture {
    static var isRequested: Bool { CommandLine.arguments.contains("--owner-store-capture") }
    static var screen: String { ProcessInfo.processInfo.environment["NEKO_CAPTURE_SCREEN"] ?? "" }
    static let filenames: [Int: String] = [
        1: "IMG_1194", 2: "IMG_9082", 3: "IMG_9393", 4: "NYXC6588",
        5: "IMG_5794", 6: "IMG_7958", 7: "MJIN0556", 8: "VZRR6412",
        27: "IMG_0968", 28: "IMG_6666", 29: "IMG_7175", 30: "IMG_1513",
        9: "EEMW5137", 10: "IMG_8862", 11: "IMG_5261", 12: "IMG_7671",
        13: "IMG_9423", 14: "IMG_2260", 15: "IMG_8971", 16: "IMG_2264", 17: "IMG_7866",
        18: "IMG_7671", 19: "IMG_7175", 20: "IMG_9082", 21: "IMG_9393",
        22: "IMG_9423", 23: "IMG_5794", 24: "IMG_5806",
        25: "IMG_9393", 26: "EEMW5137", 31: "IMG_8862", 32: "IMG_8536",
    ]

    @MainActor static func image(number: Int) -> UIImage? {
        guard isRequested, let name = filenames[number],
              let root = ProcessInfo.processInfo.environment["NEKO_PRIVATE_CAPTURE_ROOT"],
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: root)
                .appendingPathComponent(name + ".JPG") as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    @MainActor static func prepareWidgets() {
        guard isRequested, let root = SharedContainer.containerURL?
            .appendingPathComponent("owner-store-capture", isDirectory: true) else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (number, name) in [(31, "medium"), (32, "large")] {
                guard let image = image(number: number), let cg = image.cgImage else { continue }
                var output = image
                if number == 31 {
                    // The same Gaussian radius and edge clamping as the
                    // shipping cloudy-window image preparer, with its default strength.
                    let input = CIImage(cgImage: cg)
                    let radius = CloudyWindowConfiguration().strength.radius * Double(cg.width) / 500
                    let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur",
                        parameters: [kCIInputRadiusKey: radius]).cropped(to: input.extent)
                    guard let result = CIContext().createCGImage(blurred, from: input.extent) else { continue }
                    output = UIImage(cgImage: result)
                }
                try output.jpegData(compressionQuality: 0.9)?.write(to: root.appendingPathComponent(name + ".jpg"))
            }
            WidgetCenter.shared.reloadAllTimelines()
        } catch { assertionFailure("Private Widget input could not be prepared") }
    }
}

#endif
