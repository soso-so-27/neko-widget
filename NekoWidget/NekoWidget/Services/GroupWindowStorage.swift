import CryptoKit
import Foundation
import Security

protocol GroupSecretStore: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String, createOnly: Bool) throws
    func remove(_ account: String) throws
    func accounts(prefix: String) throws -> [String]
}
extension GroupSecretStore {
    func accounts(prefix: String) throws -> [String] { [] }
}

/// App-private Keychain only. No access group, synchronizable item, Widget
/// entitlement, cloud backup, or existing personal-storage key is used here.
final class GroupKeychainStore: GroupSecretStore, Sendable {
    private let service: String
    init(namespace: String) throws {
        guard !namespace.isEmpty, namespace.utf8.count <= 200 else { throw GroupClientError.invalidResponse }
        service = namespace + ".group-windows.v3"
    }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw GroupClientError.authenticationRequired }
        return data
    }
    func write(_ data: Data, account: String, createOnly: Bool = false) throws {
        var request = query(account)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        request[kSecValueData as String] = data
        let status = SecItemAdd(request as CFDictionary, nil)
        if status == errSecDuplicateItem {
            if createOnly { throw GroupClientError.idempotencyConflict }
            guard SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess
            else { throw GroupClientError.authenticationRequired }
        } else if status != errSecSuccess { throw GroupClientError.authenticationRequired }
    }
    func accounts(prefix: String) throws -> [String] {
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { throw GroupClientError.authenticationRequired }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }.sorted()
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GroupClientError.authenticationRequired }
    }
    /// 11/20: the namespaces of this app's device-only stores (as passed to
    /// `init(namespace:)`) that start with `prefix` and hold at least one
    /// item, e.g. every `.family.<scope>` of one group namespace.
    static func namespaces(prefix: String) throws -> [String] {
        let suffix = ".group-windows.v3"
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { throw GroupClientError.authenticationRequired }
        let services = rows.compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) && $0.count > prefix.count + suffix.count }
        return Set(services.map { String($0.dropLast(suffix.count)) }).sorted()
    }
}

struct GroupDeviceIdentity: Codable, Sendable {
    let personPrivateKey: Data?
    let personPublicKey: Data
    let signingPrivateKey: Data
    let agreementPrivateKey: Data
    var windowCertificates: [String: Data]
    var registered: Bool

    static func firstDevice() -> Self {
        let person = Curve25519.Signing.PrivateKey()
        return .init(personPrivateKey: person.rawRepresentation, personPublicKey: person.publicKey.rawRepresentation,
            signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation,
            agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation, windowCertificates: [:], registered: false)
    }
    var signingKey: Curve25519.Signing.PrivateKey { get throws { try .init(rawRepresentation: signingPrivateKey) } }
    var agreementKey: Curve25519.KeyAgreement.PrivateKey { get throws { try .init(rawRepresentation: agreementPrivateKey) } }
    var personID: String { GroupWire.base64(GroupCanonical.hash(personPublicKey)) }
    var deviceID: String { get throws {
        try GroupWire.base64(GroupCanonical.hash(GroupCanonical.fields([signingKey.publicKey.rawRepresentation, agreementKey.publicKey.rawRepresentation])))
    } }
    func certificate(windowID: String) throws -> GroupRosterDevice {
        let device = try GroupRosterDevice(id: deviceID, signingPublicKey: signingKey.publicKey.rawRepresentation,
            hpkePublicKey: agreementKey.publicKey.rawRepresentation, personAuthorization: Data())
        if personPrivateKey == nil {
            guard let signature = windowCertificates[windowID],
                  try Curve25519.Signing.PublicKey(rawRepresentation: personPublicKey).isValidSignature(signature,
                    for: device.authorizationBytes(windowID: windowID, personID: personID)) else { throw GroupClientError.authenticationRequired }
            return .init(id: device.id, signingPublicKey: device.signingPublicKey, hpkePublicKey: device.hpkePublicKey, personAuthorization: signature)
        }
        let raw = personPrivateKey!
        return try .init(id: device.id, signingPublicKey: device.signingPublicKey, hpkePublicKey: device.hpkePublicKey,
            personAuthorization: Curve25519.Signing.PrivateKey(rawRepresentation: raw)
                .signature(for: device.authorizationBytes(windowID: windowID, personID: personID)))
    }
}

struct GroupNameCheckpoint: Codable, Sendable {
    let rosterRevision: Int
    let nameRevision: Int
    let ciphertextHash: Data
}

struct GroupLocalWindow: Codable, Sendable {
    let anchor: GroupTrustAnchor
    var packet: SignedGroupRoster?
    var pinnedRevision: Int
    var pinnedHash: Data
    var keys: [String: Data]
    var rosterHashes: [String: Data]
    var left: Bool
    var minimumAdmissionRevision: Int
    var nameCheckpoint: GroupNameCheckpoint? = nil
    var closed: Bool? = nil
    static func empty(anchor: GroupTrustAnchor) -> Self {
        .init(anchor: anchor, packet: nil, pinnedRevision: 0, pinnedHash: Data(), keys: [:], rosterHashes: [:], left: false, minimumAdmissionRevision: 0)
    }
    func verified() throws -> VerifiedGroupRoster? {
        guard let packet else {
            guard pinnedRevision == 0, pinnedHash.isEmpty else { throw GroupClientError.invalidResponse }
            return nil
        }
        return try GroupRosterVerifier.restoreLocalCheckpoint(packet, anchor: anchor, pinnedRevision: pinnedRevision, pinnedHash: pinnedHash)
    }
}

struct GroupPendingHTTP: Codable, Sendable {
    let operationID: UUID
    let path: String
    var body: Data
    let intentHash: Data
    let createdAt: Date
    var response: Data?
}

struct GroupInvitationCapability: Codable, Sendable {
    let windowID: String
    let invitationID: String
    let privateKey: Data
    let ownerRoot: Data
    var expiresAt: Date
    var contextCiphertext: Data? = nil

    init(url: URL, now: Date = Date()) throws {
        guard let link = GroupInvitationLink(url: url),
              try GroupWire.bytes(link.windowID, count: 16).count == 16,
              try GroupWire.bytes(link.invitationID, count: 16).count == 16 else { throw GroupClientError.invalidResponse }
        windowID = link.windowID; invitationID = link.invitationID
        privateKey = link.inviteSecret; ownerRoot = link.ownerIdentityPublicKey
        contextCiphertext = link.contextCiphertext
        expiresAt = now.addingTimeInterval(86_400)
    }
    init(windowID: String, invitationID: String, privateKey: Data, ownerRoot: Data, expiresAt: Date) {
        self.windowID = windowID; self.invitationID = invitationID; self.privateKey = privateKey
        self.ownerRoot = ownerRoot; self.expiresAt = expiresAt
    }
    func shareURL() throws -> URL {
        var url = URLComponents(string: "https://nekonomado.com/join")!
        var fragment = URLComponents()
        fragment.queryItems = [URLQueryItem(name: "v", value: "3"), .init(name: "w", value: windowID),
            .init(name: "i", value: invitationID), .init(name: "s", value: GroupWire.base64(privateKey)),
            .init(name: "o", value: GroupWire.base64(ownerRoot))]
        if let contextCiphertext { fragment.queryItems?.append(.init(name: "c", value: GroupWire.base64(contextCiphertext))) }
        url.fragment = fragment.percentEncodedQuery
        guard let result = url.url else { throw GroupClientError.invalidResponse }
        return result
    }
}

struct GroupDeviceLinkOffer: Codable, Equatable, Sendable {
    let expectedPersonID: String
    let personPublicKey: Data
    let windowIDs: [String]
    let operationID: String
    let challengeID: String
    let challenge: String
    let expiresAt: Int
    let signingPublicKey: Data
    let hpkePublicKey: Data
    let deviceSignature: Data
    func transcript(personPublicKey: Data) throws -> Data {
        try GroupCanonical.fields(["NW3.IDENTITY", "3", operationID, challengeID, challenge, String(expiresAt)].map(GroupCanonical.text)
            + [personPublicKey, signingPublicKey, hpkePublicKey])
    }
}
struct GroupDeviceLinkApproval: Codable, Sendable {
    let offer: GroupDeviceLinkOffer
    let personPublicKey: Data
    let personSignature: Data
    let windowCertificates: [String: Data]
}
struct GroupLocalDeviceLink: Codable, Sendable {
    let offer: GroupDeviceLinkOffer
    let signingPrivateKey: Data
    let agreementPrivateKey: Data
}

/// 11/20: the name this person last gave (GroupDisplayName.remembered).
/// The screens read UserDefaults; this iPhone's Keychain (GroupKeychainStore:
/// device-only, not synced, like the identity) keeps a copy that deleting the
/// app does not remove. A Keychain failure leaves UserDefaults as it was.
struct GroupRememberedName {
    static let account = "my-display-name.v1"
    let defaults: () -> String?
    let setDefaults: (String) -> Void
    let keychain: () -> (any GroupSecretStore)?
    /// The Keychain item. 11/20: the family notebook's 「表示しない」 entries
    /// (FamilyHiddenOperations) are kept the same way under their own.
    var account = GroupRememberedName.account

    /// `checked`: this process already compared the two; later reads are
    /// UserDefaults only (one Keychain read per process, none while scrolling).
    func read(checked: inout Bool) -> String {
        let saved = defaults() ?? ""
        guard !checked else { return saved }
        checked = true
        let data = try? keychain()?.read(account)
        let kept = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if saved.isEmpty {
            guard !kept.isEmpty else { return "" }
            setDefaults(kept)
            return kept
        }
        // An install from before 11/20 has the name in UserDefaults only.
        if kept != saved { keep(saved) }
        return saved
    }

    func write(_ name: String) {
        setDefaults(name)
        keep(name)
    }

    /// Empty is the same as none (read treats it so): the item is removed.
    private func keep(_ name: String) {
        guard let store = keychain() else { return }
        if name.isEmpty { try? store.remove(account) }
        else { try? store.write(Data(name.utf8), account: account, createOnly: false) }
    }
}

/// 11/20: the person's protective choices in a group window, also kept in
/// this iPhone's Keychain (GroupKeychainStore: device-only, not synced, like
/// the `window:` records), so deleting the app and installing it again does
/// not bring back a blocked or hidden person, a removed photo, or a reported
/// photo. Opaque IDs, receipt numbers and dates only: no names, photos,
/// reasons or text the person wrote. Written only on the person's action; a
/// Keychain failure leaves the app as it was before (local files only).
/// Bound: each list keeps the newest 500 IDs (the oldest is dropped first),
/// as the local index keeps 500 photos a window.
enum GroupWindowKept {
    static let namespaceSuffix = ".window-choices"
    static let limit = 500

    struct Choices: Codable, Equatable, Sendable {
        var hiddenMemberIDs: [String] = []
        var blockedMemberIDs: [String] = []
        var removedPhotoIDs: [String] = []
        var isEmpty: Bool { hiddenMemberIDs.isEmpty && blockedMemberIDs.isEmpty && removedPhotoIDs.isEmpty }
    }

    struct Report: Codable, Equatable, Sendable {
        let photoID: String
        var receiptNumber: String? = nil
        let sentAt: Date
    }

    /// 11/20: 「まどと家族の手帳のデータを消す」 removes these; the report copies stay.
    static let choicesAccountPrefix = "choices:"
    private static func choicesAccount(_ windowID: String) -> String { choicesAccountPrefix + windowID }
    private static func reportsAccount(_ windowID: String) -> String { "reports:" + windowID }

    /// nil: nothing kept. Throws when the Keychain or the item could not be read.
    static func choices(windowID: String, in store: (any GroupSecretStore)?) throws -> Choices? {
        guard let store, GroupCanonical.validID(windowID) else { return nil }
        guard let data = try store.read(choicesAccount(windowID)) else { return nil }
        return try JSONDecoder().decode(Choices.self, from: data)
    }

    static func keep(_ choices: Choices, windowID: String, in store: (any GroupSecretStore)?) {
        guard let store, GroupCanonical.validID(windowID) else { return }
        let bounded = Choices(hiddenMemberIDs: bound(choices.hiddenMemberIDs),
                              blockedMemberIDs: bound(choices.blockedMemberIDs),
                              removedPhotoIDs: bound(choices.removedPhotoIDs))
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        try? store.write(data, account: choicesAccount(windowID), createOnly: false)
    }

    /// Reads, changes and writes back one window's choices; silent on failure.
    /// An unreadable item is left alone rather than overwritten with less.
    static func update(windowID: String, in store: (any GroupSecretStore)?, _ change: (inout Choices) -> Void) {
        let current: Choices
        do { current = try choices(windowID: windowID, in: store) ?? Choices() } catch { return }
        var next = current
        change(&next)
        guard next != current else { return }
        keep(next, windowID: windowID, in: store)
    }

    static func reports(windowID: String, in store: (any GroupSecretStore)?) -> [Report] {
        guard let store, GroupCanonical.validID(windowID),
              let data = try? store.read(reportsAccount(windowID)),
              let reports = try? JSONDecoder().decode([Report].self, from: data) else { return [] }
        return reports.filter { GroupCanonical.validID($0.photoID) }
    }

    /// One reported photo; a receipt number learned later is added to it.
    static func keepReport(photoID: String, receiptNumber: String?, sentAt: Date,
                           windowID: String, in store: (any GroupSecretStore)?) {
        guard let store, GroupCanonical.validID(windowID), GroupCanonical.validID(photoID) else { return }
        let account = reportsAccount(windowID)
        var reports: [Report] = []
        do {
            if let data = try store.read(account) {
                guard let saved = try? JSONDecoder().decode([Report].self, from: data) else { return }
                reports = saved
            }
        } catch { return }
        if let index = reports.firstIndex(where: { $0.photoID == photoID }) {
            guard let receiptNumber, reports[index].receiptNumber != receiptNumber else { return }
            reports[index].receiptNumber = receiptNumber
        } else {
            reports.append(Report(photoID: photoID, receiptNumber: receiptNumber, sentAt: sentAt))
        }
        guard let data = try? JSONEncoder().encode(Array(reports.suffix(limit))) else { return }
        try? store.write(data, account: account, createOnly: false)
    }

    /// A window whose kept photos were deleted here (「このまどを一覧から消す」).
    static func forgetChoices(windowID: String, in store: (any GroupSecretStore)?) {
        guard let store, GroupCanonical.validID(windowID) else { return }
        try? store.remove(choicesAccount(windowID))
    }

    private static func bound(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        // The newest copy of a repeated ID wins; the oldest IDs go first.
        let unique = ids.reversed().filter { GroupCanonical.validID($0) && seen.insert($0).inserted }.reversed()
        return Array(Array(unique).suffix(limit))
    }
}
