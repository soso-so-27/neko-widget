import Foundation

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

    var id: String { invitationID }

    /// True for anything addressed to the join page, so a malformed link is
    /// reported as a bad invitation rather than an unknown deep link.
    static func isCandidate(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == host
            && url.path == path
    }

    init?(url: URL) {
        guard Self.isCandidate(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let fragment = components.fragment,
              !fragment.isEmpty
        else { return nil }

        var values: [String: String] = [:]
        for pair in fragment.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
                  values.updateValue(String(parts[1]), forKey: String(parts[0])) == nil
            else { return nil }
        }
        guard Set(values.keys) == ["v", "w", "i", "s", "o"],
              values["v"] == Self.version,
              let windowID = values["w"], Self.isValidID(windowID),
              let invitationID = values["i"], Self.isValidID(invitationID),
              let inviteSecret = Self.decodeKey(values["s"]),
              let ownerIdentityPublicKey = Self.decodeKey(values["o"])
        else { return nil }

        self.windowID = windowID
        self.invitationID = invitationID
        self.inviteSecret = inviteSecret
        self.ownerIdentityPublicKey = ownerIdentityPublicKey
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
