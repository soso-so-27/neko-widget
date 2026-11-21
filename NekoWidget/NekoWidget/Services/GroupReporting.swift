import Foundation
import Combine

// Reporting a photo and blocking someone in a group window, as the screens
// see it (ねこのまど_通報と返答の画面との約束_1028d). The screens hand over what
// the person chose; encrypting the one photo, signing, keeping the draft so a
// send can resume, and talking to the server are the service's. Behind it is
// a prototype on this iPhone now, and Codex's real adapter later.

/// The closed reason codes the server accepts. Only the code is sent.
enum GroupReportReason: String, CaseIterable, Codable, Sendable {
    case objectionable, harassment, privacy, other

    var title: String {
        switch self {
        case .objectionable: "不適切な内容"
        case .harassment: "嫌がらせ"
        case .privacy: "プライバシー"
        case .other: "その他"
        }
    }
}

/// What the person agreed to: this one photo goes to the team, kept 7 days.
struct GroupReportConsent: Codable, Equatable, Sendable {
    var version = 1
    var acceptedAt: Date
}

/// Where one report is. Sent is not received: only a confirmed commit is.
enum GroupReportProgress: String, Codable, Equatable, Sendable {
    case preparing, sending
    case received
    /// Offline, timeout or a server error: the same draft can be sent again.
    case retryable
    /// Reservation expired before any confirmed commit; not evidence expiry.
    case expired
    case alreadyReported
    case authenticationRequired
    case unavailable
}

/// The team's answer. Unknown answers stay unknown; no server text is shown.
enum GroupReportReply: String, Codable, Equatable, Sendable {
    case none, noAction, restricted, released, unknown
}

struct GroupReportRecord: Identifiable, Codable, Equatable, Sendable {
    /// The draft on this iPhone (not the server's report ID).
    var id: String
    var windowID: String
    var photoID: String
    var senderName: String
    var reason: GroupReportReason
    var progress: GroupReportProgress
    var reply: GroupReportReply
    var sentAt: Date
    var repliedAt: Date?
    /// Server-issued matching number, not an identifier that grants access.
    var receiptNumber: String? = nil
    /// 11/20: rebuilt from the Keychain copy after the app was installed
    /// again: photo, number and date only (the reason was not kept).
    var isKeptCopy: Bool? = nil
}

enum GroupSafetyError: Error, Equatable, Sendable {
    case notAuthorized, notFound, alreadyReported, conflict
    case consentRequired, reservationExpired
    case dailyLimit, rateLimited
    case disabled, unknownOutcome, offline
    case authenticationRequired, invalidResponse
    case blockSelf
    case storageUnavailable, evidenceUnavailable

    var message: String {
        switch self {
        case .notAuthorized: "いまは送れません。届いた写真はそのままです。"
        case .notFound: "この写真は、もう通報できません。届いてから時間がたったか、消された写真です。"
        case .alreadyReported: "この写真はもう通報しています。"
        case .conflict: "うまく送れませんでした。写真を開き直して、もう一度お試しください。"
        case .consentRequired: "理由を選んで、もう一度「送る」を押してください。"
        case .reservationExpired: "時間がたったため、送れませんでした。もう一度通報してください。"
        case .dailyLimit: "きょうはこれ以上通報できません。明日お試しください。"
        case .rateLimited: "少し待ってから、もう一度お試しください。"
        case .disabled: "いまは通報できません。"
        case .unknownOutcome: "送れたかどうか分かりませんでした。「もう一度送る」を押してください。"
        // 11/21e: the same words as the rest of the まど for no connection.
        case .offline: "接続できません。電波のあるところで、もう一度お試しください。"
        case .authenticationRequired: GroupClockSkew.isLikely ? GroupClockSkew.message : "まどを開き直してから、もう一度お試しください。"
        case .invalidResponse: "いまは使えません。少し待ってから、もう一度お試しください。"
        case .blockSelf: "自分はブロックできません。"
        case .storageUnavailable: "通報を保存できませんでした。iPhoneの空き容量を確かめて、もう一度お試しください。"
        case .evidenceUnavailable: "この写真を読み込めませんでした。写真を開き直してください。"
        }
    }

    /// 11/21e: the same failures, said for a block or unblock (not a report).
    var blockMessage: String {
        switch self {
        case .blockSelf: "自分はブロックできません。"
        case .offline: GroupSafetyError.offline.message
        case .rateLimited, .authenticationRequired: message
        case .notAuthorized, .notFound: "このまどでは、いまはブロックを変えられません。"
        case .storageUnavailable: "ブロックを保存できませんでした。iPhoneの空き容量を確かめて、もう一度お試しください。"
        default: "ブロックを変えられませんでした。少し待ってから、もう一度お試しください。"
        }
    }

    /// 11/21e: no connection or a busy relay: the report waits and goes later.
    var isConnectionTrouble: Bool {
        [.offline, .unknownOutcome, .rateLimited].contains(self)
    }
}

struct GroupPendingBlock: Identifiable, Equatable, Sendable {
    let id: UUID
    let windowID: String, participantID: String
    let active: Bool
}

@MainActor
protocol GroupReportingService: AnyObject {
    /// False hides reporting and blocking (the server flags are off by default).
    var isAvailable: Bool { get }
    func refreshAvailability() async
    /// Fixes the photo, reason and consent, encrypts and keeps the draft. Nothing is sent yet.
    func prepareReport(windowID: String, photoID: String, senderName: String,
                       reason: GroupReportReason, consent: GroupReportConsent) async throws -> String
    /// reserve → upload → commit, until the team has it.
    func submitReport(draftID: String) async throws -> GroupReportRecord
    /// The same draft, the same bytes, from where it stopped.
    func resumeReport(draftID: String) async throws -> GroupReportRecord
    /// 11/20: the person's own 「もう一度送る」. The tap is consent again, so a
    /// draft the relay never reserved is not refused for an old consent.
    func resumeReport(draftID: String, consent: GroupReportConsent) async throws -> GroupReportRecord
    /// This person's reports in this window, kept even after leaving it.
    func reports(windowID: String) async -> [GroupReportRecord]
    /// Device-local suppression only: no receipt, reply or former identity is exposed.
    func locallyReportedPhotoIDs(windowID: String) async throws -> Set<String>
    /// Asks the server for this exact report's state and answer.
    func refreshReport(draftID: String) async throws -> GroupReportRecord
    func pendingBlocks(windowID: String) async throws -> [GroupPendingBlock]
    /// Keeps the choice on this iPhone first; one that cannot reach the
    /// relay now waits for `sendPendingBlocks` instead of failing (11/20).
    func setBlock(windowID: String, participantID: String, active: Bool, operationID: UUID) async throws
    /// Sends blocks and unblocks still waiting for this window (automatic).
    func sendPendingBlocks(windowID: String) async
    /// 11/21e: why the last availability check failed (nil: it did not, or
    /// none ran). Connection trouble still lets a report be kept and sent later.
    var availabilityProblem: GroupSafetyError? { get }
    /// 11/21e: automatic. Reports that did not reach the team go again, when
    /// the relay can still take them without a new tap.
    func sendUnsentReports() async
    /// 11/21e: automatic. Reads the team's answers to this person's reports.
    func refreshReplies() async
}

extension GroupReportingService {
    func locallyReportedPhotoIDs(windowID: String) async throws -> Set<String> {
        Set(await reports(windowID: windowID).map(\.photoID))
    }
    func refreshAvailability() async {}
    func pendingBlocks(windowID: String) async throws -> [GroupPendingBlock] { [] }
    func resumeReport(draftID: String, consent: GroupReportConsent) async throws -> GroupReportRecord {
        try await resumeReport(draftID: draftID)
    }
    func sendPendingBlocks(windowID: String) async {}
    var availabilityProblem: GroupSafetyError? { nil }
    func sendUnsentReports() async {}
    func refreshReplies() async {}
}

/// What the screens hold.
@MainActor
final class GroupSafety: ObservableObject {
    static let shared = GroupSafety(service: GroupReportingProvider.make())

    @Published private var locallyReportedPhotos: [String: Set<String>] = [:]
    @Published private var unreadableSuppression = Set<String>()
    @Published private(set) var records: [String: [GroupReportRecord]] = [:]
    @Published private(set) var pendingBlocks: [String: [GroupPendingBlock]] = [:]
    @Published var failure: GroupSafetyError?
    /// 11/21e: the failure came from a block or unblock (said in its words).
    @Published private(set) var failureIsBlock = false
    @Published private(set) var isWorking = false
    private var catchingUp = false
    let service: any GroupReportingService

    init(service: any GroupReportingService) {
        self.service = service
    }

    func load(windowID: String) async {
        await service.refreshAvailability()
        await service.sendPendingBlocks(windowID: windowID)
        await loadRecords(windowID: windowID)
    }

    /// 11/20: a block or unblock that could not be sent goes now (opening
    /// the window, each sync, before each photo is sent). Automatic calls.
    func sendPendingBlocks(windowID: String) async {
        await service.sendPendingBlocks(windowID: windowID)
        if let next = try? await service.pendingBlocks(windowID: windowID), pendingBlocks[windowID] != next {
            pendingBlocks[windowID] = next
        }
    }

    /// This iPhone's own records only, without asking the server.
    /// Values are assigned only when they changed, so opening a window does
    /// not announce unchanged records (each announcement rewrites the
    /// home-screen photo).
    func loadRecords(windowID: String) async {
        do {
            let reported = try await service.locallyReportedPhotoIDs(windowID: windowID)
            if locallyReportedPhotos[windowID] != reported { locallyReportedPhotos[windowID] = reported }
            if unreadableSuppression.contains(windowID) { unreadableSuppression.remove(windowID) }
        } catch {
            // An unreadable local record must never uncover a reported photo.
            unreadableSuppression.insert(windowID)
            failure = .storageUnavailable
        }
        let nextRecords = await service.reports(windowID: windowID)
        if records[windowID] != nextRecords { records[windowID] = nextRecords }
        do {
            let nextBlocks = try await service.pendingBlocks(windowID: windowID)
            if pendingBlocks[windowID] != nextBlocks { pendingBlocks[windowID] = nextBlocks }
        }
        catch { failure = error as? GroupSafetyError ?? .storageUnavailable }
    }

    /// 11/21e: what the alerts say: a block's failure in block words.
    var failureMessage: String {
        guard let failure else { return "" }
        return failureIsBlock ? failure.blockMessage : failure.message
    }

    /// 11/21e: this person's newest report of the photo when none reached the
    /// team (not sent yet, or refused), so 「この写真を通報」 stays and resumes it.
    /// Nil when there is none, or one was received.
    func unsentReport(_ photoID: String, in windowID: String) -> GroupReportRecord? {
        let mine = (records[windowID] ?? []).filter { $0.photoID == photoID }
        guard !mine.contains(where: { $0.progress == .received || $0.progress == .alreadyReported }) else { return nil }
        return mine.max { $0.sentAt < $1.sentAt }
    }

    /// 11/21e: coming to the front and the まど list (automatic, quiet):
    /// unsent reports go again, the team's answers are read, and the listed
    /// windows' records load, whichever window was opened last.
    func catchUp(windowIDs: [String]) async {
        guard !catchingUp else { return }
        catchingUp = true
        defer { catchingUp = false }
        await SharingPersonAction.automatic {
            await service.sendUnsentReports()
            await service.refreshReplies()
        }
        for windowID in windowIDs { await loadRecords(windowID: windowID) }
    }

    /// 11/21e: blocking and unblocking, said in block words. An unblock the
    /// relay refuses as not found (the person, or this iPhone's place in the
    /// window, is gone there) has no block left to lift: it counts as done,
    /// so the person is not left hidden here. False: refused, kept as it was.
    @discardableResult
    func setBlock(windowID: String, participantID: String, active: Bool, operationID: UUID = UUID()) async -> Bool {
        let service = service
        // 1115s: the person's own action, outside the automatic budget.
        return await SharingPersonAction.run {
            isWorking = true
            defer { isWorking = false }
            var done = true
            do {
                try await service.setBlock(windowID: windowID, participantID: participantID,
                                           active: active, operationID: operationID)
            } catch GroupSafetyError.notFound where !active {
                // Nothing to lift on the relay.
            } catch {
                failureIsBlock = true
                failure = error as? GroupSafetyError ?? .unknownOutcome
                done = false
            }
            await load(windowID: windowID)
            return done
        }
    }

    /// A photo this person reported stays covered on their iPhone, whatever
    /// the team decides; the others in the window still see it until then.
    func hasReported(_ photoID: String, in windowID: String) -> Bool {
        unreadableSuppression.contains(windowID)
            || locallyReportedPhotos[windowID]?.contains(photoID) == true
            || records[windowID]?.contains { $0.photoID == photoID } == true
    }

    /// Asks again for every report that can still change.
    func refresh(windowID: String) async {
        for record in await service.reports(windowID: windowID)
        where record.progress == .received {
            _ = try? await service.refreshReport(draftID: record.id)
        }
        await load(windowID: windowID)
    }

    @discardableResult
    func run<Value>(windowID: String, _ operation: () async throws -> Value) async -> Value? {
        // 1115s: the person's own action, outside the automatic budget.
        return await SharingPersonAction.run {
            isWorking = true
            defer { isWorking = false }
            do {
                let value = try await operation()
                await load(windowID: windowID)
                return value
            } catch {
                failureIsBlock = false
                failure = error as? GroupSafetyError ?? .unknownOutcome
                await load(windowID: windowID)
                return nil
            }
        }
    }
}

#if DEBUG || INTERNAL_PRESENTATION
/// Test builds: reports on this iPhone alone. Nothing is encrypted or sent;
/// a report is "received" at once, and the answer is tried with a button.
@MainActor
final class GroupReportingPrototype: GroupReportingService {
    private static let key = "debug.groupReports.v1"
    private static let blockKey = "debug.groupBlocks.v1"

    var isAvailable: Bool { InternalBuildPresentationAvailability.isAvailable }

    private var all: [GroupReportRecord] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.key) else { return [] }
            return (try? JSONDecoder().decode([GroupReportRecord].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.key) }
    }

    func prepareReport(windowID: String, photoID: String, senderName: String,
                       reason: GroupReportReason, consent: GroupReportConsent) async throws -> String {
        if all.contains(where: { $0.windowID == windowID && $0.photoID == photoID && $0.progress == .received }) {
            throw GroupSafetyError.alreadyReported
        }
        let record = GroupReportRecord(id: UUID().uuidString, windowID: windowID, photoID: photoID,
                                       senderName: senderName, reason: reason, progress: .preparing,
                                       reply: .none, sentAt: consent.acceptedAt)
        all.append(record)
        return record.id
    }

    func submitReport(draftID: String) async throws -> GroupReportRecord {
        try update(draftID) {
            $0.progress = .received
            if $0.receiptNumber == nil { $0.receiptNumber = Self.sampleReceiptNumber() }
        }
    }

    /// Test only: the same shape as the server's numbers (R-XXXX-XXXX-XX).
    private static func sampleReceiptNumber() -> String {
        let letters = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let body = String((0..<10).map { _ in letters.randomElement()! })
        let a = body.prefix(4), b = body.dropFirst(4).prefix(4), c = body.suffix(2)
        return "R-\(a)-\(b)-\(c)"
    }

    func resumeReport(draftID: String) async throws -> GroupReportRecord {
        try await submitReport(draftID: draftID)
    }

    func reports(windowID: String) async -> [GroupReportRecord] {
        all.filter { $0.windowID == windowID }.sorted { $0.sentAt > $1.sentAt }
    }

    func refreshReport(draftID: String) async throws -> GroupReportRecord {
        guard let record = all.first(where: { $0.id == draftID }) else { throw GroupSafetyError.notFound }
        return record
    }

    func setBlock(windowID: String, participantID: String, active: Bool, operationID: UUID) async throws {
        var blocks = Set(UserDefaults.standard.stringArray(forKey: Self.blockKey) ?? [])
        let key = windowID + "/" + participantID
        if active { blocks.insert(key) } else { blocks.remove(key) }
        UserDefaults.standard.set(Array(blocks), forKey: Self.blockKey)
    }

    /// Test only: the team's answer arriving for the newest report.
    func tryReply(windowID: String) {
        guard let newest = all.filter({ $0.windowID == windowID && $0.progress == .received })
            .max(by: { $0.sentAt < $1.sentAt }) else { return }
        _ = try? update(newest.id) { $0.reply = .restricted; $0.repliedAt = Date() }
    }

    private func update(_ id: String, _ change: (inout GroupReportRecord) -> Void) throws -> GroupReportRecord {
        var records = all
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw GroupSafetyError.notFound }
        change(&records[index])
        all = records
        return records[index]
    }
}

#endif
