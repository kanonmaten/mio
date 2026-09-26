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
