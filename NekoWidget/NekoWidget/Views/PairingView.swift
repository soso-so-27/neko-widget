import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PairingView: View {
    @StateObject private var model = PairingViewModel()
    @State private var dailyUpdateTime = Self.defaultUpdateTime()
    @State private var hasAcceptedPairingTerms = false
    @State private var showsCancelConfirmation = false
    @State private var showsCopyConfirmation = false

    var body: some View {
        Form {
            privacySection

            if !model.isConfigured {
                Section {
                    ContentUnavailableView(
                        "共有サーバー未接続",
                        systemImage: "network.slash",
                        description: Text(model.configurationMessage ?? "このビルドではペアリングを利用できません。")
                    )
                }
            } else if let state = model.state {
                pairingContent(state)
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text("安全な保存領域を確認しています…")
                    }
                }
            }

            if let message = model.state?.lastError ?? model.configurationMessage,
               model.isConfigured || model.state?.lastError != nil {
                Section("確認してください") {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("家族のまど")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.bootstrap() }
        .confirmationDialog(
            "ペアリングをやり直しますか？",
            isPresented: $showsCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button(cancelConfirmationButtonTitle, role: .destructive) {
                Task { await model.cancelAndReset() }
            }
            Button("戻る", role: .cancel) {}
        } message: {
            Text(cancelConfirmationMessage)
        }
    }

    private var privacySection: some View {
        Section {
            if model.isMediaSyncEnabled {
                Label("共有シートで選び、届けると確認した1枚だけ送ります", systemImage: "photo")
                Label("最大2,048pxへ縮小し、位置情報を除いて暗号化します", systemImage: "lock.shield")
                Label("撮影日時は、分かる場合だけ暗号化した中に入ります", systemImage: "calendar.badge.clock")
            } else {
                Label("このビルドでは共有鍵のペアリングだけを行います", systemImage: "key.horizontal")
                Label("写真や縮小画像は送信しません", systemImage: "photo.badge.checkmark")
            }
        } header: {
            Text("共有されるもの")
        } footer: {
            Text(model.isMediaSyncEnabled
                ? "写真が自動送信されることはありません。肉球も共有の指示ではありません。招待コードは信頼できる家族にだけ送り、機種変更や再インストール後は再招待してください。"
                : "写真同期を有効にするビルドでは、送信前に改めて同意を求めます。招待リンクは信頼できる相手にだけ送り、機種変更や再インストール後は再招待してください。")
        }
    }

    @ViewBuilder
    private func pairingContent(_ state: PairingState) -> some View {
        switch state.phase {
        case .unpaired:
            consentSection
            createSection
            joinSection
        case .creatingInvitation:
            progressSection("招待を作成しています…")
            retrySection("招待作成を再試行") {
                await model.createInvitation(dailyBoundaryMinuteUTC: utcBoundaryMinute)
            }
        case .awaitingInvitee:
            invitationSection(state)
            cancelSection
        case .joining:
            progressSection("招待を確認しています…")
            retrySection("参加を再試行") { await model.joinInvitation() }
        case .pendingApproval:
            phraseSection(state, title: "相手の承認を待っています")
            refreshSection
            cancelSection
        case .approvalRequired:
            phraseSection(state, title: "確認フレーズを照合")
            Section {
                Toggle("相手の画面と同じフレーズです", isOn: $model.hasConfirmedPhrase)
                Button("この相手を承認") {
                    Task { await model.approveAfterPhraseConfirmation() }
                }
                .disabled(!model.hasConfirmedPhrase || model.isWorking)
            } footer: {
                Text("一致しない場合は承認せず、招待をやり直してください。確認前に写真の復号鍵は相手へ渡りません。")
            }
            cancelSection
        case .awaitingCompletion:
            progressSection("相手の端末で完了するのを待っています")
            refreshSection
            cancelSection
        case .paired:
            Section {
                Label("ペアリング済み", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let phrase = state.verificationPhrase {
                    LabeledContent("確認フレーズ", value: phrase)
                        .font(.caption)
                }
            } footer: {
                Text(model.isMediaSyncEnabled
                    ? "写真は共有シートで1枚ずつ確認した時だけ届きます。"
                    : "このビルドではペアリングだけが有効で、写真同期は無効です。")
            }
            if model.isMediaSyncEnabled && !model.hasCurrentMediaSharingConsent {
                mediaConsentRenewalSection
            }
            refreshSection
            pairedCancelSection
        case .failed:
            Section {
                Label("ペアリングを完了できませんでした", systemImage: "xmark.circle")
            }
            if state.memberID != nil {
                cancelSection
            }
        }
    }

    private var createSection: some View {
        Section {
            Button {
                Task {
                    if model.isMediaSyncEnabled {
                        guard model.recordMediaSharingConsent() else { return }
                    }
                    await model.createInvitation(
                        dailyBoundaryMinuteUTC: utcBoundaryMinute
                    )
                }
            } label: {
                Label("招待コードを作る", systemImage: "person.badge.plus")
            }
            .disabled(model.isWorking || !hasAcceptedPairingTerms)
        } header: {
            Text("招待する")
        } footer: {
            Text("家族のまどを1つ作り、信頼できる相手を招待します。公開フィードや検索には表示されません。")
        }
    }

    private var joinSection: some View {
        Section {
            TextField(
                "NW1.から始まる招待コード",
                text: $model.enteredInvitationCode,
                axis: .vertical
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.footnote, design: .monospaced))
            .lineLimit(2...4)

            Button {
                Task {
                    if model.isMediaSyncEnabled {
                        guard model.recordMediaSharingConsent() else { return }
                    }
                    await model.joinInvitation()
                }
            } label: {
                Label("招待コードで参加", systemImage: "person.2")
            }
            .disabled(
                model.isWorking
                    || !hasAcceptedPairingTerms
                    || model.enteredInvitationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        } header: {
            Text("招待された")
        }
    }

    private var consentSection: some View {
        Section {
            Toggle(isOn: $hasAcceptedPairingTerms) {
                Text("共有の内容と限界を確認しました")
            }
        } header: {
            Text("ペアリング前の確認")
        } footer: {
            Text(model.isMediaSyncEnabled
                ? "共有シートで送信を確定した1枚だけを、最大2,048pxへ縮小して暗号化します。位置情報は除き、撮影日時は暗号化した中だけに入ります。共有解除後も、相手が保存・スクリーンショットしたコピーは回収できません。"
                : "この段階では鍵のペアリングだけを行い、写真はまだ送りません。写真同期を有効にするbuildでは改めて明示的な同意を求めます。共有解除後も、相手が保存・スクリーンショットしたコピーは回収できません。再インストールや機種変更後は再招待が必要です。")
        }
    }

    private var mediaConsentRenewalSection: some View {
        Section {
            Toggle(isOn: $hasAcceptedPairingTerms) {
                Text("写真共有の内容と限界を確認しました")
            }
            Button("写真共有に同意する") {
                guard model.recordMediaSharingConsent() else { return }
                hasAcceptedPairingTerms = false
            }
            .disabled(!hasAcceptedPairingTerms || model.isWorking)
        } header: {
            Text("1枚を届ける前の確認")
        } footer: {
            Text("写真は自動送信しません。共有シートで毎回1枚を選び、届け先と内容を確認して送ります。原本と位置情報は送りません。")
        }
    }

    private func invitationSection(_ state: PairingState) -> some View {
        Section {
            if let code = model.invitationCode {
                Text(code)
                    .font(.system(.caption2, design: .monospaced))
                    .accessibilityLabel("招待コード")

                ShareLink(item: code) {
                    Label("招待コードを送る", systemImage: "square.and.arrow.up")
                }

                Button {
                    copyInvitationCode(code, expiresAt: state.invitationExpiresAt)
                } label: {
                    Label("コードをコピー", systemImage: "doc.on.doc")
                }

                if showsCopyConfirmation {
                    Label("この端末内にコピーしました（最長10分で消去）", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("招待コードを安全な保存領域から読み込めませんでした。")
                    .foregroundStyle(.secondary)
            }

            if let expiresAt = state.invitationExpiresAt {
                LabeledContent(
                    "有効期限",
                    value: expiresAt.formatted(.dateTime.month().day().hour().minute())
                )
            }

            Button("参加状況を更新") {
                Task { await model.refresh() }
            }
            .disabled(model.isWorking)
        } header: {
            Text("招待コード")
        } footer: {
            Text("コードには一回限りの参加用秘密が含まれます。写真の復号鍵は含まれず、確認フレーズを照合して承認するまで相手には渡りません。")
        }
    }

    private func phraseSection(_ state: PairingState, title: String) -> some View {
        Section {
            if let phrase = state.verificationPhrase {
                Text(phrase)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("確認フレーズ、\(phrase.replacingOccurrences(of: "・", with: "、"))")
            }
        } header: {
            Text(title)
        } footer: {
            Text("12語すべてを相手の端末と比べてください。")
        }
    }

    private var refreshSection: some View {
        Section {
            Button("状態を更新") {
                Task { await model.refresh() }
            }
            .disabled(model.isWorking)
        }
    }

    private var cancelSection: some View {
        Section {
            Button("ペアリングをやり直す", role: .destructive) {
                showsCancelConfirmation = true
            }
            .disabled(model.isWorking)
        }
    }

    private var pairedCancelSection: some View {
        Section {
            Button("ペアリングを解除してやり直す", role: .destructive) {
                showsCancelConfirmation = true
            }
            .disabled(model.isWorking)
        } footer: {
            Text(model.isMediaSyncEnabled
                ? "解除すると相手からのアクセスを直ちに停止し、サーバー上の共有データ削除を開始します。この開発段階では削除完了の進捗表示はまだありません。相手が端末外へ保存・スクリーンショットしたコピーは回収できません。"
                : "現在は写真同期前のため、共有鍵とペアリング情報だけを解除します。写真同期を追加する段階では、サーバー上の縮小画像を削除する進捗表示もここへ追加します。")
        }
    }

    private var cancelConfirmationButtonTitle: String {
        model.state?.phase == .paired
            ? "ペアリングを解除する"
            : "ペアリングを取り消してやり直す"
    }

    private var cancelConfirmationMessage: String {
        if model.state?.phase == .paired {
            return "サーバー側のペアリングを解除できたことを確認してから、この端末の共有鍵とペアリング情報を削除します。通信に失敗した場合は鍵を残して再試行できます。"
        }
        return "サーバー側の参加状態を先に取り消し、確認できた場合だけこの端末の共有鍵を削除します。通信に失敗した場合は鍵を残して再試行できます。"
    }

    private func progressSection(_ text: String) -> some View {
        Section {
            HStack {
                ProgressView()
                Text(text)
            }
        }
    }

    private func retrySection(
        _ title: String,
        action: @escaping () async -> Void
    ) -> some View {
        Section {
            Button(title) { Task { await action() } }
                .disabled(model.isWorking)
        }
    }

    private func copyInvitationCode(_ code: String, expiresAt: Date?) {
        let tenMinutesFromNow = Date().addingTimeInterval(10 * 60)
        let pasteboardExpiry = min(expiresAt ?? tenMinutesFromNow, tenMinutesFromNow)
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: code]],
            options: [
                .localOnly: true,
                .expirationDate: pasteboardExpiry
            ]
        )
        showsCopyConfirmation = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            showsCopyConfirmation = false
        }
    }

    private var utcBoundaryMinute: Int {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: dailyUpdateTime)
        let minute = calendar.component(.minute, from: dailyUpdateTime)
        let localMinute = hour * 60 + minute
        let offsetMinute = TimeZone.current.secondsFromGMT(for: dailyUpdateTime) / 60
        return (localMinute - offsetMinute + 1_440) % 1_440
    }

    private static func defaultUpdateTime() -> Date {
        Calendar.current.date(
            bySettingHour: 4,
            minute: 0,
            second: 0,
            of: .now
        ) ?? .now
    }
}
