import Foundation
import Security

struct MioCloudContext: Codable, Equatable, Sendable {
    var label: String
    var text: String
}

struct MioCloudRequest: Codable, Equatable, Sendable {
    let question: String
    let context: [MioCloudContext]

    func validatedData() throws -> Data {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf8.count <= 2_000 else { throw MioCloudError.invalidQuestion }
        guard context.count <= 6,
              context.allSatisfy({
                  !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.label.utf8.count <= 200
                      && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.text.utf8.count <= 4_000
              }),
              context.reduce(0, { $0 + $1.label.utf8.count + $1.text.utf8.count }) <= 10_000
        else { throw MioCloudError.invalidContext }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 20_000 else { throw MioCloudError.invalidContext }
        return data
    }
}

struct MioCloudConnection: Equatable, Sendable {
    let endpoint: URL
    let token: String
    var observedConfigurationRevision: String? = nil

    func hasSameCredentials(as other: Self) -> Bool {
        endpoint == other.endpoint && token == other.token
    }
}

/// The gateway token's Keychain item. Older versions stored a raw token, then JSON that could
/// also hold Cloudflare Access secrets; decoding ignores those and `hasLegacyAccess` finds them.
struct MioCloudCredentials: Codable, Equatable {
    let token: String

    static func decode(_ data: Data) throws -> Self {
        if data.first == 123 { return try JSONDecoder().decode(Self.self, from: data) }
        guard let token = String(data: data, encoding: .utf8) else { throw MioCloudError.keychain }
        return Self(token: token) // Existing installations stored only the gateway token.
    }

    static func hasLegacyAccess(_ data: Data) -> Bool {
        guard data.first == 123, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return Set(object.keys) != ["token"]
    }
}

enum MioCloudError: LocalizedError {
    case disabled, notPaired, invalidServer, invalidToken, keychain, invalidQuestion, invalidContext
    case changedConfiguration, invalidResponse, oversizedResponse, network
    case incompatibleGateway
    case gateway(Int, MioGatewayErrorCode)
    case serverStatus(Int)
    case rateLimited(Int)
    case gatewayRateLimited(MioGatewayErrorCode, Int)

    var errorDescription: String? {
        switch self {
        case .disabled: "AI är pausad."
        case .notPaired: "Para datorn under Inställningar → Dator först."
        case .invalidServer: "Ange serverns HTTPS-adress utan sökväg, inloggning, frågetecken eller fragment, till exempel https://mio.example.se."
        case .invalidToken: "Ange serverns separata åtkomsttoken: 32–256 bokstäver, siffror, bindestreck eller understreck. Använd aldrig en leverantörs API-nyckel i appen. Vid byte av server krävs en ny token."
        case .keychain: "Kunde inte läsa eller ändra de skyddade anslutningsuppgifterna. Lås upp telefonen och försök igen."
        case .invalidQuestion: "Skriv en fråga på högst 2 000 UTF-8-byte. Svenska bokstäver kan ta flera byte."
        case .invalidContext: "Välj högst sex utdrag. Varje rubrik får vara högst 200 byte, varje text 4 000 byte och all vald kontext 10 000 byte. Tomma utdrag behöver tas bort eller fyllas i."
        case .changedConfiguration: "Anslutningen till datorn ändrades. Försök igen."
        case .invalidResponse: "Servern gav inget fullständigt läsbart svar. Försök med en kortare fråga."
        case .oversizedResponse: "Serverns svar var för stort och avbröts."
        case .network: "Kunde inte nå servern. Kontrollera internet, HTTPS-adressen och serverns konfiguration. Inget nytt försök görs automatiskt."
        case .rateLimited(let seconds): "AI-gränsen är nådd. Vänta minst \(seconds) sekunder och fortsätt sedan manuellt. Sparade lektionsdelar finns kvar."
        case .gatewayRateLimited(let code, _): MioCloudError.gateway(429, code).errorDescription
        case .incompatibleGateway: "Gatewayen saknar ett giltigt kontrakt för den valda Mio-uppgiften. Uppdatera eller kontrollera servern innan du fortsätter."
        case .gateway(let status, let code):
            switch code {
            case .gatewayNotConfigured: "AI-gatewayen är inte konfigurerad. Kontrollera att den publicerade serverversionen stöder vald leverantör och modell."
            case .configurationChanged: "Serverns AI-konfiguration ändrades. Granska frågan igen eller aktivera analysen på nytt innan du fortsätter."
            case .taskConfigurationInvalid: "Den valda AI-uppgiften är felkonfigurerad. Kontrollera dess leverantör, modell och krav på servern."
            case .providerAuthentication: "AI-leverantören nekade serverns inloggningsuppgifter. Kontrollera den serverägda nyckeln."
            case .providerAccount: "AI-kontot saknar åtkomst eller är blockerat. Kontrollera kontot hos leverantören."
            case .providerModelUnavailable: "Den valda modellen är inte tillgänglig för serverns konto. Kontrollera modellåtkomsten."
            case .providerParameters: "AI-leverantören accepterade inte serverns modellinställningar. Kontrollera uppgiftens profil."
            case .providerRefusal: "AI-leverantören avstod från att besvara underlaget. Inget innehåll har godkänts från svaret."
            case .providerTruncated: "AI-svaret avbröts innan det var fullständigt. Inget innehåll har godkänts från svaret."
            case .localMinuteLimit: "Mios gemensamma minutgräns är nådd. Vänta och fortsätt manuellt senare."
            case .localDayLimit: "Mios gemensamma dagsgräns är nådd. AI fortsätter efter nästa återställning."
            case .localTokenLimit: "Dagens AI-token är slut. AI fortsätter efter nästa återställning."
            case .localConcurrencyLimit: "Servern behandlar redan så många AI-anrop som tillåts. Vänta och fortsätt manuellt senare."
            case .localRequestLimit: "Mios gemensamma AI-kvot nekade anropet. Vänta och fortsätt manuellt senare."
            case .providerQuota: "AI-leverantörens kvot är nådd. Kontrollera kontot och fortsätt manuellt senare."
            case .budgetStoreFailed: "Servern kunde inte kontrollera den gemensamma AI-kvoten. Inget nytt försök görs automatiskt."
            case .providerModelIncompatible: "Modellen stöder inte Mios krav: reasoning av, temperatur 0 och strikt JSON-schema."
            case .upstreamTimeout, .requestTimeout: "AI-anropet tog för lång tid. Fortsätt manuellt senare; inget nytt försök görs automatiskt."
            case .rateLimited, .dailyLimitReached, .requestLimit: "AI-kvoten är nådd. Vänta och fortsätt manuellt senare."
            case .invalidUpstreamAnswer, .invalidUpstreamResponse, .incompleteUpstreamResponse, .invalidAnalysisResult, .invalidLessonResult, .providerInvalidResponse: "AI-leverantören gav ett ogiltigt svar. Inget innehåll har godkänts från svaret."
            case .upstreamUnavailable, .providerInfrastructure: "AI-leverantören kunde inte nås. Kontrollera gatewayens leverantörsinställningar och försök senare."
            case .providerTransport: "Servern kunde inte upprätta anslutningen till AI-leverantören. Kontrollera anslutningen och fortsätt manuellt senare."
            default: MioCloudError.serverStatus(status).errorDescription
            }
        case .serverStatus(let status):
            switch status {
            case 401, 403: "Datorn nekade åtkomst. Para om med en ny kod från mio-pair."
            case 300...399: "Servern hänvisade till en annan adress. Mio följer inte omdirigeringar; para om med en ny kod från mio-pair."
            case 422: "Modellen stöder inte Mios krav: reasoning av, temperatur 0 och strikt JSON-schema. Kontrollera modellvalet på datorn."
            case 429: "Serverns frågegräns är nådd. Vänta och försök senare."
            case 504: "Svaret tog för lång tid. Försök senare med en kortare fråga."
            default: "Servern kunde inte besvara frågan. Kontrollera servern och försök senare."
            }
        }
    }
}

@MainActor
enum MioCloudSettings {
    static let serverKey = "mio.cloud.server"
    static let didResetNotification = Notification.Name("MioCloudSettingsDidReset")
    private static let service = "app.mio.assistant.cloud-gateway"
    private static let legacyAccessRemovedKey = "mio.cloud.legacyAccessRemoved.v1"

    static var serverAddress: String { UserDefaults.standard.string(forKey: serverKey) ?? "" }
    /// Paired means an AI gateway origin is saved; the token itself is checked on use.
    static var isPaired: Bool { (try? endpoint(for: serverAddress)) != nil }

    static func endpoint(for address: String) throws -> URL {
        let clean = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: clean),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let origin = components.url else { throw MioCloudError.invalidServer }
        return origin.appendingPathComponent("v1").appendingPathComponent("ask")
    }

    /// Saves one PC pairing: the AI gateway and, when present, Pianissimo. A pairing without
    /// transcription keeps an existing Pianissimo connection on the same PC and forgets one on
    /// another host. Tokens stay in the Keychain; nothing else stores them.
    static func savePairing(_ payload: MioPairingPayload) throws {
        try save(serverAddress: payload.aiOrigin.absoluteString, token: payload.aiToken)
        if let origin = payload.transcriptionOrigin, let token = payload.transcriptionToken {
            try TranscriptionSettings.save(address: origin.absoluteString, token: token)
        } else if let saved = try? TranscriptionSettings.origin(TranscriptionSettings.address),
                  saved.host != payload.aiOrigin.host {
            try TranscriptionSettings.reset()
        }
        MioAIPreference.setEnabled(true, in: .standard)
    }

    static func save(serverAddress: String, token: String) throws {
        let endpoint = try endpoint(for: serverAddress)
        let normalizedOrigin = endpoint.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        try validateToken(token)
        try writeCredentials(MioCloudCredentials(token: token))
        UserDefaults.standard.set(normalizedOrigin, forKey: serverKey)
        MioConnectionDiscovery.shared.invalidate()
        NotificationCenter.default.post(name: didResetNotification, object: nil)
    }

    static func connection() throws -> MioCloudConnection {
        guard !serverAddress.isEmpty else { throw MioCloudError.notPaired }
        let endpoint = try endpoint(for: serverAddress)
        let credentials = try readCredentials()
        try validateToken(credentials.token)
        return MioCloudConnection(endpoint: endpoint, token: credentials.token)
    }

    /// Forget the pairing first even if Keychain deletion fails. Credentials are never part of exports.
    static func reset() throws {
        UserDefaults.standard.removeObject(forKey: serverKey)
        MioConnectionDiscovery.shared.invalidate()
        NotificationCenter.default.post(name: didResetNotification, object: nil)
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MioCloudError.keychain }
    }

    /// One-time upgrade step: Cloudflare Access is gone (2026-10-11). Rewrites the gateway item
    /// without stored Access secrets and drops the old "Tillåt molnfrågor" switch. Retried on the
    /// next launch while the Keychain is locked.
    static func removeLegacyAccessOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: legacyAccessRemovedKey) else { return }
        if defaults.object(forKey: MioAIPreference.enabledKey) == nil, !serverAddress.isEmpty {
            // A gateway saved before QR pairing existed starts paused; pairing the PC switches AI on.
            MioAIPreference.setEnabled(false, in: defaults)
        }
        defaults.removeObject(forKey: MioAIPreference.legacyCloudEnabledKey)
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { defaults.set(true, forKey: legacyAccessRemovedKey); return }
        guard status == errSecSuccess, let data = result as? Data else { return }
        if MioCloudCredentials.hasLegacyAccess(data) {
            if let credentials = try? MioCloudCredentials.decode(data) {
                guard (try? writeCredentials(credentials)) != nil else { return }
            } else {
                guard SecItemDelete(keychainQuery as CFDictionary) == errSecSuccess else { return }
                defaults.removeObject(forKey: serverKey)
            }
        }
        defaults.set(true, forKey: legacyAccessRemovedKey)
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "gateway-token"]
    }

    private static func validateToken(_ token: String) throws {
        guard MioPairingPayload.isValidToken(token) else { throw MioCloudError.invalidToken }
    }

    private static func readCredentials() throws -> MioCloudCredentials {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw MioCloudError.invalidToken }
        guard status == errSecSuccess, let data = result as? Data else { throw MioCloudError.keychain }
        do { return try MioCloudCredentials.decode(data) }
        catch { throw MioCloudError.keychain }
    }

    private static func writeCredentials(_ credentials: MioCloudCredentials) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(credentials),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let query = keychainQuery.merging(attributes) { _, new in new }
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MioCloudError.keychain }
    }
}

enum MioCloudService {
    typealias ByteTransport = @Sendable (URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse)

    static func statusV2(connection: MioCloudConnection, transport: ByteTransport? = nil) async throws -> MioGatewayStatusV2 {
        let origin = connection.endpoint.deletingLastPathComponent().deletingLastPathComponent()
        let target = MioCloudConnection(endpoint: origin.appendingPathComponent("v2/status"), token: connection.token)
        do {
            return try await perform(operation: .statusV2, connection: target, body: { Data() }, method: "GET",
                                     transport: transport) { try MioGatewayStatusV2.decode($0) }
        } catch MioCloudError.serverStatus(404) { throw MioCloudError.incompatibleGateway }
        catch MioCloudError.gateway(404, .notFound) { throw MioCloudError.incompatibleGateway }
    }

    static func ask(_ payload: MioCloudRequest, connection: MioCloudConnection, transport: ByteTransport? = nil) async throws -> String {
        try await perform(operation: .ask, connection: connection, body: { try payload.validatedData() }, transport: transport) { data in
            struct Answer: Decodable { let answer: String }
            try validateWire(data, lesson: false, ask: true)
            guard let decoded = try? JSONDecoder().decode(Answer.self, from: data),
                  !decoded.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, decoded.answer.utf8.count <= 16_000
            else { throw MioCloudError.invalidResponse }
            return decoded.answer
        }
    }

    static func status(connection: MioCloudConnection, transport: ByteTransport? = nil) async throws -> MioGatewayStatus {
        let origin = connection.endpoint.deletingLastPathComponent().deletingLastPathComponent()
        let target = MioCloudConnection(endpoint: origin.appendingPathComponent("v1/status"), token: connection.token)
        do {
            return try await perform(operation: .status, connection: target, body: { Data() }, method: "GET", transport: transport) { try MioGatewayStatus.decode($0) }
        } catch MioCloudError.serverStatus(404) { throw MioCloudError.incompatibleGateway }
        catch MioCloudError.gateway(404, .notFound) { throw MioCloudError.incompatibleGateway }
    }

    static func analyze(_ payload: MioAnalysisRequest, connection: MioCloudConnection, transport: ByteTransport? = nil) async throws -> MioAnalysisResult {
        let contextContract = payload.mode == .everyday && payload.usesContextContract
        let origin = connection.endpoint.deletingLastPathComponent().deletingLastPathComponent()
        let route = payload.mode == .lesson ? "v1/lesson-notes" : contextContract ? "v2/analyze" : "v1/analyze"
        let target = MioCloudConnection(endpoint: origin.appendingPathComponent(route), token: connection.token,
            observedConfigurationRevision: connection.observedConfigurationRevision)
        var event = MioDiagnosticEvent(operation: payload.mode == .lesson ? .lessonNotes : contextContract ? .analyzeContext : .analyze)
        event.newFragmentCount = payload.fragments.count
        event.contextFragmentCount = payload.contextFragments.count
        event.contextLimited = payload.contextLimited
        event.queueSize = payload.queueSize
        let dates = payload.allFragments.compactMap { ISO8601DateFormatter().date(from: $0.occurredAt) }
        event.sourceStart = dates.min(); event.sourceEnd = dates.max()
        return try await perform(operation: event.operation, connection: target, body: { try payload.validatedData() }, event: event,
                                 beforeSend: contextContract ? {
                                     let discovery: MioGatewayStatusV2
                                     if let transport { discovery = try await statusV2(connection: connection, transport: transport) }
                                     else { discovery = try await MioConnectionDiscovery.shared.prepare(connection: connection, task: .everyday).status }
                                     if let observed = connection.observedConfigurationRevision,
                                        observed != discovery.configurationRevision {
                                         throw MioCloudError.gateway(409, .configurationChanged)
                                     }
                                     try discovery.requireTask(.everyday)
                                 } : nil,
                                 transport: transport) { data in
            try validateWire(data, lesson: payload.mode == .lesson, contextContract: contextContract)
            let result: MioAnalysisResult
            if payload.mode == .lesson {
                struct LessonReply: Decodable {
                    let candidates: [MioAnalysisCandidate]
                    let sections: [MioLessonSection]
                    let uncertainties: [String]
                    let metadata: MioAnalysisMetadata
                }
                guard let reply = try? JSONDecoder().decode(LessonReply.self, from: data) else { throw MioCloudError.invalidResponse }
                result = MioAnalysisResult(candidates: reply.candidates, highlights: [], uncertainties: reply.uncertainties,
                                           sections: reply.sections, metadata: reply.metadata)
            } else {
                guard let reply = try? JSONDecoder().decode(MioAnalysisResult.self, from: data) else { throw MioCloudError.invalidResponse }
                result = reply
            }
            try result.validate(against: payload)
            return result
        }
    }

    private static func perform<T: Sendable>(operation: MioDiagnosticOperation, connection: MioCloudConnection,
        body: () throws -> Data, method: String = "POST", event suppliedEvent: MioDiagnosticEvent? = nil,
        beforeSend: (() async throws -> Void)? = nil, transport: ByteTransport? = nil, validate: (Data) throws -> T) async throws -> T {
        try Task.checkCancellation()
        var event = suppliedEvent ?? MioDiagnosticEvent(operation: operation)
        let started = ContinuousClock.now
        let token = await MioDiagnosticsRepository.shared.beginRequest()
        do {
            let body = try body(); event.requestBytes = body.count
            try Task.checkCancellation()
            if method == "POST", MioGatewayMetadata.revision(connection.observedConfigurationRevision) == nil {
                throw MioCloudError.changedConfiguration
            }
            try await beforeSend?()
            let data = try await send(body, connection: connection, method: method, event: &event, transport: transport)
            try Task.checkCancellation()
            let result = try validate(data)
            try Task.checkCancellation()
            event.outcome = .success
            event.durationMilliseconds = elapsedMilliseconds(since: started)
            await MioDiagnosticsRepository.shared.record(event, generation: token)
            return result
        } catch {
            event.durationMilliseconds = elapsedMilliseconds(since: started)
            if case let MioCloudError.gateway(_, code) = error { event.gatewayCode = code }
            if case let MioCloudError.gatewayRateLimited(code, seconds) = error {
                event.gatewayCode = code; event.retryAfterSeconds = seconds
            }
            if error is CancellationError || Task.isCancelled { event.outcome = .cancelled }
            else if event.outcome == .success { event.outcome = .validationFailed }
            await MioDiagnosticsRepository.shared.record(event, generation: token)
            // Discovery owns its status request's failure. Invalidating here would answer its
            // waiters with "settings changed" and drop the real 401/403 explanation.
            if operation != .statusV2 { await MioConnectionDiscovery.shared.handle(error: error) }
            throw error
        }
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return max(0, Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000))
    }

    // Codable ignores unknown keys; validate the wire shape before decoding it.
    static func validateWire(_ data: Data, lesson: Bool, ask: Bool = false, contextContract: Bool = false) throws {
        func exact(_ value: Any?, _ keys: Set<String>) -> Bool {
            guard let object = value as? [String: Any] else { return false }
            return Set(object.keys) == keys
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MioCloudError.invalidResponse
        }
        if ask {
            guard exact(root, ["answer"]) else { throw MioCloudError.invalidResponse }
            return
        }
        let expected: Set<String> = lesson ? ["candidates", "sections", "uncertainties", "metadata"]
            : ["candidates", "highlights", "uncertainties"]
        guard exact(root, expected), let candidates = root["candidates"] as? [[String: Any]],
              candidates.allSatisfy({ exact($0, contextContract
                  ? ["kind", "title", "body", "scheduledAt", "sourceIDs", "evidence", "replacesID"]
                  : ["kind", "title", "body", "scheduledAt", "sourceIDs", "evidence"]) })
        else { throw MioCloudError.invalidResponse }
        if lesson {
            guard let sections = root["sections"] as? [[String: Any]],
                  sections.allSatisfy({ exact($0, ["heading", "body", "sourceIDs", "evidence"]) }),
                  exact(root["metadata"], ["provider", "model", "promptVersion", "lessonIntervalSeconds"])
            else { throw MioCloudError.invalidResponse }
        } else {
            guard let highlights = root["highlights"] as? [[String: Any]],
                  highlights.allSatisfy({ exact($0, ["text", "sourceIDs", "evidence"]) })
            else { throw MioCloudError.invalidResponse }
        }
    }

    static func makeRequest(_ body: Data, connection: MioCloudConnection, method: String = "POST") throws -> URLRequest {
        var request = URLRequest(url: connection.endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        if method == "POST", let revision = connection.observedConfigurationRevision {
            guard MioGatewayMetadata.revision(revision) != nil else { throw MioCloudError.changedConfiguration }
            request.setValue(revision, forHTTPHeaderField: "X-Mio-Configuration-Revision")
        }
        request.httpBody = method == "GET" ? nil : body
        return request
    }

    static func gatewayCode(from data: Data) -> MioGatewayErrorCode? {
        guard data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["error"], let code = object["error"] as? String else { return nil }
        return MioGatewayErrorCode(rawValue: code)
    }

    /// Numeric or IMF-fixdate Retry-After, bounded to 1 s ... 1 day. Nil when absent or invalid.
    static func retryAfterSeconds(_ value: String?, now: Date = .now) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.count <= 10, let numeric = Int(value) { return min(86_400, max(1, numeric)) }
        guard value.utf8.count <= 64 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let deadline = formatter.date(from: value) else { return nil }
        return Int(min(86_400, max(1, ceil(deadline.timeIntervalSince(now)))))
    }

    static func httpFailure(response: HTTPURLResponse, body: Data, now: Date = .now) -> (error: MioCloudError, code: MioGatewayErrorCode?, retryAfterSeconds: Int?) {
        let code = response.mimeType == "application/json" ? gatewayCode(from: body) : nil
        if response.statusCode == 429 {
            let bounded = retryAfterSeconds(response.value(forHTTPHeaderField: "Retry-After"), now: now) ?? 60
            if let code, [.localMinuteLimit, .localDayLimit, .localTokenLimit, .localConcurrencyLimit, .localRequestLimit,
                          .providerQuota].contains(code) {
                return (.gatewayRateLimited(code, bounded), code, bounded)
            }
            return (.rateLimited(bounded), code, bounded)
        }
        if (300...399).contains(response.statusCode) {
            return (.serverStatus(response.statusCode), code, nil)
        }
        if [401, 403].contains(response.statusCode), code != .providerAuthentication, code != .providerAccount {
            return (.serverStatus(response.statusCode), code, nil)
        }
        if let code { return (.gateway(response.statusCode, code), code, nil) }
        return (.serverStatus(response.statusCode), nil, nil)
    }

    private static func send(_ body: Data, connection: MioCloudConnection, method: String,
                             event: inout MioDiagnosticEvent, transport: ByteTransport?) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 55
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = try makeRequest(body, connection: connection, method: method)
        do {
            try Task.checkCancellation()
            if let transport {
                let (bytes, response) = try await transport(request)
                return try await readResponse(bytes, response: response, event: &event)
            }
            let (bytes, response) = try await session.bytes(for: request, delegate: MioCloudRedirectGuard())
            return try await readResponse(bytes, response: response, event: &event)
        } catch is CancellationError { throw CancellationError() }
        catch let error as MioCloudError { throw error }
        catch {
            let nsError = error as NSError
            if Task.isCancelled || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                throw CancellationError()
            }
            event.outcome = .networkError
            if let domain = MioDiagnosticNetworkDomain(rawValue: nsError.domain), (-10_000...10_000).contains(nsError.code) {
                event.networkDomain = domain; event.networkCode = nsError.code
            }
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                throw MioCloudError.gateway(504, .upstreamTimeout)
            }
            throw MioCloudError.network
        }
    }
    /// Native AsyncBytes stays demand-driven; injection replaces only the transport.
    private static func readResponse<Bytes: AsyncSequence>(_ bytes: Bytes, response: URLResponse,
        event: inout MioDiagnosticEvent) async throws -> Data where Bytes.Element == UInt8 {
        guard let response = response as? HTTPURLResponse else { throw MioCloudError.invalidResponse }
        event.httpStatus = response.statusCode
        if (0...1_000_000_000).contains(response.expectedContentLength) {
            event.expectedResponseBytes = Int(response.expectedContentLength)
        }
        event.gateway = MioGatewayMetadata(response: response)
        let successful = response.statusCode == 200
        let cap = successful ? (event.operation == .statusV2 ? MioGatewayStatusV2.maxResponseBytes : event.operation == .status ? 4096 : 32_768) : 4096
        var data = Data()
        if successful {
            guard response.mimeType == "application/json" else { throw MioCloudError.invalidResponse }
            guard response.expectedContentLength <= cap else {
                event.responseTruncated = true
                throw MioCloudError.oversizedResponse
            }
        }
        // Error bodies are read only as bounded JSON; never expose HTML or provider error details.
        var exceeded = !successful && response.expectedContentLength > cap
        event.responseTruncated = exceeded
        if !exceeded {
            for try await byte in bytes {
                try Task.checkCancellation()
                event.responseBytes += 1
                if data.count == cap {
                    exceeded = true
                    event.responseTruncated = true
                    if successful { throw MioCloudError.oversizedResponse }
                    break
                }
                data.append(byte)
            }
        }
        guard successful else {
            event.outcome = .httpError
            let failure = httpFailure(response: response, body: exceeded ? Data() : data)
            event.gatewayCode = failure.code
            event.retryAfterSeconds = failure.retryAfterSeconds
            throw failure.error
        }
        return data
    }

}

/// Never forward the gateway credential or approved text to a redirect target.
private final class MioCloudRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
