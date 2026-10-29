import CryptoKit
import Foundation
import Security

protocol GroupSecretStore: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String, createOnly: Bool) throws
    func remove(_ account: String) throws
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
    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GroupClientError.authenticationRequired }
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

    init(url: URL, now: Date = Date()) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              parts.host == "nekonomado.com", parts.port == nil, parts.user == nil, parts.password == nil,
              ["/join", "/join/"].contains(parts.path), parts.query == nil,
              let fragment = parts.fragment, fragment.utf8.count <= 1024,
              let query = URLComponents(string: "https://invalid/?" + fragment)?.queryItems, query.count == 5,
              Set(query.map(\.name)) == Set(["v", "w", "i", "s", "o"])
        else { throw GroupClientError.invalidResponse }
        let fields = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        guard fields["v"] == "3", let window = fields["w"], let invite = fields["i"],
              try GroupWire.bytes(window, count: 16).count == 16,
              try GroupWire.bytes(invite, count: 16).count == 16 else { throw GroupClientError.invalidResponse }
        windowID = window; invitationID = invite
        privateKey = try GroupWire.bytes(fields["s"] ?? "", count: 32)
        ownerRoot = try GroupWire.bytes(fields["o"] ?? "", count: 32)
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
