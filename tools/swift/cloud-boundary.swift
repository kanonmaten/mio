// A platform boundary, never a model/repository/coordinator substitute.
@MainActor enum MioSystemServices {
    static let shared = PortableSystemActions()
}
@MainActor final class PortableSystemActions {
    var errorMessage: String? { "Unavailable portable boundary" }
    func cancelActions(for id: UUID) async -> Bool { false }
}
extension URLSession {
    func bytes(for request: URLRequest, delegate: URLSessionTaskDelegate?) async throws
        -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
        throw MioCloudError.network
    }
}
