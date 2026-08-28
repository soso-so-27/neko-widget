import CoreGraphics
import Foundation

private enum VerificationError: Error {
    case failed(String)
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw VerificationError.failed(message) }
}

private func presentation(suffix: String = "") -> SeasonalMoviePresentation {
    let start = Date(timeIntervalSince1970: 1_774_998_000)
    let scenes = (0..<10).map { index in
        SeasonalMovieCandidate(
            localIdentifier: "asset-\(index)\(suffix)",
            creationDate: start.addingTimeInterval(Double(index) * 86_400),
            mediaKind: .stillPhoto,
            catBoundingBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
            largestCatAreaRatio: 0.25,
            isMemory: index == 2,
            suggestedStartTime: nil,
            suggestedDuration: nil
        )
    }
    return SeasonalMoviePresentation(
        quarterStart: start,
        quarterEnd: start.addingTimeInterval(90 * 86_400),
        startYearNumber: 2026,
        startMonthNumber: 4,
        endYearNumber: 2026,
        endMonthNumber: 6,
        scenes: scenes
    )
}

@main
private struct SeasonalMovieArchiveVerifier {
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "seasonal-archive-test-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let store = SeasonalMovieArchiveStore(
            fileManager: fileManager,
            rootDirectoryOverride: root
        )
        let initial = presentation()
        let first = try await store.upsert(initial)
        try require(first.effectivePresentation.scenes.count == 10,
                    "initial recipe was not persisted")

        var enrichedScenes = initial.scenes
        enrichedScenes[0] = SeasonalMovieCandidate(
            localIdentifier: enrichedScenes[0].localIdentifier,
            creationDate: enrichedScenes[0].creationDate,
            mediaKind: .livePhoto,
            catBoundingBox: enrichedScenes[0].catBoundingBox,
            largestCatAreaRatio: enrichedScenes[0].largestCatAreaRatio,
            isMemory: enrichedScenes[0].isMemory,
            suggestedStartTime: nil,
            suggestedDuration: nil
        )
        let enriched = initial.replacingScenes(enrichedScenes)
        let finalized = try await store.finalizeDraft(
            enriched,
            replacing: initial
        )
        try require(finalized.presentation.scenes[0].mediaKind == .livePhoto,
                    "an unedited photo-first draft was not enriched")

        let firstIdentifier = initial.scenes[0].localIdentifier
        let secondIdentifier = initial.scenes[1].localIdentifier
        _ = try await store.setSceneExcluded(
            firstIdentifier,
            excluded: true,
            in: first.periodID
        )
        let protectedEdit = try await store.finalizeDraft(
            initial,
            replacing: enriched
        )
        try require(protectedEdit.presentation == enriched,
                    "automatic enrichment rewrote an edited recipe")
        try require(protectedEdit.excludedSceneIdentifiers.contains(firstIdentifier),
                    "automatic enrichment discarded a scene exclusion")
        let minimum = try await store.setSceneExcluded(
            secondIdentifier,
            excluded: true,
            in: first.periodID
        )
        try require(minimum.effectivePresentation.scenes.count == 8,
                    "reversible exclusions did not reach the eight-scene floor")
        do {
            _ = try await store.setSceneExcluded(
                initial.scenes[2].localIdentifier,
                excluded: true,
                in: first.periodID
            )
            throw VerificationError.failed("the eight-scene floor was bypassed")
        } catch SeasonalMovieArchiveError.minimumSceneCount {
            // Expected.
        }

        let automaticRescan = try await store.upsert(presentation(suffix: "-new"))
        try require(
            automaticRescan.presentation.scenes[0].localIdentifier == firstIdentifier,
            "an automatic rescan rewrote an edited seasonal work"
        )

        let catalogURL = root
            .appendingPathComponent("SeasonalMovies/v1", isDirectory: true)
            .appendingPathComponent("catalog.json")
        let unsupported = Data("{\"version\":999,\"records\":[]}".utf8)
        try unsupported.write(to: catalogURL, options: .atomic)
        do {
            _ = try await store.upsert(presentation(suffix: "-overwrite"))
            throw VerificationError.failed("an unsupported catalog was overwritten")
        } catch let error as SeasonalMovieArchiveError {
            guard case .unsupportedCatalogVersion(999) = error else {
                throw error
            }
        }
        let remainingData = try Data(contentsOf: catalogURL)
        try require(remainingData == unsupported,
                    "a failed read mutated the existing catalog")

        print("Seasonal movie archive: PASS")
    }
}
