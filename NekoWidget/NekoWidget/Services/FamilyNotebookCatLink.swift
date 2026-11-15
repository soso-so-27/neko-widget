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
    /// replaced record (its own values stay in it, nothing is erased).
    static func linking(_ care: CatCareState, toolCatID: UUID, profile: UUID, now: Date) throws -> CatCareState {
        var state = care
        guard let target = state.cats.firstIndex(where: { $0.catID == toolCatID && $0.deletedAt == nil })
        else { throw FamilyNotebookError.mappingConflict }
        var record = state.cats[target]
        guard record.profileID == nil || record.profileID == profile else { throw FamilyNotebookError.mappingConflict }
        record.profileID = profile
        for index in state.cats.indices where index != target {
            guard state.cats[index].profileID == profile, state.cats[index].deletedAt == nil else { continue }
            var own = state.cats[index]
            fill(&record, from: &own)
            // Kept, not erased: a value the family already had stays here.
            own.profileID = nil
            own.deletedAt = now
            state.cats[index] = own
        }
        state.cats[target] = record
        return state
    }

    /// Unlinks: the family cat keeps its record (and its proof photos); this
    /// iPhone's cat gets its own copy of everything written so far, and its
    /// own 見分ける写真. Nothing is erased on either side.
    static func unlinking(_ care: CatCareState, toolCatID: UUID, profile: UUID,
                          makeID: () -> UUID = UUID.init) throws -> CatCareState {
        var state = care
        guard let target = state.cats.firstIndex(where: { $0.catID == toolCatID && $0.deletedAt == nil }),
              state.cats[target].profileID == profile else { throw FamilyNotebookError.mappingConflict }
        var family = state.cats[target]
        var own = family
        own.catID = makeID()
        guard !state.cats.contains(where: { $0.catID == own.catID }) else { throw FamilyNotebookError.mappingConflict }
        own.profileID = profile
        // The proof photos stay with the shared vaccinations they belong to.
        own.vaccinations = family.vaccinations.map { var row = $0; row.proof = nil; row.familyPhotoLink = nil; return row }
        own.detachedVaccinations = nil
        own.partialWeights = nil
        own.sharedWindowIDs = []
        // 見分ける写真 are this iPhone's own: they go with this iPhone's cat.
        family.facePhoto = nil
        family.bodyPhoto = nil
        family.profileID = nil
        state.cats[target] = family
        state.cats.append(own)
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
    /// notebook, if exactly one unlinked family cat has it.
    static func sameName(_ name: String, in unlinked: [Unlinked]) -> Unlinked? {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return nil }
        let matches = unlinked.filter { normalized($0.name) == wanted }
        return matches.count == 1 ? matches[0] : nil
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCompatibilityMapping.lowercased()
    }

    /// The key the person's answer is kept under (this iPhone only).
    static func answerKey(family: UUID, cat: UUID) -> String {
        family.uuidString.lowercased() + ":" + cat.uuidString.lowercased()
    }
}
