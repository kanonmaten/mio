import Foundation

/// The result of a product command; unrelated presentation errors cannot decide success.
enum MioOperationOutcome: Equatable, Sendable {
    case success
    case failure(String)
    case cancelled
    case conflict(String)

    var isSuccess: Bool { self == .success }
    var message: String? {
        switch self {
        case .success: nil
        case let .failure(message), let .conflict(message): message
        case .cancelled: "Åtgärden avbröts."
        }
    }
}
