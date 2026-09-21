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
    let isPreview: Bool
    private var hasLoaded = false
    private let loadAction: () async -> MembershipOfferPresentation?
    private let purchaseAction: () async -> MembershipOfferActionResult
    private let restoreAction: () async -> MembershipOfferActionResult

    var canPurchase: Bool { offer != nil && !isWorking && !isWaiting }
    var canRestore: Bool { !isWorking }

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

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isWorking = true
        offer = await loadAction()
        isWorking = false
        if offer == nil { message = "料金を確認できません。時間をおいて開き直してください。" }
    }

    func purchase() async -> MembershipOfferActionResult {
        guard canPurchase else { return .unavailable }
        isWorking = true
        defer { isWorking = false }
        let result = await purchaseAction()
        apply(result, restoring: false)
        return result
    }

    func restore() async -> MembershipOfferActionResult {
        guard canRestore else { return .unavailable }
        isWorking = true
        defer { isWorking = false }
        let result = await restoreAction()
        apply(result, restoring: true)
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
        let client = MembershipStoreKitClient()
        return MembershipOfferModel(
            isPreview: false,
            load: { await client.load() },
            purchase: { await client.purchase() },
            restore: { await client.restore() }
        )
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

@MainActor
private final class MembershipStoreKitClient {
    private let configuration = PlusPurchaseConfiguration.current
    private let purchases = PlusPurchaseStore()
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
        if purchases.entitlementState.grantsPlus { return .completed }
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
                onPurchase: {
                    Task {
                        let result = await model.purchase()
                        if result == .completed || result == .cancelled { onFinish(result) }
                    }
                },
                onRestore: {
                    Task {
                        let result = await model.restore()
                        if result == .completed { onFinish(result) }
                    }
                },
                onClose: { onFinish(.cancelled) }
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
            MembershipOfferSheet(model: .preview(purchaseResult: purchaseResult)) { result in
                showsOffer = false
                resultText = result == .completed
                    ? "確認を終えて、元の画面に戻りました。契約は変更していません。"
                    : "取り消して、元の画面に戻りました。"
            }
        }
    }
}

#if DEBUG
@MainActor
struct MembershipOfferFixture: View {
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
            MembershipOfferPreviewView(purchaseResult: result)
                .safeAreaInset(edge: .bottom) {
                    Text(configurationPasses ? "構成確認OK" : "構成確認失敗")
                        .font(.caption)
                        .accessibilityIdentifier("membership-fixture-configuration")
                }
        }
    }

    private var result: MembershipOfferActionResult {
        if CommandLine.arguments.contains("--membership-purchase-waiting") { return .waiting }
        if CommandLine.arguments.contains("--membership-purchase-cancelled") { return .cancelled }
        return .completed
    }
}
#endif
