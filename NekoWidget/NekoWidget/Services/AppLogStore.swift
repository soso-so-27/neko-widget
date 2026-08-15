import Foundation

actor AppLogStore {
    func load() -> SharedLogReadResult {
        SharedLog.readAll()
    }

    func clear() {
        SharedLog.clearAll()
    }

    func makeExportFile() throws -> URL {
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
        try data.write(to: url, options: .atomic)
        return url
    }
}
