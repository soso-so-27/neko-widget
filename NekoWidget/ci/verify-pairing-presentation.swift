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
            actionText: "はじめに、このiPhoneですることを選んでください",
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
            phase: .claimingRecovery,
            role: .invitee,
            roleText: "この端末：追加するiPhone",
            actionText: "追加コードを確認しています",
            refreshText: nil
        )
        try verify(
            phase: .pendingRecoveryApproval,
            role: .invitee,
            roleText: "この端末：追加するiPhone",
            actionText: "接続済みの相手と12語を比べてください",
            refreshText: "承認されたか確認"
        )
        try verify(
            phase: .recoveryAwaitingCompletion,
            role: .invitee,
            roleText: "この端末：追加するiPhone",
            actionText: "iPhoneの追加を完了しています",
            refreshText: "完了したか確認"
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
        try verifyDeviceChangeGuidance()
        try verifySafeError(
            PairingError.requestRejected(
                status: 410,
                code: "invitation_unavailable",
                message: "relay-internal-detail-must-not-appear"
            ),
            expected: "この招待は利用できません。新しい招待コードが必要です。"
        )
        try verifySafeError(
            PairingError.requestRejected(
                status: 410,
                code: "recovery_unavailable",
                message: "relay-internal-detail-must-not-appear"
            ),
            expected: "端末追加コードの期限が切れました。接続済みの相手に新しいコードを作ってもらってください。"
        )
    }

    private static func verifyDeviceChangeGuidance() throws {
        let replacement = DeviceChangeGuidancePresentation.make(
            currentDevice: .newIPhone
        )
        guard replacement.newIPhoneTitle == "追加するiPhone（この端末）",
              replacement.previousIPhoneTitle == "すでに使っているiPhone",
              replacement.partnerIPhoneTitle == "相手のiPhone",
              !replacement.newIPhoneDetail.isEmpty,
              !replacement.previousIPhoneDetail.isEmpty,
              !replacement.partnerIPhoneDetail.isEmpty
        else {
            throw PairingPresentationVerificationError.failed(
                "Unexpected guidance for the new iPhone"
            )
        }

        let partner = DeviceChangeGuidancePresentation.make(
            currentDevice: .partnerIPhone
        )
        guard partner.newIPhoneTitle == "追加するiPhone",
              partner.previousIPhoneTitle == "相手がすでに使っているiPhone",
              partner.partnerIPhoneTitle == "相手のiPhone（この端末）",
              !partner.newIPhoneDetail.isEmpty,
              !partner.previousIPhoneDetail.isEmpty,
              !partner.partnerIPhoneDetail.isEmpty
        else {
            throw PairingPresentationVerificationError.failed(
                "Unexpected guidance for the partner iPhone"
            )
        }
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
