import XCTest
@testable import Core

final class GlossaryTermTests: XCTestCase {
    func testDecodesServerTermsAndRoundTrips() throws {
        let json = #"""
        {"terms": [
          {"id": "a1", "source": "Dao", "target": "Đạo", "book_id": null},
          {"id": "b2", "source": "class", "target": "class", "book_id": 119}
        ]}
        """#
        struct Body: Codable { let terms: [GlossaryTerm] }
        let terms = try JSONDecoder().decode(Body.self, from: Data(json.utf8)).terms
        XCTAssertEqual(terms.map(\.serverID), ["a1", "b2"])
        XCTAssertEqual(terms.map(\.bookID), [nil, 119])
        XCTAssertFalse(terms[0].keepsOriginal)
        XCTAssertTrue(terms[1].keepsOriginal)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(terms[0])) as? [String: Any]
        XCTAssertEqual(encoded?["id"] as? String, "a1")
        XCTAssertEqual(encoded?["source"] as? String, "Dao")
        XCTAssertTrue(encoded?["book_id"] is NSNull, "shared terms send an explicit null book_id")
    }

    func testNewTermHasNoServerIDAndAStableLocalIdentity() throws {
        let term = GlossaryTerm(source: "Dao", target: "Đạo", bookID: nil)
        XCTAssertNil(term.serverID)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(term)) as? [String: Any]
        XCTAssertNil(encoded?["id"])
        XCTAssertNotEqual(term.id, GlossaryTerm(source: "Dao", target: "Đạo", bookID: nil).id)
    }
}
