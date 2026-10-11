import AVFoundation
import Foundation

struct CapturedPCMBuffer: @unchecked Sendable {
    // This buffer is copied in the tap and is owned exclusively by the stream consumer.
    let buffer: AVAudioPCMBuffer
    let stamp: AudioCaptureStamp
    var channelCount: Int { Int(buffer.format.channelCount) }
}

private enum CaptureNotification: Sendable {
    case interruption(type: UInt?, options: UInt?)
    case servicesLost
    case servicesReset
    case routeChanged(reason: UInt?)
    case engineConfigurationChanged(engineID: ObjectIdentifier)

    init?(_ notification: Notification) {
        switch notification.name {
        case AVAudioSession.interruptionNotification:
            self = .interruption(
                type: notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                options: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            )
        case AVAudioSession.mediaServicesWereLostNotification:
            self = .servicesLost
        case AVAudioSession.mediaServicesWereResetNotification:
            self = .servicesReset
        case AVAudioSession.routeChangeNotification:
            self = .routeChanged(reason: notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
        case NSNotification.Name.AVAudioEngineConfigurationChange:
            guard let changed = notification.object as? AVAudioEngine else { return nil }
            self = .engineConfigurationChanged(engineID: ObjectIdentifier(changed))
        default:
            return nil
        }
    }
}

/// All engine/session mutations occur on queue; the realtime tap only copies and yields.
final class MicrophoneCapture: AudioCapturing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.mio.assistant.capture")
    private var engine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []
    private var tapInstalled = false
    private var active = false
    private var interrupted = false
    /// An automatic restart was refused (typically in the background); foreground retries it.
    private var restartPending = false
    private var restartUptimes: [TimeInterval] = []
    /// Invalidates a delayed retry once a newer restart, interruption or stop happened.
    private var restartGeneration = 0
    private var stopped = false
    private var lastBuffer: TimeInterval = 0
    private var droppedBuffers = 0
    private var bufferSequence: UInt64 = 0
    private let activityLock = NSLock()
    private let output: AsyncStream<CapturedPCMBuffer>.Continuation
    private let event: @Sendable (PipelineEvent) -> Void

    init(output: AsyncStream<CapturedPCMBuffer>.Continuation, event: @escaping @Sendable (PipelineEvent) -> Void) {
        self.output = output; self.event = event
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard !stopped else { throw CancellationError() }
                    active = true
                    registerObservers()
                    try rebuild()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stopped = true; active = false
                tearDownEngine()
                observers.forEach(NotificationCenter.default.removeObserver)
                observers.removeAll()
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                output.finish()
                continuation.resume()
            }
        }
    }

    var lastBufferUptime: TimeInterval { activityLock.withLock { lastBuffer } }
    var droppedBufferCount: Int { activityLock.withLock { droppedBuffers } }

    func checkAfterForeground() {
        queue.async { [self] in
            guard active, !stopped else { return }
            if interrupted || restartPending || !engine.isRunning {
                // Foreground is when iOS reliably allows activation again, and iOS does not
                // guarantee an .ended notification for every interruption.
                interrupted = false; restartPending = false; restartGeneration += 1
                do {
                    try rebuild()
                    event(.interruptionEnded(shouldResume: true))
                } catch {
                    tearDownEngine()
                    event(.needsResume("Mikrofonen kunde inte startas igen. Tryck Fortsätt när ljudet är ledigt."))
                }
            } else if ProcessInfo.processInfo.systemUptime - lastBufferUptime > 5 {
                event(.needsResume("Mikrofonen behöver återstartas. Tryck Fortsätt för att fortsätta samma session."))
            }
        }
    }

    private func tearDownEngine() {
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
    }

    private func rebuild() throws {
        guard active, !stopped, !interrupted else { return }
        tearDownEngine()
        engine = AVAudioEngine()
        try session.setCategory(.record, mode: .measurement)
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        // Apple: set data source and polar pattern only after category, mode and activation.
        preferOmnidirectionalBuiltInMicrophone()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MioError.invalidAudioStream }
        let epoch = UUID()
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] source, time in
            guard let self else { return }
            let callback = ProcessInfo.processInfo.systemUptime
            // Claim the sequence before copying: a failed copy must surface downstream
            // as a sequence gap instead of silently compressing the timeline.
            let sequence = self.activityLock.withLock {
                self.lastBuffer = callback
                self.bufferSequence &+= 1
                return self.bufferSequence
            }
            guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return }
            copy.frameLength = source.frameLength
            let sourceList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
            let targetList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in sourceList.indices {
                guard let from = sourceList[index].mData, let to = targetList[index].mData else { return }
                memcpy(to, from, Int(sourceList[index].mDataByteSize))
                targetList[index].mDataByteSize = sourceList[index].mDataByteSize
            }
            let stamp = AudioCaptureStamp(epoch: epoch, sequence: sequence,
                hostUptime: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil,
                sampleTime: time.isSampleTimeValid ? time.sampleTime : nil,
                sampleRate: source.format.sampleRate, frames: Int(source.frameLength), callbackUptime: callback,
                channels: Int(source.format.channelCount), format: source.format.commonFormat.rawValue)
            switch self.output.yield(CapturedPCMBuffer(buffer: copy, stamp: stamp)) {
            case .dropped:
                self.activityLock.withLock { self.droppedBuffers += 1 }
            case .terminated: return
            case .enqueued: break
            @unknown default: break
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    private func registerObservers() {
        let center = NotificationCenter.default
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification,
                     NSNotification.Name.AVAudioEngineConfigurationChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let captureNotification = CaptureNotification(notification) else { return }
                self?.queue.async { [weak self] in self?.handle(captureNotification) }
            })
        }
    }

    private func handle(_ notification: CaptureNotification) {
        guard active, !stopped else { return }
        switch notification {
        case let .interruption(rawType, _):
            guard let raw = rawType, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                interrupted = true; restartPending = false; restartGeneration += 1
                tearDownEngine(); event(.interruptionBegan)
            } else {
                // User decision 2026-10-11: listening resumes after calls and Siri whether or
                // not .shouldResume is set. That option is a playback hint; Mio only records,
                // and only while the user has neither paused nor stopped (this object exists).
                interrupted = false
                restartAutomatically()
            }
        case .servicesLost:
            interrupted = true; restartPending = false; restartGeneration += 1
            tearDownEngine(); event(.interruptionBegan)
        case .servicesReset:
            // Every audio object is invalid after a reset: start from a new engine and session setup.
            tearDownEngine(); engine = AVAudioEngine()
            interrupted = false
            restartAutomatically()
        case let .routeChanged(rawReason):
            let raw = rawReason ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            // Our own setCategory also emits a route notification; never restart for that.
            guard reason != .categoryChange, !interrupted else { return }
            // A running engine adopts the new route itself; a format change stops it and
            // arrives as an engine configuration change.
            guard !engine.isRunning || restartPending else {
                event(.routeChanged("Ljudvägen ändrades; mikrofonen fortsätter.")); return
            }
            event(.routeChanged("Ljudvägen ändrades. Mio startar om mikrofonen."))
            restartAutomatically()
        case let .engineConfigurationChanged(engineID):
            guard engineID == ObjectIdentifier(engine), !interrupted else { return }
            restartAutomatically()
        }
    }

    private func restartAutomatically() {
        let decision = MioCaptureResumePolicy.decision(userWantsListening: active && !stopped,
            interruptionOngoing: interrupted, restartFailed: false, appIsActive: true)
        guard decision == .restart else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard MioCaptureResumePolicy.allowsAutomaticRestart(previous: restartUptimes, now: now) else {
            tearDownEngine(); restartPending = false
            event(.needsResume("Mikrofonen startades om flera gånger i rad. Tryck Fortsätt för att försöka igen."))
            return
        }
        restartUptimes = restartUptimes.filter { now - $0 < 60 } + [now]
        attemptRestart(retries: 1)
    }

    private func attemptRestart(retries: Int) {
        restartGeneration += 1
        let generation = restartGeneration
        do {
            try rebuild()
            guard engine.isRunning else { return }
            restartPending = false
            event(.interruptionEnded(shouldResume: true))
        } catch {
            tearDownEngine()
            if retries > 0 {
                // The interrupting audio may still be deactivating; retry once shortly.
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, generation == self.restartGeneration, self.active, !self.stopped,
                          !self.interrupted else { return }
                    self.attemptRestart(retries: retries - 1)
                }
                return
            }
            // Typically iOS refusing a background start. The application decides whether to
            // notify; the next foreground check retries once more.
            restartPending = true
            event(.restartFailed("iOS tillät inte att mikrofonen startade igen."))
        }
    }

    /// Prefers the built-in microphone's omnidirectional pattern so quieter, farther voices are
    /// not filtered out by a directional beam. Only when the route already uses the built-in
    /// microphone; unsupported devices, modes or failures silently keep the system choice.
    private func preferOmnidirectionalBuiltInMicrophone() {
        guard session.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }),
              let port = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
              let sources = port.dataSources else { return }
        let omni = AVAudioSession.PolarPattern.omnidirectional
        let supportsOmni = { (source: AVAudioSessionDataSourceDescription) in
            source.supportedPolarPatterns?.contains(omni) == true
        }
        let selected = port.selectedDataSource.flatMap { supportsOmni($0) ? $0 : nil }
        guard let source = selected ?? sources.first(where: supportsOmni) else {
            event(.routeChanged("Rundupptagning stöds inte av den inbyggda mikrofonen här; iOS val behålls."))
            return
        }
        // Each change reconfigures the route, so only request what differs.
        guard port.selectedDataSource?.dataSourceID != source.dataSourceID || source.selectedPolarPattern != omni else { return }
        do {
            if port.selectedDataSource?.dataSourceID != source.dataSourceID { try port.setPreferredDataSource(source) }
            if source.selectedPolarPattern != omni { try source.setPreferredPolarPattern(omni) }
            event(.routeChanged("Inbyggd mikrofon med rundupptagning begärd (\(source.dataSourceName))."))
        } catch {
            event(.routeChanged("Rundupptagning kunde inte väljas; iOS val behålls."))
        }
    }
}
