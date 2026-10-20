import CryptoKit
import Foundation

/// Photos of a group window kept on this iPhone after they were verified,
/// decrypted, and checked for sensitive content. This is a new, separate
/// directory; it never reads or rewrites the two-person window's inbox,
/// favorites, or Widget cache. The relay is told a photo arrived only after
/// it is written here (`ProductionGroupWindowClient.storeAndAcknowledge`).
actor GroupWindowLocalPhotoStore {
    struct Entry: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let senderParticipantID: String
        let senderDisplayName: String
        let createdAt: Date
        /// True when the system flagged the photo; no image is kept.
        let isHidden: Bool
        let isOwn: Bool
        /// Set before copying to the Photos app, so an interrupted copy is
        /// found again instead of made twice.
        var favoriteImportToken: UUID? = nil
        /// The Photos item made by 「お気に入りに追加」.
        var favoriteLocalIdentifier: String? = nil
        /// Removed from this iPhone by the person. Kept in the index so the
        /// next sync does not download it again.
        var isRemoved: Bool? = nil
    }

    private struct Index: Codable {
        var schemaVersion = 1
        var entries: [Entry] = []
    }

    /// Windows this iPhone has kept photos for, with the last name seen, so
    /// photos stay reachable after leaving (「前のまど」).
    struct KnownWindow: Codable, Equatable, Sendable, Identifiable {
        let id: String
        var name: String
    }

    private struct Directory: Codable {
        var schemaVersion = 1
        var windows: [KnownWindow] = []
    }

    static let shared = GroupWindowLocalPhotoStore()
    private static let maximumEntriesPerWindow = 500

    private let root: URL?

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GroupWindows", isDirectory: true)
    }

    func entries(windowID: String) -> [Entry] {
        ((try? loadIndex(windowID: windowID).entries) ?? []).filter { $0.isRemoved != true }
    }

    /// Includes photos removed from this iPhone, which are not downloaded again.
    func contains(photoID: String, windowID: String) -> Bool {
        ((try? loadIndex(windowID: windowID).entries) ?? []).contains { $0.id == photoID }
    }

    func entry(photoID: String, windowID: String) -> Entry? {
        entries(windowID: windowID).first { $0.id == photoID }
    }

    /// Removes the image from this iPhone only. The window and the other
    /// members' iPhones are not changed.
    func remove(photoID: String, windowID: String) throws {
        var index = try loadIndex(windowID: windowID)
        guard let position = index.entries.firstIndex(where: { $0.id == photoID }) else { return }
        index.entries[position].isRemoved = true
        try? FileManager.default.removeItem(at: photoURL(photoID: photoID, windowID: windowID))
        try write(JSONEncoder().encode(index), to: indexURL(windowID: windowID))
    }

    func setFavoriteImport(photoID: String, windowID: String, token: UUID?, localIdentifier: String?) throws {
        var index = try loadIndex(windowID: windowID)
        guard let position = index.entries.firstIndex(where: { $0.id == photoID }) else { return }
        index.entries[position].favoriteImportToken = token
        index.entries[position].favoriteLocalIdentifier = localIdentifier
        try write(JSONEncoder().encode(index), to: indexURL(windowID: windowID))
    }

    // MARK: - Windows kept on this iPhone

    func knownWindows() -> [KnownWindow] {
        guard let url = directoryURL(), FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let directory = try? JSONDecoder().decode(Directory.self, from: data)
        else { return [] }
        return directory.windows
    }

    func remember(windowID: String, name: String) {
        var windows = knownWindows()
        if let index = windows.firstIndex(where: { $0.id == windowID }) {
            guard windows[index].name != name else { return }
            windows[index].name = name
        } else {
            windows.append(KnownWindow(id: windowID, name: name))
        }
        writeDirectory(windows)
    }

    /// Deletes every photo of a window this iPhone is no longer in.
    func forget(windowID: String) {
        writeDirectory(knownWindows().filter { $0.id != windowID })
        if let folder = try? directory(windowID: windowID) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func directoryURL() -> URL? {
        root?.appendingPathComponent("windows.json")
    }

    private func writeDirectory(_ windows: [KnownWindow]) {
        guard let root, let url = directoryURL() else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Directory(windows: windows)) else { return }
        try? write(data, to: url)
    }

    func imageURL(photoID: String, windowID: String) -> URL? {
        guard let entry = entries(windowID: windowID).first(where: { $0.id == photoID }),
              !entry.isHidden,
              let file = try? photoURL(photoID: photoID, windowID: windowID),
              FileManager.default.fileExists(atPath: file.path)
        else { return nil }
        return file
    }

    /// Writes the image (unless hidden) before the index, both atomically,
    /// so an interrupted write never lists a photo that is not there.
    func save(_ entry: Entry, jpeg: Data?, windowID: String) throws {
        var index = try loadIndex(windowID: windowID)
        guard !index.entries.contains(where: { $0.id == entry.id }) else { return }
        if !entry.isHidden {
            guard let jpeg else { throw CocoaError(.fileWriteUnknown) }
            try write(jpeg, to: photoURL(photoID: entry.id, windowID: windowID))
        }
        index.entries.append(entry)
        index.entries.sort { $0.createdAt > $1.createdAt }
        if index.entries.count > Self.maximumEntriesPerWindow {
            for removed in index.entries[Self.maximumEntriesPerWindow...] {
                try? FileManager.default.removeItem(at: photoURL(photoID: removed.id, windowID: windowID))
            }
            index.entries = Array(index.entries.prefix(Self.maximumEntriesPerWindow))
        }
        try write(JSONEncoder().encode(index), to: indexURL(windowID: windowID))
    }

    // MARK: - Files

    private func directory(windowID: String) throws -> URL {
        guard let root else { throw CocoaError(.fileNoSuchFile) }
        // The folder name is a digest, so the window ID never appears in paths.
        let digest = SHA256.hash(data: Data("group-window|\(windowID)".utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let url = root.appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func indexURL(windowID: String) throws -> URL {
        try directory(windowID: windowID).appendingPathComponent("index.json")
    }

    private func photoURL(photoID: String, windowID: String) throws -> URL {
        guard GroupCanonical.validID(photoID) else { throw CocoaError(.fileReadInvalidFileName) }
        return try directory(windowID: windowID).appendingPathComponent(photoID + ".jpg")
    }

    private func loadIndex(windowID: String) throws -> Index {
        let url = try indexURL(windowID: windowID)
        guard FileManager.default.fileExists(atPath: url.path) else { return Index() }
        return try JSONDecoder().decode(Index.self, from: Data(contentsOf: url))
    }

    private func write(_ data: Data, to url: URL) throws {
#if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
#else
        try data.write(to: url, options: .atomic)
#endif
    }
}
