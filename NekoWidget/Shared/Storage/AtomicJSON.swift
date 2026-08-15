import Foundation

enum AtomicJSON {
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try makeDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        // Encoder/decoder instances are intentionally not shared. LibraryStore
        // and WidgetCacheBuilder can run on different actors at the same time,
        // and Foundation does not document JSONEncoder as thread-safe.
        let data = try makeEncoder().encode(value)
        try data.write(to: url, options: .atomic)

        // Widget data must remain readable after the first device unlock.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}
