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

    private init() {}

    func synthesize(text: String, speed: Double) throws -> Data {
        let engine = try loadedEngine()
        let audio = engine.generate(text: text, sid: 0, speed: Float(speed))
        return try Self.wavData(from: audio)
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
        let modelConfig = sherpaOnnxOfflineTtsModelConfig(vits: vits)
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
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        guard audio.save(filename: tmpURL.path) == 1 else {
            throw PiperOfflineError.wavWriteFailed
        }
        return try Data(contentsOf: tmpURL)
    }
}
