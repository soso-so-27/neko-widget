import Foundation

// Stage 1 is a local model, not a transport, authenticated roster or E2EE implementation.
// Only the explicit Operation DTO is eligible for a future sharing boundary. Local
// mappings and migration receipts deliberately live outside that DTO.
enum FamilyNotebookError: Error, Equatable {
    case invalidValue, invalidTarget, invalidOperation, operationCollision
    case familyMismatch, mappingConflict, staleRevision, clockOverflow
    case unsupportedSchema, corruptStorage, unsafePath, storageUnavailable, invalidAcknowledgement, deletedTarget, sharingEnded
}

/// Everyone may leave their own family. Leaving is independent from the
/// payer's authority to remove someone else or dissolve the family (#543).
enum FamilyRole: Equatable, Sendable {
    case payer, member
}

struct FamilyMembership: Equatable, Sendable {
    var role: FamilyRole
    var canInvite: Bool { true }
    var canRemoveMember: Bool { role == .payer }
    var canDissolve: Bool { role == .payer }
    var canLeave: Bool { true }
}

/// Read-only contract for the future authenticated family service. This is
/// neither a locally assignable role nor an authorization token. Mutations must
/// recheck membership, Plus and generation on the server. The local prototype
/// deliberately does not apply this DTO to FamilyMembership or its outbox.
struct FamilyNotebookPayerState: Decodable, Equatable, Sendable {
    enum SharingStatus: String, Decodable, Sendable { case active, paused }
    enum PauseReason: String, Decodable, Sendable { case noPayer = "no_payer", payerPlusUnverified = "payer_plus_unverified" }
    enum Role: String, Decodable, Sendable { case payer, member }
    let schemaVersion: Int
    let familyId: String
    let generation: Int64
    let sharingStatus: SharingStatus
    let pauseReason: PauseReason?
    let payerPersonId: String?
    let role: Role
    let nominationPending: Bool
    let canClaimPayer: Bool
    let canRemoveMember: Bool
    let canDissolve: Bool

    func validated(family expectedFamily: String, person currentPerson: String,
                   minimumGeneration: Int64 = 0) throws -> Self {
        func validID(_ value: String) -> Bool {
            (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }
        guard schemaVersion == 1, validID(familyId), validID(expectedFamily), validID(currentPerson),
              (1...1_000_000_001).contains(generation), minimumGeneration >= 0,
              payerPersonId.map(validID) ?? true else { throw FamilyNotebookError.invalidValue }
        guard familyId == expectedFamily else { throw FamilyNotebookError.familyMismatch }
        guard generation >= minimumGeneration else { throw FamilyNotebookError.staleRevision }
        let isPayer = payerPersonId == currentPerson
        guard (role == .payer) == isPayer, canRemoveMember == isPayer, canDissolve == isPayer else {
            throw FamilyNotebookError.invalidValue
        }
        switch (sharingStatus, pauseReason) {
        case (.active, nil):
            guard payerPersonId != nil, !canClaimPayer else { throw FamilyNotebookError.invalidValue }
        case (.paused, .noPayer):
            guard payerPersonId == nil, role == .member, !canClaimPayer || !nominationPending else {
                throw FamilyNotebookError.invalidValue
            }
        case (.paused, .payerPlusUnverified):
            guard payerPersonId != nil, !canClaimPayer else { throw FamilyNotebookError.invalidValue }
        default: throw FamilyNotebookError.invalidValue
        }
        return self
    }
}

enum FamilyNotebookCollection: String, Codable, CaseIterable, Hashable, Sendable {
    case cat, weight, medication, vaccination, meal, visit, visitEntry, handoff, handoffMeal
}

enum FamilyNotebookField: String, Codable, CaseIterable, Hashable, Sendable {
    case name, sex, neutered, birthday, coat, marks, microchip, indoorOnly
    case conditions, allergyStatus, allergyText, specialDiet, water, litter, temperament
    case vetName, vetPhone, vetNote, measuredOn, grams, medicationName, dose, schedule
    case startedOn, endedOn, note, kind, givenOn, nextDueOn, time, food, amount, order
    case catName, observations, questions, completedAt, text, capturedAt, writtenAt
    case recipient, period, request, usualFood, meals, toilet, handling, important
    case callWhen, healthStatus, healthDetails
}

enum FamilyNotebookValue: Codable, Equatable, Sendable {
    case text(String), integer(Int), decimal(Double), date(Date), day(String), clear
}

struct FamilyNotebookTarget: Codable, Hashable, Sendable {
    let familyCatID: UUID
    let collection: FamilyNotebookCollection
    let recordID: UUID?
    let parentRecordID: UUID?
    // A nil field deletes the entire cat or stable record ID. Clear is a value,
    // not a tombstone: users can fill that field again with an explicit new edit.
    let field: FamilyNotebookField?

    init(familyCatID: UUID, collection: FamilyNotebookCollection = .cat,
         recordID: UUID? = nil, parentRecordID: UUID? = nil, field: FamilyNotebookField?) {
        self.familyCatID = familyCatID; self.collection = collection
        self.recordID = recordID; self.parentRecordID = parentRecordID; self.field = field
    }

    func removes(_ other: Self) -> Bool {
        guard field == nil, familyCatID == other.familyCatID else { return false }
        if collection == .cat { return true }
        if collection == .visit, other.collection == .visitEntry, recordID == other.parentRecordID { return true }
        if collection == .handoff, other.collection == .handoffMeal, recordID == other.parentRecordID { return true }
        return collection == other.collection && recordID == other.recordID && parentRecordID == other.parentRecordID
    }
}

struct FamilyNotebookAuthor: Codable, Equatable, Sendable {
    let personID: String
    let displayName: String
}

struct FamilyNotebookVersion: Codable, Equatable, Comparable, Sendable {
    let clock: UInt64
    let deviceID: String
    let operationID: UUID

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.clock != rhs.clock { return lhs.clock < rhs.clock }
        if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID }
        return lhs.operationID.uuidString < rhs.operationID.uuidString
    }
}

struct FamilyNotebookOperation: Codable, Equatable, Identifiable, Sendable {
    let familyID: UUID
    let target: FamilyNotebookTarget
    let value: FamilyNotebookValue?
    let version: FamilyNotebookVersion
    let author: FamilyNotebookAuthor
    // Display provenance only. Wall-clock time never selects the winner.
    let editedAt: Date
    let observedOperationIDs: [UUID]
    // Import provenance is separate from the importing person's edit time.
    let importedSourceEditedAt: Date?
    var id: UUID { version.operationID }

    init(familyID: UUID, target: FamilyNotebookTarget, value: FamilyNotebookValue?,
         version: FamilyNotebookVersion, author: FamilyNotebookAuthor, editedAt: Date,
         observedOperationIDs: [UUID] = [], importedSourceEditedAt: Date? = nil) {
        self.familyID = familyID; self.target = target; self.value = value
        self.version = version; self.author = author; self.editedAt = editedAt
        self.observedOperationIDs = observedOperationIDs
        self.importedSourceEditedAt = importedSourceEditedAt
    }
}

struct FamilyNotebookAcknowledgement: Codable, Equatable, Sendable {
    let familyID: UUID
    let operationID: UUID
    let version: FamilyNotebookVersion
}

enum FamilyNotebookStatus: String, Codable, Equatable, Sendable {
    case localSaved, pendingShared, shared, conflict
}

struct FamilyNotebookHistoryEntry: Equatable, Sendable {
    let operation: FamilyNotebookOperation
    let isConcurrentConflict: Bool
}

struct FamilyNotebookFieldState: Equatable, Sendable {
    let operation: FamilyNotebookOperation
    let status: FamilyNotebookStatus
    let history: [FamilyNotebookHistoryEntry]
    var isDeleted: Bool { operation.target.field == nil }
}

// These IDs are local reconciliation aids. They are never part of Operation.
struct FamilyNotebookLocalMapping: Codable, Equatable, Sendable {
    let sourceKey: String
    let familyCatID: UUID
    let recordID: UUID?
    let profileID: UUID?
    let toolCatID: UUID?

    init(sourceKey: String, familyCatID: UUID, recordID: UUID? = nil,
         profileID: UUID? = nil, toolCatID: UUID? = nil) {
        self.sourceKey = sourceKey; self.familyCatID = familyCatID; self.recordID = recordID
        self.profileID = profileID; self.toolCatID = toolCatID
    }
}

struct FamilyNotebookImportEntry: Equatable, Sendable {
    let ledgerKey: String
    let target: FamilyNotebookTarget
    let value: FamilyNotebookValue?
    let editedAt: Date
}

struct FamilyNotebookImportPlan: Equatable, Sendable {
    let familyID: UUID
    let entries: [FamilyNotebookImportEntry]
    let mappings: [FamilyNotebookLocalMapping]
}

struct FamilyNotebookSnapshot: Equatable, Sendable {
    let familyID: UUID
    let revision: UInt64
    let clock: UInt64
    let operations: [FamilyNotebookOperation]
    let mappings: [FamilyNotebookLocalMapping]
    let ledgerKeys: Set<String>
    let outbox: [FamilyNotebookOperation]
    let acknowledgements: [FamilyNotebookAcknowledgement]
    /// Local transmission boundary, not proof of a server-confirmed exit.
    let sharingEnded: Bool

    func fieldState(for target: FamilyNotebookTarget) -> FamilyNotebookFieldState? {
        FamilyNotebookCore.resolve(target: target, operations: operations,
                                   outboxIDs: Set(outbox.map(\.id)), acknowledgements: acknowledgements)
    }
}

enum FamilyNotebookCore {
    // No prune API: 90 days is a minimum, not permission to discard deletion
    // evidence. A checkpoint/re-bootstrap protocol does not exist in stage 1.
    static let minimumRetentionDays = 90

    static func validate(target: FamilyNotebookTarget, value: FamilyNotebookValue?) throws {
        guard (target.collection == .cat) == (target.recordID == nil),
              ([FamilyNotebookCollection.visitEntry, .handoffMeal].contains(target.collection)) == (target.parentRecordID != nil),
              target.recordID == nil || target.recordID != target.familyCatID,
              target.parentRecordID == nil || (target.parentRecordID != target.recordID && target.parentRecordID != target.familyCatID)
        else { throw FamilyNotebookError.invalidTarget }
        guard let field = target.field else {
            guard value == nil else { throw FamilyNotebookError.invalidValue }; return
        }
        let allowed: Set<FamilyNotebookField>
        switch target.collection {
        case .cat: allowed = [.name, .sex, .neutered, .birthday, .coat, .marks, .microchip, .indoorOnly,
                              .conditions, .allergyStatus, .allergyText, .specialDiet, .water, .litter,
                              .temperament, .vetName, .vetPhone, .vetNote]
        case .weight: allowed = [.measuredOn, .grams]
        case .medication: allowed = [.medicationName, .dose, .schedule, .startedOn, .endedOn, .note]
        case .vaccination: allowed = [.kind, .givenOn, .nextDueOn]
        case .meal, .handoffMeal: allowed = [.time, .food, .amount, .order]
        case .visit: allowed = [.catName, .startedOn, .observations, .questions, .completedAt]
        case .visitEntry: allowed = [.text, .capturedAt, .writtenAt, .grams, .measuredOn, .catName]
        case .handoff: allowed = [.recipient, .period, .request, .name, .catName, .usualFood, .water,
                                  .toilet, .handling, .important, .callWhen, .healthStatus, .healthDetails]
        }
        guard allowed.contains(field), let value else { throw FamilyNotebookError.invalidTarget }
        if value == .clear { return }
        let days: Set<FamilyNotebookField> = [.birthday, .measuredOn, .startedOn, .endedOn, .givenOn, .nextDueOn]
        let dates: Set<FamilyNotebookField> = [.completedAt, .capturedAt, .writtenAt]
        switch value {
        case .text(let text):
            guard !days.contains(field), !dates.contains(field), field != .grams, field != .order,
                  text.utf8.count <= 65_536, !text.contains("\u{0000}") else { throw FamilyNotebookError.invalidValue }
        case .integer(let number):
            guard (field == .grams && (0...1_000_000).contains(number)) || (field == .order && (0...100_000).contains(number))
            else { throw FamilyNotebookError.invalidValue }
        case .decimal:
            // Reserved in the value algebra; no stage-1 field authorizes a decimal yet.
            throw FamilyNotebookError.invalidValue
        case .date(let date):
            guard date.timeIntervalSince1970.isFinite,
                  dates.contains(field) || (target.collection == .visit && field == .startedOn)
            else { throw FamilyNotebookError.invalidValue }
        case .day(let day):
            guard days.contains(field), validDay(day) else { throw FamilyNotebookError.invalidValue }
        case .clear: break
        }
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func validate(_ operation: FamilyNotebookOperation) throws {
        try validate(target: operation.target, value: operation.value)
        guard operation.version.clock > 0, validIdentifier(operation.version.deviceID),
              operation.familyID != operation.target.familyCatID,
              operation.familyID != operation.target.recordID, operation.familyID != operation.target.parentRecordID,
              validIdentifier(operation.author.personID), validIdentifier(operation.author.displayName),
              operation.editedAt.timeIntervalSince1970.isFinite,
              operation.importedSourceEditedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              Set(operation.observedOperationIDs).count == operation.observedOperationIDs.count,
              !operation.observedOperationIDs.contains(operation.id)
        else { throw FamilyNotebookError.invalidOperation }
    }

    static func merge(_ existing: [FamilyNotebookOperation], _ incoming: [FamilyNotebookOperation]) throws -> [FamilyNotebookOperation] {
        var byID: [UUID: FamilyNotebookOperation] = [:]
        var family: UUID?
        var records: [UUID: FamilyNotebookTarget] = [:]
        for operation in existing + incoming {
            try validate(operation)
            if let family, family != operation.familyID { throw FamilyNotebookError.familyMismatch }
            family = operation.familyID
            if let prior = byID[operation.id], prior != operation { throw FamilyNotebookError.operationCollision }
            if let recordID = operation.target.recordID {
                if let old = records[recordID], old.familyCatID != operation.target.familyCatID
                    || old.collection != operation.target.collection || old.parentRecordID != operation.target.parentRecordID {
                    throw FamilyNotebookError.invalidTarget
                }
                records[recordID] = operation.target
            }
            byID[operation.id] = operation
        }
        for operation in byID.values {
            if let parentID = operation.target.parentRecordID, let parent = records[parentID] {
                let expected: FamilyNotebookCollection = operation.target.collection == .visitEntry ? .visit : .handoff
                guard parent.familyCatID == operation.target.familyCatID, parent.collection == expected
                else { throw FamilyNotebookError.invalidTarget }
            }
            for id in operation.observedOperationIDs {
                if let observed = byID[id] {
                    guard (observed.target == operation.target || operation.target.removes(observed.target)),
                          observed.version.clock < operation.version.clock
                    else { throw FamilyNotebookError.invalidOperation }
                }
            }
        }
        let catIDs = Set(byID.values.map(\.target.familyCatID))
        guard Set(records.keys).isDisjoint(with: catIDs) else { throw FamilyNotebookError.invalidTarget }
        return byID.values.sorted { $0.version < $1.version }
    }

    /// New edits name the causal frontier, not a growing copy of every old ID.
    /// History remains intact and resolve follows these references transitively.
    static func observedFrontier(target: FamilyNotebookTarget, operations: [FamilyNotebookOperation]) -> [UUID] {
        let candidates = operations.filter { $0.target == target || target.removes($0.target) }
        let observed = Set(candidates.flatMap(\.observedOperationIDs))
        return candidates.filter { !observed.contains($0.id) }.sorted { $0.version < $1.version }.map(\.id)
    }

    static func resolve(target: FamilyNotebookTarget, operations: [FamilyNotebookOperation],
                        outboxIDs: Set<UUID> = [], acknowledgements: [FamilyNotebookAcknowledgement] = []) -> FamilyNotebookFieldState? {
        let candidates = operations.filter { $0.target == target || $0.target.removes(target) }
        let tombstones = candidates.filter { $0.target.field == nil }
        guard let winner = (tombstones.isEmpty ? candidates : tombstones).max(by: { $0.version < $1.version }) else { return nil }
        let byID = Dictionary(operations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>(), remaining = winner.observedOperationIDs
        while let id = remaining.popLast() {
            if seen.insert(id).inserted, let observed = byID[id] { remaining += observed.observedOperationIDs }
        }
        let history = candidates.filter { $0.id != winner.id }.sorted { $0.version > $1.version }.map {
            FamilyNotebookHistoryEntry(operation: $0, isConcurrentConflict: !seen.contains($0.id) && $0.value != winner.value)
        }
        let status: FamilyNotebookStatus
        if history.contains(where: \.isConcurrentConflict) { status = .conflict }
        else if acknowledgements.contains(where: { $0.familyID == winner.familyID && $0.operationID == winner.id && $0.version == winner.version }) { status = .shared }
        else if outboxIDs.contains(winner.id) { status = .pendingShared }
        else { status = .localSaved }
        return .init(operation: winner, status: status, history: history)
    }

    private static func validDay(_ day: String) -> Bool {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              day.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }),
              let year = Int(parts[0]), let month = Int(parts[1]), let value = Int(parts[2]), (1900...2200).contains(year)
        else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: value)) else { return false }
        let result = calendar.dateComponents([.year, .month, .day], from: date)
        return result.year == year && result.month == month && result.day == value
    }
}
