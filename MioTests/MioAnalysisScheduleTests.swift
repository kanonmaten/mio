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

    func testTokenLimitResponseBecomesAGatewayRateLimit() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://pc.tail.ts.net:8443/v2/analyze")!, statusCode: 429,
            httpVersion: nil, headerFields: ["Content-Type": "application/json", "Retry-After": "3600"]))
        let failure = MioCloudService.httpFailure(response: response, body: Data("{\"error\":\"local_token_limit\"}".utf8))
        guard case .gatewayRateLimited(.localTokenLimit, 3_600) = failure.error else {
            return XCTFail("local_token_limit must keep its Retry-After")
        }
    }
}
