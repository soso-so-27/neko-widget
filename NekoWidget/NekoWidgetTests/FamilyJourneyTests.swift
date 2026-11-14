import XCTest
@testable import NekoWidget

/// 11/14: the family journey (design review A1–A6). Pure decisions only: no
/// network, no purchase, no PhotoKit. The screens are pinned by
/// ci/test-family-journey.py.
@MainActor
final class FamilyJourneyTests: XCTestCase {
    // MARK: - A3: buying Plus goes on with what was asked

    func testOnlyACompletedPurchaseOrRestoreGoesOn() {
        XCTAssertTrue(PlusPurchaseContinuation.continues(after: .completed))
        let stops: [MembershipOfferActionResult] = [
            .cancelled, .waiting, .nothingToRestore, .unavailable, .failed, .offerChanged,
            .restoreFailed(.appleConfirmation),
        ]
        for result in stops {
            XCTAssertFalse(PlusPurchaseContinuation.continues(after: result), "\(result)")
        }
    }

    func testWindowIsMadeWithTheNamesAlreadyTyped() {
        XCTAssertTrue(PlusPurchaseContinuation.createsWindow(
            name: "実家のまど", ownerName: "お母さん", namesFit: true, isWorking: false, alreadyCreated: false))
        // An emptied name, a name too long, a making already running, or a
        // window already made: nothing more is made.
        XCTAssertFalse(PlusPurchaseContinuation.createsWindow(
            name: "", ownerName: "お母さん", namesFit: true, isWorking: false, alreadyCreated: false))
        XCTAssertFalse(PlusPurchaseContinuation.createsWindow(
            name: "実家のまど", ownerName: "", namesFit: true, isWorking: false, alreadyCreated: false))
        XCTAssertFalse(PlusPurchaseContinuation.createsWindow(
            name: "実家のまど", ownerName: "お母さん", namesFit: false, isWorking: false, alreadyCreated: false))
        XCTAssertFalse(PlusPurchaseContinuation.createsWindow(
            name: "実家のまど", ownerName: "お母さん", namesFit: true, isWorking: true, alreadyCreated: false))
        XCTAssertFalse(PlusPurchaseContinuation.createsWindow(
            name: "実家のまど", ownerName: "お母さん", namesFit: true, isWorking: false, alreadyCreated: true))
    }

    func testFamilyPayerIsTakenOverOnlyWhenTheFamilyAllowsIt() {
        XCTAssertTrue(PlusPurchaseContinuation.claimsFamilyPayer(bought: true, canClaim: true, handoverPending: false))
        XCTAssertFalse(PlusPurchaseContinuation.claimsFamilyPayer(bought: false, canClaim: true, handoverPending: false))
        // The family has not seen the new Plus yet: the section offers its check.
        XCTAssertFalse(PlusPurchaseContinuation.claimsFamilyPayer(bought: true, canClaim: false, handoverPending: false))
        XCTAssertFalse(PlusPurchaseContinuation.claimsFamilyPayer(bought: true, canClaim: true, handoverPending: true))
    }

    // MARK: - A5: one press makes and sends the family invitation

    func testOnePressMakesTheLinkAndASecondPressWhileMakingDoesNothing() {
        XCTAssertEqual(FamilyInviteSendTap.action(isCreating: false, hasInvitation: false), .create)
        XCTAssertEqual(FamilyInviteSendTap.action(isCreating: true, hasInvitation: false), .ignore)
        XCTAssertEqual(FamilyInviteSendTap.action(isCreating: true, hasInvitation: true), .ignore)
        // Made already (the share sheet was closed): the same link is sent again.
        XCTAssertEqual(FamilyInviteSendTap.action(isCreating: false, hasInvitation: true), .share)
    }

    // MARK: - A6: the 写真 tab for someone in a まど with no cat photos

    func testEmptyPhotosPointToTheWindowsOnlyForAMemberAfterTheScan() {
        XCTAssertTrue(PhotosEmptyStatePolicy.pointsToWindows(scanFinished: true, catPhotoCount: 0, isWindowMember: true))
        XCTAssertFalse(PhotosEmptyStatePolicy.pointsToWindows(scanFinished: true, catPhotoCount: 0, isWindowMember: false))
        XCTAssertFalse(PhotosEmptyStatePolicy.pointsToWindows(scanFinished: false, catPhotoCount: 0, isWindowMember: true))
        XCTAssertFalse(PhotosEmptyStatePolicy.pointsToWindows(scanFinished: true, catPhotoCount: 3, isWindowMember: true))
        XCTAssertEqual(PhotosEmptyStatePolicy.windowMemberLine, "まどに届いた写真は、まどのタブで見られます。")
        XCTAssertEqual(PhotosEmptyStatePolicy.openWindowsAction, "まどを開く")
    }

    // MARK: - A2 / A4: words

    func testJoinedWindowIsNamedFromTheInvitation() {
        let model = GroupJoinModel(client: nil, invitationID: "invitation",
                                   context: GroupInvitationContext(windowName: "実家のまど", inviterName: "お母さん"),
                                   windowID: "window")
        XCTAssertEqual(model.placementWindowName, "実家のまど")
        XCTAssertEqual(model.windowID, "window")
        XCTAssertEqual(GroupWindowPresentation.placeOnHomeScreenAction, "ホーム画面に置く")
        XCTAssertEqual(GroupWindowPresentation.invitationLifetimeCaption, "24時間使えます。")
    }
}
