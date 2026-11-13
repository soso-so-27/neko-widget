import XCTest
@testable import NekoWidget

/// Build 365 follow-ups (11/13): a linked album counts in the 写真 tab's cat
/// filter, the album list's order, and 「○○を探しています」 only while searching.
final class AlbumLinkFollowupsTests: XCTestCase {
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

    func testAssignmentsCountTheLinkedAlbum() {
        var (state, ids) = household(["mugi", "sora"])
        let (mugi, sora) = (ids[0], ids[1])
        state.setProfilePhotoAlbumLink(
            profileID: mugi, localIdentifier: "album",
            assetLocalIdentifiers: ["a1", "a2", "a3", "shared"]
        )
        state.setManualMembership(assetLocalIdentifier: "m1", profileID: mugi, decision: .included)
        state.setManualMembership(assetLocalIdentifier: "a2", profileID: mugi, decision: .excluded)
        state.setManualMembership(assetLocalIdentifier: "shared", profileID: sora, decision: .included)
        state.setGloballyExcluded(true, assetLocalIdentifiers: ["a3"])

        let sets = state.effectiveAssetIdentifiersByProfile(detectedCatAssetIdentifiers: [])
        let assignments = CatHouseholdIdentityState.profileIdentifiersByAsset(sets)

        XCTAssertEqual(assignments["a1"], [mugi.uuidString])
        XCTAssertEqual(assignments["m1"], [mugi.uuidString])
        XCTAssertNil(assignments["a2"], "「この子ではない」 wins over the album")
        XCTAssertNil(assignments["a3"], "a household exclusion wins")
        XCTAssertEqual(assignments["shared"], [mugi.uuidString, sora.uuidString])
        // The filter's count is the cat page's count.
        XCTAssertEqual(assignments.filter { $0.value.contains(mugi.uuidString) }.count,
                       state.confirmedAssetIdentifiers(for: mugi).count)
    }

    func testAssignmentsCarryTheSingleCatRule() {
        var (state, ids) = household(["mugi"])
        state.setProfilePhotoAlbumLink(profileID: ids[0], localIdentifier: "album",
                                       assetLocalIdentifiers: ["album-only"])
        let sets = state.effectiveAssetIdentifiersByProfile(detectedCatAssetIdentifiers: ["detected"])
        let assignments = CatHouseholdIdentityState.profileIdentifiersByAsset(sets)
        XCTAssertEqual(Set(assignments.keys), ["album-only", "detected"])
        XCTAssertTrue(CatHouseholdIdentityState.profileIdentifiersByAsset([:]).isEmpty)
    }

    func testAlbumListHidesEmptyAlbumsAndPutsTheLinkedOneFirst() {
        let albums = [
            CatProfilePhotoAlbumOptionPresentation(identifier: "scan", title: "Scan", accessiblePhotoCount: 0),
            CatProfilePhotoAlbumOptionPresentation(identifier: "few", title: "Few", accessiblePhotoCount: 3),
            CatProfilePhotoAlbumOptionPresentation(identifier: "many", title: "Many", accessiblePhotoCount: 59),
            CatProfilePhotoAlbumOptionPresentation(identifier: "cat", title: "Cat", accessiblePhotoCount: 10),
            CatProfilePhotoAlbumOptionPresentation(identifier: "tie", title: "Tie", accessiblePhotoCount: 3)
        ]
        XCTAssertEqual(CatProfilePhotoAlbumLinkOrder.shown(albums, linkedIdentifier: nil).map(\.identifier),
                       ["many", "cat", "few", "tie"])
        XCTAssertEqual(CatProfilePhotoAlbumLinkOrder.shown(albums, linkedIdentifier: "few").map(\.identifier),
                       ["few", "many", "cat", "tie"])
        // A linked album that became empty stays, so it can be unlinked.
        XCTAssertEqual(CatProfilePhotoAlbumLinkOrder.shown(albums, linkedIdentifier: "scan").first?.identifier,
                       "scan")
    }

    func testSearchingNeedsAFlyerOrAnOffice() throws {
        var draft = LostCatDraft()
        draft.lastSeenNear = "公園"
        draft.lastSeenAt = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(draft.hasIncident)
        XCTAssertFalse(draft.isSearching, "a place typed in to try the flyer is a draft")

        draft.flyerMadeAt = Date(timeIntervalSince1970: 10)
        XCTAssertTrue(draft.isSearching)

        draft.foundMessage = "見つかりました"
        XCTAssertFalse(draft.isSearching, "a written 「見つかりました」 ends the search")
        draft.foundMessage = ""
        XCTAssertTrue(draft.isSearching)

        let ended = draft.endingIncident()
        XCTAssertNil(ended.flyerMadeAt)
        XCTAssertFalse(ended.isSearching)

        var office = LostCatDraft()
        office.incidentLog.setContacted(.police, on: Date(timeIntervalSince1970: 0),
                                        now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(office.isSearching)
    }

    func testOldDraftsDecodeAndNewOnesRoundTrip() throws {
        let old = Data(#"{"schemaVersion":1,"name":"mugi","features":"","collar":"","approachAdvice":"","contact":"","lastSeenNear":"park","updatedAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(LostCatDraft.self, from: old)
        XCTAssertNil(decoded.flyerMadeAt)
        XCTAssertFalse(decoded.isSearching)
        XCTAssertEqual(decoded.schemaVersion, LostCatDraft.schemaVersion)

        var draft = decoded
        draft.flyerMadeAt = Date(timeIntervalSinceReferenceDate: 100)
        let again = try JSONDecoder().decode(LostCatDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(again, draft)
    }
}
