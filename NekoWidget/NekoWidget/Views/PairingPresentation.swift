import Foundation

/// User-facing guidance for the one-window, one-invitee pairing flow.
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
                nextActionTitle: "はじめに、どちらをするか選んでください",
                nextActionDetail: "新しいまどを作るか、相手から届いた招待コードで参加します。",
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
                nextActionDetail: "相手がコードを入力したあと、参加したか確認します。",
                refreshButtonTitle: "相手が参加したか確認"
            )
        case .joining:
            return Self(
                roleTitle: "あなたは、招待された人です",
                nextActionTitle: "招待コードを確認しています",
                nextActionDetail: "この画面を閉じずに少しお待ちください。",
                refreshButtonTitle: nil
            )
        case .pendingApproval:
            return Self(
                roleTitle: "あなたは、招待された人です",
                nextActionTitle: "作った人と12語を比べ、承認を待ってください",
                nextActionDetail: "12語が違う場合は、そのまま進めず招待をやり直してください。",
                refreshButtonTitle: "承認されたか確認"
            )
        case .approvalRequired:
            return Self(
                roleTitle: "あなたは、まどを作った人です",
                nextActionTitle: "相手と12語が同じなら承認してください",
                nextActionDetail: "12語がすべて同じことを確認するまで、写真の鍵は相手へ渡りません。",
                refreshButtonTitle: nil
            )
        case .awaitingCompletion:
            return Self(
                roleTitle: "あなたは、まどを作った人です",
                nextActionTitle: "相手のiPhoneで承認を確認してもらってください",
                nextActionDetail: "相手が確認すると、このまどの設定が完了します。",
                refreshButtonTitle: "接続が完了したか確認"
            )
        case .paired:
            return Self(
                roleTitle: role == .invitee
                    ? "あなたは、招待された人です"
                    : "あなたは、まどを作った人です",
                nextActionTitle: "このまどは接続されています",
                nextActionDetail: "写真は共有シートで明示した1枚だけを届けます。",
                refreshButtonTitle: "接続状態を確認"
            )
        case .failed:
            return Self(
                roleTitle: role == .invitee
                    ? "招待されたまどを確認できませんでした"
                    : "まどの準備を完了できませんでした",
                nextActionTitle: "画面の案内を確認してください",
                nextActionDetail: "必要な場合は設定を取り消し、新しい招待からやり直せます。",
                refreshButtonTitle: nil
            )
        }
    }
}
