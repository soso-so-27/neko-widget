import CryptoKit
import Foundation

enum MomentSharingProtocol {
    static let version = 2
    static let APIPathVersion = "v2"
    static let maximumCanonicalPixelDimension = 2_048
    static let maximumObjectCiphertextBytes = 1_024 * 1_024
    static let maximumMediaCiphertextBytes = maximumObjectCiphertextBytes - 96 * 1_024
    static let maximumManifestCiphertextBytes = 64 * 1_024
    static let maximumWrappedKeyBytes = 512
    static let moderationVersion = 1
    static let acknowledgedRetentionSeconds: TimeInterval = 7 * 24 * 60 * 60
    static let unreceivedRetentionSeconds: TimeInterval = 30 * 24 * 60 * 60
    static let reportContentRetentionSeconds: TimeInterval = 7 * 24 * 60 * 60
    /// Must match the relay's MOMENT_UPLOAD_TTL_SECONDS. Relay wall-clock
    /// values never become unbounded local-retention authority.
    static let maximumUploadLeaseSeconds: TimeInterval = 60 * 60
    static let maximumRelayClockSkewSeconds: TimeInterval = 5 * 60
    /// Must match the relay's report-only window. A signed but malformed
    /// deadline may shorten this safety window, never extend local retention
    /// or authorization beyond one day plus explicit clock skew.
    static let maximumReportOnlyWindowSeconds: TimeInterval = 24 * 60 * 60
    /// Must match the relay's IDEMPOTENCY_TTL_SECONDS. A lost commit response
    /// can only be reconciled while the relay retains that exact response.
    static let commitReplayRetentionSeconds: TimeInterval = 2 * 24 * 60 * 60

    static func validatedUploadExpiry(
        _ expiresAt: Date,
        receivedAt: Date
    ) throws -> Date {
        guard expiresAt > receivedAt.addingTimeInterval(-maximumRelayClockSkewSeconds),
              expiresAt <= receivedAt.addingTimeInterval(
                maximumUploadLeaseSeconds + maximumRelayClockSkewSeconds
              )
        else { throw MomentSharingError.invalidPayload }
        return expiresAt
    }

    static func boundedReportOnlyUntil(
        _ until: Date,
        receivedAt: Date
    ) throws -> Date {
        guard until > receivedAt.addingTimeInterval(-maximumRelayClockSkewSeconds)
        else { throw MomentSharingError.invalidPayload }
        return min(
            until,
            receivedAt.addingTimeInterval(
                maximumReportOnlyWindowSeconds + maximumRelayClockSkewSeconds
            )
        )
    }

    /// Treat the relay deadline as closed only after the explicit clock-skew
    /// allowance. Keeping the local safety/reporting gate slightly longer can
    /// never re-enable normal delivery: the durable handoff marker remains
    /// fail-closed throughout this interval.
    static func isReportOnlyWindowClosed(
        until: Date,
        now: Date = .now
    ) -> Bool {
        until.addingTimeInterval(maximumRelayClockSkewSeconds) <= now
    }
}

/// The private-window label is synchronized independently from photos. The
/// relay only sees this small opaque AEAD value and ordering metadata; the
/// plaintext display name is never a server field, log field, identifier, or
/// part of pairing authority.
enum PrivateWindowNameSyncProtocol {
    static let version = 1
    static let maximumCiphertextBytes = 512
    static let maximumClientRevision = 9_007_199_254_740_991

    static func isOpaqueIdentifier(_ value: String) -> Bool {
        guard (8...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45
                || $0 == 95
        }
    }
}

struct PrivateWindowNameCiphertextContext: Codable, Equatable, Sendable {
    var protocolVersion: Int = PrivateWindowNameSyncProtocol.version
    let spaceID: String
    let ownerMemberID: String
    let ownerRevision: Int
    let keyEpoch: Int

    func validated() throws -> Self {
        guard protocolVersion == PrivateWindowNameSyncProtocol.version,
              PrivateWindowNameSyncProtocol.isOpaqueIdentifier(spaceID),
              PrivateWindowNameSyncProtocol.isOpaqueIdentifier(ownerMemberID),
              (0...PrivateWindowNameSyncProtocol.maximumClientRevision)
                .contains(ownerRevision),
              keyEpoch >= 1
        else { throw MomentSharingError.invalidPayload }
        return self
    }

    fileprivate func canonicalFields() throws -> [String] {
        _ = try validated()
        return [
            "NW2.WINDOW-NAME-CIPHERTEXT",
            String(protocolVersion),
            spaceID,
            ownerMemberID,
            String(ownerRevision),
            String(keyEpoch)
        ]
    }
}

struct PrivateWindowNamePreparedPayload: Codable, Equatable, Sendable {
    let context: PrivateWindowNameCiphertextContext
    let ciphertext: Data
    let ciphertextSHA256: Data
    let ownerSignature: Data

    func validated() throws -> Self {
        _ = try context.validated()
        guard (29...PrivateWindowNameSyncProtocol.maximumCiphertextBytes)
            .contains(ciphertext.count),
              ciphertextSHA256.count == 32,
              ciphertextSHA256 == Data(SHA256.hash(data: ciphertext)),
              ownerSignature.count == 64
        else { throw MomentSharingError.invalidPayload }
        return self
    }
}

enum PrivateWindowNameCrypto {
    private static let plaintextByteCount = 1 + 8 + 2
        + PrivateWindowDisplayName.maximumUTF8ByteCount

    static func prepare(
        displayName rawDisplayName: String,
        context: PrivateWindowNameCiphertextContext,
        roomKey: Data,
        ownerSigningPrivateKey: Data
    ) throws -> PrivateWindowNamePreparedPayload {
        let context = try context.validated()
        let displayName = PrivateWindowDisplayName.normalized(rawDisplayName)
        guard roomKey.count == 32,
              ownerSigningPrivateKey.count == 32,
              PrivateWindowDisplayName.isValid(displayName),
              !displayName.isEmpty
        else { throw MomentSharingError.invalidPayload }
        let plaintext = try encodedPlaintext(
            displayName: displayName,
            ownerRevision: context.ownerRevision
        )
        let aad = try canonicalData(context.canonicalFields())
        let key = derivedKey(roomKey: roomKey, aad: aad)
        let ciphertext: Data
        do {
            ciphertext = try ChaChaPoly.seal(
                plaintext,
                using: key,
                authenticating: aad
            ).combined
        } catch {
            throw MomentSharingError.invalidPayload
        }
        let hash = Data(SHA256.hash(data: ciphertext))
        let signature: Data
        do {
            signature = try Curve25519.Signing.PrivateKey(
                rawRepresentation: ownerSigningPrivateKey
            ).signature(for: recordData(context: context, ciphertextSHA256: hash))
        } catch {
            throw MomentSharingError.invalidPayload
        }
        return try PrivateWindowNamePreparedPayload(
            context: context,
            ciphertext: ciphertext,
            ciphertextSHA256: hash,
            ownerSignature: signature
        ).validated()
    }

    static func open(
        _ payload: PrivateWindowNamePreparedPayload,
        roomKey: Data,
        ownerSigningPublicKey: Data
    ) throws -> String {
        let payload = try payload.validated()
        guard roomKey.count == 32,
              ownerSigningPublicKey.count == 32,
              (try? Curve25519.Signing.PublicKey(
                rawRepresentation: ownerSigningPublicKey
              ).isValidSignature(
                payload.ownerSignature,
                for: recordData(
                    context: payload.context,
                    ciphertextSHA256: payload.ciphertextSHA256
                )
              )) == true
        else { throw MomentSharingError.invalidPayload }
        let aad = try canonicalData(payload.context.canonicalFields())
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(
                ChaChaPoly.SealedBox(combined: payload.ciphertext),
                using: derivedKey(roomKey: roomKey, aad: aad),
                authenticating: aad
            )
        } catch {
            throw MomentSharingError.invalidPayload
        }
        let opened = try decodePlaintext(plaintext)
        guard opened.ownerRevision == payload.context.ownerRevision else {
            throw MomentSharingError.invalidPayload
        }
        return opened.displayName
    }

    private static func derivedKey(roomKey: Data, aad: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: roomKey),
            salt: Data(SHA256.hash(data: domainData("key-salt", root: aad))),
            info: Data("jp.nekowidget.private-window-name.v1".utf8),
            outputByteCount: 32
        )
    }

    static func recordData(
        context: PrivateWindowNameCiphertextContext,
        ciphertextSHA256: Data
    ) throws -> Data {
        _ = try context.validated()
        guard ciphertextSHA256.count == 32 else {
            throw MomentSharingError.invalidPayload
        }
        return try canonicalData([
            "NW2.WINDOW-NAME-RECORD",
            String(PrivateWindowNameSyncProtocol.version),
            context.spaceID,
            context.ownerMemberID,
            String(context.ownerRevision),
            String(context.keyEpoch),
            base64URLEncodedString(ciphertextSHA256)
        ])
    }

    /// A fixed 75-byte plaintext keeps the relay from learning the UTF-8 name
    /// length through ciphertext length. Unused bytes are random and are
    /// authenticated together with the explicit length.
    private static func encodedPlaintext(
        displayName: String,
        ownerRevision: Int
    ) throws -> Data {
        let name = Data(displayName.utf8)
        guard ownerRevision >= 0,
              name.count <= PrivateWindowDisplayName.maximumUTF8ByteCount
        else { throw MomentSharingError.invalidPayload }
        var value = Data([UInt8(PrivateWindowNameSyncProtocol.version)])
        var revision = UInt64(ownerRevision).bigEndian
        withUnsafeBytes(of: &revision) { value.append(contentsOf: $0) }
        var nameCount = UInt16(name.count).bigEndian
        withUnsafeBytes(of: &nameCount) { value.append(contentsOf: $0) }
        var generator = SystemRandomNumberGenerator()
        var padded = Data((0..<PrivateWindowDisplayName.maximumUTF8ByteCount).map { _ in
            UInt8.random(in: UInt8.min ... UInt8.max, using: &generator)
        })
        padded.replaceSubrange(0..<name.count, with: name)
        value.append(padded)
        guard value.count == plaintextByteCount else {
            throw MomentSharingError.invalidPayload
        }
        return value
    }

    private static func decodePlaintext(
        _ data: Data
    ) throws -> (ownerRevision: Int, displayName: String) {
        guard data.count == plaintextByteCount,
              data[data.startIndex] == UInt8(PrivateWindowNameSyncProtocol.version)
        else { throw MomentSharingError.invalidPayload }
        let bytes = [UInt8](data)
        let revisionValue = bytes[1..<9].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        guard revisionValue <= UInt64(Int.max) else {
            throw MomentSharingError.invalidPayload
        }
        let nameCount = bytes[9..<11].reduce(UInt16(0)) {
            ($0 << 8) | UInt16($1)
        }
        guard nameCount > 0,
              Int(nameCount) <= PrivateWindowDisplayName.maximumUTF8ByteCount
        else { throw MomentSharingError.invalidPayload }
        let nameBytes = Data(bytes[11..<(11 + Int(nameCount))])
        guard let displayName = String(data: nameBytes, encoding: .utf8),
              PrivateWindowDisplayName.isValid(displayName),
              displayName == PrivateWindowDisplayName.normalized(displayName)
        else { throw MomentSharingError.invalidPayload }
        return (Int(revisionValue), displayName)
    }

    private static func canonicalData(_ fields: [String]) throws -> Data {
        var value = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            guard bytes.count <= Int(UInt32.max) else {
                throw MomentSharingError.invalidPayload
            }
            var count = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { value.append(contentsOf: $0) }
            value.append(bytes)
        }
        return value
    }

    private static func domainData(_ domain: String, root: Data) -> Data {
        var value = Data(domain.utf8)
        value.append(0)
        value.append(root)
        return value
    }

    private static func base64URLEncodedString(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum MomentKind: String, Codable, CaseIterable, Sendable {
    case live
    case memory
    case bootstrap
}

enum MomentReportReason: String, Codable, CaseIterable, Sendable {
    case objectionable
    case harassment
    case privacy
    case other
}

enum MomentSharingError: LocalizedError, Equatable, Sendable {
    case featureDisabled
    case notPaired
    case consentRequired
    case moderationDisabled
    case moderationUnavailable
    case sensitiveContent
    case invalidPayload
    case payloadTooLarge
    case outboxFull
    case stateUnavailable
    case reportOnly(until: Date)
    case retryableServer(retryAfterSeconds: Int?)
    case requestRejected(status: Int, code: String?, message: String)

    var errorDescription: String? {
        switch self {
        case .featureDisabled:
            "写真を届けるまどはまだ利用できません。"
        case .notPaired:
            "先に非公開のまどを作るか、招待へ参加してください。"
        case .consentRequired:
            "まどの設定で写真共有の内容を確認してください。"
        case .moderationDisabled:
            "iPhoneの「センシティブな内容の警告」を利用できないため送信しません。設定を有効にしてからもう一度お試しください。"
        case .moderationUnavailable:
            "安全確認を完了できなかったため送信しません。時間をおいてもう一度お試しください。"
        case .sensitiveContent:
            "この写真は送信できません。別の写真を選んでください。"
        case .invalidPayload:
            "送信する写真を安全に準備できませんでした。"
        case .payloadTooLarge:
            "画質を保ったまま送信上限に収められませんでした。"
        case .outboxFull:
            "送信待ちが多いため追加できません。アプリのまどで再試行または取り消してください。"
        case .stateUnavailable:
            "送信状態を保存できませんでした。"
        case let .reportOnly(until):
            "このまどの共有は終了しました。\(until.formatted(.dateTime.month().day().hour().minute()))までは通報だけ利用できます。"
        case .retryableServer:
            "通信が完了しませんでした。あとで再試行します。"
        case let .requestRejected(_, _, message):
            message
        }
    }
}

/// Values known to the Server for one logical send. The ciphertext AAD binds
/// protocol, space, client moment, kind, key epoch, and participant. Device ID
/// stays outside AAD so a future device replacement can recover the same
/// participant's payload; `clientRequestID` is the stable reserve idempotency
/// key and is separately bound to the ciphertext descriptor by the Server.
struct MomentRequestContext: Codable, Equatable, Sendable {
    let spaceID: String
    let senderParticipantID: String
    let senderDeviceID: String
    let clientRequestID: UUID
    let clientMomentID: UUID
    let kind: MomentKind
    let keyEpoch: Int

    func validated() throws -> Self {
        guard Self.isOpaqueIdentifier(spaceID),
              Self.isOpaqueIdentifier(senderParticipantID),
              Self.isOpaqueIdentifier(senderDeviceID),
              keyEpoch >= 1
        else { throw MomentSharingError.invalidPayload }
        return self
    }

    fileprivate func ciphertextCanonicalFields() throws -> [String] {
        _ = try validated()
        return [
            "NW2.MOMENT-CIPHERTEXT",
            String(MomentSharingProtocol.version),
            spaceID,
            clientMomentID.uuidString.lowercased(),
            kind.rawValue,
            String(keyEpoch),
            senderParticipantID
        ]
    }

    private static func isOpaqueIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45 || $0 == 95
        }
    }
}

/// This entire value is encrypted. In particular, `capturedAt` must never be
/// copied into a Server row, object metadata, URL, or application log.
struct MomentEncryptedManifest: Codable, Equatable, Sendable {
    var protocolVersion: Int = MomentSharingProtocol.version
    let kind: MomentKind
    let capturedAt: Date?
    let captureDateIsMissing: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let plaintextSHA256: Data

    func validated() throws -> Self {
        guard protocolVersion == MomentSharingProtocol.version,
              captureDateIsMissing == (capturedAt == nil),
              (1...MomentSharingProtocol.maximumCanonicalPixelDimension).contains(pixelWidth),
              (1...MomentSharingProtocol.maximumCanonicalPixelDimension).contains(pixelHeight),
              plaintextSHA256.count == 32
        else { throw MomentSharingError.invalidPayload }
        return self
    }

    func encoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let value = try encoder.encode(self)
        guard value.count <= MomentSharingProtocol.maximumManifestCiphertextBytes - 28 else {
            throw MomentSharingError.payloadTooLarge
        }
        return value
    }

    static func decodeValidated(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(Self.self, from: data).validated()
        } catch let error as MomentSharingError {
            throw error
        } catch {
            throw MomentSharingError.invalidPayload
        }
    }
}

/// Ciphertexts are stored in the protected App Group outbox. This type is not
/// used by diagnostics or any JSON export offered to the user.
struct MomentPreparedPayload: Codable, Equatable, Sendable {
    var protocolVersion: Int = MomentSharingProtocol.version
    let context: MomentRequestContext
    let ciphertext: Data
    let ciphertextSHA256: Data
    let moderationVersion: Int

    func validated() throws -> Self {
        _ = try context.validated()
        guard protocolVersion == MomentSharingProtocol.version,
              (100...MomentSharingProtocol.maximumObjectCiphertextBytes)
                .contains(ciphertext.count),
              ciphertextSHA256 == Data(SHA256.hash(data: ciphertext)),
              moderationVersion == MomentSharingProtocol.moderationVersion
        else { throw MomentSharingError.invalidPayload }
        return self
    }
}

enum MomentCrypto {
    private struct CiphertextObject: Codable {
        let protocolVersion: Int
        let mediaCiphertext: Data
        let manifestCiphertext: Data
        let wrappedMediaKey: Data

        func encoded() throws -> Data {
            guard protocolVersion == MomentSharingProtocol.version,
                  (29...MomentSharingProtocol.maximumMediaCiphertextBytes)
                    .contains(mediaCiphertext.count),
                  (29...MomentSharingProtocol.maximumManifestCiphertextBytes)
                    .contains(manifestCiphertext.count),
                  (29...MomentSharingProtocol.maximumWrappedKeyBytes)
                    .contains(wrappedMediaKey.count)
            else { throw MomentSharingError.invalidPayload }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let value = try encoder.encode(self)
            guard value.count <= MomentSharingProtocol.maximumObjectCiphertextBytes else {
                throw MomentSharingError.payloadTooLarge
            }
            return value
        }

        static func decodeValidated(_ data: Data) throws -> Self {
            guard data.count <= MomentSharingProtocol.maximumObjectCiphertextBytes else {
                throw MomentSharingError.payloadTooLarge
            }
            do {
                let value = try PropertyListDecoder().decode(Self.self, from: data)
                _ = try value.encoded()
                return value
            } catch let error as MomentSharingError {
                throw error
            } catch {
                throw MomentSharingError.invalidPayload
            }
        }
    }

    static func prepare(
        canonicalJPEG: Data,
        capturedAt: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        context: MomentRequestContext,
        spaceGenerationKey: Data,
        moderationVersion: Int = MomentSharingProtocol.moderationVersion
    ) throws -> MomentPreparedPayload {
        _ = try context.validated()
        guard !canonicalJPEG.isEmpty,
              canonicalJPEG.count <= MomentSharingProtocol.maximumMediaCiphertextBytes - 28,
              spaceGenerationKey.count == 32,
              moderationVersion == MomentSharingProtocol.moderationVersion
        else { throw MomentSharingError.invalidPayload }

        let mediaKey = SymmetricKey(size: .bits256)
        let rootAAD = try canonicalData(context.ciphertextCanonicalFields())
        let mediaAAD = domainAAD("media", root: rootAAD)
        let manifestAAD = domainAAD("manifest", root: rootAAD)
        let keyAAD = domainAAD("media-key", root: rootAAD)
        let mediaCiphertext = try seal(canonicalJPEG, key: mediaKey, aad: mediaAAD)

        let manifest = MomentEncryptedManifest(
            kind: context.kind,
            capturedAt: capturedAt,
            captureDateIsMissing: capturedAt == nil,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            plaintextSHA256: Data(SHA256.hash(data: canonicalJPEG))
        )
        let manifestCiphertext = try seal(
            try manifest.encoded(),
            key: mediaKey,
            aad: manifestAAD
        )
        let wrappingKey = try derivedWrappingKey(
            spaceGenerationKey: spaceGenerationKey,
            context: context
        )
        let wrappedMediaKey = try seal(
            mediaKey.withUnsafeBytes { Data($0) },
            key: wrappingKey,
            aad: keyAAD
        )

        let ciphertext = try CiphertextObject(
            protocolVersion: MomentSharingProtocol.version,
            mediaCiphertext: mediaCiphertext,
            manifestCiphertext: manifestCiphertext,
            wrappedMediaKey: wrappedMediaKey
        ).encoded()

        return try MomentPreparedPayload(
            context: context,
            ciphertext: ciphertext,
            ciphertextSHA256: Data(SHA256.hash(data: ciphertext)),
            moderationVersion: moderationVersion
        ).validated()
    }

    static func open(
        _ payload: MomentPreparedPayload,
        spaceGenerationKey: Data
    ) throws -> (jpeg: Data, manifest: MomentEncryptedManifest) {
        let payload = try payload.validated()
        guard spaceGenerationKey.count == 32 else {
            throw MomentSharingError.invalidPayload
        }
        let context = payload.context
        let object = try CiphertextObject.decodeValidated(payload.ciphertext)
        let wrappingKey = try derivedWrappingKey(
            spaceGenerationKey: spaceGenerationKey,
            context: context
        )
        let rootAAD = try canonicalData(context.ciphertextCanonicalFields())
        let keyAAD = domainAAD("media-key", root: rootAAD)
        let mediaKeyData = try open(object.wrappedMediaKey, key: wrappingKey, aad: keyAAD)
        guard mediaKeyData.count == 32 else { throw MomentSharingError.invalidPayload }
        let mediaKey = SymmetricKey(data: mediaKeyData)
        let mediaAAD = domainAAD("media", root: rootAAD)
        let manifestAAD = domainAAD("manifest", root: rootAAD)
        let jpeg = try open(object.mediaCiphertext, key: mediaKey, aad: mediaAAD)
        let manifestData = try open(
            object.manifestCiphertext,
            key: mediaKey,
            aad: manifestAAD
        )
        let manifest = try MomentEncryptedManifest.decodeValidated(manifestData)
        guard manifest.kind == context.kind,
              manifest.plaintextSHA256 == Data(SHA256.hash(data: jpeg))
        else { throw MomentSharingError.invalidPayload }
        return (jpeg, manifest)
    }

    private static func derivedWrappingKey(
        spaceGenerationKey: Data,
        context: MomentRequestContext
    ) throws -> SymmetricKey {
        let rootAAD = try canonicalData(context.ciphertextCanonicalFields())
        let salt = Data(SHA256.hash(data: domainAAD("key-salt", root: rootAAD)))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: spaceGenerationKey),
            salt: salt,
            info: Data("jp.nekowidget.moment.media-key.v1".utf8),
            outputByteCount: 32
        )
    }

    private static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        do {
            return try ChaChaPoly.seal(
                plaintext,
                using: key,
                authenticating: aad
            ).combined
        } catch let error as MomentSharingError {
            throw error
        } catch {
            throw MomentSharingError.invalidPayload
        }
    }

    private static func open(_ ciphertext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        do {
            return try ChaChaPoly.open(
                ChaChaPoly.SealedBox(combined: ciphertext),
                using: key,
                authenticating: aad
            )
        } catch {
            throw MomentSharingError.invalidPayload
        }
    }

    private static func canonicalData(_ fields: [String]) throws -> Data {
        var value = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            guard bytes.count <= Int(UInt32.max) else {
                throw MomentSharingError.invalidPayload
            }
            var count = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { value.append(contentsOf: $0) }
            value.append(bytes)
        }
        return value
    }

    private static func domainAAD(_ domain: String, root: Data) -> Data {
        var value = Data(domain.utf8)
        value.append(0)
        value.append(root)
        return value
    }
}

struct MomentPreparedReport: Equatable, Sendable {
    let ciphertext: Data
    let ciphertextSHA256: Data
    let moderationKeyID: String
}

/// Produces a separate, short-lived report copy for the moderation public key.
/// The family room key and the Worker cannot decrypt this envelope.
enum MomentReportCrypto {
    private struct Plaintext: Codable {
        var protocolVersion: Int = MomentSharingProtocol.version
        let momentID: String
        let reporterParticipantID: String
        let reason: MomentReportReason
        let capturedAt: Date?
        let reportedAt: Date
        let canonicalJPEG: Data
    }

    private struct Envelope: Codable {
        var protocolVersion: Int = MomentSharingProtocol.version
        let moderationKeyID: String
        let ephemeralPublicKey: Data
        let ciphertext: Data
    }

    static func prepare(
        canonicalJPEG: Data,
        momentID: String,
        reporterParticipantID: String,
        reason: MomentReportReason,
        capturedAt: Date?,
        reportedAt: Date,
        moderationKeyID: String,
        moderationPublicKey: Data
    ) throws -> MomentPreparedReport {
        guard !canonicalJPEG.isEmpty,
              canonicalJPEG.count <= MomentSharingProtocol.maximumMediaCiphertextBytes - 28,
              isOpaqueIdentifier(momentID),
              isOpaqueIdentifier(reporterParticipantID),
              moderationKeyID == "moderation-v1",
              moderationPublicKey.count == 32
        else { throw MomentSharingError.invalidPayload }

        let recipient = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: moderationPublicKey
        )
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let aad = try canonicalData([
            "NW2.MODERATION-REPORT",
            String(MomentSharingProtocol.version),
            momentID,
            reporterParticipantID,
            reason.rawValue,
            moderationKeyID
        ])
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(SHA256.hash(data: aad)),
            sharedInfo: Data("jp.nekowidget.moment.report.v1".utf8),
            outputByteCount: 32
        )
        let plaintextEncoder = PropertyListEncoder()
        plaintextEncoder.outputFormat = .binary
        let plaintext = try plaintextEncoder.encode(Plaintext(
            momentID: momentID,
            reporterParticipantID: reporterParticipantID,
            reason: reason,
            capturedAt: capturedAt,
            reportedAt: reportedAt,
            canonicalJPEG: canonicalJPEG
        ))
        let sealed = try ChaChaPoly.seal(plaintext, using: key, authenticating: aad).combined
        let envelopeEncoder = PropertyListEncoder()
        envelopeEncoder.outputFormat = .binary
        let envelope = try envelopeEncoder.encode(Envelope(
            moderationKeyID: moderationKeyID,
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            ciphertext: sealed
        ))
        guard envelope.count <= MomentSharingProtocol.maximumObjectCiphertextBytes else {
            throw MomentSharingError.payloadTooLarge
        }
        return MomentPreparedReport(
            ciphertext: envelope,
            ciphertextSHA256: Data(SHA256.hash(data: envelope)),
            moderationKeyID: moderationKeyID
        )
    }

    private static func isOpaqueIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45 || $0 == 95
        }
    }

    private static func canonicalData(_ fields: [String]) throws -> Data {
        var value = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            guard bytes.count <= Int(UInt32.max) else {
                throw MomentSharingError.invalidPayload
            }
            var count = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { value.append(contentsOf: $0) }
            value.append(bytes)
        }
        return value
    }
}
