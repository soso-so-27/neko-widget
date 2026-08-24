import AppIntents
import Foundation
import WidgetKit

struct NekoWidgetTimelineProvider: AppIntentTimelineProvider {
    /// WidgetKit renders every future entry when accepting a timeline. Keeping
    /// this bounded prevents Medium and Large's high-resolution canvases from
    /// exceeding the timeline render budget while preserving the 20-photo
    /// manifest as the rotation source.
    private static let maximumTimelineEntryCount = 2

    func placeholder(in context: Context) -> NekoWidgetEntry {
#if DEBUG && APP_STORE_SCREENSHOT_WIDGET_FIXTURE
        return AppStoreWidgetPreviewFixture.entry(
            at: Date(),
            variant: imageVariant(for: context.family)
        )
#endif
        return .empty(at: Date(), imageVariant: imageVariant(for: context.family))
    }

    func snapshot(
        for configuration: NekoWidgetConfigurationIntent,
        in context: Context
    ) async -> NekoWidgetEntry {
        let now = Date()
        let variant = imageVariant(for: context.family)
#if DEBUG && APP_STORE_SCREENSHOT_WIDGET_FIXTURE
        return AppStoreWidgetPreviewFixture.entry(at: now, variant: variant)
#endif
        let source = configuration.photoSource ?? .personalLibrary
        if source.id == WidgetPhotoSource.familyWindowID {
            guard WidgetPhotoSource.familyWindowSourceIsEnabled else {
                return .empty(at: now, imageVariant: variant)
            }
            return familySnapshot(
                now: now,
                variant: variant,
                preview: context.isPreview
            )
        }
        let items = sortedItems(availableItems(for: source, variant: variant))
        let likeState = readLikeState()
        let item = normalizedSchedule(
            items,
            now: now,
            preferredLocalIdentifier: recentlyChangedLikeIdentifier(
                in: likeState.records,
                relativeTo: now
            )
        ).entries.first?.item
        guard let item else {
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
            familyMomentIsFresh: false,
            windowDisplayName: PrivateWindowDisplayName.fallback,
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
#if DEBUG && APP_STORE_SCREENSHOT_WIDGET_FIXTURE
        return Timeline(
            entries: [AppStoreWidgetPreviewFixture.entry(at: now, variant: variant)],
            policy: .never
        )
#endif
        let source = configuration.photoSource ?? .personalLibrary
        if source.id == WidgetPhotoSource.familyWindowID {
            guard WidgetPhotoSource.familyWindowSourceIsEnabled else {
                return Timeline(
                    entries: [.empty(at: now, imageVariant: variant)],
                    policy: .never
                )
            }
            return familyTimeline(
                now: now,
                variant: variant,
                preview: context.isPreview
            )
        }
        let items = sortedItems(availableItems(for: source, variant: variant))
        let likeState = readLikeState()

        guard !items.isEmpty else {
            // The app explicitly reloads timelines after publishing a manifest.
            // Avoid an immediate reload loop while the shared cache is empty.
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

        // WidgetKit renders every future entry before accepting the timeline.
        // Keep only two high-resolution canvases resident per request. Anchor
        // their transition and reload dates to the manifest schedule so delayed
        // WidgetKit reloads cannot gradually shift the rotation cadence.
        let schedule = normalizedSchedule(
            items,
            now: now,
            preferredLocalIdentifier: recentlyChangedLikeIdentifier(
                in: likeState.records,
                relativeTo: now
            )
        )
        let scheduledItems = schedule.entries
        let reloadDate = schedule.reloadDate
        let entries = scheduledItems.map { item, date in
            return NekoWidgetEntry(
                date: date,
                localIdentifier: item.localIdentifier,
                cacheFilename: item.cacheFilename(for: variant),
                imageVariant: variant,
                photoSourceIdentifier: source.id,
                usesFamilySpecificImage: item.cacheFilenames != nil,
                familyMomentIsFresh: false,
                windowDisplayName: PrivateWindowDisplayName.fallback,
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
                "maximumEntries": "\(Self.maximumTimelineEntryCount)",
                "nextReload": ISO8601DateFormatter().string(from: reloadDate),
                "photoSource": source.id,
                "preview": "\(context.isPreview)",
                "uniqueFiles": "\(Set(entries.compactMap(\.cacheFilename)).count)",
                "variant": variant.rawValue
            ]
        )
        return Timeline(entries: entries, policy: .after(reloadDate))
    }

    private func familySnapshot(
        now: Date,
        variant: WidgetImageVariant,
        preview: Bool
    ) -> NekoWidgetEntry {
        let windowDisplayName = WidgetManifestReader.familyWindowDisplayName()
        guard let item = WidgetManifestReader.familyItem(for: variant) else {
            SharedLog.widget.warning(
                "timeline",
                "Family snapshot requested without a safe cache item",
                metadata: ["preview": "\(preview)"]
            )
            return .empty(
                at: now,
                imageVariant: variant,
                photoSourceIdentifier: WidgetPhotoSource.familyWindowID,
                windowDisplayName: windowDisplayName
            )
        }
        return familyEntry(
            item: item,
            date: now,
            variant: variant,
            now: now,
            windowDisplayName: windowDisplayName
        )
    }

    private func familyTimeline(
        now: Date,
        variant: WidgetImageVariant,
        preview: Bool
    ) -> Timeline<NekoWidgetEntry> {
        let windowDisplayName = WidgetManifestReader.familyWindowDisplayName()
        guard let item = WidgetManifestReader.familyItem(for: variant) else {
            SharedLog.widget.warning(
                "timeline",
                "Family timeline requested without a safe cache item",
                metadata: ["preview": "\(preview)"]
            )
            return Timeline(
                entries: [
                    .empty(
                        at: now,
                        imageVariant: variant,
                        photoSourceIdentifier: WidgetPhotoSource.familyWindowID,
                        windowDisplayName: windowDisplayName
                    )
                ],
                policy: .never
            )
        }

        var entries = [familyEntry(
            item: item,
            date: now,
            variant: variant,
            now: now,
            windowDisplayName: windowDisplayName
        )]
        if now >= item.receivedAt, now < item.freshUntil {
            entries.append(
                familyEntry(
                    item: item,
                    date: item.freshUntil,
                    variant: variant,
                    now: item.freshUntil,
                    windowDisplayName: windowDisplayName
                )
            )
        }
        SharedLog.widget.info(
            "timeline",
            "Family timeline prepared",
            metadata: ["entries": "\(entries.count)", "preview": "\(preview)"]
        )
        return Timeline(entries: entries, policy: .never)
    }

    private func familyEntry(
        item: FamilyWidgetManifestItem,
        date: Date,
        variant: WidgetImageVariant,
        now: Date,
        windowDisplayName: String
    ) -> NekoWidgetEntry {
        NekoWidgetEntry(
            date: date,
            localIdentifier: nil,
            cacheFilename: item.cacheFilenames.filename(for: variant),
            imageVariant: variant,
            photoSourceIdentifier: WidgetPhotoSource.familyWindowID,
            usesFamilySpecificImage: true,
            familyMomentIsFresh: now >= item.receivedAt && now < item.freshUntil,
            windowDisplayName: windowDisplayName,
            isLiked: false,
            isLikeInteractionEnabled: false
        )
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
            SharedLog.widget.error(
                "like",
                "Widget like state could not be read",
                metadata: SharedLog.errorMetadata(error, category: .widgetLike)
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
    ) -> (
        entries: [(item: WidgetManifestItem, date: Date)],
        reloadDate: Date
    ) {
        let defaultCadence: TimeInterval = 20 * 60
        guard !items.isEmpty else {
            return (
                entries: [],
                reloadDate: now.addingTimeInterval(
                    TimeInterval(Self.maximumTimelineEntryCount) * defaultCadence
                )
            )
        }

        // A like intent writes its changedAt before asking WidgetKit to reload.
        // Override only the current entry so feedback applies to the photo the
        // user tapped. The next item and all boundaries remain time-based;
        // repeated taps therefore cannot move the long-running cadence.
        let cadence = timelineCadence(in: items)
        let anchor = items[0].scheduledDate
        let elapsed = max(0, now.timeIntervalSince(anchor))
        let elapsedSlots = Int(floor(elapsed / cadence))
        let timeBasedStartIndex = elapsedSlots % items.count
        let preferredItem = preferredLocalIdentifier.flatMap { identifier in
            items.first(where: { $0.localIdentifier == identifier })
        }
        let candidates = (0..<items.count).map { offset in
            let item: WidgetManifestItem
            if offset == 0, let preferredItem {
                item = preferredItem
            } else {
                item = items[(timeBasedStartIndex + offset) % items.count]
            }
            let date: Date
            if offset == 0 {
                date = now
            } else {
                date = anchor.addingTimeInterval(
                    TimeInterval(elapsedSlots + offset) * cadence
                )
            }
            return (item: item, date: date)
        }
        let entries = candidates
            .prefix(Self.maximumTimelineEntryCount)
            .map { $0 }
        let reloadSlot = elapsedSlots + Self.maximumTimelineEntryCount
        let reloadDate = anchor.addingTimeInterval(
            TimeInterval(reloadSlot) * cadence
        )
        return (entries: entries, reloadDate: reloadDate)
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
            SharedLog.widget.error(
                "timeline",
                "Timeline cache lease write failed",
                metadata: SharedLog.errorMetadata(error, category: .widgetTimeline)
            )
        }
    }
}
