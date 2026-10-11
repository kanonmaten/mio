import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor enum MioDiagnosticsRuntime {
    static var analysisEnabled = false
}

enum MioDiagnosticRoute: String, Codable, Sendable {
    case ask = "/v1/ask", analyze = "/v1/analyze", analyzeContext = "/v2/analyze"
    case lessonNotes = "/v1/lesson-notes", status = "/v1/status", statusV2 = "/v2/status", transcription = "/v1/transcribe"
}

enum MioDiagnosticOperation: String, Codable, Sendable { case ask, analyze, analyzeContext, lessonNotes, status, statusV2, transcription }
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
    case configurationChanged = "configuration_changed", taskConfigurationInvalid = "task_configuration_invalid"
    case providerAuthentication = "provider_authentication", providerAccount = "provider_account"
    case providerModelUnavailable = "provider_model_unavailable", providerParameters = "provider_parameters"
    case providerRefusal = "provider_refusal", providerTruncated = "provider_truncated"
    case providerQuota = "provider_quota", providerInfrastructure = "provider_infrastructure"
    case providerTransport = "provider_transport"
    case providerInvalidResponse = "provider_invalid_response"
    case localMinuteLimit = "local_minute_limit", localDayLimit = "local_day_limit"
    case localTokenLimit = "local_token_limit"
    case localRequestLimit = "local_request_limit"
    case localConcurrencyLimit = "local_concurrency_limit", budgetStoreFailed = "budget_store_failed"
}

/// Only bounded protocol identifiers are accepted; never arbitrary headers or descriptions.
struct MioGatewayMetadata: Codable, Sendable {
    private(set) var requestID: String?
    private(set) var cfRay: String?
    private(set) var release: String?
    private(set) var provider: String?
    private(set) var model: String?
    private(set) var promptVersion: String?
    private(set) var configurationRevision: String?
    private(set) var returnedModel: String?
    private(set) var upstreamRequestID: String?
    private(set) var inputTokens: Int?
    private(set) var outputTokens: Int?
    private(set) var reasoningTokens: Int?

    init(response: HTTPURLResponse) {
        requestID = response.value(forHTTPHeaderField: "X-Mio-Request-Id").flatMap { UUID(uuidString: $0)?.uuidString }
        cfRay = response.value(forHTTPHeaderField: "CF-Ray").flatMap(Self.validRay)
        release = Self.identifier(response.value(forHTTPHeaderField: "X-Mio-Release"))
        provider = Self.protocolIdentifier(response.value(forHTTPHeaderField: "X-Mio-Provider"))
        model = Self.identifier(response.value(forHTTPHeaderField: "X-Mio-Model"))
        promptVersion = Self.identifier(response.value(forHTTPHeaderField: "X-Mio-Prompt-Version"))
        configurationRevision = Self.revision(response.value(forHTTPHeaderField: "X-Mio-Configuration-Revision"))
        returnedModel = Self.identifier(response.value(forHTTPHeaderField: "X-Mio-Returned-Model"))
        upstreamRequestID = Self.validUpstreamRequestID(response.value(forHTTPHeaderField: "X-Mio-Upstream-Request-ID"))
        inputTokens = Self.tokenHeader(response.value(forHTTPHeaderField: "X-Mio-Usage-Input-Tokens"))
        outputTokens = Self.tokenHeader(response.value(forHTTPHeaderField: "X-Mio-Usage-Output-Tokens"))
        reasoningTokens = Self.tokenHeader(response.value(forHTTPHeaderField: "X-Mio-Usage-Reasoning-Tokens"))
    }

    func sanitized() -> Self {
        var result = self
        result.requestID = requestID.flatMap { UUID(uuidString: $0)?.uuidString }
        result.cfRay = cfRay.flatMap(Self.validRay)
        result.release = Self.identifier(release)
        result.provider = Self.protocolIdentifier(provider)
        result.model = Self.identifier(model)
        result.promptVersion = Self.identifier(promptVersion)
        result.configurationRevision = Self.revision(configurationRevision)
        result.returnedModel = Self.identifier(returnedModel)
        result.upstreamRequestID = Self.validUpstreamRequestID(upstreamRequestID)
        result.inputTokens = Self.validTokenCount(inputTokens)
        result.outputTokens = Self.validTokenCount(outputTokens)
        result.reasoningTokens = Self.validTokenCount(reasoningTokens)
        return result
    }

    static func identifier(_ value: String?) -> String? {
        guard let value, (1...150).contains(value.utf8.count),
              !credentialPrefix(value), !value.contains("://"),
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || [45, 46, 47, 58, 95].contains($0) }) else { return nil }
        return value
    }

    private static func validUpstreamRequestID(_ value: String?) -> String? {
        guard let value, (1...128).contains(value.utf8.count),
              !credentialPrefix(value),
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || [45, 46, 58, 95].contains($0) }) else { return nil }
        return value
    }

    private static func credentialPrefix(_ value: String) -> Bool {
        let prefix = value.lowercased()
        return ["sk-", "sk_", "gsk_", "aiza"].contains { prefix.hasPrefix($0) }
    }

    private static func validTokenCount(_ value: Int?) -> Int? {
        guard let value, (0...1_000_000_000).contains(value) else { return nil }
        return value
    }

    private static func tokenHeader(_ value: String?) -> Int? {
        guard let value, (1...10).contains(value.utf8.count),
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return validTokenCount(Int(value))
    }

    /// Extensible wire names remain bounded and cannot contain URLs, headers or key syntax.
    static func protocolIdentifier(_ value: String?) -> String? {
        guard let value, (1...64).contains(value.utf8.count),
              identifier(value) != nil,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || [45, 46, 95].contains($0) }) else { return nil }
        return value
    }

    static func revision(_ value: String?) -> String? {
        guard let value, value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
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
    var transcription: STTDiagnostic?

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
        case .statusV2: .statusV2
        case .transcription: .transcription
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
            && (transcription == nil || (operation == .transcription && transcription!.isValid))
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
    /// Additive: on-device MetricKit payloads (no user text). Older exports omit it.
    var metricReports: [MioMetricReport]? = nil

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
              (value.provider.isEmpty || MioGatewayMetadata.protocolIdentifier(value.provider) != nil),
              (value.model.isEmpty || MioGatewayMetadata.identifier(value.model) != nil),
              MioGatewayMetadata.identifier(value.promptVersion) != nil,
              (!value.configured || (!value.provider.isEmpty && !value.model.isEmpty)),
              value.capabilities.count <= 32, Set(value.capabilities).count == value.capabilities.count,
              value.capabilities.allSatisfy({ MioGatewayMetadata.protocolIdentifier($0) != nil })
        else { throw MioCloudError.incompatibleGateway }
        return value
    }

    func requireContextAnalysis() throws {
        guard configured else { throw MioCloudError.gateway(503, .gatewayNotConfigured) }
        guard capabilities.contains("analysis-context-v2") else { throw MioCloudError.incompatibleGateway }
    }
}


enum MioAITaskID: String, Codable, CaseIterable, Sendable {
    case ask, everyday, lesson

    var requiredCapabilities: Set<String> {
        let taskContract: String
        switch self {
        case .ask: taskContract = "ask-v1"
        case .everyday: taskContract = "analysis-context-v2"
        case .lesson: taskContract = "lesson-notes-v1"
        }
        return ["reasoning-off", "temperature-zero", "strict-json", taskContract]
    }
}
enum MioTaskConfigurationError: String, Codable, Sendable {
    case gatewayConfigurationInvalid = "gateway_configuration_invalid"
    case taskProfilesInvalid = "task_profiles_invalid", taskProfileInvalid = "task_profile_invalid"
    case providerSecretMissing = "provider_secret_missing", providerModelIncompatible = "provider_model_incompatible"
    case providerOptionsIncompatible = "provider_options_incompatible"
    /// A newer server's bounded code. The task stays unavailable; no IPA update is required.
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard MioGatewayMetadata.protocolIdentifier(value) != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unbounded configuration error"))
        }
        self = Self(rawValue: value) ?? .unknown
    }
}
struct MioGatewayTaskStatus: Decodable, Sendable {
    let configured: Bool
    let provider: String
    let model: String
    let promptVersion: String
    let capabilities: [String]
    let configurationError: MioTaskConfigurationError?

    var isValid: Bool {
        (provider.isEmpty || MioGatewayMetadata.protocolIdentifier(provider) != nil)
            && (model.isEmpty || MioGatewayMetadata.identifier(model) != nil)
            && (promptVersion.isEmpty || MioGatewayMetadata.identifier(promptVersion) != nil)
            && (!configured || (!provider.isEmpty && !model.isEmpty && !promptVersion.isEmpty && configurationError == nil))
            && (configured || configurationError != nil)
            && capabilities.count <= 32 && Set(capabilities).count == capabilities.count
            && capabilities.allSatisfy { MioGatewayMetadata.protocolIdentifier($0) != nil }
    }
}
struct MioGatewayTasksStatus: Decodable, Sendable {
    let ask: MioGatewayTaskStatus
    let everyday: MioGatewayTaskStatus
    let lesson: MioGatewayTaskStatus

    subscript(task: MioAITaskID) -> MioGatewayTaskStatus {
        switch task {
        case .ask: ask
        case .everyday: everyday
        case .lesson: lesson
        }
    }
}
struct MioGatewayQuota: Decodable, Sendable {
    enum Unit: String, Decodable, Sendable { case tokens, requests }
    let limit: Int
    let remaining: Int?
    let resetAt: String?
    /// Absent from older gateways, which only counted requests.
    var unit: Unit? = nil

    var isValid: Bool {
        // Mirrors the gateway's optional daily caps (MAX_REQUESTS_PER_DAY, MAX_TOKENS_PER_DAY);
        // no cap is reported as quota null.
        (1...1_000_000).contains(limit) && (remaining == nil || (0...limit).contains(remaining!))
            && (resetAt == nil || (resetAt!.utf8.count <= 30 && resetAt!.hasSuffix("Z")
                && MioAnalysisResult.parseDate(resetAt!) != nil))
    }
}
struct MioGatewayStatusV2: Decodable, Sendable {
    let protocolVersion: Int
    let release: String
    let configurationRevision: String
    let tasks: MioGatewayTasksStatus
    let quota: MioGatewayQuota?
    static let maxResponseBytes = 16_384

    static func decode(_ data: Data) throws -> Self {
        func exact(_ value: Any?, _ keys: Set<String>) -> Bool {
            guard let object = value as? [String: Any] else { return false }
            return Set(object.keys) == keys
        }
        guard data.count <= maxResponseBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              exact(root, ["protocolVersion", "release", "configurationRevision", "tasks", "quota"]),
              // A newer server may add tasks; Mio requires its own three and ignores the rest.
              let tasks = root["tasks"] as? [String: Any], tasks.count <= 16,
              Set(tasks.keys).isSuperset(of: ["ask", "everyday", "lesson"]),
              ["ask", "everyday", "lesson"].allSatisfy({ exact(tasks[$0], ["configured", "provider", "model", "promptVersion", "capabilities", "configurationError"]) }),
              root["quota"] is NSNull || exact(root["quota"], ["limit", "remaining", "resetAt"])
                || exact(root["quota"], ["limit", "remaining", "resetAt", "unit"]),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.protocolVersion == 2,
              MioGatewayMetadata.identifier(value.release) != nil,
              MioGatewayMetadata.revision(value.configurationRevision) != nil,
              MioAITaskID.allCases.allSatisfy({ value.tasks[$0].isValid }),
              value.quota == nil || value.quota!.isValid
        else { throw MioCloudError.incompatibleGateway }
        return value
    }

    /// Unknown bounded capability/provider names are metadata, not proof that a
    /// selected task supports Mio's immutable policy or wire contract.
    @discardableResult
    func requireTask(_ task: MioAITaskID) throws -> MioGatewayTaskStatus {
        let profile = tasks[task]
        guard profile.configured else { throw MioCloudError.gateway(422, .taskConfigurationInvalid) }
        guard Set(profile.capabilities).isSuperset(of: task.requiredCapabilities) else { throw MioCloudError.incompatibleGateway }
        return profile
    }
}
