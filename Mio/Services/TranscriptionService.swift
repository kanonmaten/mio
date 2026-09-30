import Foundation
import Security

struct TranscriptionConnection: Sendable {
    let origin: URL
    let token: String
}

@MainActor
enum TranscriptionSettings {
    static let serverKey = "mio.transcription.server"
    static let didChange = Notification.Name("MioTranscriptionConnectionChanged")
    static var address: String { UserDefaults.standard.string(forKey: serverKey) ?? "" }
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.mio.assistant.transcription",
         kSecAttrAccount as String: "access-token"]
    }
    static func origin(_ address: String) throws -> URL {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
              host.hasSuffix(".ts.net"), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.port == nil || parts.port == 443,
              parts.path.isEmpty || parts.path == "/" else { throw TranscriptionError.invalidAddress }
        parts.host = host; parts.scheme = "https"; parts.path = ""; parts.port = nil
        guard let url = parts.url else { throw TranscriptionError.invalidAddress }
        return url
    }
    static func validateToken(_ token: String) throws {
        guard (32...256).contains(token.utf8.count), token.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw TranscriptionError.invalidToken }
    }
    static func connection() throws -> TranscriptionConnection {
        guard !address.isEmpty else { throw TranscriptionError.notConfigured }
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8)
        else { throw TranscriptionError.keychain }
        try validateToken(token)
        return TranscriptionConnection(origin: try origin(address), token: token)
    }
    static var hasToken: Bool { (try? connection()) != nil }
    static func save(address: String, token: String) throws {
        let url = try origin(address)
        let sameOrigin = (try? origin(self.address)) == url
        let saved = token.isEmpty && sameOrigin ? try connection().token : token
        try validateToken(saved)
        let attributes: [String: Any] = [kSecValueData as String: Data(saved.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TranscriptionError.keychain }
        UserDefaults.standard.set(url.absoluteString, forKey: serverKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
    static func reset() throws {
        UserDefaults.standard.removeObject(forKey: serverKey)
        NotificationCenter.default.post(name: didChange, object: nil)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TranscriptionError.keychain }
    }
}

private final class TranscriptionRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Credentials belong to one immutable origin. Neither cookies, disk cache nor redirects are used.
final class TranscriptionClient: @unchecked Sendable {
    private let session: URLSession
    private let connection: TranscriptionConnection
    init(connection: TranscriptionConnection, protocolClasses: [AnyClass]? = nil) {
        self.connection = connection
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = protocolClasses
        config.urlCache = nil; config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 50
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: TranscriptionRedirectGuard(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func cancel() { session.invalidateAndCancel() }

    func health() async throws -> TranscriptionHealth {
        let result: TranscriptionHealth = try await send(path: "health", chunk: nil)
        try result.validate()
        return result
    }
    func transcribe(_ chunk: AudioChunk) async throws -> TranscriptionReply {
        try await send(path: "v1/transcribe", chunk: chunk)
    }
    private func send<T: Decodable>(path: String, chunk: AudioChunk?) async throws -> T {
        var request = URLRequest(url: connection.origin.appendingPathComponent(path))
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let chunk {
            request.httpMethod = "POST"; request.httpBody = chunk.wave; request.timeoutInterval = 48
            request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
            let headers = ["Session-ID": chunk.sessionID.uuidString, "Chunk-ID": chunk.id.uuidString,
                           "Sequence": String(chunk.sequence), "Start-Sample": String(chunk.startSample),
                           "Core-Start": String(chunk.coreStart), "Core-End": String(chunk.coreEnd)]
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: "X-Mio-\(key)") }
        }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }
        guard response.statusCode == 200 else {
            let retry = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "5") ?? 5
            throw TranscriptionError.http(response.statusCode, retryAfter: retry.isFinite ? retry : 5)
        }
        guard response.mimeType == "application/json", response.expectedContentLength <= 262_144
        else { throw TranscriptionError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 262_144 else { throw TranscriptionError.invalidResponse }
            data.append(byte)
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw TranscriptionError.invalidResponse }
        return decoded
    }
}
