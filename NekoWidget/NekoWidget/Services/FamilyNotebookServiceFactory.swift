import Foundation

@MainActor
enum FamilyNotebookServiceFactory {
    static var productionRequested: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "FamilyNotebookProductionEnabled") as? String) == "YES"
    }
    static func make() -> any FamilyNotebookSharingService {
        guard productionRequested else { return FamilyNotebookPrototypeSharing() }
        // Keep the production adapter even if configuration is incomplete. A
        // requested real build must fail closed, never impersonate a family
        // by falling back to the locally simulated prototype.
        return ProductionFamilyNotebookSharingService(provider: {
            let configuration = SharingAPIConfiguration.current
            guard configuration.releaseMode == "media-staging", configuration.isMediaEnabled,
                  let endpoint = configuration.baseURL, let client = GroupWindowClientProvider.production,
                  let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw FamilySharingError.serviceUnavailable
            }
            let identity = try await client.familyNotebookIdentity()
            let scope = try GroupWire.base64(GroupCanonical.hash(GroupCanonical.fields([
                Data(endpoint.absoluteString.utf8), Data(identity.personID.utf8), Data(identity.deviceID.utf8)])))
            let directory = root.appendingPathComponent("FamilyNotebook-v1", isDirectory: true).appendingPathComponent(scope, isDirectory: true)
            let journal = try GroupOperationStore(directory: directory.appendingPathComponent("http", isDirectory: true), maximumRecordBytes: 2_100_000)
            let secrets = try GroupKeychainStore(namespace: GroupWindowClientProvider.namespace + ".family." + scope)
            return try FamilyNotebookSession(endpoint: endpoint, identity: identity, transport: GroupURLSessionTransport(),
                journal: journal, secrets: secrets, directory: directory.appendingPathComponent("notebooks", isDirectory: true))
        }, billing: {
            guard let client = GroupWindowClientProvider.production else { throw FamilySharingError.serviceUnavailable }
            try await client.connectExistingBillingAccount()
        }, displayName: { try GroupWire.name(GroupDisplayName.remembered) }, catNames: { [] })
    }
}
