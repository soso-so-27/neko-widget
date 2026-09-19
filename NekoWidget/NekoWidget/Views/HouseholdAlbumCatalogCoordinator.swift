import Combine
import Foundation

/// A change here revokes the permission to show any previously prepared photo.
/// These are publication counters/settings, never hashes of the photo arrays.
struct HouseholdAlbumCatalogAccessKey: Equatable, Sendable {
    let canBuild: Bool
    let isLimitedAccess: Bool
    let analysisFingerprint: String
    let curationMutationRevision: Int
    let identityMutationRevision: Int?
    let sourceResolutionRevision: Int
    let removedPhotoRevision: Int
    let sourceAlbumIdentifier: String?
}

struct HouseholdAlbumCatalogContentKey: Equatable, Sendable {
    let photoContentRevision: Int
    let photoCount: Int
    let legacyLifeReference: CatLifeReference?
    let growthPhotoOverridesJSON: String
    let referenceDay: Date
    let timeZoneIdentifier: String
}

struct HouseholdAlbumCatalogKey: Equatable, Sendable {
    let access: HouseholdAlbumCatalogAccessKey
    let content: HouseholdAlbumCatalogContentKey
}

struct HouseholdAlbumCatalogInput: Sendable {
    let photos: [PhotoPresentation]
    let excludedIdentifiers: Set<String>
    let lifeReference: CatLifeReference?
    let growthPhotoOverridesJSON: String
    let referenceDate: Date
    let timeZone: TimeZone
}

struct HouseholdAlbumCatalogRequest: Sendable {
    let key: HouseholdAlbumCatalogKey
    let input: HouseholdAlbumCatalogInput
}

/// A single worker finishes useful content while newer requests collapse into
/// one pending value. Access changes invalidate reads synchronously and cancel
/// the worker, but a replacement never overlaps the cancelled worker.
@MainActor
final class HouseholdAlbumCatalogCoordinator: ObservableObject {
    typealias Builder = @Sendable (HouseholdAlbumCatalogInput) async throws -> PreparedHouseholdAlbumCatalog

    private struct Completion {
        let key: HouseholdAlbumCatalogKey
        let catalog: PreparedHouseholdAlbumCatalog
    }

    @Published private var completion: Completion?
    private var access: HouseholdAlbumCatalogAccessKey?
    private var accessGeneration = 0
    private var desired: HouseholdAlbumCatalogRequest?
    private var runningKey: HouseholdAlbumCatalogKey?
    private var worker: Task<PreparedHouseholdAlbumCatalog, Error>?
    private var observer: Task<Void, Never>?
    private let builder: Builder

    // Counts describe coordinator work only, without identifiers or photo data.
    private(set) var startedCount = 0
    private(set) var completedCount = 0
    var activeCount: Int { worker == nil ? 0 : 1 }
    var hasPendingRequest: Bool {
        guard worker != nil, let desired else { return false }
        return desired.key != runningKey
    }

    init(builder: @escaping Builder = { input in
        #if DEBUG
        if ProcessInfo.processInfo.environment["NEKO_ALBUM_CATALOG_DEBUG"] == "1",
           let raw = ProcessInfo.processInfo.environment["NEKO_ALBUM_CATALOG_DELAY_MS"],
           let milliseconds = Int(raw), milliseconds > 0 {
            try await Task.sleep(for: .milliseconds(min(milliseconds, 5_000)))
        }
        #endif
        return try HouseholdAlbumCatalogBuilder().build(
            from: input.photos, excludedIdentifiers: input.excludedIdentifiers,
            lifeReference: input.lifeReference, growthPhotoOverridesJSON: input.growthPhotoOverridesJSON,
            referenceDate: input.referenceDate, timeZone: input.timeZone
        )
    }) {
        self.builder = builder
    }

    deinit {
        worker?.cancel()
        observer?.cancel()
    }

    /// The caller supplies the *current* access key, so rendering rejects an
    /// obsolete result even before SwiftUI runs the task submitting new input.
    func catalog(for currentAccess: HouseholdAlbumCatalogAccessKey) -> PreparedHouseholdAlbumCatalog? {
        guard currentAccess.canBuild, completion?.key.access == currentAccess else { return nil }
        return completion?.catalog
    }

    func submit(_ request: HouseholdAlbumCatalogRequest) {
        if access != request.key.access {
            accessGeneration &+= 1
            access = request.key.access
            completion = nil
            worker?.cancel()
        }
        guard request.key.access.canBuild else {
            desired = nil
            notifyDebugState()
            return
        }
        // This also makes view/task reappearance with the same input harmless.
        if desired?.key != request.key { desired = request }
        startNextIfNeeded()
        notifyDebugState()
    }

    private func startNextIfNeeded() {
        guard worker == nil, let request = desired,
              completion?.key != request.key else { return }
        let generation = accessGeneration
        let build = builder
        let input = request.input
        let task = Task.detached(priority: .utility) { try await build(input) }
        worker = task
        runningKey = request.key
        startedCount += 1
        observer = Task { [weak self] in
            let result = await task.result
            self?.finished(result, key: request.key, generation: generation,
                           wasCancelled: task.isCancelled)
        }
    }

    private func finished(
        _ result: Result<PreparedHouseholdAlbumCatalog, Error>,
        key: HouseholdAlbumCatalogKey,
        generation: Int,
        wasCancelled: Bool
    ) {
        worker = nil
        observer = nil
        runningKey = nil
        if case let .success(catalog) = result,
           !wasCancelled, generation == accessGeneration, access == key.access,
           key.access.canBuild,
           completion?.key != desired?.key {
            completion = Completion(key: key, catalog: catalog)
            completedCount += 1
        }
        // Do not spin if a builder fails for the latest request. A genuinely
        // newer request (or access generation) can still run after that failure.
        if desired?.key != key || generation != accessGeneration {
            startNextIfNeeded()
        }
        notifyDebugState()
    }

    private func notifyDebugState() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["NEKO_ALBUM_CATALOG_DEBUG"] == "1" {
            objectWillChange.send()
        }
        #endif
    }

    #if DEBUG
    func debugState(for currentAccess: HouseholdAlbumCatalogAccessKey) -> String {
        let visible = catalog(for: currentAccess)
        let photos = visible?.sections.flatMap(\.albums).first { $0.id == .allCatPhotos }?.photos ?? []
        let containsProbe = photos.contains { $0.id == "app-store-screenshot-fixture-page-1" }
        return "started:\(startedCount);completed:\(completedCount);active:\(activeCount)"
            + ";pending:\(hasPendingRequest ? 1 : 0);visible:\(visible == nil ? 0 : 1)"
            + ";visibleCount:\(photos.count);visibleContainsProbe:\(containsProbe ? 1 : 0)"
    }
    #endif
}
