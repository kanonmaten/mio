import XCTest

/// Native simulator/device smoke coverage. These tests never press capture,
/// permissions, AI-send, or destructive controls; one test creates a synthetic
/// task through the ordinary local UI. Run in a test simulator; Linux cannot run it.
final class MioUISmokeTests: XCTestCase {
    @MainActor
    func testFourTabsPlusCaptureButtonAndIndependentActivityStates() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        for title in ["Hem", "Lektioner", "Kalender", "Anteckningar"] {
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

    @MainActor
    func testTaskCompletionHasNamedAccessibleHitArea() throws {
        // The iOS 27 simulator sometimes reports the app as busy for 60 s after a menu or tap
        // (XCTest then continues), which alone used up the default two-minute allowance.
        executionTimeAllowance = 240
        let app = XCUIApplication()
        let title = "Syntetisk uppgift \(UUID().uuidString.prefix(8))"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Anteckningar"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Anteckningar"].tap()
        app.buttons["Lägg till"].firstMatch.tap()
        app.buttons["Uppgift"].firstMatch.tap()
        let titleField = app.textFields["Rubrik"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        app.navigationBars.buttons["Spara"].firstMatch.tap()
        let incomplete = app.buttons["Markera \(title) som klar"]
        XCTAssertTrue(incomplete.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(incomplete.frame.width, 44)
        XCTAssertGreaterThanOrEqual(incomplete.frame.height, 44)
        incomplete.tap()
        let completed = app.buttons["Markera \(title) som inte klar"]
        // On failure, name what is on screen (an alert or error text) instead of a bare false.
        let visible = { app.alerts.allElementsBoundByIndex.map(\.label) + app.staticTexts.allElementsBoundByIndex.prefix(30).map(\.label) }
        XCTAssertTrue(completed.waitForExistence(timeout: 10), "Synligt: \(visible().joined(separator: " | "))")
        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription])
    }
}
