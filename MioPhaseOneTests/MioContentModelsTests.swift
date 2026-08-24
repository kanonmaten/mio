import Foundation
import XCTest
@testable import MioPhaseOne

final class MioContentModelsTests: XCTestCase {
    func testAllFiveKindsRoundTripThroughCodable() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let items = MioContentKind.allCases.map { kind in
            MioContentItem(
                kind: kind,
                title: kind.title,
                body: "Svenskt innehåll",
                createdAt: date,
                scheduledAt: date,
                completedAt: date,
                sessionID: UUID()
            )
        }

        let data = try JSONEncoder().encode(items)
        let decoded = try JSONDecoder().decode([MioContentItem].self, from: data)

        XCTAssertEqual(decoded.map(\.kind), MioContentKind.allCases)
        XCTAssertEqual(decoded.count, 5)
        XCTAssertNil(decoded.first { $0.kind != .task && $0.completedAt != nil })
    }

    func testSearchIsCaseAndDiacriticInsensitive() {
        let item = MioContentItem(
            kind: .note,
            title: "Övning inför MATTEPROV",
            body: "Fråga läraren på tisdag"
        )

        XCTAssertTrue(item.matches(searchText: "ovning"))
        XCTAssertTrue(item.matches(searchText: "matteprov"))
        XCTAssertTrue(item.matches(searchText: "FRAGA"))
        XCTAssertTrue(item.matches(searchText: ""))
        XCTAssertFalse(item.matches(searchText: "historia"))
    }

    func testTimelineSortHasStableTieBreaker() {
        let date = Date(timeIntervalSince1970: 1_000)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = MioContentItem(
            id: firstID,
            kind: .timeline,
            title: "Första",
            createdAt: date,
            scheduledAt: date
        )
        let second = MioContentItem(
            id: secondID,
            kind: .timeline,
            title: "Andra",
            createdAt: date,
            scheduledAt: date
        )

        XCTAssertEqual(MioContentItem.timelineSorted([second, first]).map(\.id), [firstID, secondID])
    }

    func testSessionSearchUsesCorrectionWithoutChangingOriginalEvidence() {
        let originalStart = Date(timeIntervalSince1970: 2_000)
        let segment = TranscriptSegment(
            createdAt: originalStart,
            audioStartedAt: originalStart,
            audioEndedAt: originalStart.addingTimeInterval(3),
            text: "Matematik på torsdag",
            correctedText: "Matematik på fredag",
            containsMio: false,
            wasObservedInBackground: true
        )
        let session = PhaseOneSession(startedAt: originalStart, transcripts: [segment])

        XCTAssertTrue(session.matches(searchText: "fredag"))
        XCTAssertEqual(session.transcripts[0].text, "Matematik på torsdag")
        XCTAssertEqual(session.transcripts[0].audioStartedAt, originalStart)
        XCTAssertTrue(session.transcripts[0].wasObservedInBackground)
    }
}
