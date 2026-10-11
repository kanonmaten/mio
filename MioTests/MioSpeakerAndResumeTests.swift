import Foundation
import XCTest
@testable import Mio

final class MioSpeakerAndResumeTests: XCTestCase {
    func testSpeakerDecodingIsLenientAndNeverRejectsTheTranscript() throws {
        let json = """
        {"apiVersion":1,"sessionID":"b6e59117-89a4-49eb-81be-451c12738613",
         "chunkID":"d5821461-d257-474c-be09-6599e44a66d2","sequence":0,"startSample":0,
         "words":[{"text":"a","start":0.1,"end":0.2,"speaker":1},
                  {"text":"b","start":0.2,"end":0.3,"speaker":null},
                  {"text":"c","start":0.3,"end":0.4},
                  {"text":"d","start":0.4,"end":0.5,"speaker":5},
                  {"text":"e","start":0.5,"end":0.6,"speaker":0},
                  {"text":"f","start":0.6,"end":0.7,"speaker":"2"},
                  {"text":"g","start":0.7,"end":0.8,"speaker":2.5},
                  {"text":"h","start":0.8,"end":0.9,"speaker":4}],
         "metadata":{"model":"m","revision":"r","backend":"b"}}
        """
        let reply = try JSONDecoder().decode(TranscriptionReply.self, from: Data(json.utf8))
        XCTAssertEqual(reply.words.map(\.speaker), [1, nil, nil, nil, nil, nil, nil, 4])
        XCTAssertEqual(reply.words.map(\.text).joined(), "abcdefgh")
    }

    func testWordsWithoutSpeakerFieldDecodeAsBefore() throws {
        let word = try JSONDecoder().decode(TranscriptionWord.self, from: Data(#"{"text":"Hej","start":0.24,"end":0.48}"#.utf8))
        XCTAssertEqual(word, TranscriptionWord(text: "Hej", start: 0.24, end: 0.48))
        XCTAssertThrowsError(try JSONDecoder().decode(TranscriptionWord.self, from: Data(#"{"text":"Hej","start":0.24}"#.utf8)))
    }

    func testSpeakerRunsSplitOnlyAtLabelledChanges() {
        func words(_ speakers: [Int?]) -> [TranscriptionWord] {
            speakers.enumerated().map { TranscriptionWord(text: "w\($0.offset)", start: Double($0.offset), end: Double($0.offset), speaker: $0.element) }
        }
        let runs = TranscriptionWord.speakerRuns(words([nil, 1, 1, nil, 2, 2, nil, 1]))
        XCTAssertEqual(runs.map(\.speaker), [1, 2, 1])
        XCTAssertEqual(runs.map(\.words.count), [4, 3, 1])
        let unlabelled = TranscriptionWord.speakerRuns(words([nil, nil, nil]))
        XCTAssertEqual(unlabelled.count, 1)
        XCTAssertNil(unlabelled.first?.speaker)
        XCTAssertTrue(TranscriptionWord.speakerRuns([]).isEmpty)
    }

    func testSpeakerDisplayNamesAreASeparateCleanedMapping() {
        XCTAssertEqual(MioSpeakerLabel.displayName(for: 2, names: nil), "Talare 2")
        var names = MioSpeakerLabel.renamed(nil, speaker: 2, to: "  Anna\nKarin  ")
        XCTAssertEqual(names, [2: "Anna Karin"])
        XCTAssertEqual(MioSpeakerLabel.displayName(for: 2, names: names), "Anna Karin")
        XCTAssertEqual(MioSpeakerLabel.displayName(for: 1, names: names), "Talare 1")
        names = MioSpeakerLabel.renamed(names, speaker: 5, to: "Utanför")
        XCTAssertEqual(names, [2: "Anna Karin"])
        let long = MioSpeakerLabel.renamed(names, speaker: 1, to: String(repeating: "x", count: 80))
        XCTAssertEqual(long?[1]?.count, MioSpeakerLabel.maximumNameLength)
        XCTAssertNil(MioSpeakerLabel.renamed(names, speaker: 2, to: "   "))
        XCTAssertNil(MioSpeakerLabel.renamed(names, speaker: 2, to: "Talare 2"))
    }

    func testLabelsAppearWhereTheSpeakerChangesAndLegacyDataHasNone() throws {
        var session = MioSession()
        session.transcripts = [segment(1), segment(1), segment(nil), segment(2), segment(2), segment(1)]
        session.speakerNames = [2: "Bo"]
        XCTAssertEqual((0..<6).map { session.speakerLabel(at: $0) }, ["Talare 1", nil, nil, "Bo", nil, "Talare 1"])
        XCTAssertNil(session.speakerLabel(at: 6))
        let decoded = try JSONDecoder().decode(MioSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded, session)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
        legacy["speakerNames"] = nil
        var transcripts = legacy["transcripts"] as! [[String: Any]]
        for index in transcripts.indices { transcripts[index]["speaker"] = nil }
        legacy["transcripts"] = transcripts
        let old = try JSONDecoder().decode(MioSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.speakerNames)
        XCTAssertTrue(old.transcripts.allSatisfy { $0.speaker == nil })
    }

    func testAIExcerptsSayWhoSpokeWithNeutralLabelsOnly() {
        var labelled = segment(3)
        labelled.correctedText = "Rättad mening."
        XCTAssertEqual(MioAnalysisFragment.make(from: labelled).map(\.text), ["Talare 3: Rättad mening."])
        XCTAssertEqual(MioAnalysisFragment.make(from: segment(nil)).map(\.text), ["Hej där."])
        var long = TranscriptSegment(text: String(repeating: "å", count: 2_000), containsMio: false)
        long.speaker = 1
        let parts = MioAnalysisFragment.make(from: long)
        XCTAssertTrue(parts.allSatisfy { $0.text.utf8.count <= 3_500 })
        XCTAssertTrue(parts.first?.text.hasPrefix("Talare 1: ") == true)
    }

    func testRenamingASpeakerNeverChangesTheOriginalTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioSpeakerTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionRepository(storageURL: root.appendingPathComponent("sessions.json"))
        var session = MioSession()
        session.transcripts = [segment(1), segment(2)]
        let token = try await repository.operationToken(for: session.id, generation: await repository.operationGeneration())
        try await repository.saveCaptureCheckpoint(session, token: token)
        do { _ = try await repository.renameSpeaker(sessionID: session.id, speaker: 1, name: "Ada", token: token); XCTFail("Live sessions are not renamed") }
        catch { }
        session.endedAt = .now
        try await repository.saveCaptureCheckpoint(session, token: token)
        let renamed = try await repository.renameSpeaker(sessionID: session.id, speaker: 1, name: "Ada", token: token)
        XCTAssertEqual(renamed.speakerNames, [1: "Ada"])
        XCTAssertEqual(renamed.transcripts, session.transcripts)
        do { _ = try await repository.renameSpeaker(sessionID: session.id, speaker: 4, name: "Ingen", token: token); XCTFail("Unknown speaker") }
        catch { }
        let stored = try await repository.loadSessions()
        XCTAssertEqual(stored.first?.speakerName(for: 1), "Ada")
        XCTAssertEqual(stored.first?.speakerName(for: 2), "Talare 2")
    }

    func testResumeDecisionRespectsTheUserAndFallsBackToTheUser() {
        typealias Policy = MioCaptureResumePolicy
        XCTAssertEqual(Policy.decision(userWantsListening: true, interruptionOngoing: false, restartFailed: false, appIsActive: false), .restart)
        XCTAssertEqual(Policy.decision(userWantsListening: true, interruptionOngoing: false, restartFailed: false, appIsActive: true), .restart)
        XCTAssertEqual(Policy.decision(userWantsListening: true, interruptionOngoing: true, restartFailed: false, appIsActive: false), .none)
        XCTAssertEqual(Policy.decision(userWantsListening: false, interruptionOngoing: false, restartFailed: false, appIsActive: true), .none,
                       "a pause or stop by the user is never undone")
        XCTAssertEqual(Policy.decision(userWantsListening: false, interruptionOngoing: false, restartFailed: true, appIsActive: false), .none)
        XCTAssertEqual(Policy.decision(userWantsListening: true, interruptionOngoing: false, restartFailed: true, appIsActive: false), .notifyUser)
        XCTAssertEqual(Policy.decision(userWantsListening: true, interruptionOngoing: false, restartFailed: true, appIsActive: true), .askInApp)
    }

    func testAutomaticRestartsAreRateLimited() {
        XCTAssertTrue(MioCaptureResumePolicy.allowsAutomaticRestart(previous: [], now: 100))
        XCTAssertTrue(MioCaptureResumePolicy.allowsAutomaticRestart(previous: [50, 90], now: 100))
        XCTAssertFalse(MioCaptureResumePolicy.allowsAutomaticRestart(previous: [50, 90, 99], now: 100))
        XCTAssertTrue(MioCaptureResumePolicy.allowsAutomaticRestart(previous: [10, 20, 30], now: 100))
    }

    func testResumeNotificationRouteOnlyOpensCapture() {
        let route = MioNotificationRoute.resumeListening
        XCTAssertEqual(MioNotificationRoute(userInfo: route.userInfo), route)
        XCTAssertNil(MioNotificationRoute(userInfo: ["mioRoute": "resumeListening", "extra": "x"]))
        XCTAssertEqual(route.notificationBody, "Tryck för att fortsätta lyssna.")
    }

    @MainActor
    func testRefusedBackgroundRestartKeepsListeningSessionAndPostsNotice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MioResumeTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = ResumeCapture()
        let model = MioViewModel(repository: SessionRepository(storageURL: root.appendingPathComponent("sessions.json")),
                                 captureFactory: { _, handlers in capture.handlers = handlers; return capture })
        var notices: [MioResumeNotice] = []
        model.onResumeNotice = { notices.append($0) }
        await model.bootstrap()
        model.beginListening()
        await waitUntil { model.runState == .listening }
        XCTAssertEqual(notices, [.prepare])
        await capture.handlers?.event(.interruptionBegan)
        XCTAssertEqual(model.runState, .interrupted)
        model.isAppActive = { false }
        await capture.handlers?.event(.restartFailed("iOS tillät inte att mikrofonen startade igen."))
        XCTAssertEqual(model.runState, .interrupted, "the session waits for the user instead of pausing")
        XCTAssertEqual(notices, [.prepare, .post])
        await capture.handlers?.event(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(model.runState, .listening)
        XCTAssertEqual(notices, [.prepare, .post, .withdraw])
        await model.stopListening()
        XCTAssertEqual(model.runState, .off)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Övergången blev inte klar")
    }

    private func segment(_ speaker: Int?) -> TranscriptSegment {
        var segment = TranscriptSegment(text: "Hej där.", containsMio: false)
        segment.speaker = speaker
        return segment
    }
}

private final class ResumeCapture: MioCapturePipeline, @unchecked Sendable {
    var handlers: MioCaptureHandlers?
    func start() async throws -> CaptureStartDetails {
        CaptureStartDetails(health: TranscriptionHealth(apiVersion: 1, serverVersion: "fixture", status: "ready",
            metadata: TranscriptionMetadata(model: "fixture", revision: "fixture", backend: "fixture"),
            sampleRate: 16_000, channels: 1, encoding: "pcm_s16le_wav", maxSeconds: 24, maxBytes: 768_044))
    }
    func foreground() async { }
    func stop(discard: Bool) async { }
}
