import Foundation

// The two-device scenarios. Each one makes its own family with fresh
// synthetic people, so a failure in one does not leave state for the next.
//
// Not driven anywhere here (UIKit, a singleton, PhotoKit or Apple's servers);
// each scenario's PASS line names its gap:
// - FamilyNotebookSharing.shared / FamilyNotebookAutoCheck.shared /
//   FamilyRepresentativePhotos.shared and FamilyNotebookPrototype (UIKit,
//   UserDefaults.standard): their reads and the notebook view's cat sharing
//   are driven as they call the service and the bridge, one step at a time.
// - RootSyncStore (iCloud Keychain): the person keys it would list are kept
//   in PersonCloud and handed to the real GroupRecoveryLiveBuilder.
// - GroupWindowScreenModel (the まど screen, UIKit): its sync is mirrored over
//   the app's ProductionGroupWindowClient and GroupWindowLocalPhotoStore
//   (Device.syncWindow); ProductionGroupReporting refuses the local endpoint.

struct Family {
    let a: Device, b: Device
    let id: UUID, cat: UUID
    /// The page (profile) and tool cat A put the cat in from.
    let profile: UUID, tool: UUID
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
        ("S5", "member B changes iPhone, reports A's photo, the operator stops it", s5),
        ("S6", "A reinstalls and adds the same cat page again (PR #1089)", s6),
        ("S7", "member B reinstalls without 機種変更", s7),
        ("S8", "member B changes iPhone, then reinstalls without 機種変更 (name lost before the Keychain copy)", s8),
        ("S9", "member B lost its name before the Keychain copy and never wrote; A still sees B's name", s9),
        ("S10", "member B hides and reports, reinstalls without 機種変更: the choices stay", s10),
        ("S11", "member B reports, reinstalls without 機種変更: 「通報への返答」 comes back", s11),
        ("S12", "member B reinstalled on a build that kept no binding: the next launch reads, the third is normal", s12),
        ("S13", "member B answers 「同じ子ですか」, reinstalls without 機種変更: only the lost link is asked again", s13),
        ("S15", "まど: B blocks, hides and removes, reinstalls and relaunches: nothing comes back", s15),
        ("S16", "while member B's app is deleted, A adds, replaces and removes; B reinstalls and launches twice", s16),
        ("S17", "while member B's app is deleted, A takes B out; B reinstalls and launches twice", s17),
        ("S20", "member B deletes its まど and notebook data, then makes a new identity on the same iPhone", s20),
        ("S21", "member B writes, then leaves at once: A receives the write", s21),
        ("S22", "B's new iPhone runs the notebook as recovered B and deletes its own other identity: B stays", s22),
    ]

    // MARK: Common steps

    /// `oldBuildB`: B joins with a build from before the Keychain copy of its name.
    static func makeFamily(_ relay: Relay, notifications: Bool = false, oldBuildB: Bool = false) async throws -> Family {
        Log.step("A: a Sandbox billing account with test Plus")
        let billing = try await relay.bootstrapBilling()
        try await relay.grantPlus(billing)
        let a = try await Device.make("A", relay: relay, cloud: PersonCloud(), billing: billing)

        Log.step("A creates the family notebook")
        let id = UUID()
        // The notebook screen remembers the typed name before it creates or joins.
        a.rememberName("合成のA")
        try await a.service.createFamily(operationID: id)
        try await settle("A's first key", [a]) { a.inFamily }
        try expect(a.service.currentFamilyID == id, "A's notebook is the one it created")
        a.cloud.publish(a.notebookIdentity?.personPrivateKey)

        Log.step("A puts one cat page into the notebook")
        let profile = UUID(), tool = UUID()
        let cat = try shareCat(a, name: "合成のしろ", profile: profile, tool: tool)
        let store = try required(a.service.notebook, "A has no notebook copy")
        try await settle("A's cat sent", [a]) { try store.pendingOperations().isEmpty }

        Log.step("A invites; B opens the link and asks to join")
        let invitation = try await a.service.createInvitation(operationID: UUID())
        let b = try await Device.make("B", relay: relay, cloud: PersonCloud())
        // B has a cat page of its own on its iPhone (not in the notebook).
        b.addOwnPage()
        let preview = try await b.service.previewInvitation(invitation.link)
        try expect(preview.catNames == ["合成ねこ"], "B sees the invitation's cat names (got \(preview.catNames))")
        b.keepsNameInKeychain = !oldBuildB
        b.rememberName("合成のB")
        _ = try await b.service.join(preview, operationID: UUID())
        let waiting = await b.pass()
        try expect(waiting == .pendingApproval, "B waits for approval (got \(String(describing: waiting)))")
        b.cloud.publish(b.notebookIdentity?.personPrivateKey)
        if notifications {
            Log.step("A is told that B asks to join (the relay holds it up to 4 minutes; the drain clock runs ahead)")
            try await relay.drain(advance: 240)
            try expect(relay.pushCount(to: a, kind: "family_join_requested") == 1, "A got one join request push")
        }

        Log.step("A approves B")
        let requests = try await a.service.pendingRequests()
        try expect(requests.count == 1 && requests.first?.personID == b.notebookIdentity?.personID,
                   "A sees exactly B's request (got \(requests.count))")
        try await a.service.decide(requestID: requests[0].id, approve: true, operationID: UUID())

        Log.step("The keys reach both iPhones")
        try await settle("both in the family with keys", [b, a]) { a.inFamily && b.inFamily }
        if notifications {
            Log.step("B is told it was let in")
            try await relay.drain(advance: 240)
            try expect(relay.pushCount(to: b, kind: "family_join_approved") == 1, "B got one approval push")
        }
        return Family(a: a, b: b, id: id, cat: cat, profile: profile, tool: tool, joinedAt: Date())
    }

    /// 「手帳に入れる猫」 for one page, as FamilyNotebookPrototype.sharePersonalCats
    /// does it: FamilyNotebookCatOrigin.cats finds a family cat this person
    /// already put in from the page; its catMappings rule (private in the
    /// view, mirrored here) reuses a link or that cat before a new family cat;
    /// FamilyNotebookCatRelink.preserving and FamilyNotebookCatOrigin.marking
    /// as there. FamilyNotebookMigration.prepare would copy the page's records
    /// from CatCareStore; the cat's name stands in for them.
    static func shareCat(_ device: Device, name: String, profile: UUID, tool: UUID) throws -> UUID {
        let store = try required(device.service.notebook, "\(device.name) has no notebook copy")
        let author = try required(device.service.author, "\(device.name) has no author")
        let snapshot = try store.snapshot()
        let origins = FamilyNotebookCatOrigin.cats(in: snapshot, person: author.personID, profiles: [profile])
        var mappings = snapshot.activeMappings
        let cat: UUID
        if let known = mappings.first(where: { $0.recordID == nil && ($0.toolCatID == tool || $0.profileID == tool
            || $0.profileID == profile || $0.toolCatID == profile) }) {
            cat = known.familyCatID
        } else {
            if let origin = origins[profile], !mappings.contains(where: { $0.familyCatID == origin && $0.recordID == nil }) {
                cat = origin
            } else { cat = UUID() }
            mappings.append(.init(sourceKey: "cat:" + tool.uuidString.lowercased(), familyCatID: cat, profileID: profile, toolCatID: tool))
        }
        let plan = FamilyNotebookImportPlan(familyID: snapshot.familyID, entries: [
            .init(ledgerKey: "cat:" + tool.uuidString.lowercased() + ":name", target: .init(familyCatID: cat, field: .name),
                  value: .text(name), editedAt: Date()),
        ], mappings: mappings)
        let relinked = try FamilyNotebookCatRelink.preserving(plan, previous: snapshot)
        let marked = FamilyNotebookCatOrigin.marking(relinked, previous: snapshot, person: author.personID)
        _ = try store.applyImport(marked, author: author)
        return cat
    }

    /// The family cats in `device`'s copy (every row a family cat has).
    static func familyCats(_ device: Device) throws -> Set<UUID> {
        let snapshot = try required(device.service.notebook, "\(device.name) has no notebook copy").snapshot()
        return Set(snapshot.operations.map(\.target.familyCatID)).subtracting(snapshot.unsharedCatIDs)
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

    /// 機種変更 on `device` with one candidate (its iCloud holds only `person`).
    static func recoverAlone(_ device: Device, person: String, family: UUID) async throws -> GroupDeviceIdentity {
        let screen = try await device.openRecoveryScreen()
        try expect(screen.rootChoice.isEmpty && screen.selectedRootID == person, "one candidate, the person's own")
        let state = try await device.confirmNotebook(on: screen, rootID: person)
        Log.note("notebook row: \(state)")
        let recovered = try required(try await device.recoveredIdentity(), "the identity choice picks the recovered identity")
        try expect(recovered.personID == person && recovered.registered, "a registered device of the person")
        if case .registeredWaitingForKeys(_, let shown) = state { try expect(shown == (try recovered.deviceID), "the row names the new device") }
        return recovered
    }

    // MARK: S1

    static func s1(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay, notifications: true)

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
        let cats = try familyCats(f.b)
        try expect(cats == [f.cat], "B's notebook has \(cats.count) cats")
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

        Log.step("機種変更 on A2: the signed catalog, the notebook row, 続ける")
        let recovered = try await recoverAlone(a2, person: creator, family: f.id)

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
        return "service level; the sent/seen rule of FamilyRepresentativePhotos.syncOne is not driven"
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

        Log.step("B's iCloud Keychain also holds A's person key, listed first (the owner's two-iPhone trial)")
        f.b.cloud.publish(try required(f.a.cloud.roots.first, "A's person key"), first: true)

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
        try expect(try f.b.usualRoot() != nil, "B's old identity is still in the device-only Keychain")

        Log.step("機種変更 on B: two candidates, B's own first and marked 「このiPhoneで使っていた」")
        let screen = try await f.b.openRecoveryScreen()
        let choice = screen.rootChoice
        Log.note("candidates: " + choice.map { ($0.id == person ? "B" : $0.id == creator ? "A" : "?") + ($0.usedOnThisIPhone ? "(used here)" : "") }
            .joined(separator: ", "))
        try expect(choice.count == 2, "two candidates (got \(choice.count))")
        try expect(choice[0].id == person && choice[0].usedOnThisIPhone, "B's own candidate first, marked as used on this iPhone")
        try expect(choice[1].id == creator && !choice[1].usedOnThisIPhone, "A's candidate second, not marked")
        try expect(choice.allSatisfy { $0.summary.notebookIDs.contains(f.id.uuidString.lowercased()) }, "both catalogs list the notebook")

        Log.step("B picks its own person and taps 続ける on the notebook row")
        let state = try await f.b.confirmNotebook(on: screen, rootID: person)
        Log.note("notebook row: \(state)")
        let recovered = try required(try await f.b.recoveredIdentity(),
                                     "FamilyNotebookIdentityChoice keeps the leftover device (the bug of PR #1090)")
        let newDevice = try recovered.deviceID
        try expect(recovered.personID == person && recovered.registered && newDevice != oldDevice, "a new device of B is registered")

        Log.step("B's notebook opens with the new device")
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
        return "RootSyncStore's list is PersonCloud; recovery signs in the staging domain"
    }

    // MARK: S5

    static func s5(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)
        let person = try required(f.b.notebookIdentity?.personID, "B has no person")

        Log.step("A puts a photo; B sees it")
        let photo = try await deliver(f.a, f.cat, shade: 6)
        _ = try await seePhoto(f.b, f.cat, asset: photo.asset)

        Log.step("B's new iPhone: only B's iCloud Keychain on it")
        let b2 = try await Device.make("B2", relay: relay, cloud: f.b.cloud)
        let entrance = await b2.pass()
        try expect(entrance == .notInFamily, "nothing of the notebook before 機種変更 (got \(String(describing: entrance)))")

        Log.step("機種変更 on B2: the signed catalog, the notebook row, 続ける")
        let recovered = try await recoverAlone(b2, person: person, family: f.id)

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
        let hidden = try await b2.photo(f.cat)
        try expect(hidden == FamilyNotebookPhotoLoad.none, "B2 shows nothing after reporting (got \(String(describing: hidden)))")

        Log.step("The operator stops the photo (review and decision routes, test operator)")
        try await relay.stopPhoto(reportID: receipt)

        Log.step("B2 opens the notebook: one reply read after 機種変更 (FamilyReportRepliesDiscovery)")
        // FamilyReportReplies.discoverReplies (in a UIKit file) with B2's own
        // inputs: no 「通報への返答」 flag on this iPhone (the report above went
        // through the service, not the cat page's markSent, as if it had been
        // sent from B's previous iPhone), the notebook loaded, the photo gate.
        try expect(!b2.showsReplyRow, "no 「通報への返答」 flag on B2 yet")
        let discovered = await b2.notebookOpened()
        try expect(discovered == .found && b2.showsReplyRow, "the reply sets the 「通報への返答」 row flag (got \(discovered))")
        let again = await b2.notebookOpened()
        try expect(again == .skipped, "no second read once the row shows (got \(again))")
        // FamilyNotebookServiceFactory.reportReplies: the usual client, as the
        // notebook's identity (FamilyNotebookIdentityChoice's recovered one).
        let replies = try await b2.client.familyPhotoReportReplies(as: try await b2.recoveredIdentity())

        Log.step("The reporter reads the reply through the app's path: photo_stopped")
        try expect(replies.contains { $0.status == .photoStopped }, "the reply list shows the photo stopped (got \(replies.map(\.status)))")
        try expect(replies.contains { $0.receiptNumber == receipt }, "the reply is for this report")

        Log.step("Another receiving iPhone of the family (B's first) gets 410 for that photo")
        let bDevice = try required(f.b.notebookDeviceID, "B has no device")
        let mark = relay.transport.log.count
        let other = try await f.b.photo(f.cat)
        try expect(other == FamilyNotebookPhotoLoad.none, "B's first iPhone shows nothing (got \(String(describing: other)))")
        let gone = relay.transport.log.dropFirst(mark).filter {
            $0.device == bDevice && $0.path.contains(photo.asset.uuidString.lowercased()) && $0.status == 410
        }
        try expect(!gone.isEmpty, "the relay answered 410 for the stopped photo")

        Log.step("The sender (A)")
        let own = try await f.a.photo(f.cat)
        Log.note("A's read of the shared copy: \(String(describing: own).prefix(60)); A's own key photo is in its library (PhotoKit, not driven)")
        return "A's local original (PhotoKit) not driven; discoverReplies' UserDefaults flag is Device.reportSent"
    }

    // MARK: S6

    static func s6(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)
        let creator = try required(f.a.notebookIdentity?.personID, "A has no person")
        try expect(try familyCats(f.b) == [f.cat], "B starts with one cat")

        Log.step("A deletes the app and installs it again (same person and device; the page is kept)")
        let oldDevice = try required(f.a.notebookDeviceID, "A has no device")
        try await f.a.reinstall()
        let first = await f.a.pass()
        try expect(first != nil, "the first read after the reinstall answers a state, not a failure")
        try await settle("A reads the notebook again", [f.a]) { f.a.inFamily }
        try expect(f.a.notebookDeviceID == oldDevice, "A keeps its device (no 機種変更)")
        try expect(try f.a.service.notebook?.snapshot().activeMappings.isEmpty == true, "A's new copy has no local links")

        Log.step("A opens the notebook: CatCareBridge.mappings finds the page by its origin")
        let store = try required(f.a.service.notebook, "A has no notebook copy")
        let author = try required(f.a.service.author, "A has no author")
        let snapshot = try store.snapshot()
        let mappings = try FamilyNotebookCatCareBridge.mappings(for: snapshot, existingLocalIDs: [f.tool],
                                                               person: creator, profiles: [f.profile])
        if mappings != snapshot.activeMappings {
            _ = try store.applyImport(.init(familyID: f.id, entries: [], mappings: mappings), author: author)
        }
        let rows = try store.snapshot().activeMappings.filter { $0.recordID == nil }
        try expect(rows.count == 1 && rows[0].familyCatID == f.cat && rows[0].profileID == f.profile,
                   "the cat comes back as A's page (got \(rows.count) rows)")

        Log.step("A adds the same cat page again")
        let again = try shareCat(f.a, name: "合成のしろ", profile: f.profile, tool: f.tool)
        try expect(again == f.cat, "the page is the same family cat, not a new one")
        let origins = try store.snapshot().operations.filter { $0.target == FamilyNotebookCatOrigin.target(cat: f.cat) }
        try expect(origins.count == 1, "one origin marker (got \(origins.count))")
        try await settle("A's writes sent", [f.a]) { try store.pendingOperations().isEmpty }

        Log.step("B still sees exactly one cat row")
        await f.b.pass(); await f.b.pass()
        let cats = try familyCats(f.b)
        try expect(cats == [f.cat], "B's notebook has \(cats.count) cats")
        return "the notebook view's reload/sharePersonalCats are mirrored around the real CatOrigin and CatCareBridge"
    }

    // MARK: S7

    static func s7(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)
        let creator = try required(f.a.notebookIdentity?.personID, "A has no person")

        Log.step("A puts a photo; B sees it")
        let photo = try await deliver(f.a, f.cat, shade: 7)
        _ = try await seePhoto(f.b, f.cat, asset: photo.asset)
        let oldDevice = try required(f.b.notebookDeviceID, "B has no device")

        Log.step("B deletes the app and installs it again; no 機種変更")
        try await f.b.reinstall()
        let first = await f.b.pass()
        try expect(first != nil, "the first read after the reinstall answers a state, not a failure")

        Log.step("B's notebook comes back with its own device")
        try await settle("B reads the notebook again", [f.b, f.a]) { f.b.inFamily }
        try expect(f.b.notebookDeviceID == oldDevice, "B keeps its device")
        let cats = try familyCats(f.b)
        try expect(cats == [f.cat], "B's notebook has \(cats.count) cats")

        Log.step("B's notebook screen: the name comes back from the Keychain, the cat is listed")
        try expect(f.b.rememberedName.isEmpty, "the reinstall wiped B's UserDefaults")
        let author = try required(f.b.service.author, "B has no author")
        try expect(author.displayName == "合成のB" && f.b.rememberedName == "合成のB",
                   "B's name comes back from the Keychain into UserDefaults (got \(author.displayName))")
        let listed = try f.b.notebookScreenCats()
        try expect(listed == [f.cat], "B's 「猫」 list has \(listed.count) cats")

        Log.step("B reads the current photo again")
        let seen = try await seePhoto(f.b, f.cat, asset: photo.asset)
        try expect(seen.jpeg == photo.jpeg && seen.author == creator, "B reads A's current pixels again")

        Log.step("B closes the app and opens it again (the second launch after the reinstall)")
        try expect(f.b.bindingSaved, "the first open kept the notebook binding")
        try await f.b.relaunch()
        try expect(f.b.lastReadAt == nil && f.b.lastState == nil, "a new process remembers no read")
        try expect(f.b.screenHasFamily, "the notebook opens from the kept binding before any read")
        try await relaunchedReadsIntoFamily(f.b)
        try expect(f.b.notebookDeviceID == oldDevice, "B keeps its device")
        let again = try f.b.notebookScreenCats()
        try expect(again == [f.cat], "B's 「猫」 list has \(again.count) cats after the relaunch")
        return "the binding, the approval mark and lastReadAt are Device's UserDefaults and process stand-ins"
    }

    /// After a relaunch: the schedule (the app's FamilyAutoCheckPolicy.eligible)
    /// reads, and keeps reading while the notebook is open, until B is in the family.
    static func relaunchedReadsIntoFamily(_ device: Device) async throws {
        for round in 1...12 {
            try expect(await device.automaticPass(), "the schedule read nothing on round \(round) (the endless spinner)")
            if device.inFamily { Log.note("\(device.name) in the family after \(round) automatic pass(es)"); return }
        }
        throw E2EFailure(description: "\(Log.location): \(device.name) did not reach the family in 12 automatic passes")
    }

    // MARK: S8

    static func s8(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)
        let person = try required(f.b.notebookIdentity?.personID, "B has no person")
        let rosterName = try required(f.a.service.memberNames[person], "A's roster has no name for B")

        Log.step("B writes one line on the cat")
        let firstStore = try required(f.b.service.notebook, "B has no notebook copy")
        try firstStore.edit(target: .init(familyCatID: f.cat, field: .marks), value: .text("合成のしるし1"),
                            author: try required(f.b.service.author, "B has no author"))
        try await settle("B's line sent", [f.b]) { try firstStore.pendingOperations().isEmpty }

        Log.step("B's new iPhone: only B's iCloud Keychain on it; 機種変更")
        let b2 = try await Device.make("B2", relay: relay, cloud: f.b.cloud)
        b2.keepsNameInKeychain = false
        let entrance = await b2.pass()
        try expect(entrance == .notInFamily, "nothing of the notebook before 機種変更 (got \(String(describing: entrance)))")
        let recovered = try await recoverAlone(b2, person: person, family: f.id)
        let newDevice = try recovered.deviceID
        await b2.pass()
        try expect(b2.notebookDeviceID == newDevice, "B2's notebook uses the recovered device")
        try await settle("B2 has the keys", [f.a, b2]) { b2.inFamily }

        Log.step("B2 deletes the app and installs this build; no 機種変更")
        try await b2.reinstall()
        try expect(b2.rememberedName.isEmpty && b2.keptName == nil, "B2 has no name in UserDefaults or the Keychain")
        let first = await b2.pass()
        try expect(first != nil, "the first read after the reinstall answers a state, not a failure")
        try await settle("B2 reads the notebook again", [b2, f.a]) { b2.inFamily }
        try expect(b2.notebookDeviceID == newDevice, "B2 keeps the recovered device")

        Log.step("B2's notebook screen: the family's name for B, and the cat in the list")
        let author = try required(b2.service.author, "B2 has no author (the bug: the 「猫」 list stays empty)")
        try expect(author.personID == person, "B2 writes as B")
        try expect(author.displayName == rosterName, "B2's name is the roster's (got \(author.displayName))")
        try expect(b2.rememberedName == rosterName && b2.keptName == rosterName, "B2 remembers the name again, Keychain too")
        let listed = try b2.notebookScreenCats()
        try expect(listed == [f.cat], "B2's 「猫」 list has \(listed.count) cats")

        Log.step("B2 writes; A reads it as B's")
        let store = try required(b2.service.notebook, "B2 has no notebook copy")
        let line = try store.edit(target: .init(familyCatID: f.cat, field: .marks), value: .text("合成のしるし2"), author: author)
        try await settle("B2's line sent", [b2]) { try store.pendingOperations().isEmpty }
        try await settle("A has B2's line", [f.a]) {
            try f.a.service.notebook?.snapshot().operations.contains { $0.id == line.id && $0.author == author } == true
        }
        return "UserDefaults is Device.rememberedName; CatCareStore and the screen's other steps are not driven"
    }

    // MARK: S9

    static func s9(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay, oldBuildB: true)
        let person = try required(f.b.notebookIdentity?.personID, "B has no person")
        let rosterName = try required(f.a.service.memberNames[person], "A's roster has no name for B")

        Log.step("B deletes the app and installs this build; B never wrote")
        try await f.b.reinstall()
        try expect(f.b.rememberedName.isEmpty && f.b.keptName == nil, "B has no name in UserDefaults or the Keychain")
        try await settle("B reads the notebook again", [f.b, f.a]) { f.b.inFamily }

        Log.step("B's notebook screen: the unnamed word, not remembered; the cat is listed")
        let author = try required(f.b.service.author, "B has no author")
        try expect(author.personID == person && author.displayName == FamilyNotebookAuthorName.unnamed,
                   "B writes as the unnamed word (got \(author.displayName))")
        try expect(f.b.rememberedName.isEmpty && f.b.keptName == nil, "the unnamed word is not remembered")
        let listed = try f.b.notebookScreenCats()
        try expect(listed == [f.cat], "B's 「猫」 list has \(listed.count) cats")

        Log.step("B writes one line; A still shows B under B's name")
        let store = try required(f.b.service.notebook, "B has no notebook copy")
        let line = try store.edit(target: .init(familyCatID: f.cat, field: .marks), value: .text("合成のしるし"), author: author)
        try await settle("B's line sent", [f.b]) { try store.pendingOperations().isEmpty }
        try await settle("A has B's line", [f.a]) {
            try f.a.service.notebook?.snapshot().operations.contains { $0.id == line.id } == true
        }
        let operations = try required(f.a.service.notebook, "A has no notebook copy").snapshot().operations
        let received = try required(operations.first { $0.id == line.id }, "A has no line")
        try expect(received.author.displayName == FamilyNotebookAuthorName.unnamed, "the line carries the unnamed word")
        // FamilyNotebookPrototype.shownName / members on A (realMemberNames is the service's memberNames).
        let shown = FamilyNotebookAuthorName.shown(received.author, operations: operations, known: f.a.service.memberNames)
        try expect(shown == rosterName, "A shows B as \(shown), not B's name")
        return "the screens' shownName/members are FamilyNotebookAuthorName.shown with A's memberNames"
    }

    // MARK: S10

    static func s10(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)
        let creator = try required(f.a.notebookIdentity?.personID, "A has no person")

        Log.step("A puts a photo and writes one line; B sees both")
        let photo = try await deliver(f.a, f.cat, shade: 3)
        _ = try await seePhoto(f.b, f.cat, asset: photo.asset)
        let aStore = try required(f.a.service.notebook, "A has no notebook copy")
        let line = try aStore.edit(target: .init(familyCatID: f.cat, field: .marks), value: .text("合成のしるし"),
                                   author: try required(f.a.service.author, "A has no author"))
        try await settle("A's line sent", [f.a]) { try aStore.pendingOperations().isEmpty }
        try await settle("B has A's line", [f.b]) {
            try f.b.service.notebook?.snapshot().operations.contains { $0.id == line.id } == true
        }
        let entry = String(describing: line.id)

        Log.step("B: 「表示しない」 on A's line and on A's photos")
        f.b.hideEntry(entry)
        try await f.b.service.hideRepresentativePhotos(of: creator)
        let hidden = try await f.b.photo(f.cat)
        try expect(hidden == .hidden(authorID: creator), "B hides A's photo (got \(String(describing: hidden)))")

        Log.step("B deletes the app and installs it again; no 機種変更")
        let oldDevice = try required(f.b.notebookDeviceID, "B has no device")
        try await f.b.reinstall()
        try expect(f.b.hiddenEntries == nil, "the reinstall wiped B's UserDefaults")
        try await settle("B reads the notebook again", [f.b, f.a]) { f.b.inFamily }
        try expect(f.b.notebookDeviceID == oldDevice, "B keeps its device")
        _ = await f.b.notebookOpened()

        Log.step("B's choices came back from the Keychain")
        try expect(f.b.hiddenEntryIDs == [entry], "A's line stays hidden on B (got \(f.b.hiddenEntryIDs.count) entries)")
        let stillHidden = try await f.b.photo(f.cat)
        try expect(stillHidden == .hidden(authorID: creator), "A's photo stays hidden on B (got \(String(describing: stillHidden)))")

        Log.step("A still has its photo")
        let own = try await f.a.photo(f.cat)
        guard case .shown(let ownAsset, _, let ownJPEG)? = own, ownAsset == photo.asset, ownJPEG == photo.jpeg else {
            throw E2EFailure(description: "\(Log.location): A reads its photo as \(String(describing: own))")
        }

        Log.step("B shows A's photos again, then reports the photo (as S5)")
        try await f.b.service.showRepresentativePhotos(of: creator)
        let shown = try await seePhoto(f.b, f.cat, asset: photo.asset)
        try expect(shown.jpeg == photo.jpeg, "B reads A's pixels again")
        let receipt = try await f.b.reportPhoto(photo.asset)
        try expect(!receipt.isEmpty, "the relay committed the report")
        let reported = try await f.b.photo(f.cat)
        try expect(reported == FamilyNotebookPhotoLoad.none, "B shows nothing after reporting (got \(String(describing: reported)))")

        Log.step("B deletes the app and installs it again; no 機種変更 (the photo is not stopped)")
        try await f.b.reinstall()
        try await settle("B reads the notebook again", [f.b, f.a]) { f.b.inFamily }
        _ = await f.b.notebookOpened()
        let afterReport = try await f.b.photo(f.cat)
        try expect(afterReport == FamilyNotebookPhotoLoad.none,
                   "the reported photo stays away on B, and 「表示する」 held (got \(String(describing: afterReport)))")
        try expect(f.b.hiddenEntryIDs == [entry], "A's line is still hidden on B")

        Log.step("A still has its photo")
        let ownAgain = try await f.a.photo(f.cat)
        guard case .shown(let againAsset, _, _)? = ownAgain, againAsset == photo.asset else {
            throw E2EFailure(description: "\(Log.location): A reads its photo as \(String(describing: ownAgain))")
        }
        return "the entries' 「表示しない」 is FamilyHiddenOperationsMemory over Device.hiddenEntries (the view's @AppStorage)"
    }

    // MARK: S11

    static func s11(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)

        Log.step("A puts a photo; B sees it and reports it")
        let photo = try await deliver(f.a, f.cat, shade: 4)
        _ = try await seePhoto(f.b, f.cat, asset: photo.asset)
        let receipt = try await f.b.reportPhoto(photo.asset)
        try expect(!receipt.isEmpty && f.b.showsReplyRow, "the report was received; B shows 「通報への返答」")

        Log.step("B deletes the app and installs it again; no 機種変更")
        try await f.b.reinstall()
        try expect(!f.b.showsReplyRow, "the reinstall wiped the row's flag")
        let linked = try f.b.keychain.store(Device.namespace + Device.recoveryLinkSuffix)
            .read(FamilyNotebookIdentityChoice.linkAccount) != nil
        try expect(!linked, "no recovery link on B")
        try await settle("B reads the notebook again", [f.b, f.a]) { f.b.inFamily }

        Log.step("B opens the notebook: one quiet reply read finds the report")
        let replies = "/v3/family-notebooks/report-replies"
        let device = try required(f.b.notebookDeviceID, "B has no device")
        var mark = relay.transport.log.count
        let first = await f.b.notebookOpened()
        try expect(first == .found, "the app's discovery finds the reply (got \(first))")
        try expect(f.b.showsReplyRow, "「通報への返答」 shows again")
        let reads = relay.transport.log.dropFirst(mark).filter { $0.path == replies }
        try expect(reads.count == 1 && reads[0].device == device && reads[0].status == 200,
                   "one reply read by B (got \(reads.count))")

        Log.step("B opens the notebook again: no read")
        mark = relay.transport.log.count
        let second = await f.b.notebookOpened()
        try expect(second == .skipped, "the row's flag is set (got \(second))")
        try expect(!relay.transport.log.dropFirst(mark).contains { $0.path == replies }, "no second read")

        Log.step("A (never reported) opens the notebook twice: one read, then none in this launch")
        mark = relay.transport.log.count
        let aFirst = await f.a.notebookOpened(), aSecond = await f.a.notebookOpened()
        try expect(aFirst == .noReplies && !f.a.showsReplyRow, "A has no replies and no row (got \(aFirst))")
        try expect(aSecond == .skipped, "none is remembered for the launch (got \(aSecond))")
        let aReads = relay.transport.log.dropFirst(mark).filter { $0.path == replies }
        try expect(aReads.count == 1, "A read the replies once (got \(aReads.count))")
        return "FamilyReportReplies' UserDefaults flag and process memory are Device.reportSent / repliesCheckedNone"
    }

    // MARK: S12

    static func s12(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay, oldBuildB: true)

        Log.step("B deletes the app and installs the earlier build: its read finds no name, so no binding is kept")
        try await f.b.reinstall()
        f.b.savesBinding = false
        try expect(f.b.awaitingApprovalMark == nil && !f.b.bindingSaved, "the reinstall wiped B's UserDefaults")
        try expect(!f.b.screenHasFamily, "no binding: nothing opens before a read")

        Log.step("B's first launch: the unsettled mark makes the schedule read; B is in the family")
        try await relaunchedReadsIntoFamily(f.b)
        try expect(f.b.awaitingApprovalMark == false, "the first read settled the mark: not waiting")
        try expect(!f.b.bindingSaved, "the earlier build kept no binding")

        Log.step("B closes the app and opens it again with this build (the launch that sat on the spinner)")
        let device = try required(f.b.notebookDeviceID, "B has no device")
        f.b.savesBinding = true
        try await f.b.relaunch()
        try expect(f.b.lastReadAt == nil && f.b.lastState == nil, "a new process remembers no read")
        try expect(!f.b.screenHasFamily && f.b.awaitingApprovalMark == false,
                   "no binding and a settled mark: only the launch read can make the schedule read")
        let mark = relay.transport.log.count
        try await relaunchedReadsIntoFamily(f.b)
        try expect(relay.transport.log.dropFirst(mark).contains { $0.device == device },
                   "the launch read reached the relay as B's device")
        try expect(!f.b.bindingSaved, "nothing kept the binding before the read")
        let afterSchedule = relay.transport.log.count
        try expect(!(await f.b.notebookScreenAppeared()), "the screen adds no read once a read answered")
        try expect(relay.transport.log.count == afterSchedule, "nothing was sent when the screen appeared")
        let listed = try f.b.notebookScreenCats()
        try expect(listed == [f.cat], "B's 「猫」 list has \(listed.count) cats")
        try expect(f.b.bindingSaved, "this build keeps the binding once the read answered")

        Log.step("B's third launch: the screen appears in .checking with no read running: its one read; then the schedule")
        try await f.b.relaunch()
        try expect(f.b.screenHasFamily, "the notebook opens from the kept binding before any read")
        let thirdMark = relay.transport.log.count
        try expect(await f.b.notebookScreenAppeared(), "the screen's own read (FamilyAutoCheckPolicy.screenReadsOnAppear)")
        try expect(f.b.lastState != nil && f.b.sharingState != .checking, "the screen's read answered (got \(String(describing: f.b.lastState)))")
        try expect(relay.transport.log.dropFirst(thirdMark).contains { $0.device == device }, "the screen's read reached the relay as B's device")
        try expect(!(await f.b.notebookScreenAppeared()), "appearing again adds no read")
        try await relaunchedReadsIntoFamily(f.b)
        try expect(f.b.notebookDeviceID == device, "B keeps its device")
        let third = try f.b.notebookScreenCats()
        try expect(third == [f.cat], "B's 「猫」 list has \(third.count) cats on the third launch")
        return "the earlier build is Device.savesBinding = false; the schedule's eligibility is FamilyAutoCheckPolicy.eligible and the screen's read FamilyAutoCheckPolicy.screenReadsOnAppear (with `reading` false: the harness runs one read at a time); FamilyNotebookSharing.state is Device.sharingState"
    }

    // MARK: S13

    static func s13(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)

        Log.step("A puts a second cat page into the notebook; B gets it")
        let second = try shareCat(f.a, name: "合成のくろ", profile: UUID(), tool: UUID())
        let aStore = try required(f.a.service.notebook, "A has no notebook copy")
        try await settle("A's second cat sent", [f.a]) { try aStore.pendingOperations().isEmpty }
        try await settle("B has both cats", [f.b]) { try familyCats(f.b) == [f.cat, second] }
        let listed = try f.b.notebookScreenCats()
        try expect(Set(listed) == [f.cat, second], "B's 「猫」 list has \(listed.count) cats")

        Log.step("B is asked about both cats: 「べつの子」 for the first, 「同じ子」 for the second")
        let asked = try f.b.linkQuestions()
        try expect(Set(asked) == [f.cat, second], "B is asked about \(asked.count) cats")
        try f.b.answerLinkQuestion(f.cat, sameAs: nil)
        try f.b.answerLinkQuestion(second, sameAs: UUID())
        try expect(try f.b.linkQuestions().isEmpty, "nothing is asked again")
        let otherKey = FamilyNotebookCatLink.answerKey(family: f.id, cat: f.cat)
        try expect(f.b.keptLinkAnswers == [otherKey], "the Keychain keeps 「べつの子」 only (got \(f.b.keptLinkAnswers.count))")

        Log.step("B deletes the app and installs it again; no 機種変更")
        let oldDevice = try required(f.b.notebookDeviceID, "B has no device")
        try await f.b.reinstall()
        try expect(f.b.linkAnswers == nil, "the reinstall wiped B's UserDefaults")
        try await settle("B reads the notebook again", [f.b, f.a]) { f.b.inFamily }
        try expect(f.b.notebookDeviceID == oldDevice, "B keeps its device")
        let again = try f.b.notebookScreenCats()
        try expect(Set(again) == [f.cat, second], "B's 「猫」 list has \(again.count) cats")

        Log.step("「べつの子」 came back from the Keychain; the link went with the app, so that cat is asked again")
        let afterReinstall = try f.b.linkQuestions()
        try expect(afterReinstall == [second], "B is asked about the second cat only (got \(afterReinstall.count))")
        try expect(f.b.linkAnswers == [otherKey], "the answer is back in UserDefaults")

        Log.step("B closes the app and opens it again (the second launch after the reinstall)")
        try await f.b.relaunch()
        try await relaunchedReadsIntoFamily(f.b)
        _ = try f.b.notebookScreenCats()
        let secondLaunch = try f.b.linkQuestions()
        try expect(secondLaunch == [second], "the second launch asks the same (got \(secondLaunch.count))")

        Log.step("B links the second cat again: nothing is asked any more")
        try f.b.answerLinkQuestion(second, sameAs: UUID())
        try expect(try f.b.linkQuestions().isEmpty, "nothing is asked")
        try expect(f.b.keptLinkAnswers == [otherKey], "the Keychain still keeps 「べつの子」 only")
        return "the questions are FamilyNotebookCatLink's over Device.linkAnswers (the model's UserDefaults); B's own page is Device.ownPages (the screen's link input only); the questions' CatCareStore `care` is nil and 「同じ子」 is the store's mapping only (「この子のこと」 not driven)"
    }

    // MARK: S15

    /// A まど photo: the public report vector's canonical JPEG (ci/fixtures,
    /// synthetic pixels, no metadata, so GroupJPEG.validate takes it).
    static func windowJPEG() throws -> Data {
        struct Vector: Decodable { let canonicalJPEGBase64: String }
        let vector = try JSONDecoder().decode(Vector.self,
            from: Data(contentsOf: URL(fileURLWithPath: "ci/fixtures/group-report-v3.json")))
        return try required(Data(base64Encoded: vector.canonicalJPEGBase64), "the fixture JPEG")
    }

    static func s15(_ relay: Relay) async throws -> String? {
        Log.step("A: a Sandbox billing account with test Plus; A makes a まど and its invitation")
        let billing = try await relay.bootstrapBilling()
        try await relay.grantPlus(billing)
        let a = try await Device.make("A", relay: relay, cloud: PersonCloud(), billing: billing)
        let window = try await a.client.createWindow(name: "合成のまど", ownerDisplayName: "合成のA", operationID: UUID())
        let invitation = try await a.client.createInvitation(windowID: window.id,
                                                            operation: GroupOperation(expectedRevision: window.revision))
        let link = try required(URL(string: invitation.shareText).flatMap({ GroupInvitationLink(url: $0) })?.url,
                                "the invitation link")

        var joined: [Device] = []
        for name in ["B", "C", "D"] {
            Log.step("\(name) opens the link and asks to join; A's iPhone lets them in (reconcileAdmissions)")
            let device = try await Device.make(name, relay: relay, cloud: PersonCloud())
            let invitationID = try await device.client.stageInvitation(url: link)
            let request = try await device.client.apply(invitationID: invitationID, displayName: "合成の" + name, operationID: UUID())
            _ = try await a.client.reconcileAdmissions()
            let status = try await device.client.joinStatus(requestID: request.id)
            try expect(status.state == .approved, "\(name) was let in (got \(status.state))")
            joined.append(device)
        }
        let b = joined[0], c = joined[1], d = joined[2]

        Log.step("A sends two photos, C and D one each")
        let jpeg = try windowJPEG()
        let a1 = try await a.client.sendPhoto(normalizedJPEG: jpeg, windowID: window.id, operationID: UUID()).id
        let a2 = try await a.client.sendPhoto(normalizedJPEG: jpeg, windowID: window.id, operationID: UUID()).id
        let c1 = try await c.client.sendPhoto(normalizedJPEG: jpeg, windowID: window.id, operationID: UUID()).id
        let d1 = try await d.client.sendPhoto(normalizedJPEG: jpeg, windowID: window.id, operationID: UUID()).id

        Log.step("B opens the まど: the four photos are kept and shown")
        let first = try await b.syncWindow(window.id)
        try expect(Set(first.shown) == [a1, a2, c1, d1] && first.shown.count == 4, "B shows \(first.shown.count) photos")
        let entries = await b.windowPhotos.entries(windowID: window.id)
        let cPhoto = try required(entries.first { $0.id == c1 }, "B has C's photo")
        let dPhoto = try required(entries.first { $0.id == d1 }, "B has D's photo")

        Log.step("B: 「自分のまどから消す」 on A's first photo, ブロック on C, and D hidden (an earlier build's 「表示しない」)")
        // GroupWindowScreenModel.remove and blockSender (its local half; see the PASS line).
        try await b.windowPhotos.remove(photoID: a1, windowID: window.id)
        await b.windowPhotos.hide(memberID: cPhoto.senderParticipantID, name: cPhoto.senderDisplayName, windowID: window.id, blocked: true)
        await b.windowPhotos.hide(memberID: dPhoto.senderParticipantID, name: dPhoto.senderDisplayName, windowID: window.id)
        let chosen = await b.windowPhotos.entries(windowID: window.id).map(\.id)
        try expect(chosen == [a2], "B shows A's second photo only (got \(chosen.count))")
        let kept = try required(try b.keptWindowChoices(window.id), "B's Keychain keeps the choices")
        try expect(kept.removedPhotoIDs == [a1] && kept.blockedMemberIDs == [cPhoto.senderParticipantID]
                   && kept.hiddenMemberIDs == [dPhoto.senderParticipantID], "the Keychain copy holds the three choices")

        Log.step("B deletes the app and installs it again")
        try await b.reinstall()
        try expect(await b.windowPhotos.knownWindows().isEmpty, "the reinstall wiped B's kept まど photos")
        let device = try required(try await b.client.existingDeviceID(), "B still has its まど device (Keychain)")

        Log.step("B opens the まど: the relay still lists every photo; the removed one is not downloaded, C and D stay away")
        var mark = relay.transport.log.count
        let again = try await b.syncWindow(window.id)
        try expect(Set([a1, a2, c1, d1]).isSubset(of: Set(again.listed)), "the relay lists the four photos to B (the choices are what keep them away)")
        try expect(!again.downloaded.contains(a1), "the removed photo was downloaded again")
        try expect(!relay.transport.log.dropFirst(mark).contains { $0.device == device && $0.path.contains(a1) },
                   "no request for the removed photo")
        try expect(again.shown == [a2], "B shows A's second photo only after the reinstall (got \(again.shown.count))")
        try await expectHidden(b, window: window.id, blocked: cPhoto, hidden: dPhoto)

        Log.step("B closes the app and opens it again: nothing is downloaded, the same is shown")
        try await b.relaunch()
        mark = relay.transport.log.count
        let relaunched = try await b.syncWindow(window.id)
        try expect(relaunched.downloaded.isEmpty, "the second launch downloaded \(relaunched.downloaded.count) photos")
        try expect(!relay.transport.log.dropFirst(mark).contains { $0.device == device && $0.path.hasSuffix("/ciphertext") },
                   "no photo bytes were read")
        try expect(relaunched.shown == [a2], "B shows A's second photo only on the second launch (got \(relaunched.shown.count))")
        try await expectHidden(b, window: window.id, blocked: cPhoto, hidden: dPhoto)
        return "GroupWindowLocalPhotoStore and ProductionGroupWindowClient are the app's over Device's folder and Keychain; "
            + "GroupWindowScreenModel.sync/receive (GroupWindowView.swift, UIKit) are mirrored step for step, the sensitive-content check taken as safe; "
            + "the relay half of ブロック and 通報 (ProductionGroupReporting) is not driven: its init accepts only the staging endpoint "
            + "with the pinned moderation key or the iOS production configuration, so the block here is local only and the reported-photo "
            + "cover stays with verify-group-window-choices-survive-reinstall.swift"
    }

    /// 「ブロックした人」 (knownWindows' hiddenMembers): the blocked person with
    /// the name the relay gave, the hidden one not blocked.
    static func expectHidden(_ device: Device, window: String, blocked: GroupWindowLocalPhotoStore.Entry,
                             hidden: GroupWindowLocalPhotoStore.Entry) async throws {
        let known = try required(await device.windowPhotos.knownWindows().first { $0.id == window }, "\(device.name) knows the まど")
        let members = known.hiddenMembers ?? []
        try expect(members.count == 2, "\(device.name) lists \(members.count) people it does not show")
        try expect(members.contains { $0.id == blocked.senderParticipantID && $0.blocked == true && $0.name == blocked.senderDisplayName },
                   "the blocked person is listed as blocked, with the name from the relay")
        try expect(members.contains { $0.id == hidden.senderParticipantID && $0.blocked != true && $0.name == hidden.senderDisplayName },
                   "the hidden person is hidden, not blocked")
    }

    // MARK: S16

    /// A launch after a reinstall: the app's schedule (FamilyAutoCheckPolicy.eligible)
    /// reads on `device`; the other iPhones read as they would on their own.
    static func scheduledIntoFamily(_ device: Device, with others: [Device]) async throws {
        for round in 1...12 {
            try expect(await device.automaticPass(), "the schedule read nothing on round \(round)")
            if device.inFamily { Log.note("\(device.name) in the family after \(round) automatic pass(es)"); return }
            for other in others { await other.pass() }
        }
        throw E2EFailure(description: "\(Log.location): \(device.name) did not reach the family in 12 automatic passes")
    }

    /// B shows A's current notebook: the cats, one row each, and the photo.
    static func expectCurrent(_ b: Device, cats: Set<UUID>, photoCat: UUID, photo: (asset: UUID, jpeg: Data),
                              creator: String) async throws {
        let inCopy = try familyCats(b)
        try expect(inCopy == cats, "B's copy has \(inCopy.count) cats, A has \(cats.count)")
        let rows = try b.notebookScreenRows()
        try expect(rows.count == cats.count && Set(rows.map { $0.familyCatID }) == cats,
                   "B's 「猫」 list has \(rows.count) rows for \(cats.count) cats (a duplicate, or the removed cat)")
        try expect(Set(rows.map { $0.toolCatID }).count == rows.count, "one cat on B's iPhone per row")
        let seen = try await seePhoto(b, photoCat, asset: photo.asset)
        try expect(seen.jpeg == photo.jpeg && seen.author == creator, "B reads A's current pixels")
    }

    static func s16(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)
        let creator = try required(f.a.notebookIdentity?.personID, "A has no person")
        let aStore = try required(f.a.service.notebook, "A has no notebook copy")
        let aAuthor = try required(f.a.service.author, "A has no author")

        Log.step("B puts its own cat page into the notebook")
        let page = try required(f.b.ownPages.first, "B has a cat page of its own")
        let bCat = try shareCat(f.b, name: "合成のBのねこ", profile: page.profile, tool: page.tool)
        let bStore = try required(f.b.service.notebook, "B has no notebook copy")
        try await settle("B's cat sent", [f.b]) { try bStore.pendingOperations().isEmpty }

        Log.step("A puts a second cat in with a photo; B sees three cats and the photo")
        let second = try shareCat(f.a, name: "合成のくろ", profile: UUID(), tool: UUID())
        try await settle("A's second cat sent", [f.a]) { try aStore.pendingOperations().isEmpty }
        let firstPhoto = try await deliver(f.a, second, shade: 1)
        try await settle("B has the three cats", [f.b, f.a]) { try familyCats(f.b) == [f.cat, bCat, second] }
        _ = try await seePhoto(f.b, second, asset: firstPhoto.asset)
        let before = try f.b.notebookScreenRows()
        try expect(before.count == 3 && Set(before.map { $0.familyCatID }) == [f.cat, bCat, second], "B's 「猫」 list has \(before.count) rows")
        try expect(before.first(where: { $0.familyCatID == bCat })?.toolCatID == page.tool, "B's own cat is its page's cat, not a second one")
        let bDevice = try required(f.b.notebookDeviceID, "B has no device")

        Log.step("B deletes the app; while it is gone A adds a cat, removes the first one and replaces the photo")
        let third = try shareCat(f.a, name: "合成のみけ", profile: UUID(), tool: UUID())
        // FamilyNotebookPrototype.unshareCat.
        _ = try aStore.edit(target: .init(familyCatID: f.cat, field: .sharingEnded), value: nil, author: aAuthor,
                            expectedRevision: try aStore.snapshot().revision)
        try await settle("A's changes sent", [f.a]) { try aStore.pendingOperations().isEmpty }
        let replaced = try await deliver(f.a, second, shade: 2)
        let current: Set<UUID> = [bCat, second, third]
        let onA = try familyCats(f.a)
        try expect(onA == current, "A's notebook has \(onA.count) cats")

        Log.step("B installs the app again; first launch: the schedule reads until B is in the family")
        try await f.b.reinstall()
        try expect(f.b.ownPages.isEmpty && f.b.localCats.isEmpty, "the reinstall wiped B's cat page and CatCareStore")
        try await scheduledIntoFamily(f.b, with: [f.a])
        try expect(f.b.notebookDeviceID == bDevice, "B keeps its device")
        try await expectCurrent(f.b, cats: current, photoCat: second, photo: replaced, creator: creator)

        Log.step("B closes the app and opens it again (the second launch)")
        try await f.b.relaunch()
        try expect(f.b.screenHasFamily, "the notebook opens from the kept binding before any read")
        try await relaunchedReadsIntoFamily(f.b)
        try await expectCurrent(f.b, cats: current, photoCat: second, photo: replaced, creator: creator)

        Log.step("A still has the same three cats: B's two launches added none")
        await f.a.pass()
        let after = try familyCats(f.a)
        try expect(after == current, "A's notebook has \(after.count) cats after B's launches")
        return "B's cat page and CatCareStore are Device.ownPages/localCats, wiped by the reinstall and not restored; "
            + "the launches' family reads are the schedule's (FamilyAutoCheckPolicy.eligible), the photo reads the cat page's; "
            + "attachReal's relinkOwnCats and writeInitialPositions are not driven"
    }

    // MARK: S17

    /// One launch of a member taken out of the family: one read answers the
    /// entrance, nothing else reads in that launch, and there is no copy (so
    /// no 「終わりました」 notice). Returns the read's requests.
    static func entranceLaunch(_ b: Device, relay: Relay, screenFirst: Bool) async throws -> Int {
        let mark = relay.transport.log.count
        if screenFirst {
            try expect(await b.notebookScreenAppeared(), "the screen's one read (.checking, no read running)")
        } else {
            try expect(await b.automaticPass(), "the schedule's launch read (nothing read yet, an identity on this iPhone)")
        }
        try expect(b.lastState == .notInFamily && b.sharingState == .notInFamily,
                   "B's read answers the entrance, not a failure (got \(String(describing: b.lastState)))")
        let device = try required(b.notebookDeviceID, "B has no notebook device")
        let sent = relay.transport.log.dropFirst(mark).filter { $0.device == device }
        try expect(!sent.isEmpty, "the read reached the relay as B's device")
        let afterRead = relay.transport.log.count
        for _ in 0..<3 {
            try expect(!(await b.automaticPass()), "the schedule reads again in the same launch")
            try expect(!(await b.notebookScreenAppeared()), "the screen reads again in the same launch")
        }
        try expect(relay.transport.log.count == afterRead, "\(relay.transport.log.count - afterRead) more requests in the same launch")
        try expect(b.service.notebook == nil && !b.copyCanShowEndedNotice && !b.screenHasFamily,
                   "B sees only the entrance (no copy, so no 「終わりました」 notice)")
        Log.note("\(b.name): \(sent.count) requests, statuses \(sent.map(\.status))")
        return sent.count
    }

    static func s17(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)
        let person = try required(f.b.notebookIdentity?.personID, "B has no person")
        let listed = try f.b.notebookScreenCats()
        try expect(listed == [f.cat], "B's 「猫」 list has \(listed.count) cats")

        Log.step("B deletes the app; while it is gone A takes B out of the family")
        try await f.a.service.removeMember(personID: person, operationID: UUID())
        try await settle("A's family no longer lists B", [f.a]) {
            f.a.inFamily && !f.a.service.lastMembers.contains { $0.personID == person }
        }

        Log.step("B installs the app again; first launch: the notebook screen's one read, the entrance")
        try await f.b.reinstall()
        try expect(!f.b.screenHasFamily && f.b.awaitingApprovalMark == nil, "nothing opens before a read; the mark is unsettled")
        let first = try await entranceLaunch(f.b, relay: relay, screenFirst: true)

        Log.step("B closes the app and opens it again: the schedule's one launch read, the entrance again")
        try await f.b.relaunch()
        try expect(!f.b.screenHasFamily && f.b.awaitingApprovalMark == false, "no binding, a settled mark")
        let second = try await entranceLaunch(f.b, relay: relay, screenFirst: false)
        return "accepted as-is: B sees only the entrance and no 「終わりました」 notice (its copy and the notice's date went with the app); "
            + "one read per launch (\(first) and \(second) requests), none after it; the screen's read is FamilyAutoCheckPolicy.screenReadsOnAppear "
            + "and the schedule's FamilyAutoCheckPolicy.eligible over Device's stand-ins for FamilyNotebookSharing.state, lastReadAt and the mark"
    }
}

// MARK: - 11/20: deleting the identity, and writing just before leaving

extension Scenarios {
    // MARK: S20

    static func s20(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)
        let b = f.b
        let hidden = UUID().uuidString
        b.hideEntry(hidden)
        let old = try required(b.notebookIdentity, "B has a notebook identity")
        let oldScope = try FamilySharingLocalData.notebookScope(endpoint: relay.endpoint, personID: old.personID, deviceID: old.deviceID)
        let familyPrefix = Device.namespace + ".family."
        let folder = b.support.appendingPathComponent("FamilyNotebook-v1", isDirectory: true).appendingPathComponent(oldScope, isDirectory: true)
        try expect(b.keptName == "合成のB" && b.hiddenEntryIDs == [hidden], "B's name and hidden entry are kept as before")
        try expect(b.keychain.namespaces(prefix: familyPrefix) == [familyPrefix + oldScope], "B's notebook keys are in its Keychain")
        try expect(FileManager.default.fileExists(atPath: folder.path), "B's notebook copy is in Application Support")

        Log.step("B: 「まどと家族の手帳のデータを消す」")
        let main = b.keychain.store(Device.namespace)
        do {
            _ = try await b.client.requestIdentityDeletion()
            Log.note("the local Worker accepted the deletion")
        } catch {
            Log.note("the local Worker has no identity deletion (\(error)); the relay's acceptance is modelled")
        }
        // ProductionGroupWindowClient's own record ("identity-deletion"), written before the request.
        var record = try GroupWire.decode(GroupIdentityDeletion.self,
            try required(try main.read("identity-deletion"), "the deletion record was kept before sending"))
        try expect(record.personID == old.personID && record.deviceID == (try old.deviceID), "the record names the deleted identity")
        if record.acceptedAt == nil {
            record.acceptedAt = Date()
            try main.write(GroupWire.encode(record), account: "identity-deletion", createOnly: false)
        }

        Log.step("The app closes before the clean-up; the next launch finishes it")
        try await b.relaunch()
        try expect(try await b.removeLocalDataAfterIdentityDeletion() == true, "the clean-up finishes")
        try expect(try await b.client.identityDeletionNeedingLocalCleanup() == nil, "and is not run again")
        try expect(try main.accounts(prefix: "") == ["identity-deletion"], "only the deletion record stays in B's own store")
        try expect(b.keychain.namespaces(prefix: familyPrefix).isEmpty, "no notebook Keychain is left")
        try expect(!FileManager.default.fileExists(atPath: folder.path), "the notebook copy is gone")
        for suffix in [".display-name", FamilyHiddenOperationsMemory.namespaceSuffix] {
            try expect(b.keychain.namespaces(prefix: Device.namespace + suffix).isEmpty, "nothing is kept under \(suffix)")
        }

        Log.step("B makes a new identity on the same iPhone")
        try await b.relaunch()
        let fresh = try await b.client.familyNotebookIdentity()
        try expect(fresh.personID != old.personID, "a new person")
        let history = try main.accounts(prefix: "identity-deletion")
        try expect(history.count == 1 && history[0].hasPrefix("identity-deletion-history:"), "the old record moved to its history")
        try expect(b.keptName == nil && b.rememberedName == "", "no old name is offered")
        try expect(b.hiddenEntryIDs.isEmpty, "no old hidden entry comes back")
        let state = await b.pass()
        try expect(state == .notInFamily, "the new person is in no family (got \(String(describing: state)))")
        try expect((try b.keychain.store(familyPrefix + oldScope).accounts(prefix: "")).isEmpty, "the old notebook keys stay gone")
        return "real: ProductionGroupWindowClient's record, key removal and new identity, FamilySharingLocalData over B's Keychain and Application Support, the local Worker for the new identity; modelled: the relay's acceptance (the local Worker runs without GROUP_IDENTITY_ERASURE_ENABLED), the UserDefaults step (Device's stand-ins), and the iCloud person key (RootSyncStore.removeExact, iOS only)"
    }

    // MARK: S21

    static func s21(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)
        let store = try required(f.b.service.notebook, "B has a notebook copy")
        let author = try required(f.b.service.author, "B has an author")

        Log.step("B writes and leaves at once, before any read sends it")
        let written = try store.edit(target: .init(familyCatID: f.cat, field: .name), value: .text("合成のくろ"), author: author)
        try expect(try store.pendingOperations().map(\.id) == [written.id], "B's write waits to be sent")
        let mark = relay.transport.log.count
        let result = try await f.b.service.leaveFamily(operationID: UUID())
        try expect(result == .confirmed, "B left (got \(result))")
        try expect(try store.snapshot().sharingEnded && store.pendingOperations().isEmpty, "B's copy ended")
        let posts = f.b.notebookWrites(since: mark)
        try expect(posts.contains { $0.hasSuffix("/crypto/operations") }, "B sent its write before leaving (sent: \(posts))")

        Log.step("A reads B's write")
        let copy = try required(f.a.service.notebook, "A has a notebook copy")
        try await settle("A has B's write", [f.a]) { try copy.snapshot().operations.contains { $0.id == written.id } }
        let name = try copy.snapshot().fieldState(for: .init(familyCatID: f.cat, field: .name))
        try expect(name?.operation.value == .text("合成のくろ") && name?.operation.author.personID == author.personID, "A shows B's name for the cat")
        return "real: the service's leave (one send pass, then the leave) against the local Worker, and A's read; the notebook screen's edit is the store's edit"
    }

    // MARK: S22

    static func s22(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)
        let person = try required(f.b.notebookIdentity?.personID, "B has no person")

        Log.step("B's new iPhone recovers B (機種変更), then gets a usual identity of its own")
        let b2 = try await Device.make("B2", relay: relay, cloud: f.b.cloud)
        let recovered = try await recoverAlone(b2, person: person, family: f.id)
        try await settle("B2 reads as recovered B", [f.a, b2]) { b2.inFamily }
        let own = try await b2.client.familyNotebookIdentity()
        try expect(own.personID != person, "B2's usual identity is another person")
        b2.rememberName("合成のB")
        let hidden = UUID().uuidString
        b2.hideEntry(hidden)
        let scope = try required(FamilySharingLocalData.recoveryScope(personID: person), "B's recovery scope")
        let notebook = try FamilySharingLocalData.notebookScope(endpoint: relay.endpoint, personID: person, deviceID: recovered.deviceID)
        let folder = b2.support.appendingPathComponent("FamilyNotebook-v1", isDirectory: true).appendingPathComponent(notebook, isDirectory: true)
        let links = b2.keychain.store(Device.namespace + Device.recoveryLinkSuffix)
        func recoveredStays(_ when: String) throws {
            try expect(try b2.keychain.store(Device.namespace + ".recovery." + scope).read("identity") != nil, "\(when): B's recovered device stays")
            try expect(try links.read(FamilyNotebookIdentityChoice.linkAccount) != nil, "\(when): the recovery link stays")
            try expect(FileManager.default.fileExists(atPath: folder.path)
                       && !b2.keychain.namespaces(prefix: Device.namespace + ".family." + notebook).isEmpty, "\(when): B's notebook copy stays")
            try expect(b2.keptName == "合成のB" && b2.rememberedName == "合成のB" && b2.hiddenEntryIDs == [hidden],
                       "\(when): the name and hidden entry B uses stay")
        }

        Log.step("B2 deletes its usual identity; the relay's acceptance is modelled as in S20")
        let main = b2.keychain.store(Device.namespace)
        do { _ = try await b2.client.requestIdentityDeletion() } catch {
            Log.note("the local Worker has no identity deletion (\(error)); the relay's acceptance is modelled")
        }
        var record = try GroupWire.decode(GroupIdentityDeletion.self,
            try required(try main.read("identity-deletion"), "the deletion record was kept before sending"))
        try expect(record.personID == own.personID, "the record names B2's usual identity, not B")
        if record.acceptedAt == nil {
            record.acceptedAt = Date()
            try main.write(GroupWire.encode(record), account: "identity-deletion", createOnly: false)
        }
        try expect(try await b2.removeLocalDataAfterIdentityDeletion() == true, "the clean-up finishes")
        try expect(try main.read("identity") == nil, "B2's usual identity is gone")
        try recoveredStays("after the deletion")

        Log.step("An accepted record from before 11/20 (no person) at the next launch")
        let old = GroupIdentityDeletion(operationID: UUID(), receipt: GroupWire.base64(Data(repeating: 2, count: 32)),
                                        acceptedAt: Date(), completedAt: nil)
        try main.write(GroupWire.encode(old), account: "identity-deletion", createOnly: false)
        try await b2.relaunch()
        try expect(try await b2.removeLocalDataAfterIdentityDeletion() == true, "it is only marked done")
        try expect(try await b2.client.identityDeletionNeedingLocalCleanup() == nil, "and not offered again")
        try recoveredStays("after the old record")

        Log.step("B2's notebook still reads as recovered B")
        try await settle("B2 reads as recovered B again", [b2]) { b2.inFamily }
        try expect(b2.notebookDeviceID == (try? recovered.deviceID), "B2's notebook uses the recovered device")
        return "real: the client's record and key removal, FamilySharingLocalData over B2's Keychain and Application Support, recovery and the notebook against the local Worker; modelled: the relay's acceptance (as S20) and the UserDefaults stand-ins"
    }
}
