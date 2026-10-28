import Foundation

enum FamilyNotebookMigrationError: Error, Equatable {
    case unreadableSource, unsupportedSchema, invalidSource, missingCatMapping, ambiguousCatMapping, changedRecordMapping
}

/// Values already read from the private stores. Constructing a migration never
/// opens a live store: CareHandoffRepository's initializer can clean up photos.
struct FamilyNotebookMigrationSource {
    let catCare: CatCareState?
    let handoff: CareHandoffPlan?
    let visits: [VeterinaryVisit]

    init(catCare: CatCareDecoding.Result? = nil, handoff: CareHandoffPlan? = nil,
         visits: [VeterinaryVisit] = []) throws {
        if let catCare {
            guard catCare.unreadableCatCount == 0 else { throw FamilyNotebookMigrationError.unreadableSource }
            guard (1...CatCareState.currentSchemaVersion).contains(catCare.state.schemaVersion) else {
                throw FamilyNotebookMigrationError.unsupportedSchema
            }
            guard catCare.state.mutationRevision >= 0,
                  Set(catCare.state.cats.map(\.catID)).count == catCare.state.cats.count else {
                throw FamilyNotebookMigrationError.invalidSource
            }
            for cat in catCare.state.cats {
                guard Set(cat.weights.map(\.id)).count == cat.weights.count,
                      Set(cat.medications.map(\.id)).count == cat.medications.count,
                      Set(cat.vaccinations.map(\.id)).count == cat.vaccinations.count,
                      Set(cat.meals.map(\.id)).count == cat.meals.count else {
                    throw FamilyNotebookMigrationError.invalidSource
                }
            }
        }
        if let handoff {
            guard handoff.schemaVersion == 1 else { throw FamilyNotebookMigrationError.unsupportedSchema }
            try handoff.validate()
        }
        guard Set(visits.map(\.id)).count == visits.count else { throw FamilyNotebookMigrationError.invalidSource }
        for visit in visits {
            guard !visit.catName.isEmpty, visit.catName.count <= 200,
                  visit.observations.count <= 500, visit.questions.count <= 500,
                  visit.entries.count <= 20,
                  Set(visit.entries.map(\.id)).count == visit.entries.count,
                  Set(visit.entries.map(\.sourceNoteID)).count == visit.entries.count else {
                throw FamilyNotebookMigrationError.invalidSource
            }
            for entry in visit.entries {
                guard entry.text.count <= 500 else { throw FamilyNotebookMigrationError.invalidSource }
                try entry.weight?.validate()
            }
        }
        self.catCare = catCare?.state
        self.handoff = handoff
        self.visits = visits
    }

    /// Missing inputs are allowed; unreadable inputs are never replaced with an
    /// empty store. Veterinary snapshots come from `visits()`, which validates
    /// its private manifest without deleting or creating records.
    static func decode(catCareData: Data? = nil, handoffData: Data? = nil,
                       visits: [VeterinaryVisit] = []) throws -> Self {
        let care = try catCareData.map(CatCareDecoding.decode)
        let handoff = try handoffData.map { try JSONDecoder().decode(CareHandoffPlan.self, from: $0) }
        return try Self(catCare: care, handoff: handoff, visits: visits)
    }
}

struct FamilyNotebookMigrationPreparation {
    let plan: FamilyNotebookImportPlan
    /// The source photos stay private and untouched, including photo-only notes.
    let omittedPhotoEntries: Int
}

enum FamilyNotebookMigration {
    /// The caller explicitly supplies cat links and the destination's remembered
    /// record mappings. No name matching, photo reading, source writes or network.
    /// Store.applyImport atomically commits this plan, its mappings and its ledger.
    static func prepare(source: FamilyNotebookMigrationSource, familyID: UUID,
                        mappings: [FamilyNotebookLocalMapping], now: Date = Date(),
                        makeRecordID: () -> UUID = UUID.init) throws -> FamilyNotebookMigrationPreparation {
        var builder = try Builder(familyID: familyID, mappings: mappings, now: now)
        if let care = source.catCare { try builder.copy(care, makeRecordID: makeRecordID) }
        if let handoff = source.handoff { try builder.copy(handoff, makeRecordID: makeRecordID) }
        for visit in source.visits { try builder.copy(visit, makeRecordID: makeRecordID) }
        return FamilyNotebookMigrationPreparation(
            plan: FamilyNotebookImportPlan(familyID: familyID, entries: builder.entries, mappings: builder.mappings),
            omittedPhotoEntries: builder.omittedPhotoEntries)
    }

    private struct Builder {
        let familyID: UUID
        let now: Date
        var mappings: [FamilyNotebookLocalMapping]
        var entries: [FamilyNotebookImportEntry] = []
        var omittedPhotoEntries = 0
        private var targets: Set<FamilyNotebookTarget> = []

        init(familyID: UUID, mappings: [FamilyNotebookLocalMapping], now: Date) throws {
            guard now.timeIntervalSince1970.isFinite,
                  Set(mappings.map(\.sourceKey)).count == mappings.count else {
                throw FamilyNotebookMigrationError.invalidSource
            }
            self.familyID = familyID; self.mappings = mappings; self.now = now
        }

        func cat(toolID: UUID?, profileID: UUID?) throws -> UUID {
            let matched = mappings.filter { mapping in
                mapping.recordID == nil && ((toolID != nil && mapping.toolCatID == toolID)
                    || (profileID != nil && mapping.profileID == profileID))
            }
            let ids = Set(matched.map(\.familyCatID))
            guard !ids.isEmpty else { throw FamilyNotebookMigrationError.missingCatMapping }
            guard ids.count == 1 else { throw FamilyNotebookMigrationError.ambiguousCatMapping }
            return ids.first!
        }

        mutating func record(_ sourceKey: String, catID: UUID, makeRecordID: () -> UUID) throws -> UUID {
            if let existing = mappings.first(where: { $0.sourceKey == sourceKey }) {
                guard existing.familyCatID == catID, let id = existing.recordID,
                      existing.profileID == nil, existing.toolCatID == nil else {
                    throw FamilyNotebookMigrationError.changedRecordMapping
                }
                return id
            }
            let id = makeRecordID()
            guard !mappings.contains(where: { $0.recordID == id || $0.familyCatID == id }) else {
                throw FamilyNotebookMigrationError.changedRecordMapping
            }
            mappings.append(.init(sourceKey: sourceKey, familyCatID: catID, recordID: id))
            return id
        }

        mutating func put(_ field: FamilyNotebookField?, _ value: FamilyNotebookValue?,
                          catID: UUID, collection: FamilyNotebookCollection = .cat,
                          recordID: UUID? = nil, parentID: UUID? = nil,
                          source: String, at date: Date) throws {
            guard date.timeIntervalSince1970.isFinite else { throw FamilyNotebookMigrationError.invalidSource }
            let target = FamilyNotebookTarget(familyCatID: catID, collection: collection,
                recordID: recordID, parentRecordID: parentID, field: field)
            try FamilyNotebookCore.validate(target: target, value: value)
            // CatCare is authoritative; older tool values only fill missing fields.
            // An explicit clear is a real value and prevents a legacy fallback.
            guard targets.insert(target).inserted else { return }
            // Store.applyImport separates this source date from the new author's
            // import time. Clinical dates are also preserved as explicit values.
            entries.append(.init(ledgerKey: source + ":" + collection.rawValue + ":" + (field?.rawValue ?? "deleted"),
                                 target: target, value: value, editedAt: date))
        }

        mutating func text(_ field: FamilyNotebookField, _ value: String, catID: UUID,
                           collection: FamilyNotebookCollection = .cat, recordID: UUID? = nil,
                           parentID: UUID? = nil, source: String, at date: Date) throws {
            try put(field, value.isEmpty ? .clear : .text(value), catID: catID, collection: collection,
                    recordID: recordID, parentID: parentID, source: source, at: date)
        }

        func day(_ value: CatCareDay?) throws -> FamilyNotebookValue {
            guard let value else { return .clear }
            guard CatCareDay(year: value.year, month: value.month, day: value.day) != nil else {
                throw FamilyNotebookMigrationError.invalidSource
            }
            return .day(String(format: "%04d-%02d-%02d", value.year, value.month, value.day))
        }

        mutating func vet(_ value: CatCareVet?, catID: UUID, source: String, at date: Date) throws {
            for (field, text) in [(FamilyNotebookField.vetName, value?.name), (.vetPhone, value?.phone), (.vetNote, value?.note)] {
                try put(field, text.map { $0.isEmpty ? .clear : .text($0) } ?? .clear,
                        catID: catID, source: source, at: date)
            }
        }

        mutating func copy(_ state: CatCareState, makeRecordID: () -> UUID) throws {
            for input in state.cats {
                let id = try cat(toolID: input.catID, profileID: input.profileID)
                let source = "migration:v1:cat-care:" + input.catID.uuidString.lowercased()
                if let deleted = input.deletedAt {
                    try put(nil, nil, catID: id, source: source, at: deleted)
                    continue
                }
                let texts: [(FamilyNotebookField, CatCareStamped<String>?)] = [
                    (.name, input.name), (.coat, input.coat), (.marks, input.marks), (.microchip, input.microchip),
                    (.conditions, input.conditions), (.specialDiet, input.specialDiet), (.water, input.water),
                    (.litter, input.litter), (.temperament, input.temperament)]
                for (field, stamp) in texts {
                    if let stamp { try text(field, stamp.value, catID: id, source: source, at: stamp.editedAt) }
                }
                if let stamp = input.sex { try text(.sex, stamp.value.rawValue, catID: id, source: source, at: stamp.editedAt) }
                if let stamp = input.neutered { try text(.neutered, stamp.value.rawValue, catID: id, source: source, at: stamp.editedAt) }
                if let stamp = input.indoorOnly { try text(.indoorOnly, stamp.value.rawValue, catID: id, source: source, at: stamp.editedAt) }
                if let stamp = input.birthday { try put(.birthday, day(stamp.value), catID: id, source: source, at: stamp.editedAt) }
                if let stamp = input.allergy {
                    try text(.allergyStatus, stamp.value.status.rawValue, catID: id, source: source, at: stamp.editedAt)
                    try text(.allergyText, stamp.value.text, catID: id, source: source, at: stamp.editedAt)
                }
                if let stamp = input.vetOverride {
                    try vet(stamp.value, catID: id, source: source, at: stamp.editedAt)
                } else if let stamp = state.household.vet {
                    try vet(stamp.value, catID: id, source: source, at: stamp.editedAt)
                }
                for item in input.weights {
                    let key = source + ":weight:" + item.id.uuidString.lowercased()
                    let recordID = try record(key, catID: id, makeRecordID: makeRecordID)
                    if let deleted = item.deletedAt {
                        try put(nil, nil, catID: id, collection: .weight, recordID: recordID, source: key, at: deleted)
                    } else {
                        try put(.measuredOn, day(item.measuredOn), catID: id, collection: .weight, recordID: recordID, source: key, at: item.editedAt)
                        try put(.grams, .integer(item.grams), catID: id, collection: .weight, recordID: recordID, source: key, at: item.editedAt)
                    }
                }
                for item in input.medications {
                    let key = source + ":medication:" + item.id.uuidString.lowercased()
                    let recordID = try record(key, catID: id, makeRecordID: makeRecordID)
                    if let deleted = item.deletedAt {
                        try put(nil, nil, catID: id, collection: .medication, recordID: recordID, source: key, at: deleted)
                    } else {
                        for (field, value) in [(FamilyNotebookField.medicationName, item.name), (.dose, item.dose), (.schedule, item.schedule), (.note, item.note)] {
                            try text(field, value, catID: id, collection: .medication, recordID: recordID, source: key, at: item.editedAt)
                        }
                        try put(.startedOn, day(item.startedOn), catID: id, collection: .medication, recordID: recordID, source: key, at: item.editedAt)
                        try put(.endedOn, day(item.endedOn), catID: id, collection: .medication, recordID: recordID, source: key, at: item.editedAt)
                    }
                }
                for item in input.vaccinations {
                    let key = source + ":vaccination:" + item.id.uuidString.lowercased()
                    let recordID = try record(key, catID: id, makeRecordID: makeRecordID)
                    if let deleted = item.deletedAt {
                        try put(nil, nil, catID: id, collection: .vaccination, recordID: recordID, source: key, at: deleted)
                    } else {
                        try text(.kind, item.kind, catID: id, collection: .vaccination, recordID: recordID, source: key, at: item.editedAt)
                        try put(.givenOn, day(item.givenOn), catID: id, collection: .vaccination, recordID: recordID, source: key, at: item.editedAt)
                        try put(.nextDueOn, day(item.nextDueOn), catID: id, collection: .vaccination, recordID: recordID, source: key, at: item.editedAt)
                    }
                }
                for item in input.meals {
                    let key = source + ":meal:" + item.id.uuidString.lowercased()
                    let recordID = try record(key, catID: id, makeRecordID: makeRecordID)
                    if let deleted = item.deletedAt {
                        try put(nil, nil, catID: id, collection: .meal, recordID: recordID, source: key, at: deleted)
                    } else {
                        for (field, value) in [(FamilyNotebookField.time, item.time), (.food, item.food), (.amount, item.amount)] {
                            try text(field, value, catID: id, collection: .meal, recordID: recordID, source: key, at: item.editedAt)
                        }
                        try put(.order, .integer(item.order), catID: id, collection: .meal, recordID: recordID, source: key, at: item.editedAt)
                    }
                }
            }
        }

        mutating func copy(_ plan: CareHandoffPlan, makeRecordID: () -> UUID) throws {
            for input in plan.cats {
                let profileID = input.profileID.flatMap(UUID.init(uuidString:))
                guard input.profileID == nil || profileID != nil else { throw FamilyNotebookMigrationError.invalidSource }
                let id = try cat(toolID: input.toolCatID ?? input.id, profileID: profileID)
                let source = "migration:v1:handoff:" + input.id.uuidString.lowercased()
                let recordID = try record(source, catID: id, makeRecordID: makeRecordID)
                for (field, value) in [(FamilyNotebookField.recipient, plan.recipient), (.period, plan.period), (.request, plan.request),
                                       (.catName, input.name), (.usualFood, input.usualFood ?? ""), (.water, input.water),
                                       (.toilet, input.toilet), (.handling, input.handling), (.important, input.important),
                                       (.callWhen, input.callWhen ?? ""), (.healthStatus, input.healthStatus.rawValue), (.healthDetails, input.healthDetails)] {
                    try text(field, value, catID: id, collection: .handoff, recordID: recordID, source: source, at: input.updatedAt)
                }
                for (order, meal) in input.meals.enumerated() {
                    let key = source + ":meal:" + meal.id.uuidString.lowercased()
                    let mealID = try record(key, catID: id, makeRecordID: makeRecordID)
                    for (field, value) in [(FamilyNotebookField.time, meal.time), (.food, meal.food), (.amount, meal.amount)] {
                        try text(field, value, catID: id, collection: .handoffMeal, recordID: mealID,
                                 parentID: recordID, source: key, at: input.updatedAt)
                    }
                    try put(.order, .integer(order), catID: id, collection: .handoffMeal, recordID: mealID,
                            parentID: recordID, source: key, at: input.updatedAt)
                }
                for (field, value) in [(FamilyNotebookField.name, input.name), (.water, input.water), (.litter, input.toilet), (.temperament, input.handling)] {
                    if !value.isEmpty { try text(field, value, catID: id, source: source, at: input.updatedAt) }
                }
                if !plan.veterinarian.isEmpty { try text(.vetName, plan.veterinarian, catID: id, source: source, at: input.updatedAt) }
            }
        }

        mutating func copy(_ visit: VeterinaryVisit, makeRecordID: () -> UUID) throws {
            // The old visit ID may refer to a profile or a tool cat. Both routes
            // require an explicit local mapping and must agree if both exist.
            let id = try cat(toolID: visit.catID, profileID: visit.catID)
            let source = "migration:v1:visit:" + visit.id.uuidString.lowercased()
            let recordID = try record(source, catID: id, makeRecordID: makeRecordID)
            for (field, value) in [(FamilyNotebookField.catName, visit.catName), (.observations, visit.observations), (.questions, visit.questions)] {
                try text(field, value, catID: id, collection: .visit, recordID: recordID, source: source, at: now)
            }
            try put(.startedOn, visit.startedOn.map(FamilyNotebookValue.day) ?? .clear,
                    catID: id, collection: .visit, recordID: recordID, source: source, at: now)
            try put(.completedAt, visit.completedAt.map(FamilyNotebookValue.date) ?? .clear,
                    catID: id, collection: .visit, recordID: recordID, source: source, at: now)
            for entry in visit.entries {
                guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || entry.weight != nil else {
                    omittedPhotoEntries += 1; continue
                }
                let key = source + ":entry:" + entry.id.uuidString.lowercased()
                let entryID = try record(key, catID: id, makeRecordID: makeRecordID)
                try text(.text, entry.text, catID: id, collection: .visitEntry, recordID: entryID,
                         parentID: recordID, source: key, at: entry.writtenAt ?? now)
                for (field, date) in [(FamilyNotebookField.capturedAt, entry.capturedAt), (.writtenAt, entry.writtenAt)] {
                    try put(field, date.map(FamilyNotebookValue.date) ?? .clear, catID: id, collection: .visitEntry,
                            recordID: entryID, parentID: recordID, source: key, at: entry.writtenAt ?? now)
                }
                if let weight = entry.weight {
                    try put(.grams, .integer(weight.grams), catID: id, collection: .visitEntry,
                            recordID: entryID, parentID: recordID, source: key, at: entry.writtenAt ?? now)
                    try put(.measuredOn, weight.measuredOn.map(FamilyNotebookValue.day) ?? .clear, catID: id,
                            collection: .visitEntry, recordID: entryID, parentID: recordID, source: key, at: entry.writtenAt ?? now)
                    if let name = weight.catName {
                        try text(.catName, name, catID: id, collection: .visitEntry, recordID: entryID,
                                 parentID: recordID, source: key, at: entry.writtenAt ?? now)
                    }
                }
            }
        }
    }
}
