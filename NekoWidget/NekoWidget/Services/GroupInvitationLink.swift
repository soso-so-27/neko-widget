import Foundation
import CryptoKit

/// An invitation link opened on this iPhone:
/// `https://nekonomado.com/join#v=3&w=<window>&i=<invitation>&s=<invite key>&o=<owner key>`.
/// Both keys live only in the fragment, which a browser never sends to the
/// site. The parsed value is held in memory for the join screen and nowhere
/// else: it is never written to logs, saved files, or fixtures, and its
/// description leaves the keys out.
struct GroupInvitationLink: Equatable, Sendable, Identifiable {
    static let host = "nekonomado.com"
    static let path = "/join"
    static let version = "3"
    static let keyByteCount = 32

    let windowID: String
    let invitationID: String
    let inviteSecret: Data
    let ownerIdentityPublicKey: Data
    let contextCiphertext: Data?
    let context: GroupInvitationContext?

    var id: String { invitationID }

    /// True for anything addressed to the join page, so a malformed link is
    /// reported as a bad invitation rather than an unknown deep link.
    static func isCandidate(_ url: URL) -> Bool {
        // URLComponents keeps a trailing slash that URL.path would drop.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == host
            && components.path == path
    }

    init?(url: URL) {
        guard Self.isCandidate(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let fragment = components.fragment,
              !fragment.isEmpty, fragment.utf8.count <= 4096
        else { return nil }

        var values: [String: String] = [:]
        for pair in fragment.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
                  values.updateValue(String(parts[1]), forKey: String(parts[0])) == nil
            else { return nil }
        }
        guard (Set(values.keys) == ["v", "w", "i", "s", "o"] || Set(values.keys) == ["v", "w", "i", "s", "o", "c"]),
              values["v"] == Self.version,
              let windowID = values["w"], Self.isValidID(windowID),
              let invitationID = values["i"], Self.isValidID(invitationID),
              let inviteSecret = Self.decodeKey(values["s"]),
              let ownerIdentityPublicKey = Self.decodeKey(values["o"])
        else { return nil }

        var ciphertext: Data?, context: GroupInvitationContext?
        if let encoded = values["c"] {
            guard let bytes = GroupInvitationContext.decode(encoded),
                  let opened = try? GroupInvitationContext.open(bytes, secret: inviteSecret,
                    windowID: windowID, invitationID: invitationID, owner: ownerIdentityPublicKey) else { return nil }
            ciphertext = bytes; context = opened
        }
        self.contextCiphertext = ciphertext; self.context = context
        self.windowID = windowID
        self.invitationID = invitationID
        self.inviteSecret = inviteSecret
        self.ownerIdentityPublicKey = ownerIdentityPublicKey
    }

    /// Rebuilt only to hand the opened invitation to the group client, in
    /// memory. Never logged, shown, or saved by the app.
    var url: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = Self.path
        components.fragment = "v=\(Self.version)&w=\(windowID)&i=\(invitationID)"
            + "&s=\(Self.encodeKey(inviteSecret))&o=\(Self.encodeKey(ownerIdentityPublicKey))"
        if let contextCiphertext { components.fragment! += "&c=" + Self.encodeKey(contextCiphertext) }
        return components.url
    }

    private static func encodeKey(_ key: Data) -> String {
        key.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isValidID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95
        }
    }

    /// Unpadded base64url of exactly 32 bytes, which is always 43 characters.
    private static func decodeKey(_ value: String?) -> Data? {
        guard let value, value.utf8.count == 43,
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                      || $0 == 45 || $0 == 95
              })
        else { return nil }
        let base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + "="
        guard let data = Data(base64Encoded: base64), data.count == keyByteCount else { return nil }
        return data
    }
}

extension GroupInvitationLink: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "GroupInvitationLink(window: \(windowID), invitation: \(invitationID), keys: redacted)"
    }

    var debugDescription: String { description }
}

/// Display context is authenticated to this capability, not an independent identity claim.
/// No plaintext names, query parameters or server-side metadata are added to links.
struct GroupInvitationContext: Codable, Equatable, Sendable {
    let windowName: String
    let inviterName: String
    private static func binding(_ windowID: String, _ invitationID: String, _ owner: Data) -> Data {
        Data(("NW3.INVITATION.CONTEXT\n" + windowID + "\n" + invitationID + "\n" + owner.base64EncodedString()).utf8)
    }
    private static func key(_ secret: Data, _ binding: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: binding,
            info: Data("display-context-v1".utf8), outputByteCount: 32)
    }
    func seal(secret: Data, windowID: String, invitationID: String, owner: Data) throws -> Data {
        let aad = Self.binding(windowID, invitationID, owner)
        return try AES.GCM.seal(JSONEncoder().encode(self), using: Self.key(secret, aad), authenticating: aad).combined!
    }
    static func open(_ bytes: Data, secret: Data, windowID: String, invitationID: String, owner: Data) throws -> Self {
        let aad = binding(windowID, invitationID, owner)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key(secret, aad), authenticating: aad)
        let result = try JSONDecoder().decode(Self.self, from: plain)
        guard [result.windowName, result.inviterName].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return result
    }
    static func decode(_ text: String) -> Data? {
        guard text.utf8.count <= 3072, text.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4-text.count%4)%4))
    }
}
