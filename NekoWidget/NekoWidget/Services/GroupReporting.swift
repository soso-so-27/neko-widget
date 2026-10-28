import Foundation

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
}

enum GroupSafetyError: Error, Equatable, Sendable {
    case notAuthorized, notFound, alreadyReported, conflict
    case consentRequired, reservationExpired
    case dailyLimit, rateLimited
    case disabled, unknownOutcome, offline
    case authenticationRequired, invalidResponse
    case blockSelf

    var message: String {
        switch self {
        case .notAuthorized: "いまは送れません。届いた写真はそのままです。"
        case .notFound: "この写真の状態を確かめられませんでした。"
        case .alreadyReported: "この写真はもう通報しています。"
        case .conflict: "送信の内容が合いませんでした。開き直してからお試しください。"
        case .consentRequired: "もう一度、送る内容を確かめてください。"
        case .reservationExpired: "受付の期限が切れました。"
        case .dailyLimit: "きょうはこれ以上通報できません。明日お試しください。"
        case .rateLimited: "少し待ってから、もう一度お試しください。"
        case .disabled: "いまは通報を受け付けていません。"
        case .unknownOutcome, .offline: "送れたか確かめられませんでした。「もう一度送る」で続きから送ります。"
        case .authenticationRequired: "もう一度サインインしてください。"
        case .invalidResponse: "いまは使えません。少し待ってから、もう一度お試しください。"
        case .blockSelf: "自分はブロックできません。"
        }
    }
}

@MainActor
protocol GroupReportingService: AnyObject {
    /// False hides reporting and blocking (the server flags are off by default).
    var isAvailable: Bool { get }
    /// Fixes the photo, reason and consent, encrypts and keeps the draft. Nothing is sent yet.
    func prepareReport(windowID: String, photoID: String, senderName: String,
                       reason: GroupReportReason, consent: GroupReportConsent) async throws -> String
    /// reserve → upload → commit, until the team has it.
    func submitReport(draftID: String) async throws -> GroupReportRecord
    /// The same draft, the same bytes, from where it stopped.
    func resumeReport(draftID: String) async throws -> GroupReportRecord
    /// This person's reports in this window, kept even after leaving it.
    func reports(windowID: String) async -> [GroupReportRecord]
    /// Asks the server for this exact report's state and answer.
    func refreshReport(draftID: String) async throws -> GroupReportRecord
    func setBlock(windowID: String, participantID: String, active: Bool, operationID: UUID) async throws
}

/// What the screens hold.
@MainActor
final class GroupSafety: ObservableObject {
    static let shared = GroupSafety(service: GroupReportingPrototype())

    @Published private(set) var records: [String: [GroupReportRecord]] = [:]
    @Published var failure: GroupSafetyError?
    @Published private(set) var isWorking = false
    let service: any GroupReportingService

    init(service: any GroupReportingService) {
        self.service = service
    }

    func load(windowID: String) async {
        records[windowID] = await service.reports(windowID: windowID)
    }

    /// Asks again for every report that can still change.
    func refresh(windowID: String) async {
        for record in await service.reports(windowID: windowID)
        where record.progress == .received && record.reply == .none {
            _ = try? await service.refreshReport(draftID: record.id)
        }
        await load(windowID: windowID)
    }

    @discardableResult
    func run<Value>(windowID: String, _ operation: () async throws -> Value) async -> Value? {
        isWorking = true
        defer { isWorking = false }
        do {
            let value = try await operation()
            await load(windowID: windowID)
            return value
        } catch {
            failure = error as? GroupSafetyError ?? .unknownOutcome
            await load(windowID: windowID)
            return nil
        }
    }
}

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
        try update(draftID) { $0.progress = .received }
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
