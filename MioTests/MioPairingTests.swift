import Foundation
import XCTest
@testable import Mio

final class MioPairingTests: XCTestCase {
    private let aiToken = String(repeating: "A", count: 43)
    private let sttToken = String(repeating: "b", count: 43) + "_-9"

    private func code(_ fields: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }

    func testParsesTheExactMioPairOutput() throws {
        let text = "{\"mio\":1,\"aiURL\":\"https://Dator.Tailnet.ts.net:8443\",\"aiToken\":\"\(aiToken)\","
            + "\"transcriptionURL\":\"https://dator.tailnet.ts.net\",\"transcriptionToken\":\"\(sttToken)\"}"
        let payload = try MioPairingPayload.parse(text)
        XCTAssertEqual(payload.aiOrigin.absoluteString, "https://dator.tailnet.ts.net:8443")
        XCTAssertEqual(payload.aiToken, aiToken)
        XCTAssertEqual(payload.transcriptionOrigin?.absoluteString, "https://dator.tailnet.ts.net")
        XCTAssertEqual(payload.transcriptionToken, sttToken)
        XCTAssertEqual(payload.hostName, "dator.tailnet.ts.net")
    }

    func testTranscriptionPairIsOptionalButNeverHalf() throws {
        let withoutPianissimo = try MioPairingPayload.parse(code(["mio": 1, "aiURL": "https://pc.tail.ts.net:8443",
            "aiToken": aiToken, "transcriptionURL": NSNull(), "transcriptionToken": NSNull()]))
        XCTAssertNil(withoutPianissimo.transcriptionOrigin)
        XCTAssertNil(withoutPianissimo.transcriptionToken)
        XCTAssertNoThrow(try MioPairingPayload.parse(code(["mio": 1, "aiURL": "https://pc.tail.ts.net:8443", "aiToken": aiToken])))
        XCTAssertThrowsError(try MioPairingPayload.parse(code(["mio": 1, "aiURL": "https://pc.tail.ts.net:8443",
            "aiToken": aiToken, "transcriptionURL": "https://pc.tail.ts.net", "transcriptionToken": NSNull()]))) {
            XCTAssertEqual($0 as? MioPairingPayload.ParseError, .incompleteTranscription)
        }
    }

    func testRejectsOtherVersionsUnknownKeysAndForeignCodes() throws {
        let base: [String: Any] = ["mio": 1, "aiURL": "https://pc.tail.ts.net:8443", "aiToken": aiToken]
        var future = base; future["mio"] = 2
        XCTAssertThrowsError(try MioPairingPayload.parse(code(future))) {
            XCTAssertEqual($0 as? MioPairingPayload.ParseError, .unsupportedVersion)
        }
        var textual = base; textual["mio"] = "1"
        var extra = base; extra["groqKey"] = "x"
        var missing = base; missing["aiToken"] = nil
        for invalid in [try code(textual), try code(extra), try code(missing), "https://pc.tail.ts.net",
                        "[1]", "", "{\"mio\":true}", String(repeating: " ", count: 3_000) + (try code(base))] {
            XCTAssertThrowsError(try MioPairingPayload.parse(invalid), invalid.prefix(40).description) {
                XCTAssertEqual($0 as? MioPairingPayload.ParseError, .notMioCode)
            }
        }
    }

    func testAddressesMustBeHTTPSOriginsOnValidHosts() throws {
        for address in ["http://pc.tail.ts.net:8443", "https://user@pc.tail.ts.net", "https://pc.tail.ts.net/v1",
                        "https://pc.tail.ts.net?x=1", "https://pc.tail.ts.net#x", "https://localhost:8443",
                        "https://-pc.tail.ts.net", "https://pc_1.tail.ts.net", "https://pc..ts.net",
                        "https://pc.tail.ts.net:0", " https://pc.tail.ts.net", "ftp://pc.tail.ts.net"] {
            XCTAssertThrowsError(try MioPairingPayload.parse(code(["mio": 1, "aiURL": address, "aiToken": aiToken])), address) {
                XCTAssertEqual($0 as? MioPairingPayload.ParseError, .invalidAIAddress)
            }
        }
        // The AI gateway may use another valid host; Pianissimo stays on Tailscale's default HTTPS port.
        XCTAssertEqual(MioPairingPayload.origin("https://mio.example.se:443/", requireTailscale: false)?.absoluteString,
                       "https://mio.example.se")
        XCTAssertNil(MioPairingPayload.origin("https://mio.example.se", requireTailscale: true))
        for address in ["https://public.example", "https://pc.tail.ts.net:8443"] {
            XCTAssertThrowsError(try MioPairingPayload.parse(code(["mio": 1, "aiURL": "https://pc.tail.ts.net:8443",
                "aiToken": aiToken, "transcriptionURL": address, "transcriptionToken": sttToken])), address) {
                XCTAssertEqual($0 as? MioPairingPayload.ParseError, .invalidTranscriptionAddress)
            }
        }
    }

    func testTokensFollowTheGatewayAlphabetAndNeverProviderKeys() throws {
        for token in ["short", String(repeating: "x", count: 257), String(repeating: "x", count: 40) + " ",
                      String(repeating: "x", count: 40) + "=", "gsk_" + String(repeating: "x", count: 40),
                      String(repeating: "å", count: 40)] {
            XCTAssertThrowsError(try MioPairingPayload.parse(code(["mio": 1, "aiURL": "https://pc.tail.ts.net:8443",
                "aiToken": token])), token) {
                XCTAssertEqual($0 as? MioPairingPayload.ParseError, .invalidAIToken)
            }
        }
        XCTAssertTrue(MioPairingPayload.isValidToken(String(repeating: "x", count: 32)))
        XCTAssertTrue(MioPairingPayload.isValidToken(String(repeating: "x", count: 256)))
    }

    func testManualEntryTrimsAndTreatsEmptyTranscriptionAsAbsent() throws {
        let payload = try MioPairingPayload.manual(aiURL: " https://pc.tail.ts.net:8443 \n", aiToken: " \(aiToken) ",
                                                   transcriptionURL: "  ", transcriptionToken: "")
        XCTAssertEqual(payload.aiOrigin.absoluteString, "https://pc.tail.ts.net:8443")
        XCTAssertNil(payload.transcriptionOrigin)
        XCTAssertThrowsError(try MioPairingPayload.manual(aiURL: "https://pc.tail.ts.net:8443", aiToken: aiToken,
                                                          transcriptionURL: "", transcriptionToken: sttToken)) {
            XCTAssertEqual($0 as? MioPairingPayload.ParseError, .incompleteTranscription)
        }
        let full = try MioPairingPayload.manual(aiURL: "https://pc.tail.ts.net:8443", aiToken: aiToken,
                                                transcriptionURL: "https://pc.tail.ts.net/", transcriptionToken: sttToken)
        XCTAssertEqual(full.transcriptionOrigin?.absoluteString, "https://pc.tail.ts.net")
    }

    func testAIIsOnByDefaultAndThePausePersists() throws {
        let suite = "mio.tests.ai-preference.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(MioAIPreference.isEnabled(in: defaults))
        XCTAssertFalse(MioAIPreference.shouldRun(paired: false, defaults: defaults), "Nothing runs before pairing")
        XCTAssertTrue(MioAIPreference.shouldRun(paired: true, defaults: defaults))
        MioAIPreference.setEnabled(false, in: defaults)
        XCTAssertFalse(MioAIPreference.shouldRun(paired: true, defaults: defaults))
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertFalse(MioAIPreference.isEnabled(in: reopened), "The pause survives a new defaults instance")
        MioAIPreference.setEnabled(true, in: reopened)
        XCTAssertTrue(MioAIPreference.shouldRun(paired: true, defaults: defaults))
    }

    func testConsentLogFindsTheIntervalCoveringCaptureTime() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var log = MioAIConsentLog()
        log.record(.on, at: base)
        log.record(.on, at: base.addingTimeInterval(10))
        XCTAssertEqual(log.entries.count, 1, "Repeated activations keep the original consent start")
        log.record(.skipped, at: base.addingTimeInterval(100), until: base.addingTimeInterval(200))
        log.record(.off, at: base.addingTimeInterval(300))
        log.record(.on, at: base.addingTimeInterval(400))
        XCTAssertNil(log.consentStart(covering: base.addingTimeInterval(-1)))
        XCTAssertEqual(log.consentStart(covering: base.addingTimeInterval(50)), base)
        XCTAssertNil(log.consentStart(covering: base.addingTimeInterval(150)), "Quota-skipped text is never caught up")
        XCTAssertEqual(log.consentStart(covering: base.addingTimeInterval(250)), base.addingTimeInterval(200),
                       "Context restarts after a skipped interval")
        XCTAssertNil(log.consentStart(covering: base.addingTimeInterval(350)), "Text captured while AI was paused stays local")
        XCTAssertEqual(log.consentStart(covering: base.addingTimeInterval(500)), base.addingTimeInterval(400))
        XCTAssertTrue(log.isOn)
    }

    func testConsentLogTrimsOldEntriesButKeepsCurrentStateAndPersists() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var log = MioAIConsentLog()
        log.record(.on, at: base)
        log.record(.skipped, at: base.addingTimeInterval(10), until: base.addingTimeInterval(20))
        log.trim(now: base.addingTimeInterval(MioAIConsentLog.retention + 100))
        XCTAssertEqual(log.entries.map(\.kind), [.on], "An old switch-on still describes the current state")
        XCTAssertEqual(log.consentStart(covering: base.addingTimeInterval(MioAIConsentLog.retention + 50)), base)
        let suite = "mio.consent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        log.save(to: defaults)
        XCTAssertEqual(MioAIConsentLog.load(from: defaults), log)
        MioAIConsentLog.record(.off, at: base.addingTimeInterval(MioAIConsentLog.retention + 200), in: defaults)
        XCTAssertFalse(MioAIConsentLog.load(from: defaults).isOn)
    }
}
