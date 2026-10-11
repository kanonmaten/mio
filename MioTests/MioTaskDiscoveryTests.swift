import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Mio

final class MioTaskDiscoveryTests: XCTestCase {
    func testDiscoveryAcceptsIndependentProfilesAndBoundedFutureCapabilities() throws {
        let status = try MioGatewayStatusV2.decode(fixture())
        XCTAssertEqual(status.configurationRevision, String(repeating: "a", count: 64))
        XCTAssertEqual(status.tasks.ask.provider, "future_provider-2")
        XCTAssertEqual(status.tasks.everyday.model, "context:model-v1")
        XCTAssertEqual(status.tasks.lesson.model, "lesson-model")
        for task in [MioAITaskID.ask, .everyday, .lesson] { XCTAssertNoThrow(try status.requireTask(task)) }
        XCTAssertEqual(status.quota?.remaining, 73)
        XCTAssertEqual(status.quota?.resetAt, "2026-10-03T00:00:00.000Z")
    }

    func testSelectedTaskRequiresImmutablePolicyAndItsOwnContract() throws {
        for missing in ["reasoning-off", "temperature-zero", "strict-json", "ask-v1"] {
            let data = try fixture { root in
                var tasks = root["tasks"] as! [String: [String: Any]]
                var ask = tasks["ask"]!
                ask["capabilities"] = (ask["capabilities"] as! [String]).filter { $0 != missing }
                tasks["ask"] = ask; root["tasks"] = tasks
            }
            let status = try MioGatewayStatusV2.decode(data)
            XCTAssertThrowsError(try status.requireTask(.ask), missing)
            XCTAssertNoThrow(try status.requireTask(.everyday))
        }
    }

    func testDisabledTaskReportsSpecificConfigurationWithoutDisablingOtherTasks() throws {
        let status = try MioGatewayStatusV2.decode(fixture { root in
            var tasks = root["tasks"] as! [String: [String: Any]]
            tasks["lesson"] = ["configured": false, "provider": "", "model": "", "promptVersion": "lesson-v1",
                "capabilities": [], "configurationError": "provider_secret_missing"]
            root["tasks"] = tasks
        })
        XCTAssertNoThrow(try status.requireTask(.ask))
        XCTAssertEqual(status.tasks.lesson.configurationError, .providerSecretMissing)
        XCTAssertThrowsError(try status.requireTask(.lesson)) { error in
            guard case MioCloudError.gateway(422, .taskConfigurationInvalid) = error else { return XCTFail("Disabled task must be explicit") }
        }
    }

    func testDiscoveryRejectsUnsafeShapeIdentifiersRevisionsAndCapabilities() throws {
        var mutations: [(inout [String: Any]) -> Void] = [
            { $0["protocolVersion"] = 3 }, { $0["secret"] = "private" },
            { $0["configurationRevision"] = String(repeating: "A", count: 64) },
            { $0["configurationRevision"] = String(repeating: "a", count: 63) },
            { $0["configurationRevision"] = "https://private.invalid" },
            { $0["release"] = "Bearer private" },
            { $0["tasks"] = [:] }
        ]
        for provider in ["https://private.invalid", "sk-private", String(repeating: "x", count: 65)] {
            mutations.append { root in
                var tasks = root["tasks"] as! [String: [String: Any]]
                tasks["ask"]!["provider"] = provider; root["tasks"] = tasks
            }
        }
        for capabilities in [["ask-v1", "ask-v1"], ["private arbitrary text"], Array(repeating: "a", count: 33)] {
            mutations.append { root in
                var tasks = root["tasks"] as! [String: [String: Any]]
                tasks["ask"]!["capabilities"] = capabilities; root["tasks"] = tasks
            }
        }
        mutations += [
            { root in var tasks = root["tasks"] as! [String: [String: Any]]; tasks["ask"]!["configurationError"] = "private arbitrary error"; root["tasks"] = tasks },
            { root in var tasks = root["tasks"] as! [String: [String: Any]]; tasks["ask"]!["configurationError"] = "provider_secret_missing"; root["tasks"] = tasks },
            { root in var tasks = root["tasks"] as! [String: [String: Any]]; tasks["ask"]!["model"] = ""; root["tasks"] = tasks },
            { root in var tasks = root["tasks"] as! [String: [String: Any]]; tasks["ask"]!["credential"] = "private"; root["tasks"] = tasks }
        ]
        for mutation in mutations { XCTAssertThrowsError(try MioGatewayStatusV2.decode(fixture(mutation))) }
        XCTAssertThrowsError(try MioGatewayStatusV2.decode(Data(repeating: 32, count: 16_385)))
    }

    func testNewerServerAdditionsDoNotRequireAnIPAUpdate() throws {
        let extended = try MioGatewayStatusV2.decode(fixture { root in
            var tasks = root["tasks"] as! [String: [String: Any]]
            tasks["ask"]!["configured"] = false
            tasks["ask"]!["configurationError"] = "provider_region_unavailable"
            tasks["summary"] = ["configured": true, "provider": "future", "model": "future-model",
                                "promptVersion": "summary-v1", "capabilities": [], "configurationError": NSNull()]
            root["tasks"] = tasks
        })
        XCTAssertEqual(extended.tasks.ask.configurationError, .unknown)
        XCTAssertThrowsError(try extended.requireTask(.ask), "an unknown server error still disables the task")
        XCTAssertNoThrow(try extended.requireTask(.lesson))
        XCTAssertThrowsError(try MioGatewayStatusV2.decode(fixture { root in
            var tasks = root["tasks"] as! [String: [String: Any]]
            tasks.removeValue(forKey: "lesson"); root["tasks"] = tasks
        }), "Mio's own tasks remain required")
    }

    func testQuotaSupportsUnknownValuesAndRejectsImpossibleCountersAndDates() throws {
        let unknown = try MioGatewayStatusV2.decode(fixture { $0["quota"] = ["limit": 100, "remaining": NSNull(), "resetAt": NSNull()] })
        XCTAssertNil(unknown.quota?.remaining); XCTAssertNil(unknown.quota?.resetAt)
        XCTAssertNil(try MioGatewayStatusV2.decode(fixture { $0["quota"] = NSNull() }).quota)
        XCTAssertEqual(try MioGatewayStatusV2.decode(fixture { $0["quota"] = ["limit": 2000, "remaining": 1500, "resetAt": NSNull()] }).quota?.limit, 2000)
        let quotas: [[String: Any]] = [
            ["limit": 100, "remaining": -1, "resetAt": NSNull()],
            ["limit": 100, "remaining": 101, "resetAt": NSNull()],
            ["limit": 1_000_001, "remaining": 100, "resetAt": NSNull()],
            ["limit": 0, "remaining": 0, "resetAt": NSNull()],
            ["limit": 100, "remaining": 3.5, "resetAt": NSNull()],
            ["limit": 100, "remaining": 3, "resetAt": "2026-02-30T00:00:00.000Z"],
            ["limit": 100, "remaining": 3, "resetAt": "2026-10-03T00:00:00+02:00"],
            ["limit": 100, "remaining": 3, "resetAt": NSNull(), "private": "text"],
            ["limit": 100, "remaining": 3, "resetAt": NSNull(), "unit": "minutes"]
        ]
        for quota in quotas { XCTAssertThrowsError(try MioGatewayStatusV2.decode(fixture { $0["quota"] = quota })) }
    }

    func testQuotaUnitIsOptionalAndDistinguishesTokensFromRequests() throws {
        let tokens = try MioGatewayStatusV2.decode(fixture {
            $0["quota"] = ["limit": 190_000, "remaining": 1_000, "resetAt": "2026-10-12T00:00:00.000Z", "unit": "tokens"] })
        XCTAssertEqual(tokens.quota?.unit, .tokens)
        let requests = try MioGatewayStatusV2.decode(fixture { $0["quota"] = ["limit": 100, "remaining": 3, "resetAt": NSNull(), "unit": "requests"] })
        XCTAssertEqual(requests.quota?.unit, .requests)
        XCTAssertNil(try MioGatewayStatusV2.decode(fixture { $0["quota"] = ["limit": 100, "remaining": 3, "resetAt": NSNull()] }).quota?.unit,
                     "Older gateways without a unit stay compatible")
    }

    func testObservedRevisionIsSeparateFromApprovedBodyAndStatusHasNoRevisionHeader() throws {
        let body = Data(#"{"question":"Syntetiskt prov","context":[]}"#.utf8)
        var connection = connection()
        connection.observedConfigurationRevision = String(repeating: "b", count: 64)
        let request = try MioCloudService.makeRequest(body, connection: connection)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Mio-Configuration-Revision"), String(repeating: "b", count: 64))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture_gateway")
        XCTAssertEqual(request.httpBody, body)
        let status = try MioCloudService.makeRequest(Data(), connection: connection, method: "GET")
        XCTAssertNil(status.value(forHTTPHeaderField: "X-Mio-Configuration-Revision"))
        XCTAssertNil(status.httpBody)
        for invalid in ["", String(repeating: "A", count: 64), "value\r\nInjected: secret"] {
            connection.observedConfigurationRevision = invalid
            XCTAssertThrowsError(try MioCloudService.makeRequest(body, connection: connection))
        }
        connection.observedConfigurationRevision = nil
        XCTAssertNil(try MioCloudService.makeRequest(body, connection: connection).value(forHTTPHeaderField: "X-Mio-Configuration-Revision"))
    }

    func testProtectedStatusV2UsesReadOnlyRouteWithBearerToken() async throws {
        var connection = connection()
        connection.observedConfigurationRevision = String(repeating: "b", count: 64)
        let transport = DiscoveryTransport(data: try fixture())
        let status = try await MioCloudService.statusV2(connection: connection, transport: { try await transport.send($0) })
        XCTAssertEqual(status.configurationRevision, String(repeating: "a", count: 64))
        let first = await transport.firstRequest()
        let sent = try XCTUnwrap(first)
        XCTAssertEqual(sent.url?.absoluteString, "https://example.invalid/v2/status")
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertNil(sent.httpBody)
        XCTAssertNil(sent.value(forHTTPHeaderField: "X-Mio-Configuration-Revision"))
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer fixture_gateway")
        XCTAssertNil(sent.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
    }

    func testStatusV2EnforcesStreamBodyLimitAndDoesNotFallBackToLegacy() async throws {
        let oversized = DiscoveryTransport(data: Data(repeating: 32, count: 16_385))
        do { _ = try await MioCloudService.statusV2(connection: connection(), transport: { try await oversized.send($0) }); XCTFail("Oversized stream must stop") }
        catch MioCloudError.oversizedResponse {} catch { XCTFail("Unexpected failure: \(error)") }
        let missing = DiscoveryTransport(data: Data(#"{"error":"not_found"}"#.utf8), status: 404)
        do { _ = try await MioCloudService.statusV2(connection: connection(), transport: { try await missing.send($0) }); XCTFail("Missing v2 status must require server update") }
        catch MioCloudError.incompatibleGateway {} catch { XCTFail("Unexpected failure: \(error)") }
        let sent = await missing.requests()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.url?.path, "/v2/status")
    }

    func testSafeFailureCategoriesRemainSpecificWithoutArbitraryProviderBodies() throws {
        let categories: [(String, MioGatewayErrorCode)] = [
            ("configuration_changed", .configurationChanged), ("task_configuration_invalid", .taskConfigurationInvalid),
            ("provider_authentication", .providerAuthentication), ("provider_account", .providerAccount),
            ("provider_model_unavailable", .providerModelUnavailable), ("provider_parameters", .providerParameters),
            ("provider_refusal", .providerRefusal), ("provider_truncated", .providerTruncated),
            ("provider_quota", .providerQuota), ("provider_infrastructure", .providerInfrastructure),
            ("provider_transport", .providerTransport),
            ("provider_invalid_response", .providerInvalidResponse), ("local_minute_limit", .localMinuteLimit),
            ("local_day_limit", .localDayLimit), ("local_concurrency_limit", .localConcurrencyLimit),
            ("local_request_limit", .localRequestLimit),
            ("budget_store_failed", .budgetStoreFailed)
        ]
        for (wire, expected) in categories {
            let status = wire == "configuration_changed" ? 409 : wire.contains("limit") || wire == "provider_quota" ? 429 : 502
            let response = try XCTUnwrap(HTTPURLResponse(url: connection().endpoint, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "Retry-After": "9"]))
            let data = Data("{\"error\":\"\(wire)\"}".utf8)
            let failure = MioCloudService.httpFailure(response: response, body: data)
            XCTAssertEqual(failure.code, expected)
            if status == 429 {
                guard case .gatewayRateLimited(let code, let seconds) = failure.error else { XCTFail("Quota category was erased: \(wire)"); continue }
                XCTAssertEqual(code, expected); XCTAssertEqual(seconds, 9)
            } else {
                guard case .gateway(let actualStatus, let code) = failure.error else { XCTFail("Specific category was erased: \(wire)"); continue }
                XCTAssertEqual(actualStatus, status); XCTAssertEqual(code, expected)
            }
            XCTAssertFalse(failure.error.localizedDescription.contains(wire))
            if status == 429 { XCTAssertEqual(failure.retryAfterSeconds, 9) }
        }
        XCTAssertNil(MioCloudService.gatewayCode(from: Data(#"{"error":"provider_authentication","details":"private"}"#.utf8)))
        XCTAssertNil(MioCloudService.gatewayCode(from: Data(#"{"error":"private arbitrary provider body"}"#.utf8)))
    }

    func testConfigurationRevisionMetadataIsBoundedAndLegacyFieldsStillDecode() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: connection().endpoint, statusCode: 409, httpVersion: nil,
            headerFields: ["X-Mio-Configuration-Revision": String(repeating: "c", count: 64)]))
        XCTAssertEqual(MioGatewayMetadata(response: response).configurationRevision, String(repeating: "c", count: 64))
        let invalid = try XCTUnwrap(HTTPURLResponse(url: connection().endpoint, statusCode: 409, httpVersion: nil,
            headerFields: ["X-Mio-Configuration-Revision": "private arbitrary header"]))
        XCTAssertNil(MioGatewayMetadata(response: invalid).configurationRevision)
        let old = Data(#"{"release":"legacy","provider":"openai"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(MioGatewayMetadata.self, from: old).configurationRevision)
    }

    func testAskFixtureSendsExactlyApprovedPayloadWithObservedRevision() async throws {
        var connection = connection()
        connection.observedConfigurationRevision = String(repeating: "b", count: 64)
        let payload = MioCloudRequest(question: "Vilken tid?", context: [.init(label: "Valt", text: "Klockan tre.")])
        let transport = DiscoveryTransport(data: Data(#"{"answer":"Klockan tre."}"#.utf8))
        let answer = try await MioCloudService.ask(payload, connection: connection, transport: { try await transport.send($0) })
        XCTAssertEqual(answer, "Klockan tre.")
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(sent.url?.path, "/v1/ask")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Mio-Configuration-Revision"), connection.observedConfigurationRevision)
        let actual = try JSONDecoder().decode(MioCloudRequest.self, from: XCTUnwrap(sent.httpBody))
        XCTAssertEqual(actual, payload)
    }

    func testLegacyAnalysisFixtureKeepsOriginalBodyWithObservedRevision() async throws {
        var connection = connection()
        connection.observedConfigurationRevision = String(repeating: "b", count: 64)
        let payload = analysisPayload(contextContract: false)
        let transport = DiscoveryTransport(data: Data(#"{"candidates":[],"highlights":[],"uncertainties":[]}"#.utf8))
        let result = try await MioCloudService.analyze(payload, connection: connection, transport: { try await transport.send($0) })
        XCTAssertTrue(result.candidates.isEmpty)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(sent.url?.path, "/v1/analyze")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Mio-Configuration-Revision"), String(repeating: "b", count: 64))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["mode", "timeZone", "fragments"])
        XCTAssertEqual(body["timeZone"] as? String, "Europe/Stockholm")
    }

    func testGenerationWithoutAnObservedRevisionStopsBeforeAnyNetworkTraffic() async throws {
        let transport = DiscoveryTransport(data: Data(#"{"answer":"Syntetiskt svar"}"#.utf8), statusData: try fixture())
        do {
            _ = try await MioCloudService.ask(.init(question: "Syntetisk fråga?", context: []), connection: connection(),
                                              transport: { try await transport.send($0) })
            XCTFail("A question must first be reviewed with a discovered revision")
        } catch MioCloudError.changedConfiguration {} catch { XCTFail("Unexpected error \(error)") }
        for contextContract in [false, true] {
            do {
                _ = try await MioCloudService.analyze(analysisPayload(contextContract: contextContract), connection: connection(),
                                                      transport: { try await transport.send($0) })
                XCTFail("Analysis requires its activation revision")
            } catch MioCloudError.changedConfiguration {} catch { XCTFail("Unexpected error \(error)") }
        }
        let source = analysisPayload(contextContract: false)
        let lesson = MioAnalysisRequest(mode: .lesson, timeZone: source.timeZone, fragments: source.fragments)
        do {
            _ = try await MioCloudService.analyze(lesson, connection: connection(), transport: { try await transport.send($0) })
            XCTFail("Lesson notes require their activation revision")
        } catch MioCloudError.changedConfiguration {} catch { XCTFail("Unexpected error \(error)") }
        let sent = await transport.requests()
        XCTAssertTrue(sent.isEmpty)
    }

    func testSafeProviderAuthenticationAndAccountErrorsStayDistinctFromGatewayAuthentication() throws {
        for (status, wire, expected) in [(401, "provider_authentication", MioGatewayErrorCode.providerAuthentication),
                                         (403, "provider_account", .providerAccount)] {
            let response = try XCTUnwrap(HTTPURLResponse(url: connection().endpoint, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            let failure = MioCloudService.httpFailure(response: response, body: Data("{\"error\":\"\(wire)\"}".utf8))
            guard case .gateway(let actualStatus, let code) = failure.error else {
                XCTFail("The bounded provider error category was lost"); continue
            }
            XCTAssertEqual(actualStatus, status); XCTAssertEqual(code, expected)
            let gateway = MioCloudService.httpFailure(response: response, body: Data(#"{"error":"unauthorized"}"#.utf8))
            XCTAssertTrue(gateway.error.localizedDescription.contains("MIO_GATEWAY_TOKEN"))
            let arbitrary = MioCloudService.httpFailure(response: response, body: Data("private arbitrary body".utf8))
            guard case .serverStatus(status) = arbitrary.error else { return XCTFail("No arbitrary error is promoted") }
        }
    }

    func testContextAnalysisFixturePreservesRevisionAfterReadOnlyTaskPreflight() async throws {
        var connection = connection()
        connection.observedConfigurationRevision = String(repeating: "b", count: 64)
        let status = try fixture { $0["configurationRevision"] = String(repeating: "b", count: 64) }
        let transport = DiscoveryTransport(data: Data(#"{"candidates":[],"highlights":[],"uncertainties":[]}"#.utf8), statusData: status)
        _ = try await MioCloudService.analyze(analysisPayload(contextContract: true), connection: connection,
                                             transport: { try await transport.send($0) })
        let requests = await transport.requests()
        XCTAssertEqual(requests.map { $0.url!.path }, ["/v2/status", "/v2/analyze"])
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        XCTAssertNil(requests[0].httpBody)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "X-Mio-Configuration-Revision"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Mio-Configuration-Revision"), connection.observedConfigurationRevision)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["mode", "timeZone", "fragments", "contextFragments", "priorDecisions", "contextLimited"])
    }

    func testContextAnalysisUsesValidEverydayOverrideWhenLegacyGlobalProfileIsInvalid() async throws {
        var connection = connection()
        connection.observedConfigurationRevision = String(repeating: "b", count: 64)
        let status = try fixture { root in
            root["configurationRevision"] = String(repeating: "b", count: 64)
            var tasks = root["tasks"] as! [String: [String: Any]]
            tasks["ask"] = ["configured": false, "provider": "", "model": "", "promptVersion": "ask-v1",
                            "capabilities": [], "configurationError": "provider_model_incompatible"]
            root["tasks"] = tasks
        }
        let legacy = Data(#"{"protocolVersion":2,"release":"legacy","configured":false,"provider":"openai","model":"unknown","promptVersion":"context-v2","capabilities":["analysis-context-v2"]}"#.utf8)
        let transport = DiscoveryTransport(data: Data(#"{"candidates":[],"highlights":[],"uncertainties":[]}"#.utf8),
                                           statusData: status, legacyStatusData: legacy)
        _ = try await MioCloudService.analyze(analysisPayload(contextContract: true), connection: connection,
                                             transport: { try await transport.send($0) })
        let requests = await transport.requests()
        XCTAssertEqual(requests.map { $0.url!.path }, ["/v2/status", "/v2/analyze"])
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "X-Mio-Configuration-Revision"), connection.observedConfigurationRevision)
    }

    func testContextAnalysisStopsBeforePostWhenTaskDiscoveryRevisionChanged() async throws {
        var connection = connection()
        connection.observedConfigurationRevision = String(repeating: "b", count: 64)
        let legacy = Data(#"{"protocolVersion":2,"release":"legacy","configured":true,"provider":"openai","model":"fixture","promptVersion":"context-v2","capabilities":["analysis-context-v2"]}"#.utf8)
        let transport = DiscoveryTransport(data: Data(#"{"candidates":[],"highlights":[],"uncertainties":[]}"#.utf8),
                                           statusData: try fixture(), legacyStatusData: legacy)
        do {
            _ = try await MioCloudService.analyze(analysisPayload(contextContract: true), connection: connection,
                                                  transport: { try await transport.send($0) })
            XCTFail("Changed discovery requires reactivation before generation")
        } catch MioCloudError.gateway(409, .configurationChanged) {} catch { XCTFail("Unexpected error: \(error)") }
        let requests = await transport.requests()
        XCTAssertEqual(requests.map { $0.url!.path }, ["/v2/status"])
    }

    func testBoundedDottedFutureProviderDoesNotDisableOtherTasks() throws {
        let status = try MioGatewayStatusV2.decode(fixture { root in
            var tasks = root["tasks"] as! [String: [String: Any]]
            tasks["lesson"] = ["configured": false, "provider": "unreviewed.provider", "model": "future:model",
                               "promptVersion": "lesson-v1", "capabilities": [], "configurationError": "provider_model_incompatible"]
            root["tasks"] = tasks
        })
        XCTAssertEqual(status.tasks.lesson.provider, "unreviewed.provider")
        XCTAssertNoThrow(try status.requireTask(.everyday))
        XCTAssertThrowsError(try status.requireTask(.lesson))
    }

    func testGlobalConfigurationErrorIsBoundedAndDiscoverable() throws {
        let status = try MioGatewayStatusV2.decode(fixture { root in
            var tasks = root["tasks"] as! [String: [String: Any]]
            tasks["ask"] = ["configured": false, "provider": "", "model": "", "promptVersion": "ask-v1",
                            "capabilities": [], "configurationError": "gateway_configuration_invalid"]
            root["tasks"] = tasks
        })
        XCTAssertEqual(status.tasks.ask.configurationError, .gatewayConfigurationInvalid)
        XCTAssertThrowsError(try status.requireTask(.ask))
        XCTAssertNoThrow(try status.requireTask(.lesson))
    }

    func testNormalizedUsageAndProvenanceHeadersReachSafeDiagnostics() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: connection().endpoint, statusCode: 200, httpVersion: nil,
            headerFields: ["X-Mio-Returned-Model": "provider/model:revision", "X-Mio-Upstream-Request-ID": "req_fixture-42",
                           "X-Mio-Usage-Input-Tokens": "123", "X-Mio-Usage-Output-Tokens": "45", "X-Mio-Usage-Reasoning-Tokens": "0"]))
        let object = try metadataObject(MioGatewayMetadata(response: response).sanitized())
        XCTAssertEqual(object["returnedModel"] as? String, "provider/model:revision")
        XCTAssertEqual(object["upstreamRequestID"] as? String, "req_fixture-42")
        XCTAssertEqual(object["inputTokens"] as? Int, 123)
        XCTAssertEqual(object["outputTokens"] as? Int, 45)
        XCTAssertEqual(object["reasoningTokens"] as? Int, 0)
        let legacy = try JSONDecoder().decode(MioGatewayMetadata.self, from: Data(#"{"release":"legacy","model":"fixture:model-v1"}"#.utf8))
        XCTAssertNil(try metadataObject(legacy)["inputTokens"])
    }

    func testUnsafeProvenanceHeadersAndPersistedMetadataAreDiscarded() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: connection().endpoint, statusCode: 200, httpVersion: nil,
            headerFields: ["X-Mio-Model": "https://private.invalid", "X-Mio-Returned-Model": "sk-private",
                           "X-Mio-Upstream-Request-ID": "https://private.invalid", "X-Mio-Usage-Input-Tokens": "-1",
                           "X-Mio-Usage-Output-Tokens": "1000000001", "X-Mio-Usage-Reasoning-Tokens": "private body"]))
        let fromHeaders = try metadataObject(MioGatewayMetadata(response: response).sanitized())
        for field in ["model", "returnedModel", "upstreamRequestID", "inputTokens", "outputTokens", "reasoningTokens"] {
            XCTAssertNil(fromHeaders[field], field)
        }
        let stored = Data(#"{"model":"https://private.invalid","returnedModel":"gsk_private","upstreamRequestID":"private arbitrary body","inputTokens":-1,"outputTokens":1000000001,"reasoningTokens":-10}"#.utf8)
        let cleaned = try metadataObject(JSONDecoder().decode(MioGatewayMetadata.self, from: stored).sanitized())
        for field in ["model", "returnedModel", "upstreamRequestID", "inputTokens", "outputTokens", "reasoningTokens"] {
            XCTAssertNil(cleaned[field], field)
        }
        for secret in ["sk_private", "gsk_private", "AIzaFixturePrivate", "Sk_Private", "GSK_Private", "aIzAFixturePrivate"] {
            let response = try XCTUnwrap(HTTPURLResponse(url: connection().endpoint, statusCode: 200, httpVersion: nil,
                headerFields: ["X-Mio-Model": secret, "X-Mio-Returned-Model": secret, "X-Mio-Upstream-Request-ID": secret]))
            let object = try metadataObject(MioGatewayMetadata(response: response).sanitized())
            XCTAssertNil(object["model"])
            XCTAssertNil(object["returnedModel"])
            XCTAssertNil(object["upstreamRequestID"])
        }
    }

    private func metadataObject(_ metadata: MioGatewayMetadata) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
    }

    private func analysisPayload(contextContract: Bool) -> MioAnalysisRequest {
        .init(mode: .everyday, timeZone: "Europe/Stockholm", fragments: [
            .init(id: "00000000-0000-0000-0000-000000000001:0", text: "Syntetiskt valt utdrag.", occurredAt: "2026-10-02T10:00:00Z")
        ], usesContextContract: contextContract)
    }

    private func connection() -> MioCloudConnection {
        .init(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "fixture_gateway")
    }

    private func fixture(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var root: [String: Any] = ["protocolVersion": 2, "release": "fixture-v3", "configurationRevision": String(repeating: "a", count: 64),
            "tasks": [
                "ask": ["configured": true, "provider": "future_provider-2", "model": "question:model-v1", "promptVersion": "ask-v1",
                        "capabilities": ["reasoning-off", "temperature-zero", "strict-json", "ask-v1", "future-feature-v9"], "configurationError": NSNull()],
                "everyday": ["configured": true, "provider": "another_provider", "model": "context:model-v1", "promptVersion": "context-v2",
                        "capabilities": ["reasoning-off", "temperature-zero", "strict-json", "analysis-context-v2"], "configurationError": NSNull()],
                "lesson": ["configured": true, "provider": "third_provider", "model": "lesson-model", "promptVersion": "lesson-v1",
                        "capabilities": ["reasoning-off", "temperature-zero", "strict-json", "lesson-notes-v1"], "configurationError": NSNull()]
            ], "quota": ["limit": 100, "remaining": 73, "resetAt": "2026-10-03T00:00:00.000Z"]]
        mutate(&root)
        return try JSONSerialization.data(withJSONObject: root)
    }
}

private actor DiscoveryTransport {
    let data: Data
    let status: Int
    let statusData: Data?
    let legacyStatusData: Data?
    private var sent: [URLRequest] = []
    init(data: Data, status: Int = 200, statusData: Data? = nil, legacyStatusData: Data? = nil) {
        self.data = data; self.status = status; self.statusData = statusData; self.legacyStatusData = legacyStatusData
    }
    func firstRequest() -> URLRequest? { sent.first }
    func requests() -> [URLRequest] { sent }
    func send(_ request: URLRequest) throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
        sent.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        let responseData: Data
        switch request.url?.path {
        case "/v1/status": responseData = legacyStatusData ?? statusData ?? data
        case "/v2/status": responseData = statusData ?? data
        default: responseData = data
        }
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in responseData { continuation.yield(byte) }
            continuation.finish()
        }
        return (stream, response)
    }
}
