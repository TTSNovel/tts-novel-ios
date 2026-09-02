import Foundation

/// Always synthesizes via the server's `/api/tts` (`APIClient.synthesize`),
/// ignoring the offline-voice parameters entirely — the synthesizer used by
/// any platform target that doesn't link the on-device TTS engines
/// (watchOS always; macOS/iOS whenever `WebnovelReaderFullSynthesizer`
/// delegates its own online branch here). Retries a failed fetch up to
/// `maxRetries` more times, but only for errors that look transient — a
/// dropped/timed-out connection, or the server queue rejecting the request
/// (429) / a backend hiccup (5xx). Retrying `.notAuthenticated` or a
/// malformed response would just burn through the retry budget on a
/// failure that can't self-resolve. Linear backoff (1s, then 2s) rather
/// than immediate retry, giving the Cloud Run GPU fleet a moment to free up
/// an instance instead of hammering it again right away.
public final class WebnovelReaderOnlineSynthesizer: TTSSynthesizing {
    private let maxRetries: Int

    public init(maxRetries: Int = 2) {
        self.maxRetries = maxRetries
    }

    public func synthesize(
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
        var attempt = 0
        while true {
            do {
                return try await APIClient.shared.synthesize(
                    baseURL: baseURL, text: text, voice: voice, speed: speed, gwenSpeaker: gwenTTSSpeaker
                )
            } catch {
                guard attempt < maxRetries, Self.isRetryableTTSError(error) else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }

    private static func isRetryableTTSError(_ error: Error) -> Bool {
        if let apiError = error as? APIError {
            switch apiError {
            case .httpStatus(let code): return code == 429 || (500...599).contains(code)
            case .invalidResponse: return true
            case .notAuthenticated: return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .timedOut, .notConnectedToInternet, .dnsLookupFailed, .cannotConnectToHost, .cannotFindHost:
                return true
            default:
                return false
            }
        }
        return false
    }
}
