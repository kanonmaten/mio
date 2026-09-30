import Foundation
import XCTest
@testable import Mio

final class MioAnalysisCoordinatorContextTests: XCTestCase {
    @MainActor
    private func assistant(_ test: XCTestCase) -> MioAssistantViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return MioAssistantViewModel(repository: MioAssistantRepository(storageURL: directory.appendingPathComponent("assistant.json")))
    }

    @MainActor
    func testIncompleteSpeechWaitsAtMost120SecondsAndRequestsV2() async throws {
        let assistant = assistant(self)
        var clock = Date.now
        let start = clock
        var waits: [TimeInterval] = []
        let sent = expectation(description: "Incomplete speech reaches hard deadline")
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, send: { request, _ in
            XCTAssertTrue(request.usesContextContract)
            XCTAssertEqual(clock.timeIntervalSince(start), 120, accuracy: 0.01)
            XCTAssertEqual(request.fragments.map(\.text), ["Vi ses på biblioteket"])
            XCTAssertEqual(request.queueSize, 1)
            sent.fulfill()
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
        }, wait: { seconds in waits.append(seconds); clock.addTimeInterval(seconds) }, now: { clock })
        try coordinator.enable(existingSessions: [])
        let segment = TranscriptSegment(createdAt: clock, text: "Vi ses på biblioteket", containsMio: false)
        coordinator.observe(MioSession(transcripts: [segment]), assistant: assistant)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(waits, [60, 20, 20, 20])
        coordinator.disable()
        XCTAssertFalse(MioDiagnosticsRuntime.analysisEnabled)
    }

    @MainActor
    func testSecondRequestUsesDecisionCreatedByFirstResponseAndPreservesMinutePacing() async throws {
        let assistant = assistant(self)
        var clock = Date.now
        let segment = TranscriptSegment(createdAt: clock, audioEndedAt: clock.addingTimeInterval(20), text: "Vi ses på biblioteket.", containsMio: false)
        var session = MioSession(transcripts: [segment])
        let done = expectation(description: "Two requests use latest decision metadata")
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        var calls: [Date] = []
        var coordinator: MioAnalysisCoordinator!
        coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, send: { request, _ in
            calls.append(clock)
            if calls.count == 1 {
                session.transcripts.append(TranscriptSegment(createdAt: segment.createdAt.addingTimeInterval(20), text: "På torsdag klockan tre.", containsMio: false))
                coordinator.observe(session, assistant: assistant)
                return MioAnalysisResult(candidates: [MioAnalysisCandidate(kind: .plan, title: "Biblioteket", body: "", scheduledAt: nil,
                    sourceIDs: [request.fragments[0].id], evidence: segment.text)], highlights: [], uncertainties: [])
            }
            XCTAssertEqual(request.fragments.count, 1)
            XCTAssertEqual(request.contextFragments.first?.segmentID, segment.id)
            XCTAssertEqual(request.priorDecisions.count, 1)
            XCTAssertTrue(request.priorDecisions.first?.isOpen == true)
            XCTAssertGreaterThanOrEqual(calls[1].timeIntervalSince(calls[0]), 60)
            done.fulfill()
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
        }, wait: { clock.addTimeInterval($0) }, now: { clock })
        try coordinator.enable(existingSessions: [])
        coordinator.observe(session, assistant: assistant)
        await fulfillment(of: [done], timeout: 2)
        coordinator.disable()
    }

    @MainActor
    func testCaptureGapSplitsNewBatchesWithoutDroppingEitherSide() async throws {
        let assistant = assistant(self)
        var clock = Date.now
        let first = TranscriptSegment(createdAt: clock, text: "Vi ses på biblioteket.", containsMio: false)
        let second = TranscriptSegment(createdAt: clock.addingTimeInterval(30), text: "På torsdag klockan tre.", containsMio: false)
        var session = MioSession(transcripts: [first, second])
        session.captureGaps = [CaptureGap(startedAt: clock.addingTimeInterval(10), endedAt: clock.addingTimeInterval(20), reason: "Syntetiskt avbrott")]
        let sent = expectation(description: "Separate requests around the gap"); sent.expectedFulfillmentCount = 2
        var sources: [UUID] = []
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, send: { request, _ in
            XCTAssertEqual(request.fragments.count, 1)
            XCTAssertTrue(request.contextFragments.isEmpty)
            sources.append(try XCTUnwrap(request.fragments.first?.segmentID))
            XCTAssertEqual(request.contextLimited, sources.count == 2)
            sent.fulfill()
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
        }, wait: { clock.addTimeInterval($0) }, now: { clock })
        try coordinator.enable(existingSessions: [])
        coordinator.observe(session, assistant: assistant)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(sources, [first.id, second.id])
        coordinator.disable()
    }

    @MainActor
    func testFinalDrainIncludesTextDeliveredWhileStoppingAndSkipsSoftDelay() async throws {
        let assistant = assistant(self)
        var clock = Date.now
        let start = clock
        var session = MioSession(transcripts: [TranscriptSegment(createdAt: clock, text: "Vi ses", containsMio: false)])
        let done = expectation(description: "Final text kept")
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, send: { request, _ in
            XCTAssertEqual(request.fragments.map(\.text), ["Vi ses", "på biblioteket"])
            XCTAssertLessThanOrEqual(clock.timeIntervalSince(start), 60)
            done.fulfill()
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
        }, wait: { clock.addTimeInterval($0) }, now: { clock })
        try coordinator.enable(existingSessions: [])
        coordinator.observe(session, assistant: assistant)
        coordinator.beginEndingEveryday(sessionID: session.id)
        session.transcripts.append(TranscriptSegment(createdAt: clock.addingTimeInterval(20), text: "på biblioteket", containsMio: false))
        coordinator.finishEveryday(session, assistant: assistant)
        await fulfillment(of: [done], timeout: 2)
        coordinator.disable()
    }

    @MainActor
    func testFinalDrainWakesPendingAggregationWithoutWaitingAnotherMinute() async throws {
        let assistant = assistant(self)
        let waiting = expectation(description: "Aggregation wait started")
        let cancelled = expectation(description: "Stop wakes old aggregation")
        let done = expectation(description: "Final request sent promptly")
        var session = MioSession(transcripts: [TranscriptSegment(text: "Vi ses", containsMio: false)])
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        var calls = 0
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, send: { request, _ in
            calls += 1
            XCTAssertEqual(request.fragments.map(\.text), ["Vi ses", "på biblioteket"])
            done.fulfill()
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
        }, wait: { _ in
            waiting.fulfill()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled.fulfill(); throw error }
        })
        try coordinator.enable(existingSessions: [])
        session.transcripts[0] = TranscriptSegment(text: "Vi ses", containsMio: false)
        coordinator.observe(session, assistant: assistant)
        await fulfillment(of: [waiting], timeout: 2)
        coordinator.beginEndingEveryday(sessionID: session.id)
        session.transcripts.append(TranscriptSegment(text: "på biblioteket", containsMio: false))
        coordinator.finishEveryday(session, assistant: assistant)
        await fulfillment(of: [cancelled, done], timeout: 2)
        XCTAssertEqual(calls, 1)
        coordinator.disable()
    }


    @MainActor
    func testModelPacingStartsAfterSlowStatusAndSendCompletion() async throws {
        let assistant = assistant(self)
        var clock = Date.now
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        let done = expectation(description: "Pacing includes delayed preflight")
        var modelStarts: [Date] = []
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, send: { _, _ in
            if modelStarts.isEmpty { clock.addTimeInterval(40) }
            modelStarts.append(clock)
            if modelStarts.count == 2 {
                XCTAssertGreaterThanOrEqual(modelStarts[1].timeIntervalSince(modelStarts[0]), 60)
                done.fulfill()
            }
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
        }, wait: { clock.addTimeInterval($0) }, now: { clock })
        try coordinator.enable(existingSessions: [])
        let segments = (0..<2).map { _ in TranscriptSegment(createdAt: clock, text: String(repeating: "A", count: 3399) + ".", containsMio: false) }
        coordinator.observe(MioSession(transcripts: segments), assistant: assistant)
        await fulfillment(of: [done], timeout: 2)
        coordinator.disable()
    }

}
