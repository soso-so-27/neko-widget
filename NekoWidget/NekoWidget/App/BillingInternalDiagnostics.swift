#if DEBUG
import SwiftUI

enum BillingInternalDiagnosticsLaunch {
    static let argument = "--billing-internal-diagnostics"

    static var isActive: Bool {
        CommandLine.arguments.contains(argument)
    }
}

/// An argument-only internal surface. It is absent from Release builds and
/// deliberately bypasses ProductionAppRootView, StoreKit startup, normal
/// navigation, Widget, and Share Extension entry points.
@MainActor
struct BillingInternalDiagnosticsRootView: View {
    @StateObject private var model = BillingInternalDiagnosticsModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Gate / config") {
                    LabeledContent(
                        "Billing transport",
                        value: model.billingConfigurationText
                    )
                    LabeledContent(
                        "Window sponsorship",
                        value: model.sponsorshipConfigurationText
                    )
                    LabeledContent(
                        "StoreKit actions",
                        value: model.storeKitConfigurationText
                    )
                    LabeledContent("対象のまど", value: model.targetWindowText)
                    LabeledContent(
                        "Billing Keychain",
                        value: model.billingKeychainText
                    )
                    LabeledContent(
                        "Window signing Keychain",
                        value: model.pairingKeychainText
                    )
                }

                Section("Explicit operations") {
                    ForEach(BillingInternalOperation.allCases) { operation in
                        Button {
                            Task {
                                await model.perform(operation)
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(operation.title)
                                Spacer()
                                Text(model.statusText(for: operation))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        .disabled(!model.canPerform(operation))
                    }
                }
            }
            .navigationTitle("Billing diagnostics")
        }
    }
}

private enum BillingInternalOperation: String, CaseIterable, Identifiable {
    case configurationAndKeychain
    case bootstrapOrResume
    case entitlement
    case sponsorshipGet
    case sponsor
    case payerUnsponsor
    case ownerDetach

    var id: String { rawValue }

    var title: String {
        switch self {
        case .configurationAndKeychain: "設定 / Keychain確認"
        case .bootstrapOrResume: "bootstrap / resume"
        case .entitlement: "entitlement"
        case .sponsorshipGet: "sponsorship GET"
        case .sponsor: "sponsor"
        case .payerUnsponsor: "payer unsponsor"
        case .ownerDetach: "owner detach"
        }
    }
}

private enum BillingInternalAvailability: String {
    case unchecked = "未確認"
    case available = "利用可"
    case missing = "なし"
    case failed = "確認失敗"
}

private enum BillingInternalFailure: String {
    case configuration = "失敗（設定）"
    case keychain = "失敗（Keychain）"
    case transport = "失敗（通信）"
    case serverRejected = "失敗（サーバー拒否）"
    case responseValidation = "失敗（応答検証）"
    case localState = "失敗（ローカル状態）"
}

private enum BillingInternalOutcome: Equatable {
    case idle
    case running
    case prerequisiteMissing
    case succeeded(String)
    case failed(BillingInternalFailure)

    var text: String {
        switch self {
        case .idle: "未実行"
        case .running: "実行中"
        case .prerequisiteMissing: "前提未取得"
        case let .succeeded(summary): "成功（\(summary)）"
        case let .failed(failure): failure.rawValue
        }
    }
}

private enum BillingInternalPrerequisiteError: Error {
    case missing
}

private struct BillingInternalPairingAuthorization {
    let state: PairingState
    let credential: PairingCredential
    let lifecycleToken: SharingLifecycleGate.Token
    let localWindowID: String
    let displayName: String

    var binding: BillingInternalOwnerBinding? {
        guard let spaceID = state.spaceID,
              let memberID = state.memberID,
              let deviceID = state.resolvedLocalMomentDeviceID,
              let credentialAccount = state.credentialAccount
        else { return nil }
        return BillingInternalOwnerBinding(
            spaceID: spaceID,
            memberID: memberID,
            deviceID: deviceID,
            credentialAccount: credentialAccount,
            installationMarker: state.installationMarker,
            localWindowID: localWindowID
        )
    }
}

/// Identifiers stay only in memory so a later explicit tap can reject a
/// changed pairing binding. They are never rendered, logged, or persisted.
private struct BillingInternalOwnerBinding: Equatable {
    let spaceID: String
    let memberID: String
    let deviceID: String
    let credentialAccount: String
    let installationMarker: String
    let localWindowID: String

    func matches(_ authorization: BillingInternalPairingAuthorization) -> Bool {
        authorization.binding == self
    }
}

/// A participant read is held only for the next explicit operation. It is not
/// copied into access state, UserDefaults, files, Keychain, or diagnostics.
private struct BillingInternalSponsorshipSnapshot {
    let windowLineageID: String?
    let membershipRevision: Int?
    let generation: Int
    let isSponsored: Bool
    let ownerBinding: BillingInternalOwnerBinding?

    var hasOwnerConsentContext: Bool {
        windowLineageID != nil
            && membershipRevision != nil
            && ownerBinding != nil
    }

    func changing(
        generation: Int,
        isSponsored: Bool
    ) -> Self {
        Self(
            windowLineageID: windowLineageID,
            membershipRevision: membershipRevision,
            generation: generation,
            isSponsored: isSponsored,
            ownerBinding: ownerBinding
        )
    }
}

@MainActor
private final class BillingInternalDiagnosticsModel: ObservableObject {
    @Published private var outcomes: [BillingInternalOperation: BillingInternalOutcome] = [:]
    @Published private var runningOperation: BillingInternalOperation?
    @Published private var didCheckPrerequisites = false
    @Published private var billingKeychainAvailability: BillingInternalAvailability = .unchecked
    @Published private var pairingKeychainAvailability: BillingInternalAvailability = .unchecked
    @Published private(set) var targetWindowText = "未確認"

    private var registeredBillingAccountID: String?
    private var entitledBillingAccountID: String?
    private var entitlementGrantsPlus = false
    private var sponsorshipSnapshot: BillingInternalSponsorshipSnapshot?

    var billingConfigurationText: String {
        let configuration = BillingClientConfiguration.current
        if !configuration.isEnabled { return "OFF" }
        return configuration.isConfigured ? "ON" : "設定不足"
    }

    var sponsorshipConfigurationText: String {
        BillingWindowSponsorshipConfiguration.current.isEnabled ? "ON" : "OFF"
    }

    var storeKitConfigurationText: String {
        let gate = PlusPurchaseConfiguration.current.isConfigured ? "ON" : "OFF"
        return "\(gate) / 購入・復元なし / 現在の購入確認のみ"
    }

    var billingKeychainText: String { billingKeychainAvailability.rawValue }
    var pairingKeychainText: String { pairingKeychainAvailability.rawValue }

    func statusText(for operation: BillingInternalOperation) -> String {
        if let outcome = outcomes[operation], outcome != .idle {
            return outcome.text
        }
        return canPerformIgnoringRunning(operation)
            ? BillingInternalOutcome.idle.text
            : BillingInternalOutcome.prerequisiteMissing.text
    }

    func canPerform(_ operation: BillingInternalOperation) -> Bool {
        runningOperation == nil && canPerformIgnoringRunning(operation)
    }

    func perform(_ operation: BillingInternalOperation) async {
        guard canPerform(operation) else {
            outcomes[operation] = .prerequisiteMissing
            return
        }
        runningOperation = operation
        outcomes[operation] = .running
        defer { runningOperation = nil }

        switch operation {
        case .configurationAndKeychain:
            await checkConfigurationAndKeychains()
        case .bootstrapOrResume:
            await resumeBootstrap()
        case .entitlement:
            await fetchEntitlement()
        case .sponsorshipGet:
            await fetchSponsorship()
        case .sponsor:
            await sponsorWindow()
        case .payerUnsponsor:
            await unsponsorAsPayer()
        case .ownerDetach:
            await detachAsConfirmedOwner()
        }
    }

    private func canPerformIgnoringRunning(
        _ operation: BillingInternalOperation
    ) -> Bool {
        let billingConfigured = BillingClientConfiguration.current.isConfigured
        let sponsorshipEnabled = BillingWindowSponsorshipConfiguration.current.isEnabled
        switch operation {
        case .configurationAndKeychain:
            return true
        case .bootstrapOrResume:
            return didCheckPrerequisites
                && billingConfigured
                && [BillingInternalAvailability.available, .missing]
                    .contains(billingKeychainAvailability)
        case .entitlement:
            return billingConfigured && registeredBillingAccountID != nil
        case .sponsorshipGet:
            return didCheckPrerequisites
                && billingConfigured
                && sponsorshipEnabled
                && pairingKeychainAvailability == .available
        case .sponsor:
            guard let snapshot = sponsorshipSnapshot else { return false }
            return billingConfigured
                && sponsorshipEnabled
                && snapshot.hasOwnerConsentContext
                && !snapshot.isSponsored
                && entitlementGrantsPlus
                && entitledBillingAccountID == registeredBillingAccountID
        case .payerUnsponsor:
            guard let snapshot = sponsorshipSnapshot else { return false }
            return billingConfigured
                && sponsorshipEnabled
                && snapshot.isSponsored
                && snapshot.hasOwnerConsentContext
                && registeredBillingAccountID != nil
        case .ownerDetach:
            guard let snapshot = sponsorshipSnapshot else { return false }
            return billingConfigured
                && sponsorshipEnabled
                && snapshot.isSponsored
                && snapshot.hasOwnerConsentContext
        }
    }

    private func checkConfigurationAndKeychains() async {
        didCheckPrerequisites = true
        registeredBillingAccountID = nil
        entitledBillingAccountID = nil
        entitlementGrantsPlus = false
        sponsorshipSnapshot = nil
        targetWindowText = "未取得"

        var readFailed = false
        do {
            if try BillingKeychainStore.load() == nil {
                billingKeychainAvailability = .missing
            } else {
                billingKeychainAvailability = .available
            }
        } catch {
            billingKeychainAvailability = .failed
            readFailed = true
        }

        do {
            let authorization = try await loadPairingAuthorization()
            pairingKeychainAvailability = .available
            targetWindowText = authorization.displayName
        } catch BillingInternalPrerequisiteError.missing {
            pairingKeychainAvailability = .missing
        } catch {
            pairingKeychainAvailability = .failed
            readFailed = true
        }

        outcomes[.configurationAndKeychain] = readFailed
            ? .failed(.keychain)
            : .succeeded("確認完了")
    }

    private func resumeBootstrap() async {
        do {
            let apiClient = try makeAPIClient()
            let coordinator = BillingAccountBootstrapCoordinator(
                apiClient: apiClient
            )
            let credential: BillingCredential
            if try BillingKeychainStore.load() == nil {
                let authorization = try await BillingFreshAccountAuthorizer()
                    .authorizeAfterCurrentEntitlementScan()
                credential = try await coordinator.createFreshCredential(
                    authorizedBy: authorization
                ).validated()
            } else {
                credential = try await coordinator
                    .resumeExistingCredential().validated()
            }
            guard credential.phase == .registered,
                  let billingAccountID = credential.billingAccountID
            else { throw BillingClientError.invalidServerResponse }
            registeredBillingAccountID = billingAccountID
            billingKeychainAvailability = .available
            outcomes[.bootstrapOrResume] = .succeeded("登録済み")
        } catch {
            outcomes[.bootstrapOrResume] = outcome(for: error)
        }
    }

    private func fetchEntitlement() async {
        do {
            let credential = try registeredBillingCredential()
            let result = try await makeAPIClient()
                .fetchAuthoritativeEntitlement(credential: credential)
                .validated()
            entitledBillingAccountID = credential.billingAccountID
            entitlementGrantsPlus = result.grantsPlus
            outcomes[.entitlement] = .succeeded(
                result.grantsPlus ? "Plus有効" : "Plusなし"
            )
        } catch {
            entitledBillingAccountID = nil
            entitlementGrantsPlus = false
            outcomes[.entitlement] = outcome(for: error)
        }
    }

    private func fetchSponsorship() async {
        do {
            let authorization = try await loadPairingAuthorization()
            let requestedBinding = authorization.binding
            guard let memberID = authorization.state.memberID else {
                throw BillingInternalPrerequisiteError.missing
            }
            let result = try await BillingWindowSponsorshipCoordinator(
                apiClient: try makeAPIClient()
            ).fetchReadResultFromExplicitUserAction(
                memberID: memberID,
                credential: authorization.credential
            )
            try SharingLifecycleGate.validate(authorization.lifecycleToken)
            let currentAuthorization = try await loadPairingAuthorization()
            guard requestedBinding == currentAuthorization.binding else {
                throw BillingInternalPrerequisiteError.missing
            }
            targetWindowText = currentAuthorization.displayName
            let context = result.ownerConsentContext
            sponsorshipSnapshot = BillingInternalSponsorshipSnapshot(
                windowLineageID: context?.windowLineageID,
                membershipRevision: context?.membershipRevision,
                generation: result.grant.generation,
                isSponsored: result.grant.windowLineageSponsored,
                ownerBinding: context == nil ? nil : currentAuthorization.binding
            )
            let state = result.grant.windowLineageSponsored ? "提供中" : "未提供"
            let role = context == nil ? "member" : "owner"
            outcomes[.sponsorshipGet] = .succeeded("\(state) / \(role)")
        } catch {
            sponsorshipSnapshot = nil
            outcomes[.sponsorshipGet] = outcome(for: error)
        }
    }

    private func sponsorWindow() async {
        do {
            guard let snapshot = sponsorshipSnapshot,
                  let windowLineageID = snapshot.windowLineageID,
                  let membershipRevision = snapshot.membershipRevision,
                  let binding = snapshot.ownerBinding,
                  !snapshot.isSponsored
            else { throw BillingInternalPrerequisiteError.missing }
            let pairing = try await loadPairingAuthorization()
            guard binding.matches(pairing),
                  let ownerDeviceID = pairing.credential.deviceID,
                  ownerDeviceID == binding.deviceID
            else { throw BillingInternalPrerequisiteError.missing }
            let payer = try registeredBillingCredential()
            guard entitlementGrantsPlus,
                  payer.billingAccountID == entitledBillingAccountID
            else { throw BillingInternalPrerequisiteError.missing }

            let result = try await BillingWindowSponsorshipCoordinator(
                apiClient: try makeAPIClient()
            ).sponsorFromExplicitUserAction(
                windowLineageID: windowLineageID,
                expectedGeneration: snapshot.generation,
                expectedCurrentBillingAccountID: nil,
                ownerConsent: BillingWindowOwnerConsentContext(
                    consentSpaceID: binding.spaceID,
                    ownerParticipantID: binding.memberID,
                    ownerDeviceID: ownerDeviceID,
                    consentMembershipRevision: membershipRevision,
                    credential: pairing.credential
                ),
                payerCredential: payer
            )
            try SharingLifecycleGate.validate(pairing.lifecycleToken)
            sponsorshipSnapshot = snapshot.changing(
                generation: result.generation,
                isSponsored: true
            )
            outcomes[.sponsor] = .succeeded("提供開始")
        } catch {
            outcomes[.sponsor] = outcome(for: error)
        }
    }

    private func unsponsorAsPayer() async {
        do {
            guard let snapshot = sponsorshipSnapshot,
                  let windowLineageID = snapshot.windowLineageID,
                  let binding = snapshot.ownerBinding,
                  snapshot.isSponsored
            else { throw BillingInternalPrerequisiteError.missing }
            let pairing = try await loadPairingAuthorization()
            guard binding.matches(pairing) else {
                throw BillingInternalPrerequisiteError.missing
            }
            let payer = try registeredBillingCredential()
            let result = try await BillingWindowSponsorshipCoordinator(
                apiClient: try makeAPIClient()
            ).unsponsorAsPayerFromExplicitUserAction(
                windowLineageID: windowLineageID,
                expectedGeneration: snapshot.generation,
                payerCredential: payer
            )
            try SharingLifecycleGate.validate(pairing.lifecycleToken)
            sponsorshipSnapshot = snapshot.changing(
                generation: result.generation,
                isSponsored: false
            )
            outcomes[.payerUnsponsor] = .succeeded("提供解除")
        } catch {
            outcomes[.payerUnsponsor] = outcome(for: error)
        }
    }

    private func detachAsConfirmedOwner() async {
        do {
            guard let snapshot = sponsorshipSnapshot,
                  let binding = snapshot.ownerBinding,
                  snapshot.isSponsored,
                  snapshot.hasOwnerConsentContext
            else { throw BillingInternalPrerequisiteError.missing }
            let pairing = try await loadPairingAuthorization()
            guard binding.matches(pairing),
                  let memberID = pairing.state.memberID
            else { throw BillingInternalPrerequisiteError.missing }
            let result = try await BillingWindowSponsorshipCoordinator(
                apiClient: try makeAPIClient()
            ).detachAsOwnerFromExplicitUserAction(
                expectedGeneration: snapshot.generation,
                memberID: memberID,
                credential: pairing.credential
            )
            try SharingLifecycleGate.validate(pairing.lifecycleToken)
            sponsorshipSnapshot = snapshot.changing(
                generation: result.generation,
                isSponsored: false
            )
            outcomes[.ownerDetach] = .succeeded("owner解除")
        } catch {
            outcomes[.ownerDetach] = outcome(for: error)
        }
    }

    private func makeAPIClient() throws -> URLSessionBillingAPIClient {
        try URLSessionBillingAPIClient(
            configuration: BillingClientConfiguration.current
        )
    }

    private func registeredBillingCredential() throws -> BillingCredential {
        guard let expectedAccountID = registeredBillingAccountID,
              let credential = try BillingKeychainStore.load()?.validated(),
              credential.phase == .registered,
              credential.billingAccountID == expectedAccountID
        else { throw BillingInternalPrerequisiteError.missing }
        return credential
    }

    private func loadPairingAuthorization() async throws
        -> BillingInternalPairingAuthorization {
        // Match every existing host-network entry: bootstrap first proves the
        // ordinary-container installation still owns the active catalog,
        // App Group state, and host-only Keychain credential.
        let bootstrap = try await PairingInstallationGuard.bootstrapAsync()
        let state = bootstrap.state
        guard state.phase == .paired,
              let account = state.credentialAccount,
              let participantID = state.participantID,
              state.spaceID != nil,
              state.memberID != nil,
              let catalog = try PrivateWindowCatalogStore.load(),
              let activeEntry = catalog.windows.first(where: {
                  $0.localWindowID == catalog.activeWindowID
              }),
              activeEntry.spaceID == state.spaceID,
              activeEntry.credentialAccount == state.credentialAccount
        else { throw BillingInternalPrerequisiteError.missing }
        let credential = try PairingKeychainStore.load(
            account: account,
            installationMarker: state.installationMarker
        ).validated()
        guard credential.participantIDString == participantID else {
            throw BillingClientError.localStateUnavailable
        }
        if let credentialDeviceID = credential.deviceID,
           credentialDeviceID != state.resolvedLocalMomentDeviceID {
            throw BillingClientError.localStateUnavailable
        }
        try SharingLifecycleGate.validate(bootstrap.lifecycleToken)
        return BillingInternalPairingAuthorization(
            state: state,
            credential: credential,
            lifecycleToken: bootstrap.lifecycleToken,
            localWindowID: activeEntry.localWindowID,
            displayName: activeEntry.displayName
        )
    }

    private func outcome(for error: Error) -> BillingInternalOutcome {
        if error is BillingInternalPrerequisiteError {
            return .prerequisiteMissing
        }
        if error is PairingKeychainStore.RetryableReadError {
            return .failed(.keychain)
        }
        guard let error = error as? BillingClientError else {
            return .failed(.localState)
        }
        switch error {
        case .configurationUnavailable:
            return .failed(.configuration)
        case .protectedDataUnavailable, .keychainUnavailable:
            return .failed(.keychain)
        case .transportUnavailable:
            return .failed(.transport)
        case .requestRejected:
            return .failed(.serverRejected)
        case .invalidServerResponse, .identityMismatch:
            return .failed(.responseValidation)
        case .billingCredentialMissing, .billingAccountRecoveryRequired,
             .billingAccountRecoveryUnavailable, .installationChanged,
             .freshAccountAuthorizationExpired:
            return .prerequisiteMissing
        case .localStateUnavailable, .malformedCredential,
             .billingAccountRecoveryEvidenceChanged,
             .windowSponsorshipAttemptPending, .credentialChanged:
            return .failed(.localState)
        }
    }
}
#endif
