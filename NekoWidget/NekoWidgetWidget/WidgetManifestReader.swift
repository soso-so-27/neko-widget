import Foundation

enum WidgetManifestReader {
    private static let manifestFilename = "widget-manifest.json"
    private static let cacheDirectoryName = "widget-cache"

    static func availableItems(for variant: WidgetImageVariant) -> [WidgetManifestItem] {
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
            let filename = item.cacheFilename(for: variant)
            guard cacheURL(for: filename, in: cacheDirectoryURL) != nil else {
                return false
            }

            let fileURL = cacheDirectoryURL
                .appendingPathComponent(filename, isDirectory: false)
            return FileManager.default.fileExists(atPath: fileURL.path)
        }
        SharedLog.widget.debug(
            "manifest",
            "Widget manifest read",
            metadata: [
                "available": "\(available.count)",
                "declared": "\(manifest.items.count)",
                "missing": "\(manifest.items.count - available.count)",
                "variant": variant.rawValue
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

    static func familyItem(
        for variant: WidgetImageVariant,
        localWindowID: String?,
        now: Date = .now
    ) -> FamilyWidgetManifestItem? {
        if let localWindowID {
            guard PrivateWindowCatalogStore.widgetEntries().contains(where: {
                $0.localWindowID == localWindowID
            }) else { return nil }
        }
        guard let manifestURL = SharedContainer.familyWidgetManifestURL(
                  localWindowID: localWindowID
              ),
              let cacheDirectory = SharedContainer.familyWidgetCacheDirectoryURL(
                  localWindowID: localWindowID
              ),
              let manifest = readFamilyManifest(from: manifestURL),
              manifest.schemaVersion == FamilyWidgetManifest.schemaVersion,
              let item = manifest.item,
              item.sourceDigest.utf8.count == 64,
              item.sourceDigest.utf8.allSatisfy({
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }),
              item.freshUntil > item.receivedAt,
              item.freshUntil.timeIntervalSince(item.receivedAt) <= 2 * 60 * 60 + 1,
              now < item.displayUntil
        else { return nil }
        let filename = item.cacheFilenames.filename(for: variant)
        guard let fileURL = cacheURL(for: filename, in: cacheDirectory),
              FileManager.default.fileExists(atPath: fileURL.path),
              let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0,
              size <= variant.maximumJPEGByteCount
        else { return nil }
        return item
    }

    /// Returns only an actionable, coarse reason. A valid empty manifest and
    /// an expired temporary photo are normal waiting states; absent or
    /// unreadable metadata/cache requires the host app to rebuild safely.
    static func familyEmptyStateReason(
        localWindowID: String?,
        now: Date = .now
    ) -> WidgetEmptyStateReason {
        guard let manifestURL = SharedContainer.familyWidgetManifestURL(
                  localWindowID: localWindowID
              )
        else { return .needsApp }
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return .needsApp
        }
        guard let manifest = readFamilyManifest(from: manifestURL),
              manifest.schemaVersion == FamilyWidgetManifest.schemaVersion
        else { return .needsApp }
        guard let item = manifest.item else { return .waiting }
        guard now < item.displayUntil else { return .waiting }
        return .needsApp
    }

    /// The name is presentation-only and remains available even when the
    /// paired window has not received a photo yet. Invalid or pre-naming
    /// manifests fall back without hiding an otherwise valid image.
    static func familyWindowDisplayName(localWindowID: String?) -> String {
        if let localWindowID,
           !PrivateWindowCatalogStore.widgetEntries().contains(where: {
               $0.localWindowID == localWindowID
           }) {
            return "利用できないまど"
        }
        return SharedContainer.familyWidgetWindowDisplayName(localWindowID: localWindowID)
    }

    static func cacheURL(
        for filename: String,
        photoSourceIdentifier: String
    ) -> URL? {
        switch photoSourceIdentifier {
        case WidgetPhotoSource.personalLibraryID:
            return cacheURL(for: filename)
        case let identifier where WidgetPhotoSource.isFamilyWindowSourceID(identifier):
            guard let directory = SharedContainer.familyWidgetCacheDirectoryURL(
                localWindowID: WidgetPhotoSource.localWindowID(from: identifier)
            ) else {
                return nil
            }
            return cacheURL(for: filename, in: directory)
        default:
            return nil
        }
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
            SharedLog.widget.error(
                "manifest",
                "Widget manifest decode failed",
                metadata: SharedLog.errorMetadata(
                    error,
                    category: .widgetManifest,
                    additional: ["bytes": "\(data.count)"]
                )
            )
            return nil
        }
    }

    private static func readFamilyManifest(from url: URL) -> FamilyWidgetManifest? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            SharedLog.widget.warning("manifest", "Family Widget manifest is unavailable")
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(FamilyWidgetManifest.self, from: data)
        } catch {
            SharedLog.widget.error(
                "manifest",
                "Family Widget manifest decode failed",
                metadata: SharedLog.errorMetadata(error, category: .widgetManifest)
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
