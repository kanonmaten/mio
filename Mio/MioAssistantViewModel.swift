import Foundation
import Observation

@MainActor
@Observable
final class MioAssistantViewModel {
    private(set) var suggestions: [MioSuggestion] = []
    private(set) var lessons: [MioLesson] = []
    private(set) var analyses: [MioAnalysisRecord] = []
    var errorMessage: String?
    private(set) var isBusy = false

    @ObservationIgnored private let repository: MioAssistantRepository
    @ObservationIgnored private var hasBootstrapped = false
    @ObservationIgnored private var processedSources: Set<MioProcessedSource> = []
    @ObservationIgnored private var lastRefreshRequest = 0
    @ObservationIgnored private var sessionsBeingDeleted: Set<UUID> = []
    @ObservationIgnored private var isDeletingAll = false

    init(repository: MioAssistantRepository = MioAssistantRepository()) {
        self.repository = repository
    }

    var exportDocument: MioAssistantStoreDocument {
        MioAssistantStoreDocument(suggestions: suggestions, lessons: lessons, processedSources: processedSources, analyses: analyses)
    }

    var pendingCount: Int { suggestions.filter { $0.state == .pending }.count }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        do {
            try await refresh()
            hasBootstrapped = true
        } catch {
            errorMessage = "Kunde inte läsa assistentens lokala data: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func propose(text: String, kind: MioContentKind, scheduledAt: Date = .now, sessionID: UUID? = nil) async -> Bool {
        guard !isBusy, MioMaintenanceState.shared.beginWrite() else { return false }
        isBusy = true
        defer {
            isBusy = false
            MioMaintenanceState.shared.endWrite()
        }
        do {
            let suggestion = try MioLocalSuggestionEngine.explicitSuggestion(
                text: text, kind: kind, scheduledAt: scheduledAt, sessionID: sessionID
            )
            try await repository.addSuggestion(suggestion)
            try await refresh()
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Kunde inte skapa förslaget: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func proposeQuestion(text: String, sessionID: UUID? = nil) async -> Bool {
        await change {
            let question = try MioLocalSuggestionEngine.explicitQuestion(text: text, sessionID: sessionID)
            try await self.repository.addSuggestion(question)
        }
    }

    /// Detection does not use the UI mutation gate: finalized speech callbacks must
    /// not be dropped while the user is answering another proposal.
    @discardableResult
    func detectSuggestions(in session: MioSession) async -> Int {
        guard !isDeletingAll, !sessionsBeingDeleted.contains(session.id),
              MioMaintenanceState.shared.beginWrite() else { return 0 }
        defer { MioMaintenanceState.shared.endWrite() }
        do {
            let count = try await repository.detectSuggestions(in: session)
            try await refresh()
            return count
        } catch {
            errorMessage = "Kunde inte läsa lokala Mio-kommandon: \(error.localizedDescription)"
            return 0
        }
    }

    func applyAnalysis(_ result: MioAnalysisResult, request: MioAnalysisRequest, session: MioSession) async throws -> Int {
        guard !isDeletingAll, !sessionsBeingDeleted.contains(session.id),
              MioMaintenanceState.shared.beginWrite() else { throw MioAssistantValidationError.deletedSession }
        defer { MioMaintenanceState.shared.endWrite() }
        let count = try await repository.applyAnalysis(result, request: request, session: session)
        try await refresh()
        return count
    }

    func analyzedFragmentIDs(for sessionID: UUID) -> Set<String> {
        Set(analyses.filter { $0.sessionID == sessionID }.flatMap(\.fragmentIDs))
    }

    @discardableResult
    func deferSuggestion(id: UUID) async -> Bool {
        await change { try await self.repository.deferSuggestion(id: id) }
    }

    @discardableResult
    func rejectSuggestion(id: UUID) async -> Bool {
        await change { try await self.repository.removeSuggestion(id: id) }
    }

    /// Call only after approved content was saved or the approved question received a successful answer.
    @discardableResult
    func markAccepted(id: UUID) async -> Bool {
        await change { try await self.repository.removeSuggestion(id: id) }
    }

    @discardableResult
    func saveLesson(
        id: UUID? = nil,
        session: MioSession,
        title: String,
        note: String,
        startedAt: Date,
        endedAt: Date
    ) async -> Bool {
        let existing = id.flatMap { lessonID in lessons.first { $0.id == lessonID } }
        let lesson = MioLesson(
            id: existing?.id ?? id ?? UUID(),
            sessionID: session.id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            startedAt: startedAt,
            endedAt: endedAt,
            createdAt: existing?.createdAt ?? .now,
            updatedAt: .now
        )
        return await change { try await self.repository.saveLesson(lesson, session: session) }
    }

    @discardableResult
    func deleteLesson(id: UUID) async -> Bool {
        await change { try await self.repository.deleteLesson(id: id) }
    }

    @discardableResult
    func deleteSessionData(sessionID: UUID) async -> Bool {
        sessionsBeingDeleted.insert(sessionID)
        // Keep successful deletions suppressed until restart; a delayed callback
        // cannot recreate proposals for a session that no longer exists.
        let succeeded = await change { try await self.repository.deleteSessionData(sessionID: sessionID) }
        if !succeeded { sessionsBeingDeleted.remove(sessionID) }
        return succeeded
    }

    @discardableResult
    func deleteAllData() async -> Bool {
        guard !isBusy else { return false }
        isDeletingAll = true
        defer { isDeletingAll = false }
        sessionsBeingDeleted.formUnion(suggestions.compactMap(\.sessionID))
        sessionsBeingDeleted.formUnion(lessons.map(\.sessionID))
        sessionsBeingDeleted.formUnion(processedSources.map(\.sessionID))
        return await change(ignoreMaintenance: true) { try await self.repository.deleteAll() }
    }

    func lessons(for sessionID: UUID) -> [MioLesson] {
        lessons.filter { $0.sessionID == sessionID }.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func change(
        ignoreMaintenance: Bool = false,
        _ action: @MainActor () async throws -> Void
    ) async -> Bool {
        guard !isBusy else { return false }
        if !ignoreMaintenance, !MioMaintenanceState.shared.beginWrite() { return false }
        isBusy = true
        defer {
            isBusy = false
            if !ignoreMaintenance { MioMaintenanceState.shared.endWrite() }
        }
        do {
            try await action()
            try await refresh()
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Kunde inte ändra assistentens lokala data: \(error.localizedDescription)"
            return false
        }
    }

    private func refresh() async throws {
        lastRefreshRequest += 1
        let request = lastRefreshRequest
        let document = try await repository.loadDocument()
        // A slower earlier load must not replace a later deletion in the UI.
        guard request == lastRefreshRequest else { return }
        suggestions = document.suggestions.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        lessons = document.lessons.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        processedSources = document.processedSources
        analyses = document.analyses ?? []
    }
}
