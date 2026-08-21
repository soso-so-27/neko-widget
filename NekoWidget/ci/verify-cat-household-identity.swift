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
        try verifiesNormalizationSafety()
        try verifiesRevisionPolicyRejectsStaleState()
        try verifiesCodableRoundTrip()
        try await verifiesProtectedAtomicStore()
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
        state.setGloballyExcluded(false, assetLocalIdentifiers: ["two-cats"])
        try require(!state.isGloballyExcluded("two-cats"), "global restore failed")
        try require(
            state.membershipDecision(for: "two-cats", profileID: firstID) == .unknown
                && state.membershipDecision(for: "two-cats", profileID: secondID) == .unknown,
            "global restore silently reassigned the photo"
        )
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
            lifeReferenceIsApproximate: true
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
