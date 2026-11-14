import XCTest
@testable import NekoWidget

/// What VoiceOver reads and offers (11/14 review: 読み上げと大きい文字):
/// turning a book's pages and a まど tile. Synthetic values only.
final class AccessibilitySpeechTests: XCTestCase {
    func testBookPageNumberReadsThePageAndTurnsWithinTheBook() {
        typealias Access = BookPageAccess
        XCTAssertEqual(Access.label, "ページをめくる")
        XCTAssertEqual(Access.value(index: 2, count: 8), "8ページ中3ページ目")
        XCTAssertEqual(Access.turned(2, count: 8, forward: true), 3)
        XCTAssertEqual(Access.turned(2, count: 8, forward: false), 1)
        // Never past either end.
        XCTAssertEqual(Access.turned(7, count: 8, forward: true), 7)
        XCTAssertEqual(Access.turned(0, count: 8, forward: false), 0)
        XCTAssertEqual(Access.turned(0, count: 0, forward: true), 0)
        XCTAssertEqual([Access.next, Access.previous], ["次のページ", "前のページ"])
    }

    func testWindowTileSaysWhoSentItAndWhen() {
        typealias Speech = GroupPhotoTileSpeech
        XCTAssertEqual(Speech.photo(sender: "ママ", isOwn: false, day: "3日前", reported: false, hidden: false),
                       "ママからの写真、3日前")
        XCTAssertEqual(Speech.photo(sender: "ゆい", isOwn: true, day: "今日", reported: false, hidden: false),
                       "自分が届けた写真、今日")
        XCTAssertEqual(Speech.photo(sender: " ", isOwn: false, day: "10月19日", reported: true, hidden: true),
                       "名前のない人からの写真、10月19日、通報した写真")
        XCTAssertEqual(Speech.photo(sender: "パパ", isOwn: false, day: "昨日", reported: false, hidden: true),
                       "パパからの写真、昨日、表示していない写真")
    }

    func testWindowTileHeartSaysWhetherThisPersonSentOne() {
        typealias Speech = GroupPhotoTileSpeech
        XCTAssertEqual(Speech.heart(mine: false, canHeart: true), "ハートを送る")
        XCTAssertEqual(Speech.heart(mine: true, canHeart: true), "ハートを送りました")
        // Own photo, or a former member: the count alone, no offer.
        XCTAssertEqual(Speech.heart(mine: false, canHeart: false), "ハート")
        XCTAssertEqual(Speech.heart(mine: true, canHeart: false), "ハートを送りました")
    }
}
