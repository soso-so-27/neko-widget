import Foundation

// 14日体験（ADR-027・実装計画 1章）の単体検査。Keychain には触れず、記憶上の記録で
// `TrialPeriodStore` と `TrialMembershipMerge` を確かめる。
// Compile: xcrun swiftc -parse-as-library Shared/MembershipAccessPolicy.swift
//   NekoWidget/Services/TrialPeriodStore.swift ci/verify-trial-period.swift

/// 記憶上の記録。読めない記録・書けない状態も作れる。
final class MemoryTrialPersistence: TrialPeriodPersistence {
    var stored: Data?
    var failsLoad = false
    var failsWrite = false
    var inserts = 0
    var updates = 0

    init(stored: Data? = nil) { self.stored = stored }

    var record: TrialPeriodRecord? {
        stored.flatMap { try? TrialPeriodRecordCodec.decode($0) }
    }

    func load() throws -> TrialPeriodRecord? {
        if failsLoad { throw TrialPeriodStoreError.unreadable }
        guard let stored else { return nil }
        return try TrialPeriodRecordCodec.decode(stored)
    }

    func insertIfAbsent(_ record: TrialPeriodRecord) throws -> TrialPeriodRecord {
        if failsWrite { throw TrialPeriodStoreError.unavailable }
        if let stored {
            return try TrialPeriodRecordCodec.decode(stored)
        }
        inserts += 1
        stored = try TrialPeriodRecordCodec.encode(record)
        return record
    }

    func update(_ record: TrialPeriodRecord) throws {
        if failsWrite { throw TrialPeriodStoreError.unavailable }
        updates += 1
        stored = try TrialPeriodRecordCodec.encode(record)
    }
}

final class FakeClock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func read() -> Date { now }
}

@main
enum TrialPeriodVerifier {
    static let day: TimeInterval = 24 * 60 * 60
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let end = start.addingTimeInterval(14 * day)

    static func main() {
        verifyStartsWithoutRecord()
        verifyRollbackDoesNotExtend()
        verifyForwardEndsEarly()
        verifyFourteenDayBoundary()
        verifyUnreadableRecord()
        verifyExistingRecordSurvivesReinstall()
        verifyDay14NoticeOnce()
        verifyCodec()
        verifyMerge()
        verifyWindowsDuringTrial()
        print("PASS trial period: start without record, clock rollback/forward, 14-day boundary, unreadable record, reinstall, day-14 notice once, merge with Plus, windows during the trial")
    }

    static func makeStore(_ persistence: MemoryTrialPersistence, clock: FakeClock) -> TrialPeriodStore {
        TrialPeriodStore(persistence: persistence, clock: clock.read)
    }

    /// 記録がなければ最初の `refresh()` で開始する。読む前は notStarted。
    static func verifyStartsWithoutRecord() {
        let persistence = MemoryTrialPersistence()
        let clock = FakeClock(start)
        let store = makeStore(persistence, clock: clock)
        precondition(store.state == .notStarted, "nothing is decided before the record is read")
        precondition(store.remainingDays == nil && !store.shouldShowDay14Notice)
        precondition(store.refresh() == .active(until: end), "the first refresh starts the 14 days")
        precondition(persistence.inserts == 1, "the start is recorded once")
        precondition(persistence.record?.startedAt == start)
        precondition(persistence.record?.maxObservedNow == start)
        precondition(store.remainingDays == 14, "14 days remain at the start")
        precondition(store.refresh() == .active(until: end) && persistence.inserts == 1,
                     "a second refresh never starts again")
    }

    /// 端末の時刻を戻しても延びない。記録した最大観測時刻を使う。
    static func verifyRollbackDoesNotExtend() {
        let persistence = MemoryTrialPersistence()
        let clock = FakeClock(start)
        let store = makeStore(persistence, clock: clock)
        store.refresh()
        clock.now = start.addingTimeInterval(5 * day)
        store.refresh()
        precondition(store.remainingDays == 9)
        precondition(persistence.record?.maxObservedNow == clock.now, "the maximum observed time is persisted")

        clock.now = start.addingTimeInterval(1 * day)
        store.refresh()
        precondition(store.remainingDays == 9, "rolling the clock back does not restore days")
        precondition(store.state == .active(until: end))
        precondition(persistence.record?.maxObservedNow == start.addingTimeInterval(5 * day),
                     "the maximum observed time never moves backwards")

        // 再起動後（新しいインスタンス）も記録した最大観測時刻が効く。
        let relaunched = makeStore(persistence, clock: FakeClock(start.addingTimeInterval(2 * day)))
        precondition(relaunched.refresh() == .active(until: end))
        precondition(relaunched.remainingDays == 9, "a relaunch with an earlier clock keeps the recorded maximum")
    }

    /// 進めると早く終わる。戻しても終わったまま。
    static func verifyForwardEndsEarly() {
        let persistence = MemoryTrialPersistence()
        let clock = FakeClock(start)
        let store = makeStore(persistence, clock: clock)
        store.refresh()
        clock.now = start.addingTimeInterval(15 * day)
        precondition(store.refresh() == .ended(at: end), "a forward clock ends the period early")
        precondition(persistence.record?.endedAt == end, "the end is recorded")
        precondition(store.remainingDays == nil && !store.shouldShowDay14Notice)

        clock.now = start.addingTimeInterval(2 * day)
        precondition(store.refresh() == .ended(at: end), "rolling back after the end does not revive it")
        let relaunched = makeStore(persistence, clock: FakeClock(start.addingTimeInterval(2 * day)))
        precondition(relaunched.refresh() == .ended(at: end))
    }

    /// 終了時刻は startedAt + 14×24時間。その瞬間は終了。「あと○日」は切り上げ。
    static func verifyFourteenDayBoundary() {
        let persistence = MemoryTrialPersistence()
        let clock = FakeClock(start)
        let store = makeStore(persistence, clock: clock)
        store.refresh()

        clock.now = end.addingTimeInterval(-1)
        precondition(store.state == .active(until: end), "one second before the end is still active")
        precondition(store.remainingDays == 1)
        clock.now = end
        precondition(store.state == .ended(at: end), "the end instant is not active")
        precondition(store.remainingDays == nil)

        let fresh = makeStore(MemoryTrialPersistence(), clock: FakeClock(start))
        fresh.refresh()
        let expectations: [(TimeInterval, Int)] = [
            (0, 14), (1, 14), (day - 1, 14), (day, 13), (day + 1, 13),
            (13 * day - 1, 2), (13 * day, 1), (13 * day + 1, 1), (14 * day - 1, 1)
        ]
        for (elapsed, days) in expectations {
            let probe = makeStore(MemoryTrialPersistence(stored: try! TrialPeriodRecordCodec.encode(
                TrialPeriodRecord(startedAt: start))), clock: FakeClock(start.addingTimeInterval(elapsed)))
            probe.refresh()
            precondition(probe.remainingDays == days, "remaining days at \(elapsed)s should be \(days)")
        }
        _ = fresh
    }

    /// 読めない記録は体験後と同じ扱い。消さず、作り直さず、画面も出さない。
    static func verifyUnreadableRecord() {
        let unreadable = MemoryTrialPersistence(stored: Data("not json".utf8))
        let store = makeStore(unreadable, clock: FakeClock(start))
        precondition(store.refresh() == .unreadable)
        precondition(store.state == .unreadable)
        precondition(unreadable.inserts == 0 && unreadable.updates == 0, "an unreadable record is never replaced")
        precondition(unreadable.stored == Data("not json".utf8), "an unreadable record is never deleted")
        precondition(store.remainingDays == nil && !store.shouldShowDay14Notice)

        let failing = MemoryTrialPersistence(stored: try! TrialPeriodRecordCodec.encode(TrialPeriodRecord(startedAt: start)))
        failing.failsLoad = true
        let locked = makeStore(failing, clock: FakeClock(start))
        precondition(locked.refresh() == .unreadable, "a Keychain read failure is unreadable, not a new start")
        precondition(failing.inserts == 0)
        failing.failsLoad = false
        precondition(locked.refresh() == .active(until: end), "the next successful read uses the stored record")

        // 書けないときに新しい体験を始めない（払っていない人に権利を与えない）。
        let unwritable = MemoryTrialPersistence()
        unwritable.failsWrite = true
        let blocked = makeStore(unwritable, clock: FakeClock(start))
        precondition(blocked.refresh() == .unreadable)
        precondition(unwritable.stored == nil)

        for state in [TrialState.unreadable, .ended(at: end)] {
            precondition(TrialMembershipMerge.personalState(plus: .inactive, plusIsDisabled: false, trial: state) == .inactive)
            precondition(TrialMembershipMerge.personalState(plus: .checking, plusIsDisabled: true, trial: state) == .inactive,
                         "a disabled storefront after the period is inactive, never a verification request")
        }
    }

    /// 再インストール（記録が残っている）では続きから。開始時刻を作り直さない。
    static func verifyExistingRecordSurvivesReinstall() {
        let persistence = MemoryTrialPersistence(stored: try! TrialPeriodRecordCodec.encode(TrialPeriodRecord(startedAt: start)))
        let store = makeStore(persistence, clock: FakeClock(start.addingTimeInterval(10 * day)))
        precondition(store.refresh() == .active(until: end))
        precondition(persistence.inserts == 0, "an existing record is reused")
        precondition(persistence.record?.startedAt == start, "the start is not moved")
        precondition(store.remainingDays == 4)
    }

    /// 14日目（残り 0 < r ≤ 24時間）にアプリを開いたとき1回だけ。
    static func verifyDay14NoticeOnce() {
        let persistence = MemoryTrialPersistence()
        let clock = FakeClock(start)
        let store = makeStore(persistence, clock: clock)
        store.refresh()
        precondition(!store.shouldShowDay14Notice, "day 1 shows nothing")
        clock.now = start.addingTimeInterval(12 * day + 3600)
        store.refresh()
        precondition(!store.shouldShowDay14Notice, "day 13 shows nothing")
        store.markDay14NoticeShown()
        precondition(persistence.record?.day14NoticeShownAt == nil, "marking before day 14 is ignored")

        clock.now = start.addingTimeInterval(13 * day + 3600)
        store.refresh()
        precondition(store.shouldShowDay14Notice, "day 14 shows the line")
        store.markDay14NoticeShown()
        precondition(persistence.record?.day14NoticeShownAt == clock.now, "the display is recorded once")
        precondition(store.shouldShowDay14Notice, "the line stays for the rest of this process")
        let updates = persistence.updates
        store.markDay14NoticeShown()
        precondition(persistence.updates == updates, "a second display never writes again")

        clock.now = start.addingTimeInterval(13 * day + 7200)
        let relaunched = makeStore(persistence, clock: clock)
        relaunched.refresh()
        precondition(!relaunched.shouldShowDay14Notice, "a later launch on day 14 does not repeat the line")

        clock.now = end.addingTimeInterval(60)
        relaunched.refresh()
        precondition(!relaunched.shouldShowDay14Notice && relaunched.state == .ended(at: end))

        // 14日目を開かなかった人には出さない（通知は出さない）。
        let skipped = makeStore(MemoryTrialPersistence(stored: try! TrialPeriodRecordCodec.encode(
            TrialPeriodRecord(startedAt: start))), clock: FakeClock(end.addingTimeInterval(day)))
        skipped.refresh()
        precondition(!skipped.shouldShowDay14Notice)
    }

    /// 保存形式 v1。壊れた記録・別の版・不正な時刻は読めない扱い。
    static func verifyCodec() {
        let record = TrialPeriodRecord(startedAt: start)
        let data = try! TrialPeriodRecordCodec.encode(record)
        let json = String(decoding: data, as: UTF8.self)
        precondition(json.contains("\"version\":1") && json.contains("\"startedAt\":1800000000"),
                     "v1 JSON with seconds since 1970: \(json)")
        precondition(try! TrialPeriodRecordCodec.decode(data) == record)

        func rejects(_ text: String, _ reason: String) {
            do {
                _ = try TrialPeriodRecordCodec.decode(Data(text.utf8))
                preconditionFailure(reason)
            } catch TrialPeriodStoreError.unreadable {
            } catch {
                preconditionFailure("unexpected error for \(reason): \(error)")
            }
        }
        rejects("", "empty data")
        rejects("{}", "missing fields")
        rejects("{\"version\":2,\"startedAt\":1800000000,\"maxObservedNow\":1800000000}", "a newer version")
        rejects("{\"version\":1,\"startedAt\":1800000000,\"maxObservedNow\":1799999999}",
                "a maximum observed time before the start")
        rejects("{\"version\":1,\"startedAt\":\"x\",\"maxObservedNow\":1800000000}", "a non-numeric date")
        rejects(String(repeating: " ", count: 2_000) + "{}", "oversized data")
        var tooLarge = record
        tooLarge.maxObservedNow = Date(timeIntervalSince1970: .infinity)
        do { _ = try TrialPeriodRecordCodec.encode(tooLarge); preconditionFailure("non-finite date encoded") }
        catch TrialPeriodStoreError.unreadable {} catch { preconditionFailure("unexpected \(error)") }
    }

    /// 追加決定（2026-10-20昼）：まどは作った人が Plus で続ける。入る人はずっと無料。
    /// 体験中に公開する状態は `verified(体験終了)` なので、まどの作成と作ったまどへの
    /// 送信は会員扱いで allowed になり、体験後は会員が要る。体験後の判定そのもの
    /// （`createFirstOwnWindow` と作った人の送信を会員にする）は #416 の続きで Policy に入る。
    /// ここでは体験状態の公開だけを確かめる。招待されたまどでの送信は常に allowed。
    static func verifyWindowsDuringTrial() {
        let persistence = MemoryTrialPersistence()
        let clock = FakeClock(start)
        let store = makeStore(persistence, clock: clock)
        store.refresh()
        func personal(plus: MembershipPersonalState = .inactive, disabled: Bool = false) -> MembershipPersonalState {
            TrialMembershipMerge.personalState(plus: plus, plusIsDisabled: disabled, trial: store.state)
        }
        func decision(_ operation: MembershipOperation, _ state: MembershipPersonalState) -> MembershipAccessDecision {
            MembershipAccessPolicy.decision(for: operation, enforcementEnabled: true,
                personal: state, window: .inactive, now: clock.now)
        }
        let windowOperations: [MembershipOperation] = [
            .createFirstOwnWindow, .createAdditionalOwnWindow, .addSharedContent
        ]

        // 体験中（1日目・14日目）：Plus なし・storefront 無効でも、まどを作る・送る・入るは allowed。
        for elapsed in [0, 13 * day + 3600] {
            clock.now = start.addingTimeInterval(elapsed)
            store.refresh()
            precondition(personal() == .verified(validUntil: end))
            precondition(personal(plus: .checking, disabled: true) == .verified(validUntil: end))
            for operation in windowOperations {
                precondition(decision(operation, personal()) == .allowed,
                             "\(operation) must be allowed during the trial")
                precondition(decision(operation, personal(plus: .checking, disabled: true)) == .allowed)
            }
        }

        // 体験後：公開する状態は inactive。会員が要る操作は membershipRequired になり、
        // 「確認できません」にはならない。招待されたまどでの送信は常に allowed。
        clock.now = end
        store.refresh()
        precondition(store.state == .ended(at: end))
        precondition(personal() == .inactive && personal(plus: .checking, disabled: true) == .inactive)
        precondition(decision(.createAdditionalOwnWindow, personal()) == .membershipRequired)
        precondition(decision(.addSharedContent, personal()) == .allowed,
                     "joining and delivering to an invited window stay free after the trial")
        // Plus に戻れば再開する（作ったまどの続き）。
        let plusAgain = personal(plus: .verified(validUntil: end.addingTimeInterval(30 * day)))
        precondition(decision(.createAdditionalOwnWindow, plusAgain) == .allowed)

        // 体験中の Widget 用スナップショットと同じ `validUntil` を Policy も使う：終了の瞬間に止まる。
        clock.now = end.addingTimeInterval(-1)
        let fresh = makeStore(MemoryTrialPersistence(stored: try! TrialPeriodRecordCodec.encode(
            TrialPeriodRecord(startedAt: start))), clock: clock)
        fresh.refresh()
        let lastSecond = TrialMembershipMerge.personalState(plus: .inactive, plusIsDisabled: false, trial: fresh.state)
        precondition(decision(.createAdditionalOwnWindow, lastSecond) == .allowed)
        precondition(MembershipAccessPolicy.decision(for: .createAdditionalOwnWindow, enforcementEnabled: true,
            personal: lastSecond, window: .inactive, now: end) == .membershipRequired)
    }

    /// 実装計画 1-4 の合流順。
    static func verifyMerge() {
        let plusUntil = start.addingTimeInterval(30 * day)
        let active = TrialState.active(until: end)
        typealias Merge = TrialMembershipMerge

        // Plus が有効なら今のまま（体験の終了のほうが後ならそこまで）。
        precondition(Merge.personalState(plus: .verified(validUntil: plusUntil), plusIsDisabled: false, trial: active)
                     == .verified(validUntil: plusUntil))
        precondition(Merge.personalState(plus: .verified(validUntil: start.addingTimeInterval(day)), plusIsDisabled: false, trial: active)
                     == .verified(validUntil: end), "an earlier Plus expiry does not cut the 14 days short")
        precondition(Merge.personalState(plus: .indeterminate(lastVerifiedUntil: plusUntil), plusIsDisabled: false, trial: active)
                     == .indeterminate(lastVerifiedUntil: plusUntil))
        precondition(Merge.personalState(plus: .indeterminate(lastVerifiedUntil: start.addingTimeInterval(day)), plusIsDisabled: false, trial: active)
                     == .indeterminate(lastVerifiedUntil: end))
        // Plus なし（inactive・disabled・checking・期限なしの indeterminate）で体験 active → verified(体験終了)。
        for plus in [MembershipPersonalState.inactive, .checking, .indeterminate(lastVerifiedUntil: nil)] {
            precondition(Merge.personalState(plus: plus, plusIsDisabled: false, trial: active) == .verified(validUntil: end))
            precondition(Merge.personalState(plus: plus, plusIsDisabled: true, trial: active) == .verified(validUntil: end))
        }
        // 体験 ended → inactive（inactive・disabled）。checking・indeterminate は今のまま。
        for trial in [TrialState.ended(at: end), .unreadable] {
            precondition(Merge.personalState(plus: .inactive, plusIsDisabled: false, trial: trial) == .inactive)
            precondition(Merge.personalState(plus: .checking, plusIsDisabled: true, trial: trial) == .inactive)
            precondition(Merge.personalState(plus: .checking, plusIsDisabled: false, trial: trial) == .checking)
            precondition(Merge.personalState(plus: .indeterminate(lastVerifiedUntil: plusUntil), plusIsDisabled: false, trial: trial)
                         == .indeterminate(lastVerifiedUntil: plusUntil))
            precondition(Merge.personalState(plus: .verified(validUntil: plusUntil), plusIsDisabled: false, trial: trial)
                         == .verified(validUntil: plusUntil))
        }
        // 体験 notStarted（フラグ NO・開始前）→ 今のまま。
        for plus in [MembershipPersonalState.inactive, .checking, .verified(validUntil: plusUntil),
                     .indeterminate(lastVerifiedUntil: nil)] {
            precondition(Merge.personalState(plus: plus, plusIsDisabled: false, trial: .notStarted) == plus)
        }

        // 合流した状態は既存の Policy で「育つもの」を許可し、終了後は会員を求める。
        let verifiedByTrial = Merge.personalState(plus: .inactive, plusIsDisabled: false, trial: active)
        let now = start.addingTimeInterval(day)
        for operation in [MembershipOperation.refreshPersonalWidget, .openGrowingSummary, .createPersonalMemo,
                          .createAdditionalOwnWindow] {
            precondition(MembershipAccessPolicy.decision(for: operation, enforcementEnabled: true,
                personal: verifiedByTrial, window: .inactive, now: now) == .allowed)
            precondition(MembershipAccessPolicy.decision(for: operation, enforcementEnabled: true,
                personal: verifiedByTrial, window: .inactive, now: end) == .membershipRequired,
                "the end instant requires membership")
            precondition(MembershipAccessPolicy.decision(for: operation, enforcementEnabled: true,
                personal: Merge.personalState(plus: .inactive, plusIsDisabled: false, trial: .unreadable),
                window: .inactive, now: end) == .membershipRequired,
                "an unreadable record never asks for verification")
        }
    }
}
