import Foundation
import XCTest
@testable import MioPhaseTwo

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

    func testSpeechTranscriberRequiresInstalledAsset() {
        XCTAssertTrue(
            SpeechCapabilityService.shouldUseSpeechTranscriber(assetState: .installed)
        )
        XCTAssertFalse(
            SpeechCapabilityService.shouldUseSpeechTranscriber(assetState: .supported)
        )
        XCTAssertFalse(
            SpeechCapabilityService.shouldUseSpeechTranscriber(assetState: .downloading)
        )
        XCTAssertFalse(
            SpeechCapabilityService.shouldUseSpeechTranscriber(assetState: .unsupported)
        )
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

    func testLegacySessionJSONDecodesWithoutPhaseTwoMetadata() throws {
        let legacyJSON = #"{"id":"00000000-0000-0000-0000-000000000001","startedAt":"2026-08-20T20:29:02Z","endedAt":"2026-08-20T20:31:32Z","transcripts":[{"id":"00000000-0000-0000-0000-000000000002","createdAt":"2026-08-20T20:30:00Z","audioStartedAt":"2026-08-20T20:30:00Z","audioEndedAt":"2026-08-20T20:30:02Z","text":"Hej Mio","containsMio":true,"wasObservedInBackground":false,"audioTimingIsValid":true}],"events":[],"batteryReadings":[],"backgroundIntervals":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let session = try decoder.decode(MioSession.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(session.title)
        XCTAssertNil(session.manualNote)
        XCTAssertEqual(session.transcripts.first?.text, "Hej Mio")
        XCTAssertNil(session.transcripts.first?.correctedText)
    }
}
