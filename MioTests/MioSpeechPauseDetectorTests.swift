import Foundation
import XCTest
@testable import Mio

final class MioSpeechPauseDetectorTests: XCTestCase {
    private let detector = SpeechPauseDetector()
    private let speech = 1_000_000.0
    private let quiet = 100.0

    func testFrameEnergiesAreMeanSquarePerCompleteTwentyMillisecondFrame() {
        var pcm = Self.pcm(seconds: 0.02, amplitude: 1_000, constant: true)
        pcm += Self.pcm(seconds: 0.02, amplitude: 0, constant: true)
        pcm += Data(count: 100)  // An incomplete frame waits for more audio.
        XCTAssertEqual(SpeechPauseDetector.frameEnergies(pcm), [1_000_000, 0])
        XCTAssertEqual(SpeechPauseDetector.frameEnergies(pcm, from: 1), [0])
        XCTAssertEqual(SpeechPauseDetector.frameEnergies(pcm, from: 2), [])
    }

    func testFirstClearPauseAfterEightSecondsIsCutInItsMiddle() {
        var energies = Array(repeating: speech, count: 700)
        for frame in 600..<640 { energies[frame] = quiet }
        XCTAssertEqual(detector.coreEnd(energies: energies, coreStart: 0), 607)
    }

    func testCoreStartOffsetsEveryLimit() {
        var energies = Array(repeating: speech, count: 750)
        for frame in 650..<690 { energies[frame] = quiet }
        XCTAssertEqual(detector.coreEnd(energies: energies, coreStart: 50), 657)
    }

    func testPausesBeforeEightSecondsAndShortDipsDoNotCut() {
        var early = Array(repeating: speech, count: 700)
        for frame in 200..<240 { early[frame] = quiet }
        XCTAssertNil(detector.coreEnd(energies: early, coreStart: 0))
        var short = Array(repeating: speech, count: 700)
        for frame in 600..<610 { short[frame] = quiet }
        XCTAssertNil(detector.coreEnd(energies: short, coreStart: 0))
    }

    func testCutWaitsForOneSecondOfRightContext() {
        var energies = Array(repeating: speech, count: 640)
        for frame in 600..<640 { energies[frame] = quiet }
        XCTAssertNil(detector.coreEnd(energies: energies, coreStart: 0))
        energies += Array(repeating: speech, count: 17)
        XCTAssertEqual(detector.coreEnd(energies: energies, coreStart: 0), 607)
    }

    func testWithoutAPauseTheQuietestWindowIsForcedAtTheMaximum() {
        var energies = Array(repeating: speech, count: 1_149)
        XCTAssertNil(detector.coreEnd(energies: energies, coreStart: 0), "22 s core plus 1 s context is not buffered yet")
        energies.append(speech)
        for frame in 900..<905 { energies[frame] = 10_000 }
        // Every window holding the whole dip ties; the latest keeps requests long.
        XCTAssertEqual(detector.coreEnd(energies: energies, coreStart: 0), 907)
        XCTAssertEqual(detector.coreEnd(energies: Array(repeating: 0, count: 1_150), coreStart: 0), 1_100)
    }

    func testAssemblerCutsInsideARealPauseAndKeepsContext() throws {
        let origin = Date(timeIntervalSince1970: 1_000)
        var assembler = AudioChunkAssembler(sessionID: UUID())
        let audio = Self.pcm(seconds: 10, amplitude: 3_000) + Self.pcm(seconds: 0.5, amplitude: 0)
            + Self.pcm(seconds: 3, amplitude: 3_000)
        let chunks = Self.feed(audio, to: &assembler, origin: origin)
        let first = try XCTUnwrap(chunks.first)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(first.coreStart, 0)
        XCTAssertEqual(first.coreEnd, 507 * 320, "cut in the middle of the 300 ms that confirmed the pause")
        XCTAssertEqual(first.pcm.count, (507 + 50) * 320 * 2)
        let tail = try XCTUnwrap(assembler.finish())
        XCTAssertEqual(tail.startedAt.timeIntervalSince1970, first.endedAt.timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertEqual(tail.coreStart, 16_000)
        XCTAssertEqual(tail.endedAt.timeIntervalSince1970, 1_013.5, accuracy: 1e-6)
    }

    func testEveryRequestStaysWithinApiLimitsAndCoresWithinEightToTwentyTwoSeconds() {
        // Speech with pauses every 3 s, then continuous speech, then silence.
        var audio = Data()
        for _ in 0..<12 { audio += Self.pcm(seconds: 2.6, amplitude: 2_500) + Self.pcm(seconds: 0.4, amplitude: 0) }
        audio += Self.pcm(seconds: 50, amplitude: 2_500) + Self.pcm(seconds: 30, amplitude: 0)
        var assembler = AudioChunkAssembler(sessionID: UUID())
        let chunks = Self.feed(audio, to: &assembler, origin: Date(timeIntervalSince1970: 0))
        XCTAssertGreaterThan(chunks.count, 5)
        for chunk in chunks {
            let core = Double(chunk.coreEnd - chunk.coreStart) / 16_000
            XCTAssertGreaterThanOrEqual(core, 8)
            XCTAssertLessThanOrEqual(core, 22)
            XCTAssertLessThanOrEqual(chunk.pcm.count / 2, 24 * 16_000)
            XCTAssertLessThanOrEqual(chunk.wave.count, TranscriptionHealth.requiredBytes)
        }
        let cores = zip(chunks, chunks.dropFirst()).map { abs($0.endedAt.timeIntervalSince($1.startedAt)) < 1e-6 }
        XCTAssertTrue(cores.allSatisfy { $0 }, "owned cores must tile the timeline without gaps or overlap")
        XCTAssertLessThan(assembler.retainedSamples, 24 * 16_000, "at most 23 s plus one tap stays in RAM")
    }

    func testHealthRequiresTwentyFourSecondCapacity() throws {
        func health(_ seconds: Int, _ bytes: Int) -> TranscriptionHealth {
            TranscriptionHealth(apiVersion: 1, serverVersion: "1", status: "ready",
                metadata: .init(model: "m", revision: "r", backend: "b"), sampleRate: 16_000, channels: 1,
                encoding: "pcm_s16le_wav", maxSeconds: seconds, maxBytes: bytes)
        }
        XCTAssertNoThrow(try health(24, 768_044).validate())
        XCTAssertThrowsError(try health(22, 1_048_576).validate())
        XCTAssertThrowsError(try health(24, 704_044).validate())
    }

    /// Feeds the assembler like the capture does: about 85 ms of converted PCM per tap.
    private static func feed(_ audio: Data, to assembler: inout AudioChunkAssembler, origin: Date) -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        var offset = 0
        let step = 1_365 * 2
        while offset < audio.count {
            let end = min(audio.count, offset + step)
            let seconds = Double(offset / 2) / 16_000
            chunks += assembler.append(audio.subdata(in: offset..<end), at: origin.addingTimeInterval(seconds), uptime: seconds)
            offset = end
        }
        return chunks
    }

    private static func pcm(seconds: Double, amplitude: Double, constant: Bool = false) -> Data {
        let count = Int((seconds * 16_000).rounded())
        var data = Data(capacity: count * 2)
        for index in 0..<count {
            let value = constant ? amplitude : amplitude * sin(2 * Double.pi * 440 * Double(index) / 16_000)
            var sample = Int16(value.rounded()).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }
}
