import Foundation
import Core
#if canImport(SherpaOnnx)
import SherpaOnnx
#elseif canImport(SherpaOnnxShared)
import SherpaOnnxShared
#endif

enum PiperOfflineError: Error {
    case modelFilesMissing
    case wavWriteFailed
}

/// On-device Piper TTS via sherpa-onnx — no network needed. Native
/// equivalent of site_assets/piper-offline.js's "Piper (offline)" voice:
/// same vi_VN-vais1000-medium model + espeak-ng phonemizer, just native
/// ONNX Runtime instead of ONNX Runtime Web + a WASM phonemizer. Model,
/// tokens.txt (derived from the model's phoneme_id_map — see
/// k2-fsa/sherpa-onnx's scripts/piper/add_meta_data.py) and espeak-ng-data
/// are bundled directly in the app (Resources/PiperOffline/), not
/// downloaded on demand like the web version's OPFS cache — this app has
/// no equivalent "only if the user opts in" download flow yet.
actor PiperOfflineTTSService {
    static let shared = PiperOfflineTTSService()

    private var tts: SherpaOnnxOfflineTtsWrapper?
    private var transliterator: PiperEnglishTransliterator?

    private init() {}

    func synthesize(text: String, speed: Double) throws -> Data {
        let engine = try loadedEngine()
        let audio = engine.generate(text: try spokenText(for: text), sid: 0, speed: Float(speed))
        return try Self.wavData(from: audio)
    }

    /// `text` with English words rewritten as Vietnamese syllables — what
    /// Piper actually reads (see PiperEnglishTransliterator).
    func spokenText(for text: String) throws -> String {
        _ = try loadedEngine()
        return loadedTransliterator().transliterate(text)
    }

    /// Built after `loadedEngine()`: the engine's construction is what
    /// calls `espeak_Initialize`, which `englishIPA` relies on.
    private func loadedTransliterator() -> PiperEnglishTransliterator {
        if let transliterator { return transliterator }
        let built = PiperEnglishTransliterator(
            dictionary: PiperEnglishTransliterator.loadBundledDictionary(),
            phonemize: Self.englishIPA
        )
        transliterator = built
        return built
    }

    /// English IPA for each word from the espeak-ng that sherpa-onnx links
    /// statically (en_dict already ships in the bundled espeak-ng-data).
    /// Switching espeak's global voice to "en" is safe here: this runs
    /// inside the actor, so never concurrently with `generate`, and
    /// piper-phonemize sets the voice back to `vi` on every phonemize call.
    private static func englishIPA(_ words: [String]) -> [String] {
        guard espeak_SetVoiceByName("en") == 0 else { return words.map { _ in "" } }
        let ipaMode: Int32 = 0x02 | (Int32(UInt8(ascii: "_")) << 8)  // IPA, "_" between phonemes
        let utf8Text: Int32 = 1  // espeakCHARS_UTF8
        return words.map { word in
            word.withCString { cString in
                var cursor: UnsafeRawPointer? = UnsafeRawPointer(cString)
                var ipa = ""
                // One call per clause; espeak advances `cursor` and nils it at the end.
                while cursor != nil, let clause = espeak_TextToPhonemes(&cursor, utf8Text, ipaMode) {
                    ipa += String(cString: clause) + " "
                }
                return ipa
            }
        }
    }

    /// Model construction (parsing the ~61MB onnx graph) is a one-time
    /// cost of a couple seconds — kept alive for the lifetime of the app
    /// instead of reloading per sentence like the web version, which
    /// deliberately recycles its WASM worker every few calls to work
    /// around browser memory reclamation limits that don't apply here.
    private func loadedEngine() throws -> SherpaOnnxOfflineTtsWrapper {
        if let tts { return tts }
        guard
            let model = Bundle.main.path(forResource: "vi_VN-vais1000-medium", ofType: "onnx"),
            let tokens = Bundle.main.path(forResource: "tokens", ofType: "txt"),
            let dataDir = Bundle.main.resourceURL?.appendingPathComponent("espeak-ng-data").path
        else {
            throw PiperOfflineError.modelFilesMissing
        }
        let vits = sherpaOnnxOfflineTtsVitsModelConfig(model: model, lexicon: "", tokens: tokens, dataDir: dataDir)
        // sherpa-onnx defaults to 1 thread. 4 ran ~3x faster in a simulator
        // benchmark with identical output; parallel engines instead would
        // race on espeak-ng's global state (garbled phonemes). On the Mac
        // (M4 Pro) 8 was ~1.4x faster than 4; past 8 it got slower again.
        #if os(macOS)
        let numThreads = 8
        #else
        let numThreads = 4
        #endif
        let modelConfig = sherpaOnnxOfflineTtsModelConfig(vits: vits, numThreads: numThreads)
        var config = sherpaOnnxOfflineTtsConfig(model: modelConfig)
        let engine = SherpaOnnxOfflineTtsWrapper(config: &config)
        tts = engine
        return engine
    }

    /// Routes through sherpa-onnx's own WAV writer (SherpaOnnxWriteWave,
    /// via a temp file) instead of hand-rolling PCM-to-WAV encoding —
    /// reuses code already known to match what AVAudioPlayer(data:)
    /// expects, same contract APIClient.synthesize's online voices return.
    private static func wavData(from audio: SherpaOnnxGeneratedAudioWrapper) throws -> Data {
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tmpURL) } // nolog: temp file
        guard audio.save(filename: tmpURL.path) == 1 else {
            throw PiperOfflineError.wavWriteFailed
        }
        return try Data(contentsOf: tmpURL)
    }
}
