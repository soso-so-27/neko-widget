import Foundation

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String
) {
    guard condition() else { fatalError(message()) }
}

@main
private struct MembershipAccessVerifier {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(1)
        let past = now.addingTimeInterval(-1)
        let invalid = Date(timeIntervalSinceReferenceDate: .nan)
        let unbounded = Date(timeIntervalSinceReferenceDate: .infinity)
        let free: [MembershipOperation] = [
            .browsePhotos, .manageFavorites, .readExistingMemo,
            .editExistingMemo, .deleteOwnedContent, .exportExistingContent,
            .receivePhotos, .reactToPhoto, .browseOfficialWindow,
            .continueAcceptedDelivery
        ]
        let personalOperations: [MembershipOperation] = [
            .automaticAlbums, .refreshPersonalWidget, .createPersonalMemo,
            .createWindow
        ]
        require(
            Set(free + personalOperations + [.addSharedContent])
                == Set(MembershipOperation.allCases),
            "Every operation must have an explicit membership contract"
        )

        func decision(
            _ operation: MembershipOperation,
            personal: MembershipPersonalState = .inactive,
            window: MembershipWindowState = .inactive,
            at date: Date? = nil,
            enforcementEnabled: Bool = true
        ) -> MembershipAccessDecision {
            MembershipAccessPolicy.decision(
                for: operation, enforcementEnabled: enforcementEnabled,
                personal: personal, window: window, now: date ?? now
            )
        }

        // Disabling membership enforcement cannot introduce beta restrictions.
        for operation in MembershipOperation.allCases {
            require(
                decision(operation, window: .checking, enforcementEnabled: false)
                    == .allowed,
                "Beta unexpectedly restricted \(operation.rawValue)"
            )
        }

        // Loss of paid access or connectivity must never lock existing data,
        // received content, or server-accepted delivery behind another purchase.
        for operation in free {
            require(
                decision(operation, personal: .verified(validUntil: past),
                         window: .verified(validUntil: past)) == .allowed,
                "Expired access locked \(operation.rawValue)"
            )
            require(
                decision(operation, personal: .indeterminate(lastVerifiedUntil: nil),
                         window: .checking, at: invalid) == .allowed,
                "Unknown authority locked \(operation.rawValue)"
            )
        }

        // A window's sponsor cannot unlock personal paid operations.
        for operation in personalOperations {
            require(
                decision(operation, window: .verified(validUntil: future))
                    == .membershipRequired,
                "Window sponsorship unlocked \(operation.rawValue)"
            )
            require(
                decision(operation, personal: .verified(validUntil: future)) == .allowed,
                "Valid personal membership did not unlock \(operation.rawValue)"
            )
        }

        let personalCases: [(String, MembershipPersonalState, MembershipAccessDecision)] = [
            ("inactive", .inactive, .membershipRequired),
            ("checking", .checking, .verificationRequired),
            ("valid", .verified(validUntil: future), .allowed),
            ("exact expiry", .verified(validUntil: now), .membershipRequired),
            ("expired", .verified(validUntil: past), .membershipRequired),
            ("offline within prior authority", .indeterminate(lastVerifiedUntil: future), .allowed),
            ("offline at expiry", .indeterminate(lastVerifiedUntil: now), .verificationRequired),
            ("offline past expiry", .indeterminate(lastVerifiedUntil: past), .verificationRequired),
            ("never verified", .indeterminate(lastVerifiedUntil: nil), .verificationRequired),
            ("invalid verified date", .verified(validUntil: invalid), .verificationRequired),
            ("unbounded grant", .verified(validUntil: unbounded), .verificationRequired),
            ("invalid cached date", .indeterminate(lastVerifiedUntil: invalid), .verificationRequired)
        ]
        for (label, state, expected) in personalCases {
            require(
                decision(.createPersonalMemo, personal: state,
                         window: .verified(validUntil: future)) == expected,
                "Personal boundary failed: \(label)"
            )
        }

        // Each party uses the same window authority: paying personally is neither
        // sufficient nor required for adding content to a supported window.
        let windowCases: [(String, MembershipWindowState, MembershipAccessDecision)] = [
            ("unsupported", .inactive, .windowSupportRequired),
            ("checking", .checking, .verificationRequired),
            ("supported", .verified(validUntil: future), .allowed),
            ("exact expiry", .verified(validUntil: now), .windowSupportRequired),
            ("expired", .verified(validUntil: past), .windowSupportRequired),
            ("offline within prior authority", .indeterminate(lastVerifiedUntil: future), .allowed),
            ("offline at expiry", .indeterminate(lastVerifiedUntil: now), .verificationRequired),
            ("offline past expiry", .indeterminate(lastVerifiedUntil: past), .verificationRequired),
            ("never verified", .indeterminate(lastVerifiedUntil: nil), .verificationRequired),
            ("invalid verified date", .verified(validUntil: invalid), .verificationRequired),
            ("unbounded grant", .verified(validUntil: unbounded), .verificationRequired),
            ("invalid cached date", .indeterminate(lastVerifiedUntil: invalid), .verificationRequired)
        ]
        let participants: [MembershipPersonalState] = [.inactive, .verified(validUntil: future)]
        for (label, state, expected) in windowCases {
            for personal in participants {
                require(
                    decision(.addSharedContent, personal: personal, window: state) == expected,
                    "Window boundary depended on individual payer: \(label)"
                )
            }
        }

        require(
            decision(.refreshPersonalWidget, personal: .verified(validUntil: future), at: invalid)
                == .verificationRequired,
            "An invalid clock must not authorize new personal activity"
        )
        require(
            decision(.addSharedContent, window: .verified(validUntil: future), at: invalid)
                == .verificationRequired,
            "An invalid clock must not authorize new shared activity"
        )
        print("PASS membership access: beta, existing content, personal/window separation, expiry, offline authority, invalid dates")
    }
}
