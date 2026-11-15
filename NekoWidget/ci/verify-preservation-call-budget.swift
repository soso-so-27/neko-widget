import Foundation

// 11/15 (1115v-4, 1115w): the automatic-save server allows 30 authenticated
// calls per owner in each fixed UTC minute (OwnerRequestLimiter), shared by
// the owner's iPhones. This drives the app's own gate (PreservationCallBudget)
// and its retry schedule (PreservationRetrySchedule) on a synthetic clock,
// against a synthetic server with that limit, and counts. The same save
// without the gate (as before 11/15) is counted for comparison.

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ message: String) throws {
    if !value { FileHandle.standardError.write(Data(("Preservation call budget check failed: " + message + "\n").utf8)); throw Failure.check(message) }
}
private func at(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }  // stored exactly: no rounding at the window edge

/// The most calls in any 60 seconds.
private func maxPerMinute(_ times: [Double]) -> Int {
    let sorted = times.sorted(); var best = 0, start = 0
    for end in sorted.indices {
        while sorted[end] - sorted[start] >= 60 { start += 1 }
        best = max(best, end - start + 1)
    }
    return best
}

/// OwnerRequestLimiter: 30 per owner per fixed UTC minute; a refused attempt
/// gets 429 with Retry-After until the next minute (1...60 s).
private final class OwnerServer {
    static let latency = 0.4
    var perMinute: [Int: Int] = [:]
    var refused: [(device: String, reply: Double)] = []
    var received: [String: [Int]] = [:]   // device: item ids in arrival order
    /// Returns nil when admitted, else Retry-After seconds.
    func attempt(at t: Double, device: String) -> Double? {
        let minute = Int(floor(t / 60))
        let count = perMinute[minute, default: 0]
        guard count < 30 else {
            refused.append((device, t + Self.latency))
            return max(1, min(60, ceil(Double(minute + 1) * 60 - t)))
        }
        perMinute[minute] = count + 1
        return nil
    }
}

/// One iPhone: its own gate, and the times it sent.
private final class Phone {
    let name: String
    let budget = PreservationCallBudget()
    var sends: [(t: Double, person: Bool)] = []
    init(_ name: String) { self.name = name }
    var all: [Double] { sends.map(\.t) }
    var automatic: [Double] { sends.filter { !$0.person }.map(\.t) }
}

private protocol Worker: AnyObject {
    var nextAt: Double? { get }
    func step(at now: Double, server: OwnerServer)
}

private enum Outcome { case sent, waiting, held, rateLimited(Double) }
/// One call through the app's gate (`decide` is what `PreservationCallBudget.admit`
/// loops on), or straight to the server when `gated` is false (before 11/15).
private func send(_ phone: Phone, person: Bool, bulk: Bool, gated: Bool = true, at now: Double, server: OwnerServer) -> (Outcome, Double) {
    if gated {
        switch phone.budget.decide(personAction: person, bulk: bulk, at: at(now)) {
        case .held: return (.held, now)
        // As PreservationCallBudget.admit: at least 0.05 s, so a place that frees
        // only by floating-point rounding at the 60 s edge cannot stall the clock.
        case .wait(let until): return (.waiting, max(now + 0.05, until.timeIntervalSinceReferenceDate))
        case .send: break
        }
    }
    phone.sends.append((now, person))
    let reply = now + OwnerServer.latency
    if let retryAfter = server.attempt(at: now, device: phone.name) {
        // ManagedPreservationClient.request notes every 429 when the reply comes.
        if gated { phone.budget.noteRateLimited(retryAfter: retryAfter, at: at(reply)) }
        return (.rateLimited(retryAfter), reply)
    }
    return (.sent, reply)
}

/// The automatic save as AppRecordPersistence runs it: a pass reads usage and
/// the head, sends each unsent part in order (ToolBackupTransfer.upload; each
/// PUT inside waitingForRateLimit: one 60 s wait and one retry after a 429),
/// then writes the head. A part counts as sent only after its 200; an
/// interrupted pass keeps the rest for the next one.
private final class AutoSave: Worker {
    let phone: Phone, gated: Bool
    var pending: [Int]
    var nextAt: Double?
    private var plan: [Int] = []          // -1 usage/head read, -2 head write, >= 0 a part
    private var progressed = false, retried = false, quiet = 0, transientFailures = 0
    var finishedAt: Double?
    /// Seconds spent waiting because of a 429 (its retry wait, or the next pass).
    var stoppedBy429 = 0.0
    init(_ phone: Phone, items: Int, from start: Double = 0, gated: Bool = true) {
        self.phone = phone; self.gated = gated; pending = Array(0..<items); nextAt = start
    }
    private func beginPass() { plan = [-1, -1] + pending + [-2]; progressed = false; retried = false }
    private func endPass(rateLimitedAt now: Double) {
        if gated {
            // AppRecordPersistence.report: RATE_LIMITED.
            quiet = progressed ? 0 : quiet + 1
            nextAt = PreservationRetrySchedule.next(now: at(now), progressed: progressed, quietPasses: quiet,
                                                    opensAt: phone.budget.nextAutomatic(at: at(now))).timeIntervalSinceReferenceDate
        } else {
            // Before 11/15: a connection failure, 5, 15, then 60 s.
            transientFailures += 1
            nextAt = now + (transientFailures == 1 ? 5 : transientFailures == 2 ? 15 : 60)
        }
        nextAt = ceil(nextAt!)   // the 1 s loop
        stoppedBy429 += nextAt! - now
        plan = []
    }
    func step(at now: Double, server: OwnerServer) {
        if plan.isEmpty { beginPass() }
        let call = plan[0]
        let (outcome, time) = send(phone, person: false, bulk: false, gated: gated, at: now, server: server)
        switch outcome {
        case .waiting: nextAt = time
        case .held: endPass(rateLimitedAt: time)
        case .rateLimited:
            progressed = true
            if call >= 0 && !retried { retried = true; nextAt = time + 60; stoppedBy429 += 60 }   // waitingForRateLimit
            else { endPass(rateLimitedAt: time) }
        case .sent:
            progressed = true; retried = false
            plan.removeFirst()
            if call >= 0 { pending.removeAll { $0 == call }; server.received[phone.name, default: []].append(call) }
            if plan.isEmpty {
                if pending.isEmpty { finishedAt = time; nextAt = nil; transientFailures = 0 } else { nextAt = time }
            } else { nextAt = time }
        }
    }
}

/// The person's own reads, one after another (a restore: one record each,
/// one 60 s wait and retry after a 429). Stopped by a second 429, the person
/// starts it again 10 s later (files already read are kept).
private final class PersonReads: Worker {
    let phone: Phone, bulk: Bool
    var left: Int
    var nextAt: Double?
    var finishedAt: Double?
    var interrupted = 0
    private var retried = false
    init(_ phone: Phone, count: Int, bulk: Bool, from start: Double) {
        self.phone = phone; self.bulk = bulk; left = count; nextAt = start
    }
    func step(at now: Double, server: OwnerServer) {
        let (outcome, time) = send(phone, person: true, bulk: bulk, at: now, server: server)
        switch outcome {
        case .waiting: nextAt = time
        case .held: interrupted += 1; nextAt = time + 10
        case .rateLimited(let retryAfter):
            if retried { interrupted += 1; retried = false; nextAt = time + 10 }
            else { retried = true; nextAt = time + max(60, retryAfter) }
        case .sent:
            retried = false; left -= 1
            if left == 0 { finishedAt = time; nextAt = nil } else { nextAt = time }
        }
    }
}

private func run(_ workers: [Worker], server: OwnerServer, until limit: Double = 7 * 86_400) throws {
    while case let (worker, time)? = workers.compactMap({ w in w.nextAt.map { (w, $0) } }).min(by: { $0.1 < $1.1 }) {
        try check(time <= limit, "the work never finished")
        worker.step(at: time, server: server)
    }
}

/// Every part arrived once, in order; nothing was lost.
private func checkDelivered(_ save: AutoSave, items: Int, server: OwnerServer) throws {
    try check(save.pending.isEmpty && save.finishedAt != nil, "\(save.phone.name): \(save.pending.count) parts left unsent")
    try check(server.received[save.phone.name] == Array(0..<items), "\(save.phone.name): parts lost, repeated or out of order")
}

/// Each iPhone within the usual numbers in any 60 s (the lower ones are checked apart).
private func checkWindows(_ phones: [Phone]) throws {
    for phone in phones {
        try check(maxPerMinute(phone.automatic) <= PreservationCallBudget.automaticPerMinute, "\(phone.name): automatic \(maxPerMinute(phone.automatic)) in 60 s")
        try check(maxPerMinute(phone.all) <= max(PreservationCallBudget.devicePerMinute, PreservationCallBudget.bulkPerMinute), "\(phone.name): \(maxPerMinute(phone.all)) calls in 60 s")
    }
}

/// Automatic sends of that iPhone in [from, to).
private func automatic(_ phone: Phone, from: Double, to: Double) -> [Double] { phone.automatic.filter { $0 >= from && $0 < to } }

/// No automatic send from that iPhone for a minute (or Retry-After) after a
/// 429 reply; then, until 10 minutes after that, at most the lower number.
private func checkAfter429(_ phones: [Phone], server: OwnerServer) throws {
    for refusal in server.refused {
        guard let phone = phones.first(where: { $0.name == refusal.device }) else { continue }
        try check(automatic(phone, from: refusal.reply, to: refusal.reply + 60).isEmpty, "\(phone.name): automatic within 60 s of a 429")
        let slower = automatic(phone, from: refusal.reply + 60, to: refusal.reply + 660)
        try check(maxPerMinute(slower) <= PreservationCallBudget.automaticAfterRateLimit, "\(phone.name): automatic \(maxPerMinute(slower)) in 60 s within 10 min of a 429")
    }
}

/// 429 bursts: refusals more than 2 minutes apart start a new one.
private func bursts(_ server: OwnerServer) -> [Double] {
    var starts: [Double] = [], last = -Double.infinity
    for reply in server.refused.map(\.reply).sorted() {
        if reply - last > 120 { starts.append(reply) }
        last = reply
    }
    return starts
}

private func minutes(_ seconds: Double?) -> String { String(format: "%.1f", (seconds ?? .nan) / 60) }

@main
private enum Verify {
    static func main() async throws {
        try gateUnits()
        try await gateLoop()
        try retrySchedule()
        var report: [String] = []

        // (a) One iPhone, 200 and 1,000 parts waiting: with the gate, and as before (no gate).
        for items in [200, 1000] {
            let phone = Phone("A"), server = OwnerServer(), save = AutoSave(phone, items: items)
            try run([save], server: server)
            try checkDelivered(save, items: items, server: server)
            try checkWindows([phone])
            try check(server.refused.isEmpty, "one iPhone: \(server.refused.count) 429")
            let old = Phone("A0"), oldServer = OwnerServer(), oldSave = AutoSave(old, items: items, gated: false)
            try run([oldSave], server: oldServer)
            try checkDelivered(oldSave, items: items, server: oldServer)
            report.append("(a) one iPhone, \(items) parts: \(minutes(save.finishedAt)) min, automatic \(maxPerMinute(phone.automatic)) in 60 s, 0 429 "
                + "(no gate: \(minutes(oldSave.finishedAt)) min, \(oldServer.refused.count) 429, \(minutes(oldSave.stoppedBy429)) min stopped by them)")
        }

        // A first save of 320 calls (2 cats, 300 photo notes, 200 records:
        // 300 photo PUTs, about 15 metadata calls and the pass's own 5).
        do {
            let phone = Phone("F"), server = OwnerServer(), save = AutoSave(phone, items: 320)
            try run([save], server: server)
            try checkDelivered(save, items: 320, server: server)
            report.append("first save of 320 calls: \(minutes(save.finishedAt)) min")
        }

        // (b) Two iPhones of one owner saving 1,000 parts each at once.
        do {
            let b1 = Phone("B1"), b2 = Phone("B2"), server = OwnerServer()
            let save1 = AutoSave(b1, items: 1000), save2 = AutoSave(b2, items: 1000, from: 7)
            let screen = PersonReads(b2, count: 4, bulk: false, from: 300)
            try run([save1, save2, screen], server: server)
            try checkDelivered(save1, items: 1000, server: server); try checkDelivered(save2, items: 1000, server: server)
            try checkWindows([b1, b2]); try checkAfter429([b1, b2], server: server)
            try check(screen.finishedAt != nil, "the person's screen reads never finished")
            let starts = bursts(server)
            let first = starts.first ?? 0
            let calm = (b1.all + b2.all).filter { $0 > first + 60 && $0 < first + 660 }
            report.append("(b) two iPhones, 1,000 parts each at once: \(minutes(save1.finishedAt)) / \(minutes(save2.finishedAt)) min, "
                + "\(server.refused.count) 429 in \(starts.count) bursts (at \(starts.map { minutes($0) }.joined(separator: ", ")) min), "
                + "owner \(maxPerMinute(calm)) a minute in the 10 minutes after the first burst")
        }

        // (c) After a 429: a minute of nothing, 10 minutes at the lower number, then back.
        do {
            let d = Phone("D"), server = OwnerServer(); server.perMinute[0] = 25
            let save = AutoSave(d, items: 1000, from: 1)
            let tap = PersonReads(d, count: 1, bulk: false, from: 20)
            try run([save, tap], server: server)
            try checkDelivered(save, items: 1000, server: server)
            try checkAfter429([d], server: server); try checkWindows([d])
            try check(tap.interrupted == 0 && tap.finishedAt != nil, "429: the person's tap was held")
            let last = server.refused.map(\.reply).max()!
            let back = automatic(d, from: last + 660, to: .infinity)
            try check(maxPerMinute(back) == PreservationCallBudget.automaticPerMinute, "not back to the usual numbers 10 minutes after the 429")
            report.append("(c) 429 at \(String(format: "%.1f", server.refused[0].reply)) s: automatic 0 for 60 s, "
                + "\(maxPerMinute(automatic(d, from: last + 60, to: last + 660))) a minute for 10 min, then \(maxPerMinute(back)); "
                + "1,000 parts in \(minutes(save.finishedAt)) min, \(server.refused.count) 429")
        }

        // (d) The person's restore (300 one-record reads) on C1 while C1 and C2 save.
        do {
            let c1 = Phone("C1"), c2 = Phone("C2"), server = OwnerServer()
            let restore = PersonReads(c1, count: 300, bulk: true, from: 30)
            let saveC1 = AutoSave(c1, items: 200), saveC2 = AutoSave(c2, items: 200, from: 3)
            try run([restore, saveC1, saveC2], server: server)
            try checkDelivered(saveC1, items: 200, server: server); try checkDelivered(saveC2, items: 200, server: server)
            try check(restore.finishedAt != nil, "restore did not finish")
            try checkWindows([c1, c2]); try checkAfter429([c1, c2], server: server)
            let p = Phone("R"), s = OwnerServer(), alone = PersonReads(p, count: 300, bulk: true, from: 0)
            try run([alone], server: s)
            report.append("(d) restore of 300 reads with both iPhones saving: \(minutes(restore.finishedAt! - 30)) min, interrupted \(restore.interrupted) times "
                + "(alone: \(minutes(alone.finishedAt))) min), saves \(minutes(saveC1.finishedAt)) / \(minutes(saveC2.finishedAt)) min, \(server.refused.count) 429")
        }
        print("Preservation call budget: " + report.joined(separator: "; "))
    }

    /// The gate's own numbers.
    static func gateUnits() throws {
        let usual = PreservationCallBudget.usual, slower = PreservationCallBudget.afterRateLimit
        // One iPhone stays under the server's 30; after a 429 two iPhones too,
        // and a restore with the other iPhone's automatic calls.
        try check(max(usual.device, usual.bulk) < 30 && usual.automatic < usual.device, "usual numbers")
        try check(2 * slower.device <= 30 && slower.bulk + slower.automatic <= 30 && slower.automatic < slower.device, "numbers after a 429")
        let gate = PreservationCallBudget()
        for i in 0..<usual.automatic { try check(gate.decide(personAction: false, at: at(50 + Double(i) / 4)) == .send, "automatic \(i + 1) refused") }
        // 59 s and 61 s: counted over any 60 s, not per fixed minute.
        try check(gate.decide(personAction: false, at: at(61)) == .wait(until: at(110)), "automatic over the usual number not held to the first free place")
        for i in 0..<(usual.device - usual.automatic) { try check(gate.decide(personAction: true, at: at(61 + Double(i) / 4)) == .send, "tap \(i + 1) waited behind automatic") }
        try check(gate.decide(personAction: true, at: at(63)) == .wait(until: at(110)), "tap over the iPhone's number sent")
        try check(gate.decide(personAction: false, at: at(110)) == .send, "automatic not sent once a place freed")
        // A 429: automatic held for 60 s from the reply (or Retry-After), taps
        // not; then the lower numbers for 10 minutes.
        let paused = PreservationCallBudget()
        paused.noteRateLimited(retryAfter: 12, at: at(1000))
        try check(paused.decide(personAction: false, at: at(1059.9)) == .held, "automatic sent within 60 s of a 429")
        try check(paused.decide(personAction: true, at: at(1001)) == .send, "tap held after a 429")
        try check(paused.limits(at: at(1060)) == slower && paused.limits(at: at(1659.9)) == slower && paused.limits(at: at(1660)) == usual, "10 minutes at the lower numbers")
        for i in 0..<slower.automatic { try check(paused.decide(personAction: false, at: at(1062 + Double(i) / 4)) == .send, "automatic after the pause \(i + 1)") }
        try check(paused.decide(personAction: false, at: at(1070)) == .wait(until: at(1122)), "automatic over the lower number sent")
        for i in 0..<(slower.bulk - slower.automatic) { try check(paused.decide(personAction: true, bulk: true, at: at(1070 + Double(i) / 4)) == .send, "restore read \(i + 1) held") }
        try check(paused.decide(personAction: true, bulk: true, at: at(1073)) == .wait(until: at(1122)), "restore read over the lower restore number sent")
        paused.noteRateLimited(retryAfter: 90, at: at(2000))
        try check(paused.decide(personAction: false, at: at(2089)) == .held && paused.decide(personAction: false, at: at(2090)) == .send, "Retry-After over 60 s not kept")
        try check(paused.limits(at: at(2689)) == slower && paused.limits(at: at(2690)) == usual, "the lower numbers from the end of the longer pause")
        try check(paused.nextAutomatic(at: at(3000)) == nil, "nextAutomatic when open")
    }

    /// `PreservationCallBudget.admit`, the loop the client awaits, with a synthetic sleep.
    static func gateLoop() async throws {
        let gate = PreservationCallBudget()
        final class Clock: @unchecked Sendable { var t = 0.0 }
        let clock = Clock()
        var sent: [Double] = []
        let count = 2 * PreservationCallBudget.automaticPerMinute + 5
        for _ in 0..<count {
            try await PreservationCallBudget.admit(gate, personAction: false, bulk: false, now: { at(clock.t) },
                                                   sleep: { clock.t += $0 })
            sent.append(clock.t); clock.t += 0.5
        }
        try check(maxPerMinute(sent) == PreservationCallBudget.automaticPerMinute && sent.last! >= 120, "admit: \(count) automatic calls in \(sent.last!) s, \(maxPerMinute(sent)) in 60 s")
        gate.noteRateLimited(at: at(clock.t))
        var held = false
        do { try await PreservationCallBudget.admit(gate, personAction: false, bulk: false, now: { at(clock.t) }, sleep: { clock.t += $0 }) }
        catch is PreservationCallHeld { held = true }
        try check(held, "admit: automatic call sent after a 429")
        try await PreservationCallBudget.admit(gate, personAction: true, bulk: false, now: { at(clock.t) }, sleep: { clock.t += $0 })
        // Unmarked is automatic: the default reads the person's mark.
        try check(!SharingAutoCallBudget.isPersonAction && !PreservationCallBudget.isBulkRead, "unmarked is not automatic")
        let marked = await PreservationBulkRead.run { SharingAutoCallBudget.isPersonAction && PreservationCallBudget.isBulkRead }
        try check(marked, "PreservationBulkRead does not mark the person's action")
    }

    static func retrySchedule() throws {
        let now = at(500)
        try check(PreservationRetrySchedule.next(now: now, progressed: true, quietPasses: 0, opensAt: nil) == now, "progressed: not at once")
        try check(PreservationRetrySchedule.next(now: now, progressed: true, quietPasses: 0, opensAt: at(530)) == at(530), "progressed: before the gate opens")
        let quiet = (1...6).map { PreservationRetrySchedule.next(now: now, progressed: false, quietPasses: $0, opensAt: nil).timeIntervalSince(now) }
        try check(quiet == [10, 20, 40, 60, 60, 60], "quiet passes: \(quiet)")
        try check(PreservationRetrySchedule.next(now: now, progressed: false, quietPasses: 1, opensAt: at(555)) == at(555), "quiet: before the pause ends")
    }
}
