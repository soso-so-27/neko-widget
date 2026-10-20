import Foundation
import SwiftUI

/// Info.plist `TrialUnlockEnabled`（xcconfig `TRIAL_UNLOCK_ENABLED`）。
/// NO のときはアプリ側の14日開放をしない（審査で「体験は IAP で」と指摘された場合に、
/// App Store のお試しオファー方式へ切り替えるためのフラグ。ADR-027 決定1）。
enum TrialUnlockConfiguration {
    static var isEnabled: Bool {
        MembershipAccessFlag.isOn(Bundle.main.object(forInfoDictionaryKey: "TrialUnlockEnabled"))
    }
}

/// 画面に出す体験の情報。「あと○日」は設定の会員プラン欄だけ、14日目の1行は
/// ホーム画面に1回だけ。通知・全画面・カウントダウンは出さない。
struct MembershipTrialPresentation: Equatable {
    /// 体験中の残り日数（切り上げ）。体験中でなければ nil。
    var remainingDays: Int?
    var showsDay14Notice: Bool

    static let hidden = MembershipTrialPresentation(remainingDays: nil, showsDay14Notice: false)
}

extension Notification.Name {
    /// ホーム画面が14日目の1行を表示したときに送る。`MembershipAuthority` が記録する。
    static let membershipTrialDay14NoticeShown = Notification.Name("membershipTrialDay14NoticeShown")
}

private struct MembershipTrialEnvironmentKey: EnvironmentKey {
    static let defaultValue = MembershipTrialPresentation.hidden
}

extension EnvironmentValues {
    var membershipTrial: MembershipTrialPresentation {
        get { self[MembershipTrialEnvironmentKey.self] }
        set { self[MembershipTrialEnvironmentKey.self] = newValue }
    }
}

/// `PlusPurchaseStore`（Plus）と `TrialPeriodStore`（14日体験）を束ねる1つの権限。
/// `membershipActions`・環境値 `membershipAccess`・Widget スナップショットの3つを
/// ここだけが更新し、`ProductionAppRootView` はこの1つだけを参照する（実装計画 1-4）。
///
/// 体験中は `personal = .verified(validUntil: 体験終了)` を出すので、ウィジェットの
/// 新しい1枚・月のまとめ・新しいメモに加えて、**まどを作る・作ったまどを続ける**
/// （追加決定 2026-10-20昼：まどは作った人が Plus で続ける。入る人はずっと無料）も
/// 体験の対象になる。体験後にそれらを会員に求める Policy の判定は #416 の続きで入る。
@MainActor
final class MembershipAuthority: ObservableObject {
    static let productionShared = MembershipAuthority(
        plus: .productionShared,
        trial: .productionShared,
        trialUnlockEnabled: MembershipAccessContext.enforcementConfigured
            && TrialUnlockConfiguration.isEnabled
    )

    let plus: PlusPurchaseStore
    let trial: TrialPeriodStore
    /// 会員制限が有効で、かつアプリ側の開放を使うときだけ true。false のときは
    /// 体験の記録を始めず、画面にも何も出さない。
    let trialUnlockEnabled: Bool
    /// 同期的に更新する。View の寿命に依存しない。
    let membershipActions: MembershipActionAccess
    @Published private(set) var access: MembershipAccessContext
    @Published private(set) var trialPresentation: MembershipTrialPresentation = .hidden

    init(plus: PlusPurchaseStore, trial: TrialPeriodStore, trialUnlockEnabled: Bool) {
        self.plus = plus
        self.trial = trial
        self.trialUnlockEnabled = trialUnlockEnabled
        // 記録がなければここで体験が始まる（画面は出さない）。最初の判定から体験を含める。
        if trialUnlockEnabled { trial.refresh() }
        let initial = Self.resolve(
            entitlement: plus.entitlementState,
            trial: trialUnlockEnabled ? trial.state : .notStarted,
            now: .now
        )
        access = initial
        membershipActions = MembershipActionAccess(
            enforcementEnabled: initial.enforcementEnabled, personal: initial.personal)
        plus.entitlementStateDidChange = { [weak self] state in
            self?.recompute(entitlement: state)
        }
        refreshPresentation()
    }

    static func resolve(
        entitlement: PlusEntitlementState, trial: TrialState, now: Date
    ) -> MembershipAccessContext {
        var context = MembershipAccessContext(entitlement: entitlement, now: now)
        var plusIsDisabled = false
        if case .disabled = entitlement { plusIsDisabled = true }
        context.personal = TrialMembershipMerge.personalState(
            plus: context.personal, plusIsDisabled: plusIsDisabled, trial: trial)
        return context
    }

    private var trialState: TrialState {
        trialUnlockEnabled ? trial.state : .notStarted
    }

    /// 起動時。`PlusPurchaseStore.start()` と同じく画面は出さない。
    func start() async {
        refreshTrial()
        await plus.start()
        recompute()
    }

    func refreshAfterForegroundEntry() async {
        refreshTrial()
        await plus.refreshAfterForegroundEntry()
        recompute()
    }

    /// 期限を過ぎたときなど、同じ状態を今の時刻で判定し直す。
    func refresh(now: Date = .now) {
        recompute(now: now)
    }

    func publishWidgetSnapshot() {
        try? PersonalWidgetMembershipStore.publish(access.personal)
    }

    func markDay14NoticeShown() {
        guard trialUnlockEnabled else { return }
        trial.markDay14NoticeShown()
        refreshPresentation()
    }

    /// 次に判定が変わる時刻（Plus の期限と体験の終了の早いほう）。
    var nextBoundary: Date? {
        var candidates: [Date] = []
        if let expiration = plus.entitlementState.lastServerConfirmed?.expirationDate {
            candidates.append(expiration)
        }
        if case let .active(until) = trialState { candidates.append(until) }
        return candidates.min()
    }

    private func refreshTrial() {
        guard trialUnlockEnabled else { return }
        trial.refresh()
        recompute()
    }

    private func recompute(entitlement: PlusEntitlementState? = nil, now: Date = .now) {
        let resolved = Self.resolve(
            entitlement: entitlement ?? plus.entitlementState, trial: trialState, now: now)
        membershipActions.update(
            enforcementEnabled: resolved.enforcementEnabled, personal: resolved.personal)
        if resolved != access { access = resolved }
        refreshPresentation()
    }

    private func refreshPresentation() {
        let next: MembershipTrialPresentation
        if trialUnlockEnabled {
            next = MembershipTrialPresentation(
                remainingDays: trial.remainingDays,
                showsDay14Notice: trial.shouldShowDay14Notice)
        } else {
            next = .hidden
        }
        if next != trialPresentation { trialPresentation = next }
    }
}
