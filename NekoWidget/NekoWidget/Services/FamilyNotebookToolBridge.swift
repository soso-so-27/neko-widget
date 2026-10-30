import Foundation

/// Projection and edit deltas for explicitly linked cats. No live store, name
/// matching, household contact, photo transfer or membership claim lives here.
enum FamilyNotebookToolBridge {
    static func linked(_ tool: UUID?, _ profile: UUID?, in snapshot: FamilyNotebookSnapshot) -> Bool {
        snapshot.mappings.contains { $0.recordID == nil &&
            ((tool != nil && $0.toolCatID == tool) || (profile != nil && $0.profileID == profile)) }
    }
    static func selected(_ plan: CareHandoffPlan, snapshot: FamilyNotebookSnapshot) -> CareHandoffPlan {
        var result = plan
        result.cats = plan.cats.filter { $0.familyDetached != true && linked($0.toolCatID ?? $0.id, $0.profileID.flatMap(UUID.init(uuidString:)), in: snapshot) }
        return result
    }
    static func selected(_ visits: [VeterinaryVisit], snapshot: FamilyNotebookSnapshot) -> [VeterinaryVisit] {
        visits.filter { $0.familyDetached != true && linked($0.catID, $0.catID, in: snapshot) }.map { visit in
            var result = visit; result.entries = visit.entries.filter { $0.familyRetained != true }; return result
        }
    }
    static func changes(before: FamilyNotebookMigrationSource, after: FamilyNotebookMigrationSource,
                        snapshot: FamilyNotebookSnapshot, now: Date = Date()) throws -> FamilyNotebookImportPlan {
        let next = try FamilyNotebookMigration.prepare(source: after, familyID: snapshot.familyID, mappings: snapshot.mappings, now: now).plan
        let old = try FamilyNotebookMigration.prepare(source: before, familyID: snapshot.familyID, mappings: next.mappings, now: now).plan
        let previous = Dictionary(uniqueKeysWithValues: old.entries.map { ($0.target,$0) })
        let current = Dictionary(uniqueKeysWithValues: next.entries.map { ($0.target,$0) })
        var entries = next.entries.filter { previous[$0.target]?.value != $0.value }
        // Only removal of a stable row becomes a tombstone. Field clearing is
        // represented by .clear and does not delete neighboring fields.
        func row(_ target: FamilyNotebookTarget) -> FamilyNotebookTarget {
            .init(familyCatID: target.familyCatID, collection: target.collection, recordID: target.recordID,
                  parentRecordID: target.parentRecordID, field: nil)
        }
        let present = Set(current.keys.map(row))
        for removed in Set(previous.keys.map(row)).subtracting(present) {
            entries.append(.init(ledgerKey: "tool-delete:" + (removed.recordID?.uuidString ?? removed.familyCatID.uuidString),
                target: removed, value: nil, editedAt: now))
        }
        // Retain mappings for a removed row even if it was created immediately
        // before an earlier tool-file write failed.
        var mappings = next.mappings
        for mapping in old.mappings where !mappings.contains(where: { $0.sourceKey == mapping.sourceKey }) { mappings.append(mapping) }
        return .init(familyID: snapshot.familyID, entries: entries, mappings: mappings)
    }

    static func localID(_ source: String, prefix: String) -> UUID? {
        guard source.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(source.dropFirst(prefix.count)))
    }
    static func mappings(_ snapshot: FamilyNotebookSnapshot, makeID: () -> UUID = UUID.init) throws -> [FamilyNotebookLocalMapping] {
        var result = snapshot.mappings
        for collection in [FamilyNotebookCollection.handoff,.visit] {
            let prefix = collection == .handoff ? "migration:v1:handoff:" : "migration:v1:visit:"
            for cat in Set(snapshot.operations.map { $0.target.familyCatID }).sorted(by: { $0.uuidString < $1.uuidString }) {
                guard result.contains(where: { $0.familyCatID == cat && $0.recordID == nil && $0.toolCatID != nil }) else { continue }
                let ids = Set(snapshot.operations.filter { $0.target.familyCatID == cat && $0.target.collection == collection }.compactMap { $0.target.recordID })
                for record in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                    var parent = result.first { $0.familyCatID == cat && $0.recordID == record && localID($0.sourceKey, prefix: prefix) != nil }
                    if parent == nil {
                        let value = FamilyNotebookLocalMapping(sourceKey: prefix + makeID().uuidString.lowercased(), familyCatID: cat, recordID: record)
                        guard !result.contains(where: { $0.sourceKey == value.sourceKey }) else { throw FamilyNotebookError.mappingConflict }
                        result.append(value); parent = value
                    }
                    let childCollection: FamilyNotebookCollection = collection == .handoff ? .handoffMeal : .visitEntry
                    let childPrefix = parent!.sourceKey + (collection == .handoff ? ":meal:" : ":entry:")
                    let children = Set(snapshot.operations.filter { $0.target.familyCatID == cat && $0.target.collection == childCollection && $0.target.parentRecordID == record }.compactMap { $0.target.recordID })
                    for child in children.sorted(by: { $0.uuidString < $1.uuidString }) {
                        if result.contains(where: { $0.familyCatID == cat && $0.recordID == child && localID($0.sourceKey, prefix: childPrefix) != nil }) { continue }
                        let value = FamilyNotebookLocalMapping(sourceKey: childPrefix + makeID().uuidString.lowercased(), familyCatID: cat, recordID: child)
                        guard !result.contains(where: { $0.sourceKey == value.sourceKey }) else { throw FamilyNotebookError.mappingConflict }
                        result.append(value)
                    }
                }
            }
        }
        return result
    }

    private struct Values {
        let snapshot: FamilyNotebookSnapshot, cat: UUID, collection: FamilyNotebookCollection, record: UUID
        var parent: UUID? = nil
        func state(_ field: FamilyNotebookField?) -> FamilyNotebookFieldState? {
            snapshot.fieldState(for: .init(familyCatID: cat, collection: collection, recordID: record, parentRecordID: parent, field: field))
        }
        var deleted: Bool { state(nil)?.isDeleted == true }
        func text(_ field: FamilyNotebookField, _ old: String = "") throws -> String {
            guard let value = state(field)?.operation.value else { return old }
            switch value { case .text(let text), .day(let text): return text; case .clear: return ""; default: throw FamilyNotebookError.invalidValue }
        }
        func date(_ field: FamilyNotebookField, _ old: Date? = nil) throws -> Date? {
            guard let value = state(field)?.operation.value else { return old }
            switch value { case .date(let date): return date; case .clear: return nil; default: throw FamilyNotebookError.invalidValue }
        }
        func number(_ field: FamilyNotebookField) throws -> Int? {
            guard let value = state(field)?.operation.value else { return nil }
            switch value { case .integer(let n): return n; case .clear: return nil; default: throw FamilyNotebookError.invalidValue }
        }
        var latest: FamilyNotebookOperation? {
            let fields = Set(snapshot.operations.filter { $0.target.familyCatID == cat && $0.target.collection == collection && $0.target.recordID == record }.compactMap { $0.target.field })
            return fields.compactMap { state($0)?.operation }.max { $0.version < $1.version }
        }
    }

    static func apply(_ snapshot: FamilyNotebookSnapshot, to original: CareHandoffPlan) throws -> CareHandoffPlan {
        var plan = original
        for mapping in snapshot.mappings {
            guard let record = mapping.recordID, let id = localID(mapping.sourceKey, prefix: "migration:v1:handoff:"),
                  let catMapping = snapshot.mappings.first(where: { $0.familyCatID == mapping.familyCatID && $0.recordID == nil && $0.toolCatID != nil }),
                  let tool = catMapping.toolCatID else { continue }
            let values = Values(snapshot: snapshot, cat: mapping.familyCatID, collection: .handoff, record: record)
            var cat = plan.cats.first { $0.id == id } ?? CareCat(id: id, toolCatID: tool, meals: [])
            guard (cat.toolCatID ?? cat.id) == tool || (catMapping.profileID != nil && cat.profileID.flatMap(UUID.init(uuidString:)) == catMapping.profileID) else { throw FamilyNotebookError.mappingConflict }
            if values.deleted {
                if let index = plan.cats.firstIndex(where: { $0.id == id }) { plan.cats[index].familyDetached = true }
                continue
            }
            guard cat.familyDetached != true, let latest = values.latest else { continue }
            var context = cat.familyContext ?? CareHandoffContext(recipient: plan.recipient, period: plan.period, request: plan.request)
            // Never copy a recipient from the receiving phone's unrelated
            // household into a missing shared field on a newly received cat.
            if !plan.cats.contains(where: { $0.id == id }) { context = .init() }
            context.recipient = try values.text(.recipient, context.recipient)
            context.period = try values.text(.period, context.period)
            context.request = try values.text(.request, context.request)
            cat.familyContext = context
            cat.name = try values.text(.catName, cat.name)
            cat.usualFood = try values.text(.usualFood, cat.usualFood ?? "")
            if values.state(.usualFood) != nil { cat.prefilledUsualFood = false; cat.prefilledFields?.remove("food") }
            if values.state(.catName) != nil { cat.prefilledFields?.remove("name") }
            if values.state(.handling) != nil { cat.prefilledFields?.remove("handling") }
            cat.water = try values.text(.water, cat.water); cat.toilet = try values.text(.toilet, cat.toilet)
            cat.handling = try values.text(.handling, cat.handling); cat.important = try values.text(.important, cat.important)
            cat.callWhen = try values.text(.callWhen, cat.callWhen ?? "")
            let health = try values.text(.healthStatus, cat.healthStatus.rawValue)
            guard let status = CareCat.HealthStatus(rawValue: health.isEmpty ? "unknown" : health) else { throw FamilyNotebookError.invalidValue }
            cat.healthStatus = status; cat.healthDetails = try values.text(.healthDetails, cat.healthDetails)
            var orders: [UUID:Int] = [:]
            for child in snapshot.mappings where child.familyCatID == mapping.familyCatID {
                guard let childRecord = child.recordID, let mealID = localID(child.sourceKey, prefix: mapping.sourceKey + ":meal:") else { continue }
                let childValues = Values(snapshot: snapshot, cat: mapping.familyCatID, collection: .handoffMeal, record: childRecord, parent: record)
                if childValues.deleted { cat.meals.removeAll { $0.id == mealID }; continue }
                guard childValues.latest != nil else { continue }
                var meal = cat.meals.first { $0.id == mealID } ?? CareMeal(id: mealID)
                meal.time = try childValues.text(.time, meal.time); meal.food = try childValues.text(.food, meal.food); meal.amount = try childValues.text(.amount, meal.amount)
                orders[mealID] = try childValues.number(.order) ?? cat.meals.count
                if let i = cat.meals.firstIndex(where: { $0.id == mealID }) { cat.meals[i] = meal } else { cat.meals.append(meal) }
            }
            let oldOrder = Dictionary(uniqueKeysWithValues: cat.meals.enumerated().map { ($0.element.id,$0.offset) })
            cat.meals.sort { (orders[$0.id] ?? oldOrder[$0.id] ?? 0) < (orders[$1.id] ?? oldOrder[$1.id] ?? 0) }
            cat.updatedAt = latest.editedAt
            if let i = plan.cats.firstIndex(where: { $0.id == id }) { plan.cats[i] = cat } else { plan.cats.append(cat) }
        }
        if plan.cats.contains(where: { $0.familyContext != nil || $0.familyDetached != nil }) { plan.schemaVersion = 2 }
        try plan.validate(); return plan
    }

    static func apply(_ snapshot: FamilyNotebookSnapshot, to original: [VeterinaryVisit]) throws -> [VeterinaryVisit] {
        var visits = original
        for mapping in snapshot.mappings {
            guard let record = mapping.recordID, let id = localID(mapping.sourceKey, prefix: "migration:v1:visit:"),
                  let cat = snapshot.mappings.first(where: { $0.familyCatID == mapping.familyCatID && $0.recordID == nil })?.toolCatID else { continue }
            let values = Values(snapshot: snapshot, cat: mapping.familyCatID, collection: .visit, record: record)
            let old = visits.first { $0.id == id }
            guard old == nil || old?.catID == cat || snapshot.mappings.contains(where: { $0.familyCatID == mapping.familyCatID && $0.recordID == nil && $0.profileID == old?.catID }) else { throw FamilyNotebookError.mappingConflict }
            if values.deleted {
                if let i = visits.firstIndex(where: { $0.id == id }) { visits[i].familyDetached = true }
                continue
            }
            guard old?.familyDetached != true, values.latest != nil else { continue }
            let started = try values.text(.startedOn, old?.startedOn ?? "")
            var visit = VeterinaryVisit(id: id, catID: old?.catID ?? cat, catName: try values.text(.catName, old?.catName ?? "猫"),
                revision: old?.revision ?? UUID(), startedOn: started.isEmpty ? nil : started,
                observations: try values.text(.observations, old?.observations ?? ""), questions: try values.text(.questions, old?.questions ?? ""),
                entries: old?.entries ?? [], completedAt: try values.date(.completedAt, old?.completedAt), familyRecordID: record)
            for child in snapshot.mappings where child.familyCatID == mapping.familyCatID {
                guard let childRecord = child.recordID, let entryID = localID(child.sourceKey, prefix: mapping.sourceKey + ":entry:") else { continue }
                let v = Values(snapshot: snapshot, cat: mapping.familyCatID, collection: .visitEntry, record: childRecord, parent: record)
                if v.deleted {
                    // The shared deletion does not erase a private photo copy.
                    if let i = visit.entries.firstIndex(where: { $0.id == entryID }) { visit.entries[i].familyRetained = true }
                    continue
                }
                guard v.latest != nil else { continue }
                let previous = visit.entries.first { $0.id == entryID }
                let grams = try v.number(.grams) ?? (v.state(.grams) == nil ? previous?.weight?.grams : nil)
                let day = try v.text(.measuredOn, previous?.weight?.measuredOn ?? "")
                let weight = grams.map { PhotoMemoWeightValue(grams: $0, measuredOn: day.isEmpty ? nil : day, catName: visit.catName) }
                let entry = VeterinaryVisitEntry(id: entryID, sourceNoteID: previous?.sourceNoteID ?? entryID,
                    sourceRevision: previous?.sourceRevision ?? (v.latest?.id.uuidString ?? entryID.uuidString), text: try v.text(.text, previous?.text ?? ""),
                    capturedAt: try v.date(.capturedAt, previous?.capturedAt), writtenAt: try v.date(.writtenAt, previous?.writtenAt),
                    weight: weight, photoFile: previous?.photoFile, sourcePhotoIdentifier: previous?.sourcePhotoIdentifier)
                if let i = visit.entries.firstIndex(where: { $0.id == entryID }) { visit.entries[i] = entry } else { visit.entries.append(entry) }
            }
            if let old, visit != old { visit.revision = UUID() }
            if let i = visits.firstIndex(where: { $0.id == id }) { visits[i] = visit } else { visits.append(visit) }
        }
        _ = try FamilyNotebookMigrationSource(visits: visits)
        return visits
    }
}

#if os(iOS)
/// Durable local notebook first, private tool projection second. It uses the
/// already-established local binding; it neither signs in nor grants access.
enum FamilyNotebookToolSharing {
    private static func context() throws -> (FamilyNotebookStore, FamilyNotebookAuthor)? {
        guard (Bundle.main.object(forInfoDictionaryKey: "FamilyNotebookProductionEnabled") as? String) == "YES" else { return nil }
        guard let binding = try FamilyNotebookLocalBinding.load(support: AppRecordDataset.support) else { return nil }
        let store = try FamilyNotebookStore(directory: binding.directory(support: AppRecordDataset.support), familyID: binding.familyID, deviceID: binding.deviceID)
        guard try !store.snapshot().sharingEnded else { return nil }
        return (store,binding.author)
    }
    static func handoffChanged(before: CareHandoffPlan, after: CareHandoffPlan, directory: URL) throws {
        guard directory.standardizedFileURL == AppRecordDataset.directory("CareHandoff").standardizedFileURL,
              let (store,author) = try context() else { return }
        let snapshot = try store.snapshot()
        let old = FamilyNotebookToolBridge.selected(before, snapshot: snapshot), next = FamilyNotebookToolBridge.selected(after, snapshot: snapshot)
        let plan = try FamilyNotebookToolBridge.changes(before: .init(handoff: old), after: .init(handoff: next), snapshot: snapshot)
        if !plan.entries.isEmpty { try store.applyLocalChanges(plan, author: author) }
    }
    static func visitsChanged(before: [VeterinaryVisit], after: [VeterinaryVisit], directory: URL) throws {
        guard directory.standardizedFileURL == AppRecordDataset.directory("VeterinaryVisits").standardizedFileURL,
              let (store,author) = try context() else { return }
        let snapshot = try store.snapshot()
        let old = FamilyNotebookToolBridge.selected(before, snapshot: snapshot), next = FamilyNotebookToolBridge.selected(after, snapshot: snapshot)
        let plan = try FamilyNotebookToolBridge.changes(before: .init(visits: old), after: .init(visits: next), snapshot: snapshot)
        if !plan.entries.isEmpty { try store.applyLocalChanges(plan, author: author) }
    }
    private static func received() throws -> FamilyNotebookSnapshot? {
        guard let (store,author) = try context() else { return nil }
        let snapshot = try store.snapshot(), mappings = try FamilyNotebookToolBridge.mappings(snapshot)
        if mappings != snapshot.mappings {
            return try store.applyImport(.init(familyID: snapshot.familyID, entries: [], mappings: mappings), author: author)
        }
        return snapshot
    }
    static func handoffReceived(_ plan: CareHandoffPlan) throws -> CareHandoffPlan {
        guard let snapshot = try received() else { return plan }
        return try FamilyNotebookToolBridge.apply(snapshot, to: plan)
    }
    static func visitsReceived(_ visits: [VeterinaryVisit]) throws -> [VeterinaryVisit] {
        guard let snapshot = try received() else { return visits }
        return try FamilyNotebookToolBridge.apply(snapshot, to: visits)
    }
}
#endif
