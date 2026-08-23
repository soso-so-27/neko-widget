import SwiftUI

struct CatProfileDetailView: View {
    let profile: CatProfilePresentation
    let allProfiles: [CatProfilePresentation]
    let manualCandidatePhotos: [CatProfilePhotoPresentation]
    let photoAlbumOptions: [CatProfilePhotoAlbumOptionPresentation]
    let actions: CatProfilesViewActions

    @State private var showsLifeReferenceEditor = false
    @State private var showsDeleteConfirmation = false
    @State private var showsNameEditor = false
    @State private var draftName = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    CatProfileThumbnail(photo: profile.coverPhoto)
                        .frame(width: 82, height: 82)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.displayName)
                            .font(.title2.bold())
                        Text("この子の写真 \(profile.confirmedPhotoCount.formatted())枚")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            Section {
                Button {
                    draftName = profile.name ?? ""
                    showsNameEditor = true
                } label: {
                    LabeledContent("名前", value: profile.displayName)
                }

                Button {
                    showsLifeReferenceEditor = true
                } label: {
                    LabeledContent("日付の基準", value: lifeReferenceSummary)
                }
            } header: {
                Text("この子の時間")
            } footer: {
                Text(timeGroupingExplanation)
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
                        LabeledContent(
                            "アプリで写真を選ぶ",
                            value: manualCandidatePhotos.isEmpty
                                ? "追加できる写真なし"
                                : "候補 \(manualCandidatePhotos.count.formatted())枚"
                        )
                    } icon: {
                        Image(systemName: "photo.badge.plus")
                    }
                }
                .disabled(manualCandidatePhotos.isEmpty)

                NavigationLink {
                    CatProfilePhotoAlbumSelectionView(
                        profile: profile,
                        albums: photoAlbumOptions,
                        actions: actions
                    )
                } label: {
                    Label {
                        LabeledContent(
                            "写真アプリのアルバムをつなぐ",
                            value: profile.photoAlbumLink?.displayTitle ?? "未連携"
                        )
                    } icon: {
                        Image(systemName: "rectangle.stack.badge.plus")
                    }
                }

                if let link = profile.photoAlbumLink {
                    if link.isAvailable {
                        Label(
                            "「\(link.displayTitle)」から \(link.profilePhotoCount.formatted())枚を表示中",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else {
                        Label(
                            "つないだアルバムを利用できません。以前確認できた写真は保持しています。",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }

                NavigationLink {
                    CatProfileConfirmedPhotosView(
                        profile: profile,
                        allProfiles: allProfiles,
                        actions: actions
                    )
                } label: {
                    Label {
                        LabeledContent(
                            "この子の写真",
                            value: "\(profile.confirmedPhotoCount.formatted())枚"
                        )
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                }
                .disabled(profile.confirmedPhotos.isEmpty)
            } footer: {
                Text("自動で個体を決めません。アプリで指定した写真と、明示的につないだ通常アルバムだけを使います。写真アプリの写真を削除・移動しません。2匹が一緒なら両方へ追加できます。")
            }

            Section {
                Button("プロフィールを削除", role: .destructive) {
                    showsDeleteConfirmation = true
                }
            } footer: {
                Text("プロフィールを削除しても写真は削除されません。この子への手動所属とアルバム連携だけを外し、他の子の所属は保ちます。")
            }
        }
        .navigationTitle(profile.displayName)
        .sheet(isPresented: $showsLifeReferenceEditor) {
            CatProfileLifeReferenceEditor(
                profile: profile,
                save: actions.updateLifeReference
            )
        }
        .alert("名前を変更", isPresented: $showsNameEditor) {
            TextField("名前", text: $draftName)
            Button("保存") {
                Task {
                    await actions.updateName(profile.identifier, draftName)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("名前はあとから何度でも変更できます。")
        }
        .confirmationDialog(
            "\(profile.displayName)のプロフィールを削除しますか？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("プロフィールを削除", role: .destructive) {
                Task { await actions.deleteProfile(profile.identifier) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("写真ライブラリの写真や「みんな」の写真は削除されません。")
        }
    }

    private var lifeReferenceSummary: String {
        guard let reference = profile.lifeReference else { return "未設定" }
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
        }
        .navigationTitle("アルバムをつなぐ")
        .navigationBarTitleDisplayMode(.inline)
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
            Task {
                let token = identifier ?? "__none__"
                savingIdentifier = token
                let saved = await actions.setProfilePhotoAlbum(
                    profile.identifier,
                    identifier
                )
                savingIdentifier = nil
                if saved { dismiss() }
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
    let save: (String, CatProfileLifeReferencePresentation?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reference: CatProfileLifeReferencePresentation?
    @State private var isSaving = false
    @State private var saveTask: Task<Void, Never>?

    init(
        profile: CatProfilePresentation,
        save: @escaping (String, CatProfileLifeReferencePresentation?) async -> Void
    ) {
        self.profile = profile
        self.save = save
        _reference = State(initialValue: profile.lifeReference)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("日付の基準", selection: referenceKind) {
                        Text("設定しない").tag(nil as CatProfileLifeReferenceKindPresentation?)
                        ForEach(CatProfileLifeReferenceKindPresentation.allCases) { kind in
                            Text(kind.title).tag(Optional(kind))
                        }
                    }
                    if reference != nil {
                        DatePicker(
                            reference?.kind.title ?? "日付",
                            selection: referenceDate,
                            in: ...Date.now,
                            displayedComponents: .date
                        )
                        Toggle("推定の日付", isOn: approximateDate)
                    }
                } footer: {
                    Text(isSaving
                        ? "変更を保存しています…"
                        : "変更は自動保存されます。年齢アルバムは誕生日（推定を含む）だけを基準にします。")
                }
            }
            .navigationTitle("\(profile.displayName)の日付")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .onChange(of: reference) { _, newReference in
                scheduleAutoSave(newReference)
            }
        }
    }

    private var referenceKind: Binding<CatProfileLifeReferenceKindPresentation?> {
        Binding(
            get: { reference?.kind },
            set: { kind in
                guard let kind else {
                    reference = nil
                    return
                }
                reference = CatProfileLifeReferencePresentation(
                    kind: kind,
                    date: reference?.date ?? .now,
                    isApproximate: reference?.isApproximate ?? false
                )
            }
        )
    }

    private var referenceDate: Binding<Date> {
        Binding(
            get: { reference?.date ?? .now },
            set: { date in
                guard var value = reference else { return }
                value.date = date
                reference = value
            }
        )
    }

    private var approximateDate: Binding<Bool> {
        Binding(
            get: { reference?.isApproximate ?? false },
            set: { isApproximate in
                guard var value = reference else { return }
                value.isApproximate = isApproximate
                reference = value
            }
        )
    }

    private func scheduleAutoSave(
        _ newReference: CatProfileLifeReferencePresentation?
    ) {
        saveTask?.cancel()
        saveTask = Task {
            isSaving = true
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            await save(profile.identifier, newReference)
            guard !Task.isCancelled else { return }
            isSaving = false
        }
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

    var body: some View {
        CatSelectablePhotoGrid(
            photos: profile.confirmedPhotos,
            selection: $selection
        )
        .navigationTitle("\(profile.displayName)の写真")
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty { actionBar }
        }
        .sheet(isPresented: $showsAssignmentSheet) {
            CatPhotoAssignmentSheet(
                photoIdentifiers: Array(selection),
                profiles: allProfiles,
                initialAssignmentsByPhotoIdentifier: selectedAssignmentsByPhotoIdentifier,
                save: actions.replacePhotoAssignments,
                excludeFromHousehold: actions.excludeFromHousehold
            )
        }
        .confirmationDialog(
            "\(profile.displayName)の写真ではありませんか？",
            isPresented: $showsRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("\(profile.displayName)ではない") {
                let identifiers = Array(selection)
                selection.removeAll()
                Task {
                    await actions.removeProfileMembership(profile.identifier, identifiers)
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
            Text("すべてのプロフィール、思い出、ウィジェットから除外します。写真ライブラリからは削除しません。")
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
            Text("\(selection.count.formatted())枚を選択中")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("写っている子を修正", systemImage: "person.2") {
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
        .padding(12)
        .background(.regularMaterial)
    }
}

struct UnassignedCatPhotosView: View {
    let photos: [CatProfilePhotoPresentation]
    let profiles: [CatProfilePresentation]
    let actions: CatProfilesViewActions
    var navigationTitle = "どの子かまだわからない"
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
                    "未判定の写真はありません",
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
                save: actions.replacePhotoAssignments,
                excludeFromHousehold: actions.excludeFromHousehold
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
            Button("写っている子を設定", systemImage: "person.crop.circle.badge.checkmark") {
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
    let save: ([String: Set<String>]) async -> Void
    let excludeFromHousehold: ([String]) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var assignmentBatch: CatPhotoAssignmentBatchPresentation
    @State private var isSaving = false
    @State private var showsGlobalExclusionConfirmation = false

    init(
        photoIdentifiers: [String],
        profiles: [CatProfilePresentation],
        initialAssignmentsByPhotoIdentifier: [String: Set<String>],
        save: @escaping ([String: Set<String>]) async -> Void,
        excludeFromHousehold: @escaping ([String]) async -> Void
    ) {
        self.photoIdentifiers = photoIdentifiers
        self.profiles = profiles
        self.save = save
        self.excludeFromHousehold = excludeFromHousehold
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
                    Text("写っている子・複数選べます")
                } footer: {
                    Text("2匹が同じ写真に写っている場合は両方を選べます。−は一部の写真だけに設定済みです。触らなければ、その所属を保ちます。")
                }

                Section {
                    Button(role: .destructive) {
                        showsGlobalExclusionConfirmation = true
                    } label: {
                        Label("表示候補から外す", systemImage: "eye.slash")
                    }
                } header: {
                    Text("全体から外す")
                } footer: {
                    Text("プロフィールの所属訂正とは別の操作です。すべての思い出とウィジェットから除外しますが、写真ライブラリからは削除しません。")
                }
            }
            .navigationTitle("写っている子")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "保存") {
                        Task {
                            isSaving = true
                            await save(assignmentBatch.assignmentsByPhotoIdentifier)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .confirmationDialog(
            "表示候補から外しますか？",
            isPresented: $showsGlobalExclusionConfirmation,
            titleVisibility: .visible
        ) {
            Button("表示候補から外す", role: .destructive) {
                Task {
                    await excludeFromHousehold(photoIdentifiers)
                    dismiss()
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("すべてから除外します。写真ライブラリからは削除しません。")
        }
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

private struct CatSelectablePhotoGrid: View {
    let photos: [CatProfilePhotoPresentation]
    @Binding var selection: Set<String>

    private let columns = [
        GridItem(.adaptive(minimum: 104), spacing: 3)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(photos) { photo in
                    Button {
                        toggle(photo.localIdentifier)
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
