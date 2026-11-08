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

    /// Info.plist `MembershipAccessEnforced`（xcconfig `MEMBERSHIP_ACCESS_ENFORCED`）。
    /// App と Widget の両 Info.plist が同じ変数を参照する。
    static var enforcementConfigured: Bool {
        MembershipAccessFlag.isOn(Bundle.main.object(forInfoDictionaryKey: "MembershipAccessEnforced"))
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
            if now < value.serverEvaluatedAt {
                personal = .checking
            } else if !value.status.grantsAccess || value.accessUntilDate <= now {
                personal = .inactive
            } else if value.authorityStaleAt <= now {
                personal = .indeterminate(lastVerifiedUntil: nil)
            } else {
                personal = .verified(validUntil: value.expirationDate)
            }
        case let .indeterminate(value):
            personal = .indeterminate(lastVerifiedUntil:
                value?.isUsable(at: now) == true ? value?.expirationDate : nil)
        }
    }

    func decision(for operation: MembershipOperation, now: Date = .now) -> MembershipAccessDecision {
        MembershipAccessPolicy.decision(for: operation, enforcementEnabled: enforcementEnabled,
            personal: personal, window: window, now: now)
    }

    /// This iPhone's own Plus is usable now (verified, or the bounded offline
    /// fallback). Only where Plus is enforced: a beta build is not a member.
    func hasPersonalPlus(now: Date = .now) -> Bool {
        enforcementEnabled && decision(for: .createPersonalMemo, now: now) == .allowed
    }

    /// Call only with this window's participant-scoped, validated state.
    /// A personal subscription never authorizes someone else's window.
    /// ADR-027: まどの支援（sponsorship）はゲートとして停止した。`addSharedContent`
    /// は常に許可で、この状態は判定に使われない。呼出との互換のために残す。
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

private struct MembershipActionsEnvironmentKey: EnvironmentKey {
    static let defaultValue = MembershipActionAccess(enforcementEnabled: MembershipAccessContext.enforcementConfigured)
}

extension EnvironmentValues {
    var membershipActions: MembershipActionAccess {
        get { self[MembershipActionsEnvironmentKey.self] }
        set { self[MembershipActionsEnvironmentKey.self] = newValue }
    }
    var membershipAccess: MembershipAccessContext {
        get { self[MembershipAccessEnvironmentKey.self] }
        set { self[MembershipAccessEnvironmentKey.self] = newValue }
    }
}

/// A status notice, never a purchase route (ADR-027 5章). The one Plus
/// screen opens only from a `PlusOfferContext` entry (`PlusOfferPrompt`,
/// Settings, onboarding); this notice is for "確認できません" and offers only
/// the restore check, so an existing member is never told to buy again.
struct MembershipAccessNotice: View {
    let decision: MembershipAccessDecision
    @Environment(\.membershipAccess) private var access

    var body: some View {
        if decision == .verificationRequired, access.personal == .checking {
            // Just after launch: the answer is on its way. Nothing to do yet.
            HStack(spacing: 10) {
                ProgressView()
                Text("Plusを確認しています…").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("membership-access-checking")
        } else {
            notice
        }
    }

    private var notice: some View {
        VStack(spacing: 14) {
            Image(systemName: decision == .verificationRequired ? "arrow.clockwise" : "cat")
                .font(.title).foregroundStyle(.tint).accessibilityHidden(true)
            Text(title).font(.headline)
            switch decision {
            case .verificationRequired:
                Text("写真やメモはそのままです。インターネットにつながってから、「購入を復元」を押してください。")
                    .font(.subheadline).foregroundStyle(.secondary)
                // Restores right here (11/7), no second screen.
                MembershipRestoreButton(look: .prominent, identifier: "membership-access-restore")
            case .windowSupportRequired:
                Text("まどを作った人のPlusが切れています。届いた写真はこれまでどおり見られます。")
                    .font(.subheadline).foregroundStyle(.secondary)
            case .membershipRequired, .allowed:
                Text("写真やメモはそのままです。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center).padding(24)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("membership-access-notice")
    }

    private var title: String {
        switch decision {
        case .allowed: ""
        case .membershipRequired: "Plusの機能です"
        case .verificationRequired: "Plusを確かめられませんでした"
        case .windowSupportRequired: "いまはこのまどに写真を届けられません"
        }
    }
}

struct MembershipRestoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = MembershipOfferModel.live(presentsOffer: false)

    init() { }

    init(model: MembershipOfferModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("以前に購入したPlusを、このiPhoneで使えるようにします。")
                Button("購入を復元") {
                    Task {
                        if await model.restore() == .completed { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).disabled(!model.canRestore)
                    .accessibilityIdentifier("membership-restore-submit")
                // The one button also re-checks the purchase (11/5): no second button.
                if model.isWorking { ProgressView() }
                if let message = model.message {
                    Text(message).font(.footnote)
                        .accessibilityIdentifier("membership-restore-message")
                }
            }.padding().navigationTitle("購入を復元").navigationBarTitleDisplayMode(.inline)
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

/// 「購入を復元」 that restores where it is tapped (11/7: it opened a screen
/// titled 購入を復元 with one sentence and the same button). The same
/// `restore()` as `MembershipRestoreSheet`: progress on the button, the result
/// under it. Where this iPhone already shows Plus, the title is
/// 「Plusをもう一度確かめる」 (11/7); the re-check runs first either way.
@MainActor
struct MembershipRestoreButton: View {
    enum Look { case settingsRow, footnote, prominent, wide }

    let title: String
    let look: Look
    let identifier: String
    /// After a restore that found Plus. Plus checks are refreshed either way.
    let restored: () -> Void
    @StateObject private var model: MembershipOfferModel
    @State private var running = false
    @State private var found = false

    init(title: String = "購入を復元", look: Look = .prominent,
         identifier: String = "membership-restore-submit", restored: @escaping () -> Void = {}) {
        self.title = title
        self.look = look
        self.identifier = identifier
        self.restored = restored
        _model = StateObject(wrappedValue: MembershipOfferModel.live(presentsOffer: false))
    }

    var body: some View {
        button
            .disabled(running || !model.canRestore)
            .accessibilityIdentifier(identifier)
            .task { await model.load() }
        if found {
            Text("Plusを確認できました。")
                .font(.footnote).foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("membership-restore-found")
        } else if !running, let message = model.message, !message.isEmpty {
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("membership-restore-message")
        }
    }

    private var workingLabel: some View {
        WorkingLabel(title: title, workingTitle: "確認しています…", working: running)
    }

    @ViewBuilder private var button: some View {
        switch look {
        case .settingsRow:
            Button { restore() } label: {
                Label { workingLabel } icon: { Image(systemName: "arrow.clockwise") }
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        case .footnote:
            Button { restore() } label: { workingLabel }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        case .prominent:
            Button { restore() } label: { workingLabel }
                .buttonStyle(.borderedProminent)
        case .wide:
            Button { restore() } label: {
                workingLabel.font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func restore() {
        running = true
        found = false
        Task {
            let result = await model.restore()
            running = false
            NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
            if result == .completed {
                found = true
                restored()
            } else if let message = model.message {
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }
}

#if DEBUG
/// Exercises the real editor against an isolated local store. No purchase,
/// CloudKit enrollment, or photo-library mutation is part of this fixture.
/// ADR-027: ツール（預ける・病院・見せる）は無料なので、`inactive` でも
/// 新しい記録を作れることをこの fixture で確認する。新しいメモは会員。
@MainActor
struct MembershipAccessFixture: View {
    private let store = PhotoMemoryNoteStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("membership-access-\(UUID().uuidString).json"))
    @State private var record: PhotoMemoryNoteRecord?
    @State private var editingExisting = false
    @State private var editingNew = false
    @State private var state: MembershipPersonalState = .inactive
    @State private var beta = false
    private let actions = MembershipActionAccess(enforcementEnabled: true, personal: .inactive)
    private let care = CareHandoffStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("membership-care-\(UUID().uuidString)"))
    private let evacuation = EvacuationStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("membership-evacuation-\(UUID().uuidString)"))
    private let veterinary = VeterinaryVisitStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("membership-veterinary-\(UUID().uuidString)"))
    private let catID = UUID(uuidString: "AB000000-0000-0000-0000-000000000001")!
    /// ツールの「猫のプロフィール」から新しい記録を作る経路。既存の記録
    /// （ミケ）はプロフィール未登録のままにして、既存と新規を分けて確認する。
    private let toolProfiles: [CatProfilePresentation] = [
        ("AB000000-0000-0000-0000-000000000002", "ソラ"),
        ("AB000000-0000-0000-0000-000000000003", "ハナ"),
        ("AB000000-0000-0000-0000-000000000004", "クロ")
    ].map { CatProfilePresentation(identifier: $0.0, name: $0.1, coverPhoto: nil,
        confirmedPhotos: [], lifeReference: nil) }
    private var context: MembershipAccessContext {
        .init(enforcementEnabled: !beta, personal: state)
    }

    var body: some View {
        NavigationStack {
            List {
                NavigationLink("お世話メモの確認") {
                    CareHandoffView(profiles: toolProfiles, unregisteredPhotos: [], store: care, reuseStore: evacuation)
                }.accessibilityIdentifier("membership-care")
                NavigationLink("診察メモの確認") {
                    VeterinaryVisitsView(profiles: toolProfiles, photos: [], noteStore: store, store: veterinary,
                        careStore: care, evacuationStore: evacuation)
                }.accessibilityIdentifier("membership-veterinary")
                NavigationLink("ツール一覧の確認") { AppStoreScreenshotFixtureRootView() }
                    .accessibilityIdentifier("membership-tools")
                Button("既存メモを編集") { editingExisting = true }
                    .disabled(record == nil).accessibilityIdentifier("membership-existing")
                Button("新しいメモ") { editingNew = true }
                    .accessibilityIdentifier("membership-new")
                Button("確認不能") {
                    // Cannot be confirmed (not the launch-time 「確認しています…」,
                    // which offers nothing yet by design): the restore-only notice.
                    state = .indeterminate(lastVerifiedUntil: nil)
                    actions.update(enforcementEnabled: !beta, personal: state)
                }
                    .accessibilityIdentifier("membership-unknown")
                Button("現在のβ") {
                    beta = true
                    actions.update(enforcementEnabled: false, personal: state)
                }
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
        .environment(\.membershipActions, actions)
        .task {
            guard record == nil else { return }
            if care.plan.cats.isEmpty {
                _ = care.addCat(profileID: catID.uuidString, name: "ミケ", access: .beta)
            }
            _ = try? await veterinary.current(catID: catID, catName: "ミケ") { try $0() }
            if let note = try? await store.save(text: "窓辺で眠った日", for: "membership-existing-photo", expectedRevision: nil) {
                record = try? await store.record(id: note.id)
            }
        }
    }
}
#endif
