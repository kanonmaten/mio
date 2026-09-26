import Foundation
import Observation

/// A deletion barrier shared by UI writes. It prevents queued save tasks from
/// recreating private content after the user has erased all local data.
@MainActor
@Observable
final class MioMaintenanceState {
    static let shared = MioMaintenanceState()
    var isDeleting = false
    private(set) var activeWrites = 0

    func beginWrite() -> Bool {
        guard !isDeleting else { return false }
        activeWrites += 1
        return true
    }

    func endWrite() {
        activeWrites = max(0, activeWrites - 1)
    }
}
