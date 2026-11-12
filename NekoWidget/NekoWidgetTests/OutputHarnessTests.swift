import XCTest
import UIKit
@testable import NekoWidget

final class OutputHarnessTests: XCTestCase {
    @MainActor
    func testRetainedWorkExceptionDoesNotGrantCurrentPlus() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let arrival = now.addingTimeInterval(-100)
        let history = PlusWorkHistory(periods: [.init(originalID: 1,
            start: arrival.addingTimeInterval(-10), end: arrival.addingTimeInterval(10))])
        let expired = MembershipAccessContext(enforcementEnabled: true, personal: .inactive)
        XCTAssertEqual(expired.workDecision(arrival: arrival, history: history, now: now), .allowed)
        XCTAssertEqual(expired.workDecision(arrival: now, history: history, now: now), .membershipRequired)
        XCTAssertEqual(expired.workDecision(arrival: arrival, history: nil, now: now), .verificationRequired)
        XCTAssertEqual(expired.decision(for: .createOwnWindow, now: now), .membershipRequired)
        XCTAssertEqual(expired.decision(for: .createPersonalMemo, now: now), .membershipRequired)
        let active = MembershipAccessContext(enforcementEnabled: true,
            personal: .verified(validUntil: now.addingTimeInterval(60)))
        XCTAssertEqual(active.workDecision(arrival: arrival.addingTimeInterval(-1000), history: nil, now: now), .allowed)
        let revoked = PlusWorkHistory(periods: [.init(originalID: 1,
            start: arrival.addingTimeInterval(-10), end: now, revoked: true)])
        XCTAssertEqual(expired.workDecision(arrival: arrival, history: revoked, now: now), .membershipRequired)
    }

    @MainActor
    func testEligibleTrialOfferStatesStoreKitDerivedEndDate() {
        let calendar = Calendar.nekoGregorian
        let end = calendar.date(from: DateComponents(year: 2027, month: 1, day: 8))!
        let eligible = MembershipOfferPresentation.monthly(displayPrice: "¥980", trialPeriod: "14日間",
            isPreview: true, trialEnd: end)
        XCTAssertEqual(eligible.renewalText, "1月8日まで無料。そのあと 月額¥980で、1か月ごとに自動で更新されます。次の更新日の24時間前までに解約すれば、次の料金はかかりません。")
        XCTAssertEqual(eligible.purchaseTitle, "14日間無料で試す")
        XCTAssertEqual(eligible.afterTrialText, "その後 月額¥980（自動更新）")
        let ineligible = MembershipOfferPresentation.monthly(displayPrice: "¥980", trialPeriod: nil,
            isPreview: true, trialEnd: end)
        XCTAssertNil(ineligible.trialText)
        XCTAssertFalse(ineligible.renewalText.contains("まで無料"))
    }

    @MainActor
    func testGroupPhotoReplayDoesNotCreateANewLocalPhoto() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GroupWindowLocalPhotoStore(root: root)
        let jpeg = Data([1, 2, 3])
        func entry(_ id: String, at time: TimeInterval) -> GroupWindowLocalPhotoStore.Entry {
            .init(id: id, senderParticipantID: "sender", senderDisplayName: "合成",
                  createdAt: Date(timeIntervalSince1970: time), isHidden: false, isOwn: false)
        }
        try await store.save(entry("original", at: 1), jpeg: jpeg, windowID: "window", verifiedMomentID: "sender-photo-id")
        let reopened = GroupWindowLocalPhotoStore(root: root)
        try await reopened.save(entry("relay-replay", at: 2), jpeg: jpeg, windowID: "window", verifiedMomentID: "sender-photo-id")
        let beforeRemoval = await reopened.entries(windowID: "window")
        XCTAssertEqual(beforeRemoval.map(\.id), ["original"])
        try await reopened.remove(photoID: "original", windowID: "window")
        try await reopened.save(entry("after-removal", at: 3), jpeg: jpeg, windowID: "window", verifiedMomentID: "sender-photo-id")
        try await reopened.save(entry("different-send", at: 4), jpeg: jpeg, windowID: "window", verifiedMomentID: "different-sender-id")
        try await reopened.save(entry("other-window", at: 5), jpeg: jpeg, windowID: "other-window", verifiedMomentID: "sender-photo-id")
        let current = await reopened.entries(windowID: "window")
        let other = await reopened.entries(windowID: "other-window")
        XCTAssertEqual(current.map(\.id), ["different-send"])
        XCTAssertEqual(other.map(\.id), ["other-window"])
    }

    @MainActor
    func testHostModuleAndSyntheticImageRoundTrip() throws {
        // Establish the app-hosted renderer test harness, not a product snapshot.
        XCTAssertFalse(EvacuationDestination().canConfirm)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            UIColor.black.setFill()
            UIBezierPath(ovalIn: CGRect(x: 8, y: 8, width: 16, height: 16)).fill()
        }
        let decoded = try XCTUnwrap(UIImage(data: XCTUnwrap(image.pngData())))
        XCTAssertEqual(decoded.cgImage?.width, 32)
        XCTAssertEqual(decoded.cgImage?.height, 32)
    }
}
