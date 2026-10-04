import Foundation
import XCTest
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import Mio

final class TranscriptionTests: XCTestCase {
    func testChunkOverlapOwnsEachCoreExactlyOnceAndFlushesTail() throws {
        let origin = Date(timeIntervalSince1970: 1_000)
        var assembler = AudioChunkAssembler(sessionID: UUID())
        var chunks: [AudioChunk] = []
        for second in 0..<45 {
            chunks += assembler.append(Data(repeating: UInt8(second), count: 32_000),
                                       at: origin.addingTimeInterval(Double(second)), uptime: Double(second))
        }
        chunks.append(try XCTUnwrap(assembler.finish()))
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.startedAt), [origin, origin.addingTimeInterval(20), origin.addingTimeInterval(40)])
        XCTAssertEqual(chunks.map(\.endedAt), [origin.addingTimeInterval(20), origin.addingTimeInterval(40), origin.addingTimeInterval(45)])
        XCTAssertEqual(chunks.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(chunks[1].pcm.count, 22 * 32_000)
        XCTAssertEqual(chunks[0].expiresAt, 60)
        XCTAssertEqual(chunks[1].expiresAt, 79)
        XCTAssertNil(assembler.finish())
        XCTAssertEqual(String(data: chunks[0].wave.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(chunks[0].wave.count, chunks[0].pcm.count + 44)
    }

    func testInterruptionPreservesWallClockGap() throws {
        var assembler = AudioChunkAssembler(sessionID: UUID())
        let start = Date(timeIntervalSince1970: 1_000)
        _ = assembler.append(Data(count: 32_000), at: start, uptime: 0)
        let first = try XCTUnwrap(assembler.finish())
        _ = assembler.append(Data(count: 32_000), at: start.addingTimeInterval(30), uptime: 30)
        let second = try XCTUnwrap(assembler.finish())
        XCTAssertEqual(first.endedAt, start.addingTimeInterval(1))
        XCTAssertEqual(second.startedAt, start.addingTimeInterval(30))
        XCTAssertEqual(second.sequence, 1)
    }

    func testResponseIdentityTimingAndCoreOwnership() throws {
        let chunk = AudioChunk(id: UUID(), sessionID: UUID(), sequence: 2, startSample: 10,
                               origin: .now, capturedUptime: 0, coreStart: 16_000, coreEnd: 32_000, pcm: Data(count: 96_000))
        let metadata = TranscriptionMetadata(model: "future-model", revision: "revision", backend: "adapter")
        func reply(_ words: [TranscriptionWord], id: UUID? = nil) -> TranscriptionReply {
            TranscriptionReply(apiVersion: 1, sessionID: chunk.sessionID, chunkID: id ?? chunk.id,
                               sequence: 2, startSample: 10, words: words, metadata: metadata)
        }
        let result = reply([.init(text: "vänster", start: 0.1, end: 0.5), .init(text: "kärna", start: 1.1, end: 1.4),
                            .init(text: "höger", start: 2.1, end: 2.5)])
        XCTAssertEqual(try result.validatedWords(for: chunk).map(\.text), ["kärna"])
        XCTAssertThrowsError(try reply([], id: UUID()).validatedWords(for: chunk))
        XCTAssertThrowsError(try reply([.init(text: "fel", start: -1, end: 1)]).validatedWords(for: chunk))
        XCTAssertThrowsError(try reply([.init(text: "fel", start: 0, end: .infinity)]).validatedWords(for: chunk))
        XCTAssertThrowsError(try reply([.init(text: "fel", start: 0, end: 4)]).validatedWords(for: chunk))
    }

    #if canImport(AVFoundation)
    func testConverterConservesResampledFramesAndFinalTailAcrossBufferSizes() throws {
        for rate in [44_100.0, 48_000.0] {
            let converter = BufferConverter()
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                     channels: 1, interleaved: false))
            var pcm = Data()
            var remaining = Int(rate)
            for size in [137, 4_096, 811, 2_003] {
                guard remaining > 0 else { break }
                let length = min(size, remaining)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)))
                buffer.frameLength = AVAudioFrameCount(length)
                memset(buffer.floatChannelData![0], 0, length * MemoryLayout<Float>.size)
                pcm.append(try converter.transcriptionPCM(buffer)); remaining -= length
            }
            let tail = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(remaining)))
            tail.frameLength = AVAudioFrameCount(remaining)
            memset(tail.floatChannelData![0], 0, remaining * MemoryLayout<Float>.size)
            pcm.append(try converter.transcriptionPCM(tail))
            pcm.append(try converter.finishTranscriptionPCM())
            XCTAssertEqual(Double(pcm.count / 2), 16_000, accuracy: 2)
            XCTAssertEqual(try converter.finishTranscriptionPCM().count, 0)
        }
    }

    func testConverterResetAndNativePCMKeepShortTailWithoutOldFormatAudio() throws {
        let converter = BufferConverter()
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        memset(buffer.int16ChannelData![0], 0, 320)
        XCTAssertEqual(try converter.transcriptionPCM(buffer).count, 320)
        converter.reset()
        XCTAssertEqual(try converter.finishTranscriptionPCM().count, 0)
    }
    #endif

    @MainActor
    func testPrivateOriginsAndCredentials() throws {
        XCTAssertEqual(try TranscriptionSettings.origin(" https://PC.tail.ts.net/ ").absoluteString, "https://pc.tail.ts.net")
        for address in ["http://pc.tail.ts.net", "https://public.example", "https://pc.tail.ts.net/path",
                        "https://user@pc.tail.ts.net", "https://pc.tail.ts.net?token=x", "https://pc.tail.ts.net:9999"] {
            XCTAssertThrowsError(try TranscriptionSettings.origin(address))
        }
        XCTAssertThrowsError(try TranscriptionSettings.validateToken("short"))
        XCTAssertThrowsError(try TranscriptionSettings.validateToken(String(repeating: "x", count: 32) + "\n"))
        XCTAssertNoThrow(try TranscriptionSettings.validateToken(String(repeating: "x", count: 43)))
    }

    func testGapAndMetadataSurviveStorageAndAppearInCopiedNotes() throws {
        var session = MioSession(endedAt: .now, captureMode: .lesson)
        session.captureGaps = [CaptureGap(startedAt: .now, endedAt: .now, reason: "Serveravbrott")]
        var segment = TranscriptSegment(text: "Original", containsMio: false)
        segment.sourceChunkID = UUID()
        segment.transcriptionMetadata = .init(model: "pianissimo", revision: "test", backend: "nemo")
        session.transcripts = [segment]
        let decoded = try JSONDecoder().decode(MioSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(session, decoded)
        XCTAssertTrue(MioLessonDocument(session: decoded, records: []).markdown.contains("Ofullständigt ljudunderlag"))
    }
}

/// Independent per-client stubs; no global handlers or network access during XCTest.
private final class HealthyTranscriptionProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let valid = request.url?.path == "/health"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
        let body = Data("""
        {"apiVersion":1,"serverVersion":"1.0.0","status":"ready","metadata":{"model":"future","revision":"abc","backend":"test"},"sampleRate":16000,"channels":1,"encoding":"pcm_s16le_wav","maxSeconds":24,"maxBytes":1048576,"futureField":true}
        """.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 401,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class UnavailableTranscriptionProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1",
                                       headerFields: ["Retry-After": "999999"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension TranscriptionTests {
    func testTransportUsesAuthenticatedHealthAndAcceptsAdditiveContractChanges() async throws {
        let client = TranscriptionClient(connection: .init(origin: URL(string: "https://test.tail.ts.net")!, token: "test-token"),
                                         protocolClasses: [HealthyTranscriptionProtocol.self])
        defer { client.cancel() }
        let health = try await client.health()
        XCTAssertEqual(health.metadata.model, "future")
    }

    func testUnavailableServerReturnsBoundedRetryInsteadOfHanging() async {
        let client = TranscriptionClient(connection: .init(origin: URL(string: "https://test.tail.ts.net")!, token: "test-token"),
                                         protocolClasses: [UnavailableTranscriptionProtocol.self])
        defer { client.cancel() }
        do { _ = try await client.health(); XCTFail("Expected 503") }
        catch { XCTAssertEqual((error as? TranscriptionError)?.retryDelay, 30) }
        XCTAssertNil(TranscriptionError.http(401, retryAfter: 5).retryDelay)
        XCTAssertNil(TranscriptionError.http(409, retryAfter: 5).retryDelay)
    }
}

private final class SyntheticChunkTranscriptionProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data
        if request.value(forHTTPHeaderField: "X-Mio-Sequence") == "999" {
            body = Data(repeating: 32, count: 262_145)
        } else {
            let payload: [String: Any] = ["apiVersion": 1,
                "sessionID": request.value(forHTTPHeaderField: "X-Mio-Session-ID")!,
                "chunkID": request.value(forHTTPHeaderField: "X-Mio-Chunk-ID")!,
                "sequence": Int(request.value(forHTTPHeaderField: "X-Mio-Sequence")!)!,
                "startSample": Int(request.value(forHTTPHeaderField: "X-Mio-Start-Sample")!)!,
                "words": [], "metadata": ["model": "synthetic", "revision": "test", "backend": "fixture"]]
            body = try! JSONSerialization.data(withJSONObject: payload)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension TranscriptionTests {
    func testTransferredTransportPreservesChunkIdentityAndRejectsOversizedStreamingBody() async throws {
        let client = TranscriptionClient(connection: .init(origin: URL(string: "https://test.tail.ts.net")!, token: "test-token"),
                                         protocolClasses: [SyntheticChunkTranscriptionProtocol.self])
        defer { client.cancel() }
        let chunk = AudioChunk(id: UUID(), sessionID: UUID(), sequence: 2, startSample: 16_000,
            origin: .now, capturedUptime: 0, coreStart: 0, coreEnd: 16_000, pcm: Data(count: 32_000))
        let reply = try await client.startTranscription(chunk).value
        XCTAssertEqual(reply.chunkID, chunk.id)
        XCTAssertEqual(reply.startSample, chunk.startSample)
        XCTAssertEqual(try reply.validatedWords(for: chunk), [])
        let oversized = AudioChunk(id: UUID(), sessionID: chunk.sessionID, sequence: 999, startSample: 0,
            origin: .now, capturedUptime: 0, coreStart: 0, coreEnd: 16_000, pcm: Data(count: 32_000))
        do { _ = try await client.startTranscription(oversized).value; XCTFail("Expected bounded response rejection") }
        catch { XCTAssertTrue(error is TranscriptionError) }
    }
}
