import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Private, explicit snapshots for one consultation. Never a sharing/Widget
/// payload and never reconstructed by name, image recognition or old medication.
struct VeterinaryVisitEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceNoteID: UUID
    let sourceRevision: String
    let text: String
    let capturedAt: Date?
    let writtenAt: Date?
    let weight: PhotoMemoWeightValue?
    let photoFile: String?
    var sourcePhotoIdentifier: String? = nil
    var familyRetained: Bool? = nil
}

struct VeterinaryVisit: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let catID: UUID
    let catName: String
    var revision: UUID
    var startedOn: String?
    var observations: String
    var questions: String
    var entries: [VeterinaryVisitEntry]
    var completedAt: Date?
    var familyRecordID: UUID? = nil
    var familyDetached: Bool? = nil
    /// After the consultation (11/8): what the vet said, the medicine given and
    /// the next visit day. Optional, so memos saved before them still read;
    /// the only fields that stay editable once the memo is 「診察済み」.
    var doctorNote: String? = nil
    var prescription: String? = nil
    var nextVisitOn: String? = nil
    /// When the memo was started and last edited. Absent on older memos.
    var createdAt: Date? = nil
    var updatedAt: Date? = nil

    /// The day the memo was last edited, or started when never edited.
    var lastEditedAt: Date? { updatedAt ?? createdAt }

    var hasResults: Bool {
        !(doctorNote ?? "").isEmpty || !(prescription ?? "").isEmpty || nextVisitOn != nil
    }

    var orderedEntries: [VeterinaryVisitEntry] {
        entries.sorted {
            let first = $0.weight?.measuredOn ?? $0.capturedAt.map(Self.day) ?? $0.writtenAt.map(Self.day)
            let second = $1.weight?.measuredOn ?? $1.capturedAt.map(Self.day) ?? $1.writtenAt.map(Self.day)
            if first != second { return (first ?? "9999-12-31") < (second ?? "9999-12-31") }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    /// Whole seconds, so a saved time reads back exactly the same.
    static func now() -> Date { Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down)) }
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension VeterinaryVisitEntry {
    /// A video's length as it reads on its badge: 「0:12」「1:05」「1:02:03」.
    static func durationText(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
    /// A length a video can have: a finite number of seconds up to a day.
    static func validVideoSeconds(_ seconds: Double) -> Bool { seconds.isFinite && seconds >= 0 && seconds <= 86_400 }
}

/// その日の体重 (11/9): the weight is kept in 「この子のこと」, its one place.
/// A memo shows the newest one measured on or before its day, so a past memo
/// shows the weight of its time, never one measured later.
enum VeterinaryVisitWeight {
    static func latest(_ weights: [(day: String, grams: Int)], onOrBefore day: String) -> (day: String, grams: Int)? {
        weights.filter { PhotoMemoWeightValue.validDay($0.day) && $0.day <= day }
            .max { $0.day == $1.day ? $0.grams < $1.grams : $0.day < $1.day }
    }
}

enum VeterinaryVisitError: Error, LocalizedError {
    case storage, corrupted, changed, wrongCat, confirmationRequired, invalidName, visitLimit, tooLarge
    var errorDescription: String? {
        switch self {
        case .storage: "保存できませんでした。空き容量を確かめて、もう一度お試しください（前の内容は残っています）。"
        case .corrupted: "診察メモを開けませんでした。アプリを開き直してください（前の内容は残っています）。"
        case .changed: "内容が変わっていました。開き直して、もう一度お試しください。"
        case .wrongCat: "この体重は別の猫のものです。どの猫の体重か確かめてください。"
        case .confirmationRequired: "どの猫の記録か確かめてください。"
        case .invalidName: "猫の名前を1〜200文字で入力してください。"
        case .visitLimit: "保存できませんでした。もう一度お試しください（書いた内容は残っています）。"
        case .tooLarge: "1回の診察で見せる記録は20件までです。写真が大きすぎるときは、別の写真を選んでください。"
        }
    }
}

actor VeterinaryVisitStore {
    #if os(iOS)
    private static let sharedCache = VeterinaryVisitStoreCache()
    static var shared: VeterinaryVisitStore { sharedCache.current() }
#else
    static let shared = VeterinaryVisitStore()
#endif
    private static let lock = NSLock()
    private struct State: Codable {
        var schema = 1
        var visits: [VeterinaryVisit] = []
        var retiredPhotoFiles: [String]? = nil
        /// Videos (11/9): an entry's length in seconds, by entry ID. Beside the
        /// visits, not in them: an older version still reads the memo (the
        /// first frame shows as a photo), and a change received from the
        /// family keeps it as it was. Entries no longer there are dropped.
        var videoSeconds: [String: Double]? = nil
    }
    private let directory: URL

    init(directory: URL? = nil) {
        #if os(iOS)
        self.directory = directory ?? AppRecordDataset.directory("VeterinaryVisits")
#else
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("VeterinaryVisits", isDirectory: true)
#endif
    }

    func visits() throws -> [VeterinaryVisit] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try load().visits
    }
    /// Which entries are videos, and how long each is.
    func videoDurations() throws -> [UUID: Double] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let state = try load()
        let live = Set(state.visits.flatMap { $0.entries.map(\.id) })
        var result: [UUID: Double] = [:]
        for (key, seconds) in state.videoSeconds ?? [:] {
            if let id = UUID(uuidString: key), live.contains(id) { result[id] = seconds }
        }
        return result
    }
    #if os(iOS)
    func receiveFamilyChanges() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }
        guard directory.standardizedFileURL == AppRecordDataset.directory("VeterinaryVisits").standardizedFileURL else { return }
        var state = try load()
        let next = Self.keepingLocalResults(try FamilyNotebookToolSharing.visitsReceived(state.visits), from: state.visits)
        guard next != state.visits else { return }
        for visit in next { try validate(visit) }
        state.visits = next; try commit(state, familyProjection: true)
    }
    #endif

    /// What came after the consultation and the memo's own dates stay on this
    /// iPhone for now: a received family change keeps them as they were, and
    /// does not count as a change by itself.
    static func keepingLocalResults(_ received: [VeterinaryVisit], from local: [VeterinaryVisit]) -> [VeterinaryVisit] {
        received.map { visit in
            guard let old = local.first(where: { $0.id == visit.id }) else { return visit }
            var kept = visit
            kept.doctorNote = old.doctorNote; kept.prescription = old.prescription; kept.nextVisitOn = old.nextVisitOn
            kept.createdAt = old.createdAt; kept.updatedAt = old.updatedAt
            var unchanged = kept; unchanged.revision = old.revision
            return unchanged == old ? old : kept
        }
    }

    /// The UI supplies a live membership boundary around a new commit. This
    /// Foundation-only store does not depend on SwiftUI or grant membership.
    /// Returning an existing draft never invokes the creation boundary.
    func current(catID: UUID, catName: String,
                 create: @Sendable (_ commit: () throws -> Void) throws -> Void) throws -> VeterinaryVisit {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = try load()
        if let existing = state.visits.first(where: { $0.catID == catID && $0.completedAt == nil }) { return existing }
        guard Self.isValidCatName(catName) else { throw VeterinaryVisitError.invalidName }
        guard state.visits.count < 36_500 else { throw VeterinaryVisitError.visitLimit }
        let visit = VeterinaryVisit(id: UUID(), catID: catID, catName: catName, revision: UUID(),
            startedOn: nil, observations: "", questions: "", entries: [], completedAt: nil, createdAt: VeterinaryVisit.now())
        try create {
            state.visits.append(visit); try commit(state)
        }
        return visit
    }

    func save(_ draft: VeterinaryVisit, expectedRevision: UUID, base: VeterinaryVisit? = nil) throws -> VeterinaryVisit {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = try load()
        guard let index = state.visits.firstIndex(where: { $0.id == draft.id }),
              state.visits[index].catID == draft.catID, state.visits[index].completedAt == nil else { throw VeterinaryVisitError.changed }
        let current = state.visits[index]
        var next = draft
        if current.revision != expectedRevision {
            guard let base, base.id == draft.id, base.catID == draft.catID, base.revision == expectedRevision,
                  base.entries == draft.entries, base.catName == draft.catName else { throw VeterinaryVisitError.changed }
            // An open editor owns only the fields it actually changed. Keep
            // newly received entries and edits to the other fields.
            next = current
            if draft.observations != base.observations { next.observations = draft.observations }
            if draft.questions != base.questions { next.questions = draft.questions }
            if draft.startedOn != base.startedOn { next.startedOn = draft.startedOn }
            if draft.completedAt != base.completedAt { next.completedAt = draft.completedAt }
            if draft.doctorNote != base.doctorNote { next.doctorNote = draft.doctorNote }
            if draft.prescription != base.prescription { next.prescription = draft.prescription }
            if draft.nextVisitOn != base.nextVisitOn { next.nextVisitOn = draft.nextVisitOn }
        } else {
            guard current.entries == draft.entries, current.catName == draft.catName else { throw VeterinaryVisitError.changed }
        }
        next.createdAt = current.createdAt
        next.revision = UUID(); next.updatedAt = VeterinaryVisit.now()
        try validate(next); state.visits[index] = next; try commit(state)
        return next
    }

    /// A memo marked 「診察済み」 keeps everything it showed. Only what came
    /// after the consultation (先生の話・出た薬・次に行く日) can still change.
    func saveResults(_ draft: VeterinaryVisit, expectedRevision: UUID, base: VeterinaryVisit? = nil) throws -> VeterinaryVisit {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = try load()
        guard let index = state.visits.firstIndex(where: { $0.id == draft.id }),
              state.visits[index].catID == draft.catID, state.visits[index].completedAt != nil else { throw VeterinaryVisitError.changed }
        let current = state.visits[index]
        var next = current
        if current.revision == expectedRevision {
            next.doctorNote = draft.doctorNote; next.prescription = draft.prescription; next.nextVisitOn = draft.nextVisitOn
        } else {
            guard let base, base.id == draft.id, base.revision == expectedRevision else { throw VeterinaryVisitError.changed }
            if draft.doctorNote != base.doctorNote { next.doctorNote = draft.doctorNote }
            if draft.prescription != base.prescription { next.prescription = draft.prescription }
            if draft.nextVisitOn != base.nextVisitOn { next.nextVisitOn = draft.nextVisitOn }
        }
        guard next != current else { return current }
        next.revision = UUID(); next.updatedAt = VeterinaryVisit.now()
        try validate(next); state.visits[index] = next; try commit(state)
        return next
    }

    /// Caller freezes and rechecks the source after preparing an optional copy.
    /// Existing selections change only through an explicit Replace action.
    /// A video (11/9) comes with its first frame as `jpeg` and its length;
    /// it plays from the iPhone's photo library by its identifier.
    func add(source: PhotoMemoryNoteRecord, jpeg: Data?, to visitID: UUID,
             expectedRevision: UUID, confirmedTarget: Bool, replace: Bool = false,
             videoSeconds: Double? = nil) throws -> VeterinaryVisit {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard confirmedTarget else { throw VeterinaryVisitError.confirmationRequired }
        var state = try load()
        guard let index = state.visits.firstIndex(where: { $0.id == visitID }),
              state.visits[index].revision == expectedRevision, state.visits[index].completedAt == nil else { throw VeterinaryVisitError.changed }
        var visit = state.visits[index]
        if let owner = source.note.weight?.catID, owner != visit.catID { throw VeterinaryVisitError.wrongCat }
        guard !source.note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || source.note.weight != nil || jpeg != nil else { throw VeterinaryVisitError.changed }
        let old = visit.entries.first { $0.sourceNoteID == source.id }
        guard old == nil || replace else { throw VeterinaryVisitError.changed }
        guard old != nil || visit.entries.count < 20 else { throw VeterinaryVisitError.tooLarge }
        if let jpeg { try Self.validateJPEG(jpeg) }
        if let videoSeconds {
            guard VeterinaryVisitEntry.validVideoSeconds(videoSeconds), jpeg != nil,
                  !source.photoIdentifier.isEmpty else { throw VeterinaryVisitError.changed }
        }
        let file = jpeg.map { _ in UUID().uuidString + ".jpg" }
        let weight = source.note.weight.map { PhotoMemoWeightValue(grams: $0.value.grams,
            measuredOn: $0.value.measuredOn, catName: visit.catName) }
        let entry = VeterinaryVisitEntry(id: old?.id ?? UUID(), sourceNoteID: source.id,
            sourceRevision: source.note.revision, text: source.note.text,
            capturedAt: source.note.context?.capturedAt, writtenAt: source.note.writtenAt,
            weight: weight, photoFile: file, sourcePhotoIdentifier: source.photoIdentifier)
        visit.entries.removeAll { $0.sourceNoteID == source.id }; visit.entries.append(entry); visit.revision = UUID()
        visit.updatedAt = VeterinaryVisit.now()
        try validate(visit)
        var intent = state
        if let file {
            // Record the owned filename before any bytes are created, so a
            // crash or failed final commit has a durable cleanup target.
            intent.retiredPhotoFiles = (intent.retiredPhotoFiles ?? []) + [file]
            try commit(intent)
        }
        state.visits[index] = visit
        var videos = state.videoSeconds ?? [:]
        videos[entry.id.uuidString] = videoSeconds
        state.videoSeconds = videos.isEmpty ? nil : videos
        if let file = old?.photoFile { state.retiredPhotoFiles = (state.retiredPhotoFiles ?? []) + [file] }
        do {
            if let jpeg, let file { try write(jpeg, to: directory.appendingPathComponent(file)) }
            try commit(state)
        }
        catch {
            try? cleanup(&intent)
            throw error
        }
        try? cleanup(&state)
        return visit
    }

    func remove(entryID: UUID, from visitID: UUID, expectedRevision: UUID) throws -> VeterinaryVisit {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = try load()
        guard let index = state.visits.firstIndex(where: { $0.id == visitID }),
              state.visits[index].revision == expectedRevision, state.visits[index].completedAt == nil,
              let entry = state.visits[index].entries.first(where: { $0.id == entryID }) else { throw VeterinaryVisitError.changed }
        state.visits[index].entries.removeAll { $0.id == entryID }; state.visits[index].revision = UUID()
        state.visits[index].updatedAt = VeterinaryVisit.now()
        if let file = entry.photoFile { state.retiredPhotoFiles = (state.retiredPhotoFiles ?? []) + [file] }
        try commit(state)
        try? cleanup(&state)
        return state.visits[index]
    }

    func image(for entry: VeterinaryVisitEntry, visitID: UUID) throws -> Data? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard try load().visits.first(where: { $0.id == visitID })?.entries.contains(entry) == true else { throw VeterinaryVisitError.changed }
        guard let file = entry.photoFile else { return nil }
        do {
            let url = directory.appendingPathComponent(file)
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 6 * 1024 * 1024 else { throw VeterinaryVisitError.tooLarge }
            let bytes = try Data(contentsOf: url); try Self.validateJPEG(bytes); return bytes
        }
        catch { throw VeterinaryVisitError.storage }
    }

    /// Deletes only this private consultation and its owned copies.
    func delete(visitID: UUID, expectedRevision: UUID) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = try load()
        guard let visit = state.visits.first(where: { $0.id == visitID }), visit.revision == expectedRevision else { throw VeterinaryVisitError.changed }
        state.visits.removeAll { $0.id == visitID }
        state.retiredPhotoFiles = (state.retiredPhotoFiles ?? []) + visit.entries.compactMap(\.photoFile)
        try commit(state); try? cleanup(&state)
    }

    func cleanupPending() throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = try load(); try cleanup(&state)
        return !(state.retiredPhotoFiles ?? []).isEmpty
    }

    private func cleanup(_ state: inout State) throws {
        let pending = state.retiredPhotoFiles ?? []
        guard !pending.isEmpty else { return }
        var remaining: [String] = []
        for file in pending {
            // All names were validated before accepting state. No PhotoKit,
            // original memo, cloud or outside directory is a deletion target.
            do { try FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
            catch {
                let ns = error as NSError
                if !(ns.domain == NSCocoaErrorDomain && [CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue].contains(ns.code)) { remaining.append(file) }
            }
        }
        if remaining != pending { state.retiredPhotoFiles = remaining; try commit(state) }
    }

    private func load() throws -> State {
        let data: Data
        do {
            let url = directory.appendingPathComponent("state.json")
            data = try AppRecordJSON.read(url)
        }
        catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && [CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue].contains(ns.code) {
                // A missing ledger is a new store only when no saved files remain.
                // Never overwrite an orphaned photo directory with an empty ledger.
                guard Self.canInitializeMissingManifest(in: directory) else { throw VeterinaryVisitError.storage }
                return State()
            }
            throw VeterinaryVisitError.storage
        }
        do {
            let state = try JSONDecoder().decode(State.self, from: data)
            guard [1,2].contains(state.schema), state.visits.count <= 36_500,
                  Set(state.visits.map(\.id)).count == state.visits.count,
                  Set(state.visits.filter { $0.completedAt == nil && $0.familyRecordID == nil }.map(\.catID)).count == state.visits.filter({ $0.completedAt == nil && $0.familyRecordID == nil }).count else { throw VeterinaryVisitError.corrupted }
            var photoFiles = Set<String>()
            for visit in state.visits {
                try validate(visit)
                for file in visit.entries.compactMap(\.photoFile) { guard photoFiles.insert(file).inserted else { throw VeterinaryVisitError.corrupted } }
            }
            let retired = state.retiredPhotoFiles ?? []
            guard retired.count <= 2000, Set(retired).count == retired.count,
                  retired.allSatisfy({ Self.validPhotoFile($0) && !photoFiles.contains($0) }) else { throw VeterinaryVisitError.corrupted }
            let videos = state.videoSeconds ?? [:]
            guard videos.count <= state.visits.reduce(0, { $0 + $1.entries.count }),
                  videos.allSatisfy({ UUID(uuidString: $0.key) != nil && VeterinaryVisitEntry.validVideoSeconds($0.value) }) else { throw VeterinaryVisitError.corrupted }
            return state
        } catch { throw VeterinaryVisitError.corrupted }
    }

    private static func canInitializeMissingManifest(in directory: URL) -> Bool {
        do { return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty }
        catch {
            let ns = error as NSError
            return ns.domain == NSCocoaErrorDomain
                && [CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue].contains(ns.code)
        }
    }

    private static func validName(_ name: String) -> Bool { !name.isEmpty && name.count <= 200 && !name.contains("\0") }

    nonisolated static func isValidCatName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 200 && !name.contains("\0")
    }
    private static func validPhotoFile(_ file: String) -> Bool { file.hasSuffix(".jpg") && UUID(uuidString: String(file.dropLast(4))) != nil }
    private func validate(_ visit: VeterinaryVisit) throws {
        guard Self.validName(visit.catName), visit.observations.count <= 500, visit.questions.count <= 500,
              visit.startedOn.map(PhotoMemoWeightValue.validDay) ?? true,
              visit.completedAt?.timeIntervalSince1970.isFinite ?? true,
              (visit.doctorNote?.count ?? 0) <= 500, (visit.prescription?.count ?? 0) <= 500,
              visit.nextVisitOn.map(PhotoMemoWeightValue.validDay) ?? true,
              visit.createdAt?.timeIntervalSince1970.isFinite ?? true,
              visit.updatedAt?.timeIntervalSince1970.isFinite ?? true,
              visit.entries.count <= 20, Set(visit.entries.map(\.id)).count == visit.entries.count,
              Set(visit.entries.map(\.sourceNoteID)).count == visit.entries.count else { throw VeterinaryVisitError.corrupted }
        for entry in visit.entries {
            try entry.weight?.validate()
            guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || entry.weight != nil || entry.photoFile != nil,
                  entry.text.count <= 500, entry.weight?.catName == nil || entry.weight?.catName == visit.catName,
                  UUID(uuidString: entry.sourceRevision) != nil,
                  entry.sourcePhotoIdentifier.map({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.contains("\0") }) ?? true,
                  entry.capturedAt?.timeIntervalSince1970.isFinite ?? true,
                  entry.writtenAt?.timeIntervalSince1970.isFinite ?? true,
                  entry.photoFile.map(Self.validPhotoFile) ?? true else { throw VeterinaryVisitError.corrupted }
        }
    }

    private static func validateJPEG(_ bytes: Data) throws {
        guard bytes.count >= 5, bytes.count <= 6 * 1024 * 1024,
              bytes.starts(with: [0xff, 0xd8, 0xff]), bytes.suffix(2).elementsEqual([0xff, 0xd9]) else { throw VeterinaryVisitError.tooLarge }
#if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) != nil else { throw VeterinaryVisitError.corrupted }
#endif
    }
    private func commit(_ state: State, familyProjection: Bool = false) throws {
        var state = state
        // Only entries still in a memo keep their video length.
        if let videos = state.videoSeconds {
            let live = Set(state.visits.flatMap { $0.entries.map(\.id.uuidString) })
            let kept = videos.filter { live.contains($0.key) }
            state.videoSeconds = kept.isEmpty ? nil : kept
        }
        if state.visits.contains(where: { $0.familyRecordID != nil || $0.familyDetached != nil || $0.entries.contains(where: { $0.familyRetained != nil }) }) { state.schema = 2 }
        #if os(iOS)
        AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }
        try AppRecordDataset.requireWritable(directory.appendingPathComponent("state.json"))
        #endif
        let retired = state.retiredPhotoFiles ?? []
        let live = Set(state.visits.flatMap { $0.entries.compactMap(\.photoFile) })
        guard retired.count <= 2000, Set(retired).count == retired.count,
              retired.allSatisfy({ Self.validPhotoFile($0) && !live.contains($0) }) else { throw VeterinaryVisitError.storage }
        let bytes = try JSONEncoder().encode(state)
        guard bytes.count <= AppRecordJSON.maximumBytes else { throw VeterinaryVisitError.storage }
        #if os(iOS)
        if !familyProjection { try FamilyNotebookToolSharing.visitsChanged(before: load().visits, after: state.visits, directory: directory) }
        #endif
        try write(bytes, to: directory.appendingPathComponent("state.json"))
        NotificationCenter.default.post(name: Notification.Name("neko.app-records.committed.v1"), object: directory)
    }
    private func write(_ data: Data, to url: URL) throws {
#if os(iOS)
        AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }
        try AppRecordDataset.requireWritable(url)
#endif
        do {
            guard directory.isFileURL else { throw VeterinaryVisitError.storage }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            if url.lastPathComponent == "state.json" { try AppRecordJSON.write(data, to: url, options: [.atomic, .completeFileProtection]) }
            else { try data.write(to: url, options: [.atomic, .completeFileProtection]) }
#else
            if url.lastPathComponent == "state.json" { try AppRecordJSON.write(data, to: url) }
            else { try data.write(to: url, options: .atomic) }
#endif
        } catch { throw VeterinaryVisitError.storage }
    }
}

#if os(iOS)
private final class VeterinaryVisitStoreCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (URL, VeterinaryVisitStore)?
    func current() -> VeterinaryVisitStore {
        lock.lock(); defer { lock.unlock() }
        let root = AppRecordDataset.directory("VeterinaryVisits")
        if let value, value.0 == root { return value.1 }
        let store = VeterinaryVisitStore(directory: root); value = (root, store); return store
    }
}
#endif
