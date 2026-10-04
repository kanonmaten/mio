import Foundation
import Observation

struct MioPreparedConnection: Sendable {
    let connection: MioCloudConnection
    let status: MioGatewayStatusV2
}

@MainActor @Observable
final class MioConnectionDiscovery {
    static let shared = MioConnectionDiscovery()
    private(set) var lastStatus: MioGatewayStatusV2?
    private(set) var lastCheckedAt: Date?
    private(set) var isChecking = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let fetchStatus: @MainActor (MioCloudConnection) async throws -> MioGatewayStatusV2
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var cache: Cache?
    @ObservationIgnored private var pending: Pending?
    private struct Cache {
        let original: MioCloudConnection
        let prepared: MioCloudConnection
        let status: MioGatewayStatusV2
        let checkedAt: Date
    }
    private struct Pending {
        let id: UUID
        let connection: MioCloudConnection
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }
    private struct Waiter {
        let continuation: CheckedContinuation<MioGatewayStatusV2, Error>
        let cancellation: CancellationMarker
    }
    /// Cancellation is reported outside the main actor. The marker closes the
    /// race with a GET completion before its actor-side cleanup can run.
    private final class CancellationMarker: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    init(fetchStatus: @escaping @MainActor (MioCloudConnection) async throws -> MioGatewayStatusV2 = {
        try await MioCloudService.statusV2(connection: $0)
    }, now: @escaping @MainActor () -> Date = { .now }) {
        self.fetchStatus = fetchStatus; self.now = now
    }

    func inspect(connection: MioCloudConnection, forceRefresh: Bool = false) async throws -> MioGatewayStatusV2 {
        try Task.checkCancellation()
        if !forceRefresh, let cache,
           connection == cache.original || connection == cache.prepared {
            let age = now().timeIntervalSince(cache.checkedAt)
            if (0..<30).contains(age) { return cache.status }
        }
        if let pending, pending.connection != connection { invalidate() }
        let waiterID = UUID()
        let cancellation = CancellationMarker()
        let status: MioGatewayStatusV2 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !cancellation.isCancelled else {
                    continuation.resume(throwing: CancellationError()); return
                }
                let waiter = Waiter(continuation: continuation, cancellation: cancellation)
                if pending != nil { pending?.waiters[waiterID] = waiter }
                else {
                    cache = nil; lastStatus = nil; lastCheckedAt = nil; errorMessage = nil
                    let requestID = UUID()
                    let token = generation
                    let fetchStatus = self.fetchStatus
                    let task = Task { [weak self] in
                        let result: Result<MioGatewayStatusV2, Error>
                        do {
                            let value = try await fetchStatus(connection)
                            try Task.checkCancellation()
                            result = .success(value)
                        } catch { result = .failure(error) }
                        self?.finish(requestID: requestID, generation: token, result: result)
                    }
                    pending = Pending(id: requestID, connection: connection, task: task, waiters: [waiterID: waiter])
                    isChecking = true
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.cancel(waiterID: waiterID) }
        }
        try Task.checkCancellation()
        return status
    }

    private func cancel(waiterID: UUID) {
        guard let waiter = pending?.waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if pending?.waiters.isEmpty == true {
            pending?.task.cancel(); pending = nil; isChecking = false
        }
    }

    private func finish(requestID: UUID, generation token: UUID, result: Result<MioGatewayStatusV2, Error>) {
        guard generation == token, let request = pending, request.id == requestID else { return }
        pending = nil; isChecking = false
        let hasCaller = request.waiters.values.contains { !$0.cancellation.isCancelled }
        if hasCaller {
            switch result {
            case .success(let status):
                var prepared = request.connection
                prepared.observedConfigurationRevision = status.configurationRevision
                let checkedAt = now()
                cache = Cache(original: request.connection, prepared: prepared, status: status, checkedAt: checkedAt)
                lastStatus = status; lastCheckedAt = checkedAt; errorMessage = nil
            case .failure(let error):
                handle(error: error)
                if !(error is CancellationError) {
                    errorMessage = (error as? MioCloudError)?.localizedDescription ?? MioCloudError.network.localizedDescription
                }
            }
        }
        for waiter in request.waiters.values {
            if waiter.cancellation.isCancelled { waiter.continuation.resume(throwing: CancellationError()) }
            else { waiter.continuation.resume(with: result) }
        }
    }

    func prepare(connection: MioCloudConnection, task: MioAITaskID, forceRefresh: Bool = false) async throws -> MioPreparedConnection {
        let status = try await inspect(connection: connection, forceRefresh: forceRefresh)
        if let observed = connection.observedConfigurationRevision, observed != status.configurationRevision {
            invalidate()
            throw MioCloudError.gateway(409, .configurationChanged)
        }
        try status.requireTask(task)
        var prepared = connection
        prepared.observedConfigurationRevision = status.configurationRevision
        return MioPreparedConnection(connection: prepared, status: status)
    }

    func invalidate() {
        let request = pending
        generation = UUID(); pending = nil; request?.task.cancel(); cache = nil
        lastStatus = nil; lastCheckedAt = nil; errorMessage = nil; isChecking = false
        for waiter in request?.waiters.values ?? [:].values {
            waiter.continuation.resume(throwing: waiter.cancellation.isCancelled
                ? CancellationError() : MioCloudError.changedConfiguration)
        }
    }

    func handle(error: Error) {
        guard let error = error as? MioCloudError else { return }
        switch error {
        case .serverStatus(401), .serverStatus(403), .changedConfiguration,
             .gateway(401, _), .gateway(403, _), .gateway(409, .configurationChanged): invalidate()
        default: break
        }
    }
}
