import XCTest
@testable import WebnovelReader

/// Measures real wall-clock translate time for `OpusMTTranslationEngine`
/// (the always-offline OPUS-MT fallback, not `AppleTranslationEngine`) on a
/// full, real chapter-length text — Homer's *Odyssey*, Book II (Samuel
/// Butler's public-domain prose translation, ~4,200 words / ~22k chars,
/// bundled as `Resources/odyssey_book2.txt`), run through the exact same
/// `TextSegmentation` pipeline `ReaderPlaybackController.sentenceSequence`
/// uses in production, then translated sentence-by-sentence exactly as
/// `performPendingTranslation` calls the engine.
///
/// Bounded to `perSentenceBudget` wall-clock seconds rather than a fixed
/// sentence count: the unoptimized decoder graph (see
/// `OpusMTTranslationEngine.swift`'s `disableGraphOptimization: true`) can
/// need multiple seconds per sentence, so translating the whole ~160-sentence
/// chapter could run well past what's practical for a single test/CI run.
/// Stopping by elapsed time keeps this test's runtime predictable while
/// still yielding a seconds/sentence rate — the metric that's actually
/// comparable before/after an optimization change, independent of how many
/// sentences either run manages to finish in the budget.
final class TranslationPerformanceTests: XCTestCase {
    private let perSentenceBudget: TimeInterval = 240

    /// Single `translate(texts:)` call over the *whole* chapter's sentences
    /// at once — exactly how `ReaderPlaybackController.performPendingTranslation`
    /// actually calls the engine in production (see its
    /// `engine.translate(texts: textsToTranslate, ...)` call). This is the
    /// one that exercises `OpusMTTranslationEngine`'s internal sentence-level
    /// concurrency (`maxConcurrentTranslations` in-flight tasks) — unlike
    /// `testOpusMTTranslateOdysseyBookTwo` below, which calls `translate`
    /// once *per sentence* and so only ever gives it one item to parallelize
    /// per call, silently defeating that concurrency. Keep both: this one is
    /// the real end-to-end number; the per-sentence one isolates steady-state
    /// per-decode-step cost, useful for comparing changes that affect a
    /// single `translateOne` call rather than the fan-out around it.
    func testOpusMTTranslateOdysseyBookTwoBatched() async throws {
        let chapterText = try loadOdysseyBookTwo()
        let sentences = TextSegmentation.sentences(from: TextSegmentation.cleaned(chapterText))
        XCTAssertGreaterThan(sentences.count, 1, "expected the chapter to split into multiple sentences")
        print("[perf-batched] Odyssey Book II: \(chapterText.count) chars -> \(sentences.count) sentences after TextSegmentation")

        let engine = OpusMTTranslationEngine.shared
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "vi")
        XCTAssertTrue(engine.canTranslate(from: source, to: target), "OPUS-MT engine should support en->vi")

        let start = Date()
        let translated = try await translateAll(engine, texts: sentences, source: source, target: target)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(translated.count, sentences.count)
        print("""
        [perf-batched] ==== SUMMARY (OPUS-MT, batched, whole chapter in one translate() call) ====
        [perf-batched] sentences: \(sentences.count)
        [perf-batched] TOTAL (incl. model load): \(String(format: "%.2f", elapsed))s
        [perf-batched] avg: \(String(format: "%.3f", elapsed / Double(sentences.count)))s/sentence
        [perf-batched] ==================================================================
        """)
    }

    /// Isolates three separate numbers the batched/steady-state tests above
    /// conflate together: (1) pure model load (tokenizer parse + building
    /// both ONNX sessions) with zero sentences translated — `translate(texts: [])`
    /// still calls `loadModelIfNeeded` but the task group has nothing to
    /// schedule, so it returns right after load; (2) a single sentence's
    /// translate latency once the model is already warm, averaged over
    /// several different sentences to smooth out per-sentence variance
    /// (decode step count varies with output length); (3) whether coming
    /// back after a gap re-pays the load cost — `OpusMTTranslationEngine`
    /// caches `LoadedModel` in its `loaded` dict for the actor's lifetime
    /// (`OpusMTTranslationEngine.shared` is a `static let`, so that's the
    /// whole app process), so nothing *should* force a reload short of the
    /// app being killed; confirmed here by sleeping between calls rather
    /// than just asserting it from reading the code.
    func testOpusMTLoadAndWarmLatency() async throws {
        let chapterText = try loadOdysseyBookTwo()
        let sentences = TextSegmentation.sentences(from: TextSegmentation.cleaned(chapterText))
        XCTAssertGreaterThan(sentences.count, 20, "need several distinct sentences to sample from")

        let engine = OpusMTTranslationEngine.shared
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "vi")

        // (1) Pure load: zero sentences to translate, so the only work
        // `translate` does is `loadModelIfNeeded` (tokenizer + 2 ONNX
        // sessions) before the task group finds nothing to schedule.
        let loadStart = Date()
        let empty = try await translateAll(engine, texts: [], source: source, target: target)
        let loadOnly = Date().timeIntervalSince(loadStart)
        XCTAssertTrue(empty.isEmpty)
        print("[perf-warm] (1) pure model load (0 sentences): \(String(format: "%.3f", loadOnly))s")

        // (2) Single-sentence latency now that the model is warm — sampled
        // across several distinct sentences (not the same one repeated) so
        // this isn't just measuring one sentence's particular output length.
        var warmLatencies: [TimeInterval] = []
        for sentence in sentences.prefix(8) {
            let start = Date()
            _ = try await translateAll(engine, texts: [sentence], source: source, target: target)
            warmLatencies.append(Date().timeIntervalSince(start))
        }
        let avgWarm = warmLatencies.reduce(0, +) / Double(warmLatencies.count)
        print("[perf-warm] (2) warm single-sentence latency, 8 samples: \(warmLatencies.map { String(format: "%.3f", $0) }.joined(separator: ", "))s")
        print("[perf-warm] (2) warm single-sentence avg: \(String(format: "%.3f", avgWarm))s")

        // (3) "Come back later" — sleep, then translate one more sentence.
        // If this were anywhere near `loadOnly`, that would mean the model
        // got reloaded; it should instead land in the same ballpark as (2).
        try await Task.sleep(nanoseconds: 5_000_000_000)
        let laterStart = Date()
        _ = try await translateAll(engine, texts: [sentences[10]], source: source, target: target)
        let laterLatency = Date().timeIntervalSince(laterStart)
        print("[perf-warm] (3) single-sentence latency after a 5s gap: \(String(format: "%.3f", laterLatency))s")

        print("""
        [perf-warm] ==== SUMMARY ====
        [perf-warm] model load (tokenizer + 2 ONNX sessions): \(String(format: "%.3f", loadOnly))s
        [perf-warm] warm single-sentence avg (n=8):            \(String(format: "%.3f", avgWarm))s
        [perf-warm] single-sentence after 5s idle gap:          \(String(format: "%.3f", laterLatency))s
        [perf-warm] ===================
        """)

        // NOT `laterLatency < loadOnly` — with `intraOpThreads: 1` (see
        // `loadModelIfNeeded`), a single *isolated* sentence's own decode
        // loop can easily run longer than the ~0.2s load itself (see the
        // 0.2–2.0s spread in the 8-sample loop above), so that comparison
        // doesn't actually distinguish "reloaded" from "just a normal warm
        // call with no other sentence to overlap with." The real signature
        // of a reload would be `laterLatency` landing close to
        // `loadOnly` *plus* a full warm translate — i.e. noticeably above
        // the entire warm sample range this run already established.
        XCTAssertLessThan(
            laterLatency, (warmLatencies.max() ?? avgWarm) + loadOnly,
            "a post-gap translate landing above the warm range plus a full reload would suggest the model got reloaded"
        )
    }

    func testOpusMTTranslateOdysseyBookTwo() async throws {
        let chapterText = try loadOdysseyBookTwo()
        let sentences = TextSegmentation.sentences(from: TextSegmentation.cleaned(chapterText))
        XCTAssertGreaterThan(sentences.count, 1, "expected the chapter to split into multiple sentences")
        print("[perf] Odyssey Book II: \(chapterText.count) chars -> \(sentences.count) sentences after TextSegmentation")

        let engine = OpusMTTranslationEngine.shared
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "vi")
        XCTAssertTrue(engine.canTranslate(from: source, to: target), "OPUS-MT engine should support en->vi")

        // First call includes model load (tokenizer + two ONNX sessions) —
        // timed and reported separately from steady-state per-sentence cost
        // since the two have very different causes/fixes.
        let loadStart = Date()
        let firstTranslated = try await translateAll(engine, texts: [sentences[0]], source: source, target: target)
        let loadAndFirstSentence = Date().timeIntervalSince(loadStart)
        print("[perf] first translate() call (model load + 1 sentence): \(String(format: "%.2f", loadAndFirstSentence))s")
        print("[perf]   \"\(sentences[0].prefix(60))\" -> \"\(firstTranslated[0].prefix(60))\"")

        var completed = 0
        var totalElapsed: TimeInterval = 0
        let runStart = Date()
        for sentence in sentences.dropFirst() {
            let start = Date()
            _ = try await translateAll(engine, texts: [sentence], source: source, target: target)
            totalElapsed += Date().timeIntervalSince(start)
            completed += 1
            if completed % 10 == 0 {
                let rate = totalElapsed / Double(completed)
                print("[perf] \(completed)/\(sentences.count - 1) sentences, \(String(format: "%.2f", totalElapsed))s elapsed, \(String(format: "%.3f", rate))s/sentence avg")
            }
            if Date().timeIntervalSince(runStart) > perSentenceBudget { break }
        }

        let rate = totalElapsed / Double(max(completed, 1))
        let fullChapterEstimate = loadAndFirstSentence + rate * Double(sentences.count - 1)
        print("""
        [perf] ==== SUMMARY (OPUS-MT) ====
        [perf] sentences measured: \(completed) of \(sentences.count - 1) remaining (\(sentences.count) total incl. first)
        [perf] steady-state total: \(String(format: "%.2f", totalElapsed))s
        [perf] steady-state avg:   \(String(format: "%.3f", rate))s/sentence
        [perf] model load + 1st:   \(String(format: "%.2f", loadAndFirstSentence))s
        [perf] extrapolated full chapter (\(sentences.count) sentences): \(String(format: "%.1f", fullChapterEstimate))s
        [perf] ============================
        """)

        XCTAssertGreaterThan(completed, 0, "should have measured at least one steady-state sentence")
    }

    /// Real, apples-to-apples CPU-vs-CoreML-EP comparison — meant to be run
    /// on a *real device* (Simulator has no Apple Neural Engine and only
    /// limited/no GPU passthrough for CoreML, so its timing here doesn't
    /// mean much; see `TranslationOnnxSession`'s `useCoreML:` initializer
    /// doc comment for why this whole approach is unproven ahead of time —
    /// dynamic `past_key_values` shapes every decode step, historically a
    /// weak spot for CoreML). Both models run the exact same production
    /// `OpusMTTranslationEngine.translateOne` decode path (made `internal`,
    /// plus `makeModelForTesting(useCoreML:)`, specifically so this measures
    /// real behavior instead of a hand-rolled reimplementation that could
    /// silently drift from what `translateOne` actually does) against the
    /// same real Odyssey sentences, sequentially (not concurrently — the
    /// point here is comparing one backend's own per-step speed against the
    /// other's, not fan-out throughput, which `testOpusMTTranslateOdysseyBookTwoBatched`
    /// already covers for the CPU path).
    func testCoreMLExecutionProviderRealTranslation() throws {
        let chapterText = try loadOdysseyBookTwo()
        let sentences = TextSegmentation.sentences(from: TextSegmentation.cleaned(chapterText))
        let sampleSize = 20
        let sample = Array(sentences.prefix(sampleSize))
        print("[perf-coreml] Sampling \(sample.count) real sentences from Odyssey Book II")

        print("[perf-coreml] Building CPU-only model...")
        let cpuModel = try OpusMTTranslationEngine.makeModelForTesting(useCoreML: false)

        print("[perf-coreml] Building CoreML EP model...")
        let coreMLModel: OpusMTTranslationEngine.LoadedModel
        do {
            coreMLModel = try OpusMTTranslationEngine.makeModelForTesting(useCoreML: true)
            print("[perf-coreml] CoreML EP model built OK")
        } catch {
            print("[perf-coreml] CoreML EP model build FAILED — \(error)")
            throw error
        }

        // Correctness first: same input, both backends, greedy decode is
        // deterministic — a mismatch isn't necessarily "CoreML is broken"
        // (ANE compute can differ in float precision from CPU, occasionally
        // flipping an argmax tie) but IS worth knowing about explicitly
        // rather than silently trusting whichever backend is faster.
        let cpuFirst = try OpusMTTranslationEngine.translateOne(sample[0], model: cpuModel)
        let coreMLFirst = try OpusMTTranslationEngine.translateOne(sample[0], model: coreMLModel)
        print("[perf-coreml] correctness check — CPU:     \"\(cpuFirst)\"")
        print("[perf-coreml] correctness check — CoreML:  \"\(coreMLFirst)\"")
        print("[perf-coreml] correctness check — MATCH: \(cpuFirst == coreMLFirst)")

        func timeBackend(_ label: String, model: OpusMTTranslationEngine.LoadedModel) throws -> TimeInterval {
            var total: TimeInterval = 0
            for (i, sentence) in sample.enumerated() {
                let start = Date()
                _ = try OpusMTTranslationEngine.translateOne(sentence, model: model)
                let elapsed = Date().timeIntervalSince(start)
                total += elapsed
                print("[perf-coreml] [\(label)] sentence \(i + 1)/\(sample.count): \(String(format: "%.3f", elapsed))s")
            }
            return total
        }

        print("[perf-coreml] Timing CPU backend, \(sample.count) sentences...")
        let cpuTotal = try timeBackend("CPU", model: cpuModel)
        print("[perf-coreml] Timing CoreML EP backend, \(sample.count) sentences...")
        let coreMLTotal = try timeBackend("CoreML", model: coreMLModel)

        let cpuAvg = cpuTotal / Double(sample.count)
        let coreMLAvg = coreMLTotal / Double(sample.count)
        print("""
        [perf-coreml] ==== SUMMARY (CPU vs CoreML EP, \(sample.count) real sentences, sequential) ====
        [perf-coreml] CPU:    total \(String(format: "%.2f", cpuTotal))s, avg \(String(format: "%.3f", cpuAvg))s/sentence
        [perf-coreml] CoreML: total \(String(format: "%.2f", coreMLTotal))s, avg \(String(format: "%.3f", coreMLAvg))s/sentence
        [perf-coreml] speedup (CPU/CoreML): \(String(format: "%.2f", cpuAvg / coreMLAvg))x
        [perf-coreml] output match on sentence 1: \(cpuFirst == coreMLFirst)
        [perf-coreml] =========================================================================
        """)
    }

    /// `OpusMTTranslationEngine.translate` now streams results per sentence
    /// (see its doc comment) rather than returning `[String]` in one shot —
    /// this drains the stream back into an ordered array so the timing
    /// assertions below stay unchanged. Index order, not arrival order: the
    /// engine translates sentences concurrently, so a later index can land
    /// before an earlier one.
    private func translateAll(
        _ engine: OpusMTTranslationEngine, texts: [String], source: Locale.Language, target: Locale.Language
    ) async throws -> [String] {
        var results = [String?](repeating: nil, count: texts.count)
        for try await (index, text) in engine.translate(texts: texts, source: source, target: target) {
            results[index] = text
        }
        return results.map { $0! }
    }

    private func loadOdysseyBookTwo() throws -> String {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "odyssey_book2", withExtension: "txt") else {
            throw TestResourceError.missing("odyssey_book2.txt")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private enum TestResourceError: Error {
        case missing(String)
    }
}
