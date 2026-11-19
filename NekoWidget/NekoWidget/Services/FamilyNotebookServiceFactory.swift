import Foundation
import UIKit

@MainActor
enum FamilyNotebookServiceFactory {
    static var productionRequested: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "FamilyNotebookProductionEnabled") as? String) == "YES"
    }
    static func make() -> any FamilyNotebookSharingService {
        guard productionRequested else { return FamilyNotebookPrototypeSharing() }
        // Keep the production adapter even if configuration is incomplete. A
        // requested real build must fail closed, never impersonate a family
        // by falling back to the locally simulated prototype.
        return ProductionFamilyNotebookSharingService(provider: {
            let configuration = SharingAPIConfiguration.current
            guard configuration.isGroupRuntimeAvailable,
                  let endpoint = configuration.baseURL, let client = GroupWindowClientProvider.production,
                  let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw FamilySharingError.serviceUnavailable
            }
            // 11/19 (機種変更 水準2): FamilyNotebookIdentityChoice decides.
            let identity: GroupDeviceIdentity
            if let recovered = try await FamilyNotebookServiceFactory.recoveredIdentity(client) { identity = recovered }
            else { identity = try await client.familyNotebookIdentity() }
            let scope = try GroupWire.base64(GroupCanonical.hash(GroupCanonical.fields([
                Data(endpoint.absoluteString.utf8), Data(identity.personID.utf8), Data(identity.deviceID.utf8)])))
            let directory = root.appendingPathComponent("FamilyNotebook-v1", isDirectory: true).appendingPathComponent(scope, isDirectory: true)
            let journal = try GroupOperationStore(directory: directory.appendingPathComponent("http", isDirectory: true), maximumRecordBytes: 2_100_000)
            let secrets = try GroupKeychainStore(namespace: GroupWindowClientProvider.namespace + ".family." + scope)
            return try FamilyNotebookSession(endpoint: endpoint, identity: identity, transport: GroupURLSessionTransport(),
                journal: journal, secrets: secrets, directory: directory.appendingPathComponent("notebooks", isDirectory: true),
                pinSync: FamilyNotebookServiceFactory.pinSync())
        }, billing: {
            guard let client = GroupWindowClientProvider.production else { throw FamilySharingError.serviceUnavailable }
            try await client.connectExistingBillingAccount()
        }, displayName: { try GroupWire.name(GroupDisplayName.remembered) }, catNames: { FamilyNotebookPrototype.shared.catNames },
        privateFarewellDay: { tool, profile in
            try FamilyNotebookPrivateFarewell.day(json: UserDefaults.standard.string(forKey: CatFarewell.key) ?? "",
                toolCatID: tool, profileID: profile)
        }, hasPersonalPlus: { PlusPurchaseStore.productionShared.entitlementState.permitsPersonalPlus },
        hasExistingIdentity: {
            guard let client = GroupWindowClientProvider.production else { throw FamilySharingError.serviceUnavailable }
            if try await client.hasExistingIdentity() { return true }
            return try await FamilyNotebookServiceFactory.recoveredIdentity(client) != nil
        }, photoRuntimeEnabled: representativePhotoRuntimeEnabled, photoTransport: GroupURLSessionTransport(),
        moderationRecipient: { FamilyNotebookServiceFactory.moderationRecipient() },
        photoTrace: { FamilyPhotoDeliveryDiagnostics.note($0) })
    }

    /// 11/19 (機種変更 水準2): the recovered person's identity when
    /// FamilyNotebookIdentityChoice picks it (the recovery screen linked the
    /// notebook); nil keeps the iPhone's usual identity. Builds without the
    /// recovery screen never have a link.
    static func recoveredIdentity(_ client: ProductionGroupWindowClient) async throws -> GroupDeviceIdentity? {
        // 11/19: the App Store build carries 機種変更 (the relay decides).
        guard recoveryRuntimeCarried else { return nil }
        let namespace = GroupWindowClientProvider.namespace
        let usual = try await client.existingPersonID(), usualDevice = try await client.existingDeviceID()
        return try FamilyNotebookIdentityChoice.load(links: GroupKeychainStore(namespace: namespace + recoveryLinkSuffix),
            recoveryStore: { try GroupKeychainStore(namespace: namespace + ".recovery." + $0) },
            usualPersonID: usual, usualDeviceID: usualDevice)
    }
    /// 11/19: internal builds as before; the App Store build only with 機種変更's
    /// client (SharingAPIConfiguration.groupRecoveryRuntimeEnabled).
    private static var recoveryRuntimeCarried: Bool {
#if DEBUG || INTERNAL_PRESENTATION
        return true
#else
        return SharingAPIConfiguration.groupRecoveryRuntimeEnabled
#endif
    }
    /// Where the recovery screen keeps FamilyNotebookIdentityChoice.Link.
    static let recoveryLinkSuffix = ".notebook-recovery"
    /// 11/19: the recovery screen linked the notebook on this iPhone (設定
    /// keeps the notebook's row while its copy has not arrived).
    static func hasRecoveryLink() -> Bool {
        guard productionRequested, recoveryRuntimeCarried else { return false }
        let links = try? GroupKeychainStore(namespace: GroupWindowClientProvider.namespace + recoveryLinkSuffix)
        return (try? links?.read(FamilyNotebookIdentityChoice.linkAccount)) != nil
    }

    /// 11/19: the roster pin next to the person key in iCloud Keychain, in the
    /// builds that sync the person key (the same access group); nil elsewhere.
    static func pinSync() -> (any FamilyNotebookPinSync)? {
        guard recoveryRuntimeCarried, let bundleID = Bundle.main.bundleIdentifier,
              let accessGroup = Bundle.main.object(forInfoDictionaryKey: "RootSyncKeychainAccessGroup") as? String,
              accessGroup.hasSuffix("." + bundleID) else { return nil }
        return FamilyNotebookStoredPinSync(store: FamilyNotebookSyncedKeychainStore(
            service: bundleID + ".family-notebook-pin.v1", accessGroup: accessGroup))
    }

    /// The same reviewed recipient as a まど report, pinned in the app's
    /// configuration; never one from a server reply.
    static func moderationRecipient() -> (keyID: String, publicKey: Data)? {
        let configuration = SharingAPIConfiguration.current
        guard let keyID = configuration.moderationKeyID, let key = configuration.moderationPublicKey,
              GroupReportCrypto.acceptsRecipient(keyID: keyID, publicKey: key, configuration: configuration) else { return nil }
        return (keyID, key)
    }

    /// 11/19: the App Store build and the owner's staging trial carry the
    /// representative photo; the relay's gate (503 `photo_feature_disabled`)
    /// decides, and the service stops asking once it says off.
    static var representativePhotoRuntimeEnabled: Bool {
        SharingAPIConfiguration.representativePhotoRuntimeEnabled
    }

    /// The reporter's private receipt list, without loading family membership.
    /// 11/20: signed by the identity the notebook session uses (the report was
    /// sent with it): the recovered one after 機種変更, else the usual one.
    static func reportReplies() async throws -> [FamilyPhotoReportReply] {
        guard productionRequested, let client = GroupWindowClientProvider.production else {
            throw FamilyNotebookTransportError.unavailable
        }
        return try await client.familyPhotoReportReplies(as: recoveredIdentity(client))
    }

    /// The screens' way to the photo; nil while it is off.
    static func representativePhotoBackend() -> (any FamilyRepresentativePhotoBackend)? {
        guard representativePhotoRuntimeEnabled, productionRequested,
              let service = FamilyNotebookSharing.shared.service as? ProductionFamilyNotebookSharingService,
              service.representativePhotosEnabled else { return nil }
        return ProductionFamilyRepresentativePhotoBackend(service: service)
    }
}

#if INTERNAL_PRESENTATION
/// 11/19 (2台試験だけ): B's iPhone, used as A's new iPhone in the trial, goes
/// back to being B in the family notebook, and A's next recovery on it
/// registers a fresh device. Removed, on this iPhone only: the notebook's
/// recovery link, A's recovered device keys (its recovery Keychain, journal
/// and outbox), that device's notebook copy and its creator-photo records.
/// Never this iPhone's own identity, the person key in iCloud Keychain, or
/// the notebook on the relay. Does nothing on A's own iPhone.
@MainActor
enum FamilyNotebookOwnerTrialReset {
    static func forgetRecovery() async throws -> String {
        guard let trial = OwnerTwoDeviceTrialConfiguration.current,
              let client = GroupWindowClientProvider.production,
              let endpoint = SharingAPIConfiguration.current.baseURL,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw FamilySharingError.serviceUnavailable }
        if try await client.existingPersonID() == trial.owner { return "この端末はAです。戻すものはありません。" }
        let namespace = GroupWindowClientProvider.namespace
        let links = try GroupKeychainStore(namespace: namespace + FamilyNotebookServiceFactory.recoveryLinkSuffix)
        // The recovery scope of A's root (the trial's owner is its hash).
        let ownerScope = try GroupWire.bytes(trial.owner, count: 32).map { String(format: "%02x", $0) }.joined()
        var scopes: Set<String> = [ownerScope], families: Set<UUID> = [trial.family]
        if let bytes = try links.read(FamilyNotebookIdentityChoice.linkAccount),
           let link = try? GroupWire.decode(FamilyNotebookIdentityChoice.Link.self, bytes) {
            if link.scope.utf8.count == 64, link.scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                scopes.insert(link.scope)
            }
            families.formUnion(link.familyIDs)
        }
        // The link first: the notebook stops using the recovered identity.
        try links.remove(FamilyNotebookIdentityChoice.linkAccount)
        FamilyNotebookSharing.shared.restartSession()
        for scope in scopes.sorted() {
            let recovery = try GroupKeychainStore(namespace: namespace + ".recovery." + scope)
            if let saved = try recovery.read("identity") {
                let identity = try GroupWire.decode(GroupDeviceIdentity.self, saved)
                // The same scope the provider above gives that device's notebook.
                let notebook = try GroupWire.base64(GroupCanonical.hash(GroupCanonical.fields([
                    Data(endpoint.absoluteString.utf8), Data(identity.personID.utf8), Data(identity.deviceID.utf8)])))
                let secrets = try GroupKeychainStore(namespace: namespace + ".family." + notebook)
                for account in try secrets.accounts(prefix: "") { try secrets.remove(account) }
                try? FileManager.default.removeItem(at: support.appendingPathComponent("FamilyNotebook-v1", isDirectory: true)
                    .appendingPathComponent(notebook, isDirectory: true))
            }
            let journal = try GroupKeychainStore(namespace: namespace + ".recovery-journal." + scope)
            for store in [recovery, journal] {
                for account in try store.accounts(prefix: "") { try store.remove(account) }
            }
            try? FileManager.default.removeItem(at: support.appendingPathComponent("GroupTransport-v3", isDirectory: true)
                .appendingPathComponent("recovery-" + scope, isDirectory: true))
        }
        for family in families { FamilyRepresentativePhotos.forgetSyncRecords(family) }
        _ = await FamilyNotebookSharing.shared.refreshAfterPlusChange(reportsFailure: false)
        return "この端末をBに戻しました。"
    }
}
#endif

/// 11/18 (TestFlight 388): each stage of a family photo delivery in the unified
/// log and, in the owner's trial builds, in 診断ログ (設定 → ログ): a stage
/// name, the relay's HTTP status and a fixed code only.
enum FamilyPhotoDeliveryDiagnostics {
    static func note(_ note: FamilyPhotoDeliveryNote) {
        FamilyPhotoDeliveryLog.system(note)
#if INTERNAL_PRESENTATION && !NEKO_SHARE_EXTENSION
        var metadata = ["familyPhotoStage": note.stage.rawValue]
        if let status = note.status { metadata["familyPhotoStatus"] = String(status) }
        if let code = note.code { metadata["familyPhotoCode"] = code }
        SharedLog.app.info("family-photo", "Family photo delivery stage", metadata: metadata)
#endif
    }
}

/// 11/19 (2台試験): when the relay's silent push FamilyDeviceRegisteredPush
/// came and when its one notebook pass ended, with the outcome and the time
/// between, in 診断ログ of the owner's trial builds. No ID, token or key.
enum FamilyDevicePushDiagnostics {
    enum Outcome: String { case read, notRead, skipped }
    /// 11/19 (build 394): why it was skipped, or what it waited for first.
    enum Reason: String { case notReal, noFamily, working, passRunning, budgetPaused }
    static func received() {
#if INTERNAL_PRESENTATION && !NEKO_SHARE_EXTENSION
        SharedLog.app.info("family-device-push", "Family device push received",
                           metadata: ["familyDevicePush": "received"])
#endif
    }
    static func finished(_ outcome: Outcome, since start: Date, reason: Reason? = nil) {
#if INTERNAL_PRESENTATION && !NEKO_SHARE_EXTENSION
        let milliseconds = max(0, Int(Date().timeIntervalSince(start) * 1_000))
        var metadata = ["familyDevicePush": "finished", "familyDevicePushOutcome": outcome.rawValue,
                        "durationMs": String(milliseconds)]
        if let reason { metadata["familyDevicePushReason"] = reason.rawValue }
        SharedLog.app.info("family-device-push", "Family device push pass finished", metadata: metadata)
#endif
    }
}

/// The real service behind the screens' photo model.
@MainActor
final class ProductionFamilyRepresentativePhotoBackend: FamilyRepresentativePhotoBackend {
    private let service: ProductionFamilyNotebookSharingService
    init(service: ProductionFamilyNotebookSharingService) { self.service = service }
    var myPersonID: String? { service.personID }
    var canWrite: Bool { service.representativePhotoWritable }
    var relayAnswer: FamilyPhotoServerState { service.photoServer }
    func probe() async { await service.probeRepresentativePhotos() }
    func displayName(of personID: String) -> String? {
        FamilyNotebookPrototype.shared.members.first { $0.personID == personID }?.displayName
    }
    func author(of cat: UUID) -> String? { service.representativePhotoAuthor(familyCatID: cat) }
    func referencedAsset(of cat: UUID) -> UUID? { service.representativePhotoAsset(familyCatID: cat) }
    func load(_ cats: [UUID]) async throws -> [UUID: FamilyNotebookPhotoLoad] {
        try await service.representativePhotos(familyCatIDs: cats)
    }
    func deliver(_ cat: UUID, source: Data) async throws { try await service.deliverRepresentativePhoto(familyCatID: cat, source: source) }
    func hasPending(_ cat: UUID) -> Bool { service.hasPendingRepresentativePhoto(familyCatID: cat) }
    func retry(_ cat: UUID) async throws { try await service.retryRepresentativePhoto(familyCatID: cat) }
    func clear(_ cat: UUID) async throws {
        try service.clearRepresentativePhoto(familyCatID: cat)
        // 11/19: automatic, as the rest of the creator's photo: the
        // notebook's next pass sends it.
        FamilyNotebookAutoCheck.shared.sendSoon()
    }
    func report(assetID: UUID, reason: GroupReportReason) async throws -> String {
        try await service.reportRepresentativePhoto(assetID: assetID, reasonCode: reason.rawValue)
    }
    func hide(_ personID: String) async throws { try await service.hideRepresentativePhotos(of: personID) }
    func unhide(_ personID: String) async throws { try await service.showRepresentativePhotos(of: personID) }
}

#if DEBUG
/// `--cat-home-stress-family-photo` (11/17): the family's representative
/// photo through the real client (FamilyNotebookRepresentativePhotoClient)
/// and a synthetic relay on this iPhone: synthetic identities, roster
/// and key, the drawn sample cat, no network, no real photo.
@MainActor
final class FamilyRepresentativePhotoFixture: FamilyRepresentativePhotoBackend {
    static let argument = "--cat-home-stress-family-photo"
    /// A sample name for the other family member.
    static let otherName = "ゆい"
    private let family: UUID
    private let me: GroupDeviceIdentity
    private let other: GroupDeviceIdentity
    private let roster: VerifiedFamilyNotebookRoster
    private let key: Data
    private let client: FamilyNotebookRepresentativePhotoClient
    private let relay: FamilyPhotoFixtureRelay
    private var references: [UUID: (reference: FamilyNotebookRepresentativePhotoReference, authorID: String)] = [:]
    private var shownJPEG: [UUID: Data] = [:]
    private var delivered: [UUID: FamilyNotebookRepresentativePhotoClient.Pending] = [:]

    private init(family: UUID, me: GroupDeviceIdentity, other: GroupDeviceIdentity, roster: VerifiedFamilyNotebookRoster,
                 key: Data, client: FamilyNotebookRepresentativePhotoClient, relay: FamilyPhotoFixtureRelay) {
        self.family = family; self.me = me; self.other = other; self.roster = roster
        self.key = key; self.client = client; self.relay = relay
    }

    static func make(cat: UUID) async throws -> FamilyRepresentativePhotoFixture {
        let family = UUID(), key = Data(repeating: 7, count: 32)
        var me = GroupDeviceIdentity.firstDevice(); me.registered = true
        var other = GroupDeviceIdentity.firstDevice(); other.registered = true
        let members = try [me, other].map { identity in
            FamilyNotebookCryptoMember(personID: identity.personID, identityPublicKey: identity.personPublicKey,
                devices: [try identity.certificate(windowID: family.uuidString.lowercased())])
        }
        let value = FamilyNotebookCryptoRoster(familyID: family, epoch: 1, previousHash: Data(repeating: 0, count: 32),
            keyCommitment: GroupCanonical.hash(key), members: members)
        let signed = try FamilyNotebookRosterCrypto.sign(value, deviceID: try other.deviceID, signingKey: other.signingKey)
        let roster = try FamilyNotebookRosterCrypto.restore(signed,
            trustedPin: .init(familyID: family, epoch: 1, hash: GroupCanonical.hash(value.canonicalBytes())))
        let relay = FamilyPhotoFixtureRelay(family: family)
        let journal = try GroupOperationStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("family-photo-fixture-" + UUID().uuidString, isDirectory: true), maximumRecordBytes: 2_100_000)
        let client = FamilyNotebookRepresentativePhotoClient(familyID: family, endpoint: URL(string: "https://fixture.invalid")!,
            identity: me, transport: relay, journal: journal, runtimeEnabled: true)
        let fixture = FamilyRepresentativePhotoFixture(family: family, me: me, other: other, roster: roster, key: key,
                                                       client: client, relay: relay)
        // The other person's photo, sealed as the client seals it.
        guard let source = AppStoreScreenshotFixture.CatHomeStress.image(
            for: AppStoreScreenshotFixture.CatHomeStress.photoPrefix + "normal-2")?.jpegData(compressionQuality: 0.9)
        else { throw FamilyNotebookCryptoError.invalid }
        let pixels = try FamilyNotebookRepresentativePhotoImage.prepare(source)
        let slotID = FamilyNotebookRepresentativePhotoCrypto.slotID(familyID: family, catID: cat)
        let sealed = try FamilyNotebookRepresentativePhotoCrypto.seal(jpeg: pixels.jpeg, width: pixels.width,
            height: pixels.height, familyID: family, slotID: slotID, assetID: UUID(), revision: 1, roster: roster)
        await relay.place(.init(slotID: slotID, revision: 1, assetID: sealed.reference.assetID,
            ciphertextSHA256: sealed.reference.ciphertextSHA256, ciphertextBytes: sealed.ciphertext.count,
            keyEpoch: 1, authorID: other.personID), ciphertext: sealed.ciphertext)
        fixture.references[cat] = (sealed.reference, other.personID)
        return fixture
    }

    var myPersonID: String? { me.personID }
    var canWrite: Bool { true }
    func displayName(of personID: String) -> String? { personID == other.personID ? Self.otherName : nil }
    func author(of cat: UUID) -> String? { delivered[cat] != nil ? me.personID : references[cat]?.authorID }
    func referencedAsset(of cat: UUID) -> UUID? { references[cat]?.reference.assetID }

    func load(_ cats: [UUID]) async throws -> [UUID: FamilyNotebookPhotoLoad] {
        let hidden = try await client.hiddenAuthors()
        let slots = try await client.slots()
        var result: [UUID: FamilyNotebookPhotoLoad] = [:]
        for cat in cats {
            guard let found = references[cat] else { result[cat] = FamilyNotebookPhotoLoad.none; continue }
            if hidden.contains(found.authorID) { result[cat] = .hidden(authorID: found.authorID); continue }
            guard let slot = slots.first(where: { $0.slotID == found.reference.slotID }) else {
                result[cat] = FamilyNotebookPhotoLoad.none; continue
            }
            if let jpeg = try await client.image(slot: slot, reference: found.reference, roster: roster,
                                                 verifiedAuthorID: found.authorID) {
                shownJPEG[found.reference.assetID] = jpeg
                result[cat] = .shown(assetID: found.reference.assetID, authorID: found.authorID, jpeg: jpeg)
            } else { result[cat] = FamilyNotebookPhotoLoad.none }
        }
        return result
    }

    func deliver(_ cat: UUID, source: Data) async throws {
        let slotID = FamilyNotebookRepresentativePhotoCrypto.slotID(familyID: family, catID: cat)
        let revision = try await client.slots().first { $0.slotID == slotID }?.revision ?? 0
        let pending = try FamilyNotebookRepresentativePhotoClient.prepare(source: source, familyID: family, catID: cat,
            expectedRevision: revision, generation: 1, nextClock: 1,
            author: .init(personID: me.personID, displayName: "自分"), identity: me, roster: roster,
            epochKey: key, observedOperationIDs: [])
        try await client.deliver(pending)
        delivered[cat] = pending
    }
    /// Nothing waits here: a second try delivers from the photo again.
    func hasPending(_ cat: UUID) -> Bool { false }
    func retry(_ cat: UUID) async throws {
        guard let pending = delivered[cat] else { throw FamilyNotebookPhotoFailure.failed }
        try await client.deliver(pending)
    }
    func clear(_ cat: UUID) async throws {
        delivered[cat] = nil
        await relay.clear(FamilyNotebookRepresentativePhotoCrypto.slotID(familyID: family, catID: cat))
    }
    func report(assetID: UUID, reason: GroupReportReason) async throws -> String {
        guard let jpeg = shownJPEG[assetID] else { throw FamilyNotebookPhotoFailure.unavailable }
        // The same pinned recipient as a real build: none in this
        // configuration means 「いまは通報できません」, never another key.
        guard let recipient = FamilyNotebookServiceFactory.moderationRecipient() else { throw FamilyNotebookPhotoFailure.unavailable }
        let pending = try await client.prepareReport(canonicalJPEG: jpeg, assetID: assetID, reasonCode: reason.rawValue,
            moderationKeyID: recipient.keyID, moderationPublicKey: recipient.publicKey)
        return try await client.report(pending).reportID
    }
    func hide(_ personID: String) async throws { try await client.hideAuthor(personID) }
    func unhide(_ personID: String) async throws { try await client.unhideAuthor(personID) }
}


/// The relay of `--cat-home-stress-family-photo`: answers the representative
/// photo calls on this iPhone (slots, the encrypted asset and its status, a
/// delivery, a report) as the relay's contract says. Nothing leaves the iPhone.
actor FamilyPhotoFixtureRelay: GroupHTTPTransport {
    private let family: UUID
    private var slots: [UUID: FamilyNotebookRepresentativePhotoClient.Slot] = [:]
    private var assets: [UUID: Data] = [:]
    private var reservations: [UUID: FamilyNotebookRepresentativePhotoClient.Reservation] = [:]
    private var authors: [UUID: String] = [:]

    init(family: UUID) { self.family = family }

    func place(_ slot: FamilyNotebookRepresentativePhotoClient.Slot, ciphertext: Data) {
        slots[slot.slotID] = slot
        if let asset = slot.assetID { assets[asset] = ciphertext }
    }

    func clear(_ slotID: UUID) { slots[slotID] = nil }

    private func reply(_ value: [String: Any], status: Int = 200) throws -> GroupHTTPReply {
        GroupHTTPReply(status: status, data: try JSONSerialization.data(withJSONObject: value))
    }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        guard let path = request.url?.path else { throw FamilyNotebookTransportError.invalidResponse }
        let body = request.httpBody ?? Data()
        if path.hasSuffix("/slots") {
            struct Reply: Encodable { let schemaVersion: Int; let slots: [FamilyNotebookRepresentativePhotoClient.Slot] }
            return GroupHTTPReply(status: 200, data: try GroupWire.encode(Reply(schemaVersion: 1,
                slots: slots.values.sorted { $0.slotID.uuidString < $1.slotID.uuidString })))
        }
        if let range = path.range(of: "/assets/") {
            let rest = path[range.upperBound...]
            let id = UUID(uuidString: String(rest.prefix(36)))
            guard let id, slots.values.contains(where: { $0.assetID == id }), let bytes = assets[id] else {
                return try reply(["error": ["code": "photo_retired"]], status: 410)
            }
            if rest.hasSuffix("/status") {
                return try reply(["schemaVersion": 1, "assetId": id.uuidString.lowercased(), "available": true])
            }
            return GroupHTTPReply(status: 200, data: bytes)
        }
        if path.hasSuffix("/uploads") {
            let reservation = try GroupWire.decode(FamilyNotebookRepresentativePhotoClient.Reservation.self, body)
            reservations[reservation.assetID] = reservation
            return try reply(["schemaVersion": 1, "assetId": reservation.assetID.uuidString.lowercased(),
                              "uploadId": reservation.assetID.uuidString.lowercased(),
                              "reservedRevision": reservation.expectedRevision + 1, "state": "reserved"])
        }
        if path.hasSuffix("/commit"), let reservation = reservations.values.first(where: { path.contains($0.assetID.uuidString.lowercased()) }) {
            struct Commit: Decodable { let operationID: UUID; let payload: EncryptedFamilyNotebookOperation }
            let commit = try GroupWire.decode(Commit.self, body)
            slots[reservation.slotID] = .init(slotID: reservation.slotID, revision: reservation.expectedRevision + 1,
                assetID: reservation.assetID, ciphertextSHA256: reservation.ciphertextSHA256,
                ciphertextBytes: reservation.ciphertextBytes, keyEpoch: reservation.keyEpoch, authorID: commit.payload.personID)
            return try reply(["schemaVersion": 1, "assetId": reservation.assetID.uuidString.lowercased(),
                              "revision": reservation.expectedRevision + 1, "operationId": commit.operationID.uuidString.lowercased()])
        }
        if request.httpMethod == "PUT", let reservation = reservations.values.first(where: { path.contains($0.assetID.uuidString.lowercased()) }) {
            assets[reservation.assetID] = body
            return try reply(["schemaVersion": 1, "uploaded": true])
        }
        if path.hasSuffix("/reports") {
            struct Report: Decodable { let assetID: UUID }
            let report = try GroupWire.decode(Report.self, body)
            let now = Int64(Date().timeIntervalSince1970)
            return try reply(["schemaVersion": 1, "reportId": "FP-0000-0001", "familyId": family.uuidString.lowercased(),
                              "assetId": report.assetID.uuidString.lowercased(), "state": "committed",
                              "committedAt": now, "contentExpiresAt": now + 604_800])
        }
        return try reply(["error": ["code": "photo_request"]], status: 400)
    }
}
#endif
