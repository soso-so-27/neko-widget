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
        // ADR-027: ツール5つ、アルバム一覧、招待されたまどでの送信は無料。
        // 「育つもの」（まどを作る・作ったまどを続けるを含む）だけが個人の会員操作。
        // まどの支援（window 状態）は判定に使わない。
        let free: [MembershipOperation] = [
            .browsePhotos, .manageFavorites, .readExistingMemo,
            .editExistingMemo, .deleteOwnedContent, .exportExistingContent,
            .receivePhotos, .reactToPhoto, .browseOfficialWindow, .browseAlbums,
            .presentCatPhotos, .createCareMemo, .createVeterinaryVisit,
            .addSharedContent, .continueAcceptedDelivery
        ]
        let personalOperations: [MembershipOperation] = [
            .openGrowingSummary, .refreshPersonalWidget, .createPersonalMemo,
            .createOwnWindow, .addContentToOwnWindow
        ]
        require(
            Set(free + personalOperations) == Set(MembershipOperation.allCases)
                && free.count + personalOperations.count == MembershipOperation.allCases.count,
            "Every operation must have exactly one explicit membership contract"
        )
        require(
            MembershipAccessPolicy.maximumOwnWindowCount == 5,
            "Own windows must stay at 5 (ADR-027)"
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
            for operation in personalOperations {
            require(
                decision(operation, personal: state,
                         window: .verified(validUntil: future)) == expected,
                "Personal boundary failed: \(operation) / \(label)"
            )
            }
        }

        // A reference held before an async wait observes later revocation;
        // denial must not run a creation/commit callback.
        let live = MembershipActionAccess(enforcementEnabled: true,
            personal: .verified(validUntil: Date.now.addingTimeInterval(60)))
        require(live.decision(for: .createPersonalMemo) == .allowed, "Live grant not observed")
        live.update(enforcementEnabled: true, personal: .inactive)
        var commits = 0
        for operation in [MembershipOperation.createPersonalMemo, .createOwnWindow, .addContentToOwnWindow] {
            do {
                try live.perform(for: operation) { commits += 1 }
                fatalError("Revocation admitted \(operation)")
            } catch let denied as MembershipActionDenied {
                require(denied.decision == .membershipRequired, "Revocation classification")
            } catch { fatalError("Unexpected membership error") }
        }
        require(commits == 0, "Denied membership mutated data")
        // ツール5つは会員が切れても、確認不能でも、記録を作れる。
        for operation in [MembershipOperation.presentCatPhotos, .createCareMemo, .createVeterinaryVisit] {
            try! live.perform(for: operation) { commits += 1 }
        }
        live.update(enforcementEnabled: true, personal: .checking)
        try! live.perform(for: .createCareMemo) { commits += 1 }
        require(commits == 4, "Free tools blocked by membership state")
        live.update(enforcementEnabled: false, personal: .checking)
        try! live.perform(for: .createPersonalMemo) { commits += 1 }
        require(commits == 5, "Beta commit blocked")

        // 招待されたまどでの送信は、個人・まどのどの状態でも許可（入る人は
        // ずっと無料）。まどの支援（sponsorship）の状態は判定に使わない。
        let windowStates: [(String, MembershipWindowState)] = [
            ("unsupported", .inactive),
            ("checking", .checking),
            ("supported", .verified(validUntil: future)),
            ("expired", .verified(validUntil: past)),
            ("offline within prior authority", .indeterminate(lastVerifiedUntil: future)),
            ("never verified", .indeterminate(lastVerifiedUntil: nil)),
            ("invalid verified date", .verified(validUntil: invalid)),
            ("unbounded grant", .verified(validUntil: unbounded))
        ]
        let participants: [MembershipPersonalState] = [
            .inactive, .checking, .verified(validUntil: future), .verified(validUntil: past),
            .indeterminate(lastVerifiedUntil: nil), .verified(validUntil: invalid)
        ]
        for (label, window) in windowStates {
            for personal in participants {
                require(
                    decision(.addSharedContent, personal: personal, window: window) == .allowed,
                    "addSharedContent was gated: \(label)"
                )
                require(
                    decision(.addSharedContent, personal: personal, window: window, at: invalid) == .allowed,
                    "addSharedContent was gated by the clock: \(label)"
                )
            }
        }
        // まどを作る・作ったまどへ届けるのは作った人のPlus（体験中は verified）。
        // まどの状態では開かず、体験後（inactive）は会員要。
        for (label, window) in windowStates {
            for operation in [MembershipOperation.createOwnWindow, .addContentToOwnWindow] {
                require(
                    decision(operation, personal: .verified(validUntil: future), window: window) == .allowed,
                    "\(operation.rawValue) blocked during a valid trial/membership: \(label)"
                )
                require(
                    decision(operation, personal: .inactive, window: window) == .membershipRequired,
                    "Window state unlocked \(operation.rawValue): \(label)"
                )
            }
        }

        // 月のまとめ・季節のムービーを開くのは「育つもの」。体験中（verified）だけ開く。
        require(
            decision(.openGrowingSummary, personal: .verified(validUntil: future)) == .allowed,
            "A verified member could not open a growing summary"
        )
        require(
            decision(.openGrowingSummary, personal: .inactive) == .membershipRequired,
            "An inactive member opened a growing summary"
        )
        require(
            decision(.browseAlbums, personal: .inactive) == .allowed,
            "Album browsing must stay free"
        )

        require(
            decision(.refreshPersonalWidget, personal: .verified(validUntil: future), at: invalid)
                == .verificationRequired,
            "An invalid clock must not authorize new personal activity"
        )
        require(
            decision(.openGrowingSummary, personal: .verified(validUntil: future), at: invalid)
                == .verificationRequired,
            "An invalid clock must not authorize opening a growing summary"
        )
        print("PASS membership access: beta, existing content, free tools, own window creation and delivery, shared content, personal expiry, offline authority, invalid dates")
    }
}
