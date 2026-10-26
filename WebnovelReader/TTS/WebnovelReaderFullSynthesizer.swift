import Foundation
import Core

/// The iOS/macOS synthesizer — dispatches to the on-device Piper/VieNeu
/// engines first, falling back to `WebnovelReaderOnlineSynthesizer` (by
/// composition, not duplicated retry logic) for every voice that isn't one
/// of the offline ones, or whenever offline/logged-out. This is the
/// synthesizer `ReaderPlaybackController.shared` constructs on platforms
/// that link the offline TTS engines — never on watchOS, which uses
/// `WebnovelReaderOnlineSynthesizer` directly.
final class WebnovelReaderFullSynthesizer: TTSSynthesizing {
    private let online = WebnovelReaderOnlineSynthesizer()

    /// The TTS boundary — every synthesis (reader playback, next-chapter
    /// warm-up, audio pre-download) goes through here, so a failure is
    /// logged once with the voice, route and exact text, whoever asked.
    func synthesize(
        text: String,
        voice: TTSVoice,
        vieNeuOfflineV2Voice: VieNeuOfflineV2Voice?,
        vieNeuOfflineV3Voice: VieNeuOfflineV3Voice?,
        gwenTTSSpeaker: GwenTTSSpeaker,
        speed: Double,
        baseURL: URL,
        isConnected: Bool,
        isLoggedIn: Bool
    ) async throws -> Data {
        let started = Date()
        do {
            return try await route(
                text: text, voice: voice, vieNeuOfflineV2Voice: vieNeuOfflineV2Voice,
                vieNeuOfflineV3Voice: vieNeuOfflineV3Voice, gwenTTSSpeaker: gwenTTSSpeaker,
                speed: speed, baseURL: baseURL, isConnected: isConnected, isLoggedIn: isLoggedIn
            )
        } catch {
            Log.error(.tts, "Synthesis failed", error: error, [
                "voice": voice.rawValue,
                "route": voice.isOffline || !isConnected || !isLoggedIn ? "offline" : "online",
                "connected": "\(isConnected)", "loggedIn": "\(isLoggedIn)", "speed": "\(speed)",
                "chars": "\(text.count)", "text": String(text.prefix(500)),
                "ms": "\(Int(Date().timeIntervalSince(started) * 1000))",
            ])
            throw error
        }
    }

    private func route(
        text: String,
        voice: TTSVoice,
        vieNeuOfflineV2Voice: VieNeuOfflineV2Voice?,
        vieNeuOfflineV3Voice: VieNeuOfflineV3Voice?,
        gwenTTSSpeaker: GwenTTSSpeaker,
        speed: Double,
        baseURL: URL,
        isConnected: Bool,
        isLoggedIn: Bool
    ) async throws -> Data {
        #if os(iOS)
        // VieNeu's llama.cpp / SeaG2P xcframeworks have no macOS slice yet —
        // on Mac those voices fall through to Piper below.
        if voice == .vieNeuOfflineV2 {
            // No network round trip — runs the bundled GGUF backbone +
            // VieNeu-Codec ONNX decoder right here on-device (see
            // VieNeuOfflineV2TTSService).
            return try await VieNeuOfflineV2TTSService.shared.synthesize(
                text: text, speed: speed, voice: vieNeuOfflineV2Voice ?? .bichNgoc
            )
        } else if voice == .vieNeuOfflineV3 {
            // No network round trip — runs the actual v3-Turbo backbone +
            // MOSS codec through ONNX Runtime right here on-device (see
            // VieNeuOfflineV3TTSService).
            return try await VieNeuOfflineV3TTSService.shared.synthesize(
                text: text, speed: speed, voice: vieNeuOfflineV3Voice ?? .minhDuc
            )
        }
        #endif
        if voice.isOffline || !isConnected || !isLoggedIn {
            // No network round trip — runs the bundled ONNX model right
            // here on-device (see PiperOfflineTTSService).
            return try await PiperOfflineTTSService.shared.synthesize(text: text, speed: speed)
        } else {
            return try await online.synthesize(
                text: text, voice: voice, vieNeuOfflineV2Voice: vieNeuOfflineV2Voice,
                vieNeuOfflineV3Voice: vieNeuOfflineV3Voice, gwenTTSSpeaker: gwenTTSSpeaker,
                speed: speed, baseURL: baseURL, isConnected: isConnected, isLoggedIn: isLoggedIn
            )
        }
    }
}
