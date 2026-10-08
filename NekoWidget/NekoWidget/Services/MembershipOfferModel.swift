import Combine
import Foundation
import StoreKit
import SwiftUI

struct MembershipOfferPresentation: Equatable {
    let priceText: String
    let renewalText: String
    let trialText: String?
    let purchaseTitle: String
    let isPreview: Bool
}

enum MembershipOfferActionResult: Equatable {
    case completed, cancelled, waiting, nothingToRestore, unavailable, failed
}

/// Ephemeral presentation state only. It never grants an entitlement, writes
/// a memo, sends a photo, or changes the caller's navigation or draft.
@MainActor
final class MembershipOfferModel: ObservableObject {
    @Published private(set) var offer: MembershipOfferPresentation?
    @Published private(set) var isWorking = true
    @Published private(set) var message: String?
    @Published private(set) var isWaiting = false
    @Published private(set) var isMember = false
    @Published private(set) var verificationRequired = false
    @Published private(set) var purchaseTitle: String?
    private var purchases: PlusPurchaseStore?
    private var observation: AnyCancellable?
    private var expiryTask: Task<Void, Never>?
    private var fixtureStatus: MembershipOfferFixtureStatus?
    private var fixtureExpiresAt: Date?
    private var fixtureAllowsPurchase = true

    var canRefresh: Bool { !isWorking && !isMember && (verificationRequired || isWaiting) }
    let isPreview: Bool
    private var hasLoaded = false
    private let loadAction: () async -> MembershipOfferPresentation?
    private let purchaseAction: () async -> MembershipOfferActionResult
    private let restoreAction: () async -> MembershipOfferActionResult

    var canPurchase: Bool {
        offer != nil && !isWorking && !isWaiting && !isMember
            && !verificationRequired && (purchases?.canStartNewPurchase ?? fixtureAllowsPurchase)
            && !(purchases?.isPurchasing ?? false) && !(purchases?.isRestoring ?? false)
    }
    var canRestore: Bool { !isWorking && !(purchases?.isPurchasing ?? false) && !(purchases?.isRestoring ?? false) }

    private init(
        isPreview: Bool,
        load: @escaping () async -> MembershipOfferPresentation?,
        purchase: @escaping () async -> MembershipOfferActionResult,
        restore: @escaping () async -> MembershipOfferActionResult
    ) {
        self.isPreview = isPreview
        loadAction = load
        purchaseAction = purchase
        restoreAction = restore
    }

    deinit { expiryTask?.cancel() }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isWorking = true
        offer = await loadAction()
        isWorking = false
        updateMembershipState()
        if offer == nil && !isMember { message = "料金を確認できません。時間をおいて開き直してください。" }
    }

    func purchase() async -> MembershipOfferActionResult {
        guard canPurchase else { return .unavailable }
        isWorking = true
        defer { isWorking = false }
        let result = await purchaseAction()
        if result == .completed, fixtureStatus != nil { fixtureStatus = .active }
        apply(result, restoring: false)
        updateMembershipState()
        return result
    }

    func restore() async -> MembershipOfferActionResult {
        guard canRestore else { return .unavailable }
        isWorking = true
        defer { isWorking = false }
        let result = await restoreAction()
        if result == .completed, fixtureStatus != nil { fixtureStatus = .active }
        apply(result, restoring: true)
        updateMembershipState()
        return result
    }

    private func apply(_ result: MembershipOfferActionResult, restoring: Bool) {
        switch result {
        case .completed, .cancelled:
            message = nil
            if result == .completed { isWaiting = false }
        case .waiting:
            isWaiting = true
            message = "購入の確認を待っています。追加の申し込みはせず、あとで購入を復元してください。"
        case .nothingToRestore:
            message = "有効な購入が見つかりませんでした。購入時のApple Accountをご確認ください。"
        case .unavailable:
            message = "現在、購入手続きを利用できません。写真やメモはそのままです。"
        case .failed:
            message = restoring
                ? "購入を確認できませんでした。写真やメモはそのままです。"
                : "申し込みを確認できませんでした。購入を復元して状況を確認できます。"
        }
    }

    static func live() -> MembershipOfferModel {
        let store = PlusPurchaseStore.productionShared
        let client = MembershipStoreKitClient(purchases: store)
        let model = MembershipOfferModel(
            isPreview: false,
            load: { await client.load() },
            purchase: { await client.purchase() },
            restore: { await client.restore() }
        )
        model.purchases = store
        model.observation = store.objectWillChange.sink { [weak model] _ in
            // @Published sends before its new value is installed.
            Task { @MainActor in model?.updateMembershipState() }
        }
        model.updateMembershipState()
        return model
    }

    func refresh() async {
        guard canRefresh else { return }
        isWorking = true
        if let purchases {
            await purchases.refreshAfterForegroundEntry()
        } else if let fixtureStatus {
            switch fixtureStatus {
            case .unknown, .authorityPending: self.fixtureStatus = .active
            case .expired: self.fixtureStatus = .fresh
            case .fresh, .active, .applePending: break
            }
        }
        updateMembershipState()
        isWorking = false
    }

    private func updateMembershipState() {
        expiryTask?.cancel()
        if let purchases {
            isMember = purchases.entitlementState.grantsPlus
            isWaiting = purchases.pendingProductID != nil || purchases.awaitingServerConfirmation
            verificationRequired = !isMember && !isWaiting && !purchases.canStartNewPurchase
            if isMember, let expiry = purchases.entitlementState.lastServerConfirmed?.expirationDate {
                expiryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    self?.updateMembershipState()
                }
            }
        } else if let fixtureStatus {
            if fixtureStatus == .active, let fixtureExpiresAt {
                if fixtureExpiresAt <= .now {
                    self.fixtureStatus = .expired
                    updateMembershipState()
                    return
                }
                expiryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, fixtureExpiresAt.timeIntervalSinceNow))) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    self?.updateMembershipState()
                }
            }
            isMember = fixtureStatus == .active
            isWaiting = fixtureStatus == .applePending || fixtureStatus == .authorityPending
            verificationRequired = fixtureStatus == .unknown || fixtureStatus == .expired
            fixtureAllowsPurchase = fixtureStatus == .fresh
        } else { return }
        if isMember {
            purchaseTitle = "加入中です"
            message = nil
        } else if isWaiting {
            purchaseTitle = "購入の確認待ちです"
            message = purchases?.pendingProductID != nil || fixtureStatus == .applePending
                ? "Appleの購入確認を待っています。追加の申し込みはしないでください。"
                : "購入の確認を待っています。追加の申し込みはせず、会員情報を再確認してください。"
        } else if verificationRequired {
            purchaseTitle = "会員情報の確認が必要です"
            message = "会員情報を確認できません。追加の申し込みはせず、会員情報を再確認してください。"
        } else {
            purchaseTitle = nil
            message = nil
        }
    }

    static func preview(state: MembershipOfferFixtureStatus, expiresAfter: TimeInterval? = nil) -> MembershipOfferModel {
        let model = preview()
        model.fixtureStatus = state
        if state == .active, let expiresAfter {
            model.fixtureExpiresAt = .now.addingTimeInterval(expiresAfter)
        }
        model.updateMembershipState()
        return model
    }

    /// The preview has no StoreKit/session/Keychain dependency. Its results
    /// only dismiss the preview and can never change purchase authority.
    static func preview(
        purchaseResult: MembershipOfferActionResult = .completed,
        restoreResult: MembershipOfferActionResult = .completed
    ) -> MembershipOfferModel {
        MembershipOfferModel(
            isPreview: true,
            load: {
                MembershipOfferPresentation(
                    priceText: "月額980円（検討中）",
                    renewalText: "無料期間終了後は月ごとに自動更新する案です。",
                    trialText: "初回7日間無料（検討中）",
                    purchaseTitle: "申し込みの流れを確認",
                    isPreview: true
                )
            },
            purchase: { purchaseResult },
            restore: { restoreResult }
        )
    }
}

enum MembershipOfferFixtureStatus: String {
    case fresh, active, applePending, authorityPending, unknown, expired
}

@MainActor
private final class MembershipStoreKitClient {
    private let configuration = PlusPurchaseConfiguration.current
    private let purchases: PlusPurchaseStore

    init(purchases: PlusPurchaseStore) { self.purchases = purchases }
    private let session = PlusBillingSession.configured(purchaseConfiguration: .current)

    func load() async -> MembershipOfferPresentation? {
        guard configuration.isConfigured, session != nil,
              AppPublicLinksConfiguration.current.privacyURL != nil else { return nil }
        await purchases.start()
        guard let product = purchases.products.first(where: {
            $0.id == configuration.monthlyProductID
        }), let subscription = product.subscription,
           subscription.subscriptionPeriod.unit == .month,
           subscription.subscriptionPeriod.value == 1 else { return nil }

        var trial: String?
        if await subscription.isEligibleForIntroOffer,
           let introductory = subscription.introductoryOffer,
           introductory.paymentMode == .freeTrial,
           let period = Self.periodText(introductory.period, count: introductory.periodCount) {
            trial = "\(period)無料"
        }
        return MembershipOfferPresentation(
            priceText: "\(product.displayPrice) / 月",
            renewalText: trial == nil ? "月ごとに自動更新されます。" : "無料期間終了後、月ごとに自動更新されます。",
            trialText: trial,
            purchaseTitle: trial.map { "\($0)で試す" } ?? "会員プランを始める",
            isPreview: false
        )
    }

    func purchase() async -> MembershipOfferActionResult {
        guard configuration.isConfigured, let session else { return .unavailable }
        // Re-evaluate eligibility immediately before the explicit purchase;
        // an old offer must not turn a later unknown state into a new purchase.
        await purchases.refreshAfterForegroundEntry()
        if purchases.entitlementState.grantsPlus { return .completed }
        guard purchases.canStartNewPurchase, purchases.pendingProductID == nil,
              !purchases.awaitingServerConfirmation else { return .unavailable }
        do {
            let account = try await session.prepareAccountForExplicitPurchase()
            switch await purchases.purchase(.monthly, billingAccountID: account) {
            case .purchased: return .completed
            case .cancelled: return .cancelled
            case .pending, .awaitingServerConfirmation: return .waiting
            case .unavailable: return .unavailable
            case .verificationFailed, .failed: return .failed
            }
        } catch BillingClientError.billingAccountRecoveryRequired {
            return .waiting
        } catch {
            return .failed
        }
    }

    func restore() async -> MembershipOfferActionResult {
        guard configuration.isConfigured, let session else { return .unavailable }
        var outcome = await purchases.restorePurchases()
        if outcome == .indeterminate {
            do {
                _ = try await session.recoverBillingAccountExplicitly()
                await purchases.refreshAfterForegroundEntry()
                if purchases.entitlementState.grantsPlus { return .completed }
                outcome = .indeterminate
            } catch { return .failed }
        }
        switch outcome {
        case .entitlementFound: return .completed
        case .nothingToRestore: return .nothingToRestore
        case .indeterminate: return .waiting
        case .unavailable: return .unavailable
        case .failed: return .failed
        }
    }

    private static func periodText(_ period: Product.SubscriptionPeriod, count: Int) -> String? {
        let (value, overflow) = period.value.multipliedReportingOverflow(by: count)
        guard !overflow, value > 0 else { return nil }
        switch period.unit {
        case .day: return "\(value)日間"
        case .week: return "\(value)週間"
        case .month: return "\(value)か月間"
        case .year: return "\(value)年間"
        @unknown default: return nil
        }
    }
}

@MainActor
struct MembershipOfferSheet: View {
    @StateObject private var model: MembershipOfferModel
    let photo: UIImage?
    let onFinish: (MembershipOfferActionResult) -> Void

    init(model: MembershipOfferModel, photo: UIImage? = nil,
         onFinish: @escaping (MembershipOfferActionResult) -> Void) {
        _model = StateObject(wrappedValue: model)
        self.photo = photo
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            MembershipOfferView(
                photo: photo, offer: model.offer, isWorking: model.isWorking,
                canPurchase: model.canPurchase, canRestore: model.canRestore,
                message: model.message,
                isMember: model.isMember, purchaseTitle: model.purchaseTitle,
                canRefresh: model.canRefresh,
                onRefresh: { Task { await model.refresh() } },
                onPurchase: {
                    Task {
                        let result = await model.purchase()
                        if model.isPreview && (result == .completed || result == .cancelled) { onFinish(result) }
                    }
                },
                onRestore: {
                    Task {
                        let result = await model.restore()
                        if model.isPreview && result == .completed { onFinish(result) }
                    }
                },
                onClose: { onFinish(model.isMember ? .completed : .cancelled) }
            )
        }
        .interactiveDismissDisabled(model.isWorking)
        .task { await model.load() }
    }
}

/// Read-only, no-charge entry for the current internal builds. App Store
/// production receipts never expose it; no authority is derived from this flag.
enum MembershipOfferPreviewAvailability {
    static var isAvailable: Bool {
#if DEBUG
        true
#else
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
#endif
    }
}

@MainActor
struct MembershipOfferPreviewView: View {
    @State private var showsOffer = false
    @State private var resultText: String?
    var purchaseResult: MembershipOfferActionResult = .completed
    var membershipState: MembershipOfferFixtureStatus?
    var expiresAfter: TimeInterval?

    var body: some View {
        List {
            Section {
                Button("会員案内を開く") { showsOffer = true }
                    .accessibilityIdentifier("membership-preview-open")
            } footer: {
                Text("操作の確認用です。申し込み・請求・現在の機能の制限は行いません。")
            }
            if let resultText {
                Text(resultText).accessibilityIdentifier("membership-preview-result")
            }

        }
        .navigationTitle("会員案内の確認")
        .sheet(isPresented: $showsOffer) {
            MembershipOfferSheet(model: membershipState.map { .preview(state: $0, expiresAfter: expiresAfter) }
                                 ?? .preview(purchaseResult: purchaseResult)) { result in
                showsOffer = false
                resultText = result == .completed
                    ? "確認を終えて、元の画面に戻りました。契約は変更していません。"
                    : "取り消して、元の画面に戻りました。"
            }
        }
    }
}

enum BillingSandboxOwnerEnrollmentAvailability {
    static var isAvailable: Bool {
        let preservation = ManagedPreservationConfiguration.current
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
            && (Bundle.main.object(forInfoDictionaryKey: "SharingReleaseMode") as? String) == "media-staging"
            && preservation.isEnabled
            && preservation.origin?.absoluteString
                == "https://neko-preservation-staging-disabled.nakanishisoya.workers.dev"
            && preservation.membershipAudience == "neko-preservation-staging"
    }
}

/// Internal setup stays local until the owner policy is admitted separately.
@MainActor
struct BillingSandboxOwnerEnrollmentView: View {
    @State private var ownerEnrollment: BillingSandboxOwnerEnrollment?
    @State private var enrollmentMessage: String?
    @State private var canPrepare = false
    @State private var isPreparing = false
    init() { }
#if DEBUG
    private var fixture: BillingOwnerEnrollmentFixtureState?
    init(fixture: BillingOwnerEnrollmentFixtureState) { self.fixture = fixture }
#endif

    var body: some View {
        List {
            if ownerEnrollmentAvailable {
                Section {
                    Button("端末確認情報を表示") { readOwnerEnrollment() }
                        .accessibilityIdentifier("billing-owner-enrollment-read")
                        .disabled(isPreparing)
                    if canPrepare {
                        Button(isPreparing ? "準備しています…" : "テストの準備をする") {
                            Task { await prepareOwnerEnrollment() }
                        }
                        .accessibilityIdentifier("billing-owner-enrollment-prepare")
                        .disabled(isPreparing)
                    }
                    if let ownerEnrollment {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("申込ID").font(.caption).foregroundStyle(.secondary)
                            Text(ownerEnrollment.bootstrapClientRequestID)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("billing-owner-enrollment-request")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("公開鍵の指紋").font(.caption).foregroundStyle(.secondary)
                            Text(ownerEnrollment.initialPublicKeySHA256)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("billing-owner-enrollment-fingerprint")
                        }
                    }
                    if let enrollmentMessage {
                        Text(enrollmentMessage).font(.footnote)
                            .accessibilityIdentifier("billing-owner-enrollment-status")
                    }
                } footer: {
                    Text("準備では、この端末だけに確認用の鍵と申込IDを保存します。購入・サーバーへの登録は始まりません。秘密鍵は端末の外へ送りません。")
                }
            } else {
                Text("このビルドでは端末確認を利用できません。")
            }
        }.navigationTitle("本人限定テストの端末確認")
    }

    private var ownerEnrollmentAvailable: Bool {
#if DEBUG
        if fixture != nil { return true }
#endif
        return BillingSandboxOwnerEnrollmentAvailability.isAvailable
    }

    private func readOwnerEnrollment() {
        ownerEnrollment = nil
        canPrepare = false
        guard ownerEnrollmentAvailable else { return }
#if DEBUG
        if let fixture {
            ownerEnrollment = fixture.enrollment
            canPrepare = fixture.enrollment == nil
            enrollmentMessage = canPrepare ? "この端末の準備はまだです。" : "購入はまだ開始していません。"
            return
        }
#endif
        do {
            // Read credentials first. A retained key with a missing marker
            // must never be mistaken for a clean installation.
            guard let credential = try BillingKeychainStore.load() else {
                _ = try BillingInstallationMarkerStore.loadExisting()
                canPrepare = true
                enrollmentMessage = "この端末の準備はまだです。「テストの準備をする」から進めてください。"
                return
            }
            guard let marker = try BillingInstallationMarkerStore.loadExisting() else {
                throw BillingClientError.installationChanged
            }
            ownerEnrollment = try BillingSandboxOwnerEnrollment.readExistingPending(
                credential: credential, installationMarker: marker
            )
            enrollmentMessage = "購入はまだ開始していません。本人確認のため、この2項目を運用者と照合してください。"
        } catch {
            enrollmentMessage = "この端末の申込準備を確認できません。状態は変更していません。"
        }
    }

    private func prepareOwnerEnrollment() async {
        guard ownerEnrollmentAvailable, canPrepare, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
#if DEBUG
            if let fixture {
                guard BillingKeychainStore.verifySandboxOwnerPreparation() else {
                    throw BillingClientError.credentialChanged
                }
                let marker = UUID()
                let credential = BillingCredential.pending(installationMarker: marker)
                fixture.enrollment = try BillingSandboxOwnerEnrollment.readExistingPending(
                    credential: credential, installationMarker: marker
                )
                ownerEnrollment = fixture.enrollment
                canPrepare = false
                enrollmentMessage = "準備できました。購入はまだ始まっていません。境界確認OK"
                return
            }
#endif
            let authorization = try await BillingFreshAccountAuthorizer()
                .authorizeForSandboxOwnerPreparation()
            ownerEnrollment = try BillingKeychainStore.prepareSandboxOwnerPending(
                authorizedBy: authorization
            )
            canPrepare = false
            enrollmentMessage = "準備できました。申込IDと公開鍵の指紋を運用者へ伝えてください。購入はまだ始まっていません。"
        } catch BillingClientError.billingAccountRecoveryRequired {
            canPrepare = false
            enrollmentMessage = "既存の購入が見つかりました。新しい申込情報は作らず、購入の復元が必要です。"
        } catch {
            enrollmentMessage = "準備を完了できませんでした。「端末確認情報を表示」で現在の状態を確認してください。"
            canPrepare = false
        }
    }
}

#if DEBUG
@MainActor
final class BillingOwnerEnrollmentFixtureState {
    var enrollment: BillingSandboxOwnerEnrollment?
}

@MainActor
struct MembershipOfferFixture: View {
    @State private var enrollmentFixture = BillingOwnerEnrollmentFixtureState()
    private var configurationPasses: Bool {
        func config(_ enabled: Bool, _ monthly: String?, _ annual: String?) -> PlusPurchaseConfiguration {
            PlusPurchaseConfiguration(isEnabled: enabled, monthlyProductID: monthly, annualProductID: annual)
        }
        return config(true, "jp.neko.monthly", nil).isConfigured
            && config(true, "jp.neko.monthly", "").productIDs == ["jp.neko.monthly"]
            && config(true, "jp.neko.monthly", "jp.neko.annual").productIDs.count == 2
            && !config(false, "jp.neko.monthly", nil).isConfigured
            && !config(true, nil, "jp.neko.annual").isConfigured
            && !config(true, "jp.neko.monthly", "jp.neko.monthly").isConfigured
            && !config(true, "jp.neko.monthly", "invalid product").isConfigured
            && !config(true, " jp.neko.monthly", nil).isConfigured
    }

    var body: some View {
        NavigationStack {
            if CommandLine.arguments.contains("--billing-owner-enrollment-fixture") {
                BillingSandboxOwnerEnrollmentView(fixture: enrollmentFixture)
            } else {
                MembershipOfferPreviewView(purchaseResult: result, membershipState: membershipState,
                                           expiresAfter: CommandLine.arguments.contains("--membership-state-expiring") ? 2 : nil)
                .safeAreaInset(edge: .bottom) {
                    Text(configurationPasses ? "構成確認OK" : "構成確認失敗")
                        .font(.caption)
                        .accessibilityIdentifier("membership-fixture-configuration")
                }
            }
        }
    }

    private var result: MembershipOfferActionResult {
        if CommandLine.arguments.contains("--membership-purchase-waiting") { return .waiting }
        if CommandLine.arguments.contains("--membership-purchase-cancelled") { return .cancelled }
        return .completed
    }

    private var membershipState: MembershipOfferFixtureStatus? {
        let arguments = CommandLine.arguments
        if arguments.contains("--membership-state-expiring") { return .active }
        if arguments.contains("--membership-state-active") { return .active }
        if arguments.contains("--membership-state-unknown") { return .unknown }
        if arguments.contains("--membership-state-expired") { return .expired }
        if arguments.contains("--membership-state-apple-pending") { return .applePending }
        if arguments.contains("--membership-state-authority-pending") { return .authorityPending }
        if arguments.contains("--membership-state-fresh") { return .fresh }
        return nil
    }
}
#endif
