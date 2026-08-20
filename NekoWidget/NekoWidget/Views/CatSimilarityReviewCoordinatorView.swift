import SwiftUI

/// Owns one ephemeral FeaturePrint session. The generated groups and distance
/// matrix disappear when this screen closes; only groups the user explicitly
/// confirms are forwarded to the durable identity ledger.
@MainActor
struct CatSimilarityReviewCoordinatorView: View {
    typealias ConfirmationHandler = @MainActor (
        _ candidates: [CatSimilarityCandidateInstance],
        _ profileIdentifier: String
    ) async -> Bool

    let openProfileSetup: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: CatSimilarityReviewCoordinatorModel

    init(
        candidates: [CatSimilarityCandidateInstance],
        profiles: [CatSimilarityReviewProfilePresentation],
        confirmMembership: @escaping ConfirmationHandler,
        openProfileSetup: @escaping () -> Void
    ) {
        self.openProfileSetup = openProfileSetup
        _model = StateObject(wrappedValue: CatSimilarityReviewCoordinatorModel(
            candidates: candidates,
            profiles: profiles,
            confirmMembership: confirmMembership
        ))
    }

    var body: some View {
        CatSimilarityReviewView(
            presentation: model.presentation,
            actions: CatSimilarityReviewViewActions(
                startGrouping: model.startGrouping,
                confirmGroup: model.confirmGroup,
                splitMixedGroup: model.splitMixedGroup,
                reviewLater: model.reviewLater,
                cancelGrouping: model.cancelGrouping,
                dismiss: { dismiss() },
                openProfileSetup: {
                    dismiss()
                    openProfileSetup()
                }
            )
        )
        .onDisappear {
            model.discardSession()
        }
    }
}

@MainActor
private final class CatSimilarityReviewCoordinatorModel: ObservableObject {
    typealias ConfirmationHandler = CatSimilarityReviewCoordinatorView
        .ConfirmationHandler

    @Published private(set) var presentation: CatSimilarityReviewPresentation

    private let candidates: [CatSimilarityCandidateInstance]
    private let profiles: [CatSimilarityReviewProfilePresentation]
    private let confirmMembership: ConfirmationHandler
    private let service = CatSimilarityGroupingService()

    private var groupingTask: Task<Void, Never>?
    private var discardTask: Task<Void, Never>?
    private var operationToken = UUID()
    private var groupIDByPresentationIdentifier: [
        String: CatSimilaritySessionGroupID
    ] = [:]
    private var presentationIdentifierByGroupID: [
        CatSimilaritySessionGroupID: String
    ] = [:]
    private var presentationIdentifierByInstanceID: [
        CatSimilaritySessionInstanceID: String
    ] = [:]
    private var groupByPresentationIdentifier: [
        String: CatSimilarityCandidateGroup
    ] = [:]
    private var nextGroupIdentifier = 0
    private var nextCandidateIdentifier = 0
    private var confirmedGroupCount = 0
    private var deferredGroupCount = 0

    init(
        candidates: [CatSimilarityCandidateInstance],
        profiles: [CatSimilarityReviewProfilePresentation],
        confirmMembership: @escaping ConfirmationHandler
    ) {
        self.candidates = candidates
        self.profiles = profiles
        self.confirmMembership = confirmMembership
        let target = Self.targetGroupCount(candidateCount: candidates.count)
        presentation = CatSimilarityReviewPresentation(
            phase: candidates.isEmpty
                ? .empty
                : .ready(
                    candidateCount: candidates.count,
                    targetGroupCount: target
                ),
            profiles: profiles
        )
    }

    func startGrouping() async {
        guard groupingTask == nil else { return }
        if let discardTask {
            await discardTask.value
            self.discardTask = nil
        }
        resetReviewState()
        guard !candidates.isEmpty else {
            presentation = CatSimilarityReviewPresentation(
                phase: .empty,
                profiles: profiles
            )
            return
        }

        let token = UUID()
        operationToken = token
        presentation = CatSimilarityReviewPresentation(
            phase: .grouping(
                completedCandidateCount: 0,
                totalCandidateCount: candidates.count
            ),
            profiles: profiles
        )
        let target = Self.targetGroupCount(candidateCount: candidates.count)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.generateGroups(
                    for: candidates,
                    targetGroupCount: target,
                    progress: { [weak self] progress in
                        await self?.receive(progress: progress, token: token)
                    }
                )
                guard !Task.isCancelled else { return }
                receive(result: result, token: token, currentIndex: 0)
            } catch is CancellationError {
                receiveCancellation(token: token)
            } catch {
                receiveFailure(token: token)
            }
        }
        groupingTask = task
        await task.value
        if operationToken == token {
            groupingTask = nil
        }
    }

    func confirmGroup(
        groupIdentifier: String,
        profileIdentifier: String
    ) async {
        guard let group = groupByPresentationIdentifier[groupIdentifier],
              presentation.currentGroup?.identifier == groupIdentifier else {
            return
        }
        let saved = await confirmMembership(
            group.instances.map(\.candidate),
            profileIdentifier
        )
        guard saved else {
            presentation = CatSimilarityReviewPresentation(
                phase: .failed(message: "所属を保存できませんでした。もう一度お試しください。"),
                profiles: profiles
            )
            return
        }
        confirmedGroupCount += 1
        advancePastCurrentGroup()
    }

    func splitMixedGroup(groupIdentifier: String) async {
        guard let groupID = groupIDByPresentationIdentifier[groupIdentifier],
              presentation.currentGroup?.identifier == groupIdentifier else {
            return
        }
        do {
            let result = try await service.split(groupID: groupID)
            receive(
                result: result,
                token: operationToken,
                currentIndex: presentation.currentGroupIndex
            )
        } catch CatSimilarityGroupingError.groupCannotBeSplit {
            // A single-photo group is already the smallest safe unit.
        } catch is CancellationError {
            return
        } catch {
            presentation = CatSimilarityReviewPresentation(
                phase: .failed(message: "このグループを分けられませんでした。"),
                profiles: profiles
            )
        }
    }

    func reviewLater(groupIdentifier: String) async {
        guard presentation.currentGroup?.identifier == groupIdentifier else {
            return
        }
        deferredGroupCount += 1
        advancePastCurrentGroup()
    }

    func cancelGrouping() {
        operationToken = UUID()
        groupingTask?.cancel()
        groupingTask = nil
        presentation = CatSimilarityReviewPresentation(
            phase: .cancelled,
            profiles: profiles
        )
        scheduleSessionDiscard()
    }

    func discardSession() {
        operationToken = UUID()
        groupingTask?.cancel()
        groupingTask = nil
        scheduleSessionDiscard()
    }

    private func receive(
        progress: CatSimilarityGroupingProgress,
        token: UUID
    ) {
        guard token == operationToken else { return }
        let completed: Int
        switch progress.phase {
        case .generatingFeaturePrints:
            completed = min(
                candidates.count,
                max(0, progress.completedUnitCount)
            )
        case .computingDistances, .clustering:
            // Feature extraction is the long per-photo phase represented by
            // the x/N label. Distance and clustering work keep it at N/N.
            completed = candidates.count
        }
        presentation = CatSimilarityReviewPresentation(
            phase: .grouping(
                completedCandidateCount: completed,
                totalCandidateCount: candidates.count
            ),
            profiles: profiles
        )
    }

    private func receive(
        result: CatSimilarityGroupingResult,
        token: UUID,
        currentIndex: Int
    ) {
        guard token == operationToken else { return }
        let groups = result.groups.map(makePresentationGroup)
        if groups.isEmpty, !result.ungroupedInstances.isEmpty {
            presentation = CatSimilarityReviewPresentation(
                phase: .failed(
                    message: "対象写真を端末内で取得できませんでした。写真アプリで画像を開いてから、もう一度お試しください。"
                ),
                profiles: profiles,
                ungroupedCandidateCount: result.ungroupedInstances.count
            )
            return
        }
        groupByPresentationIdentifier = Dictionary(
            uniqueKeysWithValues: zip(groups, result.groups).map {
                ($0.0.identifier, $0.1)
            }
        )
        presentation = CatSimilarityReviewPresentation(
            phase: groups.isEmpty ? .empty : .reviewing,
            profiles: profiles,
            groups: groups,
            currentGroupIndex: min(currentIndex, max(0, groups.count - 1)),
            ungroupedCandidateCount: result.ungroupedInstances.count
        )
    }

    private func receiveCancellation(token: UUID) {
        guard token == operationToken else { return }
        presentation = CatSimilarityReviewPresentation(
            phase: .cancelled,
            profiles: profiles
        )
    }

    private func receiveFailure(token: UUID) {
        guard token == operationToken else { return }
        presentation = CatSimilarityReviewPresentation(
            phase: .failed(
                message: "端末内で取得できる写真を使って、もう一度お試しください。"
            ),
            profiles: profiles
        )
    }

    private func makePresentationGroup(
        _ group: CatSimilarityCandidateGroup
    ) -> CatSimilarityReviewGroupPresentation {
        let groupIdentifier: String
        if let existing = presentationIdentifierByGroupID[group.id] {
            groupIdentifier = existing
        } else {
            groupIdentifier = "group-\(nextGroupIdentifier)"
            nextGroupIdentifier += 1
            presentationIdentifierByGroupID[group.id] = groupIdentifier
            groupIDByPresentationIdentifier[groupIdentifier] = group.id
        }
        return CatSimilarityReviewGroupPresentation(
            identifier: groupIdentifier,
            candidates: group.instances.map { instance in
                let candidateIdentifier: String
                if let existing = presentationIdentifierByInstanceID[instance.id] {
                    candidateIdentifier = existing
                } else {
                    candidateIdentifier = "candidate-\(nextCandidateIdentifier)"
                    nextCandidateIdentifier += 1
                    presentationIdentifierByInstanceID[instance.id] = candidateIdentifier
                }
                return CatSimilarityReviewCandidatePresentation(
                    identifier: candidateIdentifier,
                    assetLocalIdentifier: instance.candidate.assetLocalIdentifier,
                    subjectBoundingBox: instance.candidate.boundingBox.cgRect
                )
            },
            suggestedProfileIdentifier: nil
        )
    }

    private func advancePastCurrentGroup() {
        let nextIndex = presentation.currentGroupIndex + 1
        if nextIndex >= presentation.groups.count {
            presentation = CatSimilarityReviewPresentation(
                phase: .completed(
                    confirmedGroupCount: confirmedGroupCount,
                    deferredGroupCount: deferredGroupCount
                ),
                profiles: profiles,
                groups: presentation.groups,
                currentGroupIndex: presentation.currentGroupIndex,
                ungroupedCandidateCount: presentation.ungroupedCandidateCount
            )
        } else {
            presentation = CatSimilarityReviewPresentation(
                phase: .reviewing,
                profiles: profiles,
                groups: presentation.groups,
                currentGroupIndex: nextIndex,
                ungroupedCandidateCount: presentation.ungroupedCandidateCount
            )
        }
    }

    private func resetReviewState() {
        confirmedGroupCount = 0
        deferredGroupCount = 0
        groupIDByPresentationIdentifier.removeAll(keepingCapacity: true)
        presentationIdentifierByGroupID.removeAll(keepingCapacity: true)
        presentationIdentifierByInstanceID.removeAll(keepingCapacity: true)
        groupByPresentationIdentifier.removeAll(keepingCapacity: true)
        nextGroupIdentifier = 0
        nextCandidateIdentifier = 0
    }

    private func scheduleSessionDiscard() {
        let previous = discardTask
        let service = service
        discardTask = Task {
            if let previous { await previous.value }
            await service.discardSession()
        }
    }

    private static func targetGroupCount(candidateCount: Int) -> Int {
        min(CatSimilarityGroupingService.defaultTargetGroupCount, max(1, candidateCount))
    }
}
