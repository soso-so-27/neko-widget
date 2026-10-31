import SwiftUI

struct ExcludedCatPhotoPresentation: Identifiable, Equatable {
    var localIdentifier: String
    var creationDate: Date?
    var excludedAt: Date

    var id: String { localIdentifier }
}

struct CatCandidateCurationView: View {
    let excludedPhotos: [ExcludedCatPhotoPresentation]
    let sourceAlbums: [PhotoSourceAlbumOption]
    let sourceStatus: PhotoSourceAlbumStatus
    let isLimitedAccess: Bool
    let isScanning: Bool
    let chooseMorePhotos: () -> Void
    let restoreCatCandidates: ([String]) async -> Void
    let selectSourceAlbum: (String?) async -> Void
    let refreshSourceAlbums: () async -> Void
    var showsSourceSettings = true

    @State private var isRestoringAll = false
    @State private var showsRestoreAllConfirmation = false

    var body: some View {
        Form {
            if showsSourceSettings {
                sourceSettingsSection
            }

            Section {
                if excludedPhotos.isEmpty {
                    ContentUnavailableView(
                        "外した写真はありません",
                        systemImage: "cat",
                        description: Text("写真の「…」から「猫の写真から外す」を選ぶと外せます。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 230)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(excludedPhotos) { photo in
                        ExcludedCatPhotoRow(photo: photo) {
                            Task {
                                await restoreCatCandidates([photo.localIdentifier])
                            }
                        }
                    }

                    Button {
                        showsRestoreAllConfirmation = true
                    } label: {
                        Label(
                            isRestoringAll ? "戻しています…" : "すべて猫の写真に戻す",
                            systemImage: "arrow.uturn.backward.circle"
                        )
                    }
                    .disabled(isRestoringAll)
                }
            } header: {
                Text("猫の写真から外した写真")
            }
        }
        .navigationTitle(showsSourceSettings ? "写真の整理" : "外した写真")
        .task { await refreshSourceAlbums() }
        .confirmationDialog(
            "外した写真をすべて猫の写真に戻しますか？",
            isPresented: $showsRestoreAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("すべて猫の写真に戻す") {
                Task {
                    isRestoringAll = true
                    await restoreCatCandidates(excludedPhotos.map(\.localIdentifier))
                    isRestoringAll = false
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private var sourceSettingsSection: some View {
        Section {
            NavigationLink {
                PhotoSourceAlbumSelectionView(
                    albums: sourceAlbums,
                    status: sourceStatus,
                    isScanning: isScanning,
                    selectSourceAlbum: selectSourceAlbum
                )
            } label: {
                LabeledContent("写真の対象", value: sourceTitle)
            }

            if sourceStatus == .unavailable {
                Label(
                    "選んだアルバムが見つかりません。選び直してください。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            if isLimitedAccess {
                Button("写真を追加で選ぶ", action: chooseMorePhotos)
            }
        } header: {
            Text("どの写真から探すか")
        }
    }

    private var sourceTitle: String {
        switch sourceStatus {
        case .allLibrary:
            "すべての写真"
        case let .selected(album):
            album.title
        case .unavailable:
            "見つかりません"
        }
    }
}

private struct ExcludedCatPhotoRow: View {
    let photo: ExcludedCatPhotoPresentation
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PhotoAssetImageView(
                localIdentifier: photo.localIdentifier,
                targetPixelSize: CGSize(width: 240, height: 240),
                targetAspectRatio: 1
            )
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(photo.creationDate?.formatted(.dateTime.year().month().day()) ?? "撮影日不明")
                    .font(.subheadline.weight(.semibold))
                Text("外した日：\(photo.excludedAt.formatted(.dateTime.year().month().day()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("戻す", action: restore)
                .buttonStyle(.bordered)
                .accessibilityLabel("この写真を猫の写真に戻す")
        }
        .accessibilityElement(children: .contain)
    }
}

struct PhotoSourceAlbumSelectionView: View {
    let albums: [PhotoSourceAlbumOption]
    let status: PhotoSourceAlbumStatus
    let isScanning: Bool
    let selectSourceAlbum: (String?) async -> Void
    var isLimitedAccess = false
    var chooseMorePhotos: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var savingIdentifier: String?

    var body: some View {
        List {
            if status == .unavailable || isLimitedAccess {
                Section {
                    if status == .unavailable {
                        Label(
                            "選んだアルバムが見つかりません。選び直してください。",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                    if isLimitedAccess {
                        Button("写真を追加で選ぶ", action: chooseMorePhotos)
                    }
                }
            }
            Section {
                sourceButton(
                    identifier: nil,
                    title: "すべての写真",
                    subtitle: "アルバムを選ばずに、全体から探します",
                    isSelected: status == .allLibrary
                )

                ForEach(albums) { album in
                    sourceButton(
                        identifier: album.localIdentifier,
                        title: album.title,
                        subtitle: "写真 \(album.accessibleAssetCount.formatted())枚",
                        isSelected: selectedIdentifier == album.localIdentifier
                    )
                }

                if albums.isEmpty {
                    Text("選べるアルバムがありません。写真アプリでアルバムを作るか、写真へのアクセスを見直してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("写真の対象")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var selectedIdentifier: String? {
        guard case let .selected(album) = status else { return nil }
        return album.localIdentifier
    }

    private func sourceButton(
        identifier: String?,
        title: String,
        subtitle: String,
        isSelected: Bool
    ) -> some View {
        Button {
            Task {
                savingIdentifier = identifier ?? "__all__"
                await selectSourceAlbum(identifier)
                savingIdentifier = nil
                dismiss()
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
                if savingIdentifier == (identifier ?? "__all__") {
                    ProgressView()
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.headline)
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(isScanning || savingIdentifier != nil)
    }
}
