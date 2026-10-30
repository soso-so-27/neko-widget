import Foundation
#if os(iOS)
import UIKit
#endif

@MainActor
enum GroupReportingProvider {
    static func make() -> any GroupReportingService {
#if os(iOS)
        // An explicit internal build setting, absent/NO in ordinary builds.
        // The prototype remains the 310 UI; setting this cannot open the relay.
        let selected = Bundle.main.object(forInfoDictionaryKey: "GroupReportingProductionEnabled") as? String == "YES"
        guard selected else { return GroupReportingPrototype() }
        let config = SharingAPIConfiguration.current
        guard (InternalBuildPresentationAvailability.isAvailable || config.releaseMode == "production"),
              config.isEncryptedReportAvailable,
              GroupWindowClientProvider.production != nil, let endpoint = config.baseURL,
              let publicKey = config.moderationPublicKey,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return UnavailableGroupReporting()
        }
        do {
            return try ProductionGroupReporting(endpoint: endpoint,
                secrets: GroupKeychainStore(namespace: GroupWindowClientProvider.namespace), transport: GroupURLSessionTransport(),
                directory: support.appendingPathComponent(config.releaseMode == "production"
                    ? "GroupReports-v3-production" : "GroupReports-v3-staging", isDirectory: true), publicKey: publicKey) { windowID, photoID in
                    let photos = GroupWindowLocalPhotoStore.shared
                    guard let entry = await photos.entry(photoID: photoID, windowID: windowID),
                          entry.id == photoID, !entry.isHidden, entry.isRemoved != true,
                          let file = await photos.imageURL(photoID: photoID, windowID: windowID),
                          let size = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]).fileSize,
                          size > 0, size <= 1_048_576,
                          try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                        throw GroupSafetyError.evidenceUnavailable
                    }
                    let data = try Data(contentsOf: file)
                    guard let image = UIImage(data: data), image.imageOrientation == .up else { throw GroupSafetyError.evidenceUnavailable }
                    let canonical = try MomentCanonicalPreviewBuilder.build(image: image)
                    return GroupReportEvidence(windowID: windowID, photoID: photoID, canonicalJPEG: canonical.jpeg)
                }
        } catch { return UnavailableGroupReporting() }
#else
        return GroupReportingPrototype()
#endif
    }
}

/// Invalid real configuration never silently changes to a fake successful send.
@MainActor
private final class UnavailableGroupReporting: GroupReportingService {
    let isAvailable = false
    func prepareReport(windowID: String, photoID: String, senderName: String, reason: GroupReportReason, consent: GroupReportConsent) async throws -> String { throw GroupSafetyError.disabled }
    func submitReport(draftID: String) async throws -> GroupReportRecord { throw GroupSafetyError.disabled }
    func resumeReport(draftID: String) async throws -> GroupReportRecord { throw GroupSafetyError.disabled }
    func reports(windowID: String) async -> [GroupReportRecord] { [] }
    func refreshReport(draftID: String) async throws -> GroupReportRecord { throw GroupSafetyError.disabled }
    func setBlock(windowID: String, participantID: String, active: Bool, operationID: UUID) async throws { throw GroupSafetyError.disabled }
}
