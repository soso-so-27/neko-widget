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

    /// Canonical cross-process state for likes created by either the app or an
    /// interactive widget. Keeping this separate from the scan snapshot avoids
    /// a widget read/modify/write racing with a long-running library scan.
    static var likesURL: URL? {
        containerURL?.appendingPathComponent("liked-assets.json", isDirectory: false)
    }

    /// `flock` operates on this stable inode while `liked-assets.json` can be
    /// atomically replaced. Both the app and extension must use the same lock.
    static var likesLockURL: URL? {
        containerURL?.appendingPathComponent("liked-assets.lock", isDirectory: false)
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

    /// Non-secret sharing state. Private keys and the room key live in the
    /// App Group-backed Keychain access group, never in this directory.
    static var pairingStateURL: URL? {
        containerURL?
            .appendingPathComponent("sharing", isDirectory: true)
            .appendingPathComponent("pairing-state.json", isDirectory: false)
    }

    static var sharingCacheDirectoryURL: URL? {
        containerURL?.appendingPathComponent("sharing", isDirectory: true)
    }

    /// Stable synchronization metadata deliberately lives outside `sharing/`.
    /// A privacy purge may unlink the entire ciphertext subtree without ever
    /// replacing the lifecycle-lock inode held by another process.
    static var sharingControlDirectoryURL: URL? {
        containerURL?.appendingPathComponent("sharing-control", isDirectory: true)
    }

    static var sharingLifecycleLockURL: URL? {
        sharingControlDirectoryURL?.appendingPathComponent(
            "lifecycle.lock",
            isDirectory: false
        )
    }

    static var sharingCleanupRequiredURL: URL? {
        sharingControlDirectoryURL?.appendingPathComponent(
            "cleanup-required.v1",
            isDirectory: false
        )
    }

    /// Monotonic authorization epoch for all sharing media mutations. A purge
    /// increments this value before deleting credentials/cache so an operation
    /// that started with an older room key can never publish its result later.
    static var sharingLifecycleStateURL: URL? {
        sharingControlDirectoryURL?.appendingPathComponent(
            "lifecycle-state.v1.json",
            isDirectory: false
        )
    }

    static var dailySharingStateURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent(
            "daily-media-state.json",
            isDirectory: false
        )
    }

    static var dailySharingLockURL: URL? {
        sharingControlDirectoryURL?.appendingPathComponent(
            "daily-media-state.lock",
            isDirectory: false
        )
    }

    /// A short, renewable cross-process lease serializes the network sync
    /// performed by the host app and (from Phase 3) the Widget extension.
    /// This is deliberately separate from `dailySharingLockURL`: the state
    /// lock is held only for atomic file mutations and never across awaits.
    static var dailySharingSyncLeaseURL: URL? {
        sharingControlDirectoryURL?.appendingPathComponent(
            "daily-media-sync-lease.json",
            isDirectory: false
        )
    }

    static var dailySharingSyncLeaseLockURL: URL? {
        sharingControlDirectoryURL?.appendingPathComponent(
            "daily-media-sync-lease.lock",
            isDirectory: false
        )
    }

    static var sharingOutboundDirectoryURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent("outbound", isDirectory: true)
    }

    static var sharingInboundDirectoryURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent("inbound", isDirectory: true)
    }
}
