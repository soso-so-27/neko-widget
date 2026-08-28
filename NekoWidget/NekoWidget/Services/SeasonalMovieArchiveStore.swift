import Combine
import Foundation

enum SeasonalMovieArchiveError: LocalizedError {
    case unsupportedCatalogVersion(Int)
    case invalidRecord
    case periodNotFound
    case sceneNotFound
    case minimumSceneCount
    case catalogLimit
    case catalogTooLarge

    var errorDescription: String? {
        switch self {
        case let .unsupportedCatalogVersion(version):
            return "この作品履歴は新しい形式（\(version)）です。アプリを更新してください。"
        case .invalidRecord:
            return "作品履歴の内容を確認できませんでした。"
        case .periodNotFound:
            return "この季節の作品が見つかりませんでした。"
        case .sceneNotFound:
            return "この場面は作品に含まれていません。"
        case .minimumSceneCount:
            return "作品には8場面以上必要です。"
        case .catalogLimit:
            return "作品履歴の上限に達しました。"
        case .catalogTooLarge:
            return "作品履歴が大きすぎるため保存できません。"
        }
    }
}

enum SeasonalMovieArchiveFreezeReason: String, Codable, Hashable, Sendable {
    case meaningfulPlayback
    case sceneEdit
    case export
    /// Version 1 did not record whether a work had already been watched or
    /// exported. Preserve it rather than guessing that it is still a draft.
    case legacyRecord
}

struct SeasonalMoviePeriodID: Codable, Hashable, Identifiable, Sendable {
    let year: Int
    let quarter: Int

    var id: String { "\(year)-Q\(quarter)" }

    init(year: Int, quarter: Int) {
        self.year = year
        self.quarter = min(4, max(1, quarter))
    }

    init(presentation: SeasonalMoviePresentation) {
        year = presentation.startYearNumber
        quarter = min(4, max(1, (presentation.startMonthNumber - 1) / 3 + 1))
    }
}

struct SeasonalMovieArchiveRecord: Codable, Hashable, Identifiable, Sendable {
    static let schemaVersion = 2

    let version: Int
    let periodID: SeasonalMoviePeriodID
    let createdAt: Date
    var updatedAt: Date
    var presentation: SeasonalMoviePresentation
    var excludedSceneIdentifiers: Set<String>
    var frozenAt: Date?
    var freezeReason: SeasonalMovieArchiveFreezeReason?

    var id: SeasonalMoviePeriodID { periodID }

    var isFrozen: Bool { frozenAt != nil }

    var effectivePresentation: SeasonalMoviePresentation {
        presentation.replacingScenes(
            presentation.scenes.filter {
                !excludedSceneIdentifiers.contains($0.localIdentifier)
            }
        )
    }
}

struct SeasonalMovieArchiveDraft: Sendable {
    let presentation: SeasonalMoviePresentation
    fileprivate let sourcePresentation: SeasonalMoviePresentation
    fileprivate let canFinalize: Bool
}

actor SeasonalMovieArchiveStore {
    static let shared = SeasonalMovieArchiveStore()

    private struct Catalog: Codable {
        let version: Int
        var records: [SeasonalMovieArchiveRecord]
    }

    private static let catalogVersion = 1
    /// Recipe-only records are small. Keep twenty years of quarters rather
    /// than silently evicting something the person expects to revisit.
    private static let maximumRecordCount = 80
    private static let maximumCatalogByteCount = 1_048_576
    private static let maximumIdentifierLength = 512
    private let fileManager: FileManager
    private let rootDirectoryOverride: URL?

    init(
        fileManager: FileManager = .default,
        rootDirectoryOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.rootDirectoryOverride = rootDirectoryOverride
    }

    func load() throws -> [SeasonalMovieArchiveRecord] {
        let url = try catalogURL()
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= Self.maximumCatalogByteCount else {
            throw SeasonalMovieArchiveError.catalogTooLarge
        }
        let data = try Data(contentsOf: url)
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.version == Self.catalogVersion else {
            throw SeasonalMovieArchiveError.unsupportedCatalogVersion(
                catalog.version
            )
        }
        var migratedLegacyRecord = false
        let records = catalog.records
            .compactMap { record -> SeasonalMovieArchiveRecord? in
                switch record.version {
                case SeasonalMovieArchiveRecord.schemaVersion:
                    return record
                case 1:
                    migratedLegacyRecord = true
                    return SeasonalMovieArchiveRecord(
                        version: SeasonalMovieArchiveRecord.schemaVersion,
                        periodID: record.periodID,
                        createdAt: record.createdAt,
                        updatedAt: record.updatedAt,
                        presentation: record.presentation,
                        excludedSceneIdentifiers: record.excludedSceneIdentifiers,
                        frozenAt: record.updatedAt,
                        freezeReason: .legacyRecord
                    )
                default:
                    return nil
                }
            }
            .sorted { $0.presentation.quarterStart > $1.presentation.quarterStart }
        guard records.count == catalog.records.count,
              records.count <= Self.maximumRecordCount,
              Set(records.map(\.periodID)).count == records.count,
              records.allSatisfy(isValid) else {
            throw SeasonalMovieArchiveError.invalidRecord
        }
        // Migration is deliberately best-effort. A protected or temporarily
        // unwritable directory must not hide a valid legacy catalog. The
        // normalized records stay frozen in memory and the next successful
        // mutation persists version 2 atomically.
        if migratedLegacyRecord {
            try? save(records)
        }
        return records
    }

    func upsert(
        _ presentation: SeasonalMoviePresentation,
        now: Date = Date()
    ) throws -> SeasonalMovieArchiveRecord {
        var records = try load()
        let periodID = SeasonalMoviePeriodID(presentation: presentation)
        if let existing = records.first(where: { $0.periodID == periodID }) {
            // Automatic rescans must never rewrite a piece the person already
            // edited. A future explicit "作り直す" flow can use a separate API.
            return existing
        }
        guard records.count < Self.maximumRecordCount else {
            throw SeasonalMovieArchiveError.catalogLimit
        }
        let record = SeasonalMovieArchiveRecord(
            version: SeasonalMovieArchiveRecord.schemaVersion,
            periodID: periodID,
            createdAt: now,
            updatedAt: now,
            presentation: presentation,
            excludedSceneIdentifiers: [],
            frozenAt: nil,
            freezeReason: nil
        )
        guard isValid(record) else {
            throw SeasonalMovieArchiveError.invalidRecord
        }
        records.append(record)
        try save(records)
        return record
    }

    func setSceneExcluded(
        _ identifier: String,
        excluded: Bool,
        in periodID: SeasonalMoviePeriodID,
        now: Date = Date()
    ) throws -> SeasonalMovieArchiveRecord {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.periodID == periodID }) else {
            throw SeasonalMovieArchiveError.periodNotFound
        }
        guard records[index].presentation.scenes.contains(where: {
            $0.localIdentifier == identifier
        }) else {
            throw SeasonalMovieArchiveError.sceneNotFound
        }
        let effectiveSceneCount = records[index].effectivePresentation.scenes.count
        if excluded,
           !records[index].excludedSceneIdentifiers.contains(identifier),
           effectiveSceneCount <= SeasonalMovieBuilder.minimumOutputSceneCount {
            throw SeasonalMovieArchiveError.minimumSceneCount
        }
        if excluded {
            records[index].excludedSceneIdentifiers.insert(identifier)
        } else {
            records[index].excludedSceneIdentifiers.remove(identifier)
        }
        if !records[index].isFrozen {
            records[index].frozenAt = now
            records[index].freezeReason = .sceneEdit
        }
        records[index].updatedAt = now
        let updated = records[index]
        try save(records)
        return updated
    }

    /// Replaces a photo-first recipe only while it is still exactly the
    /// unedited draft. A scene exclusion or any other durable recipe change
    /// wins over an automatic moving-media scan.
    func finalizeDraft(
        _ presentation: SeasonalMoviePresentation,
        replacing sourcePresentation: SeasonalMoviePresentation,
        now: Date = Date()
    ) throws -> SeasonalMovieArchiveRecord {
        let periodID = SeasonalMoviePeriodID(presentation: presentation)
        guard SeasonalMoviePeriodID(presentation: sourcePresentation) == periodID else {
            throw SeasonalMovieArchiveError.invalidRecord
        }
        var records = try load()
        guard let index = records.firstIndex(where: { $0.periodID == periodID }) else {
            throw SeasonalMovieArchiveError.periodNotFound
        }
        guard !records[index].isFrozen,
              records[index].excludedSceneIdentifiers.isEmpty,
              records[index].presentation == sourcePresentation else {
            return records[index]
        }
        guard records[index].presentation != presentation else {
            return records[index]
        }
        guard isPreferredDraftRefresh(
            presentation,
            over: records[index].presentation
        ) else {
            return records[index]
        }
        records[index].presentation = presentation
        records[index].updatedAt = now
        guard isValid(records[index]) else {
            throw SeasonalMovieArchiveError.invalidRecord
        }
        let updated = records[index]
        try save(records)
        return updated
    }

    func freeze(
        _ periodID: SeasonalMoviePeriodID,
        reason: SeasonalMovieArchiveFreezeReason,
        now: Date = Date()
    ) throws -> SeasonalMovieArchiveRecord {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.periodID == periodID }) else {
            throw SeasonalMovieArchiveError.periodNotFound
        }
        guard !records[index].isFrozen else { return records[index] }
        records[index].frozenAt = now
        records[index].freezeReason = reason
        records[index].updatedAt = now
        guard isValid(records[index]) else {
            throw SeasonalMovieArchiveError.invalidRecord
        }
        let updated = records[index]
        try save(records)
        return updated
    }

    func delete(_ periodID: SeasonalMoviePeriodID) throws {
        var records = try load()
        records.removeAll { $0.periodID == periodID }
        try save(records)
    }

    private func save(_ input: [SeasonalMovieArchiveRecord]) throws {
        guard input.count <= Self.maximumRecordCount,
              Set(input.map(\.periodID)).count == input.count,
              input.allSatisfy(isValid) else {
            throw SeasonalMovieArchiveError.invalidRecord
        }
        let records = input.sorted {
            $0.presentation.quarterStart > $1.presentation.quarterStart
        }
        let catalog = Catalog(
            version: Self.catalogVersion,
            records: records
        )
        try prepareDirectory()
        let data = try JSONEncoder().encode(catalog)
        guard data.count <= Self.maximumCatalogByteCount else {
            throw SeasonalMovieArchiveError.catalogTooLarge
        }
        let url = try catalogURL()
#if os(iOS)
        let writingOptions: Data.WritingOptions = [
            .atomic,
            .completeFileProtection
        ]
#else
        let writingOptions: Data.WritingOptions = [.atomic]
#endif
        try data.write(to: url, options: writingOptions)
        // The containing directory is excluded from backup before this atomic
        // commit. A fallible file-attribute write after the commit would let
        // callers observe failure even though new catalog bytes were durable.
    }

    private func prepareDirectory() throws {
        let directoryURL = try directoryURL()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directoryURL.path
        )
#endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedDirectoryURL = directoryURL
        try protectedDirectoryURL.setResourceValues(values)
    }

    private func directoryURL() throws -> URL {
        if let rootDirectoryOverride {
            return rootDirectoryOverride
                .appendingPathComponent("SeasonalMovies", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        }
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("SeasonalMovies", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    private func catalogURL() throws -> URL {
        try directoryURL().appendingPathComponent(
            "catalog.json",
            isDirectory: false
        )
    }

    private func isValid(_ record: SeasonalMovieArchiveRecord) -> Bool {
        let scenes = record.presentation.scenes
        let sceneIDs = Set(scenes.map(\.localIdentifier))
        return record.version == SeasonalMovieArchiveRecord.schemaVersion
            && (record.frozenAt == nil) == (record.freezeReason == nil)
            && (record.excludedSceneIdentifiers.isEmpty || record.isFrozen)
            && record.createdAt.timeIntervalSinceReferenceDate.isFinite
            && record.updatedAt.timeIntervalSinceReferenceDate.isFinite
            && (record.frozenAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
            && scenes.count >= SeasonalMovieBuilder.minimumOutputSceneCount
            && scenes.count <= SeasonalMovieBuilder.maximumOutputSceneCount
            && sceneIDs.count == scenes.count
            && scenes.allSatisfy {
                !$0.localIdentifier.isEmpty
                    && $0.localIdentifier.count <= Self.maximumIdentifierLength
                    && $0.creationDate.timeIntervalSinceReferenceDate.isFinite
                    && $0.playbackDuration.isFinite
                    && ($0.suggestedStartTime?.isFinite ?? true)
                    && ($0.suggestedDuration?.isFinite ?? true)
                    && ($0.largestCatAreaRatio?.isFinite ?? true)
                    && isFinite($0.catBoundingBox)
            }
            && record.excludedSceneIdentifiers.isSubset(of: sceneIDs)
            && record.effectivePresentation.scenes.count
                >= SeasonalMovieBuilder.minimumOutputSceneCount
    }

    /// An incomplete local-media pass must never make a visible draft worse.
    /// Refresh only on an objective gain, in the same order the product uses
    /// for selection: explicit memories, period coverage, motion, then scene
    /// count. Equal-quality substitutions are kept stable to avoid churn.
    private func isPreferredDraftRefresh(
        _ proposal: SeasonalMoviePresentation,
        over current: SeasonalMoviePresentation
    ) -> Bool {
        let proposedQuality = draftQuality(proposal)
        let currentQuality = draftQuality(current)
        for index in proposedQuality.indices {
            if proposedQuality[index] != currentQuality[index] {
                return proposedQuality[index] > currentQuality[index]
            }
        }
        return false
    }

    private func draftQuality(
        _ presentation: SeasonalMoviePresentation
    ) -> [Int] {
        let calendar = Calendar(identifier: .gregorian)
        return [
            presentation.scenes.filter(\.isMemory).count,
            Set(presentation.scenes.map {
                calendar.dateInterval(of: .month, for: $0.creationDate)?.start
                    ?? calendar.startOfDay(for: $0.creationDate)
            }).count,
            Set(presentation.scenes.map {
                calendar.startOfDay(for: $0.creationDate)
            }).count,
            presentation.movingSceneCount,
            presentation.scenes.count
        ]
    }

    private func isFinite(_ rect: CGRect?) -> Bool {
        guard let rect else { return true }
        return rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
    }
}

@MainActor
final class SeasonalMovieArchiveLibrary: ObservableObject {
    @Published private(set) var records: [SeasonalMovieArchiveRecord] = []
    @Published private(set) var lastErrorDescription: String?

    private let store: SeasonalMovieArchiveStore
    /// If a durable freeze fails, do not permit another automatic rewrite in
    /// this process after the person has watched or exported the work.
    private var locallyFrozenPeriodIDs: Set<SeasonalMoviePeriodID> = []

    init(store: SeasonalMovieArchiveStore = .shared) {
        self.store = store
    }

    func load() async {
        do {
            records = try await store.load()
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = archiveMessage(
                for: error,
                fallback: "作品履歴を読み込めませんでした。"
            )
        }
    }

    @discardableResult
    func recordDraft(
        _ presentation: SeasonalMoviePresentation
    ) async -> SeasonalMovieArchiveDraft? {
        do {
            let record = try await store.upsert(presentation)
            merge(record)
            lastErrorDescription = nil
            return SeasonalMovieArchiveDraft(
                presentation: record.effectivePresentation,
                sourcePresentation: record.presentation,
                canFinalize: !record.isFrozen
                    && !locallyFrozenPeriodIDs.contains(record.periodID)
                    && record.excludedSceneIdentifiers.isEmpty
            )
        } catch {
            lastErrorDescription = archiveMessage(
                for: error,
                fallback: "作品を保存できませんでした。"
            )
            // The Today card routes through the archive period ID. Showing an
            // unsaved draft would create a card that cannot be opened.
            return nil
        }
    }

    func finalizeDraft(
        _ presentation: SeasonalMoviePresentation,
        from draft: SeasonalMovieArchiveDraft
    ) async -> SeasonalMoviePresentation {
        let periodID = SeasonalMoviePeriodID(presentation: draft.presentation)
        guard draft.canFinalize,
              !locallyFrozenPeriodIDs.contains(periodID) else {
            return draft.presentation
        }
        do {
            let record = try await store.finalizeDraft(
                presentation,
                replacing: draft.sourcePresentation
            )
            merge(record)
            lastErrorDescription = nil
            return record.effectivePresentation
        } catch {
            // The photo-first recipe is already durable and playable. A
            // failed enrichment must not hide or replace it in the UI.
            lastErrorDescription = archiveMessage(
                for: error,
                fallback: "動画を含む作品へ更新できませんでした。"
            )
            return draft.presentation
        }
    }

    func freeze(
        _ periodID: SeasonalMoviePeriodID,
        reason: SeasonalMovieArchiveFreezeReason
    ) async throws {
        locallyFrozenPeriodIDs.insert(periodID)
        do {
            let record = try await store.freeze(periodID, reason: reason)
            merge(record)
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = archiveMessage(
                for: error,
                fallback: "作品を固定できませんでした。"
            )
            throw error
        }
    }

    @discardableResult
    func setSceneExcluded(
        _ identifier: String,
        excluded: Bool,
        in periodID: SeasonalMoviePeriodID
    ) async throws -> SeasonalMoviePresentation {
        do {
            let record = try await store.setSceneExcluded(
                identifier,
                excluded: excluded,
                in: periodID
            )
            merge(record)
            lastErrorDescription = nil
            return record.effectivePresentation
        } catch {
            lastErrorDescription = archiveMessage(
                for: error,
                fallback: "作品を更新できませんでした。"
            )
            throw error
        }
    }

    func presentation(
        for periodID: SeasonalMoviePeriodID
    ) -> SeasonalMoviePresentation? {
        records.first { $0.periodID == periodID }?.effectivePresentation
    }

    private func merge(_ record: SeasonalMovieArchiveRecord) {
        records.removeAll { $0.periodID == record.periodID }
        records.append(record)
        records.sort { $0.presentation.quarterStart > $1.presentation.quarterStart }
    }

    private func archiveMessage(
        for error: Error,
        fallback: String
    ) -> String {
        guard let archiveError = error as? SeasonalMovieArchiveError else {
            return fallback
        }
        return archiveError.errorDescription ?? fallback
    }
}
