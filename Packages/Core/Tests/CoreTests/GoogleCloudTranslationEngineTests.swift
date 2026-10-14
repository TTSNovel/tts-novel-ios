import XCTest
@testable import Core

final class GoogleCloudTranslationEngineTests: XCTestCase {
    private let en = Locale.Language(identifier: "en")
    private let vi = Locale.Language(identifier: "vi")

    func testChunksRespectSegmentAndCharacterLimits() {
        let many = Array(repeating: "a", count: 95)
        XCTAssertEqual(GoogleCloudTranslationEngine.chunkIndices(for: many).map(\.count), [40, 40, 15])

        let long = String(repeating: "x", count: 5000)
        XCTAssertEqual(GoogleCloudTranslationEngine.chunkIndices(for: [long, long, "short"]), [[0], [1, 2]])
        XCTAssertEqual(GoogleCloudTranslationEngine.chunkIndices(for: []), [])
    }

    func testYieldsEveryIndexWithItsOwnTranslation() async throws {
        let engine = GoogleCloudTranslationEngine { texts, source, target in
            XCTAssertEqual(source, "en")
            XCTAssertEqual(target, "vi")
            return texts.map { "vi:\($0)" }
        }
        let texts = (0..<90).map { "s\($0)" }
        var got: [Int: String] = [:]
        for try await (index, text) in engine.translate(texts: texts, source: en, target: vi) {
            got[index] = text
        }
        XCTAssertEqual(got.count, 90)
        for (index, text) in texts.enumerated() { XCTAssertEqual(got[index], "vi:\(text)") }
    }

    func testChunkFailureFailsTheStream() async {
        struct Boom: Error {}
        let engine = GoogleCloudTranslationEngine { _, _, _ in throw Boom() }
        do {
            for try await _ in engine.translate(texts: ["a"], source: en, target: vi) {}
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }
}
