import Foundation
import Observation

/// Owns cross-component commands. Presentation busy state never discards automatic work.
@MainActor @Observable
final class MioWorkflowCoordinator {
    let capture: MioViewModel
    let content: MioContentViewModel
    let assistant: MioAssistantViewModel
    let analysis: MioAnalysisCoordinator
    let questions: MioQuestionWorkflow
    let deletion: MioDeletionRecovery
    private(set) var lastOutcome: MioOperationOutcome?
    private(set) var pendingLessonIDs: Set<UUID> = []
    private(set) var queuedCommands = 0
    @ObservationIgnored private let maintenance: MioMaintenanceState
    /// ID-only list of lessons awaiting finalization, so a failed save, a recovery
    /// block or an app restart cannot silently drop them.
    @ObservationIgnored private let pendingLessonDefaults: UserDefaults
    static let pendingLessonsKey = "mio.workflow.pendingLessonFinalization"
    @ObservationIgnored private var commandTail: Task<Void, Never>?
    @ObservationIgnored private var tailID: UUID?
    @ObservationIgnored private var commands: [UUID: Task<MioOperationOutcome, Never>] = [:]
    @ObservationIgnored private var deletionCommands: Set<UUID> = []
    @ObservationIgnored private var automatic: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var endingEverydaySessionID: UUID?
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var loadedPresentation = false
    private struct ExportRevision: Equatable {
        let capture: UInt64; let content: UInt64; let assistant: UInt64
    }
    @ObservationIgnored private var exportedRevision: ExportRevision?
    private var sourceRevision: ExportRevision {
        .init(capture: capture.stateRevision, content: content.stateRevision, assistant: assistant.stateRevision)
    }

    func invalidateExportIfSourcesChanged() {
        if exportedRevision != sourceRevision { content.exportURL = nil }
    }

    init(capture: MioViewModel, content: MioContentViewModel,
         assistant: MioAssistantViewModel, analysis: MioAnalysisCoordinator,
         journal: MioDeletionJournal = MioDeletionJournal(), diagnostics: MioDiagnosticsRepository = .shared,
         systemActions: MioSystemActionPort? = nil, questions: MioQuestionWorkflow? = nil,
         clearCredentials: (@MainActor () throws -> Void)? = nil,
         pendingLessonDefaults: UserDefaults = .standard, metrics: MioMetricArchive = .shared) {
        self.pendingLessonDefaults = pendingLessonDefaults
        let systemActions = systemActions ?? .native
        let maintenance = MioMaintenanceState.shared
        let questions = questions ?? MioQuestionWorkflow(canSend: { !maintenance.blocksWork })
        let clearCredentials = clearCredentials ?? Self.clearNativeCredentials
        self.capture = capture; self.content = content
        self.assistant = assistant; self.analysis = analysis; self.questions = questions; self.maintenance = maintenance
        deletion = MioDeletionRecovery(journal: journal, cancelWork: { operation in
            // A reviewed question contains copied excerpts without durable source IDs.
            // Any deletion invalidates that preview and any late answer conservatively.
            questions.invalidate()
            switch operation.scope {
            case .all:
                analysis.disable()
                await diagnostics.invalidateForDeletion()
                await capture.cancelForDeletion()
            case .session:
                if let id = operation.targetID { analysis.cancel(sessionID: id, assistant: assistant) }
            case .content: break
            }
        }, performStep: { step, operation in
            switch step {
            case .systemActions:
                if operation.scope == .all { return await systemActions.removeAll() }
                guard let id = operation.targetID else { return .failure("Raderingsmålet saknas.") }
                return await systemActions.cancel(id)
            case .credentials:
                do { try clearCredentials(); return .success }
                catch { return .failure("Kunde inte radera serveranslutningarna. Kontrollera lagringen och försök igen.") }
            case .sessions:
                if operation.scope == .all { return await capture.deleteAllDataOutcome() }
                guard let id = operation.targetID else { return .failure("Sessionens identifierare saknas.") }
                let deleted = await capture.deleteSessionOutcome(id: id, ignoreMaintenance: true)
                guard deleted.isSuccess else { return deleted }
                // Never report the deletion complete while an app-owned export may still hold it.
                return await content.removeExportsOutcome()
            case .content:
                if operation.scope == .all { return await content.deleteAllDataOutcome() }
                guard let id = operation.targetID else { return .failure("Postens identifierare saknas.") }
                return await content.deleteOutcome(id: id, ignoreMaintenance: true, cancelSystem: false)
            case .contentLinks:
                guard let id = operation.targetID else { return .failure("Sessionens identifierare saknas.") }
                return await content.unlinkSessionOutcome(id: id, ignoreMaintenance: true)
            case .assistant:
                if operation.scope == .all { return await assistant.deleteAllDataOutcome(ignoreMaintenance: true) }
                guard let id = operation.targetID else { return .failure("Sessionens identifierare saknas.") }
                return await assistant.deleteSessionDataOutcome(sessionID: id, ignoreMaintenance: true)
            case .diagnostics:
                do { try await diagnostics.deleteAll(); try await metrics.deleteAll(); return .success }
                catch { return .failure("Kunde inte radera diagnostikjournalen. Försök igen.") }
            }
        })
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        installCaptureRouting()
        let recovered = await resumeDeletion()
        guard recovered.isSuccess else { return }
        await loadPresentationIfNeeded()
        resumePendingLessons()
    }

    func finalizeLesson(_ session: MioSession, fromCapture: Bool = false) async -> MioOperationOutcome {
        await enqueue { [self] in
            if fromCapture, capture.session(id: session.id) == nil { return .cancelled }
            guard let end = session.endedAt, session.isLesson else { return .failure("Lektionen måste vara avslutad innan den kan registreras.") }
            markLessonPending(session.id)
            do {
                // The final checkpoint may have failed when capture stopped; never register
                // a lesson whose ended session exists only in memory.
                if capture.session(id: session.id) != nil {
                    let persisted = await capture.persistEndedSession(id: session.id)
                    guard persisted.isSuccess else { return persisted }
                }
                let latest = try await assistant.latestDocument()
                if !latest.lessons.contains(where: { $0.id == session.id && $0.sessionID == session.id }) {
                    let saved = await assistant.saveLessonOutcome(id: session.id, session: session,
                        title: session.title ?? "Lektion", note: "", startedAt: session.startedAt, endedAt: end)
                    guard saved.isSuccess else { return saved }
                }
                try Task.checkCancellation()
                clearLessonPending(session.id)
                analysis.summarizeLesson(session, assistant: assistant)
                return .success
            } catch is CancellationError { return .cancelled }
            catch { return .failure("Kunde inte registrera lektionen: \(error.localizedDescription)") }
        }
    }

    func retryLessonFinalization() async -> MioOperationOutcome {
        for id in pendingLessonIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let session = capture.session(id: id) else { clearLessonPending(id); continue }
            let result = await finalizeLesson(session)
            guard result.isSuccess else { return result }
        }
        return .success
    }

    func acceptSuggestion(id: UUID, expectedRevision: Int, kind: MioContentKind, title: String,
                          body: String, scheduledAt: Date, dateConfirmed: Bool, dateChosen: Bool) async -> MioOperationOutcome {
        await enqueue { [self] in
            var claim: MioSuggestionApprovalClaim?
            do {
                try Task.checkCancellation()
                // A previous content commit is authoritative and later user edits are preserved.
                if try await content.latestItems().contains(where: { $0.id == id }) {
                    return await assistant.markAcceptedOutcome(id: id, reconcileExistingContent: true)
                }
                let document = try await assistant.latestDocument()
                guard let suggestion = document.suggestions.first(where: { $0.id == id }), suggestion.purpose == .content else {
                    return .conflict("Förslaget finns inte längre. Gå tillbaka till inkorgen.")
                }
                let dated = kind == .plan || kind == .task
                guard !dated || suggestion.evidence == nil || (dateConfirmed && (suggestion.needsDateConfirmation != true || dateChosen)) else {
                    return .failure("Välj och kontrollera datum och tid innan du godkänner.")
                }
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanTitle.isEmpty else { return .failure("Skriv en rubrik innan du sparar.") }
                claim = try await assistant.claimSuggestionApproval(id: id, expectedRevision: expectedRevision)
                try Task.checkCancellation()
                let item = MioContentItem(id: id, kind: kind, title: cleanTitle, body: body,
                    createdAt: suggestion.createdAt, updatedAt: .now, scheduledAt: scheduledAt,
                    sessionID: suggestion.sessionID.flatMap { capture.session(id: $0)?.id })
                let saved = await content.saveApproved(item)
                guard saved.isSuccess else {
                    // A privacy-attribute failure may follow an atomic content commit.
                    // Keep the decision closed when that ID exists; never reopen it.
                    if try await content.latestItems().contains(where: { $0.id == id }) {
                        if let claim { _ = await assistant.completeSuggestionApproval(claim) }
                    } else if let claim { _ = await assistant.releaseSuggestionApproval(claim) }
                    return saved
                }
                // Complete a committed approval even if cancellation arrives after storage.
                // The user can retry dismissal; the stable content ID prevents replacement.
                return await assistant.completeSuggestionApproval(claim!)
            } catch is CancellationError {
                if let claim { _ = await assistant.releaseSuggestionApproval(claim) }
                return .cancelled
            } catch let error as MioAssistantRepositoryError {
                switch error {
                case .suggestionChanged, .approvalInProgress, .invalidApproval: return .conflict(error.localizedDescription)
                case .unsupportedSchemaVersion, .invalidRelationships: return .failure(error.localizedDescription)
                }
            } catch { return .failure("Kunde inte godkänna förslaget: \(error.localizedDescription)") }
        }
    }

    func rejectSuggestion(id: UUID) async -> MioOperationOutcome {
        await enqueue { [assistant] in await assistant.rejectSuggestionOutcome(id: id) }
    }

    func deferSuggestion(id: UUID) async -> MioOperationOutcome {
        await enqueue { [assistant] in await assistant.deferSuggestionOutcome(id: id) }
    }

    func finishQuestion(id: UUID) async -> MioOperationOutcome {
        await enqueue { [assistant] in await assistant.markAcceptedOutcome(id: id) }
    }

    func prepareExport() async -> MioOperationOutcome {
        await enqueue { [self] in
            guard [.off, .failed, .unavailable].contains(capture.runState) else {
                return .conflict("Avsluta sessionen innan du exporterar data.")
            }
            guard await maintenance.beginExclusive(deleting: false) else { return .conflict("En dataåtgärd pågår redan.") }
            defer { maintenance.endExclusive() }
            do {
                try Task.checkCancellation()
                let checkpoint = await capture.checkpointForSnapshot()
                guard checkpoint.isSuccess else { return checkpoint }
                let items = try await content.latestItems()
                let sessions = try await capture.latestSessions()
                let assistantDocument = try await assistant.latestDocument()
                try Task.checkCancellation()
                let result = await content.prepareExportSnapshot(content: items, sessions: sessions, assistant: assistantDocument)
                if result.isSuccess { exportedRevision = sourceRevision }
                return result
            } catch is CancellationError { return .cancelled }
            catch { return .failure("Kunde inte läsa en sammanhängande export: \(error.localizedDescription)") }
        }
    }

    func deleteAll() async -> MioOperationOutcome { await delete(scope: .all, targetID: nil) }
    func deleteSession(id: UUID) async -> MioOperationOutcome { await delete(scope: .session, targetID: id) }
    func deleteContent(id: UUID) async -> MioOperationOutcome { await delete(scope: .content, targetID: id) }

    func resumeDeletion() async -> MioOperationOutcome {
        await enqueue(isDeletion: true) { [self] in
            guard await maintenance.beginExclusive(deleting: true) else { return .conflict("En dataåtgärd pågår redan.") }
            defer { maintenance.endExclusive() }
            let result = await deletion.resumePending()
            maintenance.setRecoveryBlocked(!result.isSuccess)
            if result.isSuccess { await loadPresentationIfNeeded(); resumePendingLessons() }
            return result
        }
    }

    private func markLessonPending(_ id: UUID) { pendingLessonIDs.insert(id); storePendingLessons() }
    private func clearLessonPending(_ id: UUID) { pendingLessonIDs.remove(id); storePendingLessons() }
    private func storePendingLessons() {
        pendingLessonDefaults.set(pendingLessonIDs.map(\.uuidString).sorted(), forKey: Self.pendingLessonsKey)
    }

    /// Restores persisted IDs, drops those whose session no longer exists, and retries
    /// the rest automatically. Only local registration runs; model work stays consented.
    private func resumePendingLessons() {
        let stored = (pendingLessonDefaults.stringArray(forKey: Self.pendingLessonsKey) ?? []).compactMap(UUID.init(uuidString:))
        pendingLessonIDs.formUnion(stored)
        pendingLessonIDs = pendingLessonIDs.filter { capture.session(id: $0) != nil }
        storePendingLessons()
        guard !pendingLessonIDs.isEmpty, !maintenance.recoveryBlocked else { return }
        automatically { [weak self] in _ = await self?.retryLessonFinalization() }
    }

    private func loadPresentationIfNeeded() async {
        guard !loadedPresentation else { return }
        loadedPresentation = true
        await content.bootstrap(); await assistant.bootstrap(); await capture.bootstrap()
    }

    /// Explicit local approval; one stable draft ID preserves later user edits on retries.
    func saveAnswerNote(_ draft: MioAnswerNoteDraft, title: String, body: String) async -> MioOperationOutcome {
        await enqueue { [self] in
            guard questions.generation == draft.generation, questions.answerDraft?.id == draft.id else { return .cancelled }
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty, !cleanBody.isEmpty else { return .failure("Skriv en rubrik och kontrollera svaret innan du sparar.") }
            guard cleanTitle.utf8.count <= 2_000, cleanBody.utf8.count <= 24_000 else { return .failure("Anteckningen är för stor. Korta texten innan du sparar.") }
            let item = MioContentItem(id: draft.id, kind: .note, title: cleanTitle, body: cleanBody)
            return await content.saveApproved(item)
        }
    }

    func cloudConfigurationChanged() { MioConnectionDiscovery.shared.invalidate(); questions.invalidate(); analysis.disable() }

    private func delete(scope: MioDeletionScope, targetID: UUID?) async -> MioOperationOutcome {
        guard !maintenance.recoveryBlocked else { return .conflict("Slutför den väntande raderingen med Försök igen innan du gör andra ändringar.") }
        if scope == .all, ![.off, .failed, .unavailable].contains(capture.runState) {
            return .conflict("Avsluta sessionen innan du raderar all data.")
        }
        if scope == .session, let id = targetID, capture.session(id: id)?.endedAt == nil, capture.session(id: id) != nil {
            return .conflict("Stoppa sessionen innan du raderar den.")
        }
        invalidateCommands()
        return await enqueue(isDeletion: true) { [self] in
            guard !maintenance.recoveryBlocked else { return .conflict("Slutför den väntande raderingen med Försök igen innan du gör andra ändringar.") }
            guard await maintenance.beginExclusive(deleting: true) else { return .conflict("En dataåtgärd pågår redan.") }
            defer { maintenance.endExclusive() }
            let outcome = await deletion.begin(scope: scope, targetID: targetID)
            maintenance.setRecoveryBlocked(!outcome.isSuccess)
            if outcome.isSuccess {
                if scope == .all { pendingLessonIDs = []; storePendingLessons() }
                else if scope == .session, let targetID { clearLessonPending(targetID) }
                // Invalidation cancelled queued automatic work; surviving lessons are retried.
                resumePendingLessons()
            }
            return outcome
        }
    }

    private func enqueue(isDeletion: Bool = false, _ operation: @escaping @MainActor () async -> MioOperationOutcome) async -> MioOperationOutcome {
        let id = UUID(); let token = generation; let previous = commandTail
        queuedCommands += 1
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, isDeletion || self.generation == token, !Task.isCancelled else { return MioOperationOutcome.cancelled }
            let result = await operation()
            if isDeletion || self.generation == token { self.lastOutcome = result }
            return result
        }
        commands[id] = task
        if isDeletion { deletionCommands.insert(id) }
        tailID = id
        commandTail = Task { _ = await task.value }
        defer {
            commands[id] = nil; deletionCommands.remove(id); queuedCommands = max(0, queuedCommands - 1)
            if tailID == id { commandTail = nil; tailID = nil }
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func invalidateCommands() {
        generation = UUID()
        // A new deletion cancels ordinary work but must not abandon another durable intent.
        for (id, task) in commands where !deletionCommands.contains(id) { task.cancel() }
        automatic.values.forEach { $0.cancel() }
        automatic = [:]
        endingEverydaySessionID = nil
    }

    private func automatically(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        automatic[id] = Task { @MainActor [weak self] in
            await operation()
            self?.automatic[id] = nil
        }
    }

    private func installCaptureRouting() {
        capture.onFinalizedTranscript = { [weak self] session in
            guard let self, !maintenance.recoveryBlocked else { return }
            if !session.isLesson, capture.currentSession?.id == session.id || endingEverydaySessionID == session.id,
               capture.runState == .listening || capture.runState == .stopping || endingEverydaySessionID == session.id {
                analysis.observe(session, assistant: assistant)
            }
            automatically { [weak self] in
                guard let self else { return }
                _ = await enqueue { [self] in
                    guard self.capture.session(id: session.id) != nil, !self.maintenance.recoveryBlocked else { return .cancelled }
                    return await self.assistant.detectSuggestionsOutcome(in: session)
                }
            }
        }
        capture.onLessonFinished = { [weak self] session in
            guard let self else { return }
            markLessonPending(session.id)
            // Blocked recovery defers the work; resumePendingLessons runs it afterwards.
            guard !maintenance.recoveryBlocked else { return }
            automatically { [weak self] in _ = await self?.finalizeLesson(session, fromCapture: true) }
        }
        capture.onCaptureStateChanged = { [weak self] state in self?.captureStateChanged(state) }
    }

    private func captureStateChanged(_ state: MioRunState) {
        guard !maintenance.recoveryBlocked else { return }
        if state == .stopping, let session = capture.currentSession, !session.isLesson {
            endingEverydaySessionID = session.id
            analysis.beginEndingEveryday(sessionID: session.id)
        } else if state == .off || state == .paused {
            let final = endingEverydaySessionID.flatMap { capture.session(id: $0) }
                ?? capture.currentSession.flatMap { $0.isLesson ? nil : $0 }
            if let final { analysis.finishEveryday(final, assistant: assistant) }
            else { analysis.pauseEveryday(assistant: assistant) }
            endingEverydaySessionID = nil
        } else if state == .interrupted || state == .failed || state == .unavailable {
            endingEverydaySessionID = nil
            analysis.pauseEveryday(assistant: assistant)
        }
    }

    private static func clearNativeCredentials() throws {
        #if canImport(Security)
        try MioCloudSettings.reset(); try TranscriptionSettings.reset()
        #else
        throw MioCloudError.disabled
        #endif
    }
}
