import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// An opt-in, isolated local prototype. There is no singleton, network client,
// account lookup, Plus validation, encryption claim or automatic migration.
final class FamilyNotebookStore: @unchecked Sendable {
    typealias Writer = @Sendable (Data, URL) throws -> Void
    // Serialize reload + edit + commit across every instance in this process,
    // including different spellings of the same directory. No in-memory cache
    // can overwrite a newer committed state. Cross-process sync is future work.
    private static let transactionLock = NSLock()
    private let directory: URL
    private let stateURL: URL
    private let familyID: UUID
    private let deviceID: String
    private let write: Writer
    var localDirectory: URL { directory }
    var localDeviceID: String { deviceID }

    private struct State: Codable, Equatable {
        var schemaVersion = 1
        var familyID: UUID
        var revision: UInt64 = 0
        var clock: UInt64 = 0
        var operations: [FamilyNotebookOperation] = []
        var outboxIDs: Set<UUID> = []
        var acknowledgements: [FamilyNotebookAcknowledgement] = []
        var mappings: [FamilyNotebookLocalMapping] = []
        var ledgerKeys: Set<String> = []
        // Absent in the original schema. Ending participation uses schema 2
        // so an older app refuses to reopen it as an active sharing outbox.
        var sharingEnded: Bool?
        var farewellDecisions: [FamilyNotebookFarewellDecision]?

        var snapshot: FamilyNotebookSnapshot {
            .init(familyID: familyID, revision: revision, clock: clock, operations: operations,
                  mappings: mappings, ledgerKeys: ledgerKeys, outbox: operations.filter { outboxIDs.contains($0.id) },
                  acknowledgements: acknowledgements, sharingEnded: sharingEnded == true,
                  farewellDecisions: farewellDecisions ?? [])
        }
    }

    init(directory: URL, familyID: UUID, deviceID: String,
         write: @escaping Writer = { data, url in try FamilyNotebookStore.secureWrite(data, to: url) }) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), FamilyNotebookCore.validIdentifier(deviceID)
        else { throw FamilyNotebookError.unsafePath }
        // Resolve an existing ancestor before restoring the missing suffix.
        // Resolving a not-yet-created full path is not a reliable way to turn
        // Apple's /var alias into /private/var.
        self.directory = try Self.canonicalDirectory(directory)
        self.stateURL = self.directory.appendingPathComponent("family-notebook.json")
        self.familyID = familyID; self.deviceID = deviceID; self.write = write
        // Validate any existing original before permitting an edit. Never
        // quarantine, reset, replace or delete an unreadable/unknown version.
        _ = try snapshot()
    }

    func snapshot() throws -> FamilyNotebookSnapshot {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        return try load().snapshot
    }

    func pendingOperations() throws -> [FamilyNotebookOperation] {
        let current = try snapshot()
        return current.sharingEnded ? [] : current.outbox
    }

    /// Preserve the complete notebook, including its unsent operations. No
    /// transport or membership claim is made by this local prototype boundary.
    @discardableResult
    func endSharing() throws -> FamilyNotebookSnapshot {
        try transaction { state in
            state.schemaVersion = 2
            state.sharingEnded = true
        }
        return try snapshot()
    }

    @discardableResult
    func edit(target: FamilyNotebookTarget, value: FamilyNotebookValue?, author: FamilyNotebookAuthor,
              editedAt: Date = Date(), enqueue: Bool = true, expectedRevision: UInt64? = nil) throws -> FamilyNotebookOperation {
        guard target.field != .farewellDay else { throw FamilyNotebookError.consentRequired }
        return try transaction(expectedRevision: expectedRevision) { state in
            let operation = try makeOperation(state: state, target: target, value: value, author: author, editedAt: editedAt)
            state.operations = try FamilyNotebookCore.merge(state.operations, [operation])
            state.clock = operation.version.clock
            if enqueue && state.sharingEnded != true { state.outboxIDs.insert(operation.id) }
            return operation
        }
    }

    // Simulation seam only: the future authenticated/decrypted receiver must
    /// One local save becomes one durable notebook transaction before a tool
    /// projects it. A failed tool-file write can be recovered from this copy.
    func applyLocalChanges(_ plan: FamilyNotebookImportPlan, author: FamilyNotebookAuthor) throws {
        guard !plan.entries.contains(where: { $0.target.field == .farewellDay }) else { throw FamilyNotebookError.consentRequired }
        try transaction { state in
            guard plan.familyID == familyID else { throw FamilyNotebookError.familyMismatch }
            guard state.sharingEnded != true else { throw FamilyNotebookError.sharingEnded }
            for mapping in plan.mappings {
                if let old = state.mappings.first(where: { $0.sourceKey == mapping.sourceKey }) {
                    guard old == mapping else { throw FamilyNotebookError.mappingConflict }
                } else { state.mappings.append(mapping) }
            }
            for entry in plan.entries {
                try FamilyNotebookCore.validate(target: entry.target, value: entry.value)
                if state.operations.contains(where: { $0.target.removes(entry.target) }) { continue }
                let current = state.snapshot.fieldState(for: entry.target)
                if current?.operation.value == entry.value && current != nil { continue }
                let operation = try makeOperation(state: state, target: entry.target, value: entry.value,
                    author: author, editedAt: entry.editedAt)
                state.operations = try FamilyNotebookCore.merge(state.operations, [operation])
                state.clock = operation.version.clock; state.outboxIDs.insert(operation.id)
            }
        }
    }

    // The authenticated/decrypted receiver establishes provenance before merge.
    // establish membership and provenance before calling a merge layer.
    @discardableResult
    func receive(_ operations: [FamilyNotebookOperation], expectedRevision: UInt64? = nil) throws -> FamilyNotebookSnapshot {
        try transaction(expectedRevision: expectedRevision) { state in
            guard state.sharingEnded != true else { throw FamilyNotebookError.sharingEnded }
            guard operations.allSatisfy({ $0.familyID == familyID }) else { throw FamilyNotebookError.familyMismatch }
            state.operations = try FamilyNotebookCore.merge(state.operations, operations)
            state.clock = max(state.clock, operations.map(\.version.clock).max() ?? 0)
        }
        return try snapshot()
    }

    // This models a matching receipt; it does not assert that a server exists
    // or that a Plus/member/cryptographic check has been implemented.
    @discardableResult
    func acknowledge(_ acknowledgement: FamilyNotebookAcknowledgement) throws -> FamilyNotebookSnapshot {
        try transaction { state in
            guard acknowledgement.familyID == familyID else { throw FamilyNotebookError.familyMismatch }
            guard let operation = state.operations.first(where: { $0.id == acknowledgement.operationID }),
                  operation.version == acknowledgement.version else { throw FamilyNotebookError.invalidAcknowledgement }
            if !state.acknowledgements.contains(acknowledgement) { state.acknowledgements.append(acknowledgement) }
            state.outboxIDs.remove(operation.id)
        }
        return try snapshot()
    }

    @discardableResult
    func enqueue(operationID: UUID) throws -> FamilyNotebookSnapshot {
        try transaction { state in
            guard state.sharingEnded != true else { throw FamilyNotebookError.sharingEnded }
            guard let operation = state.operations.first(where: { $0.id == operationID }) else { throw FamilyNotebookError.invalidOperation }
            guard Self.farewellSendAllowed(operation, state) else { throw FamilyNotebookError.consentRequired }
            if !state.acknowledgements.contains(where: { $0.operationID == operation.id && $0.version == operation.version }) {
                state.outboxIDs.insert(operationID)
            }
        }
        return try snapshot()
    }

    @discardableResult
    func applyImport(_ plan: FamilyNotebookImportPlan, author: FamilyNotebookAuthor, now: Date = Date()) throws -> FamilyNotebookSnapshot {
        guard !plan.entries.contains(where: { $0.target.field == .farewellDay }) else { throw FamilyNotebookError.consentRequired }
        try transaction { state in
            guard plan.familyID == familyID else { throw FamilyNotebookError.familyMismatch }
            guard now.timeIntervalSince1970.isFinite,
                  Set(plan.entries.map(\.ledgerKey)).count == plan.entries.count else { throw FamilyNotebookError.invalidValue }
            for mapping in plan.mappings {
                guard FamilyNotebookCore.validIdentifier(mapping.sourceKey) else { throw FamilyNotebookError.invalidValue }
                if let old = state.mappings.first(where: { $0.sourceKey == mapping.sourceKey }) {
                    guard old == mapping else { throw FamilyNotebookError.mappingConflict }
                } else { state.mappings.append(mapping) }
            }
            // Tombstones first ensure source deletion suppresses all source
            // fields independent of input order. Never replace existing data.
            let entries = plan.entries.sorted { ($0.target.field == nil ? 0 : 1, $0.ledgerKey) < ($1.target.field == nil ? 0 : 1, $1.ledgerKey) }
            for entry in entries {
                guard FamilyNotebookCore.validIdentifier(entry.ledgerKey) else { throw FamilyNotebookError.invalidValue }
                try FamilyNotebookCore.validate(target: entry.target, value: entry.value)
                guard entry.editedAt.timeIntervalSince1970.isFinite else { throw FamilyNotebookError.invalidValue }
                if state.ledgerKeys.contains(entry.ledgerKey) { continue }
                let alreadyPresent = state.operations.contains { operation in
                    operation.target == entry.target || operation.target.removes(entry.target)
                        || (entry.target.field == nil && entry.target.removes(operation.target))
                }
                if !alreadyPresent {
                    let operation = try makeOperation(state: state, target: entry.target, value: entry.value,
                                                      author: author, editedAt: now, importedSourceEditedAt: entry.editedAt)
                    state.operations.append(operation)
                    state.clock = operation.version.clock
                    if state.sharingEnded != true { state.outboxIDs.insert(operation.id) }
                }
                state.ledgerKeys.insert(entry.ledgerKey)
            }
        }
        return try snapshot()
    }

    func farewellDecision(actionID: UUID) throws -> FamilyNotebookFarewellDecision? {
        try snapshot().farewellDecisions.first { $0.actionID == actionID }
    }

    @discardableResult
    func consentFarewell(cat: UUID, day: String, author: FamilyNotebookAuthor, previewID: UUID,
                         expectedSharedOperationID: UUID?, actionID: UUID, now: Date = Date()) throws -> FamilyNotebookFarewellDecision {
        try transaction { state in
            if let prior = state.farewellDecisions?.first(where: { $0.actionID == actionID }) {
                guard prior.personID == author.personID, prior.familyCatID == cat, prior.day == day,
                      prior.previewID == previewID else { throw FamilyNotebookError.consentOperationConflict }
                return prior
            }
            guard state.sharingEnded != true else { throw FamilyNotebookError.sharingEnded }
            guard state.mappings.contains(where: { $0.recordID == nil && $0.familyCatID == cat }) else { throw FamilyNotebookError.mappingConflict }
            let target = FamilyNotebookTarget(familyCatID: cat, field: .farewellDay)
            guard state.snapshot.fieldState(for: target)?.operation.id == expectedSharedOperationID else { throw FamilyNotebookError.staleConsent }
            let operation = try makeOperation(state: state, target: target, value: .day(day), author: author, editedAt: now)
            // Superseded, unacknowledged values remain in the local history but
            // are never sent just because a new day was confirmed.
            Self.cancelFarewellOutbox(cat: cat, person: author.personID, state: &state)
            state.operations = try FamilyNotebookCore.merge(state.operations, [operation])
            state.clock = operation.version.clock; state.outboxIDs.insert(operation.id)
            let decision = FamilyNotebookFarewellDecision(actionID: actionID, previewID: previewID, personID: author.personID,
                familyCatID: cat, day: day, sharedOperationID: operation.id, decidedAt: now)
            state.farewellDecisions = (state.farewellDecisions ?? []) + [decision]
            return decision
        }
    }

    @discardableResult
    func revokeFarewell(cat: UUID, author: FamilyNotebookAuthor, actionID: UUID, now: Date = Date()) throws -> FamilyNotebookFarewellDecision {
        try transaction { state in
            if let prior = state.farewellDecisions?.first(where: { $0.actionID == actionID }) {
                guard prior.personID == author.personID, prior.familyCatID == cat, prior.day == nil,
                      prior.previewID == nil else { throw FamilyNotebookError.consentOperationConflict }
                return prior
            }
            guard state.sharingEnded != true else { throw FamilyNotebookError.sharingEnded }
            guard state.mappings.contains(where: { $0.recordID == nil && $0.familyCatID == cat }) else { throw FamilyNotebookError.mappingConflict }
            let target = FamilyNotebookTarget(familyCatID: cat, field: .farewellDay)
            let current = state.snapshot.fieldState(for: target)
            let prior = state.farewellDecisions?.last { $0.familyCatID == cat && $0.personID == author.personID }
            let previousClear = prior?.day == nil ? prior?.sharedOperationID : nil
            let keepClearPending = previousClear.map { state.outboxIDs.contains($0) } ?? false
            Self.cancelFarewellOutbox(cat: cat, person: author.personID, state: &state)
            if let previousClear, keepClearPending { state.outboxIDs.insert(previousClear) }
            var clearedID = previousClear
            // Another person's newer date is not this person's consent to revoke.
            if let prior, prior.day != nil, current?.operation.id == prior.sharedOperationID, current?.isDeleted == false {
                let clear = try makeOperation(state: state, target: target, value: .clear, author: author, editedAt: now)
                state.operations = try FamilyNotebookCore.merge(state.operations, [clear]); state.clock = clear.version.clock
                state.outboxIDs.insert(clear.id); clearedID = clear.id
            }
            let decision = FamilyNotebookFarewellDecision(actionID: actionID, previewID: nil, personID: author.personID,
                familyCatID: cat, day: nil, sharedOperationID: clearedID, decidedAt: now)
            state.farewellDecisions = (state.farewellDecisions ?? []) + [decision]
            return decision
        }
    }

    private static func cancelFarewellOutbox(cat: UUID, person: String, state: inout State) {
        let ids = state.operations.filter { $0.target.familyCatID == cat && $0.target.field == .farewellDay && $0.author.personID == person }.map(\.id)
        state.outboxIDs.subtract(ids)
    }
    private static func farewellSendAllowed(_ operation: FamilyNotebookOperation, _ state: State) -> Bool {
        guard operation.target.field == .farewellDay else { return true }
        return state.farewellDecisions?.last(where: {
            $0.familyCatID == operation.target.familyCatID && $0.personID == operation.author.personID
        })?.sharedOperationID == operation.id
    }

    private func makeOperation(state: State, target: FamilyNotebookTarget, value: FamilyNotebookValue?,
                               author: FamilyNotebookAuthor, editedAt: Date, importedSourceEditedAt: Date? = nil) throws -> FamilyNotebookOperation {
        guard !state.operations.contains(where: { $0.target.removes(target) }) else { throw FamilyNotebookError.deletedTarget }
        guard state.clock < UInt64.max else { throw FamilyNotebookError.clockOverflow }
        let result = FamilyNotebookOperation(familyID: familyID, target: target, value: value,
            version: .init(clock: state.clock + 1, deviceID: deviceID, operationID: UUID()),
            author: author, editedAt: editedAt,
            observedOperationIDs: FamilyNotebookCore.observedFrontier(target: target, operations: state.operations),
            importedSourceEditedAt: importedSourceEditedAt)
        try FamilyNotebookCore.validate(result)
        return result
    }

    private func transaction<T>(expectedRevision: UInt64? = nil, _ body: (inout State) throws -> T) throws -> T {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        let original = try load()
        if let expectedRevision, original.revision != expectedRevision { throw FamilyNotebookError.staleRevision }
        var next = original
        let result = try body(&next)
        if next != original {
            guard original.revision < UInt64.max else { throw FamilyNotebookError.clockOverflow }
            next.revision = original.revision + 1
            try validate(next)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(next)
            // A writer must either throw before commit (preserve the old file),
            // or commit atomically and return. Production uses that contract.
            try write(bytes, stateURL)
        }
        return result
    }

    private func load() throws -> State {
        try checkPath()
        let bytes: Data
        do { bytes = try Data(contentsOf: stateURL) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return State(familyID: familyID)
            }
            throw FamilyNotebookError.storageUnavailable
        }
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: bytes) else { throw FamilyNotebookError.corruptStorage }
        guard [1, 2].contains(header.schemaVersion) else { throw FamilyNotebookError.unsupportedSchema }
        let state: State
        do { state = try decoder.decode(State.self, from: bytes) }
        catch { throw FamilyNotebookError.corruptStorage }
        try validate(state)
        return state
    }

    private func validate(_ state: State) throws {
        guard [1, 2].contains(state.schemaVersion) else { throw FamilyNotebookError.unsupportedSchema }
        guard (state.schemaVersion == 1 && state.sharingEnded == nil)
                || (state.schemaVersion == 2 && state.sharingEnded == true)
        else { throw FamilyNotebookError.corruptStorage }
        guard state.familyID == familyID, state.operations.allSatisfy({ $0.familyID == familyID })
        else { throw FamilyNotebookError.familyMismatch }
        let operations = try FamilyNotebookCore.merge([], state.operations)
        guard operations.count == state.operations.count, state.clock >= (operations.map(\.version.clock).max() ?? 0),
              Set(state.mappings.map(\.sourceKey)).count == state.mappings.count,
              state.mappings.allSatisfy({ FamilyNotebookCore.validIdentifier($0.sourceKey) }),
              state.ledgerKeys.allSatisfy(FamilyNotebookCore.validIdentifier),
              Set(state.acknowledgements.map(\.operationID)).count == state.acknowledgements.count,
              state.outboxIDs.isSubset(of: Set(operations.map(\.id))) else { throw FamilyNotebookError.corruptStorage }
        for acknowledgement in state.acknowledgements {
            guard acknowledgement.familyID == familyID,
                  operations.contains(where: { $0.id == acknowledgement.operationID && $0.version == acknowledgement.version }),
                  !state.outboxIDs.contains(acknowledgement.operationID) else { throw FamilyNotebookError.corruptStorage }
        }
        for mapping in state.mappings {
            guard mapping.familyCatID != familyID,
                  mapping.familyCatID != mapping.profileID, mapping.familyCatID != mapping.toolCatID,
                  mapping.recordID == nil || (mapping.recordID != mapping.familyCatID && mapping.recordID != familyID),
                  mapping.recordID == nil || (mapping.profileID == nil && mapping.toolCatID == nil)
            else { throw FamilyNotebookError.mappingConflict }
            for other in state.mappings where other.sourceKey != mapping.sourceKey {
                let sameProfile = mapping.profileID != nil && mapping.profileID == other.profileID
                let sameTool = mapping.toolCatID != nil && mapping.toolCatID == other.toolCatID
                let sameRecord = mapping.recordID != nil && mapping.recordID == other.recordID
                guard !(sameProfile || sameTool || sameRecord) || mapping.familyCatID == other.familyCatID
                else { throw FamilyNotebookError.mappingConflict }
            }
        }
        let decisions = state.farewellDecisions ?? []
        guard Set(decisions.map(\.actionID)).count == decisions.count else { throw FamilyNotebookError.corruptStorage }
        for decision in decisions {
            guard FamilyNotebookCore.validIdentifier(decision.personID), decision.decidedAt.timeIntervalSince1970.isFinite,
                  state.mappings.contains(where: { $0.familyCatID == decision.familyCatID && $0.recordID == nil }),
                  (decision.day == nil) == (decision.previewID == nil) else { throw FamilyNotebookError.corruptStorage }
            if let id = decision.sharedOperationID {
                guard let operation = state.operations.first(where: { $0.id == id }),
                      operation.author.personID == decision.personID,
                      operation.target == FamilyNotebookTarget(familyCatID: decision.familyCatID, field: .farewellDay),
                      operation.value == (decision.day.map(FamilyNotebookValue.day) ?? .clear) else { throw FamilyNotebookError.corruptStorage }
            } else if decision.day != nil { throw FamilyNotebookError.corruptStorage }
        }
        guard state.operations.filter({ state.outboxIDs.contains($0.id) }).allSatisfy({ Self.farewellSendAllowed($0, state) }) else {
            throw FamilyNotebookError.consentRequired
        }
    }

    private func checkPath() throws {
        var current = stateURL
        var isStateFile = true
        while current.path != "/" && !current.path.isEmpty {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw FamilyNotebookError.unsafePath }
                if isStateFile {
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { throw FamilyNotebookError.unsafePath }
                } else {
                    guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw FamilyNotebookError.unsafePath }
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
                // Only missing components are allowed; all existing ancestors
                // are still inspected before treating state as uninitialized.
            }
            isStateFile = false
            current = current.deletingLastPathComponent()
        }
    }

    private static func canonicalDirectory(_ requested: URL) throws -> URL {
        var existing = requested.standardizedFileURL
        var missing: [String] = []
        while true {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: existing.path)
                let type = attributes[.type] as? FileAttributeType
                // System ancestor aliases are resolved below. A supplied
                // directory that itself is a link remains outside the contract.
                guard type == .typeDirectory || (type == .typeSymbolicLink && !missing.isEmpty)
                else { throw FamilyNotebookError.unsafePath }
                // Foundation URL normalization can strip /private again on
                // Apple platforms. Keep the physical path returned by realpath
                // so the subsequent ancestor checks do not encounter /var.
#if canImport(Darwin) || canImport(Glibc)
                guard let physical = realpath(existing.path, nil) else { throw FamilyNotebookError.storageUnavailable }
                defer { free(physical) }
                var canonical = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
#else
                throw FamilyNotebookError.storageUnavailable
#endif
                let resolved = try FileManager.default.attributesOfItem(atPath: canonical.path)
                guard resolved[.type] as? FileAttributeType == .typeDirectory else { throw FamilyNotebookError.unsafePath }
                for component in missing.reversed() {
                    canonical.appendPathComponent(component, isDirectory: true)
                }
                return canonical
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
                // Only ENOENT-style errors mean an uncreated component.
                // Access failures and every other error propagate unchanged.
                guard existing.path != "/", !existing.lastPathComponent.isEmpty else { throw error }
                missing.append(existing.lastPathComponent)
                existing.deleteLastPathComponent()
            }
        }
    }

    static func secureWrite(_ data: Data, to url: URL) throws {
#if canImport(Darwin)
        try SharingSecureFile.write(data, to: url)
#else
        // The app is iOS-only. Non-Apple fixtures must provide an explicit
        // writer rather than silently claiming unavailable file protection.
        throw FamilyNotebookError.storageUnavailable
#endif
    }
}
