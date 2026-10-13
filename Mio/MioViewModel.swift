import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class MioViewModel {
    var runState: MioRunState = .off {
        didSet { if oldValue != runState { onCaptureStateChanged?(runState) } }
    }
    private(set) var stateRevision: UInt64 = 0
    @ObservationIgnored var onCaptureStateChanged: ((MioRunState) -> Void)?
    var microphonePermission = SpeechCapabilityService.microphonePermission
    var connectionState: TranscriptionConnectionState = .unchecked
    var serverMetadata: TranscriptionMetadata?
    var serverVersion: String?
    var connectionCheckedAt: Date?
    @ObservationIgnored private var finishingPipeline: (any MioCapturePipeline)?
    @ObservationIgnored private var connectionGeneration = UUID()
    private var sessionRegister = MioSessionRegister()
    var currentSession: MioSession? {
        get { sessionRegister.current }
        set { sessionRegister.current = newValue; stateRevision &+= 1 }
    }
    var previousSessions: [MioSession] {
        get { sessionRegister.sessions }
        set { sessionRegister.sessions = newValue; stateRevision &+= 1 }
    }
    var liveTranscript = ""
    var statusMessage = "Starta Mio för att skicka ljud privat till din transkriptionsserver."
    var errorMessage: String?
    var pauseUntil: Date?
    var now = Date.now
    var exportURL: URL?
    var isRefreshingSupport = false
    var isPreparingExport = false
    var isSwitchingCaptureMode = false
    private var suspendedEverydaySessionID: UUID?
    /// True only while startup is preparing a session it created itself.
    private var preparingNewSession = false
    var isLessonActive: Bool { currentSession?.isLesson == true && currentSession?.endedAt == nil }
    /// Receives finalized text only; the assistant never observes or stores audio buffers.
    @ObservationIgnored var onFinalizedTranscript: ((MioSession) -> Void)?
    @ObservationIgnored var onLessonFinished: ((MioSession) -> Void)?
    /// Local-notification fallback when iOS refuses a background microphone restart.
    @ObservationIgnored var onResumeNotice: ((MioResumeNotice) -> Void)?
    @ObservationIgnored var isAppActive: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }

    @ObservationIgnored private let diagnostics: MioDiagnosticsRepository
    @ObservationIgnored private var diagnosticsGeneration: UUID?
    @ObservationIgnored private let repository: any MioSessionStore
    @ObservationIgnored private let captureFactory: @MainActor (UUID, MioCaptureHandlers) throws -> any MioCapturePipeline
    @ObservationIgnored private var pipeline: (any MioCapturePipeline)?
    @ObservationIgnored private var repositoryGeneration: UUID?
    @ObservationIgnored private var sessionOperationTokens: [UUID: SessionOperationToken] = [:]
    /// Generation token used to reject callbacks from a pipeline that is no longer active.
    @ObservationIgnored private var activePipelineID: UUID?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var startupTaskID: UUID?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var batteryObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var hasBootstrapped = false
    @ObservationIgnored private var lastBatterySampleAt: Date?
    @ObservationIgnored private var lastPersistedAt: Date?
    @ObservationIgnored private var preparationCancellationRequested = false
    @ObservationIgnored private var runtimeFailureTeardownInProgress = false

    init(repository: any MioSessionStore = SessionRepository(), diagnostics: MioDiagnosticsRepository = .shared,
         captureFactory: @escaping @MainActor (UUID, MioCaptureHandlers) throws -> any MioCapturePipeline = { id, handlers in
             LiveTranscriptionPipeline(connection: try TranscriptionSettings.connection(), sessionID: id,
                 handlers: .init(result: handlers.result, status: handlers.status,
                                 event: handlers.event, failure: handlers.failure, diagnostic: handlers.diagnostic))
         }) {
        self.repository = repository
        self.diagnostics = diagnostics
        self.captureFactory = captureFactory
        UIDevice.current.isBatteryMonitoringEnabled = true
        registerBatteryObservers()
        startClock()
    }

    deinit {
        pauseTask?.cancel()
        startupTask?.cancel()
        clockTask?.cancel()
        saveTask?.cancel()
        let center = NotificationCenter.default
        batteryObservers.forEach(center.removeObserver)
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        do {
            repositoryGeneration = await repository.operationGeneration()
            var sessions = try await repository.loadSessions()
            for unfinishedIndex in sessions.indices where sessions[unfinishedIndex].endedAt == nil {
                let recoveredAt = Date.now
                let lastKnownAudio = sessions[unfinishedIndex].transcripts.map(\.audioEndedAt).max()
                    ?? sessions[unfinishedIndex].startedAt
                var gaps = sessions[unfinishedIndex].captureGaps ?? []
                gaps.append(CaptureGap(startedAt: min(lastKnownAudio, recoveredAt), endedAt: recoveredAt,
                                       reason: "Oväntat appavslut: underlag kan saknas efter senast sparade text. Mikrofonen återstartades inte."))
                sessions[unfinishedIndex].captureGaps = gaps
                sessions[unfinishedIndex].endedAt = recoveredAt
                if let lastIntervalIndex = sessions[unfinishedIndex].backgroundIntervals.indices.last,
                   sessions[unfinishedIndex].backgroundIntervals[lastIntervalIndex].endedAt == nil {
                    sessions[unfinishedIndex].backgroundIntervals[lastIntervalIndex].endedAt = recoveredAt
                }
                sessions[unfinishedIndex].events.append(
                    DiagnosticEvent(
                        kind: .warning,
                        message: "Appen öppnades efter att förra sessionen avslutats oväntat. Mikrofonen startades inte automatiskt."
                    )
                )
                let token = try await operationToken(for: sessions[unfinishedIndex].id)
                sessions[unfinishedIndex] = try await repository.saveCaptureCheckpoint(sessions[unfinishedIndex], token: token)
            }
            previousSessions = sessions.sorted { $0.startedAt > $1.startedAt }
            currentSession = previousSessions.first
        } catch {
            errorMessage = "Kunde inte läsa tidigare testdata: \(error.localizedDescription)"
        }

        await refreshSupport()
    }

    func refreshSupport() async {
        microphonePermission = SpeechCapabilityService.microphonePermission
    }

    func testTranscriptionConnection() async throws {
        let generation = connectionGeneration
        let client = TranscriptionClient(connection: try TranscriptionSettings.connection())
        defer { client.cancel() }
        connectionState = .connecting
        do {
            let health = try await client.health()
            guard generation == connectionGeneration else { throw CancellationError() }
            serverMetadata = health.metadata
            serverVersion = health.serverVersion
            connectionState = .connected
            connectionCheckedAt = .now
        } catch {
            if generation == connectionGeneration {
                connectionState = error is URLError ? .offline : .actionRequired
            }
            throw error
        }
    }

    func transcriptionConfigurationChanged() async {
        connectionGeneration = UUID()
        preparationCancellationRequested = true
        startupTask?.cancel()
        // Invalidate callbacks before awaiting teardown; old-origin replies cannot be adopted.
        activePipelineID = nil
        if let pipeline { await pipeline.stop(discard: true) }
        await finishingPipeline?.stop(discard: true)
        self.pipeline = nil
        serverMetadata = nil; serverVersion = nil; connectionState = .unchecked; connectionCheckedAt = nil
        if let currentSession, currentSession.endedAt == nil {
            runState = .paused
            statusMessage = "Anslutningen ändrades. Mikrofonen är av; tryck Fortsätt när anslutningen är klar."
        }
    }

    @ObservationIgnored private var finishingBackgroundTasks: Set<UIBackgroundTaskIdentifier> = []

    private func beginFinishingBackgroundTask() -> UIBackgroundTaskIdentifier {
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save Mio session") { [weak self] in
            MainActor.assumeIsolated {
                self?.cancelFinishing()
                self?.endFinishingBackgroundTask(identifier)
            }
        }
        if identifier != .invalid { finishingBackgroundTasks.insert(identifier) }
        return identifier
    }

    private func endFinishingBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        if finishingBackgroundTasks.remove(identifier) != nil { UIApplication.shared.endBackgroundTask(identifier) }
    }

    func cancelFinishing() {
        if let finishingPipeline { Task { await finishingPipeline.stop(discard: true) } }
    }

    func beginListening() {
        guard !MioMaintenanceState.shared.blocksWork else {
            errorMessage = "Slutför dataåtgärden innan du startar mikrofonen."
            abandonUnstartedLesson()
            return
        }
        guard !isSwitchingCaptureMode else { return }
        if currentSession?.isLesson == true, currentSession?.endedAt != nil { returnToEveryday() }
        guard runState == .off
                || runState == .paused
                || runState == .failed
                || runState == .unavailable
        else { return }
        preparationCancellationRequested = false
        startupTask?.cancel()
        let taskID = UUID()
        startupTaskID = taskID
        startupTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await self.startListening()
            if self.startupTaskID == taskID {
                self.startupTask = nil
                self.startupTaskID = nil
            }
        }
    }

    func beginLesson(title: String) async {
        guard !isSwitchingCaptureMode, !isLessonActive,
              [.off, .paused, .listening, .interrupted, .failed, .unavailable].contains(runState) else { return }
        guard MioMaintenanceState.shared.beginWrite() else { return }
        isSwitchingCaptureMode = true
        errorMessage = nil
        var writeAdmitted = true
        defer {
            isSwitchingCaptureMode = false
            if writeAdmitted { MioMaintenanceState.shared.endWrite() }
        }
        if runState == .listening || runState == .interrupted {
            await pause(.untilResumed, writeAlreadyAdmitted: true)
        }
        pauseTask?.cancel(); pauseTask = nil; pauseUntil = nil
        if let previous = currentSession, previous.endedAt == nil {
            suspendedEverydaySessionID = previous.id
            guard await forceSave(ignoreMaintenance: true) else { return }
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        currentSession = MioSession(title: cleanTitle.isEmpty ? "Lektion" : String(cleanTitle.prefix(120)), captureMode: .lesson)
        lastPersistedAt = nil
        appendEvent(kind: .info, message: "Lektionsläget startades. Vardags-Mio är pausat. Inget råljud sparas.")
        sampleBattery(reason: "Startvärde för lektionen")
        runState = .off
        // Release the admitted transition before awaiting an exclusive operation.
        // Its nested checkpoints belong to this admission and cannot wait on that barrier.
        let lessonID = currentSession?.id
        MioMaintenanceState.shared.endWrite()
        writeAdmitted = false
        await MioMaintenanceState.shared.waitForExclusive()
        guard !Task.isCancelled, !MioMaintenanceState.shared.recoveryBlocked,
              currentSession?.id == lessonID else {
            if currentSession?.id == lessonID { abandonUnstartedLesson() }
            return
        }
        // Continue the original explicit lesson command through the tracked startup task.
        isSwitchingCaptureMode = false
        beginListening()
    }

    func returnToEveryday() {
        guard currentSession?.isLesson == true, currentSession?.endedAt != nil,
              !isSwitchingCaptureMode, !runtimeFailureTeardownInProgress else { return }
        if let id = suspendedEverydaySessionID, let suspended = previousSessions.first(where: { $0.id == id && $0.endedAt == nil }) {
            currentSession = suspended
            runState = .paused
            statusMessage = "Lektionen är avslutad. Vardags-Mio är pausat tills du väljer Fortsätt Mio."
        } else {
            currentSession = nil
            runState = .off
            statusMessage = "Lektionen är avslutad. Du kan starta Mio igen."
        }
        suspendedEverydaySessionID = nil
        liveTranscript = ""
    }

    func cancelPreparation() {
        guard runState == .preparing else { return }
        preparationCancellationRequested = true
        statusMessage = "Avbryter och stänger eventuell ljudsession …"
        startupTask?.cancel()
    }

    private func startListening() async {
        guard !Task.isCancelled, !MioMaintenanceState.shared.blocksWork else { abandonUnstartedLesson(); return }
        guard runState == .off
                || runState == .paused
                || runState == .failed
                || runState == .unavailable
        else { return }
        if repositoryGeneration == nil { repositoryGeneration = await repository.operationGeneration() }
        diagnosticsGeneration = await diagnostics.beginRequest()
        guard !Task.isCancelled, !MioMaintenanceState.shared.blocksWork else { abandonUnstartedLesson(); return }
        pauseTask?.cancel()
        pauseTask = nil
        pauseUntil = nil
        errorMessage = nil
        exportURL = nil

        preparingNewSession = currentSession == nil || currentSession?.endedAt != nil
        if preparingNewSession {
            currentSession = MioSession()
            lastPersistedAt = nil
            appendEvent(
                kind: .info,
                message: "Sessionen startades av användaren. Ljud skickas privat till Pianissimo-servern; högst 60 sekunder ljud hålls i minnet. Ingen ljudfil sparas."
            )
            sampleBattery(reason: "Startvärde för batteriet")
        } else {
            appendEvent(kind: .info, message: "Mio återupptogs efter paus.")
        }

        runState = .preparing
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "okänd"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "okänt"
        appendEvent(kind: .info, message: "Mio \(version) (\(build)); iOS \(UIDevice.current.systemVersion).")
        statusMessage = "Ansluter till transkriptionsservern innan mikrofonen startas …"

        guard await forceSave() else {
            runState = .off
            if !abandonUnstartedLesson() { runState = .paused }
            statusMessage = "Mikrofonen är av. Sessionen kunde inte sparas."
            return
        }
        if Task.isCancelled || preparationCancellationRequested {
            await finishCancelledPreparation()
            return
        }

        let newPipeline: any MioCapturePipeline
        do { newPipeline = try makePipeline() }
        catch {
            runState = .paused; errorMessage = error.localizedDescription
            connectionState = .actionRequired
            statusMessage = "Mikrofonen är av. Kontrollera transkriptionsinställningarna."
            activePipelineID = nil
            if preparationCancellationRequested || error is CancellationError {
                await finishCancelledPreparation()
            } else {
                await finishFailedLessonPreparation()
            }
            return
        }
        pipeline = newPipeline
        do {
            let details = try await newPipeline.start()
            try Task.checkCancellation()
            guard pipeline === newPipeline else { return }
            runState = .listening
            statusMessage = isLessonActive ? "Lektionsläge: fångar underlag till anteckningar. Vardags-Mio är pausat." : "Mio lyssnar. När AI är på kan Mio föreslå händelser och att göra ur vanliga samtal."
            serverMetadata = details.health.metadata
            serverVersion = details.health.serverVersion
            connectionState = .connected; connectionCheckedAt = .now
            appendEvent(kind: .info, message: "Mikrofonen startade. Privat transkription: \(details.health.metadata.model), revision \(details.health.metadata.revision).")
            // Ask on screen now; iOS cannot show the permission prompt from the background.
            onResumeNotice?(.prepare)
            await refreshSupport()
        } catch {
            if pipeline !== newPipeline {
                await newPipeline.stop()
                return
            }
            await newPipeline.stop(discard: true)
            if pipeline === newPipeline {
                pipeline = nil
                activePipelineID = nil
            }
            if preparationCancellationRequested || error is CancellationError {
                await finishCancelledPreparation()
                return
            }
            runState = .paused
            errorMessage = error.localizedDescription
            connectionState = error is URLError ? .offline : .actionRequired
            statusMessage = "Mikrofonen är av. Kontrollera anslutningen och tryck Fortsätt."
            appendEvent(kind: .error, message: statusMessage)
            await finishFailedLessonPreparation()
            await refreshSupport()
        }
    }

    private func finishCancelledPreparation() async {
        errorMessage = nil
        liveTranscript = ""
        activePipelineID = nil
        guard currentSession?.isLesson == true || preparingNewSession else {
            // A resumed session keeps its identity and remains paused, not ended.
            runState = .paused
            appendEvent(kind: .info, message: "Starten avbröts av användaren. Sessionen är fortfarande pausad.")
            statusMessage = "Starten avbröts. Mikrofonen används inte; tryck Fortsätt när du vill lyssna igen."
            await forceSave(allowCancelledCleanup: true)
            await refreshSupport()
            return
        }
        runState = .off
        statusMessage = "Starten avbröts. Mio är av och mikrofonen används inte."
        finishCurrentSession(message: "Starten avbröts av användaren.")
        if await forceSave(allowCancelledCleanup: true), currentSession?.isLesson == true { returnToEveryday() }
        await refreshSupport()
    }

    /// A lesson that never reached capture holds no evidence and was never persisted.
    /// Dropping it restores the suspended everyday session without a disk write, which
    /// must also work while deletion recovery blocks writes.
    @discardableResult
    private func abandonUnstartedLesson() -> Bool {
        guard let lesson = currentSession, lesson.isLesson, lesson.endedAt == nil, lesson.transcripts.isEmpty,
              lastPersistedAt == nil, pipeline == nil, runState == .off else { return false }
        saveTask?.cancel(); saveTask = nil
        sessionRegister.remove(id: lesson.id)
        sessionOperationTokens[lesson.id] = nil
        if let id = suspendedEverydaySessionID,
           let suspended = previousSessions.first(where: { $0.id == id && $0.endedAt == nil }) {
            currentSession = suspended
            runState = .paused
            statusMessage = "Lektionen startades inte. Vardags-Mio är pausat tills du väljer Fortsätt Mio."
        } else {
            currentSession = nil
            statusMessage = "Lektionen startades inte. Mikrofonen används inte."
        }
        suspendedEverydaySessionID = nil
        stateRevision &+= 1
        return true
    }

    private func finishFailedLessonPreparation() async {
        if isLessonActive {
            finishCurrentSession(message: "Lektionsstarten misslyckades. Mikrofonen är av.")
            if await forceSave() {
                returnToEveryday()
                statusMessage = "Lektionsstarten misslyckades. Mikrofonen är av; vardags-Mio kan fortsätta efter ditt val."
            }
        } else { await forceSave() }
    }

    func stopListening() async {
        guard runState == .listening || runState == .interrupted || runState == .paused else {
            return
        }
        let background = beginFinishingBackgroundTask()
        defer { endFinishingBackgroundTask(background) }
        runState = .stopping
        pauseTask?.cancel()
        pauseTask = nil
        pauseUntil = nil
        let activePipeline = pipeline
        pipeline = nil
        statusMessage = "Mikrofonen stängs. Avslutar redan fångad text, högst 15 sekunder …"
        finishingPipeline = activePipeline
        await activePipeline?.stop()
        finishingPipeline = nil
        activePipelineID = nil

        onResumeNotice?(.withdraw)
        if let endedID = currentSession?.id { releaseServerSession(endedID) }
        sampleBattery(reason: "Slutvärde för batteriet")
        finishCurrentSession(message: "Sessionen stoppades av användaren.")
        runState = .off
        liveTranscript = ""
        statusMessage = "Mio är av. Mikrofonen används inte."
        let didSave = await forceSave()
        if let lesson = currentSession, lesson.isLesson {
            // Finalization is queued even when the final save failed; the workflow retries
            // that save first and keeps the lesson visibly pending until it succeeds.
            onLessonFinished?(lesson)
            if didSave { returnToEveryday() }
        }
    }

    func pause(_ length: PauseLength, writeAlreadyAdmitted: Bool = false) async {
        guard runState == .listening || runState == .interrupted else { return }
        let background = beginFinishingBackgroundTask()
        defer { endFinishingBackgroundTask(background) }
        pauseTask?.cancel()
        let activePipeline = pipeline
        pipeline = nil
        runState = .stopping
        statusMessage = "Stänger mikrofonen för pausen …"
        finishingPipeline = activePipeline
        await activePipeline?.stop()
        finishingPipeline = nil
        activePipelineID = nil

        runState = .paused
        liveTranscript = ""
        onResumeNotice?(.withdraw)
        if let interval = length.interval {
            let resumeDate = Date.now.addingTimeInterval(interval)
            pauseUntil = resumeDate
            statusMessage = "Mikrofonen är av. Paus till \(resumeDate.formatted(date: .omitted, time: .shortened)); tryck Fortsätt när du vill lyssna igen."
            appendEvent(kind: .info, message: "Mio pausades i \(length.title). Mikrofonen stängdes av.")


        } else {
            pauseUntil = nil
            statusMessage = "Mikrofonen är av tills du startar Mio igen."
            appendEvent(kind: .info, message: "Mio pausades tills användaren startar igen. Mikrofonen stängdes av.")
        }
        sampleBattery(reason: "Batterivärde vid paus")
        await forceSave(ignoreMaintenance: writeAlreadyAdmitted)
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard currentSession?.endedAt == nil else { return }
        // Scene callbacks open and close background intervals. Only a transcript's usable
        // source-audio time—not callback delivery time—can overlap one as evidence.
        switch phase {
        case .active:
            Task { await pipeline?.foreground() }
            closeOpenBackgroundInterval(at: .now)
            appendEvent(kind: .lifecycle, message: "Appen blev aktiv på skärmen.")
        case .inactive:
            appendEvent(kind: .lifecycle, message: "Appen blev inaktiv, exempelvis av en systemruta.")
        case .background:
            if currentSession?.backgroundIntervals.last?.endedAt != nil
                || currentSession?.backgroundIntervals.isEmpty == true {
                currentSession?.backgroundIntervals.append(BackgroundInterval())
            }
            appendEvent(
                kind: .lifecycle,
                message: runState == .listening
                    ? "Appen gick till bakgrunden medan Mio lyssnade."
                    : "Appen gick till bakgrunden medan mikrofonen var av."
            )
            sampleBattery(reason: "Batterivärde vid bakgrund")
            Task { [weak self] in
                await self?.forceSave()
            }
        @unknown default:
            appendEvent(kind: .lifecycle, message: "Appens livscykel ändrades på ett nytt sätt.")
        }
    }

    func prepareExport() async {
        guard let currentSession, currentSession.endedAt != nil else { return }
        isPreparingExport = true
        do {
            exportURL = try await repository.makeExportFile(for: currentSession)
        } catch {
            errorMessage = "Kunde inte skapa testfilen: \(error.localizedDescription)"
        }
        isPreparingExport = false
    }

    func editSession(id: UUID, title: String, note: String) async -> Bool {
        guard MioMaintenanceState.shared.beginWrite() else { return false }
        defer { MioMaintenanceState.shared.endWrite() }
        guard let session = session(id: id), session.endedAt != nil else {
            errorMessage = "Stoppa sessionen innan du redigerar den."
            return false
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let token = try await operationToken(for: id)
            let stored = try await repository.updateMetadata(id: id, title: cleanTitle, note: cleanNote, token: token)
            replaceSessionInMemory(stored)
            exportURL = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Kunde inte spara sessionsändringarna: \(error.localizedDescription)"
            return false
        }
    }

    func correctTranscript(sessionID: UUID, segmentID: UUID, text: String) async -> Bool {
        guard MioMaintenanceState.shared.beginWrite() else { return false }
        defer { MioMaintenanceState.shared.endWrite() }
        guard let session = session(id: sessionID), session.endedAt != nil,
              session.transcripts.contains(where: { $0.id == segmentID })
        else {
            errorMessage = "Texten kan redigeras när sessionen har stoppats."
            return false
        }
        let correction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correction.isEmpty else {
            errorMessage = "En textdel kan inte vara tom. Radera hela sessionen om den inte ska sparas."
            return false
        }
        do {
            let token = try await operationToken(for: sessionID)
            let stored = try await repository.correctTranscript(sessionID: sessionID, segmentID: segmentID,
                                                                text: correction, token: token)
            replaceSessionInMemory(stored)
            exportURL = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Kunde inte spara textändringen: \(error.localizedDescription)"
            return false
        }
    }

    /// Display-only: the stored speaker numbers in the transcript never change.
    func renameSpeaker(sessionID: UUID, speaker: Int, name: String) async -> Bool {
        guard MioMaintenanceState.shared.beginWrite() else { return false }
        defer { MioMaintenanceState.shared.endWrite() }
        guard let session = session(id: sessionID), session.endedAt != nil,
              session.transcripts.contains(where: { $0.speaker == speaker }) else {
            errorMessage = "Talare kan byta namn när sessionen har stoppats."
            return false
        }
        do {
            let token = try await operationToken(for: sessionID)
            let stored = try await repository.renameSpeaker(sessionID: sessionID, speaker: speaker, name: name, token: token)
            replaceSessionInMemory(stored)
            exportURL = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Kunde inte spara talarnamnet: \(error.localizedDescription)"
            return false
        }
    }

    /// Best effort and fire-and-forget: the server forgets the session's speakers after 10
    /// idle minutes anyway, so a failure here is never shown or retried.
    private func releaseServerSession(_ id: UUID) {
        guard let connection = try? TranscriptionSettings.connection() else { return }
        let client = TranscriptionClient(connection: connection)
        Task {
            await client.endSession(id)
            client.cancel()
        }
    }

    func deleteSession(id: UUID) async -> Bool { await deleteSessionOutcome(id: id).isSuccess }

    func latestSessions() async throws -> [MioSession] { try await repository.loadSessions() }

    func deleteSessionOutcome(id: UUID, ignoreMaintenance: Bool = false) async -> MioOperationOutcome {
        if !ignoreMaintenance, !MioMaintenanceState.shared.beginWrite() {
            return .conflict("Vänta tills dataåtgärden är klar.")
        }
        defer { if !ignoreMaintenance { MioMaintenanceState.shared.endWrite() } }
        if session(id: id)?.endedAt == nil, session(id: id) != nil {
            errorMessage = "Stoppa den aktiva sessionen innan du raderar den."
            return .conflict(errorMessage ?? "Stoppa sessionen innan du raderar den.")
        }
        do {
            try await repository.delete(id: id)
            let wasSelected = currentSession?.id == id
            sessionRegister.remove(id: id)
            sessionOperationTokens[id] = nil
            if wasSelected { currentSession = previousSessions.first }
            exportURL = nil
            errorMessage = nil
            stateRevision &+= 1
            return .success
        } catch {
            errorMessage = "Kunde inte radera sessionen: \(error.localizedDescription)"
            return .failure("Kunde inte radera sessionen: \(error.localizedDescription)")
        }
    }

    func deleteAllData() async { _ = await deleteAllDataOutcome() }

    func cancelForDeletion() async {
        startupTask?.cancel(); saveTask?.cancel(); pauseTask?.cancel()
        activePipelineID = nil
        let active = pipeline; let finishing = finishingPipeline
        pipeline = nil; finishingPipeline = nil
        await active?.stop(discard: true)
        await finishing?.stop(discard: true)
        await startupTask?.value
        startupTask = nil; saveTask = nil; pauseTask = nil
        suspendedEverydaySessionID = nil
        runState = .off; liveTranscript = ""; pauseUntil = nil
    }

    func deleteAllDataOutcome() async -> MioOperationOutcome {
        suspendedEverydaySessionID = nil
        guard runState == .off || runState == .failed || runState == .unavailable else { return .conflict("Stoppa mikrofonen innan du raderar all data.") }
        saveTask?.cancel()
        saveTask = nil
        do {
            repositoryGeneration = try await repository.deleteAll()
            sessionOperationTokens = [:]
            currentSession = nil
            previousSessions = []
            exportURL = nil
            errorMessage = nil
            lastPersistedAt = nil
            statusMessage = "All sparad sessionsdata är raderad."
            return .success
        } catch {
            errorMessage = "Kunde inte radera sessionsdata: \(error.localizedDescription)"
            return .failure(errorMessage ?? "Kunde inte radera sessionsdata.")
        }
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    var duration: TimeInterval {
        currentSession?.duration(at: now) ?? 0
    }

    var allSessions: [MioSession] {
        sessionRegister.sessions.sorted { $0.startedAt > $1.startedAt }
    }

    func session(id: UUID) -> MioSession? {
        if currentSession?.id == id {
            return currentSession
        }
        return previousSessions.first { $0.id == id }
    }

    var pauseRemainingText: String? {
        guard let pauseUntil else { return nil }
        let seconds = max(0, Int(pauseUntil.timeIntervalSince(now)))
        return Self.durationFormatter.string(from: TimeInterval(seconds))
    }

    var batteryDropText: String {
        guard let drop = currentSession?.batteryDrop else { return "Inte mätt ännu" }
        let percentagePoints = Int((drop * 100).rounded())
        if percentagePoints > 0 { return "−\(percentagePoints) procentenheter" }
        if percentagePoints < 0 { return "+\(-percentagePoints) procentenheter" }
        return "Oförändrad"
    }

    private func makePipeline() throws -> any MioCapturePipeline {
        let pipelineID = UUID()
        activePipelineID = pipelineID
        let diagnosticToken = diagnosticsGeneration
        let diagnosticStore = diagnostics
        return try captureFactory(currentSession!.id, MioCaptureHandlers(
                result: { [weak self] chunk, reply, words in
                    guard let self else { return }
                    await MainActor.run {
                        guard self.activePipelineID == pipelineID,
                              self.currentSession?.id == chunk.sessionID,
                              !(self.currentSession?.transcripts.contains { $0.sourceChunkID == chunk.id } ?? true)
                        else { return }
                        self.receiveRemoteTranscript(chunk: chunk, reply: reply, words: words)
                    }
                },
                status: { [weak self] message in
                    Task { @MainActor in
                        guard self?.activePipelineID == pipelineID else { return }
                        self?.statusMessage = message
                    }
                },
                event: { [weak self] event in
                    guard let self else { return }
                    await MainActor.run {
                        guard self.activePipelineID == pipelineID else { return }
                        self.receivePipelineEvent(event)
                    }
                },
                failure: { [weak self] error in
                    guard let self else { return }
                    await MainActor.run {
                        guard self.activePipelineID == pipelineID else { return }
                        self.receiveFailure(error)
                    }
                },
                diagnostic: { diagnostic in
                    guard let diagnosticToken, diagnostic.isValid else { return }
                    var event = MioDiagnosticEvent(operation: .transcription)
                    event.transcription = diagnostic
                    await diagnosticStore.record(event, generation: diagnosticToken)
                }
            ))
    }

    private func receiveRemoteTranscript(chunk: AudioChunk, reply: TranscriptionReply, words: [TranscriptionWord]) {
        // One segment per speaker turn; without labels this is one segment per chunk as before.
        for run in TranscriptionWord.speakerRuns(words) {
            guard let first = run.words.first, let last = run.words.last else { continue }
            let start = max(chunk.startedAt, chunk.origin.addingTimeInterval(first.start))
            let end = max(start, min(chunk.endedAt, chunk.origin.addingTimeInterval(last.end)))
            receiveTranscript(run.words.map(\.text).joined(separator: " "), isFinal: true,
                              audioStartedAt: start, audioEndedAt: end, audioTimingIsValid: chunk.timingValidity.isReliable,
                              chunkID: chunk.id, metadata: reply.metadata, timingValidity: chunk.timingValidity,
                              speaker: run.speaker)
        }
    }

    private func receiveTranscript(
        _ text: String,
        isFinal: Bool,
        audioStartedAt: Date,
        audioEndedAt: Date,
        audioTimingIsValid: Bool,
        chunkID: UUID? = nil, metadata: TranscriptionMetadata? = nil, timingValidity: AudioTimingValidity? = nil,
        speaker: Int? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isFinal {
            liveTranscript = ""
            let containsMio = MioWakeWordDetector.containsWakeWord(in: trimmed)
            let wasObservedInBackground = audioTimingIsValid
                && currentSession?.backgroundIntervals.contains(where: {
                    $0.overlaps(audioStart: audioStartedAt, audioEnd: audioEndedAt)
                }) == true
            var segment = TranscriptSegment(createdAt: audioStartedAt,
                audioStartedAt: audioStartedAt, audioEndedAt: audioEndedAt, text: trimmed,
                containsMio: containsMio, wasObservedInBackground: wasObservedInBackground,
                audioTimingIsValid: audioTimingIsValid)
            segment.sourceChunkID = chunkID
            segment.transcriptionMetadata = metadata
            segment.timingValidity = timingValidity
            segment.speaker = speaker
            currentSession?.transcripts.append(segment)

            if !audioTimingIsValid {
                currentSession?.events.append(
                    DiagnosticEvent(
                        kind: .warning,
                        message: "En textdel saknade giltig ljudtid och räknas därför inte som bakgrundsbevis."
                    )
                )
            }
            if wasObservedInBackground {
                currentSession?.events.append(
                    DiagnosticEvent(
                        kind: .lifecycle,
                        message: "Talmotorn levererade text vars ljudtid överlappar appens bakgrundsintervall."
                    )
                )
            }
            if containsMio {
                currentSession?.events.append(
                    DiagnosticEvent(
                        kind: .wakeWord,
                        message: "Ordet Mio upptäcktes lokalt i texten från den privata transkriptionsservern."
                    )
                )
                if UIApplication.shared.applicationState == .active {
                    MioFeedback.success()
                }
            }
            persistSoon()
            if let currentSession {
                onFinalizedTranscript?(currentSession)
            }
        } else {
            liveTranscript = trimmed
        }
    }

    private func receivePipelineEvent(_ event: PipelineEvent) {
        switch event {
        case let .connection(state, metadata):
            connectionState = state
            if let metadata { serverMetadata = metadata }
            if state == .connected { connectionCheckedAt = .now }
        case let .captureGap(gap):
            if currentSession?.captureGaps == nil { currentSession?.captureGaps = [] }
            currentSession?.captureGaps?.append(gap)
            appendEvent(kind: .warning, message: gap.reason)
            persistSoon()
        case .interruptionBegan:
            if runState == .listening { runState = .interrupted }
            statusMessage = "iOS har avbrutit mikrofonen. Sessionen finns kvar."
            appendEvent(kind: .interruption, message: statusMessage)
        case let .interruptionEnded(shouldResume):
            if shouldResume, runState == .interrupted || runState == .listening {
                runState = .listening
                statusMessage = "Mio lyssnar igen. Avbrottet är markerat som en lucka."
                appendEvent(kind: .interruption, message: "Mikrofonen startades om automatiskt efter avbrottet.")
                onResumeNotice?(.withdraw)
            }
        case let .restartFailed(message):
            guard runState == .interrupted || runState == .listening else { return }
            let decision = MioCaptureResumePolicy.decision(userWantsListening: true, interruptionOngoing: false,
                restartFailed: true, appIsActive: isAppActive())
            if decision == .notifyUser {
                // The pipeline keeps the session and the open gap; becoming active retries.
                runState = .interrupted
                statusMessage = "\(message) Öppna Mio för att fortsätta lyssna."
                appendEvent(kind: .interruption, message: "\(message) En notis ber dig öppna Mio.")
                onResumeNotice?(.post)
            } else {
                pauseAfterFailure("\(message) Tryck Fortsätt för att lyssna igen.")
            }
        case let .routeChanged(message): appendEvent(kind: .routeChange, message: message)
        case let .needsResume(message): pauseAfterFailure(message)
        case .mediaServicesReset:
            pauseAfterFailure("iOS återställde ljudsystemet. Tryck Fortsätt för att återstarta mikrofonen.")
        }
    }

    private func receiveFailure(_ error: Error) {
        pauseAfterFailure(error.localizedDescription)
    }

    private func pauseAfterFailure(_ message: String) {
        guard !runtimeFailureTeardownInProgress, runState != .stopping else { return }
        errorMessage = message
        appendEvent(kind: .error, message: message)
        guard let failedPipeline = pipeline else { runState = .paused; return }
        pipeline = nil
        runtimeFailureTeardownInProgress = true
        runState = .stopping
        finishingPipeline = failedPipeline
        Task { [weak self] in
            await failedPipeline.stop(discard: true)
            guard let self else { return }
            self.activePipelineID = nil
            self.finishingPipeline = nil
            await self.forceSave()
            self.runtimeFailureTeardownInProgress = false
            self.runState = .paused
            self.statusMessage = "Mikrofonen är av. \(message)"
        }
    }

    private func finishCurrentSession(message: String) {
        guard currentSession != nil else { return }
        closeOpenBackgroundInterval(at: .now)
        currentSession?.events.append(DiagnosticEvent(kind: .info, message: message))
        currentSession?.endedAt = .now
        persistSoon()
    }

    private func replaceSessionInMemory(_ session: MioSession) {
        // A result may resume on the main actor after a newer operation or deletion.
        guard sessionRegister.sessions.contains(where: { $0.id == session.id }) else { return }
        sessionRegister.replace(session)
    }

    private func appendEvent(kind: DiagnosticEventKind, message: String) {
        guard currentSession != nil else { return }
        currentSession?.events.append(DiagnosticEvent(kind: kind, message: message))
        persistSoon()
    }

    private func closeOpenBackgroundInterval(at date: Date) {
        guard let lastIndex = currentSession?.backgroundIntervals.indices.last,
              currentSession?.backgroundIntervals[lastIndex].endedAt == nil
        else { return }
        currentSession?.backgroundIntervals[lastIndex].endedAt = date
    }

    private func sampleBattery(reason: String) {
        guard currentSession != nil else { return }
        let device = UIDevice.current
        let reading = BatteryReading(
            level: device.batteryLevel,
            state: Self.batteryStateName(device.batteryState)
        )
        currentSession?.batteryReadings.append(reading)
        currentSession?.events.append(
            DiagnosticEvent(
                kind: .info,
                message: "\(reason): \(reading.percentageText), \(reading.state.rawValue)."
            )
        )
        lastBatterySampleAt = .now
        persistSoon()
    }

    private func persistSoon() {
        guard let session = currentSession, let token = sessionOperationTokens[session.id] else { return }
        saveTask?.cancel()
        let elapsed = lastPersistedAt.map { Date.now.timeIntervalSince($0) } ?? .infinity
        let delay = max(0, 15 - elapsed)
        saveTask = Task { [repository] in
            do {
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                try Task.checkCancellation()
                guard MioMaintenanceState.shared.beginWrite() else { return }
                defer { MioMaintenanceState.shared.endWrite() }
                let stored = try await repository.saveCaptureCheckpoint(session, token: token)
                if self.currentSession?.id == stored.id {
                    self.currentSession?.mutationRevision = max(self.currentSession?.mutationRevision ?? 0, stored.mutationRevision ?? 0)
                }
                self.lastPersistedAt = .now
                self.saveTask = nil
            } catch is CancellationError {
                // Expected when saves are coalesced or an immediate save supersedes this task.
            } catch {
                self.errorMessage = "Kunde inte spara testdata under körningen: \(error.localizedDescription)"
            }
        }
    }

    /// Export owns the barrier, so its final checkpoint explicitly bypasses admission.
    func checkpointForSnapshot() async -> MioOperationOutcome {
        guard [.off, .failed, .unavailable].contains(runState) else { return .conflict("Avsluta sessionen innan du exporterar data.") }
        guard currentSession != nil else { return .success }
        let saved = await forceSave(ignoreMaintenance: true)
        return saved ? .success : .failure("Kunde inte spara den senaste sessionen inför export. Försök igen.")
    }

    @discardableResult
    private func forceSave(ignoreMaintenance: Bool = false, allowCancelledCleanup: Bool = false) async -> Bool {
        saveTask?.cancel()
        guard let currentSession else { return false }
        do {
            if !allowCancelledCleanup { try Task.checkCancellation() }
            if repositoryGeneration == nil { repositoryGeneration = await repository.operationGeneration() }
            // Capture the token before waiting: a full/target deletion invalidates it.
            let token = try await operationToken(for: currentSession.id)
            if !ignoreMaintenance {
                // User-cancelled startup still persists its final local checkpoint.
                // Deletion cleanup must never wait on the exclusive owner awaiting startup.
                if !allowCancelledCleanup {
                    await MioMaintenanceState.shared.waitForExclusive()
                    try Task.checkCancellation()
                }
                guard MioMaintenanceState.shared.beginWrite() else {
                    errorMessage = "Sessionen väntar på att den lokala dataåtgärden slutförs. Försök igen efter återhämtningen."
                    return false
                }
            }
            defer { if !ignoreMaintenance { MioMaintenanceState.shared.endWrite() } }
            let stored = try await repository.saveCaptureCheckpoint(currentSession, token: token)
            if self.currentSession?.id == stored.id {
                self.currentSession?.mutationRevision = max(self.currentSession?.mutationRevision ?? 0, stored.mutationRevision ?? 0)
            }
            lastPersistedAt = .now; saveTask = nil
            return true
        } catch is CancellationError { return false }
        catch {
            errorMessage = "Kunde inte spara sessionsdata: \(error.localizedDescription)"
            return false
        }
    }

    /// Retries the final checkpoint of an ended session that may exist only in memory.
    func persistEndedSession(id: UUID) async -> MioOperationOutcome {
        guard let session = session(id: id), session.endedAt != nil else {
            return .failure("Sessionen är inte avslutad eller finns inte längre.")
        }
        do {
            if repositoryGeneration == nil { repositoryGeneration = await repository.operationGeneration() }
            let token = try await operationToken(for: id)
            guard MioMaintenanceState.shared.beginWrite() else {
                return .conflict("Sessionen väntar på att den lokala dataåtgärden slutförs.")
            }
            defer { MioMaintenanceState.shared.endWrite() }
            let stored = try await repository.saveCaptureCheckpoint(session, token: token)
            if var current = self.session(id: id) {
                current.mutationRevision = max(current.mutationRevision ?? 0, stored.mutationRevision ?? 0)
                if currentSession?.id == id { currentSession = current } else { sessionRegister.replace(current) }
            }
            if currentSession?.id == id { lastPersistedAt = .now }
            return .success
        } catch {
            return .failure("Kunde inte spara lektionen: \(error.localizedDescription)")
        }
    }

    private func operationToken(for id: UUID) async throws -> SessionOperationToken {
        if let token = sessionOperationTokens[id] { return token }
        guard let generation = repositoryGeneration else { throw SessionRepositoryError.staleOperation }
        let token = try await repository.operationToken(for: id, generation: generation)
        sessionOperationTokens[id] = token
        return token
    }

    private func registerBatteryObservers() {
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            batteryObservers.append(
                center.addObserver(forName: name, object: UIDevice.current, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.currentSession?.endedAt == nil else { return }
                        self.sampleBattery(reason: "Batteriet ändrades")
                    }
                }
            )
        }
    }

    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    break
                }
                guard let self else { break }
                self.now = .now

                let shouldSampleBattery = self.currentSession?.endedAt == nil
                    && self.runState == .listening
                    && (self.lastBatterySampleAt == nil
                        || Date.now.timeIntervalSince(self.lastBatterySampleAt!) >= 60)
                if shouldSampleBattery {
                    self.sampleBattery(reason: "Periodiskt batterivärde")
                }
            }
        }
    }

    private static func batteryStateName(_ state: UIDevice.BatteryState) -> BatteryStateName {
        switch state {
        case .unknown: .unknown
        case .unplugged: .unplugged
        case .charging: .charging
        case .full: .full
        @unknown default: .unknown
        }
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}
