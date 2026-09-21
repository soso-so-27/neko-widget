import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Bounded presentation authority shared with the personal Widget. No account,
/// window, private memo, receipt, or payment information is stored here.
struct PersonalWidgetMembershipSnapshot: Codable, Equatable {
    var membershipRequired: Bool
    var validUntil: Date?
    var recordedAt: Date

    func allowsSelection(at now: Date) -> Bool {
        guard !membershipRequired, now.timeIntervalSince1970.isFinite,
              recordedAt.timeIntervalSince1970.isFinite,
              recordedAt <= now.addingTimeInterval(300),
              let validUntil, validUntil.timeIntervalSince1970.isFinite else { return false }
        return now < validUntil
    }

    static func updated(
        for state: MembershipPersonalState,
        previous: PersonalWidgetMembershipSnapshot?, now: Date
    ) -> PersonalWidgetMembershipSnapshot {
        // Losing confirmation must not forget an earlier cutoff and admit a
        // previously queued photo whose date falls after that deadline.
        let stoppedAt: Date
        if let prior = previous?.validUntil, prior.timeIntervalSince1970.isFinite {
            stoppedAt = min(prior, now)
        } else { stoppedAt = now }
        let until: Date?
        let required: Bool
        switch state {
        case let .verified(validUntil): until = validUntil; required = false
        case let .indeterminate(lastVerifiedUntil): until = lastVerifiedUntil ?? stoppedAt; required = false
        case .inactive: until = stoppedAt; required = true
        case .checking: until = stoppedAt; required = false
        }
        return PersonalWidgetMembershipSnapshot(
            membershipRequired: required, validUntil: until, recordedAt: now)
    }
}

enum PersonalWidgetMembershipStore {
    static var isEnforced: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MembershipAccessEnforced") as? Bool == true
    }

    private static var url: URL? {
        SharedContainer.containerURL?.appendingPathComponent("personal-widget-membership.v1.json")
    }

    static func read() -> PersonalWidgetMembershipSnapshot? {
        guard isEnforced, let url,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 2_048, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersonalWidgetMembershipSnapshot.self, from: data)
    }

    static func allowsSelection(at now: Date = .now) -> Bool {
        !isEnforced || read()?.allowsSelection(at: now) == true
    }

    static func publish(_ state: MembershipPersonalState, now: Date = .now) throws {
        guard isEnforced, let url else { return }
        let previous = read()
        // Updating the app must never extend the server-confirmed deadline.
        let snapshot = PersonalWidgetMembershipSnapshot.updated(for: state, previous: previous, now: now)
        do {
            try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic])
        } catch {
            // A failed update must not leave an older grant authorizing new
            // selections after a confirmed stop. Photo files are untouched.
            try? FileManager.default.removeItem(at: url)
#if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
#endif
            throw error
        }
#if canImport(WidgetKit)
        if previous?.membershipRequired != snapshot.membershipRequired
            || previous?.validUntil != snapshot.validUntil {
            // Replace already issued timelines when authority is withdrawn or
            // renewed. The intent also rechecks authority before a new selection.
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        }
#endif
    }
}
