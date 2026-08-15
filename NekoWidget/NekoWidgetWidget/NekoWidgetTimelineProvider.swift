import Foundation
import WidgetKit

struct NekoWidgetTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> NekoWidgetEntry {
        .empty(at: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (NekoWidgetEntry) -> Void
    ) {
        let now = Date()
        let items = sortedItems(WidgetManifestReader.availableItems())
        guard let item = items.last(where: { $0.scheduledDate <= now }) ?? items.first else {
            SharedLog.widget.warning(
                "timeline",
                "Snapshot requested without an available cache item",
                metadata: ["preview": "\(context.isPreview)"]
            )
            completion(.empty(at: now))
            return
        }

        SharedLog.widget.debug(
            "timeline",
            "Snapshot entry prepared",
            metadata: [
                "asset": SharedLog.shortHash(item.localIdentifier),
                "availableItems": "\(items.count)",
                "preview": "\(context.isPreview)"
            ]
        )

        completion(
            NekoWidgetEntry(
                date: now,
                localIdentifier: item.localIdentifier,
                cacheFilename: item.cacheFilename
            )
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<NekoWidgetEntry>) -> Void
    ) {
        let now = Date()
        let items = sortedItems(WidgetManifestReader.availableItems())

        guard !items.isEmpty else {
            // The app explicitly reloads timelines after publishing a manifest.
            // Avoid an already-expired `.atEnd` loop while the shared cache is empty.
            removeTimelineLease()
            SharedLog.widget.warning(
                "timeline",
                "Timeline requested without available cache items",
                metadata: ["preview": "\(context.isPreview)"]
            )
            completion(Timeline(entries: [.empty(at: now)], policy: .never))
            return
        }

        // The app-side builder owns both count and cadence. Rebase its relative
        // schedule to this provider invocation so every timeline still returns
        // the full configured 15–20 entries even when WidgetKit delays reload.
        let scheduledItems = normalizedSchedule(items, now: now)
        let entries = scheduledItems.map { item, date in
            return NekoWidgetEntry(
                date: date,
                localIdentifier: item.localIdentifier,
                cacheFilename: item.cacheFilename
            )
        }

        recordTimelineLease(for: entries, at: now)
        SharedLog.widget.info(
            "timeline",
            "Future timeline prepared",
            metadata: [
                "entries": "\(entries.count)",
                "preview": "\(context.isPreview)",
                "uniqueFiles": "\(Set(entries.compactMap(\.cacheFilename)).count)"
            ]
        )
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func sortedItems(_ items: [WidgetManifestItem]) -> [WidgetManifestItem] {
        Array(items.sorted { $0.scheduledDate < $1.scheduledDate }.prefix(20))
    }

    private func normalizedSchedule(
        _ items: [WidgetManifestItem],
        now: Date
    ) -> [(WidgetManifestItem, Date)] {
        guard let first = items.first else { return [] }
        return items.map { item in
            let offset = max(0, item.scheduledDate.timeIntervalSince(first.scheduledDate))
            return (item, now.addingTimeInterval(offset))
        }
    }

    private func recordTimelineLease(for entries: [NekoWidgetEntry], at date: Date) {
        guard let url = SharedContainer.widgetTimelineLeaseURL else { return }
        let filenames = Array(Set(entries.compactMap(\.cacheFilename))).sorted()
        guard !filenames.isEmpty else {
            removeTimelineLease()
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(
            WidgetTimelineLease(cacheFilenames: filenames, recordedAt: date)
        ) else { return }
        do {
            try data.write(to: url, options: .atomic)
            SharedLog.widget.debug(
                "timeline",
                "Timeline cache lease recorded",
                metadata: ["files": "\(filenames.count)"]
            )
        } catch {
            let value = error as NSError
            SharedLog.widget.error(
                "timeline",
                "Timeline cache lease write failed",
                metadata: ["code": "\(value.code)", "domain": value.domain]
            )
        }
    }

    private func removeTimelineLease() {
        guard let url = SharedContainer.widgetTimelineLeaseURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
