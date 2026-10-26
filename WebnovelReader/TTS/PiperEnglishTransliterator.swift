import Core
import Foundation

/// Rewrites English words inside a Vietnamese sentence as Vietnamese
/// syllables ("Harry Potter" -> "ha ri pót tơ") before Piper sees it.
///
/// Piper's espeak-ng `vi` voice switches English words over to English
/// phonemes (ɹ ɒ θ ə, consonant clusters, English codas) that the
/// vais1000 model never heard in training, so it mumbles or clips them —
/// and words espeak doesn't recognise as English get spelled out letter by
/// letter. Plain Vietnamese syllables only ever produce phonemes the model
/// knows. The goal is an intelligible "đọc lái" reading, not an accurate
/// English one.
///
/// Per Latin-script word:
/// 1. already a Vietnamese syllable -> kept as is
/// 2. ALL-CAPS acronym (≤5 letters) -> Vietnamese letter names ("FBI" -> "ép bi ai")
/// 3. hand-made dictionary entry (english_transliterations.csv = VietNormalizer's
///    non-vietnamese-words.csv, github.com/nghimestudio/vietnormalizer, MIT)
/// 4. otherwise English IPA (from espeak-ng `en`, via `phonemize`) mapped
///    onto Vietnamese syllables — covers made-up names like "Hogwarts".
final class PiperEnglishTransliterator {
    /// Returns espeak-ng `en` IPA for each word, phonemes separated by "_"
    /// (stress marks allowed), in the same order as the input.
    typealias Phonemizer = ([String]) -> [String]

    private let dictionary: [String: String]
    private let phonemize: Phonemizer
    private var ipaCache: [String: String] = [:]

    init(dictionary: [String: String], phonemize: @escaping Phonemizer) {
        self.dictionary = dictionary
        self.phonemize = phonemize
    }

    /// Bundled `english_transliterations.csv` ("word,ha-ri" rows, header first).
    static func loadBundledDictionary() -> [String: String] {
        guard
            let url = Bundle.main.url(forResource: "english_transliterations", withExtension: "csv"),
            let csv = Log.attempt(.tts, "English transliteration table unreadable", [:], { try String(contentsOf: url, encoding: .utf8) })
        else { return [:] }
        var dictionary: [String: String] = [:]
        // CRLF file: "\r\n" is a single Character, so split on isNewline.
        for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
            let parts = line.split(separator: ",", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: " ")
            if !key.isEmpty, !value.isEmpty, dictionary[key] == nil {
                dictionary[key] = value
            }
        }
        return dictionary
    }

    func transliterate(_ text: String) -> String {
        let words = text.matches(of: Self.wordPattern).map { String($0.output) }
        guard !words.isEmpty else { return text }

        // A mostly-English sentence also routes short English words that
        // happen to be valid Vietnamese spellings ("the", "to") through the
        // dictionary instead of reading them as Vietnamese.
        let foreignCount = words.filter { !Self.isVietnameseWord($0) }.count
        guard foreignCount > 0 else { return text }
        let sentenceIsEnglish = words.count >= 2 && foreignCount * 2 >= words.count

        let needIPA = Set(words.filter { word in
            !Self.isVietnameseWord(word) && Self.acronym(word) == nil
                && dictionary[word.lowercased()] == nil && ipaCache[word.lowercased()] == nil
        })
        if !needIPA.isEmpty {
            let ordered = Array(needIPA)
            for (word, ipa) in zip(ordered, phonemize(ordered)) {
                let spelled = Self.syllables(fromIPA: ipa)
                ipaCache[word.lowercased()] = spelled.isEmpty ? word : spelled
            }
        }

        return text.replacing(Self.wordPattern) { match in
            let word = String(match.output)
            let key = word.lowercased()
            if Self.isVietnameseWord(word) {
                return sentenceIsEnglish && !Self.hasVietnameseMarks(key) ? (dictionary[key] ?? word) : word
            }
            if let acronym = Self.acronym(word) { return acronym }
            return dictionary[key] ?? ipaCache[key] ?? word
        }
    }

    // MARK: - Word classification

    // Computed: Regex isn't Sendable, so it can't be a static let under Swift 6.
    private static var wordPattern: Regex<Substring> { #/[A-Za-zÀ-ỹĐđ]+(?:'[A-Za-z]+)*/# }

    private static let vietnameseMarks = Set("àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ")
    private static let vietnameseOnsets: Set<String> = [
        "b", "c", "d", "g", "h", "k", "l", "m", "n", "p", "q", "r", "s", "t", "v", "x",
        "ch", "gh", "gi", "kh", "ng", "nh", "ph", "qu", "th", "tr", "ngh",
    ]
    private static let vietnameseCodas: Set<String> = ["p", "t", "c", "m", "n", "ng", "ch", "nh"]
    private static let plainVowels = Set("ueoaiy")

    private static func hasVietnameseMarks(_ lowercased: String) -> Bool {
        lowercased.contains { vietnameseMarks.contains($0) }
    }

    /// Diacritics, or an unaccented spelling that fits Vietnamese syllable
    /// structure (onset + vowel run + allowed coda), e.g. "Minh", "ban".
    static func isVietnameseWord(_ word: String) -> Bool {
        let w = word.lowercased()
        if hasVietnameseMarks(w) { return true }
        if w.contains(where: { "fwzj'".contains($0) }) { return false }
        let chars = Array(w)
        guard let vowelStart = chars.firstIndex(where: { plainVowels.contains($0) }) else { return false }
        var vowelEnd = vowelStart
        while vowelEnd < chars.count, plainVowels.contains(chars[vowelEnd]) { vowelEnd += 1 }
        let onset = String(chars[..<vowelStart])
        let vowels = String(chars[vowelStart..<vowelEnd])
        let coda = String(chars[vowelEnd...])
        if coda.contains(where: { plainVowels.contains($0) }) { return false }
        if !onset.isEmpty, !vietnameseOnsets.contains(onset) { return false }
        if !coda.isEmpty, !vietnameseCodas.contains(coda) { return false }
        if ["ee", "oo", "ea", "ae", "ie"].contains(where: vowels.contains),
           !["oa", "oe", "ua", "uy"].contains(vowels) {
            return false
        }
        return true
    }

    private static let letterNames: [Character: String] = [
        "a": "ây", "b": "bi", "c": "xi", "d": "đi", "e": "i", "f": "ép", "g": "gi", "h": "ếch",
        "i": "ai", "j": "giây", "k": "cây", "l": "eo", "m": "em", "n": "en", "o": "âu", "p": "pi",
        "q": "kiu", "r": "a", "s": "ét", "t": "ti", "u": "diu", "v": "vi", "w": "đắp bờ liu",
        "x": "ích", "y": "oai", "z": "dét",
    ]

    private static func acronym(_ word: String) -> String? {
        guard word.count <= 5, word.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        return word.lowercased().compactMap { letterNames[$0] }.joined(separator: " ")
    }

    // MARK: - IPA -> Vietnamese syllables

    private struct Vowel {
        let open: String
        let closed: String
        /// Ends in a glide (aɪ, aʊ, ɔɪ) — can't take a Vietnamese coda.
        var glideEnding = false
    }

    private static let vowels: [String: Vowel] = [
        "iː": Vowel(open: "i", closed: "i"), "i": Vowel(open: "i", closed: "i"),
        "ɪ": Vowel(open: "i", closed: "i"), "ᵻ": Vowel(open: "i", closed: "i"),
        "e": Vowel(open: "e", closed: "e"), "ɛ": Vowel(open: "e", closed: "e"),
        "eɪ": Vowel(open: "ây", closed: "ê"), "eə": Vowel(open: "e", closed: "e"),
        "a": Vowel(open: "a", closed: "a"), "æ": Vowel(open: "a", closed: "a"),
        "ɑː": Vowel(open: "a", closed: "a"), "ɐ": Vowel(open: "a", closed: "a"),
        "ʌ": Vowel(open: "a", closed: "ă"), "ɒ": Vowel(open: "o", closed: "o"),
        "ɔː": Vowel(open: "o", closed: "o"), "ɔ": Vowel(open: "o", closed: "o"),
        "əʊ": Vowel(open: "ô", closed: "ô"), "oʊ": Vowel(open: "ô", closed: "ô"),
        "ʊ": Vowel(open: "u", closed: "u"), "uː": Vowel(open: "u", closed: "u"),
        "ə": Vowel(open: "ơ", closed: "ơ"), "ɜː": Vowel(open: "ơ", closed: "ơ"),
        "ɚ": Vowel(open: "ơ", closed: "ơ"), "ɪə": Vowel(open: "ia", closed: "i"),
        "ʊə": Vowel(open: "ua", closed: "u"),
        "aɪ": Vowel(open: "ai", closed: "ai", glideEnding: true),
        "aɪə": Vowel(open: "ai", closed: "ai", glideEnding: true),
        "aʊ": Vowel(open: "ao", closed: "ao", glideEnding: true),
        "ɔɪ": Vowel(open: "oi", closed: "oi", glideEnding: true),
    ]
    private static let shortVowels: Set<String> = ["ɪ", "e", "ɛ", "a", "æ", "ɒ", "ʌ", "ʊ"]
    /// After a short vowel these are doubled into a coda too: Potter -> pót tơ.
    private static let geminating: Set<String> = ["p", "b", "t", "d", "k", "ɡ", "g", "m", "n"]

    private static let onsets: [String: String] = [
        "p": "p", "b": "b", "t": "t", "d": "đ", "k": "c", "ɡ": "g", "g": "g", "f": "ph", "v": "v",
        "θ": "th", "ð": "đ", "s": "x", "z": "d", "ʃ": "s", "ʒ": "gi", "tʃ": "ch", "dʒ": "gi",
        "h": "h", "m": "m", "n": "n", "ŋ": "ng", "l": "l", "ɹ": "r", "r": "r", "j": "d", "w": "u",
    ]
    private static let codas: [String: String] = [
        "p": "p", "b": "p", "f": "p", "v": "p", "t": "t", "d": "t", "θ": "t", "ð": "t",
        "s": "t", "z": "t", "ʃ": "t", "ʒ": "t", "tʃ": "t", "dʒ": "t", "k": "c", "ɡ": "c", "g": "c",
        "m": "m", "n": "n", "ŋ": "ng", "l": "n",
    ]
    /// w-glide onset + nucleus: "wa" -> "oa", "wi" -> "uy".
    private static let wGlide: [String: String] = [
        "i": "uy", "e": "oe", "a": "oa", "ă": "oă", "ê": "uê", "ơ": "uơ", "o": "uo", "ô": "uô",
        "ai": "oai", "ây": "uây",
    ]
    private static let sacTone: [Character: Character] = [
        "a": "á", "ă": "ắ", "â": "ấ", "e": "é", "ê": "ế", "i": "í", "o": "ó", "ô": "ố", "ơ": "ớ",
        "u": "ú", "ư": "ứ", "y": "ý",
    ]

    static func phones(fromIPA ipa: String) -> [String] {
        let cleaned = ipa.replacingOccurrences(of: "ˈ", with: "")
            .replacingOccurrences(of: "ˌ", with: "")
            .replacingOccurrences(of: "ʲ", with: "")
        return cleaned.split(whereSeparator: { $0 == "_" || $0.isWhitespace }).flatMap { phone -> [String] in
            switch phone {
            case "əl": return ["ə", "l"]
            case "iə": return ["i", "ə"]
            default: return [String(phone)]
            }
        }
    }

    static func syllables(fromIPA ipa: String) -> String {
        let phones = phones(fromIPA: ipa)
        let vowelIndices = phones.indices.filter { vowels[phones[$0]] != nil }
        guard !vowelIndices.isEmpty else {
            return phones.compactMap { onsets[$0] }.map { spell(onset: $0, nucleus: "ơ", coda: "") }.joined(separator: " ")
        }

        var parts: [(onset: [String], vowel: String, coda: [String])] = []
        var onsetStart = 0
        for (n, vi) in vowelIndices.enumerated() {
            let isLast = n + 1 == vowelIndices.count
            let between = Array(phones[(vi + 1)..<(isLast ? phones.count : vowelIndices[n + 1])])
            var coda: [String] = []
            var nextOnsetStart = vi + 1
            if isLast {
                coda = between
                nextOnsetStart = phones.count
            } else if between.count == 1 {
                if shortVowels.contains(phones[vi]), geminating.contains(between[0]) {
                    coda = between
                }
            } else if between.count > 1 {
                coda = [between[0]]
                nextOnsetStart = vi + 2
            }
            parts.append((Array(phones[onsetStart..<vi]), phones[vi], coda))
            onsetStart = nextOnsetStart
        }

        var out: [String] = []
        for part in parts {
            // Vietnamese has no onset clusters: keep the last consonant
            // (or tr/qu) and give each extra one its own "ơ" syllable.
            var onset = ""
            var extra: ArraySlice<String> = []
            if part.onset.count >= 2, Array(part.onset.suffix(2)) == ["t", "ɹ"] {
                (extra, onset) = (part.onset.dropLast(2), "tr")
            } else if part.onset.count >= 2, Array(part.onset.suffix(2)) == ["k", "w"] {
                (extra, onset) = (part.onset.dropLast(2), "qu")
            } else if let last = part.onset.last {
                (extra, onset) = (part.onset.dropLast(), onsets[last] ?? "")
            }
            for consonant in extra {
                out.append(spell(onset: onsets[consonant] ?? "", nucleus: "ơ", coda: ""))
            }

            guard let vowel = vowels[part.vowel] else { continue }
            let coda = part.coda.first.flatMap { codas[$0] } ?? ""
            if vowel.glideEnding, !coda.isEmpty {
                // Mike -> mai cơ: the coda becomes its own syllable.
                out.append(spell(onset: onset, nucleus: vowel.open, coda: ""))
                out.append(spell(onset: onsets[part.coda[0]] ?? "", nucleus: "ơ", coda: ""))
            } else {
                out.append(spell(onset: onset, nucleus: coda.isEmpty ? vowel.open : vowel.closed, coda: coda))
            }
        }
        return out.joined(separator: " ")
    }

    /// One Vietnamese syllable with spelling fixes (c/k, g/gh, ng/ngh,
    /// -ch/-nh) and a sắc tone on stop codas, which Vietnamese requires.
    private static func spell(onset rawOnset: String, nucleus rawNucleus: String, coda rawCoda: String) -> String {
        var onset = rawOnset, nucleus = rawNucleus, coda = rawCoda
        if onset == "u" {
            onset = ""
            nucleus = wGlide[nucleus] ?? "u" + nucleus
        }
        let first = nucleus.first ?? "a"
        if onset == "c", "ieêy".contains(first) { onset = "k" }
        if onset == "g" || onset == "ng", "ieê".contains(first) { onset += "h" }
        if nucleus == "i" || nucleus == "ê" {
            if coda == "c" { coda = "ch" }
            if coda == "ng" { coda = "nh" }
        }
        if nucleus == "ă", coda.isEmpty { nucleus = "a" }
        if ["p", "t", "c", "ch"].contains(coda),
           let index = nucleus.indices.last(where: { sacTone[nucleus[$0]] != nil }),
           let toned = sacTone[nucleus[index]] {
            nucleus.replaceSubrange(index...index, with: String(toned))
        }
        return (onset + nucleus + coda).precomposedStringWithCanonicalMapping
    }
}
