import Combine
import Foundation
import StoreKit
import SwiftUI

/// Where the one Plus screen was opened from (ADR-027 5章). The sheet cannot
/// be created without one, so a new entry point is a deliberate code change
/// here and in `ci/run-cheap-safety-checks.sh`, never an accidental reuse.
/// Photo access, invitations, receiving, hearts, and favorites have no case.
///
/// Connected now: onboarding, Settings, a new memo, a monthly summary or
/// seasonal movie, preservation, the personal Widget resume path, and the
/// current group-window creation/continuation screens.
enum PlusOfferContext: Equatable, Sendable {
    /// The last, skippable page of the first run.
    case onboarding
    /// The app was opened from a personal Widget that kept its last photo.
    case widgetResume
    /// A monthly summary (1...12) or a seasonal movie (`nil`).
    case monthlySummary(month: Int?)
    case newMemo
    case createWindow
    /// The person who made a window opened it after it stopped.
    case continueWindow
    /// The family notebook stopped because the payer left (1029e). Whoever
    /// starts Plus first becomes the payer and sharing comes back.
    case continueFamily
    case preservation
    case settings

    /// The label of the control that opens the sheet at this place.
    var entryTitle: String {
        switch self {
        case .onboarding: "Plusについて見る"
        case .widgetResume: "ウィジェットの写真を、毎日新しくする"
        case let .monthlySummary(month?) where (1...12).contains(month): "\(month)月のまとめを見る"
        case .monthlySummary: "月のまとめ・ムービーを見る"
        case .newMemo: "メモを書く"
        case .createWindow: "まどを作る"
        case .continueWindow: "このまどを続ける"
        case .continueFamily: "家族の手帳を続ける"
        case .preservation: "保存を始める"
        case .settings: "Plusについて"
        }
    }

    /// One line above the heading saying why the screen appeared here.
    var reason: String? {
        switch self {
        case .onboarding, .settings: nil
        case .widgetResume: "ホーム画面の写真を毎日新しくするのは、Plusの機能です。"
        case .monthlySummary: "月のまとめと季節のムービーは、Plusで見られます。"
        case .newMemo: "新しいメモはPlusで書けます。書いたメモは、いつでも読めます。"
        case .createWindow: "まどを作るのは、Plusの機能です。"
        case .continueWindow: "このまどは、作った人のPlusで続きます。"
        case .continueFamily: "家族の手帳は、家族の誰か1人のPlusで続きます。"
        case .preservation: "写真やメモの保存は、Plusの機能です。"
        }
    }

    /// Stable suffix for accessibility identifiers and UI fixtures.
    var identifier: String {
        switch self {
        case .onboarding: "onboarding"
        case .widgetResume: "widget-resume"
        case .monthlySummary: "monthly-summary"
        case .newMemo: "new-memo"
        case .createWindow: "create-window"
        case .continueWindow: "continue-window"
        case .continueFamily: "continue-family"
        case .preservation: "preservation"
        case .settings: "settings"
        }
    }
}

/// The live sheet is offered only when the product and billing client are
/// both configured. Otherwise every entry stays hidden, as Settings did before.
enum PlusOfferAvailability {
    static var isConfigured: Bool {
        PlusPurchaseConfiguration.current.isConfigured
            && BillingClientConfiguration.current.isConfigured
    }
}

/// Every price and trial string comes from StoreKit (`displayPrice`,
/// `introductoryOffer`). The app never counts trial days itself.
struct MembershipOfferPresentation: Equatable {
    /// "月額¥980" — the billed amount, always shown.
    let priceText: String
    let renewalText: String
    /// "14日間無料" only when StoreKit reports introductory-offer eligibility.
    let trialText: String?
    let purchaseTitle: String
    /// "その後は月額¥980" under the trial button; `nil` without a trial.
    let afterTrialText: String?
    let isPreview: Bool

    /// One formatting path for the live offer and its previews.
    /// `displayPrice` and `trialPeriod` are StoreKit's values as given.
    static func monthly(displayPrice: String, trialPeriod: String?, isPreview: Bool) -> Self {
        let price = "月額\(displayPrice)"
        guard let trialPeriod else {
            return Self(priceText: price, renewalText: "1か月ごとに自動で更新されます。次の更新日の24時間前までに解約すれば、次の料金はかかりません。",
                        trialText: nil, purchaseTitle: "Plusを始める（\(price)）",
                        afterTrialText: nil, isPreview: isPreview)
        }
        return Self(priceText: price,
                    renewalText: "無料期間が終わると、1か月ごとに自動で更新されます。無料期間が終わる24時間前までに解約すれば、料金はかかりません。",
                    trialText: "\(trialPeriod)無料", purchaseTitle: "\(trialPeriod)無料で始める",
                    afterTrialText: "その後は\(price)", isPreview: isPreview)
    }
}

enum MembershipOfferActionResult: Equatable {
    case completed, cancelled, waiting, nothingToRestore, unavailable, failed, offerChanged
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
    private var observedCatalogRevision: UInt64?
    private var offerLoadGeneration: UInt64 = 0

    var canRefresh: Bool { !isWorking && !isMember && (verificationRequired || isWaiting) }
    let isPreview: Bool
    private var hasLoaded = false
    private let loadAction: () async -> MembershipOfferPresentation?
    private let prepareOfferAction: () async -> Void
    private let purchaseAction: (MembershipOfferPresentation) async -> MembershipOfferActionResult
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
        prepareOffer: @escaping () async -> Void = {},
        purchase: @escaping (MembershipOfferPresentation) async -> MembershipOfferActionResult,
        restore: @escaping () async -> MembershipOfferActionResult
    ) {
        self.isPreview = isPreview
        loadAction = load
        prepareOfferAction = prepareOffer
        purchaseAction = purchase
        restoreAction = restore
    }

    deinit { expiryTask?.cancel() }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isWorking = true
        await prepareOfferAction()
        await reloadOfferPresentation()
        isWorking = false
        updateMembershipState()
        if offer == nil && !isMember { message = "料金を確認できません。時間をおいて開き直してください。" }
    }

    func purchase() async -> MembershipOfferActionResult {
        guard canPurchase, let presentedOffer = offer else { return .unavailable }
        isWorking = true
        defer { isWorking = false }
        let result = await purchaseAction(presentedOffer)
        await reloadOfferPresentation()
        if result == .completed, fixtureStatus != nil { fixtureStatus = .active }
        apply(result, restoring: false)
        updateMembershipState()
        if result == .offerChanged { apply(result, restoring: false) }
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
            message = "Appleでの購入手続きが終わるのを待っています。もう一度購入せずに、しばらくしてから「購入を復元」を押してください。"
        case .nothingToRestore:
            message = "Plusの購入が見つかりませんでした。購入したときと同じApple Accountでサインインしているか確かめてください。"
        case .unavailable:
            message = "いまは購入できません。写真やメモはそのままです。"
        case .failed:
            message = restoring
                ? "購入を確認できませんでした。写真やメモはそのままです。"
                : "購入できたか確認できませんでした。「購入を復元」で確かめられます。"
        case .offerChanged:
            message = "料金か無料期間が変わりました。表示を確かめてから、もう一度お申し込みください。"
        }
    }

    static func live() -> MembershipOfferModel {
        let store = PlusPurchaseStore.productionShared
        let client = MembershipStoreKitClient(purchases: store)
        let model = MembershipOfferModel(
            isPreview: false,
            load: { await client.load() },
            prepareOffer: { await store.refreshProductsForOffer() },
            purchase: { await client.purchase(presentedOffer: $0) },
            restore: { await client.restore() }
        )
        model.purchases = store
        model.observation = store.objectWillChange.sink { [weak model] _ in
            // @Published sends before its new value is installed.
            Task { @MainActor in
                guard let model else { return }
                model.updateMembershipState()
                if model.observedCatalogRevision != store.productCatalogRevision {
                    model.observedCatalogRevision = store.productCatalogRevision
                    await model.reloadOfferPresentation()
                }
            }
        }
        model.updateMembershipState()
        return model
    }

    /// Reject an earlier eligibility/price lookup completing after a newer one.
    /// Invalidating the offer also prevents taps from using its old price.
    private func reloadOfferPresentation() async {
        offerLoadGeneration &+= 1
        let generation = offerLoadGeneration
        offer = nil
        let updated = await loadAction()
        guard generation == offerLoadGeneration else { return }
        offer = updated
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

    /// Closing Apple's management sheet is not evidence of cancellation or expiry.
    /// Reconcile the shared authority even for a currently active member, without
    /// purchasing, invoking AppStore.sync, or changing preview entitlements.
    func refreshAfterSubscriptionManagement() async {
        guard !isPreview, !isWorking, let purchases else { return }
        isWorking = true
        await purchases.refreshAfterForegroundEntry()
        updateMembershipState()
        isWorking = false
    }

    private func updateMembershipState() {
        expiryTask?.cancel()
        if let purchases {
            isMember = purchases.entitlementState.permitsPersonalPlus
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
            purchaseTitle = "Plusを利用中です"
            message = nil
        } else if isWaiting {
            purchaseTitle = "購入の確認待ちです"
            message = purchases?.pendingProductID != nil || fixtureStatus == .applePending
                ? "Appleでの購入手続きが終わるのを待っています。もう一度購入しないでください。"
                : "購入の確認を待っています。もう一度購入せずに、「購入状況を再確認」を押してください。"
        } else if verificationRequired {
            purchaseTitle = "購入状況の確認が必要です"
            message = "購入状況を確認できません。もう一度購入せずに、「購入状況を再確認」を押してください。"
        } else {
            purchaseTitle = nil
            message = nil
        }
    }

    static func preview(state: MembershipOfferFixtureStatus, expiresAfter: TimeInterval? = nil) -> MembershipOfferModel {
        let model = preview(eligibleForIntroOffer: false)
        model.fixtureStatus = state
        if state == .active, let expiresAfter {
            model.fixtureExpiresAt = .now.addingTimeInterval(expiresAfter)
        }
        model.updateMembershipState()
        return model
    }

    /// The preview has no StoreKit/session/Keychain dependency. Its results
    /// only dismiss the preview and can never change purchase authority.
    /// The sample price and trial stand in for StoreKit's `displayPrice` and
    /// introductory offer, formatted by the same function as the live offer.
    static func preview(
        purchaseResult: MembershipOfferActionResult = .completed,
        restoreResult: MembershipOfferActionResult = .completed,
        eligibleForIntroOffer: Bool = true
    ) -> MembershipOfferModel {
        MembershipOfferModel(
            isPreview: true,
            load: {
                MembershipOfferPresentation.monthly(
                    displayPrice: "¥980",
                    trialPeriod: eligibleForIntroOffer ? "14日間" : nil,
                    isPreview: true
                )
            },
            purchase: { _ in purchaseResult },
            restore: { restoreResult }
        )
    }

#if DEBUG
    /// Deterministic rendering regression for a quote changing between display
    /// and an explicit tap. No StoreKit, identity, or network is involved.
    static func catalogRefreshPreview() -> MembershipOfferModel {
        var hasRefreshed = false
        return MembershipOfferModel(
            isPreview: true,
            load: {
                MembershipOfferPresentation.monthly(
                    displayPrice: hasRefreshed ? "¥980" : "$5.99",
                    trialPeriod: hasRefreshed ? "1週間" : nil,
                    isPreview: true
                )
            },
            purchase: { _ in
                if !hasRefreshed { hasRefreshed = true; return .offerChanged }
                return .completed
            },
            restore: { .nothingToRestore }
        )
    }

    static func verifyOutOfOrderOfferLoads() async -> Bool {
        var pending: [CheckedContinuation<MembershipOfferPresentation?, Never>] = []
        let model = MembershipOfferModel(isPreview: true,
            load: { await withCheckedContinuation { pending.append($0) } },
            purchase: { _ in .unavailable }, restore: { .unavailable })
        let old = Task { await model.reloadOfferPresentation() }
        while pending.count < 1 { await Task.yield() }
        let current = Task { await model.reloadOfferPresentation() }
        while pending.count < 2 { await Task.yield() }
        let latest = MembershipOfferPresentation.monthly(displayPrice: "¥980", trialPeriod: "1週間", isPreview: true)
        pending[1].resume(returning: latest)
        await current.value
        pending[0].resume(returning: MembershipOfferPresentation.monthly(
            displayPrice: "$5.99", trialPeriod: nil, isPreview: true))
        await old.value
        guard model.offer == latest else { return false }
        let failed = Task { await model.reloadOfferPresentation() }
        while pending.count < 3 { await Task.yield() }
        guard model.offer == nil, !model.canPurchase else {
            pending[2].resume(returning: nil)
            await failed.value
            return false
        }
        pending[2].resume(returning: nil)
        await failed.value
        return model.offer == nil && !model.canPurchase
    }
#endif
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
        let revision = purchases.productCatalogRevision
        guard purchases.productAvailability == .available else { return nil }
        guard let product = purchases.products.first(where: {
            $0.id == configuration.monthlyProductID
        }), let subscription = product.subscription,
           subscription.subscriptionPeriod.unit == .month,
           subscription.subscriptionPeriod.value == 1 else { return nil }

        // Eligibility (one introductory offer per Apple ID) and the trial
        // length both come from StoreKit. No local day count exists.
        var trialPeriod: String?
        if await subscription.isEligibleForIntroOffer,
           let introductory = subscription.introductoryOffer,
           introductory.paymentMode == .freeTrial,
           let period = Self.periodText(introductory.period, count: introductory.periodCount) {
            trialPeriod = period
        }
        guard purchases.productCatalogRevision == revision,
              purchases.productAvailability == .available else { return nil }
        return MembershipOfferPresentation.monthly(
            displayPrice: product.displayPrice, trialPeriod: trialPeriod, isPreview: false)
    }

    func purchase(presentedOffer: MembershipOfferPresentation) async -> MembershipOfferActionResult {
        guard configuration.isConfigured, let session else { return .unavailable }
        // Re-evaluate eligibility immediately before the explicit purchase;
        // an old offer must not turn a later unknown state into a new purchase.
        await purchases.refreshAfterForegroundEntry()
        if purchases.entitlementState.grantsPlus { return .completed }
        guard purchases.canStartNewPurchase, purchases.pendingProductID == nil,
              !purchases.awaitingServerConfirmation else { return .unavailable }
        guard let currentOffer = await load() else { return .unavailable }
        guard currentOffer == presentedOffer else { return .offerChanged }
        let catalogRevision = purchases.productCatalogRevision
        do {
            let account = try await session.prepareAccountForExplicitPurchase()
            switch await purchases.purchase(.monthly, billingAccountID: account,
                                            expectedCatalogRevision: catalogRevision) {
            case .purchased: return .completed
            case .cancelled: return .cancelled
            case .pending, .awaitingServerConfirmation: return .waiting
            case .unavailable: return .unavailable
            case .verificationFailed, .failed: return .failed
            }
        } catch BillingClientError.billingAccountRecoveryRequired {
            purchases.requirePurchaseVerification()
            return .waiting
        } catch {
            purchases.requirePurchaseVerification()
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
/// The one Plus screen. Every entry passes its `PlusOfferContext`; the only
/// difference between entries is the one-line reason above the heading.
/// A completed purchase or restore closes the sheet at once, without a
/// completion page, so the caller's screen continues where it was.
struct MembershipOfferSheet: View {
    @StateObject private var model: MembershipOfferModel
    @State private var showsSubscriptionManagement = false
    @State private var showsManagementPreview = false
    let context: PlusOfferContext
    let photo: UIImage?
    let onFinish: (MembershipOfferActionResult) -> Void

    init(model: MembershipOfferModel, context: PlusOfferContext, photo: UIImage? = nil,
         onFinish: @escaping (MembershipOfferActionResult) -> Void) {
        _model = StateObject(wrappedValue: model)
        self.context = context
        self.photo = photo
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            MembershipOfferView(
                context: context,
                photo: photo, offer: model.offer, isWorking: model.isWorking,
                canPurchase: model.canPurchase, canRestore: model.canRestore,
                message: model.message,
                isMember: model.isMember, purchaseTitle: model.purchaseTitle,
                canRefresh: model.canRefresh,
                onRefresh: { Task { await model.refresh() } },
                onManageSubscription: {
                    if model.isPreview {
                        showsManagementPreview = true
                    } else {
                        showsSubscriptionManagement = true
                    }
                },
                onPurchase: {
                    Task {
                        let result = await model.purchase()
                        // No completion page: a purchase closes the sheet and the
                        // caller re-reads membership through its dismissal.
                        if result == .completed || (model.isPreview && result == .cancelled) { onFinish(result) }
                    }
                },
                onRestore: {
                    Task {
                        let result = await model.restore()
                        if result == .completed { onFinish(result) }
                    }
                },
                onClose: { onFinish(model.isMember ? .completed : .cancelled) }
            )
        }
        .interactiveDismissDisabled(model.isWorking)
        .manageSubscriptionsSheet(isPresented: $showsSubscriptionManagement)
        .onChange(of: showsSubscriptionManagement) { _, isPresented in
            if !isPresented {
                Task { await model.refreshAfterSubscriptionManagement() }
            }
        }
        .alert("契約管理の操作確認", isPresented: $showsManagementPreview) {
            Button("閉じる", role: .cancel) { }
        } message: {
            Text("このプレビューではAppleの契約画面を開きません。契約や会員状態は変更していません。")
        }
        .task { await model.load() }
    }
}

/// Shown in place of a Plus feature at one of the entry places. A confirmed
/// "not a member" opens the one Plus screen directly (once per appearance);
/// closing it leaves this short line with the place's own button. An unknown
/// state never offers a purchase: it shows the restore-only notice instead.
@MainActor
struct PlusOfferPrompt: View {
    let context: PlusOfferContext
    let decision: MembershipAccessDecision
    var presentsImmediately = true
    @State private var showsOffer = false
    @State private var didPresent = false

    var body: some View {
        if decision == .membershipRequired {
            VStack(spacing: 14) {
                if let reason = context.reason {
                    Text(reason)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(context.entryTitle) { showsOffer = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("plus-offer-entry-\(context.identifier)")
            }
            .multilineTextAlignment(.center).padding(24)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("plus-offer-prompt")
            .onAppear {
                guard presentsImmediately, !didPresent else { return }
                didPresent = true
                showsOffer = true
            }
            .sheet(isPresented: $showsOffer, onDismiss: {
                NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
            }) {
                MembershipOfferSheet(model: .live(), context: context) { _ in showsOffer = false }
            }
        } else {
            MembershipAccessNotice(decision: decision)
        }
    }
}

/// The Plus row in Settings: "Plusについて" before joining, "Plus利用中" with
/// Apple's subscription management after, and a recheck when the purchase
/// state cannot be confirmed. "購入を復元" stays inside this section.
/// Hidden entirely (by the caller) while the product is not configured.
@MainActor
struct PlusSettingsSection: View {
    @ObservedObject private var purchases = PlusPurchaseStore.productionShared
    @State private var showsOffer = false
    @State private var showsRestore = false
    @State private var showsManagement = false
    @State private var isRechecking = false
    @State private var purchasedJustNow = false
    @State private var offersAutoSave = false
    @State private var showsAutoSave = false

    private enum Status { case notMember, member, unknown }

    private var status: Status {
        if purchases.entitlementState.permitsPersonalPlus { return .member }
        if case .indeterminate = purchases.entitlementState { return .unknown }
        if purchases.pendingProductID != nil || purchases.awaitingServerConfirmation { return .unknown }
        return .notMember
    }

    var body: some View {
        Section {
            switch status {
            case .notMember:
                Button {
                    showsOffer = true
                } label: {
                    Label(PlusOfferContext.settings.entryTitle, systemImage: "sparkles")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("settings-membership-offer")
            case .member:
                SettingsActionRow("サブスクリプションを管理", systemImage: "checkmark.seal") { showsManagement = true }
                    .accessibilityIdentifier("settings-membership-manage")
            case .unknown:
                SettingsActionRow(isRechecking ? "確認しています…" : "購入状況を再確認",
                                  systemImage: "exclamationmark.arrow.circlepath") {
                    isRechecking = true
                    Task {
                        await purchases.refreshAfterForegroundEntry()
                        isRechecking = false
                    }
                }
                .disabled(isRechecking)
                .accessibilityIdentifier("settings-membership-recheck")
            }
            if status != .member {
                Button("購入を復元") { showsRestore = true }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("settings-membership-restore")
            }
        } header: {
            // Presenters live on the header, which stays while the rows switch
            // between states (a list Section would copy them onto every row).
            Text(status == .member ? "Plus（利用中）" : status == .unknown ? "Plus（購入状況を確認できません）" : "Plus")
                .accessibilityIdentifier(status == .member ? "settings-membership-active"
                                         : status == .unknown ? "settings-membership-unknown" : "settings-membership-header")
                .sheet(isPresented: $showsOffer, onDismiss: {
                    refreshMembership()
                    // Saving is what Plus pays for: ask once, right after buying.
                    if purchasedJustNow, ManagedPreservationConfiguration.current.isEnabled,
                       !AppRecordPersistence.shared.enabled { offersAutoSave = true }
                    purchasedJustNow = false
                }) {
                    MembershipOfferSheet(model: .live(), context: .settings) { result in
                        purchasedJustNow = result == .completed
                        showsOffer = false
                    }
                }
                .alert("自動保存も始めますか？", isPresented: $offersAutoSave) {
                    Button("保存を始める") { showsAutoSave = true }
                    Button("あとで", role: .cancel) { }
                } message: {
                    Text("猫のこと、メモ、ツールに書いたことを自動で保存して、新しいiPhoneでも戻せます。")
                }
                .sheet(isPresented: $showsAutoSave) {
                    NavigationStack {
                        AppRecordSettingsView()
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showsAutoSave = false } }
                            }
                    }
                }
                .sheet(isPresented: $showsRestore, onDismiss: refreshMembership) {
                    MembershipRestoreSheet()
                }
                .manageSubscriptionsSheet(isPresented: $showsManagement)
                .onChange(of: showsManagement) { _, isPresented in
                    // Closing Apple's sheet is not evidence of a cancellation.
                    if !isPresented { refreshMembership() }
                }
        }
    }

    private func refreshMembership() {
        NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
    }
}

/// Read-only, no-charge entry. This flag never grants purchase authority.
enum MembershipOfferPreviewAvailability {
    static var isAvailable: Bool {
        InternalBuildPresentationAvailability.isAvailable
    }
}

@MainActor
struct MembershipOfferPreviewView: View {
    @State private var offerContext: PlusOfferContext?
    @State private var resultText: String?
    var purchaseResult: MembershipOfferActionResult = .completed
    var membershipState: MembershipOfferFixtureStatus?
    var expiresAfter: TimeInterval?

    var body: some View {
        List {
            Section {
                Button("Plusの画面を開く") { offerContext = .settings }
                    .accessibilityIdentifier("membership-preview-open")
            } footer: {
                Text("操作の確認用です。申し込み・請求・現在の機能の制限は行いません。")
            }
            Section("入口ごとの確認") {
                ForEach(Self.entryContexts, id: \.identifier) { context in
                    Button(context.entryTitle) { offerContext = context }
                        .accessibilityIdentifier("membership-preview-open-\(context.identifier)")
                }
            }
            if let resultText {
                Text(resultText).accessibilityIdentifier("membership-preview-result")
            }

        }
        .navigationTitle("Plusの画面の確認")
        .sheet(isPresented: Binding(get: { offerContext != nil },
                                    set: { if !$0 { offerContext = nil } })) {
            if let offerContext {
                MembershipOfferSheet(model: previewModel, context: offerContext) { result in
                    self.offerContext = nil
                    resultText = result == .completed
                        ? "確認を終えて、元の画面に戻りました。契約は変更していません。"
                        : "取り消して、元の画面に戻りました。"
                }
            }
        }
    }

    /// Every case, so a fixture run shows each entry opens the same screen.
    static let entryContexts: [PlusOfferContext] = [
        .onboarding, .widgetResume, .monthlySummary(month: 10), .newMemo,
        .createWindow, .continueWindow, .continueFamily, .preservation, .settings,
    ]

    private var previewModel: MembershipOfferModel {
#if DEBUG
        if CommandLine.arguments.contains("--membership-catalog-refresh") { return .catalogRefreshPreview() }
#endif
        return membershipState.map { .preview(state: $0, expiresAfter: expiresAfter) }
            ?? .preview(purchaseResult: purchaseResult,
                        eligibleForIntroOffer: !CommandLine.arguments.contains("--membership-offer-no-trial"))
    }
}

enum BillingSandboxOwnerEnrollmentAvailability {
    static var isAvailable: Bool {
        let preservation = ManagedPreservationConfiguration.current
        return InternalBuildPresentationAvailability.isAvailable
            && Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
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
    @State private var catalogBoundaryResult = "未確認"
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
        .task {
            if CommandLine.arguments.contains("--membership-catalog-refresh") {
                catalogBoundaryResult = await MembershipOfferModel.verifyOutOfOrderOfferLoads() ? "境界確認OK" : "境界確認失敗"
            }
        }
        .safeAreaInset(edge: .bottom) {
            if CommandLine.arguments.contains("--membership-catalog-refresh") {
                Text(catalogBoundaryResult).accessibilityIdentifier("membership-catalog-boundary")
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
