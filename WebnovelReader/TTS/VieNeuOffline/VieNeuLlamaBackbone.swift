import Foundation
import llama

enum VieNeuBackboneError: Error {
    case modelMissing
    case modelLoadFailed
    case contextInitFailed
    case tokenizeFailed
    case decodeFailed
}

/// Drives VieNeu-TTS's legacy v2-Turbo GGUF backbone (`pnnbao-ump/VieNeu-TTS-
/// v2-Turbo-GGUF`, llama.cpp-standard — same load path as `Llama(model_path=
/// ...)` in the real `vieneu` package's turbo.py) through a plain llama.cpp
/// text-completion loop — no TTS-specific wiring needed on this side, since
/// the backbone just emits ordinary `<|speech_N|>` tokens as text
/// (`turbo.py:_format_turbo_prompt` / `utils.extract_speech_ids`). Audio
/// decode is a separate step (see VieNeuCodecDecoder) — this class only
/// produces the audio-code integers.
actor VieNeuLlamaBackbone {
    static let shared = VieNeuLlamaBackbone()

    private var model: OpaquePointer?
    private var vocab: OpaquePointer?

    private init() {}

    /// Matches turbo.py's `TurboVieNeuTTS.infer` sampling params exactly
    /// (temperature=0.4, top_k=50, top_p=0.95, min_p=0.05,
    /// repeat_penalty=1.15) so offline output follows the same distribution
    /// the reference Python pipeline does.
    func generateSpeechCodes(phonemes: String, maxTokens: Int32 = 2048) throws -> [Int32] {
        let model = try loadedModel()
        guard let vocab = llama_model_get_vocab(model) else { throw VieNeuBackboneError.modelLoadFailed }

        let prompt = "<|speaker_16|><|TEXT_PROMPT_START|>\(phonemes)<|TEXT_PROMPT_END|><|SPEECH_GENERATION_START|>"

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 2048 + UInt32(maxTokens)
        ctxParams.n_batch = 2048
        ctxParams.no_perf = true
        guard let ctx = llama_init_from_model(model, ctxParams) else {
            throw VieNeuBackboneError.contextInitFailed
        }
        defer { llama_free(ctx) }

        let promptTokens = try tokenize(vocab: vocab, text: prompt, addSpecial: true)
        let stopTokenId = singleTokenId(vocab: vocab, text: "<|SPEECH_GENERATION_END|>")

        var sparams = llama_sampler_chain_default_params()
        sparams.no_perf = true
        guard let sampler = llama_sampler_chain_init(sparams) else { throw VieNeuBackboneError.contextInitFailed }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(64, 1.15, 0.0, 0.0))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(50))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.4))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

        var generatedText = ""

        // Prime the context with the whole prompt in one decode. The
        // pointer `llama_batch_get_one` hands back is only valid for the
        // duration of this call — wrapping both the batch construction and
        // the decode in the same withUnsafeMutableBufferPointer closure
        // keeps it alive exactly that long (Swift's plain `&array` sugar
        // only guarantees validity for a single call, not for a batch
        // value stored and used later, which the original per-step `&`
        // pattern here violated).
        var promptTokensVar = promptTokens
        let promptDecodeOK = promptTokensVar.withUnsafeMutableBufferPointer { buf -> Bool in
            let batch = llama_batch_get_one(buf.baseAddress, Int32(buf.count))
            return llama_decode(ctx, batch) == 0
        }
        guard promptDecodeOK else { throw VieNeuBackboneError.decodeFailed }

        // Persistent one-token buffer for the rest of the loop — reused in
        // place each step instead of taking `&` of a fresh local var per
        // iteration (same pointer-lifetime hazard as above).
        let stepToken = UnsafeMutablePointer<llama_token>.allocate(capacity: 1)
        defer { stepToken.deallocate() }

        var produced = Int32(promptTokens.count)
        while produced < maxTokens {
            let newToken = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, newToken) || newToken == stopTokenId {
                break
            }

            var buf = [CChar](repeating: 0, count: 128)
            let n = llama_token_to_piece(vocab, newToken, &buf, Int32(buf.count), 0, true)
            if n > 0 {
                generatedText += String(cString: buf)
            }

            stepToken.pointee = newToken
            let batch = llama_batch_get_one(stepToken, 1)
            if llama_decode(ctx, batch) != 0 { throw VieNeuBackboneError.decodeFailed }
            produced += 1
        }

        return Self.extractSpeechIds(generatedText)
    }

    /// Matches `utils.extract_speech_ids`'s `RE_SPEECH_TOKEN =
    /// re.compile(r"<\|speech_(\d+)\|>")`.
    private static func extractSpeechIds(_ text: String) -> [Int32] {
        guard let regex = try? NSRegularExpression(pattern: "<\\|speech_(\\d+)\\|>") else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return Int32(ns.substring(with: match.range(at: 1)))
        }
    }

    private func tokenize(vocab: OpaquePointer, text: String, addSpecial: Bool) throws -> [llama_token] {
        let n = -llama_tokenize(vocab, text, Int32(text.utf8.count), nil, 0, addSpecial, true)
        guard n > 0 else { throw VieNeuBackboneError.tokenizeFailed }
        var tokens = [llama_token](repeating: 0, count: Int(n))
        let written = llama_tokenize(vocab, text, Int32(text.utf8.count), &tokens, n, addSpecial, true)
        guard written >= 0 else { throw VieNeuBackboneError.tokenizeFailed }
        return tokens
    }

    private func singleTokenId(vocab: OpaquePointer, text: String) -> llama_token {
        var tokens = [llama_token](repeating: 0, count: 4)
        let n = llama_tokenize(vocab, text, Int32(text.utf8.count), &tokens, 4, false, true)
        return n == 1 ? tokens[0] : LLAMA_TOKEN_NULL
    }

    private func loadedModel() throws -> OpaquePointer {
        if let model { return model }
        guard let path = Bundle.main.path(forResource: "vieneu-tts-v2-turbo", ofType: "gguf") else {
            throw VieNeuBackboneError.modelMissing
        }
        var params = llama_model_default_params()
        // CPU only (not the usual n_gpu_layers=99) — confirmed by direct
        // A/B on-device: offloading this specific backbone to Metal
        // produces numerically wrong logits (sampled tokens never form a
        // single valid `<|speech_N|>`, just raw control-byte garbage —
        // reproduced consistently across many sentences), while the exact
        // same GGUF+prompt on CPU decodes clean speech-token sequences
        // matching the llama-cpp-python reference bit-for-bit in kind. CPU
        // is also ~10x faster here in practice (5-6s/sentence vs the
        // Metal path's 50-70s of decoding garbage) — whatever the
        // Metal-backend bug is (possibly the fused Gated-Delta-Net kernel
        // this GGUF's architecture uses, per ggml's own build log), it
        // doesn't just cost quality here, it costs speed too.
        params.n_gpu_layers = 0
        guard let loaded = llama_model_load_from_file(path, params) else {
            throw VieNeuBackboneError.modelLoadFailed
        }
        model = loaded
        return loaded
    }
}
