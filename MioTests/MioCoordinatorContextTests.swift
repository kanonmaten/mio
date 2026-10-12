import Foundation
import XCTest
@testable import Mio

final class MioAnalysisCoordinatorContextTests: XCTestCase {
    @MainActor
    func testCredentialChangeDuringFailedAnalysisDoesNotPublishStaleProviderError() async throws {
        let helper = assistant(self)
        var isCurrent = true
        var clock = Date.now
        let connection = syntheticCloudConnection()
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection },
            configurationMatches: { _ in isCurrent },
            prepareConnection: { try await syntheticPreparedConnection($0, task: $1) },
            send: { _, _ in isCurrent = false; throw MioCloudError.network },
            wait: { clock.addTimeInterval($0) }, now: { clock })
        try await coordinator.enable(existingSessions: [])
        coordinator.observe(MioSession(transcripts: [TranscriptSegment(createdAt: clock,
            text: "Syntetiskt underlag.", containsMio: false)]), assistant: helper)
        for _ in 0..<10_000 { if !coordinator.isWorking && !coordinator.enabled { break }; await Task.yield() }
        XCTAssertFalse(coordinator.enabled)
        XCTAssertNotEqual(coordinator.status, "AI är pausad. Inga fler utdrag skickas.",
                          "A silently changed connection needs a fresh activation notice")
        XCTAssertNotEqual(coordinator.errorMessage, MioCloudError.network.localizedDescription
            + " AI startar igen nästa gång du öppnar Mio, eller med Starta AI igen i Inställningar.",
                          "A failure from the old connection must not be shown")
        XCTAssertTrue(coordinator.errorMessage?.localizedCaseInsensitiveContains("anslutning") == true)
        XCTAssertTrue(helper.analyses.isEmpty)
    }

    @MainActor
    private func assistant(_ test: XCTestCase) -> MioAssistantViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return MioAssistantViewModel(repository: MioAssistantRepository(storageURL: directory.appendingPathComponent("assistant.json")))
    }

    @MainActor
    func testCompletedAnalysisWaitsForSnapshotAndKeepsConsent() async throws {
        let assistant = assistant(self)
        var clock = Date.now
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        var responseReady = false
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, prepareConnection: { try await syntheticPreparedConnection($0, task: $1) },
            send: { _, _ in
                let acquired = await MioMaintenanceState.shared.beginExclusive(deleting: false)
                XCTAssertTrue(acquired)
                responseReady = true
                return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
            }, wait: { clock.addTimeInterval($0) }, now: { clock })
        defer { MioMaintenanceState.shared.endExclusive(); coordinator.disable() }
        try await coordinator.enable(existingSessions: [])
        coordinator.observe(MioSession(transcripts: [TranscriptSegment(createdAt: clock, text: "Syntetiskt underlag.", containsMio: false)]), assistant: assistant)
        for _ in 0..<10_000 { if responseReady { break }; await Task.yield() }
        XCTAssertTrue(responseReady)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(coordinator.enabled, "An export must not discard a completed analysis or disable consent")
        XCTAssertTrue(assistant.analyses.isEmpty)
        MioMaintenanceState.shared.endExclusive()
        for _ in 0..<10_000 { if coordinator.sentBatches == 1 || !coordinator.enabled { break }; await Task.yield() }
        XCTAssertEqual(coordinator.sentBatches, 1)
        XCTAssertEqual(assistant.analyses.count, 1)
    }

    @MainActor
    func testEverydayTextWaitsForFiveMinuteBatchAndRequestsV2() async throws {
        let assistant = assistant(self)
        var clock = Date.now
        let start = clock
        var waits: [TimeInterval] = []
        let sent = expectation(description: "Everyday text is sent when its batch window closes")
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { request, _ in
            XCTAssertTrue(request.usesContextContract)
            XCTAssertEqual(clock.timeIntervalSince(start), 300, accuracy: 0.01)
            XCTAssertEqual(request.fragments.map(\.text), ["Vi ses på biblioteket"])
            XCTAssertEqual(request.queueSize, 1)
            sent.fulfill()
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
        }, wait: { seconds in waits.append(seconds); clock.addTimeInterval(seconds) }, now: { clock })
        try await coordinator.enable(existingSessions: [])
        let segment = TranscriptSegment(createdAt: clock, text: "Vi ses på biblioteket", containsMio: false)
        coordinator.observe(MioSession(transcripts: [segment]), assistant: assistant)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(waits, [300])
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
        coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { request, _ in
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
        try await coordinator.enable(existingSessions: [])
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
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { request, _ in
            XCTAssertEqual(request.fragments.count, 1)
            XCTAssertTrue(request.contextFragments.isEmpty)
            sources.append(try XCTUnwrap(request.fragments.first?.segmentID))
            XCTAssertEqual(request.contextLimited, sources.count == 2)
            sent.fulfill()
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
        }, wait: { clock.addTimeInterval($0) }, now: { clock })
        try await coordinator.enable(existingSessions: [])
        coordinator.observe(session, assistant: assistant)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(sources, [first.id, second.id])
        coordinator.disable()
    }

    @MainActor
    func testEstimatedTimingCannotProvePostConsentCapture() async throws {
        let assistant = assistant(self)
        var clock = Date.now
        let consent = clock
        var sentTexts: [String] = []
        let connection = syntheticCloudConnection()
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true },
            prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { request, _ in
                sentTexts += request.fragments.map(\.text)
                return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
            }, wait: { clock.addTimeInterval($0) }, now: { clock })
        defer { coordinator.disable() }
        try await coordinator.enable(existingSessions: [])
        // Queued pre-consent audio can carry a callback estimate just after consent.
        var queued = TranscriptSegment(createdAt: consent.addingTimeInterval(10), audioStartedAt: consent.addingTimeInterval(10),
                                       text: "Uppskattad tid nära samtycket.", containsMio: false, audioTimingIsValid: false)
        queued.timingValidity = .estimated
        var reliable = TranscriptSegment(createdAt: consent.addingTimeInterval(11), audioStartedAt: consent.addingTimeInterval(11),
                                         text: "Värdtid efter samtycket.", containsMio: false)
        reliable.timingValidity = .hostTime
        var late = TranscriptSegment(createdAt: consent.addingTimeInterval(70), audioStartedAt: consent.addingTimeInterval(70),
                                     text: "Uppskattad tid efter minnesgränsen.", containsMio: false, audioTimingIsValid: false)
        late.timingValidity = .estimated
        coordinator.observe(MioSession(transcripts: [queued, reliable, late]), assistant: assistant)
        for _ in 0..<20_000 { if sentTexts.count >= 2 { break }; await Task.yield() }
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(Set(sentTexts), ["Värdtid efter samtycket.", "Uppskattad tid efter minnesgränsen."])
        XCTAssertTrue(MioAnalysisCoordinator.captured(reliable, after: consent))
        XCTAssertFalse(MioAnalysisCoordinator.captured(queued, after: consent))
    }

    @MainActor
    func testFinalDrainIncludesTextDeliveredWhileStoppingAndSkipsSoftDelay() async throws {
        let assistant = assistant(self)
        var clock = Date.now
        let start = clock
        var session = MioSession(transcripts: [TranscriptSegment(createdAt: clock, text: "Vi ses", containsMio: false)])
        let done = expectation(description: "Final text kept")
        let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/ask")!, token: "synthetic")
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { request, _ in
            XCTAssertEqual(request.fragments.map(\.text), ["Vi ses", "på biblioteket"])
            XCTAssertLessThanOrEqual(clock.timeIntervalSince(start), 60)
            done.fulfill()
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
        }, wait: { clock.addTimeInterval($0) }, now: { clock })
        try await coordinator.enable(existingSessions: [])
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
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { request, _ in
            calls += 1
            XCTAssertEqual(request.fragments.map(\.text), ["Vi ses", "på biblioteket"])
            done.fulfill()
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
        }, wait: { _ in
            waiting.fulfill()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled.fulfill(); throw error }
        })
        try await coordinator.enable(existingSessions: [])
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
        let coordinator = MioAnalysisCoordinator(loadConnection: { connection }, configurationMatches: { _ in true }, prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { _, _ in
            if modelStarts.isEmpty { clock.addTimeInterval(40) }
            modelStarts.append(clock)
            if modelStarts.count == 2 {
                XCTAssertGreaterThanOrEqual(modelStarts[1].timeIntervalSince(modelStarts[0]), 60)
                done.fulfill()
            }
            return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
        }, wait: { clock.addTimeInterval($0) }, now: { clock })
        try await coordinator.enable(existingSessions: [])
        let segments = (0..<2).map { _ in TranscriptSegment(createdAt: clock, text: String(repeating: "A", count: 3399) + ".", containsMio: false) }
        coordinator.observe(MioSession(transcripts: segments), assistant: assistant)
        await fulfillment(of: [done], timeout: 2)
        coordinator.disable()
    }

    @MainActor
    func testChangedRevisionDisablesConsentBeforeSendingNewText() async throws {
        let assistant = assistant(self)
        var preparations = 0
        var sends = 0
        let coordinator = MioAnalysisCoordinator(loadConnection: { syntheticCloudConnection() }, configurationMatches: { _ in true },
            prepareConnection: { connection, task in
                preparations += 1
                let status = syntheticGatewayStatus(revision: preparations == 1 ? "a" : "b")
                try status.requireTask(task)
                var selected = connection; selected.observedConfigurationRevision = status.configurationRevision
                return .init(connection: selected, status: status)
            }, send: { _, _ in sends += 1; return MioAnalysisResult(candidates: [], highlights: [], uncertainties: []) }, wait: { _ in })
        try await coordinator.enable(existingSessions: [])
        coordinator.observe(MioSession(transcripts: [TranscriptSegment(text: "Syntetiskt nytt underlag.", containsMio: false)]), assistant: assistant)
        for _ in 0..<10_000 { if !coordinator.enabled { break }; await Task.yield() }
        XCTAssertFalse(coordinator.enabled)
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(assistant.analyses.isEmpty)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    @MainActor
    func testShortQuotaPauseKeepsTextAndResumesAfterRetryAfter() async throws {
        let assistant = assistant(self)
        var clock = Date.now
        let start = clock
        var sends: [Date] = []
        let coordinator = MioAnalysisCoordinator(loadConnection: { syntheticCloudConnection() }, configurationMatches: { _ in true },
            prepareConnection: { try await syntheticPreparedConnection($0, task: $1) },
            send: { request, _ in
                sends.append(clock)
                if sends.count == 1 { throw MioCloudError.gatewayRateLimited(.localMinuteLimit, 9) }
                XCTAssertEqual(request.fragments.map(\.text), ["Syntetiskt underlag."])
                return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
            },
            wait: { clock.addTimeInterval($0) }, now: { clock })
        try await coordinator.enable(existingSessions: [])
        coordinator.observe(MioSession(transcripts: [TranscriptSegment(createdAt: clock, text: "Syntetiskt underlag.", containsMio: false)]), assistant: assistant)
        for _ in 0..<20_000 { if coordinator.sentBatches == 1 || !coordinator.enabled { break }; await Task.yield() }
        XCTAssertTrue(coordinator.enabled, "A quota pause must not switch AI off")
        XCTAssertEqual(coordinator.sentBatches, 1)
        XCTAssertEqual(sends.count, 2)
        XCTAssertEqual(coordinator.pausedUntil, start.addingTimeInterval(309))
        // The retry honours Retry-After and the minute spacing after the failed call.
        XCTAssertGreaterThanOrEqual(sends[1].timeIntervalSince(sends[0]), 60)
        XCTAssertGreaterThanOrEqual(sends[1], start.addingTimeInterval(309))
        coordinator.disable()
    }

    @MainActor
    func testTokenLimitPausesUntilRetryAfterAndSkipsTextMeanwhile() async throws {
        let assistant = assistant(self)
        var clock = Date.now
        var sentTexts: [String] = []
        let coordinator = MioAnalysisCoordinator(loadConnection: { syntheticCloudConnection() }, configurationMatches: { _ in true },
            prepareConnection: { connection, _ in
                var selected = connection
                selected.observedConfigurationRevision = String(repeating: "a", count: 64)
                let valid = syntheticGatewayStatus()
                let status = MioGatewayStatusV2(protocolVersion: valid.protocolVersion, release: valid.release,
                    configurationRevision: valid.configurationRevision, tasks: valid.tasks,
                    quota: .init(limit: 190_000, remaining: nil, resetAt: nil))
                return .init(connection: selected, status: status)
            }, send: { request, _ in
                sentTexts += request.fragments.map(\.text)
                if sentTexts.count == 1 { throw MioCloudError.gatewayRateLimited(.localTokenLimit, 3_600) }
                return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
            },
            wait: { clock.addTimeInterval($0) }, now: { clock })
        try await coordinator.enable(existingSessions: [])
        var session = MioSession(transcripts: [TranscriptSegment(createdAt: clock, text: "Före gränsen.", containsMio: false)])
        coordinator.observe(session, assistant: assistant)
        for _ in 0..<20_000 { if coordinator.pausedUntil != nil && !coordinator.isWorking { break }; await Task.yield() }
        let deadline = try XCTUnwrap(coordinator.pausedUntil)
        XCTAssertEqual(deadline.timeIntervalSince(clock), 3_600, accuracy: 0.01)
        XCTAssertTrue(coordinator.enabled)
        XCTAssertTrue(coordinator.status.contains("AI fortsätter kl."))
        session.transcripts.append(TranscriptSegment(createdAt: clock.addingTimeInterval(5), text: "Under pausen.", containsMio: false))
        coordinator.observe(session, assistant: assistant)
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(sentTexts, ["Före gränsen."], "Text during a long quota pause stays local and is not queued")
        clock = deadline.addingTimeInterval(1)
        session.transcripts.append(TranscriptSegment(createdAt: clock, text: "Efter pausen.", containsMio: false))
        coordinator.observe(session, assistant: assistant)
        for _ in 0..<20_000 { if sentTexts.count == 2 { break }; await Task.yield() }
        XCTAssertEqual(sentTexts, ["Före gränsen.", "Efter pausen."])
        coordinator.disable()
    }

    @MainActor
    func testChangedCredentialsDuringUncancellableModelRequestCannotPersist() async throws {
        let assistant = assistant(self)
        var matches = true
        var clock = Date.now
        var responseReady = false
        let coordinator = MioAnalysisCoordinator(loadConnection: { syntheticCloudConnection() }, configurationMatches: { _ in matches },
            prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { _, _ in
                matches = false
                responseReady = true
                return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
            }, wait: { clock.addTimeInterval($0) }, now: { clock })
        try await coordinator.enable(existingSessions: [])
        coordinator.observe(MioSession(transcripts: [TranscriptSegment(createdAt: clock, text: "Syntetiskt underlag.", containsMio: false)]), assistant: assistant)
        for _ in 0..<10_000 { if responseReady && !coordinator.isWorking { break }; await Task.yield() }
        XCTAssertTrue(responseReady)
        XCTAssertTrue(assistant.analyses.isEmpty, "A response from the superseded connection may not become local content")
        XCTAssertEqual(coordinator.sentBatches, 0)
        XCTAssertFalse(coordinator.enabled)
        coordinator.disable()
    }

    @MainActor
    func testLockedKeychainWaitsForUnlockInsteadOfDroppingQueuedText() async throws {
        let assistant = assistant(self)
        var clock = Date.now
        var readable = true
        var unlockWaits = 0
        let sent = expectation(description: "Queued text is sent after unlock")
        let coordinator = MioAnalysisCoordinator(loadConnection: { syntheticCloudConnection() }, configurationMatches: { _ in readable },
            prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { request, _ in
                XCTAssertEqual(request.fragments.map(\.text), ["Telefonen är låst."])
                sent.fulfill()
                return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
            }, wait: { clock.addTimeInterval($0) }, now: { clock },
            credentialsReadable: { readable }, waitForUnlock: { unlockWaits += 1; readable = true },
            consentLog: { MioAIConsentLog() }, recordConsent: { _, _, _ in })
        defer { coordinator.disable() }
        try await coordinator.enable(existingSessions: [])
        // The phone locks while the five-minute batch is collecting.
        readable = false
        coordinator.observe(MioSession(transcripts: [TranscriptSegment(createdAt: clock, text: "Telefonen är låst.", containsMio: false)]),
                            assistant: assistant)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(unlockWaits, 1)
        for _ in 0..<10_000 { if coordinator.sentBatches == 1 { break }; await Task.yield() }
        XCTAssertTrue(coordinator.enabled, "A locked Keychain is not a changed pairing")
        XCTAssertEqual(assistant.analyses.count, 1)
    }

    @MainActor
    func testRestartCatchesUpUnsentEverydayTextCapturedWhileAIWasOn() async throws {
        let assistant = assistant(self)
        var clock = Date.now
        let base = clock
        var log = MioAIConsentLog()
        log.record(.on, at: base.addingTimeInterval(-3_600))
        log.record(.skipped, at: base.addingTimeInterval(-1_500), until: base.addingTimeInterval(-1_400))
        func segment(_ offset: TimeInterval, _ text: String) -> TranscriptSegment {
            TranscriptSegment(createdAt: base.addingTimeInterval(offset), text: text, containsMio: false)
        }
        let everyday = MioSession(startedAt: base.addingTimeInterval(-4_000), endedAt: base.addingTimeInterval(-600), transcripts: [
            segment(-3_900, "Före samtycket."), segment(-1_800, "Osänt vardagstal."),
            segment(-1_450, "Under kvotpausen."), segment(-900, "Mer osänt tal.")])
        let lesson = MioSession(startedAt: base.addingTimeInterval(-3_000), endedAt: base.addingTimeInterval(-2_000),
                                transcripts: [segment(-2_500, "Lektionstext.")], captureMode: .lesson)
        let old = MioSession(startedAt: base.addingTimeInterval(-50_000), endedAt: base.addingTimeInterval(-49_000),
                             transcripts: [segment(-49_500, "För gammalt.")])
        var sends: [[String]] = []
        var sendTimes: [Date] = []
        let coordinator = MioAnalysisCoordinator(loadConnection: { syntheticCloudConnection() }, configurationMatches: { _ in true },
            prepareConnection: { try await syntheticPreparedConnection($0, task: $1) }, send: { request, _ in
                sends.append(request.fragments.map(\.text)); sendTimes.append(clock)
                return MioAnalysisResult(candidates: [], highlights: [], uncertainties: [])
            }, wait: { clock.addTimeInterval($0) }, now: { clock },
            consentLog: { log }, recordConsent: { log.record($0, at: $1, until: $2) })
        defer { coordinator.disable() }
        try await coordinator.enable(existingSessions: [old, everyday, lesson], assistant: assistant)
        for _ in 0..<10_000 { if coordinator.sentBatches == 2 { break }; await Task.yield() }
        XCTAssertEqual(sends, [["Osänt vardagstal."], ["Mer osänt tal."]],
                       "Only unsent everyday text inside consent; a skipped interval splits the context")
        XCTAssertEqual(sendTimes.first, base, "Caught-up text of an ended session does not wait for a new window")

        // Analysed text is never sent again on the next start.
        coordinator.disable()
        try await coordinator.enable(existingSessions: [old, everyday, lesson], assistant: assistant)
        for _ in 0..<1_000 { await Task.yield() }
        XCTAssertEqual(sends.count, 2)
        XCTAssertFalse(coordinator.isWorking)
    }
}
