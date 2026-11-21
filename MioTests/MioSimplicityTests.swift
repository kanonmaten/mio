import Foundation
import XCTest
@testable import Mio

/// Fas 6: "Kontrollera allt" and its summary line, the text-free error report and the signing date.
final class MioSimplicityTests: XCTestCase {
    private var working: MioHealthInputs {
        MioHealthInputs(microphone: .granted, notifications: .granted, reminders: .granted, paired: true,
                        gateway: .reachable, pianissimo: .reachable, aiEnabled: true, aiWorking: true)
    }

    func testEveryCheckIsGreenWhenEverythingWorksAndTheSummarySaysSo() {
        let rows = MioHealthCheck.rows(working)
        XCTAssertEqual(rows.map(\.item), MioHealthItem.allCases)
        XCTAssertTrue(rows.allSatisfy { $0.state == .ok && $0.action == nil })
        XCTAssertEqual(MioHealthCheck.summary(rows).text, "Allt fungerar")
    }

    func testNoAnswerFromThePCPointsAtTailscale() {
        var inputs = working
        inputs.gateway = .unreachable
        inputs.pianissimo = .unreachable
        let rows = MioHealthCheck.rows(inputs)
        let tailscale = rows.first { $0.item == .tailscale }
        XCTAssertEqual(tailscale?.state, .problem)
        XCTAssertEqual(tailscale?.action, .openTailscale)
        XCTAssertEqual(MioHealthCheck.summary(rows).text, "Något är fel")
        // One service answering proves the tunnel works; the other one is then the problem.
        inputs.pianissimo = .reachable
        let partial = MioHealthCheck.rows(inputs)
        XCTAssertEqual(partial.first { $0.item == .tailscale }?.state, .ok)
        XCTAssertEqual(partial.first { $0.item == .computer }?.state, .problem)
    }

    func testRefusalAsksToPairAgainAndPermissionsHaveTheirOwnAction() {
        var inputs = working
        inputs.gateway = .refused
        inputs.microphone = .denied
        inputs.reminders = .notDetermined
        let rows = Dictionary(uniqueKeysWithValues: MioHealthCheck.rows(inputs).map { ($0.item, $0) })
        XCTAssertEqual(rows[.computer]?.action, .pair)
        XCTAssertEqual(rows[.microphone]?.action, .openSettings)
        XCTAssertEqual(rows[.reminders]?.action, .requestPermission)
        XCTAssertEqual(rows[.ai]?.state, .problem)
    }

    func testNotCheckedYetIsNeverReportedAsAnError() {
        var inputs = working
        inputs.gateway = .unknown
        inputs.pianissimo = .unknown
        inputs.aiWorking = false
        let summary = MioHealthCheck.summary(MioHealthCheck.rows(inputs))
        XCTAssertEqual(summary.state, .unknown)
        XCTAssertEqual(summary.text, "Kontrollera allt")
    }

    func testUnpairedAndPausedHaveOneClearAction() {
        var inputs = MioHealthInputs()
        let unpaired = Dictionary(uniqueKeysWithValues: MioHealthCheck.rows(inputs).map { ($0.item, $0) })
        XCTAssertEqual(unpaired[.computer]?.action, .pair)
        XCTAssertEqual(unpaired[.ai]?.action, .pair)
        inputs = working
        inputs.aiEnabled = false
        XCTAssertEqual(MioHealthCheck.rows(inputs).first { $0.item == .ai }?.action, .resumeAI)
    }

    func testEveryRowIsOneSentenceInSwedishWithoutCodes() {
        let variants: [MioHealthInputs] = [working, MioHealthInputs(), {
            var inputs = working; inputs.gateway = .incompatible; inputs.pianissimo = .refused; return inputs
        }()]
        for row in variants.flatMap(MioHealthCheck.rows) {
            XCTAssertFalse(row.detail.contains { $0.isNumber }, row.detail)
            XCTAssertFalse(row.detail.lowercased().contains("http") || row.detail.contains("error"), row.detail)
            XCTAssertTrue(row.detail.hasSuffix("."), row.detail)
        }
    }

    @MainActor
    func testConnectionResultsMapToReachability() {
        XCTAssertEqual(MioConnectionDiscovery.reachability(after: MioCloudError.network), .unreachable)
        XCTAssertEqual(MioConnectionDiscovery.reachability(after: MioCloudError.serverStatus(401)), .refused)
        XCTAssertEqual(MioConnectionDiscovery.reachability(after: MioCloudError.incompatibleGateway), .incompatible)
        XCTAssertEqual(MioConnectionDiscovery.reachability(after: MioCloudError.gateway(504, .upstreamTimeout)), .unreachable)
        XCTAssertEqual(MioHealthCheck.reachability(.connected), .reachable)
        XCTAssertEqual(MioHealthCheck.reachability(.offline), .unreachable)
        XCTAssertEqual(MioHealthCheck.reachability(.connecting), .unknown)
    }

    func testTheErrorReportHoldsNoPrivateText() {
        let report = MioErrorReport(appVersion: "0.9.1", build: "77", system: "iOS 27.1", createdAt: Date(timeIntervalSince1970: 0),
                                    rows: MioHealthCheck.rows(working), sessionCount: 3, contentCount: 4, suggestionCount: 2,
                                    signingDaysLeft: 5, backup: MioBackupAttempt(at: Date(timeIntervalSince1970: 0), failure: "network"),
                                    recentEvents: ["statusV2 httpError 401"])
        let text = report.text
        XCTAssertTrue(text.contains("Mio 0.9.1 (77), iOS 27.1"))
        XCTAssertTrue(text.contains("- tailscale: ok"))
        XCTAssertTrue(text.contains("3 sessioner, 4 poster, 2 förslag"))
        XCTAssertTrue(text.contains("5 dagar kvar"))
        XCTAssertTrue(text.contains("network"))
        XCTAssertTrue(text.contains("statusV2 httpError 401"))
    }

    private func profile(expiration: String) -> Data {
        // A made-up profile: binary CMS framing around the XML property list, as in the real file.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AppIDName</key><string>Mio</string>
            <key>CreationDate</key><date>2026-11-14T10:00:00Z</date>
            <key>ExpirationDate</key><date>\(expiration)</date>
            <key>TeamName</key><string>Exempel</string>
        </dict>
        </plist>
        """
        return Data([0x30, 0x82, 0x0F, 0x00, 0x06, 0x09]) + Data(xml.utf8) + Data([0xA0, 0x82, 0x00, 0x01, 0xFF])
    }

    func testTheExpiryIsReadFromTheProvisioningProfile() throws {
        let expiration = try XCTUnwrap(MioSigning.expirationDate(fromProvisioningProfile: profile(expiration: "2026-11-21T10:00:00Z")))
        XCTAssertEqual(expiration, ISO8601DateFormatter().date(from: "2026-11-21T10:00:00Z"))
        XCTAssertNil(MioSigning.expirationDate(fromProvisioningProfile: Data("no plist here".utf8)))
        XCTAssertNil(MioSigning.expirationDate(fromProvisioningProfile: Data("<plist version=\"1.0\"><dict>".utf8)))
        XCTAssertNil(MioSigning.expirationDate(fromProvisioningProfile:
            Data("<plist version=\"1.0\"><dict><key>Name</key><string>x</string></dict></plist>".utf8)))
    }

    func testDaysLeftAndTheReminderTwentyFourHoursBefore() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let expiration = ISO8601DateFormatter().date(from: "2026-11-21T10:00:00Z")!
        let now = ISO8601DateFormatter().date(from: "2026-11-16T20:00:00Z")!
        XCTAssertEqual(MioSigning.daysLeft(until: expiration, now: now, calendar: calendar), 5)
        XCTAssertEqual(MioSigning.text(expiration: expiration, now: now, calendar: calendar), "5 dagar kvar")
        XCTAssertEqual(MioSigning.text(expiration: expiration, now: expiration.addingTimeInterval(-3600), calendar: calendar), "Går ut i dag")
        XCTAssertEqual(MioSigning.text(expiration: expiration, now: expiration.addingTimeInterval(60), calendar: calendar),
                       "Har gått ut. Förnya Mio i SideStore.")
        XCTAssertEqual(MioSigning.reminderDate(expiration: expiration, now: now), expiration.addingTimeInterval(-86_400))
        XCTAssertNil(MioSigning.reminderDate(expiration: expiration, now: expiration.addingTimeInterval(-3600)))
        XCTAssertTrue(MioSigning.reminderBody.hasPrefix("1. Stäng av Tailscale. 2. Öppna SideStore och slå på LocalDevVPN."))
    }
}
