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
        /// People whose photos this iPhone does not show in this window.
        var hiddenMembers: [HiddenMember]? = nil
        /// This iPhone's participant ID, so hearts show as its own before the relay answers.
        var myParticipantID: String? = nil
    }

    struct HiddenMember: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
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

    /// Photos to show: not removed here, and not from a person hidden here.
    func entries(windowID: String) -> [Entry] {
        let hidden = Set((knownWindows().first { $0.id == windowID }?.hiddenMembers ?? []).map(\.id))
        return ((try? loadIndex(windowID: windowID).entries) ?? [])
            .filter { $0.isRemoved != true && !hidden.contains($0.senderParticipantID) }
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

    func remember(windowID: String, name: String, myParticipantID: String? = nil) {
        var windows = knownWindows()
        if let index = windows.firstIndex(where: { $0.id == windowID }) {
            let me = myParticipantID ?? windows[index].myParticipantID
            guard windows[index].name != name || windows[index].myParticipantID != me else { return }
            windows[index].name = name
            windows[index].myParticipantID = me
        } else {
            windows.append(KnownWindow(id: windowID, name: name, myParticipantID: myParticipantID))
        }
        writeDirectory(windows)
    }

    func myParticipantID(windowID: String) -> String? {
        knownWindows().first { $0.id == windowID }?.myParticipantID
    }

    /// The hearts last seen from the relay, shown at once when the window opens.
    func hearts(windowID: String) -> [String: [GroupHeart]] {
        guard let url = try? heartsURL(windowID: windowID), FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let hearts = try? JSONDecoder().decode([String: [GroupHeart]].self, from: data)
        else { return [:] }
        return hearts
    }

    func saveHearts(_ hearts: [String: [GroupHeart]], windowID: String) {
        guard let url = try? heartsURL(windowID: windowID), let data = try? JSONEncoder().encode(hearts) else { return }
        try? write(data, to: url)
    }

    /// Stops showing one person's photos in a window, on this iPhone only.
    func hide(memberID: String, name: String, windowID: String) {
        var windows = knownWindows()
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
        var hidden = windows[index].hiddenMembers ?? []
        guard !hidden.contains(where: { $0.id == memberID }) else { return }
        hidden.append(HiddenMember(id: memberID, name: name))
        windows[index].hiddenMembers = hidden
        writeDirectory(windows)
    }

    func unhide(memberID: String, windowID: String) {
        var windows = knownWindows()
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
        windows[index].hiddenMembers?.removeAll { $0.id == memberID }
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

    private func heartsURL(windowID: String) throws -> URL {
        try directory(windowID: windowID).appendingPathComponent("hearts.json")
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

/// Which invitation this iPhone made for a window, and until when. Never the
/// link or its secret: those travel only through the share sheet.
enum GroupInvitationMemory {
    struct Saved: Equatable {
        let id: String
        let expiresAt: Date
    }

    private static func key(_ windowID: String) -> String { "groupWindow.invitation.v1." + windowID }

    static func remember(id: String, expiresAt: Date, windowID: String) {
        UserDefaults.standard.set(["id": id, "expiresAt": expiresAt.timeIntervalSince1970], forKey: key(windowID))
    }

    static func saved(windowID: String) -> Saved? {
        guard let value = UserDefaults.standard.dictionary(forKey: key(windowID)),
              let id = value["id"] as? String, let time = value["expiresAt"] as? Double else { return nil }
        return Saved(id: id, expiresAt: Date(timeIntervalSince1970: time))
    }

    static func forget(windowID: String) {
        UserDefaults.standard.removeObject(forKey: key(windowID))
    }
}
