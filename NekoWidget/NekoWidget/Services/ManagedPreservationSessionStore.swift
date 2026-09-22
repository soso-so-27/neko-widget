import Foundation
import Security
import CryptoKit

/// Only the opaque preservation session is persisted. Apple credentials and
/// challenge proofs are transient; this item neither syncs nor restores to a new device.
struct ManagedPreservationSessionStore: Sendable {
    private static let lock = NSLock()

    struct Credential: Codable, Equatable, Sendable {
        let token: String
        let ownerId: String
        let expiresAt: Date

        func validated() throws -> Self {
            guard (16...4096).contains(token.utf8.count),
                  token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
                  !ownerId.isEmpty, ownerId.utf8.count <= 256,
                  expiresAt.timeIntervalSince1970.isFinite else {
                throw ManagedPreservationError.invalidResponse
            }
            return self
        }
    }

    let origin: String

    /// No photograph or session token is copied into this owner-bound recovery item.
    struct PendingMemo: Codable, Identifiable, Sendable {
        let id: UUID
        let ownerId: String
        let recordId: UUID
        let baseRevision: Int
        let text: String
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: "jp.nekowidget.managed-preservation.session.v1",
         kSecAttrAccount: origin,
         kSecAttrSynchronizable: kCFBooleanFalse as Any]
    }

    func load() throws -> Credential? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try readCredential()
    }

    private func readCredential() throws -> Credential? {
        var request = query
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              data.count <= 8192 else { throw ManagedPreservationError.secureStorage }
        do {
            return try ManagedPreservationWire.decoder()
                .decode(Credential.self, from: data).validated()
        } catch { throw ManagedPreservationError.secureStorage }
    }

    /// Compare and replace under one process-wide lock. An old client must not
    /// overwrite a session another screen established while authorization was pending.
    func save(_ credential: Credential, replacing expected: Credential?) throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard try readCredential() == expected else { return false }
        let data = try ManagedPreservationWire.encoder().encode(credential.validated())
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { throw ManagedPreservationError.secureStorage }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ManagedPreservationError.secureStorage
        }
        return true
    }

    /// A stale 401/logout may clear only the credential that made that request.
    func clear(ifMatching expected: Credential?) throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard try readCredential() == expected else { return false }
        guard expected != nil else { return true }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ManagedPreservationError.secureStorage
        }
        return true
    }

    private func memoQuery(ownerId: String, id: UUID? = nil) -> [CFString: Any] {
        // Length-delimited inputs prevent context concatenation collisions.
        let context = Data("\(origin.utf8.count):\(origin)\(ownerId.utf8.count):\(ownerId)".utf8)
        let scope = SHA256.hash(data: context).map { String(format: "%02x", $0) }.joined()
        var result: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "jp.nekowidget.managed-preservation.pending-memo.v1." + scope,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
        if let id { result[kSecAttrAccount] = id.uuidString.lowercased() }
        return result
    }

    func savePendingMemo(_ memo: PendingMemo) throws {
        // A failed write must leave the coordinator's in-memory draft intact.
        guard !memo.ownerId.isEmpty, memo.ownerId.utf8.count <= 256,
              memo.baseRevision > 0, memo.text.utf8.count <= 262_144 else {
            throw ManagedPreservationError.secureStorage
        }
        let data = try JSONEncoder().encode(memo)
        Self.lock.lock(); defer { Self.lock.unlock() }
        let request = memoQuery(ownerId: memo.ownerId, id: memo.id)
        let attributes: [CFString: Any] = [kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ManagedPreservationError.secureStorage }
        var item = request
        attributes.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ManagedPreservationError.secureStorage
        }
    }

    /// Call only after verifying this owner. Never enumerate other owners' drafts.
    func pendingMemos(ownerId: String) throws -> [PendingMemo] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var request = memoQuery(ownerId: ownerId)
        request[kSecReturnData] = true; request[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let values = result as? [Data] else {
            throw ManagedPreservationError.secureStorage
        }
        return try values.map { data in
            guard data.count <= 2 * 1024 * 1024,
                  let memo = try? JSONDecoder().decode(PendingMemo.self, from: data),
                  memo.ownerId == ownerId, memo.baseRevision > 0,
                  memo.text.utf8.count <= 262_144 else { throw ManagedPreservationError.secureStorage }
            return memo
        }
    }

    func removePendingMemo(id: UUID, ownerId: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let status = SecItemDelete(memoQuery(ownerId: ownerId, id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ManagedPreservationError.secureStorage
        }
    }
}
