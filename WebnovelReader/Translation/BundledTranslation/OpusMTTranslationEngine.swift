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
    struct LanguagePair {
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

    /// `@unchecked Sendable`: every stored property is only ever read after
    /// `loadModelIfNeeded` builds it (never mutated), and it's shared as-is
    /// across the concurrent `translateOne` calls `translate(texts:)`
    /// fans out — safe for `TranslationOnnxSession`/`TranslationOnnxTensor`
    /// specifically because `-runWithInputs:outputNames:error:` (see
    /// TranslationOnnxSession.mm) allocates all its working state
    /// (`Ort::MemoryInfo`, input/output vectors, `Ort::RunOptions`) locally
    /// per call and never touches shared mutable session state beyond the
    /// `Ort::Session::Run` call itself, which onnxruntime documents as
    /// safe to invoke concurrently from multiple threads on one session.
    struct LoadedModel: @unchecked Sendable {
        let pair: LanguagePair
        let tokenizer: UnigramTokenizer
        let idToPiece: [Int: String]
        let encoder: TranslationOnnxSession
        let decoder: TranslationOnnxSession
    }

    private var loaded: [String: LoadedModel] = [:]

    nonisolated func canTranslate(from source: Locale.Language, to target: Locale.Language) -> Bool {
        guard let sourceCode = source.languageCode?.identifier, let targetCode = target.languageCode?.identifier else { return false }
        return Self.supportedPairs.contains { $0.sourceLanguageCode == sourceCode && $0.targetLanguageCode == targetCode }
    }

    /// Sentences run concurrently, up to `maxConcurrentTranslations` in
    /// flight at once, instead of strictly one at a time — measured on a
    /// full chapter (see `TranslationPerformanceTests`), a sequential loop
    /// left the rest of the device's cores idle for the entire decode loop
    /// of every sentence. `translateOne` and everything it calls are
    /// `nonisolated` specifically so child tasks actually run concurrently
    /// on Swift's cooperative thread pool rather than hopping back onto
    /// this actor's single serial executor one at a time — see
    /// `loadModelIfNeeded`'s `intraOpThreads: 1` doc comment for the other
    /// half of this trade-off (parallelism moved from *within* one ONNX
    /// Runtime call to *across* sentences).
    ///
    /// Bounded rather than "spawn all N at once": each in-flight sentence
    /// holds a growing KV-cache (up to `maxNewTokens` steps' worth of
    /// float arrays per layer — see `translateOne`), so capping concurrency
    /// also caps peak memory, not just thread contention.
    ///
    /// `nonisolated`, returning the stream synchronously and doing the
    /// actual work inside a detached `Task` — lets `translate` itself
    /// satisfy `TranslationEngine`'s non-async requirement while still
    /// hopping onto this actor (via `await loadModelIfNeeded`) for the one
    /// piece of actual actor-isolated state (`loaded`). Yields each
    /// sentence to the caller (`ReaderPlaybackController.performPendingTranslation`)
    /// the moment it's done, in *completion* order — a later sentence can
    /// legitimately land before an earlier one under concurrent
    /// translation, so the caller tags results by index rather than
    /// assuming stream order matches input order.
    nonisolated func translate(texts: [String], source: Locale.Language, target: Locale.Language) -> AsyncThrowingStream<(index: Int, text: String), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let sourceCode = source.languageCode?.identifier, let targetCode = target.languageCode?.identifier,
                          let pair = Self.supportedPairs.first(where: { $0.sourceLanguageCode == sourceCode && $0.targetLanguageCode == targetCode })
                    else { throw OpusMTTranslationError.unsupportedLanguage }
                    let model = try await self.loadModelIfNeeded(pair: pair)
                    try await withThrowingTaskGroup(of: (Int, String).self) { group in
                        var nextIndex = 0
                        func scheduleNext() {
                            guard nextIndex < texts.count else { return }
                            let index = nextIndex
                            let text = texts[index]
                            nextIndex += 1
                            group.addTask { (index, try Self.translateOne(text, model: model)) }
                        }
                        let initialBatch = min(Self.maxConcurrentTranslations, texts.count)
                        for _ in 0..<initialBatch { scheduleNext() }
                        while let (index, translated) = try await group.next() {
                            continuation.yield((index, translated))
                            scheduleNext()
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Intra-op threads per ONNX Runtime session — shared by both
    /// `maxConcurrentTranslations` below and `loadModelIfNeeded`'s session
    /// creation so the two stay consistent: each concurrently in-flight
    /// sentence's `Run()` call gets this many worker threads, so total
    /// threads in flight ≈ `maxConcurrentTranslations * intraOpThreads`,
    /// which is what's kept near the core count.
    ///
    /// 2, not 1 — and not simply "whichever gives more concurrent
    /// sentences": measured (see TranslationPerformanceTests) on the native
    /// KV-cache decode path (`TranslationOnnxSession`'s
    /// `AutoregressiveDecoding` category), 1 thread with the resulting
    /// higher `maxConcurrentTranslations` was slower for a *full chapter*
    /// batch too, not just for an isolated single sentence — 36.0s vs 2
    /// threads' 22.7s on the same test chapter, despite nearly 2x fewer
    /// sentences running side by side. Best guess: many threads (~13 on the
    /// test host) hammering `Run()` concurrently on one shared
    /// `Ort::Session` hits allocator/session-internal contention that
    /// outweighs the extra parallelism, especially now that each call is
    /// cheap enough (see `stepDecoderState:...`) for that contention to
    /// dominate. Not fully root-caused — if retuning this, re-measure
    /// rather than assuming either direction.
    private static let decoderIntraOpThreads: Int32 = 2

    /// Leaves some headroom for the UI/audio/system rather than saturating
    /// every core with translation work — this runs while the reader is
    /// otherwise idle (waiting on a translation), not competing with
    /// playback, but a fully pegged device still feels worse to use. Scaled
    /// down by `decoderIntraOpThreads` so total threads in flight
    /// (`maxConcurrentTranslations * decoderIntraOpThreads`) stays close to
    /// the core count instead of multiplying past it.
    private static var maxConcurrentTranslations: Int {
        max(1, (ProcessInfo.processInfo.activeProcessorCount - 1) / Int(decoderIntraOpThreads))
    }

    private func loadModelIfNeeded(pair: LanguagePair) throws -> LoadedModel {
        let key = "\(pair.sourceLanguageCode)-\(pair.targetLanguageCode)"
        if let existing = loaded[key] { return existing }
        let model = try Self.buildModel(pair: pair, useCoreML: false)
        loaded[key] = model
        return model
    }

    /// Test-only entry point (see `TranslationPerformanceTests`'
    /// `testCoreMLExecutionProviderRealTranslation`) — builds a real
    /// `LoadedModel` for the bundled en-vi pair with `useCoreML: true`
    /// sessions instead of the CPU-only ones `loadModelIfNeeded` always
    /// uses in production, so a real device can measure the *actual*
    /// `translateOne` decode path (not a synthetic decode-step-only check)
    /// running on onnxruntime's CoreML execution provider. Never called
    /// from production code, and never touches `loaded` (no caching,
    /// doesn't interfere with the real engine's state).
    static func makeModelForTesting(useCoreML: Bool) throws -> LoadedModel {
        guard let pair = supportedPairs.first else { throw OpusMTTranslationError.unsupportedLanguage }
        return try buildModel(pair: pair, useCoreML: useCoreML)
    }

    private static func buildModel(pair: LanguagePair, useCoreML: Bool) throws -> LoadedModel {
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

        // `decoderIntraOpThreads` per session, not a full
        // `activeProcessorCount`-sized pool — `translate(texts:)` runs
        // multiple sentences concurrently (see its doc comment), each with
        // its own encoder/decoder `Run()` call, so `maxConcurrentTranslations`
        // is already sized to leave each of those calls only this many
        // threads without oversubscribing the core count.
        let encoder = try TranslationOnnxSession(
            modelPath: dir.appendingPathComponent("encoder.onnx").path,
            intraOpThreads: Self.decoderIntraOpThreads, disableGraphOptimization: false, useCoreML: useCoreML
        )
        // Stays disabled — see TranslationOnnxSession's doc comment on
        // `disableGraphOptimization`: this isn't a naive perf trade-off,
        // it's a workaround for a *confirmed, reproduced* onnxruntime QDQ
        // graph-optimizer bug on this decoder's tied embedding/output
        // weight (`TransposeDQWeightsForMatMulNBits ... Missing required
        // scale`). Tried flipping this to `false` while measuring
        // TranslationPerformanceTests: it ran 161/161 sentences without a
        // thrown ORT error and was measurably faster (~21% lower
        // steady-state s/sentence) — but "didn't throw" isn't proof the
        // documented bug is absent, only proof it didn't *crash*; a
        // corrupted dequantized weight could just as easily produce
        // silently-wrong-but-still-string-shaped output, which this
        // model's already-known "can mangle output" quality ceiling would
        // mask. Not worth that risk without a real correctness check
        // (e.g. diffing translations against a known-good reference)
        // backing it up first.
        let decoder = try TranslationOnnxSession(
            modelPath: dir.appendingPathComponent("decoder_merged.onnx").path,
            intraOpThreads: Self.decoderIntraOpThreads, disableGraphOptimization: true, useCoreML: useCoreML
        )
        return LoadedModel(pair: pair, tokenizer: tokenizer, idToPiece: idToPiece, encoder: encoder, decoder: decoder)
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
    ///
    /// `static`, not an actor-isolated instance method: touches no actor
    /// state (everything it needs comes in via `model`), specifically so
    /// `translate(texts:)` can run several of these concurrently on
    /// separate threads instead of one at a time on the actor's serial
    /// executor — see that method's doc comment.
    ///
    /// Internal, not `private`: `TranslationPerformanceTests`' CoreML EP
    /// comparison calls this directly (against a `LoadedModel` built via
    /// `makeModelForTesting(useCoreML: true)`) specifically so it measures
    /// this exact production decode path rather than a hand-rolled
    /// reimplementation in test code that could silently drift from it.
    static func translateOne(_ text: String, model: LoadedModel, maxNewTokens: Int = 128) throws -> String {
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
        // Invariant across every step — built once here instead of inside
        // the loop.
        let encoderAttentionMask = int64Tensor("encoder_attention_mask", shape: [1, encoderSeqLen], [Int64](repeating: 1, count: encoderSeqLen))

        // Everything about the growing KV-cache — both the decoder's (which
        // really does grow every step) and the encoder's (constant after
        // step 0) — now lives entirely inside `state`, natively in C++, via
        // `TranslationOnnxSession`'s `AutoregressiveDecoding` category (see
        // TranslationOnnxSession.mm's `DecoderCacheState`). Each step now
        // only crosses the Swift/Obj-C boundary with one new token in and
        // one argmax'd token id out — the old per-step
        // Swift-array-to-NSData-and-back round trip for the entire cache
        // (`pastDecoderKey`/`pastDecoderValue`/`floats`/`floatTensor`) is
        // gone; see this method's git history for that version, and
        // TranslationPerformanceTests for the measured before/after.
        let state = try model.decoder.makeDecoderState(withNumLayers: pair.numLayers, numHeads: pair.numHeads, headDim: pair.headDim)

        var generated = [pair.decoderStartTokenId]
        for _ in 0..<maxNewTokens {
            let nextId = try model.decoder.step(
                state,
                encoderHiddenStates: encoderHiddenStates,
                encoderAttentionMask: encoderAttentionMask,
                tokenId: Int64(generated[generated.count - 1])
            ).intValue
            generated.append(nextId)
            if nextId == pair.eosTokenId { break }
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
        // The model's own vocab contains "<"/">"/"</" as real pieces (see
        // vocab.json) — on out-of-distribution input (front matter,
        // errata lists) it has been observed *hallucinating* these into
        // its output even when the input side was already cleaned (see
        // TextSegmentation.cleaned's matching stray-bracket strip), so
        // this needs its own independent pass rather than relying on
        // input hygiene alone.
        s = s.replacingOccurrences(of: "[<>]+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - ONNX tensor plumbing

    private static func run(_ session: TranslationOnnxSession, inputs: [TranslationOnnxTensor], outputNames: [String]) throws -> [String: TranslationOnnxTensor] {
        let outputs = try session.run(withInputs: inputs, outputNames: outputNames)
        var dict: [String: TranslationOnnxTensor] = [:]
        for t in outputs { dict[t.name] = t }
        return dict
    }

    private static func floats(_ tensor: TranslationOnnxTensor) -> [Float] {
        tensor.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private static func floatsOrThrow(_ dict: [String: TranslationOnnxTensor], _ name: String) throws -> [Float] {
        guard let t = dict[name] else { throw OpusMTTranslationError.outputMissing(name) }
        return floats(t)
    }

    private static func argmax(_ values: [Float], from start: Int, count: Int) -> Int {
        var bestIndex = 0
        var bestValue = -Float.infinity
        for i in 0..<count where values[start + i] > bestValue {
            bestValue = values[start + i]
            bestIndex = i
        }
        return bestIndex
    }

    private static func floatTensor(_ name: String, shape: [Int], _ values: [Float]) -> TranslationOnnxTensor {
        TranslationOnnxTensor(
            name: name, dtype: .float32, shape: shape.map { NSNumber(value: $0) },
            data: values.withUnsafeBufferPointer { Data(buffer: $0) }
        )
    }

    private static func int64Tensor(_ name: String, shape: [Int], _ values: [Int64]) -> TranslationOnnxTensor {
        TranslationOnnxTensor(
            name: name, dtype: .int64, shape: shape.map { NSNumber(value: $0) },
            data: values.withUnsafeBufferPointer { Data(buffer: $0) }
        )
    }

    private static func boolTensor(_ name: String, _ value: Bool) -> TranslationOnnxTensor {
        TranslationOnnxTensor(
            name: name, dtype: .bool, shape: [1],
            data: Data([value ? 1 : 0])
        )
    }
}
