import Foundation

// Matches the <select data-role="model"> option values in reader.js
// (site_assets/reader.js:779-784) — these strings go straight into the
// JSON body /api/tts forwards to the TTS backend, so they have to match
// exactly. piper_offline is deliberately excluded: that's reader.js's
// on-device WASM path (piper-offline.js), not something /api/tts serves.
enum TTSVoice: String, CaseIterable, Identifiable, Codable {
    case piperVi = "piper_vi"
    case googleTTS = "google_tts"
    case vieNeu = "vieneu"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .piperVi: return "Piper VN"
        case .googleTTS: return "Google Cloud TTS"
        case .vieNeu: return "VieNeu-TTS"
        }
    }
}
