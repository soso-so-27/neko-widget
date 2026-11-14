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
}
