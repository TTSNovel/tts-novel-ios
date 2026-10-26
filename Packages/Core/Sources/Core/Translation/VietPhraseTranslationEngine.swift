import Foundation

/// Converts Chinese text to its Sino-Vietnamese (Hán Việt) reading,
/// character by character — e.g. 第九章 -> "Đệ cửu chương". Uses the
/// community `phienam.txt` table from the VietPhrase/QuickTranslator
/// fan-translation tools (bundled as a Core resource). This is a literal
/// 1-1 phonetic transliteration, not a phrase-level translation: word
/// order and grammar stay Chinese.
///
/// Kept in step with tts-webnovel's `site_assets/hanviet.js` — same
/// spacing, punctuation and capitalization rules — so a chapter reads the
/// same on the web and in the app.
public struct HanVietConverter: Sendable {
    private let table: [Unicode.Scalar: String]

    /// Parses `phienam.txt`'s `字=reading` lines.
    public init(dictionary text: String) {
        var table: [Unicode.Scalar: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].unicodeScalars
            let reading = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard key.count == 1, let scalar = key.first, !reading.isEmpty else { continue }
            table[scalar] = reading
        }
        self.table = table
    }

    /// The bundled table, loaded once on first use. Nil only if the
    /// resource is missing from the bundle (a packaging bug).
    public static let bundled: HanVietConverter? = {
        guard let url = Bundle.module.url(forResource: "phienam", withExtension: "txt") else {
            Log.fault(.translation, "Bundled Sino-Vietnamese table missing")
            return nil
        }
        guard let text = Log.attempt(.translation, "Bundled Sino-Vietnamese table unreadable", [:], { try String(contentsOf: url, encoding: .utf8) }) else { return nil }
        return HanVietConverter(dictionary: text)
    }()

    /// Full-width CJK punctuation -> its Vietnamese/ASCII equivalent, so the
    /// converted text reads naturally and `TextSegmentation`'s `.!?`
    /// sentence splitting works on it.
    private static let punctuation: [Unicode.Scalar: String] = [
        "。": ".", "．": ".", "，": ",", "、": ",", "！": "!", "？": "?", "：": ":", "；": ";",
        "（": "(", "）": ")", "【": "[", "】": "]", "《": "“", "》": "”", "〈": "“", "〉": "”",
        "「": "“", "」": "”", "『": "“", "』": "”", "～": "~", "\u{3000}": " ",
    ]
    /// A reading glues directly onto these (no space in between) — they
    /// open a bracket/quote, or are already whitespace.
    private static let openers: Set<Character> = [" ", "\n", "\t", "“", "‘", "(", "[", "\"", "'"]
    private static let sentenceEnds: Set<String> = [".", "!", "?", "…"]

    /// Han characters missing from the table pass through unchanged, as
    /// does everything that isn't Han.
    public func convert(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { table[$0] != nil }) else { return text }
        var out = ""
        // Whether the last thing appended was a reading / a (mapped) Chinese
        // punctuation mark — Chinese runs words and punctuation together
        // with no spaces, Vietnamese doesn't, so a word, number or opening
        // quote right after either needs one ("đệ1chương" -> "đệ 1 chương",
        // 力量：1.2 -> "lực lượng: 1.2", 他说：“…” -> "tha thuyết: “…”").
        var lastWasReading = false
        var lastWasCJKPunctuation = false
        // Capitalize the first reading of each sentence — start of text,
        // right after a sentence-ending mark, or at the start of quoted
        // speech.
        var sentenceStart = true
        for raw in text.unicodeScalars {
            if let reading = table[raw] {
                if let prev = out.last, !Self.openers.contains(prev) { out += " " }
                out += sentenceStart ? reading.prefix(1).uppercased() + reading.dropFirst() : reading
                sentenceStart = false
                lastWasReading = true
                lastWasCJKPunctuation = false
                continue
            }
            let mapped = Self.punctuation[raw]
            let ch = mapped ?? String(raw)
            let isAlphanumeric = Self.isAlphanumeric(ch.unicodeScalars.first!)
            if lastWasReading || lastWasCJKPunctuation, isAlphanumeric || ch == "“" { out += " " }
            out += ch
            lastWasReading = false
            lastWasCJKPunctuation = (mapped != nil && mapped != " ") || raw == "”"
            if Self.sentenceEnds.contains(ch) || ch == "“" {
                sentenceStart = true
            } else if isAlphanumeric {
                sentenceStart = false
            }
        }
        return out
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    /// Whether `text` is predominantly Chinese — a Vietnamese chapter with
    /// a stray leftover Han character or two doesn't count. A Han character
    /// carries a whole syllable, a Latin letter a fraction of one, so
    /// they're weighted accordingly (a mostly-Chinese chapter with some
    /// English names still counts). Same rule as hanviet.js's
    /// `needsTranslation`.
    public static func isPredominantlyChinese(_ text: String) -> Bool {
        var han = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if isHan(scalar) {
                han += 1
            } else if isLatinLetter(scalar) {
                latin += 1
            }
        }
        return han > 0 && han * 3 >= latin
    }

    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F: return true
        default: return false
        }
    }

    /// Basic Latin through Latin Extended-B, plus Latin Extended Additional
    /// (where most Vietnamese tone-marked letters live).
    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.properties.isAlphabetic else { return false }
        switch scalar.value {
        case 0x41...0x24F, 0x1E00...0x1EFF: return true
        default: return false
        }
    }
}

/// The "VietPhrase" `TranslationEngine` — Chinese -> Hán Việt via
/// `HanVietConverter`. Pure Swift and fully offline, so unlike
/// `OpusMTTranslationEngine` it runs on macOS too. Only serves zh -> vi:
/// a Hán Việt reading is Vietnamese by definition.
public final class VietPhraseTranslationEngine: TranslationEngine {
    public static let shared = VietPhraseTranslationEngine()

    private init() {}

    public var displayName: String { TranslationEngineKind.vietPhrase.displayName }

    public func canTranslate(from source: Locale.Language, to target: Locale.Language) -> Bool {
        source.languageCode == .chinese && target.languageCode == .vietnamese
    }

    /// Converting is a dictionary lookup per character — a whole chapter
    /// takes milliseconds — but it still runs off the caller's actor, and
    /// yields per sentence like the other engines so callers treat it the
    /// same way.
    public func translate(texts: [String], source: Locale.Language, target: Locale.Language) -> AsyncThrowingStream<(index: Int, text: String), Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                guard let converter = HanVietConverter.bundled else {
                    continuation.finish(throwing: VietPhraseError.dictionaryMissing)
                    return
                }
                for (index, text) in texts.enumerated() {
                    if Task.isCancelled { break }
                    continuation.yield((index, converter.convert(text)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum VietPhraseError: LocalizedError {
    case dictionaryMissing

    public var errorDescription: String? {
        "Không tìm thấy từ điển Hán Việt (phienam.txt)"
    }
}
