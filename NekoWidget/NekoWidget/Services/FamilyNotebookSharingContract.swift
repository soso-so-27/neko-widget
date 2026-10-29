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
    /// Opaque reference to a verified invitation kept in the private store.
    /// The screen never receives its capability secret.
    var contextID: UUID? = nil
}

struct FamilyFarewellPreview: Equatable, Sendable {
    let id: UUID, familyID: UUID, familyCatID: UUID
    let catName: String
    /// Gregorian YYYY-MM-DD, from this phone's record, validated before sharing.
    let day: String
    let currentSharedDay: String?
    let currentSharedAuthor: FamilyNotebookAuthor?
    let expiresAt: Date
    var explanation: String {
        "この子の旅立った日を、家族の手帳に共有します。家族にあとから加わる人にも、この記録が見えることがあります。"
    }
}

struct FamilyFarewellSharingState: Equatable, Sendable {
    let familyID: UUID, familyCatID: UUID
    let localDay: String?, consentedDay: String?, sharedDay: String?
    let sharedAuthor: FamilyNotebookAuthor?
    let sharingPending: Bool, revocationPending: Bool
    let mayAlreadyHaveBeenShared: Bool
    var hasConsentForLocalDay: Bool { localDay != nil && localDay == consentedDay }
    var revocationExplanation: String {
        "まだ送っていない日付の送信を止めます。あなたが共有した日付が家族の現在の表示なら、その表示を消す更新を送ります。このiPhoneの日付は残ります。すでに届いた日付や履歴は回収できません。送信中だった日付は、届いている可能性があります。"
    }
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
    /// Taking over paying needs this person's own Plus (1029f).
    case handoverPlusRequired
    case staleRoster, removedOrDissolved
    /// Someone else in the family was confirmed as the payer first.
    case payerAlreadyChosen
    case offline, rateLimited, serviceUnavailable, unknownOutcome
    case unsupported
    case farewellDayMissing, farewellPreviewChanged
    /// Not possible before the family works between iPhones (the prototype).
    case notAvailableYet

    enum Recovery: Sendable { case retry, reload, personAction }

    var recovery: Recovery {
        switch self {
        case .offline, .rateLimited, .serviceUnavailable: .retry
        case .unknownOutcome, .staleRoster, .payerAlreadyChosen, .farewellPreviewChanged: .reload
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
        case .handoverPlusRequired: "引き継ぐには Plus が必要です。"
        case .membershipChecking: "Plus の確認ができるまでお待ちください。"
        case .staleRoster: "家族の情報が新しくなりました。もう一度お試しください。"
        case .removedOrDissolved: "この家族の共有は終わっています。"
        case .payerAlreadyChosen: "ほかの家族の Plus で、先に共有が戻りました。あなたの Plus はそのまま使えます。"
        case .offline: "つながっていません。つながってからもう一度お試しください。"
        case .rateLimited: "少し待ってから、もう一度お試しください。"
        case .serviceUnavailable: "いまは使えません。少し待ってから、もう一度お試しください。"
        case .unknownOutcome: "結果を確かめています。少し待ってから開き直してください。"
        case .unsupported: "このアプリを最新にしてください。記録は消していません。"
        case .notAvailableYet: "試作のため、まだできません。"
        case .farewellDayMissing: "この子の旅立った日は、まだ記録されていません。"
        case .farewellPreviewChanged: "日付か家族の状態が変わりました。共有する内容をもう一度確認してください。"
        }
    }
}


enum FamilySharingState: Equatable, Sendable {
    case checking
    case notInFamily
    /// Asked to join; the family has not let this person in yet.
    case pendingApproval
    /// Let in; the keys for the notebook have not arrived yet.
    case waitingForKeys
    case inFamily(FamilyMembership)
    /// Leaving or ending sent; the server has not confirmed it yet.
    case leaving

    var membership: FamilyMembership? {
        if case let .inFamily(membership) = self { return membership }
        return nil
    }
}

/// Every operation carries an operation ID; sending the same operation again
/// uses the same ID, so a retry never makes a second family or a second join.
@MainActor
protocol FamilyNotebookSharingService: AnyObject {
    /// Whether invitations can leave this iPhone (false in the prototype).
    var sendsInvitations: Bool { get }
    func loadState() async throws -> FamilySharingState
    /// Nil while sharing goes on.
    func loadPause() async throws -> FamilySharingPause?
    func createFamily(operationID: UUID) async throws
    func createInvitation(operationID: UUID) async throws -> FamilyInvitation
    func previewInvitation(_ link: URL?) async throws -> FamilyInvitationPreview
    func join(_ invitation: FamilyInvitationPreview, operationID: UUID) async throws -> FamilyJoinResult
    func leaveFamily(operationID: UUID) async throws -> FamilyExitResult
    func removeMember(personID: String, operationID: UUID) async throws
    func dissolveFamily(operationID: UUID) async throws -> FamilyExitResult
    /// After the payer left without naming anyone: become the payer, so
    /// sharing comes back. The server decides who came first.
    func claimPayer(operationID: UUID) async throws
    func loadHandover() async throws -> FamilyPayerHandover
    func nominatePayer(personID: String, expectedGeneration: Int64, operationID: UUID) async throws
    func acceptPayer(nominationID: UUID, expectedGeneration: Int64, operationID: UUID) async throws
    func cancelPayerNomination(nominationID: UUID, expectedGeneration: Int64, operationID: UUID) async throws
    func loadFarewellSharing(toolCatID: UUID) async throws -> FamilyFarewellSharingState
    func previewFarewellSharing(toolCatID: UUID) async throws -> FamilyFarewellPreview
    func consentToShareFarewell(previewID: UUID, operationID: UUID) async throws
    func revokeFarewellSharing(toolCatID: UUID, operationID: UUID) async throws
}

// A prototype never pretends to have nominated a real family member. Existing
// screen previews remain source-compatible until the production adapter lands.
extension FamilyNotebookSharingService {
    func loadFarewellSharing(toolCatID: UUID) async throws -> FamilyFarewellSharingState { throw FamilySharingError.notAvailableYet }
    func previewFarewellSharing(toolCatID: UUID) async throws -> FamilyFarewellPreview { throw FamilySharingError.notAvailableYet }
    func consentToShareFarewell(previewID: UUID, operationID: UUID) async throws { throw FamilySharingError.notAvailableYet }
    func revokeFarewellSharing(toolCatID: UUID, operationID: UUID) async throws { throw FamilySharingError.notAvailableYet }
    func loadHandover() async throws -> FamilyPayerHandover { throw FamilySharingError.notAvailableYet }
    func nominatePayer(personID: String, expectedGeneration: Int64, operationID: UUID) async throws { throw FamilySharingError.notAvailableYet }
    func acceptPayer(nominationID: UUID, expectedGeneration: Int64, operationID: UUID) async throws { throw FamilySharingError.notAvailableYet }
    func cancelPayerNomination(nominationID: UUID, expectedGeneration: Int64, operationID: UUID) async throws { throw FamilySharingError.notAvailableYet }
}

