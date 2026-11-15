import Foundation
import Photos

/// 11/14: whether opening the app needs to walk the whole Photos library
/// again. Before, every launch and every return to the app (2 s apart)
/// re-checked all photos (9,700 on the owner's iPhone), which kept the main
/// thread busy for ~20 s. Photos keeps a persistent change history; when it
/// says nothing that the scan stores has changed since the last completed
/// pass, the pass is skipped. Any doubt means a pass, as before.

/// The PhotoKit facts a scan record keeps for a photo, compared for photos
/// Photos reports as updated (its own analysis touches photos often; an
/// update that changes none of these leaves every record as it is).
struct LibraryAssetFacts: Equatable, Sendable {
    var creationDate: Date?
    var modificationDate: Date?
    var isFavorite: Bool
    var isScreenshot: Bool
    var burstIdentifier: String?

    init(creationDate: Date?, modificationDate: Date?, isFavorite: Bool,
         isScreenshot: Bool, burstIdentifier: String?) {
        self.creationDate = creationDate
        // The scanner stores whole seconds (normalizedModificationDate).
        self.modificationDate = modificationDate.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
        self.isFavorite = isFavorite
        self.isScreenshot = isScreenshot
        self.burstIdentifier = burstIdentifier
    }

    init(record: AssetRecord) {
        self.init(creationDate: record.creationDate, modificationDate: record.sourceModificationDate,
                  isFavorite: record.isFavorite,
                  isScreenshot: record.isScreenshot || record.analysisStatus == .excludedScreenshot,
                  burstIdentifier: record.burstIdentifier)
    }
}

/// Photos' persistent changes since a token, reduced to what a pass needs.
struct PhotoLibraryChangeSummary: Equatable, Sendable {
    var insertedAssets = 0
    var deletedAssets = 0
    /// Updated photos with their current facts; nil when the photo cannot
    /// be read as an image now.
    var updatedAssets: [String: LibraryAssetFacts?] = [:]
    var collectionsChanged = false
    /// More updates than are worth comparing one by one.
    var isTruncated = false
}

enum PhotoLibraryChangeCheck: Equatable, Sendable {
    /// No usable history: the token expired or PhotoKit failed.
    case unavailable
    case changes(PhotoLibraryChangeSummary)
}

/// Written only after a pass completes, with the token taken when it began.
struct LibraryVerificationReceipt: Codable, Equatable, Sendable {
    var token: Data
    var analysisFingerprint: String
    var sourceAlbumIdentifier: String?
    var lastScannedAt: Date
    var recordCount: Int
}

enum LibraryVerificationPolicy {
    /// One pass a day regardless (it also retries photos that failed).
    static let maximumAge: TimeInterval = 24 * 60 * 60

    enum Decision: Equatable {
        case skip
        case verify(String)
    }

    static func decide(
        receipt: LibraryVerificationReceipt?,
        snapshot: LibrarySnapshot,
        sourceAlbumIdentifier: String?,
        isLimitedAccess: Bool,
        forceFullAnalysis: Bool,
        now: Date,
        check: PhotoLibraryChangeCheck
    ) -> Decision {
        if forceFullAnalysis { return .verify("full-rescan") }
        // A limited selection can change without a persistent change.
        if isLimitedAccess { return .verify("limited-access") }
        let state = snapshot.scanState
        guard state.phase == .completed, state.resultKind == .final,
              !state.requiresFullRescan, state.purpose == nil,
              let lastScannedAt = state.lastScannedAt else { return .verify("no-completed-pass") }
        guard let receipt else { return .verify("no-receipt") }
        guard receipt.analysisFingerprint == snapshot.settings.analysisFingerprint else { return .verify("settings") }
        guard receipt.sourceAlbumIdentifier == sourceAlbumIdentifier else { return .verify("source") }
        // The receipt belongs to this exact snapshot (dates are stored in
        // whole seconds in the snapshot file).
        guard abs(receipt.lastScannedAt.timeIntervalSince(lastScannedAt)) < 1,
              receipt.recordCount == snapshot.assets.count else { return .verify("other-snapshot") }
        guard now.timeIntervalSince(lastScannedAt) < maximumAge, now >= lastScannedAt else { return .verify("daily") }
        guard case let .changes(summary) = check else { return .verify("no-history") }
        if summary.insertedAssets > 0 { return .verify("inserted") }
        if summary.deletedAssets > 0 { return .verify("deleted") }
        if summary.isTruncated { return .verify("many-updates") }
        if summary.collectionsChanged, sourceAlbumIdentifier != nil { return .verify("source-album") }
        guard !summary.updatedAssets.isEmpty else { return .skip }
        var stored: [String: LibraryAssetFacts] = [:]
        let wanted = Set(summary.updatedAssets.keys)
        for record in snapshot.assets where wanted.contains(record.localIdentifier) {
            stored[record.localIdentifier] = LibraryAssetFacts(record: record)
        }
        for (identifier, facts) in summary.updatedAssets {
            guard let facts else {
                // Not readable as an image now: only a photo the scan never
                // stored (a video, say) can be ignored.
                if stored[identifier] != nil { return .verify("updated-unreadable") }
                continue
            }
            guard let previous = stored[identifier] else { return .verify("updated-unknown") }
            if previous != facts { return .verify("updated") }
        }
        return .skip
    }
}

protocol PhotoLibraryChangeTokenSource: Sendable {
    /// The library's current persistent change token, archived.
    func currentToken() -> Data?
    func changes(since token: Data, maximumUpdated: Int) -> PhotoLibraryChangeCheck
}

/// iOS 16+ persistent change history. Never called on the main thread.
struct PhotoKitChangeTokenSource: PhotoLibraryChangeTokenSource {
    func currentToken() -> Data? {
        let token = PHPhotoLibrary.shared().currentChangeToken
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    func changes(since data: Data, maximumUpdated: Int) -> PhotoLibraryChangeCheck {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data) else {
            return .unavailable
        }
        // An expired token (or any other error) means a full pass.
        guard let result = try? PHPhotoLibrary.shared().fetchPersistentChanges(since: token) else {
            return .unavailable
        }
        var summary = PhotoLibraryChangeSummary()
        var updated = Set<String>()
        var failed = false
        for change in result {
            do {
                let assets = try change.changeDetails(for: .asset)
                summary.insertedAssets += assets.insertedLocalIdentifiers.count
                summary.deletedAssets += assets.deletedLocalIdentifiers.count
                updated.formUnion(assets.updatedLocalIdentifiers)
                let albums = try change.changeDetails(for: .assetCollection)
                if !albums.insertedLocalIdentifiers.isEmpty || !albums.updatedLocalIdentifiers.isEmpty
                    || !albums.deletedLocalIdentifiers.isEmpty {
                    summary.collectionsChanged = true
                }
            } catch {
                failed = true
                break
            }
            if updated.count > maximumUpdated { summary.isTruncated = true; break }
        }
        if failed { return .unavailable }
        guard !summary.isTruncated, !updated.isEmpty else { return .changes(summary) }
        var facts: [String: LibraryAssetFacts?] = Dictionary(uniqueKeysWithValues: updated.map { ($0, LibraryAssetFacts?.none) })
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(updated), options: nil)
        fetched.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image else { return }
            facts[asset.localIdentifier] = LibraryAssetFacts(
                creationDate: asset.creationDate, modificationDate: asset.modificationDate,
                isFavorite: asset.isFavorite, isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                burstIdentifier: asset.burstIdentifier)
        }
        summary.updatedAssets = facts
        return .changes(summary)
    }
}

/// When the scan may send photos to Vision again (11/14). Before, photos
/// whose analysis failed and cats whose album traits could not be read
/// (iCloud-only) went to Vision on every pass, 4 at a time.
enum ScanRetryPolicy {
    static let interval: TimeInterval = 24 * 60 * 60

    /// A failed photo's record carries the time of its last attempt.
    static func retriesFailedPhoto(lastAttempt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastAttempt) >= interval || lastAttempt > now
    }

    /// A cat still missing album traits keeps its first detection time, so
    /// these are retried together, at most once a day.
    static func retriesMissingAlbumTraits(lastRetry: Date?, now: Date) -> Bool {
        guard let lastRetry else { return true }
        return now.timeIntervalSince(lastRetry) >= interval || lastRetry > now
    }
}

/// One small app-only file in Caches (losing it only means one more pass):
/// the last completed pass's receipt and the last album-trait retry.
final class LibraryVerificationStore: @unchecked Sendable {
    static let shared = LibraryVerificationStore()

    private struct File: Codable {
        var receipt: LibraryVerificationReceipt?
        var albumTraitRetryAt: Date?
    }

    private let lock = NSLock()
    private let url: URL?

    init(url: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("library-verification.v1.json")) {
        self.url = url
    }

    var receipt: LibraryVerificationReceipt? { read().receipt }
    var albumTraitRetryAt: Date? { read().albumTraitRetryAt }

    func saveReceipt(_ receipt: LibraryVerificationReceipt?) {
        update { $0.receipt = receipt }
    }

    func noteAlbumTraitRetry(at date: Date) {
        update { $0.albumTraitRetryAt = date }
    }

    private func read() -> File {
        lock.lock(); defer { lock.unlock() }
        return readUnlocked()
    }

    private func readUnlocked() -> File {
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return File() }
        return file
    }

    private func update(_ change: (inout File) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let url else { return }
        var file = readUnlocked()
        change(&file)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The last result of a derived computation, reused while its inputs (the
/// key) are the same and it is younger than `reuseSeconds` (11/14: the
/// Widget authority sync ran ~20 times per launch with the same inputs).
/// A nil key (a value that is not the current snapshot) never reuses and
/// forgets the last result, since it wrote something else.
struct ReuseGate<Key: Equatable, Value> {
    let reuseSeconds: TimeInterval
    private(set) var last: (key: Key, value: Value, uptime: TimeInterval)?

    init(reuseSeconds: TimeInterval) {
        self.reuseSeconds = reuseSeconds
    }

    func reusable(for key: Key?, uptime: TimeInterval) -> Value? {
        guard let key, let last, last.key == key,
              uptime >= last.uptime, uptime - last.uptime < reuseSeconds else { return nil }
        return last.value
    }

    mutating func record(_ value: Value, for key: Key?, uptime: TimeInterval) {
        last = key.map { (key: $0, value: value, uptime: uptime) }
    }

    mutating func forget() {
        last = nil
    }
}

/// Merges a scan's analyzed records into the held records (11/14). Returns
/// whether any record changed: a pass re-reading photos it already knows
/// changes none, and then nothing needs publishing or saving.
enum ScanProgressMerge {
    static func merge(
        _ analyzed: [AssetRecord],
        into assets: inout [AssetRecord],
        index: inout [String: Int],
        likes: [String: SharedLikeRecord]
    ) -> Bool {
        var changed = false
        for record in analyzed {
            let existingIndex = index[record.localIdentifier]
            var merged = record.preservingUserState(from: existingIndex.map { assets[$0] })
            if let like = likes[record.localIdentifier] {
                merged.liked = like.isLiked
                merged.likedAt = like.likedAt
            }
            if let existingIndex {
                guard assets[existingIndex] != merged else { continue }
                assets[existingIndex] = merged
            } else {
                index[record.localIdentifier] = assets.count
                assets.append(merged)
            }
            changed = true
        }
        return changed
    }
}
