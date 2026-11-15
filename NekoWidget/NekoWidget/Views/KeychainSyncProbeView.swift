#if DEBUG || INTERNAL_PRESENTATION
import CryptoKit
import Security
import SwiftUI

/// Isolated synthetic root only. Never queries the product identity/key stores.
private enum KeychainSyncProbe {
    struct Sample: Codable {
        let root: Data
        let createdAt: Date
    }
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "neko") + ".diagnostic.1114j.root-only.v1",
         kSecAttrAccount as String: "synthetic-root",
         kSecAttrSynchronizable as String: true]
    }
    static func create() -> OSStatus {
        let sample = Sample(root: Curve25519.Signing.PrivateKey().rawRepresentation, createdAt: Date())
        guard let data = try? JSONEncoder().encode(sample) else { return errSecParam }
        var request = query
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        request[kSecValueData as String] = data
        // Add only: a late remote value must never be silently overwritten.
        return SecItemAdd(request as CFDictionary, nil)
    }
    static func read() -> (OSStatus, Sample?) {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let sample = try? JSONDecoder().decode(Sample.self, from: data),
              sample.root.count == 32 else { return (status == errSecSuccess ? errSecDecode : status, nil) }
        return (status, sample)
    }
    static func remove() -> OSStatus { SecItemDelete(query as CFDictionary) }
}

@MainActor
private final class KeychainSyncProbeModel: ObservableObject {
    @Published var status = "未観測"
    @Published var lines: [String] = []
    private var lastObservation = ""
    private var started = Date()

    func begin() {
        started = Date()
        lastObservation = ""
        record("観測開始（時刻はこの端末の時計。画面を閉じると停止）")
        refresh()
    }
    func refresh() {
        let (code, sample) = KeychainSyncProbe.read()
        let observation: String
        if let sample, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: sample.root) {
            // Only a public-key fingerprint and timestamp leave the keychain read.
            let fingerprint = SHA256.hash(data: key.publicKey.rawRepresentation)
                .prefix(8).map { String(format: "%02x", $0) }.joined()
            observation = "あり・照合番号 \(fingerprint)・作成 \(sample.createdAt.ISO8601Format())"
        } else if code == errSecItemNotFound {
            observation = "見つかりません（同期待ち／未作成／削除／同期設定の状態は、この結果だけでは判別できません）"
        } else {
            observation = "読取エラー OSStatus=\(code)（鍵なしとは扱いません）"
        }
        status = observation
        if observation != lastObservation {
            record("観測 +\(Int(Date().timeIntervalSince(started)))秒: \(observation)")
            lastObservation = observation
        }
    }
    func create() {
        let code = KeychainSyncProbe.create()
        record(code == errSecSuccess ? "練習鍵をこの端末に作成。相手への到着は未確認" :
            code == errSecDuplicateItem ? "既存項目あり。上書きしていません" : "作成エラー OSStatus=\(code)")
        refresh()
    }
    func remove() {
        let code = KeychainSyncProbe.remove()
        record("練習項目だけを削除 OSStatus=\(code)。相手の削除は相手で確認してください")
        refresh()
    }
    private func record(_ message: String) {
        lines.append("\(Date().ISO8601Format()) \(message)")
        if lines.count > 100 { lines.removeFirst(lines.count - 100) }
    }
    var report: String {
        "1114j 合成root同期・build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")\n" +
        "iCloud同期のON/OFF・サインイン状態: この試験からは判定しません\n" + lines.joined(separator: "\n")
    }
}

struct KeychainSyncProbeView: View {
    @StateObject private var model = KeychainSyncProbeModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsDelete = false

    var body: some View {
        List {
            Section("新しいストアの試験") {
                NavigationLink("P2・rootだけの同期") { P2RootSyncProbeView() }
            }
            Section {
                Text("練習用の本人鍵だけを同期します。実際の本人・写真・手帳の鍵には触れません。2台とも同じテスト用の版を使ってください。")
                Text("作成するのは1台だけ。もう1台は、この画面で到着を待ちます。照合番号が同じか比べてください。")
                Text("iCloudキーチェーンの設定はiPhoneの設定で確認してください。見つからない理由は自動判定できません。")
            }
            Section("いまの観測") {
                Text(model.status).textSelection(.enabled)
                Button("練習鍵を作る（最初の1台だけ）") { model.create() }
                Button("読み取り直す") { model.refresh() }
                Button("観測をここから測り直す") { model.begin() }
                Button("試験項目だけを消す", role: .destructive) { confirmsDelete = true }
            }
            Section("結果（秘密鍵は含みません）") {
                Text(model.report).font(.caption.monospaced()).textSelection(.enabled)
                ShareLink("結果の文字を共有", item: model.report)
            }
        }
        .navigationTitle("機種変更の小さな試験")
        .confirmationDialog("練習項目を消します。同じAccountのもう1台にも削除が届くか確認してください。", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("練習項目だけを消す", role: .destructive) { model.remove() }
        }
        .task {
            model.begin()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                if scenePhase == .active { model.refresh() }
            }
        }
    }
}

@MainActor
private final class P2RootSyncProbeModel: ObservableObject {
    @Published var status = "未観測"
    @Published var busy = false
    @Published var events: [String] = []
    private var store: RootSyncStore?
    private var currentID: String?
    private var started = Date()
    init() {
        // An isolated synthetic namespace, never a product root or the P0 item.
        store = try? RootSyncStore(bundleID: (Bundle.main.bundleIdentifier ?? "neko") + ".diagnostic.1115e",
                                   environment: .synthetic)
    }
    private func record(_ text: String) {
        events.append("\(Date().ISO8601Format()) +\(Int(Date().timeIntervalSince(started)))秒: \(text)")
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }
    private func observe() async {
        guard let store else { status = "試験の準備ができません"; return }
        let next: String
        switch await store.candidates() {
        case .none: currentID = nil; next = "見つかりません（未作成・同期待ち・削除・同期設定は区別できません）"
        case .one(let id): currentID = id; next = "あり・照合番号 " + id
        case .unresolved(let ids): currentID = nil; next = "複数の候補があります。自動選択しません（\(ids.count)件）"
        case .failed(let error): currentID = nil; next = "読取できません: \(error.diagnosticCode)（鍵なしとは扱いません）"
        }
        if status != next { status = next; record(next) }
    }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        await observe()
    }
    func create() async {
        guard !busy, let store else { return }; busy = true; defer { busy = false }
        // No replacement or automatic generation when existing state is unresolved.
        guard case .none = await store.candidates() else { record("既存・同期待ちの競合やエラーを上書きしません"); await observe(); return }
        let result = await store.storeIfAbsent(explicitRoot: Curve25519.Signing.PrivateKey().rawRepresentation)
        record("合成項目の作成結果: \(result)。相手への到着は未確認")
        await observe()
    }
    func remove() async {
        guard !busy, let store, let id = currentID else { return }; busy = true; defer { busy = false }
        record("表示していた合成項目だけ削除: \(await store.removeExact(expectedRootID: id))。相手の結果は別に確認")
        await observe()
    }
    func restartClock() { started = Date(); record("測り直し（端末時計、2秒間隔の観測）") }
    var report: String { "P2合成root同期（秘密鍵なし）\n" + events.joined(separator: "\n") }
}

private struct P2RootSyncProbeView: View {
    @StateObject private var model = P2RootSyncProbeModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsDelete = false
    var body: some View {
        List {
            Text("合成rootだけの新しい同期ストアです。実際の本人・写真・手帳の鍵は読みません。作るのはAだけです。")
            Section("いまの観測") {
                Text(model.status).textSelection(.enabled)
                Button("合成rootを作る（Aだけ）") { Task { await model.create() } }
                Button("読み取り直す") { Task { await model.refresh() } }
                Button("観測をここから測り直す") { model.restartClock() }
                Button("表示中の合成rootだけ消す", role: .destructive) { confirmsDelete = true }
            }.disabled(model.busy)
            Section("結果（画面を閉じる前に残す）") {
                Text(model.report).font(.caption.monospaced()).textSelection(.enabled)
                ShareLink("結果の文字を共有", item: model.report)
            }
        }
        .navigationTitle("P2・rootだけの同期")
        .confirmationDialog("表示中の合成項目1件だけを消します。もう1台への削除は別に確認してください。", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("合成項目だけを消す", role: .destructive) { Task { await model.remove() } }
        }
        .task {
            await model.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                if scenePhase == .active { await model.refresh() }
            }
        }
    }
}

#endif
