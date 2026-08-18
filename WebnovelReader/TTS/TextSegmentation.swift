import Foundation

// The source pipeline (tts-webnovel's epub_parser.py: _text_to_html) already
// emits one HTML <p> per author-intended reading beat, and
// ChapterFragmentParser preserves that boundary as "\n\n" in chapter.text
// (</p> -> "\n\n", <br> -> "\n" for a line break *within* one element). So a
// short paragraph is trusted whole, exactly as written — `.!?` is only
// consulted as a fallback once a paragraph is too long to read/synthesize as
// one unit. This is what keeps a quote spanning a period (e.g. "“Di.” Hướng
// Du...") from ever being cut in half: as long as the whole paragraph fits
// within `maxChars`, it never reaches the character-level splitter at all.
enum TextSegmentation {
    private static let maxChars = 150

    /// Paragraph-preserving cleanup — strips decorative characters and
    /// collapses ellipses, but deliberately does NOT touch `\n`/`\n\n` (the
    /// element boundaries `sentences(from:)` below needs to see).
    static func cleaned(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "[·‧・•]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "~", with: "")
        s = s.replacingOccurrences(of: "\\.{2,}", with: ".", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One HTML element (`<p>`/paragraph) per entry if it fits in one TTS
    /// request; only split further — by punctuation, then by comma — once
    /// an element is too long to read as a single unit.
    static func sentences(from text: String) -> [String] {
        splitParagraphs(text).flatMap { paragraph in
            paragraph.count <= maxChars ? [paragraph] : splitLongParagraph(paragraph)
        }
    }

    private static let paragraphBreak = try! NSRegularExpression(pattern: "\\n\\s*\\n+")

    /// Splits on the paragraph boundary ChapterFragmentParser encodes
    /// (`</p>` -> "\n\n") — NOT on every single `\n`, since a lone `\n`
    /// (from `<br>`) is a line break *within* one element, not a new one.
    /// Collapses any remaining intra-paragraph whitespace (including that
    /// `<br>` newline) down to a single space.
    private static func splitParagraphs(_ text: String) -> [String] {
        let ns = text as NSString
        var pieces: [String] = []
        var last = 0
        paragraphBreak.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            pieces.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            last = match.range.location + match.range.length
        }
        pieces.append(ns.substring(from: last))
        return pieces
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 2 }
    }

    /// Directional open/close quote pairs — same set VieNeuV3TextChunker's
    /// `openToClose` uses for its quote-aware sentence scan. The novel
    /// source (fetched from the server, see `books/<id>/data/<n>.html`)
    /// uses curly quotes (U+201C/U+201D), not the straight ASCII `"`.
    private static let openToClose: [Character: Character] = [
        "\u{201C}": "\u{201D}", // “ ”
        "\u{2018}": "\u{2019}", // ‘ ’
        "\u{00AB}": "\u{00BB}", // « »
        "\u{2039}": "\u{203A}", // ‹ ›
        "\u{300C}": "\u{300D}", // 「 」
        "\u{300E}": "\u{300F}", // 『 』
    ]
    private static let closingQuoteChars: Set<Character> = Set(openToClose.values)

    /// True once every directional quote opened in `text` has its matching
    /// close, and any straight ASCII `"` (symmetric — same glyph for open
    /// and close) has an even count.
    private static func isQuoteBalanced(_ text: String) -> Bool {
        var depth = 0
        var inStraightQuote = false
        for ch in text {
            if ch == "\"" {
                inStraightQuote.toggle()
            } else if openToClose[ch] != nil {
                depth += 1
            } else if closingQuoteChars.contains(ch), depth > 0 {
                depth -= 1
            }
        }
        return depth == 0 && !inStraightQuote
    }

    private static let terminatorPattern = try! NSRegularExpression(pattern: "[^.!?]+[.!?]*\\s*")

    /// Only reached once a single paragraph/element is too long to read as
    /// one unit (see `sentences(from:)`) — tries `.!?` first, quote-aware so
    /// a quote spanning a period never gets cut in half (re-glues any
    /// quote-unbalanced fragment onto the next one — VieNeu's TTS backbones
    /// treat a stray unmatched quote as out-of-distribution input and can
    /// fail to ever sample their stop token, generating a long meaningless
    /// "moan" instead of stopping; see
    /// VieNeuV2LlamaBackbone.generateSpeechCodes's unbounded `while produced
    /// < maxTokens` loop). Falls back to comma boundaries for any resulting
    /// piece that's *still* too long, or if the paragraph had no `.!?`
    /// terminator to split on at all.
    private static func splitLongParagraph(_ paragraph: String) -> [String] {
        let ns = paragraph as NSString
        let matches = terminatorPattern.matches(in: paragraph, range: NSRange(location: 0, length: ns.length))
        let raw = matches.isEmpty ? [paragraph] : matches.map { ns.substring(with: $0.range) }
        let bySentence = mergeUnbalancedQuotes(raw)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return bySentence.flatMap(chunkByComma)
    }

    private static func mergeUnbalancedQuotes(_ parts: [String]) -> [String] {
        var merged: [String] = []
        var pending: String?
        for part in parts {
            let combined = pending.map { $0 + " " + part } ?? part
            if isQuoteBalanced(combined) {
                merged.append(combined)
                pending = nil
            } else {
                pending = combined
            }
        }
        if let pending { merged.append(pending) }
        return merged
    }

    /// Comma boundaries, but only the ones outside any open quote — a plain
    /// `,\s*` regex split doesn't know a comma inside a quote isn't a safe
    /// cut point either (confirmed in the wild: a `<p>` reading `“Ngươi nói
    /// xong chưa? Nói xong thì cúp máy đi, nhé.” Hướng Du...` split right at
    /// "đi, nhé" — same unmatched-quote failure mode `mergeUnbalancedQuotes`
    /// above exists to prevent, just one level down).
    private static func chunkByComma(_ sentence: String) -> [String] {
        guard sentence.count > maxChars else { return [sentence] }
        var chunks: [String] = []
        var current = ""
        for part in splitOutsideQuotes(sentence, on: ",") {
            let next = current.isEmpty ? part : current + ", " + part
            if next.count > maxChars, !current.isEmpty {
                chunks.append(current)
                current = part
            } else {
                current = next
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func splitOutsideQuotes(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inStraightQuote = false
        for ch in text {
            if ch == "\"" {
                inStraightQuote.toggle()
            } else if openToClose[ch] != nil {
                depth += 1
            } else if closingQuoteChars.contains(ch), depth > 0 {
                depth -= 1
            }
            if ch == separator, depth == 0, !inStraightQuote {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
