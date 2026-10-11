import Foundation
import XCTest
@testable import Mio

final class MioConnectionDiscoveryTests: XCTestCase {
    @MainActor func testSuccessfulDiscoveryCachesByCredentialsAndFrozenRevisionForThirtySeconds() async throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        var calls = 0
        let discovery = MioConnectionDiscovery(fetchStatus: { _ in calls += 1; return syntheticGatewayStatus() }, now: { clock })
        let original = syntheticCloudConnection()
        let first = try await discovery.prepare(connection: original, task: .ask)
        XCTAssertEqual(first.connection.observedConfigurationRevision, String(repeating: "a", count: 64))
        clock.addTimeInterval(29)
        _ = try await discovery.prepare(connection: first.connection, task: .lesson)
        XCTAssertEqual(calls, 1)
        clock.addTimeInterval(1)
        _ = try await discovery.prepare(connection: original, task: .ask)
        XCTAssertEqual(calls, 2)
        var rotated = original
        rotated = .init(endpoint: original.endpoint, token: "rotated")
        _ = try await discovery.prepare(connection: rotated, task: .ask)
        XCTAssertEqual(calls, 3)
    }

    @MainActor func testTaskPolicyAndChangedFrozenRevisionRejectBeforeGeneration() async throws {
        let discovery = MioConnectionDiscovery(fetchStatus: { _ in syntheticGatewayStatus(revision: "b") })
        var frozen = syntheticCloudConnection()
        frozen.observedConfigurationRevision = String(repeating: "a", count: 64)
        do { _ = try await discovery.prepare(connection: frozen, task: .everyday); XCTFail("Require manual reactivation") }
        catch MioCloudError.gateway(409, .configurationChanged) {} catch { XCTFail("Unexpected error \(error)") }
        let invalid = MioConnectionDiscovery(fetchStatus: { _ in syntheticGatewayStatus(askCapabilities: ["ask-v1"]) })
        do { _ = try await invalid.prepare(connection: syntheticCloudConnection(), task: .ask); XCTFail("Missing immutable policy") }
        catch MioCloudError.incompatibleGateway {} catch { XCTFail("Unexpected error \(error)") }
        XCTAssertNotNil(invalid.lastStatus, "Valid task discovery can describe an unavailable selected task")
    }

    @MainActor func testForceRefreshAndAuthOrRevisionFailureInvalidateSuccessfulCache() async throws {
        var calls = 0
        let discovery = MioConnectionDiscovery(fetchStatus: { _ in calls += 1; return syntheticGatewayStatus() })
        let connection = syntheticCloudConnection()
        _ = try await discovery.prepare(connection: connection, task: .ask)
        _ = try await discovery.prepare(connection: connection, task: .ask, forceRefresh: true)
        XCTAssertEqual(calls, 2)
        for error in [MioCloudError.serverStatus(401), .serverStatus(403), .gateway(409, .configurationChanged)] {
            discovery.handle(error: error)
            XCTAssertNil(discovery.lastStatus)
            _ = try await discovery.prepare(connection: connection, task: .ask)
        }
        XCTAssertEqual(calls, 5)
    }

    @MainActor func testInvalidationRejectsLateUncancellableDiscoveryResult() async throws {
        var continuation: CheckedContinuation<MioGatewayStatusV2, Never>?
        let discovery = MioConnectionDiscovery(fetchStatus: { _ in await withCheckedContinuation { continuation = $0 } })
        let task = Task { try await discovery.prepare(connection: syntheticCloudConnection(), task: .ask) }
        for _ in 0..<1_000 { if continuation != nil { break }; await Task.yield() }
        XCTAssertNotNil(continuation)
        discovery.invalidate()
        continuation?.resume(returning: syntheticGatewayStatus())
        do { _ = try await task.value; XCTFail("Invalidated result must never enter the cache") }
        catch is CancellationError {} catch MioCloudError.changedConfiguration {} catch { XCTFail("Unexpected error \(error)") }
        XCTAssertNil(discovery.lastStatus)
        XCTAssertFalse(discovery.isChecking)
    }

    @MainActor func testCallerCancellationStopsAnUnsharedGatewayRequest() async throws {
        var started = false
        var cancelled = false
        let discovery = MioConnectionDiscovery(fetchStatus: { _ in
            started = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled = true; throw error }
            return syntheticGatewayStatus()
        })
        let caller = Task { try await discovery.prepare(connection: syntheticCloudConnection(), task: .ask) }
        for _ in 0..<1_000 { if started { break }; await Task.yield() }
        XCTAssertTrue(started)
        caller.cancel()
        for _ in 0..<1_000 { if cancelled && !discovery.isChecking { break }; await Task.yield() }
        XCTAssertTrue(cancelled, "The user's cancellation must reach the GET transport")
        XCTAssertFalse(discovery.isChecking)
        XCTAssertNil(discovery.lastStatus)
        discovery.invalidate() // Release a regressed, still sleeping transport after assertions.
        do { _ = try await caller.value; XCTFail("Cancelled discovery must not prepare generation") }
        catch is CancellationError {} catch MioCloudError.changedConfiguration {} catch { XCTFail("Unexpected error \(error)") }
    }

    @MainActor func testCancellingOneSharedCallerKeepsTheOtherAndDoesNotWaitForTheTransport() async throws {
        var continuation: CheckedContinuation<MioGatewayStatusV2, Never>?
        var firstFinished = false
        var fetches = 0
        let discovery = MioConnectionDiscovery(fetchStatus: { _ in
            fetches += 1
            return await withCheckedContinuation { continuation = $0 }
        })
        let first = Task {
            defer { firstFinished = true }
            return try await discovery.prepare(connection: syntheticCloudConnection(), task: .ask)
        }
        for _ in 0..<1_000 { if continuation != nil { break }; await Task.yield() }
        let second = Task { try await discovery.prepare(connection: syntheticCloudConnection(), task: .lesson) }
        for _ in 0..<100 { await Task.yield() }
        first.cancel()
        for _ in 0..<1_000 { if firstFinished { break }; await Task.yield() }
        XCTAssertTrue(firstFinished, "A caller can leave before an uncancellable GET finishes")
        XCTAssertTrue(discovery.isChecking, "The remaining caller still owns discovery")
        continuation?.resume(returning: syntheticGatewayStatus())
        do { _ = try await first.value; XCTFail("Cancelled caller must not receive a prepared connection") }
        catch is CancellationError {} catch { XCTFail("Unexpected error \(error)") }
        let prepared = try await second.value
        XCTAssertEqual(prepared.connection.observedConfigurationRevision, String(repeating: "a", count: 64))
        _ = try await discovery.prepare(connection: prepared.connection, task: .everyday)
        XCTAssertEqual(fetches, 1)
        XCTAssertNotNil(discovery.lastStatus)
    }

    @MainActor func testCancelledUncancellableResultCannotResurrectCacheOrClearANewerRequest() async throws {
        var continuations: [CheckedContinuation<MioGatewayStatusV2, Never>] = []
        var cancelledCallerFinished = false
        let discovery = MioConnectionDiscovery(fetchStatus: { _ in
            await withCheckedContinuation { continuations.append($0) }
        })
        let old = Task {
            defer { cancelledCallerFinished = true }
            return try await discovery.prepare(connection: syntheticCloudConnection(), task: .ask)
        }
        for _ in 0..<1_000 { if continuations.count == 1 { break }; await Task.yield() }
        old.cancel()
        for _ in 0..<1_000 { if cancelledCallerFinished { break }; await Task.yield() }
        XCTAssertTrue(cancelledCallerFinished)
        XCTAssertFalse(discovery.isChecking)
        let newer = Task { try await discovery.prepare(connection: syntheticCloudConnection(), task: .ask) }
        for _ in 0..<1_000 { if continuations.count == 2 { break }; await Task.yield() }
        XCTAssertEqual(continuations.count, 2)
        continuations[0].resume(returning: syntheticGatewayStatus())
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(discovery.isChecking)
        XCTAssertNil(discovery.lastStatus)
        if continuations.count == 2 { continuations[1].resume(returning: syntheticGatewayStatus(revision: "b")) }
        do { _ = try await old.value; XCTFail("Old request must stay cancelled") }
        catch is CancellationError {} catch { XCTFail("Unexpected error \(error)") }
        let newResult = try await newer.value
        XCTAssertEqual(newResult.status.configurationRevision, String(repeating: "b", count: 64))
        XCTAssertEqual(discovery.lastStatus?.configurationRevision, String(repeating: "b", count: 64))
    }

    @MainActor func testFailedRefreshDoesNotReuseAFormerSuccessfulObservation() async throws {
        var fetches = 0
        let discovery = MioConnectionDiscovery(fetchStatus: { _ in
            fetches += 1
            if fetches == 2 { throw MioCloudError.network }
            return syntheticGatewayStatus(revision: fetches == 1 ? "a" : "b")
        })
        let connection = syntheticCloudConnection()
        _ = try await discovery.prepare(connection: connection, task: .ask)
        do { _ = try await discovery.inspect(connection: connection, forceRefresh: true); XCTFail("Refresh should fail") }
        catch MioCloudError.network {} catch { XCTFail("Unexpected error \(error)") }
        XCTAssertNil(discovery.lastStatus)
        XCTAssertNil(discovery.lastCheckedAt)
        XCTAssertNotNil(discovery.errorMessage)
        let refreshed = try await discovery.prepare(connection: connection, task: .ask)
        XCTAssertEqual(refreshed.status.configurationRevision, String(repeating: "b", count: 64))
        XCTAssertEqual(fetches, 3)
    }
}

func syntheticCloudConnection() -> MioCloudConnection {
    .init(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
}

func syntheticGatewayStatus(revision: Character = "a", askCapabilities: [String]? = nil) -> MioGatewayStatusV2 {
    func task(_ id: MioAITaskID) -> MioGatewayTaskStatus {
        .init(configured: true, provider: "fixture", model: "fixture-model", promptVersion: "fixture-v1",
              capabilities: id == .ask ? askCapabilities ?? Array(id.requiredCapabilities) : Array(id.requiredCapabilities),
              configurationError: nil)
    }
    return .init(protocolVersion: 2, release: "fixture", configurationRevision: String(repeating: String(revision), count: 64),
                 tasks: .init(ask: task(.ask), everyday: task(.everyday), lesson: task(.lesson)),
                 quota: .init(limit: 100, remaining: 73, resetAt: "2026-10-03T00:00:00.000Z"))
}

@MainActor func syntheticPreparedConnection(_ connection: MioCloudConnection, task: MioAITaskID) async throws -> MioPreparedConnection {
    let status = syntheticGatewayStatus()
    try status.requireTask(task)
    var selected = connection
    selected.observedConfigurationRevision = status.configurationRevision
    return .init(connection: selected, status: status)
}
