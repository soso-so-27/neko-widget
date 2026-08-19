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

    @State private var isRestoringAll = false
    @State private var showsRestoreAllConfirmation = false

    var body: some View {
        Form {
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
                        "選択したアルバムを利用できません。対象を選び直すまで、以前の結果を保持します。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }

                if isLimitedAccess {
                    Button("アクセスできる写真を選び直す", action: chooseMorePhotos)
                }
            } header: {
                Text("写真の対象・上級設定")
            } footer: {
                Text("初期値は写真ライブラリ全体です。アルバムを選ぶと、その中の写真だけを次回スキャンの対象にします。アルバム名を変えても選択は維持されます。写真へのアクセスが制限されている場合は、許可済みの写真だけを確認します。")
            }

            Section {
                if excludedPhotos.isEmpty {
                    ContentUnavailableView(
                        "除外した写真はありません",
                        systemImage: "cat",
                        description: Text("写真の大表示メニューやアルバムの長押しから「うちの子ではない」を選べます。")
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
                            isRestoringAll ? "復元中…" : "すべて候補に戻す",
                            systemImage: "arrow.uturn.backward.circle"
                        )
                    }
                    .disabled(isRestoringAll)
                }
            } header: {
                Text("「うちの子ではない」")
            } footer: {
                Text("ここでの除外や復元は、ホーム、ウィジェット、自動アルバムの候補だけに影響します。写真アプリの写真は削除・変更されません。")
            }
        }
        .navigationTitle("写真の整理")
        .task { await refreshSourceAlbums() }
        .confirmationDialog(
            "除外した写真をすべて候補に戻しますか？",
            isPresented: $showsRestoreAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("すべて候補に戻す") {
                Task {
                    isRestoringAll = true
                    await restoreCatCandidates(excludedPhotos.map(\.localIdentifier))
                    isRestoringAll = false
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("写真アプリの写真自体は変更されません。")
        }
    }

    private var sourceTitle: String {
        switch sourceStatus {
        case .allLibrary:
            "すべての写真"
        case let .selected(album):
            album.title
        case .unavailable:
            "利用できません"
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
                Text("除外：\(photo.excludedAt.formatted(.dateTime.year().month().day()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("戻す", action: restore)
                .buttonStyle(.bordered)
                .accessibilityLabel("この写真を候補に戻す")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct PhotoSourceAlbumSelectionView: View {
    let albums: [PhotoSourceAlbumOption]
    let status: PhotoSourceAlbumStatus
    let isScanning: Bool
    let selectSourceAlbum: (String?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var savingIdentifier: String?

    var body: some View {
        List {
            Section {
                sourceButton(
                    identifier: nil,
                    title: "すべての写真",
                    subtitle: "写真ライブラリ全体",
                    isSelected: status == .allLibrary
                )

                ForEach(albums) { album in
                    sourceButton(
                        identifier: album.localIdentifier,
                        title: album.title,
                        subtitle: "アクセス可能な写真 \(album.accessibleAssetCount.formatted())枚",
                        isSelected: selectedIdentifier == album.localIdentifier
                    )
                }

                if albums.isEmpty {
                    Text("選べるユーザー作成アルバムがありません。写真アプリでアルバムを作るか、写真へのアクセス範囲を確認してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("対象を変えるとスキャンを行います。選択したアルバムが削除された場合は、写真ライブラリ全体へ勝手に戻さず、以前の結果を保持します。")
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
