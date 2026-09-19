import CryptoKit
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
private func rejects(_ message: String, _ action: () throws -> Void) {
    do { try action() } catch { return }
    fatalError(message)
}

@main
struct VerifyFamilyRecords {
    static func main() throws {
        let key = Data(repeating: 7, count: 32)
        let space = "fixture_record_space", author = "fixture_record_author"
        let id = UUID().uuidString.lowercased(), entryID = UUID().uuidString.lowercased()
        let text = String(repeating: "🐈‍⬛", count: 500)
        let payload = try FamilyRecordPayload.words(text)
        require(payload.text?.count == 500, "500 graphemes must be preserved")
        rejects("501 characters must not be truncated") { _ = try FamilyRecordPayload.words(text + "a") }
        rejects("Empty contribution must not be published") { _ = try FamilyRecordPayload.words(" \n ") }
        let multiline = try FamilyRecordPayload.words("  first\nsecond  ")
        require(multiline.text == "first\nsecond", "Only surrounding whitespace is trimmed")
        let sealed = try FamilyRecordCrypto.seal(payload, roomKey: key, spaceID: space, id: id,
            entryID: entryID, kind: .words, authorID: author, revision: 1)
        func row(authorID: String? = nil, parent: String? = nil, revision: Int = 1,
                 state: FamilyRecordRow.State = .active) -> FamilyRecordRow {
            FamilyRecordRow(id: id, entryID: parent ?? entryID, kind: .words, authorID: authorID ?? author,
                revision: revision, state: state, keyEpoch: 1, ciphertext: nil, createdAt: 100, updatedAt: 100)
        }
        let opened = try FamilyRecordCrypto.open(sealed, row: row(), roomKey: key, spaceID: space)
        require(opened.text == text, "Words round trip without caption truncation")
        for altered in [row(authorID: "different_author"), row(parent: UUID().uuidString.lowercased()),
                        row(revision: 2), row(state: .withdrawn)] {
            rejects("Author/parent/revision/withdrawal substitution must fail") {
                _ = try FamilyRecordCrypto.open(sealed, row: altered, roomKey: key, spaceID: space)
            }
        }
        rejects("Another window must not decrypt the words") {
            _ = try FamilyRecordCrypto.open(sealed, row: row(), roomKey: key, spaceID: "another_record_space")
        }
        var damaged = sealed; damaged[damaged.count - 1] ^= 1
        rejects("Tampered ciphertext must not be displayed") {
            _ = try FamilyRecordCrypto.open(damaged, row: row(), roomKey: key, spaceID: space)
        }
        let photo = FamilyRecordRow(id: entryID, entryID: entryID, kind: .photo, authorID: "photo_author",
            revision: 2, state: .withdrawn, keyEpoch: 1, ciphertext: nil, createdAt: 100, updatedAt: 101)
        let catalog = FamilyRecordCatalog(schemaVersion: 1, spaceID: space, participantID: author,
            maximumPhotos: 100, records: [photo, row()])
        _ = try catalog.validated(spaceID: space, participantID: author)
        require(catalog.records.count == 2, "Photo withdrawal does not remove another author's words")
        rejects("Duplicate record IDs must fail closed") {
            _ = try FamilyRecordCatalog(schemaVersion: 1, spaceID: space, participantID: author,
                maximumPhotos: 100, records: [photo, row(), row()]).validated(spaceID: space, participantID: author)
        }
        rejects("Foreign catalog must not become the current private window") {
            _ = try catalog.validated(spaceID: "other_space", participantID: author)
        }
        print("Family record text, authenticated context, withdrawal and catalog boundaries passed.")
    }
}
