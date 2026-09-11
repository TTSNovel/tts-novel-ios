import XCTest
@testable import Core

/// Exercises the actual code path `ReaderPlaybackController.sentenceSequence(for:)`
/// runs before TTS synthesis — proof the "Filter Words" feature really
/// strips matched text, not just that the app compiles.
final class TextSegmentationFilterTests: XCTestCase {
    func testPlainTextRuleStripsExactMatch() {
        let rule = FilterWordRule(pattern: "Đọc truyện tại", isRegex: false)
        let result = TextSegmentation.cleaned("Chương này. Đọc truyện tại trang X nhé.", filterRules: [rule])
        XCTAssertFalse(result.contains("Đọc truyện tại"))
        XCTAssertTrue(result.contains("Chương này"))
    }

    func testRegexRuleStripsURL() {
        let rule = FilterWordRule(pattern: #"https?://\S+"#, isRegex: true)
        let result = TextSegmentation.cleaned("Xem thêm tại https://example.com/abc nha.", filterRules: [rule])
        XCTAssertFalse(result.contains("https://"))
        XCTAssertTrue(result.contains("Xem thêm tại"))
    }

    func testInvalidRegexIsSkippedRatherThanCrashing() {
        let rule = FilterWordRule(pattern: "(unclosed", isRegex: true)
        let result = TextSegmentation.cleaned("Văn bản bình thường.", filterRules: [rule])
        XCTAssertEqual(result, "Văn bản bình thường.")
    }

    func testMultipleRulesAllApply() {
        let rules = [
            FilterWordRule(pattern: #"https?://\S+"#, isRegex: true),
            FilterWordRule(pattern: "quảng cáo", isRegex: false),
        ]
        let result = TextSegmentation.cleaned("Xem https://a.b quảng cáo ở đây.", filterRules: rules)
        XCTAssertFalse(result.contains("https://"))
        XCTAssertFalse(result.contains("quảng cáo"))
    }

    /// Every one of the shipped defaults, checked against a realistic
    /// scraped-novel-style paragraph containing exactly the kind of text
    /// each rule targets.
    func testDefaultSeedRemovesEachTargetedArtifact() {
        let text = """
        Chương 12: Khởi đầu mới
        Nguồn: convertsite.com
        Convert: Nguyễn Văn A
        Ghé xem tại www.example.com hoặc https://example.vn/truyen để đọc thêm.
        Liên hệ email: contact@example.com hoặc @username trên Zalo.
        (TN: đoạn này khó dịch) Hắn nhìn 你好 một cách khó hiểu. 😀
        Đọc truyện tại nguồn gốc, tham gia Group đọc truyện để cập nhật. #truyenhay
        """
        let result = TextSegmentation.cleaned(text, filterRules: DefaultFilterWords.seed)

        for artifact in [
            "Nguồn:", "Convert:", "www.example.com", "https://example.vn",
            "contact@example.com", "@username", "(TN:", "你好", "😀",
            "Đọc truyện tại", "Group đọc truyện", "#truyenhay",
        ] {
            XCTAssertFalse(result.contains(artifact), "expected '\(artifact)' to be stripped, got: \(result)")
        }
        // The actual narrative content must survive.
        XCTAssertTrue(result.contains("Hắn nhìn"))
        XCTAssertTrue(result.contains("khó hiểu"))
    }
}
