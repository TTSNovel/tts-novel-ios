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
        } else if voice.isOffline || !isConnected || !isLoggedIn {
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
