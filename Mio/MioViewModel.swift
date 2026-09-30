import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class MioViewModel {
    var runState: MioRunState = .off
    var microphonePermission = SpeechCapabilityService.microphonePermission
    var connectionState: TranscriptionConnectionState = .unchecked
    var serverMetadata: TranscriptionMetadata?
    var serverVersion: String?
    var connectionCheckedAt: Date?
    @ObservationIgnored private var finishingPipeline: LiveTranscriptionPipeline?
    @ObservationIgnored private var connectionGeneration = UUID()
    var currentSession: MioSession?
    var previousSessions: [MioSession] = []
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
    var isLessonActive: Bool { currentSession?.isLesson == true && currentSession?.endedAt == nil }
    /// Receives finalized text only; the assistant never observes or stores audio buffers.
    @ObservationIgnored var onFinalizedTranscript: ((MioSession) -> Void)?
    @ObservationIgnored var onLessonFinished: ((MioSession) -> Void)?

    @ObservationIgnored private let repository: SessionRepository
    @ObservationIgnored private var pipeline: LiveTranscriptionPipeline?
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

    init(repository: SessionRepository = SessionRepository()) {
        self.repository = repository
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
                try await repository.upsert(sessions[unfinishedIndex])
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
        defer { isSwitchingCaptureMode = false; MioMaintenanceState.shared.endWrite() }
        if runState == .listening || runState == .interrupted { await pause(.untilResumed) }
        pauseTask?.cancel(); pauseTask = nil; pauseUntil = nil
        if let previous = currentSession, previous.endedAt == nil {
            suspendedEverydaySessionID = previous.id
            await forceSave()
            guard errorMessage == nil else { return }
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        currentSession = MioSession(title: cleanTitle.isEmpty ? "Lektion" : String(cleanTitle.prefix(120)), captureMode: .lesson)
        lastPersistedAt = nil
        appendEvent(kind: .info, message: "Lektionsläget startades. Vardags-Mio är pausat. Inget råljud sparas.")
        sampleBattery(reason: "Startvärde för lektionen")
        runState = .off
        // Use the same tracked startup task as everyday capture so Avbryt can stop preparation.
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
        guard !Task.isCancelled else { return }
        guard runState == .off
                || runState == .paused
                || runState == .failed
                || runState == .unavailable
        else { return }
        pauseTask?.cancel()
        pauseTask = nil
        pauseUntil = nil
        errorMessage = nil
        exportURL = nil

        if currentSession == nil || currentSession?.endedAt != nil {
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

        let newPipeline: LiveTranscriptionPipeline
        do { newPipeline = try makePipeline() }
        catch {
            runState = .paused; errorMessage = error.localizedDescription
            connectionState = .actionRequired
            statusMessage = "Mikrofonen är av. Kontrollera transkriptionsinställningarna."
            await forceSave()
            return
        }
        pipeline = newPipeline
        do {
            let details = try await newPipeline.start()
            try Task.checkCancellation()
            guard pipeline === newPipeline else { return }
            runState = .listening
            statusMessage = isLessonActive ? "Lektionsläge: fångar underlag till anteckningar. Vardags-Mio är pausat." : "Mio lyssnar. AI-tolkning kan föreslå planer ur vanliga samtal när du aktiverar den."
            serverMetadata = details.health.metadata
            serverVersion = details.health.serverVersion
            connectionState = .connected; connectionCheckedAt = .now
            appendEvent(kind: .info, message: "Mikrofonen startade. Privat transkription: \(details.health.metadata.model), revision \(details.health.metadata.revision).")
            await refreshSupport()
        } catch {
            if pipeline !== newPipeline {
                await newPipeline.stop()
                return
            }
            if preparationCancellationRequested || error is CancellationError {
                await newPipeline.stop()
            }
            if pipeline === newPipeline {
                pipeline = nil
                activePipelineID = nil
            }
            if preparationCancellationRequested || error is CancellationError {
                errorMessage = nil
                runState = .off
                liveTranscript = ""
                statusMessage = "Starten avbröts. Mio är av och mikrofonen används inte."
                finishCurrentSession(message: "Starten avbröts av användaren.")
                await forceSave()
                await refreshSupport()
                return
            }
            runState = .paused
            errorMessage = error.localizedDescription
            connectionState = error is URLError ? .offline : .actionRequired
            statusMessage = "Mikrofonen är av. Kontrollera anslutningen och tryck Fortsätt."
            appendEvent(kind: .error, message: statusMessage)
            await forceSave()
            await refreshSupport()
        }
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

        sampleBattery(reason: "Slutvärde för batteriet")
        finishCurrentSession(message: "Sessionen stoppades av användaren.")
        runState = .off
        liveTranscript = ""
        statusMessage = "Mio är av. Mikrofonen används inte."
        await forceSave()
        if let lesson = currentSession, lesson.isLesson, errorMessage == nil {
            onLessonFinished?(lesson)
            returnToEveryday()
        }
    }

    func pause(_ length: PauseLength) async {
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
        await forceSave()
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
        guard var session = session(id: id), session.endedAt != nil else {
            errorMessage = "Stoppa sessionen innan du redigerar den."
            return false
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        session.title = cleanTitle.isEmpty ? nil : cleanTitle
        session.manualNote = cleanNote.isEmpty ? nil : cleanNote
        do {
            try await repository.upsert(session)
            replaceSessionInMemory(session)
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
        guard var session = session(id: sessionID), session.endedAt != nil,
              let index = session.transcripts.firstIndex(where: { $0.id == segmentID })
        else {
            errorMessage = "Texten kan redigeras när sessionen har stoppats."
            return false
        }
        let correction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correction.isEmpty else {
            errorMessage = "En textdel kan inte vara tom. Radera hela sessionen om den inte ska sparas."
            return false
        }
        session.transcripts[index].correctedText = correction == session.transcripts[index].text
            ? nil
            : correction
        do {
            try await repository.upsert(session)
            replaceSessionInMemory(session)
            exportURL = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Kunde inte spara textändringen: \(error.localizedDescription)"
            return false
        }
    }

    func deleteSession(id: UUID) async -> Bool {
        guard MioMaintenanceState.shared.beginWrite() else { return false }
        defer { MioMaintenanceState.shared.endWrite() }
        if currentSession?.id == id, currentSession?.endedAt == nil {
            errorMessage = "Stoppa den aktiva sessionen innan du raderar den."
            return false
        }
        do {
            try await repository.delete(id: id)
            previousSessions.removeAll { $0.id == id }
            if currentSession?.id == id {
                currentSession = previousSessions.first
            }
            exportURL = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Kunde inte radera sessionen: \(error.localizedDescription)"
            return false
        }
    }

    func deleteAllData() async {
        suspendedEverydaySessionID = nil
        guard runState == .off || runState == .failed || runState == .unavailable else { return }
        saveTask?.cancel()
        saveTask = nil
        do {
            try await repository.deleteAll()
            currentSession = nil
            previousSessions = []
            exportURL = nil
            errorMessage = nil
            lastPersistedAt = nil
            statusMessage = "All sparad sessionsdata är raderad."
        } catch {
            errorMessage = "Kunde inte radera testdata: \(error.localizedDescription)"
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
        var sessions = previousSessions.filter { $0.id != currentSession?.id }
        if let currentSession { sessions.append(currentSession) }
        return sessions.sorted { $0.startedAt > $1.startedAt }
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

    private func makePipeline() throws -> LiveTranscriptionPipeline {
        let connection = try TranscriptionSettings.connection()
        let pipelineID = UUID()
        activePipelineID = pipelineID
        return LiveTranscriptionPipeline(connection: connection, sessionID: currentSession!.id,
            handlers: .init(
                result: { [weak self] chunk, reply, words in
                    await MainActor.run {
                        guard let self, self.activePipelineID == pipelineID,
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
                    await MainActor.run {
                        guard self?.activePipelineID == pipelineID else { return }
                        self?.receivePipelineEvent(event)
                    }
                },
                failure: { [weak self] error in
                    await MainActor.run {
                        guard self?.activePipelineID == pipelineID else { return }
                        self?.receiveFailure(error)
                    }
                }
            ))
    }

    private func receiveRemoteTranscript(chunk: AudioChunk, reply: TranscriptionReply, words: [TranscriptionWord]) {
        guard let first = words.first, let last = words.last else { return }
        let start = max(chunk.startedAt, chunk.origin.addingTimeInterval(first.start))
        let end = min(chunk.endedAt, chunk.origin.addingTimeInterval(last.end))
        receiveTranscript(words.map(\.text).joined(separator: " "), isFinal: true,
                          audioStartedAt: start, audioEndedAt: end, audioTimingIsValid: true,
                          chunkID: chunk.id, metadata: reply.metadata)
    }

    private func receiveTranscript(
        _ text: String,
        isFinal: Bool,
        audioStartedAt: Date,
        audioEndedAt: Date,
        audioTimingIsValid: Bool,
        chunkID: UUID? = nil, metadata: TranscriptionMetadata? = nil
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
                statusMessage = "Mikrofonen levererar ljud igen."
                appendEvent(kind: .interruption, message: statusMessage)
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
        if let currentSession {
            previousSessions.removeAll { $0.id == currentSession.id }
            previousSessions.insert(currentSession, at: 0)
        }
        persistSoon()
    }

    private func replaceSessionInMemory(_ session: MioSession) {
        if currentSession?.id == session.id {
            currentSession = session
        }
        if let index = previousSessions.firstIndex(where: { $0.id == session.id }) {
            previousSessions[index] = session
        } else if session.endedAt != nil {
            previousSessions.append(session)
        }
        previousSessions.sort { $0.startedAt > $1.startedAt }
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
        guard let session = currentSession else { return }
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
                try await repository.upsert(session)
                self.lastPersistedAt = .now
                self.saveTask = nil
            } catch is CancellationError {
                // Expected when saves are coalesced or an immediate save supersedes this task.
            } catch {
                self.errorMessage = "Kunde inte spara testdata under körningen: \(error.localizedDescription)"
            }
        }
    }

    private func forceSave() async {
        guard MioMaintenanceState.shared.beginWrite() else { return }
        defer { MioMaintenanceState.shared.endWrite() }
        saveTask?.cancel()
        guard let currentSession else { return }
        do {
            try await repository.upsert(currentSession)
            lastPersistedAt = .now
            saveTask = nil
        } catch {
            errorMessage = "Kunde inte spara testdata: \(error.localizedDescription)"
        }
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
