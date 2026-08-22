import Foundation

/// Build-time boundary shared by the host app and its capture-only Share
/// Extension. The direct-send flag is retained only as a release tombstone:
/// an extension must never turn an App Group or Keychain remnant into network
/// authorization after an app reinstall.
struct SharingAPIConfiguration: Equatable, Sendable {
    let isEnabled: Bool
    let isMediaEnabled: Bool
    let isShareExtensionHandoffEnabled: Bool
    let isShareExtensionSendEnabled: Bool
    let isReviewPreviewEnabled: Bool
    let baseURL: URL?
    let moderationKeyID: String?
    let moderationPublicKey: Data?
    let privacyURL: URL?
    let supportURL: URL?
    let communityStandardsURL: URL?

    init(
        isEnabled: Bool,
        isMediaEnabled: Bool,
        isShareExtensionHandoffEnabled: Bool,
        isShareExtensionSendEnabled: Bool,
        isReviewPreviewEnabled: Bool,
        baseURL: URL?,
        moderationKeyID: String?,
        moderationPublicKey: Data?,
        supportURL: URL?,
        communityStandardsURL: URL?,
        privacyURL: URL? = nil
    ) {
        self.isEnabled = isEnabled
        self.isMediaEnabled = isMediaEnabled
        self.isShareExtensionHandoffEnabled = isShareExtensionHandoffEnabled
        self.isShareExtensionSendEnabled = isShareExtensionSendEnabled
        self.isReviewPreviewEnabled = isReviewPreviewEnabled
        self.baseURL = baseURL
        self.moderationKeyID = moderationKeyID
        self.moderationPublicKey = moderationPublicKey
        self.privacyURL = privacyURL
        self.supportURL = supportURL
        self.communityStandardsURL = communityStandardsURL
    }

    var isAvailable: Bool { isEnabled && baseURL != nil }

    var hasOperationalSafetyConfiguration: Bool {
        moderationKeyID == "moderation-v1"
            && moderationPublicKey?.count == 32
            && privacyURL != nil
            && supportURL != nil
            && communityStandardsURL != nil
    }

    /// Host-only receive, report and delivery runtime. Share Extension
    /// authorization is deliberately not part of this value.
    var isMediaAvailable: Bool {
        isAvailable && isMediaEnabled && hasOperationalSafetyConfiguration
    }

    /// The extension may only place one canonical, short-lived input in the
    /// App Group. The host validates its ordinary-container installation
    /// marker before that input can become encrypted outbox data.
    var isShareExtensionHandoffAvailable: Bool {
        isEnabled
            && isMediaEnabled
            && isShareExtensionHandoffEnabled
            && !isShareExtensionSendEnabled
    }

    var isReviewVisible: Bool { isAvailable || isReviewPreviewEnabled }

    static var current: Self {
        let info = Bundle.main.infoDictionary ?? [:]
        let enabled = explicitFlag(info["SharingFeatureEnabled"])
        let mediaEnabled = explicitFlag(info["SharingMediaEnabled"])
        let handoffEnabled = explicitFlag(info["SharingShareExtensionHandoffEnabled"])
        let directSendEnabled = explicitFlag(info["SharingShareExtensionSendEnabled"])
        let reviewPreviewEnabled = explicitFlag(info["SharingReviewPreviewEnabled"])
        let rawURL = (info["SharingAPIBaseURL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseURL = URL(string: rawURL).flatMap {
            publicHTTPSURL($0, requiresRootPath: true) ? $0 : nil
        }
        let moderationKeyID = nonemptyString(info["SharingModerationKeyID"] as? String)
        let moderationPublicKey = nonemptyString(
            info["SharingModerationPublicKey"] as? String
        ).flatMap(decodeCanonicalBase64URL)
        let privacyURL = httpsRootURL(info["SharingPrivacyURL"] as? String)
        let supportURL = httpsRootURL(info["SharingSupportURL"] as? String)
        let communityStandardsURL = httpsRootURL(
            info["SharingCommunityStandardsURL"] as? String
        )
        return Self(
            isEnabled: enabled,
            isMediaEnabled: mediaEnabled,
            isShareExtensionHandoffEnabled: handoffEnabled,
            isShareExtensionSendEnabled: directSendEnabled,
            isReviewPreviewEnabled: reviewPreviewEnabled,
            baseURL: baseURL,
            moderationKeyID: moderationKeyID,
            moderationPublicKey: moderationPublicKey,
            supportURL: supportURL,
            communityStandardsURL: communityStandardsURL,
            privacyURL: privacyURL
        )
    }

    private static func nonemptyString(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func explicitFlag(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return false
    }

    private static func decodeCanonicalBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 90)
                      || (byte >= 97 && byte <= 122)
                      || byte == 45 || byte == 95
              })
        else { return nil }
        let remainder = value.utf8.count % 4
        guard remainder != 1 else { return nil }
        let padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: remainder == 0 ? 0 : 4 - remainder)
        guard let data = Data(base64Encoded: padded) else { return nil }
        let canonical = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard canonical == value,
              !hasSmallOrderX25519PublicKey(data)
        else { return nil }
        return data
    }

    /// RFC 7748 ignores the high bit of an X25519 u-coordinate. Normalize it
    /// before comparing the seven small-order encodings rejected by the
    /// reviewed libsodium X25519 implementation.
    private static func hasSmallOrderX25519PublicKey(_ data: Data) -> Bool {
        guard data.count == 32 else { return true }
        var normalized = [UInt8](data)
        normalized[31] &= 0x7f
        return x25519SmallOrderPublicKeys.contains(Data(normalized))
    }

    private static let x25519SmallOrderPublicKeys: Set<Data> = [
        Data(repeating: 0x00, count: 32),
        Data([0x01] + [UInt8](repeating: 0x00, count: 31)),
        Data([
            0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae,
            0x16, 0x56, 0xe3, 0xfa, 0xf1, 0x9f, 0xc4, 0x6a,
            0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32, 0xb1, 0xfd,
            0x86, 0x62, 0x05, 0x16, 0x5f, 0x49, 0xb8, 0x00,
        ]),
        Data([
            0x5f, 0x9c, 0x95, 0xbc, 0xa3, 0x50, 0x8c, 0x24,
            0xb1, 0xd0, 0xb1, 0x55, 0x9c, 0x83, 0xef, 0x5b,
            0x04, 0x44, 0x5c, 0xc4, 0x58, 0x1c, 0x8e, 0x86,
            0xd8, 0x22, 0x4e, 0xdd, 0xd0, 0x9f, 0x11, 0x57,
        ]),
        Data([0xec] + [UInt8](repeating: 0xff, count: 30) + [0x7f]),
        Data([0xed] + [UInt8](repeating: 0xff, count: 30) + [0x7f]),
        Data([0xee] + [UInt8](repeating: 0xff, count: 30) + [0x7f]),
    ]

    private static func httpsRootURL(_ value: String?) -> URL? {
        guard let raw = nonemptyString(value),
              let url = URL(string: raw),
              publicHTTPSURL(url, requiresRootPath: false)
        else { return nil }
        return url
    }

    /// Release configuration must point at a publicly routable named host.
    /// Requiring a DNS name keeps runtime checks aligned with the validator
    /// and the intended TLS deployment model.
    private static func publicHTTPSURL(_ url: URL, requiresRootPath: Bool) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let rawHost = url.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              !rawHost.hasSuffix("."),
              rawHost.contains("."),
              !rawHost.contains(":"),
              !rawHost.allSatisfy({ $0.isNumber || $0 == "." }),
              !["localhost", "example", "invalid", "local", "test"].contains(rawHost),
              ![".localhost", ".example", ".invalid", ".local", ".test"].contains(
                  where: { rawHost.hasSuffix($0) }
              ),
              rawHost.split(separator: ".").allSatisfy({ label in
                  guard (1...63).contains(label.count),
                        label.first != "-",
                        label.last != "-"
                  else { return false }
                  return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
              }),
              !requiresRootPath || url.path.isEmpty || url.path == "/"
        else { return false }
        return true
    }
}
