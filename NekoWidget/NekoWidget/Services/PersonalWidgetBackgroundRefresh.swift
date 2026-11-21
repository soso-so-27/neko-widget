import BackgroundTasks
import Foundation
import Photos
import UIKit
import WidgetKit

/// Refreshes the personal Widget's photos, then the existing Plus authority,
/// without opening a purchase UI. iOS may choose not to run this job; the
/// persisted finite pool remains usable without it.
@MainActor
enum PersonalWidgetBackgroundRefresh {
    static let taskIdentifier = "jp.nekowidget.app.personal-photo-refresh"
    private static let builder = WidgetCacheBuilder()
    /// A request is submitted only after its handler is registered (a DEBUG
    /// fixture launch registers none).
    private static var isRegistered = false

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in run(task) }
        }
        isRegistered = true
    }

    /// 11/21: asked after the app starts, on leaving it and after every run,
    /// while this iPhone has photos for the Widget. Whether a personal Widget
    /// is placed is checked when the job runs, not here: a Widget placed
    /// after the app was left (the first run) is refreshed too, instead of
    /// rotating its first 3 photos until the app is opened again.
    static func schedule() {
        guard isRegistered,
              let state = try? PersonalRediscoveryStore.shared.snapshot(now: .now),
              state.isAuthorized, !state.eligiblePhotoIDs.isEmpty else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// nil when WidgetKit could not answer.
    private static func hasPersonalWidget() async -> Bool? {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                guard case .success(let configurations) = result else {
                    continuation.resume(returning: nil); return
                }
                let placed = configurations.contains(where: {
                    guard let intent = $0.widgetConfigurationIntent(of: NekoWidgetConfigurationIntent.self)
                    else { return false }
                    let id = (intent.photoSource ?? .personalLibrary).id
                    return id == WidgetPhotoSource.personalLibraryID || id.hasPrefix(CloudyWindowStore.profilePrefix)
                })
                continuation.resume(returning: placed)
            }
        }
    }

    private static func run(_ task: BGAppRefreshTask) {
        schedule()
        let operation = Task { @MainActor in
            guard UIApplication.shared.isProtectedDataAvailable else {
                task.setTaskCompleted(success: false)
                return
            }
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else {
                // Access was taken away while the app stayed closed: the
                // cached JPEGs go too, not only the right to show them.
                do {
                    let revision = try PersonalRediscoveryStore.shared.updateEligibility(
                        photoIDs: [], scopeIdentifier: "invalidated", isAuthorized: false, now: .now)
                    try? await WidgetCacheBuilder().clearPersonal(expectedRevision: revision)
                    // 11/20: the cloudy window's copies of the photos too.
                    try? CloudyWindowStore.shared.releasePreparedImages()
                    WidgetCenter.shared.reloadAllTimelines()
                    task.setTaskCompleted(success: true)
                } catch {
                    task.setTaskCompleted(success: false)
                }
                return
            }
            // A removed personal Widget must not keep warming its library.
            guard await hasPersonalWidget() == true else {
                task.setTaskCompleted(success: true)
                return
            }
            // 11/21: the photos first, Plus after them: a slow network must
            // not use up the time iOS gives this job before a photo is ready.
            var photosRefreshed = false
            do {
                try await refreshPhotos()
                photosRefreshed = true
            } catch {
                photosRefreshed = false
            }
            if !Task.isCancelled {
                await PlusPurchaseStore.productionShared.refreshWidgetAuthorityInBackground()
            }
            task.setTaskCompleted(success: photosRefreshed && !Task.isCancelled)
        }
        task.expirationHandler = { operation.cancel() }
    }

    private static func refreshPhotos() async throws {
        guard let state = try PersonalRediscoveryStore.shared.snapshot(now: .now),
              state.isAuthorized else { return }
        var input = try await LibraryStore().read()
        let eligibleRecords = WeightedPhotoSelector().eligibleCandidates(
            from: input.assets, settings: input.settings, now: .now)
        let known = Dictionary(eligibleRecords.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        // 11/21: a photo already given to a window today (or still on screen
        // from yesterday) stays even when Photos changed it (a favorite, an
        // edit): it keeps its prepared image until the app prepares it again,
        // so today's photo does not change in the middle of the day.
        let chosenPhotoIDs = CloudyWindowStore.shared.photoIDsChosenRecently(now: .now)
        // Resolve only known analyzed IDs, never enumerate/analyze the
        // full library or start an iCloud photo download in background.
        // The frozen photo (shown while membership selection is stopped)
        // may sit outside the eligible set; only its existence matters.
        var checkedIDs = state.eligiblePhotoIDs
        if let frozenPhotoID = state.frozenPhotoID { checkedIDs.insert(frozenPhotoID) }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(checkedIDs), options: nil)
        // Still in Photos and still allowed.
        var accessible = Set<String>()
        // Also unchanged since the app read it: may be prepared now.
        var unchanged = Set<String>()
        var frozenPresent = false
        assets.enumerateObjects { asset, _, _ in
            if asset.localIdentifier == state.frozenPhotoID, asset.mediaType == .image {
                frozenPresent = true
            }
            guard let record = known[asset.localIdentifier], asset.mediaType == .image else { return }
            let modified = asset.modificationDate.map {
                Date(timeIntervalSince1970: floor($0.timeIntervalSince1970))
            }
            if record.sourceModificationDate == modified {
                accessible.insert(asset.localIdentifier)
                unchanged.insert(asset.localIdentifier)
            } else if chosenPhotoIDs.contains(asset.localIdentifier) {
                accessible.insert(asset.localIdentifier)
            }
        }
        let frozenAccessible: Bool? = state.frozenPhotoID == nil ? nil : frozenPresent
        let revision = try PersonalRediscoveryStore.shared.restrictEligibility(
            to: accessible, expectedRevision: state.eligibilityRevision, now: .now,
            frozenPhotoAccessible: frozenAccessible)
        if revision != state.eligibilityRevision || frozenAccessible == false {
            WidgetCenter.shared.reloadAllTimelines()
        }
        // An edited photo is never prepared again from its old record here.
        input.assets.removeAll { !unchanged.contains($0.localIdentifier) }
        try Task.checkCancellation()
        let result = try await builder.replenishPersonal(from: input, eligibilityRevision: revision)
        let cloudyChanged = try await CloudyWindowImagePreparer.shared.prepare()
        if result.addedCount > 0 || cloudyChanged { WidgetCenter.shared.reloadAllTimelines() }
        try Task.checkCancellation()
    }
}
