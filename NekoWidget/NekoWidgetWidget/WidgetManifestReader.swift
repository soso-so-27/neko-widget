import Foundation

enum WidgetManifestReader {
    private static let manifestFilename = "widget-manifest.json"
    private static let cacheDirectoryName = "widget-cache"

    static func availableItems() -> [WidgetManifestItem] {
        guard let containerURL = SharedContainer.containerURL else {
            SharedLog.widget.error(
                "manifest",
                "App Group container is unavailable",
                metadata: ["group": SharedContainer.appGroupIdentifier]
            )
            return []
        }
        guard let manifest = readManifest(from: containerURL) else { return [] }

        let cacheDirectoryURL = containerURL
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)

        let available = manifest.items.filter { item in
            guard cacheURL(for: item.cacheFilename, in: cacheDirectoryURL) != nil else {
                return false
            }

            let fileURL = cacheDirectoryURL
                .appendingPathComponent(item.cacheFilename, isDirectory: false)
            return FileManager.default.fileExists(atPath: fileURL.path)
        }
        SharedLog.widget.debug(
            "manifest",
            "Widget manifest read",
            metadata: [
                "available": "\(available.count)",
                "declared": "\(manifest.items.count)",
                "missing": "\(manifest.items.count - available.count)"
            ]
        )
        return available
    }

    static func cacheURL(for filename: String) -> URL? {
        guard let containerURL = SharedContainer.containerURL else { return nil }
        let cacheDirectoryURL = containerURL
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)
        return cacheURL(for: filename, in: cacheDirectoryURL)
    }

    private static func readManifest(from containerURL: URL) -> WidgetManifest? {
        let manifestURL = containerURL
            .appendingPathComponent(manifestFilename, isDirectory: false)

        guard let data = try? Data(contentsOf: manifestURL, options: .mappedIfSafe) else {
            SharedLog.widget.warning("manifest", "Widget manifest file is unavailable")
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(WidgetManifest.self, from: data)
        } catch {
            let value = error as NSError
            SharedLog.widget.error(
                "manifest",
                "Widget manifest decode failed",
                metadata: [
                    "bytes": "\(data.count)",
                    "code": "\(value.code)",
                    "domain": value.domain
                ]
            )
            return nil
        }
    }

    private static func cacheURL(for filename: String, in directoryURL: URL) -> URL? {
        guard
            !filename.isEmpty,
            filename == (filename as NSString).lastPathComponent,
            filename.lowercased().hasSuffix(".jpg") || filename.lowercased().hasSuffix(".jpeg")
        else {
            return nil
        }

        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }
}
