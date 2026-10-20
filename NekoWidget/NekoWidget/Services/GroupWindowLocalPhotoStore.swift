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
    }

    private struct Index: Codable {
        var schemaVersion = 1
        var entries: [Entry] = []
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
        (try? loadIndex(windowID: windowID).entries) ?? []
    }

    func contains(photoID: String, windowID: String) -> Bool {
        entries(windowID: windowID).contains { $0.id == photoID }
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
