import Foundation

private struct MediaFields: Decodable {
    let spaceId: String
    let sourceId: String
    let publisherMemberId: String
    let generationId: String
    let shareDayKey: Int
    let mediaId: String
    let mediaBindingHash: String
}

private struct ManifestFields: Decodable {
    let spaceId: String
    let sourceId: String
    let publisherMemberId: String
    let generationId: String
    let shareDayKey: Int
    let prepareAttemptId: String
    let prepareAttemptRevision: Int
    let reservedRevision: Int
    let rotationAnchorUTC: Int
    let itemCount: Int
}

private struct Vector<Fields: Decodable>: Decodable {
    let fields: Fields
    let canonicalBase64url: String
    let sha256: String
}

private struct Fixture: Decodable {
    let protocolVersion: Int
    let media: Vector<MediaFields>
    let manifest: Vector<ManifestFields>
}

private enum VectorError: Error, CustomStringConvertible {
    case mismatch(String)

    var description: String {
        switch self {
        case let .mismatch(message): message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VectorError.mismatch(message) }
}

private func verify(
    _ data: Data,
    canonicalBase64URL: String,
    sha256: String,
    label: String
) throws {
    try require(
        data.base64URLEncodedString() == canonicalBase64URL,
        "\(label) canonical bytes differ"
    )
    try require(
        PairingCrypto.sha256(data).base64URLEncodedString() == sha256,
        "\(label) SHA-256 differs"
    )
}

private func requireThrows(
    _ message: String,
    _ operation: () throws -> Void
) throws {
    do {
        try operation()
        throw VectorError.mismatch(message)
    } catch is VectorError {
        throw VectorError.mismatch(message)
    } catch {
        // Expected: CryptoKit authentication or the protocol's validation gate
        // rejected ciphertext whose authenticated context did not match.
    }
}

@main
private struct SharingProtocolVectorVerifier {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw VectorError.mismatch("Expected one fixture path argument")
        }
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        )
        try require(
            fixture.protocolVersion == DailySharingProtocol.version,
            "Unsupported fixture protocol version"
        )

        let media = fixture.media.fields
        guard let bindingHash = Data(base64URLString: media.mediaBindingHash) else {
            throw VectorError.mismatch("media binding hash is not canonical base64url")
        }
        let mediaAAD = try DailySharingCrypto.mediaAAD(
            spaceID: media.spaceId,
            sourceID: media.sourceId,
            publisherMemberID: media.publisherMemberId,
            generationID: media.generationId,
            shareDayKey: media.shareDayKey,
            mediaID: media.mediaId,
            mediaBindingHash: bindingHash
        )
        try verify(
            mediaAAD,
            canonicalBase64URL: fixture.media.canonicalBase64url,
            sha256: fixture.media.sha256,
            label: "shared media AAD"
        )

        let manifest = fixture.manifest.fields
        let manifestAAD = try DailySharingCrypto.manifestAAD(
            spaceID: manifest.spaceId,
            sourceID: manifest.sourceId,
            publisherMemberID: manifest.publisherMemberId,
            generationID: manifest.generationId,
            shareDayKey: manifest.shareDayKey,
            prepareAttemptID: manifest.prepareAttemptId,
            prepareAttemptRevision: manifest.prepareAttemptRevision,
            reservedRevision: manifest.reservedRevision,
            rotationAnchorUTC: manifest.rotationAnchorUTC,
            itemCount: manifest.itemCount
        )
        try verify(
            manifestAAD,
            canonicalBase64URL: fixture.manifest.canonicalBase64url,
            sha256: fixture.manifest.sha256,
            label: "shared manifest AAD"
        )

        // Exercise the production HKDF/domain-separation/AEAD implementation in
        // addition to comparing canonical bytes with TypeScript. ChaCha uses a
        // random nonce, so this is intentionally a round-trip/tamper gate rather
        // than a fixed-ciphertext golden vector.
        let roomKey = Data((0..<32).map { UInt8($0) })
        let mediaPlaintext = Data("metadata-free canonical fixture".utf8)
        let mediaCiphertext = try DailySharingCrypto.sealMedia(
            mediaPlaintext,
            roomKey: roomKey,
            aad: mediaAAD
        )
        try require(
            try DailySharingCrypto.openMedia(
                mediaCiphertext,
                roomKey: roomKey,
                aad: mediaAAD
            ) == mediaPlaintext,
            "shared media AEAD round-trip differs"
        )
        var tamperedMedia = mediaCiphertext
        tamperedMedia[tamperedMedia.startIndex] ^= 0x01
        try requireThrows("tampered shared media ciphertext was accepted") {
            _ = try DailySharingCrypto.openMedia(
                tamperedMedia,
                roomKey: roomKey,
                aad: mediaAAD
            )
        }
        var wrongMediaAAD = mediaAAD
        wrongMediaAAD[wrongMediaAAD.index(before: wrongMediaAAD.endIndex)] ^= 0x01
        try requireThrows("shared media ciphertext accepted the wrong AAD") {
            _ = try DailySharingCrypto.openMedia(
                mediaCiphertext,
                roomKey: roomKey,
                aad: wrongMediaAAD
            )
        }

        let manifestPlaintext = Data("encrypted render plan fixture".utf8)
        let manifestCiphertext = try DailySharingCrypto.sealManifest(
            manifestPlaintext,
            roomKey: roomKey,
            aad: manifestAAD
        )
        try require(
            try DailySharingCrypto.openManifest(
                manifestCiphertext,
                roomKey: roomKey,
                aad: manifestAAD
            ) == manifestPlaintext,
            "shared manifest AEAD round-trip differs"
        )
        try requireThrows("media and manifest key domains were not separated") {
            let crossDomain = try DailySharingCrypto.sealMedia(
                manifestPlaintext,
                roomKey: roomKey,
                aad: manifestAAD
            )
            _ = try DailySharingCrypto.openManifest(
                crossDomain,
                roomKey: roomKey,
                aad: manifestAAD
            )
        }

        print("Sharing protocol v1 Swift vectors: PASS")
    }
}
