import Foundation
#if canImport(UIKit)
import UIKit
#endif

// The family notebook between iPhones, as the screens see it (1028c, Codex's
// proposed contract). The screens talk only to `FamilyNotebookSharing`; behind
// it is the prototype on this iPhone now, and the real service later. Leaving,
// taking someone out and ending the family are separate operations, and none
// of them deletes this person's own copy.

/// What the screens hold: the state, and one way to run an operation.
@MainActor
final class FamilyNotebookSharing: ObservableObject {
    static let shared = FamilyNotebookSharing(service: FamilyNotebookServiceFactory.make())

    @Published private(set) var state: FamilySharingState = .checking
    @Published private(set) var pause: FamilySharingPause?
    @Published var failure: FamilySharingError?
    @Published private(set) var isWorking = false
    /// 11/19 (UI/UX 整理): the last whole read did not reach the family. While
    /// the state is still `.checking`, the notebook says 「つながりませんでした」
    /// with 「もう一度」 instead of waiting without end.
    @Published private(set) var readFailed = false
    /// 11/21: a newly approved person is not signed in yet, so writing waits
    /// for everyone; the notebook says so in one line (reading goes on).
    @Published private(set) var awaitsNewMember = false
    private var refreshing = false
    /// A whole read or a requests read is running (11/19: the device push waits for it).
    var isReading: Bool { refreshing }
    /// 11/19: once a launch, the first read that knows the family asks for
    /// the notification permission and token it registers.
    private var askedForPushPreference = false
    /// The last whole-family read that finished, by a tap or by the schedule
    /// (11/15, 1115q: an automatic pass does not repeat one just made).
    private(set) var lastReadAt: Date?
    @Published private(set) var requests: [FamilyNotebookJoinRequest] = []
    @Published private(set) var ownJoinResults: [FamilyNotebookAdmissionClient.JoinResult] = []
    /// 11/16: writing of this iPhone has not reached the family for a while
    /// (FamilyNotebookSendHealth): the notebook shows one line and 「もう一度」.
    @Published private(set) var showsUnsentLine = false
    /// Not sent yet, set-aside writing included (internal builds show it).
    @Published private(set) var unsentCount = 0
    private(set) var sendHealth = FamilyNotebookSharing.savedSendHealth()
    /// 「コード：RJ-3」: the last failure's short code and the number unsent.
    var sendCode: String { FamilyNotebookSendFailure.code(kind: sendHealth.last?.kind, unsent: unsentCount) }
    static let sendHealthKey = "familyNotebook.sendHealth.v1"
    let service: any FamilyNotebookSharingService

    init(service: any FamilyNotebookSharingService) {
        self.service = service
    }

    /// The service takes one call at a time and answers a second one with
    /// unknownOutcome. A read started while the notebook's own check runs
    /// waits for it (a few seconds at most) instead of failing (11/6: the
    /// farewell row went missing and the sheet said 「結果を確かめています」).
    static func waitingForCheck<T>(_ read: () async throws -> T) async throws -> T {
        for attempt in 0..<5 {
            do { return try await read() }
            catch FamilySharingError.unknownOutcome where attempt < 4 {
                try await Task.sleep(for: .seconds(1))
            }
        }
        return try await read()
    }

    /// Background passes stay quiet: only something the person did, or asked to
    /// check again, shows a failure (11/5: the alert repeated while polling).
    /// Returns whether this pass read the family (false when another pass was
    /// already running, or the read failed).
    @discardableResult
    func refresh(reportsFailure: Bool = false) async -> Bool {
        // 1115s: a read the person asked for (pull to refresh, 「もう一度確認」,
        // after their own operation) is theirs; a quiet pass is automatic.
        guard reportsFailure else { return await read(reportsFailure: false) }
        return await SharingPersonAction.run { await read(reportsFailure: true) }
    }

    private func read(reportsFailure: Bool) async -> Bool {
        guard !refreshing else { return false }
        refreshing = true; defer { refreshing = false }
        var notedSend = false
        do {
            let loaded = try await service.loadState()
            // 11/19 (機種変更 水準2): a read that began before the notebook
            // switched to the recovered identity says nothing about it.
            if (service as? ProductionFamilyNotebookSharingService)?.restartPending == true { return false }
            detachIfRevoked(loaded)
            noteSend(); notedSend = true
            // A further pass of a notebook already on screen (more history, a
            // key rotation) keeps it there instead of flipping to 「準備しています」
            // and back every few seconds (11/5: the open notebook jolted).
            let syncing = loaded == .waitingForKeys && state.membership != nil
            let next = syncing ? state : loaded
            let nextPause = next.membership == nil ? nil : syncing ? pause : try await service.loadPause()
            // Unchanged values are not published again, so the list is not redrawn.
            if next != state {
                // Usage (11/7): this iPhone's request to join was let in.
                if state == .pendingApproval, next == .waitingForKeys || next.membership != nil {
                    UsageCounter.shared.count(.familyJoined)
                }
                state = next
            }
            // Only a settled answer moves the mark; a checking pass keeps it.
            // Let in but without the notebook's key yet is still waiting
            // (11/15: this device registers itself and the family's key
            // reaches it over the next passes).
            switch next {
            case .pendingApproval, .waitingForKeys: Self.noteAwaitingApproval(true)
            case .notInFamily, .inFamily: Self.noteAwaitingApproval(false)
            default: break
            }
            if nextPause != pause { pause = nextPause }
            if let real = service as? ProductionFamilyNotebookSharingService {
                let waits = real.awaitingNewMember && next.membership != nil
                if waits != awaitsNewMember { awaitsNewMember = waits }
                if ownJoinResults != real.lastJoinResults { ownJoinResults = real.lastJoinResults }
                FamilyNotebookPrototype.shared.attachReal(real, reportsFailure: reportsFailure)
                // Read even while keys follow a change: an approval itself
                // starts that pass, and the approved person must leave the
                // list at once (11/15: they stayed with 受け入れる under them).
                let nextRequests = next.membership == nil ? [] : try await real.pendingRequests()
                if nextRequests != requests { requests = nextRequests }
                // 11/19: the family is known: the notebook's push registration
                // follows the notification permission and token (GroupAdmissionService).
                #if canImport(UIKit)
                if real.needsPushPreference, !askedForPushPreference {
                    askedForPushPreference = true
                    Task { await GroupAdmissionService.shared.refresh(force: true) }
                }
                #endif
            }
            // 11/19 (UI/UX 整理): the family as last shown is kept after every
            // read that knows it (joining, approving, pulling to refresh), not
            // only the schedule's, so the notebook opens as itself next time
            // instead of a placeholder. Written only when
            // it changed (rememberShown), never while scrolling.
            if let membership = next.membership { FamilyNotebookPrototype.shared.rememberShown(membership) }
            // 11/19: the family stopped listing this person (taken out, or the
            // family ended): the notebook says so in one line, for a week.
            if next == .notInFamily { FamilyNotebookPrototype.shared.noteEndedNotice() }
            if readFailed { readFailed = false }
            lastReadAt = Date()
            return true
        } catch is CancellationError {
            // Leaving the screen is not a service failure.
            return false
        } catch {
            if !notedSend { noteSend() }
            if !readFailed { readFailed = true }
            if reportsFailure { failure = error as? FamilySharingError ?? .serviceUnavailable }
            return false
        }
    }

    /// 11/19 (機種変更 水準2): the recovery screen linked this iPhone to the
    /// person's notebook. The next read opens it with the recovered identity;
    /// what the identity before it showed is not kept as that notebook's
    /// state (it used to be: a member's 「in the family」 stood for the new
    /// device still waiting for its keys, and the recovery screen closed).
    func restartSession() {
        (service as? ProductionFamilyNotebookSharingService)?.restartSession()
        state = .checking; pause = nil; requests = []; ownJoinResults = []; readFailed = false; awaitsNewMember = false
    }

    /// 11/20 (GroupIdentityDeletionLocalData): restartSession, then waits (up
    /// to 10 s) for a read or call already running on the identity before it,
    /// so none writes into its stores after they are removed.
    func stopForIdentityDeletion() async {
        restartSession()
        let production = service as? ProductionFamilyNotebookSharingService
        for _ in 0..<100 {
            guard refreshing || production?.callRunning == true else { return }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }

    /// 11/15 (TestFlight 378): after Plus was bought or confirmed on this
    /// iPhone. A background pass already running may have read the family
    /// before the Plus, and a second call during it was dropped, so
    /// 「共有が止まっています」 stayed under 「Plusを確認できました。」. Waits
    /// for that pass, then reads the family again, saying if it failed.
    @discardableResult
    func refreshAfterPlusChange(reportsFailure: Bool = true) async -> Bool {
        while refreshing {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return false }
        }
        return await refresh(reportsFailure: reportsFailure)
    }

    /// 11/16: pulled down on a page of a cat in the family notebook (「この子の
    /// こと」, the cat's page in この子). The person's own read of the notebook,
    /// once: it waits for a pass already running instead of being dropped
    /// behind it, and what it brings goes into 「この子のこと」 (attachReal).
    /// Quiet, as the pages say nothing about the notebook's state.
    func readPulled() async {
        guard FamilyNotebookPrototype.shared.isReal, FamilyNotebookPrototype.shared.hasFamily else { return }
        await SharingPersonAction.run { _ = await refreshAfterPlusChange(reportsFailure: false) }
    }

    // MARK: Writing that did not reach the family (11/16)

    private static func savedSendHealth() -> FamilyNotebookSendHealth {
        guard let data = UserDefaults.standard.data(forKey: sendHealthKey),
              let saved = try? JSONDecoder().decode(FamilyNotebookSendHealth.self, from: data) else { return .init() }
        return saved
    }

    /// After each whole read: what it did about this iPhone's writing. Kept
    /// on this iPhone only, the kind and the time (no content, no IDs).
    private func noteSend(now: Date = Date()) {
        guard let real = service as? ProductionFamilyNotebookSharingService else { return }
        let unsent = (try? real.notebook?.snapshot().outbox.count) ?? 0
        var next = sendHealth
        next.record(real.lastSend, unsent: unsent, at: now)
        if next.persisted != sendHealth.persisted, let data = try? JSONEncoder().encode(next) {
            // Only when the kind or the start of the failing changes.
            UserDefaults.standard.set(data, forKey: Self.sendHealthKey)
        }
        sendHealth = next
        if unsent != unsentCount { unsentCount = unsent }
        let shows = next.showsLine(unsent: unsent, now: now)
        if shows != showsUnsentLine { showsUnsentLine = shows }
    }

    /// 「もう一度」 under 「家族に届けられていない書き込みがあります。」: the
    /// person's own read, which tries the set-aside writing again too. Quiet:
    /// the line stays while it still does not go, and goes once it has.
    func resendUnsent() async {
        await SharingPersonAction.run {
            while refreshing {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            (service as? ProductionFamilyNotebookSharingService)?.retriesHeldOnce = true
            _ = await read(reportsFailure: false)
        }
    }

    /// Runs one operation with a fresh ID, then reads the state again.
    /// `readsAfter: false` only where nothing on screen waits for that read
    /// (an invitation link: the share sheet opens first, 11/15).
    @discardableResult
    func perform(readsAfter: Bool = true, _ operation: (UUID) async throws -> Void) async -> Bool {
        // 1115s: the person's own action, outside the automatic budget.
        return await SharingPersonAction.run {
            // A background pass in flight must not swallow the person's tap.
            while refreshing {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return false }
            }
            guard !Task.isCancelled, !isWorking else { return false }
            isWorking = true
            defer { isWorking = false }
            do {
                try await operation(UUID())
                if readsAfter { await refreshAfterChange() }
                // A made family, a join or an approval: the schedule takes over.
                FamilyNotebookAutoCheck.shared.nudge()
                return true
            } catch is CancellationError {
                return false
            } catch {
                // 11/20: the device was taken off: the read below shows the
                // entrance; no error for it.
                if (service as? ProductionFamilyNotebookSharingService)?.revokedDetachPending != true {
                    failure = error as? FamilySharingError ?? .unknownOutcome
                }
                await refreshAfterChange()
                return false
            }
        }
    }

    /// 11/20: the relay said the pair whose copy this iPhone shows was taken
    /// off by another iPhone of the same person (or a mark from before, after
    /// a relaunch). The notebook returns to its entrance, as for a person with
    /// no notebook: not the ended notice, no error. The binding and the
    /// waiting mark go; the copy stays on disk with what waits to be sent.
    private func detachIfRevoked(_ loaded: FamilySharingState) {
        guard let real = service as? ProductionFamilyNotebookSharingService else { return }
        let model = FamilyNotebookPrototype.shared
        guard real.takeRevokedDetach() || (loaded == .notInFamily && model.showsRevokedPair(real)) else { return }
        model.detachRevoked()
        Self.noteAwaitingApproval(false)
    }

    /// The read after a change is never dropped behind a background pass.
    private func refreshAfterChange() async {
        while refreshing {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
        await refresh()
    }

    /// 11/15 (1115q): 「参加を待っている人」 only, for the open notebook's
    /// 20-second check; not the whole family (directory and requests).
    @discardableResult
    func refreshRequests() async -> Bool {
        guard !refreshing, state.membership != nil,
              let real = service as? ProductionFamilyNotebookSharingService else { return false }
        refreshing = true; defer { refreshing = false }
        do {
            let next = try await real.pendingRequests()
            if next != requests { requests = next }
            return true
        } catch {
            return false
        }
    }

    /// 11/15: an approved or declined request leaves the list as soon as the
    /// relay took the answer, before the next read.
    func forgetRequest(_ id: UUID) {
        requests.removeAll { $0.id == id }
    }

    static var awaitingApproval: Bool { UserDefaults.standard.bool(forKey: FamilyNotebookAwaitingApproval.key) }
    /// Never settled on this iPhone: an app from before 11/15 asked to join
    /// without leaving the mark. One read settles it either way.
    static var awaitingApprovalUnknown: Bool { UserDefaults.standard.object(forKey: FamilyNotebookAwaitingApproval.key) == nil }
    private static func noteAwaitingApproval(_ value: Bool) {
        guard awaitingApproval != value || awaitingApprovalUnknown else { return }
        UserDefaults.standard.set(value, forKey: FamilyNotebookAwaitingApproval.key)
        if value { FamilyNotebookAutoCheck.shared.nudge() }
    }
}

/// 11/15 (1115q): the family notebook's one automatic schedule. Coming to
/// the front, the notebook's screen and a shared tool's screen used to run
/// three loops of their own (the notebook's every 5 s without end while keys
/// moved); now they only say what is on screen, and this one loop decides
/// when to read again (`FamilyAutoCheckPolicy`). Its calls are automatic:
/// the transport keeps them within this iPhone's budget.
@MainActor
final class FamilyNotebookAutoCheck {
    static let shared = FamilyNotebookAutoCheck()

    enum Screen { case notebook, tool, photo }

    private var notebookScreens = 0
    private var toolScreens = 0
    private var photoScreens = 0
    private var active = false
    /// A sheet is open over the notebook: the list is not redrawn under it.
    var holdsRedraw = false
    private var loop: Task<Void, Never>?
    private var sleeping = false
    private var plannedAt: Date?
    private var plannedPass: FamilyAutoCheckPolicy.Pass = .full
    private var lastPassAt: Date?
    private var lastFullAt: Date?
    private var lastMark: String?
    private var quietKeyPasses = 0

    private var sharing: FamilyNotebookSharing { .shared }
    private var model: FamilyNotebookPrototype { .shared }

    private var lastResumeProbeAt: Date?

    /// 11/20: this iPhone holds an identity the notebook could use (the
    /// service's own Keychain check, no network). Asked once per launch, only
    /// while nothing was read yet.
    private var hasNotebookIdentity: Bool?

    private var unreadThisLaunch: Bool {
        FamilyAutoCheckPolicy.unreadThisLaunch(lastReadAt: sharing.lastReadAt, checking: sharing.state == .checking)
    }

    private var eligible: Bool {
        FamilyAutoCheckPolicy.eligible(.init(real: model.isReal, hasFamily: model.hasFamily,
            awaitingApproval: FamilyNotebookSharing.awaitingApproval,
            awaitingApprovalUnknown: FamilyNotebookSharing.awaitingApprovalUnknown,
            unreadThisLaunch: unreadThisLaunch, hasIdentity: hasNotebookIdentity == true,
            resumeProbeDue: resumeProbeDue))
    }

    /// 11/18: a notebook that ended only because the directory stopped listing
    /// the family (FamilyNotebookEndReason.mayResume) is read again on coming
    /// to the front, at most once per `resumeProbeGap`, so it can come back.
    private var resumeProbeDue: Bool {
        !model.hasFamily && model.mayResumeEndedNotebook
            && (lastResumeProbeAt.map { Date().timeIntervalSince($0) >= FamilyAutoCheckPolicy.resumeProbeGap } ?? true)
    }

    func setActive(_ value: Bool) {
        active = value
        if value { wake(gap: FamilyAutoCheckPolicy.wakeGap) }
        // The plan is kept: coming back soon keeps its pass (a 20 s list read
        // stays a list read); a plan already past becomes a whole read.
        else { loop?.cancel(); loop = nil; sleeping = false; sendBeforeLeaving() }
    }

    #if canImport(UIKit)
    private var leavingSend: Task<Void, Never>?
    private var leavingHandle: UIBackgroundTaskIdentifier = .invalid

    /// 11/16: the app leaves the screen with writing of this iPhone not sent
    /// yet (written, then the iPhone locked at once). It used to wait until
    /// the app came back; now one pass runs in the time iOS gives a leaving
    /// app. Automatic, within the budget; nothing when all was sent.
    private func sendBeforeLeaving() {
        guard leavingSend == nil, eligible, model.hasFamily, model.snapshot?.outbox.isEmpty == false,
              !sharing.isWorking else { return }
        // UIKit calls the expiration on the main thread.
        let handle = UIApplication.shared.beginBackgroundTask(withName: "Send family notebook") { [weak self] in
            MainActor.assumeIsolated {
                self?.leavingSend?.cancel()
                self?.endLeaving()
            }
        }
        guard handle != .invalid else { return }
        leavingHandle = handle
        leavingSend = Task { [weak self] in
            await SharingPersonAction.automatic { _ = await self?.sharing.refresh() }
            self?.endLeaving()
        }
    }

    private func endLeaving() {
        leavingSend = nil
        guard leavingHandle != .invalid else { return }
        UIApplication.shared.endBackgroundTask(leavingHandle)
        leavingHandle = .invalid
    }
    #else
    private func sendBeforeLeaving() -> Void {}  // no UIKit: nothing leaves
    #endif

    /// After an operation, or when this iPhone starts waiting to be let in.
    func nudge() { wake(gap: FamilyAutoCheckPolicy.nudgeGap) }

    /// 11/16: something written on this iPhone waits to be sent. It used to
    /// wait for the next pass of an open screen, or for the app to come to
    /// the front again; now one pass follows (not sooner than 30 s after the
    /// last, so typing never reads more often than a shared tool's screen).
    func sendSoon() { wake(gap: FamilyAutoCheckPolicy.sendGap) }

    func appeared(_ screen: Screen) {
        switch screen { case .notebook: notebookScreens += 1; case .tool: toolScreens += 1; case .photo: photoScreens += 1 }
        wake(gap: FamilyAutoCheckPolicy.wakeGap)
    }

    func disappeared(_ screen: Screen) {
        switch screen {
        case .notebook: notebookScreens = max(0, notebookScreens - 1)
        case .tool: toolScreens = max(0, toolScreens - 1)
        case .photo: photoScreens = max(0, photoScreens - 1)
        }
    }

    /// Something changed what the next pass should be. A loop asleep keeps
    /// its planned pass when sooner, else waits `gap` after the last pass; a
    /// loop mid-pass reads the screens again when its pass ends. Never two loops.
    private func wake(gap: TimeInterval) {
        guard active else { return }
        if loop != nil && !sleeping { return }
        let now = Date()
        let plan = plannedAt.flatMap { $0 >= now ? $0 : nil }
        let delay = FamilyAutoCheckPolicy.wakeDelay(now: now, lastPassAt: lastPassAt, plannedAt: plan, gap: gap)
        let keepsPlan = plan.map { $0.timeIntervalSince(now) <= delay } == true
        let pass = keepsPlan ? plannedPass : .full
        loop?.cancel()
        sleeping = false
        // 1115v: automatic even when a tap (an operation's nudge) started it.
        loop = Task { [weak self] in await SharingPersonAction.automatic { await self?.run(pass: pass, delay: delay) } }
    }

    private func situation(now: Date) -> FamilyAutoCheckPolicy.Situation {
        let real = sharing.service as? ProductionFamilyNotebookSharingService
        return .init(notebookOpen: notebookScreens > 0, toolOpen: toolScreens > 0, photoOpen: photoScreens > 0,
                     keysMove: real?.needsAnotherPass == true,
                     awaitingApproval: FamilyNotebookSharing.awaitingApproval,
                     inFamily: sharing.state.membership != nil,
                     quietKeyPasses: quietKeyPasses,
                     secondsSinceFull: lastFullAt.map { now.timeIntervalSince($0) } ?? .infinity)
    }

    /// The whole-family pass: the read (keys and roster included) and what follows it.
    @discardableResult
    private func fullPass() async -> Bool {
        let read = await sharing.refresh()
        if let membership = sharing.state.membership { model.rememberShown(membership) }
        if model.hasFamily {
            try? await model.copyTools(); model.applyFamilyWrites()
            // 11/19: the creator's key photos, and a try again of
            // one that did not go (its own wait), on this schedule.
            await FamilyRepresentativePhotos.shared.syncCreatorPhotos()
        }
        return read
    }

    /// 11/19 (機種変更 水準2): the relay's silent push says a device joined this
    /// person's family notebook (FamilyDeviceRegisteredPush). One full pass
    /// now, so this iPhone signs the new device in and wraps the keys for it
    /// at once. Automatic (this iPhone's call budget), skipped while the
    /// budget is paused, within the time iOS gives.
    ///
    /// 11/19 (build 394): iOS may launch the app in the background for this
    /// push alone; the notebook is opened here first (`reopenIfUnread`). A
    /// pass already running may be a light one (requests only) or may have
    /// read the roster before the device joined: this one waits for it, then
    /// makes its own full pass, instead of being skipped behind it.
    func deviceRegisteredPush() async -> Bool {
        let started = Date()
        model.reopenIfUnread()
        let skip: FamilyDevicePushDiagnostics.Reason? = !model.isReal ? .notReal : !model.hasFamily ? .noFamily
            : SharingAutoCallBudget.shared.pausedUntil() == nil ? nil : .budgetPaused
        if let skip {
            FamilyDevicePushDiagnostics.finished(.skipped, since: started, reason: skip)
            return false
        }
        let waited = pushBusyReason
        let work = Task { () -> Bool in
            while pushBusyReason != nil, Date().timeIntervalSince(started) < Self.pushWaitLimit {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return false }
            }
            return await SharingPersonAction.automatic { await fullPass() }
        }
        #if canImport(UIKit)
        // UIKit calls the expiration on the main thread.
        let handle = UIApplication.shared.beginBackgroundTask(withName: "Family notebook device") {
            MainActor.assumeIsolated { work.cancel() }
        }
        let read = await work.value
        if handle != .invalid { UIApplication.shared.endBackgroundTask(handle) }
        #else
        let read = await work.value
        #endif
        if read { lastPassAt = Date(); lastFullAt = lastPassAt }
        FamilyDevicePushDiagnostics.finished(read ? .read : .notRead, since: started, reason: waited)
        return read
    }

    /// The push waits at most this long for a pass in flight, then makes its
    /// own (a read still running then makes it end unread).
    static let pushWaitLimit: TimeInterval = 20

    /// What the device push waits for: a person's operation (`working`), or
    /// a pass of the schedule, a leaving send or another read (`passRunning`).
    private var pushBusyReason: FamilyDevicePushDiagnostics.Reason? {
        if sharing.isWorking { return .working }
        if (loop != nil && !sleeping) || sharing.isReading { return .passRunning }
        return nil
    }

    private func run(pass first: FamilyAutoCheckPolicy.Pass, delay firstDelay: TimeInterval) async {
        var pass = first, delay = firstDelay
        while !Task.isCancelled {
            if hasNotebookIdentity == nil, model.isReal, unreadThisLaunch,
               let real = sharing.service as? ProductionFamilyNotebookSharingService {
                hasNotebookIdentity = await real.hasLocalIdentity()
            }
            guard eligible else { break }
            // The budget is paused after a 429: wait it out, at least a minute.
            if let paused = SharingAutoCallBudget.shared.pausedUntil() {
                delay = max(delay, paused.timeIntervalSinceNow)
            }
            if delay > 0 {
                plannedAt = Date().addingTimeInterval(delay); plannedPass = pass
                sleeping = true
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                sleeping = false
            }
            plannedAt = nil
            // A whole-family read by a tap meanwhile stands for this pass.
            var read = false
            if pass == .full, let at = sharing.lastReadAt, Date().timeIntervalSince(at) < FamilyAutoCheckPolicy.keyBackoff[0],
               lastPassAt.map({ at > $0 }) ?? true {
                lastPassAt = at; lastFullAt = at; read = true
            } else if !holdsRedraw && !sharing.isWorking {
                // Unmarked: automatic, within this iPhone's call budget (1115s).
                switch pass {
                case .full:
                    if !model.hasFamily && model.mayResumeEndedNotebook { lastResumeProbeAt = Date() }
                    await fullPass()
                case .requestsOnly:
                    await sharing.refreshRequests()
                }
                let now = Date()
                lastPassAt = now
                if pass == .full { lastFullAt = now; read = true }
            }
            if read {
                // Progress: anything the key pass saw changed. Quiet passes
                // in a row lengthen the wait (5, 10, 20, 40, 60 s).
                let real = sharing.service as? ProductionFamilyNotebookSharingService
                let mark = "\(sharing.state)|\(real?.lastKeyObservation ?? "")|\(real?.needsAnotherPass == true)"
                quietKeyPasses = mark == lastMark ? quietKeyPasses + 1 : 0
                lastMark = mark
            }
            guard !Task.isCancelled else { return }
            guard let decision = FamilyAutoCheckPolicy.next(situation(now: Date())) else { break }
            pass = decision.pass
            delay = decision.after
        }
        if !Task.isCancelled { loop = nil; sleeping = false; plannedAt = nil }
    }
}

/// 11/15: this iPhone asked to join and waits for the family. Kept so the
/// app checks again when opened, and 設定 keeps a way to the notebook.
enum FamilyNotebookAwaitingApproval {
    static let key = "familyNotebookAwaitingApproval"
}

/// Test builds: the family on this iPhone alone (FamilyNotebookPrototype).
/// Nothing is sent; the invitation is the tried member's.
@MainActor
final class FamilyNotebookPrototypeSharing: FamilyNotebookSharingService {
    private var model: FamilyNotebookPrototype { .shared }
    /// Test only, kept in memory: the payer left, and whether this person
    /// became the payer afterwards.
    private var pretendedPause: FamilySharingPause?
    private var claimedPayer = false
    /// Test only, kept in memory: the one person asked to take over paying,
    /// and whether this person had Plus when asked.
    private var nomination: (id: UUID, personID: String)?
    private var nomineeHasPlus = false
    private var generation: Int64 = 1

    var sendsInvitations: Bool { false }

    private var isPayer: Bool {
        claimedPayer || (!model.joinedSomeonesFamily && pretendedPause == nil)
    }

    private var me: String { FamilyNotebookPrototype.me.personID }

    func loadHandover() async throws -> FamilyPayerHandover {
        guard model.hasFamily, let familyID = model.snapshot?.familyID else { throw FamilySharingError.notAvailableYet }
        var payer: String? = isPayer ? me : FamilyNotebookPrototype.tryout.personID
        if case .noPayer = pretendedPause { payer = nil }
        let nominee = nomination?.personID
        return FamilyPayerHandover(
            schemaVersion: 1, familyId: familyID, generation: generation,
            payerPersonId: payer, nominationId: nomination?.id, nomineePersonId: nominee,
            canNominate: payer == me && nomination == nil,
            canAccept: nominee == me && nomineeHasPlus,
            canCancel: nomination != nil && (payer == me || nominee == me),
            nominationState: .confirmed)
    }

    func nominatePayer(personID: String, expectedGeneration: Int64, operationID: UUID) async throws {
        guard expectedGeneration == generation else { throw FamilySharingError.staleRoster }
        guard isPayer, nomination == nil, personID != me else { throw FamilySharingError.notAllowed }
        nomination = (UUID(), personID)
        generation += 1
    }

    /// Taking it over: the nominee becomes the payer, and the family goes on.
    func acceptPayer(nominationID: UUID, expectedGeneration: Int64, operationID: UUID) async throws {
        guard expectedGeneration == generation else { throw FamilySharingError.staleRoster }
        guard nomination?.id == nominationID, nomination?.personID == me else { throw FamilySharingError.notAllowed }
        guard nomineeHasPlus else { throw FamilySharingError.plusRequired }
        nomination = nil
        pretendedPause = nil
        claimedPayer = true
        generation += 1
    }

    /// The payer taking the request back, or the nominee saying no.
    func cancelPayerNomination(nominationID: UUID, expectedGeneration: Int64, operationID: UUID) async throws {
        guard expectedGeneration == generation else { throw FamilySharingError.staleRoster }
        guard nomination?.id == nominationID else { throw FamilySharingError.notAllowed }
        nomination = nil
        generation += 1
    }

    func loadState() async throws -> FamilySharingState {
        guard model.hasFamily else { return .notInFamily }
        return .inFamily(FamilyMembership(role: isPayer ? .payer : .member))
    }

    func loadPause() async throws -> FamilySharingPause? {
        model.hasFamily ? pretendedPause : nil
    }

    /// 「家族（試し）が Plus を使っていて抜けたときを試す」: as the server would say it, with this
    /// person's Plus as the only thing deciding `canClaim`.
    func pretendPayerLeft(hasPlus: Bool) {
        // Someone already asked keeps the request; nobody claims first then.
        pretendedPause = .noPayer(canClaim: hasPlus && nomination == nil, handoverPending: nomination != nil)
        claimedPayer = false
        if nomination?.personID == me { nomineeHasPlus = hasPlus }
        // The one who was paying is gone from the list, as after a real leave.
        model.removeMember(personID: FamilyNotebookPrototype.tryout.personID)
    }

    private func forgetHandover() {
        pretendedPause = nil; claimedPayer = false; nomination = nil
        consentedFarewells = [:]; farewellPreviews = [:]
    }

    // Test only, kept in memory: which cats' farewell days this person
    // agreed to show the tried family. Nothing leaves this iPhone.
    private var consentedFarewells: [UUID: String] = [:]
    private var farewellPreviews: [UUID: (toolCatID: UUID, day: String)] = [:]

    private func localFarewell(_ toolCatID: UUID) throws -> (day: String?, name: String) {
        guard model.hasFamily else { throw FamilySharingError.removedOrDissolved }
        let cat = CatCareStore.shared.state?.cats.first { $0.catID == toolCatID }
        let day = try? FamilyNotebookPrivateFarewell.day(json: UserDefaults.standard.string(forKey: CatFarewell.key) ?? "",
                                                         toolCatID: toolCatID, profileID: cat?.profileID)
        return (day, cat?.name?.value ?? "この子")
    }

    func loadFarewellSharing(toolCatID: UUID) async throws -> FamilyFarewellSharingState {
        let local = try localFarewell(toolCatID)
        let consented = consentedFarewells[toolCatID]
        return FamilyFarewellSharingState(
            familyID: model.snapshot?.familyID ?? toolCatID, familyCatID: toolCatID,
            localDay: local.day, consentedDay: consented, sharedDay: consented,
            sharedAuthor: consented == nil ? nil : FamilyNotebookPrototype.me,
            sharingPending: false, revocationPending: false, mayAlreadyHaveBeenShared: consented != nil)
    }

    func previewFarewellSharing(toolCatID: UUID) async throws -> FamilyFarewellPreview {
        let local = try localFarewell(toolCatID)
        guard let day = local.day else { throw FamilySharingError.farewellDayMissing }
        let preview = FamilyFarewellPreview(
            id: UUID(), familyID: model.snapshot?.familyID ?? toolCatID, familyCatID: toolCatID,
            catName: local.name, day: day, currentSharedDay: consentedFarewells[toolCatID],
            currentSharedAuthor: consentedFarewells[toolCatID] == nil ? nil : FamilyNotebookPrototype.me,
            expiresAt: Date().addingTimeInterval(600))
        farewellPreviews[preview.id] = (toolCatID, day)
        return preview
    }

    func consentToShareFarewell(previewID: UUID, operationID: UUID) async throws {
        guard let prepared = farewellPreviews[previewID],
              try localFarewell(prepared.toolCatID).day == prepared.day else { throw FamilySharingError.farewellPreviewChanged }
        consentedFarewells[prepared.toolCatID] = prepared.day
        farewellPreviews[previewID] = nil
    }

    func revokeFarewellSharing(toolCatID: UUID, operationID: UUID) async throws {
        _ = try localFarewell(toolCatID)
        consentedFarewells[toolCatID] = nil
    }

    func claimPayer(operationID: UUID) async throws {
        guard case .noPayer(canClaim: true, _)? = pretendedPause else { throw FamilySharingError.plusRequired }
        pretendedPause = nil
        claimedPayer = true
    }

    func createFamily(operationID: UUID) async throws {
        guard !model.hasFamily else { throw FamilySharingError.alreadyInFamily }
        await model.create()
        guard model.hasFamily else { throw FamilySharingError.unsupported }
    }

    func createInvitation(operationID: UUID) async throws -> FamilyInvitation {
        throw FamilySharingError.notAvailableYet
    }

    func previewInvitation(_ link: URL?) async throws -> FamilyInvitationPreview {
        FamilyInvitationPreview(inviterName: FamilyNotebookPrototype.tryout.displayName,
                                catNames: model.catNames, expiresAt: nil)
    }

    func join(_ invitation: FamilyInvitationPreview, operationID: UUID) async throws -> FamilyJoinResult {
        guard !model.hasFamily else { throw FamilySharingError.alreadyInFamily }
        await model.join()
        guard model.hasFamily else { throw FamilySharingError.unsupported }
        return .joined
    }

    /// The prototype's own copy is 「この子のこと」, which stays; only the
    /// tried family on this iPhone ends.
    func leaveFamily(operationID: UUID) async throws -> FamilyExitResult {
        try model.leavePrototypeFamily()
        forgetHandover()
        return .confirmed
    }

    func removeMember(personID: String, operationID: UUID) async throws {
        guard model.hasFamily, isPayer else { throw FamilySharingError.notAllowed }
        model.removeMember(personID: personID)
        if nomination?.personID == personID { nomination = nil; generation += 1 }
    }

    func dissolveFamily(operationID: UUID) async throws -> FamilyExitResult {
        guard model.hasFamily, isPayer else { throw FamilySharingError.notAllowed }
        model.endPrototypeFamily()
        forgetHandover()
        return .confirmed
    }
}
