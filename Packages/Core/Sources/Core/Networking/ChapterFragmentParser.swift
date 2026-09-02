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
        guard let doc = try? SwiftSoup.parse(html) else {
            return Chapter(index: index, title: fallbackTitle, text: "")
        }
        let h1Text = (try? doc.select("h1").first()?.text()) ?? nil
        let title = (h1Text?.isEmpty == false) ? h1Text! : fallbackTitle
        let paragraphs = (try? doc.select("p").array()) ?? []
        let body = paragraphs.map(paragraphText).joined(separator: "\n\n")
        return Chapter(index: index, title: title, text: body)
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
                result += el.tagName().lowercased() == "br" ? "\n" : ((try? el.text()) ?? "")
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
