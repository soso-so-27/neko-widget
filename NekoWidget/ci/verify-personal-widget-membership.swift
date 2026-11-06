import Foundation

// This standalone verifier never reads or publishes an App Group file.
enum SharedContainer {
    static let containerURL: URL? = nil
}

@main
private enum PersonalWidgetMembershipVerifier {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = now.addingTimeInterval(60)
        let active = PersonalWidgetMembershipSnapshot.updated(
            for: .verified(validUntil: cutoff), previous: nil, now: now)
        precondition(active.allowsSelection(at: now))
        precondition(!active.allowsSelection(at: cutoff), "the expiry instant is not authorized")

        var previous = active
        let stoppedStates: [MembershipPersonalState] = [.inactive, .checking, .indeterminate(lastVerifiedUntil: nil)]
        for state in stoppedStates {
            let stopped = PersonalWidgetMembershipSnapshot.updated(
                for: state, previous: previous, now: cutoff.addingTimeInterval(60))
            precondition(stopped.validUntil == cutoff, "confirmation loss forgot the previous cutoff")
            precondition(!stopped.allowsSelection(at: cutoff.addingTimeInterval(60)))
            previous = stopped
        }
        let revoked = PersonalWidgetMembershipSnapshot.updated(
            for: .inactive, previous: active, now: now.addingTimeInterval(10))
        precondition(revoked.validUntil == now.addingTimeInterval(10), "revocation postponed the stop until expiry")
        precondition(!revoked.allowsSelection(at: now.addingTimeInterval(10)))

        let renewed = PersonalWidgetMembershipSnapshot.updated(
            for: .verified(validUntil: cutoff.addingTimeInterval(600)), previous: revoked, now: cutoff)
        precondition(renewed.allowsSelection(at: cutoff), "a newly verified period did not resume selection")
        let grace = PersonalWidgetMembershipSnapshot.updated(
            for: .indeterminate(lastVerifiedUntil: cutoff), previous: nil, now: now)
        precondition(grace.allowsSelection(at: now) && !grace.allowsSelection(at: cutoff))
        let unknown = PersonalWidgetMembershipSnapshot.updated(for: .checking, previous: nil, now: now)
        precondition(unknown.validUntil == now && !unknown.allowsSelection(at: now))

        // Background wake after the old 36h lease: a new server deadline,
        // not the wake time plus a local grace period, authorizes the next day.
        let oldCutoff = now.addingTimeInterval(36 * 3600)
        let old = PersonalWidgetMembershipSnapshot.updated(
            for: .verified(validUntil: oldCutoff), previous: nil, now: now)
        let wake = oldCutoff.addingTimeInterval(1)
        precondition(!old.allowsSelection(at: wake))
        let serverCutoff = wake.addingTimeInterval(900)
        let background = PersonalWidgetMembershipSnapshot.updated(
            for: .verified(validUntil: serverCutoff), previous: old, now: wake)
        precondition(background.allowsSelection(at: wake))
        precondition(!background.allowsSelection(at: serverCutoff))
        let denied = PersonalWidgetMembershipSnapshot.updated(for: .inactive, previous: background, now: wake)
        precondition(!denied.allowsSelection(at: wake))

        let malformed = PersonalWidgetMembershipSnapshot(membershipRequired: false,
            validUntil: Date(timeIntervalSinceReferenceDate: .infinity), recordedAt: now)
        precondition(!malformed.allowsSelection(at: now))
        let futureObservation = PersonalWidgetMembershipSnapshot(membershipRequired: false,
            validUntil: cutoff, recordedAt: now.addingTimeInterval(301))
        precondition(!futureObservation.allowsSelection(at: now))
        precondition(!active.allowsSelection(at: Date(timeIntervalSinceReferenceDate: .nan)))
        print("PASS personal Widget membership: exact cutoff, stop-boundary retention, revocation, renewal, bounded prior authority, invalid dates")
    }
}
