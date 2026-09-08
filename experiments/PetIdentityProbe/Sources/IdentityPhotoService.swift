import CryptoKit
import Foundation
import OnnxRuntimeBindings
import Photos
import UIKit
import Vision

enum IdentityPhotoSlot: String, CaseIterable, Identifiable, Sendable {
    case referenceA, evaluationA, referenceB, evaluationB
    var id: String { rawValue }
    var isReference: Bool { self == .referenceA || self == .referenceB }
    var cat: Int { self == .referenceA || self == .evaluationA ? 0 : 1 }
    var count: Int { isReference ? 5 : 15 }
    var title: String { "猫\(cat == 0 ? "A" : "B") · \(isReference ? "見本5枚" : "判定写真")" }
}

// Intentionally not Codable. Identifiers, thumbnails and individual predictions stay on device.
struct IdentityLocalPhoto {
    let slot: IdentityPhotoSlot
    let index: Int
    let thumbnail: CGImage?
    let embedding: [Float]?
    let fingerprint: UInt64?
    var inputIssue: IdentityInputIssue? = nil
}

enum IdentityInputIssue: String, Codable, CaseIterable, Error {
    case assetUnavailable, localImageUnavailable, catNotDetected, multipleCats, invalidCrop, detectionFailed
    var title: String {
        switch self {
        case .assetUnavailable: "写真にアクセスできない"
        case .localImageUnavailable: "端末内の画像を読み出せない"
        case .catNotDetected: "猫を検出できない"
        case .multipleCats: "複数の猫を検出"
        case .invalidCrop: "猫の範囲が小さい・切り抜けない"
        case .detectionFailed: "検出処理でエラー"
        }
    }
}

struct IdentityInputDiagnostic: Codable {
    let label: String
    let reasonCounts: [String: Int]
}

struct IdentityPhotoRun {
    let evaluation: IdentityEvaluationResult
    let photos: [IdentityLocalPhoto]
    let nearbyTimePairs: Int
    var repeatedBurstCount = 0
    var similarPhotoCount = 0

    var inputDiagnostics: [IdentityInputDiagnostic] {
        (0..<2).map { cat in
            let inputs = photos.filter { $0.slot.cat == cat && !$0.slot.isReference }
            return IdentityInputDiagnostic(label: cat == 0 ? "A" : "B",
                reasonCounts: Dictionary(uniqueKeysWithValues: IdentityInputIssue.allCases.map { issue in
                    (issue.rawValue, inputs.filter { $0.inputIssue == issue }.count)
                }))
        }
    }
}

/// Input diagnosis has no identity prediction or acceptance gate.
struct IdentityInputReport: Encodable {
    let protocolIdentifier = "pet-identity-input-diagnostic-v3"
    let imageReadable: Bool
    let singleCatDetected: Bool
    let cropUsable: Bool
    let modelOutputValidated: Bool
    let inputIssue: IdentityInputIssue?
    let modelFailure: String?
    let imageWidth: Int?
    let imageHeight: Int?
    let cropWidth: Int?
    let cropHeight: Int?
    let runtimeVersion: String
    var animalDetection: IdentityAnimalDetectionDiagnostic? = nil
    var formatComparison: IdentityImageFormatComparison? = nil
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    let modelSHA256 = ProbeModelFile.sha256
    let photoFetch = "selected-only-current-1024-local-no-network"
    let preprocessing = "vision-animal-r2-cat0.5-single-exactbbox-min32px-resize224-srgb-chw-imagenet-v1"
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let photosIncluded = false
    let identifiersIncluded = false
    let embeddingsIncluded = false
    let identityEvaluated = false
    let productValidated = false
    let productionDataChanged = false
}

// Images are deliberately outside the Codable report, and never persisted.
struct IdentityInputRun {
    let report: IdentityInputReport
    let thumbnail: CGImage?
    let cropThumbnail: CGImage?
}

private struct IdentityPreparedPhoto {
    let image: CGImage?
    let crop: CGImage?
    let issue: IdentityInputIssue?
    var animalDetection: IdentityAnimalDetectionDiagnostic? = nil
}

struct IdentityPhotoFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ProbeModelFile {
    static let sha256 = "32adffda4e65f790ae624d828b79db7a18f7fdb1facdce1cc91bb9951d948c0b"
    static func validatedURL() throws -> URL {
        guard let url = Bundle.main.url(forResource: "model-fixed", withExtension: "onnx") else {
            throw IdentityPhotoFailure(message: "確認用モデルがありません。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var size = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
            size += data.count
        }
        guard size == 89_227_594,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw IdentityPhotoFailure(message: "モデルが一致しないため中止しました。")
        }
        return url
    }
}

actor IdentityPhotoService {
    private var busy = false

    func inspectInput(id: String) async throws -> IdentityInputRun {
        guard !busy else { throw IdentityPhotoFailure(message: "前の処理の終了を待ってください。") }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        guard !id.isEmpty else { throw IdentityPhotoFailure(message: "写真を1枚選んでください。") }
        try Self.checkAuthorization()
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        let result = try autoreleasepool { () throws -> IdentityInputRun in
            let prepared = Self.preparePhoto(fetched.firstObject)
            try Task.checkCancellation()
            let formatComparison: IdentityImageFormatComparison?
            if let image = prepared.image {
                formatComparison = try IdentityImageFormatProbe.compareIfNeeded(image, original: prepared.animalDetection,
                    detect: { converted in
                        try Task.checkCancellation()
                        return try IdentityImagePipeline.inspectCatCrop(converted).diagnostic
                    })
            } else { formatComparison = nil }
            try Task.checkCancellation()
            var validated = false
            var modelFailure: String?
            let runtime = ORTVersion() ?? "unknown"
            if let crop = prepared.crop {
                if runtime != IdentityEvaluationCore.expectedRuntimeVersion {
                    modelFailure = "固定したRuntimeと一致しません。"
                } else {
                    do {
                        let engine = try IdentityCPUSession()
                        _ = try engine.embedding(crop)
                        validated = true
                    } catch {
                        // Do not export system errors, identifiers or photo paths.
                        modelFailure = "モデルの実行または出力の確認を完了できませんでした。"
                    }
                }
            }
            return IdentityInputRun(report: IdentityInputReport(
                imageReadable: prepared.image != nil,
                singleCatDetected: prepared.crop != nil || prepared.issue == .invalidCrop,
                cropUsable: prepared.crop != nil, modelOutputValidated: validated,
                inputIssue: prepared.issue, modelFailure: modelFailure,
                imageWidth: prepared.image?.width, imageHeight: prepared.image?.height,
                cropWidth: prepared.crop?.width, cropHeight: prepared.crop?.height, runtimeVersion: runtime,
                animalDetection: prepared.animalDetection, formatComparison: formatComparison),
                thumbnail: prepared.image.flatMap(Self.thumbnail),
                cropThumbnail: prepared.crop.flatMap(Self.thumbnail))
        }
        try Task.checkCancellation()
        return result
    }

    func run(selections: [IdentityPhotoSlot: [String]],
             purpose: IdentityEvaluationPurpose = .diagnostic,
             progress: @Sendable (Int) async -> Void) async throws -> IdentityPhotoRun {
        guard !busy else { throw IdentityPhotoFailure(message: "前の処理の終了を待ってください。") }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        let ids = IdentityPhotoSlot.allCases.flatMap { selections[$0] ?? [] }
        let evaluationCount = (selections[.evaluationA]?.count ?? 0) + (selections[.evaluationB]?.count ?? 0)
        let referencesReady = selections[.referenceA]?.count == 5 && selections[.referenceB]?.count == 5
        let evaluationsReady = purpose == .heldout
            ? selections[.evaluationA]?.count == 15 && selections[.evaluationB]?.count == 15
            : (1...30).contains(evaluationCount)
                && [IdentityPhotoSlot.evaluationA, .evaluationB].allSatisfy { (selections[$0]?.count ?? 0) <= 15 }
        guard referencesReady, evaluationsReady, Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }) else {
            throw IdentityPhotoFailure(message: purpose == .heldout
                ? "同じ写真を重複させず、見本5枚と判定用15枚を2匹分選んでください。"
                : "見本を猫A・Bそれぞれ5枚、別の判定写真をどちらかの猫で1枚以上選んでください。")
        }
        try Self.checkAuthorization()
        // Fetch only explicitly selected assets. Never enumerate the whole library.
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }
        var nearbyTimePairs = 0
        var repeatedBurstCount = 0
        var similarPhotoCount = 0
        for cat in 0..<2 {
            let catIDs = IdentityPhotoSlot.allCases.filter { $0.cat == cat }.flatMap { selections[$0] ?? [] }
            var bursts = Set<String>()
            let dates = catIDs.compactMap { assets[$0]?.creationDate }
            for id in catIDs {
                if let burst = assets[id]?.burstIdentifier, !bursts.insert(burst).inserted {
                    if purpose == .heldout {
                        throw IdentityPhotoFailure(message: "猫\(cat == 0 ? "A" : "B")に同じ連写の写真があります。別の場面を選んでください。")
                    }
                    repeatedBurstCount += 1
                }
            }
            for first in dates.indices {
                for second in dates.indices where second > first {
                    if abs(dates[first].timeIntervalSince(dates[second])) <= 30 { nearbyTimePairs += 1 }
                }
            }
        }
        let engine = try IdentityCPUSession()
        var photos: [IdentityLocalPhoto] = []
        for slot in IdentityPhotoSlot.allCases {
            for (index, id) in (selections[slot] ?? []).enumerated() {
                try Task.checkCancellation()
                let photo = try autoreleasepool { () throws -> IdentityLocalPhoto in
                    let prepared = Self.preparePhoto(assets[id])
                    let crop = prepared.crop
                    let issue = prepared.issue
                    // A missing/undetected evaluation remains in the denominator as unknown.
                    if slot.isReference && crop == nil {
                        throw IdentityPhotoFailure(message: "\(slot.title)の\(index + 1)枚目：\(issue?.title ?? "読み取り失敗")。選択は残しています。この欄だけ確認・入れ替えできます。")
                    }
                    let embedding: [Float]?
                    if let crop {
                        // Runtime failures abort the run; they are not disguised as uncertain cats.
                        embedding = try engine.embedding(crop)
                    } else { embedding = nil }
                    return IdentityLocalPhoto(slot: slot, index: index,
                        thumbnail: prepared.image.flatMap(Self.thumbnail),
                        embedding: embedding, fingerprint: crop.flatMap(IdentityImagePipeline.fingerprint), inputIssue: issue)
                }
                if let fingerprint = photo.fingerprint,
                   let previous = photos.first(where: {
                       $0.slot.cat == slot.cat && $0.fingerprint.map { ($0 ^ fingerprint).nonzeroBitCount <= 2 } == true
                   }) {
                    if purpose == .heldout {
                        throw IdentityPhotoFailure(message: "\(previous.slot.title)の\(previous.index + 1)枚目と\(slot.title)の\(index + 1)枚目が似すぎています。別の場面を選んでください。")
                    }
                    similarPhotoCount += 1
                }
                photos.append(photo)
                await progress(photos.count)
            }
        }
        try Task.checkCancellation()
        func vectors(_ slot: IdentityPhotoSlot) -> [[Float]?] {
            photos.filter { $0.slot == slot }.map(\.embedding)
        }
        let result = try IdentityEvaluationCore.evaluate(registrationA: vectors(.referenceA),
            registrationB: vectors(.referenceB), evaluationA: vectors(.evaluationA),
            evaluationB: vectors(.evaluationB), runtimeVersion: ORTVersion() ?? "unknown", purpose: purpose)
        // Features are not needed by the result UI; release them before returning.
        let previews = photos.map {
            IdentityLocalPhoto(slot: $0.slot, index: $0.index, thumbnail: $0.thumbnail,
                               embedding: nil, fingerprint: nil, inputIssue: $0.inputIssue)
        }
        return IdentityPhotoRun(evaluation: result, photos: previews, nearbyTimePairs: nearbyTimePairs,
                                repeatedBurstCount: repeatedBurstCount, similarPhotoCount: similarPhotoCount)
    }

    private static func checkAuthorization() throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw IdentityPhotoFailure(message: "選んだ写真へのアクセスを許可してください。限定アクセスでも利用できます。")
        }
    }

    private static func preparePhoto(_ asset: PHAsset?) -> IdentityPreparedPhoto {
        guard let asset else { return IdentityPreparedPhoto(image: nil, crop: nil, issue: .assetUnavailable) }
        guard let image = localImage(asset) else { return IdentityPreparedPhoto(image: nil, crop: nil, issue: .localImageUnavailable) }
        do {
            let inspected = try IdentityImagePipeline.inspectCatCrop(image)
            switch inspected.result {
            case .success(let crop):
                return IdentityPreparedPhoto(image: image, crop: crop, issue: nil, animalDetection: inspected.diagnostic)
            case .failure(let issue):
                return IdentityPreparedPhoto(image: image, crop: nil, issue: issue, animalDetection: inspected.diagnostic)
            }
        } catch { return IdentityPreparedPhoto(image: image, crop: nil, issue: .detectionFailed) }
    }

    private static func thumbnail(_ image: CGImage) -> CGImage? {
        let factor = 160.0 / Double(max(image.width, image.height))
        return IdentityImagePipeline.resized(image, width: max(1, Int(Double(image.width) * factor)),
                                              height: max(1, Int(Double(image.height) * factor)))
    }

    private static func localImage(_ asset: PHAsset) -> CGImage? {
        guard asset.mediaType == .image else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.version = .current
        var image: CGImage?
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1024, height: 1024),
            contentMode: .aspectFit, options: options) { value, info in
                guard info?[PHImageErrorKey] == nil,
                      (info?[PHImageCancelledKey] as? Bool) != true,
                      (info?[PHImageResultIsDegradedKey] as? Bool) != true, let value else { return }
                image = IdentityImagePipeline.upright(value)
            }
        return image
    }
}

enum IdentityImagePipeline {
    static func upright(_ image: UIImage) -> CGImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, 1024 / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, floor(image.size.width * scale)), height: max(1, floor(image.size.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    static func cropRect(_ box: CGRect, width: Int, height: Int) -> CGRect? {
        guard width > 0, height > 0,
              [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
              box.width > 0, box.height > 0 else { return nil }
        let clipped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let pixels = CGRect(x: clipped.minX * CGFloat(width), y: (1 - clipped.maxY) * CGFloat(height),
            width: clipped.width * CGFloat(width), height: clipped.height * CGFloat(height)).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        return pixels.width >= 32 && pixels.height >= 32 ? pixels : nil
    }

    static func singleCatCrop(_ image: CGImage) throws -> CGImage? {
        switch try catCropResult(image) {
        case .success(let crop): return crop
        case .failure: return nil
        }
    }

    static func catCropResult(_ image: CGImage) throws -> Result<CGImage, IdentityInputIssue> {
        try inspectCatCrop(image).result
    }

    static func inspectCatCrop(_ image: CGImage) throws
        -> (result: Result<CGImage, IdentityInputIssue>, diagnostic: IdentityAnimalDetectionDiagnostic) {
        let request = VNRecognizeAnimalsRequest()
        request.revision = VNRecognizeAnimalsRequestRevision2
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let observations = request.results ?? []
        let labels = observations.map { $0.labels.map { IdentityAnimalLabelSample(label: $0.identifier, confidence: $0.confidence) } }
        let diagnostic = IdentityAnimalDetectionDiagnostic(observationLabels: labels, revision: request.revision,
            systemCatLabel: VNAnimalIdentifier.cat.rawValue, resultsAvailable: request.results != nil)
        // The same exact-label and 0.5 predicate as before; case-insensitive counts are diagnostic only.
        let cats = zip(observations, labels).filter { IdentityAnimalDetectionDiagnostic.acceptsCat($0.1) }.map { $0.0 }
        return (cropResult(image, catBoxes: cats.map(\.boundingBox)), diagnostic)
    }

    static func cropResult(_ image: CGImage, catBoxes: [CGRect]) -> Result<CGImage, IdentityInputIssue> {
        guard !catBoxes.isEmpty else { return .failure(.catNotDetected) }
        guard catBoxes.count == 1 else { return .failure(.multipleCats) }
        guard let rect = cropRect(catBoxes[0], width: image.width, height: image.height),
              let crop = image.cropping(to: rect) else { return .failure(.invalidCrop) }
        return .success(crop)
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func rgbTensor(_ image: CGImage) -> NSMutableData? {
        var rgba = [UInt8](repeating: 0, count: 224 * 224 * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 224, height: 224, bitsPerComponent: 8,
                bytesPerRow: 224 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .high
            // Preserve CGImage raster row order; verified with asymmetric RGB fixtures.
            context.draw(image, in: CGRect(x: 0, y: 0, width: 224, height: 224))
            return true
        }
        guard rendered else { return nil }
        let mean: [Float] = [0.485, 0.456, 0.406]
        let std: [Float] = [0.229, 0.224, 0.225]
        var floats = [Float](repeating: 0, count: 3 * 224 * 224)
        for pixel in 0..<(224 * 224) {
            for channel in 0..<3 { floats[channel * 224 * 224 + pixel] = (Float(rgba[pixel * 4 + channel]) / 255 - mean[channel]) / std[channel] }
        }
        return floats.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
    }

    static func fingerprint(_ image: CGImage) -> UInt64? {
        var gray = [UInt8](repeating: 0, count: 9 * 8)
        let rendered = gray.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 9, height: 8, bitsPerComponent: 8,
                bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard rendered else { return nil }
        var value: UInt64 = 0
        for row in 0..<8 { for col in 0..<8 { value = (value << 1) | (gray[row * 9 + col] > gray[row * 9 + col + 1] ? 1 : 0) } }
        return value
    }
}

final class IdentityCPUSession {
    private let environment: ORTEnv
    private let session: ORTSession
    init() throws {
        let url = try ProbeModelFile.validatedURL()
        environment = try ORTEnv(loggingLevel: .error)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setLogSeverityLevel(.error)
        session = try ORTSession(env: environment, modelPath: url.path, sessionOptions: options)
        guard try session.inputNames() == ["input"], try session.outputNames() == ["embedding"] else {
            throw IdentityPhotoFailure(message: "モデルの入出力が一致しません。")
        }
    }
    func embedding(_ image: CGImage) throws -> [Float] {
        guard let input = IdentityImagePipeline.rgbTensor(image) else {
            throw IdentityPhotoFailure(message: "画像を変換できないため中止しました。")
        }
        let tensor = try ORTValue(tensorData: input, elementType: .float, shape: [1, 3, 224, 224])
        let output = try session.run(withInputs: ["input": tensor], outputNames: ["embedding"], runOptions: nil)
        guard let value = output["embedding"] else { throw IdentityPhotoFailure(message: "特徴を読み取れませんでした。") }
        let shape = try value.tensorTypeAndShapeInfo()
        let data = try value.tensorData()
        guard shape.elementType == .float, shape.shape.map(\.intValue) == [1, 512], data.length == 512 * 4 else {
            throw IdentityPhotoFailure(message: "特徴の形式が一致しません。")
        }
        var vector = [Float](repeating: 0, count: 512)
        withExtendedLifetime(value) {
            vector.withUnsafeMutableBytes { data.getBytes($0.baseAddress!, length: data.length) }
        }
        guard vector.allSatisfy(\.isFinite), abs(sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) }) - 1) <= 0.005 else {
            throw IdentityPhotoFailure(message: "特徴の数値を検証できないため中止しました。")
        }
        return vector
    }
}
