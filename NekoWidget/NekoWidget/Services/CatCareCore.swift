import Foundation

// 「この子のこと」: one place for each cat's information that every tool reads.
// Stored on this iPhone only. The shape is ready for family sharing later
// (encrypted to a family window's members, never readable by the developer):
// single values carry who/when edited them, and growing lists (weights,
// medications, vaccinations, meals) only ever add records or mark them
// deleted, so two iPhones editing at once never lose each other's changes.
// Foundation only, so the merge and validation rules run in CI on macOS.

// MARK: - Values

/// A calendar day without a time zone, so a birthday never shifts by a day.
struct CatCareDay: Codable, Equatable, Comparable, Hashable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    init?(year: Int, month: Int, day: Int) {
        guard (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        guard let date = Calendar(identifier: .gregorian).date(from: components),
              Calendar(identifier: .gregorian).component(.day, from: date) == day
        else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    init?(date: Date, calendar: Calendar = .current) {
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = values.year, let month = values.month, let day = values.day else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// "2026-10-20" (the photo memo's weight date format).
    init?(isoDay: String) {
        let parts = isoDay.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// A value plus who and when last edited it. The newer edit wins a merge;
/// the same instant is broken by `editedBy`, so both iPhones agree.
struct CatCareStamped<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var value: Value
    var editedAt: Date
    var editedBy: String

    func merged(with other: Self) -> Self {
        if other.editedAt != editedAt { return other.editedAt > editedAt ? other : self }
        return other.editedBy > editedBy ? other : self
    }
}

enum CatCareTriState: String, Codable, Equatable, Sendable { case unknown, yes, no }
enum CatCareSex: String, Codable, Equatable, Sendable { case unknown, male, female }

struct CatCareAllergy: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable { case unknown, none, recorded }
    var status: Status = .unknown
    var text: String = ""
}

struct CatCareVet: Codable, Equatable, Sendable {
    var name: String = ""
    var phone: String = ""
    var note: String = ""
    var isEmpty: Bool { [name, phone, note].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

struct CatCarePhotoRef: Codable, Equatable, Sendable {
    /// A copy inside the app's CatCare folder, so it survives Photos deletions.
    var fileName: String
    /// The Photos asset it came from, if any (to avoid copying twice).
    var sourceAssetID: String?
    /// How it was added: chosen from Photos, or taken in the app.
    var origin: Origin = .photos

    enum Origin: String, Codable, Equatable, Sendable { case photos, camera, importedFromTool }
}

// MARK: - Growing lists (add or mark deleted; never overwrite)

protocol CatCareListEntry: Codable, Equatable, Identifiable, Sendable where ID == UUID {
    var id: UUID { get }
    var editedAt: Date { get set }
    var editedBy: String { get set }
    var deletedAt: Date? { get set }
}

extension Array where Element: CatCareListEntry {
    /// Marks a record deleted instead of removing it, so a shared copy
    /// can never bring it back.
    mutating func markDeleted(_ id: UUID, at now: Date, by: String) {
        guard let index = firstIndex(where: { $0.id == id }) else { return }
        self[index].deletedAt = now
        self[index].editedAt = now
        self[index].editedBy = by
    }
}

struct CatCareWeight: CatCareListEntry {
    enum Source: Codable, Equatable, Sendable {
        case manual
        case photoMemo(noteID: String)
    }
    var id: UUID = UUID()
    var measuredOn: CatCareDay
    var grams: Int
    var source: Source = .manual
    var editedAt: Date
    var editedBy: String
    var deletedAt: Date? = nil
}

struct CatCareMedication: CatCareListEntry {
    var id: UUID = UUID()
    var name: String
    var dose: String = ""
    var schedule: String = ""
    var startedOn: CatCareDay? = nil
    var endedOn: CatCareDay? = nil
    var note: String = ""
    var editedAt: Date
    var editedBy: String
    var deletedAt: Date? = nil
}

struct CatCareVaccination: CatCareListEntry {
    var id: UUID = UUID()
    var kind: String
    var givenOn: CatCareDay
    var nextDueOn: CatCareDay? = nil
    var proof: CatCarePhotoRef? = nil
    var editedAt: Date
    var editedBy: String
    var deletedAt: Date? = nil
}

struct CatCareMeal: CatCareListEntry {
    var id: UUID = UUID()
    var time: String = ""
    var food: String = ""
    var amount: String = ""
    var order: Int
    var editedAt: Date
    var editedBy: String
    var deletedAt: Date? = nil
}

// MARK: - Records

struct CatCareHousehold: Codable, Equatable, Sendable {
    var ownerContact: CatCareStamped<String>?
    var backupContact: CatCareStamped<String>?
    var vet: CatCareStamped<CatCareVet>?
    var meetingPlace: CatCareStamped<String>?
}

struct CatCareRecord: Codable, Equatable, Identifiable, Sendable {
    /// The household cat ID shared by every tool (`toolCatID`). Never a name.
    var catID: UUID
    /// The cat-recognition profile this cat is linked to, if any.
    var profileID: UUID?

    var name: CatCareStamped<String>?
    var sex: CatCareStamped<CatCareSex>?
    var neutered: CatCareStamped<CatCareTriState>?
    var birthday: CatCareStamped<CatCareDay?>?
    var coat: CatCareStamped<String>?
    var marks: CatCareStamped<String>?
    /// 15 digits. Shown in full on screen and on paper (owner decision 10/20).
    var microchip: CatCareStamped<String>?
    var indoorOnly: CatCareStamped<CatCareTriState>?

    var facePhoto: CatCareStamped<CatCarePhotoRef?>?
    var bodyPhoto: CatCareStamped<CatCarePhotoRef?>?

    var conditions: CatCareStamped<String>?
    var allergy: CatCareStamped<CatCareAllergy>?
    var weights: [CatCareWeight] = []
    var medications: [CatCareMedication] = []
    var vaccinations: [CatCareVaccination] = []

    var meals: [CatCareMeal] = []
    var specialDiet: CatCareStamped<String>?
    var water: CatCareStamped<String>?
    var litter: CatCareStamped<String>?
    var temperament: CatCareStamped<String>?

    var vetOverride: CatCareStamped<CatCareVet?>?
    /// Reserved for family sharing; always empty in the first public version.
    var sharedWindowIDs: [String] = []
    var reviewedAt: Date?
    var deletedAt: Date?

    var id: UUID { catID }

    init(catID: UUID, profileID: UUID? = nil) {
        self.catID = catID
        self.profileID = profileID
    }

    /// Records not marked deleted, newest day first.
    var activeWeights: [CatCareWeight] {
        weights.filter { $0.deletedAt == nil }.sorted { $0.measuredOn > $1.measuredOn }
    }
    var activeMedications: [CatCareMedication] { medications.filter { $0.deletedAt == nil } }
    var activeVaccinations: [CatCareVaccination] {
        vaccinations.filter { $0.deletedAt == nil }.sorted { $0.givenOn > $1.givenOn }
    }
    var activeMeals: [CatCareMeal] { meals.filter { $0.deletedAt == nil }.sorted { $0.order < $1.order } }
}

struct CatCareState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    /// Advanced once per successful save (compare-and-swap in the store).
    var mutationRevision = 0
    /// Opaque ID of this iPhone, made on first use. No name or Apple ID.
    var deviceID: String
    var household = CatCareHousehold()
    var cats: [CatCareRecord] = []
    var createdAt: Date
    var updatedAt: Date

    init(deviceID: String = UUID().uuidString.lowercased(), now: Date = Date()) {
        self.deviceID = deviceID
        self.createdAt = now
        self.updatedAt = now
    }

    func record(catID: UUID) -> CatCareRecord? {
        cats.first { $0.catID == catID && $0.deletedAt == nil }
    }
}

// MARK: - Limits

enum CatCareLimits {
    static let textCharacters = 500
    static let nameCharacters = 40
    static let maximumWeights = 500
    static let maximumMedications = 100
    static let maximumVaccinations = 100
    static let maximumMeals = 8
    static let gramsRange = 1...30_000

    static func clippedText(_ value: String, limit: Int = textCharacters) -> String {
        String(value.prefix(limit))
    }

    /// Digits only, exactly 15, or empty. Spaces and hyphens are removed.
    static func normalizedMicrochip(_ value: String) -> String? {
        let digits = value.filter { !$0.isWhitespace && $0 != "-" }
        if digits.isEmpty { return "" }
        guard digits.count == 15, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return digits
    }

    static func isValidWeight(grams: Int, on day: CatCareDay, today: CatCareDay) -> Bool {
        gramsRange.contains(grams) && day <= today
    }
}

// MARK: - Merging two copies of the same household (family sharing later)

enum CatCareMerge {
    static func merge(_ local: CatCareState, _ remote: CatCareState) -> CatCareState {
        var result = local
        result.household = merge(local.household, remote.household)
        var byID = Dictionary(uniqueKeysWithValues: local.cats.map { ($0.catID, $0) })
        for cat in remote.cats {
            byID[cat.catID] = byID[cat.catID].map { merge($0, cat) } ?? cat
        }
        result.cats = local.cats.map { byID[$0.catID]! }
            + remote.cats.filter { cat in !local.cats.contains { $0.catID == cat.catID } }
        return result
    }

    static func merge(_ a: CatCareHousehold, _ b: CatCareHousehold) -> CatCareHousehold {
        CatCareHousehold(
            ownerContact: pick(a.ownerContact, b.ownerContact),
            backupContact: pick(a.backupContact, b.backupContact),
            vet: pick(a.vet, b.vet),
            meetingPlace: pick(a.meetingPlace, b.meetingPlace)
        )
    }

    static func merge(_ a: CatCareRecord, _ b: CatCareRecord) -> CatCareRecord {
        precondition(a.catID == b.catID)
        var r = a
        r.profileID = a.profileID ?? b.profileID
        r.name = pick(a.name, b.name)
        r.sex = pick(a.sex, b.sex)
        r.neutered = pick(a.neutered, b.neutered)
        r.birthday = pick(a.birthday, b.birthday)
        r.coat = pick(a.coat, b.coat)
        r.marks = pick(a.marks, b.marks)
        r.microchip = pick(a.microchip, b.microchip)
        r.indoorOnly = pick(a.indoorOnly, b.indoorOnly)
        r.facePhoto = pick(a.facePhoto, b.facePhoto)
        r.bodyPhoto = pick(a.bodyPhoto, b.bodyPhoto)
        r.conditions = pick(a.conditions, b.conditions)
        r.allergy = pick(a.allergy, b.allergy)
        r.weights = union(a.weights, b.weights)
        r.medications = union(a.medications, b.medications)
        r.vaccinations = union(a.vaccinations, b.vaccinations)
        r.meals = union(a.meals, b.meals)
        r.specialDiet = pick(a.specialDiet, b.specialDiet)
        r.water = pick(a.water, b.water)
        r.litter = pick(a.litter, b.litter)
        r.temperament = pick(a.temperament, b.temperament)
        r.vetOverride = pick(a.vetOverride, b.vetOverride)
        r.sharedWindowIDs = Array(Set(a.sharedWindowIDs).union(b.sharedWindowIDs)).sorted()
        r.reviewedAt = [a.reviewedAt, b.reviewedAt].compactMap { $0 }.max()
        r.deletedAt = [a.deletedAt, b.deletedAt].compactMap { $0 }.max()
        return r
    }

    static func pick<V>(_ a: CatCareStamped<V>?, _ b: CatCareStamped<V>?) -> CatCareStamped<V>? {
        switch (a, b) {
        case let (a?, b?): a.merged(with: b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }

    /// Every record from both sides by ID. For the same ID, a deletion wins;
    /// otherwise the newer edit wins (same instant: higher `editedBy`).
    static func union<E: CatCareListEntry>(_ a: [E], _ b: [E]) -> [E] {
        var byID: [UUID: E] = [:]
        var order: [UUID] = []
        for entry in a + b {
            guard let existing = byID[entry.id] else {
                byID[entry.id] = entry; order.append(entry.id); continue
            }
            byID[entry.id] = preferred(existing, entry)
        }
        return order.compactMap { byID[$0] }
    }

    private static func preferred<E: CatCareListEntry>(_ x: E, _ y: E) -> E {
        switch (x.deletedAt, y.deletedAt) {
        case (nil, _?): return y
        case (_?, nil): return x
        default:
            if x.editedAt != y.editedAt { return y.editedAt > x.editedAt ? y : x }
            return y.editedBy > x.editedBy ? y : x
        }
    }
}

// MARK: - Filling empty fields from existing tool records

/// What a tool already knows about one cat. The store builds these from the
/// tool records; the rules here only fill fields that are still empty and
/// never overwrite anything the owner typed in 「この子のこと」.
struct CatCareImportSource: Equatable, Sendable {
    var tool: String                 // "CareHandoff", "Evacuation", "Preparedness", "PhotoMemo"
    var catID: UUID
    var profileID: UUID?
    var name: String?
    var marks: String?
    var conditions: String?
    var allergy: CatCareAllergy?
    var water: String?
    var litter: String?
    var temperament: String?
    var meals: [(time: String, food: String, amount: String)] = []
    var weights: [(noteID: String, day: CatCareDay, grams: Int)] = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tool == rhs.tool && lhs.catID == rhs.catID && lhs.profileID == rhs.profileID
            && lhs.name == rhs.name && lhs.marks == rhs.marks && lhs.conditions == rhs.conditions
            && lhs.allergy == rhs.allergy && lhs.water == rhs.water && lhs.litter == rhs.litter
            && lhs.temperament == rhs.temperament
            && lhs.meals.map { [$0.time, $0.food, $0.amount] } == rhs.meals.map { [$0.time, $0.food, $0.amount] }
            && lhs.weights.map { "\($0.noteID)|\($0.grams)" } == rhs.weights.map { "\($0.noteID)|\($0.grams)" }
    }
}

struct CatCareHouseholdImportSource: Equatable, Sendable {
    var tool: String
    var ownerContact: String?
    var backupContact: String?
    var vet: CatCareVet?
    var meetingPlace: String?
}

enum CatCareImport {
    /// Fills only empty fields; running it again changes nothing.
    static func apply(_ source: CatCareImportSource, to state: inout CatCareState, now: Date) {
        let by = "import:" + source.tool
        let index: Int
        if let found = state.cats.firstIndex(where: { $0.catID == source.catID }) {
            index = found
        } else if let profileID = source.profileID,
                  let found = state.cats.firstIndex(where: { $0.profileID == profileID }) {
            // The same recognized cat seen by a tool without a shared cat ID.
            index = found
        } else {
            state.cats.append(CatCareRecord(catID: source.catID, profileID: source.profileID))
            index = state.cats.count - 1
        }
        var r = state.cats[index]
        guard r.deletedAt == nil else { return }
        if r.profileID == nil { r.profileID = source.profileID }
        fill(&r.name, source.name, by: by, now: now, limit: CatCareLimits.nameCharacters)
        fill(&r.marks, source.marks, by: by, now: now)
        fill(&r.conditions, source.conditions, by: by, now: now)
        fill(&r.water, source.water, by: by, now: now)
        fill(&r.litter, source.litter, by: by, now: now)
        fill(&r.temperament, source.temperament, by: by, now: now)
        if r.allergy == nil, let allergy = source.allergy, allergy.status != .unknown {
            r.allergy = .init(value: .init(status: allergy.status,
                                           text: CatCareLimits.clippedText(allergy.text)),
                              editedAt: now, editedBy: by)
        }
        if r.activeMeals.isEmpty {
            let meals = source.meals
                .filter { ![$0.time, $0.food, $0.amount].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
                .prefix(CatCareLimits.maximumMeals)
            for (order, meal) in meals.enumerated() {
                r.meals.append(.init(time: CatCareLimits.clippedText(meal.time),
                                     food: CatCareLimits.clippedText(meal.food),
                                     amount: CatCareLimits.clippedText(meal.amount),
                                     order: order, editedAt: now, editedBy: by))
            }
        }
        // One weight per photo memo, ever.
        let known = Set(r.weights.compactMap { entry -> String? in
            if case let .photoMemo(noteID) = entry.source { return noteID }
            return nil
        })
        for weight in source.weights where !known.contains(weight.noteID)
            && CatCareLimits.gramsRange.contains(weight.grams)
            && r.weights.count < CatCareLimits.maximumWeights {
            r.weights.append(.init(measuredOn: weight.day, grams: weight.grams,
                                   source: .photoMemo(noteID: weight.noteID),
                                   editedAt: now, editedBy: by))
        }
        if r != state.cats[index] {
            state.cats[index] = r
            state.updatedAt = now
        }
    }

    static func apply(_ source: CatCareHouseholdImportSource, to state: inout CatCareState, now: Date) {
        let by = "import:" + source.tool
        var h = state.household
        fill(&h.ownerContact, source.ownerContact, by: by, now: now)
        fill(&h.backupContact, source.backupContact, by: by, now: now)
        fill(&h.meetingPlace, source.meetingPlace, by: by, now: now)
        if h.vet == nil, let vet = source.vet, !vet.isEmpty {
            h.vet = .init(value: vet, editedAt: now, editedBy: by)
        }
        if h != state.household {
            state.household = h
            state.updatedAt = now
        }
    }

    private static func fill(_ field: inout CatCareStamped<String>?, _ value: String?,
                             by: String, now: Date, limit: Int = CatCareLimits.textCharacters) {
        guard field == nil || field?.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
              let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        field = .init(value: CatCareLimits.clippedText(value, limit: limit), editedAt: now, editedBy: by)
    }
}

// MARK: - 迷子のとき

enum CatCareLostCat {
    /// One short line the owner may add to the flyer with a tap, such as
    /// 「オス・3歳・室内飼い・マイクロチップあり」. The chip number stays off it.
    static func publicLine(_ record: CatCareRecord?,
                           today: CatCareDay? = CatCareDay(date: Date())) -> String? {
        var parts: [String] = []
        switch record?.sex?.value ?? .unknown {
        case .male: parts.append("オス")
        case .female: parts.append("メス")
        case .unknown: break
        }
        if let age = age(record?.birthday?.value, today: today) { parts.append(age) }
        if record?.indoorOnly?.value == .yes { parts.append("室内飼い") }
        if !(record?.microchip?.value ?? "").isEmpty { parts.append("マイクロチップあり") }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    /// 「3歳」, or 「5か月」 under one year. Nil for an unknown or future birthday.
    static func age(_ birthday: CatCareDay?, today: CatCareDay?) -> String? {
        guard let birthday, let today, birthday <= today else { return nil }
        var months = (today.year - birthday.year) * 12 + (today.month - birthday.month)
        if today.day < birthday.day { months -= 1 }
        return months < 12 ? "\(max(months, 0))か月" : "\(months / 12)歳"
    }
}

// MARK: - Reading a file where one broken cat must not hide the others

enum CatCareDecoding {
    private struct Lenient: Decodable {
        var schemaVersion: Int
        var mutationRevision: Int
        var deviceID: String
        var household: CatCareHousehold?
        var cats: [FailableRecord]
        var createdAt: Date
        var updatedAt: Date
    }

    private struct FailableRecord: Decodable {
        var record: CatCareRecord?
        init(from decoder: Decoder) throws {
            record = try? CatCareRecord(from: decoder)
        }
    }

    struct Result: Equatable {
        var state: CatCareState
        /// Cats that could not be read; their data stays in the file.
        var unreadableCatCount: Int
    }

    static func decode(_ data: Data) throws -> Result {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lenient = try decoder.decode(Lenient.self, from: data)
        guard (1...CatCareState.currentSchemaVersion).contains(lenient.schemaVersion) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var state = CatCareState(deviceID: lenient.deviceID, now: lenient.createdAt)
        state.schemaVersion = lenient.schemaVersion
        state.mutationRevision = lenient.mutationRevision
        state.household = lenient.household ?? CatCareHousehold()
        state.cats = lenient.cats.compactMap(\.record)
        state.updatedAt = lenient.updatedAt
        return Result(state: state, unreadableCatCount: lenient.cats.filter { $0.record == nil }.count)
    }

    static func encode(_ state: CatCareState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }
}
