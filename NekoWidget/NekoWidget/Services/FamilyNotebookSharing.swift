import Foundation

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
    private var refreshing = false
    /// The last whole-family read that finished, by a tap or by the schedule
    /// (11/15, 1115q: an automatic pass does not repeat one just made).
    private(set) var lastReadAt: Date?
    @Published private(set) var requests: [FamilyNotebookJoinRequest] = []
    @Published private(set) var ownJoinResults: [FamilyNotebookAdmissionClient.JoinResult] = []
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
        guard !refreshing else { return false }
        refreshing = true; defer { refreshing = false }
        do {
            let loaded = try await service.loadState()
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
                if ownJoinResults != real.lastJoinResults { ownJoinResults = real.lastJoinResults }
                FamilyNotebookPrototype.shared.attachReal(real, reportsFailure: reportsFailure)
                // Read even while keys follow a change: an approval itself
                // starts that pass, and the approved person must leave the
                // list at once (11/15: they stayed with 受け入れる under them).
                let nextRequests = next.membership == nil ? [] : try await real.pendingRequests()
                if nextRequests != requests { requests = nextRequests }
            }
            lastReadAt = Date()
            return true
        } catch is CancellationError {
            // Leaving the screen is not a service failure.
            return false
        } catch {
            if reportsFailure { failure = error as? FamilySharingError ?? .serviceUnavailable }
            return false
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

    /// Runs one operation with a fresh ID, then reads the state again.
    /// `readsAfter: false` only where nothing on screen waits for that read
    /// (an invitation link: the share sheet opens first, 11/15).
    @discardableResult
    func perform(readsAfter: Bool = true, _ operation: (UUID) async throws -> Void) async -> Bool {
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
            failure = error as? FamilySharingError ?? .unknownOutcome
            await refreshAfterChange()
            return false
        }
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

    enum Screen { case notebook, tool }

    private var notebookScreens = 0
    private var toolScreens = 0
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

    private var eligible: Bool {
        model.isReal && (model.hasFamily || FamilyNotebookSharing.awaitingApproval
            || FamilyNotebookSharing.awaitingApprovalUnknown)
    }

    func setActive(_ value: Bool) {
        active = value
        if value { wake(gap: FamilyAutoCheckPolicy.wakeGap) }
        // The plan is kept: coming back soon keeps its pass (a 20 s list read
        // stays a list read); a plan already past becomes a whole read.
        else { loop?.cancel(); loop = nil; sleeping = false }
    }

    /// After an operation, or when this iPhone starts waiting to be let in.
    func nudge() { wake(gap: FamilyAutoCheckPolicy.nudgeGap) }

    func appeared(_ screen: Screen) {
        switch screen { case .notebook: notebookScreens += 1; case .tool: toolScreens += 1 }
        wake(gap: FamilyAutoCheckPolicy.wakeGap)
    }

    func disappeared(_ screen: Screen) {
        switch screen {
        case .notebook: notebookScreens = max(0, notebookScreens - 1)
        case .tool: toolScreens = max(0, toolScreens - 1)
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
        loop = Task { [weak self] in await self?.run(pass: pass, delay: delay) }
    }

    private func situation(now: Date) -> FamilyAutoCheckPolicy.Situation {
        let real = sharing.service as? ProductionFamilyNotebookSharingService
        return .init(notebookOpen: notebookScreens > 0, toolOpen: toolScreens > 0,
                     keysMove: real?.needsAnotherPass == true,
                     awaitingApproval: FamilyNotebookSharing.awaitingApproval,
                     inFamily: sharing.state.membership != nil,
                     quietKeyPasses: quietKeyPasses,
                     secondsSinceFull: lastFullAt.map { now.timeIntervalSince($0) } ?? .infinity)
    }

    private func run(pass first: FamilyAutoCheckPolicy.Pass, delay firstDelay: TimeInterval) async {
        var pass = first, delay = firstDelay
        while !Task.isCancelled {
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
                await SharingAutoCallBudget.$isAutomatic.withValue(true) {
                    switch pass {
                    case .full:
                        await sharing.refresh()
                        if let membership = sharing.state.membership { model.rememberShown(membership) }
                        if model.hasFamily { try? await model.copyTools(); model.applyFamilyWrites() }
                    case .requestsOnly:
                        await sharing.refreshRequests()
                    }
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
