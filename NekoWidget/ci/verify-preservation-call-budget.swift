import Foundation

// 11/15 (1115v-4, 1115w): the automatic-save server allows 30 authenticated
// calls per owner in each fixed UTC minute (OwnerRequestLimiter), shared by
// the owner's iPhones. This drives the app's own gate (PreservationCallBudget)
// and its retry schedule (PreservationRetrySchedule) on a synthetic clock,
// against a synthetic server with that limit, and counts.

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ message: String) throws {
    if !value { FileHandle.standardError.write(Data(("Preservation call budget check failed: " + message + "\n").utf8)); throw Failure.check(message) }
}
private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

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
/// One call through the app's gate (`decide` is what `PreservationCallBudget.admit` loops on).
private func send(_ phone: Phone, person: Bool, bulk: Bool, at now: Double, server: OwnerServer) -> (Outcome, Double) {
    switch phone.budget.decide(personAction: person, bulk: bulk, at: at(now)) {
    case .held: return (.held, now)
    case .wait(let until): return (.waiting, until.timeIntervalSince1970)
    case .send:
        phone.sends.append((now, person))
        let reply = now + OwnerServer.latency
        if let retryAfter = server.attempt(at: now, device: phone.name) {
            // ManagedPreservationClient.request notes every 429 when the reply comes.
            phone.budget.noteRateLimited(retryAfter: retryAfter, at: at(reply))
            return (.rateLimited(retryAfter), reply)
        }
        return (.sent, reply)
    }
}

/// The automatic save as AppRecordPersistence runs it: a pass reads usage and
/// the head, sends each unsent part in order (ToolBackupTransfer.upload; each
/// PUT inside waitingForRateLimit: one 60 s wait and one retry after a 429),
/// then writes the head. A part counts as sent only after its 200; an
/// interrupted pass keeps the rest for the next one.
private final class AutoSave: Worker {
    let phone: Phone
    var pending: [Int]
    var nextAt: Double?
    private var plan: [Int] = []          // -1 usage/head read, -2 head write, >= 0 a part
    private var progressed = false, retried = false, quiet = 0
    var finishedAt: Double?
    var passes = 0
    init(_ phone: Phone, items: Int, from start: Double = 0) {
        self.phone = phone; pending = Array(0..<items); nextAt = start
    }
    private func beginPass() { plan = [-1, -1] + pending + [-2]; progressed = false; retried = false; passes += 1 }
    private func endPass(rateLimitedAt now: Double) {
        // AppRecordPersistence.report: RATE_LIMITED.
        quiet = progressed ? 0 : quiet + 1
        nextAt = PreservationRetrySchedule.next(now: at(now), progressed: progressed, quietPasses: quiet,
                                                opensAt: phone.budget.nextAutomatic(at: at(now))).timeIntervalSince1970
        nextAt = ceil(nextAt!)   // the 1 s loop
        plan = []
    }
    func step(at now: Double, server: OwnerServer) {
        if plan.isEmpty { beginPass() }
        let call = plan[0]
        let (outcome, time) = send(phone, person: false, bulk: false, at: now, server: server)
        switch outcome {
        case .waiting: nextAt = time
        case .held: endPass(rateLimitedAt: time)
        case .rateLimited:
            progressed = true
            if call >= 0 && !retried { retried = true; nextAt = time + 60 }   // waitingForRateLimit
            else { endPass(rateLimitedAt: time) }
        case .sent:
            progressed = true; retried = false
            plan.removeFirst()
            if call >= 0 { pending.removeAll { $0 == call }; server.received[phone.name, default: []].append(call) }
            if plan.isEmpty {
                if pending.isEmpty { finishedAt = time; nextAt = nil } else { nextAt = time }
            } else { nextAt = time }
        }
    }
}

/// The person's own reads, one after another (a restore: one record each).
private final class PersonReads: Worker {
    let phone: Phone, bulk: Bool
    var left: Int
    var nextAt: Double?
    var finishedAt: Double?
    var failed = 0
    private var retried = false
    init(_ phone: Phone, count: Int, bulk: Bool, from start: Double) {
        self.phone = phone; self.bulk = bulk; left = count; nextAt = start
    }
    func step(at now: Double, server: OwnerServer) {
        let (outcome, time) = send(phone, person: true, bulk: bulk, at: now, server: server)
        switch outcome {
        case .waiting: nextAt = time
        case .held: failed += 1; nextAt = nil
        case .rateLimited(let retryAfter):
            if retried { failed += 1; nextAt = nil } else { retried = true; nextAt = time + max(60, retryAfter) }
        case .sent:
            retried = false; left -= 1
            if left == 0 { finishedAt = time; nextAt = nil } else { nextAt = time }
        }
    }
}

private func run(_ workers: [Worker], server: OwnerServer, until limit: Double = 86_400) throws {
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

private func checkWindows(_ phones: [Phone], device: Int, server: OwnerServer, refusals: Int = 0) throws {
    for phone in phones {
        try check(maxPerMinute(phone.automatic) <= PreservationCallBudget.automaticPerMinute, "\(phone.name): automatic \(maxPerMinute(phone.automatic)) in 60 s")
        try check(maxPerMinute(phone.all) <= device, "\(phone.name): \(maxPerMinute(phone.all)) calls in 60 s")
    }
    let owner = phones.flatMap(\.all)
    try check(maxPerMinute(owner) <= 30, "owner: \(maxPerMinute(owner)) calls in 60 s")
    try check(server.refused.count == refusals, "owner: \(server.refused.count) calls refused by the server")
}

/// No automatic send from that iPhone for a minute (or Retry-After) after a 429 reply.
private func checkQuietAfter429(_ phones: [Phone], server: OwnerServer) throws -> Int {
    var quietSends = 0
    for refusal in server.refused {
        guard let phone = phones.first(where: { $0.name == refusal.device }) else { continue }
        quietSends += phone.automatic.filter { $0 >= refusal.reply && $0 < refusal.reply + 60 }.count
    }
    return quietSends
}

@main
private enum Verify {
    static func main() async throws {
        try gateUnits()
        try await gateLoop()
        try retrySchedule()

        // (a) 200 parts waiting on one iPhone.
        let a = Phone("A"), serverA = OwnerServer(), saveA = AutoSave(a, items: 200)
        try run([saveA], server: serverA)
        try checkDelivered(saveA, items: 200, server: serverA)
        try checkWindows([a], device: PreservationCallBudget.devicePerMinute, server: serverA)

        // (b) Two iPhones of one owner, 200 parts each, and the person opening
        // the save screen on B (4 reads) in the middle.
        let b1 = Phone("B1"), b2 = Phone("B2"), serverB = OwnerServer()
        let save1 = AutoSave(b1, items: 200), save2 = AutoSave(b2, items: 200, from: 7)
        let screen = PersonReads(b2, count: 4, bulk: false, from: 300)
        try run([save1, save2, screen], server: serverB)
        try checkDelivered(save1, items: 200, server: serverB); try checkDelivered(save2, items: 200, server: serverB)
        try check(screen.failed == 0 && screen.finishedAt.map { $0 - 300 < 10 } == true, "the person's screen reads waited behind automatic saving")
        try checkWindows([b1, b2], device: PreservationCallBudget.devicePerMinute, server: serverB)

        // (c) The person's restore (300 one-record reads) on C1 while C1 and
        // C2 save automatically.
        let c1 = Phone("C1"), c2 = Phone("C2"), serverC = OwnerServer()
        let restore = PersonReads(c1, count: 300, bulk: true, from: 30)
        let saveC1 = AutoSave(c1, items: 200), saveC2 = AutoSave(c2, items: 200, from: 3)
        try run([restore, saveC1, saveC2], server: serverC)
        try checkDelivered(saveC1, items: 200, server: serverC); try checkDelivered(saveC2, items: 200, server: serverC)
        try check(restore.failed == 0, "restore failed")
        try checkWindows([c1, c2], device: PreservationCallBudget.bulkPerMinute, server: serverC)
        let restoreMinutes = (restore.finishedAt! - 30) / 60
        // The same restore alone, at 14 (no restore window) and at 20.
        func alone(bulk: Bool) throws -> Double {
            let p = Phone("R"), s = OwnerServer(), r = PersonReads(p, count: 300, bulk: bulk, from: 0)
            try run([r], server: s)
            return r.finishedAt! / 60
        }
        let alone14 = try alone(bulk: false), alone20 = try alone(bulk: true)

        // (d) Right after a 429: other work had already used 25 of this minute.
        let d = Phone("D"), serverD = OwnerServer(); serverD.perMinute[0] = 25
        let saveD = AutoSave(d, items: 200, from: 1)
        let tap = PersonReads(d, count: 1, bulk: false, from: 20)
        try run([saveD, tap], server: serverD)
        try checkDelivered(saveD, items: 200, server: serverD)
        try check(serverD.refused.count >= 1, "429 scenario: no 429 came")
        let afterRateLimit = try checkQuietAfter429([d], server: serverD)
        try check(afterRateLimit == 0, "429: \(afterRateLimit) automatic calls within 60 s of it")
        try check(tap.failed == 0, "429: the person's tap was held")
        try check(maxPerMinute(d.automatic) <= PreservationCallBudget.automaticPerMinute, "429: automatic over the budget")
        for scenario in [serverA, serverB, serverC] { try check(try checkQuietAfter429([a, b1, b2, c1, c2], server: scenario) == 0, "quiet") }

        func minutes(_ s: AutoSave) -> String { String(format: "%.1f", s.finishedAt! / 60) }
        print("Preservation call budget (most calls in any 60 s): (a) 200 waiting parts, one iPhone: automatic \(maxPerMinute(a.automatic)), "
            + "all sent in order in \(minutes(saveA)) min, \(serverA.refused.count) 429; "
            + "(b) two iPhones of one owner: \(maxPerMinute(b1.all)) + \(maxPerMinute(b2.all)), owner \(maxPerMinute(b1.all + b2.all)), "
            + "both done in \(minutes(save1)) / \(minutes(save2)) min, \(serverB.refused.count) 429; "
            + "(c) restore of 300 reads with both saving: C1 \(maxPerMinute(c1.all)) (automatic \(maxPerMinute(c1.automatic))), C2 \(maxPerMinute(c2.all)), "
            + "owner \(maxPerMinute(c1.all + c2.all)), restore \(String(format: "%.1f", restoreMinutes)) min "
            + "(alone: \(String(format: "%.1f", alone20)) min at \(PreservationCallBudget.bulkPerMinute), \(String(format: "%.1f", alone14)) min at \(PreservationCallBudget.devicePerMinute)), "
            + "saves \(minutes(saveC1)) / \(minutes(saveC2)) min, \(serverC.refused.count) 429; "
            + "(d) 429 at \(String(format: "%.1f", serverD.refused[0].reply)) s: automatic within 60 s \(afterRateLimit), tap sent, "
            + "all 200 sent in order in \(minutes(saveD)) min")
    }

    /// The gate's own numbers.
    static func gateUnits() throws {
        let gate = PreservationCallBudget()
        for i in 0..<10 { try check(gate.decide(personAction: false, at: at(50 + Double(i))) == .send, "automatic \(i + 1) refused") }
        // 59 s and 61 s: a fixed-minute count would allow 10 more at 61 s.
        try check(gate.decide(personAction: false, at: at(61)) == .wait(until: at(110)), "automatic 11 within 60 s not held to the first free place")
        for i in 0..<4 { try check(gate.decide(personAction: true, at: at(61 + Double(i))) == .send, "tap \(i + 1) waited behind automatic") }
        try check(gate.decide(personAction: true, at: at(66)) == .wait(until: at(110)), "tap 15 within 60 s sent")
        for i in 0..<6 { try check(gate.decide(personAction: true, bulk: true, at: at(66 + Double(i))) == .send, "restore read \(i + 15) held") }
        try check(gate.decide(personAction: true, bulk: true, at: at(72)) == .wait(until: at(110)), "restore read 21 within 60 s sent")
        // At 110 the first call leaves the window: the restore may take its
        // place, automatic still waits while the iPhone holds 14 or more.
        try check(gate.decide(personAction: true, bulk: true, at: at(110)) == .send, "restore read not sent once a place freed")
        try check(gate.decide(personAction: false, at: at(110)) == .wait(until: at(117)), "automatic sent while the restore holds the iPhone")
        try check(gate.allCalls(at: at(110)) == PreservationCallBudget.bulkPerMinute, "window")
        // A 429: automatic held for 60 s from the reply (or Retry-After), taps not.
        let paused = PreservationCallBudget()
        paused.noteRateLimited(retryAfter: 12, at: at(1000))
        try check(paused.decide(personAction: false, at: at(1059.9)) == .held, "automatic sent within 60 s of a 429")
        try check(paused.decide(personAction: true, at: at(1001)) == .send, "tap held after a 429")
        try check(paused.decide(personAction: false, at: at(1060)) == .send, "automatic still held after the pause")
        paused.noteRateLimited(retryAfter: 90, at: at(2000))
        try check(paused.decide(personAction: false, at: at(2089)) == .held && paused.decide(personAction: false, at: at(2090)) == .send, "Retry-After over 60 s not kept")
        try check(paused.nextAutomatic(at: at(3000)) == nil, "nextAutomatic when open")
    }

    /// `PreservationCallBudget.admit`, the loop the client awaits, with a synthetic sleep.
    static func gateLoop() async throws {
        let gate = PreservationCallBudget()
        final class Clock: @unchecked Sendable { var t = 0.0 }
        let clock = Clock()
        var sent: [Double] = []
        for _ in 0..<25 {
            try await PreservationCallBudget.admit(gate, personAction: false, bulk: false, now: { at(clock.t) },
                                                   sleep: { clock.t += $0 })
            sent.append(clock.t); clock.t += 0.5
        }
        try check(maxPerMinute(sent) == 10 && sent.last! >= 120, "admit: 25 automatic calls in \(sent.last!) s, \(maxPerMinute(sent)) in 60 s")
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
