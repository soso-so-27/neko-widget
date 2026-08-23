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

    /// User curation is independent from scanner checkpoints. A source change
    /// can replace every AssetRecord, so exclusions must not live only inside
    /// the library snapshot.
    static var catCandidateCurationURL: URL? {
        containerURL?.appendingPathComponent(
            "cat-candidate-curation.json",
            isDirectory: false
        )
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

    /// A family photo is never mixed into the personal PhotoKit manifest.
    /// Keeping this below `sharing/` also makes unlink/reinstall cleanup remove
    /// the family Widget output together with every other sharing artifact.
    static var familyWidgetManifestURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent(
            "family-widget-manifest.v1.json",
            isDirectory: false
        )
    }

    /// Shared by the app target and Widget extension because the App Intent
    /// entity is compiled into both. The manifest is presentation-only; a
    /// missing, old, or malformed value always resolves to the neutral name.
    static func familyWidgetWindowDisplayName() -> String {
        guard let url = familyWidgetManifestURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return PrivateWindowDisplayName.fallback }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(FamilyWidgetManifest.self, from: data),
              manifest.schemaVersion == FamilyWidgetManifest.schemaVersion
        else { return PrivateWindowDisplayName.fallback }
        return PrivateWindowDisplayName.resolved(manifest.windowDisplayName)
    }

    static var familyWidgetCacheHistoryURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent(
            "family-widget-cache-history.v1.json",
            isDirectory: false
        )
    }

    static var familyWidgetCacheDirectoryURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent(
            "family-widget-cache",
            isDirectory: true
        )
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

    /// Local presentation only. The display name is deliberately separate
    /// from PairingState so a rename cannot invalidate an in-flight pairing
    /// CAS, and it is deliberately below `sharing/` so unlink/reinstall cleanup
    /// removes it with every other artifact for the old private window.
    static var privateWindowPresentationURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent(
            "window-presentation.v1.json",
            isDirectory: false
        )
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

    static var momentSharingStateURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent(
            "moment-sharing-state.v1.json",
            isDirectory: false
        )
    }

    static var momentSharingCiphertextDirectoryURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent("moments", isDirectory: true)
    }

    static var momentSharingReceivedDirectoryURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent("received-moments", isDirectory: true)
    }

    /// Short-lived, capture-only handoff from the Share Extension to the host
    /// app. This deliberately lives below `sharing/` so installation cleanup,
    /// unlink, and block remove every admission and pending capture without
    /// touching personal photos, likes, or Widget cache files.
    static var momentShareHandoffDirectoryURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent(
            "moment-handoff",
            isDirectory: true
        )
    }

    /// A terminal, pairing-scoped fail-closed marker written before a
    /// report-only transition removes handoff input. It deliberately lives
    /// beside (not inside) `moment-handoff/`, so purging that directory cannot
    /// accidentally re-enable the Share Extension. Full pairing cleanup
    /// removes the enclosing `sharing/` subtree before a new pairing begins.
    static var momentShareHandoffReportOnlyMarkerURL: URL? {
        sharingCacheDirectoryURL?.appendingPathComponent(
            "moment-handoff-report-only.v1",
            isDirectory: false
        )
    }

    static var momentShareHandoffAdmissionsURL: URL? {
        momentShareHandoffDirectoryURL?.appendingPathComponent(
            "admissions.v1.plist",
            isDirectory: false
        )
    }

    static var momentShareHandoffOutcomesURL: URL? {
        momentShareHandoffDirectoryURL?.appendingPathComponent(
            "outcomes.v1.plist",
            isDirectory: false
        )
    }

    static var momentShareHandoffCapturesDirectoryURL: URL? {
        momentShareHandoffDirectoryURL?.appendingPathComponent(
            "captures",
            isDirectory: true
        )
    }
}
