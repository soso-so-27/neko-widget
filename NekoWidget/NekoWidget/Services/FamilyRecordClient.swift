import Foundation

struct FamilyRecordSnapshot: Sendable {
    let catalog: FamilyRecordCatalog
    let words: [String: String]
}

struct FamilyRecordMutation: Sendable {
    struct Body: Encodable, Sendable {
        let entryID: String
        let kind: FamilyRecordRow.Kind
        let expectedRevision: Int
        let operationID: String
        let ciphertext: String?
        // JSON null explicitly means withdrawal; omission must never do so.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(entryID, forKey: .entryID)
            try container.encode(kind, forKey: .kind)
            try container.encode(expectedRevision, forKey: .expectedRevision)
            try container.encode(operationID, forKey: .operationID)
            try container.encode(ciphertext, forKey: .ciphertext)
        }
        enum Keys: String, CodingKey { case entryID, kind, expectedRevision, operationID, ciphertext }
    }
    let id: String
    let spaceID: String
    let authorID: String
    // Nil is accepted only by the DEBUG injected UI fixture, never this client.
    let lifecycleToken: SharingLifecycleGate.Token?
    let body: Body
}

/// No disk photo cache or offline authority. Every read/save requires the same
/// currently paired private window. Reopening re-fetches the server catalog;
/// a local snapshot never grants access or reintroduces withdrawn content.
protocol FamilyRecordServing: Sendable {
    func load() async throws -> FamilyRecordSnapshot
    func photo(_ row: FamilyRecordRow) async throws -> Data
    func photoContent(_ row: FamilyRecordRow) async throws -> FamilyRecordPhotoContent
    func preparePhoto(_ photo: MomentShareIngressPhoto, sourceMomentID: String?) async throws -> FamilyRecordMutation
    func prepareWords(_ text: String, entryID: String, replacing row: FamilyRecordRow?) async throws -> FamilyRecordMutation
    func prepareWithdrawal(_ row: FamilyRecordRow) async throws -> FamilyRecordMutation
    func save(_ mutation: FamilyRecordMutation) async throws -> FamilyRecordRow
}

extension FamilyRecordServing {
    func photoContent(_ row: FamilyRecordRow) async throws -> FamilyRecordPhotoContent {
        FamilyRecordPhotoContent(jpeg: try await photo(row), capturedAt: nil)
    }
    func preparePhoto(_ photo: MomentShareIngressPhoto) async throws -> FamilyRecordMutation {
        try await preparePhoto(photo, sourceMomentID: nil)
    }
}

actor FamilyRecordClient: FamilyRecordServing {
    private let expectedSpaceID: String
    private let configuration: SharingAPIConfiguration
    private struct Authorization {
        let pairing: PairingState
        let credential: PairingCredential
        let token: SharingLifecycleGate.Token
    }
    init(expectedSpaceID: String, configuration: SharingAPIConfiguration = .current) {
        self.expectedSpaceID = expectedSpaceID
        self.configuration = configuration
    }

    private func authorization() throws -> Authorization {
        guard configuration.isMediaAvailable else { throw FamilyRecordError.unavailable }
        let bootstrap = try PairingInstallationGuard.bootstrap()
        let pairing = bootstrap.state
        guard pairing.phase == .paired, pairing.spaceID == expectedSpaceID,
              pairing.mediaSharingConsentVersion == PairingMediaSharingConsent.currentVersion,
              pairing.mediaSharingConsentAcceptedAt != nil,
              let account = pairing.credentialAccount else { throw FamilyRecordError.unavailable }
        let credential = try PairingKeychainStore.load(account: account, installationMarker: pairing.installationMarker)
        guard credential.roomKey?.count == 32 else { throw FamilyRecordError.unavailable }
        try SharingLifecycleGate.validate(bootstrap.lifecycleToken)
        return Authorization(pairing: pairing, credential: credential, token: bootstrap.lifecycleToken)
    }
    private func validate(_ auth: Authorization) throws {
        try SharingLifecycleGate.validate(auth.token)
        let current = try authorization()
        guard current.token == auth.token, current.pairing.spaceID == auth.pairing.spaceID,
              current.pairing.memberID == auth.pairing.memberID else { throw FamilyRecordError.changed }
    }
    private func request(_ path: String, method: String = "GET", body: Data = Data(), auth: Authorization) async throws -> Data {
        try validate(auth)
        let api = try URLSessionMomentSharingAPIClient(configuration: configuration, requestTimeout: 30)
        let response = try await api.familyRecordRequest(path: path, method: method, body: body,
            pairingState: auth.pairing, credential: auth.credential)
        try Task.checkCancellation()
        try validate(auth)
        return response
    }
    func load() async throws -> FamilyRecordSnapshot {
        let auth = try authorization()
        let data = try await request("/v2/family-records", auth: auth)
        guard let author = auth.pairing.memberID, let roomKey = auth.credential.roomKey else { throw FamilyRecordError.unavailable }
        let catalog = try JSONDecoder().decode(FamilyRecordCatalog.self, from: data)
            .validated(spaceID: expectedSpaceID, participantID: author)
        var words: [String: String] = [:]
        for row in catalog.records where row.kind == .words && row.state == .active {
            guard let encoded = row.ciphertext, let cipher = Data(base64URLString: encoded),
                  let text = try FamilyRecordCrypto.open(cipher, row: row, roomKey: roomKey,
                    spaceID: expectedSpaceID).text else { throw FamilyRecordError.invalid }
            words[row.id] = text
        }
        try validate(auth)
        return FamilyRecordSnapshot(catalog: catalog, words: words)
    }
    func isAvailable() async -> Bool {
        do {
            let auth = try authorization()
            let data = try await request("/v2/family-records/capabilities", auth: auth)
            struct Capability: Decodable { let schemaVersion: Int }
            return try JSONDecoder().decode(Capability.self, from: data).schemaVersion == 1
        } catch { return false }
    }
    func photo(_ row: FamilyRecordRow) async throws -> Data {
        try await photoContent(row).jpeg
    }
    func photoContent(_ row: FamilyRecordRow) async throws -> FamilyRecordPhotoContent {
        let auth = try authorization()
        let data = try await request("/v2/family-records/\(row.id)/photo", auth: auth)
        guard let roomKey = auth.credential.roomKey,
              let content = try? FamilyRecordCrypto.open(data, row: row, roomKey: roomKey,
                  spaceID: expectedSpaceID), let jpeg = content.jpeg else { throw FamilyRecordError.invalid }
        try await requireSafe(jpeg)
        try validate(auth)
        return FamilyRecordPhotoContent(jpeg: jpeg, capturedAt: content.capturedAt)
    }
    func preparePhoto(_ photo: MomentShareIngressPhoto, sourceMomentID: String?) async throws -> FamilyRecordMutation {
        let auth = try authorization()
        try await requireSafe(photo.canonicalJPEG)
        try validate(auth)
        let id: String
        if let sourceMomentID {
            id = try FamilyRecordSourceIdentity.recordID(spaceID: expectedSpaceID, momentID: sourceMomentID)
        } else { id = UUID().uuidString.lowercased() }
        let payload = FamilyRecordPayload(schemaVersion: 1, text: nil, jpeg: photo.canonicalJPEG, capturedAt: photo.capturedAt)
        return try prepare(id: id, entryID: id, kind: .photo, revision: 0, payload: payload, auth: auth)
    }
    func prepareWords(_ text: String, entryID: String, replacing row: FamilyRecordRow? = nil) throws -> FamilyRecordMutation {
        let auth = try authorization()
        if let row {
            guard row.authorID == auth.pairing.memberID, row.kind == .words, row.entryID == entryID,
                  row.state == .active else { throw FamilyRecordError.changed }
        }
        return try prepare(id: row?.id ?? UUID().uuidString.lowercased(), entryID: entryID,
            kind: .words, revision: row?.revision ?? 0, payload: FamilyRecordPayload.words(text), auth: auth)
    }
    func prepareWithdrawal(_ row: FamilyRecordRow) throws -> FamilyRecordMutation {
        let auth = try authorization()
        guard row.authorID == auth.pairing.memberID, row.state == .active else { throw FamilyRecordError.changed }
        return try prepare(id: row.id, entryID: row.entryID, kind: row.kind, revision: row.revision, payload: nil, auth: auth)
    }
    private func prepare(id: String, entryID: String, kind: FamilyRecordRow.Kind, revision: Int,
                         payload: FamilyRecordPayload?, auth: Authorization) throws -> FamilyRecordMutation {
        guard let author = auth.pairing.memberID, let roomKey = auth.credential.roomKey else { throw FamilyRecordError.unavailable }
        let ciphertext = try payload.map { try FamilyRecordCrypto.seal($0, roomKey: roomKey,
            spaceID: expectedSpaceID, id: id, entryID: entryID, kind: kind, authorID: author, revision: revision + 1)
            .base64URLEncodedString() }
        return FamilyRecordMutation(id: id, spaceID: expectedSpaceID, authorID: author, lifecycleToken: auth.token,
            body: .init(entryID: entryID, kind: kind, expectedRevision: revision,
                operationID: UUID().uuidString.lowercased(), ciphertext: ciphertext))
    }
    @discardableResult
    func save(_ mutation: FamilyRecordMutation) async throws -> FamilyRecordRow {
        let auth = try authorization()
        guard mutation.spaceID == expectedSpaceID, mutation.authorID == auth.pairing.memberID,
              mutation.lifecycleToken == auth.token else { throw FamilyRecordError.changed }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try await request("/v2/family-records/\(mutation.id)", method: "PUT",
            body: encoder.encode(mutation.body), auth: auth)
        struct Result: Decodable { let record: FamilyRecordRow }
        let row = try JSONDecoder().decode(Result.self, from: data).record.validated()
        guard row.id == mutation.id, row.authorID == mutation.authorID, row.kind == mutation.body.kind,
              row.entryID == mutation.body.entryID, row.revision == mutation.body.expectedRevision + 1,
              (row.state == .withdrawn) == (mutation.body.ciphertext == nil) else { throw FamilyRecordError.invalid }
        return row
    }

    private func requireSafe(_ jpeg: Data) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try jpeg.write(to: url, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: url) }
        try await MomentModerationService().requireSafeImage(at: url)
    }
}

/// Exports a fresh, complete catalog. Withdrawn photos stay absent even when
/// their still-active words are exported beside an explicit missing-photo note.
enum FamilyRecordExporter {
    static func verify(_ original: FamilyRecordSnapshot, client: any FamilyRecordServing) async throws {
        let current = try await client.load()
        guard current.catalog.spaceID == original.catalog.spaceID,
              current.catalog.participantID == original.catalog.participantID,
              current.catalog.records == original.catalog.records,
              current.words == original.words else { throw FamilyRecordError.changed }
    }

    static func create(client: any FamilyRecordServing, snapshot: FamilyRecordSnapshot,
                       temporaryDirectory: URL = FileManager.default.temporaryDirectory) async throws -> PhotoMemoryNoteExportPayload {
        try await verify(snapshot, client: client)
        let records = snapshot.catalog.records
        let photos = records.filter { row in
            row.kind == .photo && (row.state == .active || records.contains {
                $0.kind == .words && $0.entryID == row.id && $0.state == .active
            })
        }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        let introduction = """
        ねこのまど　共有アルバムの書き出し

        このZIPは、書き出した時点で閲覧できた一つのまどの共有写真とメモのコピーです。
        写真は共有に保存された鑑賞用コピーで、写真アプリの原本ではありません。
        各番号のフォルダに写真と対応するメモを入れました。写真を取り下げた記録はメモだけが残ります。
        「自分」は書き出した人、「相手」は同じまどのもう一人です。
        撮影日・追加日・更新日はそれぞれ別の意味です。値がない日は記載しません。
        外へ保存したコピーは、後から共有を解除しても回収できません。
        """
        let result = try await PhotoMemoryNoteExporter.createPortableArchive(
            itemCount: photos.count, fileName: "ねこのまど_書き出し.zip",
            introduction: introduction, fetch: { index in
                let photo = photos[index]
                let image: FamilyRecordPhotoContent?
                if photo.state == .active { image = try await client.photoContent(photo) }
                else { image = nil }
                return try FamilyRecordPortableFiles.files(index: index, photo: photo, records: records,
                    words: snapshot.words, participantID: snapshot.catalog.participantID, image: image)
            }, temporaryDirectory: temporaryDirectory)
        do { try await verify(snapshot, client: client); return result }
        catch {
            do { try result.cleanup() }
            catch { throw PhotoMemoryNoteExportCleanupPending(payload: result) }
            throw error
        }
    }
}
