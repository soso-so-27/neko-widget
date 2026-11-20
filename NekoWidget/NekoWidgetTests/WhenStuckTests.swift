import XCTest
@testable import NekoWidget

/// 11/14 「困ったとき」: the Widget's empty words and the alert's sentence
/// name only a cause that is known.
final class WhenStuckTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "when-stuck-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: A1 — personal Widget

    func testPersonalWidgetStatesByCause() {
        XCTAssertEqual(WidgetStuckState.personal(status: nil, unreadable: false), .preparing)
        XCTAssertEqual(WidgetStuckState.personal(status: nil, unreadable: true), .unreadable)
        XCTAssertEqual(WidgetStuckState.personal(status: .photoAccessNeeded, unreadable: false), .photoAccessNeeded)
        XCTAssertEqual(WidgetStuckState.personal(status: .photoAccessNeeded, unreadable: true), .photoAccessNeeded)
        XCTAssertEqual(WidgetStuckState.personal(status: .noCatPhotos, unreadable: false), .noCatPhotos)
    }

    func testPersonalWidgetWords() {
        let expected: [(WidgetStuckState, String, String)] = [
            (.preparing, "写真を準備しています", "アプリを開くと始まります"),
            (.photoAccessNeeded, "写真の許可が必要です", "タップしてアプリを開く"),
            (.noCatPhotos, "猫の写真がまだありません", "猫の写真を撮ると、ここに出ます"),
            (.unreadable, "いまは出せません", "アプリを開くと、また出ます"),
            (.revealFailed, "晴らせませんでした", "タップしてアプリを開く"),
            (.catRemoved, "この子の写真は出せなくなりました", "長押しして、別の写真を選んでください"),
        ]
        for (state, title, subtitle) in expected {
            XCTAssertEqual(state.title, title)
            XCTAssertEqual(state.subtitle, subtitle)
        }
    }

    func testLibraryStatusIsOptionalAndWritesOnlyChanges() {
        XCTAssertNil(WidgetLibraryStatus.read(from: defaults))
        XCTAssertTrue(WidgetLibraryStatus.write(.noCatPhotos, to: defaults))
        XCTAssertFalse(WidgetLibraryStatus.write(.noCatPhotos, to: defaults))
        XCTAssertEqual(WidgetLibraryStatus.read(from: defaults), .noCatPhotos)
        XCTAssertTrue(WidgetLibraryStatus.write(nil, to: defaults))
        XCTAssertNil(defaults.object(forKey: WidgetLibraryStatus.defaultsKey))
        // An unknown value from a newer app is ignored, not misread.
        defaults.set("somethingNew", forKey: WidgetLibraryStatus.defaultsKey)
        XCTAssertNil(WidgetLibraryStatus.read(from: defaults))
        XCTAssertNil(WidgetLibraryStatus.read(from: nil))
    }

    // MARK: A2 — a reveal that was not saved

    func testRevealFailureMatchesOnlyThatSelectionUntilCleared() {
        XCTAssertFalse(CloudyWindowRevealFailure.matches(scopeID: "personal-library", selectionID: "a", in: defaults))
        CloudyWindowRevealFailure.record(scopeID: "personal-library", selectionID: "a", in: defaults)
        XCTAssertTrue(CloudyWindowRevealFailure.matches(scopeID: "personal-library", selectionID: "a", in: defaults))
        XCTAssertFalse(CloudyWindowRevealFailure.matches(scopeID: "personal-library", selectionID: "b", in: defaults))
        XCTAssertFalse(CloudyWindowRevealFailure.matches(scopeID: "personal-cat:x", selectionID: "a", in: defaults))
        XCTAssertTrue(CloudyWindowRevealFailure.clear(in: defaults))
        XCTAssertFalse(CloudyWindowRevealFailure.clear(in: defaults))
        XCTAssertFalse(CloudyWindowRevealFailure.matches(scopeID: "personal-library", selectionID: "a", in: defaults))
    }

    // MARK: A3 — the alert's sentence

    @MainActor
    func testUnknownCausesGetThePlainFallback() {
        let fallback = "うまくいきませんでした。もう一度お試しください。"
        XCTAssertEqual(AppViewModel.userFacingMessage(for: CocoaError(.fileWriteUnknown)), fallback)
        XCTAssertEqual(AppViewModel.userFacingMessage(for: NSError(domain: "x", code: 1)), fallback)
        XCTAssertEqual(AppViewModel.userFacingMessage(for: NekoWidgetError.albumCreationFailed),
                       "写真アルバムを更新できませんでした。もう一度お試しください。")
    }

    @MainActor
    func testKnownCausesKeepTheirOwnSentence() {
        XCTAssertEqual(AppViewModel.userFacingMessage(for: NekoWidgetError.appGroupUnavailable("group")),
                       "データを保存できませんでした。アプリを開き直しても変わらないときは、設定の「お問い合わせ」からお知らせください。")
        XCTAssertTrue(AppViewModel.userFacingMessage(for: NekoWidgetError.photoAccessDenied).contains("写真へのアクセス"))
        XCTAssertTrue(AppViewModel.userFacingMessage(for: NekoWidgetError.exportFailed).contains("空き容量"))
        XCTAssertTrue(AppViewModel.userFacingMessage(for: URLError(.notConnectedToInternet)).contains("インターネット"))
        // Photo access and storage are named only by the errors that know them.
        for error: Error in [NekoWidgetError.appGroupUnavailable("group"), NekoWidgetError.albumCreationFailed,
                             CocoaError(.fileWriteUnknown), URLError(.timedOut)] {
            let message = AppViewModel.userFacingMessage(for: error)
            XCTAssertFalse(message.contains("写真へのアクセス"), message)
            XCTAssertFalse(message.contains("空き容量"), message)
            XCTAssertFalse(message.contains("App Store"), message)
        }
    }

    // MARK: 11/20 — dead ends

    /// An automatic save that fails while offline stays 「保存中…」 however
    /// long it lasts; one that fails online for 6 hours (5 times or more),
    /// or gets an unusable server reply for 30 minutes, is shown.
    func testSaveFailureIsShownOnlyAfterALongOnlineStreak() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var offline = AppRecordFailureStreak()
        for minute in stride(from: 0, through: 72 * 60, by: 30) {
            offline.record(online: false, serverAnswered: false, at: start.addingTimeInterval(Double(minute) * 60))
        }
        XCTAssertFalse(offline.needsAttention(now: start.addingTimeInterval(72 * 3600)))

        var online = AppRecordFailureStreak()
        for hour in 0..<6 { online.record(online: true, serverAnswered: false, at: start.addingTimeInterval(Double(hour) * 3600)) }
        XCTAssertFalse(online.needsAttention(now: start.addingTimeInterval(5 * 3600)), "not yet 6 hours")
        online.record(online: true, serverAnswered: false, at: start.addingTimeInterval(6 * 3600))
        XCTAssertTrue(online.needsAttention(now: start.addingTimeInterval(6 * 3600)))
        // Offline again: quiet again, without forgetting the streak.
        online.record(online: false, serverAnswered: false, at: start.addingTimeInterval(7 * 3600))
        XCTAssertFalse(online.needsAttention(now: start.addingTimeInterval(7 * 3600)))
        online.record(online: true, serverAnswered: false, at: start.addingTimeInterval(8 * 3600))
        XCTAssertTrue(online.needsAttention(now: start.addingTimeInterval(8 * 3600)))

        // Two failures far apart are not enough on their own.
        var few = AppRecordFailureStreak()
        few.record(online: true, serverAnswered: false, at: start)
        few.record(online: true, serverAnswered: false, at: start.addingTimeInterval(10 * 3600))
        XCTAssertFalse(few.needsAttention(now: start.addingTimeInterval(10 * 3600)))

        var answered = AppRecordFailureStreak()
        for minute in [0, 5, 15, 25] {
            answered.record(online: true, serverAnswered: true, at: start.addingTimeInterval(Double(minute) * 60))
        }
        XCTAssertFalse(answered.needsAttention(now: start.addingTimeInterval(25 * 60)))
        answered.record(online: true, serverAnswered: true, at: start.addingTimeInterval(30 * 60))
        XCTAssertTrue(answered.needsAttention(now: start.addingTimeInterval(30 * 60)))
        // A connection failure in between starts the reply run again.
        var broken = AppRecordFailureStreak()
        for minute in [0, 10, 20] { broken.record(online: true, serverAnswered: true, at: start.addingTimeInterval(Double(minute) * 60)) }
        broken.record(online: true, serverAnswered: false, at: start.addingTimeInterval(25 * 60))
        for minute in [30, 40] { broken.record(online: true, serverAnswered: true, at: start.addingTimeInterval(Double(minute) * 60)) }
        XCTAssertFalse(broken.needsAttention(now: start.addingTimeInterval(40 * 60)))
    }

    /// A showcase tap lasts for the launch it caused, never for days.
    func testShowcaseLaunchRequestHasAShortLifetime() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertFalse(ShowcaseLaunchRequest.isLive(requestedAt: nil, now: now), "an old value has no time")
        XCTAssertTrue(ShowcaseLaunchRequest.isLive(requestedAt: now, now: now))
        XCTAssertTrue(ShowcaseLaunchRequest.isLive(requestedAt: now.addingTimeInterval(-ShowcaseLaunchRequest.lifetime), now: now))
        XCTAssertFalse(ShowcaseLaunchRequest.isLive(requestedAt: now.addingTimeInterval(-ShowcaseLaunchRequest.lifetime - 1), now: now))
        XCTAssertFalse(ShowcaseLaunchRequest.isLive(requestedAt: now.addingTimeInterval(-3 * 24 * 3600), now: now))
        XCTAssertFalse(ShowcaseLaunchRequest.isLive(requestedAt: now.addingTimeInterval(3600), now: now))
        XCTAssertLessThanOrEqual(ShowcaseLaunchRequest.lifetime, 120)
    }

    /// A group window's Widget says 「このまどは終わりました」 only for a window
    /// the app saw go; a copy not written yet is "being prepared".
    func testGroupWidgetEndedOnlyWhenTheAppSawItGo() {
        typealias Cache = GroupWidgetCache
        // A reinstall or a lost copy: nothing recorded at all.
        XCTAssertEqual(Cache.missingEntry(windowID: "w1", listedWindowIDs: nil, endedWindowIDs: nil), .notYetKnown)
        // Still listed by the relay, its photo not written yet.
        XCTAssertEqual(Cache.missingEntry(windowID: "w1", listedWindowIDs: ["w1", "w2"], endedWindowIDs: nil), .notYetKnown)
        // No longer listed: ended.
        XCTAssertEqual(Cache.missingEntry(windowID: "w3", listedWindowIDs: ["w1"], endedWindowIDs: nil), .ended)
        // Left or ended here, even while the relay still lists it as closed.
        XCTAssertEqual(Cache.missingEntry(windowID: "w1", listedWindowIDs: nil, endedWindowIDs: ["w1"]), .ended)
        XCTAssertEqual(Cache.missingEntry(windowID: "w1", listedWindowIDs: ["w1"], endedWindowIDs: ["w1"]), .ended)
        XCTAssertEqual(Cache.missingEntry(windowID: "w2", listedWindowIDs: nil, endedWindowIDs: ["w1"]), .notYetKnown)
    }
}
