import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class PhaseOneViewModel {
    var runState: MioRunState = .off
    var support = SpeechSupportSnapshot()
    var currentSession: PhaseOneSession?
    var previousSessions: [PhaseOneSession] = []
    var liveTranscript = ""
    var statusMessage = "Tryck på kontrollen för att börja fas 1-testet."
    var errorMessage: String?
    var pauseUntil: Date?
    var now = Date.now
    var exportURL: URL?
    var isRefreshingSupport = false
    var isPreparingExport = false

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
            if let unfinishedIndex = sessions.firstIndex(where: { $0.endedAt == nil }) {
                let recoveredAt = Date.now
                sessions[unfinishedIndex].endedAt = recoveredAt
                if let lastIntervalIndex = sessions[unfinishedIndex].backgroundIntervals.indices.last,
                   sessions[unfinishedIndex].backgroundIntervals[lastIntervalIndex].endedAt == nil {
                    sessions[unfinishedIndex].backgroundIntervals[lastIntervalIndex].endedAt = recoveredAt
                }
                sessions[unfinishedIndex].events.append(
                    DiagnosticEvent(
                        kind: .warning,
                        message: "Appen öppnades efter att förra testet avslutats oväntat. Mikrofonen startades inte automatiskt."
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
        guard !isRefreshingSupport else { return }
        isRefreshingSupport = true
        support = await SpeechCapabilityService.inspect()
        isRefreshingSupport = false
    }

    func beginListening() {
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
            currentSession = PhaseOneSession()
            lastPersistedAt = nil
            appendEvent(
                kind: .info,
                message: "Fas 1-test startades. Råljud sparas inte; bara lokal tidsstämplad text och diagnostik sparas."
            )
            sampleBattery(reason: "Startvärde för batteriet")
        } else {
            appendEvent(kind: .info, message: "Mio återupptogs efter paus.")
        }

        runState = .preparing
        statusMessage = "Kontrollerar mikrofon och svensk talmodell …"

        let newPipeline = makePipeline()
        pipeline = newPipeline
        do {
            let details = try await newPipeline.start()
            try Task.checkCancellation()
            guard pipeline === newPipeline else { return }
            runState = .listening
            statusMessage = "Lyssnar på svenska lokalt. Säg några meningar och ordet Mio."
            appendEvent(
                kind: .info,
                message: "Mikrofonen och \(details.engine.title) startade (\(details.localeIdentifier))."
            )
            if details.downloadedModel {
                appendEvent(kind: .info, message: "Apples svenska språkmodell hämtades till telefonen.")
            }
            await refreshSupport()
            support.selectedEngine = details.engine
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
            receiveFailure(error)
            finishCurrentSession(message: "Testet kunde inte starta.")
            await forceSave()
            await refreshSupport()
        }
    }

    func stopListening() async {
        guard runState == .listening || runState == .interrupted || runState == .paused else {
            return
        }
        runState = .stopping
        pauseTask?.cancel()
        pauseTask = nil
        pauseUntil = nil
        let activePipeline = pipeline
        pipeline = nil
        statusMessage = "Avslutar den lokala talmotorn …"
        await activePipeline?.stop()
        activePipelineID = nil

        sampleBattery(reason: "Slutvärde för batteriet")
        finishCurrentSession(message: "Fas 1-testet stoppades av användaren.")
        runState = .off
        liveTranscript = ""
        statusMessage = "Mio är av. Mikrofonen används inte."
        await forceSave()
    }

    func pause(_ length: PauseLength) async {
        guard runState == .listening else { return }
        pauseTask?.cancel()
        let activePipeline = pipeline
        pipeline = nil
        runState = .stopping
        statusMessage = "Stänger mikrofonen för pausen …"
        await activePipeline?.stop()
        activePipelineID = nil

        runState = .paused
        liveTranscript = ""
        if let interval = length.interval {
            let resumeDate = Date.now.addingTimeInterval(interval)
            pauseUntil = resumeDate
            statusMessage = "Mikrofonen är av. Fortsättning är planerad till \(resumeDate.formatted(date: .omitted, time: .shortened)); iOS kan kräva att appen öppnas igen."
            appendEvent(kind: .info, message: "Mio pausades i \(length.title). Mikrofonen stängdes av.")

            pauseTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    try Task.checkCancellation()
                    guard let self, self.runState == .paused else { return }
                    self.pauseTask = nil
                    self.beginListening()
                } catch {
                    // Expected when scheduled resume is replaced or the session ends manually.
                }
            }
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

    func deleteAllData() async {
        guard runState == .off || runState == .failed || runState == .unavailable else { return }
        do {
            try await repository.deleteAll()
            currentSession = nil
            previousSessions = []
            exportURL = nil
            errorMessage = nil
            lastPersistedAt = nil
            statusMessage = "All sparad fas 1-data är raderad."
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

    private func makePipeline() -> LiveTranscriptionPipeline {
        let pipelineID = UUID()
        activePipelineID = pipelineID
        return LiveTranscriptionPipeline(
            handlers: .init(
                result: { [weak self] text, isFinal, audioStartedAt, audioEndedAt, audioTimingIsValid in
                    await MainActor.run { [weak self] in
                        guard self?.activePipelineID == pipelineID else { return }
                        self?.receiveTranscript(
                            text,
                            isFinal: isFinal,
                            audioStartedAt: audioStartedAt,
                            audioEndedAt: audioEndedAt,
                            audioTimingIsValid: audioTimingIsValid
                        )
                    }
                },
                status: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard self?.activePipelineID == pipelineID else { return }
                        self?.statusMessage = message
                    }
                },
                event: { [weak self] event in
                    Task { @MainActor [weak self] in
                        guard self?.activePipelineID == pipelineID else { return }
                        self?.receivePipelineEvent(event)
                    }
                },
                failure: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard self?.activePipelineID == pipelineID else { return }
                        self?.receiveFailure(error)
                    }
                }
            )
        )
    }

    private func receiveTranscript(
        _ text: String,
        isFinal: Bool,
        audioStartedAt: Date,
        audioEndedAt: Date,
        audioTimingIsValid: Bool
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
            currentSession?.transcripts.append(
                TranscriptSegment(
                    createdAt: audioStartedAt,
                    audioStartedAt: audioStartedAt,
                    audioEndedAt: audioEndedAt,
                    text: trimmed,
                    containsMio: containsMio,
                    wasObservedInBackground: wasObservedInBackground,
                    audioTimingIsValid: audioTimingIsValid
                )
            )
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
                        message: "Ordet Mio upptäcktes lokalt i en färdig textdel. Inget skickades till internet."
                    )
                )
                if UIApplication.shared.applicationState == .active {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
            persistSoon()
        } else {
            liveTranscript = trimmed
        }
    }

    private func receivePipelineEvent(_ event: PipelineEvent) {
        switch event {
        case .interruptionBegan:
            if runState == .listening {
                runState = .interrupted
                statusMessage = "iOS har tillfälligt avbrutit mikrofonen."
            }
            appendEvent(kind: .interruption, message: "Ljudet avbröts, exempelvis av ett samtal eller alarm.")
        case let .interruptionEnded(shouldResume):
            appendEvent(
                kind: .interruption,
                message: shouldResume
                    ? "Ljudavbrottet slutade och iOS tillät automatisk återstart."
                    : "Ljudavbrottet slutade, men iOS tillät inte automatisk återstart. Stoppa och starta testet igen."
            )
            if shouldResume {
                runState = .listening
                statusMessage = "Ljudavbrottet är slut. Mio lyssnar igen."
            } else {
                runState = .failed
                errorMessage = "iOS tillät inte återstart efter ljudavbrottet. Mio stänger ljudsessionen; starta ett nytt test."
                shutDownPipelineAfterRuntimeFailure()
            }
        case let .routeChanged(description):
            appendEvent(
                kind: .routeChange,
                message: "\(description). Om texten slutar komma: stoppa och starta testet igen."
            )
        case let .audioBuffersDropped(count):
            appendEvent(
                kind: .warning,
                message: "Talmotorn hann inte med och totalt \(count) mikrofonbuffertar har tappats."
            )
        case let .backendFallback(message):
            appendEvent(kind: .warning, message: message)
        case .mediaServicesReset:
            appendEvent(
                kind: .error,
                message: "iOS startade om ljudsystemet. Mio stänger mikrofonen; starta därefter ett nytt test."
            )
            runState = .failed
            errorMessage = "iOS startade om ljudsystemet. Mio har stängt mikrofonen; starta ett nytt test."
            shutDownPipelineAfterRuntimeFailure()
        }
    }

    private func receiveFailure(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if runtimeFailureTeardownInProgress {
            appendEvent(kind: .error, message: message)
            return
        }
        errorMessage = message
        statusMessage = message
        if let phaseOneError = error as? MioPhaseOneError {
            switch phaseOneError {
            case .speechTranscriberUnavailable, .swedishUnavailable:
                runState = .unavailable
            default:
                runState = .failed
            }
        } else {
            runState = .failed
        }
        appendEvent(kind: .error, message: message)
        shutDownPipelineAfterRuntimeFailure()
    }

    private func shutDownPipelineAfterRuntimeFailure() {
        guard let failedPipeline = pipeline else { return }
        pipeline = nil
        runtimeFailureTeardownInProgress = true
        runState = .stopping
        statusMessage = "Ett tekniskt fel inträffade. Mio stänger mikrofonen säkert …"
        Task { [weak self] in
            await failedPipeline.stop()
            guard let self else { return }
            self.activePipelineID = nil
            self.sampleBattery(reason: "Slutvärde efter tekniskt fel")
            self.finishCurrentSession(message: "Testet avslutades automatiskt efter ett tekniskt fel.")
            await self.forceSave()
            self.runtimeFailureTeardownInProgress = false
            self.runState = .failed
            self.statusMessage = self.errorMessage ?? "Testet stoppades efter ett tekniskt fel."
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
