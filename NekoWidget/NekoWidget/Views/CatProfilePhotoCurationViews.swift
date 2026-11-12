import SwiftUI

/// The photo tab supplies its current, scoped browser. Profile settings can
/// continue to use the lightweight preview while organizing membership.
typealias CatProfilePhotoDestination = (String, String) -> AnyView
private struct CatProfilePhotoDestinationKey: EnvironmentKey {
    static var defaultValue: CatProfilePhotoDestination? { nil }
}

extension EnvironmentValues {
    var catProfilePhotoDestination: CatProfilePhotoDestination? {
        get { self[CatProfilePhotoDestinationKey.self] }
        set { self[CatProfilePhotoDestinationKey.self] = newValue }
    }
}

/// The cat's one page: この子のこと. The name, the key photo and deleting are
/// in its 基本; the cat's photos are in the 写真 tab (11/7: one place each,
/// so the page has no 写真 tab of its own).
struct CatProfileDetailView: View {
    let profile: CatProfilePresentation
    let allProfiles: [CatProfilePresentation]
    let manualCandidatePhotos: [CatProfilePhotoPresentation]
    let photoAlbumOptions: [CatProfilePhotoAlbumOptionPresentation]
    let actions: CatProfilesViewActions
    /// Opened from the family notebook: the faces, not a second notebook (11/7).
    var insideFamilyNotebook = false

    @ObservedObject private var familyNotebook = FamilyNotebookPrototype.shared
    @ObservedObject private var catCare = CatCareStore.shared

    /// The family's names when this cat is in the family notebook, so the
    /// page shows whose cat it is: the whole page is the shared cat (11/7).
    private var familyNames: [String]? {
        guard let catID = CatCareSummary.record(profileIdentifier: profile.identifier)?.catID,
              familyNotebook.familyCats.contains(where: { $0.toolID == catID }) else { return nil }
        return familyNotebook.members.map(\.displayName)
    }

    var body: some View {
        CatCareDetailView(profile: profile, otherProfiles: [], selectedProfileID: .constant(profile.identifier))
            .environment(\.catCareInsideCatPage, true)
            // The page renames, changes the photo and deletes with these (11/7).
            .environment(\.toolProfileActions, actions)
            .navigationTitle(profile.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let familyNames, insideFamilyNotebook {
                    ToolbarItem(placement: .topBarTrailing) { FamilyFaces(names: familyNames) }
                } else if !insideFamilyNotebook, familyNames != nil || Version1.familyNotebook || familyNotebook.hasFamily {
                    ToolbarItem(placement: .topBarTrailing) { FamilyNotebookButton(sharedNames: familyNames) }
                }
            }
            // Memo weights show in この子のこと wherever the page opens (11/7).
            .task { await catCare.importMemoWeights() }
    }
}

/// 写真 tab with one cat chosen: the one place to add photos to that cat
/// (11/7: moved here from the cat's page). The same picker as before.
struct CatProfileAddPhotosButton: View {
    let profile: CatProfilePresentation
    let allProfiles: [CatProfilePresentation]
    let actions: CatProfilesViewActions
    @State private var showsAddPhotos = false
    @State private var showsNothingToAdd = false

    var body: some View {
        // 11/7: always enabled; with nothing to add it says so (was gray with no reason).
        Button {
            if profile.manualCandidatePhotos.isEmpty {
                showsNothingToAdd = true
            } else {
                showsAddPhotos = true
            }
        } label: {
            Label("この子の写真を追加", systemImage: "photo.badge.plus")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("photos-cat-add-photos")
        .alert("追加できる写真はありません", isPresented: $showsNothingToAdd) {
            Button("閉じる", role: .cancel) {}
        }
        .sheet(isPresented: $showsAddPhotos) {
            NavigationStack {
                UnassignedCatPhotosView(
                    photos: profile.manualCandidatePhotos,
                    profiles: allProfiles,
                    actions: actions,
                    navigationTitle: "猫の写真から追加",
                    preselectedProfileIdentifier: profile.identifier,
                    dismissAfterSaving: true
                )
            }
        }
    }
}

extension CatProfilePresentation {
    /// 「推定の誕生日 2020/5/1」「両方設定済み」「未設定」: the 誕生日・迎えた日 row.
    var lifeDatesSummary: String {
        if lifeDates.hasBothDates { return "どちらも入力済み" }
        guard let reference = lifeDates.birthday ?? lifeDates.adoptionDay ?? lifeReference else { return "未設定" }
        let prefix = reference.isApproximate ? "だいたいの" : ""
        return "\(prefix)\(reference.kind.title) \(reference.date.formatted(date: .numeric, time: .omitted))"
    }

    /// What the dates do: the album groups this cat's photos by them.
    var lifeDatesExplanation: String {
        guard let reference = lifeReference else {
            return "誕生日か迎えた日を入れると、アルバムを時期ごとにまとめます。"
        }
        switch reference.kind {
        case .birthday:
            return "アルバムで「子猫のころ」「1歳のころ」のようにまとめます。"
        case .adoptionDay:
            return "迎えた日を基準に「お迎えしたころ」「いっしょに暮らして1年」のようにまとめます。"
        }
    }
}

struct CatProfileLifeReferenceEditor: View {
    let profile: CatProfilePresentation
    let save: (String, CatProfileLifeDatesPresentation) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var dates: CatProfileLifeDatesPresentation
    @State private var isSaving = false
    @State private var saveFailed = false

    init(
        profile: CatProfilePresentation,
        save: @escaping (String, CatProfileLifeDatesPresentation) async -> Bool
    ) {
        self.profile = profile
        self.save = save
        _dates = State(initialValue: profile.lifeDates)
    }

    var body: some View {
        NavigationStack {
            Form {
                dateSection(.birthday)
                dateSection(.adoptionDay)
                if dates.hasBothDates {
                    Section {
                        Picker("成長アルバムで使う日", selection: primaryKind) {
                            ForEach(CatProfileLifeReferenceKindPresentation.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                    }
                }
                if saveFailed {
                    Section {
                        Text("日付を保存できませんでした。もう一度お試しください。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle("\(profile.displayName)の日付")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "保存") {
                        isSaving = true
                        saveFailed = false
                        Task {
                            let saved = await save(profile.identifier, dates)
                            isSaving = false
                            if saved { dismiss() } else { saveFailed = true }
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .appRecordEditing(retainWhileHidden: dates != profile.lifeDates || isSaving)
    }

    private func dateSection(_ kind: CatProfileLifeReferenceKindPresentation) -> some View {
        Section {
            Toggle("設定する", isOn: dateEnabled(kind))
            if reference(for: kind) != nil {
                DatePicker(
                    kind.title,
                    selection: referenceDate(kind),
                    in: ...Date.now,
                    displayedComponents: .date
                )
                Toggle("だいたいの日付", isOn: approximateDate(kind))
            }
        } header: {
            Text(kind.title)
        } footer: {
            if kind == .birthday {
                Text("分からないときは、だいたいの日付で大丈夫です。")
            }
        }
    }

    private var primaryKind: Binding<CatProfileLifeReferenceKindPresentation> {
        Binding(
            get: { dates.primaryKind ?? .birthday },
            set: { dates.primaryKind = $0 }
        )
    }

    private func reference(
        for kind: CatProfileLifeReferenceKindPresentation
    ) -> CatProfileLifeReferencePresentation? {
        kind == .birthday ? dates.birthday : dates.adoptionDay
    }

    private func setReference(
        _ reference: CatProfileLifeReferencePresentation?,
        for kind: CatProfileLifeReferenceKindPresentation
    ) {
        switch kind {
        case .birthday: dates.birthday = reference
        case .adoptionDay: dates.adoptionDay = reference
        }
        if let primary = dates.primaryKind, self.reference(for: primary) != nil { return }
        dates.primaryKind = dates.birthday != nil ? .birthday
            : (dates.adoptionDay != nil ? .adoptionDay : nil)
    }

    private func dateEnabled(_ kind: CatProfileLifeReferenceKindPresentation) -> Binding<Bool> {
        Binding(
            get: { reference(for: kind) != nil },
            set: { enabled in
                setReference(enabled ? CatProfileLifeReferencePresentation(
                    kind: kind, date: .now, isApproximate: false
                ) : nil, for: kind)
            }
        )
    }

    private func referenceDate(_ kind: CatProfileLifeReferenceKindPresentation) -> Binding<Date> {
        Binding(
            get: { reference(for: kind)?.date ?? .now },
            set: { date in
                guard var value = reference(for: kind) else { return }
                value.date = date
                setReference(value, for: kind)
            }
        )
    }

    private func approximateDate(_ kind: CatProfileLifeReferenceKindPresentation) -> Binding<Bool> {
        Binding(
            get: { reference(for: kind)?.isApproximate ?? false },
            set: { isApproximate in
                guard var value = reference(for: kind) else { return }
                value.isApproximate = isApproximate
                setReference(value, for: kind)
            }
        )
    }

}

struct CatProfileConfirmedPhotosView: View {
    @Environment(\.catProfilePhotoDestination) private var photoDestination

    let profile: CatProfilePresentation
    let allProfiles: [CatProfilePresentation]
    let actions: CatProfilesViewActions
    /// Supplied by the cat list; omitted when opened from profile settings.
    var profileSettingsAlbumOptions: [CatProfilePhotoAlbumOptionPresentation]? = nil

    @State private var selection = Set<String>()
    @State private var isSelecting = false
    @State private var previewPhoto: CatProfilePhotoPresentation?
    @State private var openedPhotoIdentifier: String?
    @State private var showsProfileSettings = false
    @State private var showsAddPhotos = false
    @State private var showsAssignmentSheet = false
    @State private var showsRemoveConfirmation = false
    @State private var showsGlobalExclusionConfirmation = false
    @State private var isRemoving = false
    @State private var membershipSaveFailed = false

    var body: some View {
        Group {
            if profile.confirmedPhotos.isEmpty {
                ContentUnavailableView {
                    Label("\(profile.displayName)の写真", systemImage: "photo.on.rectangle")
                } description: {
                    Text("この子が写っている写真を追加すると、ここで見返せます。")
                } actions: {
                    addPhotosButton
                }
            } else if isSelecting {
                CatSelectablePhotoGrid(photos: profile.confirmedPhotos, selection: $selection)
            } else {
                CatSelectablePhotoGrid(
                    photos: profile.confirmedPhotos,
                    selection: .constant([]),
                    onChoose: { identifier in
                        if photoDestination != nil {
                            openedPhotoIdentifier = identifier
                        } else {
                            previewPhoto = profile.confirmedPhotos.first { $0.localIdentifier == identifier }
                        }
                    },
                    showsSelectionMarks: false
                )
            }
        }
        .disabled(isRemoving)
        .navigationTitle("\(profile.displayName)の写真")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button("完了") {
                        selection.removeAll()
                        isSelecting = false
                    }
                    .disabled(isRemoving)
                    .accessibilityIdentifier("cat-profile-select")
                } else if !profile.confirmedPhotos.isEmpty || profileSettingsAlbumOptions != nil {
                    Menu {
                        if !profile.confirmedPhotos.isEmpty {
                            Button("写真を選択", systemImage: "checkmark.circle") {
                                selection.removeAll()
                                isSelecting = true
                            }
                            .accessibilityIdentifier("cat-profile-select")

                            Button("この子の写真を追加", systemImage: "photo.badge.plus") {
                                showsAddPhotos = true
                            }
                            .accessibilityIdentifier("cat-profile-add-photos")
                            .disabled(profile.manualCandidatePhotos.isEmpty)
                        }
                        if profileSettingsAlbumOptions != nil {
                            Button("この子のことを開く", systemImage: "cat") {
                                showsProfileSettings = true
                            }
                            .accessibilityLabel("\(profile.displayName)のことを開く")
                            .accessibilityIdentifier("cat-profile-settings")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("\(profile.displayName)の写真のその他の操作")
                    .accessibilityIdentifier("cat-profile-more")
                    .disabled(isRemoving)
                }
            }
        }
        .navigationDestination(item: $openedPhotoIdentifier) { identifier in
            if let photoDestination {
                photoDestination(profile.identifier, identifier)
            }
        }
        .navigationDestination(isPresented: $showsProfileSettings) {
            if let albums = profileSettingsAlbumOptions {
                CatProfileDetailView(
                    profile: profile,
                    allProfiles: allProfiles,
                    manualCandidatePhotos: profile.manualCandidatePhotos,
                    photoAlbumOptions: albums,
                    actions: actions
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !selection.isEmpty {
                actionBar
            }
        }
        .sheet(isPresented: $showsAddPhotos) {
            NavigationStack {
                UnassignedCatPhotosView(
                    photos: profile.manualCandidatePhotos,
                    profiles: allProfiles,
                    actions: actions,
                    navigationTitle: "猫の写真から追加",
                    preselectedProfileIdentifier: profile.identifier,
                    dismissAfterSaving: true
                )
            }
        }
        .sheet(item: $previewPhoto) { photo in
            CatProfilePhotoPreview(photo: photo)
        }
        .sheet(isPresented: $showsAssignmentSheet) {
            CatPhotoAssignmentSheet(
                photoIdentifiers: Array(selection),
                profiles: allProfiles,
                initialAssignmentsByPhotoIdentifier: selectedAssignmentsByPhotoIdentifier,
                save: { assignments in
                    let saved = await actions.replacePhotoAssignments(assignments)
                    if saved { selection.removeAll() }
                    return saved
                }
            )
        }
        .confirmationDialog(
            "\(profile.displayName)の写真ではありませんか？",
            isPresented: $showsRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("\(profile.displayName)ではない") {
                let identifiers = Array(selection)
                isRemoving = true
                membershipSaveFailed = false
                Task {
                    let saved = await actions.removeProfileMembership(profile.identifier, identifiers)
                    isRemoving = false
                    if saved { selection.removeAll() } else { membershipSaveFailed = true }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ほかの子や「すべての猫」には残ります。")
        }
        .confirmationDialog(
            "猫の写真から外しますか？",
            isPresented: $showsGlobalExclusionConfirmation,
            titleVisibility: .visible
        ) {
            Button("猫の写真から外す", role: .destructive) {
                let identifiers = Array(selection)
                selection.removeAll()
                Task { await actions.excludeFromHousehold(identifiers) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("写真アプリの写真は消えません。")
        }
    }

    private var addPhotosButton: some View {
        Button {
            showsAddPhotos = true
        } label: {
            Label("この子の写真を追加", systemImage: "photo.badge.plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(profile.manualCandidatePhotos.isEmpty || isRemoving)
        .accessibilityIdentifier("cat-profile-add-photos")
    }

    private var selectedAssignmentsByPhotoIdentifier: [String: Set<String>] {
        let selectedPhotos = profile.confirmedPhotos.filter {
            selection.contains($0.localIdentifier)
        }
        return Dictionary(uniqueKeysWithValues: selectedPhotos.map {
            ($0.localIdentifier, $0.assignedProfileIdentifiers)
        })
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            if membershipSaveFailed {
                Text("変更を保存できませんでした。もう一度お試しください。")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Text("\(selection.count.formatted())枚を選択中")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("写っている猫を選ぶ", systemImage: "cat") {
                    showsAssignmentSheet = true
                }
                Spacer()
                Menu {
                    Button("\(profile.displayName)ではない") {
                        showsRemoveConfirmation = true
                    }
                    Button("猫の写真から外す", role: .destructive) {
                        showsGlobalExclusionConfirmation = true
                    }
                } label: {
                    Label("ほかの操作", systemImage: "ellipsis.circle")
                }
            }
        }
        .disabled(isRemoving)
        .padding(12)
        .background(.regularMaterial)
    }
}

private struct CatProfilePhotoPreview: View {
    let photo: CatProfilePhotoPresentation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                PhotoAssetImageView(
                    localIdentifier: photo.localIdentifier,
                    targetPixelSize: CGSize(width: 1600, height: 1600),
                    showsFullImage: true,
                    allowsZoom: true
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .navigationTitle(photo.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "写真")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("閉じる")
                }
            }
        }
    }
}

struct UnassignedCatPhotosView: View {
    let photos: [CatProfilePhotoPresentation]
    let profiles: [CatProfilePresentation]
    let actions: CatProfilesViewActions
    var navigationTitle = "未分類の写真"
    /// A picker opened from one cat's page starts with that cat selected while
    /// preserving any other explicit profile assignments on the same photo.
    var preselectedProfileIdentifier: String? = nil
    var dismissAfterSaving = false
    var onPhotosAdded: ((Int) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()
    @State private var showsAssignmentSheet = false
    @State private var showsGlobalExclusionConfirmation = false
    @State private var isSaving = false
    @State private var saveFailed = false
    @State private var assignmentWasSaved = false

    var body: some View {
        Group {
            if photos.isEmpty {
                ContentUnavailableView(
                    "選べる写真はありません",
                    systemImage: "checkmark.circle"
                )
            } else {
                CatSelectablePhotoGrid(
                    photos: photos,
                    selection: $selection,
                    gridAccessibilityIdentifier: "cat-profile-add-picker"
                )
            }
        }
        .disabled(isSaving)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            if dismissAfterSaving {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(isSaving)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty { actionBar }
        }
        .sheet(isPresented: $showsAssignmentSheet, onDismiss: {
            if assignmentWasSaved && dismissAfterSaving { dismiss() }
            assignmentWasSaved = false
        }) {
            CatPhotoAssignmentSheet(
                photoIdentifiers: Array(selection),
                profiles: profiles,
                initialAssignmentsByPhotoIdentifier: selectedAssignmentsByPhotoIdentifier,
                save: { assignments in
                    let saved = await actions.replacePhotoAssignments(assignments)
                    if saved {
                        let addedCount = preselectedProfileIdentifier.map { profileID in
                            assignments.values.filter { $0.contains(profileID) }.count
                        } ?? 0
                        if addedCount > 0 { onPhotosAdded?(addedCount) }
                        assignmentWasSaved = true
                        selection.removeAll()
                    }
                    return saved
                }
            )
        }
        .confirmationDialog(
            "猫の写真から外しますか？",
            isPresented: $showsGlobalExclusionConfirmation,
            titleVisibility: .visible
        ) {
            Button("猫の写真から外す", role: .destructive) {
                let identifiers = Array(selection)
                selection.removeAll()
                Task { await actions.excludeFromHousehold(identifiers) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("写真アプリの写真は消えません。")
        }
    }

    private var selectedAssignmentsByPhotoIdentifier: [String: Set<String>] {
        let selectedPhotos = photos.filter { selection.contains($0.localIdentifier) }
        return Dictionary(uniqueKeysWithValues: selectedPhotos.map {
            var identifiers = $0.assignedProfileIdentifiers
            if let preselectedProfileIdentifier {
                identifiers.insert(preselectedProfileIdentifier)
            }
            return ($0.localIdentifier, identifiers)
        })
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if saveFailed {
                Text("追加できませんでした。もう一度お試しください。")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let profileID = preselectedProfileIdentifier {
                Button {
                    addSelectedPhotos(to: profileID)
                } label: {
                    let catName = profiles.first(where: { $0.identifier == profileID })?.displayName ?? "この子"
                    Text(isSaving ? "追加中…" : "\(catName)に\(selection.count.formatted())枚追加")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("cat-profile-confirm-add")
                .disabled(!profiles.contains { $0.identifier == profileID })
                if profiles.count > 1 {
                    Button("ほかの猫も選ぶ", systemImage: "cat") {
                        showsAssignmentSheet = true
                    }
                }
            } else {
                HStack {
                    Button("写っている猫を選ぶ", systemImage: "cat") {
                        showsAssignmentSheet = true
                    }
                    .disabled(profiles.isEmpty)
                    Spacer()
                    Button(role: .destructive) {
                        showsGlobalExclusionConfirmation = true
                    } label: {
                        Label("猫の写真から外す", systemImage: "eye.slash")
                    }
                }
            }
        }
        .disabled(isSaving)
        .padding(12)
        .background(.regularMaterial)
    }

    private func addSelectedPhotos(to profileIdentifier: String) {
        guard !isSaving, !selection.isEmpty,
              profiles.contains(where: { $0.identifier == profileIdentifier }) else { return }
        let identifiers = Array(selection)
        isSaving = true
        saveFailed = false
        Task {
            // Add only this cat. Do not replace another cat's membership.
            let saved = await actions.confirmProfileMembership(profileIdentifier, identifiers)
            isSaving = false
            if saved {
                onPhotosAdded?(identifiers.count)
                selection.removeAll()
                if dismissAfterSaving { dismiss() }
            } else {
                saveFailed = true
            }
        }
    }
}

struct CatPhotoAssignmentSheet: View {
    let photoIdentifiers: [String]
    let profiles: [CatProfilePresentation]
    let save: ([String: Set<String>]) async -> Bool

    @Environment(\.dismiss) private var dismiss
    private let initialBatch: CatPhotoAssignmentBatchPresentation
    @State private var assignmentBatch: CatPhotoAssignmentBatchPresentation
    @State private var isSaving = false
    @State private var saveFailed = false

    init(
        photoIdentifiers: [String],
        profiles: [CatProfilePresentation],
        initialAssignmentsByPhotoIdentifier: [String: Set<String>],
        save: @escaping ([String: Set<String>]) async -> Bool
    ) {
        self.photoIdentifiers = photoIdentifiers
        self.profiles = profiles
        self.save = save
        let batch = CatPhotoAssignmentBatchPresentation(photoIdentifiers: photoIdentifiers,
            initialAssignmentsByPhotoIdentifier: initialAssignmentsByPhotoIdentifier)
        initialBatch = batch
        _assignmentBatch = State(initialValue: batch)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(profiles) { profile in
                        Button {
                            assignmentBatch.toggle(profileIdentifier: profile.identifier)
                        } label: {
                            HStack {
                                CatProfileThumbnail(photo: profile.coverPhoto)
                                    .frame(width: 42, height: 42)
                                Text(profile.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                switch assignmentBatch.state(for: profile.identifier) {
                                case .all:
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                case .some:
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.orange)
                                        .accessibilityLabel("一部の写真だけ")
                                case .none:
                                    Image(systemName: "circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("写っている猫（何匹でも選べます）")
                } footer: {
                    Text("「−」は、選んだ写真の一部にだけ付いている猫です。")
                }

                if saveFailed {
                    Section {
                        Text("選択を保存できませんでした。もう一度お試しください。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle("写っている猫を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "保存") {
                        isSaving = true
                        saveFailed = false
                        Task {
                            let saved = await save(assignmentBatch.assignmentsByPhotoIdentifier)
                            isSaving = false
                            if saved { dismiss() } else { saveFailed = true }
                        }
                    }
                    .disabled(isSaving || photoIdentifiers.isEmpty || profiles.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .appRecordEditing(retainWhileHidden: assignmentBatch != initialBatch || isSaving)
    }

}

/// Reuses the candidate grid for a single explicit choice. The presenting
/// view owns its NavigationStack, and a failed write keeps this picker open.
struct CatProfilePhotoPicker: View {
    let photos: [CatProfilePhotoPresentation]
    let selectedIdentifier: String?
    let choose: (String) async -> Bool
    var progressTitle = "保存中…"
    var failureMessage = "選択を保存できませんでした。もう一度お試しください。"

    @Environment(\.dismiss) private var dismiss
    @State private var savingIdentifier: String?
    @State private var saveFailed = false

    var body: some View {
        Group {
            if photos.isEmpty {
                ContentUnavailableView("選べる写真はありません", systemImage: "photo")
            } else {
                CatSelectablePhotoGrid(
                    photos: photos,
                    selection: .constant(Set(selectedIdentifier.map { [$0] } ?? [])),
                    onChoose: { identifier in
                        guard savingIdentifier == nil else { return }
                        savingIdentifier = identifier
                        saveFailed = false
                        Task {
                            let saved = await choose(identifier)
                            savingIdentifier = nil
                            if saved { dismiss() } else { saveFailed = true }
                        }
                    }
                )
                .disabled(savingIdentifier != nil)
            }
        }
        .navigationTitle("写真を選ぶ")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(savingIdentifier != nil)
        .safeAreaInset(edge: .bottom) {
            if savingIdentifier != nil || saveFailed {
                VStack {
                    if savingIdentifier != nil {
                        ProgressView(progressTitle)
                    } else {
                        Text(failureMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.regularMaterial)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("キャンセル") { dismiss() }
                    .disabled(savingIdentifier != nil)
            }
        }
        .interactiveDismissDisabled(savingIdentifier != nil)
    }
}

private struct CatSelectablePhotoGrid: View {
    let photos: [CatProfilePhotoPresentation]
    @Binding var selection: Set<String>
    var gridAccessibilityIdentifier = "cat-profile-photo-grid"
    var onChoose: ((String) -> Void)? = nil
    var showsSelectionMarks = true

    private let columns = [
        GridItem(.adaptive(minimum: 104), spacing: 3)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(photos) { photo in
                    Button {
                        if let onChoose {
                            onChoose(photo.localIdentifier)
                        } else {
                            toggle(photo.localIdentifier)
                        }
                    } label: {
                        PhotoAssetImageView(
                            localIdentifier: photo.localIdentifier,
                            catBoundingBox: photo.catBoundingBox,
                            targetPixelSize: CGSize(width: 360, height: 360),
                            targetAspectRatio: 1
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(alignment: .topTrailing) {
                            if showsSelectionMarks {
                                selectionMark(for: photo.localIdentifier)
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if photo.detectedCatCount > 1 {
                                Label(
                                    "\(photo.detectedCatCount)匹",
                                    systemImage: "pawprint.fill"
                                )
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .foregroundStyle(.white)
                                .background(.black.opacity(0.58), in: Capsule())
                                .padding(5)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cat-profile-photo")
                    .accessibilityLabel(accessibilityLabel(for: photo))
                    .accessibilityAddTraits(
                        selection.contains(photo.localIdentifier) ? .isSelected : []
                    )
                }
            }
            .padding(3)
        }
        .accessibilityIdentifier(gridAccessibilityIdentifier)
        .background(Color(.systemGroupedBackground))
    }

    private func toggle(_ identifier: String) {
        if selection.contains(identifier) {
            selection.remove(identifier)
        } else {
            selection.insert(identifier)
        }
    }

    @ViewBuilder
    private func selectionMark(for identifier: String) -> some View {
        if selection.contains(identifier) {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .font(.title3)
                .padding(6)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.white)
                .font(.title3)
                .shadow(radius: 2)
                .padding(6)
        }
    }

    private func accessibilityLabel(for photo: CatProfilePhotoPresentation) -> String {
        let date = photo.creationDate?.formatted(date: .abbreviated, time: .omitted)
            ?? "撮影日不明"
        let cats = photo.detectedCatCount > 1 ? "猫\(photo.detectedCatCount)匹" : "猫1匹"
        return "\(date)、\(cats)"
    }
}
