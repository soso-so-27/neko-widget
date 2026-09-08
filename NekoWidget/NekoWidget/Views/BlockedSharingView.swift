import SwiftUI
import UIKit

struct BlockedSharingView: View {
    @State private var entries: [MomentBlockWithdrawalStore.Entry] = []
    @State private var confirmationTarget: MomentBlockWithdrawalStore.Entry?
    @State private var isWorking = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var completionMessage: String?
    @State private var showsNewWindow = false

    var body: some View {
        List {
            if !hasLoaded && errorMessage == nil {
                ProgressView("ブロックの記録を確認しています…")
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("もう一度確認する") { Task { await reload() } }
                        .disabled(isWorking)
                }
            }
            if let completionMessage {
                Section {
                    Label(completionMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if hasLoaded && entries.isEmpty {
                ContentUnavailableView(
                    "ブロックした共有はありません", systemImage: "hand.raised",
                    description: Text("このiPhoneで行ったブロックを、ここから解除できます。")
                )
            }
            ForEach(entries) { entry in
                Section {
                    Text(entry.windowDisplayName).font(.headline)
                    Text(entry.createdAt, style: .date)
                        .font(.caption).foregroundStyle(.secondary)
                    if entry.phase == .withdrawn {
                        Label("ブロック解除済み・共有は停止中", systemImage: "checkmark.shield")
                            .font(.subheadline)
                        Button("新しいまどで共有を始める") {
                            Task { await startNewWindow() }
                        }
                        .accessibilityIdentifier("blocked-sharing-start-new")
                    } else {
                        if entry.phase == .pending {
                            Text("ブロックの結果を確認できていません。取り消す場合は、下のボタンから確認できます。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("ブロックを解除") { confirmationTarget = entry }
                            .accessibilityIdentifier("blocked-sharing-withdraw")
                    }
                }
                .disabled(isWorking)
            }
            Section {
                Text("ブロックを解除しても、写真の送受信は再開しません。もう一度共有するには、新しいまどを作り、相手と招待・確認をやり直します。削除した写真は戻りません。")
                Text("以前のバージョンで行ったブロックや、別のiPhoneで行ったブロックは、この一覧から解除できません。以前の共有を復元することもできません。")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("ブロックした共有")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await reload() }
        }
        .alert(
            "ブロックを解除しますか？",
            isPresented: Binding(
                get: { confirmationTarget != nil },
                set: { if !$0 { confirmationTarget = nil } }
            ),
            presenting: confirmationTarget
        ) { entry in
            Button("ブロックを解除する") {
                confirmationTarget = nil
                Task { await withdraw(entry) }
            }
            Button("キャンセル", role: .cancel) { confirmationTarget = nil }
        } message: { _ in
            Text("共有は自動で再開しません。もう一度写真を送り合うには、新しい招待から双方で確認します。削除した写真は戻りません。")
        }
        .navigationDestination(isPresented: $showsNewWindow) {
            PairingView(initialSetupPath: .create)
        }
    }

    @MainActor
    private func reload() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let bootstrap = try await PairingInstallationGuard.bootstrapAsync()
            entries = try MomentBlockWithdrawalStore.entries(
                installationMarker: bootstrap.state.installationMarker
            )
            hasLoaded = true
            errorMessage = nil
        } catch {
            entries = []
            hasLoaded = false
            errorMessage = "ブロックの記録を確認できませんでした。iPhoneのロックを解除したまま、もう一度お試しください。"
        }
    }

    @MainActor
    private func withdraw(_ entry: MomentBlockWithdrawalStore.Entry) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        completionMessage = nil
        do {
            let bootstrap = try await PairingInstallationGuard.bootstrapAsync()
            let marker = bootstrap.state.installationMarker
            let record = try MomentBlockWithdrawalStore.record(id: entry.id, installationMarker: marker)
            if record.phase != .withdrawn {
                guard let token = record.token else { throw PairingError.stateUnavailable }
                let api = try URLSessionMomentSharingAPIClient()
                try await api.withdrawBlock(id: record.id, token: token, clientRequestID: record.withdrawalRequestID)
                try await PairingInstallationGuard.completeBlockWithdrawalLocallyAsync(record)
                NotificationCenter.default.post(name: .momentSharingPresentationNeedsRefresh, object: nil)
            }
            entries = try MomentBlockWithdrawalStore.entries(installationMarker: marker)
            completionMessage = "ブロックを解除しました。写真の共有はまだ再開していません。"
        } catch {
            // Keep the capability and request ID after any unknown result so
            // a retry can finish the same withdrawal without claiming success.
            errorMessage = "ブロックの解除を確認できませんでした。通信状態を確認して、もう一度「ブロックを解除」をお試しください。"
        }
        isWorking = false
    }

    @MainActor
    private func startNewWindow() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let bootstrap = try await PairingInstallationGuard.prepareNewWindowForBlockRestartAsync()
            guard bootstrap.state.phase == .unpaired else { throw PairingError.stateUnavailable }
            errorMessage = nil
            showsNewWindow = true
            NotificationCenter.default.post(name: .momentSharingPresentationNeedsRefresh, object: nil)
        } catch PrivateWindowCatalogStore.Error.windowLimitReached {
            errorMessage = "まどは合計3個までです。使わないまどの共有を終了してからお試しください。"
        } catch PrivateWindowCatalogStore.Error.setupWindowAlreadyExists {
            errorMessage = "設定中のまどがあります。先にその設定を完了するか、取り消してください。"
        } catch {
            errorMessage = "新しいまどの準備を完了できませんでした。もう一度お試しください。"
        }
    }
}
