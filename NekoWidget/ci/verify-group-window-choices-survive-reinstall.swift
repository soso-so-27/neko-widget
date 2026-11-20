import CryptoKit
import Foundation

// 11/20: a person's protective choices in a まど survive deleting the app and
// installing it again. Deleting the app removes Application Support (and
// UserDefaults); this iPhone's device-only Keychain stays. Synthetic IDs,
// names and photos only. Built with the reporting sources (run-quick-ios-checks.sh).

// The standalone macOS executable has no app screens; these stand in for them.
enum InternalBuildPresentationAvailability { static let isAvailable = false }
enum GroupWindowClientProvider { static let namespace = "jp.nekowidget.verify-choices" }
enum GroupDisplayName {}
enum GroupWidgetCache {
    struct Entry { let windowID: String }
    static func entries() -> [Entry] { [] }
}

private enum ChoicesCheckFailure: Error { case failed(String) }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ChoicesCheckFailure.failed(message) }
}

/// The Keychain, in memory. `failing` makes every call fail, as a locked or
/// broken Keychain would.
private final class MemoryKeychain: GroupSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private let failing: Bool
    init(failing: Bool = false) { self.failing = failing }
    func read(_ account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if failing { throw GroupClientError.authenticationRequired }
        return values[account]
    }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw GroupClientError.authenticationRequired }
        if createOnly && values[account] != nil { throw GroupClientError.idempotencyConflict }
        values[account] = data
    }
    func remove(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw GroupClientError.authenticationRequired }
        values.removeValue(forKey: account)
    }
    func accounts(prefix: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        if failing { throw GroupClientError.authenticationRequired }
        return values.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
    func all() -> [String: Data] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Answers only the reporting-availability read; nothing is sent anywhere.
private struct AvailabilityOnly: GroupHTTPTransport {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        guard request.url?.path.hasSuffix("/reporting-availability") == true else { throw GroupClientError.offline }
        return GroupHTTPReply(status: 200, data: Data(#"{"protocolVersion":3,"reportingAvailable":true}"#.utf8))
    }
}

private func syntheticID(_ byte: UInt8) -> String { GroupWire.base64(Data(repeating: byte, count: 16)) }

private func entry(_ photo: String, from sender: String, minutesAgo: Double) -> GroupWindowLocalPhotoStore.Entry {
    .init(id: photo, senderParticipantID: sender, senderDisplayName: "合成の送り主",
          createdAt: Date(timeIntervalSinceNow: -minutesAgo * 60), isHidden: false, isOwn: false)
}

@main
@MainActor
private struct VerifyGroupWindowChoicesSurviveReinstall {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw ChoicesCheckFailure.failed("public crypto vector path required") }
        struct Vector: Decodable { let canonicalJPEGBase64: String }
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        guard let jpeg = Data(base64Encoded: vector.canonicalJPEGBase64) else { throw ChoicesCheckFailure.failed("synthetic JPEG") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("group-window-choices-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await reinstall(root, jpeg)
        try await olderInstall(root, jpeg)
        try await keychainFailure(root, jpeg)
        try bound()
        print("group window choices survive reinstall: ok")
    }

    static func reinstall(_ root: URL, _ jpeg: Data) async throws {
        let app = root.appendingPathComponent("reinstall", isDirectory: true)
        let photos = app.appendingPathComponent("GroupWindows", isDirectory: true)
        let reportsFolder = app.appendingPathComponent("GroupReports", isDirectory: true)
        let suite = "verify-choices-" + UUID().uuidString
        UserDefaults(suiteName: suite)?.set(true, forKey: "synthetic.launched")
        let kept = MemoryKeychain()
        let secrets = MemoryKeychain()
        let windowID = syntheticID(2), me = syntheticID(4), hiddenPerson = syntheticID(5), blockedPerson = syntheticID(6), other = syntheticID(7)
        let hiddenPhoto = syntheticID(10), blockedPhoto = syntheticID(11), removedPhoto = syntheticID(12), reportedPhoto = syntheticID(13), plainPhoto = syntheticID(14)

        // The identity and window records live in the Keychain, as on an iPhone.
        var identity = GroupDeviceIdentity.firstDevice(); identity.registered = true
        let anchor = GroupTrustAnchor(windowID: windowID, ownerPersonID: identity.personID, ownerIdentityPublicKey: identity.personPublicKey)
        let roster = try GroupRoster(windowID: windowID, revision: 1, keyEpoch: 1, previousHash: Data(repeating: 0, count: 32),
            ownerPersonID: identity.personID, members: [.init(participantID: me, personID: identity.personID,
                identityPublicKey: identity.personPublicKey, role: .owner, devices: [identity.certificate(windowID: windowID)])])
        let packet = try GroupRosterVerifier.sign(roster, deviceID: identity.deviceID, privateKey: identity.signingKey)
        let verified = try GroupRosterVerifier.verify(packet, anchor: anchor)
        try secrets.write(GroupWire.encode(identity), account: "identity", createOnly: true)
        try secrets.write(GroupWire.encode(GroupLocalWindow(anchor: anchor, packet: packet, pinnedRevision: 1,
            pinnedHash: verified.hash, keys: [:], rosterHashes: [:], left: false, minimumAdmissionRevision: 0)),
            account: "window:" + windowID, createOnly: true)

        func reporting() throws -> ProductionGroupReporting {
            try FileManager.default.createDirectory(at: reportsFolder, withIntermediateDirectories: true)
            return try ProductionGroupReporting(endpoint: URL(string: ProductionGroupReporting.stagingEndpoint)!,
                secrets: secrets, transport: AvailabilityOnly(), directory: reportsFolder,
                publicKey: GroupReportCrypto.moderationPublicKey, kept: kept) { window, photo in
                    GroupReportEvidence(windowID: window, photoID: photo, canonicalJPEG: jpeg)
                }
        }

        // Before: the person hides one person, blocks another, removes a photo, reports a photo.
        let before = GroupWindowLocalPhotoStore(root: photos, keychain: { kept })
        await before.remember(windowID: windowID, name: "合成のまど", myParticipantID: me)
        for (photo, sender, minutes) in [(hiddenPhoto, hiddenPerson, 1.0), (blockedPhoto, blockedPerson, 2.0),
                                         (removedPhoto, other, 3.0), (reportedPhoto, other, 4.0), (plainPhoto, other, 5.0)] {
            try await before.save(entry(photo, from: sender, minutesAgo: minutes), jpeg: jpeg, windowID: windowID)
        }
        await before.hide(memberID: hiddenPerson, name: "合成のひと", windowID: windowID)
        await before.hide(memberID: blockedPerson, name: "合成のブロック", windowID: windowID, blocked: true)
        try await before.remove(photoID: removedPhoto, windowID: windowID)
        let firstReporting = try reporting()
        _ = try await firstReporting.prepareReport(windowID: windowID, photoID: reportedPhoto, senderName: "合成の送り主",
            reason: .privacy, consent: .init(acceptedAt: Date()))
        // The relay's receipt reaches the same Keychain copy as submitReport's keepCopy.
        GroupWindowKept.keepReport(photoID: reportedPhoto, receiptNumber: "R-0123-4567-89", sentAt: Date(),
                                   windowID: windowID, in: kept)
        let coveredBefore = try await firstReporting.locallyReportedPhotoIDs(windowID: windowID)
        try require(coveredBefore.contains(reportedPhoto), "a reported photo is covered before reinstall")

        // Only opaque IDs, the receipt number and dates are in the Keychain copy.
        for (account, data) in kept.all() {
            let text = String(decoding: data, as: UTF8.self)
            for forbidden in ["合成", "privacy", "senderName", "reason", "caption", "name\""] {
                try require(!text.contains(forbidden), "\(account) keeps only IDs, numbers and dates")
            }
        }

        // Reinstall: Application Support and UserDefaults go; the Keychain stays.
        try FileManager.default.removeItem(at: app)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try require(UserDefaults(suiteName: suite)?.object(forKey: "synthetic.launched") == nil, "UserDefaults suite wiped")

        let after = GroupWindowLocalPhotoStore(root: photos, keychain: { kept })
        let windowsAfterReinstall = await after.knownWindows()
        try require(windowsAfterReinstall.isEmpty, "local files are new")
        await after.remember(windowID: windowID, name: "合成のまど", myParticipantID: me,
                             memberNames: [hiddenPerson: "合成のひと", blockedPerson: "合成のブロック"])
        let restored = await after.knownWindows().first { $0.id == windowID }?.hiddenMembers ?? []
        try require(restored.contains { $0.id == hiddenPerson && $0.blocked != true && $0.name == "合成のひと" },
                    "a hidden person stays hidden after reinstall")
        try require(restored.contains { $0.id == blockedPerson && $0.blocked == true && $0.name == "合成のブロック" },
                    "a block is listed after reinstall")
        // The relay lists the photos again: the removed one is not downloaded again.
        let removedKnown = await after.contains(photoID: removedPhoto, windowID: windowID)
        try require(removedKnown, "a removed photo is not accepted again")
        // What sync does with each listed photo: receive only what is not known yet.
        for (photo, sender, minutes) in [(hiddenPhoto, hiddenPerson, 1.0), (blockedPhoto, blockedPerson, 2.0),
                                         (removedPhoto, other, 3.0), (reportedPhoto, other, 4.0), (plainPhoto, other, 5.0)] {
            let known = await after.contains(photoID: photo, windowID: windowID)
            if !known { try await after.save(entry(photo, from: sender, minutesAgo: minutes), jpeg: jpeg, windowID: windowID) }
        }
        let shown = await after.entries(windowID: windowID).map(\.id)
        try require(!shown.contains(hiddenPhoto) && !shown.contains(blockedPhoto), "hidden and blocked people's photos are not shown")
        try require(!shown.contains(removedPhoto), "a removed photo is not shown")
        // The reported photo is covered, and its receipt is listed.
        let laterReporting = try reporting()
        let covered = try await laterReporting.locallyReportedPhotoIDs(windowID: windowID)
        try require(covered.contains(reportedPhoto), "a reported photo stays covered after reinstall")
        let records = await laterReporting.reports(windowID: windowID)
        try require(records.contains { $0.photoID == reportedPhoto && $0.receiptNumber == "R-0123-4567-89"
            && $0.progress == .received && $0.isKeptCopy == true && $0.senderName.isEmpty }, "the receipt is listed after reinstall")
        // What the home-screen photo may use: shown, and not reported.
        try require(shown.first { !covered.contains($0) } == plainPhoto, "only an unhidden, unreported photo reaches the widget")

        // The block can be lifted again; the Keychain copy follows.
        await after.unhide(memberID: blockedPerson, windowID: windowID)
        let rowsAfterLifting = await after.knownWindows().first { $0.id == windowID }?.hiddenMembers ?? []
        try require(!rowsAfterLifting.contains { $0.id == blockedPerson }, "the block row can be removed")
        let choices = try GroupWindowKept.choices(windowID: windowID, in: kept)
        try require(choices?.blockedMemberIDs.isEmpty == true && choices?.hiddenMemberIDs == [hiddenPerson],
                    "lifting the block removes it from the Keychain copy")
        let shownAfterLifting = await after.entries(windowID: windowID)
        try require(shownAfterLifting.contains { $0.id == blockedPhoto }, "lifted: photos show again")

        // 「このまどを一覧から消す」 also forgets the copy.
        await after.forget(windowID: windowID)
        let forgotten = try GroupWindowKept.choices(windowID: windowID, in: kept)
        try require(forgotten == nil, "forgetting a window forgets its choices")
    }

    /// An install from before 11/20 has the choices in its files only; the
    /// first read of the window copies them to the Keychain once.
    static func olderInstall(_ root: URL, _ jpeg: Data) async throws {
        let photos = root.appendingPathComponent("older/GroupWindows", isDirectory: true)
        let windowID = syntheticID(20), blockedPerson = syntheticID(21), removedPhoto = syntheticID(22)
        let older = GroupWindowLocalPhotoStore(root: photos, keychain: { nil })
        await older.remember(windowID: windowID, name: "合成のまど")
        try await older.save(entry(removedPhoto, from: syntheticID(23), minutesAgo: 1), jpeg: jpeg, windowID: windowID)
        await older.hide(memberID: blockedPerson, name: "合成のブロック", windowID: windowID, blocked: true)
        try await older.remove(photoID: removedPhoto, windowID: windowID)
        let kept = MemoryKeychain()
        let updated = GroupWindowLocalPhotoStore(root: photos, keychain: { kept })
        await updated.remember(windowID: windowID, name: "合成のまど")
        let choices = try GroupWindowKept.choices(windowID: windowID, in: kept)
        try require(choices?.blockedMemberIDs == [blockedPerson] && choices?.removedPhotoIDs == [removedPhoto],
                    "choices made before the update are copied to the Keychain")
    }

    /// A Keychain that fails: today's behaviour (local files only), no crash.
    static func keychainFailure(_ root: URL, _ jpeg: Data) async throws {
        let photos = root.appendingPathComponent("failing/GroupWindows", isDirectory: true)
        let windowID = syntheticID(30), blockedPerson = syntheticID(31), photo = syntheticID(32), removedPhoto = syntheticID(33)
        let broken = MemoryKeychain(failing: true)
        let store = GroupWindowLocalPhotoStore(root: photos, keychain: { broken })
        await store.remember(windowID: windowID, name: "合成のまど")
        try await store.save(entry(photo, from: blockedPerson, minutesAgo: 1), jpeg: jpeg, windowID: windowID)
        try await store.save(entry(removedPhoto, from: syntheticID(34), minutesAgo: 2), jpeg: jpeg, windowID: windowID)
        await store.hide(memberID: blockedPerson, name: "合成のブロック", windowID: windowID, blocked: true)
        try await store.remove(photoID: removedPhoto, windowID: windowID)
        let shown = await store.entries(windowID: windowID)
        try require(shown.isEmpty, "hiding and removing still work on this iPhone")
        GroupWindowKept.keepReport(photoID: photo, receiptNumber: nil, sentAt: Date(), windowID: windowID, in: broken)
        try require(GroupWindowKept.reports(windowID: windowID, in: broken).isEmpty, "a failing Keychain reads as nothing kept")
        try FileManager.default.removeItem(at: photos)
        let reinstalled = GroupWindowLocalPhotoStore(root: photos, keychain: { broken })
        await reinstalled.remember(windowID: windowID, name: "合成のまど")
        let rows = await reinstalled.knownWindows().first?.hiddenMembers ?? []
        try require(rows.isEmpty, "nothing to restore: as before 11/20")
        let removedKnown = await reinstalled.contains(photoID: removedPhoto, windowID: windowID)
        try require(!removedKnown, "as before 11/20")
    }

    /// Each list keeps the newest 500 IDs; the oldest goes first.
    static func bound() throws {
        let kept = MemoryKeychain()
        let windowID = syntheticID(40)
        let ids = (0..<600).map { GroupWire.base64(Data(SHA256.hash(data: Data([UInt8($0 % 256), UInt8($0 / 256)])).prefix(16))) }
        for photo in ids {
            GroupWindowKept.update(windowID: windowID, in: kept) { $0.removedPhotoIDs.append(photo) }
        }
        let removed = try GroupWindowKept.choices(windowID: windowID, in: kept)?.removedPhotoIDs ?? []
        try require(removed.count == GroupWindowKept.limit && removed == Array(ids.suffix(500)), "the oldest removed IDs go first")
    }
}
