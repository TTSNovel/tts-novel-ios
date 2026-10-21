import Foundation

/// The server's glossary (see `GlossaryTerm`), applied on the client for an
/// engine that has no glossary support of its own (`AppleTranslationEngine`).
/// Each term is replaced by its translation in brackets before the text goes
/// to the engine — "his Strength grew" → "his [Sức Mạnh] grew" — so the
/// engine treats it as one opaque unit and translates the rest of the
/// sentence around it. The brackets are stripped again afterwards.
///
/// The engine doesn't always leave a bracketed span alone: it may adjust the
/// diacritics ("[Phủ Binh]" → "[Phủ Bình]"), and it translates an English
/// word inside ("[class]" → "[Lớp học]") — exactly what a keep-original term
/// is meant to prevent. So `restore` puts every term's own text back instead
/// of trusting whatever came back inside the brackets.
///
/// Matching follows the server's Google glossary: case-sensitive (the terms
/// are capitalized system names — "Strength" — that also occur as ordinary
/// words — "strength"), whole words only, longest term first.
public struct Glossary: Sendable, Equatable {
    /// source → target, for the terms that apply.
    public let entries: [String: String]

    /// The terms `bookID` uses translating `source` → `target`: shared ones
    /// plus the book's own (which win over a shared term with the same
    /// source). Like the server, a term's language is inferred from its text
    /// (CJK → zh, otherwise en) and every target is Vietnamese.
    public init(terms: [GlossaryTerm], bookID: Int?, source: Locale.Language, target: Locale.Language) {
        guard target.languageCode?.identifier == "vi" else {
            self.init(entries: [:])
            return
        }
        let sourceCode = source.languageCode?.identifier ?? "en"
        var entries: [String: String] = [:]
        for term in terms where term.bookID == nil && Self.language(of: term.source) == sourceCode {
            entries[term.source] = term.target
        }
        for term in terms where term.bookID != nil && term.bookID == bookID && Self.language(of: term.source) == sourceCode {
            entries[term.source] = term.target
        }
        self.init(entries: entries)
    }

    public init(entries: [String: String]) {
        self.entries = entries.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        pattern = Self.pattern(for: Array(self.entries.keys))
    }

    public var isEmpty: Bool { entries.isEmpty }

    private let pattern: NSRegularExpression?

    public static func == (lhs: Glossary, rhs: Glossary) -> Bool { lhs.entries == rhs.entries }

    static func language(of text: String) -> String {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) } ? "zh" : "en"
    }

    /// One alternation of every term, longest first — NSRegularExpression
    /// takes the first alternative that matches, so "Dao Seed of Heaviness"
    /// wins over "Dao Seed" and "Dao" at the same position. Latin terms only
    /// match as whole words; CJK has no word boundaries to check.
    private static func pattern(for sources: [String]) -> NSRegularExpression? {
        guard !sources.isEmpty else { return nil }
        let alternatives = sources
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map { source -> String in
                let escaped = NSRegularExpression.escapedPattern(for: source)
                return language(of: source) == "zh" ? escaped : #"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#
            }
        return try? NSRegularExpression(pattern: "(?:" + alternatives.joined(separator: "|") + ")")
    }

    /// `text` as it should be sent to the engine, plus what `restore` needs.
    /// A term inside a bracket the chapter already has ("[Class: Undying
    /// Bulwark]") gets brackets of its own too — nested, which the engine
    /// keeps — except when it's that bracket's whole content ("[Strength]").
    public func protect(_ text: String) -> Protected {
        guard let pattern else { return Protected(text: text, spans: []) }
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return Protected(text: text, spans: []) }

        let wholeBracketTerms = Set(Self.bracketRanges(in: text).map { NSRange(location: $0.location + 1, length: $0.length - 2) })
        var output = ""
        var added: [Int: String] = [:]  // output location of an added "[" → target
        var cursor = 0
        for match in matches {
            let source = ns.substring(with: match.range)
            let target = entries[source] ?? source
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if wholeBracketTerms.contains(match.range) {
                output += target
            } else {
                added[(output as NSString).length] = target
                output += "[" + target + "]"
            }
            cursor = NSMaxRange(match.range)
        }
        output += ns.substring(from: cursor)

        // Every innermost bracketed span the engine will see, in order —
        // the ones added here and the ones the chapter already had ("[Fire
        // Bolt]"), since both come back the same way and have to be told
        // apart by position.
        let targets = Set(entries.values)
        let spans = Self.bracketRanges(in: output).map { range -> Protected.Span in
            if let target = added[range.location] { return Protected.Span(target: target, addedBrackets: true) }
            let content = (output as NSString).substring(with: NSRange(location: range.location + 1, length: range.length - 2))
            return Protected.Span(target: targets.contains(content) ? content : nil, addedBrackets: false)
        }
        return Protected(text: output, spans: spans)
    }

    /// The engine's translation of `protected.text`, with every glossary
    /// term put back as its own target text and the brackets `protect`
    /// added removed again.
    ///
    /// Bracketed spans in the translation are paired with `protected.spans`
    /// first by content (a span that came back as some term's target, give
    /// or take case and diacritics — robust to the engine reordering them,
    /// "[A]'s [B]" → "[B] của [A]"), then whatever's left in order.
    public func restore(_ translated: String, from protected: Protected) -> String {
        guard !protected.spans.isEmpty else { return translated }
        let ns = translated as NSString
        let found = Self.bracketRanges(in: translated)
        var assignment = [Int?](repeating: nil, count: found.count)
        var used = Set<Int>()
        for (foundIndex, range) in found.enumerated() {
            let content = Self.fold(ns.substring(with: NSRange(location: range.location + 1, length: range.length - 2)))
            // Of the spans with this target, the one closest in relative
            // position (the same term can occur several times).
            let candidates = protected.spans.indices.filter { !used.contains($0) && protected.spans[$0].target.map(Self.fold) == content }
            let position = Double(foundIndex) / Double(max(found.count, 1))
            if let best = candidates.min(by: {
                abs(Double($0) / Double(protected.spans.count) - position) < abs(Double($1) / Double(protected.spans.count) - position)
            }) {
                assignment[foundIndex] = best
                used.insert(best)
            }
        }
        var remaining = protected.spans.indices.filter { !used.contains($0) }[...]
        for foundIndex in found.indices where assignment[foundIndex] == nil {
            guard let next = remaining.popFirst() else { break }
            assignment[foundIndex] = next
        }

        var output = ""
        var cursor = 0
        for (foundIndex, range) in found.enumerated() {
            output += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            cursor = NSMaxRange(range)
            guard let spanIndex = assignment[foundIndex] else {
                output += ns.substring(with: range)
                continue
            }
            let span = protected.spans[spanIndex]
            let content = span.target ?? ns.substring(with: NSRange(location: range.location + 1, length: range.length - 2))
            output += span.addedBrackets ? content : "[" + content + "]"
        }
        output += ns.substring(from: cursor)
        return Self.tidy(output)
    }

    /// Innermost `[...]` ranges (brackets included), in order.
    private static func bracketRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        return bracketPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
    }

    private static let bracketPattern = try! NSRegularExpression(pattern: #"\[[^\[\]]*\]"#)

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Engines sometimes put a space between a restored term and the
    /// punctuation right after it ("Nhanh Nhẹn ."), never wanted — same
    /// clean-up as the server's `_tidy` for Google.
    private static let spaceBeforePunctuation = try! NSRegularExpression(pattern: #"(\w) +([,.!?;:…])"#)

    private static func tidy(_ text: String) -> String {
        spaceBeforePunctuation.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1$2"
        )
    }

    public struct Protected: Sendable, Equatable {
        public let text: String
        let spans: [Span]

        struct Span: Sendable, Equatable {
            /// What belongs inside — nil for a bracket the chapter already
            /// had that isn't exactly one term (left as the engine
            /// translated it).
            let target: String?
            /// Added by `protect`, so `restore` drops the brackets again.
            let addedBrackets: Bool
        }
    }
}

/// Wraps an engine without glossary support of its own (see `Glossary`).
public struct GlossaryTranslationEngine: TranslationEngine {
    public let base: TranslationEngine
    public let glossary: Glossary

    public init(base: TranslationEngine, glossary: Glossary) {
        self.base = base
        self.glossary = glossary
    }

    public var displayName: String { base.displayName }

    public func canTranslate(from source: Locale.Language, to target: Locale.Language) -> Bool {
        base.canTranslate(from: source, to: target)
    }

    public func translate(texts: [String], source: Locale.Language, target: Locale.Language) -> AsyncThrowingStream<(index: Int, text: String), Error> {
        guard !glossary.isEmpty else { return base.translate(texts: texts, source: source, target: target) }
        let glossary = glossary
        let protected = texts.map(glossary.protect)
        let stream = base.translate(texts: protected.map(\.text), source: source, target: target)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await (index, text) in stream {
                        continuation.yield((index, glossary.restore(text, from: protected[index])))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
