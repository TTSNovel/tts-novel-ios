import Foundation
import SwiftSoup

// book_renderer.render_chapter_fragment() (tts-webnovel repo) emits
// "<h1>{title}</h1>\n{body}" where title/body are html.escape()'d, carrying
// through whatever entities/inline markup the epub source itself used —
// not just the handful of entities a hand-rolled decoder happens to know
// about. reader.js gets away with just setting this as innerHTML in a
// trusted context, which decodes all of that correctly; SwiftSoup is a
// real, spec-compliant HTML parser so this gets the same result — a
// regex-based stand-in previously missed things like hex numeric entities
// (`&#x27;`), leaking literal "&#x27;" into the displayed/TTS text.
public enum ChapterFragmentParser {
    public static func parse(html: String, index: Int) -> Chapter {
        let fallbackTitle = "Chương \(index + 1)"
        guard let doc = Log.attempt(.library, "Chapter HTML failed to parse", ["chapter": "\(index)", "bytes": "\(html.utf8.count)"], {
            try SwiftSoup.parse(html)
        }) else {
            return Chapter(index: index, title: fallbackTitle, text: "")
        }
        // nolog: SwiftSoup's select/text only throw on an invalid selector — these are literals
        let h1Text = (try? doc.select("h1").first()?.text()) ?? nil
        let title = (h1Text?.isEmpty == false) ? h1Text! : fallbackTitle
        let paragraphs = (try? doc.select("p").array()) ?? [] // nolog: literal selector, see above
        var body = paragraphs.map(paragraphText).joined(separator: "\n\n")
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let root = doc.body() {
            body = blockText(root, skipping: try? doc.select("h1").first()) // nolog: literal selector, see above
        }
        return Chapter(index: index, title: title, text: body)
    }

    /// Fallback for epubs whose chapter body has no `<p>` at all — some
    /// Calibre conversions (books 58, 67, 73, 114, 117 at the time of
    /// writing) put the whole chapter in nested `<div>`s with `<br><br>`
    /// between paragraphs. reader.js renders those fine via innerHTML; the
    /// `<p>`-only path above would show the title and nothing else. Mirrors
    /// `innerText`: `<br>` -> "\n", a block element's boundary -> "\n\n",
    /// then each line is trimmed and runs of blank lines collapse to a
    /// single paragraph break, so `<br><br>` lands as the "\n\n"
    /// `TextSegmentation.splitParagraphs` keys on.
    private static let blockTags: Set<String> = [
        "div", "section", "article", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "table", "tr",
    ]

    private static func blockText(_ root: Element, skipping skipped: Element?) -> String {
        var raw = ""
        func walk(_ node: Node) {
            if let text = node as? TextNode {
                raw += text.text()
            } else if let el = node as? Element {
                if el === skipped { return }
                let tag = el.tagName().lowercased()
                if tag == "br" { raw += "\n"; return }
                let isBlock = blockTags.contains(tag)
                if isBlock { raw += "\n\n" }
                el.getChildNodes().forEach(walk)
                if isBlock { raw += "\n\n" }
            }
        }
        walk(root)
        let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One `<p>`'s own text, browser-`innerText`-style: a `<br>` becomes a
    /// line break, everything else's already-entity-decoded text is
    /// concatenated as-is. `Element.text()` alone can't do this — it
    /// collapses all whitespace, so a `<br>` (which has no text content of
    /// its own) would otherwise disappear entirely instead of becoming the
    /// intra-paragraph line break `TextSegmentation` expects.
    private static func paragraphText(_ element: Element) -> String {
        var result = ""
        for node in element.getChildNodes() {
            if let text = node as? TextNode {
                result += text.text()
            } else if let el = node as? Element {
                result += el.tagName().lowercased() == "br" ? "\n" : ((try? el.text()) ?? "") // nolog: Element.text() doesn't throw in practice
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
