import SwiftUI

/// All identity-changing actions include the provisional group ID. The View
/// never treats a similarity suggestion as confirmation.
struct CatSimilarityReviewViewActions {
    var startGrouping: () async -> Void
    /// The only callback that authorizes a membership write.
    var confirmGroup: (
        _ groupIdentifier: String,
        _ profileIdentifier: String
    ) async -> Void
    /// Requests a two-way re-cluster; it does not save either half.
    var splitMixedGroup: (_ groupIdentifier: String) async -> Void
    /// Advances without changing membership and keeps the group reviewable.
    var reviewLater: (_ groupIdentifier: String) async -> Void
    /// Cancels only an in-flight FeaturePrint calculation.
    var cancelGrouping: () -> Void
    /// Closes this screen without changing the review-session state.
    var dismiss: () -> Void
    var openProfileSetup: () -> Void

    static let noOp = CatSimilarityReviewViewActions(
        startGrouping: {},
        confirmGroup: { _, _ in },
        splitMixedGroup: { _ in },
        reviewLater: { _ in },
        cancelGrouping: {},
        dismiss: {},
        openProfileSetup: {}
    )
}

struct CatSimilarityReviewView: View {
    let presentation: CatSimilarityReviewPresentation
    let actions: CatSimilarityReviewViewActions

    @State private var pendingActionIdentifier: String?

    var body: some View {
        ScrollView {
            Group {
                switch presentation.displayPhase {
                case let .unavailable(reason):
                    unavailableContent(reason)
                case let .ready(candidateCount, targetGroupCount):
                    readyContent(
                        candidateCount: max(0, candidateCount),
                        targetGroupCount: max(0, targetGroupCount)
                    )
                case .grouping:
                    groupingContent
                case .reviewing:
                    reviewingContent
                case .empty:
                    emptyContent
                case let .failed(message):
                    failedContent(message: message)
                case .cancelled:
                    cancelledContent
                case let .completed(confirmed, deferred):
                    completedContent(
                        confirmedCount: max(0, confirmed),
                        deferredCount: max(0, deferred)
                    )
                }
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .navigationTitle("似た写真をまとめて確認")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("cat-similarity-review")
    }

    @ViewBuilder
    private func unavailableContent(
        _ reason: CatSimilarityReviewUnavailableReason
    ) -> some View {
        switch reason {
        case .noProfiles:
            stateCard(
                title: "先にねこのプロフィールを作ってください",
                systemImage: "cat.fill",
                description: "ねこの名前を登録すると、似た写真をまとめて確認できます。代表写真はあとからでも選べます。"
            ) {
                Button("プロフィールを追加") {
                    actions.openProfileSetup()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("cat-similarity-open-profile-setup")
            }
            .accessibilityIdentifier("cat-similarity-no-profiles")
        }
    }

    private func readyContent(
        candidateCount: Int,
        targetGroupCount: Int
    ) -> some View {
        VStack(spacing: 24) {
            stateHeader(
                title: "似た写真をまとめます",
                systemImage: "square.grid.3x3.fill",
                description: "\(candidateCount.formatted())件の猫を、およそ\(targetGroupCount.formatted())グループにまとめます。多頭写真は、写っている猫ごとに分けて確認します。"
            )

            privacyNotice

            Button {
                performAsync(identifier: "start", action: actions.startGrouping)
            } label: {
                actionLabel(
                    title: "グループを作る",
                    systemImage: "sparkles",
                    actionIdentifier: "start"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(hasPendingAction || candidateCount == 0)
            .accessibilityIdentifier("cat-similarity-start")
        }
        .accessibilityIdentifier("cat-similarity-ready")
    }

    private var groupingContent: some View {
        VStack(spacing: 22) {
            stateHeader(
                title: "似た見た目を比べています",
                systemImage: "sparkles",
                description: "写真は端末の外へ送りません。アプリを閉じると、いったん中止します。"
            )

            if let progress = presentation.generationProgress {
                VStack(spacing: 9) {
                    ProgressView(value: progress.fraction)
                    Text("\(progress.label)件")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("グループ作成 \(progress.label)件")
                .accessibilityIdentifier("cat-similarity-generation-progress")
            }

            Button("キャンセル", role: .cancel) {
                actions.cancelGrouping()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("cat-similarity-cancel")
        }
        .accessibilityIdentifier("cat-similarity-grouping")
    }

    @ViewBuilder
    private var reviewingContent: some View {
        if let group = presentation.currentGroup {
            VStack(spacing: 18) {
                VStack(spacing: 7) {
                    ProgressView(value: presentation.reviewProgress.fraction)
                    Text(presentation.reviewProgress.label)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("確認の進み具合 \(presentation.reviewProgress.label)")
                .accessibilityIdentifier("cat-similarity-review-progress")

                if presentation.ungroupedCandidateCount > 0 {
                    Label(
                        "\(presentation.ungroupedCandidateCount.formatted())件は端末内で画像を取得できず、今回のグループには含まれません。",
                        systemImage: "icloud.slash"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("cat-similarity-ungrouped-count")
                }

                candidateGrid(group)

                Text(presentation.currentQuestion)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("cat-similarity-question")

                if presentation.currentGroupRequiresSplitBeforeConfirmation {
                    Label(
                        "同じ写真の猫が複数入っています。「混ざってる」で分けてから確認してください。",
                        systemImage: "arrow.triangle.branch"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("cat-similarity-split-required")
                }

                if let notice = presentation.inlineNotice, !notice.isEmpty {
                    Label(notice, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            .orange.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .accessibilityIdentifier("cat-similarity-inline-notice")
                }

                profileConfirmationButtons(group: group)

                Divider()

                if group.candidates.count >= 2 {
                    Button {
                        performAsync(identifier: "split:\(group.identifier)") {
                            await actions.splitMixedGroup(group.identifier)
                        }
                    } label: {
                        actionLabel(
                            title: "混ざってる",
                            systemImage: "arrow.triangle.branch",
                            actionIdentifier: "split:\(group.identifier)"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(hasPendingAction)
                    .accessibilityHint("このグループを2つに分けます")
                    .accessibilityIdentifier("cat-similarity-split-group")
                }

                Button {
                    performAsync(identifier: "later:\(group.identifier)") {
                        await actions.reviewLater(group.identifier)
                    }
                } label: {
                    actionLabel(
                        title: "あとで",
                        systemImage: "clock",
                        actionIdentifier: "later:\(group.identifier)"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(hasPendingAction)
                .accessibilityIdentifier("cat-similarity-review-later")

                Button("閉じる", role: .cancel) {
                    actions.dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(hasPendingAction)
                .accessibilityIdentifier("cat-similarity-review-dismiss")

                Text("ボタンを押すまで、どの写真の所属も変わりません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("cat-similarity-confirmation-guard")
            }
            .accessibilityIdentifier("cat-similarity-current-group")
        } else {
            stateCard(
                title: "グループを表示できません",
                systemImage: "exclamationmark.triangle",
                description: "確認データを読み直して、もう一度お試しください。"
            ) {
                Button("もう一度") {
                    performAsync(identifier: "reload", action: actions.startGrouping)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("cat-similarity-reload")
            }
        }
    }

    private func candidateGrid(
        _ group: CatSimilarityReviewGroupPresentation
    ) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ],
            spacing: 8
        ) {
            ForEach(group.candidates.indices, id: \.self) { index in
                let candidate = group.candidates[index]
                PhotoAssetImageView(
                    localIdentifier: candidate.assetLocalIdentifier,
                    catBoundingBox: candidate.subjectBoundingBox,
                    targetPixelSize: CGSize(width: 360, height: 360),
                    targetAspectRatio: 1
                )
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                }
                .accessibilityLabel("グループ内の猫 \((index + 1).formatted())")
                .accessibilityIdentifier(
                    "cat-similarity-candidate-\(candidate.identifier)"
                )
            }
        }
        .accessibilityIdentifier("cat-similarity-candidate-grid")
    }

    private func profileConfirmationButtons(
        group: CatSimilarityReviewGroupPresentation
    ) -> some View {
        VStack(spacing: 10) {
            ForEach(presentation.profilesForCurrentQuestion) { profile in
                let actionIdentifier = "confirm:\(group.identifier):\(profile.identifier)"
                Button {
                    performAsync(identifier: actionIdentifier) {
                        await actions.confirmGroup(
                            group.identifier,
                            profile.identifier
                        )
                    }
                } label: {
                    HStack(spacing: 12) {
                        profileIcon(profile)
                            .frame(width: 42, height: 42)

                        Text("全部「\(profile.displayName)」")
                            .font(.headline)

                        Spacer()

                        if pendingActionIdentifier == actionIdentifier {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 58)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    hasPendingAction
                        || presentation.profileConfirmationIsDisabled(
                            profile.identifier
                        )
                )
                .accessibilityLabel("このグループは全部\(profile.displayName)")
                .accessibilityIdentifier(
                    "cat-similarity-confirm-\(profile.identifier)"
                )
            }

            if presentation.profilesForCurrentQuestion.isEmpty {
                Text("確認先のプロフィールがありません。設定からねこのプロフィールを追加してください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("cat-similarity-review-no-profiles")
            }
        }
    }

    private var emptyContent: some View {
        stateCard(
            title: "まとめられる写真がありません",
            systemImage: "photo.on.rectangle.angled",
            description: "未確認の猫が増えたら、ここから似た写真をまとめられます。"
        ) {
            closeButton
        }
        .accessibilityIdentifier("cat-similarity-empty")
    }

    private func failedContent(message: String) -> some View {
        stateCard(
            title: "グループを作れませんでした",
            systemImage: "exclamationmark.triangle",
            description: message.isEmpty
                ? "時間をおいて、もう一度お試しください。"
                : message
        ) {
            VStack(spacing: 12) {
                Button {
                    performAsync(identifier: "retry", action: actions.startGrouping)
                } label: {
                    actionLabel(
                        title: "もう一度",
                        systemImage: "arrow.clockwise",
                        actionIdentifier: "retry"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(hasPendingAction)
                .accessibilityIdentifier("cat-similarity-retry")

                closeButton
            }
        }
        .accessibilityIdentifier("cat-similarity-failed")
    }

    private var cancelledContent: some View {
        stateCard(
            title: "確認を中止しました",
            systemImage: "pause.circle",
            description: "所属は変更されていません。いつでも最初からやり直せます。"
        ) {
            VStack(spacing: 12) {
                Button {
                    performAsync(identifier: "restart", action: actions.startGrouping)
                } label: {
                    actionLabel(
                        title: "もう一度まとめる",
                        systemImage: "arrow.clockwise",
                        actionIdentifier: "restart"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(hasPendingAction)
                .accessibilityIdentifier("cat-similarity-restart")

                closeButton
            }
        }
        .accessibilityIdentifier("cat-similarity-cancelled")
    }

    private func completedContent(
        confirmedCount: Int,
        deferredCount: Int
    ) -> some View {
        let reviewSummary = deferredCount == 0
            ? "\(confirmedCount.formatted())グループを確認しました。"
            : "\(confirmedCount.formatted())グループを確認し、\(deferredCount.formatted())グループをあとに残しました。"
        let availabilitySummary = presentation.ungroupedCandidateCount == 0
            ? ""
            : " \(presentation.ungroupedCandidateCount.formatted())件は端末内で画像を取得できなかったため、所属を変更していません。"
        let noticeSummary = presentation.inlineNotice.map { " \($0)" } ?? ""
        return stateCard(
            title: "確認できました",
            systemImage: "checkmark.circle.fill",
            description: reviewSummary + availabilitySummary + noticeSummary
        ) {
            closeButton
        }
        .accessibilityIdentifier("cat-similarity-completed")
    }

    private var privacyNotice: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("端末内だけで似た見た目を比較します")
                    .font(.headline)
                Text("確認するまで、どの写真の所属も変わりません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "lock.iphone")
                .foregroundStyle(.tint)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cat-similarity-privacy-notice")
    }

    private func stateHeader(
        title: String,
        systemImage: String,
        description: String
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 45, weight: .semibold))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    private func stateCard<Actions: View>(
        title: String,
        systemImage: String,
        description: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 24) {
            stateHeader(
                title: title,
                systemImage: systemImage,
                description: description
            )
            actions()
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    @ViewBuilder
    private func profileIcon(
        _ profile: CatSimilarityReviewProfilePresentation
    ) -> some View {
        if let candidate = profile.coverCandidate {
            PhotoAssetImageView(
                localIdentifier: candidate.assetLocalIdentifier,
                catBoundingBox: candidate.subjectBoundingBox,
                targetPixelSize: CGSize(width: 180, height: 180),
                targetAspectRatio: 1
            )
            .aspectRatio(1, contentMode: .fill)
            .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(.secondary.opacity(0.14))
                Image(systemName: "cat.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var closeButton: some View {
        Button("閉じる") {
            actions.dismiss()
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("cat-similarity-close")
    }

    private func actionLabel(
        title: String,
        systemImage: String,
        actionIdentifier: String
    ) -> some View {
        HStack(spacing: 9) {
            if pendingActionIdentifier == actionIdentifier {
                ProgressView()
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
        }
    }

    private var hasPendingAction: Bool {
        pendingActionIdentifier != nil
    }

    private func performAsync(
        identifier: String,
        action: @escaping () async -> Void
    ) {
        guard pendingActionIdentifier == nil else { return }
        pendingActionIdentifier = identifier
        Task { @MainActor in
            await action()
            pendingActionIdentifier = nil
        }
    }
}
