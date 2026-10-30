import SwiftUI

/// The photo tab supplies its current, scoped browser. Profile settings can
/// continue to use the lightweight preview while organizing membership.
typealias CatProfilePhotoDestination = (String, String) -> AnyView
typealias CatProfileAlbumsDestination = (String, @escaping () -> Void) -> AnyView

private struct CatProfileAlbumsDestinationKey: EnvironmentKey {
    static var defaultValue: CatProfileAlbumsDestination? { nil }
}

private struct CatProfilePhotoDestinationKey: EnvironmentKey {
    static var defaultValue: CatProfilePhotoDestination? { nil }
}

extension EnvironmentValues {
    var catProfileAlbumsDestination: CatProfileAlbumsDestination? {
        get { self[CatProfileAlbumsDestinationKey.self] }
        set { self[CatProfileAlbumsDestinationKey.self] = newValue }
    }

    var catProfilePhotoDestination: CatProfilePhotoDestination? {
        get { self[CatProfilePhotoDestinationKey.self] }
        set { self[CatProfilePhotoDestinationKey.self] = newValue }
    }
}

struct CatProfileDetailView: View {
    let profile: CatProfilePresentation
    let allProfiles: [CatProfilePresentation]
    let manualCandidatePhotos: [CatProfilePhotoPresentation]
    let photoAlbumOptions: [CatProfilePhotoAlbumOptionPresentation]
    let actions: CatProfilesViewActions

    @Environment(\.dismiss) private var dismiss
    @State private var showsKeyPhotoPicker = false
    @State private var showsDeleteConfirmation = false
    @State private var showsNameEditor = false
    @State private var draftName = ""
    @State private var isSavingName = false
    @State private var isDeleting = false
    @State private var nameSaveFailed = false
    @State private var deleteFailed = false
    @State private var page: CatPage = .photos
    @AppStorage(CatFarewell.key) private var farewellJSON = ""
    @State private var showsFarewellEditor = false

    enum CatPage: Hashable { case photos, care }

    /// One page per cat. 写真: what the app found in Photos (name, face, which
    /// photos are this cat). この子のこと: the facts people write (dates,
    /// health, daily life, household), read by the tools and the album.
    var body: some View {
        VStack(spacing: 0) {
            // The same underline tabs as the 写真 tab, full width under the title.
            HStack(spacing: 24) {
                ForEach([CatPage.photos, CatPage.care], id: \.self) { candidate in
                    Button { page = candidate } label: {
                        Text(candidate == .photos ? "写真" : "この子のこと")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(page == candidate ? .primary : .secondary)
                            .frame(minHeight: 44)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(page == candidate ? Color.primary : .clear).frame(height: 2)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == candidate ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .background(Color(.systemGroupedBackground))
            .accessibilityIdentifier("cat-profile-page")
            Divider()
            if page == .care {
                CatCareDetailView(profile: profile, otherProfiles: [], selectedProfileID: .constant(profile.identifier))
            } else {
                profileForm
            }
        }
        .navigationTitle(profile.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // この子のこと brings its own; 写真 shows the same at the same place.
            if page == .photos, Version1.familyNotebook || FamilyNotebookPrototype.shared.hasFamily {
                ToolbarItem(placement: .topBarTrailing) {
                    FamilyNotebookButton(accessibilityIdentifier: "cat-profile-family-notebook")
                }
            }
        }
    }

    private var profileForm: some View {
        Form {
            Section {
                // One heading: the photo, the name with its pencil, the count.
                // No badge on the photo and no second box under it.
                VStack(spacing: 8) {
                    Button {
                        showsKeyPhotoPicker = true
                    } label: {
                        CatProfileThumbnail(photo: profile.coverPhoto)
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(profile.confirmedPhotos.isEmpty)
                    .accessibilityLabel("\(profile.displayName)の代表写真を変更")
                    HStack(spacing: 8) {
                        Text(profile.displayName)
                            .font(.title2.bold())
                        if !showsNameEditor {
                            Button {
                                draftName = profile.name ?? ""
                                nameSaveFailed = false
                                showsNameEditor = true
                            } label: {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("名前を変更")
                            .accessibilityIdentifier("cat-profile-rename")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
                if Version1.isOn,
                   let day = CatFarewell.days(farewellJSON)[profile.identifier] {
                    Text(CatFarewell.text(day) + "に旅立ちました")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("cat-profile-farewell")
                }

                if showsNameEditor {
                    TextField("名前", text: $draftName)
                        .disabled(isSavingName)
                    if nameSaveFailed {
                        Text("名前を保存できませんでした。もう一度お試しください。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Button("キャンセル") { showsNameEditor = false }
                        Spacer()
                        Button(isSavingName ? "保存中…" : "保存") {
                            isSavingName = true
                            nameSaveFailed = false
                            Task {
                                let saved = await actions.updateName(profile.identifier, draftName)
                                isSavingName = false
                                if saved { showsNameEditor = false } else { nameSaveFailed = true }
                            }
                        }
                        .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isSavingName)
                }
            }

            // 迷子のとき is a tool; it lives on the ツール tab, not in the profile.
            Section {
                NavigationLink {
                    UnassignedCatPhotosView(
                        photos: manualCandidatePhotos,
                        profiles: allProfiles,
                        actions: actions,
                        navigationTitle: "猫の写真から追加",
                        preselectedProfileIdentifier: profile.identifier
                    )
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("この子の写真を追加")
                                .foregroundStyle(.primary)
                        }
                    } icon: {
                        Image(systemName: "photo.badge.plus")
                    }
                }
                .disabled(manualCandidatePhotos.isEmpty)

                NavigationLink {
                    CatProfileConfirmedPhotosView(
                        profile: profile,
                        allProfiles: allProfiles,
                        actions: actions
                    )
                } label: {
                    Label {
                        LabeledContent(
                            "この子の写真を見る",
                            value: "\(profile.confirmedPhotoCount.formatted())枚"
                        )
                    } icon: {
                        Image(systemName: "photo.on.rectangle")
                    }
                }
                .disabled(profile.confirmedPhotos.isEmpty)

            } header: {
                Text("写真")
            }

            Section {
                Button("プロフィールを削除", role: .destructive) {
                    deleteFailed = false
                    showsDeleteConfirmation = true
                }
                if deleteFailed {
                    Text("削除できませんでした。もう一度お試しください。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("削除しても、写真とツールの入力は残ります。")
            }
        }
        .disabled(isDeleting || isSavingName)
        .navigationBarBackButtonHidden(isDeleting || isSavingName)
        .navigationTitle(profile.displayName)
        .alert("\(profile.displayName)のプロフィールを削除しますか？", isPresented: $showsDeleteConfirmation) {
            Button("プロフィールを削除", role: .destructive) {
                isDeleting = true
                deleteFailed = false
                Task {
                    let deleted = await actions.deleteProfile(profile.identifier)
                    isDeleting = false
                    if deleted {
                        dismiss()
                    } else { deleteFailed = true }
                }
            }
            // When a cat has died, deleting is usually where people go. Offer
            // to keep the cat instead, in words that suit any reason for deleting.
            if Version1.isOn, CatFarewell.days(farewellJSON)[profile.identifier] == nil {
                Button("思い出として残す") { showsFarewellEditor = true }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("写真やツールの入力は残ります。この子への写真の指定とアルバム連携だけを外します。")
        }
        .sheet(isPresented: $showsFarewellEditor) {
            CatFarewellEditor(name: profile.displayName, recorded: CatFarewell.days(farewellJSON)[profile.identifier]) { day in
                farewellJSON = CatFarewell.setting(day, for: profile.identifier, in: farewellJSON)
            }
        }
        .sheet(isPresented: $showsKeyPhotoPicker) {
            NavigationStack {
                CatProfilePhotoPicker(
                    photos: profile.confirmedPhotos,
                    selectedIdentifier: profile.keyPhotoIdentifier,
                    choose: { await actions.setKeyPhoto(profile.identifier, $0) }
                )
            }
        }
        .appRecordEditing(retainWhileHidden: showsNameEditor || isSavingName || showsKeyPhotoPicker)
    }

    private var preparednessCandidates: [CatProfilePhotoPresentation] {
        var seen = Set<String>()
        return (profile.confirmedPhotos + manualCandidatePhotos
                + allProfiles.flatMap { $0.confirmedPhotos + $0.manualCandidatePhotos })
            .filter { seen.insert($0.localIdentifier).inserted }
    }

}

extension CatProfilePresentation {
    /// 「推定の誕生日 2020/5/1」「両方設定済み」「未設定」: the 誕生日・迎えた日 row.
    var lifeDatesSummary: String {
        if lifeDates.hasBothDates { return "両方設定済み" }
        guard let reference = lifeDates.birthday ?? lifeDates.adoptionDay ?? lifeReference else { return "未設定" }
        let prefix = reference.isApproximate ? "推定の" : ""
        return "\(prefix)\(reference.kind.title) \(reference.date.formatted(date: .numeric, time: .omitted))"
    }

    /// What the dates do: the album groups this cat's photos by them.
    var lifeDatesExplanation: String {
        guard let reference = lifeReference else {
            return "誕生日を入れると、アルバムにこの子だけの「子猫のころ」「1歳のころ」ができます。分からなければ迎えた日でも。"
        }
        switch reference.kind {
        case .birthday:
            return "アルバムで「子猫のころ」「1歳のころ」のようにまとめます。"
        case .adoptionDay:
            return "迎えた日を基準に「お迎えしたころ」「いっしょに暮らして1年」のようにまとめます。"
        }
    }
}

private struct CatProfilePhotoAlbumSelectionView: View {
    let profile: CatProfilePresentation
    let albums: [CatProfilePhotoAlbumOptionPresentation]
    let actions: CatProfilesViewActions

    @Environment(\.dismiss) private var dismiss
    @State private var savingIdentifier: String?
    @State private var saveFailed = false

    var body: some View {
        List {
            if let link = profile.photoAlbumLink, !link.isAvailable {
                Section {
                    Label(
                        "現在つないでいるアルバムを利用できません。写真へのアクセス範囲を確認するか、別のアルバムを選んでください。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }

            Section {
                albumButton(
                    identifier: nil,
                    title: "連携しない",
                    subtitle: "手動で追加した写真だけを使う",
                    isSelected: profile.photoAlbumLink == nil
                )

                ForEach(albums) { album in
                    albumButton(
                        identifier: album.identifier,
                        title: album.title,
                        subtitle: "アクセス可能な写真 \(album.accessiblePhotoCount.formatted())枚",
                        isSelected: profile.photoAlbumLink?.identifier
                            == album.identifier
                    )
                }

                if albums.isEmpty {
                    Text("選べる通常アルバムがありません。写真アプリでアルバムを作るか、写真へのアクセス範囲を確認してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("\(profile.displayName)の写真")
            } footer: {
                Text("写真アプリで自分が作った通常アルバムを、\(profile.displayName)の明示的な所属として読み取ります。アルバムの写真は変更しません。連携を外しても、アプリで手動追加した写真は残ります。")
            }
            if saveFailed {
                Section {
                    Text("アルバムの連携を保存できませんでした。もう一度お試しください。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("アルバムをつなぐ")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(savingIdentifier != nil)
        .task { await actions.refreshPhotoAlbums() }
        .accessibilityIdentifier("profile-photo-album-selection")
    }

    private func albumButton(
        identifier: String?,
        title: String,
        subtitle: String,
        isSelected: Bool
    ) -> some View {
        Button {
            savingIdentifier = identifier ?? "__none__"
            saveFailed = false
            Task {
                let saved = await actions.setProfilePhotoAlbum(
                    profile.identifier,
                    identifier
                )
                savingIdentifier = nil
                if saved { dismiss() } else { saveFailed = true }
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if savingIdentifier == (identifier ?? "__none__") {
                    ProgressView()
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.headline)
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(savingIdentifier != nil || isSelected)
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
                        Picker("成長の基準", selection: primaryKind) {
                            ForEach(CatProfileLifeReferenceKindPresentation.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                    } footer: {
                        Text("この子の成長アルバムをまとめる基準です。")
                    }
                }
                if saveFailed {
                    Section {
                        Text("日付を保存できませんでした。入力を確認して、もう一度お試しください。")
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
                Toggle("推定の日付", isOn: approximateDate(kind))
            }
        } header: {
            Text(kind.title)
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
    @Environment(\.catProfileAlbumsDestination) private var albumsDestination

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
    @State private var showsAlbums = false
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
        .safeAreaInset(edge: .top) {
            if albumsDestination != nil && !isSelecting {
                Button {
                    showsAlbums = true
                } label: {
                    Label("この子のアルバム", systemImage: "rectangle.stack")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .accessibilityLabel("\(profile.displayName)のアルバム")
                .accessibilityIdentifier("cat-profile-open-albums")
                .background(.background)
                .disabled(isRemoving)
            }
        }
        .sheet(isPresented: $showsAlbums) {
            NavigationStack {
                if let albumsDestination {
                    albumsDestination(profile.identifier, { showsAlbums = false })
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("閉じる") { showsAlbums = false }
                                    .accessibilityIdentifier("cat-profile-albums-close")
                            }
                        }
                }
            }
        }
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
                            Button("プロフィールを編集", systemImage: "cat") {
                                showsProfileSettings = true
                            }
                            .accessibilityLabel("\(profile.displayName)のプロフィール設定")
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
            Text("\(profile.displayName)への所属だけを外します。他の子や「すべての猫」には残ります。")
        }
        .confirmationDialog(
            "候補から外しますか？",
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
            Text("すべてのプロフィール、アルバム、ウィジェットから除外します。写真ライブラリからは削除しません。")
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
    var navigationTitle = "どの猫か決めていない写真"
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
            "候補から外しますか？",
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
            Text("すべてから除外します。写真ライブラリからは削除しません。")
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
                Text("追加できませんでした。選択は残っています。もう一度お試しください。")
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
                                        .accessibilityLabel("一部の写真に設定済み")
                                case .none:
                                    Image(systemName: "circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("写っている猫・複数選べます")
                } footer: {
                    Text("一緒に写っている猫を複数選べます。−は一部の写真だけに設定済みです。変更しなければ、そのまま残ります。")
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

struct LegacyCatExclusionReviewView: View {
    let photos: [LegacyExcludedCatPhotoPresentation]
    let restore: ([String]) async -> Void

    @State private var selection = Set<String>()
    @State private var isRestoring = false

    var body: some View {
        VStack(spacing: 0) {
            Text("以前の「この子じゃない」は単頭向けでした。戻すと手動の所属は未判定になります。つないだ写真アルバムに含まれる場合は、そのプロフィールに再び表示されます。写真ライブラリからは削除されません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.orange.opacity(0.10))

            LegacySelectablePhotoGrid(photos: photos, selection: $selection)
        }
        .navigationTitle("以前除外した写真")
        .safeAreaInset(edge: .bottom) {
            Button {
                Task {
                    isRestoring = true
                    await restore(Array(selection))
                    selection.removeAll()
                    isRestoring = false
                }
            } label: {
                Label(
                    isRestoring ? "戻しています…" : "猫の写真に戻す（\(selection.count.formatted())枚）",
                    systemImage: "arrow.uturn.backward.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty || isRestoring)
            .padding(12)
            .background(.regularMaterial)
        }
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

private struct LegacySelectablePhotoGrid: View {
    let photos: [LegacyExcludedCatPhotoPresentation]
    @Binding var selection: Set<String>

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(photos) { photo in
                    Button {
                        if selection.contains(photo.localIdentifier) {
                            selection.remove(photo.localIdentifier)
                        } else {
                            selection.insert(photo.localIdentifier)
                        }
                    } label: {
                        PhotoAssetImageView(
                            localIdentifier: photo.localIdentifier,
                            targetPixelSize: CGSize(width: 360, height: 360),
                            targetAspectRatio: 1
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: selection.contains(photo.localIdentifier)
                                ? "checkmark.circle.fill"
                                : "circle")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.title3)
                                .shadow(radius: 2)
                                .padding(6)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        photo.creationDate?.formatted(date: .abbreviated, time: .omitted)
                            ?? "撮影日不明"
                    )
                    .accessibilityAddTraits(
                        selection.contains(photo.localIdentifier) ? .isSelected : []
                    )
                }
            }
            .padding(3)
        }
        .background(Color(.systemGroupedBackground))
    }
}
