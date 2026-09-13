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

    /// Confirmed against real chapter data: khotruyenchu.fun injects
    /// zero-width spaces (U+200B) inside its promo text and domain name —
    /// invisible on screen, but enough to defeat a plain-text or domain
    /// regex filter rule that only knows the clean-looking string.
    func testZeroWidthSpaceObfuscationIsStrippedBeforeMatching() {
        let text = "Mũi chân chạm nhẹ vào tường.<strong>Đừ\u{200B}n\u{200B}g\u{200B} đọc\u{200B} ở web \u{200B}lậu,\u{200B} hãy ủ\u{200B}ng h\u{200B}ộ kho\u{200B}truyenchu.f\u{200B}un</strong>"
        let rules = [
            FilterWordRule(pattern: "Đừng đọc ở web lậu, hãy ủng hộ", isRegex: false),
            FilterWordRule(pattern: #"\b[a-zA-Z0-9-]+\.(com|net|org|vn|info|me|tv|club|xyz|top|shop|ly|gg|io|fun)\b"#, isRegex: true),
        ]
        let result = TextSegmentation.cleaned(text, filterRules: rules)
        XCTAssertFalse(result.contains("web lậu"))
        XCTAssertFalse(result.contains("khotruyenchu"))
        XCTAssertTrue(result.contains("Mũi chân chạm nhẹ vào tường"))
    }

    /// Mirror image of the above: the user builds the rule by copy-pasting
    /// the on-screen (visually clean, actually ZWSP-riddled) promo text into
    /// the pattern field, so `rule.pattern` itself carries the invisible
    /// characters. Once `text` is sanitized before matching, a pattern that
    /// still has them embedded would otherwise never match again.
    func testZeroWidthSpaceInPatternItselfStillMatches() {
        let text = "Mũi chân chạm nhẹ vào tường.Đừng đọc ở web lậu, hãy ủng hộ khotruyenchu.fun"
        let pastedPattern = "Đừ\u{200B}n\u{200B}g\u{200B} đọc\u{200B} ở web \u{200B}lậu,\u{200B} hãy ủ\u{200B}ng h\u{200B}ộ"
        let rule = FilterWordRule(pattern: pastedPattern, isRegex: false)
        let result = TextSegmentation.cleaned(text, filterRules: [rule])
        XCTAssertFalse(result.contains("web lậu"))
        XCTAssertTrue(result.contains("Mũi chân chạm nhẹ vào tường"))
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
