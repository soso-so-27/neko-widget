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
        let scoped = scopedCandidates(from: assets, settings: settings, now: now)
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
        let all = scopedCandidates(from: assets, settings: settings, now: now)
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
        let all = scopedCandidates(from: assets, settings: settings, now: now)
        let recentCutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let fresh = all.filter {
            guard let lastShownAt = $0.lastShownAt else { return true }
            return lastShownAt < recentCutoff
        }
        let freshIDs = Set(fresh.map(\.localIdentifier))
        let older = all.filter { !freshIDs.contains($0.localIdentifier) }
        return weightedOrder(fresh) + weightedOrder(older)
    }

    private func scopedCandidates(
        from assets: [AssetRecord],
        settings: AppSettings,
        now: Date
    ) -> [AssetRecord] {
        // A cancelled threshold-changing rescan deliberately keeps old records
        // so likes and progress can resume. Never publish those records until
        // they have been analyzed with the active detector fingerprint.
        let fingerprint = settings.analysisFingerprint
        let cats = assets.filter {
            $0.isCatCandidate && $0.analysisFingerprint == fingerprint
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
