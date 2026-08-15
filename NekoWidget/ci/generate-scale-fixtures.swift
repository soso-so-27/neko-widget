#!/usr/bin/env swift

import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let usage = """
Usage:
  generate-scale-fixtures --source-dir <cc0-fixture-directory> \\
    --output-dir <temporary-output-directory> --count <1000...3000>

The count includes three 8000x6000 large fixtures and four warm-up fixtures.
When RUNNER_TEMP is set, output-dir must be inside RUNNER_TEMP.
"""

private enum GeneratorError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case invalidSource(String)
    case output(String)
    case image(String)

    var description: String {
        switch self {
        case .invalidArgument(let message),
             .invalidSource(let message),
             .output(let message),
             .image(let message):
            return message
        }
    }
}

private struct Arguments {
    let sourceDirectory: URL
    let outputDirectory: URL
    let totalCount: Int

    static func parse(_ values: [String]) throws -> Arguments {
        var sourcePath: String?
        var outputPath: String?
        var count: Int?
        var index = 1

        while index < values.count {
            let flag = values[index]
            guard index + 1 < values.count else {
                throw GeneratorError.invalidArgument("Missing value for \(flag).\n\(usage)")
            }
            let value = values[index + 1]
            switch flag {
            case "--source-dir":
                sourcePath = value
            case "--output-dir":
                outputPath = value
            case "--count":
                count = Int(value)
            default:
                throw GeneratorError.invalidArgument("Unknown argument: \(flag).\n\(usage)")
            }
            index += 2
        }

        guard let sourcePath, let outputPath, let count else {
            throw GeneratorError.invalidArgument(usage)
        }
        guard (1_000...3_000).contains(count) else {
            throw GeneratorError.invalidArgument("--count must be between 1000 and 3000 inclusive.")
        }

        return Arguments(
            sourceDirectory: URL(fileURLWithPath: sourcePath, isDirectory: true)
                .standardizedFileURL,
            outputDirectory: URL(fileURLWithPath: outputPath, isDirectory: true)
                .standardizedFileURL,
            totalCount: count
        )
    }
}

private enum FixtureRole: String, Codable {
    case bulk
    case large
    case warmup
}

private struct SourceSpecification {
    let fileName: String
    let expectedSHA256: String
}

private struct SourceManifestRecord: Codable {
    let fileName: String
    let height: Int
    let license: String
    let sha256: String
    let width: Int
}

private struct OutputManifestRecord: Codable {
    let bytes: Int64
    let captureDate: String
    let file: String
    let height: Int
    let pixelVariant: String
    let role: FixtureRole
    let sha256: String
    let source: String
    let width: Int
}

private struct LicenseLineage: Codable {
    let externalDownloads: Bool
    let generatedOutputsLicense: String
    let sourceLicense: String
    let sourceLicenseFile: String
    let statement: String
}

private struct ScaleFixtureManifest: Codable {
    let allOutputHashesUnique: Bool
    let generatedAt: String
    let generator: String
    let largeCount: Int
    let licenseLineage: LicenseLineage
    let outputs: [OutputManifestRecord]
    let recommendedImportOrder: [FixtureRole]
    let roleCounts: [String: Int]
    let schemaVersion: Int
    let sources: [SourceManifestRecord]
    let totalBytes: Int64
    let totalCount: Int
    let uniqueOutputHashCount: Int
    let warmupCount: Int
}

private struct LoadedSource {
    let image: CGImage
    let record: SourceManifestRecord
}

private let sourceSpecifications = [
    SourceSpecification(
        fileName: "cat-gray-portrait.png",
        expectedSHA256: "bd5a348e5e6df1b32837c51ab0357505119ea564d13ac4afefe3803b1b8dfbf8"
    ),
    SourceSpecification(
        fileName: "cat-orange-square.png",
        expectedSHA256: "b24f0ca8d3807e8c0b4845a48e15376a4faa8655d7e1f58ac327029d382e8250"
    ),
    SourceSpecification(
        fileName: "cat-tuxedo-landscape.png",
        expectedSHA256: "78fd299ab3a138b9832b2ae0a3a115908073d3171c46b0ade73875e6dde19fd4"
    )
]

private let largeCount = 3
private let warmupCount = 4

private func zeroPadded(_ value: Int, width: Int, radix: Int = 10) -> String {
    let digits = String(value, radix: radix, uppercase: false)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
}

private func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: 1_048_576) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
    }
    let hexadecimal = Array("0123456789abcdef")
    var result = ""
    result.reserveCapacity(64)
    for byte in hasher.finalize() {
        result.append(hexadecimal[Int(byte >> 4)])
        result.append(hexadecimal[Int(byte & 0x0F)])
    }
    return result
}

private func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

private func exifDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return formatter.string(from: date)
}

private func loadSources(from directory: URL) throws -> [LoadedSource] {
    guard FileManager.default.fileExists(atPath: directory.path) else {
        throw GeneratorError.invalidSource("Source directory does not exist: \(directory.path)")
    }

    return try sourceSpecifications.map { specification in
        let url = directory.appendingPathComponent(specification.fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GeneratorError.invalidSource("Required CC0 source is missing: \(specification.fileName)")
        }
        let actualHash = try sha256(of: url)
        guard actualHash == specification.expectedSHA256 else {
            throw GeneratorError.invalidSource(
                "CC0 source hash mismatch for \(specification.fileName): \(actualHash)"
            )
        }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw GeneratorError.image("Could not decode \(specification.fileName).")
        }
        return LoadedSource(
            image: image,
            record: SourceManifestRecord(
                fileName: specification.fileName,
                height: image.height,
                license: "CC0-1.0",
                sha256: actualHash,
                width: image.width
            )
        )
    }
}

private func prepareOutputDirectory(_ output: URL, source: URL) throws {
    let fileManager = FileManager.default
    let outputPath = output.path.hasSuffix("/") ? output.path : output.path + "/"
    let sourcePath = source.path.hasSuffix("/") ? source.path : source.path + "/"
    guard outputPath != sourcePath, !outputPath.hasPrefix(sourcePath) else {
        throw GeneratorError.output("Output must not be inside the licensed source directory.")
    }

    if let runnerTemp = ProcessInfo.processInfo.environment["RUNNER_TEMP"] {
        let runnerURL = URL(fileURLWithPath: runnerTemp, isDirectory: true).standardizedFileURL
        let runnerPath = runnerURL.path.hasSuffix("/") ? runnerURL.path : runnerURL.path + "/"
        guard outputPath.hasPrefix(runnerPath) else {
            throw GeneratorError.output("On CI, output must be inside RUNNER_TEMP: \(runnerURL.path)")
        }
    }

    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: output.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw GeneratorError.output("Output path exists and is not a directory: \(output.path)")
        }
        let contents = try fileManager.contentsOfDirectory(atPath: output.path)
        guard contents.isEmpty else {
            throw GeneratorError.output("Output directory must be empty: \(output.path)")
        }
    } else {
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
    }

    for role in [FixtureRole.bulk, .large, .warmup] {
        try fileManager.createDirectory(
            at: output.appendingPathComponent(role.rawValue, isDirectory: true),
            withIntermediateDirectories: false
        )
    }
}

private func regularDimensions(for image: CGImage) -> (width: Int, height: Int) {
    let longEdge = 1_280.0
    if image.width >= image.height {
        return (
            Int(longEdge),
            max(1, Int((longEdge * Double(image.height) / Double(image.width)).rounded()))
        )
    }
    return (
        max(1, Int((longEdge * Double(image.width) / Double(image.height)).rounded())),
        Int(longEdge)
    )
}

private func render(
    source: CGImage,
    width: Int,
    height: Int,
    variant: Int
) throws -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw GeneratorError.image("Could not allocate \(width)x\(height) render context.")
    }

    let shade = CGFloat(232 + ((variant * 17) % 13)) / 255
    context.setFillColor(red: shade, green: shade, blue: shade, alpha: 1)
    context.fill(
        CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    )

    let fitScale = min(
        CGFloat(width) / CGFloat(source.width),
        CGFloat(height) / CGFloat(source.height)
    )
    let zoom = 1 + CGFloat(variant % 9) * 0.00075
    let drawWidth = CGFloat(source.width) * fitScale * zoom
    let drawHeight = CGFloat(source.height) * fitScale * zoom
    let jitterX = CGFloat((variant * 37) % 9 - 4)
    let jitterY = CGFloat((variant * 53) % 9 - 4)
    let drawRect = CGRect(
        x: (CGFloat(width) - drawWidth) / 2 + jitterX,
        y: (CGFloat(height) - drawHeight) / 2 + jitterY,
        width: drawWidth,
        height: drawHeight
    )
    context.interpolationQuality = .high
    context.draw(source, in: drawRect)

    // Encode the global fixture index into actual pixels. A 4x4 monochrome
    // marker is tiny relative to the photo but large enough to survive JPEG
    // encoding, so distinct filenames/metadata are not the only difference.
    let cell = max(4, min(12, min(width, height) / 512))
    let margin = cell * 2
    for bitIndex in 0..<16 {
        let isSet = (variant & (1 << bitIndex)) != 0
        context.setFillColor(
            red: isSet ? 0.94 : 0.06,
            green: isSet ? 0.94 : 0.06,
            blue: isSet ? 0.94 : 0.06,
            alpha: 1
        )
        context.fill(
            CGRect(
                x: CGFloat(margin + (bitIndex % 4) * cell),
                y: CGFloat(margin + (bitIndex / 4) * cell),
                width: CGFloat(cell),
                height: CGFloat(cell)
            )
        )
    }

    guard let image = context.makeImage() else {
        throw GeneratorError.image("Could not finalize \(width)x\(height) render context.")
    }
    return image
}

private func writeJPEG(
    _ image: CGImage,
    to url: URL,
    quality: Double,
    captureDate: Date
) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        throw GeneratorError.image("Could not create JPEG destination: \(url.lastPathComponent)")
    }

    let dateValue = exifDate(captureDate)
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: quality,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: dateValue,
            kCGImagePropertyExifDateTimeDigitized: dateValue
        ] as [CFString: Any],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFDateTime: dateValue
        ] as [CFString: Any]
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw GeneratorError.image("Could not finalize JPEG: \(url.lastPathComponent)")
    }
    try FileManager.default.setAttributes(
        [.creationDate: captureDate, .modificationDate: captureDate],
        ofItemAtPath: url.path
    )
}

private func verifyDimensions(of url: URL, width: Int, height: Int) throws {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
          let actualWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let actualHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber,
          actualWidth.intValue == width,
          actualHeight.intValue == height else {
        throw GeneratorError.image(
            "Encoded JPEG dimensions did not match \(width)x\(height): \(url.lastPathComponent)"
        )
    }
}

private func fileSize(of url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let value = attributes[.size] as? NSNumber else {
        throw GeneratorError.output("Could not read output size: \(url.lastPathComponent)")
    }
    return value.int64Value
}

private func makeFixture(
    outputRoot: URL,
    role: FixtureRole,
    roleIndex: Int,
    globalIndex: Int,
    source: LoadedSource,
    width: Int,
    height: Int,
    quality: Double,
    captureDate: Date
) throws -> OutputManifestRecord {
    let stem = URL(fileURLWithPath: source.record.fileName).deletingPathExtension().lastPathComponent
    let fileName: String
    switch role {
    case .large:
        let ordinal = zeroPadded(roleIndex + 1, width: 2)
        fileName = "large-\(ordinal)-8000x6000-\(stem).jpg"
    case .bulk, .warmup:
        let ordinal = zeroPadded(roleIndex + 1, width: 4)
        fileName = "\(role.rawValue)-\(ordinal)-\(stem).jpg"
    }
    let relativePath = "\(role.rawValue)/\(fileName)"
    let outputURL = outputRoot.appendingPathComponent(relativePath, isDirectory: false)

    let image = try render(
        source: source.image,
        width: width,
        height: height,
        variant: globalIndex
    )
    try writeJPEG(image, to: outputURL, quality: quality, captureDate: captureDate)
    try verifyDimensions(of: outputURL, width: width, height: height)

    return OutputManifestRecord(
        bytes: try fileSize(of: outputURL),
        captureDate: iso8601(captureDate),
        file: relativePath,
        height: height,
        pixelVariant: zeroPadded(globalIndex, width: 4, radix: 16),
        role: role,
        sha256: try sha256(of: outputURL),
        source: source.record.fileName,
        width: width
    )
}

private func run() throws {
    if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
        print(usage)
        return
    }

    let arguments = try Arguments.parse(CommandLine.arguments)
    let sources = try loadSources(from: arguments.sourceDirectory)
    try prepareOutputDirectory(arguments.outputDirectory, source: arguments.sourceDirectory)

    let bulkCount = arguments.totalCount - largeCount - warmupCount
    let generatedAt = Date()
    var outputs: [OutputManifestRecord] = []
    outputs.reserveCapacity(arguments.totalCount)
    var globalIndex = 0

    // Bulk dates end at least ten minutes before the large group. The role
    // order remains deterministic even if simctl imports files in batches.
    for roleIndex in 0..<bulkCount {
        let source = sources[roleIndex % sources.count]
        let dimensions = regularDimensions(for: source.image)
        let captureDate = generatedAt.addingTimeInterval(
            -Double(bulkCount - roleIndex) - 600
        )
        let record = try autoreleasepool { () throws -> OutputManifestRecord in
            try makeFixture(
                outputRoot: arguments.outputDirectory,
                role: .bulk,
                roleIndex: roleIndex,
                globalIndex: globalIndex,
                source: source,
                width: dimensions.width,
                height: dimensions.height,
                quality: 0.68,
                captureDate: captureDate
            )
        }
        outputs.append(record)
        globalIndex += 1
    }

    guard let landscapeSource = sources.first(where: { $0.image.width > $0.image.height }) else {
        throw GeneratorError.invalidSource("A landscape CC0 source is required for large fixtures.")
    }
    for roleIndex in 0..<largeCount {
        let captureDate = generatedAt.addingTimeInterval(-300 + Double(roleIndex))
        let record = try autoreleasepool { () throws -> OutputManifestRecord in
            try makeFixture(
                outputRoot: arguments.outputDirectory,
                role: .large,
                roleIndex: roleIndex,
                globalIndex: globalIndex,
                source: landscapeSource,
                width: 8_000,
                height: 6_000,
                quality: 0.72,
                captureDate: captureDate
            )
        }
        outputs.append(record)
        globalIndex += 1
    }

    // These four newest regular-size assets warm Vision before the scanner
    // reaches the three large sources, keeping model initialization out of the
    // high-resolution memory window.
    for roleIndex in 0..<warmupCount {
        let source = sources[roleIndex % sources.count]
        let dimensions = regularDimensions(for: source.image)
        let captureDate = generatedAt.addingTimeInterval(-60 + Double(roleIndex))
        let record = try autoreleasepool { () throws -> OutputManifestRecord in
            try makeFixture(
                outputRoot: arguments.outputDirectory,
                role: .warmup,
                roleIndex: roleIndex,
                globalIndex: globalIndex,
                source: source,
                width: dimensions.width,
                height: dimensions.height,
                quality: 0.68,
                captureDate: captureDate
            )
        }
        outputs.append(record)
        globalIndex += 1
    }

    guard outputs.count == arguments.totalCount else {
        throw GeneratorError.output(
            "Generated \(outputs.count) fixtures; expected \(arguments.totalCount)."
        )
    }
    let uniqueHashes = Set(outputs.map(\.sha256))
    guard uniqueHashes.count == outputs.count else {
        throw GeneratorError.output(
            "Generated output hashes are not unique: \(uniqueHashes.count)/\(outputs.count)."
        )
    }

    let manifest = ScaleFixtureManifest(
        allOutputHashesUnique: true,
        generatedAt: iso8601(generatedAt),
        generator: "ci/generate-scale-fixtures.swift",
        largeCount: largeCount,
        licenseLineage: LicenseLineage(
            externalDownloads: false,
            generatedOutputsLicense: "CC0-1.0",
            sourceLicense: "CC0-1.0",
            sourceLicenseFile: "ci/fixtures/cats/LICENSE.md",
            statement: "Outputs are pixel-modified derivatives of only the three hash-pinned repository fixtures."
        ),
        outputs: outputs,
        recommendedImportOrder: [.bulk, .large, .warmup],
        roleCounts: [
            FixtureRole.bulk.rawValue: bulkCount,
            FixtureRole.large.rawValue: largeCount,
            FixtureRole.warmup.rawValue: warmupCount
        ],
        schemaVersion: 1,
        sources: sources.map(\.record),
        totalBytes: outputs.reduce(0) { $0 + $1.bytes },
        totalCount: outputs.count,
        uniqueOutputHashCount: uniqueHashes.count,
        warmupCount: warmupCount
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var manifestData = try encoder.encode(manifest)
    manifestData.append(0x0A)
    let manifestURL = arguments.outputDirectory
        .appendingPathComponent("scale-fixture-manifest.json", isDirectory: false)
    try manifestData.write(to: manifestURL, options: .atomic)

    print("Generated \(outputs.count) unique scale fixtures (bulk=\(bulkCount), large=3, warmup=4).")
    print("Bytes: \(outputs.reduce(0) { $0 + $1.bytes })")
    print("Manifest: \(manifestURL.path)")
}

do {
    try run()
} catch {
    let message = "Scale fixture generation failed: \(error)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}
