import SwiftUI

/// Integration boundary for the optional multi-cat experience. Every
/// membership is explicit and user-confirmed; this build does not perform
/// automatic individual-cat identification.
struct CatProfilesViewActions {
    var currentSimilarityCandidates: @MainActor () -> [CatSimilarityCandidateInstance]
    var createProfile: (CatProfileDraftPresentation) async -> Void
    var updateName: (
        _ profileIdentifier: String,
        _ name: String
    ) async -> Void
    var updateLifeReference: (
        _ profileIdentifier: String,
        _ reference: CatProfileLifeReferencePresentation?
    ) async -> Void
    /// Links or unlinks one read-only, user-created Photos album. The result is
    /// false when PhotoKit or persistence rejects the selection.
    var setProfilePhotoAlbum: (
        _ profileIdentifier: String,
        _ albumIdentifier: String?
    ) async -> Bool
    var refreshPhotoAlbums: () async -> Void
    var confirmProfileMembership: (
        _ profileIdentifier: String,
        _ photoIdentifiers: [String]
    ) async -> Void
    /// Marks only this profile as excluded. It must not alter another
    /// profile's membership or the household-wide exclusion state.
    var removeProfileMembership: (
        _ profileIdentifier: String,
        _ photoIdentifiers: [String]
    ) async -> Void
    /// Replaces profile membership per photo. The per-photo map preserves
    /// mixed assignments when a batch selection contains different cats.
    var replacePhotoAssignments: (
        _ profileIdentifiersByPhotoIdentifier: [String: Set<String>]
    ) async -> Void
    var excludeFromHousehold: (_ photoIdentifiers: [String]) async -> Void
    var restoreLegacyExclusions: (_ photoIdentifiers: [String]) async -> Void
    /// The only similarity-review action that writes identity membership.
    /// Generation, splitting, and deferring remain local to the review view.
    var confirmSimilarityGroup: (
        _ profileIdentifier: String,
        _ candidates: [CatSimilarityCandidateInstance]
    ) async -> CatSimilarityGroupConfirmationOutcome
    var deleteProfile: (_ profileIdentifier: String) async -> Void

    static let noOp = CatProfilesViewActions(
        currentSimilarityCandidates: { [] },
        createProfile: { _ in },
        updateName: { _, _ in },
        updateLifeReference: { _, _ in },
        setProfilePhotoAlbum: { _, _ in false },
        refreshPhotoAlbums: {},
        confirmProfileMembership: { _, _ in },
        removeProfileMembership: { _, _ in },
        replacePhotoAssignments: { _ in },
        excludeFromHousehold: { _ in },
        restoreLegacyExclusions: { _ in },
        confirmSimilarityGroup: { _, _ in
            .conflict(reason: .invalidGroup)
        },
        deleteProfile: { _ in }
    )
}

struct CatProfilesView: View {
    let presentation: CatProfilesPresentation
    let actions: CatProfilesViewActions

    @State private var showsAddProfile = false

    var body: some View {
        Form {
            optionalSetupSection
            profilesSection
            unassignedSection
            legacyExclusionSection
        }
        .navigationTitle("うちの子")
        .sheet(isPresented: $showsAddProfile) {
            AddCatProfileView(
                referenceCandidates: presentation.unassignedPhotos.filter {
                    $0.detectedCatCount == 1
                },
                initialLifeReference: presentation.legacyLifeReference,
                createProfile: actions.createProfile
            )
        }
    }

    private var optionalSetupSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最初は「みんな」のままで使えます")
                        .font(.headline)
                    Text("名前や写真を選ばなくても、これまで通り思い出とウィジェットを使えます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "pawprint.fill")
                    .foregroundStyle(.tint)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var profilesSection: some View {
        Section {
            EveryoneProfileRow(
                catCount: presentation.profiles.count,
                unassignedPhotoCount: presentation.unassignedPhotos.count
            )

            ForEach(presentation.profiles) { profile in
                NavigationLink {
                    CatProfileDetailView(
                        profile: profile,
                        allProfiles: presentation.profiles,
                        manualCandidatePhotos: profile.manualCandidatePhotos,
                        photoAlbumOptions: presentation.photoAlbumOptions,
                        actions: actions
                    )
                } label: {
                    CatProfileRow(profile: profile)
                }
            }

            Button {
                showsAddProfile = true
            } label: {
                Label("この子を追加", systemImage: "plus.circle")
            }
        } header: {
            Text("プロフィール")
        } footer: {
            Text(CatIndividualRecognitionCopy.unavailable)
        }
    }

    @ViewBuilder
    private var unassignedSection: some View {
        if !presentation.unassignedPhotos.isEmpty {
            Section {
                NavigationLink {
                    UnassignedCatPhotosView(
                        photos: presentation.unassignedPhotos,
                        profiles: presentation.profiles,
                        actions: actions
                    )
                } label: {
                    Label {
                        LabeledContent(
                            "どの子かまだわからない",
                            value: "\(presentation.unassignedPhotos.count.formatted())枚"
                        )
                    } icon: {
                        Image(systemName: "questionmark.circle")
                    }
                }
            } footer: {
                Text("未判定の写真も「みんな」には表示されます。仕分ける必要はありません。")
            }
        }
    }

    @ViewBuilder
    private var legacyExclusionSection: some View {
        if !presentation.legacyExcludedPhotos.isEmpty {
            Section {
                NavigationLink {
                    LegacyCatExclusionReviewView(
                        photos: presentation.legacyExcludedPhotos,
                        restore: actions.restoreLegacyExclusions
                    )
                } label: {
                    Label {
                        LabeledContent(
                            "以前除外した写真を確認",
                            value: "\(presentation.legacyExcludedPhotos.count.formatted())枚"
                        )
                    } icon: {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("単頭設定からの引き継ぎ")
            } footer: {
                Text("以前の「この子じゃない」は単頭向けでした。もう一匹のうちの子を除外していないか確認できます。")
            }
        }
    }

}

private struct EveryoneProfileRow: View {
    let catCount: Int
    let unassignedPhotoCount: Int

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("みんな")
                    Spacer()
                    Text("既定")
                        .font(.caption.bold())
                        .foregroundStyle(.tint)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.tint)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if catCount == 0 {
            return "プロフィールを作らなくても、猫候補をまとめて表示します"
        }
        if unassignedPhotoCount == 0 {
            return "\(catCount.formatted())匹の写真をまとめて表示"
        }
        return "\(catCount.formatted())匹と未判定 \(unassignedPhotoCount.formatted())枚をまとめて表示"
    }
}

private struct CatProfileRow: View {
    let profile: CatProfilePresentation

    var body: some View {
        HStack(spacing: 12) {
            CatProfileThumbnail(photo: profile.coverPhoto)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName)
                    .font(.headline)
                Text("この子の写真 \(profile.confirmedPhotoCount.formatted())枚")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CatProfileThumbnail: View {
    let photo: CatProfilePhotoPresentation?

    var body: some View {
        Group {
            if let photo {
                PhotoAssetImageView(
                    localIdentifier: photo.localIdentifier,
                    catBoundingBox: photo.catBoundingBox,
                    targetPixelSize: CGSize(width: 240, height: 240),
                    targetAspectRatio: 1
                )
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "cat.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}

/// Optional scope control for album and photo surfaces. `everyone` is always
/// first and remains the default, so adding profiles never turns browsing into
/// a required setup step.
struct CatProfileScopePicker: View {
    let profiles: [CatProfilePresentation]
    @Binding var selection: CatProfileScopePresentation

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                scopeButton(
                    scope: .everyone,
                    title: "みんな",
                    photo: nil,
                    systemImage: "square.stack.3d.up.fill"
                )
                ForEach(profiles) { profile in
                    scopeButton(
                        scope: .profile(profile.identifier),
                        title: profile.displayName,
                        photo: profile.coverPhoto,
                        systemImage: nil
                    )
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 3)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .onAppear(perform: normalizeSelection)
        .onChange(of: profiles.map(\.identifier)) { _, _ in
            normalizeSelection()
        }
    }

    private func scopeButton(
        scope: CatProfileScopePresentation,
        title: String,
        photo: CatProfilePhotoPresentation?,
        systemImage: String?
    ) -> some View {
        let isSelected = selection == scope
        return Button {
            selection = scope
        } label: {
            HStack(spacing: 7) {
                if let photo {
                    CatProfileThumbnail(photo: photo)
                        .frame(width: 30, height: 30)
                        .clipShape(Circle())
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.accentColor : Color(.secondarySystemBackground),
                in: Capsule()
            )
            .overlay {
                if !isSelected {
                    Capsule().stroke(Color.secondary.opacity(0.20))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func normalizeSelection() {
        guard case let .profile(identifier) = selection,
              !profiles.contains(where: { $0.identifier == identifier }) else {
            return
        }
        selection = .everyone
    }
}

private struct AddCatProfileView: View {
    let referenceCandidates: [CatProfilePhotoPresentation]
    let initialLifeReference: CatProfileLifeReferencePresentation?
    let createProfile: (CatProfileDraftPresentation) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CatProfileDraftPresentation
    @State private var isSaving = false

    init(
        referenceCandidates: [CatProfilePhotoPresentation],
        initialLifeReference: CatProfileLifeReferencePresentation?,
        createProfile: @escaping (CatProfileDraftPresentation) async -> Void
    ) {
        self.referenceCandidates = referenceCandidates
        self.initialLifeReference = initialLifeReference
        self.createProfile = createProfile
        _draft = State(initialValue: CatProfileDraftPresentation(
            lifeReference: initialLifeReference
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名前（あとでも設定できます）", text: $draft.name)
                } header: {
                    Text("名前")
                }

                Section {
                    if initialLifeReference != nil {
                        Label(
                            "以前設定した日付を、この子の初期値にしています",
                            systemImage: "arrow.triangle.branch"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    Picker("日付の基準", selection: lifeReferenceKind) {
                        Text("設定しない").tag(nil as CatProfileLifeReferenceKindPresentation?)
                        ForEach(CatProfileLifeReferenceKindPresentation.allCases) { kind in
                            Text(kind.title).tag(Optional(kind))
                        }
                    }

                    if draft.lifeReference != nil {
                        DatePicker(
                            draft.lifeReference?.kind.title ?? "日付",
                            selection: lifeReferenceDate,
                            in: ...Date.now,
                            displayedComponents: .date
                        )
                        Toggle("推定の日付", isOn: approximateDate)
                    }
                } header: {
                    Text("この子の時間")
                } footer: {
                    Text("年齢アルバムは誕生日（推定を含む）だけを基準にします。迎えた日もプロフィール情報として保存できます。")
                }

                Section {
                    if referenceCandidates.isEmpty {
                        Text("参照写真はあとから追加できます。")
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(referenceCandidates.prefix(12)) { photo in
                                    Button {
                                        draft.referencePhotoIdentifier =
                                            draft.referencePhotoIdentifier == photo.localIdentifier
                                                ? nil
                                                : photo.localIdentifier
                                    } label: {
                                        CatProfileThumbnail(photo: photo)
                                            .frame(width: 86, height: 86)
                                            .overlay(alignment: .topTrailing) {
                                                if draft.referencePhotoIdentifier == photo.localIdentifier {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .symbolRenderingMode(.palette)
                                                        .foregroundStyle(.white, Color.accentColor)
                                                        .padding(5)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("参照写真")
                                    .accessibilityAddTraits(
                                        draft.referencePhotoIdentifier == photo.localIdentifier
                                            ? .isSelected
                                            : []
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .scrollIndicators(.hidden)
                    }
                } header: {
                    Text("参照写真・任意")
                } footer: {
                    Text("この子だと分かる写真を1枚選ぶと、最初の所属写真になります。あとから変更できます。")
                }
            }
            .navigationTitle("この子を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "追加中…" : "追加") {
                        Task {
                            isSaving = true
                            await createProfile(draft)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    private var lifeReferenceKind: Binding<CatProfileLifeReferenceKindPresentation?> {
        Binding(
            get: { draft.lifeReference?.kind },
            set: { kind in
                guard let kind else {
                    draft.lifeReference = nil
                    return
                }
                draft.lifeReference = CatProfileLifeReferencePresentation(
                    kind: kind,
                    date: draft.lifeReference?.date ?? .now,
                    isApproximate: draft.lifeReference?.isApproximate ?? false
                )
            }
        )
    }

    private var lifeReferenceDate: Binding<Date> {
        Binding(
            get: { draft.lifeReference?.date ?? .now },
            set: { date in
                guard var reference = draft.lifeReference else { return }
                reference.date = date
                draft.lifeReference = reference
            }
        )
    }

    private var approximateDate: Binding<Bool> {
        Binding(
            get: { draft.lifeReference?.isApproximate ?? false },
            set: { isApproximate in
                guard var reference = draft.lifeReference else { return }
                reference.isApproximate = isApproximate
                draft.lifeReference = reference
            }
        )
    }
}
