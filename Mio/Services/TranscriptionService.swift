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

private final class TranscriptionOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var data = Data()
    private var completed: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?

    func bind(_ task: URLSessionDataTask) { lock.withLock { self.task = task } }
    func receive(_ part: Data) -> Bool {
        lock.withLock {
            guard completed == nil, data.count + part.count <= 262_144 else { return false }
            data.append(part); return true
        }
    }
    func finish(_ error: Error? = nil) {
        let callback: (CheckedContinuation<Data, Error>?, Result<Data, Error>)? = lock.withLock {
            guard completed == nil else { return nil }
            let result: Result<Data, Error> = error.map { .failure($0) } ?? .success(data)
            completed = result; data.removeAll(keepingCapacity: false); task = nil
            let callback = continuation; continuation = nil
            return (callback, result)
        }
        if let (continuation, result) = callback { continuation?.resume(with: result) }
    }
    func cancel() {
        let task = lock.withLock { self.task }
        task?.cancel(); finish(CancellationError())
    }
    func decoded<T: Decodable>(_ type: T.Type) async throws -> T {
        let bytes = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let result: Result<Data, Error>? = lock.withLock {
                    if let completed { return completed }
                    self.continuation = continuation; return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: { self.cancel() }
        guard let reply = try? JSONDecoder().decode(type, from: bytes) else {
            throw TranscriptionError.invalidResponse
        }
        return reply
    }
}

private final class TranscriptionRedirectGuard: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [Int: TranscriptionOperation] = [:]
    func register(_ operation: TranscriptionOperation, task: URLSessionDataTask) {
        lock.withLock { operations[task.taskIdentifier] = operation }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let operation = lock.withLock({ operations[dataTask.taskIdentifier] }) else {
            completionHandler(.allow); return
        }
        guard let response = response as? HTTPURLResponse else {
            operation.finish(TranscriptionError.invalidResponse); completionHandler(.cancel); return
        }
        guard response.statusCode == 200 else {
            MioLog.error(.transcription, "transcription http status", value: response.statusCode)
            // Numeric and HTTP-date forms share the gateway parser; retryDelay bounds the wait.
            let delay = MioCloudService.retryAfterSeconds(response.value(forHTTPHeaderField: "Retry-After")) ?? 5
            operation.finish(TranscriptionError.http(response.statusCode, retryAfter: Double(delay)))
            completionHandler(.cancel); return
        }
        guard response.mimeType == "application/json", response.expectedContentLength <= 262_144 else {
            operation.finish(TranscriptionError.invalidResponse); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let operation = lock.withLock({ operations[dataTask.taskIdentifier] }) else { return }
        if !operation.receive(data) { operation.finish(TranscriptionError.invalidResponse); dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { operations.removeValue(forKey: task.taskIdentifier) }?.finish(error)
    }
}

private struct TranscriptionSessionEnded: Decodable {}

/// Credentials belong to one immutable origin. Neither cookies, disk cache nor redirects are used.
final class TranscriptionClient: TranscriptionTransport, @unchecked Sendable {
    private let session: URLSession
    private let connection: TranscriptionConnection
    private let delegate = TranscriptionRedirectGuard()
    init(connection: TranscriptionConnection, protocolClasses: [AnyClass]? = nil) {
        self.connection = connection
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = protocolClasses
        config.urlCache = nil; config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 50
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func cancel() { session.invalidateAndCancel() }

    func health() async throws -> TranscriptionHealth {
        let operation = start(path: "health", chunk: nil)
        let result = try await operation.decoded(TranscriptionHealth.self)
        try result.validate()
        return result
    }
    func startTranscription(_ chunk: AudioChunk) -> Task<TranscriptionReply, Error> {
        let operation = start(path: "v1/transcribe", chunk: chunk)
        // URLSession owns transport bytes; no suspended application task captures the chunk/request.
        return Task { try await operation.decoded(TranscriptionReply.self) }
    }
    func endSession(_ sessionID: UUID) async {
        // 204 surfaces as a non-200 error from the response guard; any outcome is fine here.
        let operation = start(path: "v1/sessions/\(sessionID.uuidString)", chunk: nil, method: "DELETE")
        _ = try? await operation.decoded(TranscriptionSessionEnded.self)
    }
    private func start(path: String, chunk: AudioChunk?, method: String? = nil) -> TranscriptionOperation {
        var request = URLRequest(url: connection.origin.appendingPathComponent(path))
        if let method { request.httpMethod = method; request.timeoutInterval = 5 }
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
        let operation = TranscriptionOperation()
        let task = session.dataTask(with: request)
        operation.bind(task); delegate.register(operation, task: task); task.resume()
        return operation
    }
}
