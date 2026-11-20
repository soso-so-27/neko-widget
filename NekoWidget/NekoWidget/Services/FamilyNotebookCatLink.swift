import Foundation

/// 11/15 (段 1): the same cat in the family notebook and on this iPhone.
///
/// One cat is one page on one iPhone. Whether a family cat and a cat of this
/// iPhone are the same cat is the person's answer, never a name match: a
/// cat with the same name is only offered first. The answer is the existing
/// local mapping's `profileID` (the creator's phone already has it), kept on
/// this iPhone only and never in an operation. Nothing here sends anything.
///
/// Linked, the family cat's 「この子のこと」 record (`toolCatID`) becomes the
/// profile's record, so its photos come from this iPhone and its writing from
/// the notebook. What this iPhone had already written for the cat goes in
/// the way a cat added to the notebook goes in: it fills what the family has
/// not written and adds its lists; a value the family already has is kept.
/// The record it came from is kept (marked as replaced), never erased.
enum FamilyNotebookCatLink {
    /// The cat-level mapping of a family cat that this iPhone projects.
    static func catMapping(_ cat: UUID, in snapshot: FamilyNotebookSnapshot) -> FamilyNotebookLocalMapping? {
        snapshot.activeMappings.first { $0.familyCatID == cat && $0.recordID == nil && $0.toolCatID != nil }
    }

    /// The profile a family cat is linked to on this iPhone, if any.
    static func linkedProfile(_ cat: UUID, in snapshot: FamilyNotebookSnapshot) -> UUID? {
        catMapping(cat, in: snapshot)?.profileID
    }

    /// Profiles already linked to a family cat (each one at most once).
    static func linkedProfiles(in snapshot: FamilyNotebookSnapshot) -> Set<UUID> {
        Set(snapshot.activeMappings.filter { $0.recordID == nil }.compactMap(\.profileID))
    }

    // MARK: 「この子のこと」 on this iPhone

    /// Links the family cat's record to `profile`. This iPhone's own record of
    /// the profile, if any, fills only what the family record has not got,
    /// adds its list entries and its own photos; it is then kept as a
    /// replaced record (still the profile's, marked deleted, after the linked
    /// record), so unlinking shows it again. Nothing is erased.
    static func linking(_ care: CatCareState, toolCatID: UUID, profile: UUID, now: Date) throws -> CatCareState {
        var state = care
        guard let target = state.cats.firstIndex(where: { $0.catID == toolCatID && $0.deletedAt == nil })
        else { throw FamilyNotebookError.mappingConflict }
        var record = state.cats[target]
        guard record.profileID == nil || record.profileID == profile else { throw FamilyNotebookError.mappingConflict }
        record.profileID = profile
        var replaced: [Int] = []
        for index in state.cats.indices where index != target {
            guard state.cats[index].profileID == profile, state.cats[index].deletedAt == nil else { continue }
            var own = state.cats[index]
            fill(&record, from: &own)
            // Kept, not erased: a value the family already had stays here.
            own.deletedAt = now
            state.cats[index] = own
            replaced.append(index)
        }
        state.cats[target] = record
        // The linked record comes first, so every lookup by profile finds it.
        if let first = replaced.min(), first < target {
            let moved = state.cats.remove(at: target)
            state.cats.insert(moved, at: first)
        }
        return state
    }

    /// Whether this iPhone wrote something for the profile that differs from
    /// what the family wrote (the family's value is the one kept): the one
    /// case where linking asks before it goes ahead.
    static func differs(_ care: CatCareState, toolCatID: UUID, profile: UUID) -> Bool {
        guard let family = care.cats.first(where: { $0.catID == toolCatID && $0.deletedAt == nil }),
              let own = care.cats.first(where: { $0.profileID == profile && $0.deletedAt == nil && $0.catID != toolCatID })
        else { return false }
        func differ<V: Codable & Equatable & Sendable>(_ a: CatCareStamped<V>?, _ b: CatCareStamped<V>?) -> Bool {
            guard let a, let b else { return false }
            return a.value != b.value
        }
        return differ(family.name, own.name) || differ(family.sex, own.sex) || differ(family.neutered, own.neutered)
            || differ(family.birthday, own.birthday) || differ(family.adoptionDay, own.adoptionDay)
            || differ(family.coat, own.coat) || differ(family.marks, own.marks) || differ(family.microchip, own.microchip)
            || differ(family.microchipAnswer, own.microchipAnswer) || differ(family.indoorOnly, own.indoorOnly)
            || differ(family.conditions, own.conditions) || differ(family.allergy, own.allergy)
            || differ(family.vaccinationAnswer, own.vaccinationAnswer) || differ(family.specialDiet, own.specialDiet)
            || differ(family.water, own.water) || differ(family.litter, own.litter)
            || differ(family.temperament, own.temperament) || differ(family.vetOverride, own.vetOverride)
    }

    /// Unlinks: the family cat keeps its record (and its proof photos). This
    /// iPhone's cat gets back its own record as it was before linking (what
    /// it wrote is shown again), with what was written while linked filling
    /// only what it had not got; with no record before, a copy of everything.
    /// 見分ける写真 go with this iPhone's cat. Nothing is erased.
    static func unlinking(_ care: CatCareState, toolCatID: UUID, profile: UUID,
                          makeID: () -> UUID = UUID.init) throws -> CatCareState {
        var state = care
        guard let target = state.cats.firstIndex(where: { $0.catID == toolCatID && $0.deletedAt == nil }),
              state.cats[target].profileID == profile else { throw FamilyNotebookError.mappingConflict }
        var family = state.cats[target]
        // The shared copy, without the proof photos of the shared vaccinations.
        var copy = family
        copy.vaccinations = family.vaccinations.map { var row = $0; row.proof = nil; row.familyPhotoLink = nil; return row }
        copy.detachedVaccinations = nil
        copy.partialWeights = nil
        copy.sharedWindowIDs = []
        if let kept = state.cats.lastIndex(where: { $0.profileID == profile && $0.deletedAt != nil && $0.catID != toolCatID }) {
            var own = state.cats[kept]
            own.deletedAt = nil
            fill(&own, from: &copy)
            state.cats[kept] = own
        } else {
            copy.catID = makeID()
            guard !state.cats.contains(where: { $0.catID == copy.catID }) else { throw FamilyNotebookError.mappingConflict }
            state.cats.append(copy)
        }
        family.facePhoto = nil
        family.bodyPhoto = nil
        family.profileID = nil
        state.cats[target] = family
        return state
    }

    private static func fill(_ record: inout CatCareRecord, from own: inout CatCareRecord) {
        func keep<V: Codable & Equatable & Sendable>(_ field: inout CatCareStamped<V>?, _ value: CatCareStamped<V>?) {
            if field == nil { field = value }
        }
        keep(&record.name, own.name); keep(&record.sex, own.sex); keep(&record.neutered, own.neutered)
        keep(&record.birthday, own.birthday); keep(&record.adoptionDay, own.adoptionDay)
        keep(&record.coat, own.coat); keep(&record.marks, own.marks); keep(&record.microchip, own.microchip)
        keep(&record.microchipAnswer, own.microchipAnswer); keep(&record.indoorOnly, own.indoorOnly)
        keep(&record.conditions, own.conditions); keep(&record.allergy, own.allergy)
        keep(&record.vaccinationAnswer, own.vaccinationAnswer); keep(&record.specialDiet, own.specialDiet)
        keep(&record.water, own.water); keep(&record.litter, own.litter); keep(&record.temperament, own.temperament)
        keep(&record.vetOverride, own.vetOverride)
        // 見分ける写真 are not in the notebook: they move to the linked record.
        if record.facePhoto == nil { record.facePhoto = own.facePhoto; own.facePhoto = nil }
        if record.bodyPhoto == nil { record.bodyPhoto = own.bodyPhoto; own.bodyPhoto = nil }
        func add<E: CatCareListEntry>(_ list: inout [E], _ more: [E]) {
            let known = Set(list.map(\.id))
            list += more.filter { !known.contains($0.id) }
        }
        add(&record.weights, own.weights); add(&record.medications, own.medications)
        add(&record.vaccinations, own.vaccinations); add(&record.meals, own.meals)
        let partialIDs = Set((record.partialWeights ?? []).map(\.id))
        let partial = (own.partialWeights ?? []).filter { !partialIDs.contains($0.id) }
        if !partial.isEmpty { record.partialWeights = (record.partialWeights ?? []) + partial }
        let detachedIDs = Set((record.detachedVaccinations ?? []).map(\.displayKey))
        let detached = (own.detachedVaccinations ?? []).filter { !detachedIDs.contains($0.displayKey) }
        if !detached.isEmpty { record.detachedVaccinations = (record.detachedVaccinations ?? []) + detached }
        record.sharedWindowIDs = Array(Set(record.sharedWindowIDs).union(own.sharedWindowIDs)).sorted()
        record.reviewedAt = [record.reviewedAt, own.reviewedAt].compactMap { $0 }.max()
    }

    // MARK: Who is asked, and about which cats

    /// A family cat this iPhone shows as its own page (not linked to a cat of
    /// this iPhone), with its name.
    struct Unlinked: Equatable, Identifiable, Sendable {
        let id: UUID
        let toolID: UUID
        let name: String
    }

    /// Family cats without a cat of this iPhone, in the notebook's order.
    /// A cat whose record already has a profile (linked before) is linked.
    static func unlinked(_ snapshot: FamilyNotebookSnapshot, care: CatCareState?,
                         name: (UUID) -> String) -> [Unlinked] {
        guard !snapshot.sharingEnded else { return [] }
        var seen = Set<UUID>()
        return snapshot.activeMappings.compactMap { mapping in
            guard mapping.recordID == nil, let tool = mapping.toolCatID, seen.insert(mapping.familyCatID).inserted,
                  snapshot.fieldState(for: .init(familyCatID: mapping.familyCatID, field: nil))?.isDeleted != true,
                  mapping.profileID == nil,
                  care?.cats.first(where: { $0.catID == tool && $0.deletedAt == nil })?.profileID == nil
            else { return nil }
            return Unlinked(id: mapping.familyCatID, toolID: tool, name: name(mapping.familyCatID))
        }
    }

    /// This iPhone's cats to offer for one family cat: not linked to another
    /// family cat, a cat with the same name first (still only an offer).
    static func candidates<Cat>(for name: String, among cats: [Cat], id: (Cat) -> UUID?, name catName: (Cat) -> String,
                                linked: Set<UUID>) -> [Cat] {
        let wanted = normalized(name)
        let open = cats.filter { id($0).map { !linked.contains($0) } ?? false }
        return open.filter { normalized(catName($0)) == wanted } + open.filter { normalized(catName($0)) != wanted }
    }

    /// The family cat with the same name as a cat being added to the
    /// notebook, not answered 「べつの子」 yet (`skipping`). 11/19: with two or
    /// more of one name, each is asked about in turn: still only a question,
    /// never a guess, and a cat is not added again silently beside them.
    static func sameName(_ name: String, in unlinked: [Unlinked], skipping: Set<UUID> = []) -> Unlinked? {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return nil }
        return unlinked.first { !skipping.contains($0.id) && normalized($0.name) == wanted }
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCompatibilityMapping.lowercased()
    }

    /// The key the person's answer is kept under (this iPhone only).
    static func answerKey(family: UUID, cat: UUID) -> String {
        family.uuidString.lowercased() + ":" + cat.uuidString.lowercased()
    }

    /// The one family cat to ask 「同じ子ですか」 about: not closed in this
    /// launch and not answered (`key` nil: never asked).
    static func firstUnanswered(_ unlinked: [Unlinked], closed: Set<UUID>, answered: Set<String>,
                                key: (UUID) -> String?) -> Unlinked? {
        unlinked.first { cat in !closed.contains(cat.id) && !(key(cat.id).map { answered.contains($0) } ?? true) }
    }

    /// The answer keys of the family cats this iPhone linked to one of its
    /// pages (FamilyCatLinkAnswersMemory keeps no copy of those).
    static func linkedAnswerKeys(in snapshot: FamilyNotebookSnapshot) -> Set<String> {
        Set(snapshot.activeMappings.filter { $0.recordID == nil && $0.profileID != nil }
            .map { answerKey(family: snapshot.familyID, cat: $0.familyCatID) })
    }
}

/// 11/15 (段 1): one order of cats for the whole family, kept in the notebook
/// as each cat's `position` (an integer; one operation per cat, so a new
/// order reaches the family cat by cat, never all at once). The order is a
/// sort of the cats that exist, so two people moving cats at the same time
/// can neither lose nor double a cat: equal places fall back to the cat's ID.
enum FamilyNotebookCatOrder {
    /// The cat's place, or nil (never set, cleared, or out of range).
    static func position(_ cat: UUID, in snapshot: FamilyNotebookSnapshot) -> Int? {
        guard let state = snapshot.fieldState(for: .init(familyCatID: cat, field: .position)), !state.isDeleted,
              case .integer(let value) = state.operation.value,
              FamilyNotebookField.positionRange.contains(value) else { return nil }
        return value
    }

    /// The cats in the family's order: placed cats by place, then the others;
    /// equal places and unplaced cats in the order of their IDs.
    static func ordered(_ cats: [UUID], in snapshot: FamilyNotebookSnapshot) -> [UUID] {
        let places = Dictionary(cats.map { ($0, position($0, in: snapshot)) }, uniquingKeysWith: { first, _ in first })
        return Array(Set(cats)).sorted { a, b in
            switch (places[a] ?? nil, places[b] ?? nil) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.uuidString < b.uuidString
            }
        }
    }

    /// The first places, written once: only by the person who put the cat
    /// into the notebook, from the iPhone that has it as one of its own cats
    /// (its mapping names a profile), in that iPhone's order of profiles, and
    /// only for cats with no place written by anyone yet. Placed after every
    /// place already in the notebook. Everyone else keeps what they read.
    static func initialPositions(_ snapshot: FamilyNotebookSnapshot, person: String,
                                 profileOrder: [UUID]) -> [(cat: UUID, position: Int)] {
        guard !snapshot.sharingEnded else { return [] }
        let cats = snapshot.activeMappings.filter { $0.recordID == nil && $0.toolCatID != nil }
        var eligible: [(cat: UUID, rank: Int)] = []
        for mapping in cats {
            let cat = mapping.familyCatID
            guard let profile = mapping.profileID, let rank = profileOrder.firstIndex(of: profile),
                  !eligible.contains(where: { $0.cat == cat }),
                  snapshot.fieldState(for: .init(familyCatID: cat, field: nil))?.isDeleted != true,
                  !snapshot.operations.contains(where: { $0.target.familyCatID == cat && $0.target.field == .position }),
                  snapshot.operations.filter({ $0.target.familyCatID == cat }).min(by: { $0.version < $1.version })?.author.personID == person
            else { continue }
            eligible.append((cat, rank))
        }
        let known = Set(snapshot.operations.map(\.target.familyCatID)).compactMap { position($0, in: snapshot) }
        let base = (known.max() ?? -1) + 1
        return eligible.sorted { $0.rank < $1.rank }.enumerated().compactMap { index, item in
            let value = base + index
            return FamilyNotebookField.positionRange.contains(value) ? (item.cat, value) : nil
        }
    }

    /// The places for a new order: 0, 1, 2… Only cats whose place changes.
    static func positions(for order: [UUID], in snapshot: FamilyNotebookSnapshot) -> [(cat: UUID, position: Int)] {
        order.enumerated().compactMap { index, cat in
            guard FamilyNotebookField.positionRange.contains(index), position(cat, in: snapshot) != index else { return nil }
            return (cat, index)
        }
    }

    /// The 旅立った日 the family shared for a cat (someone confirmed it to
    /// send it; this only reads it), or nil.
    static func sharedFarewell(_ cat: UUID, in snapshot: FamilyNotebookSnapshot) -> CatCareDay? {
        guard let state = snapshot.fieldState(for: .init(familyCatID: cat, field: .farewellDay)), !state.isDeleted,
              case .day(let text) = state.operation.value else { return nil }
        return CatCareDay(isoDay: text)
    }
}
