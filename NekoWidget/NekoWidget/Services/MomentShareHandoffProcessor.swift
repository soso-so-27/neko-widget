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

    private let moderation: MomentModerationService

    init(moderation: MomentModerationService = MomentModerationService()) {
        self.moderation = moderation
    }

    func revokeAdmissions(
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        try MomentShareHandoffStore.revokeAdmissions(validating: lifecycleToken)
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
            try MomentShareHandoffStore.revokeAdmissions(validating: lifecycleToken)
            throw MomentSharingError.consentRequired
        }
        guard let spaceID = pairing.spaceID,
              let participantID = pairing.participantID,
              let memberID = pairing.memberID,
              pairing.credentialAccount == credential.account,
              pairing.installationMarker == credential.installationMarker,
              participantID == credential.participantIDString,
              let roomKey = credential.roomKey,
              roomKey.count == 32
        else {
            try MomentShareHandoffStore.revokeAdmissions(validating: lifecycleToken)
            throw MomentSharingError.notPaired
        }
        if let reportOnlyUntil = try MomentSharingStateStore.load().reportOnlyUntil {
            try MomentShareHandoffStore.revokeAdmissions(validating: lifecycleToken)
            throw MomentSharingError.reportOnly(until: reportOnlyUntil)
        }

        try SharingLifecycleGate.validate(lifecycleToken)
        let binding = try MomentShareHandoffStore.makeBindingSHA256(
            installationMarker: pairing.installationMarker,
            spaceID: spaceID,
            participantID: participantID
        )
        let catalog = try MomentShareHandoffStore.publishAdmissions(
            [MomentShareAdmissionInput(bindingSHA256: binding, displayName: "家族のまど")],
            validating: lifecycleToken,
            now: now
        )
        guard let admission = catalog.destinations.first(where: {
            $0.bindingSHA256 == binding
        }) else { throw MomentSharingError.stateUnavailable }

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

                let canonicalJPEG = try MomentShareHandoffStore.readCanonicalJPEG(
                    claim,
                    validating: lifecycleToken
                )
                try MomentCanonicalPreviewBuilder.validateReceived(
                    canonicalJPEG,
                    pixelWidth: claim.record.pixelWidth,
                    pixelHeight: claim.record.pixelHeight,
                    expectedPlaintextSHA256: claim.record.canonicalJPEGSHA256
                )
                guard claim.record.kind == .live,
                      claim.record.requiresHostModeration,
                      claim.record.requiredHostModerationVersion
                        == MomentSharingProtocol.moderationVersion,
                      claim.record.senderPolicyVersion == Self.senderPolicyVersion,
                      claim.record.captureDateIsMissing
                        == (claim.record.capturedAt == nil)
                else { throw MomentSharingError.invalidPayload }

                try await requireSafeCanonical(
                    canonicalJPEG,
                    captureID: claim.record.id
                )
                try Task.checkCancellation()
                try SharingLifecycleGate.validate(lifecycleToken)

                let context = MomentRequestContext(
                    spaceID: spaceID,
                    senderParticipantID: memberID,
                    // Migration 0003 uses the member's opaque ID for its first
                    // device. Future device enrollment can replace this field
                    // without changing the handoff admission boundary.
                    senderDeviceID: memberID,
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
                    try discardIfStillAuthorized(
                        claim,
                        lifecycleToken: lifecycleToken
                    )
                case .moderationUnavailable, .outboxFull:
                    try releaseIfStillAuthorized(
                        claim,
                        error: error,
                        lifecycleToken: lifecycleToken
                    )
                    return promotedCount
                case .reportOnly:
                    try? MomentShareHandoffStore.revokeAdmissions(
                        validating: lifecycleToken
                    )
                    throw error
                case .consentRequired, .notPaired:
                    try? MomentShareHandoffStore.revokeAdmissions(
                        validating: lifecycleToken
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
                    try discardIfStillAuthorized(
                        claim,
                        lifecycleToken: lifecycleToken
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
              let memberID = pairing.memberID
        else { throw MomentSharingError.notPaired }
        return try MomentSharingStateStore.existingOutboxWhileLifecycleLocked(
            clientMomentID: record.id,
            clientRequestID: record.clientRequestID,
            spaceID: spaceID,
            senderParticipantID: memberID,
            senderDeviceID: memberID,
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
              existing.context.senderDeviceID == memberID,
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

    private func requireSafeCanonical(
        _ jpeg: Data,
        captureID: UUID
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NekoWidgetMomentHandoffModeration",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Self.enforceCompleteProtectionAndBackupExclusion(directory)
        Self.pruneModerationResidue(in: directory)
        let url = directory.appendingPathComponent(
            ".handoff-\(captureID.uuidString.lowercased())-\(UUID().uuidString).jpg",
            isDirectory: false
        )
        try Self.writeCompleteProtected(jpeg, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await moderation.requireSafeImage(at: url)
    }

    private static func pruneModerationResidue(in directory: URL, now: Date = .now) {
        let cutoff = now.addingTimeInterval(-60 * 60)
        let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsSubdirectoryDescendants]
        )
        for file in files ?? [] where file.lastPathComponent.hasPrefix(".handoff-") {
            let values = try? file.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            )
            if values?.isRegularFile == true,
               let modifiedAt = values?.contentModificationDate,
               modifiedAt < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Moderation plaintext is needed only while the foreground host analyzes
    /// it. Create and verify the protected inode before writing any JPEG byte;
    /// `completeUntilFirstUserAuthentication` is intentionally insufficient
    /// for this temporary plaintext boundary.
    private static func writeCompleteProtected(_ data: Data, to url: URL) throws {
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

    private static func enforceCompleteProtectionAndBackupExclusion(
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

    private static func safeErrorCode(_ error: MomentSharingError) -> String {
        switch error {
        case .moderationUnavailable: "moderation-unavailable"
        case .outboxFull: "outbox-full"
        case .consentRequired: "consent-required"
        case .notPaired: "not-paired"
        default: "host-processing-unavailable"
        }
    }
}
