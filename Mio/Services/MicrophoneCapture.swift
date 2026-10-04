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
        let epoch = UUID()
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
            let callback = ProcessInfo.processInfo.systemUptime
            let sequence = self.activityLock.withLock {
                self.lastBuffer = callback
                self.bufferSequence &+= 1
                return self.bufferSequence
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
        case let .interruption(rawType, rawOptions):
            guard let raw = rawType, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                interrupted = true
                tearDownEngine(); event(.interruptionBegan)
            } else {
                let options = rawOptions ?? 0
                interrupted = false
                guard AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) else {
                    event(.needsResume("Ljudavbrottet är slut. Tryck Fortsätt för att återstarta mikrofonen.")); return
                }
                recover()
            }
        case .servicesLost:
            interrupted = true; tearDownEngine(); event(.interruptionBegan)
        case .servicesReset:
            tearDownEngine(); engine = AVAudioEngine()
            active = false
            event(.mediaServicesReset)
        case let .routeChanged(rawReason):
            let raw = rawReason ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            // Our own setCategory also emits a route notification; never restart for that.
            guard reason != .categoryChange, !interrupted else { return }
            event(.routeChanged("Ljudvägen ändrades. Tryck Fortsätt för att använda det nya mikrofonformatet."))
            recover()
        case let .engineConfigurationChanged(engineID):
            guard engineID == ObjectIdentifier(engine), !interrupted else { return }
            recover()
        }
    }

    private func recover() {
        // System resume hints do not authorize another microphone start.
        tearDownEngine()
        event(.needsResume("Mikrofonen behöver återstartas. Tryck Fortsätt när ljudvägen är tillgänglig."))
    }
}
