import Foundation

enum SeaG2PError: Error {
    case dictionaryMissing
    case openFailed
    case phonemizeFailed
}

/// Thin Swift wrapper around SeaG2P.xcframework's C ABI (vendored,
/// PyO3-stripped core of pnnbao97/sea-g2p, Apache-2.0) — the same
/// normalize-then-phonemize pipeline `vieneu_utils.phonemize_text.
/// phonemize_text()` runs server-side, so VI/EN code-switched text comes
/// out with the exact phoneme symbols VieNeu's models were trained on.
/// Opens the mmap'd dictionary once and keeps it for the process lifetime —
/// same rationale as PiperOfflineTTSService keeping its ONNX session alive.
actor SeaG2P {
    static let shared = SeaG2P()

    private var ctx: OpaquePointer?

    private init() {}

    /// Normalize (numbers/dates/units/abbreviations, trailing-punctuation
    /// normalization on) then phonemize `text` into VieNeu's phoneme
    /// alphabet.
    func phonemize(_ text: String) throws -> String {
        let ctx = try loadedContext()
        guard let out = text.withCString({ sea_g2p_phonemize(ctx, $0) }) else {
            throw SeaG2PError.phonemizeFailed
        }
        defer { sea_g2p_free_string(out) }
        return String(cString: out)
    }

    private func loadedContext() throws -> OpaquePointer {
        if let ctx { return ctx }
        guard let path = Bundle.main.path(forResource: "sea_g2p", ofType: "bin") else {
            throw SeaG2PError.dictionaryMissing
        }
        guard let opened = path.withCString({ sea_g2p_open($0) }) else {
            throw SeaG2PError.openFailed
        }
        ctx = opened
        return opened
    }
}
