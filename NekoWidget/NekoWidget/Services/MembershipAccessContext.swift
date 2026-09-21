import SwiftUI

extension Notification.Name {
    static let membershipAccessRefreshRequested = Notification.Name("membershipAccessRefreshRequested")
}

/// Rollout is independent of StoreKit availability. Existing beta builds keep
/// all their current features even while purchase previews are being exercised.
struct MembershipAccessContext: Equatable {
    var enforcementEnabled = false
    var personal: MembershipPersonalState = .checking
    var window: MembershipWindowState = .checking

    static let beta = MembershipAccessContext()

    static var enforcementConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MembershipAccessEnforced") as? Bool == true
    }

    init(enforcementEnabled: Bool = false,
         personal: MembershipPersonalState = .checking,
         window: MembershipWindowState = .checking) {
        self.enforcementEnabled = enforcementEnabled
        self.personal = personal
        self.window = window
    }

    init(entitlement: PlusEntitlementState, now: Date = .now) {
        enforcementEnabled = Self.enforcementConfigured
        window = .checking
        switch entitlement {
        case .disabled, .checking: personal = .checking
        case .inactive: personal = .inactive
        case let .serverConfirmed(value):
            if !value.status.grantsAccess || value.accessUntilDate <= now {
                personal = .inactive
            } else if value.authorityStaleAt <= now {
                personal = .indeterminate(lastVerifiedUntil: nil)
            } else {
                personal = .verified(validUntil: value.expirationDate)
            }
        case let .indeterminate(value):
            personal = .indeterminate(lastVerifiedUntil:
                value?.status.grantsAccess == true ? value?.expirationDate : nil)
        }
    }

    func decision(for operation: MembershipOperation, now: Date = .now) -> MembershipAccessDecision {
        MembershipAccessPolicy.decision(for: operation, enforcementEnabled: enforcementEnabled,
            personal: personal, window: window, now: now)
    }

    /// Call only with this window's participant-scoped, validated state.
    /// A personal subscription never authorizes someone else's window.
    func withWindow(_ access: BillingWindowPlusAccessState, now: Date = .now) -> Self {
        var result = self
        switch access {
        case let .active(until, _, _):
            result.window = .verified(validUntil: Date(timeIntervalSince1970: Double(until) / 1_000))
        case let .offlineGrace(until, _, _, _):
            result.window = .verified(validUntil: Date(timeIntervalSince1970: Double(until) / 1_000))
        case .unsponsored, .sponsoredWithoutCurrentAccess, .expired:
            result.window = .inactive
        case let .unknown(reason, previous):
            // Only an actual transport outage can use the existing bounded
            // offline grace. Revocation/rejection must not revive an old grant.
            if reason == .offline, let previous,
               let valid = try? previous.validated(now: now),
               case let .offlineGrace(until, _, _, _) = valid.offlineAccessState(now: now) {
                result.window = .indeterminate(lastVerifiedUntil:
                    Date(timeIntervalSince1970: Double(until) / 1_000))
            } else { result.window = .checking }
        }
        return result
    }
}

private struct MembershipAccessEnvironmentKey: EnvironmentKey {
    static let defaultValue = MembershipAccessContext(enforcementEnabled: MembershipAccessContext.enforcementConfigured)
}

extension EnvironmentValues {
    var membershipAccess: MembershipAccessContext {
        get { self[MembershipAccessEnvironmentKey.self] }
        set { self[MembershipAccessEnvironmentKey.self] = newValue }
    }
}

/// Shows an offer only for a confirmed membership boundary. Unknown state has
/// its own refresh/restore route, without telling an existing member to buy again.
struct MembershipAccessNotice: View {
    let decision: MembershipAccessDecision
    @State private var showsOffer = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: decision == .verificationRequired ? "arrow.clockwise" : "cat")
                .font(.title).foregroundStyle(.tint).accessibilityHidden(true)
            Text(title).font(.headline)
            if decision == .verificationRequired {
                Text("写真やメモはそのままです。接続を確認して、購入を復元できます。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if decision == .windowSupportRequired {
                Text("届いている写真は引き続き見られます。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Button(decision == .verificationRequired ? "購入を確認する" : "会員プランを見る") {
                    showsOffer = true
                }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("membership-access-offer")
            }
        }
        .multilineTextAlignment(.center).padding(24)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("membership-access-notice")
        .sheet(isPresented: $showsOffer, onDismiss: {
            NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
        }) {
            if decision == .verificationRequired {
                MembershipRestoreSheet()
            } else {
                MembershipOfferSheet(model: .live()) { _ in showsOffer = false }
            }
        }
    }

    private var title: String {
        switch decision {
        case .allowed: ""
        case .membershipRequired: "会員プランで、うちの子との時間を楽しむ"
        case .verificationRequired: "会員情報を確認できません"
        case .windowSupportRequired: "このまどへの送信はお休み中です"
        }
    }
}

struct MembershipRestoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = MembershipOfferModel.live()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("購入済みの会員プランを確認します。")
                Button("購入を復元") {
                    Task {
                        if await model.restore() == .completed { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).disabled(!model.canRestore)
                if model.isWorking { ProgressView() }
                if let message = model.message { Text(message).font(.footnote) }
            }.padding().navigationTitle("購入の確認").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }.task { await model.load() }
    }
}

private struct MembershipFeatureGate: ViewModifier {
    @Environment(\.membershipAccess) private var access
    let operation: MembershipOperation
    let hasContent: Bool

    func body(content: Content) -> some View {
        if !hasContent || access.decision(for: operation) == .allowed {
            content
        } else {
            MembershipAccessNotice(decision: access.decision(for: operation))
        }
    }
}

extension View {
    func membershipFeature(_ operation: MembershipOperation, hasContent: Bool = true) -> some View {
        modifier(MembershipFeatureGate(operation: operation, hasContent: hasContent))
    }
}

#if DEBUG
/// Exercises the real editor against an isolated local store. No purchase,
/// CloudKit enrollment, or photo-library mutation is part of this fixture.
@MainActor
struct MembershipAccessFixture: View {
    private let store = PhotoMemoryNoteStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("membership-access-\(UUID().uuidString).json"))
    @State private var record: PhotoMemoryNoteRecord?
    @State private var editingExisting = false
    @State private var editingNew = false
    @State private var state: MembershipPersonalState = .inactive
    @State private var beta = false
    private var context: MembershipAccessContext {
        .init(enforcementEnabled: !beta, personal: state)
    }

    var body: some View {
        NavigationStack {
            List {
                Button("既存メモを編集") { editingExisting = true }
                    .disabled(record == nil).accessibilityIdentifier("membership-existing")
                Button("新しいメモ") { editingNew = true }
                    .accessibilityIdentifier("membership-new")
                Button("確認不能") { state = .checking }
                    .accessibilityIdentifier("membership-unknown")
                Button("現在のβ") { beta = true }
                    .accessibilityIdentifier("membership-beta")
                Text(record?.note.text ?? "準備中")
                    .accessibilityIdentifier("membership-existing-text")
            }.navigationTitle("会員境界の確認")
                .sheet(isPresented: $editingExisting) {
                    if let record {
                        PhotoMemoryNoteEditor(record: record, photo: nil, store: store) {
                            Task { self.record = try? await store.record(id: record.id) }
                        }
                    }
                }
                .sheet(isPresented: $editingNew) {
                    if let photo = AppStoreScreenshotFixture.photos.first {
                        PhotoMemoryNoteEditor(photo: photo, store: store) {}
                    }
                }
        }
        .environment(\.membershipAccess, context)
        .task {
            guard record == nil else { return }
            if let note = try? await store.save(text: "窓辺で眠った日", for: "membership-existing-photo", expectedRevision: nil) {
                record = try? await store.record(id: note.id)
            }
        }
    }
}
#endif
