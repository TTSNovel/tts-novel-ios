import Foundation

enum OpusMTTranslationError: Error {
    case unsupportedLanguage
    case assetMissing(String)
    case outputMissing(String)
}

/// On-device translation via a bundled Marian/OPUS-MT encoder-decoder ONNX
/// model per supported source/target language pair — the offline-capable,
/// always-available fallback engine (see `TranslationEngine`'s doc comment
/// for how this fits alongside `AppleTranslationEngine`). Named after the
/// specific model family it runs, not a generic "the bundled engine" —
/// there will likely be other small on-device model *types* added later
/// (a different architecture, not just another OPUS-MT language pair —
/// those just extend `supportedPairs` below), each getting its own
/// `TranslationEngine`-conforming type with its own specific name, same as
/// this one. Runs entirely through ONNX Runtime, the same runtime already
/// vendored for offline TTS (Piper/VieNeu) — see `TranslationOnnxSession`'s
/// doc comment for why this uses its own small ObjC++ bridge rather than
/// VieNeuV3's.
///
/// Quality note (from real testing against this exact model before
/// integration): this is a small (~77M parameter) bilingual model — solid
/// on short/simple sentences, but on longer novel-style prose it can drop
/// clauses or mangle character names, more than just "a bit stiff." It's
/// meant as a lightweight, always-offline backup, not a quality-equivalent
/// replacement for Apple's on-device Translation framework.
actor OpusMTTranslationEngine: TranslationEngine {
    static let shared = OpusMTTranslationEngine()

    nonisolated var displayName: String { "OPUS-MT (offline)" }

    private init() {}

    /// Fixed per bundled model — Marian/OPUS-MT's architecture (Marian
    /// "base": 6 encoder + 6 decoder layers, 8 heads, 64-dim heads) and the
    /// handful of special-token ids baked in at export time (see
    /// config.json/vocab.json from the source model, not re-parsed
    /// on-device to avoid a config-file dependency for values that never
    /// change once a model is bundled).
    private struct LanguagePair {
        let sourceLanguageCode: String
        /// The one target language this bundled model was actually trained
        /// for — unlike `AppleTranslationEngine`, which can serve whatever
        /// `primaryLanguage` the user picks, this model's weights only ever
        /// produce this language; `canTranslate`/`translate` reject any
        /// other requested target.
        let targetLanguageCode: String
        let resourceDirName: String
        /// OPUS-MT's "one-to-many" models require a `>>xxx<<` target-
        /// language tag prepended to the source text (see
        /// Helsinki-NLP/opus-mt-en-vi's model card) — nil for a model
        /// that's already a dedicated single-direction pair.
        let targetLanguageTag: String?
        let numLayers: Int
        let numHeads: Int
        let headDim: Int
        let decoderStartTokenId: Int
        let eosTokenId: Int
    }

    private static let supportedPairs: [LanguagePair] = [
        LanguagePair(
            sourceLanguageCode: "en", targetLanguageCode: "vi", resourceDirName: "en-vi", targetLanguageTag: ">>vie<<",
            numLayers: 6, numHeads: 8, headDim: 64, decoderStartTokenId: 53684, eosTokenId: 0
        )
    ]

    private struct LoadedModel {
        let pair: LanguagePair
        let tokenizer: UnigramTokenizer
        let idToPiece: [Int: String]
        let encoder: TranslationOnnxSession
        let decoder: TranslationOnnxSession
    }

    private var loaded: [String: LoadedModel] = [:]
    private(set) var currentProgress: TranslationProgress?

    var translationProgress: TranslationProgress? { currentProgress }

    nonisolated func canTranslate(from source: Locale.Language, to target: Locale.Language) -> Bool {
        guard let sourceCode = source.languageCode?.identifier, let targetCode = target.languageCode?.identifier else { return false }
        return Self.supportedPairs.contains { $0.sourceLanguageCode == sourceCode && $0.targetLanguageCode == targetCode }
    }

    func translate(texts: [String], source: Locale.Language, target: Locale.Language) async throws -> [String] {
        guard let sourceCode = source.languageCode?.identifier, let targetCode = target.languageCode?.identifier,
              let pair = Self.supportedPairs.first(where: { $0.sourceLanguageCode == sourceCode && $0.targetLanguageCode == targetCode })
        else { throw OpusMTTranslationError.unsupportedLanguage }
        let model = try loadModelIfNeeded(pair: pair)
        currentProgress = TranslationProgress(completed: 0, total: texts.count)
        var results: [String] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            results.append(try translateOne(text, model: model))
            currentProgress = TranslationProgress(completed: results.count, total: texts.count)
            // `translateOne` is entirely synchronous (ONNX Runtime calls are
            // plain blocking Obj-C, no `await` inside) — without this, this
            // actor method never actually suspends until the whole loop is
            // done, so a concurrent `await engine.translationProgress` call
            // (see ReaderPlaybackController's progress poller) just queues
            // behind this method and never gets a turn until it's already
            // finished, making `translationProgress` appear to jump straight
            // from nil to done instead of advancing — confirmed via a real
            // Simulator run before this fix (progress samples came back
            // empty for a 37-sentence/7.7s translation).
            await Task.yield()
        }
        currentProgress = nil
        return results
    }

    private func loadModelIfNeeded(pair: LanguagePair) throws -> LoadedModel {
        let key = "\(pair.sourceLanguageCode)-\(pair.targetLanguageCode)"
        if let existing = loaded[key] { return existing }
        guard let dir = Bundle.main.resourceURL?
            .appendingPathComponent("BundledTranslation").appendingPathComponent(pair.resourceDirName),
            FileManager.default.fileExists(atPath: dir.path)
        else { throw OpusMTTranslationError.assetMissing("BundledTranslation/\(pair.resourceDirName)") }

        let tokenizer = try UnigramTokenizer(
            piecesURL: dir.appendingPathComponent("source_pieces.json"),
            vocabURL: dir.appendingPathComponent("vocab.json")
        )
        let vocabData = try Data(contentsOf: dir.appendingPathComponent("vocab.json"))
        let vocab = try JSONDecoder().decode([String: Int].self, from: vocabData)
        var idToPiece: [Int: String] = [:]
        idToPiece.reserveCapacity(vocab.count)
        for (piece, id) in vocab { idToPiece[id] = piece }

        let threads = Int32(max(1, min(ProcessInfo.processInfo.activeProcessorCount / 2, 4)))
        let encoder = try TranslationOnnxSession(
            modelPath: dir.appendingPathComponent("encoder.onnx").path,
            intraOpThreads: threads, disableGraphOptimization: false
        )
        // See TranslationOnnxSession's doc comment on `disableGraphOptimization`.
        let decoder = try TranslationOnnxSession(
            modelPath: dir.appendingPathComponent("decoder_merged.onnx").path,
            intraOpThreads: threads, disableGraphOptimization: true
        )
        let model = LoadedModel(pair: pair, tokenizer: tokenizer, idToPiece: idToPiece, encoder: encoder, decoder: decoder)
        loaded[key] = model
        return model
    }

    /// Greedy (not beam) decoding with the merged decoder's self-attention
    /// KV-cache — mirrors, step for step, a reference implementation
    /// written and verified in Python against this exact ONNX export
    /// before being ported here (encode → run encoder once → autoregressive
    /// decode loop reusing `present.*` as next step's `past_key_values.*`,
    /// stopping at `eosTokenId` or `maxNewTokens`). Greedy rather than the
    /// model's recommended `num_beams: 4` — simpler to implement correctly
    /// and enough to validate the engine-switching architecture; the
    /// output-quality caveat in this type's doc comment already covers the
    /// gap that would remain even with beam search.
    private func translateOne(_ text: String, model: LoadedModel, maxNewTokens: Int = 128) throws -> String {
        let pair = model.pair
        let prefixed = pair.targetLanguageTag.map { "\($0) \(text)" } ?? text
        var inputIds = model.tokenizer.encode(prefixed)
        inputIds.append(pair.eosTokenId)

        let encoderInputIds = int64Tensor("input_ids", shape: [1, inputIds.count], inputIds.map(Int64.init))
        let attentionMask = int64Tensor("attention_mask", shape: [1, inputIds.count], [Int64](repeating: 1, count: inputIds.count))
        let encoderOutputs = try run(model.encoder, inputs: [encoderInputIds, attentionMask], outputNames: ["last_hidden_state"])
        guard let encoderLastHiddenState = encoderOutputs["last_hidden_state"] else {
            throw OpusMTTranslationError.outputMissing("last_hidden_state")
        }
        // Re-tagged under the decoder's expected input name — the encoder
        // emits this same tensor as "last_hidden_state", but the objects
        // are matched to ORT graph inputs by `.name` at feed time, so
        // reusing it as-is under its original name would leave the
        // decoder's actual "encoder_hidden_states" input unbound.
        let encoderHiddenStates = TranslationOnnxTensor(
            name: "encoder_hidden_states", dtype: .float32,
            shape: encoderLastHiddenState.shape, data: encoderLastHiddenState.data
        )
        let encoderSeqLen = inputIds.count

        var pastDecoderKey = [[Float]](repeating: [], count: pair.numLayers)
        var pastDecoderValue = [[Float]](repeating: [], count: pair.numLayers)
        var pastEncoderKey = [[Float]](repeating: [], count: pair.numLayers)
        var pastEncoderValue = [[Float]](repeating: [], count: pair.numLayers)
        var pastDecoderLen = 0

        var generated = [pair.decoderStartTokenId]
        var useCacheBranch = false

        for _ in 0..<maxNewTokens {
            var inputs: [TranslationOnnxTensor] = [
                int64Tensor(
                    "input_ids",
                    shape: useCacheBranch ? [1, 1] : [1, generated.count],
                    (useCacheBranch ? [generated[generated.count - 1]] : generated).map(Int64.init)
                ),
                int64Tensor("encoder_attention_mask", shape: [1, encoderSeqLen], [Int64](repeating: 1, count: encoderSeqLen)),
                encoderHiddenStates,
                boolTensor("use_cache_branch", useCacheBranch),
            ]
            for i in 0..<pair.numLayers {
                inputs.append(floatTensor(
                    "past_key_values.\(i).decoder.key",
                    shape: [1, pair.numHeads, pastDecoderLen, pair.headDim], pastDecoderKey[i]
                ))
                inputs.append(floatTensor(
                    "past_key_values.\(i).decoder.value",
                    shape: [1, pair.numHeads, pastDecoderLen, pair.headDim], pastDecoderValue[i]
                ))
                let encoderPastLen = useCacheBranch ? encoderSeqLen : 0
                inputs.append(floatTensor(
                    "past_key_values.\(i).encoder.key",
                    shape: [1, pair.numHeads, encoderPastLen, pair.headDim], pastEncoderKey[i]
                ))
                inputs.append(floatTensor(
                    "past_key_values.\(i).encoder.value",
                    shape: [1, pair.numHeads, encoderPastLen, pair.headDim], pastEncoderValue[i]
                ))
            }

            var outputNames = ["logits"]
            for i in 0..<pair.numLayers {
                outputNames.append("present.\(i).decoder.key")
                outputNames.append("present.\(i).decoder.value")
                outputNames.append("present.\(i).encoder.key")
                outputNames.append("present.\(i).encoder.value")
            }
            let outputs = try run(model.decoder, inputs: inputs, outputNames: outputNames)
            guard let logits = outputs["logits"] else { throw OpusMTTranslationError.outputMissing("logits") }

            let vocabSize = logits.shape.last!.intValue
            let logitValues = floats(logits)
            let lastStepStart = (logitValues.count - vocabSize)
            let nextId = argmax(logitValues, from: lastStepStart, count: vocabSize)
            generated.append(nextId)
            if nextId == pair.eosTokenId { break }

            for i in 0..<pair.numLayers {
                pastDecoderKey[i] = try floatsOrThrow(outputs, "present.\(i).decoder.key")
                pastDecoderValue[i] = try floatsOrThrow(outputs, "present.\(i).decoder.value")
                if !useCacheBranch {
                    pastEncoderKey[i] = try floatsOrThrow(outputs, "present.\(i).encoder.key")
                    pastEncoderValue[i] = try floatsOrThrow(outputs, "present.\(i).encoder.value")
                }
            }
            pastDecoderLen += 1
            useCacheBranch = true
        }

        let outputIds = generated.dropFirst().filter { $0 != pair.eosTokenId }
        let pieces = outputIds.map { model.idToPiece[$0] ?? "<unk>" }
        return Self.sanitizeOutput(MarianDetokenizer.decode(pieces))
    }

    /// Strips training-corpus artifacts this specific OPUS-MT/Tatoeba
    /// model occasionally emits — confirmed by real testing, most often on
    /// inputs unlike normal prose (leftover HTML-tag fragments, book
    /// front-matter, very short strings): Moses-tokenization compound-word
    /// joiners (`@-@`/`@.@`/`@,@`, standing in for a plain "-"/"."/","),
    /// stray isolated "@" placeholders (both are real pieces in this
    /// model's vocab — see `vocab.json` — not a tokenizer bug), and "♪",
    /// which this model has been observed emitting as decoding-degenerate
    /// noise on short/odd inputs (e.g. chapter titles) rather than any
    /// real musical content — this app never asks it to translate lyrics.
    private static func sanitizeOutput(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\\s*@-@\\s*", with: "-", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*@\\.@\\s*", with: ".", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*@,@\\s*", with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?:^|\\s)@(?=\\s|$)", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "♪", with: "")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - ONNX tensor plumbing

    private func run(_ session: TranslationOnnxSession, inputs: [TranslationOnnxTensor], outputNames: [String]) throws -> [String: TranslationOnnxTensor] {
        let outputs = try session.run(withInputs: inputs, outputNames: outputNames)
        var dict: [String: TranslationOnnxTensor] = [:]
        for t in outputs { dict[t.name] = t }
        return dict
    }

    private func floats(_ tensor: TranslationOnnxTensor) -> [Float] {
        tensor.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func floatsOrThrow(_ dict: [String: TranslationOnnxTensor], _ name: String) throws -> [Float] {
        guard let t = dict[name] else { throw OpusMTTranslationError.outputMissing(name) }
        return floats(t)
    }

    private func argmax(_ values: [Float], from start: Int, count: Int) -> Int {
        var bestIndex = 0
        var bestValue = -Float.infinity
        for i in 0..<count where values[start + i] > bestValue {
            bestValue = values[start + i]
            bestIndex = i
        }
        return bestIndex
    }

    private func floatTensor(_ name: String, shape: [Int], _ values: [Float]) -> TranslationOnnxTensor {
        TranslationOnnxTensor(
            name: name, dtype: .float32, shape: shape.map { NSNumber(value: $0) },
            data: values.withUnsafeBufferPointer { Data(buffer: $0) }
        )
    }

    private func int64Tensor(_ name: String, shape: [Int], _ values: [Int64]) -> TranslationOnnxTensor {
        TranslationOnnxTensor(
            name: name, dtype: .int64, shape: shape.map { NSNumber(value: $0) },
            data: values.withUnsafeBufferPointer { Data(buffer: $0) }
        )
    }

    private func boolTensor(_ name: String, _ value: Bool) -> TranslationOnnxTensor {
        TranslationOnnxTensor(
            name: name, dtype: .bool, shape: [1],
            data: Data([value ? 1 : 0])
        )
    }
}
