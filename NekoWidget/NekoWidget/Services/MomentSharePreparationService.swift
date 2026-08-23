import Foundation
import SensitiveContentAnalysis

enum MomentSenderPolicy {
    static let currentVersion = 1
}

/// Keeps inbound moderation fail-closed without turning a missing or
/// temporarily unavailable system analyzer into a permanent sensitive-content
/// verdict. Retry decisions leave the relay delivery unacknowledged so the
/// same ciphertext can be downloaded and checked again later.
enum MomentInboundModerationPolicy {
    static func inboxState(
        after moderationError: MomentSharingError?
    ) throws -> MomentInboxState {
        guard let moderationError else { return .available }
        switch moderationError {
        case .sensitiveContent:
            return .blocked
        case .moderationDisabled, .moderationUnavailable:
            throw moderationError
        default:
            // The analyzer wrapper should only emit the three cases above.
            // If that boundary changes, keep the photo hidden and retry rather
            // than persisting an unreviewed plaintext or a false block.
            throw MomentSharingError.moderationUnavailable
        }
    }
}

protocol MomentModerating: Sendable {
    func requireSafeImage(at url: URL) async throws
}

actor MomentModerationService: MomentModerating {
    private let analyzer = SCSensitivityAnalyzer()

    func requireSafeImage(at url: URL) async throws {
        guard analyzer.analysisPolicy != .disabled else {
            throw MomentSharingError.moderationDisabled
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
