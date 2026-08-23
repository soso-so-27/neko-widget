import Foundation

enum PairingPresentationVerificationError: Error {
    case failed(String)
}

@main
enum PairingPresentationVerifier {
    static func main() throws {
        try verify(
            phase: .unpaired,
            role: nil,
            roleText: "まだまどにつながっていません",
            actionText: "はじめに、どちらをするか選んでください",
            refreshText: nil
        )
        try verify(
            phase: .awaitingInvitee,
            role: .inviter,
            roleText: "あなたは、まどを作った人です",
            actionText: "次は、招待コードを相手へ送ってください",
            refreshText: "相手が参加したか確認"
        )
        try verify(
            phase: .pendingApproval,
            role: .invitee,
            roleText: "あなたは、招待された人です",
            actionText: "作った人と12語を比べ、承認を待ってください",
            refreshText: "承認されたか確認"
        )
        try verify(
            phase: .approvalRequired,
            role: .inviter,
            roleText: "あなたは、まどを作った人です",
            actionText: "相手と12語が同じなら承認してください",
            refreshText: nil
        )
        try verify(
            phase: .awaitingCompletion,
            role: .inviter,
            roleText: "あなたは、まどを作った人です",
            actionText: "相手のiPhoneで承認を確認してもらってください",
            refreshText: "接続が完了したか確認"
        )
        try verify(
            phase: .paired,
            role: .invitee,
            roleText: "あなたは、招待された人です",
            actionText: "このまどは接続されています",
            refreshText: "接続状態を確認"
        )
        try verifySafeError(
            PairingError.requestRejected(
                status: 410,
                code: "invitation_unavailable",
                message: "relay-internal-detail-must-not-appear"
            ),
            expected: "この招待は利用できません。新しい招待コードが必要です。"
        )
    }

    private static func verify(
        phase: PairingPhase,
        role: PairingRole?,
        roleText: String,
        actionText: String,
        refreshText: String?
    ) throws {
        let value = PairingGuidancePresentation.make(phase: phase, role: role)
        guard value.roleTitle == roleText,
              value.nextActionTitle == actionText,
              value.refreshButtonTitle == refreshText,
              !value.nextActionDetail.isEmpty
        else {
            throw PairingPresentationVerificationError.failed(
                "Unexpected guidance for \(phase.rawValue)"
            )
        }
    }

    private static func verifySafeError(
        _ error: PairingError,
        expected: String
    ) throws {
        guard error.localizedDescription == expected,
              !error.localizedDescription.contains("relay-internal-detail")
        else {
            throw PairingPresentationVerificationError.failed(
                "Pairing error presentation exposed an unexpected value"
            )
        }
    }
}
