import Foundation
import CryptoKit

/// Stable across a new local mapping of the same family. This is derived only
/// from random record IDs, never from names, notes, dates, or membership data.
enum FamilyNotebookAttachmentLink {
    static func key(_ snapshot: FamilyNotebookSnapshot, cat: UUID, kind: String, record: UUID, parent: UUID? = nil) -> String {
        let material = ["neko-family-attachment-v1", snapshot.familyID.uuidString, cat.uuidString,
                        kind, parent?.uuidString ?? "", record.uuidString].joined(separator: "/")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Local IDs stay local. Received cats never match an existing personal cat by
/// name, and family writes never change household-wide contacts or vet details.
enum FamilyNotebookCatCareBridge {
    static let fields: [FamilyNotebookField] = [
        .name, .sex, .neutered, .indoorOnly, .birthday, .adoptionDay, .coat, .marks, .microchip,
        .conditions, .allergyStatus, .allergyText, .specialDiet, .water, .litter, .temperament,
        .vetName, .vetPhone, .vetNote
    ]
    // Initial import never converts an unset profile to a deletion, and a
    // received family stamp wins over an old profile's private initial value.
    static func importingAdoptionDays(_ profiles: [CatProfile], into original: CatCareState, at now: Date) -> CatCareState {
        var state = original
        for profile in profiles {
            let dates = profile.resolvedLifeDates
            guard let date = dates.adoptionDay,
                  let day = CatCareDay(year: date.year, month: date.month, day: date.day) else { continue }
            let indices = state.cats.indices.filter { state.cats[$0].profileID == profile.id && state.cats[$0].deletedAt == nil }
            guard indices.count <= 1 else { continue }
            if let index = indices.first {
                guard state.cats[index].adoptionDay == nil else { continue }
                state.cats[index].adoptionDay = .init(value: .init(day: day, isApproximate: dates.adoptionDayIsApproximate), editedAt: now, editedBy: "import:Profile")
            } else {
                var record = CatCareRecord(catID: UUID(), profileID: profile.id)
                record.name = .init(value: profile.displayName, editedAt: now, editedBy: "import:Profile")
                record.adoptionDay = .init(value: .init(day: day, isApproximate: dates.adoptionDayIsApproximate), editedAt: now, editedBy: "import:Profile")
                state.cats.append(record)
            }
        }
        return state
    }

    static func projectingAdoptionDays(_ care: CatCareState, into original: CatHouseholdIdentityState) -> CatHouseholdIdentityState {
        var state = original
        for index in state.profiles.indices {
            let matches = care.cats.filter { $0.profileID == state.profiles[index].id && $0.deletedAt == nil }
            guard matches.count == 1, let stamp = matches[0].adoptionDay else { continue }
            var dates = state.profiles[index].resolvedLifeDates
            if let value = stamp.value, let date = value.day.date(), let life = CatLifeDate(date: date) {
                dates.adoptionDay = life; dates.adoptionDayIsApproximate = value.isApproximate
            } else { dates.adoptionDay = nil; dates.adoptionDayIsApproximate = false }
            state.profiles[index].setLifeDates(dates, preferredPrimaryKind: state.profiles[index].lifeReference?.kind)
        }
        return state
    }

    static let lists: [FamilyNotebookCollection] = [.weight, .medication, .vaccination, .meal]

    static func mappings(for snapshot: FamilyNotebookSnapshot, existingLocalIDs: Set<UUID> = [], makeID: () -> UUID = UUID.init) throws -> [FamilyNotebookLocalMapping] {
        var result = snapshot.activeMappings
        for cat in Set(snapshot.operations.map { $0.target.familyCatID }).sorted(by: { $0.uuidString < $1.uuidString }) {
            if !result.contains(where: { $0.familyCatID == cat && $0.recordID == nil && $0.toolCatID != nil }) {
                // A tombstone without a local copy need not create an empty cat.
                if snapshot.fieldState(for: .init(familyCatID: cat, field: nil))?.isDeleted == true { continue }
                let previous = FamilyNotebookCatRelink.previousCat(cat, in: snapshot).flatMap { prior in
                    snapshot.mappings.first { $0.familyCatID == prior && $0.recordID == nil && $0.toolCatID != nil }
                }
                let local = previous?.toolCatID ?? makeID()
                guard (previous != nil || !existingLocalIDs.contains(local)),
                      !result.contains(where: { $0.toolCatID == local }) else { throw FamilyNotebookError.mappingConflict }
                result.append(.init(sourceKey: "cat:" + local.uuidString.lowercased(), familyCatID: cat,
                                    profileID: previous?.profileID, toolCatID: local))
            }
            guard let local = result.first(where: { $0.familyCatID == cat && $0.recordID == nil && $0.toolCatID != nil })?.toolCatID else { continue }
            for collection in lists {
                let ids = Set(snapshot.operations.filter { $0.target.familyCatID == cat && $0.target.collection == collection }.compactMap { $0.target.recordID })
                for record in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                    if collection == .vaccination && [FamilyNotebookVaccinationAnswer.recordID(cat: cat), FamilyNotebookMicrochipAnswer.recordID(cat: cat), FamilyNotebookCatRelink.recordID(cat: cat)].contains(record) { continue }
                    let prefix = sourcePrefix(local, collection)
                    if result.contains(where: { $0.familyCatID == cat && $0.recordID == record && $0.sourceKey.hasPrefix(prefix) }) { continue }
                    let retained = try FamilyNotebookCatRelink.retainedMapping(cat: cat, record: record, in: snapshot)
                    let source = retained?.sourceKey.hasPrefix(prefix) == true ? retained!.sourceKey : prefix + makeID().uuidString.lowercased()
                    guard !result.contains(where: { $0.sourceKey == source }) else { throw FamilyNotebookError.mappingConflict }
                    result.append(.init(sourceKey: source, familyCatID: cat, recordID: record))
                }
            }
        }
        return result
    }
    private static func sourcePrefix(_ cat: UUID, _ collection: FamilyNotebookCollection) -> String {
        "migration:v1:cat-care:" + cat.uuidString.lowercased() + ":" + collection.rawValue + ":"
    }
    static func localRecordID(_ mapping: FamilyNotebookLocalMapping, cat: UUID, collection: FamilyNotebookCollection) -> UUID? {
        let prefix = sourcePrefix(cat, collection)
        guard mapping.sourceKey.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(mapping.sourceKey.dropFirst(prefix.count)))
    }
    static func apply(_ snapshot: FamilyNotebookSnapshot, to original: CatCareState) throws -> CatCareState {
        var state = original
        for mapping in snapshot.activeMappings where mapping.recordID == nil {
            guard let local = mapping.toolCatID else { continue }
            let cat = mapping.familyCatID
            let removed = snapshot.fieldState(for: .init(familyCatID: cat, field: nil))
            if removed?.isDeleted == true {
                if let i = state.cats.firstIndex(where: { $0.catID == local }) { state.cats[i].deletedAt = removed!.operation.editedAt }
                continue
            }
            if !state.cats.contains(where: { $0.catID == local }) { state.cats.append(.init(catID: local, profileID: mapping.profileID)) }
            guard let index = state.cats.firstIndex(where: { $0.catID == local }), state.cats[index].deletedAt == nil else { continue }
            for field in fields {
                guard let resolved = snapshot.fieldState(for: .init(familyCatID: cat, field: field)), !resolved.isDeleted,
                      let value = resolved.operation.value else { continue }
                try put(value, field, into: &state.cats[index], operation: resolved.operation)
            }
            for collection in lists {
                for item in snapshot.activeMappings where item.familyCatID == cat && item.recordID != nil {
                    guard let record = item.recordID, let localID = localRecordID(item, cat: local, collection: collection) else { continue }
                    if collection == .vaccination && [FamilyNotebookVaccinationAnswer.recordID(cat: cat), FamilyNotebookMicrochipAnswer.recordID(cat: cat), FamilyNotebookCatRelink.recordID(cat: cat)].contains(record) { continue }
                    let values = Values(snapshot: snapshot, cat: cat, collection: collection, record: record)
                    try apply(values, localID: localID, into: &state.cats[index])
                }
            }
            if let answer = snapshot.fieldState(for: FamilyNotebookMicrochipAnswer.target(cat: cat)), !answer.isDeleted {
                var status: CatCareAbsenceAnswer
                switch answer.operation.value {
                case .text(FamilyNotebookMicrochipAnswer.noneText): status = .none
                case .clear: status = .unknown
                default: throw FamilyNotebookError.invalidValue
                }
                if let number = snapshot.fieldState(for: .init(familyCatID: cat, field: .microchip)) {
                    let newer: Bool
                    if let n = number.operation.importedSourceEditedAt, let a = answer.operation.importedSourceEditedAt,
                       number.operation.editedAt == answer.operation.editedAt {
                        newer = n > a
                    } else { newer = number.operation.version > answer.operation.version }
                    if newer { status = .unknown }
                }
                state.cats[index].microchipAnswer = .init(value: .init(status: status, numberEdit: state.cats[index].microchip),
                    editedAt: answer.operation.editedAt, editedBy: "family:" + answer.operation.author.personID)
            }
            if let answer = snapshot.fieldState(for: FamilyNotebookVaccinationAnswer.target(cat: cat)), !answer.isDeleted {
                var value: CatCareAbsenceAnswer
                switch answer.operation.value {
                case .text(CatCareVaccinationStatus.noneText): value = .none
                case .clear: value = .unknown
                default: throw FamilyNotebookError.invalidValue
                }
                // A deleted entry may never have been projected on this phone.
                // Inspect its operations too, so a fresh phone cannot revive a
                // negative answer after an older app added/deleted a vaccine.
                let invalidatingEdit = snapshot.operations.filter { operation in
                    guard operation.target.familyCatID == cat, operation.target.collection == .vaccination,
                          operation.target.recordID != FamilyNotebookVaccinationAnswer.recordID(cat: cat),
                          operation.target.recordID != FamilyNotebookMicrochipAnswer.recordID(cat: cat) else { return false }
                    if let source = operation.importedSourceEditedAt, let answerSource = answer.operation.importedSourceEditedAt,
                       operation.editedAt == answer.operation.editedAt {
                        return source > answerSource
                    }
                    return operation.version > answer.operation.version
                }.max { $0.version < $1.version }
                if value == .none && invalidatingEdit != nil { value = .unknown }
                state.cats[index].vaccinationAnswer = .init(value: .init(status: value,
                    observedVaccinationIDs: state.cats[index].vaccinations.map(\.id).sorted { $0.uuidString < $1.uuidString }),
                    editedAt: max(answer.operation.editedAt, invalidatingEdit?.editedAt ?? answer.operation.editedAt),
                    editedBy: "family:" + (invalidatingEdit?.author.personID ?? answer.operation.author.personID))
            }
        }
        return state
    }
    private static func text(_ value: FamilyNotebookValue) throws -> String {
        switch value { case .text(let text): return text; case .clear: return ""; default: throw FamilyNotebookError.invalidValue }
    }
    private static func day(_ value: FamilyNotebookValue) throws -> CatCareDay? {
        if case .clear = value { return nil }
        guard case .day(let text) = value, let date = CatCareDay(isoDay: text) else { throw FamilyNotebookError.invalidValue }
        return date
    }
    private static func put(_ value: FamilyNotebookValue, _ field: FamilyNotebookField, into record: inout CatCareRecord,
                            operation: FamilyNotebookOperation) throws {
        func stamp<T: Codable & Equatable & Sendable>(_ value: T) -> CatCareStamped<T> {
            .init(value: value, editedAt: operation.editedAt, editedBy: "family:" + operation.author.personID)
        }
        switch field {
        case .name: record.name = try stamp(text(value))
        case .coat: record.coat = try stamp(text(value))
        case .marks: record.marks = try stamp(text(value))
        case .microchip: record.microchip = try stamp(text(value))
        case .conditions: record.conditions = try stamp(text(value))
        case .specialDiet: record.specialDiet = try stamp(text(value))
        case .water: record.water = try stamp(text(value))
        case .litter: record.litter = try stamp(text(value))
        case .temperament: record.temperament = try stamp(text(value))
        case .birthday: record.birthday = try stamp(day(value))
        case .adoptionDay:
            let date = try FamilyNotebookAdoptionDate.decode(value)
            let converted: CatCareAdoptionDay?
            if let date {
                guard let day = CatCareDay(isoDay: date.day) else { throw FamilyNotebookError.invalidValue }
                converted = .init(day: day, isApproximate: date.isApproximate)
            } else { converted = nil }
            record.adoptionDay = stamp(converted)
        case .sex:
            let name = try text(value)
            guard let result = CatCareSex(rawValue: name.isEmpty ? "unknown" : name) else { throw FamilyNotebookError.invalidValue }
            record.sex = stamp(result)
        case .neutered, .indoorOnly:
            let name = try text(value)
            guard let result = CatCareTriState(rawValue: name.isEmpty ? "unknown" : name) else { throw FamilyNotebookError.invalidValue }
            if field == .neutered { record.neutered = stamp(result) } else { record.indoorOnly = stamp(result) }
        case .allergyStatus, .allergyText:
            var result = record.allergy?.value ?? .init()
            let name = try text(value)
            if field == .allergyText { result.text = name }
            else {
                guard let status = CatCareAllergy.Status(rawValue: name.isEmpty ? "unknown" : name) else { throw FamilyNotebookError.invalidValue }
                result.status = status
            }
            record.allergy = stamp(result)
        case .vetName, .vetPhone, .vetNote:
            var vet = record.vetOverride?.value ?? CatCareVet()
            if field == .vetName { vet.name = try text(value) }
            if field == .vetPhone { vet.phone = try text(value) }
            if field == .vetNote { vet.note = try text(value) }
            record.vetOverride = stamp(Optional(vet))
        default: break
        }
    }
    private struct Values {
        let snapshot: FamilyNotebookSnapshot, cat: UUID, collection: FamilyNotebookCollection, record: UUID
        func state(_ field: FamilyNotebookField?) -> FamilyNotebookFieldState? {
            snapshot.fieldState(for: .init(familyCatID: cat, collection: collection, recordID: record, field: field))
        }
        var deleted: FamilyNotebookOperation? { state(nil).flatMap { $0.isDeleted ? $0.operation : nil } }
        var latest: FamilyNotebookOperation? {
            let fields = Set(snapshot.operations.filter { $0.target.familyCatID == cat && $0.target.collection == collection && $0.target.recordID == record }.compactMap { $0.target.field })
            return fields.compactMap { state($0)?.operation }.max { $0.version < $1.version }
        }
        func text(_ field: FamilyNotebookField) throws -> String? { try state(field)?.operation.value.map(FamilyNotebookCatCareBridge.text) }
        func date(_ field: FamilyNotebookField) throws -> CatCareDay? { try state(field)?.operation.value.flatMap(FamilyNotebookCatCareBridge.day) }
        func number(_ field: FamilyNotebookField) throws -> Int? {
            guard let value = state(field)?.operation.value else { return nil }
            guard case .integer(let number) = value else { throw FamilyNotebookError.invalidValue }; return number
        }
    }
    private static func apply(_ values: Values, localID: UUID, into record: inout CatCareRecord) throws {
        if let removed = values.deleted {
            switch values.collection {
            case .weight: record.weights.markDeleted(localID, at: removed.editedAt, by: "family:" + removed.author.personID)
            case .medication: record.medications.markDeleted(localID, at: removed.editedAt, by: "family:" + removed.author.personID)
            case .vaccination: record.vaccinations.markDeleted(localID, at: removed.editedAt, by: "family:" + removed.author.personID)
            case .meal: record.meals.markDeleted(localID, at: removed.editedAt, by: "family:" + removed.author.personID)
            default: break
            }
            return
        }
        guard let latest = values.latest else { return }
        let at = latest.editedAt, by = "family:" + latest.author.personID
        switch values.collection {
        case .weight:
            guard let date = try values.date(.measuredOn), let grams = try values.number(.grams) else { return }
            var item = record.weights.first { $0.id == localID } ?? .init(id: localID, measuredOn: date, grams: grams, editedAt: at, editedBy: by)
            guard item.deletedAt == nil else { return }
            item.measuredOn = date; item.grams = grams; item.editedAt = at; item.editedBy = by
            replace(item, in: &record.weights)
        case .medication:
            guard let name = try values.text(.medicationName) else { return }
            var item = record.medications.first { $0.id == localID } ?? .init(id: localID, name: name, editedAt: at, editedBy: by)
            guard item.deletedAt == nil else { return }
            item.name = name; item.dose = try values.text(.dose) ?? item.dose; item.schedule = try values.text(.schedule) ?? item.schedule
            item.note = try values.text(.note) ?? item.note
            if values.state(.startedOn) != nil { item.startedOn = try values.date(.startedOn) }
            if values.state(.endedOn) != nil { item.endedOn = try values.date(.endedOn) }
            item.editedAt = at; item.editedBy = by; replace(item, in: &record.medications)
        case .vaccination:
            guard let kind = try values.text(.kind), let date = try values.date(.givenOn) else { return }
            var item = record.vaccinations.first { $0.id == localID } ?? .init(id: localID, kind: kind, givenOn: date, editedAt: at, editedBy: by)
            guard item.deletedAt == nil else { return }
            item.kind = kind; item.givenOn = date
            item.familyPhotoLink = FamilyNotebookAttachmentLink.key(values.snapshot, cat: values.cat,
                kind: "vaccination", record: values.record)
            if values.state(.nextDueOn) != nil { item.nextDueOn = try values.date(.nextDueOn) }
            item.editedAt = at; item.editedBy = by; replace(item, in: &record.vaccinations)
        case .meal:
            guard let order = try values.number(.order) else { return }
            var item = record.meals.first { $0.id == localID } ?? .init(id: localID, order: order, editedAt: at, editedBy: by)
            guard item.deletedAt == nil else { return }
            item.time = try values.text(.time) ?? item.time; item.food = try values.text(.food) ?? item.food; item.amount = try values.text(.amount) ?? item.amount
            item.order = order; item.editedAt = at; item.editedBy = by; replace(item, in: &record.meals)
        default: break
        }
    }
    private static func replace<T: CatCareListEntry>(_ item: T, in items: inout [T]) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.append(item) }
    }
}
