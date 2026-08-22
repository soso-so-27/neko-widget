import Foundation
import SensitiveContentAnalysis

enum MomentSenderPolicy {
    static let currentVersion = 1
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
