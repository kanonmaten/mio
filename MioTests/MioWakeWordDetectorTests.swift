import XCTest
@testable import Mio

/// Since 2026-11-20 only "Mio, kom ihåg" and "Mio, notera" at the start of a sentence count as
/// direct address; a lone "Mio" does not.
final class MioWakeWordDetectorTests: XCTestCase {
    func testDetectsBothWakePhrases() {
        XCTAssertTrue(MioWakeWordDetector.containsWakeWord(in: "Mio, kom ihåg att köpa mjölk."))
        XCTAssertTrue(MioWakeWordDetector.containsWakeWord(in: "MIO NOTERA det här!"))
        XCTAssertTrue(MioWakeWordDetector.containsWakeWord(in: "Vi har rast. Mio kom ihåg läxan."))
        XCTAssertTrue(MioWakeWordDetector.containsWakeWord(in: "Mio, komihåg gympapåsen"))
    }

    func testALoneMioIsNotDirectAddress() {
        XCTAssertFalse(MioWakeWordDetector.containsWakeWord(in: "Mio, vad är klockan?"))
        XCTAssertFalse(MioWakeWordDetector.containsWakeWord(in: "hej MIO!"))
        XCTAssertFalse(MioWakeWordDetector.containsWakeWord(in: "Mio, påminn mig om läxan."))
        XCTAssertFalse(MioWakeWordDetector.containsWakeWord(in: "Jag sa Mio, kom ihåg det."), "not at the start of a sentence")
        XCTAssertFalse(MioWakeWordDetector.containsWakeWord(in: "Mio, noterade du det?"))
    }

    func testDoesNotDetectMioInsideAnotherWord() {
        XCTAssertFalse(MioWakeWordDetector.containsWakeWord(in: "Miodrag, kom ihåg boken."))
        XCTAssertFalse(MioWakeWordDetector.containsWakeWord(in: "Mios kom ihåg-lista."))
        XCTAssertFalse(MioWakeWordDetector.containsWakeWord(in: "Ingen väckningsfras här."))
    }

    func testHandlesSwedishPunctuation() {
        XCTAssertTrue(MioWakeWordDetector.containsWakeWord(in: "—Mio—kom ihåg tandläkaren."))
        XCTAssertTrue(MioWakeWordDetector.containsWakeWord(in: "Mio: notera att provet är på fredag."))
        XCTAssertTrue(MioWakeWordDetector.containsWakeWord(in: "Klart.\nMio. Notera sidan tolv."))
    }
}
