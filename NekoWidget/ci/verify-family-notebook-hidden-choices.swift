import Foundation

// 11/20: the family notebook's 「表示しない」 choices after deleting the app.
// UserDefaults and Application Support are wiped; the device-only Keychain
// keeps a copy (FamilyHiddenOperationsMemory for entries, the representative
// photo client's `kept` store for hidden authors and reported photos).
// Synthetic people, IDs and stores only; no network.

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.check(message) } }

/// One Keychain service in memory; `failing` stands for a Keychain error.
private final class SyntheticKeychain: GroupSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]
    private var writeCount = 0
    var failing = false
    var values: [String: Data] { lock.lock(); defer { lock.unlock() }; return stored }
    var writes: Int { lock.lock(); defer { lock.unlock() }; return writeCount }
    func read(_ account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if failing { throw GroupClientError.authenticationRequired }; return stored[account]
    }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw GroupClientError.authenticationRequired }; writeCount += 1; stored[account] = data
    }
    func accounts(prefix: String) throws -> [String] { lock.lock(); defer { lock.unlock() }; return stored.keys.filter { $0.hasPrefix(prefix) } }
    func remove(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw GroupClientError.authenticationRequired }; stored.removeValue(forKey: account)
    }
}

/// Never answers: these checks make no request.
private struct NoNetwork: GroupHTTPTransport {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply { throw GroupClientError.offline }
}

@main private enum VerifyFamilyNotebookHiddenChoices {
    /// 「表示しない」 entries: @AppStorage's UserDefaults value and its Keychain copy.
    static func hiddenEntries() throws {
        var defaults: String?, keychain: SyntheticKeychain? = SyntheticKeychain()
        let memory = FamilyHiddenOperationsMemory.memory(defaults: { defaults }, setDefaults: { defaults = $0 }, keychain: { keychain })
        let first = UUID().uuidString, second = UUID().uuidString
        var checked = false
        try check(memory.read(checked: &checked) == "" && keychain?.writes == 0, "nothing hidden, nothing written")

        // 「表示しない」 twice.
        var ids = FamilyHiddenOperationsMemory.ids(defaults ?? "")
        ids.insert(first); memory.write(FamilyHiddenOperationsMemory.text(ids))
        ids.insert(second); memory.write(FamilyHiddenOperationsMemory.text(ids))
        let both = FamilyHiddenOperationsMemory.text([first, second])
        try check(defaults == both, "UserDefaults holds both entries")
        try check(keychain?.values[FamilyHiddenOperationsMemory.account] == Data(both.utf8)
                  && keychain?.values[GroupRememberedName.account] == nil, "the Keychain copy is under its own account, not the name's")

        // Deleting the app: UserDefaults is gone, the Keychain stays; a new process opens the notebook.
        defaults = nil; checked = false
        try check(memory.read(checked: &checked) == both && defaults == both, "both entries stay hidden after a reinstall")
        try check(FamilyHiddenOperationsMemory.ids(defaults ?? "") == [first, second], "the same two entries")

        // 「表示する」 on one, then on the other: the copy follows, and none comes back.
        ids.remove(first); memory.write(FamilyHiddenOperationsMemory.text(ids))
        defaults = nil; checked = false
        try check(memory.read(checked: &checked) == second, "a shown entry stays shown after a reinstall")
        ids.remove(second); memory.write(FamilyHiddenOperationsMemory.text(ids))
        try check(keychain?.values[FamilyHiddenOperationsMemory.account] == nil, "nothing hidden: the Keychain item is removed")
        defaults = nil; checked = false
        try check(memory.read(checked: &checked) == "" && (defaults ?? "") == "", "nothing comes back after a reinstall")

        // An install from before: hidden in UserDefaults only, copied once (not on every read).
        keychain = SyntheticKeychain(); defaults = first; checked = false
        try check(memory.read(checked: &checked) == first && keychain?.writes == 1, "copied into the Keychain once")
        for _ in 0..<3 { _ = memory.read(checked: &checked) }
        try check(keychain?.writes == 1, "later reads in the process touch only UserDefaults")

        // A failing Keychain: the choice still holds in UserDefaults.
        keychain?.failing = true
        memory.write(both)
        try check(defaults == both, "a failing Keychain still keeps UserDefaults")
    }

    /// The representative photo's 「表示しない」 and reported photos.
    static func photoVisibility() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-hidden-choices-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = URL(string: "https://fixture.invalid")!, family = UUID()
        let me = GroupDeviceIdentity.firstDevice(), author = GroupDeviceIdentity.firstDevice().personID
        let kept = SyntheticKeychain()
        func journal(_ name: String) throws -> GroupOperationStore {
            try GroupOperationStore(directory: root.appendingPathComponent(name, isDirectory: true), maximumRecordBytes: 2_100_000)
        }
        func client(_ journal: any GroupSecretStore, kept: (any GroupSecretStore)?) -> FamilyNotebookRepresentativePhotoClient {
            FamilyNotebookRepresentativePhotoClient(familyID: family, endpoint: endpoint, identity: me, transport: NoNetwork(),
                                                    journal: journal, runtimeEnabled: true, kept: kept)
        }

        let installed = client(try journal("first"), kept: kept)
        try await installed.hideAuthor(author)
        try check(try await installed.hiddenAuthors() == [author], "hidden on this install")
        try check(kept.writes == 1, "one Keychain write for the tap")
        for _ in 0..<3 { _ = try await installed.hiddenAuthors() }
        try check(kept.writes == 1, "reads write nothing")

        // Deleting the app: a new, empty journal; the notebook's Keychain stays.
        let reinstalled = client(try journal("second"), kept: kept)
        try check(try await reinstalled.hiddenAuthors() == [author], "the author stays hidden after a reinstall")
        try check(kept.writes == 1, "restoring writes only the new journal")

        // 「表示する」: the copy follows; the next reinstall shows the author.
        try await reinstalled.unhideAuthor(author)
        let again = client(try journal("third"), kept: kept)
        try check(try await again.hiddenAuthors().isEmpty, "a shown author stays shown after a reinstall")

        // An install from before the copy: the journal alone is kept once.
        let older = try journal("older"), fresh = SyntheticKeychain()
        try await client(older, kept: nil).hideAuthor(author)
        let upgraded = client(older, kept: fresh)
        try check(try await upgraded.hiddenAuthors() == [author] && fresh.writes == 1, "an older journal is copied once")
        _ = try await upgraded.hiddenAuthors()
        try check(fresh.writes == 1, "and not again")
        try check(try await client(try journal("older-reinstalled"), kept: fresh).hiddenAuthors() == [author],
                  "the copied choice survives the next reinstall")

        // A failing Keychain: the choice still holds in the journal.
        let failing = SyntheticKeychain(); failing.failing = true
        let unlucky = client(try journal("failing"), kept: failing)
        try await unlucky.hideAuthor(author)
        try check(try await unlucky.hiddenAuthors() == [author], "a failing Keychain still hides on this install")
    }

    static func main() async {
        do {
            try hiddenEntries()
            try await photoVisibility()
            // The screens' wiring (SwiftUI, so checked as text): every change is
            // kept, and the notebook restores once when it opens.
            let view = try String(contentsOfFile: "NekoWidget/Views/FamilyNotebookView.swift", encoding: .utf8)
            try check(view.components(separatedBy: "@AppStorage(FamilyHiddenOperationsMemory.defaultsKey)").count == 3
                      && !view.contains("@AppStorage(\"family.hiddenOperations.v1\")"), "both screens read the same key")
            try check(view.components(separatedBy: "FamilyHiddenOperations.keep(hiddenOperationIDs)").count == 3,
                      "「表示しない」 and 「表示する」 keep the copy")
            try check(view.contains(".task(id: model.hasFamily) {\n            FamilyHiddenOperations.restore()"),
                      "the notebook restores the copy when it opens")
            let service = try String(contentsOfFile: "NekoWidget/Services/ProductionFamilyNotebookSharingService.swift", encoding: .utf8)
            try check(service.contains("kept: session.secrets)"), "the photo client keeps its copy in the notebook's Keychain")
            print("Family notebook hidden choices: entries, hidden authors and the Keychain copy checks passed")
        } catch {
            FileHandle.standardError.write(Data("Family notebook hidden choices check failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
