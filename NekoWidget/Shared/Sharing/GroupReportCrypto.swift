import CryptoKit
import Foundation

enum GroupReportCryptoError: Error {
    case invalidInput
    case untrustedModerationKey
    case invalidCanonicalJPEG
    case payloadTooLarge
}

/// A separate copy of exactly one selected canonical JPEG for the reviewed
/// moderation key. Group keys, original image metadata and free text are not
/// inputs. Persist the returned envelope before sending; retries reuse it.
enum GroupReportCrypto {
    static let maximumCanonicalJPEGBytes = 950_244
    static let maximumEnvelopeBytes = 1_048_576
    static let moderationKeyID = "moderation-v2"
    // The same reviewed public key as SharingAPIConfiguration. A rotation needs
    // a reviewed app release; a remotely supplied key is never sufficient.
    static let moderationPublicKey = Data(base64Encoded:
        "T5C7//1xlc4XmIDr6zTJqMtdhBjPnMD10O3vFK/bYWg="
    )!

    private struct Plaintext: Encodable {
        let protocolVersion = 3
        let windowID: String
        let momentID: String
        let reporterParticipantID: String
        let reason: String
        let reportedAt: Date
        let canonicalJPEG: Data
        // capturedAt is deliberately absent, not a plist null or a string.
    }

    private struct Envelope: Encodable {
        let protocolVersion = 3
        let moderationKeyID: String
        let ephemeralPublicKey: Data
        let ciphertext: Data
    }

    static func encrypt(
        canonicalJPEG: Data,
        windowID: String,
        momentID: String,
        reporterParticipantID: String,
        reasonCode: String,
        keyID: String,
        publicKey: Data
    ) throws -> Data {
        guard keyID == moderationKeyID, publicKey == moderationPublicKey else {
            throw GroupReportCryptoError.untrustedModerationKey
        }
        return try encryptEnvelope(
            canonicalJPEG: canonicalJPEG, windowID: windowID, momentID: momentID,
            reporterParticipantID: reporterParticipantID, reasonCode: reasonCode,
            keyID: keyID, publicKey: publicKey, reportedAt: Date()
        )
    }

    private static func encryptEnvelope(
        canonicalJPEG: Data,
        windowID: String,
        momentID: String,
        reporterParticipantID: String,
        reasonCode: String,
        keyID: String,
        publicKey: Data,
        reportedAt: Date
    ) throws -> Data {
        guard keyID == moderationKeyID, publicKey.count == 32,
              [windowID, momentID, reporterParticipantID].allSatisfy(isCanonicalID),
              ["objectionable", "harassment", "privacy", "other"].contains(reasonCode),
              reportedAt.timeIntervalSinceReferenceDate.isFinite
        else { throw GroupReportCryptoError.invalidInput }
        try validateCanonicalJPEG(canonicalJPEG)

        let aad = authenticatedData([
            "NW3.MODERATION-REPORT", "3", windowID, momentID,
            reporterParticipantID, reasonCode, keyID
        ])
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(SHA256.hash(data: aad)),
            sharedInfo: Data("jp.nekowidget.moment.report.v1".utf8),
            outputByteCount: 32
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        var plaintext = try encoder.encode(Plaintext(
            windowID: windowID, momentID: momentID,
            reporterParticipantID: reporterParticipantID, reason: reasonCode,
            reportedAt: reportedAt, canonicalJPEG: canonicalJPEG
        ))
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let combined = try ChaChaPoly.seal(plaintext, using: key, authenticating: aad).combined
        let envelope = try encoder.encode(Envelope(
            moderationKeyID: keyID,
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            ciphertext: combined
        ))
        guard envelope.count <= maximumEnvelopeBytes else {
            throw GroupReportCryptoError.payloadTooLarge
        }
        return envelope
    }

    private static func isCanonicalID(_ value: String) -> Bool {
        guard value.utf8.count == 22, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 95
        }), let decoded = Data(base64Encoded:
            value.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "=="
        ), decoded.count == 16 else { return false }
        return decoded.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") == value
    }

    /// NW3 reports retain the report format's four-byte lengths. Ordinary
    /// GroupCanonical uses two-byte lengths and must not be used here.
    private static func authenticatedData(_ fields: [String]) -> Data {
        var result = Data()
        for field in fields {
            let bytes = Data(field.utf8) // All callers have already bounded fields.
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(bytes)
        }
        return result
    }

    /// Mirrors the operator's bounded marker validator. Image decoding and
    /// normalization remain MomentCanonicalPreviewBuilder's responsibility.
    private static func validateCanonicalJPEG(_ jpeg: Data) throws {
        guard (4...maximumCanonicalJPEGBytes).contains(jpeg.count) else {
            throw GroupReportCryptoError.invalidCanonicalJPEG
        }
        let bytes = [UInt8](jpeg)
        guard bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw GroupReportCryptoError.invalidCanonicalJPEG
        }
        let sof: Set<UInt8> = [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                              0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
        var cursor = 2
        var entropy = false
        var sawScan = false
        var sawFrame = false
        while cursor < bytes.count {
            if entropy {
                if bytes[cursor] != 0xFF { cursor += 1; continue }
                let markerStart = cursor
                while cursor < bytes.count, bytes[cursor] == 0xFF { cursor += 1 }
                guard cursor < bytes.count else { break }
                let marker = bytes[cursor]
                if marker == 0 || (0xD0...0xD7).contains(marker) {
                    cursor += 1
                    continue
                }
                cursor = markerStart
                entropy = false
                continue
            }
            guard bytes[cursor] == 0xFF else { break }
            while cursor < bytes.count, bytes[cursor] == 0xFF { cursor += 1 }
            guard cursor < bytes.count else { break }
            let marker = bytes[cursor]
            cursor += 1
            if marker == 0xD9 {
                guard sawScan, sawFrame, cursor == bytes.count else { break }
                return
            }
            guard marker != 0, marker != 0xD8,
                  !(0xD0...0xD7).contains(marker) else { break }
            if marker == 0x01 { continue }
            guard cursor <= bytes.count - 2 else { break }
            let length = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
            guard length >= 2, length <= bytes.count - cursor,
                  !(0xE0...0xEF).contains(marker), marker != 0xFE else { break }
            if sof.contains(marker) {
                guard !sawFrame, length >= 8 else { break }
                let precision = bytes[cursor + 2]
                let height = (Int(bytes[cursor + 3]) << 8) | Int(bytes[cursor + 4])
                let width = (Int(bytes[cursor + 5]) << 8) | Int(bytes[cursor + 6])
                let components = Int(bytes[cursor + 7])
                guard length == 8 + components * 3, precision == 8, components == 3,
                      (1...2048).contains(width), (1...2048).contains(height) else { break }
                sawFrame = true
            }
            cursor += length
            if marker == 0xDA {
                guard sawFrame else { break }
                sawScan = true
                entropy = true
            }
        }
        throw GroupReportCryptoError.invalidCanonicalJPEG
    }

#if GROUP_REPORT_CRYPTO_CHECKS
    // This seam is compiled only into the standalone interop executable, never
    // an app build. It uses an existing public TEST seed's recipient public key.
    static func encryptForInteroperability(
        canonicalJPEG: Data,
        windowID: String,
        momentID: String,
        reporterParticipantID: String,
        reasonCode: String,
        publicKey: Data,
        reportedAt: Date
    ) throws -> Data {
        try encryptEnvelope(
            canonicalJPEG: canonicalJPEG, windowID: windowID, momentID: momentID,
            reporterParticipantID: reporterParticipantID, reasonCode: reasonCode,
            keyID: moderationKeyID, publicKey: publicKey, reportedAt: reportedAt
        )
    }
#endif
}
