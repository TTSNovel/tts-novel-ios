import Foundation

/// Strategy seam for turning a sentence of text into playable audio —
/// `ReaderPlaybackController` (app-target) talks only to this protocol, not
/// to any concrete engine, so which synthesizer gets constructed can vary
/// per platform without touching the playback state machine. Two
/// implementations exist: `WebnovelReaderOnlineSynthesizer` (here, in
/// Core — always calls the server's `/api/tts`, no offline engines, usable
/// by every platform target including watchOS) and
/// `WebnovelReaderFullSynthesizer` (app-target-only — dispatches to the
/// on-device Piper/VieNeu engines first, falling back to
/// `WebnovelReaderOnlineSynthesizer` by composition).
public protocol TTSSynthesizing: Sendable {
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
    ) async throws -> Data
}
