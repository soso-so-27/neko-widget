import Combine
import Foundation

private enum CatalogCoordinatorVerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case let .failed(message): message }
    }
}

@MainActor
private func requireCatalog(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CatalogCoordinatorVerificationError.failed(message) }
}

/// Deliberately ignores task cancellation while blocked, like a synchronous
/// sort already in progress. Each worker exits only when the test releases it.
private actor CatalogBuildBarrier {
    private struct WaitingBuild {
        let input: HouseholdAlbumCatalogInput
        let continuation: CheckedContinuation<PreparedHouseholdAlbumCatalog, Error>
    }
    private struct WaitingStart {
        let count: Int
        let continuation: CheckedContinuation<Void, Error>
        let deadline: Task<Void, Never>
    }

    private var builds: [String: WaitingBuild] = [:]
    private var startWaiters: [UUID: WaitingStart] = [:]
    private(set) var labels: [String] = []
    private(set) var maximumConcurrent = 0

    func build(_ input: HouseholdAlbumCatalogInput) async throws -> PreparedHouseholdAlbumCatalog {
        guard let label = input.photos.first?.id, builds[label] == nil else {
            throw CatalogCoordinatorVerificationError.failed("Invalid/duplicate barrier input")
        }
        return try await withCheckedThrowingContinuation { continuation in
            builds[label] = WaitingBuild(input: input, continuation: continuation)
            labels.append(label)
            maximumConcurrent = max(maximumConcurrent, builds.count)
            for id in Array(startWaiters.keys) {
                guard let waiter = startWaiters[id], labels.count >= waiter.count else { continue }
                startWaiters[id] = nil
                waiter.deadline.cancel()
                waiter.continuation.resume()
            }
        }
    }

    func waitForStarts(_ count: Int) async throws {
        guard labels.count < count else { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            // A timeout only bounds a failed test. It never advances the test's
            // ordering; every successful transition uses explicit continuations.
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                await self?.expireStartWaiter(id)
            }
            startWaiters[id] = WaitingStart(count: count, continuation: continuation, deadline: deadline)
        }
    }

    private func expireStartWaiter(_ id: UUID) {
        guard let waiter = startWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CatalogCoordinatorVerificationError.failed(
            "Timed out waiting for worker \(waiter.count)"))
    }

    func release(_ label: String) throws {
        guard let build = builds.removeValue(forKey: label) else {
            throw CatalogCoordinatorVerificationError.failed("Released a worker that never started: \(label)")
        }
        let album = CuratedAlbumPresentation(id: .allCatPhotos, group: .all, photos: build.input.photos)
        build.continuation.resume(returning: PreparedHouseholdAlbumCatalog(
            sections: [CuratedAlbumSectionPresentation(id: .all, albums: [album])], highlights: []
        ))
    }

    func cancelAll() {
        for build in builds.values { build.continuation.resume(throwing: CancellationError()) }
        builds = [:]
        for waiter in startWaiters.values {
            waiter.deadline.cancel()
            waiter.continuation.resume(throwing: CancellationError())
        }
        startWaiters = [:]
    }
}

@MainActor
private final class CatalogPublicationWaiter {
    private var subscription: AnyCancellable?
    private var deadline: Task<Void, Never>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var predicate: (() -> Bool)?

    func wait(for coordinator: HouseholdAlbumCatalogCoordinator,
              until predicate: @escaping () -> Bool) async throws {
        if predicate() { return }
        self.predicate = predicate
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            subscription = coordinator.objectWillChange.sink { [weak self] in
                // @Published sends before mutation. The main-actor hop checks
                // only after the coordinator has completed that synchronous turn.
                Task { @MainActor [weak self] in self?.check() }
            }
            deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.finish(.failure(CatalogCoordinatorVerificationError.failed(
                    "Timed out waiting for an authorized catalog publication")))
            }
            check()
        }
    }

    private func check() {
        if predicate?() == true { finish(.success(())) }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        subscription?.cancel()
        subscription = nil
        deadline?.cancel()
        deadline = nil
        predicate = nil
        continuation.resume(with: result)
    }
}

private func catalogAccess(canBuild: Bool = true, removedRevision: Int = 0) -> HouseholdAlbumCatalogAccessKey {
    HouseholdAlbumCatalogAccessKey(
        canBuild: canBuild, isLimitedAccess: false, analysisFingerprint: "coordinator-test",
        curationMutationRevision: 0, identityMutationRevision: nil, sourceResolutionRevision: 0,
        removedPhotoRevision: removedRevision, sourceAlbumIdentifier: nil
    )
}

private func catalogRequest(
    _ label: String, revision: Int, access: HouseholdAlbumCatalogAccessKey
) -> HouseholdAlbumCatalogRequest {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let zone = TimeZone(secondsFromGMT: 0)!
    return HouseholdAlbumCatalogRequest(
        key: HouseholdAlbumCatalogKey(
            access: access,
            content: HouseholdAlbumCatalogContentKey(
                photoContentRevision: revision, photoCount: 1, legacyLifeReference: nil,
                growthPhotoOverridesJSON: "", referenceDay: date, timeZoneIdentifier: zone.identifier
            )
        ),
        input: HouseholdAlbumCatalogInput(
            photos: [PhotoPresentation(localIdentifier: label, creationDate: date)],
            excludedIdentifiers: [], lifeReference: nil, growthPhotoOverridesJSON: "",
            referenceDate: date, timeZone: zone
        )
    )
}

@MainActor
private func visibleCatalogPhoto(
    _ coordinator: HouseholdAlbumCatalogCoordinator, access: HouseholdAlbumCatalogAccessKey
) -> String? {
    coordinator.catalog(for: access)?.sections.first?.albums.first?.photos.first?.id
}

@MainActor
func verifyAlbumCatalogCoordinator() async throws {
    let barrier = CatalogBuildBarrier()
    let coordinator = HouseholdAlbumCatalogCoordinator { input in try await barrier.build(input) }
    let access = catalogAccess()
    do {
        let requestA = catalogRequest("A", revision: 1, access: access)
        for _ in 0..<100 { coordinator.submit(requestA) }
        try await barrier.waitForStarts(1)
        try requireCatalog(coordinator.startedCount == 1 && coordinator.activeCount == 1,
                           "Identical progress requests restarted the active worker")

        coordinator.submit(catalogRequest("B", revision: 2, access: access))
        coordinator.submit(catalogRequest("C", revision: 3, access: access))
        try requireCatalog(coordinator.startedCount == 1 && coordinator.hasPendingRequest,
                           "Content updates spawned an overlapping worker or lost the pending request")
        try await barrier.release("A")
        try await barrier.waitForStarts(2)
        let initialLabels = await barrier.labels
        try requireCatalog(initialLabels == ["A", "C"], "Pending content B/C did not collapse to C")
        try requireCatalog(visibleCatalogPhoto(coordinator, access: access) == "A"
                           && coordinator.activeCount == 1 && !coordinator.hasPendingRequest,
                           "A safe completed catalog disappeared while the newest content was building")
        try await barrier.release("C")
        try await CatalogPublicationWaiter().wait(for: coordinator) {
            visibleCatalogPhoto(coordinator, access: access) == "C"
        }
        try requireCatalog(coordinator.completedCount == 2 && coordinator.activeCount == 0,
                           "The latest content never completed")
        for _ in 0..<100 { coordinator.submit(catalogRequest("C", revision: 3, access: access)) }
        try requireCatalog(coordinator.startedCount == 2, "Ready-cache reappearance rebuilt unchanged content")

        coordinator.submit(catalogRequest("D", revision: 4, access: access))
        try await barrier.waitForStarts(3)
        try requireCatalog(visibleCatalogPhoto(coordinator, access: access) == "C",
                           "A normal refresh replaced ready content with an empty state")
        let denied = catalogAccess(canBuild: false)
        try requireCatalog(coordinator.catalog(for: denied) == nil,
                           "Access loss was not rejected before submitting its task")
        coordinator.submit(catalogRequest("denied", revision: 4, access: denied))
        try requireCatalog(coordinator.catalog(for: access) == nil,
                           "Access loss retained the old completed catalog")
        // Restore the same access key before the cancelled D returns. The
        // access generation must still prevent this late D result from showing.
        coordinator.submit(catalogRequest("E", revision: 5, access: access))
        try requireCatalog(coordinator.startedCount == 3 && coordinator.activeCount == 1,
                           "Replacement work overlapped a cancelled, noncooperative worker")
        try await barrier.release("D")
        try await barrier.waitForStarts(4)
        try requireCatalog(coordinator.catalog(for: access) == nil && coordinator.completedCount == 2,
                           "The cancelled worker republished an old catalog after access was restored")
        try await barrier.release("E")
        try await CatalogPublicationWaiter().wait(for: coordinator) {
            visibleCatalogPhoto(coordinator, access: access) == "E"
        }
        try requireCatalog(coordinator.completedCount == 3 && coordinator.activeCount == 0,
                           "Cancellation left the coordinator permanently waiting instead of completing E")

        // Count/content revision deliberately remain equal: the removal key
        // independently rejects the old photo even if one new photo replaces it.
        let afterRemoval = catalogAccess(removedRevision: 1)
        try requireCatalog(coordinator.catalog(for: afterRemoval) == nil,
                           "Same-count deletion did not immediately reject the previous catalog")
        coordinator.submit(catalogRequest("F", revision: 5, access: afterRemoval))
        try await barrier.waitForStarts(5)
        try requireCatalog(coordinator.catalog(for: afterRemoval) == nil,
                           "A deleted photo stayed visible during rebuilding")
        try await barrier.release("F")
        try await CatalogPublicationWaiter().wait(for: coordinator) {
            visibleCatalogPhoto(coordinator, access: afterRemoval) == "F"
        }
        let labels = await barrier.labels
        let maximumConcurrent = await barrier.maximumConcurrent
        try requireCatalog(labels == ["A", "C", "D", "E", "F"] && maximumConcurrent == 1,
                           "Work was not serialized/coalesced as requested")
        try requireCatalog(coordinator.completedCount == 4 && coordinator.activeCount == 0,
                           "The post-deletion replacement never settled")
        print("Album catalog coordinator: duplicate/coalescing/retention/access/removal/cancellation PASS")
    } catch {
        await barrier.cancelAll()
        throw error
    }
}
