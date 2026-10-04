import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Mio

final class MioDiagnosticsTests: XCTestCase {
    func testPrivacyFailureAfterAtomicCommitRemainsVisibleInSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagnostics-v1.json")
        let repository = MioDiagnosticsRepository(storageURL: url, fileManager: DiagnosticPrivacyFailureFileManager())
        let generation = await repository.beginRequest()
        await repository.record(MioDiagnosticEvent(operation: .status), generation: generation)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.storageStatus, .writeFailed)
        XCTAssertEqual(snapshot.events.count, 1)
    }

    func testLoadedJournalCannotOverwriteExternallyReplacedUnknownSchema() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagnostics-v1.json")
        let repository = MioDiagnosticsRepository(storageURL: url)
        let generation = await repository.beginRequest()
        await repository.record(MioDiagnosticEvent(operation: .status), generation: generation)
        let unknown = Data(#"{"schemaVersion":99,"futureEvents":[],"privateFixture":"must remain"}"#.utf8)
        try unknown.write(to: url, options: .atomic)
        await repository.record(MioDiagnosticEvent(operation: .ask), generation: generation)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.storageStatus, .unsupportedSchema)
        XCTAssertEqual(try Data(contentsOf: url), unknown)
    }

    func testJournalSurvivesRestartBoundsHistoryAndRejectsLateCompletionAfterDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagnostics-v1.json")
        let repository = MioDiagnosticsRepository(storageURL: url)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let generation = await repository.beginRequest()
        await repository.record(MioDiagnosticEvent(operation: .ask, startedAt: now.addingTimeInterval(-8 * 86_400)), generation: generation, now: now)
        for index in 0..<205 {
            await repository.record(MioDiagnosticEvent(operation: .ask, startedAt: now, requestBytes: index), generation: generation, now: now)
        }
        let snapshot = await MioDiagnosticsRepository(storageURL: url).snapshot(now: now)
        XCTAssertEqual(snapshot.events.count, 200)
        XCTAssertEqual(snapshot.events.first?.requestBytes, 5)
        XCTAssertEqual(snapshot.storageStatus, .available)
        await repository.invalidateForDeletion()
        try await repository.deleteAll()
        await repository.record(MioDiagnosticEvent(operation: .ask), generation: generation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let empty = await repository.snapshot()
        XCTAssertTrue(empty.events.isEmpty)
    }

    func testDeletionCutoffRejectsPreDeletionOperationEvenWithNewGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagnostics-v1.json")
        let repository = MioDiagnosticsRepository(storageURL: url)
        let earlierOperation = MioDiagnosticEvent(operation: .status, startedAt: .now.addingTimeInterval(-1))
        await repository.invalidateForDeletion()
        try await repository.deleteAll()
        let lateGeneration = await repository.beginRequest()
        await repository.record(earlierOperation, generation: lateGeneration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let journal = await repository.snapshot()
        XCTAssertTrue(journal.events.isEmpty)
    }

    func testUnknownSchemaAndFailedPersistenceStayVisibleAndNeverOverwrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagnostics-v1.json")
        let sentinel = Data("{\"schemaVersion\":99,\"events\":[]}".utf8)
        try sentinel.write(to: url)
        let repository = MioDiagnosticsRepository(storageURL: url)
        let generation = await repository.beginRequest()
        await repository.record(MioDiagnosticEvent(operation: .ask), generation: generation)
        XCTAssertEqual(try Data(contentsOf: url), sentinel)
        let unknown = await repository.snapshot()
        XCTAssertEqual(unknown.storageStatus, .unsupportedSchema)
        let failed = MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics-v1.json/nested"))
        let failedGeneration = await failed.beginRequest()
        await failed.record(MioDiagnosticEvent(operation: .ask), generation: failedGeneration)
        let failure = await failed.snapshot()
        XCTAssertNotEqual(failure.storageStatus, .available)
    }

    func testExportWithoutSessionIncludesDiagnosticsAndOlderExportStillDecodes() async throws {
        let diagnostics = MioDiagnosticsExport(configuration: .init(cloudEnabled: false, serverConfigured: false, accessConfigured: false), journal: .init(events: [], storageStatus: .available))
        let export = MioLocalExport(content: [], sessions: [], diagnostics: diagnostics)
        let data = try JSONEncoder().encode(export)
        let decoded = try JSONDecoder().decode(MioLocalExport.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertNotNil(decoded.diagnostics)
        let old = Data("{\"schemaVersion\":2,\"exportedAt\":0,\"content\":[],\"sessions\":[]}".utf8)
        XCTAssertNil(try JSONDecoder().decode(MioLocalExport.self, from: old).diagnostics)
    }

    func testRegeneratedExportIncludesLaterFailureWithoutAnySession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MioDiagnosticsRepository(storageURL: root.appendingPathComponent("diagnostics.json"))
        let content = MioContentRepository(storageURL: root.appendingPathComponent("content.json"), exportDirectoryURL: root)
        let configuration = MioDiagnosticsConfiguration(cloudEnabled: true, serverConfigured: true, accessConfigured: true)
        let firstSnapshot = await journal.snapshot()
        let firstURL = try await content.makeExportFile(content: [], sessions: [], diagnostics: MioDiagnosticsExport(configuration: configuration, journal: firstSnapshot))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let first = try decoder.decode(MioLocalExport.self, from: Data(contentsOf: firstURL))
        XCTAssertTrue(first.diagnostics?.journal.events.isEmpty == true)

        var failure = MioDiagnosticEvent(operation: .ask)
        failure.outcome = .httpError; failure.httpStatus = 503; failure.gatewayCode = .gatewayNotConfigured
        let generation = await journal.beginRequest()
        await journal.record(failure, generation: generation)
        let latestSnapshot = await journal.snapshot()
        let updatedURL = try await content.makeExportFile(content: [], sessions: [], diagnostics: MioDiagnosticsExport(configuration: configuration, journal: latestSnapshot))
        let updated = try decoder.decode(MioLocalExport.self, from: Data(contentsOf: updatedURL))
        XCTAssertTrue(updated.sessions.isEmpty)
        XCTAssertEqual(updated.diagnostics?.journal.events.count, 1)
        XCTAssertEqual(updated.diagnostics?.journal.events.first?.httpStatus, 503)
        XCTAssertEqual(updated.diagnostics?.journal.events.first?.gatewayCode, .gatewayNotConfigured)
        XCTAssertEqual(updated.diagnostics?.configuration.accessConfigured, true)
    }

    func testErrorBodiesAndHeadersOnlyExposeAllowlistedMetadata() throws {
        let secret = "private-question-secret-token"
        XCTAssertEqual(MioCloudService.gatewayCode(from: Data("{\"error\":\"gateway_not_configured\"}".utf8)), .gatewayNotConfigured)
        XCTAssertNil(MioCloudService.gatewayCode(from: Data("{\"error\":\"\(secret)\"}".utf8)))
        XCTAssertNil(MioCloudService.gatewayCode(from: Data("{\"error\":\"gateway_not_configured\",\"detail\":\"\(secret)\"}".utf8)))
        XCTAssertNil(MioCloudService.gatewayCode(from: Data(repeating: 32, count: 4097)))
        XCTAssertNil(MioCloudService.gatewayCode(from: Data("<html>\(secret)</html>".utf8)))
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid/v1/ask")!, statusCode: 503, httpVersion: nil, headerFields: ["CF-Ray": "abc123def456-SJC", "X-Mio-Model": "Bearer \(secret)", "X-Mio-Provider": "groq", "X-Mio-Prompt-Version": "v2", "X-Mio-Release": "2026-09-30", "X-Mio-Request-Id": UUID().uuidString]))
        let metadata = MioGatewayMetadata(response: response)
        XCTAssertEqual(metadata.cfRay, "abc123def456-SJC")
        XCTAssertNil(metadata.model)
        let encoded = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        let error = MioCloudError.gateway(503, .gatewayNotConfigured)
        XCTAssertTrue(error.localizedDescription.contains("konfigurerad"))
    }

    func testHTTPFailuresKeepAuthSeparateAndBoundRetryAfter() throws {
        func response(_ status: Int, _ type: String = "application/json", retry: String? = nil) throws -> HTTPURLResponse {
            var headers = ["Content-Type": type]
            headers["Retry-After"] = retry
            return try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid/v1/ask")!, statusCode: status, httpVersion: nil, headerFields: headers))
        }
        let config = Data("{\"error\":\"gateway_not_configured\"}".utf8)
        guard case .gateway(503, .gatewayNotConfigured) = MioCloudService.httpFailure(response: try response(503), body: config).error else {
            return XCTFail("503 must explain gateway configuration")
        }
        guard case .serverStatus(403) = MioCloudService.httpFailure(response: try response(403, "text/html"), body: config).error else {
            return XCTFail("Access HTML must remain an auth failure")
        }
        guard case .serverStatus(401) = MioCloudService.httpFailure(response: try response(401), body: config).error else {
            return XCTFail("HTTP auth takes precedence over an unrelated gateway code")
        }
        for (value, expected) in [("-5", 1), ("999999", 86_400), ("not-a-number", 60)] {
            let failure = MioCloudService.httpFailure(response: try response(429, retry: value), body: Data())
            guard case .rateLimited(let seconds) = failure.error else { return XCTFail("Expected rate limit") }
            XCTAssertEqual(seconds, expected)
            XCTAssertEqual(failure.retryAfterSeconds, expected)
        }
        guard case .serverStatus(503) = MioCloudService.httpFailure(response: try response(503), body: Data(repeating: 32, count: 4097)).error else {
            return XCTFail("Oversized error data must never override the HTTP failure")
        }
    }

    func testHTTPDateRetryAfterUsesResponseDeadlineAndBoundsPastDates() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": "Thu, 01 Jan 1970 00:00:30 GMT"]))
        // A date response must give a useful retry delay, not the generic 60-second value.
        XCTAssertEqual(MioCloudService.httpFailure(response: response, body: Data()).retryAfterSeconds, 1)
        XCTAssertEqual(MioCloudService.httpFailure(response: response, body: Data(), now: Date(timeIntervalSince1970: 0)).retryAfterSeconds, 30)
    }

    func testDiscoveryAcceptsBoundedFutureProvidersAndCapabilitiesButRequiresTaskSupport() throws {
        let object: [String: Any] = ["protocolVersion": 2, "release": "fixture-v3", "configured": true,
            "provider": "future_provider-2", "model": "reviewed:model", "promptVersion": "mio-v3",
            "capabilities": ["analysis-context-v2", "future-feature-v9"]]
        let status = try MioGatewayStatus.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(status.provider, "future_provider-2")
        XCTAssertNoThrow(try status.requireContextAnalysis())
        var unsupported = object; unsupported["capabilities"] = ["future-feature-v9"]
        XCTAssertThrowsError(try MioGatewayStatus.decode(JSONSerialization.data(withJSONObject: unsupported)).requireContextAnalysis())
        for provider in ["https://private.invalid", "Bearer secret", String(repeating: "x", count: 65), "sk-secret"] {
            var invalid = object; invalid["provider"] = provider
            XCTAssertThrowsError(try MioGatewayStatus.decode(JSONSerialization.data(withJSONObject: invalid)))
        }
        for capabilities in [["future feature"], ["analysis-context-v2", "analysis-context-v2"], Array(repeating: "feature", count: 33)] {
            var invalid = object; invalid["capabilities"] = capabilities
            XCTAssertThrowsError(try MioGatewayStatus.decode(JSONSerialization.data(withJSONObject: invalid)))
        }
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 200,
            httpVersion: nil, headerFields: ["X-Mio-Provider": "future_provider-2"]))
        XCTAssertEqual(MioGatewayMetadata(response: response).provider, "future_provider-2")
    }

    func testCustomModelIdentifiersMatchGatewayColonContract() throws {
        let data = Data("{\"protocolVersion\":2,\"release\":\"2026-09-30.1\",\"configured\":true,\"provider\":\"custom\",\"model\":\"fixture:model-v1\",\"promptVersion\":\"2026-09-30.1\",\"capabilities\":[\"analysis-context-v2\"]}".utf8)
        let status = try MioGatewayStatus.decode(data)
        XCTAssertEqual(status.model, "fixture:model-v1")
        XCTAssertNoThrow(try status.requireContextAnalysis())
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid/v1/ask")!, statusCode: 200, httpVersion: nil,
            headerFields: ["X-Mio-Provider": "custom", "X-Mio-Model": "fixture:model-v1"]))
        XCTAssertEqual(MioGatewayMetadata(response: response).model, "fixture:model-v1")
    }

    func testStatusRejectsUnknownKeysAndMissingContextCapability() throws {
        let valid = Data("{\"protocolVersion\":2,\"release\":\"2026-09-30\",\"configured\":true,\"provider\":\"groq\",\"model\":\"qwen/qwen3.8-27b\",\"promptVersion\":\"mio-v2\",\"capabilities\":[\"analysis-context-v2\"]}".utf8)
        let status = try MioGatewayStatus.decode(valid)
        XCTAssertNoThrow(try status.requireContextAnalysis())
        let legacy = Data("{\"protocolVersion\":2,\"release\":\"old\",\"configured\":true,\"provider\":\"openai\",\"model\":\"gpt\",\"promptVersion\":\"v1\",\"capabilities\":[\"analysis-v1\"]}".utf8)
        XCTAssertThrowsError(try MioGatewayStatus.decode(legacy).requireContextAnalysis())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["secret"] = "private"
        XCTAssertThrowsError(try MioGatewayStatus.decode(JSONSerialization.data(withJSONObject: object)))
    }
}

private final class DiagnosticPrivacyFailureFileManager: FileManager, @unchecked Sendable {
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if path.hasSuffix("diagnostics-v1.json") { throw CocoaError(.fileWriteNoPermission) }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}
