import Foundation
import Observation

/// An exclusive snapshot/deletion waits for already admitted writes and rejects new ones.
@MainActor @Observable
final class MioMaintenanceState {
    static let shared = MioMaintenanceState()
    var isDeleting = false
    private(set) var isSnapshotting = false
    private(set) var activeWrites = 0
    private(set) var recoveryBlocked = false
    var blocksWork: Bool { isDeleting || isSnapshotting || recoveryBlocked }
    @ObservationIgnored private var snapshotWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var exclusiveWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func beginWrite() -> Bool {
        guard !blocksWork else { return false }
        activeWrites += 1
        return true
    }

    func endWrite() {
        activeWrites = max(0, activeWrites - 1)
        if activeWrites == 0 {
            let waiters = idleWaiters; idleWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    func beginExclusive(deleting: Bool) async -> Bool {
        guard !isDeleting, !isSnapshotting, deleting || !recoveryBlocked else { return false }
        if deleting { isDeleting = true } else { isSnapshotting = true }
        if activeWrites > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        return true
    }

    func setRecoveryBlocked(_ blocked: Bool) { recoveryBlocked = blocked }

    func waitForSnapshot() async {
        if isSnapshotting { await withCheckedContinuation { snapshotWaiters.append($0) } }
    }

    func waitForExclusive() async {
        guard isDeleting || isSnapshotting, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() }
                else { exclusiveWaiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.exclusiveWaiters.removeValue(forKey: id)?.resume() }
        }
    }

    func endExclusive() {
        isDeleting = false; isSnapshotting = false
        let waiters = snapshotWaiters; snapshotWaiters = []
        waiters.forEach { $0.resume() }
        let exclusive = exclusiveWaiters; exclusiveWaiters = [:]
        exclusive.values.forEach { $0.resume() }
    }
}
