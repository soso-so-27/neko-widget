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
    /// The first Plus offer (11/10): once, on a later opening after the
    /// Widget was placed (FirstPlusOfferPolicy), or a resumed first-run page.
    case onboarding
    /// The app was opened from a personal Widget that kept its last photo.
    case widgetResume
    /// A monthly summary (1...12) or a seasonal movie (`nil`).
    case monthlySummary(month: Int?)
    case newMemo
    case createWindow
    /// The person who made a window opened it after it stopped.
    case continueWindow
    /// 「家族の手帳を作る」 without Plus: the one who makes the family pays (11/7).
    case createFamily
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
        case let .monthlySummary(month?) where (1...12).contains(month): "\(month)月の作品を見る"
        case .monthlySummary: "作品とムービーを見る"
        case .newMemo: "メモを書く"
        case .createWindow: "まどを作る"
        case .continueWindow: "このまどを続ける"
        case .createFamily: "家族の手帳を作る"
        case .continueFamily: "家族の手帳を続ける"
        case .preservation: "保存を始める"
        case .settings: "Plusについて"
        }
    }

    /// One line above the heading saying why the screen appeared here.
    var reason: String? {
        switch self {
        // 11/10: the free Widget keeps its one photo; Plus makes it new daily.
        case .onboarding: "ホーム画面の1枚は無料です。毎日新しくなるのはPlusです。"
        case .settings: nil
        case .widgetResume: "ホーム画面の写真を毎日新しくするのは、Plusの機能です。"
        case .monthlySummary: "月の作品と季節のムービーは、Plusで見られます。"
        case .newMemo: "メモを書くのはPlusの機能です。"
        case .createWindow: "まどを作るのは、Plusの機能です。"
        case .continueWindow: "このまどは、作った人のPlusで続きます。"
        case .createFamily: "家族の手帳を作るのは、Plusの機能です。"
        case .continueFamily: "家族の手帳は、家族の誰か1人のPlusで続きます。"
        case .preservation: "写真やメモの保存は、Plusの機能です。"
        }
    }

    /// The reason on the Plus screen, where StoreKit's offer is known: a new
    /// memo also says the free days, only when this person can have them (11/10).
    func reason(trialPeriod: String?) -> String? {
        guard case .newMemo = self, let trialPeriod, let base = reason else { return reason }
        return base + "\(trialPeriod)は無料です。"
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
        case .createFamily: "create-family"
        case .continueFamily: "continue-family"
        case .preservation: "preservation"
        case .settings: "settings"
        }
    }
}

/// The cat photo at the top of the Plus screen: the place that opens the
/// sheet names one of the person's own cat photos. Nothing is loaded until
/// the screen shows; without one, the screen keeps its cat symbol.
struct PlusOfferPhoto: Equatable, Sendable {
    let localIdentifier: String
    let catBoundingBox: CGRect?
}

private struct PlusOfferPhotoKey: EnvironmentKey {
    static var defaultValue: PlusOfferPhoto? { nil }
}

extension EnvironmentValues {
    var plusOfferPhoto: PlusOfferPhoto? {
        get { self[PlusOfferPhotoKey.self] }
        set { self[PlusOfferPhotoKey.self] = newValue }
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
    /// "その後 月額¥980（自動更新）" under the trial button; `nil` without a trial.
    let afterTrialText: String?
    let isPreview: Bool
    /// StoreKit's trial length as given ("14日間"); `nil` without a trial.
    var trialPeriod: String? = nil

    /// The button without a trial: the price is said once, under it (11/10).
    static let startTitle = "Plusを始める"

    /// The headline under the button: what is billed and that it renews, as
    /// prominent as the trial (guideline 3.1.2).
    var billingLine: String { afterTrialText ?? "\(priceText)（自動更新）" }

    /// One formatting path for the live offer and its previews.
    /// `displayPrice` and `trialPeriod` are StoreKit's values as given.
    static func monthly(displayPrice: String, trialPeriod: String?, isPreview: Bool) -> Self {
        let price = "月額\(displayPrice)"
        guard let trialPeriod else {
            return Self(priceText: price, renewalText: "1か月ごとに自動で更新されます。次の更新日の24時間前までに解約すれば、次の料金はかかりません。",
                        trialText: nil, purchaseTitle: startTitle,
                        afterTrialText: nil, isPreview: isPreview)
        }
        return Self(priceText: price,
                    renewalText: "無料期間が終わると、1か月ごとに自動で更新されます。無料期間が終わる24時間前までに解約すれば、料金はかかりません。",
                    trialText: "\(trialPeriod)無料", purchaseTitle: "\(trialPeriod)無料で試す",
                    afterTrialText: "その後 \(price)（自動更新）", isPreview: isPreview,
                    trialPeriod: trialPeriod)
    }
}

enum MembershipRestoreFailure: Equatable {
    case appleConfirmation, purchaseEvidence, localRegistration, connection, server, unknown

    static func recovering(_ error: Error) -> Self {
        guard let error = error as? BillingClientError else { return .unknown }
        switch error {
        case .billingAccountRecoveryUnavailable, .billingAccountRecoveryEvidenceChanged, .identityMismatch:
            return .purchaseEvidence
        case .protectedDataUnavailable, .keychainUnavailable, .localStateUnavailable,
             .malformedCredential, .billingCredentialMissing, .installationChanged, .credentialChanged:
            return .localRegistration
        case .transportUnavailable: return .connection
        case .requestRejected: return .server
        default: return .unknown
        }
    }

    var message: String {
        let reason: String
        switch self {
        case .connection: reason = "通信できませんでした。"
        case .appleConfirmation, .purchaseEvidence, .localRegistration, .server, .unknown:
            reason = "購入を確かめられませんでした。"
        }
        return reason + "もう一度購入せず、時間をおいて「購入を復元」をお試しください。"
    }
}

enum MembershipOfferActionResult: Equatable {
    case completed, cancelled, waiting, nothingToRestore, unavailable, failed, offerChanged
    case restoreFailed(MembershipRestoreFailure)
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
    /// 「11月9日まで使えます」 when a member's Plus will not renew (11/9); nil while it renews.
    @Published private(set) var memberEndLine: String?
    private var purchases: PlusPurchaseStore?
    private var observation: AnyCancellable?
    private var expiryTask: Task<Void, Never>?
    /// The result of the person's last purchase or restore tap (not found,
    /// unavailable, failed, a changed offer). Kept on screen until the next
    /// tap or a confirmed membership, as the restore failure (#786, 11/5).
    private var actionResult: String?
#if DEBUG || INTERNAL_PRESENTATION
    private var fixtureStatus: MembershipOfferFixtureStatus?
    private var fixtureExpiresAt: Date?
    private var fixtureAllowsPurchase = true
#endif
    private var observedCatalogRevision: UInt64?
    private var offerLoadGeneration: UInt64 = 0
    /// The price on screen. `offer` (what a tap may buy) is cleared during each
    /// reload; this keeps the last price instead, so a store refresh does not
    /// blink the price, the button and the unavailable line (11/10).
    @Published private(set) var displayedOffer: MembershipOfferPresentation?
    /// A settled load found no product at all; only then 「料金を確認できません…」.
    private var offerLoadFinishedWithoutOffer = false
    /// One offer read per catalog revision, shared by whoever asks (coalesced).
    private var offerReloadTask: Task<Void, Never>?

    var canRefresh: Bool { !isWorking && !isMember && (verificationRequired || isWaiting) }
    let isPreview: Bool
    private let presentsOffer: Bool
    private var hasLoaded = false
    private let loadAction: () async -> MembershipOfferPresentation?
    private let prepareOfferAction: () async -> Void
    private let purchaseAction: (MembershipOfferPresentation) async -> MembershipOfferActionResult
    private let restoreAction: () async -> MembershipOfferActionResult

    var canPurchase: Bool {
        offer != nil && !isWorking && !isWaiting && !isMember
            && !verificationRequired && (purchases?.canStartNewPurchase ?? permitsPreviewPurchase)
            && !(purchases?.isPurchasing ?? false) && !(purchases?.isRestoring ?? false)
    }
    private var permitsPreviewPurchase: Bool {
#if DEBUG || INTERNAL_PRESENTATION
        fixtureAllowsPurchase
#else
        false
#endif
    }

    var canRestore: Bool { !isWorking && !(purchases?.isPurchasing ?? false) && !(purchases?.isRestoring ?? false) }

    private init(
        isPreview: Bool,
        presentsOffer: Bool = true,
        load: @escaping () async -> MembershipOfferPresentation?,
        prepareOffer: @escaping () async -> Void = {},
        purchase: @escaping (MembershipOfferPresentation) async -> MembershipOfferActionResult,
        restore: @escaping () async -> MembershipOfferActionResult
    ) {
        self.isPreview = isPreview
        self.presentsOffer = presentsOffer
        loadAction = load
        prepareOfferAction = prepareOffer
        purchaseAction = purchase
        restoreAction = restore
    }

    deinit { expiryTask?.cancel() }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        // Restoring an existing purchase does not need a product quote. The
        // dedicated restore sheet has no price field or purchase action.
        guard presentsOffer else {
            updateMembershipState()
            isWorking = false
            return
        }
        isWorking = true
        await prepareOfferAction()
        await reloadOfferForCurrentCatalog()
        isWorking = false
        updateMembershipState()
        applyOfferUnavailableMessage()
    }

    func purchase() async -> MembershipOfferActionResult {
        guard canPurchase, let presentedOffer = offer else { return .unavailable }
        actionResult = nil
        isWorking = true
        defer { isWorking = false }
        let result = await purchaseAction(presentedOffer)
        await reloadOfferPresentation()
#if DEBUG || INTERNAL_PRESENTATION
        if result == .completed, fixtureStatus != nil { fixtureStatus = .active }
#endif
        apply(result, restoring: false)
        updateMembershipState()
        if result == .offerChanged { apply(result, restoring: false) }
        return result
    }

    /// The one 「購入を復元」 (11/5): the purchase re-check first, then the
    /// App Store restore. A member the re-check confirms needs no Apple sign-in.
    func restore() async -> MembershipOfferActionResult {
        guard canRestore else { return .unavailable }
        actionResult = nil
        isWorking = true
        defer { isWorking = false }
        if await recheckConfirmsMembership() {
            apply(.completed, restoring: true)
            updateMembershipState()
            if !isPreview { UsageCounter.shared.count(.plusRestored) }  // Usage (11/7)
            return .completed
        }
        let result = await restoreAction()
#if DEBUG || INTERNAL_PRESENTATION
        if result == .completed, fixtureStatus != nil { fixtureStatus = .active }
#endif
        apply(result, restoring: true)
        updateMembershipState()
        if result == .completed, !isPreview { UsageCounter.shared.count(.plusRestored) }  // Usage (11/7)
        return result
    }

    /// The re-check half of 「購入を復元」: the shared purchase authority only,
    /// never a purchase or AppStore.sync. A preview moves its fixture as the
    /// server would.
    private func recheckConfirmsMembership() async -> Bool {
        if let purchases {
            await purchases.refreshAfterForegroundEntry()
            return purchases.entitlementState.permitsPersonalPlus
        }
#if DEBUG || INTERNAL_PRESENTATION
        if let fixtureStatus {
            switch fixtureStatus {
            case .unknown, .authorityPending:
                self.fixtureStatus = .active
                return true
            case .expired: self.fixtureStatus = .fresh
            case .fresh, .active, .applePending: break
            }
        }
#endif
        return false
    }

    /// 「購入を復元」 from a screen without the Plus sheet (saving): the same
    /// re-check and restore. Returns the result line to keep on that screen,
    /// or nil when Plus was found or there is nothing to tell.
    static func restoreForAnotherScreen() async -> String? {
        let model = live(presentsOffer: false)
        await model.load()
        switch await model.restore() {
        case .completed, .cancelled, .unavailable: return nil
        default: return model.message
        }
    }

    private func apply(_ result: MembershipOfferActionResult, restoring: Bool) {
        switch result {
        case .completed, .cancelled:
            actionResult = nil
            message = nil
            if result == .completed { isWaiting = false }
        case .waiting:
            isWaiting = true
            message = "Appleでの購入手続きが終わるのを待っています。もう一度購入せずに、しばらくしてから「購入を復元」を押してください。\nApp Store で手続きが終わると、自動で使えるようになります。"
        case .nothingToRestore:
            actionResult = "Plusの購入が見つかりませんでした。購入したときと同じApple Accountでサインインしているか確かめてください。"
        case .unavailable:
            actionResult = "いまは購入できません。写真やメモはそのままです。"
        case .failed:
            actionResult = restoring
                ? "購入を確認できませんでした。写真やメモはそのままです。"
                : "購入できたか確認できませんでした。「購入を復元」で確かめられます。"
        case .offerChanged:
            actionResult = "料金か無料期間が変わりました。表示を確かめてから、もう一度お申し込みください。"
        case let .restoreFailed(reason):
            actionResult = reason.message
        }
        if let actionResult { message = actionResult }
    }

    static func live(presentsOffer: Bool = true) -> MembershipOfferModel {
        let store = PlusPurchaseStore.productionShared
        let client = MembershipStoreKitClient(purchases: store)
        let model = MembershipOfferModel(
            isPreview: false,
            presentsOffer: presentsOffer,
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
                // Only after the screen's own load began, once per settled
                // catalog: a refresh publishes many times (11/10).
                if model.presentsOffer && model.hasLoaded {
                    await model.reloadOfferForCurrentCatalog()
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
        let revision = purchases?.productCatalogRevision
        offer = nil
        let updated = await loadAction()
        guard generation == offerLoadGeneration else { return }
        offer = updated
        // Settled: the catalog this read used is still the current one. A read
        // overtaken by a newer catalog is followed by that catalog's own read.
        let settled = purchases.map {
            $0.productAvailability != .loading && $0.productCatalogRevision == revision
        } ?? true
        displayedOffer = PlusOfferReloadPolicy.displayed(previous: displayedOffer, loaded: updated, settled: settled)
        if updated != nil || settled { offerLoadFinishedWithoutOffer = updated == nil }
        applyOfferUnavailableMessage()
    }

    /// The screen's load and every store publication share this: one read per
    /// settled catalog revision, joined while it runs, never in a loop (11/10).
    private func reloadOfferForCurrentCatalog() async {
        guard let store = purchases else {
            await reloadOfferPresentation()
            return
        }
        let revision = store.productCatalogRevision
        if observedCatalogRevision == revision, let offerReloadTask {
            await offerReloadTask.value
            return
        }
        guard PlusOfferReloadPolicy.shouldReload(observedRevision: observedCatalogRevision,
                                                 currentRevision: revision,
                                                 catalogLoading: store.productAvailability == .loading)
        else { return }
        observedCatalogRevision = revision
        let task = Task { await self.reloadOfferPresentation() }
        offerReloadTask = task
        await task.value
        if offerReloadTask == task { offerReloadTask = nil }
    }

    /// 「料金を確認できません…」 only when a finished load found no product and
    /// no price is on screen; it goes away as soon as a price loads.
    private func applyOfferUnavailableMessage() {
        let shows = PlusOfferReloadPolicy.showsUnavailable(loadFinishedWithoutOffer: offerLoadFinishedWithoutOffer,
                                                           showsPrice: displayedOffer != nil, isMember: isMember)
        if shows, actionResult == nil, purchaseTitle == nil, message == nil {
            message = PlusOfferReloadPolicy.unavailableMessage
        } else if !shows, message == PlusOfferReloadPolicy.unavailableMessage {
            message = nil
        }
    }

    func refresh() async {
        guard canRefresh else { return }
        actionResult = nil
        isWorking = true
        if let purchases {
            await purchases.refreshAfterForegroundEntry()
        } else {
#if DEBUG || INTERNAL_PRESENTATION
            if let fixtureStatus {
                switch fixtureStatus {
                case .unknown, .authorityPending: self.fixtureStatus = .active
                case .expired: self.fixtureStatus = .fresh
                case .fresh, .active, .applePending: break
                }
            }
#endif
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
        // A repeated authority publication must not erase the explicit purchase
        // or restore result. A confirmed membership or a new user action clears it.
        defer {
            if isMember { actionResult = nil }
            else if let actionResult { message = actionResult }
        }
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
        } else {
#if DEBUG || INTERNAL_PRESENTATION
            if let fixtureStatus {
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
#else
            return
#endif
        }
        let renewal = purchases?.renewal
        let endLine = isMember ? PlusRenewalPresentation.offerEndLine(willAutoRenew: renewal?.willAutoRenew,
            expiration: renewal?.expirationDate, now: .now, calendar: .nekoGregorian) : nil
        if memberEndLine != endLine { memberEndLine = endLine }
        if isMember {
            purchaseTitle = PlusRenewalPresentation.renewingOfferTitle
            message = nil
        } else if isWaiting {
            purchaseTitle = "購入の確認待ちです"
            var applePending = purchases?.pendingProductID != nil
#if DEBUG || INTERNAL_PRESENTATION
            applePending = applePending || fixtureStatus == .applePending
#endif
            message = applePending
                ? "Appleでの購入手続きが終わるのを待っています。もう一度購入しないでください。\nApp Store で手続きが終わると、自動で使えるようになります。"
                : "購入の確認を待っています。もう一度購入せずに、「購入を復元」を押してください。"
        } else if purchases?.hasBillingIssue == true {
            purchaseTitle = "お支払い方法の確認が必要です"
            message = "Appleでお支払いを確認できていません。「サブスクリプションを管理」からお支払い方法を確認してください。\nApp Store で手続きが終わると、自動で使えるようになります。"
        } else if verificationRequired {
            purchaseTitle = "購入状況の確認が必要です"
            message = "購入状況を確認できません。もう一度購入せずに、「購入を復元」を押してください。"
        } else {
            purchaseTitle = nil
            message = nil
            applyOfferUnavailableMessage()
        }
    }

#if DEBUG || INTERNAL_PRESENTATION
    /// After the re-check, the restore answers as Apple would: a pending
    /// purchase is still waiting, and an ended Plus finds nothing.
    static func preview(state: MembershipOfferFixtureStatus, expiresAfter: TimeInterval? = nil) -> MembershipOfferModel {
        let restoreResult: MembershipOfferActionResult
        if state == .applePending { restoreResult = .waiting }
        else if state == .expired || expiresAfter != nil { restoreResult = .nothingToRestore }
        else { restoreResult = .completed }
        let model = preview(restoreResult: restoreResult, eligibleForIntroOffer: false)
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

#endif
#if DEBUG
    /// The first restore fails and the next finds Plus. Apple's purchase is
    /// still pending, so the re-check cannot confirm Plus before the restore.
    static func restoreFailsOncePreview(presentsOffer: Bool) -> MembershipOfferModel {
        var attempts = 0
        let model = MembershipOfferModel(isPreview: true, presentsOffer: presentsOffer,
            load: {
                presentsOffer
                    ? MembershipOfferPresentation.monthly(displayPrice: "¥980", trialPeriod: nil, isPreview: true)
                    : nil
            },
            purchase: { _ in .unavailable },
            restore: {
                attempts += 1
                return attempts == 1 ? .restoreFailed(.appleConfirmation) : .completed
            })
        model.fixtureStatus = .applePending
        model.updateMembershipState()
        return model
    }

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

#if DEBUG || INTERNAL_PRESENTATION
enum MembershipOfferFixtureStatus: String {
    case fresh, active, applePending, authorityPending, unknown, expired
}

#endif
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
            } catch { return .restoreFailed(.recovering(error)) }
        }
        switch outcome {
        case .entitlementFound: return .completed
        case .nothingToRestore: return .nothingToRestore
        case .indeterminate: return .waiting
        case .unavailable: return .unavailable
        case .failed: return .restoreFailed(.appleConfirmation)
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

/// 「自動保存も始めますか？」 after buying Plus, from every entry (11/7: only
/// Settings asked). Saving is what Plus pays for, so it is asked once, right
/// after the purchase, unless saving is already on.
@MainActor
final class AutoSaveAfterPurchase: ObservableObject {
    static let shared = AutoSaveAfterPurchase()
    /// Bought on the first run's last page: asked once the guide has ended,
    /// not over the guide's own 「あとで」 (11/7).
    @Published var waitsForOnboardingEnd = false

    /// Not from the auto-save screens themselves: their own button is right there.
    static func applies(after context: PlusOfferContext) -> Bool {
        context != .preservation && ManagedPreservationConfiguration.current.isEnabled
            && !AppRecordPersistence.shared.enabled
    }
}

private struct AutoSaveOfferAlert: ViewModifier {
    @Binding var isPresented: Bool
    let start: () -> Void
    let later: () -> Void

    func body(content: Content) -> some View {
        content.alert("自動保存も始めますか？", isPresented: $isPresented) {
            // This tap is the start: the screen opens already starting (11/7).
            Button("保存を始める", action: start)
            Button("あとで", role: .cancel, action: later)
        } message: {
            Text("猫のこと、メモ、ツールに書いたことを自動で保存して、新しいiPhoneでも戻せます。")
        }
    }
}

/// The first run's Plus page has no sheet over it: the question comes once
/// the guide has ended and the app is showing (11/7).
@MainActor
private struct AutoSaveOfferAfterOnboarding: ViewModifier {
    let onboardingEnded: Bool
    @ObservedObject private var waiting = AutoSaveAfterPurchase.shared
    @State private var asks = false
    @State private var showsAutoSave = false

    func body(content: Content) -> some View {
        content
            .modifier(AutoSaveOfferAlert(isPresented: $asks, start: { showsAutoSave = true }, later: {}))
            .sheet(isPresented: $showsAutoSave) {
                NavigationStack {
                    AppRecordSettingsView(startsOnOpen: true)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showsAutoSave = false } }
                        }
                }
            }
            .onChange(of: onboardingEnded, initial: true) { _, _ in askIfWaiting() }
            .onChange(of: waiting.waitsForOnboardingEnd) { _, _ in askIfWaiting() }
    }

    private func askIfWaiting() {
        guard onboardingEnded, waiting.waitsForOnboardingEnd else { return }
        waiting.waitsForOnboardingEnd = false
        if AutoSaveAfterPurchase.applies(after: .onboarding) { asks = true }
    }
}

extension View {
    /// Put once at the app's root: asks 「自動保存も始めますか？」 after a
    /// purchase made on the first run's last page.
    @MainActor
    func autoSaveOfferAfterOnboarding(ended: Bool) -> some View {
        modifier(AutoSaveOfferAfterOnboarding(onboardingEnded: ended))
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
    /// Bought just now: 「自動保存も始めますか？」 is asked here, and the
    /// caller hears about the purchase once it is answered (11/7).
    @State private var asksAutoSave = false
    @State private var showsAutoSave = false
#if DEBUG || INTERNAL_PRESENTATION
    @State private var showsManagementPreview = false
#endif
    @Environment(\.plusOfferPhoto) private var placePhoto
    /// The cat photo the screen opened with, kept while it is open: a new
    /// best candidate behind the sheet must not reload the header (11/10).
    @State private var heldPhoto: PlusOfferPhoto?
    let context: PlusOfferContext
    let photo: UIImage?
    /// False only where the screen is a page with its own 「あとで」 (onboarding, 11/7).
    let showsClose: Bool
    let onFinish: (MembershipOfferActionResult) -> Void

    init(model: MembershipOfferModel, context: PlusOfferContext, photo: UIImage? = nil,
         showsClose: Bool = true,
         onFinish: @escaping (MembershipOfferActionResult) -> Void) {
        _model = StateObject(wrappedValue: model)
        self.context = context
        self.photo = photo
        self.showsClose = showsClose
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            if showsAutoSave {
                // In this sheet, not a second one over it; 「閉じる」 goes back
                // to where Plus was bought.
                AppRecordSettingsView(startsOnOpen: true)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("閉じる") { onFinish(.completed) } }
                    }
            } else {
                MembershipOfferView(
                    context: context,
                    photo: photo, photoAsset: heldPhoto ?? placePhoto, offer: model.displayedOffer,
                    isWorking: model.isWorking,
                    canPurchase: model.canPurchase, canRestore: model.canRestore,
                    message: model.message,
                    isMember: model.isMember, memberEndLine: model.memberEndLine,
                    purchaseTitle: model.purchaseTitle,
                    canRefresh: model.canRefresh,
                    onRefresh: { Task { await model.refresh() } },
                    onManageSubscription: {
    #if DEBUG || INTERNAL_PRESENTATION
                        if model.isPreview {
                            showsManagementPreview = true
                        } else {
                            showsSubscriptionManagement = true
                        }
    #else
                        showsSubscriptionManagement = true
    #endif
                    },
                    onPurchase: {
                        Task {
                            let result = await model.purchase()
                            if result == .completed, !model.isPreview { UsageCounter.shared.count(.plusPurchased(.init(context))) }  // Usage (11/7)
                            // No completion page: a purchase closes the sheet and the
                            // caller re-reads membership through its dismissal.
                            if result == .completed, !model.isPreview, AutoSaveAfterPurchase.applies(after: context) {
                                // The first run asks after its guide; every other entry asks here.
                                if context == .onboarding {
                                    AutoSaveAfterPurchase.shared.waitsForOnboardingEnd = true
                                    onFinish(result)
                                } else {
                                    asksAutoSave = true
                                }
                                return
                            }
                            if result == .completed || (model.isPreview && result == .cancelled) { onFinish(result) }
                        }
                    },
                    onRestore: {
                        Task {
                            let result = await model.restore()
                            if result == .completed { onFinish(result) }
                        }
                    },
                    onClose: { onFinish(model.isMember ? .completed : .cancelled) },
                    showsClose: showsClose
                )
            }
        }
        .modifier(AutoSaveOfferAlert(isPresented: $asksAutoSave, start: { showsAutoSave = true },
                                     later: { onFinish(.completed) }))
        // While asking, a swipe must not drop the purchase the caller waits for.
        .interactiveDismissDisabled(model.isWorking || asksAutoSave || showsAutoSave)
        // Usage (11/7): each time the one Plus screen is shown, by its entry place.
        .onAppear {
            if heldPhoto == nil { heldPhoto = placePhoto }
            if !model.isPreview { UsageCounter.shared.count(.plusOfferShown(.init(context))) }
        }
        .manageSubscriptionsSheet(isPresented: $showsSubscriptionManagement)
        .onChange(of: showsSubscriptionManagement) { _, isPresented in
            if !isPresented {
                Task { await model.refreshAfterSubscriptionManagement() }
            }
        }
#if DEBUG || INTERNAL_PRESENTATION
        .alert("契約管理の操作確認", isPresented: $showsManagementPreview) {
            Button("閉じる", role: .cancel) { }
        } message: {
            Text("このプレビューではAppleの契約画面を開きません。契約や会員状態は変更していません。")
        }
#endif
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
        // The sheet hangs on the prompt as a whole, not on one branch: buying
        // flips the state to 「確認中」 for a moment, and the sheet must not
        // close under the person mid-purchase (11/6).
        Group {
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
            // A container keeps the button's own identifier (11/8).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("plus-offer-prompt")
            .onAppear {
                guard presentsImmediately, !didPresent else { return }
                didPresent = true
                showsOffer = true
            }
        } else {
            MembershipAccessNotice(decision: decision)
        }
        }
        .sheet(isPresented: $showsOffer, onDismiss: {
            NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
        }) {
            MembershipOfferSheet(model: .live(), context: context) { _ in showsOffer = false }
        }
    }
}

/// The Plus row in Settings: "Plusについて" before joining, "Plus利用中" with
/// Apple's subscription management after, and "購入を復元" (the re-check and
/// the App Store restore in one) when the purchase state cannot be confirmed.
/// "購入を復元" stays inside this section in every state but a member's, and
/// restores right on the row (11/7: it opened a screen with the same button).
/// Hidden entirely (by the caller) while the product is not configured.
@MainActor
struct PlusSettingsSection: View {
    @ObservedObject private var purchases = PlusPurchaseStore.productionShared
    @State private var showsOffer = false
    @State private var showsManagement = false
    /// The last answer before a re-check: shown while it runs (11/10).
    @State private var lastAnswer: Status?

    private typealias Status = PlusSettingsRowStatus

    /// Each refresh (launch, foreground, a closed sheet) is `.checking` again
    /// for a moment; the rows keep the last answer so the Plus sheet hung on
    /// this section is not rebuilt, which reloaded it over and over (11/10).
    private var status: Status { Status.steady(liveStatus, lastAnswer: lastAnswer) }

    private var liveStatus: Status {
        if purchases.entitlementState.permitsPersonalPlus { return .member }
        // Just after launch: neither the offer nor restore until the answer is in (11/5).
        if purchases.entitlementState == .checking { return .checking }
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
                // One button for the re-check and the App Store restore (11/5).
                MembershipRestoreButton(look: .settingsRow, identifier: "settings-membership-restore")
            case .checking:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("確認しています…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings-membership-checking")
            }
            // Restore stays reachable while checking: a check that never ends
            // must not leave a member without a way back (App Review requires it).
            // The unknown state already shows it as its one row.
            if status == .notMember || status == .checking {
                MembershipRestoreButton(look: .footnote, identifier: "settings-membership-restore")
            }
        } header: {
            // Presenters live on the header, which stays while the rows switch
            // between states (a list Section would copy them onto every row).
            Text(status == .member ? memberHeader : status == .unknown ? "Plus（購入状況を確認できません）" : "Plus")
                .accessibilityIdentifier(status == .member ? "settings-membership-active"
                                         : status == .unknown ? "settings-membership-unknown" : "settings-membership-header")
                .sheet(isPresented: $showsOffer, onDismiss: {
                    refreshMembership()
                }) {
                    // 「自動保存も始めますか？」 is asked by the sheet itself, as from every entry (11/7).
                    MembershipOfferSheet(model: .live(), context: .settings) { _ in
                        showsOffer = false
                    }
                }
                .manageSubscriptionsSheet(isPresented: $showsManagement)
                .onChange(of: showsManagement) { _, isPresented in
                    // Closing Apple's sheet is not evidence of a cancellation.
                    if !isPresented { refreshMembership() }
                }
                .onChange(of: liveStatus, initial: true) { _, answer in
                    if answer != .checking { lastAnswer = answer }
                }
        }
    }

    /// 「Plus（11月9日まで）」 once auto-renewal is off, so a cancellation shows
    /// it worked; 「Plus（利用中）」 while it renews (11/9).
    private var memberHeader: String {
        PlusRenewalPresentation.settingsHeader(willAutoRenew: purchases.renewal?.willAutoRenew,
            expiration: purchases.renewal?.expirationDate, now: .now, calendar: .nekoGregorian)
    }

    private func refreshMembership() {
        NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
    }
}

#if DEBUG || INTERNAL_PRESENTATION
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
        }
        // Above the list, not its last row: with every entry listed (11/7: 10
        // rows) a last row is below the screen and not loaded, so the result
        // of the action just taken was not shown.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let resultText {
                Text(resultText)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(.bar)
                    .accessibilityIdentifier("membership-preview-result")
            }
        }
        .navigationTitle("Plusの画面の確認")
        .sheet(isPresented: Binding(get: { offerContext != nil },
                                    set: { if !$0 { offerContext = nil } })) {
            if let offerContext {
#if DEBUG
                if CommandLine.arguments.contains("--membership-restore-without-catalog") {
                    MembershipRestoreSheet(model: .restoreFailsOncePreview(presentsOffer: false))
                } else {
                    offerSheet(offerContext)
                }
#else
                offerSheet(offerContext)
#endif
            }
        }
    }

    private func offerSheet(_ offerContext: PlusOfferContext) -> some View {
        MembershipOfferSheet(model: previewModel, context: offerContext) { result in
            self.offerContext = nil
            resultText = result == .completed
                ? "確認を終えて、元の画面に戻りました。契約は変更していません。"
                : "取り消して、元の画面に戻りました。"
        }
    }

    /// Every case, so a fixture run shows each entry opens the same screen.
    static let entryContexts: [PlusOfferContext] = [
        .onboarding, .widgetResume, .monthlySummary(month: 10), .newMemo,
        .createWindow, .continueWindow, .createFamily, .continueFamily, .preservation, .settings,
    ]

    private var previewModel: MembershipOfferModel {
#if DEBUG
        if CommandLine.arguments.contains("--membership-restore-apple-failure") {
            return .restoreFailsOncePreview(presentsOffer: true)
        }
        if CommandLine.arguments.contains("--membership-catalog-refresh") { return .catalogRefreshPreview() }
#endif
        return membershipState.map { .preview(state: $0, expiresAfter: expiresAfter) }
            ?? .preview(purchaseResult: purchaseResult,
                        eligibleForIntroOffer: !CommandLine.arguments.contains("--membership-offer-no-trial"))
    }
}

enum BillingSandboxOwnerEnrollmentAvailability {
    static var isAvailable: Bool {
#if DEBUG || INTERNAL_PRESENTATION
        let preservation = ManagedPreservationConfiguration.current
        return InternalBuildPresentationAvailability.isAvailable
            && Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
            && (Bundle.main.object(forInfoDictionaryKey: "SharingReleaseMode") as? String) == "media-staging"
            && preservation.isEnabled
            && preservation.origin?.absoluteString
                == "https://neko-preservation-staging-disabled.nakanishisoya.workers.dev"
            && preservation.membershipAudience == "neko-preservation-staging"
#else
        return false
#endif
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

#endif
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
