import Foundation

// 11/20: the name a member writes under after deleting the app wiped the
// remembered one (FamilyNotebookAuthorName). Synthetic names and stores only.

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.check(message) } }

@main private enum VerifyFamilyNotebookAuthorName {
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
        print("Family notebook author name: own writing, admission name and the unnamed word checks passed")
    }
}
