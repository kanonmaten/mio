import Foundation
import XCTest
@testable import Mio

final class MioSessionModelsTests: XCTestCase {
    func testBatteryDropUsesFirstAndLastKnownReading() {
        let session = MioSession(
            batteryReadings: [
                BatteryReading(level: -1, state: .unknown),
                BatteryReading(level: 0.82, state: .unplugged),
                BatteryReading(level: 0.76, state: .unplugged)
            ]
        )

        XCTAssertEqual(session.batteryDrop ?? 0, 0.06, accuracy: 0.001)
    }

    func testSessionCountsMioAndInterruptions() {
        let session = MioSession(
            transcripts: [
                TranscriptSegment(text: "Vanlig text", containsMio: false),
                TranscriptSegment(text: "Mio hittades", containsMio: true)
            ],
            events: [
                DiagnosticEvent(kind: .interruption, message: "början"),
                DiagnosticEvent(kind: .interruption, message: "slut"),
                DiagnosticEvent(kind: .info, message: "övrigt")
            ]
        )

        XCTAssertEqual(session.mioDetectionCount, 1)
        XCTAssertEqual(session.interruptionCount, 2)
    }

    func testPauseLengths() {
        XCTAssertEqual(PauseLength.thirtyMinutes.interval, 1_800)
        XCTAssertEqual(PauseLength.oneHour.interval, 3_600)
        XCTAssertNil(PauseLength.untilResumed.interval)
    }

    func testBackgroundIntervalRequiresRealAudioOverlap() {
        let start = Date(timeIntervalSince1970: 1_000)
        let interval = BackgroundInterval(
            startedAt: start.addingTimeInterval(10),
            endedAt: start.addingTimeInterval(20)
        )

        XCTAssertTrue(
            interval.overlaps(
                audioStart: start.addingTimeInterval(12),
                audioEnd: start.addingTimeInterval(14)
            )
        )
        XCTAssertFalse(
            interval.overlaps(
                audioStart: start.addingTimeInterval(1),
                audioEnd: start.addingTimeInterval(5)
            )
        )
    }

    func testLegacySessionJSONDecodesWithoutOptionalMetadata() throws {
        let legacyJSON = #"{"id":"00000000-0000-0000-0000-000000000001","startedAt":"2026-08-20T20:29:02Z","endedAt":"2026-08-20T20:31:32Z","transcripts":[{"id":"00000000-0000-0000-0000-000000000002","createdAt":"2026-08-20T20:30:00Z","audioStartedAt":"2026-08-20T20:30:00Z","audioEndedAt":"2026-08-20T20:30:02Z","text":"Hej Mio","containsMio":true,"wasObservedInBackground":false,"audioTimingIsValid":true}],"events":[],"batteryReadings":[],"backgroundIntervals":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let session = try decoder.decode(MioSession.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(session.title)
        XCTAssertNil(session.manualNote)
        XCTAssertEqual(session.transcripts.first?.text, "Hej Mio")
        XCTAssertNil(session.transcripts.first?.correctedText)
        XCTAssertNil(session.transcripts.first?.correctionRevision)
        XCTAssertNil(session.mutationRevision)
    }

    func testSessionRegisterRetainsSuspendedEverydayWhenLessonIsSelected() {
        var register = MioSessionRegister()
        let everyday = MioSession(startedAt: Date(timeIntervalSince1970: 1_000), title: "Vardag")
        register.current = everyday
        var lesson = MioSession(startedAt: Date(timeIntervalSince1970: 2_000), title: "Lektion", captureMode: .lesson)
        register.current = lesson
        lesson.endedAt = Date(timeIntervalSince1970: 2_010)
        register.current = lesson
        register.current = register.sessions.first { $0.id == everyday.id }
        XCTAssertEqual(register.current?.id, everyday.id)
        XCTAssertNil(register.current?.endedAt)
        XCTAssertEqual(Set(register.sessions.map(\.id)), Set([everyday.id, lesson.id]))
        XCTAssertEqual(register.sessions.first { $0.id == lesson.id }?.endedAt, Date(timeIntervalSince1970: 2_010))
    }

    func testInPlaceMutationKeepsOrderingSelectionAndOtherSessions() {
        var register = MioSessionRegister()
        let older = MioSession(startedAt: Date(timeIntervalSince1970: 1_000), title: "Äldre")
        let newer = MioSession(startedAt: Date(timeIntervalSince1970: 3_000), title: "Nyare")
        register.current = older
        register.current = newer
        register.current = MioSession(startedAt: Date(timeIntervalSince1970: 2_000), title: "Mitten")
        register.current?.transcripts.append(TranscriptSegment(text: "Syntetisk text", containsMio: false))
        register.current?.title = "Mitten ändrad"
        XCTAssertEqual(register.sessions.map(\.title), ["Nyare", "Mitten ändrad", "Äldre"])
        XCTAssertEqual(register.current?.transcripts.count, 1)
        register.current = nil
        register.current?.title = "Ingen vald"
        XCTAssertNil(register.current)
        XCTAssertEqual(register.sessions.count, 3, "deselecting keeps every session in the register")
    }

    func testSessionRegisterRejectsOlderMutationResults() {
        var register = MioSessionRegister()
        var original = MioSession(title: "Äldre")
        original.mutationRevision = 1
        register.current = original
        var latest = original; latest.title = "Nyare"; latest.mutationRevision = 2
        register.replace(latest)
        register.replace(original)
        XCTAssertEqual(register.current?.title, "Nyare")
        register.remove(id: original.id)
        XCTAssertNil(register.current)
        XCTAssertTrue(register.sessions.isEmpty)
    }
}
