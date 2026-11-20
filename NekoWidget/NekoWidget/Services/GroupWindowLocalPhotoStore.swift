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
        var caption: String? = nil
    }

    private struct Index: Codable {
        var schemaVersion = 1
        var entries: [Entry] = []
        // A signed sender ID stays known after its visible row is evicted.
        var receivedMomentIDs: Set<String>? = nil
        // 11/20: photos removed here before the app was installed again
        // (from the Keychain copy), so they are not downloaded again.
        var removedPhotoIDs: Set<String>? = nil
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
        /// Also blocked on the relay (photos stop both ways), not only hidden here.
        var blocked: Bool? = nil
    }

    private struct Directory: Codable {
        var schemaVersion = 1
        var windows: [KnownWindow] = []
    }

    static let shared = GroupWindowLocalPhotoStore()
    private static let maximumEntriesPerWindow = 500

    private let root: URL?
    /// 11/20: the Keychain copy of the person's choices (GroupWindowKept).
    private let keychain: @Sendable () -> (any GroupSecretStore)?
    /// Windows whose Keychain copy this process already compared (one read each).
    private var keptChecked = Set<String>()

    init(root: URL? = nil, keychain: (@Sendable () -> (any GroupSecretStore)?)? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent((Bundle.main.object(forInfoDictionaryKey: "SharingReleaseMode") as? String) == "production"
                ? "GroupWindows-production" : "GroupWindows", isDirectory: true)
        self.keychain = keychain ?? {
            try? GroupKeychainStore(namespace: GroupWindowClientProvider.namespace + GroupWindowKept.namespaceSuffix)
        }
    }

    /// Photos to show: not removed here, and not from a person hidden here.
    func entries(windowID: String) -> [Entry] {
        let hidden = Set((knownWindows().first { $0.id == windowID }?.hiddenMembers ?? []).map(\.id))
        return ((try? loadIndex(windowID: windowID).entries) ?? [])
            .filter { $0.isRemoved != true && !hidden.contains($0.senderParticipantID) }
    }

    /// Includes photos removed from this iPhone, which are not downloaded again.
    func contains(photoID: String, windowID: String) -> Bool {
        guard let index = try? loadIndex(windowID: windowID) else { return false }
        return index.entries.contains { $0.id == photoID } || index.removedPhotoIDs?.contains(photoID) == true
    }

    func hasReceived(verifiedMomentID: String, windowID: String) throws -> Bool {
        try loadIndex(windowID: windowID).receivedMomentIDs?.contains(verifiedMomentID) == true
    }

    func entry(photoID: String, windowID: String) -> Entry? {
        entries(windowID: windowID).first { $0.id == photoID }
    }

    /// The received photo that 「お気に入りに追加」 copied to this Photos item,
    /// among the photos to show (not removed, not from a hidden person).
    func favoriteEntry(localIdentifier: String) -> (windowID: String, entry: Entry)? {
        for window in knownWindows() {
            if let entry = entries(windowID: window.id)
                .first(where: { !$0.isOwn && $0.favoriteLocalIdentifier == localIdentifier }) {
                return (window.id, entry)
            }
        }
        return nil
    }

    /// Removes the image from this iPhone only. The window and the other
    /// members' iPhones are not changed.
    func remove(photoID: String, windowID: String) throws {
        var index = try loadIndex(windowID: windowID)
        guard let position = index.entries.firstIndex(where: { $0.id == photoID }) else { return }
        index.entries[position].isRemoved = true
        try? FileManager.default.removeItem(at: photoURL(photoID: photoID, windowID: windowID))
        try write(JSONEncoder().encode(index), to: indexURL(windowID: windowID))
        GroupWindowKept.update(windowID: windowID, in: keychain()) {
            $0.removedPhotoIDs.removeAll { $0 == photoID }
            $0.removedPhotoIDs.append(photoID)
        }
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

    /// `memberNames` (participant ID to name, from the relay's member list)
    /// names people whose block or hiding comes back from the Keychain.
    func remember(windowID: String, name: String, myParticipantID: String? = nil,
                  memberNames: [String: String] = [:]) {
        var windows = knownWindows()
        if let index = windows.firstIndex(where: { $0.id == windowID }) {
            seedKeptChoicesIfNeeded(windows[index])
            let me = myParticipantID ?? windows[index].myParticipantID
            guard windows[index].name != name || windows[index].myParticipantID != me else { return }
            windows[index].name = name
            windows[index].myParticipantID = me
        } else {
            var window = KnownWindow(id: windowID, name: name, myParticipantID: myParticipantID)
            // 11/20: new to this iPhone's files (the app was deleted and installed
            // again): the person's earlier choices come back from the Keychain.
            keptChecked.insert(windowID)
            if let kept = try? GroupWindowKept.choices(windowID: windowID, in: keychain()), !kept.isEmpty {
                let blocked = Set(kept.blockedMemberIDs)
                let hidden = kept.blockedMemberIDs + kept.hiddenMemberIDs.filter { !blocked.contains($0) }
                if !hidden.isEmpty {
                    window.hiddenMembers = hidden.map {
                        HiddenMember(id: $0, name: memberNames[$0] ?? "", blocked: blocked.contains($0) ? true : nil)
                    }
                }
                if !kept.removedPhotoIDs.isEmpty, var photos = try? loadIndex(windowID: windowID) {
                    photos.removedPhotoIDs = (photos.removedPhotoIDs ?? []).union(kept.removedPhotoIDs)
                    if let data = try? JSONEncoder().encode(photos), let url = try? indexURL(windowID: windowID) {
                        try? write(data, to: url)
                    }
                }
            }
            windows.append(window)
        }
        writeDirectory(windows)
    }

    /// An install from before 11/20 has its choices in the local files only:
    /// copied to the Keychain once, when nothing is kept there yet.
    private func seedKeptChoicesIfNeeded(_ window: KnownWindow) {
        guard keptChecked.insert(window.id).inserted, let store = keychain() else { return }
        let saved: GroupWindowKept.Choices?
        do { saved = try GroupWindowKept.choices(windowID: window.id, in: store) } catch { return }
        guard saved == nil else { return }
        let hidden = window.hiddenMembers ?? []
        let removed = ((try? loadIndex(windowID: window.id).entries) ?? [])
            .filter { $0.isRemoved == true }.sorted { $0.createdAt < $1.createdAt }.map(\.id)
        let choices = GroupWindowKept.Choices(
            hiddenMemberIDs: hidden.filter { $0.blocked != true }.map(\.id),
            blockedMemberIDs: hidden.filter { $0.blocked == true }.map(\.id),
            removedPhotoIDs: removed)
        guard !choices.isEmpty else { return }
        GroupWindowKept.keep(choices, windowID: window.id, in: store)
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
    /// A block records that too, so the list can offer to lift it.
    func hide(memberID: String, name: String, windowID: String, blocked: Bool = false) {
        var windows = knownWindows()
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
        var hidden = windows[index].hiddenMembers ?? []
        if let existing = hidden.firstIndex(where: { $0.id == memberID }) {
            guard blocked, hidden[existing].blocked != true else { return }
            hidden[existing].blocked = true
        } else {
            hidden.append(HiddenMember(id: memberID, name: name, blocked: blocked ? true : nil))
        }
        windows[index].hiddenMembers = hidden
        writeDirectory(windows)
        let isBlocked = hidden.contains { $0.id == memberID && $0.blocked == true }
        GroupWindowKept.update(windowID: windowID, in: keychain()) {
            if isBlocked {
                $0.hiddenMemberIDs.removeAll { $0 == memberID }
                if !$0.blockedMemberIDs.contains(memberID) { $0.blockedMemberIDs.append(memberID) }
            } else if !$0.hiddenMemberIDs.contains(memberID) {
                $0.hiddenMemberIDs.append(memberID)
            }
        }
    }

    func unhide(memberID: String, windowID: String) {
        var windows = knownWindows()
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
        windows[index].hiddenMembers?.removeAll { $0.id == memberID }
        writeDirectory(windows)
        GroupWindowKept.update(windowID: windowID, in: keychain()) {
            $0.hiddenMemberIDs.removeAll { $0 == memberID }
            $0.blockedMemberIDs.removeAll { $0 == memberID }
        }
    }

    /// Deletes every photo of a window this iPhone is no longer in.
    func forget(windowID: String) {
        writeDirectory(knownWindows().filter { $0.id != windowID })
        GroupWindowKept.forgetChoices(windowID: windowID, in: keychain())
        keptChecked.remove(windowID)
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
        // Up to 500 photos a window, and this iPhone's keys never leave it: a
        // backup copy could not be continued, and would only weigh. Photos
        // worth keeping go to the Photos app, as the guide says.
        var folder = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
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
    func save(_ entry: Entry, jpeg: Data?, windowID: String, verifiedMomentID: String? = nil) throws {
        var index = try loadIndex(windowID: windowID)
        guard !index.entries.contains(where: { $0.id == entry.id }) else { return }
        if let id = verifiedMomentID {
            guard GroupCanonical.validID(id) else { throw CocoaError(.fileReadCorruptFile) }
            var received = index.receivedMomentIDs ?? []
            guard received.insert(id).inserted else { return }
            index.receivedMomentIDs = received
        }
        if !entry.isHidden {
            guard let jpeg else { throw CocoaError(.fileWriteUnknown) }
            try write(jpeg, to: photoURL(photoID: entry.id, windowID: windowID))
        }
        index.entries.append(entry)
        index.entries.sort { $0.createdAt > $1.createdAt }
        let evicted = index.entries.dropFirst(Self.maximumEntriesPerWindow)
        index.entries = Array(index.entries.prefix(Self.maximumEntriesPerWindow))
        try write(JSONEncoder().encode(index), to: indexURL(windowID: windowID))
        for removed in evicted {
            try? FileManager.default.removeItem(at: photoURL(photoID: removed.id, windowID: windowID))
        }
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

/// 11/7 (W1): the newest photo time each group window showed while its page
/// was open, so the まど tab and the list can mark windows with photos not
/// seen yet. Read from what this iPhone keeps; nothing is asked of the relay.
/// Written after a window's page reads and when it goes away, never while scrolling.
enum GroupWindowSeen {
    private static func key(_ windowID: String) -> String { "groupWindow.seen.v1." + windowID }
    /// When marks began: photos kept before that count as seen.
    private static let sinceKey = "groupWindow.seen.v1.since"

    static func startIfNeeded() {
        guard UserDefaults.standard.object(forKey: sinceKey) == nil else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: sinceKey)
    }

    private static func seenUntil(windowID: String) -> Double? {
        if let seen = UserDefaults.standard.object(forKey: key(windowID)) as? Double { return seen }
        return UserDefaults.standard.object(forKey: sinceKey) as? Double
    }

    /// Someone else's photo, shown here, newer than the last one seen.
    static func hasNew(_ entries: [GroupWindowLocalPhotoStore.Entry], windowID: String) -> Bool {
        guard let seen = seenUntil(windowID: windowID) else { return false }
        return entries.contains { !$0.isOwn && !$0.isHidden && $0.createdAt.timeIntervalSince1970 > seen }
    }

    static func markSeen(_ entries: [GroupWindowLocalPhotoStore.Entry], windowID: String) {
        guard let newest = entries.map(\.createdAt).max()?.timeIntervalSince1970 else { return }
        let stored = UserDefaults.standard.object(forKey: key(windowID)) as? Double
        if let stored, stored >= newest { return }
        UserDefaults.standard.set(newest, forKey: key(windowID))
        NotificationCenter.default.post(name: .groupWindowNewPhotosDidChange, object: nil)
    }

    /// Windows this iPhone is in (the home-screen copy keeps only those)
    /// with a photo not seen yet.
    static func windowsWithNewPhotos() async -> [String] {
        let store = GroupWindowLocalPhotoStore.shared
        var windows: [String] = []
        for cached in GroupWidgetCache.entries() {
            let entries = await store.entries(windowID: cached.windowID)
            if hasNew(entries, windowID: cached.windowID) { windows.append(cached.windowID) }
        }
        return windows
    }
}

extension Notification.Name {
    /// New photos were kept, or a window's photos were seen (11/7).
    static let groupWindowNewPhotosDidChange = Notification.Name("jp.nekowidget.group.new-photos-did-change")
    /// 11/20: 「お気に入りに追加」 copies (Photos local identifiers, `[String]`)
    /// of photos removed, reported or blocked in a まど: the app stops showing them.
    static let groupWindowSavedCopiesWithdrawn = Notification.Name("jp.nekowidget.group.saved-copies-withdrawn")
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

/// The name this person last gave a window, offered again next time. Written
/// only after creating or asking to join, never while typing. 11/20: also kept
/// in this iPhone's Keychain, so deleting the app keeps it (GroupRememberedName).
extension GroupDisplayName {
    static let rememberedKey = "group.myDisplayName.v1"
    /// After GroupWindowClientProvider.namespace.
    static let keychainSuffix = ".display-name"
    private static var keychainChecked = false
    private static var memory: GroupRememberedName {
        let key = rememberedKey
        return GroupRememberedName(defaults: { UserDefaults.standard.string(forKey: key) },
            setDefaults: { UserDefaults.standard.set($0, forKey: key) },
            keychain: { try? GroupKeychainStore(namespace: GroupWindowClientProvider.namespace + keychainSuffix) })
    }

    /// 11/20 (GroupIdentityDeletionLocalData): both copies were removed; the
    /// next read compares them again instead of trusting this process's.
    static func forgetChecked() { keychainChecked = false }

    static var remembered: String { memory.read(checked: &keychainChecked) }

    static func remember(_ name: String) {
        memory.write(name)
        keychainChecked = true
    }

    /// The relay takes up to 80 bytes (GroupWire.name), about 26 kana.
    static func fits(_ name: String) -> Bool { name.utf8.count <= 80 }

    static let tooLongMessage = "名前が長すぎます。短くしてください。"
}

/// A rename or close that was sent but not settled (#591), kept so a retry,
/// even after the app was closed, resends the same operation ID and
/// arguments instead of a new one. One per window.
enum GroupManagementMemory {
    struct Pending: Codable, Equatable {
        let key: String
        let id: UUID
        let expectedRevision: Int
    }

    private static func storageKey(_ windowID: String) -> String { "group.pendingManagement.v1." + windowID }

    static func pending(windowID: String, key: String) -> Pending? {
        guard let data = UserDefaults.standard.data(forKey: storageKey(windowID)),
              let saved = try? JSONDecoder().decode(Pending.self, from: data), saved.key == key else { return nil }
        return saved
    }

    static func remember(_ pending: Pending, windowID: String) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: storageKey(windowID))
    }

    static func forget(windowID: String) {
        UserDefaults.standard.removeObject(forKey: storageKey(windowID))
    }
}
