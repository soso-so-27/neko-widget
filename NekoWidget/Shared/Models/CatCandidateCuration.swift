import Foundation

/// A user-owned decision that a detected cat photo is not part of this pet's
/// memories. PhotoKit assets are never deleted or modified by this state.
struct ExcludedCatAsset: Codable, Equatable, Identifiable, Sendable {
    var localIdentifier: String
    var excludedAt: Date

    var id: String { localIdentifier }
}

/// Durable curation state intentionally lives outside the scan snapshot.
///
/// Scanner checkpoints replace active records and retain dormant Vision cache
/// entries. Keeping user decisions here still makes them authoritative across
/// every publication and avoids a widget/app like merge racing with a long scan.
struct CatCandidateCurationState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    /// Monotonic store-owned ordering. Awaiting actor calls can resume out of
    /// order on the main actor; callers use this value to reject stale returns.
    var mutationRevision: Int
    var excludedAssets: [ExcludedCatAsset]
    /// nil means the complete readable PhotoKit library. The identifier is
    /// local-only and is never written to diagnostic JSON or logs.
    var sourceAlbumIdentifier: String?
    /// Last successfully resolved membership for the selected source. Keeping
    /// it beside the selection closes the crash gap between the source decision
    /// and a scan/checkpoint publication, and preserves the prior narrow scope
    /// if the collection is later deleted or hidden by limited access.
    var lastKnownSourceAssetIdentifiers: [String]?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mutationRevision
        case excludedAssets
        // Accepted only as a migration path for pre-release/prototype state.
        case excludedAssetIdentifiers
        case sourceAlbumIdentifier
        case lastKnownSourceAssetIdentifiers
    }

    init(
        schemaVersion: Int = currentSchemaVersion,
        mutationRevision: Int = 0,
        excludedAssets: [ExcludedCatAsset],
        sourceAlbumIdentifier: String?,
        lastKnownSourceAssetIdentifiers: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.mutationRevision = mutationRevision
        self.excludedAssets = excludedAssets
        self.sourceAlbumIdentifier = sourceAlbumIdentifier
        self.lastKnownSourceAssetIdentifiers = lastKnownSourceAssetIdentifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        mutationRevision = try container.decodeIfPresent(
            Int.self,
            forKey: .mutationRevision
        ) ?? 0
        if let exclusions = try container.decodeIfPresent(
            [ExcludedCatAsset].self,
            forKey: .excludedAssets
        ) {
            excludedAssets = exclusions
        } else {
            let legacyIdentifiers = try container.decodeIfPresent(
                [String].self,
                forKey: .excludedAssetIdentifiers
            ) ?? []
            excludedAssets = legacyIdentifiers.map {
                ExcludedCatAsset(
                    localIdentifier: $0,
                    excludedAt: Date(timeIntervalSince1970: 0)
                )
            }
        }
        sourceAlbumIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .sourceAlbumIdentifier
        )
        lastKnownSourceAssetIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .lastKnownSourceAssetIdentifiers
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(mutationRevision, forKey: .mutationRevision)
        try container.encode(excludedAssets, forKey: .excludedAssets)
        try container.encodeIfPresent(
            sourceAlbumIdentifier,
            forKey: .sourceAlbumIdentifier
        )
        try container.encodeIfPresent(
            lastKnownSourceAssetIdentifiers,
            forKey: .lastKnownSourceAssetIdentifiers
        )
    }

    static let empty = CatCandidateCurationState(
        schemaVersion: currentSchemaVersion,
        mutationRevision: 0,
        excludedAssets: [],
        sourceAlbumIdentifier: nil,
        lastKnownSourceAssetIdentifiers: nil
    )

    var excludedAssetIdentifiers: Set<String> {
        Set(excludedAssets.map(\.localIdentifier))
    }

    var usesSelectedAlbum: Bool { sourceAlbumIdentifier != nil }

    var lastKnownSourceAssetIdentifierSet: Set<String>? {
        lastKnownSourceAssetIdentifiers.map { Set($0) }
    }

    func contains(_ localIdentifier: String) -> Bool {
        excludedAssets.contains { $0.localIdentifier == localIdentifier }
    }

    /// Applies both user-owned curation axes without moving either decision
    /// into the replaceable scan snapshot. Runtime membership wins when the
    /// collection is readable; the last durable membership is the fail-closed
    /// fallback when it is unavailable.
    func includesCandidate(
        localIdentifier: String,
        selectedSourceAssetIdentifiers: Set<String>?
    ) -> Bool {
        guard !contains(localIdentifier) else { return false }
        guard usesSelectedAlbum else { return true }
        guard let sourceIdentifiers = selectedSourceAssetIdentifiers
            ?? lastKnownSourceAssetIdentifierSet else {
            // A migrated/corrupt selection with no known membership must not
            // silently become an all-library source.
            return false
        }
        return sourceIdentifiers.contains(localIdentifier)
    }

    mutating func exclude(
        localIdentifiers: some Sequence<String>,
        at date: Date = .now
    ) {
        let previous = excludedAssets
        var byIdentifier: [String: ExcludedCatAsset] = [:]
        for exclusion in excludedAssets {
            if byIdentifier[exclusion.localIdentifier] == nil {
                byIdentifier[exclusion.localIdentifier] = exclusion
            }
        }
        for identifier in localIdentifiers {
            guard Self.isValidLocalIdentifier(identifier) else { continue }
            if byIdentifier[identifier] == nil {
                byIdentifier[identifier] = ExcludedCatAsset(
                    localIdentifier: identifier,
                    excludedAt: date
                )
            }
        }
        excludedAssets = Self.ordered(Array(byIdentifier.values))
        if excludedAssets != previous { advanceRevision() }
    }

    mutating func restore(localIdentifiers: some Sequence<String>) {
        let restored = Set(localIdentifiers)
        guard !restored.isEmpty else { return }
        let previousCount = excludedAssets.count
        excludedAssets.removeAll { restored.contains($0.localIdentifier) }
        if excludedAssets.count != previousCount { advanceRevision() }
    }

    mutating func selectSourceAlbum(
        localIdentifier: String?,
        assetIdentifiers: [String]? = nil
    ) {
        guard let localIdentifier else {
            guard sourceAlbumIdentifier != nil
                    || lastKnownSourceAssetIdentifiers != nil else { return }
            sourceAlbumIdentifier = nil
            lastKnownSourceAssetIdentifiers = nil
            advanceRevision()
            return
        }
        // An invalid non-nil selection must never broaden an existing scoped
        // source back to the full library.
        guard Self.isValidLocalIdentifier(localIdentifier) else { return }
        let normalizedIdentifiers = assetIdentifiers.map {
            Self.normalizedIdentifiers($0)
        }
        guard sourceAlbumIdentifier != localIdentifier
                || lastKnownSourceAssetIdentifiers != normalizedIdentifiers else { return }
        sourceAlbumIdentifier = localIdentifier
        lastKnownSourceAssetIdentifiers = normalizedIdentifiers
        advanceRevision()
    }

    func normalized() -> Self {
        var value = self
        value.schemaVersion = Self.currentSchemaVersion
        value.mutationRevision = max(value.mutationRevision, 0)
        var unique: [String: ExcludedCatAsset] = [:]
        for exclusion in excludedAssets
        where Self.isValidLocalIdentifier(exclusion.localIdentifier) {
            if let previous = unique[exclusion.localIdentifier],
               previous.excludedAt <= exclusion.excludedAt {
                continue
            }
            unique[exclusion.localIdentifier] = exclusion
        }
        value.excludedAssets = Self.ordered(Array(unique.values))
        if value.sourceAlbumIdentifier == nil {
            value.lastKnownSourceAssetIdentifiers = nil
        } else if let identifiers = value.lastKnownSourceAssetIdentifiers {
            value.lastKnownSourceAssetIdentifiers = Self.normalizedIdentifiers(identifiers)
        }
        return value
    }

    private mutating func advanceRevision() {
        if mutationRevision < Int.max { mutationRevision += 1 }
    }

    private static func normalizedIdentifiers(_ values: [String]) -> [String] {
        Array(Set(values.filter { isValidLocalIdentifier($0) })).sorted()
    }

    private static func ordered(_ values: [ExcludedCatAsset]) -> [ExcludedCatAsset] {
        values.sorted {
            if $0.excludedAt == $1.excludedAt {
                return $0.localIdentifier < $1.localIdentifier
            }
            return $0.excludedAt > $1.excludedAt
        }
    }

    private static func isValidLocalIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 4_096
    }
}

/// Safe diagnostic representation. PhotoKit identifiers deliberately do not
/// cross this boundary, even though the local curation store needs them.
struct CatCandidateCurationExportSummary: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var excludedAssetCount: Int
    var sourceAlbumConfigured: Bool
    var containsSourceAlbumIdentifier = false
    var containsSourceAssetIdentifiers = false
    var containsExcludedAssetIdentifiers = false
    var containsPhotoData = false

    init(state: CatCandidateCurationState) {
        excludedAssetCount = state.excludedAssetIdentifiers.count
        sourceAlbumConfigured = state.usesSelectedAlbum
    }
}

/// Pure policy used by the PhotoKit scanner so source changes never destroy
/// reusable full-library Vision results. Scan progress/state still describes
/// only the active source; these identifiers are dormant cache entries.
enum PhotoSourceCachePolicy {
    static func dormantIdentifiers(
        existingIdentifiers: [String],
        activeIdentifiers: Set<String>,
        usesSelectedSource: Bool
    ) -> Set<String> {
        guard usesSelectedSource else { return [] }
        return Set(existingIdentifiers).subtracting(activeIdentifiers)
    }
}

/// Pure cold-launch gate for Widget photo routes. The app can receive a URL
/// before its local curation and snapshot stores are ready; retaining only the
/// newest request prevents an excluded or out-of-source photo from routing
/// against the temporary empty/default state.
struct CandidatePhotoRoute: Equatable, Sendable {
    var localIdentifier: String
    var shownAt: Date?
}

struct CandidatePhotoRouteGate: Equatable, Sendable {
    private(set) var pending: CandidatePhotoRoute?

    var hasPendingRoute: Bool { pending != nil }

    mutating func receive(
        _ route: CandidatePhotoRoute,
        candidateStateIsReady: Bool
    ) -> CandidatePhotoRoute? {
        guard !candidateStateIsReady else {
            pending = nil
            return route
        }
        pending = route
        return nil
    }

    mutating func finishLoading(succeeded: Bool) -> CandidatePhotoRoute? {
        let route = pending
        pending = nil
        return succeeded ? route : nil
    }
}
