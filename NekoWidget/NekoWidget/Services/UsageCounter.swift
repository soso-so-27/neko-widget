import Foundation
import Photos
import WidgetKit

/// Anonymous daily usage counts (spec 11/7). Main app only.
///
/// `count` changes memory only. The file (Application Support, excluded from
/// backup) is written when the app goes to the background or when the day
/// changes, never per tap or while scrolling. On becoming active, the earlier
/// days (up to 7) are sent once each to Info.plist `UsageReportURL`; an empty
/// or non-https value sends nothing. `setEnabled(false)` stops counting and
/// deletes what is kept; 設定 has no switch since 11/8 (the policy tells it),
/// and an earlier 「オフ」 stays off.
final class UsageCounter: @unchecked Sendable {
    static let shared = UsageCounter()
    /// Settings' toggle. Absent means on (the spec's default).
    static let enabledKey = "usageReporting.enabled"

    private let lock = NSLock()
    private var ledger: UsageLedger?
    private var enabled: Bool
    private var lastDay: String?
    private var sending = false
    private var widgetPlaced = false
    private let calendar = UsageDayKey.calendar()

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func count(_ event: UsageEvent) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        let today = UsageDayKey.string(for: .now, calendar: calendar)
        loadLocked()
        ledger?.record(event, day: today)
        noteDayLocked(today)
    }

    /// Counts `event` the first time it ever happens on this iPhone (cats_found).
    func countFirstTime(_ event: UsageEvent) {
        let key = "usageReporting.first." + event.name
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        count(event)
    }

    /// Settings calls this when the toggle changes. Off deletes the kept days.
    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = value
        guard !value else { return }
        ledger = UsageLedger()
        lastDay = nil
        if let url = Self.fileURL() { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Lifecycle (ProductionAppRootView)

    @MainActor
    func appBecameActive(viewModel: AppViewModel, plus: Bool) async {
        guard isEnabled else { return }
        // WidgetKit unable to answer keeps the last known value.
        let lastWidget = locked { widgetPlaced }
        let widget = await Self.anyWidgetPlaced() ?? lastWidget
        let state = Self.state(viewModel: viewModel, plus: plus, widget: widget)
        let today = UsageDayKey.string(for: .now, calendar: calendar)
        let endpoint = Self.endpoint()
        let jobs: [UsageDayRecord] = locked {
            widgetPlaced = widget
            guard enabled else { return [] }
            loadLocked()
            ledger?.markOpened(day: today)
            ledger?.setState(state, day: today)
            ledger?.prune(today: today, calendar: calendar)
            noteDayLocked(today)
            guard endpoint != nil, !sending else { return [] }
            let pending = ledger?.pending(today: today, calendar: calendar) ?? []
            sending = !pending.isEmpty
            return pending
        }
        guard let endpoint, !jobs.isEmpty else { return }
        // Not tied to the view's task: a short trip to Control Center must not
        // cancel the sends.
        Task.detached(priority: .utility) { await self.send(jobs, to: endpoint, fallbackState: state) }
    }

    private func send(_ jobs: [UsageDayRecord], to endpoint: URL, fallbackState state: UsageState) async {
        let sender = UsageReportSender(endpoint: endpoint)
        for record in jobs {
            let payload = UsageReportPayload(record: record, fallbackState: state,
                                             app: Self.appVersion(), os: Self.osVersion())
            guard let body = try? payload.body(), await sender.post(body) else { continue }
            // Kept in memory until the next background write; a resend before
            // then carries the same batch, which the server counts once.
            locked { ledger?.remove(day: record.day, batch: record.batch) }
        }
        sender.finish()
        locked { sending = false }
    }

    @MainActor
    func appEnteredBackground(viewModel: AppViewModel, plus: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, ledger != nil else { return }
        let today = UsageDayKey.string(for: .now, calendar: calendar)
        ledger?.setState(Self.state(viewModel: viewModel, plus: plus, widget: widgetPlaced), day: today)
        ledger?.prune(today: today, calendar: calendar)
        writeLocked()
    }

    private var isEnabled: Bool { locked { enabled } }

    /// Synchronous, so it is never held across an await.
    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: State

    @MainActor
    private static func state(viewModel: AppViewModel, plus: Bool, widget: Bool) -> UsageState {
        let access: UsagePhotoAccess = switch viewModel.authorizationStatus {
        case .authorized: .full
        case .limited: .limited
        default: UsagePhotoAccess.none
        }
        return UsageState(plus: plus, widget: widget, catCount: viewModel.catProfiles.count,
                          windowCount: GroupWidgetCache.entries().count,
                          family: FamilyNotebookSharing.shared.state.membership != nil,
                          photoAccess: access)
    }

    /// Any of this app's widgets on the Home or Lock Screen; nil if unknown.
    /// Nil when WidgetKit cannot answer. Also read by the review prompt.
    static func anyWidgetPlaced() async -> Bool? {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                guard case let .success(configurations) = result else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: !configurations.isEmpty)
            }
        }
    }

    // MARK: File

    private func noteDayLocked(_ today: String) {
        if let lastDay, lastDay != today { writeLocked() }
        lastDay = today
    }

    private func loadLocked() {
        guard ledger == nil else { return }
        guard let url = Self.fileURL(), let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(UsageLedger.self, from: data) else {
            ledger = UsageLedger(); return
        }
        ledger = stored
    }

    private func writeLocked() {
        guard let ledger, let url = Self.fileURL() else { return }
        if ledger.isEmpty {
            try? FileManager.default.removeItem(at: url); return
        }
        do {
            var directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            try JSONEncoder().encode(ledger).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var file = url
            try? file.setResourceValues(values)
        } catch {
            // Counts are best effort; the next background write tries again.
        }
    }

    private static func fileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("UsageCounts", isDirectory: true)
            .appendingPathComponent("days.json")
    }

    // MARK: Report fields

    /// Info.plist `UsageReportURL`; only an https URL with a host is used.
    static func endpoint() -> URL? {
        guard let value = (Bundle.main.object(forInfoDictionaryKey: "UsageReportURL") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, let url = URL(string: value),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func appVersion() -> String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    private static func osVersion() -> String {
        String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}

/// The one network path of usage counts: POST the JSON body, nothing else.
/// Ephemeral session, no cookies, no cache, no redirects, 15 seconds.
private final class UsageReportSender: Sendable {
    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration, delegate: UsageReportNoRedirect(), delegateQueue: nil)
    }

    /// True only for 200 or 204.
    func post(_ body: Data) async -> Bool {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let reply = try? await session.data(for: request),
              let status = (reply.1 as? HTTPURLResponse)?.statusCode else { return false }
        return status == 200 || status == 204
    }

    func finish() { session.finishTasksAndInvalidate() }
}

private final class UsageReportNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension UsagePlusEntry {
    /// Every Plus entry place by its short name; a new context must be named here.
    init(_ context: PlusOfferContext) {
        switch context {
        case .onboarding: self = .onboarding
        case .widgetResume: self = .widgetResume
        case .monthlySummary: self = .monthlySummary
        case .newMemo: self = .newMemo
        case .createWindow: self = .createWindow
        case .continueWindow: self = .continueWindow
        case .createFamily: self = .createFamily
        case .continueFamily: self = .continueFamily
        case .preservation: self = .preservation
        case .settings: self = .settings
        }
    }
}
