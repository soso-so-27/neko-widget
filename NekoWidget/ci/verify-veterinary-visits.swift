import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

@main enum VeterinaryVisitVerifier {
    struct Failure: Error { let message: String }
    static func require(_ result: Bool, _ message: String) throws { if !result { throw Failure(message: message) } }
    static func verifyLedgerRecovery(root: URL) async throws {
        let manager = FileManager.default
        let store = VeterinaryVisitStore(directory: root)
        try require(try await store.visits().isEmpty, "New absent directory was not empty")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try require(try await store.visits().isEmpty, "New empty directory was not empty")
        let visit = try await store.current(catID: UUID(), catName: "むぎ") { try $0() }
        let ledger = root.appendingPathComponent("state.json")
        let original = try Data(contentsOf: ledger)
        let photo = root.appendingPathComponent(UUID().uuidString + ".jpg")
        let photoBytes = Data([0xff, 0xd8, 0xff, 0xd9])
        try photoBytes.write(to: photo)
        try require(try await store.visits() == [visit], "Normal ledger failed")
        for corrupt in [false, true] {
            if corrupt { try Data("broken-ledger".utf8).write(to: ledger) }
            else { try manager.removeItem(at: ledger) }
            do { _ = try await store.visits(); throw Failure(message: "Missing/corrupt ledger became empty") }
            catch VeterinaryVisitError.storage {} catch VeterinaryVisitError.corrupted {}
            do {
                _ = try await store.current(catID: UUID(), catName: "別の猫") { _ in
                    throw Failure(message: "Unreadable ledger reached creation")
                }
                throw Failure(message: "Unreadable ledger accepted creation")
            } catch VeterinaryVisitError.storage {} catch VeterinaryVisitError.corrupted {}
            do { _ = try await store.save(visit, expectedRevision: visit.revision); throw Failure(message: "Unreadable ledger accepted edit") }
            catch VeterinaryVisitError.storage {} catch VeterinaryVisitError.corrupted {}
            do { try await store.delete(visitID: visit.id, expectedRevision: visit.revision); throw Failure(message: "Unreadable ledger accepted delete") }
            catch VeterinaryVisitError.storage {} catch VeterinaryVisitError.corrupted {}
            do { _ = try await store.cleanupPending(); throw Failure(message: "Unreadable ledger accepted cleanup") }
            catch VeterinaryVisitError.storage {} catch VeterinaryVisitError.corrupted {}
            try require(try Data(contentsOf: photo) == photoBytes, "Recovery path changed photo bytes")
            if corrupt { try require(try Data(contentsOf: ledger) == Data("broken-ledger".utf8), "Corrupt ledger overwritten") }
            else { try require(!manager.fileExists(atPath: ledger.path), "Missing ledger recreated") }
            try original.write(to: ledger)
            try require(try await store.visits() == [visit], "Restored ledger did not recover")
            // Restore a newer revision and another cat's record, then reuse the
            // old instance. Its stale edit/delete must preserve both records.
            struct RestoredState: Encodable { let schema = 1; let visits: [VeterinaryVisit] }
            var newer = visit; newer.revision = UUID(); newer.observations = "復元後の新しい記録"
            let additional = VeterinaryVisit(id: UUID(), catID: UUID(), catName: "別の猫", revision: UUID(),
                startedOn: nil, observations: "復元した別の記録", questions: "", entries: [], completedAt: nil)
            let restoredBytes = try JSONEncoder().encode(RestoredState(visits: [newer, additional]))
            try restoredBytes.write(to: ledger)
            do { _ = try await store.save(visit, expectedRevision: visit.revision); throw Failure(message: "Stale edit overwrote restored revision") }
            catch VeterinaryVisitError.changed {}
            do { try await store.delete(visitID: visit.id, expectedRevision: visit.revision); throw Failure(message: "Stale delete removed restored revision") }
            catch VeterinaryVisitError.changed {}
            try require(try Data(contentsOf: ledger) == restoredBytes, "Stale operation changed restored bytes")
            var edited = newer; edited.questions = "復元後の追記"
            let saved = try await store.save(edited, expectedRevision: newer.revision)
            let reopened = VeterinaryVisitStore(directory: root)
            let after = try await reopened.visits()
            try require(after.contains(saved) && after.contains(additional) && after.count == 2, "Post-recovery edit lost records")
            try require(try Data(contentsOf: photo) == photoBytes, "Post-recovery edit changed photo bytes")
            try original.write(to: ledger)
        }
    }

    static func main() async throws {
        let suiteRoot = FileManager.default.temporaryDirectory.appendingPathComponent("vet-verify-\(UUID())")
        defer { try? FileManager.default.removeItem(at: suiteRoot) }
        try await verifyLedgerRecovery(root: suiteRoot.appendingPathComponent("ledger-recovery"))
        let concurrentStore = VeterinaryVisitStore(directory: suiteRoot.appendingPathComponent("concurrent-edit"))
        let base = try await concurrentStore.current(catID: UUID(), catName: "同じ猫") { try $0() }
        var remote = base; remote.questions = "家族が書いた質問"
        _ = try await concurrentStore.save(remote, expectedRevision: base.revision)
        var typed = base; typed.observations = "入力中だった様子"
        let combined = try await concurrentStore.save(typed, expectedRevision: base.revision, base: base)
        try require(combined.questions == remote.questions && combined.observations == typed.observations, "an open editor erased a newly received field")
        let root = suiteRoot.appendingPathComponent("primary-store")
        let store = VeterinaryVisitStore(directory: root), owner = UUID(), otherOwner = UUID()
        let initial = try await store.visits()
        for invalid in ["", "   ", String(repeating: "猫", count: 201), "猫\0"] {
            do {
                _ = try await store.current(catID: UUID(), catName: invalid) { _ in
                    throw Failure(message: "Invalid name reached the creation boundary")
                }
                throw Failure(message: "Invalid name accepted")
            } catch VeterinaryVisitError.invalidName {}
            try require(try await store.visits() == initial, "Invalid name changed records")
        }
        // Previously valid whitespace names must remain readable, without a schema migration.
        struct LegacyState: Encodable { let schema = 1; let visits: [VeterinaryVisit] }
        let legacyRoot = suiteRoot.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacy = VeterinaryVisit(id: UUID(), catID: UUID(), catName: "   ", revision: UUID(),
            startedOn: nil, observations: "", questions: "", entries: [], completedAt: nil)
        try JSONEncoder().encode(LegacyState(visits: [legacy])).write(to: legacyRoot.appendingPathComponent("state.json"))
        let legacyStore = VeterinaryVisitStore(directory: legacyRoot)
        try require(try await legacyStore.visits() == [legacy], "Legacy whitespace name became unreadable")
        let reused = try await legacyStore.current(catID: legacy.catID, catName: "   ") { _ in
            throw Failure(message: "Existing legacy record invoked creation")
        }
        try require(reused == legacy, "Legacy draft was not reused")
        let capacityRoot = suiteRoot.appendingPathComponent("capacity")
        try FileManager.default.createDirectory(at: capacityRoot, withIntermediateDirectories: true)
        let full = (0..<100).map { _ in VeterinaryVisit(id: UUID(), catID: UUID(), catName: "猫", revision: UUID(),
            startedOn: nil, observations: "", questions: "", entries: [], completedAt: nil) }
        try JSONEncoder().encode(LegacyState(visits: full)).write(to: capacityRoot.appendingPathComponent("state.json"))
        let capacityStore = VeterinaryVisitStore(directory: capacityRoot)
        let capacityAdded = try await capacityStore.current(catID: UUID(), catName: "新しい猫") { try $0() }
        let afterCapacity = try await capacityStore.visits()
        try require(afterCapacity.count == 101 && afterCapacity.contains(capacityAdded), "The former 100-visit ceiling still blocked a new visit")
        try require(Set(afterCapacity.filter { $0.id != capacityAdded.id }.map(\.id)) == Set(full.map(\.id)), "Capacity migration changed prior visits")
        let first = try await store.current(catID: owner, catName: "同じ名前") { try $0() }
        let other = try await store.current(catID: otherOwner, catName: "同じ名前") { try $0() }
        try require(first.id != other.id, "same names merged cats")
        let existing = try await store.current(catID: owner, catName: "同じ名前") { _ in
            throw Failure(message: "Creation denied")
        }
        try require(existing == first, "Expiry blocked an existing draft")
        do {
            let before = try await store.visits()
            do {
                _ = try await store.current(catID: UUID(), catName: "新しい猫") { _ in
                    throw Failure(message: "Creation denied")
                }
                throw Failure(message: "Denied creation saved a new draft")
            } catch let denied as Failure { try require(denied.message == "Creation denied", "Creation boundary not invoked") }
            try require(try await store.visits() == before, "Denied creation changed records")
        }
        let value = PhotoMemoWeightValue(grams: 4200, measuredOn: "2026-09-29", catName: "同じ名前")
        let note = PhotoMemoryNote(text: "選んだ記録だけ", updatedAt: Date(), revision: UUID().uuidString,
            weight: PhotoMemoWeight(value: value, catID: owner))
        let source = PhotoMemoryNoteRecord(photoIdentifier: "private-photo", note: note)
        do {
            _ = try await store.add(source: source, jpeg: nil, to: first.id, expectedRevision: first.revision, confirmedTarget: false)
            throw Failure(message: "unconfirmed record was included")
        } catch VeterinaryVisitError.confirmationRequired { }
        do {
            _ = try await store.add(source: source, jpeg: nil, to: other.id, expectedRevision: other.revision, confirmedTarget: true)
            throw Failure(message: "other-cat weight was included")
        } catch VeterinaryVisitError.wrongCat { }
        let added = try await store.add(source: source, jpeg: nil, to: first.id, expectedRevision: first.revision, confirmedTarget: true)
        try require(added.entries.count == 1 && added.entries[0].weight == value, "selected snapshot incorrect")
        let reopened = VeterinaryVisitStore(directory: root)
        try require(try await reopened.visits().first { $0.id == first.id } == added, "snapshot not durable")
        let changedNote = PhotoMemoryNote(id: note.id, text: "元の記録を変更", updatedAt: Date(), revision: UUID().uuidString,
            weight: PhotoMemoWeight(value: PhotoMemoWeightValue(grams: 4300, measuredOn: nil, catName: "同じ名前"), catID: owner))
        let changed = PhotoMemoryNoteRecord(photoIdentifier: source.photoIdentifier, note: changedNote)
        do {
            _ = try await store.add(source: changed, jpeg: nil, to: first.id, expectedRevision: added.revision, confirmedTarget: true)
            throw Failure(message: "source edit silently replaced selected snapshot")
        } catch VeterinaryVisitError.changed { }
        let replaced = try await store.add(source: changed, jpeg: nil, to: first.id,
            expectedRevision: added.revision, confirmedTarget: true, replace: true)
        try require(replaced.entries.count == 1 && replaced.entries[0].weight?.grams == 4300, "explicit replacement duplicated or lost value")
        let removed = try await store.remove(entryID: replaced.entries[0].id, from: first.id, expectedRevision: replaced.revision)
        try require(removed.entries.isEmpty && source.note == note, "removal affected source")
        var completed = removed; completed.questions = "聞きたいこと"; completed.completedAt = Date()
        let saved = try await store.save(completed, expectedRevision: removed.revision)
        let next = try await store.current(catID: owner, catName: "同じ名前") { try $0() }
        try require(next.id != saved.id && next.entries.isEmpty && next.questions.isEmpty, "old consultation copied into next")
        let bytes = try Data(contentsOf: root.appendingPathComponent("state.json"))
        let corrupt = Data("{bad".utf8); try corrupt.write(to: root.appendingPathComponent("state.json"))
        do { _ = try await store.current(catID: owner, catName: "same") { try $0() }; throw Failure(message: "corrupt state replaced") }
        catch VeterinaryVisitError.corrupted { }
        try require(try Data(contentsOf: root.appendingPathComponent("state.json")) == corrupt, "corrupt bytes were overwritten")
        try bytes.write(to: root.appendingPathComponent("state.json"))
        try await store.delete(visitID: saved.id, expectedRevision: saved.revision)
        try require(try await store.visits().contains { $0.id == other.id }, "deleting consultation deleted other cat")
        try await verifiesOwnedPhotoCleanup(root.appendingPathComponent("photos"))
        try await verifiesResultsAfterConsultation(suiteRoot.appendingPathComponent("results"))
        try await verifiesVideosAndDayWeight(suiteRoot.appendingPathComponent("videos"))
        print("Veterinary visit boundaries passed: selection, identity, persistence, snapshots, replacement, removal, completion, results, videos, weight, corruption")
    }

    /// 11/8: 「先生の話」「出た薬」「次に行く日」 and the memo's own dates are
    /// optional. A memo saved before them still reads, and once 「診察済み」
    /// only those three can change.
    private static func verifiesResultsAfterConsultation(_ root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldID = UUID(), oldCat = UUID(), oldRevision = UUID()
        // The exact shape written before 11/8: none of the new keys.
        let oldJSON = "{\"schema\":1,\"visits\":[{\"id\":\"\(oldID.uuidString)\",\"catID\":\"\(oldCat.uuidString)\","
            + "\"catName\":\"むぎ\",\"revision\":\"\(oldRevision.uuidString)\",\"startedOn\":\"2026-10-01\","
            + "\"observations\":\"吐いた\",\"questions\":\"ごはんは？\",\"entries\":[],\"completedAt\":784000000}]}"
        try Data(oldJSON.utf8).write(to: root.appendingPathComponent("state.json"))
        let store = VeterinaryVisitStore(directory: root)
        guard let old = try await store.visits().first, old.id == oldID, old.revision == oldRevision else {
            throw Failure(message: "A memo saved before the results fields became unreadable")
        }
        try require(old.doctorNote == nil && old.prescription == nil && old.nextVisitOn == nil
            && old.createdAt == nil && old.updatedAt == nil && old.lastEditedAt == nil && !old.hasResults,
            "An old memo gained results or dates it never had")
        try require(old.observations == "吐いた" && old.questions == "ごはんは？" && old.startedOn == "2026-10-01"
            && old.completedAt == Date(timeIntervalSinceReferenceDate: 784_000_000), "An old memo changed while reading")

        // Finished: what was shown stays as it was.
        var rewritten = old; rewritten.observations = "書き換え"
        do { _ = try await store.save(rewritten, expectedRevision: old.revision); throw Failure(message: "A finished memo was rewritten") }
        catch VeterinaryVisitError.changed {}
        var results = old
        results.doctorNote = "胃腸炎。2日ほどで治る見込み"; results.prescription = "吐き気止め 1日1回・3日分"
        results.nextVisitOn = "2026-11-15"; results.observations = "書き換え"; results.questions = "書き換え"
        let saved = try await store.saveResults(results, expectedRevision: old.revision)
        try require(saved.doctorNote == results.doctorNote && saved.prescription == results.prescription
            && saved.nextVisitOn == "2026-11-15" && saved.hasResults, "Results after the consultation were not saved")
        try require(saved.observations == old.observations && saved.questions == old.questions && saved.startedOn == old.startedOn
            && saved.entries == old.entries && saved.completedAt == old.completedAt, "Saving results changed what was shown")
        try require(saved.revision != old.revision && saved.updatedAt != nil && saved.createdAt == nil, "Saving results kept the revision or invented a start day")
        try require(try await VeterinaryVisitStore(directory: root).visits() == [saved], "Results were not durable")
        do { _ = try await store.saveResults(results, expectedRevision: old.revision); throw Failure(message: "A stale results edit overwrote newer results") }
        catch VeterinaryVisitError.changed {}
        // An editor opened before another change keeps that change.
        var other = saved; other.prescription = "別の端末で書いた薬"
        let elsewhere = try await store.saveResults(other, expectedRevision: saved.revision)
        var typed = saved; typed.doctorNote = "入力中だった先生の話"
        let combined = try await store.saveResults(typed, expectedRevision: saved.revision, base: saved)
        try require(combined.doctorNote == typed.doctorNote && combined.prescription == elsewhere.prescription,
            "An open results editor erased a newer field")
        var tooLong = combined; tooLong.doctorNote = String(repeating: "猫", count: 501)
        do { _ = try await store.saveResults(tooLong, expectedRevision: combined.revision); throw Failure(message: "Over-long 先生の話 accepted") }
        catch VeterinaryVisitError.corrupted {}
        var badDay = combined; badDay.nextVisitOn = "2026-13-40"
        do { _ = try await store.saveResults(badDay, expectedRevision: combined.revision); throw Failure(message: "Invalid 次に行く日 accepted") }
        catch VeterinaryVisitError.corrupted {}
        try require(try await store.visits() == [combined], "A refused results edit changed the memo")

        // A new memo knows the day it was started; results can be written
        // before 「診察済み」 too, and never through the finished-memo path.
        let open = try await store.current(catID: oldCat, catName: "むぎ") { try $0() }
        try require(open.id != combined.id && open.createdAt != nil && open.updatedAt == nil && !open.hasResults,
            "A new memo has no start day or copied the last results")
        do { _ = try await store.saveResults(open, expectedRevision: open.revision); throw Failure(message: "An open memo went through the finished-memo path") }
        catch VeterinaryVisitError.changed {}
        var before = open; before.doctorNote = "診察の前に書いた先生の話"; before.nextVisitOn = "2026-11-20"
        let written = try await store.save(before, expectedRevision: open.revision)
        try require(written.doctorNote == before.doctorNote && written.nextVisitOn == "2026-11-20"
            && written.createdAt == open.createdAt && written.updatedAt != nil, "Results on an open memo were not saved")
        try require(try await VeterinaryVisitStore(directory: root).visits().contains(written), "Start and edit days were not durable")

        // Shared results (including clears) apply, while local memo dates stay.
        var received = written
        received.doctorNote = nil; received.prescription = nil; received.nextVisitOn = nil
        received.createdAt = nil; received.updatedAt = nil; received.revision = UUID()
        let cleared = VeterinaryVisitStore.keepingLocalResults([received], from: [written])[0]
        try require(cleared.doctorNote == nil && cleared.nextVisitOn == nil
            && cleared.createdAt == written.createdAt && cleared.updatedAt == written.updatedAt,
            "A received result clear was overwritten or changed local dates")
        var changedRemotely = received; changedRemotely.questions = "家族が書いた質問"
        changedRemotely.doctorNote = "家族が書いた先生の話"
        let merged = VeterinaryVisitStore.keepingLocalResults([changedRemotely], from: [written])
        try require(merged.count == 1 && merged[0].questions == changedRemotely.questions
            && merged[0].doctorNote == changedRemotely.doctorNote
            && merged[0].createdAt == written.createdAt && merged[0].revision == changedRemotely.revision,
            "A received family result or local date was lost")
    }

    private static func fixtureJPEG() throws -> Data {
#if canImport(ImageIO)
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try require(CGImageDestinationFinalize(destination), "native JPEG fixture failed")
        return output as Data
#else
        return Data([0xff, 0xd8, 0xff, 0xe0, 1, 0xff, 0xd9])
#endif
    }

    /// 11/9: a video is an entry whose first frame is its photo copy; its
    /// length is kept beside the memos, so older versions still read them.
    /// The day's weight is read from 「この子のこと」, never one measured later.
    private static func verifiesVideosAndDayWeight(_ root: URL) async throws {
        let store = VeterinaryVisitStore(directory: root)
        let cat = UUID()
        let visit = try await store.current(catID: cat, catName: "むぎ") { try $0() }
        let jpeg = try fixtureJPEG()
        func shot(_ identifier: String) -> PhotoMemoryNoteRecord {
            PhotoMemoryNoteRecord(photoIdentifier: identifier, note: PhotoMemoryNote(text: "", updatedAt: Date(),
                revision: UUID().uuidString, context: PhotoMemoryNoteContext(capturedAt: Date(timeIntervalSinceReferenceDate: 800_000_000), cats: [.init(id: cat, name: "むぎ")])))
        }
        let ledger = root.appendingPathComponent("state.json")
        let before = try Data(contentsOf: ledger)
        // Without a first frame, without its identifier or with an impossible
        // length, a video is refused and nothing is written.
        let refused: [(String, Data?, Double)] = [("video-1", nil, 12), ("", jpeg, 12), ("video-1", jpeg, -1),
                                                  ("video-1", jpeg, .nan), ("video-1", jpeg, .infinity), ("video-1", jpeg, 86_401)]
        for (identifier, frame, seconds) in refused {
            do {
                _ = try await store.add(source: shot(identifier), jpeg: frame, to: visit.id, expectedRevision: visit.revision,
                    confirmedTarget: true, videoSeconds: seconds)
                throw Failure(message: "An incomplete video was accepted")
            } catch VeterinaryVisitError.changed {}
            try require(try Data(contentsOf: ledger) == before, "A refused video changed the memo")
        }
        let video = shot("video-1")
        let added = try await store.add(source: video, jpeg: jpeg, to: visit.id, expectedRevision: visit.revision,
            confirmedTarget: true, videoSeconds: 12.4)
        let entry = added.entries[0]
        try require(entry.photoFile != nil && entry.sourcePhotoIdentifier == "video-1", "A video lost its first frame or identifier")
        try require(try await store.videoDurations() == [entry.id: 12.4], "A video's length was not kept")
        try require(try await VeterinaryVisitStore(directory: root).videoDurations() == [entry.id: 12.4], "A video's length was not durable")
        // An older version reads the same file: the memo and its first frame.
        struct OlderState: Decodable { let schema: Int; let visits: [VeterinaryVisit]; let retiredPhotoFiles: [String]? }
        let older = try JSONDecoder().decode(OlderState.self, from: Data(contentsOf: ledger))
        try require(older.visits == [added], "An older version could not read a memo with a video")
        // 1109e: receiving all three results rewrites the visit, but must not
        // erase its separate video-length table or private first-frame bytes.
        let frameURL = root.appendingPathComponent(entry.photoFile!)
        let frameBytes = try Data(contentsOf: frameURL)
        try await store.receiveFamilyChanges { local in
            var received = local
            received[0].doctorNote = "家族が書いた先生の話"
            received[0].prescription = "家族が書いた薬"
            received[0].nextVisitOn = "2026-11-20"
            received[0].createdAt = nil; received[0].updatedAt = nil
            received[0].revision = UUID()
            return received
        }
        let reopened = VeterinaryVisitStore(directory: root)
        let received = try await reopened.visits()[0]
        try require(received.doctorNote == "家族が書いた先生の話"
            && received.prescription == "家族が書いた薬" && received.nextVisitOn == "2026-11-20",
            "Family consultation results did not survive the real store write")
        try require(received.createdAt == added.createdAt && received.updatedAt == added.updatedAt,
            "Family receive changed device-local memo dates")
        try require(try await reopened.videoDurations() == [entry.id: 12.4],
            "Receiving consultation results erased the video sidecar")
        try require(try Data(contentsOf: frameURL) == frameBytes, "Family receive changed the private first frame")
        let receivedBytes = try Data(contentsOf: ledger)
        try await reopened.receiveFamilyChanges { $0 }
        try require(try Data(contentsOf: ledger) == receivedBytes, "Unchanged family projection rewrote the store")
        try await reopened.receiveFamilyChanges { local in
            var received = local
            received[0].doctorNote = nil; received[0].prescription = nil; received[0].nextVisitOn = nil
            received[0].revision = UUID()
            return received
        }
        let clearedReceived = try await VeterinaryVisitStore(directory: root).visits()[0]
        try require(!clearedReceived.hasResults, "Local results overwrote a received explicit clear")
        try require(try await VeterinaryVisitStore(directory: root).videoDurations() == [entry.id: 12.4],
            "Clearing consultation results erased the video sidecar")
        print("Family results receive/clear: video sidecar, local dates and private first frame preserved")
        // A photo next to it is not a video; replacing the video with a photo drops its length.
        let photo = try await store.add(source: shot("photo-1"), jpeg: jpeg, to: visit.id, expectedRevision: clearedReceived.revision, confirmedTarget: true)
        try require(try await store.videoDurations() == [entry.id: 12.4], "A photo became a video")
        let asPhoto = try await store.add(source: video, jpeg: jpeg, to: visit.id, expectedRevision: photo.revision,
            confirmedTarget: true, replace: true)
        try require(try await store.videoDurations().isEmpty && asPhoto.entries.count == 2, "A replaced video kept its length")
        let again = try await store.add(source: video, jpeg: jpeg, to: visit.id, expectedRevision: asPhoto.revision,
            confirmedTarget: true, replace: true, videoSeconds: 3)
        let againEntry = again.entries.first { $0.sourceNoteID == video.id }!
        try require(try await store.videoDurations() == [againEntry.id: 3], "A video chosen again lost its length")
        // Taking it off the memo leaves no length behind.
        let removed = try await store.remove(entryID: againEntry.id, from: visit.id, expectedRevision: again.revision)
        try require(try await store.videoDurations().isEmpty, "A removed video kept its length")
        let afterRemoval = try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as! [String: Any]
        try require(afterRemoval["videoSeconds"] == nil, "A removed video's length stayed in the file")
        // A memo saved before videos reads with none.
        let withVideo = try await store.add(source: shot("video-2"), jpeg: jpeg, to: visit.id, expectedRevision: removed.revision,
            confirmedTarget: true, videoSeconds: 30)
        var state = try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as! [String: Any]
        let saved = try Data(contentsOf: ledger)
        state["videoSeconds"] = nil
        try JSONSerialization.data(withJSONObject: state).write(to: ledger)
        let withoutLengths = try await store.visits()
        try require(try await store.videoDurations().isEmpty && withoutLengths == [withVideo],
            "A memo without video lengths did not read as before")
        // Impossible lengths, keys and counts are refused, never guessed.
        let videoID = withVideo.entries.first { $0.sourcePhotoIdentifier == "video-2" }!.id.uuidString
        let impossible: [[String: Any]] = [[videoID: -5], ["not-a-uuid": 3],
                                           [videoID: 3, UUID().uuidString: 3, UUID().uuidString: 3]]
        for bad in impossible {
            state["videoSeconds"] = bad
            try JSONSerialization.data(withJSONObject: state).write(to: ledger)
            do { _ = try await store.videoDurations(); throw Failure(message: "An impossible video length was read") }
            catch VeterinaryVisitError.corrupted {}
        }
        try saved.write(to: ledger)
        try require(try await store.videoDurations().count == 1, "Restored video length did not read")

        let lengths: [(Double, String)] = [(0, "0:00"), (12.4, "0:12"), (65, "1:05"), (3723, "1:02:03"), (.nan, "0:00")]
        for (seconds, text) in lengths {
            try require(VeterinaryVisitEntry.durationText(seconds) == text, "A video length read as " + VeterinaryVisitEntry.durationText(seconds))
        }
        let weights: [(day: String, grams: Int)] = [(day: "2026-11-01", grams: 4200), (day: "2026-11-09", grams: 4300),
                                                    (day: "2026-11-20", grams: 4400), (day: "bad", grams: 9999)]
        let today = VeterinaryVisitWeight.latest(weights, onOrBefore: "2026-11-09")
        try require(today?.day == "2026-11-09" && today?.grams == 4300, "The day's weight was not the newest on that day")
        let past = VeterinaryVisitWeight.latest(weights, onOrBefore: "2026-11-05")
        try require(past?.day == "2026-11-01" && past?.grams == 4200, "A past memo showed a weight measured later")
        try require(VeterinaryVisitWeight.latest(weights, onOrBefore: "2026-10-01") == nil, "A weight from after the memo was shown")
    }

    private static func verifiesOwnedPhotoCleanup(_ root: URL) async throws {
        let store = VeterinaryVisitStore(directory: root)
        let visit = try await store.current(catID: UUID(), catName: "むぎ") { try $0() }
        let note = PhotoMemoryNote(text: "", updatedAt: Date(), revision: UUID().uuidString)
        let source = PhotoMemoryNoteRecord(photoIdentifier: "original-photo-not-a-file", note: note)
        let jpeg: Data
#if canImport(ImageIO)
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try require(CGImageDestinationFinalize(destination), "native JPEG fixture failed")
        jpeg = output as Data
#else
        // Foundation boundary only; real JPEG decoding is exercised on Apple.
        jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 1, 0xff, 0xd9])
#endif
        let added = try await store.add(source: source, jpeg: jpeg, to: visit.id, expectedRevision: visit.revision, confirmedTarget: true)
        let first = added.entries[0]
        try require(try await store.image(for: first, visitID: visit.id) == jpeg, "owned JPEG not durable")
        let replaced = try await store.add(source: source, jpeg: jpeg, to: visit.id,
            expectedRevision: added.revision, confirmedTarget: true, replace: true)
        try require(first.photoFile != replaced.entries[0].photoFile
            && !FileManager.default.fileExists(atPath: root.appendingPathComponent(first.photoFile!).path), "replaced photo retained")
        let external = root.appendingPathComponent("unrelated-sentinel.txt")
        try Data("keep".utf8).write(to: external)
        try await store.delete(visitID: visit.id, expectedRevision: replaced.revision)
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(replaced.entries[0].photoFile!).path)
            && FileManager.default.fileExists(atPath: external.path), "delete escaped consultation-owned photo")
        let next = try await store.current(catID: UUID(), catName: "そら") { try $0() }
        let url = root.appendingPathComponent("state.json")
        var state = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        state["retiredPhotoFiles"] = (0..<2000).map { _ in UUID().uuidString + ".jpg" }
        let bounded = try JSONSerialization.data(withJSONObject: state); try bounded.write(to: url)
        do {
            _ = try await store.add(source: source, jpeg: jpeg, to: next.id, expectedRevision: next.revision, confirmedTarget: true)
            throw Failure(message: "cleanup intent overflow accepted")
        } catch VeterinaryVisitError.storage { }
        try require(try Data(contentsOf: url) == bounded, "overflow wrote an unreadable manifest")
        try require(try await store.visits().contains(next), "overflow hid healthy consultation")
        try require(try await store.cleanupPending() == false, "missing retired files could not be recovered")
        var invalid = state; invalid["retiredPhotoFiles"] = ["../unrelated-sentinel.txt"]
        let invalidBytes = try JSONSerialization.data(withJSONObject: invalid); try invalidBytes.write(to: url)
        do { _ = try await store.cleanupPending(); throw Failure(message: "invalid deletion target accepted") }
        catch VeterinaryVisitError.corrupted { }
        try require(FileManager.default.fileExists(atPath: external.path) && (try Data(contentsOf: url)) == invalidBytes,
                    "invalid cleanup changed manifest or external file")
    }
}
