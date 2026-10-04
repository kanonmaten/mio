import Foundation
#if canImport(AVFoundation)
import AVFoundation
import Network
import UIKit
#endif

protocol AudioCapturing: AnyObject, Sendable {
    func start() async throws
    func stop() async
    var lastBufferUptime: TimeInterval { get }
    var droppedBufferCount: Int { get }
    func checkAfterForeground()
}

extension AudioCapturing { var droppedBufferCount: Int { 0 } }

protocol TranscriptionTransport: Sendable {
    func health() async throws -> TranscriptionHealth
    /// Starts transport synchronously; its waiting task must not capture application PCM.
    func startTranscription(_ chunk: AudioChunk) -> Task<TranscriptionReply, Error>
    func cancel()
}

typealias AudioCaptureFactory = @Sendable (AsyncStream<CapturedPCMBuffer>.Continuation,
    @escaping @Sendable (PipelineEvent) -> Void) -> any AudioCapturing

/// One user-authorized capture epoch. Audio expiry remains supervised during graceful drain.
actor LiveTranscriptionPipeline: MioCapturePipeline {
    struct Handlers: Sendable {
        let result: @Sendable (AudioChunk, TranscriptionReply, [TranscriptionWord]) async -> Void
        let status: @Sendable (String) -> Void
        let event: @Sendable (PipelineEvent) async -> Void
        let failure: @Sendable (Error) async -> Void
        var diagnostic: @Sendable (STTDiagnostic) async -> Void = { _ in }
    }
    typealias StartDetails = CaptureStartDetails
    private let handlers: Handlers
    private let client: any TranscriptionTransport
    private let clock: AudioPipelineClock
    private let captureFactory: AudioCaptureFactory
    private let permission: @Sendable () async -> Bool
    private let isActive: @Sendable () async -> Bool
    private let converter = BufferConverter()
    private var assembler: AudioChunkAssembler
    private var timeline = AudioCaptureTimeline()
    private var capture: (any AudioCapturing)?
    private var captureTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var expiryGeneration = 0
    #if canImport(Network)
    private var pathMonitor: NWPathMonitor?
    #endif
    private var pending: [AudioChunk] = []
    private var inFlight: AudioChunk?
    private var request: Task<TranscriptionReply, Error>?
    private var stopping = false
    private var discardRequested = false
    private var stopped = false
    private var draining = false
    private var retryAt: TimeInterval = 0
    private var failures = 0
    private var lastAudioEnd: TimeInterval?
    private var convertedOrigin: TimeInterval?
    private var convertedSamples = 0
    private var conversionValidity: AudioTimingValidity = .estimated
    private var conversionEpoch = UUID()
    private var observedCaptureDrops = 0
    private var expiredCaptureEnd: TimeInterval?
    private struct ConversionDiagnosticFormat: Equatable {
        let sampleRate: Double
        let channels: Int
        let format: UInt
        let timingValidity: AudioTimingValidity
    }
    private var diagnosticFormat: ConversionDiagnosticFormat?
    private var conversionDiagnosticUptime: TimeInterval?
    private var interruptionStart: Date?
    private var wallOrigin: Date
    private var uptimeOrigin: TimeInterval

    #if canImport(AVFoundation)
    init(connection: TranscriptionConnection, sessionID: UUID, handlers: Handlers) {
        self.client = TranscriptionClient(connection: connection)
        self.assembler = AudioChunkAssembler(sessionID: sessionID)
        self.handlers = handlers
        self.clock = AudioPipelineClock()
        self.captureFactory = { MicrophoneCapture(output: $0, event: $1) }
        self.permission = { await SpeechCapabilityService.requestMicrophonePermission() }
        self.isActive = { await MainActor.run { UIApplication.shared.applicationState == .active } }
        self.wallOrigin = .now; self.uptimeOrigin = ProcessInfo.processInfo.systemUptime
    }
    #endif

    init(sessionID: UUID, handlers: Handlers, transport: any TranscriptionTransport,
         clock: AudioPipelineClock = .init(), captureFactory: @escaping AudioCaptureFactory,
         permission: @escaping @Sendable () async -> Bool = { true },
         isActive: @escaping @Sendable () async -> Bool = { true }) {
        self.client = transport; self.clock = clock; self.captureFactory = captureFactory
        self.permission = permission; self.isActive = isActive
        self.assembler = AudioChunkAssembler(sessionID: sessionID); self.handlers = handlers
        self.wallOrigin = clock.date(); self.uptimeOrigin = clock.uptime()
    }

    func start() async throws -> StartDetails {
        do {
            guard await permission() else { throw MioError.microphoneDenied }
            try Task.checkCancellation()
            guard !stopping else { throw CancellationError() }
            await handlers.event(.connection(.connecting, nil))
            let health = try await client.health()
            try Task.checkCancellation()
            guard !stopping else { throw CancellationError() }
            await handlers.event(.connection(.connected, health.metadata))
            try Task.checkCancellation()
            guard !stopping, await isActive() else { throw MioError.invalidAudioStream }
            let (stream, continuation) = AsyncStream<CapturedPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(32))
            let microphone = captureFactory(continuation) { [weak self] event in
                Task { await self?.receive(event) }
            }
            capture = microphone
            wallOrigin = clock.date(); uptimeOrigin = clock.uptime()
            captureTask = Task { [weak self] in
                for await buffer in stream {
                    guard !Task.isCancelled, let self else { break }
                    await self.ingest(buffer)
                }
            }
            try await microphone.start()
            for _ in 0..<40 {
                try Task.checkCancellation()
                guard !stopping else { throw CancellationError() }
                if microphone.lastBufferUptime > 0 { break }
                try await clock.sleep(0.1)
            }
            guard microphone.lastBufferUptime > 0 else { throw MioError.invalidAudioStream }
            startMonitoring()
            return StartDetails(health: health)
        } catch { await stop(discard: true); throw error }
    }

    func foreground() {
        guard !stopping else { return }
        retryAt = 0; capture?.checkAfterForeground(); startWorker()
    }

    func stop(discard: Bool = false) async {
        if discard {
            discardRequested = true
            let gaps = releaseAllAudio(reason: "Väntande transkription avbröts.")
            emit(gaps)
        }
        if stopped { return }
        if stopping {
            while !stopped { try? await clock.sleep(0.02); await Task.yield() }
            return
        }
        stopping = true
        let drainDeadline = clock.uptime() + 15
        #if canImport(Network)
        pathMonitor?.cancel(); pathMonitor = nil
        #endif
        monitorTask?.cancel(); monitorTask = nil
        await capture?.stop()
        await captureTask?.value
        captureTask = nil; capture = nil
        if !discardRequested { finishEpoch() }
        if !discardRequested {
            draining = true; retryAt = 0
            emit(expireAudioNow()); scheduleExpiry(); startWorker()
            while (!pending.isEmpty || inFlight != nil), !discardRequested, clock.uptime() < drainDeadline {
                let next = min(drainDeadline, earliestExpiry ?? drainDeadline)
                try? await clock.sleep(min(0.1, max(0, next - clock.uptime())))
                emit(expireAudioNow())
                await Task.yield()
            }
        }
        draining = false; discardRequested = true
        // Release every application-owned PCM reference before diagnostic/UI suspension.
        var gaps = releaseAllAudio(reason: "Ljuddelen hann inte transkriberas före avslut.")
        if let start = interruptionStart {
            gaps.append(CaptureGap(startedAt: start, endedAt: clock.date(), reason: "Mikrofonen var avbruten."))
            interruptionStart = nil
        }
        stopped = true
        for gap in gaps { await handlers.event(.captureGap(gap)) }
    }

    /// Contains no suspension while native buffers/converted PCM are in scope.
    private func ingest(_ captured: CapturedPCMBuffer) {
        guard !stopped, !discardRequested else { return }
        do {
            guard captured.stamp.sampleRate.isFinite, captured.stamp.sampleRate > 0,
                  captured.stamp.frames > 0, captured.stamp.callbackUptime.isFinite,
                  captured.stamp.callbackUptime >= 0 else { throw MioError.invalidAudioStream }
            let timing = timeline.resolve(captured.stamp)
            let date = wallOrigin.addingTimeInterval(timing.uptime - uptimeOrigin)
            let duration = Double(captured.stamp.frames) / captured.stamp.sampleRate
            if min(captured.stamp.callbackUptime, timing.uptime) + 60 <= clock.uptime() {
                var gaps = expireAudioNow()
                if let retained = assembler.retainedGap { gaps.append(retained) }
                // A queued tap can survive process suspension. Release the conversion
                // epoch before callbacks and never allocate converted PCM for expired input.
                assembler.discard(); converter.reset(); convertedOrigin = nil; convertedSamples = 0
                timeline.reset(); lastAudioEnd = nil
                expiredCaptureEnd = max(expiredCaptureEnd ?? 0, timing.uptime + duration)
                gaps.append(CaptureGap(startedAt: date, endedAt: date.addingTimeInterval(duration),
                    reason: "Köat ljud hann löpa ut före bearbetning."))
                scheduleExpiry(); emit(gaps)
                diagnose(.init(kind: .expired, sampleRate: captured.stamp.sampleRate,
                               channels: captured.channelCount, frames: captured.stamp.frames,
                               duration: duration, timingValidity: timing.validity, category: "audio_expired"))
                return
            }
            var gaps: [CaptureGap] = []
            if let end = expiredCaptureEnd, timing.uptime > end {
                gaps.append(CaptureGap(startedAt: wallOrigin.addingTimeInterval(end - uptimeOrigin),
                    endedAt: date, reason: "Ljud saknas efter att köat ljud löpte ut."))
            }
            expiredCaptureEnd = nil
            if timing.discontinuity {
                finishEpoch()
                if let end = lastAudioEnd {
                    let endedAt = max(date, wallOrigin.addingTimeInterval(end - uptimeOrigin + timing.missingDuration))
                    gaps.append(CaptureGap(startedAt: wallOrigin.addingTimeInterval(end - uptimeOrigin),
                                           endedAt: endedAt, reason: "Ljud saknas efter avbrott eller tappade mikrofonbuffertar."))
                }
                interruptionStart = nil
            }
            if let interruption = interruptionStart {
                gaps.append(CaptureGap(startedAt: interruption, endedAt: max(interruption, date), reason: "Mikrofonen var avbruten."))
                interruptionStart = nil
            }
            if convertedOrigin == nil {
                convertedOrigin = timing.uptime; convertedSamples = 0
            }
            conversionValidity = timing.validity; conversionEpoch = captured.stamp.epoch
            let pcm = try converter.transcriptionPCM(captured.buffer)
            appendConverted(pcm)
            lastAudioEnd = timing.uptime + Double(captured.stamp.frames) / captured.stamp.sampleRate
            gaps += expireAudioNow()
            if let expiry = assembler.expiresAt { convertedOrigin = expiry - 60; convertedSamples = assembler.retainedSamples }
            scheduleExpiry(); startWorker(); emit(gaps)
            let format = ConversionDiagnosticFormat(sampleRate: captured.stamp.sampleRate,
                channels: captured.channelCount, format: captured.stamp.format, timingValidity: timing.validity)
            let now = clock.uptime()
            // Persisting every tap creates unnecessary disk work. Report actual format/
            // timing changes and otherwise sample conversion diagnostics once per minute.
            if format != diagnosticFormat || now - (conversionDiagnosticUptime ?? now) >= 60 {
                diagnosticFormat = format; conversionDiagnosticUptime = now
                diagnose(.init(kind: .conversion, sampleRate: captured.stamp.sampleRate,
                               channels: captured.channelCount, frames: captured.stamp.frames,
                               duration: Double(pcm.count / 2) / 16_000, timingValidity: timing.validity))
            }
            if timing.droppedBuffers > 0 {
                diagnose(.init(kind: .droppedBuffer, duration: timing.missingDuration,
                               timingValidity: timing.validity, count: timing.droppedBuffers, category: "stream_drop"))
            }
        } catch { emitFailure(error) }
    }

    private func appendConverted(_ pcm: Data) {
        guard !pcm.isEmpty, let origin = convertedOrigin else { return }
        let uptime = origin + Double(convertedSamples) / 16_000
        pending += assembler.append(pcm, at: wallOrigin.addingTimeInterval(uptime - uptimeOrigin), uptime: uptime,
                                    timingValidity: conversionValidity, captureEpoch: conversionEpoch)
        convertedSamples += pcm.count / 2
    }
    private func finishEpoch() {
        do { appendConverted(try converter.finishTranscriptionPCM()) }
        catch { emitFailure(error) }
        if let last = assembler.finish() { pending.append(last) }
        convertedOrigin = nil; convertedSamples = 0; converter.reset()
    }

    private func receive(_ event: PipelineEvent) {
        guard !stopping else { return }
        if case .interruptionBegan = event {
            interruptionStart = clock.date(); finishEpoch(); timeline.reset(); startWorker()
            scheduleExpiry()
        }
        Task { await handlers.event(event) }
    }

    private func startMonitoring() {
        #if canImport(Network)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { Task { await self?.networkChanged() } }
        }
        monitor.start(queue: DispatchQueue(label: "app.mio.assistant.network")); pathMonitor = monitor
        #endif
        monitorTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(1) } catch { break }
                guard let self else { break }
                await self.tick()
            }
        }
    }
    private func networkChanged() { retryAt = 0; startWorker() }
    private func tick() {
        emit(expireAudioNow()); scheduleExpiry(); startWorker()
        if let capture, capture.droppedBufferCount > observedCaptureDrops {
            let count = capture.droppedBufferCount - observedCaptureDrops
            observedCaptureDrops = capture.droppedBufferCount
            diagnose(.init(kind: .droppedBuffer, count: count, category: "tap_buffering_newest"))
        }
        if interruptionStart == nil, let capture, capture.lastBufferUptime > 0,
           clock.uptime() - capture.lastBufferUptime > 5 {
            Task { await handlers.event(.needsResume("Ljudet har stannat. Tryck Fortsätt för att återstarta samma session.")) }
        }
    }
    private var earliestExpiry: TimeInterval? {
        (pending.map(\.expiresAt) + [inFlight?.expiresAt, assembler.expiresAt, convertedOrigin.map { $0 + 60 }].compactMap { $0 }).min()
    }
    private func scheduleExpiry() {
        expiryGeneration += 1
        let generation = expiryGeneration
        expiryTask?.cancel(); expiryTask = nil
        guard !stopped, let deadline = earliestExpiry else { return }
        expiryTask = Task { [weak self, clock] in
            do { try await clock.sleep(max(0, deadline - clock.uptime())) } catch { return }
            guard !Task.isCancelled, let self else { return }
            await self.expiryReached(generation)
        }
    }
    private func expiryReached(_ generation: Int) {
        guard generation == expiryGeneration, !stopped else { return }
        let gaps = expireAudioNow()
        scheduleExpiry(); startWorker(); emit(gaps)
    }
    private func expireAudioNow() -> [CaptureGap] {
        let now = clock.uptime()
        var gaps: [CaptureGap] = []
        if let expiry = [assembler.expiresAt, convertedOrigin.map { $0 + 60 }].compactMap({ $0 }).min(), expiry <= now {
            if let gap = assembler.retainedGap { gaps.append(gap) }
            assembler.discard(); converter.reset(); convertedOrigin = nil; convertedSamples = 0
        }
        pending.removeAll { chunk in
            guard chunk.expiresAt <= now else { return false }
            gaps.append(loss(chunk, reason: "Serveravbrott: ljudets 60 sekunder i minnet löpte ut.")); return true
        }
        if let chunk = inFlight, chunk.expiresAt <= now {
            gaps.append(loss(chunk, reason: "Serveravbrott: ljudets 60 sekunder i minnet löpte ut."))
            request?.cancel(); request = nil; inFlight = nil
        }
        for _ in gaps { diagnose(.init(kind: .expired, category: "audio_expired")) }
        return gaps
    }
    private func releaseAllAudio(reason: String) -> [CaptureGap] {
        var gaps = pending.map { loss($0, reason: reason) }
        if let chunk = inFlight { gaps.append(loss(chunk, reason: reason)) }
        if let gap = assembler.retainedGap { gaps.append(.init(startedAt: gap.startedAt, endedAt: gap.endedAt, reason: reason)) }
        request?.cancel(); worker?.cancel(); client.cancel()
        request = nil; worker = nil; inFlight = nil; pending.removeAll(); assembler.discard(); converter.reset(); convertedOrigin = nil; convertedSamples = 0
        expiryGeneration += 1; expiryTask?.cancel(); expiryTask = nil
        return gaps
    }
    private func loss(_ chunk: AudioChunk, reason: String) -> CaptureGap {
        CaptureGap(startedAt: chunk.startedAt, endedAt: chunk.endedAt, reason: reason)
    }
    private func emit(_ gaps: [CaptureGap]) {
        guard !gaps.isEmpty else { return }
        Task { for gap in gaps { await handlers.event(.captureGap(gap)) } }
    }
    private func diagnose(_ diagnostic: STTDiagnostic) { Task { await handlers.diagnostic(diagnostic) } }
    private func emitFailure(_ error: Error) {
        diagnose(.init(kind: .failure, category: "audio_conversion"))
        Task { await handlers.failure(error) }
    }
    private func startWorker() {
        guard worker == nil, !stopped, (!stopping || draining), !discardRequested, !pending.isEmpty else { return }
        worker = Task { [weak self] in await self?.sendPending() }
    }
    private func beginNextRequest() -> UUID {
        inFlight = pending.removeFirst()
        request = client.startTranscription(inFlight!)
        scheduleExpiry()
        return inFlight!.id
    }
    private func claimReply(_ reply: TranscriptionReply, id: UUID) throws -> (AudioChunk, [TranscriptionWord])? {
        guard let chunk = inFlight, chunk.id == id, chunk.expiresAt > clock.uptime() else { return nil }
        let words = try reply.validatedWords(for: chunk)
        let released = AudioChunk(id: chunk.id, sessionID: chunk.sessionID, sequence: chunk.sequence,
            startSample: chunk.startSample, origin: chunk.origin, capturedUptime: chunk.capturedUptime,
            coreStart: chunk.coreStart, coreEnd: chunk.coreEnd, pcm: Data(),
            timingValidity: chunk.timingValidity, captureEpoch: chunk.captureEpoch)
        inFlight = nil; request = nil; failures = 0; scheduleExpiry()
        return (released, words)
    }
    private func sendPending() async {
        defer { worker = nil; startWorker() }
        while !Task.isCancelled, !discardRequested, !stopped, (!stopping || draining) {
            emit(expireAudioNow()); scheduleExpiry()
            guard !pending.isEmpty else { return }
            if retryAt > clock.uptime() {
                do { try await clock.sleep(min(0.25, retryAt - clock.uptime())) } catch { return }
                continue
            }
            let id = beginNextRequest()
            guard let task = request else { return }
            do {
                let reply = try await task.value
                guard !discardRequested, !stopped, !Task.isCancelled else { return }
                emit(expireAudioNow())
                if let (chunk, words) = try claimReply(reply, id: id) {
                    diagnose(.init(kind: .result, chunkID: id, sequence: chunk.sequence,
                                   duration: chunk.endedAt.timeIntervalSince(chunk.startedAt), timingValidity: chunk.timingValidity))
                    await handlers.result(chunk, reply, words)
                    await handlers.event(.connection(.connected, reply.metadata))
                }
            } catch {
                guard !discardRequested, !stopped, !Task.isCancelled else { return }
                emit(expireAudioNow())
                guard inFlight?.id == id else { continue }
                let retryable = (error as? TranscriptionError)?.retryDelay != nil || error is URLError
                if retryable {
                    pending.insert(inFlight!, at: 0); inFlight = nil; request = nil
                    failures = min(failures + 1, 5)
                    let delay = max((error as? TranscriptionError)?.retryDelay ?? 0, min(30, pow(2, Double(failures))))
                    retryAt = clock.uptime() + delay; scheduleExpiry()
                    diagnose(.init(kind: .retry, chunkID: id, count: failures, category: "transport_retry"))
                    await handlers.event(.connection(.offline, nil))
                } else {
                    let gap = loss(inFlight!, reason: "Servern avvisade ljuddelen.")
                    inFlight = nil; request = nil; scheduleExpiry()
                    diagnose(.init(kind: .failure, chunkID: id, category: "response_rejected"))
                    await handlers.event(.captureGap(gap))
                    await handlers.event(.connection(.actionRequired, nil)); await handlers.failure(error)
                    return
                }
            }
        }
    }
}
