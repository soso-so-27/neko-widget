import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        var exercise = internalInfo
        exercise["SharingInternalEncryptedReportEnabled"] = false
        exercise["SharingInternalEncryptedReportScope"] = ""
        exercise["GroupReportingProductionEnabled"] = "NO"
        exercise["OwnerStagingTwoDeviceEnabled"] = "YES"
        exercise["GroupWindowsEnabled"] = "YES"
        exercise["FamilyNotebookProductionEnabled"] = "YES"
        precondition(SharingAPIConfiguration.ownerStagingTwoDeviceEnabled(info: exercise))
        for (key, value) in [("SharingAPIBaseURL", "https://api.nekonomado.com"), ("SharingReleaseMode", "production"),
                             ("OwnerStagingTwoDeviceEnabled", "NO"), ("OwnerInternalReportsDisabled", "NO"),
                             ("FamilyNotebookProductionEnabled", "NO"), ("GroupWindowsEnabled", "NO")] {
            var invalid = exercise; invalid[key] = value
            precondition(!SharingAPIConfiguration.ownerStagingTwoDeviceEnabled(info: invalid), key)
        }
        exercise["PlusBillingClientEnabled"] = "YES"
        exercise["PlusBillingAPIBaseURL"] = OwnerTwoDeviceTrialConfiguration.origin
        exercise["OwnerTwoDeviceTrial"] = ["proof": key, "owner": key, "window": String(repeating: "A", count: 22),
                                            "family": "98b47c5f-0dc4-4ed2-a2c2-26d0173db946"]
        let trial = OwnerTwoDeviceTrialConfiguration.from(info: exercise)!
        var allowed = URLRequest(url: URL(string: OwnerTwoDeviceTrialConfiguration.origin + "/v1/billing/entitlement")!)
        trial.authorize(&allowed)
        precondition(allowed.value(forHTTPHeaderField: "Neko-Owner-Trial-Proof") == key)
        for url in ["https://api.nekonomado.com/v1/billing/entitlement",
                    OwnerTwoDeviceTrialConfiguration.origin + "/v1/billing/accounts/recover",
                    OwnerTwoDeviceTrialConfiguration.origin + "/v3/group-windows?unexpected=1"] {
            var denied = URLRequest(url: URL(string: url)!)
            trial.authorize(&denied)
            precondition(denied.value(forHTTPHeaderField: "Neko-Owner-Trial-Proof") == nil)
        }
        exercise["OwnerInternalReportsDisabled"] = "NO"
        precondition(OwnerTwoDeviceTrialConfiguration.from(info: exercise) == nil)
        print("PASS production configuration: complete configuration required; no staging recipient or internal report bypass")
    }
}
