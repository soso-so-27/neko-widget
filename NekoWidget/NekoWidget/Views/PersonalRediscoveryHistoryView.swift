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
                    Text("今日の一枚を、1回だけ選び直せます。")
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
                } else {
                    ContentUnavailableView(loadFailed ? "履歴を読み込めませんでした" : "選び直した写真はまだありません",
                        systemImage: "photo.on.rectangle",
                        description: Text(loadFailed ? "少し待ってから、もう一度お試しください。" : "選び直すと、前の写真と新しい写真がここに出ます。"))
                        .accessibilityIdentifier("personal-rediscovery-empty")
                }
            }
            .padding(20)
        }
        .navigationTitle("今日の一枚を選び直す")
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
        Label(previous ? "直前の写真は表示できません" : "選び直した一枚は表示できません", systemImage: "photo")
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
            Label("今日はもう選び直しました", systemImage: "checkmark.circle")
                .font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("personal-rediscovery-used")
        } else {
            Text("ほかの写真が見つかったら、ここで選び直せます。")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("personal-rediscovery-not-ready")
        }
    }

    private func photoCard(grant: PersonalRediscoveryGrant, previous: Bool) -> some View {
        let identifier = previous ? grant.previousPhotoID : grant.photoID
        let title = previous ? "直前の写真" : "選び直した一枚"
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
        .accessibilityHint("写真を大きく開きます")
        .accessibilityIdentifier("personal-rediscovery-\(previous ? "previous" : "result")-\(grant.id)")
        #if DEBUG
        .accessibilityValue(identifier)
        #endif
    }

    private func historyHeading(_ grant: PersonalRediscoveryGrant) -> String {
        if Calendar.current.isDate(grant.committedAt, inSameDayAs: displayDate) { return "今日選び直した写真" }
        return grant.committedAt.formatted(.dateTime.month().day()) + "に選び直した写真"
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
            case .committed: message = "別の一枚に選び直しました。"
            case .existing: message = "今日はもう選び直しました。"
            case .refreshRequired: message = "画面を新しくしました。もう一度お試しください。"
            case .unavailable: message = "別の写真を選べませんでした。今日の1回はまだ残っています。"
            }
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        } catch {
            message = "別の写真を選べませんでした。少し待ってから、もう一度お試しください。"
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
