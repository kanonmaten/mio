import Foundation
import XCTest
@testable import Mio

final class MioCloudTests: XCTestCase {
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

    func testLegacyCredentialsAndAccessRoundTrip() throws {
        let token = String(repeating: "a", count: 43)
        XCTAssertEqual(try MioCloudCredentials.decode(Data(token.utf8)), MioCloudCredentials(token: token))
        let credentials = MioCloudCredentials(token: token, access: MioAccessCredentials(
            clientID: "fixture.access", clientSecret: "fixture_secret"))
        XCTAssertEqual(try MioCloudCredentials.decode(JSONEncoder().encode(credentials)), credentials)
        XCTAssertThrowsError(try MioCloudCredentials.decode(Data("{broken".utf8)))
    }

    @MainActor
    func testAccessRotationRemovalAndOriginChangeRequireCompleteCredentials() throws {
        let token = String(repeating: "a", count: 43)
        let previous = MioCloudCredentials(token: token, access: MioAccessCredentials(
            clientID: "fixture.access", clientSecret: "fixture_secret"))
        XCTAssertEqual(try MioCloudSettings.updatedCredentials(previous: previous, newToken: "",
            useAccess: true, clientID: "", clientSecret: ""), previous)
        let removed = try MioCloudSettings.updatedCredentials(previous: previous, newToken: "",
            useAccess: false, clientID: "", clientSecret: "")
        XCTAssertNil(removed.access)
        XCTAssertEqual(removed.token, token)
        let rotated = try MioCloudSettings.updatedCredentials(previous: previous, newToken: String(repeating: "b", count: 43),
            useAccess: true, clientID: "new.access", clientSecret: "new_secret")
        XCTAssertNotEqual(rotated.token, token)
        XCTAssertEqual(rotated.access?.clientSecret, "new_secret")
        // No previous credentials are supplied when the HTTPS origin changes.
        XCTAssertThrowsError(try MioCloudSettings.updatedCredentials(previous: nil, newToken: "",
            useAccess: true, clientID: "", clientSecret: ""))
        XCTAssertThrowsError(try MioCloudSettings.updatedCredentials(previous: nil, newToken: token,
            useAccess: true, clientID: "", clientSecret: ""))
        XCTAssertThrowsError(try MioCloudSettings.updatedCredentials(previous: previous, newToken: "",
            useAccess: true, clientID: "new.access", clientSecret: ""))
    }

    func testAccessHeadersAreSeparateFromBearerAndPayload() throws {
        let access = MioAccessCredentials(clientID: "fixture.access", clientSecret: "fixture_secret")
        let body = Data("{\"question\":\"Syntetiskt prov\",\"context\":[]}".utf8)
        for route in ["ask", "analyze", "lesson-notes"] {
            let connection = MioCloudConnection(endpoint: URL(string: "https://example.invalid/v1/\(route)")!,
                                                token: "fixture_gateway", access: access)
            let request = try MioCloudService.makeRequest(body, connection: connection)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture_gateway")
            XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), access.clientID)
            XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"), access.clientSecret)
            XCTAssertEqual(request.httpBody, body)
            var withoutAccess = connection
            withoutAccess.access = nil
            XCTAssertNil(try MioCloudService.makeRequest(body, connection: withoutAccess)
                .value(forHTTPHeaderField: "CF-Access-Client-Secret"))
        }
        for invalid in ["", "with space", "secret\r\nX-Injected: yes"] {
            XCTAssertThrowsError(try MioAccessCredentials(clientID: "fixture.access", clientSecret: invalid).validate())
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
