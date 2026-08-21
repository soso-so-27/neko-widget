import Foundation
import ImageIO
import SensitiveContentAnalysis
import UIKit

enum MomentSenderPolicy {
    static let currentVersion = 1
}

enum MomentPlaintextTemporaryStore {
    private static let maximumStaleAge: TimeInterval = 60 * 60

    static var sourceDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoWidgetMomentShare", isDirectory: true)
    }

    static var moderationDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NekoWidgetMomentModeration", isDirectory: true)
    }

    static func pruneStaleFiles(now: Date = .now) throws {
        let cutoff = now.addingTimeInterval(-maximumStaleAge)
        try prune(directory: sourceDirectory, prefix: "source-", cutoff: cutoff)
        try prune(directory: moderationDirectory, prefix: ".moderation-", cutoff: cutoff)
    }

    private static func prune(directory: URL, prefix: String, cutoff: Date) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return }
        let files = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: []
        )
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey]
            )
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate,
                  modifiedAt < cutoff
            else { continue }
            try? manager.removeItem(at: file)
        }
    }
}

actor MomentModerationService {
    private let analyzer = SCSensitivityAnalyzer()

    func requireSafeImage(at url: URL) async throws {
        guard analyzer.analysisPolicy != .disabled else {
            throw MomentSharingError.moderationUnavailable
        }
        do {
            let analysis = try await analyzer.analyzeImage(at: url)
            guard !analysis.isSensitive else {
                throw MomentSharingError.sensitiveContent
            }
        } catch let error as MomentSharingError {
            throw error
        } catch {
            throw MomentSharingError.moderationUnavailable
        }
    }
}

actor MomentSharePreparationService {
    private let moderation: MomentModerationService
    private let configuration: SharingAPIConfiguration

    init(
        moderation: MomentModerationService = MomentModerationService(),
        configuration: SharingAPIConfiguration = .current
    ) {
        self.moderation = moderation
        self.configuration = configuration
    }

    func prepareAndEnqueue(
        sourceURL: URL,
        senderPolicyAcceptedAt: Date,
        now: Date = .now
    ) async throws -> MomentOutboxItem {
        // The Share Extension cannot read the host app's ordinary-container
        // installation marker. Until an install-bound handoff exists, it must
        // not touch a persisted room key or create an outbound ciphertext.
        guard configuration.isShareExtensionMediaAvailable else {
            throw MomentSharingError.featureDisabled
        }
        try MomentPlaintextTemporaryStore.pruneStaleFiles()
        let operation = try PairingStateStore.beginOperation()
        guard let pairing = operation.state,
              pairing.phase == .paired,
              let account = pairing.credentialAccount,
              let spaceID = pairing.spaceID,
              let memberID = pairing.memberID
        else { throw MomentSharingError.notPaired }
        guard pairing.mediaSharingConsentVersion == PairingMediaSharingConsent.currentVersion,
              pairing.mediaSharingConsentAcceptedAt != nil
        else { throw MomentSharingError.consentRequired }
        let credential = try PairingKeychainStore.load(
            account: account,
            installationMarker: pairing.installationMarker
        )
        guard let roomKey = credential.roomKey else {
            throw MomentSharingError.notPaired
        }

        let loaded = try Self.loadImageAndCaptureDate(from: sourceURL)
        let preview = try MomentCanonicalPreviewBuilder.build(image: loaded.image)
        let temporaryRoot = MomentPlaintextTemporaryStore.moderationDirectory
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        try SharingSecureFile.enforceProtectionAndBackupExclusion(temporaryRoot)
        let moderationURL = temporaryRoot.appendingPathComponent(
            ".moderation-\(UUID().uuidString).jpg",
            isDirectory: false
        )
        try SharingSecureFile.write(preview.jpeg, to: moderationURL)
        defer { try? FileManager.default.removeItem(at: moderationURL) }
        try await moderation.requireSafeImage(at: moderationURL)
        try Task.checkCancellation()
        try SharingLifecycleGate.validate(operation.lifecycleToken)

        let context = MomentRequestContext(
            spaceID: spaceID,
            senderParticipantID: memberID,
            // Migration 0003 maps every legacy member to one participant and
            // one device with the same opaque ID. Future device enrollment can
            // replace this without changing ciphertext AAD.
            senderDeviceID: memberID,
            clientRequestID: UUID(),
            clientMomentID: UUID(),
            kind: .live,
            keyEpoch: 1
        )
        let payload = try MomentCrypto.prepare(
            canonicalJPEG: preview.jpeg,
            capturedAt: loaded.capturedAt,
            pixelWidth: preview.pixelWidth,
            pixelHeight: preview.pixelHeight,
            context: context,
            spaceGenerationKey: roomKey
        )
        try SharingLifecycleGate.validate(operation.lifecycleToken)
        return try MomentSharingStateStore.enqueue(
            payload: payload,
            senderPolicyVersion: MomentSenderPolicy.currentVersion,
            senderPolicyAcceptedAt: senderPolicyAcceptedAt,
            validating: operation.lifecycleToken,
            now: now
        )
    }

    private nonisolated static func loadImageAndCaptureDate(
        from url: URL
    ) throws -> (image: UIImage, capturedAt: Date?) {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) == 1
        else { throw MomentSharingError.invalidPayload }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize:
                MomentSharingProtocol.maximumCanonicalPixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { throw MomentSharingError.invalidPayload }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        return (
            UIImage(cgImage: image, scale: 1, orientation: .up),
            captureDate(from: properties)
        )
    }

    private nonisolated static func captureDate(
        from properties: [CFString: Any]?
    ) -> Date? {
        guard let properties else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        // EXIF wall-clock fields are not absolute instants without their
        // offset. Treating a missing offset as GMT changes the real capture
        // time and would make encrypted metadata look more certain than it is.
        // Preserve the protocol's explicit `missing` state instead.
        let offsetOriginalKey = "OffsetTimeOriginal" as CFString
        let offsetDigitizedKey = "OffsetTimeDigitized" as CFString
        let candidates: [(date: String?, offset: String?)] = [
            (
                exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                exif?[offsetOriginalKey] as? String
            ),
            (
                exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
                exif?[offsetDigitizedKey] as? String
            )
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXX"
        for candidate in candidates {
            guard let date = candidate.date,
                  let offset = candidate.offset,
                  let value = formatter.date(from: date + offset)
            else { continue }
            return value
        }
        return nil
    }
}
