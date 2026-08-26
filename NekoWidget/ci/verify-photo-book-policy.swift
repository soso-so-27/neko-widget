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

private func verifySelectionBoundary() throws {
    try require(PhotoBookPolicy.minimumPhotosPerExport == 1, "minimum changed")
    try require(PhotoBookPolicy.maximumPhotosPerExport == 30, "maximum changed")
    let input = (0..<40).map {
        candidate("photo-\($0)", TimeInterval($0))
    }
    try require(
        PhotoBookPolicy.selection(
            from: input,
            selectedIdentifiers: []
        ).isEmpty,
        "empty export selection was accepted"
    )
    try require(
        PhotoBookPolicy.selection(
            from: input,
            selectedIdentifiers: input.map(\.localIdentifier)
        ).isEmpty,
        "more than 30 export photos were accepted"
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
    let selected = PhotoBookPolicy.selection(
        from: input,
        selectedIdentifiers: [
            "nil-z", "same-b", "ignored", "newer",
            "oldest", "same-a", "nil-a"
        ]
    )
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

private func verifyExplicitSelectionCanUseAnyLikedPhoto() throws {
    let input = (0..<40).map { index in
        candidate(
            String(format: "photo-%02d", index),
            TimeInterval(index)
        )
    }
    let requested = ["photo-39", "photo-31", "photo-05"]
    let selected = PhotoBookPolicy.selection(
        from: input,
        selectedIdentifiers: requested
    )
    try require(
        selected.map(\.localIdentifier) == ["photo-05", "photo-31", "photo-39"],
        "explicit photos were not selected in stable capture order"
    )
    try require(
        !selected.contains { $0.localIdentifier == "photo-00" },
        "an unselected global-prefix photo leaked into the PDF"
    )
}

private func verifyDuplicateIdentifiersFailClosed() throws {
    let duplicatedCandidates = [
        candidate("photo-a", 100),
        candidate("photo-a", 200),
        candidate("photo-b", 300)
    ]
    try require(
        PhotoBookPolicy.selection(
            from: duplicatedCandidates,
            selectedIdentifiers: ["photo-a", "photo-b"]
        ).isEmpty,
        "duplicate candidate identifiers satisfied a PDF selection"
    )
    try require(
        PhotoBookPolicy.selection(
            from: [candidate("photo-a", 100)],
            selectedIdentifiers: ["photo-a", "photo-a"]
        ).isEmpty,
        "duplicate requested identifiers were silently accepted"
    )
}

private func verifySingleMemoryPhotoSelection() throws {
    let liked = candidate("liked", 100)
    try require(
        MemoryPhotoExportPolicy.selection(
            from: [liked, candidate("other", 200)],
            localIdentifier: "liked"
        ) == liked,
        "one explicitly selected liked photo was not accepted"
    )
    try require(
        MemoryPhotoExportPolicy.selection(
            from: [candidate("unliked", 100, liked: false)],
            localIdentifier: "unliked"
        ) == nil,
        "an unliked photo was accepted for Memory export"
    )
    try require(
        MemoryPhotoExportPolicy.selection(
            from: [liked],
            localIdentifier: "missing"
        ) == nil,
        "a missing photo fell back to a different Memory photo"
    )
    try require(
        MemoryPhotoExportPolicy.selection(
            from: [liked, liked],
            localIdentifier: "liked"
        ) == nil,
        "duplicate Memory candidates were accepted"
    )
    try require(
        MemoryPhotoExportPolicy.selection(
            from: [liked],
            localIdentifier: ""
        ) == nil,
        "an empty local identifier was accepted"
    )
}

private func verifyLikedCollectionUsesPawOrder() throws {
    let values: [(identifier: String, likedAt: Date?)] = [
        ("nil-z", nil),
        ("older", Date(timeIntervalSince1970: 100)),
        ("newer", Date(timeIntervalSince1970: 300)),
        ("same-b", Date(timeIntervalSince1970: 200)),
        ("same-a", Date(timeIntervalSince1970: 200)),
        ("nil-a", nil)
    ]
    let ordered = values.sorted { first, second in
        LikedPhotoOrderingPolicy.comesBefore(
            firstIdentifier: first.identifier,
            firstLikedAt: first.likedAt,
            secondIdentifier: second.identifier,
            secondLikedAt: second.likedAt
        )
    }
    try require(
        ordered.map(\.identifier) == [
            "newer", "same-a", "same-b", "older", "nil-a", "nil-z"
        ],
        "思い出 stopped following stable manual-add order"
    )
}

@main
private enum PhotoBookPolicyVerifier {
    static func main() throws {
        try verifySelectionBoundary()
        try verifyLikedOnlyOldestFirstSelection()
        try verifyExplicitSelectionCanUseAnyLikedPhoto()
        try verifyDuplicateIdentifiersFailClosed()
        try verifySingleMemoryPhotoSelection()
        try verifyLikedCollectionUsesPawOrder()
        print("Photo-book policy: PASS")
    }
}
