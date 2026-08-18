import Foundation

/// Line-for-line port of `vieneu_utils`' v3 chunking pipeline
/// (`core_utils.split_into_sentences` / `pack_sentences_into_chunks` /
/// `_classify_gap`, `phonemize_text.normalize_to_chunks_v3_with_gaps`) —
/// splits raw text into <=256-char chunks at sentence boundaries (quote/
/// bracket-aware, so a `?` inside a quoted question doesn't end the
/// sentence), each carrying the boundary TYPE to the next chunk
/// (`"para"`/`"sentence"`/`"minor"`) for silence-gap duration. Chunking
/// operates on NORMALIZED text length (numbers/units spelled out) via
/// `SeaG2P.normalize`, matching the server exactly — chunk boundaries would
/// otherwise land in different places than the reference implementation
/// whenever a chunk contains digits/units.
///
/// `ReaderPlaybackController` already hands `synthesize(text:)` one sentence
/// at a time (its own upstream splitter), so in practice this almost always
/// returns a single chunk with no gaps — the packing/sub-split machinery
/// only kicks in for an unusually long sentence.
enum VieNeuV3TextChunker {
    static let gapSilenceSeconds: [String: Double] = ["para": 0.35, "sentence": 0.18, "minor": 0.04]

    static func silenceSeconds(forGap gap: String) -> Double {
        gapSilenceSeconds[gap] ?? gapSilenceSeconds["sentence"]!
    }

    /// `(chunks, gaps)` — `gaps[i]` is the boundary between `chunks[i]` and
    /// `chunks[i+1]`, so `gaps.count == chunks.count - 1`.
    static func chunksWithGaps(_ text: String, maxChars: Int = 256) async throws -> (chunks: [String], gaps: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], []) }

        let paragraphs = split(trimmed, by: newlineRegex)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var rawGaps: [String] = []
        for para in paragraphs {
            let sentences = splitIntoSentences(para)
            guard !sentences.isEmpty else { continue }

            var normalizedSentences: [String] = []
            normalizedSentences.reserveCapacity(sentences.count)
            for s in sentences {
                normalizedSentences.append(try await SeaG2P.shared.normalize(s, puncNorm: false))
            }

            let paraChunks = packSentencesIntoChunks(normalizedSentences, maxChars: maxChars)
            guard !paraChunks.isEmpty else { continue }
            if !chunks.isEmpty { rawGaps.append("para") }
            for (j, ch) in paraChunks.enumerated() {
                if j > 0 { rawGaps.append("sentence") } // reclassified below
                chunks.append(ch)
            }
        }

        var finalChunks: [String] = []
        finalChunks.reserveCapacity(chunks.count)
        for c in chunks {
            finalChunks.append(try SeaG2P.puncNorm(c))
        }

        var finalGaps: [String] = []
        finalGaps.reserveCapacity(rawGaps.count)
        for (i, g) in rawGaps.enumerated() {
            finalGaps.append(g == "para" ? "para" : classifyGap(finalChunks[i]))
        }
        return (finalChunks, finalGaps)
    }

    // MARK: - Sentence packing (operates on already-normalized text)

    private static func packSentencesIntoChunks(_ sentences: [String], maxChars: Int) -> [String] {
        var finalChunks: [String] = []
        var buffer = ""

        for rawSentence in sentences {
            let sentence = rawSentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { continue }

            if sentence.count > maxChars {
                if !buffer.isEmpty { finalChunks.append(buffer); buffer = "" }

                for rawPart in splitByMinorPunct(sentence) {
                    let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !part.isEmpty else { continue }

                    if buffer.count + 1 + part.count <= maxChars {
                        buffer = buffer.isEmpty ? part : buffer + " " + part
                    } else {
                        if !buffer.isEmpty { finalChunks.append(buffer) }
                        buffer = part
                        if buffer.count > maxChars {
                            var current = ""
                            for word in tokenizeKeepEn(buffer) {
                                if !current.isEmpty && current.count + 1 + word.count > maxChars {
                                    finalChunks.append(current)
                                    current = word
                                } else {
                                    current = current.isEmpty ? word : current + " " + word
                                }
                            }
                            buffer = current
                        }
                    }
                }
            } else {
                if !buffer.isEmpty && buffer.count + 1 + sentence.count > maxChars {
                    finalChunks.append(buffer)
                    buffer = sentence
                } else {
                    buffer = buffer.isEmpty ? sentence : buffer + " " + sentence
                }
            }
        }
        if !buffer.isEmpty { finalChunks.append(buffer) }
        return finalChunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func classifyGap(_ chunk: String) -> String {
        guard let last = chunk.reversed().first(where: { !$0.isWhitespace }) else { return "minor" }
        return ".!?".contains(last) ? "sentence" : "minor"
    }

    // MARK: - Quote/bracket-aware sentence scanner (port of `_scan_sentences`)

    private static let openToClose: [Character: Character] = [
        "(": ")", "[": "]", "{": "}",
        "\u{201C}": "\u{201D}", "\u{2018}": "\u{2019}",
        "\u{00AB}": "\u{00BB}", "\u{2039}": "\u{203A}",
        "\u{300C}": "\u{300D}", "\u{300E}": "\u{300F}",
    ]
    private static let closers: Set<Character> = Set(openToClose.values)
    private static let symmetricQuote: Character = "\""
    private static let sentEndChars: Set<Character> = [".", "!", "?", "\u{2026}"]
    private static let trailingClose: Set<Character> = closers.union(["\"", "'", "\u{2019}", "\u{201D}"])

    static func splitIntoSentences(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let (sentences, balanced) = scanSentences(text, quoteAware: true)
        if !balanced {
            return scanSentences(text, quoteAware: false).sentences
        }
        return sentences
    }

    private static func scanSentences(_ text: String, quoteAware: Bool) -> (sentences: [String], balanced: Bool) {
        let chars = Array(text)
        let n = chars.count
        var sentences: [String] = []
        var start = 0
        var i = 0
        var depth = 0
        var inQuote = false

        while i < n {
            let ch = chars[i]
            if quoteAware && ch == symmetricQuote {
                inQuote.toggle()
            } else if quoteAware && openToClose[ch] != nil {
                depth += 1
            } else if quoteAware && closers.contains(ch) {
                if depth > 0 { depth -= 1 }
            } else if sentEndChars.contains(ch) && depth == 0 && !inQuote {
                var j = i + 1
                while j < n && sentEndChars.contains(chars[j]) { j += 1 }
                while j < n && trailingClose.contains(chars[j]) { j += 1 }
                if j >= n || chars[j].isWhitespace {
                    sentences.append(String(chars[start..<j]))
                    start = j
                    i = j
                    continue
                }
                i = j
                continue
            }
            i += 1
        }
        if start < n {
            sentences.append(String(chars[start...]))
        }
        let trimmed = sentences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (trimmed, depth == 0 && !inQuote)
    }

    // MARK: - Regex helpers

    private static let newlineRegex = try! NSRegularExpression(pattern: "[\\r\\n]+")
    private static let minorPunctRegex = try! NSRegularExpression(pattern: "(?<=[,;:\\-\u{2013}\u{2014}])\\s+")
    private static let tokenKeepEnRegex = try! NSRegularExpression(
        pattern: "<en>.*?</en>|\\S+", options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static func splitByMinorPunct(_ text: String) -> [String] {
        split(text, by: minorPunctRegex)
    }

    private static func tokenizeKeepEn(_ text: String) -> [String] {
        matches(text, by: tokenKeepEnRegex)
    }

    private static func split(_ text: String, by regex: NSRegularExpression) -> [String] {
        let ns = text as NSString
        var result: [String] = []
        var last = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            result.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            last = match.range.location + match.range.length
        }
        result.append(ns.substring(from: last))
        return result
    }

    private static func matches(_ text: String, by regex: NSRegularExpression) -> [String] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}

