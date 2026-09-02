import Foundation
import Core

enum VieNeuOfflineV3Error: Error {
    case voicePresetMissing
    case voicePresetMalformed
    case noAudioGenerated
}

/// On-device VieNeu-TTS v3-Turbo — the same checkpoint/architecture the
/// ONLINE "vieneu" voice runs server-side, synthesized entirely on-device
/// via VieNeuV3OnnxEngine (4 ONNX Runtime sessions, no server round trip).
/// Same shape of entry point as VieNeuOfflineV2TTSService/
/// PiperOfflineTTSService: `synthesize(text:speed:voice:) throws -> Data`.
///
/// Pipeline: text -> VieNeuV3TextChunker (<=256-char chunks + inter-chunk
/// gap type) -> sea-g2p phonemize each chunk (shared with V2 — see
/// SeaG2PBridge) -> VieNeuV3OnnxEngine.synthesize (BPE tokenize -> backbone
/// prefill/decode -> acoustic decoder -> MOSS codec) -> 48kHz PCM per chunk,
/// joined with gap-appropriate silence -> WAV `Data`.
actor VieNeuOfflineV3TTSService {
    static let shared = VieNeuOfflineV3TTSService()

    private static let sampleRate = 48_000

    private var voiceCache: [VieNeuOfflineV3Voice: (speakerEmb: [Float], refCodes: [[Int]])] = [:]

    private init() {}

    func synthesize(text: String, speed: Double, voice: VieNeuOfflineV3Voice) async throws -> Data {
        let (speakerEmb, refCodes) = try loadedVoice(voice)
        let (chunks, gaps) = try await VieNeuV3TextChunker.chunksWithGaps(text)
        guard !chunks.isEmpty else { throw VieNeuOfflineV3Error.noAudioGenerated }

        var pcmChunks: [[Float]] = []
        pcmChunks.reserveCapacity(chunks.count)
        for chunk in chunks {
            let phonemes = try await SeaG2P.shared.phonemize(chunk)
            let pcm = try await VieNeuV3OnnxEngine.shared.synthesize(
                phonemes: phonemes, speakerEmb: speakerEmb, refCodes: refCodes
            )
            pcmChunks.append(pcm)
        }

        var joined = pcmChunks[0]
        for i in 1..<pcmChunks.count {
            let silenceSeconds = VieNeuV3TextChunker.silenceSeconds(forGap: gaps[i - 1])
            let silenceSamples = Int(Double(Self.sampleRate) * silenceSeconds)
            if silenceSamples > 0 {
                joined.append(contentsOf: [Float](repeating: 0, count: silenceSamples))
            }
            joined.append(contentsOf: pcmChunks[i])
        }
        guard !joined.isEmpty else { throw VieNeuOfflineV3Error.noAudioGenerated }

        if speed != 1.0, speed > 0 {
            joined = OfflineWavEncoding.resample(joined, rateFactor: speed)
        }
        return OfflineWavEncoding.wavData(from: joined, sampleRate: Self.sampleRate)
    }

    private func loadedVoice(_ voice: VieNeuOfflineV3Voice) throws -> (speakerEmb: [Float], refCodes: [[Int]]) {
        if let cached = voiceCache[voice] { return cached }
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("VieNeuOfflineV3") else {
            throw VieNeuOfflineV3Error.voicePresetMissing
        }
        let path = dir.appendingPathComponent("\(voice.rawValue).json")
        guard let data = FileManager.default.contents(atPath: path.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embRaw = json["speaker_emb"] as? [Double],
              let codesRaw = json["ref_codes"] as? [[Int]]
        else { throw VieNeuOfflineV3Error.voicePresetMalformed }

        let result = (speakerEmb: embRaw.map { Float($0) }, refCodes: codesRaw)
        voiceCache[voice] = result
        return result
    }
}
