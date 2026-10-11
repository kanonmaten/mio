import Foundation
import Observation

@MainActor
@Observable
final class MioAssistantViewModel {
    private(set) var suggestions: [MioSuggestion] = []
    private(set) var lessons: [MioLesson] = []
    private(set) var analyses: [MioAnalysisRecord] = []
    private(set) var analysisDecisions: [MioAnalysisDecision] = []
    var errorMessage: String?
    private(set) var isBusy = false
    private(set) var stateRevision: UInt64 = 0

    @ObservationIgnored private let repository: any MioAssistantStore
    @ObservationIgnored private var hasBootstrapped = false
    @ObservationIgnored private var processedSources: Set<MioProcessedSource> = []
    @ObservationIgnored private var lastRefreshRequest = 0
    @ObservationIgnored private var sessionsBeingDeleted: Set<UUID> = []
    @ObservationIgnored private var isDeletingAll = false
    @ObservationIgnored private var activeOperations = 0

    init(repository: any MioAssistantStore = MioAssistantRepository()) {
        self.repository = repository
    }

    var exportDocument: MioAssistantStoreDocument {
        MioAssistantStoreDocument(suggestions: suggestions, lessons: lessons, processedSources: processedSources, analyses: analyses, analysisDecisions: analysisDecisions)
    }

    var pendingCount: Int { suggestions.filter { $0.state == .pending }.count }

    func latestDocument() async throws -> MioAssistantStoreDocument { try await repository.loadDocument() }

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
        (await changeOutcome {
            let suggestion = try MioLocalSuggestionEngine.explicitSuggestion(
                text: text, kind: kind, scheduledAt: scheduledAt, sessionID: sessionID
            )
            try await self.repository.addSuggestion(suggestion)
        }).isSuccess
    }

    @discardableResult
    func proposeQuestion(text: String, sessionID: UUID? = nil) async -> Bool {
        await change {
            let question = try MioLocalSuggestionEngine.explicitQuestion(text: text, sessionID: sessionID)
            try await self.repository.addSuggestion(question)
        }
    }

    /// Automatic local commands use admission, never the presentation busy flag.
    @discardableResult
    func detectSuggestions(in session: MioSession) async -> Int {
        await runDetection(in: session).count
    }

    func detectSuggestionsOutcome(in session: MioSession) async -> MioOperationOutcome {
        await runDetection(in: session).outcome
    }

    private func runDetection(in session: MioSession) async -> (count: Int, outcome: MioOperationOutcome) {
        guard !isDeletingAll, !sessionsBeingDeleted.contains(session.id), !Task.isCancelled else { return (0, .cancelled) }
        guard MioMaintenanceState.shared.beginWrite() else {
            return (0, .conflict("Slutför den lokala dataåtgärden innan Mio-kommandon kan sparas."))
        }
        defer { MioMaintenanceState.shared.endWrite() }
        do {
            let count = try await repository.detectSuggestions(in: session, now: .now)
            // Storage success is authoritative even if refreshing presentation fails.
            do { try await refresh() }
            catch { errorMessage = "Kommandona sparades, men listan kunde inte uppdateras. Försök läsa den igen." }
            return (count, .success)
        } catch is CancellationError { return (0, .cancelled) }
        catch {
            let message = "Kunde inte läsa lokala Mio-kommandon: \(error.localizedDescription)"
            errorMessage = message
            return (0, .failure(message))
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

    func analyzedFragmentIDs(for sessionID: UUID, detailedLesson: Bool = false) -> Set<String> {
        Set(analyses.filter { $0.sessionID == sessionID && (!detailedLesson || $0.sections != nil) }.flatMap(\.fragmentIDs))
    }

    @discardableResult
    func deferSuggestion(id: UUID) async -> Bool {
        (await deferSuggestionOutcome(id: id)).isSuccess
    }

    func deferSuggestionOutcome(id: UUID) async -> MioOperationOutcome {
        await changeOutcome { try await self.repository.deferSuggestion(id: id, now: .now) }
    }

    @discardableResult
    func rejectSuggestion(id: UUID) async -> Bool {
        (await rejectSuggestionOutcome(id: id)).isSuccess
    }

    func rejectSuggestionOutcome(id: UUID) async -> MioOperationOutcome {
        await changeOutcome { try await self.repository.removeSuggestion(id: id) }
    }

    /// Call only after approved content was saved or the approved question received a successful answer.
    @discardableResult
    func markAccepted(id: UUID) async -> Bool {
        (await markAcceptedOutcome(id: id)).isSuccess
    }

    func markAcceptedOutcome(id: UUID, reconcileExistingContent: Bool = false) async -> MioOperationOutcome {
        await changeOutcome {
            if reconcileExistingContent { try await self.repository.reconcileAcceptedContent(id: id) }
            else { try await self.repository.removeSuggestion(id: id) }
        }
    }

    func claimSuggestionApproval(id: UUID, expectedRevision: Int) async throws -> MioSuggestionApprovalClaim {
        guard !isDeletingAll, MioMaintenanceState.shared.beginWrite() else { throw CancellationError() }
        beginOperation()
        defer { endOperation(); MioMaintenanceState.shared.endWrite() }
        try Task.checkCancellation()
        let claim = try await repository.claimSuggestion(id: id, expectedRevision: expectedRevision)
        await refreshAfterCommit()
        return claim
    }

    func releaseSuggestionApproval(_ claim: MioSuggestionApprovalClaim) async -> MioOperationOutcome {
        await changeOutcome(checkCancellation: false) { try await self.repository.releaseApproval(claim) }
    }

    func completeSuggestionApproval(_ claim: MioSuggestionApprovalClaim) async -> MioOperationOutcome {
        await changeOutcome(checkCancellation: false) { try await self.repository.completeApproval(claim) }
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
        (await saveLessonOutcome(id: id, session: session, title: title, note: note,
                                 startedAt: startedAt, endedAt: endedAt)).isSuccess
    }

    func saveLessonOutcome(id: UUID? = nil, session: MioSession, title: String, note: String,
                           startedAt: Date, endedAt: Date) async -> MioOperationOutcome {
        guard !isDeletingAll, !sessionsBeingDeleted.contains(session.id) else { return .cancelled }
        return await changeOutcome {
            let document = try await self.repository.loadDocument()
            let existing = id.flatMap { lessonID in document.lessons.first { $0.id == lessonID } }
            var lesson = MioLesson(id: existing?.id ?? id ?? UUID(), sessionID: session.id,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                note: note.trimmingCharacters(in: .whitespacesAndNewlines), startedAt: startedAt, endedAt: endedAt,
                createdAt: existing?.createdAt ?? .now, updatedAt: .now)
            // Editing a title/note never proves that old source text was reviewed again.
            if let existing { lesson.sourceRevisions = existing.sourceRevisions }
            else { lesson.sourceRevisions = MioSourceRevision.capture(lesson.transcripts(in: session)) }
            try await self.repository.saveLesson(lesson, session: session)
        }
    }

    @discardableResult
    func deleteLesson(id: UUID) async -> Bool {
        await change { try await self.repository.deleteLesson(id: id) }
    }

    @discardableResult
    func deleteSessionData(sessionID: UUID) async -> Bool {
        (await deleteSessionDataOutcome(sessionID: sessionID)).isSuccess
    }

    func deleteSessionDataOutcome(sessionID: UUID, ignoreMaintenance: Bool = false) async -> MioOperationOutcome {
        sessionsBeingDeleted.insert(sessionID)
        // Keep successful deletions suppressed until restart; a delayed callback
        // cannot recreate proposals for a session that no longer exists.
        let outcome = await changeOutcome(ignoreMaintenance: ignoreMaintenance) { try await self.repository.deleteSessionData(sessionID: sessionID) }
        if !outcome.isSuccess { sessionsBeingDeleted.remove(sessionID) }
        return outcome
    }

    @discardableResult
    func deleteAllData() async -> Bool {
        (await deleteAllDataOutcome(ignoreMaintenance: true)).isSuccess
    }

    func deleteAllDataOutcome(ignoreMaintenance: Bool = false) async -> MioOperationOutcome {
        isDeletingAll = true
        defer { isDeletingAll = false }
        sessionsBeingDeleted.formUnion(suggestions.compactMap(\.sessionID))
        sessionsBeingDeleted.formUnion(lessons.map(\.sessionID))
        sessionsBeingDeleted.formUnion(processedSources.map(\.sessionID))
        return await changeOutcome(ignoreMaintenance: ignoreMaintenance) { try await self.repository.deleteAll(now: .now) }
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
        (await changeOutcome(ignoreMaintenance: ignoreMaintenance, action)).isSuccess
    }

    private func changeOutcome(ignoreMaintenance: Bool = false,
                               checkCancellation: Bool = true,
                               _ action: @MainActor () async throws -> Void) async -> MioOperationOutcome {
        if !ignoreMaintenance, !MioMaintenanceState.shared.beginWrite() {
            return .conflict("Lokal radering pågår. Försök igen när den är klar.")
        }
        beginOperation()
        defer {
            endOperation()
            if !ignoreMaintenance { MioMaintenanceState.shared.endWrite() }
        }
        do {
            if checkCancellation { try Task.checkCancellation() }
            try await action()
            await refreshAfterCommit()
            return .success
        } catch is CancellationError {
            return .cancelled
        } catch let error as MioAssistantRepositoryError {
            errorMessage = error.localizedDescription
            switch error {
            case .suggestionChanged, .approvalInProgress, .invalidApproval: return .conflict(error.localizedDescription)
            default: return .failure(error.localizedDescription)
            }
        } catch {
            errorMessage = "Kunde inte ändra assistentens lokala data: \(error.localizedDescription)"
            return .failure(errorMessage!)
        }
    }

    private func beginOperation() { activeOperations += 1; isBusy = true }
    private func endOperation() { activeOperations -= 1; isBusy = activeOperations > 0 }

    private func refreshAfterCommit() async {
        do {
            try await refresh()
            errorMessage = nil
        } catch {
            // The actor already committed. Presentation I/O must not undo the
            // outcome or lose an approval token needed for cleanup/reconciliation.
            errorMessage = "Ändringen är sparad, men vyn kunde inte uppdateras: \(error.localizedDescription)"
        }
    }

    private func refresh() async throws {
        lastRefreshRequest += 1
        let request = lastRefreshRequest
        let document = try await repository.loadDocument()
        // A slower earlier load must not replace a later deletion in the UI.
        guard request == lastRefreshRequest else { return }
        let newSuggestions = document.suggestions.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let newLessons = document.lessons.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let changed = suggestions != newSuggestions || lessons != newLessons
            || processedSources != document.processedSources || analyses != (document.analyses ?? [])
            || analysisDecisions != (document.analysisDecisions ?? [])
        suggestions = newSuggestions
        lessons = newLessons
        processedSources = document.processedSources
        analyses = document.analyses ?? []
        analysisDecisions = document.analysisDecisions ?? []
        if changed { stateRevision += 1 }
    }
}
