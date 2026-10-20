import Foundation
import Security

/// ADR-027：入れたらすぐ使えて14日間はすべて無料。体験は端末ごとに14日。
///
/// App target だけに置く（Widget・Share Extension には入れない。ADR-025 決定3 と
/// 同じ境界）。記録は Keychain（`AfterFirstUnlockThisDeviceOnly`、iCloud 同期なし、
/// App Group なし）だけで、DeviceCheck・サーバー記録は使わない（実装計画 8章 決定6）。
/// Widget は体験を知らない。App が `PersonalWidgetMembershipStore.publish` に
/// `.verified(validUntil: 体験終了時刻)` を書き、Widget 側は既存の `validUntil` で止まる。
///
/// 時刻の扱い（実装計画 1-3）：有効な「今」は `max(端末時刻, これまでに見た最大の現在時刻)`。
/// 端末の時刻を戻しても体験は延びない。進めると早く終わる（利用者が損をする方向）。
/// 終了時刻は `startedAt + 14×24時間`。「あと○日」は切り上げ。暦日・タイムゾーンは使わない。
enum TrialState: Equatable, Sendable {
    case notStarted
    case active(until: Date)
    case ended(at: Date)
    /// 記録はあるが読めない。体験後と同じ扱いにし、「確認できません」画面は出さない。
    case unreadable
}

enum TrialPeriodStoreError: Error, Equatable, Sendable {
    /// 記録はあるが読めない（Keychain の読み取り失敗・壊れた記録）。
    case unreadable
    /// 書き込めない。
    case unavailable
}

/// TrialPeriodRecord v1。保存形式は JSON（日時は 1970 年からの秒）。
struct TrialPeriodRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let day: TimeInterval = 24 * 60 * 60
    static let duration: TimeInterval = 14 * day

    var version: Int
    /// 体験の開始時刻（このビルドを最初に開いた時刻）。
    var startedAt: Date
    /// 起動・前面復帰のたびに更新する「これまでに見た最大の現在時刻」。
    var maxObservedNow: Date
    /// 終了を確定した時刻。
    var endedAt: Date?
    /// 14日目の「あすから」の1行を出した時刻。1回だけ出す。
    var day14NoticeShownAt: Date?

    init(startedAt: Date) {
        version = Self.currentVersion
        self.startedAt = startedAt
        maxObservedNow = startedAt
    }

    var endsAt: Date { startedAt.addingTimeInterval(Self.duration) }

    func effectiveNow(deviceNow: Date) -> Date {
        max(deviceNow, maxObservedNow)
    }

    func state(deviceNow: Date) -> TrialState {
        if endedAt != nil || effectiveNow(deviceNow: deviceNow) >= endsAt {
            return .ended(at: endsAt)
        }
        return .active(until: endsAt)
    }

    /// 切り上げの残り日数。体験中でなければ 0。残りが 0 < r ≤ 24時間 なら 1（14日目）。
    func remainingDays(deviceNow: Date) -> Int {
        guard case .active = state(deviceNow: deviceNow) else { return 0 }
        let remaining = endsAt.timeIntervalSince(effectiveNow(deviceNow: deviceNow))
        return max(0, Int((remaining / Self.day).rounded(.up)))
    }

    func isDay14(deviceNow: Date) -> Bool {
        remainingDays(deviceNow: deviceNow) == 1
    }

    /// 最大観測時刻を進め、終了していれば `endedAt` を確定する。戻すことはない。
    func observing(deviceNow: Date) -> TrialPeriodRecord {
        var next = self
        if deviceNow > next.maxObservedNow { next.maxObservedNow = deviceNow }
        if next.endedAt == nil, next.maxObservedNow >= endsAt { next.endedAt = endsAt }
        return next
    }

    func validated() throws -> TrialPeriodRecord {
        guard version == Self.currentVersion,
              startedAt.timeIntervalSince1970.isFinite,
              maxObservedNow.timeIntervalSince1970.isFinite,
              maxObservedNow >= startedAt,
              endedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              day14NoticeShownAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true
        else { throw TrialPeriodStoreError.unreadable }
        return self
    }
}

enum TrialPeriodRecordCodec {
    static let maximumBytes = 1_024

    static func encode(_ record: TrialPeriodRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(try record.validated())
        } catch let error as TrialPeriodStoreError {
            throw error
        } catch {
            throw TrialPeriodStoreError.unavailable
        }
    }

    /// 読めない・壊れた記録は `unreadable`。黙って消したり作り直したりしない。
    static func decode(_ data: Data) throws -> TrialPeriodRecord {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw TrialPeriodStoreError.unreadable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(TrialPeriodRecord.self, from: data).validated()
        } catch let error as TrialPeriodStoreError {
            throw error
        } catch {
            throw TrialPeriodStoreError.unreadable
        }
    }
}

/// 記録の置き場所。本番は Keychain、検査では記憶上の実装を使う。
protocol TrialPeriodPersistence {
    /// 記録がなければ nil。読めない記録は `TrialPeriodStoreError.unreadable`。
    func load() throws -> TrialPeriodRecord?
    /// 記録がないときだけ追加する。すでにあれば既存の記録を返し、上書きしない。
    func insertIfAbsent(_ record: TrialPeriodRecord) throws -> TrialPeriodRecord
    /// 既存の記録を更新する。
    func update(_ record: TrialPeriodRecord) throws
}

/// 既存の課金 Keychain（`BillingKeychainStore`）と同じ流儀。別の service を使い、
/// 課金用の項目には触れない。アプリを削除しても項目は残るので、同じ端末での
/// 再インストールでは体験は戻らない（Apple が保証する挙動ではない。端末ごとに14日と割り切る）。
final class TrialPeriodKeychainPersistence: TrialPeriodPersistence {
    private static let service = "jp.nekowidget.trial-period.v1.host"
    private static let account = "primary"

    init() {}

    func load() throws -> TrialPeriodRecord? {
        var query = Self.itemQuery()
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return nil
        default:
            throw TrialPeriodStoreError.unreadable
        }
        guard let data = result as? Data else {
            throw TrialPeriodStoreError.unreadable
        }
        return try TrialPeriodRecordCodec.decode(data)
    }

    func insertIfAbsent(_ record: TrialPeriodRecord) throws -> TrialPeriodRecord {
        var attributes = Self.itemQuery()
        attributes[kSecValueData] = try TrialPeriodRecordCodec.encode(record)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return record
        case errSecDuplicateItem:
            // 同時に始めた別の経路が勝った。その記録を使い、上書きしない。
            guard let existing = try load() else {
                throw TrialPeriodStoreError.unavailable
            }
            return existing
        default:
            throw TrialPeriodStoreError.unavailable
        }
    }

    func update(_ record: TrialPeriodRecord) throws {
        let attributes: [CFString: Any] = [
            kSecValueData: try TrialPeriodRecordCodec.encode(record)
        ]
        let status = SecItemUpdate(
            Self.itemQuery() as CFDictionary,
            attributes as CFDictionary
        )
        guard status == errSecSuccess else {
            throw TrialPeriodStoreError.unavailable
        }
    }

    private static func itemQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
    }
}

/// 体験期間の記録。画面は出さない。`MembershipAuthority` だけが呼び、
/// Plus の状態と合流させる。
final class TrialPeriodStore: @unchecked Sendable {
    static let productionShared = TrialPeriodStore(
        persistence: TrialPeriodKeychainPersistence()
    )

    private enum Loaded {
        case none
        case record(TrialPeriodRecord)
        case unreadable
    }

    private let lock = NSLock()
    private let persistence: TrialPeriodPersistence
    private let clock: () -> Date
    private var loaded: Loaded = .none
    /// 14日目の1行を出したプロセスの間は出し続ける（記録には1回だけ書く）。
    private var day14NoticeDisplayedInThisProcess = false

    init(persistence: TrialPeriodPersistence, clock: @escaping () -> Date = { Date() }) {
        self.persistence = persistence
        self.clock = clock
    }

    /// 起動時・前面復帰時に呼ぶ。Keychain に記録がなければ体験を開始し、
    /// あれば最大観測時刻を進める。開始時に画面は出さない。
    @discardableResult
    func refresh() -> TrialState {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        do {
            let current: TrialPeriodRecord
            switch loaded {
            case let .record(record):
                current = record
            case .none, .unreadable:
                if let stored = try persistence.load() {
                    current = stored
                } else {
                    current = try persistence
                        .insertIfAbsent(TrialPeriodRecord(startedAt: now))
                        .validated()
                }
            }
            let observed = current.observing(deviceNow: now)
            if observed != current {
                // 更新に失敗しても、このプロセスの間は進んだ時刻を使う。
                try? persistence.update(observed)
            }
            loaded = .record(observed)
            return observed.state(deviceNow: now)
        } catch {
            loaded = .unreadable
            return .unreadable
        }
    }

    /// `refresh()` の前は `notStarted`。読まずに判定を変えることはない。
    var state: TrialState {
        lock.lock()
        defer { lock.unlock() }
        switch loaded {
        case .none: return .notStarted
        case .unreadable: return .unreadable
        case let .record(record): return record.state(deviceNow: clock())
        }
    }

    /// 体験中の「あと○日」（切り上げ）。体験中でなければ nil。
    var remainingDays: Int? {
        lock.lock()
        defer { lock.unlock() }
        guard case let .record(record) = loaded else { return nil }
        let now = clock()
        guard case .active = record.state(deviceNow: now) else { return nil }
        return record.remainingDays(deviceNow: now)
    }

    /// 14日目にアプリを開いたとき1回だけ。
    var shouldShowDay14Notice: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case let .record(record) = loaded, record.isDay14(deviceNow: clock()) else {
            return false
        }
        return record.day14NoticeShownAt == nil || day14NoticeDisplayedInThisProcess
    }

    func markDay14NoticeShown() {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        guard case .record(var record) = loaded,
              record.isDay14(deviceNow: now),
              record.day14NoticeShownAt == nil else { return }
        day14NoticeDisplayedInThisProcess = true
        record.day14NoticeShownAt = now
        loaded = .record(record)
        try? persistence.update(record)
    }
}

/// 実装計画 1-4 の合流順。Plus と体験のどちらか有効なほうで許可する。
///
/// - Plus が有効（verified）または期限つきの indeterminate → 今のまま。体験の終了が
///   それより後なら、体験の終了まで延ばす（14日間はすべて無料）。
/// - Plus なし（inactive・disabled・checking・期限なしの indeterminate）で体験 active
///   → `verified(validUntil: 体験終了)`。
/// - 体験 ended・unreadable で Plus が inactive または disabled → `inactive`。
///   checking・indeterminate は今のまま（払っていた人の確認を妨げない）。
/// - 体験 notStarted（フラグが NO、または開始前）→ 今のまま。
enum TrialMembershipMerge {
    static func personalState(
        plus: MembershipPersonalState,
        plusIsDisabled: Bool,
        trial: TrialState
    ) -> MembershipPersonalState {
        switch trial {
        case let .active(until):
            switch plus {
            case let .verified(validUntil):
                return .verified(validUntil: max(validUntil, until))
            case let .indeterminate(.some(lastVerifiedUntil)):
                return .indeterminate(lastVerifiedUntil: max(lastVerifiedUntil, until))
            case .indeterminate(.none), .inactive, .checking:
                return .verified(validUntil: until)
            }
        case .ended, .unreadable:
            if plusIsDisabled { return .inactive }
            return plus
        case .notStarted:
            return plus
        }
    }
}
