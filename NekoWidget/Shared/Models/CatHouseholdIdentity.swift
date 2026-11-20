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

/// A user-selected, regular Photos album that acts as an explicit source for
/// one profile. The asset identifiers remain local-only. Keeping the last
/// successfully read membership makes an album rename or a transient Limited
/// Photos Access gap non-destructive; removing the link discards only this
/// source and never changes manual decisions.
struct CatProfilePhotoAlbumLink: Codable, Equatable, Sendable {
    var localIdentifier: String
    var lastKnownAssetLocalIdentifiers: [String]
    var linkedAt: Date
    var refreshedAt: Date

    init(
        localIdentifier: String,
        lastKnownAssetLocalIdentifiers: [String],
        linkedAt: Date = .now,
        refreshedAt: Date = .now
    ) {
        self.localIdentifier = localIdentifier
        self.lastKnownAssetLocalIdentifiers = lastKnownAssetLocalIdentifiers
        self.linkedAt = catIdentityTimestamp(linkedAt)
        self.refreshedAt = catIdentityTimestamp(max(linkedAt, refreshedAt))
    }

    func normalized() -> Self? {
        guard Self.isValidIdentifier(localIdentifier) else { return nil }
        var value = self
        value.lastKnownAssetLocalIdentifiers = Array(Set(
            lastKnownAssetLocalIdentifiers.filter(Self.isValidIdentifier)
        )).sorted()
        value.linkedAt = catIdentityTimestamp(value.linkedAt)
        value.refreshedAt = catIdentityTimestamp(
            max(value.linkedAt, value.refreshedAt)
        )
        return value
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 4_096
    }
}

/// Optional calendar metadata for each milestone. An explicit empty value is
/// distinct from an older profile that has not yet stored both date fields.
struct CatProfileLifeDates: Codable, Equatable, Sendable {
    var birthday: CatLifeDate?
    var birthdayIsApproximate: Bool
    var adoptionDay: CatLifeDate?
    var adoptionDayIsApproximate: Bool

    init(
        birthday: CatLifeDate? = nil,
        birthdayIsApproximate: Bool = false,
        adoptionDay: CatLifeDate? = nil,
        adoptionDayIsApproximate: Bool = false
    ) {
        self.birthday = birthday
        self.birthdayIsApproximate = birthday != nil && birthdayIsApproximate
        self.adoptionDay = adoptionDay
        self.adoptionDayIsApproximate = adoptionDay != nil && adoptionDayIsApproximate
    }

    func reference(for kind: CatLifeReferenceKind) -> CatLifeReference? {
        let date = kind == .birthday ? birthday : adoptionDay
        return date.map { CatLifeReference(kind: kind, date: $0) }
    }

    func isApproximate(for kind: CatLifeReferenceKind) -> Bool {
        switch kind {
        case .birthday: birthday != nil && birthdayIsApproximate
        case .adoptionDay: adoptionDay != nil && adoptionDayIsApproximate
        }
    }

    func normalized() -> Self {
        Self(
            birthday: birthday,
            birthdayIsApproximate: birthdayIsApproximate,
            adoptionDay: adoptionDay,
            adoptionDayIsApproximate: adoptionDayIsApproximate
        )
    }
}

/// 11/15: the app sets this while the family notebook has a cat that is not
/// linked to a cat of this iPhone (FamilyNotebookCatLink). Nothing is saved:
/// it is read again with every call, like the single-cat rule itself.
enum CatSingleCatRule {
    static var familyCatsOutsideProfiles = false
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
    /// Nil preserves older JSON's single life reference. Once edited, this
    /// value is authoritative even when both dates are explicitly cleared.
    var lifeDates: CatProfileLifeDates?
    /// A user-picked photo, kept stable when newer photos arrive. Its PhotoKit
    /// identifier is local-only and household normalization checks membership.
    var keyPhotoLocalIdentifier: String?
    /// Optional explicit input from a user-created Photos album. This is not
    /// the household scan-source album and not the app-managed `うちの子`
    /// output album.
    var photoAlbumLink: CatProfilePhotoAlbumLink?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        lifeReference: CatLifeReference? = nil,
        lifeReferenceIsApproximate: Bool = false,
        lifeDates: CatProfileLifeDates? = nil,
        keyPhotoLocalIdentifier: String? = nil,
        photoAlbumLink: CatProfilePhotoAlbumLink? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.lifeReference = lifeReference
        self.lifeReferenceIsApproximate = lifeReference != nil
            && lifeReferenceIsApproximate
        self.lifeDates = lifeDates
        self.keyPhotoLocalIdentifier = keyPhotoLocalIdentifier
        self.photoAlbumLink = photoAlbumLink
        self.createdAt = catIdentityTimestamp(createdAt)
        self.updatedAt = catIdentityTimestamp(max(createdAt, updatedAt))
        if let lifeDates {
            setLifeDates(lifeDates)
        }
    }

    var resolvedLifeDates: CatProfileLifeDates {
        if let lifeDates { return lifeDates.normalized() }
        guard let lifeReference else { return CatProfileLifeDates() }
        switch lifeReference.kind {
        case .birthday:
            return CatProfileLifeDates(
                birthday: lifeReference.date,
                birthdayIsApproximate: lifeReferenceIsApproximate
            )
        case .adoptionDay:
            return CatProfileLifeDates(
                adoptionDay: lifeReference.date,
                adoptionDayIsApproximate: lifeReferenceIsApproximate
            )
        }
    }

    func lifeReference(for kind: CatLifeReferenceKind) -> CatLifeReference? {
        resolvedLifeDates.reference(for: kind)
    }

    func isLifeReferenceApproximate(for kind: CatLifeReferenceKind) -> Bool {
        resolvedLifeDates.isApproximate(for: kind)
    }

    /// Keeps the legacy fields as the explicit basis for growth grouping.
    /// Adding a second milestone does not silently change an existing basis.
    mutating func setLifeDates(
        _ dates: CatProfileLifeDates,
        preferredPrimaryKind: CatLifeReferenceKind? = nil
    ) {
        let dates = dates.normalized()
        let candidateKinds: [CatLifeReferenceKind?] = [
            preferredPrimaryKind, lifeReference?.kind, .birthday, .adoptionDay
        ]
        let selectedKind = candidateKinds
            .compactMap { $0 }
            .first { dates.reference(for: $0) != nil }
        lifeDates = dates
        lifeReference = selectedKind.flatMap { dates.reference(for: $0) }
        lifeReferenceIsApproximate = selectedKind.map { dates.isApproximate(for: $0) }
            ?? false
    }

    func normalized() -> Self {
        var value = self
        value.displayName = String(
            displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(CatNameText.storedMaximumCharacters)
        )
        if let lifeDates = value.lifeDates {
            value.setLifeDates(lifeDates)
        } else if value.lifeReference == nil {
            value.lifeReferenceIsApproximate = false
        }
        value.photoAlbumLink = value.photoAlbumLink?.normalized()
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

enum CatProfileManualAssignmentPolicy {
    /// nil means the linked album already supplies the requested positive and
    /// no manual record should be created.
    static func decision(
        isSelected: Bool,
        previousDecision: CatAssetMembershipDecision?,
        isLinkedAlbumPhoto: Bool
    ) -> CatAssetMembershipDecision? {
        if isSelected {
            if isLinkedAlbumPhoto,
               previousDecision != .included,
               previousDecision != .excluded {
                return nil
            }
            return .included
        }
        if previousDecision == .excluded || isLinkedAlbumPhoto {
            return .excluded
        }
        return .unknown
    }
}

struct CatProfilePhotoAlbumRefreshResolution: Equatable, Sendable {
    var assetLocalIdentifiers: [String]
    var shouldWarnAccessIsIncomplete: Bool
}

enum CatProfilePhotoAlbumRefreshPolicy {
    /// Full Photos access is authoritative for additions and removals. Limited
    /// access is not: an omitted last-known asset may merely be unauthorized,
    /// so the safe result is a union plus an explicit warning.
    static func resolve(
        lastKnownAssetLocalIdentifiers: [String],
        accessibleAssetLocalIdentifiers: [String],
        hasLimitedPhotosAccess: Bool
    ) -> CatProfilePhotoAlbumRefreshResolution {
        let lastKnown = Set(lastKnownAssetLocalIdentifiers)
        let accessible = Set(accessibleAssetLocalIdentifiers)
        if hasLimitedPhotosAccess {
            return CatProfilePhotoAlbumRefreshResolution(
                assetLocalIdentifiers: Array(lastKnown.union(accessible)).sorted(),
                shouldWarnAccessIsIncomplete: !accessible.isSuperset(of: lastKnown)
            )
        }
        return CatProfilePhotoAlbumRefreshResolution(
            assetLocalIdentifiers: Array(accessible).sorted(),
            shouldWarnAccessIsIncomplete: false
        )
    }
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

/// 11/20: what excluding a photo from every cat took away (its per-cat
/// decisions and the cats whose key photo it was), so 「戻す」 gives it back.
/// Optional in the file: an older build ignores it and drops it on its next
/// save, which only loses the way back, never a current decision.
struct CatExclusionSetAside: Codable, Equatable, Sendable {
    var assetLocalIdentifier: String
    var memberships: [CatAssetProfileMembership]
    var keyPhotoProfileIDs: [UUID]
}

/// Durable user-owned identity state, deliberately separate from the
/// replaceable scanner snapshot. Scanner output is evidence; this file records
/// the user's household and manual many-to-many identity decisions.
struct CatHouseholdIdentityState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

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
    /// 11/20 (保存): photo decisions by iCloud Photos identity. In a saved
    /// copy, every decision this iPhone could name that way; on this iPhone,
    /// only the ones whose photos are not here yet. They are kept, and tried
    /// again, until the photo arrives. Optional: older builds ignore it.
    var portablePhotoLinks: CatPortablePhotoLinks? = nil
    /// 11/20: 旅立った日 by the same keys as `CatFarewell` (a profile's
    /// identifier or "tool-<id>"). Kept with the cats so it is saved and
    /// restored. Optional: older builds ignore it.
    var farewellDays: [String: CatFarewellDay]? = nil
    /// 11/20: kept only while the photo stays excluded (see CatExclusionSetAside).
    var exclusionSetAside: [CatExclusionSetAside]? = nil

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
        case portablePhotoLinks
        case farewellDays
        case exclusionSetAside
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
        portablePhotoLinks = try container.decodeIfPresent(
            CatPortablePhotoLinks.self,
            forKey: .portablePhotoLinks
        )
        farewellDays = try container.decodeIfPresent(
            [String: CatFarewellDay].self,
            forKey: .farewellDays
        )
        exclusionSetAside = try container.decodeIfPresent(
            [CatExclusionSetAside].self,
            forKey: .exclusionSetAside
        )
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

    /// 11/20: birthdays and adoption days saved before 11/10 on an iPhone set
    /// to 和暦 or 仏暦 hold that calendar's year. While this iPhone can still
    /// tell which day it was, they become 西暦, so a later switch to 西暦 or
    /// a restore elsewhere keeps the day. Undeterminable values stay as they are.
    func convertingDeviceCalendarYears(device: Calendar = .current) -> Self {
        var value = self
        for index in value.profiles.indices {
            var profile = value.profiles[index]
            profile.lifeReference = profile.lifeReference?.inGregorian(device: device)
            if var dates = profile.lifeDates {
                dates.birthday = dates.birthday.map { $0.inGregorian(device: device) ?? $0 }
                dates.adoptionDay = dates.adoptionDay.map { $0.inGregorian(device: device) ?? $0 }
                profile.lifeDates = dates
            }
            value.profiles[index] = profile
        }
        let legacy = value.legacyUnscoped?.lifeReference?.inGregorian(device: device)
        value.legacyUnscoped?.lifeReference = legacy
        return value
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

    /// Explicit profile membership is the union of a manual positive and the
    /// profile's linked Photos album. A manual negative always wins so a user
    /// can correct an album without editing it. Global household exclusion is
    /// still the highest-precedence decision.
    func confirmedProfileIDs(for assetLocalIdentifier: String) -> Set<UUID> {
        guard !isGloballyExcluded(assetLocalIdentifier) else { return [] }
        return Set(profiles.compactMap { profile in
            confirmsAsset(assetLocalIdentifier, for: profile.id)
                ? profile.id
                : nil
        })
    }

    /// 11/14: photos the user vouched for as a cat, whatever the stored
    /// confidence: an explicit include for any cat, a cat's key photo, or a
    /// photo in a linked Photos album. The app's own picks treat them as
    /// 確かな猫 (CatPickTier). The single-cat rule's derived photos are not
    /// in it: that rule is the app's, not the user's.
    var userVouchedAssetIdentifiers: Set<String> {
        var result = Set<String>()
        for profile in profiles {
            result.formUnion(profile.photoAlbumLink?.lastKnownAssetLocalIdentifiers ?? [])
            if let key = profile.keyPhotoLocalIdentifier { result.insert(key) }
        }
        for membership in memberships where membership.decision == .included {
            result.insert(membership.assetLocalIdentifier)
        }
        return result
    }

    func confirmedAssetIdentifiers(for profileID: UUID) -> Set<String> {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            return []
        }
        let globallyExcluded = Set(globalExcludedAssets.map(\.localIdentifier))
        let linked = Set(
            profile.photoAlbumLink?.lastKnownAssetLocalIdentifiers ?? []
        )
        let relevantManual = memberships.filter { $0.profileID == profileID }
        let manualIncluded = Set(relevantManual.lazy.filter {
            $0.decision == .included
        }.map(\.assetLocalIdentifier))
        let manualExcluded = Set(relevantManual.lazy.filter {
            $0.decision == .excluded
        }.map(\.assetLocalIdentifier))
        return linked
            .union(manualIncluded)
            .subtracting(manualExcluded)
            .subtracting(globallyExcluded)
    }

    // MARK: Single-cat rule (11/13)

    /// The household's only own cat profile (a departed cat still counts),
    /// or nil with zero or several. Family-notebook guests and tool-only cats
    /// never live in `profiles`; 11/15: but while the family notebook has a
    /// cat not linked to a cat of this iPhone, its photos may be in the
    /// library too, so the home counts as one with several cats.
    var singleCatProfileID: UUID? {
        profiles.count == 1 && !CatSingleCatRule.familyCatsOutsideProfiles ? profiles.first?.id : nil
    }

    /// 11/13: while the household has exactly one cat profile, every detected
    /// cat photo counts as that cat's photo. Nothing is persisted: the set is
    /// derived at read time, so it stops applying the moment a second profile
    /// exists and nothing has to be undone. A 「この子ではない」 (`excluded`)
    /// and a household-wide exclusion still win. With zero or several
    /// profiles this is `confirmedAssetIdentifiers(for:)` unchanged.
    func effectiveAssetIdentifiers(
        for profileID: UUID,
        detectedCatAssetIdentifiers: Set<String>
    ) -> Set<String> {
        confirmedAssetIdentifiers(for: profileID).union(
            singleCatDerivedAssetIdentifiers(
                for: profileID,
                detectedCatAssetIdentifiers: detectedCatAssetIdentifiers
            )
        )
    }

    /// The profiles one photo effectively belongs to: `confirmedProfileIDs`
    /// plus, for a detected cat photo, the only cat unless it is excluded.
    func effectiveProfileIDs(
        for assetLocalIdentifier: String,
        isDetectedCatPhoto: Bool
    ) -> Set<UUID> {
        var result = confirmedProfileIDs(for: assetLocalIdentifier)
        if let singleCatProfileID,
           isDetectedCatPhoto,
           !isGloballyExcluded(assetLocalIdentifier),
           membershipDecision(
            for: assetLocalIdentifier,
            profileID: singleCatProfileID
           ) != .excluded {
            result.insert(singleCatProfileID)
        }
        return result
    }

    /// Every profile's effective photo set, computed once per call.
    func effectiveAssetIdentifiersByProfile(
        detectedCatAssetIdentifiers: Set<String>
    ) -> [UUID: Set<String>] {
        Dictionary(uniqueKeysWithValues: profiles.map { profile in
            (profile.id, effectiveAssetIdentifiers(
                for: profile.id,
                detectedCatAssetIdentifiers: detectedCatAssetIdentifiers
            ))
        })
    }

    /// The inverse of `effectiveAssetIdentifiersByProfile`: each photo's
    /// profiles as UUID strings (the 写真 tab's cat filter). A linked album's
    /// photos count like explicit includes; photos with no cat are absent.
    static func profileIdentifiersByAsset(
        _ setsByProfile: [UUID: Set<String>]
    ) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        result.reserveCapacity(setsByProfile.values.reduce(0) { $0 + $1.count })
        for (profileID, identifiers) in setsByProfile {
            let key = profileID.uuidString
            for identifier in identifiers {
                result[identifier, default: []].insert(key)
            }
        }
        return result
    }

    /// Only the derived part of the single-cat rule: detected cat photos
    /// minus this cat's exclusions and household-wide exclusions. Empty
    /// unless `profileID` is the household's only cat profile.
    func singleCatDerivedAssetIdentifiers(
        for profileID: UUID,
        detectedCatAssetIdentifiers: Set<String>
    ) -> Set<String> {
        guard profileID == singleCatProfileID,
              !detectedCatAssetIdentifiers.isEmpty else { return [] }
        let excludedForProfile = Set(memberships.lazy.filter {
            $0.profileID == profileID && $0.decision == .excluded
        }.map(\.assetLocalIdentifier))
        let globallyExcluded = Set(globalExcludedAssets.map(\.localIdentifier))
        return detectedCatAssetIdentifiers
            .subtracting(excludedForProfile)
            .subtracting(globallyExcluded)
    }

    /// 11/13: call just before a second profile is added. Derived photos stop
    /// counting for the first cat then, so its page keeps the photo it shows:
    /// its key photo or, without one, `shownPhotoIdentifier` (the newest
    /// photo its page shows now) becomes one explicit include. Being the
    /// newest, it stays the page's photo. Nothing else is written; a photo
    /// excluded for this cat is never re-included.
    mutating func pinSingleCatPhotoBeforeAnotherProfile(
        shownPhotoIdentifier: String?,
        at date: Date = .now
    ) {
        guard let profileID = singleCatProfileID,
              let profile = profiles.first(where: { $0.id == profileID }),
              let photo = profile.keyPhotoLocalIdentifier ?? shownPhotoIdentifier,
              !confirmsAsset(photo, for: profileID),
              membershipDecision(for: photo, profileID: profileID) != .excluded else {
            return
        }
        setManualMembership(
            assetLocalIdentifier: photo,
            profileID: profileID,
            decision: .included,
            at: date
        )
    }

    /// Whether the single-cat rule alone makes `assetLocalIdentifier` this
    /// cat's photo (no explicit include, album link, or exclusion decides it).
    func isSingleCatDerivedAsset(
        _ assetLocalIdentifier: String,
        profileID: UUID,
        isDetectedCatPhoto: Bool
    ) -> Bool {
        guard isDetectedCatPhoto,
              profileID == singleCatProfileID,
              !isGloballyExcluded(assetLocalIdentifier) else { return false }
        return membershipDecision(
            for: assetLocalIdentifier,
            profileID: profileID
        ) == .unknown
    }

    func linkedPhotoAlbumContains(
        _ assetLocalIdentifier: String,
        profileID: UUID
    ) -> Bool {
        profiles.first(where: { $0.id == profileID })?
            .photoAlbumLink?
            .lastKnownAssetLocalIdentifiers
            .contains(assetLocalIdentifier) == true
    }

    func confirmsAsset(
        _ assetLocalIdentifier: String,
        for profileID: UUID
    ) -> Bool {
        guard !isGloballyExcluded(assetLocalIdentifier) else { return false }
        switch membershipDecision(
            for: assetLocalIdentifier,
            profileID: profileID
        ) {
        case .included:
            return true
        case .excluded:
            return false
        case .unknown:
            return linkedPhotoAlbumContains(
                assetLocalIdentifier,
                profileID: profileID
            )
        }
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
        let removedCatPhotos = confirmedAssetIdentifiers(for: id)
        profiles.removeAll { $0.id == id }
        memberships.removeAll { $0.profileID == id }
        guard profiles.count != previousCount else { return }
        // 11/20: with one cat left, the single-cat rule would make every
        // detected photo hers, including the deleted cat's. Those photos get
        // her 「この子ではない」 instead; she can still be given one by hand.
        memberships.append(contentsOf: Self.membershipsKeepingApart(
            removedCatPhotos,
            // Not `singleCatProfileID`: the family-notebook pause of the rule
            // can end later, and the photos must stay apart then too.
            from: profiles.count == 1 ? profiles.first?.id : nil,
            in: self,
            at: date
        ))
        mode = .profiled
        updatedAt = max(updatedAt, max(createdAt, date))
        self = normalized()
    }

    /// The 「この子ではない」 decisions that keep a deleted cat's photos off
    /// the only remaining cat (11/20). A photo she already has a decision
    /// for, or that her linked album holds, is left as it is.
    static func membershipsKeepingApart(
        _ removedCatPhotos: Set<String>,
        from remainingProfileID: UUID?,
        in state: CatHouseholdIdentityState,
        at date: Date
    ) -> [CatAssetProfileMembership] {
        guard let remainingProfileID, !removedCatPhotos.isEmpty else { return [] }
        let decided = Set(state.memberships.lazy
            .filter { $0.profileID == remainingProfileID }
            .map(\.assetLocalIdentifier))
        let remaining = state.profiles.first { $0.id == remainingProfileID }
        let linked = Set(remaining?.photoAlbumLink?.lastKnownAssetLocalIdentifiers ?? [])
        let globallyExcluded = Set(state.globalExcludedAssets.map(\.localIdentifier))
        return removedCatPhotos
            .subtracting(decided)
            .subtracting(linked)
            .subtracting(globallyExcluded)
            .sorted()
            .map {
                CatAssetProfileMembership(
                    assetLocalIdentifier: $0,
                    profileID: remainingProfileID,
                    decision: .excluded,
                    subjectBoundingBox: nil,
                    isSimilarityReference: false,
                    decidedAt: date
                )
            }
    }

    /// Selecting a cover never creates identity membership. Temporary Photos
    /// unavailability does not clear the persisted, confirmed choice.
    mutating func setProfileKeyPhoto(
        profileID: UUID,
        assetLocalIdentifier: String?,
        at date: Date = .now
    ) {
        guard var profile = profiles.first(where: { $0.id == profileID }) else {
            return
        }
        if let assetLocalIdentifier {
            guard Self.isValidLocalIdentifier(assetLocalIdentifier),
                  confirmsAsset(assetLocalIdentifier, for: profileID) else { return }
        }
        guard profile.keyPhotoLocalIdentifier != assetLocalIdentifier else { return }
        profile.keyPhotoLocalIdentifier = assetLocalIdentifier
        upsertProfile(profile, at: date)
    }

    mutating func setProfilePhotoAlbumLink(
        profileID: UUID,
        localIdentifier: String?,
        assetLocalIdentifiers: [String] = [],
        at date: Date = .now
    ) {
        guard var profile = profiles.first(where: { $0.id == profileID }) else {
            return
        }
        if let localIdentifier {
            profile.photoAlbumLink = CatProfilePhotoAlbumLink(
                localIdentifier: localIdentifier,
                lastKnownAssetLocalIdentifiers: assetLocalIdentifiers,
                linkedAt: date,
                refreshedAt: date
            ).normalized()
            guard profile.photoAlbumLink != nil else { return }
        } else {
            profile.photoAlbumLink = nil
        }
        upsertProfile(profile, at: date)
    }

    /// Refreshes membership only while the same album remains linked. This is
    /// safe when a PhotoKit read races with a later user selection.
    mutating func refreshProfilePhotoAlbumLink(
        profileID: UUID,
        localIdentifier: String,
        assetLocalIdentifiers: [String],
        at date: Date = .now
    ) {
        guard var profile = profiles.first(where: { $0.id == profileID }),
              var link = profile.photoAlbumLink,
              link.localIdentifier == localIdentifier else { return }
        let normalizedIdentifiers = Array(Set(
            assetLocalIdentifiers.filter { identifier in
                !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && identifier.utf8.count <= 4_096
            }
        )).sorted()
        guard link.lastKnownAssetLocalIdentifiers != normalizedIdentifiers else {
            return
        }
        link.lastKnownAssetLocalIdentifiers = normalizedIdentifiers
        link.refreshedAt = date
        profile.photoAlbumLink = link.normalized()
        upsertProfile(profile, at: date)
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

    /// A global exclusion removes all manual per-profile decisions for that
    /// photo. 11/20: they are set aside with it, and restoring the photo
    /// gives them back (a decision made since wins), with the key photo of a
    /// cat that has not chosen another. A still-linked Photos album may
    /// explicitly include it again for that profile.
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
            let newlyExcluded = identifiers.filter { identifier in
                !previous.contains { $0.localIdentifier == identifier }
            }
            var setAside = (exclusionSetAside ?? []).filter { !newlyExcluded.contains($0.assetLocalIdentifier) }
            for identifier in newlyExcluded.sorted() {
                let removed = memberships.filter { $0.assetLocalIdentifier == identifier }
                let keyPhotos = profiles.filter { $0.keyPhotoLocalIdentifier == identifier }.map(\.id)
                guard !removed.isEmpty || !keyPhotos.isEmpty else { continue }
                setAside.append(CatExclusionSetAside(assetLocalIdentifier: identifier,
                    memberships: removed, keyPhotoProfileIDs: keyPhotos))
            }
            exclusionSetAside = setAside.isEmpty ? nil : setAside
            globalExcludedAssets = Array(byIdentifier.values)
            memberships.removeAll { identifiers.contains($0.assetLocalIdentifier) }
        } else {
            globalExcludedAssets.removeAll { identifiers.contains($0.localIdentifier) }
            for saved in exclusionSetAside ?? [] where identifiers.contains(saved.assetLocalIdentifier) {
                for membership in saved.memberships where !memberships.contains(where: {
                    $0.assetLocalIdentifier == membership.assetLocalIdentifier && $0.profileID == membership.profileID
                }) {
                    memberships.append(membership)
                }
                for profileID in saved.keyPhotoProfileIDs {
                    guard let index = profiles.firstIndex(where: { $0.id == profileID }),
                          profiles[index].keyPhotoLocalIdentifier == nil else { continue }
                    profiles[index].keyPhotoLocalIdentifier = saved.assetLocalIdentifier
                }
            }
            let remaining = (exclusionSetAside ?? []).filter { !identifiers.contains($0.assetLocalIdentifier) }
            exclusionSetAside = remaining.isEmpty ? nil : remaining
        }
        guard globalExcludedAssets != previous else { return }
        updatedAt = max(updatedAt, max(createdAt, date))
        self = normalized()
    }

    func normalized() -> Self {
        let sourceSchemaVersion = schemaVersion
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

        for index in value.profiles.indices {
            let profile = value.profiles[index]
            if let identifier = profile.keyPhotoLocalIdentifier,
               !Self.isValidLocalIdentifier(identifier)
                || !value.confirmsAsset(identifier, for: profile.id) {
                value.profiles[index].keyPhotoLocalIdentifier = nil
            }
        }

        // Build 14 created a profile and its explicitly selected first photo
        // in the same second, but accidentally persisted the anchor flag as
        // false. Upgrade only the uniquely identifiable case. Ambiguous older
        // profiles remain without an anchor and must be selected by the user;
        // a model suggestion is never promoted here.
        if sourceSchemaVersion < 2 {
            for profile in value.profiles {
                let profileMembershipIndices = value.memberships.indices.filter {
                    let membership = value.memberships[$0]
                    return membership.profileID == profile.id
                        && membership.decision == .included
                }
                guard !profileMembershipIndices.contains(where: {
                    value.memberships[$0].isSimilarityReference
                }) else { continue }
                let inferred = profileMembershipIndices.filter {
                    let membership = value.memberships[$0]
                    return membership.subjectBoundingBox != nil
                        && membership.decidedAt == profile.createdAt
                }
                if inferred.count == 1 {
                    value.memberships[inferred[0]].isSimilarityReference = true
                }
            }
        }

        // 11/20: what an exclusion set aside lives only while it stands.
        var setAsideByIdentifier: [String: CatExclusionSetAside] = [:]
        for saved in value.exclusionSetAside ?? []
        where globallyExcluded.contains(saved.assetLocalIdentifier) {
            var entry = saved
            entry.memberships = saved.memberships.filter {
                $0.assetLocalIdentifier == saved.assetLocalIdentifier && validProfileIDs.contains($0.profileID)
            }
            entry.keyPhotoProfileIDs = Array(Set(saved.keyPhotoProfileIDs.filter { validProfileIDs.contains($0) }))
                .sorted { $0.uuidString < $1.uuidString }
            guard !entry.memberships.isEmpty || !entry.keyPhotoProfileIDs.isEmpty else { continue }
            setAsideByIdentifier[saved.assetLocalIdentifier] = entry
        }
        value.exclusionSetAside = setAsideByIdentifier.isEmpty ? nil
            : setAsideByIdentifier.values.sorted { $0.assetLocalIdentifier < $1.assetLocalIdentifier }

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
        value.portablePhotoLinks = value.portablePhotoLinks?.normalized(
            profileIDs: validProfileIDs
        )
        value.farewellDays = CatFarewellDay.normalized(value.farewellDays)
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
/// 11/14: `confirmedProfileIDs(for:)` for a whole library. The ledger's own
/// lookups search arrays (exclusions, decisions, a linked album's photos)
/// once per photo and per cat; on 10,000 photos that was the slowest part of
/// every Widget authority sync after launch. Built once, each photo is then
/// a few set lookups. Same answers: the first decision for a (photo, cat)
/// pair wins, a household exclusion wins over everything, a linked album
/// counts only without a decision.
struct CatProfileConfirmationIndex: Sendable {
    private let excluded: Set<String>
    private let profileIDs: [UUID]
    private let decisions: [UUID: [String: CatAssetMembershipDecision]]
    private let linked: [UUID: Set<String>]

    init(_ state: CatHouseholdIdentityState) {
        excluded = Set(state.globalExcludedAssets.map(\.localIdentifier))
        profileIDs = state.profiles.map(\.id)
        var linked: [UUID: Set<String>] = [:]
        for profile in state.profiles where linked[profile.id] == nil {
            linked[profile.id] = Set(profile.photoAlbumLink?.lastKnownAssetLocalIdentifiers ?? [])
        }
        self.linked = linked
        var decisions: [UUID: [String: CatAssetMembershipDecision]] = [:]
        for membership in state.memberships
        where decisions[membership.profileID]?[membership.assetLocalIdentifier] == nil {
            decisions[membership.profileID, default: [:]][membership.assetLocalIdentifier] = membership.decision
        }
        self.decisions = decisions
    }

    func confirmedProfileIDs(for assetLocalIdentifier: String) -> Set<UUID> {
        guard !excluded.contains(assetLocalIdentifier) else { return [] }
        var result = Set<UUID>()
        for id in profileIDs {
            switch decisions[id]?[assetLocalIdentifier] ?? .unknown {
            case .included:
                result.insert(id)
            case .excluded:
                continue
            case .unknown:
                if linked[id]?.contains(assetLocalIdentifier) == true { result.insert(id) }
            }
        }
        return result
    }
}

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

// MARK: - Limits on cats and names (11/14)

/// At most 10 living cat profiles. A profile whose farewell day is recorded
/// does not count; a cat written only in a tool or the family notebook is not
/// a profile. Existing data with more keeps working: only adding stops.
enum CatProfileLimit {
    static let maximumLiving = 10

    /// The cats that count: every identifier that is not departed. A nil
    /// identifier (a tool cat without a profile) counts as one cat in a tool.
    static func livingCount(_ identifiers: [String?], departed: Set<String>) -> Int {
        identifiers.filter { $0.map { !departed.contains($0) } ?? true }.count
    }

    static func canAdd(_ identifiers: [String?], departed: Set<String>) -> Bool {
        livingCount(identifiers, departed: departed) < maximumLiving
    }

    /// The profiles that exist now, set by the app whenever they change;
    /// nil until they are read. Like CatSingleCatRule, never saved.
    static var knownProfiles: Set<String>?

    /// 11/20: a tool's cats. One whose profile was deleted keeps its records
    /// and stays in the tool's list (the delete says 「ツールの記録は残ります」),
    /// but it is no longer a cat of the household and takes no place. A cat
    /// without a profile still counts; with profiles unknown, every one does.
    static func canAddToolCat(_ identifiers: [String?], departed: Set<String>,
                              profiles: Set<String>? = CatProfileLimit.knownProfiles) -> Bool {
        guard let profiles else { return canAdd(identifiers, departed: departed) }
        let known = Set(profiles.map { $0.lowercased() })
        return canAdd(identifiers.filter { $0.map { known.contains($0.lowercased()) } ?? true }, departed: departed)
    }

    /// Profile identifiers (never nil).
    static func livingCount(_ identifiers: [String], departed: Set<String>) -> Int {
        livingCount(identifiers.map { Optional($0) }, departed: departed)
    }

    static func canAdd(_ identifiers: [String], departed: Set<String>) -> Bool {
        canAdd(identifiers.map { Optional($0) }, departed: departed)
    }

    static func room(existing identifiers: [String], departed: Set<String>) -> Int {
        room(existing: identifiers.map { Optional($0) }, departed: departed)
    }

    /// Profiles first, in their order, up to the limit, counting only the
    /// living ones already there. Used where a file brings in many at once.
    static func room(existing identifiers: [String?], departed: Set<String>) -> Int {
        max(0, maximumLiving - livingCount(identifiers, departed: departed))
    }
}

/// What a person types as a name: no control, zero-width, bidi-control
/// characters or line breaks, and no spaces at either end once saved.
/// Emoji joined with a zero-width joiner stay one character.
enum VisibleText {
    static func cleaned(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var output = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar.value == 0x200D {
                // Keep a joiner only inside an emoji sequence (👨‍👩‍👧, 🏳️‍🌈).
                let next = index + 1 < scalars.count ? scalars[index + 1] : nil
                if let previous = output.last, previous.value == 0xFE0F || isEmojiLike(previous),
                   let next, isEmojiLike(next) {
                    output.append(scalar)
                }
                continue
            }
            if isInvisible(scalar) { continue }
            output.append(scalar)
        }
        return String(output)
    }

    /// Cleaned, with leading and trailing spaces (also full-width) removed.
    static func finalized(_ value: String) -> String {
        cleaned(value).trimmingCharacters(in: .whitespaces)
    }

    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: return true // controls, line breaks, tabs
        case 0x00AD, 0x061C, 0x180E: return true
        case 0x200B, 0x200C, 0x200E, 0x200F: return true
        case 0x2028...0x202E: return true // line/paragraph separators, bidi embedding
        case 0x2060...0x2064, 0x2066...0x2069: return true // word joiner, bidi isolates
        case 0xFEFF: return true
        default: return false
        }
    }

    /// Pictographs and symbols an emoji sequence joins (🐈‍⬛ ends in U+2B1B).
    /// Ranges, not Unicode properties, so the older macOS checks compile too.
    private static func isEmojiLike(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1F000...0x1FAFF, 0x2190...0x2BFF, 0x00A9, 0x00AE, 0x203C, 0x2049,
             0x2122, 0x2139, 0x3030, 0x303D, 0x3297, 0x3299: return true
        default: return false
        }
    }
}

/// A field that stops at its limit while typing or pasting, instead of
/// cutting text afterwards. Only newly inserted characters are filtered and
/// counted: a value already longer than the limit is shown as it is and can
/// be shortened, never grown.
enum TextInputGate {
    static func accept(_ proposed: String, previous: String, limit: Int,
                       allow: (Character) -> Bool = { _ in true }) -> String {
        let old = Array(previous), new = Array(proposed)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let kept = prefix + suffix
        let room = max(0, max(limit, kept) - kept)
        let inserted = new[prefix..<(new.count - suffix)].filter(allow).prefix(room)
        return String(new[..<prefix]) + String(inserted) + String(new[(new.count - suffix)...])
    }
}

/// One rule for a cat's name wherever it is written (the profile and
/// 「この子のこと」): 20 characters as people count them (an emoji is one).
/// Names saved before 11/14 may be longer (up to 80); they are kept.
enum CatNameText {
    static let maximumCharacters = 20
    /// What older builds allowed and stored; reading never cuts below this.
    static let storedMaximumCharacters = 80

    /// For a TextField binding: cleaned, and stops at 20.
    static func accept(_ proposed: String, previous: String) -> String {
        TextInputGate.accept(VisibleText.cleaned(proposed), previous: previous, limit: maximumCharacters)
    }

    /// What is saved; nil when nothing is left after cleaning.
    static func saving(_ value: String) -> String? {
        let name = VisibleText.finalized(value)
        return name.isEmpty ? nil : name
    }

    /// The model's rule for a name typed or imported now (11/20), so the
    /// limit does not depend on the text field: cleaned, at most 20
    /// characters as people count them. A name saved earlier with more keeps
    /// that length while it is being edited (it only gets shorter); stored
    /// names are never cut when they load.
    static func savingInput(_ value: String, previous: String? = nil) -> String? {
        guard let name = saving(value) else { return nil }
        let allowance = max(
            maximumCharacters,
            min(previous?.count ?? 0, storedMaximumCharacters)
        )
        return String(name.prefix(allowance))
    }
}

// MARK: - What 保存 carries of photo decisions (11/20)

/// The household's photo decisions in a form another iPhone of the same
/// person can read: 「この子に分けた写真」, 「この子ではない」, household-wide
/// exclusions, key photos, linked albums and liked photos. A photo is named
/// only by its iCloud Photos identifier (PHCloudIdentifier), which means
/// nothing outside the owner's own library; a cat by its random profile UUID.
/// No pixels, PhotoKit local identifiers, names or photo dates are written.
/// Each photo identifier is written once and referred to by its position.
///
/// It travels inside the encrypted CatIdentity record. Older builds skip the
/// unknown key, and every field decodes with a default, so neither direction
/// fails to read the other.
struct CatPortablePhotoLinks: Codable, Equatable, Sendable {
    static let currentVersion = 1

    struct Membership: Codable, Equatable, Sendable {
        var asset: Int
        var profile: Int
        /// A raw value, so a decision a later build adds never stops reading.
        var decision: String
        var box: NormalizedRect?
        var reference: Bool?
        var decidedAt: Date
        private enum CodingKeys: String, CodingKey {
            case asset = "a", profile = "p", decision = "d", box = "b", reference = "r", decidedAt = "t"
        }
    }

    struct Exclusion: Codable, Equatable, Sendable {
        var asset: Int
        var excludedAt: Date
        private enum CodingKeys: String, CodingKey { case asset = "a", excludedAt = "t" }
    }

    struct KeyPhoto: Codable, Equatable, Sendable {
        var profile: Int
        var asset: Int
        private enum CodingKeys: String, CodingKey { case profile = "p", asset = "a" }
    }

    struct Album: Codable, Equatable, Sendable {
        var profile: Int
        /// The album's iCloud Photos identifier.
        var album: String
        var assets: [Int]
        var linkedAt: Date
        private enum CodingKeys: String, CodingKey {
            case profile = "p", album = "c", assets = "a", linkedAt = "t"
        }
    }

    struct Like: Codable, Equatable, Sendable {
        var asset: Int
        var likedAt: Date
        private enum CodingKeys: String, CodingKey { case asset = "a", likedAt = "t" }
    }

    var version: Int
    var assets: [String]
    var profiles: [UUID]
    var memberships: [Membership]
    var exclusions: [Exclusion]
    var keyPhotos: [KeyPhoto]
    var albums: [Album]
    var likes: [Like]

    private enum CodingKeys: String, CodingKey {
        case version, assets, profiles, memberships, exclusions, keyPhotos, albums, likes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        assets = try container.decodeIfPresent([String].self, forKey: .assets) ?? []
        profiles = try container.decodeIfPresent([UUID].self, forKey: .profiles) ?? []
        memberships = try container.decodeIfPresent([Membership].self, forKey: .memberships) ?? []
        exclusions = try container.decodeIfPresent([Exclusion].self, forKey: .exclusions) ?? []
        keyPhotos = try container.decodeIfPresent([KeyPhoto].self, forKey: .keyPhotos) ?? []
        albums = try container.decodeIfPresent([Album].self, forKey: .albums) ?? []
        likes = try container.decodeIfPresent([Like].self, forKey: .likes) ?? []
    }

    /// The same content keyed by identifiers. Order-free, so merging and
    /// comparing never depend on table positions.
    struct Expanded: Equatable, Sendable {
        struct Key: Hashable, Sendable { var asset: String; var profile: UUID }
        struct Decision: Equatable, Sendable {
            var decision: CatAssetMembershipDecision
            var box: NormalizedRect?
            var reference: Bool
            var decidedAt: Date
        }
        struct LinkedAlbum: Equatable, Sendable {
            var album: String
            var assets: Set<String>
            var linkedAt: Date
        }
        var memberships: [Key: Decision] = [:]
        var exclusions: [String: Date] = [:]
        var keyPhotos: [UUID: String] = [:]
        var albums: [UUID: LinkedAlbum] = [:]
        var likes: [String: Date] = [:]

        var isEmpty: Bool {
            memberships.isEmpty && exclusions.isEmpty && keyPhotos.isEmpty && albums.isEmpty && likes.isEmpty
        }

        /// `self` wins every conflict; an exclusion keeps its earliest day.
        func merging(_ other: Expanded) -> Expanded {
            var result = self
            result.memberships.merge(other.memberships) { mine, _ in mine }
            result.exclusions.merge(other.exclusions) { min($0, $1) }
            result.keyPhotos.merge(other.keyPhotos) { mine, _ in mine }
            result.albums.merge(other.albums) { mine, _ in mine }
            result.likes.merge(other.likes) { mine, _ in mine }
            return result
        }
    }

    init?(_ expanded: Expanded) {
        guard !expanded.isEmpty else { return nil }
        var assetSet = Set<String>()
        assetSet.formUnion(expanded.memberships.keys.map(\.asset))
        assetSet.formUnion(expanded.exclusions.keys)
        assetSet.formUnion(expanded.keyPhotos.values)
        for album in expanded.albums.values { assetSet.formUnion(album.assets) }
        assetSet.formUnion(expanded.likes.keys)
        var profileSet = Set<UUID>(expanded.memberships.keys.map(\.profile))
        profileSet.formUnion(expanded.keyPhotos.keys)
        profileSet.formUnion(expanded.albums.keys)
        let assets = assetSet.sorted()
        let profiles = profileSet.sorted { $0.uuidString < $1.uuidString }
        var assetIndex: [String: Int] = [:]
        for (index, asset) in assets.enumerated() { assetIndex[asset] = index }
        var profileIndex: [UUID: Int] = [:]
        for (index, profile) in profiles.enumerated() { profileIndex[profile] = index }
        version = Self.currentVersion
        self.assets = assets
        self.profiles = profiles
        memberships = expanded.memberships.map { key, value in
            Membership(asset: assetIndex[key.asset]!, profile: profileIndex[key.profile]!,
                       decision: value.decision.rawValue, box: value.box,
                       reference: value.reference ? true : nil, decidedAt: value.decidedAt)
        }.sorted { $0.asset != $1.asset ? $0.asset < $1.asset : $0.profile < $1.profile }
        exclusions = expanded.exclusions.map { Exclusion(asset: assetIndex[$0.key]!, excludedAt: $0.value) }
            .sorted { $0.asset < $1.asset }
        keyPhotos = expanded.keyPhotos.map { KeyPhoto(profile: profileIndex[$0.key]!, asset: assetIndex[$0.value]!) }
            .sorted { $0.profile < $1.profile }
        albums = expanded.albums.map { profile, value in
            Album(profile: profileIndex[profile]!, album: value.album,
                  assets: value.assets.map { assetIndex[$0]! }.sorted(), linkedAt: value.linkedAt)
        }.sorted { $0.profile < $1.profile }
        likes = expanded.likes.map { Like(asset: assetIndex[$0.key]!, likedAt: $0.value) }
            .sorted { $0.asset < $1.asset }
    }

    /// Entries naming a position that does not exist, or an identifier that
    /// is empty or too long, are not read. Nothing else is guessed.
    func expanded() -> Expanded {
        func asset(_ index: Int) -> String? {
            guard assets.indices.contains(index), Self.isValidIdentifier(assets[index]) else { return nil }
            return assets[index]
        }
        func profile(_ index: Int) -> UUID? { profiles.indices.contains(index) ? profiles[index] : nil }
        var result = Expanded()
        for item in memberships {
            guard let a = asset(item.asset), let p = profile(item.profile),
                  let decision = CatAssetMembershipDecision(rawValue: item.decision) else { continue }
            let key = Expanded.Key(asset: a, profile: p)
            let value = Expanded.Decision(decision: decision, box: item.box,
                                          reference: item.reference == true, decidedAt: item.decidedAt)
            if let previous = result.memberships[key], previous.decidedAt >= value.decidedAt { continue }
            result.memberships[key] = value
        }
        for item in exclusions {
            guard let a = asset(item.asset) else { continue }
            result.exclusions[a] = min(result.exclusions[a] ?? item.excludedAt, item.excludedAt)
        }
        for item in keyPhotos {
            guard let a = asset(item.asset), let p = profile(item.profile) else { continue }
            result.keyPhotos[p] = a
        }
        for item in albums {
            guard let p = profile(item.profile), Self.isValidIdentifier(item.album) else { continue }
            result.albums[p] = .init(album: item.album, assets: Set(item.assets.compactMap(asset)), linkedAt: item.linkedAt)
        }
        for item in likes {
            guard let a = asset(item.asset) else { continue }
            result.likes[a] = max(result.likes[a] ?? item.likedAt, item.likedAt)
        }
        return result
    }

    /// The canonical form, limited to cats that exist. Nil when nothing is left.
    func normalized(profileIDs: Set<UUID>) -> Self? {
        var value = expanded()
        let excluded = value.exclusions
        value.memberships = value.memberships.filter {
            profileIDs.contains($0.key.profile) && excluded[$0.key.asset] == nil
        }
        for (key, decision) in value.memberships {
            var item = decision
            item.decidedAt = Self.second(item.decidedAt)
            if item.decision == .included {
                item.box = Self.validBox(item.box)
            } else {
                item.box = nil
                item.reference = false
            }
            value.memberships[key] = item
        }
        value.exclusions = value.exclusions.mapValues(Self.second)
        value.keyPhotos = value.keyPhotos.filter { profileIDs.contains($0.key) }
        value.albums = value.albums.filter { profileIDs.contains($0.key) }.mapValues { input in
            var album = input
            album.linkedAt = Self.second(album.linkedAt)
            return album
        }
        value.likes = value.likes.mapValues(Self.second)
        return Self(value)
    }

    /// Every iCloud Photos identifier of a photo, in table order.
    var assetIdentifiers: [String] { assets.filter(Self.isValidIdentifier) }
    var albumIdentifiers: [String] { Array(Set(albums.map(\.album).filter(Self.isValidIdentifier))).sorted() }

    /// Both sides' decisions; `preferred` wins a conflict.
    static func merged(_ preferred: Self?, _ other: Self?, profileIDs: Set<UUID>) -> Self? {
        let value = (preferred?.expanded() ?? Expanded()).merging(other?.expanded() ?? Expanded())
        return Self(value)?.normalized(profileIDs: profileIDs)
    }

    /// The saved form of this iPhone's decisions. `cloud` maps a PhotoKit local
    /// identifier to its iCloud Photos identifier, `albumCloud` the same for a
    /// linked album, and `likes` is this iPhone's liked photos by local
    /// identifier. A photo without an iCloud identifier cannot be named on
    /// another iPhone and is left out. `state.portablePhotoLinks` (decisions
    /// still waiting for their photo here) is carried on; this iPhone's own
    /// decisions win a conflict.
    static func capturing(_ state: CatHouseholdIdentityState, likes: [String: Date],
                          cloud: [String: String], albumCloud: [String: String]) -> Self? {
        var value = Expanded()
        for membership in state.memberships {
            guard let asset = cloud[membership.assetLocalIdentifier] else { continue }
            value.memberships[.init(asset: asset, profile: membership.profileID)] = .init(
                decision: membership.decision, box: membership.subjectBoundingBox,
                reference: membership.isSimilarityReference, decidedAt: membership.decidedAt)
        }
        for exclusion in state.globalExcludedAssets {
            guard let asset = cloud[exclusion.localIdentifier] else { continue }
            value.exclusions[asset] = min(value.exclusions[asset] ?? exclusion.excludedAt, exclusion.excludedAt)
        }
        for profile in state.profiles {
            if let key = profile.keyPhotoLocalIdentifier, let asset = cloud[key] { value.keyPhotos[profile.id] = asset }
            if let link = profile.photoAlbumLink, let album = albumCloud[link.localIdentifier] {
                value.albums[profile.id] = .init(album: album,
                    assets: Set(link.lastKnownAssetLocalIdentifiers.compactMap { cloud[$0] }), linkedAt: link.linkedAt)
            }
        }
        for (local, likedAt) in likes {
            guard let asset = cloud[local] else { continue }
            value.likes[asset] = max(value.likes[asset] ?? likedAt, likedAt)
        }
        // A profile with a key photo or an album here keeps its own choice.
        var waiting = state.portablePhotoLinks?.expanded() ?? Expanded()
        for profile in state.profiles {
            if profile.keyPhotoLocalIdentifier != nil { waiting.keyPhotos[profile.id] = nil }
            if profile.photoAlbumLink != nil { waiting.albums[profile.id] = nil }
        }
        return Self(value.merging(waiting))?.normalized(profileIDs: Set(state.profiles.map(\.id)))
    }

    /// Applies what can be named on this iPhone now (`assets`, `albums`: iCloud
    /// identifier to local identifier, only for items present in the library)
    /// and keeps everything else in `portablePhotoLinks` for a later try.
    /// This iPhone's own decisions win: an existing decision for the same photo
    /// and cat, an existing key photo or album link, a later local decision
    /// over a saved exclusion. Liked photos are not applied here; they stay
    /// until `takingLikes` hands them to the like store.
    static func applying(_ links: Self?, to state: CatHouseholdIdentityState,
                         assets: [String: String], albums: [String: String]) -> CatHouseholdIdentityState {
        guard let links else { return state }
        let saved = links.expanded()
        var result = state
        result.portablePhotoLinks = nil
        var rest = Expanded()
        rest.likes = saved.likes
        let profileIDs = Set(result.profiles.map(\.id))

        for (asset, excludedAt) in saved.exclusions {
            guard let local = assets[asset] else { rest.exclusions[asset] = excludedAt; continue }
            if result.isGloballyExcluded(local) { continue }
            if result.memberships.contains(where: { $0.assetLocalIdentifier == local && $0.decidedAt > excludedAt }) { continue }
            result.globalExcludedAssets.append(ExcludedCatAsset(localIdentifier: local, excludedAt: excludedAt))
            result.memberships.removeAll { $0.assetLocalIdentifier == local }
        }
        for (key, decision) in saved.memberships where profileIDs.contains(key.profile) {
            guard let local = assets[key.asset] else { rest.memberships[key] = decision; continue }
            if result.isGloballyExcluded(local) || result.membership(for: local, profileID: key.profile) != nil { continue }
            result.memberships.append(CatAssetProfileMembership(
                assetLocalIdentifier: local, profileID: key.profile, decision: decision.decision,
                subjectBoundingBox: decision.box, isSimilarityReference: decision.reference,
                decidedAt: decision.decidedAt))
        }
        for (profileID, album) in saved.albums {
            guard let index = result.profiles.firstIndex(where: { $0.id == profileID }),
                  result.profiles[index].photoAlbumLink == nil else { continue }
            guard let local = albums[album.album] else { rest.albums[profileID] = album; continue }
            result.profiles[index].photoAlbumLink = CatProfilePhotoAlbumLink(
                localIdentifier: local,
                lastKnownAssetLocalIdentifiers: album.assets.compactMap { assets[$0] },
                linkedAt: album.linkedAt, refreshedAt: album.linkedAt).normalized()
        }
        for (profileID, asset) in saved.keyPhotos {
            guard let index = result.profiles.firstIndex(where: { $0.id == profileID }),
                  result.profiles[index].keyPhotoLocalIdentifier == nil else { continue }
            guard let local = assets[asset] else { rest.keyPhotos[profileID] = asset; continue }
            if result.confirmsAsset(local, for: profileID) {
                result.profiles[index].keyPhotoLocalIdentifier = local
            } else if rest.memberships[.init(asset: asset, profile: profileID)] != nil || rest.albums[profileID] != nil {
                // Its decision or album is still waiting; try again with it.
                rest.keyPhotos[profileID] = asset
            }
        }
        result.portablePhotoLinks = Self(rest)
        return result.normalized()
    }

    /// Liked photos that can be named here now, by local identifier, and the
    /// links without them. The caller keeps the original links until the
    /// like store has accepted them.
    static func takingLikes(_ links: Self?, assets: [String: String]) -> (likes: [String: Date], remaining: Self?) {
        guard let links else { return ([:], nil) }
        var value = links.expanded()
        var likes: [String: Date] = [:]
        for (asset, likedAt) in value.likes {
            guard let local = assets[asset] else { continue }
            likes[local] = max(likes[local] ?? likedAt, likedAt)
            value.likes[asset] = nil
        }
        return (likes, Self(value))
    }

    private static func second(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 4_096
    }

    private static func validBox(_ value: NormalizedRect?) -> NormalizedRect? {
        guard let value, value.x.isFinite, value.y.isFinite, value.width.isFinite, value.height.isFinite,
              value.x >= 0, value.y >= 0, value.width > 0, value.height > 0,
              value.x + value.width <= 1, value.y + value.height <= 1 else { return nil }
        return value
    }
}

// MARK: - 旅立った日 with the cat's record (11/20)

/// The same JSON shape as `CatCareDay` ({"year","month","day"}), so the
/// iPhone's copy in UserDefaults and the record read each other directly.
struct CatFarewellDay: Codable, Equatable, Hashable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    var isValid: Bool {
        (1900...2200).contains(year) && (1...12).contains(month) && (1...31).contains(day)
    }

    static func normalized(_ days: [String: CatFarewellDay]?) -> [String: CatFarewellDay]? {
        guard let days else { return nil }
        let kept = days.filter { !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.isValid }
        return kept.isEmpty ? nil : kept
    }

    /// Reads the UserDefaults text entry by entry: one unreadable entry does
    /// not hide the others. Nil only when the text is not a JSON object at
    /// all; an empty text is an empty record.
    static func decodeAll(_ json: String) -> [String: CatFarewellDay]? {
        if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        var result: [String: CatFarewellDay] = [:]
        for (key, value) in object {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let day = try? JSONDecoder().decode(CatFarewellDay.self, from: data), day.isValid else { continue }
            result[key] = day
        }
        return result
    }

    /// `days` as UserDefaults text. Entries of `json` that `decodeAll` could
    /// not read are kept as they were, unless `days` names the same key.
    static func encodeAll(_ days: [String: CatFarewellDay], keepingUnreadableFrom json: String) -> String {
        var object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        for key in (decodeAll(json) ?? [:]).keys { object[key] = nil }
        for (key, day) in days { object[key] = ["year": day.year, "month": day.month, "day": day.day] }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return json }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Keeps the iPhone's copy (UserDefaults, read by every screen) and the
/// record's copy (saved and restored) the same. `mirrored` is what both last
/// agreed on. A change on the iPhone since then wins for the days it touched
/// (also a removal); everything else comes from the record, so a restored
/// day reaches the screens. Before the first agreement nothing is removed:
/// the iPhone's days are added to the record's.
enum CatFarewellMirror {
    struct Outcome: Equatable {
        var agreed: [String: CatFarewellDay]
        var writesUser: Bool
        var writesRecord: Bool
    }

    static func reconcile(user: [String: CatFarewellDay], mirrored: [String: CatFarewellDay]?,
                          record: [String: CatFarewellDay]) -> Outcome {
        var agreed = record
        let base = mirrored ?? [:]
        for key in Set(base.keys).union(user.keys) where base[key] != user[key] {
            agreed[key] = user[key]
        }
        return Outcome(agreed: agreed, writesUser: agreed != user, writesRecord: agreed != record)
    }
}
