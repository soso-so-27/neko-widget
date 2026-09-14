import BackgroundTasks
import Foundation
import Photos
import UIKit
import WidgetKit

/// Independent of sharing, accounts and notifications. iOS may choose not to
/// run this job; the persisted finite pool remains usable without it.
@MainActor
enum PersonalWidgetBackgroundRefresh {
    static let taskIdentifier = "jp.nekowidget.app.personal-photo-refresh"
    private static let builder = WidgetCacheBuilder()

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in run(task) }
        }
    }

    static func schedule() {
        guard let state = try? PersonalRediscoveryStore.shared.snapshot(now: .now),
              state.isAuthorized, !state.eligiblePhotoIDs.isEmpty else { return }
        // A removed personal Widget must not keep warming its entire library.
        WidgetCenter.shared.getCurrentConfigurations { result in
            guard case .success(let configurations) = result,
                  configurations.contains(where: {
                      guard let intent = $0.widgetConfigurationIntent(of: NekoWidgetConfigurationIntent.self)
                      else { return false }
                      return (intent.photoSource ?? .personalLibrary).id == WidgetPhotoSource.personalLibraryID
                  }) else { return }
            let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
            request.earliestBeginDate = Date().addingTimeInterval(60 * 60)
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    private static func run(_ task: BGAppRefreshTask) {
        schedule()
        let operation = Task { @MainActor in
            guard UIApplication.shared.isProtectedDataAvailable else {
                task.setTaskCompleted(success: false)
                return
            }
            do {
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                guard status == .authorized || status == .limited else {
                    try PersonalRediscoveryStore.shared.invalidate(now: .now)
                    WidgetCenter.shared.reloadAllTimelines()
                    task.setTaskCompleted(success: true)
                    return
                }
                guard let state = try PersonalRediscoveryStore.shared.snapshot(now: .now),
                      state.isAuthorized else {
                    task.setTaskCompleted(success: true)
                    return
                }
                var input = try await LibraryStore().load()
                let eligibleRecords = WeightedPhotoSelector().eligibleCandidates(
                    from: input.assets, settings: input.settings, now: .now)
                let known = Dictionary(uniqueKeysWithValues: eligibleRecords.map { ($0.localIdentifier, $0) })
                // Resolve only known analyzed IDs, never enumerate/analyze the
                // full library or start an iCloud photo download in background.
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(state.eligiblePhotoIDs), options: nil)
                var accessible = Set<String>()
                assets.enumerateObjects { asset, _, _ in
                    guard let record = known[asset.localIdentifier], asset.mediaType == .image else { return }
                    let modified = asset.modificationDate.map {
                        Date(timeIntervalSince1970: floor($0.timeIntervalSince1970))
                    }
                    guard record.sourceModificationDate == modified else { return }
                    accessible.insert(asset.localIdentifier)
                }
                let revision = try PersonalRediscoveryStore.shared.restrictEligibility(
                    to: accessible, expectedRevision: state.eligibilityRevision, now: .now)
                if revision != state.eligibilityRevision { WidgetCenter.shared.reloadAllTimelines() }
                input.assets.removeAll { !accessible.contains($0.localIdentifier) }
                try Task.checkCancellation()
                let result = try await builder.replenishPersonal(from: input, eligibilityRevision: revision)
                if result.addedCount > 0 { WidgetCenter.shared.reloadAllTimelines() }
                task.setTaskCompleted(success: !Task.isCancelled)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { operation.cancel() }
    }
}
