import XCTest
@testable import MioPhaseOne

final class MioWakeWordDetectorTests: XCTestCase {
    func testDetectsMioAsAWord() {
        XCTAssertTrue(MioWakeWordDetector.containsWakeWord(in: "Mio, vad är klockan?"))
        XCTAssertTrue(MioWakeWordDetector.containsWakeWord(in: "hej MIO!"))
        XCTAssertTrue(MioWakeWordDetector.containsWakeWord(in: "Kan du komma ihåg det, mío?"))
    }

    func testDoesNotDetectMioInsideAnotherWord() {
        XCTAssertFalse(MioWakeWordDetector.containsWakeWord(in: "Det är ett miodrag i texten."))
        XCTAssertFalse(MioWakeWordDetector.containsWakeWord(in: "Hermione läser."))
        XCTAssertFalse(MioWakeWordDetector.containsWakeWord(in: "Ingen väckningsfras här."))
    }

    func testHandlesSwedishPunctuation() {
        XCTAssertTrue(MioWakeWordDetector.containsWakeWord(in: "—Mio—lägg till tandläkaren."))
        XCTAssertTrue(MioWakeWordDetector.containsWakeWord(in: "(Mio) påminn mig."))
    }
}
