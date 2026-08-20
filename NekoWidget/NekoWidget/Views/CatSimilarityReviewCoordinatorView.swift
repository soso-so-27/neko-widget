import SwiftUI

/// Owns one ephemeral FeaturePrint session. The generated groups and distance
/// matrix disappear when this screen closes; only groups the user explicitly
/// confirms are forwarded to the durable identity ledger.
@MainActor
struct CatSimilarityReviewCoordinatorView: View {
    typealias CandidateProvider = @MainActor () -> [CatSimilarityCandidateInstance]
    typealias ConfirmationHandler = @MainActor (
        _ candidates: [CatSimilarityCandidateInstance],
        _ profileIdentifier: String
    ) async -> CatSimilarityGroupConfirmationOutcome

    let openProfileSetup: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: CatSimilarityReviewCoordinatorModel

    init(
        candidates: [CatSimilarityCandidateInstance],
        currentCandidates: @escaping CandidateProvider,
        profiles: [CatSimilarityReviewProfilePresentation],
        confirmMembership: @escaping ConfirmationHandler,
        openProfileSetup: @escaping () -> Void
    ) {
        self.openProfileSetup = openProfileSetup
        _model = StateObject(wrappedValue: CatSimilarityReviewCoordinatorModel(
            candidates: candidates,
            currentCandidates: currentCandidates,
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
    typealias CandidateProvider = CatSimilarityReviewCoordinatorView
        .CandidateProvider

    @Published private(set) var presentation: CatSimilarityReviewPresentation

    private var candidateBuffer: CatSimilarityReviewCandidateBuffer
    private var candidates: [CatSimilarityCandidateInstance] {
        candidateBuffer.candidates
    }
    private let currentCandidates: CandidateProvider
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
    private var confirmationTracker = CatSimilaritySessionConfirmationTracker()
    private var disabledProfileIdentifiersByGroupIdentifier: [
        String: Set<String>
    ] = [:]

    init(
        candidates: [CatSimilarityCandidateInstance],
        currentCandidates: @escaping CandidateProvider,
        profiles: [CatSimilarityReviewProfilePresentation],
        confirmMembership: @escaping ConfirmationHandler
    ) {
        candidateBuffer = CatSimilarityReviewCandidateBuffer(
            candidates: candidates
        )
        self.currentCandidates = currentCandidates
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
        let preservesCommittedProgress: Bool
        if case .failed = presentation.phase {
            preservesCommittedProgress = !presentation.groups.isEmpty
        } else {
            preservesCommittedProgress = false
        }
        if let discardTask {
            await discardTask.value
            self.discardTask = nil
        }
        candidateBuffer.replaceWithLatest(currentCandidates())
        resetReviewState(preservingReviewCounts: preservesCommittedProgress)
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
        let outcome = await confirmMembership(
            group.instances.map(\.candidate),
            profileIdentifier
        )
        switch CatSimilarityReviewConfirmationTransition.transition(for: outcome) {
        case .advanceCommitted:
            confirmationTracker.recordCommitted(
                profileIdentifier: profileIdentifier,
                candidates: group.instances.map(\.candidate)
            )
            confirmedGroupCount += 1
            advancePastCurrentGroup()
        case .stayForProfileConflict:
            disabledProfileIdentifiersByGroupIdentifier[
                groupIdentifier,
                default: []
            ].insert(profileIdentifier)
            refreshCurrentGroup(
                notice: "この写真にはすでにこの子が設定されています。別の子を選ぶか、「混ざってる」で分けるか、「あとで」を選んでください。"
            )
        case .advanceDeferredStale:
            deferredGroupCount += 1
            advancePastCurrentGroup(
                notice: "写真の情報が更新されたため、前のグループは「あとで」にしました。次のグループへ進みます。"
            )
        case .stayForInvalidGroup:
            refreshCurrentGroup(
                notice: "このグループのままでは保存できません。「混ざってる」で分けるか、「あとで」を選んでください。"
            )
        case .fail:
            presentation = CatSimilarityReviewPresentation(
                phase: .failed(message: "所属を保存できませんでした。もう一度お試しください。"),
                profiles: profiles,
                groups: presentation.groups,
                currentGroupIndex: presentation.currentGroupIndex,
                ungroupedCandidateCount: presentation.ungroupedCandidateCount
            )
        }
    }

    func splitMixedGroup(groupIdentifier: String) async {
        guard let groupID = groupIDByPresentationIdentifier[groupIdentifier],
              presentation.currentGroup?.identifier == groupIdentifier else {
            return
        }
        do {
            let result = try await service.split(groupID: groupID)
            // A group-level conflict may have belonged to only one child.
            // Let the durable guard evaluate each child independently.
            disabledProfileIdentifiersByGroupIdentifier.removeValue(
                forKey: groupIdentifier
            )
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
        let normalizedIndex = min(currentIndex, max(0, groups.count - 1))
        let currentGroupIdentifier = groups.indices.contains(normalizedIndex)
            ? groups[normalizedIndex].identifier
            : nil
        let disabledProfiles = disabledProfileIdentifiers(
            forGroupIdentifier: currentGroupIdentifier
        )
        presentation = CatSimilarityReviewPresentation(
            phase: groups.isEmpty ? .empty : .reviewing,
            profiles: profiles,
            groups: groups,
            currentGroupIndex: normalizedIndex,
            ungroupedCandidateCount: result.ungroupedInstances.count,
            inlineNotice: sessionConflictNotice(for: disabledProfiles),
            disabledProfileIdentifiers: disabledProfiles
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

    private func advancePastCurrentGroup(notice: String? = nil) {
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
                ungroupedCandidateCount: presentation.ungroupedCandidateCount,
                inlineNotice: notice
            )
        } else {
            let nextGroupIdentifier = presentation.groups[nextIndex].identifier
            let disabledProfiles = disabledProfileIdentifiers(
                forGroupIdentifier: nextGroupIdentifier
            )
            presentation = CatSimilarityReviewPresentation(
                phase: .reviewing,
                profiles: profiles,
                groups: presentation.groups,
                currentGroupIndex: nextIndex,
                ungroupedCandidateCount: presentation.ungroupedCandidateCount,
                inlineNotice: combinedNotice(
                    notice,
                    sessionConflictNotice(for: disabledProfiles)
                ),
                disabledProfileIdentifiers: disabledProfiles
            )
        }
    }

    private func refreshCurrentGroup(notice: String) {
        presentation = CatSimilarityReviewPresentation(
            phase: .reviewing,
            profiles: profiles,
            groups: presentation.groups,
            currentGroupIndex: presentation.currentGroupIndex,
            ungroupedCandidateCount: presentation.ungroupedCandidateCount,
            inlineNotice: notice,
            disabledProfileIdentifiers: disabledProfileIdentifiers(
                forGroupIdentifier: presentation.currentGroup?.identifier
            )
        )
    }

    private func disabledProfileIdentifiers(
        forGroupIdentifier groupIdentifier: String?
    ) -> Set<String> {
        guard let groupIdentifier,
              let group = groupByPresentationIdentifier[groupIdentifier] else {
            return []
        }
        var disabled = disabledProfileIdentifiersByGroupIdentifier[
            groupIdentifier
        ] ?? []
        let candidates = group.instances.map(\.candidate)
        for profile in profiles where confirmationTracker.conflicts(
            profileIdentifier: profile.identifier,
            candidates: candidates
        ) {
            disabled.insert(profile.identifier)
        }
        return disabled
    }

    private func sessionConflictNotice(
        for profileIdentifiers: Set<String>
    ) -> String? {
        guard !profileIdentifiers.isEmpty else { return nil }
        let names = profiles.filter {
            profileIdentifiers.contains($0.identifier)
        }.map(\.displayName)
        let label = names.isEmpty
            ? "選択済みの子"
            : names.map { "「\($0)」" }.joined(separator: "・")
        return "同じ写真ですでに\(label)を確認済みのため、そのボタンは選べません。別の子を選ぶか、「混ざってる」で分けるか、「あとで」を選んでください。"
    }

    private func combinedNotice(_ first: String?, _ second: String?) -> String? {
        switch (first, second) {
        case let (first?, second?):
            "\(first)\n\(second)"
        case let (first?, nil):
            first
        case let (nil, second?):
            second
        case (nil, nil):
            nil
        }
    }

    private func resetReviewState(preservingReviewCounts: Bool = false) {
        if !preservingReviewCounts {
            confirmedGroupCount = 0
            deferredGroupCount = 0
        }
        // Confirmed memberships survive an in-screen retry, so the ephemeral
        // asset/profile tracker must survive too. A new screen gets a new model.
        groupIDByPresentationIdentifier.removeAll(keepingCapacity: true)
        presentationIdentifierByGroupID.removeAll(keepingCapacity: true)
        presentationIdentifierByInstanceID.removeAll(keepingCapacity: true)
        groupByPresentationIdentifier.removeAll(keepingCapacity: true)
        disabledProfileIdentifiersByGroupIdentifier.removeAll(keepingCapacity: true)
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
