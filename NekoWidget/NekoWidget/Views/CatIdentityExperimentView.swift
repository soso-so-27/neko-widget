import SwiftUI
import UIKit

private struct CatIdentityExperimentSelectablePhoto: Identifiable, Equatable {
    let id: String
    let assetLocalIdentifier: String
    let boundingBox: CGRect
    let creationDate: Date
}

private struct CatIdentityCloseCaptureAdvisory: Identifiable {
    let profileIdentifier: String
    let profileName: String
    let firstPhotoID: String
    let secondPhotoID: String
    let firstSlot: String
    let secondSlot: String
    let firstDate: Date
    let secondDate: Date

    var id: String {
        [profileName, firstPhotoID, secondPhotoID].joined(separator: "|")
    }

    var intervalInSeconds: Int {
        Int(secondDate.timeIntervalSince(firstDate).rounded())
    }
}

private struct CatIdentityPhotoSelectionKey: Hashable {
    let profileIdentifier: String
    let photoID: String
}

/// Diagnostic-only household separability measurement. It never writes cat
/// memberships or turns an experimental prediction into a training sample.
struct CatIdentityExperimentView: View {
    let presentation: CatProfilesPresentation

    @StateObject private var model = CatIdentityExperimentViewModel()
    @State private var selectedPhotoIDsByProfile: [String: [String]] = [:]
    @State private var evaluationPhotosByOrdinal: [
        Int: CatIdentityExperimentSelectablePhoto
    ] = [:]
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
                        "この実験は2プロフィール×20枚に固定しています。プロフィールが2つのときだけ実行できます。"
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
            evaluationPhotosByOrdinal = [:]
        }
        .onChange(of: model.errorMessage) { _, message in
            if message != nil {
                evaluationPhotosByOrdinal = [:]
            }
        }
    }

    private var experimentForm: some View {
        Form {
            Section {
                Label("これは計測だけです", systemImage: "ruler")
                    .font(.headline)
                Text(
                    "各猫20枚をラベル付けし、最初の5枚だけで学習します。残り15枚は答えを隠して評価し、低確信は「わからない」にします。写真の所属は1枚も変更しません。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } footer: {
                Text(
                    "Build 18もbbox切り抜きでしたが、教師なしで20群へ強制分割していました。今回は学習10枚と独立した評価30枚を使う別の実験です。"
                )
            }

            ForEach(presentation.profiles) { profile in
                referenceSection(profile: profile)
            }

            if !closeCaptureAdvisories.isEmpty {
                Section {
                    Label(
                        "撮影日時が近い写真があります（計測はできます）",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)

                    ForEach(Array(closeCaptureAdvisories.prefix(4))) { advisory in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                "\(advisory.profileName)  \(advisory.firstSlot) ↔ \(advisory.secondSlot)（\(advisory.intervalInSeconds)秒差）"
                            )
                            .font(.subheadline.weight(.semibold))
                            Text(
                                "\(exactCaptureDate(advisory.firstDate)) / \(exactCaptureDate(advisory.secondDate))"
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }

                    if closeCaptureAdvisories.count > 4 {
                        Text("ほか\((closeCaptureAdvisories.count - 4).formatted())組")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("オレンジ枠の写真が連写やほぼ同じ場面なら、片方を替えると結果がより確かになります。撮影日時だけでは停止しません。")
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
                        evaluationPhotosByOrdinal = [:]
                    }
                } else {
                    Button {
                        startExperiment()
                    } label: {
                        Label("40枚で計測する", systemImage: "waveform.path.ecg")
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

                    ForEach(model.duplicateSelectionPairs, id: \.self) { pair in
                        if let first = labeledSelectionDescription(
                            ordinal: pair.firstOrdinal
                        ), let second = labeledSelectionDescription(
                            ordinal: pair.secondOrdinal
                        ) {
                            Text("\(first) ↔ \(second)")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                } footer: {
                    if !model.duplicateSelectionPairs.isEmpty {
                        Text("赤枠の2枚は同じ猫の連写またはほぼ同じ写真です。どちらか片方を外して、別の場面を選んでください。")
                    }
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
        let advisoryPhotoKeys = closeCapturePhotoKeys
        let duplicatePhotoKeys = duplicateSelectionPhotoKeys
        let selectedAssetIdentifiers = Set(
            presentation.profiles.flatMap { selectedProfile in
                selectedPhotos(for: selectedProfile).map(\.assetLocalIdentifier)
            }
        )
        Section {
            if photos.isEmpty {
                ContentUnavailableView(
                    "使える確認済み写真がありません",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text(
                        "「設定」→「ねこのプロフィール」から、この猫だけが写る写真を確認済みにしてください。"
                    )
                )
            } else {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(photos) { photo in
                        referencePhotoButton(
                            photo: photo,
                            profile: profile,
                            selection: selected,
                            hasCloseCaptureAdvisory:
                                advisoryPhotoKeys.contains(
                                    CatIdentityPhotoSelectionKey(
                                        profileIdentifier: profile.identifier,
                                        photoID: photo.id
                                    )
                                ),
                            hasHardDuplicate:
                                duplicatePhotoKeys.contains(
                                    CatIdentityPhotoSelectionKey(
                                        profileIdentifier: profile.identifier,
                                        photoID: photo.id
                                    )
                                ),
                            selectedAssetIdentifiers: selectedAssetIdentifiers
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack {
                Text(profile.displayName)
                Spacer()
                Text("\(selected.count) / 20")
                    .monospacedDigit()
            }
        } footer: {
            Text(
                photos.count >= 20
                    ? "先に代表的な5枚、続けて評価用15枚を選びます。評価用は古い／新しい、明るい／暗い写真を散らし、後ろ姿・横顔・遠い・一部が隠れた写真も入れてください。"
                    : "単独で写る撮影日付きの写真があと\((20 - photos.count).clampedToNonnegative().formatted())枚必要です。"
            )
        }
    }

    private func referencePhotoButton(
        photo: CatIdentityExperimentSelectablePhoto,
        profile: CatProfilePresentation,
        selection: [String],
        hasCloseCaptureAdvisory: Bool,
        hasHardDuplicate: Bool,
        selectedAssetIdentifiers: Set<String>
    ) -> some View {
        let selectedIndex = selection.firstIndex(of: photo.id)
        let isSelected = selectedIndex != nil
        let selectionIsFull = selection.count >= 20
        let isAssetSelectedByAnotherPhoto = !isSelected
            && selectedAssetIdentifiers.contains(photo.assetLocalIdentifier)
        return Button {
            toggle(photo: photo, for: profile)
        } label: {
            ZStack(alignment: .topTrailing) {
                PhotoAssetImageView(
                    localIdentifier: photo.assetLocalIdentifier,
                    catBoundingBox: photo.boundingBox,
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
            .overlay(alignment: .topLeading) {
                if let selectedIndex {
                    Text(selectedIndex < 5 ? "学習\(selectedIndex + 1)" : "評価\(selectedIndex - 4)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            selectedIndex < 5
                                ? Color.blue.opacity(0.88)
                                : Color.purple.opacity(0.88),
                            in: Capsule()
                        )
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(
                    photo.creationDate.formatted(
                        .dateTime.year().month(.abbreviated)
                    )
                )
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(5)
            }
            .overlay {
                Rectangle()
                    .stroke(
                        hasHardDuplicate
                            ? Color.red
                            : hasCloseCaptureAdvisory
                                ? Color.orange
                                : Color.clear,
                        lineWidth: 3
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(
            model.isRunning
                || model.report != nil
                || (!isSelected && isAssetSelectedByAnotherPhoto)
                || (selectionIsFull && !isSelected)
        )
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
            LabeledContent("学習", value: "\(report.input.referenceCount)枚")
            LabeledContent("評価", value: "\(report.input.evaluationCount)枚")
            LabeledContent(
                "独立した場面",
                value: "合計\(report.input.totalIndependentEpisodeCount)件"
            )
            LabeledContent(
                "学習 / 評価（各猫）",
                value: "\(report.input.minimumTrainingEpisodesPerProfile) / \(report.input.minimumEvaluationEpisodesPerProfile)件"
            )
            LabeledContent(
                "未確認候補",
                value: "\(report.input.candidateCount.formatted())件"
            )
            LabeledContent(
                "見た目の分離",
                value: report.colorEligibilityGatePassed ? "基準内" : "基準外"
            )
        } header: {
            Text("結論")
        } footer: {
            Text("最終候補には評価30枚の基準に加え、色の学習10枚が10/10で分かれ、分離比1.5以上であることも必要です。この結果だけで一般家庭向けの精度は証明できず、製品UIはまだ有効にしません。")
        }

        ForEach(report.methods, id: \.method) { methodReport in
            methodSection(methodReport)
            wrongEvaluationSection(for: methodReport.method)
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
    private func wrongEvaluationSection(
        for method: CatIdentityExperimentMethod
    ) -> some View {
        let ordinals = model.localDetail?
            .wrongEvaluationOrdinalsByMethod[method] ?? []
        if !ordinals.isEmpty {
            Section {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(ordinals, id: \.self) { ordinal in
                        if let photo = evaluationPhotosByOrdinal[ordinal] {
                            ZStack(alignment: .bottomLeading) {
                                PhotoAssetImageView(
                                    localIdentifier: photo.assetLocalIdentifier,
                                    catBoundingBox: photo.boundingBox,
                                    targetPixelSize: CGSize(
                                        width: 320,
                                        height: 320
                                    ),
                                    targetAspectRatio: 1,
                                    networkAccessAllowed: false
                                )
                                .aspectRatio(1, contentMode: .fit)

                                Text("正解：\(profileName(at: ordinal / 15))")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(.red.opacity(0.82), in: Capsule())
                                    .padding(5)
                            }
                        }
                    }
                }
            } header: {
                Text("誤判定を目視：\(methodTitle(method))")
            } footer: {
                Text("この写真は端末内だけで表示し、集計JSONには含めません。結果を見て同じ計測の写真を差し替えると精度を過大評価するため、差し替えて再合格にはしません。")
            }
        }
    }

    @ViewBuilder
    private func methodSection(_ method: CatIdentityExperimentMethodReport)
        -> some View {
        Section {
            LabeledContent(
                "正解率",
                value: fractionAndPercentage(
                    numerator: method.evaluation.correctAssignedCount,
                    denominator: method.evaluation.assignedCount,
                    rate: method.evaluation.precision
                )
            )
            LabeledContent(
                "判定できた割合",
                value: fractionAndPercentage(
                    numerator: method.evaluation.assignedCount,
                    denominator: method.evaluation.trialCount,
                    rate: method.evaluation.coverage
                )
            )
            LabeledContent(
                "正解 / 誤り / unknown",
                value: "\(method.evaluation.correctAssignedCount) / \(method.evaluation.wrongAssignedCount) / \(method.evaluation.unknownCount)"
            )
            ForEach(method.evaluation.profiles, id: \.profileIndex) {
                profileResult in
                let name = profileName(at: profileResult.profileIndex)
                LabeledContent(
                    name,
                    value: profileEvaluationSummary(profileResult)
                )
            }
            LabeledContent(
                "学習10枚の自己整合",
                value: "top-1 \(method.loo.top1CorrectCount) / \(method.loo.trialCount)"
            )
            LabeledContent(
                "学習で読み取れない写真",
                value: "\(method.referenceFeatureUnavailableCount)件"
            )
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
                method.passesEvaluationGate ? "評価30枚の基準内" : "評価30枚の基準外",
                systemImage: method.passesEvaluationGate
                    ? "checkmark.circle.fill"
                    : "xmark.circle"
            )
            .foregroundStyle(
                method.passesEvaluationGate ? Color.green : Color.secondary
            )
        } header: {
            Text(methodTitle(method.method))
        } footer: {
            Text("この方式の評価基準は30枚全体で正解率95%以上、判定率70%以上です。猫別の数字は偏りの確認用です。最終候補には結論欄の『見た目の分離』も必要です。")
        }
    }

    private var canStart: Bool {
        presentation.profiles.allSatisfy {
            selectedPhotoIDs(for: $0).count == 20
        } && !model.isRunning
            && model.report == nil
    }

    private var closeCaptureAdvisories: [CatIdentityCloseCaptureAdvisory] {
        presentation.profiles.flatMap { profile in
            let selected = selectedPhotos(for: profile)
            let slotsByID = Dictionary(
                uniqueKeysWithValues: selected.enumerated().map { index, photo in
                    (
                        photo.id,
                        index < 5 ? "学習\(index + 1)" : "評価\(index - 4)"
                    )
                }
            )
            let dated = selected.sorted { lhs, rhs in
                if lhs.creationDate != rhs.creationDate {
                    return lhs.creationDate < rhs.creationDate
                }
                return lhs.id < rhs.id
            }
            return dated.indices.flatMap { firstIndex in
                var advisories: [CatIdentityCloseCaptureAdvisory] = []
                var secondIndex = firstIndex + 1
                while secondIndex < dated.count,
                      dated[secondIndex].creationDate.timeIntervalSince(
                        dated[firstIndex].creationDate
                      ) <= 30 {
                    let first = dated[firstIndex]
                    let second = dated[secondIndex]
                    advisories.append(
                        CatIdentityCloseCaptureAdvisory(
                            profileIdentifier: profile.identifier,
                            profileName: profile.displayName,
                            firstPhotoID: first.id,
                            secondPhotoID: second.id,
                            firstSlot: slotsByID[first.id] ?? "選択写真",
                            secondSlot: slotsByID[second.id] ?? "選択写真",
                            firstDate: first.creationDate,
                            secondDate: second.creationDate
                        )
                    )
                    secondIndex += 1
                }
                return advisories
            }
        }
    }

    private var closeCapturePhotoKeys: Set<CatIdentityPhotoSelectionKey> {
        Set(closeCaptureAdvisories.flatMap {
            [
                CatIdentityPhotoSelectionKey(
                    profileIdentifier: $0.profileIdentifier,
                    photoID: $0.firstPhotoID
                ),
                CatIdentityPhotoSelectionKey(
                    profileIdentifier: $0.profileIdentifier,
                    photoID: $0.secondPhotoID
                )
            ]
        })
    }

    private var labeledPhotosInServiceOrder: [
        CatIdentityExperimentSelectablePhoto
    ] {
        let selectedByProfile = presentation.profiles.map { selectedPhotos(for: $0) }
        return selectedByProfile.flatMap { Array($0.prefix(5)) }
            + selectedByProfile.flatMap { Array($0.dropFirst(5).prefix(15)) }
    }

    private var duplicateSelectionPhotoKeys: Set<CatIdentityPhotoSelectionKey> {
        let photos = labeledPhotosInServiceOrder
        return Set(model.duplicateSelectionPairs.flatMap { pair in
            [pair.firstOrdinal, pair.secondOrdinal].compactMap { ordinal in
                guard photos.indices.contains(ordinal),
                      let profileIdentifier = profileIdentifier(
                        forLabeledOrdinal: ordinal
                      ) else { return nil }
                return CatIdentityPhotoSelectionKey(
                    profileIdentifier: profileIdentifier,
                    photoID: photos[ordinal].id
                )
            }
        })
    }

    private func profileIdentifier(forLabeledOrdinal ordinal: Int) -> String? {
        guard let location = CatIdentityExperimentEpisodePolicy
            .labeledSelectionLocation(
                ordinal: ordinal,
                profileCount: presentation.profiles.count
            ), presentation.profiles.indices.contains(location.profileIndex) else {
            return nil
        }
        return presentation.profiles[location.profileIndex].identifier
    }

    private func labeledSelectionDescription(ordinal: Int) -> String? {
        guard let location = CatIdentityExperimentEpisodePolicy
            .labeledSelectionLocation(
                ordinal: ordinal,
                profileCount: presentation.profiles.count
            ), presentation.profiles.indices.contains(location.profileIndex) else {
            return nil
        }
        let phase = location.phase == .training ? "学習" : "評価"
        return "\(presentation.profiles[location.profileIndex].displayName) \(phase)\(location.slot)"
    }

    private func exactCaptureDate(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .standard)
    }

    private func eligiblePhotos(
        for profile: CatProfilePresentation
    ) -> [CatIdentityExperimentSelectablePhoto] {
        var photosByID: [String: CatIdentityExperimentSelectablePhoto] = [:]
        for photo in profile.confirmedPhotos {
            guard photo.detectedCatCount <= 1,
                  let box = photo.catBoundingBox,
                  let date = photo.creationDate,
                  photo.assignedProfileIdentifiers == [profile.identifier]
            else { continue }
            let selectable = CatIdentityExperimentSelectablePhoto(
                id: instanceID(
                    assetLocalIdentifier: photo.localIdentifier,
                    boundingBox: box
                ),
                assetLocalIdentifier: photo.localIdentifier,
                boundingBox: box,
                creationDate: date
            )
            photosByID[selectable.id] = selectable
        }

        let unassignedByIdentifier = Dictionary(
            uniqueKeysWithValues: presentation.unassignedPhotos.map {
                ($0.localIdentifier, $0)
            }
        )
        for candidate in presentation.similarityCandidates {
            guard let asset = unassignedByIdentifier[
                candidate.assetLocalIdentifier
            ],
            asset.detectedCatCount <= 1,
            let date = asset.creationDate else { continue }
            let box = candidate.boundingBox.cgRect
            let selectable = CatIdentityExperimentSelectablePhoto(
                id: instanceID(
                    assetLocalIdentifier: candidate.assetLocalIdentifier,
                    boundingBox: box
                ),
                assetLocalIdentifier: candidate.assetLocalIdentifier,
                boundingBox: box,
                creationDate: date
            )
            photosByID[selectable.id] = selectable
        }
        return photosByID.values.sorted {
            if $0.creationDate != $1.creationDate {
                return $0.creationDate > $1.creationDate
            }
            return $0.id < $1.id
        }
    }

    private func selectedPhotoIDs(
        for profile: CatProfilePresentation
    ) -> [String] {
        selectedPhotoIDsByProfile[profile.identifier] ?? []
    }

    private func selectedPhotos(
        for profile: CatProfilePresentation
    ) -> [CatIdentityExperimentSelectablePhoto] {
        let photosByID = Dictionary(
            uniqueKeysWithValues: eligiblePhotos(for: profile).map {
                ($0.id, $0)
            }
        )
        return selectedPhotoIDs(for: profile).compactMap { photosByID[$0] }
    }

    private func toggle(
        photo: CatIdentityExperimentSelectablePhoto,
        for profile: CatProfilePresentation
    ) {
        var selected = selectedPhotoIDs(for: profile)
        if let index = selected.firstIndex(of: photo.id) {
            selected.remove(at: index)
        } else if selected.count < 20,
                  !presentation.profiles.contains(where: { selectedProfile in
                      selectedPhotos(for: selectedProfile).contains {
                          $0.assetLocalIdentifier == photo.assetLocalIdentifier
                      }
                  }) {
            selected.append(photo.id)
        }
        selectedPhotoIDsByProfile[profile.identifier] = selected
        evaluationPhotosByOrdinal = [:]
        model.resetResult()
    }

    private func startExperiment() {
        let profiles = presentation.profiles
        let selectedByProfile = profiles.map { selectedPhotos(for: $0) }
        let references = profiles.enumerated().flatMap { entry in
            let profileIndex = entry.offset
            return selectedByProfile[profileIndex].prefix(5).map { photo in
                    return CatIdentityExperimentReferenceInput(
                        profileIndex: profileIndex,
                        assetLocalIdentifier: photo.assetLocalIdentifier,
                        boundingBox: NormalizedRect(photo.boundingBox)
                    )
            }
        }
        let evaluationPhotos = profiles.enumerated().flatMap { entry in
            Array(selectedByProfile[entry.offset].dropFirst(5).prefix(15))
        }
        let evaluations = profiles.enumerated().flatMap { entry in
            let profileIndex = entry.offset
            return selectedByProfile[profileIndex]
                .dropFirst(5)
                .prefix(15)
                .map { photo in
                    CatIdentityExperimentEvaluationInput(
                        profileIndex: profileIndex,
                        assetLocalIdentifier: photo.assetLocalIdentifier,
                        boundingBox: NormalizedRect(photo.boundingBox)
                    )
                }
        }
        let candidates = presentation.similarityCandidates.map {
            CatIdentityExperimentCandidateInput(
                assetLocalIdentifier: $0.assetLocalIdentifier,
                boundingBox: $0.boundingBox
            )
        }
        evaluationPhotosByOrdinal = Dictionary(
            uniqueKeysWithValues: evaluationPhotos.enumerated().map {
                ($0.offset, $0.element)
            }
        )
        model.start(
            references: references,
            evaluations: evaluations,
            candidates: candidates
        )
    }

    private func instanceID(
        assetLocalIdentifier: String,
        boundingBox: CGRect
    ) -> String {
        [
            assetLocalIdentifier,
            String(Double(boundingBox.minX).bitPattern),
            String(Double(boundingBox.minY).bitPattern),
            String(Double(boundingBox.width).bitPattern),
            String(Double(boundingBox.height).bitPattern)
        ].joined(separator: "|")
    }

    private func profileName(at index: Int) -> String {
        guard presentation.profiles.indices.contains(index) else {
            return "猫\(index + 1)"
        }
        return presentation.profiles[index].displayName
    }

    private func referenceAccessibilityLabel(
        _ photo: CatIdentityExperimentSelectablePhoto
    ) -> String {
        photo.creationDate.formatted(date: .abbreviated, time: .omitted)
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
            "FeaturePrintは正解率95%以上でしたが判定率70%未満でした。色ヒストグラムは固定基準を通りました。"
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

    private func fractionAndPercentage(
        numerator: Int,
        denominator: Int,
        rate: Double
    ) -> String {
        "\(numerator) / \(denominator)（\(percentage(rate))）"
    }

    private func profileEvaluationSummary(
        _ value: CatIdentityExperimentProfileEvaluationSummary
    ) -> String {
        let precision = fractionAndPercentage(
            numerator: value.correctAssignedCount,
            denominator: value.correctAssignedCount + value.wrongAssignedCount,
            rate: value.precision
        )
        let coverage = fractionAndPercentage(
            numerator: value.correctAssignedCount + value.wrongAssignedCount,
            denominator: value.trialCount,
            rate: value.coverage
        )
        return "正解率 \(precision)・判定率 \(coverage)・誤り\(value.wrongAssignedCount)・unknown\(value.unknownCount)"
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
    @Published private(set) var localDetail: CatIdentityExperimentLocalDetail?
    @Published private(set) var errorMessage: String?
    @Published private(set) var duplicateSelectionPairs: [
        CatIdentityExperimentDuplicateSelectionPair
    ] = []
    @Published private(set) var isRunning = false

    private let service = CatIdentityExperimentService()
    private var runTask: Task<Void, Never>?
    private var runRevision = 0

    func start(
        references: [CatIdentityExperimentReferenceInput],
        evaluations: [CatIdentityExperimentEvaluationInput],
        candidates: [CatIdentityExperimentCandidateInput]
    ) {
        runRevision += 1
        let revision = runRevision
        runTask?.cancel()
        runTask = nil
        isRunning = true
        progress = nil
        report = nil
        localDetail = nil
        errorMessage = nil
        duplicateSelectionPairs = []
        let service = self.service
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                await service.discard()
                guard self.runRevision == revision else { return }
                let result = try await service.run(
                    references: references,
                    evaluations: evaluations,
                    candidates: candidates,
                    progress: { [weak self] progress in
                        await self?.receive(progress, revision: revision)
                    }
                )
                guard self.runRevision == revision else { return }
                self.report = result.report
                self.localDetail = result.localDetail
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
                if let serviceError = error as? CatIdentityExperimentServiceError,
                   case let .duplicateLabeledEpisodes(pairs) = serviceError {
                    self.duplicateSelectionPairs = pairs
                }
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
        localDetail = nil
        duplicateSelectionPairs = []
    }

    func resetResult() {
        guard !isRunning else { return }
        report = nil
        localDetail = nil
        errorMessage = nil
        duplicateSelectionPairs = []
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
                return "選んだ写真を計測に使えませんでした。各猫20枚を選び直してください。"
            case .duplicateLabeledEpisodes:
                return "同じ猫の連写またはほぼ同じ写真が含まれています。"
            case .colorSpaceUnavailable:
                return "写真の色を端末内で読み取れませんでした。"
            }
        }
        if let coreError = error as? CatIdentityExperimentCoreError {
            switch coreError {
            case .invalidReferenceSet, .invalidEvaluationSet:
                return "連写やほぼ同じ写真が含まれています。40枚すべてを別の場面から選んでください。"
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
