import XCTest
@testable import Core

final class DiagnosticsTests: XCTestCase {
    func testErrorInfoKeepsDomainCodeAndUnderlyingError() {
        let underlying = NSError(domain: "TranslationErrorDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: "inner"])
        let error = NSError(domain: "Outer", code: 42, userInfo: [NSUnderlyingErrorKey: underlying, "extra": "value"])

        let info = ErrorInfo(error)

        XCTAssertEqual(info.domain, "Outer")
        XCTAssertEqual(info.code, 42)
        XCTAssertEqual(info.userInfo?["extra"], "value")
        XCTAssertEqual(info.underlying?.first?.domain, "TranslationErrorDomain")
        XCTAssertEqual(info.underlying?.first?.code, 7)
        XCTAssertTrue(info.summary.contains("TranslationErrorDomain#7"))
    }

    func testSwiftErrorKeepsCaseAndAssociatedValue() {
        let info = ErrorInfo(APIError.httpStatus(503))
        XCTAssertTrue(info.description.contains("httpStatus(503)"), info.description)
        XCTAssertTrue(info.type.contains("APIError"))
    }

    func testFailedTranslationIsLoggedWithTheSentenceThatFailed() async {
        let marker = UUID().uuidString
        let engine = LoggedTranslationEngine(base: FailingEngine(failAt: 2), context: ["marker": marker])
        let texts = ["one", "two", "three — the bad one", "four"]
        var received: [Int] = []
        do {
            for try await (index, _) in engine.translate(texts: texts, source: .init(identifier: "en"), target: .init(identifier: "vi")) {
                received.append(index)
            }
            XCTFail("expected the stream to throw")
        } catch {}

        XCTAssertEqual(received, [0, 1])
        let entry = DiagnosticsLog.shared.entries(since: .distantPast, errorsOnly: true)
            .last { $0.context?["marker"] == marker }
        XCTAssertEqual(entry?.message, "Translation failed")
        XCTAssertEqual(entry?.context?["sentence"], "2")
        XCTAssertEqual(entry?.context?["text"], "three — the bad one")
        XCTAssertEqual(entry?.context?["translated"], "2/4")
        XCTAssertEqual(entry?.error?.domain, "FakeEngine")
    }

    func testContextIsAttachedToEverythingLoggedInsideIt() async {
        let marker = UUID().uuidString
        await withLogContext(["job": "test", "marker": marker]) {
            await withLogContext(["chapter": "741"]) {
                Log.error(.app, "Inside", error: NSError(domain: "X", code: 1))
            }
        }
        let entry = DiagnosticsLog.shared.entries(since: .distantPast, errorsOnly: true)
            .last { $0.context?["marker"] == marker }
        XCTAssertEqual(entry?.context?["job"], "test")
        XCTAssertEqual(entry?.context?["chapter"], "741")
    }

    func testCancellationIsNotLoggedAsAnError() {
        let marker = UUID().uuidString
        Log.error(.app, "Stopped", error: CancellationError(), ["marker": marker])
        let errors = DiagnosticsLog.shared.entries(since: .distantPast, errorsOnly: true)
        XCTAssertFalse(errors.contains { $0.context?["marker"] == marker })
        let all = DiagnosticsLog.shared.entries(since: .distantPast)
        XCTAssertEqual(all.last { $0.context?["marker"] == marker }?.level, .debug)
    }

    func testStoredJSONRoundTripsAndTreatsMissingFileAsNil() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stored-\(UUID().uuidString)/value.json")
        XCTAssertNil(StoredJSON.load([String].self, from: url))
        XCTAssertTrue(StoredJSON.save(["a", "b"], to: url))
        XCTAssertEqual(StoredJSON.load([String].self, from: url), ["a", "b"])
        StoredJSON.remove(url.deletingLastPathComponent())
    }
}

private struct FailingEngine: TranslationEngine {
    let failAt: Int
    var displayName: String { "Fake" }
    func canTranslate(from source: Locale.Language, to target: Locale.Language) -> Bool { true }
    func translate(texts: [String], source: Locale.Language, target: Locale.Language) -> AsyncThrowingStream<(index: Int, text: String), Error> {
        AsyncThrowingStream { continuation in
            for index in texts.indices {
                if index == failAt {
                    continuation.finish(throwing: NSError(domain: "FakeEngine", code: 3))
                    return
                }
                continuation.yield((index, texts[index].uppercased()))
            }
            continuation.finish()
        }
    }
}
