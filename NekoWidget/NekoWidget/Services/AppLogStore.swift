import Foundation

/// Owns only the two flat files that the app creates for an explicit share
/// sheet. Never enumerate or remove another app's temporary files.
enum TemporaryExportFileLifecycle {
    enum Kind: CaseIterable {
        case verificationJSON
        case diagnosticLog

        fileprivate var prefix: String {
            switch self {
            case .verificationJSON: "neko-widget-"
            case .diagnosticLog: "neko-widget-diagnostics-"
            }
        }

        fileprivate var suffix: String {
            switch self {
            case .verificationJSON: ".json"
            case .diagnosticLog: ".txt"
            }
        }

        fileprivate func matches(_ name: String) -> Bool {
            name.hasPrefix(prefix) && name.hasSuffix(suffix)
        }
    }

    static func removeManagedFile(
        at url: URL?,
        fileManager: FileManager = .default
    ) {
        guard let url else { return }
        let temporaryDirectory = fileManager.temporaryDirectory.standardizedFileURL
        let candidate = url.standardizedFileURL
        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
        guard candidate.deletingLastPathComponent() == temporaryDirectory,
              values?.isRegularFile == true,
              Kind.allCases.contains(where: { $0.matches(candidate.lastPathComponent) })
        else { return }
        try? fileManager.removeItem(at: candidate)
    }

    static func removeManagedFiles(
        kinds: [Kind] = Kind.allCases,
        fileManager: FileManager = .default
    ) {
        let temporaryDirectory = fileManager.temporaryDirectory.standardizedFileURL
        guard let files = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        for file in files where kinds.contains(where: { $0.matches(file.lastPathComponent) }) {
            removeManagedFile(at: file, fileManager: fileManager)
        }
    }
}

actor AppLogStore {
    func load() -> SharedLogReadResult {
        SharedLog.readAll()
    }

    func clear() {
        SharedLog.clearAll()
    }

    func makeExportFile() throws -> URL {
        TemporaryExportFileLifecycle.removeManagedFiles(kinds: [.diagnosticLog])
        let result = SharedLog.readAll()
        var text = "# 猫ウィジェット 診断ログ\n"
        text += "# generatedAt=\(ISO8601DateFormatter().string(from: .now))\n"
        text += "# malformedLines=\(result.malformedLineCount)\n"
        text += "# PhotoKit local identifiers and photo content are intentionally omitted.\n\n"
        text += SharedLog.formattedText(for: result.entries)
        text += "\n"

        let filename = "neko-widget-diagnostics-\(Int(Date().timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            filename,
            isDirectory: false
        )
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            TemporaryExportFileLifecycle.removeManagedFile(at: url)
            throw error
        }
    }
}
