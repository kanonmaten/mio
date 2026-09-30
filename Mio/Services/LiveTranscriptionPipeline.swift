import AVFoundation
import Foundation
import Network
import UIKit

/// One user-authorized capture epoch. Audio and network failures have independent lifetimes.
actor LiveTranscriptionPipeline {
    struct Handlers: Sendable {
        let result: @Sendable (AudioChunk, TranscriptionReply, [TranscriptionWord]) async -> Void
        let status: @Sendable (String) -> Void
        let event: @Sendable (PipelineEvent) async -> Void
        let failure: @Sendable (Error) async -> Void
    }
    struct StartDetails: Sendable { let health: TranscriptionHealth }
    private let handlers: Handlers
    private let client: TranscriptionClient
    private let converter = BufferConverter()
    private var assembler: AudioChunkAssembler
    private var capture: MicrophoneCapture?
    private var captureTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var pending: [AudioChunk] = []
    private var inFlight: AudioChunk?
    private var request: Task<TranscriptionReply, Error>?
    private var discardedIDs: Set<UUID> = []
    private var stopping = false
    private var discardRequested = false
    private var stopped = false
    private var draining = false
    private var retryAt: TimeInterval = 0
    private var failures = 0
    private var lastAudioEnd: TimeInterval?
    private var interruptionStart: Date?
    private var wallOrigin = Date.now
    private var uptimeOrigin: TimeInterval = 0

    init(connection: TranscriptionConnection, sessionID: UUID, handlers: Handlers) {
        self.client = TranscriptionClient(connection: connection)
        self.assembler = AudioChunkAssembler(sessionID: sessionID)
        self.handlers = handlers
    }

    func start() async throws -> StartDetails {
        do {
            guard await SpeechCapabilityService.requestMicrophonePermission() else { throw MioError.microphoneDenied }
            try Task.checkCancellation()
            guard !stopping else { throw CancellationError() }
            await handlers.event(.connection(.connecting, nil))
            let health = try await client.health()
            try Task.checkCancellation()
            guard !stopping else { throw CancellationError() }
            await handlers.event(.connection(.connected, health.metadata))
            try Task.checkCancellation()
            guard !stopping else { throw CancellationError() }
            let (stream, continuation) = AsyncStream<CapturedPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(32))
            let microphone = MicrophoneCapture(output: continuation) { [weak self] event in
                Task { await self?.receive(event) }
            }
            capture = microphone
            wallOrigin = .now; uptimeOrigin = ProcessInfo.processInfo.systemUptime
            captureTask = Task { [weak self] in
                for await buffer in stream {
                    guard !Task.isCancelled, let self else { break }
                    await self.ingest(buffer)
                }
            }
            guard await MainActor.run(body: { UIApplication.shared.applicationState == .active }) else {
                throw MioError.invalidAudioStream
            }
            try Task.checkCancellation()
            guard !stopping else { throw CancellationError() }
            try await microphone.start()
            for _ in 0..<40 {
                try Task.checkCancellation()
                guard !stopping else { throw CancellationError() }
                if microphone.lastBufferUptime > 0 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard microphone.lastBufferUptime > 0 else { throw MioError.invalidAudioStream }
            startMonitoring()
            return StartDetails(health: health)
        } catch {
            await stop(discard: true)
            throw error
        }
    }

    func foreground() {
        guard !stopping else { return }
        retryAt = 0
        capture?.checkAfterForeground()
        startWorker()
    }

    func stop(discard: Bool = false) async {
        if discard { discardRequested = true; client.cancel(); request?.cancel(); worker?.cancel() }
        if stopped { return }
        if stopping {
            while !stopped { try? await Task.sleep(for: .milliseconds(20)); await Task.yield() }
            return
        }
        stopping = true
        pathMonitor?.cancel(); pathMonitor = nil
        monitorTask?.cancel(); monitorTask = nil
        await capture?.stop()
        await captureTask?.value
        captureTask = nil; capture = nil
        if let last = assembler.finish() { pending.append(last) }
        if !discardRequested {
            draining = true; retryAt = 0; startWorker()
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while (!pending.isEmpty || inFlight != nil), !discardRequested,
                  ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                await Task.yield()
            }
        }
        draining = false
        discardRequested = true
        worker?.cancel(); request?.cancel(); client.cancel()
        for chunk in pending { await gap(chunk, reason: "Ljuddelen hann inte transkriberas före avslut.") }
        if let inFlight, !discardedIDs.contains(inFlight.id) {
            await gap(inFlight, reason: "Väntande transkription avbröts.")
        }
        if let start = interruptionStart {
            await handlers.event(.captureGap(CaptureGap(startedAt: start, endedAt: .now, reason: "Mikrofonen var avbruten.")))
            interruptionStart = nil
        }
        pending.removeAll(); inFlight = nil; request = nil; worker = nil
        stopped = true
    }

    private func ingest(_ captured: CapturedPCMBuffer) async {
        guard !stopped, !discardRequested else { return }
        do {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                            channels: 1, interleaved: true) else { throw MioError.invalidAudioStream }
            let date = wallOrigin.addingTimeInterval(captured.uptime - uptimeOrigin)
            if let end = lastAudioEnd, captured.uptime - end > 0.25 {
                if let last = assembler.finish() { pending.append(last) }
                converter.reset()
                await handlers.event(.captureGap(CaptureGap(
                    startedAt: wallOrigin.addingTimeInterval(end - uptimeOrigin), endedAt: date,
                    reason: "Ljud saknas efter avbrott eller tappade mikrofonbuffertar.")))
                interruptionStart = nil
            }
            if let interruption = interruptionStart, date >= interruption {
                await handlers.event(.captureGap(CaptureGap(startedAt: interruption, endedAt: date,
                                                            reason: "Mikrofonen var avbruten.")))
                interruptionStart = nil
            }
            let buffer = try converter.convert(captured.buffer, to: format)
            guard let channel = buffer.int16ChannelData else { throw MioError.invalidAudioStream }
            let pcm = Data(bytes: channel[0], count: Int(buffer.frameLength) * 2)
            pending += assembler.append(pcm, at: date, uptime: captured.uptime)
            lastAudioEnd = captured.uptime + Double(captured.buffer.frameLength) / captured.buffer.format.sampleRate
            await expireAudio()
            startWorker()
        } catch { await handlers.failure(error) }
    }

    private func receive(_ event: PipelineEvent) async {
        guard !stopping else { return }
        switch event {
        case .interruptionBegan:
            interruptionStart = .now
            converter.reset()
            if let last = assembler.finish() { pending.append(last); startWorker() }
        default: break
        }
        await handlers.event(event)
    }

    private func startMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { Task { await self?.networkChanged() } }
        }
        monitor.start(queue: DispatchQueue(label: "app.mio.assistant.network"))
        pathMonitor = monitor
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                guard let self else { break }
                await self.tick()
            }
        }
    }

    private func networkChanged() { retryAt = 0; startWorker() }
    private func tick() async {
        await expireAudio(); startWorker()
        if interruptionStart == nil, let capture, capture.lastBufferUptime > 0,
           ProcessInfo.processInfo.systemUptime - capture.lastBufferUptime > 5 {
            await handlers.event(.needsResume("Ljudet har stannat. Tryck Fortsätt för att återstarta samma session."))
        }
    }
    private func expireAudio() async {
        let now = ProcessInfo.processInfo.systemUptime
        while let first = pending.first, first.expiresAt <= now {
            pending.removeFirst(); await gap(first, reason: "Serveravbrott: ljudets 60 sekunder i minnet löpte ut.")
        }
        if let chunk = inFlight, chunk.expiresAt <= now, !discardedIDs.contains(chunk.id) {
            discardedIDs.insert(chunk.id); request?.cancel()
            await gap(chunk, reason: "Serveravbrott: ljudets 60 sekunder i minnet löpte ut.")
        }
    }
    private func gap(_ chunk: AudioChunk, reason: String) async {
        await handlers.event(.captureGap(CaptureGap(startedAt: chunk.startedAt, endedAt: chunk.endedAt, reason: reason)))
    }
    private func startWorker() {
        guard worker == nil, !stopped, (!stopping || draining), !discardRequested, !pending.isEmpty else { return }
        worker = Task { [weak self] in await self?.sendPending() }
    }
    private func sendPending() async {
        defer { worker = nil }
        while !Task.isCancelled, !discardRequested, !stopped, (!stopping || draining) {
            await expireAudio()
            guard !pending.isEmpty else { return }
            let delay = retryAt - ProcessInfo.processInfo.systemUptime
            if delay > 0 {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                continue
            }
            let chunk = pending.removeFirst(); inFlight = chunk
            let task = Task { try await client.transcribe(chunk) }
            request = task
            do {
                let reply = try await task.value
                guard !discardRequested, !stopped, !Task.isCancelled else { return }
                await expireAudio()
                if !discardedIDs.contains(chunk.id), !discardRequested, !stopped {
                    let words = try reply.validatedWords(for: chunk)
                    // Claim the response before suspension so stop/expiry cannot also report it lost.
                    inFlight = nil; request = nil
                    await handlers.result(chunk, reply, words)
                    failures = 0
                    await handlers.event(.connection(.connected, reply.metadata))
                }
            } catch {
                guard !discardRequested, !stopped, !Task.isCancelled else { return }
                if !discardedIDs.contains(chunk.id) {
                    let retryable = (error as? TranscriptionError)?.retryDelay != nil || error is URLError
                    guard retryable else {
                        await gap(chunk, reason: "Servern avvisade ljuddelen.")
                        inFlight = nil; request = nil
                        await handlers.event(.connection(.actionRequired, nil))
                        await handlers.failure(error)
                        return
                    }
                    inFlight = nil; request = nil
                    pending.insert(chunk, at: 0)
                    failures = min(failures + 1, 5)
                    let delay = max((error as? TranscriptionError)?.retryDelay ?? 0,
                                    min(30, pow(2, Double(failures))) * Double.random(in: 0.8...1.0))
                    retryAt = ProcessInfo.processInfo.systemUptime + delay
                    await handlers.event(.connection(.offline, nil))
                }
            }
            discardedIDs.remove(chunk.id)
            inFlight = nil; request = nil
        }
    }
}
