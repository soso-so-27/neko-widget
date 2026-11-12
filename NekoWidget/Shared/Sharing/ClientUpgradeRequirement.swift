import Foundation

struct ClientUpgradeRequiredError: LocalizedError, Sendable {
    var errorDescription: String? { ClientUpgradeRequirement.message }
}

/// A verified response from an existing HTTPS transport stops further service
/// requests for this process. Never clears identity, pending work, or local data.
final class ClientUpgradeRequirement: @unchecked Sendable {
    static let shared = ClientUpgradeRequirement()
    static let message = "App Storeでアプリを最新にしてください。"
    static let notification = Notification.Name("NekoClientUpgradeRequired")
    private let lock = NSLock()
    private var required = false

    var isRequired: Bool { lock.withLock { required } }

    func checkAllowed() throws {
        if isRequired { throw ClientUpgradeRequiredError() }
    }

    static func requiresUpgrade(status: Int, data: Data) -> Bool {
        struct Body: Decodable {
            struct Detail: Decodable { let code: String }
            let error: Detail
        }
        guard status == 426, data.count <= 16_384,
              let body = try? JSONDecoder().decode(Body.self, from: data) else { return false }
        return body.error.code == "CLIENT_UPGRADE_REQUIRED"
    }

    func checkResponse(status: Int, data: Data) throws {
        guard Self.requiresUpgrade(status: status, data: data) else { return }
        let changed = lock.withLock {
            if required { return false }
            required = true
            return true
        }
        if changed { NotificationCenter.default.post(name: Self.notification, object: nil) }
        throw ClientUpgradeRequiredError()
    }

    static var buildHeader: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !value.isEmpty, value.count <= 9, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return value
    }
}

/// Shared by settings, the upgrade screen, and the share extension. The page
/// goes live with release, not review; the publication flag has one owner.
enum AppStoreListing {
    static let appID: String? = "6801962436"
    static let isPagePublished = false
    static var pageURL: URL? {
        guard isPagePublished else { return nil }
        guard let appID, !appID.isEmpty, appID.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://apps.apple.com/jp/app/id\(appID)")
    }
    static let recommendMessage = "うちの猫の写真が、ホーム画面に。ねこのまど"
}

#if os(iOS) && canImport(SwiftUI)
import SwiftUI

struct ClientUpgradeRequiredView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text(ClientUpgradeRequirement.message)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("client-upgrade-message")
            if let url = AppStoreListing.pageURL {
                Link("App Store を開く", destination: url)
                    .accessibilityIdentifier("client-upgrade-store")
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
#endif
