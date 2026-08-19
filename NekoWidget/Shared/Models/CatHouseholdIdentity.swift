import Foundation

/// `JSONEncoder.iso8601` persists whole seconds. Canonicalizing user-decision
/// timestamps before comparison keeps migration and save round-trips idempotent.
private func catIdentityTimestamp(_ value: Date) -> Date {
    Date(timeIntervalSince1970: floor(value.timeIntervalSince1970))
}

/// Whether the app is still presenting the Build 13 household-wide candidate
/// set or has entered an explicitly user-configured per-cat experience.
enum CatHouseholdIdentityMode: String, Codable, Equatable, Sendable {
    case legacyUnscoped
    case profiled
}

/// A user-owned cat identity. Vision detections never create profiles or move
/// a life reference between profiles.
struct CatProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var displayName: String
    var lifeReference: CatLifeReference?
    /// Rescue cats often have an estimated birthday. This flag is display
    /// metadata only and must not affect Vision analysis.
    var lifeReferenceIsApproximate: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        lifeReference: CatLifeReference? = nil,
        lifeReferenceIsApproximate: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.lifeReference = lifeReference
        self.lifeReferenceIsApproximate = lifeReference != nil
            && lifeReferenceIsApproximate
        self.createdAt = catIdentityTimestamp(createdAt)
        self.updatedAt = catIdentityTimestamp(max(createdAt, updatedAt))
    }

    func normalized() -> Self {
        var value = self
        value.displayName = String(
            displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(80)
        )
        if value.lifeReference == nil {
            value.lifeReferenceIsApproximate = false
        }
        value.createdAt = catIdentityTimestamp(value.createdAt)
        value.updatedAt = catIdentityTimestamp(max(value.createdAt, value.updatedAt))
        return value
    }
}

/// A missing membership has exactly the same meaning as `.unknown`. Keeping an
/// explicit unknown record lets the UI preserve a deliberate "わからない"
/// correction without pretending it is a positive or negative identity label.
enum CatAssetMembershipDecision: String, Codable, Equatable, Sendable {
    case unknown
    case included
    case excluded
}

/// A manual, per-profile decision for one PhotoKit asset. The composite key is
/// `(assetLocalIdentifier, profileID)`, so one photo may include several cats.
/// The subject rectangle is a value in Vision coordinates, never an index into
/// a scanner result whose ordering could change on the next analysis pass.
struct CatAssetProfileMembership: Codable, Equatable, Sendable {
    var assetLocalIdentifier: String
    var profileID: UUID
    var decision: CatAssetMembershipDecision
    var subjectBoundingBox: NormalizedRect?
    /// Only a user-explicit positive may become a future similarity-search
    /// anchor. Existing global exclusions and model suggestions never set it.
    var isSimilarityReference: Bool
    var decidedAt: Date

    init(
        assetLocalIdentifier: String,
        profileID: UUID,
        decision: CatAssetMembershipDecision,
        subjectBoundingBox: NormalizedRect? = nil,
        isSimilarityReference: Bool = false,
        decidedAt: Date = .now
    ) {
        self.assetLocalIdentifier = assetLocalIdentifier
        self.profileID = profileID
        self.decision = decision
        self.subjectBoundingBox = decision == .included ? subjectBoundingBox : nil
        self.isSimilarityReference = decision == .included && isSimilarityReference
        self.decidedAt = catIdentityTimestamp(decidedAt)
    }
}

/// Build 13 metadata retained without claiming that it belongs to a particular
/// cat. The exact date and PhotoKit identifiers remain local-only.
struct CatLegacyUnscopedIdentity: Codable, Equatable, Sendable {
    var lifeReference: CatLifeReference?
    var sourceAlbumIdentifier: String?
    var lastKnownSourceAssetIdentifiers: [String]?
    /// Photos excluded before profiles existed. New profile-era household
    /// exclusions are not added, so the one-time review never mislabels them.
    var legacyExcludedAssetIdentifiers: [String]
    var importedCurationMutationRevision: Int
}

/// Durable user-owned identity state, deliberately separate from the
/// replaceable scanner snapshot. Scanner output is evidence; this file records
/// the user's household and manual many-to-many identity decisions.
struct CatHouseholdIdentityState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// Store-owned ordering. Model mutators do not advance it; a successful
    /// compare-and-swap save advances it exactly once.
    var mutationRevision: Int
    var mode: CatHouseholdIdentityMode
    var profiles: [CatProfile]
    var memberships: [CatAssetProfileMembership]
    /// Household-wide "うちの子が写っていない" decisions. These are not
    /// negative samples for any profile and are never similarity references.
    var globalExcludedAssets: [ExcludedCatAsset]
    /// Present after migration so the Build 13 experience can continue without
    /// assigning its one life reference to an invented profile.
    var legacyUnscoped: CatLegacyUnscopedIdentity?
    var createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mutationRevision
        case mode
        case profiles
        case memberships
        case globalExcludedAssets
        case legacyUnscoped
        case createdAt
        case updatedAt
    }

    init(
        schemaVersion: Int = currentSchemaVersion,
        mutationRevision: Int = 0,
        mode: CatHouseholdIdentityMode,
        profiles: [CatProfile],
        memberships: [CatAssetProfileMembership],
        globalExcludedAssets: [ExcludedCatAsset],
        legacyUnscoped: CatLegacyUnscopedIdentity?,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.mutationRevision = mutationRevision
        self.mode = mode
        self.profiles = profiles
        self.memberships = memberships
        self.globalExcludedAssets = globalExcludedAssets
        self.legacyUnscoped = legacyUnscoped
        self.createdAt = catIdentityTimestamp(createdAt)
        self.updatedAt = catIdentityTimestamp(max(createdAt, updatedAt))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? 1
        mutationRevision = try container.decodeIfPresent(
            Int.self,
            forKey: .mutationRevision
        ) ?? 0
        mode = try container.decodeIfPresent(
            CatHouseholdIdentityMode.self,
            forKey: .mode
        ) ?? .legacyUnscoped
        profiles = try container.decodeIfPresent(
            [CatProfile].self,
            forKey: .profiles
        ) ?? []
        memberships = try container.decodeIfPresent(
            [CatAssetProfileMembership].self,
            forKey: .memberships
        ) ?? []
        globalExcludedAssets = try container.decodeIfPresent(
            [ExcludedCatAsset].self,
            forKey: .globalExcludedAssets
        ) ?? []
        legacyUnscoped = try container.decodeIfPresent(
            CatLegacyUnscopedIdentity.self,
            forKey: .legacyUnscoped
        )
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? Date(timeIntervalSince1970: 0)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? createdAt
    }

    static func legacyUnscoped(
        lifeReference: CatLifeReference?,
        curation inputCuration: CatCandidateCurationState,
        at date: Date = .now
    ) -> Self {
        let curation = inputCuration.normalized()
        return Self(
            mode: .legacyUnscoped,
            profiles: [],
            memberships: [],
            globalExcludedAssets: curation.excludedAssets,
            legacyUnscoped: CatLegacyUnscopedIdentity(
                lifeReference: lifeReference,
                sourceAlbumIdentifier: curation.sourceAlbumIdentifier,
                lastKnownSourceAssetIdentifiers: curation.lastKnownSourceAssetIdentifiers,
                legacyExcludedAssetIdentifiers: curation.excludedAssets.map(\.localIdentifier),
                importedCurationMutationRevision: curation.mutationRevision
            ),
            createdAt: date,
            updatedAt: date
        ).normalized()
    }

    /// Reconciles only while Build 13 state remains authoritative. It never
    /// creates a profile or membership, and becomes a no-op once the user has
    /// explicitly entered profiled mode.
    func reconcilingLegacyUnscoped(
        lifeReference: CatLifeReference?,
        curation inputCuration: CatCandidateCurationState,
        at date: Date = .now
    ) -> Self {
        guard mode == .legacyUnscoped else { return self }
        let curation = inputCuration.normalized()
        var imported = legacyUnscoped ?? CatLegacyUnscopedIdentity(
            lifeReference: nil,
            sourceAlbumIdentifier: nil,
            lastKnownSourceAssetIdentifiers: nil,
            legacyExcludedAssetIdentifiers: [],
            importedCurationMutationRevision: -1
        )
        imported.lifeReference = lifeReference
        let hasNewerCuration = curation.mutationRevision
            > imported.importedCurationMutationRevision
        if hasNewerCuration {
            imported.sourceAlbumIdentifier = curation.sourceAlbumIdentifier
            imported.lastKnownSourceAssetIdentifiers = curation
                .lastKnownSourceAssetIdentifiers
            imported.legacyExcludedAssetIdentifiers = curation.excludedAssets
                .map(\.localIdentifier)
            imported.importedCurationMutationRevision = curation.mutationRevision
        }
        let reconciledExclusions = hasNewerCuration
            ? curation.excludedAssets
            : globalExcludedAssets
        guard globalExcludedAssets != reconciledExclusions
                || legacyUnscoped != imported else {
            return self
        }
        var value = self
        value.globalExcludedAssets = reconciledExclusions
        value.legacyUnscoped = imported
        value = value.normalized()
        let current = normalized()
        guard value.globalExcludedAssets != current.globalExcludedAssets
                || value.legacyUnscoped != current.legacyUnscoped else {
            return self
        }
        value.updatedAt = catIdentityTimestamp(
            max(current.updatedAt, max(value.createdAt, date))
        )
        return value
    }

    func membershipDecision(
        for assetLocalIdentifier: String,
        profileID: UUID
    ) -> CatAssetMembershipDecision {
        membership(for: assetLocalIdentifier, profileID: profileID)?.decision ?? .unknown
    }

    func membership(
        for assetLocalIdentifier: String,
        profileID: UUID
    ) -> CatAssetProfileMembership? {
        memberships.first {
            $0.assetLocalIdentifier == assetLocalIdentifier && $0.profileID == profileID
        }
    }

    func includedProfileIDs(for assetLocalIdentifier: String) -> Set<UUID> {
        Set(memberships.lazy.filter {
            $0.assetLocalIdentifier == assetLocalIdentifier && $0.decision == .included
        }.map(\.profileID))
    }

    func subjectBoundingBox(
        for assetLocalIdentifier: String,
        profileID: UUID
    ) -> NormalizedRect? {
        membership(for: assetLocalIdentifier, profileID: profileID)?.subjectBoundingBox
    }

    func isGloballyExcluded(_ assetLocalIdentifier: String) -> Bool {
        globalExcludedAssets.contains { $0.localIdentifier == assetLocalIdentifier }
    }

    mutating func upsertProfile(_ input: CatProfile, at date: Date = .now) {
        var profile = input.normalized()
        profile.updatedAt = catIdentityTimestamp(
            max(profile.updatedAt, max(profile.createdAt, date))
        )
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profile.createdAt = min(profiles[index].createdAt, profile.createdAt)
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        mode = .profiled
        updatedAt = max(updatedAt, max(createdAt, date))
        self = normalized()
    }

    mutating func removeProfile(id: UUID, at date: Date = .now) {
        let previousCount = profiles.count
        profiles.removeAll { $0.id == id }
        memberships.removeAll { $0.profileID == id }
        guard profiles.count != previousCount else { return }
        mode = .profiled
        updatedAt = max(updatedAt, max(createdAt, date))
        self = normalized()
    }

    /// Records a user decision only. Similarity suggestions must use a separate
    /// proposal type and call this method only after explicit confirmation.
    mutating func setManualMembership(
        assetLocalIdentifier: String,
        profileID: UUID,
        decision: CatAssetMembershipDecision,
        subjectBoundingBox: NormalizedRect? = nil,
        isSimilarityReference: Bool = false,
        at date: Date = .now
    ) {
        guard Self.isValidLocalIdentifier(assetLocalIdentifier),
              profiles.contains(where: { $0.id == profileID }),
              !isGloballyExcluded(assetLocalIdentifier) else { return }
        let value = CatAssetProfileMembership(
            assetLocalIdentifier: assetLocalIdentifier,
            profileID: profileID,
            decision: decision,
            subjectBoundingBox: subjectBoundingBox,
            isSimilarityReference: isSimilarityReference,
            decidedAt: date
        )
        if let index = memberships.firstIndex(where: {
            $0.assetLocalIdentifier == assetLocalIdentifier && $0.profileID == profileID
        }) {
            memberships[index] = value
        } else {
            memberships.append(value)
        }
        updatedAt = max(updatedAt, max(createdAt, date))
        self = normalized()
    }

    /// A global exclusion removes all per-profile decisions for that photo. If
    /// it is restored later, it deliberately returns as unknown rather than
    /// silently restoring a previous identity assignment.
    mutating func setGloballyExcluded(
        _ excluded: Bool,
        assetLocalIdentifiers: some Sequence<String>,
        at date: Date = .now
    ) {
        let identifiers = Set(assetLocalIdentifiers.filter(Self.isValidLocalIdentifier))
        guard !identifiers.isEmpty else { return }
        let previous = globalExcludedAssets
        if excluded {
            var byIdentifier: [String: ExcludedCatAsset] = [:]
            for exclusion in globalExcludedAssets {
                if let previous = byIdentifier[exclusion.localIdentifier],
                   previous.excludedAt <= exclusion.excludedAt {
                    continue
                }
                byIdentifier[exclusion.localIdentifier] = exclusion
            }
            for identifier in identifiers where byIdentifier[identifier] == nil {
                byIdentifier[identifier] = ExcludedCatAsset(
                    localIdentifier: identifier,
                    excludedAt: date
                )
            }
            globalExcludedAssets = Array(byIdentifier.values)
            memberships.removeAll { identifiers.contains($0.assetLocalIdentifier) }
        } else {
            globalExcludedAssets.removeAll { identifiers.contains($0.localIdentifier) }
        }
        guard globalExcludedAssets != previous else { return }
        updatedAt = max(updatedAt, max(createdAt, date))
        self = normalized()
    }

    func normalized() -> Self {
        var value = self
        value.schemaVersion = Self.currentSchemaVersion
        value.mutationRevision = max(0, mutationRevision)
        value.createdAt = catIdentityTimestamp(value.createdAt)
        value.updatedAt = catIdentityTimestamp(max(value.createdAt, value.updatedAt))

        var profilesByID: [UUID: CatProfile] = [:]
        for profile in profiles.map({ $0.normalized() }) {
            guard let previous = profilesByID[profile.id] else {
                profilesByID[profile.id] = profile
                continue
            }
            if profile.updatedAt > previous.updatedAt
                || (profile.updatedAt == previous.updatedAt
                    && profile.displayName < previous.displayName) {
                profilesByID[profile.id] = profile
            }
        }
        value.profiles = profilesByID.values.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }

        var exclusionsByIdentifier: [String: ExcludedCatAsset] = [:]
        for input in globalExcludedAssets
        where Self.isValidLocalIdentifier(input.localIdentifier) {
            var exclusion = input
            exclusion.excludedAt = catIdentityTimestamp(exclusion.excludedAt)
            guard let previous = exclusionsByIdentifier[exclusion.localIdentifier] else {
                exclusionsByIdentifier[exclusion.localIdentifier] = exclusion
                continue
            }
            if exclusion.excludedAt < previous.excludedAt {
                exclusionsByIdentifier[exclusion.localIdentifier] = exclusion
            }
        }
        value.globalExcludedAssets = exclusionsByIdentifier.values.sorted {
            if $0.excludedAt == $1.excludedAt {
                return $0.localIdentifier < $1.localIdentifier
            }
            return $0.excludedAt > $1.excludedAt
        }

        let validProfileIDs = Set(value.profiles.map(\.id))
        let globallyExcluded = Set(value.globalExcludedAssets.map(\.localIdentifier))
        var membershipsByKey: [MembershipKey: CatAssetProfileMembership] = [:]
        for input in memberships
        where Self.isValidLocalIdentifier(input.assetLocalIdentifier)
            && validProfileIDs.contains(input.profileID)
            && !globallyExcluded.contains(input.assetLocalIdentifier) {
            var membership = input
            membership.decidedAt = catIdentityTimestamp(membership.decidedAt)
            if membership.decision != .included {
                membership.subjectBoundingBox = nil
                membership.isSimilarityReference = false
            } else {
                membership.subjectBoundingBox = Self.validatedSubjectBoundingBox(
                    membership.subjectBoundingBox
                )
            }
            let key = MembershipKey(
                assetLocalIdentifier: membership.assetLocalIdentifier,
                profileID: membership.profileID
            )
            guard let previous = membershipsByKey[key] else {
                membershipsByKey[key] = membership
                continue
            }
            if membership.decidedAt > previous.decidedAt
                || (membership.decidedAt == previous.decidedAt
                    && membership.decision.rawValue < previous.decision.rawValue) {
                membershipsByKey[key] = membership
            }
        }
        value.memberships = membershipsByKey.values.sorted {
            if $0.assetLocalIdentifier == $1.assetLocalIdentifier {
                return $0.profileID.uuidString < $1.profileID.uuidString
            }
            return $0.assetLocalIdentifier < $1.assetLocalIdentifier
        }

        if var legacy = value.legacyUnscoped {
            legacy.importedCurationMutationRevision = max(
                0,
                legacy.importedCurationMutationRevision
            )
            if legacy.sourceAlbumIdentifier == nil {
                legacy.lastKnownSourceAssetIdentifiers = nil
            } else if let identifiers = legacy.lastKnownSourceAssetIdentifiers {
                legacy.lastKnownSourceAssetIdentifiers = Array(Set(
                    identifiers.filter(Self.isValidLocalIdentifier)
                )).sorted()
            }
            legacy.legacyExcludedAssetIdentifiers = Array(Set(
                legacy.legacyExcludedAssetIdentifiers.filter(Self.isValidLocalIdentifier)
            )).sorted()
            value.legacyUnscoped = legacy
        }
        return value
    }

    private struct MembershipKey: Hashable {
        var assetLocalIdentifier: String
        var profileID: UUID
    }

    private static func isValidLocalIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 4_096
    }

    private static func validatedSubjectBoundingBox(
        _ value: NormalizedRect?
    ) -> NormalizedRect? {
        guard let value,
              value.x.isFinite,
              value.y.isFinite,
              value.width.isFinite,
              value.height.isFinite,
              value.x >= 0,
              value.y >= 0,
              value.width > 0,
              value.height > 0,
              value.x + value.width <= 1,
              value.y + value.height <= 1 else { return nil }
        return value
    }
}

enum CatHouseholdIdentityRevisionError: Error, Equatable {
    case stale(expected: Int, actual: Int)
    case proposedRevisionMismatch(expected: Int, actual: Int)
    case exhausted
}

/// Pure compare-and-swap policy shared by the actor store and its verifier.
enum CatHouseholdIdentityRevisionPolicy {
    static func committing(
        _ proposed: CatHouseholdIdentityState,
        replacing current: CatHouseholdIdentityState,
        expectedMutationRevision: Int,
        at date: Date = .now
    ) throws -> CatHouseholdIdentityState {
        guard current.mutationRevision == expectedMutationRevision else {
            throw CatHouseholdIdentityRevisionError.stale(
                expected: expectedMutationRevision,
                actual: current.mutationRevision
            )
        }
        guard proposed.mutationRevision == expectedMutationRevision else {
            throw CatHouseholdIdentityRevisionError.proposedRevisionMismatch(
                expected: expectedMutationRevision,
                actual: proposed.mutationRevision
            )
        }
        guard expectedMutationRevision < Int.max else {
            throw CatHouseholdIdentityRevisionError.exhausted
        }
        var committed = proposed.normalized()
        committed.mutationRevision = expectedMutationRevision + 1
        committed.createdAt = current.createdAt
        committed.updatedAt = max(current.updatedAt, max(current.createdAt, date))
        return committed.normalized()
    }
}
