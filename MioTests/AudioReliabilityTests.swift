import Foundation
import XCTest
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import Mio

final class AudioReliabilityTests: XCTestCase {
    func testRepeatedCaptureFormatDoesNotProduceDiagnosticPerTap() async throws {
        let epoch = UUID()
        let stamps: [AudioCaptureStamp] = (0..<21).map { (index: Int) -> AudioCaptureStamp in
            let hostTime = 10.0 + Double(index)
            let sampleTime = Int64(index * 16_000)
            return AudioCaptureStamp(epoch: epoch, sequence: UInt64(index + 1), hostUptime: hostTime,
                sampleTime: sampleTime, sampleRate: 16_000, frames: 16_000, callbackUptime: 32)
        }
        let fixture = AudioPipelineFixture(now: 32, capturedAt: 10, stamps: stamps)
        let pipeline = fixture.pipeline()
        _ = try await pipeline.start()
        await waitUntil { fixture.transport.requestCount == 1 }
        await settle()
        await pipeline.stop(discard: true)
        XCTAssertEqual(fixture.diagnostics.conversions.count, 1)
        XCTAssertEqual(fixture.diagnostics.conversions.first?.sampleRate, 16_000)
    }

    func testChangedCaptureFormatIsReportedWithoutRepeatedTapDiagnostics() async throws {
        let epoch = UUID()
        var stamps: [AudioCaptureStamp] = (0..<21).map { (index: Int) -> AudioCaptureStamp in
            let hostTime = 10.0 + Double(index)
            let sampleTime = Int64(index * 16_000)
            return AudioCaptureStamp(epoch: epoch, sequence: UInt64(index + 1), hostUptime: hostTime,
                sampleTime: sampleTime, sampleRate: 16_000, frames: 16_000, callbackUptime: 32)
        }
        stamps.append(.init(epoch: epoch, sequence: 22, hostUptime: 31, sampleTime: 0,
                            sampleRate: 48_000, frames: 48_000, callbackUptime: 32))
        let fixture = AudioPipelineFixture(now: 32, capturedAt: 10, stamps: stamps)
        let pipeline = fixture.pipeline()
        _ = try await pipeline.start()
        await waitUntil { fixture.diagnostics.conversions.contains { $0.sampleRate == 48_000 } }
        await settle()
        await pipeline.stop(discard: true)
        XCTAssertEqual(fixture.diagnostics.conversions.count, 2)
        XCTAssertEqual(fixture.diagnostics.conversions.compactMap(\.sampleRate).sorted(), [16_000, 48_000])
    }

    func testExpiredQueuedCaptureHasVisibleGapAndNeverReachesConversionOrTransport() async throws {
        let fixture = AudioPipelineFixture(now: 100, capturedAt: 1, callbackAt: 2)
        let pipeline = fixture.pipeline()
        _ = try await pipeline.start()
        await settle()
        await pipeline.stop(discard: true)
        await settle()
        XCTAssertEqual(fixture.events.gaps.count, 1)
        let gap = try XCTUnwrap(fixture.events.gaps.first)
        XCTAssertEqual(gap.startedAt, Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(gap.endedAt, Date(timeIntervalSince1970: 1_002))
        XCTAssertEqual(fixture.diagnostics.expired.count, 1)
        XCTAssertTrue(fixture.diagnostics.conversions.isEmpty)
        XCTAssertEqual(fixture.transport.requestCount, 0)
    }

    func testOldReliableSampleExpiresBeforeConversionEvenWhenCallbackIsRecent() async throws {
        let fixture = AudioPipelineFixture(now: 100, capturedAt: 1)
        let pipeline = fixture.pipeline()
        _ = try await pipeline.start()
        await settle()
        await pipeline.stop(discard: true)
        await settle()
        XCTAssertEqual(fixture.events.gaps.count, 1)
        XCTAssertTrue(fixture.diagnostics.conversions.isEmpty)
        XCTAssertEqual(fixture.transport.requestCount, 0)
    }

    func testFreshCaptureAfterExpiredQueueKeepsRecoveryIntervalVisible() async throws {
        let epoch = UUID()
        let stamps = [
            AudioCaptureStamp(epoch: epoch, sequence: 1, hostUptime: 1, sampleTime: 0,
                sampleRate: 16_000, frames: 16_000, callbackUptime: 2),
            AudioCaptureStamp(epoch: epoch, sequence: 2, hostUptime: 100, sampleTime: 16_000,
                sampleRate: 16_000, frames: 16_000, callbackUptime: 100)
        ]
        let fixture = AudioPipelineFixture(now: 100, capturedAt: 1, stamps: stamps)
        let pipeline = fixture.pipeline()
        _ = try await pipeline.start()
        await waitUntil { fixture.diagnostics.conversions.count == 1 }
        await settle()
        XCTAssertTrue(fixture.events.gaps.contains {
            $0.startedAt == Date(timeIntervalSince1970: 1_002) && $0.endedAt == Date(timeIntervalSince1970: 1_100)
        })
        XCTAssertEqual(fixture.diagnostics.expired.count, 1)
        await pipeline.stop(discard: true)
    }

    func testAssemblerPreservesFiftyMillisecondLossAndShortTail() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        var assembler = AudioChunkAssembler(sessionID: UUID())
        _ = assembler.append(Data(count: 32_000), at: date, uptime: 0)
        let preceding = assembler.append(Data(count: 3_200), at: date.addingTimeInterval(1.05), uptime: 1.05)
        XCTAssertEqual(preceding.count, 1)
        XCTAssertEqual(preceding.first?.endedAt, date.addingTimeInterval(1))
        let tail = try XCTUnwrap(assembler.finish())
        XCTAssertEqual(tail.startedAt, date.addingTimeInterval(1.05))
        XCTAssertEqual(tail.endedAt, date.addingTimeInterval(1.15))
        XCTAssertEqual(tail.sequence, 1)
    }

    func testAssemblerEarliestExpiryIncludesRetainedOverlapAndDiscardReleasesIt() {
        var assembler = AudioChunkAssembler(sessionID: UUID())
        _ = assembler.append(Data(count: 21 * 32_000), at: .now, uptime: 10)
        XCTAssertEqual(assembler.expiresAt, 89)
        XCTAssertEqual(assembler.retainedSamples, 2 * 16_000)
        assembler.discard()
        XCTAssertNil(assembler.expiresAt)
        XCTAssertEqual(assembler.retainedSamples, 0)
        XCTAssertNil(assembler.finish())
    }

    func testSampleAnchorSurvivesMissingHostTimeWithoutInventingAnAnchor() {
        let epoch = UUID()
        var timeline = AudioCaptureTimeline()
        _ = timeline.resolve(stamp(epoch: epoch, sequence: 0, sample: 0, host: 10))
        let anchored = timeline.resolve(stamp(epoch: epoch, sequence: 1, sample: 16_000, host: nil))
        XCTAssertEqual(anchored.uptime, 11)
        XCTAssertEqual(anchored.validity, .sampleTime)
        timeline.reset()
        let unanchored = timeline.resolve(stamp(epoch: epoch, sequence: 0, sample: 0, host: nil))
        XCTAssertEqual(unanchored.validity, .estimated)
        XCTAssertFalse(unanchored.validity.isReliable)
        let noSample = timeline.resolve(stamp(epoch: epoch, sequence: 1, sample: nil, host: nil))
        XCTAssertFalse(noSample.validity.isReliable)
    }

    func testSampleContinuityIgnoresHostJitterAndDetectsOneAndTwoLostTaps() {
        let epoch = UUID()
        var timeline = AudioCaptureTimeline()
        _ = timeline.resolve(stamp(epoch: epoch, sequence: 0, sample: 0, host: 10))
        let jitter = timeline.resolve(stamp(epoch: epoch, sequence: 1, sample: 16_000, host: 11.01))
        XCTAssertEqual(jitter.uptime, 11)
        XCTAssertFalse(jitter.discontinuity)
        let one = timeline.resolve(stamp(epoch: epoch, sequence: 3, sample: 48_000, host: 13))
        XCTAssertTrue(one.discontinuity)
        XCTAssertEqual(one.missingDuration, 1)
        XCTAssertEqual(one.droppedBuffers, 1)
        let two = timeline.resolve(stamp(epoch: epoch, sequence: 6, sample: 96_000, host: 16))
        XCTAssertEqual(two.missingDuration, 2)
        XCTAssertEqual(two.droppedBuffers, 2)
        let reset = timeline.resolve(stamp(epoch: UUID(), sequence: 7, sample: 0, host: 30))
        XCTAssertTrue(reset.discontinuity)
        XCTAssertEqual(reset.uptime, 30)
    }

    func testSourceSampleLossBelowQuarterSecondResetsContinuity() {
        let epoch = UUID()
        var timeline = AudioCaptureTimeline()
        _ = timeline.resolve(stamp(epoch: epoch, sequence: 0, sample: 0, host: 10))
        let loss = timeline.resolve(stamp(epoch: epoch, sequence: 1, sample: 16_800, host: 11.05))
        XCTAssertTrue(loss.discontinuity)
        XCTAssertEqual(loss.missingDuration, 0.05, accuracy: 0.000001)
        XCTAssertEqual(loss.droppedBuffers, 0)
    }

    func testTimingValidityIsCarriedIntoOwnedChunk() throws {
        var assembler = AudioChunkAssembler(sessionID: UUID())
        let epoch = UUID()
        _ = assembler.append(Data(count: 32_000), at: .now, uptime: 10,
                             timingValidity: .estimated, captureEpoch: epoch)
        let chunk = try XCTUnwrap(assembler.finish())
        XCTAssertEqual(chunk.timingValidity, .estimated)
        XCTAssertEqual(chunk.captureEpoch, epoch)
    }

    func testGracefulStopExpiresOriginalAudioBeforeSlowGapCallbackCompletes() async throws {
        let fixture = AudioPipelineFixture(now: 59, capturedAt: 1, slowGaps: true)
        let pipeline = fixture.pipeline()
        _ = try await pipeline.start()
        let stop = Task { await pipeline.stop() }
        await settle()
        XCTAssertEqual(fixture.transport.requestCount, 1)
        fixture.time.advance(to: 61)
        await settle()
        XCTAssertEqual(fixture.transport.cancelledCount, 1)
        XCTAssertEqual(fixture.results.count, 0)
        await stop.value
        XCTAssertEqual(fixture.events.gaps.count, 1)
        fixture.gapGate.open()
    }

    func testUnchunkedAssemblerExpiresWhileCaptureIsStillActive() async throws {
        let fixture = AudioPipelineFixture(now: 59, capturedAt: 1)
        let pipeline = fixture.pipeline()
        _ = try await pipeline.start()
        await settle()
        fixture.time.advance(to: 61)
        await settle()
        await pipeline.stop()
        XCTAssertEqual(fixture.transport.requestCount, 0)
        XCTAssertEqual(fixture.events.gaps.count, 1)
    }

    func testGracefulDrainCancelsAtFifteenSecondsEvenWhenAudioIsFresh() async throws {
        let fixture = AudioPipelineFixture(now: 59, capturedAt: 59)
        let pipeline = fixture.pipeline()
        _ = try await pipeline.start()
        let stop = Task { await pipeline.stop() }
        await settle()
        fixture.time.advance(to: 74)
        await settle()
        await stop.value
        XCTAssertEqual(fixture.transport.cancelledCount, 1)
        XCTAssertEqual(fixture.events.gaps.count, 1)
    }

    func testRetryPreservesChunkIdentityAndOriginalExpiry() async throws {
        let fixture = AudioPipelineFixture(now: 30, capturedAt: 10, frames: 21 * 16_000, retryOnce: true)
        let pipeline = fixture.pipeline()
        _ = try await pipeline.start()
        await waitUntil { fixture.events.offline }
        fixture.time.advance(to: 32)
        await settle()
        XCTAssertEqual(fixture.transport.identities.count, 2)
        XCTAssertEqual(fixture.transport.identities.first, fixture.transport.identities.last)
        XCTAssertEqual(fixture.transport.expiries, [70, 70])
        await pipeline.stop(discard: true)
        XCTAssertEqual(fixture.results.count, 0)
    }

    private func stamp(epoch: UUID, sequence: UInt64, sample: Int64?, host: Double?) -> AudioCaptureStamp {
        .init(epoch: epoch, sequence: sequence, hostUptime: host, sampleTime: sample,
              sampleRate: 16_000, frames: 16_000, callbackUptime: (host ?? 10) + 1)
    }
}

private func settle() async { for _ in 0..<200 { await Task.yield() } }
private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
    XCTFail("Expected deterministic pipeline event did not arrive")
}
private final class AudioTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if isOpen { return true }
                continuations.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
    func open() {
        let waiting = lock.withLock { isOpen = true; let result = continuations; continuations.removeAll(); return result }
        waiting.forEach { $0.resume() }
    }
}

private final class AudioTestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Double
    private var sleepers: [UUID: (Double, CheckedContinuation<Void, Error>)] = [:]
    private var cancelled: Set<UUID> = []
    init(_ now: Double) { self.now = now }
    var uptime: Double { lock.withLock { now } }
    var clock: AudioPipelineClock {
        .init(uptime: { self.uptime }, date: { Date(timeIntervalSince1970: 1_000 + self.uptime) },
              sleep: { try await self.sleep($0) })
    }
    func sleep(_ seconds: Double) async throws {
        let id = UUID()
        let deadline = uptime + seconds
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let result: Result<Void, Error>? = lock.withLock {
                    if cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if now >= deadline { return .success(()) }
                    sleepers[id] = (deadline, continuation); return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>? = self.lock.withLock {
                if let sleeper = self.sleepers.removeValue(forKey: id) { return sleeper.1 }
                self.cancelled.insert(id); return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
    func advance(to value: Double) {
        let ready: [CheckedContinuation<Void, Error>] = lock.withLock {
            now = value
            let ids = sleepers.filter { $0.value.0 <= value }.map(\.key)
            return ids.compactMap { sleepers.removeValue(forKey: $0)?.1 }
        }
        ready.forEach { $0.resume() }
    }
}

private final class AudioTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CaptureGap] = []
    private var isOffline = false
    var offline: Bool { lock.withLock { isOffline } }
    var gaps: [CaptureGap] { lock.withLock { stored } }
    func receive(_ event: PipelineEvent) {
        if case let .captureGap(gap) = event { lock.withLock { stored.append(gap) } }
        if case .connection(.offline, _) = event { lock.withLock { isOffline = true } }
    }
}
private final class AudioTestResults: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var count: Int { lock.withLock { stored } }
    func receive() { lock.withLock { stored += 1 } }
}

private final class AudioTestDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [STTDiagnostic] = []
    var conversions: [STTDiagnostic] { lock.withLock { values.filter { $0.kind == .conversion } } }
    var expired: [STTDiagnostic] { lock.withLock { values.filter { $0.kind == .expired } } }
    func receive(_ diagnostic: STTDiagnostic) { lock.withLock { values.append(diagnostic) } }
}

private final class AudioTestTransport: TranscriptionTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let time: AudioTestTime
    private let retryOnce: Bool
    private var ids: [UUID] = []
    private var deadlines: [Double] = []
    private var cancelled = 0
    init(time: AudioTestTime, retryOnce: Bool) { self.time = time; self.retryOnce = retryOnce }
    var requestCount: Int { lock.withLock { ids.count } }
    var cancelledCount: Int { lock.withLock { cancelled } }
    var identities: [UUID] { lock.withLock { ids } }
    var expiries: [Double] { lock.withLock { deadlines } }
    func health() async throws -> TranscriptionHealth {
        .init(apiVersion: 1, serverVersion: "test", status: "ready",
              metadata: .init(model: "synthetic", revision: "test", backend: "fixture"),
              sampleRate: 16_000, channels: 1, encoding: "pcm_s16le_wav", maxSeconds: 24, maxBytes: 1_048_576)
    }
    func startTranscription(_ chunk: AudioChunk) -> Task<TranscriptionReply, Error> {
        let retry = lock.withLock {
            ids.append(chunk.id); deadlines.append(chunk.expiresAt)
            return retryOnce && ids.count == 1
        }
        return Task {
            if retry { throw URLError(.networkConnectionLost) }
            do { try await time.sleep(1_000) }
            catch { lock.withLock { cancelled += 1 }; throw error }
            throw CancellationError()
        }
    }
    func cancel() {}
}

private final class AudioTestCapture: AudioCapturing, @unchecked Sendable {
    private let continuation: AsyncStream<CapturedPCMBuffer>.Continuation
    private let stamps: [AudioCaptureStamp]
    var lastBufferUptime: Double { stamps.last?.callbackUptime ?? 0 }
    init(_ continuation: AsyncStream<CapturedPCMBuffer>.Continuation, stamps: [AudioCaptureStamp]) {
        self.continuation = continuation; self.stamps = stamps
    }
    func start() async throws {
        for stamp in stamps {
        #if canImport(AVFoundation)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: stamp.sampleRate,
                                  channels: AVAudioChannelCount(stamp.channels), interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(stamp.frames))!
        buffer.frameLength = AVAudioFrameCount(stamp.frames)
        memset(buffer.int16ChannelData![0], 0, stamp.frames * stamp.channels * 2)
        #else
        let buffer = Data(count: stamp.frames * 2)
        #endif
        continuation.yield(.init(buffer: buffer, stamp: stamp))
        }
    }
    func stop() async { continuation.finish() }
    func checkAfterForeground() {}
}

private final class AudioPipelineFixture: @unchecked Sendable {
    let time: AudioTestTime
    let transport: AudioTestTransport
    let events = AudioTestEvents()
    let gapGate = AudioTestGate()
    let slowGaps: Bool
    let results = AudioTestResults()
    let diagnostics = AudioTestDiagnostics()
    let stamps: [AudioCaptureStamp]
    init(now: Double, capturedAt: Double, frames: Int = 16_000, retryOnce: Bool = false, slowGaps: Bool = false,
         callbackAt: Double? = nil, stamps: [AudioCaptureStamp]? = nil) {
        self.slowGaps = slowGaps
        time = AudioTestTime(now); transport = AudioTestTransport(time: time, retryOnce: retryOnce)
        self.stamps = stamps ?? [.init(epoch: UUID(), sequence: 1, hostUptime: capturedAt, sampleTime: 0,
                      sampleRate: 16_000, frames: frames, callbackUptime: callbackAt ?? now)]
    }
    func pipeline() -> LiveTranscriptionPipeline {
        LiveTranscriptionPipeline(sessionID: UUID(), handlers: .init(
            result: { [results] _, _, _ in results.receive() }, status: { _ in },
            event: { [events, gapGate, slowGaps] event in
                events.receive(event)
                if slowGaps, case .captureGap = event { await gapGate.wait() }
            }, failure: { _ in }, diagnostic: { [diagnostics] value in diagnostics.receive(value) }),
            transport: transport, clock: time.clock,
            captureFactory: { [stamps] continuation, _ in AudioTestCapture(continuation, stamps: stamps) })
    }
}
