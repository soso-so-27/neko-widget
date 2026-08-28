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
            isPhotoLibraryFavorite: index == 3,
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

private struct LegacyCatalog: Encodable {
    let version: Int
    let records: [LegacyRecord]
}

private struct LegacyRecord: Encodable {
    let version: Int
    let periodID: SeasonalMoviePeriodID
    let createdAt: Date
    let updatedAt: Date
    let presentation: SeasonalMoviePresentation
    let excludedSceneIdentifiers: Set<String>
}

@main
private struct SeasonalMovieArchiveVerifier {
    static func main() async throws {
        let candidateData = try JSONEncoder().encode(presentation().scenes[3])
        var legacyObject = try JSONSerialization.jsonObject(
            with: candidateData
        ) as! [String: Any]
        legacyObject.removeValue(forKey: "isPhotoLibraryFavorite")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyCandidate = try JSONDecoder().decode(
            SeasonalMovieCandidate.self,
            from: legacyData
        )
        try require(!legacyCandidate.isPhotoLibraryFavorite,
                    "a legacy recipe without Photos favorite did not decode")

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
        try require(!first.isFrozen,
                    "a new automatic recipe was unexpectedly frozen")

        var enrichedScenes = initial.scenes
        enrichedScenes[0] = SeasonalMovieCandidate(
            localIdentifier: enrichedScenes[0].localIdentifier,
            creationDate: enrichedScenes[0].creationDate,
            mediaKind: .livePhoto,
            catBoundingBox: enrichedScenes[0].catBoundingBox,
            largestCatAreaRatio: enrichedScenes[0].largestCatAreaRatio,
            isMemory: enrichedScenes[0].isMemory,
            isPhotoLibraryFavorite: enrichedScenes[0].isPhotoLibraryFavorite,
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

        let inferiorSubstitution = try await store.finalizeDraft(
            presentation(suffix: "-equal"),
            replacing: finalized.presentation
        )
        try require(inferiorSubstitution.presentation == enriched,
                    "an incomplete rescan downgraded a stable draft")

        var lateScenes = enriched.scenes
        lateScenes[1] = SeasonalMovieCandidate(
            localIdentifier: "asset-1-late",
            creationDate: lateScenes[1].creationDate,
            mediaKind: .livePhoto,
            catBoundingBox: lateScenes[1].catBoundingBox,
            largestCatAreaRatio: lateScenes[1].largestCatAreaRatio,
            isMemory: lateScenes[1].isMemory,
            suggestedStartTime: nil,
            suggestedDuration: nil
        )
        let lateMaterial = initial.replacingScenes(lateScenes)
        let refreshed = try await store.finalizeDraft(
            lateMaterial,
            replacing: finalized.presentation
        )
        try require(refreshed.presentation == lateMaterial,
                    "an unseen draft did not accept later local material")

        var favoriteScenes = lateMaterial.scenes
        favoriteScenes[2] = SeasonalMovieCandidate(
            localIdentifier: favoriteScenes[2].localIdentifier,
            creationDate: favoriteScenes[2].creationDate,
            mediaKind: favoriteScenes[2].mediaKind,
            catBoundingBox: favoriteScenes[2].catBoundingBox,
            largestCatAreaRatio: favoriteScenes[2].largestCatAreaRatio,
            isMemory: favoriteScenes[2].isMemory,
            isPhotoLibraryFavorite: true,
            suggestedStartTime: favoriteScenes[2].suggestedStartTime,
            suggestedDuration: favoriteScenes[2].suggestedDuration
        )
        let favoriteRefresh = lateMaterial.replacingScenes(favoriteScenes)
        let favoriteImproved = try await store.finalizeDraft(
            favoriteRefresh,
            replacing: lateMaterial
        )
        try require(favoriteImproved.presentation == favoriteRefresh,
                    "a Photos favorite did not improve an unseen draft")

        let staleRefresh = try await store.finalizeDraft(
            presentation(suffix: "-stale"),
            replacing: initial
        )
        try require(staleRefresh.presentation == favoriteRefresh,
                    "a stale automatic refresh replaced a newer recipe")

        let watchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let watched = try await store.freeze(
            first.periodID,
            reason: .meaningfulPlayback,
            now: watchedAt
        )
        try require(watched.isFrozen,
                    "meaningful playback did not freeze the recipe")
        try require(watched.freezeReason == .meaningfulPlayback,
                    "meaningful playback freeze reason was not persisted")
        let afterWatch = try await store.finalizeDraft(
            presentation(suffix: "-after-watch"),
            replacing: favoriteRefresh
        )
        try require(afterWatch.presentation == favoriteRefresh,
                    "automatic refresh rewrote a watched recipe")

        let firstIdentifier = favoriteRefresh.scenes[0].localIdentifier
        let secondIdentifier = favoriteRefresh.scenes[1].localIdentifier
        _ = try await store.setSceneExcluded(
            firstIdentifier,
            excluded: true,
            in: first.periodID
        )
        let protectedEdit = try await store.finalizeDraft(
            initial,
            replacing: favoriteRefresh
        )
        try require(protectedEdit.presentation == favoriteRefresh,
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
                favoriteRefresh.scenes[2].localIdentifier,
                excluded: true,
                in: first.periodID
            )
            throw VerificationError.failed("the eight-scene floor was bypassed")
        } catch SeasonalMovieArchiveError.minimumSceneCount {
            // Expected.
        }

        let automaticRescan = try await store.upsert(presentation(suffix: "-new"))
        try require(
            automaticRescan.presentation == favoriteRefresh,
            "an automatic rescan rewrote an edited seasonal work"
        )

        let editRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "seasonal-edit-freeze-test-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: editRoot) }
        let editStore = SeasonalMovieArchiveStore(
            fileManager: fileManager,
            rootDirectoryOverride: editRoot
        )
        let editDraft = try await editStore.upsert(initial)
        let edited = try await editStore.setSceneExcluded(
            initial.scenes[0].localIdentifier,
            excluded: true,
            in: editDraft.periodID
        )
        try require(edited.freezeReason == .sceneEdit,
                    "a scene edit did not freeze its draft")

        let exportRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "seasonal-export-freeze-test-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: exportRoot) }
        let exportStore = SeasonalMovieArchiveStore(
            fileManager: fileManager,
            rootDirectoryOverride: exportRoot
        )
        let exportDraft = try await exportStore.upsert(initial)
        let exported = try await exportStore.freeze(
            exportDraft.periodID,
            reason: .export
        )
        try require(exported.freezeReason == .export,
                    "an export did not freeze its draft")

        let legacyRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "seasonal-legacy-migration-test-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: legacyRoot) }
        let legacyDirectory = legacyRoot
            .appendingPathComponent("SeasonalMovies/v1", isDirectory: true)
        try fileManager.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacyCatalog = LegacyCatalog(
            version: 1,
            records: [LegacyRecord(
                version: 1,
                periodID: SeasonalMoviePeriodID(presentation: initial),
                createdAt: watchedAt,
                updatedAt: watchedAt,
                presentation: initial,
                excludedSceneIdentifiers: []
            )]
        )
        let legacyURL = legacyDirectory.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(legacyCatalog).write(to: legacyURL, options: .atomic)
        let legacyStore = SeasonalMovieArchiveStore(
            fileManager: fileManager,
            rootDirectoryOverride: legacyRoot
        )
        let migrated = try await legacyStore.load()
        try require(migrated.count == 1,
                    "a version 1 catalog was not loaded")
        try require(migrated[0].version == SeasonalMovieArchiveRecord.schemaVersion,
                    "a version 1 record was not normalized")
        try require(migrated[0].freezeReason == .legacyRecord,
                    "a legacy work with unknown viewing state was not preserved")
        let legacyRefresh = try await legacyStore.finalizeDraft(
            presentation(suffix: "-legacy-refresh"),
            replacing: initial
        )
        try require(legacyRefresh.presentation == initial,
                    "migration rewrote a legacy work with unknown viewing state")

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
