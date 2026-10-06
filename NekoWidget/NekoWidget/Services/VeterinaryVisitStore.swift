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

    var orderedEntries: [VeterinaryVisitEntry] {
        entries.sorted {
            let first = $0.weight?.measuredOn ?? $0.capturedAt.map(Self.day) ?? $0.writtenAt.map(Self.day)
            let second = $1.weight?.measuredOn ?? $1.capturedAt.map(Self.day) ?? $1.writtenAt.map(Self.day)
            if first != second { return (first ?? "9999-12-31") < (second ?? "9999-12-31") }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum VeterinaryVisitError: Error, LocalizedError {
    case storage, corrupted, changed, wrongCat, confirmationRequired, invalidName, visitLimit, tooLarge
    var errorDescription: String? {
        switch self {
        case .storage: "診察メモを保存できません。保存済みの内容は変更していません。"
        case .corrupted: "診察メモを読み込めません。保存済みの内容は変更していません。"
        case .changed: "診察メモが変更されました。開き直して確認してください。"
        case .wrongCat: "この体重は別の猫の記録です。測定した猫を確認してください。"
        case .confirmationRequired: "この記録を見せる猫を確認してください。"
        case .invalidName: "猫の名前を1〜200文字で入力してください。"
        case .visitLimit: "保存できる診察メモは100件までです。不要な診察メモを削除してから作ってください。"
        case .tooLarge: "一度の診察メモには20件まで追加できます。写真は6MB以下で用意してください。"
        }
    }
}

actor VeterinaryVisitStore {
    static let shared = VeterinaryVisitStore()
    private static let lock = NSLock()
    private struct State: Codable {
        var schema = 1
        var visits: [VeterinaryVisit] = []
        var retiredPhotoFiles: [String]? = nil
    }
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("VeterinaryVisits", isDirectory: true)
    }

    func visits() throws -> [VeterinaryVisit] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try load().visits
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
        guard state.visits.count < 100 else { throw VeterinaryVisitError.visitLimit }
        let visit = VeterinaryVisit(id: UUID(), catID: catID, catName: catName, revision: UUID(),
            startedOn: nil, observations: "", questions: "", entries: [], completedAt: nil)
        try create {
            state.visits.append(visit); try commit(state)
        }
        return visit
    }

    func save(_ draft: VeterinaryVisit, expectedRevision: UUID) throws -> VeterinaryVisit {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = try load()
        guard let index = state.visits.firstIndex(where: { $0.id == draft.id }),
              state.visits[index].revision == expectedRevision,
              state.visits[index].catID == draft.catID, state.visits[index].catName == draft.catName,
              state.visits[index].entries == draft.entries,
              state.visits[index].completedAt == nil else { throw VeterinaryVisitError.changed }
        var next = draft; next.revision = UUID()
        try validate(next); state.visits[index] = next; try commit(state)
        return next
    }

    /// Caller freezes and rechecks the source after preparing an optional copy.
    /// Existing selections change only through an explicit Replace action.
    func add(source: PhotoMemoryNoteRecord, jpeg: Data?, to visitID: UUID,
             expectedRevision: UUID, confirmedTarget: Bool, replace: Bool = false) throws -> VeterinaryVisit {
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
        let file = jpeg.map { _ in UUID().uuidString + ".jpg" }
        let weight = source.note.weight.map { PhotoMemoWeightValue(grams: $0.value.grams,
            measuredOn: $0.value.measuredOn, catName: visit.catName) }
        let entry = VeterinaryVisitEntry(id: old?.id ?? UUID(), sourceNoteID: source.id,
            sourceRevision: source.note.revision, text: source.note.text,
            capturedAt: source.note.context?.capturedAt, writtenAt: source.note.writtenAt,
            weight: weight, photoFile: file, sourcePhotoIdentifier: source.photoIdentifier)
        visit.entries.removeAll { $0.sourceNoteID == source.id }; visit.entries.append(entry); visit.revision = UUID()
        try validate(visit)
        var intent = state
        if let file {
            // Record the owned filename before any bytes are created, so a
            // crash or failed final commit has a durable cleanup target.
            intent.retiredPhotoFiles = (intent.retiredPhotoFiles ?? []) + [file]
            try commit(intent)
        }
        state.visits[index] = visit
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
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 8 * 1024 * 1024 { throw VeterinaryVisitError.corrupted }
            data = try Data(contentsOf: url)
        }
        catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && [CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue].contains(ns.code) { return State() }
            throw VeterinaryVisitError.storage
        }
        do {
            let state = try JSONDecoder().decode(State.self, from: data)
            guard state.schema == 1, state.visits.count <= 100,
                  Set(state.visits.map(\.id)).count == state.visits.count,
                  Set(state.visits.filter { $0.completedAt == nil }.map(\.catID)).count == state.visits.filter({ $0.completedAt == nil }).count else { throw VeterinaryVisitError.corrupted }
            var photoFiles = Set<String>()
            for visit in state.visits {
                try validate(visit)
                for file in visit.entries.compactMap(\.photoFile) { guard photoFiles.insert(file).inserted else { throw VeterinaryVisitError.corrupted } }
            }
            let retired = state.retiredPhotoFiles ?? []
            guard retired.count <= 2000, Set(retired).count == retired.count,
                  retired.allSatisfy({ Self.validPhotoFile($0) && !photoFiles.contains($0) }) else { throw VeterinaryVisitError.corrupted }
            return state
        } catch { throw VeterinaryVisitError.corrupted }
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
    private func commit(_ state: State) throws {
        let retired = state.retiredPhotoFiles ?? []
        let live = Set(state.visits.flatMap { $0.entries.compactMap(\.photoFile) })
        guard retired.count <= 2000, Set(retired).count == retired.count,
              retired.allSatisfy({ Self.validPhotoFile($0) && !live.contains($0) }) else { throw VeterinaryVisitError.storage }
        let bytes = try JSONEncoder().encode(state)
        guard bytes.count <= 8 * 1024 * 1024 else { throw VeterinaryVisitError.storage }
        try write(bytes, to: directory.appendingPathComponent("state.json"))
    }
    private func write(_ data: Data, to url: URL) throws {
        do {
            guard directory.isFileURL else { throw VeterinaryVisitError.storage }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
#else
            try data.write(to: url, options: .atomic)
#endif
        } catch { throw VeterinaryVisitError.storage }
    }
}
