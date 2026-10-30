import Foundation

@main
enum ProductionConfigurationVerifier {
    static func main() {
        let key = Data(1...32).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let valid: [String: Any] = [
            "SharingReleaseMode": "production", "SharingFeatureEnabled": "YES", "SharingMediaEnabled": "YES",
            "GroupReportingProductionEnabled": "YES", "SharingAPIBaseURL": "https://api.nekonomado.com",
            "SharingModerationKeyID": "moderation-v2", "SharingModerationPublicKey": key,
            "SharingPrivacyURL": "https://nekonomado.com/privacy", "SharingSupportURL": "https://nekonomado.com/support",
            "SharingCommunityStandardsURL": "https://nekonomado.com/community"
        ]
        let production = SharingAPIConfiguration.from(info: valid)
        precondition(production.isGroupRuntimeAvailable && production.isEncryptedReportAvailable)
        precondition(!production.requiresLocalSharingPurge && !production.isInternalEncryptedReportEnabled)
        let rejected: [(String, Any)] = [
            ("OwnerInternalReportsDisabled", "YES"),
            ("SharingAPIBaseURL", ""), ("SharingAPIBaseURL", "http://api.nekonomado.com"),
            ("SharingAPIBaseURL", "https://neko-window-sharing-staging.nakanishisoya.workers.dev"),
            ("GroupReportingProductionEnabled", "NO"), ("SharingFeatureEnabled", "NO"),
            ("SharingMediaEnabled", "NO"), ("SharingModerationPublicKey", ""),
            ("SharingModerationPublicKey", "T5C7__1xlc4XmIDr6zTJqMtdhBjPnMD10O3vFK_bYWg"),
            ("SharingPrivacyURL", ""), ("SharingInternalEncryptedReportEnabled", true),
            ("SharingInternalEncryptedReportScope", "internal-owner-first-connection"),
            ("SharingShareExtensionSendEnabled", "YES"), ("SharingReviewPreviewEnabled", "YES")
        ]
        for (name, value) in rejected {
            var info = valid; info[name] = value
            precondition(!SharingAPIConfiguration.from(info: info).isEncryptedReportAvailable, name)
        }
        var disabled = valid; disabled["SharingReleaseMode"] = "disabled"
        precondition(!SharingAPIConfiguration.from(info: disabled).isGroupRuntimeAvailable)
        precondition(!SharingAPIConfiguration.from(info: disabled).isEncryptedReportAvailable)
        var internalInfo = valid
        internalInfo["SharingReleaseMode"] = "media-staging"
        internalInfo["SharingAPIBaseURL"] = "https://neko-window-sharing-staging.nakanishisoya.workers.dev"
        internalInfo["SharingModerationPublicKey"] = "T5C7__1xlc4XmIDr6zTJqMtdhBjPnMD10O3vFK_bYWg"
        internalInfo["SharingInternalEncryptedReportEnabled"] = true
        internalInfo["SharingInternalEncryptedReportScope"] = "internal-owner-first-connection"
        precondition(SharingAPIConfiguration.from(info: internalInfo).isEncryptedReportAvailable)
        internalInfo["OwnerInternalReportsDisabled"] = "YES"
        let owner = SharingAPIConfiguration.from(info: internalInfo)
        precondition(!owner.isEncryptedReportAvailable && owner.isMediaAvailable)
        precondition(!owner.requiresLocalSharingPurge, "report OFF must not purge photos or pending reports")
        print("PASS production configuration: complete configuration required; no staging recipient or internal report bypass")
    }
}
