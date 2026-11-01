import Foundation

@MainActor
private final class Grant {
    var begins = 0
    var ends: [Int] = []
    var callbacks: [@MainActor @Sendable () -> Void] = []
    var available = true
    var immediateExpiry = false
    func begin(_ expire: @escaping @MainActor @Sendable () -> Void) -> Int? {
        begins += 1; callbacks.append(expire)
        if immediateExpiry { expire() }
        return available ? begins : nil
    }
    func make() -> AppRecordSaveLifetime {
        AppRecordSaveLifetime(begin: { [self] in begin($0) }, end: { [self] in ends.append($0) })
    }
}

@MainActor
private final class Work {
    var starts = 0
    var cancellations = 0
    var release = false
    var unwind = false
    func save() async {
        starts += 1
        while !release && !Task.isCancelled { await Task.yield() }
        if Task.isCancelled {
            cancellations += 1
            // Simulate a URLSession callback arriving after foreground return.
            while !unwind { await Task.yield() }
        }
    }
}

@main
struct SaveLifetimeCheck {
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<100_000 {
            if condition() { return }
            await Task.yield()
        }
        fatalError("save lifetime did not reach the expected state")
    }

    @MainActor static func main() async {
        let grant = Grant(), work = Work()
        let lifetime = grant.make()
        lifetime.setForeground(false)
        await lifetime.run { await work.save() }
        precondition(work.starts == 0 && grant.begins == 0, "no new background save")
        lifetime.setForeground(true)
        let caller = Task { await lifetime.run { await work.save() } }
        await until { work.starts == 1 }
        lifetime.setForeground(false)
        caller.cancel() // Disappearing UI / cancelled timer must not own the save.
        lifetime.setForeground(false)
        precondition(grant.begins == 1 && work.cancellations == 0)
        work.release = true
        await caller.value
        precondition(grant.ends == [1] && work.cancellations == 0)
        grant.callbacks[0]() // Late expiry cannot touch a later save.

        lifetime.setForeground(true)
        work.release = false
        let manualRetry = Task { await lifetime.run { await work.save() } }
        await until { work.starts == 2 }
        lifetime.setForeground(false)
        grant.callbacks[1]()
        await until { work.cancellations == 1 }
        lifetime.setForeground(true)
        let foreground = Task { await lifetime.run { await work.save() } }
        let simultaneousRetry = Task { await lifetime.run { await work.save() } }
        for _ in 0..<10 { await Task.yield() }
        precondition(work.starts == 2, "do not overlap cancelled work")
        work.unwind = true
        await until { work.starts == 3 }
        grant.callbacks[1]()
        for _ in 0..<10 { await Task.yield() }
        precondition(work.cancellations == 1 && work.starts == 3,
            "old expiry and simultaneous waiters cannot replace the resumed task")
        work.release = true
        await manualRetry.value; await foreground.value; await simultaneousRetry.value
        precondition(grant.ends == [1, 2])

        for synchronous in [false, true] {
            let g = Grant(), w = Work()
            g.available = synchronous; g.immediateExpiry = synchronous
            let l = g.make()
            let t = Task { await l.run { await w.save() } }
            await until { w.starts == 1 }
            l.setForeground(false)
            await until { w.cancellations == 1 }
            w.unwind = true
            await t.value
            precondition(g.ends == (synchronous ? [1] : []))
        }

        let w = Work(), l = grant.make()
        let t = Task { await l.run { await w.save() } }
        await until { w.starts == 1 }
        l.setForeground(false); l.setForeground(true)
        let joined = Task { await l.run { await w.save() } }
        for _ in 0..<10 { await Task.yield() }
        precondition(w.starts == 1 && w.cancellations == 0)
        w.release = true
        await t.value; await joined.value
        print("PASS: idle background, completion, timer/UI cancellation, expiry, immediate resume, stale expiry, denied grant, overlapping callers")
    }
}
