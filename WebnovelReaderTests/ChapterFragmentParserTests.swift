import XCTest
@testable import WebnovelReader

final class ChapterFragmentParserTests: XCTestCase {
    /// Synthetic fragment (not real book content) covering the entity
    /// families a hand-rolled 6-entity whitelist used to miss: named
    /// (`&hellip;` `&mdash;` `&rsquo;`), decimal numeric (`&#39;`), and —
    /// the one that actually leaked into production, see chapters 88/89 of
    /// book 85 below — hex numeric (`&#x27;`).
    func testDecodesFullEntityRangeNotJustWhitelist() {
        let html = """
        <h1>Chương 1: A &amp; B</h1>
        <p>She said &quot;wait&hellip;&quot; &mdash; then it&#39;s over, it&#x27;s fine, and it&rsquo;s ok.</p>
        """
        let chapter = ChapterFragmentParser.parse(html: html, index: 0)

        XCTAssertFalse(chapter.text.contains("&"), "no HTML entity should survive parsing: \(chapter.text)")
        XCTAssertTrue(chapter.text.contains("\u{2026}"), "&hellip; should decode to a real ellipsis")
        XCTAssertTrue(chapter.text.contains("\u{2014}"), "&mdash; should decode to a real em dash")
        XCTAssertTrue(chapter.text.contains("\u{2019}"), "&rsquo; should decode to a real right single quote")
        XCTAssertEqual(chapter.text.filter { $0 == "'" }.count, 2, "&#39; and &#x27; should both decode to a plain apostrophe")
        XCTAssertEqual(chapter.title, "Chương 1: A & B", "&amp; should decode to a literal '&', not survive as entity syntax")
    }

    /// `<br>` must still become an intra-paragraph line break — `Element
    /// .text()` alone drops it (it has no text content of its own), which
    /// is exactly what `paragraphText(_:)` in ChapterFragmentParser works
    /// around.
    func testBrBecomesLineBreakWithinAParagraph() {
        let html = "<h1>T</h1><p>Line one<br>Line two</p>"
        let chapter = ChapterFragmentParser.parse(html: html, index: 0)
        XCTAssertEqual(chapter.text, "Line one\nLine two")
    }

    /// Two `<p>` elements must stay separated by a paragraph break
    /// (`"\n\n"`) — the boundary `TextSegmentation.splitParagraphs` relies
    /// on to keep each author-intended reading beat as one TTS unit.
    func testParagraphsJoinedByBlankLine() {
        let html = "<h1>T</h1><p>First.</p><p>Second.</p>"
        let chapter = ChapterFragmentParser.parse(html: html, index: 0)
        XCTAssertEqual(chapter.text, "First.\n\nSecond.")
    }

    // MARK: - Real chapters (book 85, chapters 84-92 — the ones reported broken)

    /// Fetches real chapter fragments straight from the live server (same
    /// `books/<id>/data/NNNN.html` route `APIClient.fetchChapter` hits, no
    /// auth required for that route) and asserts the production parser
    /// leaves no HTML entity pattern (`&...;`, named or numeric) behind —
    /// not just the two (`&#x27;`, `&quot;`) that happened to be in these
    /// specific chapters when this test was written. Root-caused via the
    /// same live data on 2026-08-31: chapters 88 and 89 showed literal
    /// "&#x27;" in place of apostrophes because the old parser only
    /// decoded decimal numeric entities, never hex.
    func testRealBook85ChaptersHaveNoResidualEntities() async throws {
        let baseURL = URL(string: "https://novel-web-zw7d5ierwq-as.a.run.app")!
        let entityPattern = try! NSRegularExpression(pattern: "&#?[a-zA-Z0-9]+;")
        var checkedAtLeastOne = false

        for index in 84...92 {
            let filename = String(format: "%04d.html", index)
            let url = baseURL.appendingPathComponent("books/85/data/\(filename)")
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                continue // live server unreachable from this environment — skip rather than fail the run
            }
            checkedAtLeastOne = true

            let chapter = ChapterFragmentParser.parse(html: html, index: index)
            let ns = chapter.text as NSString
            let match = entityPattern.firstMatch(in: chapter.text, range: NSRange(location: 0, length: ns.length))
            XCTAssertNil(match, "chapter \(index): residual HTML entity in displayed text: \(match.map { ns.substring(with: $0.range) } ?? "")")
            XCTAssertFalse(chapter.title.isEmpty, "chapter \(index): title should not be empty")
            XCTAssertFalse(chapter.text.isEmpty, "chapter \(index): body should not be empty")
        }

        if !checkedAtLeastOne {
            throw XCTSkip("live server unreachable — skipping real-chapter entity check")
        }
    }
}
