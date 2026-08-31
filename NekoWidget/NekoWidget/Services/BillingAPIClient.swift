import Foundation

protocol BillingAPIClientProtocol: Sendable {
    func createAccount(
        credential: BillingCredential
    ) async throws -> BillingAccountBootstrapResult

    func recordTransaction(
        signedTransactionInfo: String,
        expectedTransactionID: String,
        expectedOriginalTransactionID: String,
        credential: BillingCredential
    ) async throws -> BillingTransactionRecordAcknowledgement

    func fetchAuthoritativeEntitlement(
        credential: BillingCredential
    ) async throws -> BillingAuthoritativeEntitlement
}

private enum BillingEndpoint {
    case accountCreation
    case transaction
    case authoritativeEntitlement

    var method: String {
        switch self {
        case .accountCreation, .transaction: return "POST"
        case .authoritativeEntitlement: return "GET"
        }
    }

    var path: String {
        switch self {
        case .accountCreation: return BillingProtocolV1.accountCreationPath
        case .transaction: return BillingProtocolV1.transactionPath
        case .authoritativeEntitlement:
            return BillingProtocolV1.entitlementPath
        }
    }

    var expectedStatus: Int {
        switch self {
        case .accountCreation: return 201
        case .transaction, .authoritativeEntitlement: return 200
        }
    }

    var requiresAuthentication: Bool {
        switch self {
        case .accountCreation: return false
        case .transaction, .authoritativeEntitlement: return true
        }
    }

    func accepts(body: Data) -> Bool {
        switch self {
        case .accountCreation, .transaction: return !body.isEmpty
        case .authoritativeEntitlement: return body.isEmpty
        }
    }
}

/// Executes the only safe initial-account transition. The coordinator is not
/// wired into app launch or UI while the storefront remains disabled.
actor BillingAccountBootstrapCoordinator {
    typealias CredentialLoader = @Sendable () throws -> BillingCredential?
    typealias PendingCredentialInserter = @Sendable (
        BillingCredential
    ) throws -> BillingCredential
    typealias RegisteredCredentialSaver = @Sendable (
        BillingCredential,
        BillingCredential
    ) throws -> Void
    typealias InstallationMarkerLoader = @Sendable () throws -> UUID

    private let apiClient: any BillingAPIClientProtocol
    private let loadCredential: CredentialLoader
    private let insertPendingCredential: PendingCredentialInserter
    private let saveRegisteredCredential: RegisteredCredentialSaver
    private let loadInstallationMarker: InstallationMarkerLoader
    private var existingInFlight: Task<BillingCredential, Error>?
    private var freshInFlight: Task<BillingCredential, Error>?

    init(
        apiClient: any BillingAPIClientProtocol,
        loadCredential: @escaping CredentialLoader = {
            try BillingKeychainStore.load()
        },
        insertPendingCredential: @escaping PendingCredentialInserter = {
            try BillingKeychainStore.insertPendingIfAbsent($0)
        },
        saveRegisteredCredential: @escaping RegisteredCredentialSaver = {
            try BillingKeychainStore.saveRegistered($0, replacing: $1)
        },
        loadInstallationMarker: @escaping InstallationMarkerLoader = {
            try BillingInstallationMarkerStore.loadOrCreate()
        }
    ) {
        self.apiClient = apiClient
        self.loadCredential = loadCredential
        self.insertPendingCredential = insertPendingCredential
        self.saveRegisteredCredential = saveRegisteredCredential
        self.loadInstallationMarker = loadInstallationMarker
    }

    /// Returns an already registered credential or resumes one exact pending
    /// bootstrap request. Missing Keychain state never creates a new identity.
    func resumeExistingCredential() async throws -> BillingCredential {
        if let freshInFlight { return try await freshInFlight.value }
        if let existingInFlight { return try await existingInFlight.value }
        let task = Task { try await self.loadAndResumeExistingCredential() }
        existingInFlight = task
        do {
            let credential = try await task.value
            existingInFlight = nil
            return credential
        } catch {
            existingInFlight = nil
            throw error
        }
    }

    /// Creates the first pending identity only after the non-forgeable StoreKit
    /// scan capability is checked. Existing registered/pending state is reused.
    func createFreshCredential(
        authorizedBy authorization: BillingFreshAccountAuthorization
    ) async throws -> BillingCredential {
        if let freshInFlight { return try await freshInFlight.value }
        let task = Task {
            try await self.loadOrCreateFreshCredential(
                authorizedBy: authorization
            )
        }
        freshInFlight = task
        do {
            let credential = try await task.value
            freshInFlight = nil
            return credential
        } catch {
            freshInFlight = nil
            throw error
        }
    }

    private func loadAndResumeExistingCredential() async throws
        -> BillingCredential {
        let installationMarker = try loadInstallationMarker()
        let markerValue = installationMarker.uuidString.lowercased()
        guard let existing = try loadCredential() else {
            throw BillingClientError.billingCredentialMissing
        }
        return try await resume(existing, markerValue: markerValue)
    }

    private func loadOrCreateFreshCredential(
        authorizedBy authorization: BillingFreshAccountAuthorization
    ) async throws -> BillingCredential {
        let installationMarker = try loadInstallationMarker()
        let markerValue = installationMarker.uuidString.lowercased()
        if let existing = try loadCredential() {
            return try await resume(existing, markerValue: markerValue)
        }

        let candidate = try BillingCredential.pending(
            installationMarker: installationMarker
        ).validated()
        try authorization.validatedForBootstrap()
        // SecItemAdd elects one winner across coordinator instances before the
        // first await/network request. Losers reuse its key and request ID.
        let pending = try insertPendingCredential(candidate).validated()
        return try await resume(pending, markerValue: markerValue)
    }

    private func resume(
        _ existing: BillingCredential,
        markerValue: String
    ) async throws -> BillingCredential {
        let existing = try existing.validated()
        guard existing.installationMarker == markerValue else {
            // A retained Keychain item is recovery input, not authority for a
            // fresh installation. Never delete it or create another identity.
            throw BillingClientError.installationChanged
        }
        if existing.phase == .registered { return existing }
        return try await completeBootstrap(existing)
    }

    private func completeBootstrap(
        _ pending: BillingCredential
    ) async throws -> BillingCredential {
        guard pending.phase == .pendingBootstrap else {
            throw BillingClientError.malformedCredential
        }
        let result = try await apiClient.createAccount(credential: pending)
        let registered = try pending.registering(result)

        // Do not overwrite a credential changed by another coordinator or a
        // future recovery flow while this request was awaiting the network.
        let current = try loadCredential()
        if current == registered { return registered }
        guard current == pending else {
            throw BillingClientError.credentialChanged
        }
        try saveRegisteredCredential(registered, pending)
        guard try loadCredential() == registered else {
            throw BillingClientError.credentialChanged
        }
        return registered
    }
}

/// Internal live wiring between StoreKit observation and the independent
/// billing account. It never creates an account while resuming, and it never
/// rebinds an old transaction to a new installation. A missing/mismatched
/// credential with an existing purchase must enter a future JWS-backed account
/// recovery flow instead of silently claiming or replacing the old account.
actor PlusBillingSession {
    private let apiClient: any BillingAPIClientProtocol
    private let bootstrap: BillingAccountBootstrapCoordinator

    init(apiClient: any BillingAPIClientProtocol) {
        self.apiClient = apiClient
        bootstrap = BillingAccountBootstrapCoordinator(apiClient: apiClient)
    }

    static func configured(
        purchaseConfiguration: PlusPurchaseConfiguration,
        billingConfiguration: BillingClientConfiguration = .current
    ) -> PlusBillingSession? {
        guard purchaseConfiguration.isConfigured,
              billingConfiguration.isConfigured,
              let apiClient = try? URLSessionBillingAPIClient(
                  configuration: billingConfiguration
              )
        else { return nil }
        return PlusBillingSession(apiClient: apiClient)
    }

    /// Reserved for a future explicit purchase flow. The authorization proves
    /// that no configured StoreKit entitlement exists, so this cannot be used
    /// as an account-recovery shortcut.
    func createFreshBillingAccount(
        authorizedBy authorization: BillingFreshAccountAuthorization
    ) async throws -> BillingAccountID {
        let credential = try await bootstrap.createFreshCredential(
            authorizedBy: authorization
        )
        return try billingAccountID(for: credential)
    }

    func recordVerifiedTransactionEvent(
        _ event: PlusVerifiedTransactionEvent,
        billingAccountID: BillingAccountID
    ) async throws -> BillingTransactionRecordAcknowledgement {
        guard event.transaction.appAccountToken == billingAccountID.rawValue else {
            throw BillingClientError.identityMismatch
        }
        let credential = try await resumeCredentialForExistingInstallation()
        guard try self.billingAccountID(for: credential) == billingAccountID else {
            throw BillingClientError.identityMismatch
        }
        return try await apiClient.recordTransaction(
            signedTransactionInfo: event.signedTransactionInfo,
            expectedTransactionID: String(event.transaction.id),
            expectedOriginalTransactionID: String(event.transaction.originalID),
            credential: credential
        )
    }

    func fetchAuthoritativeEntitlement()
        async throws -> BillingAuthoritativeEntitlement {
        let credential = try await resumeCredentialForExistingInstallation()
        return try await apiClient.fetchAuthoritativeEntitlement(
            credential: credential
        )
    }

    private func resumeCredentialForExistingInstallation()
        async throws -> BillingCredential {
        do {
            return try await bootstrap.resumeExistingCredential()
        } catch let error as BillingClientError {
            switch error {
            case .billingCredentialMissing, .installationChanged:
                throw BillingClientError.billingAccountRecoveryRequired
            default:
                throw error
            }
        }
    }

    private func billingAccountID(
        for credential: BillingCredential
    ) throws -> BillingAccountID {
        let credential = try credential.validated()
        guard credential.phase == .registered,
              let rawValue = credential.billingAccountUUID
        else { throw BillingClientError.malformedCredential }
        return BillingAccountID(rawValue: rawValue)
    }
}

actor URLSessionBillingAPIClient: BillingAPIClientProtocol {
    private let baseURL: URL
    private let session: URLSession
    private let sessionDelegate: BillingNoRedirectSessionDelegate?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        configuration: BillingClientConfiguration,
        session: URLSession? = nil
    ) throws {
        guard configuration.isConfigured, let baseURL = configuration.baseURL else {
            throw BillingClientError.configurationUnavailable
        }
        self.baseURL = baseURL
        if let session {
            self.session = session
            sessionDelegate = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            let delegate = BillingNoRedirectSessionDelegate()
            sessionDelegate = delegate
            self.session = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: nil
            )
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func createAccount(
        credential: BillingCredential
    ) async throws -> BillingAccountBootstrapResult {
        let credential = try credential.validated()
        guard credential.phase == .pendingBootstrap else {
            throw BillingClientError.malformedCredential
        }
        let publicKey = try BillingProtocolCodec.signingPublicKey(for: credential)
        let transcript = try BillingProtocolCodec.accountCreationTranscript(
            clientRequestID: credential.clientRequestID,
            signingPublicKey: publicKey
        )
        let body = BillingAccountCreationRequest(
            protocolVersion: BillingProtocolV1.version,
            clientRequestId: credential.clientRequestID,
            signingPublicKey: publicKey,
            creationSignature: try BillingProtocolCodec.sign(
                transcript,
                credential: credential
            )
        )
        let response: BillingAccountCreationResponse = try await send(
            endpoint: .accountCreation,
            body: body,
            authentication: nil
        )
        guard response.protocolVersion == BillingProtocolV1.version else {
            throw BillingClientError.invalidServerResponse
        }
        return try BillingAccountBootstrapResult(
            billingAccountID: response.billingAccountId,
            billingKeyID: response.billingKeyId,
            createdAt: response.createdAt
        ).validated()
    }

    func recordTransaction(
        signedTransactionInfo: String,
        expectedTransactionID: String,
        expectedOriginalTransactionID: String,
        credential: BillingCredential
    ) async throws -> BillingTransactionRecordAcknowledgement {
        let credential = try credential.validated()
        guard credential.phase == .registered,
              BillingValidation.transactionID(expectedTransactionID),
              BillingValidation.transactionID(expectedOriginalTransactionID),
              signedTransactionInfo.utf8.count <= BillingProtocolV1
                .maximumSignedTransactionBytes,
              BillingValidation.compactJWS(signedTransactionInfo)
        else { throw BillingClientError.malformedCredential }
        let body = BillingTransactionRequest(
            protocolVersion: BillingProtocolV1.version,
            signedTransactionInfo: signedTransactionInfo
        )
        let encodedBody = try encoder.encode(body)
        let response: BillingTransactionResponse = try await sendData(
            endpoint: .transaction,
            body: encodedBody,
            authentication: credential
        )
        guard response.protocolVersion == BillingProtocolV1.version else {
            throw BillingClientError.invalidServerResponse
        }
        guard response.recorded,
              let accountUUID = BillingValidation.canonicalUUIDv4(
                  response.billingAccountId
              )
        else { throw BillingClientError.invalidServerResponse }
        // The nested summary is parsed only to enforce its fail-closed wire
        // contract. It is deliberately not returned as a Plus grant.
        _ = try response.entitlement.validated()
        return try BillingTransactionRecordAcknowledgement(
            billingAccountID: BillingAccountID(rawValue: accountUUID),
            originalTransactionID: response.originalTransactionId,
            transactionID: response.transactionId,
            disposition: response.disposition
        ).validated(
            credential: credential,
            expectedTransactionID: expectedTransactionID,
            expectedOriginalTransactionID: expectedOriginalTransactionID
        )
    }

    func fetchAuthoritativeEntitlement(
        credential: BillingCredential
    ) async throws -> BillingAuthoritativeEntitlement {
        let credential = try credential.validated()
        guard credential.phase == .registered,
              let billingAccountID = credential.billingAccountID
        else { throw BillingClientError.malformedCredential }
        let response: BillingAuthoritativeEntitlementResponse = try await sendData(
            endpoint: .authoritativeEntitlement,
            body: Data(),
            authentication: credential
        )
        guard response.protocolVersion == BillingProtocolV1.version,
              BillingValidation.canonicalUUIDv4(
                  response.billingAccountId
              ) != nil
        else { throw BillingClientError.invalidServerResponse }
        guard response.billingAccountId == billingAccountID else {
            throw BillingClientError.identityMismatch
        }
        return try response.entitlement.validated()
    }

    private func send<Request: Encodable, Response: Decodable>(
        endpoint: BillingEndpoint,
        body: Request,
        authentication: BillingCredential?
    ) async throws -> Response {
        let data: Data
        do {
            data = try encoder.encode(body)
        } catch {
            throw BillingClientError.invalidServerResponse
        }
        return try await sendData(
            endpoint: endpoint,
            body: data,
            authentication: authentication
        )
    }

    private func sendData<Response: Decodable>(
        endpoint: BillingEndpoint,
        body: Data,
        authentication: BillingCredential?
    ) async throws -> Response {
        guard endpoint.accepts(body: body),
              (authentication != nil) == endpoint.requiresAuthentication,
              var components = URLComponents(
                  url: baseURL,
                  resolvingAgainstBaseURL: false
              )
        else { throw BillingClientError.configurationUnavailable }
        components.path = endpoint.path
        guard let url = components.url else {
            throw BillingClientError.configurationUnavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.httpBody = body.isEmpty ? nil : body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !body.isEmpty {
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
        }
        if let authentication {
            try authenticate(
                request: &request,
                method: endpoint.method,
                pathname: endpoint.path,
                body: body,
                credential: authentication
            )
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw BillingClientError.transportUnavailable
        }
        guard let http = response as? HTTPURLResponse,
              http.url == url
        else {
            throw BillingClientError.invalidServerResponse
        }
        let maximumResponseBytes = 16 * 1_024
        if let contentLength = http.value(forHTTPHeaderField: "Content-Length")
            .flatMap(Int.init), contentLength > maximumResponseBytes {
            throw BillingClientError.invalidServerResponse
        }
        var responseData = Data()
        responseData.reserveCapacity(
            min(maximumResponseBytes, max(0, Int(http.expectedContentLength)))
        )
        do {
            for try await byte in bytes {
                guard responseData.count < maximumResponseBytes else {
                    throw BillingClientError.invalidServerResponse
                }
                responseData.append(byte)
            }
        } catch let error as BillingClientError {
            throw error
        } catch {
            throw BillingClientError.transportUnavailable
        }
        guard http.statusCode == endpoint.expectedStatus else {
            let apiError = try? decoder.decode(
                BillingAPIErrorResponse.self,
                from: responseData
            )
            throw BillingClientError.requestRejected(
                status: http.statusCode,
                code: apiError?.error.code
            )
        }
        do {
            return try decoder.decode(Response.self, from: responseData)
        } catch {
            throw BillingClientError.invalidServerResponse
        }
    }

    private func authenticate(
        request: inout URLRequest,
        method: String,
        pathname: String,
        body: Data,
        credential: BillingCredential
    ) throws {
        let credential = try credential.validated()
        guard credential.phase == .registered,
              let billingAccountID = credential.billingAccountID,
              let billingKeyID = credential.billingKeyID
        else { throw BillingClientError.malformedCredential }
        let timestamp = Int(Date().timeIntervalSince1970)
        let nonce = BillingProtocolCodec.randomNonce()
        let transcript = try BillingProtocolCodec.signedRequestTranscript(
            billingAccountID: billingAccountID,
            billingKeyID: billingKeyID,
            timestamp: timestamp,
            nonce: nonce,
            method: method,
            pathname: pathname,
            bodySHA256: BillingProtocolCodec.sha256(body)
        )
        let signature = try BillingProtocolCodec.sign(
            transcript,
            credential: credential
        )
        request.setValue(
            String(BillingProtocolV1.version),
            forHTTPHeaderField: "Neko-Billing-Protocol-Version"
        )
        request.setValue(
            billingAccountID,
            forHTTPHeaderField: "Neko-Billing-Account-ID"
        )
        request.setValue(
            billingKeyID,
            forHTTPHeaderField: "Neko-Billing-Key-ID"
        )
        request.setValue(
            String(timestamp),
            forHTTPHeaderField: "Neko-Billing-Timestamp"
        )
        request.setValue(nonce, forHTTPHeaderField: "Neko-Billing-Nonce")
        request.setValue(signature, forHTTPHeaderField: "Neko-Billing-Signature")
    }
}

private final class BillingNoRedirectSessionDelegate: NSObject,
    URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct BillingAccountCreationRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
    let signingPublicKey: String
    let creationSignature: String
}

private struct BillingAccountCreationResponse: Decodable {
    let protocolVersion: Int
    let billingAccountId: String
    let billingKeyId: String
    let createdAt: Int
}

private struct BillingTransactionRequest: Encodable {
    let protocolVersion: Int
    let signedTransactionInfo: String
}

private struct BillingTransactionResponse: Decodable {
    let protocolVersion: Int
    let billingAccountId: String
    let originalTransactionId: String
    let transactionId: String
    let recorded: Bool
    let disposition: BillingTransactionDisposition
    let entitlement: BillingProvisionalEntitlement
}

private struct BillingAuthoritativeEntitlementResponse: Decodable {
    let protocolVersion: Int
    let billingAccountId: String
    let entitlement: BillingAuthoritativeEntitlement
}

private struct BillingAPIErrorResponse: Decodable {
    struct ErrorBody: Decodable {
        let code: String
    }

    let error: ErrorBody
}

private extension BillingValidation {
    static func compactJWS(_ value: String) -> Bool {
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 3 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57)
                    || (byte >= 65 && byte <= 90)
                    || (byte >= 97 && byte <= 122)
                    || byte == 45
                    || byte == 95
            }
        }
    }
}
