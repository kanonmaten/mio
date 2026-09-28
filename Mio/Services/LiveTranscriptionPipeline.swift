import AVFoundation
import CoreMedia
import Foundation
import Speech

/// A one-shot speech pipeline. Once shutdown begins, this instance cannot be restarted.
/// Startup and shutdown are serialized explicitly; audio delivery has a single consumer.
final class LiveTranscriptionPipeline: @unchecked Sendable {
    struct Handlers {
        let result: (
            _ text: String,
            _ isFinal: Bool,
            _ audioStartedAt: Date,
            _ audioEndedAt: Date,
            _ audioTimingIsValid: Bool
        ) async -> Void
        let status: (_ message: String) -> Void
        let event: (_ event: PipelineEvent) -> Void
        let failure: (_ error: Error) -> Void
    }

    struct StartDetails: Sendable {
        let localeIdentifier: String
        let downloadedModel: Bool
        let engine: LocalSpeechEngine
    }

    /// The unchecked boundary is limited to the tap-to-audio-task handoff. The task is
    /// the sole consumer and treats the captured PCM buffer as read-only.
    private struct CapturedAudioBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let capturedUptime: TimeInterval
    }

    private enum TranscriptionBackend {
        private struct PendingResult {
            let text: String
            let audioStartedAt: Date
            let audioEndedAt: Date
            let audioTimingIsValid: Bool
        }

        case advanced(SpeechTranscriber, locale: Locale)
        case dictation(DictationTranscriber, locale: Locale)

        var module: any SpeechModule {
            switch self {
            case let .advanced(module, _): module
            case let .dictation(module, _): module
            }
        }

        var locale: Locale {
            switch self {
            case let .advanced(_, locale), let .dictation(_, locale): locale
            }
        }

        var engine: LocalSpeechEngine {
            switch self {
            case .advanced: .speechTranscriber
            case .dictation: .dictationTranscriber
            }
        }

        func makeResultTask(handlers: Handlers, timelineOrigin: Date) -> Task<Void, Never> {
            switch self {
            case let .advanced(module, _):
                Task {
                    var pendingResult: PendingResult?
                    do {
                        for try await result in module.results {
                            guard !Task.isCancelled else { break }
                            let text = String(result.text.characters)
                            let dates = Self.wallClockDates(for: result.range, origin: timelineOrigin)
                            if result.isFinal {
                                pendingResult = nil
                            } else {
                                pendingResult = PendingResult(
                                    text: text,
                                    audioStartedAt: dates.start,
                                    audioEndedAt: dates.end,
                                    audioTimingIsValid: dates.isValid
                                )
                            }
                            await handlers.result(
                                text,
                                result.isFinal,
                                dates.start,
                                dates.end,
                                dates.isValid
                            )
                        }
                        await Self.flush(pendingResult, handlers: handlers)
                    } catch is CancellationError {
                        // Expected when result consumption is cancelled during teardown.
                    } catch {
                        await Self.flush(pendingResult, handlers: handlers)
                        handlers.failure(error)
                    }
                }

            case let .dictation(module, _):
                Task {
                    var pendingResult: PendingResult?
                    do {
                        for try await result in module.results {
                            guard !Task.isCancelled else { break }
                            let text = String(result.text.characters)
                            let dates = Self.wallClockDates(for: result.range, origin: timelineOrigin)
                            if result.isFinal {
                                pendingResult = nil
                            } else {
                                pendingResult = PendingResult(
                                    text: text,
                                    audioStartedAt: dates.start,
                                    audioEndedAt: dates.end,
                                    audioTimingIsValid: dates.isValid
                                )
                            }
                            await handlers.result(
                                text,
                                result.isFinal,
                                dates.start,
                                dates.end,
                                dates.isValid
                            )
                        }
                        await Self.flush(pendingResult, handlers: handlers)
                    } catch is CancellationError {
                        // Expected when result consumption is cancelled during teardown.
                    } catch {
                        await Self.flush(pendingResult, handlers: handlers)
                        handlers.failure(error)
                    }
                }
            }
        }

        private static func flush(_ result: PendingResult?, handlers: Handlers) async {
            guard let result,
                  !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            await handlers.result(
                result.text,
                true,
                result.audioStartedAt,
                result.audioEndedAt,
                result.audioTimingIsValid
            )
        }

        /// Maps a usable analyzer-relative range onto wall-clock dates. Invalid ranges
        /// deliberately remain ineligible for background evidence.
        private static func wallClockDates(
            for range: CMTimeRange,
            origin: Date
        ) -> (start: Date, end: Date, isValid: Bool) {
            let startSeconds = range.start.seconds
            let durationSeconds = range.duration.seconds
            guard startSeconds.isFinite, durationSeconds.isFinite,
                  startSeconds >= 0, durationSeconds >= 0
            else {
                return (.now, .now, false)
            }
            let start = origin.addingTimeInterval(startSeconds)
            return (start, start.addingTimeInterval(durationSeconds), true)
        }
    }

    private let handlers: Handlers
    private let audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private let converter = BufferConverter()
    private let dropCountLock = NSLock()
    /// Guards shutdown state and gates audio startup; it does not protect every property.
    private let lifecycleLock = NSLock()

    private var backend: TranscriptionBackend?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var analyzerInput: AsyncStream<AnalyzerInput>.Continuation?
    private var microphoneOutput: AsyncStream<CapturedAudioBuffer>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var observerTokens: [NSObjectProtocol] = []
    private var tapInstalled = false
    private var analyzerStarted = false
    private var stopping = false
    private var droppedBufferCount = 0
    // Paired wall-clock and monotonic origins map analyzer-relative ranges back to dates.
    private var timelineWallClockOrigin = Date.now
    private var timelineUptimeOrigin: TimeInterval = 0
    private var lastAnalyzerInputEndTime = CMTime.zero

    init(handlers: Handlers) {
        self.handlers = handlers
    }

    func start() async throws -> StartDetails {
        guard lifecycleLock.withLock({ !stopping && shutdownTask == nil }) else {
            throw CancellationError()
        }
        dropCountLock.withLock {
            droppedBufferCount = 0
        }
        do {
            guard await SpeechCapabilityService.requestMicrophonePermission() else {
                throw MioError.microphoneDenied
            }
            handlers.status("Förbereder SpeechAnalyzer och en svensk transkriptionsmodul …")
            handlers.event(.speechSupport(await SpeechCapabilityService.inspect()))
            try Task.checkCancellation()
            let dictationLocale = await DictationTranscriber.supportedLocale(
                equivalentTo: SpeechCapabilityService.requestedLocale
            )
            let details: StartDetails
            if SpeechTranscriber.isAvailable,
               let locale = await SpeechTranscriber.supportedLocale(
                   equivalentTo: SpeechCapabilityService.requestedLocale
               ) {
                let advancedBackend = TranscriptionBackend.advanced(
                    SpeechTranscriber(
                        locale: locale,
                        preset: .timeIndexedProgressiveTranscription
                    ),
                    locale: locale
                )
                // prepare installs missing supported assets before starting the analyzer.
                do {
                    details = try await prepare(advancedBackend)
                } catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                    guard lifecycleLock.withLock({ !stopping }) else { throw CancellationError() }
                    guard let dictationLocale else { throw error }
                    let failure = error as NSError
                    handlers.event(.backendFallback(
                        "SpeechTranscriber kunde inte installeras eller starta: \(failure.localizedDescription) [\(failure.domain):\(failure.code)]. Provar DictationTranscriber i en ny SpeechAnalyzer."
                    ))
                    await discardPreparedBackend()
                    details = try await prepare(
                        .dictation(
                            SpeechCapabilityService.makeResponsiveLongDictation(locale: dictationLocale),
                            locale: dictationLocale
                        )
                    )
                }
            } else if let dictationLocale {
                let reason = SpeechTranscriber.isAvailable
                    ? "SpeechTranscriber finns, men iOS erbjuder inte svenska för den på denna enhet."
                    : "iOS rapporterar att SpeechTranscriber inte är tillgänglig på denna enhet."
                handlers.event(.backendFallback(reason + " DictationTranscriber används för svenska."))
                details = try await prepare(
                    .dictation(
                        SpeechCapabilityService.makeResponsiveLongDictation(locale: dictationLocale),
                        locale: dictationLocale
                    )
                )
            } else {
                throw MioError.swedishUnavailable
            }

            var finalSupport = await SpeechCapabilityService.inspect()
            finalSupport.selectedEngine = details.engine
            finalSupport.details = "Den aktuella lyssningen använder \(details.engine.title). Se händelseloggen för eventuell fallbackorsak."
            handlers.event(.speechSupport(finalSupport))
            try Task.checkCancellation()
            try startAudioResourcesIfAllowed()

            handlers.status("SpeechAnalyzer bearbetar svenska lokalt på telefonen.")
            return details
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        let task: Task<Void, Never> = lifecycleLock.withLock {
            if let shutdownTask {
                return shutdownTask
            }
            stopping = true
            let newTask: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.performStop()
            }
            shutdownTask = newTask
            return newTask
        }
        await task.value
    }

    private func performStop() async {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine.stop()
        microphoneOutput?.finish()
        microphoneOutput = nil

        if let audioTask {
            await audioTask.value
        }
        self.audioTask = nil

        analyzerInput?.finish()
        analyzerInput = nil
        if analyzerStarted {
            var finalizedSuccessfully = false
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
                finalizedSuccessfully = true
            } catch where error is CancellationError {
                // Cancellation is normal during teardown.
            } catch {
                handlers.failure(error)
            }
            if finalizedSuccessfully, let resultTask {
                await resultTask.value
            } else {
                resultTask?.cancel()
            }
        } else {
            resultTask?.cancel()
        }
        analyzerStarted = false

        resultTask = nil
        analyzer = nil
        backend = nil
        analyzerFormat = nil

        unregisterAudioEvents()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startAudioResourcesIfAllowed() throws {
        try lifecycleLock.withLock {
            try Task.checkCancellation()
            guard !stopping else { throw CancellationError() }
            try configureAudioSession()
            registerForAudioEvents()
            try startMicrophoneStream()
        }
        try Task.checkCancellation()
        guard lifecycleLock.withLock({ !stopping }) else {
            throw CancellationError()
        }
    }

    private func configureAudioSession() throws {
        try audioSession.setCategory(.playAndRecord, mode: .default)
        try? audioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func prepare(_ backend: TranscriptionBackend) async throws -> StartDetails {
        self.backend = backend
        let modules: [any SpeechModule] = [backend.module]
        let downloadedModel = try await SpeechCapabilityService.ensureAssets(
            for: modules,
            locale: backend.locale,
            engineTitle: backend.engine.title,
            status: handlers.status
        )

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw MioError.missingAudioFormat
        }
        try Task.checkCancellation()
        self.analyzerFormat = analyzerFormat

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        analyzerInput = inputContinuation
        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer
        timelineWallClockOrigin = .now
        timelineUptimeOrigin = ProcessInfo.processInfo.systemUptime
        lastAnalyzerInputEndTime = .zero
        try await analyzer.start(inputSequence: inputSequence)
        analyzerStarted = true
        try Task.checkCancellation()
        resultTask = backend.makeResultTask(
            handlers: handlers,
            timelineOrigin: timelineWallClockOrigin
        )

        return StartDetails(
            localeIdentifier: backend.locale.identifier,
            downloadedModel: downloadedModel,
            engine: backend.engine
        )
    }

    private func discardPreparedBackend() async {
        analyzerInput?.finish()
        analyzerInput = nil
        if analyzerStarted {
            var finalizedSuccessfully = false
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
                finalizedSuccessfully = true
            } catch {
                // Cleanup must not replace the setup error that triggered backend fallback.
            }
            if finalizedSuccessfully, let resultTask {
                await resultTask.value
            } else {
                resultTask?.cancel()
            }
        } else {
            resultTask?.cancel()
        }
        resultTask = nil
        analyzerStarted = false
        analyzer = nil
        analyzerFormat = nil
        self.backend = nil
    }

    private func startMicrophoneStream() throws {
        guard let analyzerFormat else {
            throw MioError.invalidAudioStream
        }

        var localContinuation: AsyncStream<CapturedAudioBuffer>.Continuation?
        let microphoneStream = AsyncStream<CapturedAudioBuffer>(bufferingPolicy: .bufferingNewest(32)) {
            localContinuation = $0
        }
        guard let localContinuation else {
            throw MioError.invalidAudioStream
        }
        microphoneOutput = localContinuation

        let inputNode = audioEngine.inputNode
        let microphoneFormat = inputNode.outputFormat(forBus: 0)
        guard microphoneFormat.channelCount > 0, microphoneFormat.sampleRate > 0 else {
            throw MioError.invalidAudioStream
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: microphoneFormat
        ) { [weak self] buffer, time in
            guard let self else { return }
            let capturedUptime = time.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: time.hostTime)
                : ProcessInfo.processInfo.systemUptime
            let captured = CapturedAudioBuffer(
                buffer: buffer,
                capturedUptime: capturedUptime
            )
            if case .dropped(_) = localContinuation.yield(captured) {
                reportDroppedBuffer()
            }
        }
        tapInstalled = true

        audioTask = Task { [weak self] in
            for await captured in microphoneStream {
                guard !Task.isCancelled, let self else { break }
                do {
                    let converted = try converter.convert(captured.buffer, to: analyzerFormat)
                    let elapsed = max(0, captured.capturedUptime - timelineUptimeOrigin)
                    let desiredStart = CMTime(
                        seconds: elapsed,
                        preferredTimescale: 1_000_000_000
                    )
                    // Preserve real host-time gaps, but never overlap a preceding input.
                    let bufferStartTime = CMTimeCompare(
                        desiredStart,
                        lastAnalyzerInputEndTime
                    ) >= 0 ? desiredStart : lastAnalyzerInputEndTime
                    analyzerInput?.yield(
                        AnalyzerInput(
                            buffer: converted,
                            bufferStartTime: bufferStartTime
                        )
                    )
                    let sampleRate = CMTimeScale(converted.format.sampleRate.rounded())
                    if sampleRate > 0 {
                        let duration = CMTime(
                            value: CMTimeValue(converted.frameLength),
                            timescale: sampleRate
                        )
                        lastAnalyzerInputEndTime = CMTimeAdd(bufferStartTime, duration)
                    }
                } catch {
                    handlers.failure(error)
                    break
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func registerForAudioEvents() {
        let center = NotificationCenter.default

        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] notification in
                self?.handleInterruption(notification)
            }
        )

        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] notification in
                self?.handleRouteChange(notification)
            }
        )

        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] _ in
                self?.handlers.event(.mediaServicesReset)
            }
        )
    }

    private func unregisterAudioEvents() {
        let center = NotificationCenter.default
        observerTokens.forEach(center.removeObserver)
        observerTokens.removeAll()
    }

    private func handleInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            handlers.event(.interruptionBegan)
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            handlers.event(.interruptionEnded(shouldResume: shouldResume))
            guard shouldResume else { return }

            do {
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                if !audioEngine.isRunning {
                    try audioEngine.start()
                }
            } catch {
                handlers.failure(error)
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        let description: String
        switch reason {
        case .newDeviceAvailable: description = "Ny ljudenhet anslöts"
        case .oldDeviceUnavailable: description = "En ljudenhet kopplades bort"
        case .categoryChange: description = "Ljudkategorin ändrades"
        case .override: description = "Ljudvägen åsidosattes"
        case .wakeFromSleep: description = "Telefonen vaknade"
        case .noSuitableRouteForCategory: description = "Ingen passande ljudväg"
        case .routeConfigurationChange: description = "Ljudvägen konfigurerades om"
        case .unknown, .none: description = "Okänd ändring av ljudväg"
        @unknown default: description = "Ny typ av ändring av ljudväg"
        }
        handlers.event(.routeChanged(description))
    }

    private func reportDroppedBuffer() {
        let count = dropCountLock.withLock {
            droppedBufferCount += 1
            return droppedBufferCount
        }
        if count == 1 || count.isMultiple(of: 10) {
            handlers.event(.audioBuffersDropped(count))
        }
    }

}
