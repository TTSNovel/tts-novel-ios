import XCTest
@testable import Core

/// Same cases as tts-webnovel's hanviet.js — both sides must convert a
/// chapter identically.
final class VietPhraseTranslationEngineTests: XCTestCase {
    private let converter = HanVietConverter.bundled!

    func testConvertsHanCharactersAndCapitalizesSentenceStart() {
        XCTAssertEqual(converter.convert("第九章 以战养战"), "Đệ cửu chương dĩ chiến dưỡng chiến")
    }

    func testSeparatesNumbersAndLatinWordsFromReadings() {
        XCTAssertEqual(converter.convert("第1章 楔子"), "Đệ 1 chương tiết tử")
        XCTAssertEqual(converter.convert("Hello 世界 123"), "Hello thế giới 123")
    }

    func testMapsChinesePunctuationAndQuotes() {
        XCTAssertEqual(
            converter.convert("他说：“你好！我是林动。”然后走了。"),
            "Tha thuyết: “Nhĩ hảo! Ngã thị lâm động.” Nhiên hậu tẩu liễu."
        )
        XCTAssertEqual(converter.convert("灰色为“残破”，白色为“普通”。"), "Hôi sắc vi “Tàn phá”, bạch sắc vi “Phổ thông”.")
        XCTAssertEqual(converter.convert("力量：1.2；"), "Lực lượng: 1.2;")
    }

    func testLeavesNonChineseAndUnknownCharactersAlone() {
        XCTAssertEqual(converter.convert("Đây là tiếng Việt, version 1.2."), "Đây là tiếng Việt, version 1.2.")
        XCTAssertEqual(converter.convert("𠀀"), "𠀀")
    }

    func testDetectsPredominantlyChineseText() {
        XCTAssertTrue(HanVietConverter.isPredominantlyChinese("他说你好 Lin Dong"))
        XCTAssertFalse(HanVietConverter.isPredominantlyChinese("Đây là tiếng Việt có chữ 好"))
        XCTAssertFalse(HanVietConverter.isPredominantlyChinese("Plain English text"))
    }

    func testEngineOnlyServesChineseToVietnamese() {
        let engine = VietPhraseTranslationEngine.shared
        let vi = Locale.Language(identifier: "vi")
        XCTAssertTrue(engine.canTranslate(from: Locale.Language(identifier: "zh-Hans"), to: vi))
        XCTAssertTrue(engine.canTranslate(from: Locale.Language(identifier: "zh-Hant"), to: vi))
        XCTAssertFalse(engine.canTranslate(from: Locale.Language(identifier: "en"), to: vi))
        XCTAssertFalse(engine.canTranslate(from: Locale.Language(identifier: "zh-Hans"), to: Locale.Language(identifier: "en")))
    }

    func testEngineStreamsEverySentenceByIndex() async throws {
        let stream = VietPhraseTranslationEngine.shared.translate(
            texts: ["第九章", "你好。"],
            source: Locale.Language(identifier: "zh-Hans"),
            target: Locale.Language(identifier: "vi")
        )
        var results: [Int: String] = [:]
        for try await (index, text) in stream { results[index] = text }
        XCTAssertEqual(results, [0: "Đệ cửu chương", 1: "Nhĩ hảo."])
    }

    func testChineseParagraphsSplitOnChinesePunctuation() {
        // Long enough (once weighted per Han character) to need splitting.
        let paragraph = String(repeating: "他说你好我是林动然后走了。", count: 6)
        let sentences = TextSegmentation.sentences(from: paragraph)
        XCTAssertEqual(sentences.count, 6)
        XCTAssertEqual(sentences.first, "他说你好我是林动然后走了。")
    }
}
