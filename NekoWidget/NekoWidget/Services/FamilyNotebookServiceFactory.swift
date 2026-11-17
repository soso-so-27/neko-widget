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
            let identity = try await client.familyNotebookIdentity()
            let scope = try GroupWire.base64(GroupCanonical.hash(GroupCanonical.fields([
                Data(endpoint.absoluteString.utf8), Data(identity.personID.utf8), Data(identity.deviceID.utf8)])))
            let directory = root.appendingPathComponent("FamilyNotebook-v1", isDirectory: true).appendingPathComponent(scope, isDirectory: true)
            let journal = try GroupOperationStore(directory: directory.appendingPathComponent("http", isDirectory: true), maximumRecordBytes: 2_100_000)
            let secrets = try GroupKeychainStore(namespace: GroupWindowClientProvider.namespace + ".family." + scope)
            return try FamilyNotebookSession(endpoint: endpoint, identity: identity, transport: GroupURLSessionTransport(),
                journal: journal, secrets: secrets, directory: directory.appendingPathComponent("notebooks", isDirectory: true))
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
            return try await client.hasExistingIdentity()
        }, photoRuntimeEnabled: representativePhotoRuntimeEnabled, photoTransport: GroupURLSessionTransport(),
        moderationRecipient: { FamilyNotebookServiceFactory.moderationRecipient() })
    }

    /// The same reviewed recipient as a まど report, pinned in the app's
    /// configuration; never one from a server reply.
    static func moderationRecipient() -> (keyID: String, publicKey: Data)? {
        let configuration = SharingAPIConfiguration.current
        guard let keyID = configuration.moderationKeyID, let key = configuration.moderationPublicKey,
              GroupReportCrypto.acceptsRecipient(keyID: keyID, publicKey: key, configuration: configuration) else { return nil }
        return (keyID, key)
    }

    /// 11/17: the family's representative photo. No setting turns it on:
    /// the server's gate is off, and the client stays off with it in every
    /// build. While false, no 「…」 item appears and no photo call is made.
    /// Review captures use a synthetic relay instead
    /// (AppStoreScreenshotFixture.CatHomeStress, `--cat-home-stress-family-photo`).
    static let representativePhotoRuntimeEnabled = false

    /// The reporter's private receipt list, without loading family membership.
    static func reportReplies() async throws -> [FamilyPhotoReportReply] {
        guard productionRequested, let client = GroupWindowClientProvider.production else {
            throw FamilyNotebookTransportError.unavailable
        }
        return try await client.familyPhotoReportReplies()
    }

    /// The screens' way to the photo; nil while it is off.
    static func representativePhotoBackend() -> (any FamilyRepresentativePhotoBackend)? {
        guard representativePhotoRuntimeEnabled, productionRequested,
              let service = FamilyNotebookSharing.shared.service as? ProductionFamilyNotebookSharingService,
              service.representativePhotosEnabled else { return nil }
        return ProductionFamilyRepresentativePhotoBackend(service: service)
    }
}

/// The real service behind the screens' photo model.
@MainActor
final class ProductionFamilyRepresentativePhotoBackend: FamilyRepresentativePhotoBackend {
    private let service: ProductionFamilyNotebookSharingService
    init(service: ProductionFamilyNotebookSharingService) { self.service = service }
    var myPersonID: String? { service.personID }
    func displayName(of personID: String) -> String? {
        FamilyNotebookPrototype.shared.members.first { $0.personID == personID }?.displayName
    }
    func author(of cat: UUID) -> String? { service.representativePhotoAuthor(familyCatID: cat) }
    func load(_ cats: [UUID]) async throws -> [UUID: FamilyNotebookPhotoLoad] {
        try await service.representativePhotos(familyCatIDs: cats)
    }
    func deliver(_ cat: UUID, source: Data) async throws { try await service.deliverRepresentativePhoto(familyCatID: cat, source: source) }
    func retry(_ cat: UUID) async throws { try await service.retryRepresentativePhoto(familyCatID: cat) }
    func clear(_ cat: UUID) async throws {
        try service.clearRepresentativePhoto(familyCatID: cat)
        // The person's own read sends it (the caller marks the tap).
        _ = await FamilyNotebookSharing.shared.refreshAfterPlusChange(reportsFailure: false)
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
    func displayName(of personID: String) -> String? { personID == other.personID ? Self.otherName : nil }
    func author(of cat: UUID) -> String? { delivered[cat] != nil ? me.personID : references[cat]?.authorID }

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
