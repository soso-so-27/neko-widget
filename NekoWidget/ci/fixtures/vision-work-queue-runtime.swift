// Tests of the actual extracted production queue; no Photos/Vision/permission fixtures.
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ value: Bool, _ message: String) throws {
    if !value { throw TestFailure(message) }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class WorkCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var peak = 0
    private var started = 0
    private var exited = 0
    func enter() {
        lock.lock()
        running += 1
        peak = max(peak, running)
        started += 1
        lock.unlock()
    }
    func leave() {
        lock.lock(); running -= 1; exited += 1; lock.unlock()
    }
    func read() -> (running: Int, peak: Int, started: Int, exited: Int) {
        lock.lock(); defer { lock.unlock() }
        return (running, peak, started, exited)
    }
}

/// This finite synchronous wait is used ONLY by OperationQueue job closures,
/// representing an opaque Vision call. No Swift Task waits on a semaphore.
private final class OpaqueGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var opened = false
    func wait() throws {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(12)
        while !opened {
            if !condition.wait(until: deadline), !opened {
                throw TestFailure("opaque fixture gate deadline")
            }
        }
    }
    func open() {
        condition.lock(); opened = true; condition.broadcast(); condition.unlock()
    }
}

private func eventually(
    _ name: String, timeout: Double = 5,
    _ predicate: @Sendable () -> Bool
) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !predicate() {
        if ProcessInfo.processInfo.systemUptime >= deadline {
            throw TestFailure("deadline: \(name)")
        }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

private actor RegistrationGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private func requireCancellation(_ task: Task<Int, Error>) async throws {
    do {
        _ = try await task.value
        throw TestFailure("expected CancellationError")
    } catch is CancellationError {
        return
    }
}

private func testQueueLimit(_ width: Int) async throws {
    let queue = BlockingVisionWorkQueue(maximumConcurrentJobs: width)
    let gate = OpaqueGate()
    defer { gate.open() }
    let counts = WorkCounts()
    let done = Counter()
    let jobs = (0..<(width * 3)).map { index in
        Task<Int, Error> {
            defer { done.increment() }
            return try await queue.perform {
                try require(queue.isExecutingOnOwnedQueue, "job escaped owned OperationQueue")
                counts.enter()
                defer { counts.leave() }
                try gate.wait()
                return index
            }
        }
    }
    try await eventually("queue reaches configured width") { counts.read().running == width }
    try require(counts.read().peak == width, "configured width was not exercised")
    gate.open()
    try await eventually("queue limit tasks finish") { done.read() == jobs.count }
    var values = Set<Int>()
    for job in jobs { values.insert(try await job.value) }
    try require(values.count == jobs.count, "completion values lost/duplicated")
    try require(counts.read().peak <= width && counts.read().running == 0, "queue exceeded bound")
}

private final class ImageLifetime: @unchecked Sendable {
    let released: Counter
    init(_ released: Counter) { self.released = released }
    deinit { released.increment() }
}

private func capturedImageTask(
    _ queue: BlockingVisionWorkQueue, image: ImageLifetime,
    ran: Counter, done: Counter
) -> Task<Int, Error> {
    let work: @Sendable () throws -> Int = { [image] in
        withExtendedLifetime(image) { ran.increment(); return 77 }
    }
    return Task {
        defer { done.increment() }
        return try await queue.perform(work)
    }
}

private func testQueuedCancellationReleasesImage() async throws {
    let queue = BlockingVisionWorkQueue(maximumConcurrentJobs: 2)
    let gate = OpaqueGate()
    defer { gate.open() }
    let started = Counter()
    let blockers = (0..<2).map { _ in Task<Int, Error> {
        try await queue.perform { started.increment(); try gate.wait(); return 1 }
    } }
    try await eventually("two opaque jobs running") { started.read() == 2 }
    let released = Counter(), ran = Counter(), done = Counter()
    var image: ImageLifetime? = ImageLifetime(released)
    let queued = capturedImageTask(queue, image: image!, ran: ran, done: done)
    image = nil
    try await eventually("image job queued") { queue.unfinishedOperationCount >= 3 }
    queued.cancel()
    queued.cancel() // duplicate cancellation must not double-resume.
    try await eventually("queued cancel returns before opaque jobs finish") { done.read() == 1 }
    try await requireCancellation(queued)
    try await eventually("cancelled image closure released") { released.read() == 1 }
    try require(ran.read() == 0 && started.read() == 2, "cancelled queued body ran")
    gate.open()
    for blocker in blockers { _ = try await blocker.value }
}

private func testAlreadyCancelledBeforeRegistration() async throws {
    let queue = BlockingVisionWorkQueue(maximumConcurrentJobs: 2)
    let registration = RegistrationGate()
    let ran = Counter(), done = Counter()
    let task = Task<Int, Error> {
        defer { done.increment() }
        // Deliberately not cancellation-aware, to reach perform already cancelled.
        await registration.wait()
        return try await queue.perform { ran.increment(); return 9 }
    }
    task.cancel()
    await registration.open()
    try await eventually("pre-registration cancellation returns") { done.read() == 1 }
    try await requireCancellation(task)
    try require(ran.read() == 0, "already-cancelled body ran")
}

private func testRunningCancellationJoinsAndBoundsNextGeneration() async throws {
    let queue = BlockingVisionWorkQueue(maximumConcurrentJobs: 2)
    let gate = OpaqueGate()
    defer { gate.open() }
    let counts = WorkCounts(), oldDone = Counter(), newDone = Counter(), newStarted = Counter()
    let old = (0..<2).map { _ in Task<Int, Error> {
        defer { oldDone.increment() }
        return try await queue.perform {
            counts.enter(); defer { counts.leave() }
            try gate.wait()
            return 10
        }
    } }
    try await eventually("old generation occupies both slots") { counts.read().running == 2 }
    old.forEach { $0.cancel() }
    let next = (0..<2).map { index in Task<Int, Error> {
        defer { newDone.increment() }
        return try await queue.perform {
            counts.enter(); defer { counts.leave() }
            newStarted.increment()
            return index
        }
    } }
    try await eventually("next generation enqueued") { queue.unfinishedOperationCount >= 4 }
    try await Task.sleep(nanoseconds: 20_000_000)
    try require(oldDone.read() == 0, "running cancellation released join before opaque return")
    try require(newStarted.read() == 0 && counts.read().peak == 2, "next generation escaped bound")
    gate.open()
    try await eventually("both generations finish") { oldDone.read() == 2 && newDone.read() == 2 }
    for job in old { try await requireCancellation(job) }
    for job in next { _ = try await job.value }
    try require(counts.read().exited == 4 && counts.read().peak <= 2, "running jobs leaked/exceeded limit")
}

private final class SentinelError: Error, @unchecked Sendable {}

private func testValueErrorAndTerminalCancellation() async throws {
    let queue = BlockingVisionWorkQueue(maximumConcurrentJobs: 2)
    let expected = SentinelError()
    do {
        let _: Int = try await queue.perform { throw expected }
        throw TestFailure("synchronous error was lost")
    } catch {
        try require((error as? SentinelError) === expected, "error identity was changed")
    }
    let task = Task<Int, Error> { try await queue.perform { 37 } }
    let first = try await task.value
    try require(first == 37, "normal value changed")
    task.cancel() // Completion committed first; cancellation cannot rewrite it.
    let second = try await task.value
    try require(second == 37, "terminal value rewritten by late cancellation")
}

@main
private enum VisionWorkQueueSelfTest {
    static func main() async throws {
        try await testQueueLimit(2)
        print("PASS actual queue width 2, queue identity and values")
        try await testQueueLimit(4)
        print("PASS actual queue width 4, queue identity and values")
        try await testQueuedCancellationReleasesImage()
        print("PASS queued cancellation: zero job calls and captured image released")
        try await testAlreadyCancelledBeforeRegistration()
        print("PASS already-cancelled registration")
        try await testRunningCancellationJoinsAndBoundsNextGeneration()
        print("PASS running cancellation joins opaque job; next generation bounded")
        try await testValueErrorAndTerminalCancellation()
        print("PASS exact error, normal value and completion-before-cancel")
    }
}
