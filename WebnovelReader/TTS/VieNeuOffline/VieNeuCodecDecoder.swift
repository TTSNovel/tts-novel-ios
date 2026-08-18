import Foundation

enum VieNeuCodecError: Error {
    case modelMissing
    case voiceEmbeddingMissing
    case decodeFailed
}

/// Decodes VieNeu-Codec audio-code integers into a 24kHz PCM waveform via
/// ONNX Runtime (through the VieNeuCodecONNX Objective-C++ wrapper — ORT's
/// C API doesn't bridge cleanly into Swift directly) — one stateless call,
/// the same shape of integration `PiperOfflineTTSService` already does for
/// Piper's ONNX graph. Mirrors `BaseTurboVieNeuTTS._decode` (vieneu/
/// turbo.py): feed `content_ids` (the codes) + `voice_embedding` (a fixed
/// 128-float vector for the selected preset voice, see VieNeuOfflineVoice)
/// into `vieneu_decoder_int8.onnx`.
actor VieNeuCodecDecoder {
    static let shared = VieNeuCodecDecoder()

    static let sampleRate = 24_000

    private var runner: VieNeuCodecONNX?
    /// Keyed by preset — small (128 floats each), cheap to keep all
    /// previously-used ones around rather than re-parsing the JSON every
    /// time the user switches between voices mid-session.
    private var voiceEmbeddings: [VieNeuOfflineVoice: [NSNumber]] = [:]

    private init() {}

    func decode(codes: [Int32], voice: VieNeuOfflineVoice) throws -> [Float] {
        guard !codes.isEmpty else { return [] }
        let runner = try loadedRunner()
        let voiceEmbedding = try loadedVoiceEmbedding(voice)

        let contentIds = codes.map { NSNumber(value: $0) }
        let result = try runner.decode(withContentIds: contentIds, voiceEmbedding: voiceEmbedding)
        return result.map { $0.floatValue }
    }

    private func loadedRunner() throws -> VieNeuCodecONNX {
        if let runner { return runner }
        guard let path = Bundle.main.path(forResource: "vieneu_decoder_int8", ofType: "onnx") else {
            throw VieNeuCodecError.modelMissing
        }
        let created = try VieNeuCodecONNX(modelPath: path)
        runner = created
        return created
    }

    private func loadedVoiceEmbedding(_ voice: VieNeuOfflineVoice) throws -> [NSNumber] {
        if let cached = voiceEmbeddings[voice] { return cached }
        guard let path = Bundle.main.path(forResource: voice.rawValue, ofType: "json"),
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let codes = json["codes"] as? [Double]
        else {
            throw VieNeuCodecError.voiceEmbeddingMissing
        }
        let embedding = codes.map { NSNumber(value: $0) }
        voiceEmbeddings[voice] = embedding
        return embedding
    }
}
