import Foundation
import Accelerate

enum VieNeuV3EngineError: Error {
    case configMissing
    case configField(String)
    case assetMissing(String)
    case sessionRunFailed(String)
    case outputMissing(String)
    case noAudioGenerated
}

/// Torch-free port of `vieneu`'s `OnnxV3LiteEngine` (`_v3_turbo_engine/
/// onnx_runtime_lite.py`) — the actual v3-Turbo architecture the ONLINE
/// "vieneu" voice uses server-side (speaker-embedding-conditioned backbone +
/// single-layer cached acoustic decoder + MOSS audio codec), run entirely
/// on-device through 4 ONNX Runtime sessions (VieNeuV3OnnxSession, a
/// generic named-tensor graph runner shared by all 4). Embedding lookups,
/// the speaker-anchor projection, sampling, and the autoregressive frame
/// loop are plain Swift/Accelerate here exactly like they're plain NumPy in
/// the Python reference — only the 4 transformer/codec forward passes
/// themselves cross into ONNX Runtime, one `session.run` at a time, mirrored
/// call-for-call against that source (see each method's doc comment for the
/// exact Python counterpart) so the two stay auditable side by side.
///
/// Architecturally unrelated to VieNeuOfflineV2 (llama.cpp GGUF + a single
/// ONNX codec-decode call) beyond sharing the sea-g2p phonemizer — hence a
/// separate package instead of extending V2's classes.
actor VieNeuV3OnnxEngine {
    static let shared = VieNeuV3OnnxEngine()

    private init() {}

    // MARK: - Config (from config.json, see that file for the full field list)

    private var nVq = 0
    private var hidden = 0
    private var backboneLayers = 0
    private var backboneKVHeads = 0
    private var backboneHeadDim = 0
    private var localHeads = 0
    private var localHeadDim = 0
    private var audioVocab = 0
    private var audioPad = 0
    private var tps = 0
    private var tpe = 0
    private var sgs = 0
    private var eosSpeech = 0
    private var refSlot = 0
    private var defaultStyleId = 0
    private var speakerEmbeddingDim = 0

    // MARK: - Weights (from vieneu_v3_heads.npz)

    private var textEmb: [Float] = []      // (Vt, H) flat
    private var audioEmb: [Float] = []     // (n_vq, Va, H) flat
    private var xvecW: [Float] = []        // (H, spk_dim) flat
    private var xvecB: [Float] = []        // (H,)
    private var xvecLnW: [Float] = []      // (H,)
    private var xvecLnB: [Float] = []      // (H,)
    private var xvecLnEps: Float = 1e-5

    // MARK: - Sessions

    private var sessionPrefill: VieNeuV3OnnxSession!
    private var sessionDecodeStep: VieNeuV3OnnxSession!
    private var sessionAcoustic: VieNeuV3OnnxSession!
    private var sessionCodec: VieNeuV3OnnxSession!
    private var tokenizer: VieNeuV3BPETokenizer!
    private var loaded = false

    // MARK: - Loading

    private func ensureLoaded() throws {
        guard !loaded else { return }

        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("VieNeuOfflineV3") as URL?,
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path)
        else { throw VieNeuV3EngineError.assetMissing("VieNeuOfflineV3 resource directory") }

        guard let configData = FileManager.default.contents(atPath: dir.appendingPathComponent("config.json").path),
              let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
        else { throw VieNeuV3EngineError.configMissing }

        func intField(_ key: String) throws -> Int {
            guard let v = config[key] as? Int else { throw VieNeuV3EngineError.configField(key) }
            return v
        }

        nVq = try intField("n_vq")
        hidden = try intField("hidden_size")
        backboneLayers = try intField("num_hidden_layers")
        backboneKVHeads = try intField("num_key_value_heads")
        backboneHeadDim = try intField("head_dim")
        localHeads = try intField("local_num_attention_heads")
        localHeadDim = hidden / localHeads
        audioVocab = try intField("audio_vocab_size")
        audioPad = try intField("audio_pad_token_id")
        tps = try intField("text_prompt_start_token_id")
        tpe = try intField("text_prompt_end_token_id")
        sgs = try intField("speech_generation_start_token_id")
        eosSpeech = try intField("speech_generation_end_token_id")
        refSlot = try intField("audio_ref_slot_token_id")
        defaultStyleId = try intField("default_style_token_id")
        speakerEmbeddingDim = try intField("speaker_embedding_dim")

        let npz = try VieNeuV3Npz(contentsOf: dir.appendingPathComponent("vieneu_v3_heads.npz"))
        textEmb = try npz.floatArray("text_emb")
        audioEmb = try npz.floatArray("audio_emb")
        xvecW = try npz.floatArray("xvec_w")
        xvecB = try npz.floatArray("xvec_b")
        xvecLnW = try npz.floatArray("xvec_ln_w")
        xvecLnB = try npz.floatArray("xvec_ln_b")
        xvecLnEps = try npz.scalarFloat("xvec_ln_eps")

        tokenizer = try VieNeuV3BPETokenizer(contentsOf: dir.appendingPathComponent("tokenizer.json"))

        let threads = Int32(max(1, min(ProcessInfo.processInfo.activeProcessorCount / 2, 4)))
        func openSession(_ filename: String) throws -> VieNeuV3OnnxSession {
            let path = dir.appendingPathComponent(filename).path
            guard FileManager.default.fileExists(atPath: path) else { throw VieNeuV3EngineError.assetMissing(filename) }
            return try VieNeuV3OnnxSession(modelPath: path, intraOpThreads: threads)
        }
        sessionPrefill = try openSession("vieneu_prefill.onnx")
        sessionDecodeStep = try openSession("vieneu_decode_step.onnx")
        sessionAcoustic = try openSession("vieneu_acoustic_cached.onnx")
        sessionCodec = try openSession("moss_audio_tokenizer_decode_full.onnx")

        loaded = true
    }

    // MARK: - Public entry point

    /// Mirrors `OnnxV3LiteEngine.infer` (non-streaming path): phonemize is
    /// the caller's job (see VieNeuOfflineV3TTSService — same phonemizer as
    /// V2), everything from BPE-encoding onward happens here.
    func synthesize(
        phonemes: String,
        speakerEmb: [Float],
        refCodes: [[Int]],
        temperature: Double = 0.8,
        topK: Int = 25,
        topP: Double = 0.95,
        maxNewFrames: Int = 600,
        repetitionPenalty: Double = 1.2
    ) throws -> [Float] {
        try ensureLoaded()

        let phoneIds = tokenizer.encode(phonemes)
        let anchor = speakerAnchor(speakerEmb)
        let rows = buildRows(phoneIds: phoneIds, refCodes: refCodes, styleId: defaultStyleId)
        let tPrompt = rows.count
        let promptEmbeds = embedRows(rows, anchor: anchor)

        // ── Prefill ──────────────────────────────────────────────────────
        let preOutNames = ["hidden"] + (0..<backboneLayers).map { "present_k_\($0)" }
            + (0..<backboneLayers).map { "present_v_\($0)" }
        let preOut = try run(sessionPrefill, inputs: [
            floatTensor("inputs_embeds", shape: [1, tPrompt, hidden], promptEmbeds),
        ], outputNames: preOutNames)

        var pastK: [[Float]] = []
        var pastV: [[Float]] = []
        pastK.reserveCapacity(backboneLayers)
        pastV.reserveCapacity(backboneLayers)
        for i in 0..<backboneLayers {
            pastK.append(try floats(preOut, "present_k_\(i)"))
            pastV.append(try floats(preOut, "present_v_\(i)"))
        }
        var pastLen = tPrompt
        var h = Array(try floats(preOut, "hidden").suffix(hidden)) // last position's (H,)

        // ── Autoregressive frame loop ───────────────────────────────────
        var hist: [Set<Int>]? = abs(repetitionPenalty - 1.0) > 1e-9
            ? Array(repeating: Set<Int>(), count: nVq) : nil
        var frames: [[Int]] = []
        frames.reserveCapacity(min(maxNewFrames, 256))

        for t in 0..<maxNewFrames {
            let (codes, eos) = try acousticFrame(
                h: h, anchor: anchor, temperature: temperature, topK: topK, topP: topP,
                repPen: repetitionPenalty, hist: &hist
            )
            frames.append(codes)
            if eos { break }

            var slotRow = [Int](repeating: audioPad, count: nVq + 1)
            slotRow[0] = sgs
            for ch in 0..<nVq { slotRow[ch + 1] = codes[ch] }
            let se = embedRows([slotRow], anchor: anchor)

            let decOutNames = ["hidden"] + (0..<backboneLayers).map { "present_k_\($0)" }
                + (0..<backboneLayers).map { "present_v_\($0)" }
            let decIn = [
                floatTensor("inputs_embeds", shape: [1, 1, hidden], se),
                int64Tensor("position_ids", shape: [1, 1], [Int64(tPrompt + t)]),
            ] + pastFeed(pastK, pastV, heads: backboneKVHeads, headDim: backboneHeadDim, len: pastLen)

            let decOut = try run(sessionDecodeStep, inputs: decIn, outputNames: decOutNames)
            h = try floats(decOut, "hidden")
            pastK.removeAll(keepingCapacity: true)
            pastV.removeAll(keepingCapacity: true)
            for i in 0..<backboneLayers {
                pastK.append(try floats(decOut, "present_k_\(i)"))
                pastV.append(try floats(decOut, "present_v_\(i)"))
            }
            pastLen += 1
        }

        guard !frames.isEmpty else { throw VieNeuV3EngineError.noAudioGenerated }
        return try decodeCodes(frames)
    }

    // MARK: - Speaker anchor (Linear(spkDim->H) + LayerNorm, mirrors `_speaker_anchor`)

    private func speakerAnchor(_ speakerEmb: [Float]) -> [Float] {
        var v = [Float](repeating: 0, count: hidden)
        // v = speakerEmb @ xvecW^T + xvecB, xvecW row-major (H, spkDim)
        xvecW.withUnsafeBufferPointer { w in
            speakerEmb.withUnsafeBufferPointer { x in
                v.withUnsafeMutableBufferPointer { y in
                    cblas_sgemv(
                        CblasRowMajor, CblasNoTrans, Int32(hidden), Int32(speakerEmbeddingDim),
                        1.0, w.baseAddress, Int32(speakerEmbeddingDim),
                        x.baseAddress, 1, 0.0, y.baseAddress, 1
                    )
                }
            }
        }
        for h in 0..<hidden { v[h] += xvecB[h] }

        var mean: Float = 0
        vDSP_meanv(v, 1, &mean, vDSP_Length(hidden))
        var negMean = -mean
        var centered = [Float](repeating: 0, count: hidden)
        vDSP_vsadd(v, 1, &negMean, &centered, 1, vDSP_Length(hidden))
        var variance: Float = 0
        vDSP_measqv(centered, 1, &variance, vDSP_Length(hidden))
        let denom = (variance + xvecLnEps).squareRoot()
        var out = [Float](repeating: 0, count: hidden)
        for h in 0..<hidden { out[h] = centered[h] / denom * xvecLnW[h] + xvecLnB[h] }
        return out
    }

    // MARK: - Row/embedding build (mirrors `_build_rows` / `_embed_rows`)

    private func buildRows(phoneIds: [Int], refCodes: [[Int]], styleId: Int) -> [[Int]] {
        let textIds = [styleId, tps] + phoneIds + [tpe]
        var rows: [[Int]] = textIds.map { id in
            var row = [Int](repeating: audioPad, count: nVq + 1)
            row[0] = id
            return row
        }
        for codeRow in refCodes {
            var row = [Int](repeating: audioPad, count: nVq + 1)
            row[0] = refSlot
            for ch in 0..<min(nVq, codeRow.count) { row[ch + 1] = codeRow[ch] }
            rows.append(row)
        }
        return rows
    }

    private func embedRows(_ rows: [[Int]], anchor: [Float]?) -> [Float] {
        let T = rows.count
        var emb = [Float](repeating: 0, count: T * hidden)
        emb.withUnsafeMutableBufferPointer { dst in
            textEmb.withUnsafeBufferPointer { textTable in
                audioEmb.withUnsafeBufferPointer { audioTable in
                    for t in 0..<T {
                        let row = rows[t]
                        let dstBase = t * hidden
                        let srcBase = row[0] * hidden
                        for h in 0..<hidden { dst[dstBase + h] = textTable[srcBase + h] }
                        for ch in 0..<nVq {
                            let id = row[ch + 1]
                            guard id != audioPad else { continue }
                            let aBase = (ch * audioVocab + id) * hidden
                            for h in 0..<hidden { dst[dstBase + h] += audioTable[aBase + h] }
                        }
                        if let anchor {
                            for h in 0..<hidden { dst[dstBase + h] += anchor[h] }
                        }
                    }
                }
            }
        }
        return emb
    }

    // MARK: - Acoustic frame (single-layer cached local transformer, mirrors `_acoustic_frame`)

    private func acousticFrame(
        h: [Float], anchor: [Float]?, temperature: Double, topK: Int, topP: Double, repPen: Double,
        hist: inout [Set<Int>]?
    ) throws -> (codes: [Int], eos: Bool) {
        let txt = Array(textEmb[(sgs * hidden)..<((sgs + 1) * hidden)])
        var tokenEmb = h
        tokenEmb.append(contentsOf: txt) // (2, H) flat: [cond; txt]

        var out = try run(sessionAcoustic, inputs: [
            floatTensor("token_emb", shape: [1, 2, hidden], tokenEmb),
            int64Tensor("position_ids", shape: [1, 2], [0, 1]),
            floatTensor("past_k_0", shape: [1, localHeads, 0, localHeadDim], []),
            floatTensor("past_v_0", shape: [1, localHeads, 0, localHeadDim], []),
        ], outputNames: ["hidden", "present_k_0", "present_v_0"])

        var hiddenOut = try floats(out, "hidden") // (2, H) flat
        let slot0 = Array(hiddenOut[0..<hidden])
        var pos1 = Array(hiddenOut[hidden..<(2 * hidden)])
        var pk = try floats(out, "present_k_0")
        var pv = try floats(out, "present_v_0")
        var localLen = 2

        var codes: [Int] = []
        codes.reserveCapacity(nVq)
        codes.append(try sampleChannel(0, from: pos1, temperature: temperature, topK: topK, topP: topP, repPen: repPen, hist: &hist))

        for ch in 1..<nVq {
            let prevCode = codes[codes.count - 1]
            let embBase = ((ch - 1) * audioVocab + prevCode) * hidden
            let stepEmb = Array(audioEmb[embBase..<(embBase + hidden)])

            out = try run(sessionAcoustic, inputs: [
                floatTensor("token_emb", shape: [1, 1, hidden], stepEmb),
                int64Tensor("position_ids", shape: [1, 1], [Int64(ch + 1)]),
                floatTensor("past_k_0", shape: [1, localHeads, localLen, localHeadDim], pk),
                floatTensor("past_v_0", shape: [1, localHeads, localLen, localHeadDim], pv),
            ], outputNames: ["hidden", "present_k_0", "present_v_0"])

            hiddenOut = try floats(out, "hidden") // (1, H)
            pk = try floats(out, "present_k_0")
            pv = try floats(out, "present_v_0")
            localLen += 1

            codes.append(try sampleChannel(ch, from: hiddenOut, temperature: temperature, topK: topK, topP: topP, repPen: repPen, hist: &hist))
        }

        var textLogits = [Float](repeating: 0, count: textEmb.count / hidden)
        matVec(matrix: textEmb, rows: textLogits.count, cols: hidden, vec: slot0, out: &textLogits)
        let eos = (Self.argmax(textLogits) == eosSpeech)
        return (codes, eos)
    }

    private func sampleChannel(
        _ ch: Int, from vec: [Float], temperature: Double, topK: Int, topP: Double, repPen: Double,
        hist: inout [Set<Int>]?
    ) throws -> Int {
        var logits = [Float](repeating: 0, count: audioVocab)
        let base = ch * audioVocab * hidden
        audioEmb.withUnsafeBufferPointer { table in
            let tablePtr = table.baseAddress! + base
            matVecPtr(matrix: tablePtr, rows: audioVocab, cols: hidden, vec: vec, out: &logits)
        }
        let prev = hist?[ch] ?? []
        let code = Self.sample(logits: logits, temperature: temperature, topK: topK, topP: topP, repPen: repPen, prev: prev)
        hist?[ch].insert(code)
        return code
    }

    // MARK: - Sampling (mirrors `_sample`)

    private static func sample(logits: [Float], temperature: Double, topK: Int, topP: Double, repPen: Double, prev: Set<Int>) -> Int {
        var logits = logits
        if abs(repPen - 1.0) > 1e-9 && !prev.isEmpty {
            for idx in prev {
                let v = logits[idx]
                logits[idx] = v < 0 ? v * Float(repPen) : v / Float(repPen)
            }
        }
        guard temperature > 0 else { return argmax(logits) }

        let invTemp = Float(1.0 / temperature)
        for i in 0..<logits.count { logits[i] *= invTemp }

        var candidates = Array(0..<logits.count)
        if topK > 0 && topK < logits.count {
            candidates.sort { logits[$0] > logits[$1] }
            candidates = Array(candidates.prefix(topK))
        } else {
            candidates.sort { logits[$0] > logits[$1] }
        }

        var probs = softmax(candidates.map { logits[$0] })
        if topP > 0 && topP < 1.0 {
            var cum: Float = 0
            for i in 0..<probs.count {
                let before = cum
                cum += probs[i]
                if before >= Float(topP) { probs[i] = 0 }
            }
            let sum = probs.reduce(0, +)
            if sum > 0 { for i in 0..<probs.count { probs[i] /= sum } }
        }

        let r = Float.random(in: 0..<1)
        var cum: Float = 0
        for (i, p) in probs.enumerated() {
            cum += p
            if r < cum { return candidates[i] }
        }
        return candidates[candidates.count - 1]
    }

    private static func softmax(_ xs: [Float]) -> [Float] {
        guard let m = xs.max() else { return [] }
        let exps = xs.map { Foundation.exp($0 - m) }
        let s = exps.reduce(0, +)
        guard s > 0 else { return exps.map { _ in 0 } }
        return exps.map { $0 / s }
    }

    private static func argmax(_ xs: [Float]) -> Int {
        var best = 0
        var bestV = -Float.infinity
        for (i, v) in xs.enumerated() where v > bestV { bestV = v; best = i }
        return best
    }

    // MARK: - Codec decode (mirrors `_decode_codes`)

    private func decodeCodes(_ frames: [[Int]]) throws -> [Float] {
        let t = frames.count
        var codesFlat = [Int32](repeating: 0, count: t * nVq)
        for i in 0..<t {
            for ch in 0..<nVq { codesFlat[i * nVq + ch] = Int32(frames[i][ch]) }
        }
        let out = try run(sessionCodec, inputs: [
            int32Tensor("audio_codes", shape: [1, t, nVq], codesFlat),
            int32Tensor("audio_code_lengths", shape: [1], [Int32(t)]),
        ], outputNames: ["audio"])

        guard let tensor = out["audio"] else { throw VieNeuV3EngineError.outputMissing("audio") }
        let shape = tensor.shape.map { $0.intValue }
        guard shape.count == 3 else { throw VieNeuV3EngineError.outputMissing("audio shape") }
        let channels = shape[1]
        let sampleCount = shape[2]
        let flat = dataToFloats(tensor.data)

        var result = [Float](repeating: 0, count: sampleCount)
        for c in 0..<channels {
            let base = c * sampleCount
            for n in 0..<sampleCount { result[n] += flat[base + n] }
        }
        let scale = 1.0 / Float(channels)
        for n in 0..<sampleCount { result[n] *= scale }
        return result
    }

    // MARK: - Matvec helpers (Accelerate BLAS)

    private func matVec(matrix: [Float], rows: Int, cols: Int, vec: [Float], out: inout [Float]) {
        matrix.withUnsafeBufferPointer { m in
            matVecPtr(matrix: m.baseAddress!, rows: rows, cols: cols, vec: vec, out: &out)
        }
    }

    private func matVecPtr(matrix: UnsafePointer<Float>, rows: Int, cols: Int, vec: [Float], out: inout [Float]) {
        vec.withUnsafeBufferPointer { x in
            out.withUnsafeMutableBufferPointer { y in
                cblas_sgemv(
                    CblasRowMajor, CblasNoTrans, Int32(rows), Int32(cols),
                    1.0, matrix, Int32(cols), x.baseAddress, 1, 0.0, y.baseAddress, 1
                )
            }
        }
    }

    // MARK: - ORT session tensor plumbing

    private func run(_ session: VieNeuV3OnnxSession, inputs: [VieNeuV3Tensor], outputNames: [String]) throws -> [String: VieNeuV3Tensor] {
        let out = try session.run(withInputs: inputs, outputNames: outputNames)
        var dict: [String: VieNeuV3Tensor] = [:]
        for t in out { dict[t.name] = t }
        return dict
    }

    private func floats(_ dict: [String: VieNeuV3Tensor], _ name: String) throws -> [Float] {
        guard let t = dict[name] else { throw VieNeuV3EngineError.outputMissing(name) }
        return dataToFloats(t.data)
    }

    private func floatTensor(_ name: String, shape: [Int], _ values: [Float]) -> VieNeuV3Tensor {
        VieNeuV3Tensor(name: name, dtype: .float32, shape: shape.map { NSNumber(value: $0) }, data: floatsToData(values))
    }

    private func int64Tensor(_ name: String, shape: [Int], _ values: [Int64]) -> VieNeuV3Tensor {
        VieNeuV3Tensor(name: name, dtype: .int64, shape: shape.map { NSNumber(value: $0) }, data: int64sToData(values))
    }

    private func int32Tensor(_ name: String, shape: [Int], _ values: [Int32]) -> VieNeuV3Tensor {
        VieNeuV3Tensor(name: name, dtype: .int32, shape: shape.map { NSNumber(value: $0) }, data: int32sToData(values))
    }

    /// `past_k_i`/`past_v_i` feed for the backbone (12 layers, uniform
    /// `(1, kvHeads, len, headDim)` shape) — mirrors `_past_feed`.
    private func pastFeed(_ pastK: [[Float]], _ pastV: [[Float]], heads: Int, headDim: Int, len: Int) -> [VieNeuV3Tensor] {
        var result: [VieNeuV3Tensor] = []
        result.reserveCapacity(pastK.count + pastV.count)
        for (i, k) in pastK.enumerated() {
            result.append(floatTensor("past_k_\(i)", shape: [1, heads, len, headDim], k))
        }
        for (i, v) in pastV.enumerated() {
            result.append(floatTensor("past_v_\(i)", shape: [1, heads, len, headDim], v))
        }
        return result
    }
}

// MARK: - Data <-> typed array conversion

private func dataToFloats(_ data: Data) -> [Float] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

private func floatsToData(_ values: [Float]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func int64sToData(_ values: [Int64]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func int32sToData(_ values: [Int32]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}
