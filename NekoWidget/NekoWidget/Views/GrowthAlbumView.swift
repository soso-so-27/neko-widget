import SwiftUI

/// Growth is intentionally not another thumbnail grid. The first and latest
/// periods stay visible together, while intermediate periods form a short
/// timeline and each automatic representative remains replaceable.
struct GrowthAlbumDetailView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let album: CuratedAlbumPresentation
    let sourcePhotos: [PhotoPresentation]
    let lifeReference: CatLifeReference?
    let setPhotoOverride: (GrowthAlbumPeriod, String?) -> Void
    let albumOpened: (String, String) -> Void
    let excludeFromCatCandidates: ([String]) -> Void
    let profiles: [CatProfilePresentation]
    let assignmentsByPhotoIdentifier: [String: Set<String>]
    let replaceProfileAssignments: ([String: Set<String>]) -> Void

    @State private var didRecordOpen = false
    @State private var pendingExclusionIdentifier: String?
    @State private var showsExclusionConfirmation = false
    @State private var pendingAssignmentIdentifier: String?
    @State private var showsAssignmentSheet = false
    @State private var replacementPeriod: GrowthAlbumPeriod?

    private var candidateGroups: [GrowthAlbumCandidateGroup] {
        GrowthAlbumSelector().candidateGroups(
            from: sourcePhotos,
            lifeReference: lifeReference
        )
    }

    var body: some View {
        let groups = candidateGroups
        let resolvedItems = GrowthAlbumSelector().select(
            from: album.photos,
            lifeReference: lifeReference
        )

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let first = resolvedItems.first,
                   let last = resolvedItems.last,
                   first.id != last.id {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("最初のころと、いま")
                            .font(.title2.bold())
                        Text("\(first.label) — \(last.label)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)

                        comparisonCards(first, last, groups: groups)
                    }

                    let middleItems = Array(resolvedItems.dropFirst().dropLast())
                    if !middleItems.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("その間の記録")
                                .font(.headline)
                            ForEach(middleItems) { item in
                                timelineRow(
                                    item,
                                    canReplace: canReplacePhoto(for: item.period, in: groups)
                                )
                            }
                        }
                    }
                }

                if album.id == .householdGrowth {
                    Text("猫を見分けず、撮影年ごとに並べています。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .confirmationDialog(
            "表示候補から外しますか？",
            isPresented: $showsExclusionConfirmation,
            titleVisibility: .visible
        ) {
            Button("すべてから除外", role: .destructive) {
                guard let identifier = pendingExclusionIdentifier else { return }
                pendingExclusionIdentifier = nil
                excludeFromCatCandidates([identifier])
            }
            Button("キャンセル", role: .cancel) {
                pendingExclusionIdentifier = nil
            }
        } message: {
            Text("アプリの「写真」・ウィジェット・「自動アルバム」の候補から外します。写真アプリの写真は削除・変更されません。設定からいつでも戻せます。")
        }
        .sheet(isPresented: $showsAssignmentSheet) {
            if let identifier = pendingAssignmentIdentifier {
                CatPhotoAssignmentSheet(
                    photoIdentifiers: [identifier],
                    profiles: profiles,
                    initialAssignmentsByPhotoIdentifier: [
                        identifier: assignmentsByPhotoIdentifier[identifier] ?? []
                    ],
                    save: { values in
                        replaceProfileAssignments(values)
                        pendingAssignmentIdentifier = nil
                    },
                    excludeFromHousehold: { identifiers in
                        excludeFromCatCandidates(identifiers)
                        pendingAssignmentIdentifier = nil
                    }
                )
            }
        }
        .sheet(item: $replacementPeriod) { period in
            GrowthPhotoReplacementSheet(
                period: period,
                candidates: replacementCandidates(
                    for: period,
                    in: groups,
                    selectedItems: resolvedItems
                ),
                selectedIdentifier: resolvedItems.first(where: { $0.period == period })?
                    .photo.localIdentifier,
                select: { photo in
                    selectReplacement(photo, for: period, in: groups)
                }
            )
        }
        .onAppear {
            guard !didRecordOpen else { return }
            didRecordOpen = true
            albumOpened(album.id.logKey, album.group.logKey)
        }
    }

    @ViewBuilder
    private func comparisonCards(
        _ first: GrowthAlbumItem,
        _ last: GrowthAlbumItem,
        groups: [GrowthAlbumCandidateGroup]
    ) -> some View {
        let firstCard = comparisonCard(
            first,
            roleLabel: "最初のころ",
            canReplace: canReplacePhoto(for: first.period, in: groups)
        )
        let lastCard = comparisonCard(
            last,
            roleLabel: "いま",
            canReplace: canReplacePhoto(for: last.period, in: groups)
        )

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 20) {
                firstCard
                lastCard
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                firstCard
                lastCard
            }
        }
    }

    private func comparisonCard(
        _ item: GrowthAlbumItem,
        roleLabel: String,
        canReplace: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(roleLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            photoLink(item, targetAspectRatio: 0.82)

            Text(item.label)
                .font(.headline)
                .lineLimit(2)
            if let date = item.photo.creationDate {
                Text(date, format: .dateTime.year().month().day())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if canReplace {
                replaceButton(for: item.period, labelStyle: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timelineRow(
        _ item: GrowthAlbumItem,
        canReplace: Bool
    ) -> some View {
        HStack(spacing: 12) {
            photoLink(item, targetAspectRatio: 1)
                .frame(width: 88)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.label)
                    .font(.headline)
                if let date = item.photo.creationDate {
                    Text(date, format: .dateTime.year().month().day())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)
            if canReplace {
                replaceButton(for: item.period, labelStyle: false)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func photoLink(
        _ item: GrowthAlbumItem,
        targetAspectRatio: CGFloat
    ) -> some View {
        NavigationLink(
            value: AlbumRoute.photo(
                album: album.id,
                localIdentifier: item.photo.localIdentifier
            )
        ) {
            Color.clear
                .aspectRatio(targetAspectRatio, contentMode: .fit)
                .overlay {
                    PhotoAssetImageView(
                        localIdentifier: item.photo.localIdentifier,
                        catBoundingBox: item.photo.catBoundingBox,
                        targetPixelSize: CGSize(width: 1_200, height: 1_500),
                        targetAspectRatio: targetAspectRatio
                    )
                    .clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: item))
        .accessibilityHint("写真を大きく表示します")
        .contextMenu {
            if !profiles.isEmpty {
                Button {
                    pendingAssignmentIdentifier = item.photo.localIdentifier
                    showsAssignmentSheet = true
                } label: {
                    Label("写っている子を修正", systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            Button {
                pendingExclusionIdentifier = item.photo.localIdentifier
                showsExclusionConfirmation = true
            } label: {
                Label("表示候補から外す", systemImage: "cat.circle")
            }
        }
    }

    @ViewBuilder
    private func replaceButton(
        for period: GrowthAlbumPeriod,
        labelStyle: Bool
    ) -> some View {
        Button {
            replacementPeriod = period
        } label: {
            if labelStyle {
                Label("写真を替える", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel("\(period.label)の写真を替える")
    }

    private func canReplacePhoto(
        for period: GrowthAlbumPeriod,
        in groups: [GrowthAlbumCandidateGroup]
    ) -> Bool {
        (groups.first(where: { $0.period == period })?.photos.count ?? 0) > 1
    }

    private func replacementCandidates(
        for period: GrowthAlbumPeriod,
        in groups: [GrowthAlbumCandidateGroup],
        selectedItems: [GrowthAlbumItem]
    ) -> [PhotoPresentation] {
        guard let group = groups.first(where: { $0.period == period }) else {
            return []
        }
        var candidates = Array(group.photos.prefix(6))
        if let selected = selectedItems.first(where: { $0.period == period })?.photo,
           !candidates.contains(where: { $0.localIdentifier == selected.localIdentifier }) {
            candidates = [selected] + Array(candidates.prefix(5))
        }
        return candidates
    }

    private func selectReplacement(
        _ photo: PhotoPresentation,
        for period: GrowthAlbumPeriod,
        in groups: [GrowthAlbumCandidateGroup]
    ) {
        let automaticIdentifier = groups
            .first(where: { $0.period == period })?
            .photos.first?
            .localIdentifier
        setPhotoOverride(
            period,
            photo.localIdentifier == automaticIdentifier ? nil : photo.localIdentifier
        )
    }

    private func accessibilityLabel(for item: GrowthAlbumItem) -> String {
        let date = item.photo.creationDate?.formatted(.dateTime.year().month().day())
            ?? "撮影日不明"
        return "\(item.label)、\(date)の猫の写真"
    }
}

private struct GrowthPhotoReplacementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let period: GrowthAlbumPeriod
    let candidates: [PhotoPresentation]
    let selectedIdentifier: String?
    let select: (PhotoPresentation) -> Void

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 10),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(candidates) { photo in
                        Button {
                            select(photo)
                            dismiss()
                        } label: {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    PhotoAssetImageView(
                                        localIdentifier: photo.localIdentifier,
                                        catBoundingBox: photo.catBoundingBox,
                                        targetPixelSize: CGSize(width: 720, height: 720),
                                        targetAspectRatio: 1
                                    )
                                    .clipped()
                                }
                                .overlay(alignment: .topTrailing) {
                                    if photo.localIdentifier == selectedIdentifier {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title2)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.accentColor)
                                            .padding(8)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            photo.localIdentifier == selectedIdentifier
                                ? "選択中の写真"
                                : "この写真に替える"
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle("\(period.label)の写真")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
