import Foundation
import Observation

enum MioDeletionScope: String, Codable, Hashable, Sendable {
    case all, session, content
}

enum MioDeletionStep: String, Codable, Hashable, Sendable {
    case systemActions, credentials, sessions, content, assistant, diagnostics, contentLinks
}

struct MioDeletionOperation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let scope: MioDeletionScope
    let targetID: UUID?
    var completedSteps: [MioDeletionStep]

    var requiredSteps: [MioDeletionStep] {
        switch scope {
        case .all: [.systemActions, .credentials, .sessions, .content, .assistant, .diagnostics]
        case .session: [.contentLinks, .assistant, .sessions]
        case .content: [.systemActions, .content]
        }
    }
}

enum MioDeletionJournalError: LocalizedError {
    case unsupportedSchema, malformedDocument, invalidTarget, missingOperation, invalidStep, incompleteOperation

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "Raderingsjournalen har en okänd version och har inte ändrats."
        case .malformedDocument: "Raderingsjournalen innehåller ogiltiga identifierare eller steg och har inte ändrats."
        case .invalidTarget: "Raderingen saknar en giltig identifierare."
        case .missingOperation: "Raderingsåtgärden finns inte i journalen."
        case .invalidStep: "Raderingsstegen måste slutföras i rätt ordning."
        case .incompleteOperation: "Raderingen har återstående steg."
        }
    }
}

actor MioDeletionJournal {
    private let storageURL: URL
    private let fileManager: FileManager

    init(storageURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.storageURL = storageURL ?? support.appendingPathComponent("Mio", isDirectory: true)
            .appendingPathComponent("operations-v1.json")
    }

    private struct Document: Codable {
        let schemaVersion: Int
        var operations: [MioDeletionOperation]
        init(operations: [MioDeletionOperation]) { schemaVersion = 1; self.operations = operations }
    }

    // This journal is small and deliberately reread before each mutation. An external or
    // future-schema file must never be replaced by a stale in-memory recovery snapshot.
    func pendingOperations() throws -> [MioDeletionOperation] { try load().operations }

    func begin(scope: MioDeletionScope, targetID: UUID? = nil) throws -> MioDeletionOperation {
        try validateTarget(scope: scope, targetID: targetID)
        var document = try load()
        if let pending = document.operations.first(where: { $0.scope == scope && $0.targetID == targetID }) {
            return pending
        }
        let operation = MioDeletionOperation(id: UUID(), scope: scope, targetID: targetID, completedSteps: [])
        document.operations.append(operation)
        try save(document)
        return operation
    }

    func markCompleted(operationID: UUID, step: MioDeletionStep) throws {
        var document = try load()
        guard let index = document.operations.firstIndex(where: { $0.id == operationID }) else {
            throw MioDeletionJournalError.missingOperation
        }
        let operation = document.operations[index]
        if operation.completedSteps.contains(step) { return }
        guard operation.requiredSteps.dropFirst(operation.completedSteps.count).first == step else {
            throw MioDeletionJournalError.invalidStep
        }
        document.operations[index].completedSteps.append(step)
        try save(document)
    }

    func removeCompleted(operationID: UUID) throws {
        var document = try load()
        guard let index = document.operations.firstIndex(where: { $0.id == operationID }) else { return }
        guard document.operations[index].completedSteps == document.operations[index].requiredSteps else {
            throw MioDeletionJournalError.incompleteOperation
        }
        document.operations.remove(at: index)
        if document.operations.isEmpty {
            // Removal failures retain the completed intent for a visible, idempotent retry.
            try fileManager.removeItem(at: storageURL)
        } else {
            try save(document)
        }
    }

    private func load() throws -> Document {
        guard fileManager.fileExists(atPath: storageURL.path) else { return Document(operations: []) }
        let data = try Data(contentsOf: storageURL)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int else {
            throw MioDeletionJournalError.malformedDocument
        }
        guard version == 1 else { throw MioDeletionJournalError.unsupportedSchema }
        guard Set(object.keys) == Set(["schemaVersion", "operations"]),
              let operations = object["operations"] as? [[String: Any]],
              operations.allSatisfy({ entry in
                  let keys = Set(entry.keys)
                  return keys.isSubset(of: ["id", "scope", "targetID", "completedSteps"])
                      && Set(["id", "scope", "completedSteps"]).isSubset(of: keys)
              }) else { throw MioDeletionJournalError.malformedDocument }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw MioDeletionJournalError.malformedDocument }
        try validate(document)
        return document
    }

    private func validate(_ document: Document) throws {
        guard document.schemaVersion == 1 else { throw MioDeletionJournalError.unsupportedSchema }
        var identities = Set<UUID>()
        var targets = Set<String>()
        for operation in document.operations {
            try validateTarget(scope: operation.scope, targetID: operation.targetID)
            let target = operation.scope.rawValue + ":" + (operation.targetID?.uuidString ?? "")
            guard identities.insert(operation.id).inserted, targets.insert(target).inserted,
                  operation.completedSteps.count <= operation.requiredSteps.count,
                  operation.completedSteps == Array(operation.requiredSteps.prefix(operation.completedSteps.count)) else {
                throw MioDeletionJournalError.malformedDocument
            }
        }
    }

    private func validateTarget(scope: MioDeletionScope, targetID: UUID?) throws {
        guard scope == .all ? targetID == nil : targetID != nil else { throw MioDeletionJournalError.invalidTarget }
    }

    private func save(_ document: Document) throws {
        try validate(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try MioProtectedFileWriter.write(encoder.encode(document), to: storageURL, fileManager: fileManager)
    }
}

@MainActor
@Observable
final class MioDeletionRecovery {
    private(set) var pendingOperationID: UUID?
    private(set) var blockedStep: MioDeletionStep?
    private(set) var message: String?
    @ObservationIgnored private let journal: MioDeletionJournal
    @ObservationIgnored private let cancelWork: @MainActor (MioDeletionOperation) async -> Void
    @ObservationIgnored private let performStep: @MainActor (MioDeletionStep, MioDeletionOperation) async -> MioOperationOutcome
    @ObservationIgnored private var isRunning = false

    init(journal: MioDeletionJournal, cancelWork: @escaping @MainActor (MioDeletionOperation) async -> Void,
         performStep: @escaping @MainActor (MioDeletionStep, MioDeletionOperation) async -> MioOperationOutcome) {
        self.journal = journal
        self.cancelWork = cancelWork
        self.performStep = performStep
    }

    func begin(scope: MioDeletionScope, targetID: UUID? = nil) async -> MioOperationOutcome {
        guard !isRunning else { return runningConflict() }
        isRunning = true
        defer { isRunning = false }
        do {
            // The durable intent precedes cancellation as well as destructive effects.
            let operation = try await journal.begin(scope: scope, targetID: targetID)
            return await run(operationID: operation.id)
        } catch { return journalFailure(error) }
    }

    func resumePending() async -> MioOperationOutcome {
        guard !isRunning else { return runningConflict() }
        isRunning = true
        defer { isRunning = false }
        do {
            let operations = try await journal.pendingOperations()
            for operation in operations {
                let outcome = await run(operationID: operation.id)
                guard outcome.isSuccess else { return outcome }
            }
            clearBlockedState()
            return .success
        } catch { return journalFailure(error) }
    }

    func resume(operationID: UUID) async -> MioOperationOutcome {
        guard !isRunning else { return runningConflict() }
        isRunning = true
        defer { isRunning = false }
        return await run(operationID: operationID)
    }

    private func run(operationID: UUID) async -> MioOperationOutcome {
        pendingOperationID = operationID
        blockedStep = nil
        message = nil
        do {
            guard let operation = try await journal.pendingOperations().first(where: { $0.id == operationID }) else {
                clearBlockedState()
                return .success
            }
            await cancelWork(operation)
            var current = operation
            for step in operation.requiredSteps.dropFirst(operation.completedSteps.count) {
                blockedStep = step
                guard !Task.isCancelled else { return retain(.cancelled) }
                let outcome = await performStep(step, current)
                guard outcome.isSuccess else { return retain(outcome) }
                // A successful effect is recorded even if cancellation arrived during it.
                // If recording fails, the injected effect must tolerate being repeated.
                try await journal.markCompleted(operationID: operation.id, step: step)
                current.completedSteps.append(step)
                guard !Task.isCancelled else { return retain(.cancelled) }
            }
            blockedStep = nil
            try await journal.removeCompleted(operationID: operation.id)
            clearBlockedState()
            return .success
        } catch { return journalFailure(error) }
    }

    private func retain(_ outcome: MioOperationOutcome) -> MioOperationOutcome {
        message = outcome.message
        return outcome
    }

    private func journalFailure(_ error: Error) -> MioOperationOutcome {
        let detail = (error as? MioDeletionJournalError)?.errorDescription
            ?? "Raderingen kunde inte sparas eller slutföras. Försök igen."
        return retain(.failure(detail))
    }

    private func runningConflict() -> MioOperationOutcome {
        .conflict("En radering pågår redan. Vänta tills den är klar och försök igen.")
    }

    private func clearBlockedState() {
        pendingOperationID = nil
        blockedStep = nil
        message = nil
    }
}
