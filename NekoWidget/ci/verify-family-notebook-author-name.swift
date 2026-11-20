import Foundation

// 11/20: the name a member writes under after deleting the app wiped the
// remembered one (FamilyNotebookAuthorName). Synthetic names and stores only.

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.check(message) } }

/// One Keychain service in memory; `failing` stands for a Keychain error.
private final class SyntheticKeychain: GroupSecretStore, @unchecked Sendable {
    var values: [String: Data] = [:], writes = 0, failing = false
    func read(_ account: String) throws -> Data? {
        if failing { throw GroupClientError.authenticationRequired }; return values[account]
    }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        if failing { throw GroupClientError.authenticationRequired }; writes += 1; values[account] = data
    }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}

@main private enum VerifyFamilyNotebookAuthorName {
    /// GroupDisplayName's memory over a synthetic UserDefaults value and Keychain.
    static func rememberedName() throws {
        var defaults: String?, keychain: SyntheticKeychain? = SyntheticKeychain()
        let memory = GroupRememberedName(defaults: { defaults }, setDefaults: { defaults = $0 }, keychain: { keychain })
        var checked = false
        try check(memory.read(checked: &checked) == "" && keychain?.writes == 0, "nothing remembered, nothing written")
        memory.write("合成のなまえ")
        try check(defaults == "合成のなまえ" && keychain?.values[GroupRememberedName.account] == Data("合成のなまえ".utf8),
                  "remember writes UserDefaults and the Keychain")
        // Deleting the app: UserDefaults is gone, the Keychain stays; a new process reads.
        defaults = nil; checked = false
        try check(memory.read(checked: &checked) == "合成のなまえ" && defaults == "合成のなまえ", "the Keychain's name comes back into UserDefaults")
        // An install from before: the name only in UserDefaults is copied once, not on every read.
        keychain = SyntheticKeychain(); defaults = "合成の前から"; checked = false
        try check(memory.read(checked: &checked) == "合成の前から" && keychain?.writes == 1, "copied into the Keychain once")
        for _ in 0..<3 { _ = memory.read(checked: &checked) }
        checked = false
        _ = memory.read(checked: &checked)
        try check(keychain?.writes == 1, "the same name is not written again (\(keychain?.writes ?? -1) writes)")
        // Keychain failures and no Keychain: today's behaviour.
        keychain?.failing = true; defaults = nil; checked = false
        try check(memory.read(checked: &checked) == "", "a failing Keychain reads as nothing")
        memory.write("合成の失敗")
        try check(defaults == "合成の失敗", "a failing Keychain still keeps UserDefaults")
        keychain = nil; defaults = nil; checked = false
        try check(memory.read(checked: &checked) == "", "no Keychain reads as nothing")
    }

    /// Who wrote an entry: the unnamed word never hides a known name.
    static func shownNames(_ snapshot: FamilyNotebookSnapshot, me: String, other: FamilyNotebookAuthor) throws {
        let unnamed = FamilyNotebookAuthorName.unnamed
        let lost = FamilyNotebookAuthor(personID: me, displayName: unnamed)
        try check(FamilyNotebookAuthorName.shown(lost, operations: snapshot.operations) == "合成の今の名前",
                  "the newest real name of the person's writing")
        try check(FamilyNotebookAuthorName.shown(other, operations: snapshot.operations) == "合成の家族", "a real name stays")
        let stranger = FamilyNotebookAuthor(personID: "synthetic-new", displayName: unnamed)
        try check(FamilyNotebookAuthorName.shown(stranger, operations: snapshot.operations, known: ["synthetic-new": "合成の受け入れ名"])
                  == "合成の受け入れ名", "else the admission's name")
        try check(FamilyNotebookAuthorName.shown(stranger, operations: snapshot.operations, known: ["synthetic-new": unnamed]) == unnamed
                  && FamilyNotebookAuthorName.shown(stranger, operations: []) == unnamed, "nothing known: the unnamed word")
        try check(FamilyNotebookAuthorName.shownAuthor(lost, operations: snapshot.operations)
                  == FamilyNotebookAuthor(personID: me, displayName: "合成の今の名前"), "shownAuthor keeps the person")
    }

    static func main() throws {
        let unnamed = FamilyNotebookAuthorName.unnamed
        try check(unnamed == "家族の人", "the unnamed word is the members list's")

        // The person's own writing first, newest valid name.
        var found = FamilyNotebookAuthorName.recovered(written: ["合成の新しい名前", "合成の古い名前"], known: "合成の受け入れ名")
        try check(found.name == "合成の新しい名前" && found.remember, "the newest own name is taken and kept")
        found = FamilyNotebookAuthorName.recovered(written: ["  ", unnamed, "合成の古い名前"], known: nil)
        try check(found.name == "合成の古い名前" && found.remember, "blank and unnamed own names are skipped")
        // Then the name the family's admission gave.
        found = FamilyNotebookAuthorName.recovered(written: [], known: "合成の受け入れ名")
        try check(found.name == "合成の受け入れ名" && found.remember, "the admission's name is taken and kept")
        // Neither: the unnamed word, never kept.
        for known in [nil, "", unnamed, String(repeating: "猫", count: 40)] as [String?] {
            found = FamilyNotebookAuthorName.recovered(written: [], known: known)
            try check(found.name == unnamed && !found.remember, "nothing usable: unnamed, not kept (\(known ?? "nil"))")
        }

        // Own writing in a notebook copy, newest first; others' writing is not taken.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-author-name-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let family = UUID(), cat = UUID()
        let store = try FamilyNotebookStore(directory: root, familyID: family, deviceID: "synthetic-device")
        let me = "synthetic-me", other = FamilyNotebookAuthor(personID: "synthetic-other", displayName: "合成の家族")
        try store.edit(target: .init(familyCatID: cat, field: .marks), value: .text("1"), author: .init(personID: me, displayName: "合成の前の名前"))
        try store.edit(target: .init(familyCatID: cat, field: .coat), value: .text("2"), author: .init(personID: me, displayName: "合成の今の名前"))
        try store.edit(target: .init(familyCatID: cat, field: .temperament), value: .text("3"), author: other)
        let snapshot = try store.snapshot()
        try check(FamilyNotebookAuthorName.written(by: me, in: snapshot) == ["合成の今の名前", "合成の前の名前"], "own names, newest first")
        try check(FamilyNotebookAuthorName.written(by: "synthetic-nobody", in: snapshot).isEmpty, "no writing, no names")
        try check(FamilyNotebookAuthorName.written(by: me, in: nil).isEmpty, "no copy, no names")
        try shownNames(snapshot, me: me, other: other)
        try rememberedName()
        print("Family notebook author name: own writing, admission name, the unnamed word, shown names and the Keychain copy checks passed")
    }
}
