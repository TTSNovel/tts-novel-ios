import Foundation

enum VieNeuV3TokenizerError: Error {
    case fileMissing
    case badJSON
}

/// Byte-level BPE tokenizer for the v3-turbo phoneme vocabulary
/// (`tokenizer.json`: 419-entry vocab, 119 merges — the standard GPT-2-style
/// `Split(Isolated) + ByteLevel` pretokenizer feeding a plain BPE model, same
/// shape as `tokenizers.Tokenizer.from_file(...).encode(phonemes,
/// add_special_tokens=false).ids` in the reference engine). Re-implemented
/// by hand instead of vendoring HuggingFace's `tokenizers` Rust crate
/// because this one vocab is tiny (419 tokens/119 merges) and needs neither
/// that crate's training code nor its multi-model format support — the
/// pretokenizer regex + byte-to-unicode table + merge loop below are the
/// entire GPT-2 BPE algorithm, unabridged.
///
/// Special tokens (`<|pad|>`, `<|TEXT_PROMPT_START|>`, ...) never appear in
/// a phoneme string — those slot ids are added directly as integers by
/// `VieNeuV3OnnxEngine._buildRows`, mirroring `_build_rows` in the Python
/// engine — so this tokenizer only ever needs to BPE-encode plain phoneme
/// text, no special-token splitting.
struct VieNeuV3BPETokenizer {
    private let vocab: [String: Int]
    private let mergeRank: [Pair: Int]
    private var bpeCache: [String: [String]] = [:]

    private struct Pair: Hashable { let a: String; let b: String }

    init(contentsOf url: URL) throws {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw VieNeuV3TokenizerError.fileMissing
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              let vocab = model["vocab"] as? [String: Int],
              let merges = model["merges"] as? [[String]]
        else { throw VieNeuV3TokenizerError.badJSON }

        self.vocab = vocab
        var rank: [Pair: Int] = [:]
        rank.reserveCapacity(merges.count)
        for (i, pair) in merges.enumerated() where pair.count == 2 {
            rank[Pair(a: pair[0], b: pair[1])] = i
        }
        self.mergeRank = rank
    }

    /// Matches `tokenizer.encode(phonemes, add_special_tokens=false).ids`.
    mutating func encode(_ text: String) -> [Int] {
        var ids: [Int] = []
        for pretoken in Self.pretokenize(text) {
            let byteString = Self.byteLevelEncode(pretoken)
            for symbol in bpe(byteString) {
                if let id = vocab[symbol] {
                    ids.append(id)
                } else {
                    // Full byte coverage means every single-byte symbol is
                    // always in vocab (see byte-level base table below), so
                    // this only fires on a vocab/merges mismatch — skip
                    // rather than crash on this rare-corruption path.
                }
            }
        }
        return ids
    }

    // MARK: - BPE merge loop (standard GPT-2 algorithm)

    private mutating func bpe(_ word: [String]) -> [String] {
        let key = word.joined(separator: "\u{0}")
        if let cached = bpeCache[key] { return cached }
        guard word.count > 1 else {
            bpeCache[key] = word
            return word
        }

        var symbols = word
        while symbols.count > 1 {
            var bestRank = Int.max
            var bestIndex = -1
            for i in 0..<(symbols.count - 1) {
                if let r = mergeRank[Pair(a: symbols[i], b: symbols[i + 1])], r < bestRank {
                    bestRank = r
                    bestIndex = i
                }
            }
            guard bestIndex >= 0 else { break }

            var merged: [String] = []
            merged.reserveCapacity(symbols.count - 1)
            var i = 0
            while i < symbols.count {
                if i == bestIndex {
                    merged.append(symbols[i] + symbols[i + 1])
                    i += 2
                } else {
                    merged.append(symbols[i])
                    i += 1
                }
            }
            symbols = merged
        }
        bpeCache[key] = symbols
        return symbols
    }

    // MARK: - Pretokenizer (GPT-2 regex, `Split` behavior `Isolated`)

    /// `(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}|
    ///  ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+` — verbatim from
    /// `tokenizer.json`'s `pre_tokenizer.pretokenizers[0].pattern.Regex`.
    private static let pretokenizerRegex = try! NSRegularExpression(
        pattern: "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
    )

    private static func pretokenize(_ text: String) -> [String] {
        let ns = text as NSString
        return pretokenizerRegex
            .matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    // MARK: - GPT-2 byte<->unicode table

    /// `bytes_to_unicode()` (OpenAI's `gpt2/encoder.py`): printable Latin-1
    /// bytes map to themselves; the rest map to unused codepoints starting
    /// at U+0100, so every byte has a distinct, single-codepoint, whitespace-
    /// free visible representative to run BPE merges over.
    private static let byteEncodeTable: [Character] = {
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (b, c) in zip(bs, cs) {
            table[b] = Character(UnicodeScalar(c)!)
        }
        return table
    }()

    private static func byteLevelEncode(_ s: String) -> [String] {
        s.utf8.map { String(byteEncodeTable[Int($0)]) }
    }
}
