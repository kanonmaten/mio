import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor enum MioDiagnosticsRuntime {
    static var analysisEnabled = false
}

enum MioDiagnosticRoute: String, Codable, Sendable {
    case ask = "/v1/ask", analyze = "/v1/analyze", analyzeContext = "/v2/analyze"
    case lessonNotes = "/v1/lesson-notes", status = "/v1/status"
}

enum MioDiagnosticOperation: String, Codable, Sendable { case ask, analyze, analyzeContext, lessonNotes, status }
enum MioDiagnosticOutcome: String, Codable, Sendable { case success, cancelled, httpError, networkError, validationFailed }
enum MioDiagnosticsStorageStatus: String, Codable, Sendable { case available, writeFailed, readFailed, unsupportedSchema }
enum MioGatewayErrorCode: String, Codable, Sendable {
    case gatewayNotConfigured = "gateway_not_configured"
    case unauthorized, notFound = "not_found"
    case jsonRequired = "json_required", requestTooLarge = "request_too_large", requestTimeout = "request_timeout"
    case invalidRequest = "invalid_request", invalidContext = "invalid_context", invalidJSON = "invalid_json"
    case requestLimit = "request_limit", incompleteUpstreamResponse = "incomplete_upstream_response"
    case invalidAnalysisResult = "invalid_analysis_result", invalidLessonResult = "invalid_lesson_result"
    case providerModelIncompatible = "provider_model_incompatible"
    case upstreamUnavailable = "upstream_unavailable"
    case upstreamTimeout = "upstream_timeout"
    case invalidUpstreamAnswer = "invalid_upstream_answer"
    case invalidUpstreamResponse = "invalid_upstream_response"
    case upstreamResponseTooLarge = "upstream_response_too_large"
    case rateLimited = "rate_limited"
    case dailyLimitReached = "daily_limit_reached"
    case requestFailed = "request_failed"
}

/// Only bounded protocol identifiers are accepted; never arbitrary headers or descriptions.
struct MioGatewayMetadata: Codable, Sendable {
    static let providers = ["openai", "groq", "vercel", "gemini", "anthropic", "openrouter", "mistral", "deepseek", "custom"]
    private(set) var requestID: String?
    private(set) var cfRay: String?
    private(set) var release: String?
    private(set) var provider: String?
    private(set) var model: String?
    private(set) var promptVersion: String?

    init(response: HTTPURLResponse) {
        requestID = response.value(forHTTPHeaderField: "X-Mio-Request-Id").flatMap { UUID(uuidString: $0)?.uuidString }
        cfRay = response.value(forHTTPHeaderField: "CF-Ray").flatMap(Self.validRay)
        release = Self.identifier(response.value(forHTTPHeaderField: "X-Mio-Release"))
        let candidate = response.value(forHTTPHeaderField: "X-Mio-Provider")
        provider = Self.providers.contains(candidate ?? "") ? candidate : nil
        model = Self.identifier(response.value(forHTTPHeaderField: "X-Mio-Model"))
        promptVersion = Self.identifier(response.value(forHTTPHeaderField: "X-Mio-Prompt-Version"))
    }

    func sanitized() -> Self {
        var result = self
        result.requestID = requestID.flatMap { UUID(uuidString: $0)?.uuidString }
        result.cfRay = cfRay.flatMap(Self.validRay)
        result.release = Self.identifier(release)
        result.provider = Self.providers.contains(provider ?? "") ? provider : nil
        result.model = Self.identifier(model)
        result.promptVersion = Self.identifier(promptVersion)
        return result
    }

    static func identifier(_ value: String?) -> String? {
        guard let value, (1...150).contains(value.utf8.count),
              !value.hasPrefix("sk-"), !value.hasPrefix("gsk_"),
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || [45, 46, 47, 58, 95].contains($0) }) else { return nil }
        return value
    }

    private static func validRay(_ value: String) -> String? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, (8...32).contains(parts[0].count), parts[1].count == 3,
              parts[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              parts[1].utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return value
    }
}

enum MioDiagnosticNetworkDomain: String, Codable, Sendable { case url = "NSURLErrorDomain", posix = "NSPOSIXErrorDomain", cocoa = "NSCocoaErrorDomain" }

struct MioDiagnosticEvent: Codable, Sendable {
    let id: UUID
    let operation: MioDiagnosticOperation
    let route: MioDiagnosticRoute
    let startedAt: Date
    var durationMilliseconds: Int = 0
    var requestBytes: Int = 0
    var responseBytes: Int = 0
    var expectedResponseBytes: Int?
    var responseTruncated = false
    var outcome: MioDiagnosticOutcome = .success
    var httpStatus: Int?
    var gatewayCode: MioGatewayErrorCode?
    var retryAfterSeconds: Int?
    var networkDomain: MioDiagnosticNetworkDomain?
    var networkCode: Int?
    var gateway: MioGatewayMetadata?
    var newFragmentCount: Int?
    var contextFragmentCount: Int?
    var sourceStart: Date?
    var sourceEnd: Date?
    var queueSize: Int?
    var contextLimited: Bool?

    init(operation: MioDiagnosticOperation, startedAt: Date = .now, requestBytes: Int = 0) {
        id = UUID(); self.operation = operation; self.startedAt = startedAt; self.requestBytes = max(0, requestBytes)
        route = Self.route(for: operation)
    }

    /// Fixed route comes from the operation, never the configurable origin/query.
    private static func route(for operation: MioDiagnosticOperation) -> MioDiagnosticRoute {
        switch operation {
        case .ask: .ask
        case .analyze: .analyze
        case .analyzeContext: .analyzeContext
        case .lessonNotes: .lessonNotes
        case .status: .status
        }
    }

    var isValid: Bool {
        route == Self.route(for: operation) && startedAt.timeIntervalSince1970.isFinite
            && (0...86_400_000).contains(durationMilliseconds)
            && (0...20_000).contains(requestBytes) && (0...32_769).contains(responseBytes)
            && (expectedResponseBytes == nil || (0...1_000_000_000).contains(expectedResponseBytes!))
            && (httpStatus == nil || (100...599).contains(httpStatus!))
            && (retryAfterSeconds == nil || (1...86_400).contains(retryAfterSeconds!))
            && (networkCode == nil || (networkDomain != nil && (-10_000...10_000).contains(networkCode!)))
            && [newFragmentCount, contextFragmentCount].allSatisfy { $0 == nil || (0...1_000_000).contains($0!) }
            && (queueSize == nil || (0...1_000_000).contains(queueSize!))
    }
}

struct MioDiagnosticsStoreDocument: Codable, Sendable {
    let schemaVersion: Int
    var events: [MioDiagnosticEvent]
    init(events: [MioDiagnosticEvent]) { schemaVersion = 1; self.events = events }
}

struct MioDiagnosticsSnapshot: Codable, Sendable {
    let events: [MioDiagnosticEvent]
    let storageStatus: MioDiagnosticsStorageStatus
}

struct MioDiagnosticsConfiguration: Codable, Sendable {
    let cloudEnabled: Bool
    var analysisEnabled: Bool = false
    let serverConfigured: Bool
    let accessConfigured: Bool
}

struct MioDiagnosticsExport: Codable, Sendable {
    let appVersion: String
    let build: String
    let systemVersion: String
    let machineIdentifier: String
    let timeZone: String
    let configuration: MioDiagnosticsConfiguration
    let journal: MioDiagnosticsSnapshot

    init(configuration: MioDiagnosticsConfiguration, journal: MioDiagnosticsSnapshot) {
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        systemVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        var info = utsname()
        uname(&info)
        let machineSize = MemoryLayout.size(ofValue: info.machine)
        machineIdentifier = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: machineSize) { String(cString: $0) }
        }
        timeZone = TimeZone.current.identifier
        self.configuration = configuration; self.journal = journal
    }
}

struct MioGatewayStatus: Decodable, Sendable {
    let protocolVersion: Int
    let release: String
    let configured: Bool
    let provider: String
    let model: String
    let promptVersion: String
    let capabilities: [String]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["protocolVersion", "release", "configured", "provider", "model", "promptVersion", "capabilities"],
              let value = try? JSONDecoder().decode(Self.self, from: data), value.protocolVersion == 2,
              MioGatewayMetadata.identifier(value.release) != nil,
              (value.provider.isEmpty || MioGatewayMetadata.providers.contains(value.provider)),
              (value.model.isEmpty || MioGatewayMetadata.identifier(value.model) != nil),
              MioGatewayMetadata.identifier(value.promptVersion) != nil,
              (!value.configured || (!value.provider.isEmpty && !value.model.isEmpty)),
              value.capabilities.count <= 8, Set(value.capabilities).count == value.capabilities.count,
              value.capabilities.allSatisfy({ ["ask-v1", "analysis-v1", "lesson-notes-v1", "analysis-context-v2"].contains($0) })
        else { throw MioCloudError.incompatibleGateway }
        return value
    }

    func requireContextAnalysis() throws {
        guard configured else { throw MioCloudError.gateway(503, .gatewayNotConfigured) }
        guard capabilities.contains("analysis-context-v2") else { throw MioCloudError.incompatibleGateway }
    }
}
