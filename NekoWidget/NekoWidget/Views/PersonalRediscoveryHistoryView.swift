import SwiftUI
import UIKit
import WidgetKit

/// A short-lived way back to a manual Widget selection. Viewing a card uses
/// the existing exact-photo URL and therefore the normal save/send controls.
@MainActor
struct PersonalRediscoveryHistoryView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let store: PersonalRediscoveryStore
    private let now: () -> Date
    @State private var snapshot: PersonalRediscoverySnapshot?
    @State private var currentEntry: PersonalRediscoveryEntry?
    @State private var displayDate = Date()
    @State private var message: String?
    @State private var loadFailed = false
    @State private var thumbnails: [String: URL] = [:]

    init(store: PersonalRediscoveryStore = .shared, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("1日1回、まどの写真をめくれます。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    dailyAction
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("personal-rediscovery-feedback")
                    }
                }

                if let history = snapshot?.history, !history.isEmpty {
                    ForEach(history.sorted { $0.committedAt > $1.committedAt }) { grant in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(historyHeading(grant)).font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            historyLayout {
                                if grant.resultIsAvailable {
                                    photoCard(grant: grant, previous: false)
                                } else {
                                    unavailablePhoto(previous: false)
                                }
                                if grant.previousIsAvailable {
                                    photoCard(grant: grant, previous: true)
                                } else {
                                    unavailablePhoto(previous: true)
                                }
                            }
                        }
                    }
                    Text("48時間で履歴から消えます。残したい一枚は、開いて「思い出に残す」へ。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView(loadFailed ? "履歴を読み込めませんでした" : "めくった写真はまだありません",
                        systemImage: "photo.on.rectangle",
                        description: Text(loadFailed ? "時間をおいてもう一度お試しください。" : "めくった一枚と直前の写真を、48時間ここから開けます。"))
                        .accessibilityIdentifier("personal-rediscovery-empty")
                }
            }
            .padding(20)
        }
        .navigationTitle("まどでめくった写真")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("personal-rediscovery-history")
        .refreshable { reload() }
        .task { reload() }
        .task(id: nextRefreshDate) {
            guard let deadline = nextRefreshDate else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSince(now())))) }
            catch { return }
            reload()
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
    }

    private var historyLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }

    private func unavailablePhoto(previous: Bool) -> some View {
        Label(previous ? "直前の写真は表示できません" : "めくった一枚は表示できません", systemImage: "photo")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 100)
            .accessibilityIdentifier("personal-rediscovery-\(previous ? "previous" : "result")-unavailable")
    }

    @ViewBuilder
    private var dailyAction: some View {
        if let action = currentEntry?.action, case .available = action, snapshot?.canTurn == true {
            Button(action: turnPhoto) {
                Label("もう一枚", systemImage: "arrow.clockwise")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("1日に1回、このiPhoneのまどの写真を切り替えます")
            .accessibilityIdentifier("personal-rediscovery-turn")
        } else if let next = snapshot?.nextAvailableAt, next > displayDate {
            Label("今日はめくりました", systemImage: "checkmark.circle")
                .font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("personal-rediscovery-used")
        } else {
            Text("別の写真を用意できたら、ここでもめくれます。")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("personal-rediscovery-not-ready")
        }
    }

    private func photoCard(grant: PersonalRediscoveryGrant, previous: Bool) -> some View {
        let identifier = previous ? grant.previousPhotoID : grant.photoID
        let title = previous ? "直前の写真" : "めくった一枚"
        return Button { open(grant: grant, previous: previous) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let url = thumbnails[thumbnailKey(grant: grant, previous: previous)] {
                        MomentLocalImageView(url: url, contentMode: .fill,
                                             hidesImageAccessibility: true, maximumPixelSize: 420)
                    } else {
                        ZStack {
                            Color(.secondarySystemBackground)
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    }
                }
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                Text(title).font(.subheadline.weight(.medium))
                if let date = snapshot?.candidates.first(where: { $0.item.localIdentifier == identifier })?.creationDate {
                    Text(date.formatted(.dateTime.year().month())).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("写真を大きく開きます。まどの表示や今日の回数は変わりません")
        .accessibilityIdentifier("personal-rediscovery-\(previous ? "previous" : "result")-\(grant.id)")
        #if DEBUG
        .accessibilityValue(identifier)
        #endif
    }

    private func historyHeading(_ grant: PersonalRediscoveryGrant) -> String {
        if Calendar.current.isDate(grant.committedAt, inSameDayAs: displayDate) { return "今日めくった写真" }
        return grant.committedAt.formatted(.dateTime.month().day()) + "にめくった写真"
    }

    private func thumbnailKey(grant: PersonalRediscoveryGrant, previous: Bool) -> String {
        grant.id + (previous ? "|previous" : "|result")
    }

    private var nextRefreshDate: Date? {
        ((snapshot?.history.map(\.resultExpiresAt) ?? []) + [snapshot?.nextAvailableAt].compactMap { $0 })
            .filter { $0 > displayDate }.min()
    }

    private func reload() {
        let date = now()
        displayDate = date
        do {
            snapshot = try store.snapshot(now: date)
            currentEntry = try store.currentEntry(now: date)
            var resolved: [String: URL] = [:]
            for grant in snapshot?.history ?? [] {
                for previous in [false, true] {
                    if let url = try store.historyImageURL(grantID: grant.id, previous: previous,
                                                          variant: .medium, now: date) {
                        resolved[thumbnailKey(grant: grant, previous: previous)] = url
                    }
                }
            }
            thumbnails = resolved
            loadFailed = false
        } catch {
            snapshot = nil
            currentEntry = nil
            thumbnails = [:]
            loadFailed = true
        }
    }

    private func turnPhoto() {
        let date = now()
        do {
            // Use the token this screen displayed. A screen left open across
            // midnight refreshes first and cannot silently spend the new day.
            guard let entry = currentEntry, case let .available(token) = entry.action else {
                reload()
                return
            }
            let outcome = try store.perform(token: token, operationID: UUID().uuidString,
                                            operationCreatedAt: date, now: date)
            switch outcome {
            case .committed: message = "もう一枚を選びました。"
            case .existing: message = "今日はめくりました。ここから同じ写真を何度でも開けます。"
            case .refreshRequired: message = "操作の状態を更新しました。もう一度お試しください。"
            case .unavailable: message = "別の写真を選べませんでした。今日の回数は使っていません。"
            }
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        } catch {
            message = "別の写真を選べませんでした。時間をおいてお試しください。"
        }
        reload()
    }

    private func open(grant: PersonalRediscoveryGrant, previous: Bool) {
        // Recheck expiry/eligibility at the action boundary; a row left open
        // overnight must not revive a removed or expired history reference.
        guard let latest = try? store.snapshot(now: now()),
              let permitted = latest.history.first(where: { $0.id == grant.id }),
              (previous ? permitted.previousIsAvailable : permitted.resultIsAvailable),
              let url = DeepLink.photo(localIdentifier: previous ? permitted.previousPhotoID : permitted.photoID)
        else { reload(); return }
        openURL(url)
    }
}

#if DEBUG
/// UI-only source fixtures use a temporary production store and the existing
/// illustration loader. No account, PhotoKit write, or real send is involved.
@MainActor
private final class PersonalRediscoveryHistoryFixtureModel: ObservableObject {
    let store: PersonalRediscoveryStore
    @Published var saved: Set<String> = []
    let identifiers: [String]
    var seedError: String?

    init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("personal-rediscovery-fixture-" + UUID().uuidString, isDirectory: true)
        store = PersonalRediscoveryStore(containerURL: root)
        identifiers = (1...(CommandLine.arguments.contains("--personal-rediscovery-one-photo") ? 1 : 3))
            .map { "app-store-screenshot-fixture-\($0)" }
        do {
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            let revision = try store.updateEligibility(photoIDs: Set(identifiers), scopeIdentifier: "fixture",
                                                       isAuthorized: true, now: yesterday)
            let candidates = identifiers.enumerated().map { index, identifier in
                PersonalRediscoveryCandidate(item: WidgetManifestItem(localIdentifier: identifier,
                    cacheFilename: "rediscovery-fixture-\(index)-small.jpg",
                    cacheFilenames: WidgetCacheFilenames(small: "rediscovery-fixture-\(index)-small.jpg",
                        medium: "rediscovery-fixture-\(index)-medium.jpg", large: "rediscovery-fixture-\(index)-large.jpg"),
                    scheduledDate: yesterday.addingTimeInterval(Double(index) * 1200)),
                    creationDate: yesterday.addingTimeInterval(-Double(index + 1) * 86400), preparedAt: yesterday)
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let imageData = Dictionary(uniqueKeysWithValues: identifiers.map { identifier in
                let source = AppStoreScreenshotFixture.image(for: identifier)!
                let data = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format)
                    .image { _ in source.draw(in: CGRect(x: 0, y: 0, width: 96, height: 96)) }
                    .jpegData(compressionQuality: 0.8)!
                return (identifier, data)
            })
            _ = try store.publish(candidates: candidates, expectedRevision: revision, now: yesterday,
                                  interval: 1200, prepareFiles: { _ in
                let cache = root.appendingPathComponent("widget-cache", isDirectory: true)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                for item in candidates.map(\.item) {
                    guard let data = imageData[item.localIdentifier] else { continue }
                    for filename in item.allCacheFilenames {
                        try data.write(to: cache.appendingPathComponent(filename), options: .atomic)
                    }
                }
            })
            if identifiers.count > 1, let entry = try store.currentEntry(now: yesterday),
               case let .available(token) = entry.action {
                _ = try store.perform(token: token, operationID: UUID().uuidString,
                                      operationCreatedAt: yesterday, now: yesterday)
            }
        } catch {
            seedError = String(describing: error)
        }
    }

    func photo(_ identifier: String) -> PhotoPresentation {
        PhotoPresentation(localIdentifier: identifier, creationDate: Date(timeIntervalSince1970: 1_783_008_000),
                          isLiked: saved.contains(identifier))
    }
}

@MainActor
struct PersonalRediscoveryHistoryFixture: View {
    @StateObject private var model = PersonalRediscoveryHistoryFixtureModel()

    var body: some View {
        Group {
            if let error = model.seedError {
                Text("確認用の準備に失敗しました：\(error)")
                    .accessibilityIdentifier("personal-rediscovery-fixture-error")
            } else {
                WidgetPhotoPresentationHost {
                    NavigationStack {
                        PersonalRediscoveryFixturePhoto(model: model, identifier: model.identifiers[0])
                    }
                } photo: { opening, close in
                    NavigationStack {
                        if case let .personal(identifier, _) = opening.destination,
                           model.identifiers.contains(identifier) {
                            PersonalRediscoveryFixturePhoto(model: model, identifier: identifier)
                                .toolbar { ToolbarItem(placement: .cancellationAction) {
                                    WidgetPhotoCloseButton(close: close)
                                } }
                        }
                    }
                }
            }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--personal-rediscovery-large") ? .accessibility3 : .large)
        .preferredColorScheme(.dark)
    }
}

private struct PersonalRediscoveryFixturePhoto: View {
    @ObservedObject var model: PersonalRediscoveryHistoryFixtureModel
    let identifier: String

    var body: some View {
        let photo = model.photo(identifier)
        PhotoBrowserView(photos: [photo], libraryPhotos: [photo], initialPhoto: photo,
            widgetShownAt: Date(), showsWidgetTiming: true,
            setMemorySaved: { identifier, saved in
                if saved { model.saved.insert(identifier) } else { model.saved.remove(identifier) }
            }, excludedCatCandidateIdentifiers: [], excludeFromCatCandidates: { _ in },
            restoreCatCandidates: { _ in }, profiles: [], assignmentsByPhotoIdentifier: [:],
            replaceProfileAssignments: { _ in true },
            deliveryActions: PhotoWindowDeliveryActions(destinations: { [] },
                prepare: { _ in throw MemoryPhotoJPEGExportError.photoUnavailable },
                send: { _, _, _ in "確認用のため送信しません" }),
            rediscoveryStore: model.store)
            .toolbar { ToolbarItem(placement: .bottomBar) {
                Text(identifier).font(.caption2)
                    .accessibilityIdentifier("personal-rediscovery-fixture-photo-id")
            } }
    }
}
#endif
