import SwiftUI

/// Integration boundary for the optional multi-cat experience. Every
/// membership is explicit and user-confirmed; this build does not perform
/// automatic individual-cat identification.
struct CatProfilesViewActions {
    var exportProfileDates: () throws -> Data
    var previewProfileImport: (Data) throws -> CatProfileImportPreview
    var importProfileDates: (CatProfileImportPreview) async -> Result<Bool, Error>
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
        exportProfileDates: { throw CatProfileTransferError.notReady },
        previewProfileImport: { _ in throw CatProfileTransferError.notReady },
        importProfileDates: { _ in .failure(CatProfileTransferError.notReady) },
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
    var opensProfileSettings = false

    private struct CreationRequest: Identifiable {
        let id = UUID()
        let photoIdentifier: String?
    }

    private enum OrganizationDestination: String, Identifiable {
        case unassigned, excluded
        var id: String { rawValue }
    }

    @State private var creationRequest: CreationRequest?
    @State private var showsCreationPhotoPicker = false
    @State private var creationPhotoIdentifier: String?
    @State private var continuesProfileCreation = false
    @State private var createdProfileIdentifier: String?
    @State private var openedProfileIdentifier: String?
    @State private var organizationDestination: OrganizationDestination?
    @State private var showsAbout = false

    var body: some View {
        Form {
            if presentation.profiles.isEmpty {
                optionalSetupSection
            }
            if !presentation.profiles.isEmpty {
                profilesSection
            }
        }
        .navigationTitle(opensProfileSettings ? "猫のプロフィール" : "猫ごとの写真")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: startAddingCat) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("猫を追加")
                .accessibilityIdentifier("cat-profile-add")

                organizationMenu
            }
        }
        .navigationDestination(item: $organizationDestination) { destination in
            switch destination {
            case .unassigned:
                UnassignedCatPhotosView(
                    photos: presentation.unassignedPhotos,
                    profiles: presentation.profiles,
                    actions: actions
                )
            case .excluded:
                LegacyCatExclusionReviewView(
                    photos: presentation.legacyExcludedPhotos,
                    restore: actions.restoreLegacyExclusions
                )
            }
        }
        .sheet(isPresented: $showsAbout) {
            NavigationStack {
                Form {
                    Section {
                        Text("写真を選んで、写っている猫にまとめられます。すべての写真を分ける必要はありません。")
                    } footer: {
                        Text(CatIndividualRecognitionCopy.unavailable)
                    }
                    Section {
                        Text("猫の登録は任意です。名前や写真の振り分けは、このiPhone内で管理します。")
                    }
                }
                .navigationTitle("猫ごとの写真について")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("閉じる", systemImage: "xmark") { showsAbout = false }
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .sheet(isPresented: $showsCreationPhotoPicker, onDismiss: {
            if continuesProfileCreation {
                continuesProfileCreation = false
                creationRequest = CreationRequest(photoIdentifier: creationPhotoIdentifier)
            }
        }) {
            NavigationStack {
                CatProfilePhotoPicker(
                    photos: presentation.profileCreationPhotos,
                    selectedIdentifier: nil,
                    choose: { identifier in
                        creationPhotoIdentifier = identifier
                        continuesProfileCreation = true
                        return true
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("写真はあとで") {
                            continuesProfileCreation = true
                            showsCreationPhotoPicker = false
                        }
                    }
                }
            }
        }
        .sheet(item: $creationRequest, onDismiss: {
            openedProfileIdentifier = createdProfileIdentifier
            createdProfileIdentifier = nil
        }) { request in
            AddCatProfileView(
                referenceCandidates: presentation.profileCreationPhotos,
                initialLifeReference: presentation.legacyLifeReference,
                initialPhotoIdentifier: request.photoIdentifier,
                createProfile: actions.createProfile,
                onCreated: { createdProfileIdentifier = $0 }
            )
            .id(request.id)
        }
        .navigationDestination(item: $openedProfileIdentifier) { identifier in
            if let profile = presentation.profiles.first(where: { $0.identifier == identifier }) {
                profileDetail(profile)
            }
        }
        .onChange(of: presentation.profiles.map(\.identifier)) { _, identifiers in
            if let openedProfileIdentifier, !identifiers.contains(openedProfileIdentifier) {
                self.openedProfileIdentifier = nil
            }
        }
    }

    private var optionalSetupSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("猫ごとに写真を見返す")
                        .font(.headline)
                    Text("写真を1枚選んで、写っている猫に名前を付けるところから。あとから写真を追加できます。")
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
                Button {
                    openedProfileIdentifier = profile.identifier
                } label: {
                    HStack {
                        CatProfileRow(profile: profile)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cat-profile-open")
                .accessibilityHint(opensProfileSettings
                    ? "この子のプロフィールを開きます"
                    : "この子の写真を開きます")
            }

        }
    }

    private func startAddingCat() {
        creationPhotoIdentifier = nil
        continuesProfileCreation = false
        if presentation.profileCreationPhotos.isEmpty {
            creationRequest = CreationRequest(photoIdentifier: nil)
        } else {
            showsCreationPhotoPicker = true
        }
    }

    private var organizationMenu: some View {
        Menu {
            if !presentation.profiles.isEmpty && !presentation.unassignedPhotos.isEmpty {
                Button {
                    organizationDestination = .unassigned
                } label: {
                    Label("どの猫か決めていない写真", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("cat-profiles-unassigned")
            }
            if !presentation.legacyExcludedPhotos.isEmpty {
                Button {
                    organizationDestination = .excluded
                } label: {
                    Label("以前除外した写真", systemImage: "arrow.uturn.backward")
                }
                .accessibilityIdentifier("cat-profiles-excluded")
            }
            Button {
                showsAbout = true
            } label: {
                Label("猫ごとの写真について", systemImage: "info.circle")
            }
            .accessibilityIdentifier("cat-profiles-about")
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("猫ごとの写真のメニュー")
        .accessibilityIdentifier("cat-profiles-more")
    }

    @ViewBuilder
    private func profileDetail(_ profile: CatProfilePresentation) -> some View {
        if opensProfileSettings {
            CatProfileDetailView(
                profile: profile,
                allProfiles: presentation.profiles,
                manualCandidatePhotos: profile.manualCandidatePhotos,
                photoAlbumOptions: presentation.photoAlbumOptions,
                actions: actions
            )
        } else {
            CatProfileConfirmedPhotosView(
                profile: profile,
                allProfiles: presentation.profiles,
                actions: actions,
                profileSettingsAlbumOptions: presentation.photoAlbumOptions
            )
        }
    }

}

#if DEBUG
/// In-memory UI fixture using the existing generated screenshot images.
/// No PhotoKit library, files, accounts, or production membership are changed.
@MainActor
struct CatProfilePhotoFlowFixture: View {
    @State private var names: [String] = []
    @State private var memberships: [String: Set<String>] = [:]
    @State private var rejectsNextAdd = true

    private let showsListFixture = CommandLine.arguments.contains("--cat-profile-list-fixture")

    init() {
        if CommandLine.arguments.contains("--cat-profile-list-fixture") {
            let sampleNames = ["ミケ", "ソラ"]
            _names = State(initialValue: sampleNames)
            _memberships = State(initialValue: Dictionary(uniqueKeysWithValues:
                zip(AppStoreScreenshotFixture.photos.prefix(2), sampleNames).map {
                    ($0.0.localIdentifier, Set([$0.1]))
                }
            ))
        }
    }

    private var photos: [CatProfilePhotoPresentation] {
        AppStoreScreenshotFixture.photos.prefix(3).map {
            CatProfilePhotoPresentation(
                localIdentifier: $0.localIdentifier,
                creationDate: $0.creationDate,
                catBoundingBox: $0.catBoundingBox,
                assignedProfileIdentifiers: memberships[$0.localIdentifier] ?? []
            )
        }
    }

    private var presentation: CatProfilesPresentation {
        CatProfilesPresentation(
            profiles: names.map { name in
                let confirmed = photos.filter { $0.assignedProfileIdentifiers.contains(name) }
                return CatProfilePresentation(
                    identifier: name, name: name,
                    coverPhoto: confirmed.first,
                    confirmedPhotos: confirmed,
                    manualCandidatePhotos: photos.filter { !$0.assignedProfileIdentifiers.contains(name) }
                )
            },
            unassignedPhotos: photos.filter { $0.assignedProfileIdentifiers.isEmpty },
            legacyExcludedPhotos: showsListFixture ? [
                LegacyExcludedCatPhotoPresentation(localIdentifier: AppStoreScreenshotFixture.photos[3].localIdentifier)
            ] : []
        )
    }

    private var actions: CatProfilesViewActions {
        var value = CatProfilesViewActions.noOp
        value.createProfile = { draft in
            guard !names.contains(draft.name) else { return nil }
            names.append(draft.name)
            if let identifier = draft.referencePhotoIdentifier {
                memberships[identifier, default: []].insert(draft.name)
            }
            return draft.name
        }
        value.confirmProfileMembership = { name, identifiers in
            if rejectsNextAdd {
                rejectsNextAdd = false
                return false
            }
            for identifier in identifiers { memberships[identifier, default: []].insert(name) }
            return true
        }
        value.replacePhotoAssignments = { assignments in
            for (identifier, names) in assignments { memberships[identifier] = names }
            return true
        }
        value.deleteProfile = { name in
            names.removeAll { $0 == name }
            for identifier in Array(memberships.keys) { memberships[identifier]?.remove(name) }
            return true
        }
        return value
    }

    var body: some View {
        NavigationStack {
            CatProfilesView(presentation: presentation, actions: actions)
        }
    }
}
#endif


private struct CatProfileRow: View {
    let profile: CatProfilePresentation

    var body: some View {
        HStack(spacing: 12) {
            CatProfileThumbnail(photo: profile.coverPhoto)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName)
                    .font(.headline)
                Text("\(profile.confirmedPhotoCount.formatted())枚")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Matching entrances to a cat's photos or albums; these navigate, not filter.
struct CatProfileNavigationLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let profile: CatProfilePresentation

    var body: some View {
        HStack(spacing: 8) {
            CatProfileThumbnail(photo: profile.coverPhoto)
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            Text(profile.displayName)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
    }
}

struct CatProfileNavigationStrip<Links: View, More: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder var links: () -> Links
    @ViewBuilder var more: () -> More

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    links()
                    more()
                }
            } else {
                HStack(spacing: 8) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) { links() }
                    }
                    .scrollIndicators(.hidden)
                    more()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
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
                    title: "すべての猫",
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
    private let initialDraft: CatProfileDraftPresentation
    @State private var draft: CatProfileDraftPresentation
    @State private var isSaving = false
    @State private var showsPhotoPicker = false
    @State private var saveFailed = false

    init(
        referenceCandidates: [CatProfilePhotoPresentation],
        initialLifeReference: CatProfileLifeReferencePresentation?,
        initialPhotoIdentifier: String? = nil,
        createProfile: @escaping (CatProfileDraftPresentation) async -> String?,
        onCreated: @escaping (String) -> Void
    ) {
        self.referenceCandidates = referenceCandidates
        self.createProfile = createProfile
        self.onCreated = onCreated
        let initial = CatProfileDraftPresentation(lifeReference: initialLifeReference,
            referencePhotoIdentifier: initialPhotoIdentifier)
        initialDraft = initial
        _draft = State(initialValue: initial)
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
                                Text(selectedPhoto == nil ? "この子の写真を選ぶ" : "別の写真を選ぶ")
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
                    Text("選んだ写真はこの子の写真に追加されます。誕生日などは、あとから設定できます。")
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
                        isSaving = true
                        saveFailed = false
                        Task {
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
        .appRecordEditing(retainWhileHidden: draft != initialDraft || isSaving || showsPhotoPicker)
    }

    private var selectedPhoto: CatProfilePhotoPresentation? {
        referenceCandidates.first { $0.localIdentifier == draft.referencePhotoIdentifier }
    }
}

private struct ToolProfileActionsKey: EnvironmentKey {
    static let defaultValue = CatProfilesViewActions.noOp
}
extension EnvironmentValues {
    var toolProfileActions: CatProfilesViewActions {
        get { self[ToolProfileActionsKey.self] }
        set { self[ToolProfileActionsKey.self] = newValue }
    }
}

/// Every tool reads the same ordered profile list. Creation is an explicit user action.
struct ToolCatPicker<Legacy: View>: View {
    let profiles: [CatProfilePresentation]
    let select: (CatProfilePresentation) -> Void
    @ViewBuilder var legacy: () -> Legacy
    @Environment(\.toolProfileActions) private var actions
    @State private var addsCat = false
    @State private var name = ""
    @State private var failed = false
    @State private var busy = false
    @AppStorage(CatFarewell.key) private var farewellJSON = ""
    var body: some View {
        Group {
            Section("猫のプロフィール") {
                // A cat whose day was recorded is not offered for a new plan.
                ForEach(profiles.filter { CatFarewell.days(farewellJSON)[$0.identifier] == nil }) { profile in
                    // A row that opens the cat's page: black text and a chevron, like a link.
                    Button { select(profile) } label: {
                        HStack {
                            Label(profile.displayName, systemImage: "cat")
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("tool-profile-\(profile.identifier)")
                }
                Button("猫を追加", systemImage: "plus") { name = ""; addsCat = true }
                    .accessibilityIdentifier("tool-profile-add").disabled(busy)
            }
            legacy()
        }
        .alert("猫を追加", isPresented: $addsCat) {
            TextField("名前", text: $name)
            Button("追加") {
                busy = true
                Task {
                    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let id = await actions.createProfile(CatProfileDraftPresentation(name: value))
                    busy = false
                    if let id {
                        select(CatProfilePresentation(identifier: id, name: value, coverPhoto: nil,
                            confirmedPhotos: [], lifeReference: nil))
                    } else { failed = true }
                }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("キャンセル", role: .cancel) {}
        } message: { Text("名前だけで登録できます。写真や日付はあとから設定できます。") }
        .alert("プロフィールを追加できませんでした", isPresented: $failed) {
            Button("閉じる", role: .cancel) {}
        } message: { Text("入力は残っています。もう一度お試しください。") }
    }
}

/// A cat in the row at the top of a もしも tool.
struct ToolStripCat: Identifiable, Equatable {
    let id: String
    let name: String
    /// nil for a cat without a profile (one written only in a tool).
    let profile: CatProfilePresentation?
    /// Kept from the old lists, so the same identifier still finds the cat.
    let accessibilityIdentifier: String
}

/// The row of cats at the top of a もしも tool: round photo and name, the
/// chosen one ringed. Tapping switches the page in place. With one cat
/// there is nothing to choose, so the row stays away.
struct ToolCatStrip: View {
    let cats: [ToolStripCat]
    let selectedID: String?
    let select: (ToolStripCat) -> Void
    @AppStorage(CatFarewell.key) private var farewellJSON = ""

    /// A cat whose day was recorded leaves the row, unless its page is the
    /// one open. Its plans stay; only the row stops offering it.
    private var shown: [ToolStripCat] {
        let farewells = CatFarewell.days(farewellJSON)
        return cats.filter { cat in
            cat.id == selectedID || cat.profile.map { farewells[$0.identifier] == nil } ?? true
        }
    }

    var body: some View {
        let cats = shown
        if cats.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(cats) { cat in
                        Button { select(cat) } label: { chip(cat) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(cat.name)
                            .accessibilityAddTraits(cat.id == selectedID ? .isSelected : [])
                            .accessibilityIdentifier(cat.accessibilityIdentifier)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityIdentifier("tool-cat-strip")
        }
    }

    private func chip(_ cat: ToolStripCat) -> some View {
        let chosen = cat.id == selectedID
        return VStack(spacing: 4) {
            Group {
                if let profile = cat.profile {
                    CatProfileThumbnail(photo: profile.coverPhoto)
                } else {
                    Image(systemName: "cat")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.tertiarySystemFill))
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())
            .overlay(Circle().stroke(chosen ? Color.accentColor : Color.clear, lineWidth: 3))
            .padding(3)
            Text(cat.name)
                .font(.caption.weight(chosen ? .bold : .regular))
                .foregroundStyle(chosen ? .primary : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(width: 72)
        .contentShape(Rectangle())
    }
}

struct ToolCatProfileInfo: View {
    let profile: CatProfilePresentation
    let profiles: [CatProfilePresentation]
    @Environment(\.toolProfileActions) private var actions
    var body: some View {
        Section("猫のプロフィール") {
            LabeledContent("名前", value: profile.displayName)
            if let birthday = profile.lifeDates.birthday {
                LabeledContent("誕生日", value: birthday.date.formatted(date: .abbreviated, time: .omitted))
            }
            if let adoption = profile.lifeDates.adoptionDay {
                LabeledContent("迎えた日", value: adoption.date.formatted(date: .abbreviated, time: .omitted))
            }
            NavigationLink("猫のプロフィールで編集") {
                CatProfileDetailView(profile: profile, allProfiles: profiles,
                    manualCandidatePhotos: profile.manualCandidatePhotos, photoAlbumOptions: [], actions: actions)
            }
        }
    }
}

struct ToolPromoteCatButton: View {
    let name: String
    let link: (String) -> Bool
    @Environment(\.toolProfileActions) private var actions
    @State private var busy = false
    @State private var failed = false
    @State private var createdID: String?
    var body: some View {
        Button(createdID == nil ? "プロフィールにする" : "プロフィールとの接続を再試行") {
            busy = true
            Task {
                let id: String?
                if let createdID { id = createdID }
                else { id = await actions.createProfile(CatProfileDraftPresentation(name: name.isEmpty ? "名前未設定の猫" : name)) }
                createdID = id
                failed = id.map { !link($0) } ?? true
                busy = false
            }
        }.disabled(busy)
        .alert("プロフィールとの接続を完了できませんでした", isPresented: $failed) {
            Button("閉じる", role: .cancel) {}
        } message: { Text("元の記録と写真は残っています。保存状態を確認して再試行してください。") }
    }
}

@MainActor
enum ToolCatProfileLinker {
    static func care(_ id: UUID, profileID: String, care: CareHandoffStore, evacuation: EvacuationStore) -> Bool {
        guard let cat = care.plan.cats.first(where: { $0.id == id }),
              care.loadError == nil, care.saveError == nil, evacuation.loadError == nil, evacuation.saveError == nil else { return false }
        let matches = evacuation.plan.cats.filter { ($0.toolCatID ?? $0.id) == (cat.toolCatID ?? cat.id) }
        guard matches.count <= 1, matches.allSatisfy({ $0.profileID == nil || $0.profileID == cat.profileID || $0.profileID == profileID }) else { return false }
        if let counterpart = matches.first, !evacuation.linkProfile(profileID, to: counterpart.id) { return false }
        return care.linkProfile(profileID, to: id)
    }
    static func evacuation(_ id: UUID, profileID: String, care: CareHandoffStore, evacuation: EvacuationStore) -> Bool {
        guard let cat = evacuation.plan.cats.first(where: { $0.id == id }),
              care.loadError == nil, care.saveError == nil, evacuation.loadError == nil, evacuation.saveError == nil else { return false }
        let matches = care.plan.cats.filter { ($0.toolCatID ?? $0.id) == (cat.toolCatID ?? cat.id) }
        guard matches.count <= 1, matches.allSatisfy({ $0.profileID == nil || $0.profileID == cat.profileID || $0.profileID == profileID }) else { return false }
        if let counterpart = matches.first, !care.linkProfile(profileID, to: counterpart.id) { return false }
        return evacuation.linkProfile(profileID, to: id)
    }
}
