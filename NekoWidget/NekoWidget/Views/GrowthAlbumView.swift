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
    @State private var showsAboutSelection = false

    private var candidateGroups: [GrowthAlbumCandidateGroup] {
        GrowthAlbumSelector().candidateGroups(
            from: sourcePhotos,
            lifeReference: lifeReference
        )
    }

    private var timelineColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 12),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
        )
    }

    var body: some View {
        let groups = candidateGroups
        let resolvedItems = GrowthAlbumSelector().select(
            from: album.photos,
            lifeReference: lifeReference
        )

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let first = resolvedItems.first,
                   let last = resolvedItems.last,
                   first.id != last.id {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(comparisonHeadline(from: first.period, to: last.period))
                                .font(.largeTitle.bold())
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("写真から、時期ごとに一枚ずつ選びました。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Button {
                                    showsAboutSelection = true
                                } label: {
                                    Image(systemName: "info.circle")
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("このまとめについて")
                            }
                        }

                        comparisonCards(first, last)

                        let replaceableItems = resolvedItems.filter {
                            canReplacePhoto(for: $0.period, in: groups)
                        }
                        if !replaceableItems.isEmpty {
                            replacementMenu(items: replaceableItems)
                                .frame(maxWidth: .infinity)
                        }
                    }

                    let middleItems = Array(resolvedItems.dropFirst().dropLast())
                    if !middleItems.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("その間")
                                .font(.headline)

                            LazyVGrid(columns: timelineColumns, spacing: 12) {
                                ForEach(middleItems) { item in
                                    timelineCard(item)
                                }
                            }
                        }
                    }
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
        .alert("このまとめについて", isPresented: $showsAboutSelection) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(aboutSelectionMessage)
        }
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
                    selectReplacement(photo, for: period)
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
        _ last: GrowthAlbumItem
    ) -> some View {
        let firstCard = comparisonCard(
            first,
            roleLabel: "最初のころ"
        )
        let lastCard = comparisonCard(
            last,
            roleLabel: "いま"
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
        roleLabel: String
    ) -> some View {
        photoLink(item, targetAspectRatio: 0.82)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    if shouldShowRoleLabel(roleLabel, for: item.period) {
                        Text(roleLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    Text(item.label)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 40)
                .padding(.bottom, 12)
                .background {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.74)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timelineCard(_ item: GrowthAlbumItem) -> some View {
        photoLink(item, targetAspectRatio: 1)
            .overlay(alignment: .bottomLeading) {
                Text(item.label)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 32)
                    .padding(.bottom, 12)
                    .background {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.68)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .allowsHitTesting(false)
            }
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

    private func replacementMenu(items: [GrowthAlbumItem]) -> some View {
        Menu {
            ForEach(items) { item in
                Button(item.label) {
                    replacementPeriod = item.period
                }
            }
        } label: {
            Label("一枚を選び直す", systemImage: "photo.on.rectangle.angled")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
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
        for period: GrowthAlbumPeriod
    ) {
        let automaticIdentifier = GrowthAlbumSelector()
            .select(from: sourcePhotos, lifeReference: lifeReference)
            .first(where: { $0.period == period })?
            .photo.localIdentifier
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

    private func comparisonHeadline(
        from firstPeriod: GrowthAlbumPeriod,
        to lastPeriod: GrowthAlbumPeriod
    ) -> String {
        guard let years = firstPeriod.years(until: lastPeriod) else {
            return "最初のころから、いままで。"
        }
        switch album.id {
        case .householdGrowth:
            return "\(years)年、猫たちと。"
        case let .profileGrowth(_, displayName) where !displayName.isEmpty:
            return "\(years)年、\(displayName)と。"
        default:
            return "\(years)年、いっしょに。"
        }
    }

    private func shouldShowRoleLabel(
        _ roleLabel: String,
        for period: GrowthAlbumPeriod
    ) -> Bool {
        if roleLabel == "最初のころ", case .yearsTogether(0) = period {
            return false
        }
        return true
    }

    private var aboutSelectionMessage: String {
        let source = "このiPhoneにある対象写真から、撮影時期ごとに一枚ずつ自動で選んでいます。"
        let edit = "選び直しても、写真アプリの元の写真は変わりません。"
        if album.id == .householdGrowth {
            return "\(source) 猫を見分けて同じ猫だと判定しているわけではありません。\(edit)"
        }
        return "\(source) \(edit)"
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
                                ? "選択中の一枚"
                                : "この一枚を選ぶ"
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle("\(period.label)の一枚を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
