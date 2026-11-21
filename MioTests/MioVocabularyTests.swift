import XCTest
@testable import Mio

/// Own words from the phone (fas 4). Contract: docs/DATAMODELL.md, "Egna ord från telefonen".
final class MioVocabularyTests: XCTestCase {
    func testOnlyAReplacedWordOrShortPhraseIsOffered() {
        XCTAssertEqual(MioVocabulary.candidate(original: "Vi läser om Osa Lindkvist i dag.", correction: "Vi läser om Åsa Lindqvist i dag."),
                       "Åsa Lindqvist")
        XCTAssertEqual(MioVocabulary.candidate(original: "Det heter mito kondrie.", correction: "Det heter mitokondrie."), "mitokondrie")
        XCTAssertNil(MioVocabulary.candidate(original: "hej på dig", correction: "Hej på dig!"), "case and punctuation only")
        XCTAssertNil(MioVocabulary.candidate(original: "ett två tre", correction: "ett tre"), "a deletion is not a word")
        XCTAssertNil(MioVocabulary.candidate(original: "ett tre", correction: "ett två tre"), "an insertion replaces nothing")
        XCTAssertNil(MioVocabulary.candidate(original: "samma", correction: "samma"))
        XCTAssertNil(MioVocabulary.candidate(original: "kort", correction: String(repeating: "långtord ", count: 20)), "over 100 bytes")
        XCTAssertNil(MioVocabulary.candidate(original: "en rad", correction: "en #kommentar"))
        XCTAssertEqual(MioVocabulary.validPhrase("  C++  "), "C++")
        XCTAssertNil(MioVocabulary.validPhrase("två\nrader"))
        XCTAssertNil(MioVocabulary.validPhrase(String(repeating: "å", count: 51)), "51 two-byte letters are 102 bytes")
    }

    func testRequestAndReplyFollowTheContract() throws {
        let body = try MioVocabulary.requestBody(" Åsa Lindqvist ")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["phrase": "Åsa Lindqvist"])
        XCTAssertThrowsError(try MioVocabulary.requestBody("#nej"))
        XCTAssertEqual(try MioVocabularyReply.decode(Data(#"{"added":true,"vocabulary":37}"#.utf8)),
                       MioVocabularyReply(added: true, vocabulary: 37))
        XCTAssertEqual(try MioVocabularyReply.decode(Data(#"{"added":false,"vocabulary":3,"future":1}"#.utf8)).added, false)
        XCTAssertThrowsError(try MioVocabularyReply.decode(Data(#"{"added":true}"#.utf8)))
        XCTAssertThrowsError(try MioVocabularyReply.decode(Data(#"{"added":"ja","vocabulary":1}"#.utf8)))
        XCTAssertEqual(MioVocabularyError.http(409), .full)
        XCTAssertEqual(MioVocabularyError.http(400), .invalidPhrase)
        XCTAssertEqual(MioVocabularyError.http(415), .invalidPhrase)
        XCTAssertEqual(MioVocabularyError.http(507), .storageFailed)
        XCTAssertEqual(MioVocabularyError.http(408), .network)
        XCTAssertEqual(MioVocabularyError.http(401), .unauthorized)
        for error in [MioVocabularyError.invalidPhrase, .unauthorized, .full, .tooLarge, .unavailable, .storageFailed, .invalidResponse, .network] {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty)
            XCTAssertNil(text.range(of: #"\d{3}"#, options: .regularExpression), "no codes in the sentence")
        }
    }

    func testTheAskedLogHoldsHashesNotWords() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MioVocabularyTests-\(UUID())"))
        XCTAssertFalse(MioVocabularyAskedLog.hasAsked("Åsa Lindqvist", in: defaults))
        MioVocabularyAskedLog.record("Åsa Lindqvist", in: defaults)
        XCTAssertTrue(MioVocabularyAskedLog.hasAsked("åsa lindqvist", in: defaults))
        let stored = String(decoding: try XCTUnwrap(defaults.data(forKey: MioVocabularyAskedLog.key)), as: UTF8.self)
        XCTAssertFalse(stored.contains("Lindqvist"))
        XCTAssertEqual(MioVocabularyAskedLog.hash("Åsa"), MioVocabularyAskedLog.hash("åsa"))
        MioVocabularyAskedLog.reset(in: defaults)
        XCTAssertFalse(MioVocabularyAskedLog.hasAsked("Åsa Lindqvist", in: defaults))
    }

    func testHealthReadsTheAdditiveUploadField() throws {
        let base = #"{"apiVersion":1,"serverVersion":"1","status":"ready","metadata":{"model":"m","revision":"r","backend":"b"},"sampleRate":16000,"channels":1,"encoding":"pcm_s16le_wav","maxSeconds":24,"maxBytes":768044"#
        XCTAssertNil(try JSONDecoder().decode(TranscriptionHealth.self, from: Data((base + "}").utf8)).vocabularyUpload)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionHealth.self, from: Data((base + #","vocabularyUpload":true}"#).utf8)).vocabularyUpload, true)
    }

    @MainActor
    private func makeCapture(root: URL, transport: VocabularyTransport, defaults: UserDefaults) async throws -> (MioViewModel, MioSession) {
        let sessions = SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))
        let started = Date(timeIntervalSinceNow: -600)
        let session = MioSession(startedAt: started, endedAt: started.addingTimeInterval(300),
                                 transcripts: [TranscriptSegment(createdAt: started.addingTimeInterval(10), text: "Vi läser om Osa Lindkvist.", containsMio: false)])
        let token = try await sessions.operationToken(for: session.id, generation: await sessions.operationGeneration())
        _ = try await sessions.saveCaptureCheckpoint(session, token: token)
        let capture = MioViewModel(repository: sessions, diagnostics: MioDiagnosticsRepository(storageURL: root.appendingPathComponent("d.json")),
                                   captureFactory: { _, _ in throw MioError.microphoneDenied })
        capture.vocabularyDefaults = defaults
        capture.vocabularyTransport = { transport }
        await capture.bootstrap()
        return (capture, session)
    }

    @MainActor
    func testACorrectionAsksOnceAndJaSendsTheWordOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioVocabulary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MioVocabularyTests-\(UUID())"))
        let transport = VocabularyTransport(upload: true)
        let (capture, session) = try await makeCapture(root: root, transport: transport, defaults: defaults)
        let segmentID = session.transcripts[0].id
        let saved = await capture.correctTranscript(sessionID: session.id, segmentID: segmentID, text: "Vi läser om Åsa Lindqvist.")
        XCTAssertTrue(saved)
        await capture.vocabularyCheck?.value
        XCTAssertEqual(capture.vocabularyOffer?.phrase, "Åsa Lindqvist")
        await capture.answerVocabularyOffer(accept: true)
        XCTAssertNil(capture.vocabularyOffer)
        XCTAssertEqual(transport.uploaded, ["Åsa Lindqvist"])
        XCTAssertEqual(capture.vocabularyMessage?.segmentID, segmentID)
        // The same word again: no new question.
        _ = await capture.correctTranscript(sessionID: session.id, segmentID: segmentID, text: "Vi läser om Osa Lindkvist.")
        await capture.vocabularyCheck?.value
        XCTAssertEqual(capture.vocabularyOffer?.phrase, "Osa Lindkvist")
        await capture.answerVocabularyOffer(accept: false)
        _ = await capture.correctTranscript(sessionID: session.id, segmentID: segmentID, text: "Vi läser om Åsa Lindqvist.")
        await capture.vocabularyCheck?.value
        XCTAssertNil(capture.vocabularyOffer)
        XCTAssertEqual(transport.uploaded.count, 1)
        XCTAssertEqual(transport.healthChecks, 1, "the health answer is reused during the run")
    }

    @MainActor
    func testAnOlderPianissimoIsNeverAskedAndAFailureIsNotRetriedByItself() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioVocabulary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MioVocabularyTests-\(UUID())"))
        let old = VocabularyTransport(upload: false)
        let (capture, session) = try await makeCapture(root: root, transport: old, defaults: defaults)
        let segmentID = session.transcripts[0].id
        _ = await capture.correctTranscript(sessionID: session.id, segmentID: segmentID, text: "Vi läser om Åsa Lindqvist.")
        await capture.vocabularyCheck?.value
        XCTAssertNil(capture.vocabularyOffer)
        XCTAssertFalse(MioVocabularyAskedLog.hasAsked("Åsa Lindqvist", in: defaults), "not asked, so it may be asked later")

        let failing = VocabularyTransport(upload: true, failure: .full)
        capture.serverVocabularyUpload = nil
        capture.vocabularyTransport = { failing }
        _ = await capture.correctTranscript(sessionID: session.id, segmentID: segmentID, text: "Vi läser om Åsa Lindkvist.")
        await capture.vocabularyCheck?.value
        XCTAssertEqual(capture.vocabularyOffer?.phrase, "Lindkvist")
        await capture.answerVocabularyOffer(accept: true)
        XCTAssertEqual(capture.vocabularyFailures[segmentID], "Lindkvist")
        XCTAssertEqual(capture.vocabularyMessage?.text, MioVocabularyError.full.errorDescription)
        XCTAssertEqual(failing.uploaded.count, 1, "one call, no automatic repetition")
        // She sends it again herself from the correction.
        let resent = await capture.sendVocabulary(segmentID: segmentID, phrase: "Lindkvist")
        XCTAssertFalse(resent)
        XCTAssertEqual(failing.uploaded.count, 2)
    }

    @MainActor
    func testAJaWhileAnotherWordIsSentWaitsItsTurnInsteadOfVanishing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioVocabulary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MioVocabularyTests-\(UUID())"))
        let transport = VocabularyTransport(upload: true)
        let (capture, session) = try await makeCapture(root: root, transport: transport, defaults: defaults)
        let first = session.transcripts[0].id, second = UUID()
        transport.hold = true
        let running = Task { await capture.sendVocabulary(segmentID: first, phrase: "Lindqvist") }
        for _ in 0..<1_000 where transport.uploaded.isEmpty { await Task.yield() }
        XCTAssertEqual(capture.vocabularySendingSegmentID, first)
        // The second Ja arrives while the first word is on its way.
        let queued = await capture.sendVocabulary(segmentID: second, phrase: "mitokondrie")
        XCTAssertFalse(queued, "not sent yet")
        XCTAssertEqual(capture.vocabularyMessage?.segmentID, second)
        XCTAssertEqual(transport.uploaded, ["Lindqvist"], "never two calls at once")
        transport.hold = false
        let sent = await running.value
        XCTAssertTrue(sent)
        XCTAssertEqual(transport.uploaded, ["Lindqvist", "mitokondrie"], "each Ja is one call, in order")
        XCTAssertNil(capture.vocabularySendingSegmentID)
        XCTAssertEqual(capture.vocabularyMessage?.text, "”mitokondrie” finns nu i ordlistan på datorn.")
        XCTAssertTrue(capture.vocabularyFailures.isEmpty)
    }
}

private final class VocabularyTransport: TranscriptionTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let supportsUpload: Bool
    private let failure: MioVocabularyError?
    private var _uploaded: [String] = []
    private var _healthChecks = 0
    private var _hold = false
    var uploaded: [String] { lock.withLock { _uploaded } }
    /// While true, an upload is recorded but does not answer yet.
    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }
    var healthChecks: Int { lock.withLock { _healthChecks } }

    init(upload: Bool, failure: MioVocabularyError? = nil) { supportsUpload = upload; self.failure = failure }

    func health() async throws -> TranscriptionHealth {
        lock.withLock { _healthChecks += 1 }
        var health = TranscriptionHealth(apiVersion: 1, serverVersion: "fixture", status: "ready",
                                         metadata: TranscriptionMetadata(model: "m", revision: "r", backend: "b"),
                                         sampleRate: 16_000, channels: 1, encoding: "pcm_s16le_wav", maxSeconds: 24, maxBytes: 768_044)
        health.vocabularyUpload = supportsUpload ? true : nil
        return health
    }
    func startTranscription(_ chunk: AudioChunk) -> Task<TranscriptionReply, Error> { Task { throw TranscriptionError.notConfigured } }
    func cancel() { }
    func uploadVocabulary(_ phrase: String) async throws -> MioVocabularyReply {
        lock.withLock { _uploaded.append(phrase) }
        while hold { try await Task.sleep(nanoseconds: 1_000_000) }
        if let failure { throw failure }
        return MioVocabularyReply(added: true, vocabulary: 1)
    }
}
