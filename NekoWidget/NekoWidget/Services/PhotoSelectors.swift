import Foundation

struct WeightedPhotoSelector {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func selectOne(
        from assets: [AssetRecord],
        settings: AppSettings,
        now: Date = .now
    ) -> AssetRecord? {
        let scoped = eligibleCandidates(from: assets, settings: settings, now: now)
        guard !scoped.isEmpty else { return nil }

        let recentCutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let notRecentlyShown = scoped.filter {
            guard let lastShownAt = $0.lastShownAt else { return true }
            return lastShownAt < recentCutoff
        }
        return weightedRandom(from: notRecentlyShown.isEmpty ? scoped : notRecentlyShown)
    }

    func selectSequence(
        from assets: [AssetRecord],
        settings: AppSettings,
        count: Int,
        now: Date = .now
    ) -> [AssetRecord] {
        let all = eligibleCandidates(from: assets, settings: settings, now: now)
        guard !all.isEmpty, count > 0 else { return [] }

        let recentCutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let preferred = all.filter {
            guard let lastShownAt = $0.lastShownAt else { return true }
            return lastShownAt < recentCutoff
        }
        var result: [AssetRecord] = []
        var pool = preferred.isEmpty ? all : preferred
        var hasAddedOlderFallback = preferred.isEmpty
        while result.count < count {
            if pool.isEmpty {
                if !hasAddedOlderFallback {
                    let selectedIDs = Set(result.map(\.localIdentifier))
                    pool = all.filter { !selectedIDs.contains($0.localIdentifier) }
                    hasAddedOlderFallback = true
                }
                if pool.isEmpty { pool = all }
            }
            guard let selected = weightedRandom(from: pool) else { break }
            result.append(selected)
            pool.removeAll { $0.localIdentifier == selected.localIdentifier }
        }
        return result
    }

    /// Returns each eligible photo once, preferring items that haven't been
    /// scheduled in the last 30 days. Widget cache generation can walk this
    /// order until it has enough locally available images.
    func candidateOrder(
        from assets: [AssetRecord],
        settings: AppSettings,
        now: Date = .now
    ) -> [AssetRecord] {
        let all = eligibleCandidates(from: assets, settings: settings, now: now)
        let recentCutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let fresh = all.filter {
            guard let lastShownAt = $0.lastShownAt else { return true }
            return lastShownAt < recentCutoff
        }
        let freshIDs = Set(fresh.map(\.localIdentifier))
        let older = all.filter { !freshIDs.contains($0.localIdentifier) }
        return weightedOrder(fresh) + weightedOrder(older)
    }

    func eligibleCandidates(
        from assets: [AssetRecord],
        settings: AppSettings,
        now: Date
    ) -> [AssetRecord] {
        // A cancelled threshold-changing rescan deliberately keeps old records
        // so likes and progress can resume. Never publish those records until
        // they have been analyzed with the active detector fingerprint.
        let cats = assets.filter {
            $0.isWidgetEligible(settings: settings)
        }
        guard settings.dateRange == .recentYear,
              let cutoff = calendar.date(byAdding: .year, value: -1, to: now) else {
            return cats
        }
        return cats.filter { ($0.creationDate ?? .distantPast) >= cutoff }
    }

    private func weightedRandom(from assets: [AssetRecord]) -> AssetRecord? {
        guard !assets.isEmpty else { return nil }
        let weighted = assets.map { ($0, weight(for: $0)) }
        let total = weighted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return assets.randomElement() }

        var cursor = Double.random(in: 0..<total)
        for (asset, weight) in weighted {
            cursor -= weight
            if cursor <= 0 { return asset }
        }
        return weighted.last?.0
    }

    private func weightedOrder(_ assets: [AssetRecord]) -> [AssetRecord] {
        assets
            .map { asset in
                let unit = Double.random(in: Double.leastNonzeroMagnitude..<1)
                return (asset, -log(unit) / weight(for: asset))
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private func weight(for asset: AssetRecord) -> Double {
        var value = 1.0
        if asset.liked { value *= 3 }
        if asset.isFavorite { value *= 2 }
        if asset.burstIdentifier != nil { value *= 1.5 }
        return value
    }
}

/// The photo tab's daily suggestion is intentionally independent from WidgetKit's
/// 10–30 minute timeline. Persist only the local calendar day and selected
/// Photos identifier so an ordinary reload or process restart cannot turn
/// "today" into another random feed. The library snapshot remains untouched.
struct TodayPhotoSelectionState: Codable, Equatable, Sendable {
    let localDayKey: String
    let localIdentifier: String
}

struct TodayPhotoSelectionResolution: Equatable {
    let asset: AssetRecord?
    let state: TodayPhotoSelectionState?
}

enum TodayPhotoSelectionPolicy {
    static func resolve(
        from assets: [AssetRecord],
        settings: AppSettings,
        previousState: TodayPhotoSelectionState?,
        selector: WeightedPhotoSelector,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> TodayPhotoSelectionResolution {
        let eligible = selector.eligibleCandidates(
            from: assets,
            settings: settings,
            now: now
        )
        // A transient empty snapshot can occur while Photos permission,
        // identity or scan state is being reconciled. Keep the tiny receipt so
        // the same eligible photo returns later in the day instead of losing
        // the user's stable Today selection.
        guard !eligible.isEmpty else {
            return TodayPhotoSelectionResolution(asset: nil, state: previousState)
        }

        let dayKey = localDayKey(for: now, calendar: calendar)
        if previousState?.localDayKey == dayKey,
           let identifier = previousState?.localIdentifier,
           let retained = eligible.first(where: {
               $0.localIdentifier == identifier
           }) {
            return TodayPhotoSelectionResolution(
                asset: retained,
                state: previousState
            )
        }

        guard let selected = selector.selectOne(
            from: eligible,
            settings: settings,
            now: now
        ) else {
            return TodayPhotoSelectionResolution(asset: nil, state: previousState)
        }
        return TodayPhotoSelectionResolution(
            asset: selected,
            state: TodayPhotoSelectionState(
                localDayKey: dayKey,
                localIdentifier: selected.localIdentifier
            )
        )
    }

    static func localDayKey(
        for date: Date,
        calendar: Calendar = .current
    ) -> String {
        let components = calendar.dateComponents(
            [.era, .year, .month, .day],
            from: date
        )
        return [
            components.era ?? 0,
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
        ].map { String($0) }.joined(separator: "-")
    }
}

/// A new, isolated UserDefaults receipt. It neither migrates nor rewrites the
/// library snapshot, shared likes, Widget cache or Photos assets.
struct TodayPhotoSelectionStore {
    private static let stateKey = "today-photo.selection.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> TodayPhotoSelectionState? {
        guard let data = defaults.data(forKey: Self.stateKey) else { return nil }
        return try? JSONDecoder().decode(TodayPhotoSelectionState.self, from: data)
    }

    func save(_ state: TodayPhotoSelectionState?) {
        guard let state,
              let data = try? JSONEncoder().encode(state) else {
            defaults.removeObject(forKey: Self.stateKey)
            return
        }
        defaults.set(data, forKey: Self.stateKey)
    }
}

struct AlbumCandidateSelector {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func select(from snapshot: LibrarySnapshot, now: Date = .now) -> [AssetRecord] {
        let fingerprint = snapshot.settings.analysisFingerprint
        var candidates = snapshot.assets.filter {
            $0.isCatCandidate && $0.analysisFingerprint == fingerprint
        }
        if snapshot.settings.dateRange == .recentYear,
           let cutoff = calendar.date(byAdding: .year, value: -1, to: now) {
            candidates.removeAll { ($0.creationDate ?? .distantPast) < cutoff }
        }

        // Higher-intent photos survive the cap first; among equal-priority
        // candidates, newer and more confident photos replace older ones.
        candidates.sort {
            let lhsPriority = ($0.liked ? 2 : 0) + ($0.isFavorite ? 1 : 0)
            let rhsPriority = ($1.liked ? 2 : 0) + ($1.isFavorite ? 1 : 0)
            if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
            if $0.cat.confidence != $1.cat.confidence {
                return $0.cat.confidence > $1.cat.confidence
            }
            return ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }
        return Array(candidates.prefix(snapshot.settings.albumMaximum))
    }
}

/// Keeps progress presentation below the refresh rate a person can perceive
/// while preserving the existing 1,000-photo durable resume checkpoints.
/// Terminal/stage snapshots are published by their owning paths and therefore
/// do not use this timer.
enum ScanProgressPublicationPolicy {
    static let minimumInterval: TimeInterval = 1.0

    static func delay(
        lastPublicationUptime: TimeInterval?,
        nowUptime: TimeInterval
    ) -> TimeInterval {
        guard let lastPublicationUptime else { return 0 }
        return max(0, minimumInterval - (nowUptime - lastPublicationUptime))
    }

    static func isResumeCheckpoint(scannedAssets: Int) -> Bool {
        scannedAssets > 0 && scannedAssets.isMultiple(of: 1_000)
    }

    static func preservingLiveRescanIntent(
        pending: ScanState,
        live: ScanState
    ) -> ScanState {
        guard live.requiresFullRescan else { return pending }
        var value = pending
        value.requiresFullRescan = true
        value.purpose = live.purpose ?? value.purpose
        return value
    }
}

/// Produces a full-bleed display crop centred on the detected cat. Even when
/// a wide union cannot fit wholly inside a square, it returns the best cover
/// crop instead of introducing letterboxing into the thumbnail itself.
enum PhotoThumbnailCropPolicy {
    static func cropRect(
        aroundVisionRect visionRect: CGRect,
        imagePixelSize: CGSize,
        targetAspectRatio: CGFloat
    ) -> CGRect? {
        guard imagePixelSize.width > 0,
              imagePixelSize.height > 0,
              targetAspectRatio > 0 else {
            return nil
        }

        // Vision uses a bottom-left origin; PhotoKit uses top-left here.
        let photoRect = CGRect(
            x: visionRect.minX,
            y: 1 - visionRect.maxY,
            width: visionRect.width,
            height: visionRect.height
        )
        let imageAspect = imagePixelSize.width / imagePixelSize.height

        let cropWidth: CGFloat
        let cropHeight: CGFloat
        if imageAspect > targetAspectRatio {
            cropWidth = targetAspectRatio / imageAspect
            cropHeight = 1
        } else {
            cropWidth = 1
            cropHeight = imageAspect / targetAspectRatio
        }

        let horizontalMargin = visionRect.width * 0.12
        let verticalMargin = visionRect.height * 0.12
        let paddedPhotoRect = photoRect.insetBy(
            dx: -horizontalMargin,
            dy: -verticalMargin
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !paddedPhotoRect.isNull,
              !paddedPhotoRect.isEmpty,
              paddedPhotoRect.midX.isFinite,
              paddedPhotoRect.midY.isFinite else {
            return nil
        }

        let preferredX = paddedPhotoRect.midX - cropWidth / 2
        let preferredY = paddedPhotoRect.midY - cropHeight / 2
        return CGRect(
            x: min(max(preferredX, 0), 1 - cropWidth),
            y: min(max(preferredY, 0), 1 - cropHeight),
            width: cropWidth,
            height: cropHeight
        )
    }
}
