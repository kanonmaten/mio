import XCTest

/// Native simulator/device smoke coverage. These tests never press capture,
/// permissions, AI-send, or destructive controls; one test creates a synthetic
/// task through the ordinary local UI. Run in a test simulator; Linux cannot run it.
final class MioUISmokeTests: XCTestCase {
    @MainActor
    func testFiveNativeTabsAndIndependentActivityStates() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        for title in ["Lektioner", "Kalender", "Anteckningar", "Morgon", "Mio"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.exists, "Missing native tab: \(title)")
            tab.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["mio.microphone-state"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["mio.transcription-state"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["mio.text-ai-state"].firstMatch.exists)
        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription])
    }

    @MainActor
    func testMorningEveningAndSettingsNavigation() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Morgon"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Morgon"].tap()
        let evening = app.segmentedControls.buttons["Kväll"]
        XCTAssertTrue(evening.waitForExistence(timeout: 5))
        evening.tap()
        XCTAssertTrue(app.navigationBars["Kväll"].exists)
        app.segmentedControls.buttons["Morgon"].tap()
        XCTAssertTrue(app.navigationBars["Morgon"].exists)
        app.tabBars.buttons["Mio"].tap()
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
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription])
    }
}
