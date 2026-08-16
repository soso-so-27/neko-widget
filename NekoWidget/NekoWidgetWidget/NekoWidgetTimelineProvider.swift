import Foundation
import WidgetKit

struct NekoWidgetTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> NekoWidgetEntry {
        .empty(at: Date(), imageVariant: imageVariant(for: context.family))
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (NekoWidgetEntry) -> Void
    ) {
        let now = Date()
        let variant = imageVariant(for: context.family)
        let items = sortedItems(WidgetManifestReader.availableItems(for: variant))
        guard let item = items.last(where: { $0.scheduledDate <= now }) ?? items.first else {
            SharedLog.widget.warning(
                "timeline",
                "Snapshot requested without an available cache item",
                metadata: ["preview": "\(context.isPreview)"]
            )
            completion(.empty(at: now, imageVariant: variant))
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
                cacheFilename: item.cacheFilename(for: variant),
                imageVariant: variant,
                usesFamilySpecificImage: item.cacheFilenames != nil
            )
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<NekoWidgetEntry>) -> Void
    ) {
        let now = Date()
        let variant = imageVariant(for: context.family)
        let items = sortedItems(WidgetManifestReader.availableItems(for: variant))

        guard !items.isEmpty else {
            // The app explicitly reloads timelines after publishing a manifest.
            // Avoid an already-expired `.atEnd` loop while the shared cache is empty.
            SharedLog.widget.warning(
                "timeline",
                "Timeline requested without available cache items",
                metadata: ["preview": "\(context.isPreview)"]
            )
            completion(
                Timeline(
                    entries: [.empty(at: now, imageVariant: variant)],
                    policy: .never
                )
            )
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
                cacheFilename: item.cacheFilename(for: variant),
                imageVariant: variant,
                usesFamilySpecificImage: item.cacheFilenames != nil
            )
        }

        recordTimelineLease(
            filenames: scheduledItems.flatMap { item, _ in item.allCacheFilenames },
            variant: variant,
            at: now
        )
        SharedLog.widget.info(
            "timeline",
            "Future timeline prepared",
            metadata: [
                "entries": "\(entries.count)",
                "preview": "\(context.isPreview)",
                "uniqueFiles": "\(Set(entries.compactMap(\.cacheFilename)).count)",
                "variant": variant.rawValue
            ]
        )
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func sortedItems(_ items: [WidgetManifestItem]) -> [WidgetManifestItem] {
        Array(items.sorted { $0.scheduledDate < $1.scheduledDate }.prefix(20))
    }

    private func imageVariant(for family: WidgetFamily) -> WidgetImageVariant {
        switch family {
        case .systemMedium:
            return .medium
        case .systemLarge:
            return .large
        default:
            return .small
        }
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

    private func recordTimelineLease(
        filenames: [String],
        variant: WidgetImageVariant,
        at date: Date
    ) {
        guard let url = SharedContainer.widgetTimelineLeaseURL(for: variant) else { return }
        let uniqueFilenames = Array(Set(filenames)).sorted()
        guard !uniqueFilenames.isEmpty else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(
            WidgetTimelineLease(cacheFilenames: uniqueFilenames, recordedAt: date)
        ) else { return }
        do {
            try data.write(to: url, options: .atomic)
            SharedLog.widget.debug(
                "timeline",
                "Timeline cache lease recorded",
                metadata: [
                    "files": "\(uniqueFilenames.count)",
                    "variant": variant.rawValue
                ]
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
}
