import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The read-only copy of each group window's newest photo for the home
/// screen. Only the main app writes it, after the photo was verified,
/// decrypted, checked, and kept on this iPhone. The Widget only reads it:
/// no membership authority, keys, or credentials are ever stored here.
enum GroupWidgetCache {
    struct Entry: Codable, Equatable, Sendable {
        let windowID: String
        let windowName: String
        let photoID: String?
        let imageFileName: String?
        let senderDisplayName: String?
        let capturedAt: Date?
        let isPaused: Bool
        /// This iPhone already sent a heart to `photoID`. Optional so a
        /// catalog written before this field still decodes.
        var myHeartActive: Bool? = nil
    }

    private struct Catalog: Codable {
        var schemaVersion = 1
        var entries: [Entry] = []
        /// 11/20: the windows the relay listed last (minus any left since).
        /// Nil until the app has listed them once with this copy, e.g. right
        /// after a reinstall or a lost copy. Optional so an older catalog
        /// still decodes, and an older app ignores it.
        var listedWindowIDs: [String]? = nil
        /// 11/20: windows this iPhone saw go (left, ended, data deleted),
        /// newest last, at most `maximumEndedWindows`.
        var endedWindowIDs: [String]? = nil
        /// 11/21s: per window, the photos the relay listed at the last full
        /// read and the time before which it still holds each for this iPhone.
        /// Optional: older catalogs decode, older apps ignore it.
        var listedPhotos: [String: [String: Date]]? = nil
        /// 11/21s: per window, photos the relay stopped listing well before
        /// that time (taken down by the moderation team, or their sender's
        /// data deleted). They stay in the app but not on the home screen.
        var withdrawnPhotos: [String: [String]]? = nil
    }

    /// 11/20: a Widget whose window has no entry here. Only a window the app
    /// has seen go (left, ended, data deleted, or no longer listed by the
    /// relay) has ended; otherwise the app has simply not written it yet (a
    /// reinstall, a lost copy) and the Widget asks for the app to be opened.
    enum MissingEntry: Equatable, Sendable { case ended, notYetKnown }

    static func missingEntry(windowID: String, listedWindowIDs: [String]?,
                             endedWindowIDs: [String]?) -> MissingEntry {
        // Seen going here first: a closed window can still be on the list.
        if endedWindowIDs?.contains(windowID) == true { return .ended }
        guard let listedWindowIDs else { return .notYetKnown }
        return listedWindowIDs.contains(windowID) ? .notYetKnown : .ended
    }

    static func missingEntry(windowID: String) -> MissingEntry {
        let catalog = loadCatalog()
        return missingEntry(windowID: windowID, listedWindowIDs: catalog.listedWindowIDs,
                            endedWindowIDs: catalog.endedWindowIDs)
    }

    static let sourceIDPrefix = "group-window:"
    static let maximumPixelSize = 1_000
    private static let maximumWindows = 10
    /// 11/20: every read-modify-write of `catalog.json` goes through this
    /// lock. Only the app writes (the heart intent's write runs in the app
    /// too, `NEKO_HOST_APP`), so a lock in the process is enough; no file
    /// lock is held in the shared container while the app may be suspended.
    private static let catalogLock = NSLock()

    private static func withCatalogLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        catalogLock.lock()
        defer { catalogLock.unlock() }
        return try operation()
    }
    private static let maximumEndedWindows = 20

    static func sourceID(windowID: String) -> String { sourceIDPrefix + windowID }

    static func windowID(fromSourceID id: String) -> String? {
        guard id.hasPrefix(sourceIDPrefix) else { return nil }
        let windowID = String(id.dropFirst(sourceIDPrefix.count))
        return isValidID(windowID) ? windowID : nil
    }

    static func isGroupSourceID(_ id: String) -> Bool { windowID(fromSourceID: id) != nil }

    /// Tapping a group window's home-screen photo opens that window. The URL
    /// carries only the window ID, never a photo, name, or key.
    static func openURL(windowID: String) -> URL? {
        openURL(windowID: windowID, photoID: nil)
    }

    /// 11/7: the shown photo's ID too, so the tap opens that photo, not only
    /// the window list. Still no name, image, or key.
    static func openURL(windowID: String, photoID: String?) -> URL? {
        guard isValidID(windowID) else { return nil }
        var components = URLComponents()
        components.scheme = "nekowidget"
        components.host = "group-window"
        var items = [URLQueryItem(name: "window", value: windowID)]
        if let photoID, isValidID(photoID) { items.append(URLQueryItem(name: "photo", value: photoID)) }
        components.queryItems = items
        return components.url
    }

    static func windowID(fromOpenURL url: URL) -> String? {
        openTarget(fromOpenURL: url)?.windowID
    }

    /// The photo the home screen showed, when the URL names one (11/7).
    static func photoID(fromOpenURL url: URL) -> String? {
        openTarget(fromOpenURL: url)?.photoID
    }

    /// A URL from an older Widget (the window only) still opens the window.
    private static func openTarget(fromOpenURL url: URL) -> (windowID: String, photoID: String?)? {
        guard url.scheme?.lowercased() == "nekowidget",
              url.host?.lowercased() == "group-window",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems, items.count == 1 || items.count == 2,
              items[0].name == "window", let windowID = items[0].value,
              isValidID(windowID)
        else { return nil }
        guard items.count == 2 else { return (windowID, nil) }
        guard items[1].name == "photo", let photoID = items[1].value, isValidID(photoID) else { return nil }
        return (windowID, photoID)
    }

    // MARK: Reading (Widget and app)

    static func entries() -> [Entry] {
        loadCatalog().entries
    }

    private static func loadCatalog() -> Catalog {
        guard let url = catalogURL(),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              catalog.schemaVersion == 1
        else { return Catalog() }
        return catalog
    }

    static func entry(windowID: String) -> Entry? {
        entries().first { $0.windowID == windowID }
    }

    static func imageURL(for entry: Entry) -> URL? {
        guard let name = entry.imageFileName, name == fileName(windowID: entry.windowID, photoID: entry.photoID),
              let url = directory()?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    // MARK: Writing (app only)

    /// Replaces one window's entry. A new photo is shrunk for the Widget's
    /// memory limit first; the catalog is written last, so the Widget never
    /// points to a file that is not there.
    static func update(windowID: String, windowName: String, photoID: String?, jpeg: Data?,
                       senderDisplayName: String?, capturedAt: Date?, isPaused: Bool,
                       myHeartActive: Bool = false) throws {
        guard isValidID(windowID), let directory = directory() else { return }
        try withCatalogLock {
            try updateLocked(in: directory, windowID: windowID, windowName: windowName, photoID: photoID,
                             jpeg: jpeg, senderDisplayName: senderDisplayName, capturedAt: capturedAt,
                             isPaused: isPaused, myHeartActive: myHeartActive)
        }
    }

    private static func updateLocked(in directory: URL, windowID: String, windowName: String, photoID: String?,
                                     jpeg: Data?, senderDisplayName: String?, capturedAt: Date?, isPaused: Bool,
                                     myHeartActive: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var catalog = loadCatalog()
        let previous = catalog.entries.first { $0.windowID == windowID }
        // 11/20: the same photo keeps its image only while the file is there.
        // A missing file is written again from `jpeg`, so the Widget does not
        // keep saying 「アプリを開くと写真が出ます」 after the app was opened.
        var imageFileName: String?
        if let previous, previous.photoID == photoID, imageURL(for: previous) != nil {
            imageFileName = previous.imageFileName
        }
        if imageFileName == nil, let jpeg, let small = downscaled(jpeg),
           let name = fileName(windowID: windowID, photoID: photoID) {
            try write(small, to: directory.appendingPathComponent(name))
            imageFileName = name
        }
        let entry = Entry(windowID: windowID, windowName: windowName, photoID: photoID,
                          imageFileName: imageFileName, senderDisplayName: senderDisplayName,
                          capturedAt: capturedAt, isPaused: isPaused, myHeartActive: myHeartActive)
        // 11/20: a window with an entry is not ended (joined again). An
        // existing entry means it was never marked, so the check below holds.
        catalog.endedWindowIDs?.removeAll { $0 == windowID }
        // Nothing changed: the catalog on disk already says exactly this.
        if previous == entry, catalog.entries.count <= maximumWindows { return }
        // Keep each window where it is, so the widget's list does not reorder.
        if let index = catalog.entries.firstIndex(where: { $0.windowID == windowID }) {
            catalog.entries[index] = entry
        } else {
            catalog.entries.append(entry)
        }
        // 11/21m: a person is in at most `maximumWindows` windows (the relay's
        // limit), so more entries means one of them went (left on another
        // iPhone, ended) and the list has not been read since. The window
        // written now is never the one pushed off: a window the relay no
        // longer lists goes first, then the oldest other entry.
        let dropped = evicted(from: &catalog, keeping: windowID)
        try write(JSONEncoder().encode(catalog), to: directory.appendingPathComponent("catalog.json"))
        if let old = previous?.imageFileName, old != imageFileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        }
        // A window pushed off the list takes its image with it.
        for name in dropped where name != imageFileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Removes entries beyond `maximumWindows` and returns their image files.
    /// `windowID` (the entry just written) always stays.
    private static func evicted(from catalog: inout Catalog, keeping windowID: String) -> [String] {
        var dropped: [String] = []
        let listed = catalog.listedWindowIDs
        while catalog.entries.count > maximumWindows {
            var candidate: Int?
            if let listed {
                candidate = catalog.entries.firstIndex { $0.windowID != windowID && !listed.contains($0.windowID) }
            }
            if candidate == nil { candidate = catalog.entries.firstIndex { $0.windowID != windowID } }
            guard let index = candidate else { break }
            if let name = catalog.entries[index].imageFileName { dropped.append(name) }
            catalog.entries.remove(at: index)
        }
        return dropped
    }

    /// After leaving a window, its home-screen photo goes too. 11/20: the
    /// window also leaves the listed ones, so its Widget says it ended.
    static func remove(windowID: String) throws {
        guard let directory = directory() else { return }
        try withCatalogLock {
            var catalog = loadCatalog()
            let removed = catalog.entries.first(where: { $0.windowID == windowID })
            catalog.entries.removeAll { $0.windowID == windowID }
            catalog.listedWindowIDs?.removeAll { $0 == windowID }
            catalog.listedPhotos?[windowID] = nil
            catalog.withdrawnPhotos?[windowID] = nil
            if isValidID(windowID) {
                let ended = (catalog.endedWindowIDs ?? []).filter { $0 != windowID } + [windowID]
                catalog.endedWindowIDs = Array(ended.suffix(maximumEndedWindows))
            } else if removed == nil { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(JSONEncoder().encode(catalog), to: directory.appendingPathComponent("catalog.json"))
            if let name = removed?.imageFileName {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// After the relay's list loaded: a window it no longer lists (removed by
    /// its owner, ended, left on another iPhone) leaves the home screen and the
    /// widget's choices too (11/6). 11/20: the list is kept, so a Widget of a
    /// window with no entry can tell "ended" from "not written yet". Returns
    /// whether anything a Widget shows changed.
    @discardableResult
    static func keepOnly(windowIDs: Set<String>) -> Bool {
        let gone = entries().map(\.windowID).filter { !windowIDs.contains($0) }
        for windowID in gone { try? remove(windowID: windowID) }
        var listChanged = false
        if let directory = directory() {
            withCatalogLock {
                var catalog = loadCatalog()
                let listed = windowIDs.sorted()
                if catalog.listedWindowIDs != listed {
                    catalog.listedWindowIDs = listed
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    listChanged = (try? write(JSONEncoder().encode(catalog),
                                              to: directory.appendingPathComponent("catalog.json"))) != nil
                }
            }
        }
        return !gone.isEmpty || listChanged
    }

    /// 11/21s: after a full read of one window's photos (`listed`: each photo
    /// and the relay's `accessExpiresAt` for this iPhone). A photo listed at
    /// the last read that is missing now, well before that time, was taken
    /// down: it leaves the home screen. One listed again (a restriction
    /// lifted, an unblock) comes back. Returns whether that window's
    /// taken-down photos changed. Nothing is known before the first read, so
    /// nothing is taken off then.
    @discardableResult
    static func noteListedPhotos(windowID: String, listed: [String: Date], now: Date = Date()) -> Bool {
        guard isValidID(windowID), let directory = directory() else { return false }
        return withCatalogLock {
            var catalog = loadCatalog()
            let previous = catalog.listedPhotos?[windowID] ?? [:]
            let before = catalog.withdrawnPhotos?[windowID] ?? []
            let next = withdrawn(previous: previous, before: before, listed: listed, now: now)
            let kept = listedPhotosToKeep(listed, now: now)
            // Not written again when only the 7-day bound moved on: an earlier
            // (shorter) time is the careful one. A shorter time is written.
            if next == before, Set(kept.keys) == Set(previous.keys),
               kept.allSatisfy({ $0.value >= (previous[$0.key] ?? .distantFuture) }) { return false }
            var allListed = catalog.listedPhotos ?? [:]
            allListed[windowID] = kept.isEmpty ? nil : kept
            catalog.listedPhotos = allListed
            var allWithdrawn = catalog.withdrawnPhotos ?? [:]
            allWithdrawn[windowID] = next.isEmpty ? nil : next
            catalog.withdrawnPhotos = allWithdrawn
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard (try? write(JSONEncoder().encode(catalog),
                              to: directory.appendingPathComponent("catalog.json"))) != nil else { return false }
            return next != before
        }
    }

    /// 11/21s: photos of this window that are not shown on the home screen.
    static func withdrawnPhotoIDs(windowID: String) -> Set<String> {
        Set(loadCatalog().withdrawnPhotos?[windowID] ?? [])
    }

    /// The taken-down photos after a read: the earlier ones not listed again,
    /// then each photo listed last time that is missing now although the
    /// relay should still hold it for more than `withdrawalMargin`.
    static func withdrawn(previous: [String: Date], before: [String], listed: [String: Date], now: Date) -> [String] {
        var result = before.filter { listed[$0] == nil }
        let ending = now.addingTimeInterval(withdrawalMargin)
        for (photoID, until) in previous.sorted(by: { $0.key < $1.key })
        where listed[photoID] == nil && until > ending && !result.contains(photoID) {
            result.append(photoID)
        }
        return Array(result.suffix(maximumWithdrawnPhotos))
    }

    /// What is kept from a read. Each time is at most 7 days from now:
    /// receiving the photo after this read can shorten the relay's hold for
    /// this iPhone to 7 days from then, so a later time is never relied on.
    static func listedPhotosToKeep(_ listed: [String: Date], now: Date) -> [String: Date] {
        let bound = now.addingTimeInterval(7 * 86_400)
        let valid = listed.filter { isValidID($0.key) }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        return Dictionary(valid.prefix(maximumListedPhotos).map { ($0.key, min($0.value, bound)) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// A photo missing within this time of its end may simply have ended
    /// (and the two clocks may differ a little).
    static let withdrawalMargin: TimeInterval = 3_600
    private static let maximumListedPhotos = 200
    private static let maximumWithdrawnPhotos = 100

    /// Written by builds with group windows on. The Widget then offers group
    /// windows only, as the app does (the two-person window is not shown).
    static func markGroupWindowsOn() {
        guard let directory = directory() else { return }
        let marker = directory.appendingPathComponent("group-windows-on")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? write(Data("1".utf8), to: marker)
    }

    static var groupWindowsAreOn: Bool {
        guard let marker = directory()?.appendingPathComponent("group-windows-on") else { return false }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    /// After the app sent a heart from the Widget, show it as sent.
    static func markMyHeart(windowID: String, photoID: String) throws {
        guard let directory = directory() else { return }
        try withCatalogLock {
            var catalog = loadCatalog()
            guard let index = catalog.entries.firstIndex(where: { $0.windowID == windowID }),
                  catalog.entries[index].photoID == photoID
            else { return }
            catalog.entries[index].myHeartActive = true
            try write(JSONEncoder().encode(catalog), to: directory.appendingPathComponent("catalog.json"))
        }
    }

    // MARK: Files

    private static func directory() -> URL? {
        SharedContainer.containerURL?.appendingPathComponent(
            (Bundle.main.object(forInfoDictionaryKey: "SharingReleaseMode") as? String) == "production"
                ? "GroupWidget-production" : "GroupWidget", isDirectory: true)
    }

    private static func catalogURL() -> URL? {
        directory()?.appendingPathComponent("catalog.json")
    }

    private static func fileName(windowID: String, photoID: String?) -> String? {
        guard let photoID else { return nil }
        let digest = SHA256.hash(data: Data("group-widget|\(windowID)|\(photoID)".utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        return digest + ".jpg"
    }

    private static func isValidID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95
        }
    }

    private static func downscaled(_ jpeg: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
              ] as CFDictionary)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func write(_ data: Data, to url: URL) throws {
#if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
#else
        try data.write(to: url, options: .atomic)
#endif
    }
}

/// A person's name as other people see it. Sentences about the person
/// (block, remove, invite) use 「ゆいさん」, but 「お母さん」 stays 「お母さん」
/// (no 「お母さんさん」). Shared by the app and the Widget.
enum GroupDisplayName {
    private static let endings = ["さん", "ちゃん", "くん", "君", "さま", "様", "先生", "氏"]

    static func withSan(_ name: String) -> String {
        let trimmed = plain(name)
        if trimmed == unnamed { return trimmed }
        return endings.contains(where: { trimmed.hasSuffix($0) }) ? trimmed : trimmed + "さん"
    }

    /// The name exactly as the person chose it. Names are nicknames, so the
    /// sender of a まど photo reads 「ママから」, never 「ママさんから」 (11/11).
    static func plain(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? unnamed : trimmed
    }

    /// The sender line of a まど photo: 「ママから」.
    static func from(_ name: String) -> String { plain(name) + "から" }

    private static let unnamed = "名前のない人"
}
