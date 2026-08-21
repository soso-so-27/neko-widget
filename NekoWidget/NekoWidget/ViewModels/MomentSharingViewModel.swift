import Combine
import Foundation

@MainActor
final class MomentSharingViewModel: ObservableObject {
    @Published private(set) var pairingState: PairingState?
    @Published private(set) var sharingState: MomentSharingState = .empty
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    private let configuration: SharingAPIConfiguration
    private let coordinator: MomentSharingCoordinator

    init(configuration: SharingAPIConfiguration = .current) {
        self.configuration = configuration
        coordinator = MomentSharingCoordinator(configuration: configuration)
    }

    var isPaired: Bool { pairingState?.phase == .paired }
    var hasCurrentMediaSharingConsent: Bool {
        pairingState?.mediaSharingConsentVersion == PairingMediaSharingConsent.currentVersion
            && pairingState?.mediaSharingConsentAcceptedAt != nil
    }
    var pendingCount: Int {
        sharingState.outbox.filter {
            $0.phase == .prepared || $0.phase == .reserved
                || $0.phase == .uploaded || $0.phase == .committing
        }.count
    }
    var cancellablePendingCount: Int {
        sharingState.outbox.filter {
            $0.phase == .prepared || $0.phase == .reserved || $0.phase == .uploaded
        }.count
    }
    var failedCount: Int { sharingState.outbox.filter { $0.phase == .failed }.count }
    var reportOnlyUntil: Date? { sharingState.reportOnlyUntil }
    var isReportOnly: Bool { reportOnlyUntil != nil }
    var receivedMoments: [MomentInboxItem] {
        sharingState.inbox
            .filter { $0.state == .available || $0.state == .acknowledged }
            .sorted {
                if $0.committedAt != $1.committedAt { return $0.committedAt > $1.committedAt }
                return $0.id < $1.id
            }
    }
    var safetyHiddenMoments: [MomentInboxItem] {
        sharingState.inbox
            .filter { $0.state == .blocked || $0.state == .revoked }
            .sorted {
                if $0.receivedAt != $1.receivedAt { return $0.receivedAt > $1.receivedAt }
                return $0.id < $1.id
            }
    }

    func bootstrap() async {
        do {
            _ = try await PairingInstallationGuard.bootstrapAsync()
            try reload()
            if isPaired {
                await synchronize()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func synchronize() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await coordinator.synchronize(trigger: "family-window")
        do { try reload() }
        catch { errorMessage = error.localizedDescription }
    }

    func report(
        _ item: MomentInboxItem,
        reason: MomentReportReason
    ) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await coordinator.report(
                inboxItem: item,
                reason: reason,
                consentAcceptedAt: .now
            )
            errorMessage = nil
            try reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func block(_ participantID: String) async {
        guard !isWorking, !isReportOnly else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await coordinator.blockAndLeave(participantID: participantID)
            errorMessage = nil
            try reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func discardFailedOutbox() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await coordinator.discardFailedOutbox()
            errorMessage = nil
            try reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func discardPendingOutbox() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await coordinator.discardPendingOutbox()
            errorMessage = nil
            try reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func imageURL(for item: MomentInboxItem) -> URL? {
        guard let name = item.localJPEGFileName else { return nil }
        return SharedContainer.momentSharingReceivedDirectoryURL?
            .appendingPathComponent(name, isDirectory: false)
    }

    func hasReported(_ item: MomentInboxItem) -> Bool {
        sharingState.reportOutbox.contains {
            $0.momentID == item.id && $0.phase == .committed
        }
    }

    private func reload() throws {
        pairingState = try PairingStateStore.load()
        sharingState = try MomentSharingStateStore.load()
    }
}
