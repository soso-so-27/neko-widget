import Foundation

// The five two-device scenarios. Each one makes its own family with fresh
// synthetic people, so a failure in one does not leave state for the next.
//
// Not driven anywhere here (they need UIKit, a singleton or a route the
// local Worker does not offer); each scenario's PASS line names its gap:
// - FamilyNotebookSharing.shared / FamilyNotebookAutoCheck.shared /
//   FamilyRepresentativePhotos.shared (UIKit, UserDefaults.standard):
//   reads are driven as their passes call the service, one at a time.
// - The recovery catalog (POST /v3/group-recovery/catalog): the Worker
//   refuses it unless ENVIRONMENT is production or staging, and the local
//   one runs as `local`. The catalog's answer (scope, person, family) is
//   computed here from the same key; the device keys, the registration,
//   the link and the identity choice are the app's own code.

struct Family {
    let a: Device, b: Device
    let id: UUID, cat: UUID
    /// After B's first device registered in the notebook (the relay sends
    /// one device wake-up per family per 2-minute window).
    let joinedAt: Date
}

@MainActor enum Scenarios {
    typealias Run = @MainActor (Relay) async throws -> String?
    static let all: [(String, String, Run)] = [
        ("S1", "create, invite, join, approve", s1),
        ("S2", "representative photo: read, replace, cancelled read", s2),
        ("S3", "the creator's second iPhone", s3),
        ("S4", "member B deletes and reinstalls the app (PR #1090)", s4),
        ("S5", "member B changes iPhone, then reports A's photo", s5),
    ]

    // MARK: Common steps

    static func makeFamily(_ relay: Relay) async throws -> Family {
        Log.step("A: a Sandbox billing account with test Plus")
        let billing = try await relay.bootstrapBilling()
        try await relay.grantPlus(billing)
        let a = try await Device.make("A", relay: relay, cloud: PersonCloud(), billing: billing)

        Log.step("A creates the family notebook")
        let id = UUID()
        try await a.service.createFamily(operationID: id)
        try await settle("A's first key", [a]) { a.inFamily }
        try expect(a.service.currentFamilyID == id, "A's notebook is the one it created")
        a.cloud.publish(a.notebookIdentity?.personPrivateKey)

        Log.step("A shares one cat")
        let store = try required(a.service.notebook, "A has no notebook copy")
        let author = try required(a.service.author, "A has no author")
        let cat = UUID()
        try store.applyLocalChanges(.init(familyID: id, entries: [
            .init(ledgerKey: "cat:e2e:name", target: .init(familyCatID: cat, field: .name), value: .text("合成のしろ"), editedAt: Date()),
        ], mappings: [.init(sourceKey: "cat:e2e", familyCatID: cat, toolCatID: UUID())]), author: author)
        try await settle("A's cat sent", [a]) { try store.pendingOperations().isEmpty }

        Log.step("A invites; B opens the link and asks to join")
        let invitation = try await a.service.createInvitation(operationID: UUID())
        let b = try await Device.make("B", relay: relay, cloud: PersonCloud())
        let preview = try await b.service.previewInvitation(invitation.link)
        try expect(preview.catNames == ["合成ねこ"], "B sees the invitation's cat names (got \(preview.catNames))")
        _ = try await b.service.join(preview, operationID: UUID())
        let waiting = await b.pass()
        try expect(waiting == .pendingApproval, "B waits for approval (got \(String(describing: waiting)))")
        b.cloud.publish(b.notebookIdentity?.personPrivateKey)

        Log.step("A approves B")
        let requests = try await a.service.pendingRequests()
        try expect(requests.count == 1 && requests.first?.personID == b.notebookIdentity?.personID,
                   "A sees exactly B's request (got \(requests.count))")
        try await a.service.decide(requestID: requests[0].id, approve: true, operationID: UUID())

        Log.step("The keys reach both iPhones")
        try await settle("both in the family with keys", [b, a]) { a.inFamily && b.inFamily }
        return Family(a: a, b: b, id: id, cat: cat, joinedAt: Date())
    }

    /// `device` sends a new photo of the cat, then reads it back.
    static func deliver(_ device: Device, _ cat: UUID, shade: Int) async throws -> (asset: UUID, jpeg: Data) {
        try expect(device.service.representativePhotoWritable, "\(device.name) can write the photo")
        try await device.service.deliverRepresentativePhoto(familyCatID: cat, source: syntheticJPEG(shade))
        let asset = try required(device.service.representativePhotoAsset(familyCatID: cat), "\(device.name)'s copy names its new photo")
        let load = try await device.photo(cat)
        guard case .shown(let shown, _, let jpeg)? = load, shown == asset else {
            throw E2EFailure(description: "\(Log.location): \(device.name) reads its own photo as \(String(describing: load))")
        }
        Log.note("\(device.name) delivered photo \(asset.uuidString.prefix(8)) (\(jpeg.count) bytes)")
        return (asset, jpeg)
    }

    /// `device` reads until its copy names `asset`, then reads its pixels.
    static func seePhoto(_ device: Device, _ cat: UUID, asset: UUID) async throws -> (author: String, jpeg: Data) {
        try await settle("\(device.name)'s copy names photo \(asset.uuidString.prefix(8))", [device]) {
            device.service.representativePhotoAsset(familyCatID: cat) == asset
        }
        let load = try await device.photo(cat)
        guard case .shown(let shown, let author, let jpeg)? = load, shown == asset else {
            throw E2EFailure(description: "\(Log.location): \(device.name) reads the photo as \(String(describing: load))")
        }
        return (author, jpeg)
    }

    // MARK: S1

    static func s1(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)

        Log.step("Both iPhones hold the notebook key")
        // .inFamily is returned only when the key material is ready.
        try expect(f.a.inFamily && f.b.inFamily, "both read the notebook with its key")

        Log.step("Both iPhones registered the notebook's push on the relay")
        let route = "/v3/family-notebooks/" + f.id.uuidString.lowercased() + "/push-subscription"
        for device in [f.a, f.b] {
            let id = try required(device.notebookDeviceID, "\(device.name) has no notebook device")
            let accepted = relay.transport.log.filter { $0.device == id && $0.method == "POST" && $0.path == route && $0.status == 200 }
            try expect(!accepted.isEmpty, "the relay accepted \(device.name)'s push subscription")
        }

        Log.step("B sees exactly one cat row")
        let snapshot = try required(f.b.service.notebook, "B has no notebook copy").snapshot()
        let cats = Set(snapshot.operations.filter { $0.target.collection == .cat && $0.target.field == .name }.map(\.target.familyCatID))
        try expect(cats == [f.cat], "B's notebook has \(cats.count) cat rows")
        return nil
    }

    // MARK: S2

    static func s2(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)
        let creator = try required(f.a.notebookIdentity?.personID, "A has no person")

        Log.step("A puts a photo on the cat")
        let first = try await deliver(f.a, f.cat, shade: 1)

        Log.step("B reads the same pixels")
        let seen = try await seePhoto(f.b, f.cat, asset: first.asset)
        try expect(seen.author == creator, "the photo is A's")
        try expect(seen.jpeg == first.jpeg, "B's pixels are the ones A reads")

        Log.step("A replaces the photo")
        let second = try await deliver(f.a, f.cat, shade: 2)
        try expect(second.asset != first.asset && second.jpeg != first.jpeg, "a new photo, new pixels")

        Log.step("B's read of the new photo is cancelled")
        try await settle("B's copy names the new photo", [f.b]) {
            f.b.service.representativePhotoAsset(familyCatID: f.cat) == second.asset
        }
        relay.transport.cancelNextRead(device: try required(f.b.notebookDeviceID, "B has no device"), contains: "/assets/")
        do {
            let load = try await f.b.photo(f.cat)
            throw E2EFailure(description: "\(Log.location): a cancelled read gave \(String(describing: load))")
        } catch is CancellationError {
            Log.note("the read ended as cancelled")
        }

        Log.step("B's next read gets the new photo")
        let after = try await seePhoto(f.b, f.cat, asset: second.asset)
        try expect(after.jpeg == second.jpeg && after.author == creator, "B gets A's new pixels after the cancelled read")
        return "service level; FamilyRepresentativePhotos.readAt (the page's read marker) is not driven"
    }

    // MARK: S3

    static func s3(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)
        let creator = try required(f.a.notebookIdentity?.personID, "A has no person")

        Log.step("A puts a photo; B sees it")
        let first = try await deliver(f.a, f.cat, shade: 3)
        _ = try await seePhoto(f.b, f.cat, asset: first.asset)

        Log.step("A's second iPhone: only A's iCloud Keychain on it")
        let a2 = try await Device.make("A2", relay: relay, cloud: f.a.cloud)
        let entrance = await a2.pass()
        try expect(entrance == .notInFamily, "nothing of the notebook before 機種変更 (got \(String(describing: entrance)))")

        Log.step("機種変更 on A2 with A's person key")
        let root = try required(f.a.cloud.roots.first, "A's person key is in its iCloud Keychain")
        let recovered = try await a2.recoverNotebook(root: root, family: f.id)
        try expect(recovered.personID == creator && recovered.registered, "A2 is A's person on a registered device")

        Log.step("A2 registers its device; A sends it the keys")
        await a2.pass()
        try expect(a2.notebookDeviceID == (try? recovered.deviceID), "A2's notebook uses the recovered device")
        try await settle("A2 has the keys", [f.a, a2]) { a2.inFamily }

        Log.step("A2 sees A's photo as its own person's")
        let seen = try await seePhoto(a2, f.cat, asset: first.asset)
        try expect(seen.author == creator && seen.jpeg == first.jpeg, "A2 reads A's pixels, authored by its own person")

        Log.step("A2's own reads leave the photo as it is")
        for _ in 0..<2 { await a2.pass() }
        let photoWrites = a2.notebookWrites().filter { $0.contains("/representative-photos/") }
        try expect(photoWrites.isEmpty, "A2 sent no photo by itself (\(photoWrites))")
        await f.b.pass()
        try expect(f.b.service.representativePhotoAsset(familyCatID: f.cat) == first.asset, "B still has A's first photo")

        Log.step("A2's own choice changes: A2 sends its photo")
        let store = try required(a2.service.notebook, "A2 has no notebook copy")
        let author = try required(a2.service.author, "A2 has no author")
        // The link of A2's own cat to the family cat (FamilyNotebookCatLink on that iPhone).
        try store.applyLocalChanges(.init(familyID: f.id, entries: [],
            mappings: [.init(sourceKey: "cat:e2e-a2", familyCatID: f.cat, toolCatID: UUID())]), author: author)
        let mine = try await deliver(a2, f.cat, shade: 4)
        let replaced = try await seePhoto(f.b, f.cat, asset: mine.asset)
        try expect(replaced.author == creator && replaced.jpeg == mine.jpeg, "B gets A2's photo, by the same person")
        return "service level; the sent/seen rule of FamilyRepresentativePhotos.syncOne is not driven; catalog not driven"
    }

    // MARK: S4

    static func s4(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)
        let creator = try required(f.a.notebookIdentity?.personID, "A has no person")

        Log.step("A puts a photo; B sees it")
        let photo = try await deliver(f.a, f.cat, shade: 5)
        _ = try await seePhoto(f.b, f.cat, asset: photo.asset)
        let oldDevice = try required(f.b.notebookDeviceID, "B has no device")
        let person = try required(f.b.notebookIdentity?.personID, "B has no person")

        Log.step("Earlier wake-ups are sent; the next one starts a new 2-minute window")
        try await relay.drain()
        let window = Double((Int(f.joinedAt.timeIntervalSince1970) / 120 + 1) * 120) + 1 - Date().timeIntervalSince1970
        if window > 0 {
            Log.note("waiting \(Int(window.rounded(.up))) s (B's first registration is in the current window)")
            try await Task.sleep(for: .seconds(window))
        }
        let wakeUpsBefore = relay.pushCount(to: f.a, kind: "family_device_registered")

        Log.step("B deletes the app and installs it again")
        try await f.b.reinstall()
        let mark = relay.transport.log.count
        let root = try required(try f.b.usualRoot(), "B's old identity is still in the device-only Keychain")

        Log.step("機種変更 on B with B's own person (the one used on this iPhone)")
        let recovered = try await f.b.recoverNotebook(root: root, family: f.id)
        let newDevice = try recovered.deviceID
        try expect(recovered.personID == person && recovered.registered && newDevice != oldDevice, "a new device of B is registered")

        Log.step("B's notebook opens with the new device (FamilyNotebookIdentityChoice, PR #1090)")
        await f.b.pass()
        let opened = f.b.notebookDeviceID
        try expect(opened == newDevice,
                   "the notebook opened with " + (opened == oldDevice ? "the leftover old device" : "no recovered device"))
        let writes = f.b.notebookWrites(since: mark).filter { !$0.hasSuffix("/push-subscription") }
        Log.note("new device's notebook writes: \(writes.map { $0.split(separator: "/").suffix(2).joined(separator: "/") })")
        try expect(writes.first?.hasSuffix("/crypto/devices") == true, "the new device's first notebook write is crypto/devices")
        let leftover = relay.transport.log.dropFirst(mark).filter { $0.device == oldDevice && $0.method != "GET" }
        try expect(leftover.isEmpty, "the leftover device wrote nothing after the reinstall")

        Log.step("A is woken by family_device_registered")
        try await relay.drain()
        let wakeUps = relay.pushCount(to: f.a, kind: "family_device_registered") - wakeUpsBefore
        try expect(wakeUps == 1, "A got \(wakeUps) device wake-ups")

        Log.step("A delivers the key; B's new device opens the notebook")
        try await settle("B's new device has the keys", [f.a, f.b]) { f.b.inFamily }

        Log.step("B's new device reads the current photo")
        let seen = try await seePhoto(f.b, f.cat, asset: photo.asset)
        try expect(seen.jpeg == photo.jpeg && seen.author == creator, "B reads A's current pixels again")
        return "the recovery catalog read is computed, not driven"
    }

    // MARK: S5

    static func s5(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)

        Log.step("A puts a photo; B sees it")
        let photo = try await deliver(f.a, f.cat, shade: 6)
        _ = try await seePhoto(f.b, f.cat, asset: photo.asset)

        Log.step("B's new iPhone: only B's iCloud Keychain on it")
        let b2 = try await Device.make("B2", relay: relay, cloud: f.b.cloud)
        let entrance = await b2.pass()
        try expect(entrance == .notInFamily, "nothing of the notebook before 機種変更 (got \(String(describing: entrance)))")

        Log.step("機種変更 on B2 with B's person key from iCloud")
        let root = try required(f.b.cloud.roots.first, "B's person key is in its iCloud Keychain")
        let recovered = try await b2.recoverNotebook(root: root, family: f.id)
        try expect(recovered.personID == f.b.notebookIdentity?.personID && recovered.registered, "B2 is B's person on a registered device")

        Log.step("B2 opens the notebook without going back to the entrance")
        let opened = await b2.pass()
        try expect(opened != nil && opened != .notInFamily, "B2 stays in the notebook (got \(String(describing: opened)))")
        try expect(b2.notebookDeviceID == (try? recovered.deviceID), "B2's notebook uses the recovered device")
        try await settle("B2 has the keys", [f.a, b2]) { b2.inFamily }

        Log.step("B2 sees A's photo")
        let seen = try await seePhoto(b2, f.cat, asset: photo.asset)
        try expect(seen.jpeg == photo.jpeg, "B2 reads A's pixels")

        Log.step("B2 reports A's photo")
        let receipt = try await b2.service.reportRepresentativePhoto(assetID: photo.asset, reasonCode: "other")
        try expect(!receipt.isEmpty, "the relay committed the report")
        Log.note("report received: \(receipt.prefix(6))…")

        Log.step("B2 no longer shows it; A keeps its own")
        let hidden = try await b2.photo(f.cat)
        try expect(hidden == FamilyNotebookPhotoLoad.none, "B2 shows nothing after reporting (got \(String(describing: hidden)))")
        let own = try await f.a.photo(f.cat)
        guard case .shown(let asset, _, _)? = own, asset == photo.asset else {
            throw E2EFailure(description: "\(Log.location): A reads its own photo as \(String(describing: own))")
        }

        Log.step("Operator: stop delivery and reply (not driven)")
        Log.note("The operator routes need Cloudflare Access and WebAuthn; the fixtures give only the report key pair.")
        Log.note("Missing: a loopback test route that applies the operator's photo decision and reply to a report ID.")
        do {
            let replies = try await b2.client.familyPhotoReportReplies()
            Log.note("(information) B2's usual client lists \(replies.count) replies")
        } catch {
            Log.note("(information) B2's usual client cannot list replies: \(error)")
        }
        return "up to the report receipt; operator stop/reply and B's reply not driven"
    }
}
