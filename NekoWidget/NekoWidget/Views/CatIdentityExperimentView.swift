import SwiftUI
import UIKit

/// Diagnostic-only household separability measurement. It never writes cat
/// memberships or turns an experimental prediction into a training sample.
struct CatIdentityExperimentView: View {
    let presentation: CatProfilesPresentation

    @StateObject private var model = CatIdentityExperimentViewModel()
    @State private var selectedPhotoIDsByProfile: [String: Set<String>] = [:]
    @State private var exportedFile: CatIdentityExperimentExportedFile?
    @State private var exportErrorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 4)]

    var body: some View {
        Group {
            if presentation.profiles.count == 2 {
                experimentForm
            } else {
                ContentUnavailableView(
                    "2匹の家庭だけ計測できます",
                    systemImage: "pawprint",
                    description: Text(
                        "この実験は2プロフィール×5枚に固定しています。プロフィールが2つのときだけ実行できます。"
                    )
                )
            }
        }
        .navigationTitle("猫の見分け実験")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exportedFile) { file in
            CatIdentityExperimentActivityView(activityItems: [file.url])
                .presentationDetents([.medium, .large])
        }
        .alert("書き出せませんでした", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "集計結果を作れませんでした。")
        }
        .onDisappear {
            model.cancel()
        }
    }

    private var experimentForm: some View {
        Form {
            Section {
                Label("これは計測だけです", systemImage: "ruler")
                    .font(.headline)
                Text(
                    "選んだ各5枚を正解例にして、bboxの猫だけを比較します。低確信は「わからない」にし、写真の所属は1枚も変更しません。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } footer: {
                Text(
                    "Build 18もbbox切り抜きでしたが、教師なしで20群へ強制分割していました。今回は正解例とunknownを使う別の実験です。"
                )
            }

            ForEach(presentation.profiles) { profile in
                referenceSection(profile: profile)
            }

            if hasKnownEpisodeConflict {
                Section {
                    Label(
                        "同じ猫で30秒以内に撮った写真があります。別の場面の写真を選んでください。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section {
                if model.isRunning, let progress = model.progress {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(progressTitle(progress.phase))
                            .font(.headline)
                        ProgressView(
                            value: Double(progress.completedUnitCount),
                            total: Double(max(1, progress.totalUnitCount))
                        )
                        Text(
                            "\(progress.completedUnitCount.formatted()) / \(progress.totalUnitCount.formatted())"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    Button("キャンセル", role: .cancel) {
                        model.cancel()
                    }
                } else {
                    Button {
                        startExperiment()
                    } label: {
                        Label("10枚で計測する", systemImage: "waveform.path.ecg")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                    .accessibilityIdentifier("cat-identity-experiment-start")
                }
            } header: {
                Text("計測")
            } footer: {
                Text(
                    "未確認の\(presentation.similarityCandidates.count.formatted())件にも読み取り専用で適用し、何割を安全に振り分けられそうか数えます。端末内にない写真はダウンロードしません。"
                )
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if let report = model.report {
                resultSections(report)
            }
        }
    }

    @ViewBuilder
    private func referenceSection(profile: CatProfilePresentation) -> some View {
        let photos = eligiblePhotos(for: profile)
        let selected = selectedPhotoIDs(for: profile)
        Section {
            if photos.isEmpty {
                ContentUnavailableView(
                    "使える確認済み写真がありません",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text(
                        "「思い出」から、この猫だけが写る写真を確認済みにしてください。"
                    )
                )
            } else {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(photos) { photo in
                        referencePhotoButton(
                            photo: photo,
                            profile: profile,
                            selection: selected
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack {
                Text(profile.displayName)
                Spacer()
                Text("\(selected.count) / 5")
                    .monospacedDigit()
            }
        } footer: {
            Text(
                photos.count >= 5
                    ? "連写ではなく、時期・明るさ・姿勢が違う5枚を選んでください。"
                    : "単独で写る撮影日付きの確認済み写真があと\((5 - photos.count).clampedToNonnegative().formatted())枚必要です。"
            )
        }
    }

    private func referencePhotoButton(
        photo: CatProfilePhotoPresentation,
        profile: CatProfilePresentation,
        selection: Set<String>
    ) -> some View {
        let isSelected = selection.contains(photo.localIdentifier)
        let selectionIsFull = selection.count >= 5
        return Button {
            toggle(photo: photo, for: profile)
        } label: {
            ZStack(alignment: .topTrailing) {
                PhotoAssetImageView(
                    localIdentifier: photo.localIdentifier,
                    catBoundingBox: photo.catBoundingBox,
                    targetPixelSize: CGSize(width: 320, height: 320),
                    targetAspectRatio: 1,
                    networkAccessAllowed: false
                )
                .aspectRatio(1, contentMode: .fit)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.title3)
                    .shadow(radius: 2)
                    .padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                Text(
                    photo.creationDate?.formatted(
                        .dateTime.year().month(.abbreviated)
                    ) ?? "日付不明"
                )
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(5)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isRunning || (selectionIsFull && !isSelected))
        .accessibilityLabel(referenceAccessibilityLabel(photo))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func resultSections(_ report: CatIdentityExperimentReport)
        -> some View {
        Section {
            Label(decisionTitle(report.decision), systemImage: decisionSymbol(report.decision))
                .font(.headline)
                .foregroundStyle(decisionColor(report.decision))
            Text(decisionDetail(report.decision))
                .font(.footnote)
                .foregroundStyle(.secondary)
            LabeledContent("正解例", value: "\(report.input.referenceCount)枚")
            LabeledContent(
                "独立した場面",
                value: "各猫\(report.input.minimumIndependentEpisodesPerProfile)件"
            )
            LabeledContent(
                "未確認候補",
                value: "\(report.input.candidateCount.formatted())件"
            )
        } header: {
            Text("結論")
        } footer: {
            Text("この結果だけで一般家庭向けの精度は証明できません。製品UIはまだ有効にしません。")
        }

        ForEach(report.methods, id: \.method) { methodReport in
            methodSection(methodReport)
        }

        Section {
            Button {
                do {
                    let url = try CatIdentityExperimentExporter().export(report)
                    exportedFile = CatIdentityExperimentExportedFile(url: url)
                } catch {
                    exportErrorMessage = "集計JSONを作れませんでした。もう一度お試しください。"
                }
            } label: {
                Label("集計結果を共有", systemImage: "square.and.arrow.up")
            }
        } footer: {
            Text("写真、猫の名前、プロフィールID、PhotoKit ID、撮影日時、bbox、特徴量、個別距離は含みません。")
        }
    }

    @ViewBuilder
    private func methodSection(_ method: CatIdentityExperimentMethodReport)
        -> some View {
        Section {
            LabeledContent(
                "10枚のtop-1正解",
                value: "\(method.loo.top1CorrectCount) / \(method.loo.trialCount)"
            )
            LabeledContent(
                "確定 / unknown / 誤り",
                value: "\(method.loo.assignedCount) / \(method.loo.unknownCount) / \(method.loo.wrongAssignedCount)"
            )
            LabeledContent(
                "正解例のcoverage",
                value: percentage(method.loo.coverage)
            )
            LabeledContent(
                "FAR / FRR",
                value: "\(percentage(method.loo.falseAcceptRate)) / \(percentage(method.loo.falseRejectRate))"
            )
            LabeledContent(
                "読み取れない正解例",
                value: "\(method.referenceFeatureUnavailableCount)件"
            )
            ForEach(method.loo.profiles, id: \.profileIndex) { profileResult in
                let name = profileName(at: profileResult.profileIndex)
                LabeledContent(
                    name,
                    value: "正解\(profileResult.correctAssignedCount)・unknown\(profileResult.unknownCount)・誤り\(profileResult.wrongAssignedCount)"
                )
            }
            LabeledContent(
                "未確認の確定 / unknown",
                value: "\(method.candidates.assignedCount) / \(method.candidates.unknownCount)"
            )
            LabeledContent(
                "未確認instance coverage",
                value: percentage(method.candidates.coverage)
            )
            LabeledContent(
                "未確認episode coverage",
                value: percentage(method.candidates.episodeCoverage)
            )
            LabeledContent(
                "読み取れない候補 / 同一写真の衝突",
                value: "\(method.candidates.featureUnavailableCount) / \(method.candidates.collisionAssetCount)"
            )
            LabeledContent(
                "同猫距離 P50 / P90",
                value: distancePair(
                    method.distanceSummary.sameProfileMedian,
                    method.distanceSummary.sameProfileP90
                )
            )
            LabeledContent(
                "別猫距離 P10 / P50",
                value: distancePair(
                    method.distanceSummary.differentProfileP10,
                    method.distanceSummary.differentProfileMedian
                )
            )
            if method.method == .hsvHistogramExact {
                LabeledContent(
                    "色の分離比",
                    value: method.colorSeparationRatio.map {
                        $0.formatted(.number.precision(.fractionLength(2)))
                    } ?? (method.colorDistributionsAreDisjoint == true ? "∞" : "計測不能")
                )
            }
            Label(
                method.passesPerformanceGate ? "基準内" : "基準外",
                systemImage: method.passesPerformanceGate
                    ? "checkmark.circle.fill"
                    : "xmark.circle"
            )
            .foregroundStyle(
                method.passesPerformanceGate ? Color.green : Color.secondary
            )
        } header: {
            Text(methodTitle(method.method))
        }
    }

    private var canStart: Bool {
        presentation.profiles.allSatisfy {
            selectedPhotoIDs(for: $0).count == 5
        } && !hasKnownEpisodeConflict && !model.isRunning
    }

    private var hasKnownEpisodeConflict: Bool {
        presentation.profiles.contains { profile in
            let dates = eligiblePhotos(for: profile).filter {
                selectedPhotoIDs(for: profile).contains($0.localIdentifier)
            }.compactMap(\.creationDate).sorted()
            return zip(dates, dates.dropFirst()).contains { pair in
                pair.1.timeIntervalSince(pair.0) <= 30
            }
        }
    }

    private func eligiblePhotos(
        for profile: CatProfilePresentation
    ) -> [CatProfilePhotoPresentation] {
        profile.confirmedPhotos.filter { photo in
            photo.detectedCatCount <= 1
                && photo.catBoundingBox != nil
                && photo.creationDate != nil
                && photo.assignedProfileIdentifiers == [profile.identifier]
        }
    }

    private func selectedPhotoIDs(
        for profile: CatProfilePresentation
    ) -> Set<String> {
        selectedPhotoIDsByProfile[profile.identifier] ?? []
    }

    private func toggle(
        photo: CatProfilePhotoPresentation,
        for profile: CatProfilePresentation
    ) {
        var selected = selectedPhotoIDs(for: profile)
        if selected.contains(photo.localIdentifier) {
            selected.remove(photo.localIdentifier)
        } else if selected.count < 5 {
            selected.insert(photo.localIdentifier)
        }
        selectedPhotoIDsByProfile[profile.identifier] = selected
        model.resetResult()
    }

    private func startExperiment() {
        let profiles = presentation.profiles
        let references = profiles.enumerated().flatMap { entry in
            let profileIndex = entry.offset
            let profile = entry.element
            return eligiblePhotos(for: profile)
                .filter {
                    selectedPhotoIDs(for: profile).contains($0.localIdentifier)
                }
                .sorted { $0.localIdentifier < $1.localIdentifier }
                .compactMap { photo -> CatIdentityExperimentReferenceInput? in
                    guard let box = photo.catBoundingBox else { return nil }
                    return CatIdentityExperimentReferenceInput(
                        profileIndex: profileIndex,
                        assetLocalIdentifier: photo.localIdentifier,
                        boundingBox: NormalizedRect(box)
                    )
                }
        }
        let candidates = presentation.similarityCandidates.map {
            CatIdentityExperimentCandidateInput(
                assetLocalIdentifier: $0.assetLocalIdentifier,
                boundingBox: $0.boundingBox
            )
        }
        model.start(references: references, candidates: candidates)
    }

    private func profileName(at index: Int) -> String {
        guard presentation.profiles.indices.contains(index) else {
            return "猫\(index + 1)"
        }
        return presentation.profiles[index].displayName
    }

    private func referenceAccessibilityLabel(
        _ photo: CatProfilePhotoPresentation
    ) -> String {
        photo.creationDate?.formatted(date: .abbreviated, time: .omitted)
            ?? "撮影日不明"
    }

    private func progressTitle(
        _ phase: CatIdentityExperimentProgressPhase
    ) -> String {
        switch phase {
        case .loadingAssets: "端末内の写真を読み込んでいます"
        case .extractingFeatures: "bboxの猫を比較しています"
        case .evaluating: "結果を集計しています"
        }
    }

    private func decisionTitle(_ decision: CatIdentityExperimentDecision) -> String {
        switch decision {
        case .featurePrintExact: "exact bbox FeaturePrintは次の検証候補"
        case .histogramOnly: "色が違う家庭だけ次の検証候補"
        case .noGo: "個体推定のUIは出さない"
        }
    }

    private func decisionDetail(_ decision: CatIdentityExperimentDecision) -> String {
        switch decision {
        case .featurePrintExact:
            "この家庭では、余白なしbboxのFeaturePrintが固定基準を通りました。"
        case .histogramOnly:
            "FeaturePrintは基準外ですが、色ヒストグラムは固定基準を通りました。"
        case .noGo:
            "誤所属を避けるため、「この家の猫たち」の成長だけで成立させます。"
        }
    }

    private func decisionSymbol(_ decision: CatIdentityExperimentDecision) -> String {
        switch decision {
        case .featurePrintExact: "checkmark.seal.fill"
        case .histogramOnly: "paintpalette.fill"
        case .noGo: "hand.raised.fill"
        }
    }

    private func decisionColor(_ decision: CatIdentityExperimentDecision) -> Color {
        switch decision {
        case .featurePrintExact: .green
        case .histogramOnly: .orange
        case .noGo: .secondary
        }
    }

    private func methodTitle(_ method: CatIdentityExperimentMethod) -> String {
        switch method {
        case .featurePrintExpanded10: "FeaturePrint（従来のbbox＋10%）"
        case .featurePrintExact: "FeaturePrint（exact bbox）"
        case .hsvHistogramExact: "色ヒストグラム（exact bbox）"
        }
    }

    private func percentage(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func distancePair(_ first: Double?, _ second: Double?) -> String {
        guard let first, let second else { return "計測不能" }
        return "\(distance(first)) / \(distance(second))"
    }

    private func distance(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(3)))
    }
}

@MainActor
private final class CatIdentityExperimentViewModel: ObservableObject {
    @Published private(set) var progress: CatIdentityExperimentProgress?
    @Published private(set) var report: CatIdentityExperimentReport?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false

    private let service = CatIdentityExperimentService()
    private var runTask: Task<Void, Never>?
    private var runRevision = 0

    func start(
        references: [CatIdentityExperimentReferenceInput],
        candidates: [CatIdentityExperimentCandidateInput]
    ) {
        runRevision += 1
        let revision = runRevision
        runTask?.cancel()
        runTask = nil
        isRunning = true
        progress = nil
        report = nil
        errorMessage = nil
        let service = self.service
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                await service.discard()
                guard self.runRevision == revision else { return }
                let result = try await service.run(
                    references: references,
                    candidates: candidates,
                    progress: { [weak self] progress in
                        await self?.receive(progress, revision: revision)
                    }
                )
                guard self.runRevision == revision else { return }
                self.report = result
                self.progress = nil
                self.isRunning = false
            } catch is CancellationError {
                guard self.runRevision == revision else { return }
                self.progress = nil
                self.isRunning = false
            } catch {
                guard self.runRevision == revision else { return }
                self.progress = nil
                self.isRunning = false
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    func cancel() {
        runRevision += 1
        runTask?.cancel()
        runTask = nil
        isRunning = false
        progress = nil
    }

    func resetResult() {
        guard !isRunning else { return }
        report = nil
        errorMessage = nil
    }

    private func receive(
        _ progress: CatIdentityExperimentProgress,
        revision: Int
    ) {
        guard runRevision == revision else { return }
        self.progress = progress
    }

    private static func message(for error: Error) -> String {
        if let serviceError = error as? CatIdentityExperimentServiceError {
            switch serviceError {
            case .invalidInput, .duplicateReference, .duplicateCandidate:
                return "選んだ写真を計測に使えませんでした。各猫5枚を選び直してください。"
            case .colorSpaceUnavailable:
                return "写真の色を端末内で読み取れませんでした。"
            }
        }
        if let coreError = error as? CatIdentityExperimentCoreError {
            switch coreError {
            case .invalidReferenceSet:
                return "連写やほぼ同じ写真が含まれています。各猫について、別の場面の5枚を選んでください。"
            default:
                return "距離の集計に失敗しました。写真を選び直して、もう一度お試しください。"
            }
        }
        return "計測できませんでした。写真を選び直して、もう一度お試しください。"
    }
}

private struct CatIdentityExperimentExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct CatIdentityExperimentActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private extension Int {
    func clampedToNonnegative() -> Int { Swift.max(0, self) }
}
