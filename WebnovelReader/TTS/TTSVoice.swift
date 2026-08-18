import Foundation

// piperVi/googleTTS/vieNeu match the <select data-role="model"> option
// values in reader.js (site_assets/reader.js:779-784) — those strings go
// straight into the JSON body /api/tts forwards to the TTS backend, so
// they have to match exactly. piperOffline is the odd one out: it mirrors
// reader.js's on-device WASM path (piper-offline.js) instead, synthesized
// locally via PiperOfflineTTSService rather than /api/tts — its rawValue
// still matches reader.js's "piper_offline" for consistency, even though
// nothing ever sends it over the network.
enum TTSVoice: String, CaseIterable, Identifiable, Codable {
    case piperVi = "piper_vi"
    case googleTTS = "google_tts"
    case vieNeu = "vieneu"
    // gwen-tts (Qwen3-TTS-0.6B finetune), GPU-backed voice cloning —
    // separate Cloud Run service (tts-gpu, see tts-pipeline-infra), routed
    // there by the server proxy same as reader.js. Much slower than the
    // other server-side voices (measured 10-90s per sentence, autoregressive
    // decode with no fast path) — see the per-request timeout override in
    // APIClient.synthesize.
    case gwenTTS = "gwen_tts"
    case piperOffline = "piper_offline"
    // Local-only, like piperOffline — never sent to /api/tts. Runs VieNeu's
    // legacy v2-Turbo checkpoint (llama.cpp GGUF backbone + VieNeu-Codec ONNX
    // decode) entirely on-device via VieNeuOfflineV2TTSService. A different
    // checkpoint from the online "vieneu" voice (server runs v3-Turbo), so
    // the voice/quality differs — same VI/EN code-switching capability
    // (shared sea-g2p phonemizer) either way. Kept the rawValue "vieneu_
    // offline" (pre-dating the "V2" rename) so existing installs' persisted
    // UserDefaults selection isn't silently reset.
    case vieNeuOfflineV2 = "vieneu_offline"
    // Local-only, like vieNeuOfflineV2 — never sent to /api/tts. Runs the
    // actual v3-Turbo checkpoint the online "vieneu" voice uses (pure ONNX:
    // prefill/acoustic/decode-step backbone + MOSS codec, no llama.cpp)
    // entirely on-device via VieNeuOfflineV3TTSService — see that package's
    // doc comments for the pipeline. Architecturally unrelated to v2 beyond
    // sharing the sea-g2p phonemizer, hence the separate package.
    case vieNeuOfflineV3 = "vieneu_offline_v3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .piperVi: return "Piper VN"
        case .googleTTS: return "Google Cloud TTS"
        case .vieNeu: return "VieNeu-TTS"
        case .gwenTTS: return "Gwen-TTS (voice clone)"
        case .piperOffline: return "Piper (offline)"
        case .vieNeuOfflineV2: return "VieNeu-TTS v2 (offline)"
        case .vieNeuOfflineV3: return "VieNeu-TTS v3 (offline)"
        }
    }

    var isOffline: Bool { self == .piperOffline || self == .vieNeuOfflineV2 || self == .vieNeuOfflineV3 }
}
