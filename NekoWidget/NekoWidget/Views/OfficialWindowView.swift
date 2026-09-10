import ImageIO
import CryptoKit
import SwiftUI
import UIKit
import WidgetKit

struct OfficialWindowEntryCard: View {
    var body: some View {
        NavigationLink {
            OfficialWindowView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "pawprint.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 52, height: 60)
                VStack(alignment: .leading, spacing: 5) {
                    Text(OfficialWindowCatalog.displayName).font(.headline)
                    Text("ホーム画面に、どこかで暮らす猫の一枚を。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("公式まど · 写真の投稿や友だちの招待は不要")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("official-window-entry")
    }
}

@MainActor
struct OfficialWindowView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = OfficialWindowState.empty
    @State private var isRefreshing = false
    @State private var refreshAgain = false
    @State private var message: String?
    @State private var selectedPhoto: OfficialCatPhoto?
    @State private var showsWidgetGuide = false
    @State private var hasHandledInitialPhoto = false
    var initialPhotoID: String? = nil
    var store: OfficialWindowStore = .shared
    var refreshFeed: () async throws -> Void = {
        try await OfficialWindowClient.shared.refresh(maximumImages: 6)
    }

    private var photos: [OfficialCatPhoto] { state.photos }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let latest = photos.first {
                    photoButton(latest, latest: true)
                } else {
                    introduction
                }

                if let message {
                    Label(message, systemImage: "wifi.exclamationmark")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("official-window-feedback")
                }

                if state.isSubscribed {
                    Button {
                        showsWidgetGuide = true
                    } label: {
                        Label("ホーム画面に置く", systemImage: "plus.rectangle.on.rectangle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("official-window-widget-guide")

                    if photos.count > 1 {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("最近届いた猫たち").font(.headline)
                            ForEach(photos.dropFirst().prefix(5)) { photo in
                                photoButton(photo, latest: false)
                            }
                        }
                    }
                    Button("受け取りをやめる", role: .destructive) { changeSubscription(false) }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("official-window-stop")
                } else if store.endpoint != nil {
                    Button {
                        changeSubscription(true)
                    } label: {
                        Text("このまどを受け取る").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("official-window-subscribe")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("ねこのまどが選んで届ける、公式まどです。")
                    Text("公開用に提供された写真を紹介します。猫の名前や撮影時期、提供者は写真を開くと確認できます。")
                    if state.isSubscribed {
                        Text("写真が追加されると更新します。ホーム画面への反映には時間がかかることがあります。")
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle(OfficialWindowCatalog.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .refreshable { await refresh() }
        .toolbar {
            if state.isSubscribed {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh() } } label: {
                        if isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("公式まどを更新")
                }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refresh()
        }
        .task(id: state.catalog?.validUntil) {
            // Also retire a photo while its detail is open and the phone stays
            // offline. Expiry is not dependent on another successful request.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                state = store.snapshot()
                dismissUnavailablePhoto()
            }
        }
        .sheet(item: $selectedPhoto) { photo in
            NavigationStack { OfficialPhotoDetailView(photo: photo, store: store, imageRevision: state.imageRevision) }
        }
        .sheet(isPresented: $showsWidgetGuide) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Label("ホーム画面にも、このまどを。", systemImage: "pawprint.fill").font(.title2)
                        Text("1. ホーム画面の何もないところを長押しします。")
                        Text("2. 「編集」または「＋」からウィジェットを追加し、「ねこのまど」を選びます。")
                        Text("3. 置いたウィジェットを長押しして「ウィジェットを編集」を開き、「表示する写真」を「どこかの猫 · 公式まど」にします。")
                        Text("写真ライブラリの許可や、猫の登録は必要ありません。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(24)
                }
                .navigationTitle("ホーム画面に置く")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showsWidgetGuide = false } } }
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "pawprint.fill").font(.system(size: 42)).foregroundStyle(.orange)
            Text(emptyTitle).font(.title2.weight(.semibold))
            Text(emptyDescription).foregroundStyle(.secondary)
            if isRefreshing { ProgressView("写真を確認しています…") }
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
        .padding(24)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .accessibilityIdentifier("official-window-introduction")
    }

    private var emptyTitle: String {
        if store.endpoint == nil { return "公式まどを準備しています" }
        if !state.isSubscribed { return "どこかの猫と、暮らしの中で会える。" }
        if state.catalog?.enabled == false { return "いまは配信をお休みしています" }
        return "いま届いている写真はありません"
    }

    private var emptyDescription: String {
        if store.endpoint == nil { return "公開する写真の準備ができたら、このまどからお届けします。" }
        if !state.isSubscribed { return "ふと見たホーム画面に、猫の一枚。自分の写真や、送る相手がいなくても楽しめます。" }
        return "新しい写真は、このまどで受け取れます。写真の投稿は必要ありません。"
    }

    private func photoButton(_ photo: OfficialCatPhoto, latest: Bool) -> some View {
        Button { selectedPhoto = photo } label: {
            VStack(alignment: .leading, spacing: 10) {
                OfficialPhotoImage(photo: photo, maximumPixelSize: latest ? 1100 : 650, store: store)
                    .id("\(photo.imageFilename)-\(state.imageRevision?.uuidString ?? "")")
                    .aspectRatio(CGFloat(photo.width) / CGFloat(photo.height), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                HStack {
                    Text(photo.catName).font(.headline)
                    Spacer()
                    Text(photo.publishedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                }
                if let caption = photo.caption {
                    Text(caption).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(photo.catName)の写真を開く")
    }

    private func changeSubscription(_ subscribed: Bool) {
        do {
            try store.setSubscribed(subscribed)
            state = store.snapshot()
            message = nil
            selectedPhoto = nil
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
            if subscribed {
                if isRefreshing { refreshAgain = true }
                else { Task { await refresh() } }
            }
        } catch {
            message = "受け取りの設定を保存できませんでした。もう一度お試しください。"
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        state = store.snapshot()
        guard state.isSubscribed else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshAgain {
                refreshAgain = false
                Task { await refresh() }
            }
        }
        let requestedSubscription = state.subscriptionID
        do {
            try await refreshFeed()
            message = nil
        } catch is CancellationError {
            return
        } catch {
            if store.snapshot().subscriptionID == requestedSubscription {
                message = "新しい写真を確認できませんでした。通信が戻ったら、もう一度更新できます。"
            }
        }
        state = store.snapshot()
        dismissUnavailablePhoto()
        WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        if !hasHandledInitialPhoto, let initialPhotoID {
            hasHandledInitialPhoto = true
            selectedPhoto = photos.first { $0.id == initialPhotoID }
            if selectedPhoto == nil { message = "この写真の掲載は終了しました。いま届いている写真をご覧ください。" }
        }
    }

    private func dismissUnavailablePhoto() {
        if let selectedPhoto, !photos.contains(selectedPhoto) {
            self.selectedPhoto = nil
        }
    }
}

private struct OfficialPhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let photo: OfficialCatPhoto
    let store: OfficialWindowStore
    let imageRevision: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OfficialPhotoImage(photo: photo, maximumPixelSize: 2048, store: store)
                    .id(imageRevision)
                    .aspectRatio(CGFloat(photo.width) / CGFloat(photo.height), contentMode: .fit)
                VStack(alignment: .leading, spacing: 10) {
                    if let caption = photo.caption { Text(caption).font(.body) }
                    Text("写真提供：\(photo.credit)")
                    if let date = photo.photographedOn { Text("撮影日：\(date)") }
                    Text("掲載：\(photo.publishedAt.formatted(date: .abbreviated, time: .omitted))")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
            }.padding(.bottom, 24)
        }
        .navigationTitle(photo.catName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
    }
}

private struct OfficialPhotoImage: View {
    let photo: OfficialCatPhoto
    let maximumPixelSize: Int
    let store: OfficialWindowStore
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemGroupedBackground)
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Label("写真を読み込めませんでした", systemImage: "photo")
                    .font(.footnote).foregroundStyle(.secondary).padding()
            }
        }
        .accessibilityLabel("\(photo.catName)の写真")
        .accessibilityIdentifier(image == nil ? "official-window-image-unavailable" : "official-window-image-loaded")
        .task(id: photo.imageFilename) {
            guard let url = store.imageURL(for: photo),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { image = nil; return }
            image = UIImage(cgImage: cgImage)
        }
    }
}

#if DEBUG
/// Offline fixture uses the shipping store and screens, with only the public
/// network boundary replaced. No Photos permission, real account or feed.
@MainActor
final class OfficialWindowFixtureModel: ObservableObject {
    let store: OfficialWindowStore
    private var attempts = 0

    init() {
        let unavailable = CommandLine.arguments.contains("--official-window-unconfigured")
        store = OfficialWindowStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("official-fixture-" + UUID().uuidString),
            endpoint: unavailable ? nil : URL(string: "https://official.invalid/catalog.json")
        )
    }

    func refresh() async throws {
        attempts += 1
        let request = store.snapshot()
        guard request.isSubscribed else { return }
        let image = MomentExperiencePhotoFixture.image(index: 0)
        guard let data = image.jpegData(compressionQuality: 0.88), let cgImage = image.cgImage else { return }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 2)
        let photo = OfficialCatPhoto(
            id: "fixture-photo", catID: "fixture-cat", catName: "確認用の猫", credit: "画面確認用の合成画像",
            caption: "窓辺でひと休み。", photographedOn: "2026-09-01", publishedAt: now,
            expiresAt: now.addingTimeInterval(86400), imageFilename: hash + ".jpg", sha256: hash,
            width: cgImage.width, height: cgImage.height
        )
        let catalog = OfficialWindowCatalog(schemaVersion: 1, channelID: "official-cats", enabled: true,
                                           generatedAt: now, validUntil: now.addingTimeInterval(86400), photos: [photo])
        try store.accept(catalog, for: request)
        if attempts == 1 { throw URLError(.networkConnectionLost) }
        try store.saveImage(data, photo: photo, for: request)
    }
}

struct OfficialWindowUIFixture: View {
    @StateObject private var model = OfficialWindowFixtureModel()
    var body: some View {
        NavigationStack {
            OfficialWindowView(store: model.store, refreshFeed: { try await model.refresh() })
        }
    }
}
#endif
