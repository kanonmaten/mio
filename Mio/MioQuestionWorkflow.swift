import Foundation
import Observation

struct MioQuestionResult: Equatable, Sendable {
    let outcome: MioOperationOutcome
    let answer: String?
}

struct MioAnswerNoteDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let generation: UUID
    var title: String
    var body: String
}

/// Supervises one explicitly approved question. Answers remain temporary view state;
/// invalidation never retries or begins model work.
@MainActor @Observable
final class MioQuestionWorkflow {
    private(set) var generation = UUID()
    private(set) var isSending = false
    private(set) var answerDraft: MioAnswerNoteDraft?
    @ObservationIgnored private var currentTask: Task<String, Error>?
    @ObservationIgnored private let send: @MainActor (MioCloudRequest, MioCloudConnection) async throws -> String
    @ObservationIgnored private let configurationMatches: @MainActor (MioCloudConnection) -> Bool
    @ObservationIgnored private let canSend: @MainActor () -> Bool

    init(configurationMatches: @escaping @MainActor (MioCloudConnection) -> Bool = {
        guard let current = try? MioCloudSettings.connection() else { return false }
        return $0.hasSameCredentials(as: current)
    }, send: @escaping @MainActor (MioCloudRequest, MioCloudConnection) async throws -> String = {
        try await MioCloudService.ask($0, connection: $1)
    }, canSend: @escaping @MainActor () -> Bool = { !MioMaintenanceState.shared.blocksWork }) {
        self.send = send
        self.configurationMatches = configurationMatches
        self.canSend = canSend
    }

    func invalidate() {
        generation = UUID()
        answerDraft = nil
        currentTask?.cancel()
        currentTask = nil
        isSending = false
    }

    func sendApproved(_ request: MioCloudRequest, connection: MioCloudConnection,
                      expectedGeneration: UUID? = nil) async -> MioQuestionResult {
        if let expectedGeneration, expectedGeneration != generation {
            return MioQuestionResult(outcome: .cancelled, answer: nil)
        }
        guard canSend() else {
            return MioQuestionResult(outcome: .conflict("En lokal dataåtgärd väntar. Slutför den innan du skickar frågan."), answer: nil)
        }
        guard !isSending else {
            return MioQuestionResult(outcome: .conflict("En fråga är redan skickad. Avbryt eller vänta innan du granskar en ny fråga."), answer: nil)
        }
        guard configurationMatches(connection) else {
            MioConnectionDiscovery.shared.invalidate(); invalidate()
            return MioQuestionResult(outcome: .cancelled, answer: nil)
        }
        do { _ = try request.validatedData(); try Task.checkCancellation() }
        catch is CancellationError { return MioQuestionResult(outcome: .cancelled, answer: nil) }
        catch { return MioQuestionResult(outcome: .failure(error.localizedDescription), answer: nil) }
        answerDraft = nil
        let token = generation
        let task = Task { try await send(request, connection) }
        currentTask = task
        isSending = true
        defer {
            if generation == token {
                currentTask = nil
                isSending = false
            }
        }
        return await withTaskCancellationHandler {
            do {
                let answer = try await task.value
                guard generation == token, !Task.isCancelled, !task.isCancelled else {
                    return MioQuestionResult(outcome: .cancelled, answer: nil)
                }
                guard configurationMatches(connection) else {
                    MioConnectionDiscovery.shared.invalidate(); invalidate()
                    return MioQuestionResult(outcome: .cancelled, answer: nil)
                }
                answerDraft = MioAnswerNoteDraft(id: UUID(), generation: token,
                    title: String(request.question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)), body: answer)
                return MioQuestionResult(outcome: .success, answer: answer)
            } catch is CancellationError {
                return MioQuestionResult(outcome: .cancelled, answer: nil)
            } catch {
                guard generation == token, !Task.isCancelled, !task.isCancelled else {
                    return MioQuestionResult(outcome: .cancelled, answer: nil)
                }
                guard configurationMatches(connection) else {
                    MioConnectionDiscovery.shared.invalidate(); invalidate()
                    return MioQuestionResult(outcome: .cancelled, answer: nil)
                }
                MioConnectionDiscovery.shared.handle(error: error)
                return MioQuestionResult(outcome: .failure(error.localizedDescription), answer: nil)
            }
        } onCancel: { task.cancel() }
    }
}
