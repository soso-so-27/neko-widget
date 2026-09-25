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
        let moment = "fixture_delivered_moment"
        let deliveredID = try FamilyRecordSourceIdentity.recordID(spaceID: space, momentID: moment)
        let receivedID = try FamilyRecordSourceIdentity.recordID(spaceID: space, momentID: moment)
        require(deliveredID == receivedID, "Sender and receiver must use the same photo entry without a new upload")
        require(deliveredID.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            options: .regularExpression) != nil, "Stable source identity must retain the existing relay UUID spelling")
        let otherSpaceID = try FamilyRecordSourceIdentity.recordID(spaceID: "another_record_space", momentID: moment)
        let otherMomentID = try FamilyRecordSourceIdentity.recordID(spaceID: space, momentID: "another_delivered_moment")
        require(deliveredID != otherSpaceID && deliveredID != otherMomentID, "Different windows or photos must never share an entry")
        rejects("Empty source identity must fail closed") {
            _ = try FamilyRecordSourceIdentity.recordID(spaceID: space, momentID: "")
        }
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
        let legacyMatch = try FamilyRecordSourceIdentity.existingPhoto(in: catalog, momentID: moment)
        require(legacyMatch == nil, "Legacy random records must not be associated by text or photographic likeness")
        let withdrawnSource = FamilyRecordRow(id: deliveredID, entryID: deliveredID, kind: .photo,
            authorID: "another_record_author", revision: 2, state: .withdrawn, keyEpoch: 1,
            ciphertext: nil, createdAt: 100, updatedAt: 101)
        let withdrawnCatalog = FamilyRecordCatalog(schemaVersion: 1, spaceID: space, participantID: author,
            maximumPhotos: 100, records: [withdrawnSource])
        let existingSource = try FamilyRecordSourceIdentity.existingPhoto(in: withdrawnCatalog, momentID: moment)
        require(existingSource == withdrawnSource, "A peer-owned or withdrawn source remains existing; never recreate or take ownership")
        _ = try catalog.validated(spaceID: space, participantID: author)
        require(catalog.records.count == 2, "Photo withdrawal does not remove another author's words")
        rejects("Duplicate record IDs must fail closed") {
            _ = try FamilyRecordCatalog(schemaVersion: 1, spaceID: space, participantID: author,
                maximumPhotos: 100, records: [photo, row(), row()]).validated(spaceID: space, participantID: author)
        }
        rejects("Foreign catalog must not become the current private window") {
            _ = try catalog.validated(spaceID: "other_space", participantID: author)
        }
        let otherPhotoID = UUID().uuidString.lowercased()
        let ownNote = FamilyRecordRow(id: UUID().uuidString.lowercased(), entryID: entryID,
            kind: .words, authorID: author, revision: 1, state: .active, keyEpoch: 1,
            ciphertext: nil, createdAt: 102, updatedAt: 103)
        let peerNote = FamilyRecordRow(id: UUID().uuidString.lowercased(), entryID: otherPhotoID,
            kind: .words, authorID: "other_author", revision: 1, state: .active, keyEpoch: 1,
            ciphertext: nil, createdAt: 105, updatedAt: 105)
        let removedNote = FamilyRecordRow(id: UUID().uuidString.lowercased(), entryID: otherPhotoID,
            kind: .words, authorID: author, revision: 2, state: .withdrawn, keyEpoch: 1,
            ciphertext: nil, createdAt: 104, updatedAt: 106)
        let activePhoto = FamilyRecordRow(id: otherPhotoID, entryID: otherPhotoID, kind: .photo,
            authorID: "other_author", revision: 1, state: .active, keyEpoch: 1,
            ciphertext: nil, createdAt: 100, updatedAt: 100)
        let portableRecords = [photo, activePhoto, ownNote, peerNote, removedNote]
        let portableWords = [ownNote.id: "自分の文章", peerNote.id: "相手の文章"]
        let withdrawnFiles = try FamilyRecordPortableFiles.files(index: 0, photo: photo,
            records: portableRecords, words: portableWords, participantID: author, image: nil)
        require(withdrawnFiles.map { $0.name } == ["001/メモ.txt"], "Withdrawn image must not be restored")
        let withdrawnText = String(data: withdrawnFiles[0].data, encoding: .utf8) ?? ""
        require(withdrawnText.contains("自分の文章") && withdrawnText.contains("写真: 取り下げ済み"),
            "Words must survive their photo's withdrawal")
        let activeFiles = try FamilyRecordPortableFiles.files(index: 1, photo: activePhoto,
            records: portableRecords, words: portableWords, participantID: author,
            image: FamilyRecordPhotoContent(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), capturedAt: nil))
        require(activeFiles.map { $0.name } == ["002/写真.jpg", "002/メモ.txt"], "Photo and notes must share a folder")
        let activeText = String(data: activeFiles[1].data, encoding: .utf8) ?? ""
        require(activeText.contains("相手の文章") && activeText.contains("書いた人: 相手") &&
            !activeText.contains("自分の文章") && !activeText.contains("取り下げた文章"),
            "Only this photo's active words and author may be exported")
        require(!(withdrawnText + activeText).contains(author) && !(withdrawnText + activeText).contains("other_author") &&
            !(withdrawnText + activeText).contains(entryID) && !(withdrawnText + activeText).contains(otherPhotoID),
            "Portable text must not disclose internal identifiers")
        rejects("Missing active words must fail the complete export") {
            _ = try FamilyRecordPortableFiles.files(index: 1, photo: activePhoto,
                records: portableRecords, words: [:], participantID: author,
                image: FamilyRecordPhotoContent(jpeg: Data([0xff, 0xd8]), capturedAt: nil))
        }
        print("Family record text, authenticated context, withdrawal and catalog boundaries passed.")
    }
}
