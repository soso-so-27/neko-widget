import Foundation

struct PairingBuildPresentation {
    static var currentText: String {
        make(
            version: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            build: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String
        )
    }

    static func make(version: String?, build: String?) -> String {
        let visibleVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleBuild = build?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVersion = visibleVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "-"
        let resolvedBuild = visibleBuild.flatMap { $0.isEmpty ? nil : $0 } ?? "-"
        return "バージョン \(resolvedVersion)（Build \(resolvedBuild)）"
    }
}

struct PairingAvailabilityPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let retryButtonTitle: String?

    static func temporarilyUnavailable(detail: String) -> Self {
        Self(
            title: "まどを読み込めません",
            detail: detail,
            retryButtonTitle: "もう一度読み込む"
        )
    }

    static let consentRequired = Self(
        title: "相手とつながっています",
        detail: "写真を届けるには、新しい内容を読んで同意してください。",
        retryButtonTitle: nil
    )
}

enum PendingFamilyMemoryTargetBootstrapPhase: Equatable, Sendable {
    case checking
    case temporarilyUnavailable
    case ready
}

enum PendingFamilyMemoryTargetDisposition: Equatable, Sendable {
    case preserve
    case resolve
}

struct PendingFamilyMemoryTargetPresentationPolicy {
    static func disposition(
        for phase: PendingFamilyMemoryTargetBootstrapPhase
    ) -> PendingFamilyMemoryTargetDisposition {
        switch phase {
        case .checking, .temporarilyUnavailable:
            return .preserve
        case .ready:
            return .resolve
        }
    }
}

/// Stable, presentation-only grouping for the private-window catalog.
///
/// Synchronization updates `updatedAt` frequently, so it must never decide the
/// visual order. Connected windows keep their creation order while unfinished
/// setup is shown separately. Opening a window can change the internal active
/// context required by legacy stores, but that implementation detail never
/// changes list order or appears as a user-facing state.
struct PrivateWindowListPresentationInput: Equatable, Sendable {
    let localWindowID: String
    let createdAt: Date
    let phase: PairingPhase?
}

struct PrivateWindowListPresentation: Equatable, Sendable {
    let connectedWindowIDs: [String]
    let setupWindowIDs: [String]
}

enum PrivateWindowListPresentationPolicy {
    static func make(
        inputs: [PrivateWindowListPresentationInput]
    ) -> PrivateWindowListPresentation {
        let stable = inputs.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.localWindowID < $1.localWindowID
        }
        let isSetup: (PrivateWindowListPresentationInput) -> Bool = { input in
            // A space identifier exists before pairing is complete, so it is
            // not proof of a connected window. Unknown state stays in the
            // setup section rather than overstating that two people are linked.
            guard let phase = input.phase else { return true }
            return phase != .paired
        }
        return PrivateWindowListPresentation(
            connectedWindowIDs: stable.filter { !isSetup($0) }.map(\.localWindowID),
            setupWindowIDs: stable.filter(isSetup).map(\.localWindowID)
        )
    }
}

/// User-facing guidance for one selected window and its one peer.
///
/// This type deliberately accepts only the public phase and role. It cannot
/// accidentally expose relay identifiers, invitation secrets, Keychain
/// status values, or arbitrary server messages to the interface.
struct PairingGuidancePresentation: Equatable, Sendable {
    let roleTitle: String
    let nextActionTitle: String
    let nextActionDetail: String
    let refreshButtonTitle: String?

    static func make(
        phase: PairingPhase,
        role: PairingRole?
    ) -> Self {
        switch phase {
        case .unpaired:
            return Self(
                roleTitle: "まだまどにつながっていません",
                nextActionTitle: "はじめに、このiPhoneですることを選んでください",
                nextActionDetail: "新しく作る、招待に参加する、別のiPhoneを追加する、の3つから選びます。",
                refreshButtonTitle: nil
            )
        case .creatingInvitation:
            return Self(
                roleTitle: "あなたは、まどを作る人です",
                nextActionTitle: "招待を準備しています",
                nextActionDetail: "この画面を閉じずに少しお待ちください。",
                refreshButtonTitle: nil
            )
        case .awaitingInvitee:
            return Self(
                roleTitle: "あなたは、まどを作った人です",
                nextActionTitle: "次は、招待コードを相手へ送ってください",
                nextActionDetail: "相手がコードを入力したら、「相手が参加したか確認」を押してください。",
                refreshButtonTitle: "相手が参加したか確認"
            )
        case .joining:
            return Self(
                roleTitle: "あなたは、招待された人です",
                nextActionTitle: "招待コードを確認しています",
                nextActionDetail: "この画面を閉じずに少しお待ちください。",
                refreshButtonTitle: nil
            )
        case .claimingRecovery:
            return Self(
                roleTitle: "このiPhone：追加するiPhone",
                nextActionTitle: "追加コードを確認しています",
                nextActionDetail: "相手のiPhoneが作った追加コードで、同じまどを使えるようにします。",
                refreshButtonTitle: nil
            )
        case .pendingRecoveryApproval:
            return Self(
                roleTitle: "このiPhone：追加するiPhone",
                nextActionTitle: "相手と12語を見比べてください",
                nextActionDetail: "相手のiPhoneで同じ12語を確認してもらいます。すでに使っているiPhoneは解除されません。",
                refreshButtonTitle: "承認されたか確認"
            )
        case .recoveryAwaitingCompletion:
            return Self(
                roleTitle: "このiPhone：追加するiPhone",
                nextActionTitle: "iPhoneの追加を完了しています",
                nextActionDetail: "相手のiPhoneによる承認は済んでいます。この画面を閉じずに少しお待ちください。",
                refreshButtonTitle: "完了したか確認"
            )
        case .pendingApproval:
            return Self(
                roleTitle: "あなたは、招待された人です",
                nextActionTitle: "まどを作った人と12語を見比べてください",
                nextActionDetail: "12語が違うときは進めずに、招待をやり直してください。",
                refreshButtonTitle: "承認されたか確認"
            )
        case .approvalRequired:
            return Self(
                roleTitle: "あなたは、まどを作った人です",
                nextActionTitle: "相手と12語が同じなら承認してください",
                nextActionDetail: "承認するまで、相手は写真を見られません。",
                refreshButtonTitle: nil
            )
        case .awaitingCompletion:
            return Self(
                roleTitle: "あなたは、まどを作った人です",
                nextActionTitle: "相手のiPhoneで完了するのを待っています",
                nextActionDetail: "相手のiPhoneで完了すると、まどがつながります。",
                refreshButtonTitle: "つながったか確認"
            )
        case .paired:
            return Self(
                roleTitle: role == .invitee
                    ? "あなたは、招待された人です"
                    : "あなたは、まどを作った人です",
                nextActionTitle: "このまどはつながっています",
                nextActionDetail: "写真は、自分で選んだものだけを1枚ずつ届けます。",
                refreshButtonTitle: "もう一度読み込む"
            )
        case .failed:
            return Self(
                roleTitle: role == .invitee
                    ? "招待されたまどに参加できませんでした"
                    : "まどを作れませんでした",
                nextActionTitle: "まどがまだつながっていません",
                nextActionDetail: "下のボタンから続けてください。",
                refreshButtonTitle: nil
            )
        }
    }
}

/// Device labels shown during peer-approved additional-device enrollment.
///
/// Enrollment has three different phones in the user's mental model. Keeping
/// these labels in one presentation type prevents the UI from calling both
/// the added phone and the approving peer merely "the other iPhone".
struct DeviceChangeGuidancePresentation: Equatable, Sendable {
    enum CurrentDevice: Equatable, Sendable {
        case newIPhone
        case partnerIPhone
    }

    let newIPhoneTitle: String
    let newIPhoneDetail: String
    let previousIPhoneTitle: String
    let previousIPhoneDetail: String
    let partnerIPhoneTitle: String
    let partnerIPhoneDetail: String

    static func make(currentDevice: CurrentDevice) -> Self {
        switch currentDevice {
        case .newIPhone:
            return Self(
                newIPhoneTitle: "追加するiPhone（このiPhone）",
                newIPhoneDetail: "相手のiPhoneから届いた追加コードを入力します。",
                previousIPhoneTitle: "すでに使っているiPhone",
                previousIPhoneDetail: "何もしなくて大丈夫です。そのまま使えます。",
                partnerIPhoneTitle: "相手のiPhone",
                partnerIPhoneDetail: "追加コードを作り、12語を確認してこのiPhoneを承認します。"
            )
        case .partnerIPhone:
            return Self(
                newIPhoneTitle: "追加するiPhone",
                newIPhoneDetail: "このiPhoneで作った追加コードを入力します。",
                previousIPhoneTitle: "相手がすでに使っているiPhone",
                previousIPhoneDetail: "何もしなくて大丈夫です。そのまま使えます。",
                partnerIPhoneTitle: "相手のiPhone（このiPhone）",
                partnerIPhoneDetail: "このiPhoneで、相手のiPhoneの追加を承認します。"
            )
        }
    }
}
