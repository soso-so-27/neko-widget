// PROPOSAL ONLY. Foundation-only bridge, not adopted by PhotoLibraryScanner.
// It does not establish the cause of the retained Photos/AX failure.
import Foundation

/// One instance must be shared across scan generations. A synchronous job
/// starts at the queued -> running transition under Request.lock. If cancel
/// wins that transition, the job is never called. Once start wins, cancellation
/// waits for the opaque job to return; it cannot release a queue slot early.
final class ProposedVisionWorkQueue: @unchecked Sendable {
    private let operations: OperationQueue
    let maximumConcurrentJobs: Int

    init(maximumConcurrentJobs: Int) {
        precondition(maximumConcurrentJobs == 2 || maximumConcurrentJobs == 4)
        self.maximumConcurrentJobs = maximumConcurrentJobs
        let queue = OperationQueue()
        queue.name = "neko.proposal.vision-blocking.\(maximumConcurrentJobs)"
        queue.maxConcurrentOperationCount = maximumConcurrentJobs
        queue.qualityOfService = .userInitiated
        operations = queue
    }

    func perform<Value: Sendable>(
        _ job: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let request = ProposedVisionRequest(job: job)
        return try await withTaskCancellationHandler {
            // Also covers an already-cancelled task before registration.
            if Task.isCancelled { request.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                if request.register(continuation) {
                    // Cancel may win between registration and enqueue. The
                    // operation then becomes a no-op; no job closure is kept.
                    operations.addOperation(ProposedVisionOperation(request: request))
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    // Read-only diagnostics for this proposal's standalone tests.
    var unfinishedOperationCount: Int { operations.operationCount }
    var isExecutingOnOwnedQueue: Bool { OperationQueue.current === operations }
}

private final class ProposedVisionRequest<Value: Sendable>: @unchecked Sendable {
    typealias Job = @Sendable () throws -> Value
    private enum Phase: Equatable { case unregistered, queued, running, terminal }
    private let lock = NSLock()
    private var phase: Phase = .unregistered
    private var cancellationRequested = false
    private var job: Job?
    private var continuation: CheckedContinuation<Value, Error>?

    init(job: @escaping Job) { self.job = job }

    /// Exactly one registration. No external work or continuation is called
    /// under lock. A pre-registration cancellation is remembered, not lost.
    func register(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        var cancelled = false
        var releasedJob: Job?
        lock.lock()
        precondition(phase == .unregistered)
        if cancellationRequested {
            phase = .terminal
            releasedJob = job
            job = nil
            cancelled = true
        } else {
            self.continuation = continuation
            phase = .queued
        }
        lock.unlock()
        // Capture destruction may itself run arbitrary deinit code.
        withExtendedLifetime(releasedJob) {}
        releasedJob = nil
        if cancelled { continuation.resume(throwing: CancellationError()) }
        return !cancelled
    }

    func cancel() {
        var resume: CheckedContinuation<Value, Error>?
        var releasedJob: Job?
        lock.lock()
        switch phase {
        case .unregistered:
            cancellationRequested = true
            releasedJob = job
            job = nil
        case .queued:
            cancellationRequested = true
            phase = .terminal
            releasedJob = job
            job = nil
            resume = continuation
            continuation = nil
        case .running:
            // Keep continuation and the operation's slot until job returns.
            cancellationRequested = true
        case .terminal:
            // Completion/cancellation already committed; never resume twice.
            break
        }
        lock.unlock()
        withExtendedLifetime(releasedJob) {}
        releasedJob = nil
        resume?.resume(throwing: CancellationError())
    }

    func execute() {
        let work: Job
        lock.lock()
        guard phase == .queued else {
            lock.unlock()
            return
        }
        precondition(job != nil && continuation != nil)
        phase = .running
        work = job!
        job = nil
        lock.unlock()

        // Ordinary OperationQueue execution, never inside a Swift Task body
        // or under the request lock. No synchronous wait for Swift Tasks.
        let result = Result<Value, Error> { try work() }
        finish(result)
    }

    private func finish(_ result: Result<Value, Error>) {
        let resume: CheckedContinuation<Value, Error>
        let cancelled: Bool
        lock.lock()
        precondition(phase == .running && continuation != nil)
        phase = .terminal
        resume = continuation!
        continuation = nil
        cancelled = cancellationRequested
        lock.unlock()

        // Cancel wins only if requested before this terminal commit. Running
        // work has now returned, so old-generation join can safely finish.
        if cancelled {
            resume.resume(throwing: CancellationError())
        } else {
            resume.resume(with: result)
        }
    }
}

private final class ProposedVisionOperation<Value: Sendable>: Operation, @unchecked Sendable {
    private let request: ProposedVisionRequest<Value>
    init(request: ProposedVisionRequest<Value>) { self.request = request }

    override func main() { request.execute() }

    override func cancel() {
        // Defensive Foundation-cancellation support: a cancelled Operation may
        // never run main(). Resolve queued requests before calling super.
        // Running requests still resolve only after their opaque job returns.
        request.cancel()
        super.cancel()
    }
}
