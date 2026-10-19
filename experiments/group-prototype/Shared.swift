import Foundation
import CryptoKit
import Security

// Synthetic-only bundle and App Group: no shipping identifiers or live keys.
enum PrototypeCache {
    static let group = "group.com.nekoprototype.isolated"
    static var directory: URL {
        get throws {
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            else { throw CocoaError(.fileNoSuchFile) }
            return url
        }
    }
    static func query(_ label: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "isolated-group-probe",
         kSecAttrAccount as String: label,
         kSecAttrAccessGroup as String: group]
    }
    static func putKey(_ key: Data, label: String) throws {
        var q = query(label)
        SecItemDelete(q as CFDictionary) // Only this experiment's synthetic key.
        q[kSecValueData as String] = key
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteNoPermission) }
    }
    static func key(_ label: String) throws -> Data {
        var q = query(label); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { throw CocoaError(.fileReadNoPermission) }
        return data
    }
    static func write(_ key: Data, label: String) throws {
        try putKey(key, label: label)
        let aad = Data(("synthetic-cache|" + label + "|epoch3").utf8)
        let sealed = try AES.GCM.seal(Data("synthetic cat photo".utf8), using: SymmetricKey(data: key), authenticating: aad)
        guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        try combined.write(to: directory.appendingPathComponent(label + ".bin"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func read(_ label: String) throws -> Bool {
        let combined = try Data(contentsOf: directory.appendingPathComponent(label + ".bin"))
        let sealed = try AES.GCM.SealedBox(combined: combined)
        let aad = Data(("synthetic-cache|" + label + "|epoch3").utf8)
        let plain = try AES.GCM.open(sealed, using: SymmetricKey(data: key(label)), authenticating: aad)
        return plain == Data("synthetic cat photo".utf8)
    }
    static func mlsKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = bytes.withUnsafeMutableBufferPointer { neko_mls_smoke_and_key($0.baseAddress!) }
        guard result == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return Data(bytes)
    }
    static func prepare() throws {
        try write(PrototypeHPKE.runCases(), label: "HPKE")
        try write(mlsKey(), label: "MLS")
    }
    static func widgetRead() -> String {
        do {
            // Executes the actual Rust library in the extension process too;
            // only the app owns shipping MLS mutation in the proposed design.
            _ = try mlsKey()
            guard try read("HPKE"), try read("MLS") else { return "WIDGET_READ_FAILED" }
            let result = "WIDGET_HPKE_MLS_PASS"
            try Data(result.utf8).write(to: directory.appendingPathComponent("widget-result.txt"), options: .atomic)
            return result
        } catch { return "WIDGET_READ_FAILED" }
    }
    static var widgetResult: String {
        (try? String(contentsOf: directory.appendingPathComponent("widget-result.txt"), encoding: .utf8)) ?? "WIDGET_NOT_RUN"
    }
}
