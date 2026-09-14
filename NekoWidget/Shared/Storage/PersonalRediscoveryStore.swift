import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct PersonalRediscoveryCandidate: Codable, Equatable, Sendable {
    var item: WidgetManifestItem
    var creationDate: Date? = nil
    var burstIdentifier: String? = nil
    var isFavorite: Bool = false
    var isSaved: Bool = false
    var preparedAt: Date = .now
}

struct PersonalRediscoveryEntryToken: Codable, Equatable, Sendable {
    var id: String
    var createdAt: Date
    var eligibilityDay: String
    var sourceID: String
    var photoID: String
    var scopeRevision: String
}

enum PersonalRediscoveryAction: Equatable, Sendable {
    case available(token: PersonalRediscoveryEntryToken)
    case used(grantID: String)
    case unavailable
}

struct PersonalRediscoveryEntry: Equatable, Sendable {
    var date: Date
    var item: WidgetManifestItem?
    var slotID: String
    var scopeRevision: String
    var action: PersonalRediscoveryAction
}

struct PersonalRediscoveryTimeline: Equatable, Sendable {
    var entries: [PersonalRediscoveryEntry]
    var reloadDate: Date
}

struct PersonalRediscoveryGrant: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var photoID: String
    var previousPhotoID: String
    var committedAt: Date
    var resultExpiresAt: Date
    var overrideUntil: Date
    var scopeRevision: String
    var resultIsAvailable: Bool = true
    var previousIsAvailable: Bool
    fileprivate var resultItem: WidgetManifestItem
    fileprivate var previousItem: WidgetManifestItem
    fileprivate var resultInvalidated: Bool = false
    fileprivate var previousInvalidated: Bool = false
}

enum PersonalRediscoveryTurnOutcome: Equatable, Sendable {
    case committed(PersonalRediscoveryGrant)
    case existing(PersonalRediscoveryGrant)
    case refreshRequired
    case unavailable
}

struct PersonalRediscoverySnapshot: Equatable, Sendable {
    var candidates: [PersonalRediscoveryCandidate]
    var eligibilityRevision: String
    var scopeIdentifier: String
    var eligiblePhotoIDs: Set<String>
    var photoModificationDates: [String: Date]
    var isAuthorized: Bool
    var history: [PersonalRediscoveryGrant]
    var latestGrant: PersonalRediscoveryGrant?
    var nextAvailableAt: Date?
    var canTurn: Bool
    var remainingUnissuedCount: Int
    var retirableCandidateCount: Int
}

private struct PersonalRediscoveryCycle: Codable {
    var index: Int64
    var startSlot: Int64
    var order: [String]
}

private struct PersonalRediscoveryPlan: Codable {
    var id: String
    var anchor: Date
    var interval: TimeInterval
    var seed: UInt64
    var cycles: [PersonalRediscoveryCycle]
    // nil is a pre-daily (20-minute) plan. Keep its images and migrate the
    // currently selected photo on first use, rather than clearing the store.
    var calendarTimeZoneIdentifier: String? = nil
}

private struct PersonalRediscoveryIssue: Codable {
    var slotID: String
    var photoID: String
    var scheduledAt: Date
    var issuedAt: Date
    var leaseUntil: Date
    var cacheFilenames: [String]
    var invalidated: Bool = false
}

private struct PersonalRediscoveryOperation: Codable {
    var id: String
    var createdAt: Date
    var grantID: String
}

private struct PersonalRediscoveryFile: Codable {
    var schemaVersion = 1
    var sourceID = PersonalRediscoveryStore.personalSourceID
    var eligibilityRevision: String
    var scopeIdentifier: String
    var eligiblePhotoIDs: Set<String>
    var modificationDates: [String: Date]
    var isAuthorized: Bool
    var candidates: [PersonalRediscoveryCandidate] = []
    var plan: PersonalRediscoveryPlan? = nil
    var issues: [PersonalRediscoveryIssue] = []
    var grants: [PersonalRediscoveryGrant] = []
    var operations: [PersonalRediscoveryOperation] = []
    var nextAvailableAt: Date? = nil
    var updatedAt: Date
}

/// The app, Widget provider and intents share this single commit boundary.
/// PhotoKit and JPEG rendering stay outside it. Callbacks must be synchronous,
/// must not call this store again, and may touch only personal derived files.
struct PersonalRediscoveryStore: Sendable {
    enum Error: Swift.Error, Equatable {
        case unavailable
        case corrupted
        case staleRevision
        case invalidCandidate
        case cacheBudgetExceeded
        case lockFailed(Int32)
    }

    static let shared = PersonalRediscoveryStore()
    static let personalSourceID = "personal-library"
    static let maximumCandidateCount = 100
    static let maximumCachedFileCount = 400
    static let maximumTimelineEntryCount = 2
    private static let processLock = NSLock()
    private static let historyDuration: TimeInterval = 48 * 60 * 60
    private static let operationDuration: TimeInterval = 7 * 24 * 60 * 60
    private static let leaseDuration: TimeInterval = 12 * 60 * 60
    private let containerURL: URL?

    private static var defaultContainerURL: URL? {
#if PERSONAL_REDISCOVERY_CHECKS
        return nil
#else
        return SharedContainer.containerURL
#endif
    }

    init(containerURL: URL? = Self.defaultContainerURL) {
        self.containerURL = containerURL
    }

    /// Publish the current eligibility authority before starting asynchronous
    /// cache work. An empty pool can adopt up to twenty verified legacy cache
    /// items in the same commit, so a later cache-build failure does not blank it.
    /// Added photos do not invalidate retained, unchanged items.
    @discardableResult
    func updateEligibility(
        photoIDs: Set<String>,
        scopeIdentifier: String,
        isAuthorized: Bool,
        now: Date = .now,
        photoModificationDates: [String: Date] = [:],
        bootstrapCandidates: [PersonalRediscoveryCandidate] = [],
        interval: TimeInterval = 20 * 60,
        timeZone: TimeZone = .current
    ) throws -> String {
        try locked {
            guard photoIDs.allSatisfy(Self.validIdentifier), !scopeIdentifier.isEmpty,
                  scopeIdentifier.utf8.count <= 4_096,
                  interval.isFinite, (60...86_400).contains(interval) else { throw Error.invalidCandidate }
            var state = try read() ?? PersonalRediscoveryFile(
                eligibilityRevision: UUID().uuidString, scopeIdentifier: scopeIdentifier,
                eligiblePhotoIDs: [], modificationDates: [:], isAuthorized: false,
                updatedAt: now
            )
            let allowed = isAuthorized ? photoIDs : []
            let versions = photoModificationDates.filter { allowed.contains($0.key) }
            if state.scopeIdentifier != scopeIdentifier || state.eligiblePhotoIDs != allowed
                || state.isAuthorized != isAuthorized || state.modificationDates != versions {
                state.eligibilityRevision = UUID().uuidString
            }
            state.scopeIdentifier = scopeIdentifier
            state.eligiblePhotoIDs = allowed
            state.modificationDates = versions
            state.isAuthorized = isAuthorized
            let authority = state
            state.candidates.removeAll { !eligible($0.item, in: authority) }
            for index in state.grants.indices {
                if !eligible(state.grants[index].resultItem, in: state) {
                    state.grants[index].resultInvalidated = true
                }
                if !eligible(state.grants[index].previousItem, in: state) {
                    state.grants[index].previousInvalidated = true
                }
            }
            for index in state.issues.indices where !allowed.contains(state.issues[index].photoID) {
                state.issues[index].invalidated = true
            }
            if !isAuthorized { state.plan = nil }
            prune(&state, now: now)
            if isAuthorized && state.candidates.isEmpty {
                var protected = pinnedFiles(state, now: now)
                var inspectedIDs = Set<String>()
                // Legacy manifests contain at most twenty items. Bound decode
                // work and never inspect files before checking current authority.
                for candidate in bootstrapCandidates.prefix(20) {
                    guard eligible(candidate.item, in: state), validItem(candidate.item),
                          inspectedIDs.insert(candidate.item.localIdentifier).inserted else { continue }
                    let proposedFiles = protected.union(candidate.item.allCacheFilenames)
                    guard proposedFiles.count <= Self.maximumCachedFileCount,
                          commitCandidateReady(candidate.item) else { continue }
                    state.candidates.append(candidate)
                    protected = proposedFiles
                }
                if state.plan == nil && !state.candidates.isEmpty {
                    state.plan = makePlan(candidates: state.candidates, anchor: now, timeZone: timeZone)
                }
            }
            repairPlan(&state, now: now)
            state.updatedAt = now
            try write(state)
            return state.eligibilityRevision
        }
    }

    func invalidate(now: Date = .now) throws {
        _ = try updateEligibility(photoIDs: [], scopeIdentifier: "invalidated", isAuthorized: false, now: now)
    }

    /// A foreground authority mutation temporarily blocks readers/writers while
    /// retaining the old cache and history for a subsequent successful reconcile.
    func suspend(now: Date = .now) throws {
        try locked {
            var state = try read() ?? PersonalRediscoveryFile(
                eligibilityRevision: UUID().uuidString, scopeIdentifier: "suspended",
                eligiblePhotoIDs: [], modificationDates: [:], isAuthorized: false, updatedAt: now)
            state.eligibilityRevision = UUID().uuidString
            state.isAuthorized = false
            state.updatedAt = now
            try write(state)
        }
    }

    /// Background PhotoKit reconciliation may remove inaccessible IDs, but can
    /// never widen foreground authority or override a newer foreground revision.
    @discardableResult
    func restrictEligibility(
        to photoIDs: Set<String>, expectedRevision: String, now: Date = .now
    ) throws -> String {
        try locked {
            guard var state = try read(), state.isAuthorized,
                  state.eligibilityRevision == expectedRevision else { throw Error.staleRevision }
            let allowed = state.eligiblePhotoIDs.intersection(photoIDs)
            guard allowed != state.eligiblePhotoIDs else { return state.eligibilityRevision }
            state.eligibilityRevision = UUID().uuidString
            state.eligiblePhotoIDs = allowed
            state.modificationDates = state.modificationDates.filter { allowed.contains($0.key) }
            state.candidates.removeAll { !allowed.contains($0.item.localIdentifier) }
            for index in state.grants.indices {
                if !allowed.contains(state.grants[index].photoID) { state.grants[index].resultInvalidated = true }
                if !allowed.contains(state.grants[index].previousPhotoID) { state.grants[index].previousInvalidated = true }
            }
            for index in state.issues.indices where !allowed.contains(state.issues[index].photoID) {
                state.issues[index].invalidated = true
            }
            state.updatedAt = now
            prune(&state, now: now)
            repairPlan(&state, now: now)
            try write(state)
            return state.eligibilityRevision
        }
    }

    /// `prepareFiles` receives the union of old and proposed references. It may
    /// atomically install staged JPEGs and a compatibility manifest, but must
    /// preserve every name in this set. A thrown callback publishes no state.
    @discardableResult
    func publish(
        candidates incoming: [PersonalRediscoveryCandidate],
        expectedRevision: String,
        now: Date = .now,
        interval: TimeInterval = 20 * 60,
        discardCandidateIDs: Set<String> = [],
        timeZone: TimeZone = .current,
        prepareFiles: (Set<String>) throws -> Void = { _ in }
    ) throws -> PersonalRediscoverySnapshot {
        try locked {
            guard var state = try read(), state.isAuthorized,
                  state.eligibilityRevision == expectedRevision else { throw Error.staleRevision }
            guard interval.isFinite, (60...86_400).contains(interval),
                  incoming.count <= Self.maximumCandidateCount,
                  Set(incoming.map { $0.item.localIdentifier }).count == incoming.count
            else { throw Error.invalidCandidate }
            prune(&state, now: now)
            let before = protectedFiles(state, now: now)
            var proposed = state.candidates.filter { !discardCandidateIDs.contains($0.item.localIdentifier) }
            for candidate in incoming {
                guard eligible(candidate.item, in: state), validItem(candidate.item) else {
                    throw Error.invalidCandidate
                }
                if let index = proposed.firstIndex(where: {
                    $0.item.localIdentifier == candidate.item.localIdentifier
                }) {
                    proposed[index] = candidate
                } else {
                    proposed.append(candidate)
                }
            }
            let pinned = pinnedFiles(state, now: now)
            let used = Set(state.issues.filter {
                !$0.invalidated && $0.scheduledAt <= now
            }.map(\.photoID))
            // Prefer retiring consumed, unpinned old candidates. New images
            // never evict the current/issued or retained manual pictures.
            let incomingIDs = Set(incoming.map { $0.item.localIdentifier })
            while proposed.count > Self.maximumCandidateCount
                || Set(proposed.flatMap { $0.item.allCacheFilenames }).union(pinned).count > Self.maximumCachedFileCount {
                if let index = proposed.firstIndex(where: {
                    used.contains($0.item.localIdentifier)
                        && !incomingIDs.contains($0.item.localIdentifier)
                        && pinned.isDisjoint(with: $0.item.allCacheFilenames)
                }) {
                    proposed.remove(at: index)
                } else if let index = proposed.lastIndex(where: { candidate in
                    incomingIDs.contains(candidate.item.localIdentifier)
                        && !state.candidates.contains(where: { old in old.item.localIdentifier == candidate.item.localIdentifier })
                }) {
                    proposed.remove(at: index)
                } else {
                    throw Error.cacheBudgetExceeded
                }
            }
            let nextFiles = Set(proposed.flatMap { $0.item.allCacheFilenames }).union(pinned)
            // Include the previous commit until the new atomic state exists.
            // The caller stages outside widget-cache when this transient union
            // cannot fit; it must not destroy old files to force publication.
            guard before.union(nextFiles).count <= Self.maximumCachedFileCount else {
                throw Error.cacheBudgetExceeded
            }
            try prepareFiles(before.union(nextFiles))
            for candidate in proposed where !allFilesReadable(candidate.item) {
                throw Error.invalidCandidate
            }
            state.candidates = proposed
            if state.plan == nil, !proposed.isEmpty {
                state.plan = makePlan(candidates: proposed, anchor: now, timeZone: timeZone)
            } else if var plan = state.plan, let last = plan.cycles.indices.last {
                // Append beyond already-issued slots. Keeping the established
                // interval avoids a save/refill silently moving the anchor.
                let oldIDs = Set(plan.cycles[last].order)
                let additions = proposed.map { $0.item.localIdentifier }.filter { !oldIDs.contains($0) }
                plan.cycles[last].order.append(contentsOf: additions.prefix(max(0, Self.maximumCandidateCount - plan.cycles[last].order.count)))
                state.plan = plan
            }
            repairPlan(&state, now: now)
            state.updatedAt = now
            try write(state)
            return snapshot(state, now: now)
        }
    }

    /// Cleanup and compatibility publication use this gate too. Never call
    /// another store method from the callback (the process lock is not recursive).
    func withProtectedCacheFiles<Value>(
        expectedRevision: String? = nil,
        now: Date = .now,
        operation: (Set<String>) throws -> Value
    ) throws -> Value {
        try locked {
            guard var state = try read() else { throw Error.unavailable }
            if let expectedRevision, expectedRevision != state.eligibilityRevision {
                throw Error.staleRevision
            }
            prune(&state, now: now)
            try write(state)
            return try operation(protectedFiles(state, now: now))
        }
    }

    func snapshot(now: Date = .now) throws -> PersonalRediscoverySnapshot? {
        try locked {
            guard let state = try read() else { return nil }
            return snapshot(state, now: now)
        }
    }

    func currentEntry(
        now: Date = .now, timeZone: TimeZone = .current
    ) throws -> PersonalRediscoveryEntry? {
        try locked {
            guard var state = try read(), state.isAuthorized else { return nil }
            prune(&state, now: now)
            let result = resolve(&state, date: now, now: now, timeZone: timeZone)
            try write(state)
            return result
        }
    }

    func historyImageURL(
        grantID: String, previous: Bool,
        variant: WidgetImageVariant = .medium, now: Date = .now
    ) throws -> URL? {
        try locked {
            guard let state = try read(), state.isAuthorized,
                  let grant = state.grants.first(where: { $0.id == grantID }),
                  now < grant.resultExpiresAt else { return nil }
            let item = previous ? grant.previousItem : grant.resultItem
            guard !(previous ? grant.previousInvalidated : grant.resultInvalidated),
                  eligible(item, in: state),
                  fileReadable(item.cacheFilename(for: variant), maximumBytes: variant.maximumJPEGByteCount),
                  let containerURL else { return nil }
            return containerURL.appendingPathComponent("widget-cache").appendingPathComponent(item.cacheFilename(for: variant))
        }
    }

    func issueTimeline(
        now: Date = .now,
        variant: WidgetImageVariant,
        sourceID: String = Self.personalSourceID,
        timeZone: TimeZone = .current
    ) throws -> PersonalRediscoveryTimeline? {
        guard sourceID == Self.personalSourceID else { return nil }
        return try locked {
            guard var state = try read() else { return nil }
            prune(&state, now: now)
            guard state.isAuthorized, let first = resolve(&state, date: now, now: now, timeZone: timeZone) else {
                return PersonalRediscoveryTimeline(entries: [], reloadDate: now.addingTimeInterval(20 * 60))
            }
            var entries = [first]
            let boundary = min(nextBoundary(state, now: now), Self.nextMidnight(now, timeZone: timeZone))
            if let next = resolve(&state, date: boundary, now: now, timeZone: timeZone) {
                entries.append(next)
            }
            for index in entries.indices {
                guard let item = entries[index].item else { continue }
                // Resolve photo identity first; a missing size never compacts
                // the pool into a different photo for this widget family.
                guard fileReadable(item.cacheFilename(for: variant), maximumBytes: variant.maximumJPEGByteCount) else {
                    entries[index].item = nil
                    entries[index].action = .unavailable
                    continue
                }
                if let existing = state.issues.firstIndex(where: { $0.slotID == entries[index].slotID && $0.photoID == item.localIdentifier }) {
                    state.issues[existing].leaseUntil = max(state.issues[existing].leaseUntil,
                        Self.nextMidnight(entries[index].date, timeZone: timeZone).addingTimeInterval(Self.leaseDuration))
                    state.issues[existing].cacheFilenames = Array(Set(state.issues[existing].cacheFilenames).union(item.allCacheFilenames)).sorted()
                } else {
                    state.issues.append(PersonalRediscoveryIssue(
                        slotID: entries[index].slotID, photoID: item.localIdentifier,
                        scheduledAt: entries[index].date, issuedAt: now,
                        leaseUntil: Self.nextMidnight(entries[index].date, timeZone: timeZone).addingTimeInterval(Self.leaseDuration),
                        cacheFilenames: item.allCacheFilenames
                    ))
                }
            }
            prune(&state, now: now)
            try write(state) // A failed lease/journal commit must not issue the entries.
            let reload = min(nextBoundary(state, now: boundary), Self.nextMidnight(boundary, timeZone: timeZone))
            return PersonalRediscoveryTimeline(entries: entries, reloadDate: reload)
        }
    }

    /// The entry token identifies the old visible control; operationID identifies
    /// this invocation and remains fixed only during retries of that invocation.
    /// Yesterday's control refreshes instead of silently spending today's turn.
    func perform(
        token: PersonalRediscoveryEntryToken,
        operationID: String,
        operationCreatedAt: Date,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) throws -> PersonalRediscoveryTurnOutcome {
        guard token.sourceID == Self.personalSourceID,
              UUID(uuidString: operationID) != nil,
              UUID(uuidString: token.scopeRevision) != nil,
              Self.validIdentifier(token.photoID),
              operationCreatedAt <= now.addingTimeInterval(5 * 60),
              now.timeIntervalSince(operationCreatedAt) <= Self.operationDuration,
              token.createdAt <= now.addingTimeInterval(5 * 60),
              now.timeIntervalSince(token.createdAt) <= Self.operationDuration
        else { return .refreshRequired }
        // Decode only a bounded shortlist outside the cross-process gate. The
        // commit below reloads authority/quota and requires the exact prepared
        // manifest item to remain current after this preparation boundary.
        let shortlist: [PersonalRediscoveryCandidate] = try locked {
            guard let state = try read(), state.isAuthorized,
                  state.eligibilityRevision == token.scopeRevision,
                  token.eligibilityDay == Self.dayKey(now, timeZone: timeZone),
                  state.operations.allSatisfy({ $0.id != operationID }),
                  state.nextAvailableAt.map({ now >= $0 }) ?? true,
                  let original = state.candidates.first(where: { $0.item.localIdentifier == token.photoID })
            else { return [] }
            return Array(manualCandidates(state, original: original, operationID: operationID, now: now).prefix(10))
        }
        let preparedSelection = shortlist.first(where: { commitCandidateReady($0.item) })
        return try locked {
            guard var state = try read() else { return .unavailable }
            prune(&state, now: now)
            if let operation = state.operations.first(where: { $0.id == operationID }) {
                guard let grant = state.grants.first(where: { $0.id == operation.grantID }) else {
                    throw Error.corrupted
                }
                return .existing(availableGrant(grant, in: state, now: now))
            }
            guard token.eligibilityDay == Self.dayKey(now, timeZone: timeZone) else {
                return .refreshRequired
            }
            guard state.isAuthorized, state.eligibilityRevision == token.scopeRevision,
                  let original = state.candidates.first(where: { $0.item.localIdentifier == token.photoID }),
                  eligible(original.item, in: state), allFilesReadable(original.item)
            else { return .unavailable }
            if let next = state.nextAvailableAt, now < next {
                guard let grant = state.grants.max(by: { $0.committedAt < $1.committedAt }) else {
                    throw Error.corrupted
                }
                state.operations.append(PersonalRediscoveryOperation(id: operationID, createdAt: operationCreatedAt, grantID: grant.id))
                prune(&state, now: now)
                try write(state)
                return .existing(availableGrant(grant, in: state, now: now))
            }
            guard let selected = preparedSelection,
                  state.candidates.contains(where: { $0.item == selected.item }),
                  eligible(selected.item, in: state), allFilesReadable(selected.item) else {
                return .unavailable
            }
            ensureDailyPlan(&state, now: now, timeZone: timeZone)
            let until = Self.nextMidnight(now, timeZone: timeZone)
            let grant = PersonalRediscoveryGrant(
                id: UUID().uuidString, photoID: selected.item.localIdentifier,
                previousPhotoID: token.photoID, committedAt: now,
                resultExpiresAt: now.addingTimeInterval(Self.historyDuration),
                overrideUntil: until, scopeRevision: state.eligibilityRevision,
                previousIsAvailable: true, resultItem: selected.item, previousItem: original.item
            )
            var resume: [String] = []
            if let plan = state.plan {
                let slot = Self.slot(at: now, in: plan)
                if let cycle = plan.cycles.first(where: { $0.startSlot <= slot && slot < $0.startSlot + Int64($0.order.count) }) {
                    resume = Array(cycle.order.dropFirst(Int(slot - cycle.startSlot + 1)))
                }
            }
            let allowedIDs = Set(state.candidates.map { $0.item.localIdentifier })
            resume = resume.filter { allowedIDs.contains($0) && $0 != grant.photoID }
            if resume.isEmpty {
                resume = ordered(state.candidates.filter { $0.item.localIdentifier != grant.photoID }, seed: Self.stableHash(grant.id), avoiding: grant.photoID)
            }
            state.plan = PersonalRediscoveryPlan(
                id: UUID().uuidString, anchor: until, interval: 86_400,
                seed: Self.stableHash(grant.id),
                cycles: [PersonalRediscoveryCycle(index: 0, startSlot: 0, order: resume)],
                calendarTimeZoneIdentifier: timeZone.identifier
            )
            for index in state.issues.indices where state.issues[index].scheduledAt > now {
                // Keep file leases, but these canceled reservations are not selection usage.
                state.issues[index].invalidated = true
            }
            state.grants.append(grant)
            state.operations.append(PersonalRediscoveryOperation(id: operationID, createdAt: operationCreatedAt, grantID: grant.id))
            state.nextAvailableAt = Self.nextMidnight(now, timeZone: timeZone)
            state.updatedAt = now
            prune(&state, now: now)
            try write(state) // Grant, quota, anchor and resume sequence have one commit point.
            return .committed(grant)
        }
    }

    private func manualCandidates(
        _ state: PersonalRediscoveryFile, original: PersonalRediscoveryCandidate,
        operationID: String, now: Date
    ) -> [PersonalRediscoveryCandidate] {
        let activeManual = state.grants.last(where: { !$0.resultInvalidated && now < $0.overrideUntil })?.photoID
        let recent = Set(state.issues.filter {
            !$0.invalidated && $0.scheduledAt <= now && now.timeIntervalSince($0.scheduledAt) < 24 * 60 * 60
        }.map(\.photoID)).union(state.grants.filter { now.timeIntervalSince($0.committedAt) <= Self.operationDuration }.map(\.photoID))
        let candidates = state.candidates.filter {
            $0.item.localIdentifier != original.item.localIdentifier && $0.item.localIdentifier != activeManual
                && eligible($0.item, in: state)
        }
        let order = ordered(candidates, seed: Self.stableHash(operationID), avoiding: original.item.localIdentifier,
            lastUsed: lastUsage(state, now: now), now: now)
        let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return candidates.sorted { lhs, rhs in
            let leftRecent = recent.contains(lhs.item.localIdentifier)
            let rightRecent = recent.contains(rhs.item.localIdentifier)
            if leftRecent != rightRecent { return !leftRecent }
            let leftGroup = Self.sameCaptureGroup(lhs, original)
            let rightGroup = Self.sameCaptureGroup(rhs, original)
            if leftGroup != rightGroup { return !leftGroup }
            return (positions[lhs.item.localIdentifier] ?? 0) < (positions[rhs.item.localIdentifier] ?? 0)
        }
    }

    private func resolve(
        _ state: inout PersonalRediscoveryFile, date: Date, now: Date, timeZone: TimeZone,
        dailyPlanReady: Bool = false
    ) -> PersonalRediscoveryEntry? {
        if !dailyPlanReady { ensureDailyPlan(&state, now: now, timeZone: timeZone) }
        if let grant = state.grants.last(where: { date >= $0.committedAt && date < $0.overrideUntil }),
           !grant.resultInvalidated, eligible(grant.resultItem, in: state) {
            return entry(item: grant.resultItem, date: date, slotID: "manual-\(grant.id)", state: state, now: now, timeZone: timeZone)
        }
        repairPlan(&state, now: date)
        guard var plan = state.plan, !state.candidates.isEmpty else { return nil }
        let slot = Self.slot(at: date, in: plan)
        if let last = plan.cycles.last, slot >= last.startSlot + Int64(last.order.count) {
            let count = Int64(state.candidates.count)
            let firstNext = last.startSlot + Int64(last.order.count)
            let skipped = (slot - firstNext) / count
            let index = last.index + skipped + 1
            let order = ordered(state.candidates, seed: plan.seed &+ UInt64(bitPattern: index), avoiding: last.order.last,
                lastUsed: lastUsage(state, now: now), now: now)
            plan.cycles.append(PersonalRediscoveryCycle(index: index, startSlot: firstNext + skipped * count, order: order))
            if plan.cycles.count > 2 { plan.cycles.removeFirst(plan.cycles.count - 2) }
            state.plan = plan
        }
        guard let cycle = plan.cycles.first(where: { $0.startSlot <= slot && slot < $0.startSlot + Int64($0.order.count) }) else { return nil }
        let photoID = cycle.order[Int(slot - cycle.startSlot)]
        let item = state.candidates.first(where: { $0.item.localIdentifier == photoID && eligible($0.item, in: state) })?.item
        return entry(item: item, date: date, slotID: "\(plan.id)-\(slot)", state: state, now: now, timeZone: timeZone)
    }

    /// Migrate the old cadence, or rebase after a timezone change, while keeping
    /// today's visible photo and the committed turn. A refill never reselects it.
    private func ensureDailyPlan(_ state: inout PersonalRediscoveryFile, now: Date, timeZone: TimeZone) {
        guard let old = state.plan,
              old.calendarTimeZoneIdentifier != timeZone.identifier,
              !state.candidates.isEmpty else { return }
        let current = resolve(&state, date: now, now: now, timeZone: timeZone,
                              dailyPlanReady: true)?.item?.localIdentifier
        var replacement = makePlan(candidates: state.candidates, anchor: now, timeZone: timeZone)
        if let current, let index = replacement.cycles[0].order.firstIndex(of: current) {
            replacement.cycles[0].order.swapAt(0, index)
        }
        let tomorrow = Self.nextMidnight(now, timeZone: timeZone)
        if let index = state.grants.lastIndex(where: {
            now >= $0.committedAt && now < $0.overrideUntil && !$0.resultInvalidated
        }) {
            state.grants[index].overrideUntil = max(state.grants[index].overrideUntil, tomorrow)
            state.nextAvailableAt = max(state.nextAvailableAt ?? tomorrow, state.grants[index].overrideUntil)
        }
        for index in state.issues.indices where state.issues[index].scheduledAt > now {
            state.issues[index].invalidated = true
        }
        state.plan = replacement
    }

    /// Only an authority/pool change repairs missing IDs. Missing JPEG variants
    /// never enter this function as a reason to replace a canonical photo.
    private func repairPlan(_ state: inout PersonalRediscoveryFile, now: Date) {
        guard var plan = state.plan, !state.candidates.isEmpty else { return }
        let allowed = Set(state.candidates.map { $0.item.localIdentifier })
        let slot = Self.slot(at: now, in: plan)
        let choices = ordered(state.candidates, seed: plan.seed, avoiding: nil)
        for cycleIndex in plan.cycles.indices {
            var cycle = plan.cycles[cycleIndex]
            let present = Set(cycle.order.filter { allowed.contains($0) })
            var additions = choices.filter { !present.contains($0) }
            for position in cycle.order.indices where !allowed.contains(cycle.order[position]) {
                guard cycle.startSlot + Int64(position) >= slot else { continue }
                let previous = position > 0 ? cycle.order[position - 1] : nil
                let next = position + 1 < cycle.order.count ? cycle.order[position + 1] : nil
                let preferred = additions.isEmpty ? choices : additions
                let replacement = preferred.first(where: { $0 != previous && $0 != next })
                    ?? preferred.first(where: { $0 != previous }) ?? preferred.first
                if let replacement {
                    cycle.order[position] = replacement
                    additions.removeAll { $0 == replacement }
                }
            }
            plan.cycles[cycleIndex] = cycle
        }
        state.plan = plan
    }

    private func entry(
        item: WidgetManifestItem?, date: Date, slotID: String,
        state: PersonalRediscoveryFile, now: Date, timeZone: TimeZone
    ) -> PersonalRediscoveryEntry {
        let action: PersonalRediscoveryAction
        if let item, state.candidates.count > 1 {
            if let next = state.nextAvailableAt, date < next, let grant = state.grants.last {
                action = .used(grantID: grant.id)
            } else {
                let day = Self.dayKey(date, timeZone: timeZone)
                let slotStart = state.plan.map { Self.date(forSlot: Self.slot(at: date, in: $0), in: $0) } ?? date
                action = .available(token: PersonalRediscoveryEntryToken(
                    id: "\(slotID)-\(day)", createdAt: min(date, slotStart),
                    eligibilityDay: day, sourceID: Self.personalSourceID,
                    photoID: item.localIdentifier, scopeRevision: state.eligibilityRevision
                ))
            }
        } else { action = .unavailable }
        return PersonalRediscoveryEntry(date: date, item: item, slotID: slotID, scopeRevision: state.eligibilityRevision, action: action)
    }

    private func nextBoundary(_ state: PersonalRediscoveryFile, now: Date) -> Date {
        if let grant = state.grants.last, now < grant.overrideUntil { return grant.overrideUntil }
        guard let plan = state.plan else { return now.addingTimeInterval(20 * 60) }
        return Self.date(forSlot: Self.slot(at: now, in: plan) + 1, in: plan)
    }

    private func makePlan(candidates: [PersonalRediscoveryCandidate], anchor: Date, timeZone: TimeZone) -> PersonalRediscoveryPlan {
        let id = UUID().uuidString
        let seed = Self.stableHash(id)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return PersonalRediscoveryPlan(id: id, anchor: calendar.startOfDay(for: anchor), interval: 86_400, seed: seed,
            cycles: [PersonalRediscoveryCycle(index: 0, startSlot: 0, order: ordered(candidates, seed: seed, avoiding: nil))],
            calendarTimeZoneIdentifier: timeZone.identifier)
    }

    /// Bounded O(n²), n <= 100. No repeated whole-order improvement search.
    /// The initial release keeps allocation neutral; 6:3:1 is a later comparison.
    private func ordered(
        _ candidates: [PersonalRediscoveryCandidate], seed: UInt64, avoiding: String?,
        lastUsed: [String: Date] = [:], now: Date = .now
    ) -> [String] {
        var random = PersonalRediscoveryRandom(seed: seed)
        var remaining = candidates.sorted { $0.item.localIdentifier < $1.item.localIdentifier }
        remaining.shuffle(using: &random)
        let tieOrder = Dictionary(uniqueKeysWithValues: remaining.enumerated().map { ($0.element.item.localIdentifier, $0.offset) })
        remaining.sort { lhs, rhs in
            let left = lastUsed[lhs.item.localIdentifier] ?? .distantPast
            let right = lastUsed[rhs.item.localIdentifier] ?? .distantPast
            let leftRecent = now.timeIntervalSince(left) < 24 * 60 * 60
            let rightRecent = now.timeIntervalSince(right) < 24 * 60 * 60
            if leftRecent != rightRecent { return !leftRecent }
            if left != right { return left < right }
            return (tieOrder[lhs.item.localIdentifier] ?? 0) < (tieOrder[rhs.item.localIdentifier] ?? 0)
        }
        var result: [PersonalRediscoveryCandidate] = []
        while !remaining.isEmpty {
            let index = remaining.firstIndex(where: { candidate in
                if result.isEmpty { return candidate.item.localIdentifier != avoiding }
                return !Self.sameCaptureGroup(candidate, result[result.count - 1])
            }) ?? 0
            result.append(remaining.remove(at: index))
        }
        return result.map { $0.item.localIdentifier }
    }

    private func lastUsage(_ state: PersonalRediscoveryFile, now: Date) -> [String: Date] {
        var result: [String: Date] = [:]
        for issue in state.issues where !issue.invalidated && issue.scheduledAt <= now {
            result[issue.photoID] = max(result[issue.photoID] ?? .distantPast, issue.scheduledAt)
        }
        for grant in state.grants where grant.committedAt <= now {
            result[grant.photoID] = max(result[grant.photoID] ?? .distantPast, grant.committedAt)
        }
        return result
    }

    private static func sameCaptureGroup(_ lhs: PersonalRediscoveryCandidate, _ rhs: PersonalRediscoveryCandidate) -> Bool {
        if let burst = lhs.burstIdentifier, !burst.isEmpty, burst == rhs.burstIdentifier { return true }
        if let first = lhs.creationDate, let second = rhs.creationDate {
            return abs(first.timeIntervalSince(second)) <= 30 * 60
        }
        return false
    }

    private func snapshot(_ state: PersonalRediscoveryFile, now: Date) -> PersonalRediscoverySnapshot {
        let history = state.grants.map { availableGrant($0, in: state, now: now) }
            .filter { $0.resultIsAvailable || $0.previousIsAvailable }
            .sorted { $0.committedAt > $1.committedAt }
        let used = Set(state.issues.filter { !$0.invalidated && $0.scheduledAt <= now }.map(\.photoID))
        let pinned = pinnedFiles(state, now: now)
        return PersonalRediscoverySnapshot(
            candidates: state.candidates, eligibilityRevision: state.eligibilityRevision,
            scopeIdentifier: state.scopeIdentifier, eligiblePhotoIDs: state.eligiblePhotoIDs,
            photoModificationDates: state.modificationDates, isAuthorized: state.isAuthorized,
            history: history, latestGrant: history.first, nextAvailableAt: state.nextAvailableAt,
            canTurn: state.isAuthorized && state.candidates.count > 1 && (state.nextAvailableAt.map { now >= $0 } ?? true),
            remainingUnissuedCount: state.candidates.filter { !used.contains($0.item.localIdentifier) }.count,
            retirableCandidateCount: state.candidates.filter {
                used.contains($0.item.localIdentifier) && pinned.isDisjoint(with: $0.item.allCacheFilenames)
            }.count
        )
    }

    private func availableGrant(_ grant: PersonalRediscoveryGrant, in state: PersonalRediscoveryFile, now: Date) -> PersonalRediscoveryGrant {
        var value = grant
        value.resultIsAvailable = !grant.resultInvalidated && now < grant.resultExpiresAt
            && eligible(grant.resultItem, in: state)
        value.previousIsAvailable = !grant.previousInvalidated && now < grant.resultExpiresAt
            && eligible(grant.previousItem, in: state)
        return value
    }

    private func eligible(_ item: WidgetManifestItem, in state: PersonalRediscoveryFile) -> Bool {
        state.isAuthorized && retainedByAuthority(item, in: state)
    }

    private func retainedByAuthority(_ item: WidgetManifestItem, in state: PersonalRediscoveryFile) -> Bool {
        guard state.eligiblePhotoIDs.contains(item.localIdentifier) else { return false }
        if let modified = state.modificationDates[item.localIdentifier] {
            return item.sourceModificationDate == modified
        }
        return true
    }

    private func pinnedFiles(_ state: PersonalRediscoveryFile, now: Date) -> Set<String> {
        var result = Set(state.issues.filter {
            now < $0.leaseUntil && state.eligiblePhotoIDs.contains($0.photoID)
        }.flatMap(\.cacheFilenames))
        for grant in state.grants where now < grant.resultExpiresAt {
            if !grant.resultInvalidated && retainedByAuthority(grant.resultItem, in: state) {
                result.formUnion(grant.resultItem.allCacheFilenames)
            }
            if !grant.previousInvalidated && retainedByAuthority(grant.previousItem, in: state) {
                result.formUnion(grant.previousItem.allCacheFilenames)
            }
        }
        return result
    }

    private func protectedFiles(_ state: PersonalRediscoveryFile, now: Date) -> Set<String> {
        Set(state.candidates.filter { retainedByAuthority($0.item, in: state) }.flatMap { $0.item.allCacheFilenames })
            .union(pinnedFiles(state, now: now))
    }

    private func prune(_ state: inout PersonalRediscoveryFile, now: Date) {
        state.issues.removeAll { now.timeIntervalSince($0.scheduledAt) > 30 * 24 * 60 * 60 }
        if state.issues.count > 3_000 { state.issues.removeFirst(state.issues.count - 3_000) }
        state.operations.removeAll { now.timeIntervalSince($0.createdAt) > Self.operationDuration }
        if state.operations.count > 10_000 { state.operations.removeFirst(state.operations.count - 10_000) }
        // Keeping a grant referenced by an unexpired operation prevents quota
        // corruption around a retry created near the next day's boundary.
        let referenced = Set(state.operations.map(\.grantID))
        state.grants.removeAll { now.timeIntervalSince($0.committedAt) > Self.operationDuration && !referenced.contains($0.id) }
    }

    private func validItem(_ item: WidgetManifestItem) -> Bool {
        Self.validIdentifier(item.localIdentifier)
            && item.cacheFilenames != nil
            && item.allCacheFilenames.count == 3
            && Set(item.allCacheFilenames).count == 3
            && item.allCacheFilenames.allSatisfy(Self.validFilename)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validFilename(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.hasSuffix(".jpg")
            && !value.contains("/") && !value.contains("\\") && !value.contains("..")
            && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 || $0 == 46 }
    }

    private func allFilesReadable(_ item: WidgetManifestItem) -> Bool {
        validItem(item) && WidgetImageVariant.allCases.allSatisfy {
            fileReadable(item.cacheFilename(for: $0), maximumBytes: $0.maximumJPEGByteCount)
        }
    }

    private func commitCandidateReady(_ item: WidgetManifestItem) -> Bool {
        guard allFilesReadable(item) else { return false }
#if canImport(ImageIO)
        guard let containerURL else { return false }
        return WidgetImageVariant.allCases.allSatisfy { variant in
            autoreleasepool {
                let url = containerURL.appendingPathComponent("widget-cache").appendingPathComponent(item.cacheFilename(for: variant))
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      CGImageSourceGetCount(source) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0,
                      width <= variant.pixelWidth, height <= variant.pixelHeight,
                      let image = CGImageSourceCreateImageAtIndex(source, 0,
                          [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                else { return false }
                return image.width == width && image.height == height
            }
        }
#else
        // The standalone state-machine harness uses framed test bytes; target
        // builds additionally decode the chosen candidate before consuming.
        return true
#endif
    }

    private func fileReadable(_ filename: String, maximumBytes: Int) -> Bool {
        guard Self.validFilename(filename), let containerURL else { return false }
        let url = containerURL.appendingPathComponent("widget-cache").appendingPathComponent(filename)
        guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size >= 4, size <= maximumBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 3), header == Data([0xff, 0xd8, 0xff]) else { return false }
        do {
            try handle.seek(toOffset: UInt64(size - 2))
            return try handle.read(upToCount: 2) == Data([0xff, 0xd9])
        } catch { return false }
    }

    private func read() throws -> PersonalRediscoveryFile? {
        let url = try stateURL()
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && (error.code == CocoaError.fileReadNoSuchFile.rawValue || error.code == CocoaError.fileNoSuchFile.rawValue) {
                return nil
            }
            throw Error.unavailable
        }
        guard data.count <= 8 * 1_024 * 1_024,
              let state = try? JSONDecoder().decode(PersonalRediscoveryFile.self, from: data),
              state.schemaVersion == 1, state.sourceID == Self.personalSourceID,
              UUID(uuidString: state.eligibilityRevision) != nil,
              state.candidates.count <= Self.maximumCandidateCount,
              Set(state.candidates.map { $0.item.localIdentifier }).count == state.candidates.count,
              state.candidates.allSatisfy({ validItem($0.item) }),
              state.issues.count <= 3_002,
              Set(state.grants.map(\.id)).count == state.grants.count,
              state.operations.count <= 10_000,
              state.plan.map({ $0.interval.isFinite && (60...86_400).contains($0.interval)
                  && ($0.calendarTimeZoneIdentifier.map { TimeZone(identifier: $0) != nil } ?? true)
                  && $0.cycles.count <= 2 && $0.cycles.allSatisfy({ !$0.order.isEmpty && $0.order.count <= 200 && $0.startSlot >= 0 }) }) ?? true
        else { throw Error.corrupted }
        return state
    }

    private func write(_ state: PersonalRediscoveryFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= 8 * 1_024 * 1_024 else { throw Error.corrupted }
        let url = try stateURL()
        // Foundation's atomic replacement is the sole commit. No throwing
        // operation follows it, so callers cannot mistake success for failure.
        try data.write(to: url, options: .atomic)
#if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
#endif
    }

    private func stateURL() throws -> URL {
        guard let containerURL else { throw Error.unavailable }
        return containerURL.appendingPathComponent("personal-rediscovery.v1", isDirectory: true).appendingPathComponent("state.json")
    }

    private func locked<Value>(_ operation: () throws -> Value) throws -> Value {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let directory = try stateURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(excluded)
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
#endif
        let descriptor = open(directory.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Error.lockFailed(errno) }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw Error.lockFailed(errno) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func slot(at date: Date, in plan: PersonalRediscoveryPlan) -> Int64 {
        if let identifier = plan.calendarTimeZoneIdentifier, let timeZone = TimeZone(identifier: identifier) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return Int64(max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: plan.anchor),
                                                       to: calendar.startOfDay(for: date)).day ?? 0))
        }
        let value = max(0, floor(date.timeIntervalSince(plan.anchor) / plan.interval))
        return Int64(min(value, Double(Int64.max / 4)))
    }

    private static func date(forSlot slot: Int64, in plan: PersonalRediscoveryPlan) -> Date {
        if let identifier = plan.calendarTimeZoneIdentifier, let timeZone = TimeZone(identifier: identifier) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar.date(byAdding: .day, value: Int(slot), to: plan.anchor) ?? plan.anchor.addingTimeInterval(Double(slot) * 86_400)
        }
        return plan.anchor.addingTimeInterval(Double(slot) * plan.interval)
    }

    private static func dayKey(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(values.year ?? 0)-\(values.month ?? 0)-\(values.day ?? 0)"
    }

    private static func nextMidnight(_ date: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(24 * 60 * 60)
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

private struct PersonalRediscoveryRandom: RandomNumberGenerator {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed &+= 0x9E3779B97F4A7C15
        var value = seed
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
