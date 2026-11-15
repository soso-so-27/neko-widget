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

    static var waitsOnOthers: TimeInterval { keyBackoff.last! }
    /// The app came to the front or a screen opened: not sooner than this
    /// after the last pass (a burst of openings is one pass).
    static let wakeGap: TimeInterval = 20
    /// After the person's own operation (a join, an approval): keys follow fast.
    static let nudgeGap: TimeInterval = 5

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
    /// Automatic tries need fewer than this many of each in the last 60 s.
    static let automaticCeiling = 5
    static let rateLimitedPause: TimeInterval = 60

    static func allowsAutomaticCheck(transactions: Int, entitlements: Int) -> Bool {
        transactions < automaticCeiling && entitlements < automaticCeiling
    }
}
