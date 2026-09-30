import AVFoundation
import Foundation

struct CapturedPCMBuffer: @unchecked Sendable {
    // This buffer is copied in the tap and is owned exclusively by the stream consumer.
    let buffer: AVAudioPCMBuffer
    let uptime: TimeInterval
}

/// All engine/session mutations occur on queue; the realtime tap only copies and yields.
final class MicrophoneCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.mio.assistant.capture")
    private var engine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []
    private var tapInstalled = false
    private var active = false
    private var interrupted = false
    private var stopped = false
    private var awaitingResume = false
    private var lastBuffer: TimeInterval = 0
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

    func checkAfterForeground() {
        queue.async { [self] in
            guard active, !stopped else { return }
            if interrupted || !engine.isRunning || ProcessInfo.processInfo.systemUptime - lastBufferUptime > 5 {
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
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MioError.invalidAudioStream }
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] source, time in
            guard let self,
                  let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength)
            else { return }
            copy.frameLength = source.frameLength
            let sourceList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
            let targetList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in sourceList.indices {
                guard let from = sourceList[index].mData, let to = targetList[index].mData else { return }
                memcpy(to, from, Int(sourceList[index].mDataByteSize))
                targetList[index].mDataByteSize = sourceList[index].mDataByteSize
            }
            let uptime = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime)
                : ProcessInfo.processInfo.systemUptime
            self.activityLock.withLock { self.lastBuffer = ProcessInfo.processInfo.systemUptime }
            self.output.yield(CapturedPCMBuffer(buffer: copy, uptime: uptime))
            self.queue.async { [weak self] in
                guard let self, self.active, !self.stopped, self.awaitingResume else { return }
                self.awaitingResume = false
                self.event(.interruptionEnded(shouldResume: true))
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
                self?.queue.async { [weak self] in self?.handle(notification) }
            })
        }
    }

    private func handle(_ notification: Notification) {
        guard active, !stopped else { return }
        switch notification.name {
        case AVAudioSession.interruptionNotification:
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                interrupted = true; awaitingResume = false
                tearDownEngine(); event(.interruptionBegan)
            } else {
                let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                interrupted = false
                guard AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) else {
                    event(.needsResume("Ljudavbrottet är slut. Tryck Fortsätt för att återstarta mikrofonen.")); return
                }
                recover()
            }
        case AVAudioSession.mediaServicesWereLostNotification:
            interrupted = true; tearDownEngine(); event(.interruptionBegan)
        case AVAudioSession.mediaServicesWereResetNotification:
            tearDownEngine(); engine = AVAudioEngine()
            active = false
            event(.mediaServicesReset)
        case AVAudioSession.routeChangeNotification:
            let raw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            // Our own setCategory also emits a route notification; never restart for that.
            guard reason != .categoryChange, !interrupted else { return }
            event(.routeChanged("Ljudvägen ändrades. Mio anpassar mikrofonens format."))
            recover()
        case NSNotification.Name.AVAudioEngineConfigurationChange:
            guard let changed = notification.object as? AVAudioEngine, changed === engine, !interrupted else { return }
            recover()
        default: break
        }
    }

    private func recover() {
        do { awaitingResume = true; try rebuild() }
        catch {
            awaitingResume = false
            event(.needsResume("Mikrofonen kunde inte återstartas. Tryck Fortsätt när ljudvägen är tillgänglig."))
        }
    }
}
