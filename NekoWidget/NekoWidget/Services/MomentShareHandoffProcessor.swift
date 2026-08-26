import Darwin
import Foundation

/// Host-only half of the Share Extension handoff. The extension can place a
/// bounded canonical JPEG in the App Group, but only this service runs after
/// `PairingInstallationGuard.bootstrap`, reads a host-only room key, performs
/// the final safety analysis, and promotes the image into the encrypted
/// network outbox.
struct MomentShareHandoffProcessor: Sendable {
    private static let senderPolicyVersion = 1
    private static let retryDelay: TimeInterval = 5 * 60

    private let moderation: any MomentModerating

    init(moderation: any MomentModerating = MomentModerationService()) {
        self.moderation = moderation
    }

    func revokeAdmissions(
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            // Plaintext cleanup is the first half of cancellation. If the
            // process stops here, the admission/capture still exists and a
            // later retry may safely resume. Once the store purge commits, no
            // cancelled analyzer input can remain.
            try purgeModerationTemporaryFiles()
            try MomentShareHandoffStore.revokeAdmissionsWhileLifecycleLocked()
        }
    }

    /// Cancels only the currently selected window. This is used for a local
    /// authorization failure or ordinary unlink; product-wide media disable
    /// continues to call `revokeAdmissions` and removes every destination.
    func revokeCurrentAdmission(
        pairing: PairingState,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            guard let catalog = try PrivateWindowCatalogStore.load() else {
                throw MomentSharingError.stateUnavailable
            }
            let binding: Data?
            if let spaceID = pairing.spaceID,
               let participantID = pairing.participantID {
                binding = try MomentShareHandoffStore.makeBindingSHA256(
                    installationMarker: pairing.installationMarker,
                    spaceID: spaceID,
                    participantID: participantID
                )
            } else {
                binding = nil
            }
            try purgeModerationTemporaryFiles()
            try MomentShareHandoffStore.revokeAdmissionWhileLifecycleLocked(
                localWindowID: catalog.activeWindowID,
                bindingSHA256: binding
            )
        }
    }

    @discardableResult
    func discardCancellableCaptures(
        destinationKey: String? = nil,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws -> Int {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try purgeModerationTemporaryFiles()
            return try MomentShareHandoffStore
                .discardCancellableCapturesWhileLifecycleLocked(
                    destinationKey: destinationKey
                )
        }
    }

    /// Permanently disables capture for the current pairing before persisting
    /// the relay's report-only state. The marker, capture purge, moderation
    /// temp purge, and local normal-outbox gate share one lifecycle flock; the
    /// marker is intentionally removed only by full pairing cleanup.
    func enterReportOnlyMode(
        until: Date,
        lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws {
        let discarded = try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try establishReportOnlyHandoffGateWhileLifecycleLocked(
                until: until,
                now: now
            )
            return try MomentSharingStateStore
                .enterReportOnlyModeWhileLifecycleLocked(until: until, now: now)
        }
        for item in discarded {
            try? MomentSharingStateStore.removeCiphertext(for: item)
        }
    }

    /// Durable fallback used when the cross-store state write cannot finish.
    /// A successfully written marker is sufficient to keep the Extension
    /// fail-closed until the next host sync resumes the state transition.
    func establishReportOnlyHandoffGate(
        until: Date,
        lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws {
        try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try establishReportOnlyHandoffGateWhileLifecycleLocked(
                until: until,
                now: now
            )
        }
    }

    private func establishReportOnlyHandoffGateWhileLifecycleLocked(
        until: Date,
        now: Date
    ) throws {
        try MomentShareHandoffStore
            .writeReportOnlyHandoffMarkerWhileLifecycleLocked(
                until: until,
                now: now
            )
        // The marker now prevents every Extension read/stage operation.
        // Unlink host plaintext before capture/catalog removal becomes the
        // local cancellation commit point.
        try purgeModerationTemporaryFiles()
        try MomentShareHandoffStore.revokeAdmissionsWhileLifecycleLocked()
    }

    /// Removes host-only plaintext copies used solely by an in-flight safety
    /// analysis. Deleting the file path also makes a late analyzer result lose
    /// its claim authority; the lifecycle/CAS checks still guard promotion.
    func purgeModerationTemporaryFiles() throws {
        let directory = Self.moderationTemporaryDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsSubdirectoryDescendants]
        )
        for file in files where file.lastPathComponent.hasPrefix(".handoff-") {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Publishes one current v1 destination and drains only captures admitted
    /// for that exact installation/space/participant binding. Publishing an
    /// admission is not authorization by itself: every promotion revalidates
    /// PairingState, consent, lifecycle epoch, report-only state, and room key.
    func refreshAdmissionsAndDrain(
        pairing: PairingState,
        credential: PairingCredential,
        lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) async throws -> Int {
        guard pairing.phase == .paired,
              pairing.mediaSharingConsentVersion == PairingMediaSharingConsent.currentVersion,
              pairing.mediaSharingConsentAcceptedAt != nil
        else {
            _ = try refreshAdmissionCatalog(
                lifecycleToken: lifecycleToken,
                now: now
            )
            throw MomentSharingError.consentRequired
        }
        guard let spaceID = pairing.spaceID,
              let participantID = pairing.participantID,
              let memberID = pairing.memberID,
              let localMomentDeviceID = pairing.resolvedLocalMomentDeviceID,
              pairing.credentialAccount == credential.account,
              pairing.installationMarker == credential.installationMarker,
              participantID == credential.participantIDString,
              let roomKey = credential.roomKey,
              roomKey.count == 32
        else {
            _ = try refreshAdmissionCatalog(
                lifecycleToken: lifecycleToken,
                now: now
            )
            throw MomentSharingError.notPaired
        }
        if let reportOnlyUntil = try MomentSharingStateStore.load().reportOnlyUntil {
            try enterReportOnlyMode(
                until: reportOnlyUntil,
                lifecycleToken: lifecycleToken,
                now: now
            )
            throw MomentSharingError.reportOnly(until: reportOnlyUntil)
        }

        try SharingLifecycleGate.validate(lifecycleToken)
        let binding = try MomentShareHandoffStore.makeBindingSHA256(
            installationMarker: pairing.installationMarker,
            spaceID: spaceID,
            participantID: participantID
        )
        let admission: MomentShareDestinationAdmission
        do {
            let catalog = try refreshAdmissionCatalog(
                lifecycleToken: lifecycleToken,
                now: now
            )
            guard let refreshed = catalog.destinations.first(where: {
                $0.bindingSHA256 == binding
            }) else { throw MomentSharingError.stateUnavailable }
            admission = refreshed
        } catch {
            // A different, inactive window may be temporarily unreadable
            // (for example while Data Protection is unavailable). That must
            // not block a healthy active window. Reuse only a still-current,
            // host-issued admission whose immutable binding exactly matches
            // the active pairing; never guess or fall back by display name.
            let refreshError = error
            let previousAdmissions = try? MomentShareHandoffStore
                .activeAdmissions(now: now)
            guard let existing = previousAdmissions?.first(where: {
                $0.bindingSHA256 == binding
            }) else { throw refreshError }
            admission = existing
        }
        try purgeOrphanedModerationTemporaryFiles(lifecycleToken: lifecycleToken)

        var promotedCount = 0
        while let pending = try MomentShareHandoffStore.nextPendingCapture(
            admissionID: admission.id,
            validating: lifecycleToken,
            now: .now
        ) {
            guard let claim = try MomentShareHandoffStore.claimCapture(
                pending,
                validating: lifecycleToken,
                now: .now
            ) else { continue }

            do {
                if try existingOutbox(
                    for: claim.record,
                    pairing: pairing
                ) != nil {
                    _ = try reconcileOrPromote(
                        claim: claim,
                        payload: nil,
                        pairing: pairing,
                        credential: credential,
                        lifecycleToken: lifecycleToken
                    )
                    promotedCount += 1
                    continue
                }

                guard claim.record.kind == .live,
                      claim.record.requiresHostModeration,
                      claim.record.requiredHostModerationVersion
                        == MomentSharingProtocol.moderationVersion,
                      claim.record.senderPolicyVersion == Self.senderPolicyVersion,
                      claim.record.captureDateIsMissing
                        == (claim.record.capturedAt == nil)
                else { throw MomentSharingError.invalidPayload }

                let moderationInput = try prepareModerationInput(
                    claim,
                    lifecycleToken: lifecycleToken
                )
                defer { try? FileManager.default.removeItem(at: moderationInput) }
                try await moderation.requireSafeImage(at: moderationInput)
                try Task.checkCancellation()
                try SharingLifecycleGate.validate(lifecycleToken)
                // Do not retain the JPEG in memory across the asynchronous
                // analyzer. Re-read the exact current claim only after safety
                // succeeds; a concurrent cancel then fails here before crypto.
                let canonicalJPEG = try MomentShareHandoffStore.withCurrentClaim(
                    claim,
                    validating: lifecycleToken
                ) { current in
                    try MomentCanonicalPreviewBuilder.validateReceived(
                        current.canonicalJPEG,
                        pixelWidth: current.pixelWidth,
                        pixelHeight: current.pixelHeight,
                        expectedPlaintextSHA256: current.canonicalJPEGSHA256
                    )
                    return current.canonicalJPEG
                }

                let context = MomentRequestContext(
                    spaceID: spaceID,
                    senderParticipantID: memberID,
                    senderDeviceID: localMomentDeviceID,
                    clientRequestID: claim.record.clientRequestID,
                    clientMomentID: claim.record.id,
                    kind: claim.record.kind,
                    keyEpoch: 1
                )
                let payload = try MomentCrypto.prepare(
                    canonicalJPEG: canonicalJPEG,
                    capturedAt: claim.record.capturedAt,
                    pixelWidth: claim.record.pixelWidth,
                    pixelHeight: claim.record.pixelHeight,
                    context: context,
                    spaceGenerationKey: roomKey
                )
                _ = try reconcileOrPromote(
                    claim: claim,
                    payload: payload,
                    pairing: pairing,
                    credential: credential,
                    lifecycleToken: lifecycleToken
                )
                promotedCount += 1
            } catch is CancellationError {
                try? MomentShareHandoffStore.releaseCapture(
                    claim,
                    retryAt: nil,
                    errorCode: "host-cancelled",
                    validating: lifecycleToken
                )
                throw CancellationError()
            } catch let error as MomentSharingError {
                switch error {
                case .sensitiveContent, .invalidPayload, .payloadTooLarge:
                    try discardAndRecordOutcomeIfStillAuthorized(
                        claim,
                        reason: Self.outcomeReason(for: error),
                        lifecycleToken: lifecycleToken
                    )
                case .moderationDisabled, .moderationUnavailable, .outboxFull:
                    try releaseIfStillAuthorized(
                        claim,
                        error: error,
                        lifecycleToken: lifecycleToken
                    )
                    return promotedCount
                case let .reportOnly(until):
                    try? enterReportOnlyMode(
                        until: until,
                        lifecycleToken: lifecycleToken
                    )
                    throw error
                case .consentRequired, .notPaired:
                    _ = try? refreshAdmissionCatalog(
                        lifecycleToken: lifecycleToken
                    )
                    throw error
                case .stateUnavailable:
                    // A cleanup/reinstall invalidates the token. Never turn a
                    // stale async result into an outbox after that boundary.
                    do {
                        try SharingLifecycleGate.validate(lifecycleToken)
                    } catch {
                        throw MomentSharingError.stateUnavailable
                    }
                    // A user may remove a still-local preparation while host
                    // moderation is awaiting its result. Missing the exact CAS
                    // claim proves that this async result has no authority to
                    // promote; never recreate it or continue to the network.
                    let claimIsCurrent = try MomentShareHandoffStore.isCurrentClaim(
                        claim,
                        validating: lifecycleToken
                    )
                    if !claimIsCurrent {
                        continue
                    }
                    try MomentShareHandoffStore.discardCapture(
                        claim,
                        recording: .preparationFailed,
                        validating: lifecycleToken
                    )
                default:
                    try releaseIfStillAuthorized(
                        claim,
                        error: error,
                        lifecycleToken: lifecycleToken
                    )
                    return promotedCount
                }
            } catch {
                do {
                    try SharingLifecycleGate.validate(lifecycleToken)
                } catch {
                    throw MomentSharingError.stateUnavailable
                }
                try? MomentShareHandoffStore.releaseCapture(
                    claim,
                    retryAt: Date().addingTimeInterval(Self.retryDelay),
                    errorCode: "host-processing-unavailable",
                    validating: lifecycleToken
                )
                return promotedCount
            }
        }
        return promotedCount
    }

    /// Republishes only the sanitized destination label consumed by the Share
    /// Extension. A rename must not drain a staged photo or start relay I/O.
    /// Existing bindings retain their admission IDs, so pending captures stay
    /// attached to the same locally authorized destination.
    func refreshAdmissionLabel(
        pairing: PairingState,
        credential: PairingCredential,
        lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws {
        guard pairing.phase == .paired,
              pairing.mediaSharingConsentVersion == PairingMediaSharingConsent.currentVersion,
              pairing.mediaSharingConsentAcceptedAt != nil,
              pairing.spaceID != nil,
              let participantID = pairing.participantID,
              pairing.credentialAccount == credential.account,
              pairing.installationMarker == credential.installationMarker,
              participantID == credential.participantIDString,
              credential.roomKey?.count == 32,
              try MomentSharingStateStore.load().reportOnlyUntil == nil
        else { return }

        try SharingLifecycleGate.validate(lifecycleToken)
        _ = try refreshAdmissionCatalog(
            lifecycleToken: lifecycleToken,
            now: now
        )
    }

    /// Rebuilds the sanitized Share Extension destination snapshot from every
    /// paired local window without switching the UI's active window. A
    /// transient read/keychain failure aborts publication, preserving the
    /// previous catalog and its captures rather than silently deleting one
    /// destination. Unpaired, no-consent, or report-only windows are omitted.
    @discardableResult
    func refreshAdmissionCatalog(
        lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> MomentShareAdmissionCatalog {
        try SharingLifecycleGate.validate(lifecycleToken)
        guard let catalog = try PrivateWindowCatalogStore.load() else {
            throw MomentSharingError.stateUnavailable
        }

        var inputs: [MomentShareAdmissionInput] = []
        inputs.reserveCapacity(catalog.windows.count)
        for entry in catalog.windows {
            let state: PairingState
            do {
                guard let loaded = try PairingStateStore.load(
                    localWindowID: entry.localWindowID
                ) else {
                    guard entry.spaceID == nil,
                          entry.credentialAccount == nil
                    else { throw MomentSharingError.stateUnavailable }
                    continue
                }
                state = loaded
            } catch let error as MomentSharingError {
                throw error
            } catch {
                throw MomentSharingError.stateUnavailable
            }
            guard state.phase == .paired else { continue }
            guard state.mediaSharingConsentVersion
                    == PairingMediaSharingConsent.currentVersion,
                  state.mediaSharingConsentAcceptedAt != nil
            else { continue }
            guard let spaceID = state.spaceID,
                  let participantID = state.participantID,
                  let account = state.credentialAccount,
                  entry.spaceID == nil || entry.spaceID == spaceID,
                  entry.credentialAccount == nil
                    || entry.credentialAccount == account
            else { throw MomentSharingError.stateUnavailable }

            let credential: PairingCredential
            do {
                credential = try PairingKeychainStore.load(
                    account: account,
                    installationMarker: state.installationMarker
                )
            } catch {
                // Availability is not revocation evidence. Keep the existing
                // admission/capture catalog unchanged and retry later.
                throw MomentSharingError.stateUnavailable
            }
            guard credential.account == account,
                  credential.installationMarker == state.installationMarker,
                  credential.participantIDString == participantID,
                  credential.roomKey?.count == 32
            else { throw MomentSharingError.stateUnavailable }

            let sharingState = try MomentSharingStateStore.load(
                localWindowID: entry.localWindowID
            )
            guard sharingState.reportOnlyUntil == nil else { continue }
            let binding = try MomentShareHandoffStore.makeBindingSHA256(
                installationMarker: state.installationMarker,
                spaceID: spaceID,
                participantID: participantID
            )
            inputs.append(MomentShareAdmissionInput(
                localWindowID: entry.localWindowID,
                bindingSHA256: binding,
                displayName: entry.displayName
            ))
        }
        try SharingLifecycleGate.validate(lifecycleToken)
        return try MomentShareHandoffStore.publishAdmissions(
            inputs,
            validating: lifecycleToken,
            now: now
        )
    }

    private func reconcileOrPromote(
        claim: MomentPendingCaptureClaim,
        payload: MomentPreparedPayload?,
        pairing: PairingState,
        credential: PairingCredential,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws -> MomentOutboxItem {
        try MomentShareHandoffStore.promoteCapture(
            claim,
            validating: lifecycleToken
        ) { current in
            try Self.validateCurrentPairingWhileLifecycleLocked(
                expected: pairing,
                expectedCredential: credential
            )
            if let existing = try Self.existingOutboxWhileLifecycleLocked(
                for: current,
                pairing: pairing
            ) {
                return existing
            }
            guard let payload else { throw MomentSharingError.stateUnavailable }
            return try MomentSharingStateStore.enqueueWhileLifecycleLocked(
                payload: payload,
                senderPolicyVersion: current.senderPolicyVersion,
                senderPolicyAcceptedAt: current.senderPolicyAcceptedAt
            )
        }
    }

    private func existingOutbox(
        for record: MomentPendingCaptureRecord,
        pairing: PairingState
    ) throws -> MomentOutboxItem? {
        let state = try MomentSharingStateStore.load()
        guard let existing = state.outbox.first(where: { $0.id == record.id }) else {
            return nil
        }
        try Self.validateExistingOutbox(existing, record: record, pairing: pairing)
        return existing
    }

    private static func existingOutboxWhileLifecycleLocked(
        for record: MomentPendingCaptureRecord,
        pairing: PairingState
    ) throws -> MomentOutboxItem? {
        guard let spaceID = pairing.spaceID,
              let memberID = pairing.memberID,
              let localMomentDeviceID = pairing.resolvedLocalMomentDeviceID
        else { throw MomentSharingError.notPaired }
        return try MomentSharingStateStore.existingOutboxWhileLifecycleLocked(
            clientMomentID: record.id,
            clientRequestID: record.clientRequestID,
            spaceID: spaceID,
            senderParticipantID: memberID,
            senderDeviceID: localMomentDeviceID,
            legacySenderDeviceID: localMomentDeviceID == memberID ? nil : memberID,
            kind: record.kind,
            keyEpoch: 1,
            senderPolicyVersion: record.senderPolicyVersion,
            senderPolicyAcceptedAt: record.senderPolicyAcceptedAt
        )
    }

    private static func validateExistingOutbox(
        _ existing: MomentOutboxItem,
        record: MomentPendingCaptureRecord,
        pairing: PairingState
    ) throws {
        guard let spaceID = pairing.spaceID,
              let memberID = pairing.memberID,
              existing.context.clientMomentID == record.id,
              existing.context.clientRequestID == record.clientRequestID,
              existing.context.spaceID == spaceID,
              existing.context.senderParticipantID == memberID,
              pairing.acceptsPersistedMomentDeviceID(
                  existing.context.senderDeviceID
              ),
              existing.context.kind == record.kind,
              existing.context.keyEpoch == 1,
              existing.senderPolicyVersion == record.senderPolicyVersion,
              Self.samePersistedSecond(
                  existing.senderPolicyAcceptedAt,
                  record.senderPolicyAcceptedAt
              )
        else { throw MomentSharingError.stateUnavailable }
    }

    private static func samePersistedSecond(_ lhs: Date, _ rhs: Date) -> Bool {
        Int64(lhs.timeIntervalSince1970.rounded(.down))
            == Int64(rhs.timeIntervalSince1970.rounded(.down))
    }

    /// Called only from inside `MomentShareHandoffStore.promoteCapture`, which
    /// already owns the lifecycle flock. PairingStateStore/PairingKeychainStore
    /// loads perform no additional flock acquisition, so consent, identity,
    /// and the current room key are rechecked in the same critical section as
    /// outbox publication.
    private static func validateCurrentPairingWhileLifecycleLocked(
        expected: PairingState,
        expectedCredential: PairingCredential
    ) throws {
        guard let current = try PairingStateStore.load(),
              current.phase == .paired,
              current.installationMarker == expected.installationMarker,
              current.credentialAccount == expected.credentialAccount,
              current.spaceID == expected.spaceID,
              current.memberID == expected.memberID,
              current.participantID == expected.participantID,
              current.mediaSharingConsentVersion
                == PairingMediaSharingConsent.currentVersion,
              current.mediaSharingConsentAcceptedAt
                == expected.mediaSharingConsentAcceptedAt,
              let account = current.credentialAccount
        else { throw MomentSharingError.consentRequired }
        let currentCredential: PairingCredential
        do {
            currentCredential = try PairingKeychainStore.load(
                account: account,
                installationMarker: current.installationMarker
            )
        } catch {
            throw MomentSharingError.notPaired
        }
        guard currentCredential.account == expectedCredential.account,
              currentCredential.installationMarker
                == expectedCredential.installationMarker,
              currentCredential.participantID == expectedCredential.participantID,
              currentCredential.roomKey == expectedCredential.roomKey,
              currentCredential.roomKey?.count == 32
        else { throw MomentSharingError.notPaired }
    }

    private func prepareModerationInput(
        _ claim: MomentPendingCaptureClaim,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws -> URL {
        try MomentShareHandoffStore.withCurrentClaim(
            claim,
            validating: lifecycleToken
        ) { current in
            let jpeg = current.canonicalJPEG
            try MomentCanonicalPreviewBuilder.validateReceived(
                jpeg,
                pixelWidth: current.pixelWidth,
                pixelHeight: current.pixelHeight,
                expectedPlaintextSHA256: current.canonicalJPEGSHA256
            )
            let directory = Self.moderationTemporaryDirectory
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Self.enforceCompleteProtectionAndBackupExclusion(directory)
            let url = directory.appendingPathComponent(
                Self.moderationFileName(
                    captureID: current.id,
                    claimID: claim.claimID
                ),
                isDirectory: false
            )
            // The exact same claim cannot have two authorized processors. A
            // surviving inode with this name is therefore residue from a killed
            // process and must be removed before O_EXCL creates the new input.
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try Self.writeCompleteProtected(jpeg, to: url)
            return url
        }
    }

    private static var moderationTemporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "NekoWidgetMomentHandoffModeration",
            isDirectory: true
        )
    }

    private func purgeOrphanedModerationTemporaryFiles(
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        try MomentShareHandoffStore.withActiveClaimIdentities(
            validating: lifecycleToken
        ) { activeClaims in
            let retainedNames = Set(activeClaims.map {
                Self.moderationFileName(captureID: $0.captureID, claimID: $0.claimID)
            })
            let directory = Self.moderationTemporaryDirectory
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsSubdirectoryDescendants]
            )
            for file in files where file.lastPathComponent.hasPrefix(".handoff-") {
                guard !retainedNames.contains(file.lastPathComponent) else { continue }
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
                if values?.isRegularFile == true {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    private static func moderationFileName(
        captureID: UUID,
        claimID: UUID
    ) -> String {
        ".handoff-\(captureID.uuidString.lowercased())__\(claimID.uuidString.lowercased()).jpg"
    }

    /// Moderation plaintext is needed only while the foreground host analyzes
    /// it. Create and verify the protected inode before writing any JPEG byte;
    /// `completeUntilFirstUserAuthentication` is intentionally insufficient
    /// for this temporary plaintext boundary.
    static func writeCompleteProtected(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_CREAT | O_EXCL | O_WRONLY,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw MomentSharingError.stateUnavailable
        }
        Darwin.close(descriptor)
        do {
            try enforceCompleteProtectionAndBackupExclusion(url)
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func enforceCompleteProtectionAndBackupExclusion(
        _ url: URL
    ) throws {
#if targetEnvironment(simulator)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
#else
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
#endif
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
        let verified = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        guard verified.isExcludedFromBackup == true else {
            throw MomentSharingError.stateUnavailable
        }
#if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.protectionKey] as? FileProtectionType) == .complete else {
            throw MomentSharingError.stateUnavailable
        }
#endif
    }

    private func releaseIfStillAuthorized(
        _ claim: MomentPendingCaptureClaim,
        error: MomentSharingError,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        try SharingLifecycleGate.validate(lifecycleToken)
        try MomentShareHandoffStore.releaseCapture(
            claim,
            retryAt: Date().addingTimeInterval(Self.retryDelay),
            errorCode: Self.safeErrorCode(error),
            validating: lifecycleToken
        )
    }

    private func discardIfStillAuthorized(
        _ claim: MomentPendingCaptureClaim,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        try SharingLifecycleGate.validate(lifecycleToken)
        try MomentShareHandoffStore.discardCapture(
            claim,
            validating: lifecycleToken
        )
    }

    /// The handoff and sharing ledgers are separate protected files, so there
    /// is no cross-file transaction. Delete the canonical plaintext first,
    /// then persist only the fixed reason under the same validated lifecycle
    /// token. A crash in between may omit the notice, but can never preserve a
    /// rejected sensitive image merely to guarantee presentation history.
    private func discardAndRecordOutcomeIfStillAuthorized(
        _ claim: MomentPendingCaptureClaim,
        reason: MomentOutgoingOutcomeReason,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        try discardIfStillAuthorized(claim, lifecycleToken: lifecycleToken)
        _ = try MomentSharingStateStore.recordOutgoingOutcome(
            reason: reason,
            validating: lifecycleToken
        )
    }

    private static func outcomeReason(
        for error: MomentSharingError
    ) -> MomentOutgoingOutcomeReason {
        switch error {
        case .sensitiveContent: .sensitiveContent
        case .payloadTooLarge: .photoTooLarge
        case .invalidPayload: .invalidPhoto
        default: .invalidPhoto
        }
    }

    private static func safeErrorCode(_ error: MomentSharingError) -> String {
        switch error {
        case .moderationDisabled: "moderation-disabled"
        case .moderationUnavailable: "moderation-unavailable"
        case .outboxFull: "outbox-full"
        case .consentRequired: "consent-required"
        case .notPaired: "not-paired"
        default: "host-processing-unavailable"
        }
    }
}
