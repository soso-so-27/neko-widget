import CoreGraphics
import CryptoKit
import Foundation
import OnnxRuntimeBindings

/// General COCO cat detection only, never A/B identity or a verified cat count.
/// YOLOX preprocessing/decoding/NMS follows the Apache-2.0 Megvii demo:
/// https://github.com/Megvii-BaseDetection/YOLOX/blob/main/demo/ONNXRuntime/onnx_inference.py
/// https://github.com/Megvii-BaseDetection/YOLOX/blob/main/yolox/utils/demo_utils.py
/// Call serially on the photo worker. No image, tensor or result is retained by this object.
final class CandidateObjectDetector {
    static let modelSHA256 = "c5c2d13e59ae883e6af3b45daea64af4833a4951c92d116ec270d9ddbe998063"
    static let modelByteCount = 35_858_002
    static let inputSide = 640
    static let outputRows = 8_400
    static let outputColumns = 85

    enum Failure: Error, Equatable {
        case missingModel, modelMismatch, modelContract, invalidImage, rasterization
        case outputContract, invalidOutput, invalidBox
    }

    struct Input {
        let values: [Float]
        let resizedWidth: Int
        let resizedHeight: Int
    }

    struct ScoredBox: Equatable {
        let box: CGRect
        let score: Float
        let classIndex: Int
    }

    private let environment: ORTEnv
    private let session: ORTSession

    init(bundle: Bundle = .main) throws {
        try Task.checkCancellation()
        guard let url = bundle.url(forResource: "yolox-s", withExtension: "onnx") else {
            throw Failure.missingModel
        }
        let model = try Data(contentsOf: url, options: .mappedIfSafe)
        guard model.count == Self.modelByteCount,
              SHA256.hash(data: model).map({ String(format: "%02x", $0) }).joined() == Self.modelSHA256 else {
            throw Failure.modelMismatch
        }
        try Task.checkCancellation()
        environment = try ORTEnv(loggingLevel: .error)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setLogSeverityLevel(.error)
        // No execution provider is appended: the existing ORT CPU provider is used.
        session = try ORTSession(env: environment, modelPath: url.path, sessionOptions: options)
        guard try session.inputNames() == ["images"], try session.outputNames() == ["output"] else {
            throw Failure.modelContract
        }
        try Task.checkCancellation()
    }

    /// Returns raw, unclipped TOP-LEFT original-image pixel rectangles.
    /// Negative origins are legal; invalid dimensions or numbers throw, not "no cats".
    func detect(_ image: CGImage) throws -> [CGRect] {
        try Task.checkCancellation()
        let input = try Self.preprocess(image)
        let bytes = input.values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        let tensor = try ORTValue(tensorData: bytes, elementType: .float, shape: [1, 3, 640, 640])
        try Task.checkCancellation()
        let result = try session.run(withInputs: ["images": tensor], outputNames: ["output"], runOptions: nil)
        // A synchronous ORT call may finish after cancellation; never publish its result.
        try Task.checkCancellation()
        guard let value = result["output"] else { throw Failure.outputContract }
        let info = try value.tensorTypeAndShapeInfo()
        let data = try value.tensorData()
        let shape = info.shape.map(\.intValue)
        guard info.elementType == .float, shape == [1, Self.outputRows, Self.outputColumns],
              data.length == Self.outputRows * Self.outputColumns * MemoryLayout<Float>.size else {
            throw Failure.outputContract
        }
        var output = [Float](repeating: 0, count: Self.outputRows * Self.outputColumns)
        withExtendedLifetime(value) {
            output.withUnsafeMutableBytes { data.getBytes($0.baseAddress!, length: data.length) }
        }
        return try Self.catBoxes(output, shape: shape, width: image.width, height: image.height)
    }

    private static func resizedSize(width: Int, height: Int) throws -> (width: Int, height: Int, ratio: Double) {
        guard (1...1024).contains(width), (1...1024).contains(height) else { throw Failure.invalidImage }
        let ratio = min(Double(inputSide) / Double(width), Double(inputSide) / Double(height))
        let resizedWidth = Int(Double(width) * ratio)
        let resizedHeight = Int(Double(height) * ratio)
        guard resizedWidth > 0, resizedHeight > 0,
              resizedWidth <= inputSide, resizedHeight <= inputSide else { throw Failure.invalidImage }
        return (resizedWidth, resizedHeight, ratio)
    }

    static func preprocess(_ image: CGImage) throws -> Input {
        try Task.checkCancellation()
        _ = try resizedSize(width: image.width, height: image.height)
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                return false
            }
            context.interpolationQuality = .none
            // At native dimensions, keep raster row order; do not crop or vertically flip.
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw Failure.rasterization }
        return try tensor(rgba: rgba, width: image.width, height: image.height)
    }

    /// Explicit half-pixel bilinear sampling, with edge replication and 8-bit rounding.
    /// This fixes OpenCV's coordinate convention, not byte-identical platform color conversion
    /// or its optimized fixed-point interpolation rounding. Device fixtures must be measured.
    static func tensor(rgba: [UInt8], width: Int, height: Int) throws -> Input {
        try Task.checkCancellation()
        let size = try resizedSize(width: width, height: height)
        guard rgba.count == width * height * 4 else { throw Failure.invalidImage }
        struct Sample {
            let low: Int
            let high: Int
            let fraction: Double
        }
        func samples(source: Int, destination: Int) -> [Sample] {
            (0..<destination).map { index in
                let coordinate = min(Double(source - 1), max(0,
                    (Double(index) + 0.5) * Double(source) / Double(destination) - 0.5))
                let low = Int(floor(coordinate))
                return Sample(low: low, high: min(low + 1, source - 1), fraction: coordinate - Double(low))
            }
        }
        let columns = samples(source: width, destination: size.width)
        let rows = samples(source: height, destination: size.height)
        let plane = inputSide * inputSide
        var values = [Float](repeating: 114, count: plane * 3)
        for y in rows.indices {
            if y.isMultiple(of: 16) { try Task.checkCancellation() }
            let row = rows[y]
            for x in columns.indices {
                let column = columns[x]
                for channel in 0..<3 {
                    let rgbChannel = 2 - channel // RGBA raster -> planar BGR, 0...255, no normalization.
                    let topLeft = Double(rgba[(row.low * width + column.low) * 4 + rgbChannel])
                    let topRight = Double(rgba[(row.low * width + column.high) * 4 + rgbChannel])
                    let bottomLeft = Double(rgba[(row.high * width + column.low) * 4 + rgbChannel])
                    let bottomRight = Double(rgba[(row.high * width + column.high) * 4 + rgbChannel])
                    let top = topLeft + (topRight - topLeft) * column.fraction
                    let bottom = bottomLeft + (bottomRight - bottomLeft) * column.fraction
                    let sample = (top + (bottom - top) * row.fraction).rounded()
                    values[channel * plane + y * inputSide + x] = Float(min(255, max(0, sample)))
                }
            }
        }
        try Task.checkCancellation()
        return Input(values: values, resizedWidth: size.width, resizedHeight: size.height)
    }

    static func decodedBoxes(_ output: [Float], shape: [Int], width: Int, height: Int) throws -> [ScoredBox] {
        try Task.checkCancellation()
        let size = try resizedSize(width: width, height: height)
        guard shape == [1, outputRows, outputColumns], output.count == outputRows * outputColumns else {
            throw Failure.outputContract
        }
        var boxes: [ScoredBox] = []
        var index = 0
        for stride in [8, 16, 32] {
            let side = inputSide / stride
            for y in 0..<side { for x in 0..<side {
                if index.isMultiple(of: 128) { try Task.checkCancellation() }
                let offset = index * outputColumns
                index += 1
                guard output[offset..<(offset + outputColumns)].allSatisfy(\.isFinite) else {
                    throw Failure.invalidOutput
                }
                let centerX = (output[offset] + Float(x)) * Float(stride)
                let centerY = (output[offset + 1] + Float(y)) * Float(stride)
                let boxWidth = exp(output[offset + 2]) * Float(stride)
                let boxHeight = exp(output[offset + 3]) * Float(stride)
                guard centerX.isFinite, centerY.isFinite, boxWidth.isFinite, boxHeight.isFinite,
                      boxWidth > 0, boxHeight > 0 else { throw Failure.invalidBox }
                let left = Double(centerX - boxWidth / 2) / size.ratio
                let top = Double(centerY - boxHeight / 2) / size.ratio
                let right = Double(centerX + boxWidth / 2) / size.ratio
                let bottom = Double(centerY + boxHeight / 2) / size.ratio
                guard [left, top, right, bottom].allSatisfy(\.isFinite), right > left, bottom > top else {
                    throw Failure.invalidBox
                }
                let objectness = output[offset + 4]
                guard (0...1).contains(objectness) else { throw Failure.invalidOutput }
                var bestScore: Float = -1
                var bestClass = 0
                for classIndex in 0..<80 {
                    let probability = output[offset + 5 + classIndex]
                    guard (0...1).contains(probability) else { throw Failure.invalidOutput }
                    let score = objectness * probability
                    if score > bestScore { bestScore = score; bestClass = classIndex }
                }
                if bestScore > 0.1 {
                    boxes.append(ScoredBox(box: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                        score: bestScore, classIndex: bestClass))
                }
            } }
        }
        try Task.checkCancellation()
        return boxes
    }

    static func suppressOverlaps(_ boxes: [ScoredBox]) throws -> [ScoredBox] {
        try Task.checkCancellation()
        guard boxes.count <= outputRows else { throw Failure.outputContract }
        for item in boxes {
            guard !item.box.isNull, !item.box.isInfinite,
                  [item.box.origin.x, item.box.origin.y, item.box.size.width, item.box.size.height, item.box.maxX, item.box.maxY].allSatisfy(\.isFinite),
                  item.box.size.width > 0, item.box.size.height > 0 else { throw Failure.invalidBox }
            guard item.score.isFinite, (0...1).contains(item.score), (0..<80).contains(item.classIndex) else {
                throw Failure.invalidOutput
            }
        }
        // Stable index order breaks equal-score ties deterministically; no class-specific NMS.
        var order = boxes.indices.sorted {
            boxes[$0].score == boxes[$1].score ? $0 < $1 : boxes[$0].score > boxes[$1].score
        }
        var kept: [ScoredBox] = []
        while let first = order.first {
            try Task.checkCancellation()
            let selected = boxes[first]
            kept.append(selected)
            var remaining: [Int] = []
            for other in order.dropFirst() {
                let next = boxes[other]
                // Inclusive-coordinate +1 matches the official NumPy NMS, including its edge behavior.
                let width = max(0, min(selected.box.maxX, next.box.maxX) - max(selected.box.minX, next.box.minX) + 1)
                let height = max(0, min(selected.box.maxY, next.box.maxY) - max(selected.box.minY, next.box.minY) + 1)
                let intersection = width * height
                let union = (selected.box.width + 1) * (selected.box.height + 1)
                    + (next.box.width + 1) * (next.box.height + 1) - intersection
                guard intersection.isFinite, union.isFinite, union > 0 else { throw Failure.invalidBox }
                if intersection / union <= 0.45 { remaining.append(other) }
            }
            order = remaining
        }
        try Task.checkCancellation()
        return kept
    }

    static func catBoxes(_ output: [Float], shape: [Int], width: Int, height: Int) throws -> [CGRect] {
        let decoded = try decodedBoxes(output, shape: shape, width: width, height: height)
        let kept = try suppressOverlaps(decoded)
        let cats = kept.filter { $0.classIndex == 15 && $0.score >= 0.3 }.map(\.box)
        try Task.checkCancellation()
        return cats
    }
}
