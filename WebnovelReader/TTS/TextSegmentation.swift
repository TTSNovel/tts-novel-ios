import Foundation

// Mirrors reader.js's cleanTextForTTS()/splitSentences()/chunkLongSentence()
// (site_assets/reader.js:96-126) — same sentence-level chunking so a
// chapter produces a comparable number/size of TTS requests on both web
// and native, not one giant synthesis call per chapter.
enum TextSegmentation {
    private static let maxChars = 150

    static func cleaned(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "[·‧・•]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "~", with: "")
        s = s.replacingOccurrences(of: "\\.{2,}", with: ".", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sentences(from text: String) -> [String] {
        let pattern = "[^.!?]+[.!?]*\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        let raw = matches.isEmpty ? [text] : matches.map { nsText.substring(with: $0.range) }
        let parts = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 2 }
        return parts.flatMap(chunkLongSentence)
    }

    private static func chunkLongSentence(_ sentence: String) -> [String] {
        guard sentence.count > maxChars else { return [sentence] }
        var chunks: [String] = []
        var current = ""
        for part in sentence.split(separator: /,\s*/).map(String.init) {
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
}
