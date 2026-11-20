import Foundation
import Photos
import UIKit

extension Notification.Name {
    /// Posted on the main thread after waiting photo decisions or liked photos
    /// reached this iPhone's records (after a restore, or once their photos
    /// arrived). Screens that keep the cat ledger in memory read it again.
    static let appRecordPhotoLinksApplied = Notification.Name("neko.app-records.photo-links-applied.v1")
}

/// 11/20: what 保存 carries of photo decisions and liked photos, and how a
/// restore brings them back. The saved form is `CatPortablePhotoLinks`.
enum AppRecordPhotoLinks {
    /// One saved record file is at most 8 MB (`ToolBackupIndex.validate`). At
    /// about 130 bytes a decided photo that is some 60,000 photos; a larger
    /// household stops saving with the capacity message instead of losing any.
    static let maximumIdentityBytes = 8 * 1024 * 1024

    /// This iPhone's decisions by iCloud Photos identity, with the decisions
    /// still waiting here. Liked photos come from the like store; an
    /// unreadable like store stops this save rather than leaving them out.
    static func portable(_ state: CatHouseholdIdentityState) async throws -> CatPortablePhotoLinks? {
        let likes = try likedPhotos()
        var locals = Set<String>()
        for membership in state.memberships { locals.insert(membership.assetLocalIdentifier) }
        for exclusion in state.globalExcludedAssets { locals.insert(exclusion.localIdentifier) }
        for profile in state.profiles {
            if let key = profile.keyPhotoLocalIdentifier { locals.insert(key) }
            locals.formUnion(profile.photoAlbumLink?.lastKnownAssetLocalIdentifiers ?? [])
        }
        locals.formUnion(likes.keys)
        let cloud = await AppRecordPhotoIdentity.cloud(Array(locals))
        let albumCloud = await AppRecordPhotoIdentity.cloudAlbums(state.profiles.compactMap { $0.photoAlbumLink?.localIdentifier })
        return CatPortablePhotoLinks.capturing(state, likes: likes, cloud: cloud, albumCloud: albumCloud)
    }

    static func likedPhotos() throws -> [String: Date] {
        var result: [String: Date] = [:]
        let records: [String: SharedLikeRecord]
        do { records = try SharedLikeStore.readAll() }
        // Without the App Group there is no like store, so there are no likes.
        catch SharedLikeStoreError.appGroupUnavailable { return [:] }
        for (identifier, record) in records where record.isLiked {
            result[identifier] = record.likedAt ?? record.changedAt
        }
        return result
    }

    /// Applies the decisions whose photos (and albums) are in this library
    /// now; the rest stay in `portablePhotoLinks` for `AppRecordLinkRetry`.
    static func resolving(_ state: CatHouseholdIdentityState) async -> CatHouseholdIdentityState {
        guard let links = state.portablePhotoLinks else { return state }
        let assets = await AppRecordPhotoIdentity.local(links.assetIdentifiers)
        let albums = await AppRecordPhotoIdentity.localAlbums(links.albumIdentifiers)
        guard !assets.isEmpty || !albums.isEmpty else { return state }
        return CatPortablePhotoLinks.applying(links, to: state, assets: assets, albums: albums)
    }
}

/// 11/20: one place that brings waiting saved references onto their photos:
/// photo decisions, liked photos and memos restored before their photo was
/// on this iPhone (iCloud Photos still syncing, Photos access not yet given
/// or Limited). It also keeps 旅立った日 the same in the record and on screen.
///
/// It runs after a restore, when the app comes to the front, when Photos
/// access changes and when the photo library changes, but only while
/// something waits; repeated tries that find nothing wait longer each time
/// (1 minute up to 1 hour). Never on a scroll path; all work is off the main
/// thread. A reference that cannot be named yet is kept, never dropped.
@MainActor
final class AppRecordLinkRetry: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = AppRecordLinkRetry()
    nonisolated static let mirroredFarewellKey = "catFarewell.mirrored.v1"

    private var observers: [NSObjectProtocol] = []
    private var task: Task<Void, Never>?
    private var requestedAgain = false
    private var waiting = true
    private var nextAllowed = Date.distantPast
    private var backoff: TimeInterval = 60
    private var lastAuthorization: PHAuthorizationStatus?
    private var observesLibrary = false
    private var farewellText: String?
    private var farewellTask: Task<Void, Never>?
    private var farewellAgain = false

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // queue nil: a poster off the main thread never waits for the main thread.
        observers = [
            center.addObserver(forName: .appRecordDatasetChanged, object: nil, queue: nil) { _ in
                Task { @MainActor in
                    AppRecordLinkRetry.shared.request(force: true)
                    AppRecordLinkRetry.shared.syncFarewell()
                }
            },
            center.addObserver(forName: .appRecordsReadableAgain, object: nil, queue: nil) { _ in
                Task { @MainActor in
                    AppRecordLinkRetry.shared.request(force: true)
                    AppRecordLinkRetry.shared.syncFarewell()
                }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
                Task { @MainActor in AppRecordLinkRetry.shared.request(force: false) }
            },
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
                Task { @MainActor in AppRecordLinkRetry.shared.farewellMayHaveChanged() }
            }
        ]
        farewellText = UserDefaults.standard.string(forKey: CatFarewell.key)
        request(force: true)
        syncFarewell()
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in AppRecordLinkRetry.shared.request(force: false) }
    }

    func request(force: Bool) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if force || status != lastAuthorization {
            lastAuthorization = status
            waiting = true
            nextAllowed = .distantPast
        }
        guard waiting else { return }
        if task != nil { requestedAgain = true; return }
        let delay = max(0, nextAllowed.timeIntervalSinceNow)
        task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let outcome = await Task.detached(priority: .utility) { await AppRecordLinkRetry.pass() }.value
            self?.finish(outcome)
        }
    }

    private func finish(_ outcome: Outcome) {
        task = nil
        waiting = outcome.waiting
        if outcome.progressed {
            backoff = 60
            nextAllowed = Date().addingTimeInterval(30)
            NotificationCenter.default.post(name: .appRecordPhotoLinksApplied, object: nil)
        } else {
            nextAllowed = Date().addingTimeInterval(backoff)
            backoff = min(backoff * 2, 3_600)
        }
        let readable = [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        if waiting && readable && !observesLibrary {
            PHPhotoLibrary.shared().register(self); observesLibrary = true
        } else if (!waiting || !readable) && observesLibrary {
            PHPhotoLibrary.shared().unregisterChangeObserver(self); observesLibrary = false
        }
        if requestedAgain { requestedAgain = false; request(force: false) }
    }

    struct Outcome: Sendable {
        var waiting = false
        var progressed = false
    }

    /// One try for every kind of waiting reference. A failure to read or
    /// write (iPhone locked, a concurrent edit) keeps everything waiting.
    nonisolated static func pass() async -> Outcome {
        var outcome = Outcome()
        do {
            let identity = try await relinkIdentity()
            outcome.waiting = outcome.waiting || identity.waiting
            outcome.progressed = outcome.progressed || identity.progressed
        } catch { outcome.waiting = true }
        do {
            let notes = PhotoMemoryNoteStore.shared
            let waiting = try await notes.waitingPhotoCloudIdentifiers()
            if !waiting.isEmpty {
                let resolved = await AppRecordPhotoIdentity.local(waiting)
                let moved = try await notes.relinkWaitingNotes(resolved: resolved)
                let left = try await notes.waitingPhotoCloudIdentifiers()
                outcome.progressed = outcome.progressed || moved > 0
                outcome.waiting = outcome.waiting || !left.isEmpty
            }
        } catch { outcome.waiting = true }
        return outcome
    }

    nonisolated private static func relinkIdentity() async throws -> (waiting: Bool, progressed: Bool) {
        let store = try CatHouseholdIdentityStore()
        guard let state = try await store.load(), let links = state.portablePhotoLinks else { return (false, false) }
        let assets = await AppRecordPhotoIdentity.local(links.assetIdentifiers)
        let albums = await AppRecordPhotoIdentity.localAlbums(links.albumIdentifiers)
        guard !assets.isEmpty || !albums.isEmpty else { return (true, false) }
        var proposed = CatPortablePhotoLinks.applying(links, to: state, assets: assets, albums: albums)
        let taken = CatPortablePhotoLinks.takingLikes(proposed.portablePhotoLinks, assets: assets)
        if !taken.likes.isEmpty {
            // The likes leave the record only after the like store took them.
            if (try? SharedLikeStore.mergeRestoredLikes(taken.likes)) != nil {
                proposed.portablePhotoLinks = taken.remaining
                proposed = proposed.normalized()
            }
        }
        guard proposed != state else { return (true, false) }
        let committed = try await store.save(proposed, expectedMutationRevision: state.mutationRevision)
        return (committed.portablePhotoLinks != nil, true)
    }

    // MARK: 旅立った日

    private func farewellMayHaveChanged() {
        let text = UserDefaults.standard.string(forKey: CatFarewell.key)
        guard text != farewellText else { return }
        farewellText = text
        syncFarewell()
    }

    func syncFarewell() {
        if farewellTask != nil { farewellAgain = true; return }
        farewellTask = Task { [weak self] in
            let wrote = await Task.detached(priority: .utility) { (try? await AppRecordLinkRetry.reconcileFarewell()) ?? false }.value
            guard let self else { return }
            self.farewellTask = nil
            if wrote { self.farewellText = UserDefaults.standard.string(forKey: CatFarewell.key) }
            if self.farewellAgain { self.farewellAgain = false; self.syncFarewell() }
        }
    }

    /// The 3-way agreement of `CatFarewellMirror`. An unreadable value on the
    /// iPhone is left exactly as it is and nothing is written. The agreement
    /// is recorded only after both copies hold it. Returns whether the
    /// iPhone's copy was written.
    nonisolated static func reconcileFarewell() async throws -> Bool {
        let defaults = UserDefaults.standard
        let text = defaults.string(forKey: CatFarewell.key) ?? ""
        guard let user = CatFarewellDay.decodeAll(text) else { return false }
        let mirrored = defaults.string(forKey: mirroredFarewellKey).flatMap(CatFarewellDay.decodeAll)
        let store = try CatHouseholdIdentityStore()
        guard let state = try await store.load() else { return false }
        let outcome = CatFarewellMirror.reconcile(user: user, mirrored: mirrored, record: state.farewellDays ?? [:])
        if outcome.writesRecord {
            var proposed = state
            proposed.farewellDays = outcome.agreed.isEmpty ? nil : outcome.agreed
            _ = try await store.save(proposed.normalized(), expectedMutationRevision: state.mutationRevision)
        }
        var wrote = false
        if outcome.writesUser {
            let next = CatFarewellDay.encodeAll(outcome.agreed, keepingUnreadableFrom: text)
            // Written only if no screen changed it meanwhile; the next try sees that change.
            wrote = await MainActor.run {
                guard (UserDefaults.standard.string(forKey: CatFarewell.key) ?? "") == text else { return false }
                UserDefaults.standard.set(next, forKey: CatFarewell.key)
                return true
            }
            guard wrote else { return false }
        }
        if mirrored != outcome.agreed {
            defaults.set(CatFarewellDay.encodeAll(outcome.agreed, keepingUnreadableFrom: ""), forKey: mirroredFarewellKey)
        }
        return wrote
    }
}

extension AppRecordDataset {
    /// 11/20: a restore or 「保存先の記録を使う」 publishes a new dataset folder
    /// (with a copy of every photo) and the old one stayed forever. At launch,
    /// before any store opens a folder, and only once the active dataset reads
    /// as complete, each other folder this code made (named by a UUID and
    /// holding its own matching `dataset.json`) is renamed `retired-<UUID>`
    /// in one step; retired folders are then removed in the background. An
    /// interrupted removal is finished at the next launch. The active folder,
    /// and folders without a matching receipt, are never touched.
    static func retireSupersededDatasets() {
        let manager = FileManager.default
        guard let active = try? pointer(), (try? root()) != nil,
              let names = try? manager.contentsOfDirectory(atPath: datasets.path) else { return }
        writeLock.lock(); defer { writeLock.unlock() }
        guard (try? pointer())?.datasetID == active.datasetID else { return }
        for name in names {
            guard let id = UUID(uuidString: name), id.uuidString == name, id != active.datasetID else { continue }
            let folder = datasets.appendingPathComponent(name, isDirectory: true)
            guard let data = try? ToolBackupFiles.read(folder.appendingPathComponent("dataset.json"), maximum: 4096),
                  let receipt = try? JSONDecoder().decode(Pointer.self, from: data),
                  receipt.version == 1, receipt.datasetID == id else { continue }
            try? manager.moveItem(at: folder, to: datasets.appendingPathComponent("retired-" + name, isDirectory: true))
        }
    }

    static func removeRetiredDatasets() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: datasets.path) else { return }
        for name in names where name.hasPrefix("retired-") {
            guard let id = UUID(uuidString: String(name.dropFirst("retired-".count))), "retired-" + id.uuidString == name else { continue }
            try? manager.removeItem(at: datasets.appendingPathComponent(name, isDirectory: true))
        }
    }
}
