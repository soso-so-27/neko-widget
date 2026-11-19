import Foundation

/// 11/15 (1115q): when the family notebook checks the family by itself. One
/// schedule for the app coming to the front, the notebook screen and a shared
/// tool's screen (`FamilyNotebookAutoCheck`), so two loops never run. Pure:
/// the call-count checks (ci/verify-sharing-call-budget.swift) drive it with
/// a synthetic clock. Every automatic call also passes the transport's
/// budget (`SharingAutoCallBudget`, 30 in any 60 s).
enum FamilyAutoCheckPolicy {
    enum Pass: Equatable, Sendable {
        /// The whole family: state, keys, sync, pause, requests.
        case full
        /// 「参加を待っている人」 only (directory and requests).
        case requestsOnly
    }

    struct Decision: Equatable, Sendable {
        let pass: Pass
        let after: TimeInterval
    }

    struct Situation: Equatable, Sendable {
        var notebookOpen = false
        var toolOpen = false
        /// 11/19: この子 shows a photo the family delivered (a family cat
        /// with no cat of this iPhone). The photo arrives with the notebook.
        var photoOpen = false
        /// The keys still move (`needsAnotherPass`).
        var keysMove = false
        /// Asked to join, not let in yet.
        var awaitingApproval = false
        var inFamily = false
        /// Key passes in a row in which nothing changed.
        var quietKeyPasses = 0
        var secondsSinceFull: TimeInterval = 0
    }

    /// Something changed: next at once (5 s). Nothing came: 10, 20, 40, 60.
    static let keyBackoff: [TimeInterval] = [5, 10, 20, 40, 60]
    static let awaitingInterval: TimeInterval = 30
    static let requestsInterval: TimeInterval = 20
    static let notebookFullInterval: TimeInterval = 60
    static let toolFullInterval: TimeInterval = 30
    /// 11/18: a notebook ended only by `family: null` is read again at most
    /// this often (one directory read when the app comes to the front).
    static let resumeProbeGap: TimeInterval = 60 * 60

    static var waitsOnOthers: TimeInterval { keyBackoff.last! }
    /// The app came to the front or a screen opened: not sooner than this
    /// after the last pass (a burst of openings is one pass).
    static let wakeGap: TimeInterval = 20
    /// After the person's own operation (a join, an approval): keys follow fast.
    static let nudgeGap: TimeInterval = 5
    /// 11/16: written on this iPhone, not sent yet: one pass, not sooner than
    /// this after the last (typing never reads more often than a shared
    /// tool's screen does).
    static let sendGap: TimeInterval = toolFullInterval

    /// When the next pass runs after a wake: the planned pass if it is sooner,
    /// else `gap` after the last pass (at once when none was recent).
    static func wakeDelay(now: Date, lastPassAt: Date?, plannedAt: Date?, gap: TimeInterval) -> TimeInterval {
        let gapDelay = lastPassAt.map { max(0, gap - now.timeIntervalSince($0)) } ?? 0
        guard let plannedAt else { return gapDelay }
        return min(max(0, plannedAt.timeIntervalSince(now)), gapDelay)
    }

    /// The next automatic pass, or nil: nothing until the app comes to the
    /// front again (or a screen of the notebook opens).
    static func next(_ s: Situation) -> Decision? {
        let screen = s.notebookOpen || s.toolOpen
        if s.keysMove {
            let delay = keyBackoff[min(s.quietKeyPasses, keyBackoff.count - 1)]
            // Only the other iPhone can move it now: every 60 s while a screen
            // of the notebook is open, else once per coming to the front.
            if delay >= waitsOnOthers && !screen { return nil }
            return .init(pass: .full, after: delay)
        }
        if s.awaitingApproval && !s.inFamily { return .init(pass: .full, after: awaitingInterval) }
        guard s.inFamily else { return nil }
        if s.toolOpen { return .init(pass: .full, after: toolFullInterval) }
        if s.notebookOpen {
            let full = s.secondsSinceFull + requestsInterval >= notebookFullInterval
            return .init(pass: full ? .full : .requestsOnly, after: requestsInterval)
        }
        // 11/19 (TestFlight 392): a new photo waited for the app to come to
        // the front again (7 minutes) while この子 stayed open.
        if s.photoOpen { return .init(pass: .full, after: notebookFullInterval) }
        return nil
    }
}

/// 11/15 (1115q): checking a purchase the server has not confirmed yet. The
/// billing relay allows 10 calls a minute per address, transactions and
/// entitlements counted apart. Three tries in the first minute (5, 20 and 45
/// s after the purchase), then every 30 s until 10 minutes; an automatic try
/// runs only while the last 60 s hold at most 4 of each, so a tap still fits
/// and no 60 s ever holds more than 6.
enum PlusConfirmationSchedule {
    static let firstMinuteDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(25)]
    static let followUpInterval: Duration = .seconds(30)
    static let window: TimeInterval = 10 * 60
    /// Automatic tries need fewer than this many of each in the last 60 s
    /// (1115v: the billing gate allows 4 automatic ones of each).
    static let automaticCeiling = BillingCallBudget.automaticPerMinute
    static let rateLimitedPause: TimeInterval = 60

    static func allowsAutomaticCheck(transactions: Int, entitlements: Int) -> Bool {
        transactions < automaticCeiling && entitlements < automaticCeiling
    }
}

/// 11/15 (1115v): the one gate in front of every billing call, at the very
/// send (`PlusPurchaseStore.refreshServerAuthority` and its transaction
/// record). The billing relay allows 10 calls a minute per address,
/// transactions and entitlements counted apart. A call nobody marked is
/// automatic: 4 of each kind in any 60 s, none for at least a minute after a
/// 429 (counted from when the 429 came). The person's own (buying, 購入を復元,
/// 「Plusをもう一度確かめる」, opening the Plus screen): with the automatic
/// ones, 8 of each kind in any 60 s.
final class BillingCallBudget: @unchecked Sendable {
    enum Kind: Sendable { case transaction, entitlement }

    static let shared = BillingCallBudget()
    static let automaticPerMinute = 4
    static let devicePerMinute = 8
    static let rateLimitedPause: TimeInterval = 60

    private let lock = NSLock()
    private var automatic: [Kind: SharingCallWindow] = [
        .transaction: SharingCallWindow(limit: automaticPerMinute),
        .entitlement: SharingCallWindow(limit: automaticPerMinute),
    ]
    private var all: [Kind: SharingCallWindow] = [
        .transaction: SharingCallWindow(limit: devicePerMinute),
        .entitlement: SharingCallWindow(limit: devicePerMinute),
    ]
    private var pausedUntil: Date?

    init() {}

    /// Takes one call of `kind` or refuses it (nothing is sent then).
    func admit(_ kind: Kind, personAction: Bool, at now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if personAction { return all[kind]!.admit(at: now) }
        if let pausedUntil, now < pausedUntil { return false }
        guard automatic[kind]!.count(at: now) < Self.automaticPerMinute,
              all[kind]!.count(at: now) < Self.devicePerMinute else { return false }
        _ = automatic[kind]!.admit(at: now); _ = all[kind]!.admit(at: now)
        return true
    }

    /// `now` is when the 429 came back.
    func noteRateLimited(retryAfter: TimeInterval? = nil, at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let until = now.addingTimeInterval(max(Self.rateLimitedPause, retryAfter ?? 0))
        pausedUntil = max(pausedUntil ?? until, until)
    }

    /// When an automatic call of `kind` may go again (now when nil).
    func nextAutomatic(_ kind: Kind, at now: Date = Date()) -> Date? {
        lock.lock(); defer { lock.unlock() }
        var next: Date?
        if let pausedUntil, now < pausedUntil { next = pausedUntil }
        for window in [automatic[kind]!, all[kind]!] where window.count(at: now) >= window.limit {
            if let oldest = window.times.filter({ now.timeIntervalSince($0) < window.seconds }).min() {
                let free = oldest.addingTimeInterval(window.seconds)
                next = max(next ?? free, free)
            }
        }
        return next
    }

    func automaticCalls(_ kind: Kind, at now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        return automatic[kind]!.count(at: now)
    }
}

/// A billing call the gate held back. Nothing was sent; the work is kept.
struct BillingCallDeferred: Error, Sendable {}

/// 11/15 (1115v-4, 1115w): the one gate in front of every call to the
/// automatic-save server that its owner limit counts
/// (`ManagedPreservationClient.authenticated`, and the deletion request).
/// The server allows 30 such calls per owner in each fixed UTC minute, and
/// two iPhones of one owner share them. Counted here over any 60 s, so no
/// fixed minute can hold more either. One iPhone alone may use most of them;
/// a 429 says another iPhone (or something else) shares the minute:
/// - usually: automatic (a call nobody marked) 24, with the person's own
///   (`SharingPersonAction.run`) 28 on this iPhone (under 30 with a margin);
/// - after a 429: no automatic call for at least a minute from when it came
///   back, then for 10 minutes automatic 10, with the person's own 14 (two
///   iPhones: 28), the person's restore or export (`PreservationBulkRead`)
///   20 (with the other iPhone's 10 automatic ones, 30). Ten minutes without
///   another 429 and it is back to the usual numbers.
/// A full window waits for its first free place (at most 60 s). Only an
/// automatic call during the pause is held: it is never sent, and the caller
/// sees the server's own 「少し待って」 answer, so the work stays unsent.
final class PreservationCallBudget: @unchecked Sendable {
    enum Decision: Equatable, Sendable {
        case send
        case wait(until: Date)
        /// Automatic, within the pause after a 429.
        case held
    }

    static let shared = PreservationCallBudget()
    static let automaticPerMinute = 24
    static let devicePerMinute = 28
    static let bulkPerMinute = 28
    static let automaticAfterRateLimit = 10
    static let deviceAfterRateLimit = 14
    static let bulkAfterRateLimit = 20
    static let rateLimitedPause: TimeInterval = 60
    /// After the pause, the lower numbers hold this long past the last 429.
    static let slowerAfterRateLimit: TimeInterval = 600
    /// Set only by `PreservationBulkRead.run`, inside the person's own action.
    @TaskLocal static var isBulkRead = false

    private let lock = NSLock()
    private var automatic = SharingCallWindow(limit: automaticPerMinute)
    private var all = SharingCallWindow(limit: bulkPerMinute)
    private var pausedUntil: Date?
    private var slowerUntil: Date?
    private var admitted = 0

    struct Limits: Equatable, Sendable { let automatic: Int; let device: Int; let bulk: Int }
    static let usual = Limits(automatic: automaticPerMinute, device: devicePerMinute, bulk: bulkPerMinute)
    static let afterRateLimit = Limits(automatic: automaticAfterRateLimit, device: deviceAfterRateLimit, bulk: bulkAfterRateLimit)

    private func limitsLocked(at now: Date) -> Limits {
        if let slowerUntil, now < slowerUntil { return Self.afterRateLimit }
        return Self.usual
    }

    /// The numbers in force now.
    func limits(at now: Date = Date()) -> Limits {
        lock.lock(); defer { lock.unlock() }
        return limitsLocked(at: now)
    }

    init() {}

    /// Takes one place now, or says when to ask again. Nothing is sent
    /// unless this returns `.send`.
    func decide(personAction: Bool, bulk: Bool = false, at now: Date = Date()) -> Decision {
        lock.lock(); defer { lock.unlock() }
        if !personAction, let pausedUntil, now < pausedUntil { return .held }
        let limits = limitsLocked(at: now)
        let deviceLimit = personAction && bulk ? limits.bulk : limits.device
        var free = Self.freeAt(all, limit: deviceLimit, now: now)
        if !personAction { free = [free, Self.freeAt(automatic, limit: limits.automatic, now: now)].compactMap { $0 }.max() }
        if let free { return .wait(until: free) }
        if !personAction { automatic.record(at: now) }
        all.record(at: now)
        admitted += 1
        return .send
    }

    /// When a window holding `limit` calls has room again (nil: now).
    private static func freeAt(_ window: SharingCallWindow, limit: Int, now: Date) -> Date? {
        let recent = window.times.filter { now.timeIntervalSince($0) < window.seconds }.sorted()
        guard recent.count >= limit else { return nil }
        return recent[recent.count - limit].addingTimeInterval(window.seconds)
    }

    /// `now` is when the 429 came back.
    func noteRateLimited(retryAfter: TimeInterval? = nil, at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let until = now.addingTimeInterval(max(Self.rateLimitedPause, retryAfter ?? 0))
        pausedUntil = max(pausedUntil ?? until, until)
        let slower = pausedUntil!.addingTimeInterval(Self.slowerAfterRateLimit)
        slowerUntil = max(slowerUntil ?? slower, slower)
    }

    /// When an automatic call may go again (nil: now).
    func nextAutomatic(at now: Date = Date()) -> Date? {
        lock.lock(); defer { lock.unlock() }
        var next: Date?
        if let pausedUntil, now < pausedUntil { next = pausedUntil }
        let limits = limitsLocked(at: now)
        for free in [Self.freeAt(automatic, limit: limits.automatic, now: now),
                     Self.freeAt(all, limit: limits.device, now: now)].compactMap({ $0 }) {
            next = max(next ?? free, free)
        }
        return next
    }

    /// Calls let through so far (never decreases): a pass that moved nothing.
    var admittedCalls: Int { lock.lock(); defer { lock.unlock() }; return admitted }

    func automaticCalls(at now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        return automatic.count(at: now)
    }

    func allCalls(at now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        return all.count(at: now)
    }

    /// The gate itself: returns when the call may be sent, waiting for a free
    /// place; throws `PreservationCallHeld` (nothing sent) for an automatic
    /// call during the pause after a 429.
    static func admit(_ budget: PreservationCallBudget, personAction: Bool = SharingAutoCallBudget.isPersonAction,
                      bulk: Bool = PreservationCallBudget.isBulkRead,
                      now: () -> Date = { Date() },
                      sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async throws {
        while true {
            try Task.checkCancellation()
            switch budget.decide(personAction: personAction, bulk: bulk, at: now()) {
            case .send: return
            case .held: throw PreservationCallHeld()
            case .wait(let until): try await sleep(max(0.05, until.timeIntervalSince(now())))
            }
        }
    }
}

/// 1115v-4: the next automatic save after one that ended on RATE_LIMITED. The
/// unsent work stays where it is (the binding's pending snapshot and its sent
/// receipts); only when to try again is decided here. It moved something:
/// again as soon as the gate opens. It moved nothing: 10, 20, 40, then every
/// 60 s, and never before the gate opens.
enum PreservationRetrySchedule {
    static let quietBackoff: [TimeInterval] = [10, 20, 40, 60]

    /// `quietPasses`: passes in a row, this one included, that sent nothing.
    static func next(now: Date, progressed: Bool, quietPasses: Int, opensAt: Date?) -> Date {
        let delay = progressed ? 0 : quietBackoff[min(max(quietPasses, 1), quietBackoff.count) - 1]
        let planned = now.addingTimeInterval(delay)
        guard let opensAt else { return planned }
        return max(planned, opensAt)
    }
}

/// An automatic call to the automatic-save server the gate held back after a
/// 429. Nothing was sent; the client answers it as the server's RATE_LIMITED.
struct PreservationCallHeld: Error, Sendable {}

/// The person's own restore or export: its reads may use 20 places a minute
/// on this iPhone. Marks the person's action too.
enum PreservationBulkRead {
    static func run<T>(_ work: () async throws -> T) async rethrows -> T {
        try await PreservationCallBudget.$isBulkRead.withValue(true) {
            try await SharingPersonAction.run(work)
        }
    }
}
