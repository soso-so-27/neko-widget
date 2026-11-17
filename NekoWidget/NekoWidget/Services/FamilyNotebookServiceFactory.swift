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
            guard configuration.isGroupRuntimeAvailable,
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
        }, displayName: { try GroupWire.name(GroupDisplayName.remembered) }, catNames: { FamilyNotebookPrototype.shared.catNames },
        privateFarewellDay: { tool, profile in
            try FamilyNotebookPrivateFarewell.day(json: UserDefaults.standard.string(forKey: CatFarewell.key) ?? "",
                toolCatID: tool, profileID: profile)
        }, hasPersonalPlus: { PlusPurchaseStore.productionShared.entitlementState.permitsPersonalPlus },
        hasExistingIdentity: {
            guard let client = GroupWindowClientProvider.production else { throw FamilySharingError.serviceUnavailable }
            return try await client.hasExistingIdentity()
        }, photoRuntimeEnabled: representativePhotoRuntimeEnabled, photoTransport: GroupURLSessionTransport(),
        moderationRecipient: {
            // The same reviewed recipient as a まど report, pinned in the
            // app's configuration; never one from a server reply.
            let configuration = SharingAPIConfiguration.current
            guard let keyID = configuration.moderationKeyID, let key = configuration.moderationPublicKey,
                  GroupReportCrypto.acceptsRecipient(keyID: keyID, publicKey: key, configuration: configuration) else { return nil }
            return (keyID, key)
        })
    }

    /// 11/17: the family's representative photo. No setting turns it on:
    /// the server's gate is off, and the client stays off with it in every
    /// build. While false, no 「…」 item appears and no photo call is made.
    /// Review captures use a synthetic relay instead
    /// (AppStoreScreenshotFixture.CatHomeStress, `--cat-home-stress-family-photo`).
    static let representativePhotoRuntimeEnabled = false

    /// The screens' way to the photo; nil while it is off.
    static func representativePhotoBackend() -> (any FamilyRepresentativePhotoBackend)? {
        guard representativePhotoRuntimeEnabled, productionRequested,
              let service = FamilyNotebookSharing.shared.service as? ProductionFamilyNotebookSharingService,
              service.representativePhotosEnabled else { return nil }
        return ProductionFamilyRepresentativePhotoBackend(service: service)
    }
}

/// The real service behind the screens' photo model.
@MainActor
final class ProductionFamilyRepresentativePhotoBackend: FamilyRepresentativePhotoBackend {
    private let service: ProductionFamilyNotebookSharingService
    init(service: ProductionFamilyNotebookSharingService) { self.service = service }
    var myPersonID: String? { service.personID }
    func displayName(of personID: String) -> String? {
        FamilyNotebookPrototype.shared.members.first { $0.personID == personID }?.displayName
    }
    func author(of cat: UUID) -> String? { service.representativePhotoAuthor(familyCatID: cat) }
    func load(_ cats: [UUID]) async throws -> [UUID: FamilyNotebookPhotoLoad] {
        try await service.representativePhotos(familyCatIDs: cats)
    }
    func deliver(_ cat: UUID, source: Data) async throws { try await service.deliverRepresentativePhoto(familyCatID: cat, source: source) }
    func retry(_ cat: UUID) async throws { try await service.retryRepresentativePhoto(familyCatID: cat) }
    func clear(_ cat: UUID) async throws {
        try service.clearRepresentativePhoto(familyCatID: cat)
        // The person's own read sends it (the caller marks the tap).
        _ = await FamilyNotebookSharing.shared.refreshAfterPlusChange(reportsFailure: false)
    }
    func report(assetID: UUID, reason: GroupReportReason) async throws -> String {
        try await service.reportRepresentativePhoto(assetID: assetID, reasonCode: reason.rawValue)
    }
    func hide(_ personID: String) async throws { try await service.hideRepresentativePhotos(of: personID) }
    func unhide(_ personID: String) async throws { try await service.showRepresentativePhotos(of: personID) }
}
