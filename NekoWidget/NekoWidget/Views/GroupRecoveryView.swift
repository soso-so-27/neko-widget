import SwiftUI

// 機種変更の画面。状態を受け取って描くだけ（文とボタンは GroupRecoveryPresentation）。
// 発行が OFF の間、通常の版ではどこからも開かない。入口は内部試験の版の
// 設定 → テスト用 にある見本の一覧だけ（このファイルの下の内部試験の部分）。
// 通常の版で開くときの入口は、まどのタブの一覧の上（参加の手続き中の行と同じ所）に
// GroupRecoveryEntryRow を 1 行。状態の供給は Codex のアダプタが受け持つ。

/// 押したものを受け取って、状態モデルに渡す側（Codex のアダプタ）。
/// 画面からは、本人が押したものだけが本人の操作の印つきで届く（GroupRecoveryCommandRoute）。
/// まどのタブの入口。参加の手続き中の行と同じ形。
struct GroupRecoveryEntryRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Label(GroupRecoveryWords.entry, systemImage: "iphone.and.arrow.forward")
                .font(.body.weight(.semibold))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(14)
        .frame(minHeight: 44)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// 入口から開くシート。本人が 2 つならまず選ぶ。まどが 1 つならその画面、複数なら一覧。
struct GroupRecoverySheet: View {
    let rootChoice: [GroupRecoveryRootCandidate]
    let items: [GroupRecoveryWindowItem]
    let handler: any GroupRecoveryCommandHandling
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if rootChoice.count >= 2 {
                    GroupRecoveryStateView(state: .chooseRoot(rootChoice), send: route)
                } else if items.count == 1, let item = items.first {
                    GroupRecoveryStateView(state: .registration(item.state), devices: item.devices, send: route)
                } else {
                    GroupRecoveryWindowList(items: items, send: route)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { SheetCloseButton { dismiss() } }
            }
        }
    }

    private func route(_ command: GroupRecoveryCommand) {
        GroupRecoveryCommandRoute.send(command, to: handler, dismiss: { dismiss() })
    }
}

/// 押したものの行き先。今はしない・閉じるは送らずに閉じる。ready の「開く」は
/// 本人が押したものではないので自動の扱い、それ以外は本人の操作として送る。
@MainActor
enum GroupRecoveryCommandRoute {
    static func send(_ command: GroupRecoveryCommand, to handler: any GroupRecoveryCommandHandling,
                     dismiss: @escaping () -> Void) {
        switch command {
        case .dismiss:
            dismiss()
        case .perform(.complete):
            Task { await handler.handle(command) }
        default:
            Task { await SharingPersonAction.run { await handler.handle(command) } }
        }
    }
}

/// まどが複数あるとき：まどごとに 1 行（名前が開ければ名前、開けなければ「まど」）。
struct GroupRecoveryWindowList: View {
    let items: [GroupRecoveryWindowItem]
    let send: (GroupRecoveryCommand) -> Void

    var body: some View {
        List {
            ForEach(items.filter { GroupRecoveryPresentation.rowStatus(for: $0.state) != nil }) { item in
                NavigationLink {
                    GroupRecoveryStateView(state: .registration(item.state), devices: item.devices, send: send)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName).font(.body.weight(.semibold))
                        if let status = GroupRecoveryPresentation.rowStatus(for: item.state) {
                            Text(status).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                .accessibilityIdentifier("group-recovery-window-\(item.windowID)")
            }
        }
        .navigationTitle(GroupRecoveryWords.entry)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 1 つの状態の画面。
struct GroupRecoveryStateView: View {
    let state: GroupRecoveryScreenState
    var devices: [GroupRecoveryDevice] = []
    let send: (GroupRecoveryCommand) -> Void

    @State private var asksName = false
    @State private var removing: GroupRecoveryDevice?
    @State private var choosing: GroupRecoveryRootCandidate?

    var body: some View {
        Group {
            if let screen = GroupRecoveryPresentation.make(for: state) {
                switch screen.layout {
                case .message: message(screen)
                case .deviceList: deviceList(screen)
                case .rootChoice: rootChoice(screen)
                }
            } else {
                // ready：この画面は閉じて、まどを開く。
                Color.clear.onAppear {
                    if case .registration(let registration) = state { send(.perform(registration.nextAction)) }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $asksName) {
            if case .registration(let registration) = state {
                GroupRecoveryFreshNameForm(state: registration, send: send)
            }
        }
    }

    // MARK: 状態 1 つ＋ 1 文＋ボタン（家族の手帳の「参加を待っています」と同じ作り）

    private func message(_ screen: GroupRecoveryPresentation) -> some View {
        GeometryReader { proxy in
            ScrollView {
                ContentUnavailableView {
                    Label { Text(screen.title) } icon: { icon(screen.icon) }
                } description: {
                    if let message = screen.message { Text(message) }
                } actions: {
                    VStack(spacing: NekoSpacing.s) {
                        if let primary = screen.primary {
                            Button { press(primary) } label: {
                                Text(primary.title).font(.headline).frame(maxWidth: .infinity)
                            }
                            .nekoPrimaryButton()
                            .accessibilityIdentifier("group-recovery-primary")
                        }
                        if let secondary = screen.secondary {
                            Button(secondary.title) { press(secondary) }
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("group-recovery-secondary")
                        }
                    }
                    .padding(.horizontal, NekoSpacing.l)
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(NekoPalette.groupedGround)
        .accessibilityIdentifier("group-recovery-screen")
    }

    @ViewBuilder private func icon(_ icon: GroupRecoveryPresentation.Icon) -> some View {
        switch icon {
        case .progress: ProgressView()
        case .found: Image(systemName: "iphone.and.arrow.forward")
        case .offline: Image(systemName: "wifi.exclamationmark")
        case .waiting: Image(systemName: "hourglass")
        case .noProvider: Image(systemName: "iphone.slash")
        case .needsOriginal: Image(systemName: "iphone")
        case .revoked: Image(systemName: "xmark.circle")
        case .none: EmptyView()
        }
    }

    private func press(_ button: GroupRecoveryButton) {
        switch button.step {
        case .send(let command): send(command)
        case .askFreshName: asksName = true
        }
    }

    // MARK: 3 台の上限：外す iPhone を選ぶ

    private func deviceList(_ screen: GroupRecoveryPresentation) -> some View {
        List {
            Section {
                ForEach(devices) { device in
                    Button { removing = device } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.modelName).font(.body.weight(.semibold))
                            Text(GroupRecoveryWords.registered(Self.day(device.registeredAt)))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                    .tint(Color.primary)
                    .accessibilityIdentifier("group-recovery-device-\(device.id)")
                }
            } header: {
                header(screen)
            }
        }
        .confirmationDialog(removing.map { GroupRecoveryWords.removeDeviceQuestion($0.modelName) } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { device in
            Button(GroupRecoveryWords.removeDevice, role: .destructive) {
                if case .registration(let registration) = state,
                   let command = GroupRecoveryActions.removeDevice(registration, deviceID: device.id) {
                    send(command)
                }
            }
            .accessibilityIdentifier("group-recovery-remove-confirm")
        } message: { _ in
            Text(GroupRecoveryWords.removeDeviceMessage)
        }
    }

    // MARK: 本人が 2 つ：どちらを使うか

    private func rootChoice(_ screen: GroupRecoveryPresentation) -> some View {
        let candidates: [GroupRecoveryRootCandidate] = {
            if case .chooseRoot(let list) = state { return list }
            return []
        }()
        return List {
            Section {
                ForEach(candidates) { candidate in
                    Button { choosing = candidate } label: {
                        Text(candidate.text)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .tint(Color.primary)
                    .accessibilityIdentifier("group-recovery-root-\(candidate.id)")
                }
            } header: {
                header(screen)
            }
        }
        .confirmationDialog(choosing?.text ?? "",
                            isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                            titleVisibility: .visible, presenting: choosing) { candidate in
            Button(GroupRecoveryWords.choose) {
                if let command = GroupRecoveryActions.chooseRoot(candidates, rootID: candidate.id) { send(command) }
            }
            .accessibilityIdentifier("group-recovery-choose-confirm")
        }
    }

    private func header(_ screen: GroupRecoveryPresentation) -> some View {
        VStack(alignment: .leading, spacing: NekoSpacing.xxs) {
            Text(screen.title)
                .font(.title3.weight(.bold)).foregroundStyle(Color.primary)
                .accessibilityAddTraits(.isHeader)
            if let message = screen.message {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, NekoSpacing.xs)
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().locale(Locale(identifier: "ja_JP")))
    }
}

/// ［新しく続ける］のあと：新しいまどの名前。名前を入れて［続ける］を押すまで何も起きない。
struct GroupRecoveryFreshNameForm: View {
    let state: GroupRecoveryRegistrationState
    let send: (GroupRecoveryCommand) -> Void
    @State private var name = ""
    @FocusState private var typing: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooLong: Bool { !GroupDisplayName.fits(trimmed) }

    var body: some View {
        Form {
            Section {
                TextField(GroupRecoveryWords.freshNamePlaceholder, text: VisibleTextInput.binding($name))
                    .focused($typing)
                    .submitLabel(.done)
                    .accessibilityIdentifier("group-recovery-fresh-name")
            } header: {
                Text(GroupRecoveryWords.freshNameHeader)
            } footer: {
                if tooLong { Text(GroupDisplayName.tooLongMessage).foregroundStyle(.red) }
            }
            Section {
                Button {
                    typing = false
                    if let command = GroupRecoveryActions.freshGeneration(state, newName: trimmed) { send(command) }
                } label: {
                    Text(GroupRecoveryWords.continueButton).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.isEmpty || tooLong)
                .accessibilityIdentifier("group-recovery-fresh-confirm")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .navigationTitle(GroupRecoveryWords.freshContinue)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG || INTERNAL_PRESENTATION
// MARK: - 内部試験の版だけ：見本の状態で、それぞれの画面を見る

/// 押しても何も送らない。最後に押したものを一覧の下に出すだけ。
@MainActor
final class GroupRecoveryGalleryRecorder: ObservableObject, GroupRecoveryCommandHandling {
    @Published var last: String?
    func handle(_ command: GroupRecoveryCommand) async { last = Self.describe(command) }
    func record(_ command: GroupRecoveryCommand) { last = Self.describe(command) }
    static func describe(_ command: GroupRecoveryCommand) -> String {
        switch command {
        case .perform(let action):
            switch action {
            case .queryStatus: return "状態を問い合わせる（同じ手続き）"
            case .submitSameOperation: return "登録を送る（同じ手続き）"
            case .prepareFreshGeneration(_, let name): return "新しく続ける準備：\(name)"
            case .complete: return "まどを開く"
            default: return "\(action)"
            }
        case .removeDevice(_, let deviceID): return "端末を外す：\(deviceID)"
        case .chooseRoot(let rootID): return "こちらを使う：\(rootID)"
        case .dismiss: return "閉じる（何も送らない）"
        }
    }
}

/// 見本の状態。本物の名前・写真は使わない。
enum GroupRecoverySamples {
    static let operation = UUID(uuidString: "00000000-0000-4000-8000-000000001115")!
    static let devices = [
        GroupRecoveryDevice(id: "sample-device-1", modelName: "iPhone 12", registeredAt: date(2023, 4, 2)),
        GroupRecoveryDevice(id: "sample-device-2", modelName: "iPhone 13 mini", registeredAt: date(2024, 9, 21)),
        GroupRecoveryDevice(id: "sample-device-3", modelName: "iPhone 15", registeredAt: date(2025, 11, 3)),
    ]
    static let roots = [
        GroupRecoveryRootCandidate(
            summary: GroupRootMembershipSummary(rootID: "sample-root-a", windowIDs: ["w1", "w2"], notebookIDs: ["n1"]),
            openableWindowNames: ["実家のまど"]),
        GroupRecoveryRootCandidate(
            summary: GroupRootMembershipSummary(rootID: "sample-root-b", windowIDs: [], notebookIDs: []),
            openableWindowNames: []),
    ]

    struct Case: Identifiable {
        let id: String
        let label: String
        let state: GroupRecoveryScreenState
    }
    static let cases: [Case] = [
        .init(id: "checking", label: "確かめ中", state: .registration(.checking(operationID: operation))),
        .init(id: "unavailable", label: "通信できない", state: .registration(.unavailable(operationID: operation))),
        .init(id: "notStarted", label: "前のまどが見つかった", state: .registration(.notStarted(operationID: operation))),
        .init(id: "waiting", label: "登録済み・待つ",
              state: .registration(.registeredWaitingForKeys(operationID: operation, deviceID: "sample-new"))),
        .init(id: "noKeyProvider", label: "1 人のまど・前の端末なし",
              state: .registration(.noKeyProvider(operationID: operation, deviceID: "sample-new"))),
        .init(id: "needsOriginal", label: "前の iPhone か招待が必要",
              state: .registration(.needsOriginalDeviceOrInvitation(operationID: operation))),
        .init(id: "deviceLimit", label: "3 台まで", state: .registration(.deviceLimit(operationID: operation))),
        .init(id: "revoked", label: "退会・削除・失効", state: .registration(.revoked(operationID: operation))),
        .init(id: "ready", label: "ready（画面を閉じてまどを開く）",
              state: .registration(.ready(operationID: operation, deviceID: "sample-new"))),
        .init(id: "chooseRoot", label: "本人が 2 つ", state: .chooseRoot(roots)),
    ]
    static let windows: [GroupRecoveryWindowItem] = [
        .init(windowID: "sample-window-1", name: "実家のまど",
              state: .registeredWaitingForKeys(operationID: operation, deviceID: "sample-new")),
        .init(windowID: "sample-window-2", name: "猫の友だち", state: .notStarted(operationID: operation)),
        .init(windowID: "sample-window-3", name: nil, state: .needsOriginalDeviceOrInvitation(operationID: operation)),
        .init(windowID: "sample-window-4", name: "ひとりのまど",
              state: .noKeyProvider(operationID: operation, deviceID: "sample-new")),
    ]

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "Asia/Tokyo"),
                                                                    year: year, month: month, day: day, hour: 12)) ?? Date()
    }
}

/// 設定 → テスト用 → 機種変更の画面（見本）。
struct GroupRecoveryGallery: View {
    @StateObject private var recorder = GroupRecoveryGalleryRecorder()
    @State private var showsSheet = false

    var body: some View {
        List {
            Section {
                Button { showsSheet = true } label: { GroupRecoveryEntryRow() }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("group-recovery-entry")
            } header: { Text("まどのタブの入口（一覧の上）") }
            Section {
                ForEach(GroupRecoverySamples.cases) { sample in
                    NavigationLink(sample.label) {
                        GroupRecoveryStateView(state: sample.state,
                                               devices: GroupRecoverySamples.devices,
                                               send: { recorder.record($0) })
                    }
                    .accessibilityIdentifier("group-recovery-case-\(sample.id)")
                }
            } header: { Text("状態ごとの画面") }
            if let last = recorder.last {
                Section { Text(last) } header: { Text("最後に押したボタン（何も送っていません）") }
            }
        }
        .navigationTitle("機種変更の画面（見本）")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsSheet) {
            GroupRecoverySheet(rootChoice: [], items: GroupRecoverySamples.windows, handler: recorder)
        }
    }
}
#endif

#if DEBUG
/// 撮影用（--group-recovery-ui-fixture）。`--group-recovery-case <id>` でその画面を、
/// `windows` でまどが複数の一覧を、指定なしで見本の一覧を出す。`--group-recovery-text ax5` でいちばん大きい文字。
struct GroupRecoveryFixtureRoot: View {
    static let launchArgument = "--group-recovery-ui-fixture"
    @StateObject private var recorder = GroupRecoveryGalleryRecorder()

    private static func value(_ name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    var body: some View {
        content
            .dynamicTypeSize(Self.value("--group-recovery-text") == "ax5" ? .accessibility5 : .large)
    }

    @ViewBuilder private var content: some View {
        let requested = Self.value("--group-recovery-case")
        if requested == "windows" {
            GroupRecoverySheet(rootChoice: [], items: GroupRecoverySamples.windows, handler: recorder)
        } else if let sample = GroupRecoverySamples.cases.first(where: { $0.id == requested }) {
            NavigationStack {
                GroupRecoveryStateView(state: sample.state, devices: GroupRecoverySamples.devices, send: { recorder.record($0) })
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { SheetCloseButton {} } }
            }
        } else {
            NavigationStack { GroupRecoveryGallery() }
        }
    }
}
#endif
