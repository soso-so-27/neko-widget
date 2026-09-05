import SwiftUI

struct CatProfileDetailView: View {
    let profile: CatProfilePresentation
    let allProfiles: [CatProfilePresentation]
    let manualCandidatePhotos: [CatProfilePhotoPresentation]
    let photoAlbumOptions: [CatProfilePhotoAlbumOptionPresentation]
    let actions: CatProfilesViewActions

    @Environment(\.dismiss) private var dismiss
    @State private var showsLifeReferenceEditor = false
    @State private var showsKeyPhotoPicker = false
    @State private var showsDeleteConfirmation = false
    @State private var showsNameEditor = false
    @State private var draftName = ""
    @State private var isSavingName = false
    @State private var isDeleting = false
    @State private var nameSaveFailed = false
    @State private var deleteFailed = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Button {
                        showsKeyPhotoPicker = true
                    } label: {
                        CatProfileThumbnail(photo: profile.coverPhoto)
                            .frame(width: 82, height: 82)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "photo.badge.checkmark")
                                    .padding(5)
                                    .background(.regularMaterial, in: Circle())
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(profile.confirmedPhotos.isEmpty)
                    .accessibilityLabel("\(profile.displayName)の代表写真を変更")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.displayName)
                            .font(.title2.bold())
                        Text("この子の写真 \(profile.confirmedPhotoCount.formatted())枚")
                            .foregroundStyle(.secondary)
                    }
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
                } else {
                    Button("名前を変更", systemImage: "pencil") {
                        draftName = profile.name ?? ""
                        nameSaveFailed = false
                        showsNameEditor = true
                    }
                }
            }

            Section {
                NavigationLink {
                    UnassignedCatPhotosView(
                        photos: manualCandidatePhotos,
                        profiles: allProfiles,
                        actions: actions,
                        navigationTitle: "\(profile.displayName)の写真を選ぶ",
                        preselectedProfileIdentifier: profile.identifier
                    )
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("写真を選ぶ")
                                .foregroundStyle(.primary)
                            Text("候補 \(manualCandidatePhotos.count.formatted())枚")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                NavigationLink {
                    CatProfilePhotoAlbumSelectionView(
                        profile: profile,
                        albums: photoAlbumOptions,
                        actions: actions
                    )
                } label: {
                    LabeledContent(
                        "写真アプリのアルバムをつなぐ",
                        value: profile.photoAlbumLink?.displayTitle ?? "未連携"
                    )
                }
            } header: {
                Text("写真")
            } footer: {
                Text("2匹が一緒なら両方のプロフィールへ追加できます。写真は移動・削除されません。")
            }

            Section {
                Button {
                    showsLifeReferenceEditor = true
                } label: {
                    LabeledContent("誕生日・迎えた日", value: lifeReferenceSummary)
                }
                .foregroundStyle(.primary)
            } header: {
                Text("この子の時間")
            } footer: {
                Text(timeGroupingExplanation)
            }

            Section {
                if showsDeleteConfirmation {
                    Text("\(profile.displayName)のプロフィールを削除しますか？")
                    if deleteFailed {
                        Text("削除できませんでした。もう一度お試しください。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Button(isDeleting ? "削除中…" : "プロフィールを削除", role: .destructive) {
                        isDeleting = true
                        deleteFailed = false
                        Task {
                            let deleted = await actions.deleteProfile(profile.identifier)
                            isDeleting = false
                            if deleted { dismiss() } else { deleteFailed = true }
                        }
                    }
                    Button("キャンセル") { showsDeleteConfirmation = false }
                } else {
                    Button("プロフィールを削除", role: .destructive) {
                        deleteFailed = false
                        showsDeleteConfirmation = true
                    }
                }
            } header: {
                Text("その他")
            } footer: {
                Text("プロフィールを削除しても写真は削除されません。この子への手動所属とアルバム連携だけを外し、他の子の所属は保ちます。")
            }
        }
        .disabled(isDeleting || isSavingName)
        .navigationBarBackButtonHidden(isDeleting || isSavingName)
        .navigationTitle(profile.displayName)
        .sheet(isPresented: $showsLifeReferenceEditor) {
            CatProfileLifeReferenceEditor(
                profile: profile,
                save: actions.updateLifeDates
            )
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
    }

    private var lifeReferenceSummary: String {
        if profile.lifeDates.hasBothDates { return "両方設定済み" }
        guard let reference = profile.lifeDates.birthday ?? profile.lifeDates.adoptionDay
            ?? profile.lifeReference else { return "未設定" }
        let prefix = reference.isApproximate ? "推定の" : ""
        return "\(prefix)\(reference.kind.title) \(reference.date.formatted(date: .numeric, time: .omitted))"
    }

    private var timeGroupingExplanation: String {
        guard let reference = profile.lifeReference else {
            return "誕生日を設定すると、この子だけの「子猫のころ」「1歳のころ」を作ります。"
        }
        switch reference.kind {
        case .birthday:
            return "このプロフィール内だけで「子猫のころ」「1歳のころ」のようにまとめます。"
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

private struct CatProfileLifeReferenceEditor: View {
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
    let profile: CatProfilePresentation
    let allProfiles: [CatProfilePresentation]
    let actions: CatProfilesViewActions

    @State private var selection = Set<String>()
    @State private var showsAssignmentSheet = false
    @State private var showsRemoveConfirmation = false
    @State private var showsGlobalExclusionConfirmation = false
    @State private var isRemoving = false
    @State private var membershipSaveFailed = false

    var body: some View {
        CatSelectablePhotoGrid(
            photos: profile.confirmedPhotos,
            selection: $selection
        )
        .disabled(isRemoving)
        .navigationTitle("\(profile.displayName)の写真")
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty { actionBar }
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
            Text("\(profile.displayName)への所属だけを外します。他の子や「みんな」には残ります。")
        }
        .confirmationDialog(
            "表示候補から外しますか？",
            isPresented: $showsGlobalExclusionConfirmation,
            titleVisibility: .visible
        ) {
            Button("表示候補から外す", role: .destructive) {
                let identifiers = Array(selection)
                selection.removeAll()
                Task { await actions.excludeFromHousehold(identifiers) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("すべてのプロフィール、アルバム、ウィジェットから除外します。写真ライブラリからは削除しません。")
        }
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
                Button("写っている猫を選ぶ", systemImage: "person.2") {
                    showsAssignmentSheet = true
                }
                Spacer()
                Menu {
                    Button("\(profile.displayName)ではない") {
                        showsRemoveConfirmation = true
                    }
                    Button("表示候補から外す", role: .destructive) {
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

struct UnassignedCatPhotosView: View {
    let photos: [CatProfilePhotoPresentation]
    let profiles: [CatProfilePresentation]
    let actions: CatProfilesViewActions
    var navigationTitle = "猫を選んでいない写真"
    /// A picker opened from one cat's page starts with that cat selected while
    /// preserving any other explicit profile assignments on the same photo.
    var preselectedProfileIdentifier: String? = nil

    @State private var selection = Set<String>()
    @State private var showsAssignmentSheet = false
    @State private var showsGlobalExclusionConfirmation = false

    var body: some View {
        Group {
            if photos.isEmpty {
                ContentUnavailableView(
                    "選べる写真はありません",
                    systemImage: "checkmark.circle"
                )
            } else {
                CatSelectablePhotoGrid(photos: photos, selection: $selection)
            }
        }
        .navigationTitle(navigationTitle)
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty { actionBar }
        }
        .sheet(isPresented: $showsAssignmentSheet) {
            CatPhotoAssignmentSheet(
                photoIdentifiers: Array(selection),
                profiles: profiles,
                initialAssignmentsByPhotoIdentifier: selectedAssignmentsByPhotoIdentifier,
                save: { assignments in
                    let saved = await actions.replacePhotoAssignments(assignments)
                    if saved { selection.removeAll() }
                    return saved
                }
            )
        }
        .confirmationDialog(
            "表示候補から外しますか？",
            isPresented: $showsGlobalExclusionConfirmation,
            titleVisibility: .visible
        ) {
            Button("表示候補から外す", role: .destructive) {
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
        HStack {
            Button("写っている猫を選ぶ", systemImage: "person.crop.circle.badge.checkmark") {
                showsAssignmentSheet = true
            }
            .disabled(profiles.isEmpty)
            Spacer()
            Button(role: .destructive) {
                showsGlobalExclusionConfirmation = true
            } label: {
                Label("表示候補から外す", systemImage: "eye.slash")
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }
}

struct CatPhotoAssignmentSheet: View {
    let photoIdentifiers: [String]
    let profiles: [CatProfilePresentation]
    let save: ([String: Set<String>]) async -> Bool

    @Environment(\.dismiss) private var dismiss
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
        _assignmentBatch = State(
            initialValue: CatPhotoAssignmentBatchPresentation(
                photoIdentifiers: photoIdentifiers,
                initialAssignmentsByPhotoIdentifier: initialAssignmentsByPhotoIdentifier
            )
        )
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
                    Text("2匹が同じ写真に写っている場合は両方を選べます。−は一部の写真だけに設定済みです。触らなければ、その所属を保ちます。")
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
                    isRestoring ? "戻しています…" : "候補に戻す（\(selection.count.formatted())枚）",
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
                        ProgressView("保存中…")
                    } else {
                        Text("選択を保存できませんでした。もう一度お試しください。")
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
    var onChoose: ((String) -> Void)? = nil

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
                            selectionMark(for: photo.localIdentifier)
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
                    .accessibilityLabel(accessibilityLabel(for: photo))
                    .accessibilityAddTraits(
                        selection.contains(photo.localIdentifier) ? .isSelected : []
                    )
                }
            }
            .padding(3)
        }
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
