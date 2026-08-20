import Foundation

private enum VerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw VerificationError.failed(message) }
}

private func candidate(
    _ identifier: String,
    _ timestamp: TimeInterval?,
    liked: Bool = true
) -> PhotoBookPhotoCandidate {
    PhotoBookPhotoCandidate(
        localIdentifier: identifier,
        creationDate: timestamp.map { Date(timeIntervalSince1970: $0) },
        isLiked: liked
    )
}

private func verifyProgressCopyAndBoundary() throws {
    try require(PhotoBookPolicy.photosPerBook == 30, "book size changed")
    try require(
        PhotoBookPolicy.progress(likedPhotoCount: -4).statusText
            == "あと30枚で1冊になります",
        "negative count was not normalized"
    )
    try require(
        PhotoBookPolicy.progress(likedPhotoCount: 0).statusText
            == "あと30枚で1冊になります",
        "empty progress copy changed"
    )
    try require(
        PhotoBookPolicy.progress(likedPhotoCount: 29).statusText
            == "あと1枚で1冊になります",
        "remaining-one copy changed"
    )
    let complete = PhotoBookPolicy.progress(likedPhotoCount: 30)
    try require(complete.hasCompleteBook, "30 photos did not complete a book")
    try require(complete.remainingPhotoCount == 0, "complete progress went negative")
    try require(complete.statusText == "1冊分たまりました", "completion copy changed")
    try require(
        PhotoBookPolicy.progress(likedPhotoCount: 80).statusText
            == "1冊分たまりました",
        "overflow count changed the one-book completion copy"
    )
}

private func verifyLikedOnlyOldestFirstSelection() throws {
    let input = [
        candidate("nil-z", nil),
        candidate("same-b", 200),
        candidate("ignored", 50, liked: false),
        candidate("newer", 300),
        candidate("oldest", 100),
        candidate("same-a", 200),
        candidate("nil-a", nil)
    ]
    let selected = PhotoBookPolicy.selection(from: input)
    try require(
        selected.map(\.localIdentifier) == [
            "oldest",
            "same-a",
            "same-b",
            "newer",
            "nil-a",
            "nil-z"
        ],
        "selection was not liked-only, oldest-first, nil-last, and stable"
    )
}

private func verifyFirstThirtyLimit() throws {
    let input = (0..<40).reversed().map { index in
        candidate(
            String(format: "photo-%02d", index),
            TimeInterval(index)
        )
    }
    let selected = PhotoBookPolicy.selection(from: input)
    try require(selected.count == 30, "selection exceeded one book")
    try require(
        selected.map(\.localIdentifier) == (0..<30).map {
            String(format: "photo-%02d", $0)
        },
        "selection did not keep the oldest first 30 liked photos"
    )
}

@main
private enum PhotoBookPolicyVerifier {
    static func main() throws {
        try verifyProgressCopyAndBoundary()
        try verifyLikedOnlyOldestFirstSelection()
        try verifyFirstThirtyLimit()
        print("Photo-book policy: PASS")
    }
}
