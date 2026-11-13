import XCTest
@testable import NekoWidget

/// The single-cat rule (11/13): with exactly one cat profile every detected
/// cat photo counts as that cat's photo, derived at read time only.
final class SingleCatPhotosTests: XCTestCase {
    private let detected: Set<String> = ["a", "b", "c", "d"]

    private func household(_ names: [String]) -> (CatHouseholdIdentityState, [UUID]) {
        var state = CatHouseholdIdentityState(
            mode: .profiled, profiles: [], memberships: [],
            globalExcludedAssets: [], legacyUnscoped: nil
        )
        var ids: [UUID] = []
        for name in names {
            let profile = CatProfile(displayName: name)
            state.upsertProfile(profile)
            ids.append(profile.id)
        }
        return (state, ids)
    }

    func testOnlyCatGetsEveryDetectedPhotoWithoutRecords() {
        var (state, ids) = household(["mugi"])
        let cat = ids[0]
        state.setManualMembership(assetLocalIdentifier: "manual", profileID: cat, decision: .included)
        state.setManualMembership(assetLocalIdentifier: "b", profileID: cat, decision: .excluded)
        state.setGloballyExcluded(true, assetLocalIdentifiers: ["c"])
        let membershipCount = state.memberships.count

        XCTAssertEqual(state.singleCatProfileID, cat)
        XCTAssertEqual(
            state.effectiveAssetIdentifiers(for: cat, detectedCatAssetIdentifiers: detected),
            ["a", "d", "manual"]
        )
        XCTAssertEqual(state.effectiveAssetIdentifiersByProfile(detectedCatAssetIdentifiers: detected)[cat],
                       ["a", "d", "manual"])
        XCTAssertEqual(state.effectiveProfileIDs(for: "a", isDetectedCatPhoto: true), [cat])
        XCTAssertEqual(state.effectiveProfileIDs(for: "b", isDetectedCatPhoto: true), [])
        XCTAssertTrue(state.isSingleCatDerivedAsset("a", profileID: cat, isDetectedCatPhoto: true))
        XCTAssertFalse(state.isSingleCatDerivedAsset("b", profileID: cat, isDetectedCatPhoto: true))
        // Derived only: the explicit ledger is unchanged.
        XCTAssertEqual(state.confirmedAssetIdentifiers(for: cat), ["manual"])
        XCTAssertEqual(state.memberships.count, membershipCount)
    }

    func testZeroOrSeveralProfilesAreUnchanged() {
        let (empty, _) = household([])
        XCTAssertNil(empty.singleCatProfileID)

        var (state, ids) = household(["mugi", "ame"])
        state.setManualMembership(assetLocalIdentifier: "a", profileID: ids[0], decision: .included)
        XCTAssertNil(state.singleCatProfileID)
        XCTAssertEqual(state.effectiveAssetIdentifiers(for: ids[0], detectedCatAssetIdentifiers: detected), ["a"])
        XCTAssertEqual(state.effectiveAssetIdentifiers(for: ids[1], detectedCatAssetIdentifiers: detected), [])
        XCTAssertEqual(state.effectiveProfileIDs(for: "b", isDetectedCatPhoto: true), [])
    }

    func testSecondProfileKeepsOnlyTheShownPhoto() {
        var (state, ids) = household(["mugi"])
        let cat = ids[0]
        state.pinSingleCatPhotoBeforeAnotherProfile(shownPhotoIdentifier: "d")
        XCTAssertEqual(state.membershipDecision(for: "d", profileID: cat), .included)
        XCTAssertEqual(state.memberships.count, 1)
        XCTAssertNil(state.profiles[0].keyPhotoLocalIdentifier)

        state.upsertProfile(CatProfile(displayName: "ame"))
        XCTAssertEqual(state.effectiveAssetIdentifiers(for: cat, detectedCatAssetIdentifiers: detected), ["d"])
    }

    func testPinNeverReincludesAnExcludedPhoto() {
        var (state, ids) = household(["mugi"])
        state.setManualMembership(assetLocalIdentifier: "a", profileID: ids[0], decision: .excluded)
        state.pinSingleCatPhotoBeforeAnotherProfile(shownPhotoIdentifier: "a")
        XCTAssertEqual(state.membershipDecision(for: "a", profileID: ids[0]), .excluded)
    }
}
