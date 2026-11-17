import Foundation

@MainActor
protocol GroupRecoveryCommandHandling: AnyObject {
    func handle(_ command: GroupRecoveryCommand) async
}

// 機種変更（新しい iPhone で、同じ人として まど に戻る）の画面。
// 状態は Codex の型（GroupRecoveryRegistrationState・GroupRootMembershipSummary）
// を受け取るだけ。ここは文とボタンを決めるだけで、通信・鍵・保存はしない。
// 文はこのファイルの GroupRecoveryWords だけに置く（ci/test-group-recovery-screens.py）。
// ボタンが何を呼ぶかは ci/verify-group-recovery-presentation.swift で固定する。

/// 画面の文。状態 1 つ＋ 1 文＋ボタン。仕組みの言葉は書かない。
enum GroupRecoveryWords {
    // まどのタブの入口（一覧の上に 1 行）と、まどが複数あるときの一覧の題
    static let entry = "前の iPhone のまど"
    /// 名前を開けないまど
    static let unnamedWindow = "まど"

    static let checkingTitle = "確認しています"
    static let unavailableTitle = "つながりませんでした"
    static let retry = "もう一度"

    static let foundTitle = "前の iPhone のまどがあります"
    static let foundMessage = "この iPhone でも続けますか。"
    static let continueButton = "続ける"
    static let notNow = "今はしない"

    static let waitingTitle = "もう少しで見られます"
    static let waitingMessage = "前の iPhone でアプリを開くと、続きが届きます。"

    static let noProviderTitle = "前の写真は開けません"
    static let noProviderMessage = "新しく続けることはできます。まどの名前は付け直します。"
    static let freshContinue = "新しく続ける"
    static let freshNameHeader = "まどの名前"
    static let freshNamePlaceholder = "例：実家のまど"

    static let needsOriginalTitle = "前の iPhone が必要です"
    static let needsOriginalMessage = "前の iPhone でアプリを一度開くか、もう一度招待してもらってください。"

    static let deviceLimitTitle = "使える iPhone は 3 台までです"
    static let deviceLimitMessage = "外す iPhone を選んでください。"
    static let removeDevice = "外す"
    static let keepDevice = "やめる"
    static let removeDeviceMessage = "外した iPhone では、この人として入っているまどと家族の手帳が見られなくなります。"
    static func removeDeviceQuestion(_ modelName: String) -> String { "\(modelName) を外しますか" }
    static func registered(_ date: String) -> String { "\(date) に登録" }

    static let revokedTitle = "このまどには戻れません"

    static let chooseTitle = "どちらを使いますか"
    static let choose = "こちらを使う"
    static let inNothing = "まだどこにも入っていない"
    static let familyNotebook = "家族の手帳"

    /// 本人の 1 つを、入っている所で言う（作った日や順番では選ばせない）。
    static func describe(windowCount: Int, openableWindowNames: [String], inFamilyNotebook: Bool) -> String {
        var parts: [String] = []
        if windowCount > 0 {
            if let first = openableWindowNames.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                parts.append(windowCount == 1 ? "みんなのまど『\(first)』" : "みんなのまど『\(first)』ほか \(windowCount - 1) つ")
            } else {
                parts.append("まど \(windowCount) つ")
            }
        }
        if inFamilyNotebook { parts.append(familyNotebook) }
        return parts.isEmpty ? inNothing : parts.joined(separator: "・") + "に入っている"
    }
}

/// 3 台の上限で外す候補。機種名と登録した日（Codex に足してもらう値）。
struct GroupRecoveryDevice: Identifiable, Equatable, Sendable {
    let id: String
    let modelName: String
    let registeredAt: Date
}

/// 本人が 2 つ見つかったときの 1 つ。名前は、この iPhone で開けたものだけ。
struct GroupRecoveryRootCandidate: Identifiable, Equatable, Sendable {
    let summary: GroupRootMembershipSummary
    let openableWindowNames: [String]
    var id: String { summary.rootID }
    var text: String {
        GroupRecoveryWords.describe(windowCount: summary.windowIDs.count,
                                    openableWindowNames: openableWindowNames,
                                    inFamilyNotebook: !summary.notebookIDs.isEmpty)
    }
}

/// 画面が受け取る状態。
enum GroupRecoveryScreenState: Equatable, Sendable {
    /// まど 1 つ分の登録の状態（Codex の型そのもの）。
    case registration(GroupRecoveryRegistrationState)
    /// GroupRootSelection.choose：本人が 2 つ以上。選ぶまで何もしない。
    case chooseRoot([GroupRecoveryRootCandidate])
}

/// まどが複数あるときの 1 行。
struct GroupRecoveryWindowItem: Identifiable, Equatable, Sendable {
    let windowID: String
    /// この iPhone で開けた名前。開けなければ nil（「まど」と出す）。
    let name: String?
    let state: GroupRecoveryRegistrationState
    var devices: [GroupRecoveryDevice] = []
    var id: String { windowID }
    var displayName: String {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return GroupRecoveryWords.unnamedWindow
        }
        return name
    }
}

/// 押したときに、状態モデルの外へ渡すもの。通信は受け取った側（Codex のアダプタ）が、
/// 本人の操作として（SharingPersonAction.run の中で）する。
enum GroupRecoveryCommand: Equatable, Sendable {
    /// Codex の型が返した次の手（queryStatus・submitSameOperation・prepareFreshGeneration）。
    case perform(GroupRecoveryRetryAction)
    /// 3 台の上限：選んだ端末を外す。
    case removeDevice(operationID: UUID, deviceID: String)
    /// 本人が 2 つ：選んだ方を使う。選ばなかった方は消さない。
    case chooseRoot(String)
    /// 今はしない・閉じる。何も送らない。
    case dismiss
}

/// 画面の中だけの次の一歩（送らない）。
enum GroupRecoveryStep: Equatable, Sendable {
    case send(GroupRecoveryCommand)
    /// 名前を入れる欄へ進む。名前を入れて［続ける］を押すまで何も起きない。
    case askFreshName
}

struct GroupRecoveryButton: Equatable, Sendable {
    let title: String
    let step: GroupRecoveryStep
}

/// 1 つの状態の画面。
struct GroupRecoveryPresentation: Equatable, Sendable {
    enum Layout: Equatable, Sendable { case message, deviceList, rootChoice }
    enum Icon: Equatable, Sendable {
        case progress, found, offline, waiting, noProvider, needsOriginal, revoked, none
    }

    let title: String
    let message: String?
    let icon: Icon
    let layout: Layout
    let primary: GroupRecoveryButton?
    let secondary: GroupRecoveryButton?

    /// nil：ready。この画面は閉じて、まどを開く。
    static func make(for state: GroupRecoveryScreenState) -> Self? {
        switch state {
        case .chooseRoot:
            return Self(title: GroupRecoveryWords.chooseTitle, message: nil, icon: .none,
                        layout: .rootChoice, primary: nil, secondary: nil)
        case .registration(let registration):
            return make(for: registration)
        }
    }

    static func make(for state: GroupRecoveryRegistrationState) -> Self? {
        let notNow = GroupRecoveryButton(title: GroupRecoveryWords.notNow, step: .send(.dismiss))
        switch state {
        case .ready:
            return nil
        case .checking:
            // 確かめている間は押すものを出さない（二重の問い合わせにしない）。
            return Self(title: GroupRecoveryWords.checkingTitle, message: nil, icon: .progress,
                        layout: .message, primary: nil, secondary: nil)
        case .unavailable:
            return Self(title: GroupRecoveryWords.unavailableTitle, message: nil, icon: .offline, layout: .message,
                        primary: .init(title: GroupRecoveryWords.retry, step: .send(.perform(state.nextAction))),
                        secondary: nil)
        case .notStarted:
            return Self(title: GroupRecoveryWords.foundTitle, message: GroupRecoveryWords.foundMessage,
                        icon: .found, layout: .message,
                        primary: .init(title: GroupRecoveryWords.continueButton, step: .send(.perform(state.nextAction))),
                        secondary: notNow)
        case .registeredWaitingForKeys:
            return Self(title: GroupRecoveryWords.waitingTitle, message: GroupRecoveryWords.waitingMessage,
                        icon: .waiting, layout: .message, primary: nil, secondary: nil)
        case .noKeyProvider:
            return Self(title: GroupRecoveryWords.noProviderTitle, message: GroupRecoveryWords.noProviderMessage,
                        icon: .noProvider, layout: .message,
                        primary: .init(title: GroupRecoveryWords.freshContinue, step: .askFreshName),
                        secondary: notNow)
        case .needsOriginalDeviceOrInvitation:
            return Self(title: GroupRecoveryWords.needsOriginalTitle, message: GroupRecoveryWords.needsOriginalMessage,
                        icon: .needsOriginal, layout: .message, primary: nil, secondary: nil)
        case .deviceLimit:
            return Self(title: GroupRecoveryWords.deviceLimitTitle, message: GroupRecoveryWords.deviceLimitMessage,
                        icon: .none, layout: .deviceList, primary: nil, secondary: nil)
        case .revoked:
            return Self(title: GroupRecoveryWords.revokedTitle, message: nil, icon: .revoked,
                        layout: .message, primary: nil, secondary: nil)
        }
    }

    /// まどが複数あるときの一覧の 2 行目。画面の見出しと同じ言葉にする。
    static func rowStatus(for state: GroupRecoveryRegistrationState) -> String? {
        make(for: state)?.title
    }
}

/// 状態モデルへの薄い層。Codex の型の関数を呼んで、送るものを決めるだけ。
enum GroupRecoveryActions {
    /// ［新しく続ける］→ 名前 →［続ける］。前の写真が開けないと伝えたあとの、本人の明示の選択。
    /// 名前が空・長すぎ・状態が違うときは何も送らない。
    static func freshGeneration(_ state: GroupRecoveryRegistrationState, newName: String) -> GroupRecoveryCommand? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = state.freshGenerationChoice(confirmedPastUnavailable: true, newName: trimmed)
        guard case .prepareFreshGeneration = action else { return nil }
        return .perform(action)
    }

    /// 3 台の上限：外す端末を選んで確認したとき。
    static func removeDevice(_ state: GroupRecoveryRegistrationState, deviceID: String) -> GroupRecoveryCommand? {
        guard case .deviceLimit(let operationID) = state, state.nextAction == .manageDevices,
              !deviceID.isEmpty else { return nil }
        return .removeDevice(operationID: operationID, deviceID: deviceID)
    }

    /// 本人が 2 つ：選んで確認したとき。候補にないものは送らない。
    static func chooseRoot(_ candidates: [GroupRecoveryRootCandidate], rootID: String) -> GroupRecoveryCommand? {
        guard candidates.count >= 2, candidates.contains(where: { $0.id == rootID }) else { return nil }
        return .chooseRoot(rootID)
    }
}
