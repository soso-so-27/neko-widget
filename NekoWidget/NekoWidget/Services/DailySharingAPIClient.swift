import CryptoKit
import Foundation

struct SharingReserveResult: Sendable {
    let sourceID: String
    let publisherMemberID: String
    let generationID: String
    let shareDayKey: Int
    let createdAt: Int
    let expiresAt: Int
    let mediaIDs: [String]
}

struct SharingPrepareResult: Sendable {
    let generationID: String
    let attemptID: String
    let attemptRevision: Int
    let reservedRevision: Int
    let rotationAnchorUTC: Int
    let prepareExpiresAt: Int
}

struct SharingCommitResult: Sendable {
    let sourceID: String
    let generationID: String
    let shareDayKey: Int
    let revision: Int
    let attemptID: String
    let attemptRevision: Int
    let reservedRevision: Int
    let rotationAnchorUTC: Int
}

struct SharingGenerationResume: Sendable {
    struct Media: Sendable {
        let mediaID: String
        let ciphertextSize: Int?
        let ciphertextSHA256: String?
        let state: String
    }
    let sourceID: String
    let publisherMemberID: String
    let generationID: String
    let state: String
    let shareDayKey: Int
    let itemCount: Int
    let createdAt: Int
    let expiresAt: Int
    let attemptID: String?
    let attemptRevision: Int?
    let reservedRevision: Int?
    let rotationAnchorUTC: Int?
    let prepareExpiresAt: Int?
    let manifest: SharingCurrentGeneration.ObjectDescriptor?
    let media: [Media]
}

struct SharingSourceSummary: Sendable {
    struct Current: Sendable {
        let generationID: String
        let shareDayKey: Int
        let revision: Int
        let rotationAnchorUTC: Int
        let uniqueMediaCount: Int
    }
    let sourceID: String
    let publisherMemberID: String
    let current: Current?
}

struct SharingCurrentGeneration: Sendable {
    struct ObjectDescriptor: Sendable {
        let ciphertextSize: Int
        let ciphertextSHA256: String
    }
    struct MediaDescriptor: Sendable {
        let mediaID: String
        let ciphertextSize: Int
        let ciphertextSHA256: String
    }
    let sourceID: String
    let publisherMemberID: String
    let generationID: String
    let shareDayKey: Int
    let revision: Int
    let attemptID: String
    let attemptRevision: Int
    let reservedRevision: Int
    let rotationAnchorUTC: Int
    let uniqueMediaCount: Int
    let manifest: ObjectDescriptor
    let media: [MediaDescriptor]
}

enum SharingCurrentFetch: Sendable {
    case notModified
    case current(SharingCurrentGeneration, eTag: String?)
}

protocol DailySharingAPIClientProtocol: Sendable {
    func reserveGeneration(
        mediaIDs: [String],
        clientRequestID: UUID,
        memberID: String,
        credential: PairingCredential
    ) async throws -> SharingReserveResult

    func freezeDescriptors(
        generationID: String,
        media: [StagedSharingMedia],
        clientRequestID: UUID,
        memberID: String,
        credential: PairingCredential
    ) async throws

    func uploadMedia(
        generationID: String,
        mediaID: String,
        ciphertext: Data,
        expectedSHA256: String,
        memberID: String,
        credential: PairingCredential
    ) async throws

    func prepare(
        generationID: String,
        clientRequestID: UUID,
        memberID: String,
        credential: PairingCredential
    ) async throws -> SharingPrepareResult

    func uploadManifest(
        generationID: String,
        attemptID: String,
        ciphertext: Data,
        expectedSHA256: String,
        memberID: String,
        credential: PairingCredential
    ) async throws

    func commit(
        generationID: String,
        expectedSourceID: String,
        expectedShareDayKey: Int,
        prepare: PreparedSharingAttempt,
        memberID: String,
        credential: PairingCredential
    ) async throws -> SharingCommitResult

    func generation(
        generationID: String,
        expectedPublisherMemberID: String,
        memberID: String,
        credential: PairingCredential
    ) async throws -> SharingGenerationResume

    func listSources(
        expectedPublisherMemberIDs: Set<String>,
        memberID: String,
        credential: PairingCredential
    ) async throws -> [SharingSourceSummary]

    func current(
        sourceID: String,
        eTag: String?,
        memberID: String,
        credential: PairingCredential
    ) async throws -> SharingCurrentFetch

    func downloadManifest(
        current: SharingCurrentGeneration,
        memberID: String,
        credential: PairingCredential
    ) async throws -> Data

    func downloadMedia(
        current: SharingCurrentGeneration,
        descriptor: SharingCurrentGeneration.MediaDescriptor,
        memberID: String,
        credential: PairingCredential
    ) async throws -> Data
}

actor URLSessionDailySharingAPIClient: DailySharingAPIClientProtocol {
    private let baseURL: URL
    private let transport: SharingBoundedURLSessionTransport
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(configuration: SharingAPIConfiguration) throws {
        guard configuration.isMediaAvailable, let baseURL = configuration.baseURL else {
            throw PairingError.apiNotConfigured
        }
        self.baseURL = baseURL
        transport = SharingBoundedURLSessionTransport()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func reserveGeneration(
        mediaIDs: [String],
        clientRequestID: UUID,
        memberID: String,
        credential: PairingCredential
    ) async throws -> SharingReserveResult {
        guard Self.validSortedUniqueMediaIDs(mediaIDs) else {
            throw DailySharingError.invalidLocalManifest
        }
        let response: ReserveResponse = try await sendJSON(
            path: "/v1/sharing/generations/reserve",
            method: "POST",
            body: ReserveRequest(
                protocolVersion: DailySharingProtocol.version,
                clientRequestId: clientRequestID.uuidString.lowercased(),
                items: mediaIDs.map(ReserveRequest.Item.init(mediaId:))
            ),
            memberID: memberID,
            credential: credential
        )
        guard response.protocolVersion == DailySharingProtocol.version,
              response.source.publisherMemberId == memberID,
              Self.isIdentifier(response.source.id),
              Self.isIdentifier(response.generation.id),
              response.generation.state == "reserved",
              (0...10_000_000).contains(response.generation.shareDayKey),
              response.generation.itemCount == mediaIDs.count,
              response.generation.createdAt > 0,
              response.generation.expiresAt > response.generation.createdAt,
              response.generation.expiresAt <= response.generation.createdAt + 60 * 60,
              response.items.map(\.mediaId) == mediaIDs,
              response.items.allSatisfy({ $0.state == "reserved" })
        else { throw PairingError.invalidServerResponse }
        return SharingReserveResult(
            sourceID: response.source.id,
            publisherMemberID: response.source.publisherMemberId,
            generationID: response.generation.id,
            shareDayKey: response.generation.shareDayKey,
            createdAt: response.generation.createdAt,
            expiresAt: response.generation.expiresAt,
            mediaIDs: mediaIDs
        )
    }

    func freezeDescriptors(
        generationID: String,
        media: [StagedSharingMedia],
        clientRequestID: UUID,
        memberID: String,
        credential: PairingCredential
    ) async throws {
        guard Self.isIdentifier(generationID),
              media.map(\.frozen.mediaID) == media.map(\.frozen.mediaID).sorted(),
              media.allSatisfy({
                  $0.ciphertextSize != nil && $0.ciphertextSHA256 != nil
              })
        else { throw DailySharingError.stateUnavailable }
        let requestItems = try media.map { item -> DescriptorRequest.Item in
            guard let size = item.ciphertextSize,
                  let hash = item.ciphertextSHA256
            else { throw DailySharingError.stateUnavailable }
            return DescriptorRequest.Item(
                mediaId: item.frozen.mediaID,
                ciphertextSize: size,
                ciphertextSHA256: hash
            )
        }
        let response: DescriptorResponse = try await sendJSON(
            path: "/v1/sharing/generations/\(generationID)/descriptors",
            method: "POST",
            body: DescriptorRequest(
                protocolVersion: DailySharingProtocol.version,
                clientRequestId: clientRequestID.uuidString.lowercased(),
                items: requestItems
            ),
            memberID: memberID,
            credential: credential
        )
        guard response.protocolVersion == DailySharingProtocol.version,
              response.generationId == generationID,
              response.state == "uploading",
              response.items.count == requestItems.count
        else { throw PairingError.invalidServerResponse }
        for (expected, actual) in zip(requestItems, response.items) {
            guard actual.mediaId == expected.mediaId,
                  actual.ciphertextSize == expected.ciphertextSize,
                  actual.ciphertextSHA256 == expected.ciphertextSHA256,
                  actual.state == "expected"
            else { throw PairingError.invalidServerResponse }
        }
    }

    func uploadMedia(
        generationID: String,
        mediaID: String,
        ciphertext: Data,
        expectedSHA256: String,
        memberID: String,
        credential: PairingCredential
    ) async throws {
        guard Self.isIdentifier(generationID), Self.isIdentifier(mediaID),
              ciphertext.count <= DailySharingProtocol.maximumMediaCiphertextBytes,
              PairingCrypto.sha256(ciphertext).base64URLEncodedString() == expectedSHA256
        else { throw DailySharingError.stateUnavailable }
        let path = "/v1/sharing/generations/\(generationID)/media/\(mediaID)"
        let (data, response) = try await sendRaw(
            path: path,
            method: "PUT",
            body: ciphertext,
            contentType: "application/octet-stream",
            memberID: memberID,
            credential: credential,
            maximumResponseBytes: 65_536
        )
        let value: MediaVerifiedResponse = try decode(data)
        guard response.statusCode == 200,
              value.protocolVersion == DailySharingProtocol.version,
              value.generationId == generationID,
              value.mediaId == mediaID,
              value.ciphertextSize == ciphertext.count,
              value.ciphertextSHA256 == expectedSHA256,
              value.state == "verified"
        else { throw PairingError.invalidServerResponse }
    }

    func prepare(
        generationID: String,
        clientRequestID: UUID,
        memberID: String,
        credential: PairingCredential
    ) async throws -> SharingPrepareResult {
        guard Self.isIdentifier(generationID) else { throw DailySharingError.stateUnavailable }
        let response: PrepareResponse = try await sendJSON(
            path: "/v1/sharing/generations/\(generationID)/prepare",
            method: "POST",
            body: OperationRequest(
                protocolVersion: DailySharingProtocol.version,
                clientRequestId: clientRequestID.uuidString.lowercased()
            ),
            memberID: memberID,
            credential: credential
        )
        guard response.protocolVersion == DailySharingProtocol.version,
              response.generationId == generationID,
              response.state == "prepared",
              Self.isIdentifier(response.prepareAttemptId),
              response.prepareAttemptRevision > 0,
              response.reservedRevision > 0,
              response.rotationAnchorUTC > 0,
              response.rotationAnchorUTC.isMultiple(of: 1_200),
              response.prepareExpiresAt == response.rotationAnchorUTC
        else { throw PairingError.invalidServerResponse }
        return SharingPrepareResult(
            generationID: generationID,
            attemptID: response.prepareAttemptId,
            attemptRevision: response.prepareAttemptRevision,
            reservedRevision: response.reservedRevision,
            rotationAnchorUTC: response.rotationAnchorUTC,
            prepareExpiresAt: response.prepareExpiresAt
        )
    }

    func uploadManifest(
        generationID: String,
        attemptID: String,
        ciphertext: Data,
        expectedSHA256: String,
        memberID: String,
        credential: PairingCredential
    ) async throws {
        guard Self.isIdentifier(generationID), Self.isIdentifier(attemptID),
              ciphertext.count <= DailySharingProtocol.maximumManifestCiphertextBytes,
              PairingCrypto.sha256(ciphertext).base64URLEncodedString() == expectedSHA256
        else { throw DailySharingError.stateUnavailable }
        let path = "/v1/sharing/generations/\(generationID)/prepares/\(attemptID)/manifest"
        let (data, response) = try await sendRaw(
            path: path,
            method: "PUT",
            body: ciphertext,
            contentType: "application/octet-stream",
            memberID: memberID,
            credential: credential,
            maximumResponseBytes: 65_536
        )
        let value: ManifestVerifiedResponse = try decode(data)
        guard response.statusCode == 200,
              value.protocolVersion == DailySharingProtocol.version,
              value.generationId == generationID,
              value.prepareAttemptId == attemptID,
              value.ciphertextSize == ciphertext.count,
              value.ciphertextSHA256 == expectedSHA256,
              value.state == "verified"
        else { throw PairingError.invalidServerResponse }
    }

    func commit(
        generationID: String,
        expectedSourceID: String,
        expectedShareDayKey: Int,
        prepare: PreparedSharingAttempt,
        memberID: String,
        credential: PairingCredential
    ) async throws -> SharingCommitResult {
        guard Self.isIdentifier(generationID),
              Self.isIdentifier(expectedSourceID),
              (0...10_000_000).contains(expectedShareDayKey)
        else { throw DailySharingError.stateUnavailable }
        let prepare = try prepare.validated()
        guard let hash = prepare.manifestCiphertextSHA256,
              let requestID = prepare.commitClientRequestID.flatMap(UUID.init(uuidString:))
        else { throw DailySharingError.stateUnavailable }
        let response: CommitResponse = try await sendJSON(
            path: "/v1/sharing/generations/\(generationID)/commit",
            method: "POST",
            body: CommitRequest(
                protocolVersion: DailySharingProtocol.version,
                clientRequestId: requestID.uuidString.lowercased(),
                prepareAttemptId: prepare.attemptID,
                prepareAttemptRevision: prepare.attemptRevision,
                reservedRevision: prepare.reservedRevision,
                manifestCiphertextSHA256: hash
            ),
            memberID: memberID,
            credential: credential
        )
        guard response.protocolVersion == DailySharingProtocol.version,
              Self.isIdentifier(response.sourceId),
              Self.isIdentifier(response.generationId),
              response.sourceId == expectedSourceID,
              response.generationId == generationID,
              response.state == "current",
              response.prepareAttemptId == prepare.attemptID,
              response.prepareAttemptRevision == prepare.attemptRevision,
              response.reservedRevision == prepare.reservedRevision,
              response.revision == prepare.reservedRevision,
              response.rotationAnchorUTC == prepare.rotationAnchorUTC,
              response.rotationAnchorUTC.isMultiple(of: 1_200),
              response.shareDayKey == expectedShareDayKey,
              response.committedAt > 0,
              response.committedAt < response.rotationAnchorUTC,
              response.contentExpiresAt > response.committedAt,
              response.contentExpiresAt <= response.committedAt + 30 * 86_400
        else { throw PairingError.invalidServerResponse }
        return SharingCommitResult(
            sourceID: response.sourceId,
            generationID: generationID,
            shareDayKey: response.shareDayKey,
            revision: response.revision,
            attemptID: response.prepareAttemptId,
            attemptRevision: response.prepareAttemptRevision,
            reservedRevision: response.reservedRevision,
            rotationAnchorUTC: response.rotationAnchorUTC
        )
    }

    func generation(
        generationID: String,
        expectedPublisherMemberID: String,
        memberID: String,
        credential: PairingCredential
    ) async throws -> SharingGenerationResume {
        guard Self.isIdentifier(generationID),
              Self.isIdentifier(expectedPublisherMemberID),
              expectedPublisherMemberID == memberID
        else { throw DailySharingError.stateUnavailable }
        let response: GenerationResumeResponse = try await sendEmptyJSON(
            path: "/v1/sharing/generations/\(generationID)",
            method: "GET",
            memberID: memberID,
            credential: credential
        )
        let generation = response.generation
        let allowedStates: Set<String> = ["reserved", "uploading", "prepared", "committed"]
        guard response.protocolVersion == DailySharingProtocol.version,
              Self.isIdentifier(response.sourceId),
              response.publisherMemberId == expectedPublisherMemberID,
              generation.id == generationID,
              allowedStates.contains(generation.state),
              (0...10_000_000).contains(generation.shareDayKey),
              (1...DailySharingProtocol.maximumSlotCount).contains(generation.itemCount),
              generation.createdAt > 0,
              generation.expiresAt > generation.createdAt,
              generation.expiresAt <= generation.createdAt + 60 * 60,
              generation.itemCount == response.items.count,
              Self.validSortedUniqueMediaIDs(response.items.map(\.mediaId))
        else { throw PairingError.invalidServerResponse }

        let hasPrepare = generation.prepareAttemptId != nil
            || generation.prepareAttemptRevision != nil
            || generation.reservedRevision != nil
            || generation.rotationAnchorUTC != nil
            || generation.prepareExpiresAt != nil
        if hasPrepare {
            guard let attemptID = generation.prepareAttemptId,
                  Self.isIdentifier(attemptID),
                  let attemptRevision = generation.prepareAttemptRevision,
                  attemptRevision > 0,
                  let reservedRevision = generation.reservedRevision,
                  reservedRevision > 0,
                  let anchor = generation.rotationAnchorUTC,
                  anchor > 0,
                  anchor.isMultiple(of: 1_200),
                  generation.prepareExpiresAt == anchor,
                  generation.state == "prepared" || generation.state == "committed"
            else { throw PairingError.invalidServerResponse }
        } else if generation.state == "prepared" || generation.state == "committed" {
            throw PairingError.invalidServerResponse
        }

        let media = try response.items.map { item -> SharingGenerationResume.Media in
            switch item.state {
            case "reserved":
                guard generation.state == "reserved",
                      item.ciphertextSize == nil,
                      item.ciphertextSHA256 == nil
                else { throw PairingError.invalidServerResponse }
            case "expected", "verified":
                guard generation.state != "reserved",
                      let size = item.ciphertextSize,
                      (DailySharingProtocol.chachaCombinedOverheadBytes + 1 ... DailySharingProtocol.maximumMediaCiphertextBytes)
                        .contains(size),
                      let hash = item.ciphertextSHA256,
                      Data(base64URLString: hash)?.count == 32
                else { throw PairingError.invalidServerResponse }
            default:
                throw PairingError.invalidServerResponse
            }
            if generation.state == "prepared" || generation.state == "committed" {
                guard item.state == "verified" else { throw PairingError.invalidServerResponse }
            }
            return .init(
                mediaID: item.mediaId,
                ciphertextSize: item.ciphertextSize,
                ciphertextSHA256: item.ciphertextSHA256,
                state: item.state
            )
        }

        let manifest = try generation.manifest.map { value -> SharingCurrentGeneration.ObjectDescriptor in
            guard generation.state == "prepared" || generation.state == "committed",
                  (DailySharingProtocol.chachaCombinedOverheadBytes + 1 ... DailySharingProtocol.maximumManifestCiphertextBytes)
                    .contains(value.ciphertextSize),
                  Data(base64URLString: value.ciphertextSHA256)?.count == 32
            else { throw PairingError.invalidServerResponse }
            return .init(
                ciphertextSize: value.ciphertextSize,
                ciphertextSHA256: value.ciphertextSHA256
            )
        }
        if generation.state == "committed", manifest == nil {
            throw PairingError.invalidServerResponse
        }
        return SharingGenerationResume(
            sourceID: response.sourceId,
            publisherMemberID: response.publisherMemberId,
            generationID: generation.id,
            state: generation.state,
            shareDayKey: generation.shareDayKey,
            itemCount: generation.itemCount,
            createdAt: generation.createdAt,
            expiresAt: generation.expiresAt,
            attemptID: generation.prepareAttemptId,
            attemptRevision: generation.prepareAttemptRevision,
            reservedRevision: generation.reservedRevision,
            rotationAnchorUTC: generation.rotationAnchorUTC,
            prepareExpiresAt: generation.prepareExpiresAt,
            manifest: manifest,
            media: media
        )
    }

    func listSources(
        expectedPublisherMemberIDs: Set<String>,
        memberID: String,
        credential: PairingCredential
    ) async throws -> [SharingSourceSummary] {
        guard expectedPublisherMemberIDs.count == 2,
              expectedPublisherMemberIDs.contains(memberID),
              expectedPublisherMemberIDs.allSatisfy(Self.isIdentifier)
        else { throw DailySharingError.stateUnavailable }
        let response: SourcesResponse = try await sendEmptyJSON(
            path: "/v1/sharing/sources",
            method: "GET",
            memberID: memberID,
            credential: credential
        )
        guard response.protocolVersion == DailySharingProtocol.version,
              response.sources.count <= 2,
              Set(response.sources.map(\.id)).count == response.sources.count,
              Set(response.sources.map(\.publisherMemberId)).count == response.sources.count,
              Set(response.sources.map(\.publisherMemberId)).isSubset(of: expectedPublisherMemberIDs)
        else {
            throw PairingError.invalidServerResponse
        }
        var seen = Set<String>()
        return try response.sources.map { source in
            guard Self.isIdentifier(source.id),
                  Self.isIdentifier(source.publisherMemberId),
                  seen.insert(source.id).inserted
            else { throw PairingError.invalidServerResponse }
            let current = try source.current.map { try Self.validatedSummary($0) }
            return SharingSourceSummary(
                sourceID: source.id,
                publisherMemberID: source.publisherMemberId,
                current: current
            )
        }
    }

    func current(
        sourceID: String,
        eTag: String?,
        memberID: String,
        credential: PairingCredential
    ) async throws -> SharingCurrentFetch {
        guard Self.isIdentifier(sourceID) else { throw DailySharingError.stateUnavailable }
        let (data, response) = try await sendRaw(
            path: "/v1/sharing/sources/\(sourceID)/current",
            method: "GET",
            body: Data(),
            contentType: nil,
            memberID: memberID,
            credential: credential,
            maximumResponseBytes: 65_536,
            ifNoneMatch: eTag,
            allowNotModified: eTag != nil
        )
        if response.statusCode == 304 {
            try Self.validateNotModified(
                requestETag: eTag,
                responseETag: response.value(forHTTPHeaderField: "ETag")
            )
            return .notModified
        }
        let value: CurrentResponse = try decode(data)
        let validated = try Self.validatedCurrent(value, expectedSourceID: sourceID)
        let expectedETag = "\"nw1-\(sourceID)-\(validated.revision)\""
        guard response.value(forHTTPHeaderField: "ETag") == expectedETag else {
            throw PairingError.invalidServerResponse
        }
        return .current(validated, eTag: expectedETag)
    }

#if DEBUG
    static func runtimeSelfTestValidateNotModified(
        requestETag: String?,
        responseETag: String?
    ) throws {
        try validateNotModified(requestETag: requestETag, responseETag: responseETag)
    }
#endif

    func downloadManifest(
        current: SharingCurrentGeneration,
        memberID: String,
        credential: PairingCredential
    ) async throws -> Data {
        try await download(
            path: "/v1/sharing/generations/\(current.generationID)/manifest",
            maximumBytes: DailySharingProtocol.maximumManifestCiphertextBytes,
            expectedSize: current.manifest.ciphertextSize,
            expectedSHA256: current.manifest.ciphertextSHA256,
            memberID: memberID,
            credential: credential
        )
    }

    func downloadMedia(
        current: SharingCurrentGeneration,
        descriptor: SharingCurrentGeneration.MediaDescriptor,
        memberID: String,
        credential: PairingCredential
    ) async throws -> Data {
        guard Self.isIdentifier(current.generationID),
              Self.isIdentifier(descriptor.mediaID),
              current.media.contains(where: {
                  $0.mediaID == descriptor.mediaID
                    && $0.ciphertextSize == descriptor.ciphertextSize
                    && $0.ciphertextSHA256 == descriptor.ciphertextSHA256
              })
        else { throw DailySharingError.stateUnavailable }
        return try await download(
            path: "/v1/sharing/generations/\(current.generationID)/media/\(descriptor.mediaID)",
            maximumBytes: DailySharingProtocol.maximumMediaCiphertextBytes,
            expectedSize: descriptor.ciphertextSize,
            expectedSHA256: descriptor.ciphertextSHA256,
            memberID: memberID,
            credential: credential
        )
    }

    private func download(
        path: String,
        maximumBytes: Int,
        expectedSize: Int,
        expectedSHA256: String,
        memberID: String,
        credential: PairingCredential
    ) async throws -> Data {
        let (data, response) = try await sendRaw(
            path: path,
            method: "GET",
            body: Data(),
            contentType: nil,
            memberID: memberID,
            credential: credential,
            maximumResponseBytes: maximumBytes
        )
        guard response.statusCode == 200,
              response.mimeType == "application/octet-stream",
              data.count == expectedSize,
              PairingCrypto.sha256(data).base64URLEncodedString() == expectedSHA256,
              response.value(forHTTPHeaderField: "Content-Length") == String(data.count),
              let hash = response.value(forHTTPHeaderField: "Neko-Ciphertext-SHA256"),
              Data(base64URLString: hash)?.count == 32,
              PairingCrypto.sha256(data).base64URLEncodedString() == hash,
              hash == expectedSHA256,
              response.value(forHTTPHeaderField: "ETag") == "\"sha256-\(hash)\"",
              response.value(forHTTPHeaderField: "X-Content-Type-Options")?.lowercased() == "nosniff",
              response.value(forHTTPHeaderField: "Cache-Control")?.lowercased()
                == "no-store, max-age=0"
        else { throw PairingError.invalidServerResponse }
        return data
    }

    private func sendEmptyJSON<Response: Decodable>(
        path: String,
        method: String,
        memberID: String,
        credential: PairingCredential
    ) async throws -> Response {
        let (data, _) = try await sendRaw(
            path: path,
            method: method,
            body: Data(),
            contentType: nil,
            memberID: memberID,
            credential: credential,
            maximumResponseBytes: 65_536
        )
        return try decode(data)
    }

    private func sendJSON<Request: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Request,
        memberID: String,
        credential: PairingCredential
    ) async throws -> Response {
        let body = try encoder.encode(body)
        let (data, _) = try await sendRaw(
            path: path,
            method: method,
            body: body,
            contentType: "application/json",
            memberID: memberID,
            credential: credential,
            maximumResponseBytes: 65_536
        )
        return try decode(data)
    }

    private func sendRaw(
        path: String,
        method: String,
        body: Data,
        contentType: String?,
        memberID: String,
        credential: PairingCredential,
        maximumResponseBytes: Int,
        ifNoneMatch: String? = nil,
        allowNotModified: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/"), !path.contains("?"),
              maximumResponseBytes > 0,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { throw PairingError.invalidServerResponse }
        components.path = path
        guard let url = components.url else { throw PairingError.apiNotConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        request.timeoutInterval = 30
        request.setValue("application/json, application/octet-stream", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let ifNoneMatch { request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match") }
        try authenticate(
            &request,
            path: path,
            method: method,
            body: body,
            memberID: memberID,
            credential: credential
        )
        let (data, response) = try await transport.data(
            for: request,
            maximumBytes: maximumResponseBytes
        )
        guard let http = response as? HTTPURLResponse else {
            throw PairingError.invalidServerResponse
        }
        if allowNotModified, http.statusCode == 304 { return (Data(), http) }
        if let contentLength = http.value(forHTTPHeaderField: "Content-Length")
            .flatMap(Int.init), contentLength > maximumResponseBytes {
            throw DailySharingError.responseTooLarge
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode) {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Int.init)
                    .map { min(max($0, 1), 6 * 60 * 60) }
                throw DailySharingError.retryableServer(retryAfterSeconds: retryAfter)
            }
            let value = try? decoder.decode(SharingAPIErrorResponse.self, from: data)
            throw PairingError.requestRejected(
                status: http.statusCode,
                code: value?.error.code,
                message: value.map { String($0.error.message.prefix(240)) }
                    ?? "共有サーバーで処理を完了できませんでした（\(http.statusCode)）。"
            )
        }
        return (data, http)
    }

    private func authenticate(
        _ request: inout URLRequest,
        path: String,
        method: String,
        body: Data,
        memberID: String,
        credential: PairingCredential
    ) throws {
        guard PairingValidation.isOpaqueIdentifier(memberID) else {
            throw PairingError.malformedCredential
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let nonce = PairingCrypto.randomData(count: 16).base64URLEncodedString()
        let transcript = try PairingCanonicalEncoder.encode([
            "NW1.REQUEST",
            String(PairingProtocol.version),
            memberID,
            String(timestamp),
            nonce,
            method.uppercased(),
            path,
            PairingCrypto.sha256(body).base64URLEncodedString()
        ])
        let signature = try PairingCrypto.sign(transcript, credential: credential)
            .base64URLEncodedString()
        request.setValue(String(PairingProtocol.version), forHTTPHeaderField: "Neko-Protocol-Version")
        request.setValue(memberID, forHTTPHeaderField: "Neko-Member-ID")
        request.setValue(String(timestamp), forHTTPHeaderField: "Neko-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "Neko-Nonce")
        request.setValue(signature, forHTTPHeaderField: "Neko-Signature")
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do { return try decoder.decode(Value.self, from: data) }
        catch { throw PairingError.invalidServerResponse }
    }

    private static func validateNotModified(
        requestETag: String?,
        responseETag: String?
    ) throws {
        guard let requestETag,
              !requestETag.isEmpty,
              responseETag == requestETag
        else { throw PairingError.invalidServerResponse }
    }

    private static func validatedSummary(_ value: SourceCurrentSummary) throws -> SharingSourceSummary.Current {
        guard isIdentifier(value.generationId),
              (0...10_000_000).contains(value.shareDayKey),
              value.revision > 0,
              value.rotationAnchorUTC > 0,
              value.rotationAnchorUTC.isMultiple(of: 1_200),
              (1...DailySharingProtocol.maximumSlotCount).contains(value.itemCount),
              value.committedAt > 0,
              value.contentExpiresAt > value.committedAt,
              value.contentExpiresAt <= value.committedAt + 30 * 86_400
        else { throw PairingError.invalidServerResponse }
        return .init(
            generationID: value.generationId,
            shareDayKey: value.shareDayKey,
            revision: value.revision,
            rotationAnchorUTC: value.rotationAnchorUTC,
            uniqueMediaCount: value.itemCount
        )
    }

    private static func validatedCurrent(
        _ response: CurrentResponse,
        expectedSourceID: String
    ) throws -> SharingCurrentGeneration {
        let value = response.current
        guard response.protocolVersion == DailySharingProtocol.version,
              response.sourceId == expectedSourceID,
              isIdentifier(response.publisherMemberId),
              isIdentifier(value.generationId),
              (0...10_000_000).contains(value.shareDayKey),
              value.revision > 0,
              isIdentifier(value.prepareAttemptId),
              value.prepareAttemptRevision > 0,
              value.reservedRevision == value.revision,
              value.rotationAnchorUTC > 0,
              value.rotationAnchorUTC.isMultiple(of: 1_200),
              value.itemCount == value.items.count,
              (1...DailySharingProtocol.maximumSlotCount).contains(value.itemCount),
              (DailySharingProtocol.chachaCombinedOverheadBytes + 1 ... DailySharingProtocol.maximumManifestCiphertextBytes)
                .contains(value.manifest.ciphertextSize),
              Data(base64URLString: value.manifest.ciphertextSHA256)?.count == 32,
              validSortedUniqueMediaIDs(value.items.map(\.mediaId))
        else { throw PairingError.invalidServerResponse }
        guard value.committedAt > 0,
              value.contentExpiresAt > value.committedAt,
              value.contentExpiresAt <= value.committedAt + 30 * 86_400
        else { throw PairingError.invalidServerResponse }
        let media = try value.items.map { item -> SharingCurrentGeneration.MediaDescriptor in
            guard (DailySharingProtocol.chachaCombinedOverheadBytes + 1 ... DailySharingProtocol.maximumMediaCiphertextBytes)
                .contains(item.ciphertextSize),
                  Data(base64URLString: item.ciphertextSHA256)?.count == 32
            else { throw PairingError.invalidServerResponse }
            return .init(
                mediaID: item.mediaId,
                ciphertextSize: item.ciphertextSize,
                ciphertextSHA256: item.ciphertextSHA256
            )
        }
        return SharingCurrentGeneration(
            sourceID: response.sourceId,
            publisherMemberID: response.publisherMemberId,
            generationID: value.generationId,
            shareDayKey: value.shareDayKey,
            revision: value.revision,
            attemptID: value.prepareAttemptId,
            attemptRevision: value.prepareAttemptRevision,
            reservedRevision: value.reservedRevision,
            rotationAnchorUTC: value.rotationAnchorUTC,
            uniqueMediaCount: value.itemCount,
            manifest: .init(
                ciphertextSize: value.manifest.ciphertextSize,
                ciphertextSHA256: value.manifest.ciphertextSHA256
            ),
            media: media
        )
    }

    private static func validSortedUniqueMediaIDs(_ values: [String]) -> Bool {
        !values.isEmpty && values.count <= DailySharingProtocol.maximumSlotCount
            && values == values.sorted() && Set(values).count == values.count
            && values.allSatisfy(isIdentifier)
    }

    private static func isIdentifier(_ value: String) -> Bool {
        Data(base64URLString: value)?.count == 16
    }
}

private final class SharingBoundedURLSessionTransport: NSObject,
    URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private final class Context {
        let maximumBytes: Int
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
        var data = Data()
        var response: URLResponse?
        var terminalError: Error?

        init(
            maximumBytes: Int,
            continuation: CheckedContinuation<(Data, URLResponse), Error>
        ) {
            self.maximumBytes = maximumBytes
            self.continuation = continuation
            data.reserveCapacity(min(maximumBytes, 64 * 1_024))
        }
    }

    private final class TaskHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        func set(_ task: URLSessionTask) {
            lock.lock()
            self.task = task
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
    }

    private let lock = NSLock()
    private var contexts: [Int: Context] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let queue = OperationQueue()
        queue.name = "jp.nekowidget.sharing.bounded-transport"
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    func data(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        guard maximumBytes > 0 else { throw DailySharingError.responseTooLarge }
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let context = Context(
                    maximumBytes: maximumBytes,
                    continuation: continuation
                )
                lock.lock()
                contexts[task.taskIdentifier] = context
                lock.unlock()
                holder.set(task)
                task.resume()
            }
        } onCancel: {
            holder.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        guard let context = contexts[dataTask.taskIdentifier] else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        context.response = response
        let declared = response.expectedContentLength
        if declared > Int64(context.maximumBytes) {
            context.terminalError = DailySharingError.responseTooLarge
            lock.unlock()
            completionHandler(.cancel)
        } else {
            lock.unlock()
            completionHandler(.allow)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard let context = contexts[dataTask.taskIdentifier],
              context.terminalError == nil
        else {
            lock.unlock()
            return
        }
        guard data.count <= context.maximumBytes - context.data.count else {
            context.terminalError = DailySharingError.responseTooLarge
            lock.unlock()
            dataTask.cancel()
            return
        }
        context.data.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let context = contexts.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let context else { return }
        if let terminalError = context.terminalError {
            context.continuation.resume(throwing: terminalError)
        } else if let error {
            context.continuation.resume(throwing: error)
        } else if let response = context.response {
            context.continuation.resume(returning: (context.data, response))
        } else {
            context.continuation.resume(throwing: PairingError.invalidServerResponse)
        }
    }
}

private struct ReserveRequest: Encodable {
    struct Item: Encodable { let mediaId: String }
    let protocolVersion: Int
    let clientRequestId: String
    let items: [Item]
}

private struct DescriptorRequest: Encodable {
    struct Item: Encodable {
        let mediaId: String
        let ciphertextSize: Int
        let ciphertextSHA256: String
    }
    let protocolVersion: Int
    let clientRequestId: String
    let items: [Item]
}

private struct OperationRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
}

private struct CommitRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
    let prepareAttemptId: String
    let prepareAttemptRevision: Int
    let reservedRevision: Int
    let manifestCiphertextSHA256: String
}

private struct ReserveResponse: Decodable {
    struct Source: Decodable { let id: String; let publisherMemberId: String }
    struct Generation: Decodable {
        let id: String
        let state: String
        let shareDayKey: Int
        let itemCount: Int
        let createdAt: Int
        let expiresAt: Int
    }
    struct Item: Decodable { let mediaId: String; let state: String }
    let protocolVersion: Int
    let source: Source
    let generation: Generation
    let items: [Item]
}

private struct DescriptorResponse: Decodable {
    struct Item: Decodable {
        let mediaId: String
        let ciphertextSize: Int
        let ciphertextSHA256: String
        let state: String
    }
    let protocolVersion: Int
    let generationId: String
    let state: String
    let items: [Item]
}

private struct MediaVerifiedResponse: Decodable {
    let protocolVersion: Int
    let generationId: String
    let mediaId: String
    let ciphertextSize: Int
    let ciphertextSHA256: String
    let state: String
}

private struct PrepareResponse: Decodable {
    let protocolVersion: Int
    let generationId: String
    let state: String
    let prepareAttemptRevision: Int
    let prepareAttemptId: String
    let reservedRevision: Int
    let rotationAnchorUTC: Int
    let prepareExpiresAt: Int
}

private struct ManifestVerifiedResponse: Decodable {
    let protocolVersion: Int
    let generationId: String
    let prepareAttemptRevision: Int
    let prepareAttemptId: String
    let ciphertextSize: Int
    let ciphertextSHA256: String
    let state: String
}

private struct CommitResponse: Decodable {
    let protocolVersion: Int
    let sourceId: String
    let generationId: String
    let shareDayKey: Int
    let revision: Int
    let prepareAttemptId: String
    let prepareAttemptRevision: Int
    let reservedRevision: Int
    let rotationAnchorUTC: Int
    let committedAt: Int
    let contentExpiresAt: Int
    let state: String
}

private struct SourceCurrentSummary: Decodable {
    let generationId: String
    let shareDayKey: Int
    let revision: Int
    let rotationAnchorUTC: Int
    let itemCount: Int
    let committedAt: Int
    let contentExpiresAt: Int
}

private struct SourcesResponse: Decodable {
    struct Source: Decodable {
        let id: String
        let publisherMemberId: String
        let current: SourceCurrentSummary?
    }
    let protocolVersion: Int
    let sources: [Source]
}

private struct CurrentResponse: Decodable {
    struct Current: Decodable {
        struct Descriptor: Decodable {
            let ciphertextSize: Int
            let ciphertextSHA256: String
        }
        struct Media: Decodable {
            let mediaId: String
            let ciphertextSize: Int
            let ciphertextSHA256: String
        }
        let generationId: String
        let shareDayKey: Int
        let revision: Int
        let prepareAttemptId: String
        let prepareAttemptRevision: Int
        let reservedRevision: Int
        let rotationAnchorUTC: Int
        let itemCount: Int
        let committedAt: Int
        let contentExpiresAt: Int
        let manifest: Descriptor
        let items: [Media]
    }
    let protocolVersion: Int
    let sourceId: String
    let publisherMemberId: String
    let current: Current
}

private struct SharingAPIErrorResponse: Decodable {
    struct Body: Decodable { let code: String; let message: String }
    let error: Body
}

enum DailySharingAPIContractVerifier {
    static func verifyGoldenResponses(_ data: Data) throws {
        struct Fixture: Decodable {
            let schemaVersion: Int
            let reserve: ReserveResponse
            let descriptors: DescriptorResponse
            let mediaVerified: MediaVerifiedResponse
            let generationResume: GenerationResumeResponse
            let prepare: PrepareResponse
            let manifestVerified: ManifestVerifiedResponse
            let commit: CommitResponse
            let sources: SourcesResponse
            let current: CurrentResponse
        }
        let value = try JSONDecoder().decode(Fixture.self, from: data)
        guard value.schemaVersion == DailySharingProtocol.version,
              value.reserve.protocolVersion == DailySharingProtocol.version,
              value.descriptors.protocolVersion == DailySharingProtocol.version,
              value.mediaVerified.protocolVersion == DailySharingProtocol.version,
              value.generationResume.protocolVersion == DailySharingProtocol.version,
              value.prepare.protocolVersion == DailySharingProtocol.version,
              value.manifestVerified.protocolVersion == DailySharingProtocol.version,
              value.commit.protocolVersion == DailySharingProtocol.version,
              value.sources.protocolVersion == DailySharingProtocol.version,
              value.current.protocolVersion == DailySharingProtocol.version,
              value.current.current.prepareAttemptRevision == value.prepare.prepareAttemptRevision,
              value.current.current.reservedRevision == value.prepare.reservedRevision
        else { throw PairingError.invalidServerResponse }
    }
}

private struct GenerationResumeResponse: Decodable {
    struct Generation: Decodable {
        struct Manifest: Decodable {
            let ciphertextSize: Int
            let ciphertextSHA256: String
        }
        let id: String
        let state: String
        let shareDayKey: Int
        let itemCount: Int
        let createdAt: Int
        let expiresAt: Int
        let prepareAttemptRevision: Int?
        let prepareAttemptId: String?
        let reservedRevision: Int?
        let rotationAnchorUTC: Int?
        let prepareExpiresAt: Int?
        let manifest: Manifest?
    }
    let protocolVersion: Int
    let sourceId: String
    let publisherMemberId: String
    let generation: Generation
    struct Item: Decodable {
        let mediaId: String
        let ciphertextSize: Int?
        let ciphertextSHA256: String?
        let state: String
    }
    let items: [Item]
}
