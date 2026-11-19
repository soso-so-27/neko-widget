import Foundation

// The six two-device scenarios. Each one makes its own family with fresh
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
    ]

    // MARK: Common steps

    static func makeFamily(_ relay: Relay, notifications: Bool = false) async throws -> Family {
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

        Log.step("A puts one cat page into the notebook")
        let profile = UUID(), tool = UUID()
        let cat = try shareCat(a, name: "合成のしろ", profile: profile, tool: tool)
        let store = try required(a.service.notebook, "A has no notebook copy")
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

        Log.step("The reporter reads the reply: photo_stopped")
        let replies = try await b2.repliesAsNotebookIdentity()
        try expect(replies.contains { $0.status == .photoStopped }, "the reply list shows the photo stopped (got \(replies.map(\.status)))")
        var finding: String?
        do {
            let usual = try await b2.client.familyPhotoReportReplies()
            Log.note("the app's reply wiring (usual client) lists \(usual.count) replies")
        } catch {
            // FamilyNotebookServiceFactory.reportReplies reads with the usual
            // identity; an iPhone recovered only through the notebook has none.
            finding = "the app's reply list (usual identity) fails on B2: \(error)"
            print("::warning title=Two-device S5::\(finding!)")
            Log.note("FINDING: " + finding!)
        }

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
        return "A's local original (PhotoKit) not driven" + (finding.map { "; FINDING: " + $0 } ?? "")
    }

    // MARK: S6

    static func s6(_ relay: Relay) async throws -> String? {
        let f = try await makeFamily(relay)
        let creator = try required(f.a.notebookIdentity?.personID, "A has no person")
        try expect(try familyCats(f.b) == [f.cat], "B starts with one cat")

        Log.step("A deletes the app and installs it again (same person and device; the page is kept)")
        try await f.a.reinstall()
        try await settle("A reads the notebook again", [f.a]) { f.a.inFamily }
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
}
