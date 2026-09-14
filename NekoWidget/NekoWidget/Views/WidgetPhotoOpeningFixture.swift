#if DEBUG
import SwiftUI

/// Exercises the shipping URL receiver and presentation host with isolated
/// sources. Personal pixels use the existing PhotoKit fixture; private pixels
/// use a temporary JPEG; public windows use the production store and detail.
/// The held lookup is deliberate: UI tests can inspect the first destination
/// before allowing any source to resolve. It does not simulate live accounts,
/// private source authorization, or PhotoKit permission/recovery.
@MainActor
struct WidgetPhotoOpeningFixture: View {
    @State private var showsSettings = false
    @State private var showsExistingPhoto = false
    @State private var showsOtherURL = false
    @State private var otherURL = ""
    @StateObject private var official = OfficialWindowFixtureModel(initiallySubscribed: true)
    @StateObject private var channel = OfficialWindowFixtureModel(
        definition: PublicWindowDefinition(
            id: "nap-cats", displayName: "おひるね", subtitle: "確認用の猫の写真",
            endpoint: URL(string: "https://official.invalid/windows/nap-cats/catalog.json")),
        initiallySubscribed: true)

    var body: some View {
        WidgetPhotoPresentationHost(onOtherURL: { url in
            otherURL = url.absoluteString
            showsOtherURL = true
        }) {
            NavigationStack {
                VStack(spacing: 24) {
                    Button("写真ホーム") {}
                        .accessibilityIdentifier("widget-photo-fixture-home")
                    Button("まどの一覧") {}
                        .accessibilityIdentifier("widget-photo-fixture-list")
                    Button("確認用の設定") { showsSettings = true }
                        .accessibilityIdentifier("widget-photo-fixture-settings-open")
                    Button("確認用の写真") { showsExistingPhoto = true }
                        .accessibilityIdentifier("widget-photo-fixture-existing-open")
                }
                .navigationTitle("確認用ホーム")
            }
            .sheet(isPresented: $showsSettings) {
                WidgetPhotoOpeningSettingsFixture(close: { showsSettings = false })
            }
            .fullScreenCover(isPresented: $showsExistingPhoto) {
                WidgetPhotoOpeningExistingPhotoFixture(close: { showsExistingPhoto = false })
            }
            .sheet(isPresented: $showsOtherURL) {
                NavigationStack {
                    Text(otherURL)
                        .accessibilityIdentifier("widget-photo-fixture-other-url")
                        .navigationTitle("まどのリンク")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("戻る") { showsOtherURL = false }
                                    .accessibilityIdentifier("widget-photo-fixture-other-close")
                            }
                        }
                }
            }
        } photo: { opening, close in
            WidgetPhotoOpeningFixtureDetail(opening: opening, official: official,
                                           channel: channel, close: close)
        }
        .preferredColorScheme(.dark)
    }
}

/// The draft belongs to the sheet itself, so restoring a newly created sheet
/// instead of preserving the existing presentation loses this counter.
private struct WidgetPhotoOpeningSettingsFixture: View {
    let close: () -> Void
    @State private var changeCount = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("変更回数：\(changeCount)")
                    .accessibilityIdentifier("widget-photo-fixture-settings-draft")
                Button("設定を編集") { changeCount += 1 }
                    .accessibilityIdentifier("widget-photo-fixture-settings-edit")
            }
            .navigationTitle("確認用の設定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("設定を閉じる", action: close)
                        .accessibilityIdentifier("widget-photo-fixture-settings-close")
                }
            }
        }
    }
}

private struct WidgetPhotoOpeningExistingPhotoFixture: View {
    let close: () -> Void
    @State private var changeCount = 0

    var body: some View {
        NavigationStack {
            MomentPhotoDetailBody(imageURL: MomentExperiencePhotoFixture.url(index: 2), caption: nil) {
                VStack(spacing: 12) {
                    Text("変更回数：\(changeCount)")
                        .accessibilityIdentifier("widget-photo-fixture-existing-draft")
                    Button("写真のメモを編集") { changeCount += 1 }
                        .accessibilityIdentifier("widget-photo-fixture-existing-edit")
                }
                .padding()
            }
            .navigationTitle("開いていた写真")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("写真を閉じる", action: close)
                        .accessibilityIdentifier("widget-photo-fixture-existing-close")
                }
            }
        }
    }
}

@MainActor
private struct WidgetPhotoOpeningFixtureDetail: View {
    let opening: WidgetPhotoOpening
    let official: OfficialWindowFixtureModel
    let channel: OfficialWindowFixtureModel
    let close: () -> Void
    @State private var hasResolved = false

    private var destinationKey: String {
        switch opening.destination {
        case let .personal(identifier, _): return "personal|\(identifier)"
        case let .family(window, digest): return "family|\(window)|\(digest)"
        case let .official(route): return "official|\(route.id)"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if hasResolved {
                    resolvedPhoto
                } else {
                    MomentPhotoDetailBody(imageURL: nil, isLoading: true, caption: nil) {
                        EmptyView()
                    }
                    .navigationTitle("写真")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    WidgetPhotoCloseButton(close: close)
                }
                ToolbarItem(placement: .bottomBar) {
                    VStack(spacing: 4) {
                        Text(destinationKey).font(.caption2).lineLimit(1)
                            .accessibilityIdentifier("widget-photo-fixture-route")
                        if !hasResolved {
                            Button("確認用：写真の読み込みを進める") { hasResolved = true }
                                .accessibilityIdentifier("widget-photo-fixture-resolve")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resolvedPhoto: some View {
        switch opening.destination {
        case let .personal(identifier, shownAt):
            if AppStoreScreenshotFixture.isFixtureIdentifier(identifier) {
                let photo = PhotoPresentation(localIdentifier: identifier,
                    creationDate: Date(timeIntervalSince1970: 1_783_008_000))
                PhotoBrowserView(photos: [photo], libraryPhotos: [photo], initialPhoto: photo,
                    widgetShownAt: shownAt, showsWidgetTiming: true,
                    setMemorySaved: { _, _ in }, excludedCatCandidateIdentifiers: [],
                    excludeFromCatCandidates: { _ in }, restoreCatCandidates: { _ in },
                    profiles: [], assignmentsByPhotoIdentifier: [:],
                    replaceProfileAssignments: { _ in true },
                    deliveryActions: PhotoWindowDeliveryActions(
                        destinations: { [] },
                        prepare: { _ in throw MemoryPhotoJPEGExportError.photoUnavailable },
                        send: { _, _, _ in "確認用のため送信しません" }))
            } else {
                unavailablePhoto
            }
        case let .family(window, digest):
            MomentPhotoDetailBody(
                imageURL: window == "11111111-1111-4111-8111-111111111111"
                    && digest == String(repeating: "a", count: 64)
                    ? MomentExperiencePhotoFixture.url(index: 1) : nil,
                caption: nil) { EmptyView() }
                .navigationTitle("写真")
                .navigationBarTitleDisplayMode(.inline)
        case let .official(route):
            if route.windowID == official.store.windowID || route.windowID == channel.store.windowID {
                let model = route.windowID == official.store.windowID ? official : channel
                OfficialWindowView(initialPhotoID: route.photoID, store: model.store,
                    refreshFeed: { throw URLError(.notConnectedToInternet) },
                    previewFeed: { throw URLError(.notConnectedToInternet) })
            } else {
                unavailablePhoto
            }
        }
    }

    private var unavailablePhoto: some View {
        MomentPhotoDetailBody(imageURL: nil, caption: nil) { EmptyView() }
            .navigationTitle("写真")
            .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
