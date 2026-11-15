import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Mio

final class MioAnalysisScheduleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testFirstEverydayTextWaitsForTheFiveMinuteBatch() {
        let input = MioAnalysisSchedule.Input(kind: .everyday, enqueuedAt: at(0))
        XCTAssertEqual(MioAnalysisSchedule.nextSendTime(input, now: at(0)), at(300))
        XCTAssertEqual(MioAnalysisSchedule.nextSendTime(input, now: at(400)), at(400), "Never earlier than now")
    }

    func testNewWindowOpensAtMostEveryFiveMinutes() {
        // Text queued after the last window opened waits for both its own batch and the window.
        let input = MioAnalysisSchedule.Input(kind: .everyday, enqueuedAt: at(10), lastSentAt: at(20), windowOpenedAt: at(0))
        XCTAssertEqual(MioAnalysisSchedule.nextSendTime(input, now: at(20)), at(310))
        let late = MioAnalysisSchedule.Input(kind: .everyday, enqueuedAt: at(500), lastSentAt: at(20), windowOpenedAt: at(0))
        XCTAssertEqual(MioAnalysisSchedule.nextSendTime(late, now: at(500)), at(800))
    }

    func testRequestsOfAnOpenWindowFollowEachOtherWithMinuteSpacing() {
        let input = MioAnalysisSchedule.Input(kind: .everyday, enqueuedAt: at(0), lastSentAt: at(310), windowOpenedAt: at(300))
        XCTAssertEqual(MioAnalysisSchedule.nextSendTime(input, now: at(310)), at(370))
    }

    func testPauseOrStopDrainsWithoutTheWindowButKeepsSpacing() {
        let fresh = MioAnalysisSchedule.Input(kind: .everyday, enqueuedAt: at(100), isFinal: true, windowOpenedAt: at(0))
        XCTAssertEqual(MioAnalysisSchedule.nextSendTime(fresh, now: at(100)), at(100))
        let recent = MioAnalysisSchedule.Input(kind: .everyday, enqueuedAt: at(100), isFinal: true, lastSentAt: at(90))
        XCTAssertEqual(MioAnalysisSchedule.nextSendTime(recent, now: at(100)), at(150))
    }

    func testLessonPartsUseTheServerIntervalOfAtLeastSixtySeconds() {
        let first = MioAnalysisSchedule.Input(kind: .lesson, enqueuedAt: at(0))
        XCTAssertEqual(MioAnalysisSchedule.nextSendTime(first, now: at(0)), at(0))
        let slower = MioAnalysisSchedule.Input(kind: .lesson, enqueuedAt: at(0), lastSentAt: at(10), lessonInterval: 120)
        XCTAssertEqual(MioAnalysisSchedule.nextSendTime(slower, now: at(10)), at(130))
        let tooFast = MioAnalysisSchedule.Input(kind: .lesson, enqueuedAt: at(0), lastSentAt: at(10), lessonInterval: 5)
        XCTAssertEqual(MioAnalysisSchedule.nextSendTime(tooFast, now: at(10)), at(70))
    }

    func testRetryAfterDelaysEveryKindOfWork() {
        for kind in [MioAnalysisSchedule.Kind.everyday, .lesson] {
            let input = MioAnalysisSchedule.Input(kind: kind, enqueuedAt: at(0), isFinal: true, pausedUntil: at(3_600))
            XCTAssertEqual(MioAnalysisSchedule.nextSendTime(input, now: at(5)), at(3_600))
        }
        let expired = MioAnalysisSchedule.Input(kind: .lesson, enqueuedAt: at(0), pausedUntil: at(1))
        XCTAssertEqual(MioAnalysisSchedule.nextSendTime(expired, now: at(5)), at(5))
    }

    func testRetryDeadlinesFollowRetryAfterAndQuotaReset() {
        let now = at(0)
        XCTAssertEqual(MioAnalysisSchedule.retryDeadline(after: MioCloudError.rateLimited(30), now: now, quotaResetAt: nil), at(30))
        XCTAssertEqual(MioAnalysisSchedule.retryDeadline(after: MioCloudError.gatewayRateLimited(.localMinuteLimit, 9),
                                                         now: now, quotaResetAt: at(9_000)), at(9))
        XCTAssertEqual(MioAnalysisSchedule.retryDeadline(after: MioCloudError.gatewayRateLimited(.localTokenLimit, 60),
                                                         now: now, quotaResetAt: at(9_000)), at(9_000))
        XCTAssertEqual(MioAnalysisSchedule.retryDeadline(after: MioCloudError.gatewayRateLimited(.localDayLimit, 9_500),
                                                         now: now, quotaResetAt: at(9_000)), at(9_500))
        XCTAssertEqual(MioAnalysisSchedule.retryDeadline(after: MioCloudError.gatewayRateLimited(.localTokenLimit, 120),
                                                         now: now, quotaResetAt: nil), at(120))
        XCTAssertEqual(MioAnalysisSchedule.retryDeadline(after: MioCloudError.network, now: now, quotaResetAt: nil), at(300))
        XCTAssertNil(MioAnalysisSchedule.retryDeadline(after: MioCloudError.invalidResponse, now: now, quotaResetAt: nil))
        XCTAssertNil(MioAnalysisSchedule.retryDeadline(after: CancellationError(), now: now, quotaResetAt: nil))
        XCTAssertFalse(MioAnalysisSchedule.dropsEverydayWork(pausedUntil: at(300), now: now))
        XCTAssertTrue(MioAnalysisSchedule.dropsEverydayWork(pausedUntil: at(301), now: now))
    }

    func testBriefProviderAndServerFailuresPauseForAMinuteInsteadOfStoppingAI() {
        let now = at(0)
        for code in [MioGatewayErrorCode.upstreamTimeout, .requestTimeout, .providerInfrastructure, .providerTransport, .upstreamUnavailable] {
            XCTAssertEqual(MioAnalysisSchedule.retryDeadline(after: MioCloudError.gateway(502, code), now: now, quotaResetAt: nil), at(60), "\(code)")
        }
        for status in [502, 503, 504] {
            XCTAssertEqual(MioAnalysisSchedule.retryDeadline(after: MioCloudError.serverStatus(status), now: now, quotaResetAt: nil), at(60))
        }
        // Errors that need the user stay errors.
        for error in [MioCloudError.serverStatus(401), .gateway(422, .providerModelUnavailable), .gateway(502, .providerAuthentication),
                      .gateway(409, .configurationChanged), .gateway(413, .providerRequestTooLarge), .incompatibleGateway] {
            XCTAssertNil(MioAnalysisSchedule.retryDeadline(after: error, now: now, quotaResetAt: nil), "\(error)")
        }
    }

    func testRepeatedShortPausesBackOffToOneWindowAndLongWaitsAreKept() {
        let now = at(0)
        XCTAssertEqual(MioAnalysisSchedule.backoff(at(60), now: now, consecutivePauses: 0), at(60))
        XCTAssertEqual(MioAnalysisSchedule.backoff(at(60), now: now, consecutivePauses: 1), at(120))
        XCTAssertEqual(MioAnalysisSchedule.backoff(at(60), now: now, consecutivePauses: 2), at(240))
        XCTAssertEqual(MioAnalysisSchedule.backoff(at(60), now: now, consecutivePauses: 3), at(300))
        XCTAssertEqual(MioAnalysisSchedule.backoff(at(60), now: now, consecutivePauses: 50), at(300))
        // A quota reset hours away is neither shortened nor stretched, and the queue rule
        // (drop everyday work only beyond one window) is unaffected.
        XCTAssertEqual(MioAnalysisSchedule.backoff(at(9_000), now: now, consecutivePauses: 3), at(9_000))
        XCTAssertEqual(MioAnalysisSchedule.backoff(at(300), now: now, consecutivePauses: 3), at(300))
        XCTAssertFalse(MioAnalysisSchedule.dropsEverydayWork(pausedUntil: MioAnalysisSchedule.backoff(at(60), now: now, consecutivePauses: 9), now: now))
    }

    func testAQuestionWaitsOutShortLimitsAndBriefFailuresButNotDayLimitsOrRealErrors() {
        XCTAssertEqual(MioAnalysisSchedule.questionRetrySeconds(after: MioCloudError.gatewayRateLimited(.providerQuota, 12)), 12)
        XCTAssertEqual(MioAnalysisSchedule.questionRetrySeconds(after: MioCloudError.gatewayRateLimited(.localMinuteLimit, 60)), 60)
        XCTAssertEqual(MioAnalysisSchedule.questionRetrySeconds(after: MioCloudError.rateLimited(90)), 90)
        XCTAssertEqual(MioAnalysisSchedule.questionRetrySeconds(after: MioCloudError.gateway(409, .configurationChanged)), 0)
        XCTAssertEqual(MioAnalysisSchedule.questionRetrySeconds(after: MioCloudError.changedConfiguration), 0)
        XCTAssertEqual(MioAnalysisSchedule.questionRetrySeconds(after: MioCloudError.gateway(504, .upstreamTimeout)), 3)
        XCTAssertEqual(MioAnalysisSchedule.questionRetrySeconds(after: MioCloudError.serverStatus(502)), 3)
        for error in [MioCloudError.rateLimited(91), .gatewayRateLimited(.providerQuota, 600), .gatewayRateLimited(.localTokenLimit, 30),
                      .gatewayRateLimited(.localDayLimit, 30), .gateway(413, .providerRequestTooLarge), .gateway(502, .providerRefusal),
                      .serverStatus(401), .network, .invalidResponse] {
            XCTAssertNil(MioAnalysisSchedule.questionRetrySeconds(after: error), "\(error)")
        }
        XCTAssertNil(MioAnalysisSchedule.questionRetrySeconds(after: CancellationError()))
    }

    func testOnlyFailuresBeforeTheConnectionExistsAreRetriedAndAtMostThreeTimes() {
        // Cannot find host / cannot connect / DNS / not connected / TLS: nothing was sent.
        for code in [-1003, -1004, -1006, -1009, -1200] {
            XCTAssertEqual(MioCloudRetry.delay(urlErrorCode: code, attempt: 1), 1)
            XCTAssertEqual(MioCloudRetry.delay(urlErrorCode: code, attempt: 2), 2.5)
            XCTAssertEqual(MioCloudRetry.delay(urlErrorCode: code, attempt: 3), 5)
            XCTAssertNil(MioCloudRetry.delay(urlErrorCode: code, attempt: 4))
            XCTAssertNil(MioCloudRetry.delay(urlErrorCode: code, attempt: 0))
        }
        // Timed out (-1001) and connection lost (-1005) may have reached the gateway: a blind
        // resend could run the model twice. Cancelled (-999) is the user's choice.
        for code in [-1001, -1005, -999, -1011, 0] { XCTAssertNil(MioCloudRetry.delay(urlErrorCode: code, attempt: 1)) }
    }

    func testTooLargeAndCutOffAnswersAskForASmallerRequestAndBatchesShrinkByHalves() {
        XCTAssertTrue(MioWorkSplit.needsSmallerRequest(MioCloudError.gateway(413, .providerRequestTooLarge)))
        XCTAssertTrue(MioWorkSplit.needsSmallerRequest(MioCloudError.gateway(502, .providerTruncated)))
        XCTAssertTrue(MioWorkSplit.needsSmallerRequest(MioCloudError.serverStatus(413)))
        for error in [MioCloudError.gatewayRateLimited(.providerQuota, 60), .rateLimited(60), .network, .invalidResponse,
                      .gateway(502, .invalidAnalysisResult)] {
            XCTAssertFalse(MioWorkSplit.needsSmallerRequest(error), "\(error)")
        }
        let fragments = (0..<12).map { MioAnalysisFragment(id: "\(UUID().uuidString):\($0)", text: String(repeating: "a", count: 1_000), occurredAt: "2026-11-15T10:00:00Z") }
        XCTAssertEqual(MioEverydayContext.batches(fragments).map(\.count), [5, 5, 2])
        XCTAssertEqual(MioEverydayContext.batches(fragments, backlog: true).map(\.count), [12])
        XCTAssertEqual(MioEverydayContext.batches(fragments, shrink: 1).map(\.count), [2, 2, 2, 2, 2, 2])
        // A shrunk batch never grows back into a backlog batch.
        XCTAssertEqual(MioEverydayContext.batches(fragments, backlog: true, shrink: 1).map(\.count), [2, 2, 2, 2, 2, 2])
        XCTAssertEqual(MioEverydayContext.batches(fragments, shrink: 3).map(\.count), Array(repeating: 1, count: 12))
        XCTAssertEqual(MioEverydayContext.batches(fragments, shrink: 99).map(\.count), Array(repeating: 1, count: 12))
        XCTAssertEqual(MioEverydayContext.batches(Array(fragments.prefix(4)), shrink: 1).map(\.count), [2, 2])
    }

    func testTokenLimitResponseBecomesAGatewayRateLimit() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://pc.tail.ts.net:8443/v2/analyze")!, statusCode: 429,
            httpVersion: nil, headerFields: ["Content-Type": "application/json", "Retry-After": "3600"]))
        let failure = MioCloudService.httpFailure(response: response, body: Data("{\"error\":\"local_token_limit\"}".utf8))
        guard case .gatewayRateLimited(.localTokenLimit, 3_600) = failure.error else {
            return XCTFail("local_token_limit must keep its Retry-After")
        }
    }
}
