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
#endif
