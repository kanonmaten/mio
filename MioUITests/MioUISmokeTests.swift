import XCTest

/// Native simulator/device smoke coverage. These tests never press capture,
/// permissions, AI-send, or destructive controls, and never hand anything to Apple's apps.
/// Run in a test simulator; Linux cannot run it.
final class MioUISmokeTests: XCTestCase {
    @MainActor
    func testThreeTabsPlusCaptureButtonAndIndependentActivityStates() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        for title in ["Hem", "Lektioner", "Förslag"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.exists, "Missing native tab: \(title)")
            tab.tap()
        }
        // The capture tab uses the separate trailing tab-bar button, so look it up app-wide.
        let capture = app.buttons["Fånga"].firstMatch
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        capture.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mio.microphone-state"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["mio.transcription-state"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["mio.text-ai-state"].firstMatch.exists)
        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription])
    }

    @MainActor
    func testHomeMorningEveningAndSettingsNavigation() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Hem"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Hem"].tap()
        XCTAssertTrue(app.buttons["Förra veckan"].waitForExistence(timeout: 5))
        let evening = app.segmentedControls.buttons["Kväll"]
        XCTAssertTrue(evening.waitForExistence(timeout: 5))
        evening.tap()
        XCTAssertTrue(evening.isSelected)
        let morning = app.segmentedControls.buttons["Morgon"]
        morning.tap()
        XCTAssertTrue(morning.isSelected)
        let settings = app.buttons["Inställningar"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mio.settings.panel"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Dator"].firstMatch.exists, "The panel starts with the Dator section")
        let done = app.buttons["mio.settings.done"]
        XCTAssertTrue(done.exists)
        done.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mio.settings.panel"].firstMatch.waitForNonExistence(timeout: 5))
    }

    /// 0.9.1: nothing is created by hand in Mio; Förslag lists proposals and what was sent.
    @MainActor
    func testProposalsTabHasNoLocalCreationAndPassesTheAudit() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Förslag"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Förslag"].tap()
        XCTAssertTrue(app.navigationBars["Förslag"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Lägg till"].exists)
        XCTAssertFalse(app.buttons["Skriv förslag"].exists)
        XCTAssertFalse(app.tabBars.buttons["Kalender"].exists)
        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription])
    }
}
