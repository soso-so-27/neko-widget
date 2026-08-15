import Foundation

struct JSONExporter {
    func export(_ snapshot: LibrarySnapshot) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "neko-widget-\(formatter.string(from: .now)).json"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename, isDirectory: false)
        try AtomicJSON.write(snapshot, to: url)
        return url
    }
}
