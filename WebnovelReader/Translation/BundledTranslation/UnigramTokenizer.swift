import Foundation

/// Reimplements SentencePiece's Unigram-LM encoding for a single
/// language's `.spm` model — Marian/OPUS-MT tokenizers use SentencePiece
/// under the hood, but there's no SentencePiece runtime bundled in this
/// app (adding Google's C++ library, or a Swift wrapper for it, is its own
/// dependency to vet), so this ports the algorithm directly against a
/// pre-extracted `{piece, score}` list instead of parsing the `.spm`
/// protobuf on-device.
///
/// Verified byte-for-byte against the real `sentencepiece` Python package
/// (`SentencePieceProcessor.encode(text, out_type=str)`) on representative
/// English sentences before being ported here — the encode algorithm
/// itself (Viterbi over piece log-scores) is exact; the one known
/// simplification is preprocessing (see `preprocess`), which skips
/// SentencePiece's "nmt_nfkc" precompiled normalizer (a custom charsmap
/// this doesn't parse) in favor of the plain dummy-prefix +
/// space-to-"▁" substitution that was actually validated. That agrees with
/// the real normalizer for ordinary prose; text with unusual Unicode
/// (exotic punctuation, full-width forms) may tokenize slightly
/// differently than the reference.
struct UnigramTokenizer {
    private struct Piece: Decodable { let piece: String; let score: Double }

    private let pieceScores: [String: Double]
    private let vocab: [String: Int]
    private let maxPieceLength: Int
    private let unkId: Int
    /// Score assigned to a single-scalar fallback step when no known piece
    /// matches — below every real piece's score so the Viterbi search only
    /// ever takes this path when nothing better exists, same role as
    /// SentencePiece's own unknown-piece lattice arcs (this model has
    /// `byte_fallback: false`, so the fallback unit is one Unicode scalar
    /// mapped straight to `<unk>`, not a UTF-8 byte piece).
    private let unkScore: Double

    init(piecesURL: URL, vocabURL: URL, unkToken: String = "<unk>") throws {
        let pieces = try JSONDecoder().decode([Piece].self, from: Data(contentsOf: piecesURL))
        var scores: [String: Double] = [:]
        scores.reserveCapacity(pieces.count)
        var maxLen = 1
        var minScore = 0.0
        for p in pieces {
            scores[p.piece] = p.score
            maxLen = max(maxLen, p.piece.unicodeScalars.count)
            minScore = min(minScore, p.score)
        }
        pieceScores = scores
        maxPieceLength = maxLen
        unkScore = minScore - 10

        vocab = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: vocabURL))
        unkId = vocab[unkToken] ?? 0
    }

    /// Encodes `text` into vocabulary ids via Unigram segmentation, ready
    /// to feed straight into the encoder ONNX graph's `input_ids`.
    func encode(_ text: String) -> [Int] {
        let scalars = Array(preprocess(text).unicodeScalars)
        return segment(scalars).map { vocab[$0] ?? unkId }
    }

    /// Dummy-prefix + space-escaping, matching this model's
    /// `add_dummy_prefix: true` / `escape_whitespaces: true` — see this
    /// type's doc comment for what's deliberately NOT reproduced here.
    private func preprocess(_ text: String) -> String {
        "▁" + text.replacingOccurrences(of: " ", with: "▁")
    }

    /// Unigram-LM Viterbi segmentation over Unicode scalars (not
    /// `Character`/grapheme clusters — SentencePiece and Python's `str`
    /// both index by codepoint, and this was verified against that).
    /// `O(n · maxPieceLength)`, fine at sentence length.
    private func segment(_ scalars: [Unicode.Scalar]) -> [String] {
        let n = scalars.count
        guard n > 0 else { return [] }
        let negInf = -Double.infinity
        var best = [Double](repeating: negInf, count: n + 1)
        best[0] = 0
        var backPos = [Int](repeating: -1, count: n + 1)
        var backPiece = [String?](repeating: nil, count: n + 1)

        for i in 1...n {
            let jLower = max(0, i - maxPieceLength)
            for j in jLower..<i {
                guard best[j] > negInf else { continue }
                let candidate = String(String.UnicodeScalarView(scalars[j..<i]))
                guard let score = pieceScores[candidate] else { continue }
                let total = best[j] + score
                if total > best[i] {
                    best[i] = total
                    backPos[i] = j
                    backPiece[i] = candidate
                }
            }
            let j = i - 1
            if best[j] > negInf {
                let total = best[j] + unkScore
                if total > best[i] {
                    best[i] = total
                    backPos[i] = j
                    backPiece[i] = nil
                }
            }
        }

        var result: [String] = []
        var i = n
        while i > 0 {
            result.append(backPiece[i] ?? "<unk>")
            i = backPos[i]
        }
        return result.reversed()
    }
}

/// Reverses Marian/SentencePiece tokenization for the *target* side —
/// joining generated pieces back into text is just "concatenate, then turn
/// every '▁' into a space and trim the leading one," with no Viterbi
/// search needed (unlike encoding). Verified to match
/// `SentencePieceProcessor.decode()` exactly for this model before being
/// ported here, which is why the target side doesn't need its own
/// `UnigramTokenizer` instance at all — only `source.spm`'s piece/score
/// table is needed on-device.
enum MarianDetokenizer {
    static func decode(_ pieces: [String]) -> String {
        pieces.joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
