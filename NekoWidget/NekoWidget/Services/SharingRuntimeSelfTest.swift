#if DEBUG
import Darwin
import Foundation
import Security
import UIKit

private enum RuntimeReserveStep: Sendable {
    case responseLost(SharingReserveResult)
    case success(SharingReserveResult)
}

private actor RuntimeSharingAPI: DailySharingAPIClientProtocol {
    let manifest: Data
    let mediaByID: [String: Data]
    let generationByID: [String: SharingGenerationResume]
    private var reserveSteps: [RuntimeReserveStep]
    private var reserveRequestIDs: [String] = []
    private var reserveMediaIDs: [[String]] = []
    private var manifestDownloadCount = 0
    private var mediaDownloadCount = 0

    init(
        manifest: Data = Data(),
        mediaByID: [String: Data] = [:],
        generationByID: [String: SharingGenerationResume] = [:],
        reserveSteps: [RuntimeReserveStep] = []
    ) {
        self.manifest = manifest
        self.mediaByID = mediaByID
        self.generationByID = generationByID
        self.reserveSteps = reserveSteps
    }

    private func unsupported<T>() throws -> T { throw PairingError.invalidServerResponse }

    func reserveGeneration(
        mediaIDs: [String], clientRequestID: UUID, memberID: String,
        credential: PairingCredential
    ) async throws -> SharingReserveResult {
        guard !reserveSteps.isEmpty else { return try unsupported() }
        reserveRequestIDs.append(clientRequestID.uuidString.lowercased())
        reserveMediaIDs.append(mediaIDs)
        let step = reserveSteps.removeFirst()
        switch step {
        case .responseLost(_):
            // Represents a server commit followed by connection loss before
            // the authenticated response reaches the coordinator.
            throw URLError(.networkConnectionLost)
        case .success(let result):
            return result
        }
    }

    func freezeDescriptors(
        generationID: String, media: [StagedSharingMedia], clientRequestID: UUID,
        memberID: String, credential: PairingCredential
    ) async throws { throw PairingError.invalidServerResponse }

    func uploadMedia(
        generationID: String, mediaID: String, ciphertext: Data,
        expectedSHA256: String, memberID: String, credential: PairingCredential
    ) async throws { throw PairingError.invalidServerResponse }

    func prepare(
        generationID: String, clientRequestID: UUID, memberID: String,
        credential: PairingCredential
    ) async throws -> SharingPrepareResult { try unsupported() }

    func uploadManifest(
        generationID: String, attemptID: String, ciphertext: Data,
        expectedSHA256: String, memberID: String, credential: PairingCredential
    ) async throws { throw PairingError.invalidServerResponse }

    func commit(
        generationID: String, expectedSourceID: String, expectedShareDayKey: Int,
        prepare: PreparedSharingAttempt, memberID: String,
        credential: PairingCredential
    ) async throws -> SharingCommitResult { try unsupported() }

    func generation(
        generationID: String, expectedPublisherMemberID: String,
        memberID: String, credential: PairingCredential
    ) async throws -> SharingGenerationResume {
        guard let value = generationByID[generationID],
              value.publisherMemberID == expectedPublisherMemberID
        else { throw PairingError.invalidServerResponse }
        return value
    }

    func listSources(
        expectedPublisherMemberIDs: Set<String>, memberID: String,
        credential: PairingCredential
    ) async throws -> [SharingSourceSummary] { try unsupported() }

    func current(
        sourceID: String, eTag: String?, memberID: String,
        credential: PairingCredential
    ) async throws -> SharingCurrentFetch { try unsupported() }

    func downloadManifest(
        current: SharingCurrentGeneration, memberID: String,
        credential: PairingCredential
    ) async throws -> Data {
        guard PairingCrypto.sha256(manifest).base64URLEncodedString()
                == current.manifest.ciphertextSHA256,
              manifest.count == current.manifest.ciphertextSize
        else { throw PairingError.invalidServerResponse }
        manifestDownloadCount += 1
        return manifest
    }

    func downloadMedia(
        current: SharingCurrentGeneration,
        descriptor: SharingCurrentGeneration.MediaDescriptor,
        memberID: String, credential: PairingCredential
    ) async throws -> Data {
        guard let data = mediaByID[descriptor.mediaID],
              data.count == descriptor.ciphertextSize,
              PairingCrypto.sha256(data).base64URLEncodedString()
                == descriptor.ciphertextSHA256
        else { throw PairingError.invalidServerResponse }
        mediaDownloadCount += 1
        return data
    }

    func runtimeDownloadCounts() -> (manifest: Int, media: Int) {
        (manifestDownloadCount, mediaDownloadCount)
    }

    func runtimeReserveCalls() -> (requestIDs: [String], mediaIDs: [[String]]) {
        (reserveRequestIDs, reserveMediaIDs)
    }
}

private enum RuntimeMomentModerationStep: Sendable {
    case safe
    case failure(MomentSharingError)
}

private actor RuntimeMomentModerator: MomentModerating {
    private var steps: [RuntimeMomentModerationStep]
    private var analysisCount = 0

    init(steps: [RuntimeMomentModerationStep]) {
        self.steps = steps
    }

    func requireSafeImage(at url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path),
              (try Data(contentsOf: url)).isEmpty == false,
              !steps.isEmpty
        else { throw MomentSharingError.stateUnavailable }
        analysisCount += 1
        switch steps.removeFirst() {
        case .safe:
            return
        case .failure(let error):
            throw error
        }
    }

    func runtimeAnalysisCount() -> Int { analysisCount }
}

private actor RuntimeMomentAPI: MomentSharingAPIClientProtocol {
    private let change: MomentChange
    private let ciphertext: Data
    private var downloadCount = 0
    private var acknowledgementCount = 0

    init(change: MomentChange, ciphertext: Data) {
        self.change = change
        self.ciphertext = ciphertext
    }

    private func unsupported<T>() throws -> T {
        throw MomentSharingError.invalidPayload
    }

    func reserve(
        item: MomentOutboxItem,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentReservationResult { try unsupported() }

    func upload(
        momentID: String,
        ciphertext: Data,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws { throw MomentSharingError.invalidPayload }

    func commit(
        momentID: String,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentCommitResult { try unsupported() }

    func changes(
        after cursor: String?,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentChangesResult {
        if cursor == change.cursor {
            return MomentChangesResult(changes: [], nextCursor: change.cursor)
        }
        guard cursor == nil else { throw MomentSharingError.invalidPayload }
        return MomentChangesResult(changes: [change], nextCursor: change.cursor)
    }

    func download(
        momentID: String,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> Data {
        guard momentID == change.momentID else {
            throw MomentSharingError.invalidPayload
        }
        downloadCount += 1
        return ciphertext
    }

    func acknowledge(
        momentID: String,
        ciphertextSHA256: Data,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentAcknowledgementResult {
        guard momentID == change.momentID,
              ciphertextSHA256 == change.ciphertextSHA256
        else { throw MomentSharingError.invalidPayload }
        acknowledgementCount += 1
        return MomentAcknowledgementResult(
            momentID: momentID,
            acknowledgedAt: change.committedAt.addingTimeInterval(1),
            accessExpiresAt: change.accessExpiresAt
        )
    }

    func block(
        participantID: String,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentBlockResult { try unsupported() }

    func reserveReport(
        momentID: String,
        reason: MomentReportReason,
        prepared: MomentPreparedReport,
        clientRequestID: UUID,
        reporterConsentAcceptedAt: Date,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentReportReservationResult { try unsupported() }

    func uploadReport(
        reportID: String,
        ciphertext: Data,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws { throw MomentSharingError.invalidPayload }

    func commitReport(
        reportID: String,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentReportCommitResult { try unsupported() }

    func runtimeCounts() -> (downloads: Int, acknowledgements: Int) {
        (downloadCount, acknowledgementCount)
    }
}

private actor RuntimeWindowNameAPI: PrivateWindowNameAPIClientProtocol {
    private var getCount = 0
    private var putCount = 0

    func currentWindowName(
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> PrivateWindowNameRelayValue? {
        getCount += 1
        return nil
    }

    func putWindowName(
        _ payload: PrivateWindowNamePreparedPayload,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> PrivateWindowNameRelayValue {
        putCount += 1
        throw MomentSharingError.invalidPayload
    }

    func runtimeCounts() -> (gets: Int, puts: Int) {
        (getCount, putCount)
    }
}

private actor RuntimeMomentProcessQueueProbe {
    private struct RunWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var runCount = 0
    private var didReleaseFirst = false
    private var releasedFirstNotice: MomentSynchronizationNotice?
    private var firstRunContinuations: [
        CheckedContinuation<MomentSynchronizationNotice?, Never>
    ] = []
    private var runWaiters: [RunWaiter] = []

    func run(
        firstNotice: MomentSynchronizationNotice?,
        trailingNotice: MomentSynchronizationNotice?
    ) async -> MomentSynchronizationNotice? {
        runCount += 1
        let reached = runWaiters.filter { $0.expectedCount <= runCount }
        runWaiters.removeAll { $0.expectedCount <= runCount }
        for waiter in reached {
            waiter.continuation.resume()
        }
        guard runCount == 1 else { return trailingNotice }
        if didReleaseFirst { return releasedFirstNotice ?? firstNotice }
        return await withCheckedContinuation { continuation in
            firstRunContinuations.append(continuation)
        }
    }

    func count() -> Int { runCount }

    func waitUntilRunCount(_ expectedCount: Int) async {
        guard runCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            runWaiters.append(
                RunWaiter(
                    expectedCount: expectedCount,
                    continuation: continuation
                )
            )
        }
    }

    func releaseFirst(with notice: MomentSynchronizationNotice?) {
        didReleaseFirst = true
        releasedFirstNotice = notice
        let pending = firstRunContinuations
        firstRunContinuations.removeAll(keepingCapacity: true)
        for continuation in pending {
            continuation.resume(returning: notice)
        }
    }
}

/// DEBUG-only, generated-data runtime gate used by simulator smoke CI. The
/// report deliberately contains only fixed case identifiers and pass/fail
/// values—never paths, PhotoKit identifiers, keys, invite codes, or bytes.
actor SharingRuntimeSelfTestRunner {
    static let shared = SharingRuntimeSelfTestRunner()

    private static let launchArgument = "--sharing-runtime-self-test"
    private static let reportFilename = "sharing-runtime-self-test.json"
    private static let progressFilename = "sharing-runtime-self-test-progress.json"
    private var didRun = false

    private struct CaseResult: Codable {
        let id: String
        let status: String
    }

    private struct Report: Codable {
        let schemaVersion: Int
        let rendererVersion: String
        let status: String
        let cases: [CaseResult]
    }

    /// Fixed-string, DEBUG-only breadcrumb for diagnosing a simulator process
    /// that remains alive without publishing its final report. It deliberately
    /// contains no paths, identifiers, keys, image data, or error text.
    private struct Progress: Codable {
        let schemaVersion: Int
        let caseID: String
        let phase: String
    }

    private struct StoreFixture {
        let lifecycleToken: SharingLifecycleGate.Token
        let installationMarker: String
        let spaceID: String
        let memberID: String
        let peerMemberID: String
        let ownSourceID: String
        let ownGenerationID: String
        let ownAttemptID: String
        let ownMediaID: String
        let lease: DailySharingStateStore.SyncLease
        var state: DailySharingState
        var leaseChecksPassed: Bool
    }

    func runIfRequested() async {
        guard !didRun,
              CommandLine.arguments.contains(Self.launchArgument)
        else { return }
        didRun = true

        var results: [CaseResult] = []
        results.append(run("secure-file-attributes") {
            try Self.testSecureFileAttributes()
        })
        results.append(run("pairing-bootstrap-transient-preservation") {
            try Self.testPairingBootstrapTransientPreservation()
        })
        results.append(await runAsync("moment-process-serialized-refresh") {
            try await Self.testMomentProcessSerializedRefresh()
        })
        results.append(run("moment-terminal-authorization-classification") {
            try Self.testMomentTerminalAuthorizationClassification()
        })
        results.append(await runAsync("moment-install-bound-handoff") {
            try await Self.testMomentInstallBoundHandoff()
        })
        results.append(await runAsync("disabled-upgrade-purge") {
            try await Self.testDisabledUpgradePurge()
        })
        results.append(run("moment-report-only-terminal-gate") {
            try Self.testMomentReportOnlyTerminalGate()
        })
        results.append(run("moment-saved-memory-boundary") {
            try Self.testMomentSavedMemoryBoundary()
        })
        results.append(run("moment-sent-delivery-receipt-boundary") {
            try Self.testMomentSentDeliveryReceiptBoundary()
        })
        results.append(run("moment-empty-cursor-normalization") {
            try Self.testMomentEmptyCursorNormalization()
        })
        results.append(run("moment-expired-delivery-advances") {
            try Self.testMomentExpiredDeliveryPolicy()
        })
        results.append(run("moment-inbound-moderation-retry-policy") {
            try Self.testMomentInboundModerationRetryPolicy()
        })
        results.append(await runAsync("moment-inbound-moderation-flow") {
            try await Self.testMomentInboundModerationFlow()
        })
        results.append(run("moment-outbox-bounds-and-expiry") {
            try Self.testMomentOutboxBoundsAndExpiry()
        })
        results.append(run("moment-outcome-ledger-migration") {
            try Self.testMomentOutcomeLedgerAndMigration()
        })
        results.append(run("moment-commit-ack-metadata") {
            try Self.testMomentCommitAcknowledgementMetadata()
        })
        results.append(run("moment-report-outbox-bounds-and-recovery") {
            try Self.testMomentReportOutboxBoundsAndRecovery()
        })
        results.append(run("normalizer-orientation-scale-parity") {
            try Self.testNormalizerParity()
        })
        results.append(run("legacy-widget-cache-migration") {
            try Self.testLegacyWidgetCacheMigration()
        })
        results.append(run("canonical-local-only-privacy-budget") {
            try Self.testCanonicalPrivacyAndBudget()
        })
        results.append(run("diagnostic-persistence-privacy") {
            try Self.testDiagnosticPersistencePrivacy()
        })
        results.append(run("day-boundary-convergence") {
            try Self.testDayBoundaryConvergence()
        })

        var fixture: StoreFixture?
        Self.writeProgress(caseID: "store-fixture", phase: "started")
        do {
            fixture = try Self.makeStoreFixture()
            Self.writeProgress(caseID: "store-fixture", phase: "passed")
        } catch {
            fixture = nil
            Self.writeProgress(caseID: "store-fixture", phase: "failed")
        }

        if var value = fixture {
            results.append(run("daily-store-cas-highwater-anchor") {
                try Self.testStoreCASHighWaterAndAnchor(&value)
            })
            results.append(await runAsync("own-source-local-promotion") {
                try await Self.testOwnSourcePromotion(&value)
            })
            results.append(run("partial-download-resume-tamper") {
                try Self.testPartialDownloadAndTamper(&value)
            })
            results.append(await runAsync("retry-independent-deadline") {
                try await Self.testIndependentRetryState(&value)
            })
            results.append(await runAsync("lease-heartbeat") {
                try await Self.finishLeaseChecks(&value)
            })
            results.append(await runAsync("peer-revoke-terminal-purge") {
                try await Self.testTerminalPurge(value)
            })
            fixture = value
        } else {
            for id in [
                "daily-store-cas-highwater-anchor",
                "own-source-local-promotion",
                "partial-download-resume-tamper",
                "retry-independent-deadline",
                "lease-heartbeat",
                "peer-revoke-terminal-purge"
            ] {
                results.append(CaseResult(id: id, status: "failed"))
            }
        }

        let passed = results.allSatisfy { $0.status == "passed" }
        let report = Report(
            schemaVersion: 1,
            rendererVersion: WidgetRenderPlanner.rendererVersion,
            status: passed ? "passed" : "failed",
            cases: results.sorted { $0.id < $1.id }
        )
        guard let root = SharedContainer.containerURL else { return }
        let url = root.appendingPathComponent(Self.reportFilename, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            // This DEBUG-only report contains fixed case IDs and pass/fail
            // values only. It must remain observable even when the test is
            // diagnosing the secure writer itself on Simulator.
            let data = try encoder.encode(report)
            try data.write(to: url, options: .atomic)
            Self.writeProgress(caseID: "report", phase: "published")
        } catch {
            Self.writeProgress(caseID: "report", phase: "failed")
            assertionFailure("Sharing runtime self-test report publication failed")
        }
    }

    private func run(_ id: String, _ body: () throws -> Void) -> CaseResult {
        Self.writeProgress(caseID: id, phase: "started")
        do {
            try body()
            Self.writeProgress(caseID: id, phase: "passed")
            return CaseResult(id: id, status: "passed")
        } catch {
            Self.writeProgress(caseID: id, phase: "failed")
            return CaseResult(id: id, status: "failed")
        }
    }

    private func runAsync(
        _ id: String,
        _ body: () async throws -> Void
    ) async -> CaseResult {
        Self.writeProgress(caseID: id, phase: "started")
        do {
            try await body()
            Self.writeProgress(caseID: id, phase: "passed")
            return CaseResult(id: id, status: "passed")
        } catch {
            Self.writeProgress(caseID: id, phase: "failed")
            return CaseResult(id: id, status: "failed")
        }
    }

    private static func testPairingBootstrapTransientPreservation() throws {
        guard PairingKeychainStore.readStatusDisposition(errSecSuccess) == .success,
              PairingKeychainStore.readStatusDisposition(errSecItemNotFound) == .missing,
              PairingKeychainStore.readStatusDisposition(errSecInteractionNotAllowed)
                == .retryable(.protectedDataUnavailable),
              PairingKeychainStore.readStatusDisposition(errSecNotAvailable)
                == .retryable(.protectedDataUnavailable),
              PairingKeychainStore.readStatusDisposition(errSecParam)
                == .retryable(.keychainUnavailable)
        else { throw PairingError.stateUnavailable }

        let missingCocoaFile = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadNoSuchFile.rawValue
        )
        let missingPOSIXFile = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        let wrappedMissingFile = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: missingPOSIXFile]
        )
        let unavailableFile = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadNoPermission.rawValue
        )
        guard SharingFileReadFailureClassifier.disposition(missingCocoaFile) == .missing,
              SharingFileReadFailureClassifier.disposition(wrappedMissingFile) == .missing,
              SharingFileReadFailureClassifier.disposition(unavailableFile) == .retryable,
              PairingViewModel.runtimeTestIsRetryableBootstrapCompletionError(
                SharingSecureFile.Error.cannotCreateTemporaryFile
              ),
              PairingViewModel.runtimeTestIsRetryableBootstrapCompletionError(
                DailySharingError.stateUnavailable
              )
        else { throw PairingError.stateUnavailable }

        let directProtectionFailure = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadNoPermission.rawValue
        )
        guard PairingInstallationGuard.pairingStateLoadFailureDisposition(
            directProtectionFailure
        ) == .retryable(.pairingStateProtectedDataUnavailable) else {
            throw PairingError.stateUnavailable
        }

        let underlyingProtectionFailure = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EACCES)
        )
        let wrappedProtectionFailure = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: underlyingProtectionFailure]
        )
        guard PairingInstallationGuard.pairingStateLoadFailureDisposition(
            wrappedProtectionFailure
        ) == .retryable(.pairingStateProtectedDataUnavailable) else {
            throw PairingError.stateUnavailable
        }

        let genericReadFailure = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadUnknown.rawValue
        )
        guard PairingInstallationGuard.pairingStateLoadFailureDisposition(
            genericReadFailure
        ) == .retryable(.pairingStateReadUnavailable),
              PairingInstallationGuard.pairingStateLoadFailureDisposition(
                PairingError.stateUnavailable
              ) == .retryable(.pairingStateReadUnavailable),
              PairingInstallationGuard.pairingStateLoadFailureDisposition(
                PairingStateStore.LoadError.invalidState
              ) == .failClosed
        else { throw PairingError.stateUnavailable }

        let malformedState = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "runtime generated malformed state")
        )
        guard PairingInstallationGuard.pairingStateLoadFailureDisposition(
            malformedState
        ) == .failClosed else {
            throw PairingError.stateUnavailable
        }
    }

    private static func testDiagnosticPersistencePrivacy() throws {
        let legacyPayload =
            "https://example.invalid/private/var/mobile/secret?token=SUPERSECRET\nsecond-line"
        var snapshot = LibrarySnapshot.empty
        snapshot.scanState.lastError = legacyPayload
        let url = try JSONExporter().export(snapshot)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in [
            "SUPERSECRET",
            "example.invalid",
            "/private/var/",
            "second-line",
        ] where text.contains(forbidden) {
            throw MomentSharingError.stateUnavailable
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scanState = root["scanState"] as? [String: Any],
              scanState["lastError"] as? String
                == DiagnosticLogPrivacy.persistedScanFailureCopy
        else { throw MomentSharingError.stateUnavailable }
    }

    private static func writeProgress(caseID: String, phase: String) {
        guard let root = SharedContainer.containerURL else { return }
        let value = Progress(schemaVersion: 1, caseID: caseID, phase: phase)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        let url = root.appendingPathComponent(progressFilename, isDirectory: false)
        try? data.write(to: url, options: .atomic)
    }

    private static func testSecureFileAttributes() throws {
        guard let root = SharedContainer.containerURL else {
            throw DailySharingError.stateUnavailable
        }
        let url = root.appendingPathComponent(".sharing-runtime-secure", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try SharingSecureFile.write(Data("runtime".utf8), to: url)
#if targetEnvironment(simulator)
        // Simulator lacks reliable Data Protection read-back; the production
        // helper still proves that backup exclusion was set on this inode.
#endif
        guard SharingSecureFile.hasRequiredProtectionAndBackupExclusion(url) else {
            throw DailySharingError.stateUnavailable
        }
    }

    private static func testMomentProcessSerializedRefresh() async throws {
        let firstCoordinator = MomentSharingCoordinator()
        let joinedCoordinator = MomentSharingCoordinator()
        let probe = RuntimeMomentProcessQueueProbe()
        let ownerNotice = MomentSynchronizationNotice.inboundModerationUnavailable
        let trailingNotice = MomentSynchronizationNotice.inboundModerationDisabled
        let first = Task {
            await firstCoordinator.runtimeTestJoinProcessSynchronization {
                await probe.run(
                    firstNotice: ownerNotice,
                    trailingNotice: trailingNotice
                )
            }
        }
        await probe.waitUntilRunCount(1)

        let joined = Task {
            await joinedCoordinator.runtimeTestJoinProcessSynchronization {
                await probe.run(
                    firstNotice: ownerNotice,
                    trailingNotice: trailingNotice
                )
            }
        }
        await firstCoordinator.runtimeTestWaitUntilProcessSynchronizationIsPending()
        await probe.releaseFirst(with: ownerNotice)
        await probe.waitUntilRunCount(2)
        let firstResult = await first.value
        let joinedResult = await joined.value
        let actualRunCount = await probe.count()
        let firstRecordedNotice = await firstCoordinator.synchronizationNotice()
        let joinedRecordedNotice = await joinedCoordinator.synchronizationNotice()
        guard actualRunCount == 2,
              firstResult == ownerNotice,
              joinedResult == trailingNotice,
              firstRecordedNotice == ownerNotice,
              joinedRecordedNotice == trailingNotice
        else { throw MomentSharingError.stateUnavailable }

        // A cancelled queued caller must release its reserved turn without
        // running, and the next caller must execute in its own active Task.
        let cancellationOwner = MomentSharingCoordinator()
        let cancelledCoordinator = MomentSharingCoordinator()
        let activeCoordinator = MomentSharingCoordinator()
        let cancellationProbe = RuntimeMomentProcessQueueProbe()
        let cancellationOwnerTask = Task {
            await cancellationOwner.runtimeTestJoinProcessSynchronization {
                await cancellationProbe.run(
                    firstNotice: ownerNotice,
                    trailingNotice: trailingNotice
                )
            }
        }
        await cancellationProbe.waitUntilRunCount(1)
        let cancelledTask = Task {
            await cancelledCoordinator.runtimeTestJoinProcessSynchronization {
                await cancellationProbe.run(
                    firstNotice: ownerNotice,
                    trailingNotice: trailingNotice
                )
            }
        }
        await cancellationOwner.runtimeTestWaitUntilProcessSynchronizationIsPending()
        cancelledTask.cancel()
        let activeTask = Task {
            await activeCoordinator.runtimeTestJoinProcessSynchronization {
                await cancellationProbe.run(
                    firstNotice: ownerNotice,
                    trailingNotice: trailingNotice
                )
            }
        }
        await cancellationOwner.runtimeTestWaitUntilProcessSynchronizationIsPending(
            count: 2
        )
        await cancellationProbe.releaseFirst(with: ownerNotice)
        await cancellationProbe.waitUntilRunCount(2)
        let cancellationOwnerResult = await cancellationOwnerTask.value
        let cancelledResult = await cancelledTask.value
        let activeResult = await activeTask.value
        let cancellationRunCount = await cancellationProbe.count()
        guard cancellationRunCount == 2,
              cancellationOwnerResult == ownerNotice,
              cancelledResult == nil,
              activeResult == trailingNotice
        else { throw MomentSharingError.stateUnavailable }

        // The next caller must not inherit cancellation from the Task that
        // previously owned the process permit.
        let cancelledOwnerCoordinator = MomentSharingCoordinator()
        let unaffectedCoordinator = MomentSharingCoordinator()
        let ownerCancellationProbe = RuntimeMomentProcessQueueProbe()
        let cancelledOwnerTask = Task {
            await cancelledOwnerCoordinator.runtimeTestJoinProcessSynchronization {
                await ownerCancellationProbe.run(
                    firstNotice: ownerNotice,
                    trailingNotice: trailingNotice
                )
            }
        }
        await ownerCancellationProbe.waitUntilRunCount(1)
        let unaffectedTask = Task {
            await unaffectedCoordinator.runtimeTestJoinProcessSynchronization {
                Task.isCancelled ? ownerNotice : trailingNotice
            }
        }
        await cancelledOwnerCoordinator
            .runtimeTestWaitUntilProcessSynchronizationIsPending()
        cancelledOwnerTask.cancel()
        await ownerCancellationProbe.releaseFirst(with: ownerNotice)
        let cancelledOwnerValue = await cancelledOwnerTask.value
        let unaffectedValue = await unaffectedTask.value
        guard cancelledOwnerValue == ownerNotice,
              unaffectedValue == trailingNotice
        else { throw MomentSharingError.stateUnavailable }
    }

    /// Only an exact, authenticated authorization-wide terminal response may
    /// destroy the room credential. Resource 410s and undecodable future 410s
    /// remain paired so a later synchronization can reconcile them.
    private static func testMomentTerminalAuthorizationClassification() throws {
        let cases: [(MomentSharingError, Bool, String)] = [
            (
                .requestRejected(
                    status: 410,
                    code: "sharing_revoked",
                    message: "ignored"
                ),
                true,
                "remote-authorization-terminal"
            ),
            (
                .requestRejected(
                    status: 401,
                    code: "invalid_authentication",
                    message: "ignored"
                ),
                false,
                "request-rejected-nonterminal"
            ),
            (
                .requestRejected(
                    status: 410,
                    code: "reservation_expired",
                    message: "ignored"
                ),
                false,
                "resource-gone-nonterminal"
            ),
            (
                .requestRejected(
                    status: 410,
                    code: "report_window_closed",
                    message: "ignored"
                ),
                false,
                "resource-gone-nonterminal"
            ),
            (
                .requestRejected(
                    status: 410,
                    code: "report_unavailable",
                    message: "ignored"
                ),
                false,
                "resource-gone-nonterminal"
            ),
            (
                .requestRejected(
                    status: 410,
                    code: "window_name_unavailable",
                    message: "ignored"
                ),
                false,
                "resource-gone-nonterminal"
            ),
            (
                .requestRejected(status: 410, code: nil, message: "ignored"),
                false,
                "resource-gone-nonterminal"
            ),
            (
                .requestRejected(
                    status: 409,
                    code: "sharing_revoked",
                    message: "ignored"
                ),
                false,
                "request-rejected-nonterminal"
            ),
            (.stateUnavailable, false, "local-state-unavailable")
        ]

        for (error, shouldReset, expectedReason) in cases {
            guard MomentSharingCoordinator.runtimeRequiresLocalRevocationReset(error)
                    == shouldReset,
                  MomentSharingCoordinator.runtimeLocalFailureReason(error)
                    == expectedReason
            else { throw MomentSharingError.stateUnavailable }
        }

        guard MomentSharingCoordinator.runtimeIsNonterminalAuthenticationFailure(
            cases[1].0
        ),
        !MomentSharingCoordinator.runtimeIsNonterminalAuthenticationFailure(cases[0].0),
        !MomentSharingCoordinator.runtimeIsNonterminalAuthenticationFailure(
            MomentSharingError.requestRejected(
                status: 401,
                code: nil,
                message: "ignored"
            )
        ) else { throw MomentSharingError.stateUnavailable }

        guard DailySharingSyncCoordinator.isRemoteRevocation(
            PairingError.requestRejected(
                status: 410,
                code: "sharing_revoked",
                message: "ignored"
            )
        ), !DailySharingSyncCoordinator.isRemoteRevocation(
            PairingError.requestRejected(
                status: 401,
                code: "invalid_authentication",
                message: "ignored"
            )
        ), !DailySharingSyncCoordinator.isRemoteRevocation(
            PairingError.requestRejected(status: 410, code: nil, message: "ignored")
        ), PairingViewModel.runtimeServerConfirmsPairingIsGone(
            PairingError.requestRejected(
                status: 410,
                code: "sharing_revoked",
                message: "ignored"
            )
        ), !PairingViewModel.runtimeServerConfirmsPairingIsGone(
            PairingError.requestRejected(
                status: 401,
                code: "invalid_authentication",
                message: "ignored"
            )
        ), !PairingViewModel.runtimeServerConfirmsPairingIsGone(
            PairingError.requestRejected(status: 410, code: nil, message: "ignored")
        ) else { throw PairingError.stateUnavailable }
    }

    private static func testMomentDeviceIdentityResolution() throws {
        let memberID = "member_device_identity_fixture"
        let spaceID = "space_device_identity_fixture"
        let recoveredDeviceID = "device_recovered_fixture"
        let peerReplacementDeviceID = "device_peer_replacement_fixture"

        var ordinary = PairingState.unpaired(installationMarker: UUID().uuidString)
        ordinary.spaceID = spaceID
        ordinary.memberID = memberID
        guard ordinary.resolvedLocalMomentDeviceID == memberID else {
            throw MomentSharingError.stateUnavailable
        }

        // Build and decode a fully valid paired recovery state with the field
        // removed, matching bytes written by Build 41.
        let installationMarker = UUID().uuidString
        let localCredential = PairingCrypto.makeCredential(
            installationMarker: installationMarker,
            includesInvitationSecret: false,
            includesRoomKey: true
        )
        let peerCredential = PairingCrypto.makeCredential(
            installationMarker: installationMarker,
            includesInvitationSecret: false,
            includesRoomKey: true
        )
        let previousCredential = PairingCrypto.makeCredential(
            installationMarker: installationMarker,
            includesInvitationSecret: false,
            includesRoomKey: true
        )
        let recoveryTranscript = Data("device-identity-recovery".utf8)
        let recoveryHash = PairingCrypto.sha256(recoveryTranscript)
        var build41Recovery = PairingState.unpaired(
            installationMarker: installationMarker
        )
        build41Recovery.phase = .paired
        build41Recovery.role = .inviter
        build41Recovery.credentialAccount = localCredential.account
        build41Recovery.participantID = localCredential.participantIDString
        build41Recovery.spaceID = spaceID
        build41Recovery.memberID = memberID
        build41Recovery.peerMemberID = "member_peer_device_identity_fixture"
        build41Recovery.peerParticipantID = peerCredential.participantIDString
        build41Recovery.peerAgreementPublicKey = try PairingCrypto
            .agreementPublicKey(for: peerCredential).base64URLEncodedString()
        build41Recovery.peerSigningPublicKey = try PairingCrypto
            .signingPublicKey(for: peerCredential).base64URLEncodedString()
        build41Recovery.recoveryID = "recovery_device_identity_fixture"
        build41Recovery.recoveryExpiresAt = Date().addingTimeInterval(3_600)
        build41Recovery.recoveryMembershipRevision = 1
        build41Recovery.recoveryKeyEpoch = 1
        build41Recovery.recoveryDeviceID = recoveredDeviceID
        build41Recovery.recoveryPreviousTargetAgreementPublicKey = try PairingCrypto
            .agreementPublicKey(for: previousCredential).base64URLEncodedString()
        build41Recovery.recoveryPreviousTargetSigningPublicKey = try PairingCrypto
            .signingPublicKey(for: previousCredential).base64URLEncodedString()
        build41Recovery.recoveryCandidateAgreementPublicKey = try PairingCrypto
            .agreementPublicKey(for: localCredential).base64URLEncodedString()
        build41Recovery.recoveryCandidateSigningPublicKey = try PairingCrypto
            .signingPublicKey(for: localCredential).base64URLEncodedString()
        build41Recovery.recoveryTranscript = recoveryTranscript.base64URLEncodedString()
        build41Recovery.recoveryTranscriptHash = recoveryHash.base64URLEncodedString()
        build41Recovery.recoveryVerificationPhrase = PairingCrypto
            .verificationPhrase(for: recoveryHash)
        build41Recovery.recoveryCompletedAt = Date()
        build41Recovery.recoveryWasLocalDeviceReplacement = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var legacyObject = try JSONSerialization.jsonObject(
            with: encoder.encode(build41Recovery)
        ) as? [String: Any]
        legacyObject?.removeValue(forKey: "localMomentDeviceID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject ?? [:])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let migratedRecovery = try decoder.decode(PairingState.self, from: legacyData)
            .validated()
        guard migratedRecovery.localMomentDeviceID == recoveredDeviceID,
              migratedRecovery.resolvedLocalMomentDeviceID == recoveredDeviceID
        else {
            throw MomentSharingError.stateUnavailable
        }

        // Sponsoring a peer recovery must not change this installation's
        // relay device identity, even though recoveryDeviceID is reused by the
        // current recovery ceremony.
        var stableRecovery = migratedRecovery
        stableRecovery.localMomentDeviceID = recoveredDeviceID
        stableRecovery.recoveryDeviceID = peerReplacementDeviceID
        guard stableRecovery.resolvedLocalMomentDeviceID == recoveredDeviceID else {
            throw MomentSharingError.stateUnavailable
        }

        var sponsor = ordinary
        sponsor.recoveryDeviceID = peerReplacementDeviceID
        sponsor.recoveryWasLocalDeviceReplacement = false
        guard sponsor.resolvedLocalMomentDeviceID == memberID else {
            throw MomentSharingError.stateUnavailable
        }

        let recoveredContext = MomentRequestContext(
            spaceID: spaceID,
            senderParticipantID: memberID,
            senderDeviceID: recoveredDeviceID,
            clientRequestID: UUID(),
            clientMomentID: UUID(),
            kind: .live,
            keyEpoch: 1
        )
        guard MomentReservationIdentityPolicy.accepts(
            context: recoveredContext,
            pairingState: migratedRecovery,
            responseSpaceID: spaceID,
            responseParticipantID: memberID,
            responseDeviceID: recoveredDeviceID
        ), !MomentReservationIdentityPolicy.accepts(
            context: recoveredContext,
            pairingState: migratedRecovery,
            responseSpaceID: spaceID,
            responseParticipantID: memberID,
            responseDeviceID: memberID
        ), !MomentReservationIdentityPolicy.accepts(
            context: recoveredContext,
            pairingState: migratedRecovery,
            responseSpaceID: spaceID,
            responseParticipantID: memberID,
            responseDeviceID: peerReplacementDeviceID
        ) else { throw MomentSharingError.stateUnavailable }

        let build41Context = MomentRequestContext(
            spaceID: spaceID,
            senderParticipantID: memberID,
            senderDeviceID: memberID,
            clientRequestID: UUID(),
            clientMomentID: UUID(),
            kind: .live,
            keyEpoch: 1
        )
        guard MomentReservationIdentityPolicy.acceptsContext(
            build41Context,
            pairingState: migratedRecovery
        ), MomentReservationIdentityPolicy.accepts(
            context: build41Context,
            pairingState: migratedRecovery,
            responseSpaceID: spaceID,
            responseParticipantID: memberID,
            responseDeviceID: recoveredDeviceID
        ) else { throw MomentSharingError.stateUnavailable }

        let ordinaryContext = MomentRequestContext(
            spaceID: spaceID,
            senderParticipantID: memberID,
            senderDeviceID: memberID,
            clientRequestID: UUID(),
            clientMomentID: UUID(),
            kind: .live,
            keyEpoch: 1
        )
        guard MomentReservationIdentityPolicy.accepts(
            context: ordinaryContext,
            pairingState: sponsor,
            responseSpaceID: spaceID,
            responseParticipantID: memberID,
            responseDeviceID: memberID
        ) else { throw MomentSharingError.stateUnavailable }
    }

    /// The Share Extension may only leave a bounded, short-lived canonical
    /// input. A host-issued binding change and an installation reset must
    /// remove it before any room credential or network client is involved.
    private static func testMomentInstallBoundHandoff() async throws {
        try testMomentDeviceIdentityResolution()
        let initial = try PairingInstallationGuard.bootstrap()
        _ = try PairingInstallationGuard.resetLocalSharing(
            expectedState: initial.state,
            lifecycleToken: initial.lifecycleToken,
            message: nil
        )
        let bootstrap = try PairingInstallationGuard.bootstrap()
        let token = bootstrap.lifecycleToken
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let acceptedAt = base.addingTimeInterval(-1)
        let preview = try MomentCanonicalPreviewBuilder.build(image: generatedImage())
        let privateMetadataJPEG = try momentJPEGWithSyntheticPrivateMetadata(preview.jpeg)
        guard MomentCanonicalPreviewBuilder.runtimeSelfTestStrippingPrivateMetadata(
            from: privateMetadataJPEG
        ) == preview.jpeg else { throw MomentSharingError.invalidPayload }
        do {
            try MomentCanonicalPreviewBuilder.validateReceived(
                privateMetadataJPEG,
                pixelWidth: preview.pixelWidth,
                pixelHeight: preview.pixelHeight,
                expectedPlaintextSHA256: PairingCrypto.sha256(privateMetadataJPEG)
            )
            throw MomentSharingError.stateUnavailable
        } catch let error as MomentSharingError {
            guard error == .invalidPayload else { throw error }
        }

        let firstCatalog = try MomentShareHandoffStore.publishAdmissions(
            [MomentShareAdmissionInput(
                bindingSHA256: Data(repeating: 0x51, count: 32),
                displayName: "家族のまど"
            )],
            validating: token,
            now: base
        )
        guard let firstAdmission = firstCatalog.destinations.first else {
            throw MomentSharingError.stateUnavailable
        }
        let renewedAdmission = MomentShareDestinationAdmission(
            id: firstAdmission.id,
            bindingSHA256: firstAdmission.bindingSHA256,
            displayName: firstAdmission.displayName,
            issuedAt: base,
            expiresAt: base.addingTimeInterval(
                60 + MomentShareHandoffStore.admissionLifetime
            )
        )
        let renewedCatalog = try MomentShareAdmissionCatalog(
            destinations: [renewedAdmission],
            updatedAt: base.addingTimeInterval(60)
        ).validated()
        guard renewedCatalog.isCurrent(at: base.addingTimeInterval(60)),
              !renewedCatalog.isCurrent(
                  at: base.addingTimeInterval(
                    -MomentShareHandoffStore.maximumLocalClockSkew - 1
                  )
              )
        else { throw MomentSharingError.stateUnavailable }
        do {
            _ = try MomentShareAdmissionCatalog(
                destinations: [MomentShareDestinationAdmission(
                    id: firstAdmission.id,
                    bindingSHA256: firstAdmission.bindingSHA256,
                    displayName: firstAdmission.displayName,
                    issuedAt: base,
                    expiresAt: base.addingTimeInterval(
                        MomentShareHandoffStore.admissionLifetime + 61
                    )
                )],
                updatedAt: base.addingTimeInterval(60)
            ).validated()
            throw MomentSharingError.stateUnavailable
        } catch MomentSharingError.stateUnavailable {
            // A catalog deadline is bounded by its latest host renewal.
        }

        var staged: [MomentPendingCaptureRecord] = []
        for offset in 0..<MomentShareHandoffStore.maximumPendingCaptureCount {
            let record = try MomentShareHandoffStore.stageCapture(
                admissionID: firstAdmission.id,
                canonicalJPEG: preview.jpeg,
                capturedAt: nil,
                pixelWidth: preview.pixelWidth,
                pixelHeight: preview.pixelHeight,
                senderPolicyVersion: 1,
                senderPolicyAcceptedAt: acceptedAt,
                now: base.addingTimeInterval(TimeInterval(offset))
            )
            guard MomentShareHandoffStore.captureHasRequiredProtection(record) else {
                throw MomentSharingError.stateUnavailable
            }
            staged.append(record)
        }
        guard staged.count == MomentShareHandoffStore.maximumPendingCaptureCount else {
            throw MomentSharingError.stateUnavailable
        }

        // A presentation-only rename must retain the admission identity and
        // every staged capture. Only a pairing binding change may revoke them.
        let renamedCatalog = try MomentShareHandoffStore.publishAdmissions(
            [MomentShareAdmissionInput(
                bindingSHA256: firstAdmission.bindingSHA256,
                displayName: "しずくのまど"
            )],
            validating: token,
            now: base.addingTimeInterval(5)
        )
        guard let renamedAdmission = renamedCatalog.destinations.first,
              renamedAdmission.id == firstAdmission.id,
              renamedAdmission.displayName == "しずくのまど",
              try MomentShareHandoffStore.nextPendingCapture(
                  admissionID: renamedAdmission.id,
                  validating: token,
                  now: base.addingTimeInterval(5)
              ) != nil
        else { throw MomentSharingError.stateUnavailable }
        do {
            _ = try MomentShareHandoffStore.stageCapture(
                admissionID: firstAdmission.id,
                canonicalJPEG: preview.jpeg,
                capturedAt: nil,
                pixelWidth: preview.pixelWidth,
                pixelHeight: preview.pixelHeight,
                senderPolicyVersion: 1,
                senderPolicyAcceptedAt: acceptedAt,
                now: base.addingTimeInterval(4)
            )
            throw MomentSharingError.stateUnavailable
        } catch let error as MomentSharingError {
            guard error == .outboxFull else { throw error }
        }

        // A different current installation/pairing binding keeps no capture
        // admitted by the previous one.
        let secondCatalog = try MomentShareHandoffStore.publishAdmissions(
            [MomentShareAdmissionInput(
                bindingSHA256: Data(repeating: 0x52, count: 32),
                displayName: "家族のまど"
            )],
            validating: token,
            now: base.addingTimeInterval(10)
        )
        guard let secondAdmission = secondCatalog.destinations.first,
              secondAdmission.id != firstAdmission.id,
              try MomentShareHandoffStore.nextPendingCapture(
                  admissionID: firstAdmission.id,
                  validating: token,
                  now: base.addingTimeInterval(10)
              ) == nil
        else { throw MomentSharingError.stateUnavailable }

        let pending = try MomentShareHandoffStore.stageCapture(
            admissionID: secondAdmission.id,
            canonicalJPEG: preview.jpeg,
            capturedAt: nil,
            pixelWidth: preview.pixelWidth,
            pixelHeight: preview.pixelHeight,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: acceptedAt,
            now: base.addingTimeInterval(11)
        )
        let overlongCapture = MomentPendingCaptureRecord(
            id: pending.id,
            clientRequestID: pending.clientRequestID,
            admissionID: pending.admissionID,
            kind: pending.kind,
            canonicalJPEG: pending.canonicalJPEG,
            canonicalJPEGSize: pending.canonicalJPEGSize,
            canonicalJPEGSHA256: pending.canonicalJPEGSHA256,
            pixelWidth: pending.pixelWidth,
            pixelHeight: pending.pixelHeight,
            capturedAt: pending.capturedAt,
            captureDateIsMissing: pending.captureDateIsMissing,
            requiredHostModerationVersion: pending.requiredHostModerationVersion,
            requiresHostModeration: pending.requiresHostModeration,
            senderPolicyVersion: pending.senderPolicyVersion,
            senderPolicyAcceptedAt: pending.senderPolicyAcceptedAt,
            createdAt: pending.createdAt,
            expiresAt: pending.createdAt.addingTimeInterval(
                MomentShareHandoffStore.captureLifetime + 1
            ),
            updatedAt: pending.updatedAt,
            phase: pending.phase,
            claimID: pending.claimID,
            claimedAt: pending.claimedAt,
            nextRetryAt: pending.nextRetryAt,
            lastErrorCode: pending.lastErrorCode
        )
        do {
            _ = try overlongCapture.validated()
            throw MomentSharingError.stateUnavailable
        } catch MomentSharingError.stateUnavailable {
            // App Group bytes cannot grant plaintext retention beyond one hour.
        }
        guard let claim = try MomentShareHandoffStore.claimCapture(
            pending,
            validating: token,
            now: base.addingTimeInterval(12)
        ), try MomentShareHandoffStore.claimCapture(
            pending,
            validating: token,
            now: base.addingTimeInterval(12)
        ) == nil,
        try MomentShareHandoffStore.nextPendingCapture(
            admissionID: secondAdmission.id,
            validating: token,
            now: base.addingTimeInterval(13)
        ) == nil
        else { throw MomentSharingError.stateUnavailable }

        let recoveredAt = base.addingTimeInterval(
            12 + MomentShareHandoffStore.claimRecoveryInterval
        )
        guard let recovered = try MomentShareHandoffStore.nextPendingCapture(
            admissionID: secondAdmission.id,
            validating: token,
            now: recoveredAt
        ), recovered.id == claim.record.id, recovered.phase == .pending else {
            throw MomentSharingError.stateUnavailable
        }

        let expiredReadAt = base.addingTimeInterval(
            MomentShareHandoffStore.captureLifetime + 12
        )
        _ = try MomentShareHandoffStore.activeAdmissions(now: expiredReadAt)
        guard !MomentShareHandoffStore.captureExists(recovered) else {
            throw MomentSharingError.stateUnavailable
        }
        let expiredPresentation = try MomentShareHandoffStore.presentationSnapshot(
            now: expiredReadAt
        )
        guard expiredPresentation.statuses.isEmpty,
              expiredPresentation.terminalOutcomes.count == 1,
              expiredPresentation.terminalOutcomes[0].reason == .preparationExpired,
              expiredPresentation.terminalOutcomes[0].createdAt == recovered.expiresAt
        else { throw MomentSharingError.stateUnavailable }
        guard try MomentShareHandoffStore.nextPendingCapture(
            admissionID: secondAdmission.id,
            validating: token,
            now: expiredReadAt
        ) == nil else { throw MomentSharingError.stateUnavailable }

        try MomentShareHandoffStore.clearTerminalOutcomes(validating: token)
        guard try MomentShareHandoffStore.presentationSnapshot(
            now: expiredReadAt
        ).terminalOutcomes.isEmpty else {
            throw MomentSharingError.stateUnavailable
        }

        let releaseExpired = try MomentShareHandoffStore.stageCapture(
            admissionID: secondAdmission.id,
            canonicalJPEG: preview.jpeg,
            capturedAt: nil,
            pixelWidth: preview.pixelWidth,
            pixelHeight: preview.pixelHeight,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: acceptedAt,
            now: base.addingTimeInterval(3_650)
        )
        guard let releaseExpiredClaim = try MomentShareHandoffStore.claimCapture(
            releaseExpired,
            validating: token,
            now: base.addingTimeInterval(3_651)
        ) else { throw MomentSharingError.stateUnavailable }
        try MomentShareHandoffStore.releaseCapture(
            releaseExpiredClaim,
            retryAt: releaseExpired.expiresAt,
            errorCode: "moderation-unavailable",
            validating: token,
            now: base.addingTimeInterval(3_652)
        )
        let releaseExpiredPresentation = try MomentShareHandoffStore.presentationSnapshot(
            now: base.addingTimeInterval(3_652)
        )
        guard !MomentShareHandoffStore.captureExists(releaseExpired),
              releaseExpiredPresentation.statuses.isEmpty,
              releaseExpiredPresentation.terminalOutcomes.count == 1,
              releaseExpiredPresentation.terminalOutcomes[0].reason == .preparationExpired,
              releaseExpiredPresentation.terminalOutcomes[0].createdAt
                == base.addingTimeInterval(3_652)
        else { throw MomentSharingError.stateUnavailable }
        try MomentShareHandoffStore.clearTerminalOutcomes(validating: token)

        let failedPreparation = try MomentShareHandoffStore.stageCapture(
            admissionID: secondAdmission.id,
            canonicalJPEG: preview.jpeg,
            capturedAt: nil,
            pixelWidth: preview.pixelWidth,
            pixelHeight: preview.pixelHeight,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: acceptedAt,
            now: base.addingTimeInterval(3_660)
        )
        guard let failedPreparationClaim = try MomentShareHandoffStore.claimCapture(
            failedPreparation,
            validating: token,
            now: base.addingTimeInterval(3_661)
        ) else { throw MomentSharingError.stateUnavailable }
        try MomentShareHandoffStore.discardCapture(
            failedPreparationClaim,
            recording: .preparationFailed,
            validating: token,
            now: base.addingTimeInterval(3_662)
        )
        let failedPreparationPresentation = try MomentShareHandoffStore
            .presentationSnapshot(now: base.addingTimeInterval(3_662))
        guard !MomentShareHandoffStore.captureExists(failedPreparation),
              failedPreparationPresentation.statuses.isEmpty,
              failedPreparationPresentation.terminalOutcomes.count == 1,
              failedPreparationPresentation.terminalOutcomes[0].reason
                == .preparationFailed
        else { throw MomentSharingError.stateUnavailable }
        try MomentShareHandoffStore.clearTerminalOutcomes(validating: token)

        let cancelPending = try MomentShareHandoffStore.stageCapture(
            admissionID: secondAdmission.id,
            canonicalJPEG: preview.jpeg,
            capturedAt: nil,
            pixelWidth: preview.pixelWidth,
            pixelHeight: preview.pixelHeight,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: acceptedAt,
            now: base.addingTimeInterval(3_700)
        )
        let cancelProcessing = try MomentShareHandoffStore.stageCapture(
            admissionID: secondAdmission.id,
            canonicalJPEG: preview.jpeg,
            capturedAt: nil,
            pixelWidth: preview.pixelWidth,
            pixelHeight: preview.pixelHeight,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: acceptedAt,
            now: base.addingTimeInterval(3_701)
        )
        guard let cancelledClaim = try MomentShareHandoffStore.claimCapture(
            cancelProcessing,
            validating: token,
            now: base.addingTimeInterval(3_702)
        ) else { throw MomentSharingError.stateUnavailable }
        let cancellationPresentation = try MomentShareHandoffStore.presentationSnapshot(
            now: base.addingTimeInterval(3_703)
        )
        let discardedPreparationCount = try MomentShareHandoffStore
            .discardCancellableCaptures(validating: token)
        let cancelledClaimRemains = try MomentShareHandoffStore.isCurrentClaim(
            cancelledClaim,
            validating: token,
            now: base.addingTimeInterval(3_704)
        )
        guard cancellationPresentation.statuses.count == 2,
              cancellationPresentation.statuses.allSatisfy(\.isCancellable),
              discardedPreparationCount == 2,
              !MomentShareHandoffStore.captureExists(cancelPending),
              !MomentShareHandoffStore.captureExists(cancelProcessing),
              !cancelledClaimRemains
        else { throw MomentSharingError.stateUnavailable }

        let reconcileRecord = try MomentShareHandoffStore.stageCapture(
            admissionID: secondAdmission.id,
            canonicalJPEG: preview.jpeg,
            capturedAt: nil,
            pixelWidth: preview.pixelWidth,
            pixelHeight: preview.pixelHeight,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: acceptedAt,
            now: base.addingTimeInterval(2 * 60 * 60)
        )
        let spaceID = opaque(0x61)
        let memberID = opaque(0x62)
        let replacementDeviceID = opaque(0x64)
        let context = MomentRequestContext(
            spaceID: spaceID,
            senderParticipantID: memberID,
            senderDeviceID: memberID,
            clientRequestID: reconcileRecord.clientRequestID,
            clientMomentID: reconcileRecord.id,
            kind: .live,
            keyEpoch: 1
        )
        let payload = try MomentCrypto.prepare(
            canonicalJPEG: reconcileRecord.canonicalJPEG,
            capturedAt: reconcileRecord.capturedAt,
            pixelWidth: reconcileRecord.pixelWidth,
            pixelHeight: reconcileRecord.pixelHeight,
            context: context,
            spaceGenerationKey: Data(repeating: 0x63, count: 32)
        )
        let durable = try MomentSharingStateStore.enqueue(
            payload: payload,
            senderPolicyVersion: reconcileRecord.senderPolicyVersion,
            senderPolicyAcceptedAt: reconcileRecord.senderPolicyAcceptedAt,
            validating: token,
            now: base.addingTimeInterval(2 * 60 * 60)
        )
        guard let reconcileClaim = try MomentShareHandoffStore.claimCapture(
            reconcileRecord,
            validating: token,
            now: base.addingTimeInterval(2 * 60 * 60 + 1)
        ) else { throw MomentSharingError.stateUnavailable }
        let reconciled = try MomentShareHandoffStore.promoteCapture(
            reconcileClaim,
            validating: token,
            now: base.addingTimeInterval(2 * 60 * 60 + 2)
        ) { record in
            guard let existing = try MomentSharingStateStore
                .existingOutboxWhileLifecycleLocked(
                    clientMomentID: record.id,
                    clientRequestID: record.clientRequestID,
                    spaceID: spaceID,
                    senderParticipantID: memberID,
                    senderDeviceID: replacementDeviceID,
                    legacySenderDeviceID: memberID,
                    kind: record.kind,
                    keyEpoch: 1,
                    senderPolicyVersion: record.senderPolicyVersion,
                    senderPolicyAcceptedAt: record.senderPolicyAcceptedAt
                ) else { throw MomentSharingError.stateUnavailable }
            return existing
        }
        guard reconciled.id == durable.id,
              try MomentShareHandoffStore.nextPendingCapture(
                  admissionID: secondAdmission.id,
                  validating: token,
                  now: base.addingTimeInterval(2 * 60 * 60 + 2)
              ) == nil
        else { throw MomentSharingError.stateUnavailable }

        let blockedRecord = try MomentShareHandoffStore.stageCapture(
            admissionID: secondAdmission.id,
            canonicalJPEG: preview.jpeg,
            capturedAt: nil,
            pixelWidth: preview.pixelWidth,
            pixelHeight: preview.pixelHeight,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: acceptedAt,
            now: base.addingTimeInterval(2 * 60 * 60 + 3)
        )
        guard let blockedClaim = try MomentShareHandoffStore.claimCapture(
            blockedRecord,
            validating: token,
            now: base.addingTimeInterval(2 * 60 * 60 + 4)
        ) else { throw MomentSharingError.stateUnavailable }
        let reportOnlyUntil = base.addingTimeInterval(3 * 60 * 60)
        try MomentSharingStateStore.enterReportOnlyMode(
            until: reportOnlyUntil,
            validating: token,
            now: base.addingTimeInterval(2 * 60 * 60 + 5)
        )
        do {
            _ = try MomentShareHandoffStore.promoteCapture(
                blockedClaim,
                validating: token,
                now: base.addingTimeInterval(2 * 60 * 60 + 6)
            ) { record in
                try MomentSharingStateStore.enqueueWhileLifecycleLocked(
                    payload: try MomentCrypto.prepare(
                        canonicalJPEG: record.canonicalJPEG,
                        capturedAt: record.capturedAt,
                        pixelWidth: record.pixelWidth,
                        pixelHeight: record.pixelHeight,
                        context: MomentRequestContext(
                            spaceID: spaceID,
                            senderParticipantID: memberID,
                            senderDeviceID: memberID,
                            clientRequestID: record.clientRequestID,
                            clientMomentID: record.id,
                            kind: record.kind,
                            keyEpoch: 1
                        ),
                        spaceGenerationKey: Data(repeating: 0x63, count: 32)
                    ),
                    senderPolicyVersion: record.senderPolicyVersion,
                    senderPolicyAcceptedAt: record.senderPolicyAcceptedAt
                )
            }
            throw MomentSharingError.stateUnavailable
        } catch let error as MomentSharingError {
            guard case let .reportOnly(until) = error,
                  until == reportOnlyUntil
            else { throw error }
        }

        let longInactiveAt = blockedRecord.expiresAt.addingTimeInterval(
            MomentShareHandoffStore.terminalOutcomeLifetime + 1
        )
        _ = try MomentShareHandoffStore.activeAdmissions(now: longInactiveAt)
        let longInactivePresentation = try MomentShareHandoffStore.presentationSnapshot(
            now: longInactiveAt
        )
        guard !MomentShareHandoffStore.captureExists(blockedRecord),
              longInactivePresentation.statuses.isEmpty,
              longInactivePresentation.terminalOutcomes.isEmpty
        else { throw MomentSharingError.stateUnavailable }

        // Pairing-only keeps its room authorization while physically removing
        // any admission and staged canonical plaintext from a media build.
        // The fully-disabled upgrade boundary is exercised separately with a
        // real paired credential and complete sharing cache below.
        let pairingOnlyConfiguration = SharingAPIConfiguration(
            isEnabled: true,
            isMediaEnabled: false,
            isShareExtensionHandoffEnabled: false,
            isShareExtensionSendEnabled: false,
            isReviewPreviewEnabled: false,
            baseURL: URL(string: "https://example.com")!,
            moderationKeyID: nil,
            moderationPublicKey: nil,
            supportURL: nil,
            communityStandardsURL: nil,
            releaseMode: "pairing-only"
        )
        let pairingOnlyCoordinator = MomentSharingCoordinator(
            configuration: pairingOnlyConfiguration
        )
        let moderationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NekoWidgetMomentHandoffModeration",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: moderationDirectory,
            withIntermediateDirectories: true
        )
        let rollbackResidue = moderationDirectory.appendingPathComponent(
            ".handoff-runtime-disabled.jpg",
            isDirectory: false
        )
        try Data([0x52]).write(to: rollbackResidue)
        let inboundModerationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NekoWidgetMomentInboundModeration",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: inboundModerationDirectory,
            withIntermediateDirectories: true
        )
        let inboundRollbackResidue = inboundModerationDirectory
            .appendingPathComponent(
                ".inbound-runtime-disabled.jpg",
                isDirectory: false
            )
        try Data([0x54]).write(to: inboundRollbackResidue)
        await pairingOnlyCoordinator.synchronize(trigger: "runtime-pairing-only")
        guard try MomentShareHandoffStore.activeAdmissions(
            now: base.addingTimeInterval(2 * 60 * 60)
        ).isEmpty,
        SharedContainer.momentShareHandoffDirectoryURL.map({
            !FileManager.default.fileExists(atPath: $0.path)
        }) == true,
        !FileManager.default.fileExists(atPath: rollbackResidue.path),
        !FileManager.default.fileExists(atPath: inboundRollbackResidue.path)
        else { throw MomentSharingError.stateUnavailable }

        // Recreate a local-only handoff to independently verify that the
        // installation reset also removes the whole subtree.
        let resetCatalog = try MomentShareHandoffStore.publishAdmissions(
            [MomentShareAdmissionInput(
                bindingSHA256: Data(repeating: 0x53, count: 32),
                displayName: "家族のまど"
            )],
            validating: token,
            now: base.addingTimeInterval(2 * 60 * 60 + 7)
        )
        guard let resetAdmission = resetCatalog.destinations.first else {
            throw MomentSharingError.stateUnavailable
        }
        _ = try MomentShareHandoffStore.stageCapture(
            admissionID: resetAdmission.id,
            canonicalJPEG: preview.jpeg,
            capturedAt: nil,
            pixelWidth: preview.pixelWidth,
            pixelHeight: preview.pixelHeight,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: acceptedAt,
            now: base.addingTimeInterval(2 * 60 * 60 + 8)
        )
        try FileManager.default.createDirectory(
            at: moderationDirectory,
            withIntermediateDirectories: true
        )
        let resetResidue = moderationDirectory.appendingPathComponent(
            ".handoff-installation-reset.jpg",
            isDirectory: false
        )
        try Data([0x53]).write(to: resetResidue)
        try FileManager.default.createDirectory(
            at: inboundModerationDirectory,
            withIntermediateDirectories: true
        )
        let inboundResetResidue = inboundModerationDirectory
            .appendingPathComponent(
                ".inbound-installation-reset.jpg",
                isDirectory: false
            )
        try Data([0x55]).write(to: inboundResetResidue)
        let reportOnlyMarkerUntil = base.addingTimeInterval(3 * 60 * 60 + 30)
        try MomentShareHandoffProcessor().enterReportOnlyMode(
            until: reportOnlyMarkerUntil,
            lifecycleToken: token,
            now: base.addingTimeInterval(2 * 60 * 60 + 10)
        )
        guard try MomentShareHandoffStore.reportOnlyHandoffDeadline(
            validating: token,
            now: base.addingTimeInterval(2 * 60 * 60 + 11)
        ) == reportOnlyMarkerUntil,
        try MomentShareHandoffStore.activeAdmissions(
            now: base.addingTimeInterval(2 * 60 * 60 + 11)
        ).isEmpty,
        !FileManager.default.fileExists(atPath: resetResidue.path)
        else { throw MomentSharingError.stateUnavailable }

        // Corrupt marker bytes must keep the Extension fail-closed while the
        // host recovers a fixed deadline from the protected inode. The anchor
        // can never grant more than one local report-only window.
        guard let reportOnlyMarkerURL = SharedContainer
            .momentShareHandoffReportOnlyMarkerURL
        else { throw MomentSharingError.stateUnavailable }
        let markerWriteStartedAt = Date()
        try SharingSecureFile.write(Data([0x00]), to: reportOnlyMarkerURL)
        let markerWriteFinishedAt = Date()
        do {
            _ = try MomentShareHandoffStore.reportOnlyHandoffDeadline(
                validating: token,
                now: markerWriteFinishedAt
            )
            throw MomentSharingError.stateUnavailable
        } catch MomentSharingError.stateUnavailable {
            // The payload is intentionally malformed; existence remains the
            // Extension authority while the host uses the bounded anchor.
        }
        let markerRecoveryNow = markerWriteFinishedAt.addingTimeInterval(1)
        let recoveredMarkerUntil = try MomentShareHandoffStore
            .reportOnlyHandoffRecoveryDeadline(
                validating: token,
                now: markerRecoveryNow
            )
        guard let recoveredMarkerUntil,
              recoveredMarkerUntil >= markerWriteStartedAt.addingTimeInterval(
                  MomentSharingProtocol.maximumReportOnlyWindowSeconds - 2
              ),
              recoveredMarkerUntil <= markerWriteFinishedAt.addingTimeInterval(
                  MomentSharingProtocol.maximumReportOnlyWindowSeconds + 2
              )
        else { throw MomentSharingError.stateUnavailable }
        try MomentShareHandoffProcessor().establishReportOnlyHandoffGate(
            until: recoveredMarkerUntil,
            lifecycleToken: token,
            now: markerRecoveryNow
        )
        do {
            _ = try MomentShareHandoffStore.publishAdmissions(
                [MomentShareAdmissionInput(
                    bindingSHA256: Data(repeating: 0x54, count: 32),
                    displayName: "家族のまど"
                )],
                validating: token,
                now: base.addingTimeInterval(2 * 60 * 60 + 12)
            )
            throw MomentSharingError.stateUnavailable
        } catch MomentSharingError.invalidPayload {
            // The report-only marker is cleared only by a full pairing reset.
        }
        _ = try PairingInstallationGuard.resetLocalSharing(
            expectedState: bootstrap.state,
            lifecycleToken: token,
            message: nil
        )
        guard try MomentShareHandoffStore.activeAdmissions(
            now: base.addingTimeInterval(2 * 60 * 60)
        ).isEmpty,
        SharedContainer.momentShareHandoffDirectoryURL.map({
            !FileManager.default.fileExists(atPath: $0.path)
        }) == true,
        !FileManager.default.fileExists(atPath: moderationDirectory.path),
        !FileManager.default.fileExists(atPath: inboundModerationDirectory.path),
        SharedContainer.momentShareHandoffReportOnlyMarkerURL.map({
            !FileManager.default.fileExists(atPath: $0.path)
        }) == true
        else { throw MomentSharingError.stateUnavailable }
    }

    /// Installing a fully-disabled build over a previously paired media build
    /// must revoke the entire local room before any relay client exists. The
    /// fixture includes every user-visible sharing class plus a cleanup marker
    /// left by an interrupted attempt; a second pass proves convergence.
    private static func testDisabledUpgradePurge() async throws {
        let initial = try PairingInstallationGuard.bootstrap()
        _ = try PairingInstallationGuard.resetLocalSharing(
            expectedState: initial.state,
            lifecycleToken: initial.lifecycleToken,
            message: nil
        )
        let bootstrap = try PairingInstallationGuard.bootstrap()
        let lifecycleToken = bootstrap.lifecycleToken
        let unpaired = bootstrap.state
        guard unpaired.phase == .unpaired,
              let root = SharedContainer.containerURL,
              let personalWidgetDirectory = SharedContainer.widgetCacheDirectoryURL
        else { throw MomentSharingError.stateUnavailable }

        let personalSentinels = [
            root.appendingPathComponent(
                ".runtime-disabled-upgrade-photo-scan",
                isDirectory: false
            ),
            root.appendingPathComponent(
                ".runtime-disabled-upgrade-likes",
                isDirectory: false
            ),
            personalWidgetDirectory.appendingPathComponent(
                ".runtime-disabled-upgrade-personal-widget",
                isDirectory: false
            )
        ]
        let personalSentinelData = Data("personal-local-state".utf8)
        try FileManager.default.createDirectory(
            at: personalWidgetDirectory,
            withIntermediateDirectories: true
        )
        for url in personalSentinels {
            try SharingSecureFile.write(personalSentinelData, to: url)
        }
        defer {
            for url in personalSentinels {
                try? FileManager.default.removeItem(at: url)
            }
            try? PairingInstallationGuard
                .resetLocalSharingForDisabledConfiguration()
        }

        let credential = PairingCrypto.makeCredential(
            installationMarker: unpaired.installationMarker,
            includesInvitationSecret: false,
            includesRoomKey: true
        )
        let peerCredential = PairingCrypto.makeCredential(
            installationMarker: unpaired.installationMarker,
            includesInvitationSecret: false,
            includesRoomKey: false
        )
        let orphanCredential = PairingCrypto.makeCredential(
            installationMarker: unpaired.installationMarker,
            includesInvitationSecret: false,
            includesRoomKey: true
        )
        let localMember = PairingMemberIdentity(
            memberID: opaque(0x81),
            participantID: credential.participantIDString,
            agreementPublicKey: try PairingCrypto.agreementPublicKey(for: credential)
                .base64URLEncodedString(),
            signingPublicKey: try PairingCrypto.signingPublicKey(for: credential)
                .base64URLEncodedString()
        )
        let peerMember = PairingMemberIdentity(
            memberID: opaque(0x82),
            participantID: peerCredential.participantIDString,
            agreementPublicKey: try PairingCrypto.agreementPublicKey(for: peerCredential)
                .base64URLEncodedString(),
            signingPublicKey: try PairingCrypto.signingPublicKey(for: peerCredential)
                .base64URLEncodedString()
        )
        let spaceID = opaque(0x83)
        let invitationID = opaque(0x84)
        let enrollmentID = opaque(0x85)
        let transcript = PairingVerificationTranscript(
            spaceID: spaceID,
            invitationID: invitationID,
            enrollmentID: enrollmentID,
            dailyBoundaryMinuteUTC: 240,
            inviter: localMember,
            invitee: peerMember
        )
        let transcriptData = try transcript.canonicalData()
        let transcriptHash = PairingCrypto.sha256(transcriptData)

        var creating = unpaired
        creating.phase = .creatingInvitation
        creating.role = .inviter
        creating.credentialAccount = credential.account
        creating.participantID = credential.participantIDString
        creating.pendingClientRequestID = UUID().uuidString.lowercased()
        creating.pendingOperation = "create"
        creating.lastUpdatedAt = .now
        creating = try PairingStateStore.saveInitialCredentialAndState(
            credential: credential,
            state: creating,
            expected: unpaired,
            lifecycleToken: lifecycleToken
        )
        var paired = creating
        paired.phase = .paired
        paired.spaceID = spaceID
        paired.memberID = localMember.memberID
        paired.invitationID = invitationID
        paired.enrollmentID = enrollmentID
        paired.peerMemberID = peerMember.memberID
        paired.peerParticipantID = peerMember.participantID
        paired.peerAgreementPublicKey = peerMember.agreementPublicKey
        paired.peerSigningPublicKey = peerMember.signingPublicKey
        paired.transcript = transcriptData.base64URLEncodedString()
        paired.transcriptHash = transcriptHash.base64URLEncodedString()
        paired.verificationPhrase = PairingCrypto.verificationPhrase(for: transcriptHash)
        paired.dailyBoundaryMinuteUTC = 240
        paired.pendingClientRequestID = nil
        paired.pendingOperation = nil
        paired.mediaSharingConsentVersion = PairingMediaSharingConsent.currentVersion
        paired.mediaSharingConsentAcceptedAt = .now
        paired.lastUpdatedAt = .now
        paired = try PairingStateStore.save(
            paired,
            expected: creating,
            lifecycleToken: lifecycleToken
        )
        // A crash before state publication can leave more than the one account
        // referenced by PairingState. The disabled purge must delete the exact
        // sharing service wholesale, not only the currently bound account.
        try PairingKeychainStore.save(
            orphanCredential,
            lifecycleToken: lifecycleToken
        )

        _ = try PrivateWindowPresentationStore.save(
            displayName: "以前のまど",
            pairing: paired,
            validating: lifecycleToken
        )
        guard let familyWidgetManifestURL = SharedContainer.familyWidgetManifestURL else {
            throw MomentSharingError.stateUnavailable
        }
        guard let windowNameSyncURL = SharedContainer.privateWindowNameSyncStateURL,
              let familyWidgetHistoryURL = SharedContainer.familyWidgetCacheHistoryURL,
              let familyWidgetCacheDirectory = SharedContainer.familyWidgetCacheDirectoryURL
        else { throw MomentSharingError.stateUnavailable }
        try SharingSecureFile.write(
            Data("stale-family-widget".utf8),
            to: familyWidgetManifestURL
        )
        try SharingSecureFile.write(
            Data("stale-window-name-sync".utf8),
            to: windowNameSyncURL
        )
        try SharingSecureFile.write(
            Data("stale-family-history".utf8),
            to: familyWidgetHistoryURL
        )
        try FileManager.default.createDirectory(
            at: familyWidgetCacheDirectory,
            withIntermediateDirectories: true
        )
        let familyWidgetJPEGURL = familyWidgetCacheDirectory.appendingPathComponent(
            "stale-family-widget.jpg",
            isDirectory: false
        )
        try SharingSecureFile.write(
            Data(repeating: 0x93, count: 64),
            to: familyWidgetJPEGURL
        )

        // Availability is not a destructive policy boundary. A pairing-only
        // candidate with a missing/invalid relay URL must fail closed for
        // networking without erasing an already-authorized room.
        let unavailablePairingOnlyConfiguration = SharingAPIConfiguration(
            isEnabled: true,
            isMediaEnabled: false,
            isShareExtensionHandoffEnabled: false,
            isShareExtensionSendEnabled: false,
            isReviewPreviewEnabled: false,
            baseURL: nil,
            moderationKeyID: nil,
            moderationPublicKey: nil,
            supportURL: nil,
            communityStandardsURL: nil,
            releaseMode: "pairing-only"
        )
        let unavailablePairingOnlyCoordinator = MomentSharingCoordinator(
            configuration: unavailablePairingOnlyConfiguration
        )
        guard !unavailablePairingOnlyConfiguration.isAvailable,
              !unavailablePairingOnlyConfiguration.requiresLocalSharingPurge
        else { throw MomentSharingError.stateUnavailable }
        await unavailablePairingOnlyCoordinator.synchronize(
            trigger: "runtime-pairing-only-unavailable"
        )
        let pairingOnlyNetworkConstructionCount = await unavailablePairingOnlyCoordinator
            .runtimeNetworkClientConstructions()
        guard (try PairingStateStore.load())?.phase == .paired,
              try PairingKeychainStore.load(
                  account: credential.account,
                  installationMarker: paired.installationMarker
              ) == credential,
              try PairingKeychainStore.load(
                  account: orphanCredential.account,
                  installationMarker: paired.installationMarker
              ) == orphanCredential,
              pairingOnlyNetworkConstructionCount == 0,
              FileManager.default.fileExists(atPath: familyWidgetManifestURL.path),
              FileManager.default.fileExists(atPath: familyWidgetJPEGURL.path)
        else { throw MomentSharingError.stateUnavailable }

        let reviewPreviewConfiguration = SharingAPIConfiguration(
            isEnabled: false,
            isMediaEnabled: false,
            isShareExtensionHandoffEnabled: false,
            isShareExtensionSendEnabled: false,
            isReviewPreviewEnabled: true,
            baseURL: nil,
            moderationKeyID: nil,
            moderationPublicKey: nil,
            supportURL: nil,
            communityStandardsURL: nil,
            releaseMode: "review-preview"
        )
        let reviewPreviewCoordinator = MomentSharingCoordinator(
            configuration: reviewPreviewConfiguration
        )
        guard !reviewPreviewConfiguration.isAvailable,
              !reviewPreviewConfiguration.requiresLocalSharingPurge
        else { throw MomentSharingError.stateUnavailable }
        await reviewPreviewCoordinator.synchronize(
            trigger: "runtime-review-preview-preserve"
        )
        let reviewPreviewNetworkConstructionCount = await reviewPreviewCoordinator
            .runtimeNetworkClientConstructions()
        guard (try PairingStateStore.load())?.phase == .paired,
              try PairingKeychainStore.load(
                  account: credential.account,
                  installationMarker: paired.installationMarker
              ) == credential,
              reviewPreviewNetworkConstructionCount == 0,
              FileManager.default.fileExists(atPath: familyWidgetManifestURL.path),
              FileManager.default.fileExists(atPath: familyWidgetJPEGURL.path)
        else { throw MomentSharingError.stateUnavailable }

        let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let preview = try MomentCanonicalPreviewBuilder.build(image: generatedImage())
        let binding = try MomentShareHandoffStore.makeBindingSHA256(
            installationMarker: paired.installationMarker,
            spaceID: spaceID,
            participantID: credential.participantIDString
        )
        let catalog = try MomentShareHandoffStore.publishAdmissions(
            [MomentShareAdmissionInput(
                bindingSHA256: binding,
                displayName: "以前のまど"
            )],
            validating: lifecycleToken,
            now: base
        )
        guard let admission = catalog.destinations.first else {
            throw MomentSharingError.stateUnavailable
        }
        let pendingCapture = try MomentShareHandoffStore.stageCapture(
            admissionID: admission.id,
            canonicalJPEG: preview.jpeg,
            capturedAt: base,
            pixelWidth: preview.pixelWidth,
            pixelHeight: preview.pixelHeight,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: base,
            now: base.addingTimeInterval(1)
        )

        guard let roomKey = credential.roomKey else {
            throw MomentSharingError.stateUnavailable
        }
        let prepared = try MomentCrypto.prepare(
            canonicalJPEG: preview.jpeg,
            capturedAt: base,
            pixelWidth: preview.pixelWidth,
            pixelHeight: preview.pixelHeight,
            context: MomentRequestContext(
                spaceID: spaceID,
                senderParticipantID: localMember.participantID,
                senderDeviceID: localMember.participantID,
                clientRequestID: UUID(),
                clientMomentID: UUID(),
                kind: .live,
                keyEpoch: 1
            ),
            spaceGenerationKey: roomKey
        )
        let outboxItem = try MomentSharingStateStore.enqueue(
            payload: prepared,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: base,
            validating: lifecycleToken,
            now: base
        )
        guard let ciphertextDirectory = SharedContainer.momentSharingCiphertextDirectoryURL
        else { throw MomentSharingError.stateUnavailable }
        let ciphertextURL = ciphertextDirectory.appendingPathComponent(
            outboxItem.ciphertextFileName,
            isDirectory: false
        )

        let receivedMomentID = opaque(0x86)
        let receivedItem = try MomentInboxItem(
            id: receivedMomentID,
            senderParticipantID: peerMember.participantID,
            kind: .live,
            keyEpoch: 1,
            localJPEGFileName: "\(receivedMomentID).jpg",
            capturedAt: base,
            captureDateIsMissing: false,
            committedAt: base,
            receivedAt: base,
            state: .available,
            accessExpiresAt: base.addingTimeInterval(30 * 24 * 60 * 60)
        ).validated()
        _ = try MomentSharingStateStore.publishReceivedJPEG(
            receivedItem,
            jpeg: preview.jpeg,
            validating: lifecycleToken
        )
        guard let receivedDirectory = SharedContainer.momentSharingReceivedDirectoryURL
        else { throw MomentSharingError.stateUnavailable }
        guard let receivedFileName = receivedItem.localJPEGFileName else {
            throw MomentSharingError.stateUnavailable
        }
        let receivedURL = receivedDirectory.appendingPathComponent(
            receivedFileName,
            isDirectory: false
        )
        let reportCiphertext = Data(repeating: 0x91, count: 128)
        _ = try MomentSharingStateStore.enqueueReport(
            momentID: receivedMomentID,
            reason: .privacy,
            prepared: MomentPreparedReport(
                ciphertext: reportCiphertext,
                ciphertextSHA256: PairingCrypto.sha256(reportCiphertext),
                moderationKeyID: "moderation-v1"
            ),
            reporterConsentAcceptedAt: base,
            validating: lifecycleToken,
            now: base
        )

        let moderationDirectories = [
            "NekoWidgetMomentHandoffModeration",
            "NekoWidgetMomentInboundModeration"
        ].map {
            FileManager.default.temporaryDirectory.appendingPathComponent(
                $0,
                isDirectory: true
            )
        }
        for directory in moderationDirectories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data([0x92]).write(
                to: directory.appendingPathComponent(
                    ".disabled-upgrade-residue",
                    isDirectory: false
                )
            )
        }

        let seededState = try MomentSharingStateStore.load()
        guard (try PairingStateStore.load())?.phase == .paired,
              try PairingKeychainStore.load(
                  account: credential.account,
                  installationMarker: paired.installationMarker
              ) == credential,
              try PairingKeychainStore.load(
                  account: orphanCredential.account,
                  installationMarker: paired.installationMarker
              ) == orphanCredential,
              seededState.inbox.contains(where: { $0.id == receivedMomentID }),
              seededState.outbox.contains(where: { $0.id == outboxItem.id }),
              seededState.reportOutbox.contains(where: { $0.momentID == receivedMomentID }),
              MomentShareHandoffStore.captureExists(pendingCapture),
              FileManager.default.fileExists(atPath: ciphertextURL.path),
              FileManager.default.fileExists(atPath: receivedURL.path),
              FileManager.default.fileExists(atPath: familyWidgetManifestURL.path),
              FileManager.default.fileExists(atPath: windowNameSyncURL.path),
              FileManager.default.fileExists(atPath: familyWidgetHistoryURL.path),
              FileManager.default.fileExists(atPath: familyWidgetJPEGURL.path),
              personalSentinels.allSatisfy({
                  (try? Data(contentsOf: $0)) == personalSentinelData
              })
        else { throw MomentSharingError.stateUnavailable }

        // Model a killed cleanup after its fail-closed marker became durable.
        try SharingLifecycleGate.withExclusive {
            try SharingLifecycleGate.markCleanupRequired()
        }
        let disabledConfiguration = SharingAPIConfiguration(
            // The disabled marker remains authoritative even if an archive was
            // accidentally injected with otherwise-enabled network values.
            isEnabled: true,
            isMediaEnabled: true,
            isShareExtensionHandoffEnabled: true,
            isShareExtensionSendEnabled: false,
            isReviewPreviewEnabled: false,
            baseURL: URL(string: "https://unexpected.invalid")!,
            moderationKeyID: nil,
            moderationPublicKey: nil,
            supportURL: nil,
            communityStandardsURL: nil,
            releaseMode: "disabled"
        )
        guard disabledConfiguration.isAvailable,
              disabledConfiguration.requiresLocalSharingPurge
        else { throw MomentSharingError.stateUnavailable }
        let coordinator = MomentSharingCoordinator(configuration: disabledConfiguration)
        await coordinator.synchronize(trigger: "runtime-disabled-upgrade")
        let firstNetworkConstructionCount = await coordinator
            .runtimeNetworkClientConstructions()

        guard let reset = try PairingStateStore.load(),
              reset.phase == .unpaired,
              reset.credentialAccount == nil,
              !SharingLifecycleGate.isCleanupRequired,
              firstNetworkConstructionCount == 0,
              SharedContainer.momentSharingStateURL.map({
                  !FileManager.default.fileExists(atPath: $0.path)
              }) == true,
              SharedContainer.momentShareHandoffDirectoryURL.map({
                  !FileManager.default.fileExists(atPath: $0.path)
              }) == true,
              SharedContainer.privateWindowPresentationURL.map({
                  !FileManager.default.fileExists(atPath: $0.path)
              }) == true,
              SharedContainer.familyWidgetManifestURL.map({
                  !FileManager.default.fileExists(atPath: $0.path)
              }) == true,
              !FileManager.default.fileExists(atPath: windowNameSyncURL.path),
              !FileManager.default.fileExists(atPath: familyWidgetHistoryURL.path),
              !FileManager.default.fileExists(atPath: familyWidgetJPEGURL.path),
              !FileManager.default.fileExists(atPath: ciphertextURL.path),
              !FileManager.default.fileExists(atPath: receivedURL.path),
              moderationDirectories.allSatisfy({
                  !FileManager.default.fileExists(atPath: $0.path)
              }),
              personalSentinels.allSatisfy({
                  (try? Data(contentsOf: $0)) == personalSentinelData
              })
        else { throw MomentSharingError.stateUnavailable }
        for removedCredential in [credential, orphanCredential] {
            do {
                _ = try PairingKeychainStore.load(
                    account: removedCredential.account,
                    installationMarker: paired.installationMarker
                )
                throw MomentSharingError.stateUnavailable
            } catch PairingError.malformedCredential {
                // Expected: no bound or orphan room capability survives.
            }
        }

        await coordinator.synchronize(trigger: "runtime-disabled-idempotent")
        let secondNetworkConstructionCount = await coordinator
            .runtimeNetworkClientConstructions()
        guard (try PairingStateStore.load())?.phase == .unpaired,
              !SharingLifecycleGate.isCleanupRequired,
              secondNetworkConstructionCount == 0,
              personalSentinels.allSatisfy({
                  (try? Data(contentsOf: $0)) == personalSentinelData
              })
        else { throw MomentSharingError.stateUnavailable }
    }

    /// A report-only transition must be enforced by the shared store itself.
    /// The Share Extension and host app are separate processes, so a UI-only
    /// check would allow older image preparation work to recreate a normal
    /// outbox entry after a peer block/revocation was already persisted.
    private static func testMomentReportOnlyTerminalGate() throws {
        try clearMomentSharingFixture()
        defer { try? clearMomentSharingFixture() }

        let lifecycleToken = try SharingLifecycleGate.issueToken()
        let roomKey = Data(repeating: 0x31, count: 32)
        let firstMomentID = UUID()
        let firstPayload = try MomentCrypto.prepare(
            canonicalJPEG: Data(repeating: 0x42, count: 512),
            capturedAt: nil,
            pixelWidth: 32,
            pixelHeight: 16,
            context: MomentRequestContext(
                spaceID: "space_runtime_fixture",
                senderParticipantID: "member_runtime_fixture",
                senderDeviceID: "member_runtime_fixture",
                clientRequestID: UUID(),
                clientMomentID: firstMomentID,
                kind: .live,
                keyEpoch: 1
            ),
            spaceGenerationKey: roomKey
        )
        let first = try MomentSharingStateStore.enqueue(
            payload: firstPayload,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            validating: lifecycleToken
        )
        guard let ciphertextDirectory = SharedContainer.momentSharingCiphertextDirectoryURL
        else { throw MomentSharingError.stateUnavailable }
        let firstCiphertext = ciphertextDirectory.appendingPathComponent(
            first.ciphertextFileName,
            isDirectory: false
        )
        guard FileManager.default.fileExists(atPath: firstCiphertext.path) else {
            throw MomentSharingError.stateUnavailable
        }

        let reportOnlyUntil = Date(timeIntervalSince1970: 1_900_000_000)
        try MomentSharingStateStore.enterReportOnlyMode(
            until: reportOnlyUntil,
            validating: lifecycleToken,
            now: reportOnlyUntil.addingTimeInterval(-60)
        )
        let terminal = try MomentSharingStateStore.load()
        guard terminal.reportOnlyUntil == reportOnlyUntil,
              terminal.outbox.isEmpty,
              !FileManager.default.fileExists(atPath: firstCiphertext.path)
        else { throw MomentSharingError.stateUnavailable }

        let secondPayload = try MomentCrypto.prepare(
            canonicalJPEG: Data(repeating: 0x43, count: 512),
            capturedAt: nil,
            pixelWidth: 32,
            pixelHeight: 16,
            context: MomentRequestContext(
                spaceID: "space_runtime_fixture",
                senderParticipantID: "member_runtime_fixture",
                senderDeviceID: "member_runtime_fixture",
                clientRequestID: UUID(),
                clientMomentID: UUID(),
                kind: .live,
                keyEpoch: 1
            ),
            spaceGenerationKey: roomKey
        )
        do {
            _ = try MomentSharingStateStore.enqueue(
                payload: secondPayload,
                senderPolicyVersion: 1,
                senderPolicyAcceptedAt: Date(timeIntervalSince1970: 1_700_000_100),
                validating: lifecycleToken
            )
            throw MomentSharingError.stateUnavailable
        } catch let error as MomentSharingError {
            guard case let .reportOnly(until) = error,
                  until == reportOnlyUntil,
                  try MomentSharingStateStore.load().outbox.isEmpty
            else { throw MomentSharingError.stateUnavailable }
        }

        guard try MomentSharingStateStore.isPersistedStateDefinitelyCorrupt(
            validating: lifecycleToken
        ) == false,
        let stateURL = SharedContainer.momentSharingStateURL else {
            throw MomentSharingError.stateUnavailable
        }
        try SharingSecureFile.write(Data("{".utf8), to: stateURL)
        guard try MomentSharingStateStore.isPersistedStateDefinitelyCorrupt(
            validating: lifecycleToken
        ) else { throw MomentSharingError.stateUnavailable }
    }

    private static func testMomentSavedMemoryBoundary() throws {
        try clearMomentSharingFixture()
        defer { try? clearMomentSharingFixture() }

        let lifecycleToken = try SharingLifecycleGate.issueToken()
        let baseDate = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970)
        )
        let momentID = "moment_saved_memory_fixture"
        let item = try MomentInboxItem(
            id: momentID,
            senderParticipantID: "participant_saved_memory_fixture",
            kind: .live,
            keyEpoch: 1,
            localJPEGFileName: "\(momentID).jpg",
            capturedAt: baseDate,
            captureDateIsMissing: false,
            committedAt: baseDate,
            receivedAt: baseDate,
            state: .available,
            accessExpiresAt: baseDate.addingTimeInterval(30 * 24 * 60 * 60)
        ).validated()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        _ = try MomentSharingStateStore.publishReceivedJPEG(
            item,
            jpeg: jpeg,
            validating: lifecycleToken
        )

        let likesBefore = SharedContainer.likesURL.flatMap {
            try? Data(contentsOf: $0)
        }
        try MomentSharingStateStore.setSavedMemory(
            momentID: momentID,
            isSaved: true,
            now: baseDate.addingTimeInterval(1),
            validating: lifecycleToken
        )
        let saved = try MomentSharingStateStore.load()
        let likesAfter = SharedContainer.likesURL.flatMap {
            try? Data(contentsOf: $0)
        }
        guard saved.savedMemories == [
            MomentSavedMemoryRecord(
                momentID: momentID,
                savedAt: baseDate.addingTimeInterval(1)
            )
        ],
        let receivedDirectory = SharedContainer.momentSharingReceivedDirectoryURL,
        try Data(contentsOf: receivedDirectory.appendingPathComponent("\(momentID).jpg"))
            == jpeg,
        likesBefore == likesAfter
        else { throw MomentSharingError.stateUnavailable }

        let blockedMomentID = "moment_saved_then_blocked_fixture"
        let blockedItem = try MomentInboxItem(
            id: blockedMomentID,
            senderParticipantID: item.senderParticipantID,
            kind: item.kind,
            keyEpoch: item.keyEpoch,
            localJPEGFileName: "\(blockedMomentID).jpg",
            capturedAt: baseDate.addingTimeInterval(3),
            captureDateIsMissing: false,
            committedAt: baseDate.addingTimeInterval(3),
            receivedAt: baseDate.addingTimeInterval(3),
            state: .available,
            accessExpiresAt: baseDate.addingTimeInterval(30 * 24 * 60 * 60)
        ).validated()
        _ = try MomentSharingStateStore.publishReceivedJPEG(
            blockedItem,
            jpeg: jpeg,
            validating: lifecycleToken
        )
        try MomentSharingStateStore.setSavedMemory(
            momentID: blockedMomentID,
            isSaved: true,
            now: baseDate.addingTimeInterval(4),
            validating: lifecycleToken
        )
        var blockedCandidate = blockedItem
        blockedCandidate.state = .blocked
        let blockedJPEG = Data([0xFF, 0xD8, 0x00, 0xFF, 0xD9])
        _ = try MomentSharingStateStore.publishReceivedJPEG(
            blockedCandidate,
            jpeg: blockedJPEG,
            validating: lifecycleToken
        )
        let blockedState = try MomentSharingStateStore.load()
        guard blockedState.savedMemories == saved.savedMemories,
              blockedState.inbox.first(where: { $0.id == blockedMomentID })?.state == .blocked,
              try Data(
                contentsOf: receivedDirectory.appendingPathComponent("\(blockedMomentID).jpg")
              ) == blockedJPEG
        else { throw MomentSharingError.stateUnavailable }

        let reportOnlyUntil = baseDate.addingTimeInterval(60 * 60)
        try MomentSharingStateStore.enterReportOnlyMode(
            until: reportOnlyUntil,
            validating: lifecycleToken,
            now: baseDate
        )
        do {
            try MomentSharingStateStore.setSavedMemory(
                momentID: momentID,
                isSaved: false,
                now: baseDate.addingTimeInterval(2),
                validating: lifecycleToken
            )
            throw MomentSharingError.stateUnavailable
        } catch let error as MomentSharingError {
            guard case .reportOnly = error else { throw error }
        }

        let tombstone = try MomentInboxItem(
            id: momentID,
            senderParticipantID: item.senderParticipantID,
            kind: item.kind,
            keyEpoch: item.keyEpoch,
            localJPEGFileName: nil,
            capturedAt: item.capturedAt,
            captureDateIsMissing: item.captureDateIsMissing,
            committedAt: item.committedAt,
            receivedAt: item.receivedAt,
            state: .revoked,
            accessExpiresAt: item.accessExpiresAt
        ).validated()
        try MomentSharingStateStore.revokeInbox(
            tombstone: tombstone,
            validating: lifecycleToken
        )
        let revoked = try MomentSharingStateStore.load()
        guard revoked.savedMemories.isEmpty,
              revoked.inbox.first(where: { $0.id == momentID })?.state == .revoked,
              revoked.inbox.first(where: { $0.id == blockedMomentID })?.state == .blocked
        else { throw MomentSharingError.stateUnavailable }

        // Exercise the real 500-item pruning boundary without letting old
        // bookmarks displace safety evidence or the newest visible photo.
        try clearMomentSharingFixture()
        guard let retentionDirectory = SharedContainer.momentSharingReceivedDirectoryURL
        else { throw MomentSharingError.stateUnavailable }
        let retentionNow = baseDate.addingTimeInterval(10_000)
        func retentionItem(
            id: String,
            state: MomentInboxState,
            receivedAt: Date
        ) throws -> MomentInboxItem {
            try MomentInboxItem(
                id: id,
                senderParticipantID: item.senderParticipantID,
                kind: item.kind,
                keyEpoch: item.keyEpoch,
                localJPEGFileName: state == .revoked ? nil : "\(id).jpg",
                capturedAt: receivedAt,
                captureDateIsMissing: false,
                committedAt: receivedAt,
                receivedAt: receivedAt,
                state: state,
                accessExpiresAt: receivedAt.addingTimeInterval(30 * 24 * 60 * 60)
            ).validated()
        }

        let newestVisible = try retentionItem(
            id: "retention_newest_visible",
            state: .available,
            receivedAt: retentionNow.addingTimeInterval(-2)
        )
        let blockedEvidence = try retentionItem(
            id: "retention_blocked_evidence",
            state: .blocked,
            receivedAt: retentionNow.addingTimeInterval(-1)
        )
        let revocationTombstone = try retentionItem(
            id: "retention_revocation_tombstone",
            state: .revoked,
            receivedAt: retentionNow
        )
        let ordinaryVisible = try retentionItem(
            id: "retention_ordinary_visible",
            state: .available,
            receivedAt: retentionNow.addingTimeInterval(-2_000)
        )
        var retentionItems = [
            newestVisible,
            blockedEvidence,
            revocationTombstone,
            ordinaryVisible
        ]
        var retentionBookmarks: [MomentSavedMemoryRecord] = []
        for index in 0..<499 {
            let receivedAt = retentionNow.addingTimeInterval(-1_000 - Double(index))
            let savedItem = try retentionItem(
                id: String(format: "retention_saved_%03d", index),
                state: .available,
                receivedAt: receivedAt
            )
            retentionItems.append(savedItem)
            retentionBookmarks.append(
                MomentSavedMemoryRecord(
                    momentID: savedItem.id,
                    savedAt: receivedAt.addingTimeInterval(1)
                )
            )
        }
        for retentionItem in retentionItems {
            if let fileName = retentionItem.localJPEGFileName {
                try SharingSecureFile.write(
                    jpeg,
                    to: retentionDirectory.appendingPathComponent(fileName)
                )
            }
        }
        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            state.inbox = retentionItems
            state.savedMemories = retentionBookmarks
        }
        try MomentSharingStateStore.pruneLocalHistory(now: retentionNow)
        let capped = try MomentSharingStateStore.load()
        guard capped.inbox.count == MomentSharingStateStore.maximumLocalHistoryCount,
              capped.savedMemories.count == 497,
              capped.inbox.contains(where: { $0.id == newestVisible.id }),
              capped.inbox.contains(where: { $0.id == blockedEvidence.id }),
              capped.inbox.contains(where: { $0.id == revocationTombstone.id }),
              !capped.inbox.contains(where: { $0.id == ordinaryVisible.id })
        else { throw MomentSharingError.stateUnavailable }

        try MomentSharingStateStore.pruneLocalHistory(
            now: retentionNow.addingTimeInterval(90 * 24 * 60 * 60 + 1)
        )
        let expired = try MomentSharingStateStore.load()
        let remainingJPEGs = try FileManager.default.contentsOfDirectory(
            at: retentionDirectory,
            includingPropertiesForKeys: nil
        )
        guard expired.inbox.isEmpty,
              expired.savedMemories.isEmpty,
              remainingJPEGs.isEmpty
        else { throw MomentSharingError.stateUnavailable }
    }

    private static func testMomentSentDeliveryReceiptBoundary() throws {
        try clearMomentSharingFixture()
        defer { try? clearMomentSharingFixture() }

        let lifecycleToken = try SharingLifecycleGate.issueToken()
        let createdAt = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970)
        )
        let committedAt = createdAt.addingTimeInterval(1)
        let clientMomentID = UUID()
        let context = MomentRequestContext(
            spaceID: "space_sent_receipt_fixture",
            senderParticipantID: "member_sent_receipt_fixture",
            senderDeviceID: "device_sent_receipt_fixture",
            clientRequestID: UUID(),
            clientMomentID: clientMomentID,
            kind: .live,
            keyEpoch: 1
        )
        let committed = try MomentOutboxItem(
            id: clientMomentID,
            context: context,
            phase: .committed,
            ciphertextFileName: "\(clientMomentID.uuidString.lowercased()).ciphertext",
            ciphertextSize: 128,
            ciphertextSHA256: Data(repeating: 0x42, count: 32),
            moderationVersion: MomentSharingProtocol.moderationVersion,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: createdAt,
            serverMomentID: "moment_sent_receipt_fixture",
            attemptCount: 1,
            commitStartedAt: createdAt,
            committedAt: committedAt,
            unreceivedExpiresAt: committedAt.addingTimeInterval(30 * 24 * 60 * 60),
            recipientCount: 1,
            createdAt: createdAt,
            updatedAt: committedAt
        ).validated()

        // Additive persistence must keep pre-feature committed metadata valid.
        let encoded = try JSONEncoder().encode(committed)
        guard var legacyJSON = try JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        else { throw MomentSharingError.stateUnavailable }
        legacyJSON.removeValue(forKey: "recipientDeliveryConfirmedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacy = try JSONDecoder().decode(MomentOutboxItem.self, from: legacyData)
        guard try legacy.validated().recipientDeliveryConfirmedAt == nil else {
            throw MomentSharingError.stateUnavailable
        }

        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            state.outbox.append(committed)
        }
        guard !(try MomentSharingStateStore.markRecipientDeliveryConfirmed(
            serverMomentID: "moment_unrelated_fixture",
            clientMomentID: clientMomentID,
            observedAt: committedAt.addingTimeInterval(2),
            validating: lifecycleToken
        )), (try MomentSharingStateStore.load().outbox[0])
            .recipientDeliveryConfirmedAt == nil
        else { throw MomentSharingError.stateUnavailable }

        let firstObservation = committedAt.addingTimeInterval(3)
        guard try MomentSharingStateStore.markRecipientDeliveryConfirmed(
            serverMomentID: "moment_sent_receipt_fixture",
            clientMomentID: clientMomentID,
            observedAt: firstObservation,
            validating: lifecycleToken
        ) else { throw MomentSharingError.stateUnavailable }
        let confirmed = try MomentSharingStateStore.load().outbox[0]
        guard confirmed.recipientDeliveryConfirmedAt == firstObservation,
              confirmed.updatedAt == firstObservation,
              !(try MomentSharingStateStore.markRecipientDeliveryConfirmed(
                serverMomentID: "moment_sent_receipt_fixture",
                clientMomentID: clientMomentID,
                observedAt: firstObservation.addingTimeInterval(30),
                validating: lifecycleToken
              )),
              (try MomentSharingStateStore.load().outbox[0])
                .recipientDeliveryConfirmedAt == firstObservation
        else { throw MomentSharingError.stateUnavailable }
    }

    private static func testMomentEmptyCursorNormalization() throws {
        guard try MomentChangeCursorPolicy.normalize("") == nil,
              try MomentChangeCursorPolicy.normalize("0123456789abcdef0123456789abcdef")
                == "0123456789abcdef0123456789abcdef"
        else { throw MomentSharingError.stateUnavailable }
        do {
            _ = try MomentChangeCursorPolicy.normalize("not/a/cursor")
            throw MomentSharingError.stateUnavailable
        } catch MomentSharingError.invalidPayload {
            // Expected: an invalid relay cursor must never be persisted.
        }
    }

    private static func testMomentExpiredDeliveryPolicy() throws {
        guard try MomentDeliveryActionPolicy.action(
            changeType: .momentCommitted,
            deliveryState: "pending"
        ) == .download,
        try MomentDeliveryActionPolicy.action(
            changeType: .momentCommitted,
            deliveryState: "expired"
        ) == .revokeWithoutDownload,
        try MomentDeliveryActionPolicy.action(
            changeType: .deliveryRevoked,
            deliveryState: "revoked"
        ) == .revokeWithoutDownload
        else { throw MomentSharingError.stateUnavailable }

        let relayCommit = Date(timeIntervalSince1970: 1_700_000_060)
        var skewedClockItem = try MomentInboxItem(
            id: "moment_clock_skew_fixture",
            senderParticipantID: "member_clock_skew_fixture",
            kind: .live,
            keyEpoch: 1,
            localJPEGFileName: "moment_clock_skew_fixture.jpg",
            capturedAt: nil,
            captureDateIsMissing: true,
            committedAt: relayCommit,
            receivedAt: relayCommit.addingTimeInterval(-60),
            state: .available,
            accessExpiresAt: relayCommit.addingTimeInterval(3_600)
        ).validated()
        skewedClockItem.state = .revoked
        _ = try skewedClockItem.validated()
    }

    private static func testMomentInboundModerationRetryPolicy() throws {
        guard try MomentInboundModerationPolicy.inboxState(after: nil) == .available,
              try MomentInboundModerationPolicy.inboxState(
                  after: .sensitiveContent
              ) == .blocked
        else { throw MomentSharingError.stateUnavailable }

        for expected in [
            MomentSharingError.moderationDisabled,
            MomentSharingError.moderationUnavailable
        ] {
            do {
                _ = try MomentInboundModerationPolicy.inboxState(after: expected)
                throw MomentSharingError.stateUnavailable
            } catch let received as MomentSharingError {
                guard received == expected else {
                    throw MomentSharingError.stateUnavailable
                }
            }
        }

        do {
            _ = try MomentInboundModerationPolicy.inboxState(
                after: .invalidPayload
            )
            throw MomentSharingError.stateUnavailable
        } catch let received as MomentSharingError {
            guard received == .moderationUnavailable else {
                throw MomentSharingError.stateUnavailable
            }
        }
    }

    private static func testMomentInboundModerationFlow() async throws {
        try clearMomentSharingFixture()
        let moderationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NekoWidgetMomentInboundModeration",
                isDirectory: true
            )
        try? FileManager.default.removeItem(at: moderationDirectory)
        defer {
            try? clearMomentSharingFixture()
            try? FileManager.default.removeItem(at: moderationDirectory)
        }

        let lifecycleToken = try SharingLifecycleGate.issueToken()
        let preview = try MomentCanonicalPreviewBuilder.build(image: generatedImage())
        let roomKey = Data(repeating: 0x71, count: 32)
        let installationMarker = UUID().uuidString.lowercased()
        let spaceID = "space_inbound_moderation_flow"
        let receiverID = "member_inbound_receiver"
        let senderID = "member_inbound_sender"
        var pairing = PairingState.unpaired(installationMarker: installationMarker)
        pairing.phase = .paired
        pairing.spaceID = spaceID
        pairing.memberID = receiverID
        let credential = PairingCredential(
            installationMarker: installationMarker,
            account: UUID().uuidString.lowercased(),
            participantID: Data(repeating: 0x72, count: 16),
            agreementPrivateKey: Data(repeating: 0x73, count: 32),
            signingPrivateKey: Data(repeating: 0x74, count: 32),
            roomKey: roomKey,
            enrollmentSecret: nil
        )

        func fixture(_ suffix: String) throws -> (MomentChange, Data, URL) {
            let clientMomentID = UUID()
            let payload = try MomentCrypto.prepare(
                canonicalJPEG: preview.jpeg,
                capturedAt: nil,
                pixelWidth: preview.pixelWidth,
                pixelHeight: preview.pixelHeight,
                context: MomentRequestContext(
                    spaceID: spaceID,
                    senderParticipantID: senderID,
                    senderDeviceID: senderID,
                    clientRequestID: UUID(),
                    clientMomentID: clientMomentID,
                    kind: .live,
                    keyEpoch: 1
                ),
                spaceGenerationKey: roomKey
            )
            let momentID = "moment_inbound_\(suffix)"
            let committedAt = Date().addingTimeInterval(-60)
            let change = MomentChange(
                cursor: "cursor_inbound_\(suffix)",
                type: .momentCommitted,
                createdAt: committedAt,
                momentID: momentID,
                clientMomentID: clientMomentID,
                senderParticipantID: senderID,
                kind: .live,
                keyEpoch: 1,
                ciphertextSize: payload.ciphertext.count,
                ciphertextSHA256: payload.ciphertextSHA256,
                committedAt: committedAt,
                accessExpiresAt: committedAt.addingTimeInterval(3_600),
                deliveryState: "pending"
            )
            guard let receivedDirectory = SharedContainer
                .momentSharingReceivedDirectoryURL
            else { throw MomentSharingError.stateUnavailable }
            return (
                change,
                payload.ciphertext,
                receivedDirectory.appendingPathComponent(
                    "\(momentID).jpg",
                    isDirectory: false
                )
            )
        }

        func requireNoModerationResidue() throws {
            guard FileManager.default.fileExists(atPath: moderationDirectory.path)
            else { return }
            let files = try FileManager.default.contentsOfDirectory(
                at: moderationDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsSubdirectoryDescendants]
            )
            guard !files.contains(where: {
                $0.lastPathComponent.hasPrefix(".inbound-")
            }) else { throw MomentSharingError.stateUnavailable }
        }

        let disabledFixture = try fixture("disabled")
        let disabledAPI = RuntimeMomentAPI(
            change: disabledFixture.0,
            ciphertext: disabledFixture.1
        )
        let disabledModerator = RuntimeMomentModerator(
            steps: [.failure(.moderationDisabled), .safe]
        )
        let disabledCoordinator = MomentSharingCoordinator(
            moderation: disabledModerator
        )
        do {
            _ = try await disabledCoordinator.runtimeTestReceiveChanges(
                api: disabledAPI,
                pairing: pairing,
                credential: credential,
                lifecycleToken: lifecycleToken
            )
            throw MomentSharingError.stateUnavailable
        } catch let error as MomentSharingError {
            guard error == .moderationDisabled else { throw error }
        }
        let disabledRetryState = try MomentSharingStateStore.load()
        let disabledRetryCounts = await disabledAPI.runtimeCounts()
        let disabledRetryAnalysisCount = await disabledModerator
            .runtimeAnalysisCount()
        guard disabledRetryState.changeCursor == nil,
              disabledRetryState.inbox.isEmpty,
              disabledRetryCounts.downloads == 1,
              disabledRetryCounts.acknowledgements == 0,
              disabledRetryAnalysisCount == 1,
              !FileManager.default.fileExists(atPath: disabledFixture.2.path)
        else { throw MomentSharingError.stateUnavailable }
        try requireNoModerationResidue()

        guard try await disabledCoordinator.runtimeTestReceiveChanges(
            api: disabledAPI,
            pairing: pairing,
            credential: credential,
            lifecycleToken: lifecycleToken
        ) == 1 else { throw MomentSharingError.stateUnavailable }
        let recoveredState = try MomentSharingStateStore.load()
        let recoveredCounts = await disabledAPI.runtimeCounts()
        let recoveredAnalysisCount = await disabledModerator
            .runtimeAnalysisCount()
        guard recoveredState.changeCursor == disabledFixture.0.cursor,
              recoveredState.inbox.count == 1,
              recoveredState.inbox[0].state == .acknowledged,
              recoveredCounts.downloads == 2,
              recoveredCounts.acknowledgements == 1,
              recoveredAnalysisCount == 2,
              try Data(contentsOf: disabledFixture.2) == preview.jpeg,
              SharingSecureFile.hasRequiredProtectionAndBackupExclusion(
                  disabledFixture.2
              )
        else { throw MomentSharingError.stateUnavailable }
        try requireNoModerationResidue()

        try clearMomentSharingFixture()
        let unavailableFixture = try fixture("unavailable")
        let unavailableAPI = RuntimeMomentAPI(
            change: unavailableFixture.0,
            ciphertext: unavailableFixture.1
        )
        let unavailableModerator = RuntimeMomentModerator(
            steps: [.failure(.moderationUnavailable)]
        )
        let unavailableCoordinator = MomentSharingCoordinator(
            moderation: unavailableModerator
        )
        do {
            _ = try await unavailableCoordinator.runtimeTestReceiveChanges(
                api: unavailableAPI,
                pairing: pairing,
                credential: credential,
                lifecycleToken: lifecycleToken
            )
            throw MomentSharingError.stateUnavailable
        } catch let error as MomentSharingError {
            guard error == .moderationUnavailable else { throw error }
        }
        let unavailableState = try MomentSharingStateStore.load()
        let unavailableCounts = await unavailableAPI.runtimeCounts()
        let unavailableAnalysisCount = await unavailableModerator
            .runtimeAnalysisCount()
        guard unavailableState.changeCursor == nil,
              unavailableState.inbox.isEmpty,
              unavailableCounts.downloads == 1,
              unavailableCounts.acknowledgements == 0,
              unavailableAnalysisCount == 1,
              !FileManager.default.fileExists(atPath: unavailableFixture.2.path)
        else { throw MomentSharingError.stateUnavailable }
        try requireNoModerationResidue()

        try clearMomentSharingFixture()
        let sensitiveFixture = try fixture("sensitive")
        let sensitiveAPI = RuntimeMomentAPI(
            change: sensitiveFixture.0,
            ciphertext: sensitiveFixture.1
        )
        let sensitiveModerator = RuntimeMomentModerator(
            steps: [.failure(.sensitiveContent)]
        )
        let sensitiveCoordinator = MomentSharingCoordinator(
            moderation: sensitiveModerator
        )
        guard try await sensitiveCoordinator.runtimeTestReceiveChanges(
            api: sensitiveAPI,
            pairing: pairing,
            credential: credential,
            lifecycleToken: lifecycleToken
        ) == 1 else { throw MomentSharingError.stateUnavailable }
        let sensitiveState = try MomentSharingStateStore.load()
        let sensitiveCounts = await sensitiveAPI.runtimeCounts()
        let sensitiveAnalysisCount = await sensitiveModerator
            .runtimeAnalysisCount()
        guard sensitiveState.changeCursor == sensitiveFixture.0.cursor,
              sensitiveState.inbox.count == 1,
              sensitiveState.inbox[0].state == .blocked,
              sensitiveState.inbox[0].acknowledgedAt != nil,
              sensitiveCounts.downloads == 1,
              sensitiveCounts.acknowledgements == 1,
              sensitiveAnalysisCount == 1,
              try Data(contentsOf: sensitiveFixture.2) == preview.jpeg,
              SharingSecureFile.hasRequiredProtectionAndBackupExclusion(
                  sensitiveFixture.2
              )
        else { throw MomentSharingError.stateUnavailable }
        try requireNoModerationResidue()

        guard try await sensitiveCoordinator.runtimeTestReceiveChanges(
            api: sensitiveAPI,
            pairing: pairing,
            credential: credential,
            lifecycleToken: lifecycleToken
        ) == 0 else { throw MomentSharingError.stateUnavailable }
        let terminalSensitiveCounts = await sensitiveAPI.runtimeCounts()
        let terminalSensitiveAnalysisCount = await sensitiveModerator
            .runtimeAnalysisCount()
        guard terminalSensitiveCounts.downloads == 1,
              terminalSensitiveCounts.acknowledgements == 1,
              terminalSensitiveAnalysisCount == 1
        else { throw MomentSharingError.stateUnavailable }
    }

    private static func testMomentOutboxBoundsAndExpiry() throws {
        try clearMomentSharingFixture()
        defer { try? clearMomentSharingFixture() }
        let lifecycleToken = try SharingLifecycleGate.issueToken()
        let roomKey = Data(repeating: 0x61, count: 32)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        func payload(index: Int) throws -> MomentPreparedPayload {
            try MomentCrypto.prepare(
                canonicalJPEG: Data(repeating: UInt8(0x30 + index), count: 512),
                capturedAt: nil,
                pixelWidth: 32,
                pixelHeight: 16,
                context: MomentRequestContext(
                    spaceID: "space_outbox_fixture",
                    senderParticipantID: "member_outbox_fixture",
                    senderDeviceID: "member_outbox_fixture",
                    clientRequestID: UUID(),
                    clientMomentID: UUID(),
                    kind: .live,
                    keyEpoch: 1
                ),
                spaceGenerationKey: roomKey
            )
        }

        for index in 0..<10 {
            _ = try MomentSharingStateStore.enqueue(
                payload: payload(index: index),
                senderPolicyVersion: 1,
                senderPolicyAcceptedAt: baseDate,
                validating: lifecycleToken,
                now: baseDate
            )
        }
        do {
            _ = try MomentSharingStateStore.enqueue(
                payload: payload(index: 10),
                senderPolicyVersion: 1,
                senderPolicyAcceptedAt: baseDate,
                validating: lifecycleToken,
                now: baseDate
            )
            throw MomentSharingError.stateUnavailable
        } catch MomentSharingError.outboxFull {
            // Expected: offline use cannot grow a hidden unbounded queue.
        }

        let ambiguous = try MomentSharingStateStore.load().outbox[0]
        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            guard let index = state.outbox.firstIndex(where: { $0.id == ambiguous.id })
            else { throw MomentSharingError.stateUnavailable }
            state.outbox[index].serverMomentID = "moment_commit_fixture"
            state.outbox[index].phase = .committing
            state.outbox[index].commitStartedAt = baseDate
            state.outbox[index].uploadExpiresAt = baseDate.addingTimeInterval(60 * 60)
        }
        try MomentSharingStateStore.discardPendingOutbox(validating: lifecycleToken)
        let afterDiscard = try MomentSharingStateStore.load().outbox
        guard afterDiscard.count == 1,
              afterDiscard[0].id == ambiguous.id,
              afterDiscard[0].phase == .committing
        else {
            throw MomentSharingError.stateUnavailable
        }
        try MomentSharingStateStore.markOutboxFailed(
            itemID: ambiguous.id,
            code: "must-not-overwrite-commit-ambiguity",
            validating: lifecycleToken
        )
        guard try MomentSharingStateStore.load().outbox.first?.phase == .committing
        else { throw MomentSharingError.stateUnavailable }
        guard try MomentSharingStateStore.recoverExpiredReservation(
            itemID: ambiguous.id,
            validating: lifecycleToken,
            now: baseDate.addingTimeInterval(30)
        ),
        let recoveredReservation = try MomentSharingStateStore.load().outbox.first,
        recoveredReservation.phase == .prepared,
        recoveredReservation.serverMomentID == nil,
        recoveredReservation.uploadExpiresAt == nil,
        recoveredReservation.commitStartedAt == nil
        else { throw MomentSharingError.stateUnavailable }
        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            guard let index = state.outbox.firstIndex(where: { $0.id == ambiguous.id })
            else { throw MomentSharingError.stateUnavailable }
            state.outbox[index].serverMomentID = "moment_commit_fixture_retried"
            state.outbox[index].phase = .committing
            state.outbox[index].commitStartedAt = baseDate
            // Simulate malformed/corrupt persisted relay input. Local retention
            // must remain bounded even if this wall-clock date is far future.
            state.outbox[index].uploadExpiresAt = baseDate.addingTimeInterval(365 * 24 * 60 * 60)
        }
        try MomentSharingStateStore.pruneLocalHistory(
            now: baseDate.addingTimeInterval(
                MomentSharingProtocol.commitReplayRetentionSeconds + 1
            )
        )
        guard try MomentSharingStateStore.load().outbox.first?.phase == .committing
        else { throw MomentSharingError.stateUnavailable }
        try MomentSharingStateStore.pruneLocalHistory(
            now: baseDate.addingTimeInterval(
                MomentSharingProtocol.maximumUploadLeaseSeconds
                    + MomentSharingProtocol.maximumRelayClockSkewSeconds
                    + MomentSharingProtocol.commitReplayRetentionSeconds + 1
            )
        )
        guard let unresolved = try MomentSharingStateStore.load().outbox.first,
              unresolved.phase == .deliveryResultUnknown,
              let ambiguityCiphertextDirectory =
                SharedContainer.momentSharingCiphertextDirectoryURL,
              !FileManager.default.fileExists(
                  atPath: ambiguityCiphertextDirectory.appendingPathComponent(
                      unresolved.ciphertextFileName
                  ).path
              )
        else { throw MomentSharingError.stateUnavailable }
        try MomentSharingStateStore.discardFailedOutbox(validating: lifecycleToken)
        guard try MomentSharingStateStore.load().outbox.isEmpty
        else { throw MomentSharingError.stateUnavailable }

        let expiring = try MomentSharingStateStore.enqueue(
            payload: payload(index: 11),
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: baseDate,
            validating: lifecycleToken,
            now: baseDate
        )
        try MomentSharingStateStore.pruneLocalHistory(
            now: baseDate.addingTimeInterval(7 * 24 * 60 * 60 + 1)
        )
        guard let expired = try MomentSharingStateStore.load().outbox.first,
              expired.id == expiring.id,
              expired.phase == .failed,
              let directory = SharedContainer.momentSharingCiphertextDirectoryURL,
              !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(expired.ciphertextFileName).path
              )
        else { throw MomentSharingError.stateUnavailable }

        try MomentSharingStateStore.pruneLocalHistory(
            now: expired.updatedAt.addingTimeInterval(30 * 24 * 60 * 60 + 1)
        )
        guard try MomentSharingStateStore.load().outbox.isEmpty else {
            throw MomentSharingError.stateUnavailable
        }

        var oldestTerminalID: UUID?
        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            for index in 0...MomentSharingStateStore.maximumTerminalOutboxMetadataCount {
                let id = UUID()
                if index == 0 { oldestTerminalID = id }
                let createdAt = baseDate.addingTimeInterval(
                    60 * 24 * 60 * 60 + TimeInterval(index)
                )
                let context = MomentRequestContext(
                    spaceID: "space_terminal_\(index)",
                    senderParticipantID: "member_terminal_\(index)",
                    senderDeviceID: "device_terminal_\(index)",
                    clientRequestID: UUID(),
                    clientMomentID: id,
                    kind: .live,
                    keyEpoch: 1
                )
                state.outbox.append(try MomentOutboxItem(
                    id: id,
                    context: context,
                    phase: .failed,
                    ciphertextFileName: "\(id.uuidString.lowercased()).ciphertext",
                    ciphertextSize: 128,
                    ciphertextSHA256: Data(repeating: UInt8(index % 255), count: 32),
                    moderationVersion: MomentSharingProtocol.moderationVersion,
                    senderPolicyVersion: 1,
                    senderPolicyAcceptedAt: createdAt,
                    attemptCount: 1,
                    lastErrorCode: "state-unavailable",
                    createdAt: createdAt,
                    updatedAt: createdAt
                ).validated())
            }
        }
        guard let crashCiphertextDirectory =
                SharedContainer.momentSharingCiphertextDirectoryURL,
              let crashReceivedDirectory =
                SharedContainer.momentSharingReceivedDirectoryURL
        else { throw MomentSharingError.stateUnavailable }
        let crashCiphertext = crashCiphertextDirectory.appendingPathComponent(
            ".sharing-secure-runtime-crash-ciphertext",
            isDirectory: false
        )
        let crashReceivedJPEG = crashReceivedDirectory.appendingPathComponent(
            ".sharing-secure-runtime-crash-jpeg",
            isDirectory: false
        )
        try SharingSecureFile.write(Data([0x71]), to: crashCiphertext)
        try SharingSecureFile.write(Data([0x72]), to: crashReceivedJPEG)
        try MomentSharingStateStore.pruneLocalHistory(
            now: baseDate.addingTimeInterval(60 * 24 * 60 * 60 + 200)
        )
        let boundedTerminal = try MomentSharingStateStore.load().outbox
        guard boundedTerminal.count
                == MomentSharingStateStore.maximumTerminalOutboxMetadataCount,
              oldestTerminalID.map({ id in
                  !boundedTerminal.contains(where: { $0.id == id })
              }) == true,
              !FileManager.default.fileExists(atPath: crashCiphertext.path),
              !FileManager.default.fileExists(atPath: crashReceivedJPEG.path)
        else { throw MomentSharingError.stateUnavailable }
    }

    private static func testMomentOutcomeLedgerAndMigration() throws {
        try clearMomentSharingFixture()
        defer { try? clearMomentSharingFixture() }
        let baseDate = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970)
        )
        let legacyContext = MomentRequestContext(
            spaceID: "space_legacy_outcome_fixture",
            senderParticipantID: "member_legacy_outcome_fixture",
            senderDeviceID: "device_legacy_outcome_fixture",
            clientRequestID: UUID(),
            clientMomentID: UUID(),
            kind: .live,
            keyEpoch: 1
        )
        let legacyOutbox = try MomentOutboxItem(
            id: legacyContext.clientMomentID,
            context: legacyContext,
            phase: .committed,
            ciphertextFileName:
                "\(legacyContext.clientMomentID.uuidString.lowercased()).ciphertext",
            ciphertextSize: 128,
            ciphertextSHA256: Data(repeating: 0x42, count: 32),
            moderationVersion: MomentSharingProtocol.moderationVersion,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: baseDate,
            serverMomentID: "moment_legacy_outcome_fixture",
            attemptCount: 0,
            createdAt: baseDate,
            updatedAt: baseDate
        ).validated()
        let legacyCommittingContext = MomentRequestContext(
            spaceID: "space_legacy_committing_fixture",
            senderParticipantID: "member_legacy_committing_fixture",
            senderDeviceID: "device_legacy_committing_fixture",
            clientRequestID: UUID(),
            clientMomentID: UUID(),
            kind: .live,
            keyEpoch: 1
        )
        let legacyCommitting = MomentOutboxItem(
            id: legacyCommittingContext.clientMomentID,
            context: legacyCommittingContext,
            phase: .committing,
            ciphertextFileName:
                "\(legacyCommittingContext.clientMomentID.uuidString.lowercased()).ciphertext",
            ciphertextSize: 128,
            ciphertextSHA256: Data(repeating: 0x43, count: 32),
            moderationVersion: MomentSharingProtocol.moderationVersion,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: baseDate,
            serverMomentID: "moment_legacy_committing_fixture",
            uploadExpiresAt: baseDate.addingTimeInterval(3_600),
            attemptCount: 2,
            createdAt: baseDate,
            updatedAt: baseDate.addingTimeInterval(100)
        )
        let legacyReportID = UUID()
        let legacyReport = MomentReportOutboxItem(
            id: legacyReportID,
            momentID: "moment_legacy_report_fixture",
            reason: .privacy,
            ciphertextFileName:
                "report-\(legacyReportID.uuidString.lowercased()).ciphertext",
            ciphertextSize: 128,
            ciphertextSHA256: Data(repeating: 0x44, count: 32),
            moderationKeyID: "moderation-v1",
            reporterConsentAcceptedAt: baseDate,
            commitRequestID: UUID(),
            phase: .committing,
            serverReportID: "report_legacy_committing_fixture",
            createdAt: baseDate,
            updatedAt: baseDate.addingTimeInterval(120)
        )
        let currentEncoding = MomentSharingState(
            storageRevision: 3,
            changeCursor: nil,
            outbox: [legacyOutbox, legacyCommitting],
            inbox: [],
            reportOutbox: [legacyReport]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let currentEncoded = try encoder.encode(currentEncoding)
        var schema5Object = try JSONSerialization.jsonObject(
            with: encoder.encode(MomentSharingState.empty)
        ) as? [String: Any]
        schema5Object?["schemaVersion"] = 5
        schema5Object?.removeValue(forKey: "savedMemories")
        var legacyObject = try JSONSerialization.jsonObject(
            with: currentEncoded
        ) as? [String: Any]
        legacyObject?["schemaVersion"] = 3
        legacyObject?.removeValue(forKey: "outgoingOutcomes")
        legacyObject?.removeValue(forKey: "savedMemories")
        if var legacyOutboxItems = legacyObject?["outbox"] as? [[String: Any]],
           !legacyOutboxItems.isEmpty {
            for index in legacyOutboxItems.indices {
                legacyOutboxItems[index].removeValue(forKey: "committedAt")
                legacyOutboxItems[index].removeValue(forKey: "unreceivedExpiresAt")
                legacyOutboxItems[index].removeValue(forKey: "recipientCount")
                legacyOutboxItems[index].removeValue(forKey: "commitStartedAt")
            }
            legacyObject?["outbox"] = legacyOutboxItems
        }
        if var legacyReports = legacyObject?["reportOutbox"] as? [[String: Any]],
           !legacyReports.isEmpty {
            legacyReports[0].removeValue(forKey: "commitStartedAt")
            legacyObject?["reportOutbox"] = legacyReports
        }
        guard let schema5Object,
              let legacyObject,
              let stateURL = SharedContainer.momentSharingStateURL
        else { throw MomentSharingError.stateUnavailable }
        try SharingSecureFile.write(
            JSONSerialization.data(withJSONObject: schema5Object, options: [.sortedKeys]),
            to: stateURL
        )
        let migratedSchema5 = try MomentSharingStateStore.load()
        guard migratedSchema5.schemaVersion == MomentSharingState.schemaVersion,
              migratedSchema5.savedMemories.isEmpty,
              migratedSchema5 == .empty
        else { throw MomentSharingError.stateUnavailable }

        try SharingSecureFile.write(
            JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys]),
            to: stateURL
        )

        let migrated = try MomentSharingStateStore.load()
        guard migrated.schemaVersion == MomentSharingState.schemaVersion,
              migrated.savedMemories.isEmpty,
              migrated.outgoingOutcomes.isEmpty,
              migrated.outbox.count == 2,
              let migratedCommitted = migrated.outbox.first(where: {
                  $0.id == legacyOutbox.id
              }),
              migratedCommitted.phase == .committed,
              migratedCommitted.committedAt == nil,
              migratedCommitted.unreceivedExpiresAt == nil,
              migratedCommitted.recipientCount == nil,
              let migratedCommitting = migrated.outbox.first(where: {
                  $0.id == legacyCommitting.id
              }),
              migratedCommitting.phase == .committing,
              migratedCommitting.commitStartedAt == legacyCommitting.updatedAt,
              let migratedReport = migrated.reportOutbox.first(where: {
                  $0.id == legacyReport.id
              }),
              migratedReport.phase == .committing,
              migratedReport.commitStartedAt == legacyReport.updatedAt
        else { throw MomentSharingError.stateUnavailable }

        let lifecycleToken = try SharingLifecycleGate.issueToken()
        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            state.outbox.removeAll()
            for index in 0...MomentOutgoingOutcome.maximumCount {
                let createdAt = baseDate.addingTimeInterval(TimeInterval(index))
                state.outgoingOutcomes.append(
                    try MomentOutgoingOutcome(
                        id: UUID(),
                        reason: index == 0 ? .sensitiveContent : .invalidPhoto,
                        createdAt: createdAt,
                        expiresAt: createdAt.addingTimeInterval(
                            MomentOutgoingOutcome.retentionSeconds
                        )
                    ).validated()
                )
            }
        }
        let bounded = try MomentSharingStateStore.load().outgoingOutcomes
        guard bounded.count == MomentOutgoingOutcome.maximumCount,
              !bounded.contains(where: { $0.reason == .sensitiveContent })
        else { throw MomentSharingError.stateUnavailable }

        let sensitive = try MomentSharingStateStore.recordOutgoingOutcome(
            reason: .sensitiveContent,
            validating: lifecycleToken,
            now: baseDate.addingTimeInterval(1_000)
        )
        let encodedState = try MomentSharingStateStore.load()
        let encoded = try encoder.encode(encodedState)
        guard let encodedObject = try JSONSerialization.jsonObject(with: encoded)
                as? [String: Any],
              let outcomes = encodedObject["outgoingOutcomes"] as? [[String: Any]],
              outcomes.allSatisfy({ Set($0.keys) == [
                  "schemaVersion", "id", "reason", "createdAt", "expiresAt"
              ] }),
              outcomes.contains(where: { $0["reason"] as? String == "sensitiveContent" })
        else { throw MomentSharingError.stateUnavailable }

        try MomentSharingStateStore.dismissOutgoingOutcome(
            id: sensitive.id,
            validating: lifecycleToken
        )
        let afterDismiss = try MomentSharingStateStore.load()
        guard !afterDismiss.outgoingOutcomes.contains(where: {
            $0.id == sensitive.id
        }) else { throw MomentSharingError.stateUnavailable }
        try MomentSharingStateStore.pruneLocalHistory(
            now: baseDate.addingTimeInterval(
                MomentOutgoingOutcome.retentionSeconds + 1_001
            )
        )
        guard try MomentSharingStateStore.load().outgoingOutcomes.isEmpty
        else { throw MomentSharingError.stateUnavailable }
    }

    private static func testMomentCommitAcknowledgementMetadata() throws {
        let baseDate = Date(timeIntervalSince1970: 1_900_000_000)
        guard try MomentSharingProtocol.validatedUploadExpiry(
            baseDate.addingTimeInterval(MomentSharingProtocol.maximumUploadLeaseSeconds),
            receivedAt: baseDate
        ) == baseDate.addingTimeInterval(MomentSharingProtocol.maximumUploadLeaseSeconds)
        else { throw MomentSharingError.stateUnavailable }
        do {
            _ = try MomentSharingProtocol.validatedUploadExpiry(
                baseDate.addingTimeInterval(
                    MomentSharingProtocol.maximumUploadLeaseSeconds
                        + MomentSharingProtocol.maximumRelayClockSkewSeconds + 1
                ),
                receivedAt: baseDate
            )
            throw MomentSharingError.stateUnavailable
        } catch MomentSharingError.invalidPayload {
            // A relay date cannot extend local ciphertext retention forever.
        }
        guard try MomentSharingProtocol.boundedReportOnlyUntil(
            baseDate.addingTimeInterval(
                MomentSharingProtocol.maximumReportOnlyWindowSeconds
                    + 2 * MomentSharingProtocol.maximumRelayClockSkewSeconds
            ),
            receivedAt: baseDate
        ) == baseDate.addingTimeInterval(
            MomentSharingProtocol.maximumReportOnlyWindowSeconds
                + MomentSharingProtocol.maximumRelayClockSkewSeconds
        ) else { throw MomentSharingError.stateUnavailable }
        let reportOnlyUntil = baseDate.addingTimeInterval(60)
        guard !MomentSharingProtocol.isReportOnlyWindowClosed(
            until: reportOnlyUntil,
            now: reportOnlyUntil.addingTimeInterval(
                MomentSharingProtocol.maximumRelayClockSkewSeconds - 1
            )
        ),
        MomentSharingProtocol.isReportOnlyWindowClosed(
            until: reportOnlyUntil,
            now: reportOnlyUntil.addingTimeInterval(
                MomentSharingProtocol.maximumRelayClockSkewSeconds
            )
        ) else { throw MomentSharingError.stateUnavailable }
        let context = MomentRequestContext(
            spaceID: "space_commit_ack_fixture",
            senderParticipantID: "member_commit_ack_fixture",
            senderDeviceID: "device_commit_ack_fixture",
            clientRequestID: UUID(),
            clientMomentID: UUID(),
            kind: .live,
            keyEpoch: 1
        )
        let committedAt = baseDate.addingTimeInterval(60)
        let unreceivedExpiresAt = committedAt.addingTimeInterval(24 * 60 * 60)
        let committed = try MomentOutboxItem(
            id: context.clientMomentID,
            context: context,
            phase: .committed,
            ciphertextFileName:
                "\(context.clientMomentID.uuidString.lowercased()).ciphertext",
            ciphertextSize: 128,
            ciphertextSHA256: Data(repeating: 0x44, count: 32),
            moderationVersion: MomentSharingProtocol.moderationVersion,
            senderPolicyVersion: 1,
            senderPolicyAcceptedAt: baseDate,
            serverMomentID: "moment_commit_ack_fixture",
            attemptCount: 0,
            commitStartedAt: baseDate.addingTimeInterval(30),
            committedAt: committedAt,
            unreceivedExpiresAt: unreceivedExpiresAt,
            recipientCount: 3,
            createdAt: baseDate,
            updatedAt: committedAt
        ).validated()
        guard committed.committedAt == committedAt,
              committed.unreceivedExpiresAt == unreceivedExpiresAt,
              committed.recipientCount == 3
        else { throw MomentSharingError.stateUnavailable }

        var partial = committed
        partial.unreceivedExpiresAt = nil
        var rejectedPartialTuple = false
        do {
            _ = try partial.validated()
        } catch MomentSharingError.stateUnavailable {
            rejectedPartialTuple = true
        }
        guard rejectedPartialTuple else { throw MomentSharingError.stateUnavailable }

        var missingNewCommitTuple = committed
        missingNewCommitTuple.committedAt = nil
        missingNewCommitTuple.unreceivedExpiresAt = nil
        missingNewCommitTuple.recipientCount = nil
        var rejectedMissingNewCommitTuple = false
        do {
            _ = try missingNewCommitTuple.validated()
        } catch MomentSharingError.stateUnavailable {
            rejectedMissingNewCommitTuple = true
        }
        guard rejectedMissingNewCommitTuple else {
            throw MomentSharingError.stateUnavailable
        }

        var tupleWithoutCommitStart = committed
        tupleWithoutCommitStart.commitStartedAt = nil
        var rejectedTupleWithoutCommitStart = false
        do {
            _ = try tupleWithoutCommitStart.validated()
        } catch MomentSharingError.stateUnavailable {
            rejectedTupleWithoutCommitStart = true
        }
        guard rejectedTupleWithoutCommitStart else {
            throw MomentSharingError.stateUnavailable
        }

        var commitStartAfterUpdate = committed
        commitStartAfterUpdate.commitStartedAt = committed.updatedAt.addingTimeInterval(1)
        var rejectedCommitStartAfterUpdate = false
        do {
            _ = try commitStartAfterUpdate.validated()
        } catch MomentSharingError.stateUnavailable {
            rejectedCommitStartAfterUpdate = true
        }
        guard rejectedCommitStartAfterUpdate else {
            throw MomentSharingError.stateUnavailable
        }
    }

    private static func testMomentReportOutboxBoundsAndRecovery() throws {
        try clearMomentSharingFixture()
        defer { try? clearMomentSharingFixture() }
        let lifecycleToken = try SharingLifecycleGate.issueToken()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        func prepared(index: Int) -> MomentPreparedReport {
            let ciphertext = Data(repeating: UInt8(0x70 + index), count: 128)
            return MomentPreparedReport(
                ciphertext: ciphertext,
                ciphertextSHA256: PairingCrypto.sha256(ciphertext),
                moderationKeyID: "moderation-v1"
            )
        }

        var first: MomentReportOutboxItem?
        for index in 0..<10 {
            let item = try MomentSharingStateStore.enqueueReport(
                momentID: "moment_report_fixture_\(index)",
                reason: .privacy,
                prepared: prepared(index: index),
                reporterConsentAcceptedAt: baseDate,
                validating: lifecycleToken,
                now: baseDate
            )
            if index == 0 { first = item }
        }
        do {
            _ = try MomentSharingStateStore.enqueueReport(
                momentID: "moment_report_fixture_10",
                reason: .privacy,
                prepared: prepared(index: 10),
                reporterConsentAcceptedAt: baseDate,
                validating: lifecycleToken,
                now: baseDate
            )
            throw MomentSharingError.stateUnavailable
        } catch MomentSharingError.outboxFull {
            // Expected: moderation copies are bounded independently too.
        }

        guard let first else { throw MomentSharingError.stateUnavailable }
        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            guard let index = state.reportOutbox.firstIndex(where: { $0.id == first.id })
            else { throw MomentSharingError.stateUnavailable }
            state.reportOutbox[index].serverReportID = "report_reservation_fixture"
            state.reportOutbox[index].phase = .reserved
        }
        guard try MomentSharingStateStore.recoverExpiredReportReservation(
            itemID: first.id,
            validating: lifecycleToken,
            now: baseDate.addingTimeInterval(60)
        ),
        let recovered = try MomentSharingStateStore.load().reportOutbox.first(where: {
            $0.id == first.id
        }),
        recovered.phase == .prepared,
        recovered.serverReportID == nil
        else { throw MomentSharingError.stateUnavailable }

        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            guard let index = state.reportOutbox.firstIndex(where: { $0.id == first.id })
            else { throw MomentSharingError.stateUnavailable }
            state.reportOutbox[index].serverReportID = "report_commit_fixture"
            state.reportOutbox[index].phase = .committing
            state.reportOutbox[index].commitStartedAt = baseDate
        }
        try MomentSharingStateStore.pruneLocalHistory(
            now: baseDate.addingTimeInterval(24 * 60 * 60 + 1)
        )
        let retained = try MomentSharingStateStore.load().reportOutbox
        guard retained.count == 1,
              retained[0].id == first.id,
              retained[0].phase == .committing,
              let directory = SharedContainer.momentSharingCiphertextDirectoryURL,
              FileManager.default.fileExists(
                  atPath: directory.appendingPathComponent(first.ciphertextFileName).path
              )
        else { throw MomentSharingError.stateUnavailable }

        try MomentSharingStateStore.pruneLocalHistory(
            now: baseDate.addingTimeInterval(
                MomentSharingProtocol.maximumUploadLeaseSeconds
                    + MomentSharingProtocol.reportContentRetentionSeconds
                    + (2 * MomentSharingProtocol.maximumRelayClockSkewSeconds)
                    + 1
            )
        )
        guard let unresolved = try MomentSharingStateStore.load().reportOutbox.first,
              unresolved.id == first.id,
              unresolved.phase == .deliveryResultUnknown,
              !FileManager.default.fileExists(
                  atPath: directory.appendingPathComponent(first.ciphertextFileName).path
              )
        else { throw MomentSharingError.stateUnavailable }
    }

    private static func clearMomentSharingFixture() throws {
        try SharingLifecycleGate.withExclusive {
            for url in [
                SharedContainer.momentSharingStateURL,
                SharedContainer.momentSharingCiphertextDirectoryURL,
                SharedContainer.momentSharingReceivedDirectoryURL,
                SharedContainer.momentShareHandoffReportOnlyMarkerURL
            ].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func generatedImage(
        size: CGSize = CGSize(width: 96, height: 72)
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: size,
            format: format
        ).image { context in
            let scaleX = size.width / 96
            let scaleY = size.height / 72
            func scaled(_ rect: CGRect) -> CGRect {
                CGRect(
                    x: rect.minX * scaleX,
                    y: rect.minY * scaleY,
                    width: rect.width * scaleX,
                    height: rect.height * scaleY
                )
            }
            UIColor(red: 0.08, green: 0.16, blue: 0.28, alpha: 1).setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.92, green: 0.24, blue: 0.12, alpha: 1).setFill()
            context.cgContext.fill(scaled(CGRect(x: 3, y: 5, width: 31, height: 19)))
            UIColor(red: 0.12, green: 0.78, blue: 0.34, alpha: 1).setFill()
            context.cgContext.fill(scaled(CGRect(x: 51, y: 11, width: 38, height: 47)))
            UIColor(red: 0.94, green: 0.86, blue: 0.18, alpha: 1).setFill()
            context.cgContext.fill(scaled(CGRect(x: 17, y: 49, width: 23, height: 13)))
        }
    }

    /// Adds fixed synthetic APPn/COM segments without using any device or photo
    /// metadata. The Moment encoder must remove every segment byte-for-byte.
    private static func momentJPEGWithSyntheticPrivateMetadata(_ jpeg: Data) throws -> Data {
        guard jpeg.count >= 4,
              jpeg[0] == 0xFF,
              jpeg[1] == 0xD8,
              jpeg[jpeg.count - 2] == 0xFF,
              jpeg[jpeg.count - 1] == 0xD9
        else {
            throw MomentSharingError.invalidPayload
        }
        let segments = try momentSyntheticPrivateMetadataSegments()
        var result = Data([0xFF, 0xD8])
        // Exercise both the ordinary header and markers found after entropy
        // data but before EOI. The latter prevents an SOS-to-EOF shortcut from
        // silently accepting private metadata between scans.
        result.append(segments)
        result.append(contentsOf: jpeg.dropFirst(2).dropLast(2))
        result.append(segments)
        result.append(contentsOf: [0xFF, 0xD9])
        return result
    }

    private static func momentSyntheticPrivateMetadataSegments() throws -> Data {
        var result = Data()
        for (marker, payload) in [
            (UInt8(0xE0), Array("JFIF\u{0}runtime-private".utf8)),
            (UInt8(0xE1), Array("Exif\u{0}\u{0}runtime".utf8)),
            (UInt8(0xE3), Array("runtime-unknown-app".utf8)),
            (UInt8(0xED), Array("Photoshop 3.0\u{0}runtime".utf8)),
            (UInt8(0xFE), Array("runtime-comment".utf8))
        ] {
            let length = payload.count + 2
            guard length <= Int(UInt16.max) else {
                throw MomentSharingError.invalidPayload
            }
            result.append(0xFF)
            result.append(marker)
            result.append(UInt8((length >> 8) & 0xFF))
            result.append(UInt8(length & 0xFF))
            result.append(contentsOf: payload)
        }
        return result
    }

    private static func legacyNormalizedImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up || image.scale != 1 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func rgba(_ image: UIImage) throws -> (Int, Int, [UInt8]) {
        guard let source = image.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw DailySharingError.canonicalEncodingFailed }
        var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
        let rendered = bytes.withUnsafeMutableBytes {
            (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: source.width,
                height: source.height,
                bitsPerComponent: 8,
                bytesPerRow: source.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(
                source,
                in: CGRect(x: 0, y: 0, width: source.width, height: source.height)
            )
            return true
        }
        guard rendered else { throw DailySharingError.canonicalEncodingFailed }
        return (source.width, source.height, bytes)
    }

    private static func testNormalizerParity() throws {
        guard let source = generatedImage().cgImage else {
            throw DailySharingError.canonicalEncodingFailed
        }
        let orientations: [UIImage.Orientation] = [
            .up, .down, .left, .right,
            .upMirrored, .downMirrored, .leftMirrored, .rightMirrored
        ]
        for scale in [CGFloat(1), CGFloat(2), CGFloat(3)] {
            for orientation in orientations {
                let input = UIImage(cgImage: source, scale: scale, orientation: orientation)
                let expected = try rgba(legacyNormalizedImage(input))
                let actual = try rgba(WidgetSourceImageNormalizer.normalizedUIImage(input))
                guard expected.0 == actual.0, expected.1 == actual.1,
                      expected.2.count == actual.2.count
                else { throw DailySharingError.invalidLocalManifest }
                var maximumDifference = 0
                var totalDifference = 0
                for (lhs, rhs) in zip(expected.2, actual.2) {
                    let difference = abs(Int(lhs) - Int(rhs))
                    maximumDifference = max(maximumDifference, difference)
                    totalDifference += difference
                }
                let mean = Double(totalDifference) / Double(max(1, expected.2.count))
                guard maximumDifference <= 2, mean <= 0.5 else {
                    throw DailySharingError.invalidLocalManifest
                }
            }
        }
    }

    private static func testCanonicalPrivacyAndBudget() throws {
        try testSharingRectQuantization()
        guard !CanonicalPreviewBuilder.automaticNetworkAccessAllowed else {
            throw DailySharingError.localPhotoUnavailable
        }
        let image = generatedImage(size: CGSize(width: 1_200, height: 1_200))
        guard let source = image.cgImage else {
            throw DailySharingError.canonicalEncodingFailed
        }
        let sourceSize = WidgetSourcePixelSize(width: source.width, height: source.height)
        let plans = WidgetRenderPlanner.plans(
            visionBoundingBox: nil,
            sourcePixelSize: sourceSize
        )
        let preview = try CanonicalPreviewBuilder.runtimeSelfTestPreview(
            image: image,
            renderPlans: plans,
            diagnosticCase: .canonicalLocalOnlyPrivacyBudget
        )
        let plainHash = preview.plaintextSHA256.base64URLEncodedString()
        try CanonicalPreviewBuilder.validateReceivedJPEG(
            preview.jpeg,
            binding: preview.binding,
            expectedPlaintextSHA256: plainHash
        )
        let tamperedProfileJPEG = try CanonicalPreviewBuilder
            .runtimeSelfTestJPEGWithTamperedColorProfile(preview.jpeg)
        var rejectedTamperedProfile = false
        do {
            try CanonicalPreviewBuilder.validateReceivedJPEG(
                tamperedProfileJPEG,
                binding: preview.binding,
                expectedPlaintextSHA256: PairingCrypto.sha256(tamperedProfileJPEG)
                    .base64URLEncodedString()
            )
        } catch DailySharingError.invalidSharedManifest {
            rejectedTamperedProfile = true
        }
        guard rejectedTamperedProfile else {
            throw DailySharingError.invalidSharedManifest
        }
        let aad = try DailySharingCrypto.mediaAAD(
            spaceID: opaque(1),
            sourceID: opaque(2),
            publisherMemberID: opaque(3),
            generationID: opaque(4),
            shareDayKey: 20_682,
            mediaID: opaque(5),
            mediaBindingHash: try preview.binding.bindingHash()
        )
        let roomKey = Data(repeating: 0xA5, count: 32)
        let ciphertext = try DailySharingCrypto.sealMedia(
            preview.jpeg,
            roomKey: roomKey,
            aad: aad
        )
        guard ciphertext.count <= DailySharingProtocol.maximumMediaCiphertextBytes,
              try DailySharingCrypto.openMedia(
                ciphertext,
                roomKey: roomKey,
                aad: aad
              ) == preview.jpeg
        else { throw DailySharingError.canonicalEncodingFailed }
    }

    private static func testSharingRectQuantization() throws {
        let scale = DailySharingProtocol.coordinateScale
        let edge = SharingNormalizedRect(
            WidgetRenderRect(
                CGRect(x: 0.0546875, y: 0.03125, width: 0.9453125, height: 0.96875)
            )
        )
        guard edge.isValid,
              edge.x + edge.width == scale,
              edge.y + edge.height == scale
        else { throw DailySharingError.invalidSharedManifest }

        // Deterministic edge-clamped fuzz: every source rect reaches exactly
        // one or both unit-square edges and must survive fixed-point encoding
        // without independently-rounded origin/extent overflow.
        for index in 1...512 {
            let x = Double((index * 7_919) % 900_000) / Double(scale)
            let y = Double((index * 104_729) % 900_000) / Double(scale)
            let reachesRightEdge = index.isMultiple(of: 2)
            let reachesBottomEdge = index.isMultiple(of: 3)
            let width = reachesRightEdge ? 1 - x : max(0.000_01, (1 - x) * 0.731_257)
            let height = reachesBottomEdge ? 1 - y : max(0.000_01, (1 - y) * 0.619_873)
            let rect = SharingNormalizedRect(
                WidgetRenderRect(CGRect(x: x, y: y, width: width, height: height))
            )
            guard rect.isValid,
                  rect.x + rect.width <= scale,
                  rect.y + rect.height <= scale,
                  !reachesRightEdge || rect.x + rect.width == scale,
                  !reachesBottomEdge || rect.y + rect.height == scale
            else { throw DailySharingError.invalidSharedManifest }
        }
    }

    private static func testLegacyWidgetCacheMigration() throws {
        guard let root = SharedContainer.containerURL else {
            throw DailySharingError.stateUnavailable
        }
        let directory = root.appendingPathComponent(
            ".sharing-runtime-widget-v5-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let record = AssetRecord(
            localIdentifier: "runtime-v5-local-photo",
            creationDate: modificationDate,
            sourceModificationDate: modificationDate,
            sourceModificationDateWasCaptured: true,
            isFavorite: true,
            isScreenshot: false,
            burstIdentifier: nil,
            cat: CatDetection(
                detected: true,
                confidence: 0.99,
                boundingBox: nil,
                areaRatio: 0.5,
                catCount: 1
            ),
            analysisStatus: .detected,
            analysisFingerprint: "runtime-v5-analysis"
        )
        let oldFilenames = WidgetCacheFilenames(
            small: "asset-cat-aware-full-bleed-v5-small-runtime.jpg",
            medium: "asset-cat-aware-full-bleed-v5-medium-runtime.jpg",
            large: "asset-cat-aware-full-bleed-v5-large-runtime.jpg"
        )
        guard WidgetCacheBuilder.runtimeSelfTestCurrentCacheFilenames(for: record)
                != oldFilenames
        else { throw DailySharingError.stateUnavailable }
        let fileBytes = Dictionary(uniqueKeysWithValues: oldFilenames.all.enumerated().map {
            ($0.element, Data(repeating: UInt8(0x31 + $0.offset), count: 128))
        })
        for (filename, data) in fileBytes {
            try SharingSecureFile.write(
                data,
                to: directory.appendingPathComponent(filename, isDirectory: false)
            )
        }
        let manifest = WidgetManifest(
            items: [WidgetManifestItem(
                localIdentifier: record.localIdentifier,
                cacheFilename: oldFilenames.small,
                cacheFilenames: oldFilenames,
                scheduledDate: modificationDate,
                rendererVersion: "cat-aware-full-bleed-v5",
                sourcePixelSize: nil,
                renderPlans: nil,
                sourceModificationDate: modificationDate
            )],
            generatedAt: modificationDate
        )
        let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
        try AtomicJSON.write(manifest, to: manifestURL)
        let originalManifestBytes = try Data(contentsOf: manifestURL)

        // A missing family and a known modification mismatch must not qualify.
        let missingURL = directory.appendingPathComponent(oldFilenames.medium, isDirectory: false)
        try FileManager.default.removeItem(at: missingURL)
        guard WidgetCacheBuilder.runtimeSelfTestRetainedActiveManifestIfPhotoUnavailable(
            manifest,
            record: record,
            cacheDirectory: directory
        ) == nil else { throw DailySharingError.stateUnavailable }
        guard let restoredMedium = fileBytes[oldFilenames.medium] else {
            throw DailySharingError.stateUnavailable
        }
        try SharingSecureFile.write(restoredMedium, to: missingURL)
        var editedRecord = record
        editedRecord.sourceModificationDate = modificationDate.addingTimeInterval(1)
        guard WidgetCacheBuilder.runtimeSelfTestRetainedActiveManifestIfPhotoUnavailable(
            manifest,
            record: editedRecord,
            cacheDirectory: directory
        ) == nil else { throw DailySharingError.stateUnavailable }

        let familyFilesAreUnchanged = try oldFilenames.all.allSatisfy { filename in
            guard let expected = fileBytes[filename] else { return false }
            return try Data(contentsOf: directory.appendingPathComponent(filename)) == expected
        }
        guard let retained = WidgetCacheBuilder
            .runtimeSelfTestRetainedActiveManifestIfPhotoUnavailable(
                manifest,
                record: record,
                cacheDirectory: directory
            ),
              retained.manifest == manifest,
              retained.selectedIdentifiers == [record.localIdentifier],
              try Data(contentsOf: manifestURL) == originalManifestBytes,
              familyFilesAreUnchanged
        else { throw DailySharingError.stateUnavailable }

        do {
            _ = try DailyManifestFreezer.freeze(
                retained.manifest,
                localDayKey: 20_682,
                now: modificationDate
            )
            throw DailySharingError.stateUnavailable
        } catch DailySharingError.invalidLocalManifest {
            // Personal v5 bytes remain active; sharing keeps its prior day.
        }
    }

    private static func testDayBoundaryConvergence() throws {
        let boundaryMinute = 240
        let boundary = 20_000 * 86_400 + boundaryMinute * 60
        let before = Date(timeIntervalSince1970: TimeInterval(boundary - 1))
        let after = Date(timeIntervalSince1970: TimeInterval(boundary + 1))
        guard DailySharingSyncCoordinator.dayKey(
            now: before,
            boundaryMinuteUTC: boundaryMinute
        ) == 19_999,
        DailySharingSyncCoordinator.dayKey(
            now: after,
            boundaryMinuteUTC: boundaryMinute
        ) == 20_000,
        DailySharingSyncCoordinator.secondsUntilNextBoundary(
            now: before,
            boundaryMinuteUTC: boundaryMinute
        ) == 1,
        DailySharingSyncCoordinator.secondsSinceBoundary(
            now: after,
            boundaryMinuteUTC: boundaryMinute
        ) == 1,
        DailySharingSyncCoordinator.clockSkewRetryDate(
            now: after,
            boundaryMinuteUTC: boundaryMinute
        ).timeIntervalSince1970 >= TimeInterval(boundary + 360)
        else { throw DailySharingError.stateUnavailable }
    }

    private static func makeStoreFixture() throws -> StoreFixture {
        let initial = try PairingInstallationGuard.bootstrap()
        guard initial.state.phase == .unpaired else {
            throw PairingError.stateUnavailable
        }
        // The DEBUG launch is intentionally repeatable on the same simulator.
        // Remove only sharing state/ciphertext left by an interrupted earlier
        // self-test; the normal personal Widget evidence is outside this tree.
        _ = try PairingInstallationGuard.resetLocalSharing(
            expectedState: initial.state,
            lifecycleToken: initial.lifecycleToken,
            message: nil
        )
        let bootstrap = try PairingInstallationGuard.bootstrap()
        guard bootstrap.state.phase == .unpaired else {
            throw PairingError.stateUnavailable
        }
        let spaceID = opaque(11)
        let memberID = opaque(12)
        let peerMemberID = opaque(13)
        let ownSourceID = opaque(14)
        let acquisition = try DailySharingStateStore.acquireSyncLease(
            spaceID: spaceID,
            memberID: memberID,
            lifecycleToken: bootstrap.lifecycleToken
        )
        guard case .acquired(let lease) = acquisition else {
            throw DailySharingError.stateChanged
        }
        var state = try DailySharingStateStore.load(
            spaceID: spaceID,
            memberID: memberID,
            lease: lease
        )
        guard state.storageRevision == 0 else {
            lease.release()
            throw DailySharingError.stateChanged
        }
        state.ownSourceID = ownSourceID
        state = try DailySharingStateStore.save(
            state,
            expectedStorageRevision: state.storageRevision,
            lease: lease
        )
        guard case .busy(let retryAt) = try DailySharingStateStore.acquireSyncLease(
            spaceID: spaceID,
            memberID: memberID,
            lifecycleToken: bootstrap.lifecycleToken
        ), retryAt > .now else {
            lease.release()
            throw DailySharingError.stateChanged
        }
        try lease.renew()
        guard case .busy(let renewedRetryAt) = try DailySharingStateStore.acquireSyncLease(
            spaceID: spaceID,
            memberID: memberID,
            lifecycleToken: bootstrap.lifecycleToken
        ), renewedRetryAt > .now else {
            lease.release()
            throw DailySharingError.stateChanged
        }
        return StoreFixture(
            lifecycleToken: bootstrap.lifecycleToken,
            installationMarker: bootstrap.state.installationMarker,
            spaceID: spaceID,
            memberID: memberID,
            peerMemberID: peerMemberID,
            ownSourceID: ownSourceID,
            ownGenerationID: opaque(15),
            ownAttemptID: opaque(16),
            ownMediaID: opaque(17),
            lease: lease,
            state: state,
            leaseChecksPassed: true
        )
    }

    private static func testStoreCASHighWaterAndAnchor(
        _ fixture: inout StoreFixture
    ) throws {
        let stale = fixture.state
        fixture.state.lastSyncAt = .now
        fixture.state = try DailySharingStateStore.save(
            fixture.state,
            expectedStorageRevision: fixture.state.storageRevision,
            lease: fixture.lease
        )
        do {
            _ = try DailySharingStateStore.save(
                stale,
                expectedStorageRevision: stale.storageRevision,
                lease: fixture.lease
            )
            throw DailySharingError.stateUnavailable
        } catch DailySharingError.stateChanged {
            // Expected CAS loser.
        }
        let eTag = "\"nw1-(fixture.ownSourceID)-1\""
        try URLSessionDailySharingAPIClient.runtimeSelfTestValidateNotModified(
            requestETag: eTag,
            responseETag: eTag
        )
        var rejectedMissingRequestTag = false
        do {
            try URLSessionDailySharingAPIClient.runtimeSelfTestValidateNotModified(
                requestETag: nil,
                responseETag: eTag
            )
        } catch PairingError.invalidServerResponse {
            rejectedMissingRequestTag = true
        }
        guard rejectedMissingRequestTag else {
            throw PairingError.invalidServerResponse
        }
        var rejectedMismatchedResponseTag = false
        do {
            try URLSessionDailySharingAPIClient.runtimeSelfTestValidateNotModified(
                requestETag: eTag,
                responseETag: "\"nw1-(fixture.ownSourceID)-2\""
            )
        } catch PairingError.invalidServerResponse {
            rejectedMismatchedResponseTag = true
        }
        guard rejectedMismatchedResponseTag else {
            throw PairingError.invalidServerResponse
        }
    }

    private static func testOwnSourcePromotion(
        _ fixture: inout StoreFixture
    ) async throws {
        let nowUnix = Int(Date().timeIntervalSince1970)
        // Keep the generated anchor comfortably in the future so a slow CI
        // image encode cannot accidentally activate it during this case.
        let anchor = ((nowUnix / 1_200) + 2) * 1_200
        let image = generatedImage(size: CGSize(width: 1_200, height: 1_200))
        guard let source = image.cgImage else {
            throw DailySharingError.canonicalEncodingFailed
        }
        let sourceSize = WidgetSourcePixelSize(width: source.width, height: source.height)
        let plans = WidgetRenderPlanner.plans(
            visionBoundingBox: nil,
            sourcePixelSize: sourceSize
        )
        let preview = try CanonicalPreviewBuilder.runtimeSelfTestPreview(
            image: image,
            renderPlans: plans,
            diagnosticCase: .ownSourceLocalPromotion
        )
        let roomKey = Data(repeating: 0xB6, count: 32)
        let mediaAAD = try DailySharingCrypto.mediaAAD(
            spaceID: fixture.spaceID,
            sourceID: fixture.ownSourceID,
            publisherMemberID: fixture.memberID,
            generationID: fixture.ownGenerationID,
            shareDayKey: 20_682,
            mediaID: fixture.ownMediaID,
            mediaBindingHash: try preview.binding.bindingHash()
        )
        let mediaCiphertext = try DailySharingCrypto.sealMedia(
            preview.jpeg,
            roomKey: roomKey,
            aad: mediaAAD
        )
        let mediaHash = PairingCrypto.sha256(mediaCiphertext).base64URLEncodedString()
        let plainHash = preview.plaintextSHA256.base64URLEncodedString()
        let sharedManifest = try DailySharedManifest(
            media: [DailySharedManifestMedia(
                mediaID: fixture.ownMediaID,
                binding: preview.binding,
                ciphertextSize: mediaCiphertext.count,
                ciphertextSHA256: mediaHash,
                canonicalJPEGPlaintextSHA256: plainHash
            )],
            slots: [fixture.ownMediaID]
        ).encoded()
        let manifestAAD = try DailySharingCrypto.manifestAAD(
            spaceID: fixture.spaceID,
            sourceID: fixture.ownSourceID,
            publisherMemberID: fixture.memberID,
            generationID: fixture.ownGenerationID,
            shareDayKey: 20_682,
            prepareAttemptID: fixture.ownAttemptID,
            prepareAttemptRevision: 1,
            reservedRevision: 1,
            rotationAnchorUTC: anchor,
            itemCount: 1
        )
        let manifestCiphertext = try DailySharingCrypto.sealManifest(
            sharedManifest,
            roomKey: roomKey,
            aad: manifestAAD
        )
        let mediaFilename = "runtime-own-media.enc"
        let manifestFilename = "runtime-own-manifest.enc"
        try DailySharingStateStore.writeOutboundCiphertext(
            mediaCiphertext,
            filename: mediaFilename,
            lease: fixture.lease
        )
        try DailySharingStateStore.writeOutboundCiphertext(
            manifestCiphertext,
            filename: manifestFilename,
            lease: fixture.lease
        )
        let prepare = PreparedSharingAttempt(
            clientRequestID: UUID().uuidString.lowercased(),
            attemptID: fixture.ownAttemptID,
            attemptRevision: 1,
            reservedRevision: 1,
            rotationAnchorUTC: anchor,
            prepareExpiresAt: anchor,
            manifestCiphertextFilename: manifestFilename,
            manifestCiphertextSize: manifestCiphertext.count,
            manifestCiphertextSHA256: PairingCrypto.sha256(manifestCiphertext)
                .base64URLEncodedString(),
            commitClientRequestID: UUID().uuidString.lowercased()
        )
        let outbound = try OutboundSharingGeneration(
            phase: .committing,
            localDayKey: 20_682,
            frozenAt: .now,
            sourceManifestGeneratedAt: .now,
            reserveClientRequestID: UUID().uuidString.lowercased(),
            slotMediaIDs: [fixture.ownMediaID],
            media: [StagedSharingMedia(
                frozen: FrozenSharingMedia(
                    mediaID: fixture.ownMediaID,
                    localIdentifier: "generated-runtime-image",
                    sourceModificationDate: nil,
                    sourcePixelSize: sourceSize,
                    renderPlans: plans
                ),
                binding: preview.binding,
                canonicalJPEGPlaintextSHA256: plainHash,
                ciphertextFilename: mediaFilename,
                ciphertextSize: mediaCiphertext.count,
                ciphertextSHA256: mediaHash,
                uploadVerified: true
            )],
            sourceID: fixture.ownSourceID,
            generationID: fixture.ownGenerationID,
            serverShareDayKey: 20_682,
            draftExpiresAt: nowUnix + 3_600,
            descriptorClientRequestID: UUID().uuidString.lowercased(),
            pendingPrepareClientRequestID: nil,
            prepare: prepare
        ).validated()
        let current = SharingCurrentGeneration(
            sourceID: fixture.ownSourceID,
            publisherMemberID: fixture.memberID,
            generationID: fixture.ownGenerationID,
            shareDayKey: 20_682,
            revision: 1,
            attemptID: fixture.ownAttemptID,
            attemptRevision: 1,
            reservedRevision: 1,
            rotationAnchorUTC: anchor,
            uniqueMediaCount: 1,
            manifest: .init(
                ciphertextSize: manifestCiphertext.count,
                ciphertextSHA256: PairingCrypto.sha256(manifestCiphertext)
                    .base64URLEncodedString()
            ),
            media: [.init(
                mediaID: fixture.ownMediaID,
                ciphertextSize: mediaCiphertext.count,
                ciphertextSHA256: mediaHash
            )]
        )
        fixture.state.outbound = outbound
        fixture.state = try DailySharingStateStore.save(
            fixture.state,
            expectedStorageRevision: fixture.state.storageRevision,
            lease: fixture.lease
        )
        // Force the actual production local-first helper through its same-pass
        // server fallback after it has already staged the local manifest.
        try DailySharingStateStore.removeOutboundCiphertext(
            filename: mediaFilename,
            lease: fixture.lease
        )
        var credential = PairingCrypto.makeCredential(
            installationMarker: fixture.installationMarker,
            includesInvitationSecret: false,
            includesRoomKey: true
        )
        credential.roomKey = roomKey
        let api = RuntimeSharingAPI(
            manifest: manifestCiphertext,
            mediaByID: [fixture.ownMediaID: mediaCiphertext]
        )
        let coordinator = DailySharingSyncCoordinator(
            configuration: .current,
            api: api
        )
        try await coordinator.runtimeSelfTestPromoteOwnCommittedGeneration(
            current,
            outbound: outbound,
            state: &fixture.state,
            spaceID: fixture.spaceID,
            memberID: fixture.memberID,
            roomKey: roomKey,
            credential: credential,
            api: api,
            lease: fixture.lease
        )
        let downloadCounts = await api.runtimeDownloadCounts()
        guard downloadCounts.manifest == 0,
              downloadCounts.media == 1,
              fixture.state.inboundPendingBySource[fixture.ownSourceID] != nil,
              fixture.state.inboundActiveBySource[fixture.ownSourceID] == nil,
              fixture.state.inboundHighWaterBySource[fixture.ownSourceID]?.accepts(
                publisherMemberID: fixture.memberID,
                shareDayKey: 20_682,
                revision: 1,
                generationID: fixture.ownGenerationID,
                prepareAttemptID: fixture.ownAttemptID,
                prepareAttemptRevision: 1,
                reservedRevision: 1,
                rotationAnchorUTC: anchor,
                uniqueMediaCount: 1,
                manifestCiphertextSize: manifestCiphertext.count,
                manifestHash: PairingCrypto.sha256(manifestCiphertext)
                    .base64URLEncodedString()
              ) == true,
              fixture.state.inboundHighWaterBySource[fixture.ownSourceID]?.accepts(
                publisherMemberID: fixture.memberID,
                shareDayKey: 20_682,
                revision: 1,
                generationID: fixture.ownGenerationID,
                prepareAttemptID: fixture.ownAttemptID,
                prepareAttemptRevision: 1,
                reservedRevision: 1,
                rotationAnchorUTC: anchor,
                uniqueMediaCount: 1,
                manifestCiphertextSize: manifestCiphertext.count,
                manifestHash: Data(repeating: 0x00, count: 32)
                    .base64URLEncodedString()
              ) == false
        else { throw DailySharingError.stateUnavailable }
        fixture.state = try DailySharingStateStore.activateDueInbound(
            expectedState: fixture.state,
            lease: fixture.lease,
            now: Date(timeIntervalSince1970: TimeInterval(anchor - 1))
        )
        guard fixture.state.inboundActiveBySource[fixture.ownSourceID] == nil else {
            throw DailySharingError.stateUnavailable
        }
        fixture.state = try DailySharingStateStore.activateDueInbound(
            expectedState: fixture.state,
            lease: fixture.lease,
            now: Date(timeIntervalSince1970: TimeInterval(anchor + 1))
        )
        guard fixture.state.inboundActiveBySource[fixture.ownSourceID] != nil else {
            throw DailySharingError.stateUnavailable
        }
        guard let highWater = fixture.state.inboundHighWaterBySource[fixture.ownSourceID],
              let inboundRoot = SharedContainer.sharingInboundDirectoryURL
        else { throw DailySharingError.stateUnavailable }
        let exactSummary = SharingSourceSummary.Current(
            generationID: current.generationID,
            shareDayKey: current.shareDayKey,
            revision: current.revision,
            rotationAnchorUTC: current.rotationAnchorUTC,
            uniqueMediaCount: current.uniqueMediaCount
        )
        let changedAnchorSummary = SharingSourceSummary.Current(
            generationID: current.generationID,
            shareDayKey: current.shareDayKey,
            revision: current.revision,
            rotationAnchorUTC: current.rotationAnchorUTC + 1_200,
            uniqueMediaCount: current.uniqueMediaCount
        )
        let changedCountSummary = SharingSourceSummary.Current(
            generationID: current.generationID,
            shareDayKey: current.shareDayKey,
            revision: current.revision,
            rotationAnchorUTC: current.rotationAnchorUTC,
            uniqueMediaCount: current.uniqueMediaCount + 1
        )
        guard DailySharingSyncCoordinator.runtimeSelfTestHighWaterMatchesSummary(
            highWater,
            sourceID: current.sourceID,
            publisherMemberID: current.publisherMemberID,
            summary: exactSummary
        ), !DailySharingSyncCoordinator.runtimeSelfTestHighWaterMatchesSummary(
            highWater,
            sourceID: current.sourceID,
            publisherMemberID: current.publisherMemberID,
            summary: changedAnchorSummary
        ), !DailySharingSyncCoordinator.runtimeSelfTestHighWaterMatchesSummary(
            highWater,
            sourceID: current.sourceID,
            publisherMemberID: current.publisherMemberID,
            summary: changedCountSummary
        ) else { throw PairingError.invalidServerResponse }

        let monotonicBase = currentVariant(
            current,
            generationID: opaque(61),
            shareDayKey: 20_690,
            revision: 10
        )
        let exactWasNewer = try DailySharingSyncCoordinator
            .runtimeSelfTestCurrentReplacementIsStrictlyNewer(
                original: monotonicBase,
                replacement: monotonicBase
            )
        guard !exactWasNewer else { throw PairingError.invalidServerResponse }
        let monotonicNewer = currentVariant(
            monotonicBase,
            generationID: opaque(62),
            shareDayKey: 20_691,
            revision: 11,
            rotationAnchorUTC: monotonicBase.rotationAnchorUTC + 1_200
        )
        let newerWasAccepted = try DailySharingSyncCoordinator
            .runtimeSelfTestCurrentReplacementIsStrictlyNewer(
                original: monotonicBase,
                replacement: monotonicNewer
            )
        guard newerWasAccepted else { throw PairingError.invalidServerResponse }
        let rollback = currentVariant(
            monotonicBase,
            generationID: opaque(63),
            shareDayKey: 20_689,
            revision: 9
        )
        var rejectedRollback = false
        do {
            _ = try DailySharingSyncCoordinator
                .runtimeSelfTestCurrentReplacementIsStrictlyNewer(
                    original: monotonicBase,
                    replacement: rollback
                )
        } catch PairingError.invalidServerResponse {
            rejectedRollback = true
        }
        guard rejectedRollback else {
            throw PairingError.invalidServerResponse
        }
        let equivocated = currentVariant(
            monotonicBase,
            manifestHash: Data(repeating: 0xD1, count: 32).base64URLEncodedString()
        )
        var rejectedEquivocation = false
        do {
            _ = try DailySharingSyncCoordinator
                .runtimeSelfTestCurrentReplacementIsStrictlyNewer(
                    original: monotonicBase,
                    replacement: equivocated
                )
        } catch PairingError.invalidServerResponse {
            rejectedEquivocation = true
        }
        guard rejectedEquivocation else {
            throw PairingError.invalidServerResponse
        }
        let verifiedMediaURL = inboundRoot
            .appendingPathComponent(highWater.verifiedDirectoryName, isDirectory: true)
            .appendingPathComponent("\(fixture.ownMediaID).enc", isDirectory: false)
        try Data(repeating: 0xEE, count: mediaCiphertext.count)
            .write(to: verifiedMediaURL, options: .atomic)
        guard try await coordinator.runtimeSelfTestVerifiedInboundGenerationIsIntact(
            highWater,
            spaceID: fixture.spaceID,
            roomKey: roomKey,
            lease: fixture.lease
        ) == false else { throw DailySharingError.invalidCiphertext }
        try SharingSecureFile.write(mediaCiphertext, to: verifiedMediaURL)
        guard try await coordinator.runtimeSelfTestVerifiedInboundGenerationIsIntact(
            highWater,
            spaceID: fixture.spaceID,
            roomKey: roomKey,
            lease: fixture.lease
        ) else { throw DailySharingError.invalidCiphertext }
        fixture.state.outbound = nil
        fixture.state = try DailySharingStateStore.save(
            fixture.state,
            expectedStorageRevision: fixture.state.storageRevision,
            lease: fixture.lease
        )
        try? DailySharingStateStore.removeOutboundCiphertexts(
            for: fixture.ownGenerationID,
            lease: fixture.lease
        )
    }

    private static func testPartialDownloadAndTamper(
        _ fixture: inout StoreFixture
    ) throws {
        let sourceID = opaque(21)
        let generationID = opaque(22)
        let attemptID = opaque(23)
        let mediaID = opaque(24)
        let manifest = Data(repeating: 0x53, count: 29)
        let media = Data(repeating: 0x64, count: 29)
        let anchor = ((Int(Date().timeIntervalSince1970) / 1_200) + 2) * 1_200
        let draft = InboundDownloadDraft(
            sourceID: sourceID,
            publisherMemberID: fixture.peerMemberID,
            shareDayKey: 20_682,
            revision: 1,
            generationID: generationID,
            prepareAttemptID: attemptID,
            prepareAttemptRevision: 1,
            reservedRevision: 1,
            rotationAnchorUTC: anchor,
            uniqueMediaCount: 1,
            manifestCiphertextSize: manifest.count,
            manifestCiphertextSHA256: PairingCrypto.sha256(manifest)
                .base64URLEncodedString(),
            media: [InboundDownloadMedia(
                mediaID: mediaID,
                ciphertextSize: media.count,
                ciphertextSHA256: PairingCrypto.sha256(media).base64URLEncodedString()
            )],
            stagingDirectoryName: ".download-\(sourceID)-\(generationID)",
            manifestVerified: false,
            completedMediaIDs: [],
            startedAt: .now
        )
        fixture.state = try DailySharingStateStore.beginInboundDownload(
            expectedState: fixture.state,
            candidate: draft,
            lease: fixture.lease
        )
        fixture.state = try DailySharingStateStore.stageVerifiedInboundManifest(
            manifest,
            expectedState: fixture.state,
            sourceID: sourceID,
            lease: fixture.lease
        )
        fixture.state = try DailySharingStateStore.stageVerifiedInboundMedia(
            media,
            mediaID: mediaID,
            expectedState: fixture.state,
            sourceID: sourceID,
            lease: fixture.lease
        )
        guard let persisted = fixture.state.inboundDownloadBySource[sourceID],
              try DailySharingStateStore.readInboundDraftMedia(
                persisted,
                media: persisted.media[0],
                lease: fixture.lease
              ) == media,
              let root = SharedContainer.sharingInboundDirectoryURL
        else { throw DailySharingError.stateUnavailable }
        let mediaURL = root
            .appendingPathComponent(persisted.stagingDirectoryName, isDirectory: true)
            .appendingPathComponent("\(mediaID).enc", isDirectory: false)
        try Data(repeating: 0xFF, count: media.count).write(to: mediaURL, options: .atomic)
        guard try DailySharingStateStore.readInboundDraftMedia(
            persisted,
            media: persisted.media[0],
            lease: fixture.lease
        ) == nil else { throw DailySharingError.invalidCiphertext }
        fixture.state = try DailySharingStateStore.stageVerifiedInboundMedia(
            media,
            mediaID: mediaID,
            expectedState: fixture.state,
            sourceID: sourceID,
            lease: fixture.lease
        )
        guard let repaired = fixture.state.inboundDownloadBySource[sourceID],
              try DailySharingStateStore.readInboundDraftMedia(
                repaired,
                media: persisted.media[0],
                lease: fixture.lease
              ) == media
        else { throw DailySharingError.stateUnavailable }
        fixture.state = try DailySharingStateStore.finalizeInboundDownload(
            expectedState: fixture.state,
            sourceID: sourceID,
            lease: fixture.lease,
            now: Date(timeIntervalSince1970: TimeInterval(anchor - 1))
        )
        guard fixture.state.inboundDownloadBySource[sourceID] == nil,
              fixture.state.inboundPendingBySource[sourceID] != nil,
              fixture.state.inboundHighWaterBySource[sourceID] != nil,
              fixture.state.inboundActiveBySource[sourceID] == nil
        else { throw DailySharingError.stateUnavailable }
    }

    private static func testIndependentRetryState(
        _ fixture: inout StoreFixture
    ) async throws {
        let nowUnix = Int(Date().timeIntervalSince1970)
        let sourceSize = WidgetSourcePixelSize(width: 1_200, height: 1_200)
        let plans = WidgetRenderPlanner.plans(
            visionBoundingBox: nil,
            sourcePixelSize: sourceSize
        )
        let binding = SharingMediaBinding(
            canonicalPixelSize: sourceSize,
            renderPlans: plans
        )
        let mediaID = opaque(31)
        let ciphertextSize = 29
        let ciphertextHash = Data(repeating: 0x82, count: 32)
            .base64URLEncodedString()
        let plaintextHash = Data(repeating: 0x83, count: 32)
            .base64URLEncodedString()
        let media = StagedSharingMedia(
            frozen: FrozenSharingMedia(
                mediaID: mediaID,
                localIdentifier: "runtime-deadline-photo",
                sourceModificationDate: nil,
                sourcePixelSize: sourceSize,
                renderPlans: plans
            ),
            binding: binding,
            canonicalJPEGPlaintextSHA256: plaintextHash,
            ciphertextFilename: "runtime-deadline-media.enc",
            ciphertextSize: ciphertextSize,
            ciphertextSHA256: ciphertextHash,
            uploadVerified: true
        )
        let preparedGenerationID = opaque(32)
        let preparedAttemptID = opaque(33)
        let expiredAnchor = ((nowUnix / 1_200) - 1) * 1_200
        let liveDraftExpiry = nowUnix + 1_800
        let prepared = PreparedSharingAttempt(
            clientRequestID: UUID().uuidString.lowercased(),
            attemptID: preparedAttemptID,
            attemptRevision: 1,
            reservedRevision: 1,
            rotationAnchorUTC: expiredAnchor,
            prepareExpiresAt: expiredAnchor
        )
        let preparedOutbound = try OutboundSharingGeneration(
            phase: .prepared,
            localDayKey: 20_682,
            frozenAt: .now,
            sourceManifestGeneratedAt: .now,
            reserveClientRequestID: UUID().uuidString.lowercased(),
            slotMediaIDs: [mediaID],
            media: [media],
            sourceID: fixture.ownSourceID,
            generationID: preparedGenerationID,
            serverShareDayKey: 20_682,
            draftExpiresAt: liveDraftExpiry,
            descriptorClientRequestID: UUID().uuidString.lowercased(),
            pendingPrepareClientRequestID: nil,
            prepare: prepared
        ).validated()
        let expiredGenerationID = opaque(34)
        let expiredDraft = try OutboundSharingGeneration(
            phase: .mediaUploaded,
            localDayKey: 20_683,
            frozenAt: .now,
            sourceManifestGeneratedAt: .now,
            reserveClientRequestID: UUID().uuidString.lowercased(),
            slotMediaIDs: [mediaID],
            media: [media],
            sourceID: fixture.ownSourceID,
            generationID: expiredGenerationID,
            serverShareDayKey: 20_683,
            draftExpiresAt: nowUnix - 1,
            descriptorClientRequestID: UUID().uuidString.lowercased()
        ).validated()
        let api = RuntimeSharingAPI(generationByID: [
            preparedGenerationID: SharingGenerationResume(
                sourceID: fixture.ownSourceID,
                publisherMemberID: fixture.memberID,
                generationID: preparedGenerationID,
                state: "prepared",
                shareDayKey: 20_682,
                itemCount: 1,
                createdAt: nowUnix - 60,
                expiresAt: liveDraftExpiry,
                attemptID: preparedAttemptID,
                attemptRevision: 1,
                reservedRevision: 1,
                rotationAnchorUTC: expiredAnchor,
                prepareExpiresAt: expiredAnchor,
                manifest: nil,
                media: [.init(
                    mediaID: mediaID,
                    ciphertextSize: ciphertextSize,
                    ciphertextSHA256: ciphertextHash,
                    state: "verified"
                )]
            ),
            expiredGenerationID: SharingGenerationResume(
                sourceID: fixture.ownSourceID,
                publisherMemberID: fixture.memberID,
                generationID: expiredGenerationID,
                state: "uploading",
                shareDayKey: 20_683,
                itemCount: 1,
                createdAt: nowUnix - 3_600,
                expiresAt: nowUnix - 1,
                attemptID: nil,
                attemptRevision: nil,
                reservedRevision: nil,
                rotationAnchorUTC: nil,
                prepareExpiresAt: nil,
                manifest: nil,
                media: [.init(
                    mediaID: mediaID,
                    ciphertextSize: ciphertextSize,
                    ciphertextSHA256: ciphertextHash,
                    state: "verified"
                )]
            )
        ])
        var credential = PairingCrypto.makeCredential(
            installationMarker: fixture.installationMarker,
            includesInvitationSecret: false,
            includesRoomKey: true
        )
        let roomKey = Data(repeating: 0x84, count: 32)
        credential.roomKey = roomKey
        let inboundRetry = DailySharingRetrySchedule(
            attemptCount: 4,
            nextRetryAt: Date().addingTimeInterval(900)
        )
        fixture.state.inboundRetry = inboundRetry
        fixture.state.outbound = preparedOutbound
        fixture.state.outboundRetry = nil
        fixture.state.outboundRetryIntent = nil
        fixture.state.outboundReconcileReason = nil
        fixture.state = try DailySharingStateStore.save(
            fixture.state,
            expectedStorageRevision: fixture.state.storageRevision,
            lease: fixture.lease
        )
        let coordinator = DailySharingSyncCoordinator(configuration: .current, api: api)
        try await coordinator.runtimeSelfTestDriveOutboundDeadlineReconciliation(
            expectedReason: .prepareDeadline,
            state: &fixture.state,
            spaceID: fixture.spaceID,
            memberID: fixture.memberID,
            roomKey: roomKey,
            credential: credential,
            api: api,
            lease: fixture.lease
        )
        guard fixture.state.outbound?.phase == .mediaUploaded,
              fixture.state.outbound?.prepare == nil,
              fixture.state.outbound?.pendingPrepareClientRequestID != nil,
              fixture.state.outboundRetryIntent == .mutation,
              fixture.state.outboundReconcileReason == nil,
              fixture.state.inboundRetry == inboundRetry
        else { throw DailySharingError.stateUnavailable }

        fixture.state.outbound = expiredDraft
        fixture.state.outboundRetry = nil
        fixture.state.outboundRetryIntent = nil
        fixture.state.outboundReconcileReason = nil
        fixture.state = try DailySharingStateStore.save(
            fixture.state,
            expectedStorageRevision: fixture.state.storageRevision,
            lease: fixture.lease
        )
        try await coordinator.runtimeSelfTestDriveOutboundDeadlineReconciliation(
            expectedReason: .draftDeadline,
            state: &fixture.state,
            spaceID: fixture.spaceID,
            memberID: fixture.memberID,
            roomKey: roomKey,
            credential: credential,
            api: api,
            lease: fixture.lease
        )
        guard fixture.state.outbound == nil,
              fixture.state.lastCompletedLocalDayKey == expiredDraft.localDayKey,
              fixture.state.outboundRetry == nil,
              fixture.state.inboundRetry == inboundRetry
        else { throw DailySharingError.stateUnavailable }

        // Three handled passes must not replace a persisted Retry-After or its
        // reconciliation reason with an eager 30-second mutation retry.
        let preservedRetry = DailySharingRetrySchedule(
            attemptCount: 7,
            nextRetryAt: Date().addingTimeInterval(7_200)
        )
        fixture.state.outbound = preparedOutbound
        fixture.state.outboundRetry = preservedRetry
        fixture.state.outboundRetryIntent = .reconcileOnly
        fixture.state.outboundReconcileReason = .prepareDeadline
        fixture.state = try DailySharingStateStore.save(
            fixture.state,
            expectedStorageRevision: fixture.state.storageRevision,
            lease: fixture.lease
        )
        for _ in 0..<3 {
            try await coordinator.runtimeSelfTestPersistContinuationAfterPassLimit(
                state: &fixture.state,
                lease: fixture.lease
            )
        }
        guard fixture.state.outboundRetry == preservedRetry,
              fixture.state.outboundRetryIntent == .reconcileOnly,
              fixture.state.outboundReconcileReason == .prepareDeadline,
              fixture.state.inboundRetry == inboundRetry
        else { throw DailySharingError.stateUnavailable }

        // Simulate: reserve commits, the response is lost before local save,
        // the app is killed, and the exact request is recovered after the next
        // boundary plus the six-minute skew window.
        let boundaryMinuteUTC = 0
        let attemptedDay = 30_000
        let attemptDate = Date(
            timeIntervalSince1970: TimeInterval((attemptedDay + 1) * 86_400 - 60)
        )
        let recoveryDate = Date(
            timeIntervalSince1970: TimeInterval((attemptedDay + 1) * 86_400 + 600)
        )
        let stableReserveRequestID = UUID().uuidString.lowercased()
        let frozenForReserve = try OutboundSharingGeneration(
            phase: .frozen,
            localDayKey: attemptedDay,
            frozenAt: attemptDate,
            sourceManifestGeneratedAt: attemptDate,
            reserveClientRequestID: stableReserveRequestID,
            slotMediaIDs: [mediaID],
            media: [StagedSharingMedia(frozen: media.frozen)]
        ).validated()
        fixture.state.outbound = frozenForReserve
        fixture.state.outboundRetry = nil
        fixture.state.outboundRetryIntent = nil
        fixture.state.outboundReconcileReason = nil
        fixture.state = try DailySharingStateStore.save(
            fixture.state,
            expectedStorageRevision: fixture.state.storageRevision,
            lease: fixture.lease
        )
        let recoveredGenerationID = opaque(35)
        let reserveResult = SharingReserveResult(
            sourceID: fixture.ownSourceID,
            publisherMemberID: fixture.memberID,
            generationID: recoveredGenerationID,
            shareDayKey: attemptedDay + 1,
            createdAt: Int(recoveryDate.timeIntervalSince1970),
            expiresAt: Int(recoveryDate.timeIntervalSince1970) + 3_600,
            mediaIDs: [mediaID]
        )
        let reserveAPI = RuntimeSharingAPI(reserveSteps: [
            .responseLost(reserveResult),
            .success(reserveResult)
        ])
        let reserveCoordinator = DailySharingSyncCoordinator(
            configuration: .current,
            api: reserveAPI
        )
        do {
            _ = try await reserveCoordinator.runtimeSelfTestReserveFrozenGeneration(
                state: &fixture.state,
                boundaryMinuteUTC: boundaryMinuteUTC,
                now: attemptDate,
                memberID: fixture.memberID,
                credential: credential,
                api: reserveAPI,
                lease: fixture.lease
            )
            throw DailySharingError.stateUnavailable
        } catch let error as URLError where error.code == .networkConnectionLost {
            // Server-side success with a lost response leaves the marker live.
        }
        fixture.state = try DailySharingStateStore.load(
            spaceID: fixture.spaceID,
            memberID: fixture.memberID,
            lease: fixture.lease
        )
        guard fixture.state.outbound?.reserveAttemptedAt == attemptDate,
              fixture.state.outbound?.reserveClientRequestID == stableReserveRequestID
        else { throw DailySharingError.stateUnavailable }
        try await reserveCoordinator.runtimeSelfTestDiscardStaleUnsentFrozen(
            state: &fixture.state,
            currentLocalDayKey: attemptedDay + 1,
            lease: fixture.lease
        )
        guard fixture.state.outbound?.reserveClientRequestID == stableReserveRequestID else {
            throw DailySharingError.stateUnavailable
        }
        guard try await reserveCoordinator.runtimeSelfTestReserveFrozenGeneration(
            state: &fixture.state,
            boundaryMinuteUTC: boundaryMinuteUTC,
            now: recoveryDate,
            memberID: fixture.memberID,
            credential: credential,
            api: reserveAPI,
            lease: fixture.lease
        ) else { throw DailySharingError.stateUnavailable }
        let reserveCalls = await reserveAPI.runtimeReserveCalls()
        guard reserveCalls.requestIDs == [stableReserveRequestID, stableReserveRequestID],
              reserveCalls.mediaIDs == [[mediaID], [mediaID]],
              fixture.state.outbound?.phase == .reserved,
              fixture.state.outbound?.generationID == recoveredGenerationID,
              fixture.state.outbound?.localDayKey == attemptedDay + 1,
              fixture.state.outbound?.reserveAttemptedAt == nil
        else { throw DailySharingError.stateUnavailable }

        // A never-sent stale freeze has no uncertainty and must still be
        // discarded before today's manifest is frozen.
        var neverSent = frozenForReserve
        neverSent.reserveClientRequestID = UUID().uuidString.lowercased()
        fixture.state.outbound = neverSent
        fixture.state = try DailySharingStateStore.save(
            fixture.state,
            expectedStorageRevision: fixture.state.storageRevision,
            lease: fixture.lease
        )
        try await reserveCoordinator.runtimeSelfTestDiscardStaleUnsentFrozen(
            state: &fixture.state,
            currentLocalDayKey: attemptedDay + 1,
            lease: fixture.lease
        )
        guard fixture.state.outbound == nil else {
            throw DailySharingError.stateUnavailable
        }

        let first = DailySharingSyncCoordinator.retryTiming(
            error: URLError(.timedOut),
            attempt: 1
        ).delay
        let capped = DailySharingSyncCoordinator.retryTiming(
            error: URLError(.timedOut),
            attempt: 10
        ).delay
        guard (24.0...36.0).contains(first),
              (17_280.0...25_920.0).contains(capped)
        else { throw DailySharingError.stateUnavailable }
    }

    private static func finishLeaseChecks(
        _ fixture: inout StoreFixture
    ) async throws {
        guard fixture.leaseChecksPassed else { throw DailySharingError.stateChanged }
        let coordinator = DailySharingSyncCoordinator(configuration: .current)
        try await coordinator.runtimeSelfTestLeaseHeartbeat(
            spaceID: fixture.spaceID,
            memberID: fixture.memberID,
            lifecycleToken: fixture.lifecycleToken,
            lease: fixture.lease
        )
        fixture.lease.release()
        let acquisition = try DailySharingStateStore.acquireSyncLease(
            spaceID: fixture.spaceID,
            memberID: fixture.memberID,
            lifecycleToken: fixture.lifecycleToken
        )
        guard case .acquired(let replacement) = acquisition else {
            throw DailySharingError.stateChanged
        }
        replacement.release()
    }

    private static func testTerminalPurge(_ fixture: StoreFixture) async throws {
        let snapshot = try PairingStateStore.beginOperation()
        guard let unpaired = snapshot.state,
              unpaired.phase == .unpaired,
              let directory = SharedContainer.sharingOutboundDirectoryURL
        else { throw PairingError.stateUnavailable }

        let keychainProbe = PairingCrypto.makeCredential(
            installationMarker: unpaired.installationMarker,
            includesInvitationSecret: false,
            includesRoomKey: true
        )
        let peerCredential = PairingCrypto.makeCredential(
            installationMarker: unpaired.installationMarker,
            includesInvitationSecret: false,
            includesRoomKey: false
        )
        let localMember = PairingMemberIdentity(
            memberID: opaque(41),
            participantID: keychainProbe.participantIDString,
            agreementPublicKey: try PairingCrypto.agreementPublicKey(for: keychainProbe)
                .base64URLEncodedString(),
            signingPublicKey: try PairingCrypto.signingPublicKey(for: keychainProbe)
                .base64URLEncodedString()
        )
        let peerMember = PairingMemberIdentity(
            memberID: opaque(42),
            participantID: peerCredential.participantIDString,
            agreementPublicKey: try PairingCrypto.agreementPublicKey(for: peerCredential)
                .base64URLEncodedString(),
            signingPublicKey: try PairingCrypto.signingPublicKey(for: peerCredential)
                .base64URLEncodedString()
        )
        let spaceID = opaque(43)
        let invitationID = opaque(44)
        let enrollmentID = opaque(45)
        let transcript = PairingVerificationTranscript(
            spaceID: spaceID,
            invitationID: invitationID,
            enrollmentID: enrollmentID,
            dailyBoundaryMinuteUTC: 240,
            inviter: localMember,
            invitee: peerMember
        )
        let transcriptData = try transcript.canonicalData()
        let transcriptHash = PairingCrypto.sha256(transcriptData)

        var creating = unpaired
        creating.phase = .creatingInvitation
        creating.role = .inviter
        creating.credentialAccount = keychainProbe.account
        creating.participantID = keychainProbe.participantIDString
        creating.pendingClientRequestID = UUID().uuidString.lowercased()
        creating.pendingOperation = "create"
        creating.lastUpdatedAt = .now
        creating = try PairingStateStore.saveInitialCredentialAndState(
            credential: keychainProbe,
            state: creating,
            expected: unpaired,
            lifecycleToken: snapshot.lifecycleToken
        )
        var paired = creating
        paired.phase = .paired
        paired.spaceID = spaceID
        paired.memberID = localMember.memberID
        paired.invitationID = invitationID
        paired.enrollmentID = enrollmentID
        paired.peerMemberID = peerMember.memberID
        paired.peerParticipantID = peerMember.participantID
        paired.peerAgreementPublicKey = peerMember.agreementPublicKey
        paired.peerSigningPublicKey = peerMember.signingPublicKey
        paired.transcript = transcriptData.base64URLEncodedString()
        paired.transcriptHash = transcriptHash.base64URLEncodedString()
        paired.verificationPhrase = PairingCrypto.verificationPhrase(for: transcriptHash)
        paired.dailyBoundaryMinuteUTC = 240
        paired.pendingClientRequestID = nil
        paired.pendingOperation = nil
        paired.mediaSharingConsentVersion = PairingMediaSharingConsent.currentVersion
        paired.mediaSharingConsentAcceptedAt = .now
        paired.lastUpdatedAt = .now
        paired = try PairingStateStore.save(
            paired,
            expected: creating,
            lifecycleToken: snapshot.lifecycleToken
        )

        // A normal read may hide legacy diagnostic text in memory, but it must
        // never rewrite the full PairingState without the lifecycle flock. A
        // locked operation performs the physical scrub without changing the
        // authorization identity or its CAS revision.
        guard let pairingStateURL = SharedContainer.pairingStateURL else {
            throw PairingError.stateUnavailable
        }
        let legacyPairingError =
            "https://example.invalid/private/var/mobile/pairing?token=SUPERSECRET\nsecond-line"
        var legacyPairing = paired
        legacyPairing.lastError = legacyPairingError
        let legacyPairingEncoder = JSONEncoder()
        legacyPairingEncoder.dateEncodingStrategy = .iso8601
        legacyPairingEncoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let legacyPairingData = try legacyPairingEncoder.encode(legacyPairing.validated())
        try SharingLifecycleGate.withValidatedToken(snapshot.lifecycleToken) {
            try SharingSecureFile.write(legacyPairingData, to: pairingStateURL)
        }
        guard String(decoding: legacyPairingData, as: UTF8.self).contains("SUPERSECRET"),
              let readOnlyPairing = try PairingStateStore.load(),
              readOnlyPairing.lastError == DiagnosticLogPrivacy.persistedPairingFailureCopy,
              try Data(contentsOf: pairingStateURL) == legacyPairingData
        else { throw PairingError.stateUnavailable }

        let lockedMigration = try PairingStateStore.beginOperation()
        guard lockedMigration.lifecycleToken == snapshot.lifecycleToken,
              let migratedPairing = lockedMigration.state,
              migratedPairing.lastError == DiagnosticLogPrivacy.persistedPairingFailureCopy,
              migratedPairing.storageRevision == paired.storageRevision
        else { throw PairingError.stateUnavailable }
        let migratedPairingData = try Data(contentsOf: pairingStateURL)
        let migratedPairingText = String(decoding: migratedPairingData, as: UTF8.self)
        for forbidden in [
            "SUPERSECRET",
            "example.invalid",
            "/private/var/",
            "second-line",
        ] where migratedPairingText.contains(forbidden) {
            throw PairingError.stateUnavailable
        }
        paired = migratedPairing

        let pairingRevisionBeforeRename = paired.storageRevision
        let firstWindowName = try PrivateWindowPresentationStore.save(
            displayName: "  しずくのまど  ",
            pairing: paired,
            validating: snapshot.lifecycleToken
        )
        let secondWindowName = try PrivateWindowPresentationStore.save(
            displayName: "夜のまど",
            pairing: paired,
            validating: snapshot.lifecycleToken
        )
        guard firstWindowName.displayName == "しずくのまど",
              secondWindowName.displayName == "夜のまど",
              secondWindowName.storageRevision == firstWindowName.storageRevision + 1,
              (try PairingStateStore.load())?.storageRevision
                == pairingRevisionBeforeRename,
              PrivateWindowPresentationStore.resolvedDisplayName(
                  pairing: paired,
                  validating: snapshot.lifecycleToken
              ) == "夜のまど",
              let windowPresentationURL = SharedContainer.privateWindowPresentationURL,
              FileManager.default.fileExists(atPath: windowPresentationURL.path)
        else { throw PairingError.stateUnavailable }

        guard let roomKey = keychainProbe.roomKey,
              let windowNameSyncURL = SharedContainer.privateWindowNameSyncStateURL
        else { throw PairingError.stateUnavailable }
        let synchronizedName = try PrivateWindowNameCrypto.prepare(
            displayName: secondWindowName.displayName,
            context: PrivateWindowNameCiphertextContext(
                spaceID: spaceID,
                ownerMemberID: localMember.memberID,
                ownerRevision: secondWindowName.storageRevision,
                keyEpoch: 1
            ),
            roomKey: roomKey,
            ownerSigningPrivateKey: keychainProbe.signingPrivateKey
        )
        let retryID = UUID()
        let stagedName = try PrivateWindowNameSyncStore.stagePending(
            synchronizedName,
            clientRequestID: retryID,
            pairing: paired,
            validating: snapshot.lifecycleToken
        )
        let reloadedPending = try PrivateWindowNameSyncStore.pending(
            ownerRevision: secondWindowName.storageRevision,
            pairing: paired,
            validating: snapshot.lifecycleToken
        )
        let firstPendingFile = try Data(contentsOf: windowNameSyncURL)
        let independentlyPreparedRetry = try PrivateWindowNameCrypto.prepare(
            displayName: secondWindowName.displayName,
            context: synchronizedName.context,
            roomKey: roomKey,
            ownerSigningPrivateKey: keychainProbe.signingPrivateKey
        )
        let replacementRetryID = UUID()
        let exactRetry = try PrivateWindowNameSyncStore.stagePending(
            independentlyPreparedRetry,
            clientRequestID: replacementRetryID,
            pairing: paired,
            validating: snapshot.lifecycleToken
        )
        let retriedPendingFile = try Data(contentsOf: windowNameSyncURL)
        guard stagedName.payload == synchronizedName,
              stagedName.clientRequestID == retryID,
              reloadedPending?.payload == synchronizedName,
              reloadedPending?.clientRequestID == retryID,
              independentlyPreparedRetry != synchronizedName,
              replacementRetryID != retryID,
              exactRetry.payload == synchronizedName,
              exactRetry.clientRequestID == retryID,
              retriedPendingFile == firstPendingFile,
              FileManager.default.fileExists(atPath: windowNameSyncURL.path)
        else { throw PairingError.stateUnavailable }

        // Build 33 persisted no transcript-encoding marker. Reproduce that
        // exact JSON shape, prove it is never exposed for verbatim retry, then
        // migrate only the ambiguous envelope while retaining the rollback
        // floor before a corrected payload receives a fresh idempotency key.
        guard var legacyPendingState = try PrivateWindowNameSyncStore.load(
            pairing: paired,
            validating: snapshot.lifecycleToken
        ) else { throw PairingError.stateUnavailable }
        let legacyAcceptedHash = Data(repeating: 0x6A, count: 32)
        legacyPendingState.acceptedOwnerRevision = firstWindowName.storageRevision
        legacyPendingState.acceptedCiphertextSHA256 = legacyAcceptedHash
        legacyPendingState.pendingTranscriptEncodingVersion = nil
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        legacyEncoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        let legacyPendingData = try legacyEncoder.encode(legacyPendingState.validated())
        guard legacyPendingData.range(
            of: Data("pendingTranscriptEncodingVersion".utf8)
        ) == nil else { throw PairingError.stateUnavailable }
        try SharingLifecycleGate.withValidatedToken(snapshot.lifecycleToken) {
            try SharingSecureFile.write(legacyPendingData, to: windowNameSyncURL)
        }
        guard try PrivateWindowNameSyncStore.pending(
            ownerRevision: secondWindowName.storageRevision,
            pairing: paired,
            validating: snapshot.lifecycleToken
        ) == nil,
              let legacyBeforeMigration = try PrivateWindowNameSyncStore.load(
                  pairing: paired,
                  validating: snapshot.lifecycleToken
              )
        else { throw PairingError.stateUnavailable }

        let migrationDate = Date(timeIntervalSince1970: 1_780_000_000)
        guard try PrivateWindowNameSyncStore.discardLegacyPendingAfterAuthoritativeRead(
            pairing: paired,
            validating: snapshot.lifecycleToken,
            now: migrationDate
        ),
              let migratedLegacyState = try PrivateWindowNameSyncStore.load(
                  pairing: paired,
                  validating: snapshot.lifecycleToken
              ),
              migratedLegacyState.storageRevision
                == legacyBeforeMigration.storageRevision + 1,
              migratedLegacyState.acceptedOwnerRevision
                == firstWindowName.storageRevision,
              migratedLegacyState.acceptedCiphertextSHA256 == legacyAcceptedHash,
              migratedLegacyState.pendingPayload == nil,
              migratedLegacyState.pendingClientRequestID == nil,
              migratedLegacyState.pendingTranscriptEncodingVersion == nil,
              !(try PrivateWindowNameSyncStore
                  .discardLegacyPendingAfterAuthoritativeRead(
                      pairing: paired,
                      validating: snapshot.lifecycleToken,
                      now: migrationDate
                  ))
        else { throw PairingError.stateUnavailable }

        let correctedRetryID = UUID()
        let correctedPending = try PrivateWindowNameSyncStore.stagePending(
            synchronizedName,
            clientRequestID: correctedRetryID,
            pairing: paired,
            validating: snapshot.lifecycleToken
        )
        guard correctedRetryID != retryID,
              correctedPending.payload == synchronizedName,
              correctedPending.clientRequestID == correctedRetryID,
              let correctedState = try PrivateWindowNameSyncStore.load(
                  pairing: paired,
                  validating: snapshot.lifecycleToken
              ),
              correctedState.pendingTranscriptEncodingVersion
                == PrivateWindowNameSyncState.currentPendingTranscriptEncodingVersion,
              try PrivateWindowNameSyncStore.recordAccepted(
                synchronizedName,
                pairing: paired,
                validating: snapshot.lifecycleToken
              ),
              try PrivateWindowNameSyncStore.pending(
                ownerRevision: secondWindowName.storageRevision,
                pairing: paired,
                validating: snapshot.lifecycleToken
              ) == nil
        else { throw PairingError.stateUnavailable }

        let staleName = try PrivateWindowNameCrypto.prepare(
            displayName: firstWindowName.displayName,
            context: PrivateWindowNameCiphertextContext(
                spaceID: spaceID,
                ownerMemberID: localMember.memberID,
                ownerRevision: firstWindowName.storageRevision,
                keyEpoch: 1
            ),
            roomKey: roomKey,
            ownerSigningPrivateKey: keychainProbe.signingPrivateKey
        )
        guard !(try PrivateWindowNameSyncStore.recordAccepted(
            staleName,
            pairing: paired,
            validating: snapshot.lifecycleToken
        )) else { throw PairingError.stateUnavailable }

        let conflictingName = try PrivateWindowNameCrypto.prepare(
            displayName: "別のまど",
            context: synchronizedName.context,
            roomKey: roomKey,
            ownerSigningPrivateKey: keychainProbe.signingPrivateKey
        )
        do {
            _ = try PrivateWindowNameSyncStore.recordAccepted(
                conflictingName,
                pairing: paired,
                validating: snapshot.lifecycleToken
            )
            throw PairingError.stateUnavailable
        } catch PairingError.stateUnavailable {
            // Same creator revision with different authenticated bytes is a
            // conflict, never a last-arrival-wins rename.
        }
        guard (try PairingStateStore.load())?.storageRevision
                == pairingRevisionBeforeRename
        else { throw PairingError.stateUnavailable }

        let reportOnlyUntil = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 60 * 60
        )
        try MomentSharingStateStore.enterReportOnlyMode(
            until: reportOnlyUntil,
            validating: snapshot.lifecycleToken,
            now: .now
        )
        let reportOnlyAPI = RuntimeWindowNameAPI()
        let nameCoordinator = MomentSharingCoordinator()
        do {
            try await nameCoordinator.runtimeSynchronizeWindowName(
                api: reportOnlyAPI
            )
            throw PairingError.stateUnavailable
        } catch let error as MomentSharingError {
            guard case let .reportOnly(until) = error,
                  until == reportOnlyUntil
            else { throw error }
        }
        let reportOnlyCounts = await reportOnlyAPI.runtimeCounts()
        guard reportOnlyCounts.gets == 0,
              reportOnlyCounts.puts == 0
        else { throw PairingError.stateUnavailable }

        var wrongWindowIdentity = paired
        wrongWindowIdentity.spaceID = opaque(46)
        guard PrivateWindowPresentationStore.resolvedDisplayName(
            pairing: wrongWindowIdentity,
            validating: snapshot.lifecycleToken
        ) == PrivateWindowDisplayName.fallback else {
            throw PairingError.stateUnavailable
        }

        let sentinel = directory.appendingPathComponent("runtime-purge.enc", isDirectory: false)
        try SharingSecureFile.write(Data(repeating: 0x71, count: 29), to: sentinel)

        // An authenticated response from an older/different pairing must not
        // purge a newly established identity.
        var staleIdentity = paired
        staleIdentity.spaceID = opaque(46)
        try PairingInstallationGuard.resetAfterRemoteRevocation(
            expectedState: staleIdentity,
            lifecycleToken: snapshot.lifecycleToken
        )
        guard (try PairingStateStore.load()) == paired,
              try PairingKeychainStore.load(
                  account: keychainProbe.account,
                  installationMarker: unpaired.installationMarker
              ) == keychainProbe,
              FileManager.default.fileExists(atPath: sentinel.path),
              FileManager.default.fileExists(atPath: windowPresentationURL.path),
              FileManager.default.fileExists(atPath: windowNameSyncURL.path)
        else { throw PairingError.stateUnavailable }

        // A benign mutable revision change must not prevent cleanup of the
        // exact same immutable pairing identity after authenticated revoke.
        var refreshed = paired
        refreshed.lastError = "runtime benign refresh"
        refreshed.lastUpdatedAt = .now
        refreshed = try PairingStateStore.save(
            refreshed,
            expected: paired,
            lifecycleToken: snapshot.lifecycleToken
        )
        guard refreshed.storageRevision != paired.storageRevision else {
            throw PairingError.stateUnavailable
        }
        try PairingInstallationGuard.resetAfterRemoteRevocation(
            expectedState: paired,
            lifecycleToken: snapshot.lifecycleToken
        )
        guard !FileManager.default.fileExists(atPath: sentinel.path),
              !FileManager.default.fileExists(atPath: windowPresentationURL.path),
              !FileManager.default.fileExists(atPath: windowNameSyncURL.path),
              (try PairingStateStore.load())?.phase == .unpaired
        else { throw PairingError.stateUnavailable }
        do {
            _ = try PrivateWindowNameSyncStore.recordAccepted(
                synchronizedName,
                pairing: paired,
                validating: snapshot.lifecycleToken
            )
            throw PairingError.stateUnavailable
        } catch PairingError.stateUnavailable {
            // Models a GET/PUT response resuming after unlink. The stale
            // lifecycle cannot recreate either presentation file.
        } catch SharingLifecycleGate.Error.unavailable {
            // The terminal purge invalidates the lifecycle before a stale
            // response can reach either presentation store.
        }
        guard !FileManager.default.fileExists(atPath: windowPresentationURL.path),
              !FileManager.default.fileExists(atPath: windowNameSyncURL.path)
        else { throw PairingError.stateUnavailable }
        do {
            _ = try PairingKeychainStore.load(
                account: keychainProbe.account,
                installationMarker: unpaired.installationMarker
            )
            throw PairingError.stateUnavailable
        } catch PairingError.malformedCredential {
            // Service-scoped cleanup removed the room key/private keys.
        }
        do {
            try SharingLifecycleGate.validate(fixture.lifecycleToken)
            throw PairingError.stateUnavailable
        } catch SharingLifecycleGate.Error.unavailable {
            // The terminal purge invalidated every old media writer.
        }
    }

    private static func opaque(_ byte: UInt8) -> String {
        Data(repeating: byte, count: 16).base64URLEncodedString()
    }

    private static func currentVariant(
        _ base: SharingCurrentGeneration,
        generationID: String? = nil,
        shareDayKey: Int? = nil,
        revision: Int? = nil,
        rotationAnchorUTC: Int? = nil,
        manifestHash: String? = nil
    ) -> SharingCurrentGeneration {
        let effectiveRevision = revision ?? base.revision
        return SharingCurrentGeneration(
            sourceID: base.sourceID,
            publisherMemberID: base.publisherMemberID,
            generationID: generationID ?? base.generationID,
            shareDayKey: shareDayKey ?? base.shareDayKey,
            revision: effectiveRevision,
            attemptID: base.attemptID,
            attemptRevision: base.attemptRevision,
            reservedRevision: effectiveRevision,
            rotationAnchorUTC: rotationAnchorUTC ?? base.rotationAnchorUTC,
            uniqueMediaCount: base.uniqueMediaCount,
            manifest: .init(
                ciphertextSize: base.manifest.ciphertextSize,
                ciphertextSHA256: manifestHash ?? base.manifest.ciphertextSHA256
            ),
            media: base.media
        )
    }
}
#endif
