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
}

enum MioCloudError: LocalizedError {
    case disabled, invalidServer, invalidToken, keychain, invalidQuestion, invalidContext
    case changedConfiguration, invalidResponse, oversizedResponse, network
    case serverStatus(Int)

    var errorDescription: String? {
        switch self {
        case .disabled: "Molnfrågor är avstängda."
        case .invalidServer: "Ange serverns HTTPS-adress utan sökväg, inloggning, frågetecken eller fragment, till exempel https://mio.example.se."
        case .invalidToken: "Ange serverns separata åtkomsttoken: 32–256 bokstäver, siffror, bindestreck eller understreck. Använd aldrig en OpenAI-nyckel i appen. Vid byte av server krävs en ny token."
        case .keychain: "Kunde inte läsa eller ändra den skyddade åtkomsttokenen. Lås upp telefonen och försök igen."
        case .invalidQuestion: "Skriv en fråga på högst 2 000 UTF-8-byte. Svenska bokstäver kan ta flera byte."
        case .invalidContext: "Välj högst sex utdrag. Varje rubrik får vara högst 200 byte, varje text 4 000 byte och all vald kontext 10 000 byte. Tomma utdrag behöver tas bort eller fyllas i."
        case .changedConfiguration: "Inställningarna ändrades. Förhandsgranska frågan igen."
        case .invalidResponse: "Servern gav inget fullständigt läsbart svar. Försök med en kortare fråga."
        case .oversizedResponse: "Serverns svar var för stort och avbröts."
        case .network: "Kunde inte nå servern. Kontrollera internet, HTTPS-adressen och serverns konfiguration. Inget nytt försök görs automatiskt."
        case .serverStatus(let status):
            switch status {
            case 401, 403: "Servern nekade åtkomst. Kontrollera serverns separata åtkomsttoken."
            case 429: "Serverns frågegräns är nådd. Vänta och försök senare."
            case 504: "Svaret tog för lång tid. Försök senare med en kortare fråga."
            default: "Servern kunde inte besvara frågan. Kontrollera servern och försök senare."
            }
        }
    }
}

@MainActor
enum MioCloudSettings {
    static let enabledKey = "mio.cloud.enabled"
    static let serverKey = "mio.cloud.server"
    static let didResetNotification = Notification.Name("MioCloudSettingsDidReset")
    private static let service = "app.mio.assistant.cloud-gateway"

    static var serverAddress: String { UserDefaults.standard.string(forKey: serverKey) ?? "" }

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

    static func save(serverAddress: String, newToken: String) throws {
        let endpoint = try endpoint(for: serverAddress)
        let normalizedOrigin = endpoint.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        let sameServer = (try? self.endpoint(for: self.serverAddress)) == endpoint
        let token = newToken.isEmpty && sameServer ? try readToken() : newToken
        try validateToken(token)
        try writeToken(token)
        UserDefaults.standard.set(normalizedOrigin, forKey: serverKey)
        NotificationCenter.default.post(name: didResetNotification, object: nil)
    }

    static func connection() throws -> MioCloudConnection {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { throw MioCloudError.disabled }
        let endpoint = try endpoint(for: serverAddress)
        let token = try readToken()
        try validateToken(token)
        return MioCloudConnection(endpoint: endpoint, token: token)
    }

    /// Disable first even if Keychain deletion fails. Credentials are never part of exports.
    static func reset() throws {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: serverKey)
        NotificationCenter.default.post(name: didResetNotification, object: nil)
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MioCloudError.keychain }
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "gateway-token"]
    }

    private static func validateToken(_ token: String) throws {
        guard (32...256).contains(token.utf8.count), !token.hasPrefix("sk-"),
              token.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0)
                      || (48...57).contains($0) || $0 == 45 || $0 == 95
              }) else { throw MioCloudError.invalidToken }
    }

    private static func readToken() throws -> String {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw MioCloudError.invalidToken }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw MioCloudError.keychain }
        return token
    }

    private static func writeToken(_ token: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
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
    static func ask(_ payload: MioCloudRequest, connection: MioCloudConnection) async throws -> String {
        let data = try await send(payload.validatedData(), connection: connection)
        struct Answer: Decodable { let answer: String }
        guard let decoded = try? JSONDecoder().decode(Answer.self, from: data),
              !decoded.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw MioCloudError.invalidResponse }
        return decoded.answer
    }

    static func analyze(_ payload: MioAnalysisRequest, connection: MioCloudConnection) async throws -> MioAnalysisResult {
        let endpoint = connection.endpoint.deletingLastPathComponent().appendingPathComponent("analyze")
        let data = try await send(payload.validatedData(), connection: MioCloudConnection(endpoint: endpoint, token: connection.token))
        guard let result = try? JSONDecoder().decode(MioAnalysisResult.self, from: data) else { throw MioCloudError.invalidResponse }
        try result.validate(against: payload)
        return result
    }

    private static func send(_ body: Data, connection: MioCloudConnection) async throws -> Data {
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

        var request = URLRequest(url: connection.endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request, delegate: MioCloudRedirectGuard())
            guard let response = response as? HTTPURLResponse else { throw MioCloudError.invalidResponse }
            guard response.statusCode == 200 else { throw MioCloudError.serverStatus(response.statusCode) }
            guard response.mimeType == "application/json" else { throw MioCloudError.invalidResponse }
            guard response.expectedContentLength <= 32_768 else { throw MioCloudError.oversizedResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 32_768 else { throw MioCloudError.oversizedResponse }
                data.append(byte)
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MioCloudError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw MioCloudError.network
        }
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
