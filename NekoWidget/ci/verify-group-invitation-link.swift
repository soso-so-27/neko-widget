import Foundation

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ name: String) throws {
    if !value { throw Failure.check(name) }
}

// 43 unpadded base64url characters decode to exactly 32 bytes.
private let inviteKey = String(repeating: "A", count: 43)
private let ownerKey = "B" + String(repeating: "A", count: 42)

private func link(
    _ fragment: String,
    scheme: String = "https",
    host: String = "nekonomado.com",
    path: String = "/join",
    query: String? = nil
) -> URL {
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.path = path
    components.query = query
    components.fragment = fragment
    return components.url!
}

private let goodFragment = "v=3&w=room-one&i=invite-one&s=\(inviteKey)&o=\(ownerKey)"

@main
struct VerifyGroupInvitationLink {
    static func main() throws {
        let good = link(goodFragment)
        guard let parsed = GroupInvitationLink(url: good) else {
            throw Failure.check("valid link parses")
        }
        try check(parsed.windowID == "room-one" && parsed.invitationID == "invite-one", "ids")
        try check(parsed.id == "invite-one", "identifiable by invitation")
        try check(parsed.inviteSecret.count == 32 && parsed.ownerIdentityPublicKey.count == 32, "key sizes")
        try check(parsed.inviteSecret.allSatisfy { $0 == 0 }, "base64url decodes the invite key")
        try check(parsed.ownerIdentityPublicKey.first == 0x04, "base64url decodes the owner key")
        for text in [parsed.description, parsed.debugDescription, "\(parsed)", String(reflecting: parsed)] {
            try check(!text.contains(inviteKey) && !text.contains(ownerKey), "descriptions leave the keys out")
        }
        try check(parsed.url.flatMap(GroupInvitationLink.init(url:)) == parsed, "rebuilt link round-trips")
        try check(parsed.url?.query == nil && parsed.url?.fragment != nil, "rebuilt link keeps keys in the fragment")
        try check(GroupInvitationLink.isCandidate(good), "valid link is a candidate")
        try check(GroupInvitationLink.isCandidate(link("garbage")), "malformed join link is still a candidate")
        try check(!GroupInvitationLink.isCandidate(link(goodFragment, scheme: "http")), "http is not a candidate")
        try check(!GroupInvitationLink.isCandidate(link(goodFragment, host: "example.com")), "other host is not a candidate")
        try check(GroupInvitationLink(url: link("o=\(ownerKey)&s=\(inviteKey)&i=invite-one&w=room-one&v=3")) != nil,
                  "key order does not matter")
        try check(GroupInvitationLink(url: link(goodFragment, host: "NekoNoMado.com")) != nil, "host is case-insensitive")

        let context = GroupInvitationContext(windowName: "実家のまど", inviterName: "お母さん")
        let cipher = try context.seal(secret: parsed.inviteSecret, windowID: parsed.windowID,
            invitationID: parsed.invitationID, owner: parsed.ownerIdentityPublicKey)
        let encoded = cipher.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let named = link(goodFragment + "&c=" + encoded)
        try check(GroupInvitationLink(url: named)?.context == context, "encrypted names round-trip")
        try check(!named.absoluteString.contains("実家") && named.query == nil, "names never become query/plaintext")
        try check(GroupInvitationLink(url: link(goodFragment.replacingOccurrences(of: "room-one", with: "room-two") + "&c=" + encoded)) == nil, "context cannot be moved to another window")
        try check(GroupInvitationLink(url: link(goodFragment + "&c=" + String(encoded.dropLast(4)) + "AAAA")) == nil, "tampered context fails closed")
        try check(GroupInvitationLink(url: named)?.url.flatMap(GroupInvitationLink.init(url:))?.context == context, "staging preserves context")

        let rejected: [(String, URL)] = [
            ("http scheme", link(goodFragment, scheme: "http")),
            ("other host", link(goodFragment, host: "example.com")),
            ("www host", link(goodFragment, host: "www.nekonomado.com")),
            ("other path", link(goodFragment, path: "/join/")),
            ("root path", link(goodFragment, path: "/")),
            ("secret in query", link("v=3&w=room-one&i=invite-one&o=\(ownerKey)", query: "s=\(inviteKey)")),
            ("empty query marker", link(goodFragment, query: "")),
            ("older version", link("v=2&w=room-one&i=invite-one&s=\(inviteKey)&o=\(ownerKey)")),
            ("missing owner key", link("v=3&w=room-one&i=invite-one&s=\(inviteKey)")),
            ("missing window", link("v=3&i=invite-one&s=\(inviteKey)&o=\(ownerKey)")),
            ("unknown key", link("\(goodFragment)&x=1")),
            ("duplicate key", link("v=3&\(goodFragment)")),
            ("empty value", link("v=3&w=&i=invite-one&s=\(inviteKey)&o=\(ownerKey)")),
            ("short key", link("v=3&w=room-one&i=invite-one&s=\(inviteKey.dropLast())&o=\(ownerKey)")),
            ("long key", link("v=3&w=room-one&i=invite-one&s=\(inviteKey)A&o=\(ownerKey)")),
            ("padded key", link("v=3&w=room-one&i=invite-one&s=\(inviteKey.dropLast())=&o=\(ownerKey)")),
            ("standard base64 characters", link("v=3&w=room-one&i=invite-one&s=\(inviteKey.dropLast())+&o=\(ownerKey)")),
            ("id with slash", link("v=3&w=room/one&i=invite-one&s=\(inviteKey)&o=\(ownerKey)")),
            ("id too long", link("v=3&w=\(String(repeating: "a", count: 129))&i=invite-one&s=\(inviteKey)&o=\(ownerKey)")),
            ("empty fragment", link("")),
            ("no fragment", URL(string: "https://nekonomado.com/join")!),
            ("credentials in link", URL(string: "https://user:pass@nekonomado.com/join#\(goodFragment)")!),
        ]
        for (name, url) in rejected {
            try check(GroupInvitationLink(url: url) == nil, "rejects \(name)")
        }
        print("Group invitation link checks passed")
    }
}
