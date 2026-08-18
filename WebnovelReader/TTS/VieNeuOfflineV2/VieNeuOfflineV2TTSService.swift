import Foundation

enum VieNeuOfflineV2Error: Error {
    case noAudioGenerated
}

/// On-device VieNeu-TTS via llama.cpp (GGUF backbone) + ONNX Runtime
/// (VieNeu-Codec decode) — no server round trip. Same shape of entry point
/// as PiperOfflineTTSService: `synthesize(text:speed:) throws -> Data`.
///
/// Pipeline (mirrors `vieneu.turbo.TurboVieNeuTTS.infer`, legacy v2-Turbo
/// checkpoint — see TTSVoice.vieNeuOffline's doc comment for why this is a
/// different checkpoint from the online "vieneu" voice):
///   text -> sea-g2p normalize+phonemize -> llama.cpp backbone generates
///   `<|speech_N|>` tokens -> VieNeu-Codec ONNX decodes tokens -> 24kHz PCM
///   -> WAV `Data`.
///
/// Speed is applied by resampling the decoded PCM (VieNeu's engine has no
/// native rate-control param either — same approach `synthesize_vieneu`
/// takes server-side, see tts-generate/main.py).
actor VieNeuOfflineV2TTSService {
    static let shared = VieNeuOfflineV2TTSService()

    private init() {}

    func synthesize(text: String, speed: Double, voice: VieNeuOfflineV2Voice) async throws -> Data {
        let phonemes = try await SeaG2P.shared.phonemize(text)
        let codes = try await VieNeuV2LlamaBackbone.shared.generateSpeechCodes(phonemes: phonemes)
        var pcm = try await VieNeuV2CodecDecoder.shared.decode(codes: codes, voice: voice)
        guard !pcm.isEmpty else { throw VieNeuOfflineV2Error.noAudioGenerated }

        if speed != 1.0, speed > 0 {
            pcm = OfflineWavEncoding.resample(pcm, rateFactor: speed)
        }

        return OfflineWavEncoding.wavData(from: pcm, sampleRate: VieNeuV2CodecDecoder.sampleRate)
    }
}
