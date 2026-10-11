import Foundation
import XCTest
@testable import Mio

final class MioCloudTests: XCTestCase {
    func testKnownProviderKeyPrefixesCannotBecomeAppGatewayCredentials() throws {
        for prefix in ["sk-", "SK-", "sk_", "SK_", "gsk_", "GSK_", "AIza", "aiza"] {
            XCTAssertFalse(MioPairingPayload.isValidToken(prefix + String(repeating: "x", count: 43)))
        }
        XCTAssertTrue(MioPairingPayload.isValidToken(String(repeating: "x", count: 43)))
    }

    @MainActor
    func testOnlyHTTPSOriginsAreAccepted() throws {
        XCTAssertEqual(try MioCloudSettings.endpoint(for: "https://mio.example.se").absoluteString,
                       "https://mio.example.se/v1/ask")
        for address in ["http://mio.example.se", "https://user:password@mio.example.se",
                        "https://mio.example.se/other", "https://mio.example.se?token=value",
                        "https://mio.example.se#fragment", "file:///tmp/private", ""] {
            XCTAssertThrowsError(try MioCloudSettings.endpoint(for: address), address)
        }
    }

    func testLegacyAccessSecretsAreDetectedAndDroppedOnRewrite() throws {
        let token = String(repeating: "a", count: 43)
        XCTAssertEqual(try MioCloudCredentials.decode(Data(token.utf8)), MioCloudCredentials(token: token))
        XCTAssertFalse(MioCloudCredentials.hasLegacyAccess(Data(token.utf8)))
        let legacy = Data("{\"token\":\"\(token)\",\"access\":{\"clientID\":\"fixture.access\",\"clientSecret\":\"fixture_secret\"}}".utf8)
        XCTAssertTrue(MioCloudCredentials.hasLegacyAccess(legacy))
        let decoded = try MioCloudCredentials.decode(legacy)
        XCTAssertEqual(decoded, MioCloudCredentials(token: token))
        let rewritten = try JSONEncoder().encode(decoded)
        XCTAssertFalse(MioCloudCredentials.hasLegacyAccess(rewritten))
        XCTAssertFalse(String(decoding: rewritten, as: UTF8.self).contains("fixture_secret"))
        XCTAssertThrowsError(try MioCloudCredentials.decode(Data("{broken".utf8)))
    }

    func testGatewayRequestsCarryOnlyTheBearerToken() throws {
        let body = Data("{\"question\":\"Syntetiskt prov\",\"context\":[]}".utf8)
        for route in ["ask", "analyze", "lesson-notes"] {
            let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/\(route)")!,
                                                token: "fixture_gateway")
            let request = try MioCloudService.makeRequest(body, connection: connection)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture_gateway")
            XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Id"))
            XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
            XCTAssertEqual(request.httpBody, body)
        }
    }

    func testApprovedPayloadContainsExactlyTheSelectedText() throws {
        let request = MioCloudRequest(question: "  Varför?  ", context: [
            MioCloudContext(label: "Valt utdrag", text: "Bara den här texten.")
        ])
        let data = try request.validatedData()
        let decoded = try JSONDecoder().decode(MioCloudRequest.self, from: data)
        XCTAssertEqual(decoded, request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["question", "context"])
    }

    func testByteLimitsAndEmptyContextAreRejectedBeforeSending() throws {
        XCTAssertThrowsError(try MioCloudRequest(question: " ", context: []).validatedData())
        XCTAssertThrowsError(try MioCloudRequest(question: String(repeating: "å", count: 1_001), context: []).validatedData())
        XCTAssertThrowsError(try MioCloudRequest(question: "Hej", context: [
            MioCloudContext(label: "Utdrag", text: "")
        ]).validatedData())
        XCTAssertThrowsError(try MioCloudRequest(question: "Hej", context: Array(
            repeating: MioCloudContext(label: "Utdrag", text: String(repeating: "a", count: 3_500)), count: 3
        )).validatedData())
        XCTAssertNoThrow(try MioCloudRequest(question: "Hej", context: []).validatedData())
    }
}
