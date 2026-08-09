import Foundation

// Not a general HTML parser — matches exactly what
// book_renderer.render_chapter_fragment() emits: "<h1>{title}</h1>\n{body}"
// where both title and body only ever contain the entities html.escape()
// produces (& < > " ') plus whatever the epub source itself used (e.g.
// &nbsp;). reader.js gets away with just setting this as innerHTML in a
// trusted context; here it's stripped down to plain text for both display
// and (later) feeding to TTS.
enum ChapterFragmentParser {
    static func parse(html: String, index: Int) -> Chapter {
        var title = "Chương \(index + 1)"
        var body = html
        if let range = html.range(of: "<h1>.*?</h1>", options: [.regularExpression, .caseInsensitive]) {
            title = String(html[range]).strippingHTMLTags()
            body = String(html[range.upperBound...])
        }
        return Chapter(index: index, title: title, text: body.strippingHTMLTags())
    }
}

extension String {
    func strippingHTMLTags() -> String {
        var s = self
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (entity, character) in entities {
            s = s.replacingOccurrences(of: entity, with: character)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
