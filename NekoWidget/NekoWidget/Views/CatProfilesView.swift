import SwiftUI

/// Integration boundary for the optional multi-cat experience. Every
/// membership is explicit and user-confirmed; this build does not perform
/// automatic individual-cat identification.
struct CatProfilesViewActions {
    var currentSimilarityCandidates: @MainActor () -> [CatSimilarityCandidateInstance]
    var createProfile: (CatProfileDraftPresentation) async -> String?
    var updateName: (
        _ profileIdentifier: String,
        _ name: String
    ) async -> Bool
    var updateLifeDates: (
        _ profileIdentifier: String,
        _ dates: CatProfileLifeDatesPresentation
    ) async -> Bool
    var setKeyPhoto: (_ profileIdentifier: String, _ photoIdentifier: String) async -> Bool
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
    ) async -> Bool
    /// Marks only this profile as excluded. It must not alter another
    /// profile's membership or the household-wide exclusion state.
    var removeProfileMembership: (
        _ profileIdentifier: String,
        _ photoIdentifiers: [String]
    ) async -> Bool
    /// Replaces profile membership per photo. The per-photo map preserves
    /// mixed assignments when a batch selection contains different cats.
    var replacePhotoAssignments: (
        _ profileIdentifiersByPhotoIdentifier: [String: Set<String>]
    ) async -> Bool
    var excludeFromHousehold: (_ photoIdentifiers: [String]) async -> Void
    var restoreLegacyExclusions: (_ photoIdentifiers: [String]) async -> Void
    /// The only similarity-review action that writes identity membership.
    /// Generation, splitting, and deferring remain local to the review view.
    var confirmSimilarityGroup: (
        _ profileIdentifier: String,
        _ candidates: [CatSimilarityCandidateInstance]
    ) async -> CatSimilarityGroupConfirmationOutcome
    var deleteProfile: (_ profileIdentifier: String) async -> Bool

    static let noOp = CatProfilesViewActions(
        currentSimilarityCandidates: { [] },
        createProfile: { _ in nil },
        updateName: { _, _ in false },
        updateLifeDates: { _, _ in false },
        setKeyPhoto: { _, _ in false },
        setProfilePhotoAlbum: { _, _ in false },
        refreshPhotoAlbums: {},
        confirmProfileMembership: { _, _ in false },
        removeProfileMembership: { _, _ in false },
        replacePhotoAssignments: { _ in false },
        excludeFromHousehold: { _ in },
        restoreLegacyExclusions: { _ in },
        confirmSimilarityGroup: { _, _ in
            .conflict(reason: .invalidGroup)
        },
        deleteProfile: { _ in false }
    )
}

struct CatProfilesView: View {
    let presentation: CatProfilesPresentation
    let actions: CatProfilesViewActions

    @State private var showsAddProfile = false
    @State private var createdProfileIdentifier: String?
    @State private var openedProfileIdentifier: String?

    var body: some View {
        Form {
            if presentation.profiles.isEmpty {
                optionalSetupSection
            }
            profilesSection
            unassignedSection
            legacyExclusionSection
        }
        .navigationTitle("ねこのプロフィール")
        .sheet(isPresented: $showsAddProfile, onDismiss: {
            openedProfileIdentifier = createdProfileIdentifier
            createdProfileIdentifier = nil
        }) {
            AddCatProfileView(
                referenceCandidates: presentation.profileCreationPhotos,
                initialLifeReference: presentation.legacyLifeReference,
                createProfile: actions.createProfile,
                onCreated: { createdProfileIdentifier = $0 }
            )
        }
        .navigationDestination(item: $openedProfileIdentifier) { identifier in
            if let profile = presentation.profiles.first(where: { $0.identifier == identifier }) {
                profileDetail(profile)
            }
        }
    }

    private var optionalSetupSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("猫ごとに写真を見返す")
                        .font(.headline)
                    Text("登録は任意です。今までの写真やアルバムは、そのまま使えます。")
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
            ForEach(presentation.profiles) { profile in
                NavigationLink {
                    profileDetail(profile)
                } label: {
                    CatProfileRow(profile: profile)
                }
            }

            Button {
                showsAddProfile = true
            } label: {
                Label("猫を追加", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("cat-profile-add")
        } header: {
            Text("プロフィール")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(CatIndividualRecognitionCopy.unavailable)
                Text("写っている猫は自分で選べます。プロフィールと猫別の写真設定は、このiPhone内で管理します。")
            }
        }
    }

    @ViewBuilder
    private var unassignedSection: some View {
        if !presentation.profiles.isEmpty && !presentation.unassignedPhotos.isEmpty {
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
                            "猫を選んでいない写真",
                            value: "\(presentation.unassignedPhotos.count.formatted())枚"
                        )
                    } icon: {
                        Image(systemName: "questionmark.circle")
                    }
                }
            } footer: {
                Text("選んでいない写真も「みんな」に表示されます。すべてを分ける必要はありません。")
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
                Text("以前の「この子じゃない」は単頭向けでした。別の猫の写真まで除外していないか確認できます。")
            }
        }
    }

    private func profileDetail(_ profile: CatProfilePresentation) -> some View {
        CatProfileDetailView(
            profile: profile,
            allProfiles: presentation.profiles,
            manualCandidatePhotos: profile.manualCandidatePhotos,
            photoAlbumOptions: presentation.photoAlbumOptions,
            actions: actions
        )
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
    let createProfile: (CatProfileDraftPresentation) async -> String?
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CatProfileDraftPresentation
    @State private var isSaving = false
    @State private var showsPhotoPicker = false
    @State private var saveFailed = false

    init(
        referenceCandidates: [CatProfilePhotoPresentation],
        initialLifeReference: CatProfileLifeReferencePresentation?,
        createProfile: @escaping (CatProfileDraftPresentation) async -> String?,
        onCreated: @escaping (String) -> Void
    ) {
        self.referenceCandidates = referenceCandidates
        self.createProfile = createProfile
        self.onCreated = onCreated
        _draft = State(initialValue: CatProfileDraftPresentation(
            lifeReference: initialLifeReference
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("猫の名前", text: $draft.name)
                        .accessibilityIdentifier("cat-profile-name")
                    if !referenceCandidates.isEmpty {
                        Button {
                            showsPhotoPicker = true
                        } label: {
                            HStack(spacing: 12) {
                                CatProfileThumbnail(photo: selectedPhoto)
                                    .frame(width: 58, height: 58)
                                Text(selectedPhoto == nil ? "プロフィール写真を選ぶ" : "写真を変更")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .accessibilityIdentifier("cat-profile-key-photo")
                        if selectedPhoto != nil {
                            Button("写真はあとで選ぶ") {
                                draft.referencePhotoIdentifier = nil
                            }
                            .font(.footnote)
                        }
                    }
                } footer: {
                    Text("写真や誕生日は、追加したあとでも設定できます。")
                }

                if let reference = draft.lifeReference {
                    Section {
                        LabeledContent(reference.kind.title) {
                            Text(reference.date, format: .dateTime.year().month().day())
                        }
                        Button("この日付を引き継がない") { draft.lifeReference = nil }
                    } footer: {
                        Text("以前設定した日付です。この猫のプロフィールに引き継ぎます。")
                    }
                }

                if saveFailed {
                    Section {
                        Text("追加できませんでした。入力は残っています。もう一度お試しください。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle("猫を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "追加中…" : "追加") {
                        Task {
                            isSaving = true
                            saveFailed = false
                            let identifier = await createProfile(draft)
                            isSaving = false
                            if let identifier {
                                onCreated(identifier)
                                dismiss()
                            } else {
                                saveFailed = true
                            }
                        }
                    }
                    .disabled(isSaving || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("cat-profile-create")
                }
            }
            .sheet(isPresented: $showsPhotoPicker) {
                NavigationStack {
                    CatProfilePhotoPicker(
                        photos: referenceCandidates,
                        selectedIdentifier: draft.referencePhotoIdentifier,
                        choose: { identifier in
                            draft.referencePhotoIdentifier = identifier
                            return true
                        }
                    )
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var selectedPhoto: CatProfilePhotoPresentation? {
        referenceCandidates.first { $0.localIdentifier == draft.referencePhotoIdentifier }
    }
}
