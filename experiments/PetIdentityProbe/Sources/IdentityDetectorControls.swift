import Foundation
import UIKit

enum IdentityDetectorControlID: String, CaseIterable, Codable, Identifiable {
    case orange = "cat-orange-square"
    case tuxedo = "cat-tuxedo-landscape"
    case gray = "cat-gray-portrait"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .orange: "基準画像1 · 茶色の猫"
        case .tuxedo: "基準画像2 · 白黒の猫"
        case .gray: "基準画像3 · 灰色の猫"
        }
    }
}

// This type deliberately has no photo identifier, filename, pixels, or geometry.
struct IdentityDetectorInputReport: Encodable {
    let imageReadable: Bool
    let format: IdentityPixelFormat?
    let animalDetection: IdentityAnimalDetectionDiagnostic?
    let inputIssue: IdentityInputIssue?
    let cropUsable: Bool

    init(image: CGImage?, diagnostic: IdentityAnimalDetectionDiagnostic?, issue: IdentityInputIssue?) {
        imageReadable = image != nil
        format = image.map(IdentityPixelFormat.init)
        animalDetection = diagnostic
        inputIssue = issue
        cropUsable = image != nil && diagnostic?.acceptedCatObservationCount == 1 && issue == nil
    }
    var summary: String {
        if let inputIssue { return inputIssue.title }
        return cropUsable ? "猫の範囲を確認できました" : "確認できませんでした"
    }
}

// Geometry is exported ONLY for the three fixed, generated, bundled controls.
// The saved-photo report above cannot carry this type.
struct IdentityControlBox: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    init?(_ rect: CGRect) {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0 else { return nil }
        x = Double(rect.minX); y = Double(rect.minY)
        width = Double(rect.width); height = Double(rect.height)
    }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct IdentityDetectorControlResult: Encodable {
    let control: IdentityDetectorControlID
    let expectedVisibleCats = 1
    let input: IdentityDetectorInputReport
    let acceptedBoxes: [IdentityControlBox]
    let geometryScope = "fixed-generated-control-only;normalized-vision-bottom-left"
}

struct IdentityDetectorComparisonReport: Encodable {
    let controls: [IdentityDetectorControlResult]
    let savedPhoto: IdentityDetectorInputReport?
    let allControlsHaveSingleUsableCrop: Bool
    let protocolIdentifier = "pet-detector-controls-v1"
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    #if targetEnvironment(simulator)
    let platform = "simulator"
    #else
    let platform = "device"
    #endif
    let method = "three-generated-controls-and-at-most-one-saved-photo;upright-max1024;vision-r2-cat0.5;no-fallback"
    let photosIncluded = false
    let identifiersIncluded = false
    let embeddingsIncluded = false
    let savedPhotoGeometryIncluded = false
    let identityEvaluated = false
    let modelExecuted = false
    let productValidated = false
    let productionDataChanged = false

    init(controls: [IdentityDetectorControlResult], savedPhoto: IdentityDetectorInputReport?) {
        self.controls = controls
        self.savedPhoto = savedPhoto
        allControlsHaveSingleUsableCrop = controls.count == IdentityDetectorControlID.allCases.count
            && Set(controls.map(\.control)) == Set(IdentityDetectorControlID.allCases)
            && controls.allSatisfy { $0.input.cropUsable }
    }

    var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

// The selected thumbnail is local, transient, not encoded and not saved.
struct IdentityDetectorComparisonRun {
    let report: IdentityDetectorComparisonReport
    let savedPhotoThumbnail: CGImage?
}

enum IdentityDetectorControls {
    static func inspect(_ control: IdentityDetectorControlID, bundle: Bundle = .main) -> IdentityDetectorControlResult {
        guard let path = bundle.url(forResource: control.rawValue, withExtension: "png")?.path,
              let source = UIImage(contentsOfFile: path),
              let image = IdentityImagePipeline.upright(source) else {
            return IdentityDetectorControlResult(control: control,
                input: IdentityDetectorInputReport(image: nil, diagnostic: nil, issue: .localImageUnavailable), acceptedBoxes: [])
        }
        do {
            let inspected = try IdentityImagePipeline.inspectCatCrop(image)
            let issue: IdentityInputIssue?
            switch inspected.result {
            case .success: issue = nil
            case .failure(let failure): issue = failure
            }
            return IdentityDetectorControlResult(control: control,
                input: IdentityDetectorInputReport(image: image, diagnostic: inspected.diagnostic, issue: issue),
                acceptedBoxes: inspected.acceptedBoxes.compactMap(IdentityControlBox.init))
        } catch {
            return IdentityDetectorControlResult(control: control,
                input: IdentityDetectorInputReport(image: image, diagnostic: nil, issue: .detectionFailed), acceptedBoxes: [])
        }
    }
}
