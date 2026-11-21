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
    let reminders: MioReminderPort
    @ObservationIgnored private let systemActions: MioSystemActionPort
    /// Only the app itself opts in; tests construct workflows without touching real data.
    @ObservationIgnored private let removesLegacyItems: Bool
    /// False on the temporary in-memory store; see `MioDeletionRecovery`.
    @ObservationIgnored private let storesAreDurable: @MainActor () async -> Bool
    /// Set once the 0.9.1 upgrade removed the items and alarms from before Apple's apps took over.
    static let legacyCleanupKey = "mio.upgrade.0.9.1.legacyItemsRemoved"
    private(set) var lastOutcome: MioOperationOutcome?
    private(set) var pendingLessonIDs: Set<UUID> = []
    private(set) var queuedCommands = 0
    @ObservationIgnored private let maintenance: MioMaintenanceState
    /// ID-only list of lessons awaiting finalization, so a failed save, a recovery
    /// block or an app restart cannot silently drop them.
    @ObservationIgnored private let pendingLessonDefaults: UserDefaults
    static let pendingLessonsKey = "mio.workflow.pendingLessonFinalization"
    /// ID-only list of lessons whose detailed notes were requested but may be unfinished,
    /// so notes interrupted by suspension or iOS ending the task resume after a relaunch.
    static let lessonNotesKey = "mio.workflow.lessonNotesInProgress"
    /// Called after the user's own action queued lesson notes (iOS continued processing).
    @ObservationIgnored var onLessonNotesStarted: ((UUID) -> Void)?
    /// Called once when a lesson's notes are done; in the foreground the app opens the review
    /// sheet or, when she is busy, offers it in a row (`MioNavigationCoordinator.lessonNotesReady`),
    /// otherwise it posts "Anteckningarna från lektionen är klara" (notification route `lessonReview`).
    @ObservationIgnored var onLessonNotesReady: (@MainActor (UUID) -> Void)?
    /// The last measured time from lesson end to finished notes, for tests and diagnostics.
    private(set) var lastLessonNotesLatency: MioLessonNotesLatencyLog.Entry?
    @ObservationIgnored private var analysisWasEnabled = false
    @ObservationIgnored private var commandTail: Task<Void, Never>?
    @ObservationIgnored private var tailID: UUID?
    @ObservationIgnored private var commands: [UUID: Task<MioOperationOutcome, Never>] = [:]
    @ObservationIgnored private var deletionCommands: Set<UUID> = []
    @ObservationIgnored private var automatic: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var endingEverydaySessionID: UUID?
    /// The one launch bootstrap; later callers (the nightly backup) wait for the same run.
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapFinished = false
    /// Where a chosen backup copy waits for the restart (fas 6). Nil in tests that do not opt in.
    @ObservationIgnored private let restoreFiles: MioLegacyStoreFiles?
    /// Whether a chosen copy waits for the restart. While it does, no capture or lesson starts:
    /// anything recorded would be replaced at the next launch.
    private(set) var restorePending = false
    /// One sentence when a pending restore was removed without her asking (a deletion, or the
    /// 24-hour limit). Cleared by `dismissRestoreNotice()`.
    private(set) var restoreNotice: String?
    /// Called after "Radera all data" succeeded, for state outside the portable core (the
    /// scheduled backup request and its in-memory attempt).
    @ObservationIgnored var onAllDataDeleted: (@MainActor () -> Void)?
    static let restorePendingCaptureMessage = "En återställning väntar – starta om Mio eller avbryt den."
    @ObservationIgnored private var isPruning = false
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
         reminders: MioReminderPort? = nil, removesLegacyItems: Bool = false,
         clearCredentials: (@MainActor () throws -> Void)? = nil,
         pendingLessonDefaults: UserDefaults = .standard, metrics: MioMetricArchive = .shared,
         restoreFiles: MioLegacyStoreFiles? = nil,
         storesAreDurable: @escaping @MainActor () async -> Bool = { true }) {
        self.storesAreDurable = storesAreDurable
        self.restoreFiles = restoreFiles
        self.pendingLessonDefaults = pendingLessonDefaults
        self.reminders = reminders ?? .native
        let systemActions = systemActions ?? .native
        self.systemActions = systemActions
        self.removesLegacyItems = removesLegacyItems
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
        }, storesAreDurable: storesAreDurable)
        restorePending = restoreFiles.map(MioBackupRestore.hasPending) ?? false
        capture.captureBlocker = { [weak self] in
            self?.restorePending == true ? Self.restorePendingCaptureMessage : nil
        }
    }

    /// Runs once per launch: deletion recovery first, then the stored data. A second caller, such
    /// as the nightly backup started by iOS before any view exists, waits for the same run.
    func bootstrap() async {
        if let bootstrapTask { await bootstrapTask.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            installCaptureRouting()
            let recovered = await resumeDeletion()
            if recovered.isSuccess {
                await loadPresentationIfNeeded()
                if removesLegacyItems { await removeLegacyItemsOnce() }
                resumePendingLessons()
                observeAnalysisAvailability()
            }
            // The launch has applied or refused any copy by now (the stores are resolved).
            refreshRestorePending()
            bootstrapFinished = true
        }
        bootstrapTask = task
        await task.value
    }

    /// Whether background work may read or plan from stored data: the launch bootstrap has run,
    /// no deletion is blocked or unfinished, and the data is loaded from durable stores.
    func readyForBackgroundWork() async -> Bool {
        await bootstrap()
        guard bootstrapFinished, loadedPresentation, !maintenance.recoveryBlocked,
              deletion.pendingOperationID == nil else { return false }
        return await storesAreDurable()
    }

    /// Re-reads the pending restore. A copy older than 24 hours is removed with a notice.
    func refreshRestorePending(now: Date = .now) {
        guard let restoreFiles else { restorePending = false; return }
        if MioBackupRestore.hasPending(in: restoreFiles),
           let metadata = MioBackupRestore.readMetadata(in: restoreFiles),
           let refused = MioBackupRestore.refusal(for: metadata,
               deletionGeneration: MioBackupRestore.deletionGeneration(in: pendingLessonDefaults), now: now) {
            if (try? MioBackupRestore.cancel(in: restoreFiles)) != nil { restoreNotice = refused }
        }
        restorePending = MioBackupRestore.hasPending(in: restoreFiles)
    }

    /// "Avbryt återställningen", from settings or from the notice on Fånga and lesson start.
    @discardableResult
    func cancelPendingRestore() -> Bool {
        guard let restoreFiles else { return true }
        let removed = (try? MioBackupRestore.cancel(in: restoreFiles)) != nil
        restorePending = MioBackupRestore.hasPending(in: restoreFiles)
        return removed
    }

    func dismissRestoreNotice() { restoreNotice = nil }

    /// Removes a pending restore when a deletion begins and bumps the deletion generation, so a
    /// copy chosen before the deletion can never bring the deleted data back at the next launch
    /// (review of fas 6). Returns false only when the copy is still on disk.
    private func abandonPendingRestoreForDeletion() -> Bool {
        MioBackupRestore.noteDeletion(in: pendingLessonDefaults)
        guard let restoreFiles, MioBackupRestore.hasPending(in: restoreFiles) else { return true }
        let removed = (try? MioBackupRestore.cancel(in: restoreFiles)) != nil
        restorePending = MioBackupRestore.hasPending(in: restoreFiles)
        if removed {
            restoreNotice = "Återställningen avbröts, eftersom du raderade data efter att du valde kopian."
        }
        return removed
    }

    /// 0.9.1 (user decision 2026-10-13): local notes, tasks, plans and memories from before the
    /// handoff to Apple's apps are deleted once, then Mio's alarms and post reminders. Handoff
    /// records are kept. A failure leaves the marker unset, so the next launch tries again.
    func removeLegacyItemsOnce() async {
        guard !pendingLessonDefaults.bool(forKey: Self.legacyCleanupKey), await storesAreDurable() else { return }
        guard let items = try? await content.latestItems() else { return }
        // Mio notes from a direct instruction (2026-11-20) are kept.
        for item in items where item.handoff == nil && item.direct == nil {
            guard await content.deleteOutcome(id: item.id, cancelSystem: false).isSuccess else { return }
        }
        guard await systemActions.removeLegacy().isSuccess else { return }
        pendingLessonDefaults.set(true, forKey: Self.legacyCleanupKey)
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
                requestLessonNotes(session, userInitiated: fromCapture)
                return .success
            } catch is CancellationError { return .cancelled }
            catch { return .failure("Kunde inte registrera lektionen. \(MioErrorText.action(for: error))") }
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
                          body: String, scheduledAt: Date, dateConfirmed: Bool, dateChosen: Bool,
                          isAllDay: Bool = false) async -> MioOperationOutcome {
        await enqueue { [self] in
            await performAccept(id: id, expectedRevision: expectedRevision, kind: kind, title: title, body: body,
                                scheduledAt: scheduledAt, dateConfirmed: dateConfirmed, dateChosen: dateChosen, isAllDay: isAllDay)
        }
    }

    /// The body of `acceptSuggestion`, for callers already inside the command queue.
    private func performAccept(id: UUID, expectedRevision: Int, kind: MioContentKind, title: String,
                               body: String, scheduledAt: Date, dateConfirmed: Bool, dateChosen: Bool,
                               isAllDay: Bool, direct: MioDirectRecord? = nil) async -> MioOperationOutcome {
        do {
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
                let allDay = isAllDay && dated
                let item = MioContentItem(id: id, kind: kind, title: cleanTitle, body: body,
                    createdAt: suggestion.createdAt, updatedAt: .now,
                    scheduledAt: allDay ? Calendar.current.startOfDay(for: scheduledAt) : scheduledAt,
                    sessionID: suggestion.sessionID.flatMap { capture.session(id: $0)?.id }, isAllDay: allDay,
                    direct: direct)
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
                // Release like approveHandoff does, or the proposal stays claimed (ultrareview B3).
                if let claim { _ = await assistant.releaseSuggestionApproval(claim) }
                switch error {
                case .suggestionChanged, .approvalInProgress, .invalidApproval: return .conflict(error.localizedDescription)
                case .unsupportedSchemaVersion, .invalidRelationships: return .failure(error.localizedDescription)
                }
            } catch {
                if let claim { _ = await assistant.releaseSuggestionApproval(claim) }
                return .failure("Kunde inte godkänna förslaget. \(MioErrorText.action(for: error))")
            }
        }
    }

    /// Creates the approved reminder in Reminders, then records the handoff and closes the
    /// proposal. The reminder carries the proposal's link, so a retry after a failed local write
    /// finds it instead of creating a second one. Denied access leaves the proposal untouched.
    func sendToReminders(id: UUID, expectedRevision: Int, title: String, notes: String,
                         dueDate: Date?, hasTime: Bool, listID: String?, examSubject: String? = nil) async -> MioOperationOutcome {
        await approveHandoff(id: id, expectedRevision: expectedRevision, title: title, kind: .task,
                             examDate: dueDate.map { (date: $0, allDay: !hasTime) }, examSubject: examSubject) { [reminders] suggestion, cleanTitle in
            if reminders.access() == .notDetermined { _ = await reminders.requestAccess() }
            guard reminders.access() == .granted else { throw MioReminderError.accessDenied }
            let due = dueDate.map { hasTime ? $0 : Calendar.current.startOfDay(for: $0) }
            let draft = MioReminderDraft(title: cleanTitle, notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                url: suggestion.sessionID.flatMap { MioLink.session($0, proposal: id) } ?? MioLink.proposal(id),
                dueDate: due, hasTime: due != nil && hasTime, listID: listID)
            let identifier = try await reminders.save(draft)
            if let listID { UserDefaults.standard.set(listID, forKey: MioReminderPort.lastListKey) }
            return MioHandoff(destination: .reminders, externalIdentifier: identifier, sentAt: .now)
        }
    }

    /// Records a handoff the user already completed in Apple's own UI (the Calendar editor or
    /// the share sheet). That action is authoritative, so a newer AI revision does not block it.
    /// `examDate` is the day she approved before Calendar's editor opened; it is kept only when the
    /// title reads as an exam (fas 5), since Mio never reads the event back.
    func recordHandoff(id: UUID, kind: MioContentKind, title: String, destination: MioHandoffDestination,
                       externalIdentifier: String? = nil, examDate: (date: Date, allDay: Bool)? = nil,
                       examSubject: String? = nil) async -> MioOperationOutcome {
        await approveHandoff(id: id, expectedRevision: nil, title: title, kind: kind,
                             examDate: examDate, examSubject: examSubject) { _, _ in
            MioHandoff(destination: destination, externalIdentifier: externalIdentifier, sentAt: .now)
        }
    }

    private func approveHandoff(id: UUID, expectedRevision: Int?, title: String, kind: MioContentKind,
                                examDate: (date: Date, allDay: Bool)? = nil, examSubject: String? = nil,
                                perform: @escaping @MainActor (MioSuggestion, String) async throws -> MioHandoff) async -> MioOperationOutcome {
        await enqueue { [self] in
            await performHandoff(id: id, expectedRevision: expectedRevision, title: title, kind: kind,
                                 examDate: examDate, examSubject: examSubject, perform: perform)
        }
    }

    /// The body of `approveHandoff`, for callers already inside the command queue.
    private func performHandoff(id: UUID, expectedRevision: Int?, title: String, kind: MioContentKind,
                                direct: MioDirectRecord? = nil, examDate: (date: Date, allDay: Bool)? = nil,
                                examSubject: String? = nil,
                                perform: @MainActor (MioSuggestion, String) async throws -> MioHandoff) async -> MioOperationOutcome {
        do {
            var claim: MioSuggestionApprovalClaim?
            do {
                try Task.checkCancellation()
                if try await content.latestItems().contains(where: { $0.id == id }) {
                    return await assistant.markAcceptedOutcome(id: id, reconcileExistingContent: true)
                }
                let document = try await assistant.latestDocument()
                guard let suggestion = document.suggestions.first(where: { $0.id == id }), suggestion.purpose == .content else {
                    return .conflict("Förslaget finns inte längre. Gå tillbaka till inkorgen.")
                }
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanTitle.isEmpty else { return .failure("Skriv en rubrik innan du skickar.") }
                claim = try await assistant.claimSuggestionApproval(id: id, expectedRevision: expectedRevision ?? suggestion.reviewRevision)
                let handoff = try await perform(suggestion, cleanTitle)
                // The record keeps no text and no date: Apple's app owns both from now on. The one
                // exception is an exam's approved day and subject (fas 5), for Hem's countdown.
                let session = suggestion.sessionID.flatMap { capture.session(id: $0) }
                let exam = MioExamRecord.make(kind: kind, title: cleanTitle, date: examDate?.date,
                                              isAllDay: examDate?.allDay ?? false,
                                              subject: examSubject ?? (session?.isLesson == true ? session?.subject : nil),
                                              knownSubjects: MioExamSubjects.known(in: capture.allSessions))
                let item = MioContentItem(id: id, kind: kind, title: cleanTitle, createdAt: suggestion.createdAt,
                    updatedAt: handoff.sentAt, scheduledAt: handoff.sentAt,
                    sessionID: session?.id, handoff: handoff,
                    direct: direct.map { MioDirectRecord(destination: $0.destination, savedAt: handoff.sentAt) },
                    exam: exam)
                let saved = await content.saveApproved(item)
                guard saved.isSuccess else {
                    if try await content.latestItems().contains(where: { $0.id == id }) {
                        if let claim { _ = await assistant.completeSuggestionApproval(claim) }
                    } else if let claim { _ = await assistant.releaseSuggestionApproval(claim) }
                    return saved
                }
                return await assistant.completeSuggestionApproval(claim!)
            } catch is CancellationError {
                if let claim { _ = await assistant.releaseSuggestionApproval(claim) }
                return .cancelled
            } catch let error as MioAssistantRepositoryError {
                if let claim { _ = await assistant.releaseSuggestionApproval(claim) }
                switch error {
                case .suggestionChanged, .approvalInProgress, .invalidApproval: return .conflict(error.localizedDescription)
                case .unsupportedSchemaVersion, .invalidRelationships: return .failure(error.localizedDescription)
                }
            } catch {
                if let claim { _ = await assistant.releaseSuggestionApproval(claim) }
                return .failure(MioErrorText.sentence(for: error))
            }
        }
    }

    func rejectSuggestion(id: UUID) async -> MioOperationOutcome {
        let fromDirect = assistant.suggestions.first { $0.id == id }?.direct != nil
        let outcome = await enqueue { [assistant] in await assistant.rejectSuggestionOutcome(id: id) }
        // Text-free count of Nej on direct instructions, to see whether the phrases misfire.
        if fromDirect, outcome.isSuccess { MioDirectNoteTally.record(.rejected, in: pendingLessonDefaults) }
        return outcome
    }

    /// Ångra for a direct instruction within 24 hours: the reminder is removed from Reminders
    /// (or the Mio note from Mio) and nothing is left under Förslag. After 24 hours the item
    /// stays and this refuses.
    func undoDirect(id: UUID, now: Date = .now) async -> MioOperationOutcome {
        let removal = await enqueue { [self] in
            guard let item = try? await content.latestItems().first(where: { $0.id == id }), let direct = item.direct else {
                return .conflict("Posten finns inte längre.")
            }
            guard direct.canUndo(at: now) else { return .conflict("Ångra går bara i 24 timmar. Posten finns kvar.") }
            if let handoff = item.handoff, handoff.destination == .reminders, let identifier = handoff.externalIdentifier {
                // The reminder's link carries this proposal ID (`MioLink`); see `MioReminderStore.remove`.
                do { try await reminders.remove(identifier, item.id) }
                catch MioReminderError.notFound {
                    // Never reported as undone: the reminder may still be in Reminders. The item stays.
                    return .failure(MioReminderError.notFound.localizedDescription)
                } catch MioReminderError.accessDenied {
                    return .failure("Mio behöver åtkomst till Påminnelser för att ta bort påminnelsen. Tillåt det i Inställningar → Mio → Påminnelser.")
                } catch {
                    return .failure("Påminnelsen kunde inte tas bort. Försök igen.")
                }
            }
            return .success
        }
        guard removal.isSuccess else { return removal }
        // The ordinary deletion: its journal and the item's system actions, never the transcript.
        let deleted = await deleteContent(id: id)
        if deleted.isSuccess { MioDirectNoteTally.record(.undone, in: pendingLessonDefaults) }
        return deleted
    }

    /// Saves proposals that came from "Mio, kom ihåg/notera" straight away, since a direct
    /// instruction counts as Yes (rule changed with the user's approval 2026-11-20): Reminders
    /// for "kom ihåg", a Mio note for "notera". A calendar event is never saved silently; it
    /// waits under Förslag. Anything that cannot be saved (for example without access to
    /// Reminders) also stays under Förslag, so nothing is lost. Runs inside the command queue.
    private func saveDirectCommands(_ suggestions: [MioSuggestion]) async -> MioDirectFeedback? {
        guard !suggestions.isEmpty else { return nil }
        var allSaved = true
        for suggestion in suggestions {
            guard let origin = suggestion.direct else { continue }
            let record = MioDirectRecord(destination: origin.destination, savedAt: .now)
            let outcome: MioOperationOutcome
            switch origin.destination {
            case .calendar:
                MioDirectNoteTally.record(.waiting, in: pendingLessonDefaults)
                continue
            case .mioNote:
                outcome = await performAccept(id: suggestion.id, expectedRevision: suggestion.reviewRevision, kind: .note,
                    title: suggestion.title, body: suggestion.body, scheduledAt: suggestion.scheduledAt,
                    dateConfirmed: false, dateChosen: false, isAllDay: false, direct: record)
            case .reminders:
                let appIsActive = capture.isAppActive()
                let examDate = origin.hasDate ? (date: suggestion.scheduledAt, allDay: !origin.hasTime) : nil
                outcome = await performHandoff(id: suggestion.id, expectedRevision: suggestion.reviewRevision,
                                               title: suggestion.title, kind: .task, direct: record,
                                               examDate: examDate) { [reminders] proposal, cleanTitle in
                    // iOS can only ask for access on screen; from the background the proposal waits.
                    if reminders.access() == .notDetermined, appIsActive { _ = await reminders.requestAccess() }
                    guard reminders.access() == .granted else { throw MioReminderError.accessDenied }
                    let due: Date? = origin.hasDate
                        ? (origin.hasTime ? proposal.scheduledAt : Calendar.current.startOfDay(for: proposal.scheduledAt)) : nil
                    let draft = MioReminderDraft(title: cleanTitle, notes: proposal.body,
                        url: proposal.sessionID.flatMap { MioLink.session($0, proposal: proposal.id) } ?? MioLink.proposal(proposal.id),
                        dueDate: due, hasTime: due != nil && origin.hasTime,
                        listID: UserDefaults.standard.string(forKey: MioReminderPort.lastListKey))
                    let identifier = try await reminders.save(draft)
                    return MioHandoff(destination: .reminders, externalIdentifier: identifier, sentAt: .now)
                }
            }
            if outcome.isSuccess {
                MioDirectNoteTally.record(.saved, in: pendingLessonDefaults)
            } else {
                allSaved = false
                MioDirectNoteTally.record(.waiting, in: pendingLessonDefaults)
            }
        }
        return allSaved ? .saved : .notUnderstood
    }

    /// Local detection of "Mio, kom ihåg/notera" in a session, for both the automatic path after
    /// each finalized segment and the "Hitta lokala Mio-förslag" button, so a direct instruction
    /// is saved at once with Ångra either way instead of waiting under Förslag for a Ja.
    func detectDirectCommands(in session: MioSession) async -> MioOperationOutcome {
        await enqueue { [self] in
            guard capture.session(id: session.id) != nil, !maintenance.recoveryBlocked else { return .cancelled }
            let detection = await assistant.detectDirectCommands(in: session)
            // Vibrate only after direct address, never for proposals AI picks up.
            if let feedback = await saveDirectCommands(detection.direct) { capture.directFeedback(feedback) }
            return detection.outcome
        }
    }

    /// Everyday transcripts older than 30 days are deleted (see `MioRetentionPolicy`). Runs at
    /// launch and when the app goes to the background; does nothing when nothing has expired.
    ///
    /// Rule (fix 2026-11-20): pruning is maintenance, never the user's deletion. It does not go
    /// through `delete(scope:)`, so it never changes `generation`, never cancels queued or
    /// automatic commands (a "Mio, kom ihåg" being saved, a Ja on a proposal), never clears
    /// `endingEverydaySessionID` and never sets `isDeleting`, so `beginLesson` is never refused.
    /// Each expired session is one ordinary, low-priority command in the queue: commands queued
    /// meanwhile run between sessions, and its writes are ordinary admitted writes, so the user's
    /// own deletion or export waits for the current step and then wins. It stops (and the next
    /// launch or background transition retries) while capture or a lesson is starting or
    /// stopping, while a question is being sent, and it never takes a session that is open,
    /// current or awaiting lesson registration.
    /// No deletion journal and no recovery block: the steps run in an idempotent order with the
    /// session row last (proposals, analysis decisions and processed sources; then links from
    /// approved items; then app-owned exports; then the transcript), so an interrupted prune
    /// leaves the session in place and the next prune finishes it. A failure only stops this
    /// round; it never sets the recovery block and never stops other work.
    @discardableResult
    func pruneExpiredEverydaySessions(now: Date = .now) async -> Int {
        guard !isPruning else { return 0 }
        isPruning = true
        defer { isPruning = false }
        guard !maintenance.recoveryBlocked, await storesAreDurable(),
              let document = try? await assistant.latestDocument() else { return 0 }
        let expired = MioRetentionPolicy.expiredEverydaySessionIDs(capture.allSessions,
            lessonSessionIDs: Set(document.lessons.map(\.sessionID)), now: now)
        var deleted = 0
        for id in expired {
            let outcome = await enqueue(recordsOutcome: false) { [self] in await pruneExpiredSession(id: id, now: now) }
            guard outcome.isSuccess else { break }
            deleted += 1
        }
        return deleted
    }

    /// Whether retention may touch stored data right now; see `pruneExpiredEverydaySessions`.
    private var pruningMayRun: Bool {
        !maintenance.blocksWork && !capture.isSwitchingCaptureMode && !questions.isSending
            && ![.preparing, .stopping].contains(capture.runState)
    }

    /// One expired session, inside the command queue. Re-checks expiry against fresh state,
    /// since the queue may have waited behind other work.
    private func pruneExpiredSession(id: UUID, now: Date) async -> MioOperationOutcome {
        guard pruningMayRun, !Task.isCancelled else { return .cancelled }
        guard let session = capture.session(id: id) else { return .success } // already gone
        let active = ![.off, .failed, .unavailable].contains(capture.runState)
        guard session.endedAt != nil, !pendingLessonIDs.contains(id), endingEverydaySessionID != id,
              !(active && capture.currentSession?.id == id),
              let document = try? await assistant.latestDocument(),
              MioRetentionPolicy.expiredEverydaySessionIDs([session],
                  lessonSessionIDs: Set(document.lessons.map(\.sessionID)), now: now) == [id] else { return .cancelled }
        analysis.forgetExpired(sessionID: id, assistant: assistant)
        let steps: [@MainActor () async -> MioOperationOutcome] = [
            { [assistant] in await assistant.deleteSessionDataOutcome(sessionID: id) },
            { [content] in await content.unlinkSessionOutcome(id: id) },
            { [content] in await content.removeExportsOutcome() },
            { [capture] in await capture.deleteSessionOutcome(id: id) },
        ]
        for step in steps {
            guard pruningMayRun, !Task.isCancelled else { return .cancelled }
            let outcome = await step()
            guard outcome.isSuccess else { return outcome }
        }
        return .success
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
            catch { return .failure("Kunde inte läsa en sammanhängande export. \(MioErrorText.action(for: error))") }
        }
    }

    /// The nightly copy (fas 6): the same consistent snapshot as the export, read in the command
    /// queue behind an exclusive snapshot, without diagnostics. Runs only while nothing is being
    /// captured (a paused capture is allowed, see `checkpointForBackup`), and only after the
    /// launch bootstrap and deletion recovery succeeded: data an unfinished deletion would remove
    /// is never sent. Cancelling the caller (iOS ending the background task) reaches the queued
    /// operation through `enqueue`'s cancellation handler and gives `.timeout`, never data.
    func backupExport() async -> Result<Data, MioBackupError> {
        guard await readyForBackgroundWork() else { return .failure(.dataBusy) }
        guard !Task.isCancelled else { return .failure(.timeout) }
        let produced = MioBackupResultBox()
        _ = await enqueue(recordsOutcome: false) { [self] in
            guard !Task.isCancelled else { produced.value = .failure(.timeout); return .cancelled }
            guard !maintenance.recoveryBlocked, deletion.pendingOperationID == nil else {
                produced.value = .failure(.dataBusy); return .conflict("")
            }
            guard [.off, .failed, .unavailable, .paused].contains(capture.runState) else {
                produced.value = .failure(.capturing); return .conflict("")
            }
            guard await maintenance.beginExclusive(deleting: false) else { produced.value = .failure(.dataBusy); return .conflict("") }
            defer { maintenance.endExclusive() }
            do {
                try Task.checkCancellation()
                let checkpoint = await capture.checkpointForBackup()
                guard checkpoint.isSuccess else { produced.value = .failure(.localData); return checkpoint }
                let export = MioLocalExport(content: try await content.latestItems(), sessions: try await capture.latestSessions(),
                                            assistant: try await assistant.latestDocument())
                try Task.checkCancellation()
                // The JSON encoding can take seconds for a large export: off the main actor.
                let data = try await Task.detached(priority: .utility) { try MioBackupService.encode(export) }.value
                try Task.checkCancellation()
                produced.value = .success(data)
                return .success
            } catch is CancellationError {
                produced.value = .failure(.timeout); return .cancelled
            } catch {
                produced.value = .failure(.localData); return .failure("")
            }
        }
        if Task.isCancelled { return .failure(.timeout) }
        return produced.value
    }

    /// Restoring (fas 6) is refused while capture runs or a deletion waits; the copy itself is
    /// applied at the next launch (`MioBackupRestore`), before any repository opens.
    var restoreBlocker: MioBackupError? {
        if ![.off, .failed, .unavailable].contains(capture.runState) || capture.isSwitchingCaptureMode { return .capturing }
        if maintenance.blocksWork { return .dataBusy }
        return nil
    }

    /// The deletion generation a restore is chosen under; see `MioBackupRestore.stage`.
    var restoreDeletionGeneration: Int { MioBackupRestore.deletionGeneration(in: pendingLessonDefaults) }

    /// Writes a downloaded copy as the pending restore, refusing it while capture runs, while a
    /// data operation blocks work, or when a deletion began after `deletionGeneration` was read.
    func stageRestore(_ data: Data, deletionGeneration: Int, now: Date = .now) throws -> Date {
        if let restoreBlocker { throw restoreBlocker }
        guard let restoreFiles else { throw MioBackupError.localData }
        let exportedAt = try MioBackupRestore.stage(data, files: restoreFiles, deletionGeneration: deletionGeneration,
                                                    defaults: pendingLessonDefaults, now: now)
        restorePending = MioBackupRestore.hasPending(in: restoreFiles)
        return exportedAt
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

    /// Queues detailed notes for an ended lesson and remembers it until the notes are complete.
    func requestLessonNotes(_ session: MioSession, userInitiated: Bool) {
        analysis.summarizeLesson(session, assistant: assistant)
        guard analysis.hasPendingLessonNotes(sessionID: session.id) else { return }
        var stored = storedLessonNotes()
        if !stored.contains(session.id) { stored.append(session.id); storeLessonNotes(stored) }
        if userInitiated { onLessonNotesStarted?(session.id) }
    }

    /// Re-queues listed lessons whose notes are still incomplete and drops finished or
    /// deleted ones. Runs whenever AI becomes enabled, including after launch.
    func resumeUnfinishedLessonNotes() {
        guard analysis.enabled, !maintenance.recoveryBlocked else { return }
        var unfinished: [UUID] = []
        for id in storedLessonNotes() {
            guard let session = capture.session(id: id), session.isLesson, session.endedAt != nil,
                  !MioLessonDocument(session: session, records: assistant.analyses).isComplete else { continue }
            unfinished.append(id)
            analysis.summarizeLesson(session, assistant: assistant)
        }
        storeLessonNotes(unfinished)
    }

    private func storedLessonNotes() -> [UUID] {
        (pendingLessonDefaults.stringArray(forKey: Self.lessonNotesKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    private func storeLessonNotes(_ ids: [UUID]) {
        pendingLessonDefaults.set(ids.map(\.uuidString), forKey: Self.lessonNotesKey)
    }

    private func observeAnalysisAvailability() {
        let enabled = withObservationTracking { analysis.enabled } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeAnalysisAvailability() }
        }
        if enabled, !analysisWasEnabled { resumeUnfinishedLessonNotes() }
        analysisWasEnabled = enabled
    }

    private func loadPresentationIfNeeded() async {
        guard !loadedPresentation else { return }
        loadedPresentation = true
        await content.bootstrap(); await assistant.bootstrap(); await capture.bootstrap()
    }

    /// Explicit approval; one stable draft ID preserves later user edits on retries. With a
    /// destination (0.9.1) the text already went to Notes through the share sheet and Mio keeps
    /// only the handoff record, without the answer text.
    func saveAnswerNote(_ draft: MioAnswerNoteDraft, title: String, body: String,
                        destination: MioHandoffDestination? = nil) async -> MioOperationOutcome {
        await enqueue { [self] in
            guard questions.generation == draft.generation, questions.answerDraft?.id == draft.id else { return .cancelled }
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty, !cleanBody.isEmpty else { return .failure("Skriv en rubrik och kontrollera svaret innan du sparar.") }
            guard cleanTitle.utf8.count <= 2_000, cleanBody.utf8.count <= 24_000 else { return .failure("Anteckningen är för stor. Korta texten innan du sparar.") }
            let handoff = destination.map { MioHandoff(destination: $0, externalIdentifier: nil, sentAt: .now) }
            let item = MioContentItem(id: draft.id, kind: .note, title: cleanTitle, body: handoff == nil ? cleanBody : "",
                                      scheduledAt: handoff?.sentAt, handoff: handoff)
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
        // Refused before any intent is written, so nothing is blocked or cancelled (ultrareview B1).
        guard await storesAreDurable() else { return .conflict(MioDeletionRecovery.temporaryStoreMessage) }
        invalidateCommands()
        return await enqueue(isDeletion: true) { [self] in
            guard !maintenance.recoveryBlocked else { return .conflict("Slutför den väntande raderingen med Försök igen innan du gör andra ändringar.") }
            guard await maintenance.beginExclusive(deleting: true) else { return .conflict("En dataåtgärd pågår redan.") }
            defer { maintenance.endExclusive() }
            // Before any intent is written: a pending restore is a full unencrypted copy that the
            // next launch would apply, bringing back what she deletes now.
            guard abandonPendingRestoreForDeletion() || scope != .all else {
                return .failure("Den väntande återställningen kunde inte tas bort. Försök igen.")
            }
            let outcome = await deletion.begin(scope: scope, targetID: targetID)
            maintenance.setRecoveryBlocked(!outcome.isSuccess)
            if outcome.isSuccess {
                if scope == .all {
                    pendingLessonIDs = []; storePendingLessons(); storeLessonNotes([])
                    MioDirectNoteTally.reset(in: pendingLessonDefaults)
                    MioLessonNotesLatencyLog.reset(in: pendingLessonDefaults)
                    MioLessonNotesReadyLog.reset(in: pendingLessonDefaults)
                    MioVocabularyAskedLog.reset(in: capture.vocabularyDefaults)
                    MioBackupAttempt.clear(in: pendingLessonDefaults)
                    // Morning and evening notifications are off again, as before fas 5.
                    MioDailyDigest.resetSettings(in: pendingLessonDefaults)
                    onAllDataDeleted?()
                }
                else if scope == .session, let targetID { clearLessonPending(targetID) }
                // Invalidation cancelled queued automatic work; surviving lessons are retried.
                resumePendingLessons()
            }
            return outcome
        }
    }

    private func enqueue(isDeletion: Bool = false, recordsOutcome: Bool = true,
                         _ operation: @escaping @MainActor () async -> MioOperationOutcome) async -> MioOperationOutcome {
        let id = UUID(); let token = generation; let previous = commandTail
        queuedCommands += 1
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, isDeletion || self.generation == token, !Task.isCancelled else { return MioOperationOutcome.cancelled }
            let result = await operation()
            if recordsOutcome, isDeletion || self.generation == token { self.lastOutcome = result }
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
            // While interrupted, a finalized transcript is audio captured before the interruption
            // (ultrareview A7); the coordinator files it under the window that ended there.
            if !session.isLesson, capture.currentSession?.id == session.id || endingEverydaySessionID == session.id,
               [.listening, .stopping, .interrupted].contains(capture.runState) || endingEverydaySessionID == session.id {
                analysis.observe(session, assistant: assistant)
            }
            automatically { [weak self] in _ = await self?.detectDirectCommands(in: session) }
        }
        capture.onLessonFinished = { [weak self] session in
            guard let self else { return }
            markLessonPending(session.id)
            // Blocked recovery defers the work; resumePendingLessons runs it afterwards.
            guard !maintenance.recoveryBlocked else { return }
            automatically { [weak self] in _ = await self?.finalizeLesson(session, fromCapture: true) }
        }
        capture.onCaptureStateChanged = { [weak self] state in self?.captureStateChanged(state) }
        analysis.onLessonNotesComplete = { [weak self] session in self?.lessonNotesCompleted(session) }
    }

    /// Measures the time from lesson end to finished notes once per lesson (no text) and
    /// hands the lesson to the review sheet. Notes finished again later are not reported again:
    /// `MioLessonNotesReadyLog` decides that, independent of whether the time was measured.
    func lessonNotesCompleted(_ session: MioSession, now: Date = .now) {
        guard session.isLesson, let endedAt = session.endedAt, capture.session(id: session.id) != nil else { return }
        storeLessonNotes(storedLessonNotes().filter { $0 != session.id })
        // Lessons measured before the ready log existed were already announced.
        let measuredBefore = MioLessonNotesLatencyLog.load(from: pendingLessonDefaults).entries.contains { $0.sessionID == session.id }
        guard MioLessonNotesReadyLog.claim(session.id, in: pendingLessonDefaults), !measuredBefore else { return }
        // Nil for an implausible time (a clock change, notes finished a week later): not measured.
        lastLessonNotesLatency = MioLessonNotesLatencyLog.record(sessionID: session.id, endedAt: endedAt, completedAt: now,
                                                                 in: pendingLessonDefaults)
        onLessonNotesReady?(session.id)
    }

    private func captureStateChanged(_ state: MioRunState) {
        guard !maintenance.recoveryBlocked else { return }
        if state == .stopping, let session = capture.currentSession, !session.isLesson {
            endingEverydaySessionID = session.id
            analysis.beginEndingEveryday(sessionID: session.id)
        } else if [.off, .paused, .interrupted, .failed, .unavailable].contains(state) {
            // Text captured before an interruption was captured with consent: send it now
            // instead of dropping it. The capture gap keeps it out of later context.
            let final = endingEverydaySessionID.flatMap { capture.session(id: $0) }
                ?? capture.currentSession.flatMap { $0.isLesson ? nil : $0 }
            analysis.finishEveryday(final, assistant: assistant)
            endingEverydaySessionID = nil
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

/// Carries the backup's bytes out of the command queue, whose operations return an outcome only.
@MainActor
private final class MioBackupResultBox {
    var value: Result<Data, MioBackupError> = .failure(.dataBusy)
}
