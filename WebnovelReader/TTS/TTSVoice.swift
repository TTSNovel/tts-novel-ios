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
    case piperOffline = "piper_offline"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .piperVi: return "Piper VN"
        case .googleTTS: return "Google Cloud TTS"
        case .vieNeu: return "VieNeu-TTS"
        case .piperOffline: return "Piper (offline)"
        }
    }

    var isOffline: Bool { self == .piperOffline }
}
