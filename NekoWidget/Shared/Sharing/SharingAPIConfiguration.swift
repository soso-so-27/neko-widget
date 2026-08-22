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
    let supportURL: URL?
    let communityStandardsURL: URL?

    var isAvailable: Bool { isEnabled && baseURL != nil }

    var hasOperationalSafetyConfiguration: Bool {
        moderationKeyID == "moderation-v1"
            && moderationPublicKey?.count == 32
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
            communityStandardsURL: communityStandardsURL
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
        return canonical == value ? data : nil
    }

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
