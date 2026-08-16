import Foundation

/// URLs shared by the application and its WidgetKit extension.
///
/// Both targets must carry the same `AppGroupIdentifier` Info.plist value and
/// the matching App Group entitlement. The fallback keeps local development
/// deterministic, but it does not replace the entitlement.
enum SharedContainer {
    static var appGroupIdentifier: String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return configured
        }
        return "group.com.example.nekowidget"
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("library-snapshot.json", isDirectory: false)
    }

    static var widgetManifestURL: URL? {
        containerURL?.appendingPathComponent("widget-manifest.json", isDirectory: false)
    }

    /// Build 4 used one global lease. Keep reading it during migration so a
    /// timeline created by the older extension cannot lose its cache files.
    static var legacyWidgetTimelineLeaseURL: URL? {
        containerURL?.appendingPathComponent("widget-timeline-lease.json", isDirectory: false)
    }

    static func widgetTimelineLeaseURL(for variant: WidgetImageVariant) -> URL? {
        containerURL?.appendingPathComponent(
            "widget-timeline-lease-\(variant.rawValue).json",
            isDirectory: false
        )
    }

    static var allWidgetTimelineLeaseURLs: [URL] {
        let familyURLs = WidgetImageVariant.allCases.compactMap {
            widgetTimelineLeaseURL(for: $0)
        }
        if let legacyWidgetTimelineLeaseURL {
            return familyURLs + [legacyWidgetTimelineLeaseURL]
        }
        return familyURLs
    }

    static var widgetCacheDirectoryURL: URL? {
        containerURL?.appendingPathComponent("widget-cache", isDirectory: true)
    }

    static var logsDirectoryURL: URL? {
        containerURL?.appendingPathComponent("diagnostic-logs", isDirectory: true)
    }
}
