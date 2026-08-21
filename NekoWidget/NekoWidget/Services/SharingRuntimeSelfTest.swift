#if DEBUG
import Foundation
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
        results.append(run("moment-report-only-terminal-gate") {
            try Self.testMomentReportOnlyTerminalGate()
        })
        results.append(run("moment-empty-cursor-normalization") {
            try Self.testMomentEmptyCursorNormalization()
        })
        results.append(run("moment-expired-delivery-advances") {
            try Self.testMomentExpiredDeliveryPolicy()
        })
        results.append(run("moment-outbox-bounds-and-expiry") {
            try Self.testMomentOutboxBoundsAndExpiry()
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
            results.append(run("peer-revoke-terminal-purge") {
                try Self.testTerminalPurge(value)
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
            validating: lifecycleToken
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
        }
        try MomentSharingStateStore.discardPendingOutbox(validating: lifecycleToken)
        let afterDiscard = try MomentSharingStateStore.load().outbox
        guard afterDiscard.count == 1,
              afterDiscard[0].id == ambiguous.id,
              afterDiscard[0].phase == .committing
        else {
            throw MomentSharingError.stateUnavailable
        }
        try MomentSharingStateStore.removeCiphertext(for: afterDiscard[0])
        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            state.outbox.removeAll()
        }

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
    }

    private static func clearMomentSharingFixture() throws {
        try SharingLifecycleGate.withExclusive {
            for url in [
                SharedContainer.momentSharingStateURL,
                SharedContainer.momentSharingCiphertextDirectoryURL,
                SharedContainer.momentSharingReceivedDirectoryURL
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

    private static func testTerminalPurge(_ fixture: StoreFixture) throws {
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
              FileManager.default.fileExists(atPath: sentinel.path)
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
              (try PairingStateStore.load())?.phase == .unpaired
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
