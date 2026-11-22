import Foundation

// Standalone macOS invocation (kept out of workflow until the new source files
// are added to the Xcode targets):
// xcrun --sdk macosx swiftc -parse-as-library \
//   Shared/Models/AppSettings.swift Shared/Models/NormalizedRect.swift \
//   Shared/Models/CatCandidateCuration.swift \
//   Shared/Models/CatHouseholdIdentity.swift Shared/Models/NekoWidgetError.swift \
//   Shared/Models/WidgetRenderPlan.swift Shared/Models/WidgetManifest.swift \
//   Shared/AppGroup/SharedContainer.swift \
//   NekoWidget/Services/CatHouseholdIdentityStore.swift \
//   ci/verify-cat-household-identity.swift -o /tmp/verify-cat-household-identity

@main
enum CatHouseholdIdentityVerifier {
    static func main() async throws {
        try verifiesLegacyMigrationIsUnscopedAndIdempotent()
        try verifiesStaleLegacyMirrorCannotUndoIdentityDecision()
        try verifiesManyToManyManualMembership()
        try verifiesProfileAlbumMembershipPrecedence()
        try verifiesBuild14ReferenceMigrationIsConservative()
        try verifiesGlobalExclusionIsSeparate()
        try verifiesDeviceCalendarYearsBecomeGregorian()
        try verifiesDeletedProfilesTakeNoToolPlace()
        try verifiesNormalizationSafety()
        try verifiesOptionalProfileMetadataCompatibility()
        try verifiesBothProfileDatesAndPrimaryBasis()
        try verifiesStableConfirmedKeyPhoto()
        try verifiesRevisionPolicyRejectsStaleState()
        try verifiesCodableRoundTrip()
        try verifiesProfileTransferBoundaries()
        try verifiesReorderedProfilesKeepTheirOrder()
        try verifiesDeletedCatsPhotosStayOffTheRemainingCats()
        try verifiesOnlyCatAtHomeRule()
        try verifiesPortablePhotoTransferNeedsExplicitConfirmation()
        try verifiesImportPlanSaysWhatApplyingDoes()
        try await verifiesProfileTransferCommitConflict()
        try await verifiesProtectedAtomicStore()
        try await verifiesFailedIdentityLoadsPreserveBytesAndAllowExplicitReread()
        print("Cat household identity verifier passed")
    }

    private static func verifiesLegacyMigrationIsUnscopedAndIdempotent() throws {
        var curation = CatCandidateCurationState.empty
        curation.exclude(
            localIdentifiers: ["stray-photo"],
            at: Date(timeIntervalSince1970: 10)
        )
        curation.selectSourceAlbum(
            localIdentifier: "legacy-household-album",
            assetIdentifiers: ["cat-b", "cat-a", "cat-b"]
        )
        let reference = lifeReference(year: 2020, month: 4, day: 5)
        let migrated = CatHouseholdIdentityState.legacyUnscoped(
            lifeReference: reference,
            curation: curation,
            at: Date(timeIntervalSince1970: 100)
        )

        try require(migrated.mode == .legacyUnscoped, "legacy mode was not retained")
        try require(migrated.profiles.isEmpty, "migration invented a cat profile")
        try require(migrated.memberships.isEmpty, "migration assigned photos to a profile")
        try require(
            migrated.legacyUnscoped?.lifeReference == reference,
            "legacy life reference was lost or assigned elsewhere"
        )
        try require(
            migrated.globalExcludedAssets.map(\.localIdentifier) == ["stray-photo"],
            "legacy global exclusion was not preserved"
        )
        try require(
            migrated.legacyUnscoped?.sourceAlbumIdentifier == "legacy-household-album"
                && migrated.legacyUnscoped?.lastKnownSourceAssetIdentifiers
                    == ["cat-a", "cat-b"],
            "legacy source was not preserved as household-wide state"
        )
        let repeated = migrated.reconcilingLegacyUnscoped(
            lifeReference: reference,
            curation: curation,
            at: Date(timeIntervalSince1970: 200)
        )
        try require(repeated == migrated, "identical legacy migration was not idempotent")

        var profiled = migrated
        profiled.upsertProfile(
            CatProfile(
                id: fixedUUID("00000000-0000-0000-0000-000000000001"),
                displayName: "むぎ",
                lifeReference: nil,
                createdAt: Date(timeIntervalSince1970: 300),
                updatedAt: Date(timeIntervalSince1970: 300)
            ),
            at: Date(timeIntervalSince1970: 300)
        )
        var changedCuration = curation
        changedCuration.exclude(localIdentifiers: ["new-stray"])
        let afterProfile = profiled.reconcilingLegacyUnscoped(
            lifeReference: nil,
            curation: changedCuration,
            at: Date(timeIntervalSince1970: 400)
        )
        try require(
            afterProfile == profiled,
            "legacy input overwrote explicit profiled state"
        )
    }

    private static func verifiesStaleLegacyMirrorCannotUndoIdentityDecision() throws {
        let curation = CatCandidateCurationState.empty
        var identity = CatHouseholdIdentityState.legacyUnscoped(
            lifeReference: nil,
            curation: curation,
            at: Date(timeIntervalSince1970: 10)
        )
        identity.setGloballyExcluded(
            true,
            assetLocalIdentifiers: ["new-global-exclusion"],
            at: Date(timeIntervalSince1970: 20)
        )
        let staleReconcile = identity.reconcilingLegacyUnscoped(
            lifeReference: nil,
            curation: curation,
            at: Date(timeIntervalSince1970: 30)
        )
        try require(
            staleReconcile.isGloballyExcluded("new-global-exclusion"),
            "a stale compatibility mirror undid a newer identity exclusion"
        )

        var newerCuration = curation
        newerCuration.exclude(
            localIdentifiers: ["new-global-exclusion"],
            at: Date(timeIntervalSince1970: 20)
        )
        let newerReconcile = staleReconcile.reconcilingLegacyUnscoped(
            lifeReference: nil,
            curation: newerCuration,
            at: Date(timeIntervalSince1970: 40)
        )
        try require(
            newerReconcile.legacyUnscoped?.importedCurationMutationRevision
                == newerCuration.mutationRevision,
            "a newer compatibility mirror revision was not imported"
        )

        // Once curation A has committed and its revision has been acknowledged,
        // replaying that same compatibility revision must not erase a newer
        // in-memory identity decision.
        var acknowledged = newerReconcile
        acknowledged.setGloballyExcluded(
            true,
            assetLocalIdentifiers: ["second-global-exclusion"],
            at: Date(timeIntervalSince1970: 50)
        )
        let afterFailedNextMirror = acknowledged.reconcilingLegacyUnscoped(
            lifeReference: nil,
            curation: newerCuration,
            at: Date(timeIntervalSince1970: 60)
        )
        try require(
            afterFailedNextMirror.isGloballyExcluded("new-global-exclusion")
                && afterFailedNextMirror.isGloballyExcluded("second-global-exclusion"),
            "an acknowledged curation revision rolled back a later identity decision"
        )

        // Entering profiled mode is a one-way canonical boundary. The app
        // reconciles the latest durable curation immediately before creating
        // the first profile so a previously failed acknowledgement is folded
        // in instead of silently resurrecting an excluded photo.
        var laggingIdentity = CatHouseholdIdentityState.legacyUnscoped(
            lifeReference: nil,
            curation: curation,
            at: Date(timeIntervalSince1970: 70)
        )
        laggingIdentity = laggingIdentity.reconcilingLegacyUnscoped(
            lifeReference: nil,
            curation: newerCuration,
            at: Date(timeIntervalSince1970: 80)
        )
        laggingIdentity.upsertProfile(
            CatProfile(
                id: fixedUUID("00000000-0000-0000-0000-000000000009"),
                displayName: "むぎ"
            ),
            at: Date(timeIntervalSince1970: 90)
        )
        try require(
            laggingIdentity.mode == .profiled
                && laggingIdentity.isGloballyExcluded("new-global-exclusion"),
            "profile creation lost the latest durable legacy exclusion"
        )
    }

    private static func verifiesManyToManyManualMembership() throws {
        let firstID = fixedUUID("00000000-0000-0000-0000-000000000001")
        let secondID = fixedUUID("00000000-0000-0000-0000-000000000002")
        var state = emptyProfiledState()
        state.upsertProfile(CatProfile(id: firstID, displayName: "むぎ"))
        state.upsertProfile(CatProfile(id: secondID, displayName: "あめ"))

        let firstRect = NormalizedRect(x: 0.05, y: 0.10, width: 0.35, height: 0.50)
        let secondRect = NormalizedRect(x: 0.55, y: 0.10, width: 0.35, height: 0.50)
        state.setManualMembership(
            assetLocalIdentifier: "two-cats",
            profileID: firstID,
            decision: .included,
            subjectBoundingBox: firstRect,
            isSimilarityReference: true
        )
        state.setManualMembership(
            assetLocalIdentifier: "two-cats",
            profileID: secondID,
            decision: .included,
            subjectBoundingBox: secondRect
        )

        try require(
            state.includedProfileIDs(for: "two-cats") == [firstID, secondID],
            "one photo could not belong to two profiles"
        )
        try require(
            state.subjectBoundingBox(for: "two-cats", profileID: firstID) == firstRect,
            "manual subject rectangle was not preserved by value"
        )
        try require(
            state.membership(for: "two-cats", profileID: firstID)?.isSimilarityReference
                == true,
            "explicit similarity reference was lost"
        )
        try require(
            state.membershipDecision(for: "unreviewed", profileID: firstID) == .unknown,
            "missing membership was not unknown"
        )

        state.setManualMembership(
            assetLocalIdentifier: "two-cats",
            profileID: firstID,
            decision: .excluded,
            subjectBoundingBox: firstRect,
            isSimilarityReference: true
        )
        let first = state.membership(for: "two-cats", profileID: firstID)
        try require(
            first?.decision == .excluded
                && first?.subjectBoundingBox == nil
                && first?.isSimilarityReference == false,
            "negative membership retained a crop or learning anchor"
        )
        try require(
            state.membershipDecision(for: "two-cats", profileID: secondID) == .included,
            "excluding one profile removed the other cat"
        )
    }

    private static func verifiesProfileAlbumMembershipPrecedence() throws {
        let firstID = fixedUUID("00000000-0000-0000-0000-000000000021")
        let secondID = fixedUUID("00000000-0000-0000-0000-000000000022")
        var state = emptyProfiledState()
        state.upsertProfile(CatProfile(id: firstID, displayName: "むぎ"))
        state.upsertProfile(CatProfile(id: secondID, displayName: "あめ"))
        state.setProfilePhotoAlbumLink(
            profileID: firstID,
            localIdentifier: "mugi-album",
            assetLocalIdentifiers: ["shared", "album-only", "shared"]
        )
        state.setProfilePhotoAlbumLink(
            profileID: secondID,
            localIdentifier: "ame-album",
            assetLocalIdentifiers: ["shared", "ame-only"]
        )
        state.setManualMembership(
            assetLocalIdentifier: "manual-only",
            profileID: firstID,
            decision: .included
        )

        try require(
            state.confirmedAssetIdentifiers(for: firstID)
                == ["album-only", "manual-only", "shared"],
            "manual and linked-album positives were not resolved as one set"
        )
        try require(
            state.confirmedProfileIDs(for: "shared") == [firstID, secondID],
            "one linked photo could not belong to two profiles"
        )
        try require(
            CatProfileManualAssignmentPolicy.decision(
                isSelected: true,
                previousDecision: nil,
                isLinkedAlbumPhoto: true
            ) == nil,
            "saving an unchanged album assignment created manual provenance"
        )
        try require(
            CatProfileManualAssignmentPolicy.decision(
                isSelected: false,
                previousDecision: nil,
                isLinkedAlbumPhoto: true
            ) == .excluded,
            "removing an album assignment did not create a manual override"
        )
        try require(
            CatProfileManualAssignmentPolicy.decision(
                isSelected: false,
                previousDecision: .included,
                isLinkedAlbumPhoto: false
            ) == .unknown,
            "removing a manual-only assignment left a false negative"
        )
        let limitedRefresh = CatProfilePhotoAlbumRefreshPolicy.resolve(
            lastKnownAssetLocalIdentifiers: ["old-a", "old-b"],
            accessibleAssetLocalIdentifiers: ["old-a", "new-c"],
            hasLimitedPhotosAccess: true
        )
        try require(
            limitedRefresh.assetLocalIdentifiers == ["new-c", "old-a", "old-b"]
                && limitedRefresh.shouldWarnAccessIsIncomplete,
            "limited Photos access destructively erased last-known membership"
        )
        let fullRefresh = CatProfilePhotoAlbumRefreshPolicy.resolve(
            lastKnownAssetLocalIdentifiers: ["old-a", "old-b"],
            accessibleAssetLocalIdentifiers: ["old-a", "new-c"],
            hasLimitedPhotosAccess: false
        )
        try require(
            fullRefresh.assetLocalIdentifiers == ["new-c", "old-a"]
                && !fullRefresh.shouldWarnAccessIsIncomplete,
            "full Photos access failed to apply authoritative album removals"
        )

        state.setManualMembership(
            assetLocalIdentifier: "album-only",
            profileID: firstID,
            decision: .excluded
        )
        try require(
            !state.confirmsAsset("album-only", for: firstID),
            "manual exclusion did not override the linked album"
        )

        let beforeNoOpRefresh = state
        state.refreshProfilePhotoAlbumLink(
            profileID: firstID,
            localIdentifier: "mugi-album",
            assetLocalIdentifiers: ["shared", "album-only"],
            at: Date(timeIntervalSince1970: 9_999)
        )
        try require(
            state == beforeNoOpRefresh,
            "an unchanged album refresh rewrote identity state"
        )
        state.refreshProfilePhotoAlbumLink(
            profileID: firstID,
            localIdentifier: "stale-album",
            assetLocalIdentifiers: ["stale-photo"]
        )
        try require(
            !state.confirmsAsset("stale-photo", for: firstID),
            "a stale album refresh replaced the current link"
        )

        state.setProfilePhotoAlbumLink(
            profileID: firstID,
            localIdentifier: nil
        )
        try require(
            state.confirmedAssetIdentifiers(for: firstID) == ["manual-only"],
            "unlinking an album removed a manual positive or retained album-only photos"
        )
        try require(
            state.confirmsAsset("shared", for: secondID),
            "unlinking one profile altered another profile's album"
        )

        state.setGloballyExcluded(
            true,
            assetLocalIdentifiers: ["shared"]
        )
        try require(
            state.confirmedProfileIDs(for: "shared").isEmpty,
            "global exclusion did not override a linked album"
        )
        state.setGloballyExcluded(false, assetLocalIdentifiers: ["shared"])
        try require(
            state.confirmedProfileIDs(for: "shared") == [secondID],
            "restoring a household candidate did not honor its still-linked album"
        )
    }

    private static func verifiesBuild14ReferenceMigrationIsConservative() throws {
        let uniqueProfileID = fixedUUID("00000000-0000-0000-0000-000000000011")
        let ambiguousProfileID = fixedUUID("00000000-0000-0000-0000-000000000012")
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let box = NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.5)
        let legacy = CatHouseholdIdentityState(
            schemaVersion: 1,
            mode: .profiled,
            profiles: [
                CatProfile(
                    id: uniqueProfileID,
                    displayName: "むぎ",
                    createdAt: createdAt,
                    updatedAt: createdAt
                ),
                CatProfile(
                    id: ambiguousProfileID,
                    displayName: "あめ",
                    createdAt: createdAt,
                    updatedAt: createdAt
                )
            ],
            memberships: [
                CatAssetProfileMembership(
                    assetLocalIdentifier: "unique-seed",
                    profileID: uniqueProfileID,
                    decision: .included,
                    subjectBoundingBox: box,
                    decidedAt: createdAt
                ),
                CatAssetProfileMembership(
                    assetLocalIdentifier: "ambiguous-a",
                    profileID: ambiguousProfileID,
                    decision: .included,
                    subjectBoundingBox: box,
                    decidedAt: createdAt
                ),
                CatAssetProfileMembership(
                    assetLocalIdentifier: "ambiguous-b",
                    profileID: ambiguousProfileID,
                    decision: .included,
                    subjectBoundingBox: box,
                    decidedAt: createdAt
                )
            ],
            globalExcludedAssets: [],
            legacyUnscoped: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        ).normalized()

        try require(
            legacy.schemaVersion == CatHouseholdIdentityState.currentSchemaVersion,
            "identity schema was not upgraded"
        )
        try require(
            legacy.membership(
                for: "unique-seed",
                profileID: uniqueProfileID
            )?.isSimilarityReference == true,
            "unique Build 14 profile seed was not recovered"
        )
        try require(
            legacy.memberships.filter {
                $0.profileID == ambiguousProfileID && $0.isSimilarityReference
            }.isEmpty,
            "ambiguous Build 14 memberships were promoted to anchors"
        )
    }

    private static func verifiesGlobalExclusionIsSeparate() throws {
        let firstID = fixedUUID("00000000-0000-0000-0000-000000000001")
        let secondID = fixedUUID("00000000-0000-0000-0000-000000000002")
        var state = emptyProfiledState()
        state.upsertProfile(CatProfile(id: firstID, displayName: "むぎ"))
        state.upsertProfile(CatProfile(id: secondID, displayName: "あめ"))
        for profileID in [firstID, secondID] {
            state.setManualMembership(
                assetLocalIdentifier: "two-cats",
                profileID: profileID,
                decision: .included,
                isSimilarityReference: true
            )
        }
        state.setProfileKeyPhoto(profileID: firstID, assetLocalIdentifier: "two-cats")
        try require(state.profiles.first { $0.id == firstID }?.keyPhotoLocalIdentifier == "two-cats", "key photo fixture")
        let beforeExclusion = state.memberships
        state.setGloballyExcluded(
            true,
            assetLocalIdentifiers: ["two-cats"],
            at: Date(timeIntervalSince1970: 500)
        )
        try require(state.isGloballyExcluded("two-cats"), "global exclusion was lost")
        try require(
            state.memberships.allSatisfy { $0.assetLocalIdentifier != "two-cats" },
            "global exclusion retained per-profile learning decisions"
        )
        try require(state.profiles.allSatisfy { $0.keyPhotoLocalIdentifier == nil }, "an excluded photo stayed a key photo")
        // A local-only copy: what leaves this iPhone drops it with the exclusions.
        var portable = state
        portable.globalExcludedAssets = []
        try require(portable.normalized().exclusionSetAside == nil, "set-aside decisions outlived their exclusion")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        state = try decoder.decode(CatHouseholdIdentityState.self, from: encoder.encode(state))
        // 11/20: 「戻す」 gives back what the exclusion took, key photo included.
        state.setGloballyExcluded(false, assetLocalIdentifiers: ["two-cats"])
        try require(!state.isGloballyExcluded("two-cats"), "global restore failed")
        try require(state.memberships == beforeExclusion, "global restore lost the per-cat decisions")
        try require(state.profiles.first { $0.id == firstID }?.keyPhotoLocalIdentifier == "two-cats", "global restore lost the key photo")
        try require(state.exclusionSetAside == nil, "a restored photo kept its set-aside copy")

        // A decision made while excluded is not overwritten; a cat with a
        // new key photo keeps it.
        state.setManualMembership(assetLocalIdentifier: "other", profileID: firstID, decision: .included)
        state.setGloballyExcluded(true, assetLocalIdentifiers: ["two-cats"], at: Date(timeIntervalSince1970: 600))
        state.setProfileKeyPhoto(profileID: firstID, assetLocalIdentifier: "other")
        state.setGloballyExcluded(false, assetLocalIdentifiers: ["two-cats"])
        try require(state.profiles.first { $0.id == firstID }?.keyPhotoLocalIdentifier == "other", "restore replaced a newer key photo")
        try require(state.membershipDecision(for: "two-cats", profileID: secondID) == .included, "restore lost the second cat's decision")
    }

    /// 11/20: a tool cat whose profile was deleted keeps its records but takes
    /// no place; a cat without a profile still does.
    private static func verifiesDeletedProfilesTakeNoToolPlace() throws {
        let living = (0..<9).map { "PROFILE-\($0)" }
        let tool: [String?] = living + ["deleted-profile"]
        try require(!CatProfileLimit.canAddToolCat(tool, departed: [], profiles: nil), "unknown profiles count every cat")
        try require(CatProfileLimit.canAddToolCat(tool, departed: [], profiles: Set(living.map { $0.lowercased() })),
                    "a deleted profile's leftover blocked a new cat")
        try require(!CatProfileLimit.canAddToolCat(tool + [nil], departed: [], profiles: Set(living)),
                    "a cat without a profile stopped counting")
    }

    /// 11/20: a year saved in the iPhone's 仏暦 calendar before 11/10 becomes
    /// 西暦 while this iPhone can tell the day; otherwise it stays as it is.
    private static func verifiesDeviceCalendarYearsBecomeGregorian() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let legacy = try JSONDecoder().decode(CatLifeDate.self, from: Data(#"{"year":2569,"month":4,"day":5}"#.utf8))
        let converted = legacy.inGregorian(device: buddhist)
        try require(converted?.year == 2026 && converted?.month == 4 && converted?.day == 5, "a 仏暦 year did not become 西暦")
        try require(legacy.inGregorian(device: gregorian) == nil, "a 西暦 iPhone guessed at an undeterminable year")
        let current = lifeReference(year: 2020, month: 4, day: 5).date
        try require(current.inGregorian(device: buddhist) == nil, "a 西暦 year was converted again")

        let profileID = fixedUUID("00000000-0000-0000-0000-000000000009")
        var state = emptyProfiledState()
        state.upsertProfile(CatProfile(id: profileID, displayName: "むぎ",
            lifeDates: CatProfileLifeDates(birthday: legacy, adoptionDay: current)))
        let unchanged = state.convertingDeviceCalendarYears(device: gregorian)
        try require(unchanged == state, "a 西暦 iPhone changed an undeterminable birthday")
        let fixed = state.convertingDeviceCalendarYears(device: buddhist)
        let dates = fixed.profiles.first?.resolvedLifeDates
        try require(dates?.birthday?.year == 2026 && dates?.adoptionDay?.year == 2020, "profile dates were not made 西暦")
        try require(fixed.profiles.first?.lifeReference?.date.year == 2026, "the primary basis kept the 仏暦 year")
    }

    private static func verifiesNormalizationSafety() throws {
        let profileID = fixedUUID("00000000-0000-0000-0000-000000000001")
        var state = emptyProfiledState()
        state.upsertProfile(CatProfile(
            id: profileID,
            displayName: "  むぎ  ",
            lifeReference: nil,
            lifeReferenceIsApproximate: true
        ))
        state.setManualMembership(
            assetLocalIdentifier: "invalid-crop",
            profileID: profileID,
            decision: .included,
            subjectBoundingBox: NormalizedRect(
                x: 0.8,
                y: 0.2,
                width: 0.4,
                height: 0.4
            ),
            isSimilarityReference: true
        )
        state.setProfilePhotoAlbumLink(
            profileID: profileID,
            localIdentifier: "mugi-album",
            assetLocalIdentifiers: ["linked-b", "linked-a", "linked-b"]
        )
        let normalized = state.normalized()
        try require(
            normalized.profiles.first?.displayName == "むぎ",
            "profile display name was not normalized"
        )
        try require(
            normalized.profiles.first?.lifeReferenceIsApproximate == false,
            "nil life reference remained approximate"
        )
        try require(
            normalized.subjectBoundingBox(
                for: "invalid-crop",
                profileID: profileID
            ) == nil,
            "out-of-unit subject rectangle was persisted"
        )
    }

    private static func verifiesOptionalProfileMetadataCompatibility() throws {
        // A schema-3 file from before dual dates/key photos existed. Keeping a
        // literal fixture ensures missing new keys are actually exercised.
        let oldJSON = """
        {
          "schemaVersion": 3, "mutationRevision": 7, "mode": "profiled",
          "profiles": [{
            "id": "00000000-0000-0000-0000-000000000001",
            "displayName": "むぎ",
            "lifeReference": {
              "kind": "adoptionDay", "date": {"year": 2020, "month": 4, "day": 5}
            },
            "lifeReferenceIsApproximate": true,
            "createdAt": "2020-01-01T00:00:00Z", "updatedAt": "2020-01-01T00:00:00Z"
          }],
          "memberships": [{
            "assetLocalIdentifier": "old-confirmed-photo",
            "profileID": "00000000-0000-0000-0000-000000000001",
            "decision": "included", "isSimilarityReference": false,
            "decidedAt": "2020-01-01T00:00:00Z"
          }],
          "globalExcludedAssets": [{
            "localIdentifier": "old-excluded-photo", "excludedAt": "2020-01-01T00:00:00Z"
          }],
          "createdAt": "2020-01-01T00:00:00Z", "updatedAt": "2020-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            CatHouseholdIdentityState.self,
            from: Data(oldJSON.utf8)
        )
        let normalized = decoded.normalized()
        try require(normalized == decoded, "old schema-3 identity changed during normalization")
        try require(
            normalized.profiles[0].lifeDates == nil
                && normalized.profiles[0].keyPhotoLocalIdentifier == nil
                && normalized.profiles[0].lifeReference(for: .birthday) == nil
                && normalized.profiles[0].lifeReference(for: .adoptionDay)
                    == normalized.profiles[0].lifeReference
                && normalized.profiles[0].isLifeReferenceApproximate(for: .adoptionDay),
            "missing optional profile fields lost or reassigned an older milestone"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let restored = try decoder.decode(
            CatHouseholdIdentityState.self,
            from: encoder.encode(normalized)
        ).normalized()
        try require(
            restored == decoded,
            "old UUID, membership, exclusion, date, or revision changed after round-trip"
        )
    }

    private static func verifiesBothProfileDatesAndPrimaryBasis() throws {
        let birthday = lifeReference(year: 2020, month: 4, day: 5)
        let adoption = CatLifeReference(
            kind: .adoptionDay,
            date: lifeReference(year: 2020, month: 7, day: 6).date
        )
        var profile = CatProfile(displayName: "むぎ", lifeReference: adoption)
        let bothDates = CatProfileLifeDates(
            birthday: birthday.date,
            birthdayIsApproximate: true,
            adoptionDay: adoption.date
        )
        profile.setLifeDates(bothDates)
        try require(
            profile.lifeReference == adoption && !profile.lifeReferenceIsApproximate
                && profile.lifeReference(for: .birthday) == birthday
                && profile.isLifeReferenceApproximate(for: .birthday),
            "adding a birthday replaced the established adoption basis or lost approximation"
        )
        profile.setLifeDates(bothDates, preferredPrimaryKind: .birthday)
        try require(
            profile.lifeReference == birthday && profile.lifeReferenceIsApproximate,
            "the explicitly selected growth basis was not applied"
        )
        profile.setLifeDates(CatProfileLifeDates(adoptionDay: adoption.date))
        try require(
            profile.lifeReference == adoption && !profile.lifeReferenceIsApproximate,
            "clearing the primary date did not fall back to the remaining milestone"
        )
        profile.setLifeDates(CatProfileLifeDates())
        // Explicit empty new metadata must remain authoritative even if a
        // stale caller supplies an old legacy field alongside it.
        profile.lifeReference = birthday
        profile.lifeReferenceIsApproximate = true
        profile = profile.normalized()
        try require(
            profile.lifeReference == nil && !profile.lifeReferenceIsApproximate
                && profile.lifeDates == CatProfileLifeDates()
                && profile.lifeReference(for: .birthday) == nil
                && profile.lifeReference(for: .adoptionDay) == nil,
            "cleared profile dates were resurrected from legacy fields"
        )
        let restored = try JSONDecoder().decode(
            CatProfile.self,
            from: JSONEncoder().encode(profile)
        ).normalized()
        try require(restored == profile, "cleared profile dates did not survive round-trip")
        profile.setLifeDates(bothDates)
        try require(
            profile.lifeReference == birthday && profile.lifeReferenceIsApproximate,
            "a profile without a previous basis did not default to birthday"
        )
    }

    private static func verifiesStableConfirmedKeyPhoto() throws {
        let firstID = fixedUUID("00000000-0000-0000-0000-000000000001")
        let secondID = fixedUUID("00000000-0000-0000-0000-000000000002")
        var state = emptyProfiledState()
        state.upsertProfile(CatProfile(id: firstID, displayName: "むぎ"))
        state.upsertProfile(CatProfile(id: secondID, displayName: "あめ"))
        for profileID in [firstID, secondID] {
            state.setManualMembership(
                assetLocalIdentifier: "chosen-photo", profileID: profileID, decision: .included
            )
            state.setProfileKeyPhoto(profileID: profileID, assetLocalIdentifier: "chosen-photo")
        }
        state.setManualMembership(
            assetLocalIdentifier: "newer-photo", profileID: firstID, decision: .included
        )
        state.setProfileKeyPhoto(profileID: firstID, assetLocalIdentifier: "unconfirmed")
        state.setProfileKeyPhoto(profileID: firstID, assetLocalIdentifier: "  ")
        try require(
            state.profiles.allSatisfy { $0.keyPhotoLocalIdentifier == "chosen-photo" }
                && state.confirmedProfileIDs(for: "chosen-photo") == [firstID, secondID],
            "a new or invalid cover changed a stable selection or many-to-many membership"
        )
        state.setProfileKeyPhoto(profileID: firstID, assetLocalIdentifier: nil)
        try require(
            state.profiles.first { $0.id == firstID }?.keyPhotoLocalIdentifier == nil
                && state.confirmsAsset("chosen-photo", for: firstID),
            "clearing a key photo also removed its confirmed membership"
        )
        state.setProfileKeyPhoto(profileID: firstID, assetLocalIdentifier: "chosen-photo")
        state.setManualMembership(
            assetLocalIdentifier: "chosen-photo", profileID: firstID, decision: .unknown
        )
        try require(
            state.profiles.first { $0.id == firstID }?.keyPhotoLocalIdentifier == nil
                && state.profiles.first { $0.id == secondID }?.keyPhotoLocalIdentifier
                    == "chosen-photo",
            "removing membership retained an invalid cover or altered another profile"
        )
        state.setProfilePhotoAlbumLink(
            profileID: firstID, localIdentifier: "mugi-album",
            assetLocalIdentifiers: ["linked-cover"]
        )
        state.setProfileKeyPhoto(profileID: firstID, assetLocalIdentifier: "linked-cover")
        let limitedRefresh = CatProfilePhotoAlbumRefreshPolicy.resolve(
            lastKnownAssetLocalIdentifiers: ["linked-cover"],
            accessibleAssetLocalIdentifiers: [], hasLimitedPhotosAccess: true
        )
        state.refreshProfilePhotoAlbumLink(
            profileID: firstID, localIdentifier: "mugi-album",
            assetLocalIdentifiers: limitedRefresh.assetLocalIdentifiers
        )
        try require(
            state.profiles.first { $0.id == firstID }?.keyPhotoLocalIdentifier == "linked-cover",
            "temporary Limited Photos unavailability cleared a confirmed key photo"
        )
        state.setProfilePhotoAlbumLink(profileID: firstID, localIdentifier: nil)
        try require(
            state.profiles.first { $0.id == firstID }?.keyPhotoLocalIdentifier == nil,
            "unlinking the only confirming source retained its key photo"
        )
        state.setGloballyExcluded(true, assetLocalIdentifiers: ["chosen-photo"])
        try require(
            state.profiles.allSatisfy { $0.keyPhotoLocalIdentifier == nil },
            "global exclusion retained a key photo"
        )
        // 11/20: 「戻す」 gives back what the exclusion took: the second cat's
        // confirmed membership and, with it, its key photo. The first cat,
        // whose decision was unknown, stays without one.
        state.setGloballyExcluded(false, assetLocalIdentifiers: ["chosen-photo"])
        try require(
            state.profiles.first { $0.id == firstID }?.keyPhotoLocalIdentifier == nil
                && state.profiles.first { $0.id == secondID }?.keyPhotoLocalIdentifier == "chosen-photo"
                && state.confirmsAsset("chosen-photo", for: secondID),
            "global restore resurrected an unconfirmed key photo or lost a confirmed one"
        )
        state.setProfileKeyPhoto(profileID: secondID, assetLocalIdentifier: nil)
        state.profiles[0].keyPhotoLocalIdentifier = "unconfirmed"
        try require(
            state.normalized().profiles.allSatisfy { $0.keyPhotoLocalIdentifier == nil },
            "decoded unconfirmed key photo bypassed membership validation"
        )
    }

    private static func verifiesRevisionPolicyRejectsStaleState() throws {
        var current = emptyProfiledState()
        current.mutationRevision = 4
        var proposed = current
        proposed.upsertProfile(CatProfile(displayName: "むぎ"))
        proposed.mutationRevision = 4
        let committed = try CatHouseholdIdentityRevisionPolicy.committing(
            proposed,
            replacing: current,
            expectedMutationRevision: 4,
            at: Date(timeIntervalSince1970: 600)
        )
        try require(committed.mutationRevision == 5, "commit did not advance exactly once")

        do {
            _ = try CatHouseholdIdentityRevisionPolicy.committing(
                proposed,
                replacing: committed,
                expectedMutationRevision: 4
            )
            throw VerificationError.failed("stale revision was accepted")
        } catch let error as CatHouseholdIdentityRevisionError {
            try require(
                error == .stale(expected: 4, actual: 5),
                "stale revision reported the wrong ordering"
            )
        }
    }

    private static func verifiesCodableRoundTrip() throws {
        let profileID = fixedUUID("00000000-0000-0000-0000-000000000001")
        var state = emptyProfiledState()
        state.upsertProfile(CatProfile(
            id: profileID,
            displayName: "むぎ",
            lifeReference: lifeReference(year: 2020, month: 4, day: 5),
            lifeReferenceIsApproximate: true,
            lifeDates: CatProfileLifeDates(
                birthday: lifeReference(year: 2020, month: 4, day: 5).date,
                birthdayIsApproximate: true,
                adoptionDay: lifeReference(year: 2020, month: 7, day: 6).date
            )
        ))
        state.setManualMembership(
            assetLocalIdentifier: "cat-photo",
            profileID: profileID,
            decision: .included,
            subjectBoundingBox: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            isSimilarityReference: true
        )
        state.setProfilePhotoAlbumLink(
            profileID: profileID,
            localIdentifier: "mugi-album",
            assetLocalIdentifiers: ["linked-b", "linked-a", "linked-b"]
        )
        state.setProfileKeyPhoto(profileID: profileID, assetLocalIdentifier: "cat-photo")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            CatHouseholdIdentityState.self,
            from: encoder.encode(state)
        ).normalized()
        try require(decoded == state.normalized(), "identity round-trip lost data")
        try require(
            decoded.profiles.first?.keyPhotoLocalIdentifier == "cat-photo"
                && decoded.profiles.first?.lifeReference(for: .birthday)?.date
                    == lifeReference(year: 2020, month: 4, day: 5).date
                && decoded.profiles.first?.lifeReference(for: .adoptionDay)?.date
                    == lifeReference(year: 2020, month: 7, day: 6).date,
            "dual milestones or stable key photo were not persisted"
        )
        try require(
            decoded.profiles.first?.photoAlbumLink?.lastKnownAssetLocalIdentifiers
                == ["linked-a", "linked-b"],
            "profile album membership was not normalized or persisted"
        )

        var schemaTwo = state
        schemaTwo.schemaVersion = 2
        schemaTwo.profiles[0].photoAlbumLink = nil
        guard var schemaTwoObject = try JSONSerialization.jsonObject(
            with: encoder.encode(schemaTwo)
        ) as? [String: Any] else {
            throw VerificationError.failed("schema 2 identity JSON was unavailable")
        }
        guard var schemaTwoProfiles = schemaTwoObject["profiles"]
                as? [[String: Any]] else {
            throw VerificationError.failed("schema 2 profile JSON was unavailable")
        }
        for index in schemaTwoProfiles.indices {
            schemaTwoProfiles[index].removeValue(forKey: "photoAlbumLink")
            schemaTwoProfiles[index].removeValue(forKey: "lifeDates")
            schemaTwoProfiles[index].removeValue(forKey: "keyPhotoLocalIdentifier")
        }
        schemaTwoObject["profiles"] = schemaTwoProfiles
        let schemaTwoData = try JSONSerialization.data(
            withJSONObject: schemaTwoObject
        )
        let schemaTwoDecoded = try decoder.decode(
            CatHouseholdIdentityState.self,
            from: schemaTwoData
        ).normalized()
        try require(
            schemaTwoDecoded.schemaVersion
                == CatHouseholdIdentityState.currentSchemaVersion
                && schemaTwoDecoded.profiles.first?.photoAlbumLink == nil,
            "schema 2 identity did not migrate without inventing an album link"
        )
    }

    /// Uses only a fresh temporary fixture and the existing stateURL injection.
    /// This proves store-level rejection/reread, not AppViewModel startup retry.
    private static func verifiesFailedIdentityLoadsPreserveBytesAndAllowExplicitReread() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "startup-identity-fault-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic-identity.json")
        let store = try CatHouseholdIdentityStore(stateURL: url)
        var curation = CatCandidateCurationState.empty
        curation.exclude(localIdentifiers: ["synthetic-excluded-photo"], at: Date(timeIntervalSince1970: 1))
        let original = try await store.loadOrMigrate(
            legacyLifeReference: lifeReference(year: 2020, month: 4, day: 5),
            legacyCuration: curation, at: Date(timeIntervalSince1970: 2))
        let validBytes = try Data(contentsOf: url)

        // A truncated read payload must not be treated as a missing/empty ledger.
        let partialBytes = Data(validBytes.prefix(max(1, validBytes.count / 2)))
        try partialBytes.write(to: url)
        var rejected = false
        do { _ = try await store.load() } catch is DecodingError { rejected = true }
        try require(rejected, "a truncated identity was accepted as a successful load")
        let bytesAfterFailure = try Data(contentsOf: url)
        try require(bytesAfterFailure == partialBytes, "a failed load rewrote the truncated identity")

        // Even the migration entry point must not replace malformed data with defaults.
        for _ in 0..<2 {
            rejected = false
            do {
                _ = try await store.loadOrMigrate(legacyLifeReference: nil, legacyCuration: .empty)
            } catch is DecodingError { rejected = true }
            try require(rejected, "persistent identity corruption became an empty migration")
            let bytesAfterMigrationFailure = try Data(contentsOf: url)
            try require(bytesAfterMigrationFailure == partialBytes, "migration overwrote a corrupt identity")
        }

        // Restore only the generated fixture; no automatic recovery/reset is performed.
        try validBytes.write(to: url)
        let recovered = try await store.load()
        try require(recovered == original, "the same store could not explicitly reread a repaired fixture")
        let bytesAfterRecovery = try Data(contentsOf: url)
        try require(bytesAfterRecovery == validBytes, "rereading advanced or rewrote healthy identity data")

        // 11/20: a plain load writes nothing, so a field from a later build
        // in the same schema survives being read here.
        var later = try JSONSerialization.jsonObject(with: validBytes) as! [String: Any]
        later["syntheticFieldFromLaterBuild"] = "kept"
        let laterBytes = try JSONSerialization.data(withJSONObject: later, options: [.sortedKeys])
        try laterBytes.write(to: url)
        _ = try await store.load()
        let bytesAfterPlainLoad = try Data(contentsOf: url)
        try require(bytesAfterPlainLoad == laterBytes, "a plain load rewrote the identity file")
        try validBytes.write(to: url)

        var future = try JSONSerialization.jsonObject(with: validBytes) as! [String: Any]
        future["schemaVersion"] = CatHouseholdIdentityState.currentSchemaVersion + 1
        let futureBytes = try JSONSerialization.data(withJSONObject: future, options: [.sortedKeys])
        try futureBytes.write(to: url)
        do {
            _ = try await store.loadOrMigrate(legacyLifeReference: nil, legacyCuration: .empty)
            throw VerificationError.failed("a future identity schema was silently replaced")
        } catch CatHouseholdIdentityStoreError.unsupportedSchema(_) { }
        let bytesAfterFutureSchemaFailure = try Data(contentsOf: url)
        try require(bytesAfterFutureSchemaFailure == futureBytes, "future-schema failure changed stored bytes")
    }

    private static func verifiesProtectedAtomicStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cat-identity-verifier-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("identity.json")
        let store = try CatHouseholdIdentityStore(stateURL: stateURL)
        var curation = CatCandidateCurationState.empty
        curation.exclude(localIdentifiers: ["stray-photo"])

        let initial = try await store.loadOrMigrate(
            legacyLifeReference: lifeReference(year: 2020, month: 4, day: 5),
            legacyCuration: curation,
            at: Date(timeIntervalSince1970: 700)
        )
        let repeated = try await store.loadOrMigrate(
            legacyLifeReference: initial.legacyUnscoped?.lifeReference,
            legacyCuration: curation,
            at: Date(timeIntervalSince1970: 800)
        )
        try require(repeated == initial, "store migration advanced on identical input")
        try require(
            CatHouseholdIdentityStore.hasRequiredFileSecurity(at: stateURL),
            "identity file is backed up or lacks data protection"
        )

        var proposed = initial
        proposed.upsertProfile(CatProfile(displayName: "むぎ"))
        let committed = try await store.save(
            proposed,
            expectedMutationRevision: initial.mutationRevision,
            at: Date(timeIntervalSince1970: 900)
        )
        try require(committed.mutationRevision == 1, "store revision did not advance")
        do {
            _ = try await store.save(
                initial,
                expectedMutationRevision: initial.mutationRevision
            )
            throw VerificationError.failed("store accepted a stale save")
        } catch let error as CatHouseholdIdentityRevisionError {
            try require(
                error == .stale(expected: 0, actual: 1),
                "store stale-save error was incorrect"
            )
        }
    }

    /// 11/21 並べ替え: the array's order is the cats' order, through
    /// normalization, a commit, the saved JSON and the transfer file. A file
    /// without a new order (saved in createdAt order) keeps that order.
    private static func verifiesReorderedProfilesKeepTheirOrder() throws {
        let a = fixedUUID("00000000-0000-0000-0000-0000000000A1")
        let b = fixedUUID("00000000-0000-0000-0000-0000000000A2")
        let c = fixedUUID("00000000-0000-0000-0000-0000000000A3")
        var state = emptyProfiledState()
        for (index, id) in [a, b, c].enumerated() {
            let created = Date(timeIntervalSince1970: Double(100 + index))
            state.upsertProfile(CatProfile(id: id, displayName: "合成ねこ\(index)", createdAt: created,
                                           updatedAt: created), at: created)
        }
        try require(state.profiles.map(\.id) == [a, b, c], "cats were not kept in the order they were added")
        var reordered = state
        reordered.profiles = [c, a, b].compactMap { id in state.profiles.first { $0.id == id } }
        reordered = reordered.normalized()
        try require(reordered.profiles.map(\.id) == [c, a, b], "normalization undid a reorder")
        try require(reordered != state, "a reorder was treated as no change")
        let committed = try CatHouseholdIdentityRevisionPolicy.committing(
            reordered, replacing: state, expectedMutationRevision: state.mutationRevision,
            at: Date(timeIntervalSince1970: 900))
        try require(committed.profiles.map(\.id) == [c, a, b], "a commit undid a reorder")
        let decoded = try JSONDecoder().decode(CatHouseholdIdentityState.self,
                                               from: JSONEncoder().encode(committed)).normalized()
        try require(decoded.profiles.map(\.id) == [c, a, b], "a reload undid a reorder")
        try require(decoded == decoded.normalized(), "a reordered file is not stable under normalization")
        var renamed = decoded
        renamed.upsertProfile(CatProfile(id: a, displayName: "合成ねこ改", createdAt: Date(timeIntervalSince1970: 100)),
                              at: Date(timeIntervalSince1970: 950))
        try require(renamed.profiles.map(\.id) == [c, a, b], "editing a cat moved it")
        let d = fixedUUID("00000000-0000-0000-0000-0000000000A4")
        renamed.upsertProfile(CatProfile(id: d, displayName: "合成ねこ3", createdAt: Date(timeIntervalSince1970: 50)),
                              at: Date(timeIntervalSince1970: 960))
        try require(renamed.profiles.map(\.id) == [c, a, b, d], "a new cat did not come last")
        var duplicated = decoded
        duplicated.profiles.append(decoded.profiles[0])
        try require(duplicated.normalized().profiles.map(\.id) == [c, a, b], "a duplicate moved a cat")
        let transfer = try CatProfileTransfer(profiles: committed.profiles)
        let imported = try CatProfileTransfer.decode(transfer.encoded())
            .applying(to: emptyProfiledState(), expectedRevision: 0, at: Date(timeIntervalSince1970: 990))
        try require(imported.profiles.map(\.id) == [c, a, b], "the transfer file lost the order")
    }

    /// 11/21: a photo chosen for a deleted cat never becomes the photo of a
    /// cat that is left: not at 2→1 when 「写っている猫を選ぶ」 wrote
    /// 「わからない」 for the other cat, and not at 3→2→1. A photo no cat
    /// was chosen for still follows the single-cat rule.
    private static func verifiesDeletedCatsPhotosStayOffTheRemainingCats() throws {
        let mugi = fixedUUID("00000000-0000-0000-0000-0000000000B1")
        let ame = fixedUUID("00000000-0000-0000-0000-0000000000B2")
        let sora = fixedUUID("00000000-0000-0000-0000-0000000000B3")
        let detected: Set<String> = ["for-sora", "for-ame", "both", "nobody", "album"]
        var state = emptyProfiledState()
        for (index, id) in [mugi, ame, sora].enumerated() {
            state.upsertProfile(CatProfile(id: id, displayName: "合成ねこ\(index)"))
        }
        state.setProfilePhotoAlbumLink(profileID: mugi, localIdentifier: "mugi-album",
                                       assetLocalIdentifiers: ["album"])
        // As 「写っている猫を選ぶ」 writes it: yes for the chosen, わからない for the others.
        func choose(_ photo: String, _ chosen: Set<UUID>) {
            for id in [mugi, ame, sora] {
                state.setManualMembership(assetLocalIdentifier: photo, profileID: id,
                                          decision: chosen.contains(id) ? .included : .unknown)
            }
        }
        choose("for-sora", [sora])
        choose("for-ame", [ame])
        choose("both", [mugi, sora])
        state.setManualMembership(assetLocalIdentifier: "album", profileID: sora, decision: .included)

        state.removeProfile(id: sora)  // 3→2
        try require(state.membershipDecision(for: "for-sora", profileID: mugi) == .excluded
                    && state.membershipDecision(for: "for-sora", profileID: ame) == .excluded,
                    "a deleted cat's photo was left undecided for the cats left")
        try require(state.membershipDecision(for: "both", profileID: mugi) == .included,
                    "a cat's own yes was replaced")
        try require(state.membershipDecision(for: "album", profileID: mugi) == .unknown
                    && state.confirmsAsset("album", for: mugi), "a linked album photo was taken off its cat")
        try require(state.memberships.filter {
            $0.assetLocalIdentifier == "for-sora" && $0.profileID == mugi
        }.count == 1, "the わからない was kept beside the new decision")

        state.removeProfile(id: ame)  // 2→1
        try require(state.singleCatProfileID == mugi, "one cat was not left")
        let mugiPhotos = state.effectiveAssetIdentifiers(for: mugi, detectedCatAssetIdentifiers: detected)
        try require(mugiPhotos == ["both", "nobody", "album"],
                    "the last cat's photos were \(mugiPhotos.sorted()), not her own and the unassigned one")
        try require(state.effectiveProfileIDs(for: "for-sora", isDetectedCatPhoto: true).isEmpty
                    && state.effectiveProfileIDs(for: "for-ame", isDetectedCatPhoto: true).isEmpty,
                    "a deleted cat's photo became the last cat's")
        // She can still be given one by hand.
        state.setManualMembership(assetLocalIdentifier: "for-ame", profileID: mugi, decision: .included)
        try require(state.confirmsAsset("for-ame", for: mugi), "a photo could not be given to the last cat")
    }

    /// 11/22: a photo taken while one cat was home is that cat's photo.
    /// Synthetic household: the first cat came home in 2022, the second in 2025.
    private static func verifiesOnlyCatAtHomeRule() throws {
        let saved = CatSingleCatRule.familyCatsOutsideProfiles
        defer { CatSingleCatRule.familyCatsOutsideProfiles = saved }
        CatSingleCatRule.familyCatsOutsideProfiles = false
        let first = fixedUUID("22222222-1122-4222-8222-000000000001")
        let second = fixedUUID("22222222-1122-4222-8222-000000000002")
        func adopted(_ year: Int, _ month: Int, _ day: Int) -> CatProfileLifeDates {
            CatProfileLifeDates(adoptionDay: lifeReference(year: year, month: month, day: day).date)
        }
        func taken(_ year: Int, _ month: Int, _ day: Int) -> Date {
            lifeReference(year: year, month: month, day: day).date.date()!
        }
        var state = emptyProfiledState()
        state.upsertProfile(CatProfile(id: first, displayName: "合成ねこA", lifeDates: adopted(2022, 4, 10)))
        state.upsertProfile(CatProfile(id: second, displayName: "合成ねこB", lifeDates: adopted(2025, 6, 10)))
        let dates: [String: Date] = [
            "y2021": taken(2021, 8, 15),          // before either cat came home
            "y2022-day": taken(2022, 4, 10),      // the first cat's 迎えた日
            "y2024": taken(2024, 8, 15),
            "y2025-before": taken(2025, 6, 9),
            "y2025-after": taken(2025, 7, 15),
            "y2026": taken(2026, 3, 15),
            "y2024-for-second": taken(2024, 9, 15),
            "y2024-not-first": taken(2024, 10, 15),
            "y2024-hidden": taken(2024, 11, 15)
        ]
        let detected = Set(dates.keys).union(["no-date"])
        state.setManualMembership(assetLocalIdentifier: "y2024-for-second", profileID: second, decision: .included)
        state.setManualMembership(assetLocalIdentifier: "y2024-not-first", profileID: first, decision: .excluded)
        state.setGloballyExcluded(true, assetLocalIdentifiers: ["y2024-hidden"])

        let sets = state.effectiveAssetIdentifiersByProfile(
            detectedCatAssetIdentifiers: detected, detectedCatPhotoDates: dates)
        try require(sets[first] == ["y2022-day", "y2024", "y2025-before"],
                    "the first cat's photos were \((sets[first] ?? []).sorted())")
        try require(sets[second] == ["y2024-for-second"],
                    "the second cat's photos were \((sets[second] ?? []).sorted())")
        try require(state.effectiveProfileIDs(for: "y2024", isDetectedCatPhoto: true, takenAt: dates["y2024"]) == [first]
                    && state.effectiveProfileIDs(for: "y2025-after", isDetectedCatPhoto: true,
                                                 takenAt: dates["y2025-after"]).isEmpty
                    && state.effectiveProfileIDs(for: "no-date", isDetectedCatPhoto: true, takenAt: nil).isEmpty,
                    "one photo's cats disagree with the sets")
        try require(state.memberships.count == 2, "the rule wrote a decision")

        // The first cat's 旅立った日: from the next day the second cat is the only one home.
        var departed = state
        departed.farewellDays = [first.uuidString: CatFarewellDay(year: 2025, month: 12, day: 31)]
        let afterFarewell = departed.effectiveAssetIdentifiersByProfile(
            detectedCatAssetIdentifiers: detected, detectedCatPhotoDates: dates)
        try require(afterFarewell[second] == ["y2024-for-second", "y2026"]
                    && afterFarewell[first] == ["y2022-day", "y2024", "y2025-before"],
                    "after the 旅立った日 the photos were \(afterFarewell.mapValues { $0.sorted() })")

        // A cat without 迎えた日, or a family-notebook cat outside the profiles: as before.
        var undated = state
        undated.upsertProfile(CatProfile(id: second, displayName: "合成ねこB", lifeDates: CatProfileLifeDates()))
        try require(undated.homeDerivedProfileIDs(detectedCatPhotoDates: dates).isEmpty,
                    "a household with a cat without 迎えた日 used the rule")
        CatSingleCatRule.familyCatsOutsideProfiles = true
        try require(state.homeDerivedProfileIDs(detectedCatPhotoDates: dates).isEmpty,
                    "a family-notebook cat outside the profiles did not stop the rule")
        CatSingleCatRule.familyCatsOutsideProfiles = false

        // One cat: the single-cat rule, unchanged.
        var one = state
        one.removeProfile(id: second)
        try require(one.homeDerivedProfileIDs(detectedCatPhotoDates: dates).isEmpty
                    && one.effectiveAssetIdentifiers(for: first, detectedCatAssetIdentifiers: detected,
                                                     detectedCatPhotoDates: dates).contains("no-date"),
                    "the one-cat household changed")
    }

    private static func emptyProfiledState() -> CatHouseholdIdentityState {
        CatHouseholdIdentityState(
            mode: .profiled,
            profiles: [],
            memberships: [],
            globalExcludedAssets: [],
            legacyUnscoped: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private static func verifiesProfileTransferBoundaries() throws {
        let birthday = lifeReference(year: 2020, month: 2, day: 29).date
        let adopted = lifeReference(year: 2021, month: 5, day: 3).date
        var profile = CatProfile(displayName: "テスト猫", keyPhotoLocalIdentifier: "PRIVATE-PHOTO-ID")
        profile.setLifeDates(CatProfileLifeDates(
            birthday: birthday, birthdayIsApproximate: true,
            adoptionDay: adopted, adoptionDayIsApproximate: false
        ), preferredPrimaryKind: .adoptionDay)
        let withoutDates = CatProfile(displayName: "テスト猫", lifeDates: CatProfileLifeDates())
        let transfer = try CatProfileTransfer(profiles: [profile, withoutDates])
        let data = try transfer.encoded()
        let text = String(decoding: data, as: UTF8.self)
        try require(!text.contains("PRIVATE-PHOTO-ID") && !text.contains("keyPhotoLocalIdentifier")
                    && !text.contains("memberships") && !text.contains("photoAlbumLink"),
                    "portable file exposed photo settings")
        let decoded = try CatProfileTransfer.decode(data)
        try require(decoded == transfer, "portable profile dates did not round-trip")
        let empty = CatHouseholdIdentityState.legacyUnscoped(lifeReference: nil, curation: .empty)
        let proposed = try decoded.applying(to: empty, expectedRevision: empty.mutationRevision)
        try require(Set(proposed.profiles.map(\.id)) == Set([profile.id, withoutDates.id]),
                    "same-name cats were merged or assigned new identities")
        let restored = proposed.profiles.first { $0.id == profile.id }!
        try require(restored.resolvedLifeDates == profile.resolvedLifeDates
                    && restored.lifeReference?.kind == .adoptionDay,
                    "both dates, approximation or primary basis changed")
        try require(proposed.profiles.first { $0.id == withoutDates.id }!.resolvedLifeDates == CatProfileLifeDates(),
                    "explicit unset dates were replaced")
        try require(proposed.memberships.isEmpty && proposed.globalExcludedAssets.isEmpty
                    && proposed.profiles.allSatisfy { $0.keyPhotoLocalIdentifier == nil && $0.photoAlbumLink == nil },
                    "import invented photo assignments")
        var withNewPhotoSettings = proposed
        withNewPhotoSettings.setManualMembership(assetLocalIdentifier: "new-photo", profileID: profile.id,
                                                decision: .included, subjectBoundingBox: nil)
        let repeated = try decoded.applying(to: withNewPhotoSettings, expectedRevision: withNewPhotoSettings.mutationRevision)
        try require(repeated == withNewPhotoSettings, "repeat import overwrote photo settings or duplicated profiles")

        // 11/21: a household with a cat takes the file's cats beside it.
        var other = empty
        let resident = CatProfile(displayName: "既存の猫")
        other.upsertProfile(resident)
        let merged = try decoded.applying(to: other, expectedRevision: other.mutationRevision)
        try require(Set(merged.profiles.map(\.id)) == Set([resident.id, profile.id, withoutDates.id]),
                    "import did not add the file's cats beside the existing one")
        try require(merged.profiles.first { $0.id == resident.id } == other.profiles.first { $0.id == resident.id },
                    "import changed an existing profile")
        var full = empty
        for index in 0..<CatProfileLimit.maximumLiving { full.upsertProfile(CatProfile(displayName: "猫\(index)")) }
        let unchanged = try decoded.applying(to: full, expectedRevision: full.mutationRevision)
        try require(unchanged.profiles.count == CatProfileLimit.maximumLiving, "import went past the living limit")
        var deletedProfiles = empty
        deletedProfiles.mode = .profiled
        var selectedAlbum = CatCandidateCurationState.empty
        selectedAlbum.selectSourceAlbum(localIdentifier: "existing-album", assetIdentifiers: ["existing-photo"])
        do {
            _ = try decoded.applying(to: deletedProfiles, expectedRevision: deletedProfiles.mutationRevision,
                                     legacyCuration: selectedAlbum)
            throw VerificationError.failed("import ignored current album settings after profiles were deleted")
        } catch CatProfileTransferError.existingSettings { }
        do {
            _ = try decoded.applying(to: empty, expectedRevision: empty.mutationRevision + 1)
            throw VerificationError.failed("import accepted a stale preview")
        } catch CatProfileTransferError.changedState { }
        var curation = CatCandidateCurationState.empty
        curation.exclude(localIdentifiers: ["excluded-photo"])
        let excluded = CatHouseholdIdentityState.legacyUnscoped(lifeReference: nil, curation: curation)
        do {
            _ = try decoded.applying(to: excluded, expectedRevision: excluded.mutationRevision)
            throw VerificationError.failed("import ignored legacy exclusions")
        } catch CatProfileTransferError.existingSettings { }
        let legacyDate = CatHouseholdIdentityState.legacyUnscoped(
            lifeReference: lifeReference(year: 2022, month: 6, day: 1), curation: .empty)
        do {
            _ = try decoded.applying(to: legacyDate, expectedRevision: legacyDate.mutationRevision)
            throw VerificationError.failed("import replaced an existing legacy date")
        } catch CatProfileTransferError.existingSettings { }

        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["version"] = 99
        do {
            _ = try CatProfileTransfer.decode(JSONSerialization.data(withJSONObject: object))
            throw VerificationError.failed("future transfer version was accepted")
        } catch CatProfileTransferError.unsupportedVersion { }
        object["version"] = 1
        var entries = object["profiles"] as! [[String: Any]]
        object["profiles"] = [entries[0], entries[0]]
        do {
            _ = try CatProfileTransfer.decode(JSONSerialization.data(withJSONObject: object))
            throw VerificationError.failed("duplicate profile UUID was accepted")
        } catch CatProfileTransferError.invalidFile { }
        var dates = entries[0]["dates"] as! [String: Any]
        dates["birthday"] = ["year": 2020, "month": 2, "day": 31]
        entries[0]["dates"] = dates
        object["profiles"] = entries
        do {
            _ = try CatProfileTransfer.decode(JSONSerialization.data(withJSONObject: object))
            throw VerificationError.failed("invalid calendar date was accepted")
        } catch CatProfileTransferError.invalidFile { }
        do {
            _ = try CatProfileTransfer.decode(Data(repeating: 32, count: CatProfileTransfer.maximumBytes + 1))
            throw VerificationError.failed("oversized transfer was accepted")
        } catch CatProfileTransferError.invalidFile { }
    }

    private static func verifiesPortablePhotoTransferNeedsExplicitConfirmation() throws {
        let cat = CatProfile(displayName: "Portable cat")
        let metadata = CatProfileTransfer.PhotoMetadata(creationDate: Date(timeIntervalSince1970: 1234.987),
            width: 2048, height: 1536, mediaType: 1, duration: 0)
        let portableID = UUID()
        let transfer = try CatProfileTransfer(profiles: [cat], photos: [
            .init(id: portableID, metadata: metadata, profileIDs: [cat.id])
        ])
        let encoded = try transfer.encoded()
        let decoded = try CatProfileTransfer.decode(encoded)
        try require(decoded == transfer, "portable metadata did not round trip")
        try require(decoded.photos?.first?.metadata.creationDate == Date(timeIntervalSince1970: 1234),
                    "fractional PhotoKit dates did not normalize to portable seconds")
        let text = String(decoding: encoded, as: UTF8.self)
        try require(!text.contains("localIdentifier") && !text.contains("assetLocalIdentifier"),
                    "portable file contains device-specific photo identifiers")
        let empty = CatHouseholdIdentityState.legacyUnscoped(lifeReference: nil, curation: .empty)
        let profiles = try transfer.applying(to: empty, expectedRevision: empty.mutationRevision)
        let candidates = [CatProfileTransferCandidate(localIdentifier: "new-device-photo", metadata: metadata),
                          CatProfileTransferCandidate(localIdentifier: "ambiguous-other-photo", metadata: metadata)]
        let notConfirmed = try transfer.applyingConfirmedPhotos(to: profiles, selections: [:], candidates: candidates)
        try require(notConfirmed.memberships.isEmpty, "metadata or ambiguous matches assigned automatically")
        let confirmed = try transfer.applyingConfirmedPhotos(to: profiles,
            selections: [portableID: "new-device-photo"], candidates: candidates)
        try require(confirmed.confirmedAssetIdentifiers(for: cat.id) == ["new-device-photo"],
                    "explicit selection did not use the new device identifier")
        let repeated = try transfer.applyingConfirmedPhotos(to: confirmed,
            selections: [portableID: "new-device-photo"], candidates: candidates)
        try require(repeated == confirmed, "repeated confirmation changed existing memberships")
        do {
            _ = try transfer.applyingConfirmedPhotos(to: profiles,
                selections: [portableID: "new-device-photo"], candidates: [])
            throw VerificationError.failed("missing or revoked photo was assigned")
        } catch CatProfileTransferError.changedState { }
        let secondID = UUID()
        let duplicates = try CatProfileTransfer(profiles: [cat], photos: [
            .init(id: portableID, metadata: metadata, profileIDs: [cat.id]),
            .init(id: secondID, metadata: metadata, profileIDs: [cat.id])
        ])
        do {
            _ = try duplicates.applyingConfirmedPhotos(to: profiles,
                selections: [portableID: "new-device-photo", secondID: "new-device-photo"], candidates: candidates)
            throw VerificationError.failed("two portable rows claimed the same local asset")
        } catch CatProfileTransferError.invalidFile { }
        var excluded = profiles
        excluded.setManualMembership(assetLocalIdentifier: "new-device-photo", profileID: cat.id, decision: .excluded)
        do {
            _ = try transfer.applyingConfirmedPhotos(to: excluded,
                selections: [portableID: "new-device-photo"], candidates: candidates)
            throw VerificationError.failed("import overwrote an existing exclusion")
        } catch CatProfileTransferError.existingSettings { }
        try require(excluded.membershipDecision(for: "new-device-photo", profileID: cat.id) == .excluded,
                    "failed import changed its input")
    }

    /// 11/21 (1121n): the preview lists what `applying` really adds: a cat
    /// already here is not changed, a cat over the living limit stays out.
    private static func verifiesImportPlanSaysWhatApplyingDoes() throws {
        let here = CatProfile(displayName: "いる猫")
        var current = CatHouseholdIdentityState.legacyUnscoped(lifeReference: nil, curation: .empty)
        current.upsertProfile(here)
        for index in 1..<CatProfileLimit.maximumLiving { current.upsertProfile(CatProfile(displayName: "猫\(index)")) }
        var changedHere = here
        changedHere.displayName = "別の名前"
        let newcomer = CatProfile(displayName: "来る猫")
        let transfer = try CatProfileTransfer(profiles: [changedHere, newcomer])
        let plan = transfer.importPlan(into: current)
        try require(plan.added.isEmpty && plan.alreadyHere.map(\.id) == [here.id] && plan.leftOut.map(\.id) == [newcomer.id],
                    "a full household adds nothing; the cat here is not changed")
        let applied = try transfer.applying(to: current, expectedRevision: current.mutationRevision)
        try require(applied == current, "applying did more than the plan said")
        var roomy = CatHouseholdIdentityState.legacyUnscoped(lifeReference: nil, curation: .empty)
        roomy.upsertProfile(here)
        let roomyPlan = transfer.importPlan(into: roomy)
        try require(roomyPlan.added.map(\.id) == [newcomer.id] && roomyPlan.leftOut.isEmpty, "the new cat comes")
        let roomyApplied = try transfer.applying(to: roomy, expectedRevision: roomy.mutationRevision)
        try require(Set(roomyApplied.profiles.map(\.id)) == [here.id, newcomer.id]
                    && roomyApplied.profiles.first { $0.id == here.id }?.displayName == "いる猫",
                    "applying followed the plan")
    }

    private static func verifiesProfileTransferCommitConflict() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("identity.json")
        let store = try CatHouseholdIdentityStore(stateURL: url)
        let original = try await store.loadOrMigrate(legacyLifeReference: nil, legacyCuration: .empty)
        let transfer = try CatProfileTransfer(profiles: [CatProfile(displayName: "引き継ぐ猫")])
        let pending = try transfer.applying(to: original, expectedRevision: original.mutationRevision)
        let afterPreview = try await store.load()
        try require(afterPreview == original, "preview changed stored state")
        var concurrent = original
        concurrent.upsertProfile(CatProfile(displayName: "先に登録した猫"))
        let newest = try await store.save(concurrent, expectedMutationRevision: original.mutationRevision)
        do {
            _ = try await store.save(pending, expectedMutationRevision: original.mutationRevision)
            throw VerificationError.failed("stale import overwrote concurrent data")
        } catch CatHouseholdIdentityRevisionError.stale(_, _) { }
        let afterConflict = try await store.load()
        try require(afterConflict == newest, "failed import changed stored data")
    }

    private static func lifeReference(
        year: Int,
        month: Int,
        day: Int
    ) -> CatLifeReference {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        ))!
        return CatLifeReference(kind: .birthday, date: CatLifeDate(date: date, calendar: calendar)!)
    }

    private static func fixedUUID(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw VerificationError.failed(message) }
    }
}

private enum VerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}
