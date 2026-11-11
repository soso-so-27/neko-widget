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
            let large = ["widget-personal", "widget-family"].contains(screen) ? 9 : 32
            for (number, name) in [(31, "medium"), (large, "large")] {
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
            if screen == "widget-family" {
                guard let jpeg = image(number: 18)?.jpegData(compressionQuality: 0.92) else {
                    assertionFailure("The delivered Widget photo is missing")
                    return
                }
                try GroupWidgetCache.update(windowID: "fixture-window", windowName: "わが家", photoID: "fixture-photo",
                    jpeg: jpeg, senderDisplayName: "ママ", capturedAt: nil, isPaused: false)
                try Data().write(to: root.appendingPathComponent("show-group-window"), options: .atomic)
            }
            WidgetCenter.shared.reloadAllTimelines()
        } catch { assertionFailure("Private Widget input could not be prepared") }
    }

    @MainActor static func prepareVeterinaryVisit() async {
        guard isRequested, screen == "vet",
              let catID = UUID(uuidString: "11111111-1111-4111-8111-111111111111") else { return }
        do {
            let store = VeterinaryVisitStore.shared
            var visit = try await store.current(catID: catID, catName: "むぎ", create: { try $0() })
            guard visit.entries.isEmpty else { return }
            visit.observations = "朝ごはんを少し残す日が続いています。"
            visit = try await store.save(visit, expectedRevision: visit.revision)
            let cat = PhotoMemoryNoteCat(id: catID, name: "むぎ")
            for (index, number) in [10, 25].enumerated() {
                guard let jpeg = image(number: number)?.jpegData(compressionQuality: 0.85) else {
                    assertionFailure("A veterinary capture photo is missing")
                    return
                }
                let day = Date().addingTimeInterval(Double(index - 2) * 86_400)
                let note = PhotoMemoryNote(text: "", updatedAt: day, revision: UUID().uuidString,
                    context: .init(capturedAt: day, cats: [cat]))
                let record = PhotoMemoryNoteRecord(photoIdentifier: "app-store-screenshot-fixture-\(number)", note: note)
                visit = try await store.add(source: record, jpeg: jpeg, to: visit.id,
                    expectedRevision: visit.revision, confirmedTarget: true)
            }
        } catch { assertionFailure("Private veterinary visit fixture could not be prepared") }
    }
}

#endif
