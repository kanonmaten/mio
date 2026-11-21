import XCTest

/// Native simulator/device smoke coverage. These tests never press capture,
/// permissions, AI-send, or destructive controls, and never hand anything to Apple's apps.
/// Run in a test simulator; Linux cannot run it.
final class MioUISmokeTests: XCTestCase {
    /// Keeps a picture of the screen in the result bundle, so the design can be reviewed from a
    /// cloud run. The simulator has no user data, so nothing private can appear in it.
    @MainActor
    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot(), quality: .original)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
        XCTAssertTrue(app.buttons["mio.text-ai-toggle"].firstMatch.exists, "The quick AI pause sits beside the chips")
        keepScreenshot("fanga")
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
        // Fas 6: the panel starts with whether everything works; the technical rows sit under Avancerat.
        XCTAssertTrue(app.descendants(matching: .any)["mio.settings.health"].firstMatch.waitForExistence(timeout: 5),
                      "The panel starts with the health line")
        let done = app.buttons["mio.settings.done"]
        XCTAssertTrue(done.exists)
        keepScreenshot("installningar")
        done.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mio.settings.panel"].firstMatch.waitForNonExistence(timeout: 5))
    }

    /// 2026-11-15: everything about the PC, transcription and AI is reached from the one settings
    /// sheet, under Avancerat since fas 6. Opens each page and keeps a picture; changes nothing and pairs nothing.
    @MainActor
    func testSettingsSheetLeadsToPairingTranscriptionAndAI() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Lektioner"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Lektioner"].tap()
        XCTAssertTrue(app.navigationBars["Lektioner"].waitForExistence(timeout: 5))
        keepScreenshot("lektioner")
        let settings = app.buttons["Inställningar"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.buttons["mio.settings.done"].waitForExistence(timeout: 5))
        // Avancerat is the last section of a lazy List: its row only exists once it is scrolled into view.
        let advanced = app.descendants(matching: .any)["mio.settings.advanced"].firstMatch
        var swipes = 0
        while !advanced.waitForExistence(timeout: 1) && swipes < 6 {
            app.descendants(matching: .any)["mio.settings.panel"].firstMatch.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(advanced.waitForExistence(timeout: 5), "Missing Avancerat")
        advanced.tap()
        for (row, title) in [("Parning", "Parning"), ("Transkription", "Transkription"), ("AI", "AI")] {
            let link = app.staticTexts[row].firstMatch
            var rowSwipes = 0
            while !(link.waitForExistence(timeout: 1) && link.isHittable) && rowSwipes < 6 {
                app.descendants(matching: .any)["mio.settings.panel"].firstMatch.swipeUp()
                rowSwipes += 1
            }
            XCTAssertTrue(link.waitForExistence(timeout: 5), "Missing settings row: \(row)")
            link.tap()
            let bar = app.navigationBars[title]
            XCTAssertTrue(bar.waitForExistence(timeout: 5), "Settings page did not open: \(title)")
            keepScreenshot("installningar-\(title.lowercased())")
            bar.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Inställningar"].waitForExistence(timeout: 5))
        }
        app.buttons["mio.settings.done"].tap()
        XCTAssertTrue(app.buttons["mio.settings.done"].waitForNonExistence(timeout: 5))
    }

    /// 0.9.1: nothing is created by hand in Mio; Förslag lists proposals and what was sent.
    @MainActor
    func testProposalsTabHasNoLocalCreationAndPassesTheAudit() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Förslag"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Förslag"].tap()
        XCTAssertTrue(app.navigationBars["Förslag"].waitForExistence(timeout: 5))
        keepScreenshot("forslag")
        XCTAssertFalse(app.buttons["Lägg till"].exists)
        XCTAssertFalse(app.buttons["Skriv förslag"].exists)
        XCTAssertFalse(app.tabBars.buttons["Kalender"].exists)
        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription])
    }
}
