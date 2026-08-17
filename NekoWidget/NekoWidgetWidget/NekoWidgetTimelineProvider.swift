import AppIntents
import Foundation
import WidgetKit

struct NekoWidgetTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NekoWidgetEntry {
        .empty(at: Date(), imageVariant: imageVariant(for: context.family))
    }

    func snapshot(
        for configuration: NekoWidgetConfigurationIntent,
        in context: Context
    ) async -> NekoWidgetEntry {
        let now = Date()
        let variant = imageVariant(for: context.family)
        let source = configuration.photoSource ?? .personalLibrary
        let items = sortedItems(availableItems(for: source, variant: variant))
        let likeState = readLikeState()
        guard let item = items.last(where: { $0.scheduledDate <= now }) ?? items.first else {
            SharedLog.widget.warning(
                "timeline",
                "Snapshot requested without an available cache item",
                metadata: [
                    "photoSource": source.id,
                    "preview": "\(context.isPreview)"
                ]
            )
            return .empty(
                at: now,
                imageVariant: variant,
                photoSourceIdentifier: source.id
            )
        }

        SharedLog.widget.debug(
            "timeline",
            "Snapshot entry prepared",
            metadata: [
                "asset": SharedLog.shortHash(item.localIdentifier),
                "availableItems": "\(items.count)",
                "photoSource": source.id,
                "preview": "\(context.isPreview)"
            ]
        )

        return NekoWidgetEntry(
            date: now,
            localIdentifier: item.localIdentifier,
            cacheFilename: item.cacheFilename(for: variant),
            imageVariant: variant,
            photoSourceIdentifier: source.id,
            usesFamilySpecificImage: item.cacheFilenames != nil,
            isLiked: likeState.records[item.localIdentifier]?.isLiked ?? false,
            isLikeInteractionEnabled: likeState.isInteractionReady
        )
    }

    func timeline(
        for configuration: NekoWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<NekoWidgetEntry> {
        let now = Date()
        let variant = imageVariant(for: context.family)
        let source = configuration.photoSource ?? .personalLibrary
        let items = sortedItems(availableItems(for: source, variant: variant))
        let likeState = readLikeState()

        guard !items.isEmpty else {
            // The app explicitly reloads timelines after publishing a manifest.
            // Avoid an already-expired `.atEnd` loop while the shared cache is empty.
            SharedLog.widget.warning(
                "timeline",
                "Timeline requested without available cache items",
                metadata: [
                    "photoSource": source.id,
                    "preview": "\(context.isPreview)"
                ]
            )
            return Timeline(
                entries: [
                    .empty(
                        at: now,
                        imageVariant: variant,
                        photoSourceIdentifier: source.id
                    )
                ],
                policy: .never
            )
        }

        // The app-side builder owns both count and cadence. Rebase its relative
        // schedule to this provider invocation so every timeline still returns
        // the full configured 15–20 entries even when WidgetKit delays reload.
        let scheduledItems = normalizedSchedule(
            items,
            now: now,
            preferredLocalIdentifier: recentlyChangedLikeIdentifier(
                in: likeState.records,
                relativeTo: now
            )
        )
        let entries = scheduledItems.map { item, date in
            return NekoWidgetEntry(
                date: date,
                localIdentifier: item.localIdentifier,
                cacheFilename: item.cacheFilename(for: variant),
                imageVariant: variant,
                photoSourceIdentifier: source.id,
                usesFamilySpecificImage: item.cacheFilenames != nil,
                isLiked: likeState.records[item.localIdentifier]?.isLiked ?? false,
                isLikeInteractionEnabled: likeState.isInteractionReady
            )
        }

        recordTimelineLease(
            // A family timeline references only its own precomposed canvas.
            // Leasing all three variants tripled retained high-resolution disk
            // usage without protecting any additional live Widget entry.
            filenames: scheduledItems.map { item, _ in
                item.cacheFilename(for: variant)
            },
            variant: variant,
            at: now
        )
        SharedLog.widget.info(
            "timeline",
            "Future timeline prepared",
            metadata: [
                "entries": "\(entries.count)",
                "photoSource": source.id,
                "preview": "\(context.isPreview)",
                "uniqueFiles": "\(Set(entries.compactMap(\.cacheFilename)).count)",
                "variant": variant.rawValue
            ]
        )
        return Timeline(entries: entries, policy: .atEnd)
    }

    private func availableItems(
        for source: WidgetPhotoSource,
        variant: WidgetImageVariant
    ) -> [WidgetManifestItem] {
        // Fail closed for unknown or retired sources. Never substitute the
        // personal camera roll for another configured source.
        guard source.id == WidgetPhotoSource.personalLibraryID else { return [] }
        return WidgetManifestReader.availableItems(for: variant)
    }

    private func sortedItems(_ items: [WidgetManifestItem]) -> [WidgetManifestItem] {
        Array(items.sorted { $0.scheduledDate < $1.scheduledDate }.prefix(20))
    }

    private func readLikeState() -> SharedLikeStateSnapshot {
        do {
            return try SharedLikeStore.stateSnapshot()
        } catch {
            let value = error as NSError
            SharedLog.widget.error(
                "like",
                "Widget like state could not be read",
                metadata: [
                    "code": "\(value.code)",
                    "domain": value.domain
                ]
            )
            return SharedLikeStateSnapshot(records: [:], isInteractionReady: false)
        }
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
        now: Date,
        preferredLocalIdentifier: String?
    ) -> [(WidgetManifestItem, Date)] {
        guard !items.isEmpty else { return [] }

        // A like intent writes its changedAt before asking WidgetKit to reload.
        // Prefer that asset so feedback applies to the photo the user actually
        // tapped, even after the manifest's original six-hour schedule expires.
        // Otherwise preserve the active item while still inside that schedule.
        let startIndex: Int
        if let preferredLocalIdentifier,
           let preferredIndex = items.firstIndex(where: {
               $0.localIdentifier == preferredLocalIdentifier
           }) {
            startIndex = preferredIndex
        } else if let last = items.last,
                  now <= last.scheduledDate,
                  let activeIndex = items.lastIndex(where: {
                      $0.scheduledDate <= now
                  }) {
            startIndex = activeIndex
        } else {
            startIndex = 0
        }

        let orderedItems = Array(items[startIndex...]) + Array(items[..<startIndex])
        let cadence = timelineCadence(in: items)
        return orderedItems.enumerated().map { offset, item in
            (item, now.addingTimeInterval(TimeInterval(offset) * cadence))
        }
    }

    private func timelineCadence(in items: [WidgetManifestItem]) -> TimeInterval {
        guard items.count > 1 else { return 20 * 60 }
        let interval = items[1].scheduledDate.timeIntervalSince(items[0].scheduledDate)
        return max(1, interval)
    }

    private func recentlyChangedLikeIdentifier(
        in records: [String: SharedLikeRecord],
        relativeTo now: Date
    ) -> String? {
        let feedbackWindow: TimeInterval = 2 * 60
        return records.values
            .filter {
                let age = now.timeIntervalSince($0.changedAt)
                return age >= -5 && age <= feedbackWindow
            }
            .max(by: { $0.changedAt < $1.changedAt })?
            .localIdentifier
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
