import Foundation
import OSLog

enum SharedLogLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error
}

enum SharedLogProcess: String, Codable, CaseIterable, Sendable {
    case app
    case widget
}

struct SharedLogEntry: Codable, Identifiable, Sendable {
    var id: UUID
    var timestamp: Date
    var level: SharedLogLevel
    var category: String
    var process: SharedLogProcess
    var message: String
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        level: SharedLogLevel,
        category: String,
        process: SharedLogProcess,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.process = process
        self.message = message
        self.metadata = metadata
    }
}

struct SharedLogReadResult: Sendable {
    var entries: [SharedLogEntry]
    var malformedLineCount: Int
}

/// Privacy-conscious diagnostics shared by the app and WidgetKit extension.
///
/// Every process launch writes a session-specific JSONL stream, so concurrent
/// WidgetKit processes never append to the same inode. In-process writes are
/// serialized with `NSLock`. The log screen merges all retained streams by
/// their embedded timestamps. Callers must use `shortHash(_:)` instead of
/// writing PhotoKit local identifiers.
enum SharedLog {
    static let app = SharedFileLogger(process: .app)
    static let widget = SharedFileLogger(process: .widget)

    static let maximumFileBytes: UInt64 = 192 * 1_024
    static let maximumRotationIndex = 1
    fileprivate static let privacySafeSessionPrefix = "p2"

    /// Returns diagnostics that are safe to persist and export. The caller
    /// supplies a closed category; arbitrary NSError text and userInfo are
    /// deliberately ignored. Unknown/custom domains are collapsed to `other`.
    static func errorMetadata(
        _ error: Error,
        category: SharedLogErrorCategory,
        additional: [String: String] = [:]
    ) -> [String: String] {
        let value = error as NSError
        return errorMetadata(
            domain: value.domain,
            code: value.code,
            category: category,
            additional: additional
        )
    }

    static func errorMetadata(
        domain: String?,
        code: Int?,
        category: SharedLogErrorCategory,
        additional: [String: String] = [:]
    ) -> [String: String] {
        DiagnosticLogPrivacy.errorMetadata(
            domain: domain,
            code: code,
            category: category,
            additional: additional
        )
    }

    static func stableErrorDomain(_ domain: String?) -> String {
        DiagnosticLogPrivacy.stableErrorDomain(domain)
    }

    static func shortHash(_ value: String) -> String {
        // FNV-1a is deliberately non-reversible for diagnostic correlation.
        // It is not used for security decisions or persistent identity.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%012llx", hash & 0x0000_FFFF_FFFF_FFFF)
    }

    static func readAll() -> SharedLogReadResult {
        guard let directoryURL = SharedContainer.logsDirectoryURL else {
            return SharedLogReadResult(entries: [], malformedLineCount: 0)
        }

        // Older builds could persist raw NSError text. Delete those physical
        // files before enumerating anything that can be displayed or exported.
        purgeLegacyUnsafeLogs(in: directoryURL)

        let decoder = JSONDecoder()
        // Fractional-second precision preserves the order of rapid scan/widget
        // breadcrumbs that frequently occur within the same wall-clock second.
        decoder.dateDecodingStrategy = .secondsSince1970
        var entries: [SharedLogEntry] = []
        var malformedLineCount = 0

        let urls = privacySafeLogURLs(in: directoryURL).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        for url in urls {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                continue
            }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                do {
                    let entry = try decoder.decode(SharedLogEntry.self, from: Data(line))
                    entries.append(sanitizedEntry(entry))
                } catch {
                    // A killed extension can leave one partial final line.
                    // Preserve every other readable entry and surface the
                    // count in the in-app log screen.
                    malformedLineCount += 1
                }
            }
        }

        entries.sort {
            if $0.timestamp == $1.timestamp {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.timestamp < $1.timestamp
        }
        return SharedLogReadResult(
            entries: entries,
            malformedLineCount: malformedLineCount
        )
    }

    static func formattedText(for entries: [SharedLogEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries.map { rawEntry in
            let entry = sanitizedEntry(rawEntry)
            let metadata = entry.metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\(quotedIfNeeded($0.value))" }
                .joined(separator: " ")
            let prefix = "[\(formatter.string(from: entry.timestamp))] [\(entry.level.rawValue.uppercased())] [\(entry.process.rawValue)/\(entry.category)]"
            return metadata.isEmpty
                ? "\(prefix) \(entry.message)"
                : "\(prefix) \(entry.message) | \(metadata)"
        }.joined(separator: "\n")
    }

    static func clearAll() {
        app.clearAllRetainedFiles()
    }

    fileprivate static func fileURL(
        sessionStem: String,
        rotationIndex: Int,
        in directoryURL: URL
    ) -> URL {
        let suffix = rotationIndex == 0 ? "" : ".\(rotationIndex)"
        return directoryURL.appendingPathComponent(
            "\(sessionStem)\(suffix).jsonl",
            isDirectory: false
        )
    }

    fileprivate static func recognizedLogURLs(in directoryURL: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.filter { url in
            let name = url.lastPathComponent
            return name.hasSuffix(".jsonl")
                && SharedLogProcess.allCases.contains { name.hasPrefix("\($0.rawValue)-") }
                && sessionStem(from: name) != nil
        }
    }

    fileprivate static func privacySafeLogURLs(in directoryURL: URL) -> [URL] {
        recognizedLogURLs(in: directoryURL).filter { url in
            guard let stem = sessionStem(from: url.lastPathComponent) else {
                return false
            }
            return sessionStemIsPrivacySafe(stem)
        }
    }

    fileprivate static func purgeLegacyUnsafeLogs(in directoryURL: URL) {
        for url in recognizedLogURLs(in: directoryURL) {
            guard let stem = sessionStem(from: url.lastPathComponent),
                  !sessionStemIsPrivacySafe(stem)
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    fileprivate static func sessionStemIsPrivacySafe(_ stem: String) -> Bool {
        let pieces = stem.split(separator: "-", omittingEmptySubsequences: false)
        return pieces.count == 4
            && pieces[3].hasPrefix(privacySafeSessionPrefix)
    }

    fileprivate static func sessionStem(from filename: String) -> String? {
        guard filename.hasSuffix(".jsonl") else { return nil }
        var stem = String(filename.dropLast(".jsonl".count))
        if let dot = stem.lastIndex(of: "."),
           Int(stem[stem.index(after: dot)...]) != nil {
            stem = String(stem[..<dot])
        }
        let pieces = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 4,
              SharedLogProcess(rawValue: String(pieces[0])) != nil,
              Int64(pieces[1]) != nil,
              Int32(pieces[2]) != nil,
              pieces[3].count == 12 else {
            return nil
        }
        return stem
    }

    private static func quotedIfNeeded(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || $0 == "=" || $0 == "\"" }) else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    fileprivate static func sanitizedEntry(_ entry: SharedLogEntry) -> SharedLogEntry {
        SharedLogEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            level: entry.level,
            category: sanitizedText(entry.category, maximumLength: 48),
            process: entry.process,
            message: sanitizedText(entry.message, maximumLength: 600),
            metadata: sanitizedMetadata(entry.metadata)
        )
    }

    fileprivate static func sanitizedMetadata(
        _ metadata: [String: String]
    ) -> [String: String] {
        DiagnosticLogPrivacy.sanitizeMetadata(metadata)
    }

    fileprivate static func sanitizedText(
        _ value: String,
        maximumLength: Int
    ) -> String {
        DiagnosticLogPrivacy.sanitizeText(value, maximumLength: maximumLength)
    }
}

final class SharedFileLogger: @unchecked Sendable {
    private let process: SharedLogProcess
    private let lock = NSLock()
    private let sessionStem: String
    private let systemLogger: Logger
    private var didPruneSessions = false

    fileprivate init(process: SharedLogProcess) {
        self.process = process
        let startedMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        let session = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let safeSession = "\(SharedLog.privacySafeSessionPrefix)\(session.prefix(10).lowercased())"
        sessionStem = "\(process.rawValue)-\(startedMilliseconds)-\(ProcessInfo.processInfo.processIdentifier)-\(safeSession)"
        systemLogger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "NekoWidget",
            category: process.rawValue
        )
    }

    fileprivate func clearAllRetainedFiles() {
        guard let directoryURL = SharedContainer.logsDirectoryURL else { return }
        lock.lock()
        defer { lock.unlock() }
        for url in SharedLog.recognizedLogURLs(in: directoryURL) {
            try? FileManager.default.removeItem(at: url)
        }
        // A concurrent WidgetKit process can recreate its own session file
        // immediately after clear; this is intentional and produces a valid
        // new stream rather than cross-process mutation of an existing file.
    }

    func debug(
        _ category: String,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        log(.debug, category, message, metadata: metadata)
    }

    func info(
        _ category: String,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        log(.info, category, message, metadata: metadata)
    }

    func warning(
        _ category: String,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        log(.warning, category, message, metadata: metadata)
    }

    func error(
        _ category: String,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        log(.error, category, message, metadata: metadata)
    }

    fileprivate func log(
        _ level: SharedLogLevel,
        _ category: String,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        let entry = SharedLogEntry(
            level: level,
            category: SharedLog.sanitizedText(category, maximumLength: 48),
            process: process,
            message: SharedLog.sanitizedText(message, maximumLength: 600),
            metadata: SharedLog.sanitizedMetadata(metadata)
        )

        lock.lock()
        defer { lock.unlock() }
        do {
            try append(entry)
        } catch {
            let value = error as NSError
            let domain = SharedLog.stableErrorDomain(value.domain)
            systemLogger.error(
                "file-log: JSONL append failed category=\(SharedLogErrorCategory.fileIO.rawValue, privacy: .public) domain=\(domain, privacy: .public) code=\(value.code, privacy: .public)"
            )
        }
        writeToUnifiedLog(entry)
    }

    private func append(_ entry: SharedLogEntry) throws {
        guard let directoryURL = SharedContainer.logsDirectoryURL else { return }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.path
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(entry)
        data.append(0x0A)

        var currentURL = SharedLog.fileURL(
            sessionStem: sessionStem,
            rotationIndex: 0,
            in: directoryURL
        )
        if !FileManager.default.fileExists(atPath: currentURL.path) {
            FileManager.default.createFile(atPath: currentURL.path, contents: nil)
        }

        var handle = try FileHandle(forWritingTo: currentURL)
        var currentSize = try handle.seekToEnd()
        if currentSize + UInt64(data.count) > SharedLog.maximumFileBytes {
            try handle.close()
            try rotate(in: directoryURL)
            currentURL = SharedLog.fileURL(
                sessionStem: sessionStem,
                rotationIndex: 0,
                in: directoryURL
            )
            FileManager.default.createFile(atPath: currentURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: currentURL)
            currentSize = 0
        }

        defer { try? handle.close() }
        if currentSize > 0 { try handle.seekToEnd() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: currentURL.path
        )
        if !didPruneSessions {
            pruneSessions(in: directoryURL)
            didPruneSessions = true
        }
    }

    private func rotate(in directoryURL: URL) throws {
        let oldest = SharedLog.fileURL(
            sessionStem: sessionStem,
            rotationIndex: SharedLog.maximumRotationIndex,
            in: directoryURL
        )
        try? FileManager.default.removeItem(at: oldest)

        guard SharedLog.maximumRotationIndex > 0 else { return }
        for index in stride(
            from: SharedLog.maximumRotationIndex - 1,
            through: 0,
            by: -1
        ) {
            let source = SharedLog.fileURL(
                sessionStem: sessionStem,
                rotationIndex: index,
                in: directoryURL
            )
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = SharedLog.fileURL(
                sessionStem: sessionStem,
                rotationIndex: index + 1,
                in: directoryURL
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: source, to: destination)
        }
        pruneSessions(in: directoryURL)
    }

    private func pruneSessions(in directoryURL: URL) {
        // Session start milliseconds are encoded in the filename, so retention
        // never reads filesystem creation/modification timestamps.
        let maximumSessions = process == .app ? 4 : 8
        SharedLog.purgeLegacyUnsafeLogs(in: directoryURL)
        let recognizedURLs = SharedLog.recognizedLogURLs(in: directoryURL)
        let grouped = Dictionary(
            grouping: recognizedURLs.filter {
                $0.lastPathComponent.hasPrefix("\(process.rawValue)-")
                    && SharedLog.sessionStem(from: $0.lastPathComponent)
                        .map(SharedLog.sessionStemIsPrivacySafe) == true
            },
            by: { SharedLog.sessionStem(from: $0.lastPathComponent) ?? "" }
        ).filter { !$0.key.isEmpty }

        let orderedStems = grouped.keys.sorted { lhs, rhs in
            let left = Int64(lhs.split(separator: "-")[1]) ?? 0
            let right = Int64(rhs.split(separator: "-")[1]) ?? 0
            if left == right { return lhs > rhs }
            return left > right
        }
        let retained = Set(orderedStems.prefix(maximumSessions)).union([sessionStem])
        for (stem, urls) in grouped where !retained.contains(stem) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func writeToUnifiedLog(_ entry: SharedLogEntry) {
        let metadata = entry.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        switch entry.level {
        case .debug:
            systemLogger.debug("\(entry.category, privacy: .public): \(entry.message, privacy: .public) | \(metadata, privacy: .private(mask: .hash))")
        case .info:
            systemLogger.info("\(entry.category, privacy: .public): \(entry.message, privacy: .public) | \(metadata, privacy: .private(mask: .hash))")
        case .warning:
            systemLogger.warning("\(entry.category, privacy: .public): \(entry.message, privacy: .public) | \(metadata, privacy: .private(mask: .hash))")
        case .error:
            systemLogger.error("\(entry.category, privacy: .public): \(entry.message, privacy: .public) | \(metadata, privacy: .private(mask: .hash))")
        }
    }

}
