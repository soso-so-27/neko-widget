import Foundation

/// Why new writing does not reach the family now (1029e). What is written
/// stays on every iPhone; only sharing stops. Read from the server's payer
/// state, never decided on this iPhone.
enum FamilySharingPause: Equatable, Sendable {
    /// The payer left without naming anyone. Whoever is confirmed first on the
    /// server becomes the payer; `canClaim` is the server's word that this
    /// person has Plus and may be the one.
    case noPayer(canClaim: Bool, handoverPending: Bool)
    /// The payer's Plus could not be confirmed. The payer stays the payer.
    case payerPlusUnverified(isPayer: Bool)

    init?(_ state: FamilyNotebookPayerState) {
        switch (state.sharingStatus, state.pauseReason) {
        case (.paused, .noPayer):
            self = .noPayer(canClaim: state.canClaimPayer, handoverPending: state.nominationPending)
        case (.paused, .payerPlusUnverified):
            self = .payerPlusUnverified(isPayer: state.role == .payer)
        default:
            return nil
        }
    }
}

struct FamilyInvitation: Equatable, Sendable {
    var link: URL
    var expiresAt: Date
}

/// What an invitation shows before joining: who asks and for which cats.
/// Only what the family chose to show; never an address or health notes.
struct FamilyInvitationPreview: Equatable, Sendable {
    var inviterName: String
    var catNames: [String]
    var expiresAt: Date?
}

enum FamilyJoinResult: Equatable, Sendable {
    case pendingApproval
    case waitingForKeys
    case joined
}

enum FamilyExitResult: Equatable, Sendable {
    /// The server confirmed it.
    case confirmed
    /// Sent, result not known yet; ask again before doing it twice.
    case pending
}

enum FamilySharingError: Error, Equatable, Sendable {
    case invitationExpired, invitationRevoked, invitationUsed
    case alreadyInFamily, memberLimit
    case signInExpired, notAllowed
    case plusRequired, membershipChecking
    case staleRoster, removedOrDissolved
    /// Someone else in the family was confirmed as the payer first.
    case payerAlreadyChosen
    case offline, rateLimited, serviceUnavailable, unknownOutcome
    case unsupported
    /// Not possible before the family works between iPhones (the prototype).
    case notAvailableYet

    enum Recovery: Sendable { case retry, reload, personAction }

    var recovery: Recovery {
        switch self {
        case .offline, .rateLimited, .serviceUnavailable: .retry
        case .unknownOutcome, .staleRoster, .payerAlreadyChosen: .reload
        default: .personAction
        }
    }

    var message: String {
        switch self {
        case .invitationExpired: "この招待は期限が切れています。新しい招待をもらってください。"
        case .invitationRevoked: "この招待は取り消されています。"
        case .invitationUsed: "この招待はもう使われています。"
        case .alreadyInFamily: "家族は 1 つまでです。いまの家族から抜けると参加できます。"
        case .memberLimit: "この家族はいっぱいです。"
        case .signInExpired: "もう一度サインインしてください。"
        case .notAllowed: "この操作はできません。"
        case .plusRequired: "家族を作るには Plus が必要です。"
        case .membershipChecking: "Plus の確認ができるまでお待ちください。"
        case .staleRoster: "家族の情報が新しくなりました。もう一度お試しください。"
        case .removedOrDissolved: "この家族の共有は終わっています。"
        case .payerAlreadyChosen: "ほかの家族が先に払う人になりました。共有は戻っています。あなたの Plus はそのまま使えます。"
        case .offline: "つながっていません。つながってからもう一度お試しください。"
        case .rateLimited: "少し待ってから、もう一度お試しください。"
        case .serviceUnavailable: "いまは使えません。少し待ってから、もう一度お試しください。"
        case .unknownOutcome: "結果を確かめています。少し待ってから開き直してください。"
        case .unsupported: "このアプリを最新にしてください。記録は消していません。"
        case .notAvailableYet: "試作のため、まだできません。"
        }
    }
}

